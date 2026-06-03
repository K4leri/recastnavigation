//! Advanced example: SLICED (incremental) pathfinding.
//!
//! Detour has no true hierarchical planner, but it ships the next best thing
//! for spreading a long A* search over several frames: the *sliced* query API
//!   initSlicedFindPath -> updateSlicedFindPath (N times) -> finalizeSlicedFindPath
//! This example bakes a real navmesh (same proven pipeline as
//! examples/03_full_pathfinding.zig and the integration tests), then:
//!
//!   PART 1  computes a path one-shot with findPath().
//!   PART 2  computes the SAME path incrementally with the sliced API, doing only
//!           a few A* iterations per "frame", and asserts the result is identical
//!           to the one-shot path.
//!   PART 3  expands the poly path into world-space waypoints via findStraightPath.
//!
//! All of it is real querying against a baked mesh — no stubs.
//!
//! Run:  zig build run-hierarchical_pathfinding

const std = @import("std");
const nav = @import("recast-nav");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("  ADVANCED EXAMPLE: Sliced (Incremental) Pathfinding\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // ---------------------------------------------------------------------
    // STEP 1: Input geometry — an S-shaped (serpentine) walkable strip.
    // A single flat quad collapses to ONE poly (A* has nothing to do); a
    // winding corridor forces the path through MANY polys, so the sliced
    // search actually performs several A* iterations spread over frames.
    //
    // The strip is built from 5 axis-aligned floor quads forming an S:
    //   bottom rail (left->right), riser up the right, middle rail
    //   (right->left), riser up the left, top rail (left->right).
    // ---------------------------------------------------------------------
    var verts_list: std.ArrayList(f32) = .empty;
    defer verts_list.deinit(allocator);
    var idx_list: std.ArrayList(i32) = .empty;
    defer idx_list.deinit(allocator);

    // Add an axis-aligned floor quad [x0,x1] x [z0,z1] at y=0 (two triangles).
    const Quad = struct {
        fn add(vl: *std.ArrayList(f32), il: *std.ArrayList(i32), a: std.mem.Allocator, x0: f32, z0: f32, x1: f32, z1: f32) !void {
            const base: i32 = @intCast(vl.items.len / 3);
            try vl.appendSlice(a, &.{ x0, 0, z0, x1, 0, z0, x1, 0, z1, x0, 0, z1 });
            try il.appendSlice(a, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
        }
    };

    const w: f32 = 8; // corridor width
    try Quad.add(&verts_list, &idx_list, allocator, 0, 0, 40, w); // bottom rail
    try Quad.add(&verts_list, &idx_list, allocator, 40 - w, 0, 40, 20); // right riser
    try Quad.add(&verts_list, &idx_list, allocator, 0, 20 - w, 40, 20); // middle rail
    try Quad.add(&verts_list, &idx_list, allocator, 0, 20 - w, w, 40); // left riser
    try Quad.add(&verts_list, &idx_list, allocator, 0, 40 - w, 40, 40); // top rail

    const verts = verts_list.items;
    const indices = idx_list.items;
    const tri_count = indices.len / 3;

    const bmin = nav.Vec3.init(0, 0, 0);
    const bmax = nav.Vec3.init(40, 1, 40);

    // ---------------------------------------------------------------------
    // STEP 2: Build configuration. Small cell size => more polys => the A*
    // search has to walk several nodes (so slicing is actually meaningful).
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
    std.debug.print("Step 1: grid {d} x {d} cells\n", .{ cfg.width, cfg.height });

    // ---------------------------------------------------------------------
    // STEP 3: Recast pipeline (rasterize -> filter -> compact -> regions ->
    // contours -> poly mesh -> detail mesh). Mirrors 03_full_pathfinding.zig.
    // ---------------------------------------------------------------------
    var hf = try nav.Heightfield.init(allocator, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    defer hf.deinit();

    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, 1); // RC_WALKABLE_AREA

    try nav.recast.rasterization.rasterizeTriangles(&ctx, verts, indices, areas, &hf, cfg.walkable_climb);

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, cfg.width, cfg.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch, cfg.border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);

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

    std.debug.print("Step 2: polymesh {d} verts, {d} polys\n", .{ pmesh.nverts, pmesh.npolys });

    // ---------------------------------------------------------------------
    // STEP 4: Detour navmesh data + tile.
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
        .max_polys = 1024,
    });
    defer navmesh.deinit();
    _ = try navmesh.addTile(navmesh_data, nav.detour.TileFlags{ .free_data = false }, 0);

    // ---------------------------------------------------------------------
    // STEP 5: Resolve start/end polys (corner-to-corner across the floor).
    // ---------------------------------------------------------------------
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    const start_in = [3]f32{ 2.0, 0.0, 2.0 };
    const end_in = [3]f32{ 38.0, 0.0, 38.0 };

    var start_ref: nav.detour.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&start_in, &ext, &filter, &start_ref, &start_pos);

    var end_ref: nav.detour.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_in, &ext, &filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("ERROR: start/end poly not found\n", .{});
        return error.NoStartOrEndPoly;
    }
    std.debug.print("Step 3: start_ref={d}  end_ref={d}\n\n", .{ start_ref, end_ref });

    // =====================================================================
    // PART 1: One-shot pathfinding (the baseline / ground truth).
    // =====================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 1: One-shot findPath (baseline)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    var oneshot_buf: [256]nav.detour.PolyRef = undefined;
    var oneshot_count: usize = 0;
    try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &oneshot_buf, &oneshot_count);
    const oneshot = oneshot_buf[0..oneshot_count];

    std.debug.print("  path length : {d} polygons\n", .{oneshot_count});
    std.debug.print("  reached goal: {}\n\n", .{oneshot_count > 0 and oneshot[oneshot_count - 1] == end_ref});

    // =====================================================================
    // PART 2: Sliced pathfinding — same A*, spread over several "frames".
    // =====================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 2: Sliced findPath (incremental, multi-frame)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // Only a handful of A* iterations per frame, to actually exercise slicing.
    const max_iter_per_frame: u32 = 4;

    const init_status = query.initSlicedFindPath(start_ref, end_ref, &start_pos, &end_pos, &filter, 0);
    if (init_status.failure) {
        std.debug.print("ERROR: initSlicedFindPath failed\n", .{});
        return error.SlicedInitFailed;
    }

    var frame: u32 = 0;
    var total_iters: u32 = 0;
    while (true) {
        frame += 1;
        var done_iters: u32 = 0;
        const status = query.updateSlicedFindPath(max_iter_per_frame, &done_iters);
        total_iters += done_iters;
        std.debug.print("  frame {d:>2}: +{d} iters (total {d})\n", .{ frame, done_iters, total_iters });

        if (status.success or status.failure) break;
        if (frame > 1000) {
            std.debug.print("ERROR: sliced search did not converge\n", .{});
            return error.SlicedNoConverge;
        }
    }

    var sliced_buf: [256]nav.detour.PolyRef = undefined;
    var sliced_count: usize = 0;
    const fin_status = query.finalizeSlicedFindPath(&sliced_buf, &sliced_count);
    if (fin_status.failure) {
        std.debug.print("ERROR: finalizeSlicedFindPath failed\n", .{});
        return error.SlicedFinalizeFailed;
    }
    const sliced = sliced_buf[0..sliced_count];

    std.debug.print("\n  path length : {d} polygons\n", .{sliced_count});
    std.debug.print("  frames      : {d}\n", .{frame});
    std.debug.print("  iters/frame : {d} (cap)\n", .{max_iter_per_frame});
    std.debug.print("  total iters : {d}\n\n", .{total_iters});

    // ------- Equivalence check: sliced path MUST equal the one-shot path. -------
    const identical = sliced_count == oneshot_count and
        std.mem.eql(nav.detour.PolyRef, sliced, oneshot);
    std.debug.print("  sliced == one-shot path: {}\n", .{identical});
    if (!identical) {
        std.debug.print("ERROR: sliced path diverged from one-shot path\n", .{});
        return error.SlicedPathMismatch;
    }
    std.debug.print("  -> incremental search reproduced the baseline exactly.\n\n", .{});

    // =====================================================================
    // PART 3: Expand the poly path into world-space waypoints.
    // =====================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 3: findStraightPath waypoints\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    if (sliced_count > 0) {
        var straight: [256 * 3]f32 = undefined;
        var sflags: [256]u8 = undefined;
        var srefs: [256]nav.detour.PolyRef = undefined;
        var scount: usize = 0;
        _ = try query.findStraightPath(&start_pos, &end_pos, sliced, &straight, &sflags, &srefs, &scount, 0);

        std.debug.print("  {d} waypoints:\n", .{scount});
        for (0..scount) |i| {
            std.debug.print("    {d}: ({d:.2}, {d:.2}, {d:.2})\n", .{
                i, straight[i * 3 + 0], straight[i * 3 + 1], straight[i * 3 + 2],
            });
        }
    }

    std.debug.print("\nDone. Sliced pathfinding demonstrated and verified against one-shot.\n", .{});
}
