const std = @import("std");
const math = @import("../math.zig");
const heightfield_mod = @import("heightfield.zig");
const polymesh_mod = @import("polymesh.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const CompactHeightfield = heightfield_mod.CompactHeightfield;
const CompactSpan = heightfield_mod.CompactSpan;
const CompactCell = heightfield_mod.CompactCell;
const ContourSet = polymesh_mod.ContourSet;
const Contour = polymesh_mod.Contour;

const NULL_AREA = config.AreaId.NULL_AREA;
const NOT_CONNECTED = config.NOT_CONNECTED;
const BORDER_REG = config.BORDER_REG;
const BORDER_VERTEX = config.BORDER_VERTEX;
const AREA_BORDER = config.AREA_BORDER;
const CONTOUR_REG_MASK = config.CONTOUR_REG_MASK;
const CONTOUR_TESS_WALL_EDGES = config.CONTOUR_TESS_WALL_EDGES;
const CONTOUR_TESS_AREA_EDGES = config.CONTOUR_TESS_AREA_EDGES;

/// Gets the corner height for a contour vertex
fn getCornerHeight(
    x: i32,
    y: i32,
    i: usize,
    dir: u2,
    chf: *const CompactHeightfield,
    is_border_vertex: *bool,
) i32 {
    const s = chf.spans[i];
    var ch: i32 = @intCast(s.y);
    const dirp: u2 = dir +% 1;

    var regs: [4]u32 = .{ 0, 0, 0, 0 };

    // Combine region and area codes to prevent border vertices
    // between two areas from being removed
    regs[0] = @as(u32, chf.spans[i].reg) | (@as(u32, chf.areas[i]) << 16);

    const w = chf.width;

    if (s.getCon(dir) != NOT_CONNECTED) {
        const ax = x + heightfield_mod.getDirOffsetX(dir);
        const ay = y + heightfield_mod.getDirOffsetY(dir);
        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir)));
        const as = chf.spans[ai];
        ch = @max(ch, @as(i32, @intCast(as.y)));
        regs[1] = @as(u32, chf.spans[ai].reg) | (@as(u32, chf.areas[ai]) << 16);

        if (as.getCon(dirp) != NOT_CONNECTED) {
            const ax2 = ax + heightfield_mod.getDirOffsetX(dirp);
            const ay2 = ay + heightfield_mod.getDirOffsetY(dirp);
            const ai2 = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax2 + ay2 * w))].index + as.getCon(dirp)));
            const as2 = chf.spans[ai2];
            ch = @max(ch, @as(i32, @intCast(as2.y)));
            regs[2] = @as(u32, chf.spans[ai2].reg) | (@as(u32, chf.areas[ai2]) << 16);
        }
    }

    if (s.getCon(dirp) != NOT_CONNECTED) {
        const ax = x + heightfield_mod.getDirOffsetX(dirp);
        const ay = y + heightfield_mod.getDirOffsetY(dirp);
        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dirp)));
        const as = chf.spans[ai];
        ch = @max(ch, @as(i32, @intCast(as.y)));
        regs[3] = @as(u32, chf.spans[ai].reg) | (@as(u32, chf.areas[ai]) << 16);

        if (as.getCon(dir) != NOT_CONNECTED) {
            const ax2 = ax + heightfield_mod.getDirOffsetX(dir);
            const ay2 = ay + heightfield_mod.getDirOffsetY(dir);
            const ai2 = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax2 + ay2 * w))].index + as.getCon(dir)));
            const as2 = chf.spans[ai2];
            ch = @max(ch, @as(i32, @intCast(as2.y)));
            regs[2] = @as(u32, chf.spans[ai2].reg) | (@as(u32, chf.areas[ai2]) << 16);
        }
    }

    // Check if vertex is special edge vertex (will be removed later)
    var j: usize = 0;
    while (j < 4) : (j += 1) {
        const a = j;
        const b = (j + 1) & 0x3;
        const c = (j + 2) & 0x3;
        const d = (j + 3) & 0x3;

        // Border vertex: two same exterior cells in a row, followed by two interior cells
        const two_same_exts = (regs[a] & regs[b] & BORDER_REG) != 0 and regs[a] == regs[b];
        const two_ints = ((regs[c] | regs[d]) & BORDER_REG) == 0;
        const ints_same_area = (regs[c] >> 16) == (regs[d] >> 16);
        const no_zeros = regs[a] != 0 and regs[b] != 0 and regs[c] != 0 and regs[d] != 0;

        if (two_same_exts and two_ints and ints_same_area and no_zeros) {
            is_border_vertex.* = true;
            break;
        }
    }

    return ch;
}

