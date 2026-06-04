//! NavMeshPruneTool — обрезка navmesh до достижимой области.
//! Порт RecastDemo/Tool_NavMeshPrune. 1-в-1 с оригиналом:
//!   ЛКМ — клик заливает (flood-fill по связности полигонов через линки тайла)
//!   достижимую от точки область, помечая её. "Prune Unselected" отключает
//!   (выставляет SamplePolyFlags.disabled) все НЕ помеченные полигоны.
//!
//! Связность считается ровно как upstream floodNavmesh: обход по списку линков
//! полигона (poly.first_link -> tile.links[i].next), сосед = tile.links[i].ref.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ddgl = @import("debug_draw_gl.zig");
const sample = @import("sample.zig");

const dt = recast.detour;
const dbg = recast.debug;
const PF = sample.SamplePolyFlags;

/// Per-tile / per-poly visited flags (порт NavmeshFlags). tileFlags[it] — слайс
/// длиной poly_count тайла it (или null, если тайл пуст). Индекс ip берётся из
/// decodePolyId — ровно как upstream getFlags/setFlags.
const NavmeshFlags = struct {
    alloc: std.mem.Allocator,
    navmesh: ?*const dt.NavMesh = null,
    tile_flags: []?[]u8 = &.{},

    fn deinit(self: *NavmeshFlags) void {
        self.clearStorage();
    }

    fn clearStorage(self: *NavmeshFlags) void {
        for (self.tile_flags) |maybe| {
            if (maybe) |s| self.alloc.free(s);
        }
        if (self.tile_flags.len > 0) self.alloc.free(self.tile_flags);
        self.tile_flags = &.{};
        self.navmesh = null;
    }

    /// Порт NavmeshFlags::init: аллоцирует флаги под каждый поли в каждом тайле.
    fn init(self: *NavmeshFlags, nav: *const dt.NavMesh) !void {
        self.clearStorage();
        self.navmesh = nav;

        const num_tiles: usize = @intCast(nav.max_tiles);
        if (num_tiles == 0) return;

        self.tile_flags = try self.alloc.alloc(?[]u8, num_tiles);
        for (self.tile_flags) |*slot| slot.* = null;

        for (0..num_tiles) |i| {
            const tile = &nav.tiles[i];
            const header = tile.header orelse continue;
            const pc: usize = @intCast(header.poly_count);
            const s = try self.alloc.alloc(u8, pc);
            @memset(s, 0);
            self.tile_flags[i] = s;
        }
    }

    /// Порт NavmeshFlags::clearAllFlags.
    fn clearAllFlags(self: *NavmeshFlags) void {
        for (self.tile_flags) |maybe| {
            if (maybe) |s| @memset(s, 0);
        }
    }

    /// Порт NavmeshFlags::getFlags. ref считается валидным (без bounds-check).
    fn getFlags(self: *const NavmeshFlags, ref: dt.PolyRef) u8 {
        const nav = self.navmesh.?;
        const d = nav.decodePolyId(ref);
        return self.tile_flags[d.tile].?[d.poly];
    }

    /// Порт NavmeshFlags::setFlags.
    fn setFlags(self: *NavmeshFlags, ref: dt.PolyRef, flags: u8) void {
        const nav = self.navmesh.?;
        const d = nav.decodePolyId(ref);
        self.tile_flags[d.tile].?[d.poly] = flags;
    }
};

/// Порт floodNavmesh: заливка по связности полигонов от start, пометка флагом flag.
/// Обход — ровно как upstream: по списку линков тайла (firstLink -> links[i].next).
fn floodNavmesh(nav: *const dt.NavMesh, flags: *NavmeshFlags, start: dt.PolyRef, flag: u8) void {
    // Если start невалиден (findNearestPoly не нашёл поли) — выходим.
    if (start == 0) return;
    // Если уже посещён — пропускаем.
    if (flags.getFlags(start) != 0) return;

    flags.setFlags(start, flag);

    var open_list = std.array_list.Managed(dt.PolyRef).init(flags.alloc);
    defer open_list.deinit();
    open_list.append(start) catch return;

    while (open_list.items.len > 0) {
        const ref = open_list.pop().?;

        // Текущий поли и тайл. ref уже проверен — берём без bounds-check (Unsafe).
        var tile: ?*const dt.MeshTile = null;
        var poly: ?*const dt.Poly = null;
        nav.getTileAndPolyByRefUnsafe(ref, &tile, &poly);
        const t = tile.?;
        const p = poly.?;

        // Обход линкованных полигонов.
        var i: u32 = p.first_link;
        while (i != dt.NULL_LINK) : (i = t.links[i].next) {
            const nei_ref = t.links[i].ref;
            // Пропуск невалидных и уже посещённых.
            if (nei_ref == 0 or flags.getFlags(nei_ref) != 0) continue;
            // Пометить как посещённый.
            flags.setFlags(nei_ref, flag);
            // Посетить соседей.
            open_list.append(nei_ref) catch return;
        }
    }
}

