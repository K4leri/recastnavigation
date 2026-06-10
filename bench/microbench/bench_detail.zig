//! Bench group: recast.detail leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

// ============================================================================
// distPtTri
// ============================================================================

fn runDistPtTri(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const p = [3]f32{ 0.25 + f * 0.01, 0, 0.25 };
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 0, 0 };
    const c = [3]f32{ 0, 0, 1 };
    dna(nav.recast.detail.distPtTri(&p, &a, &b, &c));
}
fn checkDistPtTri() bool {
    const p = [3]f32{ 0.25, 0, 0.25 };
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 0, 0 };
    const c = [3]f32{ 0, 0, 1 };
    // point lies on the flat (y=0) triangle, vertical distance == 0
    return nav.recast.detail.distPtTri(&p, &a, &b, &c) < 1e-4;
}

/// Analog: replace sum-of-products in dot computations with @mulAdd.
/// dot00 = v0[0]*v0[0] + v0[2]*v0[2]  -> @mulAdd(f32, v0[2], v0[2], v0[0]*v0[0])
/// Similar for dot01,dot02,dot11,dot12.
/// @mulAdd changes rounding vs separate * + * — EXPECT REJECT.
fn distPtTri_fma(p: [*]const f32, a: [*]const f32, b: [*]const f32, c: [*]const f32) f32 {
    const v0 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const v1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v2 = [3]f32{ p[0] - a[0], p[1] - a[1], p[2] - a[2] };

    const dot00 = @mulAdd(f32, v0[2], v0[2], v0[0] * v0[0]);
    const dot01 = @mulAdd(f32, v0[2], v1[2], v0[0] * v1[0]);
    const dot02 = @mulAdd(f32, v0[2], v2[2], v0[0] * v2[0]);
    const dot11 = @mulAdd(f32, v1[2], v1[2], v1[0] * v1[0]);
    const dot12 = @mulAdd(f32, v1[2], v2[2], v1[0] * v2[0]);

    const inv_denom = 1.0 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * inv_denom;
    const v = (dot00 * dot12 - dot01 * dot02) * inv_denom;

    const EPS = 1e-4;
    if (u >= -EPS and v >= -EPS and (u + v) <= 1 + EPS) {
        const y = a[1] + v0[1] * u + v1[1] * v;
        return @abs(y - p[1]);
    }
    return std.math.floatMax(f32);
}
fn runDistPtTriFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const p = [3]f32{ 0.25 + f * 0.01, 0, 0.25 };
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 0, 0 };
    const c = [3]f32{ 0, 0, 1 };
    dna(distPtTri_fma(&p, &a, &b, &c));
}
fn checkDistPtTriFma() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const p = [3]f32{ f * 0.001, 0, f * 0.0007 };
        const a = [3]f32{ 0, 0, 0 };
        const b = [3]f32{ 1, 0, 0 };
        const c = [3]f32{ 0, 0, 1 };
        if (distPtTri_fma(&p, &a, &b, &c) != nav.recast.detail.distPtTri(&p, &a, &b, &c)) return false;
    }
    return true;
}

// ============================================================================
// distancePtSeg  (f32 scalar overload in recast.detail)
// ============================================================================

fn runDistancePtSeg(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(nav.recast.detail.distancePtSeg(3.0 + f * 0.1, 4.0, 0, 0, 10, 10));
}
fn checkDistancePtSeg() bool {
    // pt (5,5) on the diagonal (0,0)-(10,10) -> squared dist == 0
    return nav.recast.detail.distancePtSeg(5, 5, 0, 0, 10, 10) < 1e-4;
}

/// Analog: replace pqx*pqx + pqz*pqz  with @mulAdd and pqx*dx + pqz*dz with @mulAdd.
/// Different rounding order -> EXPECT REJECT.
fn distancePtSeg_fma(x: f32, z: f32, px: f32, pz: f32, qx: f32, qz: f32) f32 {
    const pqx = qx - px;
    const pqz = qz - pz;
    const dx = x - px;
    const dz = z - pz;
    const d = @mulAdd(f32, pqz, pqz, pqx * pqx);
    var t = @mulAdd(f32, pqz, dz, pqx * dx);
    if (d > 0) t /= d;
    if (t < 0) t = 0 else if (t > 1) t = 1;

    const dx_final = px + t * pqx - x;
    const dz_final = pz + t * pqz - z;
    return @mulAdd(f32, dz_final, dz_final, dx_final * dx_final);
}
fn runDistancePtSegFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    dna(distancePtSeg_fma(3.0 + f * 0.1, 4.0, 0, 0, 10, 10));
}
fn checkDistancePtSegFma() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const x = f * 0.003;
        const z = f * 0.0025;
        if (distancePtSeg_fma(x, z, 0, 0, 10, 10) != nav.recast.detail.distancePtSeg(x, z, 0, 0, 10, 10)) return false;
    }
    return true;
}

