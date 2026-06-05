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
///   same_component (user) comes from a USER-FILTER-aware link BFS (reachableUnderFilter):
///   it ignores COST and only honours passFilter, so it answers "can the user filter's
///   flags even connect start->end?". classify then splits:
///     neutral-reach & !user-reach  => filtered_by_flags (flags severed connectivity);
///     user-reach   & partial path  => blocked_by_cost (connected, but cost cut the
///                                     corridor / drained the search — soft).
///   Deriving same_component from passFilter-connectivity (NOT from path_reaches_end)
///   is what keeps blocked_by_cost reachable: an open-list drain on a flag-passable but
///   expensive route is cost, not flags.
pub fn diagnose(
    alloc: std.mem.Allocator,
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
        // user-connectivity = can the user filter's FLAGS connect start->end at all
        // (passFilter link-BFS, cost ignored). If the path reached the goal it's
        // trivially connected; otherwise consult the BFS so a cost-cut-but-flag-
        // passable route reads as connected (=> blocked_by_cost, not filtered_by_flags).
        s.same_component = if (s.path_reaches_end)
            true
        else
            reachableUnderFilter(alloc, nav, start_ref, end_ref, user_filter) catch s.path_reaches_end;
    }

    // Node-pool occupancy snapshot (after the findPath above).
    if (query.getNodePool()) |np| {
        s.node_count = np.getNodeCount();
        s.max_nodes = np.getMaxNodes();
    }

    return .{ .verdict = wnp.classify(s), .signals = s };
}

/// User-filter-aware reachability: BFS over poly links from `start_ref`, traversing
/// ONLY into polygons the filter accepts (`passFilter`), and report whether `end_ref`
/// is reached. COST is intentionally ignored — this answers "can the filter's FLAGS
/// connect these polys at all?", which separates filtered_by_flags (no) from
/// blocked_by_cost (yes, but the cost-aware search still didn't deliver a corridor).
/// Mirrors components.compute's link walk (first_link / links[li].next / .ref) but
/// gated by passFilter. Bounded by the visited set; returns OutOfMemory on alloc fail.
fn reachableUnderFilter(
    alloc: std.mem.Allocator,
    nav: *const dt.NavMesh,
    start_ref: dt.PolyRef,
    end_ref: dt.PolyRef,
    filter: *const dt.QueryFilter,
) !bool {
    if (start_ref == 0 or end_ref == 0) return false;
    if (start_ref == end_ref) return true;

    // The start poly itself must pass the filter, else nothing is reachable.
    {
        var t0: ?*const dt.MeshTile = null;
        var p0: ?*const dt.Poly = null;
        nav.getTileAndPolyByRefUnsafe(start_ref, &t0, &p0);
        if (t0 == null or p0 == null) return false;
        if (!filter.passFilter(start_ref, t0.?, p0.?)) return false;
    }

    var visited = std.AutoHashMap(dt.PolyRef, void).init(alloc);
    defer visited.deinit();
    var open = std.array_list.Managed(dt.PolyRef).init(alloc);
    defer open.deinit();

    try visited.put(start_ref, {});
    try open.append(start_ref);

    while (open.items.len > 0) {
        const r = open.pop().?;
        var t2: ?*const dt.MeshTile = null;
        var p2: ?*const dt.Poly = null;
        nav.getTileAndPolyByRefUnsafe(r, &t2, &p2);
        const tt = t2 orelse continue;
        const pp = p2 orelse continue;
        var li: u32 = pp.first_link;
        while (li != dt.NULL_LINK) : (li = tt.links[li].next) {
            const nref = tt.links[li].ref;
            if (nref == 0) continue;
            if (visited.contains(nref)) continue;
            // Honour the filter: only cross into a neighbour the filter accepts.
            var nt: ?*const dt.MeshTile = null;
            var np: ?*const dt.Poly = null;
            nav.getTileAndPolyByRefUnsafe(nref, &nt, &np);
            const ntt = nt orelse continue;
            const npp = np orelse continue;
            if (!filter.passFilter(nref, ntt, npp)) continue;
            if (nref == end_ref) return true;
            try visited.put(nref, {});
            try open.append(nref);
        }
    }
    return false;
}
