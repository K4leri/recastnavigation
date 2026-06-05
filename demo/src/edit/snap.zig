//! snap.zig — pure editing-snap logic for cluster F2 (snap к геометрии/сетке).
//!
//! `snapPoint` maps a raw pick/coordinate to a snapped position according to a
//! `SnapConfig`. It is a PURE function: it only reads `*const InputGeom`, does
//! no allocation, and linear-scans the geometry (demo scale — no acceleration
//! structure needed). The returned `SnapResult.kind` reports what actually
//! snapped (`.off` = nothing snapped → `pos` is the raw point).
//!
//! Modes (all candidate distances measured as full 3D distance; `grid` rounds
//! XZ only):
//!   - .off    → identity (raw, .off).
//!   - .vertex → nearest mesh vertex within `radius` (snap full xyz).
//!   - .edge   → nearest point on any triangle edge within `radius`
//!               (closest point on the segment, t clamped to [0,1]).
//!   - .grid   → round X and Z to nearest multiple of `grid_step`, keep raw Y;
//!               always "snaps" (no radius gate).
//!   - .object → nearest convex-volume hull point OR off-mesh endpoint within
//!               `radius` (snap full xyz).

const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;

pub const SnapMode = enum { off, vertex, edge, grid, object };

pub const SnapConfig = struct {
    mode: SnapMode = .off,
    grid_step: f32 = 1.0,
    radius: f32 = 1.0,
};

pub const SnapResult = struct {
    pos: [3]f32,
    /// What actually snapped. `.off` ⇒ no snap (pos == raw).
    kind: SnapMode,
};

/// Snap `raw` according to `cfg`, reading geometry from `geom`. Pure, no alloc.
pub fn snapPoint(geom: *const InputGeom, raw: [3]f32, cfg: SnapConfig) SnapResult {
    return switch (cfg.mode) {
        .off => .{ .pos = raw, .kind = .off },
        .grid => snapGrid(raw, cfg.grid_step),
        .vertex => snapVertex(geom, raw, cfg.radius),
        .edge => snapEdge(geom, raw, cfg.radius),
        .object => snapObject(geom, raw, cfg.radius),
    };
}

fn snapGrid(raw: [3]f32, step: f32) SnapResult {
    // Degenerate / non-positive step ⇒ nothing to round to: leave XZ untouched
    // but still report a grid snap (grid always "snaps").
    if (!(step > 0)) return .{ .pos = raw, .kind = .grid };
    return .{
        .pos = .{ roundTo(raw[0], step), raw[1], roundTo(raw[2], step) },
        .kind = .grid,
    };
}

fn snapVertex(geom: *const InputGeom, raw: [3]f32, radius: f32) SnapResult {
    const v = geom.verts.items;
    const r2 = radius * radius;
    var best2: f32 = r2;
    var best: ?[3]f32 = null;
    var i: usize = 0;
    while (i + 3 <= v.len) : (i += 3) {
        const p = [3]f32{ v[i], v[i + 1], v[i + 2] };
        const d2 = dist3sq(raw, p);
        if (d2 <= best2) {
            best2 = d2;
            best = p;
        }
    }
    if (best) |p| return .{ .pos = p, .kind = .vertex };
    return .{ .pos = raw, .kind = .off };
}

fn snapEdge(geom: *const InputGeom, raw: [3]f32, radius: f32) SnapResult {
    const v = geom.verts.items;
    const tris = geom.tris.items;
    const r2 = radius * radius;
    var best2: f32 = r2;
    var best: ?[3]f32 = null;
    var t: usize = 0;
    while (t + 3 <= tris.len) : (t += 3) {
        const ia: usize = @intCast(tris[t]);
        const ib: usize = @intCast(tris[t + 1]);
        const ic: usize = @intCast(tris[t + 2]);
        const a = [3]f32{ v[ia * 3], v[ia * 3 + 1], v[ia * 3 + 2] };
        const b = [3]f32{ v[ib * 3], v[ib * 3 + 1], v[ib * 3 + 2] };
        const c = [3]f32{ v[ic * 3], v[ic * 3 + 1], v[ic * 3 + 2] };
        considerEdge(raw, a, b, &best2, &best);
        considerEdge(raw, b, c, &best2, &best);
        considerEdge(raw, c, a, &best2, &best);
    }
    if (best) |p| return .{ .pos = p, .kind = .edge };
    return .{ .pos = raw, .kind = .off };
}

