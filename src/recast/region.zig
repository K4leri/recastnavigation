const std = @import("std");
const math = @import("../math.zig");
const heightfield_mod = @import("heightfield.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const CompactHeightfield = heightfield_mod.CompactHeightfield;
const CompactSpan = heightfield_mod.CompactSpan;
const CompactCell = heightfield_mod.CompactCell;

const NULL_AREA = config.AreaId.NULL_AREA;
const NOT_CONNECTED = config.NOT_CONNECTED;
const BORDER_REG = config.BORDER_REG;

/// Stack entry for level-based operations
const LevelStackEntry = struct {
    x: i32,
    y: i32,
    index: i32, // can be negative to mark as processed
};

/// Entry tracking modified region data
const DirtyEntry = struct {
    index: usize,
    region: u16,
    distance2: u16,
};

/// Paints all spans in a rectangular region with a given region ID
fn paintRectRegion(
    minx: i32,
    maxx: i32,
    miny: i32,
    maxy: i32,
    reg_id: u16,
    chf: *CompactHeightfield,
    src_reg: []u16,
) void {
    const w = chf.width;

    var y: i32 = miny;
    while (y < maxy) : (y += 1) {
        var x: i32 = minx;
        while (x < maxx) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                if (chf.areas[i] != NULL_AREA) {
                    src_reg[i] = reg_id;
                }
            }
        }
    }
}

/// Calculates the distance field for the compact heightfield.
/// Distance is measured from area boundaries.
fn calculateDistanceField(
    chf: *CompactHeightfield,
    src: []u16,
    max_dist: *u16,
) void {
    const w = chf.width;
    const h = chf.height;

    // Init distance
    @memset(src, 0xffff);

    // Mark boundary cells
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                const area = chf.areas[i];

                var nc: u32 = 0;
                var dir: u3 = 0;
                while (dir < 4) : (dir += 1) {
                    const dir_u2: u2 = @intCast(dir);
                    if (s.getCon(dir_u2) != NOT_CONNECTED) {
                        const ax = x + heightfield_mod.getDirOffsetX(dir_u2);
                        const ay = y + heightfield_mod.getDirOffsetY(dir_u2);
                        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir_u2)));
                        if (area == chf.areas[ai]) {
                            nc += 1;
                        }
                    }
                }
                if (nc != 4) {
                    src[i] = 0;
                }
            }
        }
    }

    // Pass 1 - forward sweep
    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];

                // (-1, 0)
                if (s.getCon(0) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(0);
                    const ay = y + heightfield_mod.getDirOffsetY(0);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(0)));
                    const as = chf.spans[ai];
                    if (src[ai] + 2 < src[i]) {
                        src[i] = src[ai] + 2;
                    }

                    // (-1, -1)
                    if (as.getCon(3) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(3);
                        const aay = ay + heightfield_mod.getDirOffsetY(3);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(3)));
                        if (src[aai] + 3 < src[i]) {
                            src[i] = src[aai] + 3;
                        }
                    }
                }

                // (0, -1)
                if (s.getCon(3) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(3);
                    const ay = y + heightfield_mod.getDirOffsetY(3);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(3)));
                    const as = chf.spans[ai];
                    if (src[ai] + 2 < src[i]) {
                        src[i] = src[ai] + 2;
                    }

                    // (1, -1)
                    if (as.getCon(2) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(2);
                        const aay = ay + heightfield_mod.getDirOffsetY(2);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(2)));
                        if (src[aai] + 3 < src[i]) {
                            src[i] = src[aai] + 3;
                        }
                    }
                }
            }
        }
    }

    // Pass 2 - backward sweep
    y = h - 1;
    while (y >= 0) : (y -= 1) {
        var x: i32 = w - 1;
        while (x >= 0) : (x -= 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];

                // (1, 0)
                if (s.getCon(2) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(2);
                    const ay = y + heightfield_mod.getDirOffsetY(2);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(2)));
                    const as = chf.spans[ai];
                    if (src[ai] + 2 < src[i]) {
                        src[i] = src[ai] + 2;
                    }

                    // (1, 1)
                    if (as.getCon(1) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(1);
                        const aay = ay + heightfield_mod.getDirOffsetY(1);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(1)));
                        if (src[aai] + 3 < src[i]) {
                            src[i] = src[aai] + 3;
                        }
                    }
                }

                // (0, 1)
                if (s.getCon(1) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(1);
                    const ay = y + heightfield_mod.getDirOffsetY(1);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(1)));
                    const as = chf.spans[ai];
                    if (src[ai] + 2 < src[i]) {
                        src[i] = src[ai] + 2;
                    }

                    // (-1, 1)
                    if (as.getCon(0) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(0);
                        const aay = ay + heightfield_mod.getDirOffsetY(0);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(0)));
                        if (src[aai] + 3 < src[i]) {
                            src[i] = src[aai] + 3;
                        }
                    }
                }
            }
        }
    }

    // Find max distance
    max_dist.* = 0;
    for (src) |d| {
        max_dist.* = @max(max_dist.*, d);
    }
}

