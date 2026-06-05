//! RecastDemo — GUI-визуализатор navmesh (порт recastnavigation/RecastDemo).
//! Бэкенд: DVUI (glfw + OpenGL render_backend), 3D-рендер на модерн GL 3.3 core (zgl).
//!
//! Задача #9: окно + GL-контекст + dvui ontop + кадровый цикл.

const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("glfw-backend");
const zgl = @import("zgl");
const zglfw = Backend.zglfw;
const recast = @import("recast-nav");
const mat = @import("mat.zig");
const ui = @import("ui.zig");
const theme = @import("theme.zig");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const poly_flags = @import("poly_flags.zig");
const tracy = @import("tracy.zig");
const TestCase = @import("testcase.zig").TestCase;
const ddgl = @import("debug_draw_gl.zig");
const Camera = @import("camera.zig").Camera;
const BuildContext = @import("build_context.zig").BuildContext;
const AppState = @import("app_state.zig").AppState;
const io_util = @import("io_util.zig");
const scene_container = @import("persist/scene_container.zig");
const InputGate = @import("input_gate.zig").InputGate;
const tool_registry = @import("tool_registry.zig");
const InputGeom = @import("input_geom.zig").InputGeom;
const ConvexVolume = @import("input_geom.zig").ConvexVolume;
const SampleSolo = @import("sample_solo.zig").SampleSolo;
const scheme_state = @import("render/scheme_state.zig");
const filter_state = @import("render/filter_state.zig");
const isolation = @import("render/isolation.zig");
const view_state = @import("render/view_state.zig");
const legend = @import("render/legend.zig");
const overlay = @import("render/overlay.zig");
const minimap = @import("render/minimap.zig");
const capture = @import("render/capture.zig");
const poly_visit = @import("render/poly_visit.zig");
const SampleTile = @import("sample_tile.zig").SampleTile;
const SampleTempObstacles = @import("sample_temp_obstacles.zig").SampleTempObstacles;
const NavMeshTesterTool = @import("tool_navmesh_tester.zig").NavMeshTesterTool;
const OffMeshConnectionTool = @import("tool_offmesh.zig").OffMeshConnectionTool;
const ConvexVolumeTool = @import("tool_convex.zig").ConvexVolumeTool;
const CrowdTool = @import("tool_crowd.zig").CrowdTool;
const NavMeshPruneTool = @import("tool_prune.zig").NavMeshPruneTool;
const UndoStack = @import("edit/undo_stack.zig").UndoStack;
const edit_op = @import("edit/edit_op.zig");
const Selection = @import("edit/selection.zig").Selection;
const selection_mod = @import("edit/selection.zig");
const snap_mod = @import("edit/snap.zig");
const Clipboard = @import("edit/clipboard.zig").Clipboard;
const inspector = @import("edit/inspector.zig");
const presets = @import("edit/presets.zig");
const poly_inspect = @import("diag/poly_inspect.zig");
const navmesh_lint = @import("diag/navmesh_lint.zig");
const navmesh_verify = @import("diag/navmesh_verify.zig");
const Vec3 = recast.math.Vec3;

const ActiveTool = tool_registry.ToolId; // { none, tester, prune, offmesh, convex, crowd }

// Управление обработкой ошибок OpenGL в zgl.
pub const opengl_error_handling = zgl.ErrorHandling.assert;

var g_window: *zglfw.Window = undefined;
var g_scroll: f64 = 0; // аккумулятор колеса (пишется из callback)
var show_legend: bool = true; // Cluster E (P1-3): scheme legend corner overlay
var show_build_inspector: bool = false; // Cluster B (B-1): per-stage build inspector table

fn glGetProcAddress(p: zglfw.GlProc, proc: [:0]const u8) ?zgl.binding.FunctionPointer {
    _ = p;
    return @alignCast(zglfw.getProcAddress(proc));
}

fn scrollCallback(_: *zglfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    g_scroll += yoffset;
}

/// One snapshotted object's BEFORE-state for an in-progress group move (F3).
/// Keyed by stable id. Exactly one of `vol`/`off` is set per the `kind` tag.
/// The live geom verts are recomputed from this snapshot each frame (snapshot +
/// delta) so dragging never accumulates drift.
const MoveSnapItem = struct {
    kind: enum { volume, offmesh },
    id: u32,
    vol: ConvexVolume, // valid when kind == .volume
    off: edit_op.OffMeshData, // valid when kind == .offmesh
};

