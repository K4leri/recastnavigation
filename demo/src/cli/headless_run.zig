//! headless_run — config-прогон и батч-матрица (cluster H / P0+P1).
//!
//! Две точки входа, обе поверх headless_build.buildNavmesh (общий build-путь):
//!   runConfig(gpa, config_path) — JSON-конфиг: geom + settings + queries + out{}.
//!     Собирает навмеш, gatherMetrics, runQueries, пишет metrics/query_results/csv/
//!     navmesh. exit 0 если сборка ок и все запросы found (или ожиданий нет).
//!   runBatch(gpa, args)        — декартова матрица параметров (--matrix), для
//!     каждой ячейки собирает навмеш (+опц. queries) и пишет строку CSV.
//!
//! JSON парсится через std.json.parseFromSlice(std.json.Value, ...). Прогресс/
//! ошибки -> stderr. Вывод файлов -> io_util.writeWholeFile.

const std = @import("std");
const sample = @import("../sample.zig");
const headless = @import("headless_build.zig");
const headless_query = @import("headless_query.zig");
const nav_export = @import("../io/nav_export.zig");
const export_metrics = @import("../io/export_metrics.zig");
const export_query = @import("../io/export_query.zig");
const navmesh_io = @import("../navmesh_io.zig");
const io_util = @import("../io_util.zig");
const recast = @import("recast-nav");

const dt = recast.detour;

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// ===========================================================================
// Shared: JSON -> settings
// ===========================================================================

/// Применить объект "settings" (std.json) к CommonSettings/tile_size. Неизвестные
/// ключи игнорируются (forward-compat). Числа берём как f64 -> f32.
fn applySettingsJson(s: *sample.CommonSettings, tile_size: *?f32, obj: std.json.ObjectMap) void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "partition")) {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "monotone")) {
                    s.partition_type = .monotone;
                } else if (std.mem.eql(u8, v.string, "layers")) {
                    s.partition_type = .layers;
                } else {
                    s.partition_type = .watershed;
                }
            }
            continue;
        }
        const num: f32 = switch (v) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => continue,
        };
        if (std.mem.eql(u8, key, "cell_size")) s.cell_size = num else if (std.mem.eql(u8, key, "cell_height")) s.cell_height = num else if (std.mem.eql(u8, key, "agent_height")) s.agent_height = num else if (std.mem.eql(u8, key, "agent_radius")) s.agent_radius = num else if (std.mem.eql(u8, key, "agent_max_climb")) s.agent_max_climb = num else if (std.mem.eql(u8, key, "agent_max_slope")) s.agent_max_slope = num else if (std.mem.eql(u8, key, "region_min_size")) s.region_min_size = num else if (std.mem.eql(u8, key, "region_merge_size")) s.region_merge_size = num else if (std.mem.eql(u8, key, "edge_max_len")) s.edge_max_len = num else if (std.mem.eql(u8, key, "edge_max_error")) s.edge_max_error = num else if (std.mem.eql(u8, key, "verts_per_poly")) s.verts_per_poly = num else if (std.mem.eql(u8, key, "detail_sample_dist")) s.detail_sample_dist = num else if (std.mem.eql(u8, key, "detail_sample_max_error")) s.detail_sample_max_error = num else if (std.mem.eql(u8, key, "tile_size")) tile_size.* = num;
    }
}

fn parseSampleKind(str: []const u8) headless.SampleKind {
    if (std.mem.eql(u8, str, "tile")) return .tile;
    if (std.mem.eql(u8, str, "temp")) return .temp;
    return .solo;
}

/// Прочитать [3]f32 из json-массива. Недостающие -> 0.
fn readVec3(v: std.json.Value) [3]f32 {
    var out = [3]f32{ 0, 0, 0 };
    if (v != .array) return out;
    for (v.array.items, 0..) |item, i| {
        if (i >= 3) break;
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => 0,
        };
    }
    return out;
}

fn readU16(obj: std.json.ObjectMap, key: []const u8, default: u16) u16 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .integer => |n| @intCast(@max(0, @min(n, 0xffff))),
        else => default,
    };
}

// ===========================================================================
// runConfig
// ===========================================================================

