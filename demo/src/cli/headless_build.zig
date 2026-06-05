//! headless_build — безоконная сборка навмеша (cluster D / D5).
//!
//! Строит навмеш ВЫБРАННЫМ сэмплом (solo/tile/temp) БЕЗ GL-контекста и без окна,
//! затем собирает метрики (nav_export.gatherMetrics) -> JSON (export_metrics.toJson)
//! и (опционально) экспортирует геометрию навмеша (.bin/.obj/.glb/.svg).
//!
//! ── GL-FREE: как и почему ────────────────────────────────────────────────────
//! Sample{Solo,Tile,TempObstacles}.init требует `*DebugDrawGL`, а DebugDrawGL.init
//! создаёт GL program/VAO/VBO/texture и ТРЕБУЕТ живой GL-контекст. Однако сам
//! build()/doBuild() этот указатель НЕ дереференсит — `dd_gl` читается ИСКЛЮЧИТЕЛЬНО
//! в render() (проверено: grep `dd_gl` по sample_solo.zig даёт только render-путь).
//! Поэтому здесь создаётся `var dd: DebugDrawGL = undefined` и в init передаётся
//! `&dd`: build() его не трогает, GL не нужен. render() в headless не вызывается.
//!
//! ── R-D1 (совпадение с GUI) ──────────────────────────────────────────────────
//! Используется ТОТ ЖЕ `sample.build()`, что и GUI (loadMeshIndex -> solo.build()).
//! Метрики идентичны GUI-сборке на том же geom+settings BY CONSTRUCTION — общий
//! build-путь, общая структура CommonSettings, общий gatherMetrics. Риск
//! расхождения отсутствует, пока GUI и headless подают одинаковые settings.

const std = @import("std");
const InputGeom = @import("../input_geom.zig").InputGeom;
const BuildContext = @import("../build_context.zig").BuildContext;
const ddgl = @import("../debug_draw_gl.zig");
const sample = @import("../sample.zig");
const SampleSolo = @import("../sample_solo.zig").SampleSolo;
const SampleTile = @import("../sample_tile.zig").SampleTile;
const SampleTempObstacles = @import("../sample_temp_obstacles.zig").SampleTempObstacles;
const import_geom = @import("../io/import_geom.zig");
const nav_export = @import("../io/nav_export.zig");
const export_metrics = @import("../io/export_metrics.zig");
const export_obj = @import("../io/export_obj.zig");
const export_gltf = @import("../io/export_gltf.zig");
const export_svg = @import("../io/export_svg.zig");
const navmesh_io = @import("../navmesh_io.zig");
const io_util = @import("../io_util.zig");

pub const SampleKind = enum { solo, tile, temp };

/// Параметры headless-сборки (заполняются парсером cli.zig).
pub const Options = struct {
    geom: []const u8,
    sample: SampleKind = .solo,
    settings: sample.CommonSettings = .{},
    /// tile_size для tile/temp (используется только если sample != .solo).
    tile_size: ?f32 = null,
    /// Куда писать метрики: путь к файлу, либо "-" = stdout.
    metrics_out: []const u8,
    out_navmesh: ?[]const u8 = null,
    out_obj: ?[]const u8 = null,
    out_gltf: ?[]const u8 = null,
    out_svg: ?[]const u8 = null,
};

/// Печать строки прогресса/ошибки в stderr (как весь проект через std.debug.print).
fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Записать `data` в stdout (для `--metrics -`).
fn writeStdout(gpa: std.mem.Allocator, data: []const u8) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.File.stdout().writeStreamingAll(threaded.io(), data);
}

