const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

// =============================================================================
// REGRESSION TEST — removeTile must unconnect neighbour portal links
//
// Bug (fixed by `dtNavMesh::unconnectLinks` port in NavMesh.removeTile):
// Detour links live in a fixed per-tile pool (`header.max_link_count`) managed
// by a freelist. When a tile is removed, neighbour tiles still held portal
// links pointing at it. Those Link records were never returned to the
// neighbour's freelist, so every remove+add cycle (tilecache rebake,
// temp-obstacles, editing) leaked links out of each neighbour's pool until
// `allocLink` returned NULL_LINK and `connectExtLinks` silently dropped
// portal stitches.
//
// This test builds two adjacent coplanar tiles that stitch across their shared
// border, then rebuilds one tile many times. Without the fix the neighbour's
// freelink count strictly decreases each cycle (leak); with the fix it is
// invariant and the portal stays stitched.
// =============================================================================

const NULL_LINK = nav.detour.common.NULL_LINK;

const TILE_SIZE: f32 = 6.0; // world units per tile (20 cells @ cs=0.3)

/// Count how many links sit on `tile`'s freelist (unallocated link slots).
fn countFreeLinks(tile: *const nav.detour.MeshTile) usize {
    var n: usize = 0;
    var j = tile.links_free_list;
    while (j != NULL_LINK) : (n += 1) {
        j = tile.links[j].next;
    }
    return n;
}

/// Count links inside `tile` (the neighbour) whose ref points at `target_idx`.
fn linksToTile(navmesh: *nav.detour.NavMesh, tile_idx: u32, target_idx: u32) usize {
    const tile = &navmesh.tiles[tile_idx];
    if (tile.header == null) return 0;
    const poly_count: usize = @intCast(tile.header.?.poly_count);
    var count: usize = 0;
    for (tile.polys[0..poly_count]) |*poly| {
        var j = poly.first_link;
        while (j != NULL_LINK) {
            if (navmesh.decodePolyId(tile.links[j].ref).tile == target_idx) count += 1;
            j = tile.links[j].next;
        }
    }
    return count;
}

/// Build a single flat-quad tile at grid coords (tx, tz). The quad fills the
/// whole tile cell so its outer edges land exactly on the tile border and
/// become portal edges that stitch to neighbour tiles. `walkable_radius = 0`
/// keeps erosion from pulling the polygon edges away from the border.
fn buildFlatTile(allocator: std.mem.Allocator, tx: i32, tz: i32) ![]u8 {
    var ctx = nav.Context.init(allocator);

    const ox = @as(f32, @floatFromInt(tx)) * TILE_SIZE;
    const oz = @as(f32, @floatFromInt(tz)) * TILE_SIZE;

    // Tiled build: expand the heightfield by `border` cells on each side and
    // build with border_size > 0 so buildPolyMesh tags the tile-border edges as
    // portals (the recipe upstream's tiled samples use). walkable_radius = 0
    // skips erosion to keep the test geometry trivial.
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
        .bmin = nav.Vec3.init(ox - pad, -1.0, oz - pad),
        .bmax = nav.Vec3.init(ox + TILE_SIZE + pad, 1.0, oz + TILE_SIZE + pad),
    };

    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(config.bmin, config.bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

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

    // Flat quad (two triangles) covering the whole expanded field at y = 0, so
    // every cell (including the border ring) is walkable.
    const x0 = config.bmin.x;
    const x1 = config.bmax.x;
    const z0 = config.bmin.z;
    const z1 = config.bmax.z;
    const verts = [_]f32{
        x0, 0.0, z0,
        x1, 0.0, z0,
        x1, 0.0, z1,
        x0, 0.0, z1,
    };
    const indices = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 1, 1 };

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        &verts,
        &indices,
        &areas,
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
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, allocator);

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

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01);

    const params = nav.detour.NavMeshCreateParams{
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
        // Use the polymesh bounds (true tile bounds: expanded field shrunk back
        // by border on each side) so the tile header lands on the real grid.
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(config.walkable_height)) * config.ch,
        .walkable_radius = @as(f32, @floatFromInt(config.walkable_radius)) * config.cs,
        .walkable_climb = @as(f32, @floatFromInt(config.walkable_climb)) * config.ch,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .build_bv_tree = true,
        .tile_x = tx,
        .tile_y = tz,
    };

    return try nav.detour.createNavMeshData(&params, allocator);
}

test "removeTile: neighbour portal links do not leak across rebake cycles" {
    const allocator = testing.allocator;

    // Two adjacent tiles sharing the border at x = TILE_SIZE.
    const data0 = try buildFlatTile(allocator, 0, 0);
    defer allocator.free(data0);
    const data1 = try buildFlatTile(allocator, 1, 0);
    defer allocator.free(data1);

    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = TILE_SIZE,
        .tile_height = TILE_SIZE,
        .max_tiles = 8,
        .max_polys = 256,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    const flags = nav.detour.TileFlags{ .free_data = false };

    const ref0 = try navmesh.addTile(data0, flags, 0);
    var ref1 = try navmesh.addTile(data1, flags, 0);

    const tile0_idx = navmesh.decodePolyId(ref0).tile;

    // Sanity: the two tiles must actually stitch, otherwise the test proves
    // nothing. tile0 (the neighbour we keep) must hold >=1 link into tile1.
    {
        const t1_idx = navmesh.decodePolyId(ref1).tile;
        const stitched = linksToTile(&navmesh, tile0_idx, t1_idx);
        try testing.expect(stitched >= 1);
    }

    const free0_initial = countFreeLinks(&navmesh.tiles[tile0_idx]);

    // Rebake tile1 many times. Each cycle = removeTile + addTile, exactly the
    // tilecache / temp-obstacle path that triggered the leak.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const removed = try navmesh.removeTile(ref1);
        try testing.expect(removed.data.ptr == data1.ptr); // free_data=false: we own it
        ref1 = try navmesh.addTile(data1, flags, 0);
    }

    const free0_after = countFreeLinks(&navmesh.tiles[tile0_idx]);

    // Primary assertion: neighbour's link pool is conserved across rebakes.
    // Without unconnectLinks this count strictly decreases every cycle.
    try testing.expectEqual(free0_initial, free0_after);

    // Secondary: the portal is still stitched after all the churn.
    const t1_idx_final = navmesh.decodePolyId(ref1).tile;
    try testing.expect(linksToTile(&navmesh, tile0_idx, t1_idx_final) >= 1);
}
