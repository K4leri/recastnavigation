//! Persist — shared little-endian byte I/O primitives (dedup core).
//!
//! ALL persist sub-formats encode integers/floats LITTLE-ENDIAN, field-by-field
//! (std.mem.writeInt/readInt `.little`), so files are portable across machines
//! independent of host ABI/alignment. This module centralizes the read cursor and
//! write helpers that were previously copy-pasted into every persist file
//! (registry_io / scene_io / manifest / bundle / navmesh_io / crowd_replay).
//!
//! BYTE-FORMAT INVARIANT: this is a pure mechanical extraction — every read/write
//! produces byte-IDENTICAL results to the prior hand-rolled `.little` code. No
//! field layout, width, or order changes here.
//!
//! LeReader: a bounds-checked cursor over a `[]const u8`. Every read validates the
//! requested span fits BEFORE advancing — it never panics on a truncated/corrupt
//! buffer. End offsets are computed overflow-safely (`std.math.add`) so a bogus
//! length field returns error.Truncated rather than wrapping.
//!
//! LeWriter: a free-function namespace over `*std.array_list.Managed(u8)` (append
//! little-endian). Float helpers @bitCast through the matching unsigned width so
//! the exact IEEE-754 bit pattern is preserved and the on-disk bytes are stable.

const std = @import("std");

/// Error set for short/truncated reads. Callers may widen this into their own
/// error vocabulary (e.g. scene_io.Error) — `error.Truncated` is shared.
pub const ReadError = error{Truncated};

/// Bounds-checked little-endian read cursor over a borrowed byte slice.
///
/// `data` is NOT owned; the cursor only reads. `pos` is the current offset. All
/// readers return `error.Truncated` (never panic) when the requested bytes are
/// not available, and only advance `pos` on success.
pub const LeReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) LeReader {
        return .{ .data = data };
    }

    /// Bytes left to read from the current position.
    pub fn remaining(self: *const LeReader) usize {
        return self.data.len - self.pos;
    }

    /// Overflow-safe check that `n` more bytes are available; returns the
    /// (validated) end offset without advancing.
    fn checkEnd(self: *const LeReader, n: usize) ReadError!usize {
        const end = std.math.add(usize, self.pos, n) catch return error.Truncated;
        if (end > self.data.len) return error.Truncated;
        return end;
    }

    pub fn readU8(self: *LeReader) ReadError!u8 {
        const end = try self.checkEnd(1);
        const v = self.data[self.pos];
        self.pos = end;
        return v;
    }

    pub fn readU16(self: *LeReader) ReadError!u16 {
        const end = try self.checkEnd(2);
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos = end;
        return v;
    }

    pub fn readU32(self: *LeReader) ReadError!u32 {
        const end = try self.checkEnd(4);
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos = end;
        return v;
    }

    pub fn readU64(self: *LeReader) ReadError!u64 {
        const end = try self.checkEnd(8);
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos = end;
        return v;
    }

    pub fn readI32(self: *LeReader) ReadError!i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF32(self: *LeReader) ReadError!f32 {
        return @bitCast(try self.readU32());
    }

    /// Return a no-copy slice of the next `n` bytes (pointing into `data`).
    pub fn readBytes(self: *LeReader, n: usize) ReadError![]const u8 {
        const end = try self.checkEnd(n);
        const s = self.data[self.pos..end];
        self.pos = end;
        return s;
    }

    /// Advance past `n` bytes without returning them.
    pub fn skip(self: *LeReader, n: usize) ReadError!void {
        const end = try self.checkEnd(n);
        self.pos = end;
    }
};

/// Little-endian write helpers over `*std.array_list.Managed(u8)`.
///
/// Free-function namespace (no state) so existing call-sites can swap their
/// hand-rolled putU*/putI*/putF* for `LeWriter.putU32(b, v)` etc. The buffer's
/// own allocator backs every append; errors propagate as Allocator.Error.
pub const LeWriter = struct {
    pub const Buf = std.array_list.Managed(u8);

    pub fn putU8(b: *Buf, v: u8) !void {
        try b.append(v);
    }

    pub fn putU16(b: *Buf, v: u16) !void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .little);
        try b.appendSlice(&tmp);
    }

    pub fn putU32(b: *Buf, v: u32) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try b.appendSlice(&tmp);
    }

    pub fn putU64(b: *Buf, v: u64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .little);
        try b.appendSlice(&tmp);
    }

    /// @bitCast preserves the two's-complement bit pattern; LE write makes it portable.
    pub fn putI32(b: *Buf, v: i32) !void {
        try putU32(b, @bitCast(v));
    }

    /// @bitCast preserves the IEEE-754 bit pattern; LE write makes it portable.
    pub fn putF32(b: *Buf, v: f32) !void {
        try putU32(b, @bitCast(v));
    }
};

// ---------------------------------------------------------------------------
// Tests (std-only — `zig test demo/src/persist/byteio.zig`).
// ---------------------------------------------------------------------------

test "LeWriter -> LeReader round-trip for every width" {
    const a = std.testing.allocator;
    var b = LeWriter.Buf.init(a);
    defer b.deinit();

    try LeWriter.putU8(&b, 0xAB);
    try LeWriter.putU16(&b, 0xBEEF);
    try LeWriter.putU32(&b, 0xDEADBEEF);
    try LeWriter.putU64(&b, 0x0123456789ABCDEF);
    try LeWriter.putI32(&b, -123456);
    try LeWriter.putF32(&b, 3.14159);

    var r = LeReader.init(b.items);
    try std.testing.expectEqual(@as(u8, 0xAB), try r.readU8());
    try std.testing.expectEqual(@as(u16, 0xBEEF), try r.readU16());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readU32());
    try std.testing.expectEqual(@as(u64, 0x0123456789ABCDEF), try r.readU64());
    try std.testing.expectEqual(@as(i32, -123456), try r.readI32());
    try std.testing.expectEqual(@as(f32, 3.14159), try r.readF32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "LeReader bounds-check returns Truncated, never panics" {
    // A 3-byte buffer cannot satisfy a u32 read.
    var r = LeReader.init(&[_]u8{ 1, 2, 3 });
    try std.testing.expectError(error.Truncated, r.readU32());
    // pos must NOT advance on a failed read.
    try std.testing.expectEqual(@as(usize, 0), r.pos);

    // readBytes / skip past the end also report Truncated.
    var r2 = LeReader.init(&[_]u8{ 1, 2 });
    try std.testing.expectError(error.Truncated, r2.readBytes(5));
    try std.testing.expectError(error.Truncated, r2.skip(3));

    // An overflowing length (near usize max) must not wrap — reports Truncated.
    var r3 = LeReader.init(&[_]u8{ 0, 0, 0, 0 });
    r3.pos = 2;
    try std.testing.expectError(error.Truncated, r3.readBytes(std.math.maxInt(usize)));
}

test "LeReader byte-exact little-endian decoding matches std.mem.writeInt" {
    // Known LE byte pattern for 0x44434241 = 'A','B','C','D'.
    const bytes = [_]u8{ 'A', 'B', 'C', 'D' };
    var r = LeReader.init(&bytes);
    try std.testing.expectEqual(@as(u32, 0x44434241), try r.readU32());

    // readBytes hands back a no-copy slice with exact contents.
    var r2 = LeReader.init("hello world");
    const head = try r2.readBytes(5);
    try std.testing.expectEqualSlices(u8, "hello", head);
    try std.testing.expectEqual(@as(usize, 6), r2.remaining());
}
