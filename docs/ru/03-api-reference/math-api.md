# Math API Reference

Математические утилиты и геометрические функции.

---

## Vec3

3D вектор с операциями.

### Constructors

```zig
pub fn init(x: f32, y: f32, z: f32) Vec3
pub fn zero() Vec3
pub fn fromArray(arr: *const [3]f32) Vec3
```

### Vector Operations

```zig
// Arithmetic
pub fn add(self: Vec3, other: Vec3) Vec3
pub fn sub(self: Vec3, other: Vec3) Vec3
pub fn scale(self: Vec3, s: f32) Vec3
pub fn mad(self: Vec3, other: Vec3, s: f32) Vec3  // self + other * s

// Products
pub fn dot(self: Vec3, other: Vec3) f32
pub fn cross(self: Vec3, other: Vec3) Vec3
pub fn dot2D(self: Vec3, other: Vec3) f32          // XZ plane
pub fn perp2D(self: Vec3, other: Vec3) f32         // XZ plane perpendicular

// Length/Distance
pub fn length(self: Vec3) f32
pub fn lengthSq(self: Vec3) f32
pub fn dist(self: Vec3, other: Vec3) f32
pub fn distSq(self: Vec3, other: Vec3) f32
pub fn dist2D(self: Vec3, other: Vec3) f32         // XZ plane
pub fn dist2DSq(self: Vec3, other: Vec3) f32

// Normalization
pub fn normalize(self: *Vec3) void
pub fn normalized(self: Vec3) Vec3

// Interpolation
pub fn lerp(self: Vec3, other: Vec3, t: f32) Vec3

// Component-wise
pub fn min(self: Vec3, other: Vec3) Vec3
pub fn max(self: Vec3, other: Vec3) Vec3

// Checks
pub fn isFinite(self: Vec3) bool
pub fn equal(self: Vec3, other: Vec3) bool
```

---

## AABB

Axis-aligned bounding box.

```zig
pub const AABB = struct {
    min: Vec3,
    max: Vec3,
};
```

---

## Geometry Functions

### Distance Calculations

```zig
// Point to segment distance (2D)
pub fn distancePtSegSqr2D(
    pt: *const [3]f32,
    p: *const [3]f32,
    q: *const [3]f32,
    t: *f32,
) f32

// Point to line distance (2D)
pub fn distancePtSeg2D(
    pt: *const [3]f32,
    p: *const [3]f32,
    q: *const [3]f32,
) f32
```

### Intersection Tests

```zig
// Segment vs segment intersection (2D)
pub fn intersectSegSeg2D(
    ap: *const [3]f32,
    aq: *const [3]f32,
    bp: *const [3]f32,
    bq: *const [3]f32,
    s: *f32,
    t: *f32,
) bool

// Segment vs polygon intersection (2D)
pub fn intersectSegmentPoly2D(
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    verts: []const f32,
    nverts: usize,
    tmin: *f32,
    tmax: *f32,
    seg_min: *i32,
    seg_max: *i32,
) bool
```

### Point Tests

```zig
// Point in polygon test (2D)
pub fn pointInPolygon(
    pt: *const [3]f32,
    verts: []const f32,
    nverts: usize,
) bool

// Point vs AABB
pub fn overlapBounds(
    amin: *const [3]f32,
    amax: *const [3]f32,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
) bool

// Closest point on polygon
pub fn closestPtPointTriangle(
    p: *const [3]f32,
    a: *const [3]f32,
    b: *const [3]f32,
    c: *const [3]f32,
) [3]f32
```

### Triangle Tests

```zig
// Triangle area (2D)
pub fn triArea2D(
    a: *const [3]f32,
    b: *const [3]f32,
    c: *const [3]f32,
) f32

// Overlap test
pub fn overlapRange(
    amin: f32,
    amax: f32,
    bmin: f32,
    bmax: f32,
    eps: f32,
) bool
```

---

## Utility Functions

### Vector Operations