pub fn main(main_init: std.process.Init) !void {
    if (dvui.render_backend.kind != .opengl) @compileError("ожидается opengl render_backend");

    // --- окно + GL 3.3 core контекст (владеем мы) ---
    try zglfw.init();
    defer zglfw.terminate();

    // 4.1 core — максимум на macOS и достаточно, чтобы zgl загрузил все свои
    // entry points (включая GL 4.0 subroutines). GLSL 330 здесь поддерживается.
    zglfw.windowHint(.context_version_major, 4);
    zglfw.windowHint(.context_version_minor, 1);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.doublebuffer, true);
    zglfw.windowHint(.depth_bits, 24); // явный 24-бит depth — иначе z-fighting вокселей вдали
    zglfw.windowHint(.stencil_bits, 8);
    zglfw.windowHint(.samples, 4); // 4x MSAA как RecastDemo (main.cpp): без него копланарные
    // общие грани соседних воксель-боксов z-fight'ят на пологих углах -> мерцание/просвет

    g_window = try zglfw.Window.create(1280, 720, "RecastDemo — zig + dvui", null);
    defer g_window.destroy();

    zglfw.makeContextCurrent(g_window);
    zglfw.swapInterval(0); // драйверный vsync busy-wait жжёт CPU -> кап вручную ниже

    // GL-функции для нашего собственного 3D-рендера.
    // НЕ `try`: zgl.loadExtensions грузит ВЕСЬ набор GL до 4.6 и возвращает ошибку,
    // если ХОТЬ ОДНА функция не найдена через wglGetProcAddress. На драйверах без
    // GL 4.5 (Intel/старые GPU) отсутствуют robustness-функции (glGetnTexImage,
    // glGetnUniformdv, …), которые мы НЕ используем — но `try` ронял весь демо на
    // старте. Игнорируем: все нужные нам функции (GL 3.3/4.1 core: VBO/shader/texture/
    // draw) грузятся независимо; недостающие 4.2+ просто остаются незагруженными.
    const proc: zglfw.GlProc = undefined;
    zgl.loadExtensions(proc, glGetProcAddress) catch |err| {
        std.debug.print("[GL] zgl.loadExtensions: {s} — some GL >4.1 functions are unavailable on this driver (harmless: the demo does not use them; only core GL 3.3/4.1 is required)\n", .{@errorName(err)});
    };

    // ВАЖНО: ставим свой scroll-колбэк (камера) ДО Backend.init. Бэкенд dvui
    // сохранит его как userScrollCallback и будет чейнить непотреблённый скролл
    // (когда курсор НЕ над панелью) сюда. Иначе мы перезатёрли бы dvui-колбэк и
    // прокрутка scrollArea в панелях не работала бы.
    _ = zglfw.setScrollCallback(g_window, scrollCallback);

    // --- dvui поверх нашего контекста ---
    var renderer = try dvui.render_backend.init(main_init.gpa, zglfw.getProcAddress, "330");
    defer renderer.deinit();

    var impl = Backend.init(main_init.io, main_init.gpa, g_window);
    defer impl.deinit();

    const backend = dvui.Backend.init(&impl, &renderer);
    var win = try dvui.Window.init(@src(), main_init.gpa, backend, .{ .theme = theme.imgui_dark });
    defer win.deinit();

    // --- 3D debug-draw ---
    var dd_gl = try ddgl.DebugDrawGL.init(main_init.gpa);
    defer dd_gl.deinit();
    const dd = dd_gl.debugDraw();

    zgl.enable(.depth_test);
    // LEQUAL: навмеш/оверлеи рисуются на той же высоте, что и пол меша (depthMask=false).
    // С дефолтным LESS совпадающие фрагменты проигрывают z-тест -> навмеш невидим/мерцает.
    zgl.depthFunc(.less_or_equal);
    zgl.enable(.multisample); // 4x MSAA сглаживает копланарные швы граней вокселей (как RecastDemo)
    std.debug.print("[GL] samples={d} BUILD_MARKER=surface-mesh-v4 renderer={s} vendor={s}\n", .{ zgl.getInteger(.samples), zgl.getString(.renderer) orelse "?", zgl.getString(.vendor) orelse "?" });
    zgl.enable(.blend);
    zgl.blendFunc(.src_alpha, .one_minus_src_alpha);

    // --- состояние приложения + build-контекст (лог-панель) ---
    var app = AppState{};
    var bctx = BuildContext.init(main_init.gpa);
    bctx.wire();
    defer bctx.deinit();
    bctx.context().log(.progress, "RecastDemo (zig {s}) initialized", .{"0.16"});

    // --- камера + состояние ввода ---
    var cam = Camera{};
    cam.reset(Vec3.init(-25, 0, -25), Vec3.init(25, 10, 25));

    // --- геометрия + сэмпл SoloMesh ---
    var geom = InputGeom.init(main_init.gpa);
    defer geom.deinit();
    var solo = SampleSolo.init(main_init.gpa, &bctx, &dd_gl);
    defer solo.deinit();
    var tile = SampleTile.init(main_init.gpa, &bctx, &dd_gl);
    defer tile.deinit();
    var temp = SampleTempObstacles.init(main_init.gpa, &bctx, &dd_gl);
    defer temp.deinit();
    const SampleKind = enum { solo, tile, temp };
    var sample_kind: SampleKind = .solo;
    var prev_sample_kind: SampleKind = .solo;
    var last_gen: u32 = 0;

    // Scene-edit undo/redo stack (cluster F / F1). Owned here; threaded into the
    // convex + off-mesh tools so their add/delete edits are recorded.
    var undo_stack = UndoStack.init(main_init.gpa);
    defer undo_stack.deinit();

    // Multi-select state (cluster F / F3). Tracks selected volume/off-mesh ids by
    // STABLE id (survives undo/redo churn). Only meaningful for active_tool==.select.
    var selection = Selection.init(main_init.gpa);
    defer selection.deinit();

    var tester = NavMeshTesterTool.init(main_init.gpa, &dd_gl);
    defer tester.deinit();
    var offmesh_tool = OffMeshConnectionTool.init(&geom, &dd_gl, &undo_stack);
    var convex_tool = ConvexVolumeTool.init(main_init.gpa, &geom, &dd_gl, &undo_stack);
    defer convex_tool.deinit();
    var crowd_tool = CrowdTool.init(main_init.gpa, &dd_gl);
    defer crowd_tool.deinit();
    var prune_tool = NavMeshPruneTool.init(main_init.gpa, &dd_gl);
    defer prune_tool.deinit();
    var active_tool: ActiveTool = .tester;
    var prev_lmb = false;

    // Резолвим каталог ассетов относительно exe/cwd, чтобы recast_demo.exe запускался
    // из zig-out/bin (а не только из repo root). meshes = <base>, tests = <base>/TestCases.
    const assets_base = io_util.resolveAssetDir(main_init.gpa, "test_data") catch
        (main_init.gpa.dupe(u8, "test_data") catch "test_data");
    defer main_init.gpa.free(assets_base);
    app.meshes_folder = assets_base;

    // список мешей (персистентный для dropdown)
    var mesh_files: [][]u8 = &.{};
    if (io_util.scanDirectory(main_init.gpa, app.meshes_folder, ".obj")) |fs| {
        mesh_files = fs;
    } else |_| {}
    defer if (mesh_files.len > 0) {
        for (mesh_files) |f| main_init.gpa.free(f);
        main_init.gpa.free(mesh_files);
    };
    var mesh_names: [][]const u8 = &.{};
    if (mesh_files.len > 0) {
        mesh_names = main_init.gpa.alloc([]const u8, mesh_files.len) catch &.{};
        for (mesh_files, 0..) |f, i| mesh_names[i] = f;
    }
    defer if (mesh_names.len > 0) main_init.gpa.free(mesh_names);
    var mesh_choice: usize = 0;

    // список тест-кейсов (<base>/TestCases/*.txt) — база уже резолвнута относительно exe/cwd
    const tests_folder = try std.fmt.allocPrint(main_init.gpa, "{s}/TestCases", .{assets_base});
    defer main_init.gpa.free(tests_folder);
    var test_files: [][]u8 = &.{};
    if (io_util.scanDirectory(main_init.gpa, tests_folder, ".txt")) |fs| {
        test_files = fs;
    } else |_| {}
    defer if (test_files.len > 0) {
        for (test_files) |f| main_init.gpa.free(f);
        main_init.gpa.free(test_files);
    };
    var test_names: [][]const u8 = &.{};
    if (test_files.len > 0) {
        test_names = main_init.gpa.alloc([]const u8, test_files.len) catch &.{};
        for (test_files, 0..) |f, i| test_names[i] = f;
    }
    defer if (test_names.len > 0) main_init.gpa.free(test_names);
    var active_test: ?TestCase = null;
    defer if (active_test) |*t| t.deinit();
    var prev_test_choice: usize = std.math.maxInt(usize);

    if (mesh_files.len > 0)
        loadMeshIndex(main_init.gpa, app.meshes_folder, 0, mesh_files, &geom, &solo, &tile, &temp, &tester, &crowd_tool, &cam, &bctx);

    var last_mouse = g_window.getCursorPos();
    var rotating = false;
    var gate = InputGate{}; // курсор над панелью / фокус в textfield (с прошлого кадра)
    var prev_esc = false; // фронт Esc (чтобы Esc в редакторе не закрывал приложение)
    var new_flag_name: [20]u8 = [_]u8{0} ** 20; // поле ввода имени нового poly-флага
    // --- Capture UI state (Cluster E, P2-1) ---------------------------------
    var capture_ui_frames: f32 = 120; // frame-count slider (orbit -> 120 frames = full sweep)
    var capture_ui_dir: [capture.DIR_MAX]u8 = [_]u8{0} ** capture.DIR_MAX; // output dir text entry
    @memcpy(capture_ui_dir[0..7], "capture"); // default dir name
    // --- F4: area/flag presets state ---------------------------------------
    var preset_name: [48]u8 = [_]u8{0} ** 48; // поле ввода имени нового пресета (Save Preset)
    var preset_names: [][]u8 = &.{}; // кэш списка пресетов (имена-стемы, owned) — пересканируется
    var preset_choice: usize = 0; // выбранный пресет в дропдауне Apply
    var preset_merge: bool = true; // стратегия применения: true=Merge (по умолчанию), false=Replace
    var preset_list_init = false; // первичное сканирование presets/ выполнено?
    defer freePresetNames(main_init.gpa, &preset_names);
    var variant_name: [32]u8 = [_]u8{0} ** 32; // поле ввода тега варианта сцены (Save Scene)
    // Кэш списка вариантов сцены (Load): сканируется по требованию (кнопка Refresh и
    // при смене меша), не каждый кадр. Освобождается через freeVariants.
    var variants: []SceneVariant = &.{};
    var variants_stem: []const u8 = ""; // stem, для которого построен кэш (owned)
    defer freeVariants(main_init.gpa, &variants, &variants_stem);
    var pick_hit: ?Vec3 = null; // последняя точка пикинга по земле
    // B-4 Polygon Inspector: poly-ref picked by the Disabled-tool inspection click.
    // 0 = nothing inspected; non-zero = ref of the last clicked polygon.
    var inspected_ref: recast.detour.PolyRef = 0; // PolyRef-typed (widens to u64 under -Dpolyref64)
    // G1 Validation panel: cached LintReport from the last "Lint NavMesh" click.
    // Owns a heap ArrayList -> freed before re-lint and on the deferred teardown;
    // null-after-free so the deferred deinit never double-frees a moved report.
    var lint_report: ?navmesh_lint.LintReport = null;
    defer if (lint_report) |*r| r.deinit(main_init.gpa);
    var lint_highlight: bool = false; // overdraw culprit refs in a warning colour
    // G2 Validation panel: cached VerifyReport from the last "Verify Integrity"
    // click. Owns a heap ArrayList -> freed before re-verify and on the deferred
    // teardown; null-after-free so the deferred deinit never double-frees.
    var verify_report: ?navmesh_verify.VerifyReport = null;
    defer if (verify_report) |*r| r.deinit(main_init.gpa);
    var overlay_cap_warned = false; // P1-2: logged once when labels:all hits the cap
    // P1-4 minimap fly-to entry state.
    var minimap_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var mm_tile_x: f32 = 0;
    var mm_tile_y: f32 = 0;
    var mm_ref_buf: [20]u8 = [_]u8{0} ** 20;
    var snap_cfg = snap_mod.SnapConfig{}; // snap state (mode=.off by default)
    // Select-tool rubber-band drag (F3). `sel_drag_start` = world hit at LMB-down;
    // `sel_drag_cur` = current cursor world hit while held (for drawing the box).
    // Both null when not dragging. Active only for active_tool==.select.
    var sel_drag_start: ?Vec3 = null;
    var sel_drag_cur: ?Vec3 = null;
    var prev_delete = false; // edge-detect Del (group-delete in select tool)
    // F3 WAVE 2 — copy/paste clipboard (value copies of selected objects).
    var clipboard = Clipboard.init(main_init.gpa);
    defer clipboard.deinit();
    var prev_copy = false; // edge-detect Ctrl+C
    var prev_paste = false; // edge-detect Ctrl+V
    // F3 WAVE 2 — group move. `move_drag_start` = the world anchor at LMB-down on
    // an already-selected object; non-null only while a move is in progress (and
    // mutually exclusive with sel_drag_start). `move_snap` holds each selected
    // object's BEFORE-state so every frame recomputes verts = snapshot + delta.
    var move_drag_start: ?Vec3 = null;
    var move_snap = std.array_list.Managed(MoveSnapItem).init(main_init.gpa);
    defer move_snap.deinit();
    const dt: f32 = 1.0 / 60.0;

    // --- Auto-save state (cluster F) ---
    // When enabled and the scene is edited (convex/offmesh dirty or undo/redo),
    // a debounce countdown is (re)started. Once it reaches 0 a single save is
    // emitted to "<stem>__autosave.recastscene". ~45 frames ≈ 0.75 s at 60 fps.
    var auto_save: bool = true; // on by default
    var autosave_countdown: i32 = 0; // counts down from AUTOSAVE_DELAY to 0
    var autosave_pending: bool = false; // true while a debounced save is in flight
    const AUTOSAVE_DELAY: i32 = 45;
    var pending_delete: ?usize = null; // variant index awaiting delete confirmation

    // фикс-прямоугольники окон (как статичные окна RecastDemo по краям)
    var props_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var tools_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var log_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var test_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var flags_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var show_flags: bool = false; // the Poly Flags manager window (hidden by default)
    var test_choice: usize = 0;

    // --- Diagnostics: each heavy panel lives in its OWN floating window (toggled
    // by a checkbox in Properties → "Diagnostics"). Moved out of the Properties
    // scrollArea so the rows are not horizontally truncated. Default rects cascade
    // into the centre free area (Tools is left, Properties right, Log bottom);
    // wide (~440) so Build Inspector rows fit. Movable + resizable — these rect
    // vars persist user drags between frames.
    var show_validation: bool = false; // Validation (G1/G2) window
    var show_capture: bool = false; // Capture controls window
    const diag_base_x: f32 = 270; // tools column (250) + pad
    var build_inspector_win_rect: dvui.Rect = .{ .x = diag_base_x + 0, .y = 40, .w = 440, .h = 360 };
    var profiler_win_rect: dvui.Rect = .{ .x = diag_base_x + 30, .y = 70, .w = 440, .h = 360 };
    var memory_win_rect: dvui.Rect = .{ .x = diag_base_x + 60, .y = 100, .w = 440, .h = 300 };
    var validation_win_rect: dvui.Rect = .{ .x = diag_base_x + 90, .y = 130, .w = 440, .h = 380 };
    var capture_win_rect: dvui.Rect = .{ .x = diag_base_x + 120, .y = 160, .w = 440, .h = 280 };

    // bench-режим (--bench): камера крутится на 360°, без idle/cap, фикс число
    // кадров, затем печать средней нагрузки. Для профилирования под нагрузкой.
    var bench = false;
    var cycle_modes = false; // --cyclemodes: перебор всех draw-режимов (поиск крашей)
    var shot_draw: ?[]const u8 = null; // --draw=<имя>: фикс draw-режим для скриншот-сравнения
    var shot_cam: ?[5]f32 = null; // --cam=pitch,yaw,x,y,z: задать ракурс камеры для сравнения
    // --capture=<dir>,<frames>: write N PPM frames + manifest to <dir>, sweeping a full
    // 360° orbit deterministically (frame-count-driven), then auto-close. Reuses the bench
    // orbit machinery for the camera sweep. Headless-friendly (no UI interaction needed;
    // a GL window still must exist — true offscreen FBO is out of scope).
    var capture_state: capture.State = .{};
    var capture_headless = false; // set by --capture: auto-close the window after the run
    // --lint: after the startup build, run the navmesh linter over the active
    // sample's navMesh(), print findings to stdout, set the process exit code to
    // the error-count, and exit WITHOUT opening the GUI (clean headless CI path).
    var lint_headless = false;
    var verify_headless = false;
    {
        var it = try std.process.Args.Iterator.initAllocator(main_init.minimal.args, main_init.gpa);
        defer it.deinit();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--lint")) lint_headless = true;
            if (std.mem.eql(u8, a, "--verify")) verify_headless = true;
            if (std.mem.eql(u8, a, "--bench")) bench = true;
            if (std.mem.startsWith(u8, a, "--capture=")) {
                // "<dir>,<frames>" — split on the last comma so dir names may contain none.
                const spec = a["--capture=".len..];
                if (std.mem.lastIndexOfScalar(u8, spec, ',')) |ci| {
                    const dir_s = spec[0..ci];
                    const n = std.fmt.parseInt(u32, spec[ci + 1 ..], 10) catch 0;
                    if (dir_s.len > 0 and n > 0) {
                        capture_state.start(dir_s, n, .orbit);
                        capture_headless = true;
                        bench = true; // reuse the orbit machinery so the camera sweeps 360°
                    }
                }
            }
            if (std.mem.eql(u8, a, "--cyclemodes")) cycle_modes = true;
            if (std.mem.startsWith(u8, a, "--draw=")) {
                // дублируем в arena (it.next буфер переиспользуется)
                shot_draw = main_init.arena.allocator().dupe(u8, a["--draw=".len..]) catch null;
            }
            if (std.mem.startsWith(u8, a, "--cull=")) {
                dd_gl.cull_mode = std.fmt.parseInt(u8, a["--cull=".len..], 10) catch 1;
            }
            if (std.mem.startsWith(u8, a, "--cam=")) {
                var vals: [5]f32 = .{ 0, 0, 0, 0, 0 };
                var n: usize = 0;
                var t = std.mem.tokenizeScalar(u8, a["--cam=".len..], ',');
                while (t.next()) |s| : (n += 1) {
                    if (n >= 5) break;
                    vals[n] = std.fmt.parseFloat(f32, s) catch 0;
                }
                if (n >= 2) shot_cam = vals;
            }
        }
    }

    // --- --lint headless path: run the linter over the navmesh built at startup
    // (loadMeshIndex above already called solo.build(), so navMesh() is valid),
    // print findings, and exit with code = error-count. No GUI / frame loop.
    // Clean CI gate. Parsed AFTER the arg block so lint_headless is set.
    if (lint_headless) {
        runLintHeadless(main_init.gpa, solo.navMesh());
    }

    // --- --verify headless path: run the integrity verifier over the navmesh
    // built at startup, print violations, and exit with code = violation count
    // (clamped u8; 0 = clean for CI). Mirrors --lint exactly.
    if (verify_headless) {
        runVerifyHeadless(main_init.gpa, solo.navMesh());
    }

    if (shot_draw) |dm| {
        inline for (@typeInfo(@TypeOf(solo.draw_mode)).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, dm)) solo.draw_mode = @field(@TypeOf(solo.draw_mode), f.name);
        }
        app.show_tools = false; // чище для сравнения
    }
    if (shot_cam) |c| {
        cam.eulers = .{ c[0], c[1] };
        // pos задаём только если передан (не все нули) — иначе оставляем reset-камеру
        if (c[2] != 0 or c[3] != 0 or c[4] != 0) cam.pos = Vec3.init(c[2], c[3], c[4]);
    }
    var cycle_i: usize = 0;
    var cycle_frame: u32 = 0;
    const bench_secs: f64 = 10.0; // длительность прогона
    var bench_started = false;
    var bench_off = Vec3.init(0, 0, 0); // смещение глаза от центра (орбита)
    var bench_center = Vec3.init(0, 0, 0);
    var bench_yaw0: f32 = 0;
    var bench_angle: f32 = 0; // накопленный угол орбиты (градусы)
    var bench_ns: i128 = 0;
    var bench_frames: u64 = 0;
    var bench_draws: u64 = 0;

    // --- кадровый цикл ---
    tracy.setThreadName("main");
    tracy.appInfo("RecastDemo (zig)");
    var woke = true; // проснулись ли по событию (для beginWait/бёрста)
    var force_frames: u32 = 30; // бёрст полноскоростных кадров после события
    var prev_c = false; // edge-детект для клавиши C (переключение culling)
    var prev_p = false; // edge-детект для клавиши P (печать камеры)
    var prev_v = false; // edge-детект для клавиши V (вариант рендера вокселей)
    var prev_space = false; // edge-детект SPACE (run/pause толпы)
    var prev_step = false; // edge-детект "1" (single step толпы)
    var prev_undo = false; // edge-детект Ctrl+Z (undo)
    var prev_redo = false; // edge-детект Ctrl+Y / Ctrl+Shift+Z (redo)
    var geom_edited = false; // set when undo/redo changed geom -> trigger rebuild

    // F5 Properties inspector — staging buffers that mirror the SINGLE selected
    // object. `inspect_id`/`inspect_is_volume` track which object the buffers
    // currently reflect; when the single selection differs, they are re-seeded.
    var inspect_id: u32 = 0;
    var inspect_is_volume: bool = false;
    var inspect_vol: inspector.VolumeStaging = .{};
    var inspect_off: inspector.OffMeshStaging = .{};
    // F6 incremental rebuild: the geom edit-bbox from the PREVIOUS frame. Unioning
    // it with the post-edit bbox makes the dirty-tile set cover deletes too (the
    // deleted object was present last frame). Recomputed every frame below.
    var prev_geom_bbox: ?EditBBox = geomEditBBox(&geom);

    // Capture: in-memory manifest accumulated across frames, flushed durably on finish.
    var capture_manifest = std.array_list.Managed(u8).init(main_init.gpa);
    defer capture_manifest.deinit();
    var capture_dir_opened = false; // create the output dir once (on the first frame).

    while (!g_window.shouldClose()) {
        const frame_start = impl.nanoTime();

        if (bench) {
            // орбита вокруг центра сцены, чтобы геометрия всегда была в кадре.
            if (!bench_started) {
                bench_started = true;
                cam.reset(
                    Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]),
                    Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]),
                );
                bench_center = Vec3.init(
                    (geom.bmin[0] + geom.bmax[0]) * 0.5,
                    (geom.bmin[1] + geom.bmax[1]) * 0.5,
                    (geom.bmin[2] + geom.bmax[2]) * 0.5,
                );
                bench_off = cam.pos.sub(bench_center);
                bench_yaw0 = cam.eulers[1];
            }
            // Orbit step. In CAPTURE mode it is frame-count-driven (360°/total per
            // captured frame) so the N frames span exactly one revolution deterministically
            // — independent of wall-clock / FPS, for reproducible image sequences. In plain
            // --bench mode it stays the wall-clock-tuned ~36°/s sweep.
            if (capture_state.active and capture_state.total > 0) {
                bench_angle = @as(f32, @floatFromInt(capture_state.done)) * 360.0 /
                    @as(f32, @floatFromInt(capture_state.total));
            } else {
                bench_angle += 36.0 / 60.0; // ~36°/с при 60 эфф. кадров -> 360° за 10с
            }
            const a = bench_angle * std.math.pi / 180.0;
            const ca = @cos(a);
            const sa = @sin(a);
            // поворот смещения глаза вокруг оси Y + синхронный yaw = взгляд держит центр
            cam.pos = Vec3.init(
                bench_center.x + bench_off.x * ca + bench_off.z * sa,
                bench_center.y + bench_off.y,
                bench_center.z - bench_off.x * sa + bench_off.z * ca,
            );
            cam.eulers[1] = bench_yaw0 + bench_angle;
        }
        dd_gl.draw_calls = 0;
        dd_gl.verts_uploaded = 0;

        if (cycle_modes and sample_kind == .solo) {
            cycle_frame += 1;
            if (cycle_frame >= 25) {
                cycle_frame = 0;
                cycle_i += 1;
                const n_modes = @typeInfo(@TypeOf(solo.draw_mode)).@"enum".fields.len;
                if (cycle_i >= n_modes) {
                    std.debug.print("[CYCLE] all {d} draw modes survived\n", .{n_modes});
                    break;
                }
                solo.draw_mode = @enumFromInt(cycle_i);
            }
        }

        const fb = g_window.getFramebufferSize();
        const viewport = [4]i32{ 0, 0, fb[0], fb[1] };

        app.viewport = viewport;
        zgl.viewport(0, 0, @intCast(fb[0]), @intCast(fb[1]));

        // --- ввод камеры (если курсор не над UI) ---
        const cur = g_window.getCursorPos();
        const rmb = g_window.getMouseButton(.right) == .press;
        if (rmb and gate.pointerInScene()) {
            if (!rotating) {
                rotating = true;
                last_mouse = cur;
            }
            cam.rotate(@floatCast(cur[0] - last_mouse[0]), @floatCast(cur[1] - last_mouse[1]));
        } else {
            rotating = false;
        }
        last_mouse = cur;

        // масштаб скорости/зума от удаления камеры до центра сцены:
        // дальше -> быстрее, ближе -> медленнее (естественная навигация).
        const sc_x = (geom.bmin[0] + geom.bmax[0]) * 0.5;
        const sc_y = (geom.bmin[1] + geom.bmax[1]) * 0.5;
        const sc_z = (geom.bmin[2] + geom.bmax[2]) * 0.5;
        const ex = geom.bmax[0] - geom.bmin[0];
        const ey = geom.bmax[1] - geom.bmin[1];
        const ez = geom.bmax[2] - geom.bmin[2];
        const scene_r = @max(@as(f32, 1.0), 0.5 * @sqrt(ex * ex + ey * ey + ez * ez));
        const ddx = cam.pos.x - sc_x;
        const ddy = cam.pos.y - sc_y;
        const ddz = cam.pos.z - sc_z;
        const dist = @sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
        const dist_scale = std.math.clamp(dist / scene_r, 0.12, 6.0);

        // Управление с клавиатуры (WASD/QE/F) работает ВСЕГДА, независимо от того,
        // над панелью курсор или нет — как в оригинале (клавиатура не блокируется UI).
        // Только пикинг ЛКМ и зум колесом учитывают курсор над панелью.
        // База скорости подобрана так, чтобы сцена пересекалась за ~2с (как в оригинале);
        // dist_scale делает движение пропорциональным удалению.
        // Keyboard hotkeys (camera move, reset, render toggles) — suppressed while a
        // dvui text field has focus, so typing a name doesn't drive the camera or
        // toggle render modes.
        if (gate.keyboardFree()) {
        const base: f32 = if (g_window.getKey(.left_shift) == .press) @as(f32, 150.0) else 40.0;
        const d = base * dist_scale * dt;
        if (g_window.getKey(.w) == .press) cam.moveLocal(0, 0, -d);
        if (g_window.getKey(.s) == .press) cam.moveLocal(0, 0, d);
        if (g_window.getKey(.a) == .press) cam.moveLocal(-d, 0, 0);
        if (g_window.getKey(.d) == .press) cam.moveLocal(d, 0, 0);
        if (g_window.getKey(.q) == .press) cam.moveLocal(0, -d, 0);
        if (g_window.getKey(.e) == .press) cam.moveLocal(0, d, 0);
        // R — сброс вида (раньше было на F/Home; F освобождена под edit-режим).
        if (g_window.getKey(.r) == .press) {
            cam.reset(
                Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]),
                Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]),
            );
        }
        // K — переключить режим отсечения граней (0=off, 1=back, 2=front) для подбора winding.
        // (Раньше было на C — конфликтовало с Ctrl+C=copy в Select-инструменте: copy
        //  одновременно дёргал cull и ломал картинку.)
        const c_now = g_window.getKey(.k) == .press;
        if (c_now and !prev_c) {
            dd_gl.cull_mode = (dd_gl.cull_mode + 1) % 3;
            const names = [_][]const u8{ "off", "back", "front" };
            std.debug.print("[CULL] mode={s}\n", .{names[dd_gl.cull_mode]});
        }
        prev_c = c_now;
        // Клавиша P — печать текущей камеры в stderr (для воспроизведения ракурса).
        const p_now = g_window.getKey(.p) == .press;
        if (p_now and !prev_p) {
            std.debug.print("[CAM] --cam={d:.1},{d:.1},{d:.2},{d:.2},{d:.2}\n", .{ cam.eulers[0], cam.eulers[1], cam.pos.x, cam.pos.y, cam.pos.z });
        }
        prev_p = p_now;
        // Клавиша J — вариант рендера вокселей (8 шт). Активный вариант — в заголовке окна.
        // (Раньше было на V — конфликтовало с Ctrl+V=paste.)
        const vox_names = [_][:0]const u8{ "0:BASE mesh+fog+back+LEQUAL", "1:NO-MESH", "2:NO-FOG", "3:NO-MESH+NO-FOG", "4:CULL-OFF", "5:CULL-FRONT", "6:LESS", "7:NO-BLEND" };
        const v_now = g_window.getKey(.j) == .press;
        if (v_now and !prev_v) {
            dd_gl.voxel_variant +%= 1;
            std.debug.print("[VOXVAR] {s}\n", .{vox_names[dd_gl.voxel_variant % 8]});
        }
        prev_v = v_now;
        // --- Undo / Redo (scene edits, F1) — edge-triggered, gated by keyboardFree
        // (so it never fires while typing into a text field). Ctrl+Z = undo;
        // Ctrl+Y or Ctrl+Shift+Z = redo. One press = one action.
        {
            const ctrl = g_window.getKey(.left_control) == .press or g_window.getKey(.right_control) == .press;
            const shift_k = g_window.getKey(.left_shift) == .press or g_window.getKey(.right_shift) == .press;
            const z = g_window.getKey(.z) == .press;
            const y = g_window.getKey(.y) == .press;
            const t = g_window.getKey(.t) == .press;
            const undo_now = ctrl and z and !shift_k;
            const redo_now = ctrl and (y or t or (z and shift_k));
            if (undo_now and !prev_undo) {
                // Context-aware: when the convex tool is active, try removing the
                // last in-progress point first; fall through to the committed-edit
                // stack only if there are no in-progress points to pop.
                if (!(active_tool == .convex and convex_tool.undoPoint())) {
                    if (undo_stack.undo(&geom)) {
                        geom_edited = true;
                        inspect_id = 0; // force the Properties panel to re-seed from the reverted object
                    }
                }
            }
            if (redo_now and !prev_redo) {
                // Redo mirrors undo's GLOBAL order: in-progress points are always
                // newer than any committed edit, so undo pops points first then the
                // edit -> redo must re-apply the committed edit FIRST, then points.
                if (undo_stack.redo(&geom)) {
                    geom_edited = true;
                    inspect_id = 0; // re-seed the Properties panel after redo too
                } else if (active_tool == .convex) {
                    _ = convex_tool.redoPoint();
                }
            }
            prev_undo = undo_now;
            prev_redo = redo_now;
        }
        } // end keyboardFree hotkey gate
        // SPACE — run/pause симуляции толпы; "1" — один шаг (1-в-1 CrowdTool onToggle/singleStep).
        // Только для активного crowd-инструмента и не когда курсор над dvui-панелью.
        if (active_tool == .crowd and gate.pointerInScene() and gate.keyboardFree()) {
            const space_now = g_window.getKey(.space) == .press;
            if (space_now and !prev_space) crowd_tool.running = !crowd_tool.running;
            prev_space = space_now;
            const step_now = g_window.getKey(.one) == .press;
            if (step_now and !prev_step) crowd_tool.singleStep();
            prev_step = step_now;
        } else {
            prev_space = false;
            prev_step = false;
        }
        // зум колесом — только из 3D (g_scroll уже 0, если скролл потреблён панелью dvui)
        if (g_scroll != 0 and gate.pointerInScene()) {
            const zoom_step = @max(@as(f32, 0.5), dist * 0.1);
            cam.moveLocal(0, 0, @as(f32, @floatCast(-g_scroll)) * zoom_step);
        }
        g_scroll = 0;
        // Esc quits — but edge-triggered (only on a fresh press) and suppressed
        // while the area-type editor dialog is open (it consumes Esc to close
        // itself). Without the edge check, holding Esc would close the dialog one
        // frame and quit the app the next.
        {
            const esc_now = g_window.getKey(.escape) == .press;
            if (esc_now and !prev_esc and convex_tool.editor == null) g_window.setShouldClose(true);
            prev_esc = esc_now;
        }

        // ЛКМ (по фронту нажатия) -> клик в активный инструмент
        const lmb = gate.pointerInScene() and g_window.getMouseButton(.left) == .press;
        if (lmb and !prev_lmb) {
            // курсор в оконных координатах -> пиксели фреймбуфера (HiDPI/скейл дисплея)
            const win_sz = g_window.getSize();
            const sx: f64 = if (win_sz[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(win_sz[0])) else 1.0;
            const sy: f64 = if (win_sz[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(win_sz[1])) else 1.0;
            if (cam.pickRay(@floatCast(cur[0] * sx), @floatCast(cur[1] * sy), viewport)) |r| {
                if (pickPoint(&geom, r.start, r.end)) |h| {
                    const shift = g_window.getKey(.left_shift) == .press;
                    const ctrl_held = g_window.getKey(.left_control) == .press or g_window.getKey(.right_control) == .press;
                    const rs = r.start.toArray();
                    const hp = h.toArray();
                    if (sample_kind == .temp) {
                        temp.onClick(&rs, &hp, shift); // препятствия
                    } else switch (active_tool) {
                        .none => {
                            // Инспекция: клик по навмешу показывает инфо полигона под точкой
                            // в панели Polygon Inspector (B-4). Stderr-лог сохранён для
                            // headless-наблюдаемости.
                            // Inspection click: shows polygon info in the Polygon Inspector
                            // panel (B-4). stderr log kept for headless observability.
                            if (tester.query) |q| {
                                const ext = [3]f32{ 2, 4, 2 };
                                var ref: u32 = 0;
                                var poly_snap: [3]f32 = undefined;
                                _ = q.findNearestPoly(&hp, &ext, &tester.filter, &ref, &poly_snap) catch {};
                                if (ref != 0) {
                                    inspected_ref = ref; // B-4: store for panel
                                    const flags = if (tester.navmesh) |nm| (nm.getPolyFlags(ref) catch 0) else 0;
                                    std.debug.print("[POLY] ref={d} navmeshY={d:.2} clickHitY={d:.2} world=({d:.2},{d:.2},{d:.2}) flags=0x{x}\n", .{ ref, poly_snap[1], hp[1], poly_snap[0], poly_snap[1], poly_snap[2], flags });
                                } else {
                                    std.debug.print("[POLY] под кликом нет полигона (hitY={d:.2}, world x={d:.2} z={d:.2})\n", .{ hp[1], hp[0], hp[2] });
                                }
                            }
                        },
                        .tester => tester.onClick(&rs, &hp, shift),
                        .prune => prune_tool.onClick(&rs, &hp, shift),
                        .offmesh => blk: {
                            // Apply snap for edit tools (bypass if Ctrl held).
                            const use_snap = snap_cfg.mode != .off and !ctrl_held;
                            if (use_snap) {
                                const sr = snap_mod.snapPoint(&geom, hp, snap_cfg);
                                offmesh_tool.onClick(&rs, &sr.pos, shift);
                            } else {
                                offmesh_tool.onClick(&rs, &hp, shift);
                            }
                            break :blk;
                        },
                        .convex => blk: {
                            const use_snap = snap_cfg.mode != .off and !ctrl_held;
                            if (use_snap) {
                                const sr = snap_mod.snapPoint(&geom, hp, snap_cfg);
                                convex_tool.onClick(&rs, &sr.pos, shift);
                            } else {
                                convex_tool.onClick(&rs, &hp, shift);
                            }
                            break :blk;
                        },
                        .crowd => crowd_tool.onClick(&rs, &hp, shift),
                        .select => {
                            // F3 Select tool: Ctrl+LMB toggles the single object under
                            // the cursor (no drag begins). Plain LMB begins a rubber-band
                            // box (resolved on release). The release-side falling edge
                            // (below) finishes the box or treats a tiny drag as a click.
                            if (ctrl_held) {
                                if (selection_mod.hitTest(&geom, hp[0], hp[2], 0.5)) |hit| {
                                    switch (hit) {
                                        .volume => |id| {
                                            selection.toggleVolume(id) catch {};
                                            std.debug.print("[INFO] select: toggle volume id={d} (selected {d})\n", .{ id, selection.count() });
                                        },
                                        .offmesh => |id| {
                                            selection.toggleOffmesh(id) catch {};
                                            std.debug.print("[INFO] select: toggle off-mesh id={d} (selected {d})\n", .{ id, selection.count() });
                                        },
                                    }
                                }
                                sel_drag_start = null;
                                sel_drag_cur = null;
                            } else if (hitOnSelected(&geom, &selection, hp[0], hp[2])) {
                                // Click landed on an ALREADY-selected object -> begin a
                                // GROUP MOVE (not a box). Snapshot the BEFORE-state of every
                                // selected object so each frame recomputes verts from the
                                // snapshot + the live delta (drift-free). Box drag stays off.
                                move_snap.clearRetainingCapacity();
                                snapshotSelection(&geom, &selection, &move_snap);
                                move_drag_start = h;
                                sel_drag_start = null;
                                sel_drag_cur = null;
                            } else {
                                // Begin a box drag from this world point.
                                sel_drag_start = h;
                                sel_drag_cur = h;
                            }
                        },
                    }
                    pick_hit = h;
                }
            }
        }
        // Leaving the select tool mid-drag must drop any in-progress box so it
        // neither renders nor resolves after switching back.
        if (active_tool != .select and sel_drag_start != null) {
            sel_drag_start = null;
            sel_drag_cur = null;
        }
        // Leaving the select tool mid-MOVE must drop the move + free the snapshot
        // (mirrors the box cleanup above). The geom keeps whatever live delta was
        // applied so far — no undo is recorded for an abandoned move.
        if (active_tool != .select and move_drag_start != null) {
            move_drag_start = null;
            move_snap.clearRetainingCapacity();
        }
        // --- Select-tool rubber-band: per-frame update + release resolution (F3) ---
        // While LMB is held in the select tool with a drag in progress, recompute the
        // current world hit each frame (for drawing the box). On the falling edge,
        // either single-pick (tiny drag = click) or run the rubber-band rect select.
        if (active_tool == .select and sel_drag_start != null) {
            // Recompute the world point under the current cursor (same pickRay path).
            const win_sz2 = g_window.getSize();
            const sx2: f64 = if (win_sz2[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(win_sz2[0])) else 1.0;
            const sy2: f64 = if (win_sz2[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(win_sz2[1])) else 1.0;
            if (cam.pickRay(@floatCast(cur[0] * sx2), @floatCast(cur[1] * sy2), viewport)) |r2| {
                if (pickPoint(&geom, r2.start, r2.end)) |h2| sel_drag_cur = h2;
            }
            // Falling edge: LMB was down last frame, now up -> resolve the drag.
            if (prev_lmb and !lmb) {
                const start = sel_drag_start.?;
                const cur_w = sel_drag_cur orelse start;
                const adx = @abs(cur_w.x - start.x);
                const adz = @abs(cur_w.z - start.z);
                if (adx < 0.25 and adz < 0.25) {
                    // Tiny drag = click: replace selection with the single object under
                    // the release point (or clear if nothing is there).
                    selection.clear();
                    if (selection_mod.hitTest(&geom, cur_w.x, cur_w.z, 0.5)) |hit| {
                        switch (hit) {
                            .volume => |id| selection.toggleVolume(id) catch {},
                            .offmesh => |id| selection.toggleOffmesh(id) catch {},
                        }
                    }
                    std.debug.print("[INFO] select: click-pick -> {d} selected\n", .{selection.count()});
                } else {
                    selection_mod.rubberBand(&selection, &geom, start.x, start.z, cur_w.x, cur_w.z) catch {};
                    std.debug.print("[INFO] select: box -> {d} volume(s), {d} off-mesh selected\n", .{ selection.volumes.items.len, selection.offmesh.items.len });
                }
                sel_drag_start = null;
                sel_drag_cur = null;
            }
        }
        // --- Select-tool GROUP MOVE: per-frame live drag + release commit (F3 W2) ---
        // While LMB held with a move in progress, recompute the cursor world point and
        // re-apply (cur - anchor) XZ to every selected object FROM THE SNAPSHOT (not
        // incrementally). The highlight render redraws selected objects straight from
        // geom, so they follow the cursor automatically. On release, snap the final
        // anchor (unless Ctrl/snap-off), re-apply the committed delta, then record one
        // composite of edit_volume/edit_offmesh ops (skipped if the net move is ~0).
        if (active_tool == .select and move_drag_start != null) {
            const ctrl_held = g_window.getKey(.left_control) == .press or g_window.getKey(.right_control) == .press;
            const anchor = move_drag_start.?;
            // Current cursor world point (same pickRay path as the box drag).
            var cur_w = anchor;
            const win_sz3 = g_window.getSize();
            const sx3: f64 = if (win_sz3[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(win_sz3[0])) else 1.0;
            const sy3: f64 = if (win_sz3[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(win_sz3[1])) else 1.0;
            if (cam.pickRay(@floatCast(cur[0] * sx3), @floatCast(cur[1] * sy3), viewport)) |r3| {
                if (pickPoint(&geom, r3.start, r3.end)) |h3| cur_w = h3;
            }
            // Live (un-snapped) delta for drag feedback.
            applyMoveDelta(&geom, &move_snap, cur_w.x - anchor.x, cur_w.z - anchor.z);

            // Falling edge: LMB released -> commit the move.
            if (prev_lmb and !lmb) {
                // Snap the FINAL anchor world point (snap the anchor, delta = snapped -
                // start) unless snapping is off or Ctrl bypasses it for this drag.
                var dx = cur_w.x - anchor.x;
                var dz = cur_w.z - anchor.z;
                if (snap_cfg.mode != .off and !ctrl_held) {
                    const moved_anchor = [3]f32{ anchor.x + dx, anchor.y, anchor.z + dz };
                    const sr = snap_mod.snapPoint(&geom, moved_anchor, snap_cfg);
                    dx = sr.pos[0] - anchor.x;
                    dz = sr.pos[2] - anchor.z;
                }
                // Re-apply the committed (possibly snapped) delta one last time.
                applyMoveDelta(&geom, &move_snap, dx, dz);

                // No-op move (anchor barely shifted) -> don't pollute the undo stack.
                if (@abs(dx) < 1e-4 and @abs(dz) < 1e-4) {
                    // Restore exact snapshot (delta 0) so any float noise is erased.
                    applyMoveDelta(&geom, &move_snap, 0, 0);
                } else {
                    commitMove(main_init.gpa, &geom, &move_snap, &undo_stack);
                    geom_edited = true;
                    std.debug.print("[INFO] select: moved {d} object(s) by ({d:.3},{d:.3})\n", .{ move_snap.items.len, dx, dz });
                }
                move_drag_start = null;
                move_snap.clearRetainingCapacity();
            }
        }
        prev_lmb = lmb;

        // --- Select-tool COPY / PASTE (F3 W2) — Ctrl+C / Ctrl+V, edge-triggered,
        // gated by keyboardFree so they never fire while typing in a text field.
        if (active_tool == .select and gate.keyboardFree()) {
            const ctrl = g_window.getKey(.left_control) == .press or g_window.getKey(.right_control) == .press;
            const copy_now = ctrl and g_window.getKey(.c) == .press;
            const paste_now = ctrl and g_window.getKey(.v) == .press;
            if (copy_now and !prev_copy and !selection.isEmpty()) {
                doCopy(&clipboard, &geom, &selection);
            }
            if (paste_now and !prev_paste and !clipboard.isEmpty()) {
                doPaste(main_init.gpa, &clipboard, &geom, &selection, &undo_stack);
                geom_edited = true;
            }
            prev_copy = copy_now;
            prev_paste = paste_now;
        } else {
            prev_copy = false;
            prev_paste = false;
        }

        // --- Group delete (F3): Del key in select tool removes all selected objects
        // as ONE composite edit. Edge-triggered, gated by keyboardFree (so it never
        // fires while typing in a dvui text field). Descending-index deletes keep the
        // index math stable; composite.revert (reverse order) re-inserts exactly.
        if (active_tool == .select and gate.keyboardFree()) {
            const del_now = g_window.getKey(.delete) == .press;
            if (del_now and !prev_delete and !selection.isEmpty()) {
                deleteSelected(main_init.gpa, &geom, &selection, &undo_stack);
                selection.clear();
                geom_edited = true;
            }
            prev_delete = del_now;
        } else {
            prev_delete = false;
        }

        // перестройка navmesh, если инструмент изменил геометрию (или undo/redo
        // изменил geom — F1: navmesh должен отразить откат/повтор правки).
        // Auto-save: capture the edit condition BEFORE dirty flags are cleared so the
        // autosave debouncer can observe it without disturbing the rebuild path.
        const edited_this_frame = offmesh_tool.dirty or convex_tool.dirty or geom_edited;
        if (edited_this_frame) {
            offmesh_tool.dirty = false;
            convex_tool.dirty = false;
            geom_edited = false;
            area_types.rebuild_needed = false; // satisfied by this rebuild
            switch (sample_kind) {
                .solo => _ = solo.build(),
                .tile => {
                    // F6: incremental rebuild for Tile when enabled and a navmesh
                    // already exists. Mark the tiles touched by this edit (union of
                    // the bbox BEFORE the edit — covers deletes — with the bbox AFTER),
                    // then rebuild only those. Falls back to a full build otherwise.
                    if (tile.incremental and tile.navMesh() != null) {
                        const cur_bbox = geomEditBBox(&geom);
                        if (prev_geom_bbox) |b| tile.markDirtyBBox(b.minx, b.minz, b.maxx, b.maxz);
                        if (cur_bbox) |b| tile.markDirtyBBox(b.minx, b.minz, b.maxx, b.maxz);
                        if (tile.dirtyCount() > 0) {
                            const n = tile.rebuildDirty();
                            bctx.context().log(.progress, "Incremental rebuild: {d} tile(s)", .{n});
                        } else {
                            // No locatable edit bbox (e.g. all geometry cleared) -> full build.
                            _ = tile.build();
                        }
                    } else {
                        _ = tile.build();
                    }
                },
                .temp => _ = temp.build(),
            }
        }
        // Track the current geom edit-bbox for next frame's delete-coverage union.
        prev_geom_bbox = geomEditBBox(&geom);

        // Auto-save debounce: (re)start the countdown on each edit; fire once settled.
        // If auto_save is turned off, cancel any pending save so turning it back on
        // doesn't fire for a stale countdown from a previous session.
        if (!auto_save) {
            autosave_pending = false;
            autosave_countdown = 0;
        }
        if (auto_save and sample_kind == .solo and edited_this_frame) {
            autosave_pending = true;
            autosave_countdown = AUTOSAVE_DELAY;
        }
        if (autosave_pending and auto_save and autosave_countdown > 0) {
            autosave_countdown -= 1;
        }
        if (autosave_pending and auto_save and autosave_countdown == 0) {
            autosave_pending = false;
            // Determine the current mesh stem (same logic as Scene Persistence UI).
            const as_cur_name: []const u8 = if (mesh_files.len > 0 and mesh_choice < mesh_files.len)
                mesh_files[mesh_choice]
            else
                "scene.obj";
            const as_cur_stem = stemOf(as_cur_name);
            saveSceneNow(main_init.gpa, &geom, &solo, app.meshes_folder, as_cur_name, "autosave", &bctx);
            bctx.context().log(.progress, "Auto-saved scene ({s}__autosave)", .{as_cur_stem});
            // Refresh the variant list so "autosave" appears in the Load panel.
            rebuildVariants(main_init.gpa, app.meshes_folder, as_cur_stem, &variants, &variants_stem, &bctx);
        }

        // Area-type cost edits apply at runtime (re-push into the live filters).
        if (area_types.costs_dirty) {
            area_types.costs_dirty = false;
            area_types.applyCosts(&tester.filter);
            crowd_tool.reapplyAreaCosts();
        }
        // Flag edits / added/removed types are baked into tile data -> rebuild.
        // Done automatically here only when the Rebuild mini-tool's auto toggle is on;
        // otherwise it just notifies and waits for a manual Rebuild.
        if (area_types.rebuild_needed and area_types.auto_rebuild) {
            area_types.rebuild_needed = false;
            switch (sample_kind) {
                .solo => _ = solo.build(),
                .tile => _ = tile.build(),
                .temp => _ = temp.build(),
            }
        }

        // синхронизация инструментов при перестройке активного сэмпла
        {
            const gen = switch (sample_kind) {
                .solo => solo.build_gen,
                .tile => tile.build_gen,
                .temp => temp.build_gen,
            };
            if (gen != last_gen or sample_kind != prev_sample_kind) {
                last_gen = gen;
                prev_sample_kind = sample_kind;
                const nm = switch (sample_kind) {
                    .solo => solo.navMesh(),
                    .tile => tile.navMesh(),
                    .temp => temp.navMesh(),
                };
                tester.setNavMesh(nm);
                crowd_tool.setNavMesh(nm);
                prune_tool.setNavMesh(nm);
                const st = switch (sample_kind) {
                    .solo => solo.settings,
                    .tile => tile.settings,
                    .temp => temp.settings,
                };
                tester.setAgent(st.agent_radius, st.agent_height, st.agent_max_climb);
                prune_tool.setAgent(st.agent_radius);
                crowd_tool.agent_radius = st.agent_radius;
                crowd_tool.agent_height = st.agent_height;
            }
        }

        // симуляция толпы + tilecache
        crowd_tool.update(dt);
        if (sample_kind == .temp) temp.update(dt);

        // 1) наш 3D-проход
        const z_r3d = tracy.zone(@src(), "render3d");
        // dvui backend.begin() КАЖДЫЙ кадр делает disable(DEPTH_TEST)+depthMask(FALSE) и
        // не восстанавливает (end() пустой). Init-стейта (стр.118) хватает лишь на 1-й кадр —
        // дальше 3D-проход рисуется без depth-теста (painter's order: дальние воксели затирают
        // ближние -> «просвечивание сквозь крышу»). Восстанавливаем depth-стейт каждый кадр.
        // depthMask(true) ОБЯЗАТЕЛЬНО до clear: glClear(depth) уважает depthMask=FALSE и иначе
        // не очистит depth-буфер.
        zgl.depthMask(true);
        zgl.enable(.depth_test);
        zgl.depthFunc(.less_or_equal);
        // dvui opengl-backend каждый кадр ставит premultiplied blend (blendFunc(ONE,
        // ONE_MINUS_SRC_ALPHA)) и не восстанавливает. Наши debug-цвета — straight-alpha
        // (НЕ premult), поэтому в premult-режиме RGB добавляется на полную, игнорируя
        // alpha -> навмеш насыщенный cyan вместо бледного azure, а полупрозрачные
        // оверлеи (линии соседей, convex-fill) перекрашиваются фоном. Возвращаем
        // straight-alpha blend каждый кадр (как glBlendFunc в RecastDemo/main.cpp:320).
        zgl.enable(.blend);
        zgl.blendFunc(.src_alpha, .one_minus_src_alpha);
        zgl.clearColor(0.3, 0.3, 0.32, 1.0); // как RecastDemo (фон ≈ цвет тумана)
        zgl.clear(.{ .color = true, .depth = true, .stencil = true });

        const aspect: f32 = @as(f32, @floatFromInt(fb[0])) / @as(f32, @floatFromInt(fb[1]));
        dd_gl.setMvp(cam.proj(aspect).mul(cam.view()).m);
        dd_gl.setViewport(fb[0], fb[1]);

        switch (sample_kind) {
            .solo => solo.render(),
            .tile => tile.render(),
            .temp => temp.render(),
        }
        switch (active_tool) {
            .none => {},
            .tester => tester.render(),
            .prune => prune_tool.render(),
            .offmesh => offmesh_tool.render(),
            .convex => convex_tool.render(),
            .crowd => crowd_tool.render(),
            .select => {},
        }

        // --- Select-tool highlight overlay (F3) -------------------------------
        // Bright-yellow XZ outlines for selected volumes, highlighted markers for
        // selected off-mesh endpoints, and the in-progress rubber-band rectangle.
        if (active_tool == .select) {
            const hl = recast.debug.rgba(255, 255, 0, 255); // bright yellow highlight
            // Selected convex volumes: closed XZ line-loop at the volume's hmax height.
            for (geom.volumes.items) |*vol| {
                if (!selection.containsVolume(vol.id)) continue;
                const n: usize = @intCast(vol.nverts);
                if (n < 2) continue;
                const hy = vol.hmax;
                dd.begin(.lines, 3.0);
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const a = k * 3;
                    const b = ((k + 1) % n) * 3;
                    dd.vertexXYZ(vol.verts[a + 0], hy, vol.verts[a + 2], hl);
                    dd.vertexXYZ(vol.verts[b + 0], hy, vol.verts[b + 2], hl);
                }
                dd.end();
            }
            // Selected off-mesh links: highlight both endpoints with a small cross.
            var oi: usize = 0;
            while (oi < geom.offMeshCount()) : (oi += 1) {
                if (!selection.containsOffmesh(geom.off_id.items[oi])) continue;
                const v = geom.off_verts.items[oi * 6 ..][0..6];
                dd.begin(.lines, 3.0);
                for ([_]usize{ 0, 3 }) |o| {
                    const ex2 = v[o + 0];
                    const ey2 = v[o + 1];
                    const ez2 = v[o + 2];
                    dd.vertexXYZ(ex2 - 0.4, ey2, ez2, hl);
                    dd.vertexXYZ(ex2 + 0.4, ey2, ez2, hl);
                    dd.vertexXYZ(ex2, ey2, ez2 - 0.4, hl);
                    dd.vertexXYZ(ex2, ey2, ez2 + 0.4, hl);
                    dd.vertexXYZ(ex2, ey2, ez2, hl);
                    dd.vertexXYZ(ex2, ey2 + 0.8, ez2, hl);
                }
                dd.end();
            }
            // In-progress rubber-band rectangle on the ground at the start height.
            if (sel_drag_start) |s| {
                if (sel_drag_cur) |c| {
                    const ry = s.y;
                    const x0 = s.x;
                    const z0 = s.z;
                    const x1 = c.x;
                    const z1 = c.z;
                    const rc = recast.debug.rgba(255, 255, 120, 255);
                    dd.begin(.lines, 2.0);
                    dd.vertexXYZ(x0, ry, z0, rc);
                    dd.vertexXYZ(x1, ry, z0, rc);
                    dd.vertexXYZ(x1, ry, z0, rc);
                    dd.vertexXYZ(x1, ry, z1, rc);
                    dd.vertexXYZ(x1, ry, z1, rc);
                    dd.vertexXYZ(x0, ry, z1, rc);
                    dd.vertexXYZ(x0, ry, z1, rc);
                    dd.vertexXYZ(x0, ry, z0, rc);
                    dd.end();
                }
            }
        }

        // --- Lint highlight overlay (G1) --------------------------------------
        // When "Highlight findings" is on, overdraw each cached finding's culprit
        // polys in a warning colour (reuses the tester's debugDrawNavMeshPoly
        // pattern). Off-mesh/orphan refs that aren't ground polys are skipped by
        // the draw helper (bad ref -> no-op).
        if (lint_highlight) {
            if (lint_report) |*rep| {
                const active_nav: ?*recast.detour.NavMesh = switch (sample_kind) {
                    .solo => solo.navMesh(),
                    .tile => tile.navMesh(),
                    .temp => temp.navMesh(),
                };
                if (active_nav) |nm| {
                    // Bright BEACONS first (full alpha, hard to miss): the faithful
                    // poly fill forces alpha 64 and was nearly invisible. Draw a tall
                    // vertical line + a cross at each finding poly's centroid in the
                    // severity colour at full opacity. depthMask(false) so they show
                    // through the navmesh.
                    dd.depthMask(false);
                    dd.begin(.lines, 3.0);
                    for (rep.findings.items) |*f| {
                        const bcol = switch (f.severity) {
                            .err => recast.debug.rgba(255, 40, 40, 255),
                            .warn => recast.debug.rgba(255, 210, 30, 255),
                            .info => recast.debug.rgba(90, 170, 255, 255),
                        };
                        for (0..f.ref_count) |i| {
                            if (f.refs[i] == 0) continue;
                            const tp = nm.getTileAndPolyByRef(f.refs[i]) catch continue;
                            // centroid (bounds-safe avg of the poly's tile verts)
                            var cx: f32 = 0;
                            var cy: f32 = 0;
                            var cz: f32 = 0;
                            const vc: usize = tp.poly.vert_count;
                            if (vc == 0) continue;
                            var got: usize = 0;
                            for (0..vc) |k| {
                                const vi = @as(usize, tp.poly.verts[k]) * 3;
                                if (vi + 2 >= tp.tile.verts.len) continue;
                                cx += tp.tile.verts[vi];
                                cy += tp.tile.verts[vi + 1];
                                cz += tp.tile.verts[vi + 2];
                                got += 1;
                            }
                            if (got == 0) continue;
                            const fg: f32 = @floatFromInt(got);
                            cx /= fg;
                            cy /= fg;
                            cz /= fg;
                            // tall beacon
                            dd.vertexXYZ(cx, cy, cz, bcol);
                            dd.vertexXYZ(cx, cy + 6.0, cz, bcol);
                            // small cross at the base
                            dd.vertexXYZ(cx - 0.6, cy + 0.1, cz, bcol);
                            dd.vertexXYZ(cx + 0.6, cy + 0.1, cz, bcol);
                            dd.vertexXYZ(cx, cy + 0.1, cz - 0.6, bcol);
                            dd.vertexXYZ(cx, cy + 0.1, cz + 0.6, bcol);
                        }
                    }
                    dd.end();
                    dd.depthMask(true);
                    // Faint poly fill on top (the existing tint), guarded against stale refs.
                    for (rep.findings.items) |*f| {
                        const col = switch (f.severity) {
                            .err => recast.debug.rgba(235, 60, 60, 160),
                            .warn => recast.debug.rgba(235, 200, 50, 160),
                            .info => recast.debug.rgba(120, 180, 235, 160),
                        };
                        for (0..f.ref_count) |i| {
                            if (f.refs[i] == 0) continue;
                            if (@as(usize, nm.decodePolyId(f.refs[i]).tile) >= nm.tiles.len) continue;
                            if (nm.isValidPolyRef(f.refs[i])) recast.debug.debugDrawNavMeshPoly(dd, nm, f.refs[i], col);
                        }
                    }
                }
            }
        }

        // тест-кейсы: посчитать пути один раз (когда query привязан к нужному сэмплу), затем рисовать кеш
        if (active_test) |*t| {
            if (!t.computed) {
                if (tester.query) |q| t.compute(q);
            }
            if (t.computed) t.render(dd);
        }

        if (pick_hit) |h| {
            const col = recast.debug.rgba(255, 200, 0, 255);
            dd.begin(.lines, 2.0);
            dd.vertexXYZ(h.x - 0.5, h.y, h.z, col);
            dd.vertexXYZ(h.x + 0.5, h.y, h.z, col);
            dd.vertexXYZ(h.x, h.y, h.z - 0.5, col);
            dd.vertexXYZ(h.x, h.y, h.z + 0.5, col);
            dd.vertexXYZ(h.x, h.y, h.z, col);
            dd.vertexXYZ(h.x, h.y + 1.0, h.z, col);
            dd.end();
        }

        // Snap hover marker: every frame when an edit tool is active and snap is on,
        // show a small cross at the snap target UNDER THE CURSOR (live), so the snap
        // target follows the mouse instead of only updating on click — without this
        // there's no feedback and snap "looks broken". Falls back to the last
        // pick_hit when the cursor is over a panel. Color by kind:
        // vertex=yellow, edge=cyan, grid=white, object=magenta.
        if ((active_tool == .convex or active_tool == .offmesh) and snap_cfg.mode != .off) {
            var hover_src: ?Vec3 = null;
            if (gate.pointerInScene()) {
                const hsz = g_window.getSize();
                const hsx: f64 = if (hsz[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(hsz[0])) else 1.0;
                const hsy: f64 = if (hsz[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(hsz[1])) else 1.0;
                if (cam.pickRay(@floatCast(cur[0] * hsx), @floatCast(cur[1] * hsy), viewport)) |hr| {
                    hover_src = pickPoint(&geom, hr.start, hr.end);
                }
            }
            if (hover_src orelse pick_hit) |ph| {
                const snap_hover = snap_mod.snapPoint(&geom, ph.toArray(), snap_cfg);
                if (snap_hover.kind != .off) {
                    const sm_col: u32 = switch (snap_hover.kind) {
                        .vertex => recast.debug.rgba(255, 230, 0, 255),
                        .edge => recast.debug.rgba(0, 220, 220, 255),
                        .grid => recast.debug.rgba(255, 255, 255, 255),
                        .object => recast.debug.rgba(220, 0, 220, 255),
                        .off => recast.debug.rgba(128, 128, 128, 255),
                    };
                    const sp = snap_hover.pos;
                    const sm_r: f32 = 0.3; // marker arm length
                    dd.begin(.lines, 2.5);
                    dd.vertexXYZ(sp[0] - sm_r, sp[1], sp[2], sm_col);
                    dd.vertexXYZ(sp[0] + sm_r, sp[1], sp[2], sm_col);
                    dd.vertexXYZ(sp[0], sp[1], sp[2] - sm_r, sm_col);
                    dd.vertexXYZ(sp[0], sp[1], sp[2] + sm_r, sm_col);
                    dd.vertexXYZ(sp[0], sp[1], sp[2], sm_col);
                    dd.vertexXYZ(sp[0], sp[1] + sm_r * 2.0, sp[2], sm_col);
                    dd.end();
                }
            }
        }

        z_r3d.end(); // конец 3D-прохода
        tracy.plotF("draw_calls", @floatFromInt(dd_gl.draw_calls));
        tracy.plotF("verts", @floatFromInt(dd_gl.verts_uploaded));

        // 2) события -> dvui
        const z_dvui = tracy.zone(@src(), "dvui");
        {
            const z = tracy.zone(@src(), "dvui.events");
            defer z.end();
            impl.addAllEvents(&win);
        }

        // 3) кадр dvui (рисует поверх нашего 3D)
        try win.begin(win.beginWait(woke));

        // фикс-позиции окон по краям (как staticWindowFlags RecastDemo)
        {
            const wr = dvui.windowRect();
            const colw: f32 = 250;
            const padw: f32 = 10;
            const logh: f32 = 200;
            props_rect = .{ .x = wr.w - colw - padw, .y = padw, .w = colw, .h = wr.h - 2 * padw };
            tools_rect = .{ .x = padw, .y = padw, .w = colw, .h = wr.h - 2 * padw };
            log_rect = .{ .x = colw + 2 * padw, .y = wr.h - logh - padw, .w = wr.w - 2 * colw - 4 * padw, .h = logh };
            test_rect = .{ .x = wr.w - padw - colw - padw - 200, .y = wr.h - padw - 450, .w = 200, .h = 450 };
            // Poly Flags manager — just left of the Properties panel, only shown when
            // toggled on. Wide enough that the flag rows / hints don't clip.
            // Height fits the flag count (header + desc + N rows + add row), so no
            // empty space below for the default 4 flags.
            // +200 for the F4 preset section (Save row + dropdown + radios + Apply).
            const fh: f32 = 116 + 200 + @as(f32, @floatFromInt(poly_flags.count())) * 28;
            flags_rect = .{ .x = wr.w - colw - 3 * padw - 380, .y = padw, .w = 380, .h = fh };
            // P1-4 minimap — bottom-left, above the Tools column's lower edge.
            const mmw: f32 = 260;
            const mmh: f32 = 320;
            minimap_rect = .{ .x = colw + 3 * padw, .y = wr.h - mmh - padw, .w = mmw, .h = mmh };
        }

        // --- Tools (левая колонка) ---
        if (app.show_tools) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &tools_rect, .resize = .none, .window_avoid = .none }, .{ .id_extra = 1 });
            defer fw.deinit();
            _ = dvui.windowHeader("Tools", "", &app.show_tools);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();

            if (sample_kind == .temp) {
                ui.section(@src(), "Create Temp Obstacles");
                dvui.labelNoFmt(@src(), "LMB: add  Shift+LMB: remove", .{}, .{});
            } else {
                ui.section(@src(), "Tool Selection");
                for (tool_registry.entries) |e| {
                    if (ui.radio(@src(), active_tool == e.id, e.label, e.radio_id)) active_tool = e.id;
                }

                ui.section(@src(), "Tool Settings");
                switch (active_tool) {
                    .none => {},
                    .tester => tester.drawMenu(),
                    .prune => prune_tool.drawMenu(),
                    .offmesh => offmesh_tool.drawMenu(),
                    .convex => convex_tool.drawMenu(),
                    .crowd => crowd_tool.drawMenu(),
                    .select => {
                        // F3 selection panel: live count + clear / delete buttons.
                        dvui.label(@src(), "Selected: {d} volume(s), {d} off-mesh", .{ selection.volumes.items.len, selection.offmesh.items.len }, .{});
                        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                        defer row.deinit();
                        if (dvui.button(@src(), "Clear selection", .{ .grayed = selection.isEmpty() }, .{ .id_extra = 980 })) {
                            selection.clear();
                        }
                        if (dvui.button(@src(), "Delete selected", .{ .grayed = selection.isEmpty() }, .{ .id_extra = 981 })) {
                            if (!selection.isEmpty()) {
                                deleteSelected(main_init.gpa, &geom, &selection, &undo_stack);
                                selection.clear();
                                geom_edited = true;
                            }
                        }
                        // Copy / Paste mirror the Ctrl+C / Ctrl+V hotkeys (F3 W2).
                        var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                        defer row2.deinit();
                        if (dvui.button(@src(), "Copy (Ctrl+C)", .{ .grayed = selection.isEmpty() }, .{ .id_extra = 982 })) {
                            if (!selection.isEmpty()) doCopy(&clipboard, &geom, &selection);
                        }
                        if (dvui.button(@src(), "Paste (Ctrl+V)", .{ .grayed = clipboard.isEmpty() }, .{ .id_extra = 983 })) {
                            if (!clipboard.isEmpty()) {
                                doPaste(main_init.gpa, &clipboard, &geom, &selection, &undo_stack);
                                geom_edited = true;
                            }
                        }

                        // --- F5 Properties inspector (single-selection only) ---
                        if (selection.count() == 1) {
                            if (selection.volumes.items.len == 1) {
                                // Resolve the live volume by its stable id.
                                const sel_id = selection.volumes.items[0];
                                var vi: ?usize = null;
                                for (geom.volumes.items, 0..) |*v, i| {
                                    if (v.id == sel_id) vi = i;
                                }
                                if (vi) |idx| {
                                    const live = geom.volumes.items[idx];
                                    // Re-seed staging when the selected object changed.
                                    if (!(inspect_is_volume and inspect_id == sel_id)) {
                                        inspect_vol = inspector.VolumeStaging.seed(live);
                                        inspect_id = sel_id;
                                        inspect_is_volume = true;
                                    }
                                    ui.section(@src(), "Properties — Volume");
                                    dvui.label(@src(), "id: {d}", .{sel_id}, .{});
                                    // Mode radios (prism/surface).
                                    if (ui.radio(@src(), inspect_vol.mode == .prism, "Prism (flat box)", 940))
                                        inspect_vol.mode = .prism;
                                    if (ui.radio(@src(), inspect_vol.mode == .surface, "Surface (draped slab)", 941))
                                        inspect_vol.mode = .surface;
                                    _ = dvui.sliderEntry(@src(), "hmin {d:.2}", .{ .value = &inspect_vol.hmin, .min = -100, .max = 100, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "hmax {d:.2}", .{ .value = &inspect_vol.hmax, .min = -100, .max = 100, .interval = null }, .{ .expand = .horizontal });
                                    if (inspect_vol.mode == .surface) {
                                        _ = dvui.sliderEntry(@src(), "band below {d:.2}", .{ .value = &inspect_vol.band_below, .min = 0, .max = 50, .interval = null }, .{ .expand = .horizontal });
                                        _ = dvui.sliderEntry(@src(), "band above {d:.2}", .{ .value = &inspect_vol.band_above, .min = 0, .max = 50, .interval = null }, .{ .expand = .horizontal });
                                    }
                                    // Area dropdown — only `used` area types are offered.
                                    inspectorAreaDropdown(&inspect_vol.area);

                                    var arow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                                    defer arow.deinit();
                                    if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 942 })) {
                                        const before = live;
                                        const after = inspector.buildAfterVolume(live, inspect_vol);
                                        geom.volumes.items[idx] = after; // mutate live (id-keyed index)
                                        undo_stack.record(.{ .edit_volume = .{ .id = sel_id, .before = before, .after = after } });
                                        geom_edited = true;
                                        inspect_vol = inspector.VolumeStaging.seed(after); // re-seed
                                        std.debug.print("[INFO] inspector: applied edit to volume id {d}\n", .{sel_id});
                                    }
                                    if (dvui.button(@src(), "Revert", .{}, .{ .id_extra = 943 })) {
                                        inspect_vol = inspector.VolumeStaging.seed(live);
                                    }
                                }
                            } else if (selection.offmesh.items.len == 1) {
                                // Resolve the live off-mesh by off_id.
                                const sel_id = selection.offmesh.items[0];
                                var oi: ?usize = null;
                                for (geom.off_id.items, 0..) |oid, i| {
                                    if (oid == sel_id) oi = i;
                                }
                                if (oi) |idx| {
                                    const live = edit_op.OffMeshData.capture(&geom, idx);
                                    if (!(!inspect_is_volume and inspect_id == sel_id)) {
                                        inspect_off = inspector.OffMeshStaging.seed(live);
                                        inspect_id = sel_id;
                                        inspect_is_volume = false;
                                    }
                                    ui.section(@src(), "Properties — Off-Mesh");
                                    dvui.label(@src(), "id: {d}", .{sel_id}, .{});
                                    dvui.labelNoFmt(@src(), "Start (x,y,z)", .{}, .{});
                                    _ = dvui.sliderEntry(@src(), "sx {d:.2}", .{ .value = &inspect_off.start[0], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "sy {d:.2}", .{ .value = &inspect_off.start[1], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "sz {d:.2}", .{ .value = &inspect_off.start[2], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    dvui.labelNoFmt(@src(), "End (x,y,z)", .{}, .{});
                                    _ = dvui.sliderEntry(@src(), "ex {d:.2}", .{ .value = &inspect_off.end[0], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "ey {d:.2}", .{ .value = &inspect_off.end[1], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "ez {d:.2}", .{ .value = &inspect_off.end[2], .min = -1000, .max = 1000, .interval = null }, .{ .expand = .horizontal });
                                    _ = dvui.sliderEntry(@src(), "radius {d:.2}", .{ .value = &inspect_off.rad, .min = 0, .max = 50, .interval = null }, .{ .expand = .horizontal });
                                    // Direction toggle (0 = one-way, 1 = bidirectional).
                                    {
                                        var biz = inspect_off.dir != 0;
                                        if (dvui.checkbox(@src(), &biz, "Bidirectional", .{ .id_extra = 944 }))
                                            inspect_off.dir = if (biz) 1 else 0;
                                    }
                                    inspectorAreaDropdown(&inspect_off.area);
                                    // Flags — one checkbox per registered (non-reserved) poly flag.
                                    dvui.labelNoFmt(@src(), "Flags", .{}, .{});
                                    {
                                        var fi: usize = 0;
                                        while (fi < poly_flags.MAX_FLAGS) : (fi += 1) {
                                            const fl = poly_flags.get(fi) orelse continue;
                                            const bit = poly_flags.bitOf(fi).?;
                                            var on = (inspect_off.flags & bit) != 0;
                                            if (dvui.checkbox(@src(), &on, fl.name(), .{ .id_extra = 950 + fi })) {
                                                if (on) inspect_off.flags |= bit else inspect_off.flags &= ~bit;
                                            }
                                        }
                                    }

                                    var orow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                                    defer orow.deinit();
                                    if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 945 })) {
                                        const before = live;
                                        const after = inspector.buildAfterOffmesh(live, inspect_off);
                                        // Mutate live via the op, then record (one edit_offmesh).
                                        const op = edit_op.EditOp{ .edit_offmesh = .{ .id = sel_id, .before = before, .after = after } };
                                        op.apply(&geom);
                                        undo_stack.record(op);
                                        geom_edited = true;
                                        inspect_off = inspector.OffMeshStaging.seed(after); // re-seed
                                        std.debug.print("[INFO] inspector: applied edit to off-mesh id {d}\n", .{sel_id});
                                    }
                                    if (dvui.button(@src(), "Revert", .{}, .{ .id_extra = 946 })) {
                                        inspect_off = inspector.OffMeshStaging.seed(live);
                                    }
                                }
                            }
                        } else {
                            // Not a single selection — reset so it re-seeds next time.
                            inspect_id = 0;
                        }
                    },
                }

                // Snap UI: shown only for edit tools (convex / offmesh).
                if (active_tool == .convex or active_tool == .offmesh) {
                    ui.section(@src(), "Snap");
                    if (ui.radio(@src(), snap_cfg.mode == .off, "Off", 330)) snap_cfg.mode = .off;
                    if (ui.radio(@src(), snap_cfg.mode == .vertex, "Vertex", 331)) snap_cfg.mode = .vertex;
                    if (ui.radio(@src(), snap_cfg.mode == .edge, "Edge", 332)) snap_cfg.mode = .edge;
                    if (ui.radio(@src(), snap_cfg.mode == .grid, "Grid", 333)) snap_cfg.mode = .grid;
                    if (ui.radio(@src(), snap_cfg.mode == .object, "Object", 334)) snap_cfg.mode = .object;
                    if (snap_cfg.mode == .grid) {
                        ui.slider(@src(), "Grid step = {d:.2}", &snap_cfg.grid_step, 0.1, 8.0);
                    }
                    if (snap_cfg.mode == .vertex or snap_cfg.mode == .edge or snap_cfg.mode == .object) {
                        ui.slider(@src(), "Snap radius = {d:.1}", &snap_cfg.radius, 0.1, 5.0);
                    }
                    dvui.labelNoFmt(@src(), "Ctrl: bypass snap for this click", .{}, .{});
                }
            }

            // --- Edit History (F1: undo/redo for scene edits) ---
            ui.section(@src(), "Edit History");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer row.deinit();
                const can_u = undo_stack.canUndo();
                const can_r = undo_stack.canRedo();
                // When convex tool is active with in-progress points, the buttons
                // operate on point-level undo/redo first (same priority as Ctrl+Z/Y).
                const convex_has_pts = active_tool == .convex and convex_tool.numPoints() > 0;
                const convex_has_popped = active_tool == .convex and convex_tool.popped_pts.items.len >= 3;
                if (dvui.button(@src(), "Undo", .{ .grayed = !can_u and !convex_has_pts }, .{ .id_extra = 970 })) {
                    if (!(active_tool == .convex and convex_tool.undoPoint())) {
                        if (can_u and undo_stack.undo(&geom)) {
                            geom_edited = true;
                            inspect_id = 0; // re-seed Properties panel from the reverted object
                        }
                    }
                }
                if (dvui.button(@src(), "Redo", .{ .grayed = !can_r and !convex_has_popped }, .{ .id_extra = 971 })) {
                    if (can_r and undo_stack.redo(&geom)) {
                        geom_edited = true;
                        inspect_id = 0; // re-seed Properties panel after redo
                    } else if (active_tool == .convex) {
                        _ = convex_tool.redoPoint();
                    }
                }
            }
            if (undo_stack.nextUndoName()) |nm| {
                dvui.label(@src(), "Undo: {s}", .{nm}, .{});
            } else {
                dvui.labelNoFmt(@src(), "Undo: (nothing)", .{}, .{});
            }
            if (undo_stack.nextRedoName()) |nm| {
                dvui.label(@src(), "Redo: {s}", .{nm}, .{});
            } else {
                dvui.labelNoFmt(@src(), "Redo: (nothing)", .{}, .{});
            }
            dvui.labelNoFmt(@src(), "Ctrl+Z undo  Ctrl+Y / Ctrl+Shift+Z redo", .{}, .{});
        }

        // --- Properties (правая колонка) ---
        {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &props_rect, .resize = .none, .window_avoid = .none }, .{ .id_extra = 2 });
            defer fw.deinit();
            _ = dvui.windowHeader("Properties", "", null);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();

            dvui.labelNoFmt(@src(), "Show", .{}, .{});
            _ = dvui.checkbox(@src(), &app.show_log, "Build Log", .{});
            _ = dvui.checkbox(@src(), &app.show_tools, "Tools Panel", .{});
            _ = dvui.checkbox(@src(), &app.show_test_cases, "Test Cases", .{});
            _ = dvui.checkbox(@src(), &show_flags, "Poly Flags", .{});
            _ = dvui.checkbox(@src(), &minimap.show, "Minimap", .{}); // cluster E (P1-4)

            ui.section(@src(), "Sample");
            {
                const sample_names = [_][]const u8{ "Solo Mesh", "Tile Mesh", "Temp Obstacles" };
                var ch: usize = switch (sample_kind) {
                    .solo => 0,
                    .tile => 1,
                    .temp => 2,
                };
                if (dvui.dropdown(@src(), sample_names[0..], .{ .choice = &ch }, .{}, .{})) {
                    sample_kind = switch (ch) {
                        0 => .solo,
                        1 => .tile,
                        else => .temp,
                    };
                    switch (sample_kind) {
                        .tile => if (tile.build_gen == 0) {
                            _ = tile.build();
                        },
                        .temp => if (temp.build_gen == 0) {
                            _ = temp.build();
                        },
                        else => {},
                    }
                }
            }

            ui.section(@src(), "Input Mesh");
            if (mesh_names.len > 0) {
                if (dvui.dropdown(@src(), mesh_names, .{ .choice = &mesh_choice }, .{}, .{})) {
                    loadMeshIndex(main_init.gpa, app.meshes_folder, mesh_choice, mesh_files, &geom, &solo, &tile, &temp, &tester, &crowd_tool, &cam, &bctx);
                }
            }
            if (geom.triCount() > 0) {
                const vk = @as(f32, @floatFromInt(geom.vertCount())) / 1000.0;
                const tk = @as(f32, @floatFromInt(geom.triCount())) / 1000.0;
                dvui.label(@src(), "Verts: {d:.1}k  Tris: {d:.1}k", .{ vk, tk }, .{});
            }

            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            switch (sample_kind) {
                .solo => solo.sampleIface().drawSettings(),
                .tile => tile.drawSettings(),
                .temp => temp.drawSettings(),
            }

            if (dvui.button(@src(), "Build", .{}, .{ .id_extra = 999 })) {
                switch (sample_kind) {
                    .solo => _ = solo.build(),
                    .tile => _ = tile.build(),
                    .temp => _ = temp.build(),
                }
                // Manual Build satisfies any pending rebuild -> clear the red notice.
                area_types.rebuild_needed = false;
            }

            // Area-type *flag*/type changes are baked into tile data, so they need a
            // rebuild (cost/colour edits apply instantly and don't). When auto is off,
            // a red "rebuild needed" notice is drawn bottom-left (see below).
            _ = dvui.checkbox(@src(), &area_types.auto_rebuild, "Auto-rebuild on changes", .{});

            // --- Diagnostics (toggles) ---
            // Each diagnostic panel now lives in its OWN movable/resizable floating
            // window (built after the three primary windows below). The checkboxes
            // stay HERE in Properties; only the heavy content moved out so the rows
            // are no longer horizontally truncated. Closing a window's X unchecks
            // its box (windowHeader openflag wired to the same bool).
            ui.section(@src(), "Diagnostics");
            _ = dvui.checkbox(@src(), &show_build_inspector, "Build Inspector", .{ .id_extra = 7402 });
            _ = dvui.checkbox(@src(), &solo.show_profiler, "Profiler", .{ .id_extra = 7506 });
            _ = dvui.checkbox(@src(), &solo.show_memory, "Memory", .{ .id_extra = 7507 });
            _ = dvui.checkbox(@src(), &show_validation, "Validation", .{ .id_extra = 7508 });
            _ = dvui.checkbox(@src(), &show_capture, "Capture", .{ .id_extra = 7509 });

            // --- Polygon Inspector (B-4) ---
            // Shows a structured table for the polygon last picked via the
            // Disabled-tool inspection click (active_tool == .none + LMB on mesh).
            // Visible whenever inspected_ref != 0; "no polygon inspected" otherwise.
            //
            // Панель инспектора полигона (B-4). Отображает таблицу для последнего
            // полигона, выбранного кликом в режиме Disabled (active_tool == .none).
            {
                ui.section(@src(), "Polygon Inspector");
                if (inspected_ref == 0) {
                    dvui.labelNoFmt(@src(), "No polygon inspected.", .{}, .{ .id_extra = 7440 });
                    dvui.labelNoFmt(@src(), "Click the navmesh (no tool selected).", .{}, .{ .id_extra = 7441 });
                } else if (tester.navmesh) |nm| {
                    // Recompute per-frame (cheap single-poly read, no alloc).
                    // Перевычисляем каждый кадр — дёшево, одна poly, нет аллокаций.
                    if (poly_inspect.inspect(nm, inspected_ref)) |info| {
                        // Ref row
                        {
                            var ref_buf: [16]u8 = undefined;
                            const ref_str = poly_inspect.formatRefText(&ref_buf, info.ref);
                            dvui.label(@src(), "Ref:   {s}", .{ref_str}, .{ .id_extra = 7442 });
                        }
                        // Area row: id + registry name
                        {
                            var area_buf: [64]u8 = undefined;
                            const area_nm: ?[]const u8 = if (area_types.get(info.area)) |at| at.name() else null;
                            const area_str = poly_inspect.formatAreaText(&area_buf, info.area, area_nm);
                            dvui.label(@src(), "Area:  {s}", .{area_str}, .{ .id_extra = 7443 });
                        }
                        // Flags row: bit names + hex
                        {
                            var fl_buf: [128]u8 = undefined;
                            const fl_str = poly_inspect.formatFlagsText(&fl_buf, info.flags);
                            dvui.label(@src(), "Flags: {s}", .{fl_str}, .{ .id_extra = 7444 });
                        }
                        // Vert count + centroid
                        dvui.label(@src(), "Verts: {d}", .{info.vert_count}, .{ .id_extra = 7445 });
                        dvui.label(@src(), "Centroid: ({d:.2}, {d:.2}, {d:.2})", .{ info.centroid[0], info.centroid[1], info.centroid[2] }, .{ .id_extra = 7446 });
                        // Y range
                        dvui.label(@src(), "Y range: [{d:.2} .. {d:.2}]", .{ info.y_min, info.y_max }, .{ .id_extra = 7447 });
                        // Links
                        dvui.label(@src(), "Links: {d}", .{info.link_count}, .{ .id_extra = 7448 });
                        // Neighbours expander
                        if (dvui.expander(@src(), "Neighbours", .{}, .{ .id_extra = 7449 })) {
                            if (info.neighbour_count == 0) {
                                dvui.labelNoFmt(@src(), "  (boundary — no neighbours)", .{}, .{ .id_extra = 7450 });
                            } else {
                                var ni: u32 = 0;
                                while (ni < info.neighbour_count) : (ni += 1) {
                                    var nb_buf: [16]u8 = undefined;
                                    const nb_str = poly_inspect.formatRefText(&nb_buf, info.neighbours[ni]);
                                    dvui.label(@src(), "  [{d}] {s}", .{ ni, nb_str }, .{ .id_extra = 7451 + ni });
                                }
                            }
                        }
                        // Clear button
                        if (dvui.button(@src(), "Clear", .{}, .{ .id_extra = 7459 })) {
                            inspected_ref = 0;
                        }
                    } else {
                        // Bad/stale ref (tile reloaded, mesh rebuilt, etc.) — no crash.
                        // Плохой/устаревший ref (тайл перезагружен, меш пересобран) — без краша.
                        dvui.labelNoFmt(@src(), "Ref is stale (mesh rebuilt?).", .{}, .{ .id_extra = 7440 });
                        {
                            var ref_buf: [16]u8 = undefined;
                            const ref_str = poly_inspect.formatRefText(&ref_buf, inspected_ref);
                            dvui.label(@src(), "Last ref: {s}", .{ref_str}, .{ .id_extra = 7441 });
                        }
                        if (dvui.button(@src(), "Clear", .{}, .{ .id_extra = 7459 })) {
                            inspected_ref = 0;
                        }
                    }
                } else {
                    // No navmesh loaded yet.
                    dvui.labelNoFmt(@src(), "No navmesh loaded.", .{}, .{ .id_extra = 7440 });
                }
            }

            // --- Validation (G1/G2) moved to its own floating window (toggle
            // `show_validation`, built below). See the "Diagnostics" checkboxes
            // above. ---

            // --- Scene persistence (.recastscene container) ---
            // Save only (Load is a follow-up). Solo sample only; reads geom + navmesh
            // and writes files, never mutates live state.
            if (sample_kind == .solo) {
                ui.section(@src(), "Scene Persistence");
                const cur_name: []const u8 = if (mesh_files.len > 0 and mesh_choice < mesh_files.len)
                    mesh_files[mesh_choice]
                else
                    "scene.obj";
                const cur_stem = stemOf(cur_name);

                // Rebuild the variant cache when it is stale (different mesh stem) or
                // empty. Per-frame scanning would be wasteful + leak-prone, so the list
                // is cached and only refreshed here (stem change) or via Refresh below.
                if (!std.mem.eql(u8, variants_stem, cur_stem)) {
                    rebuildVariants(main_init.gpa, app.meshes_folder, cur_stem, &variants, &variants_stem, &bctx);
                }

                // --- Save: Variant text field + Save Scene button ---
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer row.deinit();
                    dvui.labelNoFmt(@src(), "Variant", .{}, .{ .gravity_y = 0.5 });
                    {
                        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &variant_name } }, .{ .expand = .horizontal });
                        te.deinit();
                    }
                }
                if (dvui.button(@src(), "Save Scene", .{}, .{ .id_extra = 998 })) {
                    const variant_in = std.mem.sliceTo(&variant_name, 0);
                    saveSceneNow(main_init.gpa, &geom, &solo, app.meshes_folder, cur_name, variant_in, &bctx);
                    // Refresh the list so the just-saved variant appears (and newest-first).
                    rebuildVariants(main_init.gpa, app.meshes_folder, cur_stem, &variants, &variants_stem, &bctx);
                }

                // --- Auto-save: debounced background save to "<stem>__autosave" ---
                _ = dvui.checkbox(@src(), &auto_save, "Auto-save edits", .{});
                dvui.label(@src(), "  -> {s}__autosave", .{cur_stem}, .{});

                // --- Load: scrollable selectable list of this mesh's variants ---
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer row.deinit();
                    dvui.labelNoFmt(@src(), "Variants (newest first)", .{}, .{ .gravity_y = 0.5 });
                    if (dvui.button(@src(), "Refresh", .{}, .{ .id_extra = 996, .gravity_x = 1.0 })) {
                        rebuildVariants(main_init.gpa, app.meshes_folder, cur_stem, &variants, &variants_stem, &bctx);
                    }
                }
                if (pending_delete) |pidx| {
                    // Confirmation prompt (replaces the list until resolved).
                    if (pidx < variants.len) {
                        const dv = variants[pidx];
                        var dbuf: [192]u8 = undefined;
                        const dtxt = std.fmt.bufPrint(&dbuf, "Delete \"{s}\"? Permanently removes the saved scene.", .{dv.variant}) catch "Delete this variant permanently?";
                        dvui.labelNoFmt(@src(), dtxt, .{}, .{});
                        var crow = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                        defer crow.deinit();
                        if (dvui.button(@src(), "Delete", .{}, .{ .id_extra = 5700 })) {
                            deleteVariant(main_init.gpa, dv.path, &bctx);
                            pending_delete = null;
                            rebuildVariants(main_init.gpa, app.meshes_folder, cur_stem, &variants, &variants_stem, &bctx);
                        }
                        if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 5701 })) {
                            pending_delete = null;
                        }
                    } else {
                        pending_delete = null; // list changed under us
                    }
                } else if (variants.len == 0) {
                    dvui.labelNoFmt(@src(), "(no saved variants)", .{}, .{});
                } else {
                    // Up to 5 rows tall; from the 6th variant on it scrolls (the box
                    // does NOT keep growing — same height as for 5 entries).
                    const list_rows: f32 = @floatFromInt(@min(variants.len, 5));
                    var vsc = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = list_rows * 30 } });
                    defer vsc.deinit();
                    for (variants, 0..) |v, vi| {
                        var vrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = vi });
                        defer vrow.deinit();
                        // index 0 = newest -> highlighted as the default selection.
                        const lbl = if (vi == 0)
                            std.fmt.allocPrint(main_init.gpa, "{s}  (newest)", .{v.variant}) catch v.variant
                        else
                            v.variant;
                        defer if (vi == 0 and lbl.ptr != v.variant.ptr) main_init.gpa.free(lbl);
                        if (dvui.button(@src(), lbl, .{}, .{ .id_extra = 5000 + vi, .expand = .horizontal })) {
                            loadSceneNow(main_init.gpa, app.meshes_folder, v.path, cur_name, &geom, &solo, &tile, &temp, &tester, &crowd_tool, &prune_tool, &cam, &bctx);
                        }
                        if (dvui.buttonIcon(@src(), "del", dvui.entypo.trash, .{}, .{}, .{ .id_extra = 5800 + vi, .gravity_y = 0.5 })) {
                            pending_delete = vi;
                        }
                    }
                }
            }

            ui.section(@src(), "Navmesh Colouring");
            if (ui.radio(@src(), scheme_state.active == .area, "Area", 310)) scheme_state.active = .area;
            if (ui.radio(@src(), scheme_state.active == .flags, "Flags", 311)) scheme_state.active = .flags;
            if (ui.radio(@src(), scheme_state.active == .height, "Height", 312)) scheme_state.active = .height;
            if (ui.radio(@src(), scheme_state.active == .component, "Component", 313)) scheme_state.active = .component;
            if (ui.radio(@src(), scheme_state.active == .cost, "Cost", 314)) scheme_state.active = .cost;
            // Cluster E (P1-3): legend overlay toggle.
            _ = dvui.checkbox(@src(), &show_legend, "Legend", .{ .id_extra = 315 });

            // Cluster E (P1-2): poly overlay labels (poly-ref/centroid/area/cost).
            // Gated additionally on the `labels` view group at render time. id_extra
            // 362..364 (after the 356..361 Layers range — verified no collision).
            ui.section(@src(), "Poly Labels");
            if (ui.radio(@src(), overlay.mode == .none, "Labels: none", 362)) overlay.mode = .none;
            if (ui.radio(@src(), overlay.mode == .hovered, "Labels: hovered", 363)) overlay.mode = .hovered;
            if (ui.radio(@src(), overlay.mode == .all, "Labels: all", 364)) overlay.mode = .all;
            // NOTE: .region is intentionally absent from the UI — region IDs live in
            // PolyMesh.regs (Recast build stage) and are not baked into the Detour
            // navmesh. Wiring it up requires Solo-only PolyMesh.regs plumbing.
            // (cluster E open question Q1: deferred)

            // --- Clipping / Isolation (cluster E, P0-2) ---
            // Read overlapping floors (parking decks, buildings) floor-by-floor.
            // NAVMESH-ONLY: filters the navmesh draw; input geom mesh is not clipped.
            ui.section(@src(), "Clipping / Isolation");
            {
                const fl = &filter_state.active;
                // Clip mode radios (id_extra 340..343).
                if (ui.radio(@src(), fl.clip_mode == .off, "Clip: off", 340)) fl.clip_mode = .off;
                if (ui.radio(@src(), fl.clip_mode == .above, "Clip: above", 341)) fl.clip_mode = .above;
                if (ui.radio(@src(), fl.clip_mode == .below, "Clip: below", 342)) fl.clip_mode = .below;
                if (ui.radio(@src(), fl.clip_mode == .slab, "Clip: slab", 343)) fl.clip_mode = .slab;
                if (fl.clip_mode != .off) {
                    // Clip Y slider spans the NAVMESH's vertical range (poly centroid
                    // heights) — the same value the clip predicate compares against —
                    // NOT the input-geom bbox (which includes walls/ceilings far above
                    // the walkable surface, making most of the slider useless). Falls
                    // back to the geom bbox if no navmesh is built yet.
                    const clip_nm = switch (sample_kind) {
                        .solo => solo.navMesh(),
                        .tile => tile.navMesh(),
                        .temp => temp.navMesh(),
                    };
                    var y_lo: f32 = geom.bmin[1];
                    var y_hi: f32 = geom.bmax[1];
                    if (clip_nm) |nm| {
                        const hr = poly_visit.schemeRange(nm, .height);
                        if (hr.hi > hr.lo) {
                            // pad a touch so the extremes are reachable
                            y_lo = hr.lo - 0.5;
                            y_hi = hr.hi + 0.5;
                        }
                    }
                    if (y_hi > y_lo) {
                        _ = dvui.sliderEntry(@src(), "clip Y {d:.2}", .{ .value = &fl.clip_y, .min = y_lo, .max = y_hi, .interval = null }, .{ .expand = .horizontal, .id_extra = 344 });
                    } else {
                        dvui.label(@src(), "clip Y: load a mesh first", .{}, .{ .id_extra = 344 });
                    }
                    if (fl.clip_mode == .slab)
                        _ = dvui.sliderEntry(@src(), "slab +-{d:.2}", .{ .value = &fl.slab_thickness, .min = 0.1, .max = 50, .interval = null }, .{ .expand = .horizontal, .id_extra = 345 });
                }

                // Isolation mode radios (id_extra 346..348).
                if (ui.radio(@src(), fl.iso_mode == .none, "Iso: none", 346)) fl.iso_mode = .none;
                if (ui.radio(@src(), fl.iso_mode == .show_only, "Iso: show-only (hide non-matching)", 347)) fl.iso_mode = .show_only;
                if (ui.radio(@src(), fl.iso_mode == .dim_others, "Iso: dim-others (fade non-matching)", 348)) fl.iso_mode = .dim_others;
                if (fl.iso_mode != .none) {
                    dvui.labelNoFmt(@src(), "Pick a KEY + VALUE; polys whose key==value stay, the rest are hidden (show-only) or faded (dim-others). If the value matches NO polys, everything hides — check the value (e.g. tile must be a real (tx,ty); area must be a painted area id).", .{}, .{ .id_extra = 339 });
                    // Iso key radios (id_extra 349..351).
                    if (ui.radio(@src(), fl.iso_key == .tile, "by tile", 349)) fl.iso_key = .tile;
                    if (ui.radio(@src(), fl.iso_key == .area, "by area", 350)) fl.iso_key = .area;
                    if (ui.radio(@src(), fl.iso_key == .flags, "by flags", 351)) fl.iso_key = .flags;
                    switch (fl.iso_key) {
                        .tile => {
                            // i32 tile coords via f32 proxies (id_extra 352..353).
                            var tx: f32 = @floatFromInt(fl.iso_tile_x);
                            var ty: f32 = @floatFromInt(fl.iso_tile_y);
                            _ = dvui.sliderEntry(@src(), "tile x {d:.0}", .{ .value = &tx, .min = 0, .max = 64, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 352 });
                            _ = dvui.sliderEntry(@src(), "tile y {d:.0}", .{ .value = &ty, .min = 0, .max = 64, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 353 });
                            // Clamp before the int cast (consistent with area/flags;
                            // guards against a future widened slider range).
                            fl.iso_tile_x = @intFromFloat(std.math.clamp(@round(tx), 0, 64));
                            fl.iso_tile_y = @intFromFloat(std.math.clamp(@round(ty), 0, 64));
                        },
                        .area => {
                            // u8 area 0..63 via f32 proxy (id_extra 354).
                            var av: f32 = @floatFromInt(fl.iso_area);
                            _ = dvui.sliderEntry(@src(), "area {d:.0}", .{ .value = &av, .min = 0, .max = 63, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 354 });
                            fl.iso_area = @intFromFloat(std.math.clamp(@round(av), 0, 63));
                        },
                        .flags => {
                            // u16 flags via f32 proxy (id_extra 355).
                            var fv: f32 = @floatFromInt(fl.iso_flags);
                            _ = dvui.sliderEntry(@src(), "flags {d:.0}", .{ .value = &fv, .min = 0, .max = 65535, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 355 });
                            fl.iso_flags = @intFromFloat(std.math.clamp(@round(fv), 0, 65535));
                        },
                    }
                }
            }

            // --- Layers / Wireframe (cluster E, P1-1) ---
            // Wireframe routes the navmesh draw through poly_visit.outlineNavMesh
            // (edges only). The group checkboxes hide each scene group across all
            // three samples. id_extra 356..361 (after the 340..355 iso range).
            ui.section(@src(), "Layers");
            {
                const grp = &view_state.groups;
                // "Show input mesh" / "Show navmesh" checkboxes removed: they duplicated
                // the Draw Settings draw-mode controls. The render gates on
                // grp.input_mesh / grp.navmesh remain; both default true (view_state.zig)
                // and nothing else flips them, so input-mesh + navmesh always render
                // (controlled by the draw mode).
                _ = dvui.checkbox(@src(), &view_state.wireframe, "Wireframe (navmesh edges)", .{ .id_extra = 356 });
                _ = dvui.checkbox(@src(), &grp.offmesh, "Show off-mesh links", .{ .id_extra = 359 });
                _ = dvui.checkbox(@src(), &grp.convex, "Show convex volumes", .{ .id_extra = 360 });
                _ = dvui.checkbox(@src(), &grp.labels, "Agent/test labels (crowd/target/A* g-h-f)", .{ .id_extra = 361 });
            }

            // --- Capture (cluster E, P2-1) moved to its own floating window
            // (toggle `show_capture`, built below). See "Diagnostics" above. ---

            ui.section(@src(), "Debug Settings");
            switch (sample_kind) {
                .solo => solo.sampleIface().drawDebugMode(),
                .tile => tile.drawDebugMode(),
                .temp => temp.drawDebugMode(),
            }
        }

        // --- Log (снизу по центру, со скроллом) ---
        if (app.show_log) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &log_rect, .resize = .none, .window_avoid = .none }, .{ .id_extra = 3 });
            defer fw.deinit();
            _ = dvui.windowHeader("Log", "", &app.show_log);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();
            var i: usize = 0;
            const n = bctx.getLogCount();
            while (i < n) : (i += 1) {
                dvui.labelNoFmt(@src(), bctx.getLogText(i), .{}, .{ .id_extra = i });
            }
        }

        // =====================================================================
        // Diagnostic windows (declutter: moved OUT of the Properties scrollArea).
        // Built AFTER the three primary windows so they layer on top; toggled by
        // the "Diagnostics" checkboxes in Properties. Each is movable + resizable
        // (resize = .all) and nudges off other windows (window_avoid = .nudge);
        // its rect var persists user drags. windowHeader's openflag = the same
        // toggle bool, so the window's X unchecks the box. Default rects cascade
        // into the centre free area, width ~440 so Build Inspector rows fit.
        // =====================================================================

        // --- Build Inspector (B-1/B-2): Solo only ---
        if (show_build_inspector) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &build_inspector_win_rect, .resize = .all, .window_avoid = .nudge, .open_flag = &show_build_inspector }, .{ .id_extra = 20 });
            defer fw.deinit();
            _ = dvui.windowHeader("Build Inspector", "", &show_build_inspector);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();
            if (sample_kind == .solo) {
                solo.drawBuildInspector();
            } else {
                dvui.labelNoFmt(@src(), "Solo sample only.", .{}, .{ .id_extra = 7401 });
            }
        }

        // --- Profiler (C1): Solo only ---
        if (solo.show_profiler) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &profiler_win_rect, .resize = .all, .window_avoid = .nudge, .open_flag = &solo.show_profiler }, .{ .id_extra = 21 });
            defer fw.deinit();
            _ = dvui.windowHeader("Profiler", "", &solo.show_profiler);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();
            if (sample_kind == .solo) {
                solo.drawProfiler();
            } else {
                dvui.labelNoFmt(@src(), "Solo sample only.", .{}, .{ .id_extra = 7505 });
            }
        }

        // --- Memory (C3): works for all samples ---
        if (solo.show_memory) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &memory_win_rect, .resize = .all, .window_avoid = .nudge, .open_flag = &solo.show_memory }, .{ .id_extra = 22 });
            defer fw.deinit();
            _ = dvui.windowHeader("Memory", "", &solo.show_memory);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();
            switch (sample_kind) {
                .solo => solo.drawMemory(),
                .tile => tile.drawMemory(),
                .temp => temp.drawMemory(),
            }
        }

        // --- Validation (G1 linter + G2 integrity verifier): all samples ---
        if (show_validation) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &validation_win_rect, .resize = .all, .window_avoid = .nudge, .open_flag = &show_validation }, .{ .id_extra = 23 });
            defer fw.deinit();
            _ = dvui.windowHeader("Validation", "", &show_validation);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();

            const active_nav: ?*recast.detour.NavMesh = switch (sample_kind) {
                .solo => solo.navMesh(),
                .tile => tile.navMesh(),
                .temp => temp.navMesh(),
            };
            var lrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 7550 });
            if (dvui.button(@src(), "Lint NavMesh", .{ .grayed = active_nav == null }, .{ .id_extra = 7551 })) {
                if (active_nav) |nm| {
                    if (lint_report) |*old| {
                        old.deinit(main_init.gpa);
                        lint_report = null; // null-after-free
                    }
                    lint_report = navmesh_lint.lint(nm, 0.02, main_init.gpa) catch null;
                }
            }
            _ = dvui.checkbox(@src(), &lint_highlight, "Highlight findings", .{ .id_extra = 7552, .gravity_y = 0.5 });
            lrow.deinit();

            if (lint_report) |*rep| {
                dvui.label(@src(), "errors: {d}   warnings: {d}   info: {d}", .{ rep.error_count, rep.warn_count, rep.info_count }, .{ .id_extra = 7553 });
                if (rep.findings.items.len == 0) {
                    dvui.labelNoFmt(@src(), "No findings — navmesh is clean.", .{}, .{ .id_extra = 7554, .color_text = .{ .r = 140, .g = 220, .b = 140 } });
                } else {
                    var fsc = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 160 }, .id_extra = 7555 });
                    for (rep.findings.items, 0..) |*f, fi| {
                        const col: dvui.Color = switch (f.severity) {
                            .err => .{ .r = 235, .g = 90, .b = 90 },
                            .warn => .{ .r = 235, .g = 200, .b = 80 },
                            .info => .{ .r = 150, .g = 190, .b = 235 },
                        };
                        const badge = switch (f.severity) {
                            .err => "E",
                            .warn => "W",
                            .info => "I",
                        };
                        var rbuf: [128]u8 = undefined;
                        const row = std.fmt.bufPrint(&rbuf, "[{s}] {s}: {s}", .{ badge, @tagName(f.rule), f.message() }) catch f.message();
                        dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = 7556 + fi, .color_text = col });
                    }
                    fsc.deinit();
                }
            } else {
                dvui.labelNoFmt(@src(), "Click \"Lint NavMesh\" to run the linter.", .{}, .{ .id_extra = 7554 });
            }

            if (dvui.button(@src(), "Verify Integrity", .{ .grayed = active_nav == null }, .{ .id_extra = 7580 })) {
                if (active_nav) |nm| {
                    if (verify_report) |*old| {
                        old.deinit(main_init.gpa);
                        verify_report = null; // null-after-free
                    }
                    verify_report = navmesh_verify.verify(nm, main_init.gpa) catch null;
                }
            }
            if (verify_report) |*vrep| {
                if (vrep.ok) {
                    dvui.labelNoFmt(@src(), "\u{2713} integrity OK", .{}, .{ .id_extra = 7581, .color_text = .{ .r = 140, .g = 220, .b = 140 } });
                } else {
                    dvui.label(@src(), "integrity: {d} violation(s)", .{vrep.count}, .{ .id_extra = 7581, .color_text = .{ .r = 235, .g = 90, .b = 90 } });
                    var vsc = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 160 }, .id_extra = 7582 });
                    for (vrep.violations.items, 0..) |*v, vi| {
                        var vbuf: [160]u8 = undefined;
                        const row = std.fmt.bufPrint(&vbuf, "[{s}] t{d}/p{d}/l{d}: {s}", .{ @tagName(v.invariant), v.tile, v.poly, v.link, v.message() }) catch v.message();
                        dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = 7583 + vi, .color_text = .{ .r = 235, .g = 90, .b = 90 } });
                    }
                    vsc.deinit();
                }
            }
        }

        // --- Capture (cluster E, P2-1): all samples. PPM-only; reassemble with:
        // ffmpeg -i <dir>/frame_%05d.ppm out.mp4 ---
        if (show_capture) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &capture_win_rect, .resize = .all, .window_avoid = .nudge, .open_flag = &show_capture }, .{ .id_extra = 24 });
            defer fw.deinit();
            _ = dvui.windowHeader("Capture", "", &show_capture);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();

            ui.sliderInt(@src(), "frames {d:.0}", &capture_ui_frames, 1, 600);
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer row.deinit();
                if (ui.radio(@src(), capture_state.mode == .orbit, "orbit", 365)) capture_state.mode = .orbit;
                if (ui.radio(@src(), capture_state.mode == .live, "live", 366)) capture_state.mode = .live;
            }
            {
                // Dir text entry — gated so typing here doesn't drive the camera/hotkeys.
                var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &capture_ui_dir } }, .{ .expand = .horizontal, .id_extra = 367 });
                te.deinit();
            }
            if (capture_state.active) {
                dvui.label(@src(), "capturing {d}/{d}", .{ capture_state.done, capture_state.total }, .{ .id_extra = 368 });
                if (dvui.button(@src(), "Stop", .{}, .{ .id_extra = 369 })) {
                    capture_state.active = false; // mid-capture stop: no leak (per-frame defers freed buffers)
                    capture_manifest.clearRetainingCapacity(); // drop the aborted run's partial lines
                    if (capture_state.mode == .orbit) bench = false;
                }
            } else {
                if (dvui.button(@src(), "Start", .{}, .{ .id_extra = 369 })) {
                    const dir_s = std.mem.sliceTo(&capture_ui_dir, 0);
                    if (dir_s.len > 0) {
                        capture_manifest.clearRetainingCapacity();
                        capture_state.start(dir_s, @intFromFloat(capture_ui_frames), capture_state.mode);
                        if (capture_state.mode == .orbit) {
                            bench = true; // sweep 360° via the orbit machinery
                            bench_started = false; // re-seed the orbit center from current geom
                        }
                    }
                }
            }
        }

        // --- Poly Flags manager (global reachability flags; hidden by default) ---
        if (show_flags) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &flags_rect, .open_flag = &show_flags }, .{ .id_extra = 9 });
            defer fw.deinit();
            _ = dvui.windowHeader("Poly Flags", "", &show_flags);
            dvui.labelNoFmt(@src(), "Reachability flags (max 16).", .{}, .{});
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            {
                var i: usize = 0;
                while (i < poly_flags.MAX_FLAGS) : (i += 1) {
                    const fl = poly_flags.get(i) orelse continue;
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
                    defer row.deinit();
                    dvui.label(@src(), "{s}  (0x{x:0>2})", .{ fl.name(), @as(u16, 1) << @intCast(i) }, .{ .id_extra = i });
                    if (!fl.builtin and dvui.button(@src(), "remove", .{}, .{ .id_extra = i, .gravity_x = 1.0 })) {
                        // Capture the Flag BEFORE removing it so undo can restore it.
                        const captured = fl.*;
                        poly_flags.removeFlag(i);
                        undo_stack.record(.{ .flag_remove = .{ .bit_index = i, .flag = captured } });
                        // Defining/removing a flag doesn't touch baked tile data — a
                        // rebuild is only needed once a flag is assigned to an area
                        // type (handled in the area editor), so no rebuild_needed here.
                    }
                }
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer row.deinit();
                {
                    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &new_flag_name } }, .{ .expand = .horizontal });
                    te.deinit();
                }
                if (dvui.button(@src(), "Add Flag", .{}, .{})) {
                    const name = std.mem.sliceTo(&new_flag_name, 0);
                    if (name.len > 0) {
                        // addFlag returns the bit value (1 << index); derive the bit
                        // index so we can capture the new slot for undo.
                        if (poly_flags.addFlag(name)) |bit| { // ASCII/English names only (font has no Cyrillic)
                            const bit_index: usize = @ctz(bit);
                            if (poly_flags.get(bit_index)) |nf|
                                undo_stack.record(.{ .flag_add = .{ .bit_index = bit_index, .flag = nf.* } });
                        }
                        @memset(&new_flag_name, 0);
                    }
                }
            }

            // --- F4: area-type / poly-flag PRESETS ----------------------------
            // First time the panel renders, scan presets/ once so the dropdown is
            // populated. Re-scan happens after every Save below.
            if (!preset_list_init) {
                preset_list_init = true;
                rescanPresets(main_init.gpa, app.meshes_folder, &preset_names);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            dvui.labelNoFmt(@src(), "Presets (area types + poly flags)", .{}, .{});

            // Save Preset: name entry + Save button -> presets/<name>.reg.
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer row.deinit();
                {
                    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &preset_name } }, .{ .expand = .horizontal });
                    te.deinit();
                }
                if (dvui.button(@src(), "Save Preset", .{}, .{})) {
                    const nm_in = std.mem.sliceTo(&preset_name, 0);
                    const nm = if (nm_in.len > 0) nm_in else "preset"; // savePreset also sanitizes/defaults
                    savePresetNow(main_init.gpa, app.meshes_folder, nm);
                    @memset(&preset_name, 0);
                    // Re-scan so the new preset appears in the Apply dropdown.
                    rescanPresets(main_init.gpa, app.meshes_folder, &preset_names);
                }
            }

            // Apply Preset: dropdown + Replace/Merge radio + Apply button.
            if (preset_names.len > 0) {
                if (preset_choice >= preset_names.len) preset_choice = 0;
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer row.deinit();
                    // dvui.dropdown wants []const []const u8 — our names are [][]u8;
                    // the element type coerces, so pass it directly.
                    _ = dvui.dropdown(@src(), preset_names, .{ .choice = &preset_choice }, .{}, .{ .expand = .horizontal });
                }
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer row.deinit();
                    if (ui.radio(@src(), preset_merge, "Merge", 970)) preset_merge = true;
                    if (ui.radio(@src(), !preset_merge, "Replace", 971)) preset_merge = false;
                }
                if (dvui.button(@src(), "Apply Preset", .{}, .{})) {
                    applyPresetNow(main_init.gpa, app.meshes_folder, preset_names[preset_choice], preset_merge, &undo_stack, &geom);
                    geom_edited = true;
                }
            } else {
                dvui.labelNoFmt(@src(), "(no presets — Save one above)", .{}, .{});
            }
        }

        // --- Minimap overview + fly-to (cluster E, P1-4) -----------------------
        // Top-down 2D overview: scene XZ bbox, tile grid (Tile/Temp), camera
        // position+heading, off-mesh midpoints + convex-volume centroids. Fly-to by
        // map-click / tile (tx,ty) / poly-ref hex. Faithful core untouched.
        if (minimap.show) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &minimap_rect, .resize = .none, .window_avoid = .none, .open_flag = &minimap.show }, .{ .id_extra = 11 });
            defer fw.deinit();
            _ = dvui.windowHeader("Minimap", "", &minimap.show);

            const mm_nm = switch (sample_kind) {
                .solo => solo.navMesh(),
                .tile => tile.navMesh(),
                .temp => temp.navMesh(),
            };

            // bbox for the map projection (scene geom XZ). Pad slightly so markers on
            // the edge aren't clipped by the outline.
            const bminx = geom.bmin[0];
            const bminz = geom.bmin[2];
            const bmaxx = geom.bmax[0];
            const bmaxz = geom.bmax[2];

            // Square canvas box; grab its physical rect for drawing, and resolve the
            // click-to-fly BEFORE deinit (clickedEx reads the live widget + events).
            var canvas = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 236, .h = 236 }, .expand = .horizontal });
            const cr = canvas.data().rectScale().r; // physical pixels
            var click_world: ?[2]f32 = null;
            if (dvui.clickedEx(canvas.data(), .{ .rect = cr })) |ev| {
                if (ev == .mouse and cr.contains(ev.mouse.p)) {
                    click_world = minimap.mapToWorld(ev.mouse.p.x, ev.mouse.p.y, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                }
            }
            canvas.deinit();
            if (click_world) |w| flyToXZ(&cam, &geom, w[0], w[1]);

            // bbox outline (the map frame).
            minimap.rectOutline(cr.x, cr.y, cr.w, cr.h, .{ .r = 120, .g = 120, .b = 130, .a = 255 }, 1.5);

            // Tile grid lines (Tile/Temp only — Solo has no tile params: tw/th may be 0).
            if (mm_nm) |nm| {
                if (nm.tile_width > 0 and nm.tile_height > 0) {
                    const grid_col = dvui.Color{ .r = 70, .g = 90, .b = 110, .a = 200 };
                    // vertical lines at orig.x + k*tw within [bminx,bmaxx]
                    var gx = nm.orig.x + @ceil((bminx - nm.orig.x) / nm.tile_width) * nm.tile_width;
                    while (gx <= bmaxx) : (gx += nm.tile_width) {
                        const a = minimap.worldToMap(gx, bminz, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                        const b = minimap.worldToMap(gx, bmaxz, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                        minimap.line(a[0], a[1], b[0], b[1], grid_col, 1.0);
                    }
                    var gz = nm.orig.z + @ceil((bminz - nm.orig.z) / nm.tile_height) * nm.tile_height;
                    while (gz <= bmaxz) : (gz += nm.tile_height) {
                        const a = minimap.worldToMap(bminx, gz, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                        const b = minimap.worldToMap(bmaxx, gz, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                        minimap.line(a[0], a[1], b[0], b[1], grid_col, 1.0);
                    }
                }
            }

            // Off-mesh connection midpoints (cyan) + convex-volume centroids (orange).
            {
                var oi: usize = 0;
                while (oi * 6 + 5 < geom.off_verts.items.len) : (oi += 1) {
                    const v = geom.off_verts.items[oi * 6 ..][0..6];
                    const mx = (v[0] + v[3]) * 0.5;
                    const mz = (v[2] + v[5]) * 0.5;
                    const p = minimap.worldToMap(mx, mz, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                    minimap.dot(p[0], p[1], 5, .{ .r = 0, .g = 230, .b = 230, .a = 255 });
                }
            }
            for (geom.volumes.items) |*vol| {
                const nv: usize = @intCast(vol.nverts);
                if (nv == 0) continue;
                var cx: f32 = 0;
                var cz: f32 = 0;
                for (0..nv) |k| {
                    cx += vol.verts[k * 3 + 0];
                    cz += vol.verts[k * 3 + 2];
                }
                const fn_: f32 = @floatFromInt(nv);
                const p = minimap.worldToMap(cx / fn_, cz / fn_, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                minimap.dot(p[0], p[1], 5, .{ .r = 255, .g = 150, .b = 0, .a = 255 });
            }

            // Camera marker (yellow). The marker shows where the camera is LOOKING
            // (its forward ray hit on the scene mid-height plane), NOT the eye — so a
            // minimap click+fly-to lands the marker ON the clicked point (the eye is
            // pulled back, which made the marker look "off" from the click). Falls
            // back to the eye XZ when the view is near-horizontal (no ground hit).
            {
                const yellow = dvui.Color{ .r = 255, .g = 235, .b = 0, .a = 255 };
                const vmat = cam.view();
                // forward world dir = -(third row of rotation) -> (-m2, -m6, -m10).
                var fwx = -vmat.m[2];
                const fwy = -vmat.m[6];
                var fwz = -vmat.m[10];
                const ymid = (geom.bmin[1] + geom.bmax[1]) * 0.5;
                var look_x = cam.pos.x;
                var look_z = cam.pos.z;
                if (@abs(fwy) > 1e-3) {
                    const t = (ymid - cam.pos.y) / fwy;
                    if (t > 0) {
                        look_x = cam.pos.x + fwx * t;
                        look_z = cam.pos.z + fwz * t;
                    }
                }
                const cp = minimap.worldToMap(look_x, look_z, bminx, bminz, bmaxx, bmaxz, cr.x, cr.y, cr.w, cr.h);
                minimap.dot(cp[0], cp[1], 7, yellow);
                // heading arrow from the look point along the view-forward XZ.
                const fl2 = @sqrt(fwx * fwx + fwz * fwz);
                if (fl2 > 1e-4) {
                    fwx /= fl2;
                    fwz /= fl2;
                    const al: f32 = 16;
                    minimap.line(cp[0], cp[1], cp[0] + fwx * al, cp[1] + fwz * al, yellow, 2.0);
                }
            }

            _ = dvui.separator(@src(), .{ .expand = .horizontal });

            // Fly-to by tile (tx,ty).
            if (mm_nm) |nm| {
                if (nm.tile_width > 0 and nm.tile_height > 0) {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    _ = dvui.sliderEntry(@src(), "tx {d:.0}", .{ .value = &mm_tile_x, .min = 0, .max = 256, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 1100 });
                    _ = dvui.sliderEntry(@src(), "ty {d:.0}", .{ .value = &mm_tile_y, .min = 0, .max = 256, .interval = 1 }, .{ .expand = .horizontal, .id_extra = 1101 });
                    row.deinit();
                    if (dvui.button(@src(), "Go to tile", .{}, .{ .id_extra = 1102 })) {
                        const c = minimap.tileCenter(.{ nm.orig.x, nm.orig.y, nm.orig.z }, nm.tile_width, nm.tile_height, @intFromFloat(@round(mm_tile_x)), @intFromFloat(@round(mm_tile_y)));
                        flyToXZ(&cam, &geom, c[0], c[1]);
                    }
                } else {
                    dvui.labelNoFmt(@src(), "(Solo: no tile grid — use ref / click)", .{}, .{});
                }
            }

            // Fly-to by poly-ref hex.
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                {
                    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &mm_ref_buf } }, .{ .expand = .horizontal });
                    te.deinit();
                }
                if (dvui.button(@src(), "Go to ref", .{}, .{ .id_extra = 1103 })) {
                    if (minimap.parseHexRef(std.mem.sliceTo(&mm_ref_buf, 0))) |ref| {
                        if (mm_nm) |nm| {
                            if (polyCentroid(nm, ref)) |c| flyToXZ(&cam, &geom, c.x, c.z);
                        }
                    }
                }
                row.deinit();
            }
            dvui.labelNoFmt(@src(), "click map / Go to fly there", .{}, .{});
        }

        // --- Test Cases (как окно "Test Cases" RecastDemo) ---
        if (app.show_test_cases) {
            var fw = dvui.floatingWindow(@src(), .{ .rect = &test_rect, .resize = .none, .window_avoid = .none }, .{ .id_extra = 4 });
            defer fw.deinit();
            _ = dvui.windowHeader("Test Cases", "", &app.show_test_cases);
            var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer sc.deinit();
            dvui.labelNoFmt(@src(), "Choose Test", .{}, .{});
            if (test_names.len > 0) {
                const changed = dvui.dropdown(@src(), test_names, .{ .choice = &test_choice }, .{}, .{});
                if (changed and test_choice != prev_test_choice) {
                    prev_test_choice = test_choice;
                    if (active_test) |*t| t.deinit();
                    active_test = null;
                    const p = std.fmt.allocPrint(main_init.gpa, "{s}/{s}", .{ tests_folder, test_files[test_choice] }) catch null;
                    if (p) |path| {
                        defer main_init.gpa.free(path);
                        if (TestCase.load(main_init.gpa, path)) |tc| {
                            active_test = tc;
                            const sn = tc.sampleName();
                            if (std.mem.eql(u8, sn, "Solo Mesh")) {
                                sample_kind = .solo;
                            } else if (std.mem.eql(u8, sn, "Tile Mesh")) {
                                sample_kind = .tile;
                            } else if (std.mem.eql(u8, sn, "Temp Obstacles")) {
                                sample_kind = .temp;
                            }
                            const gn = tc.geomName();
                            var geom_found = false;
                            for (mesh_files, 0..) |mf, mi| {
                                if (std.mem.eql(u8, mf, gn)) {
                                    mesh_choice = mi;
                                    loadMeshIndex(main_init.gpa, app.meshes_folder, mi, mesh_files, &geom, &solo, &tile, &temp, &tester, &crowd_tool, &cam, &bctx);
                                    geom_found = true;
                                    break;
                                }
                            }
                            if (!geom_found) {
                                // меш теста отсутствует — не строим чужой навмеш и не показываем
                                // ложные результаты (см. movement_test.txt -> movement.obj).
                                bctx.context().log(.err, "Test mesh '{s}' not found in {s}", .{ gn, app.meshes_folder });
                                active_test.?.deinit();
                                active_test = null;
                            } else {
                                switch (sample_kind) {
                                    .solo => _ = solo.build(),
                                    .tile => _ = tile.build(),
                                    .temp => _ = temp.build(),
                                }
                                bctx.context().log(.progress, "Test: {s} ({d} cases)", .{ test_files[test_choice], tc.tests.items.len });
                            }
                        } else |e| {
                            bctx.context().log(.err, "Test load failed: {s}", .{@errorName(e)});
                        }
                    }
                }
            } else {
                dvui.labelNoFmt(@src(), "No test cases found", .{}, .{});
            }
            if (active_test) |*t| {
                _ = dvui.separator(@src(), .{ .expand = .horizontal });
                dvui.label(@src(), "Sample: {s}", .{t.sampleName()}, .{});
                dvui.label(@src(), "OK: {d}/{d}", .{ t.n_ok, t.tests.items.len }, .{});
                dvui.label(@src(), "Total: {d:.2} ms", .{t.total_ms}, .{});
            }
        }

        // --- worldspace overlay-текст (DrawWorldspaceText) + экранные подсказки ---
        {
            const vh: f32 = @floatFromInt(fb[1]);
            var tbuf: [64]u8 = undefined;
            const white = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
            const label_col = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 220 };

            // Crowd perf graph (Show Perf Graph) — 2D overlay over the dvui frame.
            if (active_tool == .crowd) crowd_tool.renderPerfGraph(vh);

            // подписи агентов толпы (индекс над агентом) — по чекбоксу Show Labels.
            // Cluster E (P1-1): also gated on the `labels` view group.
            if (view_state.groups.labels and active_tool == .crowd and crowd_tool.show_labels) {
                if (crowd_tool.crowd) |*c| {
                    for (0..crowd_tool.agent_count) |i| {
                        const ag = c.getAgent(@intCast(i)) orelse continue;
                        if (!ag.active) continue;
                        // 1-в-1: позиция pos.y+height, цвет ЧЁРНЫЙ (0,0,0,220) как renderOverlay.
                        const wp = Vec3.init(ag.npos[0], ag.npos[1] + ag.params.height, ag.npos[2]);
                        if (cam.worldToScreen(wp, viewport)) |sp| {
                            if (sp.z >= 0 and sp.z <= 1) {
                                const txt = std.fmt.bufPrint(&tbuf, "{d}", .{i}) catch continue;
                                ui.screenTextEx(sp.x, vh - sp.y, txt, label_col, true);
                            }
                        }
                    }
                }
            }

            // float-дист до соседа в цилиндре — 1-в-1 Tool_Crowd.cpp:656-697.
            // При выделенном агенте (idx!=-1) + Show Neighbors рисуется белый "%.3f" КВАДРАТА
            // дистанции (neis.dist хранит distSqr, как DetourCrowd.cpp:215) в позиции соседа
            // на высоте npos.y + radius ВЫДЕЛЕННОГО агента. guard showDetailAll: для всех / только idx.
            if (view_state.groups.labels and active_tool == .crowd and crowd_tool.debug.idx != -1 and crowd_tool.show_neighbors) {
                if (crowd_tool.crowd) |*c| {
                    for (0..crowd_tool.agent_count) |i| {
                        if (!crowd_tool.show_detail_all and @as(i32, @intCast(i)) != crowd_tool.debug.idx) continue;
                        const ag = c.getAgent(@intCast(i)) orelse continue;
                        if (!ag.active) continue;
                        for (0..ag.nneis) |j| {
                            const nag = c.getAgent(@intCast(ag.neis[j].idx)) orelse continue;
                            if (!nag.active) continue;
                            const wp = Vec3.init(nag.npos[0], nag.npos[1] + ag.params.radius, nag.npos[2]);
                            if (cam.worldToScreen(wp, viewport)) |sp| {
                                if (sp.z >= 0 and sp.z <= 1) {
                                    const txt = std.fmt.bufPrint(&tbuf, "{d:.3}", .{ag.neis[j].dist}) catch continue;
                                    ui.screenTextEx(sp.x, vh - sp.y, txt, white, true);
                                }
                            }
                        }
                    }
                }
            }

            // подпись "TARGET" над целью толпы (как renderOverlay оригинала)
            if (view_state.groups.labels and active_tool == .crowd and crowd_tool.has_target) {
                const wp = Vec3.init(crowd_tool.target_pos[0], crowd_tool.target_pos[1], crowd_tool.target_pos[2]);
                if (cam.worldToScreen(wp, viewport)) |sp| {
                    if (sp.z >= 0 and sp.z <= 1) ui.screenTextEx(sp.x, vh - sp.y, "TARGET", white, true);
                }
            }

            // подписи тестов (T<index> над точкой старта) — gated on `labels` group.
            if (view_state.groups.labels) {
                if (active_test) |*t| {
                    for (t.tests.items, 0..) |tc, i| {
                        const wp = Vec3.init(tc.spos[0], tc.spos[1] + 0.5, tc.spos[2]);
                        if (cam.worldToScreen(wp, viewport)) |sp| {
                            if (sp.z >= 0 and sp.z <= 1) {
                                const txt = std.fmt.bufPrint(&tbuf, "T{d}", .{i}) catch continue;
                                ui.screenTextEx(sp.x, vh - sp.y, txt, white, true);
                            }
                        }
                    }
                }
            }

            // Sliced-search g/h/f labels (incremental A* visualizer). Density-capped
            // inside forEachSearchLabel (skips when node count > MAX_LABEL_NODES);
            // each label is culled here by sp.z∈[0,1] (behind-camera / out of depth).
            if (view_state.groups.labels and active_tool == .tester) {
                const LabelCtx = struct {
                    cam: *const Camera,
                    viewport: [4]i32,
                    vh: f32,
                    col: dvui.Color,
                };
                const lctx = LabelCtx{
                    .cam = &cam,
                    .viewport = viewport,
                    .vh = vh,
                    .col = dvui.Color{ .r = 255, .g = 255, .b = 200, .a = 255 },
                };
                tester.forEachSearchLabel(lctx, struct {
                    fn emit(c: LabelCtx, pos: [3]f32, text: []const u8) void {
                        const wp = Vec3.init(pos[0], pos[1], pos[2]);
                        if (c.cam.worldToScreen(wp, c.viewport)) |sp| {
                            if (sp.z >= 0 and sp.z <= 1)
                                ui.screenTextEx(sp.x, c.vh - sp.y, text, c.col, true);
                        }
                    }
                }.emit);

                // Funnel/portal overlay labels (A3): "P{i}" at portal midpoints,
                // "W{k}" at ALL_CROSSINGS waypoints. Same plumbing as the search
                // labels; density-capped inside forEachFunnelLabel, culled by sp.z.
                const fctx = LabelCtx{
                    .cam = &cam,
                    .viewport = viewport,
                    .vh = vh,
                    .col = dvui.Color{ .r = 0, .g = 230, .b = 230, .a = 255 },
                };
                tester.forEachFunnelLabel(fctx, struct {
                    fn emit(c: LabelCtx, pos: [3]f32, text: []const u8) void {
                        const wp = Vec3.init(pos[0], pos[1], pos[2]);
                        if (c.cam.worldToScreen(wp, c.viewport)) |sp| {
                            if (sp.z >= 0 and sp.z <= 1)
                                ui.screenTextEx(sp.x, c.vh - sp.y, text, c.col, true);
                        }
                    }
                }.emit);
            }

            // Cluster E (P1-2): poly overlay labels — poly-ref / centroid / area /
            // cost over polygons. Gated on the `labels` view group AND the overlay
            // mode (none/hovered/all). `hovered` labels the poly under the cursor;
            // `all` labels every visible poly, auto-downgrading to `hovered` when the
            // would-be count exceeds overlay.MAX_ALL_LABELS (perf + readability).
            // Poly Labels is its OWN control (the radio), independent of the
            // "Agent/test labels" group toggle — they were redundant/confusing.
            if (overlay.mode != .none) {
                const nm_opt = switch (sample_kind) {
                    .solo => solo.navMesh(),
                    .tile => tile.navMesh(),
                    .temp => temp.navMesh(),
                };
                if (nm_opt) |nm| {
                    var lbuf: [96]u8 = undefined;
                    const lcol = dvui.Color{ .r = 245, .g = 240, .b = 200, .a = 255 };

                    // Decide the effective mode this frame: `all` downgrades to
                    // `hovered` past the cap (counts non-offmesh, non-hidden polys).
                    var eff_mode = overlay.mode;
                    if (eff_mode == .all) {
                        var n_labels: usize = 0;
                        outer: for (0..@intCast(nm.max_tiles)) |ti| {
                            const t2 = &nm.tiles[ti];
                            const hdr = t2.header orelse continue;
                            for (0..@intCast(hdr.poly_count)) |pi| {
                                const p = &t2.polys[pi];
                                if (p.getType() == .offmesh_connection) continue;
                                const cy = polyCentroidY(t2, p);
                                if (isolation.verdictFor(filter_state.active, cy, hdr.x, hdr.y, p.getArea(), p.flags) == .hide) continue;
                                n_labels += 1;
                                if (n_labels > overlay.MAX_ALL_LABELS) {
                                    eff_mode = .hovered;
                                    if (!overlay_cap_warned) {
                                        overlay_cap_warned = true;
                                        std.debug.print("[overlay] {d}+ visible polys exceed cap {d} — labels:all downgraded to hovered this frame\n", .{ n_labels, overlay.MAX_ALL_LABELS });
                                    }
                                    break :outer;
                                }
                            }
                        }
                    }

                    if (eff_mode == .hovered) {
                        // Ray-pick the world point under the cursor, then nearest poly.
                        const win_sz2 = g_window.getSize();
                        const hx: f64 = if (win_sz2[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(win_sz2[0])) else 1.0;
                        const hy: f64 = if (win_sz2[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(win_sz2[1])) else 1.0;
                        if (gate.pointerInScene()) {
                            if (cam.pickRay(@floatCast(cur[0] * hx), @floatCast(cur[1] * hy), viewport)) |r| {
                                if (pickPoint(&geom, r.start, r.end)) |h| {
                                    if (tester.query) |q| {
                                        const hp = h.toArray();
                                        const ext = [3]f32{ 2, 4, 2 };
                                        var ref: u32 = 0;
                                        var snap: [3]f32 = undefined;
                                        _ = q.findNearestPoly(&hp, &ext, &tester.filter, &ref, &snap) catch {};
                                        if (ref != 0) drawPolyLabel(nm, ref, &lbuf, lcol, cam, viewport, vh);
                                    }
                                }
                            }
                        }
                    } else if (eff_mode == .all) {
                        for (0..@intCast(nm.max_tiles)) |ti| {
                            const t2 = &nm.tiles[ti];
                            const hdr = t2.header orelse continue;
                            const base = nm.getPolyRefBase(t2);
                            for (0..@intCast(hdr.poly_count)) |pi| {
                                const p = &t2.polys[pi];
                                if (p.getType() == .offmesh_connection) continue;
                                const cy = polyCentroidY(t2, p);
                                if (isolation.verdictFor(filter_state.active, cy, hdr.x, hdr.y, p.getArea(), p.flags) == .hide) continue;
                                const ref: u32 = base | @as(u32, @intCast(pi));
                                drawPolyLabel(nm, ref, &lbuf, lcol, cam, viewport, vh);
                            }
                        }
                    }
                }
            }

            // Cluster E (P1-3): scheme legend — top-right corner overlay. For the
            // height/cost gradient bar we pass the navmesh value range (else 0..0).
            if (show_legend) {
                const scheme = scheme_state.active;
                var lo: f32 = 0;
                var hi: f32 = 0;
                // Continuous schemes (height/cost) need a baked navmesh to label a
                // range; without one we'd draw a meaningless "0.00 .. 0.00" bar, so
                // skip the legend entirely in that case. Discrete schemes (area/
                // flags/component) come from the registries and draw regardless.
                var draw_legend = true;
                if (scheme == .height or scheme == .cost) {
                    const nm = switch (sample_kind) {
                        .solo => solo.navMesh(),
                        .tile => tile.navMesh(),
                        .temp => temp.navMesh(),
                    };
                    if (nm) |n| {
                        const r = poly_visit.schemeRange(n, scheme);
                        lo = r.lo;
                        hi = r.hi;
                    } else {
                        draw_legend = false;
                    }
                }
                if (draw_legend) legend.draw(scheme, @floatFromInt(fb[0]), vh, lo, hi);
            }

            // экранные подсказки (нижний левый угол)
            const hint = tool_registry.hintFor(active_tool);
            // Controls hint — top-centre (white).
            ui.screenTextEx(@as(f32, @floatFromInt(fb[0])) * 0.5, 16, hint, white, true);
            // Red "rebuild needed" notice — bottom-centre. Shown only when a baked
            // change is pending and auto-rebuild is off.
            if (area_types.rebuild_needed and !area_types.auto_rebuild) {
                const cx = @as(f32, @floatFromInt(fb[0])) * 0.5;
                ui.screenTextEx(cx, vh - 28, "! Navmesh rebuild needed — press Build", .{ .r = 235, .g = 70, .b = 50, .a = 255 }, true);
            }
        }

        const z_end = tracy.zone(@src(), "dvui.end"); // тесселяция + GL-рендер UI
        const end_micros = try win.end(.{ .manage_backend = false });
        z_end.end();
        // курсор над dvui-панелью? -> на след. кадре не трогаем камеру/пикинг
        gate.update(win.cursorRequestedFloating() != null, win.textInputRequested() != null);
        z_dvui.end();

        // --- Frame capture hook (Cluster E, P2-1) ---
        // AFTER the 3D sample + dvui UI have drawn into the default framebuffer and BEFORE
        // the buffer swap, the framebuffer is complete: read it back, encode a flipped PPM,
        // and durably write it via write_atomic (no torn images). Frame-count-driven.
        if (capture_state.active and !capture_state.finished()) {
            captureFrame(
                main_init.gpa,
                &capture_state,
                &capture_manifest,
                &capture_dir_opened,
                fb,
                cam,
                &bctx,
            );
            if (capture_state.finished()) {
                bctx.context().log(.progress, "capture: wrote {d} frames to {s}", .{ capture_state.done, capture_state.dir() });
                bctx.context().log(.progress, "capture: video via  ffmpeg -i {s}/frame_%05d.ppm out.mp4", .{capture_state.dir()});
                capture_state.active = false;
                if (capture_headless) {
                    g_window.setShouldClose(true); // headless run exits after capture
                } else if (capture_state.mode == .orbit) {
                    bench = false; // UI-triggered orbit: stop the camera sweep when done
                }
            }
        }

        {
            const z = tracy.zone(@src(), "swapBuffers");
            defer z.end();
            g_window.swapBuffers();
        }

        // --- управление частотой кадров ---
        // need = идёт ввод/симуляция ИЛИ ещё длится бёрст после события.
        // Активно -> 60 FPS кап + неблокирующая прокачка событий.
        // Простой -> блокируемся на событиях/анимациях dvui (CPU ~0, не крутим UI зря).
        const need = bench or cycle_modes or continuousNeeded(&crowd_tool) or force_frames > 0;
        if (need) {
            if (force_frames > 0) force_frames -= 1;
            const elapsed = impl.nanoTime() - frame_start;
            const target_ns: i128 = 16_666_667;
            if (!bench and elapsed > 0 and elapsed < target_ns) {
                const z = tracy.zone(@src(), "frameSleep");
                defer z.end();
                main_init.io.sleep(.fromNanoseconds(@intCast(target_ns - elapsed)), .awake) catch {};
            }
            woke = impl.pollEventsTimeout(0); // прокачать события, не блокируя
        } else {
            const z = tracy.zone(@src(), "idleWait");
            defer z.end();
            const wait_micros = win.waitTime(end_micros);
            woke = impl.pollEventsTimeout(wait_micros); // блок до события/анимации/таймаута
        }
        if (woke) force_frames = 30; // событие -> бёрст кадров (досчёт анимаций/симуляции)
        tracy.frameMark();

        // bench: учёт и выход по времени (~10с)
        if (bench) {
            bench_ns += impl.nanoTime() - frame_start;
            bench_frames += 1;
            bench_draws += dd_gl.draw_calls;
            if (@as(f64, @floatFromInt(bench_ns)) / 1_000_000_000.0 >= bench_secs) {
                const frames: f64 = @floatFromInt(bench_frames);
                const avg_ms = @as(f64, @floatFromInt(bench_ns)) / 1_000_000.0 / frames;
                std.debug.print("\n=== BENCH orbit {d:.0}s ===\nframes: {d}\navg frame: {d:.3} ms ({d:.0} FPS)\navg draw calls/frame: {d:.0}\nrevolutions: {d:.2}\n", .{
                    bench_secs, bench_frames, avg_ms, 1000.0 / avg_ms,
                    @as(f64, @floatFromInt(bench_draws)) / frames, bench_angle / 360.0,
                });
                break;
            }
        }
    }
}

/// Нужна ли непрерывная отрисовка: зажат ввод камеры/мыши или активна симуляция толпы.
fn continuousNeeded(crowd: *const CrowdTool) bool {
    if (g_window.getKey(.w) == .press or g_window.getKey(.s) == .press or
        g_window.getKey(.a) == .press or g_window.getKey(.d) == .press or
        g_window.getKey(.q) == .press or g_window.getKey(.e) == .press) return true;
    if (g_window.getMouseButton(.right) == .press or g_window.getMouseButton(.left) == .press) return true;
    if (crowd.running and crowd.agent_count > 0) return true;
    return false;
}

/// Capture one frame: glReadPixels the complete default framebuffer, encode a vertically
/// flipped PPM (GL origin is bottom-left), and durably write it to `<dir>/frame_<idx>.ppm`
/// via write_atomic (atomic rename — a partially written frame never appears). Appends a
/// manifest line; on the final frame flushes the manifest to `<dir>/manifest.txt`.
///
/// All IO/alloc errors are caught + logged (capture is best-effort demo tooling — a single
/// failed frame must never crash the loop). `done` is incremented on a fully written frame.
fn captureFrame(
    gpa: std.mem.Allocator,
    st: *capture.State,
    manifest: *std.array_list.Managed(u8),
    dir_opened: *bool,
    fb: [2]i32,
    cam: Camera,
    bctx: *BuildContext,
) void {
    const write_atomic = @import("persist/write_atomic.zig");

    const w: usize = @intCast(fb[0]);
    const h: usize = @intCast(fb[1]);
    if (w == 0 or h == 0) return;

    // 1) Read back the framebuffer (RGB, bottom-up). zgl wraps glReadPixels.
    const rgb = gpa.alloc(u8, w * h * 3) catch {
        bctx.context().log(.err, "capture: alloc pixels failed", .{});
        return;
    };
    defer gpa.free(rgb);
    // GL_PACK_ALIGNMENT defaults to 4: with .rgb/.unsigned_byte, rows whose
    // width*3 isn't a multiple of 4 get padded, so glReadPixels would write a
    // row-padded layout past our exact w*h*3 buffer (heap overflow) AND shear the
    // image. Force tight packing so each row is exactly width*3 bytes.
    zgl.pixelStore(.pack_alignment, 1);
    zgl.readPixels(0, 0, w, h, .rgb, .unsigned_byte, rgb.ptr);

    // 2) Encode a top-down PPM (encodePpm flips vertically).
    const ppm = capture.encodePpm(gpa, rgb, w, h) catch {
        bctx.context().log(.err, "capture: encode PPM failed", .{});
        return;
    };
    defer gpa.free(ppm);

    // 3) Durable write. One Threaded Io + cwd Dir per frame (mirrors saveSceneNow).
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = write_atomic.openContainerDir(io, std.Io.Dir.cwd(), st.dir()) catch {
        bctx.context().log(.err, "capture: open dir '{s}' failed", .{st.dir()});
        return;
    };
    defer dir.close(io);
    dir_opened.* = true;

    var name_buf: [32]u8 = undefined;
    const name = capture.frameName(&name_buf, st.done + 1);
    write_atomic.writeAtomic(io, dir, name, ppm) catch |e| {
        bctx.context().log(.err, "capture: write {s} failed: {s}", .{ name, @errorName(e) });
        return;
    };

    // 4) Append the manifest line (best-effort; appends are in-memory until finish).
    var line_buf: [128]u8 = undefined;
    const line = capture.manifestLine(&line_buf, st.done + 1, cam.eulers[0], cam.eulers[1], .{ cam.pos.x, cam.pos.y, cam.pos.z });
    manifest.appendSlice(line) catch {};

    st.done += 1;

    // 5) On the last frame, flush the manifest durably.
    if (st.finished()) {
        write_atomic.writeAtomic(io, dir, "manifest.txt", manifest.items) catch |e| {
            bctx.context().log(.err, "capture: write manifest failed: {s}", .{@errorName(e)});
        };
    }
}

/// --lint headless runner: lint `nav`, print each finding "[SEV] RULE: message
/// (refs...)" to stderr, and exit the process with code = error-count (clamped to
/// u8). No navmesh -> "no navmesh" + exit(2). Never returns.
fn runLintHeadless(gpa: std.mem.Allocator, nav: ?*recast.detour.NavMesh) noreturn {
    const out = nav orelse {
        std.debug.print("[lint] no navmesh built (load a mesh / build failed)\n", .{});
        std.process.exit(2);
    };
    var report = navmesh_lint.lint(out, 0.02, gpa) catch |e| {
        std.debug.print("[lint] error: {s}\n", .{@errorName(e)});
        std.process.exit(2);
    };
    defer report.deinit(gpa);

    for (report.findings.items) |*f| {
        const sev = switch (f.severity) {
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
        };
        // Append the culprit refs (if any) as a parenthesised hex list.
        var refbuf: [80]u8 = undefined;
        var rp: usize = 0;
        if (f.ref_count > 0) {
            rp += (std.fmt.bufPrint(refbuf[rp..], " (", .{}) catch refbuf[rp..rp]).len;
            for (0..f.ref_count) |i| {
                const sep = if (i == 0) "" else ", ";
                rp += (std.fmt.bufPrint(refbuf[rp..], "{s}0x{X}", .{ sep, f.refs[i] }) catch refbuf[rp..rp]).len;
            }
            rp += (std.fmt.bufPrint(refbuf[rp..], ")", .{}) catch refbuf[rp..rp]).len;
        }
        std.debug.print("[{s}] {s}: {s}{s}\n", .{ sev, @tagName(f.rule), f.message(), refbuf[0..rp] });
    }
    std.debug.print(
        "[lint] {d} error(s), {d} warning(s), {d} info\n",
        .{ report.error_count, report.warn_count, report.info_count },
    );
    const code: u8 = @intCast(@min(report.error_count, @as(usize, 255)));
    std.process.exit(code);
}

/// --verify headless runner: verify `nav`'s structural invariants, print each
/// violation "[INVARIANT] tile/poly/link: message" to stderr, and exit the
/// process with code = violation count (clamped to u8; 0 = clean for CI). No
/// navmesh -> exit(2). Mirrors runLintHeadless. Never returns.
fn runVerifyHeadless(gpa: std.mem.Allocator, nav: ?*recast.detour.NavMesh) noreturn {
    const out = nav orelse {
        std.debug.print("[verify] no navmesh built (load a mesh / build failed)\n", .{});
        std.process.exit(2);
    };
    var report = navmesh_verify.verify(out, gpa) catch |e| {
        std.debug.print("[verify] error: {s}\n", .{@errorName(e)});
        std.process.exit(2);
    };
    defer report.deinit(gpa);

    for (report.violations.items) |*v| {
        std.debug.print("[{s}] tile {d}/poly {d}/link {d}: {s}\n", .{ @tagName(v.invariant), v.tile, v.poly, v.link, v.message() });
    }
    std.debug.print("[verify] {d} violation(s)\n", .{report.count});
    const code: u8 = @intCast(@min(report.count, @as(usize, 255)));
    std.process.exit(code);
}

/// Загрузить меш по индексу: load -> build -> setNavMesh -> reset камеры.
fn loadMeshIndex(
    gpa: std.mem.Allocator,
    folder: []const u8,
    idx: usize,
    files: [][]u8,
    geom: *InputGeom,
    solo: *SampleSolo,
    tile: *SampleTile,
    temp: *SampleTempObstacles,
    tester: *NavMeshTesterTool,
    crowd_tool: *CrowdTool,
    cam: *Camera,
    bctx: *BuildContext,
) void {
    if (idx >= files.len) return;
    const p = std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, files[idx] }) catch return;
    defer gpa.free(p);
    geom.loadMesh(p) catch |e| {
        bctx.context().log(.err, "load mesh: {s}", .{@errorName(e)});
        return;
    };
    solo.setGeom(geom);
    tile.setGeom(geom);
    temp.setGeom(geom);
    cam.reset(Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]), Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]));
    {
        // Диапазон тумана по границам сцены (RecastDemo: camr=halfDiag*3, start=camr*0.1, end=camr*1.25).
        const dx = geom.bmax[0] - geom.bmin[0];
        const dy = geom.bmax[1] - geom.bmin[1];
        const dz = geom.bmax[2] - geom.bmin[2];
        const camr = @sqrt(dx * dx + dy * dy + dz * dz) / 2.0 * 3.0;
        solo.dd_gl.setFogRange(camr * 0.1, camr * 1.25);
    }
    _ = solo.build();
    tester.setNavMesh(solo.navMesh());
    crowd_tool.setNavMesh(solo.navMesh());
    bctx.context().log(.progress, "Loaded {s}", .{files[idx]});
}

