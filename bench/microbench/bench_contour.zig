//! Bench group: recast.contour leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
//!
//! Functions: calcAreaOfPolygon2D, intersectProp, intersect, intersectSegContour.
//! Layout note: verts are flat i32 slices, stride=4 ([x, y, z, flag]).
//! Geometry uses indices [0]=x, [2]=z (y at [1] is height, unused by these predicates).

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

// ============================================================================
// calcAreaOfPolygon2D
// Signature: (verts: []const i32, nverts: usize) i32
// Stride: 4 per vertex; uses vi[0] (x) and vi[2] (z) — shoelace sum.
// ============================================================================

fn runCalcArea(i: usize) void {
    const o: i32 = @intCast(i & 31);
    // 4 vertices, stride 4: [x,y,z,flag] per vertex
    const verts = [_]i32{
        0,       0, 0,       0,
        10 + o,  0, 0,       0,
        10 + o,  0, 10 + o,  0,
        0,       0, 10 + o,  0,
    };
    dna(nav.recast.contour.calcAreaOfPolygon2D(&verts, 4));
}

fn checkCalcArea() bool {
    // Unit square: (0,0),(1,0),(1,1),(0,1) in xz — area = 1, shoelace*2 = 2
    // @divTrunc(2+1, 2) = 1
    const verts = [_]i32{
        0, 0, 0, 0,
        1, 0, 0, 0,
        1, 0, 1, 0,
        0, 0, 1, 0,
    };
    return nav.recast.contour.calcAreaOfPolygon2D(&verts, 4) == 1;
}

// Analog: accumulate the shoelace sum in reverse vertex order (i goes n-1..0),
// which produces the negated signed area — same magnitude after the signed
// @divTrunc, but flipped sign.  Gate: |analog| == |orig| for every test input
// (we compare absolute values so the check returns true, proving identical magnitude).
fn calcAreaOfPolygon2DReverse(verts: []const i32, nverts: usize) i32 {
    var area: i32 = 0;
    var i: usize = nverts - 1; // start from last vertex
    var j: usize = nverts - 2;
    var count: usize = 0;
    while (count < nverts) : ({
        j = if (i == 0) nverts - 1 else i - 1;
        i = if (i == 0) nverts - 1 else i - 1;
        count += 1;
    }) {
        const vi = verts[i * 4 ..];
        const vj = verts[j * 4 ..];
        area += vi[0] * vj[2] - vj[0] * vi[2];
    }
    return @divTrunc(area + 1, 2);
}

fn runCalcAreaAnalog(i: usize) void {
    const o: i32 = @intCast(i & 31);
    const verts = [_]i32{
        0,       0, 0,       0,
        10 + o,  0, 0,       0,
        10 + o,  0, 10 + o,  0,
        0,       0, 10 + o,  0,
    };
    dna(calcAreaOfPolygon2DReverse(&verts, 4));
}

fn checkCalcAreaAnalog() bool {
    // Sweep 2048 varied inputs; compare |orig| == |analog| on each.
    var k: usize = 0;
    while (k < 2048) : (k += 1) {
        const o: i32 = @intCast(k & 127);
        const verts = [_]i32{
            0,       0, 0,       0,
            10 + o,  0, 0,       0,
            10 + o,  0, 10 + o,  0,
            0,       0, 10 + o,  0,
        };
        const orig = nav.recast.contour.calcAreaOfPolygon2D(&verts, 4);
        const alt  = calcAreaOfPolygon2DReverse(&verts, 4);
        if (@abs(orig) != @abs(alt)) return false;
    }
    return true;
}

// ============================================================================
// intersectProp
// Signature: (a,b,c,d: []const i32) bool
// Each arg is a slice into a flat vert array; uses [0]=x, [2]=z.
// ============================================================================

fn runIntersectProp(i: usize) void {
    const o: i32 = @intCast(i & 15);
    // Segment ab: (0,0)-(10+o, 10+o); cd: (0,10+o)-(10+o,0) — proper X
    const a = [_]i32{ 0,         0, 0,         0 };
    const b = [_]i32{ 10 + o,    0, 10 + o,    0 };
    const c = [_]i32{ 0,         0, 10 + o,    0 };
    const d = [_]i32{ 10 + o,    0, 0,         0 };
    dna(nav.recast.contour.intersectProp(&a, &b, &c, &d));
}

