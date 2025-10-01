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
    const dirp: u2 = @intCast((dir + 1) & 0x3);

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
            dir = @intCast((dir + 1) & 0x3); // Rotate CW
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
            dir = @intCast((dir + 3) & 0x3); // Rotate CCW
        }

        if (i == start_i and dir == start_dir) {
            break;
        }
    }
}

/// Distance from point to line segment (squared)
fn distancePtSeg(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
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
fn simplifyContour(
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

    ctx.log(.debug, "buildContours: Finding boundaries...", .{});

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

    ctx.log(.debug, "buildContours: Walking contours...", .{});

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
                        .nverts = nverts,
                        .rverts = rverts_copy,
                        .nrverts = nrverts,
                        .reg = reg,
                        .area = area,
                    });
                }
            }
        }
    }

    // Transfer ownership to contour set
    cset.conts = try contours.toOwnedSlice();
    cset.nconts = @intCast(cset.conts.len);

    ctx.log(.info, "buildContours: Created {d} contours", .{cset.nconts});
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
