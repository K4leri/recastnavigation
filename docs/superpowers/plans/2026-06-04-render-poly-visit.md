# Render infra: scheme-coloured navmesh fill (foundation step 3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the user recolour the navmesh fill by colour scheme (area / flags / height) from a Properties selector, using the `color_scheme` mapping from step 3a.

**Architecture:** The faithful core `debugDrawNavMesh` colours fills only by `area` (its only colour input is the `area_to_col` hook). So a demo-side fill pass `render/poly_visit.zig` replicates the detail-triangle fill loop of `drawMeshTile` (src/debug/detour_debug.zig:166-203) but colours each polygon via `color_scheme.colorForPoly`. A tiny `render/scheme_state.zig` holds the active scheme (default `.area`). When the active scheme is `.area` the render path is unchanged (zero regression); for `.flags`/`.height` the demo draws an opaque scheme-coloured fill over the (covered) area fill, leaving the core boundaries on top. Only baked navmesh data is used — region/component/cost schemes are deferred (they need extra plumbing).

**Tech Stack:** Zig 0.16 (full path `C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`; unset http_proxy/https_proxy before `zig build`; kill `recast_demo.exe` before building). `poly_visit.zig` is GUI code (draws via DebugDraw), so it is verified by `zig build demo` + visual check, not a unit test.

---

## File Structure

- **Create** `demo/src/render/scheme_state.zig` — `pub var active: ColorScheme = .area;` (the live selection).
- **Create** `demo/src/render/poly_visit.zig` — `fillNavMesh(dd, mesh, scheme)`: demo fill pass colouring each poly by the scheme.
- **Modify** `demo/src/sample_solo.zig` — in `render`, after the core navmesh draw, draw the scheme fill when `active != .area`.
- **Modify** `demo/src/main.zig` — a "Navmesh Colouring" radio group in the Properties panel that sets `scheme_state.active`.

---

## Task 1: scheme_state.zig + poly_visit.zig

**Files:**
- Create: `demo/src/render/scheme_state.zig`
- Create: `demo/src/render/poly_visit.zig`

- [ ] **Step 1: scheme_state.zig**

Create `demo/src/render/scheme_state.zig`:

```zig
//! Live navmesh-colouring selection (foundation render layer, §3.c). Global so
//! the Properties UI (main.zig) and the sample render path (sample_*.zig) share
//! one source of truth without threading it through every call. Default `.area`
//! reproduces the original look exactly.

const ColorScheme = @import("color_scheme.zig").ColorScheme;

pub var active: ColorScheme = .area;
```

- [ ] **Step 2: poly_visit.zig**

Create `demo/src/render/poly_visit.zig`. The fill loop is copied 1:1 from
`drawMeshTile` (src/debug/detour_debug.zig:166-203) — same poly/detail-tri
indexing — but the per-poly colour comes from `colorForPoly`. Height range is
computed in a pre-pass so the module is self-contained.

```zig
//! Demo-side navmesh fill pass that colours each polygon by the active colour
//! scheme (foundation render layer, §3.c). The faithful core `debugDrawNavMesh`
//! can only colour by area (its sole input is the area_to_col hook), so this
//! replicates the detail-triangle fill of `drawMeshTile` and applies
//! `color_scheme.colorForPoly` per polygon. Boundaries/off-mesh stay with the
//! core draw.

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;
const dbg = recast.debug;
const sample = @import("../sample.zig");
const cs = @import("color_scheme.zig");

const NavMesh = dt.NavMesh;
const PolyRef = dt.PolyRef;

/// Average Y of a polygon's base vertices — its representative height.
fn polyHeight(tile: *const dt.MeshTile, p: *const dt.Poly) f32 {
    var sum: f32 = 0;
    for (0..p.vert_count) |k| {
        sum += tile.verts[@as(usize, p.verts[k]) * 3 + 1];
    }
    return if (p.vert_count == 0) 0 else sum / @as(f32, @floatFromInt(p.vert_count));
}

/// Min/max representative height across all walkable polys (for the height ramp).
fn heightRange(mesh: *const NavMesh) struct { lo: f32, hi: f32 } {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var found = false;
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        const hdr = tile.header orelse continue;
        for (0..@intCast(hdr.poly_count)) |pi| {
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;
            const h = polyHeight(tile, p);
            lo = @min(lo, h);
            hi = @max(hi, h);
            found = true;
        }
    }
    return if (found) .{ .lo = lo, .hi = hi } else .{ .lo = 0, .hi = 0 };
}

/// Draw an opaque scheme-coloured fill over the navmesh. Call only when the
/// active scheme is NOT `.area` (for `.area` the core draw already suffices).
pub fn fillNavMesh(dd: dbg.DebugDraw, mesh: *const NavMesh, scheme: cs.ColorScheme) void {
    const hr = heightRange(mesh);

    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;
            const pd = &tile.detail_meshes[i];

            const ctx = cs.PolyColorCtx{
                .area_col = sample.sampleAreaToCol(p.getArea()),
                .flags = p.flags,
                .height = polyHeight(tile, p),
                .height_min = hr.lo,
                .height_max = hr.hi,
            };
            const col = cs.colorForPoly(scheme, ctx);

            for (0..@intCast(pd.tri_count)) |j| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];
                for (0..3) |k| {
                    if (t[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[t[k]]) * 3;
                        dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                    } else {
                        const d_idx = (pd.vert_base + (t[k] - p.vert_count)) * 3;
                        dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                    }
                }
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}
```

