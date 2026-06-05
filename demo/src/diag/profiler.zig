//! BUILD PROFILER + RUN HISTORY (cluster C, C1, P0).
//! Кольцевой буфер последних N=16 сборок (per-stage ms + total) + чистые
//! stats/layout-хелперы для панели Profiler: проценты стадий, доли для
//! горизонтального stacked-bar и нормализация total_ms для sparkline.
//!
//! Ring buffer of the last N=16 builds (per-stage ms + total) plus pure
//! stats/layout helpers for the Profiler panel: stage percents, fractions for
//! the horizontal stacked bar, and total_ms normalisation for the sparkline.
//!
//! DEMO-LEVEL only — faithful core (src/*) untouched. `History` is a VALUE type
//! (fixed array, no heap) so it copies by assignment and never leaks. Capture
//! happens once per successful build (sample_solo); the panel reads cached state.
//! Тестируемые load-bearing части — чистые хелперы; dvui-отрисовка панели не
//! юнит-тестируется (GUI).

const std = @import("std");
const dvui = @import("dvui");
const build_stats = @import("build_stats.zig");

const STAGE_COUNT = build_stats.STAGE_COUNT;

/// Снимок одной сборки для истории/панели. Только агрегаты, без счётчиков —
/// детальные счётчики живут в BuildStats (Build Inspector).
///
/// One build's snapshot for the history/panel. Aggregates only (per-stage ms +
/// total + a couple of headline counts); detailed counters stay in BuildStats.
pub const BuildProfile = struct {
    stage_ms: [STAGE_COUNT]f32 = [_]f32{0} ** STAGE_COUNT, // per-stage ms (0 for N/A)
    stage_ran: [STAGE_COUNT]bool = [_]bool{false} ** STAGE_COUNT,
    total_ms: f32 = 0,
    partition: build_stats.Partition = .watershed,
    n_polys: u32 = 0,
    n_regions: u32 = 0,
    gen: u64 = 0, // build generation number (history-list label)

    /// Снимок из BuildStats. `gen`/`n_polys`/`n_regions` передаёт вызывающий
    /// (они либо инкремент сборки, либо счётчики из соответствующих стадий).
    ///
    /// Snapshot from BuildStats. Caller passes the build generation and the two
    /// headline counts (poly/region) read from the matching stages.
    pub fn fromBuildStats(bs: *const build_stats.BuildStats, gen: u64, n_polys: u32, n_regions: u32) BuildProfile {
        var p = BuildProfile{
            .total_ms = bs.total_ms,
            .partition = bs.partition,
            .n_polys = n_polys,
            .n_regions = n_regions,
            .gen = gen,
        };
        for (0..STAGE_COUNT) |i| {
            p.stage_ms[i] = bs.stages[i].ms;
            p.stage_ran[i] = bs.stages[i].ran;
        }
        return p;
    }
};

/// Сколько сборок хранит история (кольцо).
/// How many builds the history ring keeps.
pub const HISTORY = 16;

/// Кольцевой буфер профилей. VALUE-тип: фиксированный массив, без heap —
/// копируется присваиванием, не требует deinit, не течёт.
///
/// Ring buffer of profiles. VALUE type: a fixed array, no heap — copies by
/// assignment, needs no deinit, cannot leak.
pub const History = struct {
    buf: [HISTORY]BuildProfile = undefined,
    head: usize = 0, // следующий слот записи / next write slot
    len: usize = 0, // сколько валидных элементов / valid element count

    /// Добавляет профиль; при заполнении перезаписывает самый старый.
    /// Pushes a profile; at capacity it overwrites the oldest.
    pub fn push(self: *History, p: BuildProfile) void {
        self.buf[self.head] = p;
        self.head = (self.head + 1) % HISTORY;
        if (self.len < HISTORY) self.len += 1;
    }

    /// Очищает историю (len -> 0). Слоты не зануляются — недоступны через at().
    /// Clears the history (len -> 0). Slots aren't zeroed — unreachable via at().
    pub fn clear(self: *History) void {
        self.head = 0;
        self.len = 0;
    }

    /// Логический доступ: i=0 — самый старый .. len-1 — самый новый.
    /// Logical access: i=0 oldest .. len-1 newest. null when out of range.
    pub fn at(self: *const History, i: usize) ?BuildProfile {
        if (i >= self.len) return null;
        // Самый старый элемент стоит за head (если буфер заполнен), иначе с 0.
        // Oldest sits at (head - len) modulo HISTORY.
        const start = (self.head + HISTORY - self.len) % HISTORY;
        return self.buf[(start + i) % HISTORY];
    }

    /// Самый новый профиль (или null, если истории нет).
    /// The newest profile (or null when empty).
    pub fn newest(self: *const History) ?BuildProfile {
        if (self.len == 0) return null;
        return self.at(self.len - 1);
    }
};

