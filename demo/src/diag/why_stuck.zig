//! WHY-STUCK VERDICT — pure decision machine (J / P0-1).
//! Дано: сигналы СОСТОЯНИЯ crowd-агента (state/target_state/partial/ncorners/
//! скорости), снятые из УЖЕ хранимых полей CrowdAgent (ядро НЕ меняем).
//! Результат: человекочитаемая причина, почему агент не движется (или движется).
//!
//! Вся "тяжёлая" логика — в чистой `classify` (без crowd-ядра), что делает
//! дерево решений юнит-тестируемым на синтетических сигналах. Живой сбор сигналов —
//! тонкая обёртка над CrowdAgent (подключается отдельно).
//!
//! The pure classifier: given gathered agent-state signals it outputs a Verdict.
//! Keeping it free of the crowd core makes the decision TREE exhaustively
//! unit-testable on synthetic signals.

const std = @import("std");

/// Порог "агент реально движется": если |vel| строго больше этого eps, считаем,
/// что агент едет (не застрял). Метры/сек в системе координат симуляции. Малый —
/// чтобы дрожание VO/числовой шум не считались движением, но реальный шаг — считался.
/// "Agent is actually moving" speed threshold (|vel| > this -> moving).
pub const MOVING_EPS: f32 = 0.05;

/// Порог "скорость практически ноль": |vel| <= этого считаем стоянием (для arrived
/// и blocked_by_neighbors). Чуть выше MOVING_EPS НЕ нужен — берём тот же масштаб,
/// зона (STOPPED_EPS, MOVING_EPS] трактуется как "почти стоит, но и не едет" и
/// разруливается порядком дерева (см. classify).
/// "Speed is essentially zero" threshold (|vel| <= this -> standing still).
pub const STOPPED_EPS: f32 = 0.05;

/// Порог "желаемая скорость практически ноль": desired_speed <= этого означает, что
/// контроллер сам НЕ хочет ехать (правомерная остановка у цели).
/// "Desired speed is essentially zero" threshold (controller intends to stop).
pub const DESIRED_EPS: f32 = 0.01;

pub const Verdict = enum {
    moving, //              агент реально движется (|vel| заметна) — не застрял.
    arrived, //             у цели, желаемая скорость ~0 правомерно.
    off_navmesh, //         state == .invalid (агент не на навмеше).
    no_target, //           target_state == none (цель не задана).
    target_pending, //      requesting/waiting_for_queue/waiting_for_path — путь ещё считается.
    no_path, //             target_failed (путь не найден).
    partial_path, //        partial == true (коридор неполный, упирается).
    blocked_by_neighbors, // desired_speed>0, но |vel|~0 при наличии коридора (ncorners>0) — затёрт соседями/VO.
    unknown,
};

/// Все сигналы, нужные классификатору; заполняются живой обёрткой из CrowdAgent.
/// All signals the classifier needs, gathered from CrowdAgent fields.
pub const Signals = struct {
    /// agent.state == .invalid (агент вне навмеша).
    state_invalid: bool,
    /// target_state == target_none (цель не задана).
    target_none: bool,
    /// target_state == target_failed (путь не найден).
    target_failed: bool,
    /// target_state ∈ {requesting, waiting_for_queue, waiting_for_path} (ещё считается).
    target_pending: bool,
    /// partial == true (частичный путь — коридор не дотягивается до цели).
    partial: bool,
    /// число углов сглаженного коридора (>0 — есть куда ехать).
    ncorners: u32,
    /// desired_speed контроллера (сколько агент ХОЧЕТ ехать).
    desired_speed: f32,
    /// |vel| — фактическая величина скорости.
    speed: f32,
    /// агент в пределах радиуса цели (для правомерного arrived).
    near_target: bool,
};

