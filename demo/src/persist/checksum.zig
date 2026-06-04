//! Persist Module 1 — checksum + self-describing chunk-header.
//! Hash: std.hash.XxHash3 (confirmed in Zig 0.16, seed = 0). Not cryptographic —
//! only for bitrot / torn-write detection (see docs/research/persistence-durability-research.md).
//! Chunk header: magic|version|type_flags|payload_len|checksum (PNG/glTF model).
//!
//! On-disk encoding is LITTLE-ENDIAN, field-by-field (NOT raw struct layout), so the
//! format is portable across machines independent of host ABI/alignment.
//!
//! LOCKED INTERFACE: XXH3 only (no CRC32 Algo enum — dropped as YAGNI). checksum domain =
//! (type_flags bytes ‖ header-without-checksum bytes ‖ payload bytes).

const std = @import("std");

/// Hash seed fixed for determinism across runs/machines.
pub const HASH_SEED: u64 = 0;

/// Checksum of arbitrary bytes (XXH3, seed = HASH_SEED). u64.
pub fn checksum(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(HASH_SEED, bytes);
}

/// Chunk-parse errors. Truncated/WrongMagic/WrongVersion mirror navmesh_io.zig
/// (single Persist error vocabulary). ChecksumMismatch is new.
pub const ChunkError = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
};

// Individually pub-exported for callers that name them directly.
pub const Truncated = ChunkError.Truncated;
pub const WrongMagic = ChunkError.WrongMagic;
pub const WrongVersion = ChunkError.WrongVersion;
pub const ChecksumMismatch = ChunkError.ChecksumMismatch;

/// Serialized header size in bytes: 4(magic)+4(version)+2(type_flags)+8(payload_len)+8(checksum) = 26.
pub const HEADER_LEN: usize = 4 + 4 + 2 + 8 + 8;
comptime {
    // Lock the on-disk header size; a field-encoding change must be deliberate.
    std.debug.assert(HEADER_LEN == 26);
}

/// Header-prefix length (header WITHOUT the trailing checksum field).
const HEADER_PREFIX_LEN: usize = 4 + 4 + 2 + 8; // = 18

pub const ChunkHeader = struct {
    magic: u32,
    version: u32,
    type_flags: u16,
    payload_len: u64, // BYTE length of payload
    checksum: u64,

    /// Compute checksum over the LOCKED domain:
    ///   XXH3( type_flags(LE,2B) ‖ header-without-checksum(LE,18B) ‖ payload ).
    /// type_flags is hashed twice on purpose (leading tf, then again inside the
    /// header prefix) — this reproduces the owner-interface formula verbatim and
    /// pins the contract; it is harmless for collision resistance.
    pub fn computeChecksum(magic: u32, version: u32, type_flags: u16, payload: []const u8) u64 {
        var h = std.hash.XxHash3.init(HASH_SEED);

        // leading type_flags (LE)
        var tf: [2]u8 = undefined;
        std.mem.writeInt(u16, &tf, type_flags, .little);
        h.update(&tf);

        // header prefix (magic|version|type_flags|payload_len), LE, field-by-field
        var pre: [HEADER_PREFIX_LEN]u8 = undefined;
        std.mem.writeInt(u32, pre[0..4], magic, .little);
        std.mem.writeInt(u32, pre[4..8], version, .little);
        std.mem.writeInt(u16, pre[8..10], type_flags, .little);
        std.mem.writeInt(u64, pre[10..18], @as(u64, payload.len), .little);
        h.update(&pre);

        h.update(payload);
        return h.final();
    }

    /// Build a header for `payload` (checksum computed here).
    pub fn init(magic: u32, version: u32, type_flags: u16, payload: []const u8) ChunkHeader {
        return .{
            .magic = magic,
            .version = version,
            .type_flags = type_flags,
            .payload_len = payload.len,
            .checksum = computeChecksum(magic, version, type_flags, payload),
        };
    }

    /// Serialize the header into HEADER_LEN bytes (LE, field-by-field).
    pub fn pack(self: ChunkHeader) [HEADER_LEN]u8 {
        var out: [HEADER_LEN]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], self.magic, .little);
        std.mem.writeInt(u32, out[4..8], self.version, .little);
        std.mem.writeInt(u16, out[8..10], self.type_flags, .little);
        std.mem.writeInt(u64, out[10..18], self.payload_len, .little);
        std.mem.writeInt(u64, out[18..26], self.checksum, .little);
        return out;
    }
};