// ===========================================================================
// Named scene variants (Save/Load): one mesh -> many `<stem>__<variant>.recastscene`
// containers, listed newest-first. UI-only helpers (the persist layer is untouched).
// ===========================================================================

/// Max sanitized variant length (file-name safe; keeps container names short).
const VARIANT_MAX = 24;

/// One saved variant of the current mesh: its display tag, the OWNED full container
/// path to pass to loadSceneNow, and the manifest mtime (ns) used to sort newest-first.
const SceneVariant = struct {
    variant: []const u8, // owned
    path: []const u8, // owned ("<folder>/<stem>__<variant>.recastscene")
    mtime_ns: i128,
};

/// Strip a mesh file's extension: "dungeon.obj" -> "dungeon" (last '.').
fn stemOf(mesh_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, mesh_name, '.');
    return if (dot) |d| mesh_name[0..d] else mesh_name;
}

/// Sanitize a user variant tag into a safe file-name fragment: keep [A-Za-z0-9-_],
/// replace anything else with '_', cap at VARIANT_MAX. Empty/all-stripped -> "default".
fn sanitizeVariant(in: []const u8, buf: *[VARIANT_MAX]u8) []const u8 {
    var n: usize = 0;
    for (in) |c| {
        if (n >= VARIANT_MAX) break;
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        buf[n] = if (ok) c else '_';
        n += 1;
    }
    if (n == 0) return "default";
    return buf[0..n];
}

