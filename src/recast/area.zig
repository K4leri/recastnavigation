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
const EPSILON: f32 = 1e-6;

/// Sorts the given data in-place using insertion sort.
fn insertSort(data: []u8) void {
    for (1..data.len) |value_idx| {
        const value = data[value_idx];
        var insert_idx: isize = @intCast(value_idx - 1);

        while (insert_idx >= 0 and data[@intCast(insert_idx)] > value) : (insert_idx -= 1) {
            // Shift over values
            data[@intCast(insert_idx + 1)] = data[@intCast(insert_idx)];
        }

        // Insert the value in sorted order
        data[@intCast(insert_idx + 1)] = value;
    }
}

/// Checks if a point is contained within a polygon (2D XZ plane)
fn pointInPoly(num_verts: usize, verts: []const f32, point: Vec3) bool {
    var in_poly = false;
    var i: usize = 0;
    var j: usize = num_verts - 1;

    while (i < num_verts) : ({i += 1; j = i - 1;}) {
        const vi_idx = i * 3;
        const vj_idx = j * 3;

        const vi_x = verts[vi_idx];
        const vi_z = verts[vi_idx + 2];
        const vj_x = verts[vj_idx];
        const vj_z = verts[vj_idx + 2];

        if ((vi_z > point.z) == (vj_z > point.z)) {
            continue;
        }

        if (point.x >= (vj_x - vi_x) * (point.z - vi_z) / (vj_z - vi_z) + vi_x) {
            continue;
        }

        in_poly = !in_poly;
    }

    return in_poly;
}

/// Normalizes the vector if the length is greater than zero.
fn vsafeNormalize(v: *Vec3) void {
    const sq_mag = v.x * v.x + v.y * v.y + v.z * v.z;
    if (sq_mag > EPSILON) {
        const inv_mag = 1.0 / @sqrt(sq_mag);
        v.x *= inv_mag;
        v.y *= inv_mag;
        v.z *= inv_mag;
    }
}

