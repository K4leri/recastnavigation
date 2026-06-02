const std = @import("std");
const math = @import("../math.zig");

/// Debug draw primitive types
pub const DebugDrawPrimitives = enum {
    points,
    lines,
    tris,
    quads,
};

/// Abstract debug draw interface using vtable pattern
pub const DebugDraw = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        depthMask: *const fn (ptr: *anyopaque, state: bool) void,
        texture: *const fn (ptr: *anyopaque, state: bool) void,
        begin: *const fn (ptr: *anyopaque, prim: DebugDrawPrimitives, size: f32) void,
        vertex: *const fn (ptr: *anyopaque, pos: *const [3]f32, color: u32) void,
        vertexXYZ: *const fn (ptr: *anyopaque, x: f32, y: f32, z: f32, color: u32) void,
        end: *const fn (ptr: *anyopaque) void,
        areaToCol: *const fn (ptr: *anyopaque, area: u32) u32,
    };

    pub fn depthMask(self: DebugDraw, state: bool) void {
        self.vtable.depthMask(self.ptr, state);
    }

    pub fn texture(self: DebugDraw, state: bool) void {
        self.vtable.texture(self.ptr, state);
    }

    pub fn begin(self: DebugDraw, prim: DebugDrawPrimitives, size: f32) void {
        self.vtable.begin(self.ptr, prim, size);
    }

    pub fn vertex(self: DebugDraw, pos: *const [3]f32, color: u32) void {
        self.vtable.vertex(self.ptr, pos, color);
    }

    pub fn vertexXYZ(self: DebugDraw, x: f32, y: f32, z: f32, color: u32) void {
        self.vtable.vertexXYZ(self.ptr, x, y, z, color);
    }

    pub fn end(self: DebugDraw) void {
        self.vtable.end(self.ptr);
    }

    pub fn areaToCol(self: DebugDraw, area: u32) u32 {
        return self.vtable.areaToCol(self.ptr, area);
    }
};

// ============================================================================
// Color Helper Functions
// ============================================================================

pub const PI: f32 = 3.14159265;

/// Create RGBA color from components (0-255)
pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

/// Create RGBA color from float components (0.0-1.0)
pub inline fn rgbaf(fr: f32, fg: f32, fb: f32, fa: f32) u32 {
    const r: u8 = @intFromFloat(fr * 255.0);
    const g: u8 = @intFromFloat(fg * 255.0);
    const b: u8 = @intFromFloat(fb * 255.0);
    const a: u8 = @intFromFloat(fa * 255.0);
    return rgba(r, g, b, a);
}

/// Convert integer to color
pub fn intToCol(i: i32, a: i32) u32 {
    const r = (bit_cast(u32, i *% 8121) *% 28411) *% 1007 & 0xFF;
    const g = (bit_cast(u32, i *% 13417) *% 26281) *% 2027 & 0xFF;
    const b = (bit_cast(u32, i *% 17569) *% 19283) *% 3079 & 0xFF;
    return rgba(@intCast(r), @intCast(g), @intCast(b), @intCast(a));
}

fn bit_cast(comptime T: type, value: anytype) T {
    return @bitCast(value);
}

/// Convert integer to color (float array version)
pub fn intToColF(i: i32, col: *[4]f32) void {
    const r = ((@as(u32, @bitCast(i)) *% 8121) *% 28411) *% 1007 & 0xFF;
    const g = ((@as(u32, @bitCast(i)) *% 13417) *% 26281) *% 2027 & 0xFF;
    const b = ((@as(u32, @bitCast(i)) *% 17569) *% 19283) *% 3079 & 0xFF;
    col[0] = @as(f32, @floatFromInt(r)) / 255.0;
    col[1] = @as(f32, @floatFromInt(g)) / 255.0;
    col[2] = @as(f32, @floatFromInt(b)) / 255.0;
}

