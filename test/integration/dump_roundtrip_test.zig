const std = @import("std");
const testing = std.testing;
const nav = @import("zig-recast");

const dump = nav.debug.dump;
const FileIO = dump.FileIO;

// In-memory FileIO: write appends to a growable buffer; read consumes a cursor.
const MemIO = struct {
    buf: *std.array_list.Managed(u8),
    cursor: usize = 0,
    writing: bool,

    fn isWriting(ptr: *anyopaque) bool {
        const self: *MemIO = @ptrCast(@alignCast(ptr));
        return self.writing;
    }
    fn isReading(ptr: *anyopaque) bool {
        const self: *MemIO = @ptrCast(@alignCast(ptr));
        return !self.writing;
    }
    fn write(ptr: *anyopaque, data: []const u8) bool {
        const self: *MemIO = @ptrCast(@alignCast(ptr));
        self.buf.appendSlice(data) catch return false;
        return true;
    }
    fn read(ptr: *anyopaque, buffer: []u8) bool {
        const self: *MemIO = @ptrCast(@alignCast(ptr));
        if (self.cursor + buffer.len > self.buf.items.len) return false;
        @memcpy(buffer, self.buf.items[self.cursor .. self.cursor + buffer.len]);
        self.cursor += buffer.len;
        return true;
    }
    const vtable = FileIO.VTable{
        .isWriting = isWriting,
        .isReading = isReading,
        .write = write,
        .read = read,
    };
    fn io(self: *MemIO) FileIO {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "dump/read ContourSet round-trips" {
    const allocator = testing.allocator;

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    cset.nconts = 1;
    cset.bmin = nav.Vec3.init(1, 2, 3);
    cset.bmax = nav.Vec3.init(4, 5, 6);
    cset.cs = 0.3;
    cset.ch = 0.2;
    cset.width = 10;
    cset.height = 12;
    cset.border_size = 1;

    const conts = try allocator.alloc(nav.recast.Contour, 1);
    conts[0] = nav.recast.Contour.init(allocator);
    conts[0].nverts = 2;
    conts[0].nrverts = 3;
    conts[0].reg = 7;
    conts[0].area = 5;
    conts[0].verts = try allocator.alloc(i32, 2 * 4);
    for (conts[0].verts, 0..) |*v, i| v.* = @intCast(i * 11);
    conts[0].rverts = try allocator.alloc(i32, 3 * 4);
    for (conts[0].rverts, 0..) |*v, i| v.* = @intCast(i * 7 + 1);
    cset.conts = conts;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    var wio = MemIO{ .buf = &buf, .writing = true };
    try dump.dumpContourSet(&cset, wio.io());

    var cset2 = nav.ContourSet.init(allocator);
    defer cset2.deinit();
    var rio = MemIO{ .buf = &buf, .writing = false };
    try dump.readContourSet(&cset2, rio.io());

    try testing.expectEqual(cset.nconts, cset2.nconts);
    try testing.expectEqual(cset.width, cset2.width);
    try testing.expectEqual(cset.height, cset2.height);
    try testing.expectEqual(cset.border_size, cset2.border_size);
    try testing.expectEqual(cset.cs, cset2.cs);
    try testing.expectEqual(cset.ch, cset2.ch);
    try testing.expectEqual(cset.bmin.x, cset2.bmin.x);
    try testing.expectEqual(cset.bmax.z, cset2.bmax.z);
    try testing.expectEqual(cset.conts[0].nverts, cset2.conts[0].nverts);
    try testing.expectEqual(cset.conts[0].nrverts, cset2.conts[0].nrverts);
    try testing.expectEqual(cset.conts[0].reg, cset2.conts[0].reg);
    try testing.expectEqual(cset.conts[0].area, cset2.conts[0].area);
    try testing.expectEqualSlices(i32, cset.conts[0].verts, cset2.conts[0].verts);
    try testing.expectEqualSlices(i32, cset.conts[0].rverts, cset2.conts[0].rverts);
}
