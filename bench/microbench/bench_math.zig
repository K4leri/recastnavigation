//! Bench group: math.zig leaf / pure functions (isolation class A), original impl.
//! Analogs of these live in analogs_math.zig. Aggregated by ../microbench.zig.

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const Vec3 = nav.math.Vec3;
const dna = std.mem.doNotOptimizeAway;

// scratch destinations for void-returning vector ops (kept out of the timed path).
var d3: [3]f32 = undefined;

fn runTriArea2D(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.triArea2D(Vec3.init(0, 0, 0), Vec3.init(4 + f, 0, 1), Vec3.init(2, 0, 5)));
}
fn checkTriArea2D() bool {
    return @abs(nav.math.triArea2D(Vec3.init(0, 0, 0), Vec3.init(4, 0, 1), Vec3.init(2, 0, 5)) - (-18.0)) < 1e-3;
}

fn runVdist(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vdist(&[3]f32{ 0, 0, 0 }, &[3]f32{ 3 + f, 4, 0 }));
}
fn checkVdist() bool {
    return @abs(nav.math.vdist(&[3]f32{ 0, 0, 0 }, &[3]f32{ 3, 4, 0 }) - 5.0) < 1e-3;
}

fn runVdistSqr(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vdistSqr(&[3]f32{ 0, 0, 0 }, &[3]f32{ 1 + f, 2, 2 }));
}
fn checkVdistSqr() bool {
    return @abs(nav.math.vdistSqr(&[3]f32{ 0, 0, 0 }, &[3]f32{ 1, 2, 2 }) - 9.0) < 1e-3;
}

fn runVdot(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vdot(&[3]f32{ 1 + f, 2, 3 }, &[3]f32{ 4, 5, 6 }));
}
fn checkVdot() bool {
    return @abs(nav.math.vdot(&[3]f32{ 1, 2, 3 }, &[3]f32{ 4, 5, 6 }) - 32.0) < 1e-3;
}

fn runVlen(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vlen(&[3]f32{ 3 + f, 4, 0 }));
}
fn checkVlen() bool {
    return @abs(nav.math.vlen(&[3]f32{ 3, 4, 0 }) - 5.0) < 1e-3;
}

fn runVlenSqr(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vlenSqr(&[3]f32{ 3 + f, 4, 0 }));
}
fn checkVlenSqr() bool {
    return @abs(nav.math.vlenSqr(&[3]f32{ 3, 4, 0 }) - 25.0) < 1e-3;
}

fn runVcross(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15)) * 0.0;
    nav.math.vcross(&d3, &[3]f32{ 1 + f, 0, 0 }, &[3]f32{ 0, 1, 0 });
    dna(d3[2]);
}
fn checkVcross() bool {
    var d: [3]f32 = undefined;
    nav.math.vcross(&d, &[3]f32{ 1, 0, 0 }, &[3]f32{ 0, 1, 0 });
    return @abs(d[2] - 1) < 1e-3 and @abs(d[0]) < 1e-3 and @abs(d[1]) < 1e-3;
}

