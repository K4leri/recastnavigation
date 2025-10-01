const std = @import("std");

pub const PI: f32 = 3.14159265;

/// 3D vector with f32 components
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub fn fromArray(arr: *const [3]f32) Vec3 {
        return .{ .x = arr[0], .y = arr[1], .z = arr[2] };
    }

    pub fn toArray(self: Vec3) [3]f32 {
        return .{ self.x, self.y, self.z };
    }

    // Vector operations
    pub inline fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub inline fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    pub inline fn scale(self: Vec3, s: f32) Vec3 {
        return .{
            .x = self.x * s,
            .y = self.y * s,
            .z = self.z * s,
        };
    }

    pub inline fn mad(self: Vec3, other: Vec3, s: f32) Vec3 {
        return .{
            .x = self.x + other.x * s,
            .y = self.y + other.y * s,
            .z = self.z + other.z * s,
        };
    }

    pub inline fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub inline fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub inline fn lengthSq(self: Vec3) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub inline fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSq());
    }

    pub inline fn distSq(self: Vec3, other: Vec3) f32 {
        const dx = other.x - self.x;
        const dy = other.y - self.y;
        const dz = other.z - self.z;
        return dx * dx + dy * dy + dz * dz;
    }

    pub inline fn dist(self: Vec3, other: Vec3) f32 {
        return @sqrt(self.distSq(other));
    }

    pub inline fn dist2D(self: Vec3, other: Vec3) f32 {
        const dx = other.x - self.x;
        const dz = other.z - self.z;
        return @sqrt(dx * dx + dz * dz);
    }

    pub inline fn dist2DSq(self: Vec3, other: Vec3) f32 {
        const dx = other.x - self.x;
        const dz = other.z - self.z;
        return dx * dx + dz * dz;
    }

    pub inline fn normalize(self: *Vec3) void {
        const d = 1.0 / self.length();
        self.x *= d;
        self.y *= d;
        self.z *= d;
    }

    pub inline fn normalized(self: Vec3) Vec3 {
        var result = self;
        result.normalize();
        return result;
    }

    pub inline fn lerp(self: Vec3, other: Vec3, t: f32) Vec3 {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
            .z = self.z + (other.z - self.z) * t,
        };
    }

    pub inline fn min(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = @min(self.x, other.x),
            .y = @min(self.y, other.y),
            .z = @min(self.z, other.z),
        };
    }

    pub inline fn max(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = @max(self.x, other.x),
            .y = @max(self.y, other.y),
            .z = @max(self.z, other.z),
        };
    }

    /// 2D dot product (xz plane)
    pub inline fn dot2D(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.z * other.z;
    }

    /// 2D perp product (xz plane)
    pub inline fn perp2D(self: Vec3, other: Vec3) f32 {
        return self.x * other.z - self.z * other.x;
    }

    /// Check if vectors are approximately equal
    pub inline fn equal(self: Vec3, other: Vec3) bool {
        const threshold = sqr(f32, 1.0 / 16384.0);
        return self.distSq(other) < threshold;
    }

    /// Check if all components are finite
    pub inline fn isFinite(self: Vec3) bool {
        return std.math.isFinite(self.x) and
               std.math.isFinite(self.y) and
               std.math.isFinite(self.z);
    }

    /// Check if 2D components are finite
    pub inline fn isFinite2D(self: Vec3) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.z);
    }
};

/// 2D vector (used for bounds calculations)
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
};

/// Axis-Aligned Bounding Box
pub const AABB = struct {
    min: Vec3,
    max: Vec3,

    pub fn init(min_bounds: Vec3, max_bounds: Vec3) AABB {
        return .{ .min = min_bounds, .max = max_bounds };
    }

    pub fn fromArray(min_bounds: *const [3]f32, max_bounds: *const [3]f32) AABB {
        return .{
            .min = Vec3.fromArray(min_bounds),
            .max = Vec3.fromArray(max_bounds),
        };
    }

    pub fn overlaps(self: AABB, other: AABB) bool {
        return !(self.min.x > other.max.x or self.max.x < other.min.x or
            self.min.y > other.max.y or self.max.y < other.min.y or
            self.min.z > other.max.z or self.max.z < other.min.z);
    }

    pub fn contains(self: AABB, point: Vec3) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y and
            point.z >= self.min.z and point.z <= self.max.z;
    }
};