// ============================================================================
// distancePtSeg3d
// ============================================================================

fn runDistancePtSeg3d(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 3.0 + f * 0.1, 1.0, 4.0 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    dna(nav.recast.detail.distancePtSeg3d(&pt, &p, &q));
}
fn checkDistancePtSeg3d() bool {
    // pt exactly on the segment midpoint (5,0,5) -> dist^2 = 1.0 (y offset)
    const pt = [3]f32{ 5, 1, 5 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    return @abs(nav.recast.detail.distancePtSeg3d(&pt, &p, &q) - 1.0) < 1e-4;
}

/// Analog: replace the three sum-of-products  pqx*pqx + pqy*pqy + pqz*pqz
/// and pqx*dx + pqy*dy + pqz*dz with @mulAdd chains.
/// Different rounding -> EXPECT REJECT.
fn distancePtSeg3d_fma(pt: [*]const f32, p: [*]const f32, q: [*]const f32) f32 {
    const pqx = q[0] - p[0];
    const pqy = q[1] - p[1];
    const pqz = q[2] - p[2];
    var dx = pt[0] - p[0];
    var dy = pt[1] - p[1];
    var dz = pt[2] - p[2];
    const d = @mulAdd(f32, pqz, pqz, @mulAdd(f32, pqy, pqy, pqx * pqx));
    var t = @mulAdd(f32, pqz, dz, @mulAdd(f32, pqy, dy, pqx * dx));
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }
    dx = p[0] + t * pqx - pt[0];
    dy = p[1] + t * pqy - pt[1];
    dz = p[2] + t * pqz - pt[2];
    return @mulAdd(f32, dz, dz, @mulAdd(f32, dy, dy, dx * dx));
}
fn runDistancePtSeg3dFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 3.0 + f * 0.1, 1.0, 4.0 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    dna(distancePtSeg3d_fma(&pt, &p, &q));
}
fn checkDistancePtSeg3dFma() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const pt = [3]f32{ f * 0.003, f * 0.002, f * 0.0025 };
        const p = [3]f32{ 0, 0, 0 };
        const q = [3]f32{ 10, 5, 10 };
        if (distancePtSeg3d_fma(&pt, &p, &q) != nav.recast.detail.distancePtSeg3d(&pt, &p, &q)) return false;
    }
    return true;
}

// ============================================================================
// distancePtSeg2d
// ============================================================================

fn runDistancePtSeg2d(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 3.0 + f * 0.1, 99, 4.0 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    dna(nav.recast.detail.distancePtSeg2d(&pt, &p, &q));
}
fn checkDistancePtSeg2d() bool {
    // pt (5,99,5) projected onto (0,0,0)-(10,0,10) -> on the segment, dist^2 = 0
    const pt = [3]f32{ 5, 99, 5 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    return nav.recast.detail.distancePtSeg2d(&pt, &p, &q) < 1e-4;
}

/// Analog: @mulAdd for the two 2D dot products. Different rounding -> EXPECT REJECT.
fn distancePtSeg2d_fma(pt: [*]const f32, p: [*]const f32, q: [*]const f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    const dx = pt[0] - p[0];
    const dz = pt[2] - p[2];
    const d = @mulAdd(f32, pqz, pqz, pqx * pqx);
    var t = @mulAdd(f32, pqz, dz, pqx * dx);
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }
    const dx_final = p[0] + t * pqx - pt[0];
    const dz_final = p[2] + t * pqz - pt[2];
    return @mulAdd(f32, dz_final, dz_final, dx_final * dx_final);
}
fn runDistancePtSeg2dFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 3.0 + f * 0.1, 99, 4.0 };
    const p = [3]f32{ 0, 0, 0 };
    const q = [3]f32{ 10, 0, 10 };
    dna(distancePtSeg2d_fma(&pt, &p, &q));
}
fn checkDistancePtSeg2dFma() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const pt = [3]f32{ f * 0.003, 0, f * 0.0025 };
        const p = [3]f32{ 0, 0, 0 };
        const q = [3]f32{ 10, 0, 10 };
        if (distancePtSeg2d_fma(&pt, &p, &q) != nav.recast.detail.distancePtSeg2d(&pt, &p, &q)) return false;
    }
    return true;
}

