//! Чистый детерминированный эмиттер результатов pathfinding-запросов (cluster D / D4).
//!
//! Автономный модуль: импортирует ТОЛЬКО std, чтобы тестироваться отдельно от
//! остального проекта. Сбор данных из tester'а не производится — на вход подаются
//! уже заполненные записи QueryRecord.
//!
//! CSV: плоская таблица «по запросу» (заголовок + строка на запрос).
//! Точки/path НЕ включаются в CSV — только скаляры.
//!
//! JSON: массив объектов со всеми полями + вложенными corners/path.
//! Детерминированный порядок ключей. Не-конечные float → 0 (валидный JSON).

const std = @import("std");

/// Одна запись результата pathfinding-запроса.
pub const QueryRecord = struct {
    id: []const u8, // "Q0" / "T3"
    kind: []const u8, // "follow"|"straight"|"sliced"|"raycast"|...
    start: [3]f32,
    end: [3]f32,
    status: []const u8, // "ok"|"partial"|"failed"|"invalid"
    path_len: f32, // мировая длина
    npolys: u32,
    nwaypoints: u32,
    ms: f32,
    include_flags: u16,
    exclude_flags: u16,
    corners: []const [3]f32, // точки straight-path (может быть пусто)
    path: []const u32, // poly-refs (может быть пусто)
};

// ===========================================================================
// Вспомогательные функции
// ===========================================================================

/// Записать float в детерминированном формате {d}. Не-конечные значения → 0.
fn writeFloat(w: *std.Io.Writer, v: f32) !void {
    const safe: f32 = if (std.math.isFinite(v)) v else 0;
    try w.print("{d}", .{safe});
}

/// CSV-экранирование поля по RFC 4180.
/// Поле берётся в двойные кавычки если содержит запятую, двойную кавычку или перевод строки.
/// Внутренние двойные кавычки удваиваются.
fn writeCsvField(w: *std.Io.Writer, s: []const u8) !void {
    // Проверяем нужно ли экранировать
    var needs_quote = false;
    for (s) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        try w.writeAll(s);
        return;
    }
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"') try w.writeByte('"'); // удваиваем
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// Записать JSON-строку с экранированием спецсимволов по RFC 8259.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
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
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ===========================================================================
// CSV
// ===========================================================================

/// CSV: плоская таблица «по запросу» (заголовок + строка на запрос). Точки/path
/// НЕ включаются в CSV (они переменной длины) — только скаляры. Колонки:
/// query_id,kind,sx,sy,sz,ex,ey,ez,status,path_len,npolys,nwaypoints,ms,include_flags,exclude_flags
/// include/exclude — в hex (0x...). Поля со спецсимволами (id/kind/status) —
/// CSV-экранирование (двойные кавычки если есть запятая/кавычка/перевод строки).
pub fn writeCsv(writer: *std.Io.Writer, records: []const QueryRecord) !void {
    // Заголовок
    try writer.writeAll("query_id,kind,sx,sy,sz,ex,ey,ez,status,path_len,npolys,nwaypoints,ms,include_flags,exclude_flags\n");

    for (records) |r| {
        // query_id
        try writeCsvField(writer, r.id);
        try writer.writeByte(',');
        // kind
        try writeCsvField(writer, r.kind);
        try writer.writeByte(',');
        // sx,sy,sz
        try writeFloat(writer, r.start[0]);
        try writer.writeByte(',');
        try writeFloat(writer, r.start[1]);
        try writer.writeByte(',');
        try writeFloat(writer, r.start[2]);
        try writer.writeByte(',');
        // ex,ey,ez
        try writeFloat(writer, r.end[0]);
        try writer.writeByte(',');
        try writeFloat(writer, r.end[1]);
        try writer.writeByte(',');
        try writeFloat(writer, r.end[2]);
        try writer.writeByte(',');
        // status
        try writeCsvField(writer, r.status);
        try writer.writeByte(',');
        // path_len
        try writeFloat(writer, r.path_len);
        try writer.writeByte(',');
        // npolys
        try writer.print("{d}", .{r.npolys});
        try writer.writeByte(',');
        // nwaypoints
        try writer.print("{d}", .{r.nwaypoints});
        try writer.writeByte(',');
        // ms
        try writeFloat(writer, r.ms);
        try writer.writeByte(',');
        // include_flags (hex)
        try writer.print("0x{x}", .{r.include_flags});
        try writer.writeByte(',');
        // exclude_flags (hex)
        try writer.print("0x{x}", .{r.exclude_flags});
        try writer.writeByte('\n');
    }
}