// ============================================================================
// PURE HELPERS (TESTABLE) — stats/layout for the panel.
// ============================================================================

/// Доля стадии от total_ms в процентах. 0, если total==0 или стадия не шла.
/// Stage's share of total_ms in percent. 0 when total==0 or stage didn't run.
pub fn stagePercent(profile: BuildProfile, stage: build_stats.Stage) f32 {
    const i = @intFromEnum(stage);
    if (!profile.stage_ran[i] or profile.total_ms <= 0) return 0;
    return profile.stage_ms[i] / profile.total_ms * 100.0;
}

/// Доли стадий для stacked-bar: каждая = ms / сумма-ms-всех-RAN-стадий,
/// нормировано к 1.0. N/A-стадии -> 0. Сумма ms == 0 -> все нули.
///
/// Stacked-bar fractions: each stage's ms / sum-of-RAN-stage-ms, normalised to
/// 1.0 across the ran stages. N/A stages -> 0. Zero total -> all zeros.
pub fn stageFractions(profile: BuildProfile, out: *[STAGE_COUNT]f32) void {
    var sum: f32 = 0;
    for (0..STAGE_COUNT) |i| {
        if (profile.stage_ran[i]) sum += profile.stage_ms[i];
    }
    if (sum <= 0) {
        for (out) |*o| o.* = 0;
        return;
    }
    for (0..STAGE_COUNT) |i| {
        out[i] = if (profile.stage_ran[i]) profile.stage_ms[i] / sum else 0;
    }
}

/// Нормализует total_ms каждого профиля истории в [0,1] по диапазону min..max.
/// Пишет в out[i] (i — логический порядок: старый->новый). Возвращает число
/// записанных. Плоская история (min==max) -> все 0.5 (без деления на ноль).
///
/// Normalises each history profile's total_ms into [0,1] over the history's
/// min..max. Writes out[i] in logical order (oldest->newest). Returns count.
/// Flat history (min==max) -> all 0.5 (no div-by-zero). out may be shorter than
/// history; only min(len, out.len) entries are written/considered.
pub fn sparklineNorm(history: *const History, out: []f32) usize {
    const n = @min(history.len, out.len);
    if (n == 0) return 0;
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    for (0..n) |i| {
        const t = history.at(i).?.total_ms; // i < n <= len, so at(i) is always present
        if (t < lo) lo = t;
        if (t > hi) hi = t;
    }
    const range = hi - lo;
    for (0..n) |i| {
        const t = history.at(i).?.total_ms; // i < n <= len, so at(i) is always present
        out[i] = if (range > 0) (t - lo) / range else 0.5;
    }
    return n;
}

/// Палитра из 7 различимых цветов (по индексу стадии). Используется и таблицей,
/// и stacked-bar для консистентности. RGBA-компоненты dvui-стиля (0..255).
///
/// Fixed 7-colour palette (indexed by stage). Shared by table + stacked bar.
pub const STAGE_PALETTE = [STAGE_COUNT][3]u8{
    .{ 230, 80, 80 }, // heightfield  — red
    .{ 230, 150, 60 }, // compact     — orange
    .{ 220, 210, 70 }, // distancefield — yellow
    .{ 90, 200, 90 }, // regions      — green
    .{ 70, 180, 220 }, // contours    — cyan
    .{ 110, 130, 230 }, // polymesh    — blue
    .{ 190, 110, 220 }, // detail      — violet
};

/// Цвет стадии как dvui.Color (палитра выше, alpha=255).
/// Stage colour as a dvui.Color (palette above, fully opaque).
pub fn stageColor(i: usize) dvui.Color {
    const c = STAGE_PALETTE[i % STAGE_COUNT];
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
}

// ---------------------------------------------------------------------------
// dvui draw primitives (NOT unit-tested — GUI; thin wrappers, minimap-style).
// Вызывать внутри dvui-кадра; координаты — физические пиксели.
// ---------------------------------------------------------------------------

