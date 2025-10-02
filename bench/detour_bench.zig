const std = @import("std");
const nav = @import("zig-recast");

// ==============================================================================
// BENCHMARK CONFIGURATION
// ==============================================================================

const BenchConfig = struct {
    iterations: usize = 100,
    warmup_iterations: usize = 10,
};

const BenchResult = struct {
    name: []const u8,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    iterations: usize,

    pub fn print(self: BenchResult) void {
        const avg_us = @as(f64, @floatFromInt(self.avg_time_ns)) / 1_000.0;
        const min_us = @as(f64, @floatFromInt(self.min_time_ns)) / 1_000.0;
        const max_us = @as(f64, @floatFromInt(self.max_time_ns)) / 1_000.0;

        std.debug.print("{s:<40} | Avg: {d:>8.2} μs | Min: {d:>8.2} μs | Max: {d:>8.2} μs | Iters: {d}\n", .{
            self.name,
            avg_us,
            min_us,
            max_us,
            self.iterations,
        });
    }
};

// ==============================================================================
// NAVMESH BUILDER
// ==============================================================================

const NavMeshTestData = struct {
    navmesh: *nav.NavMesh,
    query: *nav.NavMeshQuery,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, grid_size: usize) !NavMeshTestData {
        // Create simple grid NavMesh for testing
        var ctx = nav.Context.init(allocator);

        // Create grid mesh
        const cell_size: f32 = 1.0;
        const triangle_count = (grid_size - 1) * (grid_size - 1) * 2;
        var vertices = try allocator.alloc(nav.Vec3, triangle_count * 3);
        defer allocator.free(vertices);

        var idx: usize = 0;
        var z: usize = 0;
        while (z < grid_size - 1) : (z += 1) {
            var x: usize = 0;
            while (x < grid_size - 1) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) * cell_size;
                const fz = @as(f32, @floatFromInt(z)) * cell_size;
                const fx1 = fx + cell_size;
                const fz1 = fz + cell_size;

                vertices[idx] = nav.Vec3.init(fx, 0, fz);
                vertices[idx + 1] = nav.Vec3.init(fx1, 0, fz);
                vertices[idx + 2] = nav.Vec3.init(fx1, 0, fz1);
                idx += 3;

                vertices[idx] = nav.Vec3.init(fx, 0, fz);
                vertices[idx + 1] = nav.Vec3.init(fx1, 0, fz1);
                vertices[idx + 2] = nav.Vec3.init(fx, 0, fz1);
                idx += 3;
            }
        }

        // Build NavMesh through Recast pipeline
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

        var bmin = nav.Vec3.zero();
        var bmax = nav.Vec3.zero();
        nav.RecastConfig.calcBounds(vertices, &bmin, &bmax);
        config.bmin = bmin;
        config.bmax = bmax;

        var size_x: i32 = 0;
        var size_z: i32 = 0;
        nav.RecastConfig.calcGridSize(bmin, bmax, config.cs, &size_x, &size_z);
        config.width = size_x;
        config.height = size_z;

        // Build pipeline
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

        const tri_count = vertices.len / 3;
        var indices_i32 = try allocator.alloc(i32, vertices.len);
        defer allocator.free(indices_i32);
        for (0..vertices.len) |i| {
            indices_i32[i] = @intCast(i);
        }

        var verts_f32 = try allocator.alloc(f32, vertices.len * 3);
        defer allocator.free(verts_f32);
        for (vertices, 0..) |v, i| {
            verts_f32[i * 3 + 0] = v.x;
            verts_f32[i * 3 + 1] = v.y;
            verts_f32[i * 3 + 2] = v.z;
        }

        const areas = try allocator.alloc(u8, tri_count);
        defer allocator.free(areas);
        @memset(areas, 1);

        try nav.recast.rasterization.rasterizeTriangles(&ctx, verts_f32, indices_i32, areas, &heightfield, config.walkable_climb);
        nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
        nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
        nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

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

        try nav.recast.compact.buildCompactHeightfield(&ctx, config.walkable_height, config.walkable_climb, &heightfield, &chf);
        try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
        try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
        try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

        var cset = nav.ContourSet.init(allocator);
        defer cset.deinit();
        try nav.recast.contour.buildContours(&ctx, &chf, config.max_simplification_error, config.max_edge_len, &cset, 0, allocator);

        var pmesh = nav.PolyMesh.init(allocator);
        defer pmesh.deinit();
        try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, allocator);

        var dmesh = nav.PolyMeshDetail.init(allocator);
        defer dmesh.deinit();
        try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, config.detail_sample_dist, config.detail_sample_max_error, &dmesh, allocator);

        // Create NavMesh
        const params = nav.NavMeshParams{
            .orig = config.bmin,
            .tile_width = @as(f32, @floatFromInt(config.width)) * config.cs,
            .tile_height = @as(f32, @floatFromInt(config.height)) * config.cs,
            .max_tiles = 1,
            .max_polys = 512,
        };
        const navmesh = try allocator.create(nav.NavMesh);
        navmesh.* = try nav.NavMesh.init(allocator, params);

        // Create NavMesh data
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
        };

        const navmesh_data = try nav.detour.createNavMeshData(&navmesh_create_params, allocator);
        defer allocator.free(navmesh_data);

        // Add tile to NavMesh
        _ = try navmesh.addTile(navmesh_data, .{ .free_data = false }, 0);

        // Create query
        var query = try nav.NavMeshQuery.init(allocator);
        try query.initQuery(navmesh, 2048);

        return NavMeshTestData{
            .navmesh = navmesh,
            .query = query,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NavMeshTestData) void {
        self.query.deinit();
        self.navmesh.deinit();
        self.allocator.destroy(self.navmesh);
    }
};

