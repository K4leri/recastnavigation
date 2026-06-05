//! D6 stage 1 — чистый diff двух JSON-метрик навмеша (схема D3).
//!
//! Сравнивает два D3-JSON (Zig-навмеш vs C++-эталон) на одном входе и выдаёт
//! отчёт о расхождениях, пригодный для CI exit-code (поле `ok`).
//!
//! Автономный модуль: импортирует только `std`. Файловый ввод и CLI-роутинг —
//! на стороне вызывающего.
//!
//! Классификация полей (КАК сравниваем):
//!   ТОЧНОЕ равенство (eps НЕ применяется):
//!     - schema_version (int)
//!     - navmesh.num_tiles / num_polys / num_verts / max_polys (счётчики)
//!     - areas[].id, areas[].poly_count (счётчики)
//!     - все СТРОКИ: source.geom, source.sample, settings.partition,
//!       areas[].name
//!     - settings.tile_size: null vs число — расхождение (тип/наличие)
//!   EPS-сравнение (|a-b|/max(1,|a|,|b|) > eps → расхождение):
//!     - все float-настройки settings.* (cell_size, cell_height, agent_height,
//!       agent_radius, agent_max_climb, agent_max_slope, region_min_size,
//!       region_merge_size, edge_max_len, edge_max_error, verts_per_poly,
//!       detail_sample_dist, detail_sample_max_error) и settings.tile_size
//!       (когда обе стороны — числа)
//!     - bounds.min[0..3], bounds.max[0..3]
//!     - build_ms
//!
//! areas сопоставляются ПО id (а не по индексу); отсутствие area с данным id в
//! одном из файлов — расхождение.
//!
//! Память: все строки в FieldDiff (path/a/b) дублируются в ArenaAllocator,
//! который держит сам DiffReport. deinit освобождает арену целиком —
//! ручной free отдельных строк не требуется. На testing.allocator утечек нет.

const std = @import("std");

pub const FieldDiff = struct {
    path: []const u8, // напр. "navmesh.num_polys" или "bounds.min[1]"
    a: []const u8, // строковое представление значения из a
    b: []const u8, // из b
    rel: f32, // относительное расхождение (для чисел), 0 для строк/наличия
};

pub const DiffReport = struct {
    matched: usize,
    diffs: std.array_list.Managed(FieldDiff), // owned
    ok: bool, // true если расхождений сверх порога нет (CI exit-code)
    arena: std.heap.ArenaAllocator, // владеет дублированными строками path/a/b

    pub fn deinit(self: *DiffReport) void {
        self.diffs.deinit();
        self.arena.deinit();
    }
};

// --- внутреннее состояние для накопления расхождений ---

const Builder = struct {
    arena_alloc: std.mem.Allocator,
    rep: *DiffReport,

    fn addMatch(self: *Builder) void {
        self.rep.matched += 1;
    }

    fn addDiff(self: *Builder, path: []const u8, a: []const u8, b: []const u8, rel: f32) !void {
        const p = try self.arena_alloc.dupe(u8, path);
        const av = try self.arena_alloc.dupe(u8, a);
        const bv = try self.arena_alloc.dupe(u8, b);
        try self.rep.diffs.append(.{ .path = p, .a = av, .b = bv, .rel = rel });
        self.rep.ok = false;
    }

    fn addDiffFmt(
        self: *Builder,
        path: []const u8,
        comptime fmt_a: []const u8,
        args_a: anytype,
        comptime fmt_b: []const u8,
        args_b: anytype,
        rel: f32,
    ) !void {
        const p = try self.arena_alloc.dupe(u8, path);
        const av = try std.fmt.allocPrint(self.arena_alloc, fmt_a, args_a);
        const bv = try std.fmt.allocPrint(self.arena_alloc, fmt_b, args_b);
        try self.rep.diffs.append(.{ .path = p, .a = av, .b = bv, .rel = rel });
        self.rep.ok = false;
    }
};

// --- помощники по JSON-значениям ---