/// Walks along a contour edge and collects vertices
fn walkContour(
    start_x: i32,
    start_y: i32,
    start_i: usize,
    chf: *const CompactHeightfield,
    flags: []u8,
    points: *std.ArrayList(i32),
) !void {
    var x = start_x;
    var y = start_y;
    var i = start_i;

    // Choose the first non-connected edge
    var dir: u2 = 0;
    while ((flags[i] & (@as(u8, 1) << dir)) == 0) {
        dir +%= 1;
    }

    const start_dir = dir;
    const area = chf.areas[i];
    const w = chf.width;

    var iter: usize = 0;
    while (iter < 40000) : (iter += 1) {
        if ((flags[i] & (@as(u8, 1) << dir)) != 0) {
            // Choose the edge corner
            var is_border_vertex = false;
            var is_area_border = false;
            var px = x;
            const py = getCornerHeight(x, y, i, dir, chf, &is_border_vertex);
            var pz = y;

            switch (dir) {
                0 => pz += 1,
                1 => {
                    px += 1;
                    pz += 1;
                },
                2 => px += 1,
                3 => {},
            }

            var r: i32 = 0;
            const s = chf.spans[i];
            if (s.getCon(dir) != NOT_CONNECTED) {
                const ax = x + heightfield_mod.getDirOffsetX(dir);
                const ay = y + heightfield_mod.getDirOffsetY(dir);
                const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir)));
                r = @intCast(chf.spans[ai].reg);
                if (area != chf.areas[ai]) {
                    is_area_border = true;
                }
            }

            if (is_border_vertex) {
                r |= @intCast(BORDER_VERTEX);
            }
            if (is_area_border) {
                r |= @intCast(AREA_BORDER);
            }

            try points.append(px);
            try points.append(py);
            try points.append(pz);
            try points.append(r);

            flags[i] &= ~(@as(u8, 1) << dir); // Remove visited edges
            dir = dir +% 1; // Rotate CW (wraps around for u2)
        } else {
            var ni: i32 = -1;
            const nx = x + heightfield_mod.getDirOffsetX(dir);
            const ny = y + heightfield_mod.getDirOffsetY(dir);
            const s = chf.spans[i];

            if (s.getCon(dir) != NOT_CONNECTED) {
                const nc = chf.cells[@as(usize, @intCast(nx + ny * w))];
                ni = @as(i32, @intCast(nc.index)) + @as(i32, @intCast(s.getCon(dir)));
            }

            if (ni == -1) {
                // Should not happen
                return;
            }

            x = nx;
            y = ny;
            i = @intCast(ni);
            dir = dir +% 3; // Rotate CCW (wraps around for u2)
        }

        if (i == start_i and dir == start_dir) {
            break;
        }
    }
}

/// Distance from point to line segment (squared)
/// INTERNAL: Exported for testing purposes only
pub fn distancePtSeg(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
    const pqx: f32 = @floatFromInt(qx - px);
    const pqz: f32 = @floatFromInt(qz - pz);
    var dx: f32 = @floatFromInt(x - px);
    var dz: f32 = @floatFromInt(z - pz);
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;

    if (d > 0) {
        t /= d;
    }
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    const px_f: f32 = @floatFromInt(px);
    const x_f: f32 = @floatFromInt(x);
    const pz_f: f32 = @floatFromInt(pz);
    const z_f: f32 = @floatFromInt(z);

    dx = px_f + t * pqx - x_f;
    dz = pz_f + t * pqz - z_f;

    return dx * dx + dz * dz;
}