// ==============================================================================
// BENCHMARK HELPERS
// ==============================================================================

fn benchmark(
    comptime name: []const u8,
    comptime func: anytype,
    args: anytype,
    config: BenchConfig,
) !BenchResult {
    var timer = try std.time.Timer.start();

    // Warmup
    var i: usize = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        _ = try @call(.auto, func, args);
    }

    // Actual benchmark
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    var total_time: u64 = 0;

    i = 0;
    while (i < config.iterations) : (i += 1) {
        timer.reset();
        _ = try @call(.auto, func, args);
        const elapsed = timer.read();

        min_time = @min(min_time, elapsed);
        max_time = @max(max_time, elapsed);
        total_time += elapsed;
    }

    return BenchResult{
        .name = name,
        .avg_time_ns = total_time / config.iterations,
        .min_time_ns = min_time,
        .max_time_ns = max_time,
        .iterations = config.iterations,
    };
}

// ==============================================================================
// DETOUR BENCHMARKS
// ==============================================================================

/// Benchmark findNearestPoly
fn benchmarkFindNearestPoly(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };
    var nearest_ref: u32 = 0;
    var nearest_pt: [3]f32 = undefined;

    try query.findNearestPoly(&pos, &extents, filter, &nearest_ref, &nearest_pt);
}

