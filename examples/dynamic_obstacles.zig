//! Dynamic (run-time) obstacles via DetourTileCache.
//!
//! Bake a navmesh through the tile cache, find a path across it, drop a cylinder
//! obstacle on the straight line between the endpoints, let the tile cache rebuild
//! the affected tile, and find the path again — it now bends around the obstacle
//! and gets longer. Remove the obstacle, rebuild, and the path snaps back. This is
//! the live, incremental obstacle machinery you'd drive per frame in a game.
//!
//! Run with:
//!   zig build run-dynamic_obstacles

const std = @import("std");
const nav = @import("recast-nav");

const rc = nav.recast;
const dt = nav.detour;
const tc = nav.detour_tilecache;
const Vec3 = nav.math.Vec3;

// --- No-op compressor (matches the vtable exactly) ---------------------------
fn maxSize(_: *anyopaque, n: usize) usize {
    return n;
}
fn compress(_: *anyopaque, buffer: []const u8, out: []u8, out_size: *usize) nav.Status {
    @memcpy(out[0..buffer.len], buffer);
    out_size.* = buffer.len;
    return .{ .success = true };
}
fn decompress(_: *anyopaque, comp: []const u8, buffer: []u8, buf_size: *usize) nav.Status {
    @memcpy(buffer[0..comp.len], comp);
    buf_size.* = comp.len;
    return .{ .success = true };
}
const comp_vtable = tc.TileCacheCompressor.VTable{
    .maxCompressedSize = maxSize,
    .compress = compress,
    .decompress = decompress,
};

// MeshProcess: mark every baked polygon walkable so the default QueryFilter
// accepts it (tile-cache polys are flag 0 otherwise).
fn meshProcess(_: *anyopaque, _: *anyopaque, poly_areas: []u8, poly_flags: []u16) void {
    for (poly_areas, poly_flags) |*a, *f| {
        f.* = if (a.* != 0) 0x01 else 0;
    }
}
const mp_vtable = tc.TileCacheMeshProcess.VTable{ .process = meshProcess };

const CS: f32 = 0.3;
const CH: f32 = 0.2;
const WALKABLE_HEIGHT: i32 = 10; // 2.0 / CH
const WALKABLE_CLIMB: i32 = 4; // 0.9 / CH
const WALKABLE_RADIUS: i32 = 2; // 0.6 / CS
const TILE_SIZE: i32 = 64;
const BORDER: i32 = WALKABLE_RADIUS + 3;

/// Find a path a -> b and return the straight-path length, or 0 if no path.
fn routeLen(query: *dt.NavMeshQuery, filter: *const dt.QueryFilter, a: [3]f32, b: [3]f32) !f32 {
    const ext = [3]f32{ 4, 4, 4 };
    var ar: dt.PolyRef = 0;
    var br: dt.PolyRef = 0;
    var ap: [3]f32 = undefined;
    var bp: [3]f32 = undefined;
    _ = try query.findNearestPoly(&a, &ext, filter, &ar, &ap);
    _ = try query.findNearestPoly(&b, &ext, filter, &br, &bp);
    if (ar == 0 or br == 0) return 0;

    var path: [256]dt.PolyRef = undefined;
    var npath: usize = 0;
    _ = try query.findPath(ar, br, &ap, &bp, filter, &path, &npath);
    if (npath == 0) return 0;

    var straight: [256 * 3]f32 = undefined;
    var sflags: [256]u8 = undefined;
    var srefs: [256]dt.PolyRef = undefined;
    var ns: usize = 0;
    _ = try query.findStraightPath(&ap, &bp, path[0..npath], &straight, &sflags, &srefs, &ns, 0);

    var len: f32 = 0;
    var i: usize = 1;
    while (i < ns) : (i += 1) {
        const dx = straight[i * 3 + 0] - straight[(i - 1) * 3 + 0];
        const dz = straight[i * 3 + 2] - straight[(i - 1) * 3 + 2];
        len += @sqrt(dx * dx + dz * dz);
    }
    return len;
}

