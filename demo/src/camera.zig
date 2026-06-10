//! Камера демо — модель RecastDemo (main.cpp + AppState).
//! view = rotX(pitch) * rotY(yaw) * translate(-pos).
//! Управление: правая кнопка — орбита, колесо — зум, WASD/QE — полёт.

const std = @import("std");
const recast = @import("recast-nav");
const mat = @import("mat.zig");
const Vec3 = recast.math.Vec3;
const Mat4 = mat.Mat4;

pub const MOVE_SPEED: f32 = 4.0;
pub const FAST_MOVE_SPEED: f32 = 22.0;

pub const Camera = struct {
    eulers: [2]f32 = .{ 45, -45 }, // pitch, yaw (градусы)
    pos: Vec3 = Vec3.init(0, 0, 0),
    fov: f32 = 50.0,
    near: f32 = 1.0,
    far: f32 = 1000.0,

    pub fn view(self: Camera) Mat4 {
        const rx = Mat4.rotationX(self.eulers[0]);
        const ry = Mat4.rotationY(self.eulers[1]);
        const t = Mat4.translation(-self.pos.x, -self.pos.y, -self.pos.z);
        return rx.mul(ry).mul(t);
    }

    pub fn proj(self: Camera, aspect: f32) Mat4 {
        return Mat4.perspective(self.fov, aspect, self.near, self.far);
    }

    /// Орбита: dx/dy — смещение мыши в пикселях.
    pub fn rotate(self: *Camera, dx: f32, dy: f32) void {
        self.eulers[1] += dx; // yaw
        self.eulers[0] += dy; // pitch
        if (self.eulers[0] < -90) self.eulers[0] = -90;
        if (self.eulers[0] > 90) self.eulers[0] = 90;
    }

    /// Полёт вдоль осей камеры (мировые оси — строки view-матрицы).
    pub fn moveLocal(self: *Camera, right_amt: f32, up_amt: f32, fwd_amt: f32) void {
        const v = self.view();
        const r = Vec3.init(v.m[0], v.m[4], v.m[8]); // right
        const u = Vec3.init(v.m[1], v.m[5], v.m[9]); // up
        const f = Vec3.init(v.m[2], v.m[6], v.m[10]); // back (+ = назад)
        self.pos = self.pos
            .add(r.scale(right_amt))
            .add(u.scale(up_amt))
            .add(f.scale(fwd_amt));
    }

    /// Установка камеры по bounding box сцены (AppState::resetCamera).
    pub fn reset(self: *Camera, bmin: Vec3, bmax: Vec3) void {
        const ext = bmax.sub(bmin);
        const camr = @sqrt(ext.x * ext.x + ext.y * ext.y + ext.z * ext.z) / 2.0;
        self.pos = Vec3.init(
            (bmax.x + bmin.x) / 2.0 + camr,
            (bmax.y + bmin.y) / 2.0 + camr,
            (bmax.z + bmin.z) / 2.0 + camr,
        );
        self.eulers = .{ 45, -45 };
        self.far = camr * 3.0; // как оригинал (gluPerspective far=camr, их camr=halfDiag*3)
        if (self.far < 10.0) self.far = 10.0;
    }

    /// Луч под курсором (ray-pick). winy в оконной конвенции (верх=0) — внутри
    /// переворачивается в GL-конвенцию. viewport = {x,y,w,h}.
    pub fn pickRay(self: Camera, mouse_x: f32, mouse_y: f32, viewport: [4]i32) ?struct { start: Vec3, end: Vec3 } {
        const vh: f32 = @floatFromInt(viewport[3]);
        const aspect: f32 = @as(f32, @floatFromInt(viewport[2])) / vh;
        const p = self.proj(aspect);
        const v = self.view();
        const gl_y = vh - mouse_y; // окно: верх=0 -> GL: низ=0
        const start = mat.unproject(mouse_x, gl_y, 0.0, v, p, viewport) orelse return null;
        const end = mat.unproject(mouse_x, gl_y, 1.0, v, p, viewport) orelse return null;
        return .{ .start = start, .end = end };
    }

    /// Мировые координаты -> экранные (для текста в world-space).
    pub fn worldToScreen(self: Camera, world: Vec3, viewport: [4]i32) ?Vec3 {
        const aspect: f32 = @as(f32, @floatFromInt(viewport[2])) / @as(f32, @floatFromInt(viewport[3]));
        return mat.project(world, self.view(), self.proj(aspect), viewport);
    }
};

test "camera reset puts eye away from center" {
    var cam = Camera{};
    cam.reset(Vec3.init(-10, 0, -10), Vec3.init(10, 5, 10));
    try std.testing.expect(cam.far > 10.0);
    try std.testing.expectEqual(@as(f32, 45), cam.eulers[0]);
}
