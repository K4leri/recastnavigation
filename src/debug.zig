/// Debug utilities for visualization and export

pub const debug_draw = @import("debug/debug_draw.zig");
pub const recast_debug = @import("debug/recast_debug.zig");
pub const detour_debug = @import("debug/detour_debug.zig");
pub const dump = @import("debug/dump.zig");

// Re-export commonly used types
pub const DebugDraw = debug_draw.DebugDraw;
pub const DebugDrawPrimitives = debug_draw.DebugDrawPrimitives;

// Color helpers
pub const rgba = debug_draw.rgba;
pub const rgbaf = debug_draw.rgbaf;
pub const intToCol = debug_draw.intToCol;
pub const intToColF = debug_draw.intToColF;
pub const multCol = debug_draw.multCol;
pub const darkenCol = debug_draw.darkenCol;
pub const lerpCol = debug_draw.lerpCol;
pub const transCol = debug_draw.transCol;
pub const calcBoxColors = debug_draw.calcBoxColors;

// Geometric drawing helpers
pub const appendArc = debug_draw.appendArc;
pub const appendCircle = debug_draw.appendCircle;
pub const appendCross = debug_draw.appendCross;
pub const appendBox = debug_draw.appendBox;
pub const appendCylinder = debug_draw.appendCylinder;

// Recast debug functions
pub const debugDrawHeightfieldSolid = recast_debug.debugDrawHeightfieldSolid;
pub const debugDrawHeightfieldWalkable = recast_debug.debugDrawHeightfieldWalkable;
pub const debugDrawCompactHeightfieldSolid = recast_debug.debugDrawCompactHeightfieldSolid;
pub const debugDrawCompactHeightfieldRegions = recast_debug.debugDrawCompactHeightfieldRegions;
pub const debugDrawCompactHeightfieldDistance = recast_debug.debugDrawCompactHeightfieldDistance;
pub const debugDrawHeightfieldLayer = recast_debug.debugDrawHeightfieldLayer;
pub const debugDrawHeightfieldLayers = recast_debug.debugDrawHeightfieldLayers;
pub const debugDrawHeightfieldLayersRegions = recast_debug.debugDrawHeightfieldLayersRegions;
pub const debugDrawRegionConnections = recast_debug.debugDrawRegionConnections;
pub const debugDrawRawContours = recast_debug.debugDrawRawContours;
pub const debugDrawContours = recast_debug.debugDrawContours;
pub const debugDrawPolyMesh = recast_debug.debugDrawPolyMesh;
pub const debugDrawPolyMeshDetail = recast_debug.debugDrawPolyMeshDetail;

// Detour debug functions
pub const DrawNavMeshFlags = detour_debug.DrawNavMeshFlags;
pub const debugDrawNavMesh = detour_debug.debugDrawNavMesh;
pub const debugDrawNavMeshWithClosedList = detour_debug.debugDrawNavMeshWithClosedList;
pub const debugDrawNavMeshNodes = detour_debug.debugDrawNavMeshNodes;
pub const debugDrawNavMeshBVTree = detour_debug.debugDrawNavMeshBVTree;
pub const debugDrawNavMeshPortals = detour_debug.debugDrawNavMeshPortals;
pub const debugDrawNavMeshPolysWithFlags = detour_debug.debugDrawNavMeshPolysWithFlags;
pub const debugDrawNavMeshPoly = detour_debug.debugDrawNavMeshPoly;

// Dump/export functions
pub const FileIO = dump.FileIO;
pub const StdFileIO = dump.StdFileIO;
pub const dumpPolyMeshToObj = dump.dumpPolyMeshToObj;
pub const dumpPolyMeshDetailToObj = dump.dumpPolyMeshDetailToObj;
pub const logBuildTimes = dump.logBuildTimes;
