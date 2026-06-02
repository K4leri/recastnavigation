// Off-mesh connection traversal in DetourCrowd.
//
// Verifies the off-mesh trigger + animation-advance ported into Crowd.update(),
// 1:1 with C++ dtCrowd::update (DetourCrowd.cpp:1154-1193 trigger, 1442-1479 anim).
//
// Two layers of coverage:
//   1) Deterministic animation-advance math (an agent placed into .offmesh with
//      hand-set anim fields; we tick update() and assert the ta/tb lerp split,
//      tmax exit, and the .offmesh -> .walking transition).
//   2) End-to-end: a navmesh with two disconnected walkable quads linked ONLY by
//      one off-mesh connection; an agent paths from quad A to quad B, must ENTER
//      .offmesh at the link, lerp across it, and EXIT to .walking past the link.

const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

const MESH_NULL_IDX: u16 = 0xffff;

fn vdist2D(a: *const [3]f32, b: *const [3]f32) f32 {
    const dx = a[0] - b[0];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dz * dz);
}

// ==============================================================================
// 1) DETERMINISTIC ANIMATION-ADVANCE MATH
// ==============================================================================
//
// We build a trivial single-quad navmesh just to get a valid Crowd + agent, then
// drive the off-mesh animation by setting agent_anims[idx] fields directly and
// forcing the agent into .offmesh state. update() must then advance anim.t by dt,
// lerp npos exactly as C++ (initPos->startPos for the first 15% of tmax, then
// startPos->endPos), zero velocity, and flip back to .walking once t > tmax.

fn buildSingleQuadNavMesh(allocator: std.mem.Allocator) !nav.detour.NavMesh {
    // A single 10x10 quad as two triangles (in cell units; cs=0.1 -> 0..10 world).
    const verts = [_]u16{
        0,   0, 0,
        100, 0, 0,
        100, 0, 100,
        0,   0, 100,
    };
    const nvp = 6;
    const polys = [_]u16{
        // poly 0: 0,1,2  (neighbors: edge 2,0 internal to poly1 = index 2 -> stored as +1)
        0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        MESH_NULL_IDX, MESH_NULL_IDX, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        // poly 1: 0,2,3
        0, 2, 3, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        MESH_NULL_IDX, 1, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
    };
    const poly_flags = [_]u16{ 0x01, 0x01 };
    const poly_areas = [_]u8{ 0, 0 };

    const params = nav.detour.NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 4,
        .polys = &polys,
        .poly_flags = &poly_flags,
        .poly_areas = &poly_areas,
        .poly_count = 2,
        .nvp = nvp,
        .bmin = .{ 0.0, 0.0, 0.0 },
        .bmax = .{ 10.0, 1.0, 10.0 },
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .cs = 0.1,
        .ch = 0.1,
        .build_bv_tree = true,
    };

    const data = try nav.detour.createNavMeshData(&params, allocator);
    errdefer allocator.free(data);

    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = 10.0,
        .tile_height = 10.0,
        .max_tiles = 1,
        .max_polys = 256,
    };
    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    const tile_flags = nav.detour.TileFlags{ .free_data = true };
    _ = try navmesh.addTile(data, tile_flags, 0);
    return navmesh;
}