/// Multiply color by value
pub inline fn multCol(col: u32, d: u32) u32 {
    const r = col & 0xff;
    const g = (col >> 8) & 0xff;
    const b = (col >> 16) & 0xff;
    const a = (col >> 24) & 0xff;
    return rgba(@intCast((r * d) >> 8), @intCast((g * d) >> 8), @intCast((b * d) >> 8), @intCast(a));
}

/// Darken color
pub inline fn darkenCol(col: u32) u32 {
    return ((col >> 1) & 0x007f7f7f) | (col & 0xff000000);
}

/// Lerp between two colors
pub inline fn lerpCol(ca: u32, cb: u32, u: u32) u32 {
    const ra = ca & 0xff;
    const ga = (ca >> 8) & 0xff;
    const ba = (ca >> 16) & 0xff;
    const aa = (ca >> 24) & 0xff;
    const rb = cb & 0xff;
    const gb = (cb >> 8) & 0xff;
    const bb = (cb >> 16) & 0xff;
    const ab = (cb >> 24) & 0xff;

    const r = (ra * (255 - u) + rb * u) / 255;
    const g = (ga * (255 - u) + gb * u) / 255;
    const b = (ba * (255 - u) + bb * u) / 255;
    const a = (aa * (255 - u) + ab * u) / 255;
    return rgba(@intCast(r), @intCast(g), @intCast(b), @intCast(a));
}

/// Set transparency
pub inline fn transCol(c: u32, a: u32) u32 {
    return (a << 24) | (c & 0x00ffffff);
}

/// Calculate box colors for top and sides
pub fn calcBoxColors(colors: *[6]u32, col_top: u32, col_side: u32) void {
    colors[0] = multCol(col_top, 250);
    colors[1] = multCol(col_side, 140);
    colors[2] = multCol(col_side, 165);
    colors[3] = multCol(col_side, 217);
    colors[4] = multCol(col_side, 165);
    colors[5] = multCol(col_side, 217);
}

// ============================================================================
// Geometric Drawing Helpers
// ============================================================================

const NUM_ARC_PTS: usize = 8;
const PAD: f32 = 0.05;
const ARC_PTS_SCALE: f32 = (1.0 - PAD * 2) / @as(f32, NUM_ARC_PTS);
const ARC_PTS: [NUM_ARC_PTS][2]f32 = blk: {
    var pts: [NUM_ARC_PTS][2]f32 = undefined;
    for (0..NUM_ARC_PTS) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, NUM_ARC_PTS) * PI;
        pts[i] = .{
            @cos(a),
            @sin(a),
        };
    }
    break :blk pts;
};

pub fn appendArc(dd: DebugDraw, x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, h: f32, as0: f32, as1: f32, col: u32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    const len = @sqrt(dx * dx + dy * dy + dz * dz);
    var prev: [3]f32 = undefined;
    // C++ duAppendArc передаёт len*h как высоту дуги в evalArc (иначе дуга почти плоская).
    const ah = len * h;
    evalArc(x0, y0, z0, dx, dy, dz, ah, PAD, &prev);

    for (1..NUM_ARC_PTS + 1) |i| {
        const u = PAD + @as(f32, @floatFromInt(i)) * ARC_PTS_SCALE;
        var pt: [3]f32 = undefined;
        evalArc(x0, y0, z0, dx, dy, dz, ah, u, &pt);
        dd.vertex(&prev, col);
        dd.vertex(&pt, col);
        prev = pt;
    }

    // End arrows
    if (as0 > 0.001) {
        var p: [3]f32 = undefined;
        var q: [3]f32 = undefined;
        evalArc(x0, y0, z0, dx, dy, dz, ah, PAD, &p);
        evalArc(x0, y0, z0, dx, dy, dz, ah, PAD + 0.05, &q);
        appendArrowHead(dd, &p, &q, as0, col);
    }

    if (as1 > 0.001) {
        var p: [3]f32 = undefined;
        var q: [3]f32 = undefined;
        evalArc(x0, y0, z0, dx, dy, dz, ah, 1.0 - PAD, &p);
        evalArc(x0, y0, z0, dx, dy, dz, ah, 1.0 - PAD - 0.05, &q);
        appendArrowHead(dd, &p, &q, as1, col);
    }
}

