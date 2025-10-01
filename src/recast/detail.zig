// Detail mesh generation for Recast
const std = @import("std");
const config = @import("config.zig");
const context_mod = @import("../context.zig");
const heightfield = @import("heightfield.zig");
const polymesh = @import("polymesh.zig");

const Context = context_mod.Context;
const CompactHeightfield = heightfield.CompactHeightfield;
const CompactSpan = heightfield.CompactSpan;
const CompactCell = heightfield.CompactCell;
const PolyMesh = polymesh.PolyMesh;
const PolyMeshDetail = polymesh.PolyMeshDetail;

const RC_UNSET_HEIGHT = config.SPAN_MAX_HEIGHT;
const RC_MULTIPLE_REGS = config.MULTIPLE_REGS;
const RC_MESH_NULL_IDX = config.MESH_NULL_IDX;
const NOT_CONNECTED = config.NOT_CONNECTED;

// Constants for detail mesh generation
const MAX_VERTS = 127;
const MAX_TRIS = 255;
const MAX_VERTS_PER_EDGE = 32;
const EV_UNDEF = -1;
const EV_HULL = -2;
const DETAIL_EDGE_BOUNDARY = 0x1;
const RETRACT_SIZE = 256;

/// Height patch for storing height data
pub const HeightPatch = struct {
    data: []u16,
    xmin: i32,
    ymin: i32,
    width: i32,
    height: i32,
};

// ============================================================================
// Vector math helpers
// ============================================================================

inline fn vdot2(a: [*]const f32, b: [*]const f32) f32 {
    return a[0] * b[0] + a[2] * b[2];
}

inline fn vdistSq2(p: [*]const f32, q: [*]const f32) f32 {
    const dx = q[0] - p[0];
    const dz = q[2] - p[2];
    return dx * dx + dz * dz;
}

inline fn vdist2(p: [*]const f32, q: [*]const f32) f32 {
    return @sqrt(vdistSq2(p, q));
}

inline fn vcross2(p1: [*]const f32, p2: [*]const f32, p3: [*]const f32) f32 {
    const uu1 = p2[0] - p1[0];
    const vv1 = p2[2] - p1[2];
    const uu2 = p3[0] - p1[0];
    const vv2 = p3[2] - p1[2];
    return uu1 * vv2 - vv1 * uu2;
}

// ============================================================================
// Geometry helpers
// ============================================================================

/// Computes circumcircle of a triangle
fn circumCircle(
    p1: [*]const f32,
    p2: [*]const f32,
    p3: [*]const f32,
    c: [*]f32,
    r: *f32,
) void {
    const EPS = 1e-6;

    const v1 = [3]f32{ p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2] };
    const v2 = [3]f32{ p3[0] - p1[0], p3[1] - p1[1], p3[2] - p1[2] };

    const dot11 = v1[0] * v1[0] + v1[2] * v1[2];
    const dot22 = v2[0] * v2[0] + v2[2] * v2[2];

    const d = 2 * (v1[0] * v2[2] - v1[2] * v2[0]);
    if (@abs(d) < EPS) {
        r.* = -1;
        return;
    }

    const inv_d = 1.0 / d;
    const uu = (v2[2] * dot11 - v1[2] * dot22) * inv_d;
    const vv = (v1[0] * dot22 - v2[0] * dot11) * inv_d;

    c[0] = p1[0] + uu;
    c[1] = p1[1];
    c[2] = p1[2] + vv;
    r.* = @sqrt(uu * uu + vv * vv);
}

/// Distance from point to triangle with barycentric coordinates
fn distPtTri(p: [*]const f32, a: [*]const f32, b: [*]const f32, c: [*]const f32) f32 {
    const v0 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const v1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v2 = [3]f32{ p[0] - a[0], p[1] - a[1], p[2] - a[2] };

    const dot00 = v0[0] * v0[0] + v0[2] * v0[2];
    const dot01 = v0[0] * v1[0] + v0[2] * v1[2];
    const dot02 = v0[0] * v2[0] + v0[2] * v2[2];
    const dot11 = v1[0] * v1[0] + v1[2] * v1[2];
    const dot12 = v1[0] * v2[0] + v1[2] * v2[2];

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

/// Distance from point to line segment
fn distancePtSeg(x: f32, z: f32, px: f32, pz: f32, qx: f32, qz: f32) f32 {
    const pqx = qx - px;
    const pqz = qz - pz;
    const dx = x - px;
    const dz = z - pz;
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d > 0) t /= d;
    if (t < 0) t = 0 else if (t > 1) t = 1;

    const dx_final = px + t * pqx - x;
    const dz_final = pz + t * pqz - z;
    return dx_final * dx_final + dz_final * dz_final;
}

/// Distance from point to line segment (2D version with arrays)
fn distancePtSeg2d(pt: [*]const f32, p: [*]const f32, q: [*]const f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    const dx = pt[0] - p[0];
    const dz = pt[2] - p[2];
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    const dx_final = p[0] + t * pqx - pt[0];
    const dz_final = p[2] + t * pqz - pt[2];
    return dx_final * dx_final + dz_final * dz_final;
}

/// Distance to triangle mesh
fn distToTriMesh(
    p: [*]const f32,
    verts: [*]const f32,
    _: i32,
    tris: [*]const i32,
    ntris: i32,
) f32 {
    var dmin = std.math.floatMax(f32);
    var i: i32 = 0;
    while (i < ntris) : (i += 1) {
        const va = verts + @as(usize, @intCast(tris[@as(usize, @intCast(i * 4 + 0))])) * 3;
        const vb = verts + @as(usize, @intCast(tris[@as(usize, @intCast(i * 4 + 1))])) * 3;
        const vc = verts + @as(usize, @intCast(tris[@as(usize, @intCast(i * 4 + 2))])) * 3;
        const d = distPtTri(p, va, vb, vc);
        if (d < dmin) dmin = d;
    }
    if (dmin == std.math.floatMax(f32)) return -1;
    return dmin;
}

/// Distance to polygon boundary
fn distToPoly(nin: i32, inv: [*]const f32, p: [*]const f32) f32 {
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
            (p[0] < (vj[0] - vi[0]) * (p[2] - vi[2]) / (vj[2] - vi[2]) + vi[0]))
        {
            c = !c;
        }
        dmin = @min(dmin, distancePtSeg2d(p, vj, vi));
    }
    return if (c) -dmin else dmin;
}

/// Calculate minimum extent of polygon
fn polyMinExtent(verts: [*]const f32, nverts: i32) f32 {
    var minDist = std.math.floatMax(f32);
    var i: i32 = 0;
    while (i < nverts) : (i += 1) {
        const ni = @rem(i + 1, nverts);
        const p1 = verts + @as(usize, @intCast(i)) * 3;
        const p2 = verts + @as(usize, @intCast(ni)) * 3;
        var j: i32 = 0;
        while (j < nverts) : (j += 1) {
            if (j == i or j == ni) continue;
            const p3 = verts + @as(usize, @intCast(j)) * 3;
            const d = distancePtSeg2d(p3, p1, p2);
            minDist = @min(minDist, d);
        }
    }
    return @sqrt(minDist);
}

