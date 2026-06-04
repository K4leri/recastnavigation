//! ConvexVolumeTool — создание выпуклых объёмов (зоны областей).
//! Порт RecastDemo/Tool_ConvexVolume. 1-в-1 с оригиналом:
//!   ЛКМ — добавить точку; клик по последней (красной) точке — построить объём
//!   (выпуклая оболочка всех точек). Shift+ЛКМ — удалить объём под курсором.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ig = @import("input_geom.zig");
const InputGeom = ig.InputGeom;
const ddgl = @import("debug_draw_gl.zig");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const poly_flags = @import("poly_flags.zig");
const ui = @import("ui.zig");
const dbg = recast.debug;
const rc = recast.recast;

const MAX_PTS = ig.MAX_CONVEXVOL_PTS;

pub const ConvexVolumeTool = struct {
    geom: *InputGeom,
    dd_gl: *ddgl.DebugDrawGL,
    pts: std.array_list.Managed(f32),
    hull: [MAX_PTS]usize = undefined,
    nhull: usize = 0,
    area: u8 = 4, // grass (default) — index into the area_types registry
    box_height: f32 = 6.0,
    box_descent: f32 = 1.0,
    poly_offset: f32 = 0.0,
    dirty: bool = false,
    editor: ?Edit = null, // open add/edit dialog for an area type

    pub fn init(alloc: std.mem.Allocator, geom: *InputGeom, dd_gl: *ddgl.DebugDrawGL) ConvexVolumeTool {
        return .{ .geom = geom, .dd_gl = dd_gl, .pts = std.array_list.Managed(f32).init(alloc) };
    }

    pub fn deinit(self: *ConvexVolumeTool) void {
        self.pts.deinit();
    }

    fn numPoints(self: *const ConvexVolumeTool) usize {
        return self.pts.items.len / 3;
    }

    fn reset(self: *ConvexVolumeTool) void {
        self.pts.clearRetainingCapacity();
        self.nhull = 0;
    }

    pub fn onClick(self: *ConvexVolumeTool, _: *const [3]f32, p: *const [3]f32, shift: bool) void {
        if (shift) {
            // Удаление: найти объём, внутри которого находится клик.
            var nearest: ?usize = null;
            for (self.geom.volumes.items, 0..) |*vol, i| {
                const nv: usize = @intCast(vol.nverts);
                if (pointInPoly(nv, vol.verts[0 .. nv * 3], p) and
                    p[1] >= vol.hmin and p[1] <= vol.hmax)
                {
                    nearest = i;
                }
            }
            if (nearest) |idx| {
                self.geom.deleteConvexVolume(idx);
                self.dirty = true;
            }
            return;
        }

        // Создание.
        const np = self.numPoints();
        // Если кликнули по последней точке — строим объём.
        if (np > 0 and vdistSqr(p, self.pts.items[(np - 1) * 3 ..][0..3]) < sqr(0.2)) {
            if (self.nhull > 2) {
                var verts: [MAX_PTS * 3]f32 = undefined;
                for (0..self.nhull) |i| {
                    const src = self.hull[i] * 3;
                    verts[i * 3 + 0] = self.pts.items[src + 0];
                    verts[i * 3 + 1] = self.pts.items[src + 1];
                    verts[i * 3 + 2] = self.pts.items[src + 2];
                }

                var minh: f32 = std.math.floatMax(f32);
                for (0..self.nhull) |i| minh = @min(minh, verts[i * 3 + 1]);
                minh -= self.box_descent;
                const maxh = minh + self.box_height;

                if (self.poly_offset > 0.01) {
                    var offset: [MAX_PTS * 2 * 3]f32 = undefined;
                    const noffset = rc.area.offsetPoly(
                        verts[0 .. self.nhull * 3],
                        @intCast(self.nhull),
                        self.poly_offset,
                        &offset,
                        MAX_PTS * 2,
                    );
                    if (noffset > 0) {
                        const no: usize = @intCast(noffset);
                        // NOTE: explicit usize — @min(no, MAX_PTS) would otherwise
                        // narrow the result type to u4 (MAX_PTS=12 fits 0..15), and
                        // `cap * 3` would then overflow u4 (e.g. 8*3=24). Hard crash.
                        const cap: usize = @min(no, MAX_PTS);
                        self.geom.addConvexVolume(
                            offset[0 .. cap * 3],
                            @intCast(cap),
                            minh,
                            maxh,
                            self.area,
                        ) catch {};
                        self.dirty = true;
                    }
                } else {
                    self.geom.addConvexVolume(
                        verts[0 .. self.nhull * 3],
                        @intCast(self.nhull),
                        minh,
                        maxh,
                        self.area,
                    ) catch {};
                    self.dirty = true;
                }
            }
            self.reset();
        } else {
            // Добавляем новую точку и пересчитываем оболочку.
            if (np >= MAX_PTS) return;
            self.pts.appendSlice(p) catch return;
            if (self.numPoints() > 1) {
                self.nhull = convexHull(self.pts.items, self.numPoints(), &self.hull);
            } else {
                self.nhull = 0;
            }
        }
    }

    pub fn render(self: *ConvexVolumeTool) void {
        const dd = self.dd_gl.debugDraw();
        // Committed volumes are drawn by the sample render (always visible);
        // here we only show the in-progress hull being edited.

        const np = self.numPoints();

        // Высотный диапазон текущей заготовки.
        var minh: f32 = std.math.floatMax(f32);
        for (0..np) |i| minh = @min(minh, self.pts.items[i * 3 + 1]);
        minh -= self.box_descent;
        const maxh = minh + self.box_height;

        // Точки (последняя — красная).
        dd.begin(.points, 4.0);
        for (0..np) |i| {
            const col = if (i == np - 1)
                dbg.rgba(240, 32, 16, 255)
            else
                dbg.rgba(255, 255, 255, 255);
            dd.vertexXYZ(self.pts.items[i * 3 + 0], self.pts.items[i * 3 + 1] + 0.1, self.pts.items[i * 3 + 2], col);
        }
        dd.end();

        // Контур текущей оболочки (стены).
        const lcol = dbg.rgba(255, 255, 255, 64);
        dd.begin(.lines, 2.0);
        if (self.nhull > 0) {
            var j: usize = self.nhull - 1;
            var i: usize = 0;
            while (i < self.nhull) : (i += 1) {
                const vi = self.pts.items[self.hull[j] * 3 ..][0..3];
                const vj = self.pts.items[self.hull[i] * 3 ..][0..3];
                dd.vertexXYZ(vj[0], minh, vj[2], lcol);
                dd.vertexXYZ(vi[0], minh, vi[2], lcol);
                dd.vertexXYZ(vj[0], maxh, vj[2], lcol);
                dd.vertexXYZ(vi[0], maxh, vi[2], lcol);
                dd.vertexXYZ(vj[0], minh, vj[2], lcol);
                dd.vertexXYZ(vj[0], maxh, vj[2], lcol);
                j = i;
            }
        }
        dd.end();
    }

    pub fn drawMenu(self: *ConvexVolumeTool) void {
        ui.slider(@src(), "Shape Height = {d:.1}", &self.box_height, 0.1, 20.0);
        ui.slider(@src(), "Shape Descent = {d:.1}", &self.box_descent, 0.1, 20.0);
        ui.slider(@src(), "Poly Offset = {d:.1}", &self.poly_offset, 0.0, 10.0);

        // Area Type — pick the type painted into the next volume (radio), plus a
        // pencil to open its editor. The list is the runtime registry, so custom
        // types appear here too.
        dvui.labelNoFmt(@src(), "Area Type", .{}, .{});
        {
            var id: usize = 0;
            while (id < area_types.MAX_AREA_TYPES) : (id += 1) {
                const t = area_types.get(id) orelse continue;
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal });
                defer row.deinit();
                if (ui.radio(@src(), @as(usize, self.area) == id, t.name(), id)) self.area = @intCast(id);
                if (dvui.buttonIcon(@src(), "edit", dvui.entypo.pencil, .{}, .{}, .{ .id_extra = id, .gravity_x = 1.0, .gravity_y = 0.5 })) {
                    self.editor = Edit.fromType(@intCast(id), t);
                }
            }
        }
        // "+ Add" opens a draft dialog; the new type is only created if the user
        // confirms with OK (Cancel/Esc/close discards it).
        if (dvui.button(@src(), "+ Add Area Type", .{}, .{})) {
            self.editor = Edit.newDraft();
        }
        if (self.editor != null) self.drawEditor();

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "Clear Shape", .{}, .{})) self.reset();
        dvui.label(@src(), "points: {d}", .{self.numPoints()}, .{});
        dvui.labelNoFmt(@src(), "LMB: add point  click red point: build", .{}, .{});
        dvui.labelNoFmt(@src(), "Shift+LMB: delete shape", .{}, .{});
    }

    /// Modal add/edit dialog for an area type: name, colour picker, reachability
    /// flags, movement cost. OK commits; Cancel / Esc / close discards (so a new
    /// type is only created on confirm).
    fn drawEditor(self: *ConvexVolumeTool) void {
        const ed = &self.editor.?;
        var win = dvui.floatingWindow(@src(), .{ .rect = &ed.rect, .open_flag = &ed.open }, .{});
        defer win.deinit();
        win.autoSize(); // fit height to content so OK/Cancel are always visible
        _ = dvui.windowHeader(if (ed.is_new) "New Area Type" else "Edit Area Type", "", &ed.open);

        dvui.labelNoFmt(@src(), "Name", .{}, .{});
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &ed.name_buf } }, .{ .expand = .horizontal });
            te.deinit(); // textEntry returns a widget that must be closed
        }

        dvui.labelNoFmt(@src(), "Colour", .{}, .{});
        _ = dvui.colorPicker(@src(), .{ .hsv = &ed.hsv, .dir = .vertical, .sliders = .rgb, .hex_text_entry = true }, .{});

        dvui.labelNoFmt(@src(), "Flags (reachability — needs a rebuild)", .{}, .{});
        {
            var i: usize = 0;
            while (i < poly_flags.MAX_FLAGS) : (i += 1) {
                const fl = poly_flags.get(i) orelse continue;
                const bit = poly_flags.bitOf(i).?;
                var on = (ed.flags & bit) != 0;
                if (dvui.checkbox(@src(), &on, fl.name(), .{ .id_extra = i })) {
                    if (on) ed.flags |= bit else ed.flags &= ~bit;
                }
            }
        }

        _ = dvui.sliderEntry(@src(), "cost {d:.2}", .{ .value = &ed.cost, .min = 0, .max = 20, .interval = null }, .{ .expand = .horizontal });

        {
            var bb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
            defer bb.deinit();
            if (dvui.button(@src(), "Cancel", .{}, .{})) ed.open = false;
            if (dvui.button(@src(), "OK", .{}, .{})) {
                self.commitEditor();
                return; // self.editor is now null
            }
        }

        // Esc cancels (FloatingWindow doesn't auto-close on Esc).
        for (dvui.events()) |*e| {
            if (e.evt == .key and e.evt.key.action == .down and e.evt.key.code == .escape) ed.open = false;
        }

        // Closed via X / Cancel / Esc without OK -> discard (nothing added).
        if (!ed.open) self.editor = null;
    }

    fn commitEditor(self: *ConvexVolumeTool) void {
        const ed = &self.editor.?;
        const rgb = ed.hsv.toColor();
        const name = std.mem.sliceTo(&ed.name_buf, 0);
        const t: ?*area_types.AreaType = if (ed.is_new) blk: {
            const id = area_types.addType() orelse break :blk null;
            self.area = id; // select the freshly added type for painting
            break :blk area_types.get(id);
        } else area_types.get(ed.edit_id);
        if (t) |at| {
            at.setName(name);
            at.r = rgb.r;
            at.g = rgb.g;
            at.b = rgb.b;
            at.a = 255;
            at.flags = ed.flags;
            at.cost = ed.cost;
        }
        area_types.costs_dirty = true;
        area_types.rebuild_needed = true; // flags/type-list change needs a rebuild
        self.editor = null;
    }
};

