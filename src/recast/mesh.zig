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
    const d0 = verts[(indices[i] & 0x0fffffff) * 4 ..];
    const d1 = verts[(indices[j] & 0x0fffffff) * 4 ..];

    var k: usize = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);

        // Skip edges incident to i or j
        if ((k == i) or (k1 == i) or (k == j) or (k1 == j)) {
            continue;
        }

        const p0 = verts[(indices[k] & 0x0fffffff) * 4 ..];
        const p1 = verts[(indices[k1] & 0x0fffffff) * 4 ..];

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
    const pi = verts[(indices[i] & 0x0fffffff) * 4 ..];
    const pj = verts[(indices[j] & 0x0fffffff) * 4 ..];
    const pi1 = verts[(indices[next(i, n)] & 0x0fffffff) * 4 ..];
    const pin1 = verts[(indices[prev(i, n)] & 0x0fffffff) * 4 ..];

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
    const d0 = verts[(indices[i] & 0x0fffffff) * 4 ..];
    const d1 = verts[(indices[j] & 0x0fffffff) * 4 ..];

    var k: usize = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);

        if ((k == i) or (k1 == i) or (k == j) or (k1 == j)) {
            continue;
        }

        const p0 = verts[(indices[k] & 0x0fffffff) * 4 ..];
        const p1 = verts[(indices[k1] & 0x0fffffff) * 4 ..];

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
    const pi = verts[(indices[i] & 0x0fffffff) * 4 ..];
    const pj = verts[(indices[j] & 0x0fffffff) * 4 ..];
    const pi1 = verts[(indices[next(i, n)] & 0x0fffffff) * 4 ..];
    const pin1 = verts[(indices[prev(i, n)] & 0x0fffffff) * 4 ..];

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
            indices[idx1] |= 0x80000000;
        }
    }

    while (n > 3) {
        var min_len: i32 = -1;
        var mini: i32 = -1;

        // Find best vertex to remove (shortest diagonal)
        i = 0;
        while (i < n) : (i += 1) {
            const idx1 = next(i, n);
            if ((indices[idx1] & 0x80000000) != 0) {
                const p0 = verts[(indices[i] & 0x0fffffff) * 4 ..];
                const p2 = verts[(indices[next(idx1, n)] & 0x0fffffff) * 4 ..];

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
                    const p0 = verts[(indices[i] & 0x0fffffff) * 4 ..];
                    const p2 = verts[(indices[next(idx2, n)] & 0x0fffffff) * 4 ..];
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
            indices[i_new] |= 0x80000000;
        } else {
            indices[i_new] &= 0x0fffffff;
        }

        if (diagonal(i_new, next(idx1_new, n), n, verts, indices)) {
            indices[idx1_new] |= 0x80000000;
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
        max_vertices += cont.nverts;
        max_tris += cont.nverts - 2;
        max_verts_per_cont = @max(max_verts_per_cont, cont.nverts);
    }

    if (max_vertices >= 0xfffe) {
        ctx.log(.err, "buildPolyMesh: Too many vertices {d}", .{max_vertices});
        return error.TooManyVertices;
    }

    ctx.log(.debug, "buildPolyMesh: max_vertices={d}, max_tris={d}", .{ max_vertices, max_tris });

    // Allocate mesh data
    mesh.verts = try allocator.alloc(u16, max_vertices * 3);
    @memset(mesh.verts, 0);

    mesh.polys = try allocator.alloc(u16, max_tris * nvp * 2);
    @memset(mesh.polys, 0xff);

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

    // Process each contour
    for (cset.conts) |cont| {
        if (cont.nverts < 3) continue;

        // Triangulate contour
        for (0..cont.nverts) |j| {
            indices[j] = @intCast(j);
        }

        const ntris = triangulate(cont.nverts, cont.verts, indices, tris);
        if (ntris <= 0) {
            ctx.log(.warn, "buildPolyMesh: Bad triangulation for contour", .{});
            continue;
        }

        // Add and merge vertices
        for (0..cont.nverts) |j| {
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
        @memset(polys, 0xff);

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

        // TODO: Merge polygons if nvp > 3

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

    // TODO: Remove edge vertices
    // TODO: Build adjacency

    // Build mesh adjacency
    try buildMeshAdjacency(
        mesh.polys,
        @intCast(mesh.npolys),
        @intCast(mesh.nverts),
        nvp,
        allocator,
    );

    ctx.log(.info, "buildPolyMesh: Created mesh with {d} vertices and {d} polygons", .{ mesh.nverts, mesh.npolys });
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