// ============================================================================
// Jitter functions for sample placement
// ============================================================================

inline fn getJitterX(i: i32) f32 {
    const i_u: u32 = @bitCast(i);
    const val = (i_u *% 0x8da6b343) & 0xffff;
    return (@as(f32, @floatFromInt(val)) / 65535.0 * 2.0) - 1.0;
}

inline fn getJitterY(i: i32) f32 {
    const i_u: u32 = @bitCast(i);
    const val = (i_u *% 0xd8163841) & 0xffff;
    return (@as(f32, @floatFromInt(val)) / 65535.0 * 2.0) - 1.0;
}

// ============================================================================
// Height sampling
// ============================================================================

/// Get direction offset for X coordinate
inline fn getDirOffsetX(dir: i32) i32 {
    const offset = [_]i32{ -1, 0, 1, 0 };
    return offset[@as(usize, @intCast(dir & 0x03))];
}

/// Get direction offset for Y coordinate
inline fn getDirOffsetY(dir: i32) i32 {
    const offset = [_]i32{ 0, 1, 0, -1 };
    return offset[@as(usize, @intCast(dir & 0x03))];
}

/// Get connection value from compact span
inline fn getCon(s: *const CompactSpan, dir: i32) u8 {
    const shift: u5 = @intCast((dir & 0x3) * 6);
    return @truncate((s.con >> shift) & 0x3f);
}

/// Sample height from heightfield with spiral search
fn getHeight(
    fx: f32,
    _: f32,
    fz: f32,
    cs: f32,
    ics: f32,
    _: f32,
    radius: i32,
    hp: *const HeightPatch,
) u16 {
    const ix = @as(i32, @intFromFloat(@floor(fx * ics + 0.01)));
    const iz = @as(i32, @intFromFloat(@floor(fz * ics + 0.01)));
    const x = std.math.clamp(ix - hp.xmin, 0, hp.width - 1);
    const z = std.math.clamp(iz - hp.ymin, 0, hp.height - 1);
    var h = hp.data[@as(usize, @intCast(x + z * hp.width))];
    if (h != RC_UNSET_HEIGHT) {
        return h;
    }

    // Spiral search
    const offx = [_]i32{ 0, -1, -1, -1, 0, 1, 1, 1 };
    const offy = [_]i32{ -1, -1, 0, 1, 1, 1, 0, -1 };

    var dmin = std.math.floatMax(f32);
    var r: i32 = 1;
    while (r <= radius) : (r += 1) {
        var dir: usize = 0;
        while (dir < 8) : (dir += 1) {
            const nx = x + offx[dir] * r;
            const nz = z + offy[dir] * r;
            if (nx >= 0 and nx < hp.width and nz >= 0 and nz < hp.height) {
                const nh = hp.data[@as(usize, @intCast(nx + nz * hp.width))];
                if (nh != RC_UNSET_HEIGHT) {
                    const d = @abs(@as(f32, @floatFromInt(nx)) * cs + @as(f32, @floatFromInt(hp.xmin)) * cs - fx) +
                        @abs(@as(f32, @floatFromInt(nz)) * cs + @as(f32, @floatFromInt(hp.ymin)) * cs - fz);
                    if (d < dmin) {
                        h = nh;
                        dmin = d;
                    }
                }
            }
        }
    }
    return h;
}

// ============================================================================
// Delaunay triangulation
// ============================================================================

/// Find edge in edge list
fn findEdge(edges: []const i32, nedges: i32, s: i32, t: i32) i32 {
    var i: i32 = 0;
    while (i < nedges) : (i += 1) {
        const e = edges[@as(usize, @intCast(i * 4))..];
        if ((e[0] == s and e[1] == t) or (e[0] == t and e[1] == s)) {
            return i;
        }
    }
    return EV_UNDEF;
}

/// Add edge to edge list
fn addEdge(
    ctx: *const Context,
    edges: []i32,
    nedges: *i32,
    max_edges: i32,
    s: i32,
    t: i32,
    l: i32,
    r: i32,
) i32 {
    if (nedges.* >= max_edges) {
        ctx.log(.err, "addEdge: Too many edges ({d}/{d}).", .{ nedges.*, max_edges });
        return EV_UNDEF;
    }

    const e = findEdge(edges, nedges.*, s, t);
    if (e == EV_UNDEF) {
        const idx = @as(usize, @intCast(nedges.* * 4));
        edges[idx + 0] = s;
        edges[idx + 1] = t;
        edges[idx + 2] = l;
        edges[idx + 3] = r;
        const result = nedges.*;
        nedges.* += 1;
        return result;
    }
    return EV_UNDEF;
}

/// Update left face of edge
fn updateLeftFace(e: []i32, s: i32, t: i32, f: i32) void {
    if (e[0] == s and e[1] == t and e[2] == EV_UNDEF) {
        e[2] = f;
    } else if (e[1] == s and e[0] == t and e[3] == EV_UNDEF) {
        e[3] = f;
    }
}

/// Check if two 2D segments overlap
fn overlapSegSeg2d(a: [*]const f32, b: [*]const f32, c: [*]const f32, d: [*]const f32) bool {
    const a1 = vcross2(a, b, d);
    const a2 = vcross2(a, b, c);
    if (a1 * a2 < 0.0) {
        const a3 = vcross2(c, d, a);
        const a4 = a3 + a2 - a1;
        if (a3 * a4 < 0.0) {
            return true;
        }
    }
    return false;
}

/// Check if edge overlaps with any existing edges
fn overlapEdges(pts: [*]const f32, edges: []const i32, nedges: i32, s1: i32, t1: i32) bool {
    var i: i32 = 0;
    while (i < nedges) : (i += 1) {
        const idx = @as(usize, @intCast(i * 4));
        const s0 = edges[idx + 0];
        const t0 = edges[idx + 1];
        if (s0 == s1 or s0 == t1 or t0 == s1 or t0 == t1) continue;

        const s0_idx = @as(usize, @intCast(s0 * 3));
        const t0_idx = @as(usize, @intCast(t0 * 3));
        const s1_idx = @as(usize, @intCast(s1 * 3));
        const t1_idx = @as(usize, @intCast(t1 * 3));

        if (overlapSegSeg2d(pts + s0_idx, pts + t0_idx, pts + s1_idx, pts + t1_idx)) {
            return true;
        }
    }
    return false;
}

