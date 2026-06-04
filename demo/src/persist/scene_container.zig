//! Persist Module 4c — scene_container: the saveScene / loadScene orchestrator for
//! a `.recastscene/` container. Glues registry_io (Module 2) + scene_io (Module 3)
//! + tile_store + manifest (Module 4a/4b) in the canonical commit/load order.
//!
//! CONTAINER LAYOUT:
//!   <container>/
//!     scene.gset            # geometry ref + settings + volumes/offmesh text (RecastDemo)
//!     edits/areas.reg       # area-type registry        (registry_io)
//!     edits/flags.reg       # poly-flag registry        (registry_io)
//!     edits/volumes.bin     # convex volumes incl id    (scene_io)
//!     edits/offmesh.bin     # off-mesh conns incl off_id (scene_io)
//!     tiles/<tx>_<ty>_<layer>.tile   # per-tile chunks   (tile_store)
//!     manifest              # self-describing index, written LAST (manifest)
//!
//! COMMIT ORDER (saveScene) — durability-critical, do not reorder:
//!   1. scene.gset + edits/* (registries via saveAll, volumes/offmesh)   [each fsync'd]
//!   2. fsync(edits/)                                                     [dir barrier]
//!   3. all tiles -> tiles/                                               [each fsync'd]
//!   4. fsync(tiles/) -> atomic-write(manifest) -> fsync(root)            [commitWorld]
//! The manifest is the atomic version-switch point: if any earlier step fails the
//! old manifest (if any) still describes a valid world.
//!
//! LOAD ORDER INVARIANT (loadScene) — do not reorder:
//!   manifest FIRST (fatal if corrupt) -> registries (areas/flags) BEFORE geometry
//!   -> geom/volumes/offmesh -> return the tile list. Registries load first so an
//!   area-id referenced by a volume resolves to a real area type (color/cost/flags)
//!   instead of a fallback. Tiles are loaded by the caller (loadTilesInto), which it
//!   may do directly (big worlds: add the saved tiles straight to the navmesh) or
//!   skip (rebuild from geometry if no tiles were saved).
//!
//! ============================================================================
//! UI INTEGRATION POINTS (main.zig — documented, NOT wired this increment):
//!   - Save Scene / Load Scene buttons: add two dvui.button("Save Scene")/
//!     ("Load Scene") next to the existing Save/Load navmesh controls. "Save Scene"
//!     calls saveScene(io, alloc, <path>, &geom, &mesh); "Load Scene" calls
//!     loadScene(...) (phase 1: geom/registries) then, after the sample rebuild or
//!     directly, loadTilesInto(...) (phase 2) to populate the dt.NavMesh.
//!   - Mesh picker `.recastscene/` entries: the current picker lists files via
//!     io_util.scanDirectory(dir, ext). Add a branch that lists DIRECTORIES whose
//!     name ends with ".recastscene" (entry.kind == .directory and
//!     std.mem.endsWith(u8, name, ".recastscene")) so a container can be chosen the
//!     same way as a .gset / MSET file.
//!   - On successful saveScene: clear the scene dirty bits. On successful loadScene:
//!     set the active scene name to the container name and clear dirty bits.
//!   - Log all save/load via the build context log; log skipped corrupt tiles as warn.
//! ============================================================================
//!
//! Registries (area_types / poly_flags) are MODULE-GLOBAL singletons in this demo,
//! so saveScene/loadScene operate on the live registry state via registry_io.saveAll
//! / loadAll (no registry pointers are threaded through here).

const std = @import("std");
const recast = @import("recast-nav");
const write_atomic = @import("write_atomic.zig");
const registry_io = @import("registry_io.zig");
const scene_io = @import("scene_io.zig");
const tile_store = @import("tile_store.zig");
const manifest = @import("manifest.zig");

const input_geom = @import("../input_geom.zig");
const InputGeom = input_geom.InputGeom;

const dt = recast.detour;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Result of loadScene phase 1: the sub-format versions and the OWNED list of tile
/// keys from the manifest. Free with freeLoadResult.
pub const LoadResult = struct {
    versions: manifest.FormatVersions,
    /// Owned (free via freeLoadResult). The caller passes this to loadTilesInto.
    tiles: []const tile_store.TileKey,
    /// Owned (free via freeLoadResult). The geometry mesh reference from scene.gset
    /// (e.g. "dungeon.obj"). Empty if scene.gset had no/empty mesh row. The UI caller
    /// resolves this under the meshes folder to reload the base .obj triangles, since
    /// loadScene restores volumes/offmesh into geom but NOT the base triangle mesh.
    mesh_name: []const u8,
};

