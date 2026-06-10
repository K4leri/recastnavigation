//! Analog group: alternative implementations of math.zig functions, each PROVEN
//! identical to the original (its `check` compares against the library fn over an
//! input sweep). Grouped here so analogs stay modular and discoverable per module.
//! Aggregated by ../microbench.zig.

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

/// ilog2 via count-leading-zeros: one CLZ vs the original's 5-stage shift cascade.
/// floor(log2) — bit-identical to math.ilog2 for all u32.
pub fn ilog2_clz(v: u32) u32 {
    return if (v == 0) 0 else 31 - @clz(v);
}
fn runIlog2Clz(i: usize) void {
    dna(ilog2_clz(@as(u32, @intCast(64 + (i & 63)))));
}
fn checkIlog2Clz() bool {
    var x: u32 = 0;
    while (x < 200_000) : (x += 1) {
        if (ilog2_clz(x) != nav.math.ilog2(x)) return false;
    }
    for ([_]u32{ 0, 1, 2, 255, 256, 0x7fffffff, 0x80000000, 0xffffffff }) |t| {
        if (ilog2_clz(t) != nav.math.ilog2(t)) return false;
    }
    return true;
}

/// nextPow2 via CLZ. Identical to math.nextPow2 for v <= 2^31.
pub fn nextPow2_clz(v: u32) u32 {
    return if (v <= 1) 1 else @as(u32, 1) << @intCast(32 - @clz(v - 1));
}
fn runNextPow2Clz(i: usize) void {
    dna(nextPow2_clz(@as(u32, @intCast(100 + (i & 63)))));
}
fn checkNextPow2Clz() bool {
    var x: u32 = 0;
    while (x < 200_000) : (x += 1) {
        if (nextPow2_clz(x) != nav.math.nextPow2(x)) return false;
    }
    for ([_]u32{ 0, 1, 2, 3, 255, 256, 257, 0x20000000, 0x40000000 }) |t| {
        if (nextPow2_clz(t) != nav.math.nextPow2(t)) return false;
    }
    return true;
}

/// overlapQuantBounds as a flat AND-chain instead of the original's per-axis
/// if/else fold. Bool result is bit-identical (De Morgan of the original test).
pub fn overlapQuantBounds_and(amin: *const [3]u16, amax: *const [3]u16, bmin: *const [3]u16, bmax: *const [3]u16) bool {
    return amin[0] <= bmax[0] and amax[0] >= bmin[0] and
        amin[1] <= bmax[1] and amax[1] >= bmin[1] and
        amin[2] <= bmax[2] and amax[2] >= bmin[2];
}
fn runOverlapAnd(i: usize) void {
    const f: u16 = @intCast(i & 3);
    dna(overlapQuantBounds_and(&[3]u16{ 0, 0, 0 }, &[3]u16{ 5 + f, 5, 5 }, &[3]u16{ 3, 3, 3 }, &[3]u16{ 8, 8, 8 }));
}
fn checkOverlapAnd() bool {
    // EXACT identity vs the original over a sweep of box pairs.
    var i: u16 = 0;
    while (i < 40) : (i += 1) {
        var j: u16 = 0;
        while (j < 40) : (j += 1) {
            const amin = [3]u16{ i, 2, i };
            const amax = [3]u16{ i + 6, 8, i + 4 };
            const bmin = [3]u16{ j, 1, j };
            const bmax = [3]u16{ j + 5, 9, j + 7 };
            if (overlapQuantBounds_and(&amin, &amax, &bmin, &bmax) != nav.math.overlapQuantBounds(&amin, &amax, &bmin, &bmax)) return false;
        }
    }
    return true;
}

/// vdot via fused multiply-add. PLAUSIBLE faster analog — but @mulAdd fuses the
/// rounding, so the result is NOT bit-identical to the original a*b+c*d+e*f. The
/// EXACT-identity gate rejects it (recorded check_ok=no) — empirical proof that this
/// alternative is not behaviour-preserving, so the original is kept.
fn vdot_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return @mulAdd(f32, v1[2], v2[2], @mulAdd(f32, v1[1], v2[1], v1[0] * v2[0]));
}
fn runVdotFma(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(vdot_fma(&[3]f32{ 1 + f, 2.3, 3.7 }, &[3]f32{ 4.1, 5.9, 6.2 }));
}
fn checkVdotFma() bool {
    // EXACT (bit) identity required. fma changes rounding -> expected to differ.
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const a = [3]f32{ @floatFromInt(i), 2.3, 3.7 };
        const b = [3]f32{ 4.1, @floatFromInt(i % 97), 6.2 };
        if (vdot_fma(&a, &b) != nav.math.vdot(&a, &b)) return false; // not bit-identical -> REJECTED
    }
    return true;
}