// Utility functions
pub inline fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

pub inline fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

pub inline fn abs(comptime T: type, a: T) T {
    return if (a < 0) -a else a;
}

pub inline fn sqr(comptime T: type, a: T) T {
    return a * a;
}

pub inline fn clamp(comptime T: type, value: T, min_val: T, max_val: T) T {
    return if (value < min_val) min_val else if (value > max_val) max_val else value;
}

// Geometric functions
pub fn triArea2D(a: Vec3, b: Vec3, c: Vec3) f32 {
    const abx = b.x - a.x;
    const abz = b.z - a.z;
    const acx = c.x - a.x;
    const acz = c.z - a.z;
    return acx * abz - abx * acz;
}

pub fn closestPtPointTriangle(p: Vec3, a: Vec3, b: Vec3, c: Vec3) Vec3 {
    // Check if P in vertex region outside A
    const ab = b.sub(a);
    const ac = c.sub(a);
    const ap = p.sub(a);
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0.0 and d2 <= 0.0) return a;

    // Check if P in vertex region outside B
    const bp = p.sub(b);
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0.0 and d4 <= d3) return b;

    // Check if P in edge region of AB
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0) {
        const v = d1 / (d1 - d3);
        return a.add(ab.scale(v));
    }

    // Check if P in vertex region outside C
    const cp = p.sub(c);
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0.0 and d5 <= d6) return c;

    // Check if P in edge region of AC
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0) {
        const w = d2 / (d2 - d6);
        return a.add(ac.scale(w));
    }

    // Check if P in edge region of BC
    const va = d3 * d6 - d5 * d4;
    if (va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0) {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b.add(c.sub(b).scale(w));
    }

    // P inside face region. Compute Q through its barycentric coordinates
    const denom = 1.0 / (va + vb + vc);
    const v = vb * denom;
    const w = vc * denom;
    return a.add(ab.scale(v)).add(ac.scale(w));
}

pub fn pointInPolygon(pt: Vec3, verts: []const Vec3) bool {
    var c = false;
    var i: usize = 0;
    var j = verts.len - 1;
    while (i < verts.len) : (i += 1) {
        const vi = verts[i];
        const vj = verts[j];
        if (((vi.z > pt.z) != (vj.z > pt.z)) and
            (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x))
        {
            c = !c;
        }
        j = i;
    }
    return c;
}

// Bit manipulation utilities
pub fn nextPow2(v: u32) u32 {
    var n = v;
    n -= 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n += 1;
    return n;
}

pub fn ilog2(v: u32) u32 {
    var r: u32 = 0;
    var n = v;
    var shift: u32 = 0;

    shift = if (n > 0xffff) 16 else 0;
    n >>= @intCast(shift);
    r |= shift;

    shift = if (n > 0xff) 8 else 0;
    n >>= @intCast(shift);
    r |= shift;

    shift = if (n > 0xf) 4 else 0;
    n >>= @intCast(shift);
    r |= shift;

    shift = if (n > 0x3) 2 else 0;
    n >>= @intCast(shift);
    r |= shift;

    r |= (n >> 1);
    return r;
}

pub fn align4(x: i32) i32 {
    return (x + 3) & ~@as(i32, 3);
}

/// Calculate squared distance from point to line segment in 2D (xz plane)
/// Returns the parameter t along the segment
pub fn distancePtSegSqr2D(pt: *const [3]f32, p: *const [3]f32, q: *const [3]f32, t: *f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    const dx = pt[0] - p[0];
    const dz = pt[2] - p[2];
    const d = pqx * pqx + pqz * pqz;
    var param = pqx * dx + pqz * dz;

    if (d > 0) param /= d;

    if (param < 0) {
        t.* = 0;
    } else if (param > 1) {
        t.* = 1;
    } else {
        t.* = param;
    }

    const cx = p[0] + param * pqx;
    const cz = p[2] + param * pqz;
    const distx = pt[0] - cx;
    const distz = pt[2] - cz;

    return distx * distx + distz * distz;
}

