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
    std.debug.assert(HEADER_PREFIX_LEN == HEADER_LEN - 8); // header minus the u64 checksum
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
/// `skip_out` semantics (boundary trust):
///   - Truncated (header too short, or payload doesn't fit): boundary unknown →
///     `skip_out.*` left at 0.
///   - WrongMagic: boundary untrusted → `skip_out.*` left at 0.
///   - WrongVersion: boundary IS trusted (magic ok, payload fits) → `skip_out.*` = end,
///     so a version-aware scanner can advance to the next record.
///   - ChecksumMismatch: boundary trusted → `skip_out.*` = end.
///   - Success: `skip_out.*` = end (same value as Record.next).
///
/// Ordering of checks:
///   1. decode raw header fields; if buf too short → Truncated (skip_out stays 0).
///   2. check magic; mismatch → WrongMagic (skip_out stays 0).
///   3. compute plen / end with overflow guard; if payload doesn't fit → Truncated
///      (skip_out stays 0 — boundary untrusted).
///   4. boundary is now trusted: set skip_out.* = end.
///   5. check version; mismatch → WrongVersion (skip_out already = end).
///   6. verify checksum; mismatch → ChecksumMismatch (skip_out already = end).
///   7. success → return Record{...}.
pub fn readRecord(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
    skip_out: ?*usize,
) ChunkError!Record {
    // Step 0: clear skip_out (boundary unknown until proven otherwise).
    if (skip_out) |p| p.* = 0;

    // Step 1: decode raw header; requires HEADER_LEN bytes.
    if (buf.len < HEADER_LEN) return error.Truncated;
    const hdr = ChunkHeader{
        .magic = std.mem.readInt(u32, buf[0..4], .little),
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .type_flags = std.mem.readInt(u16, buf[8..10], .little),
        .payload_len = std.mem.readInt(u64, buf[10..18], .little),
        .checksum = std.mem.readInt(u64, buf[18..26], .little),
    };

    // Step 2: check magic; boundary untrusted on mismatch.
    if (hdr.magic != expect_magic) return error.WrongMagic;

    // Step 3: compute end; if payload doesn't fit, boundary untrusted.
    const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
    const end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
    if (buf.len < end) return error.Truncated;

    // Step 4: boundary is now trusted (magic ok, payload fits).
    if (skip_out) |p| p.* = end;

    // Step 5: check version; skip_out already holds the trusted boundary.
    if (hdr.version != expect_version) return error.WrongVersion;

    // Step 6: verify checksum.
    const payload = buf[HEADER_LEN..end];
    const want = ChunkHeader.computeChecksum(hdr.magic, hdr.version, hdr.type_flags, payload);
    if (want != hdr.checksum) return error.ChecksumMismatch;

    // Step 7: success.
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

// ===========================================================================
// Shared file framing — dedup of the [file-header ‖ body] envelope used by
// registry_io / scene_io (~5 copies of the same parse-and-verify boilerplate).
//
// A "file" is one outer ChunkHeader(TYPE_FILE_HEADER) over the whole body. The
// body itself holds either fixed-length records (registry_io) or count-prefixed
// per-record ChunkHeaders (scene_io). These helpers own ONLY the outer envelope;
// the per-record interpretation stays in the caller.
// ===========================================================================

/// type_flags value for a file-header chunk (the outer envelope).
pub const TYPE_FILE_HEADER: u16 = 0;
/// type_flags value for a data record chunk (per-record framing).
pub const TYPE_RECORD: u16 = 1;

/// Result of parsing a file envelope: the no-copy body slice plus its byte length
/// (callers use `plen` for fixed-record-count math).
pub const FileBody = struct {
    body: []const u8,
    plen: usize,
};

/// Parse the outer file header, bounds-check, and verify the file-level checksum.
/// On checksum MISMATCH this WARNS (per-record graceful recovery) instead of
/// erroring — it mirrors the registry_io/scene_io degradation policy verbatim.
/// Hard errors (Truncated / WrongMagic / WrongVersion) still propagate.
///
/// `name` is only used in the warn message (e.g. "flags.reg", "offmesh.bin").
pub fn fileBody(data: []const u8, magic: u32, version: u32, name: []const u8) ChunkError!FileBody {
    const hdr = try unpackHeader(data, magic, version);
    const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
    const body_end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
    if (body_end > data.len) return error.Truncated;
    const body = data[HEADER_LEN..body_end];
    const want = ChunkHeader.computeChecksum(magic, version, hdr.type_flags, body);
    if (want != hdr.checksum) {
        std.log.warn("persist: {s} file checksum mismatch — attempting per-record recovery", .{name});
    }
    return .{ .body = body, .plen = plen };
}

/// Like `fileBody` but tries `version` first and, on WrongVersion, falls back to
/// `legacy_version`. Returns the body + the detected version. Used by volumes.bin
/// (v2 current / v1 legacy). `info_on_legacy` (if non-null) is logged at info level
/// when the legacy path is taken.
pub fn fileBodyAnyVersion(
    data: []const u8,
    magic: u32,
    version: u32,
    legacy_version: u32,
    name: []const u8,
    info_on_legacy: ?[]const u8,
) ChunkError!struct { body: []const u8, plen: usize, version: u32 } {
    if (fileBody(data, magic, version, name)) |fb| {
        return .{ .body = fb.body, .plen = fb.plen, .version = version };
    } else |e1| {
        if (e1 != error.WrongVersion) return e1;
        const fb = try fileBody(data, magic, legacy_version, name);
        if (info_on_legacy) |msg| std.log.info("{s}", .{msg});
        return .{ .body = fb.body, .plen = fb.plen, .version = legacy_version };
    }
}

/// Append a length-framed record [ChunkHeader(magic, version, TYPE_RECORD, payload)]
/// ++ payload to `b`. The self-describing payload_len lets readRecord skip a corrupt
/// record independently (graceful per-record degradation). `Buf` is the caller's
/// `*std.array_list.Managed(u8)`.
pub fn appendRecord(b: anytype, magic: u32, version: u32, payload: []const u8) !void {
    const hdr = ChunkHeader.init(magic, version, TYPE_RECORD, payload).pack();
    try b.appendSlice(&hdr);
    try b.appendSlice(payload);
}

/// Assemble [ChunkHeader(magic, version, TYPE_FILE_HEADER, body)] ++ body into a
/// freshly-init'd ArrayList of `BufType` (caller's managed u8 list type). Caller
/// owns/deinits the returned list.
pub fn assembleFile(comptime BufType: type, alloc: std.mem.Allocator, magic: u32, version: u32, body: []const u8) !BufType {
    var out = BufType.init(alloc);
    errdefer out.deinit();
    const hdr_bytes = ChunkHeader.init(magic, version, TYPE_FILE_HEADER, body).pack();
    try out.appendSlice(&hdr_bytes);
    try out.appendSlice(body);
    return out;
}

/// Iterate count-prefixed per-record chunks in `body`.
///
/// Layout: body = [count:u32 LE] ++ (record × count), each record = readRecord-
/// parseable [ChunkHeader(magic, version)][payload]. For each successfully-parsed
/// record, `cb(ctx, payload)` is invoked. A record that fails readRecord is logged
/// and SKIPPED via its trusted skip offset; if the boundary is unknown (skip==0)
/// iteration breaks (cannot resync) — the canonical idiom shared by all scene_io
/// count-prefixed loops.
///
/// `cb` errors are logged-and-skipped (per-record degradation), NOT propagated,
/// matching the existing decodeVolumes/decodeOffMesh behavior.
pub fn forEachRecord(
    body: []const u8,
    magic: u32,
    version: u32,
    name: []const u8,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), []const u8) anyerror!void,
) ChunkError!void {
    // Count prefix is part of the body; a short body here is a hard Truncated.
    if (body.len < 4) return error.Truncated;
    const count = std.mem.readInt(u32, body[0..4], .little);
    var pos: usize = 4;
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        var skip: usize = 0;
        const rec = readRecord(body[pos..], magic, version, &skip) catch |e| {
            std.log.warn("persist: {s}: skipping bad record #{d}: {s}", .{ name, k, @errorName(e) });
            if (skip == 0) break; // boundary unknown — cannot resync
            pos += skip;
            continue;
        };
        pos += rec.next;
        cb(ctx, rec.payload) catch |e| {
            std.log.warn("persist: {s}: record #{d} dropped: {s}", .{ name, k, @errorName(e) });
            continue;
        };
    }
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

test "readRecord WrongMagic leaves skip_out at 0 (boundary untrusted)" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const body = [_]u8{ 1, 2, 3, 4 };
    // Build a valid chunk then corrupt the magic bytes in the serialized header.
    const chunk = try buildChunk(a, MAGIC, 1, 0x00, &body);
    defer a.free(chunk);
    // Flip low 16 bits of the magic field (bytes 0..4, LE).
    std.mem.writeInt(u32, chunk[0..4], MAGIC ^ 0xFFFF, .little);
    var skip: usize = 12345;
    try std.testing.expectError(error.WrongMagic, readRecord(chunk, MAGIC, 1, &skip));
    try std.testing.expectEqual(@as(usize, 0), skip);
}

test "readRecord WrongVersion reports skip offset for version-aware scan" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const body = [_]u8{ 1, 2, 3, 4 };
    // Write version 2 on disk; reader expects version 1.
    const chunk = try buildChunk(a, MAGIC, 2, 0x00, &body);
    defer a.free(chunk);
    var skip: usize = 0;
    try std.testing.expectError(error.WrongVersion, readRecord(chunk, MAGIC, 1, &skip));
    try std.testing.expectEqual(@as(usize, HEADER_LEN + body.len), skip);
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
