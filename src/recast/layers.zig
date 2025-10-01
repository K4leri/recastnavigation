// Heightfield layers generation for Recast
const std = @import("std");
const config = @import("config.zig");
const heightfield = @import("heightfield.zig");
const polymesh = @import("polymesh.zig");

const Context = config.Context;
const CompactHeightfield = heightfield.CompactHeightfield;
const CompactSpan = heightfield.CompactSpan;
const CompactCell = heightfield.CompactCell;
const HeightfieldLayerSet = polymesh.HeightfieldLayerSet;
const HeightfieldLayer = polymesh.HeightfieldLayer;

const RC_NULL_AREA = config.NULL_AREA;
const NOT_CONNECTED = config.NOT_CONNECTED;

// Constants for layers
const RC_MAX_LAYERS = 63;
const RC_MAX_NEIS = 16;
const MAX_STACK = 64;

/// Layer region structure
const LayerRegion = struct {
    layers: [RC_MAX_LAYERS]u8,
    neis: [RC_MAX_NEIS]u8,
    ymin: u16,
    ymax: u16,
    layer_id: u8,
    nlayers: u8,
    nneis: u8,
    base: u8,
};

/// Sweep span structure for monotone partitioning
const LayerSweepSpan = struct {
    ns: u16,
    id: u8,
    nei: u8,
};

// ============================================================================
// Helper functions
// ============================================================================

/// Check if array contains value
fn contains(a: []const u8, v: u8) bool {
    for (a) |val| {
        if (val == v) return true;
    }
    return false;
}

/// Add value to array if not present
fn addUnique(a: []u8, an: *u8, an_max: usize, v: u8) bool {
    if (contains(a[0..an.*], v)) return true;
    if (an.* >= an_max) return false;
    a[an.*] = v;
    an.* += 1;
    return true;
}

/// Check if two ranges overlap
inline fn overlapRange(amin: u16, amax: u16, bmin: u16, bmax: u16) bool {
    return !(amin > bmax or amax < bmin);
}

/// Get direction offset for X coordinate
inline fn getDirOffsetX(dir: usize) i32 {
    const offset = [_]i32{ -1, 0, 1, 0 };
    return offset[dir & 0x03];
}

/// Get direction offset for Y coordinate
inline fn getDirOffsetY(dir: usize) i32 {
    const offset = [_]i32{ 0, 1, 0, -1 };
    return offset[dir & 0x03];
}

/// Get connection value from compact span
inline fn getCon(s: *const CompactSpan, dir: usize) u8 {
    const shift: u5 = @intCast((dir & 0x3) * 6);
    return @truncate((s.con >> shift) & 0x3f);
}

// ============================================================================
// Main layer building function
// ============================================================================

