const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");
const obj_loader = @import("obj_loader");

// ==============================================================================
// TEST CASE PARSER
// ==============================================================================

const PathfindTest = struct {
    start: [3]f32,
    end: [3]f32,
    include_flags: u16,
    exclude_flags: u16,
};

fn parseTestCases(allocator: std.mem.Allocator, file_path: []const u8) !struct {
    mesh_file: []const u8,
    tests: []PathfindTest,
} {
    const content = try obj_loader.readWholeFile(file_path, allocator);
    defer allocator.free(content);

    var tests = std.array_list.Managed(PathfindTest).init(allocator);
    errdefer tests.deinit();

    var mesh_file: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Parse mesh file: "f nav_test.obj"
        if (std.mem.startsWith(u8, trimmed, "f ")) {
            const filename = std.mem.trim(u8, trimmed[2..], " \t");
            mesh_file = try allocator.dupe(u8, filename);
        }
        // Parse pathfinding test: "pf  x y z  x y z  flags flags"
        else if (std.mem.startsWith(u8, trimmed, "pf ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[3..], " \t");

            var test_case: PathfindTest = undefined;
            var i: usize = 0;

            while (parts.next()) |part| : (i += 1) {
                switch (i) {
                    0 => test_case.start[0] = try std.fmt.parseFloat(f32, part),
                    1 => test_case.start[1] = try std.fmt.parseFloat(f32, part),
                    2 => test_case.start[2] = try std.fmt.parseFloat(f32, part),
                    3 => test_case.end[0] = try std.fmt.parseFloat(f32, part),
                    4 => test_case.end[1] = try std.fmt.parseFloat(f32, part),
                    5 => test_case.end[2] = try std.fmt.parseFloat(f32, part),
                    6 => test_case.include_flags = try std.fmt.parseInt(u16, part, 0),
                    7 => test_case.exclude_flags = try std.fmt.parseInt(u16, part, 0),
                    else => break,
                }
            }

            try tests.append(test_case);
        }
    }

    if (mesh_file == null) {
        return error.NoMeshFile;
    }

    return .{
        .mesh_file = mesh_file.?,
        .tests = try tests.toOwnedSlice(),
    };
}

// ==============================================================================
// NAVMESH BUILDER (from Recast to Detour)
// ==============================================================================

fn buildNavMesh(
    allocator: std.mem.Allocator,
    mesh_path: []const u8,
) !struct {
    navmesh: nav.detour.NavMesh,
    navmesh_data: []const u8,
} {
    var ctx = nav.Context.init(allocator);

    // Load mesh
    var mesh = try obj_loader.loadObj(mesh_path, allocator);
    defer mesh.deinit();

    // Configure Recast
    var config = nav.RecastConfig{
        .cs = 0.3,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 20,
        .walkable_climb = 9,
        .walkable_radius = 2,
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
        .bmin = nav.Vec3.zero(),
        .bmax = nav.Vec3.zero(),
    };

    // Calculate bounds
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();

    const verts_vec3 = try allocator.alloc(nav.Vec3, mesh.vertex_count);
    defer allocator.free(verts_vec3);
    for (0..mesh.vertex_count) |i| {
        verts_vec3[i] = nav.Vec3.init(
            mesh.vertices[i * 3 + 0],
            mesh.vertices[i * 3 + 1],
            mesh.vertices[i * 3 + 2],
        );
    }

    nav.RecastConfig.calcBounds(verts_vec3, &bmin, &bmax);
    config.bmin = bmin;
    config.bmax = bmax;

    // Calculate grid size
    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

    // Build heightfield
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

    // Rasterize triangles
    const areas = try allocator.alloc(u8, mesh.tri_count);
    defer allocator.free(areas);
    @memset(areas, 1);

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        mesh.vertices,
        mesh.indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

    // Filter
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    // Build compact heightfield
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

    // Erode, build distance field and regions
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    // Build contours
    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();

    try nav.recast.contour.buildContours(
        &ctx,
        &chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        nav.recast.config.CONTOUR_TESS_WALL_EDGES,
        allocator,
    );

    // Build polygon mesh
    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();

    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        &cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );

    // Build detail mesh
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

    // Create NavMesh
    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // Walkable

    const navmesh_params = nav.detour.NavMeshCreateParams{
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
    };

    const navmesh_data = try nav.detour.createNavMeshData(&navmesh_params, allocator);

    // Initialize NavMesh
    const nm_params = nav.detour.NavMeshParams{
        .orig = bmin,
        .tile_width = bmax.x - bmin.x,
        .tile_height = bmax.z - bmin.z,
        .max_tiles = 1,
        .max_polys = @intCast(pmesh.npolys), // 1:1 dtNavMesh::init(data) DetourNavMesh.cpp:285 = header->polyCount
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);

    // Add tile
    const tile_flags = nav.detour.TileFlags{ .free_data = false };
    _ = try navmesh.addTile(navmesh_data, tile_flags, 0);

    return .{
        .navmesh = navmesh,
        .navmesh_data = navmesh_data,
    };
}

