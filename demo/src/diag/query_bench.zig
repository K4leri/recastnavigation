//! NAVMESH ROUTE-QUERY BENCHMARK (cluster C, C2, P0).
//! Генерирует K случайных пар (start, end) на построенном навмеше, замеряет
//! findPath для каждой и считает перцентили латентности (p50/p95/p99/min/max/avg),
//! success-rate, среднее число посещённых узлов A* + гистограмму латентности.
//! Хвостовые перцентили (p95/p99) важнее среднего для бюджетирования запросов.
//!
//! Generates K random (start, end) pairs on the built navmesh, times `findPath`
//! for each, and reports latency percentiles (p50/p95/p99/min/max/avg), success
//! rate, average visited-node count, and a latency histogram. Tail percentiles
//! (p95/p99) matter more than the average for query budgeting.
//!
//! DEMO-LEVEL only — faithful core (src/*) is read, never modified. `BenchResult`
//! is a VALUE type (fixed arrays, no heap) so it copies by assignment and never
//! leaks. `run()`'s scratch (latencies/nodes/path) is freed via defer. The pure
//! percentile/histogram math is the load-bearing tested bit; `run()` needs a real
//! NavMesh so it is owner-verified via the panel (not unit-tested).

const std = @import("std");
const recast = @import("recast-nav");

const dt = recast.detour;
const NavMesh = dt.NavMesh;
const NavMeshQuery = dt.NavMeshQuery;
const QueryFilter = dt.QueryFilter;
const PolyRef = dt.PolyRef;

/// Число бинов гистограммы латентности.
/// Number of latency-histogram bins.
pub const HIST_BINS = 20;

/// Максимальная длина буфера коридора на один findPath (как MAX_POLYS у тестера).
/// Max corridor length for a single findPath scratch (mirrors the tester).
const MAX_PATH = 256;

/// Результат бенчмарка. VALUE-тип: фиксированные массивы, без heap — копируется
/// присваиванием, не требует deinit, не течёт.
///
/// Benchmark result. VALUE type: fixed arrays, no heap — copies by assignment,
/// needs no deinit, cannot leak.
pub const BenchResult = struct {
    n: usize = 0, // запрошено итераций / iterations requested
    ok_count: usize = 0, // findPath успешно достроил путь / successful routes
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    avg_ns: u64 = 0,
    avg_nodes: f32 = 0, // среднее число узлов A* по таймированным запросам
    hist: [HIST_BINS]u32 = [_]u32{0} ** HIST_BINS, // counts по бинам латентности
    hist_lo_ns: u64 = 0, // нижняя граница гистограммы (= min_ns)
    hist_hi_ns: u64 = 0, // верхняя граница гистограммы (= max_ns)
    worst_start: PolyRef = 0, // refs самого медленного запроса (для подсветки)
    worst_end: PolyRef = 0,

    /// Success-rate в процентах (0..100). 0, если ничего не запускалось.
    /// Success rate in percent (0..100). 0 when nothing ran.
    pub fn successPct(self: BenchResult) f32 {
        if (self.n == 0) return 0;
        return @as(f32, @floatFromInt(self.ok_count)) / @as(f32, @floatFromInt(self.n)) * 100.0;
    }
};

// ============================================================================
// PURE HELPERS (TESTABLE).
// ============================================================================

/// Перцентиль по nearest-rank на ОТСОРТИРОВАННОМ (по возрастанию) срезе.
/// p в [0,1]: p=0 -> min, p=1 -> max, p=0.5 -> медиана. Пустой срез -> 0.
/// Ранг = ceil(p * n), индекс = rank-1, зажат в [0, n-1].
///
/// Nearest-rank percentile over an ascending-SORTED slice. `p` in [0,1]: p=0 ->
/// min, p=1 -> max. Empty slice -> 0. rank = ceil(p*n), index = rank-1, clamped.
pub fn percentile(sorted: []const u64, p: f32) u64 {
    if (sorted.len == 0) return 0;
    const pc = std.math.clamp(p, 0.0, 1.0);
    if (pc <= 0.0) return sorted[0];
    if (pc >= 1.0) return sorted[sorted.len - 1];
    // nearest-rank: rank = ceil(p * n), index = rank - 1.
    const n_f: f32 = @floatFromInt(sorted.len);
    const rank_f = @ceil(pc * n_f);
    var rank: usize = @intFromFloat(rank_f);
    if (rank == 0) rank = 1; // p>0 -> at least rank 1
    if (rank > sorted.len) rank = sorted.len;
    return sorted[rank - 1];
}

