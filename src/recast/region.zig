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
    var max_span_idx: usize = 0;
    for (src, 0..) |d, idx| {
        if (d > max_dist.*) {
            max_dist.* = d;
            max_span_idx = idx;
        }
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
        const back = stack.pop().?; // Safe to unwrap since we checked len > 0
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

/// Sorts cells by their distance level and distributes them into multiple stacks.
/// This is used by the C++ multi-stack watershed algorithm.
fn sortCellsByLevel(
    start_level: u16,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    stacks: []std.ArrayList(LevelStackEntry),
    log_levels_per_stack: u4,
) void {
    const w = chf.width;
    const h = chf.height;
    const start_level_shifted = start_level >> log_levels_per_stack;

    // Clear all stacks
    for (stacks) |*stack| {
        stack.clearRetainingCapacity();
    }

    // Put all cells in the level range into the appropriate stacks
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                if (chf.areas[i] == NULL_AREA or src_reg[i] != 0) {
                    continue;
                }

                const level = chf.dist[i] >> log_levels_per_stack;
                const s_id_signed = @as(i32, @intCast(start_level_shifted)) - @as(i32, @intCast(level));
                if (s_id_signed >= @as(i32, @intCast(stacks.len))) {
                    continue;
                }
                const s_id: usize = if (s_id_signed < 0) 0 else @intCast(s_id_signed);

                stacks[s_id].append(.{ .x = x, .y = y, .index = @intCast(i) }) catch {
                    // If append fails, just skip this entry
                    continue;
                };
            }
        }
    }
}

/// Appends unprocessed entries from source stack to destination stack.
/// Used to carry over leftover cells from previous level.
fn appendStacks(
    src_stack: *const std.ArrayList(LevelStackEntry),
    dst_stack: *std.ArrayList(LevelStackEntry),
    src_reg: []const u16,
) void {
    for (src_stack.items) |entry| {
        const i = entry.index;
        if (i < 0 or src_reg[@intCast(i)] != 0) {
            continue;
        }
        dst_stack.append(entry) catch {
            // If append fails, just skip
            continue;
        };
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

/// Remove adjacent duplicate neighbours
fn removeAdjacentNeighbours(reg: *Region) void {
    var i: usize = 0;
    while (i < reg.connections.items.len and reg.connections.items.len > 1) {
        const ni = (i + 1) % reg.connections.items.len;
        if (reg.connections.items[i] == reg.connections.items[ni]) {
            // Remove duplicate
            _ = reg.connections.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Replace oldId with newId in connections and floors
fn replaceNeighbour(reg: *Region, old_id: u16, new_id: u16) void {
    var nei_changed = false;
    for (reg.connections.items) |*conn| {
        if (conn.* == old_id) {
            conn.* = new_id;
            nei_changed = true;
        }
    }
    for (reg.floors.items) |*floor| {
        if (floor.* == old_id) {
            floor.* = new_id;
        }
    }
    if (nei_changed) {
        removeAdjacentNeighbours(reg);
    }
}

/// Check if two regions can be merged
fn canMergeWithRegion(reg_a: *const Region, reg_b: *const Region) bool {
    if (reg_a.area_type != reg_b.area_type) return false;

    var n: i32 = 0;
    for (reg_a.connections.items) |conn| {
        if (conn == reg_b.id) n += 1;
    }
    if (n > 1) return false;

    for (reg_a.floors.items) |floor| {
        if (floor == reg_b.id) return false;
    }
    return true;
}

/// Merge region b into region a
fn mergeRegions(reg_a: *Region, reg_b: *Region, allocator: std.mem.Allocator) !bool {
    const aid = reg_a.id;
    const bid = reg_b.id;

    // Duplicate current neighbourhood
    var acon = std.ArrayList(i32).init(allocator);
    defer acon.deinit();
    try acon.appendSlice(reg_a.connections.items);

    // Find insertion point on A
    var insa: i32 = -1;
    for (acon.items, 0..) |conn, i| {
        if (conn == bid) {
            insa = @intCast(i);
            break;
        }
    }
    if (insa == -1) return false;

    // Find insertion point on B
    var insb: i32 = -1;
    for (reg_b.connections.items, 0..) |conn, i| {
        if (conn == aid) {
            insb = @intCast(i);
            break;
        }
    }
    if (insb == -1) return false;

    // Merge neighbours
    reg_a.connections.clearRetainingCapacity();

    const ni_a = @as(i32, @intCast(acon.items.len));
    var i: i32 = 0;
    while (i < ni_a - 1) : (i += 1) {
        const idx = @mod((insa + 1 + i), ni_a);
        try reg_a.connections.append(acon.items[@intCast(idx)]);
    }

    const ni_b = @as(i32, @intCast(reg_b.connections.items.len));
    i = 0;
    while (i < ni_b - 1) : (i += 1) {
        const idx = @mod((insb + 1 + i), ni_b);
        try reg_a.connections.append(reg_b.connections.items[@intCast(idx)]);
    }

    removeAdjacentNeighbours(reg_a);

    for (reg_b.floors.items) |floor| {
        try addUniqueFloorRegion(reg_a, floor);
    }
    reg_a.span_count += reg_b.span_count;
    reg_b.span_count = 0;
    reg_b.connections.clearRetainingCapacity();

    return true;
}

/// Check if region is connected to border
fn isRegionConnectedToBorder(reg: *const Region) bool {
    for (reg.connections.items) |conn| {
        if (conn == 0) return true;
    }
    return false;
}

/// Check if edge is solid (boundary)
fn isSolidEdge(
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    x: i32,
    y: i32,
    i: usize,
    dir: u2,
) bool {
    const s = chf.spans[i];
    var r: u16 = 0;
    if (s.getCon(dir) != NOT_CONNECTED) {
        const ax = x + heightfield_mod.getDirOffsetX(dir);
        const ay = y + heightfield_mod.getDirOffsetY(dir);
        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * chf.width))].index + s.getCon(dir)));
        r = src_reg[ai];
    }
    return r != src_reg[i];
}

