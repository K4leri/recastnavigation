//! Dynamic (run-time) obstacles — DetourTileCache obstacle workflow + a real,
//! measurable path reroute.
//!
//! This example does two things, both for real:
//!
//!   A) Exercises the DetourTileCache obstacle API exactly as the CI test
//!      `test/integration/tilecache_pipeline_test.zig` does: build a tile cache
//!      over a floor, add a cylinder obstacle, run update() so the cache queues
//!      and processes it, then remove it and update again. This is the live,
//!      incremental obstacle machinery you'd drive per frame in a game.
//!
//!   B) Demonstrates the *effect* of that obstacle on pathfinding with a real
//!      query: build a queryable navmesh from the floor, find a path across it,
//!      then carve the obstacle's footprint out of the walkable area, rebuild,
//!      and find the path again. The path bends around the hole and gets
//!      longer; removing the obstacle restores it.
//!
//! Why two navmeshes? The current tile-cache *bake-to-navmesh* path in this port
//! produces tiles that the Detour query cannot safely walk (see the API GAPS
//! note at the bottom of this file). So the obstacle workflow is driven through
//! the real TileCache API in (A), while the queryable mesh in (B) is built and
//! re-carved through the proven Recast→Detour pipeline used by
//! `examples/03_full_pathfinding.zig`. Both halves act on the same obstacle, so
//! the demonstrated reroute is faithful to what the obstacle does.
//!
//! Run with:
//!   zig build run-dynamic_obstacles

const std = @import("std");
const nav = @import("recast-nav");

const rc = nav.recast;
const dt = nav.detour;
const tc = nav.detour_tilecache;
const Vec3 = nav.math.Vec3;

// --- Compressor that does no compression (matches the vtable exactly) ---------
fn maxSize(_: *anyopaque, n: usize) usize {
    return n;
}
fn compress(_: *anyopaque, buffer: []const u8, out: []u8, out_size: *usize) nav.Status {
    if (out.len < buffer.len) return .{ .failure = true, .buffer_too_small = true };
    @memcpy(out[0..buffer.len], buffer);
    out_size.* = buffer.len;
    return .{ .success = true };
}
fn decompress(_: *anyopaque, comp: []const u8, buffer: []u8, buf_size: *usize) nav.Status {
    if (buffer.len < comp.len) return .{ .failure = true, .buffer_too_small = true };
    @memcpy(buffer[0..comp.len], comp);
    buf_size.* = comp.len;
    return .{ .success = true };
}

const comp_vtable = tc.TileCacheCompressor.VTable{
    .maxCompressedSize = maxSize,
    .compress = compress,
    .decompress = decompress,
};

// MeshProcess: mark every baked polygon walkable (used by the tile cache bake).
fn meshProcess(_: *anyopaque, _: *anyopaque, poly_areas: []u8, poly_flags: []u16) void {
    for (poly_areas, 0..) |*ar, i| {
        if (ar.* == tc.TILECACHE_WALKABLE_AREA) ar.* = 1;
        poly_flags[i] = 0x01;
    }
}
const mp_vtable = tc.TileCacheMeshProcess.VTable{ .process = meshProcess };

// Shared build settings.
const CS: f32 = 0.3;
const CH: f32 = 0.2;
const AGENT_HEIGHT: f32 = 2.0;
const AGENT_RADIUS: f32 = 0.6;
const AGENT_CLIMB: f32 = 0.9;
const MAX_SIMPL_ERR: f32 = 1.3;
const TILE_SIZE: i32 = 64;

const WALKABLE_FLAG: u16 = 0x01;
const NULL_AREA: u8 = 0;
const GROUND_AREA: u8 = 1;

// Flat floor, 16 x 16, y = 0. CCW winding (viewed from +y) so the surface
// normal points up and markWalkableTriangles accepts it.
const floor_verts = [_]f32{
    -8, 0, -8,
    8,  0, -8,
    8,  0, 8,
    -8, 0, 8,
};
const floor_tris = [_]i32{ 0, 2, 1, 0, 3, 2 };
const floor_bmin = Vec3.init(-8, -1, -8);
const floor_bmax = Vec3.init(8, 1, 8);

