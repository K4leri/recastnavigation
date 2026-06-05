//! WHY-NO-PATH VERDICT — pure decision machine (A1, P0).
//! Дано: сигналы navmesh-запроса (start/end ref, связность, статус findPath).
//! Результат: человекочитаемая причина, почему путь не найден (или найден).
//!
//! Вся "тяжёлая" логика — в чистой `classify` (без NavMeshQuery), что делает
//! дерево решений юнит-тестируемым на синтетических сигналах. Живой сбор сигналов —
//! тонкая обёртка `diagnose` (diag/diagnose.zig).
//!
//! The pure classifier: given gathered signals it outputs a Verdict. Keeping it
//! free of NavMeshQuery makes the decision TREE exhaustively unit-testable.

const std = @import("std");

pub const Verdict = enum {
    ok,
    same_poly,
    invalid_start,
    invalid_end,
    different_components,
    partial_node_limit,
    /// Reserved: a partial path that is neither a flags nor a clear cost case. The
    /// current `classify` residue yields `unknown` (blocked_by_cost already covers
    /// the partial+connected case); kept for callers that construct it directly.
    partial_no_goal,
    filtered_by_flags,
    blocked_by_cost,
    unknown,
};

/// Все сигналы, нужные классификатору; заполняются живой обёрткой `diagnose`.
/// All signals the classifier needs, gathered by the live `diagnose` wrapper.
pub const Signals = struct {
    start_ref: u32,
    end_ref: u32,
    /// start & end в одной связной компоненте ПОД ПОЛЬЗОВАТЕЛЬСКИМ фильтром.
    /// start & end in the same connected component under the USER filter.
    same_component: bool,
    /// при НЕЙТРАЛЬНОМ фильтре — достижим ли end из start (топологическая связность).
    /// with a NEUTRAL filter, is end reachable from start? (real topological gap test)
    reachable_neutral: bool,
    status_success: bool,
    status_partial: bool,
    status_out_of_nodes: bool,
    status_invalid: bool,
    /// path[path_count-1] == end_ref — путь реально дошёл до цели.
    /// the produced path actually ends at end_ref.
    path_reaches_end: bool,
    node_count: usize,
    max_nodes: usize,
};

/// Чистая машина решений. Финальное согласованное дерево (см. спецификацию A1):
///   1. start_ref==0 -> invalid_start; end_ref==0 -> invalid_end.
///   2. start_ref==end_ref -> same_poly.
///   3. status_success && path_reaches_end -> ok.
///   4. status_out_of_nodes -> partial_node_limit.
///   5. !reachable_neutral -> different_components (настоящий топологический разрыв:
///      даже нейтральный фильтр не связывает).
///   6. (нейтральный достигает) !same_component -> filtered_by_flags
///      (пользовательский фильтр срезал связность по флагам).
///   7. (пользователь связан, но путь не дошёл) status_partial && !path_reaches_end
///      -> blocked_by_cost (мягко: связны, но поиск не выдал полный путь под
///      пользовательскими стоимостями).
///   8. иначе partial_no_goal / unknown.
///
/// Pure decision machine — the reconciled tree. The TRUE "different components"
/// verdict means even a NEUTRAL filter can't connect them (a real gap). If neutral
/// CAN connect but the user filter can't, that's filtered_by_flags (or blocked_by_cost
/// if connectivity is the same but cost cut the branch).
pub fn classify(s: Signals) Verdict {
    // 1. Invalid endpoints first (a ref of 0 means findNearestPoly snapped nothing).
    if (s.start_ref == 0) return .invalid_start;
    if (s.end_ref == 0) return .invalid_end;

    // 2. Trivial: start and end are the same polygon.
    if (s.start_ref == s.end_ref) return .same_poly;

    // 3. Full success — the path was found and reaches the goal.
    if (s.status_success and s.path_reaches_end) return .ok;

    // Defensive: findPath reported an explicit invalid-param status. After the
    // invalid_start/end guards above this is rare, but treat it as an end issue.
    if (s.status_invalid) return .invalid_end;

    // 4. The node pool was exhausted (findPath surfaced OutOfNodes — e.g. the start
    //    node itself couldn't be allocated, or the pool filled mid-search). Bump
    //    max_nodes in initQuery to recover.
    if (s.status_out_of_nodes) return .partial_node_limit;

    // 5. Real topological gap: even a neutral filter cannot connect them.
    if (!s.reachable_neutral) return .different_components;

    // 6. Neutral reaches, but the USER filter cut connectivity -> flags.
    if (!s.same_component) return .filtered_by_flags;

    // 7. User-connected yet the path is partial / never reached -> soft cost issue.
    if (s.status_partial and !s.path_reaches_end) return .blocked_by_cost;

    // 8. Nothing else fired.
    return .unknown;
}

