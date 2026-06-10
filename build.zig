const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy-профилирование demo: zig build run-demo -Dtracy=true
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiling in demo") orelse false;
    // Глубокие (inner-loop) зоны Tracy/registry. Активны только вместе с -Dtracy.
    // Без этого флага zoneDeep() — полный no-op (ни registry, ни ztracy).
    const enable_tracy_deep = b.option(bool, "tracy-deep", "Enable inner-loop Tracy/registry zones") orelse false;
    // Registry-only measurement build: records CSV zones WITHOUT linking ztracy.
    // Use for fair Zig-vs-C++ benchmarking (both sides registry-only, no GUI overhead).
    // -Dtracy=true implies registry as well, so -Dbench is only needed when ztracy is off.
    const enable_bench = b.option(bool, "bench", "Enable registry-only measurement (no ztracy, CSV output)") orelse false;
    // enable_registry: true when either -Dbench or -Dtracy is set.
    const enable_registry = enable_bench or enable_tracy;

    // Demo (и его dvui/zgl-зависимости) по умолчанию ReleaseSafe: оптимизировано
    // (immediate-mode UI dvui в Debug в ~4× медленнее), но с safety-проверками и
    // детерминированным заполнением undefined (0xAA) — иначе ReleaseFast вскрывает
    // latent-UB в core-пайплайне (мусорная геометрия, фликер). Для отладки демо:
    // -Ddemo-optimize=Debug; для максимума скорости (на свой риск) ReleaseFast.
    const demo_optimize = b.option(std.builtin.OptimizeMode, "demo-optimize", "Optimize mode for demo (default ReleaseSafe)") orelse .ReleaseSafe;

    // In-process timing registry (Tracy benchmark data source). Exposed as a
    // standalone module so tests/runners AND the wrapper (src/tracy.zig) import
    // the ONE instance by name — sharing its process-global aggregate state.
    const tracy_registry = b.addModule("tracy_registry", .{
        .root_source_file = b.path("src/tracy_registry.zig"),
        .target = target,
    });

    // 64-bit poly/tile refs for very large worlds (1:1 with the C++ DT_POLYREF64
    // compile flag). Default: 32-bit. `zig build -Dpolyref64=true`. Threaded into
    // the library as the `build_config` module (read by src/detour/common.zig).
    const polyref64 = b.option(bool, "polyref64", "Use 64-bit dtPolyRef/dtTileRef (DT_POLYREF64) for very large worlds (default: 32-bit)") orelse false;
    const build_config = b.addOptions();
    build_config.addOption(bool, "polyref64", polyref64);
    const config_mod = build_config.createModule();

    // Main library module
    const recast_nav = b.addModule("recast-nav", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    recast_nav.addImport("build_config", config_mod);

    // build_options + the registry for the instrumented core (src/tracy.zig
    // reads both). Always injected so the core compiles for every
    // worktree-internal step; with tracy=false both gates fold to
    // comptime-false → zero overhead, and ztracy is never imported.
    const core_opts = b.addOptions();
    core_opts.addOption(bool, "enable_tracy", enable_tracy);
    core_opts.addOption(bool, "enable_tracy_deep", enable_tracy_deep);
    core_opts.addOption(bool, "enable_registry", enable_registry);
    recast_nav.addImport("build_options", core_opts.createModule());
    recast_nav.addImport("tracy_registry", tracy_registry);

    // ztracy C library that instrumented consumers of recast_nav must link when
    // tracy is enabled. Null when tracy=false (nothing to link).
    //
    // We also capture the ztracy *module* itself: any other consumer that pulls
    // in recast_nav (e.g. the GUI demo) MUST reuse this exact module instance
    // rather than calling lazyDependency("ztracy", ...) again. A second
    // lazyDependency with a different `.optimize` produces a second module whose
    // root is the SAME ztracy.zig file — Zig then errors with
    // "file exists in modules 'ztracy' and 'ztracy0'". Sharing the one module
    // (and the one tracy lib) avoids that collision.
    var core_ztracy_lib: ?*std.Build.Step.Compile = null;
    var core_ztracy_mod: ?*std.Build.Module = null;
    if (enable_tracy) {
        if (b.lazyDependency("ztracy", .{
            .target = target,
            .optimize = optimize,
            .enable_ztracy = true,
            .on_demand = true,
        })) |dep| {
            const ztracy_root = dep.module("root");
            recast_nav.addImport("ztracy", ztracy_root);
            core_ztracy_lib = dep.artifact("tracy");
            core_ztracy_mod = ztracy_root;
        }
    }

    // Production library with safety checks enabled (ReleaseSafe mode)
    // This provides performance optimizations while maintaining runtime safety.
    // It roots at the SAME src/root.zig as recast_nav, so its module graph also
    // reaches the instrumented core files (which `@import("../tracy.zig")`).
    // tracy.zig imports build_options + tracy_registry at module top-level
    // (always analyzed), so recast-nav-safe MUST receive the same imports or it
    // fails to compile. ztracy is only reached behind a comptime-false gate when
    // tracy is off, so it is wired only under -Dtracy (mirroring recast_nav).
    const recast_nav_safe = b.addModule("recast-nav-safe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe, // Optimized but with safety checks
    });
    recast_nav_safe.addImport("build_options", core_opts.createModule());
    recast_nav_safe.addImport("tracy_registry", tracy_registry);
    if (core_ztracy_mod) |zmod| recast_nav_safe.addImport("ztracy", zmod);
    recast_nav_safe.addImport("build_config", config_mod);

    const lib_safe = b.addLibrary(.{
        .name = "recast-nav-safe",
        .root_module = recast_nav_safe,
        .linkage = .static,
    });
    if (core_ztracy_lib) |lib_t| lib_safe.root_module.linkLibrary(lib_t);
    b.installArtifact(lib_safe);

    // Static library
    const lib = b.addLibrary(.{
        .name = "recast-nav",
        .root_module = recast_nav,
        .linkage = .static,
    });
    if (core_ztracy_lib) |lib_t| lib.root_module.linkLibrary(lib_t);
    b.installArtifact(lib);

    // ====================================================================
    // RECAST DEMO - GUI приложение (порт RecastDemo на DVUI + GLFW/OpenGL)
    // ====================================================================
    // Два варианта (см. addDemo ниже):
    //   demo / run-demo           — demo_optimize (по умолчанию ReleaseSafe: безопасно для
    //                                разработки, ловит latent-UB через safety + 0xAA-poison).
    //   demo-fast / run-demo-fast — ReleaseFast (быстрее, для релизных бинарей). Используется CI.
    addDemo(b, target, demo_optimize, enable_tracy, recast_nav, core_ztracy_mod, core_ztracy_lib, "demo", "Build RecastDemo GUI", "run-demo", "Run RecastDemo GUI");
    addDemo(b, target, .ReleaseFast, enable_tracy, recast_nav, core_ztracy_mod, core_ztracy_lib, "demo-fast", "Build RecastDemo GUI (ReleaseFast)", "run-demo-fast", "Run RecastDemo GUI (ReleaseFast)");

    // Тесты математики демо (не требуют dvui/glfw — только recast-nav).
    {
        const mat_test_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        });
        mat_test_mod.addImport("recast-nav", recast_nav);
        const mat_test = b.addTest(.{ .root_module = mat_test_mod });
        if (core_ztracy_lib) |lib_t| mat_test.root_module.linkLibrary(lib_t);
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
    if (core_ztracy_lib) |lib_t| unit_tests.root_module.linkLibrary(lib_t);
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
    integration_test_module.addImport("tracy_registry", tracy_registry);
    const integration_tests = b.addTest(.{
        .root_module = integration_test_module,
    });
    if (core_ztracy_lib) |lib_t| integration_tests.root_module.linkLibrary(lib_t);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Add integration tests to main test step
    test_step.dependOn(&run_integration_tests.step);

    // Standalone test for the timing registry (fast, no recast-nav dependency).
    const tracy_registry_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/tracy_registry_test.zig"),
        .target = target,
        .optimize = .Debug,
    });
    tracy_registry_test_module.addImport("tracy_registry", tracy_registry);
    const tracy_registry_tests = b.addTest(.{ .root_module = tracy_registry_test_module });
    const run_tracy_registry_tests = b.addRunArtifact(tracy_registry_tests);
    const tracy_registry_test_step = b.step("test-tracy-registry", "Run tracy timing-registry tests");
    tracy_registry_test_step.dependOn(&run_tracy_registry_tests.step);
    test_step.dependOn(&run_tracy_registry_tests.step);

    // Smoke test for the thin Tracy wrapper (src/tracy.zig). It needs the same
    // import wiring the core gets (build_options + ztracy when -Dtracy), so we
    // model it as a standalone module rooted at src/tracy.zig. The wrapper
    // imports the registry BY MODULE NAME (`@import("tracy_registry")`), so we
    // wire that same `tracy_registry` module instance into both the wrapper and
    // the test module below — recorded zone state is shared across every
    // consumer of that single module.
    const tracy_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("src/tracy.zig"),
        .target = target,
        .optimize = .Debug,
    });
    tracy_wrapper_mod.addImport("build_options", core_opts.createModule());
    tracy_wrapper_mod.addImport("tracy_registry", tracy_registry);
    const tracy_wrapper_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/tracy_wrapper_test.zig"),
        .target = target,
        .optimize = .Debug,
    });
    tracy_wrapper_test_module.addImport("tracy", tracy_wrapper_mod);
    tracy_wrapper_test_module.addImport("tracy_registry", tracy_registry);
    if (enable_tracy) {
        if (b.lazyDependency("ztracy", .{
            .target = target,
            .optimize = .Debug,
            .enable_ztracy = true,
            .on_demand = true,
        })) |dep| {
            tracy_wrapper_mod.addImport("ztracy", dep.module("root"));
            tracy_wrapper_test_module.linkLibrary(dep.artifact("tracy"));
        }
    }
    const tracy_wrapper_tests = b.addTest(.{ .root_module = tracy_wrapper_test_module });
    const run_tracy_wrapper_tests = b.addRunArtifact(tracy_wrapper_tests);
    const tracy_wrapper_test_step = b.step("test-tracy-wrapper", "Run thin Tracy wrapper smoke tests");
    tracy_wrapper_test_step.dependOn(&run_tracy_wrapper_tests.step);
    // Fold into the main test step so a plain `zig build test` exercises the
    // wrapper's zero-cost (tracy-off) path on every run.
    test_step.dependOn(&run_tracy_wrapper_tests.step);

    // Standalone test for the bench .obj loader (bench/obj_loader.zig). No
    // recast-nav dependency: it is pure parsing over std. The test file
    // (test/integration/obj_loader_test.zig) imports the loader by RELATIVE PATH
    // `../../bench/obj_loader.zig`; Zig 0.16 forbids importing outside a module's
    // root directory, so we root this module at a repo-root shim
    // (bench_obj_loader_test_root.zig). With the repo root as the module root,
    // `../../bench/...` resolves inside the subtree and the import is legal.
    // Folded into `zig build test` so the loader runs on every test invocation
    // alongside its dedicated `test-obj-loader` step.
    const obj_loader_test_module = b.createModule(.{
        .root_source_file = b.path("bench_obj_loader_test_root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const obj_loader_tests = b.addTest(.{ .root_module = obj_loader_test_module });
    const run_obj_loader_tests = b.addRunArtifact(obj_loader_tests);
    const obj_loader_test_step = b.step("test-obj-loader", "Run bench .obj loader tests");
    obj_loader_test_step.dependOn(&run_obj_loader_tests.step);
    test_step.dependOn(&run_obj_loader_tests.step);

    // Standalone test for the merge_csv analysis tool (tools/analysis/merge_csv.zig).
    // Pure CSV parse/join/format over std (no recast-nav dependency). The test file
    // (test/integration/merge_csv_test.zig) imports the tool by RELATIVE PATH
    // `../../tools/analysis/merge_csv.zig`; Zig 0.16 forbids importing outside a
    // module's root directory, so we root this module at a repo-root shim
    // (merge_csv_test_root.zig) — exactly the obj_loader_test pattern above. Folded
    // into `zig build test` so the merge logic runs on every test invocation.
    const merge_csv_test_module = b.createModule(.{
        .root_source_file = b.path("merge_csv_test_root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const merge_csv_tests = b.addTest(.{ .root_module = merge_csv_test_module });
    const run_merge_csv_tests = b.addRunArtifact(merge_csv_tests);
    const merge_csv_test_step = b.step("test-merge-csv", "Run merge_csv tool tests");
    merge_csv_test_step.dependOn(&run_merge_csv_tests.step);
    test_step.dependOn(&run_merge_csv_tests.step);

    // merge_csv standalone executable (Task 6.2): joins the Zig + C++ per-zone
    // benchmark CSVs into ZIG_VS_CPP.csv. Pure std; no recast-nav/ztracy. ReleaseFast
    // is irrelevant for a one-shot file tool but honoring the user's -Doptimize keeps
    // it consistent with the other analysis targets.
    const merge_csv_module = b.createModule(.{
        .root_source_file = b.path("tools/analysis/merge_csv.zig"),
        .target = target,
        .optimize = optimize,
    });
    const merge_csv_exe = b.addExecutable(.{
        .name = "merge_csv",
        .root_module = merge_csv_module,
    });
    const install_merge_csv = b.addInstallArtifact(merge_csv_exe, .{});
    const merge_csv_build_step = b.step("merge-csv", "Build the merge_csv analysis tool");
    merge_csv_build_step.dependOn(&install_merge_csv.step);

    const run_merge_csv = b.addRunArtifact(merge_csv_exe);
    run_merge_csv.step.dependOn(&install_merge_csv.step);
    if (b.args) |a| run_merge_csv.addArgs(a);
    const run_merge_csv_step = b.step("run-merge-csv", "Run merge_csv: -- <zig_csv> <cpp_csv> <out_csv>");
    run_merge_csv_step.dependOn(&run_merge_csv.step);

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
    if (core_ztracy_lib) |lib_t| raycast_test_exe.root_module.linkLibrary(lib_t);

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

    if (core_ztracy_lib) |lib_t| {
        example_simple.root_module.linkLibrary(lib_t);
        example_pathfinding.root_module.linkLibrary(lib_t);
        example_crowd.root_module.linkLibrary(lib_t);
        example_dynamic_obstacles.root_module.linkLibrary(lib_t);
    }

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

    if (core_ztracy_lib) |lib_t| {
        bench_recast.root_module.linkLibrary(lib_t);
        bench_detour.root_module.linkLibrary(lib_t);
        bench_crowd.root_module.linkLibrary(lib_t);
        bench_findstraightpath.root_module.linkLibrary(lib_t);
    }

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

    // ====================================================================
    // TRACY SCENARIO RUNNER (Task 3.2a) — bench/tracy_scenarios.zig
    // ====================================================================
    // Drives the BUILD scenarios from dev/research/performance_analysis/scenarios.md
    // and dumps per-zone self/inclusive times to a CSV via the in-process
    // tracy_registry. The in-core Tracy zones only RECORD when the runner is built
    // with -Dtracy=true (otherwise zone() folds to comptime-false → empty CSV), so
    // the runner reuses the SAME recast_nav module instance (which already received
    // the tracy gate + ztracy import in build()) and links the core's ztracy lib.
    //
    // ReleaseFast is the right mode for real timing runs; it also compiles in Debug
    // (the framework is plain std + the core pipeline). We honor the user's
    // -Doptimize here so `-Doptimize=Debug` and `-Doptimize=ReleaseFast` both work.
    const tracy_scenarios_module = b.createModule(.{
        .root_source_file = b.path("bench/tracy_scenarios.zig"),
        .target = target,
        .optimize = optimize,
    });
    tracy_scenarios_module.addImport("zig-recast", recast_nav);
    tracy_scenarios_module.addImport("tracy_registry", tracy_registry);
    const tracy_scenarios_exe = b.addExecutable(.{
        .name = "tracy_scenarios",
        .root_module = tracy_scenarios_module,
    });
    // Same ztracy gate the rest of the instrumented consumers use: when -Dtracy
    // is set, core_ztracy_lib is non-null and must be linked so the C TracyClient
    // symbols resolve. With tracy off the runner still builds; zones are no-ops.
    if (core_ztracy_lib) |lib_t| tracy_scenarios_exe.root_module.linkLibrary(lib_t);

    const install_tracy_scenarios = b.addInstallArtifact(tracy_scenarios_exe, .{});
    const bench_tracy_step = b.step("bench-tracy", "Build the Tracy scenario benchmark runner");
    bench_tracy_step.dependOn(&install_tracy_scenarios.step);

    const run_tracy_scenarios = b.addRunArtifact(tracy_scenarios_exe);
    run_tracy_scenarios.step.dependOn(&install_tracy_scenarios.step);
    if (b.args) |a| run_tracy_scenarios.addArgs(a);
    const run_tracy_scenarios_step = b.step("run-tracy-scenarios", "Run the Tracy scenario runner: -- <scenario_id|all> <geom_dir> <out_csv>");
    run_tracy_scenarios_step.dependOn(&run_tracy_scenarios.step);

    // ====================================================================
    // PER-FUNCTION MICRO-BENCHMARK — bench/microbench.zig
    // ====================================================================
    // Isolates and times individual library functions; tags each CSV row with the
    // compiled optimize mode (the "build variant"). No Tracy needed (own timer via
    // the std.Io .awake clock). Build under -Doptimize={ReleaseFast,ReleaseSafe,
    // Debug} to get the three-variant trace.
    const microbench_module = b.createModule(.{
        .root_source_file = b.path("bench/microbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    microbench_module.addImport("zig-recast", recast_nav);
    const microbench_exe = b.addExecutable(.{
        .name = "microbench",
        .root_module = microbench_module,
    });
    const install_microbench = b.addInstallArtifact(microbench_exe, .{});
    const microbench_step = b.step("microbench", "Build the per-function micro-benchmark runner");
    microbench_step.dependOn(&install_microbench.step);

    const run_microbench = b.addRunArtifact(microbench_exe);
    run_microbench.step.dependOn(&install_microbench.step);
    if (b.args) |a| run_microbench.addArgs(a);
    const run_microbench_step = b.step("run-microbench", "Run the micro-benchmark: -- <out_csv>");
    run_microbench_step.dependOn(&run_microbench.step);
}

/// Создаёт build- и run-таргеты demo для заданного optimize-режима.
/// Вызывается дважды: demo (ReleaseSafe) и demo-fast (ReleaseFast).
/// lazyDependency: dvui/zgl/ztracy тянутся только когда соответствующий шаг реально собирается.
fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_tracy: bool,
    recast_nav: *std.Build.Module,
    // Shared ztracy module + tracy lib resolved once in build() for the core.
    // The demo MUST reuse these (not re-resolve ztracy) to avoid the
    // "file exists in modules 'ztracy' and 'ztracy0'" module-graph collision.
    core_ztracy_mod: ?*std.Build.Module,
    core_ztracy_lib: ?*std.Build.Step.Compile,
    build_step_name: []const u8,
    build_step_desc: []const u8,
    run_step_name: []const u8,
    run_step_desc: []const u8,
) void {
    if (b.lazyDependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw,
        .@"tree-sitter" = false,
        .freetype = false,
    })) |dvui_dep| if (b.lazyDependency("zgl", .{
        .target = target,
        .optimize = optimize,
    })) |zgl_dep| {
        const demo_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        demo_mod.addImport("recast-nav", recast_nav);
        demo_mod.addImport("dvui", dvui_dep.module("dvui_glfw"));
        demo_mod.addImport("glfw-backend", dvui_dep.module("glfw"));

        const zgl_mod = zgl_dep.module("zgl");
        switch (target.result.os.tag) {
            .windows => zgl_mod.linkSystemLibrary("opengl32", .{}),
            .linux => zgl_mod.linkSystemLibrary("GL", .{}),
            .macos => zgl_mod.linkFramework("OpenGL", .{}),
            else => {},
        }
        demo_mod.addImport("zgl", zgl_mod);

        const demo_options = b.addOptions();
        demo_options.addOption(bool, "enable_tracy", enable_tracy);
        demo_mod.addImport("build_options", demo_options.createModule());

        var ztracy_lib: ?*std.Build.Step.Compile = null;
        if (enable_tracy) {
            // Reuse the core's single ztracy module/lib instance (resolved in
            // build()). Re-resolving via lazyDependency here would create a
            // second module rooted at the same ztracy.zig and break the build.
            if (core_ztracy_mod) |zmod| {
                demo_mod.addImport("ztracy", zmod);
                ztracy_lib = core_ztracy_lib;
            } else {
                // Core ztracy not resolved (lazy dep not yet fetched); fall back
                // to the stub so the demo still compiles this pass.
                demo_mod.addImport("ztracy", b.createModule(.{
                    .root_source_file = b.path("demo/src/ztracy_stub.zig"),
                }));
            }
        } else {
            demo_mod.addImport("ztracy", b.createModule(.{
                .root_source_file = b.path("demo/src/ztracy_stub.zig"),
            }));
        }

        const demo_exe = b.addExecutable(.{
            .name = "recast_demo",
            .root_module = demo_mod,
            // self-hosted x86_64 backend не умеет tail calls из zgl — нужен LLVM.
            .use_llvm = true,
        });
        if (ztracy_lib) |lib_t| demo_exe.root_module.linkLibrary(lib_t);
        const install_demo = b.addInstallArtifact(demo_exe, .{});

        // Ассеты рядом с exe (zig-out/bin/test_data) — standalone-запуск.
        const install_assets = b.addInstallDirectory(.{
            .source_dir = b.path("test_data"),
            .install_dir = .bin,
            .install_subdir = "test_data",
        });

        const demo_step = b.step(build_step_name, build_step_desc);
        demo_step.dependOn(&install_demo.step);
        demo_step.dependOn(&install_assets.step);

        const run_demo = b.addRunArtifact(demo_exe);
        run_demo.step.dependOn(&install_demo.step);
        run_demo.step.dependOn(&install_assets.step);
        const run_demo_step = b.step(run_step_name, run_step_desc);
        run_demo_step.dependOn(&run_demo.step);
    };
}