test "Crowd off-mesh: animation-advance math (ta/tb lerp, tmax exit)" {
    const allocator = testing.allocator;

    var navmesh = try buildSingleQuadNavMesh(allocator);
    defer navmesh.deinit();

    var crowd = try nav.detour_crowd.Crowd.init(allocator, 4, 0.6, &navmesh);
    defer crowd.deinit();

    const start_pos = [3]f32{ 2.0, 0.0, 2.0 };
    var ap = nav.detour_crowd.CrowdAgentParams.init();
    ap.radius = 0.3;
    ap.max_speed = 2.0;
    const idx = try crowd.addAgent(&start_pos, &ap);
    try testing.expect(idx >= 0);
    const ui: usize = @intCast(idx);

    const ag = &crowd.agents[ui];
    try testing.expect(ag.state == .walking);

    // Hand-construct an off-mesh animation, mirroring what the trigger block sets.
    const init_pos = [3]f32{ 2.0, 0.0, 2.0 }; // current agent position
    const link_start = [3]f32{ 3.0, 0.0, 3.0 }; // off-mesh start endpoint
    const link_end = [3]f32{ 8.0, 0.0, 8.0 }; // off-mesh end endpoint
    const max_speed: f32 = ap.max_speed;
    const tmax = (vdist2D(&link_start, &link_end) / max_speed) * 0.5;

    ag.npos = init_pos;
    ag.state = .offmesh;
    ag.ncorners = 0;

    const anim = &crowd.agent_anims[ui];
    anim.active = true;
    anim.init_pos = init_pos;
    anim.start_pos = link_start;
    anim.end_pos = link_end;
    anim.t = 0.0;
    anim.tmax = tmax;
    anim.poly_ref = 0;

    try testing.expect(tmax > 0.0);

    const ta = tmax * 0.15;
    const dt: f32 = 0.05;

    // Phase A: t < ta -> lerp init_pos -> start_pos.
    // First tick lands at t = dt. If dt < ta, position is on the init->start segment.
    try crowd.update(dt);
    try testing.expect(ag.state == .offmesh);
    try testing.expectApproxEqAbs(@as(f32, 0.0), nav.math.vlen(&ag.vel), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), nav.math.vlen(&ag.dvel), 1e-6);

    if (dt < ta) {
        const u = dt / ta; // tween(t,0,ta), unclamped here since 0<dt<ta
        const ex = init_pos[0] + (link_start[0] - init_pos[0]) * u;
        const ez = init_pos[2] + (link_start[2] - init_pos[2]) * u;
        try testing.expectApproxEqAbs(ex, ag.npos[0], 1e-4);
        try testing.expectApproxEqAbs(ez, ag.npos[2], 1e-4);
    }

    // Advance to a time safely in phase B (t in (ta, tmax)). Pick t ~ 0.6*tmax.
    anim.t = 0.6 * tmax - dt; // so after one more dt we are at 0.6*tmax
    try crowd.update(dt);
    try testing.expect(ag.state == .offmesh);
    {
        const t = 0.6 * tmax;
        const u = (t - ta) / (tmax - ta); // tween(t,ta,tmax)
        const ex = link_start[0] + (link_end[0] - link_start[0]) * u;
        const ez = link_start[2] + (link_end[2] - link_start[2]) * u;
        try testing.expectApproxEqAbs(ex, ag.npos[0], 1e-3);
        try testing.expectApproxEqAbs(ez, ag.npos[2], 1e-3);
    }

    // Exit: push t past tmax. Agent flips back to .walking and anim deactivates.
    anim.t = tmax; // next +dt makes t > tmax
    try crowd.update(dt);
    try testing.expect(!anim.active);
    try testing.expect(ag.state == .walking);
}

// ==============================================================================
// 2) END-TO-END: REAL OFF-MESH NAVMESH FIXTURE
// ==============================================================================
//
// Two disconnected 4x10 quads (A: x in [0,4], B: x in [6,10]), gap x in [4,6].
// No shared edges -> connectIntLinks keeps them separate. A single off-mesh
// connection links (2,0,5) on A to (8,0,5) on B. The ONLY A->B route is the
// off-mesh con, so the corridor's straight path carries a corner flagged
// STRAIGHTPATH_OFFMESH_CONNECTION -> the trigger fires.

fn buildTwoQuadOffMeshNavMesh(allocator: std.mem.Allocator) !nav.detour.NavMesh {
    // cs = 0.1 -> world coords = cell / 10.
    // Quad A: x in [0,4], z in [0,10]   verts 0..3
    // Quad B: x in [6,10], z in [0,10]  verts 4..7
    const verts = [_]u16{
        0,   0, 0, // 0  (0,0)
        40,  0, 0, // 1  (4,0)
        40,  0, 100, // 2 (4,10)
        0,   0, 100, // 3 (0,10)
        60,  0, 0, // 4  (6,0)
        100, 0, 0, // 5  (10,0)
        100, 0, 100, // 6 (10,10)
        60,  0, 100, // 7 (6,10)
    };
    const nvp = 4;
    // Each quad is one 4-gon poly, with NO neighbor links between them.
    const polys = [_]u16{
        // poly 0 (quad A): verts 0,1,2,3 ; all border edges (no internal neighbor)
        0, 1, 2, 3,
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        // poly 1 (quad B): verts 4,5,6,7 ; all border edges
        4, 5, 6, 7,
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
    };
    const poly_flags = [_]u16{ 0x01, 0x01 };
    const poly_areas = [_]u8{ 0, 0 };

    // Off-mesh connection: start on quad A, end on quad B.
    const off_mesh_verts = [_]f32{
        2.0, 0.0, 5.0, // start (on A)
        8.0, 0.0, 5.0, // end   (on B)
    };
    const off_mesh_rad = [_]f32{0.6};
    const off_mesh_flags = [_]u16{0x01};
    const off_mesh_areas = [_]u8{0};
    const off_mesh_dir = [_]u8{1}; // bidirectional

    const params = nav.detour.NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 8,
        .polys = &polys,
        .poly_flags = &poly_flags,
        .poly_areas = &poly_areas,
        .poly_count = 2,
        .nvp = nvp,
        .off_mesh_con_verts = &off_mesh_verts,
        .off_mesh_con_rad = &off_mesh_rad,
        .off_mesh_con_flags = &off_mesh_flags,
        .off_mesh_con_areas = &off_mesh_areas,
        .off_mesh_con_dir = &off_mesh_dir,
        .off_mesh_con_count = 1,
        .bmin = .{ 0.0, 0.0, 0.0 },
        .bmax = .{ 10.0, 1.0, 10.0 },
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .cs = 0.1,
        .ch = 0.1,
        .build_bv_tree = true,
    };

    const data = try nav.detour.createNavMeshData(&params, allocator);
    errdefer allocator.free(data);

    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = 10.0,
        .tile_height = 10.0,
        .max_tiles = 1,
        .max_polys = 256,
    };
    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    const tile_flags = nav.detour.TileFlags{ .free_data = true };
    _ = try navmesh.addTile(data, tile_flags, 0);
    return navmesh;
}