pub fn freeLoadResult(alloc: std.mem.Allocator, r: LoadResult) void {
    alloc.free(r.tiles);
    alloc.free(r.mesh_name);
}

/// Save the full scene into `container_path` (created if missing) in commit order.
///
/// `geom`      — geometry + edits source (volumes/offmesh).
/// `mesh`      — built navmesh; its valid tiles become per-tile files.
/// `gset_name` — the geometry mesh reference written into scene.gset (e.g. "mesh.obj").
/// `settings`  — optional .gset settings row.
/// Registries are read from the module-global area_types/poly_flags state.
pub fn saveScene(
    io: Io,
    alloc: std.mem.Allocator,
    container_path: []const u8,
    geom: *const InputGeom,
    mesh: *const dt.NavMesh,
    gset_name: []const u8,
    settings: ?scene_io.GsetSettings,
) !void {
    // 0) Create container + the tiles/ subdir; open handles we need for fsync.
    var root = try write_atomic.openContainerDir(io, Dir.cwd(), container_path);
    defer root.close(io);
    var tiles_dir = try write_atomic.openContainerDir(io, root, "tiles");
    defer tiles_dir.close(io);

    // 1) Geometry + edits. scene_io writes scene.gset at root and volumes/offmesh
    //    under edits/; registry_io writes areas.reg/flags.reg under edits/.
    //    writeAtomic creates the edits/ subdir as needed and fsyncs each file.
    try scene_io.writeGset(alloc, io, root, geom, gset_name, settings);
    try registry_io.saveAll(alloc, io, root); // flags then areas
    try scene_io.saveVolumes(alloc, io, root, geom);
    try scene_io.saveOffMesh(alloc, io, root, geom);

    // 2) Directory barrier for edits/ (POSIX; no-op on Windows). Open a handle just
    //    for the fsync; tolerate absence (registries/edits may all be empty files).
    var edits_dir = root.openDir(io, "edits", .{}) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (edits_dir) |*ed| {
        defer ed.close(io);
        try write_atomic.dirFsync(ed.*);
    }

    // 3) Tiles: one file per valid navmesh tile; writeTile fsyncs each.
    const keys = try tile_store.saveAllTiles(io, alloc, tiles_dir, mesh);
    defer alloc.free(keys);

    // 4) Manifest LAST, with the fsync barriers (atomic version switch).
    const m = manifest.Manifest{
        .versions = .{},
        .gset_name = gset_name_default(gset_name),
        .tiles = keys,
    };
    try manifest.commitWorld(io, alloc, root, tiles_dir, m);
}

fn gset_name_default(name: []const u8) []const u8 {
    return if (name.len == 0) "scene.gset" else name;
}

/// loadScene PHASE 1: manifest -> registries -> geometry/volumes/offmesh.
///
/// INVARIANT: registries (areas/flags) load BEFORE geometry so volume area-ids
/// resolve to real area types. A corrupt MANIFEST is fatal (propagated). A missing
/// edits/ directory or a missing/corrupt individual sub-file is tolerated
/// (registries fall back to builtins; volumes/offmesh load is best-effort + logged).
///
/// Returns the OWNED tile-key list (free via freeLoadResult). The caller then either
/// calls loadTilesInto to add the saved tiles directly to a dt.NavMesh, or rebuilds
/// the navmesh from geometry (when no tiles were saved).
pub fn loadScene(
    io: Io,
    alloc: std.mem.Allocator,
    container_path: []const u8,
    out_geom: *InputGeom,
) !LoadResult {
    var root = try Dir.cwd().openDir(io, container_path, .{});
    defer root.close(io);

    // 0) Manifest FIRST (source of truth for versions + tile set). Fatal if corrupt.
    const m = try manifest.readManifest(io, alloc, root);
    // We keep `tiles` (moved into LoadResult); free only gset_name here.
    alloc.free(m.gset_name);
    errdefer alloc.free(m.tiles);

    // mesh_name is captured from scene.gset below and moved into LoadResult. Default
    // to an owned empty string so the result is always free-able via freeLoadResult.
    var mesh_name: []const u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(mesh_name);

    // 1) Registries FIRST (invariant). loadAll resets to builtins on FileNotFound;
    //    corruption is surfaced — tolerate it here (fall back to whatever loaded).
    registry_io.loadAll(alloc, io, root) catch |e| switch (e) {
        error.FileNotFound, error.ChecksumMismatch, error.WrongMagic, error.WrongVersion, error.Truncated => {
            std.log.warn("scene_container: registries missing/corrupt ({s}); using builtins/partial", .{@errorName(e)});
        },
        else => return e,
    };

    // 2) Geometry (.gset) then volumes/offmesh, AFTER registries. scene_io's
    //    loadVolumes/loadOffMesh already treat FileNotFound as a no-op; other
    //    corruption is logged and tolerated (best-effort edits restore).
    const parsed = scene_io.readGset(alloc, io, root, out_geom) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (parsed) |p| {
        // Move the gset mesh reference into LoadResult (replace the empty default).
        alloc.free(mesh_name);
        mesh_name = p.mesh_name; // ownership transferred
    }

    scene_io.loadVolumes(alloc, io, root, out_geom) catch |e|
        std.log.warn("scene_container: volumes.bin: {s}", .{@errorName(e)});
    scene_io.loadOffMesh(alloc, io, root, out_geom) catch |e|
        std.log.warn("scene_container: offmesh.bin: {s}", .{@errorName(e)});

    return .{ .versions = m.versions, .tiles = m.tiles, .mesh_name = mesh_name };
}

