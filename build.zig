const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy-профилирование demo: zig build run-demo -Dtracy=true
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiling in demo") orelse false;

    // Demo (и его dvui/zgl-зависимости) по умолчанию ReleaseSafe: оптимизировано
    // (immediate-mode UI dvui в Debug в ~4× медленнее), но с safety-проверками и
    // детерминированным заполнением undefined (0xAA) — иначе ReleaseFast вскрывает
    // latent-UB в core-пайплайне (мусорная геометрия, фликер). Для отладки демо:
    // -Ddemo-optimize=Debug; для максимума скорости (на свой риск) ReleaseFast.
    const demo_optimize = b.option(std.builtin.OptimizeMode, "demo-optimize", "Optimize mode for demo (default ReleaseSafe)") orelse .ReleaseSafe;

    // Main library module
    const recast_nav = b.addModule("recast-nav", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Production library with safety checks enabled (ReleaseSafe mode)
    // This provides performance optimizations while maintaining runtime safety
    const recast_nav_safe = b.addModule("recast-nav-safe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe, // Optimized but with safety checks
    });

    const lib_safe = b.addLibrary(.{
        .name = "recast-nav-safe",
        .root_module = recast_nav_safe,
        .linkage = .static,
    });
    b.installArtifact(lib_safe);

    // Static library
    const lib = b.addLibrary(.{
        .name = "recast-nav",
        .root_module = recast_nav,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ====================================================================
    // RECAST DEMO - GUI приложение (порт RecastDemo на DVUI + GLFW/OpenGL)
    // ====================================================================
    // lazyDependency: демо-зависимости тянутся/оцениваются только когда реально
    // собирается таргет demo/run-demo. Сборка библиотеки и тестов их не трогает.
    if (b.lazyDependency("dvui", .{
        .target = target,
        .optimize = demo_optimize,
        .backend = .glfw,
        // подсветка синтаксиса (tree-sitter) нам не нужна — отключаем лишние C-deps.
        .@"tree-sitter" = false,
        // stb_truetype вместо C-freetype (минус зависимость).
        .freetype = false,
    })) |dvui_dep| if (b.lazyDependency("zgl", .{
        .target = target,
        .optimize = demo_optimize,
    })) |zgl_dep| {
        const demo_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/main.zig"),
            .target = target,
            .optimize = demo_optimize,
        });
        demo_mod.addImport("recast-nav", recast_nav);
        demo_mod.addImport("dvui", dvui_dep.module("dvui_glfw"));
        // прямой доступ к glfw-бэкенду (zglfw, Backend.init) — как в примере dvui
        demo_mod.addImport("glfw-backend", dvui_dep.module("glfw"));

        // zgl сам по себе не линкует системный GL — добавляем по платформе.
        const zgl_mod = zgl_dep.module("zgl");
        switch (target.result.os.tag) {
            .windows => zgl_mod.linkSystemLibrary("opengl32", .{}),
            .linux => zgl_mod.linkSystemLibrary("GL", .{}),
            .macos => zgl_mod.linkFramework("OpenGL", .{}),
            else => {},
        }
        demo_mod.addImport("zgl", zgl_mod);

        // Tracy: опции + модуль ztracy (само-гейтится через enable_ztracy).
        const demo_options = b.addOptions();
        demo_options.addOption(bool, "enable_tracy", enable_tracy);
        demo_mod.addImport("build_options", demo_options.createModule());

        const ztracy_dep = b.dependency("ztracy", .{
            .target = target,
            .optimize = demo_optimize,
            .enable_ztracy = enable_tracy,
            .on_demand = true,
        });
        demo_mod.addImport("ztracy", ztracy_dep.module("root"));

        const demo_exe = b.addExecutable(.{
            .name = "recast_demo",
            .root_module = demo_mod,
            // self-hosted x86_64 backend не умеет tail calls, которые генерит zgl
            // (см. коммент в dvui примере glfw-opengl-ontop) — нужен LLVM.
            .use_llvm = true,
        });
        // C-клиент Tracy линкуем только когда профилирование включено.
        if (enable_tracy) demo_exe.root_module.linkLibrary(ztracy_dep.artifact("tracy"));
        const install_demo = b.addInstallArtifact(demo_exe, .{});

        // Ассеты рядом с exe (zig-out/bin/test_data) — чтобы установленный demo
        // запускался standalone (резолвер ассетов ищет <exeDir>/test_data в первую очередь).
        const install_assets = b.addInstallDirectory(.{
            .source_dir = b.path("test_data"),
            .install_dir = .bin,
            .install_subdir = "test_data",
        });

        const demo_step = b.step("demo", "Build RecastDemo GUI");
        demo_step.dependOn(&install_demo.step);
        demo_step.dependOn(&install_assets.step);

        const run_demo = b.addRunArtifact(demo_exe);
        run_demo.step.dependOn(&install_demo.step);
        run_demo.step.dependOn(&install_assets.step);
        const run_demo_step = b.step("run-demo", "Run RecastDemo GUI");
        run_demo_step.dependOn(&run_demo.step);
    };

    // Тесты математики демо (не требуют dvui/glfw — только recast-nav).
    {
        const mat_test_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        });
        mat_test_mod.addImport("recast-nav", recast_nav);
        const mat_test = b.addTest(.{ .root_module = mat_test_mod });
        const demo_test_step = b.step("demo-test", "Тесты математики демо");
        demo_test_step.dependOn(&b.addRunArtifact(mat_test).step);
    }

    // ====================================================================
    // OPTIMIZED TESTING ARCHITECTURE - SOLUTION TO LAZY COMPILATION
    // ====================================================================

    // Instead of creating separate test modules for each test file,
    // we use a single centralized test runner that imports all unit tests.
    // This solves Zig's lazy compilation issue where test files are
    // not compiled unless explicitly referenced.

    // CORE UNIT TESTS - Single Module Solution with Safety Checks
    // Tests should always run in Debug mode for maximum safety and error detection
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("test/all_tests.zig"),
        .target = target,
        .optimize = .Debug, // Force Debug mode for comprehensive testing
    });
    unit_test_module.addImport("recast-nav", recast_nav);

    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Main test step now includes all unit tests through centralized runner
    const test_step = b.step("test", "Run all library tests");
    test_step.dependOn(&run_unit_tests.step);

    // ====================================================================
    // SPECIALIZED TEST MODULES - Only for complex integration tests
    // ====================================================================

    // OBJ Loader utility (used by multiple integration tests)
    const obj_loader = b.addModule("obj_loader", .{
        .root_source_file = b.path("test/obj_loader.zig"),
    });

    // Integration Tests - Keep separate as they have different dependencies
    // Also run in Debug mode for maximum safety during complex integration scenarios
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/all.zig"),
        .target = target,
        .optimize = .Debug, // Force Debug mode for comprehensive integration testing
    });
    integration_test_module.addImport("zig-recast", recast_nav);
    integration_test_module.addImport("obj_loader", obj_loader);
    const integration_tests = b.addTest(.{
        .root_module = integration_test_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Add integration tests to main test step
    test_step.dependOn(&run_integration_tests.step);

    // ====================================================================
    // INDIVIDUAL TEST EXECUTABLES - For specific scenarios
    // ====================================================================

    // Raycast test executable (kept as standalone for specific testing scenarios)
    const raycast_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/raycast_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raycast_test_module.addImport("zig-recast", recast_nav);
    raycast_test_module.addImport("obj_loader", obj_loader);
    const raycast_test_exe = b.addExecutable(.{
        .name = "raycast_test",
        .root_module = raycast_test_module,
    });

    const install_raycast_test = b.addInstallArtifact(raycast_test_exe, .{});
    const raycast_test_step = b.step("raycast-test", "Build raycast test executable");
    raycast_test_step.dependOn(&install_raycast_test.step);

    // ====================================================================
    // EXAMPLES - Unchanged
    // ====================================================================

    const example_simple_module = b.createModule(.{
        .root_source_file = b.path("examples/simple_navmesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_simple_module.addImport("recast-nav", recast_nav);
    const example_simple = b.addExecutable(.{
        .name = "simple_navmesh",
        .root_module = example_simple_module,
    });

    const example_pathfinding_module = b.createModule(.{
        .root_source_file = b.path("examples/pathfinding_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_pathfinding_module.addImport("recast-nav", recast_nav);
    const example_pathfinding = b.addExecutable(.{
        .name = "pathfinding_demo",
        .root_module = example_pathfinding_module,
    });

    const example_crowd_module = b.createModule(.{
        .root_source_file = b.path("examples/crowd_simulation.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_crowd_module.addImport("recast-nav", recast_nav);
    const example_crowd = b.addExecutable(.{
        .name = "crowd_simulation",
        .root_module = example_crowd_module,
    });

    const example_dynamic_obstacles_module = b.createModule(.{
        .root_source_file = b.path("examples/dynamic_obstacles.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_dynamic_obstacles_module.addImport("recast-nav", recast_nav);
    const example_dynamic_obstacles = b.addExecutable(.{
        .name = "dynamic_obstacles",
        .root_module = example_dynamic_obstacles_module,
    });

    const install_example_simple = b.addInstallArtifact(example_simple, .{});
    const install_example_pathfinding = b.addInstallArtifact(example_pathfinding, .{});
    const install_example_crowd = b.addInstallArtifact(example_crowd, .{});
    const install_example_dynamic_obstacles = b.addInstallArtifact(example_dynamic_obstacles, .{});

    const example_step = b.step("examples", "Build examples");
    example_step.dependOn(&install_example_simple.step);
    example_step.dependOn(&install_example_pathfinding.step);
    example_step.dependOn(&install_example_crowd.step);
    example_step.dependOn(&install_example_dynamic_obstacles.step);

    // ====================================================================
    // PERFORMANCE BENCHMARKS - Unchanged
    // ====================================================================

    const bench_recast_module = b.createModule(.{
        .root_source_file = b.path("bench/recast_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_recast_module.addImport("zig-recast", recast_nav);
    const bench_recast = b.addExecutable(.{
        .name = "recast_bench",
        .root_module = bench_recast_module,
    });

    const bench_detour_module = b.createModule(.{
        .root_source_file = b.path("bench/detour_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_detour_module.addImport("zig-recast", recast_nav);
    const bench_detour = b.addExecutable(.{
        .name = "detour_bench",
        .root_module = bench_detour_module,
    });

    const bench_crowd_module = b.createModule(.{
        .root_source_file = b.path("bench/crowd_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_crowd_module.addImport("zig-recast", recast_nav);
    const bench_crowd = b.addExecutable(.{
        .name = "crowd_bench",
        .root_module = bench_crowd_module,
    });

    const bench_findstraightpath_module = b.createModule(.{
        .root_source_file = b.path("bench/findStraightPath_detailed.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_findstraightpath_module.addImport("zig-recast", recast_nav);
    const bench_findstraightpath = b.addExecutable(.{
        .name = "findStraightPath_detailed",
        .root_module = bench_findstraightpath_module,
    });

    const install_bench_recast = b.addInstallArtifact(bench_recast, .{});
    const install_bench_detour = b.addInstallArtifact(bench_detour, .{});
    const install_bench_crowd = b.addInstallArtifact(bench_crowd, .{});
    const install_bench_findstraightpath = b.addInstallArtifact(bench_findstraightpath, .{});

    const bench_step = b.step("bench", "Build all benchmarks");
    bench_step.dependOn(&install_bench_recast.step);
    bench_step.dependOn(&install_bench_detour.step);
    bench_step.dependOn(&install_bench_crowd.step);
    bench_step.dependOn(&install_bench_findstraightpath.step);

    // Run benchmark steps
    const run_bench_recast = b.addRunArtifact(bench_recast);
    const run_bench_detour = b.addRunArtifact(bench_detour);
    const run_bench_crowd = b.addRunArtifact(bench_crowd);
    const run_bench_findstraightpath = b.addRunArtifact(bench_findstraightpath);

    const run_bench_recast_step = b.step("bench-recast", "Run Recast performance benchmarks");
    run_bench_recast_step.dependOn(&run_bench_recast.step);

    const run_bench_detour_step = b.step("bench-detour", "Run Detour performance benchmarks");
    run_bench_detour_step.dependOn(&run_bench_detour.step);

    const run_bench_crowd_step = b.step("bench-crowd", "Run Crowd performance benchmarks");
    run_bench_crowd_step.dependOn(&run_bench_crowd.step);

    const run_bench_findstraightpath_step = b.step("bench-findstraightpath", "Run detailed findStraightPath benchmarks");
    run_bench_findstraightpath_step.dependOn(&run_bench_findstraightpath.step);

    const run_all_bench_step = b.step("bench-run", "Run all performance benchmarks");
    run_all_bench_step.dependOn(&run_bench_recast.step);
    run_all_bench_step.dependOn(&run_bench_detour.step);
    run_all_bench_step.dependOn(&run_bench_crowd.step);
    run_all_bench_step.dependOn(&run_bench_findstraightpath.step);
}