fn evalArc(x0: f32, y0: f32, z0: f32, dx: f32, dy: f32, dz: f32, h: f32, u: f32, res: *[3]f32) void {
    res[0] = x0 + dx * u;
    res[1] = y0 + dy * u + h * (1.0 - (u * 2.0 - 1.0) * (u * 2.0 - 1.0));
    res[2] = z0 + dz * u;
}

fn appendArrowHead(dd: DebugDraw, p: *const [3]f32, q: *const [3]f32, s: f32, col: u32) void {
    const eps: f32 = 0.001;
    const dxq = q[0] - p[0];
    const dyq = q[1] - p[1];
    const dzq = q[2] - p[2];
    if (dxq * dxq + dyq * dyq + dzq * dzq < eps * eps) return;

    // Ортонормированный базис как в C++ duAppendArrowHead.
    var az: [3]f32 = .{ dxq, dyq, dzq };
    vnormalize(&az);
    const up: [3]f32 = .{ 0, 1, 0 };
    var ax: [3]f32 = undefined;
    vcross3(&ax, &up, &az);

    dd.vertex(p, col);
    dd.vertex(&.{
        p[0] + az[0] * s + ax[0] * s / 3.0,
        p[1] + az[1] * s + ax[1] * s / 3.0,
        p[2] + az[2] * s + ax[2] * s / 3.0,
    }, col);

    dd.vertex(p, col);
    dd.vertex(&.{
        p[0] + az[0] * s - ax[0] * s / 3.0,
        p[1] + az[1] * s - ax[1] * s / 3.0,
        p[2] + az[2] * s - ax[2] * s / 3.0,
    }, col);
}

fn vcross3(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void {
    dest[0] = v1[1] * v2[2] - v1[2] * v2[1];
    dest[1] = v1[2] * v2[0] - v1[0] * v2[2];
    dest[2] = v1[0] * v2[1] - v1[1] * v2[0];
}

fn vnormalize(v: *[3]f32) void {
    const d = 1.0 / @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    v[0] *= d;
    v[1] *= d;
    v[2] *= d;
}

pub fn appendCircle(dd: DebugDraw, x: f32, y: f32, z: f32, r: f32, col: u32) void {
    const NUM_SEG: usize = 40;
    var dir: [NUM_SEG * 2]f32 = undefined;

    for (0..NUM_SEG) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, NUM_SEG) * PI * 2.0;
        dir[i * 2] = @cos(a);
        dir[i * 2 + 1] = @sin(a);
    }

    for (0..NUM_SEG) |i| {
        const a_idx = i * 2;
        const b_idx = ((i + 1) % NUM_SEG) * 2;
        dd.vertex(&.{ x + dir[a_idx] * r, y, z + dir[a_idx + 1] * r }, col);
        dd.vertex(&.{ x + dir[b_idx] * r, y, z + dir[b_idx + 1] * r }, col);
    }
}

pub fn appendCross(dd: DebugDraw, x: f32, y: f32, z: f32, size: f32, col: u32) void {
    dd.vertex(&.{ x - size, y, z }, col);
    dd.vertex(&.{ x + size, y, z }, col);
    dd.vertex(&.{ x, y - size, z }, col);
    dd.vertex(&.{ x, y + size, z }, col);
    dd.vertex(&.{ x, y, z - size }, col);
    dd.vertex(&.{ x, y, z + size }, col);
}

