const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

// =============================================================================
// mergePolyMeshes (rcMergePolyMeshes) — merge two adjacent tile polymeshes into
// one, verifying shared-border vertices are deduplicated and all polygons are
// carried over.
// =============================================================================

const TILE: f32 = 6.0;

/// Build a flat-quad tile's PolyMesh at grid coords (tx, 0). Caller owns/deinits
/// the returned PolyMesh. border_size > 0 so tile-border edges get portal flags.
fn buildTilePolyMesh(allocator: std.mem.Allocator, tx: i32) !nav.PolyMesh {
    var ctx = nav.Context.init(allocator);

    const ox = @as(f32, @floatFromInt(tx)) * TILE;
    const cs: f32 = 0.3;
    const border: i32 = 4;
    const pad: f32 = @as(f32, @floatFromInt(border)) * cs;

    var config = nav.RecastConfig{
        .cs = cs,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 0,
        .max_edge_len = 12,
        .max_simplification_error = 1.3,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .border_size = border,
        .width = 0,
        .height = 0,
        .bmin = nav.Vec3.init(ox - pad, -1.0, 0 - pad),
        .bmax = nav.Vec3.init(ox + TILE + pad, 1.0, TILE + pad),
    };

    var sx: i32 = 0;
    var sz: i32 = 0;
    nav.RecastConfig.calcGridSize(config.bmin, config.bmax, config.cs, &sx, &sz);
    config.width = sx;
    config.height = sz;

    var hf = try nav.Heightfield.init(allocator, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch);
    defer hf.deinit();

    const x0 = config.bmin.x;
    const x1 = config.bmax.x;
    const z0 = config.bmin.z;
    const z1 = config.bmax.z;
    const verts = [_]f32{ x0, 0.0, z0, x1, 0.0, z0, x1, 0.0, z1, x0, 0.0, z1 };
    const indices = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 1, 1 };

    try nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &indices, &areas, &hf, config.walkable_climb);
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, config.width, config.height, @intCast(span_count), config.walkable_height, config.walkable_climb, config.bmin, config.bmax, config.cs, config.ch, config.border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, config.walkable_height, config.walkable_climb, &hf, &chf);

    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, config.max_simplification_error, config.max_edge_len, &cset, 0, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, allocator);
    return pmesh;
}

test "mergePolyMeshes: dedupes shared border vertices and keeps all polys" {
    const allocator = testing.allocator;

    var m0 = try buildTilePolyMesh(allocator, 0);
    defer m0.deinit();
    var m1 = try buildTilePolyMesh(allocator, 1);
    defer m1.deinit();

    // Both tiles must have produced geometry.
    try testing.expect(m0.npolys > 0 and m1.npolys > 0);
    try testing.expect(m0.nverts > 0 and m1.nverts > 0);

    var merged = nav.PolyMesh.init(allocator);
    defer merged.deinit();

    var ctx = nav.Context.init(allocator);
    const inputs = [_]*nav.PolyMesh{ &m0, &m1 };
    try nav.recast.mesh.mergePolyMeshes(&ctx, &inputs, inputs.len, &merged, allocator);

    // All polygons carried over.
    try testing.expectEqual(m0.npolys + m1.npolys, merged.npolys);

    // Shared border vertices were deduplicated: merged has strictly fewer verts
    // than the naive sum (the tiles touch along x = TILE).
    try testing.expect(merged.nverts < m0.nverts + m1.nverts);
    try testing.expect(merged.nverts > 0);

    // Every poly index references a valid merged vertex.
    const nvp: usize = @intCast(merged.nvp);
    const MESH_NULL_IDX: u16 = 0xffff;
    for (0..@intCast(merged.npolys)) |p| {
        const poly = merged.polys[p * 2 * nvp ..];
        for (0..nvp) |k| {
            if (poly[k] == MESH_NULL_IDX) break;
            try testing.expect(poly[k] < @as(u16, @intCast(merged.nverts)));
        }
    }
}