/// Линейная гистограмма `vals` в `bins` счётчиков по диапазону [lo,hi].
/// bin = floor((v-lo)/(hi-lo) * nbins), зажат в [0, nbins-1] (v==hi -> последний
/// бин). lo==hi (нет разброса) -> всё в бин 0 (без деления на ноль). Значения вне
/// [lo,hi] зажимаются в крайние бины. bins зануляется в начале.
///
/// Linear histogram of `vals` into `bins` counts over [lo,hi]. bin =
/// floor((v-lo)/(hi-lo) * nbins), clamped to [0, nbins-1] (v==hi -> last bin).
/// lo==hi -> everything in bin 0 (no div-by-zero). Out-of-range values clamp to
/// the end bins. `bins` is zeroed first.
pub fn histogram(vals: []const u64, lo: u64, hi: u64, bins: []u32) void {
    for (bins) |*b| b.* = 0;
    if (bins.len == 0) return;
    const nbins = bins.len;
    if (hi <= lo) {
        // No spread: pile every value into bin 0.
        for (vals) |_| bins[0] += 1;
        return;
    }
    const span: f64 = @floatFromInt(hi - lo);
    const nb_f: f64 = @floatFromInt(nbins);
    for (vals) |v| {
        var idx: usize = 0;
        if (v <= lo) {
            idx = 0;
        } else if (v >= hi) {
            idx = nbins - 1;
        } else {
            const off: f64 = @floatFromInt(v - lo);
            const f = off / span * nb_f;
            const fi: usize = @intFromFloat(@floor(f));
            idx = if (fi >= nbins) nbins - 1 else fi;
        }
        bins[idx] += 1;
    }
}

// ============================================================================
// BENCH RUNNER (needs a real NavMesh — owner-verified, not unit-tested).
// ============================================================================

/// A small deterministic-PRNG frand adapter: findRandomPoint takes a std.Random,
/// which a DefaultPrng provides directly (we seed it from the user `seed`).

/// Запускает бенчмарк: K итераций, каждая выбирает start+end через
/// findRandomPoint(filter), таймирует findPath, пишет latency_ns + node_count + ok.
/// Считает BenchResult (сортирует scratch-копию латентностей для перцентилей).
/// Scratch (latencies/nodes/path) освобождается через defer. На вырожденном
/// навмеше (нет случайной точки) ok_count может быть < K.
///
/// Runs the benchmark: K iterations, each picks start+end via findRandomPoint,
/// times findPath, records latency_ns + node_count + ok. Computes BenchResult
/// (sorts a scratch copy of latencies). Scratch freed via defer. On a degenerate
/// navmesh (no random point) ok_count may be < K. A query that produced both
/// endpoints is TIMED (counts in n/latency); ok = findPath reached a corridor.
pub fn run(
    query: *NavMeshQuery,
    nav: *const NavMesh,
    filter: *const QueryFilter,
    k: usize,
    seed: u64,
    alloc: std.mem.Allocator,
) !BenchResult {
    _ = nav; // findRandomPoint/findPath read the mesh via the query's bound nav.
    var result = BenchResult{ .n = 0 };
    if (k == 0) return result;

    // Scratch: per-timed-query latency + node count, plus one reusable path buffer.
    const latencies = try alloc.alloc(u64, k);
    defer alloc.free(latencies);
    const nodes = try alloc.alloc(u32, k);
    defer alloc.free(nodes);
    const path = try alloc.alloc(PolyRef, MAX_PATH);
    defer alloc.free(path);

    // Deterministic PRNG seeded by `seed` so runs are reproducible.
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    // Monotonic ns clock (Zig 0.16: std.time.Timer is gone — use std.Io.Clock
    // (.awake) via a Threaded io created ONCE here and reused per query).
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var timed: usize = 0; // queries that produced both endpoints (timed samples)
    var ok_count: usize = 0;
    var nodes_sum: u64 = 0;
    var worst_ns: u64 = 0;
    var worst_start: PolyRef = 0;
    var worst_end: PolyRef = 0;

    var i: usize = 0;
    while (i < k) : (i += 1) {
        var start_ref: PolyRef = 0;
        var start_pt: [3]f32 = .{ 0, 0, 0 };
        var end_ref: PolyRef = 0;
        var end_pt: [3]f32 = .{ 0, 0, 0 };

        // Pick start + end. On a degenerate navmesh either may fail -> skip (not
        // timed, not counted in n) — the bench reports fewer samples than K.
        query.findRandomPoint(filter, rand, &start_ref, &start_pt) catch continue;
        query.findRandomPoint(filter, rand, &end_ref, &end_pt) catch continue;
        if (start_ref == 0 or end_ref == 0) continue;

        // Time exactly the findPath call (monotonic ns).
        var npath: usize = 0;
        const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
        const ok = if (query.findPath(start_ref, end_ref, &start_pt, &end_pt, filter, path, &npath)) |_| true else |_| false;
        const t1 = std.Io.Clock.now(.awake, io).nanoseconds;
        const lat: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;

        // Node count after the query (A* visited/closed+open from the pool).
        const ncount: u32 = if (query.getNodePool()) |pool| @intCast(pool.getNodeCount()) else 0;

        latencies[timed] = lat;
        nodes[timed] = ncount;
        nodes_sum += ncount;
        // ok = findPath succeeded AND produced a non-empty corridor (reached).
        if (ok and npath > 0) ok_count += 1;
        if (lat > worst_ns) {
            worst_ns = lat;
            worst_start = start_ref;
            worst_end = end_ref;
        }
        timed += 1;
    }

    result.n = timed;
    result.ok_count = ok_count;
    result.worst_start = worst_start;
    result.worst_end = worst_end;
    if (timed == 0) return result; // degenerate mesh: nothing timed.

    result.avg_nodes = @as(f32, @floatFromInt(nodes_sum)) / @as(f32, @floatFromInt(timed));

    // Sum + min/max from the unsorted view (cheap; one pass).
    var sum: u64 = 0;
    var mn: u64 = latencies[0];
    var mx: u64 = latencies[0];
    for (latencies[0..timed]) |l| {
        sum += l;
        if (l < mn) mn = l;
        if (l > mx) mx = l;
    }
    result.min_ns = mn;
    result.max_ns = mx;
    result.avg_ns = sum / @as(u64, @intCast(timed));

    // Sort the latency scratch in place for percentiles (nearest-rank).
    std.mem.sort(u64, latencies[0..timed], {}, std.sort.asc(u64));
    result.p50_ns = percentile(latencies[0..timed], 0.50);
    result.p95_ns = percentile(latencies[0..timed], 0.95);
    result.p99_ns = percentile(latencies[0..timed], 0.99);

    // Latency histogram over [min,max].
    result.hist_lo_ns = mn;
    result.hist_hi_ns = mx;
    histogram(latencies[0..timed], mn, mx, result.hist[0..]);

    return result;
}

