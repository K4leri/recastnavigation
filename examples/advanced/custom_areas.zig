//! ADVANCED EXAMPLE: custom area types + per-area cost routing.
//!
//! What this demonstrates (REAL work, not a print stub):
//!   1. Build a navmesh from a flat floor.
//!   2. After building the compact heightfield, stamp a custom area id onto a
//!      sub-region with `nav.recast.area.markBoxArea` — a real grid mutation.
//!   3. Bake that area through contours -> polymesh -> detour tile, so the area
//!      id survives into the navmesh polygons.
//!   4. Run `findPath` twice with two `QueryFilter`s that differ only in the
//!      cost assigned to the custom area, and show the resulting paths differ:
//!      cheap custom area -> A* cuts straight through it; expensive custom area
//!      -> A* routes around it.
//!
//! The detour cost model is `dist * filter.area_cost[poly_area]` (see
//! src/detour/query.zig getCost), so raising the custom area's cost makes the
//! straight-line polys through it more expensive than the detour around them.
//!
//! Run with:
//!   zig build run-custom_areas

const std = @import("std");
const nav = @import("recast-nav");

// Standard walkable area id used by the rasterizer / template (RC_WALKABLE_AREA).
const AREA_GROUND: u8 = 1;
// A custom area id we invent. Must be < detour MAX_AREAS (64). This is the id we
// stamp onto a sub-region and then re-cost in the query filter.
const AREA_MUD: u8 = 9;

