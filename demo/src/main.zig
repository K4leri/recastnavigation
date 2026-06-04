//! RecastDemo — GUI-визуализатор navmesh (порт recastnavigation/RecastDemo).
//! Бэкенд: DVUI (glfw + OpenGL render_backend), 3D-рендер на модерн GL 3.3 core (zgl).
//!
//! Задача #9: окно + GL-контекст + dvui ontop + кадровый цикл.

const std = @import("std");
const builtin = @import("builtin");
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
const SampleSolo = @import("sample_solo.zig").SampleSolo;
const scheme_state = @import("render/scheme_state.zig");
const SampleTile = @import("sample_tile.zig").SampleTile;
const SampleTempObstacles = @import("sample_temp_obstacles.zig").SampleTempObstacles;
const NavMeshTesterTool = @import("tool_navmesh_tester.zig").NavMeshTesterTool;
const OffMeshConnectionTool = @import("tool_offmesh.zig").OffMeshConnectionTool;
const ConvexVolumeTool = @import("tool_convex.zig").ConvexVolumeTool;
const CrowdTool = @import("tool_crowd.zig").CrowdTool;
const NavMeshPruneTool = @import("tool_prune.zig").NavMeshPruneTool;
const Vec3 = recast.math.Vec3;

const ActiveTool = tool_registry.ToolId; // { none, tester, prune, offmesh, convex, crowd }

// Управление обработкой ошибок OpenGL в zgl.
pub const opengl_error_handling = zgl.ErrorHandling.assert;

var g_window: *zglfw.Window = undefined;
var g_scroll: f64 = 0; // аккумулятор колеса (пишется из callback)

fn glGetProcAddress(p: zglfw.GlProc, proc: [:0]const u8) ?zgl.binding.FunctionPointer {
    _ = p;
    return @alignCast(zglfw.getProcAddress(proc));
}

fn scrollCallback(_: *zglfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    g_scroll += yoffset;
}

extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(.winapi) c_int;

