//! BUILD INSPECTOR — per-stage Solo navmesh build counters + wall-clock times.
//! Чистая структура статистики + форматирование строк таблицы (без UI/recast),
//! чтобы метки/формат были юнит-тестируемы. Живой сбор — в sample_solo.doBuild,
//! который заполняет StageStats после каждой стадии пайплайна.
//!
//! Pure stats struct + row formatting (no UI, no recast deps) so labels/format
//! are unit-testable. Live gathering happens in sample_solo.doBuild, which fills
//! each StageStats right after the matching pipeline stage produces its result.

const std = @import("std");

/// 7 стадий Solo-пайплайна (порядок = индекс в BuildStats.stages).
/// The 7 Solo pipeline stages (order == index into BuildStats.stages).
pub const Stage = enum {
    heightfield,
    compact,
    distancefield,
    regions,
    contours,
    polymesh,
    detail,
};

pub const STAGE_COUNT = @typeInfo(Stage).@"enum".fields.len;

/// Тип партиционирования регионов (зеркало sample.SamplePartitionType — held
/// here so this module stays free of the sample/UI imports).
pub const Partition = enum { watershed, monotone, layers };

/// Метрики одной стадии. Каждая стадия пишет в СВОЙ набор полей (остальные = 0);
/// `formatStageRow` печатает только релевантные для данной стадии счётчики.
/// `ran == false` => N/A (например distancefield для monotone/layers).
///
/// Per-stage metrics. Each stage fills only its OWN fields (others stay 0);
/// `formatStageRow` prints just the counters relevant to that stage.
pub const StageStats = struct {
    ran: bool = false,
    ms: f32 = 0,

    // heightfield
    spans: u64 = 0,
    walkable_spans: u64 = 0,
    // compact
    compact_spans: u64 = 0,
    walkable_height: i32 = 0,
    walkable_climb: i32 = 0,
    // distancefield (watershed only)
    max_distance: u32 = 0,
    // regions
    max_regions: u32 = 0,
    // contours
    nconts: u32 = 0,
    raw_verts: u64 = 0,
    simplified_verts: u64 = 0,
    // polymesh
    pm_verts: u64 = 0,
    pm_polys: u64 = 0,
    nvp: i32 = 0,
    // detail
    dm_meshes: u64 = 0,
    dm_verts: u64 = 0,
    dm_tris: u64 = 0,
};

pub const BuildStats = struct {
    stages: [STAGE_COUNT]StageStats = [_]StageStats{.{}} ** STAGE_COUNT,
    total_ms: f32 = 0,
    partition: Partition = .watershed,

    /// Сброс перед каждой сборкой (все стадии -> N/A, счётчики -> 0).
    pub fn reset(self: *BuildStats) void {
        self.stages = [_]StageStats{.{}} ** STAGE_COUNT;
        self.total_ms = 0;
    }

    /// Доступ к статистике стадии по enum.
    pub fn stage(self: *BuildStats, s: Stage) *StageStats {
        return &self.stages[@intFromEnum(s)];
    }
};

/// Человекочитаемая метка стадии (для таблицы).
pub fn stageLabel(s: Stage) []const u8 {
    return switch (s) {
        .heightfield => "heightfield",
        .compact => "compact",
        .distancefield => "distancefield",
        .regions => "regions",
        .contours => "contours",
        .polymesh => "polymesh",
        .detail => "detail",
    };
}

