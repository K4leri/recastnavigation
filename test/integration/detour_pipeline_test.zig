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

test "Detour Pipeline: Build NavMesh from Recast Data" {
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
        0,
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

    // Verify we have mesh data
    try testing.expect(pmesh.npolys > 0);
    try testing.expect(pmesh.nverts > 0);
    try testing.expect(dmesh.nmeshes > 0);

    // Step 11: Create default poly flags (mark all as walkable)
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // Default walkable flag

    // Create NavMesh data using Detour (without detail mesh for now)
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

    // Verify NavMesh data was created
    try testing.expect(navmesh_data.len > 0);
}

test "Detour Pipeline: NavMesh and Query Initialization" {
    const allocator = testing.allocator;

    // Create context
    var ctx = nav.Context.init(allocator);

    // Create simple mesh (same as before)
    const vertices = createSimpleBoxMesh();

    // Configure Recast (same as before - abbreviated for brevity)
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

    // Build full Recast pipeline (abbreviated - same steps as test 1)
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

    // Create default poly flags (mark all as walkable)
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // Default walkable flag

    // Create NavMesh data
    const navmesh_params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
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
    _ = try navmesh.addTile(navmesh_data, tile_flags, 0);

    // Initialize NavMeshQuery
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&navmesh, 2048);

    // Verify NavMesh and Query are initialized
    try testing.expect(navmesh.max_tiles > 0);
    try testing.expect(navmesh.tiles.len > 0);
}