/// Build heightfield layers for tiled navigation meshes
pub fn buildHeightfieldLayers(
    ctx: *const Context,
    chf: *const CompactHeightfield,
    border_size: i32,
    walkable_height: i32,
    lset: *HeightfieldLayerSet,
    allocator: std.mem.Allocator,
) !void {
    const w = chf.width;
    const h = chf.height;

    // Allocate source region array
    const src_reg = try allocator.alloc(u8, chf.span_count);
    defer allocator.free(src_reg);
    @memset(src_reg, 0xff);

    // Allocate sweep spans
    const nsweeps: usize = @intCast(chf.width);
    const sweeps = try allocator.alloc(LayerSweepSpan, nsweeps);
    defer allocator.free(sweeps);

    // Partition walkable area into monotone regions
    var prev_count: [256]i32 = undefined;
    var reg_id: u8 = 0;

    var y: i32 = border_size;
    while (y < h - border_size) : (y += 1) {
        @memset(prev_count[0..reg_id], 0);
        var sweep_id: u8 = 0;

        var x: i32 = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                if (chf.areas[i] == RC_NULL_AREA) continue;

                var sid: u8 = 0xff;

                // Check -x direction
                if (getCon(&s, 0) != NOT_CONNECTED) {
                    const ax = x + getDirOffsetX(0);
                    const ay = y + getDirOffsetY(0);
                    const ai = chf.cells[@intCast(ax + ay * w)].index + getCon(&s, 0);
                    if (chf.areas[ai] != RC_NULL_AREA and src_reg[ai] != 0xff) {
                        sid = src_reg[ai];
                    }
                }

                if (sid == 0xff) {
                    sid = sweep_id;
                    sweep_id += 1;
                    sweeps[sid].nei = 0xff;
                    sweeps[sid].ns = 0;
                }

                // Check -y direction
                if (getCon(&s, 3) != NOT_CONNECTED) {
                    const ax = x + getDirOffsetX(3);
                    const ay = y + getDirOffsetY(3);
                    const ai = chf.cells[@intCast(ax + ay * w)].index + getCon(&s, 3);
                    const nr = src_reg[ai];
                    if (nr != 0xff) {
                        if (sweeps[sid].ns == 0) {
                            sweeps[sid].nei = nr;
                        }

                        if (sweeps[sid].nei == nr) {
                            sweeps[sid].ns += 1;
                            prev_count[nr] += 1;
                        } else {
                            sweeps[sid].nei = 0xff;
                        }
                    }
                }

                src_reg[i] = sid;
            }
        }

        // Create unique IDs
        var i: usize = 0;
        while (i < sweep_id) : (i += 1) {
            if (sweeps[i].nei != 0xff and prev_count[sweeps[i].nei] == sweeps[i].ns) {
                sweeps[i].id = sweeps[i].nei;
            } else {
                if (reg_id == 255) {
                    ctx.log(.err, "rcBuildHeightfieldLayers: Region ID overflow.", .{});
                    return error.RegionIdOverflow;
                }
                sweeps[i].id = reg_id;
                reg_id += 1;
            }
        }

        // Remap local sweep ids to region ids
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            i = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                if (src_reg[i] != 0xff) {
                    src_reg[i] = sweeps[src_reg[i]].id;
                }
            }
        }
    }

    // Allocate and init layer regions
    const nregs: usize = reg_id;
    const regs = try allocator.alloc(LayerRegion, nregs);
    defer allocator.free(regs);

    for (regs) |*reg| {
        @memset(&reg.layers, 0);
        @memset(&reg.neis, 0);
        reg.ymin = 0xffff;
        reg.ymax = 0;
        reg.layer_id = 0xff;
        reg.nlayers = 0;
        reg.nneis = 0;
        reg.base = 0;
    }

    // Find region neighbours and overlapping regions
    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];

            var lregs: [RC_MAX_LAYERS]u8 = undefined;
            var nlregs: usize = 0;

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = chf.spans[i];
                const ri = src_reg[i];
                if (ri == 0xff) continue;

                regs[ri].ymin = @min(regs[ri].ymin, s.y);
                regs[ri].ymax = @max(regs[ri].ymax, s.y);

                // Collect all region layers
                if (nlregs < RC_MAX_LAYERS) {
                    lregs[nlregs] = ri;
                    nlregs += 1;
                }

                // Update neighbours
                for (0..4) |dir| {
                    if (getCon(&s, dir) != NOT_CONNECTED) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = chf.cells[@intCast(ax + ay * w)].index + getCon(&s, dir);
                        const rai = src_reg[ai];
                        if (rai != 0xff and rai != ri) {
                            _ = addUnique(&regs[ri].neis, &regs[ri].nneis, RC_MAX_NEIS, rai);
                        }
                    }
                }
            }

            // Update overlapping regions
            var ii: usize = 0;
            while (ii < nlregs - 1) : (ii += 1) {
                var j: usize = ii + 1;
                while (j < nlregs) : (j += 1) {
                    if (lregs[ii] != lregs[j]) {
                        if (!addUnique(&regs[lregs[ii]].layers, &regs[lregs[ii]].nlayers, RC_MAX_LAYERS, lregs[j]) or
                            !addUnique(&regs[lregs[j]].layers, &regs[lregs[j]].nlayers, RC_MAX_LAYERS, lregs[ii]))
                        {
                            ctx.log(.err, "rcBuildHeightfieldLayers: layer overflow (too many overlapping walkable platforms). Try increasing RC_MAX_LAYERS.", .{});
                            return error.LayerOverflow;
                        }
                    }
                }
            }
        }
    }

    // Create 2D layers from regions
    var layer_id: u8 = 0;
    var stack: [MAX_STACK]u8 = undefined;

    for (0..nregs) |i| {
        if (regs[i].layer_id != 0xff) continue;

        regs[i].layer_id = layer_id;
        regs[i].base = 1;

        var nstack: usize = 0;
        stack[nstack] = @intCast(i);
        nstack += 1;

        while (nstack > 0) {
            const reg_idx = stack[0];
            nstack -= 1;
            for (0..nstack) |j| {
                stack[j] = stack[j + 1];
            }

            const nneis = regs[reg_idx].nneis;
            for (0..nneis) |j| {
                const nei = regs[reg_idx].neis[j];
                if (regs[nei].layer_id != 0xff) continue;
                if (contains(regs[i].layers[0..regs[i].nlayers], nei)) continue;

                const ymin = @min(regs[i].ymin, regs[nei].ymin);
                const ymax = @max(regs[i].ymax, regs[nei].ymax);
                if (ymax - ymin >= 255) continue;

                if (nstack < MAX_STACK) {
                    stack[nstack] = nei;
                    nstack += 1;

                    regs[nei].layer_id = layer_id;
                    for (0..regs[nei].nlayers) |k| {
                        if (!addUnique(&regs[i].layers, &regs[i].nlayers, RC_MAX_LAYERS, regs[nei].layers[k])) {
                            ctx.log(.err, "rcBuildHeightfieldLayers: layer overflow.", .{});
                            return error.LayerOverflow;
                        }
                    }
                    regs[i].ymin = @min(regs[i].ymin, regs[nei].ymin);
                    regs[i].ymax = @max(regs[i].ymax, regs[nei].ymax);
                }
            }
        }

        layer_id += 1;
    }

    // Merge non-overlapping regions that are close in height
    const merge_height: u16 = @intCast(walkable_height * 4);

    for (0..nregs) |i| {
        if (regs[i].base == 0) continue;

        const new_id = regs[i].layer_id;

        while (true) {
            var old_id: u8 = 0xff;

            for (0..nregs) |j| {
                if (i == j) continue;
                if (regs[j].base == 0) continue;

                if (!overlapRange(regs[i].ymin, regs[i].ymax + merge_height, regs[j].ymin, regs[j].ymax + merge_height)) continue;

                const ymin = @min(regs[i].ymin, regs[j].ymin);
                const ymax = @max(regs[i].ymax, regs[j].ymax);
                if (ymax - ymin >= 255) continue;

                var overlap = false;
                for (0..nregs) |k| {
                    if (regs[k].layer_id != regs[j].layer_id) continue;
                    if (contains(regs[i].layers[0..regs[i].nlayers], @intCast(k))) {
                        overlap = true;
                        break;
                    }
                }

                if (overlap) continue;

                old_id = regs[j].layer_id;
                break;
            }

            if (old_id == 0xff) break;

            for (0..nregs) |j| {
                if (regs[j].layer_id == old_id) {
                    regs[j].base = 0;
                    regs[j].layer_id = new_id;
                    for (0..regs[j].nlayers) |k| {
                        if (!addUnique(&regs[i].layers, &regs[i].nlayers, RC_MAX_LAYERS, regs[j].layers[k])) {
                            ctx.log(.err, "rcBuildHeightfieldLayers: layer overflow.", .{});
                            return error.LayerOverflow;
                        }
                    }
                    regs[i].ymin = @min(regs[i].ymin, regs[j].ymin);
                    regs[i].ymax = @max(regs[i].ymax, regs[j].ymax);
                }
            }
        }
    }

    // Compact layer IDs
    var remap: [256]u8 = undefined;
    @memset(&remap, 0);

    layer_id = 0;
    for (0..nregs) |i| {
        remap[regs[i].layer_id] = 1;
    }
    for (0..256) |i| {
        if (remap[i] != 0) {
            remap[i] = layer_id;
            layer_id += 1;
        } else {
            remap[i] = 0xff;
        }
    }
    for (0..nregs) |i| {
        regs[i].layer_id = remap[regs[i].layer_id];
    }

    if (layer_id == 0) return;

    // Create layers
    const lw = w - border_size * 2;
    const lh = h - border_size * 2;

    var bmin = chf.bmin;
    var bmax = chf.bmax;
    bmin[0] += @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmin[2] += @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmax[0] -= @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmax[2] -= @as(f32, @floatFromInt(border_size)) * chf.cs;

    lset.nlayers = layer_id;
    lset.layers = try allocator.alloc(HeightfieldLayer, lset.nlayers);

    for (0..lset.nlayers) |i| {
        const cur_id: u8 = @intCast(i);
        var layer = &lset.layers[i];

        const grid_size: usize = @intCast(lw * lh);

        layer.heights = try allocator.alloc(u8, grid_size);
        @memset(layer.heights, 0xff);

        layer.areas = try allocator.alloc(u8, grid_size);
        @memset(layer.areas, 0);

        layer.cons = try allocator.alloc(u8, grid_size);
        @memset(layer.cons, 0);

        // Find layer height bounds
        var hmin: i32 = 0;
        var hmax: i32 = 0;
        for (0..nregs) |j| {
            if (regs[j].base != 0 and regs[j].layer_id == cur_id) {
                hmin = @intCast(regs[j].ymin);
                hmax = @intCast(regs[j].ymax);
            }
        }

        layer.width = lw;
        layer.height = lh;
        layer.cs = chf.cs;
        layer.ch = chf.ch;

        layer.bmin = bmin;
        layer.bmax = bmax;
        layer.bmin[1] = bmin[1] + @as(f32, @floatFromInt(hmin)) * chf.ch;
        layer.bmax[1] = bmin[1] + @as(f32, @floatFromInt(hmax)) * chf.ch;
        layer.hmin = @intCast(hmin);
        layer.hmax = @intCast(hmax);

        layer.minx = layer.width;
        layer.maxx = 0;
        layer.miny = layer.height;
        layer.maxy = 0;

        // Copy height and area from compact heightfield
        y = 0;
        while (y < lh) : (y += 1) {
            var x: i32 = 0;
            while (x < lw) : (x += 1) {
                const cx = border_size + x;
                const cy = border_size + y;
                const c = chf.cells[@intCast(cx + cy * w)];

                var j: usize = c.index;
                const nj = c.index + c.count;
                while (j < nj) : (j += 1) {
                    const s = chf.spans[j];
                    if (src_reg[j] == 0xff) continue;

                    const lid = regs[src_reg[j]].layer_id;
                    if (lid != cur_id) continue;

                    layer.minx = @min(layer.minx, x);
                    layer.maxx = @max(layer.maxx, x);
                    layer.miny = @min(layer.miny, y);
                    layer.maxy = @max(layer.maxy, y);

                    const idx: usize = @intCast(x + y * lw);
                    layer.heights[idx] = @intCast(s.y - hmin);
                    layer.areas[idx] = chf.areas[j];

                    var portal: u8 = 0;
                    var con: u8 = 0;
                    for (0..4) |dir| {
                        if (getCon(&s, dir) != NOT_CONNECTED) {
                            const ax = cx + getDirOffsetX(dir);
                            const ay = cy + getDirOffsetY(dir);
                            const ai = chf.cells[@intCast(ax + ay * w)].index + getCon(&s, dir);
                            const alid = if (src_reg[ai] != 0xff) regs[src_reg[ai]].layer_id else 0xff;

                            if (chf.areas[ai] != RC_NULL_AREA and lid != alid) {
                                portal |= @as(u8, @intCast(1 << @as(u3, @intCast(dir))));
                                const as = chf.spans[ai];
                                if (as.y > hmin) {
                                    layer.heights[idx] = @max(layer.heights[idx], @as(u8, @intCast(as.y - hmin)));
                                }
                            }

                            if (chf.areas[ai] != RC_NULL_AREA and lid == alid) {
                                const nx = ax - border_size;
                                const ny = ay - border_size;
                                if (nx >= 0 and ny >= 0 and nx < lw and ny < lh) {
                                    con |= @as(u8, @intCast(1 << @as(u3, @intCast(dir))));
                                }
                            }
                        }
                    }

                    layer.cons[idx] = (portal << 4) | con;
                }
            }
        }

        if (layer.minx > layer.maxx) {
            layer.minx = 0;
            layer.maxx = 0;
        }
        if (layer.miny > layer.maxy) {
            layer.miny = 0;
            layer.maxy = 0;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "contains - value present" {
    const arr = [_]u8{ 1, 2, 3, 4, 5 };
    try testing.expect(contains(&arr, 3));
}

test "contains - value absent" {
    const arr = [_]u8{ 1, 2, 3, 4, 5 };
    try testing.expect(!contains(&arr, 6));
}

test "addUnique - new value" {
    var arr: [10]u8 = undefined;
    var count: u8 = 0;
    try testing.expect(addUnique(&arr, &count, 10, 5));
    try testing.expectEqual(@as(u8, 1), count);
    try testing.expectEqual(@as(u8, 5), arr[0]);
}

test "addUnique - duplicate value" {
    var arr: [10]u8 = undefined;
    var count: u8 = 0;
    try testing.expect(addUnique(&arr, &count, 10, 5));
    try testing.expect(addUnique(&arr, &count, 10, 5));
    try testing.expectEqual(@as(u8, 1), count);
}

test "overlapRange - overlapping" {
    try testing.expect(overlapRange(10, 20, 15, 25));
    try testing.expect(overlapRange(15, 25, 10, 20));
}

test "overlapRange - non-overlapping" {
    try testing.expect(!overlapRange(10, 20, 25, 35));
    try testing.expect(!overlapRange(25, 35, 10, 20));
}