/// triArea2D via fma — same algebra, fused rounding. Not bit-identical -> gate rejects.
fn triArea2D_fma(a: Vec3, b: Vec3, c: Vec3) f32 {
    const abz = b.z - a.z;
    const acx = c.x - a.x;
    const abx = b.x - a.x;
    const acz = c.z - a.z;
    return @mulAdd(f32, acx, abz, -(abx * acz));
}
const Vec3 = nav.math.Vec3;
fn runTriAreaFma(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(triArea2D_fma(Vec3.init(0, 0, 0), Vec3.init(4 + f, 0, 1.3), Vec3.init(2, 0, 5.7)));
}
fn checkTriAreaFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const a = Vec3.init(0, 0, 0);
        const b = Vec3.init(fa * 0.7, 0, 1.3);
        const c = Vec3.init(2.1, 0, fa * 0.3);
        if (triArea2D_fma(a, b, c) != nav.math.triArea2D(a, b, c)) return false; // not bit-identical -> REJECTED
    }
    return true;
}

// ===========================================================================
// fma-reassociation analogs (SCALAR — no SIMD, per user constraint). Each rewrites
// an a*b±c*d / sum-of-products with @mulAdd. fma fuses the intermediate rounding,
// so the result is generally NOT bit-identical -> the EXACT gate REJECTS it
// (check_ok=no): empirical proof the faster-looking analog changes behaviour and
// the original must stay. (Some bool-returning ones may still PASS if the verdict
// never flips over the sweep — recorded as TIE; that too is an empirical result.)
// ===========================================================================
fn eq3(a: [3]f32, b: [3]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}
fn eqV(a: Vec3, b: Vec3) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

// --- vmad: dest = v1 + v2*s ---
fn vmad_fma(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32, s: f32) void {
    dest[0] = @mulAdd(f32, v2[0], s, v1[0]);
    dest[1] = @mulAdd(f32, v2[1], s, v1[1]);
    dest[2] = @mulAdd(f32, v2[2], s, v1[2]);
}
fn runVmadFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vmad_fma(&d, &.{ 1.1 + f, 2.2, 3.3 }, &.{ 0.5, 1.5 + f, 2.5 }, 0.75);
    dna(d[0]);
}
fn checkVmadFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const v2 = [3]f32{ 0.5, fa * 0.1, 2.5 };
        var a: [3]f32 = undefined;
        var b: [3]f32 = undefined;
        vmad_fma(&a, &v1, &v2, 0.75);
        nav.math.vmad(&b, &v1, &v2, 0.75);
        if (!eq3(a, b)) return false;
    }
    return true;
}

// --- vlerp: dest = v1 + (v2-v1)*t ---
fn vlerp_fma(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32, t: f32) void {
    dest[0] = @mulAdd(f32, v2[0] - v1[0], t, v1[0]);
    dest[1] = @mulAdd(f32, v2[1] - v1[1], t, v1[1]);
    dest[2] = @mulAdd(f32, v2[2] - v1[2], t, v1[2]);
}
fn runVlerpFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vlerp_fma(&d, &.{ 1.1 + f, 2.2, 3.3 }, &.{ 7.5, 1.5 + f, 9.5 }, 0.3);
    dna(d[0]);
}
fn checkVlerpFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const v2 = [3]f32{ 7.5, fa * 0.1, 9.5 };
        var a: [3]f32 = undefined;
        var b: [3]f32 = undefined;
        vlerp_fma(&a, &v1, &v2, 0.3);
        nav.math.vlerp(&b, &v1, &v2, 0.3);
        if (!eq3(a, b)) return false;
    }
    return true;
}

// --- vcross ---
fn vcross_fma(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void {
    dest[0] = @mulAdd(f32, v1[1], v2[2], -(v1[2] * v2[1]));
    dest[1] = @mulAdd(f32, v1[2], v2[0], -(v1[0] * v2[2]));
    dest[2] = @mulAdd(f32, v1[0], v2[1], -(v1[1] * v2[0]));
}
fn runVcrossFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vcross_fma(&d, &.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2 + f, 6.3 });
    dna(d[0]);
}
fn checkVcrossFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const v2 = [3]f32{ 4.1, fa * 0.1, 6.3 };
        var a: [3]f32 = undefined;
        var b: [3]f32 = undefined;
        vcross_fma(&a, &v1, &v2);
        nav.math.vcross(&b, &v1, &v2);
        if (!eq3(a, b)) return false;
    }
    return true;
}

// --- vperp2D: v1[0]*v2[2] - v1[2]*v2[0] ---
fn vperp2D_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return @mulAdd(f32, v1[0], v2[2], -(v1[2] * v2[0]));
}
fn runVperpFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vperp2D_fma(&.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2, 6.3 + f }));
}
fn checkVperpFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const v2 = [3]f32{ 4.1, 5.2, fa * 0.1 };
        if (vperp2D_fma(&v1, &v2) != nav.math.vperp2D(&v1, &v2)) return false;
    }
    return true;
}

