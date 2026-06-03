//! Off-mesh connections: link two *disconnected* walkable areas with a single
//! traversal link (a jump), then prove that pathfinding routes across it.
//!
//! Unlike the by-hand navmesh fixtures in the unit tests, this example drives the
//! WHOLE Recast pipeline (rasterize -> filter -> compact -> regions -> contours ->
//! poly mesh -> detail mesh) on two physically separated floor quads, so Recast
//! itself produces two disconnected polygons. With no shared edge between them the
//! ONLY A->B route is the off-mesh connection we declare in NavMeshCreateParams.
//! findPath must therefore include the off-mesh poly, and findStraightPath must
//! emit a waypoint flagged STRAIGHTPATH_OFFMESH_CONNECTION.
//!
//! Run with:  zig build run-offmesh_connections
//!
//! NOTE on direction (`off_mesh_con_dir`): 1 = bidirectional, 0 = one-way
//! (start -> end only). Area/flags here are plain numbers (the upstream demo's
//! POLYAREA_JUMP / POLYFLAGS_JUMP enums are application-defined, not library
//! symbols); 0x01 is the conventional "walkable" flag the default filter accepts.

const std = @import("std");
const nav = @import("recast-nav");

pub fn main() !void {
    // DebugAllocator (0.16 successor to GeneralPurposeAllocator): also a leak
    // smoke-test — deinit() panics if anything was left unfreed.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("Off-mesh connections: jump between two disconnected platforms\n", .{});
    std.debug.print("============================================================\n\n", .{});

    // ---------------------------------------------------------------------
    // 1. Input geometry: TWO separate flat quads with a gap between them.
    //    Quad A: x in [0,8],   z in [0,10]
    //    Quad B: x in [14,22], z in [0,10]   (gap x in [8,14] -> no shared edge)
    // ---------------------------------------------------------------------
    const verts = [_]f32{
        // Quad A
        0,  0, 0, // 0
        8,  0, 0, // 1
        8,  0, 10, // 2
        0,  0, 10, // 3
        // Quad B
        14, 0, 0, // 4
        22, 0, 0, // 5
        22, 0, 10, // 6
        14, 0, 10, // 7
    };
    const indices = [_]i32{
        0, 1, 2, 0, 2, 3, // quad A
        4, 5, 6, 4, 6, 7, // quad B
    };
    const tri_count = indices.len / 3;

    var bmin = nav.Vec3.init(verts[0], verts[1], verts[2]);
    var bmax = bmin;
    var vi: usize = 0;
    while (vi < verts.len) : (vi += 3) {
        bmin.x = @min(bmin.x, verts[vi + 0]);
        bmin.y = @min(bmin.y, verts[vi + 1]);
        bmin.z = @min(bmin.z, verts[vi + 2]);
        bmax.x = @max(bmax.x, verts[vi + 0]);
        bmax.y = @max(bmax.y, verts[vi + 1]);
        bmax.z = @max(bmax.z, verts[vi + 2]);
    }
    // Give the heightfield a little vertical headroom so spans rasterize cleanly.
    bmin.y -= 1.0;
    bmax.y += 1.0;

    // ---------------------------------------------------------------------
    // 2. Build configuration (small agent so the two 8x10 quads survive erosion)
    // ---------------------------------------------------------------------
    var cfg = nav.RecastConfig{
        .cs = 0.3,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 2,
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
        .bmin = bmin,
        .bmax = bmax,
    };
    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, cfg.cs, &size_x, &size_z);
    cfg.width = size_x;
    cfg.height = size_z;
    std.debug.print("grid: {d} x {d} cells\n", .{ cfg.width, cfg.height });

    // ---------------------------------------------------------------------
    // 3. Rasterize -> filter -> compact -> erode
    // ---------------------------------------------------------------------
    var hf = try nav.Heightfield.init(allocator, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    defer hf.deinit();

    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, 1); // RC_WALKABLE_AREA

    try nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &indices, areas, &hf, cfg.walkable_climb);

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, cfg.width, cfg.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch, cfg.border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);

    // ---------------------------------------------------------------------
    // 4. Distance field -> regions -> contours -> poly mesh -> detail mesh
    // ---------------------------------------------------------------------
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, 0, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    std.debug.print("polymesh: {d} verts, {d} polys (expect >= 2 disconnected polys)\n", .{ pmesh.nverts, pmesh.npolys });

    // ---------------------------------------------------------------------
    // 5. Declare the OFF-MESH CONNECTION bridging quad A and quad B.
    //    Endpoint on A at (7,0,5); endpoint on B at (15,0,5). The link spans the
    //    gap [8,14] that has no walkable mesh under it.
    // ---------------------------------------------------------------------
    const off_mesh_verts = [_]f32{
        7.0,  0.0, 5.0, // start (on quad A)
        15.0, 0.0, 5.0, // end   (on quad B)
    };
    const off_mesh_rad = [_]f32{ 0.6 };
    const off_mesh_flags = [_]u16{ 0x01 }; // walkable flag (default filter accepts)
    const off_mesh_areas = [_]u8{ 0 };
    const off_mesh_dir = [_]u8{ 1 }; // 1 = bidirectional
    const off_mesh_user_id = [_]u32{ 42 };

    std.debug.print("off-mesh link: ({d:.1},{d:.1},{d:.1}) <-> ({d:.1},{d:.1},{d:.1}) r={d:.2} bidir\n\n", .{
        off_mesh_verts[0], off_mesh_verts[1], off_mesh_verts[2],
        off_mesh_verts[3], off_mesh_verts[4], off_mesh_verts[5],
        off_mesh_rad[0],
    });

    // ---------------------------------------------------------------------
    // 6. Detour navmesh data + tile (with the off-mesh connection wired in)
    // ---------------------------------------------------------------------
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // walkable

    const create_params = nav.detour.NavMeshCreateParams{
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
        // off-mesh connection block:
        .off_mesh_con_verts = &off_mesh_verts,
        .off_mesh_con_rad = &off_mesh_rad,
        .off_mesh_con_flags = &off_mesh_flags,
        .off_mesh_con_areas = &off_mesh_areas,
        .off_mesh_con_dir = &off_mesh_dir,
        .off_mesh_con_user_id = &off_mesh_user_id,
        .off_mesh_con_count = 1,
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * cfg.ch,
        .walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cfg.cs,
        .walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * cfg.ch,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .build_bv_tree = true,
    };
    const navmesh_data = try nav.detour.createNavMeshData(&create_params, allocator);
    defer allocator.free(navmesh_data);

    var navmesh = try nav.detour.NavMesh.init(allocator, .{
        .orig = bmin,
        .tile_width = bmax.x - bmin.x,
        .tile_height = bmax.z - bmin.z,
        .max_tiles = 1,
        .max_polys = 256,
    });
    defer navmesh.deinit();
    _ = try navmesh.addTile(navmesh_data, nav.detour.TileFlags{ .free_data = false }, 0);

    // Confirm the off-mesh connection actually landed in the tile header.
    {
        const tile = navmesh.getTileAt(0, 0, 0).?;
        std.debug.print("tile: {d} mesh polys + {d} off-mesh poly(s)\n", .{
            @as(i32, tile.header.?.poly_count) - @as(i32, tile.header.?.off_mesh_con_count),
            tile.header.?.off_mesh_con_count,
        });
        if (tile.header.?.off_mesh_con_count < 1) {
            std.debug.print("ERROR: off-mesh connection was not stored (endpoints off-poly?)\n", .{});
            return error.OffMeshConnectionNotStored;
        }
    }

    // ---------------------------------------------------------------------
    // 7. Query: path from a point on quad A to a point on quad B.
    //    The two quads share no edge, so the path MUST use the off-mesh link.
    // ---------------------------------------------------------------------
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    const start_in = [3]f32{ 2.0, 0.0, 5.0 }; // on quad A
    const end_in = [3]f32{ 20.0, 0.0, 5.0 }; // on quad B

    var start_ref: nav.detour.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&start_in, &ext, &filter, &start_ref, &start_pos);

    var end_ref: nav.detour.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_in, &ext, &filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("ERROR: start/end poly not found\n", .{});
        return error.PolyNotFound;
    }

    var path: [256]nav.detour.PolyRef = undefined;
    var path_count: usize = 0;
    _ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
    std.debug.print("path: {d} polys\n", .{path_count});

    if (path_count == 0 or path[path_count - 1] != end_ref) {
        std.debug.print("ERROR: no complete path A->B (off-mesh link not traversed)\n", .{});
        return error.NoPath;
    }

    // ---------------------------------------------------------------------
    // 8. Straight path: a waypoint flagged STRAIGHTPATH_OFFMESH_CONNECTION marks
    //    the moment the agent steps onto the link (where it would jump).
    // ---------------------------------------------------------------------
    var straight: [256 * 3]f32 = undefined;
    var straight_flags: [256]u8 = undefined;
    var straight_refs: [256]nav.detour.PolyRef = undefined;
    var straight_count: usize = 0;
    _ = try query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &straight, &straight_flags, &straight_refs, &straight_count, 0);

    std.debug.print("straight path: {d} waypoints\n", .{straight_count});
    var used_offmesh = false;
    for (0..straight_count) |i| {
        const is_off = (straight_flags[i] & nav.detour.STRAIGHTPATH_OFFMESH_CONNECTION) != 0;
        if (is_off) used_offmesh = true;
        std.debug.print("  {d}: ({d:.2}, {d:.2}, {d:.2}){s}\n", .{
            i, straight[i * 3 + 0], straight[i * 3 + 1], straight[i * 3 + 2],
            if (is_off) "  <- OFF-MESH CONNECTION (jump here)" else "",
        });
    }

    std.debug.print("\n", .{});
    if (used_offmesh) {
        std.debug.print("SUCCESS: path crossed the gap via the off-mesh connection.\n", .{});
    } else {
        std.debug.print("ERROR: path reached B but no off-mesh waypoint was flagged.\n", .{});
        return error.OffMeshNotUsed;
    }

    std.debug.print("done.\n", .{});
}
