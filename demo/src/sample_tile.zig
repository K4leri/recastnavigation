//! Sample_TileMesh — тайловая сборка navmesh.
//! Порт RecastDemo/Sample_TileMesh (core: buildAllTiles + per-tile pipeline).
//! Без ChunkyTriMesh: растеризуем все треугольники с клиппингом по границам тайла.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const sample = @import("sample.zig");
const InputGeom = @import("input_geom.zig").InputGeom;
const BuildContext = @import("build_context.zig").BuildContext;
const ddgl = @import("debug_draw_gl.zig");
const io_util = @import("io_util.zig");
const ui = @import("ui.zig");
const nav_io = @import("navmesh_io.zig");

const rc = recast.recast;
const dt = recast.detour;
const dbg = recast.debug;
const Vec3 = recast.math.Vec3;

pub const DrawMode = enum { mesh, navmesh, navmesh_trans, navmesh_bvtree, navmesh_portals };

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

    pub fn init(alloc: std.mem.Allocator, bctx: *BuildContext, dd_gl: *ddgl.DebugDrawGL) SampleTile {
        return .{ .alloc = alloc, .bctx = bctx, .dd_gl = dd_gl };
    }

    pub fn deinit(self: *SampleTile) void {
        if (self.navmesh) |*n| n.deinit();
        self.navmesh = null;
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
        const ts: i32 = @intFromFloat(self.tile_size);
        const tw = @divTrunc(gw + ts - 1, ts);
        const th = @divTrunc(gh + ts - 1, ts);
        const tcs = self.tile_size * cs;

        // битовое распределение (как RecastDemo)
        const tile_bits: u5 = @intCast(@min(recast.math.ilog2(recast.math.nextPow2(@intCast(tw * th))), 14));
        const poly_bits: u5 = @intCast(22 - @as(u32, tile_bits));
        const max_tiles: i32 = @as(i32, 1) << tile_bits;
        const max_polys: i32 = @as(i32, 1) << poly_bits;

        const nm_params = dt.NavMeshParams{
            .orig = bmin,
            .tile_width = tcs,
            .tile_height = tcs,
            .max_tiles = max_tiles,
            .max_polys = max_polys,
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

    fn buildTileMesh(self: *SampleTile, ctx: *recast.Context, geom: *InputGeom, tx: i32, ty: i32, bmin: Vec3, bmax: Vec3, navmesh: *dt.NavMesh) bool {
        const a = self.alloc;
        const s = &self.settings;
        const cs = s.cell_size;
        const ch = s.cell_height;
        const walkable_height: i32 = @intFromFloat(@ceil(s.agent_height / ch));
        const walkable_climb: i32 = @intFromFloat(@floor(s.agent_max_climb / ch));
        const walkable_radius: i32 = @intFromFloat(@ceil(s.agent_radius / cs));
        const max_edge_len: i32 = @intFromFloat(s.edge_max_len / cs);
        const min_region_area: i32 = @intFromFloat(s.region_min_size * s.region_min_size);
        const merge_region_area: i32 = @intFromFloat(s.region_merge_size * s.region_merge_size);
        const detail_sample_dist: f32 = if (s.detail_sample_dist < 0.9) 0 else cs * s.detail_sample_dist;
        const detail_sample_max_error: f32 = ch * s.detail_sample_max_error;
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

        const ntris = geom.triCount();
        const areas = a.alloc(u8, ntris) catch return false;
        defer a.free(areas);
        @memset(areas, 0); // NULL_AREA: не-walkable грани должны остаться 0 (как upstream memset)
        rc.filter.markWalkableTriangles(ctx, s.agent_max_slope, geom.verts.items, geom.tris.items, areas);
        rc.rasterization.rasterizeTriangles(ctx, geom.verts.items, geom.tris.items, areas, &hf, walkable_climb) catch return false;

        rc.filter.filterLowHangingWalkableObstacles(ctx, walkable_climb, &hf);
        rc.filter.filterLedgeSpans(ctx, walkable_height, walkable_climb, &hf);
        rc.filter.filterWalkableLowHeightSpans(ctx, walkable_height, &hf);

        const span_count = rc.compact.getHeightFieldSpanCount(ctx, &hf);
        var chf = recast.CompactHeightfield.init(a, width, width, @intCast(span_count), walkable_height, walkable_climb, hbmin, hbmax, cs, ch, border_size) catch return false;
        defer chf.deinit();
        rc.compact.buildCompactHeightfield(ctx, walkable_height, walkable_climb, &hf, &chf) catch return false;

        rc.area.erodeWalkableArea(ctx, walkable_radius, &chf, a) catch return false;
        for (geom.volumes.items) |*vol| {
            const nv: usize = @intCast(vol.nverts);
            rc.area.markConvexPolyArea(ctx, vol.verts[0 .. nv * 3], nv, vol.hmin, vol.hmax, vol.area, &chf);
        }
        rc.region.buildDistanceField(ctx, &chf, a) catch return false;
        rc.region.buildRegions(ctx, &chf, border_size, min_region_area, merge_region_area, a) catch return false;

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
            if (pmesh.areas[i] == rc.config.AreaId.WALKABLE_AREA) pmesh.areas[i] = @intFromEnum(sample.SamplePolyAreas.ground);
            poly_flags[i] = sample.SamplePolyFlags.walk;
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

    pub fn render(self: *SampleTile) void {
        self.dd_gl.area_to_col = sample.sampleAreaToCol;
        const dd = self.dd_gl.debugDraw();
        switch (self.draw_mode) {
            .mesh => self.renderInputMesh(dd),
            .navmesh => if (self.navmesh) |*n| dbg.debugDrawNavMesh(dd, n, 0),
            .navmesh_trans => {
                self.renderInputMesh(dd);
                if (self.navmesh) |*n| dbg.debugDrawNavMesh(dd, n, 0);
            },
            .navmesh_bvtree => if (self.navmesh) |*n| {
                dbg.debugDrawNavMesh(dd, n, 0);
                dbg.debugDrawNavMeshBVTree(dd, n);
            },
            .navmesh_portals => if (self.navmesh) |*n| {
                dbg.debugDrawNavMesh(dd, n, 0);
                dbg.debugDrawNavMeshPortals(dd, n);
            },
        }

        // Scene overlays drawn regardless of the active tool (1:1 Sample::handleRender).
        if (self.geom) |g| {
            // Mesh bounds wireframe (1:1 Sample::handleRender — duDebugDrawBoxWire,
            // white 255,255,255,128). Marks the 3D object's extent.
            dbg.debugDrawBoxWire(dd, g.bmin[0], g.bmin[1], g.bmin[2], g.bmax[0], g.bmax[1], g.bmax[2], dbg.rgba(255, 255, 255, 128), 1.0);
            g.drawConvexVolumes(dd);
            g.drawOffMeshConnections(dd);
        }
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
            const ts: i32 = @intFromFloat(self.tile_size);
            const tw = @divTrunc(gw + ts - 1, ts);
            const th = @divTrunc(gh + ts - 1, ts);
            dvui.label(@src(), "Tiles  {d} x {d}", .{ tw, th }, .{});
            const tile_bits: u5 = @intCast(@min(recast.math.ilog2(recast.math.nextPow2(@intCast(tw * th))), 14));
            const poly_bits: u5 = @intCast(22 - @as(u32, tile_bits));
            dvui.label(@src(), "Max Tiles  {d}", .{@as(i32, 1) << tile_bits}, .{});
            dvui.label(@src(), "Max Polys  {d}", .{@as(i32, 1) << poly_bits}, .{});
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "Save", .{}, .{})) self.saveNavMesh();
        if (dvui.button(@src(), "Load", .{}, .{})) self.loadNavMesh();
        dvui.label(@src(), "Build Time: {d:.1}ms", .{self.build_time_ms}, .{});
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
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
        dvui.labelNoFmt(@src(), "Draw", .{}, .{});
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
