const std = @import("std");
const math = @import("../math.zig");
const polymesh_mod = @import("polymesh.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const ContourSet = polymesh_mod.ContourSet;
const Contour = polymesh_mod.Contour;
const PolyMesh = polymesh_mod.PolyMesh;

const MESH_NULL_IDX = config.MESH_NULL_IDX;
const BORDER_VERTEX = config.BORDER_VERTEX;

const VERTEX_BUCKET_COUNT: usize = 1 << 12;

/// Edge structure for mesh adjacency
const Edge = struct {
    vert: [2]u16,
    poly_edge: [2]u16,
    poly: [2]u16,
};

/// Helper functions for array indexing
inline fn prev(i: usize, n: usize) usize {
    return if (i >= 1) i - 1 else n - 1;
}

inline fn next(i: usize, n: usize) usize {
    return if (i + 1 < n) i + 1 else 0;
}

/// Computes signed area of triangle (a,b,c)
inline fn area2(a: []const i32, b: []const i32, c: []const i32) i32 {
    return (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);
}

/// Returns true if c is strictly to the left of line a->b
inline fn left(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) < 0;
}

/// Returns true if c is to the left of or on line a->b
inline fn leftOn(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) <= 0;
}

/// Returns true if a, b, c are collinear
inline fn collinear(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) == 0;
}

/// Returns true if segments ab and cd properly intersect
fn intersectProp(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    // Eliminate improper cases
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
    {
        return false;
    }

    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

/// Returns true if c lies on closed segment ab
fn between(a: []const i32, b: []const i32, c: []const i32) bool {
    if (!collinear(a, b, c)) {
        return false;
    }

    // If ab not vertical, check betweenness on x; else on z
    if (a[0] != b[0]) {
        return ((a[0] <= c[0]) and (c[0] <= b[0])) or ((a[0] >= c[0]) and (c[0] >= b[0]));
    }

    return ((a[2] <= c[2]) and (c[2] <= b[2])) or ((a[2] >= c[2]) and (c[2] >= b[2]));
}

/// Returns true if segments ab and cd intersect (properly or improperly)
fn intersect(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    if (intersectProp(a, b, c, d)) {
        return true;
    }

    return between(a, b, c) or between(a, b, d) or
        between(c, d, a) or between(c, d, b);
}

/// Check if two vertices are equal on XZ plane
fn vequal(a: []const i32, b: []const i32) bool {
    return a[0] == b[0] and a[2] == b[2];
}

/// Check if diagonal (i,j) doesn't intersect polygon edges
fn diagonalie(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    const d0 = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
    const d1 = verts[@as(usize, @intCast(indices[j] & 0x0fffffff)) * 4 ..];

    var k: usize = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);

        // Skip edges incident to i or j
        if ((k == i) or (k1 == i) or (k == j) or (k1 == j)) {
            continue;
        }

        const p0 = verts[@as(usize, @intCast(indices[k] & 0x0fffffff)) * 4 ..];
        const p1 = verts[@as(usize, @intCast(indices[k1] & 0x0fffffff)) * 4 ..];

        if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) {
            continue;
        }

        if (intersect(d0, d1, p0, p1)) {
            return false;
        }
    }

    return true;
}

/// Check if diagonal (i,j) is internal to polygon in neighborhood of i
fn inCone(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    const pi = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
    const pj = verts[@as(usize, @intCast(indices[j] & 0x0fffffff)) * 4 ..];
    const pi1 = verts[@as(usize, @intCast(indices[next(i, n)] & 0x0fffffff)) * 4 ..];
    const pin1 = verts[@as(usize, @intCast(indices[prev(i, n)] & 0x0fffffff)) * 4 ..];

    // If P[i] is a convex vertex [i+1 left or on (i-1,i)]
    if (leftOn(pin1, pi, pi1)) {
        return left(pi, pj, pin1) and left(pj, pi, pi1);
    }

    // else P[i] is reflex
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

/// Check if (i,j) is a proper internal diagonal
fn diagonal(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    return inCone(i, j, n, verts, indices) and diagonalie(i, j, n, verts, indices);
}

/// Looser version of diagonalie for recovering from overlapping segments
fn diagonalieLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    const d0 = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
    const d1 = verts[@as(usize, @intCast(indices[j] & 0x0fffffff)) * 4 ..];

    var k: usize = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);

        if ((k == i) or (k1 == i) or (k == j) or (k1 == j)) {
            continue;
        }

        const p0 = verts[@as(usize, @intCast(indices[k] & 0x0fffffff)) * 4 ..];
        const p1 = verts[@as(usize, @intCast(indices[k1] & 0x0fffffff)) * 4 ..];

        if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) {
            continue;
        }

        if (intersectProp(d0, d1, p0, p1)) {
            return false;
        }
    }

    return true;
}

/// Looser version of inCone
fn inConeLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    const pi = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
    const pj = verts[@as(usize, @intCast(indices[j] & 0x0fffffff)) * 4 ..];
    const pi1 = verts[@as(usize, @intCast(indices[next(i, n)] & 0x0fffffff)) * 4 ..];
    const pin1 = verts[@as(usize, @intCast(indices[prev(i, n)] & 0x0fffffff)) * 4 ..];

    if (leftOn(pin1, pi, pi1)) {
        return leftOn(pi, pj, pin1) and leftOn(pj, pi, pi1);
    }

    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

/// Looser version of diagonal
fn diagonalLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const i32) bool {
    return inConeLoose(i, j, n, verts, indices) and diagonalieLoose(i, j, n, verts, indices);
}