// ==============================================================================
// PATHFINDING TEST
// ==============================================================================

test "Pathfinding: nav_mesh_test.txt reference tests" {
    const allocator = testing.allocator;

    // Parse test cases
    const test_data = try parseTestCases(allocator, "E:/Projects/CS2/navMesh/movement/fullProject/recastnavigation/RecastDemo/Bin/TestCases/nav_mesh_test.txt");
    defer allocator.free(test_data.mesh_file);
    defer allocator.free(test_data.tests);

    std.debug.print("\n=== Pathfinding Tests: {s} ===\n", .{test_data.mesh_file});
    std.debug.print("Found {d} test cases\n\n", .{test_data.tests.len});

    // Build navmesh
    const mesh_path = try std.fmt.allocPrint(allocator, "test_data/{s}", .{test_data.mesh_file});
    defer allocator.free(mesh_path);

    var navmesh_result = try buildNavMesh(allocator, mesh_path);
    defer navmesh_result.navmesh.deinit();
    defer allocator.free(navmesh_result.navmesh_data);

    // Create query
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&navmesh_result.navmesh, 2048);

    // Run tests
    const poly_pick_ext = [3]f32{ 2.0, 4.0, 2.0 };
    const max_path_polys = 256;

    var path_buffer = try allocator.alloc(nav.detour.PolyRef, max_path_polys);
    defer allocator.free(path_buffer);

    for (test_data.tests, 0..) |test_case, i| {
        std.debug.print("[TEST {d}] Finding path from ({d:.2}, {d:.2}, {d:.2}) to ({d:.2}, {d:.2}, {d:.2})\n", .{
            i + 1,
            test_case.start[0],
            test_case.start[1],
            test_case.start[2],
            test_case.end[0],
            test_case.end[1],
            test_case.end[2],
        });

        // Find nearest polys
        const filter = nav.detour.QueryFilter.init();

        var start_ref: nav.detour.PolyRef = 0;
        var start_pos: [3]f32 = undefined;
        _ = try query.findNearestPoly(&test_case.start, &poly_pick_ext, &filter, &start_ref, &start_pos);

        var end_ref: nav.detour.PolyRef = 0;
        var end_pos: [3]f32 = undefined;
        _ = try query.findNearestPoly(&test_case.end, &poly_pick_ext, &filter, &end_ref, &end_pos);

        // Debug TEST 13 - check if poly 367 is in candidates
        if (i == 12) {
            std.debug.print("  [DEBUG] Input start: ({d:.6}, {d:.6}, {d:.6})\n", .{ test_case.start[0], test_case.start[1], test_case.start[2] });

            // Query polys to see candidates
            var polys_debug: [128]nav.detour.PolyRef = undefined;
            var poly_count_debug: usize = 0;
            _ = query.queryPolygons(&test_case.start, &poly_pick_ext, &filter, &polys_debug, &poly_count_debug) catch 0;

            std.debug.print("  [DEBUG] queryPolygons returned {d} candidates\n", .{poly_count_debug});
            var found_367 = false;
            var found_623 = false;
            for (0..poly_count_debug) |idx| {
                if (polys_debug[idx] == 367) found_367 = true;
                if (polys_debug[idx] == 623) found_623 = true;
            }
            std.debug.print("  [DEBUG] Contains poly 367 (C++ result): {}\n", .{found_367});
            std.debug.print("  [DEBUG] Contains poly 623 (Zig result): {}\n", .{found_623});

            std.debug.print("  [DEBUG] Found start_pos: ({d:.6}, {d:.6}, {d:.6})\n", .{ start_pos[0], start_pos[1], start_pos[2] });
            std.debug.print("  [DEBUG] start_ref: {d}\n", .{start_ref});
        }

        if (start_ref == 0 or end_ref == 0) {
            std.debug.print("  [FAIL] Could not find start/end poly\n\n", .{});
            continue;
        }

        // Find path
        var path_count: usize = 0;
        const status = try query.findPath(
            start_ref,
            end_ref,
            &start_pos,
            &end_pos,
            &filter,
            path_buffer,
            &path_count,
        );

        std.debug.print("  Status: {any}, Path length: {d} polys\n", .{ status, path_count });

        // Find straight path
        if (path_count > 0) {
            const straight_path = try allocator.alloc(f32, max_path_polys * 3);
            defer allocator.free(straight_path);

            const straight_path_flags = try allocator.alloc(u8, max_path_polys);
            defer allocator.free(straight_path_flags);

            const straight_path_refs = try allocator.alloc(nav.detour.PolyRef, max_path_polys);
            defer allocator.free(straight_path_refs);

            var straight_path_count: usize = 0;

            _ = try query.findStraightPath(
                &start_pos,
                &end_pos,
                path_buffer[0..path_count],
                straight_path,
                straight_path_flags,
                straight_path_refs,
                &straight_path_count,
                0,
            );

            std.debug.print("  Waypoints: {d}\n", .{straight_path_count});

            // Print first 5 waypoints
            const print_count = @min(straight_path_count, 5);
            for (0..print_count) |j| {
                std.debug.print("    [{d}] ({d:.2}, {d:.2}, {d:.2})\n", .{
                    j,
                    straight_path[j * 3 + 0],
                    straight_path[j * 3 + 1],
                    straight_path[j * 3 + 2],
                });
            }
            if (straight_path_count > 5) {
                std.debug.print("    ... ({d} more waypoints)\n", .{straight_path_count - 5});
            }
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("=== Completed {d} pathfinding tests ===\n", .{test_data.tests.len});
}

test "REPRO Crowd: multi-poly stuck" {
    const allocator = testing.allocator;
    var navmesh_result = try buildNavMesh(allocator, "test_data/nav_test.obj");
    defer navmesh_result.navmesh.deinit();
    defer allocator.free(navmesh_result.navmesh_data);

    const dc = nav.detour_crowd;
    var crowd = try dc.Crowd.init(allocator, 32, 0.6, &navmesh_result.navmesh);
    defer crowd.deinit();

    var p = dc.CrowdAgentParams.init();
    p.radius = 0.6;
    p.height = 2.0;
    p.max_speed = 3.5;
    p.max_acceleration = 8.0;
    p.update_flags = dc.UpdateFlags.all | dc.UpdateFlags.optimize_topo; // как demo

    var filter = nav.detour.QueryFilter.init();
    const ext = [3]f32{ 2, 4, 2 };

    const start_w = [3]f32{ 18.138550, -2.370003, -21.319118 };
    const target_w = [3]f32{ -19.206181, -2.369133, 24.802742 };

    var sref: nav.detour.PolyRef = 0;
    var ssnap: [3]f32 = undefined;
    try crowd.navquery.findNearestPoly(&start_w, &ext, &filter, &sref, &ssnap);
    var tref: nav.detour.PolyRef = 0;
    var tsnap: [3]f32 = undefined;
    try crowd.navquery.findNearestPoly(&target_w, &ext, &filter, &tref, &tsnap);
    std.debug.print("\n[RC] sref={} tref={} ssnap=({d:.2},{d:.2},{d:.2}) tsnap=({d:.2},{d:.2},{d:.2})\n", .{ sref, tref, ssnap[0], ssnap[1], ssnap[2], tsnap[0], tsnap[1], tsnap[2] });

    {
        var path512: [256]nav.detour.PolyRef = undefined;
        var n512: usize = 0;
        const st512 = crowd.navquery.findPath(sref, tref, &ssnap, &tsnap, &filter, path512[0..], &n512);
        std.debug.print("[RC] findPath@512: status={any} npath={d} last={} (target={})\n", .{ st512, n512, if (n512 > 0) path512[n512 - 1] else 0, tref });
        var q2 = try nav.detour.NavMeshQuery.init(allocator);
        defer q2.deinit();
        try q2.initQuery(&navmesh_result.navmesh, 2048);
        // findNearestPoly target через q2 + разные ext
        inline for (.{ [3]f32{ 2, 4, 2 }, [3]f32{ 4, 8, 4 }, [3]f32{ 10, 20, 10 } }) |e| {
            var tr2: nav.detour.PolyRef = 0;
            var ts2: [3]f32 = undefined;
            q2.findNearestPoly(&target_w, &e, &filter, &tr2, &ts2) catch {};
            // queryPolygons count в этом боксе
            var qp: [256]nav.detour.PolyRef = undefined;
            var qpc: usize = 0;
            _ = q2.queryPolygons(&target_w, &e, &filter, &qp, &qpc) catch {};
            std.debug.print("[RC] q2 findNearestPoly ext={d}: ref={} snap=({d:.2},{d:.2},{d:.2}) qpolys={d}\n", .{ e[0], tr2, ts2[0], ts2[1], ts2[2], qpc });
        }
        {
            const r = navmesh_result.navmesh.getTileAndPolyByRef(sref) catch unreachable;
            const h = r.tile.header.?;
            std.debug.print("[RC] header bmin=({d:.2},{d:.2},{d:.2}) bmax=({d:.2},{d:.2},{d:.2}) qfac={d:.4} (1/cs={d:.4}) bvNodes={d}\n", .{ h.bmin.x, h.bmin.y, h.bmin.z, h.bmax.x, h.bmax.y, h.bmax.z, h.bv_quant_factor, @as(f32, 1.0 / 0.3), r.tile.bv_tree.len });
            std.debug.print("[RC] poly_count={d} vert_count={d}\n", .{ h.poly_count, h.vert_count });
        }
        {
            // БРУТФОРС: истинно ближайший полигон к target по всем полигонам тайла.
            const r = navmesh_result.navmesh.getTileAndPolyByRef(sref) catch unreachable;
            const base = navmesh_result.navmesh.getPolyRefBase(r.tile);
            const pc: usize = @intCast(r.tile.header.?.poly_count);
            var best_ref: nav.detour.PolyRef = 0;
            var best_d: f32 = std.math.floatMax(f32);
            var best_pt: [3]f32 = .{ 0, 0, 0 };
            for (0..pc) |pi| {
                const ref = base | @as(nav.detour.PolyRef, @intCast(pi));
                var cp: [3]f32 = undefined;
                var over: bool = false;
                _ = q2.closestPointOnPoly(ref, &target_w, &cp, &over) catch continue;
                const dxx = cp[0] - target_w[0];
                const dzz = cp[2] - target_w[2];
                const d = dxx * dxx + dzz * dzz;
                if (d < best_d) {
                    best_d = d;
                    best_ref = ref;
                    best_pt = cp;
                }
            }
            std.debug.print("[RC] BRUTE nearest to target: ref={} pt=({d:.2},{d:.2},{d:.2}) dist2D={d:.3}\n", .{ best_ref, best_pt[0], best_pt[1], best_pt[2], @sqrt(best_d) });
        }
        var path2k: [256]nav.detour.PolyRef = undefined;
        var n2k: usize = 0;
        const st2k = q2.findPath(sref, tref, &ssnap, &tsnap, &filter, path2k[0..], &n2k);
        std.debug.print("[RC] findPath@2048: status={any} npath={d} last={} (target={})\n", .{ st2k, n2k, if (n2k > 0) path2k[n2k - 1] else 0, tref });
    }

    {
        // BFS по линкам навмеша от sref — сколько полигонов достижимо и виден ли tref.
        const NM = &navmesh_result.navmesh;
        var visited = std.AutoHashMap(nav.detour.PolyRef, void).init(allocator);
        defer visited.deinit();
        var queue: [4096]nav.detour.PolyRef = undefined;
        var qn: usize = 0;
        queue[qn] = sref;
        qn += 1;
        try visited.put(sref, {});
        var qi: usize = 0;
        var reached_target = false;
        while (qi < qn) : (qi += 1) {
            const cur = queue[qi];
            const r = NM.getTileAndPolyByRef(cur) catch continue;
            var li = r.poly.first_link;
            while (li != 0xffffffff) {
                const link = r.tile.links[li];
                li = link.next;
                if (link.ref == 0) continue;
                if (link.ref == tref) reached_target = true;
                if (visited.contains(link.ref)) continue;
                try visited.put(link.ref, {});
                if (qn < queue.len) {
                    queue[qn] = link.ref;
                    qn += 1;
                }
            }
        }
        std.debug.print("[RC] BFS from {}: reachable={d} polys, target {} reachable={}\n", .{ sref, visited.count(), tref, reached_target });
        // степень самого sref
        const r0 = NM.getTileAndPolyByRef(sref) catch unreachable;
        var deg: usize = 0;
        var l0 = r0.poly.first_link;
        std.debug.print("[RC] poly {} neighbors:", .{sref});
        while (l0 != 0xffffffff) {
            const lk = r0.tile.links[l0];
            l0 = lk.next;
            if (lk.ref == 0) continue;
            deg += 1;
            std.debug.print(" {}", .{lk.ref});
        }
        std.debug.print("  (deg={d}, vertCount={d})\n", .{ deg, r0.poly.vert_count });
    }

    const idx = try crowd.addAgent(&ssnap, &p);
    const ag = &crowd.agents[@intCast(idx)];
    _ = crowd.requestMoveTarget(idx, tref, &tsnap);

    const dt: f32 = 1.0 / 30.0;
    var reached = false;
    for (0..600) |s| {
        try crowd.update(dt);
        const dgoal = nav.math.vdist2D(&ag.npos, &tsnap);
        if (s % 100 == 0) {
            std.debug.print("[RC] step {d:3}: npos=({d:.2},{d:.2}) pc={d} dist_to_goal={d:.2}\n", .{ s, ag.npos[0], ag.npos[2], ag.corridor.getPathCount(), dgoal });
        }
        if (dgoal < ag.params.radius * 2.0) {
            reached = true;
            std.debug.print("[RC] REACHED goal at step {d}, dist={d:.2}\n", .{ s, dgoal });
            break;
        }
    }
    const moved = nav.math.vdist(&ag.npos, &ssnap);
    std.debug.print("[RC] total moved = {d:.3} reached={}\n", .{ moved, reached });
    try std.testing.expect(reached);
}