/// loadScene PHASE 2: add the manifest's tiles directly to `mesh`. A missing or
/// corrupt tile is skipped + logged (graceful degradation); the rest load. The
/// owned blob is handed to mesh.addTile with free_data=true (navmesh takes
/// ownership); on addTile failure we free it ourselves.
pub fn loadTilesInto(
    io: Io,
    alloc: std.mem.Allocator,
    container_path: []const u8,
    keys: []const tile_store.TileKey,
    mesh: *dt.NavMesh,
) !void {
    var root = try Dir.cwd().openDir(io, container_path, .{});
    defer root.close(io);
    var tiles_dir = root.openDir(io, "tiles", .{}) catch |e| switch (e) {
        error.FileNotFound => return, // no tiles dir -> nothing to add
        else => return e,
    };
    defer tiles_dir.close(io);

    for (keys) |key| {
        const got = tile_store.loadTile(io, alloc, tiles_dir, key) catch |e| {
            std.log.warn("scene_container: skip tile {d}_{d}_{d}: {s}", .{ key.tx, key.ty, key.layer, @errorName(e) });
            continue;
        };
        // got.payload is owned; addTile(free_data=true) takes ownership on success.
        _ = mesh.addTile(got.payload, dt.TileFlags{ .free_data = true }, 0) catch |e| {
            std.log.warn("scene_container: addTile failed {d}_{d}_{d}: {s}", .{ key.tx, key.ty, key.layer, @errorName(e) });
            alloc.free(got.payload);
        };
    }
}

// ---------------------------------------------------------------------------
// Tests (aggregated via demo/src/tests.zig -> `zig build demo-test`).
// ---------------------------------------------------------------------------

const testing = std.testing;
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");
const tc = recast.detour_tilecache;

/// Build a synthetic tilecache blob with coords (the FULL round-trip does not need a
/// real navmesh: we write tiles directly via tile_store and list them in the manifest).
fn synthTileCacheBlob(buf: []u8, tx: i32, ty: i32, tlayer: i32) []u8 {
    const H = tc.TileCacheLayerHeader;
    const h: *H = @ptrCast(@alignCast(buf.ptr));
    h.* = std.mem.zeroes(H);
    h.magic = tc.TILECACHE_MAGIC;
    h.version = tc.TILECACHE_VERSION;
    h.tx = tx;
    h.ty = ty;
    h.tlayer = tlayer;
    return buf[0..@sizeOf(H)];
}