fn considerEdge(raw: [3]f32, a: [3]f32, b: [3]f32, best2: *f32, best: *?[3]f32) void {
    const cp = closestPointOnSegment(raw, a, b);
    const d2 = dist3sq(raw, cp);
    if (d2 <= best2.*) {
        best2.* = d2;
        best.* = cp;
    }
}

fn snapObject(geom: *const InputGeom, raw: [3]f32, radius: f32) SnapResult {
    const r2 = radius * radius;
    var best2: f32 = r2;
    var best: ?[3]f32 = null;

    // Convex-volume hull points.
    for (geom.volumes.items) |*vol| {
        const n: usize = @intCast(vol.nverts);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = [3]f32{ vol.verts[i * 3], vol.verts[i * 3 + 1], vol.verts[i * 3 + 2] };
            const d2 = dist3sq(raw, p);
            if (d2 <= best2) {
                best2 = d2;
                best = p;
            }
        }
    }

    // Off-mesh endpoints (start xyz + end xyz, 6 floats per connection).
    const ov = geom.off_verts.items;
    var k: usize = 0;
    while (k + 6 <= ov.len) : (k += 6) {
        const s = [3]f32{ ov[k], ov[k + 1], ov[k + 2] };
        const e = [3]f32{ ov[k + 3], ov[k + 4], ov[k + 5] };
        inline for (.{ s, e }) |p| {
            const d2 = dist3sq(raw, p);
            if (d2 <= best2) {
                best2 = d2;
                best = p;
            }
        }
    }

    if (best) |p| return .{ .pos = p, .kind = .object };
    return .{ .pos = raw, .kind = .off };
}

// --- private helpers ---

inline fn roundTo(x: f32, step: f32) f32 {
    return @round(x / step) * step;
}

inline fn dist3sq(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

inline fn dist3(a: [3]f32, b: [3]f32) f32 {
    return @sqrt(dist3sq(a, b));
}

/// Closest point on segment [a,b] to point p, with the parameter t clamped to
/// [0,1] (so the result is always ON the segment, including the endpoints for a
/// degenerate a==b segment).
fn closestPointOnSegment(p: [3]f32, a: [3]f32, b: [3]f32) [3]f32 {
    const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const ap = [3]f32{ p[0] - a[0], p[1] - a[1], p[2] - a[2] };
    const ab_len2 = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
    if (!(ab_len2 > 0)) return a; // degenerate segment ⇒ the point itself
    var t = (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / ab_len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return .{ a[0] + ab[0] * t, a[1] + ab[1] * t, a[2] + ab[2] * t };
}

// ===================================================================== tests

const std = @import("std");
const testing = std.testing;

/// Build a small mesh: a unit square on y=0 split into 2 tris, with verts at
/// (0,0,0),(2,0,0),(2,0,2),(0,0,2).
fn buildGeom(alloc: std.mem.Allocator) !InputGeom {
    var geom = InputGeom.init(alloc);
    try geom.verts.appendSlice(&.{
        0, 0, 0,
        2, 0, 0,
        2, 0, 2,
        0, 0, 2,
    });
    // two triangles: (0,1,2) and (0,2,3)
    try geom.tris.appendSlice(&.{ 0, 1, 2, 0, 2, 3 });
    return geom;
}

test "off mode returns raw unchanged" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    const raw = [3]f32{ 0.37, 1.23, -4.0 };
    const r = snapPoint(&geom, raw, .{ .mode = .off });
    try testing.expectEqual(SnapMode.off, r.kind);
    try testing.expectEqual(raw[0], r.pos[0]);
    try testing.expectEqual(raw[1], r.pos[1]);
    try testing.expectEqual(raw[2], r.pos[2]);
}

test "vertex snap picks nearest vertex within radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    // raw near vertex (2,0,2)
    const raw = [3]f32{ 1.9, 0.1, 2.05 };
    const r = snapPoint(&geom, raw, .{ .mode = .vertex, .radius = 1.0 });
    try testing.expectEqual(SnapMode.vertex, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 2.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.pos[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), r.pos[2], 1e-6);
}