/// Triangulates a polygon using ear-clipping algorithm
/// Returns number of triangles created (negative if had to use loose diagonal)
fn triangulate(n_in: usize, verts: []const i32, indices: []i32, tris: []i32) i32 {
    var n = n_in;
    var ntris: i32 = 0;
    var dst_idx: usize = 0;

    // Mark vertices that can be removed (form valid diagonal)
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx1 = next(i, n);
        const idx2 = next(idx1, n);
        if (diagonal(i, idx2, n, verts, indices)) {
            indices[idx1] |= @as(i32, @bitCast(@as(u32, 0x80000000)));
        }
    }

    while (n > 3) {
        var min_len: i32 = -1;
        var mini: i32 = -1;

        // Find best vertex to remove (shortest diagonal)
        i = 0;
        while (i < n) : (i += 1) {
            const idx1 = next(i, n);
            if ((indices[idx1] & @as(i32, @bitCast(@as(u32, 0x80000000)))) != 0) {
                const p0 = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
                const p2 = verts[@as(usize, @intCast(indices[next(idx1, n)] & 0x0fffffff)) * 4 ..];

                const dx = p2[0] - p0[0];
                const dy = p2[2] - p0[2];
                const len = dx * dx + dy * dy;

                if (min_len < 0 or len < min_len) {
                    min_len = len;
                    mini = @intCast(i);
                }
            }
        }

        if (mini == -1) {
            // Try to recover using loose diagonal
            min_len = -1;
            i = 0;
            while (i < n) : (i += 1) {
                const idx1 = next(i, n);
                const idx2 = next(idx1, n);
                if (diagonalLoose(i, idx2, n, verts, indices)) {
                    const p0 = verts[@as(usize, @intCast(indices[i] & 0x0fffffff)) * 4 ..];
                    const p2 = verts[@as(usize, @intCast(indices[next(idx2, n)] & 0x0fffffff)) * 4 ..];
                    const dx = p2[0] - p0[0];
                    const dy = p2[2] - p0[2];
                    const len = dx * dx + dy * dy;

                    if (min_len < 0 or len < min_len) {
                        min_len = len;
                        mini = @intCast(i);
                    }
                }
            }

            if (mini == -1) {
                // Contour is messed up
                return -ntris;
            }
        }

        const mini_usize: usize = @intCast(mini);
        const i_val = mini_usize;
        const idx1_val = next(i_val, n);
        const idx2_val = next(idx1_val, n);

        // Output triangle
        tris[dst_idx] = indices[i_val] & 0x0fffffff;
        tris[dst_idx + 1] = indices[idx1_val] & 0x0fffffff;
        tris[dst_idx + 2] = indices[idx2_val] & 0x0fffffff;
        dst_idx += 3;
        ntris += 1;

        // Remove vertex idx1 by shifting
        n -= 1;
        var k: usize = idx1_val;
        while (k < n) : (k += 1) {
            indices[k] = indices[k + 1];
        }

        var idx1_new = idx1_val;
        if (idx1_new >= n) idx1_new = 0;
        const i_new = prev(idx1_new, n);

        // Update diagonal flags
        if (diagonal(prev(i_new, n), idx1_new, n, verts, indices)) {
            indices[i_new] |= @as(i32, @bitCast(@as(u32, 0x80000000)));
        } else {
            indices[i_new] &= 0x0fffffff;
        }

        if (diagonal(i_new, next(idx1_new, n), n, verts, indices)) {
            indices[idx1_new] |= @as(i32, @bitCast(@as(u32, 0x80000000)));
        } else {
            indices[idx1_new] &= 0x0fffffff;
        }
    }

    // Append remaining triangle
    tris[dst_idx] = indices[0] & 0x0fffffff;
    tris[dst_idx + 1] = indices[1] & 0x0fffffff;
    tris[dst_idx + 2] = indices[2] & 0x0fffffff;
    ntris += 1;

    return ntris;
}

/// Computes vertex hash for spatial hashing
fn computeVertexHash(x: i32, y: i32, z: i32) usize {
    _ = y; // Height not used in hash
    const h1: u32 = 0x8da6b343;
    const h2: u32 = 0xd8163841;
    const h3: u32 = 0xcb1ab31f;

    const xu: u32 = @bitCast(x);
    const zu: u32 = @bitCast(z);
    const n: u32 = h1 *% xu +% h2 *% 0 +% h3 *% zu;

    return @as(usize, n & (VERTEX_BUCKET_COUNT - 1));
}

/// Adds vertex or returns existing one (with height tolerance)
fn addVertex(
    x: u16,
    y: u16,
    z: u16,
    verts: []u16,
    first_vert: []i32,
    next_vert: []i32,
    nv: *i32,
) u16 {
    const bucket = computeVertexHash(@intCast(x), 0, @intCast(z));
    var idx = first_vert[bucket];

    while (idx != -1) {
        const v = verts[@as(usize, @intCast(idx)) * 3 ..];
        if (v[0] == x and @abs(@as(i32, v[1]) - @as(i32, y)) <= 2 and v[2] == z) {
            return @intCast(idx);
        }
        idx = next_vert[@intCast(idx)];
    }

    // Create new vertex
    idx = nv.*;
    nv.* += 1;
    const v = verts[@as(usize, @intCast(idx)) * 3 ..];
    v[0] = x;
    v[1] = y;
    v[2] = z;
    next_vert[@intCast(idx)] = first_vert[bucket];
    first_vert[bucket] = idx;

    return @intCast(idx);
}