/// Закрашенный прямоугольник (физические пиксели).
/// A filled rectangle in physical pixels.
pub fn fillRect(x: f32, y: f32, w: f32, h: f32, col: dvui.Color) void {
    if (w <= 0 or h <= 0) return;
    const r: dvui.Rect.Physical = .{ .x = x, .y = y, .w = w, .h = h };
    r.fill(.{}, .{ .color = col });
}

/// Один отрезок (как minimap.line).
/// One line segment (mirrors minimap.line).
pub fn line(x0: f32, y0: f32, x1: f32, y1: f32, col: dvui.Color, thickness: f32) void {
    var b = dvui.Path.Builder.init(dvui.currentWindow().lifo());
    defer b.deinit();
    b.addPoint(.{ .x = x0, .y = y0 });
    b.addPoint(.{ .x = x1, .y = y1 });
    b.build().stroke(.{ .thickness = thickness, .color = col, .closed = false });
}

/// Горизонтальный stacked-bar: сегменты по долям стадий (stageFractions) в
/// палитре стадий, слева направо. Прямоугольник (x,y,w,h) физ. пикселей.
///
/// Horizontal stacked bar: per-stage segments (stageFractions widths) in the
/// stage palette, left to right, inside rect (x,y,w,h) physical pixels.
pub fn drawStackedBar(profile: BuildProfile, x: f32, y: f32, w: f32, h: f32) void {
    var fr: [STAGE_COUNT]f32 = undefined;
    stageFractions(profile, &fr);
    var cx = x;
    for (0..STAGE_COUNT) |i| {
        const seg_w = fr[i] * w;
        if (seg_w <= 0) continue;
        fillRect(cx, y, seg_w, h, stageColor(i));
        cx += seg_w;
    }
}

/// Sparkline total_ms по истории: ломаная, новейший справа, нормировка по
/// min..max. Рисует в rect (x,y,w,h). Возвращает, было ли что рисовать.
///
/// Sparkline of total_ms across the history: a polyline, newest on the right,
/// normalised over min..max into rect (x,y,w,h). y inverted (high == up).
pub fn drawSparkline(history: *const History, x: f32, y: f32, w: f32, h: f32, col: dvui.Color) void {
    var norm: [HISTORY]f32 = undefined;
    const n = sparklineNorm(history, &norm);
    if (n == 0) return;
    if (n == 1) {
        // single sample: a dot in the vertical middle.
        fillRect(x + w * 0.5 - 1.5, y + h * (1.0 - norm[0]) - 1.5, 3, 3, col);
        return;
    }
    const denom: f32 = @floatFromInt(n - 1);
    var prev_x: f32 = x;
    var prev_y: f32 = y + h * (1.0 - norm[0]);
    for (1..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const px = x + (fi / denom) * w;
        const py = y + h * (1.0 - norm[i]);
        line(prev_x, prev_y, px, py, col, 1.5);
        prev_x = px;
        prev_y = py;
    }
}

// ============================================================================
// TESTS — pure helpers + ring semantics.
// ============================================================================
const testing = std.testing;

fn mkProfile(total: f32, gen: u64) BuildProfile {
    return .{ .total_ms = total, .gen = gen };
}

test "History push ring-wraps; len caps at HISTORY; ordering preserved" {
    var h = History{};
    try testing.expectEqual(@as(usize, 0), h.len);
    try testing.expect(h.newest() == null);
    try testing.expect(h.at(0) == null);

    // push HISTORY+3 -> oldest 3 dropped, len==HISTORY.
    const n = HISTORY + 3;
    for (0..n) |i| h.push(mkProfile(@floatFromInt(i), @intCast(i)));
    try testing.expectEqual(@as(usize, HISTORY), h.len);

    // logical at(0) is the oldest surviving element: gen == n-HISTORY == 3.
    try testing.expectEqual(@as(u64, n - HISTORY), h.at(0).?.gen);
    // newest is the last pushed.
    try testing.expectEqual(@as(u64, n - 1), h.newest().?.gen);
    // contiguous logical order.
    for (0..HISTORY) |i| {
        try testing.expectEqual(@as(u64, n - HISTORY + i), h.at(i).?.gen);
    }
    // out-of-range.
    try testing.expect(h.at(HISTORY) == null);
}

test "History clear empties it" {
    var h = History{};
    h.push(mkProfile(1, 1));
    h.push(mkProfile(2, 2));
    h.clear();
    try testing.expectEqual(@as(usize, 0), h.len);
    try testing.expect(h.newest() == null);
    try testing.expect(h.at(0) == null);
    // reuse after clear works.
    h.push(mkProfile(9, 9));
    try testing.expectEqual(@as(u64, 9), h.newest().?.gen);
}