test "scene_container FULL round-trip: registries + volumes(id) + offmesh(off_id) + tiles" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // --- Build the source scene -------------------------------------------------
    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    const ladder_bit = poly_flags.addFlag("ladder").?;
    const lava_id = area_types.addType().?;
    {
        const t = area_types.get(lava_id).?;
        t.cost = 9.0;
        t.flags = ladder_bit;
        t.setName("Lava");
    }
    const custom_id = area_types.addType().?;
    area_types.get(custom_id).?.setName("Custom");

    var geom = InputGeom.init(alloc);
    defer geom.deinit();
    const triA = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const triB = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    try geom.addConvexVolume(&triA, 3, 0.5, 2.0, @intCast(lava_id)); // id=1
    try geom.addConvexVolume(&triB, 3, -1.0, 3.0, @intCast(custom_id)); // id=2
    try geom.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.5, 1, 9, 0xABCD);
    try geom.addOffMeshConnection(.{ -1, 0, 1 }, .{ 2, 2, 2 }, 1.25, 0, 2, 0x0001);

    const keys = [_]tile_store.TileKey{
        .{ .tx = 3, .ty = 4, .layer = 0 },
        .{ .tx = -1, .ty = 2, .layer = 1 },
    };

    // --- Save into a container under tmp ----------------------------------------
    const sub = "world.recastscene";
    try saveSyntheticSceneUnder(io, alloc, tmp.dir, sub, &geom, &keys);

    // --- Verify manifest exists and lists 2 tiles -------------------------------
    var root = try tmp.dir.openDir(io, sub, .{});
    defer root.close(io);
    {
        const mdata = try root.readFileAlloc(io, manifest.MANIFEST_NAME, alloc, .unlimited);
        defer alloc.free(mdata);
        try testing.expect(mdata.len > 0);
    }

    // --- Fresh state: wipe registries + geom, then load -------------------------
    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    try testing.expect(area_types.get(lava_id) == null); // gone after reset

    var geom2 = InputGeom.init(alloc);
    defer geom2.deinit();

    const lr = try loadSceneUnder(io, alloc, tmp.dir, sub, &geom2);
    defer freeLoadResult(alloc, lr);

    // Registries restored (areas/flags) ------------------------------------------
    try testing.expectEqualStrings("Lava", area_types.get(lava_id).?.name());
    try testing.expectEqual(@as(f32, 9.0), area_types.get(lava_id).?.cost);
    try testing.expectEqualStrings("Custom", area_types.get(custom_id).?.name());
    var found_ladder = false;
    for (0..poly_flags.MAX_FLAGS) |i| {
        if (poly_flags.get(i)) |f| {
            if (std.mem.eql(u8, f.name(), "ladder")) found_ladder = true;
        }
    }
    try testing.expect(found_ladder);

    // Volumes restored incl stable id --------------------------------------------
    try testing.expectEqual(@as(usize, 2), geom2.volumes.items.len);
    try testing.expectEqual(geom.volumes.items[0].id, geom2.volumes.items[0].id);
    try testing.expectEqual(geom.volumes.items[1].id, geom2.volumes.items[1].id);
    try testing.expectEqual(geom.volumes.items[0].area, geom2.volumes.items[0].area);

    // Off-mesh restored incl off_id ----------------------------------------------
    try testing.expectEqual(geom.offMeshCount(), geom2.offMeshCount());
    try testing.expectEqualSlices(u32, geom.off_id.items, geom2.off_id.items);
    try testing.expectEqualSlices(u16, geom.off_flags.items, geom2.off_flags.items);

    // Tiles listed in manifest ---------------------------------------------------
    try testing.expectEqual(@as(usize, 2), lr.tiles.len);

    // Tiles readable via tile_store (graceful path) ------------------------------
    var td = try root.openDir(io, "tiles", .{});
    defer td.close(io);
    var loaded_count: usize = 0;
    for (lr.tiles) |k| {
        const got = tile_store.loadTile(io, alloc, td, k) catch continue;
        defer alloc.free(got.payload);
        try testing.expectEqual(k.tx, got.key.tx);
        try testing.expectEqual(k.ty, got.key.ty);
        try testing.expectEqual(k.layer, got.key.layer);
        loaded_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), loaded_count);
}

