//! Repro test for the "off-mesh path lost after Scene save/load" bug.
//!
//! Scenario (deterministic, no GUI):
//!   1. Build an InputGeom of two disconnected floor quads (gap between them) and
//!      add an off-mesh connection (area=jump, flags=jump) bridging the gap.
//!   2. Build a Detour navmesh from that geom (mirrors sample_solo:503-509 — the
//!      off_mesh_con_* parallel arrays are wired into NavMeshCreateParams) and run
//!      findPath A->B. Baseline: the path MUST traverse the off-mesh poly.
//!   3. Simulate Scene save/load: serialize the off-mesh via scene_io
//!      (writeGsetText + encodeOffMesh) and restore into a FRESH geom exactly like
//!      scene_container.loadScene does (readGsetText FIRST, then decodeOffMesh which
//!      clears + re-appends). Rebuild the navmesh and run findPath again.
//!   4. The restored path MUST still traverse the off-mesh. If it does not, the bug
//!      lives in serialization/restore; if it passes here, the bug is GUI-specific.

const std = @import("std");
const recast = @import("recast-nav");
const input_geom = @import("../input_geom.zig");
const scene_io = @import("scene_io.zig");
const sample = @import("../sample.zig");

const InputGeom = input_geom.InputGeom;
const rc = recast.recast;
const dt = recast.detour;

const PF = sample.SamplePolyFlags;
const PA = sample.SamplePolyAreas;

/// Two 8x10 quads with a gap [8,14] (no shared edge), like examples/06.
fn buildTwoQuadGeom(alloc: std.mem.Allocator) !InputGeom {
    var g = InputGeom.init(alloc);
    errdefer g.deinit();
    const verts = [_]f32{
        0,  0, 0,
        8,  0, 0,
        8,  0, 10,
        0,  0, 10,
        14, 0, 0,
        22, 0, 0,
        22, 0, 10,
        14, 0, 10,
    };
    // Winding chosen so each triangle's normal points UP (+y): markWalkableTriangles
    // computes the face normal and only marks faces with norm.y above the slope
    // threshold, so a flat floor must wind such that the up-normal is positive.
    const tris = [_]i32{
        0, 2, 1, 0, 3, 2,
        4, 6, 5, 4, 7, 6,
    };
    try g.setMesh(&verts, &tris);
    return g;
}

/// Build a Detour navmesh from `geom`, wiring off-mesh connections EXACTLY like
/// sample_solo.zig:503-509. Returns navmesh + owned data + query (caller frees).
const Built = struct {
    // NavMesh is HEAP-BOXED: the query holds a `*const NavMesh` from initQuery, so the
    // navmesh's address must stay stable after buildNavmesh returns (returning it by
    // value would move it and dangle the query's pointer).
    navmesh: *dt.NavMesh,
    data: []u8,
    query: *dt.NavMeshQuery,
    off_mesh_poly_count: i32,

    fn deinit(self: *Built, alloc: std.mem.Allocator) void {
        self.query.deinit();
        self.navmesh.deinit();
        alloc.destroy(self.navmesh);
        alloc.free(self.data);
    }
};

