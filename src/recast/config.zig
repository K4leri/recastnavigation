const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;

/// Configuration for Recast navmesh building
pub const Config = struct {
    /// The width of the field along the x-axis (in voxels)
    width: i32 = 0,

    /// The height of the field along the z-axis (in voxels)
    height: i32 = 0,

    /// The width/height size of tiles on the xz-plane (in voxels)
    tile_size: i32 = 0,

    /// The size of the non-navigable border around the heightfield (in voxels)
    border_size: i32 = 0,

    /// The xz-plane cell size (in world units)
    cs: f32 = 0.3,

    /// The y-axis cell size (in world units)
    ch: f32 = 0.2,

    /// The minimum bounds of the field's AABB (in world units)
    bmin: Vec3 = Vec3.zero(),

    /// The maximum bounds of the field's AABB (in world units)
    bmax: Vec3 = Vec3.zero(),

    /// The maximum slope that is considered walkable (in degrees, 0-90)
    walkable_slope_angle: f32 = 45.0,

    /// Minimum floor to ceiling height that allows floor to be walkable (in voxels, >= 3)
    walkable_height: i32 = 20,

    /// Maximum ledge height that is still traversable (in voxels, >= 0)
    walkable_climb: i32 = 9,

    /// The distance to erode/shrink walkable area from obstructions (in voxels, >= 0)
    walkable_radius: i32 = 8,

    /// Maximum allowed length for contour edges along border (in voxels, >= 0)
    max_edge_len: i32 = 12,

    /// Maximum distance contour's border can deviate from raw contour (in voxels, >= 0)
    max_simplification_error: f32 = 1.3,

    /// Minimum number of cells to form isolated island areas (in voxels, >= 0)
    min_region_area: i32 = 8,

    /// Regions smaller than this will be merged with larger regions (in voxels, >= 0)
    merge_region_area: i32 = 20,

    /// Maximum vertices allowed per polygon (>= 3)
    max_verts_per_poly: i32 = 6,

    /// Sampling distance for detail mesh (in world units, 0 or >= 0.9)
    detail_sample_dist: f32 = 6.0,

    /// Maximum distance detail mesh surface can deviate from heightfield (in world units, >= 0)
    detail_sample_max_error: f32 = 1.0,

    pub fn calcBounds(verts: []const Vec3, min_bounds: *Vec3, max_bounds: *Vec3) void {
        if (verts.len == 0) return;

        min_bounds.* = verts[0];
        max_bounds.* = verts[0];

        for (verts[1..]) |v| {
            min_bounds.* = min_bounds.min(v);
            max_bounds.* = max_bounds.max(v);
        }
    }

    pub fn calcGridSize(min_bounds: Vec3, max_bounds: Vec3, cell_size: f32, size_x: *i32, size_z: *i32) void {
        size_x.* = @intFromFloat(@ceil((max_bounds.x - min_bounds.x) / cell_size));
        size_z.* = @intFromFloat(@ceil((max_bounds.z - min_bounds.z) / cell_size));
    }
};

/// Area IDs for navigation mesh polygons
pub const AreaId = struct {
    pub const NULL_AREA: u8 = 0;
    pub const WALKABLE_AREA: u8 = 63;
};

/// Constants for heightfield
pub const SPAN_HEIGHT_BITS: u5 = 13;
pub const SPAN_MAX_HEIGHT: u32 = (1 << SPAN_HEIGHT_BITS) - 1;
pub const SPANS_PER_POOL: usize = 2048;

/// Border and connection flags
pub const BORDER_REG: u16 = 0x8000;
pub const MULTIPLE_REGS: u16 = 0;
pub const BORDER_VERTEX: u32 = 0x10000;
pub const AREA_BORDER: u32 = 0x20000;
pub const CONTOUR_REG_MASK: u32 = 0xffff;
pub const MESH_NULL_IDX: u16 = 0xffff;
pub const NOT_CONNECTED: u8 = 0x3f;

/// Build contours flag constants
pub const CONTOUR_TESS_WALL_EDGES: i32 = 0x01;
pub const CONTOUR_TESS_AREA_EDGES: i32 = 0x02;

/// Build contours flags
pub const BuildContoursFlags = packed struct {
    tess_wall_edges: bool = false,
    tess_area_edges: bool = false,
};

// ============================================================================
// Tests
// ============================================================================

test "calcGridSize - computes grid dimensions" {
    const verts = [_]Vec3{
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(0.0, 2.0, 6.0),
    };

    var bmin: Vec3 = undefined;
    var bmax: Vec3 = undefined;
    Config.calcBounds(&verts, &bmin, &bmax);

    const cell_size: f32 = 1.5;
    var width: i32 = undefined;
    var height: i32 = undefined;

    Config.calcGridSize(bmin, bmax, cell_size, &width, &height);

    try std.testing.expectEqual(@as(i32, 1), width);
    try std.testing.expectEqual(@as(i32, 2), height);
}
