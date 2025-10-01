const std = @import("std");

/// Log categories for Recast operations
pub const LogCategory = enum {
    progress,
    warning,
    err,
};

/// Timer labels for performance tracking
pub const TimerLabel = enum {
    total,
    temp,
    rasterize_triangles,
    build_compact_heightfield,
    build_contours,
    build_contours_trace,
    build_contours_simplify,
    filter_border,
    filter_walkable,
    median_area,
    filter_low_obstacles,
    build_polymesh,
    merge_polymesh,
    erode_area,
    mark_box_area,
    mark_cylinder_area,
    mark_convexpoly_area,
    build_distancefield,
    build_distancefield_dist,
    build_distancefield_blur,
    build_regions,
    build_regions_watershed,
    build_regions_expand,
    build_regions_flood,
    build_regions_filter,
    build_layers,
    build_polymeshdetail,
    merge_polymeshdetail,
};

/// Build context for logging and performance tracking
pub const Context = struct {
    log_enabled: bool = true,
    timer_enabled: bool = true,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn enableLog(self: *Self, enabled: bool) void {
        self.log_enabled = enabled;
    }

    pub fn enableTimer(self: *Self, enabled: bool) void {
        self.timer_enabled = enabled;
    }

    pub fn log(self: *const Self, category: LogCategory, comptime fmt: []const u8, args: anytype) void {
        if (!self.log_enabled) return;

        const prefix = switch (category) {
            .progress => "[PROGRESS]",
            .warning => "[WARNING]",
            .err => "[ERROR]",
        };

        std.debug.print("{s} ", .{prefix});
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
    }

    pub fn startTimer(_: *const Self, _: TimerLabel) void {
        // TODO: Implement timer tracking
    }

    pub fn stopTimer(_: *const Self, _: TimerLabel) void {
        // TODO: Implement timer tracking
    }
};

/// RAII timer helper
pub const ScopedTimer = struct {
    ctx: *const Context,
    label: TimerLabel,

    pub fn init(ctx: *const Context, label: TimerLabel) ScopedTimer {
        ctx.startTimer(label);
        return .{ .ctx = ctx, .label = label };
    }

    pub fn deinit(self: *ScopedTimer) void {
        self.ctx.stopTimer(self.label);
    }
};