/// Parse a container directory name back into its variant tag, given the current stem.
/// Rules (per design): the name must end with ".recastscene"; strip that. If what
/// remains is exactly `<stem>` -> legacy variant "default". Otherwise it must be
/// `<stem>__<variant>` (split on the LAST "__"; the prefix before it must equal stem).
/// Returns null if the name does not belong to this stem.
fn variantOf(dir_name: []const u8, stem: []const u8) ?[]const u8 {
    const ext = ".recastscene";
    if (!std.mem.endsWith(u8, dir_name, ext)) return null;
    const base = dir_name[0 .. dir_name.len - ext.len];
    if (std.mem.eql(u8, base, stem)) return "default"; // legacy "<stem>.recastscene"
    if (std.mem.lastIndexOf(u8, base, "__")) |i| {
        if (std.mem.eql(u8, base[0..i], stem)) return base[i + 2 ..];
    }
    return null;
}

/// Free a variant cache slice + its remembered stem; reset both to empty.
/// Permanently delete a scene-variant container directory. Guarded to only ever
/// remove a path that ends in ".recastscene".
fn deleteVariant(gpa: std.mem.Allocator, path: []const u8, bctx: *BuildContext) void {
    if (!std.mem.endsWith(u8, path, ".recastscene")) {
        bctx.context().log(.err, "Refused to delete non-scene path: {s}", .{path});
        return;
    }
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, path) catch |e| {
        bctx.context().log(.err, "Delete scene failed: {s}", .{@errorName(e)});
        return;
    };
    bctx.context().log(.progress, "Deleted scene variant: {s}", .{path});
}

