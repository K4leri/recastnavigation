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

        std.debug.print("{s:<50} | Avg: {d:>9.2} μs | Min: {d:>9.2} μs | Max: {d:>9.2} μs\n", .{
            self.name,
            avg_us,
            min_us,
            max_us,
        });
    }
};

// ==============================================================================
// NAVMESH BUILDER (same as detour_bench.zig)
// ==============================================================================

const NavMeshTestData = struct {
    navmesh: *nav.NavMesh,
    query: *nav.NavMeshQuery,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, grid_size: usize) !NavMeshTestData {
        var ctx = nav.Context.init(allocator);

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

        var heightfield = try nav.Heightfield.init(allocator, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch);
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
        var chf = try nav.CompactHeightfield.init(allocator, config.width, config.height, @intCast(span_count), config.walkable_height, config.walkable_climb, config.bmin, config.bmax, config.cs, config.ch, config.border_size);
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

        const params = nav.NavMeshParams{
            .orig = config.bmin,
            .tile_width = @as(f32, @floatFromInt(config.width)) * config.cs,
            .tile_height = @as(f32, @floatFromInt(config.height)) * config.cs,
            .max_tiles = 1,
            .max_polys = 512,
        };
        const navmesh = try allocator.create(nav.NavMesh);
        navmesh.* = try nav.NavMesh.init(allocator, params);

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

        _ = try navmesh.addTile(navmesh_data, .{ .free_data = false }, 0);

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
// CROWD BENCHMARKS
// ==============================================================================

/// Benchmark crowd update with N agents
fn benchmarkCrowdUpdate(crowd: *nav.Crowd, dt: f32) !void {
    try crowd.update(dt, null);
}

/// Benchmark adding agent to crowd
fn benchmarkAddAgent(crowd: *nav.Crowd, pos: [3]f32, params: nav.CrowdAgentParams) !void {
    const idx = try crowd.addAgent(&pos, &params);
    if (idx >= 0) {
        crowd.removeAgent(idx);
    }
}

/// Benchmark setting move target for agent
fn benchmarkRequestMoveTarget(crowd: *nav.Crowd, agent_idx: i32, target_pos: [3]f32) !void {
    const filter = crowd.getFilter(0);
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var target_ref: u32 = 0;
    try crowd.navquery.findNearestPoly(&target_pos, &extents, filter, &target_ref, null);

    if (target_ref != 0) {
        try crowd.requestMoveTarget(agent_idx, target_ref, &target_pos);
    }
}

// ==============================================================================
// CROWD TEST SCENARIOS
// ==============================================================================

const CrowdTestScenario = struct {
    crowd: *nav.Crowd,
    navmesh_data: NavMeshTestData,
    agent_indices: []i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, grid_size: usize, agent_count: usize) !CrowdTestScenario {
        // Create NavMesh
        const navmesh_data = try NavMeshTestData.init(allocator, grid_size);

        // Create crowd
        var crowd = try nav.Crowd.init(allocator, @intCast(agent_count * 2), 0.6, navmesh_data.navmesh);

        // Configure obstacle avoidance
        var oa_params = nav.ObstacleAvoidanceParams{
            .vel_bias = 0.4,
            .weight_des_vel = 2.0,
            .weight_cur_vel = 0.75,
            .weight_side = 0.75,
            .weight_toi = 2.5,
            .horiz_time = 2.5,
            .grid_size = 33,
            .adaptive_divs = 7,
            .adaptive_rings = 2,
            .adaptive_depth = 5,
        };
        crowd.setObstacleAvoidanceParams(0, &oa_params);

        // Add agents
        var agent_indices = try allocator.alloc(i32, agent_count);
        const grid_float = @as(f32, @floatFromInt(grid_size));

        var params = nav.CrowdAgentParams.init();
        params.radius = 0.6;
        params.height = 2.0;
        params.max_acceleration = 8.0;
        params.max_speed = 3.5;
        params.collision_query_range = 2.5;
        params.path_optimization_range = 30.0;
        params.separation_weight = 2.0;

        for (0..agent_count) |i| {
            // Distribute agents across the grid
            const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(agent_count));
            const radius = grid_float * 0.25;
            const center_x = grid_float * 0.5;
            const center_z = grid_float * 0.5;

            const pos = [3]f32{
                center_x + @cos(angle) * radius,
                0.0,
                center_z + @sin(angle) * radius,
            };

            const idx = try crowd.addAgent(&pos, &params);
            agent_indices[i] = idx;

            // Set opposite target (agents move to opposite side)
            const target_pos = [3]f32{
                center_x - @cos(angle) * radius,
                0.0,
                center_z - @sin(angle) * radius,
            };

            const filter = crowd.getFilter(0);
            const extents = [3]f32{ 2.0, 4.0, 2.0 };
            var target_ref: u32 = 0;

            try crowd.navquery.findNearestPoly(&target_pos, &extents, filter, &target_ref, null);
            if (target_ref != 0) {
                try crowd.requestMoveTarget(idx, target_ref, &target_pos);
            }
        }

        return CrowdTestScenario{
            .crowd = crowd,
            .navmesh_data = navmesh_data,
            .agent_indices = agent_indices,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CrowdTestScenario) void {
        // Remove all agents
        for (self.agent_indices) |idx| {
            self.crowd.removeAgent(idx);
        }
        self.allocator.free(self.agent_indices);

        self.crowd.deinit();
        self.navmesh_data.deinit();
    }
};

