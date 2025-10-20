const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;

/// Polygon reference type
/// For large worlds (>16×16 km), consider changing to u64 (see documentation)
pub const PolyRef = u32; //                                               ┐
//                                                   should be the same vallues ┤
/// Tile reference type                                                         │
/// For large worlds (>16×16 km), consider changing to u64 (see documentation)  │
pub const TileRef = u32; //                                               ┘

/// Status code for operations
pub const Status = packed struct {
    failure: bool = false,
    success: bool = false,
    in_progress: bool = false,
    wrong_magic: bool = false,
    wrong_version: bool = false,
    out_of_memory: bool = false,
    invalid_param: bool = false,
    buffer_too_small: bool = false,
    out_of_nodes: bool = false,
    partial_result: bool = false,
    already_occupied: bool = false,
    _padding: u21 = 0,

    pub fn isSuccess(self: Status) bool {
        return self.success;
    }

    pub fn isFailure(self: Status) bool {
        return self.failure;
    }

    pub fn isInProgress(self: Status) bool {
        return self.in_progress;
    }

    pub fn ok() Status {
        return .{ .success = true };
    }

    pub fn fail() Status {
        return .{ .failure = true };
    }
};

pub const Error = error{
    Failure,
    WrongMagic,
    WrongVersion,
    OutOfMemory,
    InvalidParam,
    BufferTooSmall,
    OutOfNodes,
    AlreadyOccupied,
};

/// Maximum vertices per polygon
pub const VERTS_PER_POLYGON: usize = 6;

/// Navigation mesh magic and version
pub const NAVMESH_MAGIC: i32 = ('D' << 24) | ('N' << 16) | ('A' << 8) | 'V';
pub const NAVMESH_VERSION: i32 = 7;
pub const NAVMESH_STATE_MAGIC: i32 = ('D' << 24) | ('N' << 16) | ('M' << 8) | 'S';
pub const NAVMESH_STATE_VERSION: i32 = 1;

/// Link flags
pub const EXT_LINK: u16 = 0x8000;
pub const NULL_LINK: u32 = 0xffffffff;
pub const OFFMESH_CON_BIDIR: u32 = 1;

/// Detail triangle edge flags
pub const DETAIL_EDGE_BOUNDARY: u8 = 0x01; // Detail triangle edge is part of the poly boundary

/// Maximum area count
pub const MAX_AREAS: usize = 64;

/// Tile flags
pub const TileFlags = packed struct {
    free_data: bool = false,
    _padding: u31 = 0,
};

/// Straight path flags
/// Straight path flags (vertex classification in findStraightPath)
pub const STRAIGHTPATH_START: u8 = 0x01; // The vertex is the start position
pub const STRAIGHTPATH_END: u8 = 0x02; // The vertex is the end position
pub const STRAIGHTPATH_OFFMESH_CONNECTION: u8 = 0x04; // The vertex is start of off-mesh connection

/// Straight path options (controls what edges to add)
pub const STRAIGHTPATH_AREA_CROSSINGS: u32 = 0x01; // Add vertex at area changes
pub const STRAIGHTPATH_ALL_CROSSINGS: u32 = 0x02; // Add vertex at all polygon edges

/// Polygon types
pub const PolyType = enum(u8) {
    ground = 0,
    offmesh_connection = 1,
};

/// Find path options
pub const FindPathOptions = packed struct {
    any_angle: bool = false,
    _padding: u31 = 0,
};

/// Raycast options
pub const RAYCAST_USE_COSTS: u32 = 0x01; // Calculate movement cost along the ray

// Pathfinding options
pub const FINDPATH_ANY_ANGLE: u32 = 0x02; // Use raycasts during pathfinding to "shortcut" paths

/// Ray cast limit for any-angle pathfinding
pub const RAY_CAST_LIMIT_PROPORTIONS: f32 = 50.0;