/// Чистая машина решений. Дерево приоритетов (сверху вниз):
///   1. state_invalid -> off_navmesh. Самое фундаментальное: агент вне навмеша,
///      любые цели/коридоры бессмысленны, пока он не на меше.
///   2. speed > MOVING_EPS -> moving. Если агент РЕАЛЬНО едет, он по определению не
///      застрял — это бьёт любые "проблемные" target_state (частичный путь и т.п.
///      не мешают, раз движение есть). Намеренно выше target_*-веток.
///   3. near_target && desired_speed <= DESIRED_EPS -> arrived. Стоит правомерно:
///      он у цели и сам не хочет ехать (контроллер обнулил desired). Проверяем до
///      target_*-веток, т.к. это "хороший" штиль, а не проблема.
///   4. target_none -> no_target. Цель не задана — ехать некуда (не ошибка пути).
///   5. target_failed -> no_path. Планировщик не нашёл путь к цели.
///   6. target_pending -> target_pending. Путь ещё считается асинхронно — подожди.
///   7. partial -> partial_path. Коридор неполный: агент дойдёт до обрыва и встанет.
///   8. desired_speed > DESIRED_EPS && speed <= STOPPED_EPS && ncorners > 0 ->
///      blocked_by_neighbors. Хочет ехать, путь/коридор есть, но фактически стоит —
///      его затирают соседи / VO / локальное препятствие.
///   9. иначе -> unknown.
///
/// Pure decision machine — priority TREE, top to bottom. `off_navmesh` is the most
/// fundamental; `moving` deliberately outranks the target_* branches (a moving agent
/// is not stuck regardless of a partial/failed target).
pub fn classify(s: Signals) Verdict {
    // 1. Off the navmesh — nothing else matters until the agent is on the mesh.
    if (s.state_invalid) return .off_navmesh;

    // 2. Actually moving — by definition not stuck. Beats any problem target_state.
    if (s.speed > MOVING_EPS) return .moving;

    // 3. Legitimately parked at the goal: at target AND controller wants ~0 speed.
    if (s.near_target and s.desired_speed <= DESIRED_EPS) return .arrived;

    // 4. No target set — nowhere to go (not a pathing failure).
    if (s.target_none) return .no_target;

    // 5. Planner reported failure — no path to the target.
    if (s.target_failed) return .no_path;

    // 6. Path still being computed asynchronously — wait.
    if (s.target_pending) return .target_pending;

    // 7. Partial corridor — agent will reach the truncation and stop short.
    if (s.partial) return .partial_path;

    // 8. Wants to move, has a corridor, but is standing still -> neighbors/VO crush it.
    if (s.desired_speed > DESIRED_EPS and s.speed <= STOPPED_EPS and s.ncorners > 0)
        return .blocked_by_neighbors;

    // 9. Nothing else fired.
    return .unknown;
}

/// Однострочная человекочитаемая причина (для панели). Exhaustive switch —
/// добавление вердикта без текста не скомпилируется.
/// One-line human-readable reason for a verdict (panel status line).
pub fn reasonText(v: Verdict) []const u8 {
    return switch (v) {
        .moving => "Agent is actually moving (|vel| above threshold) - it is NOT stuck.",
        .arrived => "Agent is parked at its target and the controller wants ~0 speed (arrived).",
        .off_navmesh => "Agent is OFF the navmesh (state invalid) - it cannot move until it's on walkable mesh.",
        .no_target => "No target set - the agent has nowhere to go.",
        .target_pending => "The target's path is still being computed (requesting / waiting for queue or path) - wait a tick.",
        .no_path => "Path request FAILED - no route to the target was found.",
        .partial_path => "Only a PARTIAL path exists - the corridor stops short of the goal and the agent halts at the truncation.",
        .blocked_by_neighbors => "Agent WANTS to move and has a corridor, but is standing still - it's being crushed by neighbors / obstacle-avoidance (VO).",
        .unknown => "Agent is not moving for an undetermined reason.",
    };
}

/// Развёрнутое объяснение ("Explain"): дописывает детали (счётчики/скорости)
/// в `buf`, возвращает срез. Не аллоцирует.
/// Longer "Explain" detail; references speeds / corner counts. Writes into the
/// caller's buffer.
pub fn explainText(buf: []u8, v: Verdict, s: Signals) []const u8 {
    const reason = reasonText(v);
    const detail: []const u8 = switch (v) {
        .moving => "Velocity exceeds MOVING_EPS, so the agent is making progress this tick.",
        .arrived => "near_target is set and desired_speed is ~0, so standing still is correct.",
        .off_navmesh => "findNearestPoly / the boundary check left the agent without a valid poly ref; re-place it onto the mesh.",
        .no_target => "Call requestMoveTarget (or set a velocity target) to give the agent a destination.",
        .target_pending => "The async path queue hasn't resolved yet; the corridor will appear once the request completes.",
        .no_path => "The planner returned target_failed - the destination is unreachable under the current filter, or off-mesh.",
        .partial_path => "partial is set: the corridor reaches only part of the way, so the agent drives to the cut and stops.",
        .blocked_by_neighbors => "desired_speed>0 with ncorners>0 yet |vel|~0 - local steering (separation / VO) zeroed the velocity.",
        .unknown => "Signals did not match any known stuck pattern.",
    };
    return std.fmt.bufPrint(
        buf,
        "{s}\n{s}\n\nspeed {d:.3} / desired {d:.3}   corners {d}   near-target: {}   partial: {}",
        .{
            reason,
            detail,
            s.speed,
            s.desired_speed,
            s.ncorners,
            s.near_target,
            s.partial,
        },
    ) catch reason;
}

// ─────────────────────────── tests ───────────────────────────
// Каждый вердикт имеет фикстуру Signals, его дающую; проверяем порядок/границы.