/// Benchmark findPath (short distance)
fn benchmarkFindPathShort(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const start_pos = [3]f32{ 1.0, 0.0, 1.0 };
    const end_pos = [3]f32{ 3.0, 0.0, 3.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: u32 = 0;
    var end_ref: u32 = 0;

    try query.findNearestPoly(&start_pos, &extents, filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, filter, &end_ref, null);

    if (start_ref != 0 and end_ref != 0) {
        var path: [256]u32 = undefined;
        var path_count: usize = 0;
        try query.findPath(start_ref, end_ref, &start_pos, &end_pos, filter, &path, &path_count);
    }
}

/// Benchmark findPath (long distance)
fn benchmarkFindPathLong(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter, grid_size: f32) !void {
    const start_pos = [3]f32{ 0.5, 0.0, 0.5 };
    const end_pos = [3]f32{ grid_size - 0.5, 0.0, grid_size - 0.5 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: u32 = 0;
    var end_ref: u32 = 0;

    try query.findNearestPoly(&start_pos, &extents, filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, filter, &end_ref, null);

    if (start_ref != 0 and end_ref != 0) {
        var path: [256]u32 = undefined;
        var path_count: usize = 0;
        try query.findPath(start_ref, end_ref, &start_pos, &end_pos, filter, &path, &path_count);
    }
}

/// Benchmark raycast
fn benchmarkRaycast(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const start_pos = [3]f32{ 1.0, 0.0, 1.0 };
    const end_pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: u32 = 0;
    try query.findNearestPoly(&start_pos, &extents, filter, &start_ref, null);

    if (start_ref != 0) {
        var hit = nav.RaycastHit{
            .t = 0,
            .hit_normal = .{ 0, 0, 0 },
            .path = undefined,
            .path_count = 0,
            .max_path = 256,
            .path_cost = 0,
        };
        _ = try query.raycast(start_ref, &start_pos, &end_pos, filter, 0, &hit, 0);
    }
}

/// Benchmark findStraightPath
fn benchmarkFindStraightPath(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const start_pos = [3]f32{ 1.0, 0.0, 1.0 };
    const end_pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: u32 = 0;
    var end_ref: u32 = 0;

    try query.findNearestPoly(&start_pos, &extents, filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, filter, &end_ref, null);

    if (start_ref != 0 and end_ref != 0) {
        var path: [256]u64 = undefined;
        const path_count = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, filter, &path);

        if (path_count > 0) {
            var straight_path: [256 * 3]f32 = undefined;
            var straight_path_flags: [256]u8 = undefined;
            var straight_path_refs: [256]u64 = undefined;
            var straight_path_count: usize = 0;

            _ = try query.findStraightPath(
                &start_pos,
                &end_pos,
                path[0..path_count],
                &straight_path,
                &straight_path_flags,
                &straight_path_refs,
                &straight_path_count,
                256,
                0,
            );
        }
    }
}

/// Benchmark queryPolygons
fn benchmarkQueryPolygons(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const center = [3]f32{ 5.0, 0.0, 5.0 };
    const half_extents = [3]f32{ 3.0, 4.0, 3.0 };
    var polys: [128]u64 = undefined;
    var poly_count: i32 = 0;

    try query.queryPolygons(&center, &half_extents, filter, &polys, &poly_count, 128);
}

/// Benchmark findDistanceToWall
fn benchmarkFindDistanceToWall(query: *nav.NavMeshQuery, filter: *const nav.QueryFilter) !void {
    const center_pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: u32 = 0;
    try query.findNearestPoly(&center_pos, &extents, filter, &start_ref, null);

    if (start_ref != 0) {
        var hit_dist: f32 = 0;
        var hit_pos: [3]f32 = undefined;
        var hit_normal: [3]f32 = undefined;

        _ = try query.findDistanceToWall(start_ref, &center_pos, 10.0, filter, &hit_dist, &hit_pos, &hit_normal);
    }
}

// ==============================================================================
// MAIN BENCHMARK RUNNER
// ==============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                          DETOUR PERFORMANCE BENCHMARKS                                           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const bench_config = BenchConfig{
        .iterations = 500,
        .warmup_iterations = 50,
    };

    // ========== SMALL NAVMESH (10x10 grid) ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  SMALL NAVMESH (10x10 grid)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var small_data = try NavMeshTestData.init(allocator, 10);
    defer small_data.deinit();

    const filter = nav.QueryFilter.init();

    const r1 = try benchmark("findNearestPoly (Small)", benchmarkFindNearestPoly, .{ small_data.query, &filter }, bench_config);
    r1.print();

    const r2 = try benchmark("findPath Short (Small)", benchmarkFindPathShort, .{ small_data.query, &filter }, bench_config);
    r2.print();

    const r3 = try benchmark("findPath Long (Small)", benchmarkFindPathLong, .{ small_data.query, &filter, 10.0 }, bench_config);
    r3.print();

    const r4 = try benchmark("raycast (Small)", benchmarkRaycast, .{ small_data.query, &filter }, bench_config);
    r4.print();

    const r5 = try benchmark("findStraightPath (Small)", benchmarkFindStraightPath, .{ small_data.query, &filter }, bench_config);
    r5.print();

    const r6 = try benchmark("queryPolygons (Small)", benchmarkQueryPolygons, .{ small_data.query, &filter }, bench_config);
    r6.print();

    const r7 = try benchmark("findDistanceToWall (Small)", benchmarkFindDistanceToWall, .{ small_data.query, &filter }, bench_config);
    r7.print();

    std.debug.print("\n", .{});

    // ========== MEDIUM NAVMESH (20x20 grid) ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  MEDIUM NAVMESH (20x20 grid)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var medium_data = try NavMeshTestData.init(allocator, 20);
    defer medium_data.deinit();

    const r8 = try benchmark("findNearestPoly (Medium)", benchmarkFindNearestPoly, .{ medium_data.query, &filter }, bench_config);
    r8.print();

    const r9 = try benchmark("findPath Short (Medium)", benchmarkFindPathShort, .{ medium_data.query, &filter }, bench_config);
    r9.print();

    const r10 = try benchmark("findPath Long (Medium)", benchmarkFindPathLong, .{ medium_data.query, &filter, 20.0 }, bench_config);
    r10.print();

    const r11 = try benchmark("raycast (Medium)", benchmarkRaycast, .{ medium_data.query, &filter }, bench_config);
    r11.print();

    const r12 = try benchmark("findStraightPath (Medium)", benchmarkFindStraightPath, .{ medium_data.query, &filter }, bench_config);
    r12.print();

    const r13 = try benchmark("queryPolygons (Medium)", benchmarkQueryPolygons, .{ medium_data.query, &filter }, bench_config);
    r13.print();

    const r14 = try benchmark("findDistanceToWall (Medium)", benchmarkFindDistanceToWall, .{ medium_data.query, &filter }, bench_config);
    r14.print();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                               BENCHMARK COMPLETE                                                 ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
