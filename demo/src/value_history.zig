//! Port of RecastDemo's ValueHistory + graph drawing (ValueHistory.cpp).
//! A fixed ring buffer of samples plus a 2D screen-space line graph rendered with
//! dvui primitives (the upstream imgui graph renderer was left #if 0'd; this is a
//! faithful re-implementation of its geometry for the Crowd "Show Perf Graph").

const std = @import("std");
const dvui = @import("dvui");
const ui = @import("ui.zig");

pub const MAX_HISTORY = 256;

/// Ring buffer of the last MAX_HISTORY samples. 1:1 with `ValueHistory`.
pub const ValueHistory = struct {
    samples: [MAX_HISTORY]f32 = [_]f32{0} ** MAX_HISTORY,
    count: usize = 0, // valid samples until the buffer fills
    next: usize = 0, // write cursor once full

    pub fn addSample(self: *ValueHistory, val: f32) void {
        if (self.count < MAX_HISTORY) {
            self.samples[self.count] = val;
            self.count += 1;
        } else {
            self.samples[self.next] = val;
            self.next = (self.next + 1) % MAX_HISTORY;
        }
    }

    pub fn sampleCount(self: *const ValueHistory) usize {
        return self.count;
    }

    /// Oldest-first indexed sample (1:1 `getSample`).
    pub fn sample(self: *const ValueHistory, i: usize) f32 {
        return self.samples[(self.next + i) % MAX_HISTORY];
    }

    pub fn average(self: *const ValueHistory) f32 {
        if (self.count == 0) return 0;
        var total: f32 = 0;
        for (0..self.count) |i| total += self.samples[i];
        return total / @as(f32, @floatFromInt(self.count));
    }
};

const col = ui.colorFromRgba;

/// Draw one value-history line graph at screen rect (x,y,w,h) physical px (y-down),
/// mapping [range_min, range_max] to the padded height. Re-implements the (disabled)
/// upstream `drawGraph`: background, the sample polyline, and a legend swatch + label
/// with the running average. `index` stacks legend rows. Must be called inside a dvui
/// frame (between win.begin/end).
pub fn drawGraph(
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pad: f32,
    range_min: f32,
    range_max: f32,
    units: []const u8,
    hist: *const ValueHistory,
    rgba_color: u32,
    label: []const u8,
    index: usize,
    draw_bg: bool,
) void {
    const color = col(rgba_color);

    // Background (only once per stacked group, like drawGraphBackground).
    if (draw_bg) {
        const bg = dvui.Rect.Physical{ .x = x, .y = y, .w = w, .h = h };
        bg.fill(.{}, .{ .color = .{ .r = 32, .g = 32, .b = 32, .a = 160 } });
    }

    const n = hist.sampleCount();
    if (n >= 2) {
        const range = if (range_max - range_min > 0.0001) range_max - range_min else 1.0;
        const sx = (w - pad * 2) / @as(f32, @floatFromInt(n));
        const sy = (h - pad * 2) / range;
        const ox = x + pad;
        const oy = y + h - pad; // bottom of the plot (y-down => value grows upward)

        var pb = dvui.Path.Builder.init(allocator);
        defer pb.deinit();
        for (0..n) |i| {
            const vx = ox + @as(f32, @floatFromInt(i)) * sx;
            const vy = oy - (hist.sample(i) - range_min) * sy;
            pb.addPoint(.{ .x = vx, .y = vy });
        }
        pb.build().stroke(.{ .thickness = 2.0, .color = color, .closed = false });
    }

    // Legend: swatch + label + average (stacked upward by index).
    const sz: f32 = 15;
    const spacing: f32 = 10;
    const ix = x + w + 5;
    const iy = y + h - @as(f32, @floatFromInt(index + 1)) * (sz + spacing);
    const swatch = dvui.Rect.Physical{ .x = ix, .y = iy, .w = sz, .h = sz };
    swatch.fill(.{}, .{ .color = color });

    var buf: [64]u8 = undefined;
    const avg = std.fmt.bufPrint(&buf, "{s}: {d:.2} {s}", .{ label, hist.average(), units }) catch label;
    ui.screenText(ix + sz + 5, iy + 1, avg, .{ .r = 255, .g = 255, .b = 255, .a = 200 });
}