/// Builds mesh adjacency information
pub fn buildMeshAdjacency(
    polys: []u16,
    npolys: usize,
    nverts: usize,
    verts_per_poly: usize,
    allocator: std.mem.Allocator,
) !void {
    const max_edge_count = npolys * verts_per_poly;

    const first_edge = try allocator.alloc(u16, nverts + max_edge_count);
    defer allocator.free(first_edge);
    @memset(first_edge[0..nverts], MESH_NULL_IDX);

    const next_edge = first_edge[nverts..];

    const edges = try allocator.alloc(Edge, max_edge_count);
    defer allocator.free(edges);

    var edge_count: usize = 0;

    // Build edges
    for (0..npolys) |i| {
        const t = polys[i * verts_per_poly * 2 ..];
        for (0..verts_per_poly) |j| {
            if (t[j] == MESH_NULL_IDX) break;
            const v0 = t[j];
            const v1 = if (j + 1 >= verts_per_poly or t[j + 1] == MESH_NULL_IDX) t[0] else t[j + 1];

            if (v0 < v1) {
                var edge = &edges[edge_count];
                edge.vert[0] = v0;
                edge.vert[1] = v1;
                edge.poly[0] = @intCast(i);
                edge.poly_edge[0] = @intCast(j);
                edge.poly[1] = @intCast(i);
                edge.poly_edge[1] = 0;

                next_edge[edge_count] = first_edge[v0];
                first_edge[v0] = @intCast(edge_count);
                edge_count += 1;
            }
        }
    }

    // Find matching edges
    for (0..npolys) |i| {
        const t = polys[i * verts_per_poly * 2 ..];
        for (0..verts_per_poly) |j| {
            if (t[j] == MESH_NULL_IDX) break;
            const v0 = t[j];
            const v1 = if (j + 1 >= verts_per_poly or t[j + 1] == MESH_NULL_IDX) t[0] else t[j + 1];

            if (v0 > v1) {
                var e = first_edge[v1];
                while (e != MESH_NULL_IDX) {
                    const edge = &edges[e];
                    if (edge.vert[1] == v0 and edge.poly[0] == edge.poly[1]) {
                        edge.poly[1] = @intCast(i);
                        edge.poly_edge[1] = @intCast(j);
                        break;
                    }
                    e = next_edge[e];
                }
            }
        }
    }

    // Store adjacency
    for (0..edge_count) |i| {
        const e = &edges[i];
        if (e.poly[0] != e.poly[1]) {
            const p0 = polys[e.poly[0] * verts_per_poly * 2 ..];
            const p1 = polys[e.poly[1] * verts_per_poly * 2 ..];
            p0[verts_per_poly + e.poly_edge[0]] = e.poly[1];
            p1[verts_per_poly + e.poly_edge[1]] = e.poly[0];
        }
    }
}

/// Counts actual vertices in a polygon (until MESH_NULL_IDX)
fn countPolyVerts(p: []const u16, nvp: usize) usize {
    for (0..nvp) |i| {
        if (p[i] == MESH_NULL_IDX) {
            return i;
        }
    }
    return nvp;
}

/// Left test for u16 coordinates (used for polygon merging convexity check)
inline fn uleft(a: []const u16, b: []const u16, c: []const u16) bool {
    return (@as(i32, @intCast(b[0])) - @as(i32, @intCast(a[0]))) *
           (@as(i32, @intCast(c[2])) - @as(i32, @intCast(a[2]))) -
           (@as(i32, @intCast(c[0])) - @as(i32, @intCast(a[0]))) *
           (@as(i32, @intCast(b[2])) - @as(i32, @intCast(a[2]))) < 0;
}

/// Returns merge value for two polygons if they can be merged (shared edge + convexity check)
/// Returns -1 if polygons cannot be merged
/// ea and eb are output parameters for edge indices
fn getPolyMergeValue(
    pa: []u16,
    pb: []u16,
    verts: []const u16,
    ea: *i32,
    eb: *i32,
    nvp: usize,
) i32 {
    const na = countPolyVerts(pa, nvp);
    const nb = countPolyVerts(pb, nvp);

    // If the merged polygon would be too big, do not merge
    if (na + nb - 2 > nvp) {
        return -1;
    }

    // Check if the polygons share an edge
    ea.* = -1;
    eb.* = -1;

    for (0..na) |i| {
        var va0 = pa[i];
        var va1 = pa[(i + 1) % na];
        if (va0 > va1) {
            const tmp = va0;
            va0 = va1;
            va1 = tmp;
        }
        for (0..nb) |j| {
            var vb0 = pb[j];
            var vb1 = pb[(j + 1) % nb];
            if (vb0 > vb1) {
                const tmp = vb0;
                vb0 = vb1;
                vb1 = tmp;
            }
            if (va0 == vb0 and va1 == vb1) {
                ea.* = @intCast(i);
                eb.* = @intCast(j);
                break;
            }
        }
    }

    // No common edge, cannot merge
    if (ea.* == -1 or eb.* == -1) {
        return -1;
    }

    // Check to see if the merged polygon would be convex
    const ea_usize: usize = @intCast(ea.*);
    const eb_usize: usize = @intCast(eb.*);

    var va = pa[(ea_usize + na - 1) % na];
    var vb = pa[ea_usize];
    var vc = pb[(eb_usize + 2) % nb];
    if (!uleft(verts[@as(usize, va) * 3 ..], verts[@as(usize, vb) * 3 ..], verts[@as(usize, vc) * 3 ..])) {
        return -1;
    }

    va = pb[(eb_usize + nb - 1) % nb];
    vb = pb[eb_usize];
    vc = pa[(ea_usize + 2) % na];
    if (!uleft(verts[@as(usize, va) * 3 ..], verts[@as(usize, vb) * 3 ..], verts[@as(usize, vc) * 3 ..])) {
        return -1;
    }

    va = pa[ea_usize];
    vb = pa[(ea_usize + 1) % na];

    const dx = @as(i32, @intCast(verts[@as(usize, va) * 3 + 0])) - @as(i32, @intCast(verts[@as(usize, vb) * 3 + 0]));
    const dy = @as(i32, @intCast(verts[@as(usize, va) * 3 + 2])) - @as(i32, @intCast(verts[@as(usize, vb) * 3 + 2]));

    return dx * dx + dy * dy;
}

