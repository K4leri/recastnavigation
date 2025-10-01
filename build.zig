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

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

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

    const install_example_simple = b.addInstallArtifact(example_simple, .{});
    const install_example_pathfinding = b.addInstallArtifact(example_pathfinding, .{});
    const install_example_crowd = b.addInstallArtifact(example_crowd, .{});

    const example_step = b.step("examples", "Build examples");
    example_step.dependOn(&install_example_simple.step);
    example_step.dependOn(&install_example_pathfinding.step);
    example_step.dependOn(&install_example_crowd.step);
}
