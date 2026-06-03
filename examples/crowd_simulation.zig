//! DetourCrowd simulation demo on the CURRENT library API.
//!
//! Bakes a real navmesh from raw triangles (same pipeline as
//! `examples/03_full_pathfinding.zig`), then drives a real `Crowd`:
//! several agents are added, all given a SHARED move target via
//! `requestMoveTarget`, and the crowd is stepped with a fixed dt.
//! Agent positions are printed converging toward the goal.
//!
//! Mirrors the CI-verified usage in
//! `test/integration/crowd_simulation_test.zig`.
//!
//! Run with:
//!   zig build run-crowd_simulation

const std = @import("std");
const nav = @import("recast-nav");

pub fn main() !void {
    // DebugAllocator (0.16 successor to GeneralPurposeAllocator): doubles as a
    // leak smoke-test — deinit() reports whether anything was left unfreed.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leaked");
    const allocator = gpa.allocator();

    var ctx = nav.Context.init(allocator);

    std.debug.print("DetourCrowd simulation demo\n", .{});
    std.debug.print("===========================\n\n", .{});

    // ---------------------------------------------------------------------
    // 1. Input geometry: a flat 40x40 floor (flat f32 xyz, i32 indices)
    // ---------------------------------------------------------------------
    const verts = [_]f32{
        -20, 0, -20, // 0
        20,  0, -20, // 1
        20,  0, 20, // 2
        -20, 0, 20, // 3
    };
    const indices = [_]i32{
        0, 1, 2,
        0, 2, 3,
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
    // 9. Crowd: add agents, share a move target, simulate
    // ---------------------------------------------------------------------
    const max_agents = 8;
    const agent_radius: f32 = 0.6;
    var crowd = try nav.Crowd.init(allocator, max_agents, agent_radius, &navmesh);
    defer crowd.deinit();

    var agent_params = nav.CrowdAgentParams.init();
    agent_params.radius = agent_radius;
    agent_params.height = 2.0;
    agent_params.max_acceleration = 8.0;
    agent_params.max_speed = 3.5;
    agent_params.collision_query_range = agent_radius * 12.0;
    agent_params.path_optimization_range = agent_radius * 30.0;
    agent_params.separation_weight = 2.0;
    agent_params.update_flags = nav.CrowdAgentParams.init().update_flags; // = UpdateFlags.all

    // Spawn agents along one side of the floor.
    const spawns = [_][3]f32{
        .{ -15, 0, -15 },
        .{ -10, 0, -15 },
        .{ -5, 0, -15 },
        .{ 0, 0, -15 },
        .{ 5, 0, -15 },
        .{ 10, 0, -15 },
    };

    var agent_ids: [spawns.len]i32 = undefined;
    var n_added: usize = 0;
    for (spawns, 0..) |pos, i| {
        const id = try crowd.addAgent(&pos, &agent_params);
        agent_ids[i] = id;
        if (id >= 0) n_added += 1;
    }
    std.debug.print("added {d} agents\n", .{n_added});

    // Shared goal on the opposite corner — snap to nearest navmesh poly.
    const goal_in = [3]f32{ 15, 0, 15 };
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    var filter = nav.detour.QueryFilter.init();
    var target_ref: nav.detour.PolyRef = 0;
    var target_pos = [3]f32{ 0, 0, 0 };
    try crowd.navquery.findNearestPoly(&goal_in, &ext, &filter, &target_ref, &target_pos);
    if (target_ref == 0) {
        std.debug.print("goal poly not found on navmesh\n", .{});
        return;
    }
    std.debug.print("shared goal: ({d:.2}, {d:.2}, {d:.2}) ref={d}\n\n", .{ target_pos[0], target_pos[1], target_pos[2], target_ref });

    for (agent_ids) |id| {
        _ = crowd.requestMoveTarget(id, target_ref, &target_pos);
    }

    // ---------------------------------------------------------------------
    // 10. Run the simulation
    // ---------------------------------------------------------------------
    const dt: f32 = 1.0 / 30.0; // 30 Hz
    const num_steps: usize = 300; // 10 seconds
    std.debug.print("simulating {d} steps @ {d:.1} Hz ({d:.1}s)\n", .{ num_steps, 1.0 / dt, @as(f32, @floatFromInt(num_steps)) * dt });
    std.debug.print("------------------------------------------------------------\n", .{});

    var step: usize = 0;
    while (step < num_steps) : (step += 1) {
        try crowd.update(dt);

        if (step % 60 == 0 or step == num_steps - 1) {
            const t = @as(f32, @floatFromInt(step)) * dt;
            std.debug.print("t={d:5.2}s\n", .{t});
            for (agent_ids, 0..) |id, idx| {
                const ag = crowd.getAgent(id) orelse continue;
                const dx = target_pos[0] - ag.npos[0];
                const dz = target_pos[2] - ag.npos[2];
                const dist = @sqrt(dx * dx + dz * dz);
                const speed = @sqrt(ag.vel[0] * ag.vel[0] + ag.vel[2] * ag.vel[2]);
                std.debug.print("  agent {d}: pos=({d:6.2},{d:6.2},{d:6.2}) speed={d:.2} dist_to_goal={d:5.2} [{s}]\n", .{
                    idx, ag.npos[0], ag.npos[1], ag.npos[2], speed, dist, @tagName(ag.state),
                });
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("------------------------------------------------------------\n", .{});
    std.debug.print("velocity samples processed: {d}\n", .{crowd.getVelocitySampleCount()});

    // Summary: how many agents reached the goal vicinity.
    var arrived: usize = 0;
    for (agent_ids) |id| {
        const ag = crowd.getAgent(id) orelse continue;
        const dx = target_pos[0] - ag.npos[0];
        const dz = target_pos[2] - ag.npos[2];
        if (@sqrt(dx * dx + dz * dz) < 2.0) arrived += 1;
    }
    std.debug.print("agents within 2.0m of goal: {d}/{d}\n", .{ arrived, n_added });
    std.debug.print("\ndone.\n", .{});
}