/// Форматирует одну строку таблицы: "<label>  <counters>  <ms>ms" (или N/A).
/// Возвращает срез внутри `buf`. Печатаются только счётчики данной стадии.
///
/// Renders one table row into `buf`; only the counters owned by `s` are printed.
pub fn formatStageRow(buf: []u8, s: Stage, st: StageStats) []const u8 {
    const label = stageLabel(s);
    if (!st.ran) {
        return std.fmt.bufPrint(buf, "{s:<13} N/A", .{label}) catch buf[0..0];
    }
    return switch (s) {
        .heightfield => std.fmt.bufPrint(buf, "{s:<13} spans={d} walk={d}  {d:.2}ms", .{ label, st.spans, st.walkable_spans, st.ms }),
        .compact => std.fmt.bufPrint(buf, "{s:<13} spans={d} wh={d} wc={d}  {d:.2}ms", .{ label, st.compact_spans, st.walkable_height, st.walkable_climb, st.ms }),
        .distancefield => std.fmt.bufPrint(buf, "{s:<13} maxDist={d}  {d:.2}ms", .{ label, st.max_distance, st.ms }),
        .regions => std.fmt.bufPrint(buf, "{s:<13} maxRegions={d}  {d:.2}ms", .{ label, st.max_regions, st.ms }),
        .contours => std.fmt.bufPrint(buf, "{s:<13} conts={d} raw={d} simpl={d}  {d:.2}ms", .{ label, st.nconts, st.raw_verts, st.simplified_verts, st.ms }),
        .polymesh => std.fmt.bufPrint(buf, "{s:<13} verts={d} polys={d} nvp={d}  {d:.2}ms", .{ label, st.pm_verts, st.pm_polys, st.nvp, st.ms }),
        .detail => std.fmt.bufPrint(buf, "{s:<13} meshes={d} verts={d} tris={d}  {d:.2}ms", .{ label, st.dm_meshes, st.dm_verts, st.dm_tris, st.ms }),
    } catch buf[0..0];
}

// ============================================================================
// DIFF LAYER (B-2) — per-stage signed deltas between two BuildStats snapshots.
// Чисто вычислительный слой; ни UI, ни recast-зависимостей нет.
// Pure computation layer; no UI or recast deps.
// ============================================================================

/// Знаковые дельты одной стадии (after − before). Счётчики — i64 (разность u64);
/// время — f32. Пара ran_before/ran_after: для корректного отображения N/A-переходов.
///
/// Signed per-stage deltas (after − before). Counts are i64 (difference of u64);
/// ms is f32. ran_before/ran_after track N/A transitions.
pub const StageDelta = struct {
    ran_before: bool,
    ran_after: bool,
    ms: f32,

    // heightfield
    spans: i64,
    walkable_spans: i64,
    // compact
    compact_spans: i64,
    walkable_height: i64,
    walkable_climb: i64,
    // distancefield
    max_distance: i64,
    // regions
    max_regions: i64,
    // contours
    nconts: i64,
    raw_verts: i64,
    simplified_verts: i64,
    // polymesh
    pm_verts: i64,
    pm_polys: i64,
    nvp: i64,
    // detail
    dm_meshes: i64,
    dm_verts: i64,
    dm_tris: i64,
};

/// Вычисляет after − before для одной стадии `s`. Чистая функция; не читает UI.
/// Computes after − before for stage `s`. Pure; reads no UI state.
pub fn diffStage(before: StageStats, after: StageStats, _: Stage) StageDelta {
    return .{
        .ran_before = before.ran,
        .ran_after = after.ran,
        .ms = after.ms - before.ms,
        .spans = @as(i64, @intCast(after.spans)) - @as(i64, @intCast(before.spans)),
        .walkable_spans = @as(i64, @intCast(after.walkable_spans)) - @as(i64, @intCast(before.walkable_spans)),
        .compact_spans = @as(i64, @intCast(after.compact_spans)) - @as(i64, @intCast(before.compact_spans)),
        .walkable_height = @as(i64, after.walkable_height) - @as(i64, before.walkable_height),
        .walkable_climb = @as(i64, after.walkable_climb) - @as(i64, before.walkable_climb),
        .max_distance = @as(i64, @intCast(after.max_distance)) - @as(i64, @intCast(before.max_distance)),
        .max_regions = @as(i64, @intCast(after.max_regions)) - @as(i64, @intCast(before.max_regions)),
        .nconts = @as(i64, @intCast(after.nconts)) - @as(i64, @intCast(before.nconts)),
        .raw_verts = @as(i64, @intCast(after.raw_verts)) - @as(i64, @intCast(before.raw_verts)),
        .simplified_verts = @as(i64, @intCast(after.simplified_verts)) - @as(i64, @intCast(before.simplified_verts)),
        .pm_verts = @as(i64, @intCast(after.pm_verts)) - @as(i64, @intCast(before.pm_verts)),
        .pm_polys = @as(i64, @intCast(after.pm_polys)) - @as(i64, @intCast(before.pm_polys)),
        .nvp = @as(i64, after.nvp) - @as(i64, before.nvp),
        .dm_meshes = @as(i64, @intCast(after.dm_meshes)) - @as(i64, @intCast(before.dm_meshes)),
        .dm_verts = @as(i64, @intCast(after.dm_verts)) - @as(i64, @intCast(before.dm_verts)),
        .dm_tris = @as(i64, @intCast(after.dm_tris)) - @as(i64, @intCast(before.dm_tris)),
    };
}