/// Linear interpolation between two vectors
pub fn vlerp(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32, t: f32) void {
    dest[0] = v1[0] + (v2[0] - v1[0]) * t;
    dest[1] = v1[1] + (v2[1] - v1[1]) * t;
    dest[2] = v1[2] + (v2[2] - v1[2]) * t;
}

// Array-based vector operations (some functions already exist below, adding missing ones here)

/// Vector subtraction: dest = v1 - v2
pub fn vsub(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void {
    dest[0] = v1[0] - v2[0];
    dest[1] = v1[1] - v2[1];
    dest[2] = v1[2] - v2[2];
}

/// Vector addition: dest = v1 + v2
pub fn vadd(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void {
    dest[0] = v1[0] + v2[0];
    dest[1] = v1[1] + v2[1];
    dest[2] = v1[2] + v2[2];
}

/// Vector multiply-add: dest = v1 + v2 * s
pub fn vmad(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32, s: f32) void {
    dest[0] = v1[0] + v2[0] * s;
    dest[1] = v1[1] + v2[1] * s;
    dest[2] = v1[2] + v2[2] * s;
}

/// Vector scale: dest = v * s
pub fn vscale(dest: *[3]f32, v: *const [3]f32, s: f32) void {
    dest[0] = v[0] * s;
    dest[1] = v[1] * s;
    dest[2] = v[2] * s;
}

/// Dot product 3D
pub fn vdot(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return v1[0] * v2[0] + v1[1] * v2[1] + v1[2] * v2[2];
}

/// Vector length squared
pub fn vlenSqr(v: *const [3]f32) f32 {
    return v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
}

/// Vector length
pub fn vlen(v: *const [3]f32) f32 {
    return @sqrt(vlenSqr(v));
}

/// 3D distance
pub fn vdist(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dy = v2[1] - v1[1];
    const dz = v2[2] - v1[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

/// 3D distance squared
pub fn vdistSqr(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dy = v2[1] - v1[1];
    const dz = v2[2] - v1[2];
    return dx * dx + dy * dy + dz * dz;
}

/// 2D distance
pub fn vdist2D(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dz = v2[2] - v1[2];
    return @sqrt(dx * dx + dz * dz);
}

/// 2D distance squared
pub fn vdist2DSqr(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dz = v2[2] - v1[2];
    return dx * dx + dz * dz;
}

/// Normalize vector in place
pub fn vnormalize(v: *[3]f32) void {
    const d = 1.0 / vlen(v);
    v[0] *= d;
    v[1] *= d;
    v[2] *= d;
}

/// 2D perp dot product (xz plane)
pub fn vperp2D(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return v1[0] * v2[2] - v1[2] * v2[0];
}

/// Calculate squared distance from point to polygon edges
/// Returns true if point is inside polygon
pub fn distancePtPolyEdgesSqr(pt: *const [3]f32, verts: []const f32, nverts: usize, ed: []f32, et: []f32) bool {
    var c = false;
    var i: usize = 0;
    var j = nverts - 1;

    while (i < nverts) : ({
        j = i;
        i += 1;
    }) {
        const vi = verts[i * 3 .. i * 3 + 3];
        const vj = verts[j * 3 .. j * 3 + 3];

        if (((vi[2] > pt[2]) != (vj[2] > pt[2])) and
            (pt[0] < (vj[0] - vi[0]) * (pt[2] - vi[2]) / (vj[2] - vi[2]) + vi[0]))
        {
            c = !c;
        }

        ed[j] = distancePtSegSqr2D(pt, vj[0..3], vi[0..3], &et[j]);
    }

    return c;
}

/// Copy vector
pub inline fn vcopy(dest: *[3]f32, src: *const [3]f32) void {
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

/// Selects the minimum value of each element from the specified vectors
/// Updates mn in place with component-wise minimum
pub inline fn vmin(mn: *[3]f32, v: *const [3]f32) void {
    mn[0] = @min(mn[0], v[0]);
    mn[1] = @min(mn[1], v[1]);
    mn[2] = @min(mn[2], v[2]);
}

/// Selects the maximum value of each element from the specified vectors
/// Updates mx in place with component-wise maximum
pub inline fn vmax(mx: *[3]f32, v: *const [3]f32) void {
    mx[0] = @max(mx[0], v[0]);
    mx[1] = @max(mx[1], v[1]);
    mx[2] = @max(mx[2], v[2]);
}

/// Computes the cross product of two vectors
pub inline fn vcross(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void {
    dest[0] = v1[1] * v2[2] - v1[2] * v2[1];
    dest[1] = v1[2] * v2[0] - v1[0] * v2[2];
    dest[2] = v1[0] * v2[1] - v1[1] * v2[0];
}

/// Swap two values
pub inline fn swap(comptime T: type, a: *T, b: *T) void {
    const temp = a.*;
    a.* = b.*;
    b.* = temp;
}

/// Check if two vectors are approximately equal
pub inline fn vequal(a: *const [3]f32, b: *const [3]f32) bool {
    const threshold = sqr(f32, 1.0 / 16384.0);
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return dx * dx + dy * dy + dz * dz < threshold;
}

/// 2D dot product of two vectors (using x and z components)
pub inline fn vdot2D(u: []const f32, v: []const f32) f32 {
    return u[0] * v[0] + u[2] * v[2];
}

/// Check if vector components are finite (x, y, z)
pub inline fn visfinite(v: *const [3]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and std.math.isFinite(v[2]);
}

/// Check if 2D vector components are finite (x, z)
pub inline fn visfinite2D(v: *const [3]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[2]);
}

/// Check if a scalar is finite
pub inline fn isfinite(v: f32) bool {
    return std.math.isFinite(v);
}

/// Calculate intersection of two 2D segments in XZ plane
/// Returns true if segments intersect, fills s and t with parametric values
pub fn intersectSegSeg2D(ap: *const [3]f32, aq: *const [3]f32, bp: *const [3]f32, bq: *const [3]f32, s: *f32, t: *f32) bool {
    const ux = aq[0] - ap[0];
    const uz = aq[2] - ap[2];
    const vx = bq[0] - bp[0];
    const vz = bq[2] - bp[2];
    const wx = ap[0] - bp[0];
    const wz = ap[2] - bp[2];

    const d = ux * vz - uz * vx;
    if (@abs(d) < 1e-6) return false;

    s.* = (vx * wz - vz * wx) / d;
    t.* = (ux * wz - uz * wx) / d;
    return true;
}

/// Intersect segment with polygon in 2D (XZ plane)
/// Uses Cyrus-Beck clipping algorithm
/// Returns true if segment intersects polygon
/// tmin, tmax: parametric values where segment enters/exits polygon (0..1)
/// seg_min, seg_max: edge indices where segment enters/exits (-1 if fully inside)
pub fn intersectSegmentPoly2D(
    p0: *const [3]f32,
    p1: *const [3]f32,
    verts: []const f32,
    nverts: usize,
    tmin: *f32,
    tmax: *f32,
    seg_min: *i32,
    seg_max: *i32,
) bool {
    const EPS = 0.000001;

    tmin.* = 0;
    tmax.* = 1;
    seg_min.* = -1;
    seg_max.* = -1;

    var dir: [3]f32 = undefined;
    dir[0] = p1[0] - p0[0];
    dir[1] = p1[1] - p0[1];
    dir[2] = p1[2] - p0[2];

    var j: usize = nverts - 1;
    var i: usize = 0;
    while (i < nverts) : ({
        j = i;
        i += 1;
    }) {
        const vi = verts[i * 3 .. i * 3 + 3];
        const vj = verts[j * 3 .. j * 3 + 3];

        var edge: [3]f32 = undefined;
        edge[0] = vi[0] - vj[0];
        edge[1] = vi[1] - vj[1];
        edge[2] = vi[2] - vj[2];

        var diff: [3]f32 = undefined;
        diff[0] = p0[0] - vj[0];
        diff[1] = p0[1] - vj[1];
        diff[2] = p0[2] - vj[2];

        const n = edge[0] * diff[2] - edge[2] * diff[0]; // perp2D(edge, diff)
        const d = dir[0] * edge[2] - dir[2] * edge[0]; // perp2D(dir, edge)

        if (@abs(d) < EPS) {
            // Segment is nearly parallel to this edge
            if (n < 0) {
                return false;
            } else {
                continue;
            }
        }

        const t = n / d;
        if (d < 0) {
            // Segment is entering across this edge
            if (t > tmin.*) {
                tmin.* = t;
                seg_min.* = @intCast(j);
                // Segment enters after leaving polygon
                if (tmin.* > tmax.*) {
                    return false;
                }
            }
        } else {
            // Segment is leaving across this edge
            if (t < tmax.*) {
                tmax.* = t;
                seg_max.* = @intCast(j);
                // Segment leaves before entering polygon
                if (tmax.* < tmin.*) {
                    return false;
                }
            }
        }
    }

    return true;
}

// Tests
test "Vec3 basic operations" {
    const v1 = Vec3.init(1.0, 2.0, 3.0);
    const v2 = Vec3.init(4.0, 5.0, 6.0);

    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f32, 5.0), sum.x);
    try std.testing.expectEqual(@as(f32, 7.0), sum.y);
    try std.testing.expectEqual(@as(f32, 9.0), sum.z);

    const dot_product = v1.dot(v2);
    try std.testing.expectEqual(@as(f32, 32.0), dot_product);
}

test "Vec3 distance" {
    const v1 = Vec3.init(0.0, 0.0, 0.0);
    const v2 = Vec3.init(3.0, 4.0, 0.0);
    const dist = v1.dist(v2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), dist, 0.001);
}

test "AABB overlap" {
    const aabb1 = AABB.init(
        Vec3.init(0.0, 0.0, 0.0),
        Vec3.init(10.0, 10.0, 10.0),
    );
    const aabb2 = AABB.init(
        Vec3.init(5.0, 5.0, 5.0),
        Vec3.init(15.0, 15.0, 15.0),
    );
    try std.testing.expect(aabb1.overlaps(aabb2));
}

// ============================================================================
// Scalar Mathematical Functions Tests
// ============================================================================

test "min - returns lowest value" {
    try std.testing.expectEqual(@as(i32, 1), min(i32, 1, 2));
    try std.testing.expectEqual(@as(i32, 1), min(i32, 2, 1));
}

test "min - equal args" {
    try std.testing.expectEqual(@as(i32, 1), min(i32, 1, 1));
}

test "max - returns greatest value" {
    try std.testing.expectEqual(@as(i32, 2), max(i32, 1, 2));
    try std.testing.expectEqual(@as(i32, 2), max(i32, 2, 1));
}

test "max - equal args" {
    try std.testing.expectEqual(@as(i32, 1), max(i32, 1, 1));
}

test "abs - returns absolute value" {
    try std.testing.expectEqual(@as(i32, 1), abs(i32, -1));
    try std.testing.expectEqual(@as(i32, 1), abs(i32, 1));
    try std.testing.expectEqual(@as(i32, 0), abs(i32, 0));
}

test "sqr - squares a number" {
    try std.testing.expectEqual(@as(i32, 4), sqr(i32, 2));
    try std.testing.expectEqual(@as(i32, 16), sqr(i32, -4));
    try std.testing.expectEqual(@as(i32, 0), sqr(i32, 0));
}

test "clamp - higher than range" {
    try std.testing.expectEqual(@as(i32, 1), clamp(i32, 2, 0, 1));
}

test "clamp - within range" {
    try std.testing.expectEqual(@as(i32, 1), clamp(i32, 1, 0, 2));
}

test "clamp - lower than range" {
    try std.testing.expectEqual(@as(i32, 1), clamp(i32, 0, 1, 2));
}

test "sqrt - gets square root" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), @sqrt(@as(f32, 4.0)), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), @sqrt(@as(f32, 81.0)), 0.0001);
}

