//! OffMeshConnectionTool — создание off-mesh связей (прыжки/лестницы).
//! Порт RecastDemo/Tool_OffMeshConnection.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const InputGeom = @import("input_geom.zig").InputGeom;
const ddgl = @import("debug_draw_gl.zig");
const sample = @import("sample.zig");
const ui = @import("ui.zig");
const dbg = recast.debug;

pub const OffMeshConnectionTool = struct {
    geom: *InputGeom,
    dd_gl: *ddgl.DebugDrawGL,
    hit_pos: [3]f32 = .{ 0, 0, 0 },
    has_hit: bool = false,
    bidir: bool = true,
    dirty: bool = false,

    pub fn init(geom: *InputGeom, dd_gl: *ddgl.DebugDrawGL) OffMeshConnectionTool {
        return .{ .geom = geom, .dd_gl = dd_gl };
    }

    pub fn onClick(self: *OffMeshConnectionTool, _: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        if (shift) {
            self.has_hit = false; // отмена текущей
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
            self.has_hit = false;
            self.dirty = true;
        }
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
