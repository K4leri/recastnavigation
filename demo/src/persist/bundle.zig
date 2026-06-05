//! Persist — single-file `.recastbundle` archive (cluster I / I-2).
//!
//! A bundle is ONE buffer holding a set of named blobs (the files of a scene
//! directory `.recastscene/` plus the `repro/` section). This module is the
//! PURE core: memory -> memory only. NO file I/O lives here — `pack` takes a
//! list of (name, bytes) and returns one owned buffer; `unpack` takes a buffer
//! and hands back the entries. Higher layers do the actual disk reading/writing.
//!
//! On-buffer encoding is LITTLE-ENDIAN, field-by-field (std.mem.writeInt/readInt
//! `.little`), so the format is portable across machines independent of host
//! ABI/alignment. Names are arbitrary bytes (may contain '/'), length-prefixed.
//!
//! Checksum: std.hash.XxHash32 (confirmed in Zig 0.16, seed = 0). Returns u32,
//! which matches the on-buffer `data_crc u32` field. Not cryptographic — only
//! for bitrot / torn-write / corruption detection. Computed over each blob's
//! `data`; verified on every entry during `unpack` -> error.BundleCorrupt on
//! mismatch.
//!
//! LAYOUT (all integers LE):
//!   Header:
//!     magic        u32  = 'RBND' (0x444E4252 as a LE u32 of the ASCII bytes 'R','B','N','D')
//!     version      u32  = 1
//!     entry_count  u32
//!   Entry table (entry_count records, in the exact order passed to `pack`):
//!     name_len     u32
//!     name         name_len bytes
//!     data_len     u64
//!     data_crc     u32   (XxHash32 of the data bytes)
//!   Data section (after the WHOLE table): the data blocks back-to-back, in the
//!     same order as the table. (Table-then-data layout: a reader can scan all
//!     headers/checksums without touching payloads.)
//!
//! Determinism: entries are written in the order given (caller sorts if it wants
//! a canonical order); identical input -> byte-identical output.

const std = @import("std");

/// Magic identifying a `.recastbundle` buffer: ASCII 'R','B','N','D' read as a
/// little-endian u32.
pub const MAGIC: u32 = std.mem.readInt(u32, "RBND", .little);

/// Current bundle format version.
pub const VERSION: u32 = 1;

/// Hash seed fixed for determinism across runs/machines.
pub const HASH_SEED: u32 = 0;

/// Checksum of a data blob (XxHash32, seed = HASH_SEED). u32.
fn crc(bytes: []const u8) u32 {
    return std.hash.XxHash32.hash(HASH_SEED, bytes);
}

pub const Error = error{
    BundleBadMagic,
    BundleBadVersion,
    BundleTruncated,
    BundleCorrupt,
};

pub const Entry = struct {
    name: []const u8, // relative path inside the bundle, e.g. "scene.gset" or "repro/query.json"
    data: []const u8, // contents
};

// Header field offsets / sizes.
const MAGIC_LEN = 4;
const VERSION_LEN = 4;
const COUNT_LEN = 4;
const HEADER_LEN = MAGIC_LEN + VERSION_LEN + COUNT_LEN; // 12
// Per-entry table record fixed overhead (excluding the variable-length name).
const NAME_LEN_FIELD = 4;
const DATA_LEN_FIELD = 8;
const DATA_CRC_FIELD = 4;

/// Pack `entries` into one owned `.recastbundle` buffer (caller frees with `alloc`).
/// Entries are written in the order given (deterministic; caller sorts if desired).
pub fn pack(alloc: std.mem.Allocator, entries: []const Entry) ![]u8 {
    // Compute total size up front (overflow-safe via u64 accumulation, then cast).
    var total: u64 = HEADER_LEN;
    for (entries) |e| {
        total += NAME_LEN_FIELD;
        total += @as(u64, e.name.len);
        total += DATA_LEN_FIELD;
        total += DATA_CRC_FIELD;
        total += @as(u64, e.data.len);
    }
    const total_usize = std.math.cast(usize, total) orelse return error.OutOfMemory;

    const out = try alloc.alloc(u8, total_usize);
    errdefer alloc.free(out);

    var off: usize = 0;
    // Header.
    std.mem.writeInt(u32, out[off..][0..4], MAGIC, .little);
    off += 4;
    std.mem.writeInt(u32, out[off..][0..4], VERSION, .little);
    off += 4;
    std.mem.writeInt(u32, out[off..][0..4], @intCast(entries.len), .little);
    off += 4;

    // Entry table.
    for (entries) |e| {
        std.mem.writeInt(u32, out[off..][0..4], @intCast(e.name.len), .little);
        off += 4;
        @memcpy(out[off..][0..e.name.len], e.name);
        off += e.name.len;
        std.mem.writeInt(u64, out[off..][0..8], @as(u64, e.data.len), .little);
        off += 8;
        std.mem.writeInt(u32, out[off..][0..4], crc(e.data), .little);
        off += 4;
    }

    // Data section (in table order).
    for (entries) |e| {
        @memcpy(out[off..][0..e.data.len], e.data);
        off += e.data.len;
    }

    std.debug.assert(off == total_usize);
    return out;
}