test "vertex snap returns raw when outside radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    // raw at center (1,0,1): nearest vertex distance = sqrt(2) ≈ 1.414 > 0.5
    const raw = [3]f32{ 1.0, 0.0, 1.0 };
    const r = snapPoint(&geom, raw, .{ .mode = .vertex, .radius = 0.5 });
    try testing.expectEqual(SnapMode.off, r.kind);
    try testing.expectEqual(raw[0], r.pos[0]);
    try testing.expectEqual(raw[2], r.pos[2]);
}

test "grid snap rounds XZ and preserves Y" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    const raw = [3]f32{ 1.2, 3.7, -0.6 };
    const r = snapPoint(&geom, raw, .{ .mode = .grid, .grid_step = 0.5 });
    try testing.expectEqual(SnapMode.grid, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.pos[0], 1e-6); // 1.2 → 1.0
    try testing.expectApproxEqAbs(@as(f32, 3.7), r.pos[1], 1e-6); // Y kept
    try testing.expectApproxEqAbs(@as(f32, -0.5), r.pos[2], 1e-6); // -0.6 → -0.5
}

test "grid snap with integer step" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    const raw = [3]f32{ 2.4, 9.0, 2.6 };
    const r = snapPoint(&geom, raw, .{ .mode = .grid, .grid_step = 1.0 });
    try testing.expectEqual(SnapMode.grid, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 2.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0), r.pos[2], 1e-6);
}

test "edge snap returns closest point on expected edge" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    // raw just above the edge from (0,0,0)→(2,0,0): closest point is (1.0,0,0).
    const raw = [3]f32{ 1.0, 0.0, 0.2 };
    const r = snapPoint(&geom, raw, .{ .mode = .edge, .radius = 1.0 });
    try testing.expectEqual(SnapMode.edge, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.pos[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.pos[2], 1e-6);
    // result must lie ON the segment (z==0 here) and within radius.
    try testing.expect(dist3(raw, r.pos) <= 1.0);
}

test "edge snap clamps t to endpoint" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    // raw beyond vertex (0,0,0) along -x: closest point on edge (0,0,0)->(2,0,0)
    // is the endpoint (0,0,0) (t clamped to 0).
    const raw = [3]f32{ -0.3, 0.0, 0.0 };
    const r = snapPoint(&geom, raw, .{ .mode = .edge, .radius = 1.0 });
    try testing.expectEqual(SnapMode.edge, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.pos[2], 1e-6);
}

test "edge snap returns raw when outside radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    const raw = [3]f32{ 1.0, 5.0, 1.0 }; // far above the plane
    const r = snapPoint(&geom, raw, .{ .mode = .edge, .radius = 0.5 });
    try testing.expectEqual(SnapMode.off, r.kind);
    try testing.expectEqual(raw[1], r.pos[1]);
}

test "object snap picks convex-volume hull point within radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    // a triangular volume with a hull vertex at (5,0,5)
    const vol = [_]f32{ 5, 0, 5, 6, 0, 5, 5, 0, 6 };
    try geom.addConvexVolume(&vol, 3, 0.0, 1.0, 0);
    const raw = [3]f32{ 5.1, 0.0, 4.95 };
    const r = snapPoint(&geom, raw, .{ .mode = .object, .radius = 0.5 });
    try testing.expectEqual(SnapMode.object, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 5.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5.0), r.pos[2], 1e-6);
}

test "object snap picks off-mesh endpoint within radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    try geom.addOffMeshConnection(.{ 10, 1, 10 }, .{ 12, 1, 12 }, 0.6, 1, 0, 0);
    // near the END endpoint (12,1,12)
    const raw = [3]f32{ 11.9, 1.0, 12.1 };
    const r = snapPoint(&geom, raw, .{ .mode = .object, .radius = 0.5 });
    try testing.expectEqual(SnapMode.object, r.kind);
    try testing.expectApproxEqAbs(@as(f32, 12.0), r.pos[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.pos[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 12.0), r.pos[2], 1e-6);
}

test "object snap returns raw when nothing in radius" {
    var geom = try buildGeom(testing.allocator);
    defer geom.deinit();
    try geom.addOffMeshConnection(.{ 10, 1, 10 }, .{ 12, 1, 12 }, 0.6, 1, 0, 0);
    const raw = [3]f32{ 0, 0, 0 };
    const r = snapPoint(&geom, raw, .{ .mode = .object, .radius = 1.0 });
    try testing.expectEqual(SnapMode.off, r.kind);
    try testing.expectEqual(raw[0], r.pos[0]);
}