// --- vlenSqr / vlen (sum of squares) ---
fn vlenSqr_fma(v: *const [3]f32) f32 {
    return @mulAdd(f32, v[2], v[2], @mulAdd(f32, v[1], v[1], v[0] * v[0]));
}
fn runVlenSqrFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vlenSqr_fma(&.{ 1.1 + f, 2.2, 3.3 }));
}
fn checkVlenSqrFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, fa * 0.1, 3.3 };
        if (vlenSqr_fma(&v) != nav.math.vlenSqr(&v)) return false;
    }
    return true;
}
fn vlen_fma(v: *const [3]f32) f32 {
    return @sqrt(vlenSqr_fma(v));
}
fn runVlenFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vlen_fma(&.{ 1.1 + f, 2.2, 3.3 }));
}
fn checkVlenFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, fa * 0.1, 3.3 };
        if (vlen_fma(&v) != nav.math.vlen(&v)) return false;
    }
    return true;
}

// --- vdistSqr / vdist / vdist2D / vdist2DSqr ---
fn vdistSqr_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dy = v2[1] - v1[1];
    const dz = v2[2] - v1[2];
    return @mulAdd(f32, dz, dz, @mulAdd(f32, dy, dy, dx * dx));
}
fn runVdistSqrFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vdistSqr_fma(&.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2, 6.3 }));
}
fn checkVdistSqrFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, fa * 0.05 };
        const v2 = [3]f32{ 4.1, fa * 0.1, 6.3 };
        if (vdistSqr_fma(&v1, &v2) != nav.math.vdistSqr(&v1, &v2)) return false;
    }
    return true;
}
fn vdist_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return @sqrt(vdistSqr_fma(v1, v2));
}
fn runVdistFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vdist_fma(&.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2, 6.3 }));
}
fn checkVdistFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, fa * 0.05 };
        const v2 = [3]f32{ 4.1, fa * 0.1, 6.3 };
        if (vdist_fma(&v1, &v2) != nav.math.vdist(&v1, &v2)) return false;
    }
    return true;
}
fn vdist2DSqr_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dz = v2[2] - v1[2];
    return @mulAdd(f32, dx, dx, dz * dz);
}
fn runVdist2DSqrFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vdist2DSqr_fma(&.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2, 6.3 }));
}
fn checkVdist2DSqrFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, fa * 0.05 };
        const v2 = [3]f32{ 4.1, 5.2, 6.3 };
        if (vdist2DSqr_fma(&v1, &v2) != nav.math.vdist2DSqr(&v1, &v2)) return false;
    }
    return true;
}
fn vdist2D_fma(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return @sqrt(vdist2DSqr_fma(v1, v2));
}
fn runVdist2DFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(vdist2D_fma(&.{ 1.1 + f, 2.2, 3.3 }, &.{ 4.1, 5.2, 6.3 }));
}
fn checkVdist2DFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v1 = [3]f32{ fa * 0.3, 2.2, fa * 0.05 };
        const v2 = [3]f32{ 4.1, 5.2, 6.3 };
        if (vdist2D_fma(&v1, &v2) != nav.math.vdist2D(&v1, &v2)) return false;
    }
    return true;
}

// --- vequal (bool: distSq < threshold) ---
fn vequal_fma(a: *const [3]f32, b: *const [3]f32) bool {
    const threshold = comptime nav.math.sqr(f32, 1.0 / 16384.0);
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return @mulAdd(f32, dz, dz, @mulAdd(f32, dy, dy, dx * dx)) < threshold;
}
fn runVequalFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 7);
    dna(vequal_fma(&.{ 1.1, 2.2, 3.3 }, &.{ 1.1 + f * 0.00001, 2.2, 3.3 }));
}
fn checkVequalFma() bool {
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const e: f32 = @as(f32, @floatFromInt(i)) * 0.00002;
        const a = [3]f32{ 1.1, 2.2, 3.3 };
        const b = [3]f32{ 1.1 + e, 2.2 - e, 3.3 };
        if (vequal_fma(&a, &b) != nav.math.vequal(&a, &b)) return false;
    }
    return true;
}

// --- vnormalize: original = *(1/len); analog = /len (div, not reciprocal-mul) ---
fn vnormalize_div(v: *[3]f32) void {
    const len = nav.math.vlen(v);
    v[0] /= len;
    v[1] /= len;
    v[2] /= len;
}
fn runVnormalizeDiv(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var v = [3]f32{ 1.1 + f, 2.2, 3.3 };
    vnormalize_div(&v);
    dna(v[0]);
}
fn checkVnormalizeDiv() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        var a = [3]f32{ fa * 0.3, 2.2, 3.3 };
        var b = a;
        vnormalize_div(&a);
        nav.math.vnormalize(&b);
        if (!eq3(a, b)) return false;
    }
    return true;
}

