// Controlled correctness test for NavMeshQuery.findPath in two cases that a
// point-snapping benchmark flagged as diverging from upstream C++ Detour:
//
//   Case A: partial path to an UNREACHABLE goal (two disconnected regions).
//   Case B: avoiding a polygon excluded via QueryFilter.exclude_flags.
//
// The benchmark used findNearestPoly point-snapping + baseline-derived blocked
// refs, so a divergence there could be a harness artifact. This test removes
// that ambiguity entirely: it uses KNOWN poly refs derived directly from the
// tile (getPolyRefBase + poly index), never via point snapping. That makes the
// start/goal/blocked refs deterministic and unambiguous.
//
// Upstream reference (DetourNavMeshQuery.cpp dtNavMeshQuery::findPath):
//   - On an unreachable goal, A* drains the open list and the path is extracted
//     to `lastBestNode` (the closest reached poly), returning a NON-EMPTY
//     partial path that does NOT end at the goal (DT_PARTIAL_RESULT).
//   - passFilter() rejects polys whose flags intersect exclude_flags, so an
//     excluded poly is never expanded and is absent from the result.

const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

const MESH_NULL_IDX: u16 = 0xffff;

// ==============================================================================
// CASE A FIXTURE: two DISCONNECTED quads, no shared edge, NO off-mesh link.
// ==============================================================================
//
// Quad A: x in [0,4], z in [0,10]  (poly 0)  -- region A
// Quad B: x in [6,10], z in [0,10] (poly 1)  -- region B
// Gap x in [4,6], no shared vertices, no neighbor links, no off-mesh connection.
// => region B is UNREACHABLE from region A.