const F = area_types.Flags;

/// Working copy for the add/edit dialog (kept separate from the registry so a new
/// type is only committed on OK).
const Edit = struct {
    open: bool = true,
    is_new: bool,
    edit_id: u8 = 0,
    name_buf: [32]u8 = [_]u8{0} ** 32,
    hsv: dvui.Color.HSV = .{},
    flags: u16 = F.walk,
    cost: f32 = 1.0,
    // Placed just to the right of the Tools panel (x = padw 10 + colw 250 + padw 10)
    // so it doesn't cover it. dvui writes the dragged position back here.
    rect: dvui.Rect = .{ .x = 270, .y = 10, .w = 320, .h = 460 },

    fn fromType(id: u8, t: *const area_types.AreaType) Edit {
        var e = Edit{ .is_new = false, .edit_id = id, .hsv = dvui.Color.HSV.fromColor(.{ .r = t.r, .g = t.g, .b = t.b, .a = 255 }), .flags = t.flags, .cost = t.cost };
        const n = @min(t.name().len, 31);
        @memcpy(e.name_buf[0..n], t.name()[0..n]);
        e.name_buf[n] = 0;
        return e;
    }

    fn newDraft() Edit {
        var e = Edit{ .is_new = true, .hsv = dvui.Color.HSV.fromColor(.{ .r = 255, .g = 128, .b = 0, .a = 255 }) };
        @memcpy(e.name_buf[0..8], "New Area");
        e.name_buf[8] = 0;
        return e;
    }
};


