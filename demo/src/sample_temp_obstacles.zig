//! Sample_TempObstacles — динамические препятствия через dtTileCache.
//! Порт RecastDemo/Sample_TempObstacles (core: rasterizeTileLayers + obstacles).

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

const rc = recast.recast;
const dt = recast.detour;
const tc = recast.detour_tilecache;
const dbg = recast.debug;
const Vec3 = recast.math.Vec3;

// --- компрессор без сжатия (точно под vtable, без @ptrCast) ---
const NoopCompressor = struct {
    fn maxSize(_: *anyopaque, n: usize) usize {
        return n;
    }
    fn compress(_: *anyopaque, buffer: []const u8, out: []u8, out_size: *usize) recast.Status {
        if (out.len < buffer.len) return .{ .failure = true, .buffer_too_small = true };
        @memcpy(out[0..buffer.len], buffer);
        out_size.* = buffer.len;
        return .{ .success = true };
    }
    fn decompress(_: *anyopaque, comp: []const u8, buffer: []u8, buf_size: *usize) recast.Status {
        if (buffer.len < comp.len) return .{ .failure = true, .buffer_too_small = true };
        @memcpy(buffer[0..comp.len], comp);
        buf_size.* = comp.len;
        return .{ .success = true };
    }
};

const comp_vtable = tc.TileCacheCompressor.VTable{
    .maxCompressedSize = NoopCompressor.maxSize,
    .compress = NoopCompressor.compress,
    .decompress = NoopCompressor.decompress,
};

// --- MeshProcess: помечает полигоны тайла как проходимые ---
fn meshProcess(_: *anyopaque, _: *anyopaque, poly_areas: []u8, poly_flags: []u16) void {
    for (poly_areas, 0..) |*ar, i| {
        if (ar.* == tc.TILECACHE_WALKABLE_AREA or area_types.get(ar.*) == null)
            ar.* = @intFromEnum(sample.SamplePolyAreas.ground);
        poly_flags[i] = area_types.flagsFor(ar.*);
    }
}

const mp_vtable = tc.TileCacheMeshProcess.VTable{ .process = meshProcess };

const Obstacle = struct { ref: tc.ObstacleRef, pos: [3]f32, radius: f32, height: f32 };