/// Applies a box blur filter to the distance field.
fn boxBlur(
    chf: *CompactHeightfield,
    thr: i32,
    src: []u16,
    dst: []u16,
) []u16 {
    const w = chf.width;
    const h = chf.height;

    const threshold = thr * 2;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                const cd = src[i];

                if (cd <= threshold) {
                    dst[i] = cd;
                    continue;
                }

                var d: i32 = @intCast(cd);
                var dir: u3 = 0;
                while (dir < 4) : (dir += 1) {
                    const dir_u2: u2 = @intCast(dir);
                    if (s.getCon(dir_u2) != NOT_CONNECTED) {
                        const ax = x + heightfield_mod.getDirOffsetX(dir_u2);
                        const ay = y + heightfield_mod.getDirOffsetY(dir_u2);
                        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir_u2)));
                        d += @intCast(src[ai]);

                        const as = chf.spans[ai];
                        const dir2: u2 = @intCast((dir + 1) & 0x3);
                        if (as.getCon(dir2) != NOT_CONNECTED) {
                            const ax2 = ax + heightfield_mod.getDirOffsetX(dir2);
                            const ay2 = ay + heightfield_mod.getDirOffsetY(dir2);
                            const ai2 = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax2 + ay2 * w))].index + as.getCon(dir2)));
                            d += @intCast(src[ai2]);
                        } else {
                            d += @intCast(cd);
                        }
                    } else {
                        d += @intCast(cd * 2);
                    }
                }
                dst[i] = @intCast(@divTrunc(d + 5, 9));
            }
        }
    }

    return dst;
}

/// Flood fills a region starting from (x,y,i) at a given distance level
fn floodRegion(
    x: i32,
    y: i32,
    i: usize,
    level: u16,
    r: u16,
    chf: *CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
) !bool {
    const w = chf.width;
    const area = chf.areas[i];

    // Start flood fill
    stack.clearRetainingCapacity();
    try stack.append(.{ .x = x, .y = y, .index = @intCast(i) });
    src_reg[i] = r;
    src_dist[i] = 0;

    const lev: u16 = if (level >= 2) level - 2 else 0;
    var count: usize = 0;

    while (stack.items.len > 0) {
        const back = stack.pop();
        const cx = back.x;
        const cy = back.y;
        const ci: usize = @intCast(back.index);

        const cs = chf.spans[ci];

        // Check if any neighbor already has a valid region
        var ar: u16 = 0;
        var dir: u3 = 0;
        while (dir < 4) : (dir += 1) {
            const dir_u2: u2 = @intCast(dir);
            if (cs.getCon(dir_u2) != NOT_CONNECTED) {
                const ax = cx + heightfield_mod.getDirOffsetX(dir_u2);
                const ay = cy + heightfield_mod.getDirOffsetY(dir_u2);
                const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + cs.getCon(dir_u2)));
                if (chf.areas[ai] != area) continue;

                const nr = src_reg[ai];
                if ((nr & BORDER_REG) != 0) continue; // Don't take borders into account
                if (nr != 0 and nr != r) {
                    ar = nr;
                    break;
                }

                const as = chf.spans[ai];

                // Check diagonal neighbor
                const dir2: u2 = @intCast((dir + 1) & 0x3);
                if (as.getCon(dir2) != NOT_CONNECTED) {
                    const ax2 = ax + heightfield_mod.getDirOffsetX(dir2);
                    const ay2 = ay + heightfield_mod.getDirOffsetY(dir2);
                    const ai2 = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax2 + ay2 * w))].index + as.getCon(dir2)));
                    if (chf.areas[ai2] != area) continue;

                    const nr2 = src_reg[ai2];
                    if (nr2 != 0 and nr2 != r) {
                        ar = nr2;
                        break;
                    }
                }
            }
        }

        if (ar != 0) {
            src_reg[ci] = 0;
            continue;
        }

        count += 1;

        // Expand to neighbors
        dir = 0;
        while (dir < 4) : (dir += 1) {
            const dir_u2: u2 = @intCast(dir);
            if (cs.getCon(dir_u2) != NOT_CONNECTED) {
                const ax = cx + heightfield_mod.getDirOffsetX(dir_u2);
                const ay = cy + heightfield_mod.getDirOffsetY(dir_u2);
                const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + cs.getCon(dir_u2)));
                if (chf.areas[ai] != area) continue;
                if (chf.dist[ai] >= lev and src_reg[ai] == 0) {
                    src_reg[ai] = r;
                    src_dist[ai] = 0;
                    try stack.append(.{ .x = ax, .y = ay, .index = @intCast(ai) });
                }
            }
        }
    }

    return count > 0;
}

