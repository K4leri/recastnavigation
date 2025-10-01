// Detour module - Navigation mesh queries and pathfinding
pub const common = @import("detour/common.zig");
pub const navmesh = @import("detour/navmesh.zig");
pub const builder = @import("detour/builder.zig");
pub const query = @import("detour/query.zig");

// Re-export commonly used types
pub const PolyRef = common.PolyRef;
pub const TileRef = common.TileRef;
pub const Status = common.Status;
pub const Error = common.Error;

pub const Poly = navmesh.Poly;
pub const PolyDetail = navmesh.PolyDetail;
pub const Link = navmesh.Link;
pub const BVNode = navmesh.BVNode;
pub const OffMeshConnection = navmesh.OffMeshConnection;
pub const MeshHeader = navmesh.MeshHeader;
pub const MeshTile = navmesh.MeshTile;
pub const NavMesh = navmesh.NavMesh;
pub const NavMeshParams = navmesh.NavMeshParams;

pub const NavMeshCreateParams = builder.NavMeshCreateParams;
pub const createNavMeshData = builder.createNavMeshData;

pub const QueryFilter = query.QueryFilter;
pub const RaycastHit = query.RaycastHit;
pub const Node = query.Node;
pub const NodePool = query.NodePool;
pub const NodeQueue = query.NodeQueue;
pub const NavMeshQuery = query.NavMeshQuery;

// Re-export constants
pub const VERTS_PER_POLYGON = common.VERTS_PER_POLYGON;
pub const MAX_AREAS = common.MAX_AREAS;
pub const NULL_LINK = common.NULL_LINK;
pub const NAVMESH_MAGIC = common.NAVMESH_MAGIC;
pub const NAVMESH_VERSION = common.NAVMESH_VERSION;

pub const PolyType = common.PolyType;
pub const TileFlags = common.TileFlags;
pub const FindPathOptions = common.FindPathOptions;

// Straight path constants
pub const STRAIGHTPATH_START = common.STRAIGHTPATH_START;
pub const STRAIGHTPATH_END = common.STRAIGHTPATH_END;
pub const STRAIGHTPATH_OFFMESH_CONNECTION = common.STRAIGHTPATH_OFFMESH_CONNECTION;
pub const STRAIGHTPATH_AREA_CROSSINGS = common.STRAIGHTPATH_AREA_CROSSINGS;
pub const STRAIGHTPATH_ALL_CROSSINGS = common.STRAIGHTPATH_ALL_CROSSINGS;

// Raycast constants
pub const RAYCAST_USE_COSTS = common.RAYCAST_USE_COSTS;

test {
    @import("std").testing.refAllDecls(@This());
}
