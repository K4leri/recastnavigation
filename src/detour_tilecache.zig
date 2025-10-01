// DetourTileCache - Dynamic obstacle support for navigation meshes
//
// This module provides compressed tile storage and dynamic obstacle management
// for Detour navigation meshes. It allows adding/removing obstacles at runtime
// and incrementally rebuilding affected tiles.

pub const builder = @import("detour_tilecache/builder.zig");
pub const tilecache = @import("detour_tilecache/tilecache.zig");

// Re-export main types
pub const TileCache = tilecache.TileCache;
pub const TileCacheParams = tilecache.TileCacheParams;
pub const TileCacheObstacle = tilecache.TileCacheObstacle;
pub const CompressedTile = tilecache.CompressedTile;
pub const CompressedTileRef = tilecache.CompressedTileRef;
pub const ObstacleRef = tilecache.ObstacleRef;
pub const ObstacleState = tilecache.ObstacleState;
pub const ObstacleType = tilecache.ObstacleType;
pub const ObstacleCylinder = tilecache.ObstacleCylinder;
pub const ObstacleBox = tilecache.ObstacleBox;
pub const ObstacleOrientedBox = tilecache.ObstacleOrientedBox;
pub const CompressedTileFlags = tilecache.CompressedTileFlags;
pub const TileCacheMeshProcess = tilecache.TileCacheMeshProcess;

// Re-export builder types
pub const TileCacheLayerHeader = builder.TileCacheLayerHeader;
pub const TileCacheLayer = builder.TileCacheLayer;
pub const TileCacheContour = builder.TileCacheContour;
pub const TileCacheContourSet = builder.TileCacheContourSet;
pub const TileCachePolyMesh = builder.TileCachePolyMesh;
pub const TileCacheCompressor = builder.TileCacheCompressor;

// Re-export builder constants
pub const TILECACHE_MAGIC = builder.TILECACHE_MAGIC;
pub const TILECACHE_VERSION = builder.TILECACHE_VERSION;
pub const TILECACHE_NULL_AREA = builder.TILECACHE_NULL_AREA;
pub const TILECACHE_WALKABLE_AREA = builder.TILECACHE_WALKABLE_AREA;
pub const TILECACHE_NULL_IDX = builder.TILECACHE_NULL_IDX;

// Re-export builder functions
pub const buildTileCacheRegions = builder.buildTileCacheRegions;
pub const buildTileCacheContours = builder.buildTileCacheContours;
pub const buildTileCachePolyMesh = builder.buildTileCachePolyMesh;
pub const decompressTileCacheLayer = builder.decompressTileCacheLayer;
pub const buildTileCacheLayer = builder.buildTileCacheLayer;
pub const allocTileCacheContourSet = builder.allocTileCacheContourSet;
pub const freeTileCacheContourSet = builder.freeTileCacheContourSet;
pub const allocTileCachePolyMesh = builder.allocTileCachePolyMesh;
pub const freeTileCachePolyMesh = builder.freeTileCachePolyMesh;
pub const freeTileCacheLayer = builder.freeTileCacheLayer;
pub const markCylinderArea = builder.markCylinderArea;
pub const markBoxArea = builder.markBoxArea;
pub const markOrientedBoxArea = builder.markOrientedBoxArea;
