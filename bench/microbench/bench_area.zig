//! Bench group: recast.area leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;
const Vec3 = nav.math.Vec3;

// ===========================================================================
// insertSort — orig
// Input: 8-byte mutable local seeded by i. dna the sorted[0] to prevent elision.
// ===========================================================================
fn runInsertSort(i: usize) void {
    var data = [_]u8{
        @intCast((i *% 7) & 255),
        @intCast((i *% 31 +% 3) & 255),
        200,
        17,
        99,
        1,
        255,
        42,
    };
    nav.recast.area.insertSort(&data);
    dna(data[0]);
}
fn checkInsertSort() bool {
    var data = [_]u8{ 5, 3, 4, 1, 2 };
    nav.recast.area.insertSort(&data);
    return data[0] <= data[1] and data[1] <= data[2] and data[2] <= data[3] and data[3] <= data[4];
}

// ===========================================================================
// insertSort analog — std.mem.sort (stdlib pdqsort on []u8)
// Gate: EXACT byte-identical sorted output vs insertSort over 2048 varied inputs.
// Expected verdict: TIE (same O(n) work on n=8; may differ in constant factor).
// ===========================================================================
fn insertSort_stdlib(data: []u8) void {
    std.mem.sort(u8, data, {}, std.sort.asc(u8));
}
fn runInsertSortStdlib(i: usize) void {
    var data = [_]u8{
        @intCast((i *% 7) & 255),
        @intCast((i *% 31 +% 3) & 255),
        200,
        17,
        99,
        1,
        255,
        42,
    };
    insertSort_stdlib(&data);
    dna(data[0]);
}
fn checkInsertSortStdlib() bool {
    // EXACT identity gate over 2048 varied 8-element arrays.
    var i: usize = 0;
    while (i < 2048) : (i += 1) {
        var a = [_]u8{
            @intCast((i *% 7) & 255),
            @intCast((i *% 31 +% 3) & 255),
            @intCast((i *% 53 +% 200) & 255),
            @intCast((i *% 97 +% 17) & 255),
            @intCast((i *% 13 +% 99) & 255),
            @intCast((i *% 41 +% 1) & 255),
            @intCast((i *% 127 +% 255) & 255),
            @intCast((i *% 19 +% 42) & 255),
        };
        var b = a;
        nav.recast.area.insertSort(&a);
        insertSort_stdlib(&b);
        if (!std.mem.eql(u8, &a, &b)) return false;
    }
    return true;
}

// ===========================================================================
// pointInPoly — orig
// Input: square polygon [0,10]x[0,10] in XZ; point x,z vary with i.
// dna the bool result.
// ===========================================================================
const pip_verts = [_]f32{
    0,  0, 0,
    10, 0, 0,
    10, 0, 10,
    0,  0, 10,
};
fn runPointInPoly(i: usize) void {
    const fx = @as(f32, @floatFromInt(i & 15)) * 0.7;
    const fz = @as(f32, @floatFromInt((i >> 4) & 15)) * 0.7;
    dna(nav.recast.area.pointInPoly(4, &pip_verts, Vec3.init(fx, 0, fz)));
}
fn checkPointInPoly() bool {
    // point inside the square
    if (!nav.recast.area.pointInPoly(4, &pip_verts, Vec3.init(5, 0, 5))) return false;
    // point outside the square
    if (nav.recast.area.pointInPoly(4, &pip_verts, Vec3.init(15, 0, 15))) return false;
    return true;
}

// ===========================================================================
// pointInPoly analog — modulo-predecessor loop
// Same float crossing test, same i/j pairs but j = (i+n-1)%n instead of a
// trailing j variable. Structurally different loop but identical IEEE ops and
// accumulation order -> should be bit-identical bool (TIE).
// Gate: EXACT bool identity over 2000+ (x,z) grid sweep.
// ===========================================================================
fn pointInPoly_mod(num_verts: usize, verts: []const f32, point: Vec3) bool {
    var in_poly = false;
    var i: usize = 0;
    while (i < num_verts) : (i += 1) {
        const j = (i + num_verts - 1) % num_verts;
        const vi_idx = i * 3;
        const vj_idx = j * 3;
        const vi_x = verts[vi_idx];
        const vi_z = verts[vi_idx + 2];
        const vj_x = verts[vj_idx];
        const vj_z = verts[vj_idx + 2];
        if ((vi_z > point.z) == (vj_z > point.z)) continue;
        if (point.x >= (vj_x - vi_x) * (point.z - vi_z) / (vj_z - vi_z) + vi_x) continue;
        in_poly = !in_poly;
    }
    return in_poly;
}
fn runPointInPolyMod(i: usize) void {
    const fx = @as(f32, @floatFromInt(i & 15)) * 0.7;
    const fz = @as(f32, @floatFromInt((i >> 4) & 15)) * 0.7;
    dna(pointInPoly_mod(4, &pip_verts, Vec3.init(fx, 0, fz)));
}
fn checkPointInPolyMod() bool {
    // EXACT bool identity over a 2025-point grid sweep.
    var xi: usize = 0;
    while (xi < 45) : (xi += 1) {
        var zi: usize = 0;
        while (zi < 45) : (zi += 1) {
            const fx = @as(f32, @floatFromInt(xi)) * 0.5 - 5.0;
            const fz = @as(f32, @floatFromInt(zi)) * 0.5 - 5.0;
            const pt = Vec3.init(fx, 0, fz);
            if (pointInPoly_mod(4, &pip_verts, pt) !=
                nav.recast.area.pointInPoly(4, &pip_verts, pt)) return false;
        }
    }
    return true;
}

