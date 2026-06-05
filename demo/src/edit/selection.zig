//! Selection — pure selection geometry for multi-select / group editing
//! (cluster F, feature F3). No UI, no render, no main.zig wiring: this layer
//! only tracks which scene objects are selected (by STABLE id) and computes the
//! XZ rubber-band hit-test against an InputGeom.
//!
//! Identity is by stable id, not array index, so a selection survives the
//! add/remove churn that undo/redo performs:
//!   - `volumes` holds ConvexVolume `.id` values (monotonic, never reused).
//!   - `offmesh` holds off-mesh `.off_id` values. NOTE: off_id is currently
//!     INDEX-DERIVED (1000 + array length, see input_geom.zig) and is NOT stable
//!     across deletion — deleting a middle connection and adding a new one reuses
//!     an id. Off-mesh selection is therefore safe within a churn-free session but
//!     can alias after delete+add until off_id is made monotonic (foundation TODO).

const std = @import("std");
const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;
const Managed = std.array_list.Managed;

pub const Selection = struct {
    /// Selected ConvexVolume `.id` values.
    volumes: Managed(u32),
    /// Selected off-mesh `.off_id` values.
    offmesh: Managed(u32),

    pub fn init(alloc: std.mem.Allocator) Selection {
        return .{
            .volumes = Managed(u32).init(alloc),
            .offmesh = Managed(u32).init(alloc),
        };
    }

    pub fn deinit(self: *Selection) void {
        self.volumes.deinit();
        self.offmesh.deinit();
    }

    /// Drop every selected id (both kinds), keeping allocated capacity.
    pub fn clear(self: *Selection) void {
        self.volumes.clearRetainingCapacity();
        self.offmesh.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Selection) bool {
        return self.volumes.items.len == 0 and self.offmesh.items.len == 0;
    }

    /// Total selected objects across both kinds.
    pub fn count(self: *const Selection) usize {
        return self.volumes.items.len + self.offmesh.items.len;
    }

    pub fn containsVolume(self: *const Selection, id: u32) bool {
        for (self.volumes.items) |v| {
            if (v == id) return true;
        }
        return false;
    }

    pub fn containsOffmesh(self: *const Selection, id: u32) bool {
        for (self.offmesh.items) |v| {
            if (v == id) return true;
        }
        return false;
    }

    /// Add `id` if absent, remove it if already present.
    pub fn toggleVolume(self: *Selection, id: u32) !void {
        for (self.volumes.items, 0..) |v, i| {
            if (v == id) {
                _ = self.volumes.orderedRemove(i);
                return;
            }
        }
        try self.volumes.append(id);
    }

    /// Add `id` if absent, remove it if already present.
    pub fn toggleOffmesh(self: *Selection, id: u32) !void {
        for (self.offmesh.items, 0..) |v, i| {
            if (v == id) {
                _ = self.offmesh.orderedRemove(i);
                return;
            }
        }
        try self.offmesh.append(id);
    }
};

