//! Чистый детерминированный JSON-эмиттер метрик навмеша (cluster D / D3).
//!
//! Автономный модуль: импортирует ТОЛЬКО std, чтобы тестироваться отдельно от
//! остального проекта. Сам обход навмеша/recast здесь не делается — на вход
//! подаётся уже заполненная структура `Metrics`.
//!
//! Формат float: для ВСЕХ полей f32 используется `{d}` (Zig печатает кратчайшее
//! детерминированное десятичное представление, round-trip-точное для f32).
//! Выбор именно `{d}` (а не `{d:.6}`): он короче, детерминирован между запусками
//! на одной платформе и сохраняет точные значения без хвостовых нулей. Применяем
//! одинаково ко всем float (settings, bounds, tile_size, build_ms).
//!
//! Порядок ключей зафиксирован вручную (ручной writer, без std.json.Stringify)
//! строго по схеме D3 — это критично для побайтового diff (D6).

const std = @import("std");

pub const AreaCount = struct {
    id: u8,
    name: []const u8,
    poly_count: u32,
};

pub const Metrics = struct {
    schema_version: u32 = 1,
    source_geom: []const u8, // "dungeon.obj"
    source_sample: []const u8, // "solo"|"tile"|"temp"
    // settings (снимок CommonSettings)
    cell_size: f32,
    cell_height: f32,
    agent_height: f32,
    agent_radius: f32,
    agent_max_climb: f32,
    agent_max_slope: f32,
    region_min_size: f32,
    region_merge_size: f32,
    edge_max_len: f32,
    edge_max_error: f32,
    verts_per_poly: f32,
    detail_sample_dist: f32,
    detail_sample_max_error: f32,
    partition: []const u8, // "watershed"|"monotone"|"layers"
    tile_size: ?f32, // null для solo
    // bounds
    bmin: [3]f32,
    bmax: [3]f32,
    // navmesh counts
    num_tiles: u32,
    num_polys: u32,
    num_verts: u32,
    max_polys: u32,
    /// XXH3 (seed 0) over the navmesh tile data bytes — a deterministic build
    /// fingerprint (I-3 repro-contract). Same geom+settings -> same hash across
    /// runs/machines on one arch; byte-divergence from upstream MSET shows here.
    navmesh_hash: u64 = 0,
    areas: []const AreaCount,
    build_ms: f32,
};

/// Тонкая обёртка над std.array_list.Managed(u8) с writer-подобным API.
/// В Zig 0.16 у Managed-листа нет `.writer()`, есть методы append/appendSlice/print
/// прямо на структуре — оборачиваем их, чтобы helper'ы читались как обычный writer.
const Buf = struct {
    list: *std.array_list.Managed(u8),

    fn writeByte(self: Buf, b: u8) !void {
        try self.list.append(b);
    }
    fn writeAll(self: Buf, s: []const u8) !void {
        try self.list.appendSlice(s);
    }
    fn print(self: Buf, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(fmt, args);
    }
};

