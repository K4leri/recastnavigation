//! InputGeom — загрузка геометрии (.obj), bounds, нормали, raycast,
//! выпуклые объёмы и off-mesh связи (аналог RecastDemo/InputGeom.cpp).
//! ChunkyTriMesh/PartitionedMesh и .gset — добавляются в #17/полировке.

const std = @import("std");
const recast = @import("recast-nav");
const io_util = @import("io_util.zig");
const convex_surface = @import("convex_surface.zig");
const DebugDraw = recast.debug.DebugDraw;
const Managed = std.array_list.Managed;

pub const MAX_CONVEXVOL_PTS = 12;

pub const VolumeMode = enum(u8) { prism = 0, surface = 1 };

pub const ConvexVolume = struct {
    verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined,
    nverts: i32 = 0,
    hmin: f32 = 0,
    hmax: f32 = 0,
    area: u8 = 0,
    /// Stable identity, assigned monotonically by InputGeom.addConvexVolume.
    /// Never reused, so selection/undo (cluster F) and repro (cluster I) can
    /// reference a volume across add/remove. 0 = unassigned.
    id: u32 = 0,
    mode: VolumeMode = .surface,
    band_below: f32 = 1.0,
    band_above: f32 = 1.0,
};

pub const InputGeom = struct {
    alloc: std.mem.Allocator,

    verts: Managed(f32), // x,y,z,...
    tris: Managed(i32), // i0,i1,i2,...
    normals: Managed(f32), // нормаль на треугольник (3 на tri)
    bmin: [3]f32 = .{ 0, 0, 0 },
    bmax: [3]f32 = .{ 0, 0, 0 },

    volumes: Managed(ConvexVolume),

    // off-mesh связи (параллельные массивы)
    off_verts: Managed(f32), // 6 на связь
    off_rad: Managed(f32),
    off_dir: Managed(u8), // bidirectional
    off_area: Managed(u8),
    off_flags: Managed(u16),
    off_id: Managed(u32),
    /// Next stable convex-volume id (monotonic; never reused). Starts at 1 so 0
    /// stays the "unassigned" sentinel.
    next_volume_id: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) InputGeom {
        return .{
            .alloc = alloc,
            .verts = Managed(f32).init(alloc),
            .tris = Managed(i32).init(alloc),
            .normals = Managed(f32).init(alloc),
            .volumes = Managed(ConvexVolume).init(alloc),
            .off_verts = Managed(f32).init(alloc),
            .off_rad = Managed(f32).init(alloc),
            .off_dir = Managed(u8).init(alloc),
            .off_area = Managed(u8).init(alloc),
            .off_flags = Managed(u16).init(alloc),
            .off_id = Managed(u32).init(alloc),
        };
    }

    pub fn deinit(self: *InputGeom) void {
        self.verts.deinit();
        self.tris.deinit();
        self.normals.deinit();
        self.volumes.deinit();
        self.off_verts.deinit();
        self.off_rad.deinit();
        self.off_dir.deinit();
        self.off_area.deinit();
        self.off_flags.deinit();
        self.off_id.deinit();
    }

    pub fn vertCount(self: *const InputGeom) usize {
        return self.verts.items.len / 3;
    }
    pub fn triCount(self: *const InputGeom) usize {
        return self.tris.items.len / 3;
    }

    /// Загрузка .obj (вершины v, грани f с триангуляцией полигонов веером).
    pub fn loadMesh(self: *InputGeom, path: []const u8) !void {
        const content = try io_util.readWholeFile(path, self.alloc);
        defer self.alloc.free(content);

        self.verts.clearRetainingCapacity();
        self.tris.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len < 2) continue;

            if (std.mem.startsWith(u8, trimmed, "v ")) {
                var it = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
                var i: usize = 0;
                while (it.next()) |tok| : (i += 1) {
                    if (i >= 3) break;
                    try self.verts.append(try std.fmt.parseFloat(f32, tok));
                }
            } else if (std.mem.startsWith(u8, trimmed, "f ")) {
                var it = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
                var face: [32]i32 = undefined;
                var nf: usize = 0;
                while (it.next()) |tok| {
                    var sl = std.mem.tokenizeScalar(u8, tok, '/');
                    if (sl.next()) |vs| {
                        const idx = try std.fmt.parseInt(i32, vs, 10);
                        if (nf < face.len) {
                            face[nf] = idx - 1; // OBJ с 1
                            nf += 1;
                        }
                    }
                }
                // триангуляция веером
                var k: usize = 2;
                while (k < nf) : (k += 1) {
                    try self.tris.append(face[0]);
                    try self.tris.append(face[k - 1]);
                    try self.tris.append(face[k]);
                }
            }
        }

        self.computeBounds();
        try self.computeNormals();
    }

    fn computeBounds(self: *InputGeom) void {
        if (self.verts.items.len == 0) return;
        self.bmin = .{ self.verts.items[0], self.verts.items[1], self.verts.items[2] };
        self.bmax = self.bmin;
        var i: usize = 0;
        while (i < self.verts.items.len) : (i += 3) {
            for (0..3) |c| {
                const v = self.verts.items[i + c];
                self.bmin[c] = @min(self.bmin[c], v);
                self.bmax[c] = @max(self.bmax[c], v);
            }
        }
    }

    fn computeNormals(self: *InputGeom) !void {
        self.normals.clearRetainingCapacity();
        const v = self.verts.items;
        var t: usize = 0;
        while (t < self.tris.items.len) : (t += 3) {
            const a: usize = @intCast(self.tris.items[t]);
            const b: usize = @intCast(self.tris.items[t + 1]);
            const c: usize = @intCast(self.tris.items[t + 2]);
            const e0 = [3]f32{ v[b * 3] - v[a * 3], v[b * 3 + 1] - v[a * 3 + 1], v[b * 3 + 2] - v[a * 3 + 2] };
            const e1 = [3]f32{ v[c * 3] - v[a * 3], v[c * 3 + 1] - v[a * 3 + 1], v[c * 3 + 2] - v[a * 3 + 2] };
            var n = [3]f32{
                e0[1] * e1[2] - e0[2] * e1[1],
                e0[2] * e1[0] - e0[0] * e1[2],
                e0[0] * e1[1] - e0[1] * e1[0],
            };
            const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            if (len > 0) {
                n[0] /= len;
                n[1] /= len;
                n[2] /= len;
            }
            try self.normals.append(n[0]);
            try self.normals.append(n[1]);
            try self.normals.append(n[2]);
        }
    }

    /// Пересечение отрезка src->dst с мешем (brute-force Möller–Trumbore).
    /// Возвращает параметр t в (0,1] ближайшего пересечения.
    pub fn raycastMesh(self: *const InputGeom, src: [3]f32, dst: [3]f32) ?f32 {
        const dir = [3]f32{ dst[0] - src[0], dst[1] - src[1], dst[2] - src[2] };
        var tmin: f32 = 1.0;
        var hit = false;
        const v = self.verts.items;
        var t: usize = 0;
        while (t < self.tris.items.len) : (t += 3) {
            const a: usize = @intCast(self.tris.items[t]);
            const b: usize = @intCast(self.tris.items[t + 1]);
            const c: usize = @intCast(self.tris.items[t + 2]);
            if (rayTri(src, dir, v[a * 3 ..][0..3].*, v[b * 3 ..][0..3].*, v[c * 3 ..][0..3].*)) |tt| {
                if (tt < tmin) {
                    tmin = tt;
                    hit = true;
                }
            }
        }
        return if (hit) tmin else null;
    }

    // --- convex volumes ---
    pub fn addConvexVolume(self: *InputGeom, verts: []const f32, nverts: i32, minh: f32, maxh: f32, area: u8) !void {
        var vol = ConvexVolume{ .nverts = nverts, .hmin = minh, .hmax = maxh, .area = area, .id = self.next_volume_id };
        self.next_volume_id += 1;
        const n: usize = @intCast(nverts);
        @memcpy(vol.verts[0 .. n * 3], verts[0 .. n * 3]);
        try self.volumes.append(vol);
    }
    pub fn deleteConvexVolume(self: *InputGeom, i: usize) void {
        if (i < self.volumes.items.len) _ = self.volumes.orderedRemove(i);
    }

    // --- off-mesh connections ---
    pub fn addOffMeshConnection(self: *InputGeom, start: [3]f32, end: [3]f32, radius: f32, bidir: u8, area: u8, flags: u16) !void {
        try self.off_verts.appendSlice(&.{ start[0], start[1], start[2], end[0], end[1], end[2] });
        try self.off_rad.append(radius);
        try self.off_dir.append(bidir);
        try self.off_area.append(area);
        try self.off_flags.append(flags);
        // NOTE: index-derived (1000+len), NOT monotonic — an id is reused after a
        // middle connection is removed. Stable-id consumers (cluster F/I) must not
        // rely on off_id being unique across removal; making it monotonic like
        // next_volume_id is tracked as a follow-up (changes upstream-faithful value).
        try self.off_id.append(@intCast(1000 + self.off_id.items.len));
    }
    pub fn offMeshCount(self: *const InputGeom) usize {
        return self.off_rad.items.len;
    }

    // --- отрисовка ---
    /// Per-volume vertical band: for PRISM mode it's the flat hmin/hmax box; for
    /// SURFACE mode it follows the least-squares plane (fitPlane) ± band, so the
    /// slab tilts with the relief and shows band_above+band_below as thickness.
    const VolumeBand = struct {
        plane: ?convex_surface.Plane,
        hmin: f32,
        hmax: f32,
        band_below: f32,
        band_above: f32,
        fn init(vol: *const ConvexVolume) VolumeBand {
            const n: usize = @intCast(vol.nverts);
            return switch (vol.mode) {
                .prism => .{ .plane = null, .hmin = vol.hmin, .hmax = vol.hmax, .band_below = 0, .band_above = 0 },
                .surface => .{
                    .plane = convex_surface.fitPlane(vol.verts[0 .. n * 3], n),
                    .hmin = 0,
                    .hmax = 0,
                    .band_below = vol.band_below,
                    .band_above = vol.band_above,
                },
            };
        }
        /// Top (upper) Y for the vertex at (vx,vz).
        fn topY(self: VolumeBand, vx: f32, vz: f32) f32 {
            return if (self.plane) |p| p.at(vx, vz) + self.band_above else self.hmax;
        }
        /// Bottom (lower) Y for the vertex at (vx,vz).
        fn botY(self: VolumeBand, vx: f32, vz: f32) f32 {
            return if (self.plane) |p| p.at(vx, vz) - self.band_below else self.hmin;
        }
    };

    pub fn drawConvexVolumes(self: *const InputGeom, dd: DebugDraw) void {
        // 1-в-1 с duDebugDrawConvexVolumes: верхняя грань (fan) + стены + рёбра-линии + точки.
        // PRISM: плоский ящик hmin..hmax. SURFACE: дрейпированный слаб по плоскости ± band.
        const D = recast.debug;
        dd.depthMask(false);

        dd.begin(.tris, 1.0);
        for (self.volumes.items) |*vol| {
            const n: usize = @intCast(vol.nverts);
            const b = VolumeBand.init(vol);
            const col = D.transCol(dd.areaToCol(vol.area), 32);
            const cold = D.darkenCol(col);
            // Fan anchor = vertex 0 (per-vertex top so the fan slopes with the plane).
            const v0x = vol.verts[0];
            const v0z = vol.verts[2];
            const v0top = b.topY(v0x, v0z);
            var j: usize = n - 1;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const va = vol.verts[j * 3 ..][0..3];
                const vb = vol.verts[i * 3 ..][0..3];
                const va_top = b.topY(va[0], va[2]);
                const vb_top = b.topY(vb[0], vb[2]);
                const va_bot = b.botY(va[0], va[2]);
                const vb_bot = b.botY(vb[0], vb[2]);
                // Top fan (sloped for surface).
                dd.vertexXYZ(v0x, v0top, v0z, col);
                dd.vertexXYZ(vb[0], vb_top, vb[2], col);
                dd.vertexXYZ(va[0], va_top, va[2], col);
                // Side wall va_bot -> va_top -> vb_top, then va_bot -> vb_top -> vb_bot.
                dd.vertexXYZ(va[0], va_bot, va[2], cold);
                dd.vertexXYZ(va[0], va_top, va[2], col);
                dd.vertexXYZ(vb[0], vb_top, vb[2], col);
                dd.vertexXYZ(va[0], va_bot, va[2], cold);
                dd.vertexXYZ(vb[0], vb_top, vb[2], col);
                dd.vertexXYZ(vb[0], vb_bot, vb[2], cold);
                j = i;
            }
        }
        dd.end();

        dd.begin(.lines, 2.0);
        for (self.volumes.items) |*vol| {
            const n: usize = @intCast(vol.nverts);
            const b = VolumeBand.init(vol);
            const col = D.transCol(dd.areaToCol(vol.area), 220);
            const cold = D.darkenCol(col);
            var j: usize = n - 1;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const va = vol.verts[j * 3 ..][0..3];
                const vb = vol.verts[i * 3 ..][0..3];
                dd.vertexXYZ(va[0], b.botY(va[0], va[2]), va[2], cold);
                dd.vertexXYZ(vb[0], b.botY(vb[0], vb[2]), vb[2], cold);
                dd.vertexXYZ(va[0], b.topY(va[0], va[2]), va[2], col);
                dd.vertexXYZ(vb[0], b.topY(vb[0], vb[2]), vb[2], col);
                dd.vertexXYZ(va[0], b.botY(va[0], va[2]), va[2], cold);
                dd.vertexXYZ(va[0], b.topY(va[0], va[2]), va[2], col);
                j = i;
            }
        }
        dd.end();

        dd.begin(.points, 3.0);
        for (self.volumes.items) |*vol| {
            const n: usize = @intCast(vol.nverts);
            const b = VolumeBand.init(vol);
            const col = D.darkenCol(D.transCol(dd.areaToCol(vol.area), 220));
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const v = vol.verts[i * 3 ..][0..3];
                dd.vertexXYZ(v[0], v[1] + 0.1, v[2], col);
                dd.vertexXYZ(v[0], b.botY(v[0], v[2]), v[2], col);
                dd.vertexXYZ(v[0], b.topY(v[0], v[2]), v[2], col);
            }
        }
        dd.end();

        dd.depthMask(true);
    }

    pub fn drawOffMeshConnections(self: *const InputGeom, dd: DebugDraw) void {
        // 1-в-1 с InputGeom::drawOffMeshConnections: вертикальные столбики + круги на
        // концах + дуга со стрелкой (duAppendArc). as0=0.6 при двунаправленной (стрелки
        // с обоих концов), иначе только на конце.
        const con_col = recast.debug.rgba(192, 0, 128, 192);
        const base_col = recast.debug.rgba(0, 0, 0, 64);
        dd.depthMask(false);
        dd.begin(.lines, 2.0);
        var i: usize = 0;
        while (i < self.offMeshCount()) : (i += 1) {
            const v = self.off_verts.items[i * 6 ..][0..6];
            const rad = self.off_rad.items[i];
            const dir = self.off_dir.items[i];
            dd.vertexXYZ(v[0], v[1], v[2], base_col);
            dd.vertexXYZ(v[0], v[1] + 0.2, v[2], base_col);
            dd.vertexXYZ(v[3], v[4], v[5], base_col);
            dd.vertexXYZ(v[3], v[4] + 0.2, v[5], base_col);
            recast.debug.appendCircle(dd, v[0], v[1] + 0.1, v[2], rad, base_col);
            recast.debug.appendCircle(dd, v[3], v[4] + 0.1, v[5], rad, base_col);
            const as0: f32 = if ((dir & 1) != 0) 0.6 else 0.0;
            recast.debug.appendArc(dd, v[0], v[1], v[2], v[3], v[4], v[5], 0.25, as0, 0.6, con_col);
        }
        dd.end();
        dd.depthMask(true);
    }
};