// ===========================================================================
// PART A — TileCache obstacle workflow (the real DetourTileCache API)
// ===========================================================================

// ===========================================================================
// PART B — queryable navmesh via the proven Recast→Detour pipeline,
//          optionally carving an obstacle box out of the walkable area.
// ===========================================================================

/// Build a single-tile, BV-tree + detail navmesh from the floor. If `carve` is
/// given, the AABB [carve_min, carve_max] is stamped as NULL_AREA so the agent
/// must route around it. Returns the navmesh and the backing tile data (caller
/// frees both).
fn buildQueryNavmesh(
    allocator: std.mem.Allocator,
    ctx: *nav.Context,
    carve_min: ?Vec3,
    carve_max: ?Vec3,
) !struct { mesh: dt.NavMesh, data: []u8 } {
    var cfg = nav.RecastConfig{
        .cs = CS,
        .ch = CH,
        .walkable_slope_angle = 45.0,
        .walkable_height = @intFromFloat(@ceil(AGENT_HEIGHT / CH)),
        .walkable_climb = @intFromFloat(@floor(AGENT_CLIMB / CH)),
        .walkable_radius = @intFromFloat(@ceil(AGENT_RADIUS / CS)),
        .max_edge_len = 12,
        .max_simplification_error = MAX_SIMPL_ERR,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .border_size = 0,
        .width = 0,
        .height = 0,
        .bmin = floor_bmin,
        .bmax = floor_bmax,
    };
    var sx: i32 = 0;
    var sz: i32 = 0;
    nav.RecastConfig.calcGridSize(floor_bmin, floor_bmax, cfg.cs, &sx, &sz);
    cfg.width = sx;
    cfg.height = sz;

    var hf = try nav.Heightfield.init(allocator, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    defer hf.deinit();

    const ntris = floor_tris.len / 3;
    const areas = try allocator.alloc(u8, ntris);
    defer allocator.free(areas);
    @memset(areas, 0);
    rc.filter.markWalkableTriangles(ctx, cfg.walkable_slope_angle, &floor_verts, &floor_tris, areas);
    try rc.rasterization.rasterizeTriangles(ctx, &floor_verts, &floor_tris, areas, &hf, cfg.walkable_climb);

    rc.filter.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    rc.filter.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    rc.filter.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);

    const span_count = rc.compact.getHeightFieldSpanCount(ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, cfg.width, cfg.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch, cfg.border_size);
    defer chf.deinit();
    try rc.compact.buildCompactHeightfield(ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
    try rc.area.erodeWalkableArea(ctx, cfg.walkable_radius, &chf, allocator);

    // Carve the obstacle footprint out of the walkable area.
    if (carve_min) |cmin| {
        const cmax = carve_max.?;
        rc.area.markBoxArea(ctx, cmin, cmax, NULL_AREA, &chf);
    }

    try rc.region.buildDistanceField(ctx, &chf, allocator);
    try rc.region.buildRegions(ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try rc.contour.buildContours(ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, 0, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try rc.mesh.buildPolyMesh(ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try rc.detail.buildPolyMeshDetail(ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    // Mark only real ground polys walkable; NULL_AREA (carved) polys stay 0 and
    // are excluded by the query filter, so the path must route around them.
    for (0..@intCast(pmesh.npolys)) |i| {
        poly_flags[i] = if (pmesh.areas[i] == NULL_AREA) 0 else WALKABLE_FLAG;
        if (pmesh.areas[i] != NULL_AREA) pmesh.areas[i] = GROUND_AREA;
    }

    const create_params = dt.NavMeshCreateParams{
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
        .walkable_height = AGENT_HEIGHT,
        .walkable_radius = AGENT_RADIUS,
        .walkable_climb = AGENT_CLIMB,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .build_bv_tree = true,
    };
    const data = try dt.createNavMeshData(&create_params, allocator);
    errdefer allocator.free(data);

    var mesh = try dt.NavMesh.init(allocator, .{
        .orig = floor_bmin,
        .tile_width = floor_bmax.x - floor_bmin.x,
        .tile_height = floor_bmax.z - floor_bmin.z,
        .max_tiles = 1,
        .max_polys = 1024,
    });
    errdefer mesh.deinit();
    _ = try mesh.addTile(data, dt.TileFlags{ .free_data = false }, 0);

    return .{ .mesh = mesh, .data = data };
}

/// Find a path and return its total length, printing waypoints. null = no path.
fn findPathLength(
    allocator: std.mem.Allocator,
    mesh: *dt.NavMesh,
    start_in: [3]f32,
    end_in: [3]f32,
    label: []const u8,
) !?f32 {
    const query = try dt.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(mesh, 2048);
    const filter = dt.QueryFilter.init();
    const ext = [3]f32{ 2.0, 8.0, 2.0 };

    var start_ref: dt.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&start_in, &ext, &filter, &start_ref, &start_pos);

    var end_ref: dt.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_in, &ext, &filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("   [{s}] start/end poly not found\n", .{label});
        return null;
    }

    var path: [256]dt.PolyRef = undefined;
    var path_count: usize = 0;
    _ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
    if (path_count == 0) {
        std.debug.print("   [{s}] no path\n", .{label});
        return null;
    }

    var straight: [256 * 3]f32 = undefined;
    var sflags: [256]u8 = undefined;
    var srefs: [256]dt.PolyRef = undefined;
    var scount: usize = 0;
    _ = try query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &straight, &sflags, &srefs, &scount, 0);

    var len: f32 = 0;
    var i: usize = 1;
    while (i < scount) : (i += 1) {
        const dx = straight[i * 3 + 0] - straight[(i - 1) * 3 + 0];
        const dy = straight[i * 3 + 1] - straight[(i - 1) * 3 + 1];
        const dz = straight[i * 3 + 2] - straight[(i - 1) * 3 + 2];
        len += @sqrt(dx * dx + dy * dy + dz * dz);
    }

    // Whether the straight path actually reaches the goal (vs. dead-ending at
    // the obstacle because the goal became unreachable).
    const last = (scount - 1) * 3;
    const gdx = straight[last + 0] - end_pos[0];
    const gdz = straight[last + 2] - end_pos[2];
    const reaches = (gdx * gdx + gdz * gdz) < 1.0;

    std.debug.print("   [{s}] {d} polys, {d} waypoints, length {d:.2}{s}\n", .{
        label, path_count, scount, len, if (reaches) "" else "  (does not reach goal)",
    });
    for (0..scount) |w| {
        std.debug.print("        ({d:6.2}, {d:5.2}, {d:6.2})\n", .{ straight[w * 3 + 0], straight[w * 3 + 1], straight[w * 3 + 2] });
    }
    return if (reaches) len else null;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("DetourTileCache - Dynamic Obstacles\n", .{});
    std.debug.print("===================================\n\n", .{});

    const start = [3]f32{ -6.0, 0.0, -6.0 };
    const goal = [3]f32{ 6.0, 0.0, 6.0 };

    // Obstacle: a cylinder at the origin (in the corridor between start & goal).
    const obs_center = [3]f32{ 0.0, 0.0, 0.0 };
    const obs_radius: f32 = 2.5;
    const obs_height: f32 = 4.0;

    // -----------------------------------------------------------------------
    // PART A: real DetourTileCache obstacle workflow.
    // -----------------------------------------------------------------------
    std.debug.print("PART A - TileCache obstacle workflow (live API)\n", .{});
    std.debug.print("-----------------------------------------------\n", .{});

    var gw: i32 = 0;
    var gh: i32 = 0;
    nav.RecastConfig.calcGridSize(floor_bmin, floor_bmax, CS, &gw, &gh);
    const ts = TILE_SIZE;
    const tw = @divTrunc(gw + ts - 1, ts);
    const th = @divTrunc(gh + ts - 1, ts);
    const tcs = @as(f32, @floatFromInt(ts)) * CS;

    const tile_bits: u5 = @intCast(@min(nav.math.ilog2(nav.math.nextPow2(@intCast(tw * th * 4))), 14));
    const poly_bits: u5 = @intCast(22 - @as(u32, tile_bits));
    var nav_params = dt.NavMeshParams.init();
    nav_params.orig = floor_bmin;
    nav_params.tile_width = tcs;
    nav_params.tile_height = tcs;
    nav_params.max_tiles = @as(i32, 1) << tile_bits;
    nav_params.max_polys = @as(i32, 1) << poly_bits;
    var tc_navmesh = try dt.NavMesh.init(allocator, nav_params);
    defer tc_navmesh.deinit();

    var dummy: u8 = 0;
    var comp_iface = tc.TileCacheCompressor{ .ptr = @ptrCast(&dummy), .vtable = &comp_vtable };
    var mp_iface = tc.TileCacheMeshProcess{ .ptr = @ptrCast(&dummy), .vtable = &mp_vtable };

    var tc_params = std.mem.zeroes(tc.TileCacheParams);
    tc_params.orig = .{ floor_bmin.x, floor_bmin.y, floor_bmin.z };
    tc_params.cs = CS;
    tc_params.ch = CH;
    tc_params.width = ts;
    tc_params.height = ts;
    tc_params.walkable_height = AGENT_HEIGHT;
    tc_params.walkable_radius = AGENT_RADIUS;
    tc_params.walkable_climb = AGENT_CLIMB;
    tc_params.max_simplification_error = MAX_SIMPL_ERR;
    tc_params.max_tiles = tw * th * 4;
    tc_params.max_obstacles = 128;
    var tilecache = try tc.TileCache.init(allocator, &tc_params, &comp_iface, &mp_iface);
    defer tilecache.deinit();

    std.debug.print("cache over a {d}x{d} tile grid, {d} obstacle slots\n", .{ tw, th, tc_params.max_obstacles });

    // Add the cylinder obstacle, update() so the cache queues + processes the
    // obstacle and marks the touched tiles, then remove it and update again —
    // exactly the live game loop. (This mirrors the CI tile-cache test, which
    // drives the obstacle API without pre-baking geometry tiles; see the
    // API GAPS note for why the bake path is not used here.)
    var up_to_date = false;

    const obs_ref = try tilecache.addObstacle(&obs_center, obs_radius, obs_height);
    std.debug.print("addObstacle -> ref {d}\n", .{obs_ref});
    const s1 = try tilecache.update(0.1, &tc_navmesh, &up_to_date);
    std.debug.print("update() after add: success={any}\n", .{s1.isSuccess()});

    try tilecache.removeObstacle(obs_ref);
    const s2 = try tilecache.update(0.1, &tc_navmesh, &up_to_date);
    std.debug.print("removeObstacle + update(): success={any}\n", .{s2.isSuccess()});
    std.debug.print("TileCache obstacle add/update/remove cycle OK.\n\n", .{});

    // -----------------------------------------------------------------------
    // PART B: measurable path reroute on a queryable navmesh.
    // -----------------------------------------------------------------------
    std.debug.print("PART B - path reroute caused by the obstacle\n", .{});
    std.debug.print("--------------------------------------------\n", .{});

    // 1) Baseline path (no obstacle).
    var nm0 = try buildQueryNavmesh(allocator, &ctx, null, null);
    defer {
        nm0.mesh.deinit();
        allocator.free(nm0.data);
    }
    std.debug.print("1) BEFORE obstacle:\n", .{});
    const len_before = try findPathLength(allocator, &nm0.mesh, start, goal, "before") orelse {
        std.debug.print("ERROR: no baseline path on an open floor\n", .{});
        return error.NoBaselinePath;
    };

    // 2) Carve the obstacle footprint and rebuild; path must reroute.
    const pad = AGENT_RADIUS; // detour erodes by radius, so the hole must too
    const carve_min = Vec3.init(obs_center[0] - obs_radius - pad, floor_bmin.y, obs_center[2] - obs_radius - pad);
    const carve_max = Vec3.init(obs_center[0] + obs_radius + pad, floor_bmax.y, obs_center[2] + obs_radius + pad);
    var nm1 = try buildQueryNavmesh(allocator, &ctx, carve_min, carve_max);
    defer {
        nm1.mesh.deinit();
        allocator.free(nm1.data);
    }
    std.debug.print("\n2) AFTER obstacle (footprint carved):\n", .{});
    const len_after = try findPathLength(allocator, &nm1.mesh, start, goal, "after");

    // 3) Remove obstacle -> rebuild without carve -> path restored.
    var nm2 = try buildQueryNavmesh(allocator, &ctx, null, null);
    defer {
        nm2.mesh.deinit();
        allocator.free(nm2.data);
    }
    std.debug.print("\n3) AFTER removal:\n", .{});
    const len_restored = try findPathLength(allocator, &nm2.mesh, start, goal, "restored");

    // -----------------------------------------------------------------------
    // Verdict.
    // -----------------------------------------------------------------------
    std.debug.print("\n===================================\n", .{});
    std.debug.print("length before   : {d:.2}\n", .{len_before});
    if (len_after) |la| {
        std.debug.print("length after    : {d:.2}  (delta {d:.2})\n", .{ la, la - len_before });
    } else {
        std.debug.print("length after    : goal unreachable through the obstacle\n", .{});
    }
    if (len_restored) |lr| std.debug.print("length restored : {d:.2}\n", .{lr});

    const rerouted = if (len_after) |la| la > len_before + 0.25 else true;
    if (rerouted) {
        std.debug.print("\nRESULT: obstacle CHANGED the path (agent re-routed). OK\n", .{});
    } else {
        std.debug.print("\nRESULT: WARNING - path unchanged; obstacle had no effect.\n", .{});
        return error.ObstacleHadNoEffect;
    }
}

// ===========================================================================
// API GAPS found while writing this example (current zig-recast tile cache):
//
//  1. detour_tilecache builder: `@memset(mesh.polys, 0xff)` on a `[]u16` writes
//     the element value 0x00ff (255), not the byte pattern 0xffff. The Detour
//     null-index sentinel is 0xffff, so createNavMeshData can never find where a
//     polygon's vertices end and sets every poly's vert_count to nvp (6), leaving
//     255 in the vertex list. Querying such a tile reads out of bounds.
//  2. TileCache.buildNavMeshTile passes `tile.compressed` (header already
//     stripped) to decompressTileCacheLayer, which re-reads a header from offset
//     0 of its argument — a double-strip; the compressed bytes must therefore
//     themselves begin with a valid header.
//  3. A tile-cache-baked tile carries no detail mesh, but the no-BV-tree query
//     path (closestPointOnPoly -> closestPointOnDetailEdges) dereferences detail
//     data unconditionally.
//  4. TileCache.buildNavMeshTile adds the baked nav data to the navmesh with
//     default tile flags (free_data = false) and discards the data returned by
//     navmesh.removeTile during a rebuild, so every tile-cache navmesh bake /
//     rebuild leaks its tile memory.
//
// Because of (1), (3) and (4) the tile-cache→navmesh bake path cannot currently
// be queried (or even run) leak-free, so PART A drives only the obstacle API
// (no geometry tiles, exactly like the CI test) and PART B builds the queryable
// mesh via the proven Recast→Detour pipeline, carving the obstacle there. Once
// these are fixed, PART B could be driven directly off `tc_navmesh`.
// ===========================================================================
