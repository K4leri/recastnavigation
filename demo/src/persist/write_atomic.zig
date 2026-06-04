//! Persist Module 1 — durable atomic write.
//!
//! Recipe (POSIX): createFileAtomic(replace=true) -> writeAll -> flush
//!   -> EXPLICIT File.sync (fsync) [EIO fatal -> DurabilityFailed, NO retry]
//!   -> replace (atomic rename) -> dirFsync(parent directory).
//! Windows: File.sync = FlushFileBuffers; replace -> rename via NtSetInformationFile;
//!   dirFsync = no-op (NTFS journals the rename metadata; there is no dir-fsync).
//! macOS F_FULLFSYNC is OUT OF SCOPE (target OS = Windows/Linux).
//!
//! Closes three stdlib gaps: `File.Atomic.replace` fsyncs NEITHER the file NOR the
//! directory; there is no cross-platform directory-fsync wrapper; and the "EIO ->
//! untrusted state" policy (the fsyncgate lesson) is implemented here, not by stdlib.
//! See docs/research/persistence-durability-research.md.
//!
//! CRITICAL ORDER (verified from std/Io/File/Atomic.zig:77): `replace()` CLOSES the
//! file BEFORE renaming, so File.sync MUST be called BEFORE replace, while the file
//! is still open. Syncing after replace would be a no-op on a closed handle.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// Durable-write errors. `DurabilityFailed` is the terminal state produced by an
/// EIO from fsync (fsyncgate: re-fsync after EIO is unsafe — the in-flight write may
/// be lost and the dirty page already cleared; we treat the result as untrusted and
/// do NOT retry).
pub const WriteAtomicError = error{
    DurabilityFailed,
} || Dir.CreateFileAtomicError
  || File.Writer.Error // underlying IO write error (w.err), not interface WriteFailed
  || File.SyncError
  || File.Atomic.ReplaceError
  || Dir.CreateDirPathError;

/// fsync a directory descriptor so a freshly-renamed dir-entry reaches stable
/// storage (POSIX). EINVAL/EBADF/EROFS are treated as no-op success (some
/// filesystems reject fsync on a directory fd — kernel issues #15563/#17950; this
/// is NOT a durability failure). EIO is fatal. Windows: no-op (NTFS journals the
/// rename metadata; there is no directory-fsync syscall).
pub fn dirFsync(dir: Dir) WriteAtomicError!void {
    if (builtin.os.tag == .windows) return; // no directory-fsync on NTFS; rename is journaled.

    // `std.posix.fsync` does not exist in 0.16 (only fdatasync/syncfs/sync). Use the
    // raw syscall and decode errno ourselves. On Linux `std.posix.system.fsync`
    // resolves to `std.os.linux.fsync` (raw syscall returning usize); on libc targets
    // it is the libc `fsync` returning c_int. `std.posix.errno` accepts both.
    const fd = dir.handle; // std.posix.fd_t (Dir.zig:13)
    while (true) {
        const rc = std.posix.system.fsync(fd);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue, // interrupted by signal — retry the fsync.
            // dir-fd does not support fsync on this filesystem -> treat as no-op success.
            .INVAL, .BADF, .ROFS => return,
            // EIO -> in-flight metadata may be lost; state is untrusted. Fatal, no retry.
            else => return error.DurabilityFailed,
        }
    }
}