/// Lightweight bounds-checked cursor over the input buffer. Every read validates
/// the requested span fits — never panics on a truncated/corrupt buffer.
const Cursor = struct {
    buf: []const u8,
    off: usize = 0,

    fn readU32(self: *Cursor) Error!u32 {
        if (self.off + 4 > self.buf.len) return error.BundleTruncated;
        const v = std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
        self.off += 4;
        return v;
    }

    fn readU64(self: *Cursor) Error!u64 {
        if (self.off + 8 > self.buf.len) return error.BundleTruncated;
        const v = std.mem.readInt(u64, self.buf[self.off..][0..8], .little);
        self.off += 8;
        return v;
    }

    fn readBytes(self: *Cursor, n: usize) Error![]const u8 {
        // Overflow-safe end computation.
        const end = std.math.add(usize, self.off, n) catch return error.BundleTruncated;
        if (end > self.buf.len) return error.BundleTruncated;
        const s = self.buf[self.off..end];
        self.off = end;
        return s;
    }
};

pub const Unpacked = struct {
    entries: []Entry, // name/data point into `arena`-owned copies
    arena: std.heap.ArenaAllocator, // owns entries slice + every name/data buffer

    pub fn deinit(self: *Unpacked) void {
        self.arena.deinit();
    }

    /// Return the contents of the entry with the given `name`, or null.
    pub fn find(self: *const Unpacked, name: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.data;
        }
        return null;
    }
};

/// Unpack a `.recastbundle` buffer. Validates magic/version, and for EVERY entry
/// re-computes and compares `data_crc` -> error.BundleCorrupt on mismatch. Any
/// out-of-bounds / truncated read -> error.BundleTruncated. Bad magic/version ->
/// error.BundleBadMagic / error.BundleBadVersion. Never panics on a bad buffer.
///
/// The returned `Unpacked` owns all memory through an arena; `deinit` frees it all
/// at once. `alloc` is the backing allocator for that arena.
pub fn unpack(alloc: std.mem.Allocator, bytes: []const u8) !Unpacked {
    var cur = Cursor{ .buf = bytes };

    // Header.
    const magic = try cur.readU32();
    if (magic != MAGIC) return error.BundleBadMagic;
    const version = try cur.readU32();
    if (version != VERSION) return error.BundleBadVersion;
    const count = try cur.readU32();

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const entries = try a.alloc(Entry, count);

    // Parse the entry table. Names are copied into the arena here; data offsets/
    // lengths are recorded so we can copy & verify from the data section after.
    const DataRef = struct { len: usize, crc: u32 };
    const refs = try a.alloc(DataRef, count);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name_len = try cur.readU32();
        const name_src = try cur.readBytes(name_len);
        const name_copy = try a.dupe(u8, name_src);

        const data_len = try cur.readU64();
        const data_len_usize = std.math.cast(usize, data_len) orelse return error.BundleTruncated;
        const data_crc = try cur.readU32();

        entries[i] = .{ .name = name_copy, .data = &[_]u8{} };
        refs[i] = .{ .len = data_len_usize, .crc = data_crc };
    }

    // Data section follows the whole table, in table order.
    i = 0;
    while (i < count) : (i += 1) {
        const data_src = try cur.readBytes(refs[i].len);
        if (crc(data_src) != refs[i].crc) return error.BundleCorrupt;
        entries[i].data = try a.dupe(u8, data_src);
    }

    return .{ .entries = entries, .arena = arena };
}

// ---------------------------------------------------------------------------
// Tests (pure logic — `zig test demo/src/persist/bundle.zig`).
// ---------------------------------------------------------------------------

