const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;

/// Polygon reference type
pub const PolyRef = u32;

/// Tile reference type
pub const TileRef = u32;

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
