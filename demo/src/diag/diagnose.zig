//! Live signal gathering for the WHY-NO-PATH verdict (A1, PART 2).
//! Запускает живые запросы, заполняет `Signals`, затем вызывает чистую `classify`.
//! Не мутирует постоянное состояние сверх прогона запросов в scratch-буферы.
//!
//! Thin wrapper: the load-bearing decision logic lives in why_no_path.classify
//! (exhaustively unit-tested). Here we only translate live query results into the
//! pure Signals struct.

const std = @import("std");
const recast = @import("recast-nav");
const components = @import("../render/components.zig");
const wnp = @import("why_no_path.zig");

const dt = recast.detour;
pub const Verdict = wnp.Verdict;
pub const Signals = wnp.Signals;

/// Результат диагностики: вердикт + сигналы, на которых он построен.
pub const Result = struct { verdict: Verdict, signals: Signals };

/// Запускает живые запросы и классифицирует.
///
/// Маппинг живых сигналов (важно — разделение нейтральной и пользовательской связности):
///   - reachable_neutral: componentForRef(start) == componentForRef(end) в `comps`.
///     `comps` строится flood-fill по ЛИНКАМ без учёта фильтра => НЕЙТРАЛЬНАЯ
///     (топологическая) связность. Разные id => реальный разрыв в топологии.
///   - same_component (под пользовательским фильтром): запускаем findPath с
///     user_filter; считаем связными, если путь реально дошёл до end_ref
///     (path_reaches_end). Тогда дерево различает flags/cost:
///       neutral-reach & !user-path => filtered_by_flags (флаги срезали связность);
///       neutral-reach & user-path-частичный => blocked_by_cost.
///   - status_*: findPath возвращает Zig error-union (!void), а НЕ Status — поэтому
///     статус выводим из самой ошибки/результата (см. ниже).
///
/// Mapping (neutral vs user connectivity -> flags/cost split):
///   reachable_neutral comes from the filter-agnostic component flood-fill;
///   same_component (user) is derived from whether the user-filter findPath reached
///   the goal. classify then splits flags vs cost on these two booleans.
pub fn diagnose(
    query: *dt.NavMeshQuery,
    nav: *const dt.NavMesh,
    comps: *const components.Components,
    start_ref: dt.PolyRef,
    end_ref: dt.PolyRef,
    spos: [3]f32,
    epos: [3]f32,
    user_filter: *const dt.QueryFilter,
    path_scratch: []dt.PolyRef,
) Result {
    var s = Signals{
        .start_ref = @intCast(start_ref),
        .end_ref = @intCast(end_ref),
        .same_component = false,
        .reachable_neutral = false,
        .status_success = false,
        .status_partial = false,
        .status_out_of_nodes = false,
        .status_invalid = false,
        .path_reaches_end = false,
        .node_count = 0,
        .max_nodes = 0,
    };

    // Neutral (topological) reachability: same flood-fill component in `comps`.
    if (start_ref != 0 and end_ref != 0) {
        const cs = comps.componentForRef(nav, start_ref);
        const ce = comps.componentForRef(nav, end_ref);
        if (cs != null and ce != null and cs.? != 0 and cs.? == ce.?) {
            s.reachable_neutral = true;
        }
    }

    // Run the USER-filter findPath into scratch; derive status + path_reaches_end.
    if (start_ref != 0 and end_ref != 0) {
        var n: usize = 0;
        var sp = spos;
        var ep = epos;
        if (query.findPath(start_ref, end_ref, &sp, &ep, user_filter, path_scratch, &n)) {
            // Success (no error). Path complete iff last poly == end_ref.
            s.status_success = true;
            if (n > 0 and path_scratch[n - 1] == end_ref) {
                s.path_reaches_end = true;
            } else {
                // findPath succeeded but the corridor is partial (goal not reached).
                s.status_partial = true;
            }
        } else |err| switch (err) {
            error.OutOfNodes => s.status_out_of_nodes = true,
            error.InvalidParam => s.status_invalid = true,
            else => {}, // NoNavMesh/NoNodePool/etc — leave as plain failure.
        }
        // user-connectivity == the user-filter path actually reached the goal.
        s.same_component = s.path_reaches_end;
    }

    // Node-pool occupancy snapshot (after the findPath above).
    if (query.getNodePool()) |np| {
        s.node_count = np.getNodeCount();
        s.max_nodes = np.getMaxNodes();
    }

    return .{ .verdict = wnp.classify(s), .signals = s };
}