/// Complete a facet in Delaunay triangulation
fn completeFacet(
    ctx: *const Context,
    pts: [*]const f32,
    npts: i32,
    edges: []i32,
    nedges: *i32,
    max_edges: i32,
    nfaces: *i32,
    e: i32,
) void {
    const EPS = 1e-5;
    const edge_idx = @as(usize, @intCast(e * 4));
    const edge = edges[edge_idx .. edge_idx + 4];

    var s: i32 = undefined;
    var t: i32 = undefined;

    if (edge[2] == EV_UNDEF) {
        s = edge[0];
        t = edge[1];
    } else if (edge[3] == EV_UNDEF) {
        s = edge[1];
        t = edge[0];
    } else {
        return;
    }

    var pt = npts;
    var c: [3]f32 = .{ 0, 0, 0 };
    var r: f32 = -1;

    var u: i32 = 0;
    while (u < npts) : (u += 1) {
        if (u == s or u == t) continue;

        const s_idx = @as(usize, @intCast(s * 3));
        const t_idx = @as(usize, @intCast(t * 3));
        const u_idx = @as(usize, @intCast(u * 3));

        if (vcross2(pts + s_idx, pts + t_idx, pts + u_idx) > EPS) {
            if (r < 0) {
                pt = u;
                circumCircle(pts + s_idx, pts + t_idx, pts + u_idx, &c, &r);
                continue;
            }

            const d = vdist2(&c, pts + u_idx);
            const tol = 0.001;
            if (d > r * (1.0 + tol)) {
                continue;
            } else if (d < r * (1.0 - tol)) {
                pt = u;
                circumCircle(pts + s_idx, pts + t_idx, pts + u_idx, &c, &r);
            } else {
                if (overlapEdges(pts, edges, nedges.*, s, u)) continue;
                if (overlapEdges(pts, edges, nedges.*, t, u)) continue;
                pt = u;
                circumCircle(pts + s_idx, pts + t_idx, pts + u_idx, &c, &r);
            }
        }
    }

    if (pt < npts) {
        updateLeftFace(edges[edge_idx .. edge_idx + 4], s, t, nfaces.*);

        var e2 = findEdge(edges, nedges.*, pt, s);
        if (e2 == EV_UNDEF) {
            _ = addEdge(ctx, edges, nedges, max_edges, pt, s, nfaces.*, EV_UNDEF);
        } else {
            const e2_idx = @as(usize, @intCast(e2 * 4));
            updateLeftFace(edges[e2_idx .. e2_idx + 4], pt, s, nfaces.*);
        }

        e2 = findEdge(edges, nedges.*, t, pt);
        if (e2 == EV_UNDEF) {
            _ = addEdge(ctx, edges, nedges, max_edges, t, pt, nfaces.*, EV_UNDEF);
        } else {
            const e2_idx = @as(usize, @intCast(e2 * 4));
            updateLeftFace(edges[e2_idx .. e2_idx + 4], t, pt, nfaces.*);
        }

        nfaces.* += 1;
    } else {
        updateLeftFace(edges[edge_idx .. edge_idx + 4], s, t, EV_HULL);
    }
}

/// Perform Delaunay triangulation on convex hull
fn delaunayHull(
    ctx: *const Context,
    npts: i32,
    pts: [*]const f32,
    nhull: i32,
    hull: []const i32,
    tris: *std.ArrayList(i32),
    edges: *std.ArrayList(i32),
) !void {
    var nfaces: i32 = 0;
    var nedges: i32 = 0;
    const max_edges = npts * 10;
    try edges.resize(@as(usize, @intCast(max_edges * 4)));

    var i: i32 = 0;
    var j = nhull - 1;
    while (i < nhull) : ({
        j = i;
        i += 1;
    }) {
        _ = addEdge(ctx, edges.items, &nedges, max_edges, hull[@as(usize, @intCast(j))], hull[@as(usize, @intCast(i))], EV_HULL, EV_UNDEF);
    }

    var current_edge: i32 = 0;
    while (current_edge < nedges) : (current_edge += 1) {
        const idx = @as(usize, @intCast(current_edge * 4));
        if (edges.items[idx + 2] == EV_UNDEF) {
            completeFacet(ctx, pts, npts, edges.items, &nedges, max_edges, &nfaces, current_edge);
        }
        if (edges.items[idx + 3] == EV_UNDEF) {
            completeFacet(ctx, pts, npts, edges.items, &nedges, max_edges, &nfaces, current_edge);
        }
    }

    try tris.resize(@as(usize, @intCast(nfaces * 4)));
    for (0..@as(usize, @intCast(nfaces * 4))) |idx| {
        tris.items[idx] = -1;
    }

    i = 0;
    while (i < nedges) : (i += 1) {
        const idx = @as(usize, @intCast(i * 4));
        const e = edges.items[idx .. idx + 4];
        if (e[3] >= 0) {
            const t_idx = @as(usize, @intCast(e[3] * 4));
            var t = tris.items[t_idx .. t_idx + 4];
            if (t[0] == -1) {
                t[0] = e[0];
                t[1] = e[1];
            } else if (t[0] == e[1]) {
                t[2] = e[0];
            } else if (t[1] == e[0]) {
                t[2] = e[1];
            }
        }
        if (e[2] >= 0) {
            const t_idx = @as(usize, @intCast(e[2] * 4));
            var t = tris.items[t_idx .. t_idx + 4];
            if (t[0] == -1) {
                t[0] = e[1];
                t[1] = e[0];
            } else if (t[0] == e[0]) {
                t[2] = e[1];
            } else if (t[1] == e[1]) {
                t[2] = e[0];
            }
        }
    }

    i = 0;
    while (i < @as(i32, @intCast(tris.items.len / 4))) {
        const t_idx = @as(usize, @intCast(i * 4));
        const t = tris.items[t_idx .. t_idx + 4];
        if (t[0] == -1 or t[1] == -1 or t[2] == -1) {
            ctx.log(.warning, "delaunayHull: Removing dangling face {d} [{d},{d},{d}].", .{ i, t[0], t[1], t[2] });
            const last_idx = tris.items.len - 4;
            t[0] = tris.items[last_idx + 0];
            t[1] = tris.items[last_idx + 1];
            t[2] = tris.items[last_idx + 2];
            t[3] = tris.items[last_idx + 3];
            try tris.resize(tris.items.len - 4);
            i -= 1;
        }
        i += 1;
    }
}

/// Check if edge is on hull
fn onHull(a: i32, b: i32, nhull: i32, hull: []const i32) bool {
    if (a >= nhull or b >= nhull) return false;

    var j: i32 = nhull - 1;
    var i: i32 = 0;
    while (i < nhull) : ({
        j = i;
        i += 1;
    }) {
        if (a == hull[@as(usize, @intCast(j))] and b == hull[@as(usize, @intCast(i))]) {
            return true;
        }
    }
    return false;
}