/// Durable atomic write of `bytes` to `dir/sub_path`. On success the data is on
/// stable storage (to the limit of the hardware's guarantees). Overwriting an
/// existing file is safe (full replace; the old content/size never leaks through).
///
/// `sub_path` may be nested (e.g. "edits/volumes.bin"): the parent directory is
/// created first via `createDirPath`. The directory fsync targets `dir` (the parent
/// passed in) — callers writing into a nested subdir that needs its own dir-entry
/// durably committed should fsync that subdir via `dirFsync` after the batch.
pub fn writeAtomic(
    io: Io,
    dir: Dir,
    sub_path: []const u8,
    bytes: []const u8,
) WriteAtomicError!void {
    // 0) Ensure the parent directory of a nested sub_path exists. createDirPath is a
    //    no-op success if it already exists, and creates intermediate dirs.
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }

    var af = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    {
        // errdefer is scoped to the pre-replace region: it deletes the temp file and
        // closes the handle on ANY error before/at `replace`. It MUST NOT outlive the
        // explicit `af.deinit` below, or it would double-deinit an undefined struct.
        errdefer af.deinit(io);

        // 1) Write all bytes through a buffered writer, then MANDATORY flush. Without the
        //    flush the tail of `bytes` would linger in the user-space buffer and never be
        //    seen by fsync.
        var wbuf: [4096]u8 = undefined;
        var w = af.file.writer(io, &wbuf);
        w.interface.writeAll(bytes) catch |e| switch (e) {
            error.WriteFailed => return w.err orelse error.Unexpected,
        };
        try w.flush(); // File.Writer.flush unwraps WriteFailed to the underlying error.

        // 2) EXPLICIT fsync of the file, BEFORE replace (replace closes the file). EIO is
        //    fatal: per the fsyncgate lesson we do NOT retry — a second fsync can report
        //    success while the data is already lost.
        af.file.sync(io) catch |e| switch (e) {
            error.InputOutput => return error.DurabilityFailed,
            else => return e,
        };

        // 3) Atomic rename temp -> sub_path. (replace closes af.file internally first.)
        try af.replace(io);
        // NOTE: dirFsync MUST stay OUTSIDE this block — the errdefer above must be dead before the explicit deinit ran, or it would deinit an already-undefined AtomicFile.
    }

    // 4) Release remaining resources. After a successful replace this is a no-op for
    //    the file/temp (both flags cleared); it only matters for close_dir_on_deinit,
    //    which is false here (we did not pass make_path-owned dir). Safe to call.
    //    The errdefer above has gone out of scope, so this runs exactly once.
    af.deinit(io);

    // 5) Directory-fsync so the renamed directory entry itself reaches stable storage
    //    (POSIX). No-op on Windows. If this fails the file is already materialized;
    //    we surface the durability error to the caller (no temp to clean up).
    try dirFsync(dir);
}

/// Open (creating if needed) a scene container directory under `parent`, returning
/// an owned Dir the caller must close. Used by the persistence orchestrator to get
/// a handle for writeAtomic sub-paths.
///
/// Uses `createDirPathOpen` which atomically creates all intermediate directories
/// (no-op if already present) and returns an open handle in a single operation.
pub fn openContainerDir(io: Io, parent: Dir, sub_path: []const u8) !Dir {
    return parent.createDirPathOpen(io, sub_path, .{});
}

// ---------------------------------------------------------------------------
// Integration tests (temp dir): happy path + overwrite + nested path + dirFsync.
// Run: & "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/persist/write_atomic.zig
// (std.testing provides a process-global Io via std.testing.io, used by tmpDir.)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeAtomic round-trip: write then read back equals bytes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "durable round-trip payload";
    try writeAtomic(io, tmp.dir, "a.bin", payload);

    const got = try tmp.dir.readFileAlloc(io, "a.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, payload, got);
}

test "writeAtomic overwrite leaves new content (replace=true, not truncated/corrupt)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAtomic(io, tmp.dir, "b.bin", "first-version-data"); // longer
    try writeAtomic(io, tmp.dir, "b.bin", "second"); // shorter -> size must shrink, no tail leak

    const got = try tmp.dir.readFileAlloc(io, "b.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, "second", got);
}

test "writeAtomic nested sub_path creates parent dir and writes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "nested durable payload";
    try writeAtomic(io, tmp.dir, "edits/volumes.bin", payload);

    const got = try tmp.dir.readFileAlloc(io, "edits/volumes.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, payload, got);
}

test "dirFsync on a normal directory returns without error (EINVAL tolerated)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try dirFsync(tmp.dir); // POSIX or Windows: returns without error (EINVAL tolerated).
}

test "openContainerDir creates and opens a nested container" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var d = try openContainerDir(io, tmp.dir, "world/.recastscene");
    defer d.close(io);
    try writeAtomic(io, d, "manifest", "hello");
    const got = try d.readFileAlloc(io, "manifest", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}