/// Replace `sel` contents with everything whose XZ footprint falls inside the
/// axis-aligned rect [min(x0,x1)..max] x [min(z0,z1)..max]. A ConvexVolume is
/// selected when its XZ CENTROID (average of its nverts (x,z)) is inside; an
/// off-mesh link when its segment MIDPOINT XZ is inside. Y is ignored. The rect
/// is normalized (handles x1<x0 / z1<z0).
pub fn rubberBand(sel: *Selection, geom: *const InputGeom, x0: f32, z0: f32, x1: f32, z1: f32) !void {
    const xmin = @min(x0, x1);
    const xmax = @max(x0, x1);
    const zmin = @min(z0, z1);
    const zmax = @max(z0, z1);

    sel.clear();

    // Convex volumes: XZ centroid (mean of nverts x,z) inside the rect.
    for (geom.volumes.items) |*vol| {
        const n: usize = @intCast(vol.nverts);
        if (n == 0) continue;
        var sx: f32 = 0;
        var sz: f32 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            sx += vol.verts[k * 3 + 0];
            sz += vol.verts[k * 3 + 2];
        }
        const cx = sx / @as(f32, @floatFromInt(n));
        const cz = sz / @as(f32, @floatFromInt(n));
        if (cx >= xmin and cx <= xmax and cz >= zmin and cz <= zmax) {
            try sel.volumes.append(vol.id);
        }
    }

    // Off-mesh links: XZ midpoint of the (start,end) segment inside the rect.
    var i: usize = 0;
    while (i < geom.offMeshCount()) : (i += 1) {
        const v = geom.off_verts.items[i * 6 ..][0..6];
        const mx = (v[0] + v[3]) * 0.5;
        const mz = (v[2] + v[5]) * 0.5;
        if (mx >= xmin and mx <= xmax and mz >= zmin and mz <= zmax) {
            try sel.offmesh.append(geom.off_id.items[i]);
        }
    }
}

/// Result of a single-object pick under a world XZ point (feature F3): identifies
/// which scene object (if any) lies beneath the cursor, by STABLE id. Volume
/// containment wins over an off-mesh endpoint (objects on top of a region are
/// selected in preference to a link drawn through it).
pub const HitResult = union(enum) {
    volume: u32, // ConvexVolume .id
    offmesh: u32, // off-mesh .off_id
};

/// Standard XZ point-in-polygon (ray-cast / crossing-number) against a convex
/// volume's `nverts` XZ footprint. Y is ignored. `verts` is the volume's stride-3
/// [x,y,z,...] array; `nverts` its point count.
fn pointInVolumeXZ(verts: []const f32, nverts: usize, px: f32, pz: f32) bool {
    if (nverts < 3) return false;
    var inside = false;
    var i: usize = 0;
    var j: usize = nverts - 1;
    while (i < nverts) : (i += 1) {
        const xi = verts[i * 3 + 0];
        const zi = verts[i * 3 + 2];
        const xj = verts[j * 3 + 0];
        const zj = verts[j * 3 + 2];
        if (((zi > pz) != (zj > pz)) and
            (px < (xj - xi) * (pz - zi) / (zj - zi) + xi))
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Single-object hit-test for Ctrl+click toggle and tiny-drag click. Returns the
/// object under world XZ (px,pz): a volume whose XZ footprint CONTAINS the point
/// (preferred — last/topmost match wins), else the nearest off-mesh endpoint
/// within `off_radius` world units, else null. Pure geometry; no UI, no mutation.
pub fn hitTest(geom: *const InputGeom, px: f32, pz: f32, off_radius: f32) ?HitResult {
    // Prefer volume containment. Iterate so the LAST containing volume wins (later
    // = drawn on top in the add order), matching what the user clicks visually.
    var found_vol: ?u32 = null;
    for (geom.volumes.items) |*vol| {
        const n: usize = @intCast(vol.nverts);
        if (pointInVolumeXZ(vol.verts[0 .. n * 3], n, px, pz)) found_vol = vol.id;
    }
    if (found_vol) |id| return .{ .volume = id };

    // Fall back to the nearest off-mesh ENDPOINT (start or end) within radius.
    const r2 = off_radius * off_radius;
    var best_d2: f32 = r2;
    var best_id: ?u32 = null;
    var i: usize = 0;
    while (i < geom.offMeshCount()) : (i += 1) {
        const v = geom.off_verts.items[i * 6 ..][0..6];
        for ([_]usize{ 0, 3 }) |o| {
            const dx = v[o + 0] - px;
            const dz = v[o + 2] - pz;
            const d2 = dx * dx + dz * dz;
            if (d2 <= best_d2) {
                best_d2 = d2;
                best_id = geom.off_id.items[i];
            }
        }
    }
    if (best_id) |id| return .{ .offmesh = id };
    return null;
}

test "toggleVolume adds then removes; containsVolume + count reflect it" {
    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();

    try std.testing.expect(sel.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), sel.count());

    try sel.toggleVolume(7);
    try std.testing.expect(sel.containsVolume(7));
    try std.testing.expect(!sel.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), sel.count());

    try sel.toggleVolume(7); // toggle off
    try std.testing.expect(!sel.containsVolume(7));
    try std.testing.expectEqual(@as(usize, 0), sel.count());
    try std.testing.expect(sel.isEmpty());
}