/// Merges two polygons pa and pb by shared edge (ea, eb) into pa
/// tmp is temporary storage for nvp vertices
fn mergePolyVerts(
    pa: []u16,
    pb: []const u16,
    ea: usize,
    eb: usize,
    tmp: []u16,
    nvp: usize,
) void {
    const na = countPolyVerts(pa, nvp);
    const nb = countPolyVerts(pb, nvp);

    // Merge polygons
    @memset(tmp[0..nvp], MESH_NULL_IDX);
    var n: usize = 0;

    // Add pa
    for (0..na - 1) |i| {
        tmp[n] = pa[(ea + 1 + i) % na];
        n += 1;
    }

    // Add pb
    for (0..nb - 1) |i| {
        tmp[n] = pb[(eb + 1 + i) % nb];
        n += 1;
    }

    @memcpy(pa[0..nvp], tmp[0..nvp]);
}

/// Checks if a vertex can be removed from the mesh
fn canRemoveVertex(
    ctx: *const Context,
    mesh: *const PolyMesh,
    rem: u16,
    allocator: std.mem.Allocator,
) !bool {
    const nvp: usize = @intCast(mesh.nvp);

    // Count number of polygons to remove
    var num_touched_verts: i32 = 0;
    var num_remaining_edges: i32 = 0;
    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. i * nvp * 2 + nvp];
        const nv = countPolyVerts(p, nvp);
        var num_removed: i32 = 0;
        var num_verts: i32 = 0;
        for (0..nv) |j| {
            if (p[j] == rem) {
                num_touched_verts += 1;
                num_removed += 1;
            }
            num_verts += 1;
        }
        if (num_removed > 0) {
            num_remaining_edges += num_verts - (num_removed + 1);
        }
    }

    // There would be too few edges remaining to create a polygon
    if (num_remaining_edges <= 2) {
        return false;
    }

    // Find edges which share the removed vertex
    const max_edges: usize = @intCast(num_touched_verts * 2);
    const edges = try allocator.alloc(i32, max_edges * 3);
    defer allocator.free(edges);
    var nedges: usize = 0;

    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. i * nvp * 2 + nvp];
        const nv = countPolyVerts(p, nvp);

        // Collect edges which touch the removed vertex
        var j: usize = 0;
        var k: usize = nv - 1;
        while (j < nv) : ({
            k = j;
            j += 1;
        }) {
            if (p[j] == rem or p[k] == rem) {
                // Arrange edge so that a=rem
                var a: i32 = @intCast(p[j]);
                var b: i32 = @intCast(p[k]);
                if (b == rem) {
                    const tmp = a;
                    a = b;
                    b = tmp;
                }

                // Check if the edge exists
                var exists = false;
                for (0..nedges) |m| {
                    const e = edges[m * 3 .. m * 3 + 3];
                    if (e[1] == b) {
                        // Exists, increment vertex share count
                        e[2] += 1;
                        exists = true;
                        break;
                    }
                }

                // Add new edge
                if (!exists) {
                    if (nedges >= max_edges) {
                        ctx.log(.warning, "canRemoveVertex: Too many edges", .{});
                        return false;
                    }
                    edges[nedges * 3 + 0] = a;
                    edges[nedges * 3 + 1] = b;
                    edges[nedges * 3 + 2] = 1;
                    nedges += 1;
                }
            }
        }
    }

    // There should be no more than 2 open edges
    var num_open_edges: i32 = 0;
    for (0..nedges) |i| {
        if (edges[i * 3 + 2] < 2) {
            num_open_edges += 1;
        }
    }
    if (num_open_edges > 2) {
        return false;
    }

    return true;
}

/// Helper to add element to front of array
inline fn pushFront(v: i32, arr: []i32, an: *usize) void {
    var i: usize = an.*;
    while (i > 0) : (i -= 1) {
        arr[i] = arr[i - 1];
    }
    arr[0] = v;
    an.* += 1;
}

/// Helper to add element to back of array
inline fn pushBack(v: i32, arr: []i32, an: *usize) void {
    arr[an.*] = v;
    an.* += 1;
}

