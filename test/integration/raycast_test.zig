const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");
const obj_loader = @import("obj_loader");

// ==============================================================================
// TEST CASE PARSER
// ==============================================================================

const RaycastTest = struct {
    start: [3]f32,
    end: [3]f32,
    include_flags: u16,
    exclude_flags: u16,
};

fn parseRaycastTests(allocator: std.mem.Allocator, file_path: []const u8) !struct {
    mesh_file: []const u8,
    tests: []RaycastTest,
} {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var tests = std.ArrayList(RaycastTest).init(allocator);
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
        // Parse raycast test: "rc  x y z  x y z  flags flags"
        else if (std.mem.startsWith(u8, trimmed, "rc ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[3..], " \t");

            var test_case: RaycastTest = undefined;
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
    @memset(areas, 0); // Initialize as NULL_AREA

    // Mark walkable triangles
    nav.recast.filter.markWalkableTriangles(
        &ctx,
        config.walkable_slope_angle,
        mesh.vertices,
        mesh.indices,
        areas,
    );

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

    // Debug: Check areas before erode
    if (6612 < chf.span_count) {
        std.debug.print("[DEBUG Zig BEFORE erode] span 6612: area={d}\n", .{chf.areas[6612]});
    }
    if (6666 < chf.span_count) {
        std.debug.print("[DEBUG Zig BEFORE erode] span 6666: area={d}\n", .{chf.areas[6666]});
    }

    // Erode, build distance field and regions
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);

    // Debug: Check areas after erode
    if (6612 < chf.span_count) {
        std.debug.print("[DEBUG Zig AFTER erode] span 6612: area={d}\n", .{chf.areas[6612]});
    }
    if (6666 < chf.span_count) {
        std.debug.print("[DEBUG Zig AFTER erode] span 6666: area={d}\n", .{chf.areas[6666]});
    }

    // Debug: Check area value for span 34504 after erodeWalkableArea
    if (34504 < chf.span_count) {
        std.debug.print("[DEBUG after erodeWalkableArea] span 34504: area={d}\n", .{chf.areas[34504]});
    }

    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);
    std.debug.print("[DEBUG] Zig chf.max_regions: {d}\n", .{chf.max_regions});

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

    std.debug.print("[DEBUG] Contour count: {d}\n", .{cset.nconts});

    // Count valid contours and print details
    var valid_conts: usize = 0;
    var expected_tris: usize = 0;
    for (0..@intCast(cset.nconts)) |i| {
        const nverts = cset.conts[i].nverts;
        std.debug.print("[ZIG CONTOUR] {d}: nverts={d}, reg={d}, area={d}\n",
            .{i, nverts, cset.conts[i].reg, cset.conts[i].area});
        if (nverts >= 3) {
            valid_conts += 1;
            expected_tris += @as(usize, @intCast(nverts)) - 2;
        }
    }
    std.debug.print("[DEBUG] Valid contours (nverts>=3): {d}\n", .{valid_conts});
    std.debug.print("[DEBUG] Expected triangles: {d}\n", .{expected_tris});

    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        &cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );

    std.debug.print("[DEBUG] PolyMesh poly count: {d}\n", .{pmesh.npolys});

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
        .max_polys = 256,
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
// MAIN TEST FUNCTION
// ==============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zig Raycast Tests ===\n", .{});

    // Parse test cases
    const test_case_path = "E:/Projects/CS2/navMesh/movement/fullProject/recastnavigation/RecastDemo/Bin/TestCases/raycast_test.txt";
    const parsed = try parseRaycastTests(allocator, test_case_path);
    defer allocator.free(parsed.mesh_file);
    defer allocator.free(parsed.tests);

    std.debug.print("Found {d} raycast test cases\n", .{parsed.tests.len});
    std.debug.print("Mesh file: {s}\n\n", .{parsed.mesh_file});

    // Build navmesh
    const mesh_path = try std.fmt.allocPrint(
        allocator,
        "E:/Projects/CS2/navMesh/movement/fullProject/recastnavigation/RecastDemo/Bin/Meshes/{s}",
        .{parsed.mesh_file},
    );
    defer allocator.free(mesh_path);

    var nav_result = try buildNavMesh(allocator, mesh_path);
    defer nav_result.navmesh.deinit();
    defer allocator.free(nav_result.navmesh_data);

    std.debug.print("NavMesh built successfully\n", .{});

    // Debug BVH tree info
    const tile_result = nav_result.navmesh.getTileAt(0, 0, 0);
    if (tile_result) |tile| {
        std.debug.print("Poly count: {d}\n", .{tile.header.?.poly_count});
        std.debug.print("BVH tree nodes: {d}\n", .{tile.bv_tree.len});
        std.debug.print("Expected nodes: {d}\n", .{tile.header.?.poly_count * 2 - 1});
        if (tile.bv_tree.len > 293) {
            const node104 = &tile.bv_tree[293];
            std.debug.print("Node 293 (poly 104): i={d}, bmin=[{d},{d},{d}], bmax=[{d},{d},{d}]\n",
                .{node104.i, node104.bmin[0], node104.bmin[1], node104.bmin[2],
                  node104.bmax[0], node104.bmax[1], node104.bmax[2]});
        }
    }
    std.debug.print("\n", .{});

    // Create query
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&nav_result.navmesh, 2048);

    // Run tests
    const poly_pick_ext = [3]f32{ 2.0, 4.0, 2.0 };
    const path_buffer = try allocator.alloc(nav.detour.PolyRef, 256);
    defer allocator.free(path_buffer);

    for (parsed.tests, 0..) |test_case, i| {
        std.debug.print("Test {d}:\n", .{i + 1});
        std.debug.print("  Start: ({d:.6}, {d:.6}, {d:.6})\n", .{ test_case.start[0], test_case.start[1], test_case.start[2] });
        std.debug.print("  End:   ({d:.6}, {d:.6}, {d:.6})\n", .{ test_case.end[0], test_case.end[1], test_case.end[2] });
        std.debug.print("  Include: 0x{x:0>4}, Exclude: 0x{x:0>4}\n", .{ test_case.include_flags, test_case.exclude_flags });

        // Set up filter
        var filter = nav.detour.QueryFilter.init();
        filter.include_flags = test_case.include_flags;
        filter.exclude_flags = test_case.exclude_flags;

        // Find start polygon
        var start_ref: nav.detour.PolyRef = 0;
        var start_pos: [3]f32 = undefined;
        _ = try query.findNearestPoly(&test_case.start, &poly_pick_ext, &filter, &start_ref, &start_pos);

        if (start_ref == 0) {
            std.debug.print("  ERROR: Could not find start polygon\n\n", .{});
            continue;
        }

        std.debug.print("  Start poly: {d}\n", .{start_ref});
        std.debug.print("  Start pos from findNearestPoly: ({d:.6}, {d:.6}, {d:.6})\n", .{start_pos[0], start_pos[1], start_pos[2]});

        // Perform raycast
        var hit = nav.detour.RaycastHit.init(path_buffer);
        std.debug.print("  Calling raycast with start_ref={d}\n", .{start_ref});
        std.debug.print("  Using start_pos (not test.start) for raycast\n", .{});
        const status = try query.raycast(
            start_ref,
            &start_pos,  // Use corrected position from findNearestPoly
            &test_case.end,
            &filter,
            0,
            &hit,
            0,
        );

        std.debug.print("  Raycast status: failure={}, invalid_param={}\n", .{status.failure, status.invalid_param});
        if (status.failure) {
            std.debug.print("  ERROR: Raycast failed\n\n", .{});
            continue;
        }

        std.debug.print("  Hit t: {d:.6}\n", .{hit.t});
        std.debug.print("  Hit normal: ({d:.6}, {d:.6}, {d:.6})\n", .{ hit.hit_normal[0], hit.hit_normal[1], hit.hit_normal[2] });
        std.debug.print("  Hit edge: {d}\n", .{hit.hit_edge_index});
        std.debug.print("  Path cost: {d:.6}\n", .{hit.path_cost});
        std.debug.print("  Path count: {d}\n", .{hit.path_count});

        if (hit.path_count > 0) {
            std.debug.print("  Path polys:", .{});
            for (0..hit.path_count) |j| {
                std.debug.print(" {d}", .{hit.path[j]});
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("=== Tests Complete ===\n", .{});
}