pub fn appendBox(dd: DebugDraw, minx: f32, miny: f32, minz: f32, maxx: f32, maxy: f32, maxz: f32, fcol: *const [6]u32) void {
    const verts = [8][3]f32{
        .{ minx, miny, minz },
        .{ maxx, miny, minz },
        .{ maxx, miny, maxz },
        .{ minx, miny, maxz },
        .{ minx, maxy, minz },
        .{ maxx, maxy, minz },
        .{ maxx, maxy, maxz },
        .{ minx, maxy, maxz },
    };

    // 6 граней × 4 вершины (КВАДЫ) — 1:1 с duAppendBox. Вызыватель делает begin(.quads),
    // путь .quads разворачивает каждые 4 вершины в 2 треугольника. Если эмитить треугольники
    // (6/грань), .quads мисинтерпретирует поток → искажённая геометрия («пирамидки»).
    const idx = [_]usize{
        7, 6, 5, 4,
        0, 1, 2, 3,
        1, 5, 6, 2,
        3, 7, 4, 0,
        2, 6, 7, 3,
        0, 4, 5, 1,
    };

    for (0..6) |i| {
        dd.vertex(&verts[idx[i * 4 + 0]], fcol[i]);
        dd.vertex(&verts[idx[i * 4 + 1]], fcol[i]);
        dd.vertex(&verts[idx[i * 4 + 2]], fcol[i]);
        dd.vertex(&verts[idx[i * 4 + 3]], fcol[i]);
    }
}

pub fn appendCylinder(dd: DebugDraw, minx: f32, miny: f32, minz: f32, maxx: f32, maxy: f32, maxz: f32, col: u32) void {
    const NUM_SEG: usize = 16;
    const cx = (maxx + minx) / 2;
    const cz = (maxz + minz) / 2;
    const rx = (maxx - minx) / 2;
    const rz = (maxz - minz) / 2;

    var dir: [NUM_SEG * 2]f32 = undefined;
    for (0..NUM_SEG) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, NUM_SEG) * PI * 2.0;
        dir[i * 2] = @cos(a);
        dir[i * 2 + 1] = @sin(a);
    }

    // 1-в-1 с duAppendCylinder: бока (нижние верты затемнены multCol(col,160)) + ВЕРХНЯЯ
    // крышка (fan). Без нижней крышки. Корректный winding — грани смотрят наружу, back-cull
    // оставляет видимые (раньше обе крышки имели одинаковый winding → одна отсекалась →
    // цилиндр выглядел «пустым спереди»).
    const col2 = multCol(col, 160);

    // Sides — winding как у appendBox (нормали НАРУЖУ): a-bot, a-top, b-top / a-bot, b-top, b-bot.
    // (Прежний порядок был зеркальным -> нормали внутрь -> back-cull срезал передние грани,
    // цилиндр выглядел «пустым спереди».)
    for (0..NUM_SEG) |i| {
        const a_idx = i;
        const b_idx = (i + 1) % NUM_SEG;
        dd.vertex(&.{ cx + dir[a_idx * 2] * rx, miny, cz + dir[a_idx * 2 + 1] * rz }, col2);
        dd.vertex(&.{ cx + dir[a_idx * 2] * rx, maxy, cz + dir[a_idx * 2 + 1] * rz }, col);
        dd.vertex(&.{ cx + dir[b_idx * 2] * rx, maxy, cz + dir[b_idx * 2 + 1] * rz }, col);

        dd.vertex(&.{ cx + dir[a_idx * 2] * rx, miny, cz + dir[a_idx * 2 + 1] * rz }, col2);
        dd.vertex(&.{ cx + dir[b_idx * 2] * rx, maxy, cz + dir[b_idx * 2 + 1] * rz }, col);
        dd.vertex(&.{ cx + dir[b_idx * 2] * rx, miny, cz + dir[b_idx * 2 + 1] * rz }, col2);
    }

    // Top cap (fan) — нормаль вверх.
    for (2..NUM_SEG) |i| {
        const a_idx: usize = 0;
        const b_idx = i;
        const c_idx = i - 1;
        dd.vertex(&.{ cx + dir[a_idx * 2] * rx, maxy, cz + dir[a_idx * 2 + 1] * rz }, col);
        dd.vertex(&.{ cx + dir[b_idx * 2] * rx, maxy, cz + dir[b_idx * 2 + 1] * rz }, col);
        dd.vertex(&.{ cx + dir[c_idx * 2] * rx, maxy, cz + dir[c_idx * 2 + 1] * rz }, col);
    }
}
