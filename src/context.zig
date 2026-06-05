const std = @import("std");
const builtin = @import("builtin");

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

/// Опциональный приёмник лог-сообщений (аналог виртуального rcContext::doLog).
/// Если задан в Context.sink, сообщения уходят в него вместо stderr —
/// используется демкой для буфера панели Log.
pub const LogSink = struct {
    ptr: *anyopaque,
    func: *const fn (ptr: *anyopaque, category: LogCategory, msg: []const u8) void,
};

/// Build context for logging and performance tracking
pub const Context = struct {
    log_enabled: bool = true,
    timer_enabled: bool = true,
    allocator: std.mem.Allocator,
    sink: ?LogSink = null,

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

        if (self.sink) |s| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
            s.func(s.ptr, category, msg);
            return;
        }

        // Под тест-раннером (zig build test) дочерний процесс общается с
        // build-сервером через `--listen=-`, и его stderr перехватывается в pipe.
        // Сотни [PROGRESS]-строк из полного recast-пайплайна (его прогоняют десятки
        // интеграционных тестов) гонятся с чтением result-манифеста сервером и на
        // Windows всплывают как «unable to read results of configure phase ...
        // FileNotFound» + recursive panic. Sink (демка) не затрагивается — у неё
        // is_test=false и она идёт по ветке sink выше. Глушим только stderr-вывод
        // тестового бинаря; вся логика/ассерты тестов нетронуты.
        if (builtin.is_test) return;

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