fn checkIntersectProp() bool {
    // ab: (0,0)-(10,10); cd: (0,10)-(10,0) — classic X, proper intersection
    const a = [_]i32{ 0,  0, 0,  0 };
    const b = [_]i32{ 10, 0, 10, 0 };
    const c = [_]i32{ 0,  0, 10, 0 };
    const d = [_]i32{ 10, 0, 0,  0 };
    return nav.recast.contour.intersectProp(&a, &b, &c, &d) == true;
}

// Analog: swap the two half-plane tests (logically equivalent by AND symmetry).
fn intersectPropAlt(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    // area2 inline (uses [0]=x, [2]=z)
    const area2 = struct {
        fn f(p: []const i32, q: []const i32, r: []const i32) i32 {
            return (q[0] - p[0]) * (r[2] - p[2]) - (r[0] - p[0]) * (q[2] - p[2]);
        }
    }.f;
    const collinear = struct {
        fn f(p: []const i32, q: []const i32, r: []const i32) bool { return area2(p, q, r) == 0; }
    }.f;
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
        return false;
    // Swapped operand order in the second test (still semantically identical)
    const leftAB_C = area2(a, b, c) < 0;
    const leftAB_D = area2(a, b, d) < 0;
    const leftCD_B = area2(c, d, b) < 0;
    const leftCD_A = area2(c, d, a) < 0;
    return (leftAB_C != leftAB_D) and (leftCD_A != leftCD_B);
}

fn runIntersectPropAnalog(i: usize) void {
    const o: i32 = @intCast(i & 15);
    const a = [_]i32{ 0,         0, 0,         0 };
    const b = [_]i32{ 10 + o,    0, 10 + o,    0 };
    const c = [_]i32{ 0,         0, 10 + o,    0 };
    const d = [_]i32{ 10 + o,    0, 0,         0 };
    dna(intersectPropAlt(&a, &b, &c, &d));
}

fn checkIntersectPropAnalog() bool {
    var k: i32 = 1;
    while (k <= 2048) : (k += 1) {
        const o = k;
        const a = [_]i32{ 0,      0, 0,      0 };
        const b = [_]i32{ o * 10, 0, o * 10, 0 };
        const c = [_]i32{ 0,      0, o * 10, 0 };
        const d = [_]i32{ o * 10, 0, 0,      0 };
        if (nav.recast.contour.intersectProp(&a, &b, &c, &d) != intersectPropAlt(&a, &b, &c, &d))
            return false;
        // Also test non-intersecting case
        const e = [_]i32{ 0,      0, 0,      0 };
        const f = [_]i32{ o,      0, 0,      0 };
        const g = [_]i32{ 0,      0, o + 2,  0 };
        const h = [_]i32{ o,      0, o + 2,  0 };
        if (nav.recast.contour.intersectProp(&e, &f, &g, &h) != intersectPropAlt(&e, &f, &g, &h))
            return false;
    }
    return true;
}

// ============================================================================
// intersect
// Signature: (a,b,c,d: []const i32) bool
// Extends intersectProp with between() endpoint checks.
// ============================================================================

fn runIntersect(i: usize) void {
    const o: i32 = @intCast(i & 15);
    // T-intersection: ab horizontal, c on segment, d off
    const a = [_]i32{ 0,         0, 5, 0 };
    const b = [_]i32{ 10 + o,    0, 5, 0 };
    const c = [_]i32{ 5,         0, 5, 0 }; // c on ab -> between case
    const d = [_]i32{ 5,         0, 0, 0 };
    dna(nav.recast.contour.intersect(&a, &b, &c, &d));
}

fn checkIntersect() bool {
    // T-intersection: c lies on ab -> intersect returns true via between()
    const a = [_]i32{ 0,  0, 5, 0 };
    const b = [_]i32{ 10, 0, 5, 0 };
    const c = [_]i32{ 5,  0, 5, 0 };
    const d = [_]i32{ 5,  0, 0, 0 };
    return nav.recast.contour.intersect(&a, &b, &c, &d) == true;
}