test "swap - swaps two values" {
    var one: i32 = 1;
    var two: i32 = 2;
    swap(i32, &one, &two);
    try std.testing.expectEqual(@as(i32, 2), one);
    try std.testing.expectEqual(@as(i32, 1), two);
}

// ============================================================================
// Vector Operations (array-based) Tests
// ============================================================================

test "vdot - normalized vector with itself" {
    const v1 = [_]f32{ 1.0, 0.0, 0.0 };
    const result = vdot(&v1, &v1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.0001);
}

test "vdot - zero vector with anything is zero" {
    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 0.0, 0.0, 0.0 };
    const result = vdot(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 0.0001);
}

test "vmad - scaled add two vectors" {
    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 0.0, 2.0, 4.0 };
    var result: [3]f32 = undefined;
    vmad(&result, &v1, &v2, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), result[2], 0.0001);
}

test "vmad - second vector is scaled, first is not" {
    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 5.0, 6.0, 7.0 };
    var result: [3]f32 = undefined;
    vmad(&result, &v1, &v2, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), result[2], 0.0001);
}

test "vadd - add two vectors" {
    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 5.0, 6.0, 7.0 };
    var result: [3]f32 = undefined;
    vadd(&result, &v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), result[2], 0.0001);
}

test "vsub - subtract two vectors" {
    const v1 = [_]f32{ 5.0, 4.0, 3.0 };
    const v2 = [_]f32{ 1.0, 2.0, 3.0 };
    var result: [3]f32 = undefined;
    vsub(&result, &v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[2], 0.0001);
}

