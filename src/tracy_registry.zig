//! In-process timing registry — the PRIMARY data source for the Zig-vs-C++
//! Recast/Detour/Crowd benchmark comparison (Tracy's external capture tools are
//! not installed here). It aggregates, per named zone, an inclusive + self time
//! profile and dumps it to CSV in a format that the C++ `rn_registry` must match
//! byte-for-byte.
//!
//! ## Model
//!
//! Each `ScopeTimer` is RAII-like: `start(name)` records a monotonic start
//! timestamp and pushes itself onto a per-thread zone stack; `stop()` pops,
//! computes its inclusive duration `dur`, and folds time into the aggregate map.
//!
//! Self-time uses the standard "subtract children" accounting: every active zone
//! owns a `child_ns` accumulator. When a child zone stops it adds its own full
//! inclusive `dur` to the *parent's* `child_ns`. So when a zone stops,
//! `self = dur - self.child_ns` is exactly its inclusive time minus the inclusive
//! time of all its DIRECT children (grandchildren are already folded into the
//! child's inclusive time, so they are not double-counted).
//!
//! Aggregation per zone name: `count += 1; inclusive_ns += dur;
//! self_ns += (dur - child_ns); min/max update on dur`.
//!
//! ## Timing source (Zig 0.16)
//!
//! On Windows: `nowNs()` calls `RtlQueryPerformanceCounter` directly via
//! `std.os.windows.ntdll`, with the frequency cached in a process-global `u64`.
//! No spinlock, no vtable, no `std.Io` — ~20-30 cycles per call, matching the
//! C++ `std::chrono::steady_clock` overhead for symmetric benchmarking.
//!
//! On other platforms: falls back to `std.Io.Clock.awake` via a lazily-
//! initialized process-global `std.Io.Threaded` (guarded by the same mutex as
//! the map). The clock read is a plain syscall; it does NOT block or schedule.
//!
//! ## Thread-safety
//!
//! The zone stack is `threadlocal` (per-thread, no locking needed). The global
//! aggregate map + plot map (and on non-Windows: the shared `Io` backend) are
//! guarded by a single spinlock. The crowd pipeline is single-threaded today,
//! but the registry stays correct under concurrent zones on distinct threads.
//! On Windows, `nowNs()` uses a lock-free cached QPF read.
//!
//! ## Key lifetime
//!
//! Zone/plot names are expected to be 'static-lifetime string literals (the
//! canonical zone names, e.g. "rcBuildRegions", are comptime literals that live
//! for the whole program). We therefore store the slice directly as the map key
//! WITHOUT duping — the map borrows the caller's memory. Passing a transient,
//! caller-freed slice as a zone name is a misuse and would leave a dangling key.
//!
//! ## Recursion (same zone name nested in itself)
//!
//! Chosen behavior: each `ScopeTimer` instance carries its OWN `child_ns`, so a
//! recursive call produces a fresh stack entry with a fresh accumulator. Each
//! activation aggregates independently into the single named `Stat` (so `count`
//! counts activations, and `inclusive_ns` over-counts wall time across recursion
//! levels just like any flat per-name aggregator — this matches Tracy's per-zone
//! accounting and the C++ counterpart). Self-time per activation still correctly
//! excludes its direct children.

const std = @import("std");
const builtin = @import("builtin");

/// Per-zone aggregate statistics. Times are nanoseconds.
pub const Stat = struct {
    /// Number of completed activations of this zone.
    count: u64 = 0,
    /// Total wall time between start and stop, summed over all calls
    /// (includes time spent in nested child zones).
    inclusive_ns: u64 = 0,
    /// Inclusive time minus the inclusive time attributed to direct child zones.
    self_ns: u64 = 0,
    /// Minimum inclusive duration of a single call.
    min_ns: u64 = std.math.maxInt(u64),
    /// Maximum inclusive duration of a single call.
    max_ns: u64 = 0,
};

/// Named scalar plot sample aggregate (e.g. agent count, span count).
pub const PlotStat = struct {
    /// Most recently recorded value.
    last: f64 = 0,
    /// Number of samples recorded.
    count: u64 = 0,
    /// Sum of all recorded values (for computing a mean).
    sum: f64 = 0,
};

/// Maximum zone nesting depth tracked per thread. Real Recast/Detour/Crowd
/// pipelines nest only a handful of zones deep; exceeding this is a bug. We
/// degrade gracefully: zones above the limit are still timed but contribute
/// neither self-time accounting nor a parent fold (see `stop`).
const max_depth = 64;

/// One active (started, not yet stopped) zone on the thread-local stack. We
/// store the child accumulator BY VALUE in the stack (not via a pointer back to
/// the returned ScopeTimer) because `start` returns by value — the caller's
/// `var` copy is the live one and its address is not knowable inside `start`.
/// Keeping `child_ns` in the stack slot sidesteps that entirely: a child folds
/// its inclusive `dur` into its parent's slot via the parent's stack depth.
const StackEntry = struct {
    /// Inclusive time consumed by this zone's DIRECT children, accumulated as
    /// each child stops. `self = dur - child_ns`.
    child_ns: u64,
};