fn buildNavmesh(alloc: std.mem.Allocator, geom: *InputGeom) !Built {
    var ctx = recast.Context.init(alloc);

    const verts = geom.verts.items;
    const tris = geom.tris.items;
    const ntris = geom.triCount();

    var bmin = recast.math.Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]);
    var bmax = recast.math.Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]);
    bmin.y -= 1.0;
    bmax.y += 1.0;

    const cs: f32 = 0.3;
    const ch: f32 = 0.2;
    const walkable_height: i32 = 10;
    const walkable_climb: i32 = 4;
    const walkable_radius: i32 = 2;
    const border_size: i32 = 0;

    var size_x: i32 = 0;
    var size_z: i32 = 0;
    recast.RecastConfig.calcGridSize(bmin, bmax, cs, &size_x, &size_z);

    var hf = try recast.Heightfield.init(alloc, size_x, size_z, bmin, bmax, cs, ch);
    defer hf.deinit();

    const areas = try alloc.alloc(u8, ntris);
    defer alloc.free(areas);
    @memset(areas, rc.config.AreaId.NULL_AREA);
    rc.filter.markWalkableTriangles(&ctx, 45.0, verts, tris, areas);
    try rc.rasterization.rasterizeTriangles(&ctx, verts, tris, areas, &hf, walkable_climb);
    rc.filter.filterLowHangingWalkableObstacles(&ctx, walkable_climb, &hf);
    rc.filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);
    rc.filter.filterWalkableLowHeightSpans(&ctx, walkable_height, &hf);

    const span_count = rc.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = try recast.CompactHeightfield.init(alloc, size_x, size_z, @intCast(span_count), walkable_height, walkable_climb, bmin, bmax, cs, ch, border_size);
    defer chf.deinit();
    try rc.compact.buildCompactHeightfield(&ctx, walkable_height, walkable_climb, &hf, &chf);
    try rc.area.erodeWalkableArea(&ctx, walkable_radius, &chf, alloc);

    try rc.region.buildDistanceField(&ctx, &chf, alloc);
    try rc.region.buildRegions(&ctx, &chf, border_size, 8, 20, alloc);

    var cset = recast.ContourSet.init(alloc);
    defer cset.deinit();
    try rc.contour.buildContours(&ctx, &chf, 1.3, 12, &cset, 0, alloc);

    var pmesh = recast.PolyMesh.init(alloc);
    defer pmesh.deinit();
    try rc.mesh.buildPolyMesh(&ctx, &cset, 6, &pmesh, alloc);

    var dmesh = recast.PolyMeshDetail.init(alloc);
    defer dmesh.deinit();
    try rc.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, 6.0, 1.0, &dmesh, alloc);

    // poly flags from the area registry (mirrors sample_solo step 8).
    const area_types = @import("../area_types.zig");
    const npolys: usize = pmesh.polyCount();
    const poly_flags = try alloc.alloc(u16, npolys);
    defer alloc.free(poly_flags);
    for (0..npolys) |i| {
        if (pmesh.areas[i] == rc.config.AreaId.WALKABLE_AREA or area_types.get(pmesh.areas[i]) == null) {
            pmesh.areas[i] = @intFromEnum(PA.ground);
        }
        poly_flags[i] = area_types.flagsFor(pmesh.areas[i]);
    }

    const has_off = geom.offMeshCount() > 0;
    const params = dt.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = pmesh.vertCount(),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas,
        .poly_count = pmesh.polyCount(),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = dmesh.vertCount(),
        .detail_tris = dmesh.tris,
        .detail_tri_count = dmesh.triCount(),
        .bmin = .{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = .{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(walkable_climb)) * ch,
        .cs = pmesh.cs,
        .ch = pmesh.ch,
        .off_mesh_con_verts = if (has_off) geom.off_verts.items else null,
        .off_mesh_con_rad = if (has_off) geom.off_rad.items else null,
        .off_mesh_con_flags = if (has_off) geom.off_flags.items else null,
        .off_mesh_con_areas = if (has_off) geom.off_area.items else null,
        .off_mesh_con_dir = if (has_off) geom.off_dir.items else null,
        .off_mesh_con_user_id = if (has_off) geom.off_id.items else null,
        .off_mesh_con_count = geom.offMeshCount(),
        .build_bv_tree = true,
    };

    const data = try dt.createNavMeshData(&params, alloc);
    errdefer alloc.free(data);

    const navmesh = try alloc.create(dt.NavMesh);
    errdefer alloc.destroy(navmesh);
    navmesh.* = try dt.NavMesh.init(alloc, .{
        .orig = bmin,
        .tile_width = bmax.x - bmin.x,
        .tile_height = bmax.z - bmin.z,
        .max_tiles = 1,
        .max_polys = 256,
    });
    errdefer navmesh.deinit();
    _ = try navmesh.addTile(data, dt.TileFlags{ .free_data = false }, 0);

    const tile = navmesh.getTileAt(0, 0, 0).?;
    const off_count: i32 = tile.header.?.off_mesh_con_count;

    const query = try dt.NavMeshQuery.init(alloc);
    errdefer query.deinit();
    try query.initQuery(navmesh, 2048);

    return .{ .navmesh = navmesh, .data = data, .query = query, .off_mesh_poly_count = off_count };
}

