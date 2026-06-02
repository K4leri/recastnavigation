const std = @import("std");
const math = @import("../math.zig");
const heightfield_mod = @import("heightfield.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const Heightfield = heightfield_mod.Heightfield;
const CompactHeightfield = heightfield_mod.CompactHeightfield;
const Span = heightfield_mod.Span;
const CompactSpan = heightfield_mod.CompactSpan;
const CompactCell = heightfield_mod.CompactCell;

const NULL_AREA = config.AreaId.NULL_AREA;
const NOT_CONNECTED = config.NOT_CONNECTED;
const MAX_HEIGHTFIELD_HEIGHT: i32 = 0xffff;

/// All four 6-bit direction slots packed with NOT_CONNECTED (0x3f) — the initial
/// `con` value before any walkable neighbor is found in the connect loop.
const ALL_DIRS_NOT_CONNECTED: u24 = (@as(u24, NOT_CONNECTED) << 18) |
    (@as(u24, NOT_CONNECTED) << 12) |
    (@as(u24, NOT_CONNECTED) << 6) |
    @as(u24, NOT_CONNECTED);

/// Returns the number of walkable spans in the heightfield.
pub fn getHeightFieldSpanCount(ctx: *const Context, heightfield: *const Heightfield) usize {
    _ = ctx; // TODO: timer
    const num_cols = heightfield.width * heightfield.height;
    var span_count: usize = 0;

    var col_idx: usize = 0;
    while (col_idx < num_cols) : (col_idx += 1) {
        var span = heightfield.spans[col_idx];
        while (span) |s| {
            if (s.area != NULL_AREA) {
                span_count += 1;
            }
            span = s.next;
        }
    }

    return span_count;
}

/// Builds a compact heightfield from a regular heightfield.
///
/// A compact heightfield is a more memory-efficient representation that:
/// - Stores spans contiguously instead of as linked lists
/// - Pre-calculates neighbor connections for pathfinding
/// - Uses cells that index into the span array
///
/// This is typically called after filtering the heightfield.
pub fn buildCompactHeightfield(
    ctx: *const Context,
    walkable_height: i32,
    walkable_climb: i32,
    heightfield: *const Heightfield,
    compact_hf: *CompactHeightfield,
) !void {
    // const timer = ctx.startTimer(.build_compact_heightfield);
    // defer timer.stop();

    const x_size = heightfield.width;
    const z_size = heightfield.height;
    const span_count = getHeightFieldSpanCount(ctx, heightfield);

    // Fill in header
    compact_hf.width = x_size;
    compact_hf.height = z_size;
    compact_hf.span_count = @intCast(span_count);
    compact_hf.walkable_height = walkable_height;
    compact_hf.walkable_climb = walkable_climb;
    compact_hf.max_regions = 0;
    compact_hf.bmin = heightfield.bmin;
    compact_hf.bmax = heightfield.bmax;
    compact_hf.bmax.y += @as(f32, @floatFromInt(walkable_height)) * heightfield.ch;
    compact_hf.cs = heightfield.cs;
    compact_hf.ch = heightfield.ch;

    // Allocate cells (or reallocate if size changed)
    const cells_len = @as(usize, @intCast(x_size * z_size));
    compact_hf.cells = try compact_hf.allocator.alloc(CompactCell, cells_len);
    @memset(compact_hf.cells, .{ .index = 0, .count = 0 });

    // Allocate spans
    compact_hf.spans = try compact_hf.allocator.alloc(CompactSpan, span_count);
    @memset(compact_hf.spans, .{ .y = 0, .reg = 0, .con = 0, .h = 0 });

    // Allocate areas
    compact_hf.areas = try compact_hf.allocator.alloc(u8, span_count);
    @memset(compact_hf.areas, NULL_AREA);

    // Fill in cells and spans
    var current_cell_index: usize = 0;
    const num_columns = @as(usize, @intCast(x_size * z_size));

    var col_idx: usize = 0;
    while (col_idx < num_columns) : (col_idx += 1) {
        var span = heightfield.spans[col_idx];

        // If there are no spans at this cell, just leave the data to index=0, count=0
        if (span == null) {
            continue;
        }

        var cell = &compact_hf.cells[col_idx];
        cell.index = @intCast(current_cell_index);
        cell.count = 0;

        while (span) |s| {
            if (s.area != NULL_AREA) {
                const bot: i32 = @intCast(s.smax);
                const top: i32 = if (s.next) |next| @intCast(next.smin) else MAX_HEIGHTFIELD_HEIGHT;

                // Write the whole packed CompactSpan in ONE store instead of two
                // partial-field stores (.y then .h), each of which lowers to a
                // read-modify-write on the packed backing word. reg/con are 0 here
                // (the connect phase overwrites con later) — byte-identical.
                compact_hf.spans[current_cell_index] = .{
                    .y = @intCast(std.math.clamp(bot, 0, 0xffff)),
                    .reg = 0,
                    .con = 0,
                    .h = @intCast(std.math.clamp(top - bot, 0, 0xff)),
                };
                compact_hf.areas[current_cell_index] = s.area;
                current_cell_index += 1;
                cell.count += 1;
            }
            span = s.next;
        }
    }

    // Find neighbor connections
    const MAX_LAYERS = NOT_CONNECTED - 1;
    var max_layer_index: i32 = 0;
    const z_stride = x_size; // for readability

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = compact_hf.cells[cell_idx];

            var i: usize = cell.index;
            const ni = cell.index + cell.count;
            while (i < ni) : (i += 1) {
                const span = &compact_hf.spans[i];

                // Span extents are invariant across the dir/neighbor loops; hoist
                // them to i32 (matching upstream's int promotion of span.y/span.h)
                // so the inner test is pure signed-int arithmetic — no per-neighbor
                // re-read of the packed span and no unsigned-underflow guard.
                const span_y: i32 = span.y;
                const span_top: i32 = span_y + span.h;

                // Accumulate the 4 direction codes in a local u24 and write `con`
                // ONCE after the loop. The per-direction setCon form does up to two
                // read-modify-write cycles per direction on the packed backing word
                // (8 RMWs/span); building con locally and storing once is a single
                // masked store. Every slot starts at NOT_CONNECTED so unmatched
                // directions keep the exact bits the old code wrote — output-identical.
                var con_acc: u24 = ALL_DIRS_NOT_CONNECTED;

                // Check all 4 directions
                var dir: u3 = 0;
                while (dir < 4) : (dir += 1) {
                    const dir_u2: u2 = @intCast(dir);

                    const neighbor_x = x + heightfield_mod.getDirOffsetX(dir_u2);
                    const neighbor_z = z + heightfield_mod.getDirOffsetY(dir_u2);

                    // First check that the neighbor cell is in bounds
                    if (neighbor_x < 0 or neighbor_z < 0 or neighbor_x >= x_size or neighbor_z >= z_size) {
                        continue;
                    }

                    // Iterate over all neighbor spans and check if any is accessible from current cell
                    const neighbor_cell_idx = @as(usize, @intCast(neighbor_x + neighbor_z * z_stride));
                    const neighbor_cell = compact_hf.cells[neighbor_cell_idx];

                    const k0: usize = neighbor_cell.index;
                    const nk = k0 + neighbor_cell.count;
                    var k: usize = k0;
                    while (k < nk) : (k += 1) {
                        // Reference (not a value copy) into the packed span array,
                        // mirroring upstream `const rcCompactSpan& neighborSpan`.
                        const neighbor_span = &compact_hf.spans[k];
                        const ny: i32 = neighbor_span.y;

                        const bot = @max(span_y, ny);
                        const top = @min(span_top, ny + neighbor_span.h);

                        // Check that the gap between the spans is walkable,
                        // and that the climb height between the gaps is not too high.
                        // (top - bot) is signed here, so the upstream test needs no
                        // separate top>=bot guard.
                        if ((top - bot) >= walkable_height and
                            @abs(ny - span_y) <= walkable_climb)
                        {
                            // Mark direction as walkable
                            const layer_index: i32 = @as(i32, @intCast(k - k0));
                            if (layer_index < 0 or layer_index > MAX_LAYERS) {
                                max_layer_index = @max(max_layer_index, layer_index);
                                continue;
                            }
                            const shift: u5 = @as(u5, dir) * 6;
                            const mask: u24 = @as(u24, 0x3f) << shift;
                            con_acc = (con_acc & ~mask) |
                                (@as(u24, @as(u6, @intCast(layer_index))) << shift);
                            break;
                        }
                    }
                }
                span.con = con_acc;
            }
        }
    }

    if (max_layer_index > MAX_LAYERS) {
        ctx.log(.err, "buildCompactHeightfield: Heightfield has too many layers {d} (max: {d})", .{ max_layer_index, MAX_LAYERS });
    }
}