// ===========================================================================
// vsafeNormalize — orig
// Input: Vec3 varied by i (non-zero so the branch is taken). dna v.x after call.
// ===========================================================================
fn runVsafeNormalize(i: usize) void {
    const f = @as(f32, @floatFromInt((i & 31) + 1));
    var v = Vec3.init(3.0 + f * 0.1, 4.0, 0.0);
    nav.recast.area.vsafeNormalize(&v);
    dna(v.x);
}
fn checkVsafeNormalize() bool {
    // normalized (3,4,0) -> (0.6, 0.8, 0.0); check unit length within tolerance
    var v = Vec3.init(3.0, 4.0, 0.0);
    nav.recast.area.vsafeNormalize(&v);
    const len_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    return @abs(len_sq - 1.0) < 1e-5 and @abs(v.x - 0.6) < 1e-5;
}

// ===========================================================================
// vsafeNormalize analog — divide-by-length (div) instead of multiply-by-reciprocal
// orig: inv = 1/sqrt(sq); v.x *= inv   (one div + three muls)
// analog: len = sqrt(sq); v.x /= len   (one div per component = three divs)
// Dividing x/len vs x*(1/len) gives a different rounding in general ->
// the EXACT-identity gate is expected to REJECT this (check_ok=no), proving the
// two implementations are not bit-identical and the original must be kept.
// ===========================================================================
const EPSILON_AREA: f32 = 1e-6;
fn vsafeNormalize_div(v: *Vec3) void {
    const sq_mag = v.x * v.x + v.y * v.y + v.z * v.z;
    if (sq_mag > EPSILON_AREA) {
        const len = @sqrt(sq_mag);
        v.x /= len;
        v.y /= len;
        v.z /= len;
    }
}
fn runVsafeNormalizeDiv(i: usize) void {
    const f = @as(f32, @floatFromInt((i & 31) + 1));
    var v = Vec3.init(3.0 + f * 0.1, 4.0, 0.0);
    vsafeNormalize_div(&v);
    dna(v.x);
}
fn checkVsafeNormalizeDiv() bool {
    // EXACT bit-identity vs orig over 2048 varied non-zero vectors.
    // Expected to differ for most inputs (reciprocal-mul != component-div).
    var i: usize = 1;
    while (i < 2048) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        var a = Vec3.init(fa * 0.37, fa * 0.19 + 1.0, fa * 0.11 + 0.5);
        var b = a;
        nav.recast.area.vsafeNormalize(&a);
        vsafeNormalize_div(&b);
        if (a.x != b.x or a.y != b.y or a.z != b.z) return false;
    }
    return true;
}

pub const benches = [_]core.Bench{
    // -- orig --
    .{ .name = "insertSort", .module = "recast.area", .isolation = "A", .run = runInsertSort, .check = checkInsertSort },
    .{ .name = "pointInPoly", .module = "recast.area", .isolation = "A", .run = runPointInPoly, .check = checkPointInPoly },
    .{ .name = "vsafeNormalize", .module = "recast.area", .isolation = "A", .run = runVsafeNormalize, .check = checkVsafeNormalize },
    // -- analogs --
    // insertSort/std.mem.sort: stdlib pdqsort on n=8; expected TIE or WIN for stdlib.
    .{ .name = "insertSort", .module = "recast.area", .impl = "stdlib-sort", .isolation = "A", .run = runInsertSortStdlib, .check = checkInsertSortStdlib },
    // pointInPoly/mod-index: same float ops reordered via modulo predecessor; expected TIE (bit-identical).
    .{ .name = "pointInPoly", .module = "recast.area", .impl = "mod-index", .isolation = "A", .run = runPointInPolyMod, .check = checkPointInPolyMod },
    // vsafeNormalize/div: component-div vs reciprocal-mul; expected REJECT (not bit-identical due to rounding).
    .{ .name = "vsafeNormalize", .module = "recast.area", .impl = "div", .isolation = "A", .run = runVsafeNormalizeDiv, .check = checkVsafeNormalizeDiv },
};