test "vmin - selects min component from vectors" {
    var v1 = [_]f32{ 5.0, 4.0, 0.0 };
    const v2 = [_]f32{ 1.0, 2.0, 9.0 };
    vmin(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v1[2], 0.0001);
}

test "vmin - v1 is min" {
    var v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 4.0, 5.0, 6.0 };
    vmin(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), v1[2], 0.0001);
}

test "vmin - v2 is min" {
    var v1 = [_]f32{ 4.0, 5.0, 6.0 };
    const v2 = [_]f32{ 1.0, 2.0, 3.0 };
    vmin(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), v1[2], 0.0001);
}

test "vmax - selects max component from vectors" {
    var v1 = [_]f32{ 5.0, 4.0, 0.0 };
    const v2 = [_]f32{ 1.0, 2.0, 9.0 };
    vmax(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), v1[2], 0.0001);
}

test "vmax - v2 is max" {
    var v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 4.0, 5.0, 6.0 };
    vmax(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), v1[2], 0.0001);
}

test "vmax - v1 is max" {
    var v1 = [_]f32{ 4.0, 5.0, 6.0 };
    const v2 = [_]f32{ 1.0, 2.0, 3.0 };
    vmax(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), v1[2], 0.0001);
}

test "vcopy - copies a vector into another vector" {
    const v1 = [_]f32{ 5.0, 4.0, 0.0 };
    var result = [_]f32{ 1.0, 2.0, 9.0 };
    vcopy(&result, &v1);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[2], 0.0001);
    // Check that v1 is unchanged
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), v1[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), v1[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v1[2], 0.0001);
}

