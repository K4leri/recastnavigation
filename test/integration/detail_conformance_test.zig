const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");
const obj_loader = @import("obj_loader");

// Regression test for the PolyMeshDetail conformance bug: `polyMinExtent`
// collapsed to ~0 (missing the per-edge max), so most polygons skipped internal
// detail sampling and the navmesh stopped following undulating terrain.
//
// Built with the RecastDemo "Solo Mesh" defaults for undulating.obj, the C++
// reference produces ~216 detail meshes / ~2800 verts / ~3200 tris. The buggy
// Zig build produced only ~2429 verts / ~2441 tris (≈11 tris/poly vs ≈15). We
// assert the detail mesh is densely sampled so the regression cannot return.
test "detail mesh conforms to undulating terrain (polyMinExtent)" {
    const a = testing.allocator;
    var mesh = obj_loader.loadObj("test_data/undulating.obj", a) catch return error.SkipZigTest;
    defer mesh.deinit();

    var ctx = nav.Context.init(a);

    const cs: f32 = 0.3;
    const ch: f32 = 0.2;
    // RecastDemo Solo Mesh defaults (cell-space), 1:1 with the demo build.
    var config = nav.RecastConfig{
        .cs = cs,
        .ch = ch,
        .walkable_slope_angle = 45.0,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 2,
        .max_edge_len = 40,
        .max_simplification_error = 1.3,
        .min_region_area = 64,
        .merge_region_area = 400,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 1.8,
        .detail_sample_max_error = 0.2,
        .border_size = 0,
        .width = 0,
        .height = 0,
        .bmin = nav.Vec3.zero(),
        .bmax = nav.Vec3.zero(),
    };

    const vv = try a.alloc(nav.Vec3, mesh.vertex_count);
    defer a.free(vv);
    for (0..mesh.vertex_count) |i| vv[i] = nav.Vec3.init(mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2]);
    nav.RecastConfig.calcBounds(vv, &config.bmin, &config.bmax);
    var sx: i32 = 0;
    var sz: i32 = 0;
    nav.RecastConfig.calcGridSize(config.bmin, config.bmax, cs, &sx, &sz);
    config.width = sx;
    config.height = sz;

    var hf = try nav.Heightfield.init(a, config.width, config.height, config.bmin, config.bmax, cs, ch);
    defer hf.deinit();

    const areas = try a.alloc(u8, mesh.tri_count);
    defer a.free(areas);
    @memset(areas, 0);
    nav.recast.filter.markWalkableTriangles(&ctx, config.walkable_slope_angle, mesh.vertices, mesh.indices, areas);
    try nav.recast.rasterization.rasterizeTriangles(&ctx, mesh.vertices, mesh.indices, areas, &hf, config.walkable_climb);

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &hf);

    const sc = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(a, config.width, config.height, @intCast(sc), config.walkable_height, config.walkable_climb, config.bmin, config.bmax, cs, ch, config.border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, config.walkable_height, config.walkable_climb, &hf, &chf);

    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, a);
    try nav.recast.region.buildDistanceField(&ctx, &chf, a);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, a);

    var cset = nav.ContourSet.init(a);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, config.max_simplification_error, config.max_edge_len, &cset, nav.recast.config.CONTOUR_TESS_WALL_EDGES, a);

    var pmesh = nav.PolyMesh.init(a);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, a);

    var dmesh = nav.PolyMeshDetail.init(a);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, config.detail_sample_dist, config.detail_sample_max_error, &dmesh, a);

    // The poly mesh is identical to the C++ reference (374 verts / 216 polys).
    try testing.expectEqual(@as(i32, 216), pmesh.npolys);

    // Detail mesh must be densely sampled (C++ reference ≈ 2800 verts / 3200 tris).
    // The polyMinExtent regression produced only 2429 / 2441 — well under these.
    try testing.expect(dmesh.nverts > 2700);
    try testing.expect(dmesh.ntris > 3000);
}