// --- distancePtSegSqr2D (sum-of-products in d and final) ---
fn distancePtSegSqr2D_fma(pt: *const [3]f32, p: *const [3]f32, q: *const [3]f32, t: *f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    var dx = pt[0] - p[0];
    var dz = pt[2] - p[2];
    const d = @mulAdd(f32, pqx, pqx, pqz * pqz);
    t.* = @mulAdd(f32, pqx, dx, pqz * dz);
    if (d > 0) t.* /= d;
    if (t.* < 0) t.* = 0 else if (t.* > 1) t.* = 1;
    dx = @mulAdd(f32, t.*, pqx, p[0]) - pt[0];
    dz = @mulAdd(f32, t.*, pqz, p[2]) - pt[2];
    return @mulAdd(f32, dx, dx, dz * dz);
}
fn runDistPtSegFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var t: f32 = undefined;
    dna(distancePtSegSqr2D_fma(&.{ 2.0 + f * 0.1, 0, 3.0 }, &.{ 0, 0, 0 }, &.{ 10, 0, 0 }, &t));
}
fn checkDistPtSegFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const pt = [3]f32{ fa * 0.01, 0, fa * 0.003 };
        const p = [3]f32{ 0, 0, 0 };
        const q = [3]f32{ 10, 0, 7 };
        var ta: f32 = undefined;
        var tb: f32 = undefined;
        if (distancePtSegSqr2D_fma(&pt, &p, &q, &ta) != nav.math.distancePtSegSqr2D(&pt, &p, &q, &tb)) return false;
        if (ta != tb) return false;
    }
    return true;
}

// --- intersectSegSeg2D (determinants are perp products) ---
fn intersectSegSeg2D_fma(ap: *const [3]f32, aq: *const [3]f32, bp: *const [3]f32, bq: *const [3]f32, s: *f32, t: *f32) bool {
    const ux = aq[0] - ap[0];
    const uz = aq[2] - ap[2];
    const vx = bq[0] - bp[0];
    const vz = bq[2] - bp[2];
    const wx = ap[0] - bp[0];
    const wz = ap[2] - bp[2];
    const d = @mulAdd(f32, ux, vz, -(uz * vx));
    if (@abs(d) < 1e-6) return false;
    s.* = @mulAdd(f32, vx, wz, -(vz * wx)) / d;
    t.* = @mulAdd(f32, ux, wz, -(uz * wx)) / d;
    return true;
}
fn runIntersectFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var s: f32 = undefined;
    var t: f32 = undefined;
    _ = intersectSegSeg2D_fma(&.{ 0, 0, 0 }, &.{ 10 + f * 0.1, 0, 10 }, &.{ 0, 0, 10 }, &.{ 10, 0, 0 }, &s, &t);
    dna(s);
}
fn checkIntersectFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const ap = [3]f32{ 0, 0, 0 };
        const aq = [3]f32{ 10 + fa * 0.01, 0, 10 };
        const bp = [3]f32{ 0, 0, 10 };
        const bq = [3]f32{ 10, 0, fa * 0.01 };
        var sa: f32 = undefined;
        var ta: f32 = undefined;
        var sb: f32 = undefined;
        var tb: f32 = undefined;
        const ra = intersectSegSeg2D_fma(&ap, &aq, &bp, &bq, &sa, &ta);
        const rb = nav.math.intersectSegSeg2D(&ap, &aq, &bp, &bq, &sb, &tb);
        if (ra != rb) return false;
        if (ra and (sa != sb or ta != tb)) return false;
    }
    return true;
}

// --- closestPtPointTriangle (fma the va/vb/vc cross terms) ---
fn closestPtPointTriangle_fma(p: Vec3, a: Vec3, b: Vec3, c: Vec3) Vec3 {
    const ab = b.sub(a);
    const ac = c.sub(a);
    const ap = p.sub(a);
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0.0 and d2 <= 0.0) return a;
    const bp = p.sub(b);
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0.0 and d4 <= d3) return b;
    const vc = @mulAdd(f32, d1, d4, -(d3 * d2));
    if (vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0) return a.add(ab.scale(d1 / (d1 - d3)));
    const cp = p.sub(c);
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0.0 and d5 <= d6) return c;
    const vb = @mulAdd(f32, d5, d2, -(d1 * d6));
    if (vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0) return a.add(ac.scale(d2 / (d2 - d6)));
    const va = @mulAdd(f32, d3, d6, -(d5 * d4));
    if (va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0) {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b.add(c.sub(b).scale(w));
    }
    const denom = 1.0 / (va + vb + vc);
    return a.add(ab.scale(vb * denom)).add(ac.scale(vc * denom));
}
fn runClosestPtFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(closestPtPointTriangle_fma(Vec3.init(1.0 + f * 0.05, 0, 1.3), Vec3.init(0, 0, 0), Vec3.init(4, 0, 0), Vec3.init(0, 0, 4)).x);
}
fn checkClosestPtFma() bool {
    var i: usize = 1;
    while (i < 4000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const p = Vec3.init(fa * 0.001, 0.0, fa * 0.0007);
        const a = Vec3.init(0, 0, 0);
        const b = Vec3.init(4, 0, 0);
        const c = Vec3.init(0, 0, 4);
        if (!eqV(closestPtPointTriangle_fma(p, a, b, c), nav.math.closestPtPointTriangle(p, a, b, c))) return false;
    }
    return true;
}

