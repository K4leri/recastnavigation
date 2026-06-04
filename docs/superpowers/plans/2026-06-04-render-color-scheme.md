# Render infra: colour schemes (foundation step 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure, reusable `ColorScheme` → RGBA mapping (`colorForPoly`) so any debug visualiser (clusters E/A/B/G) can recolour the navmesh by area / region / flags / height / connected-component / movement-cost without duplicating the colour logic.

**Architecture:** A new `demo/src/render/color_scheme.zig` is a pure function module: `ColorScheme` enum + `PolyColorCtx` (the per-polygon inputs) + `colorForPoly(scheme, ctx) u32`. It reuses the faithful core colour helpers (`recast.debug.rgba/intToCol/lerpCol`). It does NOT traverse or draw anything — applying a scheme during a navmesh traversal, plus the UI toggle, is a later increment (step 3b). It is registered in the demo test aggregator and verified via `zig build demo-test`.

**Tech Stack:** Zig 0.16 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`). Because the module imports `recast-nav` (for the core colour helpers), it is tested through the project's `zig build demo-test` step (the `demo/src/tests.zig` aggregator), NOT standalone `zig test`. Always unset http_proxy/https_proxy before any `zig build`.

---

## File Structure

- **Create** `demo/src/render/color_scheme.zig` — `ColorScheme`, `PolyColorCtx`, `colorForPoly`, plus its tests. New `render/` subfolder for the foundation render layer (§3.c).
- **Modify** `demo/src/tests.zig` — add the new module to the demo test aggregator so its tests run under `zig build demo-test`.

The module is pure and not yet wired into the live render path (the traversal that calls it is step 3b). It is the reusable mapping that the spec's §3.c builds on.

---

## Task 1: color_scheme.zig

**Files:**
- Create: `demo/src/render/color_scheme.zig`
- Modify: `demo/src/tests.zig`

- [ ] **Step 1: Write the module with its tests**

Create `demo/src/render/color_scheme.zig`:

```zig
//! Colour schemes for navmesh visualisation (foundation render layer, §3.c).
//! Pure mapping from one polygon's properties to an RGBA colour, so every debug
//! visualiser (cluster E and others) recolours the navmesh by area / region /
//! flags / height / connected-component / movement-cost through ONE place,
//! instead of hardcoding palettes. This module only computes a colour; applying
//! it during a navmesh traversal is a separate module (step 3b).

const std = @import("std");
const recast = @import("recast-nav");
const dbg = recast.debug; // rgba / intToCol / lerpCol — faithful core helpers

pub const ColorScheme = enum { area, region, flags, height, component, cost };

/// Per-polygon inputs a scheme may use. The caller fills the fields relevant to
/// the active scheme; the rest may stay at their defaults.
pub const PolyColorCtx = struct {
    /// Precomputed area colour (from the area-type registry) — used by `.area`.
    area_col: u32 = 0,
    region: i32 = 0,
    component: i32 = 0,
    flags: u16 = 0,
    height: f32 = 0,
    height_min: f32 = 0,
    height_max: f32 = 0,
    cost: f32 = 0,
    cost_max: f32 = 0,
};

const ALPHA: i32 = 192;

// Gradient endpoints (dbg.rgba is an inline fn, so these fold at comptime).
const HEIGHT_LO: u32 = dbg.rgba(40, 90, 200, 192); // low  = blue
const HEIGHT_HI: u32 = dbg.rgba(220, 70, 40, 192); // high = red
const COST_LO: u32 = dbg.rgba(60, 180, 70, 192); // cheap = green
const COST_HI: u32 = dbg.rgba(200, 50, 40, 192); // dear  = red

/// Clamp (v - lo) / (hi - lo) to [0,1]; returns 0 when the range is empty.
fn norm(v: f32, lo: f32, hi: f32) f32 {
    if (hi <= lo) return 0;
    return std.math.clamp((v - lo) / (hi - lo), 0.0, 1.0);
}

fn gradient(a: u32, b: u32, t: f32) u32 {
    const u: u32 = @intFromFloat(std.math.clamp(t, 0.0, 1.0) * 255.0);
    return dbg.lerpCol(a, b, u);
}