/// Returns true if findPath A->B reaches B AND a straight-path waypoint is flagged
/// as an off-mesh connection (i.e. the route actually crossed the gap via the link).
fn pathUsesOffMesh(built: *Built) !bool {
    const filter = blk: {
        var f = dt.QueryFilter.init();
        f.setIncludeFlags(PF.walk | PF.swim | PF.door | PF.jump);
        f.setExcludeFlags(0);
        break :blk f;
    };
    const ext = [3]f32{ 2.0, 4.0, 2.0 };
    const start_in = [3]f32{ 2.0, 0.0, 5.0 };
    const end_in = [3]f32{ 20.0, 0.0, 5.0 };

    var start_ref: dt.PolyRef = 0;
    var start_pos: [3]f32 = undefined;
    _ = try built.query.findNearestPoly(&start_in, &ext, &filter, &start_ref, &start_pos);
    var end_ref: dt.PolyRef = 0;
    var end_pos: [3]f32 = undefined;
    _ = try built.query.findNearestPoly(&end_in, &ext, &filter, &end_ref, &end_pos);
    if (start_ref == 0 or end_ref == 0) return false;

    var path: [256]dt.PolyRef = undefined;
    var path_count: usize = 0;
    _ = try built.query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
    if (path_count == 0 or path[path_count - 1] != end_ref) return false;

    var straight: [256 * 3]f32 = undefined;
    var sflags: [256]u8 = undefined;
    var srefs: [256]dt.PolyRef = undefined;
    var scount: usize = 0;
    _ = try built.query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &straight, &sflags, &srefs, &scount, 0);
    for (0..scount) |i| {
        if ((sflags[i] & dt.STRAIGHTPATH_OFFMESH_CONNECTION) != 0) return true;
    }
    return false;
}

test "off-mesh path survives scene save/load round-trip" {
    const alloc = std.testing.allocator;
    const area_types = @import("../area_types.zig");
    const poly_flags = @import("../poly_flags.zig");
    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    // --- 1. Source geom: two quads + off-mesh (area=jump, flags=jump) -----------
    var geom = try buildTwoQuadGeom(alloc);
    defer geom.deinit();
    try geom.addOffMeshConnection(
        .{ 7.0, 0.0, 5.0 },
        .{ 15.0, 0.0, 5.0 },
        0.6,
        1, // bidir
        @intFromEnum(PA.jump),
        PF.jump,
    );

    // --- 2. Baseline: build + query MUST cross the gap via the off-mesh ---------
    {
        var built = try buildNavmesh(alloc, &geom);
        defer built.deinit(alloc);
        try std.testing.expectEqual(@as(i32, 1), built.off_mesh_poly_count);
        try std.testing.expect(try pathUsesOffMesh(&built));
    }

    // --- 3. Simulate Scene save/load via scene_io (gset + offmesh.bin) ----------
    //   loadScene order: readGsetText FIRST (addOffMeshConnection), then
    //   decodeOffMesh (clears + re-appends from offmesh.bin).
    var gset = try scene_io.writeGsetText(alloc, &geom, "two_quads.obj", null);
    defer gset.deinit();
    var offbin = try scene_io.encodeOffMesh(alloc, &geom);
    defer offbin.deinit();

    var geom2 = try buildTwoQuadGeom(alloc); // base triangles reloaded (loadInto)
    defer geom2.deinit();
    const parsed = try scene_io.readGsetText(alloc, &geom2, gset.items);
    alloc.free(parsed.mesh_name);
    try scene_io.decodeOffMesh(&geom2, offbin.items);

    // off-mesh fields must be intact (area=jump=5, flags=jump=0x08).
    try std.testing.expectEqual(@as(usize, 1), geom2.offMeshCount());
    try std.testing.expectEqual(@as(u8, @intFromEnum(PA.jump)), geom2.off_area.items[0]);
    try std.testing.expectEqual(@as(u16, PF.jump), geom2.off_flags.items[0]);

    // --- 4. Rebuild from restored geom + query MUST still cross via off-mesh ----
    {
        var built2 = try buildNavmesh(alloc, &geom2);
        defer built2.deinit(alloc);
        try std.testing.expectEqual(@as(i32, 1), built2.off_mesh_poly_count);
        try std.testing.expect(try pathUsesOffMesh(&built2));
    }
}