/// Simplifies a contour using Douglas-Peucker algorithm
/// INTERNAL: Exported for testing purposes only
pub fn simplifyContour(
    points: *const std.ArrayList(i32),
    simplified: *std.ArrayList(i32),
    max_error: f32,
    max_edge_len: i32,
    build_flags: i32,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;

    // Check for connections (portals to other regions)
    var has_connections = false;
    var idx: usize = 0;
    while (idx < points.items.len) : (idx += 4) {
        if ((points.items[idx + 3] & CONTOUR_REG_MASK) != 0) {
            has_connections = true;
            break;
        }
    }

    if (has_connections) {
        // Add points where region changes
        const ni = @divTrunc(points.items.len, 4);
        var i: usize = 0;
        while (i < ni) : (i += 1) {
            const ii = (i + 1) % ni;
            const different_regs = (points.items[i * 4 + 3] & CONTOUR_REG_MASK) != (points.items[ii * 4 + 3] & CONTOUR_REG_MASK);
            const area_borders = (points.items[i * 4 + 3] & AREA_BORDER) != (points.items[ii * 4 + 3] & AREA_BORDER);

            if (different_regs or area_borders) {
                try simplified.append(points.items[i * 4 + 0]);
                try simplified.append(points.items[i * 4 + 1]);
                try simplified.append(points.items[i * 4 + 2]);
                try simplified.append(@intCast(i));
            }
        }
    }

    if (simplified.items.len == 0) {
        // No connections - find lower-left and upper-right vertices
        var llx = points.items[0];
        var lly = points.items[1];
        var llz = points.items[2];
        var lli: i32 = 0;
        var urx = points.items[0];
        var ury = points.items[1];
        var urz = points.items[2];
        var uri: i32 = 0;

        idx = 0;
        while (idx < points.items.len) : (idx += 4) {
            const px = points.items[idx + 0];
            const py = points.items[idx + 1];
            const pz = points.items[idx + 2];

            if (px < llx or (px == llx and pz < llz)) {
                llx = px;
                lly = py;
                llz = pz;
                lli = @intCast(@divTrunc(idx, 4));
            }
            if (px > urx or (px == urx and pz > urz)) {
                urx = px;
                ury = py;
                urz = pz;
                uri = @intCast(@divTrunc(idx, 4));
            }
        }

        try simplified.append(llx);
        try simplified.append(lly);
        try simplified.append(llz);
        try simplified.append(lli);

        try simplified.append(urx);
        try simplified.append(ury);
        try simplified.append(urz);
        try simplified.append(uri);
    }

    // Douglas-Peucker simplification
    const pn = @divTrunc(points.items.len, 4);
    var i: usize = 0;
    while (i < @divTrunc(simplified.items.len, 4)) {
        const ii = (i + 1) % @divTrunc(simplified.items.len, 4);

        var ax = simplified.items[i * 4 + 0];
        var az = simplified.items[i * 4 + 2];
        const ai = simplified.items[i * 4 + 3];

        var bx = simplified.items[ii * 4 + 0];
        var bz = simplified.items[ii * 4 + 2];
        const bi = simplified.items[ii * 4 + 3];

        // Find maximum deviation
        var maxd: f32 = 0;
        var maxi: i32 = -1;
        var ci: usize = 0;
        var cinc: usize = 0;
        var endi: i32 = 0;

        // Traverse in lexicological order
        if (bx > ax or (bx == ax and bz > az)) {
            cinc = 1;
            ci = (@as(usize, @intCast(ai)) + cinc) % pn;
            endi = bi;
        } else {
            cinc = pn - 1;
            ci = (@as(usize, @intCast(bi)) + cinc) % pn;
            endi = ai;
            std.mem.swap(i32, &ax, &bx);
            std.mem.swap(i32, &az, &bz);
        }

        // Tessellate only outer edges or edges between areas
        if ((points.items[ci * 4 + 3] & CONTOUR_REG_MASK) == 0 or
            (points.items[ci * 4 + 3] & AREA_BORDER) != 0)
        {
            while (ci != @as(usize, @intCast(endi))) {
                const d = distancePtSeg(points.items[ci * 4 + 0], points.items[ci * 4 + 2], ax, az, bx, bz);
                if (d > maxd) {
                    maxd = d;
                    maxi = @intCast(ci);
                }
                ci = (ci + cinc) % pn;
            }
        }

        // Add point if deviation too large
        if (maxi != -1 and maxd > (max_error * max_error)) {
            try simplified.resize(simplified.items.len + 4);
            const n = @divTrunc(simplified.items.len, 4);
            var j: usize = n - 1;
            while (j > i) : (j -= 1) {
                simplified.items[j * 4 + 0] = simplified.items[(j - 1) * 4 + 0];
                simplified.items[j * 4 + 1] = simplified.items[(j - 1) * 4 + 1];
                simplified.items[j * 4 + 2] = simplified.items[(j - 1) * 4 + 2];
                simplified.items[j * 4 + 3] = simplified.items[(j - 1) * 4 + 3];
            }

            const maxi_usize: usize = @intCast(maxi);
            simplified.items[(i + 1) * 4 + 0] = points.items[maxi_usize * 4 + 0];
            simplified.items[(i + 1) * 4 + 1] = points.items[maxi_usize * 4 + 1];
            simplified.items[(i + 1) * 4 + 2] = points.items[maxi_usize * 4 + 2];
            simplified.items[(i + 1) * 4 + 3] = maxi;
        } else {
            i += 1;
        }
    }

    // Split long edges if needed
    if (max_edge_len > 0 and (build_flags & (CONTOUR_TESS_WALL_EDGES | CONTOUR_TESS_AREA_EDGES)) != 0) {
        i = 0;
        while (i < @divTrunc(simplified.items.len, 4)) {
            const ii = (i + 1) % @divTrunc(simplified.items.len, 4);

            const ax = simplified.items[i * 4 + 0];
            const az = simplified.items[i * 4 + 2];
            const ai = simplified.items[i * 4 + 3];

            const bx = simplified.items[ii * 4 + 0];
            const bz = simplified.items[ii * 4 + 2];
            const bi = simplified.items[ii * 4 + 3];

            var maxi: i32 = -1;
            const ci = (@as(usize, @intCast(ai)) + 1) % pn;

            // Check if we should tessellate this edge
            var tess = false;
            if ((build_flags & CONTOUR_TESS_WALL_EDGES) != 0 and (points.items[ci * 4 + 3] & CONTOUR_REG_MASK) == 0) {
                tess = true;
            }
            if ((build_flags & CONTOUR_TESS_AREA_EDGES) != 0 and (points.items[ci * 4 + 3] & AREA_BORDER) != 0) {
                tess = true;
            }

            if (tess) {
                const dx = bx - ax;
                const dz = bz - az;
                if (dx * dx + dz * dz > max_edge_len * max_edge_len) {
                    const ai_usize: usize = @intCast(ai);
                    const bi_usize: usize = @intCast(bi);
                    const n: i32 = if (bi_usize < ai_usize)
                        @intCast(bi_usize + pn - ai_usize)
                    else
                        @intCast(bi_usize - ai_usize);

                    if (n > 1) {
                        if (bx > ax or (bx == ax and bz > az)) {
                            maxi = @intCast((ai_usize + @as(usize, @intCast(@divTrunc(n, 2)))) % pn);
                        } else {
                            maxi = @intCast((ai_usize + @as(usize, @intCast(@divTrunc(n + 1, 2)))) % pn);
                        }
                    }
                }
            }

            // Add point if needed
            if (maxi != -1) {
                try simplified.resize(simplified.items.len + 4);
                const n = @divTrunc(simplified.items.len, 4);
                var j: usize = n - 1;
                while (j > i) : (j -= 1) {
                    simplified.items[j * 4 + 0] = simplified.items[(j - 1) * 4 + 0];
                    simplified.items[j * 4 + 1] = simplified.items[(j - 1) * 4 + 1];
                    simplified.items[j * 4 + 2] = simplified.items[(j - 1) * 4 + 2];
                    simplified.items[j * 4 + 3] = simplified.items[(j - 1) * 4 + 3];
                }

                const maxi_usize: usize = @intCast(maxi);
                simplified.items[(i + 1) * 4 + 0] = points.items[maxi_usize * 4 + 0];
                simplified.items[(i + 1) * 4 + 1] = points.items[maxi_usize * 4 + 1];
                simplified.items[(i + 1) * 4 + 2] = points.items[maxi_usize * 4 + 2];
                simplified.items[(i + 1) * 4 + 3] = maxi;
            } else {
                i += 1;
            }
        }
    }

    // Update region flags
    i = 0;
    while (i < @divTrunc(simplified.items.len, 4)) : (i += 1) {
        const ai = (@as(usize, @intCast(simplified.items[i * 4 + 3])) + 1) % pn;
        const bi: usize = @intCast(simplified.items[i * 4 + 3]);
        simplified.items[i * 4 + 3] = (points.items[ai * 4 + 3] & (CONTOUR_REG_MASK | AREA_BORDER)) |
            (points.items[bi * 4 + 3] & BORDER_VERTEX);
    }
}