pub const SampleTempObstacles = struct {
    alloc: std.mem.Allocator,
    settings: sample.CommonSettings = .{},
    tile_size: f32 = 48.0,
    geom: ?*InputGeom = null,
    bctx: *BuildContext,
    dd_gl: *ddgl.DebugDrawGL,

    build_gen: u32 = 0,
    build_time_ms: f32 = 0,
    keep_inter: bool = false,

    navmesh: ?dt.NavMesh = null,
    tilecache: ?tc.TileCache = null,
    comp_iface: tc.TileCacheCompressor = undefined,
    mp_iface: tc.TileCacheMeshProcess = undefined,
    dummy: u8 = 0,

    obstacles: std.array_list.Managed(Obstacle),

    pub fn init(alloc: std.mem.Allocator, bctx: *BuildContext, dd_gl: *ddgl.DebugDrawGL) SampleTempObstacles {
        return .{ .alloc = alloc, .bctx = bctx, .dd_gl = dd_gl, .obstacles = std.array_list.Managed(Obstacle).init(alloc) };
    }

    pub fn deinit(self: *SampleTempObstacles) void {
        if (self.tilecache) |*t| t.deinit();
        if (self.navmesh) |*n| n.deinit();
        self.obstacles.deinit();
    }

    pub fn setGeom(self: *SampleTempObstacles, geom: *InputGeom) void {
        self.geom = geom;
        self.cleanup();
    }

    fn cleanup(self: *SampleTempObstacles) void {
        if (self.tilecache) |*t| t.deinit();
        if (self.navmesh) |*n| n.deinit();
        self.tilecache = null;
        self.navmesh = null;
        self.obstacles.clearRetainingCapacity();
    }

    pub fn navMesh(self: *SampleTempObstacles) ?*dt.NavMesh {
        if (self.navmesh) |*n| return n;
        return null;
    }

    pub fn build(self: *SampleTempObstacles) bool {
        const geom = self.geom orelse return false;
        if (geom.triCount() == 0) return false;
        self.cleanup();
        self.bctx.resetLog();
        const ctx = self.bctx.context();
        const s = &self.settings;

        var timer = io_util.PerfTimer.start();

        const cs = s.cell_size;
        const ch = s.cell_height;
        const bmin = Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]);
        const bmax = Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]);

        var gw: i32 = 0;
        var gh: i32 = 0;
        recast.RecastConfig.calcGridSize(bmin, bmax, cs, &gw, &gh);
        const ts: i32 = @intFromFloat(self.tile_size);
        const tw = @divTrunc(gw + ts - 1, ts);
        const th = @divTrunc(gh + ts - 1, ts);
        const tcs = self.tile_size * cs;

        // навмеш (multi-tile) — резерв с запасом на слои
        const tile_bits: u5 = @intCast(@min(recast.math.ilog2(recast.math.nextPow2(@intCast(tw * th * 4))), 14));
        const poly_bits: u5 = @intCast(22 - @as(u32, tile_bits));
        var nav_params = dt.NavMeshParams.init();
        nav_params.orig = bmin;
        nav_params.tile_width = tcs;
        nav_params.tile_height = tcs;
        nav_params.max_tiles = @as(i32, 1) << tile_bits;
        nav_params.max_polys = @as(i32, 1) << poly_bits;
        var navmesh = dt.NavMesh.init(self.alloc, nav_params) catch return false;
        errdefer navmesh.deinit();

        // tilecache
        self.comp_iface = .{ .ptr = @ptrCast(&self.dummy), .vtable = &comp_vtable };
        self.mp_iface = .{ .ptr = @ptrCast(&self.dummy), .vtable = &mp_vtable };
        var tc_params = std.mem.zeroes(tc.TileCacheParams);
        tc_params.orig = .{ bmin.x, bmin.y, bmin.z };
        tc_params.cs = cs;
        tc_params.ch = ch;
        tc_params.width = ts;
        tc_params.height = ts;
        tc_params.walkable_height = s.agent_height;
        tc_params.walkable_radius = s.agent_radius;
        tc_params.walkable_climb = s.agent_max_climb;
        tc_params.max_simplification_error = s.edge_max_error;
        tc_params.max_tiles = tw * th * 4;
        tc_params.max_obstacles = 128;
        var tilecache = tc.TileCache.init(self.alloc, &tc_params, &self.comp_iface, &self.mp_iface) catch return false;
        errdefer tilecache.deinit();

        // per-tile слои
        var ty: i32 = 0;
        while (ty < th) : (ty += 1) {
            var tx: i32 = 0;
            while (tx < tw) : (tx += 1) {
                self.rasterizeTileLayers(ctx, geom, tx, ty, bmin, bmax, &tilecache) catch {};
                _ = tilecache.buildNavMeshTilesAt(tx, ty, &navmesh) catch {};
            }
        }

        self.tilecache = tilecache;
        self.navmesh = navmesh;
        self.build_time_ms = timer.readMs();
        self.build_gen +%= 1;
        ctx.log(.progress, "TempObstacles: {d}x{d} tiles in {d:.1} ms", .{ tw, th, self.build_time_ms });
        return true;
    }

    fn rasterizeTileLayers(self: *SampleTempObstacles, ctx: *recast.Context, geom: *InputGeom, tx: i32, ty: i32, bmin: Vec3, bmax: Vec3, tilecache: *tc.TileCache) !void {
        const a = self.alloc;
        const s = &self.settings;
        const cs = s.cell_size;
        const ch = s.cell_height;
        const walkable_height: i32 = @intFromFloat(@ceil(s.agent_height / ch));
        const walkable_climb: i32 = @intFromFloat(@floor(s.agent_max_climb / ch));
        const walkable_radius: i32 = @intFromFloat(@ceil(s.agent_radius / cs));
        const border_size = walkable_radius + 3;
        const tcs = self.tile_size * cs;

        const tbmin = Vec3.init(bmin.x + @as(f32, @floatFromInt(tx)) * tcs, bmin.y, bmin.z + @as(f32, @floatFromInt(ty)) * tcs);
        const exp = @as(f32, @floatFromInt(border_size)) * cs;
        const hbmin = Vec3.init(tbmin.x - exp, tbmin.y, tbmin.z - exp);
        const hbmax = Vec3.init(tbmin.x + tcs + exp, bmax.y, tbmin.z + tcs + exp);
        const width: i32 = @as(i32, @intFromFloat(self.tile_size)) + border_size * 2;

        var hf = try recast.Heightfield.init(a, width, width, hbmin, hbmax, cs, ch);
        defer hf.deinit();

        const ntris = geom.triCount();
        const areas = try a.alloc(u8, ntris);
        defer a.free(areas);
        @memset(areas, 0); // NULL_AREA: не-walkable грани должны остаться 0 (как upstream memset)
        rc.filter.markWalkableTriangles(ctx, s.agent_max_slope, geom.verts.items, geom.tris.items, areas);
        try rc.rasterization.rasterizeTriangles(ctx, geom.verts.items, geom.tris.items, areas, &hf, walkable_climb);

        // Фильтры условно по переключателям UI (1-в-1 Sample_TempObstacles::rasterizeTileLayers).
        // Partitioning здесь не выбирается: TileCache всегда использует layer-партишн
        // через rcBuildHeightfieldLayers (см. ниже), как в оригинале — s.partition_type не применяется.
        if (s.filter_low_hanging_obstacles)
            rc.filter.filterLowHangingWalkableObstacles(ctx, walkable_climb, &hf);
        if (s.filter_ledge_spans)
            rc.filter.filterLedgeSpans(ctx, walkable_height, walkable_climb, &hf);
        if (s.filter_walkable_low_height_spans)
            rc.filter.filterWalkableLowHeightSpans(ctx, walkable_height, &hf);

        const span_count = rc.compact.getHeightFieldSpanCount(ctx, &hf);
        var chf = try recast.CompactHeightfield.init(a, width, width, @intCast(span_count), walkable_height, walkable_climb, hbmin, hbmax, cs, ch, border_size);
        defer chf.deinit();
        try rc.compact.buildCompactHeightfield(ctx, walkable_height, walkable_climb, &hf, &chf);
        try rc.area.erodeWalkableArea(ctx, walkable_radius, &chf, a);
        for (geom.volumes.items) |*vol| {
            const nv: usize = @intCast(vol.nverts);
            rc.area.markConvexPolyArea(ctx, vol.verts[0 .. nv * 3], nv, vol.hmin, vol.hmax, vol.area, &chf);
        }

        var lset = rc.HeightfieldLayerSet.init(a);
        defer lset.deinit();
        try rc.layers.buildHeightfieldLayers(ctx, &chf, border_size, walkable_height, &lset, a);

        const nlayers: usize = @min(lset.layerCount(), 255);
        for (0..nlayers) |i| {
            const layer = &lset.layers[i];
            var header = std.mem.zeroes(tc.TileCacheLayerHeader);
            header.magic = tc.TILECACHE_MAGIC;
            header.version = tc.TILECACHE_VERSION;
            header.tx = tx;
            header.ty = ty;
            header.tlayer = @intCast(i);
            header.bmin = layer.bmin.toArray();
            header.bmax = layer.bmax.toArray();
            header.hmin = @intCast(layer.hmin);
            header.hmax = @intCast(layer.hmax);
            header.width = @intCast(layer.width);
            header.height = @intCast(layer.height);
            header.minx = @intCast(layer.minx);
            header.maxx = @intCast(layer.maxx);
            header.miny = @intCast(layer.miny);
            header.maxy = @intCast(layer.maxy);

            const data = tc.builder.buildTileCacheLayer(&self.comp_iface, &header, layer.heights, layer.areas, layer.cons, a) catch continue;
            _ = tilecache.addTile(data, .{}) catch {
                a.free(data);
            };
        }
    }

    pub fn addObstacle(self: *SampleTempObstacles, pos: [3]f32) void {
        const t = if (self.tilecache) |*tt| tt else return;
        const radius: f32 = 1.0;
        const height: f32 = 2.0;
        const ref = t.addObstacle(&pos, radius, height) catch return;
        self.obstacles.append(.{ .ref = ref, .pos = pos, .radius = radius, .height = height }) catch {};
        self.applyUpdates();
    }

    pub fn removeObstacleNear(self: *SampleTempObstacles, pos: [3]f32) void {
        const t = if (self.tilecache) |*tt| tt else return;
        var best: ?usize = null;
        var bestd: f32 = std.math.floatMax(f32);
        for (self.obstacles.items, 0..) |o, i| {
            const dx = o.pos[0] - pos[0];
            const dz = o.pos[2] - pos[2];
            const d = dx * dx + dz * dz;
            if (d < bestd) {
                bestd = d;
                best = i;
            }
        }
        if (best) |i| {
            t.removeObstacle(self.obstacles.items[i].ref) catch {};
            _ = self.obstacles.orderedRemove(i);
            self.applyUpdates();
        }
    }

    fn applyUpdates(self: *SampleTempObstacles) void {
        const t = if (self.tilecache) |*tt| tt else return;
        const nm = if (self.navmesh) |*n| n else return;
        var up_to_date = false;
        var guard: u32 = 0;
        while (!up_to_date and guard < 64) : (guard += 1) {
            _ = t.update(0, nm, &up_to_date) catch break;
        }
    }

    pub fn update(self: *SampleTempObstacles, delta: f32) void {
        const t = if (self.tilecache) |*tt| tt else return;
        const nm = if (self.navmesh) |*n| n else return;
        var up_to_date = false;
        _ = t.update(delta, nm, &up_to_date) catch {};
    }

    pub fn onClick(self: *SampleTempObstacles, _: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        if (shift) self.removeObstacleNear(ray_hit.*) else self.addObstacle(ray_hit.*);
    }

    pub fn render(self: *SampleTempObstacles) void {
        self.dd_gl.area_to_col = sample.sampleAreaToCol;
        const dd = self.dd_gl.debugDraw();
        if (self.navmesh) |*n| dbg.debugDrawNavMesh(dd, n, 0);

        // препятствия (цилиндры)
        const col = dbg.rgba(220, 64, 0, 200);
        for (self.obstacles.items) |o| {
            dd.begin(.lines, 1.0);
            const segs = 16;
            var i: usize = 0;
            while (i < segs) : (i += 1) {
                const a0 = @as(f32, @floatFromInt(i)) / segs * std.math.tau;
                const a1 = @as(f32, @floatFromInt(i + 1)) / segs * std.math.tau;
                dd.vertexXYZ(o.pos[0] + @cos(a0) * o.radius, o.pos[1], o.pos[2] + @sin(a0) * o.radius, col);
                dd.vertexXYZ(o.pos[0] + @cos(a1) * o.radius, o.pos[1], o.pos[2] + @sin(a1) * o.radius, col);
                dd.vertexXYZ(o.pos[0] + @cos(a0) * o.radius, o.pos[1] + o.height, o.pos[2] + @sin(a0) * o.radius, col);
                dd.vertexXYZ(o.pos[0] + @cos(a1) * o.radius, o.pos[1] + o.height, o.pos[2] + @sin(a1) * o.radius, col);
            }
            dd.end();
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

    pub fn drawSettings(self: *SampleTempObstacles) void {
        const s = &self.settings;
        var gw: i32 = 0;
        var gh: i32 = 0;
        if (self.geom) |g| {
            const bmin = Vec3.init(g.bmin[0], g.bmin[1], g.bmin[2]);
            const bmax = Vec3.init(g.bmax[0], g.bmax[1], g.bmax[2]);
            recast.RecastConfig.calcGridSize(bmin, bmax, s.cell_size, &gw, &gh);
        }
        sample.drawCommonSettings(s, gw, gh);

        _ = dvui.checkbox(@src(), &self.keep_inter, "Keep Itermediate Results", .{});
        dvui.labelNoFmt(@src(), "Tiling", .{}, .{});
        ui.sliderInt(@src(), "Tile Size: {d:.0}", &self.tile_size, 16, 128);

        if (self.geom != null and gw > 0) {
            const ts: i32 = @intFromFloat(self.tile_size);
            const tw = @divTrunc(gw + ts - 1, ts);
            const th = @divTrunc(gh + ts - 1, ts);
            dvui.label(@src(), "Tiles  {d} x {d}", .{ tw, th }, .{});
            const tile_bits: u5 = @intCast(@min(recast.math.ilog2(recast.math.nextPow2(@intCast(tw * th * 4))), 14));
            const poly_bits: u5 = @intCast(22 - @as(u32, tile_bits));
            dvui.label(@src(), "Max Tiles  {d}", .{@as(i32, 1) << tile_bits}, .{});
            dvui.label(@src(), "Max Polys  {d}", .{@as(i32, 1) << poly_bits}, .{});
        }

        ui.section(@src(), "Tile Cache");
        dvui.label(@src(), "Obstacles  {d}", .{self.obstacles.items.len}, .{});
        dvui.label(@src(), "Navmesh Build Time  {d:.1} ms", .{self.build_time_ms}, .{});

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "Save", .{}, .{})) self.saveNavMesh();
        if (dvui.button(@src(), "Load", .{}, .{})) self.loadNavMesh();
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
    }

    const SAVE_PATH = "temp_navmesh.bin";

    fn saveNavMesh(self: *SampleTempObstacles) void {
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

    fn loadNavMesh(self: *SampleTempObstacles) void {
        const loaded = nav_io.load(self.alloc, SAVE_PATH) catch |e| {
            self.bctx.context().log(.err, "Load failed: {s}", .{@errorName(e)});
            return;
        };
        self.cleanup();
        self.navmesh = loaded;
        self.build_gen +%= 1;
        self.bctx.context().log(.progress, "Loaded {s}", .{SAVE_PATH});
    }

    pub fn drawDebugMode(self: *SampleTempObstacles) void {
        _ = self;
        dvui.labelNoFmt(@src(), "Navmesh", .{}, .{});
    }
};
