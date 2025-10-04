const std = @import("std");
const nav = @import("zig-recast");

const BenchConfig = struct {
    iterations: usize = 100,
    warmup_iterations: usize = 10,
    inner_iterations: usize = 10000,
};

const BenchResult = struct {
    name: []const u8,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    iterations: usize,
    path_points_avg: f64,

    pub fn print(self: BenchResult) void {
        std.debug.print("{s:<50} | Avg: {d:>6} ns | Min: {d:>6} ns | Max: {d:>6} ns | Points: {d:.1}\n", .{
            self.name,
            self.avg_time_ns,
            self.min_time_ns,
            self.max_time_ns,
            self.path_points_avg,
        });
    }
};

fn createTestNavMesh(allocator: std.mem.Allocator, grid_size: usize) !struct {
    navmesh: *nav.detour.NavMesh,
    query: *nav.detour.NavMeshQuery,
} {

    // Create grid EXACTLY like C++ Bench_Detour.cpp
    // (which is what actually runs, not Bench_Detour_Detailed.cpp)
    // Uses 4 vertices per quad + height variation
    const cell_size: f32 = 1.0;
    var temp_verts = std.array_list.Managed(nav.Vec3).init(allocator);
    defer temp_verts.deinit();
    var temp_indices = std.array_list.Managed(i32).init(allocator);
    defer temp_indices.deinit();

    for (0..grid_size - 1) |z| {
        for (0..grid_size - 1) |x| {
            // Skip cells to create obstacles (every 5th cell) - EXACT C++ logic
            if ((x % 5 == 2 or z % 5 == 2) and (x > 5 and x < grid_size - 5 and z > 5 and z < grid_size - 5)) {
                continue; // Create obstacle
            }

            const fx = @as(f32, @floatFromInt(x)) * cell_size;
            const fz = @as(f32, @floatFromInt(z)) * cell_size;
            const fx1 = fx + cell_size;
            const fz1 = fz + cell_size;
            const fy = @as(f32, @floatFromInt((x + z) % 3)) * 0.01;

            const base_idx: i32 = @intCast(temp_verts.items.len);

            // Add 4 vertices for this cell
            try temp_verts.append(nav.Vec3.init(fx, fy, fz));
            try temp_verts.append(nav.Vec3.init(fx1, fy, fz));
            try temp_verts.append(nav.Vec3.init(fx1, fy, fz1));
            try temp_verts.append(nav.Vec3.init(fx, fy, fz1));

            // Triangle 1
            try temp_indices.append(base_idx + 0);
            try temp_indices.append(base_idx + 1);
            try temp_indices.append(base_idx + 2);

            // Triangle 2
            try temp_indices.append(base_idx + 0);
            try temp_indices.append(base_idx + 2);
            try temp_indices.append(base_idx + 3);
        }
    }

    const vertices = temp_verts.items;
    const triangles = temp_indices.items;
    const vertex_count = vertices.len;
    const triangle_count = triangles.len / 3;

    std.debug.print("[GEOM] vertexCount={}, triangleCount={}\n", .{vertex_count, triangle_count});

    // Build NavMesh through Recast - match C++ exactly
    var config = nav.RecastConfig{
        .width = 0,
        .height = 0,
        .tile_size = 0,
        .border_size = 0, // C++ doesn't set this explicitly, defaults to 0
        .cs = 0.3,
        .ch = 0.2,
        .bmin = nav.math.Vec3.init(0, 0, 0),
        .bmax = nav.math.Vec3.init(0, 0, 0),
        .walkable_slope_angle = 45.0,
        .walkable_height = 20,
        .walkable_climb = 9,
        .walkable_radius = 2, // Match C++ Bench_Detour.cpp (NOT Detailed!)
        .max_edge_len = 12,
        .max_simplification_error = 1.3,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
    };

    nav.RecastConfig.calcBounds(vertices, &config.bmin, &config.bmax);
    nav.RecastConfig.calcGridSize(config.bmin, config.bmax, config.cs, &config.width, &config.height);

    const ctx = nav.Context.init(allocator);

    var hf = try nav.recast.Heightfield.init(allocator, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch);
    defer hf.deinit();

    var verts_f32 = try allocator.alloc(f32, vertex_count * 3);
    defer allocator.free(verts_f32);
    for (vertices, 0..) |v, i| {
        verts_f32[i * 3 + 0] = v.x;
        verts_f32[i * 3 + 1] = v.y;
        verts_f32[i * 3 + 2] = v.z;
    }

    const areas = try allocator.alloc(u8, triangle_count);
    defer allocator.free(areas);
    @memset(areas, 1);

    try nav.recast.rasterization.rasterizeTriangles(&ctx, verts_f32, triangles, areas, &hf, config.walkable_climb);
    std.debug.print("[DEBUG] After rasterization: {} spans in heightfield\n", .{hf.getSpanCount()});

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try nav.CompactHeightfield.init(allocator, config.width, config.height, @intCast(span_count), config.walkable_height, config.walkable_climb, config.bmin, config.bmax, config.cs, config.ch, config.border_size);
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(&ctx, config.walkable_height, config.walkable_climb, &hf, &chf);
    std.debug.print("[DEBUG] After buildCompactHeightfield: span_count={}\n", .{chf.span_count});

    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);

    // Count walkable spans after erosion
    var walkable_count: usize = 0;
    for (chf.areas) |area| {
        if (area != 0) walkable_count += 1;
    }
    std.debug.print("[DEBUG] After erodeWalkableArea: walkable_radius={}, walkable_spans={}\n", .{config.walkable_radius, walkable_count});

    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);
    std.debug.print("[DEBUG] After buildRegions: max_regions={}\n", .{chf.max_regions});

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, config.max_simplification_error, config.max_edge_len, &cset, 0, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, allocator);

    std.debug.print("[DEBUG] After buildPolyMesh: npolys={}, nverts={}\n", .{pmesh.npolys, pmesh.nverts});

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, config.detail_sample_dist, config.detail_sample_max_error, &dmesh, allocator);

    // Create NavMesh
    const nm_params = nav.NavMeshParams{
        .orig = config.bmin,
        .tile_width = @as(f32, @floatFromInt(config.width)) * config.cs,
        .tile_height = @as(f32, @floatFromInt(config.height)) * config.cs,
        .max_tiles = 1,
        .max_polys = 512,
    };
    const navmesh = try allocator.create(nav.NavMesh);
    navmesh.* = try nav.NavMesh.init(allocator, nm_params);

    var navmesh_create_params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = pmesh.flags,
        .poly_areas = pmesh.areas,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
        .walkable_height = @floatFromInt(config.walkable_height),
        .walkable_radius = @floatFromInt(config.walkable_radius),
        .walkable_climb = @floatFromInt(config.walkable_climb),
        .bmin = config.bmin.toArray(),
        .bmax = config.bmax.toArray(),
        .cs = config.cs,
        .ch = config.ch,
        .build_bv_tree = true,
        .off_mesh_con_verts = &[_]f32{},
        .off_mesh_con_rad = &[_]f32{},
        .off_mesh_con_flags = &[_]u16{},
        .off_mesh_con_areas = &[_]u8{},
        .off_mesh_con_dir = &[_]u8{},
        .off_mesh_con_user_id = &[_]u32{},
        .off_mesh_con_count = 0,
        .user_id = 0,
        .tile_x = 0,
        .tile_y = 0,
        .tile_layer = 0,
    };

    const navmesh_data = try nav.detour.createNavMeshData(&navmesh_create_params, allocator);
    _ = try navmesh.addTile(navmesh_data, .{ .free_data = true }, 0);

    const query = try nav.NavMeshQuery.init(allocator);
    try query.initQuery(navmesh, 2048);

    return .{ .navmesh = navmesh, .query = query };
}

