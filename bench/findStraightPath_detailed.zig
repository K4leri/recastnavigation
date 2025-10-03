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

    // Create simple flat grid
    const vertex_count = grid_size * grid_size;
    const triangle_count = (grid_size - 1) * (grid_size - 1) * 2;

    var vertices = try allocator.alloc(f32, vertex_count * 3);
    defer allocator.free(vertices);

    var triangles = try allocator.alloc(i32, triangle_count * 3);
    defer allocator.free(triangles);

    // Create vertex grid
    var vidx: usize = 0;
    for (0..grid_size) |z| {
        for (0..grid_size) |x| {
            vertices[vidx] = @as(f32, @floatFromInt(x));
            vidx += 1;
            vertices[vidx] = 0.0;
            vidx += 1;
            vertices[vidx] = @as(f32, @floatFromInt(z));
            vidx += 1;
        }
    }

    // Create triangle indices
    var tidx: usize = 0;
    for (0..grid_size - 1) |z| {
        for (0..grid_size - 1) |x| {
            const v0: i32 = @intCast(z * grid_size + x);
            const v1 = v0 + 1;
            const v2 = v0 + @as(i32, @intCast(grid_size));
            const v3 = v2 + 1;

            // Triangle 1
            triangles[tidx] = v0;
            tidx += 1;
            triangles[tidx] = v1;
            tidx += 1;
            triangles[tidx] = v3;
            tidx += 1;

            // Triangle 2
            triangles[tidx] = v0;
            tidx += 1;
            triangles[tidx] = v3;
            tidx += 1;
            triangles[tidx] = v2;
            tidx += 1;
        }
    }

    // Build NavMesh through Recast
    var config = nav.RecastConfig{
        .width = 0,
        .height = 0,
        .tile_size = 0,
        .border_size = 0,
        .cs = 0.3,
        .ch = 0.2,
        .bmin = nav.math.Vec3.init(0, 0, 0),
        .bmax = nav.math.Vec3.init(0, 0, 0),
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
    };

    nav.RecastConfig.calcBounds(vertices, &config.bmin, &config.bmax);
    nav.RecastConfig.calcGridSize(&config);

    const ctx = try nav.RecastContext.init(allocator);
    defer ctx.deinit();

    var hf = try nav.RecastHeightfield.init(allocator, config.width, config.height, &config.bmin, &config.bmax, config.cs, config.ch);
    defer hf.deinit(allocator);

    const areas = try allocator.alloc(u8, triangle_count);
    defer allocator.free(areas);
    @memset(areas, nav.WALKABLE_AREA);

    try nav.markWalkableTriangles(ctx, config.walkable_slope_angle, vertices, triangles, areas);
    try nav.rasterizeTriangles(ctx, vertices, triangles, areas, &hf, config.walkable_climb);

    try nav.filterLowHangingWalkableObstacles(ctx, config.walkable_climb, &hf);
    try nav.filterLedgeSpans(ctx, config.walkable_height, config.walkable_climb, &hf);
    try nav.filterWalkableLowHeightSpans(ctx, config.walkable_height, &hf);

    var chf = try nav.RecastCompactHeightfield.init(allocator, &hf, config.walkable_height, config.walkable_climb);
    defer chf.deinit(allocator);

    try nav.erodeWalkableArea(ctx, config.walkable_radius, &chf);
    try nav.buildDistanceField(ctx, &chf);
    try nav.buildRegions(ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area);

    var cset = try nav.RecastContourSet.init(allocator);
    defer cset.deinit(allocator);
    try nav.buildContours(ctx, &chf, config.max_simplification_error, config.max_edge_len, &cset);

    var pmesh = try nav.RecastPolyMesh.init(allocator);
    defer pmesh.deinit(allocator);
    try nav.buildPolyMesh(ctx, &cset, config.max_verts_per_poly, &pmesh);

    var dmesh = try nav.RecastPolyMeshDetail.init(allocator);
    defer dmesh.deinit(allocator);
    try nav.buildPolyMeshDetail(ctx, &pmesh, &chf, config.detail_sample_dist, config.detail_sample_max_error, &dmesh);

    // Create NavMesh
    var params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_areas = pmesh.areas,
        .poly_flags = pmesh.flags,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
        .walkable_height = config.walkable_height,
        .walkable_radius = config.walkable_radius,
        .walkable_climb = config.walkable_climb,
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

    const navmesh_data = try nav.detour.createNavMeshData(&params, allocator);
    defer allocator.free(navmesh_data);

    const navmesh = try nav.detour.NavMesh.init(allocator);
    _ = try navmesh.addTile(navmesh_data, .free_data, 0, allocator);

    const query = try nav.detour.NavMeshQuery.init(navmesh, 2048, allocator);

    return .{ .navmesh = navmesh, .query = query };
}

fn benchmarkFindStraightPath(
    comptime name: []const u8,
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
    defer _ = gpa.deinit();
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
    defer test_data.navmesh.deinit(allocator);
    defer test_data.query.deinit(allocator);

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
