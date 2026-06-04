//! Surface-conforming convex-volume marking (demo-level; foundation of the
//! "surface" volume mode). Fits a least-squares plane through the contour
//! vertices and, per (x,z) column inside the contour, marks the walkable spans
//! that hug the LOCAL surface (nearest span to the plane, ± band). This keeps the
//! marked area attached to the relief and off neighbouring floors. The faithful
//! core `rcMarkConvexPolyArea` is NOT touched.

const std = @import("std");
const recast = @import("recast-nav");

pub const Plane = struct {
    a: f32 = 0,
    b: f32 = 0,
    c: f32 = 0,
    pub fn at(self: Plane, x: f32, z: f32) f32 {
        return self.a * x + self.b * z + self.c;
    }
};

/// Least-squares plane y = a*x + b*z + c through the contour vertices
/// (verts laid out x,y,z,...). Degenerate (collinear in XZ) -> horizontal at mean Y.
pub fn fitPlane(verts: []const f32, nverts: usize) Plane {
    var sx: f64 = 0;
    var sz: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxz: f64 = 0;
    var szz: f64 = 0;
    var sxy: f64 = 0;
    var szy: f64 = 0;
    const n: f64 = @floatFromInt(nverts);
    for (0..nverts) |i| {
        const x: f64 = verts[i * 3 + 0];
        const y: f64 = verts[i * 3 + 1];
        const z: f64 = verts[i * 3 + 2];
        sx += x;
        sz += z;
        sy += y;
        sxx += x * x;
        sxz += x * z;
        szz += z * z;
        sxy += x * y;
        szy += z * y;
    }
    // Normal equations M*[a,b,c] = R, M = [[sxx,sxz,sx],[sxz,szz,sz],[sx,sz,n]],
    // R = [sxy,szy,sy]. Solved by Cramer's rule.
    const det = sxx * (szz * n - sz * sz) - sxz * (sxz * n - sz * sx) + sx * (sxz * sz - szz * sx);
    if (@abs(det) < 1e-6) {
        return .{ .a = 0, .b = 0, .c = @floatCast(sy / n) };
    }
    const da = sxy * (szz * n - sz * sz) - sxz * (szy * n - sz * sy) + sx * (szy * sz - szz * sy);
    const db = sxx * (szy * n - sz * sy) - sxy * (sxz * n - sz * sx) + sx * (sxz * sy - szy * sx);
    const dc = sxx * (szz * sy - szy * sz) - sxz * (sxz * sy - szy * sx) + sxy * (sxz * sz - szz * sx);
    return .{ .a = @floatCast(da / det), .b = @floatCast(db / det), .c = @floatCast(dc / det) };
}

/// Ray-cast point-in-polygon in the XZ plane (mirror of recast rcPointInPoly).
pub fn pointInPoly(nverts: usize, verts: []const f32, px: f32, pz: f32) bool {
    var c = false;
    var i: usize = 0;
    var j: usize = nverts - 1;
    while (i < nverts) : (i += 1) {
        const vix = verts[i * 3 + 0];
        const viz = verts[i * 3 + 2];
        const vjx = verts[j * 3 + 0];
        const vjz = verts[j * 3 + 2];
        if (((viz > pz) != (vjz > pz)) and
            (px < (vjx - vix) * (pz - viz) / (vjz - viz) + vix))
        {
            c = !c;
        }
        j = i;
    }
    return c;
}

const CompactHeightfield = recast.CompactHeightfield;
// CompactCell/CompactSpan are not re-exported at the recast-nav root; reach them
// through the `recast` sub-namespace (src/recast.zig).
const CompactCell = recast.recast.CompactCell;
const CompactSpan = recast.recast.CompactSpan;
const NULL_AREA = recast.recast.AreaId.NULL_AREA;
const WALKABLE_AREA = recast.recast.AreaId.WALKABLE_AREA;