fn benchmarkFindStraightPath(
    name: []const u8,
    query: *nav.detour.NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    config: BenchConfig,
    allocator: std.mem.Allocator,
) !BenchResult {
    const filter = nav.detour.QueryFilter.init();

    // Find path first
    var start_ref: u32 = undefined;
    var start_pt: [3]f32 = undefined;
    const extents = [3]f32{ 2.0, 4.0, 2.0 };
    _ = try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, &start_pt);

    var end_ref: u32 = undefined;
    var end_pt: [3]f32 = undefined;
    _ = try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, &end_pt);

    var path = try allocator.alloc(u32, 256);
    defer allocator.free(path);
    var path_count: usize = 0;
    _ = try query.findPath(start_ref, end_ref, &start_pt, &end_pt, &filter, path, &path_count);

    if (path_count == 0) {
        return error.NoPath;
    }

    // Prepare output buffers
    const straight_path = try allocator.alloc(f32, 256 * 3);
    defer allocator.free(straight_path);
    const straight_path_flags = try allocator.alloc(u8, 256);
    defer allocator.free(straight_path_flags);
    const straight_path_refs = try allocator.alloc(u32, 256);
    defer allocator.free(straight_path_refs);

    var timer = try std.time.Timer.start();

    // Warmup
    {
        var i: usize = 0;
        while (i < config.warmup_iterations) : (i += 1) {
            var j: usize = 0;
            while (j < config.inner_iterations) : (j += 1) {
                var sp_count: usize = 0;
                _ = try query.findStraightPath(&start_pt, &end_pt, path[0..path_count], straight_path, straight_path_flags, straight_path_refs, &sp_count, 0);
            }
        }
    }

    // Benchmark
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    var total_time: u64 = 0;
    var total_points: usize = 0;

    {
        var i: usize = 0;
        while (i < config.iterations) : (i += 1) {
            timer.reset();

            var j: usize = 0;
            while (j < config.inner_iterations) : (j += 1) {
                var sp_count: usize = 0;
                _ = try query.findStraightPath(&start_pt, &end_pt, path[0..path_count], straight_path, straight_path_flags, straight_path_refs, &sp_count, 0);
                if (j == 0) total_points += sp_count;
            }

            const elapsed = timer.read();
            const per_call = elapsed / config.inner_iterations;

            min_time = @min(min_time, per_call);
            max_time = @max(max_time, per_call);
            total_time += per_call;
        }
    }

    return BenchResult{
        .name = name,
        .avg_time_ns = total_time / config.iterations,
        .min_time_ns = min_time,
        .max_time_ns = max_time,
        .iterations = config.iterations,
        .path_points_avg = @as(f64, @floatFromInt(total_points)) / @as(f64, @floatFromInt(config.iterations)),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leaked!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          DETAILED findStraightPath PERFORMANCE ANALYSIS                                         ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const config = BenchConfig{};

    // Test on 50x50 grid (matching C++ benchmark)
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  50x50 NAVMESH (matching C++ benchmark)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const test_data = try createTestNavMesh(allocator, 50);
    defer allocator.destroy(test_data.navmesh);
    defer test_data.navmesh.deinit();
    defer test_data.query.deinit();

    // Test scenarios
    const scenarios = [_]struct {
        name: []const u8,
        start: [3]f32,
        end: [3]f32,
    }{
        .{ .name = "Very Short (2m)", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 7.0, 0.0, 5.0 } },
        .{ .name = "Short (5m)", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 10.0, 0.0, 5.0 } },
        .{ .name = "Medium (10m)", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 15.0, 0.0, 5.0 } },
        .{ .name = "Long (20m)", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 25.0, 0.0, 5.0 } },
        .{ .name = "Diagonal Short", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 10.0, 0.0, 10.0 } },
        .{ .name = "Diagonal Long", .start = [_]f32{ 5.0, 0.0, 5.0 }, .end = [_]f32{ 25.0, 0.0, 25.0 } },
    };

    for (scenarios) |scenario| {
        const result = try benchmarkFindStraightPath(
            scenario.name,
            test_data.query,
            scenario.start,
            scenario.end,
            config,
            allocator,
        );
        result.print();
    }

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                               ANALYSIS COMPLETE                                                  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
