//! Analog group: alternative implementations of recast leaf helpers, each EXACT-gated
//! against the original over an input sweep. Modular per module. Aggregated by
//! ../microbench.zig. See analogs_math.zig for the analog method/verdict conventions.

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

/// distancePtSeg (recast.contour) via fma. The orig computes the segment distance with
/// d = pqx*pqx+pqz*pqz, t = pqx*dx+pqz*dz, ret = dx*dx+dz*dz (sums of products). The
/// analog fuses each with @mulAdd. fma changes the intermediate rounding, so unless LLVM
/// already contracts the orig identically the EXACT gate REJECTS it (check_ok=no) —
/// empirical proof it is not behaviour-preserving; the original stays.
fn distancePtSeg_fma(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
    const pqx: f32 = @floatFromInt(qx - px);
    const pqz: f32 = @floatFromInt(qz - pz);
    var dx: f32 = @floatFromInt(x - px);
    var dz: f32 = @floatFromInt(z - pz);
    const d = @mulAdd(f32, pqx, pqx, pqz * pqz);
    var t = @mulAdd(f32, pqx, dx, pqz * dz);
    if (d > 0) t /= d;
    if (t < 0) t = 0 else if (t > 1) t = 1;
    const px_f: f32 = @floatFromInt(px);
    const x_f: f32 = @floatFromInt(x);
    const pz_f: f32 = @floatFromInt(pz);
    const z_f: f32 = @floatFromInt(z);
    dx = @mulAdd(f32, t, pqx, px_f) - x_f;
    dz = @mulAdd(f32, t, pqz, pz_f) - z_f;
    return @mulAdd(f32, dx, dx, dz * dz);
}
fn runDistancePtSegFma(i: usize) void {
    const o: i32 = @intCast(i & 31);
    dna(distancePtSeg_fma(3 + o, 7, 0, 0, 10, 10));
}
fn checkDistancePtSegFma() bool {
    // EXACT identity vs the original over a sweep of integer point/segment positions.
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        var j: i32 = 0;
        while (j < 64) : (j += 1) {
            if (distancePtSeg_fma(i, j, 0, 0, 17, 31) != nav.recast.contour.distancePtSeg(i, j, 0, 0, 17, 31)) return false;
        }
    }
    return true;
}

pub const benches = [_]core.Bench{
    .{ .name = "distancePtSeg", .module = "recast.contour", .impl = "fma", .isolation = "A", .run = runDistancePtSegFma, .check = checkDistancePtSegFma },
};