/// Записать JSON-строку в writer с экранированием спецсимволов по правилам JSON.
/// Экранируются: `"`, `\\`, и управляющие символы < 0x20 (включая \n, \r, \t, \b, \f).
fn writeJsonString(w: Buf, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            0x0D => try w.writeAll("\\r"),
            else => {
                if (c < 0x20) {
                    // прочие управляющие символы — \u00XX
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Записать значение f32 единым детерминированным форматом `{d}`.
///
/// ВАЖНО: Zig печатает `{d}` для не-конечных f32 как `inf`/`-inf`/`nan` —
/// это НЕВАЛИДНЫЙ JSON (нет таких литералов в RFC 8259), он сломает
/// std.json.parseFromSlice и весь diff D6. Поэтому не-конечные значения
/// (inf/-inf/nan) детерминированно заменяем на 0. Конечные значения, включая
/// -0.0, печатаются как есть.
fn writeFloat(w: Buf, v: f32) !void {
    const safe: f32 = if (std.math.isFinite(v)) v else 0;
    try w.print("{d}", .{safe});
}

/// Сериализовать Metrics в JSON (owned []u8, caller frees). ДЕТЕРМИНИРОВАННЫЙ
/// порядок ключей (критично для diff D6). Структура JSON — по схеме спеки D3.
pub fn toJson(alloc: std.mem.Allocator, m: Metrics) ![]u8 {
    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = Buf{ .list = &buf };

    try w.writeByte('{');

    // schema_version
    try w.print("\"schema_version\":{d}", .{m.schema_version});

    // source
    try w.writeAll(",\"source\":{");
    try w.writeAll("\"geom\":");
    try writeJsonString(w, m.source_geom);
    try w.writeAll(",\"sample\":");
    try writeJsonString(w, m.source_sample);
    try w.writeByte('}');

    // settings — порядок строго по схеме D3
    try w.writeAll(",\"settings\":{");
    try w.writeAll("\"cell_size\":");
    try writeFloat(w, m.cell_size);
    try w.writeAll(",\"cell_height\":");
    try writeFloat(w, m.cell_height);
    try w.writeAll(",\"agent_height\":");
    try writeFloat(w, m.agent_height);
    try w.writeAll(",\"agent_radius\":");
    try writeFloat(w, m.agent_radius);
    try w.writeAll(",\"agent_max_climb\":");
    try writeFloat(w, m.agent_max_climb);
    try w.writeAll(",\"agent_max_slope\":");
    try writeFloat(w, m.agent_max_slope);
    try w.writeAll(",\"region_min_size\":");
    try writeFloat(w, m.region_min_size);
    try w.writeAll(",\"region_merge_size\":");
    try writeFloat(w, m.region_merge_size);
    try w.writeAll(",\"edge_max_len\":");
    try writeFloat(w, m.edge_max_len);
    try w.writeAll(",\"edge_max_error\":");
    try writeFloat(w, m.edge_max_error);
    try w.writeAll(",\"verts_per_poly\":");
    try writeFloat(w, m.verts_per_poly);
    try w.writeAll(",\"detail_sample_dist\":");
    try writeFloat(w, m.detail_sample_dist);
    try w.writeAll(",\"detail_sample_max_error\":");
    try writeFloat(w, m.detail_sample_max_error);
    try w.writeAll(",\"partition\":");
    try writeJsonString(w, m.partition);
    try w.writeAll(",\"tile_size\":");
    if (m.tile_size) |ts| {
        try writeFloat(w, ts);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');

    // bounds
    try w.writeAll(",\"bounds\":{\"min\":[");
    try writeFloat(w, m.bmin[0]);
    try w.writeByte(',');
    try writeFloat(w, m.bmin[1]);
    try w.writeByte(',');
    try writeFloat(w, m.bmin[2]);
    try w.writeAll("],\"max\":[");
    try writeFloat(w, m.bmax[0]);
    try w.writeByte(',');
    try writeFloat(w, m.bmax[1]);
    try w.writeByte(',');
    try writeFloat(w, m.bmax[2]);
    try w.writeAll("]}");

    // navmesh
    try w.writeAll(",\"navmesh\":{");
    try w.print("\"num_tiles\":{d}", .{m.num_tiles});
    try w.print(",\"num_polys\":{d}", .{m.num_polys});
    try w.print(",\"num_verts\":{d}", .{m.num_verts});
    try w.print(",\"max_polys\":{d}", .{m.max_polys});
    // Deterministic build fingerprint as a hex STRING (exact-compared by D6 diff).
    try w.print(",\"hash\":\"0x{x:0>16}\"", .{m.navmesh_hash});
    try w.writeByte('}');

    // areas
    try w.writeAll(",\"areas\":[");
    for (m.areas, 0..) |a, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.print("\"id\":{d}", .{a.id});
        try w.writeAll(",\"name\":");
        try writeJsonString(w, a.name);
        try w.print(",\"poly_count\":{d}", .{a.poly_count});
        try w.writeByte('}');
    }
    try w.writeByte(']');

    // build_ms
    try w.writeAll(",\"build_ms\":");
    try writeFloat(w, m.build_ms);

    try w.writeByte('}');

    return buf.toOwnedSlice();
}

// ===========================================================================
// Тесты
// ===========================================================================

fn soloFixture() Metrics {
    const areas = &[_]AreaCount{
        .{ .id = 0, .name = "Ground", .poly_count = 128 },
    };
    return .{
        .schema_version = 1,
        .source_geom = "dungeon.obj",
        .source_sample = "solo",
        .cell_size = 0.3,
        .cell_height = 0.2,
        .agent_height = 2.0,
        .agent_radius = 0.6,
        .agent_max_climb = 0.9,
        .agent_max_slope = 45.0,
        .region_min_size = 8.0,
        .region_merge_size = 20.0,
        .edge_max_len = 12.0,
        .edge_max_error = 1.3,
        .verts_per_poly = 6.0,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .partition = "watershed",
        .tile_size = null,
        .bmin = .{ -10.0, -1.5, -10.0 },
        .bmax = .{ 10.0, 5.0, 10.0 },
        .num_tiles = 1,
        .num_polys = 200,
        .num_verts = 512,
        .max_polys = 256,
        .navmesh_hash = 0xDEADBEEFCAFEF00D,
        .areas = areas,
        .build_ms = 12.34,
    };
}

test "toJson: parses back via std.json (solo)" {
    const alloc = std.testing.allocator;
    const json = try toJson(alloc, soloFixture());
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    // корневой объект
    try std.testing.expect(parsed.value == .object);
}

test "toJson: concrete values (schema_version, num_polys, partition, tile_size null)" {
    const alloc = std.testing.allocator;
    const json = try toJson(alloc, soloFixture());
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"num_polys\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"partition\":\"watershed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tile_size\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Ground\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"build_ms\":12.34") != null);

    // структурно через парсер
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    const nav = root.get("navmesh").?.object;
    try std.testing.expectEqual(@as(i64, 200), nav.get("num_polys").?.integer);
    const settings = root.get("settings").?.object;
    try std.testing.expect(settings.get("tile_size").? == .null);
    try std.testing.expectEqualStrings("watershed", settings.get("partition").?.string);
}

test "toJson: deterministic (two calls produce identical bytes)" {
    const alloc = std.testing.allocator;
    const a = try toJson(alloc, soloFixture());
    defer alloc.free(a);
    const b = try toJson(alloc, soloFixture());
    defer alloc.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "toJson: string escaping (quote in source_geom)" {
    const alloc = std.testing.allocator;
    var m = soloFixture();
    m.source_geom = "weird\"name\n\\path.obj";

    const json = try toJson(alloc, m);
    defer alloc.free(json);

    // экранированная последовательность присутствует
    try std.testing.expect(std.mem.indexOf(u8, json, "weird\\\"name\\n\\\\path.obj") != null);

    // и всё ещё валидный JSON, парсится с тем же значением
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const geom = parsed.value.object.get("source").?.object.get("geom").?.string;
    try std.testing.expectEqualStrings("weird\"name\n\\path.obj", geom);
}

test "toJson: non-finite floats (inf/-inf/nan) -> 0, stays valid JSON" {
    const alloc = std.testing.allocator;
    var m = soloFixture();
    // Засовываем спецзначения в разные float-поля: build_ms, settings, bounds, tile_size.
    m.build_ms = std.math.inf(f32);
    m.cell_size = -std.math.inf(f32);
    m.agent_radius = std.math.nan(f32);
    m.bmin = .{ std.math.nan(f32), 0, std.math.inf(f32) };
    m.tile_size = std.math.inf(f32);

    const json = try toJson(alloc, m);
    defer alloc.free(json);

    // Никаких невалидных литералов inf/nan в выводе.
    try std.testing.expect(std.mem.indexOf(u8, json, "inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nan") == null);

    // Всё ещё валидный JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // build_ms заменён на 0 (integer 0 после {d}).
    const bm = root.get("build_ms").?;
    const bm_val: f64 = switch (bm) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => unreachable,
    };
    try std.testing.expectEqual(@as(f64, 0), bm_val);

    // tile_size был inf -> заменён на 0 (а НЕ null, т.к. поле было не-null).
    const ts = root.get("settings").?.object.get("tile_size").?;
    try std.testing.expect(ts != .null);
}

test "toJson: control characters in string escaped (\\r, \\u0001)" {
    const alloc = std.testing.allocator;
    var m = soloFixture();
    // area name из реестра может содержать что угодно: \r, \n, \t и низкий control 0x01.
    const evil_name = "a\rb\x01c\nd";
    const areas = &[_]AreaCount{
        .{ .id = 7, .name = evil_name, .poly_count = 1 },
    };
    m.areas = areas;

    const json = try toJson(alloc, m);
    defer alloc.free(json);

    // \r -> \\r, 0x01 -> \\u0001, \n -> \\n
    try std.testing.expect(std.mem.indexOf(u8, json, "a\\rb\\u0001c\\nd") != null);
    // Сырые control-байты в выводе отсутствуют.
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, 0x01) == null);

    // Парсится обратно с восстановлением исходной строки.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const name = parsed.value.object.get("areas").?.array.items[0].object.get("name").?.string;
    try std.testing.expectEqualStrings(evil_name, name);
}

test "toJson: empty areas and empty strings stay valid" {
    const alloc = std.testing.allocator;
    var m = soloFixture();
    m.areas = &[_]AreaCount{};
    m.source_geom = "";
    m.partition = "";

    const json = try toJson(alloc, m);
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"areas\":[]") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("areas").?.array.items.len);
    try std.testing.expectEqualStrings("", parsed.value.object.get("source").?.object.get("geom").?.string);
}

test "toJson: tile_size != null (tile sample)" {
    const alloc = std.testing.allocator;
    var m = soloFixture();
    m.source_sample = "tile";
    m.tile_size = 48.0;

    const json = try toJson(alloc, m);
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tile_size\":48") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sample\":\"tile\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const ts = parsed.value.object.get("settings").?.object.get("tile_size").?;
    // {d} печатает 48.0 как "48" -> JSON-парсер видит integer; принимаем оба варианта.
    const ts_val: f64 = switch (ts) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => unreachable,
    };
    try std.testing.expectEqual(@as(f64, 48.0), ts_val);
}
