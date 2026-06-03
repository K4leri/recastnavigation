//! Advanced example: STREAMING WORLD — dynamic tile add/remove on a tiled NavMesh.
//!
//! A large open world is partitioned into a grid of tiles. We never keep every
//! tile resident: only the tiles within a streaming radius of the agent are
//! present in the NavMesh. As the agent walks, distant tiles are removeTile'd
//! (their memory reclaimed) and newly-near tiles are addTile'd back. The
//! navmesh stays queryable across boundaries the whole time.
//!
//! The DebugAllocator leak check at the end is the real proof: every tile we
//! add we also free on removal, so add/remove churn must net to zero leaks.
//!
//! Generalizes the single-tile bake in examples/03_full_pathfinding.zig to a
//! grid, and uses the addTile/removeTile cycle pattern from
//! test/integration/removetile_link_leak_test.zig.
//!
//! Run with:
//!   zig build run-streaming_world --cache-dir .zig-cache-ex/stream --prefix .zigout-ex/stream

const std = @import("std");
const nav = @import("recast-nav");

const TILE_SIZE: f32 = 6.0; // world units per tile (20 cells @ cs=0.3)
const WORLD_TILES: i32 = 6; // 6x6 grid
const STREAM_RADIUS: i32 = 1; // keep tiles within +/-1 of the agent's tile

const TileKey = struct { tx: i32, tz: i32 };

const LoadedTile = struct {
    ref: nav.detour.TileRef,
    data: []u8, // owned; freed on unload (free_data=false → we own it)
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    std.debug.print("Streaming World — dynamic tile add/remove\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // -----------------------------------------------------------------
    // 1. Create a tiled NavMesh sized so many tiles fit, but we'll only
    //    ever hold a handful resident at once.
    // -----------------------------------------------------------------
    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = TILE_SIZE,
        .tile_height = TILE_SIZE,
        .max_tiles = 16, // resident cap — far below the 36-tile world
        .max_polys = 256,
    };
    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    defer navmesh.deinit();

    std.debug.print("World: {d}x{d} tiles, tile = {d:.1} units, resident cap = {d}\n", .{
        WORLD_TILES, WORLD_TILES, TILE_SIZE, nm_params.max_tiles,
    });
    std.debug.print("Stream radius: {d} (a {d}x{d} window follows the agent)\n\n", .{
        STREAM_RADIUS, 2 * STREAM_RADIUS + 1, 2 * STREAM_RADIUS + 1,
    });

    // Resident tiles, keyed by grid coord.
    var loaded = std.AutoHashMap(TileKey, LoadedTile).init(allocator);
    defer {
        // Tear down anything still resident at the end (defensive; the walk
        // below already unloads as it goes).
        var it = loaded.valueIterator();
        while (it.next()) |t| {
            _ = navmesh.removeTile(t.ref) catch {};
            allocator.free(t.data);
        }
        loaded.deinit();
    }

    var total_added: u32 = 0;
    var total_removed: u32 = 0;

    // -----------------------------------------------------------------
    // 2. Walk the agent diagonally across the world. At each step, stream
    //    the window of tiles around the agent in/out.
    // -----------------------------------------------------------------
    const flags = nav.detour.TileFlags{ .free_data = false }; // we own the data

    var step: i32 = 0;
    while (step < WORLD_TILES) : (step += 1) {
        const agent_tx = step;
        const agent_tz = step;
        const agent_pos = [3]f32{
            (@as(f32, @floatFromInt(agent_tx)) + 0.5) * TILE_SIZE,
            0.0,
            (@as(f32, @floatFromInt(agent_tz)) + 0.5) * TILE_SIZE,
        };

        std.debug.print("--- Step {d}: agent at tile ({d},{d}) pos ({d:.1},{d:.1}) ---\n", .{
            step, agent_tx, agent_tz, agent_pos[0], agent_pos[2],
        });

        // (a) Unload tiles now outside the window.
        var to_unload: std.ArrayList(TileKey) = .empty;
        defer to_unload.deinit(allocator);
        var it = loaded.keyIterator();
        while (it.next()) |k| {
            const dx = @abs(k.tx - agent_tx);
            const dz = @abs(k.tz - agent_tz);
            if (dx > STREAM_RADIUS or dz > STREAM_RADIUS) {
                try to_unload.append(allocator, k.*);
            }
        }
        for (to_unload.items) |k| {
            const t = loaded.fetchRemove(k).?.value;
            const removed = try navmesh.removeTile(t.ref);
            std.debug.assert(removed.data.ptr == t.data.ptr); // we own it back
            allocator.free(t.data);
            total_removed += 1;
            std.debug.print("  unload tile ({d},{d})\n", .{ k.tx, k.tz });
        }

        // (b) Load tiles now inside the window that aren't resident yet.
        var dz: i32 = -STREAM_RADIUS;
        while (dz <= STREAM_RADIUS) : (dz += 1) {
            var dx: i32 = -STREAM_RADIUS;
            while (dx <= STREAM_RADIUS) : (dx += 1) {
                const tx = agent_tx + dx;
                const tz = agent_tz + dz;
                if (tx < 0 or tx >= WORLD_TILES or tz < 0 or tz >= WORLD_TILES) continue;
                const key = TileKey{ .tx = tx, .tz = tz };
                if (loaded.contains(key)) continue;

                // Bake this tile fresh each time it streams in (simulates
                // reading baked data from disk / a cache).
                const data = try buildFlatTile(allocator, tx, tz);
                const ref = navmesh.addTile(data, flags, 0) catch |e| {
                    allocator.free(data);
                    return e;
                };
                try loaded.put(key, .{ .ref = ref, .data = data });
                total_added += 1;
                std.debug.print("  load   tile ({d},{d})\n", .{ tx, tz });
            }
        }

        std.debug.print("  resident tiles: {d}\n", .{loaded.count()});

        // (c) Query the streamed navmesh: find a path from the agent toward
        //     the far corner of the currently-resident window. This proves
        //     the mesh is queryable and stitched across tile borders.
        try runQuery(allocator, &navmesh, agent_pos, agent_tx, agent_tz);
        std.debug.print("\n", .{});
    }

    std.debug.print("=========================================\n", .{});
    std.debug.print("Streaming done. tiles added: {d}, tiles removed: {d}\n", .{
        total_added, total_removed,
    });
    std.debug.print("Still resident (will be torn down): {d}\n", .{loaded.count()});
    std.debug.print("DebugAllocator leak check runs on exit — no leak == streaming reclaimed all memory.\n", .{});
}