// ============================================================================
// Distance and Normalization Tests
// ============================================================================

test "vdist - distance between two vectors" {
    const v1 = [_]f32{ 3.0, 1.0, 3.0 };
    const v2 = [_]f32{ 1.0, 3.0, 1.0 };
    const result = vdist(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 3.4641), result, 0.001);
}

test "vdist - distance from zero is magnitude" {
    const v1 = [_]f32{ 3.0, 1.0, 3.0 };
    const v2 = [_]f32{ 0.0, 0.0, 0.0 };
    const distance = vdist(&v1, &v2);
    const magnitude = @sqrt(sqr(f32, v1[0]) + sqr(f32, v1[1]) + sqr(f32, v1[2]));
    try std.testing.expectApproxEqAbs(magnitude, distance, 0.0001);
}

test "vdistSqr - squared distance between two vectors" {
    const v1 = [_]f32{ 3.0, 1.0, 3.0 };
    const v2 = [_]f32{ 1.0, 3.0, 1.0 };
    const result = vdistSqr(&v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), result, 0.0001);
}

test "vnormalize - normalizes a vector" {
    var v = [_]f32{ 3.0, 4.0, 0.0 };
    vnormalize(&v);
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.0001);
}

test "vcross - computes cross product" {
    const v1 = [_]f32{ 3.0, -3.0, 1.0 };
    const v2 = [_]f32{ 4.0, 9.0, 2.0 };
    var result: [3]f32 = undefined;
    vcross(&result, &v1, &v2);
    try std.testing.expectApproxEqAbs(@as(f32, -15.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 39.0), result[2], 0.0001);
}