fn runVlerp(i: usize) void {
    const t = @as(f32, @floatFromInt(i & 15)) / 15.0;
    nav.math.vlerp(&d3, &[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, t);
    dna(d3[0]);
}
fn checkVlerp() bool {
    var d: [3]f32 = undefined;
    nav.math.vlerp(&d, &[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, 0.5);
    return @abs(d[0] - 5) < 1e-3;
}

fn runVnormalize(i: usize) void {
    d3 = [3]f32{ 3 + @as(f32, @floatFromInt(i & 15)), 4, 0 };
    nav.math.vnormalize(&d3);
    dna(d3[0]);
}
fn checkVnormalize() bool {
    var v = [3]f32{ 3, 4, 0 };
    nav.math.vnormalize(&v);
    return @abs(v[0] - 0.6) < 1e-3 and @abs(v[1] - 0.8) < 1e-3;
}

fn runVsub(i: usize) void {
    nav.math.vsub(&d3, &[3]f32{ 5 + @as(f32, @floatFromInt(i & 15)), 7, 9 }, &[3]f32{ 1, 2, 3 });
    dna(d3[0]);
}
fn checkVsub() bool {
    var d: [3]f32 = undefined;
    nav.math.vsub(&d, &[3]f32{ 5, 7, 9 }, &[3]f32{ 1, 2, 3 });
    return @abs(d[0] - 4) < 1e-3 and @abs(d[2] - 6) < 1e-3;
}

fn runVadd(i: usize) void {
    nav.math.vadd(&d3, &[3]f32{ 1 + @as(f32, @floatFromInt(i & 15)), 2, 3 }, &[3]f32{ 4, 5, 6 });
    dna(d3[0]);
}
fn checkVadd() bool {
    var d: [3]f32 = undefined;
    nav.math.vadd(&d, &[3]f32{ 1, 2, 3 }, &[3]f32{ 4, 5, 6 });
    return @abs(d[0] - 5) < 1e-3 and @abs(d[2] - 9) < 1e-3;
}

fn runVscale(i: usize) void {
    nav.math.vscale(&d3, &[3]f32{ 1 + @as(f32, @floatFromInt(i & 15)), 2, 3 }, 2.0);
    dna(d3[1]);
}
fn checkVscale() bool {
    var d: [3]f32 = undefined;
    nav.math.vscale(&d, &[3]f32{ 1, 2, 3 }, 2.0);
    return @abs(d[1] - 4) < 1e-3;
}

fn runVmad(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15)) * 0.0;
    nav.math.vmad(&d3, &[3]f32{ 1, 1, 1 }, &[3]f32{ 1 + f, 0, 0 }, 3.0);
    dna(d3[0]);
}
fn checkVmad() bool {
    var d: [3]f32 = undefined;
    nav.math.vmad(&d, &[3]f32{ 1, 1, 1 }, &[3]f32{ 1, 0, 0 }, 3.0);
    return @abs(d[0] - 4) < 1e-3 and @abs(d[1] - 1) < 1e-3;
}

fn runVcopy(i: usize) void {
    nav.math.vcopy(&d3, &[3]f32{ 1 + @as(f32, @floatFromInt(i & 15)), 2, 3 });
    dna(d3[0]);
}
fn checkVcopy() bool {
    var d: [3]f32 = undefined;
    nav.math.vcopy(&d, &[3]f32{ 7, 8, 9 });
    return d[0] == 7 and d[1] == 8 and d[2] == 9;
}

fn runVequal(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 1));
    dna(nav.math.vequal(&[3]f32{ 1, 2, 3 }, &[3]f32{ 1 + f, 2, 3 }));
}
fn checkVequal() bool {
    return nav.math.vequal(&[3]f32{ 1, 2, 3 }, &[3]f32{ 1, 2, 3 }) and
        !nav.math.vequal(&[3]f32{ 1, 2, 3 }, &[3]f32{ 1, 2, 4 });
}

fn runVmin(i: usize) void {
    _ = i;
    d3 = [3]f32{ 5, 5, 5 };
    nav.math.vmin(&d3, &[3]f32{ 3, 9, 1 });
    dna(d3[0]);
}
fn checkVmin() bool {
    var m = [3]f32{ 5, 5, 5 };
    nav.math.vmin(&m, &[3]f32{ 3, 9, 1 });
    return m[0] == 3 and m[1] == 5 and m[2] == 1;
}

fn runVmax(i: usize) void {
    _ = i;
    d3 = [3]f32{ 5, 5, 5 };
    nav.math.vmax(&d3, &[3]f32{ 3, 9, 1 });
    dna(d3[1]);
}
fn checkVmax() bool {
    var m = [3]f32{ 5, 5, 5 };
    nav.math.vmax(&m, &[3]f32{ 3, 9, 1 });
    return m[0] == 5 and m[1] == 9 and m[2] == 5;
}