/// Привести числовое JSON-значение (.integer | .float | .number_string) к f64.
fn asF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Привести целочисленное JSON-значение к i64 (счётчики/id).
/// Принимает .integer; .float целочисленный тоже допускаем (JSON может прийти
/// как 150.0). .number_string — парсим.
fn asI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f == @floor(f)) @as(i64, @intFromFloat(f)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch blk: {
            const f = std.fmt.parseFloat(f64, s) catch break :blk null;
            break :blk if (f == @floor(f)) @as(i64, @intFromFloat(f)) else null;
        },
        else => null,
    };
}

fn relNum(a: f64, b: f64) f64 {
    const denom = @max(@max(@abs(a), @abs(b)), 1.0);
    return @abs(a - b) / denom;
}

fn getField(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    return obj.object.get(key);
}

// --- сравнение конкретных видов полей ---

/// EPS-сравнение числового поля. Обе стороны должны быть числами.
fn cmpEpsNum(b: *Builder, path: []const u8, a: std.json.Value, bv: std.json.Value, eps: f32) !void {
    const an = asF64(a) orelse {
        try b.addDiff(path, "<not-a-number>", "<num>", 0);
        return;
    };
    const bn = asF64(bv) orelse {
        try b.addDiff(path, "<num>", "<not-a-number>", 0);
        return;
    };
    const rel = relNum(an, bn);
    if (rel > eps) {
        try b.addDiffFmt(path, "{d}", .{an}, "{d}", .{bn}, @floatCast(rel));
    } else {
        b.addMatch();
    }
}

/// ТОЧНОЕ сравнение целочисленного поля (счётчик/id/schema_version).
fn cmpExactInt(b: *Builder, path: []const u8, a: std.json.Value, bv: std.json.Value) !void {
    const ai = asI64(a) orelse {
        try b.addDiff(path, "<not-an-int>", "<int>", 0);
        return;
    };
    const bi = asI64(bv) orelse {
        try b.addDiff(path, "<int>", "<not-an-int>", 0);
        return;
    };
    if (ai == bi) {
        b.addMatch();
    } else {
        const rel: f32 = @floatCast(relNum(@floatFromInt(ai), @floatFromInt(bi)));
        try b.addDiffFmt(path, "{d}", .{ai}, "{d}", .{bi}, rel);
    }
}

/// ТОЧНОЕ сравнение строкового поля.
fn cmpExactStr(b: *Builder, path: []const u8, a: std.json.Value, bv: std.json.Value) !void {
    const as_: ?[]const u8 = if (a == .string) a.string else null;
    const bs_: ?[]const u8 = if (bv == .string) bv.string else null;
    if (as_ == null or bs_ == null) {
        try b.addDiff(
            path,
            if (as_) |s| s else "<not-a-string>",
            if (bs_) |s| s else "<not-a-string>",
            0,
        );
        return;
    }
    if (std.mem.eql(u8, as_.?, bs_.?)) {
        b.addMatch();
    } else {
        try b.addDiff(path, as_.?, bs_.?, 0);
    }
}

// --- наборы имён полей ---

const settings_float_fields = [_][]const u8{
    "cell_size",            "cell_height",
    "agent_height",         "agent_radius",
    "agent_max_climb",      "agent_max_slope",
    "region_min_size",      "region_merge_size",
    "edge_max_len",         "edge_max_error",
    "verts_per_poly",       "detail_sample_dist",
    "detail_sample_max_error",
};

const navmesh_count_fields = [_][]const u8{
    "num_tiles", "num_polys", "num_verts", "max_polys",
};

// --- секции ---

