// Integration test suite - imports all integration tests

comptime {
    // Import all integration test files
    _ = @import("recast_pipeline_test.zig");
    _ = @import("detour_pipeline_test.zig");
    _ = @import("crowd_simulation_test.zig");
    _ = @import("tilecache_pipeline_test.zig");
    _ = @import("real_mesh_test.zig");
    _ = @import("dungeon_undulating_test.zig");
    _ = @import("pathfinding_test.zig");
    _ = @import("raycast_test.zig");
}