fn runVperp2D(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vperp2D(&[3]f32{ 1 + f, 0, 0 }, &[3]f32{ 0, 0, 1 }));
}
fn checkVperp2D() bool {
    return @abs(nav.math.vperp2D(&[3]f32{ 1, 0, 0 }, &[3]f32{ 0, 0, 1 }) - 1.0) < 1e-3;
}

fn runVdist2D(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vdist2D(&[3]f32{ 0, 99, 0 }, &[3]f32{ 3 + f, 99, 4 }));
}
fn checkVdist2D() bool {
    return @abs(nav.math.vdist2D(&[3]f32{ 0, 99, 0 }, &[3]f32{ 3, 99, 4 }) - 5.0) < 1e-3;
}

fn runVdist2DSqr(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    dna(nav.math.vdist2DSqr(&[3]f32{ 0, 99, 0 }, &[3]f32{ 3 + f, 5, 4 }));
}
fn checkVdist2DSqr() bool {
    return @abs(nav.math.vdist2DSqr(&[3]f32{ 0, 99, 0 }, &[3]f32{ 3, 5, 4 }) - 25.0) < 1e-3;
}

fn runDistPtSegSqr2D(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15));
    var t: f32 = 0;
    dna(nav.math.distancePtSegSqr2D(&[3]f32{ 5, 0, 5 + f }, &[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, &t));
}
fn checkDistPtSegSqr2D() bool {
    var t: f32 = 0;
    return @abs(nav.math.distancePtSegSqr2D(&[3]f32{ 5, 0, 5 }, &[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, &t) - 25.0) < 1e-2;
}

fn runNextPow2(i: usize) void {
    dna(nav.math.nextPow2(@as(u32, @intCast(100 + (i & 63)))));
}
fn checkNextPow2() bool {
    return nav.math.nextPow2(100) == 128 and nav.math.nextPow2(64) == 64;
}

fn runIlog2(i: usize) void {
    dna(nav.math.ilog2(@as(u32, @intCast(64 + (i & 63)))));
}
fn checkIlog2() bool {
    return nav.math.ilog2(64) == 6 and nav.math.ilog2(1024) == 10;
}

fn runAlign4(i: usize) void {
    dna(nav.math.align4(@as(i32, @intCast(13 + (i & 7)))));
}
fn checkAlign4() bool {
    return nav.math.align4(13) == 16 and nav.math.align4(8) == 8 and nav.math.align4(0) == 0;
}

var cht_h: f32 = 0;
fn runClosestHeightPointTriangle(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15)) * 0.1;
    dna(nav.math.closestHeightPointTriangle(&[3]f32{ 2 + f, 5, 2 }, &[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, &[3]f32{ 0, 0, 10 }, &cht_h));
}
fn checkClosestHeightPointTriangle() bool {
    var h: f32 = -1;
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 10, 0, 0 };
    const c = [3]f32{ 0, 0, 10 };
    const inside = nav.math.closestHeightPointTriangle(&[3]f32{ 2, 5, 2 }, &a, &b, &c, &h);
    const outside = nav.math.closestHeightPointTriangle(&[3]f32{ 9, 5, 9 }, &a, &b, &c, &h);
    return inside and @abs(h) < 1e-3 and !outside;
}

const sq_poly = [_]Vec3{ Vec3.init(0, 0, 0), Vec3.init(10, 0, 0), Vec3.init(10, 0, 10), Vec3.init(0, 0, 10) };
fn runPointInPolygon(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 7)) * 0.1;
    dna(nav.math.pointInPolygon(Vec3.init(3 + f, 0, 5), &sq_poly));
}
fn checkPointInPolygon() bool {
    return nav.math.pointInPolygon(Vec3.init(5, 0, 5), &sq_poly) and
        !nav.math.pointInPolygon(Vec3.init(15, 0, 5), &sq_poly);
}

