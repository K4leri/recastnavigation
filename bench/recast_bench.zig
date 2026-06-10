const std = @import("std");
const nav = @import("zig-recast");

// ==============================================================================
// BENCHMARK CONFIGURATION
// ==============================================================================

const BenchConfig = struct {
    iterations: usize = 100,
    warmup_iterations: usize = 10,
    inner_iterations: usize = 1, // Recast операции долгие, 1 вызов достаточно
};

const BenchResult = struct {
    name: []const u8,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    iterations: usize,

    pub fn print(self: BenchResult) void {
        // Для удобочитаемости выводим в микросекундах (Recast операции долгие)
        const avg_us = @as(f64, @floatFromInt(self.avg_time_ns)) / 1_000.0;
        const min_us = @as(f64, @floatFromInt(self.min_time_ns)) / 1_000.0;
        const max_us = @as(f64, @floatFromInt(self.max_time_ns)) / 1_000.0;

        std.debug.print("{s:<40} | Avg: {d:>10.1} μs | Min: {d:>10.1} μs | Max: {d:>10.1} μs | Iters: {d}\n", .{
            self.name,
            avg_us,
            min_us,
            max_us,
            self.iterations,
        });
    }
};

// ==============================================================================
// MESH GENERATORS
// ==============================================================================

/// Small box mesh (12 triangles)
fn createSmallBoxMesh() [12]nav.Vec3 {
    return [12]nav.Vec3{
        // Top face
        nav.Vec3.init(0, 0.5, 0),
        nav.Vec3.init(10, 0.5, 0),
        nav.Vec3.init(10, 0.5, 10),
        nav.Vec3.init(0, 0.5, 0),
        nav.Vec3.init(10, 0.5, 10),
        nav.Vec3.init(0, 0.5, 10),
        // Bottom face
        nav.Vec3.init(0, 0, 0),
        nav.Vec3.init(10, 0, 10),
        nav.Vec3.init(10, 0, 0),
        nav.Vec3.init(0, 0, 0),
        nav.Vec3.init(0, 0, 10),
        nav.Vec3.init(10, 0, 10),
    };
}

/// Medium terrain mesh (100 triangles)
fn createMediumTerrainMesh(allocator: std.mem.Allocator) ![]nav.Vec3 {
    const grid_size = 10; // 10x10 grid = 200 triangles
    const cell_size: f32 = 1.0;
    const triangle_count = (grid_size - 1) * (grid_size - 1) * 2;

    var vertices = try allocator.alloc(nav.Vec3, triangle_count * 3);
    var idx: usize = 0;

    var z: usize = 0;
    while (z < grid_size - 1) : (z += 1) {
        var x: usize = 0;
        while (x < grid_size - 1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) * cell_size;
            const fz = @as(f32, @floatFromInt(z)) * cell_size;
            const fx1 = fx + cell_size;
            const fz1 = fz + cell_size;

            // Random height variation
            const h1: f32 = @as(f32, @floatFromInt((x + z) % 3)) * 0.2;
            const h2: f32 = @as(f32, @floatFromInt((x + z + 1) % 3)) * 0.2;
            const h3: f32 = @as(f32, @floatFromInt((x + z + 2) % 3)) * 0.2;
            const h4: f32 = @as(f32, @floatFromInt((x + z + 3) % 3)) * 0.2;

            // Triangle 1
            vertices[idx] = nav.Vec3.init(fx, h1, fz);
            vertices[idx + 1] = nav.Vec3.init(fx1, h2, fz);
            vertices[idx + 2] = nav.Vec3.init(fx1, h3, fz1);
            idx += 3;

            // Triangle 2
            vertices[idx] = nav.Vec3.init(fx, h1, fz);
            vertices[idx + 1] = nav.Vec3.init(fx1, h3, fz1);
            vertices[idx + 2] = nav.Vec3.init(fx, h4, fz1);
            idx += 3;
        }
    }

    return vertices;
}

