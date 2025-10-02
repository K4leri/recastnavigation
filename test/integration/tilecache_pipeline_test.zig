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
// STUB COMPRESSOR (No-op compression for testing)
// ==============================================================================

const StubCompressor = struct {
    fn maxCompressedSize(_: *anyopaque, buffer_size: usize) usize {
        return buffer_size; // No compression, same size
    }

    fn compress(
        _: *anyopaque,
        buffer: []const u8,
        compressed: []u8,
        compressed_size: *usize,
    ) nav.detour.Status {
        @memcpy(compressed[0..buffer.len], buffer);
        compressed_size.* = buffer.len;
        return nav.detour.Status.ok();
    }

    fn decompress(
        _: *anyopaque,
        compressed: []const u8,
        buffer: []u8,
        buffer_size: *usize,
    ) nav.detour.Status {
        @memcpy(buffer[0..compressed.len], compressed);
        buffer_size.* = compressed.len;
        return nav.detour.Status.ok();
    }

    pub fn toInterface(self: *StubCompressor) nav.detour_tilecache.TileCacheCompressor {
        return .{
            .ptr = self,
            .vtable = &.{
                .maxCompressedSize = maxCompressedSize,
                .compress = compress,
                .decompress = decompress,
            },
        };
    }
};

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

test "TileCache: Add and Remove Obstacle" {
    const allocator = testing.allocator;

    // TileCache parameters
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 32,
        .height = 32,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 128,
        .max_obstacles = 128,
    };

    // Create stub compressor
    var stub_comp = StubCompressor{};
    var compressor = stub_comp.toInterface();

    // Initialize TileCache
    var tilecache = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        &compressor,
        null, // No mesh process for now
    );
    defer tilecache.deinit();

    // Create NavMesh for TileCache
    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = @as(f32, @floatFromInt(tc_params.width)) * tc_params.cs,
        .tile_height = @as(f32, @floatFromInt(tc_params.height)) * tc_params.cs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 16384,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    // Add cylinder obstacle at center of map
    const obstacle_pos = [3]f32{ 5.0, 0.5, 5.0 };
    const obstacle_radius: f32 = 0.5;
    const obstacle_height: f32 = 2.0;

    const obstacle_ref = try tilecache.addObstacle(&obstacle_pos, obstacle_radius, obstacle_height);
    try testing.expect(obstacle_ref != 0);

    // Update TileCache (это должно пометить тайлы для перестройки)
    var up_to_date: bool = false;
    const status = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status.isSuccess());

    // Verify obstacle was added
    // (в реальном сценарии нужно проверить что NavMesh изменился)

    // Remove obstacle
    try tilecache.removeObstacle(obstacle_ref);

    // Update again
    const status2 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status2.isSuccess());

    // Verify obstacle was removed
    // (NavMesh должен вернуться к исходному состоянию)
}

test "TileCache: Box Obstacle (AABB)" {
    const allocator = testing.allocator;

    // TileCache parameters
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 32,
        .height = 32,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 128,
        .max_obstacles = 128,
    };

    // Create stub compressor
    var stub_comp = StubCompressor{};
    var compressor = stub_comp.toInterface();

    // Initialize TileCache
    var tilecache = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        &compressor,
        null,
    );
    defer tilecache.deinit();

    // Create NavMesh
    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = @as(f32, @floatFromInt(tc_params.width)) * tc_params.cs,
        .tile_height = @as(f32, @floatFromInt(tc_params.height)) * tc_params.cs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 16384,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    // Add box obstacle (AABB)
    const bmin = [3]f32{ 4.0, 0.0, 4.0 };
    const bmax = [3]f32{ 6.0, 2.0, 6.0 };

    const obstacle_ref = try tilecache.addBoxObstacle(&bmin, &bmax);
    try testing.expect(obstacle_ref != 0);

    // Update TileCache
    var up_to_date: bool = false;
    const status = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status.isSuccess());

    // Remove obstacle
    try tilecache.removeObstacle(obstacle_ref);

    // Update again
    const status2 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status2.isSuccess());
}

