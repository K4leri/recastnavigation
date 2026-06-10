//! Micro-bench core: timing primitive, the Bench descriptor, the per-call stats
//! sampler, and the CSV runner. Bench GROUPS live in sibling files (bench_*.zig,
//! analogs_*.zig) and are aggregated by ../microbench.zig — keep this file free of
//! any function-specific benches so groups stay modular and navigable.
//!
//! See dev/research/PERFUNC_BENCH_GOAL.md.

const std = @import("std");
const builtin = @import("builtin");

/// Build-variant tag for every row (ReleaseFast / ReleaseSafe / Debug).
pub const variant = @tagName(builtin.mode);

// ---------------------------------------------------------------------------
// Timing (std.Io .awake clock — std.time.Timer is gone in Zig 0.16)
// ---------------------------------------------------------------------------
var io_backend: std.Io.Threaded = undefined;
var io_iface: std.Io = undefined;

fn nowNs() i128 {
    return std.Io.Clock.awake.now(io_iface).nanoseconds;
}

pub const Stats = struct {
    count: u64,
    min_ns: f64,
    mean_ns: f64,
    median_ns: f64,
    p95_ns: f64,
};

const batch_target_ns: i128 = 300_000; // ~0.3ms per batch (amortise the clock read)
const num_batches: usize = 64;
const max_k: usize = 1 << 28;

/// Time `run` (performs ONE call, taking the iteration index to perturb inputs so
/// the call is not loop-invariant). Auto-tunes the inner repeat K, then samples B
/// batches and reports per-call min/mean/median/p95 over the batch means.
pub fn measure(call: *const fn (usize) void) Stats {
    var k: usize = 1;
    while (k < max_k) {
        const t0 = nowNs();
        var i: usize = 0;
        while (i < k) : (i += 1) call(i);
        const dt = nowNs() - t0;
        if (dt >= batch_target_ns) break;
        const grow: usize = if (dt <= 0) 8 else @intCast(@max(2, @divTrunc(batch_target_ns, dt) + 1));
        k *|= grow;
    }
    var samples: [num_batches]f64 = undefined;
    for (&samples) |*s| {
        const t0 = nowNs();
        var i: usize = 0;
        while (i < k) : (i += 1) call(i);
        const dt = nowNs() - t0;
        s.* = @as(f64, @floatFromInt(@max(@as(i128, 0), dt))) / @as(f64, @floatFromInt(k));
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (samples) |v| sum += v;
    const p95_idx: usize = @intFromFloat(@as(f64, num_batches) * 0.95);
    return .{
        .count = @as(u64, num_batches) * k,
        .min_ns = samples[0],
        .mean_ns = sum / @as(f64, num_batches),
        .median_ns = samples[num_batches / 2],
        .p95_ns = samples[@min(p95_idx, num_batches - 1)],
    };
}

/// One benchmarked (function, implementation) pair.
pub const Bench = struct {
    name: []const u8,
    module: []const u8,
    /// "orig" = library's current implementation; any other label is an ANALOG —
    /// an alternative implementation whose `check` proves it identical to the original.
    impl: []const u8 = "orig",
    /// Isolatability class (A/B/C/D, see goal doc).
    isolation: []const u8,
    /// Optional one-time, UNTIMED setup run before this bench (class-B/C: build the
    /// prerequisite pipeline state once). null for leaf functions.
    setup: ?*const fn () void = null,
    run: *const fn (usize) void,
    /// Correctness gate. "orig": output == known expected value. Analog: output ==
    /// the original over an input sweep (proves behaviour-preserving before ranking).
    check: *const fn () bool,
};

/// CSV runner: header + one flushed row per bench (crash-safe). Out path is argv[1]
/// or microbench_trace_<variant>.csv.
pub fn run(benches: []const Bench, init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    io_backend = std.Io.Threaded.init(allocator, .{});
    io_iface = io_backend.io();
    defer io_backend.deinit();

    var out_buf: [256]u8 = undefined;
    var out_path: []const u8 = std.fmt.bufPrint(&out_buf, "microbench_trace_{s}.csv", .{variant}) catch "microbench_trace.csv";
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer it.deinit();
        _ = it.skip();
        if (it.next()) |a| out_path = std.fmt.bufPrint(&out_buf, "{s}", .{a}) catch out_path;
    }

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    var wbuf: [8 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &wbuf);
    const w = &fw.interface;

    try w.writeAll("function,module,impl,variant,count,min_ns,mean_ns,median_ns,p95_ns,isolation,check_ok\n");
    try w.flush();

    var fails: usize = 0;
    for (benches) |b| {
        if (b.setup) |s| s(); // one-time prerequisite build (untimed)
        // check_ok: orig -> output matches expected; analog -> identical to original over
        // the sweep. A FALSE analog is REJECTED (not behaviour-preserving) — recorded, not fatal.
        const ok = b.check();
        if (!ok) {
            fails += 1;
            const kind = if (std.mem.eql(u8, b.impl, "orig")) "CORRECTNESS FAIL" else "ANALOG REJECTED (not identical)";
            std.debug.print("[microbench] {s}: {s}/{s} impl={s}\n", .{ kind, b.module, b.name, b.impl });
        }
        const s = measure(b.run);
        try w.print("{s},{s},{s},{s},{d},{d:.2},{d:.2},{d:.2},{d:.2},{s},{s}\n", .{
            b.name, b.module, b.impl, variant, s.count, s.min_ns, s.mean_ns, s.median_ns, s.p95_ns, b.isolation,
            if (ok) "yes" else "no",
        });
        try w.flush();
    }
    std.debug.print("[microbench] variant={s}: {d} bench rows, {d} not-identical/fail -> {s}\n", .{ variant, benches.len, fails, out_path });
}
