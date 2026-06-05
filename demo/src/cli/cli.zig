//! cli — headless CLI-роутинг демо (cluster D / D5 + D6).
//!
//! Подкоманды:
//!   build  — собрать навмеш без окна, выгрузить метрики (+опц. геометрию).
//!   diff   — сравнить две JSON-метрики (D6), exit!=0 при расхождении.
//!
//! main.zig вызывает run() ДО любой инициализации glfw/GL/окна, если argv[1] —
//! одна из подкоманд. Весь парс аргументов живёт здесь; main.zig только
//! маршрутизирует. Прогресс/ошибки -> stderr (std.debug.print); метрики -> файл
//! или stdout (`--metrics -`). Любая ошибка парса/сборки/IO -> exit-code != 0.

const std = @import("std");
const sample = @import("../sample.zig");
const headless = @import("headless_build.zig");
const diff_mod = @import("diff.zig");
const io_util = @import("../io_util.zig");
const bundle_io = @import("../persist/bundle_io.zig");

/// true, если `arg` — известная headless-подкоманда (build/diff/bundle) ИЛИ путь к
/// .recastbundle (drag-onto-exe / `recast_demo file.recastbundle`). main.zig использует
/// это, чтобы решить, идти ли headless-путём ВМЕСТО GUI.
pub fn isSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "build") or
        std.mem.eql(u8, arg, "diff") or
        std.mem.eql(u8, arg, "bundle") or
        std.mem.endsWith(u8, arg, ".recastbundle");
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Точка входа CLI. `args` — полный argv (argv[0] = exe, argv[1] = подкоманда).
/// Возвращает process exit-code (0 = успех). Не паникует на ошибках ввода.
pub fn run(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) {
        warn("usage: recast_demo <build|diff> ...\n", .{});
        return 2;
    }
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "build")) return runBuild(gpa, rest);
    if (std.mem.eql(u8, cmd, "diff")) return runDiff(gpa, rest);
    // `bundle import <path>` OR a bare `<path>.recastbundle` (drag-onto-exe).
    if (std.mem.eql(u8, cmd, "bundle")) {
        if (rest.len >= 2 and std.mem.eql(u8, rest[0], "import")) return runBundleImport(gpa, rest[1]);
        warn("usage: recast_demo bundle import <file.recastbundle>\n", .{});
        return 2;
    }
    if (std.mem.endsWith(u8, cmd, ".recastbundle")) return runBundleImport(gpa, cmd);
    warn("unknown subcommand '{s}' (expected build|diff|bundle)\n", .{cmd});
    return 2;
}

// ===========================================================================
// bundle import — headless validate/unpack of a .recastbundle (cluster I / I-2)
// ===========================================================================

/// Headless import of a `.recastbundle`: unpack it into a temp `.recastscene/`
/// container, validate (magic/version/per-entry checksums propagate as errors),
/// and report what was restored on stderr. Full GUI scene-restore is NOT performed
/// here (no window/sample); this validates the bundle and materializes the scene so
/// it could be loaded — sufficient for drag-onto-exe / CI smoke. exit 0 on success.
fn runBundleImport(gpa: std.mem.Allocator, bundle_path: []const u8) u8 {
    // Restore next to the bundle file (its parent dir), mirroring the GUI flow.
    const dest = std.fs.path.dirname(bundle_path) orelse ".";
    var res = bundle_io.importBundle(gpa, bundle_path, dest) catch |e| {
        warn("[bundle] import '{s}' failed: {s}\n", .{ bundle_path, @errorName(e) });
        return 1;
    };
    defer res.deinit();
    warn("[bundle] imported scene -> {s}{s}\n", .{
        res.scene_container_path,
        if (res.repro_json != null) " (+repro/query.json)" else " (no repro)",
    });
    return 0;
}

// ===========================================================================
// build
// ===========================================================================

/// Получить значение следующего аргумента после флага `flag` на позиции `i`.
/// Возвращает null если значения нет (флаг был последним).
fn nextVal(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn runBuild(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var geom: ?[]const u8 = null;
    var metrics_out: ?[]const u8 = null;
    var sample_kind: headless.SampleKind = .solo;
    var settings = sample.CommonSettings{};
    var tile_size: ?f32 = null;
    var out_navmesh: ?[]const u8 = null;
    var out_obj: ?[]const u8 = null;
    var out_gltf: ?[]const u8 = null;
    var out_svg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--geom")) {
            geom = nextVal(args, &i) orelse return missingVal("--geom");
        } else if (std.mem.eql(u8, a, "--metrics")) {
            metrics_out = nextVal(args, &i) orelse return missingVal("--metrics");
        } else if (std.mem.eql(u8, a, "--sample")) {
            const v = nextVal(args, &i) orelse return missingVal("--sample");
            if (std.mem.eql(u8, v, "solo")) {
                sample_kind = .solo;
            } else if (std.mem.eql(u8, v, "tile")) {
                sample_kind = .tile;
            } else if (std.mem.eql(u8, v, "temp")) {
                sample_kind = .temp;
            } else {
                warn("[build] --sample: unknown value '{s}' (expected solo|tile|temp)\n", .{v});
                return 2;
            }
        } else if (std.mem.eql(u8, a, "--cfg")) {
            const v = nextVal(args, &i) orelse return missingVal("--cfg");
            if (!applyCfg(&settings, &tile_size, v)) return 2;
        } else if (std.mem.eql(u8, a, "--out-navmesh")) {
            out_navmesh = nextVal(args, &i) orelse return missingVal("--out-navmesh");
        } else if (std.mem.eql(u8, a, "--out-obj")) {
            out_obj = nextVal(args, &i) orelse return missingVal("--out-obj");
        } else if (std.mem.eql(u8, a, "--out-gltf")) {
            out_gltf = nextVal(args, &i) orelse return missingVal("--out-gltf");
        } else if (std.mem.eql(u8, a, "--out-svg")) {
            out_svg = nextVal(args, &i) orelse return missingVal("--out-svg");
        } else {
            warn("[build] unknown argument '{s}'\n", .{a});
            return 2;
        }
    }

    const g = geom orelse {
        warn("[build] --geom <path> is required\n", .{});
        return 2;
    };
    const m = metrics_out orelse {
        warn("[build] --metrics <out.json|-> is required\n", .{});
        return 2;
    };

    return headless.headlessBuild(gpa, .{
        .geom = g,
        .sample = sample_kind,
        .settings = settings,
        .tile_size = tile_size,
        .metrics_out = m,
        .out_navmesh = out_navmesh,
        .out_obj = out_obj,
        .out_gltf = out_gltf,
        .out_svg = out_svg,
    });
}