/// Check if two vertices are equal on XZ plane
fn vequal(a: []const i32, b: []const i32) bool {
    return a[0] == b[0] and a[2] == b[2];
}

/// Removes degenerate segments (adjacent equal vertices)
fn removeDegenerateSegments(simplified: *std.ArrayList(i32)) void {
    var npts = @divTrunc(simplified.items.len, 4);
    var i: usize = 0;
    while (i < npts) {
        const ni = (i + 1) % npts;

        if (vequal(simplified.items[i * 4 ..], simplified.items[ni * 4 ..])) {
            // Degenerate segment - remove
            var j: usize = i;
            while (j < npts - 1) : (j += 1) {
                simplified.items[j * 4 + 0] = simplified.items[(j + 1) * 4 + 0];
                simplified.items[j * 4 + 1] = simplified.items[(j + 1) * 4 + 1];
                simplified.items[j * 4 + 2] = simplified.items[(j + 1) * 4 + 2];
                simplified.items[j * 4 + 3] = simplified.items[(j + 1) * 4 + 3];
            }
            simplified.shrinkRetainingCapacity(simplified.items.len - 4);
            npts -= 1;
        } else {
            i += 1;
        }
    }
}

/// Calculates area of a 2D polygon (for winding detection)
fn calcAreaOfPolygon2D(verts: []const i32, nverts: usize) i32 {
    var area: i32 = 0;
    var i: usize = 0;
    var j: usize = nverts - 1;
    while (i < nverts) : ({
        j = i;
        i += 1;
    }) {
        const vi = verts[i * 4 ..];
        const vj = verts[j * 4 ..];
        area += vi[0] * vj[2] - vj[0] * vi[2];
    }
    return @divTrunc(area + 1, 2);
}

// ============================================================================
// Геометрические вспомогательные функции для hole merging
// ============================================================================