/// Однострочная человекочитаемая причина (для панели). Exhaustive switch —
/// добавление вердикта без текста не скомпилируется.
/// One-line human-readable reason for a verdict (panel status line).
pub fn reasonText(v: Verdict) []const u8 {
    return switch (v) {
        .ok => "OK - a path exists from start to end.",
        .same_poly => "Start and end are on the same polygon (trivially connected).",
        .invalid_start => "No navmesh polygon under the START point - move it onto walkable navmesh.",
        .invalid_end => "No navmesh polygon under the END point - move it onto walkable navmesh.",
        .different_components => "No path: start and end are on SEPARATE pieces of navmesh that aren't connected by anything (a real gap - even an all-flags filter can't cross it).",
        .partial_node_limit => "No full path: the search ran out of node-pool space before reaching the end. Raise max_nodes.",
        .partial_no_goal => "Partial path only: the search stopped short of the goal.",
        .filtered_by_flags => "No path: the polygons that WOULD connect start->end are blocked by your include/exclude FLAGS (they'd connect with an all-flags filter). Allow the needed flag.",
        .blocked_by_cost => "Reachable by flags, but the area COSTS steered the search away from a complete corridor (it's expensive, not impossible).",
        .unknown => "Path failed for an undetermined reason.",
    };
}

/// Развёрнутое объяснение ("Explain"): дописывает детали (счётчики узлов и т.п.)
/// в `buf`, возвращает срез. Не аллоцирует.
/// Longer "Explain" detail; references node counts / which signal fired. Writes
/// into the caller's buffer.
pub fn explainText(buf: []u8, v: Verdict, s: Signals) []const u8 {
    const reason = reasonText(v);
    const detail: []const u8 = switch (v) {
        .ok => "The A* search closed a complete corridor from start to end.",
        .same_poly => "findNearestPoly snapped both points onto one polygon; no search needed.",
        .invalid_start => "Increase the search half-extents or move the start onto the mesh.",
        .invalid_end => "Increase the search half-extents or move the end onto the mesh.",
        .different_components => "A neutral (all-flags) filter also fails to connect them, so this is a real gap in the mesh topology, not a filter issue.",
        .partial_node_limit => "Raise the query node limit (initQuery max_nodes) or shorten the query.",
        .partial_no_goal => "The open list emptied before the goal node was closed.",
        .filtered_by_flags => "A neutral filter connects them, but the user include/exclude flags exclude a boundary polygon on the only route.",
        .blocked_by_cost => "Connectivity is intact under the user filter, but per-area costs made the search settle on a partial corridor.",
        .unknown => "Signals did not match any known failure pattern.",
    };
    return std.fmt.bufPrint(
        buf,
        "{s}\n{s}\n\nnodes {d} / {d}   neutral-reach: {}   user-component: {}   partial: {}   reaches-end: {}",
        .{
            reason,
            detail,
            s.node_count,
            s.max_nodes,
            s.reachable_neutral,
            s.same_component,
            s.status_partial,
            s.path_reaches_end,
        },
    ) catch reason;
}