/// Erodes the walkable area within the heightfield by the specified radius.
///
/// This removes walkable spans that are too close to boundaries, making the
/// navigation mesh safer by adding a buffer around obstacles.
pub fn erodeWalkableArea(
    ctx: *const Context,
    erosion_radius: i32,
    chf: *CompactHeightfield,
    allocator: std.mem.Allocator,
) !void {
    _ = ctx; // TODO: timer
    // const timer = ctx.startTimer(.erode_area);
    // defer timer.stop();

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Allocate distance buffer
    const dist = try allocator.alloc(u8, @intCast(chf.span_count));
    defer allocator.free(dist);
    @memset(dist, 0xff);

    // Mark boundary cells
    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                if (chf.areas[span_idx] == NULL_AREA) {
                    dist[span_idx] = 0;
                    continue;
                }

                const span = chf.spans[span_idx];

                // Check that there is a non-null adjacent span in each of the 4 cardinal directions
                var neighbor_count: u32 = 0;
                var dir: u2 = 0;
                while (dir < 4) : (dir += 1) {
                    const neighbor_con = span.getCon(dir);
                    if (neighbor_con == NOT_CONNECTED) {
                        break;
                    }

                    const neighbor_x = x + heightfield_mod.getDirOffsetX(dir);
                    const neighbor_z = z + heightfield_mod.getDirOffsetY(dir);
                    const neighbor_cell_idx = @as(usize, @intCast(neighbor_x + neighbor_z * z_stride));
                    const neighbor_span_idx = chf.cells[neighbor_cell_idx].index + neighbor_con;

                    if (chf.areas[neighbor_span_idx] == NULL_AREA) {
                        break;
                    }
                    neighbor_count += 1;
                }

                // At least one missing neighbour, so this is a boundary cell
                if (neighbor_count != 4) {
                    dist[span_idx] = 0;
                }
            }
        }
    }

    // Pass 1 - forward sweep
    z = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                // (-1, 0)
                if (span.getCon(0) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(0);
                    const ay = z + heightfield_mod.getDirOffsetY(0);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * x_size))].index + span.getCon(0)));
                    const a_span = chf.spans[ai];
                    var new_dist = @min(@as(u32, dist[ai]) + 2, 255);
                    if (new_dist < dist[span_idx]) {
                        dist[span_idx] = @intCast(new_dist);
                    }

                    // (-1, -1)
                    if (a_span.getCon(3) != NOT_CONNECTED) {
                        const bx = ax + heightfield_mod.getDirOffsetX(3);
                        const by = ay + heightfield_mod.getDirOffsetY(3);
                        const bi = @as(usize, @intCast(chf.cells[@as(usize, @intCast(bx + by * x_size))].index + a_span.getCon(3)));
                        new_dist = @min(@as(u32, dist[bi]) + 3, 255);
                        if (new_dist < dist[span_idx]) {
                            dist[span_idx] = @intCast(new_dist);
                        }
                    }
                }

                // (0, -1)
                if (span.getCon(3) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(3);
                    const ay = z + heightfield_mod.getDirOffsetY(3);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * x_size))].index + span.getCon(3)));
                    const a_span = chf.spans[ai];
                    var new_dist = @min(@as(u32, dist[ai]) + 2, 255);
                    if (new_dist < dist[span_idx]) {
                        dist[span_idx] = @intCast(new_dist);
                    }

                    // (1, -1)
                    if (a_span.getCon(2) != NOT_CONNECTED) {
                        const bx = ax + heightfield_mod.getDirOffsetX(2);
                        const by = ay + heightfield_mod.getDirOffsetY(2);
                        const bi = @as(usize, @intCast(chf.cells[@as(usize, @intCast(bx + by * x_size))].index + a_span.getCon(2)));
                        new_dist = @min(@as(u32, dist[bi]) + 3, 255);
                        if (new_dist < dist[span_idx]) {
                            dist[span_idx] = @intCast(new_dist);
                        }
                    }
                }
            }
        }
    }

    // Pass 2 - backward sweep
    z = z_size - 1;
    while (z >= 0) : (z -= 1) {
        var x: i32 = x_size - 1;
        while (x >= 0) : (x -= 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                // (1, 0)
                if (span.getCon(2) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(2);
                    const ay = z + heightfield_mod.getDirOffsetY(2);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * x_size))].index + span.getCon(2)));
                    const a_span = chf.spans[ai];
                    var new_dist = @min(@as(u32, dist[ai]) + 2, 255);
                    if (new_dist < dist[span_idx]) {
                        dist[span_idx] = @intCast(new_dist);
                    }

                    // (1, 1)
                    if (a_span.getCon(1) != NOT_CONNECTED) {
                        const bx = ax + heightfield_mod.getDirOffsetX(1);
                        const by = ay + heightfield_mod.getDirOffsetY(1);
                        const bi = @as(usize, @intCast(chf.cells[@as(usize, @intCast(bx + by * x_size))].index + a_span.getCon(1)));
                        new_dist = @min(@as(u32, dist[bi]) + 3, 255);
                        if (new_dist < dist[span_idx]) {
                            dist[span_idx] = @intCast(new_dist);
                        }
                    }
                }

                // (0, 1)
                if (span.getCon(1) != NOT_CONNECTED) {
                    const ax = x + heightfield_mod.getDirOffsetX(1);
                    const ay = z + heightfield_mod.getDirOffsetY(1);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + ay * x_size))].index + span.getCon(1)));
                    const a_span = chf.spans[ai];
                    var new_dist = @min(@as(u32, dist[ai]) + 2, 255);
                    if (new_dist < dist[span_idx]) {
                        dist[span_idx] = @intCast(new_dist);
                    }

                    // (-1, 1)
                    if (a_span.getCon(0) != NOT_CONNECTED) {
                        const bx = ax + heightfield_mod.getDirOffsetX(0);
                        const by = ay + heightfield_mod.getDirOffsetY(0);
                        const bi = @as(usize, @intCast(chf.cells[@as(usize, @intCast(bx + by * x_size))].index + a_span.getCon(0)));
                        new_dist = @min(@as(u32, dist[bi]) + 3, 255);
                        if (new_dist < dist[span_idx]) {
                            dist[span_idx] = @intCast(new_dist);
                        }
                    }
                }
            }
        }
    }

    // Mark areas with insufficient distance as NULL_AREA
    const min_boundary_dist: u8 = @intCast(erosion_radius * 2);
    for (0..@intCast(chf.span_count)) |i| {
        if (dist[i] < min_boundary_dist) {
            chf.areas[i] = NULL_AREA;
        }
    }
}