/// Базовый "движется" набор сигналов; тесты мутируют отдельные поля.
fn baseMoving() Signals {
    return .{
        .state_invalid = false,
        .target_none = false,
        .target_failed = false,
        .target_pending = false,
        .partial = false,
        .ncorners = 3,
        .desired_speed = 1.5,
        .speed = 1.2, // > MOVING_EPS
        .near_target = false,
    };
}

test "classify: moving" {
    try std.testing.expectEqual(Verdict.moving, classify(baseMoving()));
}

test "classify: off_navmesh beats everything" {
    var s = baseMoving();
    s.state_invalid = true;
    // even while "moving" and with a failed target, off-navmesh wins (checked first)
    s.speed = 5.0;
    s.target_failed = true;
    try std.testing.expectEqual(Verdict.off_navmesh, classify(s));
}

test "classify: moving beats a failed target" {
    var s = baseMoving();
    s.target_failed = true; // a problem target_state...
    s.speed = 0.9; // ...but the agent is actually moving -> not stuck
    try std.testing.expectEqual(Verdict.moving, classify(s));
}

test "classify: arrived" {
    var s = baseMoving();
    s.speed = 0.0;
    s.desired_speed = 0.0; // <= DESIRED_EPS
    s.near_target = true;
    try std.testing.expectEqual(Verdict.arrived, classify(s));
}

test "classify: arrived beats no_path when parked at goal" {
    var s = baseMoving();
    s.speed = 0.0;
    s.desired_speed = 0.0;
    s.near_target = true;
    s.target_failed = true; // arrived is the "good" calm, checked before target_*
    try std.testing.expectEqual(Verdict.arrived, classify(s));
}

test "classify: no_target" {
    var s = baseMoving();
    s.speed = 0.0;
    s.target_none = true;
    try std.testing.expectEqual(Verdict.no_target, classify(s));
}

test "classify: no_path (target_failed)" {
    var s = baseMoving();
    s.speed = 0.0;
    s.target_failed = true;
    try std.testing.expectEqual(Verdict.no_path, classify(s));
}

test "classify: target_pending" {
    var s = baseMoving();
    s.speed = 0.0;
    s.target_pending = true;
    try std.testing.expectEqual(Verdict.target_pending, classify(s));
}

test "classify: partial_path" {
    var s = baseMoving();
    s.speed = 0.0;
    s.partial = true;
    try std.testing.expectEqual(Verdict.partial_path, classify(s));
}

test "classify: blocked_by_neighbors" {
    var s = baseMoving();
    s.speed = 0.0; // <= STOPPED_EPS
    s.desired_speed = 1.5; // > DESIRED_EPS, wants to move
    s.ncorners = 4; // has a corridor
    try std.testing.expectEqual(Verdict.blocked_by_neighbors, classify(s));
}

test "classify: unknown residue (wants to move but no corridor)" {
    var s = baseMoving();
    s.speed = 0.0;
    s.desired_speed = 1.5;
    s.ncorners = 0; // no corridor -> blocked_by_neighbors guard fails -> unknown
    try std.testing.expectEqual(Verdict.unknown, classify(s));
}

test "classify: boundary - speed exactly at MOVING_EPS is NOT moving" {
    var s = baseMoving();
    s.speed = MOVING_EPS; // strictly-greater test, so equal -> not moving
    s.desired_speed = 1.5;
    s.ncorners = 2;
    // falls through to blocked_by_neighbors (wants move, has corridor, ~0 speed)
    try std.testing.expectEqual(Verdict.blocked_by_neighbors, classify(s));
}

test "classify: boundary - speed just above MOVING_EPS IS moving" {
    var s = baseMoving();
    s.speed = MOVING_EPS + 0.001;
    try std.testing.expectEqual(Verdict.moving, classify(s));
}

test "classify: arrived needs desired ~0 - nonzero desired at target is not arrived" {
    var s = baseMoving();
    s.speed = 0.0;
    s.near_target = true;
    s.desired_speed = 0.5; // > DESIRED_EPS -> not "arrived"
    s.ncorners = 2;
    // wants to move at target but standing -> blocked_by_neighbors
    try std.testing.expectEqual(Verdict.blocked_by_neighbors, classify(s));
}

test "reasonText: non-empty for every verdict" {
    inline for (std.meta.fields(Verdict)) |f| {
        const v: Verdict = @enumFromInt(f.value);
        try std.testing.expect(reasonText(v).len > 0);
    }
}

test "explainText: non-empty + contains speed counters for every verdict" {
    var buf: [512]u8 = undefined;
    inline for (std.meta.fields(Verdict)) |f| {
        const v: Verdict = @enumFromInt(f.value);
        const txt = explainText(&buf, v, baseMoving());
        try std.testing.expect(txt.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, txt, "speed") != null);
        try std.testing.expect(std.mem.indexOf(u8, txt, "corners") != null);
    }
}