// --- closestHeightPointTriangle (fma denom/u/v/h) ---
fn closestHeightPointTriangle_fma(p: *const [3]f32, a: *const [3]f32, b: *const [3]f32, c: *const [3]f32, h: *f32) bool {
    const EPS: f32 = 1e-6;
    var v0: [3]f32 = undefined;
    var v1: [3]f32 = undefined;
    var v2: [3]f32 = undefined;
    nav.math.vsub(&v0, c, a);
    nav.math.vsub(&v1, b, a);
    nav.math.vsub(&v2, p, a);
    var denom = @mulAdd(f32, v0[0], v1[2], -(v0[2] * v1[0]));
    if (@abs(denom) < EPS) return false;
    var u = @mulAdd(f32, v1[2], v2[0], -(v1[0] * v2[2]));
    var v = @mulAdd(f32, v0[0], v2[2], -(v0[2] * v2[0]));
    if (denom < 0) {
        denom = -denom;
        u = -u;
        v = -v;
    }
    if (u >= 0.0 and v >= 0.0 and (u + v) <= denom) {
        h.* = a[1] + @mulAdd(f32, v0[1], u, v1[1] * v) / denom;
        return true;
    }
    return false;
}
fn runClosestHeightFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var h: f32 = undefined;
    _ = closestHeightPointTriangle_fma(&.{ 1.0 + f * 0.05, 5, 1.3 }, &.{ 0, 0, 0 }, &.{ 4, 1, 0 }, &.{ 0, 2, 4 }, &h);
    dna(h);
}
fn checkClosestHeightFma() bool {
    var i: usize = 1;
    while (i < 4000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const p = [3]f32{ fa * 0.001, 5, fa * 0.0007 };
        const a = [3]f32{ 0, 0, 0 };
        const b = [3]f32{ 4, 1, 0 };
        const c = [3]f32{ 0, 2, 4 };
        var ha: f32 = undefined;
        var hb: f32 = undefined;
        const ra = closestHeightPointTriangle_fma(&p, &a, &b, &c, &ha);
        const rb = nav.math.closestHeightPointTriangle(&p, &a, &b, &c, &hb);
        if (ra != rb) return false;
        if (ra and ha != hb) return false;
    }
    return true;
}

// --- calcPolyCenter: original = sum then *(1/n); analog = sum then /n (div) ---
fn calcPolyCenter_div(tc: *[3]f32, idx: []const u16, nidx: usize, verts: []const f32) void {
    tc[0] = 0;
    tc[1] = 0;
    tc[2] = 0;
    for (0..nidx) |j| {
        const v = verts[idx[j] * 3 .. idx[j] * 3 + 3];
        tc[0] += v[0];
        tc[1] += v[1];
        tc[2] += v[2];
    }
    const n: f32 = @floatFromInt(nidx);
    tc[0] /= n;
    tc[1] /= n;
    tc[2] /= n;
}
const poly_verts = [_]f32{ 0, 0, 0, 10, 1, 0, 11, 2, 9, 1, 1, 10 };
const poly_idx = [_]u16{ 0, 1, 2, 3 };
fn runCalcCenterDiv(i: usize) void {
    var tc: [3]f32 = undefined;
    calcPolyCenter_div(&tc, &poly_idx, 3 + (i & 1), &poly_verts);
    dna(tc[0]);
}
fn checkCalcCenterDiv() bool {
    var n: usize = 3;
    while (n <= 4) : (n += 1) {
        var a: [3]f32 = undefined;
        var b: [3]f32 = undefined;
        calcPolyCenter_div(&a, &poly_idx, n, &poly_verts);
        nav.math.calcPolyCenter(&b, &poly_idx, n, &poly_verts);
        if (!eq3(a, b)) return false;
    }
    return true;
}

// ===========================================================================
// STRUCTURAL analogs — same IEEE ops in a different shape -> bit-identical (TIE).
// Proves the original is already optimal: a reorder buys nothing.
// ===========================================================================

// --- align4: (x+3) & ~3  ==  (x+3) & -4  (two's-complement identity) ---
fn align4_negmask(x: i32) i32 {
    return (x + 3) & @as(i32, -4);
}
fn runAlign4Neg(i: usize) void {
    dna(align4_negmask(@as(i32, @intCast(i & 1023)) - 256));
}
fn checkAlign4Neg() bool {
    var x: i32 = -100_000;
    while (x < 100_000) : (x += 1) {
        if (align4_negmask(x) != nav.math.align4(x)) return false;
    }
    return true;
}

