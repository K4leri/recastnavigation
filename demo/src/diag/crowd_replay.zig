//! Crowd record/replay — чистая логика журнала событий (std-only, без detour/dvui).
//! Кластер J / P1: запись пользовательских действий толпы (add agent / move target /
//! set velocity / remove agent) с номером кадра и детерминированный реплей ВПЕРЁД
//! из этого журнала (re-sim фиксированным dt). YAGNI: без перемотки назад и снапшотов.
//!
//! Этот файл НЕ зависит от ядра recast/detour — только std. Он держит формат события,
//! append-only журнал и бинарную сериализацию (round-trip), чтобы сценарий толпы можно
//! было сохранить/переслать. Применение событий к реальной dc.Crowd — в tool_crowd.zig.

const std = @import("std");

/// Тип события — какое пользовательское действие записано (тег сериализуется как u8).
pub const EventKind = enum(u8) {
    add_agent = 0,
    move_target = 1,
    set_velocity = 2,
    remove_agent = 3,
};

/// Одно записанное событие. Все варианты несут номер кадра (frame), на котором действие
/// произошло; полезная нагрузка зависит от типа. Для move_target/set_velocity нагрузка —
/// точка/вектор в мире (применяется ко всем активным агентам, как делает onClick).
pub const CrowdEvent = union(EventKind) {
    add_agent: struct { frame: u64, pos: [3]f32 },
    move_target: struct { frame: u64, pos: [3]f32 },
    set_velocity: struct { frame: u64, vel: [3]f32 },
    remove_agent: struct { frame: u64, idx: u32 },

    /// Кадр события (унифицированный доступ для реплея).
    pub fn frame(self: CrowdEvent) u64 {
        return switch (self) {
            .add_agent => |e| e.frame,
            .move_target => |e| e.frame,
            .set_velocity => |e| e.frame,
            .remove_agent => |e| e.frame,
        };
    }
};

/// Append-only журнал событий + монотонный кадровый счётчик.
pub const EventLog = struct {
    events: std.array_list.Managed(CrowdEvent),

    pub fn init(alloc: std.mem.Allocator) EventLog {
        return .{ .events = std.array_list.Managed(CrowdEvent).init(alloc) };
    }

    pub fn deinit(self: *EventLog) void {
        self.events.deinit();
    }

    pub fn clear(self: *EventLog) void {
        self.events.clearRetainingCapacity();
    }

    pub fn count(self: *const EventLog) usize {
        return self.events.items.len;
    }

    pub fn append(self: *EventLog, ev: CrowdEvent) !void {
        try self.events.append(ev);
    }

    // --- Бинарная сериализация (round-trip) ----------------------------------
    // Формат: magic "CRWR" + u32 версия + u32 число событий, затем по событию:
    // u8 тег + полезная нагрузка (frame u64 LE, далее 3×f32 LE или idx u32 LE).
    // Little-endian фиксированно — переносимо между запусками на той же платформе.

    const MAGIC = [4]u8{ 'C', 'R', 'W', 'R' };
    const VERSION: u32 = 1;

    fn putU32(w: *std.array_list.Managed(u8), v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.appendSlice(&b);
    }
    fn putU64(w: *std.array_list.Managed(u8), v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try w.appendSlice(&b);
    }
    fn putF32(w: *std.array_list.Managed(u8), v: f32) !void {
        try putU32(w, @bitCast(v));
    }

    /// Сериализует журнал в owned-буфер (вызывающий освобождает через alloc).
    pub fn serialize(self: *const EventLog, alloc: std.mem.Allocator) ![]u8 {
        var w = std.array_list.Managed(u8).init(alloc);
        errdefer w.deinit();
        try w.appendSlice(&MAGIC);
        try putU32(&w, VERSION);
        try putU32(&w, @intCast(self.events.items.len));
        for (self.events.items) |ev| {
            try w.append(@intFromEnum(std.meta.activeTag(ev)));
            switch (ev) {
                .add_agent => |e| {
                    try putU64(&w, e.frame);
                    for (e.pos) |c| try putF32(&w, c);
                },
                .move_target => |e| {
                    try putU64(&w, e.frame);
                    for (e.pos) |c| try putF32(&w, c);
                },
                .set_velocity => |e| {
                    try putU64(&w, e.frame);
                    for (e.vel) |c| try putF32(&w, c);
                },
                .remove_agent => |e| {
                    try putU64(&w, e.frame);
                    try putU32(&w, e.idx);
                },
            }
        }
        return w.toOwnedSlice();
    }

    const Reader = struct {
        buf: []const u8,
        off: usize = 0,

        fn need(self: *Reader, n: usize) !void {
            if (self.off + n > self.buf.len) return error.Truncated;
        }
        fn getU32(self: *Reader) !u32 {
            try self.need(4);
            const v = std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
            self.off += 4;
            return v;
        }
        fn getU64(self: *Reader) !u64 {
            try self.need(8);
            const v = std.mem.readInt(u64, self.buf[self.off..][0..8], .little);
            self.off += 8;
            return v;
        }
        fn getF32(self: *Reader) !f32 {
            return @bitCast(try self.getU32());
        }
        fn getU8(self: *Reader) !u8 {
            try self.need(1);
            const v = self.buf[self.off];
            self.off += 1;
            return v;
        }
    };

    /// Разбирает буфер в журнал (журнал должен быть свежим/очищенным; добавляет события).
    pub fn deserialize(self: *EventLog, buf: []const u8) !void {
        var r = Reader{ .buf = buf };
        try r.need(4);
        if (!std.mem.eql(u8, r.buf[0..4], &MAGIC)) return error.BadMagic;
        r.off = 4;
        const ver = try r.getU32();
        if (ver != VERSION) return error.BadVersion;
        const n = try r.getU32();
        try self.events.ensureUnusedCapacity(n);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tag = try r.getU8();
            const kind = std.enums.fromInt(EventKind, tag) orelse return error.BadTag;
            const fr = try r.getU64();
            const ev: CrowdEvent = switch (kind) {
                .add_agent => .{ .add_agent = .{ .frame = fr, .pos = .{ try r.getF32(), try r.getF32(), try r.getF32() } } },
                .move_target => .{ .move_target = .{ .frame = fr, .pos = .{ try r.getF32(), try r.getF32(), try r.getF32() } } },
                .set_velocity => .{ .set_velocity = .{ .frame = fr, .vel = .{ try r.getF32(), try r.getF32(), try r.getF32() } } },
                .remove_agent => .{ .remove_agent = .{ .frame = fr, .idx = try r.getU32() } },
            };
            try self.events.append(ev);
        }
    }
};

