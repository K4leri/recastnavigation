//! Persist — bundle_io: file-side wiring over the pure `bundle.zig` core
//! (cluster I / I-2). Turns a `.recastscene` CONTAINER on disk plus an optional
//! repro section into one self-contained `.recastbundle` file, and back.
//!
//! LAYOUT DECISION (investigated, see scene_container.zig):
//!   `.recastscene` is a DIRECTORY (scene.gset, edits/*, tiles/*, manifest), NOT a
//!   single file. So we cannot just pack one file. scene_io.zig already provides a
//!   portable directory<->bytes archiver (packArchiveToBytes / unpackArchiveFromBytes,
//!   chunk-framed, path-traversal-safe). We reuse it: the whole container directory is
//!   serialized into ONE archive blob and stored as a single bundle entry:
//!
//!     bundle entry "scene.recastarchive"  = scene_io.packArchiveToBytes(<container dir>)
//!     bundle entry "repro/query.json"     = repro_json   (only if provided)
//!
//!   On import we unpack the bundle, write the archive blob back out to a fresh
//!   `<stem>.recastscene/` directory under dest_dir via unpackArchiveFromBytes, and
//!   return that container path (ready for loadSceneNow / scene_container.loadScene).
//!
//! ERRORS: bundle corruption (BundleCorrupt / BundleTruncated / BundleBadMagic /
//! BundleBadVersion) is propagated unchanged. Archive path-escape is rejected by
//! scene_io (ArchivePathEscape). I/O uses the Threaded backend + cwd Dir, exactly
//! like io_util.zig and the persist tests.

const std = @import("std");
const bundle = @import("bundle.zig");
const scene_io = @import("scene_io.zig");
const write_atomic = @import("write_atomic.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Entry name (inside the bundle) holding the whole scene-container archive blob.
pub const SCENE_ARCHIVE_ENTRY = "scene.recastarchive";
/// Entry name holding the optional repro JSON.
pub const REPRO_ENTRY = "repro/query.json";

pub const Error = error{
    /// out_bundle_path / scene_container_path had no usable file/dir name.
    BadPath,
} || bundle.Error || std.mem.Allocator.Error;

/// Return the final path component (basename) of `path`, splitting on '/' and '\\'.
fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') start = i + 1;
    }
    return path[start..];
}

/// Pack a `.recastscene` CONTAINER directory (+ optional repro JSON) into one owned
/// `.recastbundle` file at `out_bundle_path`.
///
/// `scene_container_path` — the on-disk `<...>.recastscene/` directory (the same path
///   saveSceneNow / loadSceneNow use). Read recursively into one archive blob.
/// `repro_json`           — optional repro payload; stored as entry "repro/query.json".
/// `out_bundle_path`      — destination `.recastbundle` file (overwritten atomically).
pub fn exportBundle(
    alloc: std.mem.Allocator,
    scene_container_path: []const u8,
    repro_json: ?[]const u8,
    out_bundle_path: []const u8,
) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1) Archive the whole container directory into one portable blob.
    var src = try Dir.cwd().openDir(io, scene_container_path, .{ .iterate = true });
    defer src.close(io);
    var archive = try scene_io.packArchiveToBytes(io, alloc, src);
    defer archive.deinit();

    // 2) Assemble bundle entries (scene archive, then optional repro).
    var entries = std.array_list.Managed(bundle.Entry).init(alloc);
    defer entries.deinit();
    try entries.append(.{ .name = SCENE_ARCHIVE_ENTRY, .data = archive.items });
    if (repro_json) |rj| try entries.append(.{ .name = REPRO_ENTRY, .data = rj });

    // 3) Pack -> owned buffer, then write to disk (parent dir of out_bundle_path
    //    must already exist; the meshes folder always does).
    const packed_bytes = try bundle.pack(alloc, entries.items);
    defer alloc.free(packed_bytes);

    try Dir.cwd().writeFile(io, .{ .sub_path = out_bundle_path, .data = packed_bytes });
}

