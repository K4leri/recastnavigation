//! Query-focused pathfinding demo. Bakes a small navmesh from raw triangles
//! (the same pipeline as `03_full_pathfinding.zig` and the integration tests)
//! and then exercises SEVERAL Detour query functions on it:
//!   findNearestPoly, findPath, findStraightPath, raycast,
//!   findPolysAroundCircle, findDistanceToWall.
//!
//! Run with:
//!   zig build run-pathfinding_demo
//!
//! The DebugAllocator doubles as a leak smoke-test: on deinit it panics if
//! anything was left unfreed.

const std = @import("std");
const nav = @import("recast-nav");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("Recast/Detour query demo\n", .{});
    std.debug.print("========================\n\n", .{});

    // ---------------------------------------------------------------------
    // 1. Input geometry: an L-shaped floor (flat f32 xyz, i32 tri indices)
    // ---------------------------------------------------------------------
    const verts = [_]f32{
        0,  0, 0, // 0
        20, 0, 0, // 1
        20, 0, 20, // 2
        0,  0, 20, // 3
        20, 0, 0, // 4
        30, 0, 0, // 5
        30, 0, 10, // 6
        20, 0, 10, // 7
    };
    const indices = [_]i32{
        0, 1, 2, 0, 2, 3, // main room
        4, 5, 6, 4, 6, 7, // extension
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
    @memset(areas, 1); // RC_WALKABLE_AREA

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

    std.debug.print("polymesh: {d} verts, {d} polys\n\n", .{ pmesh.nverts, pmesh.npolys });

    // ---------------------------------------------------------------------
    // 8. Detour navmesh data + tile
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

    // ---------------------------------------------------------------------
    // 9. Queries
    // ---------------------------------------------------------------------
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2.0, 4.0, 2.0 };

    // A couple of start/end pairs to demonstrate the queries.
    const pairs = [_]struct { start: [3]f32, end: [3]f32 }{
        .{ .start = .{ 2.0, 0.0, 2.0 }, .end = .{ 28.0, 0.0, 8.0 } }, // across into extension
        .{ .start = .{ 5.0, 0.0, 18.0 }, .end = .{ 18.0, 0.0, 3.0 } }, // diagonal within main room
    };

    for (pairs, 0..) |pair, pi| {
        std.debug.print("--- pair {d}: start ({d:.1},{d:.1},{d:.1}) -> end ({d:.1},{d:.1},{d:.1}) ---\n", .{
            pi,            pair.start[0], pair.start[1],
            pair.start[2], pair.end[0],   pair.end[1],
            pair.end[2],
        });

        // findNearestPoly for both endpoints
        var start_ref: nav.detour.PolyRef = 0;
        var start_pos: [3]f32 = undefined;
        _ = try query.findNearestPoly(&pair.start, &ext, &filter, &start_ref, &start_pos);

        var end_ref: nav.detour.PolyRef = 0;
        var end_pos: [3]f32 = undefined;
        _ = try query.findNearestPoly(&pair.end, &ext, &filter, &end_ref, &end_pos);

        std.debug.print("findNearestPoly: start_ref={d} end_ref={d}\n", .{ start_ref, end_ref });
        if (start_ref == 0 or end_ref == 0) {
            std.debug.print("  (an endpoint was off-mesh; skipping pair)\n\n", .{});
            continue;
        }

        // findPath (A* corridor of poly refs)
        var path: [256]nav.detour.PolyRef = undefined;
        var path_count: usize = 0;
        _ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
        std.debug.print("findPath: {d} polys\n", .{path_count});

        // findStraightPath (string-pulled waypoints)
        if (path_count > 0) {
            var straight: [256 * 3]f32 = undefined;
            var straight_flags: [256]u8 = undefined;
            var straight_refs: [256]nav.detour.PolyRef = undefined;
            var straight_count: usize = 0;
            _ = try query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &straight, &straight_flags, &straight_refs, &straight_count, 0);
            std.debug.print("findStraightPath: {d} waypoints\n", .{straight_count});
            for (0..straight_count) |i| {
                std.debug.print("  wp {d}: ({d:.2}, {d:.2}, {d:.2})\n", .{ i, straight[i * 3 + 0], straight[i * 3 + 1], straight[i * 3 + 2] });
            }
        }

        // raycast: straight-line walkability check from start toward end
        {
            var hit = nav.detour.RaycastHit.init(&path);
            _ = try query.raycast(start_ref, &start_pos, &end_pos, &filter, 0, &hit, 0);
            if (hit.t >= std.math.floatMax(f32)) {
                std.debug.print("raycast: clear line of sight (no wall hit), {d} polys crossed\n", .{hit.path_count});
            } else {
                std.debug.print("raycast: hit wall at t={d:.3}, normal=({d:.2},{d:.2},{d:.2})\n", .{
                    hit.t,             hit.hit_normal[0],
                    hit.hit_normal[1], hit.hit_normal[2],
                });
            }
        }

        // findPolysAroundCircle: all polys reachable within a radius of start
        {
            var around_ref: [64]nav.detour.PolyRef = undefined;
            var around_count: usize = 0;
            _ = try query.findPolysAroundCircle(start_ref, &start_pos, 10.0, &filter, &around_ref, null, null, &around_count);
            std.debug.print("findPolysAroundCircle (r=10): {d} polys reachable\n", .{around_count});
        }

        // findDistanceToWall: nearest navmesh boundary within max radius of start
        {
            var hit_dist: f32 = 0;
            var hit_pos: [3]f32 = undefined;
            var hit_normal: [3]f32 = undefined;
            _ = try query.findDistanceToWall(start_ref, &start_pos, 20.0, &filter, &hit_dist, &hit_pos, &hit_normal);
            std.debug.print("findDistanceToWall: {d:.3} units to nearest wall\n", .{hit_dist});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("done.\n", .{});
}