fn freeVariants(gpa: std.mem.Allocator, variants: *[]SceneVariant, stem: *[]const u8) void {
    for (variants.*) |v| {
        gpa.free(v.variant);
        gpa.free(v.path);
    }
    if (variants.len > 0) gpa.free(variants.*);
    variants.* = &.{};
    if (stem.len > 0) gpa.free(stem.*);
    stem.* = "";
}

/// (Re)scan `folder` for directories matching `<stem>__*.recastscene` (and the legacy
/// `<stem>.recastscene`), build the variant list sorted by manifest mtime DESC
/// (newest first), and replace the cache. All errors are caught + logged (never crash);
/// on any failure the cache is left empty. Caps at 32 variants.
fn rebuildVariants(
    gpa: std.mem.Allocator,
    folder: []const u8,
    stem: []const u8,
    variants: *[]SceneVariant,
    stem_cache: *[]const u8,
    bctx: *BuildContext,
) void {
    // Drop the old cache first (always re-points stem_cache to the requested stem so we
    // don't rescan the same stem every frame even when it yields zero variants).
    freeVariants(gpa, variants, stem_cache);
    stem_cache.* = gpa.dupe(u8, stem) catch {
        bctx.context().log(.err, "Variants: stem dup failed", .{});
        return;
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var list = std.array_list.Managed(SceneVariant).init(gpa);
    defer list.deinit(); // items moved into the cache on success
    var ok = false;
    defer if (!ok) for (list.items) |v| {
        gpa.free(v.variant);
        gpa.free(v.path);
    };

    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |e| {
        bctx.context().log(.err, "Variants: open {s}: {s}", .{ folder, @errorName(e) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |e| {
        bctx.context().log(.err, "Variants: iterate {s}: {s}", .{ folder, @errorName(e) });
        return;
    }) |entry| {
        if (entry.kind != .directory) continue;
        const variant = variantOf(entry.name, stem) orelse continue;
        if (list.items.len >= 32) break;

        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, entry.name }) catch continue;
        // mtime from the manifest file (written LAST on save -> best "last-edited"
        // signal); fall back to the container dir's mtime if the manifest is absent.
        const manifest_sub = std.fmt.allocPrint(gpa, "{s}/manifest", .{path}) catch {
            gpa.free(path);
            continue;
        };
        defer gpa.free(manifest_sub);
        const mtime_ns: i128 = blk: {
            if (std.Io.Dir.cwd().statFile(io, manifest_sub, .{})) |st| {
                break :blk @intCast(st.mtime.nanoseconds);
            } else |_| {}
            if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
                break :blk @intCast(st.mtime.nanoseconds);
            } else |_| {}
            break :blk 0; // unknown mtime -> sorts oldest (name tiebreak below)
        };

        const vdup = gpa.dupe(u8, variant) catch {
            gpa.free(path);
            continue;
        };
        list.append(.{ .variant = vdup, .path = path, .mtime_ns = mtime_ns }) catch {
            gpa.free(vdup);
            gpa.free(path);
            continue;
        };
    }

    std.mem.sort(SceneVariant, list.items, {}, struct {
        fn lessThan(_: void, a: SceneVariant, b: SceneVariant) bool {
            if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns; // newest first
            return std.mem.lessThan(u8, a.variant, b.variant); // stable name tiebreak
        }
    }.lessThan);

    variants.* = list.toOwnedSlice() catch {
        bctx.context().log(.err, "Variants: toOwnedSlice failed", .{});
        return;
    };
    ok = true;
}