fn runOverlapQuantBounds(i: usize) void {
    const f: u16 = @intCast(i & 3);
    dna(nav.math.overlapQuantBounds(&[3]u16{ 0, 0, 0 }, &[3]u16{ 5 + f, 5, 5 }, &[3]u16{ 3, 3, 3 }, &[3]u16{ 8, 8, 8 }));
}
fn checkOverlapQuantBounds() bool {
    const amin = [3]u16{ 0, 0, 0 };
    const amax = [3]u16{ 5, 5, 5 };
    return nav.math.overlapQuantBounds(&amin, &amax, &[3]u16{ 3, 3, 3 }, &[3]u16{ 8, 8, 8 }) and
        !nav.math.overlapQuantBounds(&amin, &amax, &[3]u16{ 10, 10, 10 }, &[3]u16{ 12, 12, 12 });
}

fn runClosestPtPointTriangle(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15)) * 0.1;
    const r = nav.math.closestPtPointTriangle(Vec3.init(2 + f, 5, 2), Vec3.init(0, 0, 0), Vec3.init(10, 0, 0), Vec3.init(0, 0, 10));
    dna(r.x);
}
fn checkClosestPtPointTriangle() bool {
    const r = nav.math.closestPtPointTriangle(Vec3.init(2, 5, 2), Vec3.init(0, 0, 0), Vec3.init(10, 0, 0), Vec3.init(0, 0, 10));
    return @abs(r.x - 2) < 1e-3 and @abs(r.z - 2) < 1e-3; // projects onto the flat triangle
}