```zig
// Copy
pub fn vcopy(dest: []f32, src: []const f32) void
pub fn vcopy3(dest: *[3]f32, src: *const [3]f32) void

// Set
pub fn vset(dest: []f32, x: f32, y: f32, z: f32) void

// Min/Max
pub fn vmin(dest: []f32, v: []const f32) void
pub fn vmax(dest: []f32, v: []const f32) void

// Arithmetic
pub fn vadd(dest: []f32, v1: []const f32, v2: []const f32) void
pub fn vsub(dest: []f32, v1: []const f32, v2: []const f32) void
pub fn vscale(dest: []f32, v: []const f32, t: f32) void
pub fn vmad(dest: []f32, v1: []const f32, v2: []const f32, s: f32) void

// Distance
pub fn vdist(v1: []const f32, v2: []const f32) f32
pub fn vdist2D(v1: []const f32, v2: []const f32) f32
pub fn vdistSqr(v1: []const f32, v2: []const f32) f32
pub fn vdist2DSqr(v1: []const f32, v2: []const f32) f32

// Normalization
pub fn vnormalize(v: []f32) void

// Products
pub fn vdot(v1: []const f32, v2: []const f32) f32
pub fn vdot2D(u: []const f32, v: []const f32) f32
pub fn vperp2D(u: []const f32, v: []const f32) f32
pub fn vcross(dest: []f32, v1: []const f32, v2: []const f32) void

// Length
pub fn vlen(v: []const f32) f32
pub fn vlenSqr(v: []const f32) f32

// Interpolation
pub fn vlerp(dest: []f32, v1: []const f32, v2: []const f32, t: f32) void

// Equality
pub fn vequal(v1: []const f32, v2: []const f32) bool
```

---

## Math Utilities

```zig
// Swap
pub fn swap(comptime T: type, a: *T, b: *T) void

// Clamp
pub fn clamp(v: f32, min_val: f32, max_val: f32) f32

// Square
pub fn sqr(a: f32) f32

// Next power of 2
pub fn nextPow2(v: u32) u32
pub fn ilog2(v: u32) u32

// Min/Max
pub fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a)
pub fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a)
```

---

## Examples

### Vector Math

```zig
const math = @import("zig-recast").math;

// Create vectors
const v1 = math.Vec3.init(1.0, 2.0, 3.0);
const v2 = math.Vec3.init(4.0, 5.0, 6.0);

// Operations
const sum = v1.add(v2);
const dot_product = v1.dot(v2);
const cross_product = v1.cross(v2);

// Distance
const distance = v1.dist(v2);
const distance_2d = v1.dist2D(v2);  // XZ plane only

// Normalize
var v3 = math.Vec3.init(3.0, 4.0, 0.0);
v3.normalize();  // Now length = 1.0
```

### Point Tests

```zig
// Point in polygon
const point = [3]f32{ 5.0, 0.0, 5.0 };
const polygon = [_]f32{
    0.0, 0.0, 0.0,
    10.0, 0.0, 0.0,
    10.0, 0.0, 10.0,
    0.0, 0.0, 10.0,
};

const inside = math.pointInPolygon(&point, &polygon, 4);
```

### Intersection

```zig
// Segment intersection
var s: f32 = undefined;
var t: f32 = undefined;

const intersects = math.intersectSegSeg2D(
    &[3]f32{ 0, 0, 0 },
    &[3]f32{ 10, 0, 0 },
    &[3]f32{ 5, 0, -5 },
    &[3]f32{ 5, 0, 5 },
    &s,
    &t,
);

if (intersects) {
    // s and t contain intersection parameters
}
```

---

## Constants

```zig
pub const PI: f32 = 3.14159265;
pub const EPS: f32 = 1e-4;
```

---

## See Also

- 📖 [Recast API](recast-api.md)
- 📖 [Detour API](detour-api.md)
- 🏗️ [Architecture](../02-architecture/overview.md)