// ─────────────────────────── tests ───────────────────────────
// Каждый вердикт имеет фикстуру Signals, его дающую; проверяем порядок/границы.

/// Базовый "успешный" набор сигналов; тесты мутируют отдельные поля.
fn baseOk() Signals {
    return .{
        .start_ref = 10,
        .end_ref = 20,
        .same_component = true,
        .reachable_neutral = true,
        .status_success = true,
        .status_partial = false,
        .status_out_of_nodes = false,
        .status_invalid = false,
        .path_reaches_end = true,
        .node_count = 5,
        .max_nodes = 2048,
    };
}

test "classify: ok" {
    try std.testing.expectEqual(Verdict.ok, classify(baseOk()));
}

test "classify: invalid_start beats everything" {
    var s = baseOk();
    s.start_ref = 0;
    // even with end_ref also 0, start wins (checked first)
    s.end_ref = 0;
    try std.testing.expectEqual(Verdict.invalid_start, classify(s));
}

test "classify: invalid_end" {
    var s = baseOk();
    s.end_ref = 0;
    try std.testing.expectEqual(Verdict.invalid_end, classify(s));
}

test "classify: same_poly beats success/components" {
    var s = baseOk();
    s.start_ref = 42;
    s.end_ref = 42;
    try std.testing.expectEqual(Verdict.same_poly, classify(s));
}

test "classify: out_of_nodes -> partial_node_limit" {
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.status_out_of_nodes = true;
    try std.testing.expectEqual(Verdict.partial_node_limit, classify(s));
}

test "classify: neutral-unreachable -> different_components" {
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.reachable_neutral = false;
    s.same_component = false;
    try std.testing.expectEqual(Verdict.different_components, classify(s));
}

test "classify: neutral-reachable + user-disconnected -> filtered_by_flags" {
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.reachable_neutral = true;
    s.same_component = false;
    try std.testing.expectEqual(Verdict.filtered_by_flags, classify(s));
}

test "classify: user-connected + partial -> blocked_by_cost" {
    // Live-producible: diagnose sets same_component from a passFilter link-BFS
    // (cost-agnostic), so a flag-passable but cost-cut route yields exactly this
    // combo — neutral-reachable, user-flag-connected, yet the path came back partial.
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.reachable_neutral = true;
    s.same_component = true; // passFilter-BFS reached end (flags OK); cost cut the path
    s.status_partial = true;
    try std.testing.expectEqual(Verdict.blocked_by_cost, classify(s));
}

test "classify: user-connected + non-partial residue -> unknown" {
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.reachable_neutral = true;
    s.same_component = true;
    s.status_partial = false;
    try std.testing.expectEqual(Verdict.unknown, classify(s));
}

test "classify: explicit invalid status -> invalid_end" {
    var s = baseOk();
    s.status_success = false;
    s.path_reaches_end = false;
    s.status_invalid = true;
    try std.testing.expectEqual(Verdict.invalid_end, classify(s));
}

test "classify: partial_no_goal reachable via direct construction" {
    // partial_no_goal is reserved for the residual partial branch; ensure
    // reasonText covers it (it can be produced by diagnose mapping, not classify's
    // current residue which yields unknown). Covered by exhaustive reasonText below.
    try std.testing.expect(reasonText(.partial_no_goal).len > 0);
}

test "reasonText: non-empty for every verdict" {
    inline for (std.meta.fields(Verdict)) |f| {
        const v: Verdict = @enumFromInt(f.value);
        try std.testing.expect(reasonText(v).len > 0);
    }
}

test "explainText: non-empty + contains node counts for every verdict" {
    var buf: [512]u8 = undefined;
    inline for (std.meta.fields(Verdict)) |f| {
        const v: Verdict = @enumFromInt(f.value);
        const txt = explainText(&buf, v, baseOk());
        try std.testing.expect(txt.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, txt, "nodes") != null);
    }
}
