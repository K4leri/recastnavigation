//! Bench group: recast leaf / pure helpers (isolation class A) callable with plain
//! inputs (no pipeline prerequisite). Stage functions (class B) and internal helpers
//! (class C) get their own groups (bench_recast_stage.zig) as they are wired with
//! prerequisite setup. Aggregated by ../microbench.zig.

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

fn runDistancePtSeg(i: usize) void {
    const o: i32 = @intCast(i & 31);
    dna(nav.recast.contour.distancePtSeg(3 + o, 7, 0, 0, 10, 10));
}
fn checkDistancePtSeg() bool {
    // pt(5,5) on segment (0,0)-(10,10) -> dist^2 = 0
    return nav.recast.contour.distancePtSeg(5, 5, 0, 0, 10, 10) < 1e-3;
}

pub const benches = [_]core.Bench{
    .{ .name = "distancePtSeg", .module = "recast.contour", .isolation = "A", .run = runDistancePtSeg, .check = checkDistancePtSeg },
};