// ===========================================================================
// JSON
// ===========================================================================

/// JSON: массив объектов, каждый со всеми полями + вложенными "corners":[[x,y,z],..]
/// и "path":[ref,..]. Детерминированный порядок ключей. Валидный JSON.
/// Строки экранируются по JSON. Float — {d}, не-конечные → 0.
pub fn writeJson(alloc: std.mem.Allocator, records: []const QueryRecord) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeByte('[');

    for (records, 0..) |r, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');

        // id
        try w.writeAll("\"id\":");
        try writeJsonString(w, r.id);

        // kind
        try w.writeAll(",\"kind\":");
        try writeJsonString(w, r.kind);

        // start
        try w.writeAll(",\"start\":[");
        try writeFloat(w, r.start[0]);
        try w.writeByte(',');
        try writeFloat(w, r.start[1]);
        try w.writeByte(',');
        try writeFloat(w, r.start[2]);
        try w.writeByte(']');

        // end
        try w.writeAll(",\"end\":[");
        try writeFloat(w, r.end[0]);
        try w.writeByte(',');
        try writeFloat(w, r.end[1]);
        try w.writeByte(',');
        try writeFloat(w, r.end[2]);
        try w.writeByte(']');

        // status
        try w.writeAll(",\"status\":");
        try writeJsonString(w, r.status);

        // path_len
        try w.writeAll(",\"path_len\":");
        try writeFloat(w, r.path_len);

        // npolys
        try w.print(",\"npolys\":{d}", .{r.npolys});

        // nwaypoints
        try w.print(",\"nwaypoints\":{d}", .{r.nwaypoints});

        // ms
        try w.writeAll(",\"ms\":");
        try writeFloat(w, r.ms);

        // include_flags (hex)
        try w.print(",\"include_flags\":\"0x{x}\"", .{r.include_flags});

        // exclude_flags (hex)
        try w.print(",\"exclude_flags\":\"0x{x}\"", .{r.exclude_flags});

        // corners — вложенный массив [[x,y,z],...]
        try w.writeAll(",\"corners\":[");
        for (r.corners, 0..) |c, ci| {
            if (ci != 0) try w.writeByte(',');
            try w.writeByte('[');
            try writeFloat(w, c[0]);
            try w.writeByte(',');
            try writeFloat(w, c[1]);
            try w.writeByte(',');
            try writeFloat(w, c[2]);
            try w.writeByte(']');
        }
        try w.writeByte(']');

        // path — массив poly-refs
        try w.writeAll(",\"path\":[");
        for (r.path, 0..) |ref, pi| {
            if (pi != 0) try w.writeByte(',');
            try w.print("{d}", .{ref});
        }
        try w.writeByte(']');

        try w.writeByte('}');
    }

    try w.writeByte(']');

    return aw.toOwnedSlice();
}

// ===========================================================================
// Тесты
// ===========================================================================

fn makeOkRecord() QueryRecord {
    return .{
        .id = "Q0",
        .kind = "straight",
        .start = .{ 1.0, 0.0, 2.0 },
        .end = .{ 5.0, 0.0, 6.0 },
        .status = "ok",
        .path_len = 7.5,
        .npolys = 3,
        .nwaypoints = 2,
        .ms = 0.12,
        .include_flags = 0x0001,
        .exclude_flags = 0x0010,
        .corners = &[_][3]f32{ .{ 1.0, 0.0, 2.0 }, .{ 3.0, 0.0, 4.0 }, .{ 5.0, 0.0, 6.0 } },
        .path = &[_]u32{ 100, 101, 102 },
    };
}

