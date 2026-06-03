//! Tiled navmesh: build TWO adjacent tiles, stitch them into a multi-tile
//! NavMesh (max_tiles > 1), and find a path that crosses the shared tile
//! border. This mirrors the API used by the CI-verified integration tests
//! (`test/integration/removetile_link_leak_test.zig`,
//! `test/integration/detour_pipeline_test.zig`), which are the living
//! reference for how to drive the library.
//!
//! Run with:  zig build run-tiled_navmesh

const std = @import("std");
const nav = @import("recast-nav");

const TILE_SIZE: f32 = 6.0; // world units per tile (20 cells @ cs=0.3)

/// Build a single flat-quad tile at grid coords (tx, tz). The quad fills the
/// whole (border-expanded) tile cell so its outer edges land exactly on the
/// tile border and become portal edges that stitch to neighbour tiles.
/// `walkable_radius = 0` keeps erosion from pulling the polygon edges away
/// from the border. Returns owned navmesh-data bytes (caller frees).
fn buildFlatTile(allocator: std.mem.Allocator, tx: i32, tz: i32) ![]u8 {
    var ctx = nav.Context.init(allocator);

    const ox = @as(f32, @floatFromInt(tx)) * TILE_SIZE;
    const oz = @as(f32, @floatFromInt(tz)) * TILE_SIZE;

    // Tiled recipe: expand the heightfield by `border` cells on each side and
    // build with border_size > 0 so buildPolyMesh tags the tile-border edges as
    // portals (the recipe upstream's tiled samples use).
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
    const areas = [_]u8{ 1, 1 }; // RC_WALKABLE_AREA

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
    @memset(poly_flags, 0x01); // walkable

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
        // Tile grid coordinates: this is what makes the navmesh "tiled".
        .tile_x = tx,
        .tile_y = tz,
    };

    return try nav.detour.createNavMeshData(&params, allocator);
}

pub fn main() !void {
    // DebugAllocator doubles as a leak smoke-test: deinit() reports whether
    // anything was left unfreed.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    std.debug.print("Tiled navmesh build & cross-tile pathfinding\n", .{});
    std.debug.print("============================================\n\n", .{});

    // ---------------------------------------------------------------------
    // 1. Bake two adjacent tiles sharing the border at x = TILE_SIZE.
    //    Tile (0,0) covers x in [0, 6], tile (1,0) covers x in [6, 12].
    // ---------------------------------------------------------------------
    const data0 = try buildFlatTile(allocator, 0, 0);
    defer allocator.free(data0);
    const data1 = try buildFlatTile(allocator, 1, 0);
    defer allocator.free(data1);
    std.debug.print("baked tile (0,0): {d} bytes\n", .{data0.len});
    std.debug.print("baked tile (1,0): {d} bytes\n", .{data1.len});

    // ---------------------------------------------------------------------
    // 2. Multi-tile NavMesh (max_tiles > 1) and add both tiles.
    // ---------------------------------------------------------------------
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
    const ref1 = try navmesh.addTile(data1, flags, 0);

    const tile0_idx = navmesh.decodePolyId(ref0).tile;
    const tile1_idx = navmesh.decodePolyId(ref1).tile;
    std.debug.print("\nadded 2 tiles to NavMesh (max_tiles={d})\n", .{navmesh.max_tiles});
    std.debug.print("tile (0,0) -> index {d}\n", .{tile0_idx});
    std.debug.print("tile (1,0) -> index {d}\n", .{tile1_idx});

    // ---------------------------------------------------------------------
    // 3. Verify the two tiles actually stitch: tile0 must hold >=1 portal
    //    link into tile1 (a connection across the shared border).
    // ---------------------------------------------------------------------
    const NULL_LINK = nav.detour.common.NULL_LINK;
    var portal_links: usize = 0;
    {
        const t0 = &navmesh.tiles[tile0_idx];
        const poly_count: usize = @intCast(t0.header.?.poly_count);
        for (t0.polys[0..poly_count]) |*poly| {
            var j = poly.first_link;
            while (j != NULL_LINK) {
                if (navmesh.decodePolyId(t0.links[j].ref).tile == tile1_idx) portal_links += 1;
                j = t0.links[j].next;
            }
        }
    }
    std.debug.print("portal links tile(0,0) -> tile(1,0): {d}\n", .{portal_links});
    if (portal_links == 0) {
        std.debug.print("ERROR: tiles did not stitch\n", .{});
        return error.TilesNotStitched;
    }

    // ---------------------------------------------------------------------
    // 4. findPath across the tile boundary: start inside tile (0,0),
    //    end inside tile (1,0).
    // ---------------------------------------------------------------------
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    const start_in = [3]f32{ 1.5, 0.0, 3.0 }; // tile (0,0)
    const end_in = [3]f32{ 10.5, 0.0, 3.0 }; // tile (1,0)

    var start_ref: nav.detour.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&start_in, &ext, &filter, &start_ref, &start_pos);

    var end_ref: nav.detour.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_in, &ext, &filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("start/end poly not found\n", .{});
        return error.PolyNotFound;
    }

    const start_tile = navmesh.decodePolyId(start_ref).tile;
    const end_tile = navmesh.decodePolyId(end_ref).tile;
    std.debug.print("\nstart poly in tile index {d}, end poly in tile index {d}\n", .{ start_tile, end_tile });

    var path: [256]nav.detour.PolyRef = undefined;
    var path_count: usize = 0;
    _ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
    std.debug.print("path: {d} polys\n", .{path_count});

    // Confirm the path really crosses tiles: it should touch both tile indices.
    var touches_tile0 = false;
    var touches_tile1 = false;
    for (path[0..path_count]) |pref| {
        const t = navmesh.decodePolyId(pref).tile;
        if (t == tile0_idx) touches_tile0 = true;
        if (t == tile1_idx) touches_tile1 = true;
    }
    std.debug.print("path spans both tiles: {}\n", .{touches_tile0 and touches_tile1});

    if (path_count > 0) {
        var straight: [256 * 3]f32 = undefined;
        var straight_flags: [256]u8 = undefined;
        var straight_refs: [256]nav.detour.PolyRef = undefined;
        var straight_count: usize = 0;
        _ = try query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &straight, &straight_flags, &straight_refs, &straight_count, 0);

        std.debug.print("straight path: {d} waypoints\n", .{straight_count});
        for (0..straight_count) |i| {
            std.debug.print("  {d}: ({d:.2}, {d:.2}, {d:.2})\n", .{ i, straight[i * 3 + 0], straight[i * 3 + 1], straight[i * 3 + 2] });
        }
    }

    std.debug.print("\ndone.\n", .{});
}
