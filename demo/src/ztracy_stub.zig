//! No-op заглушка ztracy для сборки demo без -Dtracy. Позволяет собирать demo без
//! внешней зависимости ztracy (CI / свежий clone). Повторяет подмножество API ztracy,
//! используемое demo/src/tracy.zig; все вызовы схлопываются в ноль.
const std = @import("std");

pub const enabled = false;

pub const ZoneCtx = struct {
    pub inline fn End(self: ZoneCtx) void {
        _ = self;
    }
    pub inline fn Text(self: ZoneCtx, _: []const u8) void {
        _ = self;
    }
    pub inline fn Name(self: ZoneCtx, _: []const u8) void {
        _ = self;
    }
    pub inline fn Value(self: ZoneCtx, _: u64) void {
        _ = self;
    }
};

pub inline fn ZoneN(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8) ZoneCtx {
    _ = src;
    _ = name;
    return .{};
}

pub inline fn ZoneNC(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8, color: u32) ZoneCtx {
    _ = src;
    _ = name;
    _ = color;
    return .{};
}

pub inline fn FrameMark() void {}

pub inline fn SetThreadName(comptime name: [*:0]const u8) void {
    _ = name;
}

pub inline fn AppInfo(text: []const u8) void {
    _ = text;
}

pub inline fn PlotF(comptime name: [*:0]const u8, v: f64) void {
    _ = name;
    _ = v;
}

pub inline fn Message(text: []const u8) void {
    _ = text;
}
