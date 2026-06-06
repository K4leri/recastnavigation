//! Общий glb-контейнер (бинарный glTF 2.0): header + JSON-чанк + BIN-чанк.
//!
//! Один источник истины для импортёра (import_gltf.zig) и экспортёра
//! (export_gltf.zig): константы магиков, выравнивание по 4, чтение u32 LE,
//! сборка (writeContainer) и разбор (parseContainer) контейнера.
//!
//! Формат glb:
//!   header (12 байт): magic 'glTF' (LE) + version (=2) + total length
//!   chunk JSON: u32 length + u32 type('JSON') + payload (паддинг пробелами 0x20 до /4)
//!   chunk BIN:  u32 length + u32 type('BIN\0') + payload (паддинг нулями до /4)
//! Все длины кратны 4.

const std = @import("std");

/// 'glTF' little-endian. Первые 4 байта любого glb.
pub const MAGIC: u32 = 0x46546C67;
/// 'JSON' — тип JSON-чанка.
pub const CHUNK_JSON: u32 = 0x4E4F534A;
/// 'BIN\0' — тип бинарного чанка.
pub const CHUNK_BIN: u32 = 0x004E4942;
/// Версия контейнера glb (всегда 2).
pub const VERSION: u32 = 2;

/// Округлить вверх до кратного 4.
pub inline fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// Прочитать u32 little-endian по смещению off с проверкой границ.
pub fn readU32LE(bytes: []const u8, off: usize) error{BadGlb}!u32 {
    if (off + 4 > bytes.len) return error.BadGlb;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Дописать значение типа T (целое) в list как little-endian байты.
pub fn appendLe(list: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(&buf);
}

/// Собрать glb из готовых JSON- и BIN-байтов.
/// JSON-чанк дополняется пробелами (0x20) до кратности 4, BIN-чанк — нулями.
/// Возвращает owned []u8 (caller frees).
pub fn writeContainer(alloc: std.mem.Allocator, json: []const u8, bin: []const u8) ![]u8 {
    const json_chunk_len: usize = align4(json.len);
    const bin_chunk_len: usize = align4(bin.len);

    const header_len: usize = 12;
    const chunk_header_len: usize = 8;
    const total_len: usize = header_len +
        chunk_header_len + json_chunk_len +
        chunk_header_len + bin_chunk_len;

    var out = try std.array_list.Managed(u8).initCapacity(alloc, total_len);
    errdefer out.deinit();

    // header
    try appendLe(&out, u32, MAGIC);
    try appendLe(&out, u32, VERSION);
    try appendLe(&out, u32, @intCast(total_len));

    // JSON chunk
    try appendLe(&out, u32, @intCast(json_chunk_len));
    try appendLe(&out, u32, CHUNK_JSON);
    try out.appendSlice(json);
    while (out.items.len < header_len + chunk_header_len + json_chunk_len)
        try out.append(0x20); // паддинг JSON пробелами

    // BIN chunk
    try appendLe(&out, u32, @intCast(bin_chunk_len));
    try appendLe(&out, u32, CHUNK_BIN);
    try out.appendSlice(bin);
    while (out.items.len < total_len) try out.append(0); // паддинг BIN нулями

    std.debug.assert(out.items.len == total_len);
    return out.toOwnedSlice();
}

/// Результат разбора glb-контейнера: срезы внутрь исходных байтов.
pub const Container = struct {
    json: []const u8,
    bin: []const u8,
};

/// Разобрать glb-контейнер (bounds-safe). Проверяет magic/version/length,
/// идёт по чанкам и возвращает JSON- и BIN-пейлоады. Прочие чанки игнорируются.
/// Если BIN-чанк отсутствует, .bin будет пустым срезом.
pub fn parseContainer(bytes: []const u8) error{BadGlb}!Container {
    if (bytes.len < 12) return error.BadGlb;
    const magic = try readU32LE(bytes, 0);
    if (magic != MAGIC) return error.BadGlb;
    const version = try readU32LE(bytes, 4);
    if (version != VERSION) return error.BadGlb;
    const total_len = try readU32LE(bytes, 8);
    if (total_len > bytes.len) return error.BadGlb;

    var json: ?[]const u8 = null;
    var bin: []const u8 = &.{};

    var off: usize = 12;
    while (off + 8 <= total_len) {
        const chunk_len: usize = @intCast(try readU32LE(bytes, off));
        const chunk_type = try readU32LE(bytes, off + 4);
        const data_start = off + 8;
        const data_end = data_start + chunk_len;
        if (data_end > total_len or data_end > bytes.len) return error.BadGlb;
        const data = bytes[data_start..data_end];
        switch (chunk_type) {
            CHUNK_JSON => json = data,
            CHUNK_BIN => bin = data,
            else => {},
        }
        off = data_end;
    }

    const j = json orelse return error.BadGlb;
    return .{ .json = j, .bin = bin };
}

/// Быстрая проверка магика без полного разбора.
pub fn isGlb(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.readInt(u32, bytes[0..4], .little) == MAGIC;
}

// ============================ TESTS ============================

const testing = std.testing;

test "writeContainer + parseContainer round-trip" {
    const alloc = testing.allocator;
    const json = "{\"a\":1}"; // len 7 -> паддинг до 8
    const bin = [_]u8{ 1, 2, 3 }; // len 3 -> паддинг до 4
    const glb = try writeContainer(alloc, json, &bin);
    defer alloc.free(glb);

    try testing.expect(isGlb(glb));
    try testing.expectEqual(@as(usize, 0), glb.len % 4);
    try testing.expectEqual(MAGIC, try readU32LE(glb, 0));
    try testing.expectEqual(VERSION, try readU32LE(glb, 4));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), try readU32LE(glb, 8));

    const c = try parseContainer(glb);
    // JSON: первые 7 байт == исходный, хвост — пробелы
    try testing.expectEqualStrings(json, c.json[0..json.len]);
    try testing.expectEqual(@as(usize, 8), c.json.len);
    try testing.expectEqual(@as(u8, 0x20), c.json[7]);
    // BIN: первые 3 байта == исходные, хвост — ноль
    try testing.expectEqualSlices(u8, &bin, c.bin[0..bin.len]);
    try testing.expectEqual(@as(usize, 4), c.bin.len);
    try testing.expectEqual(@as(u8, 0), c.bin[3]);
}

test "parseContainer rejects bad magic / short input" {
    try testing.expectError(error.BadGlb, parseContainer(&[_]u8{ 0, 1, 2 }));
    var bad = [_]u8{0} ** 12;
    std.mem.writeInt(u32, bad[0..4], 0xDEADBEEF, .little);
    try testing.expectError(error.BadGlb, parseContainer(&bad));
}

test "align4" {
    try testing.expectEqual(@as(usize, 0), align4(0));
    try testing.expectEqual(@as(usize, 4), align4(1));
    try testing.expectEqual(@as(usize, 4), align4(4));
    try testing.expectEqual(@as(usize, 8), align4(5));
}