/// Per-thread stack of active zones. `threadlocal` => no locking on the stack.
threadlocal var stack: [max_depth]StackEntry = undefined;
threadlocal var stack_len: usize = 0;

/// RAII-style scope timer. Construct with `start` (live zone) or `noop`
/// (disabled deep zone — all ops are no-ops). Must call `stop` exactly once.
pub const ScopeTimer = struct {
    name: []const u8,
    /// Monotonic start timestamp (ns from QPC). Unused when noop.
    start_ns: i64,
    /// This zone's index in the thread-local stack (its depth). `no_slot` when
    /// the zone overflowed the depth limit (it is still timed, but does not
    /// participate in parent/child folding).
    depth: usize,
    /// True for a disabled (deep) zone: start/stop do nothing.
    is_noop: bool,

    /// Sentinel depth meaning "not on the stack" (overflow case).
    const no_slot = std.math.maxInt(usize);

    /// Begin timing a zone and push it onto the thread-local stack.
    /// `name` must be a 'static-lifetime slice (string literal).
    pub fn start(name: []const u8) ScopeTimer {
        const ts = nowNs();
        var depth: usize = no_slot;
        // Push a fresh slot with a zeroed child accumulator. On overflow we keep
        // timing but skip stack participation (its self == inclusive). Overflow
        // only happens past `max_depth` nesting, which indicates a bug upstream.
        if (stack_len < max_depth) {
            depth = stack_len;
            stack[stack_len] = .{ .child_ns = 0 };
            stack_len += 1;
        }
        return .{
            .name = name,
            .start_ns = ts,
            .depth = depth,
            .is_noop = false,
        };
    }

    /// A disabled zone: timing and aggregation are skipped entirely.
    pub fn noop() ScopeTimer {
        return .{ .name = "", .start_ns = 0, .depth = no_slot, .is_noop = true };
    }

    /// Stop timing, compute self-time, fold into parent, and aggregate.
    /// Must be called exactly once; calling twice double-counts.
    pub fn stop(self: *ScopeTimer) void {
        if (self.is_noop) return;

        const end_ns = nowNs();
        const dur: u64 = blk: {
            const d = end_ns - self.start_ns;
            break :blk if (d < 0) 0 else @intCast(d);
        };

        var child_ns: u64 = 0;
        if (self.depth != no_slot and self.depth < stack_len) {
            // LIFO discipline: this zone should be the current top of stack.
            // Read our own accumulated child time, then pop us.
            child_ns = stack[self.depth].child_ns;
            stack_len = self.depth;
            // Fold our full inclusive duration into the parent's slot so the
            // parent's self-time excludes us.
            if (self.depth > 0) {
                stack[self.depth - 1].child_ns += dur;
            }
        }

        const self_ns = dur - @min(child_ns, dur);
        aggregate(self.name, dur, self_ns);
    }
};

// ---------------------------------------------------------------------------
// Cheap registry clock — Windows direct QueryPerformanceCounter path.
// ---------------------------------------------------------------------------

/// Cached QPF (ticks per second). Populated once on first call.
/// Reads are always done under no lock — QPF is process-invariant after init,
/// and worst-case a second thread also initialises it to the same value.
var qpc_freq: u64 = 0;

/// Read the monotonic clock in nanoseconds. On Windows: direct QPC with a
/// cached frequency (~20-30 cycles, no spinlock, no vtable). On other
/// platforms: std.Io.Clock.awake (existing portable path, lazily-inited).
fn nowNs() i64 {
    if (builtin.os.tag == .windows) {
        if (qpc_freq == 0) {
            var f: std.os.windows.LARGE_INTEGER = undefined;
            _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&f);
            qpc_freq = @bitCast(f); // i64 → u64; QPF is always positive
        }
        var c: std.os.windows.LARGE_INTEGER = undefined;
        _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&c);
        const counter: u64 = @bitCast(c);
        // u128 intermediate prevents overflow (counter * 1e9 overflows u64).
        return @intCast(@as(u128, counter) * 1_000_000_000 / qpc_freq);
    } else {
        const io = sharedIo();
        return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    }
}

// ---------------------------------------------------------------------------
// Global state (map, plots, shared Io) — guarded by `mutex`.
// ---------------------------------------------------------------------------

/// Tiny atomic spinlock guarding the global maps + shared Io backend.
///
/// Why not `std.Thread.Mutex` / `std.Io.Mutex`? In Zig 0.16 `std.Thread.Mutex`
/// no longer exists and `std.Io.Mutex.lock/unlock` require an `Io` handle —
/// threading `io` through every `get`/`aggregate` would change the public API
/// and create a lock-ordering hazard with `sharedIo()` (which itself must lock).
/// The critical sections here are a handful of hashmap ops; under the
/// single-threaded benchmark this lock is never contended (the CAS succeeds on
/// the first try), and it is still correct if zones ever run on multiple threads.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var mutex: SpinLock = .{};
var initialized: bool = false;

