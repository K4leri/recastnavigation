# Render: component colour scheme (foundation step 3c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a "Component" navmesh colouring that paints each connected-component (connectivity island) a distinct colour — visible structure on any mesh with zero setup, and synergistic with the Prune tool.

**Architecture:** `render/components.zig` computes a per-polygon component id by flood-filling over poly links (generalising `tool_prune.floodNavmesh`). `poly_visit.fillNavMesh` gains an allocator and, when the active scheme is `.component`, computes the components once per draw and feeds each poly's id into `colorForPoly(.component, ...)` (which is `intToCol(component)`). A "Component" radio joins the Properties selector. `.component` is computed from the navmesh alone — no baked data needed.

**Tech Stack:** Zig 0.16 (full path; unset http_proxy/https_proxy before `zig build`; kill `recast_demo.exe` first). GUI code — verified by `zig build demo` + visual check.

---

## File Structure

- **Create** `demo/src/render/components.zig` — `Components` (per-tile/per-poly id table) + `compute(mesh, alloc)`.
- **Modify** `demo/src/render/poly_visit.zig` — add an `alloc` param; compute components when scheme is `.component`; fill `ctx.component`.
- **Modify** `demo/src/sample_solo.zig` — pass `self.alloc` to the `fillNavMesh` call sites.
- **Modify** `demo/src/main.zig` — add a "Component" radio (id 313).

---

## Task 1: components.zig

**Files:**
- Create: `demo/src/render/components.zig`

- [ ] **Step 1: Write the module**

Create `demo/src/render/components.zig`. The flood-fill mirrors
`demo/src/tool_prune.zig` `floodNavmesh` / `NavmeshFlags` (link traversal
`p.first_link -> tile.links[i].next`, neighbour `tile.links[i].ref`,
`decodePolyId`, `getPolyRefBase`, `getTileAndPolyByRefUnsafe`):

```zig
//! Connected components of the navmesh: each polygon gets a 1-based component id
//! via flood-fill over poly links (generalises tool_prune.floodNavmesh). Feeds
//! the `component` colour scheme to paint connectivity islands. Computed on
//! demand from the navmesh alone — no baked data. NOTE: O(polys+links) per call;
//! callers recompute per draw while the scheme is active (cache later if needed).

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;

pub const Components = struct {
    alloc: std.mem.Allocator,
    tile_comp: []?[]u16 = &.{}, // per tile: id per poly (0 = unassigned), or null for empty tile
    count: u16 = 0,

    pub fn deinit(self: *Components) void {
        for (self.tile_comp) |maybe| {
            if (maybe) |s| self.alloc.free(s);
        }
        if (self.tile_comp.len > 0) self.alloc.free(self.tile_comp);
        self.tile_comp = &.{};
    }

    /// Component id for a poly slot (1-based; 0 = none/empty). No bounds check.
    pub fn getByIndex(self: *const Components, tile_idx: usize, poly_idx: usize) u16 {
        return if (self.tile_comp[tile_idx]) |s| s[poly_idx] else 0;
    }
};

/// Flood-fill the whole navmesh into connected components.
pub fn compute(nav: *const dt.NavMesh, alloc: std.mem.Allocator) !Components {
    var comps = Components{ .alloc = alloc };
    const num_tiles: usize = @intCast(nav.max_tiles);
    if (num_tiles == 0) return comps;

    comps.tile_comp = try alloc.alloc(?[]u16, num_tiles);
    for (comps.tile_comp) |*slot| slot.* = null;
    errdefer comps.deinit();

    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const pc: usize = @intCast(header.poly_count);
        const s = try alloc.alloc(u16, pc);
        @memset(s, 0);
        comps.tile_comp[i] = s;
    }

    var open = std.array_list.Managed(dt.PolyRef).init(alloc);
    defer open.deinit();

    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const base = nav.getPolyRefBase(tile);
        const pc: usize = @intCast(header.poly_count);
        for (0..pc) |j| {
            const ref = base | @as(dt.PolyRef, @intCast(j));
            const d0 = nav.decodePolyId(ref);
            if (comps.tile_comp[d0.tile].?[d0.poly] != 0) continue;

            comps.count += 1;
            const cid = comps.count;
            comps.tile_comp[d0.tile].?[d0.poly] = cid;

            open.clearRetainingCapacity();
            try open.append(ref);
            while (open.items.len > 0) {
                const r = open.pop().?;
                var t2: ?*const dt.MeshTile = null;
                var p2: ?*const dt.Poly = null;
                nav.getTileAndPolyByRefUnsafe(r, &t2, &p2);
                const tt = t2.?;
                const pp = p2.?;
                var li: u32 = pp.first_link;
                while (li != dt.NULL_LINK) : (li = tt.links[li].next) {
                    const nref = tt.links[li].ref;
                    if (nref == 0) continue;
                    const dn = nav.decodePolyId(nref);
                    if (comps.tile_comp[dn.tile].?[dn.poly] != 0) continue;
                    comps.tile_comp[dn.tile].?[dn.poly] = cid;
                    try open.append(nref);
                }
            }
        }
    }
    return comps;
}
```