fn diffSource(b: *Builder, a_root: std.json.Value, b_root: std.json.Value) !void {
    const a_src = getField(a_root, "source");
    const b_src = getField(b_root, "source");
    if (a_src == null and b_src == null) return;
    if (a_src == null or b_src == null) {
        try b.addDiff("source", if (a_src == null) "<missing>" else "<present>", if (b_src == null) "<missing>" else "<present>", 0);
        return;
    }
    inline for (.{ "geom", "sample" }) |key| {
        const av = getField(a_src.?, key);
        const bv = getField(b_src.?, key);
        if (av != null and bv != null) {
            try cmpExactStr(b, "source." ++ key, av.?, bv.?);
        } else if (av != null or bv != null) {
            try b.addDiff("source." ++ key, if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
        }
    }
}

fn diffSettings(b: *Builder, a_root: std.json.Value, b_root: std.json.Value, eps: f32) !void {
    const a_s = getField(a_root, "settings");
    const b_s = getField(b_root, "settings");
    if (a_s == null and b_s == null) return;
    if (a_s == null or b_s == null) {
        try b.addDiff("settings", if (a_s == null) "<missing>" else "<present>", if (b_s == null) "<missing>" else "<present>", 0);
        return;
    }

    // float-настройки — EPS
    inline for (settings_float_fields) |key| {
        const av = getField(a_s.?, key);
        const bv = getField(b_s.?, key);
        if (av != null and bv != null) {
            try cmpEpsNum(b, "settings." ++ key, av.?, bv.?, eps);
        } else if (av != null or bv != null) {
            try b.addDiff("settings." ++ key, if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
        }
    }

    // partition — строка, ТОЧНО
    {
        const av = getField(a_s.?, "partition");
        const bv = getField(b_s.?, "partition");
        if (av != null and bv != null) {
            try cmpExactStr(b, "settings.partition", av.?, bv.?);
        } else if (av != null or bv != null) {
            try b.addDiff("settings.partition", if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
        }
    }

    // tile_size — float|null. null vs число — расхождение; число vs число — EPS.
    {
        const av = getField(a_s.?, "tile_size");
        const bv = getField(b_s.?, "tile_size");
        const a_present = av != null and av.? != .null;
        const b_present = bv != null and bv.? != .null;
        if (!a_present and !b_present) {
            // оба null/отсутствуют — совпадение
            if (av != null or bv != null) b.addMatch();
        } else if (a_present and b_present) {
            try cmpEpsNum(b, "settings.tile_size", av.?, bv.?, eps);
        } else {
            try b.addDiff(
                "settings.tile_size",
                if (a_present) "<num>" else "null",
                if (b_present) "<num>" else "null",
                0,
            );
        }
    }
}

fn diffBoundsVec(b: *Builder, comptime which: []const u8, a_b: std.json.Value, b_b: std.json.Value, eps: f32) !void {
    const av = getField(a_b, which);
    const bv = getField(b_b, which);
    if (av == null and bv == null) return;
    if (av == null or bv == null or av.? != .array or bv.? != .array) {
        try b.addDiff("bounds." ++ which, "<vec3>", "<vec3>", 0);
        return;
    }
    const aa = av.?.array.items;
    const ba = bv.?.array.items;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        // путь формируем динамически (индекс)
        var buf: [32]u8 = undefined;
        const dyn = std.fmt.bufPrint(&buf, "bounds." ++ which ++ "[{d}]", .{i}) catch unreachable;
        if (i >= aa.len or i >= ba.len) {
            try b.addDiff(dyn, "<short>", "<short>", 0);
            continue;
        }
        try cmpEpsNum(b, dyn, aa[i], ba[i], eps);
    }
}

fn diffBounds(b: *Builder, a_root: std.json.Value, b_root: std.json.Value, eps: f32) !void {
    const a_b = getField(a_root, "bounds");
    const b_b = getField(b_root, "bounds");
    if (a_b == null and b_b == null) return;
    if (a_b == null or b_b == null) {
        try b.addDiff("bounds", if (a_b == null) "<missing>" else "<present>", if (b_b == null) "<missing>" else "<present>", 0);
        return;
    }
    try diffBoundsVec(b, "min", a_b.?, b_b.?, eps);
    try diffBoundsVec(b, "max", a_b.?, b_b.?, eps);
}

fn diffNavmesh(b: *Builder, a_root: std.json.Value, b_root: std.json.Value) !void {
    const a_n = getField(a_root, "navmesh");
    const b_n = getField(b_root, "navmesh");
    if (a_n == null and b_n == null) return;
    if (a_n == null or b_n == null) {
        try b.addDiff("navmesh", if (a_n == null) "<missing>" else "<present>", if (b_n == null) "<missing>" else "<present>", 0);
        return;
    }
    inline for (navmesh_count_fields) |key| {
        const av = getField(a_n.?, key);
        const bv = getField(b_n.?, key);
        if (av != null and bv != null) {
            try cmpExactInt(b, "navmesh." ++ key, av.?, bv.?);
        } else if (av != null or bv != null) {
            try b.addDiff("navmesh." ++ key, if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
        }
    }
}

fn diffAreas(b: *Builder, a_root: std.json.Value, b_root: std.json.Value) !void {
    const a_a = getField(a_root, "areas");
    const b_a = getField(b_root, "areas");
    if (a_a == null and b_a == null) return;
    if (a_a == null or b_a == null or a_a.? != .array or b_a.? != .array) {
        try b.addDiff("areas", if (a_a == null) "<missing>" else "<present>", if (b_a == null) "<missing>" else "<present>", 0);
        return;
    }
    const a_items = a_a.?.array.items;
    const b_items = b_a.?.array.items;

    // Матчим по id. Для каждой area из a ищем area с тем же id в b.
    for (a_items) |a_area| {
        const a_id_v = getField(a_area, "id") orelse continue;
        const a_id = asI64(a_id_v) orelse continue;
        var found: ?std.json.Value = null;
        for (b_items) |b_area| {
            const b_id_v = getField(b_area, "id") orelse continue;
            const b_id = asI64(b_id_v) orelse continue;
            if (a_id == b_id) {
                found = b_area;
                break;
            }
        }
        var pbuf: [48]u8 = undefined;
        if (found == null) {
            const p = std.fmt.bufPrint(&pbuf, "areas[id={d}]", .{a_id}) catch "areas[?]";
            try b.addDiff(p, "<present>", "<missing>", 0);
            continue;
        }
        // сравнить name (строка, точно) и poly_count (счётчик, точно)
        {
            const av = getField(a_area, "name");
            const bv = getField(found.?, "name");
            if (av != null and bv != null) {
                const p = std.fmt.bufPrint(&pbuf, "areas[id={d}].name", .{a_id}) catch "areas[?].name";
                try cmpExactStr(b, p, av.?, bv.?);
            }
        }
        {
            const av = getField(a_area, "poly_count");
            const bv = getField(found.?, "poly_count");
            if (av != null and bv != null) {
                var pbuf2: [48]u8 = undefined;
                const p = std.fmt.bufPrint(&pbuf2, "areas[id={d}].poly_count", .{a_id}) catch "areas[?].poly_count";
                try cmpExactInt(b, p, av.?, bv.?);
            }
        }
    }

    // areas, присутствующие в b, но отсутствующие в a.
    for (b_items) |b_area| {
        const b_id_v = getField(b_area, "id") orelse continue;
        const b_id = asI64(b_id_v) orelse continue;
        var exists = false;
        for (a_items) |a_area| {
            const a_id_v = getField(a_area, "id") orelse continue;
            const a_id = asI64(a_id_v) orelse continue;
            if (a_id == b_id) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var pbuf: [48]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "areas[id={d}]", .{b_id}) catch "areas[?]";
            try b.addDiff(p, "<missing>", "<present>", 0);
        }
    }
}

fn diffBuildMs(b: *Builder, a_root: std.json.Value, b_root: std.json.Value, eps: f32) !void {
    const av = getField(a_root, "build_ms");
    const bv = getField(b_root, "build_ms");
    if (av == null and bv == null) return;
    if (av != null and bv != null) {
        try cmpEpsNum(b, "build_ms", av.?, bv.?, eps);
    } else {
        try b.addDiff("build_ms", if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
    }
}

/// Сравнить два D3-JSON.
///
/// ЧИСЛОВЫЕ float-поля: расходятся если |a-b|/max(1,|a|,|b|) > eps.
/// СЧЁТЧИКИ (navmesh.*, areas[].poly_count/id, schema_version) — ТОЧНОЕ
/// равенство (eps не применяется).
/// СТРОКИ (partition, names, source) — точное равенство.
/// tile_size null vs число — расхождение. areas сопоставляются по id.
/// `ok` = нет расхождений (для CI exit-code).
pub fn diff(alloc: std.mem.Allocator, a_json: []const u8, b_json: []const u8, eps: f32) !DiffReport {
    var parsed_a = try std.json.parseFromSlice(std.json.Value, alloc, a_json, .{});
    defer parsed_a.deinit();
    var parsed_b = try std.json.parseFromSlice(std.json.Value, alloc, b_json, .{});
    defer parsed_b.deinit();

    var rep = DiffReport{
        .matched = 0,
        .diffs = std.array_list.Managed(FieldDiff).init(alloc),
        .ok = true,
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    errdefer rep.deinit();

    var b = Builder{ .arena_alloc = rep.arena.allocator(), .rep = &rep };

    const a_root = parsed_a.value;
    const b_root = parsed_b.value;

    // schema_version — счётчик, ТОЧНО
    {
        const av = getField(a_root, "schema_version");
        const bv = getField(b_root, "schema_version");
        if (av != null and bv != null) {
            try cmpExactInt(&b, "schema_version", av.?, bv.?);
        } else if (av != null or bv != null) {
            try b.addDiff("schema_version", if (av == null) "<missing>" else "<present>", if (bv == null) "<missing>" else "<present>", 0);
        }
    }

    try diffSource(&b, a_root, b_root);
    try diffSettings(&b, a_root, b_root, eps);
    try diffBounds(&b, a_root, b_root, eps);
    try diffNavmesh(&b, a_root, b_root);
    try diffAreas(&b, a_root, b_root);
    try diffBuildMs(&b, a_root, b_root, eps);

    return rep;
}

/// Человекочитаемый отчёт в writer.
pub fn writeReport(writer: anytype, rep: DiffReport) !void {
    try writer.print("MATCH {d} fields\n", .{rep.matched});
    for (rep.diffs.items) |d| {
        try writer.print("DIFF {s}: a={s} b={s} (rel={d})\n", .{ d.path, d.a, d.b, d.rel });
    }
    if (rep.ok) {
        try writer.print("OK (no diffs over threshold)\n", .{});
    } else {
        try writer.print("FAIL ({d} diffs)\n", .{rep.diffs.items.len});
    }
}

// =====================================================================
// Тесты
// =====================================================================

const testing = std.testing;

const sample_json =
    \\{
    \\  "schema_version": 1,
    \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
    \\  "settings": {
    \\    "cell_size": 0.30, "cell_height": 0.20,
    \\    "agent_height": 2.0, "agent_radius": 0.6,
    \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
    \\    "region_min_size": 8.0, "region_merge_size": 20.0,
    \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
    \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
    \\    "detail_sample_max_error": 1.0,
    \\    "partition": "watershed", "tile_size": null
    \\  },
    \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
    \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
    \\  "areas": [
    \\    { "id": 0, "name": "Ground", "poly_count": 120 },
    \\    { "id": 1, "name": "Water", "poly_count": 29 }
    \\  ],
    \\  "build_ms": 12.34
    \\}
;

test "identical JSON → ok, no diffs, matched>0" {
    var rep = try diff(testing.allocator, sample_json, sample_json, 1e-4);
    defer rep.deinit();
    try testing.expect(rep.ok);
    try testing.expectEqual(@as(usize, 0), rep.diffs.items.len);
    try testing.expect(rep.matched > 0);
}

test "float within eps → not a diff" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30001, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 },
        \\    { "id": 1, "name": "Water", "poly_count": 29 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-3);
    defer rep.deinit();
    try testing.expect(rep.ok);
    try testing.expectEqual(@as(usize, 0), rep.diffs.items.len);
}

test "float over eps → diff with rel" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.50, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 },
        \\    { "id": 1, "name": "Water", "poly_count": 29 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();
    try testing.expect(!rep.ok);
    try testing.expectEqual(@as(usize, 1), rep.diffs.items.len);
    try testing.expectEqualStrings("settings.cell_size", rep.diffs.items[0].path);
    try testing.expect(rep.diffs.items[0].rel > 0.0);
}

test "counter num_polys 149 vs 150 → diff (exact, eps doesn't save)" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 150, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 },
        \\    { "id": 1, "name": "Water", "poly_count": 29 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    // даже с гигантским eps счётчик должен расходиться
    var rep = try diff(testing.allocator, a, b, 100.0);
    defer rep.deinit();
    try testing.expect(!rep.ok);
    var found = false;
    for (rep.diffs.items) |d| {
        if (std.mem.eql(u8, d.path, "navmesh.num_polys")) found = true;
    }
    try testing.expect(found);
}