/// Получить предыдущий индекс (циклический)
inline fn prev(i: i32, n: i32) i32 {
    return if (i - 1 >= 0) i - 1 else n - 1;
}

/// Получить следующий индекс (циклический)
inline fn next(i: i32, n: i32) i32 {
    return if (i + 1 < n) i + 1 else 0;
}

/// Вычисляет удвоенную площадь треугольника (signed area)
inline fn area2(a: []const i32, b: []const i32, c: []const i32) i32 {
    return (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);
}

/// Возвращает true если c строго слева от направленной линии a->b
inline fn left(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) < 0;
}

/// Возвращает true если c слева или на линии a->b
inline fn leftOn(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) <= 0;
}

/// Возвращает true если точки коллинеарны
inline fn collinear(a: []const i32, b: []const i32, c: []const i32) bool {
    return area2(a, b, c) == 0;
}

/// Возвращает true если ab и cd пересекаются (proper intersection)
fn intersectProp(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    // Исключаем improper cases
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
        return false;

    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

/// Возвращает true если точки коллинеарны и c лежит на отрезке ab
fn between(a: []const i32, b: []const i32, c: []const i32) bool {
    if (!collinear(a, b, c))
        return false;

    // Если ab не вертикален, проверяем по x; иначе по z
    if (a[0] != b[0])
        return ((a[0] <= c[0]) and (c[0] <= b[0])) or ((a[0] >= c[0]) and (c[0] >= b[0]))
    else
        return ((a[2] <= c[2]) and (c[2] <= b[2])) or ((a[2] >= c[2]) and (c[2] >= b[2]));
}

/// Возвращает true если отрезки ab и cd пересекаются
fn intersect(a: []const i32, b: []const i32, c: []const i32, d: []const i32) bool {
    if (intersectProp(a, b, c, d))
        return true
    else if (between(a, b, c) or between(a, b, d) or
        between(c, d, a) or between(c, d, b))
        return true
    else
        return false;
}

/// Проверяет пересекает ли отрезок d0-d1 контур
fn intersectSegContour(d0: []const i32, d1: []const i32, i: i32, n: i32, verts: []const i32) bool {
    // Для каждого ребра (k, k+1) контура P
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);
        // Пропускаем рёбра, инцидентные i
        if (i == k or i == k1)
            continue;

        const k_usize: usize = @intCast(k);
        const k1_usize: usize = @intCast(k1);
        const p0 = verts[k_usize * 4 .. k_usize * 4 + 4];
        const p1 = verts[k1_usize * 4 .. k1_usize * 4 + 4];

        if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1))
            continue;

        if (intersect(d0, d1, p0, p1))
            return true;
    }
    return false;
}