/// Walk contour to find all neighbours
fn walkContour(
    x_start: i32,
    y_start: i32,
    i_start: usize,
    dir_start: u2,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    cont: *std.ArrayList(i32),
) !void {
    var x = x_start;
    var y = y_start;
    var i = i_start;
    var dir = dir_start;

    const start_dir = dir_start;
    const start_i = i_start;

    const ss = chf.spans[i];
    var cur_reg: u16 = 0;
    if (ss.getCon(dir) != NOT_CONNECTED) {
        const ax = x + heightfield_mod.getDirOffsetX(dir);
        const ay = y + heightfield_mod.getDirOffsetY(dir);
        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * chf.width))].index + ss.getCon(dir)));
        cur_reg = src_reg[ai];
    }
    try cont.append(@intCast(cur_reg));

    var iter: i32 = 0;
    while (iter < 40000) : (iter += 1) {
        const s = chf.spans[i];

        if (isSolidEdge(chf, src_reg, x, y, i, dir)) {
            // Choose the edge corner
            var r: u16 = 0;
            if (s.getCon(dir) != NOT_CONNECTED) {
                const ax = x + heightfield_mod.getDirOffsetX(dir);
                const ay = y + heightfield_mod.getDirOffsetY(dir);
                const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * chf.width))].index + s.getCon(dir)));
                r = src_reg[ai];
            }
            if (r != cur_reg) {
                cur_reg = r;
                try cont.append(@intCast(cur_reg));
            }

            dir = @truncate((dir +% 1) & 0x3); // Rotate CW
        } else {
            var ni: i32 = -1;
            const nx = x + heightfield_mod.getDirOffsetX(dir);
            const ny = y + heightfield_mod.getDirOffsetY(dir);
            if (s.getCon(dir) != NOT_CONNECTED) {
                const nc = chf.cells[@as(usize, @intCast(nx + ny * chf.width))];
                ni = @as(i32, @intCast(nc.index)) + @as(i32, @intCast(s.getCon(dir)));
            }
            if (ni == -1) {
                // Should not happen
                return;
            }
            x = nx;
            y = ny;
            i = @intCast(ni);
            dir = @truncate((dir +% 3) & 0x3); // Rotate CCW
        }

        if (start_i == i and start_dir == dir) {
            break;
        }
    }

    // Remove adjacent duplicates
    if (cont.items.len > 1) {
        var j: usize = 0;
        while (j < cont.items.len) {
            const nj = (j + 1) % cont.items.len;
            if (cont.items[j] == cont.items[nj]) {
                _ = cont.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }
}

/// Merge and filter regions based on area thresholds
fn mergeAndFilterRegions(
    ctx: *const Context,
    min_region_area: i32,
    merge_region_size: i32,
    max_region_id: *u16,
    chf: *CompactHeightfield,
    src_reg: []u16,
    overlaps: *std.ArrayList(i32),
    allocator: std.mem.Allocator,
) !void {
    const w = chf.width;
    const h = chf.height;

    const nreg = @as(usize, max_region_id.*) + 1;
    const regions = try allocator.alloc(Region, nreg);
    defer {
        for (regions) |*reg| {
            reg.deinit();
        }
        allocator.free(regions);
    }

    // Construct regions
    for (regions, 0..) |*reg, i| {
        reg.* = try Region.init(allocator, @intCast(i));
    }

    // Find edge of a region and find connections around the contour
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const cell = chf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const r = src_reg[i];
                if (r == 0 or r >= nreg) continue;

                var reg = &regions[r];
                reg.span_count += 1;

                // Update floors
                var j: usize = cell.index;
                while (j < ni) : (j += 1) {
                    if (i == j) continue;
                    const floor_id = src_reg[j];
                    if (floor_id == 0 or floor_id >= nreg) continue;
                    if (floor_id == r) {
                        reg.overlap = true;
                    }
                    try addUniqueFloorRegion(reg, @intCast(floor_id));
                }

                // Have found contour
                if (reg.connections.items.len > 0) continue;

                reg.area_type = chf.areas[i];

                // Check if this cell is next to a border
                var ndir: i32 = -1;
                var dir: u2 = 0;
                while (dir < 4) : (dir += 1) {
                    if (isSolidEdge(chf, src_reg, x, y, i, dir)) {
                        ndir = dir;
                        break;
                    }
                }

                if (ndir != -1) {
                    // The cell is at border - walk around the contour
                    try walkContour(x, y, i, @intCast(ndir), chf, src_reg, &reg.connections);
                }
            }
        }
    }

    // Debug: log region span counts
    ctx.log(.progress, "mergeAndFilterRegions: Region span counts:", .{});
    for (regions) |*reg| {
        if (reg.id > 0 and reg.span_count > 0 and (reg.id & BORDER_REG) == 0) {
            ctx.log(.progress, "  Region {d}: {d} spans, {d} connections", .{ reg.id, reg.span_count, reg.connections.items.len });
        }
    }

    // Remove too small regions
    var stack = std.ArrayList(i32).init(allocator);
    defer stack.deinit();
    var trace = std.ArrayList(i32).init(allocator);
    defer trace.deinit();

    for (regions, 0..) |*reg, i| {
        if (reg.id == 0 or (reg.id & BORDER_REG) != 0) continue;
        if (reg.span_count == 0) continue;
        if (reg.visited) continue;

        // Count the total size of all connected regions
        var connects_to_border = false;
        var span_count: i32 = 0;
        stack.clearRetainingCapacity();
        trace.clearRetainingCapacity();

        reg.visited = true;
        try stack.append(@intCast(i));

        while (stack.items.len > 0) {
            const ri = stack.pop() orelse break;
            const creg = &regions[@intCast(ri)];

            span_count += creg.span_count;
            try trace.append(ri);

            for (creg.connections.items) |conn| {
                if ((conn & BORDER_REG) != 0) {
                    connects_to_border = true;
                    continue;
                }
                var neireg = &regions[@intCast(conn)];
                if (neireg.visited) continue;
                if (neireg.id == 0 or (neireg.id & BORDER_REG) != 0) continue;

                try stack.append(neireg.id);
                neireg.visited = true;
            }
        }

        // If accumulated region is too small, remove it
        if (span_count < min_region_area and !connects_to_border) {
            // Debug: log which regions are being removed
            ctx.log(.progress, "  Removing small region group (spanCount={d} < {d}): ids={any}", .{ span_count, min_region_area, trace.items });
            for (trace.items) |ri| {
                regions[@intCast(ri)].span_count = 0;
                regions[@intCast(ri)].id = 0;
            }
        }
    }

    // Merge too small regions to neighbour regions
    var merge_count: i32 = 0;
    while (true) {
        merge_count = 0;
        for (regions) |*reg| {
            if (reg.id == 0 or (reg.id & BORDER_REG) != 0) continue;
            if (reg.overlap) continue;
            if (reg.span_count == 0) continue;

            // Check to see if the region should be merged
            if (reg.span_count > merge_region_size and isRegionConnectedToBorder(reg)) continue;

            // Find smallest neighbour region that connects to this one
            var smallest: i32 = 0x0fffffff;
            var merge_id: u16 = reg.id;
            for (reg.connections.items) |conn| {
                if ((conn & BORDER_REG) != 0) continue;
                const mreg = &regions[@intCast(conn)];
                if (mreg.id == 0 or (mreg.id & BORDER_REG) != 0 or mreg.overlap) continue;
                if (mreg.span_count < smallest and
                    canMergeWithRegion(reg, mreg) and
                    canMergeWithRegion(mreg, reg))
                {
                    smallest = mreg.span_count;
                    merge_id = mreg.id;
                }
            }

            // Found new id
            if (merge_id != reg.id) {
                const old_id = reg.id;
                const target = &regions[merge_id];

                // Merge neighbours
                if (try mergeRegions(target, reg, allocator)) {
                    ctx.log(.progress, "  Merging region {d} (spanCount={d}) into {d} (spanCount={d})", .{ old_id, reg.span_count, merge_id, target.span_count });
                    // Fixup regions pointing to current region
                    for (regions) |*fix_reg| {
                        if (fix_reg.id == 0 or (fix_reg.id & BORDER_REG) != 0) continue;
                        // If another region was already merged into current region
                        if (fix_reg.id == old_id) {
                            fix_reg.id = merge_id;
                        }
                        // Replace the current region with the new one
                        replaceNeighbour(fix_reg, old_id, merge_id);
                    }
                    merge_count += 1;
                }
            }
        }
        if (merge_count == 0) break;
    }

    // Compress region Ids
    for (regions) |*reg| {
        reg.remap = false;
        if (reg.id == 0) continue;
        if ((reg.id & BORDER_REG) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (regions, 0..) |*reg, i| {
        if (!reg.remap) continue;
        const old_id = reg.id;
        reg_id_gen += 1;
        const new_id = reg_id_gen;
        var j: usize = i;
        while (j < nreg) : (j += 1) {
            if (regions[j].id == old_id) {
                regions[j].id = new_id;
                regions[j].remap = false;
            }
        }
    }
    max_region_id.* = reg_id_gen;

    // Remap regions
    for (0..@intCast(chf.span_count)) |i| {
        if ((src_reg[i] & BORDER_REG) == 0) {
            src_reg[i] = regions[src_reg[i]].id;
        }
    }

    // Return regions that we found to be overlapping
    for (regions) |*reg| {
        if (reg.overlap) {
            try overlaps.append(@intCast(reg.id));
        }
    }

    ctx.log(.progress, "mergeAndFilterRegions: Merged and filtered to {d} regions", .{reg_id_gen});
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

    // Create multi-stack system for watershed (matching C++ algorithm)
    const LOG_NB_STACKS: u3 = 3;
    const NB_STACKS: usize = 1 << LOG_NB_STACKS; // 8 stacks

    var lvl_stacks: [NB_STACKS]std.ArrayList(LevelStackEntry) = undefined;
    for (&lvl_stacks) |*lvl_stack| {
        lvl_stack.* = std.ArrayList(LevelStackEntry).init(allocator);
    }
    defer {
        for (&lvl_stacks) |*lvl_stack| {
            lvl_stack.deinit();
        }
    }

    // Reserve capacity for each stack
    for (&lvl_stacks) |*lvl_stack| {
        try lvl_stack.ensureTotalCapacity(256);
    }

    var stack = std.ArrayList(LevelStackEntry).init(allocator);
    defer stack.deinit();
    try stack.ensureTotalCapacity(256);

    var s_id: i32 = -1;

    // Watershed partitioning with multi-stack system
    while (level > 0) {
        level = if (level >= 2) level - 2 else 0;
        s_id = (s_id + 1) & (@as(i32, NB_STACKS) - 1);

        // Sort cells by level or append from previous stack
        if (s_id == 0) {
            sortCellsByLevel(level, chf, src_reg, &lvl_stacks, 1);
        } else {
            const prev_id: usize = @intCast(s_id - 1);
            const curr_id: usize = @intCast(s_id);
            appendStacks(&lvl_stacks[prev_id], &lvl_stacks[curr_id], src_reg);
        }

        const curr_stack_id: usize = @intCast(s_id);

        // Expand current regions
        try expandRegions(expand_iters, level, chf, src_reg, src_dist, &lvl_stacks[curr_stack_id], false, allocator);

        // Flood fill new regions
        for (lvl_stacks[curr_stack_id].items) |current| {
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

    ctx.log(.progress, "buildRegions: max_distance={d}, level_start={d}", .{ chf.max_distance, (chf.max_distance + 1) & ~@as(u16, 1) });
    ctx.log(.progress, "buildRegions: Watershed created {d} regions (before merging)", .{region_id - 1});

    // Merge and filter regions
    var overlaps = std.ArrayList(i32).init(allocator);
    defer overlaps.deinit();
    try mergeAndFilterRegions(ctx, min_region_area, merge_region_area, &region_id, chf, src_reg, &overlaps, allocator);

    // Check for overlaps
    if (overlaps.items.len > 0) {
        ctx.log(.err, "buildRegions: {d} overlapping regions", .{overlaps.items.len});
    }

    // Write results to compact heightfield
    chf.max_regions = region_id;
    for (0..span_count) |i| {
        chf.spans[i].reg = src_reg[i];
    }

    ctx.log(.progress, "buildRegions: Created {d} regions", .{region_id - 1});
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

/// Структура для отслеживания регионов
const Region = struct {
    span_count: i32,
    id: u16,
    area_type: u8,
    remap: bool,
    visited: bool,
    overlap: bool,
    connects_to_border: bool,
    ymin: u16,
    ymax: u16,
    connections: std.ArrayList(i32),
    floors: std.ArrayList(i32),

    fn init(allocator: std.mem.Allocator, region_id: u16) !Region {
        return Region{
            .span_count = 0,
            .id = region_id,
            .area_type = 0,
            .remap = false,
            .visited = false,
            .overlap = false,
            .connects_to_border = false,
            .ymin = 0xffff,
            .ymax = 0,
            .connections = std.ArrayList(i32).init(allocator),
            .floors = std.ArrayList(i32).init(allocator),
        };
    }

    fn deinit(self: *Region) void {
        self.connections.deinit();
        self.floors.deinit();
    }
};

const NULL_NEI: u16 = 0xffff;

/// Добавляет уникальное соединение к региону
fn addUniqueConnection(reg: *Region, n: i32) !void {
    for (reg.connections.items) |conn| {
        if (conn == n) return;
    }
    try reg.connections.append(n);
}

/// Добавляет уникальный floor region
fn addUniqueFloorRegion(reg: *Region, n: i32) !void {
    for (reg.floors.items) |floor| {
        if (floor == n) return;
    }
    try reg.floors.append(n);
}

/// Объединяет монотонные регионы в слои и удаляет мелкие регионы
fn mergeAndFilterLayerRegions(
    _: *const Context,
    min_region_area: i32,
    max_region_id: *u16,
    chf: *CompactHeightfield,
    src_reg: []u16,
    allocator: std.mem.Allocator,
) !bool {
    const w = chf.width;
    const h = chf.height;

    const nreg: usize = @intCast(max_region_id.* + 1);
    var regions = std.ArrayList(Region).init(allocator);
    defer {
        for (regions.items) |*reg| {
            reg.deinit();
        }
        regions.deinit();
    }

    // Construct regions
    try regions.ensureTotalCapacity(nreg);
    for (0..nreg) |i| {
        try regions.append(try Region.init(allocator, @intCast(i)));
    }

    // Find region neighbours and overlapping regions
    var lregs = std.ArrayList(i32).init(allocator);
    defer lregs.deinit();

    for (0..@intCast(h)) |y| {
        for (0..@intCast(w)) |x| {
            const cell_idx = x + y * @as(usize, @intCast(w));
            const c = chf.cells[cell_idx];

            lregs.clearRetainingCapacity();

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                const area = chf.areas[i];
                const ri = src_reg[i];
                if (ri == 0 or ri >= nreg) continue;
                var reg = &regions.items[ri];

                reg.span_count += 1;
                reg.area_type = area;
                reg.ymin = @min(reg.ymin, s.y);
                reg.ymax = @max(reg.ymax, s.y);

                // Collect all region layers
                try lregs.append(@intCast(ri));

                // Update neighbours
                for (0..4) |dir| {
                    const dir_u2: u2 = @intCast(dir);
                    if (s.getCon(dir_u2) != NOT_CONNECTED) {
                        const ax: i32 = @intCast(x);
                        const ay: i32 = @intCast(y);
                        const neighbor_x = ax + heightfield_mod.getDirOffsetX(dir_u2);
                        const neighbor_y = ay + heightfield_mod.getDirOffsetY(dir_u2);
                        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(neighbor_x + neighbor_y * @as(i32, @intCast(w))))].index + s.getCon(dir_u2)));
                        const rai = src_reg[ai];
                        if (rai > 0 and rai < nreg and rai != ri) {
                            try addUniqueConnection(reg, @intCast(rai));
                        }
                        if ((rai & BORDER_REG) != 0) {
                            reg.connects_to_border = true;
                        }
                    }
                }
            }

            // Update overlapping regions
            if (lregs.items.len > 1) {
                for (0..lregs.items.len - 1) |ii| {
                    for (ii + 1..lregs.items.len) |jj| {
                        if (lregs.items[ii] != lregs.items[jj]) {
                            const ri_idx: usize = @intCast(lregs.items[ii]);
                            const rj_idx: usize = @intCast(lregs.items[jj]);
                            try addUniqueFloorRegion(&regions.items[ri_idx], lregs.items[jj]);
                            try addUniqueFloorRegion(&regions.items[rj_idx], lregs.items[ii]);
                        }
                    }
                }
            }
        }
    }

    // Create 2D layers from regions
    var layer_id: u16 = 1;

    for (regions.items) |*reg| {
        reg.id = 0;
    }

    // Merge monotone regions to create non-overlapping areas
    var stack = std.ArrayList(i32).init(allocator);
    defer stack.deinit();

    for (1..nreg) |i| {
        var root = &regions.items[i];
        if (root.id != 0) continue;

        root.id = layer_id;
        stack.clearRetainingCapacity();
        try stack.append(@intCast(i));

        while (stack.items.len > 0) {
            // Pop front
            const reg_idx: usize = @intCast(stack.items[0]);
            const reg = &regions.items[reg_idx];
            stack.orderedRemove(0);

            for (reg.connections.items) |nei| {
                const nei_idx: usize = @intCast(nei);
                var regn = &regions.items[nei_idx];
                if (regn.id != 0) continue;
                if (reg.area_type != regn.area_type) continue;

                // Check if overlapping with root
                var overlap = false;
                for (root.floors.items) |floor| {
                    if (floor == nei) {
                        overlap = true;
                        break;
                    }
                }
                if (overlap) continue;

                // Deepen
                try stack.append(nei);

                // Mark layer id
                regn.id = layer_id;

                // Merge current layers to root
                for (regn.floors.items) |floor| {
                    try addUniqueFloorRegion(root, floor);
                }
                root.ymin = @min(root.ymin, regn.ymin);
                root.ymax = @max(root.ymax, regn.ymax);
                root.span_count += regn.span_count;
                regn.span_count = 0;
                root.connects_to_border = root.connects_to_border or regn.connects_to_border;
            }
        }

        layer_id += 1;
    }

    // Remove small regions
    for (regions.items) |*reg| {
        if (reg.span_count > 0 and reg.span_count < min_region_area and !reg.connects_to_border) {
            const reg_id = reg.id;
            for (regions.items) |*r| {
                if (r.id == reg_id) {
                    r.id = 0;
                }
            }
        }
    }

    // Compress region IDs
    for (regions.items) |*reg| {
        reg.remap = false;
        if (reg.id == 0) continue;
        if ((reg.id & BORDER_REG) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (0..nreg) |i| {
        if (!regions.items[i].remap) continue;
        const old_id = regions.items[i].id;
        const new_id = blk: {
            reg_id_gen += 1;
            break :blk reg_id_gen;
        };
        for (i..nreg) |j| {
            if (regions.items[j].id == old_id) {
                regions.items[j].id = new_id;
                regions.items[j].remap = false;
            }
        }
    }
    max_region_id.* = reg_id_gen;

    // Remap regions
    for (0..chf.span_count) |i| {
        if ((src_reg[i] & BORDER_REG) == 0) {
            src_reg[i] = regions.items[src_reg[i]].id;
        }
    }

    return true;
}

/// Строит регионы слоёв для tiled navmesh
pub fn buildLayerRegions(
    ctx: *const Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    allocator: std.mem.Allocator,
) !void {
    // TODO: timer
    const w = chf.width;
    const h = chf.height;
    var id: u16 = 1;

    const src_reg = try allocator.alloc(u16, @intCast(chf.span_count));
    defer allocator.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps = @max(chf.width, chf.height);
    const sweeps = try allocator.alloc(SweepSpan, @intCast(nsweeps));
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
        const id_usize: usize = @intCast(id);
        if (id_usize + 1 > prev.items.len) {
            try prev.resize(id_usize + 1);
        }
        @memset(prev.items[0..id_usize], 0);
        var rid: u16 = 1;

        var x: i32 = border_size;
        while (x < w - border_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const c = chf.cells[cell_idx];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                if (chf.areas[i] == NULL_AREA) continue;

                // -x direction
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

                // -y direction
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
                            sweeps[previd].nei = NULL_NEI;
                        }
                    }
                }

                src_reg[i] = previd;
            }
        }

        // Create unique ID
        for (1..@intCast(rid)) |ii| {
            if (sweeps[ii].nei != NULL_NEI and sweeps[ii].nei != 0 and
                prev.items[sweeps[ii].nei] == @as(i32, @intCast(sweeps[ii].ns)))
            {
                sweeps[ii].id = sweeps[ii].nei;
            } else {
                sweeps[ii].id = id;
                id += 1;
            }
        }

        // Remap IDs
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + y * w));
            const c = chf.cells[cell_idx];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                if (src_reg[i] > 0 and src_reg[i] < rid) {
                    src_reg[i] = sweeps[src_reg[i]].id;
                }
            }
        }
    }

    // Merge monotone regions to layers and remove small regions
    chf.max_regions = id;
    if (!try mergeAndFilterLayerRegions(ctx, min_region_area, &chf.max_regions, chf, src_reg, allocator)) {
        return error.MergeRegionsFailed;
    }

    // Store the result
    for (0..@intCast(chf.span_count)) |i| {
        chf.spans[i].reg = src_reg[i];
    }
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