test "partition watershed vs monotone → diff (string)" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "monotone", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 },
        \\    { "id": 1, "name": "Water", "poly_count": 29 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();
    try testing.expect(!rep.ok);
    var found = false;
    for (rep.diffs.items) |d| {
        if (std.mem.eql(u8, d.path, "settings.partition")) {
            found = true;
            try testing.expectEqualStrings("watershed", d.a);
            try testing.expectEqualStrings("monotone", d.b);
            try testing.expectEqual(@as(f32, 0.0), d.rel);
        }
    }
    try testing.expect(found);
}

test "tile_size null vs 48 → diff" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": 48.0
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 },
        \\    { "id": 1, "name": "Water", "poly_count": 29 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();
    try testing.expect(!rep.ok);
    var found = false;
    for (rep.diffs.items) |d| {
        if (std.mem.eql(u8, d.path, "settings.tile_size")) {
            found = true;
            try testing.expectEqualStrings("null", d.a);
            try testing.expectEqualStrings("<num>", d.b);
        }
    }
    try testing.expect(found);
}

test "areas matched by id: a has id=1, b doesn't → diff" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 0, "name": "Ground", "poly_count": 120 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();
    try testing.expect(!rep.ok);
    var found = false;
    for (rep.diffs.items) |d| {
        if (std.mem.eql(u8, d.path, "areas[id=1]")) {
            found = true;
            try testing.expectEqualStrings("<present>", d.a);
            try testing.expectEqualStrings("<missing>", d.b);
        }
    }
    try testing.expect(found);
}