test "stagePercent: known ms/total; N/A and zero-total -> 0" {
    var p = BuildProfile{ .total_ms = 10.0 };
    p.stage_ran[@intFromEnum(build_stats.Stage.heightfield)] = true;
    p.stage_ms[@intFromEnum(build_stats.Stage.heightfield)] = 2.5;
    try testing.expectApproxEqAbs(@as(f32, 25.0), stagePercent(p, .heightfield), 1e-4);
    // stage that didn't run -> 0.
    try testing.expectEqual(@as(f32, 0), stagePercent(p, .detail));
    // zero total -> 0 even if ran.
    var z = BuildProfile{ .total_ms = 0 };
    z.stage_ran[@intFromEnum(build_stats.Stage.heightfield)] = true;
    z.stage_ms[@intFromEnum(build_stats.Stage.heightfield)] = 1.0;
    try testing.expectEqual(@as(f32, 0), stagePercent(z, .heightfield));
}

test "stageFractions: sums to ~1 over ran stages; N/A -> 0; zero-total -> zeros" {
    var p = BuildProfile{};
    // 3 ran stages with ms 1,2,1 -> fractions .25,.5,.25.
    p.stage_ran[0] = true;
    p.stage_ms[0] = 1.0;
    p.stage_ran[1] = true;
    p.stage_ms[1] = 2.0;
    p.stage_ran[3] = true;
    p.stage_ms[3] = 1.0;
    var out: [STAGE_COUNT]f32 = undefined;
    stageFractions(p, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.50), out[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-4); // N/A
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[3], 1e-4);
    var sum: f32 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-4);

    // zero total (no ran stages) -> all zeros.
    var z = BuildProfile{};
    stageFractions(z, &out);
    for (out) |o| try testing.expectEqual(@as(f32, 0), o);
    // ran but all-zero ms -> still zeros (sum==0).
    z.stage_ran[0] = true;
    z.stage_ms[0] = 0;
    stageFractions(z, &out);
    for (out) |o| try testing.expectEqual(@as(f32, 0), o);
}

test "sparklineNorm: min->0, max->1; flat -> 0.5; empty -> 0 count" {
    var h = History{};
    var out: [HISTORY]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), sparklineNorm(&h, &out));

    // ascending totals 10,20,30,40 -> norm 0, .333, .667, 1.
    h.push(mkProfile(10, 0));
    h.push(mkProfile(20, 1));
    h.push(mkProfile(30, 2));
    h.push(mkProfile(40, 3));
    const n = sparklineNorm(&h, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[3], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), out[1], 1e-4);

    // flat history -> all 0.5 (no div-by-zero).
    var f = History{};
    f.push(mkProfile(5, 0));
    f.push(mkProfile(5, 1));
    f.push(mkProfile(5, 2));
    const fn_ = sparklineNorm(&f, &out);
    try testing.expectEqual(@as(usize, 3), fn_);
    for (0..fn_) |i| try testing.expectApproxEqAbs(@as(f32, 0.5), out[i], 1e-4);
}

test "fromBuildStats copies per-stage ms/ran + aggregates" {
    var bs = build_stats.BuildStats{ .total_ms = 7.5, .partition = .monotone };
    bs.stage(.heightfield).ran = true;
    bs.stage(.heightfield).ms = 3.0;
    bs.stage(.distancefield).ran = false; // N/A in monotone
    const p = BuildProfile.fromBuildStats(&bs, 42, 100, 9);
    try testing.expectEqual(@as(u64, 42), p.gen);
    try testing.expectEqual(@as(u32, 100), p.n_polys);
    try testing.expectEqual(@as(u32, 9), p.n_regions);
    try testing.expectEqual(build_stats.Partition.monotone, p.partition);
    try testing.expectApproxEqAbs(@as(f32, 7.5), p.total_ms, 1e-5);
    try testing.expect(p.stage_ran[@intFromEnum(build_stats.Stage.heightfield)]);
    try testing.expectApproxEqAbs(@as(f32, 3.0), p.stage_ms[@intFromEnum(build_stats.Stage.heightfield)], 1e-5);
    try testing.expect(!p.stage_ran[@intFromEnum(build_stats.Stage.distancefield)]);
}