test "off-mesh path survives FULL container save/load (loadScene, registries incl jump area)" {
    // Exercises the SAME code path as the GUI Save Scene / Load Scene buttons:
    // scene_container.saveScene -> loadScene (manifest + registry_io.loadAll +
    // readGset + decodeOffMesh), with the jump area registered, then rebuilds and
    // queries. This catches any registry-restore interaction the scene_io-only test
    // (above) would miss.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const area_types = @import("../area_types.zig");
    const poly_flags = @import("../poly_flags.zig");

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var geom = try buildTwoQuadGeom(alloc);
    defer geom.deinit();
    try geom.addOffMeshConnection(
        .{ 7.0, 0.0, 5.0 },
        .{ 15.0, 0.0, 5.0 },
        0.6,
        1,
        @intFromEnum(PA.jump),
        PF.jump,
    );

    // Save a full container (mirror saveSyntheticSceneUnder, but with a REAL built
    // navmesh so tiles are saved too — closer to the GUI).
    {
        var built = try buildNavmesh(alloc, &geom);
        defer built.deinit(alloc);
        try std.testing.expect(try pathUsesOffMesh(&built));

        var root = try @import("write_atomic.zig").openContainerDir(io, tmp.dir, "scene.recastscene");
        defer root.close(io);
        var tiles_dir = try @import("write_atomic.zig").openContainerDir(io, root, "tiles");
        defer tiles_dir.close(io);
        try scene_io.writeGset(alloc, io, root, &geom, "two_quads.obj", null);
        try @import("registry_io.zig").saveAll(alloc, io, root);
        try scene_io.saveVolumes(alloc, io, root, &geom);
        try scene_io.saveOffMesh(alloc, io, root, &geom);
        const tile_store = @import("tile_store.zig");
        const keys = try tile_store.saveAllTiles(io, alloc, tiles_dir, built.navmesh);
        defer alloc.free(keys);
        const manifest = @import("manifest.zig");
        const m = manifest.Manifest{ .gset_name = "two_quads.obj", .tiles = keys };
        try manifest.commitWorld(io, alloc, root, tiles_dir, m);
    }

    // Wipe registries (as a fresh process would have only builtins) and load.
    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    var geom2 = try buildTwoQuadGeom(alloc); // base triangles (loadInto stand-in)
    defer geom2.deinit();

    // loadScene resolves relative to cwd; run the SAME steps against the tmp dir
    // directly (manifest -> registry loadAll -> readGset -> loadOffMesh).
    {
        var root = try tmp.dir.openDir(io, "scene.recastscene", .{});
        defer root.close(io);
        const manifest = @import("manifest.zig");
        const m = try manifest.readManifest(io, alloc, root);
        alloc.free(m.gset_name);
        alloc.free(m.tiles);
        @import("registry_io.zig").loadAll(alloc, io, root) catch {};
        const parsed = try scene_io.readGset(alloc, io, root, &geom2);
        alloc.free(parsed.mesh_name);
        try scene_io.loadOffMesh(alloc, io, root, &geom2);
    }

    try std.testing.expectEqual(@as(usize, 1), geom2.offMeshCount());
    try std.testing.expectEqual(@as(u16, PF.jump), geom2.off_flags.items[0]);

    var built2 = try buildNavmesh(alloc, &geom2);
    defer built2.deinit(alloc);
    try std.testing.expectEqual(@as(i32, 1), built2.off_mesh_poly_count);
    try std.testing.expect(try pathUsesOffMesh(&built2));
}