test "areas matched by id, not by index" {
    // a: [id=0, id=1]; b: [id=1, id=0] — порядок разный, но по id совпадают
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "source": { "geom": "dungeon.obj", "sample": "solo" },
        \\  "settings": {
        \\    "cell_size": 0.30, "cell_height": 0.20,
        \\    "agent_height": 2.0, "agent_radius": 0.6,
        \\    "agent_max_climb": 0.9, "agent_max_slope": 45.0,
        \\    "region_min_size": 8.0, "region_merge_size": 20.0,
        \\    "edge_max_len": 12.0, "edge_max_error": 1.3,
        \\    "verts_per_poly": 6.0, "detail_sample_dist": 6.0,
        \\    "detail_sample_max_error": 1.0,
        \\    "partition": "watershed", "tile_size": null
        \\  },
        \\  "bounds": { "min": [-10.0, -2.0, -10.0], "max": [10.0, 5.0, 10.0] },
        \\  "navmesh": { "num_tiles": 1, "num_polys": 149, "num_verts": 300, "max_polys": 256 },
        \\  "areas": [
        \\    { "id": 1, "name": "Water", "poly_count": 29 },
        \\    { "id": 0, "name": "Ground", "poly_count": 120 }
        \\  ],
        \\  "build_ms": 12.34
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();
    try testing.expect(rep.ok);
    try testing.expectEqual(@as(usize, 0), rep.diffs.items.len);
}

test "writeReport doesn't crash, prints MATCH/DIFF" {
    const a = sample_json;
    const b =
        \\{
        \\  "schema_version": 1,
        \\  "navmesh": { "num_tiles": 1, "num_polys": 150, "num_verts": 300, "max_polys": 256 }
        \\}
    ;
    var rep = try diff(testing.allocator, a, b, 1e-4);
    defer rep.deinit();

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeReport(&aw.writer, rep);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "MATCH") != null);
    try testing.expect(std.mem.indexOf(u8, out, "DIFF") != null);
}
