const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");
const obj_loader = @import("obj_loader");

// Integration test using real nav_test.obj mesh data
// This tests the full Recast pipeline with realistic geometry
test "Real Mesh: nav_test.obj full pipeline" {
    const allocator = testing.allocator;

    // Load nav_test.obj
    var mesh = obj_loader.loadObj("test_data/nav_test.obj", allocator) catch |err| {
        std.debug.print("Failed to load nav_test.obj: {}\n", .{err});
        std.debug.print("Make sure test_data/nav_test.obj exists\n", .{});
        return error.SkipZigTest;
    };
    defer mesh.deinit();

    std.debug.print("\n=== Loaded nav_test.obj ===\n", .{});
    std.debug.print("Vertices: {d}\n", .{mesh.vertex_count});
    std.debug.print("Triangles: {d}\n", .{mesh.tri_count});

    // Create context
    var ctx = nav.Context.init(allocator);

    // Configure Recast
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

    // Convert mesh vertices to Vec3 array for calcBounds
    const verts_vec3 = try allocator.alloc(nav.Vec3, mesh.vertex_count);
    defer allocator.free(verts_vec3);
    for (0..mesh.vertex_count) |i| {
        verts_vec3[i] = nav.Vec3.init(
            mesh.vertices[i * 3 + 0],
            mesh.vertices[i * 3 + 1],
            mesh.vertices[i * 3 + 2],
        );
    }

    nav.RecastConfig.calcBounds(verts_vec3, &bmin, &bmax);
    config.bmin = bmin;
    config.bmax = bmax;

    std.debug.print("Bounds: min=({d:.2}, {d:.2}, {d:.2}) max=({d:.2}, {d:.2}, {d:.2})\n", .{
        bmin.x, bmin.y, bmin.z,
        bmax.x, bmax.y, bmax.z,
    });

    // Calculate grid size
    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

    std.debug.print("Grid size: {d}x{d}\n", .{ size_x, size_z });

    // Build heightfield
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

    // Rasterize triangles
    const areas = try allocator.alloc(u8, mesh.tri_count);
    defer allocator.free(areas);
    @memset(areas, 1); // All walkable

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        mesh.vertices,
        mesh.indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

    std.debug.print("Rasterized {d} triangles\n", .{mesh.tri_count});

    // Filter
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    // Build compact heightfield
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

    std.debug.print("Built compact heightfield with {d} spans\n", .{span_count});

    // Erode walkable area
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);

    // Build distance field and regions
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    // Build contours
    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();

    try nav.recast.contour.buildContours(
        &ctx,
        &chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        nav.recast.config.CONTOUR_TESS_WALL_EDGES,
        allocator,
    );

    std.debug.print("Built {d} contours\n", .{cset.nconts});

    // Print contour details
    std.debug.print("Contour details:\n", .{});
    for (0..@as(usize, @intCast(cset.nconts))) |i| {
        const cont = cset.conts[i];
        std.debug.print("  Contour {d}: nverts={d}, reg={d}, area={d}\n", .{ i, cont.nverts, cont.reg, cont.area });
    }

    // Build polygon mesh
    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();

    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        &cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );

    std.debug.print("Built PolyMesh: {d} vertices, {d} polygons\n", .{ pmesh.nverts, pmesh.npolys });

    // Verify we got meaningful results
    try testing.expect(pmesh.npolys > 0);
    try testing.expect(pmesh.nverts > 0);

    // Build detail mesh
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

    std.debug.print("Built PolyMeshDetail: {d} meshes, {d} verts, {d} tris\n", .{
        dmesh.nmeshes,
        dmesh.nverts,
        dmesh.ntris,
    });

    // Test canRemoveVertex on real mesh
    std.debug.print("\n=== Testing canRemoveVertex on real mesh ===\n", .{});

    // Try removing first vertex
    if (pmesh.nverts > 0) {
        const can_remove_0 = try nav.recast.mesh.canRemoveVertex(&ctx, &pmesh, 0, allocator);
        std.debug.print("Can remove vertex 0: {}\n", .{can_remove_0});
    }

    // Try removing last vertex
    if (pmesh.nverts > 1) {
        const last_vert: u16 = @intCast(pmesh.nverts - 1);
        const can_remove_last = try nav.recast.mesh.canRemoveVertex(&ctx, &pmesh, last_vert, allocator);
        std.debug.print("Can remove vertex {d}: {}\n", .{ last_vert, can_remove_last });
    }

    // Try removing middle vertex
    if (pmesh.nverts > 2) {
        const mid_vert: u16 = @intCast(@divTrunc(pmesh.nverts, 2));
        const can_remove_mid = try nav.recast.mesh.canRemoveVertex(&ctx, &pmesh, mid_vert, allocator);
        std.debug.print("Can remove vertex {d}: {}\n", .{ mid_vert, can_remove_mid });
    }

    std.debug.print("\n=== Real mesh test completed successfully ===\n", .{});
}