test "rubberBand selects only the volume whose centroid is inside the rect" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    // Volume A: triangle near origin (centroid ~ (0.33, 0.33)) -> INSIDE [-1..1].
    const a = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&a, 3, 0.0, 1.0, 0); // id 1
    // Volume B: triangle far away (centroid ~ (10.33, 10.33)) -> OUTSIDE.
    const b = [_]f32{ 10, 0, 10, 11, 0, 10, 10, 0, 11 };
    try geom.addConvexVolume(&b, 3, 0.0, 1.0, 0); // id 2

    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();

    try rubberBand(&sel, &geom, -1, -1, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), sel.count());
    try std.testing.expect(sel.containsVolume(1));
    try std.testing.expect(!sel.containsVolume(2));
}

test "rubberBand normalizes an inverted rect (x1<x0, z1<z0)" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    const a = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&a, 3, 0.0, 1.0, 0); // id 1, centroid inside [-1..1]

    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();

    // Inverted corners describe the same rect via min/max normalization.
    try rubberBand(&sel, &geom, 1, 1, -1, -1);
    try std.testing.expectEqual(@as(usize, 1), sel.count());
    try std.testing.expect(sel.containsVolume(1));
}

test "rubberBand selects off-mesh by segment midpoint XZ" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    // Segment from (0,0,0) to (2,0,2): midpoint XZ = (1,1) -> inside [-1..3].
    try geom.addOffMeshConnection(.{ 0, 0, 0 }, .{ 2, 0, 2 }, 0.5, 1, 0, 0); // off_id 1000
    // Segment far away: midpoint ~ (20,20) -> outside.
    try geom.addOffMeshConnection(.{ 20, 0, 20 }, .{ 22, 0, 22 }, 0.5, 1, 0, 0);

    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();

    try rubberBand(&sel, &geom, -1, -1, 3, 3);
    try std.testing.expectEqual(@as(usize, 1), sel.count());
    try std.testing.expect(sel.containsOffmesh(1000));
}

test "hitTest: point inside a volume returns that volume id (containment wins)" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    // A unit square around origin (verts CCW in XZ): contains (0.25, 0.25).
    const sq = [_]f32{ -1, 0, -1, 1, 0, -1, 1, 0, 1, -1, 0, 1 };
    try geom.addConvexVolume(&sq, 4, 0.0, 1.0, 0); // id 1

    const hit = hitTest(&geom, 0.25, 0.25, 0.5).?;
    try std.testing.expectEqual(@as(u32, 1), hit.volume);

    // A point well outside -> no hit.
    try std.testing.expectEqual(@as(?HitResult, null), hitTest(&geom, 10, 10, 0.5));
}

test "hitTest: nearest off-mesh endpoint within radius when no volume contains" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    // Endpoint at (5,_,5). A click at (5.2, 5.1) is within 0.5 of it.
    try geom.addOffMeshConnection(.{ 5, 0, 5 }, .{ 8, 0, 8 }, 0.5, 1, 0, 0); // off_id 1000

    const hit = hitTest(&geom, 5.2, 5.1, 0.5).?;
    try std.testing.expectEqual(@as(u32, 1000), hit.offmesh);

    // Just out of radius -> no hit.
    try std.testing.expectEqual(@as(?HitResult, null), hitTest(&geom, 6.0, 6.0, 0.5));
}
