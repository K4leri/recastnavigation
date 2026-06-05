//! OffMeshConnectionTool — создание off-mesh связей (прыжки/лестницы).
//! Порт RecastDemo/Tool_OffMeshConnection.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const InputGeom = @import("input_geom.zig").InputGeom;
const ddgl = @import("debug_draw_gl.zig");
const sample = @import("sample.zig");
const ui = @import("ui.zig");
const UndoStack = @import("edit/undo_stack.zig").UndoStack;
const OffMeshData = @import("edit/edit_op.zig").OffMeshData;
const dbg = recast.debug;

pub const OffMeshConnectionTool = struct {
    geom: *InputGeom,
    dd_gl: *ddgl.DebugDrawGL,
    hit_pos: [3]f32 = .{ 0, 0, 0 },
    has_hit: bool = false,
    bidir: bool = true,
    dirty: bool = false,
    undo: *UndoStack,

    pub fn init(geom: *InputGeom, dd_gl: *ddgl.DebugDrawGL, undo: *UndoStack) OffMeshConnectionTool {
        return .{ .geom = geom, .dd_gl = dd_gl, .undo = undo };
    }

    pub fn onClick(self: *OffMeshConnectionTool, _: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        if (shift) {
            // Shift cancels an in-progress start; otherwise it deletes the nearest
            // endpoint (1-в-1 upstream Tool_OffMeshConnection: nearest within
            // agentRadius-ish of either endpoint).
            if (self.has_hit) {
                self.has_hit = false; // отмена текущей
                return;
            }
            const idx = self.nearestConnection(ray_hit) orelse return;
            const captured = OffMeshData.capture(self.geom, idx);
            self.geom.deleteOffMeshConnection(idx);
            self.undo.record(.{ .delete_offmesh = .{ .index = idx, .data = captured } });
            self.dirty = true;
            return;
        }
        if (!self.has_hit) {
            self.hit_pos = ray_hit.*;
            self.has_hit = true;
        } else {
            self.geom.addOffMeshConnection(
                self.hit_pos,
                ray_hit.*,
                0.6,
                @as(u8, @intFromBool(self.bidir)),
                @intFromEnum(sample.SamplePolyAreas.jump),
                sample.SamplePolyFlags.jump,
            ) catch {};
            // Capture the just-appended connection (all 6 fields) for undo.
            if (self.geom.offMeshCount() > 0) {
                const captured = OffMeshData.capture(self.geom, self.geom.offMeshCount() - 1);
                self.undo.record(.{ .add_offmesh = captured });
            }
            self.has_hit = false;
            self.dirty = true;
        }
    }

    /// Index of the off-mesh connection whose nearest endpoint is closest to `p`
    /// (within a small radius), or null if none — used by shift-delete.
    fn nearestConnection(self: *const OffMeshConnectionTool, p: *const [3]f32) ?usize {
        var best: ?usize = null;
        var best_d: f32 = std.math.floatMax(f32);
        const r2: f32 = 1.0; // ~1m squared pick tolerance
        var i: usize = 0;
        while (i < self.geom.offMeshCount()) : (i += 1) {
            const v = self.geom.off_verts.items[i * 6 ..][0..6];
            const d0 = distSq(p, v[0..3]);
            const d1 = distSq(p, v[3..6]);
            const d = @min(d0, d1);
            if (d < best_d and d < r2) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }

    pub fn render(self: *OffMeshConnectionTool) void {
        const dd = self.dd_gl.debugDraw();
        // Committed connections are drawn by the sample render (always visible);
        // here we only show the in-progress start point.
        if (self.has_hit) {
            const col = dbg.rgba(220, 32, 128, 255);
            dd.begin(.lines, 1.0);
            dd.vertexXYZ(self.hit_pos[0], self.hit_pos[1], self.hit_pos[2], col);
            dd.vertexXYZ(self.hit_pos[0], self.hit_pos[1] + 0.6, self.hit_pos[2], col);
            dd.end();
        }
    }

    pub fn drawMenu(self: *OffMeshConnectionTool) void {
        if (ui.radio(@src(), !self.bidir, "One Way", 0)) self.bidir = false;
        if (ui.radio(@src(), self.bidir, "Bidirectional", 1)) self.bidir = true;
        dvui.labelNoFmt(@src(), "LMB: create.  Shift+LMB: delete", .{}, .{});
    }
};

inline fn distSq(a: *const [3]f32, b: []const f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}
