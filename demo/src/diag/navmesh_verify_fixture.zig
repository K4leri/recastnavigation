//! Test fixture for navmesh_verify: builds a REAL two-tile Detour navmesh from
//! two adjacent coplanar quads that stitch across their shared border (so the
//! mesh has genuine cross-tile portal links — exactly what the freelist /
//! portal-symmetry / salt invariants exercise).
//!
//! The build recipe is the same one the `removetile_link_leak_test.zig`
//! regression test uses (tiled build with border_size so buildPolyMesh tags the
//! tile-border edges as portals, walkable_radius = 0 to keep edges on the
//! border). This module exists only so the verifier's highest-value unit test
//! can assert verify() == ok on actual Detour data. Test-only.

const std = @import("std");
const nav = @import("recast-nav");

const TILE_SIZE: f32 = 6.0; // world units per tile (20 cells @ cs=0.3)

/// A built two-tile navmesh plus the tile-data buffers it borrows (free_data =
/// false, so the fixture owns and frees them). Call `deinit` to release both.
pub const TwoTile = struct {
    navmesh: nav.detour.NavMesh,
    data0: []u8,
    data1: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TwoTile) void {
        self.navmesh.deinit();
        self.allocator.free(self.data0);
        self.allocator.free(self.data1);
    }
};

/// Build the two-tile fixture. Caller owns the result -> `deinit`.
pub fn buildTwoTile(allocator: std.mem.Allocator) !TwoTile {
    const data0 = try buildFlatTile(allocator, 0, 0);
    errdefer allocator.free(data0);
    const data1 = try buildFlatTile(allocator, 1, 0);
    errdefer allocator.free(data1);

    const nm_params = nav.detour.NavMeshParams{
        .orig = nav.Vec3.init(0, 0, 0),
        .tile_width = TILE_SIZE,
        .tile_height = TILE_SIZE,
        .max_tiles = 8,
        .max_polys = 256,
    };

    var navmesh = try nav.detour.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    const flags = nav.detour.TileFlags{ .free_data = false };
    _ = try navmesh.addTile(data0, flags, 0);
    _ = try navmesh.addTile(data1, flags, 0);

    return .{ .navmesh = navmesh, .data0 = data0, .data1 = data1, .allocator = allocator };
}

/// Build a single flat-quad tile at grid coords (tx, tz) filling the whole tile
/// cell so its outer edges land on the tile border and become portal edges.
/// (Lifted from removetile_link_leak_test.zig's buildFlatTile.)
fn buildFlatTile(allocator: std.mem.Allocator, tx: i32, tz: i32) ![]u8 {
    var ctx = nav.Context.init(allocator);

    const ox = @as(f32, @floatFromInt(tx)) * TILE_SIZE;
    const oz = @as(f32, @floatFromInt(tz)) * TILE_SIZE;

    const cs: f32 = 0.3;
    const border: i32 = 4;
    const pad: f32 = @as(f32, @floatFromInt(border)) * cs;

    var config = nav.RecastConfig{
        .cs = cs,
        .ch = 0.2,
        .walkable_slope_angle = 45.0,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 0,
        .max_edge_len = 12,
        .max_simplification_error = 1.3,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .border_size = border,
        .width = 0,
        .height = 0,
        .bmin = nav.Vec3.init(ox - pad, -1.0, oz - pad),
        .bmax = nav.Vec3.init(ox + TILE_SIZE + pad, 1.0, oz + TILE_SIZE + pad),
    };

    var size_x: i32 = 0;
    var size_z: i32 = 0;
    nav.RecastConfig.calcGridSize(config.bmin, config.bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

    var heightfield = try nav.Heightfield.init(
        allocator,
        config.width,
        config.height,
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
    );
    defer heightfield.deinit();

    const x0 = config.bmin.x;
    const x1 = config.bmax.x;
    const z0 = config.bmin.z;
    const z1 = config.bmax.z;
    const verts = [_]f32{
        x0, 0.0, z0,
        x1, 0.0, z0,
        x1, 0.0, z1,
        x0, 0.0, z1,
    };
    const indices = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 1, 1 };

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        &verts,
        &indices,
        &areas,
        &heightfield,
        config.walkable_climb,
    );

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    var chf = try nav.CompactHeightfield.init(
        allocator,
        config.width,
        config.height,
        @intCast(span_count),
        config.walkable_height,
        config.walkable_climb,
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
        config.border_size,
    );
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(
        &ctx,
        config.walkable_height,
        config.walkable_climb,
        &heightfield,
        &chf,
    );

    try nav.recast.area.erodeWalkableArea(&ctx, config.walkable_radius, &chf, allocator);
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, config.border_size, config.min_region_area, config.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(
        &ctx,
        &chf,
        config.max_simplification_error,
        config.max_edge_len,
        &cset,
        0,
        allocator,
    );

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(config.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(
        &ctx,
        &pmesh,
        &chf,
        config.detail_sample_dist,
        config.detail_sample_max_error,
        &dmesh,
        allocator,
    );

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01);

    const params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(config.walkable_height)) * config.ch,
        .walkable_radius = @as(f32, @floatFromInt(config.walkable_radius)) * config.cs,
        .walkable_climb = @as(f32, @floatFromInt(config.walkable_climb)) * config.ch,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .build_bv_tree = true,
        .tile_x = tx,
        .tile_y = tz,
    };

    return try nav.detour.createNavMeshData(&params, allocator);
}