/// Проверяет лежит ли точка pj в конусе вершины i
fn inCone(i: i32, n: i32, verts: []const i32, pj: []const i32) bool {
    const i_usize: usize = @intCast(i);
    const i1_usize: usize = @intCast(next(i, n));
    const in1_usize: usize = @intCast(prev(i, n));

    const pi = verts[i_usize * 4 .. i_usize * 4 + 4];
    const pi1 = verts[i1_usize * 4 .. i1_usize * 4 + 4];
    const pin1 = verts[in1_usize * 4 .. in1_usize * 4 + 4];

    // Если P[i] выпуклая вершина [i+1 left or on (i-1,i)]
    if (leftOn(pin1, pi, pi1))
        return left(pi, pj, pin1) and left(pj, pi, pi1);

    // Иначе P[i] вогнутая
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

/// Builds contours from a compact heightfield
pub fn buildContours(
    ctx: *const Context,
    chf: *const CompactHeightfield,
    max_error: f32,
    max_edge_len: i32,
    cset: *ContourSet,
    build_flags: i32,
    allocator: std.mem.Allocator,
) !void {
    const w = chf.width;
    const h = chf.height;
    const border_size = chf.border_size;

    // Setup contour set
    cset.bmin = chf.bmin;
    cset.bmax = chf.bmax;
    if (border_size > 0) {
        const pad = @as(f32, @floatFromInt(border_size)) * chf.cs;
        cset.bmin.x += pad;
        cset.bmin.z += pad;
        cset.bmax.x -= pad;
        cset.bmax.z -= pad;
    }
    cset.cs = chf.cs;
    cset.ch = chf.ch;
    cset.width = chf.width - chf.border_size * 2;
    cset.height = chf.height - chf.border_size * 2;
    cset.border_size = chf.border_size;
    cset.max_error = max_error;

    // Allocate flags for marking boundaries
    const span_count: usize = @intCast(chf.span_count);
    const flags = try allocator.alloc(u8, span_count);
    defer allocator.free(flags);
    @memset(flags, 0);

    ctx.log(.progress, "buildContours: Finding boundaries...", .{});

    // Mark boundaries (edges not connected to same region)
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const reg = chf.spans[i].reg;
                if (reg == 0 or (reg & BORDER_REG) != 0) {
                    flags[i] = 0;
                    continue;
                }

                const s = chf.spans[i];
                var res: u8 = 0;

                var dir: u3 = 0;
                while (dir < 4) : (dir += 1) {
                    const dir_u2: u2 = @intCast(dir);
                    var r: u16 = 0;
                    if (s.getCon(dir_u2) != NOT_CONNECTED) {
                        const ax = x + heightfield_mod.getDirOffsetX(dir_u2);
                        const ay = y + heightfield_mod.getDirOffsetY(dir_u2);
                        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir_u2)));
                        r = chf.spans[ai].reg;
                    }
                    if (r == reg) {
                        res |= @as(u8, 1) << dir_u2;
                    }
                }

                // Inverse - mark non-connected edges
                flags[i] = res ^ 0xf;
            }
        }
    }

    ctx.log(.progress, "buildContours: Walking contours...", .{});

    var verts = std.ArrayList(i32).init(allocator);
    defer verts.deinit();
    try verts.ensureTotalCapacity(256);

    var simplified = std.ArrayList(i32).init(allocator);
    defer simplified.deinit();
    try simplified.ensureTotalCapacity(64);

    var contours = std.ArrayList(Contour).init(allocator);
    defer {
        // Clean up contours on error
        for (contours.items) |*cont| {
            if (cont.verts.len > 0) allocator.free(cont.verts);
            if (cont.rverts.len > 0) allocator.free(cont.rverts);
        }
        contours.deinit();
    }

    // Walk contours
    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                if (flags[i] == 0 or flags[i] == 0xf) {
                    flags[i] = 0;
                    continue;
                }

                const reg = chf.spans[i].reg;
                if (reg == 0 or (reg & BORDER_REG) != 0) {
                    continue;
                }

                const area = chf.areas[i];

                verts.clearRetainingCapacity();
                simplified.clearRetainingCapacity();

                try walkContour(x, y, i, chf, flags, &verts);
                try simplifyContour(&verts, &simplified, max_error, max_edge_len, build_flags, allocator);
                removeDegenerateSegments(&simplified);

                // Create contour if we have enough vertices
                if (@divTrunc(simplified.items.len, 4) >= 3) {
                    const nverts = @divTrunc(simplified.items.len, 4);

                    // Allocate and copy simplified verts
                    const verts_copy = try allocator.alloc(i32, simplified.items.len);
                    @memcpy(verts_copy, simplified.items);

                    // Remove border offset
                    if (border_size > 0) {
                        for (0..nverts) |v| {
                            verts_copy[v * 4 + 0] -= border_size;
                            verts_copy[v * 4 + 2] -= border_size;
                        }
                    }

                    // Allocate and copy raw verts
                    const nrverts = @divTrunc(verts.items.len, 4);
                    const rverts_copy = try allocator.alloc(i32, verts.items.len);
                    @memcpy(rverts_copy, verts.items);

                    // Remove border offset
                    if (border_size > 0) {
                        for (0..nrverts) |v| {
                            rverts_copy[v * 4 + 0] -= border_size;
                            rverts_copy[v * 4 + 2] -= border_size;
                        }
                    }

                    try contours.append(.{
                        .verts = verts_copy,
                        .nverts = @intCast(nverts),
                        .rverts = rverts_copy,
                        .nrverts = @intCast(nrverts),
                        .reg = reg,
                        .area = area,
                        .allocator = allocator,
                    });
                }
            }
        }
    }

    // Merge holes if needed
    if (contours.items.len > 0) {
        ctx.log(.progress, "buildContours: Checking for holes...", .{});

        // Calculate winding of all contours
        const winding = try allocator.alloc(i8, contours.items.len);
        defer allocator.free(winding);

        var nholes: usize = 0;
        for (contours.items, 0..) |*cont, i| {
            // Если контур закручен назад, это hole
            winding[i] = if (calcAreaOfPolygon2D(cont.verts, @intCast(cont.nverts)) < 0) @as(i8, -1) else @as(i8, 1);
            if (winding[i] < 0) {
                nholes += 1;
            }
        }

        if (nholes > 0) {
            ctx.log(.progress, "buildContours: Found {d} holes, merging...", .{nholes});

            // Собираем outline и holes по регионам
            const nregions: usize = @intCast(chf.max_regions + 1);
            const regions = try allocator.alloc(ContourRegion, nregions);
            defer allocator.free(regions);
            @memset(regions, .{ .outline = null, .holes = &[_]ContourHole{}, .nholes = 0 });

            const holes_storage = try allocator.alloc(ContourHole, contours.items.len);
            defer allocator.free(holes_storage);
            @memset(holes_storage, .{ .contour = undefined, .minx = 0, .minz = 0, .leftmost = 0 });

            // Первый проход: устанавливаем outline и считаем holes
            for (contours.items, 0..) |*cont, i| {
                const reg_idx: usize = @intCast(cont.reg);
                if (winding[i] > 0) {
                    // Положительный winding - это outline
                    if (regions[reg_idx].outline != null) {
                        ctx.log(.err, "buildContours: Multiple outlines for region {d}", .{cont.reg});
                    }
                    regions[reg_idx].outline = cont;
                } else {
                    // Отрицательный winding - это hole
                    regions[reg_idx].nholes += 1;
                }
            }

            // Выделяем места для holes в каждом регионе
            var index: usize = 0;
            for (0..nregions) |i| {
                if (regions[i].nholes > 0) {
                    regions[i].holes = holes_storage[index .. index + regions[i].nholes];
                    index += regions[i].nholes;
                    regions[i].nholes = 0; // Сбросим для повторного использования
                }
            }

            // Второй проход: заполняем holes и вычисляем leftmost
            for (contours.items, 0..) |*cont, i| {
                const reg_idx: usize = @intCast(cont.reg);
                if (winding[i] < 0) {
                    const leftmost_info = findLeftMostVertex(cont);
                    const hole_idx = regions[reg_idx].nholes;
                    regions[reg_idx].holes[hole_idx] = .{
                        .contour = cont,
                        .minx = leftmost_info.minx,
                        .minz = leftmost_info.minz,
                        .leftmost = leftmost_info.leftmost,
                    };
                    regions[reg_idx].nholes += 1;
                }
            }

            // Объединяем holes для каждого региона
            for (0..nregions) |i| {
                if (regions[i].nholes == 0) continue;

                if (regions[i].outline != null) {
                    try mergeRegionHoles(ctx, &regions[i], allocator);
                } else {
                    ctx.log(.err, "buildContours: Bad outline for region {d}, contour simplification is likely too aggressive", .{i});
                }
            }

            ctx.log(.progress, "buildContours: Merged {d} holes", .{nholes});
        }
    }

    // Transfer ownership to contour set
    cset.conts = try contours.toOwnedSlice();
    cset.nconts = @intCast(cset.conts.len);

    ctx.log(.progress, "buildContours: Created {d} contours", .{cset.nconts});
}

