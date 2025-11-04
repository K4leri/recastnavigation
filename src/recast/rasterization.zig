const std = @import("std");
const math = @import("../math.zig");
const heightfield_mod = @import("heightfield.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const Heightfield = heightfield_mod.Heightfield;
const Span = heightfield_mod.Span;
const SPAN_MAX_HEIGHT = config.SPAN_MAX_HEIGHT;

/// Axis for polygon division
const Axis = enum(u8) {
    x = 0,
    y = 1,
    z = 2,
};

/// Check whether two bounding boxes overlap
fn overlapBounds(amin: Vec3, amax: Vec3, bmin: Vec3, bmax: Vec3) bool {
    return amin.x <= bmax.x and amax.x >= bmin.x and
        amin.y <= bmax.y and amax.y >= bmin.y and
        amin.z <= bmax.z and amax.z >= bmin.z;
}

/// Adds a span to the heightfield. If the new span overlaps existing spans,
/// it will merge the new span with the existing ones.
pub fn addSpan(
    heightfield: *Heightfield,
    x: i32,
    z: i32,
    smin: u16,
    smax: u16,
    area_id: u8,
    flag_merge_threshold: i32,
) !bool {
    // Create the new span
    var new_span = try heightfield.allocSpan();
    new_span.smin = smin;
    new_span.smax = smax;
    new_span.area = area_id;
    new_span.next = null;

    const column_index = @as(usize, @intCast(x + z * heightfield.width));
    var previous_span: ?*heightfield_mod.Span = null;
    var current_span = heightfield.spans[column_index];

    // Insert the new span, possibly merging it with existing spans
    while (current_span) |curr| {
        if (curr.smin > new_span.smax) {
            // Current span is completely after the new span, break
            break;
        }

        if (curr.smax < new_span.smin) {
            // Current span is completely before the new span. Keep going.
            previous_span = curr;
            current_span = curr.next;
        } else {
            // The new span overlaps with an existing span. Merge them.
            if (curr.smin < new_span.smin) {
                new_span.smin = curr.smin;
            }
            if (curr.smax > new_span.smax) {
                new_span.smax = curr.smax;
            }

            // Merge flags
            if (@abs(@as(i32, new_span.smax) - @as(i32, curr.smax)) <= flag_merge_threshold) {
                // Higher area ID numbers indicate higher resolution priority
                new_span.area = @max(new_span.area, curr.area);
            }

            // Remove the current span since it's now merged with newSpan
            const next = curr.next;
            heightfield.freeSpan(curr);
            if (previous_span) |prev| {
                prev.next = next;
            } else {
                heightfield.spans[column_index] = next;
            }
            current_span = next;
        }
    }

    // Insert new span after prev
    if (previous_span) |prev| {
        new_span.next = prev.next;
        prev.next = new_span;
    } else {
        // This span should go before the others in the list
        new_span.next = heightfield.spans[column_index];
        heightfield.spans[column_index] = new_span;
    }

    return true;
}

/// Divides a convex polygon of max 12 vertices into two convex polygons
/// across a separating axis.
pub fn dividePoly(
    in_verts: []const f32,
    in_verts_count: usize,
    out_verts1: []f32,
    out_verts2: []f32,
    axis_offset: f32,
    axis: Axis,
) struct { count1: usize, count2: usize } {
    std.debug.assert(in_verts_count <= 12);

    // Handle empty polygon case to avoid integer underflow
    if (in_verts_count == 0) {
        return .{ .count1 = 0, .count2 = 0 };
    }

    // How far positive or negative away from the separating axis is each vertex
    var in_vert_axis_delta: [12]f32 = undefined;
    for (0..in_verts_count) |i| {
        in_vert_axis_delta[i] = axis_offset - in_verts[i * 3 + @intFromEnum(axis)];
    }

    var poly1_vert: usize = 0;
    var poly2_vert: usize = 0;
    var in_vert_b: usize = in_verts_count - 1;

    for (0..in_verts_count) |in_vert_a| {
        defer in_vert_b = in_vert_a;

        // If the two vertices are on the same side of the separating axis
        const same_side = (in_vert_axis_delta[in_vert_a] >= 0) == (in_vert_axis_delta[in_vert_b] >= 0);

        if (!same_side) {
            const s = in_vert_axis_delta[in_vert_b] / (in_vert_axis_delta[in_vert_b] - in_vert_axis_delta[in_vert_a]);

            // Only create intersection if it's not at vertex position (avoid duplicates when delta=0)
            if (in_vert_axis_delta[in_vert_a] != 0 and in_vert_axis_delta[in_vert_b] != 0) {
                // Interpolate intersection point
                for (0..3) |j| {
                    const val = in_verts[in_vert_b * 3 + j] + (in_verts[in_vert_a * 3 + j] - in_verts[in_vert_b * 3 + j]) * s;
                    out_verts1[poly1_vert * 3 + j] = val;
                    out_verts2[poly2_vert * 3 + j] = val;
                }
                poly1_vert += 1;
                poly2_vert += 1;
            }

            // Add the inVertA point to the right polygon. Do NOT add points that are on the dividing line
            if (in_vert_axis_delta[in_vert_a] > 0) {
                @memcpy(out_verts1[poly1_vert * 3 .. poly1_vert * 3 + 3], in_verts[in_vert_a * 3 .. in_vert_a * 3 + 3]);
                poly1_vert += 1;
            } else if (in_vert_axis_delta[in_vert_a] < 0) {
                @memcpy(out_verts2[poly2_vert * 3 .. poly2_vert * 3 + 3], in_verts[in_vert_a * 3 .. in_vert_a * 3 + 3]);
                poly2_vert += 1;
            }
        } else {
            // Add the inVertA point to the right polygon
            if (in_vert_axis_delta[in_vert_a] >= 0) {
                @memcpy(out_verts1[poly1_vert * 3 .. poly1_vert * 3 + 3], in_verts[in_vert_a * 3 .. in_vert_a * 3 + 3]);
                poly1_vert += 1;
                // If delta = 0, vertex is on dividing line - add to polygon 2 as well
                if (in_vert_axis_delta[in_vert_a] == 0) {
                    @memcpy(out_verts2[poly2_vert * 3 .. poly2_vert * 3 + 3], in_verts[in_vert_a * 3 .. in_vert_a * 3 + 3]);
                    poly2_vert += 1;
                }
                continue;
            }
            @memcpy(out_verts2[poly2_vert * 3 .. poly2_vert * 3 + 3], in_verts[in_vert_a * 3 .. in_vert_a * 3 + 3]);
            poly2_vert += 1;
        }
    }

    return .{ .count1 = poly1_vert, .count2 = poly2_vert };
}

/// Rasterize a single triangle to the heightfield.
/// This code is extremely hot, so much care should be given to maintaining maximum perf here.
fn rasterizeTri(
    v0: Vec3,
    v1: Vec3,
    v2: Vec3,
    area_id: u8,
    heightfield: *Heightfield,
    heightfield_bb_min: Vec3,
    heightfield_bb_max: Vec3,
    cell_size: f32,
    inverse_cell_size: f32,
    inverse_cell_height: f32,
    flag_merge_threshold: i32,
) !bool {
    // Calculate the bounding box of the triangle
    var tri_bb_min = v0;
    tri_bb_min = tri_bb_min.min(v1);
    tri_bb_min = tri_bb_min.min(v2);

    var tri_bb_max = v0;
    tri_bb_max = tri_bb_max.max(v1);
    tri_bb_max = tri_bb_max.max(v2);

    // If the triangle does not touch the bounding box of the heightfield, skip
    if (!overlapBounds(tri_bb_min, tri_bb_max, heightfield_bb_min, heightfield_bb_max)) {
        return true;
    }

    const w = heightfield.width;
    const h = heightfield.height;
    const by = heightfield_bb_max.y - heightfield_bb_min.y;

    // Calculate the footprint of the triangle on the grid's z-axis.
    // Use @floor for consistent rounding between adjacent tiles, especially when
    // triangle vertices lie just outside the tile boundary in (-1.0, 0.0).
    // See: https://github.com/recastnavigation/recastnavigation/pull/766
    var z0 = @as(i32, @intFromFloat(@floor((tri_bb_min.z - heightfield_bb_min.z) * inverse_cell_size)));
    var z1 = @as(i32, @intFromFloat(@floor((tri_bb_max.z - heightfield_bb_min.z) * inverse_cell_size)));

    // Use -1 rather than 0 to cut the polygon properly at the start of the tile
    z0 = math.clamp(i32, z0, -1, h - 1);
    z1 = math.clamp(i32, z1, 0, h - 1);

    // Clip the triangle into all grid cells it touches
    var buf: [7 * 3 * 4]f32 = undefined;
    var in = buf[0 .. 7 * 3];
    var in_row = buf[7 * 3 .. 7 * 3 * 2];
    var p1 = buf[7 * 3 * 2 .. 7 * 3 * 3];
    var p2 = buf[7 * 3 * 3 .. 7 * 3 * 4];

    // Copy triangle vertices
    @memcpy(in[0..3], &v0.toArray());
    @memcpy(in[3..6], &v1.toArray());
    @memcpy(in[6..9], &v2.toArray());
    var nv_in: usize = 3;

    var z = z0;
    while (z <= z1) : (z += 1) {
        // Clip polygon to row. Store the remaining polygon as well
        const cell_z = heightfield_bb_min.z + @as(f32, @floatFromInt(z)) * cell_size;
        const result = dividePoly(in[0 .. nv_in * 3], nv_in, in_row, p1, cell_z + cell_size, .z);
        const nv_row = result.count1;
        nv_in = result.count2;

        // Swap in and p1
        const temp = in;
        in = p1;
        p1 = temp;

        if (nv_row < 3 or z < 0) {
            continue;
        }

        // Find X-axis bounds of the row
        var min_x = in_row[0];
        var max_x = in_row[0];
        for (1..nv_row) |vert| {
            min_x = @min(min_x, in_row[vert * 3]);
            max_x = @max(max_x, in_row[vert * 3]);
        }

        // Fix from PR #766: Use @floor for consistent rounding between adjacent tiles
        // Issue #765: @intFromFloat does truncation towards zero, causing inconsistencies
        // when coordinates are in range (-1.0, 0.0). floor() ensures proper cell indexing.
        var x0 = @as(i32, @intFromFloat(@floor((min_x - heightfield_bb_min.x) * inverse_cell_size)));
        var x1 = @as(i32, @intFromFloat(@floor((max_x - heightfield_bb_min.x) * inverse_cell_size)));
        if (x1 < 0 or x0 >= w) {
            continue;
        }
        x0 = math.clamp(i32, x0, -1, w - 1);
        x1 = math.clamp(i32, x1, 0, w - 1);

        var nv2 = nv_row;

        var x = x0;
        while (x <= x1) : (x += 1) {
            // Clip polygon to column. Store the remaining polygon as well
            const cx = heightfield_bb_min.x + @as(f32, @floatFromInt(x)) * cell_size;
            const result2 = dividePoly(in_row[0 .. nv2 * 3], nv2, p1, p2, cx + cell_size, .x);
            const nv = result2.count1;
            nv2 = result2.count2;

            // Swap inRow and p2
            const temp2 = in_row;
            in_row = p2;
            p2 = temp2;

            if (nv < 3 or x < 0) {
                continue;
            }

            // Calculate min and max of the span
            var span_min = p1[1];
            var span_max = p1[1];
            for (1..nv) |vert| {
                span_min = @min(span_min, p1[vert * 3 + 1]);
                span_max = @max(span_max, p1[vert * 3 + 1]);
            }
            span_min -= heightfield_bb_min.y;
            span_max -= heightfield_bb_min.y;

            // Skip the span if it's completely outside the heightfield bounding box
            if (span_max < 0.0 or span_min > by) {
                continue;
            }

            // Clamp the span to the heightfield bounding box
            if (span_min < 0.0) {
                span_min = 0;
            }
            if (span_max > by) {
                span_max = by;
            }

            // Snap the span to the heightfield height grid
            const span_min_cell_index: u16 = @intCast(math.clamp(
                i32,
                @as(i32, @intFromFloat(@floor(span_min * inverse_cell_height))),
                0,
                SPAN_MAX_HEIGHT,
            ));
            const span_max_cell_index: u16 = @intCast(math.clamp(
                i32,
                @as(i32, @intFromFloat(@ceil(span_max * inverse_cell_height))),
                @as(i32, span_min_cell_index) + 1,
                SPAN_MAX_HEIGHT,
            ));

            if (!try addSpan(heightfield, x, z, span_min_cell_index, span_max_cell_index, area_id, flag_merge_threshold)) {
                return false;
            }
        }
    }

    return true;
}

/// Rasterize a single triangle to the heightfield.
pub fn rasterizeTriangle(
    ctx: *const Context,
    v0: Vec3,
    v1: Vec3,
    v2: Vec3,
    area_id: u8,
    heightfield: *Heightfield,
    flag_merge_threshold: i32,
) !void {
    // const timer = ctx.startTimer(.rasterize_triangles);
    // defer ctx.stopTimer(.rasterize_triangles);

    const inverse_cell_size = 1.0 / heightfield.cs;
    const inverse_cell_height = 1.0 / heightfield.ch;

    if (!try rasterizeTri(
        v0,
        v1,
        v2,
        area_id,
        heightfield,
        heightfield.bmin,
        heightfield.bmax,
        heightfield.cs,
        inverse_cell_size,
        inverse_cell_height,
        flag_merge_threshold,
    )) {
        ctx.log(.err, "rasterizeTriangle: Out of memory.", .{});
        return error.OutOfMemory;
    }
}

/// Rasterize triangles with i32 indices
pub fn rasterizeTriangles(
    ctx: *const Context,
    verts: []const f32,
    tris: []const i32,
    tri_area_ids: []const u8,
    heightfield: *Heightfield,
    flag_merge_threshold: i32,
) !void {
    // const timer = ctx.startTimer(.rasterize_triangles);
    // defer ctx.stopTimer(.rasterize_triangles);

    const num_tris = @divExact(tris.len, 3);
    std.debug.assert(tri_area_ids.len == num_tris);

    const inverse_cell_size = 1.0 / heightfield.cs;
    const inverse_cell_height = 1.0 / heightfield.ch;

    for (0..num_tris) |tri_index| {
        const v0_idx = @as(usize, @intCast(tris[tri_index * 3 + 0]));
        const v1_idx = @as(usize, @intCast(tris[tri_index * 3 + 1]));
        const v2_idx = @as(usize, @intCast(tris[tri_index * 3 + 2]));

        const v0 = Vec3.init(verts[v0_idx * 3], verts[v0_idx * 3 + 1], verts[v0_idx * 3 + 2]);
        const v1 = Vec3.init(verts[v1_idx * 3], verts[v1_idx * 3 + 1], verts[v1_idx * 3 + 2]);
        const v2 = Vec3.init(verts[v2_idx * 3], verts[v2_idx * 3 + 1], verts[v2_idx * 3 + 2]);

        if (!try rasterizeTri(
            v0,
            v1,
            v2,
            tri_area_ids[tri_index],
            heightfield,
            heightfield.bmin,
            heightfield.bmax,
            heightfield.cs,
            inverse_cell_size,
            inverse_cell_height,
            flag_merge_threshold,
        )) {
            ctx.log(.err, "rasterizeTriangles: Out of memory.", .{});
            return error.OutOfMemory;
        }
    }
}

/// Rasterize triangles with u16 indices
pub fn rasterizeTrianglesU16(
    ctx: *const Context,
    verts: []const f32,
    tris: []const u16,
    tri_area_ids: []const u8,
    heightfield: *Heightfield,
    flag_merge_threshold: i32,
) !void {
    // const timer = ctx.startTimer(.rasterize_triangles);
    // defer ctx.stopTimer(.rasterize_triangles);

    const num_tris = @divExact(tris.len, 3);
    std.debug.assert(tri_area_ids.len == num_tris);

    const inverse_cell_size = 1.0 / heightfield.cs;
    const inverse_cell_height = 1.0 / heightfield.ch;

    for (0..num_tris) |tri_index| {
        const v0_idx = tris[tri_index * 3 + 0];
        const v1_idx = tris[tri_index * 3 + 1];
        const v2_idx = tris[tri_index * 3 + 2];

        const v0 = Vec3.init(verts[v0_idx * 3], verts[v0_idx * 3 + 1], verts[v0_idx * 3 + 2]);
        const v1 = Vec3.init(verts[v1_idx * 3], verts[v1_idx * 3 + 1], verts[v1_idx * 3 + 2]);
        const v2 = Vec3.init(verts[v2_idx * 3], verts[v2_idx * 3 + 1], verts[v2_idx * 3 + 2]);

        if (!try rasterizeTri(
            v0,
            v1,
            v2,
            tri_area_ids[tri_index],
            heightfield,
            heightfield.bmin,
            heightfield.bmax,
            heightfield.cs,
            inverse_cell_size,
            inverse_cell_height,
            flag_merge_threshold,
        )) {
            ctx.log(.err, "rasterizeTriangles: Out of memory.", .{});
            return error.OutOfMemory;
        }
    }
}

/// Rasterize triangles from flat vertex array (3 verts per triangle)
pub fn rasterizeTrianglesFlat(
    ctx: *const Context,
    verts: []const f32,
    tri_area_ids: []const u8,
    heightfield: *Heightfield,
    flag_merge_threshold: i32,
) !void {
    // const timer = ctx.startTimer(.rasterize_triangles);
    // defer ctx.stopTimer(.rasterize_triangles);

    const num_tris = @divExact(verts.len, 9); // 3 verts * 3 components
    std.debug.assert(tri_area_ids.len == num_tris);

    const inverse_cell_size = 1.0 / heightfield.cs;
    const inverse_cell_height = 1.0 / heightfield.ch;

    for (0..num_tris) |tri_index| {
        const base = (tri_index * 3) * 3;
        const v0 = Vec3.init(verts[base + 0], verts[base + 1], verts[base + 2]);
        const v1 = Vec3.init(verts[base + 3], verts[base + 4], verts[base + 5]);
        const v2 = Vec3.init(verts[base + 6], verts[base + 7], verts[base + 8]);

        if (!try rasterizeTri(
            v0,
            v1,
            v2,
            tri_area_ids[tri_index],
            heightfield,
            heightfield.bmin,
            heightfield.bmax,
            heightfield.cs,
            inverse_cell_size,
            inverse_cell_height,
            flag_merge_threshold,
        )) {
            ctx.log(.err, "rasterizeTriangles: Out of memory.", .{});
            return error.OutOfMemory;
        }
    }
}

// Tests
test "overlapBounds" {
    const a_min = Vec3.init(0, 0, 0);
    const a_max = Vec3.init(10, 10, 10);
    const b_min = Vec3.init(5, 5, 5);
    const b_max = Vec3.init(15, 15, 15);

    try std.testing.expect(overlapBounds(a_min, a_max, b_min, b_max));

    const c_min = Vec3.init(20, 20, 20);
    const c_max = Vec3.init(30, 30, 30);
    try std.testing.expect(!overlapBounds(a_min, a_max, c_min, c_max));
}

test "dividePoly simple" {
    var in_verts = [_]f32{
        0,  0, 0,
        10, 0, 0,
        10, 0, 10,
        0,  0, 10,
    };
    var out1: [7 * 3]f32 = undefined;
    var out2: [7 * 3]f32 = undefined;

    const result = dividePoly(&in_verts, 4, &out1, &out2, 5.0, .x);

    try std.testing.expect(result.count1 > 0);
    try std.testing.expect(result.count2 > 0);
}

test "rasterizeTriangle basic" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        32,
        32,
        Vec3.init(0, 0, 0),
        Vec3.init(32, 10, 32),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    const v0 = Vec3.init(5, 0, 5);
    const v1 = Vec3.init(10, 2, 5);
    const v2 = Vec3.init(5, 0, 10);

    try rasterizeTriangle(&ctx, v0, v1, v2, 1, &hf, 1);

    // Should have created some spans
    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterizeTriangle - overlapping bb but non-overlapping triangle" {
    // Minimal repro case for issue #476
    // Triangle outside heightfield should not create any spans
    const allocator = std.testing.allocator;

    const cell_size: f32 = 1.0;
    const cell_height: f32 = 1.0;
    const width: i32 = 10;
    const height: i32 = 10;
    const bmin = Vec3.init(0, 0, 0);
    const bmax = Vec3.init(10, 10, 10);

    var hf = try Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cell_size,
        cell_height,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Triangle outside of the heightfield
    const v0 = Vec3.init(-10.0, 5.5, -10.0);
    const v1 = Vec3.init(-10.0, 5.5, 3.0);
    const v2 = Vec3.init(3.0, 5.5, -10.0);

    const area: u8 = 42;
    const flag_merge_thr: i32 = 1;

    try rasterizeTriangle(&ctx, v0, v1, v2, area, &hf, flag_merge_thr);

    // Ensure that no spans were created
    for (0..@intCast(width)) |x| {
        for (0..@intCast(height)) |z| {
            const idx = x + z * @as(usize, @intCast(width));
            const span = hf.spans[idx];
            try std.testing.expectEqual(@as(?*Span, null), span);
        }
    }
}