/// Applies a median filter to walkable area assignments.
///
/// This smooths the area assignments by taking the median of a span and its neighbors.
pub fn medianFilterWalkableArea(
    ctx: *const Context,
    chf: *CompactHeightfield,
    allocator: std.mem.Allocator,
) !void {
    _ = ctx; // TODO: timer

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    const areas = try allocator.alloc(u8, @intCast(chf.span_count));
    defer allocator.free(areas);
    @memset(areas, 0xff);

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                if (chf.areas[span_idx] == NULL_AREA) {
                    areas[span_idx] = chf.areas[span_idx];
                    continue;
                }

                var neighbor_areas: [9]u8 = undefined;
                for (0..9) |i| {
                    neighbor_areas[i] = chf.areas[span_idx];
                }

                var dir: u2 = 0;
                while (dir < 4) : (dir += 1) {
                    if (span.getCon(dir) == NOT_CONNECTED) {
                        continue;
                    }

                    const ax = x + heightfield_mod.getDirOffsetX(dir);
                    const az = z + heightfield_mod.getDirOffsetY(dir);
                    const ai = @as(usize, @intCast(chf.cells[@as(usize, @intCast(ax + az * z_stride))].index + span.getCon(dir)));

                    if (chf.areas[ai] != NULL_AREA) {
                        neighbor_areas[dir * 2 + 0] = chf.areas[ai];
                    }

                    const a_span = chf.spans[ai];
                    const dir2: u2 = @intCast((dir + 1) & 0x3);
                    const neighbor_con2 = a_span.getCon(dir2);

                    if (neighbor_con2 != NOT_CONNECTED) {
                        const bx = ax + heightfield_mod.getDirOffsetX(dir2);
                        const bz = az + heightfield_mod.getDirOffsetY(dir2);
                        const bi = @as(usize, @intCast(chf.cells[@as(usize, @intCast(bx + bz * z_stride))].index + neighbor_con2));

                        if (chf.areas[bi] != NULL_AREA) {
                            neighbor_areas[dir * 2 + 1] = chf.areas[bi];
                        }
                    }
                }

                insertSort(&neighbor_areas);
                areas[span_idx] = neighbor_areas[4]; // Median value
            }
        }
    }

    // Copy filtered areas back
    @memcpy(chf.areas, areas);
}

/// Marks all spans within a box area with the specified area ID.
pub fn markBoxArea(
    ctx: *const Context,
    box_min: Vec3,
    box_max: Vec3,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    _ = ctx; // TODO: timer

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Find the footprint of the box area in grid cell coordinates
    var min_x = @as(i32, @intFromFloat((box_min.x - chf.bmin.x) / chf.cs));
    const min_y = @as(i32, @intFromFloat((box_min.y - chf.bmin.y) / chf.ch));
    var min_z = @as(i32, @intFromFloat((box_min.z - chf.bmin.z) / chf.cs));
    var max_x = @as(i32, @intFromFloat((box_max.x - chf.bmin.x) / chf.cs));
    const max_y = @as(i32, @intFromFloat((box_max.y - chf.bmin.y) / chf.ch));
    var max_z = @as(i32, @intFromFloat((box_max.z - chf.bmin.z) / chf.cs));

    // Early-out if the box is outside the bounds of the grid
    if (max_x < 0) return;
    if (min_x >= x_size) return;
    if (max_z < 0) return;
    if (min_z >= z_size) return;

    // Clamp relevant bound coordinates to the grid
    if (min_x < 0) min_x = 0;
    if (max_x >= x_size) max_x = x_size - 1;
    if (min_z < 0) min_z = 0;
    if (max_z >= z_size) max_z = z_size - 1;

    // Mark relevant cells
    var z: i32 = min_z;
    while (z <= max_z) : (z += 1) {
        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                // Skip if the span is outside the box extents
                if (@as(i32, span.y) < min_y or @as(i32, span.y) > max_y) {
                    continue;
                }

                // Skip if the span has been removed
                if (chf.areas[span_idx] == NULL_AREA) {
                    continue;
                }

                // Mark the span
                chf.areas[span_idx] = area_id;
            }
        }
    }
}

/// Marks all spans within a convex polygon area with the specified area ID.
pub fn markConvexPolyArea(
    ctx: *const Context,
    verts: []const f32,
    num_verts: usize,
    min_y: f32,
    max_y: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    _ = ctx; // TODO: timer

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Compute the bounding box of the polygon
    var bmin = Vec3.init(verts[0], min_y, verts[2]);
    var bmax = Vec3.init(verts[0], max_y, verts[2]);

    for (1..num_verts) |i| {
        const v_idx = i * 3;
        bmin.x = @min(bmin.x, verts[v_idx]);
        bmin.z = @min(bmin.z, verts[v_idx + 2]);
        bmax.x = @max(bmax.x, verts[v_idx]);
        bmax.z = @max(bmax.z, verts[v_idx + 2]);
    }

    // Compute the grid footprint of the polygon
    var minx = @as(i32, @intFromFloat((bmin.x - chf.bmin.x) / chf.cs));
    const miny = @as(i32, @intFromFloat((bmin.y - chf.bmin.y) / chf.ch));
    var minz = @as(i32, @intFromFloat((bmin.z - chf.bmin.z) / chf.cs));
    var maxx = @as(i32, @intFromFloat((bmax.x - chf.bmin.x) / chf.cs));
    const maxy = @as(i32, @intFromFloat((bmax.y - chf.bmin.y) / chf.ch));
    var maxz = @as(i32, @intFromFloat((bmax.z - chf.bmin.z) / chf.cs));

    // Early-out if the polygon lies entirely outside the grid
    if (maxx < 0) return;
    if (minx >= x_size) return;
    if (maxz < 0) return;
    if (minz >= z_size) return;

    // Clamp the polygon footprint to the grid
    if (minx < 0) minx = 0;
    if (maxx >= x_size) maxx = x_size - 1;
    if (minz < 0) minz = 0;
    if (maxz >= z_size) maxz = z_size - 1;

    var z: i32 = minz;
    while (z <= maxz) : (z += 1) {
        var x: i32 = minx;
        while (x <= maxx) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                // Skip if span is removed
                if (chf.areas[span_idx] == NULL_AREA) {
                    continue;
                }

                // Skip if y extents don't overlap
                if (@as(i32, span.y) < miny or @as(i32, span.y) > maxy) {
                    continue;
                }

                const point = Vec3.init(
                    chf.bmin.x + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs,
                    0,
                    chf.bmin.z + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs,
                );

                if (pointInPoly(num_verts, verts, point)) {
                    chf.areas[span_idx] = area_id;
                }
            }
        }
    }
}