pub fn main(main_init: std.process.Init) !void {
    if (dvui.render_backend.kind != .opengl) @compileError("ожидается opengl render_backend");

    // Make the process DPI-UNAWARE *before* glfw initialises (glfw respects an
    // already-set awareness). The dvui glfw backend scales cursor coordinates by
    // glfwGetWindowContentScale() while laying the UI out at the raw framebuffer
    // size (which on Windows equals the window size, i.e. scale 1). On a high-DPI
    // monitor (e.g. a 4K @ 150%) contentScale is 1.5 but the framebuffer is not,
    // so the cursor is pushed 1.5x too far and clicks land below/right of the
    // target — only on the hi-DPI monitor. DPI-unaware forces contentScale to 1.0
    // everywhere, so clicks are correct on every monitor (Windows bitmap-scales
    // the window on hi-DPI). DPI_AWARENESS_CONTEXT_UNAWARE == (HANDLE)-1.
    if (builtin.os.tag == .windows) {
        const DPI_AWARENESS_CONTEXT_UNAWARE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_UNAWARE);
    }

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

    var tester = NavMeshTesterTool.init(main_init.gpa, &dd_gl);
    defer tester.deinit();
    var offmesh_tool = OffMeshConnectionTool.init(&geom, &dd_gl);
    var convex_tool = ConvexVolumeTool.init(main_init.gpa, &geom, &dd_gl);
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
    var variant_name: [32]u8 = [_]u8{0} ** 32; // поле ввода тега варианта сцены (Save Scene)
    // Кэш списка вариантов сцены (Load): сканируется по требованию (кнопка Refresh и
    // при смене меша), не каждый кадр. Освобождается через freeVariants.
    var variants: []SceneVariant = &.{};
    var variants_stem: []const u8 = ""; // stem, для которого построен кэш (owned)
    defer freeVariants(main_init.gpa, &variants, &variants_stem);
    var pick_hit: ?Vec3 = null; // последняя точка пикинга по земле
    const dt: f32 = 1.0 / 60.0;

    // фикс-прямоугольники окон (как статичные окна RecastDemo по краям)
    var props_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var tools_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var log_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var test_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var flags_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var show_flags: bool = false; // the Poly Flags manager window (hidden by default)
    var test_choice: usize = 0;

    // bench-режим (--bench): камера крутится на 360°, без idle/cap, фикс число
    // кадров, затем печать средней нагрузки. Для профилирования под нагрузкой.
    var bench = false;
    var cycle_modes = false; // --cyclemodes: перебор всех draw-режимов (поиск крашей)
    var shot_draw: ?[]const u8 = null; // --draw=<имя>: фикс draw-режим для скриншот-сравнения
    var shot_cam: ?[5]f32 = null; // --cam=pitch,yaw,x,y,z: задать ракурс камеры для сравнения
    {
        var it = try std.process.Args.Iterator.initAllocator(main_init.minimal.args, main_init.gpa);
        defer it.deinit();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--bench")) bench = true;
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
            bench_angle += 36.0 / 60.0; // ~36°/с при 60 эфф. кадров -> 360° за 10с
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
        if (g_window.getKey(.f) == .press or g_window.getKey(.home) == .press) {
            cam.reset(
                Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]),
                Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]),
            );
        }
        // C — переключить режим отсечения граней (0=off, 1=back, 2=front) для подбора winding
        const c_now = g_window.getKey(.c) == .press;
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
        // Клавиша V — вариант рендера вокселей (8 шт). Активный вариант — в заголовке окна.
        const vox_names = [_][:0]const u8{ "0:BASE mesh+fog+back+LEQUAL", "1:NO-MESH", "2:NO-FOG", "3:NO-MESH+NO-FOG", "4:CULL-OFF", "5:CULL-FRONT", "6:LESS", "7:NO-BLEND" };
        const v_now = g_window.getKey(.v) == .press;
        if (v_now and !prev_v) {
            dd_gl.voxel_variant +%= 1;
            std.debug.print("[VOXVAR] {s}\n", .{vox_names[dd_gl.voxel_variant % 8]});
        }
        prev_v = v_now;
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
                    const rs = r.start.toArray();
                    const hp = h.toArray();
                    if (sample_kind == .temp) {
                        temp.onClick(&rs, &hp, shift); // препятствия
                    } else switch (active_tool) {
                        .none => {
                            // Инспекция: клик по навмешу печатает инфо полигона под точкой.
                            if (tester.query) |q| {
                                const ext = [3]f32{ 2, 4, 2 };
                                var ref: u32 = 0;
                                var snap: [3]f32 = undefined;
                                _ = q.findNearestPoly(&hp, &ext, &tester.filter, &ref, &snap) catch {};
                                if (ref != 0) {
                                    const flags = if (tester.navmesh) |nm| (nm.getPolyFlags(ref) catch 0) else 0;
                                    std.debug.print("[POLY] ref={d} navmeshY={d:.2} clickHitY={d:.2} world=({d:.2},{d:.2},{d:.2}) flags=0x{x}\n", .{ ref, snap[1], hp[1], snap[0], snap[1], snap[2], flags });
                                } else {
                                    std.debug.print("[POLY] под кликом нет полигона (hitY={d:.2}, world x={d:.2} z={d:.2})\n", .{ hp[1], hp[0], hp[2] });
                                }
                            }
                        },
                        .tester => tester.onClick(&rs, &hp, shift),
                        .prune => prune_tool.onClick(&rs, &hp, shift),
                        .offmesh => offmesh_tool.onClick(&rs, &hp, shift),
                        .convex => convex_tool.onClick(&rs, &hp, shift),
                        .crowd => crowd_tool.onClick(&rs, &hp, shift),
                    }
                    pick_hit = h;
                }
            }
        }
        prev_lmb = lmb;

        // перестройка navmesh, если инструмент изменил геометрию
        if (offmesh_tool.dirty or convex_tool.dirty) {
            offmesh_tool.dirty = false;
            convex_tool.dirty = false;
            switch (sample_kind) {
                .solo => _ = solo.build(),
                .tile => _ = tile.build(),
                .temp => _ = temp.build(),
            }
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
            const fh: f32 = 116 + @as(f32, @floatFromInt(poly_flags.count())) * 28;
            flags_rect = .{ .x = wr.w - colw - 3 * padw - 380, .y = padw, .w = 380, .h = fh };
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
                }
            }
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

                // --- Load: scrollable selectable list of this mesh's variants ---
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer row.deinit();
                    dvui.labelNoFmt(@src(), "Variants (newest first)", .{}, .{ .gravity_y = 0.5 });
                    if (dvui.button(@src(), "Refresh", .{}, .{ .id_extra = 996, .gravity_x = 1.0 })) {
                        rebuildVariants(main_init.gpa, app.meshes_folder, cur_stem, &variants, &variants_stem, &bctx);
                    }
                }
                if (variants.len == 0) {
                    dvui.labelNoFmt(@src(), "(no saved variants)", .{}, .{});
                } else {
                    // Height fits the variant count (cap ~8 rows, scroll beyond), so a
                    // short list shows no empty space — same idea as the Poly Flags window.
                    const list_rows: f32 = @floatFromInt(@min(variants.len, 8));
                    var vsc = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = list_rows * 30 } });
                    defer vsc.deinit();
                    for (variants, 0..) |v, vi| {
                        // index 0 = newest -> highlighted as the default selection.
                        const lbl = if (vi == 0)
                            std.fmt.allocPrint(main_init.gpa, "{s}  (newest)", .{v.variant}) catch v.variant
                        else
                            v.variant;
                        defer if (vi == 0 and lbl.ptr != v.variant.ptr) main_init.gpa.free(lbl);
                        if (dvui.button(@src(), lbl, .{}, .{ .id_extra = 5000 + vi, .expand = .horizontal })) {
                            loadSceneNow(main_init.gpa, app.meshes_folder, v.path, cur_name, &geom, &solo, &tile, &temp, &tester, &crowd_tool, &prune_tool, &cam, &bctx);
                        }
                    }
                }
            }

            ui.section(@src(), "Navmesh Colouring");
            if (ui.radio(@src(), scheme_state.active == .area, "Area", 310)) scheme_state.active = .area;
            if (ui.radio(@src(), scheme_state.active == .flags, "Flags", 311)) scheme_state.active = .flags;
            if (ui.radio(@src(), scheme_state.active == .height, "Height", 312)) scheme_state.active = .height;
            if (ui.radio(@src(), scheme_state.active == .component, "Component", 313)) scheme_state.active = .component;

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
                        poly_flags.removeFlag(i);
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
                        _ = poly_flags.addFlag(name); // ASCII/English names only (font has no Cyrillic)
                        @memset(&new_flag_name, 0);
                    }
                }
            }
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

            // подписи агентов толпы (индекс над агентом) — по чекбоксу Show Labels
            if (active_tool == .crowd and crowd_tool.show_labels) {
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
            if (active_tool == .crowd and crowd_tool.debug.idx != -1 and crowd_tool.show_neighbors) {
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
            if (active_tool == .crowd and crowd_tool.has_target) {
                const wp = Vec3.init(crowd_tool.target_pos[0], crowd_tool.target_pos[1], crowd_tool.target_pos[2]);
                if (cam.worldToScreen(wp, viewport)) |sp| {
                    if (sp.z >= 0 and sp.z <= 1) ui.screenTextEx(sp.x, vh - sp.y, "TARGET", white, true);
                }
            }

            // подписи тестов (T<index> над точкой старта)
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
fn pickPoint(geom: *const InputGeom, start: Vec3, end: Vec3) ?Vec3 {
    const s = start.toArray();
    const e = end.toArray();
    if (geom.raycastMesh(s, e)) |t| {
        return Vec3.init(s[0] + (e[0] - s[0]) * t, s[1] + (e[1] - s[1]) * t, s[2] + (e[2] - s[2]) * t);
    }
    return rayGroundHit(start, end);
}

/// Пересечение луча (start->end) с плоскостью y=0.
fn rayGroundHit(start: Vec3, end: Vec3) ?Vec3 {
    const dy = end.y - start.y;
    if (@abs(dy) < 1e-6) return null;
    const t = -start.y / dy;
    if (t < 0 or t > 1) return null;
    return start.add(end.sub(start).scale(t));
}