/// Parse the header from the leading HEADER_LEN bytes. Checks magic/version.
/// Does NOT verify checksum (payload may not be present in `buf`).
pub fn unpackHeader(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
) ChunkError!ChunkHeader {
    if (buf.len < HEADER_LEN) return error.Truncated;
    const hdr = ChunkHeader{
        .magic = std.mem.readInt(u32, buf[0..4], .little),
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .type_flags = std.mem.readInt(u16, buf[8..10], .little),
        .payload_len = std.mem.readInt(u64, buf[10..18], .little),
        .checksum = std.mem.readInt(u64, buf[18..26], .little),
    };
    if (hdr.magic != expect_magic) return error.WrongMagic;
    if (hdr.version != expect_version) return error.WrongVersion;
    return hdr;
}

/// Result of a per-record read: the parsed header, the payload slice (no-copy,
/// pointing into `buf`), and `next` = offset of the byte just past this record.
/// On ChecksumMismatch the caller still wants `next` to SKIP to the following
/// record — `readRecord` reports it via the error path (see below).
pub const Record = struct {
    header: ChunkHeader,
    payload: []const u8,
    /// Offset in `buf` just past [header|payload] for this record.
    next: usize,
};

/// Read ONE record [header|payload] starting at `buf[0]`.
///
/// Success: returns Record (payload no-copy slice into buf, `next` = HEADER_LEN+payload_len).
///
/// ChecksumMismatch: the header itself was structurally valid (magic/version/length
/// all fit), but the payload bytes do not match the stored checksum. The caller MUST
/// be able to skip this corrupt record and continue with the next one. To enable that,
/// the *recoverable* skip offset is delivered out-of-band via `skip_out.*` (set to
/// HEADER_LEN + payload_len) whenever a non-null `skip_out` is supplied. On any other
/// error (Truncated/WrongMagic/WrongVersion) `skip_out.*` is left 0 because the record
/// boundary is unknown/untrusted and the stream cannot be safely resynchronized.
pub fn readRecord(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
    skip_out: ?*usize,
) ChunkError!Record {
    if (skip_out) |p| p.* = 0;

    const hdr = try unpackHeader(buf, expect_magic, expect_version);
    const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
    const end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
    if (buf.len < end) return error.Truncated;

    const payload = buf[HEADER_LEN..end];

    // Declared length is consistent with the buffer: the record boundary IS known,
    // so even on checksum failure the caller can skip exactly `end` bytes.
    if (skip_out) |p| p.* = end;

    const want = ChunkHeader.computeChecksum(hdr.magic, hdr.version, hdr.type_flags, payload);
    if (want != hdr.checksum) return error.ChecksumMismatch;

    return .{ .header = hdr, .payload = payload, .next = end };
}

/// Full parse of one chunk [header|payload]: return the payload slice (no-copy),
/// verifying length and checksum. Convenience wrapper over readRecord for callers
/// that only want the payload and do not need the skip offset.
pub fn parseChunk(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
) ChunkError![]const u8 {
    const rec = try readRecord(buf, expect_magic, expect_version, null);
    return rec.payload;
}

/// Serialize a whole chunk [header|payload] into an owned buffer.
pub fn buildChunk(
    alloc: std.mem.Allocator,
    magic: u32,
    version: u32,
    type_flags: u16,
    payload: []const u8,
) ![]u8 {
    const hdr = ChunkHeader.init(magic, version, type_flags, payload);
    const out = try alloc.alloc(u8, HEADER_LEN + payload.len);
    const packed_hdr = hdr.pack();
    @memcpy(out[0..HEADER_LEN], &packed_hdr);
    @memcpy(out[HEADER_LEN..], payload);
    return out;
}