// ============================================================================
// Hole merging - структуры и функции
// ============================================================================

/// Информация об отверстии (hole) в контуре
const ContourHole = struct {
    contour: *Contour,
    minx: i32,
    minz: i32,
    leftmost: usize,
};

/// Регион с outline и holes
const ContourRegion = struct {
    outline: ?*Contour,
    holes: []ContourHole,
    nholes: usize,
};

/// Потенциальная диагональ для соединения outline с hole
const PotentialDiagonal = struct {
    vert: i32,
    dist: i32,
};

/// Находит leftmost вершину контура
fn findLeftMostVertex(contour: *const Contour) struct { minx: i32, minz: i32, leftmost: usize } {
    var minx = contour.verts[0];
    var minz = contour.verts[2];
    var leftmost: usize = 0;

    for (1..@intCast(contour.nverts)) |i| {
        const x = contour.verts[i * 4 + 0];
        const z = contour.verts[i * 4 + 2];
        if (x < minx or (x == minx and z < minz)) {
            minx = x;
            minz = z;
            leftmost = i;
        }
    }

    return .{ .minx = minx, .minz = minz, .leftmost = leftmost };
}

/// Функция сравнения для сортировки holes (для std.sort)
fn compareHoles(_: void, a: ContourHole, b: ContourHole) bool {
    if (a.minx == b.minx) {
        return a.minz < b.minz;
    }
    return a.minx < b.minx;
}

/// Функция сравнения для сортировки потенциальных диагоналей
fn compareDiagonals(_: void, a: PotentialDiagonal, b: PotentialDiagonal) bool {
    return a.dist < b.dist;
}

/// Объединяет два контура через вершины ia и ib
fn mergeContours(
    ca: *Contour,
    cb: *const Contour,
    ia: usize,
    ib: usize,
    allocator: std.mem.Allocator,
) !bool {
    const max_verts = ca.nverts + cb.nverts + 2;
    const verts = try allocator.alloc(i32, @as(usize, @intCast(max_verts)) * 4);

    var nv: usize = 0;

    // Копируем контур A, начиная с ia
    for (0..@as(usize, @intCast(ca.nverts)) + 1) |i| {
        const src_idx = (ia + i) % @as(usize, @intCast(ca.nverts));
        @memcpy(verts[nv * 4 .. nv * 4 + 4], ca.verts[src_idx * 4 .. src_idx * 4 + 4]);
        nv += 1;
    }

    // Копируем контур B, начиная с ib
    for (0..@as(usize, @intCast(cb.nverts)) + 1) |i| {
        const src_idx = (ib + i) % @as(usize, @intCast(cb.nverts));
        @memcpy(verts[nv * 4 .. nv * 4 + 4], cb.verts[src_idx * 4 .. src_idx * 4 + 4]);
        nv += 1;
    }

    // Освобождаем старый массив и заменяем новым
    allocator.free(ca.verts);
    ca.verts = verts;
    ca.nverts = @intCast(nv);

    return true;
}