/// Рендерит строку дельты для стадии `s` в `buf`. Формат:
///   "  Δspans=+3 Δwalk=-1  Δ+0.4ms"
/// Переходы N/A->ran: "(was N/A)", ran->N/A: "(now N/A)".
/// Нет изменений: "(no change)".
/// Возвращает срез внутри buf.
///
/// Renders one delta line into `buf`. Returns slice within `buf`.
/// N/A transitions: "(was N/A)" / "(now N/A)".
/// All-zero diff: "(no change)".
pub fn formatStageDelta(buf: []u8, s: Stage, d: StageDelta) []const u8 {
    // N/A transitions: one side did not run.
    if (!d.ran_before and d.ran_after) {
        return std.fmt.bufPrint(buf, "  (was N/A)", .{}) catch buf[0..0];
    }
    if (d.ran_before and !d.ran_after) {
        return std.fmt.bufPrint(buf, "  (now N/A)", .{}) catch buf[0..0];
    }
    // Both N/A: nothing to show.
    if (!d.ran_before and !d.ran_after) {
        return std.fmt.bufPrint(buf, "  (no change)", .{}) catch buf[0..0];
    }

    // Both ran: check if all relevant deltas are zero.
    // Use a local check: all deltas zero?
    const all_zero: bool = switch (s) {
        .heightfield => d.spans == 0 and d.walkable_spans == 0 and d.ms == 0,
        .compact => d.compact_spans == 0 and d.walkable_height == 0 and d.walkable_climb == 0 and d.ms == 0,
        .distancefield => d.max_distance == 0 and d.ms == 0,
        .regions => d.max_regions == 0 and d.ms == 0,
        .contours => d.nconts == 0 and d.raw_verts == 0 and d.simplified_verts == 0 and d.ms == 0,
        .polymesh => d.pm_verts == 0 and d.pm_polys == 0 and d.nvp == 0 and d.ms == 0,
        .detail => d.dm_meshes == 0 and d.dm_verts == 0 and d.dm_tris == 0 and d.ms == 0,
    };
    if (all_zero) {
        return std.fmt.bufPrint(buf, "  (no change)", .{}) catch buf[0..0];
    }

    // Format signed deltas for only the counters relevant to this stage.
    // Zig fmt (0.16) does not support the '+' fill/align specifier on integers or
    // floats, so we print sign+|value| explicitly via si() / sf() helpers.
    const si = struct {
        fn sgn(v: i64) []const u8 {
            return if (v >= 0) "+" else "-";
        }
        fn abs(v: i64) i64 {
            return if (v < 0) -v else v;
        }
    };
    const ms_sign: []const u8 = if (d.ms >= 0) "+" else "";
    const ms_abs: f32 = if (d.ms < 0) -d.ms else d.ms;
    return switch (s) {
        .heightfield => std.fmt.bufPrint(buf, "  Δspans={s}{d} Δwalk={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.spans), si.abs(d.spans), si.sgn(d.walkable_spans), si.abs(d.walkable_spans), ms_sign, ms_abs }),
        .compact => std.fmt.bufPrint(buf, "  Δspans={s}{d} Δwh={s}{d} Δwc={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.compact_spans), si.abs(d.compact_spans), si.sgn(d.walkable_height), si.abs(d.walkable_height), si.sgn(d.walkable_climb), si.abs(d.walkable_climb), ms_sign, ms_abs }),
        .distancefield => std.fmt.bufPrint(buf, "  ΔmaxDist={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.max_distance), si.abs(d.max_distance), ms_sign, ms_abs }),
        .regions => std.fmt.bufPrint(buf, "  ΔmaxRegions={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.max_regions), si.abs(d.max_regions), ms_sign, ms_abs }),
        .contours => std.fmt.bufPrint(buf, "  Δconts={s}{d} Δraw={s}{d} Δsimpl={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.nconts), si.abs(d.nconts), si.sgn(d.raw_verts), si.abs(d.raw_verts), si.sgn(d.simplified_verts), si.abs(d.simplified_verts), ms_sign, ms_abs }),
        .polymesh => std.fmt.bufPrint(buf, "  Δverts={s}{d} Δpolys={s}{d} Δnvp={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.pm_verts), si.abs(d.pm_verts), si.sgn(d.pm_polys), si.abs(d.pm_polys), si.sgn(d.nvp), si.abs(d.nvp), ms_sign, ms_abs }),
        .detail => std.fmt.bufPrint(buf, "  Δmeshes={s}{d} Δverts={s}{d} Δtris={s}{d}  Δ{s}{d:.2}ms", .{ si.sgn(d.dm_meshes), si.abs(d.dm_meshes), si.sgn(d.dm_verts), si.abs(d.dm_verts), si.sgn(d.dm_tris), si.abs(d.dm_tris), ms_sign, ms_abs }),
    } catch buf[0..0];
}

// ============================================================================
// TESTS — pure label/format helpers.
// ============================================================================
const testing = std.testing;

test "stageLabel covers all 7 stages" {
    try testing.expectEqualStrings("heightfield", stageLabel(.heightfield));
    try testing.expectEqualStrings("compact", stageLabel(.compact));
    try testing.expectEqualStrings("distancefield", stageLabel(.distancefield));
    try testing.expectEqualStrings("regions", stageLabel(.regions));
    try testing.expectEqualStrings("contours", stageLabel(.contours));
    try testing.expectEqualStrings("polymesh", stageLabel(.polymesh));
    try testing.expectEqualStrings("detail", stageLabel(.detail));
    // ensure none is empty
    inline for (@typeInfo(Stage).@"enum".fields) |f| {
        try testing.expect(stageLabel(@field(Stage, f.name)).len > 0);
    }
}

test "formatStageRow heightfield prints counters + ms" {
    var buf: [128]u8 = undefined;
    const row = formatStageRow(&buf, .heightfield, .{ .ran = true, .ms = 3.2, .spans = 1234, .walkable_spans = 900 });
    try testing.expectEqualStrings("heightfield   spans=1234 walk=900  3.20ms", row);
}

test "formatStageRow N/A when stage did not run" {
    var buf: [128]u8 = undefined;
    const row = formatStageRow(&buf, .distancefield, .{ .ran = false });
    try testing.expectEqualStrings("distancefield N/A", row);
}

test "formatStageRow polymesh" {
    var buf: [128]u8 = undefined;
    const row = formatStageRow(&buf, .polymesh, .{ .ran = true, .ms = 0.5, .pm_verts = 42, .pm_polys = 17, .nvp = 6 });
    try testing.expectEqualStrings("polymesh      verts=42 polys=17 nvp=6  0.50ms", row);
}

test "BuildStats reset clears stages and total" {
    var bs = BuildStats{};
    bs.stage(.heightfield).ran = true;
    bs.stage(.heightfield).spans = 99;
    bs.total_ms = 12.5;
    bs.reset();
    try testing.expect(!bs.stage(.heightfield).ran);
    try testing.expectEqual(@as(u64, 0), bs.stage(.heightfield).spans);
    try testing.expectEqual(@as(f32, 0), bs.total_ms);
}

// ============================================================================
// TESTS — diffStage + formatStageDelta (B-2).
// ============================================================================

test "diffStage heightfield: correct signed deltas" {
    const before = StageStats{ .ran = true, .ms = 1.0, .spans = 100, .walkable_spans = 80 };
    const after = StageStats{ .ran = true, .ms = 1.5, .spans = 97, .walkable_spans = 83 };
    const d = diffStage(before, after, .heightfield);
    try testing.expect(d.ran_before);
    try testing.expect(d.ran_after);
    try testing.expectEqual(@as(i64, -3), d.spans);
    try testing.expectEqual(@as(i64, 3), d.walkable_spans);
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.ms, 1e-5);
}

test "diffStage regions: correct signed deltas" {
    const before = StageStats{ .ran = true, .ms = 2.0, .max_regions = 10 };
    const after = StageStats{ .ran = true, .ms = 1.6, .max_regions = 7 };
    const d = diffStage(before, after, .regions);
    try testing.expectEqual(@as(i64, -3), d.max_regions);
    try testing.expectApproxEqAbs(@as(f32, -0.4), d.ms, 1e-5);
}

test "diffStage detail: correct signed deltas" {
    const before = StageStats{ .ran = true, .ms = 0.5, .dm_meshes = 5, .dm_verts = 20, .dm_tris = 30 };
    const after = StageStats{ .ran = true, .ms = 0.7, .dm_meshes = 6, .dm_verts = 22, .dm_tris = 28 };
    const d = diffStage(before, after, .detail);
    try testing.expectEqual(@as(i64, 1), d.dm_meshes);
    try testing.expectEqual(@as(i64, 2), d.dm_verts);
    try testing.expectEqual(@as(i64, -2), d.dm_tris);
}

test "diffStage all-zero: both ran, no change" {
    const st = StageStats{ .ran = true, .ms = 1.0, .spans = 50, .walkable_spans = 40 };
    const d = diffStage(st, st, .heightfield);
    try testing.expectEqual(@as(i64, 0), d.spans);
    try testing.expectEqual(@as(i64, 0), d.walkable_spans);
    try testing.expectApproxEqAbs(@as(f32, 0), d.ms, 1e-5);
}

test "diffStage N/A transition: before not ran, after ran" {
    const before = StageStats{ .ran = false };
    const after = StageStats{ .ran = true, .ms = 0.3, .max_distance = 5 };
    const d = diffStage(before, after, .distancefield);
    try testing.expect(!d.ran_before);
    try testing.expect(d.ran_after);
}

test "formatStageDelta: heightfield with count+ms changes" {
    var buf: [160]u8 = undefined;
    const before = StageStats{ .ran = true, .ms = 1.0, .spans = 100, .walkable_spans = 80 };
    const after = StageStats{ .ran = true, .ms = 1.5, .spans = 97, .walkable_spans = 83 };
    const d = diffStage(before, after, .heightfield);
    const row = formatStageDelta(&buf, .heightfield, d);
    // должна содержать знаковые дельты / must contain signed deltas
    try testing.expect(row.len > 0);
    try testing.expect(std.mem.indexOf(u8, row, "-3") != null);
    try testing.expect(std.mem.indexOf(u8, row, "+3") != null);
}

test "formatStageDelta: all-zero diff yields (no change)" {
    var buf: [160]u8 = undefined;
    const st = StageStats{ .ran = true, .ms = 1.0, .spans = 50, .walkable_spans = 40 };
    const d = diffStage(st, st, .heightfield);
    const row = formatStageDelta(&buf, .heightfield, d);
    try testing.expectEqualStrings("  (no change)", row);
}

test "formatStageDelta: N/A to ran transition" {
    var buf: [160]u8 = undefined;
    const before = StageStats{ .ran = false };
    const after = StageStats{ .ran = true, .ms = 0.3, .max_distance = 5 };
    const d = diffStage(before, after, .distancefield);
    const row = formatStageDelta(&buf, .distancefield, d);
    try testing.expectEqualStrings("  (was N/A)", row);
}

test "formatStageDelta: ran to N/A transition" {
    var buf: [160]u8 = undefined;
    const before = StageStats{ .ran = true, .ms = 0.3, .max_distance = 5 };
    const after = StageStats{ .ran = false };
    const d = diffStage(before, after, .distancefield);
    const row = formatStageDelta(&buf, .distancefield, d);
    try testing.expectEqualStrings("  (now N/A)", row);
}