- [ ] **Step 2: Build (module compiles; unused until Task 2)**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0. If any name differs (`getTileAndPolyByRefUnsafe`, `decodePolyId` return field names `.tile`/`.poly`, `getPolyRefBase`, `dt.NULL_LINK`, `p.first_link`, `t.links[i].next/.ref`), confirm against `demo/src/tool_prune.zig` (which uses all of them) and adapt; report changes.

- [ ] **Step 3: Commit**

```bash
git add demo/src/render/components.zig
git commit -m "demo(render): connected-components flood-fill for the component colour scheme"
```

---

## Task 2: Wire the component scheme into poly_visit + Solo render + UI

**Files:**
- Modify: `demo/src/render/poly_visit.zig`
- Modify: `demo/src/sample_solo.zig`
- Modify: `demo/src/main.zig`

- [ ] **Step 1: poly_visit — add alloc param + component computation**

In `demo/src/render/poly_visit.zig`:

Add the import near the others:
```zig
const components = @import("components.zig");
```

Change the `fillNavMesh` signature to take an allocator:
```zig
pub fn fillNavMesh(dd: dbg.DebugDraw, mesh: *const NavMesh, scheme: cs.ColorScheme, alloc: std.mem.Allocator) void {
```

At the top of `fillNavMesh` (next to the existing `hr` line), compute components
only for the component scheme:
```zig
    var comps: ?components.Components = if (scheme == .component) (components.compute(mesh, alloc) catch null) else null;
    defer if (comps) |*c| c.deinit();
```

In the inner poly loop, set `ctx.component` from the table (the outer tile loop
index is `ti`, the poly index is `i`):
```zig
                .component = if (comps) |*c| @as(i32, c.getByIndex(ti, i)) else 0,
```
Add that field to the `cs.PolyColorCtx{ ... }` literal already being built (it
currently sets `area_col`, `flags`, `height`, `height_min`, `height_max`).

- [ ] **Step 2: sample_solo — pass the allocator**

In `demo/src/sample_solo.zig`, every `poly_visit.fillNavMesh(dd, n, scheme_state.active)`
call (added in the previous increment, in the `.navmesh`/`.navmesh_trans`/
`.navmesh_bvtree`/`.navmesh_nodes` branches) becomes:
```zig
poly_visit.fillNavMesh(dd, n, scheme_state.active, self.alloc);
```
(Confirm the sample's allocator field is named `self.alloc` — grep the struct; the
build path uses `const a = self.alloc`. If it is named differently, use that.)

- [ ] **Step 3: main.zig — add the Component radio**

In the "Navmesh Colouring" section added previously, add a fourth radio after
Height (id 313 — confirm it is free via `rg -n "313" demo/src/main.zig`):
```zig
                if (ui.radio(@src(), scheme_state.active == .component, "Component", 313)) scheme_state.active = .component;
```

- [ ] **Step 4: Build**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0. Do NOT launch the GUI.

- [ ] **Step 5: Commit**

```bash
git add demo/src/render/poly_visit.zig demo/src/sample_solo.zig demo/src/main.zig
git commit -m "demo(render): Component colouring (connectivity islands) in the selector"
```

---

## Self-Review

- **Spec coverage:** adds the `.component` scheme end-to-end (compute → ctx → colour → UI). Region and cost schemes, legend, isolation, highlight remain OUT (later) — `.region` is deferred because region id is not baked into navmesh polys.
- **Reuse:** the flood-fill mirrors `tool_prune.floodNavmesh` (same link traversal); `colorForPoly(.component, ...)` already exists from step 3a.
- **Default unchanged:** `.area` path untouched; component work runs only when `.component` is selected.
- **Known cost:** components recompute per draw while active (commented in the module); acceptable for demo sizes, cache later.
- **Type consistency:** `Components`/`compute`/`getByIndex` names match across Task 1 and Task 2; `fillNavMesh`'s new `alloc` param matches the four call sites; `ctx.component` is `i32` (cast from `u16`).