/// Save the current editable scene into a `<mesh>.recastscene/` container using the
// ===========================================================================
// F4 — area/flag PRESETS UI helpers (presets/ lives under the scene save root).
// All file I/O is best-effort: errors log a [WARN] and never crash the GUI.
// ===========================================================================

/// Free a cached preset-name list (owned name strings + the slice).
fn freePresetNames(gpa: std.mem.Allocator, names: *[][]u8) void {
    for (names.*) |n| gpa.free(n);
    if (names.len > 0) gpa.free(names.*);
    names.* = &.{};
}

/// (Re)scan `<folder>/presets/*.reg` and replace the cached name list. All errors
/// are caught + logged; on failure the cache is left empty.
fn rescanPresets(gpa: std.mem.Allocator, folder: []const u8, names: *[][]u8) void {
    freePresetNames(gpa, names);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |e| {
        std.debug.print("[WARN] presets: open scene root '{s}' failed: {s}\n", .{ folder, @errorName(e) });
        return;
    };
    defer root.close(io);
    names.* = presets.listPresets(gpa, io, root) catch |e| {
        std.debug.print("[WARN] presets: list failed: {s}\n", .{@errorName(e)});
        names.* = &.{};
        return;
    };
}

/// Save the CURRENT registry to `<folder>/presets/<name>.reg`. Errors -> [WARN], no crash.
fn savePresetNow(gpa: std.mem.Allocator, folder: []const u8, name: []const u8) void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |e| {
        std.debug.print("[WARN] presets: open scene root '{s}' failed: {s}\n", .{ folder, @errorName(e) });
        return;
    };
    defer root.close(io);
    presets.savePreset(gpa, io, root, name) catch |e| {
        std.debug.print("[WARN] presets: save '{s}' failed: {s}\n", .{ name, @errorName(e) });
        return;
    };
    std.debug.print("[INFO] presets: saved preset '{s}' to {s}/presets/\n", .{ name, folder });
}

