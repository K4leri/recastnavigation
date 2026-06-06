//! Общий навмеш-render-слой для всех трёх сэмплов (solo/tile/temp).
//! Перенесён ДОСЛОВНО (1-в-1) из drawNavmeshLayer/scene-overlays каждого сэмпла —
//! correctness-sensitive render-код, golden hash его НЕ покрывает.
//!
//! drawNavmeshLayer: 4-веточный роутинг (wireframe -> outline; filter active ->
//! filtered fill; иначе faithful debugDrawNavMesh + опциональный scheme overdraw).
//! Сам gate `view_state.groups.navmesh` ВКЛЮЧЁН в функцию (как было у каждого
//! сэмпла). Artifact-highlight (solo-специфичный) остаётся в solo как пост-вызов.
//!
//! drawSceneOverlays: mesh-bounds wireframe + convex/off-mesh (1:1 Sample::handleRender).

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;
const dbg = recast.debug;
const InputGeom = @import("../input_geom.zig").InputGeom;
const poly_visit = @import("poly_visit.zig");
const scheme_state = @import("scheme_state.zig");
const filter_state = @import("filter_state.zig");
const view_state = @import("view_state.zig");

/// Единый навмеш-слой: gate на группе `navmesh`; wireframe -> outline (работает с
/// фильтром on/off), иначе фильтрованная отрисовка (clip/iso active) иначе faithful
/// + опциональный scheme overdraw. 1-в-1 с прежними копиями в сэмплах.
pub fn drawNavmeshLayer(dd: dbg.DebugDraw, n: *dt.NavMesh, alloc: std.mem.Allocator) void {
    if (!view_state.groups.navmesh) return;
    if (view_state.wireframe) {
        poly_visit.outlineNavMesh(dd, n, scheme_state.active, filter_state.active, alloc);
    } else if (filter_state.active.active()) {
        poly_visit.fillNavMeshFiltered(dd, n, scheme_state.active, filter_state.active, alloc);
    } else {
        dbg.debugDrawNavMesh(dd, n, 0);
        if (scheme_state.active != .area) poly_visit.fillNavMesh(dd, n, scheme_state.active, alloc);
    }
}

/// Сценовые оверлеи, рисуемые независимо от активного инструмента (1:1
/// Sample::handleRender): mesh-bounds wireframe (белый 255,255,255,128) +
/// convex-объёмы и off-mesh-связи под их group-гейтами.
pub fn drawSceneOverlays(dd: dbg.DebugDraw, geom: ?*InputGeom) void {
    if (geom) |g| {
        // Mesh bounds wireframe (1:1 Sample::handleRender — duDebugDrawBoxWire,
        // white 255,255,255,128). Marks the 3D object's extent.
        dbg.debugDrawBoxWire(dd, g.bmin[0], g.bmin[1], g.bmin[2], g.bmax[0], g.bmax[1], g.bmax[2], dbg.rgba(255, 255, 255, 128), 1.0);
        // Cluster E (P1-1): convex / off-mesh gated on their groups.
        if (view_state.groups.convex) g.drawConvexVolumes(dd);
        if (view_state.groups.offmesh) g.drawOffMeshConnections(dd);
    }
}
