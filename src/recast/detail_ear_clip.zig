// Ear Clipping Algorithm Adapter for triangulateHull
// Adapted from mesh.zig ear clipping implementation to work with f32 vertices

const std = @import("std");

// ====================================================================
// EAR CLIPPING ALGORITHM - F32 ADAPTATION
// ====================================================================

pub const EarClipper = struct {
    const PRECISION_SCALE: f32 = 1000.0; // Scale factor for f32 to i32 conversion
    const EPSILON: f32 = 1e-6;

    /// Convert f32 vertex to i32 format for ear clipping algorithm
    fn convertVertex(vert: [3]f32) [4]i32 {
        return .{
            @as(i32, @intCast(@round(vert[0] * PRECISION_SCALE))),
            @as(i32, @intCast(@round(vert[1] * PRECISION_SCALE))),
            @as(i32, @intCast(@round(vert[2] * PRECISION_SCALE))),
            0, // padding
        };
    }

    /// Convert array of f32 vertices to i32 format
    fn convertVertices(verts: []const f32, indices: []const i32, output: []i32) void {
        for (indices, 0..) |idx, i| {
            const vert = [3]f32{
                verts[@as(usize, @intCast(idx * 3 + 0))],
                verts[@as(usize, @intCast(idx * 3 + 1))],
                verts[@as(usize, @intCast(idx * 3 + 2))],
            };
            const converted = convertVertex(vert);
            output[i * 4 + 0] = converted[0];
            output[i * 4 + 1] = converted[1];
            output[i * 4 + 2] = converted[2];
            output[i * 4 + 3] = converted[3];
        }
    }

    // Helper functions for array indexing (adapted from mesh.zig)
    inline fn prev(i: usize, n: usize) usize {
        return if (i >= 1) i - 1 else n - 1;
    }

    inline fn next(i: usize, n: usize) usize {
        return if (i + 1 < n) i + 1 else 0;
    }

    /// Computes signed area of triangle (a,b,c) in i32 format
    inline fn area2(a: []const i32, b: []const i32, c: []const i32) i32 {
        return (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);
    }

    /// Returns true if c is strictly to the left of line a->b
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

        return (leftOn(a, b, c) != leftOn(a, b, d)) and (leftOn(c, d, a) != leftOn(c, d, b));
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
            return leftOn(pi, pj, pin1) and leftOn(pj, pi, pi1);
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

    /// Main ear clipping triangulation function (adapted from mesh.zig)
    /// Returns number of triangles created (negative if had to use loose diagonal)
    pub fn triangulate(n_in: usize, verts: []const i32, indices: []i32, tris: []i32) i32 {
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

    /// Public interface for triangulation with f32 vertices
    pub fn triangulateHull(
        _: i32,
        verts_f32: []const f32,
        nhull: i32,
        hull: []const i32,
        _: i32,
        tris: *std.array_list.Managed(i32),
        allocator: std.mem.Allocator,
    ) !i32 {
        // Input validation
        if (nhull < 3) {
            return 0; // Not enough vertices for triangulation
        }

        // Allocate temporary arrays
        const verts_i32 = try allocator.alloc(i32, nhull * 4);
        defer allocator.free(verts_i32);

        const indices = try allocator.alloc(i32, nhull);
        defer allocator.free(indices);

        const max_tris = nhull - 2;
        const tris_i32 = try allocator.alloc(i32, max_tris * 3);
        defer allocator.free(tris_i32);

        // Convert f32 vertices to i32 format
        convertVertices(verts_f32, hull[0..@intCast(nhull)], verts_i32);

        // Initialize indices
        for (0..nhull) |i| {
            indices[i] = @intCast(i);
        }

        // Perform ear clipping triangulation
        const ntris = triangulate(@intCast(nhull), verts_i32, indices, tris_i32);

        if (ntris <= 0) {
            return -ntris; // Return negative to indicate loose diagonal was used
        }

        // Convert results back to expected format
        for (0..@intCast(ntris)) |i| {
            try tris.append(tris_i32[i * 3 + 0]);
            try tris.append(tris_i32[i * 3 + 1]);
            try tris.append(tris_i32[i * 3 + 2]);
            try tris.append(0); // flags
        }

        return ntris;
    }
};

// ====================================================================
// PUBLIC INTERFACE
// ====================================================================

pub const triangulateHull = EarClipper.triangulateHull;