fn missingVal(flag: []const u8) u8 {
    warn("[build] {s}: missing value\n", .{flag});
    return 2;
}

/// Разобрать `--cfg k=v,k=v,...` и применить к settings/tile_size.
/// Неизвестный ключ -> false (caller возвращает exit!=0). Невалидное число тоже.
fn applyCfg(settings: *sample.CommonSettings, tile_size: *?f32, spec: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            warn("[build] --cfg: '{s}' is not k=v\n", .{pair});
            return false;
        };
        const key = std.mem.trim(u8, pair[0..eq], " ");
        const val = std.mem.trim(u8, pair[eq + 1 ..], " ");
        if (!applyOne(settings, tile_size, key, val)) return false;
    }
    return true;
}

fn parseF32(key: []const u8, val: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, val) catch {
        warn("[build] --cfg {s}: '{s}' is not a number\n", .{ key, val });
        return null;
    };
}

/// Применить один k=v к настройкам. Возвращает false при неизвестном ключе или
/// невалидном значении. Поддержанные ключи перечислены в спеке D5.
fn applyOne(settings: *sample.CommonSettings, tile_size: *?f32, key: []const u8, val: []const u8) bool {
    // `cells` — алиас cell_size (как в спеке: "cells/cell_size").
    if (std.mem.eql(u8, key, "cells") or std.mem.eql(u8, key, "cell_size")) {
        settings.cell_size = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "cell_height")) {
        settings.cell_height = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "agent_radius")) {
        settings.agent_radius = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "agent_height")) {
        settings.agent_height = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "agent_max_climb")) {
        settings.agent_max_climb = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "agent_max_slope")) {
        settings.agent_max_slope = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "region_min_size")) {
        settings.region_min_size = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "region_merge_size")) {
        settings.region_merge_size = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "edge_max_len")) {
        settings.edge_max_len = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "edge_max_error")) {
        settings.edge_max_error = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "verts_per_poly")) {
        settings.verts_per_poly = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "detail_sample_dist")) {
        settings.detail_sample_dist = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "detail_sample_max_error")) {
        settings.detail_sample_max_error = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "tile_size")) {
        tile_size.* = parseF32(key, val) orelse return false;
    } else if (std.mem.eql(u8, key, "partition")) {
        if (std.mem.eql(u8, val, "watershed")) {
            settings.partition_type = .watershed;
        } else if (std.mem.eql(u8, val, "monotone")) {
            settings.partition_type = .monotone;
        } else if (std.mem.eql(u8, val, "layers")) {
            settings.partition_type = .layers;
        } else {
            warn("[build] --cfg partition: '{s}' (expected watershed|monotone|layers)\n", .{val});
            return false;
        }
    } else {
        warn("[build] --cfg: unknown key '{s}'\n", .{key});
        return false;
    }
    return true;
}

// ===========================================================================
// diff
// ===========================================================================

fn runDiff(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var a_path: ?[]const u8 = null;
    var b_path: ?[]const u8 = null;
    var eps: f32 = 1e-4;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--a")) {
            a_path = nextVal(args, &i) orelse {
                warn("[diff] --a: missing value\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--b")) {
            b_path = nextVal(args, &i) orelse {
                warn("[diff] --b: missing value\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--eps")) {
            const v = nextVal(args, &i) orelse {
                warn("[diff] --eps: missing value\n", .{});
                return 2;
            };
            eps = std.fmt.parseFloat(f32, v) catch {
                warn("[diff] --eps: '{s}' is not a number\n", .{v});
                return 2;
            };
        } else {
            warn("[diff] unknown argument '{s}'\n", .{a});
            return 2;
        }
    }

    const ap = a_path orelse {
        warn("[diff] --a <a.json> is required\n", .{});
        return 2;
    };
    const bp = b_path orelse {
        warn("[diff] --b <b.json> is required\n", .{});
        return 2;
    };

    const a_json = io_util.readWholeFile(ap, gpa) catch |e| {
        warn("[diff] read '{s}' failed: {s}\n", .{ ap, @errorName(e) });
        return 2;
    };
    defer gpa.free(a_json);
    const b_json = io_util.readWholeFile(bp, gpa) catch |e| {
        warn("[diff] read '{s}' failed: {s}\n", .{ bp, @errorName(e) });
        return 2;
    };
    defer gpa.free(b_json);

    var rep = diff_mod.diff(gpa, a_json, b_json, eps) catch |e| {
        warn("[diff] compare failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    defer rep.deinit();

    // Отчёт -> stdout. writeReport принимает *std.Io.Writer (как в его тестах),
    // поэтому форматируем в Allocating-буфер, затем сбрасываем в stdout.
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    diff_mod.writeReport(&aw.writer, rep) catch {};
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        std.Io.File.stdout().writeStreamingAll(threaded.io(), aw.writer.buffered()) catch {};
    }

    return if (rep.ok) 0 else 1;
}