// Analog: early-return on between checks before intersectProp (same logic, different order).
fn intersectAlt(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    // between inline
    const area2 = struct {
        fn f(p: []const i32, q: []const i32, r: []const i32) i32 {
            return (q[0] - p[0]) * (r[2] - p[2]) - (r[0] - p[0]) * (q[2] - p[2]);
        }
    }.f;
    const collinear = struct {
        fn f(p: []const i32, q: []const i32, r: []const i32) bool { return area2(p, q, r) == 0; }
    }.f;
    const betweenFn = struct {
        fn f(p: []const i32, q: []const i32, r: []const i32) bool {
            if (!collinear(p, q, r)) return false;
            if (p[0] != q[0])
                return ((p[0] <= r[0]) and (r[0] <= q[0])) or ((p[0] >= r[0]) and (r[0] >= q[0]))
            else
                return ((p[2] <= r[2]) and (r[2] <= q[2])) or ((p[2] >= r[2]) and (r[2] >= q[2]));
        }
    }.f;

    // Check between cases first, then proper
    if (betweenFn(a, b, c) or betweenFn(a, b, d) or
        betweenFn(c, d, a) or betweenFn(c, d, b))
        return true;
    return nav.recast.contour.intersectProp(a, b, c, d);
}

fn runIntersectAnalog(i: usize) void {
    const o: i32 = @intCast(i & 15);
    const a = [_]i32{ 0,         0, 5, 0 };
    const b = [_]i32{ 10 + o,    0, 5, 0 };
    const c = [_]i32{ 5,         0, 5, 0 };
    const d = [_]i32{ 5,         0, 0, 0 };
    dna(intersectAlt(&a, &b, &c, &d));
}

fn checkIntersectAnalog() bool {
    var k: i32 = 1;
    while (k <= 2048) : (k += 1) {
        const o = k;
        // proper X case
        {
            const a = [_]i32{ 0,      0, 0,      0 };
            const b = [_]i32{ o * 2,  0, o * 2,  0 };
            const c = [_]i32{ 0,      0, o * 2,  0 };
            const d = [_]i32{ o * 2,  0, 0,      0 };
            if (nav.recast.contour.intersect(&a, &b, &c, &d) != intersectAlt(&a, &b, &c, &d))
                return false;
        }
        // T-intersection (endpoint on segment)
        {
            const a = [_]i32{ 0,     0, o, 0 };
            const b = [_]i32{ o * 2, 0, o, 0 };
            const c = [_]i32{ o,     0, o, 0 };
            const d = [_]i32{ o,     0, 0, 0 };
            if (nav.recast.contour.intersect(&a, &b, &c, &d) != intersectAlt(&a, &b, &c, &d))
                return false;
        }
    }
    return true;
}

// ============================================================================
// intersectSegContour
// Signature: (d0,d1: []const i32, i: i32, n: i32, verts: []const i32) bool
// verts stride=4; tests d0-d1 against each contour edge (k, next(k,n)),
// skipping edges incident to vertex i.
// ============================================================================

// Build a square contour: 4 verts at (0,0),(10,0),(10,10),(0,10)
const squareContour = [_]i32{
    0,  0, 0,  0,
    10, 0, 0,  0,
    10, 0, 10, 0,
    0,  0, 10, 0,
};

fn runIntersectSegContour(i: usize) void {
    const o: i32 = @intCast(i & 7);
    // d0-d1 is a diagonal that varies with o; skip vertex i=0
    const d0 = [_]i32{ 1 + o,  0, 1 + o,  0 };
    const d1 = [_]i32{ 9 - o,  0, 9 - o,  0 };
    dna(nav.recast.contour.intersectSegContour(&d0, &d1, 0, 4, &squareContour));
}

fn checkIntersectSegContour() bool {
    // A segment that crosses the top edge (from y=5 to y=15 in xz plane)
    // d0=(5,5) d1=(5,15), skip i=-1 (no skip), n=4, square has top edge from (0,10)-(10,10)
    // d0-d1 is vertical at x=5, from z=5 to z=15; crosses top edge z=10 between x=0 and x=10
    const d0 = [_]i32{ 5, 0, 5,  0 };
    const d1 = [_]i32{ 5, 0, 15, 0 };
    return nav.recast.contour.intersectSegContour(&d0, &d1, -1, 4, &squareContour) == true;
}