/// Result of importBundle: the restored container path (ready for loadScene) plus an
/// optional copy of the repro JSON. All owned — free with `deinit`.
pub const ImportResult = struct {
    /// "<dest_dir>/<stem>.recastscene" — owned.
    scene_container_path: []u8,
    /// Owned copy of the repro JSON, or null if the bundle had none.
    repro_json: ?[]u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ImportResult) void {
        self.alloc.free(self.scene_container_path);
        if (self.repro_json) |rj| self.alloc.free(rj);
        self.* = undefined;
    }
};

/// Unpack a `.recastbundle` file: restore the scene container directory on disk under
/// `dest_dir` and return its path (+ optional repro JSON copy).
///
/// `bundle_path` — the `.recastbundle` file to read.
/// `dest_dir`    — directory under which to materialize "<stem>.recastscene/". The
///   stem is derived from the bundle file name (e.g. "world.recastbundle" ->
///   "world.recastscene"); falls back to "imported" if the name has no usable stem.
///
/// Bundle corruption errors propagate. The restored container is ready to hand to
/// scene_container.loadScene / loadSceneNow.
pub fn importBundle(
    alloc: std.mem.Allocator,
    bundle_path: []const u8,
    dest_dir: []const u8,
) !ImportResult {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1) Read + unpack the bundle (validates magic/version/checksums).
    const raw = try Dir.cwd().readFileAlloc(io, bundle_path, alloc, .unlimited);
    defer alloc.free(raw);
    var up = try bundle.unpack(alloc, raw);
    defer up.deinit();

    const archive = up.find(SCENE_ARCHIVE_ENTRY) orelse return error.BundleTruncated;

    // 2) Derive the destination container path "<dest_dir>/<stem>.recastscene".
    const base = baseName(bundle_path);
    const stem = blk: {
        const ext = ".recastbundle";
        if (std.mem.endsWith(u8, base, ext) and base.len > ext.len)
            break :blk base[0 .. base.len - ext.len];
        if (base.len > 0) break :blk base;
        break :blk "imported";
    };
    const container_path = try std.fmt.allocPrint(alloc, "{s}/{s}.recastscene", .{ dest_dir, stem });
    errdefer alloc.free(container_path);

    // 3) Create the container directory and unpack the archive blob into it.
    var dst = try write_atomic.openContainerDir(io, Dir.cwd(), container_path);
    defer dst.close(io);
    try scene_io.unpackArchiveFromBytes(io, archive, dst);

    // 4) Copy the optional repro section into an owned buffer (outlives `up`).
    var repro_copy: ?[]u8 = null;
    errdefer if (repro_copy) |rc| alloc.free(rc);
    if (up.find(REPRO_ENTRY)) |rj| repro_copy = try alloc.dupe(u8, rj);

    return .{
        .scene_container_path = container_path,
        .repro_json = repro_copy,
        .alloc = alloc,
    };
}

// ---------------------------------------------------------------------------
// Tests — full disk round-trip through a tmp dir (Threaded io via std.testing.io
// is NOT used here because export/import open their own Threaded backend; we drive
// real cwd-relative paths under a tmp dir created with std.testing).
// Run aggregated via demo-test, or standalone:
//   & "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/persist/bundle_io.zig
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bundle_io baseName handles / and \\ and bare names" {
    try testing.expectEqualStrings("world.recastbundle", baseName("a/b/world.recastbundle"));
    try testing.expectEqualStrings("world.recastbundle", baseName("a\\b\\world.recastbundle"));
    try testing.expectEqualStrings("world.recastbundle", baseName("world.recastbundle"));
    try testing.expectEqualStrings("", baseName("a/b/"));
}