/// Set triangle edge flags
fn setTriFlags(tris: *std.ArrayList(i32), nhull: i32, hull: []const i32) void {
    var i: usize = 0;
    while (i < tris.items.len) : (i += 4) {
        const a = tris.items[i + 0];
        const b = tris.items[i + 1];
        const c = tris.items[i + 2];
        var flags: u16 = 0;
        if (onHull(a, b, nhull, hull)) flags |= DETAIL_EDGE_BOUNDARY << 0;
        if (onHull(b, c, nhull, hull)) flags |= DETAIL_EDGE_BOUNDARY << 2;
        if (onHull(c, a, nhull, hull)) flags |= DETAIL_EDGE_BOUNDARY << 4;
        tris.items[i + 3] = @as(i32, @intCast(flags));
    }
}

/// Simple hull triangulation for degenerate cases
fn triangulateHull(
    _: i32,
    verts: [*]const f32,
    nhull: i32,
    hull: []const i32,
    _: i32,
    tris: *std.ArrayList(i32),
) !void {
    var left: i32 = 1;
    var right: i32 = nhull - 1;

    while (left < right) {
        const nleft = @mod(left + 1, nhull);
        const nright = if (right - 1 < 0) nhull - 1 else right - 1;

        const cvleft_idx = @as(usize, @intCast(hull[@as(usize, @intCast(left))] * 3));
        const nvleft_idx = @as(usize, @intCast(hull[@as(usize, @intCast(nleft))] * 3));
        const cvright_idx = @as(usize, @intCast(hull[@as(usize, @intCast(right))] * 3));
        const nvright_idx = @as(usize, @intCast(hull[@as(usize, @intCast(nright))] * 3));

        const cvleft = verts + cvleft_idx;
        const nvleft = verts + nvleft_idx;
        const cvright = verts + cvright_idx;
        const nvright = verts + nvright_idx;

        const dleft = vdist2(cvleft, nvleft) + vdist2(nvleft, cvright);
        const dright = vdist2(cvright, nvright) + vdist2(cvleft, nvright);

        if (dleft < dright) {
            try tris.append(hull[@as(usize, @intCast(left))]);
            try tris.append(hull[@as(usize, @intCast(nleft))]);
            try tris.append(hull[@as(usize, @intCast(right))]);
            try tris.append(0);
            left = nleft;
        } else {
            try tris.append(hull[@as(usize, @intCast(left))]);
            try tris.append(hull[@as(usize, @intCast(nright))]);
            try tris.append(hull[@as(usize, @intCast(right))]);
            try tris.append(0);
            right = nright;
        }
    }
}

// ============================================================================
// Placeholder functions - to be implemented
// ============================================================================

fn seedArrayWithPolyCenter(
    _: *const Context,
    chf: *const CompactHeightfield,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    bs: i32,
    hp: *const HeightPatch,
    array: *std.ArrayList(i32),
) !void {
    const offset = [_]i32{
        0, 0, -1, -1, 0, -1, 1, -1, 1, 0, 1, 1, 0, 1, -1, 1, -1, 0,
    };

    var start_cell_x: i32 = 0;
    var start_cell_y: i32 = 0;
    var start_span_index: i32 = -1;
    var dmin: i32 = @intCast(RC_UNSET_HEIGHT);

    var j: usize = 0;
    while (j < npoly and dmin > 0) : (j += 1) {
        var k: usize = 0;
        while (k < 9 and dmin > 0) : (k += 1) {
            const ax = @as(i32, @intCast(verts[poly[j] * 3 + 0])) + offset[k * 2 + 0];
            const ay = @as(i32, @intCast(verts[poly[j] * 3 + 1]));
            const az = @as(i32, @intCast(verts[poly[j] * 3 + 2])) + offset[k * 2 + 1];

            if (ax < hp.xmin or ax >= hp.xmin + hp.width or
                az < hp.ymin or az >= hp.ymin + hp.height) continue;

            const cell_idx = @as(usize, @intCast((ax + bs) + (az + bs) * chf.width));
            const c = chf.cells[cell_idx];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni and dmin > 0) : (i += 1) {
                const s = chf.spans[i];
                const d = @abs(ay - @as(i32, @intCast(s.y)));
                if (d < dmin) {
                    start_cell_x = ax;
                    start_cell_y = az;
                    start_span_index = @as(i32, @intCast(i));
                    dmin = @intCast(d);
                }
            }
        }
    }

    var pcx: i32 = 0;
    var pcy: i32 = 0;
    j = 0;
    while (j < npoly) : (j += 1) {
        pcx += @as(i32, @intCast(verts[poly[j] * 3 + 0]));
        pcy += @as(i32, @intCast(verts[poly[j] * 3 + 2]));
    }
    pcx = @divTrunc(pcx, @as(i32, @intCast(npoly)));
    pcy = @divTrunc(pcy, @as(i32, @intCast(npoly)));

    try array.resize(0);
    try array.append(start_cell_x);
    try array.append(start_cell_y);
    try array.append(start_span_index);

    var dirs = [_]i32{ 0, 1, 2, 3 };
    @memset(hp.data, 0);

    const dx = start_cell_x - pcx;
    const dy = start_cell_y - pcy;
    if (dx < 0) {
        std.mem.swap(i32, &dirs[0], &dirs[3]);
    }
    if (dy < 0) {
        std.mem.swap(i32, &dirs[1], &dirs[2]);
    }
    if (@abs(dy) > @abs(dx)) {
        std.mem.swap(i32, &dirs[0], &dirs[1]);
        std.mem.swap(i32, &dirs[2], &dirs[3]);
    }

    var iter: usize = 0;
    while (iter < array.items.len / 3) : (iter += 1) {
        if (iter >= @as(usize, @intCast(chf.width * chf.height))) break;

        const cx = array.items[iter * 3 + 0];
        const cy = array.items[iter * 3 + 1];
        const ci = array.items[iter * 3 + 2];

        if (cx == pcx and cy == pcy) break;

        const cs = chf.spans[@as(usize, @intCast(ci))];

        for (dirs) |dir| {
            if (getCon(&cs, dir) == NOT_CONNECTED) continue;

            const ax = cx + getDirOffsetX(dir);
            const ay = cy + getDirOffsetY(dir);

            if (ax < hp.xmin or ax >= hp.xmin + hp.width or
                ay < hp.ymin or ay >= hp.ymin + hp.height) continue;

            if (hp.data[@as(usize, @intCast((ax - hp.xmin) + (ay - hp.ymin) * hp.width))] != 0) continue;

            const cell_idx = @as(usize, @intCast(ax + bs + (ay + bs) * chf.width));
            const ai = @as(i32, @intCast(chf.cells[cell_idx].index)) + @as(i32, @intCast(getCon(&cs, dir)));

            const hx = ax - hp.xmin;
            const hy = ay - hp.ymin;
            hp.data[@as(usize, @intCast(hx + hy * hp.width))] = 1;

            try array.append(ax);
            try array.append(ay);
            try array.append(ai);
        }
    }

    try array.resize(0);
    try array.append(start_cell_x);
    try array.append(start_cell_y);
    try array.append(start_span_index);
}

