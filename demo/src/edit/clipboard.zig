//! Clipboard — pure value storage for copy/paste of selected scene objects
//! (cluster F, feature F3, WAVE 2). Like `selection.zig` this layer holds NO UI
//! and performs NO geom mutation: it only stores by-VALUE copies of the objects
//! that were selected at copy time. Paste (which mutates the geom + records an
//! undo composite) lives in main.zig — the clipboard stays pure data so it can be
//! unit-tested without GL/UI and so mutating the live geom after a copy never
//! disturbs the captured copies.
//!
//! Both `ConvexVolume` and `OffMeshData` are value types (fixed arrays, no
//! slices), so the clipboard owns no per-object heap — only the two backing
//! ArrayLists.

const std = @import("std");
const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;
const ConvexVolume = ig.ConvexVolume;
const OffMeshData = @import("edit_op.zig").OffMeshData;
const Selection = @import("selection.zig").Selection;
const Managed = std.array_list.Managed;

pub const Clipboard = struct {
    /// Full value copies of the copied volumes (id/mode/band/verts preserved).
    volumes: Managed(ConvexVolume),
    /// Full value copies of the copied off-mesh connections.
    offmesh: Managed(OffMeshData),

    pub fn init(alloc: std.mem.Allocator) Clipboard {
        return .{
            .volumes = Managed(ConvexVolume).init(alloc),
            .offmesh = Managed(OffMeshData).init(alloc),
        };
    }

    pub fn deinit(self: *Clipboard) void {
        self.volumes.deinit();
        self.offmesh.deinit();
    }

    /// Drop all copied objects, keeping allocated capacity.
    pub fn clear(self: *Clipboard) void {
        self.volumes.clearRetainingCapacity();
        self.offmesh.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Clipboard) bool {
        return self.volumes.items.len == 0 and self.offmesh.items.len == 0;
    }

    /// Total copied objects across both kinds.
    pub fn count(self: *const Clipboard) usize {
        return self.volumes.items.len + self.offmesh.items.len;
    }

    /// Replace clipboard contents with by-value copies of everything currently
    /// selected. For each selected volume id, find the matching volume in
    /// `geom.volumes` and append a full struct copy (mode/band/verts preserved).
    /// For each selected off_id, find the connection and append `OffMeshData`.
    /// Selected ids that no longer exist in `geom` are skipped silently.
    pub fn copyFrom(self: *Clipboard, geom: *const InputGeom, sel: *const Selection) !void {
        self.clear();

        for (sel.volumes.items) |sid| {
            for (geom.volumes.items) |*vol| {
                if (vol.id == sid) {
                    try self.volumes.append(vol.*); // value copy
                    break;
                }
            }
        }

        for (sel.offmesh.items) |sid| {
            for (geom.off_id.items, 0..) |oid, i| {
                if (oid == sid) {
                    try self.offmesh.append(OffMeshData.capture(geom, i));
                    break;
                }
            }
        }
    }
};

// ===================================================================== tests

test "copyFrom copies the selected subset by value; later geom mutation is isolated" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    // Two volumes; we will select only the first.
    const triA = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    const triB = [_]f32{ 9, 0, 9, 10, 0, 9, 9, 0, 10 };
    try geom.addConvexVolume(&triA, 3, 0.0, 1.0, 4); // id 1
    geom.volumes.items[0].mode = .prism;
    geom.volumes.items[0].band_below = 2.5;
    geom.volumes.items[0].band_above = 3.5;
    try geom.addConvexVolume(&triB, 3, 0.0, 1.0, 0); // id 2

    // One off-mesh; selected.
    try geom.addOffMeshConnection(.{ 1, 1, 1 }, .{ 4, 1, 4 }, 0.5, 1, 7, 0x22); // off_id 1000

    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();
    try sel.volumes.append(1); // only volume id 1
    try sel.offmesh.append(1000);

    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();
    try cb.copyFrom(&geom, &sel);

    // Exactly the selected subset (1 volume + 1 off-mesh), not volume id 2.
    try std.testing.expectEqual(@as(usize, 2), cb.count());
    try std.testing.expectEqual(@as(usize, 1), cb.volumes.items.len);
    try std.testing.expectEqual(@as(usize, 1), cb.offmesh.items.len);
    try std.testing.expectEqual(@as(u32, 1), cb.volumes.items[0].id);
    // mode/band preserved in the copy.
    try std.testing.expectEqual(ig.VolumeMode.prism, cb.volumes.items[0].mode);
    try std.testing.expectEqual(@as(f32, 2.5), cb.volumes.items[0].band_below);
    try std.testing.expectEqual(@as(f32, 3.5), cb.volumes.items[0].band_above);
    try std.testing.expectEqual(@as(f32, 1.0), cb.offmesh.items[0].verts[0]);

    // Mutate the GEOM after the copy — the clipboard copies must NOT change.
    geom.volumes.items[0].verts[0] = 999;
    geom.volumes.items[0].band_below = -7;
    geom.off_verts.items[0] = 999;
    try std.testing.expectEqual(@as(f32, 0.0), cb.volumes.items[0].verts[0]);
    try std.testing.expectEqual(@as(f32, 2.5), cb.volumes.items[0].band_below);
    try std.testing.expectEqual(@as(f32, 1.0), cb.offmesh.items[0].verts[0]);
}

test "copyFrom clears prior contents; isEmpty + count reflect state" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0); // id 1

    var sel = Selection.init(std.testing.allocator);
    defer sel.deinit();

    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();

    try std.testing.expect(cb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), cb.count());

    // Copy with id 1 selected.
    try sel.volumes.append(1);
    try cb.copyFrom(&geom, &sel);
    try std.testing.expect(!cb.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), cb.count());

    // Copy again with an EMPTY selection -> clipboard cleared.
    sel.clear();
    try cb.copyFrom(&geom, &sel);
    try std.testing.expect(cb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), cb.count());
}