/// Removes a vertex from the mesh and retriangulates the resulting hole
fn removeVertex(
    ctx: *const Context,
    mesh: *PolyMesh,
    rem: u16,
    max_tris: usize,
    allocator: std.mem.Allocator,
) !void {
    const nvp: usize = @intCast(mesh.nvp);

    // Count number of polygons to remove
    var num_removed_verts: usize = 0;
    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. i * nvp * 2 + nvp];
        const nv = countPolyVerts(p, nvp);
        for (0..nv) |j| {
            if (p[j] == rem) {
                num_removed_verts += 1;
            }
        }
    }

    const edges = try allocator.alloc(i32, num_removed_verts * nvp * 4);
    defer allocator.free(edges);
    var nedges: usize = 0;

    const hole = try allocator.alloc(i32, num_removed_verts * nvp);
    defer allocator.free(hole);
    var nhole: usize = 0;

    const hreg = try allocator.alloc(i32, num_removed_verts * nvp);
    defer allocator.free(hreg);

    const harea = try allocator.alloc(i32, num_removed_verts * nvp);
    defer allocator.free(harea);

    var i: usize = 0;
    while (i < @as(usize, @intCast(mesh.npolys))) {
        const p = mesh.polys[i * nvp * 2 .. i * nvp * 2 + nvp];
        const nv = countPolyVerts(p, nvp);
        var has_rem = false;
        for (0..nv) |j| {
            if (p[j] == rem) {
                has_rem = true;
                break;
            }
        }

        if (has_rem) {
            // Collect edges which do not touch the removed vertex
            var j: usize = 0;
            var k: usize = nv - 1;
            while (j < nv) : ({
                k = j;
                j += 1;
            }) {
                if (p[j] != rem and p[k] != rem) {
                    edges[nedges * 4 + 0] = @intCast(p[k]);
                    edges[nedges * 4 + 1] = @intCast(p[j]);
                    edges[nedges * 4 + 2] = @intCast(mesh.regs[i]);
                    edges[nedges * 4 + 3] = @intCast(mesh.areas[i]);
                    nedges += 1;
                }
            }

            // Remove the polygon
            const p2 = mesh.polys[(@as(usize, @intCast(mesh.npolys)) - 1) * nvp * 2 .. (@as(usize, @intCast(mesh.npolys)) - 1) * nvp * 2 + nvp];
            if (p.ptr != p2.ptr) {
                @memcpy(@constCast(p), p2);
            }
            @memset(@constCast(p[nvp..nvp * 2]), MESH_NULL_IDX);
            mesh.regs[i] = mesh.regs[@intCast(mesh.npolys - 1)];
            mesh.areas[i] = mesh.areas[@intCast(mesh.npolys - 1)];
            mesh.npolys -= 1;
        } else {
            i += 1;
        }
    }

    // Remove vertex
    const rem_usize: usize = @intCast(rem);
    var vi: usize = rem_usize;
    while (vi < @as(usize, @intCast(mesh.nverts)) - 1) : (vi += 1) {
        mesh.verts[vi * 3 + 0] = mesh.verts[(vi + 1) * 3 + 0];
        mesh.verts[vi * 3 + 1] = mesh.verts[(vi + 1) * 3 + 1];
        mesh.verts[vi * 3 + 2] = mesh.verts[(vi + 1) * 3 + 2];
    }
    mesh.nverts -= 1;

    // Adjust indices to match the removed vertex layout
    for (0..@intCast(mesh.npolys)) |pi| {
        const p = mesh.polys[pi * nvp * 2 .. pi * nvp * 2 + nvp];
        const nv = countPolyVerts(p, nvp);
        for (0..nv) |j| {
            if (p[j] > rem) {
                p[j] -= 1;
            }
        }
    }

    for (0..nedges) |ei| {
        if (edges[ei * 4 + 0] > rem) {
            edges[ei * 4 + 0] -= 1;
        }
        if (edges[ei * 4 + 1] > rem) {
            edges[ei * 4 + 1] -= 1;
        }
    }

    if (nedges == 0) {
        return;
    }

    // Start with one vertex, keep appending connected segments
    pushBack(edges[0], hole, &nhole);
    pushBack(edges[2], hreg, &nhole);
    pushBack(edges[3], harea, &nhole);

    while (nedges > 0) {
        var match = false;

        var ei: usize = 0;
        while (ei < nedges) {
            const ea = edges[ei * 4 + 0];
            const eb = edges[ei * 4 + 1];
            const r = edges[ei * 4 + 2];
            const a = edges[ei * 4 + 3];
            var add = false;

            if (hole[0] == eb) {
                pushFront(ea, hole, &nhole);
                pushFront(r, hreg, &nhole);
                pushFront(a, harea, &nhole);
                add = true;
            } else if (hole[nhole - 1] == ea) {
                pushBack(eb, hole, &nhole);
                pushBack(r, hreg, &nhole);
                pushBack(a, harea, &nhole);
                add = true;
            }

            if (add) {
                // Remove the edge
                edges[ei * 4 + 0] = edges[(nedges - 1) * 4 + 0];
                edges[ei * 4 + 1] = edges[(nedges - 1) * 4 + 1];
                edges[ei * 4 + 2] = edges[(nedges - 1) * 4 + 2];
                edges[ei * 4 + 3] = edges[(nedges - 1) * 4 + 3];
                nedges -= 1;
                match = true;
            } else {
                ei += 1;
            }
        }

        if (!match) {
            break;
        }
    }

    const tris = try allocator.alloc(i32, nhole * 3);
    defer allocator.free(tris);

    const tverts = try allocator.alloc(i32, nhole * 4);
    defer allocator.free(tverts);

    const thole = try allocator.alloc(i32, nhole);
    defer allocator.free(thole);

    // Generate temp vertex array for triangulation
    for (0..nhole) |hi| {
        const pi: usize = @intCast(hole[hi]);
        tverts[hi * 4 + 0] = @intCast(mesh.verts[pi * 3 + 0]);
        tverts[hi * 4 + 1] = @intCast(mesh.verts[pi * 3 + 1]);
        tverts[hi * 4 + 2] = @intCast(mesh.verts[pi * 3 + 2]);
        tverts[hi * 4 + 3] = 0;
        thole[hi] = @intCast(hi);
    }

    // Triangulate the hole
    var ntris = triangulate(@intCast(nhole), tverts, thole, tris);
    if (ntris < 0) {
        ntris = -ntris;
        ctx.log(.warning, "removeVertex: triangulate() returned bad results", .{});
    }

    const ntris_usize: usize = @intCast(ntris);
    const polys = try allocator.alloc(u16, (ntris_usize + 1) * nvp);
    defer allocator.free(polys);

    const pregs = try allocator.alloc(u16, ntris_usize);
    defer allocator.free(pregs);

    const pareas = try allocator.alloc(u8, ntris_usize);
    defer allocator.free(pareas);

    const tmp_poly = polys[ntris_usize * nvp ..];

    // Build initial polygons
    var npolys: usize = 0;
    @memset(polys[0 .. ntris_usize * nvp], MESH_NULL_IDX);
    for (0..ntris_usize) |j| {
        const t = tris[j * 3 .. j * 3 + 3];
        if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
            polys[npolys * nvp + 0] = @intCast(hole[@intCast(t[0])]);
            polys[npolys * nvp + 1] = @intCast(hole[@intCast(t[1])]);
            polys[npolys * nvp + 2] = @intCast(hole[@intCast(t[2])]);

            const t0: usize = @intCast(t[0]);
            const t1: usize = @intCast(t[1]);
            const t2: usize = @intCast(t[2]);

            // Mark if polygon covers multiple regions
            if (hreg[t0] != hreg[t1] or hreg[t1] != hreg[t2]) {
                pregs[npolys] = config.MULTIPLE_REGS;
            } else {
                pregs[npolys] = @intCast(hreg[t0]);
            }

            pareas[npolys] = @intCast(harea[t0]);
            npolys += 1;
        }
    }

    if (npolys == 0) {
        return;
    }

    // Merge polygons
    if (nvp > 3) {
        while (true) {
            var best_merge_val: i32 = 0;
            var best_pa: usize = 0;
            var best_pb: usize = 0;
            var best_ea: i32 = 0;
            var best_eb: i32 = 0;

            var j: usize = 0;
            while (j < npolys - 1) : (j += 1) {
                const pj = polys[j * nvp .. j * nvp + nvp];
                var k = j + 1;
                while (k < npolys) : (k += 1) {
                    const pk = polys[k * nvp .. k * nvp + nvp];
                    var ea: i32 = 0;
                    var eb: i32 = 0;
                    const v = getPolyMergeValue(@constCast(pj), @constCast(pk), mesh.verts, &ea, &eb, nvp);
                    if (v > best_merge_val) {
                        best_merge_val = v;
                        best_pa = j;
                        best_pb = k;
                        best_ea = ea;
                        best_eb = eb;
                    }
                }
            }

            if (best_merge_val > 0) {
                const pa = polys[best_pa * nvp .. best_pa * nvp + nvp];
                const pb = polys[best_pb * nvp .. best_pb * nvp + nvp];
                mergePolyVerts(@constCast(pa), pb, @intCast(best_ea), @intCast(best_eb), tmp_poly, nvp);

                if (pregs[best_pa] != pregs[best_pb]) {
                    pregs[best_pa] = config.MULTIPLE_REGS;
                }

                const last = polys[(npolys - 1) * nvp .. (npolys - 1) * nvp + nvp];
                if (pb.ptr != last.ptr) {
                    @memcpy(@constCast(pb), last);
                }
                pregs[best_pb] = pregs[npolys - 1];
                pareas[best_pb] = pareas[npolys - 1];
                npolys -= 1;
            } else {
                break;
            }
        }
    }

    // Store polygons
    for (0..npolys) |pi| {
        if (mesh.npolys >= @as(i32, @intCast(max_tris))) {
            break;
        }

        const p = mesh.polys[@as(usize, @intCast(mesh.npolys)) * nvp * 2 .. @as(usize, @intCast(mesh.npolys)) * nvp * 2 + nvp * 2];
        @memset(p, MESH_NULL_IDX);
        for (0..nvp) |j| {
            p[j] = polys[pi * nvp + j];
        }
        mesh.regs[@intCast(mesh.npolys)] = pregs[pi];
        mesh.areas[@intCast(mesh.npolys)] = pareas[pi];
        mesh.npolys += 1;

        if (mesh.npolys > @as(i32, @intCast(max_tris))) {
            ctx.log(.err, "removeVertex: Too many polygons {d} (max:{d})", .{ mesh.npolys, max_tris });
            return error.TooManyPolygons;
        }
    }
}