/// Run the tile cache's update() until it reports the work queue is drained.
fn drain(tilecache: *tc.TileCache, navmesh: *dt.NavMesh) !void {
    var done = false;
    var guard: usize = 0;
    while (!done and guard < 64) : (guard += 1) {
        _ = try tilecache.update(0.05, navmesh, &done);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("Dynamic obstacles (DetourTileCache)\n", .{});
    std.debug.print("===================================\n\n", .{});

    const tcs: f32 = @as(f32, @floatFromInt(TILE_SIZE)) * CS; // tile size in world units
    const exp: f32 = @as(f32, @floatFromInt(BORDER)) * CS;
    const hbmin = Vec3.init(-exp, -1.0, -exp);
    const hbmax = Vec3.init(tcs + exp, 1.0, tcs + exp);
    const hf_w: i32 = TILE_SIZE + BORDER * 2;

    // --- Build a heightfield layer set from a flat floor [0, tcs] x [0, tcs] ---
    var hf = try nav.Heightfield.init(allocator, hf_w, hf_w, hbmin, hbmax, CS, CH);
    defer hf.deinit();

    const verts = [_]f32{
        hbmin.x, 0, hbmin.z,
        hbmax.x, 0, hbmin.z,
        hbmax.x, 0, hbmax.z,
        hbmin.x, 0, hbmax.z,
    };
    const indices = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 1, 1 };
    try rc.rasterization.rasterizeTriangles(&ctx, &verts, &indices, &areas, &hf, WALKABLE_CLIMB);
    rc.filter.filterLowHangingWalkableObstacles(&ctx, WALKABLE_CLIMB, &hf);
    rc.filter.filterLedgeSpans(&ctx, WALKABLE_HEIGHT, WALKABLE_CLIMB, &hf);
    rc.filter.filterWalkableLowHeightSpans(&ctx, WALKABLE_HEIGHT, &hf);

    const span_count = rc.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, hf_w, hf_w, @intCast(span_count), WALKABLE_HEIGHT, WALKABLE_CLIMB, hbmin, hbmax, CS, CH, BORDER);
    defer chf.deinit();
    try rc.compact.buildCompactHeightfield(&ctx, WALKABLE_HEIGHT, WALKABLE_CLIMB, &hf, &chf);
    try rc.area.erodeWalkableArea(&ctx, WALKABLE_RADIUS, &chf, allocator);

    var lset = rc.HeightfieldLayerSet.init(allocator);
    defer lset.deinit();
    try rc.layers.buildHeightfieldLayers(&ctx, &chf, BORDER, WALKABLE_HEIGHT, &lset, allocator);

    // --- Tile cache + navmesh ---------------------------------------------------
    const tc_params = tc.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = CS,
        .ch = CH,
        .width = TILE_SIZE,
        .height = TILE_SIZE,
        .walkable_height = @as(f32, @floatFromInt(WALKABLE_HEIGHT)) * CH,
        .walkable_radius = @as(f32, @floatFromInt(WALKABLE_RADIUS)) * CS,
        .walkable_climb = @as(f32, @floatFromInt(WALKABLE_CLIMB)) * CH,
        .max_simplification_error = 1.3,
        .max_tiles = 8,
        .max_obstacles = 16,
    };

    var comp = tc.TileCacheCompressor{ .ptr = undefined, .vtable = &comp_vtable };
    var mp = tc.TileCacheMeshProcess{ .ptr = undefined, .vtable = &mp_vtable };
    var tilecache = try tc.TileCache.init(allocator, &tc_params, &comp, &mp);
    defer tilecache.deinit();

    var navmesh = try dt.NavMesh.init(allocator, .{
        .orig = Vec3.init(0, 0, 0),
        .tile_width = tcs,
        .tile_height = tcs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 4096,
    });
    defer navmesh.deinit();

    const nlayers: usize = @min(lset.layerCount(), 255);
    for (0..nlayers) |i| {
        const layer = &lset.layers[i];
        var header = std.mem.zeroes(tc.TileCacheLayerHeader);
        header.magic = tc.builder.TILECACHE_MAGIC;
        header.version = tc.builder.TILECACHE_VERSION;
        header.tx = 0;
        header.ty = 0;
        header.tlayer = @intCast(i);
        header.bmin = layer.bmin.toArray();
        header.bmax = layer.bmax.toArray();
        header.hmin = @intCast(layer.hmin);
        header.hmax = @intCast(layer.hmax);
        header.width = @intCast(layer.width);
        header.height = @intCast(layer.height);
        header.minx = @intCast(layer.minx);
        header.maxx = @intCast(layer.maxx);
        header.miny = @intCast(layer.miny);
        header.maxy = @intCast(layer.maxy);

        const data = try tc.builder.buildTileCacheLayer(&comp, &header, layer.heights, layer.areas, layer.cons, allocator);
        _ = tilecache.addTile(data, .{ .free_data = true }) catch |e| {
            allocator.free(data);
            return e;
        };
    }

    _ = try tilecache.buildNavMeshTilesAt(0, 0, &navmesh);

    const query = try dt.NavMeshQuery.init(allocator); // returns *NavMeshQuery
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);
    const filter = dt.QueryFilter.init();

    // Diagonal route; the obstacle sits on the straight line between the ends.
    const start = [3]f32{ tcs * 0.2, 0, tcs * 0.2 };
    const goal = [3]f32{ tcs * 0.8, 0, tcs * 0.8 };
    const center = [3]f32{ tcs * 0.5, 0, tcs * 0.5 };

    const base_len = try routeLen(query, &filter, start, goal);
    std.debug.print("baseline path length:      {d:.2}\n", .{base_len});

    // --- Drop an obstacle on the route -----------------------------------------
    const ob = try tilecache.addObstacle(&center, 2.5, 2.0);
    try drain(&tilecache, &navmesh);
    const blocked_len = try routeLen(query, &filter, start, goal);
    std.debug.print("with obstacle:             {d:.2}  (+{d:.2})\n", .{ blocked_len, blocked_len - base_len });

    // --- Remove it; the path snaps back ----------------------------------------
    try tilecache.removeObstacle(ob);
    try drain(&tilecache, &navmesh);
    const restored_len = try routeLen(query, &filter, start, goal);
    std.debug.print("obstacle removed:          {d:.2}\n", .{restored_len});

    std.debug.print("\ndone.\n", .{});
}