// --- Unit tests --------------------------------------------------------------

test "EventLog round-trip serialize/deserialize" {
    const a = std.testing.allocator;
    var log = EventLog.init(a);
    defer log.deinit();

    try log.append(.{ .add_agent = .{ .frame = 0, .pos = .{ 1.0, 2.0, 3.0 } } });
    try log.append(.{ .move_target = .{ .frame = 5, .pos = .{ -4.5, 0.0, 7.25 } } });
    try log.append(.{ .set_velocity = .{ .frame = 12, .vel = .{ 0.5, 0.0, -0.5 } } });
    try log.append(.{ .add_agent = .{ .frame = 12, .pos = .{ 9.0, 1.0, 9.0 } } });
    try log.append(.{ .remove_agent = .{ .frame = 30, .idx = 1 } });

    const blob = try log.serialize(a);
    defer a.free(blob);

    var log2 = EventLog.init(a);
    defer log2.deinit();
    try log2.deserialize(blob);

    try std.testing.expectEqual(log.count(), log2.count());
    for (log.events.items, log2.events.items) |e1, e2| {
        try std.testing.expectEqual(std.meta.activeTag(e1), std.meta.activeTag(e2));
        try std.testing.expectEqual(e1.frame(), e2.frame());
    }
    // Точечная сверка содержимого нагрузки.
    try std.testing.expectEqual(@as(f32, 1.0), log2.events.items[0].add_agent.pos[0]);
    try std.testing.expectEqual(@as(f32, 7.25), log2.events.items[1].move_target.pos[2]);
    try std.testing.expectEqual(@as(f32, -0.5), log2.events.items[2].set_velocity.vel[2]);
    try std.testing.expectEqual(@as(u32, 1), log2.events.items[4].remove_agent.idx);
}

test "deserialize rejects bad magic" {
    const a = std.testing.allocator;
    var log = EventLog.init(a);
    defer log.deinit();
    try std.testing.expectError(error.BadMagic, log.deserialize("XXXX...."));
}

test "empty log round-trips" {
    const a = std.testing.allocator;
    var log = EventLog.init(a);
    defer log.deinit();
    const blob = try log.serialize(a);
    defer a.free(blob);
    var log2 = EventLog.init(a);
    defer log2.deinit();
    try log2.deserialize(blob);
    try std.testing.expectEqual(@as(usize, 0), log2.count());
}