/// Expands existing regions to fill gaps
fn expandRegions(
    max_iter: i32,
    level: u16,
    chf: *CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
    fill_stack: bool,
    allocator: std.mem.Allocator,
) !void {
    const w = chf.width;
    const h = chf.height;

    if (fill_stack) {
        // Find cells revealed by the raised level
        stack.clearRetainingCapacity();
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                const cell_idx = @as(usize, @intCast(x + y * w));
                const cell = chf.cells[cell_idx];

                var i: usize = cell.index;
                const ni = cell.index + cell.count;
                while (i < ni) : (i += 1) {
                    if (chf.dist[i] >= level and src_reg[i] == 0 and chf.areas[i] != NULL_AREA) {
                        try stack.append(.{ .x = x, .y = y, .index = @intCast(i) });
                    }
                }
            }
        }
    } else {
        // Mark cells that already have a region as processed
        for (stack.items) |*entry| {
            const i: usize = @intCast(entry.index);
            if (entry.index >= 0 and src_reg[i] != 0) {
                entry.index = -1;
            }
        }
    }

    var dirty_entries = std.ArrayList(DirtyEntry).init(allocator);
    defer dirty_entries.deinit();

    var iter: i32 = 0;
    while (stack.items.len > 0) {
        var failed: usize = 0;
        dirty_entries.clearRetainingCapacity();

        for (stack.items) |entry| {
            const x = entry.x;
            const y = entry.y;
            const idx = entry.index;
            if (idx < 0) {
                failed += 1;
                continue;
            }

            const i: usize = @intCast(idx);
            var r = src_reg[i];
            var d2: u16 = 0xffff;
            const area = chf.areas[i];
            const s = chf.spans[i];

            var dir: u3 = 0;
            while (dir < 4) : (dir += 1) {
                const dir_u2: u2 = @intCast(dir);
                if (s.getCon(dir_u2) == NOT_CONNECTED) continue;

                const ax = x + heightfield_mod.getDirOffsetX(dir_u2);
                const ay = y + heightfield_mod.getDirOffsetY(dir_u2);
                const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir_u2)));
                if (chf.areas[ai] != area) continue;
                if (src_reg[ai] > 0 and (src_reg[ai] & BORDER_REG) == 0) {
                    if (@as(i32, @intCast(src_dist[ai])) + 2 < @as(i32, @intCast(d2))) {
                        r = src_reg[ai];
                        d2 = src_dist[ai] + 2;
                    }
                }
            }

            if (r != 0) {
                try dirty_entries.append(.{ .index = i, .region = r, .distance2 = d2 });
            } else {
                failed += 1;
            }
        }

        // Apply dirty entries
        for (dirty_entries.items) |entry| {
            src_reg[entry.index] = entry.region;
            src_dist[entry.index] = entry.distance2;
        }

        // Mark processed entries in stack
        var j: usize = 0;
        for (stack.items) |*entry| {
            if (entry.index >= 0) {
                const i: usize = @intCast(entry.index);
                var found = false;
                for (dirty_entries.items) |de| {
                    if (de.index == i) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    entry.index = -1;
                }
            }
            j += 1;
        }

        if (failed == stack.items.len) break;

        if (level > 0) {
            iter += 1;
            if (iter >= max_iter) break;
        }
    }
}