/// RGBA colour for one polygon under the given scheme.
pub fn colorForPoly(scheme: ColorScheme, ctx: PolyColorCtx) u32 {
    return switch (scheme) {
        .area => ctx.area_col,
        .region => dbg.intToCol(ctx.region, ALPHA),
        .component => dbg.intToCol(ctx.component, ALPHA),
        .flags => dbg.intToCol(@as(i32, ctx.flags), ALPHA),
        .height => gradient(HEIGHT_LO, HEIGHT_HI, norm(ctx.height, ctx.height_min, ctx.height_max)),
        .cost => gradient(COST_LO, COST_HI, norm(ctx.cost, 0, ctx.cost_max)),
    };
}

test "area scheme returns the precomputed area colour verbatim" {
    const col: u32 = 0x8011_2233;
    try std.testing.expectEqual(col, colorForPoly(.area, .{ .area_col = col }));
}

test "region/component/flags are deterministic and match intToCol" {
    try std.testing.expectEqual(dbg.intToCol(5, ALPHA), colorForPoly(.region, .{ .region = 5 }));
    try std.testing.expectEqual(dbg.intToCol(7, ALPHA), colorForPoly(.component, .{ .component = 7 }));
    try std.testing.expectEqual(dbg.intToCol(@as(i32, 0x0A), ALPHA), colorForPoly(.flags, .{ .flags = 0x0A }));
    // determinism: same input -> same colour
    try std.testing.expectEqual(colorForPoly(.region, .{ .region = 5 }), colorForPoly(.region, .{ .region = 5 }));
}

test "height gradient hits endpoints; empty range -> low" {
    const lo = colorForPoly(.height, .{ .height = 0, .height_min = 0, .height_max = 10 });
    const hi = colorForPoly(.height, .{ .height = 10, .height_min = 0, .height_max = 10 });
    try std.testing.expectEqual(HEIGHT_LO, lo);
    try std.testing.expectEqual(HEIGHT_HI, hi);
    // degenerate range: norm() returns 0 -> low endpoint, no divide-by-zero
    const empty = colorForPoly(.height, .{ .height = 5, .height_min = 3, .height_max = 3 });
    try std.testing.expectEqual(HEIGHT_LO, empty);
}

test "cost gradient hits endpoints" {
    try std.testing.expectEqual(COST_LO, colorForPoly(.cost, .{ .cost = 0, .cost_max = 4 }));
    try std.testing.expectEqual(COST_HI, colorForPoly(.cost, .{ .cost = 4, .cost_max = 4 }));
}
```

- [ ] **Step 2: Register the module in the demo test aggregator**

In `demo/src/tests.zig`, add one line inside the `test { ... }` block (after the
existing `_ = @import("input_geom.zig");`):

```zig
    _ = @import("render/color_scheme.zig");
```

- [ ] **Step 3: Run the demo tests, expect PASS**

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo-test
```
Expected: build succeeds and all demo tests pass (including the four
`color_scheme` tests). If the build prints test failures, read them and fix the
module (do not weaken the assertions to pass).

> If `recast.debug` does not expose `rgba`/`intToCol`/`lerpCol` under that exact
> name, grep `demo/src/tool_navmesh_tester.zig` (it uses `const dbg = recast.debug;`
> then `dbg.rgba(...)`) and `src/debug/debug_draw.zig` for the real names, and use
> those. Report any name you had to change.

- [ ] **Step 4: Commit**

```bash
git add demo/src/render/color_scheme.zig demo/src/tests.zig
git commit -m "demo(render): add colour-scheme mapping (area/region/flags/height/component/cost)"
```

---

## Self-Review

- **Spec coverage (foundation §3.c — colour schemes):** `ColorScheme` enum with all six schemes ✓; `colorForPoly` pure mapping ✓. Legend / isolation / highlight / the traversal that applies the scheme are explicitly OUT (step 3b and later) — noted in Architecture.
- **Placeholder scan:** none — exact code, paths, commands.
- **Type consistency:** `ColorScheme`, `PolyColorCtx`, `colorForPoly`, `norm`, `gradient`, and the four gradient constants are each defined once and referenced consistently; `dbg.intToCol(i: i32, a: i32)` and `dbg.lerpCol(ca, cb, u: u32)` are called with the argument types the core defines (`ALPHA: i32`; `u` built via `@intFromFloat`).
- **Reuse:** colours come from the faithful core helpers (`recast.debug`), not re-implemented — no DRY violation.
- **Testability:** module imports `recast-nav`, so it is registered in `demo/src/tests.zig` and run via `zig build demo-test` (not standalone `zig test`), matching the project's demo-test convention.