// --- pointInPolygon: trailing-j loop rewritten with a modulo predecessor index.
// Same (vi,vj) edge pairs, same float comparisons -> identical bool. ---
fn pointInPolygon_mod(pt: Vec3, verts: []const Vec3) bool {
    var c = false;
    const n = verts.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const vi = verts[i];
        const vj = verts[(i + n - 1) % n];
        if (((vi.z > pt.z) != (vj.z > pt.z)) and
            (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x))
        {
            c = !c;
        }
    }
    return c;
}
// SAME input as bench_math.zig orig (sq_poly, pt = 3 + (i&7)*0.1) for a fair head-to-head.
const pip_quad = [_]Vec3{ Vec3.init(0, 0, 0), Vec3.init(10, 0, 0), Vec3.init(10, 0, 10), Vec3.init(0, 0, 10) };
fn runPipMod(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 7)) * 0.1;
    dna(pointInPolygon_mod(Vec3.init(3 + f, 0, 5), &pip_quad));
}
fn checkPipMod() bool {
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const fx: f32 = @as(f32, @floatFromInt(i % 130)) - 5;
        const fz: f32 = @as(f32, @floatFromInt(i / 130)) - 5;
        const pt = Vec3.init(fx, 0, fz);
        if (pointInPolygon_mod(pt, &pip_quad) != nav.math.pointInPolygon(pt, &pip_quad)) return false;
    }
    return true;
}

// --- overlapPolyPoly2D: SAT is symmetric in axis order -> test B's edges first,
// then A's. Same separating-axis set, same projections -> identical bool. ---
fn projP(axis: *const [3]f32, poly: []const f32, np: usize, rmin: *f32, rmax: *f32) void {
    rmin.* = nav.math.vdot2D(axis, poly[0..3]);
    rmax.* = rmin.*;
    var i: usize = 1;
    while (i < np) : (i += 1) {
        const d = nav.math.vdot2D(axis, poly[i * 3 .. i * 3 + 3]);
        rmin.* = @min(rmin.*, d);
        rmax.* = @max(rmax.*, d);
    }
}
fn ovR(amin: f32, amax: f32, bmin: f32, bmax: f32, eps: f32) bool {
    return !((amin + eps) > bmax or (amax - eps) < bmin);
}
fn sat(edges: []const f32, ne: usize, pa: []const f32, npa: usize, pb: []const f32, npb: usize) bool {
    var j: usize = ne - 1;
    var i: usize = 0;
    while (i < ne) : ({
        j = i;
        i += 1;
    }) {
        const va = edges[j * 3 .. j * 3 + 3];
        const vb = edges[i * 3 .. i * 3 + 3];
        const n = [3]f32{ vb[2] - va[2], 0, -(vb[0] - va[0]) };
        var amin: f32 = undefined;
        var amax: f32 = undefined;
        var bmin: f32 = undefined;
        var bmax: f32 = undefined;
        projP(&n, pa, npa, &amin, &amax);
        projP(&n, pb, npb, &bmin, &bmax);
        if (!ovR(amin, amax, bmin, bmax, 1e-4)) return false;
    }
    return true;
}
fn overlapPolyPoly2D_swap(polya: []const f32, npolya: usize, polyb: []const f32, npolyb: usize) bool {
    // B's edges first, then A's (original does A then B).
    if (!sat(polyb, npolyb, polya, npolya, polyb, npolyb)) return false;
    if (!sat(polya, npolya, polya, npolya, polyb, npolyb)) return false;
    return true;
}
// SAME constant inputs as bench_math.zig orig (polyA / polyB_ovl, loop-invariant)
// so the orig-vs-analog ns comparison is a fair head-to-head, not an input artifact.
const opp_a = [_]f32{ 0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 10 };
const opp_b = [_]f32{ 5, 0, 5, 15, 0, 5, 15, 0, 15, 5, 0, 15 };
fn runOppSwap(i: usize) void {
    _ = i;
    dna(overlapPolyPoly2D_swap(&opp_a, 4, &opp_b, 4));
}
fn checkOppSwap() bool {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const off: f32 = @as(f32, @floatFromInt(i)) * 0.02 - 5;
        const b = [_]f32{ off, 0, off, 10 + off, 0, off, 10 + off, 0, 10 + off, off, 0, 10 + off };
        if (overlapPolyPoly2D_swap(&opp_a, 4, &b, 4) != nav.math.overlapPolyPoly2D(&opp_a, 4, &b, 4)) return false;
    }
    return true;
}

