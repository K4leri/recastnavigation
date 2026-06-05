//! BuildContext — аналог RecastDemo/SampleInterfaces.cpp::BuildContext.
//! Оборачивает recast.Context и буферизует лог-сообщения для панели Log.

const std = @import("std");
const recast = @import("recast-nav");
const ctxmod = recast.context;

pub const BuildContext = struct {
    alloc: std.mem.Allocator,
    messages: std.array_list.Managed(Message),
    ctx: recast.Context,

    pub const Message = struct {
        category: ctxmod.LogCategory,
        text: []u8,
    };

    pub fn init(alloc: std.mem.Allocator) BuildContext {
        return .{
            .alloc = alloc,
            .messages = std.array_list.Managed(Message).init(alloc),
            .ctx = recast.Context.init(alloc),
        };
    }

    pub fn deinit(self: *BuildContext) void {
        self.resetLog();
        self.messages.deinit();
    }

    /// Подключает лог-sink к встроенному Context. Вызывать после того, как
    /// BuildContext занял стабильный адрес (sink хранит указатель на self).
    pub fn wire(self: *BuildContext) void {
        self.ctx.sink = .{ .ptr = self, .func = sinkFn };
    }

    /// Указатель на recast.Context для передачи в recast/detour функции.
    pub fn context(self: *BuildContext) *recast.Context {
        return &self.ctx;
    }

    fn sinkFn(ptr: *anyopaque, category: ctxmod.LogCategory, msg: []const u8) void {
        const self: *BuildContext = @ptrCast(@alignCast(ptr));
        // Mirror to stderr so the running GUI's log (auto-save, delete, errors, …)
        // is visible in the process output, not only in the in-app Log panel.
        std.debug.print("[{s}] {s}\n", .{ @tagName(category), msg });
        const dup = self.alloc.dupe(u8, msg) catch return;
        self.messages.append(.{ .category = category, .text = dup }) catch {
            self.alloc.free(dup);
        };
    }

    pub fn resetLog(self: *BuildContext) void {
        for (self.messages.items) |m| self.alloc.free(m.text);
        self.messages.clearRetainingCapacity();
    }

    pub fn getLogCount(self: *const BuildContext) usize {
        return self.messages.items.len;
    }

    pub fn getLogText(self: *const BuildContext, i: usize) []const u8 {
        return self.messages.items[i].text;
    }
};