fn getHeightData(
    ctx: *const Context,
    chf: *const CompactHeightfield,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    bs: i32,
    hp: *HeightPatch,
    queue: *std.ArrayList(i32),
    region: u16,
) !void {
    try queue.resize(0);
    @memset(hp.data, 0xff);

    var empty = true;

    if (region != RC_MULTIPLE_REGS) {
        var hy: i32 = 0;
        while (hy < hp.height) : (hy += 1) {
            const y = hp.ymin + hy + bs;
            var hx: i32 = 0;
            while (hx < hp.width) : (hx += 1) {
                const x = hp.xmin + hx + bs;
                const cell_idx = @as(usize, @intCast(x + y * chf.width));
                const c = chf.cells[cell_idx];

                var i: usize = c.index;
                const ni = c.index + c.count;
                while (i < ni) : (i += 1) {
                    const s = chf.spans[i];
                    if (s.reg == region) {
                        hp.data[@as(usize, @intCast(hx + hy * hp.width))] = s.y;
                        empty = false;

                        var border = false;
                        var dir: i32 = 0;
                        while (dir < 4) : (dir += 1) {
                            if (getCon(&s, dir) != NOT_CONNECTED) {
                                const ax = x + getDirOffsetX(dir);
                                const ay = y + getDirOffsetY(dir);
                                const ai_idx = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * chf.width))].index)) +
                                    @as(usize, @intCast(getCon(&s, dir)));
                                const as = chf.spans[ai_idx];
                                if (as.reg != region) {
                                    border = true;
                                    break;
                                }
                            }
                        }

                        if (border) {
                            try queue.append(x);
                            try queue.append(y);
                            try queue.append(@as(i32, @intCast(i)));
                        }
                        break;
                    }
                }
            }
        }
    }

    if (empty) {
        try seedArrayWithPolyCenter(ctx, chf, poly, npoly, verts, bs, hp, queue);
    }

    var head: usize = 0;
    while (head * 3 < queue.items.len) : (head += 1) {
        const cx = queue.items[head * 3 + 0];
        const cy = queue.items[head * 3 + 1];
        const ci = queue.items[head * 3 + 2];

        if (head >= RETRACT_SIZE) {
            head = 0;
            if (queue.items.len > RETRACT_SIZE * 3) {
                const old_len = queue.items.len;
                @memcpy(
                    queue.items[0 .. old_len - RETRACT_SIZE * 3],
                    queue.items[RETRACT_SIZE * 3 .. old_len],
                );
                try queue.resize(old_len - RETRACT_SIZE * 3);
            }
        }

        const cs = chf.spans[@as(usize, @intCast(ci))];
        var dir: i32 = 0;
        while (dir < 4) : (dir += 1) {
            if (getCon(&cs, dir) == NOT_CONNECTED) continue;

            const ax = cx + getDirOffsetX(dir);
            const ay = cy + getDirOffsetY(dir);
            const hx = ax - hp.xmin - bs;
            const hy = ay - hp.ymin - bs;

            if (hx < 0 or hx >= hp.width or hy < 0 or hy >= hp.height) continue;

            if (hp.data[@as(usize, @intCast(hx + hy * hp.width))] != RC_UNSET_HEIGHT) continue;

            const ai_idx = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * chf.width))].index)) +
                @as(usize, @intCast(getCon(&cs, dir)));
            const as = chf.spans[ai_idx];

            hp.data[@as(usize, @intCast(hx + hy * hp.width))] = as.y;

            try queue.append(ax);
            try queue.append(ay);
            try queue.append(@as(i32, @intCast(ai_idx)));
        }
    }
}