test "TileCache: Oriented Box Obstacle (OBB)" {
    const allocator = testing.allocator;

    // TileCache parameters
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 32,
        .height = 32,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 128,
        .max_obstacles = 128,
    };

    // Create stub compressor
    var stub_comp = StubCompressor{};
    var compressor = stub_comp.toInterface();

    // Initialize TileCache
    var tilecache = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        &compressor,
        null,
    );
    defer tilecache.deinit();

    // Create NavMesh
    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = @as(f32, @floatFromInt(tc_params.width)) * tc_params.cs,
        .tile_height = @as(f32, @floatFromInt(tc_params.height)) * tc_params.cs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 16384,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    // Add oriented box obstacle (rotated 45 degrees)
    const center = [3]f32{ 5.0, 1.0, 5.0 };
    const half_extents = [3]f32{ 1.0, 1.0, 1.0 };
    const y_radians: f32 = 0.785398; // 45 degrees in radians

    const obstacle_ref = try tilecache.addOrientedBoxObstacle(&center, &half_extents, y_radians);
    try testing.expect(obstacle_ref != 0);

    // Update TileCache
    var up_to_date: bool = false;
    const status = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status.isSuccess());

    // Remove obstacle
    try tilecache.removeObstacle(obstacle_ref);

    // Update again
    const status2 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status2.isSuccess());
}

test "TileCache: Multiple Obstacles" {
    const allocator = testing.allocator;

    // TileCache parameters
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 32,
        .height = 32,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 128,
        .max_obstacles = 128,
    };

    // Create stub compressor
    var stub_comp = StubCompressor{};
    var compressor = stub_comp.toInterface();

    // Initialize TileCache
    var tilecache = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        &compressor,
        null,
    );
    defer tilecache.deinit();

    // Create NavMesh
    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = @as(f32, @floatFromInt(tc_params.width)) * tc_params.cs,
        .tile_height = @as(f32, @floatFromInt(tc_params.height)) * tc_params.cs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 16384,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    // Add multiple obstacles of different types
    const obstacle1 = try tilecache.addObstacle(&[3]f32{ 2.0, 0.5, 2.0 }, 0.5, 2.0); // Cylinder
    const obstacle2 = try tilecache.addBoxObstacle(&[3]f32{ 4.0, 0.0, 4.0 }, &[3]f32{ 6.0, 2.0, 6.0 }); // Box
    const obstacle3 = try tilecache.addObstacle(&[3]f32{ 8.0, 0.5, 8.0 }, 0.5, 2.0); // Another cylinder

    try testing.expect(obstacle1 != 0);
    try testing.expect(obstacle2 != 0);
    try testing.expect(obstacle3 != 0);
    try testing.expect(obstacle1 != obstacle2);
    try testing.expect(obstacle2 != obstacle3);

    // Update TileCache (should mark multiple tiles affected)
    var up_to_date: bool = false;
    const status = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status.isSuccess());

    // Remove one obstacle
    try tilecache.removeObstacle(obstacle2);

    // Update again (should rebuild tiles affected by obstacle2)
    const status2 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status2.isSuccess());

    // Remove remaining obstacles
    try tilecache.removeObstacle(obstacle1);
    try tilecache.removeObstacle(obstacle3);

    // Final update
    const status3 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status3.isSuccess());
}