// ============================================================================
// TESTS — pure percentile/histogram math (the load-bearing bit).
// ============================================================================
const testing = std.testing;

test "percentile: nearest-rank on [1..100]" {
    var data: [100]u64 = undefined;
    for (0..100) |i| data[i] = @intCast(i + 1); // 1..100, already sorted

    // p0 -> min, p1 -> max.
    try testing.expectEqual(@as(u64, 1), percentile(&data, 0.0));
    try testing.expectEqual(@as(u64, 100), percentile(&data, 1.0));
    // p50: rank = ceil(0.5*100)=50 -> index 49 -> value 50.
    try testing.expectEqual(@as(u64, 50), percentile(&data, 0.50));
    // p95: rank = ceil(0.95*100)=95 -> value 95.
    try testing.expectEqual(@as(u64, 95), percentile(&data, 0.95));
    // p99: rank = ceil(0.99*100)=99 -> value 99.
    try testing.expectEqual(@as(u64, 99), percentile(&data, 0.99));
}

test "percentile: single element + empty + clamping" {
    const one = [_]u64{42};
    try testing.expectEqual(@as(u64, 42), percentile(&one, 0.0));
    try testing.expectEqual(@as(u64, 42), percentile(&one, 0.5));
    try testing.expectEqual(@as(u64, 42), percentile(&one, 1.0));

    const empty = [_]u64{};
    try testing.expectEqual(@as(u64, 0), percentile(&empty, 0.5));

    // out-of-range p clamps into [0,1].
    const three = [_]u64{ 5, 10, 15 };
    try testing.expectEqual(@as(u64, 5), percentile(&three, -1.0));
    try testing.expectEqual(@as(u64, 15), percentile(&three, 2.0));
}

test "histogram: known vals land in the right bins" {
    var bins: [4]u32 = undefined;
    // range [0,40], 4 bins of width 10: [0,10),[10,20),[20,30),[30,40].
    const vals = [_]u64{ 0, 5, 9, 10, 15, 25, 40 };
    histogram(&vals, 0, 40, &bins);
    // 0,5,9 -> bin 0 (3); 10,15 -> bin 1 (2); 25 -> bin 2 (1); 40 -> last bin (1).
    try testing.expectEqual(@as(u32, 3), bins[0]);
    try testing.expectEqual(@as(u32, 2), bins[1]);
    try testing.expectEqual(@as(u32, 1), bins[2]);
    try testing.expectEqual(@as(u32, 1), bins[3]);
    var total: u32 = 0;
    for (bins) |b| total += b;
    try testing.expectEqual(@as(u32, vals.len), total);
}

test "histogram: lo==hi -> no div0, all in bin 0" {
    var bins: [5]u32 = undefined;
    const vals = [_]u64{ 7, 7, 7 };
    histogram(&vals, 7, 7, &bins);
    try testing.expectEqual(@as(u32, 3), bins[0]);
    for (1..5) |i| try testing.expectEqual(@as(u32, 0), bins[i]);
}

test "histogram: value==hi lands in last bin; out-of-range clamps" {
    var bins: [3]u32 = undefined;
    // range [10,40], 3 bins: [10,20),[20,30),[30,40].
    const vals = [_]u64{ 40, 5, 100 }; // hi, below-lo, above-hi
    histogram(&vals, 10, 40, &bins);
    // 40 -> last bin; 5 (<lo) -> bin 0; 100 (>hi) -> last bin.
    try testing.expectEqual(@as(u32, 1), bins[0]);
    try testing.expectEqual(@as(u32, 0), bins[1]);
    try testing.expectEqual(@as(u32, 2), bins[2]);
}

test "BenchResult.successPct" {
    var r = BenchResult{ .n = 200, .ok_count = 150 };
    try testing.expectApproxEqAbs(@as(f32, 75.0), r.successPct(), 1e-4);
    r.n = 0;
    try testing.expectEqual(@as(f32, 0), r.successPct());
}
