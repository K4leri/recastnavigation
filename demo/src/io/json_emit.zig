//! Общие JSON-эмит-хелперы для детерминированных экспортёров (cluster D).
//!
//! Автономный модуль: импортирует ТОЛЬКО std. Каноничные реализации
//! JSON-экранирования строк и безопасного float-эмита, разделяемые между
//! export_metrics.zig и export_query.zig (раньше дублировались побайтово).
//!
//! Формат float: `{d}` (Zig печатает кратчайшее детерминированное round-trip
//! представление для f32). Не-конечные значения (inf/-inf/nan) НЕВАЛИДНЫ в JSON
//! (RFC 8259) — детерминированно заменяются на 0.

const std = @import("std");

/// Записать JSON-строку в writer с экранированием спецсимволов по RFC 8259.
/// Экранируются: `"`, `\\`, и управляющие символы < 0x20 (включая \n, \r, \t,
/// \b, \f); прочие control-байты — как `\u00XX`.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            0x0D => try w.writeAll("\\r"),
            else => {
                if (c < 0x20) {
                    // прочие управляющие символы — \u00XX
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Записать значение f32 единым детерминированным форматом `{d}`.
///
/// ВАЖНО: Zig печатает `{d}` для не-конечных f32 как `inf`/`-inf`/`nan` — это
/// НЕВАЛИДНЫЙ JSON (нет таких литералов в RFC 8259), он сломает
/// std.json.parseFromSlice. Поэтому не-конечные значения (inf/-inf/nan)
/// детерминированно заменяем на 0. Конечные значения, включая -0.0, печатаются
/// как есть.
pub fn writeFloatSafe(w: *std.Io.Writer, v: f32) !void {
    const safe: f32 = if (std.math.isFinite(v)) v else 0;
    try w.print("{d}", .{safe});
}

// ===========================================================================
// Тесты
// ===========================================================================

const testing = std.testing;

test "writeJsonString: escapes quote, backslash, control chars" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, "a\"b\\c\nd\re\tf\x01g");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\\u0001g\"", aw.written());
}

test "writeFloatSafe: finite passes through, non-finite -> 0" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeFloatSafe(&aw.writer, 12.34);
    try aw.writer.writeByte(' ');
    try writeFloatSafe(&aw.writer, std.math.inf(f32));
    try aw.writer.writeByte(' ');
    try writeFloatSafe(&aw.writer, -std.math.inf(f32));
    try aw.writer.writeByte(' ');
    try writeFloatSafe(&aw.writer, std.math.nan(f32));
    try testing.expectEqualStrings("12.34 0 0 0", aw.written());
}
