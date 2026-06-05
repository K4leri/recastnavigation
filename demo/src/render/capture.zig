//! Frame-sequence capture (Cluster E, P2-1) — pure capture logic + helpers.
//!
//! Writes N rendered frames to a directory as PPM (P6) images plus a manifest, driven
//! by a deterministic orbit path (frame-count-driven, NOT wall-clock — reproducible) or
//! live input. For detached repro / PR-review ("here's what the bug looks like") without
//! a live session.
//!
//! This module owns only the PURE parts (PPM encode + filename/manifest formatting) so
//! they can be unit-tested without GL. The GL readPixels + write_atomic plumbing lives in
//! main.zig (the per-frame hook, after the 3D+UI draw, before the buffer swap).
//!
//! PPM-only: PNG would need an encoder (out of scope). To turn the frames into a video:
//!   ffmpeg -i frame_%05d.ppm out.mp4
//!
//! Захват последовательности кадров: N кадров в каталог (PPM + манифест), по
//! детерминированной орбите (счёт кадров, не часы — воспроизводимо) или live-вводу.
//! Чистые части (кодирование PPM, имена файлов, строки манифеста) — здесь и под тестами;
//! GL readPixels + durable-запись через write_atomic — в main.zig.

const std = @import("std");

pub const Mode = enum { orbit, live };

/// Max directory-name length stored inline. 256 covers any sane relative output path.
pub const DIR_MAX = 256;

/// Capture run state. Lives in main.zig's frame loop; the per-frame hook reads `active`
/// + `finished()` and advances `done`. The output directory is stored in a fixed inline
/// buffer (no allocation, no lifetime coupling to UI text buffers).
pub const State = struct {
    active: bool = false,
    mode: Mode = .orbit,
    total: u32 = 0, // frames to capture
    done: u32 = 0, // frames written so far
    dir_buf: [DIR_MAX]u8 = undefined,
    dir_len: usize = 0,

    /// Begin a capture run: copy `dir`, set total + mode, reset progress, go active.
    /// `dir` is truncated to DIR_MAX bytes (a path that long is already pathological).
    pub fn start(self: *State, out_dir: []const u8, total: u32, mode: Mode) void {
        const n = @min(out_dir.len, DIR_MAX);
        @memcpy(self.dir_buf[0..n], out_dir[0..n]);
        self.dir_len = n;
        self.total = total;
        self.done = 0;
        self.mode = mode;
        self.active = true;
    }

    /// The configured output directory (slice into the inline buffer).
    pub fn dir(self: *const State) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    /// All requested frames written.
    pub fn finished(self: *const State) bool {
        return self.done >= self.total;
    }
};

/// Build a PPM (P6) byte buffer from an RGB framebuffer that is BOTTOM-UP (GL order:
/// glReadPixels' first row is the BOTTOM of the image). Writes the "P6\n{w} {h}\n255\n"
/// header, then the pixel rows TOP-DOWN (vertical flip) so the resulting image is the
/// right way up. `rgb` must be exactly w*h*3 bytes. Caller frees the result.
pub fn encodePpm(alloc: std.mem.Allocator, rgb: []const u8, w: usize, h: usize) ![]u8 {
    std.debug.assert(rgb.len == w * h * 3);
    const row = w * 3;

    // Header then exactly h*row pixel bytes. Pre-size the header into a small stack buf.
    var hdr: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ w, h });

    const out = try alloc.alloc(u8, head.len + h * row);
    @memcpy(out[0..head.len], head);

    // Flip vertically: source row (h-1-y) (from the bottom) -> dest row y (from the top).
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src = rgb[(h - 1 - y) * row ..][0..row];
        @memcpy(out[head.len + y * row ..][0..row], src);
    }
    return out;
}

/// Format the zero-padded frame filename "frame_00001.ppm" into `buf`. Returns the slice.
/// 5 digits cover up to 99999 frames; larger indices simply use more digits (no overflow).
pub fn frameName(buf: []u8, idx: u32) []const u8 {
    return std.fmt.bufPrint(buf, "frame_{d:0>5}.ppm", .{idx}) catch buf[0..0];
}

/// Format one manifest line: frame index + camera pitch/yaw/pos — pure, newline-terminated.
/// Columns are stable for diffing across runs (orbit is deterministic, so two runs match).
pub fn manifestLine(buf: []u8, idx: u32, pitch: f32, yaw: f32, pos: [3]f32) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d:0>5} pitch={d:.3} yaw={d:.3} pos={d:.3},{d:.3},{d:.3}\n",
        .{ idx, pitch, yaw, pos[0], pos[1], pos[2] },
    ) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Unit tests for the pure helpers (no GL). std.testing.allocator catches leaks.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encodePpm header + vertical flip of a 2x2 bottom-up image" {
    // 2x2 bottom-up source. Bottom row (index 0) = A,B; top row (index 1) = C,D.
    // Each pixel is a distinct RGB triple so the flip is unambiguous.
    const A = [3]u8{ 1, 2, 3 };
    const B = [3]u8{ 4, 5, 6 };
    const C = [3]u8{ 7, 8, 9 };
    const D = [3]u8{ 10, 11, 12 };
    const rgb = A ++ B ++ C ++ D; // bottom row first (A,B), then top row (C,D)

    const out = try encodePpm(testing.allocator, &rgb, 2, 2);
    defer testing.allocator.free(out);

    // Header.
    const head = "P6\n2 2\n255\n";
    try testing.expectEqualStrings(head, out[0..head.len]);

    // After the flip the FIRST emitted row must be the TOP of the image (C,D),
    // and the SECOND row the bottom (A,B).
    const body = out[head.len..];
    try testing.expectEqualSlices(u8, &(C ++ D), body[0..6]);
    try testing.expectEqualSlices(u8, &(A ++ B), body[6..12]);
}

test "frameName zero-pads to 5 digits" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("frame_00001.ppm", frameName(&buf, 1));
    try testing.expectEqualStrings("frame_00042.ppm", frameName(&buf, 42));
    try testing.expectEqualStrings("frame_12345.ppm", frameName(&buf, 12345));
}

test "manifestLine format is stable" {
    var buf: [128]u8 = undefined;
    const line = manifestLine(&buf, 7, 45.0, -90.0, .{ 1.5, 2.0, -3.25 });
    try testing.expectEqualStrings(
        "00007 pitch=45.000 yaw=-90.000 pos=1.500,2.000,-3.250\n",
        line,
    );
}

test "State.start / finished lifecycle" {
    var s = State{};
    try testing.expect(!s.active);
    s.start("capture", 3, .orbit);
    try testing.expect(s.active);
    try testing.expectEqualStrings("capture", s.dir());
    try testing.expectEqual(@as(u32, 3), s.total);
    try testing.expect(!s.finished());
    s.done = 3;
    try testing.expect(s.finished());
}
