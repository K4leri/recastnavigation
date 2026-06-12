//! Sample_TileMesh — тайловая сборка navmesh.
//! Порт RecastDemo/Sample_TileMesh (core: buildAllTiles + per-tile pipeline).
//! Растеризация через PartitionedMesh: только чанки, пересекающие тайл (как upstream).

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const InputGeom = @import("input_geom.zig").InputGeom;
const BuildContext = @import("build_context.zig").BuildContext;
const ddgl = @import("debug_draw_gl.zig");
const io_util = @import("io_util.zig");
const ui = @import("ui.zig");
const nav_io = @import("navmesh_io.zig");
const view_state = @import("render/view_state.zig");
const navmesh_layer = @import("render/navmesh_layer.zig");

const rc = recast.recast;
const dt = recast.detour;
const dbg = recast.debug;
const Vec3 = recast.math.Vec3;
const mem_budget = @import("diag/mem_budget.zig");

pub const DrawMode = enum { mesh, navmesh, navmesh_trans, navmesh_bvtree, navmesh_portals };

/// (tx,ty) tile coordinate — key for the dirty-tile set (cluster F6).
pub const TileCoord = struct { x: i32, y: i32 };
pub const DirtyTiles = std.AutoHashMap(TileCoord, void);

pub const SampleTile = struct {
    alloc: std.mem.Allocator,
    settings: sample.CommonSettings = .{},
    tile_size: f32 = 32.0,
    geom: ?*InputGeom = null,
    bctx: *BuildContext,
    dd_gl: *ddgl.DebugDrawGL,

    draw_mode: DrawMode = .navmesh,
    build_all: bool = true,
    build_time_ms: f32 = 0,
    build_gen: u32 = 0,
    tiles_built: usize = 0,

    navmesh: ?dt.NavMesh = null,

    // Dirty-tile set for incremental rebuild (cluster F6). An edit registers the
    // (tx,ty) tiles whose bbox it touches via markDirtyBBox; the main loop drains
    // this via rebuildDirty when "Incremental rebuild" is on.
    dirty_tiles: DirtyTiles = undefined,
    incremental: bool = true, // default ON for Tile (Solo is always a single full build)

    pub fn init(alloc: std.mem.Allocator, bctx: *BuildContext, dd_gl: *ddgl.DebugDrawGL) SampleTile {
        return .{ .alloc = alloc, .bctx = bctx, .dd_gl = dd_gl, .dirty_tiles = DirtyTiles.init(alloc) };
    }

    pub fn deinit(self: *SampleTile) void {
        if (self.navmesh) |*n| n.deinit();
        self.navmesh = null;
        self.dirty_tiles.deinit();
    }

    /// Number of tiles currently marked dirty (for the "N tiles dirty" indicator).
    pub fn dirtyCount(self: *const SampleTile) usize {
        return self.dirty_tiles.count();
    }

    /// Map an axis-aligned XZ edit bbox to the tiles it touches and mark them dirty.
    /// CONSERVATIVE: the range is expanded by ±1 tile on each side, because an edit
    /// near a tile border affects neighbour tiles through `border_size` (the
    /// per-tile rasterisation reaches `border_size` cells past the tile boundary).
    /// Requires a navmesh (for calcTileLoc); no-op if there is none yet.
    pub fn markDirtyBBox(self: *SampleTile, minx: f32, minz: f32, maxx: f32, maxz: f32) void {
        const nm = if (self.navmesh) |*n| n else return;
        const geom = self.geom orelse return;
        // Valid tile grid [0,tw)×[0,th) — same derivation as build().
        var gw: i32 = 0;
        var gh: i32 = 0;
        recast.RecastConfig.calcGridSize(
            Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]),
            Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]),
            self.settings.cell_size,
            &gw,
            &gh,
        );
        const grid = sample.computeTileGrid(gw, gh, self.tile_size, self.settings.cell_size, 1);
        const tw = grid.tw;
        const th = grid.th;

        const lo = nm.calcTileLoc(Vec3.init(minx, 0, minz));
        const hi = nm.calcTileLoc(Vec3.init(maxx, 0, maxz));
        // ±1 conservative expansion, then clamp to the valid grid so we never mark
        // off-grid tiles (a full build never produces those).
        var ty: i32 = @max(0, lo.y - 1);
        while (ty <= @min(th - 1, hi.y + 1)) : (ty += 1) {
            var tx: i32 = @max(0, lo.x - 1);
            while (tx <= @min(tw - 1, hi.x + 1)) : (tx += 1) {
                self.dirty_tiles.put(.{ .x = tx, .y = ty }, {}) catch {};
            }
        }
    }

    /// Rebuild every dirty tile incrementally, then clear the set. Returns the
    /// number of tiles rebuilt. Mirrors what a full build() would have produced for
    /// exactly those tiles (rebuildTile uses the same per-tile path).
    pub fn rebuildDirty(self: *SampleTile) usize {
        if (self.navmesh == null) return 0;
        var n: usize = 0;
        var it = self.dirty_tiles.keyIterator();
        while (it.next()) |k| {
            if (self.rebuildTile(k.x, k.y)) n += 1;
        }
        self.dirty_tiles.clearRetainingCapacity();
        return n;
    }

    pub fn setGeom(self: *SampleTile, geom: *InputGeom) void {
        self.geom = geom;
        if (self.navmesh) |*n| n.deinit();
        self.navmesh = null;
    }

    pub fn navMesh(self: *SampleTile) ?*dt.NavMesh {
        if (self.navmesh) |*n| return n;
        return null;
    }

    pub fn build(self: *SampleTile) bool {
        const geom = self.geom orelse return false;
        if (geom.triCount() == 0) return false;
        if (self.navmesh) |*n| n.deinit();
        self.navmesh = null;
        self.bctx.resetLog();
        const ctx = self.bctx.context();
        const s = &self.settings;

        var timer = io_util.PerfTimer.start();

        const cs = s.cell_size;
        const bmin = Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]);
        const bmax = Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]);

        var gw: i32 = 0;
        var gh: i32 = 0;
        recast.RecastConfig.calcGridSize(bmin, bmax, cs, &gw, &gh);
        const grid = sample.computeTileGrid(gw, gh, self.tile_size, cs, 1);
        const tw = grid.tw;
        const th = grid.th;

        const nm_params = dt.NavMeshParams{
            .orig = bmin,
            .tile_width = grid.tcs,
            .tile_height = grid.tcs,
            .max_tiles = grid.max_tiles,
            .max_polys = grid.max_polys,
        };
        var navmesh = dt.NavMesh.init(self.alloc, nm_params) catch return false;
        errdefer navmesh.deinit();

        self.tiles_built = 0;
        var ty: i32 = 0;
        while (ty < th) : (ty += 1) {
            var tx: i32 = 0;
            while (tx < tw) : (tx += 1) {
                if (self.buildTileMesh(ctx, geom, tx, ty, bmin, bmax, &navmesh)) {
                    self.tiles_built += 1;
                }
            }
        }

        self.navmesh = navmesh;
        self.build_time_ms = timer.readMs();
        self.build_gen +%= 1;
        ctx.log(.progress, "Tile build: {d} tiles in {d:.1} ms", .{ self.tiles_built, self.build_time_ms });
        return true;
    }

    /// Incremental single-tile rebuild (cluster F6). Removes any existing tile(s)
    /// at (tx,ty) from the live navmesh, then rebuilds JUST that tile via the same
    /// per-tile `buildTileMesh` path `build()` uses — so the result is byte-identical
    /// to that tile from a full `build()`.
    ///
    /// Preconditions: a navmesh already exists (a prior `build()`), and the geom is
    /// set. `bmin/bmax` are recomputed from geom EXACTLY as `build()` does, so the
    /// tile origin / border expansion match the full build verbatim.
    ///
    /// Returns true if the navmesh was updated (whether or not the rebuilt tile
    /// produced data — an empty tile is a valid "removed only" outcome). Returns
    /// false only if there is no navmesh/geom to operate on.
    pub fn rebuildTile(self: *SampleTile, tx: i32, ty: i32) bool {
        const geom = self.geom orelse return false;
        const navmesh = if (self.navmesh) |*n| n else return false;
        const ctx = self.bctx.context();

        // bmin/bmax come from geom — identical to build()'s computation.
        const bmin = Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]);
        const bmax = Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]);

        // Remove existing tile(s) at this (tx,ty) across all layers. The tile sample
        // only builds layer 0, but getTilesAt + removeTile is the upstream-faithful
        // way to clear the slot (it also unstitches neighbour portal links).
        // removeTile frees the old data because tiles were added with free_data=true.
        {
            const MAX = 32;
            var tiles: [MAX]*dt.MeshTile = undefined;
            const n = navmesh.getTilesAt(tx, ty, &tiles, MAX);
            for (0..n) |i| {
                const ref = navmesh.getTileRef(tiles[i]);
                if (ref != 0) _ = navmesh.removeTile(ref) catch {};
            }
        }

        // Rebuild just this tile via the SAME private path build() uses. If it
        // produces no data (empty tile), the slot simply stays removed — correct.
        _ = self.buildTileMesh(ctx, geom, tx, ty, bmin, bmax, navmesh);
        self.build_gen +%= 1;
        return true;
    }

    fn buildTileMesh(self: *SampleTile, ctx: *recast.Context, geom: *InputGeom, tx: i32, ty: i32, bmin: Vec3, bmax: Vec3, navmesh: *dt.NavMesh) bool {
        const a = self.alloc;
        const s = &self.settings;
        const cs = s.cell_size;
        const ch = s.cell_height;
        const d = sample.deriveCfg(s, cs, ch);
        const walkable_height = d.walkable_height;
        const walkable_climb = d.walkable_climb;
        const walkable_radius = d.walkable_radius;
        const max_edge_len = d.max_edge_len;
        const min_region_area = d.min_region_area;
        const merge_region_area = d.merge_region_area;
        const detail_sample_dist = d.detail_sample_dist;
        const detail_sample_max_error = d.detail_sample_max_error;
        const border_size = walkable_radius + 3;
        const tcs = self.tile_size * cs;

        // границы тайла + расширение на border
        const tbmin = Vec3.init(bmin.x + @as(f32, @floatFromInt(tx)) * tcs, bmin.y, bmin.z + @as(f32, @floatFromInt(ty)) * tcs);
        const tbmax = Vec3.init(tbmin.x + tcs, bmax.y, tbmin.z + tcs);
        const exp = @as(f32, @floatFromInt(border_size)) * cs;
        const hbmin = Vec3.init(tbmin.x - exp, tbmin.y, tbmin.z - exp);
        const hbmax = Vec3.init(tbmax.x + exp, tbmax.y, tbmax.z + exp);
        const width: i32 = @as(i32, @intFromFloat(self.tile_size)) + border_size * 2;

        var hf = recast.Heightfield.init(a, width, width, hbmin, hbmax, cs, ch) catch return false;
        defer hf.deinit();

        // PartitionedMesh: растеризуем только чанки, пересекающие расширенный bbox
        // тайла (1-в-1 Sample_TileMesh::buildTileMesh). Пустой тайл — early-out,
        // как upstream `if (overlappingNodes.empty()) return 0;`.
        var node_ids = std.array_list.Managed(usize).init(a);
        defer node_ids.deinit();
        geom.pmesh.nodesOverlappingRect(.{ hbmin.x, hbmin.z }, .{ hbmax.x, hbmax.z }, &node_ids) catch return false;
        if (node_ids.items.len == 0) return false;

        // Буфер на maxTrisPerChunk, переиспользуется на каждый чанк (upstream triareas).
        const triareas = a.alloc(u8, @intCast(geom.pmesh.max_tris_per_chunk)) catch return false;
        defer a.free(triareas);
        for (node_ids.items) |ni| {
            const node_tris = geom.pmesh.nodeTris(ni);
            const areas = triareas[0 .. node_tris.len / 3];
            @memset(areas, 0); // NULL_AREA: не-walkable грани должны остаться 0 (как upstream memset)
            rc.filter.markWalkableTriangles(ctx, s.agent_max_slope, geom.verts.items, node_tris, areas);
            rc.rasterization.rasterizeTriangles(ctx, geom.verts.items, node_tris, areas, &hf, walkable_climb) catch return false;
        }

        // Фильтры условно по переключателям UI (1-в-1 Sample_TileMesh::buildTileMesh).
        if (s.filter_low_hanging_obstacles)
            rc.filter.filterLowHangingWalkableObstacles(ctx, walkable_climb, &hf);
        if (s.filter_ledge_spans)
            rc.filter.filterLedgeSpans(ctx, walkable_height, walkable_climb, &hf);
        if (s.filter_walkable_low_height_spans)
            rc.filter.filterWalkableLowHeightSpans(ctx, walkable_height, &hf);

        const span_count = rc.compact.getHeightFieldSpanCount(ctx, &hf);
        var chf = recast.CompactHeightfield.init(a, width, width, @intCast(span_count), walkable_height, walkable_climb, hbmin, hbmax, cs, ch, border_size) catch return false;
        defer chf.deinit();
        rc.compact.buildCompactHeightfield(ctx, walkable_height, walkable_climb, &hf, &chf) catch return false;

        rc.area.erodeWalkableArea(ctx, walkable_radius, &chf, a) catch return false;
        sample.markConvexVolumes(ctx, geom, &chf);
        // Partitioning (ветвление по типу, 1-в-1 Sample_TileMesh::buildTileMesh).
        switch (s.partition_type) {
            .watershed => {
                // Watershed: дистанционное поле + рост регионов.
                rc.region.buildDistanceField(ctx, &chf, a) catch return false;
                rc.region.buildRegions(ctx, &chf, border_size, min_region_area, merge_region_area, a) catch return false;
            },
            // Monotone: без distancefield.
            .monotone => rc.region.buildRegionsMonotone(ctx, &chf, border_size, min_region_area, merge_region_area, a) catch return false,
            // Layers: без distancefield; merge_region_area не используется (как в оригинале).
            .layers => rc.region.buildLayerRegions(ctx, &chf, border_size, min_region_area, a) catch return false,
        }

        var cset = recast.ContourSet.init(a);
        defer cset.deinit();
        rc.contour.buildContours(ctx, &chf, s.edge_max_error, max_edge_len, &cset, rc.config.CONTOUR_TESS_WALL_EDGES, a) catch return false;
        if (cset.nconts == 0) return false;

        var pmesh = recast.PolyMesh.init(a);
        defer pmesh.deinit();
        const nvp: usize = @intFromFloat(s.verts_per_poly);
        rc.mesh.buildPolyMesh(ctx, &cset, nvp, &pmesh, a) catch return false;
        if (pmesh.npolys == 0) return false;

        var dmesh = recast.PolyMeshDetail.init(a);
        defer dmesh.deinit();
        rc.detail.buildPolyMeshDetail(ctx, &pmesh, &chf, detail_sample_dist, detail_sample_max_error, &dmesh, a) catch return false;

        const npolys: usize = pmesh.polyCount();
        const poly_flags = a.alloc(u16, npolys) catch return false;
        defer a.free(poly_flags);
        for (0..npolys) |i| {
            if (pmesh.areas[i] == rc.config.AreaId.WALKABLE_AREA or area_types.get(pmesh.areas[i]) == null)
                pmesh.areas[i] = @intFromEnum(sample.SamplePolyAreas.ground);
            poly_flags[i] = area_types.flagsFor(pmesh.areas[i]);
        }

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
            .cs = cs,
            .ch = ch,
            .tile_x = tx,
            .tile_y = ty,
            .tile_layer = 0,
            .build_bv_tree = true,
        };
        const data = dt.createNavMeshData(&params, a) catch return false;
        _ = navmesh.addTile(data, dt.TileFlags{ .free_data = true }, 0) catch {
            a.free(data);
            return false;
        };
        return true;
    }

    // Cluster E (P1-1): unified navmesh-layer draw (navmesh group gate + wireframe/
    // filter/faithful routing). Shared via render/navmesh_layer.zig.
    fn drawNavmeshLayer(self: *SampleTile, dd: dbg.DebugDraw, n: *dt.NavMesh) void {
        navmesh_layer.drawNavmeshLayer(dd, n, self.alloc);
    }

    pub fn render(self: *SampleTile) void {
        self.dd_gl.area_to_col = sample.sampleAreaToCol;
        const dd = self.dd_gl.debugDraw();
        switch (self.draw_mode) {
            .mesh => if (view_state.groups.input_mesh) self.renderInputMesh(dd),
            .navmesh => if (self.navmesh) |*n| {
                self.drawNavmeshLayer(dd, n);
            },
            .navmesh_trans => {
                if (view_state.groups.input_mesh) self.renderInputMesh(dd);
                if (self.navmesh) |*n| self.drawNavmeshLayer(dd, n);
            },
            .navmesh_bvtree => if (self.navmesh) |*n| {
                self.drawNavmeshLayer(dd, n);
                if (view_state.groups.navmesh) dbg.debugDrawNavMeshBVTree(dd, n);
            },
            .navmesh_portals => if (self.navmesh) |*n| {
                self.drawNavmeshLayer(dd, n);
                if (view_state.groups.navmesh) dbg.debugDrawNavMeshPortals(dd, n);
            },
        }

        // Scene overlays drawn regardless of the active tool (1:1 Sample::handleRender).
        navmesh_layer.drawSceneOverlays(dd, self.geom);
    }

    fn renderInputMesh(self: *SampleTile, dd: dbg.DebugDraw) void {
        const geom = self.geom orelse return;
        const v = geom.verts.items;
        const t = geom.tris.items;
        dd.begin(.tris, 1.0);
        var i: usize = 0;
        while (i < t.len) : (i += 3) {
            const ai: usize = @intCast(t[i]);
            const bi: usize = @intCast(t[i + 1]);
            const ci: usize = @intCast(t[i + 2]);
            const col = dbg.rgba(160, 160, 160, 255);
            dd.vertexXYZ(v[ai * 3], v[ai * 3 + 1], v[ai * 3 + 2], col);
            dd.vertexXYZ(v[bi * 3], v[bi * 3 + 1], v[bi * 3 + 2], col);
            dd.vertexXYZ(v[ci * 3], v[ci * 3 + 1], v[ci * 3 + 2], col);
        }
        dd.end();
    }

    pub fn drawSettings(self: *SampleTile) void {
        const s = &self.settings;
        var gw: i32 = 0;
        var gh: i32 = 0;
        if (self.geom) |g| {
            const bmin = Vec3.init(g.bmin[0], g.bmin[1], g.bmin[2]);
            const bmax = Vec3.init(g.bmax[0], g.bmax[1], g.bmax[2]);
            recast.RecastConfig.calcGridSize(bmin, bmax, s.cell_size, &gw, &gh);
        }
        sample.drawCommonSettings(s, gw, gh);

        _ = dvui.checkbox(@src(), &self.build_all, "Build All Tiles", .{});
        dvui.labelNoFmt(@src(), "Tiling", .{}, .{});
        ui.sliderInt(@src(), "Tile Size: {d:.0}", &self.tile_size, 16, 1024);

        if (self.geom != null and gw > 0) {
            const grid = sample.computeTileGrid(gw, gh, self.tile_size, s.cell_size, 1);
            dvui.label(@src(), "Tiles  {d} x {d}", .{ grid.tw, grid.th }, .{});
            dvui.label(@src(), "Max Tiles  {d}", .{grid.max_tiles}, .{});
            dvui.label(@src(), "Max Polys  {d}", .{grid.max_polys}, .{});
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        // F6: incremental rebuild. ON by default for Tile; when off, edits trigger a
        // full build() (old behaviour). Shows how many tiles are currently dirty.
        _ = dvui.checkbox(@src(), &self.incremental, "Incremental rebuild", .{});
        if (self.incremental) {
            dvui.label(@src(), "{d} tiles dirty", .{self.dirtyCount()}, .{});
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "Save", .{}, .{})) self.saveNavMesh();
        if (dvui.button(@src(), "Load", .{}, .{})) self.loadNavMesh();
        dvui.label(@src(), "Build Time: {d:.1}ms", .{self.build_time_ms}, .{});
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        self.drawMemory();
    }

    /// Memory Budget (C3) — Tile variant.
    /// Reports total navmesh bytes (sum of all tile data_size) + tile count + avg.
    /// id_extra range 7531-7540.
    pub fn drawMemory(self: *SampleTile) void {
        ui.section(@src(), "Memory");
        const nm = if (self.navmesh) |*n| n else {
            dvui.labelNoFmt(@src(), "Build the Tile mesh to see memory usage.", .{}, .{ .id_extra = 7531 });
            return;
        };

        // Sum data_size across all live tiles (tiles with header != null are live).
        var total_bytes: usize = 0;
        var tile_count: usize = 0;
        for (nm.tiles) |*tile| {
            if (tile.header != null) {
                total_bytes += tile.data_size;
                tile_count += 1;
            }
        }

        var fbuf: [32]u8 = undefined;
        dvui.label(@src(), "NavMesh tile data : {s}", .{mem_budget.formatBytes(&fbuf, total_bytes)}, .{ .id_extra = 7532 });
        dvui.label(@src(), "Tile count        : {d}", .{tile_count}, .{ .id_extra = 7533 });
        if (tile_count > 0) {
            const avg = total_bytes / tile_count;
            dvui.label(@src(), "Avg per tile      : {s}", .{mem_budget.formatBytes(&fbuf, avg)}, .{ .id_extra = 7534 });
        }
    }

    const SAVE_PATH = "all_tiles_navmesh.bin";

    fn saveNavMesh(self: *SampleTile) void {
        const nm = if (self.navmesh) |*n| n else {
            self.bctx.context().log(.err, "Save: no navmesh", .{});
            return;
        };
        nav_io.save(self.alloc, SAVE_PATH, nm) catch |e| {
            self.bctx.context().log(.err, "Save failed: {s}", .{@errorName(e)});
            return;
        };
        self.bctx.context().log(.progress, "Saved {s}", .{SAVE_PATH});
    }

    fn loadNavMesh(self: *SampleTile) void {
        const loaded = nav_io.load(self.alloc, SAVE_PATH) catch |e| {
            self.bctx.context().log(.err, "Load failed: {s}", .{@errorName(e)});
            return;
        };
        if (self.navmesh) |*n| n.deinit();
        self.navmesh = loaded;
        self.build_gen +%= 1;
        self.bctx.context().log(.progress, "Loaded {s}", .{SAVE_PATH});
    }

    pub fn drawDebugMode(self: *SampleTile) void {
        dvui.labelNoFmt(@src(), "Draw Settings", .{}, .{});
        const has_nav = self.navmesh != null;
        self.dmOpt("Input Mesh", .mesh, self.geom != null, 0);
        self.dmOpt("Navmesh", .navmesh, has_nav, 1);
        self.dmOpt("Navmesh Trans", .navmesh_trans, has_nav, 2);
        self.dmOpt("Navmesh BVTree", .navmesh_bvtree, has_nav, 3);
        self.dmOpt("Navmesh Portals", .navmesh_portals, has_nav, 4);
    }

    fn dmOpt(self: *SampleTile, label: []const u8, mode: DrawMode, avail: bool, id: usize) void {
        if (!avail) return;
        if (ui.radio(@src(), self.draw_mode == mode, label, id)) self.draw_mode = mode;
    }
};