// ==============================================================================
// MAIN BENCHMARK RUNNER
// ==============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                          CROWD PERFORMANCE BENCHMARKS                                            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const bench_config = BenchConfig{
        .iterations = 100,
        .warmup_iterations = 10,
    };

    const dt: f32 = 1.0 / 60.0; // 60 FPS

    // ========== 10 AGENTS ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  10 AGENTS (20x20 NavMesh)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var scenario_10 = try CrowdTestScenario.init(allocator, 20, 10);
    defer scenario_10.deinit();

    const r1 = try benchmark("Crowd Update (10 agents)", benchmarkCrowdUpdate, .{ scenario_10.crowd, dt }, bench_config);
    r1.print();

    std.debug.print("\n", .{});

    // ========== 25 AGENTS ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  25 AGENTS (30x30 NavMesh)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var scenario_25 = try CrowdTestScenario.init(allocator, 30, 25);
    defer scenario_25.deinit();

    const r2 = try benchmark("Crowd Update (25 agents)", benchmarkCrowdUpdate, .{ scenario_25.crowd, dt }, bench_config);
    r2.print();

    std.debug.print("\n", .{});

    // ========== 50 AGENTS ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  50 AGENTS (40x40 NavMesh)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var scenario_50 = try CrowdTestScenario.init(allocator, 40, 50);
    defer scenario_50.deinit();

    const r3 = try benchmark("Crowd Update (50 agents)", benchmarkCrowdUpdate, .{ scenario_50.crowd, dt }, bench_config);
    r3.print();

    std.debug.print("\n", .{});

    // ========== 100 AGENTS ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  100 AGENTS (50x50 NavMesh)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var scenario_100 = try CrowdTestScenario.init(allocator, 50, 100);
    defer scenario_100.deinit();

    const r4 = try benchmark("Crowd Update (100 agents)", benchmarkCrowdUpdate, .{ scenario_100.crowd, dt }, bench_config);
    r4.print();

    std.debug.print("\n", .{});

    // ========== INDIVIDUAL OPERATIONS ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  INDIVIDUAL OPERATIONS\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const pos = [3]f32{ 10.0, 0.0, 10.0 };
    const params = nav.CrowdAgentParams.init();

    const r5 = try benchmark("addAgent", benchmarkAddAgent, .{ scenario_10.crowd, pos, params }, bench_config);
    r5.print();

    const target_pos = [3]f32{ 15.0, 0.0, 15.0 };
    const r6 = try benchmark("requestMoveTarget", benchmarkRequestMoveTarget, .{ scenario_10.crowd, scenario_10.agent_indices[0], target_pos }, bench_config);
    r6.print();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                               BENCHMARK COMPLETE                                                 ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
