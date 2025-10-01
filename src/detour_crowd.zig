// DetourCrowd module - Crowd simulation and agent management
pub const path_corridor = @import("detour_crowd/path_corridor.zig");
pub const local_boundary = @import("detour_crowd/local_boundary.zig");
pub const proximity_grid = @import("detour_crowd/proximity_grid.zig");
pub const path_queue = @import("detour_crowd/path_queue.zig");
pub const obstacle_avoidance = @import("detour_crowd/obstacle_avoidance.zig");
pub const crowd = @import("detour_crowd/crowd.zig");

// Re-export commonly used types
pub const PathCorridor = path_corridor.PathCorridor;
pub const LocalBoundary = local_boundary.LocalBoundary;
pub const ProximityGrid = proximity_grid.ProximityGrid;
pub const PathQueue = path_queue.PathQueue;
pub const PathQueueRef = path_queue.PathQueueRef;
pub const INVALID_QUEUE_REF = path_queue.INVALID_QUEUE_REF;
pub const ObstacleAvoidanceQuery = obstacle_avoidance.ObstacleAvoidanceQuery;
pub const ObstacleAvoidanceParams = obstacle_avoidance.ObstacleAvoidanceParams;
pub const ObstacleAvoidanceDebugData = obstacle_avoidance.ObstacleAvoidanceDebugData;
pub const ObstacleCircle = obstacle_avoidance.ObstacleCircle;
pub const ObstacleSegment = obstacle_avoidance.ObstacleSegment;
pub const Crowd = crowd.Crowd;
pub const CrowdAgent = crowd.CrowdAgent;
pub const CrowdAgentParams = crowd.CrowdAgentParams;
pub const CrowdNeighbour = crowd.CrowdNeighbour;
pub const CrowdAgentState = crowd.CrowdAgentState;
pub const MoveRequestState = crowd.MoveRequestState;
pub const UpdateFlags = crowd.UpdateFlags;

test {
    @import("std").testing.refAllDecls(@This());
}
