const std = @import("std");
const recast = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("👥 Recast Navigation Crowd Simulation Demo\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Create a simple rectangular area: 40x40 units
    const vertices = [_]f32{
        // Floor vertices (y=0)
        -20.0, 0.0, -20.0, // 0
        20.0,  0.0, -20.0, // 1
        20.0,  0.0, 20.0, // 2
        -20.0, 0.0, 20.0, // 3
    };

    const indices = [_]i32{
        0, 1, 2, // Triangle 1
        0, 2, 3, // Triangle 2
    };

    std.debug.print("📦 Input mesh: {d} vertices, {d} triangles\n", .{ vertices.len / 3, indices.len / 3 });

    // Calculate bounds
    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        bmin[0] = @min(bmin[0], vertices[i + 0]);
        bmin[1] = @min(bmin[1], vertices[i + 1]);
        bmin[2] = @min(bmin[2], vertices[i + 2]);
        bmax[0] = @max(bmax[0], vertices[i + 0]);
        bmax[1] = @max(bmax[1], vertices[i + 1]);
        bmax[2] = @max(bmax[2], vertices[i + 2]);
    }

    std.debug.print("📏 Bounds: ({d:.1}, {d:.1}, {d:.1}) to ({d:.1}, {d:.1}, {d:.1})\n\n", .{
        bmin[0], bmin[1], bmin[2],
        bmax[0], bmax[1], bmax[2],
    });

    // Create navmesh parameters
    var nav_params = recast.NavMeshParams.init();
    nav_params.orig = recast.Vec3.init(bmin[0], bmin[1], bmin[2]);
    nav_params.tile_width = bmax[0] - bmin[0];
    nav_params.tile_height = bmax[2] - bmin[2];
    nav_params.max_tiles = 128;
    nav_params.max_polys = 256;

    std.debug.print("🗺️  Creating navigation mesh...\n", .{});
    var navmesh = try recast.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    std.debug.print("✅ NavMesh created with {d} max tiles\n\n", .{navmesh.max_tiles});

    // Create a query object
    std.debug.print("🔍 Creating navmesh query...\n", .{});
    var query = try recast.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&navmesh, 2048);
    std.debug.print("✅ Query initialized\n\n", .{});

    // Create crowd manager
    std.debug.print("👥 Creating crowd manager...\n", .{});
    var crowd = try recast.Crowd.init(allocator, 10, 0.6, &navmesh);
    defer crowd.deinit();

    std.debug.print("✅ Crowd manager created with max 10 agents\n", .{});
    std.debug.print("   - Agent radius: 0.6 units\n", .{});
    std.debug.print("   - Max agents: {d}\n\n", .{crowd.getAgentCount()});

    // Setup agent parameters
    var agent_params = recast.CrowdAgentParams{
        .radius = 0.6,
        .height = 2.0,
        .max_acceleration = 8.0,
        .max_speed = 3.5,
        .collision_query_range = 2.5,
        .path_optimization_range = 30.0,
        .separation_weight = 2.0,
        .update_flags = recast.UpdateFlags.anticipate_turns |
                        recast.UpdateFlags.optimize_vis |
                        recast.UpdateFlags.optimize_topo |
                        recast.UpdateFlags.obstacle_avoid |
                        recast.UpdateFlags.separation,
        .obstacle_avoidance_type = 3,
        .query_filter_type = 0,
        .user_data = null,
    };

    // Add several agents at different positions
    std.debug.print("🚶 Adding agents to simulation...\n", .{});

    const agent_positions = [_][3]f32{
        .{ -15.0, 0.0, -15.0 }, // Agent 0
        .{ -10.0, 0.0, -10.0 }, // Agent 1
        .{ 10.0, 0.0, -10.0 },  // Agent 2
        .{ 15.0, 0.0, 15.0 },   // Agent 3
    };

    const agent_targets = [_][3]f32{
        .{ 15.0, 0.0, 15.0 },   // Agent 0 target
        .{ 10.0, 0.0, 10.0 },   // Agent 1 target
        .{ -10.0, 0.0, 10.0 },  // Agent 2 target
        .{ -15.0, 0.0, -15.0 }, // Agent 3 target
    };

    var agent_ids: [4]i32 = undefined;

    for (agent_positions, 0..) |pos, idx| {
        const agent_id = try crowd.addAgent(&pos, &agent_params);
        agent_ids[idx] = agent_id;
        std.debug.print("   Agent {d}: pos=({d:.1}, {d:.1}, {d:.1}) -> target=({d:.1}, {d:.1}, {d:.1})\n", .{
            idx,
            pos[0], pos[1], pos[2],
            agent_targets[idx][0], agent_targets[idx][1], agent_targets[idx][2],
        });
    }

    std.debug.print("\n✅ Added {d} agents\n\n", .{agent_positions.len});

    // Set movement targets for agents
    std.debug.print("🎯 Setting agent targets...\n", .{});

    for (agent_ids, 0..) |agent_id, idx| {
        const agent = crowd.getAgent(agent_id);
        if (agent) |ag| {
            // For this demo, we'll use requestMoveVelocity since we don't have actual navmesh tiles
            // In a real scenario with proper navmesh, you'd use requestMoveTarget
            const dir_x = agent_targets[idx][0] - ag.npos[0];
            const dir_z = agent_targets[idx][2] - ag.npos[2];
            const dist = @sqrt(dir_x * dir_x + dir_z * dir_z);

            var vel = [3]f32{ 0, 0, 0 };
            if (dist > 0.1) {
                vel[0] = (dir_x / dist) * ag.params.max_speed;
                vel[2] = (dir_z / dist) * ag.params.max_speed;
            }

            _ = crowd.requestMoveVelocity(agent_id, &vel);
            std.debug.print("   Agent {d}: velocity=({d:.2}, {d:.2}, {d:.2})\n", .{
                idx, vel[0], vel[1], vel[2],
            });
        }
    }

    std.debug.print("\n🎬 Starting simulation...\n", .{});
    std.debug.print("-" ** 60 ++ "\n\n", .{});

    // Run simulation for several timesteps
    const dt: f32 = 1.0 / 60.0; // 60 FPS
    const num_steps: usize = 120; // 2 seconds at 60 FPS

    var step: usize = 0;
    while (step < num_steps) : (step += 1) {
        // Update crowd simulation
        try crowd.update(dt);

        // Print agent positions every 30 frames (0.5 seconds)
        if (step % 30 == 0) {
            const time = @as(f32, @floatFromInt(step)) * dt;
            std.debug.print("⏱️  Time: {d:.2}s\n", .{time});

            for (agent_ids, 0..) |agent_id, idx| {
                const agent = crowd.getAgent(agent_id);
                if (agent) |ag| {
                    const vel_mag = @sqrt(ag.vel[0] * ag.vel[0] + ag.vel[2] * ag.vel[2]);
                    const target_dist = blk: {
                        const dx = agent_targets[idx][0] - ag.npos[0];
                        const dz = agent_targets[idx][2] - ag.npos[2];
                        break :blk @sqrt(dx * dx + dz * dz);
                    };

                    std.debug.print("   Agent {d}: pos=({d:5.1}, {d:5.1}, {d:5.1}) ", .{
                        idx, ag.npos[0], ag.npos[1], ag.npos[2],
                    });
                    std.debug.print("vel={d:.2} m/s, dist_to_target={d:.1}m", .{
                        vel_mag, target_dist,
                    });

                    // Show state
                    std.debug.print(" [{s}]\n", .{@tagName(ag.state)});
                }
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("📊 Simulation Statistics:\n", .{});
    std.debug.print("   Total time steps: {d}\n", .{num_steps});
    std.debug.print("   Simulation time: {d:.2}s\n", .{@as(f32, @floatFromInt(num_steps)) * dt});
    std.debug.print("   Velocity samples: {d}\n", .{crowd.getVelocitySampleCount()});
    std.debug.print("   Active agents: {d}\n\n", .{agent_positions.len});

    // Final agent positions
    std.debug.print("🏁 Final Agent Positions:\n", .{});
    for (agent_ids, 0..) |agent_id, idx| {
        const agent = crowd.getAgent(agent_id);
        if (agent) |ag| {
            const target_dist = blk: {
                const dx = agent_targets[idx][0] - ag.npos[0];
                const dz = agent_targets[idx][2] - ag.npos[2];
                break :blk @sqrt(dx * dx + dz * dz);
            };

            std.debug.print("   Agent {d}: ({d:5.1}, {d:5.1}, {d:5.1}) - ", .{
                idx, ag.npos[0], ag.npos[1], ag.npos[2],
            });
            std.debug.print("{d:.1}m from target\n", .{target_dist});
        }
    }

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("✨ Crowd simulation demo completed successfully!\n\n", .{});

    std.debug.print("📚 DetourCrowd Features Demonstrated:\n", .{});
    std.debug.print("   ✅ Crowd manager initialization\n", .{});
    std.debug.print("   ✅ Multiple agent management\n", .{});
    std.debug.print("   ✅ Agent parameter configuration\n", .{});
    std.debug.print("   ✅ Movement target requests\n", .{});
    std.debug.print("   ✅ Real-time crowd simulation update\n", .{});
    std.debug.print("   ✅ Velocity integration\n", .{});
    std.debug.print("   ✅ Agent state tracking\n", .{});
    std.debug.print("\n📝 Note: This demo uses velocity-based movement.\n", .{});
    std.debug.print("   For pathfinding-based movement, build a complete navmesh with tiles.\n", .{});
}
