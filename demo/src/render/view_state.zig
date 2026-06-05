//! Live VIEW state (cluster E, P1-1): wireframe toggle + per-group visibility.
//! Global so the Properties UI (main.zig) and the sample render paths
//! (sample_*.zig) share one source of truth without threading flags through every
//! call — mirrors scheme_state.zig / filter_state.zig. Defaults reproduce the
//! original look exactly (wireframe off, every group visible).

/// When true the navmesh renders as edges only (outline pass), no filled tris.
/// Routed through poly_visit.outlineNavMesh so it works with a clip/iso filter
/// active or inactive.
pub var wireframe: bool = false;

/// Per-group visibility. Each sample gates its corresponding scene draw on these.
pub const Groups = struct {
    input_mesh: bool = true, // input geometry triangles
    navmesh: bool = true, // navmesh fill/outline (faithful/filtered/wireframe)
    offmesh: bool = true, // off-mesh connections (g.drawOffMeshConnections)
    convex: bool = true, // convex volumes (g.drawConvexVolumes)
    labels: bool = true, // worldspace text labels (agents/tests/etc.)
};

pub var groups: Groups = .{};