test "rasterizeTriangle - skinny triangle along x axis" {
    // Triangle smaller than half voxel should not crash
    const allocator = std.testing.allocator;
    const config_mod = @import("config.zig");

    const verts = [_]Vec3{
        Vec3.init(5.0, 0.0, 0.005),
        Vec3.init(5.0, 0.0, -0.005),
        Vec3.init(-5.0, 0.0, 0.005),
    };

    var bmin: Vec3 = undefined;
    var bmax: Vec3 = undefined;
    config_mod.Config.calcBounds(&verts, &bmin, &bmax);

    const cell_size: f32 = 1.0;
    const cell_height: f32 = 1.0;

    var width: i32 = undefined;
    var height: i32 = undefined;
    config_mod.Config.calcGridSize(bmin, bmax, cell_size, &width, &height);

    var hf = try Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cell_size,
        cell_height,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Should not crash
    try rasterizeTriangle(&ctx, verts[0], verts[1], verts[2], 42, &hf, 1);
}

test "rasterizeTriangle - skinny triangle along z axis" {
    // Triangle smaller than half voxel should not crash
    const allocator = std.testing.allocator;
    const config_mod = @import("config.zig");

    const verts = [_]Vec3{
        Vec3.init(0.005, 0.0, 5.0),
        Vec3.init(-0.005, 0.0, 5.0),
        Vec3.init(0.005, 0.0, -5.0),
    };

    var bmin: Vec3 = undefined;
    var bmax: Vec3 = undefined;
    config_mod.Config.calcBounds(&verts, &bmin, &bmax);

    const cell_size: f32 = 1.0;
    const cell_height: f32 = 1.0;

    var width: i32 = undefined;
    var height: i32 = undefined;
    config_mod.Config.calcGridSize(bmin, bmax, cell_size, &width, &height);

    var hf = try Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cell_size,
        cell_height,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Should not crash
    try rasterizeTriangle(&ctx, verts[0], verts[1], verts[2], 42, &hf, 1);
}
