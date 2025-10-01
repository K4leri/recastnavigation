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

test "Recast Pipeline: Simple Box Mesh → NavMesh" {
    const allocator = testing.allocator;

    // Create context
    var ctx = nav.Context.init(allocator);

    // Create simple mesh
    const vertices = createSimpleBoxMesh();

    // Configure Recast
    var config = nav.RecastConfig{
        .cs = 0.3, // cell size
        .ch = 0.2, // cell height
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

    // Step 1: Create heightfield
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

    // Step 2: Rasterize triangles
    const indices = [_]u16{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
    };
    const areas = try allocator.alloc(u8, 4);
    defer allocator.free(areas);
    @memset(areas, 1); // Mark all as walkable

    // Convert indices to i32 array for rasterization
    var indices_i32 = try allocator.alloc(i32, indices.len);
    defer allocator.free(indices_i32);
    for (indices, 0..) |idx, i| {
        indices_i32[i] = @intCast(idx);
    }

    // Convert Vec3 array to f32 array for rasterization
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

    // Step 3: Filter walkable surfaces
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    // Step 4: Build compact heightfield
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

    // Step 5: Erode walkable area
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);

    // Step 6: Build distance field
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);

    // Step 7: Build regions
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    // Step 8: Build contours
    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();

    try nav.recast.contour.buildContours(
        &ctx,
        &chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        0, // buildFlags
        allocator,
    );

    // Step 9: Build polygon mesh
    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();

    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        &cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );

    // Step 10: Build detail mesh
    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();

    try nav.recast.detail.buildPolyMeshDetail(
        &ctx,
        &pmesh,
        &chf,
        config.detail_sample_dist,
        config.detail_sample_max_error,
        &dmesh,
        allocator,
    );

    // Verify results
    // 1. Heightfield should have dimensions
    try testing.expect(heightfield.width > 0);
    try testing.expect(heightfield.height > 0);

    // 2. Compact heightfield should have cells
    try testing.expect(chf.width > 0);
    try testing.expect(chf.height > 0);
    try testing.expect(chf.span_count > 0);

    // 3. Should have at least one region
    try testing.expect(chf.max_regions > 0);

    // 4. Should have contours
    try testing.expect(cset.nconts > 0);

    // 5. PolyMesh should have at least one polygon
    try testing.expect(pmesh.npolys > 0);
    try testing.expect(pmesh.nverts > 0);

    // 6. Detail mesh should have triangles
    try testing.expect(dmesh.nmeshes > 0);
    try testing.expect(dmesh.nverts > 0);
    try testing.expect(dmesh.ntris > 0);

    // 7. Verify detail mesh corresponds to poly mesh
    try testing.expect(dmesh.nmeshes == pmesh.npolys);
}

test "Recast Pipeline: Verify Config Bounds Calculation" {
    const vertices = [_]nav.Vec3{
        nav.Vec3.init(0, 0, 0),
        nav.Vec3.init(10, 0, 0),
        nav.Vec3.init(10, 0, 10),
        nav.Vec3.init(0, 0, 10),
    };

    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    nav.RecastConfig.calcBounds(&vertices, &bmin, &bmax);

    // Verify bounds are correct
    try testing.expectEqual(@as(f32, 0.0), bmin.x);
    try testing.expectEqual(@as(f32, 0.0), bmin.y);
    try testing.expectEqual(@as(f32, 0.0), bmin.z);
    try testing.expectEqual(@as(f32, 10.0), bmax.x);
    try testing.expectEqual(@as(f32, 0.0), bmax.y);
    try testing.expectEqual(@as(f32, 10.0), bmax.z);
}

test "Recast Pipeline: Grid Size Calculation" {
    const bmin = nav.Vec3.init(0, 0, 0);
    const bmax = nav.Vec3.init(10, 0, 10);
    const cs: f32 = 0.3;

    var width: i32 = 0;
    var height: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, cs, &width, &height);

    // Grid should be non-zero
    try testing.expect(width > 0);
    try testing.expect(height > 0);

    // Grid dimensions should match expected size
    const expected_width = @ceil(10.0 / 0.3);
    const expected_height = @ceil(10.0 / 0.3);
    try testing.expectEqual(@as(i32, @intFromFloat(expected_width)), width);
    try testing.expectEqual(@as(i32, @intFromFloat(expected_height)), height);
}

test "Recast Pipeline: Heightfield Creation and Rasterization" {
    const allocator = testing.allocator;
    var ctx = nav.Context.init(allocator);

    const vertices = createSimpleBoxMesh();

    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    nav.RecastConfig.calcBounds(&vertices, &bmin, &bmax);

    var width: i32 = 0;
    var height: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, 0.3, &width, &height);

    // Create heightfield
    var heightfield = try nav.Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        0.3,
        0.2,
    );
    defer heightfield.deinit();

    // Verify heightfield structure
    try testing.expectEqual(width, heightfield.width);
    try testing.expectEqual(height, heightfield.height);
    try testing.expectEqual(@as(f32, 0.3), heightfield.cs);
    try testing.expectEqual(@as(f32, 0.2), heightfield.ch);

    // Rasterize triangles
    const indices = [_]u16{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
    };
    const areas = try allocator.alloc(u8, 4);
    defer allocator.free(areas);
    @memset(areas, 1); // Mark all as walkable

    // Convert Vec3 array to f32 array for rasterization
    var verts_f32: [12 * 3]f32 = undefined;
    for (vertices, 0..) |v, i| {
        verts_f32[i * 3 + 0] = v.x;
        verts_f32[i * 3 + 1] = v.y;
        verts_f32[i * 3 + 2] = v.z;
    }

    try nav.recast.rasterization.rasterizeTrianglesU16(&ctx, &verts_f32, &indices, areas, &heightfield, 9);

    // After rasterization, heightfield should have some spans
    const span_count = heightfield.getSpanCount();
    try testing.expect(span_count > 0);
}
