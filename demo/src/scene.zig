//! Scene — the aggregate of editable world state (foundation step 2 skeleton).
//! Intended to become the single point-of-truth that persistence serialises and
//! that tools/clusters read. For now it borrows the existing `InputGeom` and owns
//! only the NEW pieces (meta + dirty tracking); the module-global area/flag
//! registries are migrated in a later step (foundation step 5) via transitional
//! wrappers, so they are deliberately NOT moved here yet.

const std = @import("std");
const InputGeom = @import("input_geom.zig").InputGeom;

/// On-disk format version for the scene container (edits/manifest). Bumped when
/// the serialised layout changes; readers use it for backward compatibility.
pub const FORMAT_VERSION: u32 = 1;

/// What changed since the last save. Drives "needs rebuild" / "needs save"
/// decisions and (later) which tiles/registries to re-serialise.
pub const DirtyBits = struct {
    geom: bool = false,
    areas: bool = false,
    flags: bool = false,
    tiles: bool = false,

    pub fn any(self: DirtyBits) bool {
        return self.geom or self.areas or self.flags or self.tiles;
    }
    pub fn clear(self: *DirtyBits) void {
        self.* = .{};
    }
    pub fn markAll(self: *DirtyBits) void {
        self.* = .{ .geom = true, .areas = true, .flags = true, .tiles = true };
    }
};

/// Scene identity/metadata persisted alongside the geometry and registries.
pub const SceneMeta = struct {
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    format_version: u32 = FORMAT_VERSION,

    pub fn name(self: *const SceneMeta) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn setName(self: *SceneMeta, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

/// Aggregate of editable world state. Borrows `geom` (does not own/free it);
/// owns `meta` and `dirty`. Accessors are the start of the point-of-truth API
/// and grow as clusters need them.
pub const Scene = struct {
    geom: *InputGeom,
    meta: SceneMeta = .{},
    dirty: DirtyBits = .{},

    pub fn init(geom: *InputGeom) Scene {
        return .{ .geom = geom };
    }

    pub fn volumeCount(self: *const Scene) usize {
        return self.geom.volumes.items.len;
    }
    pub fn offMeshCount(self: *const Scene) usize {
        return self.geom.offMeshCount();
    }
};

test "DirtyBits any/clear/markAll" {
    var d = DirtyBits{};
    try std.testing.expect(!d.any());
    d.geom = true;
    try std.testing.expect(d.any());
    d.clear();
    try std.testing.expect(!d.any());
    d.markAll();
    try std.testing.expect(d.geom and d.areas and d.flags and d.tiles);
}

test "SceneMeta name + default version" {
    var m = SceneMeta{};
    try std.testing.expectEqual(@as(u32, FORMAT_VERSION), m.format_version);
    try std.testing.expectEqualStrings("", m.name());
    m.setName("nav_test");
    try std.testing.expectEqualStrings("nav_test", m.name());
}

test "Scene borrows geom and reports counts" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var scene = Scene.init(&geom);
    try std.testing.expectEqual(@as(usize, 0), scene.volumeCount());
    try std.testing.expectEqual(@as(usize, 0), scene.offMeshCount());
    try std.testing.expect(!scene.dirty.any());
}