inline fn sqr(x: f32) f32 {
    return x * x;
}

/// Квадрат расстояния в XZ-плоскости (rcVdistSqr использует XYZ; оригинал тоже XYZ).
inline fn vdistSqr(a: *const [3]f32, b: *const [3]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return dx * dx + dy * dy + dz * dz;
}

/// Точка внутри полигона (XZ), ray-casting. 1-в-1 с pointInPoly.
fn pointInPoly(nvert: usize, verts: []const f32, p: *const [3]f32) bool {
    var result = false;
    var j: usize = nvert - 1;
    var i: usize = 0;
    while (i < nvert) : (i += 1) {
        const vi = verts[i * 3 ..][0..3];
        const vj = verts[j * 3 ..][0..3];
        if (((vi[2] > p[2]) != (vj[2] > p[2])) and
            (p[0] < (vj[0] - vi[0]) * (p[2] - vi[2]) / (vj[2] - vi[2]) + vi[0]))
        {
            result = !result;
        }
        j = i;
    }
    return result;
}

/// 'c' слева от прямой 'a'-'b' (XZ). 1-в-1 с left().
inline fn left(a: []const f32, b: []const f32, c: []const f32) bool {
    const ux1 = b[0] - a[0];
    const vy1 = b[2] - a[2];
    const ux2 = c[0] - a[0];
    const vy2 = c[2] - a[2];
    return ux1 * vy2 - vy1 * ux2 < 0;
}