/// Large complex mesh (1000+ triangles)
fn createLargeComplexMesh(allocator: std.mem.Allocator) ![]nav.Vec3 {
    const grid_size = 32; // 32x32 grid = 2048 triangles
    const cell_size: f32 = 1.0;
    const triangle_count = (grid_size - 1) * (grid_size - 1) * 2;

    var vertices = try allocator.alloc(nav.Vec3, triangle_count * 3);
    var idx: usize = 0;

    var z: usize = 0;
    while (z < grid_size - 1) : (z += 1) {
        var x: usize = 0;
        while (x < grid_size - 1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) * cell_size;
            const fz = @as(f32, @floatFromInt(z)) * cell_size;
            const fx1 = fx + cell_size;
            const fz1 = fz + cell_size;

            // Complex height variation (sine wave + noise)
            const h1: f32 = @sin(fx * 0.5) * 2.0 + @as(f32, @floatFromInt((x * 7 + z * 13) % 5)) * 0.3;
            const h2: f32 = @sin(fx1 * 0.5) * 2.0 + @as(f32, @floatFromInt((x * 7 + z * 13 + 1) % 5)) * 0.3;
            const h3: f32 = @sin(fx1 * 0.5) * 2.0 + @as(f32, @floatFromInt((x * 7 + z * 13 + 2) % 5)) * 0.3;
            const h4: f32 = @sin(fx * 0.5) * 2.0 + @as(f32, @floatFromInt((x * 7 + z * 13 + 3) % 5)) * 0.3;

            // Triangle 1
            vertices[idx] = nav.Vec3.init(fx, h1, fz);
            vertices[idx + 1] = nav.Vec3.init(fx1, h2, fz);
            vertices[idx + 2] = nav.Vec3.init(fx1, h3, fz1);
            idx += 3;

            // Triangle 2
            vertices[idx] = nav.Vec3.init(fx, h1, fz);
            vertices[idx + 1] = nav.Vec3.init(fx1, h3, fz1);
            vertices[idx + 2] = nav.Vec3.init(fx, h4, fz1);
            idx += 3;
        }
    }

    return vertices;
}

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
        var j: usize = 0;
        while (j < config.inner_iterations) : (j += 1) {
            _ = try @call(.auto, func, args);
        }
    }

    // Actual benchmark
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    var total_time: u64 = 0;

    i = 0;
    while (i < config.iterations) : (i += 1) {
        timer.reset();

        // Вызываем функцию много раз для точного измерения
        var j: usize = 0;
        while (j < config.inner_iterations) : (j += 1) {
            _ = try @call(.auto, func, args);
        }

        const elapsed = timer.read();
        const per_call = elapsed / config.inner_iterations;

        min_time = @min(min_time, per_call);
        max_time = @max(max_time, per_call);
        total_time += per_call;
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
// RECAST PIPELINE BENCHMARKS
// ==============================================================================

/// Benchmark heightfield rasterization
fn benchmarkRasterization(
    allocator: std.mem.Allocator,
    vertices: []const nav.Vec3,
) !void {
    var ctx = nav.Context.init(allocator);

    // Configure
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

    // Create heightfield
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

    // Prepare data
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

    // BENCHMARK: Rasterization
    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        verts_f32,
        indices_i32,
        areas,
        &heightfield,
        config.walkable_climb,
    );
}

/// Benchmark compact heightfield building
fn benchmarkCompactHeightfield(
    allocator: std.mem.Allocator,
    heightfield: *nav.Heightfield,
    config: nav.RecastConfig,
) !void {
    var ctx = nav.Context.init(allocator);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, heightfield);
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

    // BENCHMARK: Build compact heightfield
    try nav.recast.compact.buildCompactHeightfield(
        &ctx,
        config.walkable_height,
        config.walkable_climb,
        heightfield,
        &chf,
    );
}

/// Benchmark region building (watershed algorithm)
fn benchmarkRegionBuilding(
    allocator: std.mem.Allocator,
    chf: *nav.CompactHeightfield,
    config: nav.RecastConfig,
) !void {
    var ctx = nav.Context.init(allocator);

    // Erode walkable area
    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, chf, allocator);

    // Build distance field
    try nav.recast.region.buildDistanceField(&ctx, chf, allocator);

    // BENCHMARK: Build regions
    try nav.recast.region.buildRegions(
        &ctx,
        chf,
        config.border_size,
        config.min_region_area,
        config.merge_region_area,
        allocator,
    );
}

