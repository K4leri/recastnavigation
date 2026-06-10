//! Bench group: recast.mesh + recast.rasterization leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;
const Vec3 = nav.math.Vec3;

// ---------------------------------------------------------------------------
// overlapBounds (recast.rasterization) — orig + analog
// ---------------------------------------------------------------------------

fn runOverlapBounds(i: usize) void {
    const f: f32 = @floatFromInt(i & 15);
    dna(nav.recast.rasterization.overlapBounds(
        Vec3.init(0, 0, 0),
        Vec3.init(5 + f, 5, 5),
        Vec3.init(3, 3, 3),
        Vec3.init(8, 8, 8),
    ));
}
fn checkOverlapBounds() bool {
    return nav.recast.rasterization.overlapBounds(
        Vec3.init(0, 0, 0), Vec3.init(5, 5, 5),
        Vec3.init(3, 3, 3), Vec3.init(8, 8, 8),
    ) and !nav.recast.rasterization.overlapBounds(
        Vec3.init(0, 0, 0), Vec3.init(5, 5, 5),
        Vec3.init(10, 10, 10), Vec3.init(12, 12, 12),
    );
}

/// Analog: reordered AND-chain (z first, then y, then x) — De Morgan-equivalent,
/// same six comparisons, just evaluated in a different left-to-right order so
/// short-circuit behaviour may differ; bool result is bit-identical.
fn overlapBoundsZYX(amin: Vec3, amax: Vec3, bmin: Vec3, bmax: Vec3) bool {
    return amin.z <= bmax.z and amax.z >= bmin.z and
        amin.y <= bmax.y and amax.y >= bmin.y and
        amin.x <= bmax.x and amax.x >= bmin.x;
}
fn runOverlapBoundsZYX(i: usize) void {
    const f: f32 = @floatFromInt(i & 15);
    dna(overlapBoundsZYX(
        Vec3.init(0, 0, 0),
        Vec3.init(5 + f, 5, 5),
        Vec3.init(3, 3, 3),
        Vec3.init(8, 8, 8),
    ));
}
fn checkOverlapBoundsZYX() bool {
    // EXACT identity gate vs orig over 2025 varied inputs.
    var ix: i32 = -5;
    while (ix <= 40) : (ix += 1) {
        var iz: i32 = -5;
        while (iz <= 40) : (iz += 1) {
            const fx: f32 = @floatFromInt(ix);
            const fz: f32 = @floatFromInt(iz);
            const got = overlapBoundsZYX(
                Vec3.init(0, 0, 0), Vec3.init(fx, 10, fz),
                Vec3.init(3, 3, 3), Vec3.init(8, 8, 8),
            );
            const want = nav.recast.rasterization.overlapBounds(
                Vec3.init(0, 0, 0), Vec3.init(fx, 10, fz),
                Vec3.init(3, 3, 3), Vec3.init(8, 8, 8),
            );
            if (got != want) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Helper: area2 inline (reproduces the kernel used by intersectProp/intersect)
// area2(a,b,c) = (b[0]-a[0])*(c[2]-a[2]) - (c[0]-a[0])*(b[2]-a[2])
// ---------------------------------------------------------------------------
inline fn area2(a: []const i32, b: []const i32, c: []const i32) i32 {
    return (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);
}

// ---------------------------------------------------------------------------
// intersectProp (recast.mesh) — orig + analog
// ---------------------------------------------------------------------------

// Varied segments that properly cross: A=(0,0,10)→B=(10,0,10), C=(5,0,5)→D=(5,0,15)
// Use index [0]=x [2]=z (y ignored by the predicate)
const seg_a0 = [4]i32{ 0, 0, 0, 0 };
const seg_b0 = [4]i32{ 10, 0, 10, 0 };
const seg_c0 = [4]i32{ 5, 0, 5, 0 };
const seg_d0 = [4]i32{ 5, 0, 15, 0 };
// Parallel segments that do NOT cross
const seg_c1 = [4]i32{ 0, 0, 5, 0 };
const seg_d1 = [4]i32{ 10, 0, 5, 0 };

fn runIntersectProp(i: usize) void {
    const o: i32 = @intCast(i & 7);
    var a = [4]i32{ 0, 0, 0, 0 };
    var b = [4]i32{ 10 + o, 0, 10, 0 };
    var c = [4]i32{ 5, 0, 5, 0 };
    var d = [4]i32{ 5, 0, 15, 0 };
    dna(nav.recast.mesh.intersectProp(&a, &b, &c, &d));
}
fn checkIntersectProp() bool {
    // Properly crossing → true
    const t = nav.recast.mesh.intersectProp(&seg_a0, &seg_b0, &seg_c0, &seg_d0);
    // Parallel (collinear endpoints) → false
    const f = nav.recast.mesh.intersectProp(&seg_a0, &seg_b0, &seg_c1, &seg_d1);
    return t and !f;
}

/// Analog: fully inlined — expand left/collinear via area2 macro, eliminate
/// helper-function call overhead.  Identical integer arithmetic → bit-identical.
fn intersectPropInline(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    // collinear checks (area2 == 0)
    if (area2(a, b, c) == 0 or area2(a, b, d) == 0 or
        area2(c, d, a) == 0 or area2(c, d, b) == 0) return false;
    // left(a,b,c) = area2(a,b,c) < 0
    const lab_c = area2(a, b, c) < 0;
    const lab_d = area2(a, b, d) < 0;
    const lcd_a = area2(c, d, a) < 0;
    const lcd_b = area2(c, d, b) < 0;
    return (lab_c != lab_d) and (lcd_a != lcd_b);
}
fn runIntersectPropInline(i: usize) void {
    const o: i32 = @intCast(i & 7);
    var a = [4]i32{ 0, 0, 0, 0 };
    var b = [4]i32{ 10 + o, 0, 10, 0 };
    var c = [4]i32{ 5, 0, 5, 0 };
    var d = [4]i32{ 5, 0, 15, 0 };
    dna(intersectPropInline(&a, &b, &c, &d));
}
fn checkIntersectPropInline() bool {
    // EXACT identity gate over 2025 input combinations.
    var ox: i32 = -22;
    while (ox <= 22) : (ox += 1) {
        var oz: i32 = -22;
        while (oz <= 22) : (oz += 1) {
            var a = [4]i32{ 0, 0, 0, 0 };
            var b = [4]i32{ 10, 0, 10, 0 };
            var c = [4]i32{ ox, 0, oz, 0 };
            var d = [4]i32{ ox + 4, 0, oz + 8, 0 };
            if (intersectPropInline(&a, &b, &c, &d) !=
                nav.recast.mesh.intersectProp(&a, &b, &c, &d)) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// intersect (recast.mesh) — orig + analog
// ---------------------------------------------------------------------------

fn runIntersect(i: usize) void {
    const o: i32 = @intCast(i & 7);
    var a = [4]i32{ 0, 0, 0, 0 };
    var b = [4]i32{ 10 + o, 0, 10, 0 };
    var c = [4]i32{ 5, 0, 5, 0 };
    var d = [4]i32{ 5, 0, 15, 0 };
    dna(nav.recast.mesh.intersect(&a, &b, &c, &d));
}
fn checkIntersect() bool {
    // Proper crossing → true
    const t = nav.recast.mesh.intersect(&seg_a0, &seg_b0, &seg_c0, &seg_d0);
    // T-endpoint on segment: c on ab → improperly intersecting → true
    var a2 = [4]i32{ 0, 0, 0, 0 };
    var b2 = [4]i32{ 10, 0, 0, 0 };
    var c2 = [4]i32{ 5, 0, 0, 0 }; // c midpoint on ab
    var d2 = [4]i32{ 5, 0, 5, 0 };
    const t2 = nav.recast.mesh.intersect(&a2, &b2, &c2, &d2);
    // Disjoint → false
    const f = nav.recast.mesh.intersect(&seg_a0, &seg_b0, &seg_c1, &seg_d1);
    return t and t2 and !f;
}

/// Analog: early-out version — test intersectPropInline first, then inline
/// the `between` helper.  Identical integer ops → bit-identical.
fn betweenInline(a: []const i32, b: []const i32, c: []const i32) bool {
    if (area2(a, b, c) != 0) return false;
    if (a[0] != b[0]) {
        return ((a[0] <= c[0]) and (c[0] <= b[0])) or ((a[0] >= c[0]) and (c[0] >= b[0]));
    }
    return ((a[2] <= c[2]) and (c[2] <= b[2])) or ((a[2] >= c[2]) and (c[2] >= b[2]));
}
fn intersectInline(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    if (intersectPropInline(a, b, c, d)) return true;
    return betweenInline(a, b, c) or betweenInline(a, b, d) or
        betweenInline(c, d, a) or betweenInline(c, d, b);
}
fn runIntersectInline(i: usize) void {
    const o: i32 = @intCast(i & 7);
    var a = [4]i32{ 0, 0, 0, 0 };
    var b = [4]i32{ 10 + o, 0, 10, 0 };
    var c = [4]i32{ 5, 0, 5, 0 };
    var d = [4]i32{ 5, 0, 15, 0 };
    dna(intersectInline(&a, &b, &c, &d));
}
fn checkIntersectInline() bool {
    // EXACT identity gate over 2025 input combinations.
    var ox: i32 = -22;
    while (ox <= 22) : (ox += 1) {
        var oz: i32 = -22;
        while (oz <= 22) : (oz += 1) {
            var a = [4]i32{ 0, 0, 0, 0 };
            var b = [4]i32{ 10, 0, 10, 0 };
            var c = [4]i32{ ox, 0, oz, 0 };
            var d = [4]i32{ ox + 4, 0, oz + 8, 0 };
            if (intersectInline(&a, &b, &c, &d) !=
                nav.recast.mesh.intersect(&a, &b, &c, &d)) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// vequal (recast.mesh) — orig + analog
// ---------------------------------------------------------------------------

fn runVequal(i: usize) void {
    const o: i32 = @intCast(i & 15);
    var a = [4]i32{ 3 + o, 0, 7, 0 };
    var b = [4]i32{ 3 + (o & 1), 0, 7, 0 };
    dna(nav.recast.mesh.vequal(&a, &b));
}
fn checkVequal() bool {
    var eq = [4]i32{ 5, 0, 9, 0 };
    var ne = [4]i32{ 5, 1, 8, 0 }; // same x, different z
    var neX = [4]i32{ 6, 0, 9, 0 }; // different x
    return nav.recast.mesh.vequal(&eq, &eq) and
        !nav.recast.mesh.vequal(&eq, &ne) and
        !nav.recast.mesh.vequal(&eq, &neX);
}

/// Analog: OR-difference trick — (a[0]-b[0]) | (a[2]-b[2]) == 0 iff both
/// differences are zero.  Same integer ops, no branch on two comparisons.
fn vequalOrDiff(a: []const i32, b: []const i32) bool {
    return ((a[0] - b[0]) | (a[2] - b[2])) == 0;
}
fn runVequalOrDiff(i: usize) void {
    const o: i32 = @intCast(i & 15);
    var a = [4]i32{ 3 + o, 0, 7, 0 };
    var b = [4]i32{ 3 + (o & 1), 0, 7, 0 };
    dna(vequalOrDiff(&a, &b));
}
fn checkVequalOrDiff() bool {
    // EXACT identity gate over 2025 input combinations.
    var dx: i32 = -22;
    while (dx <= 22) : (dx += 1) {
        var dz: i32 = -22;
        while (dz <= 22) : (dz += 1) {
            var a = [4]i32{ 10, 0, 10, 0 };
            var b = [4]i32{ 10 + dx, 0, 10 + dz, 0 };
            if (vequalOrDiff(&a, &b) != nav.recast.mesh.vequal(&a, &b)) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Bench table
// ---------------------------------------------------------------------------

pub const benches = [_]core.Bench{
    // overlapBounds
    .{ .name = "overlapBounds", .module = "recast.rasterization", .isolation = "A", .run = runOverlapBounds, .check = checkOverlapBounds },
    .{ .name = "overlapBounds", .module = "recast.rasterization", .impl = "zyx-chain", .isolation = "A", .run = runOverlapBoundsZYX, .check = checkOverlapBoundsZYX },
    // intersectProp
    .{ .name = "intersectProp", .module = "recast.mesh", .isolation = "A", .run = runIntersectProp, .check = checkIntersectProp },
    .{ .name = "intersectProp", .module = "recast.mesh", .impl = "inlined", .isolation = "A", .run = runIntersectPropInline, .check = checkIntersectPropInline },
    // intersect
    .{ .name = "intersect", .module = "recast.mesh", .isolation = "A", .run = runIntersect, .check = checkIntersect },
    .{ .name = "intersect", .module = "recast.mesh", .impl = "inlined", .isolation = "A", .run = runIntersectInline, .check = checkIntersectInline },
    // vequal
    .{ .name = "vequal", .module = "recast.mesh", .isolation = "A", .run = runVequal, .check = checkVequal },
    .{ .name = "vequal", .module = "recast.mesh", .impl = "or-diff", .isolation = "A", .run = runVequalOrDiff, .check = checkVequalOrDiff },
};
