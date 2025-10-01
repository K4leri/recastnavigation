const std = @import("std");
const recast = @import("zig-recast");

/// Streaming World demonstrates dynamic tile loading/unloading for large worlds:
/// 1. Tiled navigation mesh architecture
/// 2. Dynamic tile addition and removal
/// 3. Streaming based on player position
/// 4. Memory management for open worlds

const TILE_SIZE: f32 = 32.0; // Each tile is 32x32 units
const STREAM_RADIUS: i32 = 2; // Load tiles within 2 tile radius
const WORLD_TILES_X: i32 = 10;
const WORLD_TILES_Z: i32 = 10;

const TileState = enum {
    unloaded,
    loading,
    loaded,
    unloading,
};

const TileInfo = struct {
    tx: i32,
    tz: i32,
    state: TileState,
    tile_ref: recast.TileRef,
    data: ?[]u8, // Owned tile data
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("  ADVANCED EXAMPLE: Streaming World (Dynamic Tile Loading)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("This example demonstrates a tiled navigation mesh for a large\n", .{});
    std.debug.print("open world with dynamic tile loading/unloading.\n\n", .{});

    // ================================================================
    // STEP 1: Initialize tiled navigation mesh
    // ================================================================
    std.debug.print("Step 1: Initializing tiled navigation mesh...\n", .{});

    const world_min = [3]f32{ 0.0, 0.0, 0.0 };
    const world_max = [3]f32{
        @as(f32, @floatFromInt(WORLD_TILES_X)) * TILE_SIZE,
        10.0,
        @as(f32, @floatFromInt(WORLD_TILES_Z)) * TILE_SIZE,
    };

    const params = recast.NavMeshParams{
        .orig = world_min,
        .tileWidth = TILE_SIZE,
        .tileHeight = TILE_SIZE,
        .maxTiles = 128, // Maximum loaded tiles
        .maxPolys = 2048, // Max polygons per tile
    };

    var navmesh = try recast.NavMesh.init(allocator);
    defer navmesh.deinit();

    try navmesh.initTiled(&params);

    std.debug.print("  World size: {d:.0f}x{d:.0f} units\n", .{
        world_max[0] - world_min[0],
        world_max[2] - world_min[2],
    });
    std.debug.print("  Tile size: {d:.0f}x{d:.0f} units\n", .{ TILE_SIZE, TILE_SIZE });
    std.debug.print("  Grid: {}x{} tiles (total: {} tiles)\n", .{
        WORLD_TILES_X,
        WORLD_TILES_Z,
        WORLD_TILES_X * WORLD_TILES_Z,
    });
    std.debug.print("  Max loaded tiles: {}\n", .{params.maxTiles});
    std.debug.print("  Stream radius: {} tiles\n\n", .{STREAM_RADIUS});

    // ================================================================
    // STEP 2: Pre-generate all tile data
    // ================================================================
    std.debug.print("Step 2: Pre-generating tile navigation data...\n", .{});

    var ctx = recast.Context.init(allocator);

    const cell_size: f32 = 0.3;
    const cell_height: f32 = 0.2;
    const agent_height: f32 = 2.0;
    const agent_radius: f32 = 0.6;
    const agent_max_climb: f32 = 0.9;

    const walkableHeight = @as(i32, @intFromFloat(@ceil(agent_height / cell_height)));
    const walkableClimb = @as(i32, @intFromFloat(@ceil(agent_max_climb / cell_height)));
    const walkableRadius = @as(i32, @intFromFloat(@ceil(agent_radius / cell_size)));

    // Tile storage (simulates persistent storage / cache)
    var tile_storage = std.AutoHashMap(i64, []u8).init(allocator);
    defer {
        var iter = tile_storage.valueIterator();
        while (iter.next()) |data| {
            allocator.free(data.*);
        }
        tile_storage.deinit();
    }

    std.debug.print("  Generating navigation data for all tiles...\n", .{});

    var tiles_generated: u32 = 0;
    var tz: i32 = 0;
    while (tz < WORLD_TILES_Z) : (tz += 1) {
        var tx: i32 = 0;
        while (tx < WORLD_TILES_X) : (tx += 1) {
            const tile_data = try generateTileData(
                allocator,
                &ctx,
                tx,
                tz,
                cell_size,
                cell_height,
                walkableHeight,
                walkableClimb,
                walkableRadius,
                agent_height,
                agent_radius,
                agent_max_climb,
            );

            const key = tileKey(tx, tz);
            try tile_storage.put(key, tile_data);
            tiles_generated += 1;

            if (tiles_generated % 10 == 0) {
                std.debug.print("    Generated {}/{} tiles...\r", .{
                    tiles_generated,
                    WORLD_TILES_X * WORLD_TILES_Z,
                });
            }
        }
    }

    std.debug.print("  Generated {}/{} tiles successfully\n\n", .{
        tiles_generated,
        WORLD_TILES_X * WORLD_TILES_Z,
    });

    // ================================================================
    // STEP 3: Simulate player movement and tile streaming
    // ================================================================
    std.debug.print("Step 3: Simulating player movement with tile streaming...\n\n", .{});

    var loaded_tiles = std.AutoHashMap(i64, TileInfo).init(allocator);
    defer loaded_tiles.deinit();

    // Simulate player walking across the world
    const path_points = [_][3]f32{
        [3]f32{ 16.0, 0.0, 16.0 }, // Start at tile (0, 0)
        [3]f32{ 80.0, 0.0, 80.0 }, // Move to tile (2, 2)
        [3]f32{ 160.0, 0.0, 48.0 }, // Move to tile (5, 1)
        [3]f32{ 240.0, 0.0, 160.0 }, // Move to tile (7, 5)
        [3]f32{ 304.0, 0.0, 304.0 }, // Move to tile (9, 9)
    };

    for (path_points, 0..) |player_pos, step| {
        std.debug.print("=" ** 70 ++ "\n", .{});
        std.debug.print("  Step {}: Player at ({d:.1f}, {d:.1f}, {d:.1f})\n", .{
            step + 1,
            player_pos[0],
            player_pos[1],
            player_pos[2],
        });
        std.debug.print("=" ** 70 ++ "\n\n", .{});

        // Calculate player tile
        var player_tx: i32 = 0;
        var player_tz: i32 = 0;
        navmesh.calcTileLoc(&player_pos, &player_tx, &player_tz);

        std.debug.print("  Player tile: ({}, {})\n\n", .{ player_tx, player_tz });

        // Determine which tiles should be loaded
        var tiles_to_load = std.ArrayList(struct { tx: i32, tz: i32 }).init(allocator);
        defer tiles_to_load.deinit();

        var tz_check: i32 = player_tz - STREAM_RADIUS;
        while (tz_check <= player_tz + STREAM_RADIUS) : (tz_check += 1) {
            var tx_check: i32 = player_tx - STREAM_RADIUS;
            while (tx_check <= player_tx + STREAM_RADIUS) : (tx_check += 1) {
                if (tx_check >= 0 and tx_check < WORLD_TILES_X and
                    tz_check >= 0 and tz_check < WORLD_TILES_Z)
                {
                    try tiles_to_load.append(.{ .tx = tx_check, .tz = tz_check });
                }
            }
        }

        std.debug.print("  Tiles in range: {}\n", .{tiles_to_load.items.len});

        // Unload tiles outside range
        var unload_count: u32 = 0;
        var iter = loaded_tiles.iterator();
        var tiles_to_remove = std.ArrayList(i64).init(allocator);
        defer tiles_to_remove.deinit();

        while (iter.next()) |entry| {
            const tile_info = entry.value_ptr;
            const in_range = for (tiles_to_load.items) |t| {
                if (t.tx == tile_info.tx and t.tz == tile_info.tz) break true;
            } else false;

            if (!in_range) {
                // Unload this tile
                _ = navmesh.removeTile(tile_info.tile_ref);
                if (tile_info.data) |data| {
                    allocator.free(data);
                }
                try tiles_to_remove.append(entry.key_ptr.*);
                unload_count += 1;
            }
        }

        for (tiles_to_remove.items) |key| {
            _ = loaded_tiles.remove(key);
        }

        if (unload_count > 0) {
            std.debug.print("  Unloaded {} tiles\n", .{unload_count});
        }

        // Load new tiles
        var load_count: u32 = 0;
        for (tiles_to_load.items) |t| {
            const key = tileKey(t.tx, t.tz);

            if (!loaded_tiles.contains(key)) {
                // Load this tile
                if (tile_storage.get(key)) |tile_data| {
                    // Make a copy for the navmesh
                    const data_copy = try allocator.dupe(u8, tile_data);

                    const tile_ref = try navmesh.addTile(data_copy, 0, 0);

                    try loaded_tiles.put(key, TileInfo{
                        .tx = t.tx,
                        .tz = t.tz,
                        .state = .loaded,
                        .tile_ref = tile_ref,
                        .data = data_copy,
                    });

                    load_count += 1;
                }
            }
        }

        if (load_count > 0) {
            std.debug.print("  Loaded {} tiles\n", .{load_count});
        }

        std.debug.print("  Currently loaded: {} tiles\n\n", .{loaded_tiles.count()});

        // Show loaded tile grid
        std.debug.print("  Loaded tile map:\n", .{});
        tz_check = player_tz - STREAM_RADIUS - 1;
        while (tz_check <= player_tz + STREAM_RADIUS + 1) : (tz_check += 1) {
            std.debug.print("    ", .{});
            var tx_check: i32 = player_tx - STREAM_RADIUS - 1;
            while (tx_check <= player_tx + STREAM_RADIUS + 1) : (tx_check += 1) {
                const key = tileKey(tx_check, tz_check);
                const is_player = (tx_check == player_tx and tz_check == player_tz);
                const is_loaded = loaded_tiles.contains(key);

                const char = if (is_player)
                    "P"
                else if (is_loaded)
                    "█"
                else
                    "·";

                std.debug.print("{s} ", .{char});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});

        // Test pathfinding in the loaded area
        if (step < path_points.len - 1) {
            const next_pos = path_points[step + 1];

            var query = try recast.NavMeshQuery.init(allocator, &navmesh, 2048);
            defer query.deinit();

            const extents = [3]f32{ 2.0, 4.0, 2.0 };
            var filter = recast.QueryFilter.init();

            var start_nearest: [3]f32 = undefined;
            var end_nearest: [3]f32 = undefined;

            const start_ref = query.findNearestPoly(&player_pos, &extents, &filter, &start_nearest, null) catch 0;
            const end_ref = query.findNearestPoly(&next_pos, &extents, &filter, &end_nearest, null) catch 0;

            if (start_ref != 0 and end_ref != 0) {
                var path: [256]recast.PolyRef = undefined;
                const path_count = query.findPath(
                    start_ref,
                    end_ref,
                    &start_nearest,
                    &end_nearest,
                    &filter,
                    &path,
                    256,
                ) catch 0;

                if (path_count > 0) {
                    std.debug.print("  ✓ Path to next point: {} polygons\n\n", .{path_count});
                } else {
                    std.debug.print("  ✗ No path to next point (tiles not loaded?)\n\n", .{});
                }
            } else {
                std.debug.print("  ✗ Cannot find start/end polygons\n\n", .{});
            }
        }
    }

    // ================================================================
    // STEP 4: Memory statistics
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  STEP 4: Memory Statistics\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    var total_storage: usize = 0;
    var iter_storage = tile_storage.valueIterator();
    while (iter_storage.next()) |data| {
        total_storage += data.len;
    }

    var total_loaded: usize = 0;
    var iter_loaded = loaded_tiles.valueIterator();
    while (iter_loaded.next()) |info| {
        if (info.data) |data| {
            total_loaded += data.len;
        }
    }

    std.debug.print("Memory usage:\n", .{});
    std.debug.print("  Total tiles: {}\n", .{WORLD_TILES_X * WORLD_TILES_Z});
    std.debug.print("  Storage (all tiles): {} KB\n", .{total_storage / 1024});
    std.debug.print("  Loaded tiles: {}\n", .{loaded_tiles.count()});
    std.debug.print("  Loaded memory: {} KB\n", .{total_loaded / 1024});
    std.debug.print("  Memory savings: {d:.1f}%\n\n", .{
        (1.0 - @as(f32, @floatFromInt(total_loaded)) / @as(f32, @floatFromInt(total_storage))) * 100.0,
    });

    // ================================================================
    // SUMMARY
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  SUMMARY: Streaming World Architecture\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("Key Concepts:\n", .{});
    std.debug.print("  1. Tiled navigation mesh for large worlds\n", .{});
    std.debug.print("  2. Dynamic tile loading based on player position\n", .{});
    std.debug.print("  3. Automatic unloading of distant tiles\n", .{});
    std.debug.print("  4. Efficient memory management\n", .{});
    std.debug.print("  5. Seamless pathfinding across tile boundaries\n\n", .{});

    std.debug.print("Benefits:\n", .{});
    std.debug.print("  - Supports arbitrarily large worlds\n", .{});
    std.debug.print("  - Constant memory usage regardless of world size\n", .{});
    std.debug.print("  - Fast navigation queries (only loaded tiles)\n", .{});
    std.debug.print("  - Can be combined with async loading\n\n", .{});

    std.debug.print("Use Cases:\n", .{});
    std.debug.print("  - Open world games\n", .{});
    std.debug.print("  - MMORPGs with large maps\n", .{});
    std.debug.print("  - Procedurally generated worlds\n", .{});
    std.debug.print("  - Any game with memory constraints\n\n", .{});
}

fn tileKey(tx: i32, tz: i32) i64 {
    return (@as(i64, @intCast(tx)) << 32) | @as(i64, @intCast(tz));
}

fn generateTileData(
    allocator: std.mem.Allocator,
    ctx: *recast.Context,
    tx: i32,
    tz: i32,
    cell_size: f32,
    cell_height: f32,
    walkableHeight: i32,
    walkableClimb: i32,
    walkableRadius: i32,
    agent_height: f32,
    agent_radius: f32,
    agent_max_climb: f32,
) ![]u8 {
    // Generate simple flat tile geometry
    const tile_x = @as(f32, @floatFromInt(tx)) * TILE_SIZE;
    const tile_z = @as(f32, @floatFromInt(tz)) * TILE_SIZE;

    // Create a simple quad for this tile
    const vertices = [_]f32{
        tile_x,             0.0, tile_z,
        tile_x + TILE_SIZE, 0.0, tile_z,
        tile_x + TILE_SIZE, 0.0, tile_z + TILE_SIZE,
        tile_x,             0.0, tile_z + TILE_SIZE,
    };

    const indices = [_]i32{
        0, 1, 2,
        0, 2, 3,
    };

    const areas = [_]u8{ recast.POLYAREA_GROUND, recast.POLYAREA_GROUND };

    // Build navmesh for this tile
    const bmin = [3]f32{ tile_x, -10.0, tile_z };
    const bmax = [3]f32{ tile_x + TILE_SIZE, 10.0, tile_z + TILE_SIZE };

    var width: i32 = 0;
    var height: i32 = 0;
    recast.calcGridSize(&bmin, &bmax, cell_size, &width, &height);

    var heightfield = try recast.Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cell_size,
        cell_height,
    );
    defer heightfield.deinit();

    try recast.rasterizeTriangles(ctx, &vertices, &indices, &areas, &heightfield, 1);

    try recast.filterLowHangingWalkableObstacles(ctx, walkableClimb, &heightfield);
    try recast.filterLedgeSpans(ctx, walkableHeight, walkableClimb, &heightfield);
    try recast.filterWalkableLowHeightSpans(ctx, walkableHeight, &heightfield);

    var chf = try recast.buildCompactHeightfield(ctx, allocator, walkableHeight, walkableClimb, &heightfield);
    defer chf.deinit();

    try recast.erodeWalkableArea(ctx, walkableRadius, &chf);
    try recast.buildDistanceField(ctx, &chf);
    try recast.buildRegions(ctx, allocator, &chf, 0, 8, 20);

    var cset = try recast.buildContours(ctx, allocator, &chf, 1.3, 12, recast.CONTOUR_TESS_WALL_EDGES);
    defer cset.deinit();

    var pmesh = try recast.buildPolyMesh(ctx, allocator, &cset, 6);
    defer pmesh.deinit();

    var dmesh = try recast.buildPolyMeshDetail(ctx, allocator, &pmesh, &chf, 6.0, 1.0);
    defer dmesh.deinit();

    // Create nav data for this tile
    const nav_data = try recast.createNavMeshData(allocator, &pmesh, &dmesh, .{
        .cs = cell_size,
        .ch = cell_height,
        .walkableHeight = agent_height,
        .walkableRadius = agent_radius,
        .walkableClimb = agent_max_climb,
        .bmin = bmin,
        .bmax = bmax,
        .buildBvTree = true,
        .tileX = tx,
        .tileY = tz,
    });

    return nav_data;
}