// Tests
test "getHeightFieldSpanCount" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        10,
        10,
        Vec3.init(0, 0, 0),
        Vec3.init(10, 10, 10),
        1.0,
        0.5,
    );
    defer hf.deinit();

    // Add some walkable spans
    const x: i32 = 5;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 10));

    const span1 = try hf.allocator.create(Span);
    span1.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    const span2 = try hf.allocator.create(Span);
    span2.* = .{
        .smin = 20,
        .smax = 30,
        .area = 1, // Walkable
        .next = null,
    };

    const span3 = try hf.allocator.create(Span);
    span3.* = .{
        .smin = 40,
        .smax = 50,
        .area = 0, // Not walkable
        .next = null,
    };

    span1.next = span2;
    span2.next = span3;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    const count = getHeightFieldSpanCount(&ctx, &hf);

    // Should count only walkable spans
    try std.testing.expectEqual(@as(usize, 2), count);

    // Clean up manually allocated spans
    allocator.destroy(span3);
    allocator.destroy(span2);
    allocator.destroy(span1);
}

test "buildCompactHeightfield - simple grid" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        5,
        5,
        Vec3.init(0, 0, 0),
        Vec3.init(5, 5, 5),
        1.0,
        0.5,
    );
    defer hf.deinit();

    // Create a simple 3x3 grid of walkable spans
    var z: i32 = 1;
    while (z <= 3) : (z += 1) {
        var x: i32 = 1;
        while (x <= 3) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * 5));
            const span = try hf.allocator.create(Span);
            span.* = .{
                .smin = 0,
                .smax = 10,
                .area = 1,
                .next = null,
            };
            hf.spans[col_idx] = span;
        }
    }

    // Create empty compact heightfield (buildCompactHeightfield will fill it in)
    var chf = CompactHeightfield{
        .width = 0,
        .height = 0,
        .span_count = 0,
        .walkable_height = 0,
        .walkable_climb = 0,
        .border_size = 0,
        .max_distance = 0,
        .max_regions = 0,
        .bmin = Vec3.init(0, 0, 0),
        .bmax = Vec3.init(0, 0, 0),
        .cs = 0,
        .ch = 0,
        .cells = &[_]CompactCell{},
        .spans = &[_]CompactSpan{},
        .dist = &[_]u16{},
        .areas = &[_]u8{},
        .allocator = allocator,
    };
    defer chf.deinit();

    const ctx = Context.init(allocator);
    try buildCompactHeightfield(&ctx, 5, 2, &hf, &chf);

    // Check basic properties
    try std.testing.expectEqual(@as(i32, 5), chf.width);
    try std.testing.expectEqual(@as(i32, 5), chf.height);
    try std.testing.expectEqual(@as(i32, 9), chf.span_count);

    // Check that center span has connections to all 4 neighbors
    const center_cell_idx = @as(usize, @intCast(2 + 2 * 5));
    const center_cell = chf.cells[center_cell_idx];
    try std.testing.expect(center_cell.count > 0);

    const center_span_idx = center_cell.index;
    const center_span = chf.spans[center_span_idx];

    // Center should be connected in all 4 directions
    try std.testing.expect(center_span.getCon(0) != NOT_CONNECTED); // West
    try std.testing.expect(center_span.getCon(1) != NOT_CONNECTED); // South
    try std.testing.expect(center_span.getCon(2) != NOT_CONNECTED); // East
    try std.testing.expect(center_span.getCon(3) != NOT_CONNECTED); // North

    // Clean up manually allocated spans
    z = 1;
    while (z <= 3) : (z += 1) {
        var x: i32 = 1;
        while (x <= 3) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * 5));
            if (hf.spans[col_idx]) |span| {
                allocator.destroy(span);
            }
        }
    }
}