// ============================================================================
// distToPoly
// ============================================================================

// A unit square polygon (xz-plane, y=0), stored flat as [nvert*3]f32.
const poly_sq = [_]f32{
    0, 0, 0,
    4, 0, 0,
    4, 0, 4,
    0, 0, 4,
};

fn runDistToPoly(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 2.0 + f * 0.03, 0, 2.0 };
    dna(nav.recast.detail.distToPoly(4, &poly_sq, &pt));
}
fn checkDistToPoly() bool {
    // point inside the square -> result should be negative (signed inside-distance)
    const pt_in = [3]f32{ 2, 0, 2 };
    const pt_out = [3]f32{ 6, 0, 2 };
    const d_in = nav.recast.detail.distToPoly(4, &poly_sq, &pt_in);
    const d_out = nav.recast.detail.distToPoly(4, &poly_sq, &pt_out);
    return d_in < 0 and d_out > 0;
}

/// Analog: multiply by reciprocal instead of dividing inline in the ray-cast test.
/// The division  (vj[0]-vi[0])*(p[2]-vi[2]) / (vj[2]-vi[2])  is replaced by
/// precomputing 1/(vj[2]-vi[2]) and multiplying.  Float reciprocal is NOT exact ->
/// the crossing test changes for some inputs -> EXPECT REJECT.
fn distToPoly_recip(nin: i32, inv: [*]const f32, p: [*]const f32) f32 {
    var dmin = std.math.floatMax(f32);
    var i: i32 = 0;
    var j = nin - 1;
    var c = false;
    while (i < nin) : ({
        j = i;
        i += 1;
    }) {
        const vi = inv + @as(usize, @intCast(i)) * 3;
        const vj = inv + @as(usize, @intCast(j)) * 3;
        if (((vi[2] > p[2]) != (vj[2] > p[2])) and
            (p[0] < (vj[0] - vi[0]) * (p[2] - vi[2]) * (1.0 / (vj[2] - vi[2])) + vi[0]))
        {
            c = !c;
        }
        dmin = @min(dmin, nav.recast.detail.distancePtSeg2d(p, vj, vi));
    }
    return if (c) -dmin else dmin;
}
fn runDistToPolyRecip(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const pt = [3]f32{ 2.0 + f * 0.03, 0, 2.0 };
    dna(distToPoly_recip(4, &poly_sq, &pt));
}
fn checkDistToPolyRecip() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const pt = [3]f32{ f * 0.002, 0, f * 0.0015 };
        if (distToPoly_recip(4, &poly_sq, &pt) != nav.recast.detail.distToPoly(4, &poly_sq, &pt)) return false;
    }
    return true;
}

// ============================================================================
// overlapSegSeg2d
// ============================================================================

fn runOverlapSegSeg2d(i: usize) void {
    const f: f32 = @floatFromInt(i & 15);
    // segment ab crosses cd for most i values
    const a = [3]f32{ 0 + f * 0.01, 0, 0 };
    const b = [3]f32{ 10, 0, 10 };
    const c = [3]f32{ 0, 0, 10 };
    const d = [3]f32{ 10, 0, 0 };
    dna(nav.recast.detail.overlapSegSeg2d(&a, &b, &c, &d));
}
fn checkOverlapSegSeg2d() bool {
    // crossing diagonals of the unit square must overlap
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 10, 0, 10 };
    const c = [3]f32{ 0, 0, 10 };
    const d = [3]f32{ 10, 0, 0 };
    // parallel non-crossing segments must NOT overlap
    const e = [3]f32{ 0, 0, 0 };
    const ff = [3]f32{ 5, 0, 0 };
    const g = [3]f32{ 0, 0, 5 };
    const h = [3]f32{ 5, 0, 5 };
    return nav.recast.detail.overlapSegSeg2d(&a, &b, &c, &d) and
        !nav.recast.detail.overlapSegSeg2d(&e, &ff, &g, &h);
}

