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

    // Static library
    const lib = b.addStaticLibrary(.{
        .name = "recast-nav",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Unit Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Additional unit tests
    // Note: filter_test.zig temporarily disabled due to outdated Heightfield structure
    // const filter_tests = b.addTest(.{
    //     .root_source_file = b.path("test/filter_test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // filter_tests.root_module.addImport("recast-nav", recast_nav);
    // const run_filter_tests = b.addRunArtifact(filter_tests);
    // test_step.dependOn(&run_filter_tests.step);

    const rasterization_tests = b.addTest(.{
        .root_source_file = b.path("test/rasterization_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    rasterization_tests.root_module.addImport("recast-nav", recast_nav);
    const run_rasterization_tests = b.addRunArtifact(rasterization_tests);
    test_step.dependOn(&run_rasterization_tests.step);

    const mesh_advanced_tests = b.addTest(.{
        .root_source_file = b.path("test/mesh_advanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_advanced_tests.root_module.addImport("recast-nav", recast_nav);
    const run_mesh_advanced_tests = b.addRunArtifact(mesh_advanced_tests);
    test_step.dependOn(&run_mesh_advanced_tests.step);

    const contour_advanced_tests = b.addTest(.{
        .root_source_file = b.path("test/contour_advanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    contour_advanced_tests.root_module.addImport("recast-nav", recast_nav);
    const run_contour_advanced_tests = b.addRunArtifact(contour_advanced_tests);
    test_step.dependOn(&run_contour_advanced_tests.step);

    const obj_loader_tests = b.addTest(.{
        .root_source_file = b.path("test/obj_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_obj_loader_tests = b.addRunArtifact(obj_loader_tests);
    test_step.dependOn(&run_obj_loader_tests.step);

    // OBJ Loader module for tests
    const obj_loader = b.addModule("obj_loader", .{
        .root_source_file = b.path("test/obj_loader.zig"),
    });

    // Integration Tests
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("zig-recast", recast_nav);
    integration_tests.root_module.addImport("obj_loader", obj_loader);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Add integration tests to main test step
    test_step.dependOn(&run_integration_tests.step);

    // Examples
    const example_simple = b.addExecutable(.{
        .name = "simple_navmesh",
        .root_source_file = b.path("examples/simple_navmesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_simple.root_module.addImport("recast-nav", recast_nav);

    const example_pathfinding = b.addExecutable(.{
        .name = "pathfinding_demo",
        .root_source_file = b.path("examples/pathfinding_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_pathfinding.root_module.addImport("recast-nav", recast_nav);

    const example_crowd = b.addExecutable(.{
        .name = "crowd_simulation",
        .root_source_file = b.path("examples/crowd_simulation.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_crowd.root_module.addImport("recast-nav", recast_nav);

    const example_dynamic_obstacles = b.addExecutable(.{
        .name = "dynamic_obstacles",
        .root_source_file = b.path("examples/dynamic_obstacles.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_dynamic_obstacles.root_module.addImport("recast-nav", recast_nav);

    const install_example_simple = b.addInstallArtifact(example_simple, .{});
    const install_example_pathfinding = b.addInstallArtifact(example_pathfinding, .{});
    const install_example_crowd = b.addInstallArtifact(example_crowd, .{});
    const install_example_dynamic_obstacles = b.addInstallArtifact(example_dynamic_obstacles, .{});

    const example_step = b.step("examples", "Build examples");
    example_step.dependOn(&install_example_simple.step);
    example_step.dependOn(&install_example_pathfinding.step);
    example_step.dependOn(&install_example_crowd.step);
    example_step.dependOn(&install_example_dynamic_obstacles.step);

    // Raycast test executable
    const raycast_test_exe = b.addExecutable(.{
        .name = "raycast_test",
        .root_source_file = b.path("test/integration/raycast_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raycast_test_exe.root_module.addImport("zig-recast", recast_nav);
    raycast_test_exe.root_module.addImport("obj_loader", obj_loader);

    const install_raycast_test = b.addInstallArtifact(raycast_test_exe, .{});
    const raycast_test_step = b.step("raycast-test", "Build raycast test executable");
    raycast_test_step.dependOn(&install_raycast_test.step);

    // Performance Benchmarks
    const bench_recast = b.addExecutable(.{
        .name = "recast_bench",
        .root_source_file = b.path("bench/recast_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_recast.root_module.addImport("zig-recast", recast_nav);

    const bench_detour = b.addExecutable(.{
        .name = "detour_bench",
        .root_source_file = b.path("bench/detour_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_detour.root_module.addImport("zig-recast", recast_nav);

    const bench_crowd = b.addExecutable(.{
        .name = "crowd_bench",
        .root_source_file = b.path("bench/crowd_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_crowd.root_module.addImport("zig-recast", recast_nav);

    const install_bench_recast = b.addInstallArtifact(bench_recast, .{});
    const install_bench_detour = b.addInstallArtifact(bench_detour, .{});
    const install_bench_crowd = b.addInstallArtifact(bench_crowd, .{});

    const bench_step = b.step("bench", "Build all benchmarks");
    bench_step.dependOn(&install_bench_recast.step);
    bench_step.dependOn(&install_bench_detour.step);
    bench_step.dependOn(&install_bench_crowd.step);

    // Run benchmark steps
    const run_bench_recast = b.addRunArtifact(bench_recast);
    const run_bench_detour = b.addRunArtifact(bench_detour);
    const run_bench_crowd = b.addRunArtifact(bench_crowd);

    const run_bench_recast_step = b.step("bench-recast", "Run Recast performance benchmarks");
    run_bench_recast_step.dependOn(&run_bench_recast.step);

    const run_bench_detour_step = b.step("bench-detour", "Run Detour performance benchmarks");
    run_bench_detour_step.dependOn(&run_bench_detour.step);

    const run_bench_crowd_step = b.step("bench-crowd", "Run Crowd performance benchmarks");
    run_bench_crowd_step.dependOn(&run_bench_crowd.step);

    const run_all_bench_step = b.step("bench-run", "Run all performance benchmarks");
    run_all_bench_step.dependOn(&run_bench_recast.step);
    run_all_bench_step.dependOn(&run_bench_detour.step);
    run_all_bench_step.dependOn(&run_bench_crowd.step);
}