fn buildPolyDetail(
    ctx: *const Context,
    in: []const f32,
    nin: i32,
    sample_dist: f32,
    sample_max_error: f32,
    height_search_radius: i32,
    chf: *const CompactHeightfield,
    hp: *const HeightPatch,
    verts: []f32,
    nverts: *i32,
    tris: *std.ArrayList(i32),
    edges: *std.ArrayList(i32),
    samples: *std.ArrayList(i32),
) !bool {
    var edge_verts: [MAX_VERTS_PER_EDGE + 1][3]f32 = undefined;
    var hull: [MAX_VERTS]i32 = undefined;
    var nhull: i32 = 0;

    nverts.* = nin;

    var i: usize = 0;
    while (i < nin) : (i += 1) {
        verts[i * 3 + 0] = in[i * 3 + 0];
        verts[i * 3 + 1] = in[i * 3 + 1];
        verts[i * 3 + 2] = in[i * 3 + 2];
    }

    try edges.resize(0);
    try tris.resize(0);

    const cs = chf.cs;
    const ics = 1.0 / cs;

    const min_extent = polyMinExtent(verts[0..].ptr, nverts.*);

    if (sample_dist > 0) {
        i = 0;
        var j: usize = @intCast(nin - 1);
        while (i < nin) : ({
            j = i;
            i += 1;
        }) {
            var vj = in[j * 3 ..].ptr;
            var vi = in[i * 3 ..].ptr;
            var swapped = false;

            if (@abs(vj[0] - vi[0]) < 1e-6) {
                if (vj[2] > vi[2]) {
                    std.mem.swap([*]const f32, &vj, &vi);
                    swapped = true;
                }
            } else {
                if (vj[0] > vi[0]) {
                    std.mem.swap([*]const f32, &vj, &vi);
                    swapped = true;
                }
            }

            const dx = vi[0] - vj[0];
            const dy = vi[1] - vj[1];
            const dz = vi[2] - vj[2];
            const d = @sqrt(dx * dx + dz * dz);
            var nn = 1 + @as(i32, @intFromFloat(@floor(d / sample_dist)));
            if (nn >= MAX_VERTS_PER_EDGE) nn = MAX_VERTS_PER_EDGE - 1;
            if (nverts.* + nn >= MAX_VERTS) nn = MAX_VERTS - 1 - nverts.*;

            var k: i32 = 0;
            while (k <= nn) : (k += 1) {
                const u = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(nn));
                edge_verts[@intCast(k)][0] = vj[0] + dx * u;
                edge_verts[@intCast(k)][1] = vj[1] + dy * u;
                edge_verts[@intCast(k)][2] = vj[2] + dz * u;
                const h = getHeight(edge_verts[@intCast(k)][0], edge_verts[@intCast(k)][1], edge_verts[@intCast(k)][2], cs, ics, chf.ch, height_search_radius, hp);
                edge_verts[@intCast(k)][1] = @as(f32, @floatFromInt(h)) * chf.ch;
            }

            var idx: [MAX_VERTS_PER_EDGE]i32 = undefined;
            idx[0] = 0;
            idx[1] = nn;
            var nidx: usize = 2;

            k = 0;
            while (k < nidx - 1) {
                const a = idx[@intCast(k)];
                const b = idx[@intCast(k + 1)];
                const va = &edge_verts[@intCast(a)];
                const vb = &edge_verts[@intCast(b)];

                var maxd: f32 = 0;
                var maxi: i32 = -1;
                var m = a + 1;
                while (m < b) : (m += 1) {
                    const dev = distancePtSeg2d(&edge_verts[@intCast(m)], va, vb);
                    if (dev > maxd) {
                        maxd = dev;
                        maxi = m;
                    }
                }

                if (maxi != -1 and maxd > (sample_max_error * sample_max_error)) {
                    var m2: usize = nidx;
                    while (m2 > @as(usize, @intCast(k))) : (m2 -= 1) {
                        idx[m2] = idx[m2 - 1];
                    }
                    idx[@as(usize, @intCast(k + 1))] = maxi;
                    nidx += 1;
                } else {
                    k += 1;
                }
            }

            hull[@intCast(nhull)] = @intCast(j);
            nhull += 1;

            if (swapped) {
                k = @intCast(nidx - 2);
                while (k > 0) : (k -= 1) {
                    verts[@intCast(nverts.* * 3 + 0)] = edge_verts[@intCast(idx[@intCast(k)])][0];
                    verts[@intCast(nverts.* * 3 + 1)] = edge_verts[@intCast(idx[@intCast(k)])][1];
                    verts[@intCast(nverts.* * 3 + 2)] = edge_verts[@intCast(idx[@intCast(k)])][2];
                    hull[@intCast(nhull)] = nverts.*;
                    nhull += 1;
                    nverts.* += 1;
                }
            } else {
                k = 1;
                while (k < nidx - 1) : (k += 1) {
                    verts[@intCast(nverts.* * 3 + 0)] = edge_verts[@intCast(idx[@intCast(k)])][0];
                    verts[@intCast(nverts.* * 3 + 1)] = edge_verts[@intCast(idx[@intCast(k)])][1];
                    verts[@intCast(nverts.* * 3 + 2)] = edge_verts[@intCast(idx[@intCast(k)])][2];
                    hull[@intCast(nhull)] = nverts.*;
                    nhull += 1;
                    nverts.* += 1;
                }
            }
        }
    }

    if (min_extent < sample_dist * 2) {
        try triangulateHull(nverts.*, verts[0..].ptr, nhull, hull[0..@intCast(nhull)], nin, tris);
        setTriFlags(tris, nhull, hull[0..@intCast(nhull)]);
        return true;
    }

    try triangulateHull(nverts.*, verts[0..].ptr, nhull, hull[0..@intCast(nhull)], nin, tris);

    if (tris.items.len == 0) {
        ctx.log(.warning, "buildPolyDetail: Could not triangulate polygon ({d} verts).", .{nverts.*});
        return true;
    }

    if (sample_dist > 0) {
        var bmin = [_]f32{ in[0], in[1], in[2] };
        var bmax = [_]f32{ in[0], in[1], in[2] };
        i = 1;
        while (i < nin) : (i += 1) {
            bmin[0] = @min(bmin[0], in[i * 3 + 0]);
            bmin[1] = @min(bmin[1], in[i * 3 + 1]);
            bmin[2] = @min(bmin[2], in[i * 3 + 2]);
            bmax[0] = @max(bmax[0], in[i * 3 + 0]);
            bmax[1] = @max(bmax[1], in[i * 3 + 1]);
            bmax[2] = @max(bmax[2], in[i * 3 + 2]);
        }

        const x0 = @as(i32, @intFromFloat(@floor(bmin[0] / sample_dist)));
        const x1 = @as(i32, @intFromFloat(@ceil(bmax[0] / sample_dist)));
        const z0 = @as(i32, @intFromFloat(@floor(bmin[2] / sample_dist)));
        const z1 = @as(i32, @intFromFloat(@ceil(bmax[2] / sample_dist)));

        try samples.resize(0);
        var z = z0;
        while (z < z1) : (z += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const pt = [_]f32{
                    @as(f32, @floatFromInt(x)) * sample_dist,
                    (bmax[1] + bmin[1]) * 0.5,
                    @as(f32, @floatFromInt(z)) * sample_dist,
                };
                if (distToPoly(nin, in.ptr, &pt) > -sample_dist / 2) continue;

                try samples.append(x);
                try samples.append(@intCast(getHeight(pt[0], pt[1], pt[2], cs, ics, chf.ch, height_search_radius, hp)));
                try samples.append(z);
                try samples.append(0);
            }
        }

        const nsamples = @divTrunc(@as(i32, @intCast(samples.items.len)), 4);
        var iter: i32 = 0;
        while (iter < nsamples) : (iter += 1) {
            if (nverts.* >= MAX_VERTS) break;

            var bestpt = [_]f32{ 0, 0, 0 };
            var bestd: f32 = 0;
            var besti: i32 = -1;

            i = 0;
            while (i < nsamples) : (i += 1) {
                const s_idx = i * 4;
                if (samples.items[@intCast(s_idx + 3)] != 0) continue;

                const pt = [_]f32{
                    @as(f32, @floatFromInt(samples.items[@intCast(s_idx + 0)])) * sample_dist + getJitterX(@intCast(i)) * cs * 0.1,
                    @as(f32, @floatFromInt(samples.items[@intCast(s_idx + 1)])) * chf.ch,
                    @as(f32, @floatFromInt(samples.items[@intCast(s_idx + 2)])) * sample_dist + getJitterY(@intCast(i)) * cs * 0.1,
                };
                const d = distToTriMesh(&pt, verts[0..].ptr, nverts.*, @ptrCast(tris.items.ptr), @divTrunc(@as(i32, @intCast(tris.items.len)), 4));
                if (d < 0) continue;
                if (d > bestd) {
                    bestd = d;
                    besti = @intCast(i);
                    bestpt = pt;
                }
            }

            if (bestd <= sample_max_error or besti == -1) break;

            samples.items[@intCast(besti * 4 + 3)] = 1;

            verts[@intCast(nverts.* * 3 + 0)] = bestpt[0];
            verts[@intCast(nverts.* * 3 + 1)] = bestpt[1];
            verts[@intCast(nverts.* * 3 + 2)] = bestpt[2];
            nverts.* += 1;

            try edges.resize(0);
            try tris.resize(0);
            try delaunayHull(ctx, nverts.*, verts[0..].ptr, nhull, hull[0..@intCast(nhull)], tris, edges);
        }
    }

    const ntris = @divTrunc(@as(i32, @intCast(tris.items.len)), 4);
    if (ntris > MAX_TRIS) {
        try tris.resize(@intCast(MAX_TRIS * 4));
        ctx.log(.err, "rcBuildPolyMeshDetail: Shrinking triangle count from {d} to max {d}.", .{ ntris, MAX_TRIS });
    }

    setTriFlags(tris, nhull, hull[0..@intCast(nhull)]);

    return true;
}

