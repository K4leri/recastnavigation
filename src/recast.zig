// Recast module - Navigation mesh construction
pub const config = @import("recast/config.zig");
pub const heightfield = @import("recast/heightfield.zig");
pub const polymesh = @import("recast/polymesh.zig");
pub const rasterization = @import("recast/rasterization.zig");
pub const filter = @import("recast/filter.zig");
pub const compact = @import("recast/compact.zig");
pub const area = @import("recast/area.zig");
pub const region = @import("recast/region.zig");
pub const contour = @import("recast/contour.zig");
pub const mesh = @import("recast/mesh.zig");
pub const detail = @import("recast/detail.zig");
pub const layers = @import("recast/layers.zig");

// Re-export commonly used types
pub const Config = config.Config;
pub const Heightfield = heightfield.Heightfield;
pub const CompactHeightfield = heightfield.CompactHeightfield;
pub const Span = heightfield.Span;
pub const CompactSpan = heightfield.CompactSpan;
pub const CompactCell = heightfield.CompactCell;
pub const Contour = polymesh.Contour;
pub const ContourSet = polymesh.ContourSet;
pub const PolyMesh = polymesh.PolyMesh;
pub const PolyMeshDetail = polymesh.PolyMeshDetail;
pub const HeightfieldLayer = polymesh.HeightfieldLayer;
pub const HeightfieldLayerSet = polymesh.HeightfieldLayerSet;

// Re-export constants
pub const AreaId = config.AreaId;
pub const BORDER_REG = config.BORDER_REG;
pub const MESH_NULL_IDX = config.MESH_NULL_IDX;
pub const NOT_CONNECTED = config.NOT_CONNECTED;

test {
    @import("std").testing.refAllDecls(@This());
}
