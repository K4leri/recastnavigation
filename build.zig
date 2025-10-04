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
    const lib = b.addLibrary(.{
        .name = "recast-nav",
        .root_module = recast_nav,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Unit Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Additional unit tests
    const filter_test_module = b.createModule(.{
        .root_source_file = b.path("test/filter_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_test_module.addImport("recast-nav", recast_nav);
    const filter_tests = b.addTest(.{
        .root_module = filter_test_module,
    });
    const run_filter_tests = b.addRunArtifact(filter_tests);
    test_step.dependOn(&run_filter_tests.step);

    const rasterization_test_module = b.createModule(.{
        .root_source_file = b.path("test/rasterization_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    rasterization_test_module.addImport("recast-nav", recast_nav);
    const rasterization_tests = b.addTest(.{
        .root_module = rasterization_test_module,
    });
    const run_rasterization_tests = b.addRunArtifact(rasterization_tests);
    test_step.dependOn(&run_rasterization_tests.step);

    const mesh_advanced_test_module = b.createModule(.{
        .root_source_file = b.path("test/mesh_advanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_advanced_test_module.addImport("recast-nav", recast_nav);
    const mesh_advanced_tests = b.addTest(.{
        .root_module = mesh_advanced_test_module,
    });
    const run_mesh_advanced_tests = b.addRunArtifact(mesh_advanced_tests);
    test_step.dependOn(&run_mesh_advanced_tests.step);

    const contour_advanced_test_module = b.createModule(.{
        .root_source_file = b.path("test/contour_advanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    contour_advanced_test_module.addImport("recast-nav", recast_nav);
    const contour_advanced_tests = b.addTest(.{
        .root_module = contour_advanced_test_module,
    });
    const run_contour_advanced_tests = b.addRunArtifact(contour_advanced_tests);
    test_step.dependOn(&run_contour_advanced_tests.step);

    const obj_loader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/obj_loader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_obj_loader_tests = b.addRunArtifact(obj_loader_tests);
    test_step.dependOn(&run_obj_loader_tests.step);

    // OBJ Loader module for tests
    const obj_loader = b.addModule("obj_loader", .{
        .root_source_file = b.path("test/obj_loader.zig"),
    });

    // Integration Tests
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/all.zig"),
        .target = target,
        .optimize = optimize,
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

    // Examples
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

    // Raycast test executable
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

    // Performance Benchmarks
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