/// Контекст, прокидываемый в build-callback: всё, что нужно для запросов + вывода.
const ConfigCtx = struct {
    gpa: std.mem.Allocator,
    specs: []const headless_query.QuerySpec,
    geom_path: []const u8,
    settings: *const sample.CommonSettings,
    out_metrics: ?[]const u8,
    out_query_json: ?[]const u8,
    out_query_csv: ?[]const u8,
    out_navmesh: ?[]const u8,
    // результаты (читаются после buildNavmesh):
    found: usize = 0,
    total: usize = 0,
    ok: bool = false,
};

fn configBuildCb(ctx: *ConfigCtx, built: headless.BuiltNav) anyerror!void {
    const gpa = ctx.gpa;

    // --- метрики ---
    if (ctx.out_metrics) |mp| {
        var owned = nav_export.gatherMetrics(gpa, built.mesh, ctx.settings, ctx.geom_path, built.sample_name, built.geom.bmin, built.geom.bmax, built.build_ms, built.tile_size) catch |e| {
            warn("[run] gatherMetrics failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer owned.deinit(gpa);
        const json = export_metrics.toJson(gpa, owned.metrics) catch |e| {
            warn("[run] metrics toJson failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer gpa.free(json);
        io_util.writeWholeFile(mp, json, gpa) catch |e| {
            warn("[run] write metrics '{s}' failed: {s}\n", .{ mp, @errorName(e) });
            return e;
        };
        warn("[run] metrics -> {s}\n", .{mp});
    }

    // --- навмеш ---
    if (ctx.out_navmesh) |np| {
        navmesh_io.save(gpa, np, built.mesh) catch |e| {
            warn("[run] save navmesh '{s}' failed: {s}\n", .{ np, @errorName(e) });
            return e;
        };
        warn("[run] navmesh -> {s}\n", .{np});
    }

    // --- запросы ---
    ctx.total = ctx.specs.len;
    if (ctx.specs.len != 0) {
        var query = dt.NavMeshQuery.init(gpa) catch |e| {
            warn("[run] NavMeshQuery.init failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer query.deinit();
        query.initQuery(built.mesh, 2048) catch |e| {
            warn("[run] initQuery failed: {s}\n", .{@errorName(e)});
            return e;
        };

        const records = headless_query.runQueries(gpa, query, built.mesh, ctx.specs) catch |e| {
            warn("[run] runQueries failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer headless_query.freeRecords(gpa, records);

        // queries_found = записи со статусом "ok" (полный успех). partial/failed не считаются.
        for (records) |r| {
            if (std.mem.eql(u8, r.status, "ok")) ctx.found += 1;
        }

        if (ctx.out_query_json) |qp| {
            const json = export_query.writeJson(gpa, records) catch |e| {
                warn("[run] query writeJson failed: {s}\n", .{@errorName(e)});
                return e;
            };
            defer gpa.free(json);
            io_util.writeWholeFile(qp, json, gpa) catch |e| {
                warn("[run] write query json '{s}' failed: {s}\n", .{ qp, @errorName(e) });
                return e;
            };
            warn("[run] query_results -> {s}\n", .{qp});
        }
        if (ctx.out_query_csv) |cp| {
            var aw = std.Io.Writer.Allocating.init(gpa);
            defer aw.deinit();
            export_query.writeCsv(&aw.writer, records) catch |e| {
                warn("[run] query writeCsv failed: {s}\n", .{@errorName(e)});
                return e;
            };
            io_util.writeWholeFile(cp, aw.writer.buffered(), gpa) catch |e| {
                warn("[run] write query csv '{s}' failed: {s}\n", .{ cp, @errorName(e) });
                return e;
            };
            warn("[run] query_csv -> {s}\n", .{cp});
        }
        warn("[run] queries: {d}/{d} found (ok)\n", .{ ctx.found, ctx.total });
    }
    ctx.ok = true;
}

/// `recast_demo headless --config run.json`. Возвращает process exit-code.
pub fn runConfig(gpa: std.mem.Allocator, config_path: []const u8) u8 {
    const text = io_util.readWholeFile(config_path, gpa) catch |e| {
        warn("[run] read config '{s}' failed: {s}\n", .{ config_path, @errorName(e) });
        return 2;
    };
    defer gpa.free(text);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |e| {
        warn("[run] config JSON parse failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        warn("[run] config root must be a JSON object\n", .{});
        return 2;
    }
    const root = parsed.value.object;

    const geom_path = blk: {
        const v = root.get("geom") orelse {
            warn("[run] config: \"geom\" is required\n", .{});
            return 2;
        };
        if (v != .string) {
            warn("[run] config: \"geom\" must be a string\n", .{});
            return 2;
        }
        break :blk v.string;
    };

    var settings = sample.CommonSettings{};
    var tile_size: ?f32 = null;
    if (root.get("settings")) |sv| {
        if (sv == .object) applySettingsJson(&settings, &tile_size, sv.object);
    }

    const sample_kind = blk: {
        const v = root.get("sample") orelse break :blk headless.SampleKind.solo;
        if (v == .string) break :blk parseSampleKind(v.string);
        break :blk headless.SampleKind.solo;
    };

    // --- queries ---
    var specs = std.array_list.Managed(headless_query.QuerySpec).init(gpa);
    defer specs.deinit();
    if (root.get("queries")) |qv| {
        if (qv == .array) {
            for (qv.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const type_v = o.get("type") orelse continue;
                if (type_v != .string) continue;
                specs.append(.{
                    .type = type_v.string, // живёт пока жив `parsed`
                    .start = if (o.get("start")) |s| readVec3(s) else .{ 0, 0, 0 },
                    .end = if (o.get("end")) |e| readVec3(e) else .{ 0, 0, 0 },
                    .include = readU16(o, "include", 0xffff),
                    .exclude = readU16(o, "exclude", 0),
                    .half_extents = if (o.get("half_extents")) |h| readVec3(h) else .{ 2, 4, 2 },
                }) catch return 4;
            }
        }
    }

    // --- out{} ---
    var out_metrics: ?[]const u8 = null;
    var out_query_json: ?[]const u8 = null;
    var out_query_csv: ?[]const u8 = null;
    var out_navmesh: ?[]const u8 = null;
    if (root.get("out")) |ov| {
        if (ov == .object) {
            const o = ov.object;
            if (o.get("metrics")) |x| if (x == .string) {
                out_metrics = x.string;
            };
            if (o.get("query_results")) |x| if (x == .string) {
                out_query_json = x.string;
            };
            if (o.get("query_csv")) |x| if (x == .string) {
                out_query_csv = x.string;
            };
            if (o.get("navmesh")) |x| if (x == .string) {
                out_navmesh = x.string;
            };
        }
    }

    var ctx = ConfigCtx{
        .gpa = gpa,
        .specs = specs.items,
        .geom_path = geom_path,
        .settings = &settings,
        .out_metrics = out_metrics,
        .out_query_json = out_query_json,
        .out_query_csv = out_query_csv,
        .out_navmesh = out_navmesh,
    };

    headless.buildNavmesh(gpa, geom_path, settings, sample_kind, tile_size, &ctx, configBuildCb) catch |e| {
        warn("[run] build/queries failed: {s}\n", .{@errorName(e)});
        return 3;
    };

    if (!ctx.ok) return 3;
    // exit != 0, если были запросы и не все нашли путь.
    if (ctx.total != 0 and ctx.found != ctx.total) {
        warn("[run] {d}/{d} queries found a path (expected all)\n", .{ ctx.found, ctx.total });
        return 1;
    }
    return 0;
}

// ===========================================================================
// runBatch
// ===========================================================================

const MatrixParam = struct {
    key: []const u8,
    values: std.array_list.Managed([]const u8),
};

/// Контекст batch-ячейки: собирает счётчики для CSV-строки.
const CellCtx = struct {
    gpa: std.mem.Allocator,
    specs: []const headless_query.QuerySpec,
    num_polys: u32 = 0,
    num_verts: u32 = 0,
    build_ms: f32 = 0,
    found: usize = 0,
    total: usize = 0,
    ok: bool = false,
};

fn cellBuildCb(ctx: *CellCtx, built: headless.BuiltNav) anyerror!void {
    ctx.build_ms = built.build_ms;
    // считаем polys/verts быстрым обходом тайлов (как gatherMetrics).
    var np: u32 = 0;
    var nv: u32 = 0;
    for (built.mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        np += @intCast(@max(hdr.poly_count, 0));
        nv += @intCast(@max(hdr.vert_count, 0));
    }
    ctx.num_polys = np;
    ctx.num_verts = nv;

    ctx.total = ctx.specs.len;
    if (ctx.specs.len != 0) {
        var query = dt.NavMeshQuery.init(ctx.gpa) catch |e| return e;
        defer query.deinit();
        query.initQuery(built.mesh, 2048) catch |e| return e;
        const records = headless_query.runQueries(ctx.gpa, query, built.mesh, ctx.specs) catch |e| return e;
        defer headless_query.freeRecords(ctx.gpa, records);
        for (records) |r| {
            if (std.mem.eql(u8, r.status, "ok")) ctx.found += 1;
        }
    }
    ctx.ok = true;
}

/// `recast_demo batch --geom X --sample solo --matrix "k=v1,v2;k2=v3,v4" --out table.csv [--queries run.json] [--out-json t.json]`
pub fn runBatch(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var geom: ?[]const u8 = null;
    var sample_kind: headless.SampleKind = .solo;
    var matrix_spec: ?[]const u8 = null;
    var out_csv: ?[]const u8 = null;
    var out_json: ?[]const u8 = null;
    var queries_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--geom")) {
            i += 1;
            if (i >= args.len) return missing("--geom");
            geom = args[i];
        } else if (std.mem.eql(u8, a, "--sample")) {
            i += 1;
            if (i >= args.len) return missing("--sample");
            sample_kind = parseSampleKind(args[i]);
        } else if (std.mem.eql(u8, a, "--matrix")) {
            i += 1;
            if (i >= args.len) return missing("--matrix");
            matrix_spec = args[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return missing("--out");
            out_csv = args[i];
        } else if (std.mem.eql(u8, a, "--out-json")) {
            i += 1;
            if (i >= args.len) return missing("--out-json");
            out_json = args[i];
        } else if (std.mem.eql(u8, a, "--queries")) {
            i += 1;
            if (i >= args.len) return missing("--queries");
            queries_path = args[i];
        } else {
            warn("[batch] unknown argument '{s}'\n", .{a});
            return 2;
        }
    }

    const g = geom orelse {
        warn("[batch] --geom <path> is required\n", .{});
        return 2;
    };
    const ms = matrix_spec orelse {
        warn("[batch] --matrix \"k=v1,v2;...\" is required\n", .{});
        return 2;
    };
    const oc = out_csv orelse {
        warn("[batch] --out <table.csv> is required\n", .{});
        return 2;
    };

    // --- парс матрицы: ";"-разделённые параметры, каждый "key=v1,v2,..." ---
    var params = std.array_list.Managed(MatrixParam).init(gpa);
    defer {
        for (params.items) |*p| p.values.deinit();
        params.deinit();
    }
    {
        var pit = std.mem.tokenizeScalar(u8, ms, ';');
        while (pit.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                warn("[batch] --matrix: '{s}' is not key=values\n", .{pair});
                return 2;
            };
            const key = std.mem.trim(u8, pair[0..eq], " ");
            var vals = std.array_list.Managed([]const u8).init(gpa);
            var vit = std.mem.tokenizeScalar(u8, pair[eq + 1 ..], ',');
            while (vit.next()) |v| vals.append(std.mem.trim(u8, v, " ")) catch return 4;
            if (vals.items.len == 0) {
                warn("[batch] --matrix: key '{s}' has no values\n", .{key});
                vals.deinit();
                return 2;
            }
            params.append(.{ .key = key, .values = vals }) catch return 4;
        }
    }
    if (params.items.len == 0) {
        warn("[batch] --matrix produced no parameters\n", .{});
        return 2;
    }

    // --- опц. queries из JSON-файла (формат как config.queries) ---
    var qparsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (qparsed) |*p| p.deinit();
    var specs = std.array_list.Managed(headless_query.QuerySpec).init(gpa);
    defer specs.deinit();
    if (queries_path) |qp| {
        const qtext = io_util.readWholeFile(qp, gpa) catch |e| {
            warn("[batch] read queries '{s}' failed: {s}\n", .{ qp, @errorName(e) });
            return 2;
        };
        defer gpa.free(qtext);
        qparsed = std.json.parseFromSlice(std.json.Value, gpa, qtext, .{}) catch |e| {
            warn("[batch] queries JSON parse failed: {s}\n", .{@errorName(e)});
            return 2;
        };
        // queries-файл = либо {"queries":[...]} либо просто [...]
        const arr: ?std.json.Array = blk: {
            const rv = qparsed.?.value;
            if (rv == .array) break :blk rv.array;
            if (rv == .object) {
                if (rv.object.get("queries")) |qv| if (qv == .array) break :blk qv.array;
            }
            break :blk null;
        };
        if (arr) |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const type_v = o.get("type") orelse continue;
                if (type_v != .string) continue;
                specs.append(.{
                    .type = type_v.string,
                    .start = if (o.get("start")) |s| readVec3(s) else .{ 0, 0, 0 },
                    .end = if (o.get("end")) |e| readVec3(e) else .{ 0, 0, 0 },
                    .include = readU16(o, "include", 0xffff),
                    .exclude = readU16(o, "exclude", 0),
                    .half_extents = if (o.get("half_extents")) |h| readVec3(h) else .{ 2, 4, 2 },
                }) catch return 4;
            }
        }
    }

    // --- декартова матрица: итерация по всем комбинациям ---
    var csv = std.Io.Writer.Allocating.init(gpa);
    defer csv.deinit();
    // заголовок: <param keys...>,status,num_polys,num_verts,build_ms,queries_found,queries_total
    for (params.items) |p| {
        csv.writer.writeAll(p.key) catch return 4;
        csv.writer.writeByte(',') catch return 4;
    }
    csv.writer.writeAll("status,num_polys,num_verts,build_ms,queries_found,queries_total\n") catch return 4;

    // JSON-таблица (опц.)
    var json = std.Io.Writer.Allocating.init(gpa);
    defer json.deinit();
    json.writer.writeByte('[') catch return 4;
    var json_first = true;

    // индексы-счётчики по каждому параметру (mixed-radix).
    const nparams = params.items.len;
    var idxs = gpa.alloc(usize, nparams) catch return 4;
    defer gpa.free(idxs);
    @memset(idxs, 0);

    var any_fail = false;
    var cell_count: usize = 0;

    while (true) {
        cell_count += 1;
        // собрать settings для текущей комбинации.
        var settings = sample.CommonSettings{};
        var tile_size: ?f32 = null;
        var bad_key = false;
        for (params.items, 0..) |p, pi| {
            const val = p.values.items[idxs[pi]];
            if (!applyMatrixKey(&settings, &tile_size, p.key, val)) {
                warn("[batch] unknown/invalid matrix key '{s}'='{s}'\n", .{ p.key, val });
                bad_key = true;
            }
        }
        if (bad_key) return 2;

        var ctx = CellCtx{ .gpa = gpa, .specs = specs.items };
        var status: []const u8 = "ok";
        headless.buildNavmesh(gpa, g, settings, sample_kind, tile_size, &ctx, cellBuildCb) catch {
            status = "failed";
            any_fail = true;
        };
        if (!ctx.ok and !any_fail) {
            // (buildNavmesh не вызвал cb из-за ошибки до cb)
            status = "failed";
            any_fail = true;
        }

        // CSV-строка
        for (params.items, 0..) |p, pi| {
            csv.writer.writeAll(p.values.items[idxs[pi]]) catch return 4;
            csv.writer.writeByte(',') catch return 4;
        }
        csv.writer.print("{s},{d},{d},{d},{d},{d}\n", .{ status, ctx.num_polys, ctx.num_verts, ctx.build_ms, ctx.found, ctx.total }) catch return 4;

        // JSON-строка
        if (out_json != null) {
            if (!json_first) json.writer.writeByte(',') catch return 4;
            json_first = false;
            json.writer.writeByte('{') catch return 4;
            for (params.items, 0..) |p, pi| {
                json.writer.print("\"{s}\":\"{s}\",", .{ p.key, p.values.items[idxs[pi]] }) catch return 4;
            }
            json.writer.print("\"status\":\"{s}\",\"num_polys\":{d},\"num_verts\":{d},\"build_ms\":{d},\"queries_found\":{d},\"queries_total\":{d}}}", .{ status, ctx.num_polys, ctx.num_verts, ctx.build_ms, ctx.found, ctx.total }) catch return 4;
        }

        // инкремент mixed-radix
        var carry: usize = nparams;
        while (carry > 0) {
            carry -= 1;
            idxs[carry] += 1;
            if (idxs[carry] < params.items[carry].values.items.len) break;
            idxs[carry] = 0;
            if (carry == 0) {
                // переполнение старшего разряда -> все комбинации перебраны.
                carry = std.math.maxInt(usize);
                break;
            }
        }
        if (carry == std.math.maxInt(usize)) break;
    }

    json.writer.writeByte(']') catch return 4;

    io_util.writeWholeFile(oc, csv.writer.buffered(), gpa) catch |e| {
        warn("[batch] write csv '{s}' failed: {s}\n", .{ oc, @errorName(e) });
        return 4;
    };
    warn("[batch] {d} cells -> {s}\n", .{ cell_count, oc });
    if (out_json) |oj| {
        io_util.writeWholeFile(oj, json.writer.buffered(), gpa) catch |e| {
            warn("[batch] write json '{s}' failed: {s}\n", .{ oj, @errorName(e) });
            return 4;
        };
        warn("[batch] json -> {s}\n", .{oj});
    }

    return if (any_fail) 1 else 0;
}

fn missing(flag: []const u8) u8 {
    warn("[batch] {s}: missing value\n", .{flag});
    return 2;
}

/// Применить один matrix key=val. Возвращает false при неизвестном ключе/значении.
/// Поддерживает те же ключи, что cli build --cfg, + partition (строковый).
fn applyMatrixKey(s: *sample.CommonSettings, tile_size: *?f32, key: []const u8, val: []const u8) bool {
    if (std.mem.eql(u8, key, "partition")) {
        if (std.mem.eql(u8, val, "watershed")) {
            s.partition_type = .watershed;
        } else if (std.mem.eql(u8, val, "monotone")) {
            s.partition_type = .monotone;
        } else if (std.mem.eql(u8, val, "layers")) {
            s.partition_type = .layers;
        } else return false;
        return true;
    }
    const num = std.fmt.parseFloat(f32, val) catch return false;
    if (std.mem.eql(u8, key, "cell_size") or std.mem.eql(u8, key, "cells")) {
        s.cell_size = num;
    } else if (std.mem.eql(u8, key, "cell_height")) {
        s.cell_height = num;
    } else if (std.mem.eql(u8, key, "agent_radius")) {
        s.agent_radius = num;
    } else if (std.mem.eql(u8, key, "agent_height")) {
        s.agent_height = num;
    } else if (std.mem.eql(u8, key, "agent_max_climb")) {
        s.agent_max_climb = num;
    } else if (std.mem.eql(u8, key, "agent_max_slope")) {
        s.agent_max_slope = num;
    } else if (std.mem.eql(u8, key, "region_min_size")) {
        s.region_min_size = num;
    } else if (std.mem.eql(u8, key, "region_merge_size")) {
        s.region_merge_size = num;
    } else if (std.mem.eql(u8, key, "edge_max_len")) {
        s.edge_max_len = num;
    } else if (std.mem.eql(u8, key, "edge_max_error")) {
        s.edge_max_error = num;
    } else if (std.mem.eql(u8, key, "verts_per_poly")) {
        s.verts_per_poly = num;
    } else if (std.mem.eql(u8, key, "detail_sample_dist")) {
        s.detail_sample_dist = num;
    } else if (std.mem.eql(u8, key, "detail_sample_max_error")) {
        s.detail_sample_max_error = num;
    } else if (std.mem.eql(u8, key, "tile_size")) {
        tile_size.* = num;
    } else return false;
    return true;
}