test "Crowd off-mesh: end-to-end traversal across an off-mesh connection" {
    const allocator = testing.allocator;

    var navmesh = try buildTwoQuadOffMeshNavMesh(allocator);
    defer navmesh.deinit();

    // Header sanity: 2 mesh polys + 1 off-mesh poly; one off-mesh connection.
    {
        const tile = navmesh.getTileAt(0, 0, 0).?;
        try testing.expectEqual(@as(i32, 3), tile.header.?.poly_count);
        try testing.expectEqual(@as(i32, 1), tile.header.?.off_mesh_con_count);
    }

    var crowd = try nav.detour_crowd.Crowd.init(allocator, 4, 0.6, &navmesh);
    defer crowd.deinit();

    // Agent starts on quad A near the off-mesh start endpoint.
    const start_pos = [3]f32{ 2.0, 0.0, 5.0 };
    var ap = nav.detour_crowd.CrowdAgentParams.init();
    ap.radius = 0.3;
    ap.height = 2.0;
    ap.max_speed = 2.0;
    // Disable obstacle avoidance / separation noise (single agent anyway).
    ap.update_flags = nav.detour_crowd.UpdateFlags.optimize_vis | nav.detour_crowd.UpdateFlags.optimize_topo;
    const idx = try crowd.addAgent(&start_pos, &ap);
    try testing.expect(idx >= 0);
    const ui: usize = @intCast(idx);
    const ag = &crowd.agents[ui];
    try testing.expect(ag.state == .walking);

    // Target on quad B (far side of the link).
    const target_pos = [3]f32{ 9.0, 0.0, 5.0 };
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    var filter = nav.detour.QueryFilter.init();
    var target_ref: nav.detour.PolyRef = 0;
    var nearest_pt = [3]f32{ 0, 0, 0 };
    try crowd.navquery.findNearestPoly(&target_pos, &ext, &filter, &target_ref, &nearest_pt);
    try testing.expect(target_ref != 0);

    try testing.expect(crowd.requestMoveTarget(idx, target_ref, &nearest_pt));

    const dt: f32 = 0.1;
    var entered_offmesh = false;
    var saw_mid_lerp = false;
    var exited_to_walking = false;
    var max_x_during_offmesh: f32 = -1.0;

    var step: usize = 0;
    while (step < 400) : (step += 1) {
        const was_offmesh = ag.state == .offmesh;
        try crowd.update(dt);

        if (ag.state == .offmesh) {
            entered_offmesh = true;
            // While animating, npos must lie within the link's x-corridor [start,end].
            if (ag.npos[0] > 2.0 and ag.npos[0] < 8.0) saw_mid_lerp = true;
            max_x_during_offmesh = @max(max_x_during_offmesh, ag.npos[0]);
            // Velocity is forced to zero during off-mesh animation.
            try testing.expectApproxEqAbs(@as(f32, 0.0), nav.math.vlen(&ag.vel), 1e-5);
        }
        if (was_offmesh and ag.state == .walking) {
            exited_to_walking = true;
        }
        // Stop once the agent reached quad B and finished animating.
        if (exited_to_walking and ag.npos[0] > 6.0) break;
    }

    try testing.expect(entered_offmesh); // trigger fired -> .offmesh
    try testing.expect(saw_mid_lerp); // position interpolated across the link
    try testing.expect(exited_to_walking); // animation finished -> .walking
    // The off-mesh lerp carried the agent across the gap (x:[4,6]) toward quad B.
    try testing.expect(max_x_during_offmesh > 6.0);
    // Agent ended up on quad B (past the gap / off-mesh link).
    try testing.expect(ag.npos[0] > 6.0);
    try testing.expect(ag.state == .walking);
}
