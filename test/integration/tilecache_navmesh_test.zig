//! Regression test for the tile-cache -> navmesh bake path.
//!
//! This path was unexercised by the other tile-cache tests (they add obstacles but
//! never add layer tiles, so `buildNavMeshTile` never ran on real data), which hid
//! four bugs:
//!   1. `@memset(mesh.polys, 0xff)` on a []u16 wrote 0x00ff instead of the 0xffff
//!      null-index sentinel, so `createNavMeshData` mis-parsed every polygon.
//!   2. `buildNavMeshTile` fed the header-stripped `tile.compressed` to the
//!      decompressor, which re-reads a header from offset 0 (double strip).
//!   3. (claimed) a detail-mesh deref on tiles without a detail mesh — actually a
//!      downstream symptom of #1, since createNavMeshData synthesizes a per-poly
//!      detail mesh when none is supplied.
//!   4. tiles were added with free_data=false and the rebuild removeTile result was
//!      discarded, leaking the old tile every bake.
//!
//! The test bakes a flat floor through the tile cache, queries the resulting
//! navmesh, then runs an obstacle add/remove rebuild cycle. testing.allocator is a
//! leak-checking allocator, so a tile leak (#4) fails the test.

const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

const tc = nav.detour_tilecache;

// No-op compressor: the layer bytes pass through unchanged.
const StubCompressor = struct {
    fn maxCompressedSize(_: *anyopaque, buffer_size: usize) usize {
        return buffer_size;
    }
    fn compress(_: *anyopaque, buffer: []const u8, compressed: []u8, compressed_size: *usize) nav.detour.Status {
        @memcpy(compressed[0..buffer.len], buffer);
        compressed_size.* = buffer.len;
        return nav.detour.Status.ok();
    }
    fn decompress(_: *anyopaque, compressed: []const u8, buffer: []u8, buffer_size: *usize) nav.detour.Status {
        @memcpy(buffer[0..compressed.len], compressed);
        buffer_size.* = compressed.len;
        return nav.detour.Status.ok();
    }
    fn toInterface(self: *StubCompressor) tc.TileCacheCompressor {
        return .{ .ptr = self, .vtable = &.{
            .maxCompressedSize = maxCompressedSize,
            .compress = compress,
            .decompress = decompress,
        } };
    }
};

// Mesh process: mark every baked polygon walkable so the default QueryFilter
// accepts it (tile-cache polys get flags = 0 otherwise).
const MeshProcess = struct {
    fn process(_: *anyopaque, _: *anyopaque, poly_areas: []u8, poly_flags: []u16) void {
        for (poly_areas, poly_flags) |*a, *f| {
            if (a.* != 0) f.* = 0x01 else f.* = 0;
        }
    }
    fn toInterface(self: *MeshProcess) tc.TileCacheMeshProcess {
        return .{ .ptr = self, .vtable = &.{ .process = process } };
    }
};