/// Read `<folder>/presets/<name>.reg`, apply it (replace|merge) as ONE undo-able
/// edit recorded on `undo_stack`, and raise the same dirty signals the area editor
/// uses so live filters/costs refresh. Errors -> [WARN], no crash.
fn applyPresetNow(
    gpa: std.mem.Allocator,
    folder: []const u8,
    name: []const u8,
    merge: bool,
    undo_stack: *UndoStack,
    geom: *InputGeom,
) void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |e| {
        std.debug.print("[WARN] presets: open scene root '{s}' failed: {s}\n", .{ folder, @errorName(e) });
        return;
    };
    defer root.close(io);

    var sub_buf: [80]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "presets/{s}.reg", .{name}) catch {
        std.debug.print("[WARN] presets: name '{s}' too long\n", .{name});
        return;
    };
    const blob = root.readFileAlloc(io, sub, gpa, .unlimited) catch |e| {
        std.debug.print("[WARN] presets: read '{s}' failed: {s}\n", .{ sub, @errorName(e) });
        return;
    };
    defer gpa.free(blob);

    const mode: presets.ApplyMode = if (merge) .merge else .replace;
    const op = presets.applyBlob(gpa, blob, mode) catch |e| {
        std.debug.print("[WARN] presets: apply '{s}' failed: {s}\n", .{ name, @errorName(e) });
        return;
    };
    undo_stack.record(op);
    // applyBlob's op.apply already raised these, but the apply path here did NOT
    // call op.apply (the globals were mutated in-place by applyBlob) — so signal
    // explicitly to refresh live filters/costs + trigger a rebuild.
    area_types.rebuild_needed = true;
    area_types.costs_dirty = true;
    _ = geom;
    std.debug.print("[INFO] presets: applied preset '{s}' ({s}), {d} areas / {d} flags now\n", .{ name, if (merge) "merge" else "replace", area_types.count(), poly_flags.count() });
}

/// finished persistence layer (scene_container.saveScene). READ-ONLY w.r.t. live state:
/// it only reads `geom` + the built navmesh and writes files. Errors are caught and
/// logged (never propagated to a crash). Solo sample only.
fn saveSceneNow(
    gpa: std.mem.Allocator,
    geom: *const InputGeom,
    solo: *SampleSolo,
    folder: []const u8,
    mesh_name: []const u8,
    variant_in: []const u8,
    bctx: *BuildContext,
) void {
    const dt = recast.detour;

    // 1) Derive a deterministic container path with a variant tag:
    //    "<folder>/<stem>__<variant>.recastscene". Strip the mesh extension; fall back
    //    to "scene" if the name is empty. The variant is sanitized to a safe filename
    //    ([A-Za-z0-9-_], others -> '_', capped ~24); empty -> "default".
    const stem = stemOf(if (mesh_name.len > 0) mesh_name else "scene");
    var vbuf: [VARIANT_MAX]u8 = undefined;
    const variant = sanitizeVariant(variant_in, &vbuf);
    const container_path = std.fmt.allocPrint(gpa, "{s}/{s}__{s}.recastscene", .{ folder, stem, variant }) catch |e| {
        bctx.context().log(.err, "Save Scene: path alloc failed: {s}", .{@errorName(e)});
        return;
    };
    defer gpa.free(container_path);

    // 2) Acquire io exactly like io_util.zig / the persist tests (Threaded backend).
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 3) The .gset geometry reference written into scene.gset.
    const gset_name = if (mesh_name.len > 0) mesh_name else "mesh.obj";

    // 4) Tiles come from the live built navmesh (scene_container/tile_store walk
    //    mesh.tiles, take data[0..data_size] per valid tile, kind=mset). If there is
    //    no built navmesh, persist an empty one (geometry + registries + .gset still
    //    written, zero tiles) — never mutate live state.
    if (solo.navMesh()) |nm| {
        scene_container.saveScene(io, gpa, container_path, geom, nm, gset_name, null) catch |e| {
            bctx.context().log(.err, "Save Scene failed ({s}): {s}", .{ container_path, @errorName(e) });
            return;
        };
        bctx.context().log(.progress, "Saved scene to {s}", .{container_path});
    } else {
        // No built navmesh: build a throwaway empty navmesh just to satisfy the
        // *const dt.NavMesh param; saveAllTiles finds zero valid tiles.
        var empty = dt.NavMesh.init(gpa, dt.NavMeshParams.init()) catch |e| {
            bctx.context().log(.err, "Save Scene: empty navmesh init failed: {s}", .{@errorName(e)});
            return;
        };
        defer empty.deinit();
        scene_container.saveScene(io, gpa, container_path, geom, &empty, gset_name, null) catch |e| {
            bctx.context().log(.err, "Save Scene failed ({s}): {s}", .{ container_path, @errorName(e) });
            return;
        };
        bctx.context().log(.progress, "Saved scene to {s} (no navmesh built; 0 tiles)", .{container_path});
    }
}