/// Builds the distance field for the compact heightfield.
///
/// The distance field represents the distance of each span from the nearest
/// obstacle or boundary. This is used for region partitioning.
pub fn buildDistanceField(
    ctx: *const Context,
    chf: *CompactHeightfield,
    allocator: std.mem.Allocator,
) !void {
    _ = ctx; // TODO: timer

    // Free existing distance field if present
    if (chf.dist.len > 0) {
        allocator.free(chf.dist);
        chf.dist = &[_]u16{};
    }

    const span_count = @as(usize, @intCast(chf.span_count));

    const src = try allocator.alloc(u16, span_count);
    defer allocator.free(src);

    const dst = try allocator.alloc(u16, span_count);
    defer allocator.free(dst);

    var max_dist: u16 = 0;
    calculateDistanceField(chf, src, &max_dist);
    chf.max_distance = max_dist;

    // Blur
    const blur_result = boxBlur(chf, 1, src, dst);

    // Store distance - allocate new array and copy
    chf.dist = try allocator.alloc(u16, span_count);
    if (blur_result.ptr == dst.ptr) {
        @memcpy(chf.dist, dst);
    } else {
        @memcpy(chf.dist, src);
    }
}

/// Builds regions using watershed partitioning.
///
/// This creates regions by flooding from distance field peaks, which tends to
/// create more natural region boundaries than monotone partitioning.
pub fn buildRegions(
    ctx: *const Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
    allocator: std.mem.Allocator,
) !void {
    _ = min_region_area; // TODO: Implement region filtering
    _ = merge_region_area; // TODO: Implement region merging

    const w = chf.width;
    const h = chf.height;
    const span_count = @as(usize, @intCast(chf.span_count));

    // Allocate temporary buffers
    const src_reg = try allocator.alloc(u16, span_count);
    defer allocator.free(src_reg);
    @memset(src_reg, 0);

    const src_dist = try allocator.alloc(u16, span_count);
    defer allocator.free(src_dist);
    @memset(src_dist, 0);

    var region_id: u16 = 1;
    var level: u16 = (chf.max_distance + 1) & ~@as(u16, 1);

    const expand_iters: i32 = 8;

    // Mark border regions
    if (border_size > 0) {
        const bw = @min(w, border_size);
        const bh = @min(h, border_size);

        // Paint four border regions
        paintRectRegion(0, bw, 0, h, region_id | BORDER_REG, chf, src_reg);
        region_id += 1;
        paintRectRegion(w - bw, w, 0, h, region_id | BORDER_REG, chf, src_reg);
        region_id += 1;
        paintRectRegion(0, w, 0, bh, region_id | BORDER_REG, chf, src_reg);
        region_id += 1;
        paintRectRegion(0, w, h - bh, h, region_id | BORDER_REG, chf, src_reg);
        region_id += 1;
    }

    chf.border_size = border_size;

    // Create work stacks
    var stack = std.ArrayList(LevelStackEntry).init(allocator);
    defer stack.deinit();
    try stack.ensureTotalCapacity(256);

    // Watershed partitioning
    while (level > 0) {
        level = if (level >= 2) level - 2 else 0;

        // Expand current regions
        try expandRegions(expand_iters, level, chf, src_reg, src_dist, &stack, true, allocator);

        // Mark new regions with flood fill
        stack.clearRetainingCapacity();

        // Collect cells at this level
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                const cell_idx = @as(usize, @intCast(x + y * w));
                const cell = chf.cells[cell_idx];

                var i: usize = cell.index;
                const ni = cell.index + cell.count;
                while (i < ni) : (i += 1) {
                    if (chf.dist[i] >= level and src_reg[i] == 0 and chf.areas[i] != NULL_AREA) {
                        try stack.append(.{ .x = x, .y = y, .index = @intCast(i) });
                    }
                }
            }
        }

        // Flood fill new regions
        for (stack.items) |current| {
            const x = current.x;
            const y_coord = current.y;
            const idx = current.index;
            if (idx >= 0) {
                const i: usize = @intCast(idx);
                if (src_reg[i] == 0) {
                    if (try floodRegion(x, y_coord, i, level, region_id, chf, src_reg, src_dist, &stack)) {
                        if (region_id == 0xFFFF) {
                            ctx.log(.err, "buildRegions: Region ID overflow", .{});
                            return error.RegionOverflow;
                        }
                        region_id += 1;
                    }
                }
            }
        }
    }

    // Expand current regions to fill remaining gaps
    try expandRegions(expand_iters * 8, 0, chf, src_reg, src_dist, &stack, true, allocator);

    // Write results to compact heightfield
    chf.max_regions = region_id;
    for (0..span_count) |i| {
        chf.spans[i].reg = src_reg[i];
    }

    ctx.log(.info, "buildRegions: Created {d} regions", .{region_id - 1});
}