/// Marks all spans within a cylindrical area with the specified area ID.
pub fn markCylinderArea(
    ctx: *const Context,
    position: Vec3,
    radius: f32,
    height: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    _ = ctx; // TODO: timer

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Compute the bounding box of the cylinder
    const cyl_bb_min = Vec3.init(
        position.x - radius,
        position.y,
        position.z - radius,
    );
    const cyl_bb_max = Vec3.init(
        position.x + radius,
        position.y + height,
        position.z + radius,
    );

    // Compute the grid footprint of the cylinder
    var minx = @as(i32, @intFromFloat((cyl_bb_min.x - chf.bmin.x) / chf.cs));
    const miny = @as(i32, @intFromFloat((cyl_bb_min.y - chf.bmin.y) / chf.ch));
    var minz = @as(i32, @intFromFloat((cyl_bb_min.z - chf.bmin.z) / chf.cs));
    var maxx = @as(i32, @intFromFloat((cyl_bb_max.x - chf.bmin.x) / chf.cs));
    const maxy = @as(i32, @intFromFloat((cyl_bb_max.y - chf.bmin.y) / chf.ch));
    var maxz = @as(i32, @intFromFloat((cyl_bb_max.z - chf.bmin.z) / chf.cs));

    // Early-out if the cylinder is completely outside the grid bounds
    if (maxx < 0) return;
    if (minx >= x_size) return;
    if (maxz < 0) return;
    if (minz >= z_size) return;

    // Clamp the cylinder bounds to the grid
    if (minx < 0) minx = 0;
    if (maxx >= x_size) maxx = x_size - 1;
    if (minz < 0) minz = 0;
    if (maxz >= z_size) maxz = z_size - 1;

    const radius_sq = radius * radius;

    var z: i32 = minz;
    while (z <= maxz) : (z += 1) {
        var x: i32 = minx;
        while (x <= maxx) : (x += 1) {
            const cell_idx = @as(usize, @intCast(x + z * z_stride));
            const cell = chf.cells[cell_idx];

            const cell_x = chf.bmin.x + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs;
            const cell_z = chf.bmin.z + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs;
            const delta_x = cell_x - position.x;
            const delta_z = cell_z - position.z;

            // Skip this column if it's too far from the center point of the cylinder
            if (delta_x * delta_x + delta_z * delta_z >= radius_sq) {
                continue;
            }

            // Mark all overlapping spans
            var span_idx: usize = cell.index;
            const max_span_idx = cell.index + cell.count;
            while (span_idx < max_span_idx) : (span_idx += 1) {
                const span = chf.spans[span_idx];

                // Skip if span is removed
                if (chf.areas[span_idx] == NULL_AREA) {
                    continue;
                }

                // Mark if y extents overlap
                if (@as(i32, span.y) >= miny and @as(i32, span.y) <= maxy) {
                    chf.areas[span_idx] = area_id;
                }
            }
        }
    }
}

// Tests
test "insertSort" {
    var data = [_]u8{ 5, 2, 8, 1, 9 };
    insertSort(&data);

    try std.testing.expectEqual(@as(u8, 1), data[0]);
    try std.testing.expectEqual(@as(u8, 2), data[1]);
    try std.testing.expectEqual(@as(u8, 5), data[2]);
    try std.testing.expectEqual(@as(u8, 8), data[3]);
    try std.testing.expectEqual(@as(u8, 9), data[4]);
}

test "pointInPoly - point inside" {
    // Square polygon
    const verts = [_]f32{
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10,
    };

    const point = Vec3.init(5, 0, 5);
    try std.testing.expect(pointInPoly(4, &verts, point));
}

test "pointInPoly - point outside" {
    const verts = [_]f32{
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10,
    };

    const point = Vec3.init(15, 0, 15);
    try std.testing.expect(!pointInPoly(4, &verts, point));
}
