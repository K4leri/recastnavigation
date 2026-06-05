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