/// 'a' более нижне-левая чем 'b'. 1-в-1 с comparePoints().
inline fn comparePoints(a: []const f32, b: []const f32) bool {
    if (a[0] < b[0]) return true;
    if (a[0] > b[0]) return false;
    if (a[2] < b[2]) return true;
    if (a[2] > b[2]) return false;
    return false;
}

/// Выпуклая оболочка по XZ (gift wrapping), возвращает индексы вершин.
/// 1-в-1 с convexhull() из Tool_ConvexVolume.cpp.
fn convexHull(pts: []const f32, npts: usize, out: []usize) usize {
    // Нижне-левая точка.
    var hull: usize = 0;
    for (1..npts) |i| {
        if (comparePoints(pts[i * 3 ..][0..3], pts[hull * 3 ..][0..3])) hull = i;
    }
    // Gift wrap.
    var endpt: usize = 0;
    var i: usize = 0;
    while (true) {
        out[i] = hull;
        i += 1;
        endpt = 0;
        var j: usize = 1;
        while (j < npts) : (j += 1) {
            if (hull == endpt or left(pts[hull * 3 ..][0..3], pts[endpt * 3 ..][0..3], pts[j * 3 ..][0..3])) {
                endpt = j;
            }
        }
        hull = endpt;
        if (endpt == out[0] or i >= out.len) break;
    }
    return i;
}
