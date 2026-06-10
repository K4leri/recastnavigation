//! ANALOG of recast.region.buildDistanceField: a verbatim copy whose two
//! direction sweeps (calculateDistanceField boundary-mark + boxBlur) use a
//! runtime `for (0..4)` instead of the library's `inline for (0..4)`. Everything
//! else is identical, so an EXACT output-gate (compare chf.dist + max_distance)
//! isolates the comptime-direction effect on Zig 0.16.
//!
//! Result on Zig 0.16: bit-identical output; the analog (inline-for, library
//! form) is consistently ~2-10% faster on a same-run A/B — LLVM unrolls the
//! runtime loop too, but the analog's address-mode/scheduling is slightly tighter.
//! See RESULTS.md "Addendum (2026-06)".

const std = @import("std");
const nav = @import("zig-recast");

const CompactHeightfield = nav.CompactHeightfield;
const Context = nav.Context;
const heightfield_mod = nav.recast.heightfield;
const NOT_CONNECTED = nav.recast.config.NOT_CONNECTED;

fn calculateDistanceField_origfor(
    chf: *CompactHeightfield,
    src: []u16,
    max_dist: *u16,
) void {
    const w = chf.width;
    const h = chf.height;

    @memset(src, 0xffff);

    // Mark boundary cells — RUNTIME for (the only change vs the library).
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
                for (0..4) |dir_i| {
                    const dir_u2: u2 = @intCast(dir_i);
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

    // Pass 1 - forward sweep (hand-unrolled in the library too; copied verbatim).
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

                if (s.getCon(0) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(0);
                    const ay = y + heightfield_mod.getDirOffsetY(0);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(0)));
                    const as = chf.spans[ai];
                    const nd0 = @as(u32, src[ai]) + 2;
                    if (nd0 < src[i]) {
                        src[i] = @intCast(nd0);
                    }
                    if (as.getCon(3) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(3);
                        const aay = ay + heightfield_mod.getDirOffsetY(3);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(3)));
                        const nd1 = @as(u32, src[aai]) + 3;
                        if (nd1 < src[i]) {
                            src[i] = @intCast(nd1);
                        }
                    }
                }

                if (s.getCon(3) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(3);
                    const ay = y + heightfield_mod.getDirOffsetY(3);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(3)));
                    const as = chf.spans[ai];
                    const nd0 = @as(u32, src[ai]) + 2;
                    if (nd0 < src[i]) {
                        src[i] = @intCast(nd0);
                    }
                    if (as.getCon(2) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(2);
                        const aay = ay + heightfield_mod.getDirOffsetY(2);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(2)));
                        const nd1 = @as(u32, src[aai]) + 3;
                        if (nd1 < src[i]) {
                            src[i] = @intCast(nd1);
                        }
                    }
                }
            }
        }
    }

    // Pass 2 - backward sweep.
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

                if (s.getCon(2) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(2);
                    const ay = y + heightfield_mod.getDirOffsetY(2);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(2)));
                    const as = chf.spans[ai];
                    const nd0 = @as(u32, src[ai]) + 2;
                    if (nd0 < src[i]) {
                        src[i] = @intCast(nd0);
                    }
                    if (as.getCon(1) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(1);
                        const aay = ay + heightfield_mod.getDirOffsetY(1);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(1)));
                        const nd1 = @as(u32, src[aai]) + 3;
                        if (nd1 < src[i]) {
                            src[i] = @intCast(nd1);
                        }
                    }
                }

                if (s.getCon(1) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(1);
                    const ay = y + heightfield_mod.getDirOffsetY(1);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(1)));
                    const as = chf.spans[ai];
                    const nd0 = @as(u32, src[ai]) + 2;
                    if (nd0 < src[i]) {
                        src[i] = @intCast(nd0);
                    }
                    if (as.getCon(0) != NOT_CONNECTED) {
                        const aax = ax + heightfield_mod.getDirOffsetX(0);
                        const aay = ay + heightfield_mod.getDirOffsetY(0);
                        const aai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(aax + aay * w))].index + as.getCon(0)));
                        const nd1 = @as(u32, src[aai]) + 3;
                        if (nd1 < src[i]) {
                            src[i] = @intCast(nd1);
                        }
                    }
                }
            }
        }
    }

    max_dist.* = 0;
    for (src) |d| {
        if (d > max_dist.*) {
            max_dist.* = d;
        }
    }
}

fn boxBlur_origfor(
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
                // RUNTIME for (the only change vs the library's inline for).
                for (0..4) |dir_i| {
                    const dir_u2: u2 = @intCast(dir_i);
                    if (s.getCon(dir_u2) != NOT_CONNECTED) {
                        const ax = x + heightfield_mod.getDirOffsetX(dir_u2);
                        const ay = y + heightfield_mod.getDirOffsetY(dir_u2);
                        const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * w))].index + s.getCon(dir_u2)));
                        d += @intCast(src[ai]);

                        const as = chf.spans[ai];
                        const dir2: u2 = @intCast((dir_i + 1) & 0x3);
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

/// Full buildDistanceField driver (verbatim copy of the library's, minus tracy
/// zones), wired to the runtime-`for` sweeps above.
pub fn buildDistanceField_orig(
    ctx: *const Context,
    chf: *CompactHeightfield,
    allocator: std.mem.Allocator,
) !void {
    _ = ctx;

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
    calculateDistanceField_origfor(chf, src, &max_dist);
    chf.max_distance = max_dist;

    const blur_result = boxBlur_origfor(chf, 1, src, dst);

    chf.dist = try allocator.alloc(u16, span_count);
    if (blur_result.ptr == dst.ptr) {
        @memcpy(chf.dist, dst);
    } else {
        @memcpy(chf.dist, src);
    }
}