fn buildTwoDisconnectedQuads(allocator: std.mem.Allocator) !nav.detour.NavMesh {
    // cs = 0.1 -> world coords = cell / 10.
    const verts = [_]u16{
        0,   0, 0, // 0  (0,0)   quad A
        40,  0, 0, // 1  (4,0)
        40,  0, 100, // 2 (4,10)
        0,   0, 100, // 3 (0,10)
        60,  0, 0, // 4  (6,0)   quad B
        100, 0, 0, // 5  (10,0)
        100, 0, 100, // 6 (10,10)
        60,  0, 100, // 7 (6,10)
    };
    const nvp = 4;
    // Two 4-gon polys, NO neighbor links between them (all border edges).
    const polys = [_]u16{
        // poly 0 (quad A): verts 0,1,2,3
        0, 1, 2, 3,
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        // poly 1 (quad B): verts 4,5,6,7
        4, 5, 6, 7,
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
    };
    const poly_flags = [_]u16{ 0x01, 0x01 };
    const poly_areas = [_]u8{ 0, 0 };

    const params = nav.detour.NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 8,
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

test "findPath Case A: unreachable goal returns a PARTIAL path (not empty)" {
    const allocator = testing.allocator;

    var navmesh = try buildTwoDisconnectedQuads(allocator);
    defer navmesh.deinit();

    // Known refs taken DIRECTLY from the tile (no point snapping).
    const tile = navmesh.getTileAt(0, 0, 0).?;
    try testing.expectEqual(@as(i32, 2), tile.header.?.poly_count);
    const base = navmesh.getPolyRefBase(tile);
    const start_ref_a: nav.detour.PolyRef = base | 0; // poly 0 = region A
    const goal_ref_b: nav.detour.PolyRef = base | 1; // poly 1 = region B (unreachable)
    try testing.expect(start_ref_a != 0);
    try testing.expect(goal_ref_b != 0);
    try testing.expect(start_ref_a != goal_ref_b);

    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const filter = nav.detour.QueryFilter.init();

    // Interior points (only used for A* heuristics / costs, not for ref pick).
    const start_pos = [3]f32{ 2.0, 0.0, 5.0 }; // inside quad A
    const goal_pos = [3]f32{ 8.0, 0.0, 5.0 }; // inside quad B

    var path: [64]nav.detour.PolyRef = undefined;
    var path_count: usize = 0;
    try query.findPath(start_ref_a, goal_ref_b, &start_pos, &goal_pos, &filter, &path, &path_count);

    // --- DEFINITIVE ASSERTIONS (upstream partial-path semantics) ---
    // 1) Path is NON-EMPTY (a partial path, not 0). Empty => real divergence.
    try testing.expect(path_count > 0);
    // 2) Path starts at the start ref.
    try testing.expectEqual(start_ref_a, path[0]);
    // 3) Path does NOT reach the unreachable goal (it is partial).
    try testing.expect(path[path_count - 1] != goal_ref_b);
    // 4) For this fixture the closest reachable poly is the start itself
    //    (region A is a single poly), so the partial path is exactly [start].
    try testing.expectEqual(@as(usize, 1), path_count);
    try testing.expectEqual(start_ref_a, path[path_count - 1]);

    std.debug.print(
        "\n[Case A] unreachable goal: path_count={d} path[0]={d} last={d} goal={d} (partial, ends at closest reachable)\n",
        .{ path_count, path[0], path[path_count - 1], goal_ref_b },
    );
}

// ==============================================================================
// CASE B FIXTURE: a 2x3 grid (ladder) with a SHORT route and a DETOUR.
// ==============================================================================
//
// Columns x = 0,4,8,12 ; rows z = 0,4,8.
//   Top row  (z 0->4): A(0) - M(1) - C(2)
//   Bot row  (z 4->8): D(3) - E(4) - F(5)
// Vertical links: A-D, M-E, C-F. Horizontal links within each row.
//
// Two routes A -> C:
//   SHORT : A(0) -> M(1) -> C(2)              (3 polys)
//   DETOUR: A(0) -> D(3) -> E(4) -> F(5) -> C(2) (5 polys)
//
// Blocking M (exclude its flag) must force the detour and exclude M entirely.

fn buildLadderTwoRoute(allocator: std.mem.Allocator) !nav.detour.NavMesh {
    // cs = 0.1 -> world = cell / 10.  x: 0,40,80,120  z: 0,40,80
    const verts = [_]u16{
        // row z=0
        0,   0, 0, // 0  (0,0)
        40,  0, 0, // 1  (4,0)
        80,  0, 0, // 2  (8,0)
        120, 0, 0, // 3  (12,0)
        // row z=4
        0,   0, 40, // 4  (0,4)
        40,  0, 40, // 5  (4,4)
        80,  0, 40, // 6  (8,4)
        120, 0, 40, // 7  (12,4)
        // row z=8
        0,   0, 80, // 8  (0,8)
        40,  0, 80, // 9  (4,8)
        80,  0, 80, // 10 (8,8)
        120, 0, 80, // 11 (12,8)
    };
    const nvp = 4;

    // Edge convention for quad [p0,p1,p2,p3]:
    //   edge0: p0->p1 (bottom)  edge1: p1->p2 (right)
    //   edge2: p2->p3 (top)     edge3: p3->p0 (left)
    // IMPORTANT: NavMeshCreateParams.polys neighbor slots store RAW 0-based poly
    // indices; createNavMeshData adds the internal +1 itself (builder.zig:553).
    // Border edges use MESH_NULL_IDX (0xffff, has the 0x8000 portal bit).
    const polys = [_]u16{
        // poly 0  A = v0,v1,v5,v4   neis: e1->M(1), e2->D(3)
        0,  1,  5,  4,
        MESH_NULL_IDX, 1,             3,             MESH_NULL_IDX,
        // poly 1  M = v1,v2,v6,v5   neis: e1->C(2), e2->E(4), e3->A(0)
        1,  2,  6,  5,
        MESH_NULL_IDX, 2,             4,             0,
        // poly 2  C = v2,v3,v7,v6   neis: e2->F(5), e3->M(1)
        2,  3,  7,  6,
        MESH_NULL_IDX, MESH_NULL_IDX, 5,             1,
        // poly 3  D = v4,v5,v9,v8   neis: e0->A(0), e1->E(4)
        4,  5,  9,  8,
        0,             4,             MESH_NULL_IDX, MESH_NULL_IDX,
        // poly 4  E = v5,v6,v10,v9  neis: e0->M(1), e1->F(5), e3->D(3)
        5,  6,  10, 9,
        1,             5,             MESH_NULL_IDX, 3,
        // poly 5  F = v6,v7,v11,v10 neis: e0->C(2), e3->E(4)
        6,  7,  11, 10,
        2,             MESH_NULL_IDX, MESH_NULL_IDX, 4,
    };
    const poly_flags = [_]u16{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 };
    const poly_areas = [_]u8{ 0, 0, 0, 0, 0, 0 };

    const params = nav.detour.NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 12,
        .polys = &polys,
        .poly_flags = &poly_flags,
        .poly_areas = &poly_areas,
        .poly_count = 6,
        .nvp = nvp,
        .bmin = .{ 0.0, 0.0, 0.0 },
        .bmax = .{ 12.0, 1.0, 8.0 },
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
        .tile_width = 12.0,
        .tile_height = 8.0,
        .max_tiles = 1,
        .max_polys = 256,
    };
    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    const tile_flags = nav.detour.TileFlags{ .free_data = true };
    _ = try navmesh.addTile(data, tile_flags, 0);
    return navmesh;
}

fn pathContains(path: []const nav.detour.PolyRef, count: usize, ref: nav.detour.PolyRef) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (path[i] == ref) return true;
    }
    return false;
}