/// Builds polygon mesh from contour set
pub fn buildPolyMesh(
    ctx: *const Context,
    cset: *const ContourSet,
    nvp: usize,
    mesh: *PolyMesh,
    allocator: std.mem.Allocator,
) !void {
    mesh.bmin = cset.bmin;
    mesh.bmax = cset.bmax;
    mesh.cs = cset.cs;
    mesh.ch = cset.ch;
    mesh.border_size = cset.border_size;
    mesh.max_edge_error = cset.max_error;

    var max_vertices: usize = 0;
    var max_tris: usize = 0;
    var max_verts_per_cont: usize = 0;

    for (cset.conts) |cont| {
        if (cont.nverts < 3) continue;
        max_vertices += @intCast(cont.nverts);
        max_tris += @intCast(cont.nverts - 2);
        max_verts_per_cont = @max(max_verts_per_cont, @as(usize, @intCast(cont.nverts)));
    }

    if (max_vertices >= 0xfffe) {
        ctx.log(.err, "buildPolyMesh: Too many vertices {d}", .{max_vertices});
        return error.TooManyVertices;
    }

    ctx.log(.progress, "buildPolyMesh: max_vertices={d}, max_tris={d}", .{ max_vertices, max_tris });

    // Allocate mesh data
    mesh.verts = try allocator.alloc(u16, max_vertices * 3);
    @memset(mesh.verts, 0);

    mesh.polys = try allocator.alloc(u16, max_tris * nvp * 2);
    @memset(mesh.polys, MESH_NULL_IDX);

    mesh.regs = try allocator.alloc(u16, max_tris);
    @memset(mesh.regs, 0);

    mesh.areas = try allocator.alloc(u8, max_tris);
    @memset(mesh.areas, 0);

    mesh.nverts = 0;
    mesh.npolys = 0;
    mesh.nvp = @intCast(nvp);
    mesh.maxpolys = @intCast(max_tris);

    // Temporary arrays
    const vflags = try allocator.alloc(u8, max_vertices);
    defer allocator.free(vflags);
    @memset(vflags, 0);

    const next_vert = try allocator.alloc(i32, max_vertices);
    defer allocator.free(next_vert);
    @memset(next_vert, 0);

    const first_vert = try allocator.alloc(i32, VERTEX_BUCKET_COUNT);
    defer allocator.free(first_vert);
    @memset(first_vert, @bitCast(@as(u32, 0xffffffff)));

    const indices = try allocator.alloc(i32, max_verts_per_cont);
    defer allocator.free(indices);

    const tris = try allocator.alloc(i32, max_verts_per_cont * 3);
    defer allocator.free(tris);

    const polys = try allocator.alloc(u16, max_verts_per_cont * nvp);
    defer allocator.free(polys);

    const tmp_poly = try allocator.alloc(u16, nvp);
    defer allocator.free(tmp_poly);

    // Process each contour
    for (cset.conts) |cont| {
        if (cont.nverts < 3) continue;

        // Triangulate contour
        for (0..@intCast(cont.nverts)) |j| {
            indices[j] = @intCast(j);
        }

        const ntris = triangulate(@intCast(cont.nverts), cont.verts, indices, tris);
        if (ntris <= 0) {
            ctx.log(.warning, "buildPolyMesh: Bad triangulation for contour", .{});
            continue;
        }

        // Add and merge vertices
        for (0..@intCast(cont.nverts)) |j| {
            const v = cont.verts[j * 4 ..];
            indices[j] = @intCast(addVertex(
                @intCast(v[0]),
                @intCast(v[1]),
                @intCast(v[2]),
                mesh.verts,
                first_vert,
                next_vert,
                &mesh.nverts,
            ));

            if ((v[3] & BORDER_VERTEX) != 0) {
                vflags[@intCast(indices[j])] = 1;
            }
        }

        // Build initial polygons from triangles
        var npolys: usize = 0;
        @memset(polys, MESH_NULL_IDX);

        const ntris_usize: usize = @intCast(@abs(ntris));
        for (0..ntris_usize) |j| {
            const t = tris[j * 3 ..];
            if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
                polys[npolys * nvp + 0] = @intCast(indices[@intCast(t[0])]);
                polys[npolys * nvp + 1] = @intCast(indices[@intCast(t[1])]);
                polys[npolys * nvp + 2] = @intCast(indices[@intCast(t[2])]);
                npolys += 1;
            }
        }

        if (npolys == 0) continue;

        // Merge polygons if nvp > 3
        if (nvp > 3) {
            while (true) {
                // Find best polygons to merge
                var best_merge_val: i32 = 0;
                var best_pa: usize = 0;
                var best_pb: usize = 0;
                var best_ea: i32 = 0;
                var best_eb: i32 = 0;

                var j: usize = 0;
                while (j < npolys - 1) : (j += 1) {
                    const pj = polys[j * nvp ..];
                    var k = j + 1;
                    while (k < npolys) : (k += 1) {
                        const pk = polys[k * nvp ..];
                        var ea: i32 = 0;
                        var eb: i32 = 0;
                        const v = getPolyMergeValue(@constCast(pj[0..nvp]), @constCast(pk[0..nvp]), mesh.verts, &ea, &eb, nvp);
                        if (v > best_merge_val) {
                            best_merge_val = v;
                            best_pa = j;
                            best_pb = k;
                            best_ea = ea;
                            best_eb = eb;
                        }
                    }
                }

                if (best_merge_val > 0) {
                    // Found best, merge
                    const pa = polys[best_pa * nvp .. best_pa * nvp + nvp];
                    const pb = polys[best_pb * nvp .. best_pb * nvp + nvp];
                    mergePolyVerts(@constCast(pa), pb, @intCast(best_ea), @intCast(best_eb), tmp_poly, nvp);

                    const last_poly = polys[(npolys - 1) * nvp .. (npolys - 1) * nvp + nvp];
                    if (pb.ptr != last_poly.ptr) {
                        @memcpy(@constCast(pb), last_poly);
                    }
                    npolys -= 1;
                } else {
                    // Could not merge any polygons, stop
                    break;
                }
            }
        }

        // Store polygons
        for (0..npolys) |j| {
            const p = mesh.polys[@as(usize, @intCast(mesh.npolys)) * nvp * 2 ..];
            const q = polys[j * nvp ..];
            for (0..nvp) |k| {
                p[k] = q[k];
            }
            mesh.regs[@intCast(mesh.npolys)] = cont.reg;
            mesh.areas[@intCast(mesh.npolys)] = cont.area;
            mesh.npolys += 1;

            if (mesh.npolys > @as(i32, @intCast(max_tris))) {
                ctx.log(.err, "buildPolyMesh: Too many polygons {d}", .{mesh.npolys});
                return error.TooManyPolygons;
            }
        }
    }

    // Remove edge vertices
    var i: usize = 0;
    while (i < @as(usize, @intCast(mesh.nverts))) {
        if (vflags[i] != 0) {
            if (!(try canRemoveVertex(ctx, mesh, @intCast(i), allocator))) {
                i += 1;
                continue;
            }
            try removeVertex(ctx, mesh, @intCast(i), max_tris, allocator);
            // Note: mesh.nverts is already decremented inside removeVertex()!
            // Fixup vertex flags
            var j: usize = i;
            while (j < @as(usize, @intCast(mesh.nverts))) : (j += 1) {
                vflags[j] = vflags[j + 1];
            }
        } else {
            i += 1;
        }
    }

    // Build mesh adjacency
    try buildMeshAdjacency(
        mesh.polys,
        @intCast(mesh.npolys),
        @intCast(mesh.nverts),
        nvp,
        allocator,
    );

    ctx.log(.progress, "buildPolyMesh: Created mesh with {d} vertices and {d} polygons", .{ mesh.nverts, mesh.npolys });
}