// ===========================================================================
// Trivial componentwise ops (one IEEE op per lane, no cross-lane term): the only
// alternatives are SIMD (excluded by user) or a loop instead of the unrolled body.
// The loop form is bit-identical (LLVM unrolls it) -> TIE. Written + gated so NO
// benched leaf fn rests on an unproven "no alternative" assertion.
// ===========================================================================
fn vsub_loop(d: *[3]f32, a: *const [3]f32, b: *const [3]f32) void {
    for (0..3) |k| d[k] = a[k] - b[k];
}
fn vadd_loop(d: *[3]f32, a: *const [3]f32, b: *const [3]f32) void {
    for (0..3) |k| d[k] = a[k] + b[k];
}
fn vscale_loop(d: *[3]f32, v: *const [3]f32, s: f32) void {
    for (0..3) |k| d[k] = v[k] * s;
}
fn vcopy_loop(d: *[3]f32, s: *const [3]f32) void {
    for (0..3) |k| d[k] = s[k];
}
fn vmin_loop(mn: *[3]f32, v: *const [3]f32) void {
    for (0..3) |k| mn[k] = @min(mn[k], v[k]);
}
fn vmax_loop(mx: *[3]f32, v: *const [3]f32) void {
    for (0..3) |k| mx[k] = @max(mx[k], v[k]);
}
fn runVsubLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vsub_loop(&d, &.{ 1.1 + f, 2.2, 3.3 }, &.{ 0.5, 1.5, 2.5 });
    dna(d[0]);
}
fn runVaddLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vadd_loop(&d, &.{ 1.1 + f, 2.2, 3.3 }, &.{ 0.5, 1.5, 2.5 });
    dna(d[0]);
}
fn runVscaleLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vscale_loop(&d, &.{ 1.1 + f, 2.2, 3.3 }, 0.75);
    dna(d[0]);
}
fn runVcopyLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d: [3]f32 = undefined;
    vcopy_loop(&d, &.{ 1.1 + f, 2.2, 3.3 });
    dna(d[0]);
}
fn runVminLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d = [3]f32{ 2.0, 2.0, 2.0 };
    vmin_loop(&d, &.{ 1.1 + f, 2.2, 3.3 });
    dna(d[0]);
}
fn runVmaxLoop(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var d = [3]f32{ 2.0, 2.0, 2.0 };
    vmax_loop(&d, &.{ 1.1 + f, 2.2, 3.3 });
    dna(d[0]);
}
fn checkVsubLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const a = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const b = [3]f32{ 0.5, fa * 0.1, 2.5 };
        var x: [3]f32 = undefined;
        var y: [3]f32 = undefined;
        vsub_loop(&x, &a, &b);
        nav.math.vsub(&y, &a, &b);
        if (!eq3(x, y)) return false;
    }
    return true;
}
fn checkVaddLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const a = [3]f32{ fa * 0.3, 2.2, 3.3 };
        const b = [3]f32{ 0.5, fa * 0.1, 2.5 };
        var x: [3]f32 = undefined;
        var y: [3]f32 = undefined;
        vadd_loop(&x, &a, &b);
        nav.math.vadd(&y, &a, &b);
        if (!eq3(x, y)) return false;
    }
    return true;
}
fn checkVscaleLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, 2.2, 3.3 };
        var x: [3]f32 = undefined;
        var y: [3]f32 = undefined;
        vscale_loop(&x, &v, 0.75);
        nav.math.vscale(&y, &v, 0.75);
        if (!eq3(x, y)) return false;
    }
    return true;
}
fn checkVcopyLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, 2.2, 3.3 };
        var x: [3]f32 = undefined;
        var y: [3]f32 = undefined;
        vcopy_loop(&x, &v);
        nav.math.vcopy(&y, &v);
        if (!eq3(x, y)) return false;
    }
    return true;
}
fn checkVminLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, 2.2, 3.3 };
        var x = [3]f32{ 2.0, 2.0, 2.0 };
        var y = [3]f32{ 2.0, 2.0, 2.0 };
        vmin_loop(&x, &v);
        nav.math.vmin(&y, &v);
        if (!eq3(x, y)) return false;
    }
    return true;
}
fn checkVmaxLoop() bool {
    var i: usize = 1;
    while (i < 3000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const v = [3]f32{ fa * 0.3, 2.2, 3.3 };
        var x = [3]f32{ 2.0, 2.0, 2.0 };
        var y = [3]f32{ 2.0, 2.0, 2.0 };
        vmax_loop(&x, &v);
        nav.math.vmax(&y, &v);
        if (!eq3(x, y)) return false;
    }
    return true;
}

