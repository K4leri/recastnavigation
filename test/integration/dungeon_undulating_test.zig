const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");
const obj_loader = @import("obj_loader");

// Quick test for dungeon.obj
test "Real Mesh: dungeon.obj quick test" {
    const allocator = testing.allocator;

    // Load dungeon.obj
    var mesh = obj_loader.loadObj("test_data/dungeon.obj", allocator) catch |err| {
        std.debug.print("Failed to load dungeon.obj: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer mesh.deinit();

    std.debug.print("\n=== Loaded dungeon.obj ===\n", .{});
    std.debug.print("Vertices: {d}\n", .{mesh.vertex_count});
    std.debug.print("Triangles: {d}\n\n", .{mesh.tri_count});

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
    @memset(areas, 1);

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        mesh.vertices,
        mesh.indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

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

    std.debug.print("Compact heightfield: {d} spans\n", .{span_count});

    // Erode, build distance field and regions
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    // Count regions
    var max_region: u16 = 0;
    for (chf.spans) |span| {
        if (span.reg > max_region) max_region = span.reg;
    }
    std.debug.print("Regions: {d}\n", .{max_region});

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

    std.debug.print("Contours: {d}\n", .{cset.nconts});

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

    std.debug.print("PolyMesh: {d} vertices, {d} polygons\n", .{ pmesh.nverts, pmesh.npolys });

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

    std.debug.print("PolyMeshDetail: {d} meshes, {d} verts, {d} tris\n\n", .{
        dmesh.nmeshes,
        dmesh.nverts,
        dmesh.ntris,
    });
}

// Quick test for undulating.obj
test "Real Mesh: undulating.obj quick test" {
    const allocator = testing.allocator;

    // Load undulating.obj
    var mesh = obj_loader.loadObj("test_data/undulating.obj", allocator) catch |err| {
        std.debug.print("Failed to load undulating.obj: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer mesh.deinit();

    std.debug.print("\n=== Loaded undulating.obj ===\n", .{});
    std.debug.print("Vertices: {d}\n", .{mesh.vertex_count});
    std.debug.print("Triangles: {d}\n\n", .{mesh.tri_count});

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
    @memset(areas, 1);

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        mesh.vertices,
        mesh.indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

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

    std.debug.print("Compact heightfield: {d} spans\n", .{span_count});

    // Erode, build distance field and regions
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    // Count regions
    var max_region: u16 = 0;
    for (chf.spans) |span| {
        if (span.reg > max_region) max_region = span.reg;
    }
    std.debug.print("Regions: {d}\n", .{max_region});

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

    std.debug.print("Contours: {d}\n", .{cset.nconts});

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

    std.debug.print("PolyMesh: {d} vertices, {d} polygons\n", .{ pmesh.nverts, pmesh.npolys });

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

    std.debug.print("PolyMeshDetail: {d} meshes, {d} verts, {d} tris\n\n", .{
        dmesh.nmeshes,
        dmesh.nverts,
        dmesh.ntris,
    });
}