/// Analog: algebraically equivalent rearrangement — compute a4 = a3 + a2 - a1
/// only after the first sign test passes, same ops, same order.
/// This is structurally identical to the original (no op reorder) -> EXPECT TIE.
fn overlapSegSeg2d_same(a: [*]const f32, b: [*]const f32, c: [*]const f32, d: [*]const f32) bool {
    // vcross2 inlined to avoid a private-fn dependency while keeping identical ops
    const uu1a = b[0] - a[0]; const vv1a = b[2] - a[2];
    const uu2d = d[0] - a[0]; const vv2d = d[2] - a[2];
    const a1 = uu1a * vv2d - vv1a * uu2d; // vcross2(a,b,d)

    const uu2c = c[0] - a[0]; const vv2c = c[2] - a[2];
    const a2 = uu1a * vv2c - vv1a * uu2c; // vcross2(a,b,c)

    if (a1 * a2 < 0.0) {
        const uu1c = d[0] - c[0]; const vv1c = d[2] - c[2];
        const uu2a = a[0] - c[0]; const vv2a = a[2] - c[2];
        const a3 = uu1c * vv2a - vv1c * uu2a; // vcross2(c,d,a)
        const a4 = a3 + a2 - a1;
        if (a3 * a4 < 0.0) return true;
    }
    return false;
}
fn runOverlapSegSeg2dSame(i: usize) void {
    const f: f32 = @floatFromInt(i & 15);
    const a = [3]f32{ 0 + f * 0.01, 0, 0 };
    const b = [3]f32{ 10, 0, 10 };
    const c = [3]f32{ 0, 0, 10 };
    const d = [3]f32{ 10, 0, 0 };
    dna(overlapSegSeg2d_same(&a, &b, &c, &d));
}
fn checkOverlapSegSeg2dSame() bool {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        const a = [3]f32{ f * 0.001, 0, 0 };
        const b = [3]f32{ 10, 0, 10 };
        const c = [3]f32{ 0, 0, f * 0.0007 + 1.0 };
        const d = [3]f32{ 10, 0, 0 };
        if (overlapSegSeg2d_same(&a, &b, &c, &d) != nav.recast.detail.overlapSegSeg2d(&a, &b, &c, &d)) return false;
    }
    return true;
}

// ============================================================================
// overlapEdges
// ============================================================================

// A small triangulation: 4 points, 2 edges (stored as 4-tuples: s,t,l,r).
// Points (stride 3): [0]=(0,0,0), [1]=(4,0,0), [2]=(4,0,4), [3]=(0,0,4)
const bench_pts = [_]f32{
    0, 0, 0, // 0
    4, 0, 0, // 1
    4, 0, 4, // 2
    0, 0, 4, // 3
};
// Two non-touching edges: 0->2 (diagonal) and 1->3 (other diagonal) — they cross.
const bench_edges_cross = [_]i32{ 0, 2, 0, 0,  1, 3, 0, 0 };
// One edge 0->1 (horizontal bottom), test edge 0->3 — share vertex 0, must skip.
const bench_edges_share = [_]i32{ 0, 1, 0, 0 };

fn runOverlapEdges(i: usize) void {
    // test edge s1=1, t1=3 against the two crossing edges (no shared verts)
    _ = i; // nedges=2 is constant; i not useful here without more edge sets
    dna(nav.recast.detail.overlapEdges(&bench_pts, &bench_edges_cross, 2, 1, 3));
}
fn checkOverlapEdges() bool {
    // 0->2 vs 1->3: the two diagonals of a square DO overlap
    const yes = nav.recast.detail.overlapEdges(&bench_pts, &bench_edges_cross, 2, 1, 3);
    // edge 0->1 vs test edge 2->3: share no vertices, parallel sides -> no overlap
    const no = nav.recast.detail.overlapEdges(&bench_pts, &bench_edges_share, 1, 2, 3);
    return yes and !no;
}

