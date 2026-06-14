const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy profiling for the demo: zig build run-demo -Dtracy=true
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiling in demo") orelse false;

    // Demo (and its dvui/zgl deps) defaults to ReleaseSafe: optimized
    // (dvui immediate-mode UI is ~4x slower in Debug) but with safety checks and
    // deterministic undefined fill (0xAA) — ReleaseFast otherwise exposes latent UB
    // in the core pipeline (garbage geometry, flicker). To debug the demo:
    // -Ddemo-optimize=Debug; for max speed (at your own risk) use ReleaseFast.
    const demo_optimize = b.option(std.builtin.OptimizeMode, "demo-optimize", "Optimize mode for demo (default ReleaseSafe)") orelse .ReleaseSafe;

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

    // Production library with safety checks enabled (ReleaseSafe mode)
    // This provides performance optimizations while maintaining runtime safety
    const recast_nav_safe = b.addModule("recast-nav-safe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe, // Optimized but with safety checks
    });
    recast_nav_safe.addImport("build_config", config_mod);

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
    // RECAST DEMO - GUI app (RecastDemo port on DVUI + GLFW/OpenGL)
    // ====================================================================
    // Two variants (see addDemo below):
    //   demo / run-demo           — demo_optimize (default ReleaseSafe: safe for
    //                                development; catches latent UB via safety + 0xAA poison).
    //   demo-fast / run-demo-fast — ReleaseFast (faster, for release binaries). Used in CI.
    // Demo is gated behind -Ddemo: dvui-0.5.0-dev in the cache requires zig 0.16-dev and breaks
    // the build graph for downstream consumers (e.g. zigServer on 0.15.2).
    // lazyDependency still runs a dependency's build.zig once the package is cached,
    // so the only reliable gate is to skip addDemo entirely unless -Ddemo is set.
    const build_demo = b.option(bool, "demo", "Configure RecastDemo GUI targets (needs dvui/zgl, zig 0.16-dev)") orelse false;
    if (build_demo) {
        addDemo(b, target, demo_optimize, enable_tracy, recast_nav, "demo", "Build RecastDemo GUI", "run-demo", "Run RecastDemo GUI");
        addDemo(b, target, .ReleaseFast, enable_tracy, recast_nav, "demo-fast", "Build RecastDemo GUI (ReleaseFast)", "run-demo-fast", "Run RecastDemo GUI (ReleaseFast)");
    }

    // Demo math tests (no dvui/glfw required — recast-nav only).
    {
        const mat_test_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        });
        mat_test_mod.addImport("recast-nav", recast_nav);
        const mat_test = b.addTest(.{ .root_module = mat_test_mod });
        const demo_test_step = b.step("demo-test", "Demo math tests");
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

    // Data-driven: each example becomes an executable, an `examples`-aggregate
    // dependency, and its own `run-<name>` step. The flagship full_pathfinding is
    // also aliased as `run-example`.
    const Example = struct { name: []const u8, path: []const u8 };
    const examples = [_]Example{
        .{ .name = "full_pathfinding", .path = "examples/03_full_pathfinding.zig" },
        .{ .name = "tiled_navmesh", .path = "examples/02_tiled_navmesh.zig" },
        .{ .name = "offmesh_connections", .path = "examples/06_offmesh_connections.zig" },
        .{ .name = "simple_navmesh", .path = "examples/simple_navmesh.zig" },
        .{ .name = "pathfinding_demo", .path = "examples/pathfinding_demo.zig" },
        .{ .name = "crowd_simulation", .path = "examples/crowd_simulation.zig" },
        .{ .name = "dynamic_obstacles", .path = "examples/dynamic_obstacles.zig" },
        .{ .name = "custom_areas", .path = "examples/advanced/custom_areas.zig" },
        .{ .name = "hierarchical_pathfinding", .path = "examples/advanced/hierarchical_pathfinding.zig" },
        .{ .name = "streaming_world", .path = "examples/advanced/streaming_world.zig" },
    };

    const example_step = b.step("examples", "Build all examples");
    const run_examples_step = b.step("run-examples", "Build and run all examples (CI smoke test)");
    for (examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("recast-nav", recast_nav);
        const exe = b.addExecutable(.{ .name = ex.name, .root_module = mod });
        example_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(
            b.fmt("run-{s}", .{ex.name}),
            b.fmt("Run example: {s}", .{ex.name}),
        );
        run_step.dependOn(&run.step);
        run_examples_step.dependOn(&run.step);

        // `zig build run-example` -> the flagship full pipeline demo
        if (std.mem.eql(u8, ex.name, "full_pathfinding")) {
            const alias = b.step("run-example", "Run the full pathfinding example");
            alias.dependOn(&run.step);
        }
    }

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

/// Creates demo build and run targets for the given optimize mode.
/// Called twice: demo (ReleaseSafe) and demo-fast (ReleaseFast).
/// lazyDependency: dvui/zgl/ztracy are fetched only when the corresponding step is built.
fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_tracy: bool,
    recast_nav: *std.Build.Module,
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
            if (b.lazyDependency("ztracy", .{
                .target = target,
                .optimize = optimize,
                .enable_ztracy = true,
                .on_demand = true,
            })) |ztracy_dep| {
                demo_mod.addImport("ztracy", ztracy_dep.module("root"));
                ztracy_lib = ztracy_dep.artifact("tracy");
            }
        } else {
            demo_mod.addImport("ztracy", b.createModule(.{
                .root_source_file = b.path("demo/src/ztracy_stub.zig"),
            }));
        }

        const demo_exe = b.addExecutable(.{
            .name = "recast_demo",
            .root_module = demo_mod,
            // Self-hosted x86_64 backend cannot tail-call through zgl — LLVM required.
            .use_llvm = true,
        });
        if (ztracy_lib) |lib_t| demo_exe.root_module.linkLibrary(lib_t);
        const install_demo = b.addInstallArtifact(demo_exe, .{});

        // Install assets next to the exe (zig-out/bin/test_data) for standalone runs.
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