test "vcross - cross product with itself is zero" {
    const v1 = [_]f32{ 3.0, -3.0, 1.0 };
    var result: [3]f32 = undefined;
    vcross(&result, &v1, &v1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[2], 0.0001);
}

/// Project polygon onto an axis, returning min and max projection values
fn projectPoly(axis: *const [3]f32, poly: []const f32, npoly: usize, rmin: *f32, rmax: *f32) void {
    rmin.* = vdot2D(axis, poly[0..3]);
    rmax.* = rmin.*;

    var i: usize = 1;
    while (i < npoly) : (i += 1) {
        const d = vdot2D(axis, poly[i * 3 .. i * 3 + 3]);
        rmin.* = @min(rmin.*, d);
        rmax.* = @max(rmax.*, d);
    }
}

/// Check if two ranges [amin, amax] and [bmin, bmax] overlap
pub inline fn overlapRange(amin: f32, amax: f32, bmin: f32, bmax: f32, eps: f32) bool {
    return !((amin + eps) > bmax or (amax - eps) < bmin);
}

/// Test if two convex polygons overlap in 2D (xz-plane) using Separating Axis Theorem
/// @param polya First polygon vertices (x,y,z triplets)
/// @param npolya Number of vertices in first polygon
/// @param polyb Second polygon vertices (x,y,z triplets)
/// @param npolyb Number of vertices in second polygon
/// @return true if polygons overlap
pub fn overlapPolyPoly2D(polya: []const f32, npolya: usize, polyb: []const f32, npolyb: usize) bool {
    const eps = 1e-4;

    // Test edges of polygon A as separating axes
    var j: usize = npolya - 1;
    var i: usize = 0;
    while (i < npolya) : ({j = i; i += 1;}) {
        const va = polya[j * 3 .. j * 3 + 3];
        const vb = polya[i * 3 .. i * 3 + 3];
        const n = [3]f32{ vb[2] - va[2], 0, -(vb[0] - va[0]) };

        var amin: f32 = undefined;
        var amax: f32 = undefined;
        var bmin: f32 = undefined;
        var bmax: f32 = undefined;

        projectPoly(&n, polya, npolya, &amin, &amax);
        projectPoly(&n, polyb, npolyb, &bmin, &bmax);

        if (!overlapRange(amin, amax, bmin, bmax, eps)) {
            // Found separating axis
            return false;
        }
    }

    // Test edges of polygon B as separating axes
    j = npolyb - 1;
    i = 0;
    while (i < npolyb) : ({j = i; i += 1;}) {
        const va = polyb[j * 3 .. j * 3 + 3];
        const vb = polyb[i * 3 .. i * 3 + 3];
        const n = [3]f32{ vb[2] - va[2], 0, -(vb[0] - va[0]) };

        var amin: f32 = undefined;
        var amax: f32 = undefined;
        var bmin: f32 = undefined;
        var bmax: f32 = undefined;

        projectPoly(&n, polya, npolya, &amin, &amax);
        projectPoly(&n, polyb, npolyb, &bmin, &bmax);

        if (!overlapRange(amin, amax, bmin, bmax, eps)) {
            // Found separating axis
            return false;
        }
    }

    // No separating axis found, polygons overlap
    return true;
}