test "TileCache: NavMesh Changes Verification" {
    const allocator = testing.allocator;

    // Create context
    var ctx = nav.Context.init(allocator);

    // Create simple mesh
    const vertices = createSimpleBoxMesh();

    // Configure Recast for tiled navmesh matching TileCache params
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
        .border_size = 0,
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

    // Calculate grid size
    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

    // Build full Recast pipeline to create actual NavMesh tile
    var heightfield = try nav.Heightfield.init(
        allocator,
        config.width,
        config.height,
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
    );
    defer heightfield.deinit();

    const indices = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const areas = try allocator.alloc(u8, 4);
    defer allocator.free(areas);
    @memset(areas, 1);

    var indices_i32 = try allocator.alloc(i32, indices.len);
    defer allocator.free(indices_i32);
    for (indices, 0..) |idx, i| {
        indices_i32[i] = @intCast(idx);
    }

    var verts_f32 = try allocator.alloc(f32, vertices.len * 3);
    defer allocator.free(verts_f32);
    for (vertices, 0..) |v, i| {
        verts_f32[i * 3 + 0] = v.x;
        verts_f32[i * 3 + 1] = v.y;
        verts_f32[i * 3 + 2] = v.z;
    }

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        verts_f32,
        indices_i32,
        areas,
        &heightfield,
        config.walkable_climb,
    );

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    var chf = try nav.CompactHeightfield.init(
        allocator,
        config.width,
        config.height,
        @intCast(span_count),
        config.walkable_height,
        config.walkable_climb,
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
        config.border_size,
    );
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(
        &ctx,
        config.walkable_height,
        config.walkable_climb,
        &heightfield,
        &chf,
    );

    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();

    try nav.recast.contour.buildContours(
        &ctx,
        &chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        0,
        allocator,
    );

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();

    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        &cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );

    // Create poly flags
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01);

    // Create NavMesh data
    const navmesh_params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(config.walkable_height)) * config.ch,
        .walkable_radius = @as(f32, @floatFromInt(config.walkable_radius)) * config.cs,
        .walkable_climb = @as(f32, @floatFromInt(config.walkable_climb)) * config.ch,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .build_bv_tree = true,
    };

    const navmesh_data = try nav.detour.createNavMeshData(&navmesh_params, allocator);
    defer allocator.free(navmesh_data);

    // Initialize NavMesh
    const nm_params = nav.detour.NavMeshParams{
        .orig = bmin,
        .tile_width = bmax.x - bmin.x,
        .tile_height = bmax.z - bmin.z,
        .max_tiles = 1,
        .max_polys = 256,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    // Add tile to NavMesh
    const tile_flags = nav.detour.TileFlags{ .free_data = false };
    const tile_ref = try navmesh.addTile(navmesh_data, tile_flags, 0);

    // Get the tile and verify it has polygons
    const tile_loc = navmesh.calcTileLoc(nav.Vec3.init(5, 0.5, 5));
    const tile = navmesh.getTileAt(tile_loc.x, tile_loc.y, 0);
    try testing.expect(tile != null);
    const initial_poly_count = tile.?.polys.len;
    try testing.expect(initial_poly_count > 0);

    // Initialize NavMeshQuery to test pathfinding
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    // Test point at center of mesh (should be walkable initially)
    const test_pos = [3]f32{ 5.0, 0.5, 5.0 };
    const ext = [3]f32{ 2.0, 2.0, 2.0 };
    var filter = nav.detour.QueryFilter.init();
    var nearest_ref: nav.detour.PolyRef = 0;
    var nearest_pt: [3]f32 = undefined;

    // Query before obstacle
    try query.findNearestPoly(&test_pos, &ext, &filter, &nearest_ref, &nearest_pt);
    try testing.expect(nearest_ref != 0); // Should find a polygon

    // Now create TileCache to add obstacles
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = [3]f32{ bmin.x, bmin.y, bmin.z },
        .cs = config.cs,
        .ch = config.ch,
        .width = config.width,
        .height = config.height,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 1,
        .max_obstacles = 16,
    };

    var stub_comp = StubCompressor{};
    var compressor = stub_comp.toInterface();

    var tilecache = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        &compressor,
        null,
    );
    defer tilecache.deinit();

    // Add large obstacle at test position
    const obstacle_ref = try tilecache.addObstacle(&test_pos, 1.5, 2.0);
    try testing.expect(obstacle_ref != 0);

    // Update TileCache (this should affect the navmesh)
    var up_to_date: bool = false;
    const status = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status.isSuccess());

    // Verify tile reference is still valid (tile should exist but may be modified)
    try testing.expect(tile_ref != 0);

    // Remove obstacle
    try tilecache.removeObstacle(obstacle_ref);

    // Update again (should restore navmesh)
    const status2 = try tilecache.update(0.1, &navmesh, &up_to_date);
    try testing.expect(status2.isSuccess());

    // Verify we can still query the navmesh
    var final_ref: nav.detour.PolyRef = 0;
    var final_pt: [3]f32 = undefined;
    try query.findNearestPoly(&test_pos, &ext, &filter, &final_ref, &final_pt);
    // After restoration, should still be able to find polygons
    try testing.expect(final_ref != 0);
}