/// Make a unique cwd-relative scratch directory and return its owned path. We address
/// it cwd-relative (not via realpath, which Io.Dir lacks in 0.16) so the string paths
/// passed to export/import — which resolve against cwd — work directly. Caller removes
/// it with `Dir.cwd().deleteTree(io, path)`.
fn makeScratch(alloc: std.mem.Allocator, io: Io, tag: []const u8) ![]u8 {
    const ns: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.now(.awake, io).nanoseconds)));
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bundle_io_{s}_{x}", .{ tag, ns });
    errdefer alloc.free(path);
    try Dir.cwd().createDirPath(io, path);
    return path;
}

test "exportBundle -> importBundle round-trip restores container files + repro" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Build a minimal `.recastscene` container by hand (scene.gset + a nested edits/
    // file) under a cwd-relative scratch dir, so we don't depend on a full saveScene.
    const scratch = try makeScratch(alloc, io, "rt");
    defer alloc.free(scratch);
    defer Dir.cwd().deleteTree(io, scratch) catch {};

    const container = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "src.recastscene" });
    defer alloc.free(container);
    {
        var c = try write_atomic.openContainerDir(io, Dir.cwd(), container);
        defer c.close(io);
        try c.writeFile(io, .{ .sub_path = "scene.gset", .data = "f mesh.obj\n" });
        try c.createDirPath(io, "edits");
        try c.writeFile(io, .{ .sub_path = "edits/volumes.bin", .data = "\x01\x02\x03\x04" });
    }

    const bundle_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "world.recastbundle" });
    defer alloc.free(bundle_path);

    const repro = "{\"query\":\"findPath\"}";
    try exportBundle(alloc, container, repro, bundle_path);

    // Import into a fresh dest under the same scratch dir.
    const dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "restored" });
    defer alloc.free(dest);
    var res = try importBundle(alloc, bundle_path, dest);
    defer res.deinit();

    // Restored container path is "<dest>/world.recastscene".
    try testing.expect(std.mem.endsWith(u8, res.scene_container_path, "world.recastscene"));
    try testing.expect(res.repro_json != null);
    try testing.expectEqualStrings(repro, res.repro_json.?);

    // Files round-tripped byte-for-byte.
    var rc = try Dir.cwd().openDir(io, res.scene_container_path, .{});
    defer rc.close(io);
    const gset = try rc.readFileAlloc(io, "scene.gset", alloc, .unlimited);
    defer alloc.free(gset);
    try testing.expectEqualStrings("f mesh.obj\n", gset);
    const vol = try rc.readFileAlloc(io, "edits/volumes.bin", alloc, .unlimited);
    defer alloc.free(vol);
    try testing.expectEqualSlices(u8, "\x01\x02\x03\x04", vol);
}

test "importBundle propagates BundleCorrupt on a flipped data byte" {
    const alloc = testing.allocator;
    const io = testing.io;

    const scratch = try makeScratch(alloc, io, "corrupt");
    defer alloc.free(scratch);
    defer Dir.cwd().deleteTree(io, scratch) catch {};

    const container = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "c.recastscene" });
    defer alloc.free(container);
    {
        var c = try write_atomic.openContainerDir(io, Dir.cwd(), container);
        defer c.close(io);
        try c.writeFile(io, .{ .sub_path = "scene.gset", .data = "f mesh.obj\n" });
    }
    const bundle_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "c.recastbundle" });
    defer alloc.free(bundle_path);
    try exportBundle(alloc, container, null, bundle_path);

    // Corrupt the last byte (in the data section) and re-write.
    const raw = try Dir.cwd().readFileAlloc(io, bundle_path, alloc, .unlimited);
    defer alloc.free(raw);
    raw[raw.len - 1] ^= 0xFF;
    try Dir.cwd().writeFile(io, .{ .sub_path = bundle_path, .data = raw });

    const dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scratch, "out" });
    defer alloc.free(dest);
    try testing.expectError(error.BundleCorrupt, importBundle(alloc, bundle_path, dest));
}
