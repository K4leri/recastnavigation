const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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