test "round-trip: 3 entries incl '/', empty data, full-range binary bytes" {
    const a = std.testing.allocator;

    // A data blob containing every byte value 0..255.
    var all_bytes: [256]u8 = undefined;
    for (0..256) |k| all_bytes[k] = @intCast(k);

    const entries = [_]Entry{
        .{ .name = "scene.gset", .data = "the quick brown fox" },
        .{ .name = "repro/query.json", .data = "" }, // empty data
        .{ .name = "binary.blob", .data = &all_bytes }, // all 256 byte values
    };

    const buf = try pack(a, &entries);
    defer a.free(buf);

    var up = try unpack(a, buf);
    defer up.deinit();

    try std.testing.expectEqual(@as(usize, 3), up.entries.len);

    const d0 = up.find("scene.gset") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, "the quick brown fox", d0);

    const d1 = up.find("repro/query.json") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, "", d1);
    try std.testing.expectEqual(@as(usize, 0), d1.len);

    const d2 = up.find("binary.blob") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &all_bytes, d2);
}

test "empty list packs and unpacks to zero entries" {
    const a = std.testing.allocator;
    const buf = try pack(a, &[_]Entry{});
    defer a.free(buf);

    // A valid but empty bundle is just the 12-byte header.
    try std.testing.expectEqual(@as(usize, HEADER_LEN), buf.len);

    var up = try unpack(a, buf);
    defer up.deinit();
    try std.testing.expectEqual(@as(usize, 0), up.entries.len);
    try std.testing.expectEqual(@as(?[]const u8, null), up.find("anything"));
}

test "corrupting one data byte -> BundleCorrupt" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        .{ .name = "a", .data = "AAAA" },
        .{ .name = "b", .data = "BBBBBBBB" },
    };
    const buf = try pack(a, &entries);
    defer a.free(buf);

    // The data section is at the tail; flip a byte there.
    buf[buf.len - 2] ^= 0x40;
    try std.testing.expectError(error.BundleCorrupt, unpack(a, buf));
}

test "truncated buffer -> BundleTruncated (no panic)" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        .{ .name = "name-one", .data = "0123456789" },
    };
    const buf = try pack(a, &entries);
    defer a.free(buf);

    // Cut off the tail (loses part of the data section).
    try std.testing.expectError(error.BundleTruncated, unpack(a, buf[0 .. buf.len - 3]));

    // Cut into the header too.
    try std.testing.expectError(error.BundleTruncated, unpack(a, buf[0..5]));

    // Empty buffer.
    try std.testing.expectError(error.BundleTruncated, unpack(a, &[_]u8{}));
}

test "bad magic -> BundleBadMagic" {
    const a = std.testing.allocator;
    const buf = try pack(a, &[_]Entry{});
    defer a.free(buf);

    buf[0] ^= 0xFF; // corrupt magic
    try std.testing.expectError(error.BundleBadMagic, unpack(a, buf));
}

test "bad version -> BundleBadVersion" {
    const a = std.testing.allocator;
    const buf = try pack(a, &[_]Entry{});
    defer a.free(buf);

    std.mem.writeInt(u32, buf[4..8], 999, .little);
    try std.testing.expectError(error.BundleBadVersion, unpack(a, buf));
}

test "find of a missing name returns null" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        .{ .name = "present", .data = "x" },
    };
    const buf = try pack(a, &entries);
    defer a.free(buf);

    var up = try unpack(a, buf);
    defer up.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), up.find("absent"));
    try std.testing.expect(up.find("present") != null);
}

test "determinism: two packs of the same entries are byte-identical" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        .{ .name = "scene.gset", .data = "data-1" },
        .{ .name = "repro/q.json", .data = "data-22" },
        .{ .name = "z", .data = "" },
    };
    const b1 = try pack(a, &entries);
    defer a.free(b1);
    const b2 = try pack(a, &entries);
    defer a.free(b2);
    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "large (u64-length) data blob round-trips" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 100_000);
    defer a.free(big);
    for (big, 0..) |*p, k| p.* = @intCast(k & 0xFF);

    const entries = [_]Entry{
        .{ .name = "big", .data = big },
    };
    const buf = try pack(a, &entries);
    defer a.free(buf);

    var up = try unpack(a, buf);
    defer up.deinit();
    const got = up.find("big") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, big, got);
}
