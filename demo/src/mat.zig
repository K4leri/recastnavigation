//! Матрицы 4x4 и камера-математика для демо (замена glu* из RecastDemo).
//! Column-major хранение (как в OpenGL): m[col*4 + row].
//! Используется только демкой; ядро (src/math.zig) этого не содержит.

const std = @import("std");
const recast = @import("recast-nav");
const Vec3 = recast.math.Vec3;

pub const Mat4 = struct {
    m: [16]f32,

    pub fn identity() Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    /// C = self * other (оба column-major).
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[k * 4 + row] * b.m[c * 4 + k];
                }
                r.m[c * 4 + row] = sum;
            }
        }
        return r;
    }

    /// v' = self * v (v как column vector [x,y,z,w]).
    pub fn mulVec4(self: Mat4, v: [4]f32) [4]f32 {
        var out: [4]f32 = .{ 0, 0, 0, 0 };
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var sum: f32 = 0;
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                sum += self.m[c * 4 + row] * v[c];
            }
            out[row] = sum;
        }
        return out;
    }

    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        var r = identity();
        r.m[12] = x;
        r.m[13] = y;
        r.m[14] = z;
        return r;
    }

    pub fn rotationX(deg: f32) Mat4 {
        const a = std.math.degreesToRadians(deg);
        const c = @cos(a);
        const s = @sin(a);
        var r = identity();
        r.m[5] = c;
        r.m[6] = s;
        r.m[9] = -s;
        r.m[10] = c;
        return r;
    }

    pub fn rotationY(deg: f32) Mat4 {
        const a = std.math.degreesToRadians(deg);
        const c = @cos(a);
        const s = @sin(a);
        var r = identity();
        r.m[0] = c;
        r.m[2] = -s;
        r.m[8] = s;
        r.m[10] = c;
        return r;
    }

    /// gluPerspective: fovy в градусах.
    pub fn perspective(fovy_deg: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(std.math.degreesToRadians(fovy_deg) * 0.5);
        var r = Mat4{ .m = .{0} ** 16 };
        r.m[0] = f / aspect;
        r.m[5] = f;
        r.m[10] = (far + near) / (near - far);
        r.m[11] = -1.0;
        r.m[14] = (2.0 * far * near) / (near - far);
        return r;
    }

    /// gluLookAt.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = normalize(center.sub(eye));
        const s = normalize(cross(f, up));
        const u = cross(s, f);
        return .{ .m = .{
            s.x,           u.x,           -f.x,        0,
            s.y,           u.y,           -f.y,        0,
            s.z,           u.z,           -f.z,        0,
            -dot(s, eye),  -dot(u, eye),  dot(f, eye), 1,
        } };
    }

    /// Полное обращение 4x4 (метод кофакторов). null если матрица вырождена.
    pub fn inverse(self: Mat4) ?Mat4 {
        const m = self.m;
        var inv: [16]f32 = undefined;

        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

        var det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (det == 0) return null;
        det = 1.0 / det;

        var r: Mat4 = undefined;
        for (0..16) |i| r.m[i] = inv[i] * det;
        return r;
    }
};

// --- мелкие векторные хелперы (на случай отличий API Vec3) ---
fn dot(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}
fn normalize(v: Vec3) Vec3 {
    const len = @sqrt(dot(v, v));
    if (len == 0) return v;
    return .{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
}

/// Нормаль грани треугольника (нормализованная).
pub fn faceNormal(v0: Vec3, v1: Vec3, v2: Vec3) Vec3 {
    return normalize(cross(v1.sub(v0), v2.sub(v0)));
}

/// gluUnProject: экранные (winx, winy, winz) -> мировые координаты.
/// winy ожидается в GL-конвенции (низ = 0): передавать (viewport_h - mouse_y).
/// winz: 0 = ближняя плоскость, 1 = дальняя.
pub fn unproject(winx: f32, winy: f32, winz: f32, modelview: Mat4, proj: Mat4, viewport: [4]i32) ?Vec3 {
    const a = proj.mul(modelview);
    const inv = a.inverse() orelse return null;

    const vx: f32 = @floatFromInt(viewport[0]);
    const vy: f32 = @floatFromInt(viewport[1]);
    const vw: f32 = @floatFromInt(viewport[2]);
    const vh: f32 = @floatFromInt(viewport[3]);

    const in = [4]f32{
        2.0 * (winx - vx) / vw - 1.0,
        2.0 * (winy - vy) / vh - 1.0,
        2.0 * winz - 1.0,
        1.0,
    };
    const out = inv.mulVec4(in);
    if (out[3] == 0) return null;
    return Vec3.init(out[0] / out[3], out[1] / out[3], out[2] / out[3]);
}

/// gluProject: мировые координаты -> экранные (для текста в world-space).
/// Возвращает (screenx, screeny в GL-конвенции, depth 0..1).
pub fn project(obj: Vec3, modelview: Mat4, proj: Mat4, viewport: [4]i32) ?Vec3 {
    const eye = modelview.mulVec4(.{ obj.x, obj.y, obj.z, 1.0 });
    const clip = proj.mulVec4(eye);
    if (clip[3] == 0) return null;

    const ndc = [3]f32{ clip[0] / clip[3], clip[1] / clip[3], clip[2] / clip[3] };

    const vx: f32 = @floatFromInt(viewport[0]);
    const vy: f32 = @floatFromInt(viewport[1]);
    const vw: f32 = @floatFromInt(viewport[2]);
    const vh: f32 = @floatFromInt(viewport[3]);

    return Vec3.init(
        vx + vw * (ndc[0] + 1.0) * 0.5,
        vy + vh * (ndc[1] + 1.0) * 0.5,
        (ndc[2] + 1.0) * 0.5,
    );
}

test "Mat4 identity * v" {
    const id = Mat4.identity();
    const v = id.mulVec4(.{ 1, 2, 3, 1 });
    try std.testing.expectEqual(@as(f32, 1), v[0]);
    try std.testing.expectEqual(@as(f32, 2), v[1]);
    try std.testing.expectEqual(@as(f32, 3), v[2]);
}

test "inverse(perspective)*perspective ~= identity" {
    const p = Mat4.perspective(60.0, 1.5, 1.0, 100.0);
    const inv = p.inverse().?;
    const prod = p.mul(inv);
    for (0..4) |i| {
        const expect: f32 = if (i == 0) 1 else 0;
        try std.testing.expectApproxEqAbs(expect, prod.m[i], 1e-4);
    }
}