fn rayTri(orig: [3]f32, dir: [3]f32, v0: [3]f32, v1: [3]f32, v2: [3]f32) ?f32 {
    const eps = 1e-6;
    const e1 = sub(v1, v0);
    const e2 = sub(v2, v0);
    const p = cross(dir, e2);
    const det = dot(e1, p);
    // Back-face culling как в оригинале (intersectSegmentTriangle: d<=0 -> reject).
    // det == dot(-dir, cross(e1,e2)) == оригинальное d. Луч ловит только лицевые
    // грани (нормаль навстречу лучу) -> клик попадает в ВИДИМУЮ поверхность (пол),
    // а не в culling'нутую крышу/back-стену.
    if (det < eps) return null;
    const inv = 1.0 / det;
    const tv = sub(orig, v0);
    const u = dot(tv, p) * inv;
    if (u < 0 or u > 1) return null;
    const q = cross(tv, e1);
    const vv = dot(dir, q) * inv;
    if (vv < 0 or u + vv > 1) return null;
    const t = dot(e2, q) * inv;
    if (t > eps and t <= 1.0) return t;
    return null;
}

inline fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
inline fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
inline fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

test "addConvexVolume assigns monotonic non-reused ids" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 }; // 3 verts
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);

    try std.testing.expectEqual(@as(u32, 1), geom.volumes.items[0].id);
    try std.testing.expectEqual(@as(u32, 2), geom.volumes.items[1].id);
    try std.testing.expectEqual(@as(u32, 3), geom.volumes.items[2].id);
    try std.testing.expectEqual(@as(u32, 4), geom.next_volume_id);

    // Remove volume 1 (index 0), add a fourth — id must not reuse 1, 2 or 3.
    geom.deleteConvexVolume(0);
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try std.testing.expectEqual(@as(u32, 4), geom.volumes.items[geom.volumes.items.len - 1].id);
    try std.testing.expectEqual(@as(u32, 5), geom.next_volume_id);
}

test "raycast hits a quad on the ground" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    // плоский квад в y=0, намотка вверх (нормаль +y), иначе back-face cull отбросит
    try geom.verts.appendSlice(&.{ -1, 0, -1, 1, 0, -1, 1, 0, 1, -1, 0, 1 });
    try geom.tris.appendSlice(&.{ 0, 2, 1, 0, 3, 2 });
    const t = geom.raycastMesh(.{ 0, 1, 0 }, .{ 0, -1, 0 });
    try std.testing.expect(t != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.?, 1e-4);
}