/// Sweep span for monotone partitioning
const SweepSpan = struct {
    rid: u16, // row id
    id: u16, // region id
    ns: u16, // number of samples
    nei: u16, // neighbor id

    const NULL_NEI: u16 = 0xffff;
};

/// Builds regions using monotone partitioning.
///
/// This is a simpler alternative to watershed that creates regions by sweeping
/// along one axis. Regions may be longer/narrower than watershed but computation
/// is faster.
pub fn buildRegionsMonotone(
    ctx: *const Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
    allocator: std.mem.Allocator,
) !void {
    _ = min_region_area; // TODO: Implement region filtering
    _ = merge_region_area; // TODO: Implement region merging

    const w = chf.width;
    const h = chf.height;
    const span_count = @as(usize, @intCast(chf.span_count));

    var id: u16 = 1;

    const src_reg = try allocator.alloc(u16, span_count);
    defer allocator.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps: usize = @intCast(@max(w, h));
    const sweeps = try allocator.alloc(SweepSpan, nsweeps);
    defer allocator.free(sweeps);

    // Mark border regions
    if (border_size > 0) {
        const bw = @min(w, border_size);
        const bh = @min(h, border_size);

        paintRectRegion(0, bw, 0, h, id | BORDER_REG, chf, src_reg);
        id += 1;
        paintRectRegion(w - bw, w, 0, h, id | BORDER_REG, chf, src_reg);
        id += 1;
        paintRectRegion(0, w, 0, bh, id | BORDER_REG, chf, src_reg);
        id += 1;
        paintRectRegion(0, w, h - bh, h, id | BORDER_REG, chf, src_reg);
        id += 1;
    }

    chf.border_size = border_size;

    var prev = std.ArrayList(i32).init(allocator);
    defer prev.deinit();
    try prev.resize(256);

    // Sweep one line at a time
    var y: i32 = border_size;
    while (y < h - border_size) : (y += 1) {
        // Collect spans from this row
        try prev.resize(@intCast(id + 1));
        @memset(prev.items, 0);
        var rid: u16 = 1;

        var x: i32 = border_size;
        while (x < w - border_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                if (chf.areas[i] == NULL_AREA) continue;

                // Check -x direction
                var previd: u16 = 0;
                if (s.getCon(0) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(0);
                    const ay = y + heightfield_mod.getDirOffsetY(0);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(0)));
                    if ((src_reg[ai] & BORDER_REG) == 0 and chf.areas[i] == chf.areas[ai]) {
                        previd = src_reg[ai];
                    }
                }

                if (previd == 0) {
                    previd = rid;
                    rid += 1;
                    sweeps[previd].rid = previd;
                    sweeps[previd].ns = 0;
                    sweeps[previd].nei = 0;
                }

                // Check -y direction
                if (s.getCon(3) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(3);
                    const ay = y + heightfield_mod.getDirOffsetY(3);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(3)));
                    if (src_reg[ai] != 0 and (src_reg[ai] & BORDER_REG) == 0 and chf.areas[i] == chf.areas[ai]) {
                        const nr = src_reg[ai];
                        if (sweeps[previd].nei == 0 or sweeps[previd].nei == nr) {
                            sweeps[previd].nei = nr;
                            sweeps[previd].ns += 1;
                            prev.items[nr] += 1;
                        } else {
                            sweeps[previd].nei = SweepSpan.NULL_NEI;
                        }
                    }
                }

                src_reg[i] = previd;
            }
        }

        // Create unique IDs
        var i: usize = 1;
        while (i < rid) : (i += 1) {
            if (sweeps[i].nei != SweepSpan.NULL_NEI and sweeps[i].nei != 0 and
                prev.items[sweeps[i].nei] == sweeps[i].ns)
            {
                sweeps[i].id = sweeps[i].nei;
            } else {
                sweeps[i].id = id;
                id += 1;
            }
        }

        // Remap IDs
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            i = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                if (src_reg[i] > 0 and src_reg[i] < rid) {
                    src_reg[i] = sweeps[src_reg[i]].id;
                }
            }
        }
    }

    // TODO: Merge and filter regions

    // Write results
    chf.max_regions = id;
    for (0..span_count) |i| {
        chf.spans[i].reg = src_reg[i];
    }

    ctx.log(.info, "buildRegionsMonotone: Created {d} regions", .{id - 1});
}