test "TileCache -> NavMesh: bake a tile and query it (regression: poly memset + decompress + leak)" {
    const allocator = testing.allocator;

    var ctx = nav.Context.init(allocator);

    const cs: f32 = 0.3;
    const ch: f32 = 0.2;
    const walkable_height: i32 = 10; // 2.0 / ch
    const walkable_climb: i32 = 4; // 0.9 / ch
    const walkable_radius: i32 = 0; // keep the whole floor walkable
    const tile_size: i32 = 48;
    const border_size: i32 = walkable_radius + 3;

    // One tile (0,0). Heightfield spans the tile plus the border ring.
    const tcs: f32 = @as(f32, @floatFromInt(tile_size)) * cs; // 14.4 world units
    const exp: f32 = @as(f32, @floatFromInt(border_size)) * cs;
    const hbmin = nav.Vec3.init(-exp, -1.0, -exp);
    const hbmax = nav.Vec3.init(tcs + exp, 1.0, tcs + exp);
    const hf_w: i32 = tile_size + border_size * 2;

    var hf = try nav.Heightfield.init(allocator, hf_w, hf_w, hbmin, hbmax, cs, ch);
    defer hf.deinit();

    // Flat floor quad covering the whole (border-expanded) field at y = 0.
    const verts = [_]f32{
        hbmin.x, 0.0, hbmin.z,
        hbmax.x, 0.0, hbmin.z,
        hbmax.x, 0.0, hbmax.z,
        hbmin.x, 0.0, hbmax.z,
    };
    const indices = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 1, 1 };
    try nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &indices, &areas, &hf, walkable_climb);

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, hf_w, hf_w, @intCast(span_count), walkable_height, walkable_climb, hbmin, hbmax, cs, ch, border_size);
    defer chf.deinit();
    try nav.recast.compact.buildCompactHeightfield(&ctx, walkable_height, walkable_climb, &hf, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, walkable_radius, &chf, allocator);

    var lset = nav.recast.HeightfieldLayerSet.init(allocator);
    defer lset.deinit();
    try nav.recast.layers.buildHeightfieldLayers(&ctx, &chf, border_size, walkable_height, &lset, allocator);
    try testing.expect(lset.layerCount() > 0);

    // Tile cache + navmesh.
    const tc_params = tc.TileCacheParams{
        .orig = [3]f32{ 0, 0, 0 },
        .cs = cs,
        .ch = ch,
        .width = tile_size,
        .height = tile_size,
        .walkable_height = @as(f32, @floatFromInt(walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(walkable_climb)) * ch,
        .max_simplification_error = 1.3,
        .max_tiles = 8,
        .max_obstacles = 16,
    };

    var stub = StubCompressor{};
    var comp = stub.toInterface();
    var mproc = MeshProcess{};
    var mp = mproc.toInterface();

    var tilecache = try tc.TileCache.init(allocator, &tc_params, &comp, &mp);
    defer tilecache.deinit();

    var navmesh = try nav.detour.NavMesh.init(allocator, .{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = tcs,
        .tile_height = tcs,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 4096,
    });
    defer navmesh.deinit();

    // Build + add a compressed layer tile per layer at grid (0,0).
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
        // free_data=true: the tile cache owns `data` and frees it on deinit
        // (DT_COMPRESSEDTILE_FREE_DATA). On failure it isn't taken, so free it here.
        _ = tilecache.addTile(data, .{ .free_data = true }) catch |e| {
            allocator.free(data);
            return e;
        };
    }

    // Bake the tile-cache tile(s) into the navmesh (the previously-broken path).
    const bake = try tilecache.buildNavMeshTilesAt(0, 0, &navmesh);
    try testing.expect(bake.isSuccess());

    // The navmesh must now be queryable. findNearestPoly goes through
    // closestPointOnPoly -> the detail path, so a valid ref proves bugs #1/#2/#3
    // are fixed (no garbage poly parse, no OOB).
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const center = [3]f32{ tcs * 0.5, 0.0, tcs * 0.5 };
    const ext = [3]f32{ 4.0, 4.0, 4.0 };
    var ref: nav.detour.PolyRef = 0;
    var nearest: [3]f32 = undefined;
    _ = try query.findNearestPoly(&center, &ext, &filter, &ref, &nearest);
    try testing.expect(ref != 0);
    try testing.expect(std.math.isFinite(nearest[0]) and std.math.isFinite(nearest[1]) and std.math.isFinite(nearest[2]));

    // Obstacle add/remove rebuild cycle. Each update re-bakes the touched tile via
    // buildNavMeshTile (removeTile old + addTile new). With free_data=true on the
    // tile-cache tiles (#4 fix), the old tile is freed; testing.allocator fails the
    // test on any leak. The navmesh must stay queryable throughout.
    const ob_pos = [3]f32{ tcs * 0.5, 0.0, tcs * 0.5 };
    const ob = try tilecache.addObstacle(&ob_pos, 1.0, 2.0);
    try testing.expect(ob != 0);

    var up_to_date = false;
    var guard: usize = 0;
    while (!up_to_date and guard < 32) : (guard += 1) {
        const st = try tilecache.update(0.05, &navmesh, &up_to_date);
        try testing.expect(st.isSuccess());
    }

    try tilecache.removeObstacle(ob);
    up_to_date = false;
    guard = 0;
    while (!up_to_date and guard < 32) : (guard += 1) {
        const st = try tilecache.update(0.05, &navmesh, &up_to_date);
        try testing.expect(st.isSuccess());
    }

    // Still queryable after the rebuild cycle.
    var ref2: nav.detour.PolyRef = 0;
    var nearest2: [3]f32 = undefined;
    _ = try query.findNearestPoly(&center, &ext, &filter, &ref2, &nearest2);
    try testing.expect(ref2 != 0);
}