test "findPath Case B: exclude-flagged poly is avoided (detour taken)" {
    const allocator = testing.allocator;

    var navmesh = try buildLadderTwoRoute(allocator);
    defer navmesh.deinit();

    const tile = navmesh.getTileAt(0, 0, 0).?;
    try testing.expectEqual(@as(i32, 6), tile.header.?.poly_count);
    const base = navmesh.getPolyRefBase(tile);

    const ref_a: nav.detour.PolyRef = base | 0; // A  (start)
    const ref_m: nav.detour.PolyRef = base | 1; // M  (short-route middle, to be blocked)
    const ref_c: nav.detour.PolyRef = base | 2; // C  (goal)

    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    // Centers used only for cost/heuristic; refs are exact.
    const pos_a = [3]f32{ 2.0, 0.0, 2.0 }; // inside A
    const pos_c = [3]f32{ 10.0, 0.0, 2.0 }; // inside C

    // --- 1) Default filter: should take the SHORT route through M. ---
    var filter = nav.detour.QueryFilter.init();
    var path0: [64]nav.detour.PolyRef = undefined;
    var pc0: usize = 0;
    try query.findPath(ref_a, ref_c, &pos_a, &pos_c, &filter, &path0, &pc0);

    try testing.expect(pc0 > 0);
    try testing.expectEqual(ref_a, path0[0]);
    try testing.expectEqual(ref_c, path0[pc0 - 1]); // reached the goal
    try testing.expect(pathContains(&path0, pc0, ref_m)); // short route uses M
    try testing.expectEqual(@as(usize, 3), pc0); // A -> M -> C

    // --- 2) Exclude M's flag: must AVOID M and take the DETOUR. ---
    // Flag M with a bit and exclude that bit from the filter.
    const block_flag: u16 = 0x8000;
    const orig_flags = try navmesh.getPolyFlags(ref_m);
    try navmesh.setPolyFlags(ref_m, orig_flags | block_flag);
    filter.exclude_flags = block_flag;

    var path1: [64]nav.detour.PolyRef = undefined;
    var pc1: usize = 0;
    try query.findPath(ref_a, ref_c, &pos_a, &pos_c, &filter, &path1, &pc1);

    // --- DEFINITIVE ASSERTIONS (passFilter / exclude semantics) ---
    try testing.expect(pc1 > 0);
    try testing.expectEqual(ref_a, path1[0]);
    try testing.expectEqual(ref_c, path1[pc1 - 1]); // still reaches goal via detour
    try testing.expect(!pathContains(&path1, pc1, ref_m)); // M is AVOIDED
    try testing.expect(pc1 != pc0 or !std.mem.eql(nav.detour.PolyRef, path0[0..pc0], path1[0..pc1])); // path changed
    try testing.expectEqual(@as(usize, 5), pc1); // A -> D -> E -> F -> C detour

    std.debug.print(
        "\n[Case B] short route pc={d}  detour-after-exclude pc={d}  M-in-detour={}\n",
        .{ pc0, pc1, pathContains(&path1, pc1, ref_m) },
    );
}

test "findPath Case B (no alternative): blocking the ONLY route yields a partial path avoiding M" {
    const allocator = testing.allocator;

    var navmesh = try buildLadderTwoRoute(allocator);
    defer navmesh.deinit();

    const tile = navmesh.getTileAt(0, 0, 0).?;
    const base = navmesh.getPolyRefBase(tile);
    const ref_a: nav.detour.PolyRef = base | 0; // A
    const ref_m: nav.detour.PolyRef = base | 1; // M
    const ref_c: nav.detour.PolyRef = base | 2; // C
    const ref_d: nav.detour.PolyRef = base | 3; // D (detour entry from A)
    const ref_f: nav.detour.PolyRef = base | 5; // F (detour entry into C)

    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(&navmesh, 2048);

    const pos_a = [3]f32{ 2.0, 0.0, 2.0 };
    const pos_c = [3]f32{ 10.0, 0.0, 2.0 };

    // Block EVERY poly adjacent to C except via M: i.e. block both M and F so the
    // only edges into goal C are gone. C becomes unreachable -> partial path,
    // and it must never include the blocked M.
    const block_flag: u16 = 0x8000;
    try navmesh.setPolyFlags(ref_m, (try navmesh.getPolyFlags(ref_m)) | block_flag);
    try navmesh.setPolyFlags(ref_f, (try navmesh.getPolyFlags(ref_f)) | block_flag);

    var filter = nav.detour.QueryFilter.init();
    filter.exclude_flags = block_flag;

    var path: [64]nav.detour.PolyRef = undefined;
    var pc: usize = 0;
    try query.findPath(ref_a, ref_c, &pos_a, &pos_c, &filter, &path, &pc);

    // C is now unreachable (both M and F excluded). Expect a clean PARTIAL path:
    try testing.expect(pc > 0); // non-empty
    try testing.expectEqual(ref_a, path[0]); // starts at A
    try testing.expect(path[pc - 1] != ref_c); // does not reach goal
    try testing.expect(!pathContains(&path, pc, ref_m)); // excluded M never used
    try testing.expect(!pathContains(&path, pc, ref_f)); // excluded F never used
    // Reachable set from A without M/F is {A, D, E}; the closest-to-goal reachable
    // poly is D or E, so the partial path stays within that set.
    _ = ref_d;

    std.debug.print(
        "\n[Case B/no-alt] partial pc={d} last={d} goal={d} M-used={} F-used={}\n",
        .{ pc, path[pc - 1], ref_c, pathContains(&path, pc, ref_m), pathContains(&path, pc, ref_f) },
    );
}
