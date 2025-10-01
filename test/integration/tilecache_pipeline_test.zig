const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

// ==============================================================================
// HELPER FUNCTIONS
// ==============================================================================

/// Create a simple box mesh for testing
fn createSimpleBoxMesh() [12]nav.Vec3 {
    return [12]nav.Vec3{
        // Top face (y = 0.5)
        nav.Vec3.init(0, 0.5, 0),
        nav.Vec3.init(10, 0.5, 0),
        nav.Vec3.init(10, 0.5, 10),

        nav.Vec3.init(0, 0.5, 0),
        nav.Vec3.init(10, 0.5, 10),
        nav.Vec3.init(0, 0.5, 10),

        // Bottom face (y = 0)
        nav.Vec3.init(0, 0, 0),
        nav.Vec3.init(10, 0, 10),
        nav.Vec3.init(10, 0, 0),

        nav.Vec3.init(0, 0, 0),
        nav.Vec3.init(0, 0, 10),
        nav.Vec3.init(10, 0, 10),
    };
}

// ==============================================================================
// TESTS
// ==============================================================================

test "TileCache Pipeline: Basic Setup (Stub)" {
    const allocator = testing.allocator;

    // Create context
    const ctx = nav.Context.init(allocator);
    _ = ctx;

    // Create simple mesh
    const vertices = createSimpleBoxMesh();

    // Configure Recast for tiled navmesh
    var config = nav.RecastConfig{
        .cs = 0.3,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 20,
        .walkable_climb = 9,
        .walkable_radius = 8,
        .max_edge_len = 12,
        .max_simplification_error = 1.3,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .border_size = 1, // Important for tiled meshes
        .tile_size = 32, // Tile size for tiled navmesh
        .width = 0,
        .height = 0,
        .bmin = nav.Vec3.zero(),
        .bmax = nav.Vec3.zero(),
    };

    // Calculate bounds
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    nav.RecastConfig.calcBounds(&vertices, &bmin, &bmax);

    config.bmin = bmin;
    config.bmax = bmax;

    // TODO: TileCache pipeline implementation requires:
    // 1. Build tiled NavMesh (similar to regular but with tiles)
    // 2. Create TileCache instance with TileCacheParams
    // 3. Add compressed tiles to cache
    // 4. Add temporary obstacle
    // 5. Update TileCache (rebuilds affected tiles)
    // 6. Verify obstacle affects navmesh
    // 7. Remove obstacle
    // 8. Update TileCache again
    // 9. Verify navmesh restored

    // For now, just verify basic config is valid
    try testing.expect(config.cs > 0);
    try testing.expect(config.tile_size > 0);
    try testing.expect(config.border_size > 0);

    // This test is a stub - full implementation requires:
    // - Tiled NavMesh building from Recast data
    // - TileCache initialization with compressor
    // - Obstacle addition/removal APIs
    // - TileCache update mechanism
    // - Verification that obstacles carve navmesh
}

test "TileCache: Verify Config for Tiled Build" {
    // Verify that tile configuration makes sense
    const tile_size: i32 = 32;
    const border_size: i32 = 1;
    const cs: f32 = 0.3;

    // Tile size should be positive
    try testing.expect(tile_size > 0);

    // Border should be smaller than tile
    try testing.expect(border_size < tile_size);

    // Cell size should be reasonable for tile
    try testing.expect(cs > 0 and cs < @as(f32, @floatFromInt(tile_size)));

    // Total tile grid cells
    const grid_cells = tile_size + 2 * border_size;
    try testing.expect(grid_cells > tile_size);
}