/// Mark `area` on the compact heightfield within the XZ contour, hugging the
/// local surface: per column, anchor on the walkable span nearest the fitted
/// plane, then mark spans within [anchor - band_below, anchor + band_above].
/// Columns whose nearest span is farther than (band_below+band_above+ch) from
/// the plane are skipped (gap / other floor). Writes only `chf.areas`.
pub fn markConvexPolyAreaSurface(
    verts: []const f32,
    nverts: usize,
    band_below: f32,
    band_above: f32,
    area: u8,
    chf: *CompactHeightfield,
) void {
    if (nverts < 3) return;
    const plane = fitPlane(verts, nverts);
    const bminx = chf.bmin.x;
    const bminy = chf.bmin.y;
    const bminz = chf.bmin.z;
    const snap_max = band_below + band_above + chf.ch;

    var minx_f = verts[0];
    var maxx_f = verts[0];
    var minz_f = verts[2];
    var maxz_f = verts[2];
    for (1..nverts) |i| {
        minx_f = @min(minx_f, verts[i * 3 + 0]);
        maxx_f = @max(maxx_f, verts[i * 3 + 0]);
        minz_f = @min(minz_f, verts[i * 3 + 2]);
        maxz_f = @max(maxz_f, verts[i * 3 + 2]);
    }
    const inv_cs = 1.0 / chf.cs;
    var minx: i32 = @intFromFloat((minx_f - bminx) * inv_cs);
    var maxx: i32 = @intFromFloat((maxx_f - bminx) * inv_cs);
    var minz: i32 = @intFromFloat((minz_f - bminz) * inv_cs);
    var maxz: i32 = @intFromFloat((maxz_f - bminz) * inv_cs);
    minx = @max(minx, 0);
    maxx = @min(maxx, chf.width - 1);
    minz = @max(minz, 0);
    maxz = @min(maxz, chf.height - 1);
    if (maxx < minx or maxz < minz) return;

    var z: i32 = minz;
    while (z <= maxz) : (z += 1) {
        var x: i32 = minx;
        while (x <= maxx) : (x += 1) {
            const wx = bminx + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs;
            const wz = bminz + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs;
            if (!pointInPoly(nverts, verts, wx, wz)) continue;
            const expected = plane.at(wx, wz);

            const cell = chf.cells[@intCast(x + z * chf.width)];
            const start: usize = cell.index;
            const end: usize = start + cell.count;

            var best: ?usize = null;
            var best_d: f32 = std.math.floatMax(f32);
            var i: usize = start;
            while (i < end) : (i += 1) {
                if (chf.areas[i] == NULL_AREA) continue;
                const sy = bminy + @as(f32, @floatFromInt(chf.spans[i].y)) * chf.ch;
                const d = @abs(sy - expected);
                if (d < best_d) {
                    best_d = d;
                    best = i;
                }
            }
            if (best) |bi| {
                if (best_d > snap_max) continue;
                const anchor = bminy + @as(f32, @floatFromInt(chf.spans[bi].y)) * chf.ch;
                const lo = anchor - band_below;
                const hi = anchor + band_above;
                var k: usize = start;
                while (k < end) : (k += 1) {
                    if (chf.areas[k] == NULL_AREA) continue;
                    const sy = bminy + @as(f32, @floatFromInt(chf.spans[k].y)) * chf.ch;
                    if (sy >= lo and sy <= hi) chf.areas[k] = area;
                }
            }
        }
    }
}

test "fitPlane recovers a known sloped plane" {
    // y = 0.5*x + 0.25*z + 2  at 4 corners
    const v = [_]f32{
        0, 2.0, 0,
        4, 4.0, 0, // 0.5*4 + 2 = 4
        4, 5.0, 4, // 0.5*4 + 0.25*4 + 2 = 5
        0, 3.0, 4, // 0.25*4 + 2 = 3
    };
    const p = fitPlane(&v, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.a, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), p.b, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), p.c, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), p.at(4, 4), 1e-3);
}

test "fitPlane degenerate (collinear in XZ) -> horizontal at mean" {
    // all points on the line x=z, varied Y -> XZ-collinear -> fallback mean
    const v = [_]f32{ 0, 1, 0, 1, 3, 1, 2, 5, 2 };
    const p = fitPlane(&v, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.a, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.b, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), p.c, 1e-3); // mean(1,3,5)
}