/// Объединяет все holes региона с его outline
fn mergeRegionHoles(
    ctx: *const Context,
    region: *ContourRegion,
    allocator: std.mem.Allocator,
) !void {
    // Сортируем holes слева направо
    std.mem.sort(ContourHole, region.holes[0..region.nholes], {}, compareHoles);

    // Подсчитываем максимальное количество вершин
    var max_verts: usize = if (region.outline) |outline| @intCast(outline.nverts) else 0;
    for (0..region.nholes) |i| {
        max_verts += @intCast(region.holes[i].contour.nverts);
    }

    const diags = try allocator.alloc(PotentialDiagonal, max_verts);
    defer allocator.free(diags);

    var outline = region.outline orelse return;

    // Объединяем holes в outline по одному
    for (0..region.nholes) |i| {
        const hole = region.holes[i].contour;

        var index: i32 = -1;
        var best_vertex = region.holes[i].leftmost;

        // Пытаемся найти лучшую точку соединения
        for (0..@intCast(hole.nverts)) |_| {
            // Находим потенциальные диагонали
            var ndiags: usize = 0;
            const corner = hole.verts[best_vertex * 4 .. best_vertex * 4 + 4];

            for (0..@intCast(outline.nverts)) |j| {
                const j_i32: i32 = @intCast(j);
                const n_i32: i32 = @intCast(outline.nverts);
                if (inCone(j_i32, n_i32, outline.verts, corner)) {
                    const dx = outline.verts[j * 4 + 0] - corner[0];
                    const dz = outline.verts[j * 4 + 2] - corner[2];
                    diags[ndiags] = .{
                        .vert = j_i32,
                        .dist = dx * dx + dz * dz,
                    };
                    ndiags += 1;
                }
            }

            // Сортируем диагонали по расстоянию
            std.mem.sort(PotentialDiagonal, diags[0..ndiags], {}, compareDiagonals);

            // Находим диагональ, которая не пересекает контур
            index = -1;
            for (0..ndiags) |j| {
                const pt = outline.verts[@as(usize, @intCast(diags[j].vert)) * 4 .. @as(usize, @intCast(diags[j].vert)) * 4 + 4];
                const vert_i32: i32 = @intCast(diags[j].vert);
                const n_outline: i32 = @intCast(outline.nverts);
                var intersects = intersectSegContour(pt, corner, vert_i32, n_outline, outline.verts);

                // Проверяем пересечение с остальными holes
                var k: usize = i;
                while (k < region.nholes and !intersects) : (k += 1) {
                    const n_hole: i32 = @intCast(region.holes[k].contour.nverts);
                    intersects = intersects or intersectSegContour(pt, corner, -1, n_hole, region.holes[k].contour.verts);
                }

                if (!intersects) {
                    index = diags[j].vert;
                    break;
                }
            }

            // Если нашли непересекающуюся диагональ, прекращаем поиск
            if (index != -1)
                break;

            // Все диагонали пересекаются, пробуем следующую вершину
            best_vertex = (best_vertex + 1) % @as(usize, @intCast(hole.nverts));
        }

        if (index == -1) {
            ctx.log(.warning, "mergeRegionHoles: Failed to find merge points for outline and hole", .{});
            continue;
        }

        const merge_ok = mergeContours(outline, hole, @intCast(index), best_vertex, allocator) catch |err| {
            ctx.log(.warning, "mergeRegionHoles: Failed to merge contours: {any}", .{err});
            continue;
        };

        if (!merge_ok) {
            ctx.log(.warning, "mergeRegionHoles: mergeContours returned false", .{});
        }
    }
}

// Tests
test "distancePtSeg - point on segment" {
    const d = distancePtSeg(5, 5, 0, 0, 10, 10);
    try std.testing.expect(d < 0.1); // Should be very close to 0
}

test "distancePtSeg - point off segment" {
    const d = distancePtSeg(0, 10, 0, 0, 10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), d, 0.1);
}

test "vequal - equal vertices" {
    const a = [_]i32{ 5, 10, 15, 20 };
    const b = [_]i32{ 5, 20, 15, 30 };
    try std.testing.expect(vequal(&a, &b));
}

test "vequal - different vertices" {
    const a = [_]i32{ 5, 10, 15, 20 };
    const b = [_]i32{ 5, 10, 16, 20 };
    try std.testing.expect(!vequal(&a, &b));
}