pub const benches = [_]core.Bench{
    // -- previously written (integer/bool exact + float fma) --
    .{ .name = "triArea2D", .module = "math", .impl = "fma", .isolation = "A", .run = runTriAreaFma, .check = checkTriAreaFma },
    .{ .name = "ilog2", .module = "math", .impl = "clz", .isolation = "A", .run = runIlog2Clz, .check = checkIlog2Clz },
    .{ .name = "nextPow2", .module = "math", .impl = "clz", .isolation = "A", .run = runNextPow2Clz, .check = checkNextPow2Clz },
    .{ .name = "overlapQuantBounds", .module = "math", .impl = "and-chain", .isolation = "A", .run = runOverlapAnd, .check = checkOverlapAnd },
    .{ .name = "vdot", .module = "math", .impl = "fma", .isolation = "A", .run = runVdotFma, .check = checkVdotFma },
    // -- fma-reassociation analogs (expected REJECT: not bit-identical) --
    .{ .name = "vmad", .module = "math", .impl = "fma", .isolation = "A", .run = runVmadFma, .check = checkVmadFma },
    .{ .name = "vlerp", .module = "math", .impl = "fma", .isolation = "A", .run = runVlerpFma, .check = checkVlerpFma },
    .{ .name = "vcross", .module = "math", .impl = "fma", .isolation = "A", .run = runVcrossFma, .check = checkVcrossFma },
    .{ .name = "vperp2D", .module = "math", .impl = "fma", .isolation = "A", .run = runVperpFma, .check = checkVperpFma },
    .{ .name = "vlenSqr", .module = "math", .impl = "fma", .isolation = "A", .run = runVlenSqrFma, .check = checkVlenSqrFma },
    .{ .name = "vlen", .module = "math", .impl = "fma", .isolation = "A", .run = runVlenFma, .check = checkVlenFma },
    .{ .name = "vdistSqr", .module = "math", .impl = "fma", .isolation = "A", .run = runVdistSqrFma, .check = checkVdistSqrFma },
    .{ .name = "vdist", .module = "math", .impl = "fma", .isolation = "A", .run = runVdistFma, .check = checkVdistFma },
    .{ .name = "vdist2DSqr", .module = "math", .impl = "fma", .isolation = "A", .run = runVdist2DSqrFma, .check = checkVdist2DSqrFma },
    .{ .name = "vdist2D", .module = "math", .impl = "fma", .isolation = "A", .run = runVdist2DFma, .check = checkVdist2DFma },
    .{ .name = "vequal", .module = "math", .impl = "fma", .isolation = "A", .run = runVequalFma, .check = checkVequalFma },
    .{ .name = "vnormalize", .module = "math", .impl = "div", .isolation = "A", .run = runVnormalizeDiv, .check = checkVnormalizeDiv },
    .{ .name = "distancePtSegSqr2D", .module = "math", .impl = "fma", .isolation = "A", .run = runDistPtSegFma, .check = checkDistPtSegFma },
    .{ .name = "intersectSegSeg2D", .module = "math", .impl = "fma", .isolation = "A", .run = runIntersectFma, .check = checkIntersectFma },
    .{ .name = "closestPtPointTriangle", .module = "math", .impl = "fma", .isolation = "A", .run = runClosestPtFma, .check = checkClosestPtFma },
    .{ .name = "closestHeightPointTriangle", .module = "math", .impl = "fma", .isolation = "A", .run = runClosestHeightFma, .check = checkClosestHeightFma },
    .{ .name = "calcPolyCenter", .module = "math", .impl = "div", .isolation = "A", .run = runCalcCenterDiv, .check = checkCalcCenterDiv },
    // -- structural analogs (expected TIE: bit-identical, proves orig optimal) --
    .{ .name = "align4", .module = "math", .impl = "neg-mask", .isolation = "A", .run = runAlign4Neg, .check = checkAlign4Neg },
    .{ .name = "pointInPolygon", .module = "math", .impl = "mod-index", .isolation = "A", .run = runPipMod, .check = checkPipMod },
    .{ .name = "overlapPolyPoly2D", .module = "math", .impl = "B-first-SAT", .isolation = "A", .run = runOppSwap, .check = checkOppSwap },
    // -- trivial componentwise: loop vs unrolled (expected TIE, bit-identical) --
    .{ .name = "vsub", .module = "math", .impl = "loop", .isolation = "A", .run = runVsubLoop, .check = checkVsubLoop },
    .{ .name = "vadd", .module = "math", .impl = "loop", .isolation = "A", .run = runVaddLoop, .check = checkVaddLoop },
    .{ .name = "vscale", .module = "math", .impl = "loop", .isolation = "A", .run = runVscaleLoop, .check = checkVscaleLoop },
    .{ .name = "vcopy", .module = "math", .impl = "loop", .isolation = "A", .run = runVcopyLoop, .check = checkVcopyLoop },
    .{ .name = "vmin", .module = "math", .impl = "loop", .isolation = "A", .run = runVminLoop, .check = checkVminLoop },
    .{ .name = "vmax", .module = "math", .impl = "loop", .isolation = "A", .run = runVmaxLoop, .check = checkVmaxLoop },
};