test "scene_container: missing edits/ tolerated, corrupt tile skipped, unknown area-id tolerated" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    var geom = InputGeom.init(alloc);
    defer geom.deinit();
    // A volume referencing an UNKNOWN area-id (63) — must not crash load.
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&tri, 3, 0, 1, 63);

    const keys = [_]tile_store.TileKey{
        .{ .tx = 0, .ty = 0, .layer = 0 },
        .{ .tx = 1, .ty = 0, .layer = 0 },
    };
    const container = "edge.recastscene";
    try saveSyntheticSceneUnder(io, alloc, tmp.dir, container, &geom, &keys);

    // Remove edits/ entirely -> load must tolerate (builtins; volumes/offmesh gone).
    try tmp.dir.deleteTree(io, "edge.recastscene/edits");

    // Corrupt the FIRST tile on disk -> loadTilesInto/skip must keep the second.
    {
        var root = try tmp.dir.openDir(io, container, .{});
        defer root.close(io);
        var td = try root.openDir(io, "tiles", .{});
        defer td.close(io);
        const data = try td.readFileAlloc(io, "0_0_0.tile", alloc, .unlimited);
        defer alloc.free(data);
        data[data.len - 1] ^= 0xFF;
        try td.writeFile(io, .{ .sub_path = "0_0_0.tile", .data = data });
    }

    var geom2 = InputGeom.init(alloc);
    defer geom2.deinit();
    const lr = try loadSceneUnder(io, alloc, tmp.dir, container, &geom2);
    defer freeLoadResult(alloc, lr);

    // edits/ gone -> registries are builtins; volumes.bin/offmesh.bin are absent,
    // so the stable-id edits restore is skipped. The volume still survives because
    // scene.gset carries the geometry ('v' row, re-stamped id via addConvexVolume) —
    // load tolerates the missing edits/ and falls back to the gset geometry.
    try testing.expectEqual(@as(usize, 1), geom2.volumes.items.len);
    try testing.expectEqual(@as(u8, 63), geom2.volumes.items[0].area); // unknown area-id tolerated
    try testing.expectEqual(@as(usize, 2), lr.tiles.len);

    // One tile corrupt -> exactly one loads.
    var root = try tmp.dir.openDir(io, container, .{});
    defer root.close(io);
    var td = try root.openDir(io, "tiles", .{});
    defer td.close(io);
    var ok: usize = 0;
    for (lr.tiles) |k| {
        if (tile_store.loadTile(io, alloc, td, k)) |g| {
            alloc.free(g.payload);
            ok += 1;
        } else |_| {}
    }
    try testing.expectEqual(@as(usize, 1), ok);
}

// --- Test helpers that run against an explicit parent Dir (tmp.dir) ------------
// The public saveScene/loadScene resolve container_path against process cwd; the
// tests instead operate under a tmpDir parent for isolation, mirroring the same
// commit/load order against `parent`.

fn saveSyntheticSceneUnder(
    io: Io,
    alloc: std.mem.Allocator,
    parent: Dir,
    container_path: []const u8,
    geom: *const InputGeom,
    keys: []const tile_store.TileKey,
) !void {
    var root = try write_atomic.openContainerDir(io, parent, container_path);
    defer root.close(io);
    var tiles_dir = try write_atomic.openContainerDir(io, root, "tiles");
    defer tiles_dir.close(io);

    try scene_io.writeGset(alloc, io, root, geom, "mesh.obj", null);
    try registry_io.saveAll(alloc, io, root);
    try scene_io.saveVolumes(alloc, io, root, geom);
    try scene_io.saveOffMesh(alloc, io, root, geom);

    var raw0: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    var raw1: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    const b0 = synthTileCacheBlob(&raw0, keys[0].tx, keys[0].ty, keys[0].layer);
    const b1 = synthTileCacheBlob(&raw1, keys[1].tx, keys[1].ty, keys[1].layer);
    try tile_store.writeTile(io, alloc, tiles_dir, .tilecache, b0);
    try tile_store.writeTile(io, alloc, tiles_dir, .tilecache, b1);

    const m = manifest.Manifest{ .gset_name = "mesh.obj", .tiles = keys };
    try manifest.commitWorld(io, alloc, root, tiles_dir, m);
}

fn loadSceneUnder(
    io: Io,
    alloc: std.mem.Allocator,
    parent: Dir,
    container_path: []const u8,
    out_geom: *InputGeom,
) !LoadResult {
    var root = try parent.openDir(io, container_path, .{});
    defer root.close(io);

    const m = try manifest.readManifest(io, alloc, root);
    alloc.free(m.gset_name);
    errdefer alloc.free(m.tiles);

    registry_io.loadAll(alloc, io, root) catch |e| switch (e) {
        error.FileNotFound, error.ChecksumMismatch, error.WrongMagic, error.WrongVersion, error.Truncated => {
            std.log.warn("scene_container(test): registries missing/corrupt ({s})", .{@errorName(e)});
        },
        else => return e,
    };

    var mesh_name: []const u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(mesh_name);

    const parsed = scene_io.readGset(alloc, io, root, out_geom) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (parsed) |p| {
        alloc.free(mesh_name);
        mesh_name = p.mesh_name;
    }

    scene_io.loadVolumes(alloc, io, root, out_geom) catch |e|
        std.log.warn("scene_container(test): volumes.bin: {s}", .{@errorName(e)});
    scene_io.loadOffMesh(alloc, io, root, out_geom) catch |e|
        std.log.warn("scene_container(test): offmesh.bin: {s}", .{@errorName(e)});

    return .{ .versions = m.versions, .tiles = m.tiles, .mesh_name = mesh_name };
}