var iss_s: f32 = 0;
var iss_t: f32 = 0;
fn runIntersectSegSeg2D(i: usize) void {
    const f = @as(f32, @floatFromInt(i & 15)) * 0.1;
    dna(nav.math.intersectSegSeg2D(&[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, &[3]f32{ 5 + f, 0, -5 }, &[3]f32{ 5 + f, 0, 5 }, &iss_s, &iss_t));
}
fn checkIntersectSegSeg2D() bool {
    var s: f32 = 0;
    var t: f32 = 0;
    return nav.math.intersectSegSeg2D(&[3]f32{ 0, 0, 0 }, &[3]f32{ 10, 0, 0 }, &[3]f32{ 5, 0, -5 }, &[3]f32{ 5, 0, 5 }, &s, &t);
}

const polyA = [_]f32{ 0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 10 };
const polyB_ovl = [_]f32{ 5, 0, 5, 15, 0, 5, 15, 0, 15, 5, 0, 15 };
const polyB_dis = [_]f32{ 20, 0, 20, 30, 0, 20, 30, 0, 30, 20, 0, 30 };
fn runOverlapPolyPoly2D(i: usize) void {
    _ = i;
    dna(nav.math.overlapPolyPoly2D(&polyA, 4, &polyB_ovl, 4));
}
fn checkOverlapPolyPoly2D() bool {
    return nav.math.overlapPolyPoly2D(&polyA, 4, &polyB_ovl, 4) and
        !nav.math.overlapPolyPoly2D(&polyA, 4, &polyB_dis, 4);
}

const pc_idx = [_]u16{ 0, 1, 2, 3 };
var pc_c: [3]f32 = undefined;
fn runCalcPolyCenter(i: usize) void {
    _ = i;
    nav.math.calcPolyCenter(&pc_c, &pc_idx, 4, &polyA);
    dna(pc_c[0]);
}
fn checkCalcPolyCenter() bool {
    var c: [3]f32 = undefined;
    nav.math.calcPolyCenter(&c, &pc_idx, 4, &polyA);
    return @abs(c[0] - 5) < 1e-3 and @abs(c[2] - 5) < 1e-3; // square centroid
}

pub const benches = [_]core.Bench{
    .{ .name = "triArea2D", .module = "math", .isolation = "A", .run = runTriArea2D, .check = checkTriArea2D },
    .{ .name = "closestPtPointTriangle", .module = "math", .isolation = "A", .run = runClosestPtPointTriangle, .check = checkClosestPtPointTriangle },
    .{ .name = "intersectSegSeg2D", .module = "math", .isolation = "A", .run = runIntersectSegSeg2D, .check = checkIntersectSegSeg2D },
    .{ .name = "overlapPolyPoly2D", .module = "math", .isolation = "A", .run = runOverlapPolyPoly2D, .check = checkOverlapPolyPoly2D },
    .{ .name = "calcPolyCenter", .module = "math", .isolation = "A", .run = runCalcPolyCenter, .check = checkCalcPolyCenter },
    .{ .name = "vsub", .module = "math", .isolation = "A", .run = runVsub, .check = checkVsub },
    .{ .name = "vadd", .module = "math", .isolation = "A", .run = runVadd, .check = checkVadd },
    .{ .name = "vscale", .module = "math", .isolation = "A", .run = runVscale, .check = checkVscale },
    .{ .name = "vmad", .module = "math", .isolation = "A", .run = runVmad, .check = checkVmad },
    .{ .name = "vcopy", .module = "math", .isolation = "A", .run = runVcopy, .check = checkVcopy },
    .{ .name = "vequal", .module = "math", .isolation = "A", .run = runVequal, .check = checkVequal },
    .{ .name = "vmin", .module = "math", .isolation = "A", .run = runVmin, .check = checkVmin },
    .{ .name = "vmax", .module = "math", .isolation = "A", .run = runVmax, .check = checkVmax },
    .{ .name = "vlen", .module = "math", .isolation = "A", .run = runVlen, .check = checkVlen },
    .{ .name = "vlenSqr", .module = "math", .isolation = "A", .run = runVlenSqr, .check = checkVlenSqr },
    .{ .name = "vdot", .module = "math", .isolation = "A", .run = runVdot, .check = checkVdot },
    .{ .name = "vcross", .module = "math", .isolation = "A", .run = runVcross, .check = checkVcross },
    .{ .name = "vlerp", .module = "math", .isolation = "A", .run = runVlerp, .check = checkVlerp },
    .{ .name = "vnormalize", .module = "math", .isolation = "A", .run = runVnormalize, .check = checkVnormalize },
    .{ .name = "vperp2D", .module = "math", .isolation = "A", .run = runVperp2D, .check = checkVperp2D },
    .{ .name = "vdist", .module = "math", .isolation = "A", .run = runVdist, .check = checkVdist },
    .{ .name = "vdistSqr", .module = "math", .isolation = "A", .run = runVdistSqr, .check = checkVdistSqr },
    .{ .name = "vdist2D", .module = "math", .isolation = "A", .run = runVdist2D, .check = checkVdist2D },
    .{ .name = "vdist2DSqr", .module = "math", .isolation = "A", .run = runVdist2DSqr, .check = checkVdist2DSqr },
    .{ .name = "distancePtSegSqr2D", .module = "math", .isolation = "A", .run = runDistPtSegSqr2D, .check = checkDistPtSegSqr2D },
    .{ .name = "closestHeightPointTriangle", .module = "math", .isolation = "A", .run = runClosestHeightPointTriangle, .check = checkClosestHeightPointTriangle },
    .{ .name = "pointInPolygon", .module = "math", .isolation = "A", .run = runPointInPolygon, .check = checkPointInPolygon },
    .{ .name = "overlapQuantBounds", .module = "math", .isolation = "A", .run = runOverlapQuantBounds, .check = checkOverlapQuantBounds },
    .{ .name = "nextPow2", .module = "math", .isolation = "A", .run = runNextPow2, .check = checkNextPow2 },
    .{ .name = "ilog2", .module = "math", .isolation = "A", .run = runIlog2, .check = checkIlog2 },
    .{ .name = "align4", .module = "math", .isolation = "A", .run = runAlign4, .check = checkAlign4 },
};
