//! Tests for the in-process timing registry (src/tracy_registry.zig).
//!
//! NOTE on timing API: the task spec / model used `std.time.Timer` +
//! `std.Thread.sleep`, but BOTH were removed in this Zig 0.16.0 (timing moved
//! behind the `std.Io` interface). We therefore drive sleeps through
//! `std.Io.sleep(io, Duration, .awake)` and let the registry measure elapsed
//! wall time itself via the monotonic `.awake` clock. Semantics (self vs
//! inclusive aggregation) are identical to the model.

const std = @import("std");
const reg = @import("tracy_registry");

/// Sleep helper using the Zig 0.16 std.Io monotonic-friendly sleep.
fn sleepMs(ms: u64) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Warm up the OS timer subsystem once. On Windows the very first `Io.sleep`
/// after process start can return early (default timer granularity ~15.6 ms is
/// only raised on first use), which would make tight absolute-duration
/// assertions flaky. A throwaway sleep stabilizes subsequent sleeps.
var warmed: bool = false;
fn warmup() void {
    if (warmed) return;
    sleepMs(5);
    warmed = true;
}

test "nested zones: self-time subtracts child inclusive" {
    warmup();
    reg.reset();
    {
        var outer = reg.ScopeTimer.start("outer");
        sleepMs(20);
        {
            var inner = reg.ScopeTimer.start("inner");
            sleepMs(30);
            inner.stop();
        }
        outer.stop();
    }
    const o = reg.get("outer").?;
    const i = reg.get("inner").?;
    try std.testing.expect(i.count == 1 and o.count == 1);
    // Absolute durations use generous slop: Windows std.Io.sleep granularity can
    // be coarse, but it never returns dramatically early after warmup. The exact
    // self/inclusive RELATIONSHIP below is the real contract.
    try std.testing.expect(i.inclusive_ns >= 25 * std.time.ns_per_ms);
    try std.testing.expect(o.inclusive_ns >= 45 * std.time.ns_per_ms);
    // outer self excludes inner's inclusive time
    try std.testing.expect(o.self_ns < o.inclusive_ns);
    try std.testing.expect(o.self_ns >= 10 * std.time.ns_per_ms); // ~20ms of its own work
    // outer.self == outer.inclusive - inner.inclusive (self subtracts direct child).
    // Both sides measured off the same monotonic clock, so the identity is exact
    // up to the single subtraction; allow 5ms slack for clock-read jitter.
    try std.testing.expect(o.self_ns + i.inclusive_ns <= o.inclusive_ns + 5 * std.time.ns_per_ms);
    try std.testing.expect(o.self_ns + i.inclusive_ns + 5 * std.time.ns_per_ms >= o.inclusive_ns);
}

test "noop timer records nothing" {
    reg.reset();
    var z = reg.ScopeTimer.noop();
    z.stop();
    try std.testing.expect(reg.get("anything") == null);
}

test "repeated zone aggregates count/min/max" {
    warmup();
    reg.reset();
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        var z = reg.ScopeTimer.start("loop");
        sleepMs(10);
        z.stop();
    }
    const s = reg.get("loop").?;
    try std.testing.expect(s.count == 3);
    try std.testing.expect(s.max_ns >= s.min_ns);
    try std.testing.expect(s.inclusive_ns >= 25 * std.time.ns_per_ms);
}

test "dumpCsv emits header and sorted zone rows" {
    warmup();
    reg.reset();
    // Two zones in non-alphabetical insertion order; output must be sorted.
    {
        var z = reg.ScopeTimer.start("zeta");
        sleepMs(1);
        z.stop();
    }
    {
        var z = reg.ScopeTimer.start("alpha");
        sleepMs(1);
        z.stop();
    }

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try reg.writeCsvHeader(w);
    try reg.dumpCsv(w, "smoke_scenario");

    const out = aw.written();
    // Header present (exact contract).
    try std.testing.expect(std.mem.indexOf(u8, out, "scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns") != null);
    // Both rows present, scenario id prefixing each row.
    try std.testing.expect(std.mem.indexOf(u8, out, "smoke_scenario,alpha,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "smoke_scenario,zeta,") != null);
    // Deterministic sort: alpha row must come before zeta row.
    const ia = std.mem.indexOf(u8, out, "smoke_scenario,alpha,").?;
    const iz = std.mem.indexOf(u8, out, "smoke_scenario,zeta,").?;
    try std.testing.expect(ia < iz);
}

test "plot records last/count/sum" {
    reg.reset();
    reg.plot("agents", 25);
    reg.plot("agents", 100);
    reg.plot("agents", 50);
    const p = reg.getPlot("agents").?;
    try std.testing.expect(p.count == 3);
    try std.testing.expect(p.last == 50);
    try std.testing.expect(p.sum == 175);
    try std.testing.expect(reg.getPlot("missing") == null);
}