// page_allocator-backed: the registry is a long-lived process-global tool; we
// never free the map (reset clears entries but keeps capacity). Keys are
// borrowed 'static literals, so the allocator only owns map nodes/buckets.
var map: std.StringHashMap(Stat) = undefined;
var plots: std.StringHashMap(PlotStat) = undefined;

// Non-Windows only: shared Io backend for monotonic clock reads.
// On Windows, nowNs() goes through direct QPC (no Io backend needed).
var io_backend: if (builtin.os.tag != .windows) std.Io.Threaded else void = undefined;
var io_iface: if (builtin.os.tag != .windows) std.Io else void = undefined;

fn ensureInit() void {
    if (initialized) return;
    map = std.StringHashMap(Stat).init(std.heap.page_allocator);
    plots = std.StringHashMap(PlotStat).init(std.heap.page_allocator);
    if (builtin.os.tag != .windows) {
        io_backend = std.Io.Threaded.init(std.heap.page_allocator, .{});
        io_iface = io_backend.io();
    }
    initialized = true;
}

fn sharedIo() std.Io {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    return io_iface;
}

/// Fold a completed zone activation into its named aggregate.
fn aggregate(name: []const u8, dur: u64, self_ns: u64) void {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();

    const gop = map.getOrPut(name) catch {
        // OOM on a benchmarking tool: drop the sample rather than crash the run.
        return;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const s = gop.value_ptr;
    s.count += 1;
    s.inclusive_ns += dur;
    s.self_ns += self_ns;
    if (dur < s.min_ns) s.min_ns = dur;
    if (dur > s.max_ns) s.max_ns = dur;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Clear all aggregated zone + plot data and reset the thread-local stack.
/// Call between scenarios or in test setup. Capacity is retained.
pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    map.clearRetainingCapacity();
    plots.clearRetainingCapacity();
    // Reset the calling thread's stack. (Other threads, if any, reset their own
    // threadlocal state lazily; in a benchmark this runs single-threaded.)
    stack_len = 0;
}

/// Look up the aggregate for a zone by name. Null if never recorded.
pub fn get(name: []const u8) ?Stat {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    return map.get(name);
}

/// Number of distinct zones currently aggregated (= rows `dumpCsv` will emit).
/// Used by callers to assert a scenario actually recorded something (guard
/// against an empty-CSV regression).
pub fn zoneCount() usize {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    return map.count();
}

/// Record a named scalar sample (last value + running count/sum).
pub fn plot(name: []const u8, val: f64) void {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    const gop = plots.getOrPut(name) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const p = gop.value_ptr;
    p.last = val;
    p.count += 1;
    p.sum += val;
}

/// Look up a plot aggregate by name. Null if never recorded.
pub fn getPlot(name: []const u8) ?PlotStat {
    mutex.lock();
    defer mutex.unlock();
    ensureInit();
    return plots.get(name);
}

/// CSV header — the EXACT column contract shared with the C++ rn_registry.
/// Write this once per output file before any `dumpCsv` rows.
pub fn writeCsvHeader(writer: anytype) !void {
    try writer.writeAll("scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns\n");
}

/// Append one CSV row per recorded zone, sorted by zone name for deterministic
/// diffable output. `mean_ns = inclusive_ns / count`. Rows are prefixed with
/// `scenario_id`. Does NOT write the header (call `writeCsvHeader` first).
pub fn dumpCsv(writer: anytype, scenario_id: []const u8) !void {
    // Snapshot the zone names under the lock, then sort and emit. We copy names
    // (borrowed 'static slices) into a temporary list so we can release the lock
    // before touching the writer (the writer may do I/O / block).
    var names = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer names.deinit();
    var rows = std.array_list.Managed(Stat).init(std.heap.page_allocator);
    defer rows.deinit();

    {
        mutex.lock();
        defer mutex.unlock();
        ensureInit();
        try names.ensureTotalCapacity(map.count());
        try rows.ensureTotalCapacity(map.count());
        var it = map.iterator();
        while (it.next()) |e| {
            names.appendAssumeCapacity(e.key_ptr.*);
            rows.appendAssumeCapacity(e.value_ptr.*);
        }
    }

    // Co-sort names + rows by name. Build an index permutation to keep it simple.
    const n = names.items.len;
    const idx = try std.heap.page_allocator.alloc(usize, n);
    defer std.heap.page_allocator.free(idx);
    for (idx, 0..) |*p, i| p.* = i;
    const Ctx = struct {
        names: [][]const u8,
        fn lessThan(self: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, self.names[a], self.names[b]);
        }
    };
    std.mem.sort(usize, idx, Ctx{ .names = names.items }, Ctx.lessThan);

    for (idx) |i| {
        const name = names.items[i];
        const s = rows.items[i];
        const mean: u64 = if (s.count == 0) 0 else s.inclusive_ns / s.count;
        const min_out: u64 = if (s.count == 0) 0 else s.min_ns;
        try writer.print("{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
            scenario_id,
            name,
            s.count,
            s.inclusive_ns,
            s.self_ns,
            mean,
            min_out,
            s.max_ns,
        });
    }
}
