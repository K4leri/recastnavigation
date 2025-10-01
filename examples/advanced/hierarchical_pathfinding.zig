const std = @import("std");
const recast = @import("zig-recast");

/// Hierarchical pathfinding demonstrates techniques for handling
/// long-distance navigation efficiently:
/// 1. Sliced pathfinding (spread across multiple frames)
/// 2. Path corridors (progressive refinement)
/// 3. High-level path planning vs low-level execution

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("  ADVANCED EXAMPLE: Hierarchical Pathfinding\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // ================================================================
    // STEP 1: Create large test environment
    // ================================================================
    std.debug.print("Step 1: Creating large test environment (200x200 units)...\n", .{});

    var ctx = recast.Context.init(allocator);

    // Create a large flat terrain with some obstacles
    // This simulates a large open world section
    const world_size = 200.0;
    const num_segments = 20; // 20x20 grid
    const segment_size = world_size / @as(f32, @floatFromInt(num_segments));

    // Generate grid mesh
    var vertices_list = std.ArrayList(f32).init(allocator);
    defer vertices_list.deinit();
    var indices_list = std.ArrayList(i32).init(allocator);
    defer indices_list.deinit();

    var z: usize = 0;
    while (z < num_segments) : (z += 1) {
        var x: usize = 0;
        while (x < num_segments) : (x += 1) {
            const x0 = @as(f32, @floatFromInt(x)) * segment_size;
            const z0 = @as(f32, @floatFromInt(z)) * segment_size;
            const x1 = x0 + segment_size;
            const z1 = z0 + segment_size;

            // Add slight elevation variation
            const y_var = @sin(x0 * 0.1) * @cos(z0 * 0.1) * 0.5;

            const base_vertex = @as(i32, @intCast(vertices_list.items.len / 3));

            // Quad vertices
            try vertices_list.appendSlice(&[_]f32{ x0, y_var, z0 });
            try vertices_list.appendSlice(&[_]f32{ x1, y_var, z0 });
            try vertices_list.appendSlice(&[_]f32{ x1, y_var, z1 });
            try vertices_list.appendSlice(&[_]f32{ x0, y_var, z1 });

            // Two triangles per quad
            try indices_list.appendSlice(&[_]i32{
                base_vertex,
                base_vertex + 1,
                base_vertex + 2,
                base_vertex,
                base_vertex + 2,
                base_vertex + 3,
            });
        }
    }

    const vertices = vertices_list.items;
    const indices = indices_list.items;

    std.debug.print("  Generated terrain: {} vertices, {} triangles\n", .{
        vertices.len / 3,
        indices.len / 3,
    });
    std.debug.print("  World size: {d:.0f}x{d:.0f} units\n\n", .{ world_size, world_size });

    // ================================================================
    // STEP 2: Build navigation mesh (optimized settings)
    // ================================================================
    std.debug.print("Step 2: Building navigation mesh...\n", .{});

    const cell_size: f32 = 0.5; // Larger cells for big environment
    const cell_height: f32 = 0.3;
    const agent_height: f32 = 2.0;
    const agent_radius: f32 = 0.6;
    const agent_max_climb: f32 = 0.9;

    const walkableHeight = @as(i32, @intFromFloat(@ceil(agent_height / cell_height)));
    const walkableClimb = @as(i32, @intFromFloat(@ceil(agent_max_climb / cell_height)));
    const walkableRadius = @as(i32, @intFromFloat(@ceil(agent_radius / cell_size)));

    var bmin = [3]f32{ 0.0, -10.0, 0.0 };
    var bmax = [3]f32{ world_size, 10.0, world_size };

    var width: i32 = 0;
    var height: i32 = 0;
    recast.calcGridSize(&bmin, &bmax, cell_size, &width, &height);

    std.debug.print("  Grid size: {}x{} cells\n", .{ width, height });

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

    // Rasterize all geometry
    var areas = try allocator.alloc(u8, indices.len / 3);
    defer allocator.free(areas);
    @memset(areas, recast.POLYAREA_GROUND);

    try recast.rasterizeTriangles(&ctx, vertices, indices, areas, &heightfield, 1);

    try recast.filterLowHangingWalkableObstacles(&ctx, walkableClimb, &heightfield);
    try recast.filterLedgeSpans(&ctx, walkableHeight, walkableClimb, &heightfield);
    try recast.filterWalkableLowHeightSpans(&ctx, walkableHeight, &heightfield);

    var chf = try recast.buildCompactHeightfield(&ctx, allocator, walkableHeight, walkableClimb, &heightfield);
    defer chf.deinit();

    try recast.erodeWalkableArea(&ctx, walkableRadius, &chf);
    try recast.buildDistanceField(&ctx, &chf);
    try recast.buildRegions(&ctx, allocator, &chf, 0, 10, 25); // Larger regions

    var cset = try recast.buildContours(&ctx, allocator, &chf, 1.3, 12, recast.CONTOUR_TESS_WALL_EDGES);
    defer cset.deinit();

    var pmesh = try recast.buildPolyMesh(&ctx, allocator, &cset, 6);
    defer pmesh.deinit();

    var dmesh = try recast.buildPolyMeshDetail(&ctx, allocator, &pmesh, &chf, 6.0, 1.0);
    defer dmesh.deinit();

    std.debug.print("  Built navmesh: {} polygons\n\n", .{pmesh.npolys});

    // ================================================================
    // STEP 3: Create Detour navigation mesh
    // ================================================================
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

    // ================================================================
    // PART 1: Standard pathfinding (single-shot)
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 1: Standard Pathfinding (Single-Shot)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    var query = try recast.NavMeshQuery.init(allocator, &navmesh, 2048);
    defer query.deinit();

    const start_pos = [3]f32{ 10.0, 0.0, 10.0 };
    const end_pos = [3]f32{ 190.0, 0.0, 190.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var filter = recast.QueryFilter.init();

    var start_nearest: [3]f32 = undefined;
    var end_nearest: [3]f32 = undefined;

    const start_ref = try query.findNearestPoly(&start_pos, &extents, &filter, &start_nearest, null);
    const end_ref = try query.findNearestPoly(&end_pos, &extents, &filter, &end_nearest, null);

    std.debug.print("Finding long-distance path...\n", .{});
    std.debug.print("  Start: ({d:.1f}, {d:.1f}, {d:.1f})\n", .{ start_pos[0], start_pos[1], start_pos[2] });
    std.debug.print("  End: ({d:.1f}, {d:.1f}, {d:.1f})\n", .{ end_pos[0], end_pos[1], end_pos[2] });
    std.debug.print("  Distance: ~{d:.1f} units\n\n", .{recast.vdist(&start_pos, &end_pos)});

    const timer_start = std.time.nanoTimestamp();

    var path: [1024]recast.PolyRef = undefined;
    const path_count = try query.findPath(
        start_ref,
        end_ref,
        &start_nearest,
        &end_nearest,
        &filter,
        &path,
        1024,
    );

    const timer_end = std.time.nanoTimestamp();
    const elapsed_us = @divTrunc(timer_end - timer_start, 1000);

    std.debug.print("Standard pathfinding results:\n", .{});
    std.debug.print("  Path length: {} polygons\n", .{path_count});
    std.debug.print("  Time: {} μs\n\n", .{elapsed_us});

    // ================================================================
    // PART 2: Sliced pathfinding (multi-frame)
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 2: Sliced Pathfinding (Multi-Frame)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("Sliced pathfinding allows spreading pathfinding over multiple\n", .{});
    std.debug.print("frames to avoid performance spikes in games.\n\n", .{});

    const max_iterations_per_frame = 64; // Process 64 nodes per frame

    var sliced_path: [1024]recast.PolyRef = undefined;
    var sliced_query = try recast.NavMeshQuery.init(allocator, &navmesh, 2048);
    defer sliced_query.deinit();

    // Initialize sliced pathfinding
    try sliced_query.initSlicedFindPath(start_ref, end_ref, &start_nearest, &end_nearest, &filter, 0);

    var frame_count: u32 = 0;
    var total_iterations: u32 = 0;

    std.debug.print("Processing path in slices...\n", .{});

    const sliced_timer_start = std.time.nanoTimestamp();

    while (true) {
        frame_count += 1;

        var iterations_done: i32 = 0;
        const status = try sliced_query.updateSlicedFindPath(max_iterations_per_frame, &iterations_done);
        total_iterations += @intCast(iterations_done);

        std.debug.print("  Frame {}: processed {} nodes (total: {})\n", .{
            frame_count,
            iterations_done,
            total_iterations,
        });

        if (recast.dtStatusSucceed(status)) {
            break;
        }

        if (frame_count > 100) {
            std.debug.print("  WARNING: Path not found after 100 frames\n", .{});
            break;
        }
    }

    var sliced_path_count: i32 = 0;
    try sliced_query.finalizeSlicedFindPath(&sliced_path, &sliced_path_count, 1024);

    const sliced_timer_end = std.time.nanoTimestamp();
    const sliced_elapsed_us = @divTrunc(sliced_timer_end - sliced_timer_start, 1000);

    std.debug.print("\nSliced pathfinding results:\n", .{});
    std.debug.print("  Path length: {} polygons\n", .{sliced_path_count});
    std.debug.print("  Total time: {} μs\n", .{sliced_elapsed_us});
    std.debug.print("  Frames: {}\n", .{frame_count});
    std.debug.print("  Avg time per frame: {} μs\n", .{@divTrunc(sliced_elapsed_us, frame_count)});
    std.debug.print("  Nodes processed: {}\n\n", .{total_iterations});

    // ================================================================
    // PART 3: Path Corridor (Progressive Refinement)
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  PART 3: Path Corridor (Progressive Movement)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("Path corridors allow agents to move along a path while\n", .{});
    std.debug.print("dynamically adjusting to obstacles and path changes.\n\n", .{});

    var corridor = try recast.PathCorridor.init(allocator);
    defer corridor.deinit();

    corridor.reset(start_ref, &start_nearest);
    try corridor.setCorridor(&end_nearest, path[0..path_count]);

    std.debug.print("Corridor initialized:\n", .{});
    std.debug.print("  Start poly: {}\n", .{corridor.getFirstPoly()});
    std.debug.print("  Target poly: {}\n", .{corridor.getLastPoly()});
    std.debug.print("  Corridor length: {} polygons\n\n", .{corridor.getPathCount()});

    // Simulate movement along corridor
    var current_pos = start_nearest;
    var move_count: u32 = 0;
    const move_distance: f32 = 5.0; // Move 5 units per step

    std.debug.print("Simulating movement along corridor:\n", .{});

    while (recast.vdist(&current_pos, &end_nearest) > 1.0 and move_count < 100) {
        move_count += 1;

        // Get corners ahead in the corridor
        var corner_verts: [4][3]f32 = undefined;
        var corner_flags: [4]u8 = undefined;
        var corner_polys: [4]recast.PolyRef = undefined;
        const num_corners = try corridor.findCorners(
            &corner_verts,
            &corner_flags,
            &corner_polys,
            4,
            &query,
            &filter,
        );

        if (num_corners == 0) break;

        // Move towards first corner
        const target = corner_verts[0];
        var move_dir = [3]f32{
            target[0] - current_pos[0],
            target[1] - current_pos[1],
            target[2] - current_pos[2],
        };

        const dist = recast.vlen(&move_dir);
        if (dist > 0.001) {
            recast.vscale(&move_dir, &move_dir, 1.0 / dist);
        }

        const step_size = @min(move_distance, dist);
        var new_pos = [3]f32{
            current_pos[0] + move_dir[0] * step_size,
            current_pos[1] + move_dir[1] * step_size,
            current_pos[2] + move_dir[2] * step_size,
        };

        // Move position in corridor
        var visited: [16]recast.PolyRef = undefined;
        var nvisited: i32 = 0;

        try corridor.movePosition(&new_pos, &query, &filter, &visited, &nvisited, 16);
        current_pos = corridor.getPos().*;

        if (move_count % 10 == 0) {
            std.debug.print("  Step {}: pos=({d:.1f}, {d:.1f}, {d:.1f}), dist_to_goal={d:.1f}\n", .{
                move_count,
                current_pos[0],
                current_pos[1],
                current_pos[2],
                recast.vdist(&current_pos, &end_nearest),
            });
        }
    }

    std.debug.print("\nMovement simulation complete:\n", .{});
    std.debug.print("  Steps taken: {}\n", .{move_count});
    std.debug.print("  Final distance to goal: {d:.1f} units\n\n", .{recast.vdist(&current_pos, &end_nearest)});

    // ================================================================
    // SUMMARY
    // ================================================================
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  SUMMARY: Hierarchical Pathfinding Techniques\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("Three approaches compared:\n\n", .{});

    std.debug.print("1. STANDARD PATHFINDING:\n", .{});
    std.debug.print("   - Single-shot, immediate result\n", .{});
    std.debug.print("   - Can cause frame rate spikes on long paths\n", .{});
    std.debug.print("   - Time: {} μs\n\n", .{elapsed_us});

    std.debug.print("2. SLICED PATHFINDING:\n", .{});
    std.debug.print("   - Spread across {} frames\n", .{frame_count});
    std.debug.print("   - Avg {} μs per frame (smooth performance)\n", .{@divTrunc(sliced_elapsed_us, frame_count)});
    std.debug.print("   - Total time: {} μs\n\n", .{sliced_elapsed_us});

    std.debug.print("3. PATH CORRIDOR:\n", .{});
    std.debug.print("   - Progressive movement with dynamic updates\n", .{});
    std.debug.print("   - Handles obstacles and path changes\n", .{});
    std.debug.print("   - Optimal for moving agents\n\n", .{});

    std.debug.print("Best Practices:\n", .{});
    std.debug.print("  - Use sliced pathfinding for long-distance planning\n", .{});
    std.debug.print("  - Use path corridors for agent movement\n", .{});
    std.debug.print("  - Combine both for optimal performance\n", .{});
    std.debug.print("  - Adjust slice size based on frame budget\n\n", .{});
}