/// Find a path from `agent_pos` to the center of a neighbouring resident tile,
/// demonstrating the navmesh stays queryable while tiles stream in/out.
fn runQuery(
    allocator: std.mem.Allocator,
    navmesh: *nav.detour.NavMesh,
    agent_pos: [3]f32,
    agent_tx: i32,
    agent_tz: i32,
) !void {
    // Target the tile one step toward the world max (still in-window when it
    // exists); clamp to the agent's own tile at the far corner.
    const tgt_tx = @min(agent_tx + STREAM_RADIUS, WORLD_TILES - 1);
    const tgt_tz = @min(agent_tz + STREAM_RADIUS, WORLD_TILES - 1);
    const target_pos = [3]f32{
        (@as(f32, @floatFromInt(tgt_tx)) + 0.5) * TILE_SIZE,
        0.0,
        (@as(f32, @floatFromInt(tgt_tz)) + 0.5) * TILE_SIZE,
    };

    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: nav.detour.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&agent_pos, &ext, &filter, &start_ref, &start_pos);

    var end_ref: nav.detour.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try query.findNearestPoly(&target_pos, &ext, &filter, &end_ref, &end_pos);

    if (start_ref == 0 or end_ref == 0) {
        std.debug.print("  query: start/end poly not found\n", .{});
        return;
    }

    var path: [256]nav.detour.PolyRef = undefined;
    var path_count: usize = 0;
    _ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
    std.debug.print("  query: path to tile ({d},{d}) = {d} polys\n", .{ tgt_tx, tgt_tz, path_count });
}

/// Bake one flat-quad tile at grid coords (tx, tz). Geometry fills the whole
/// tile cell (plus a border ring) so outer edges land on the tile border and
/// become portal edges that stitch to neighbour tiles. Mirrors the bake recipe
/// in test/integration/removetile_link_leak_test.zig.
fn buildFlatTile(allocator: std.mem.Allocator, tx: i32, tz: i32) ![]u8 {
    var ctx = nav.Context.init(allocator);

    const ox = @as(f32, @floatFromInt(tx)) * TILE_SIZE;
    const oz = @as(f32, @floatFromInt(tz)) * TILE_SIZE;

    const cs: f32 = 0.3;
    const border: i32 = 4;
    const pad: f32 = @as(f32, @floatFromInt(border)) * cs;

    var config = nav.RecastConfig{
        .cs = cs,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 0, // skip erosion → polygon edges reach the border
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