/// Build detail mesh from polygon mesh
pub fn buildPolyMeshDetail(
    ctx: *const Context,
    mesh: *const PolyMesh,
    chf: *const CompactHeightfield,
    sample_dist: f32,
    sample_max_error: f32,
    dmesh: *PolyMeshDetail,
    allocator: std.mem.Allocator,
) !void {
    if (mesh.nverts == 0 or mesh.npolys == 0) return;

    const nvp = mesh.nvp;
    const cs = mesh.cs;
    const ch = mesh.ch;
    const orig = mesh.bmin;
    const border_size = mesh.border_size;
    const height_search_radius = @max(1, @as(i32, @intFromFloat(@ceil(mesh.max_edge_error))));

    var edges = std.ArrayList(i32).init(allocator);
    defer edges.deinit();
    var tris = std.ArrayList(i32).init(allocator);
    defer tris.deinit();
    var arr = std.ArrayList(i32).init(allocator);
    defer arr.deinit();
    var samples = std.ArrayList(i32).init(allocator);
    defer samples.deinit();

    var verts: [256 * 3]f32 = undefined;
    var n_poly_verts: usize = 0;
    var maxhw: i32 = 0;
    var maxhh: i32 = 0;

    const bounds = try allocator.alloc(i32, @as(usize, @intCast(mesh.npolys)) * 4);
    defer allocator.free(bounds);

    const poly = try allocator.alloc(f32, @as(usize, @intCast(nvp)) * 3);
    defer allocator.free(poly);

    // Find max size for polygon area
    for (0..@intCast(mesh.npolys)) |i| {
        const p_offset = i * @as(usize, @intCast(nvp)) * 2;
        const p = mesh.polys[p_offset .. p_offset + @as(usize, @intCast(nvp))];
        var xmin: i32 = chf.width;
        var xmax: i32 = 0;
        var ymin: i32 = chf.height;
        var ymax: i32 = 0;

        for (0..@intCast(nvp)) |j| {
            if (p[j] == RC_MESH_NULL_IDX) break;
            // Bounds check to prevent invalid access
            if (p[j] >= mesh.nverts) break;
            const v = mesh.verts[@as(usize, p[j]) * 3 ..];
            xmin = @min(xmin, @as(i32, @intCast(v[0])));
            xmax = @max(xmax, @as(i32, @intCast(v[0])));
            ymin = @min(ymin, @as(i32, @intCast(v[2])));
            ymax = @max(ymax, @as(i32, @intCast(v[2])));
            n_poly_verts += 1;
        }

        xmin = @max(0, xmin - 1);
        xmax = @min(chf.width, xmax + 1);
        ymin = @max(0, ymin - 1);
        ymax = @min(chf.height, ymax + 1);

        if (xmin >= xmax or ymin >= ymax) continue;

        bounds[i * 4 + 0] = xmin;
        bounds[i * 4 + 1] = xmax;
        bounds[i * 4 + 2] = ymin;
        bounds[i * 4 + 3] = ymax;

        maxhw = @max(maxhw, xmax - xmin);
        maxhh = @max(maxhh, ymax - ymin);
    }

    const hp_data = try allocator.alloc(u16, @intCast(maxhw * maxhh));
    defer allocator.free(hp_data);
    var hp = HeightPatch{
        .data = hp_data,
        .xmin = 0,
        .ymin = 0,
        .width = 0,
        .height = 0,
    };

    dmesh.nmeshes = mesh.npolys;
    dmesh.nverts = 0;
    dmesh.ntris = 0;

    dmesh.meshes = try allocator.alloc(u32, @as(usize, @intCast(dmesh.nmeshes)) * 4);
    @memset(dmesh.meshes, 0);

    var vcap = n_poly_verts + n_poly_verts / 2;
    var tcap = vcap * 2;

    dmesh.verts = try allocator.alloc(f32, vcap * 3);
    dmesh.tris = try allocator.alloc(u8, tcap * 4);

    for (0..@intCast(mesh.npolys)) |i| {
        const p_offset = i * @as(usize, @intCast(nvp)) * 2;
        const p = mesh.polys[p_offset .. p_offset + @as(usize, @intCast(nvp))];

        var npoly: usize = 0;
        for (0..@intCast(nvp)) |j| {
            if (p[j] == RC_MESH_NULL_IDX) break;
            // Bounds check to prevent invalid access
            if (p[j] >= mesh.nverts) break;
            const v = mesh.verts[@as(usize, p[j]) * 3 ..];
            poly[j * 3 + 0] = @as(f32, @floatFromInt(v[0])) * cs;
            poly[j * 3 + 1] = @as(f32, @floatFromInt(v[1])) * ch;
            poly[j * 3 + 2] = @as(f32, @floatFromInt(v[2])) * cs;
            npoly += 1;
        }

        hp.xmin = bounds[i * 4 + 0];
        hp.ymin = bounds[i * 4 + 2];
        hp.width = bounds[i * 4 + 1] - bounds[i * 4 + 0];
        hp.height = bounds[i * 4 + 3] - bounds[i * 4 + 2];

        try getHeightData(
            ctx,
            chf,
            p[0..@intCast(nvp)],
            @intCast(npoly),
            mesh.verts,
            border_size,
            &hp,
            &arr,
            mesh.regs[i],
        );

        var nverts: i32 = 0;
        if (!try buildPolyDetail(
            ctx,
            poly,
            @intCast(npoly),
            sample_dist,
            sample_max_error,
            height_search_radius,
            chf,
            &hp,
            &verts,
            &nverts,
            &tris,
            &edges,
            &samples,
        )) {
            return error.DetailBuildFailed;
        }

        // Move detail verts to world space
        for (0..@intCast(nverts)) |j| {
            verts[j * 3 + 0] += orig.x;
            verts[j * 3 + 1] += orig.y + chf.ch;
            verts[j * 3 + 2] += orig.z;
        }

        // Store detail submesh
        const ntris: usize = tris.items.len / 4;

        dmesh.meshes[i * 4 + 0] = @intCast(dmesh.nverts);
        dmesh.meshes[i * 4 + 1] = @intCast(nverts);
        dmesh.meshes[i * 4 + 2] = @intCast(dmesh.ntris);
        dmesh.meshes[i * 4 + 3] = @intCast(ntris);

        // Store vertices, allocate more if necessary
        if (dmesh.nverts + nverts > vcap) {
            while (dmesh.nverts + nverts > vcap) {
                vcap += 256;
            }
            const new_verts = try allocator.alloc(f32, vcap * 3);
            if (dmesh.nverts > 0) {
                @memcpy(new_verts[0 .. @as(usize, @intCast(dmesh.nverts)) * 3], dmesh.verts[0 .. @as(usize, @intCast(dmesh.nverts)) * 3]);
            }
            allocator.free(dmesh.verts);
            dmesh.verts = new_verts;
        }

        for (0..@intCast(nverts)) |j| {
            dmesh.verts[@as(usize, @intCast(dmesh.nverts * 3 + 0))] = verts[j * 3 + 0];
            dmesh.verts[@as(usize, @intCast(dmesh.nverts * 3 + 1))] = verts[j * 3 + 1];
            dmesh.verts[@as(usize, @intCast(dmesh.nverts * 3 + 2))] = verts[j * 3 + 2];
            dmesh.nverts += 1;
        }

        // Store triangles, allocate more if necessary
        if (@as(usize, @intCast(dmesh.ntris)) + ntris > tcap) {
            while (@as(usize, @intCast(dmesh.ntris)) + ntris > tcap) {
                tcap += 256;
            }
            const new_tris = try allocator.alloc(u8, tcap * 4);
            if (dmesh.ntris > 0) {
                @memcpy(new_tris[0 .. @as(usize, @intCast(dmesh.ntris)) * 4], dmesh.tris[0 .. @as(usize, @intCast(dmesh.ntris)) * 4]);
            }
            allocator.free(dmesh.tris);
            dmesh.tris = new_tris;
        }

        for (0..ntris) |j| {
            const t = tris.items[j * 4 ..];
            dmesh.tris[@as(usize, @intCast(dmesh.ntris * 4 + 0))] = @intCast(t[0]);
            dmesh.tris[@as(usize, @intCast(dmesh.ntris * 4 + 1))] = @intCast(t[1]);
            dmesh.tris[@as(usize, @intCast(dmesh.ntris * 4 + 2))] = @intCast(t[2]);
            dmesh.tris[@as(usize, @intCast(dmesh.ntris * 4 + 3))] = @intCast(t[3]);
            dmesh.ntris += 1;
        }
    }
}