// Tests
test "calculateDistanceField - simple grid" {
    const allocator = std.testing.allocator;

    // Create a simple compact heightfield
    var chf = CompactHeightfield{
        .width = 3,
        .height = 3,
        .span_count = 9,
        .walkable_height = 5,
        .walkable_climb = 2,
        .border_size = 0,
        .max_distance = 0,
        .max_regions = 0,
        .bmin = Vec3.init(0, 0, 0),
        .bmax = Vec3.init(3, 3, 3),
        .cs = 1.0,
        .ch = 0.5,
        .cells = undefined,
        .spans = undefined,
        .dist = &[_]u16{},
        .areas = undefined,
        .allocator = allocator,
    };

    chf.cells = try allocator.alloc(CompactCell, 9);
    defer allocator.free(chf.cells);

    chf.spans = try allocator.alloc(CompactSpan, 9);
    defer allocator.free(chf.spans);

    chf.areas = try allocator.alloc(u8, 9);
    defer allocator.free(chf.areas);

    // Initialize cells and spans
    for (0..9) |i| {
        chf.cells[i] = CompactCell.init(@intCast(i), 1);
        chf.spans[i] = CompactSpan.init();
        chf.areas[i] = 1; // All walkable
    }

    // Set up connections (3x3 grid) - only center cell has all 4 connections
    // Edge cells have NO_CONNECTED to edges
    for (0..3) |y| {
        for (0..3) |x| {
            const idx = x + y * 3;
            const span = &chf.spans[idx];

            // Initialize all to NOT_CONNECTED
            span.setCon(0, NOT_CONNECTED);
            span.setCon(1, NOT_CONNECTED);
            span.setCon(2, NOT_CONNECTED);
            span.setCon(3, NOT_CONNECTED);

            // West - connect to cell at same level in neighbor
            if (x > 0) {
                span.setCon(0, 0); // layer index 0 in neighbor cell
            }
            // South
            if (y > 0) {
                span.setCon(3, 0);
            }
            // East
            if (x < 2) {
                span.setCon(2, 0);
            }
            // North
            if (y < 2) {
                span.setCon(1, 0);
            }
        }
    }

    const src = try allocator.alloc(u16, 9);
    defer allocator.free(src);

    var max_dist: u16 = 0;
    calculateDistanceField(&chf, src, &max_dist);

    // Center cell should have highest distance
    try std.testing.expect(src[4] > src[0]); // center > corner
}

test "buildDistanceField" {
    const allocator = std.testing.allocator;

    var chf = CompactHeightfield{
        .width = 3,
        .height = 3,
        .span_count = 9,
        .walkable_height = 5,
        .walkable_climb = 2,
        .border_size = 0,
        .max_distance = 0,
        .max_regions = 0,
        .bmin = Vec3.init(0, 0, 0),
        .bmax = Vec3.init(3, 3, 3),
        .cs = 1.0,
        .ch = 0.5,
        .cells = undefined,
        .spans = undefined,
        .dist = &[_]u16{},
        .areas = undefined,
        .allocator = allocator,
    };

    chf.cells = try allocator.alloc(CompactCell, 9);
    defer allocator.free(chf.cells);

    chf.spans = try allocator.alloc(CompactSpan, 9);
    defer allocator.free(chf.spans);

    chf.areas = try allocator.alloc(u8, 9);
    defer allocator.free(chf.areas);

    // Initialize cells and spans
    for (0..9) |i| {
        chf.cells[i] = CompactCell.init(@intCast(i), 1);
        chf.spans[i] = CompactSpan.init();
        chf.areas[i] = 1;
    }

    // Set up connections properly
    for (0..3) |y| {
        for (0..3) |x| {
            const idx = x + y * 3;
            const span = &chf.spans[idx];

            // Initialize all to NOT_CONNECTED
            span.setCon(0, NOT_CONNECTED);
            span.setCon(1, NOT_CONNECTED);
            span.setCon(2, NOT_CONNECTED);
            span.setCon(3, NOT_CONNECTED);

            if (x > 0) span.setCon(0, 0);
            if (y > 0) span.setCon(3, 0);
            if (x < 2) span.setCon(2, 0);
            if (y < 2) span.setCon(1, 0);
        }
    }

    const ctx = Context.init(allocator);
    try buildDistanceField(&ctx, &chf, allocator);
    defer allocator.free(chf.dist);

    // Distance field should be allocated
    try std.testing.expect(chf.dist.len == 9);
    try std.testing.expect(chf.max_distance > 0);
}
