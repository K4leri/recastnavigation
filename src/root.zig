const std = @import("std");

/// Mathematical utilities and types
pub const math = @import("math.zig");

/// Build context for logging and timers
pub const context = @import("context.zig");

/// Recast - Navigation mesh construction
pub const recast = @import("recast.zig");

/// Detour - Navigation mesh queries and pathfinding
pub const detour = @import("detour.zig");

/// DetourCrowd - Crowd simulation and agent management
pub const detour_crowd = @import("detour_crowd.zig");

/// DetourTileCache - Dynamic obstacle support for navigation meshes
pub const detour_tilecache = @import("detour_tilecache.zig");

// Re-export commonly used types for convenience
pub const Vec3 = math.Vec3;
pub const AABB = math.AABB;
pub const Context = context.Context;

// Recast types
pub const RecastConfig = recast.Config;
pub const Heightfield = recast.Heightfield;
pub const CompactHeightfield = recast.CompactHeightfield;
pub const PolyMesh = recast.PolyMesh;
pub const PolyMeshDetail = recast.PolyMeshDetail;
pub const ContourSet = recast.ContourSet;

// Detour types
pub const NavMesh = detour.NavMesh;
pub const NavMeshParams = detour.NavMeshParams;
pub const NavMeshQuery = detour.NavMeshQuery;
pub const QueryFilter = detour.QueryFilter;
pub const PolyRef = detour.PolyRef;
pub const Status = detour.Status;

// DetourCrowd types
pub const PathCorridor = detour_crowd.PathCorridor;
pub const LocalBoundary = detour_crowd.LocalBoundary;
pub const ProximityGrid = detour_crowd.ProximityGrid;
pub const PathQueue = detour_crowd.PathQueue;
pub const PathQueueRef = detour_crowd.PathQueueRef;
pub const ObstacleAvoidanceQuery = detour_crowd.ObstacleAvoidanceQuery;
pub const ObstacleAvoidanceParams = detour_crowd.ObstacleAvoidanceParams;
pub const ObstacleAvoidanceDebugData = detour_crowd.ObstacleAvoidanceDebugData;
pub const Crowd = detour_crowd.Crowd;
pub const CrowdAgent = detour_crowd.CrowdAgent;
pub const CrowdAgentParams = detour_crowd.CrowdAgentParams;
pub const UpdateFlags = detour_crowd.UpdateFlags;

// DetourTileCache types
pub const TileCache = detour_tilecache.TileCache;
pub const TileCacheParams = detour_tilecache.TileCacheParams;
pub const TileCacheObstacle = detour_tilecache.TileCacheObstacle;
pub const CompressedTile = detour_tilecache.CompressedTile;
pub const ObstacleRef = detour_tilecache.ObstacleRef;
pub const TileCacheCompressor = detour_tilecache.TileCacheCompressor;

test {
    std.testing.refAllDecls(@This());
}

// Library version
pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 1;
pub const VERSION_PATCH = 0;

pub fn version() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}", .{
        VERSION_MAJOR,
        VERSION_MINOR,
        VERSION_PATCH,
    });
}