/// Benchmark contour extraction
fn benchmarkContourExtraction(
    allocator: std.mem.Allocator,
    chf: *nav.CompactHeightfield,
    config: nav.RecastConfig,
) !void {
    var ctx = nav.Context.init(allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();

    // BENCHMARK: Build contours
    try nav.recast.contour.buildContours(
        &ctx,
        chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        0,
        allocator,
    );
}

/// Benchmark polygon mesh building
fn benchmarkPolyMeshBuilding(
    allocator: std.mem.Allocator,
    cset: *nav.ContourSet,
    config: nav.RecastConfig,
) !void {
    var ctx = nav.Context.init(allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();

    // BENCHMARK: Build polygon mesh
    try nav.recast.mesh.buildPolyMesh(
        &ctx,
        cset,
        @intCast(config.max_verts_per_poly),
        &pmesh,
        allocator,
    );
}

/// Benchmark detail mesh generation
fn benchmarkDetailMeshGeneration(
    allocator: std.mem.Allocator,
    pmesh: *nav.PolyMesh,
    chf: *nav.CompactHeightfield,
    config: nav.RecastConfig,
) !void {
    var ctx = nav.Context.init(allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();

    // BENCHMARK: Build detail mesh
    try nav.recast.detail.buildPolyMeshDetail(
        &ctx,
        pmesh,
        chf,
        config.detail_sample_dist,
        config.detail_sample_max_error,
        &dmesh,
        allocator,
    );
}

/// Full pipeline benchmark
fn benchmarkFullPipeline(
    allocator: std.mem.Allocator,
    vertices: []const nav.Vec3,
) !void {
    var ctx = nav.Context.init(allocator);

    // Configure
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

    // Full pipeline
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

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        verts_f32,
        indices_i32,
        areas,
        &heightfield,
        config.walkable_climb,
    );

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
    std.debug.print("║                          RECAST PERFORMANCE BENCHMARKS                                           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const bench_config = BenchConfig{
        .iterations = 50,
        .warmup_iterations = 5,
    };

    // ========== SMALL MESH (12 triangles) ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  SMALL MESH (12 triangles)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const small_mesh = createSmallBoxMesh();
    const small_verts: []const nav.Vec3 = &small_mesh;

    const result1 = try benchmark(
        "Rasterization (Small)",
        benchmarkRasterization,
        .{ allocator, small_verts },
        bench_config,
    );
    result1.print();

    const result2 = try benchmark(
        "Full Pipeline (Small)",
        benchmarkFullPipeline,
        .{ allocator, small_verts },
        bench_config,
    );
    result2.print();

    std.debug.print("\n", .{});

    // ========== MEDIUM MESH (200 triangles) ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  MEDIUM MESH (200 triangles)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const medium_verts = try createMediumTerrainMesh(allocator);
    defer allocator.free(medium_verts);

    const result3 = try benchmark(
        "Rasterization (Medium)",
        benchmarkRasterization,
        .{ allocator, medium_verts },
        bench_config,
    );
    result3.print();

    const result4 = try benchmark(
        "Full Pipeline (Medium)",
        benchmarkFullPipeline,
        .{ allocator, medium_verts },
        bench_config,
    );
    result4.print();

    std.debug.print("\n", .{});

    // ========== LARGE MESH (2048 triangles) ==========
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("  LARGE MESH (2048 triangles)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const large_verts = try createLargeComplexMesh(allocator);
    defer allocator.free(large_verts);

    const result5 = try benchmark(
        "Rasterization (Large)",
        benchmarkRasterization,
        .{ allocator, large_verts },
        bench_config,
    );
    result5.print();

    const result6 = try benchmark(
        "Full Pipeline (Large)",
        benchmarkFullPipeline,
        .{ allocator, large_verts },
        bench_config,
    );
    result6.print();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                               BENCHMARK COMPLETE                                                 ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