/// Выполнить безоконную сборку. Возвращает process exit-code (0 = успех).
/// Никогда не паникует на ожидаемых ошибках (IO/парс/пустая геометрия) —
/// логирует в stderr и возвращает !=0.
pub fn headlessBuild(gpa: std.mem.Allocator, opt: Options) u8 {
    // --- GL-free debug-draw заглушка (см. шапку). build() её не читает. ---
    var dd: ddgl.DebugDrawGL = undefined;

    var bctx = BuildContext.init(gpa);
    bctx.wire();
    defer bctx.deinit();

    var geom = InputGeom.init(gpa);
    defer geom.deinit();

    import_geom.loadInto(&geom, opt.geom) catch |e| {
        warn("[build] load geom '{s}' failed: {s}\n", .{ opt.geom, @errorName(e) });
        return 2;
    };
    if (geom.triCount() == 0) {
        warn("[build] geom '{s}' has 0 triangles\n", .{opt.geom});
        return 2;
    }
    warn("[build] loaded {s}: {d} verts, {d} tris\n", .{ opt.geom, geom.vertCount(), geom.triCount() });

    // --- собрать выбранным сэмплом (ОБЩИЙ build-путь с GUI — R-D1) ---
    const sample_name: []const u8 = switch (opt.sample) {
        .solo => "solo",
        .tile => "tile",
        .temp => "temp",
    };

    var mesh: *@import("recast-nav").detour.NavMesh = undefined;
    var build_ms: f32 = 0;
    var tile_size_meta: ?f32 = null;

    // Сэмплы создаются в union-подобном порядке; держим живой только активный.
    switch (opt.sample) {
        .solo => {
            var s = SampleSolo.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = opt.settings;
            s.setGeom(&geom);
            if (!s.build()) {
                warn("[build] solo build failed (see log above)\n", .{});
                return 3;
            }
            build_ms = s.build_time_ms;
            mesh = s.navMesh() orelse {
                warn("[build] solo produced no navmesh\n", .{});
                return 3;
            };
            return finish(gpa, opt, mesh, &bctx, &geom, sample_name, build_ms, tile_size_meta);
        },
        .tile => {
            var s = SampleTile.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = opt.settings;
            if (opt.tile_size) |ts| s.tile_size = ts;
            tile_size_meta = s.tile_size;
            s.setGeom(&geom);
            if (!s.build()) {
                warn("[build] tile build failed (see log above)\n", .{});
                return 3;
            }
            build_ms = s.build_time_ms;
            mesh = s.navMesh() orelse {
                warn("[build] tile produced no navmesh\n", .{});
                return 3;
            };
            return finish(gpa, opt, mesh, &bctx, &geom, sample_name, build_ms, tile_size_meta);
        },
        .temp => {
            var s = SampleTempObstacles.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = opt.settings;
            if (opt.tile_size) |ts| s.tile_size = ts;
            tile_size_meta = s.tile_size;
            s.setGeom(&geom);
            if (!s.build()) {
                warn("[build] temp build failed (see log above)\n", .{});
                return 3;
            }
            build_ms = s.build_time_ms;
            mesh = s.navMesh() orelse {
                warn("[build] temp produced no navmesh\n", .{});
                return 3;
            };
            return finish(gpa, opt, mesh, &bctx, &geom, sample_name, build_ms, tile_size_meta);
        },
    }
}

/// Метрики + опциональные экспортные артефакты. Mesh и geom живы у вызывающего.
fn finish(
    gpa: std.mem.Allocator,
    opt: Options,
    mesh: *@import("recast-nav").detour.NavMesh,
    bctx: *BuildContext,
    geom: *const InputGeom,
    sample_name: []const u8,
    build_ms: f32,
    tile_size_meta: ?f32,
) u8 {
    _ = bctx;

    // --- метрики ---
    var owned = nav_export.gatherMetrics(
        gpa,
        mesh,
        &opt.settings,
        opt.geom,
        sample_name,
        geom.bmin,
        geom.bmax,
        build_ms,
        tile_size_meta,
    ) catch |e| {
        warn("[build] gatherMetrics failed: {s}\n", .{@errorName(e)});
        return 4;
    };
    defer owned.deinit(gpa);

    const json = export_metrics.toJson(gpa, owned.metrics) catch |e| {
        warn("[build] toJson failed: {s}\n", .{@errorName(e)});
        return 4;
    };
    defer gpa.free(json);

    if (std.mem.eql(u8, opt.metrics_out, "-")) {
        writeStdout(gpa, json) catch |e| {
            warn("[build] write stdout failed: {s}\n", .{@errorName(e)});
            return 4;
        };
    } else {
        io_util.writeWholeFile(opt.metrics_out, json, gpa) catch |e| {
            warn("[build] write '{s}' failed: {s}\n", .{ opt.metrics_out, @errorName(e) });
            return 4;
        };
        warn("[build] metrics -> {s}\n", .{opt.metrics_out});
    }

    // --- опциональные экспортные артефакты ---
    if (opt.out_navmesh) |p| {
        navmesh_io.save(gpa, p, mesh) catch |e| {
            warn("[build] save navmesh '{s}' failed: {s}\n", .{ p, @errorName(e) });
            return 5;
        };
        warn("[build] navmesh -> {s}\n", .{p});
    }

    if (opt.out_obj) |p| {
        if (exportObj(gpa, mesh, p)) {
            warn("[build] obj -> {s}\n", .{p});
        } else |e| {
            warn("[build] export obj '{s}' failed: {s}\n", .{ p, @errorName(e) });
            return 5;
        }
    }

    if (opt.out_gltf) |p| {
        if (exportGltf(gpa, mesh, p)) {
            warn("[build] gltf -> {s}\n", .{p});
        } else |e| {
            warn("[build] export gltf '{s}' failed: {s}\n", .{ p, @errorName(e) });
            return 5;
        }
    }

    if (opt.out_svg) |p| {
        if (exportSvg(gpa, mesh, p)) {
            warn("[build] svg -> {s}\n", .{p});
        } else |e| {
            warn("[build] export svg '{s}' failed: {s}\n", .{ p, @errorName(e) });
            return 5;
        }
    }

    return 0;
}

const NavMesh = @import("recast-nav").detour.NavMesh;