/// Merges multiple polygon meshes into one
pub fn mergePolyMeshes(
    ctx: *const Context,
    meshes: []const *PolyMesh,
    nmeshes: usize,
    mesh: *PolyMesh,
    allocator: std.mem.Allocator,
) !void {
    _ = ctx;
    _ = meshes;
    _ = nmeshes;
    _ = mesh;
    _ = allocator;

    // TODO: Implement mesh merging
    return error.NotImplemented;
}

/// Копирует polygon mesh из source в destination
pub fn copyPolyMesh(
    ctx: *const Context,
    src: *const PolyMesh,
    dst: *PolyMesh,
) !void {
    // Destination должен быть пуст
    if (dst.verts.len > 0 or dst.polys.len > 0 or dst.regs.len > 0 or
        dst.areas.len > 0 or dst.flags.len > 0) {
        ctx.log(.err, "copyPolyMesh: Destination mesh must be empty", .{});
        return error.DestinationNotEmpty;
    }

    // Копируем метаданные
    dst.nverts = src.nverts;
    dst.npolys = src.npolys;
    dst.maxpolys = src.npolys;
    dst.nvp = src.nvp;
    dst.bmin = src.bmin;
    dst.bmax = src.bmax;
    dst.cs = src.cs;
    dst.ch = src.ch;
    dst.border_size = src.border_size;
    dst.max_edge_error = src.max_edge_error;

    // Allocate и копируем verts
    const nverts_usize: usize = @intCast(src.nverts);
    dst.verts = try dst.allocator.alloc(u16, nverts_usize * 3);
    @memcpy(dst.verts, src.verts[0..nverts_usize * 3]);

    // Allocate и копируем polys
    const npolys_usize: usize = @intCast(src.npolys);
    const nvp_usize: usize = @intCast(src.nvp);
    dst.polys = try dst.allocator.alloc(u16, npolys_usize * 2 * nvp_usize);
    @memcpy(dst.polys, src.polys[0..npolys_usize * 2 * nvp_usize]);

    // Allocate и копируем regs
    dst.regs = try dst.allocator.alloc(u16, npolys_usize);
    @memcpy(dst.regs, src.regs[0..npolys_usize]);

    // Allocate и копируем areas
    dst.areas = try dst.allocator.alloc(u8, npolys_usize);
    @memcpy(dst.areas, src.areas[0..npolys_usize]);

    // Allocate и копируем flags
    dst.flags = try dst.allocator.alloc(u16, npolys_usize);
    @memcpy(dst.flags, src.flags[0..npolys_usize]);
}

// Tests
test "area2 - basic triangle" {
    const a = [_]i32{ 0, 0, 0, 0 };
    const b = [_]i32{ 10, 0, 0, 0 };
    const c = [_]i32{ 5, 0, 10, 0 };

    const area = area2(&a, &b, &c);
    try std.testing.expect(area == 100);
}

test "left - point left of line" {
    const a = [_]i32{ 0, 0, 0, 0 };
    const b = [_]i32{ 10, 0, 0, 0 };
    const c = [_]i32{ 5, 0, -10, 0 }; // Point to the left (negative Z)

    try std.testing.expect(left(&a, &b, &c));
}

test "vequal - equal vertices" {
    const a = [_]i32{ 5, 10, 15, 20 };
    const b = [_]i32{ 5, 20, 15, 30 };
    try std.testing.expect(vequal(&a, &b));
}

test "computeVertexHash - consistent" {
    const h1 = computeVertexHash(10, 5, 20);
    const h2 = computeVertexHash(10, 5, 20);
    try std.testing.expectEqual(h1, h2);
}