pub fn main() !void {
    // DebugAllocator (0.16 successor to GeneralPurposeAllocator): doubles as a
    // leak smoke-test.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("Custom area types + per-area cost routing\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // ---------------------------------------------------------------------
    // 1. Input geometry: a wide flat floor, 0..60 in X, 0..40 in Z.
    //    Big enough that A* has room to route around a marked band.
    // ---------------------------------------------------------------------
    const verts = [_]f32{
        0,  0, 0, // 0
        60, 0, 0, // 1
        60, 0, 40, // 2
        0,  0, 40, // 3
    };
    const indices = [_]i32{
        0, 1, 2,
        0, 2, 3,
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

    // ---------------------------------------------------------------------
    // 2. Build configuration
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
    // 3. Rasterize triangles into a heightfield
    // ---------------------------------------------------------------------
    var hf = try nav.Heightfield.init(allocator, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    defer hf.deinit();

    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, AREA_GROUND);

    try nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &indices, areas, &hf, cfg.walkable_climb);

    // ---------------------------------------------------------------------
    // 4. Filter walkable surfaces
    // ---------------------------------------------------------------------
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &hf);

    // ---------------------------------------------------------------------
    // 5. Compact heightfield + erode by agent radius
    // ---------------------------------------------------------------------
    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, cfg.width, cfg.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch, cfg.border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);

    // ---------------------------------------------------------------------
    // 5b. CUSTOM AREA: stamp a "mud" band onto the compact heightfield.
    //
    //   We mark an axis-aligned box covering most of the floor's width but
    //   leaving an open lane along the high-Z edge (z in 34..40). That way the
    //   direct start->end line crosses the band, but A* still has walkable
    //   default-cost polys to detour through when the band gets expensive.
    //
    //   markBoxArea(ctx, box_min, box_max, area_id, chf) mutates chf.areas in
    //   place — this is a real grid edit, verified below by the path change.
    // ---------------------------------------------------------------------
    const band_min = nav.Vec3.init(24.0, bmin.y - 1.0, 0.0);
    const band_max = nav.Vec3.init(36.0, bmax.y + 1.0, 32.0);
    nav.recast.area.markBoxArea(&ctx, band_min, band_max, AREA_MUD, &chf);

    // Count how many spans actually got the custom id (sanity that the mark hit).
    var mud_spans: usize = 0;
    for (chf.areas[0..@intCast(span_count)]) |a| {
        if (a == AREA_MUD) mud_spans += 1;
    }
    std.debug.print("marked custom MUD band: {d} compact spans got area id {d}\n", .{ mud_spans, AREA_MUD });

    // ---------------------------------------------------------------------
    // 6. Distance field + watershed regions
    // ---------------------------------------------------------------------
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, allocator);

    // ---------------------------------------------------------------------
    // 7. Contours -> polygon mesh -> detail mesh
    // ---------------------------------------------------------------------
    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, 0, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    // Report how the custom area survived into the polymesh.
    var mud_polys: usize = 0;
    for (pmesh.areas[0..@intCast(pmesh.npolys)]) |a| {
        if (a == AREA_MUD) mud_polys += 1;
    }
    std.debug.print("polymesh: {d} verts, {d} polys ({d} are MUD)\n", .{ pmesh.nverts, pmesh.npolys, mud_polys });

    // ---------------------------------------------------------------------
    // 8. Detour navmesh data + tile
    // ---------------------------------------------------------------------
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // all walkable

    const create_params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas, // carries our AREA_MUD ids into detour
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
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
        .max_polys = 1024,
    });
    defer navmesh.deinit();
    _ = try navmesh.addTile(navmesh_data, nav.detour.TileFlags{ .free_data = false }, 0);

    // ---------------------------------------------------------------------
    // 9. Query: same start/end, two filters that differ ONLY in MUD cost.
    // ---------------------------------------------------------------------
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const ext = [3]f32{ 2.0, 8.0, 2.0 };
    // Start lower-left, end lower-right: the straight line runs along low Z and
    // passes through the MUD band (x 24..36, z 0..32).
    const start_in = [3]f32{ 4.0, 0.0, 6.0 };
    const end_in = [3]f32{ 56.0, 0.0, 6.0 };

    // Locate endpoints with a default filter (cost is irrelevant for findNearestPoly).
    const locate_filter = nav.detour.QueryFilter.init();
    var start_ref: nav.detour.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&start_in, &ext, &locate_filter, &start_ref, &start_pos);
    var end_ref: nav.detour.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_in, &ext, &locate_filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("start/end poly not found\n", .{});
        return;
    }

    // ---- Run A* and report the path + whether it touches MUD ----------------
    const Result = struct {
        count: usize,
        touches_mud: bool,
        path: [256]nav.detour.PolyRef,
    };

    const runPath = struct {
        fn go(q: *nav.detour.NavMeshQuery, nm: *nav.detour.NavMesh, sref: nav.detour.PolyRef, eref: nav.detour.PolyRef, sp: *const [3]f32, ep: *const [3]f32, filter: *const nav.detour.QueryFilter) !Result {
            var r: Result = .{ .count = 0, .touches_mud = false, .path = undefined };
            _ = try q.findPath(sref, eref, sp, ep, filter, &r.path, &r.count);
            for (r.path[0..r.count]) |pref| {
                var tile: ?*const nav.detour.MeshTile = null;
                var poly: ?*const nav.detour.Poly = null;
                nm.getTileAndPolyByRefUnsafe(pref, &tile, &poly);
                if (poly.?.getArea() == AREA_MUD) {
                    r.touches_mud = true;
                    break;
                }
            }
            return r;
        }
    }.go;

    // Filter A: MUD is cheap (cost 1.0, same as ground) -> A* takes the short
    // straight line right through the band.
    var filter_cheap = nav.detour.QueryFilter.init();
    filter_cheap.setAreaCost(AREA_MUD, 1.0);
    const cheap = try runPath(query, &navmesh, start_ref, end_ref, &start_pos, &end_pos, &filter_cheap);

    // Filter B: MUD is very expensive (cost 50.0) -> A* detours around the band.
    var filter_avoid = nav.detour.QueryFilter.init();
    filter_avoid.setAreaCost(AREA_MUD, 50.0);
    const avoid = try runPath(query, &navmesh, start_ref, end_ref, &start_pos, &end_pos, &filter_avoid);

    std.debug.print("\nfindPath results (same start/end, MUD cost differs):\n", .{});
    std.debug.print("  cheap MUD (cost 1.0):  {d} polys, path crosses MUD = {}\n", .{ cheap.count, cheap.touches_mud });
    std.debug.print("  avoid MUD (cost 50.0): {d} polys, path crosses MUD = {}\n", .{ avoid.count, avoid.touches_mud });

    const path_changed = (cheap.count != avoid.count) or (cheap.touches_mud != avoid.touches_mud);
    std.debug.print("\n  -> area cost changed the route: {}\n", .{path_changed});
    if (cheap.touches_mud and !avoid.touches_mud) {
        std.debug.print("  -> cheap path goes THROUGH the custom area; expensive path AVOIDS it.\n", .{});
    }

    std.debug.print("\ndone.\n", .{});
}