// ===========================================================================
// Reusable build pipeline (cluster H): «geom + settings -> built navmesh» with
// a callback so the navmesh (owned by a stack-resident sample) stays alive for
// the duration of the caller's work (queries, metrics, …). headless_run.zig
// (config/batch) uses this instead of re-implementing the per-sample switch.
// ===========================================================================

/// Результат сборки, передаваемый в callback: живой навмеш + метаданные сборки.
pub const BuiltNav = struct {
    mesh: *NavMesh,
    geom: *const InputGeom,
    sample_name: []const u8,
    build_ms: f32,
    tile_size: ?f32,
};

pub const BuildError = error{
    LoadGeomFailed,
    EmptyGeom,
    BuildFailed,
    NoNavmesh,
};

/// Собрать навмеш выбранным сэмплом (ОБЩИЙ build-путь с GUI — R-D1) и вызвать
/// `cb(ctx, BuiltNav)` пока навмеш ещё жив. Геометрия/сэмпл живут на стеке этой
/// функции и деинициализируются после возврата cb. Ошибки сборки -> BuildError
/// (логируются в stderr). Возвращает значение, которое вернул cb.
pub fn buildNavmesh(
    gpa: std.mem.Allocator,
    geom_path: []const u8,
    settings: sample.CommonSettings,
    sample_kind: SampleKind,
    tile_size_opt: ?f32,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), BuiltNav) anyerror!void,
) anyerror!void {
    var dd: ddgl.DebugDrawGL = undefined; // GL-free заглушка (см. шапку файла).

    var bctx = BuildContext.init(gpa);
    bctx.wire();
    defer bctx.deinit();

    var geom = InputGeom.init(gpa);
    defer geom.deinit();

    import_geom.loadInto(&geom, geom_path) catch |e| {
        warn("[run] load geom '{s}' failed: {s}\n", .{ geom_path, @errorName(e) });
        return BuildError.LoadGeomFailed;
    };
    if (geom.triCount() == 0) {
        warn("[run] geom '{s}' has 0 triangles\n", .{geom_path});
        return BuildError.EmptyGeom;
    }

    const sample_name: []const u8 = switch (sample_kind) {
        .solo => "solo",
        .tile => "tile",
        .temp => "temp",
    };

    switch (sample_kind) {
        .solo => {
            var s = SampleSolo.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = settings;
            s.setGeom(&geom);
            if (!s.build()) return BuildError.BuildFailed;
            const mesh = s.navMesh() orelse return BuildError.NoNavmesh;
            return cb(ctx, .{ .mesh = mesh, .geom = &geom, .sample_name = sample_name, .build_ms = s.build_time_ms, .tile_size = null });
        },
        .tile => {
            var s = SampleTile.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = settings;
            if (tile_size_opt) |ts| s.tile_size = ts;
            s.setGeom(&geom);
            if (!s.build()) return BuildError.BuildFailed;
            const mesh = s.navMesh() orelse return BuildError.NoNavmesh;
            return cb(ctx, .{ .mesh = mesh, .geom = &geom, .sample_name = sample_name, .build_ms = s.build_time_ms, .tile_size = s.tile_size });
        },
        .temp => {
            var s = SampleTempObstacles.init(gpa, &bctx, &dd);
            defer s.deinit();
            s.settings = settings;
            if (tile_size_opt) |ts| s.tile_size = ts;
            s.setGeom(&geom);
            if (!s.build()) return BuildError.BuildFailed;
            const mesh = s.navMesh() orelse return BuildError.NoNavmesh;
            return cb(ctx, .{ .mesh = mesh, .geom = &geom, .sample_name = sample_name, .build_ms = s.build_time_ms, .tile_size = s.tile_size });
        },
    }
}

fn exportObj(gpa: std.mem.Allocator, mesh: *const NavMesh, path: []const u8) !void {
    var g = try nav_export.navObjFaces(gpa, mesh);
    defer g.deinit(gpa);
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try export_obj.writeObj(&aw.writer, g.verts, g.faces_flat, g.face_sizes);
    try io_util.writeWholeFile(path, aw.writer.buffered(), gpa);
}

fn exportGltf(gpa: std.mem.Allocator, mesh: *const NavMesh, path: []const u8) !void {
    var g = try nav_export.navTriangles(gpa, mesh);
    defer g.deinit(gpa);
    const glb = try export_gltf.writeGlb(gpa, g.verts, g.indices);
    defer gpa.free(glb);
    try io_util.writeWholeFile(path, glb, gpa);
}

fn exportSvg(gpa: std.mem.Allocator, mesh: *const NavMesh, path: []const u8) !void {
    var g = try nav_export.navPolys2D(gpa, mesh);
    defer g.deinit(gpa);
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try export_svg.writeSvg(&aw.writer, g.polys_flat, g.poly_sizes, g.colors, g.bmin2, g.bmax2);
    try io_util.writeWholeFile(path, aw.writer.buffered(), gpa);
}