fn makeFailedRecord() QueryRecord {
    // id содержит запятую — для теста CSV-экранирования
    return .{
        .id = "T,3",
        .kind = "follow",
        .start = .{ 0.0, 0.0, 0.0 },
        .end = .{ 0.0, 0.0, 0.0 },
        .status = "failed",
        .path_len = 0.0,
        .npolys = 0,
        .nwaypoints = 0,
        .ms = 0.01,
        .include_flags = 0xffff,
        .exclude_flags = 0x0000,
        .corners = &[_][3]f32{},
        .path = &[_]u32{},
    };
}

test "writeCsv: header + 2 rows, hex flags, CSV escaping" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    const records = [_]QueryRecord{ makeOkRecord(), makeFailedRecord() };
    try writeCsv(&aw.writer, &records);

    const out = aw.written();

    // Подсчёт строк: заголовок + 2 записи = 3 строки (каждая завершается \n)
    var line_count: usize = 0;
    for (out) |c| {
        if (c == '\n') line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);

    // Первая строка — заголовок
    const header = "query_id,kind,sx,sy,sz,ex,ey,ez,status,path_len,npolys,nwaypoints,ms,include_flags,exclude_flags";
    try std.testing.expect(std.mem.startsWith(u8, out, header));

    // Hex флаги
    try std.testing.expect(std.mem.indexOf(u8, out, "0x1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0xffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x0") != null);

    // id "T,3" должен быть в кавычках (содержит запятую)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"T,3\"") != null);

    // Статус "ok" — без кавычек (нет спецсимволов)
    try std.testing.expect(std.mem.indexOf(u8, out, ",ok,") != null);
}

test "writeJson: parses via std.json, corners/path, status, deterministic" {
    const alloc = std.testing.allocator;

    const records = [_]QueryRecord{ makeOkRecord(), makeFailedRecord() };

    const json1 = try writeJson(alloc, &records);
    defer alloc.free(json1);

    // Парсится std.json
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json1, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);

    // Проверим первый объект (ok-запись)
    const obj0 = arr[0].object;
    try std.testing.expectEqualStrings("Q0", obj0.get("id").?.string);
    try std.testing.expectEqualStrings("straight", obj0.get("kind").?.string);
    try std.testing.expectEqualStrings("ok", obj0.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 3), obj0.get("npolys").?.integer);
    try std.testing.expectEqual(@as(usize, 3), obj0.get("corners").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), obj0.get("path").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 100), obj0.get("path").?.array.items[0].integer);

    // Проверим второй объект (failed-запись)
    const obj1 = arr[1].object;
    try std.testing.expectEqualStrings("failed", obj1.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 0), obj1.get("corners").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), obj1.get("path").?.array.items.len);

    // Детерминизм: два вызова — идентичные байты
    const json2 = try writeJson(alloc, &records);
    defer alloc.free(json2);
    try std.testing.expectEqualSlices(u8, json1, json2);
}

test "writeJson: non-finite float (path_len = inf) -> 0, stays valid JSON" {
    const alloc = std.testing.allocator;

    var r = makeOkRecord();
    r.path_len = std.math.inf(f32);
    r.ms = -std.math.inf(f32);
    r.start = .{ std.math.nan(f32), 0.0, 0.0 };

    const records = [_]QueryRecord{r};
    const json = try writeJson(alloc, &records);
    defer alloc.free(json);

    // Нет невалидных литералов
    try std.testing.expect(std.mem.indexOf(u8, json, "inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nan") == null);

    // Валидный JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.array.items[0].object;
    const pl = obj.get("path_len").?;
    const pl_val: f64 = switch (pl) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => unreachable,
    };
    try std.testing.expectEqual(@as(f64, 0), pl_val);
}

test "writeCsv: empty list -> only header" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try writeCsv(&aw.writer, &[_]QueryRecord{});

    const out = aw.written();
    const header = "query_id,kind,sx,sy,sz,ex,ey,ez,status,path_len,npolys,nwaypoints,ms,include_flags,exclude_flags\n";
    try std.testing.expectEqualSlices(u8, header, out);
}

test "writeJson: empty list -> []" {
    const alloc = std.testing.allocator;

    const json = try writeJson(alloc, &[_]QueryRecord{});
    defer alloc.free(json);

    try std.testing.expectEqualStrings("[]", json);

    // Парсится
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}