- [ ] **Step 3: Build (these modules compile but aren't called yet)**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0. If a field/method name differs (e.g. `p.flags`, `p.vert_count`,
`p.verts`, `tile.detail_meshes`, `pd.tri_base/tri_base`, `mesh.max_tiles`,
`tile.header`), confirm the real names against `src/debug/detour_debug.zig`
(`drawMeshTile`, lines 158-203) and `src/detour/navmesh.zig` (Poly/MeshTile),
adapt, and report what you changed. Do NOT guess — read the structs.

> Note: `poly_visit.fillNavMesh` is `pub` and unused until Task 2 — that is fine
> in Zig at file scope (no unused-function error for pub decls).

- [ ] **Step 4: Commit**

```bash
git add demo/src/render/scheme_state.zig demo/src/render/poly_visit.zig
git commit -m "demo(render): poly-visit fill pass that colours navmesh by scheme"
```

---

## Task 2: Wire the scheme fill into the Solo render + a Properties selector

**Files:**
- Modify: `demo/src/sample_solo.zig` (`render`, around lines 364-446)
- Modify: `demo/src/main.zig` (Properties panel; imports)

- [ ] **Step 1: Import the render modules in sample_solo.zig**

At the top of `demo/src/sample_solo.zig`, next to the existing imports, add:

```zig
const poly_visit = @import("render/poly_visit.zig");
const scheme_state = @import("render/scheme_state.zig");
```

- [ ] **Step 2: Draw the scheme fill after the core navmesh draw**

In `SampleSolo.render`, the navmesh is drawn by `dbg.debugDrawNavMesh(dd, n, 0)`
on the `.navmesh`, `.navmesh_trans`, and `.navmesh_nodes` draw-mode branches
(around lines 440-446). For each of those three branches, immediately AFTER the
`dbg.debugDrawNavMesh(dd, n, 0)` call (still inside the `if (self.navmesh) |*n|`),
add an opaque scheme fill when the active scheme is not `.area`:

```zig
if (scheme_state.active != .area) poly_visit.fillNavMesh(dd, n, scheme_state.active);
```

Concretely, change e.g.:
```zig
            .navmesh, .navmesh_trans => if (self.navmesh) |*n| dbg.debugDrawNavMesh(dd, n, 0),
```
to:
```zig
            .navmesh, .navmesh_trans => if (self.navmesh) |*n| {
                dbg.debugDrawNavMesh(dd, n, 0);
                if (scheme_state.active != .area) poly_visit.fillNavMesh(dd, n, scheme_state.active);
            },
```
Do the same for the `.navmesh_nodes` branch (line ~446). For the `.navmesh_bvtree`
branch (~443) that already uses a block, add the same two-line guard after its
`dbg.debugDrawNavMesh(dd, n, 0);`. (If a branch's exact form differs, read it and
apply the same "after the core draw, add the guarded fill" rule; report anything
ambiguous.)

- [ ] **Step 3: Add the Properties selector in main.zig**

Add the import next to the other render/demo imports in `demo/src/main.zig`:
```zig
const scheme_state = @import("render/scheme_state.zig");
```

In the Properties panel, add a "Navmesh Colouring" section with three radios.
Place it near the other Properties sections (e.g. just before the "Poly Flags"
Show checkbox, or after the Draw-mode controls). Use the existing `ui.section` /
`ui.radio` helpers (same as the Tools radios). Insert:

```zig
                ui.section(@src(), "Navmesh Colouring");
                if (ui.radio(@src(), scheme_state.active == .area, "Area", 310)) scheme_state.active = .area;
                if (ui.radio(@src(), scheme_state.active == .flags, "Flags", 311)) scheme_state.active = .flags;
                if (ui.radio(@src(), scheme_state.active == .height, "Height", 312)) scheme_state.active = .height;
```

(Choose id_extra values 310-312 that are not already used by other radios in
main.zig — grep `ui.radio(` to confirm 310-312 are free; if taken, pick the next
free trio and report it.)

- [ ] **Step 4: Build**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add demo/src/sample_solo.zig demo/src/main.zig
git commit -m "demo(render): Properties navmesh-colouring selector (area/flags/height)"
```

---

## Self-Review

- **Spec coverage (foundation §3.c):** colour-scheme mapping is applied to the live navmesh via a demo fill pass ✓; user selector ✓. Region/component/cost schemes, legend, isolation, highlight, and Tile/Temp samples are OUT of this increment (Solo only) — noted in Architecture.
- **Zero-regression default:** with `active == .area` neither `poly_visit` nor any new draw runs; the render path is byte-identical to before. Visual verification target: switching to Flags/Height recolours the fill; switching back to Area restores the original look.
- **Faithful core untouched:** `poly_visit` lives in `demo/src`; it copies the traversal shape but the core `src/debug/detour_debug.zig` is not modified.
- **Placeholder scan:** none — exact code/paths/commands; struct field names flagged for verification against the core in Task 1 Step 3.
- **Type consistency:** `ColorScheme`/`PolyColorCtx`/`colorForPoly` from `color_scheme.zig`; `scheme_state.active` written by main.zig and read by sample_solo.zig; `fillNavMesh(dd, mesh, scheme)` signature matches both the definition and the call site.