test "pointInPoly square" {
    const sq = [_]f32{ 0, 0, 0, 4, 0, 0, 4, 0, 4, 0, 0, 4 };
    try std.testing.expect(pointInPoly(4, &sq, 2, 2));
    try std.testing.expect(!pointInPoly(4, &sq, 5, 2));
    try std.testing.expect(!pointInPoly(4, &sq, -1, 2));
}

test "markSurface marks the surface floor, not the upper floor" {
    const alloc = std.testing.allocator;
    // 3x1 grid (width=3, height=1), cs=1, ch=1, origin 0.
    // Columns 0 and 1: surface span at y=0 (WALKABLE_AREA) + upper-floor span at y=10 (WALKABLE_AREA).
    // Column 2:        one NULL_AREA span at y=0 — at surface height but unwalkable.
    // Plane fit on the contour verts ~ y=0.
    // After marking with area=7:
    //   col0/col1 y=0 -> 7  (surface, walkable, within band)
    //   col0/col1 y=10 -> WALKABLE_AREA (63, too far from plane, snap_max cull)
    //   col2 y=0 -> 0  (NULL_AREA, skipped in both anchor-selection and marking loops)
    //
    // Layout: cells[x + z*width], spans packed: col0=[0..1], col1=[2..3], col2=[4]
    const cells = try alloc.alloc(CompactCell, 3);
    defer alloc.free(cells);
    const spans = try alloc.alloc(CompactSpan, 5);
    defer alloc.free(spans);
    const areas = try alloc.alloc(u8, 5);
    defer alloc.free(areas);

    // Columns 0 and 1: walkable surface + walkable upper floor
    cells[0] = .{ .index = 0, .count = 2 };
    spans[0] = .{ .y = 0, .reg = 0, .con = 0 };  areas[0] = WALKABLE_AREA; // col0 surface
    spans[1] = .{ .y = 10, .reg = 0, .con = 0 }; areas[1] = WALKABLE_AREA; // col0 upper
    cells[1] = .{ .index = 2, .count = 2 };
    spans[2] = .{ .y = 0, .reg = 0, .con = 0 };  areas[2] = WALKABLE_AREA; // col1 surface
    spans[3] = .{ .y = 10, .reg = 0, .con = 0 }; areas[3] = WALKABLE_AREA; // col1 upper
    // Column 2: single NULL_AREA span at surface height — must NOT be selected as anchor
    // and must NOT be marked (NULL_AREA skip in both loops).
    cells[2] = .{ .index = 4, .count = 1 };
    spans[4] = .{ .y = 0, .reg = 0, .con = 0 };  areas[4] = NULL_AREA;     // col2 null

    var chf: recast.CompactHeightfield = undefined;
    chf.width = 3;
    chf.height = 1;
    chf.bmin = .{ .x = 0, .y = 0, .z = 0 };
    chf.cs = 1;
    chf.ch = 1;
    chf.cells = cells;
    chf.spans = spans;
    chf.areas = areas;

    // Contour covering the whole 3x1 at surface height (y=0), area = 7.
    // snap_max = band_below + band_above + ch = 0.5 + 0.5 + 1.0 = 2.0 < 10 -> upper floor culled.
    const v = [_]f32{ 0, 0, 0, 3, 0, 0, 3, 0, 1, 0, 0, 1 };
    markConvexPolyAreaSurface(&v, 4, 0.5, 0.5, 7, &chf);

    // Walkable surface spans get marked with area 7.
    try std.testing.expectEqual(@as(u8, 7), areas[0]);  // col0 surface: marked
    try std.testing.expectEqual(@as(u8, 7), areas[2]);  // col1 surface: marked
    // Upper-floor spans stay WALKABLE_AREA (snap_max cull: distance 10 > 2.0).
    try std.testing.expectEqual(WALKABLE_AREA, areas[1]); // col0 upper: not marked
    try std.testing.expectEqual(WALKABLE_AREA, areas[3]); // col1 upper: not marked
    // NULL_AREA span stays 0 — skipped in anchor selection AND marking loop.
    try std.testing.expectEqual(NULL_AREA, areas[4]);   // col2 null: skipped, stays 0
}