/// Restore a `<mesh>.recastscene/` container produced by saveSceneNow and rebuild the
/// Solo navmesh from the restored geometry + area registry. MUTATES live state (geom,
/// the module-global registries, the navmesh, the tools) — so it is built to be safe:
///   * ALL errors are caught + logged via bctx and we return without crashing.
///   * The restore happens into a TEMP geom first; the live `geom` is only swapped in
///     once loadScene + the base-mesh reload BOTH succeed, so a failed/corrupt load
///     leaves the previous scene intact (no half-applied state).
/// Solo sample only (the caller gates sample_kind == .solo).
fn loadSceneNow(
    gpa: std.mem.Allocator,
    folder: []const u8,
    container_path: []const u8,
    mesh_name: []const u8,
    geom: *InputGeom,
    solo: *SampleSolo,
    tile: *SampleTile,
    temp: *SampleTempObstacles,
    tester: *NavMeshTesterTool,
    crowd_tool: *CrowdTool,
    prune_tool: *NavMeshPruneTool,
    cam: *Camera,
    bctx: *BuildContext,
) void {
    // 1) The caller passes the full "<folder>/<stem>__<variant>.recastscene" container
    //    path of the selected variant (legacy "<stem>.recastscene" also accepted as-is).

    // 2) io acquisition mirrors saveSceneNow / io_util (Threaded backend).
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 3) Restore into a TEMP geom so a failure cannot corrupt the live scene.
    //    loadScene resets+restores the module-global registries (area_types/poly_flags),
    //    then restores volumes/offmesh into `tmp_geom`. NOTE: this DOES mutate the
    //    global registries even on the temp path; that is acceptable (the registries are
    //    re-derived on the next successful save and a failed load only logs), and the
    //    invariant "registries before geometry" is owned entirely by loadScene.
    var tmp_geom = InputGeom.init(gpa);
    var tmp_geom_owned = true;
    defer if (tmp_geom_owned) tmp_geom.deinit();

    const lr = scene_container.loadScene(io, gpa, container_path, &tmp_geom) catch |e| {
        bctx.context().log(.err, "Load Scene failed ({s}): {s}", .{ container_path, @errorName(e) });
        return;
    };
    defer scene_container.freeLoadResult(gpa, lr);

    // 4) loadScene restored volumes/offmesh but NOT the base triangle mesh. Reload the
    //    .obj referenced by scene.gset (resolved under the meshes folder). ORDERING: we
    //    deliberately call loadMesh AFTER the loadScene restore because loadMesh clears
    //    ONLY verts/tris/normals and leaves volumes + off-mesh arrays untouched (verified
    //    in input_geom.loadMesh). So the restored edits SURVIVE the triangle reload and
    //    the final geom has BOTH the mesh triangles AND the restored volumes/offmesh.
    const obj_name = if (lr.mesh_name.len > 0) lr.mesh_name else mesh_name;
    if (obj_name.len == 0) {
        bctx.context().log(.err, "Load Scene: no mesh name in container {s}", .{container_path});
        return;
    }
    const obj_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, obj_name }) catch |e| {
        bctx.context().log(.err, "Load Scene: obj path alloc failed: {s}", .{@errorName(e)});
        return;
    };
    defer gpa.free(obj_path);
    tmp_geom.loadMesh(obj_path) catch |e| {
        bctx.context().log(.err, "Load Scene: reload mesh {s}: {s}", .{ obj_path, @errorName(e) });
        return;
    };

    // 5) Commit: swap the restored temp geom into the live `geom`. From here on the
    //    operation succeeds (the remaining steps are infallible build/tool wiring).
    geom.deinit();
    geom.* = tmp_geom;
    tmp_geom_owned = false; // ownership moved into `geom`; don't deinit it in defer.

    // 6) Rebuild the Solo navmesh from the restored geom + restored area registry.
    //    (Solo first-cut: regenerate from geometry. Direct saved-tile load via
    //    scene_container.loadTilesInto(io, gpa, container_path, lr.tiles, navmesh) is a
    //    documented follow-up — not wired here.)
    solo.setGeom(geom);
    tile.setGeom(geom);
    temp.setGeom(geom);
    cam.reset(Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]), Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]));
    {
        const dx = geom.bmax[0] - geom.bmin[0];
        const dy = geom.bmax[1] - geom.bmin[1];
        const dz = geom.bmax[2] - geom.bmin[2];
        const camr = @sqrt(dx * dx + dy * dy + dz * dz) / 2.0 * 3.0;
        solo.dd_gl.setFogRange(camr * 0.1, camr * 1.25);
    }
    _ = solo.build();

    // 7) Post-load tail (mirror loadMeshIndex): re-point the tools at the new navmesh,
    //    and reapply the restored area costs into the live filters. The main loop's
    //    build_gen sync would also re-point the tools next frame, but we do it eagerly
    //    here exactly like loadMeshIndex so no tool is left on a stale navmesh.
    const nm = solo.navMesh();
    tester.setNavMesh(nm);
    crowd_tool.setNavMesh(nm);
    prune_tool.setNavMesh(nm);
    area_types.applyCosts(&tester.filter);
    crowd_tool.reapplyAreaCosts();
    // Ensure any later cost edit still re-pushes; also harmless if already clean.
    area_types.costs_dirty = false;

    bctx.context().log(.progress, "Loaded scene {s} (mesh {s}, {d} saved tiles)", .{ container_path, obj_name, lr.tiles.len });
}

/// Точка пикинга: пересечение с мешем (если есть), иначе с плоскостью y=0.
/// XZ bbox (minx,minz,maxx,maxz) of all convex volumes + off-mesh endpoints in the
/// geom, or null if there are none. Used by the F6 incremental-rebuild dirty-tile
/// tracking: unioning the bbox from the frame BEFORE an edit with the one AFTER
/// covers add/move (object present after) AND delete (object present before).
const EditBBox = struct { minx: f32, minz: f32, maxx: f32, maxz: f32 };
fn geomEditBBox(geom: *const InputGeom) ?EditBBox {
    var any = false;
    var minx: f32 = std.math.floatMax(f32);
    var minz: f32 = std.math.floatMax(f32);
    var maxx: f32 = -std.math.floatMax(f32);
    var maxz: f32 = -std.math.floatMax(f32);
    for (geom.volumes.items) |*vol| {
        const nv: usize = @intCast(vol.nverts);
        var i: usize = 0;
        while (i < nv) : (i += 1) {
            const vx = vol.verts[i * 3 + 0];
            const vz = vol.verts[i * 3 + 2];
            minx = @min(minx, vx);
            maxx = @max(maxx, vx);
            minz = @min(minz, vz);
            maxz = @max(maxz, vz);
            any = true;
        }
    }
    const oc = geom.offMeshCount();
    var c: usize = 0;
    while (c < oc) : (c += 1) {
        const v = geom.off_verts.items[c * 6 ..][0..6];
        // both endpoints (start xyz, end xyz)
        for ([_]usize{ 0, 3 }) |o| {
            minx = @min(minx, v[o + 0]);
            maxx = @max(maxx, v[o + 0]);
            minz = @min(minz, v[o + 2]);
            maxz = @max(maxz, v[o + 2]);
            any = true;
        }
    }
    if (!any) return null;
    return .{ .minx = minx, .minz = minz, .maxx = maxx, .maxz = maxz };
}

fn pickPoint(geom: *const InputGeom, start: Vec3, end: Vec3) ?Vec3 {
    const s = start.toArray();
    const e = end.toArray();
    if (geom.raycastMesh(s, e)) |t| {
        return Vec3.init(s[0] + (e[0] - s[0]) * t, s[1] + (e[1] - s[1]) * t, s[2] + (e[2] - s[2]) * t);
    }
    return rayGroundHit(start, end);
}

// --- P1-2 poly overlay-label helpers ----------------------------------------

/// Mean Y of a polygon's outer-ring verts (its centroid height), used for the
/// clip/iso verdict in the `all`-mode visibility test. Mirrors poly_visit's
/// polyHeight (kept local so main doesn't import a private fn).
fn polyCentroidY(tile: *const recast.detour.MeshTile, p: *const recast.detour.Poly) f32 {
    if (p.vert_count == 0) return 0;
    var sum: f32 = 0;
    for (0..p.vert_count) |k| sum += tile.verts[@as(usize, p.verts[k]) * 3 + 1];
    return sum / @as(f32, @floatFromInt(p.vert_count));
}

/// Full XYZ centroid (average of outer-ring verts) of the poly behind `ref`.
fn polyCentroid(nm: *const recast.detour.NavMesh, ref: u32) ?Vec3 {
    const res = nm.getTileAndPolyByRef(ref) catch return null;
    const p = res.poly;
    if (p.vert_count == 0) return null;
    var sx: f32 = 0;
    var sy: f32 = 0;
    var sz: f32 = 0;
    for (0..p.vert_count) |k| {
        const o = @as(usize, p.verts[k]) * 3;
        sx += res.tile.verts[o + 0];
        sy += res.tile.verts[o + 1];
        sz += res.tile.verts[o + 2];
    }
    const n: f32 = @floatFromInt(p.vert_count);
    return Vec3.init(sx / n, sy / n, sz / n);
}

/// Format + draw one poly's overlay label at its on-screen centroid. Resolves the
/// area name/cost from the demo registry; culls when the centroid is off-screen or
/// behind the camera (worldToScreen null / depth outside [0,1]).
fn drawPolyLabel(
    nm: *const recast.detour.NavMesh,
    ref: u32,
    buf: []u8,
    col: dvui.Color,
    cam: Camera,
    viewport: [4]i32,
    vh: f32,
) void {
    const c = polyCentroid(nm, ref) orelse return;
    const area: u8 = nm.getPolyArea(ref) catch 0;
    const aname = if (area_types.get(area)) |at| at.name() else "?";
    const cost = poly_visit.polyCost(area);
    const txt = overlay.formatLabel(buf, ref, c.x, c.y, c.z, area, aname, cost);
    if (txt.len == 0) return;
    if (cam.worldToScreen(c, viewport)) |sp| {
        if (sp.z >= 0 and sp.z <= 1) ui.screenTextEx(sp.x, vh - sp.y, txt, col, true);
    }
}

/// P1-4 fly-to: frame the camera on a world XZ point. Y is the scene bbox mid; a
/// small bbox around the point is passed to cam.reset (reuses the existing framing
/// logic — eye placed back+up at a comfortable distance, default angles).
fn flyToXZ(cam: *Camera, geom: *const InputGeom, wx_in: f32, wz_in: f32) void {
    const ymid = (geom.bmin[1] + geom.bmax[1]) * 0.5;
    // Clamp the target INTO the scene bbox: a stray/edge click can't fling the
    // camera outside the scene (which would push everything past the fog and look
    // like a blackout). 1-unit pad keeps it just inside.
    const wx = std.math.clamp(wx_in, geom.bmin[0], geom.bmax[0]);
    const wz = std.math.clamp(wz_in, geom.bmin[2], geom.bmax[2]);
    // Frame a comfortable overview (was 0.12 — too tight, the camera ended up
    // almost inside the mesh and the fog hid everything but the immediate area).
    const ext = @max(@max(geom.bmax[0] - geom.bmin[0], geom.bmax[2] - geom.bmin[2]), 1.0);
    const r = ext * 0.30;
    cam.reset(
        Vec3.init(wx - r, ymid - r, wz - r),
        Vec3.init(wx + r, ymid + r, wz + r),
    );
}

/// Group-delete every selected object (F3) as ONE composite undo edit.
///
/// Resolves the selected STABLE ids to current array indices, then deletes in
/// DESCENDING index order so each delete leaves the remaining target indices
/// valid. Each delete is captured (full ConvexVolume / 6-field OffMeshData + its
/// former index) into an ops slice in deletion order. The composite's `revert`
/// runs the ops in REVERSE, so the ascending-index re-inserts reconstruct the
/// original list exactly (the invariant proved by the composite undo_stack test).
/// On any allocation failure the captured ops are freed and nothing is recorded
/// (the geom mutations already happened are left as-is — a no-undo edge case).
/// F5 inspector area dropdown: lists every `used` area type by name and writes
/// the chosen area id back into `area_proxy` (an f32 holding the u8 area). The
/// dropdown index <-> area-id mapping is rebuilt each frame from the registry so
/// it tracks add/remove of area types. Falls back to a passthrough label when no
/// types exist.
fn inspectorAreaDropdown(area_proxy: *f32) void {
    var labels: [area_types.MAX_AREA_TYPES][]const u8 = undefined;
    var ids: [area_types.MAX_AREA_TYPES]usize = undefined;
    var n: usize = 0;
    var cur_choice: usize = 0;
    var cur_found = false;
    const cur_id: usize = @intFromFloat(std.math.clamp(@round(area_proxy.*), 0, 63));
    var i: usize = 0;
    while (i < area_types.MAX_AREA_TYPES) : (i += 1) {
        if (area_types.get(i)) |t| {
            if (t.used) {
                labels[n] = t.name();
                ids[n] = i;
                if (i == cur_id) {
                    cur_choice = n;
                    cur_found = true;
                }
                n += 1;
            }
        }
    }
    // No used types, or the object's current area id isn't one of them: show the
    // raw id as a passthrough label and DO NOT overwrite area_proxy (a dropdown
    // here would silently clobber the value to the first used type on frame 1).
    if (n == 0 or !cur_found) {
        dvui.label(@src(), "area: {d} (unlisted)", .{cur_id}, .{});
        return;
    }
    dvui.labelNoFmt(@src(), "Area", .{}, .{});
    if (dvui.dropdown(@src(), labels[0..n], .{ .choice = &cur_choice }, .{}, .{ .expand = .horizontal })) {
        area_proxy.* = @floatFromInt(ids[cur_choice]);
    }
}

fn deleteSelected(alloc: std.mem.Allocator, geom: *InputGeom, sel: *Selection, undo_stack: *UndoStack) void {
    const Managed = std.array_list.Managed;
    // Collect current indices for each selected id (skip ids no longer present).
    var vol_idx = Managed(usize).init(alloc);
    defer vol_idx.deinit();
    var off_idx = Managed(usize).init(alloc);
    defer off_idx.deinit();

    for (sel.volumes.items) |id| {
        for (geom.volumes.items, 0..) |*v, i| {
            if (v.id == id) {
                vol_idx.append(i) catch std.debug.print("[WARN] select: OOM resolving volume id {d}, deleting fewer\n", .{id});
                break;
            }
        }
    }
    var oc: usize = 0;
    while (oc < geom.offMeshCount()) : (oc += 1) {
        for (sel.offmesh.items) |id| {
            if (geom.off_id.items[oc] == id) {
                off_idx.append(oc) catch std.debug.print("[WARN] select: OOM resolving off-mesh id {d}, deleting fewer\n", .{id});
                break;
            }
        }
    }

    // Sort both descending so we delete from the back forward (stable indices).
    std.mem.sort(usize, vol_idx.items, {}, comptime std.sort.desc(usize));
    std.mem.sort(usize, off_idx.items, {}, comptime std.sort.desc(usize));

    const total = vol_idx.items.len + off_idx.items.len;
    if (total == 0) return;

    var ops = alloc.alloc(edit_op.EditOp, total) catch return;
    var n: usize = 0;

    // Volumes first (descending), then off-mesh (descending). Capture BEFORE delete.
    for (vol_idx.items) |i| {
        ops[n] = .{ .delete_volume = .{ .index = i, .vol = geom.volumes.items[i] } };
        n += 1;
        geom.deleteConvexVolume(i);
    }
    for (off_idx.items) |i| {
        ops[n] = .{ .delete_offmesh = .{ .index = i, .data = edit_op.OffMeshData.capture(geom, i) } };
        n += 1;
        geom.deleteOffMeshConnection(i);
    }

    undo_stack.record(edit_op.makeComposite(alloc, ops));
    std.debug.print("[INFO] select: group-delete {d} volume(s) + {d} off-mesh (composite)\n", .{ vol_idx.items.len, off_idx.items.len });
}

/// World-unit XZ offset applied to pasted objects so the paste is visible and
/// not exactly overlapping the originals (F3 WAVE 2).
const PASTE_OFFSET: f32 = 1.0;

/// True when (px,pz) lands on an object that is ALREADY in the selection — used to
/// disambiguate select-tool LMB-down (hit-selected => move, else => box).
fn hitOnSelected(geom: *const InputGeom, sel: *const Selection, px: f32, pz: f32) bool {
    if (selection_mod.hitTest(geom, px, pz, 0.5)) |hit| {
        return switch (hit) {
            .volume => |id| sel.containsVolume(id),
            .offmesh => |id| sel.containsOffmesh(id),
        };
    }
    return false;
}

/// Snapshot the BEFORE-state of every selected object into `out` (keyed by id) so
/// a group move can recompute verts = snapshot + delta each frame. Ids no longer
/// present in geom are skipped. OOM drops the offending item (move proceeds with
/// fewer objects) rather than crashing.
fn snapshotSelection(geom: *const InputGeom, sel: *const Selection, out: *std.array_list.Managed(MoveSnapItem)) void {
    for (sel.volumes.items) |id| {
        for (geom.volumes.items) |*v| {
            if (v.id == id) {
                out.append(.{ .kind = .volume, .id = id, .vol = v.*, .off = undefined }) catch {};
                break;
            }
        }
    }
    for (sel.offmesh.items) |id| {
        for (geom.off_id.items, 0..) |oid, i| {
            if (oid == id) {
                out.append(.{ .kind = .offmesh, .id = id, .vol = undefined, .off = edit_op.OffMeshData.capture(geom, i) }) catch {};
                break;
            }
        }
    }
}

/// Re-apply an XZ delta to every snapshotted object's LIVE geom state from its
/// snapshot (verts = snapshot.verts + (dx,_,dz)). Recomputing from the snapshot
/// each call (rather than incrementally) keeps the drag drift-free. Y is unchanged.
fn applyMoveDelta(geom: *InputGeom, snap: *const std.array_list.Managed(MoveSnapItem), dx: f32, dz: f32) void {
    for (snap.items) |*it| {
        switch (it.kind) {
            .volume => {
                if (volIndexById(geom, it.id)) |vi| {
                    var v = it.vol; // snapshot copy
                    const n: usize = @intCast(v.nverts);
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        v.verts[k * 3 + 0] += dx;
                        v.verts[k * 3 + 2] += dz;
                    }
                    geom.volumes.items[vi] = v;
                }
            },
            .offmesh => {
                if (offIndexById(geom, it.id)) |oi| {
                    const base = oi * 6;
                    geom.off_verts.items[base + 0] = it.off.verts[0] + dx;
                    geom.off_verts.items[base + 1] = it.off.verts[1];
                    geom.off_verts.items[base + 2] = it.off.verts[2] + dz;
                    geom.off_verts.items[base + 3] = it.off.verts[3] + dx;
                    geom.off_verts.items[base + 4] = it.off.verts[4];
                    geom.off_verts.items[base + 5] = it.off.verts[5] + dz;
                }
            },
        }
    }
}

/// Record a single composite of edit_volume/edit_offmesh ops capturing each moved
/// object's BEFORE (snapshot) and AFTER (current live geom) state. Id-keyed, so it
/// survives later list reordering. OOM -> skip the undo record (geom already moved).
fn commitMove(alloc: std.mem.Allocator, geom: *InputGeom, snap: *const std.array_list.Managed(MoveSnapItem), undo_stack: *UndoStack) void {
    if (snap.items.len == 0) return;
    // Build into an ArrayList so toOwnedSlice yields an exactly-sized heap slice
    // (some snapshot ids could be absent — skip those). On OOM, skip the undo
    // record (the geom is already moved; just no undo for this move).
    var list = std.array_list.Managed(edit_op.EditOp).init(alloc);
    for (snap.items) |*it| {
        switch (it.kind) {
            .volume => {
                if (volIndexById(geom, it.id)) |vi|
                    list.append(.{ .edit_volume = .{ .id = it.id, .before = it.vol, .after = geom.volumes.items[vi] } }) catch {};
            },
            .offmesh => {
                if (offIndexById(geom, it.id)) |oi|
                    list.append(.{ .edit_offmesh = .{ .id = it.id, .before = it.off, .after = edit_op.OffMeshData.capture(geom, oi) } }) catch {};
            },
        }
    }
    if (list.items.len == 0) {
        list.deinit();
        return;
    }
    const ops = list.toOwnedSlice() catch {
        list.deinit();
        return;
    };
    undo_stack.record(edit_op.makeComposite(alloc, ops));
}

/// Copy the current selection into the clipboard (value copies). Ctrl+C / button.
fn doCopy(clipboard: *Clipboard, geom: *const InputGeom, sel: *const Selection) void {
    clipboard.copyFrom(geom, sel) catch |e| {
        std.debug.print("[WARN] select: copy failed: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("[INFO] select: copied {d} volume(s) + {d} off-mesh\n", .{ clipboard.volumes.items.len, clipboard.offmesh.items.len });
}

/// Paste every clipboard object into geom with a small XZ offset, each as a FRESH
/// id (add_volume/add_offmesh), recorded as ONE composite ("paste = one undo").
/// Volumes preserve mode/band/area/verts (offset applied); off-mesh endpoints are
/// offset too. After paste the selection is REPLACED with the new objects' ids so
/// the user can immediately move them. OOM on the ops slice -> skip the undo.
fn doPaste(alloc: std.mem.Allocator, clipboard: *const Clipboard, geom: *InputGeom, sel: *Selection, undo_stack: *UndoStack) void {
    if (clipboard.isEmpty()) return;
    // Build the add-ops into an ArrayList -> exactly-sized owned slice for the
    // composite (one undo). On OOM, skip the undo record (objects still pasted).
    var list = std.array_list.Managed(edit_op.EditOp).init(alloc);
    sel.clear();

    for (clipboard.volumes.items) |src| {
        // Translate every vertex by the paste offset (XZ), keep Y.
        var verts: [12 * 3]f32 = src.verts;
        const nv: usize = @intCast(src.nverts);
        var k: usize = 0;
        while (k < nv) : (k += 1) {
            verts[k * 3 + 0] += PASTE_OFFSET;
            verts[k * 3 + 2] += PASTE_OFFSET;
        }
        // addConvexVolume assigns a FRESH id but doesn't take mode/band; set them on
        // the appended volume, then capture THAT final volume as the add op so
        // undo/redo reproduce mode/band.
        geom.addConvexVolume(verts[0 .. nv * 3], src.nverts, src.hmin, src.hmax, src.area) catch continue;
        const li = geom.volumes.items.len - 1;
        geom.volumes.items[li].mode = src.mode;
        geom.volumes.items[li].band_below = src.band_below;
        geom.volumes.items[li].band_above = src.band_above;
        list.append(.{ .add_volume = geom.volumes.items[li] }) catch {};
        sel.volumes.append(geom.volumes.items[li].id) catch {};
    }

    for (clipboard.offmesh.items) |src| {
        const start = [3]f32{ src.verts[0] + PASTE_OFFSET, src.verts[1], src.verts[2] + PASTE_OFFSET };
        const end = [3]f32{ src.verts[3] + PASTE_OFFSET, src.verts[4], src.verts[5] + PASTE_OFFSET };
        geom.addOffMeshConnection(start, end, src.rad, src.dir, src.area, src.flags) catch continue;
        const li = geom.offMeshCount() - 1;
        list.append(.{ .add_offmesh = edit_op.OffMeshData.capture(geom, li) }) catch {};
        sel.offmesh.append(geom.off_id.items[li]) catch {};
    }

    if (list.items.len == 0) {
        list.deinit();
        return;
    }
    const ops = list.toOwnedSlice() catch {
        list.deinit();
        return;
    };
    undo_stack.record(edit_op.makeComposite(alloc, ops));
    std.debug.print("[INFO] select: pasted {d} volume(s) + {d} off-mesh (composite)\n", .{ clipboard.volumes.items.len, clipboard.offmesh.items.len });
}

/// Locate a convex volume's array index by stable id (move helpers).
fn volIndexById(geom: *const InputGeom, id: u32) ?usize {
    for (geom.volumes.items, 0..) |*v, i| if (v.id == id) return i;
    return null;
}

/// Locate an off-mesh connection's array index by stable off_id (move helpers).
fn offIndexById(geom: *const InputGeom, id: u32) ?usize {
    for (geom.off_id.items, 0..) |oid, i| if (oid == id) return i;
    return null;
}

/// Пересечение луча (start->end) с плоскостью y=0.
fn rayGroundHit(start: Vec3, end: Vec3) ?Vec3 {
    const dy = end.y - start.y;
    if (@abs(dy) < 1e-6) return null;
    const t = -start.y / dy;
    if (t < 0 or t > 1) return null;
    return start.add(end.sub(start).scale(t));
}