/// Объединяет несколько detail meshes в один
pub fn mergePolyMeshDetails(
    ctx: *const Context,
    meshes: []const *PolyMeshDetail,
    mesh: *PolyMeshDetail,
) !void {
    // Подсчитываем суммарные размеры
    var max_verts: usize = 0;
    var max_tris: usize = 0;
    var max_meshes: usize = 0;

    for (meshes) |dm| {
        max_verts += @intCast(dm.nverts);
        max_tris += @intCast(dm.ntris);
        max_meshes += @intCast(dm.nmeshes);
    }

    // Allocate массивы для результата
    mesh.meshes = try mesh.allocator.alloc(u32, max_meshes * 4);
    errdefer mesh.allocator.free(mesh.meshes);

    mesh.tris = try mesh.allocator.alloc(u8, max_tris * 4);
    errdefer mesh.allocator.free(mesh.tris);

    mesh.verts = try mesh.allocator.alloc(f32, max_verts * 3);
    errdefer mesh.allocator.free(mesh.verts);

    mesh.nmeshes = 0;
    mesh.ntris = 0;
    mesh.nverts = 0;

    // Объединяем данные из всех meshes
    for (meshes) |dm| {
        // Копируем meshes (sub-mesh данные)
        const nmeshes_usize: usize = @intCast(dm.nmeshes);
        for (0..nmeshes_usize) |j| {
            const dst_idx = @as(usize, @intCast(mesh.nmeshes)) * 4;
            const src_idx = j * 4;

            mesh.meshes[dst_idx + 0] = @as(u32, @intCast(mesh.nverts)) + dm.meshes[src_idx + 0];
            mesh.meshes[dst_idx + 1] = dm.meshes[src_idx + 1];
            mesh.meshes[dst_idx + 2] = @as(u32, @intCast(mesh.ntris)) + dm.meshes[src_idx + 2];
            mesh.meshes[dst_idx + 3] = dm.meshes[src_idx + 3];

            mesh.nmeshes += 1;
        }

        // Копируем вершины
        const nverts_usize: usize = @intCast(dm.nverts);
        for (0..nverts_usize) |k| {
            const dst_idx = @as(usize, @intCast(mesh.nverts)) * 3;
            const src_idx = k * 3;
            mesh.verts[dst_idx + 0] = dm.verts[src_idx + 0];
            mesh.verts[dst_idx + 1] = dm.verts[src_idx + 1];
            mesh.verts[dst_idx + 2] = dm.verts[src_idx + 2];
            mesh.nverts += 1;
        }

        // Копируем треугольники
        const ntris_usize: usize = @intCast(dm.ntris);
        for (0..ntris_usize) |k| {
            const dst_idx = @as(usize, @intCast(mesh.ntris)) * 4;
            const src_idx = k * 4;
            mesh.tris[dst_idx + 0] = dm.tris[src_idx + 0];
            mesh.tris[dst_idx + 1] = dm.tris[src_idx + 1];
            mesh.tris[dst_idx + 2] = dm.tris[src_idx + 2];
            mesh.tris[dst_idx + 3] = dm.tris[src_idx + 3];
            mesh.ntris += 1;
        }
    }

    ctx.log(.info, "mergePolyMeshDetails: Merged {d} detail meshes into one (verts={d}, tris={d}, meshes={d})", .{
        meshes.len,
        mesh.nverts,
        mesh.ntris,
        mesh.nmeshes,
    });
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "vdot2 - dot product 2D" {
    const a = [_]f32{ 1.0, 0.0, 2.0 };
    const b = [_]f32{ 3.0, 0.0, 4.0 };
    try testing.expectApproxEqAbs(@as(f32, 11.0), vdot2(&a, &b), 0.001);
}

test "vcross2 - cross product 2D" {
    const p1 = [_]f32{ 0.0, 0.0, 0.0 };
    const p2 = [_]f32{ 1.0, 0.0, 0.0 };
    const p3 = [_]f32{ 0.0, 0.0, 1.0 };
    try testing.expectApproxEqAbs(@as(f32, 1.0), vcross2(&p1, &p2, &p3), 0.001);
}

test "vdist2 - distance 2D" {
    const p = [_]f32{ 0.0, 0.0, 0.0 };
    const q = [_]f32{ 3.0, 0.0, 4.0 };
    try testing.expectApproxEqAbs(@as(f32, 5.0), vdist2(&p, &q), 0.001);
}

test "circumCircle - basic triangle" {
    const p1 = [_]f32{ 0.0, 0.0, 0.0 };
    const p2 = [_]f32{ 2.0, 0.0, 0.0 };
    const p3 = [_]f32{ 1.0, 0.0, 2.0 };
    var c: [3]f32 = undefined;
    var r: f32 = undefined;
    circumCircle(&p1, &p2, &p3, &c, &r);
    try testing.expect(r > 0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c[0], 0.1);
}

test "getJitterX - deterministic jitter" {
    const j1 = getJitterX(0);
    const j2 = getJitterX(1);
    try testing.expect(j1 >= -1.0 and j1 <= 1.0);
    try testing.expect(j2 >= -1.0 and j2 <= 1.0);
    try testing.expect(j1 != j2);
}

test "polyMinExtent - triangle" {
    const verts = [_]f32{
        0.0, 0.0, 0.0,
        3.0, 0.0, 0.0,
        0.0, 0.0, 4.0,
    };
    const extent = polyMinExtent(&verts, 3);
    try testing.expect(extent > 0);
}
