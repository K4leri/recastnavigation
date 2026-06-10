//! Тонкая comptime-обёртка над ztracy. Зоны/фреймы/плоты/сообщения.
//! Когда -Dtracy=false, ztracy = stub, всё схлопывается в ноль (zero-cost).

const std = @import("std");
const ztracy = @import("ztracy");

pub const enabled = ztracy.enabled;

pub const Zone = struct {
    ctx: ztracy.ZoneCtx,
    pub inline fn end(self: Zone) void {
        self.ctx.End();
    }
};

/// Зона профилирования. `src` ОБЯЗАТЕЛЬНО передавать с места вызова (@src()),
/// иначе Tracy склеит все зоны в одну (ключ по source-location).
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8) Zone {
    return .{ .ctx = ztracy.ZoneN(src, name) };
}

/// Цветная зона (0xRRGGBB).
pub inline fn zoneC(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8, color: u32) Zone {
    return .{ .ctx = ztracy.ZoneNC(src, name, color) };
}

pub inline fn frameMark() void {
    ztracy.FrameMark();
}

pub inline fn setThreadName(comptime name: [*:0]const u8) void {
    ztracy.SetThreadName(name);
}

pub inline fn appInfo(text: []const u8) void {
    ztracy.AppInfo(text);
}

pub inline fn plotF(comptime name: [*:0]const u8, v: f64) void {
    ztracy.PlotF(name, v);
}

pub inline fn message(text: []const u8) void {
    ztracy.Message(text);
}