// ---------------------------------------------------------------------------
// Tests (pure logic — `zig test demo/src/persist/checksum.zig`).
// ---------------------------------------------------------------------------

test "checksum determinism and single-byte sensitivity" {
    const a = "recast-persist-chunk";
    try std.testing.expectEqual(checksum(a), checksum(a)); // deterministic
    var b = a.*;
    b[0] ^= 0x01;
    try std.testing.expect(checksum(a) != checksum(&b)); // avalanche on one byte
    _ = checksum(""); // empty input must not panic
}

test "HEADER_LEN is the locked 26-byte field encoding" {
    try std.testing.expectEqual(@as(usize, 26), HEADER_LEN);
    const hdr = ChunkHeader.init(0x41524541, 1, 0x00, "abc");
    const bytes = hdr.pack();
    try std.testing.expectEqual(@as(usize, HEADER_LEN), bytes.len);
}

test "chunk pack/unpack round-trip" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541; // 'AREA' example domain
    const VERSION: u32 = 1;
    const payload = "hello durable world";
    const chunk = try buildChunk(a, MAGIC, VERSION, 0x00, payload);
    defer a.free(chunk);

    const got = try parseChunk(chunk, MAGIC, VERSION);
    try std.testing.expectEqualSlices(u8, payload, got);

    // wrong magic / version
    try std.testing.expectError(error.WrongMagic, parseChunk(chunk, 0xDEADBEEF, VERSION));
    try std.testing.expectError(error.WrongVersion, parseChunk(chunk, MAGIC, 2));
}

test "chunk corruption detect -> ChecksumMismatch, with per-record skip offset" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const payload = "payload-bytes-xyz";
    const chunk = try buildChunk(a, MAGIC, 1, 0x00, payload);
    defer a.free(chunk);

    // corrupt one payload byte
    chunk[HEADER_LEN + 3] ^= 0x40;
    try std.testing.expectError(error.ChecksumMismatch, parseChunk(chunk, MAGIC, 1));

    // readRecord must still hand back the skip offset so the caller can advance
    // past this corrupt record and continue with the next one.
    var skip: usize = 12345;
    const r = readRecord(chunk, MAGIC, 1, &skip);
    try std.testing.expectError(error.ChecksumMismatch, r);
    try std.testing.expectEqual(@as(usize, HEADER_LEN + payload.len), skip);
}

test "truncated header and truncated payload" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const chunk = try buildChunk(a, MAGIC, 1, 0x00, "0123456789");
    defer a.free(chunk);
    try std.testing.expectError(error.Truncated, parseChunk(chunk[0 .. HEADER_LEN - 1], MAGIC, 1));
    try std.testing.expectError(error.Truncated, parseChunk(chunk[0 .. HEADER_LEN + 2], MAGIC, 1));

    // On a truncated/unknown-boundary record, skip_out stays 0 (cannot resync).
    var skip: usize = 999;
    _ = readRecord(chunk[0 .. HEADER_LEN - 1], MAGIC, 1, &skip) catch {};
    try std.testing.expectEqual(@as(usize, 0), skip);
}

test "readRecord success reports next offset for sequential scan" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const p0 = "first";
    const p1 = "second-record";
    const c0 = try buildChunk(a, MAGIC, 1, 0x00, p0);
    defer a.free(c0);
    const c1 = try buildChunk(a, MAGIC, 1, 0x00, p1);
    defer a.free(c1);

    const stream = try a.alloc(u8, c0.len + c1.len);
    defer a.free(stream);
    @memcpy(stream[0..c0.len], c0);
    @memcpy(stream[c0.len..], c1);

    const r0 = try readRecord(stream, MAGIC, 1, null);
    try std.testing.expectEqualSlices(u8, p0, r0.payload);
    try std.testing.expectEqual(@as(usize, HEADER_LEN + p0.len), r0.next);

    const r1 = try readRecord(stream[r0.next..], MAGIC, 1, null);
    try std.testing.expectEqualSlices(u8, p1, r1.payload);
}
