const std = @import("std");
const math = @import("../math.zig");
const heightfield_mod = @import("heightfield.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;
const Heightfield = heightfield_mod.Heightfield;
const Span = heightfield_mod.Span;

const MAX_HEIGHTFIELD_HEIGHT: i32 = 0xffff;
const NULL_AREA = config.AreaId.NULL_AREA;
const WALKABLE_AREA = config.AreaId.WALKABLE_AREA;

/// Marks non-walkable spans as walkable if their maximum is within walkableClimb of a walkable neighbor.
/// Allows small obstacles (curbs, stairs) to be traversed.
pub fn filterLowHangingWalkableObstacles(
    ctx: *const Context,
    walkable_climb: i32,
    heightfield: *Heightfield,
) void {
    _ = ctx; // TODO: timer
    const x_size = heightfield.width;
    const z_size = heightfield.height;

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            var previous_span: ?*Span = null;
            var previous_was_walkable = false;
            var previous_area_id: u8 = NULL_AREA;

            const col_idx = @as(usize, @intCast(x + z * x_size));
            var span = heightfield.spans[col_idx];

            // For each span in the column...
            while (span) |s| {
                const walkable = s.area != NULL_AREA;

                // If current span is not walkable, but there is walkable span just below it
                // and the height difference is small enough, mark current span as walkable too
                if (!walkable and previous_was_walkable) {
                    if (previous_span) |prev| {
                        if (@as(i32, s.smax) - @as(i32, prev.smax) <= walkable_climb) {
                            s.area = previous_area_id;
                        }
                    }
                }

                // Copy the original walkable value regardless of whether we changed it
                previous_was_walkable = walkable;
                previous_area_id = s.area;
                previous_span = s;
                span = s.next;
            }
        }
    }
}

/// Marks spans that are ledges as unwalkable.
/// A ledge is a span with one or more neighbors whose maximum is further away than walkableClimb.
pub fn filterLedgeSpans(
    ctx: *const Context,
    walkable_height: i32,
    walkable_climb: i32,
    heightfield: *Heightfield,
) void {
    _ = ctx; // TODO: timer
    const x_size = heightfield.width;
    const z_size = heightfield.height;

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * x_size));
            var span = heightfield.spans[col_idx];

            while (span) |s| {
                // Skip non-walkable spans
                if (s.area == NULL_AREA) {
                    span = s.next;
                    continue;
                }

                const floor = @as(i32, s.smax);
                const ceiling = if (s.next) |next| @as(i32, next.smin) else MAX_HEIGHTFIELD_HEIGHT;

                // The difference between this walkable area and the lowest neighbor walkable area
                var lowest_neighbor_floor_diff = MAX_HEIGHTFIELD_HEIGHT;

                // Min and max height of accessible neighbors
                var lowest_traversable_neighbor_floor = @as(i32, s.smax);
                var highest_traversable_neighbor_floor = @as(i32, s.smax);

                // Check all 4 neighbors
                var is_ledge = false;
                for (0..4) |direction| {
                    const dir: u2 = @intCast(direction);
                    const neighbor_x = x + heightfield_mod.getDirOffsetX(dir);
                    const neighbor_z = z + heightfield_mod.getDirOffsetY(dir);

                    // Skip neighbors which are out of bounds
                    if (neighbor_x < 0 or neighbor_z < 0 or neighbor_x >= x_size or neighbor_z >= z_size) {
                        lowest_neighbor_floor_diff = -walkable_climb - 1;
                        is_ledge = true;
                        break;
                    }

                    const neighbor_col_idx = @as(usize, @intCast(neighbor_x + neighbor_z * x_size));
                    var neighbor_span = heightfield.spans[neighbor_col_idx];

                    // The most we can step down to the neighbor is the walkableClimb distance
                    var neighbor_ceiling = if (neighbor_span) |ns| @as(i32, ns.smin) else MAX_HEIGHTFIELD_HEIGHT;

                    // Skip neighbor if the gap between the spans is too small
                    if (@min(ceiling, neighbor_ceiling) - floor >= walkable_height) {
                        lowest_neighbor_floor_diff = -walkable_climb - 1;
                        is_ledge = true;
                        break;
                    }

                    // For each span in the neighboring column...
                    while (neighbor_span) |ns| {
                        const neighbor_floor = @as(i32, ns.smax);
                        neighbor_ceiling = if (ns.next) |next| @as(i32, next.smin) else MAX_HEIGHTFIELD_HEIGHT;

                        // Only consider neighboring areas that have enough overlap
                        if (@min(ceiling, neighbor_ceiling) - @max(floor, neighbor_floor) < walkable_height) {
                            // No space to traverse between them
                            neighbor_span = ns.next;
                            continue;
                        }

                        const neighbor_floor_diff = neighbor_floor - floor;
                        lowest_neighbor_floor_diff = @min(lowest_neighbor_floor_diff, neighbor_floor_diff);

                        // Find min/max accessible neighbor height
                        if (@abs(neighbor_floor_diff) <= walkable_climb) {
                            // There is space to move to the neighbor cell
                            lowest_traversable_neighbor_floor = @min(lowest_traversable_neighbor_floor, neighbor_floor);
                            highest_traversable_neighbor_floor = @max(highest_traversable_neighbor_floor, neighbor_floor);
                        } else if (neighbor_floor_diff < -walkable_climb) {
                            // We already know this is a ledge
                            break;
                        }

                        neighbor_span = ns.next;
                    }
                }

                // The current span is close to a ledge if the drop to any neighbor is greater than walkableClimb
                if (lowest_neighbor_floor_diff < -walkable_climb) {
                    s.area = NULL_AREA;
                } else if (highest_traversable_neighbor_floor - lowest_traversable_neighbor_floor > walkable_climb) {
                    // If the difference between all neighbor floors is too large, this is a steep slope
                    s.area = NULL_AREA;
                }

                span = s.next;
            }
        }
    }
}