/// Analog: early-out rewritten as a single bitmask comparison instead of four `==`.
/// s0 == s1 || s0 == t1 || t0 == s1 || t0 == t1 expressed as bitwise OR of all four
/// comparisons — identical semantics, identical result -> EXPECT TIE.
fn overlapEdges_bitmask(pts: [*]const f32, edges: []const i32, nedges: i32, s1: i32, t1: i32) bool {
    var i: i32 = 0;
    while (i < nedges) : (i += 1) {
        const idx = @as(usize, @intCast(i * 4));
        const s0 = edges[idx + 0];
        const t0 = edges[idx + 1];
        // bitwise-OR of the four equality bits (all i32, no UB)
        const skip: i32 = @intFromBool(s0 == s1) | @intFromBool(s0 == t1) |
                          @intFromBool(t0 == s1) | @intFromBool(t0 == t1);
        if (skip != 0) continue;

        const s0_idx = @as(usize, @intCast(s0 * 3));
        const t0_idx = @as(usize, @intCast(t0 * 3));
        const s1_idx = @as(usize, @intCast(s1 * 3));
        const t1_idx = @as(usize, @intCast(t1 * 3));

        if (nav.recast.detail.overlapSegSeg2d(pts + s0_idx, pts + t0_idx, pts + s1_idx, pts + t1_idx)) {
            return true;
        }
    }
    return false;
}
fn runOverlapEdgesBitmask(i: usize) void {
    _ = i;
    dna(overlapEdges_bitmask(&bench_pts, &bench_edges_cross, 2, 1, 3));
}
fn checkOverlapEdgesBitmask() bool {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        // vary which test edge we query
        const s1: i32 = @intCast(i % 4);
        const t1: i32 = @intCast((i + 2) % 4);
        if (s1 == t1) continue;
        if (overlapEdges_bitmask(&bench_pts, &bench_edges_cross, 2, s1, t1) !=
            nav.recast.detail.overlapEdges(&bench_pts, &bench_edges_cross, 2, s1, t1)) return false;
    }
    return true;
}

// ============================================================================
// Bench table
// ============================================================================

pub const benches = [_]core.Bench{
    .{ .name = "distPtTri",         .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runDistPtTri,            .check = checkDistPtTri },
    .{ .name = "distPtTri",         .module = "recast.detail", .impl = "fma",     .isolation = "A", .run = runDistPtTriFma,         .check = checkDistPtTriFma },
    .{ .name = "distancePtSeg",     .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runDistancePtSeg,        .check = checkDistancePtSeg },
    .{ .name = "distancePtSeg",     .module = "recast.detail", .impl = "fma",     .isolation = "A", .run = runDistancePtSegFma,     .check = checkDistancePtSegFma },
    .{ .name = "distancePtSeg3d",   .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runDistancePtSeg3d,      .check = checkDistancePtSeg3d },
    .{ .name = "distancePtSeg3d",   .module = "recast.detail", .impl = "fma",     .isolation = "A", .run = runDistancePtSeg3dFma,   .check = checkDistancePtSeg3dFma },
    .{ .name = "distancePtSeg2d",   .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runDistancePtSeg2d,      .check = checkDistancePtSeg2d },
    .{ .name = "distancePtSeg2d",   .module = "recast.detail", .impl = "fma",     .isolation = "A", .run = runDistancePtSeg2dFma,   .check = checkDistancePtSeg2dFma },
    .{ .name = "distToPoly",        .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runDistToPoly,           .check = checkDistToPoly },
    .{ .name = "distToPoly",        .module = "recast.detail", .impl = "recip",   .isolation = "A", .run = runDistToPolyRecip,      .check = checkDistToPolyRecip },
    .{ .name = "overlapSegSeg2d",   .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runOverlapSegSeg2d,      .check = checkOverlapSegSeg2d },
    .{ .name = "overlapSegSeg2d",   .module = "recast.detail", .impl = "same",    .isolation = "A", .run = runOverlapSegSeg2dSame,  .check = checkOverlapSegSeg2dSame },
    .{ .name = "overlapEdges",      .module = "recast.detail", .impl = "orig",    .isolation = "A", .run = runOverlapEdges,         .check = checkOverlapEdges },
    .{ .name = "overlapEdges",      .module = "recast.detail", .impl = "bitmask", .isolation = "A", .run = runOverlapEdgesBitmask,  .check = checkOverlapEdgesBitmask },
};