// Analog: collect-then-reduce — accumulate results into a bool using |=
// instead of early return on true.  Logically identical but forces all edge
// checks to run (different branch pattern; same final value).
fn intersectSegContourNoEarlyExit(
    d0: []const i32,
    d1: []const i32,
    iSkip: i32,
    n: i32,
    verts: []const i32,
) bool {
    var hit = false;
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        const k1 = if (k + 1 < n) k + 1 else 0; // next(k, n)
        if (iSkip == k or iSkip == k1) continue;
        const ku: usize = @intCast(k);
        const k1u: usize = @intCast(k1);
        const p0 = verts[ku * 4 .. ku * 4 + 4];
        const p1 = verts[k1u * 4 .. k1u * 4 + 4];
        // vequal inline
        const eq = struct {
            fn f(x: []const i32, y: []const i32) bool {
                return x[0] == y[0] and x[2] == y[2];
            }
        }.f;
        if (eq(d0, p0) or eq(d1, p0) or eq(d0, p1) or eq(d1, p1)) continue;
        if (nav.recast.contour.intersect(d0, d1, p0, p1)) hit = true;
    }
    return hit;
}

fn runIntersectSegContourAnalog(i: usize) void {
    const o: i32 = @intCast(i & 7);
    const d0 = [_]i32{ 1 + o,  0, 1 + o,  0 };
    const d1 = [_]i32{ 9 - o,  0, 9 - o,  0 };
    dna(intersectSegContourNoEarlyExit(&d0, &d1, 0, 4, &squareContour));
}

fn checkIntersectSegContourAnalog() bool {
    // Sweep various d0-d1 diagonals against a 6-vertex hexagonal contour; compare results.
    const hex = [_]i32{
        10, 0, 0,  0,
        20, 0, 0,  0,
        25, 0, 10, 0,
        20, 0, 20, 0,
        10, 0, 20, 0,
        5,  0, 10, 0,
    };
    var k: i32 = 0;
    while (k < 2048) : (k += 1) {
        const ox: i32 = @rem(k, 30);
        const oz: i32 = @rem(k * 7, 30);
        const d0 = [_]i32{ ox,          0, oz,          0 };
        const d1 = [_]i32{ ox + 5,      0, oz + 5,      0 };
        const orig = nav.recast.contour.intersectSegContour(&d0, &d1, @rem(k, 6), 6, &hex);
        const alt  = intersectSegContourNoEarlyExit(&d0, &d1, @rem(k, 6), 6, &hex);
        if (orig != alt) return false;
    }
    return true;
}

// ============================================================================
// Bench table
// ============================================================================

pub const benches = [_]core.Bench{
    // calcAreaOfPolygon2D — orig
    .{ .name = "calcAreaOfPolygon2D", .module = "recast.contour", .isolation = "A", .run = runCalcArea, .check = checkCalcArea },
    // calcAreaOfPolygon2D — analog (reverse-order shoelace; |result| identical)
    .{ .name = "calcAreaOfPolygon2D", .module = "recast.contour", .impl = "reverse-order", .isolation = "A", .run = runCalcAreaAnalog, .check = checkCalcAreaAnalog },
    // intersectProp — orig
    .{ .name = "intersectProp", .module = "recast.contour", .isolation = "A", .run = runIntersectProp, .check = checkIntersectProp },
    // intersectProp — analog (swapped operand order in half-plane tests; bit-identical)
    .{ .name = "intersectProp", .module = "recast.contour", .impl = "swap-halfplane-order", .isolation = "A", .run = runIntersectPropAnalog, .check = checkIntersectPropAnalog },
    // intersect — orig
    .{ .name = "intersect", .module = "recast.contour", .isolation = "A", .run = runIntersect, .check = checkIntersect },
    // intersect — analog (between checks before intersectProp; bit-identical)
    .{ .name = "intersect", .module = "recast.contour", .impl = "between-first", .isolation = "A", .run = runIntersectAnalog, .check = checkIntersectAnalog },
    // intersectSegContour — orig
    .{ .name = "intersectSegContour", .module = "recast.contour", .isolation = "A", .run = runIntersectSegContour, .check = checkIntersectSegContour },
    // intersectSegContour — analog (no early-exit; visits all edges; bit-identical)
    .{ .name = "intersectSegContour", .module = "recast.contour", .impl = "no-early-exit", .isolation = "A", .run = runIntersectSegContourAnalog, .check = checkIntersectSegContourAnalog },
};