/// Calculate 2D triangle area (in XZ plane)
fn triArea2D(a: *const [3]f32, b: *const [3]f32, c: *const [3]f32) f32 {
    const abx = b[0] - a[0];
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const acz = c[2] - a[2];
    return acx * abz - abx * acz;
}

/// Generate a random point in a convex polygon
/// @param pts Array of vertex coordinates (x,y,z triplets)
/// @param npts Number of vertices in polygon
/// @param areas Work buffer for triangle areas (must be at least npts floats)
/// @param s Random value [0..1] for selecting triangle
/// @param t Random value [0..1] for point within triangle
/// @param out Output point [3]f32
pub fn randomPointInConvexPoly(pts: []const f32, npts: i32, areas: []f32, s: f32, t: f32, out: *[3]f32) void {
    // Calculate triangle areas
    var areasum: f32 = 0.0;
    var i: i32 = 2;
    while (i < npts) : (i += 1) {
        const idx = @as(usize, @intCast(i));
        const idx_prev = @as(usize, @intCast(i - 1));
        const p0 = pts[0..3];
        const p1 = pts[idx_prev * 3 .. idx_prev * 3 + 3];
        const p2 = pts[idx * 3 .. idx * 3 + 3];
        areas[idx] = triArea2D(p0[0..3], p1[0..3], p2[0..3]);
        areasum += @max(0.001, areas[idx]);
    }

    // Find sub triangle weighted by area
    const thr = s * areasum;
    var acc: f32 = 0.0;
    var u: f32 = 1.0;
    var tri: i32 = npts - 1;

    i = 2;
    while (i < npts) : (i += 1) {
        const idx = @as(usize, @intCast(i));
        const dacc = areas[idx];
        if (thr >= acc and thr < (acc + dacc)) {
            u = (thr - acc) / dacc;
            tri = i;
            break;
        }
        acc += dacc;
    }

    const v = @sqrt(t);

    const a = 1.0 - v;
    const b = (1.0 - u) * v;
    const c = u * v;

    const tri_usize = @as(usize, @intCast(tri));
    const tri_prev_usize = @as(usize, @intCast(tri - 1));
    const pa = pts[0..3];
    const pb = pts[tri_prev_usize * 3 .. tri_prev_usize * 3 + 3];
    const pc = pts[tri_usize * 3 .. tri_usize * 3 + 3];

    out[0] = a * pa[0] + b * pb[0] + c * pc[0];
    out[1] = a * pa[1] + b * pb[1] + c * pc[1];
    out[2] = a * pa[2] + b * pb[2] + c * pc[2];
}

// ============================================================================
// Tests
// ============================================================================

test "randomPointInConvexPoly - properly works when s is 1.0" {
    const pts = [_]f32{
        0.0, 0.0, 0.0,
        0.0, 0.0, 1.0,
        1.0, 0.0, 0.0,
    };
    const npts: i32 = 3;
    var areas: [6]f32 = undefined;
    var out: [3]f32 = undefined;

    // s=0.0, t=1.0 -> point at (0, 0, 1)
    randomPointInConvexPoly(&pts, npts, &areas, 0.0, 1.0, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[2], 0.001);

    // s=0.5, t=1.0 -> point at (0.5, 0, 0.5)
    randomPointInConvexPoly(&pts, npts, &areas, 0.5, 1.0, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 0.001);

    // s=1.0, t=1.0 -> point at (1, 0, 0)
    randomPointInConvexPoly(&pts, npts, &areas, 1.0, 1.0, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[2], 0.001);
}

/// Get flags for edge in detail triangle
///  @param[in]  tri_flags    The flags for the triangle (last component of detail vertices)
///  @param[in]  edge_index   The index of the first vertex of the edge
/// @return Edge flags
pub inline fn getDetailTriEdgeFlags(tri_flags: u8, edge_index: usize) u8 {
    return @intCast((tri_flags >> @intCast(edge_index * 2)) & 0x3);
}