/// Порт disableUnvisitedPolys: всем НЕ помеченным полигонам выставить флаг disabled.
fn disableUnvisitedPolys(nav: *dt.NavMesh, flags: *NavmeshFlags) void {
    const num_tiles: usize = @intCast(nav.max_tiles);
    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const base = nav.getPolyRefBase(tile);
        const pc: usize = @intCast(header.poly_count);
        for (0..pc) |j| {
            const ref = base | @as(dt.PolyRef, @intCast(j));
            if (flags.getFlags(ref) == 0) {
                const f = nav.getPolyFlags(ref) catch 0;
                nav.setPolyFlags(ref, f | PF.disabled) catch {};
            }
        }
    }
}

pub const NavMeshPruneTool = struct {
    alloc: std.mem.Allocator,
    dd_gl: *ddgl.DebugDrawGL,

    navmesh: ?*dt.NavMesh = null,
    query: ?*dt.NavMeshQuery = null,
    filter: dt.QueryFilter,

    flags: NavmeshFlags,
    flags_active: bool = false,

    hit_pos: [3]f32 = .{ 0, 0, 0 },
    hit_pos_set: bool = false,

    // радиус крестика-маркера (upstream берёт sample->agentRadius)
    agent_radius: f32 = 0.6,

    pub fn init(alloc: std.mem.Allocator, dd_gl: *ddgl.DebugDrawGL) NavMeshPruneTool {
        return .{
            .alloc = alloc,
            .dd_gl = dd_gl,
            .filter = dt.QueryFilter.init(),
            .flags = .{ .alloc = alloc },
        };
    }

    pub fn deinit(self: *NavMeshPruneTool) void {
        self.flags.deinit();
        if (self.query) |q| q.deinit();
        self.query = null;
    }

    /// Порт NavMeshPruneTool::reset (вызывается при смене navmesh).
    pub fn setNavMesh(self: *NavMeshPruneTool, nm: ?*dt.NavMesh) void {
        if (self.query) |q| {
            q.deinit();
            self.query = null;
        }
        self.flags.clearStorage();
        self.flags_active = false;
        self.hit_pos_set = false;
        self.navmesh = nm;
        if (nm) |m| {
            var q = dt.NavMeshQuery.init(self.alloc) catch return;
            q.initQuery(m, 2048) catch {
                q.deinit();
                return;
            };
            self.query = q;
        }
    }

    pub fn setAgent(self: *NavMeshPruneTool, radius: f32) void {
        self.agent_radius = radius;
    }

    /// Порт NavMeshPruneTool::onClick.
    pub fn onClick(self: *NavMeshPruneTool, _: *const [3]f32, p: *const [3]f32, _: bool) void {
        const nav = self.navmesh orelse return;
        const q = self.query orelse return;

        self.hit_pos = p.*;
        self.hit_pos_set = true;

        if (!self.flags_active) {
            self.flags.init(nav) catch return;
            self.flags_active = true;
        }

        const ext = [3]f32{ 2, 4, 2 };
        var ref: dt.PolyRef = 0;
        var snap: [3]f32 = undefined;
        _ = q.findNearestPoly(p, &ext, &self.filter, &ref, &snap) catch {};

        floodNavmesh(nav, &self.flags, ref, 1);
    }

    /// Порт NavMeshPruneTool::render.
    pub fn render(self: *NavMeshPruneTool) void {
        const dd = self.dd_gl.debugDraw();

        if (self.hit_pos_set) {
            const r = self.agent_radius;
            const col = dbg.rgba(255, 255, 255, 255);
            const hp = self.hit_pos;
            dd.begin(.lines, 1.0);
            dd.vertexXYZ(hp[0] - r, hp[1], hp[2], col);
            dd.vertexXYZ(hp[0] + r, hp[1], hp[2], col);
            dd.vertexXYZ(hp[0], hp[1] - r, hp[2], col);
            dd.vertexXYZ(hp[0], hp[1] + r, hp[2], col);
            dd.vertexXYZ(hp[0], hp[1], hp[2] - r, col);
            dd.vertexXYZ(hp[0], hp[1], hp[2] + r, col);
            dd.end();
        }

        const nav = self.navmesh orelse return;
        if (!self.flags_active) return;

        const col = dbg.rgba(255, 255, 255, 128);
        const num_tiles: usize = @intCast(nav.max_tiles);
        for (0..num_tiles) |i| {
            const tile = &nav.tiles[i];
            const header = tile.header orelse continue;
            const base = nav.getPolyRefBase(tile);
            const pc: usize = @intCast(header.poly_count);
            for (0..pc) |j| {
                const ref = base | @as(dt.PolyRef, @intCast(j));
                if (self.flags.getFlags(ref) != 0) {
                    dbg.debugDrawNavMeshPoly(dd, nav, ref, col);
                }
            }
        }
    }

    /// Порт NavMeshPruneTool::drawMenuUI.
    pub fn drawMenu(self: *NavMeshPruneTool) void {
        dvui.labelNoFmt(@src(), "LMB: Click fill area.", .{}, .{});

        if (!self.flags_active) return;
        if (self.navmesh == null) return;

        if (dvui.button(@src(), "Clear Selection", .{}, .{})) {
            self.flags.clearAllFlags();
        }

        if (dvui.button(@src(), "Prune Unselected", .{}, .{})) {
            disableUnvisitedPolys(self.navmesh.?, &self.flags);
            self.flags.clearStorage();
            self.flags_active = false;
        }
    }
};