/// Marks walkable spans as not walkable if the clearance above the span is less than the specified height.
pub fn filterWalkableLowHeightSpans(
    ctx: *const Context,
    walkable_height: i32,
    heightfield: *Heightfield,
) void {
    _ = ctx; // TODO: timer
    const x_size = heightfield.width;
    const z_size = heightfield.height;

    // Remove walkable flag from spans which do not have enough space above them
    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * x_size));
            var span = heightfield.spans[col_idx];

            while (span) |s| {
                const floor = @as(i32, s.smax);
                const ceiling = if (s.next) |next| @as(i32, next.smin) else MAX_HEIGHTFIELD_HEIGHT;

                if (ceiling - floor < walkable_height) {
                    s.area = NULL_AREA;
                }

                span = s.next;
            }
        }
    }
}

/// Marks walkable triangles by checking if the triangle slope is below the threshold.
/// Triangles with a slope angle less than walkableSlopeAngle are marked as walkable.
pub fn markWalkableTriangles(
    ctx: *const Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    tris: []const i32,
    tri_area_ids: []u8,
) void {
    _ = ctx;
    const num_tris = @divExact(tris.len, 3);
    std.debug.assert(tri_area_ids.len == num_tris);

    const walkable_thr = @cos(walkable_slope_angle / 180.0 * math.PI);

    for (0..num_tris) |i| {
        const tri = tris[i * 3 .. (i + 1) * 3];
        const idx0 = @as(usize, @intCast(tri[0] * 3));
        const idx1 = @as(usize, @intCast(tri[1] * 3));
        const idx2 = @as(usize, @intCast(tri[2] * 3));
        const v0 = Vec3.init(verts[idx0], verts[idx0 + 1], verts[idx0 + 2]);
        const v1 = Vec3.init(verts[idx1], verts[idx1 + 1], verts[idx1 + 2]);
        const v2 = Vec3.init(verts[idx2], verts[idx2 + 1], verts[idx2 + 2]);

        // Calculate triangle normal
        const e0 = v1.sub(v0);
        const e1 = v2.sub(v0);
        var norm = e0.cross(e1);
        norm.normalize();

        // Check if the face is walkable
        if (norm.y > walkable_thr) {
            tri_area_ids[i] = WALKABLE_AREA;
        }
    }
}

/// Marks walkable triangles as null area by checking if the triangle slope is above the threshold.
/// Triangles with a slope angle greater than walkableSlopeAngle are marked as unwalkable.
pub fn clearUnwalkableTriangles(
    ctx: *const Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    tris: []const i32,
    tri_area_ids: []u8,
) void {
    _ = ctx;
    const num_tris = @divExact(tris.len, 3);
    std.debug.assert(tri_area_ids.len == num_tris);

    const walkable_thr = @cos(walkable_slope_angle / 180.0 * math.PI);

    for (0..num_tris) |i| {
        const tri = tris[i * 3 .. (i + 1) * 3];
        const idx0 = @as(usize, @intCast(tri[0] * 3));
        const idx1 = @as(usize, @intCast(tri[1] * 3));
        const idx2 = @as(usize, @intCast(tri[2] * 3));
        const v0 = Vec3.init(verts[idx0], verts[idx0 + 1], verts[idx0 + 2]);
        const v1 = Vec3.init(verts[idx1], verts[idx1 + 1], verts[idx1 + 2]);
        const v2 = Vec3.init(verts[idx2], verts[idx2 + 1], verts[idx2 + 2]);

        // Calculate triangle normal
        const e0 = v1.sub(v0);
        const e1 = v2.sub(v0);
        var norm = e0.cross(e1);
        norm.normalize();

        // Check if the face is unwalkable
        if (norm.y <= walkable_thr) {
            tri_area_ids[i] = NULL_AREA;
        }
    }
}

// Tests
test "filterLowHangingWalkableObstacles" {
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

    // Create a test scenario with spans
    // TODO: Add test spans

    const ctx = Context.init(allocator);
    filterLowHangingWalkableObstacles(&ctx, 2, &hf);
}

test "markWalkableTriangles" {
    const allocator = std.testing.allocator;

    // Counter-clockwise winding when viewed from above (Y-up)
    const verts = [_]f32{
        0, 0, 0,
        1, 0, 0,
        0, 0, -1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{0};

    const ctx = Context.init(allocator);
    markWalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Flat triangle with correct winding should be walkable
    try std.testing.expectEqual(WALKABLE_AREA, areas[0]);
}

test "clearUnwalkableTriangles - steep slope" {
    const allocator = std.testing.allocator;

    // Steep triangle (almost vertical)
    const verts = [_]f32{
        0, 0,  0,
        1, 10, 0,
        0, 0,  1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{WALKABLE_AREA};

    const ctx = Context.init(allocator);
    clearUnwalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Steep triangle should be cleared
    try std.testing.expectEqual(NULL_AREA, areas[0]);
}
