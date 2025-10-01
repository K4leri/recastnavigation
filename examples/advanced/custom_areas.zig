const std = @import("std");
const recast = @import("zig-recast");

// Custom area types extending the standard ones
const AreaType = enum(u8) {
    ground = recast.POLYAREA_GROUND, // 0 - Standard walkable area
    water = 1, // Shallow water - slow movement
    road = 2, // Road - fast movement
    grass = 3, // Grass - normal movement
    door = 4, // Door - requires key/permission
    danger = 5, // Dangerous area - high cost
    _,
};

// Custom area costs (lower = preferred)
const AreaCosts = struct {
    ground: f32 = 1.0, // Default cost
    water: f32 = 10.0, // 10x slower in water
    road: f32 = 0.5, // 2x faster on roads
    grass: f32 = 2.0, // Slightly slower in grass
    door: f32 = 1.5, // Small overhead for doors
    danger: f32 = 50.0, // Avoid dangerous areas
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  ADVANCED EXAMPLE: Custom Area Types\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Create context for logging
    var ctx = recast.Context.init(allocator);

    // ================================================================
    // STEP 1: Define test geometry with different area types
    // ================================================================
    std.debug.print("Step 1: Creating multi-area test environment...\n", .{});

    // Create a complex environment:
    // - Ground platform (area 0)
    // - Water section (area 1)
    // - Road section (area 2)
    // - Grass section (area 3)
    // - Dangerous area (area 5)

    const vertices = [_]f32{
        // Ground platform (0-20 in X)
        0.0, 0.0, 0.0,
        20.0, 0.0, 0.0,
        20.0, 0.0, 10.0,
        0.0, 0.0, 10.0,

        // Road section (20-40 in X) - slightly elevated
        20.0, 0.1, 0.0,
        40.0, 0.1, 0.0,
        40.0, 0.1, 10.0,
        20.0, 0.1, 10.0,

        // Water section (40-60 in X) - slightly lower
        40.0, -0.5, 0.0,
        60.0, -0.5, 0.0,
        60.0, -0.5, 10.0,
        40.0, -0.5, 10.0,

        // Grass section (60-80 in X)
        60.0, 0.0, 0.0,
        80.0, 0.0, 0.0,
        80.0, 0.0, 10.0,
        60.0, 0.0, 10.0,

        // Danger zone (70-90 in X, 10-20 in Z) - optional path
        70.0, 0.0, 10.0,
        90.0, 0.0, 10.0,
        90.0, 0.0, 20.0,
        70.0, 0.0, 20.0,

        // Safe bypass (80-100 in X, 0-10 in Z)
        80.0, 0.0, 0.0,
        100.0, 0.0, 0.0,
        100.0, 0.0, 10.0,
        80.0, 0.0, 10.0,
    };

    const indices = [_]i32{
        // Ground platform
        0, 1, 2, 0, 2, 3,
        // Road
        4, 5, 6, 4, 6, 7,
        // Water
        8, 9, 10, 8, 10, 11,
        // Grass
        12, 13, 14, 12, 14, 15,
        // Danger zone
        16, 17, 18, 16, 18, 19,
        // Safe bypass
        20, 21, 22, 20, 22, 23,
    };

    // Area types for each triangle (2 triangles per section)
    const areas = [_]u8{
        @intFromEnum(AreaType.ground),
        @intFromEnum(AreaType.ground),
        @intFromEnum(AreaType.road),
        @intFromEnum(AreaType.road),
        @intFromEnum(AreaType.water),
        @intFromEnum(AreaType.water),
        @intFromEnum(AreaType.grass),
        @intFromEnum(AreaType.grass),
        @intFromEnum(AreaType.danger),
        @intFromEnum(AreaType.danger),
        @intFromEnum(AreaType.grass),
        @intFromEnum(AreaType.grass),
    };

    std.debug.print("  Created environment with {} triangles\n", .{indices.len / 3});
    std.debug.print("  Area types: ground, road, water, grass, danger\n\n", .{});

    // ================================================================
    // STEP 2: Configure Recast parameters
    // ================================================================
    const cell_size: f32 = 0.3;
    const cell_height: f32 = 0.2;
    const agent_height: f32 = 2.0;
    const agent_radius: f32 = 0.6;
    const agent_max_climb: f32 = 0.9;
    const agent_max_slope: f32 = 45.0;

    const walkableHeight = @as(i32, @intFromFloat(@ceil(agent_height / cell_height)));
    const walkableClimb = @as(i32, @intFromFloat(@ceil(agent_max_climb / cell_height)));
    const walkableRadius = @as(i32, @intFromFloat(@ceil(agent_radius / cell_size)));

    // Calculate grid size
    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) };
    recast.calcBounds(&vertices, &bmin, &bmax);

    var width: i32 = 0;
    var height: i32 = 0;
    recast.calcGridSize(&bmin, &bmax, cell_size, &width, &height);

    // ================================================================
    // STEP 3: Build navigation mesh (abbreviated pipeline)
    // ================================================================
    std.debug.print("Step 2: Building navigation mesh...\n", .{});

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

    try recast.rasterizeTriangles(&ctx, &vertices, &indices, areas, &heightfield, 1);

    try recast.filterLowHangingWalkableObstacles(&ctx, walkableClimb, &heightfield);
    try recast.filterLedgeSpans(&ctx, walkableHeight, walkableClimb, &heightfield);
    try recast.filterWalkableLowHeightSpans(&ctx, walkableHeight, &heightfield);

    var chf = try recast.buildCompactHeightfield(&ctx, allocator, walkableHeight, walkableClimb, &heightfield);
    defer chf.deinit();

    try recast.erodeWalkableArea(&ctx, walkableRadius, &chf);
    try recast.buildDistanceField(&ctx, &chf);
    try recast.buildRegions(&ctx, allocator, &chf, 0, 8, 20);

    var cset = try recast.buildContours(&ctx, allocator, &chf, 1.3, 12, recast.CONTOUR_TESS_WALL_EDGES);
    defer cset.deinit();

    var pmesh = try recast.buildPolyMesh(&ctx, allocator, &cset, 6);
    defer pmesh.deinit();

    var dmesh = try recast.buildPolyMeshDetail(&ctx, allocator, &pmesh, &chf, 6.0, 1.0);
    defer dmesh.deinit();

    std.debug.print("  Built navmesh with {} polygons\n\n", .{pmesh.npolys});

    // ================================================================
    // STEP 4: Create Detour navigation mesh
    // ================================================================
    std.debug.print("Step 3: Creating Detour navigation mesh...\n", .{});

    var nav_data = try recast.createNavMeshData(allocator, &pmesh, &dmesh, .{
        .cs = cell_size,
        .ch = cell_height,
        .walkableHeight = agent_height,
        .walkableRadius = agent_radius,
        .walkableClimb = agent_max_climb,
        .bmin = bmin,
        .bmax = bmax,
        .buildBvTree = true,
    });
    defer allocator.free(nav_data);

    var navmesh = try recast.NavMesh.init(allocator);
    defer navmesh.deinit();

    _ = try navmesh.addTile(nav_data, 0, 0);

    std.debug.print("  NavMesh initialized\n\n", .{});

    // ================================================================
    // STEP 5: Setup pathfinding query with custom area costs
    // ================================================================
    std.debug.print("Step 4: Configuring custom area costs...\n", .{});

    var query = try recast.NavMeshQuery.init(allocator, &navmesh, 2048);
    defer query.deinit();

    const costs = AreaCosts{};

    // Create filter with custom area costs
    var filter = recast.QueryFilter.init();
    filter.setAreaCost(@intFromEnum(AreaType.ground), costs.ground);
    filter.setAreaCost(@intFromEnum(AreaType.water), costs.water);
    filter.setAreaCost(@intFromEnum(AreaType.road), costs.road);
    filter.setAreaCost(@intFromEnum(AreaType.grass), costs.grass);
    filter.setAreaCost(@intFromEnum(AreaType.door), costs.door);
    filter.setAreaCost(@intFromEnum(AreaType.danger), costs.danger);

    std.debug.print("  Area costs configured:\n", .{});
    std.debug.print("    Ground: {d:.1f}\n", .{costs.ground});
    std.debug.print("    Water: {d:.1f} (10x slower)\n", .{costs.water});
    std.debug.print("    Road: {d:.1f} (2x faster)\n", .{costs.road});
    std.debug.print("    Grass: {d:.1f}\n", .{costs.grass});
    std.debug.print("    Danger: {d:.1f} (avoid!)\n\n", .{costs.danger});

    // ================================================================
    // STEP 6: Find paths with different area preferences
    // ================================================================
    std.debug.print("Step 5: Testing pathfinding with custom area costs...\n\n", .{});

    const start_pos = [3]f32{ 10.0, 0.0, 5.0 }; // Start on ground
    const end_pos = [3]f32{ 90.0, 0.0, 5.0 }; // End on safe bypass

    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_nearest: [3]f32 = undefined;
    var end_nearest: [3]f32 = undefined;

    const start_ref = try query.findNearestPoly(&start_pos, &extents, &filter, &start_nearest, null);
    const end_ref = try query.findNearestPoly(&end_pos, &extents, &filter, &end_nearest, null);

    std.debug.print("  Start: ({d:.1f}, {d:.1f}, {d:.1f}) -> Poly {}\n", .{
        start_pos[0],
        start_pos[1],
        start_pos[2],
        start_ref,
    });
    std.debug.print("  End: ({d:.1f}, {d:.1f}, {d:.1f}) -> Poly {}\n\n", .{
        end_pos[0],
        end_pos[1],
        end_pos[2],
        end_ref,
    });

    // Find path with standard costs
    var path: [256]recast.PolyRef = undefined;
    const path_count = try query.findPath(start_ref, end_ref, &start_nearest, &end_nearest, &filter, &path, 256);

    std.debug.print("  Path found with {} polygons\n", .{path_count});

    // Get area types along the path
    std.debug.print("  Path areas: ", .{});
    for (path[0..path_count]) |poly_ref| {
        const area = try navmesh.getPolyArea(poly_ref);
        const area_name = switch (area) {
            @intFromEnum(AreaType.ground) => "ground",
            @intFromEnum(AreaType.water) => "water",
            @intFromEnum(AreaType.road) => "road",
            @intFromEnum(AreaType.grass) => "grass",
            @intFromEnum(AreaType.danger) => "danger",
            else => "unknown",
        };
        std.debug.print("{s} ", .{area_name});
    }
    std.debug.print("\n\n", .{});

    // ================================================================
    // STEP 7: Test different cost configurations
    // ================================================================
    std.debug.print("Step 6: Testing alternative cost configurations...\n\n", .{});

    // Configuration 1: Avoid water at all costs
    std.debug.print("  Config 1: Avoid water (cost=100.0)\n", .{});
    var filter_no_water = recast.QueryFilter.init();
    filter_no_water.setAreaCost(@intFromEnum(AreaType.water), 100.0);
    filter_no_water.setAreaCost(@intFromEnum(AreaType.road), costs.road);
    filter_no_water.setAreaCost(@intFromEnum(AreaType.grass), costs.grass);

    const path_no_water = try query.findPath(
        start_ref,
        end_ref,
        &start_nearest,
        &end_nearest,
        &filter_no_water,
        &path,
        256,
    );
    std.debug.print("    Path length: {} polygons\n", .{path_no_water});

    // Configuration 2: Prefer roads heavily
    std.debug.print("  Config 2: Prefer roads (cost=0.1)\n", .{});
    var filter_roads = recast.QueryFilter.init();
    filter_roads.setAreaCost(@intFromEnum(AreaType.road), 0.1);
    filter_roads.setAreaCost(@intFromEnum(AreaType.ground), costs.ground);
    filter_roads.setAreaCost(@intFromEnum(AreaType.water), costs.water);
    filter_roads.setAreaCost(@intFromEnum(AreaType.grass), costs.grass);

    const path_roads = try query.findPath(
        start_ref,
        end_ref,
        &start_nearest,
        &end_nearest,
        &filter_roads,
        &path,
        256,
    );
    std.debug.print("    Path length: {} polygons\n", .{path_roads});

    // Configuration 3: Ignore danger zones completely
    std.debug.print("  Config 3: Block danger zones (excludeFlags)\n", .{});
    var filter_no_danger = recast.QueryFilter.init();
    filter_no_danger.setIncludeFlags(0xFFFF);
    filter_no_danger.setExcludeFlags(1 << @intFromEnum(AreaType.danger));

    const path_safe = try query.findPath(
        start_ref,
        end_ref,
        &start_nearest,
        &end_nearest,
        &filter_no_danger,
        &path,
        256,
    );
    std.debug.print("    Path length: {} polygons\n\n", .{path_safe});

    // ================================================================
    // SUMMARY
    // ================================================================
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("  SUMMARY: Custom Area Types\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    std.debug.print("Key Concepts Demonstrated:\n", .{});
    std.debug.print("  1. Custom area types (ground, water, road, grass, danger)\n", .{});
    std.debug.print("  2. Area cost configuration for pathfinding preferences\n", .{});
    std.debug.print("  3. Multiple pathfinding configurations\n", .{});
    std.debug.print("  4. Area-based filtering (include/exclude flags)\n", .{});
    std.debug.print("  5. Dynamic cost adjustment for different scenarios\n\n", .{});

    std.debug.print("Use Cases:\n", .{});
    std.debug.print("  - NPCs that prefer roads over terrain\n", .{});
    std.debug.print("  - Characters that avoid water/dangerous areas\n", .{});
    std.debug.print("  - Different movement costs for different unit types\n", .{});
    std.debug.print("  - Access-controlled areas (doors, restricted zones)\n", .{});
    std.debug.print("  - Dynamic environment changes (flooded areas, hazards)\n\n", .{});
}
