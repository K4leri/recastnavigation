# Surface-band convex volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Convex volumes can mark navmesh that hugs the local surface (per-column nearest span to a fitted plane ± band) instead of a flat min..max prism, with a per-volume Prism/Surface mode (default Surface).

**Architecture:** A new demo module `demo/src/convex_surface.zig` provides a plane-fit + point-in-poly + a surface marker that writes `chf.areas` over the `CompactHeightfield` (faithful core `rcMarkConvexPolyArea` is NOT modified). `ConvexVolume` gains `mode`/`band_below`/`band_above`; the three samples branch on `mode` during build; the convex tool gets a mode toggle + band sliders; `volumes.bin` is extended (version bump). Spec: `docs/superpowers/specs/2026-06-05-surface-band-convex-volume-design.md`.

**Tech Stack:** Zig 0.16 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`; unset http_proxy/https_proxy before `zig build`; kill recast_demo.exe first). Pure math units test via `zig test demo/src/convex_surface.zig`; persistence via `zig build demo-test`; integration via `zig build demo`.

---

## File Structure

- **Create** `demo/src/convex_surface.zig` — `Plane`, `fitPlane`, `pointInPoly`, `markConvexPolyAreaSurface`. Pure + chf-marking. Self-tests.
- **Modify** `demo/src/input_geom.zig` — `VolumeMode` enum + `mode`/`band_below`/`band_above` fields on `ConvexVolume`.
- **Modify** `demo/src/sample_solo.zig`, `sample_tile.zig`, `sample_temp_obstacles.zig` — branch the volume-marking loop on `vol.mode`.
- **Modify** `demo/src/tool_convex.zig` — mode toggle + band sliders; stamp mode/band on created volumes.
- **Modify** `demo/src/persist/scene_io.zig` — volumes.bin record gains mode/band + version bump (legacy → prism).

---

## Task 1: plane fit + point-in-poly (pure)

**Files:** Create `demo/src/convex_surface.zig`

- [ ] **Step 1: Write the module with tests**

Create `demo/src/convex_surface.zig`:

```zig
//! Surface-conforming convex-volume marking (demo-level; foundation of the
//! "surface" volume mode). Fits a least-squares plane through the contour
//! vertices and, per (x,z) column inside the contour, marks the walkable spans
//! that hug the LOCAL surface (nearest span to the plane, ± band). This keeps the
//! marked area attached to the relief and off neighbouring floors. The faithful
//! core `rcMarkConvexPolyArea` is NOT touched.

const std = @import("std");
const recast = @import("recast-nav");

pub const Plane = struct {
    a: f32 = 0,
    b: f32 = 0,
    c: f32 = 0,
    pub fn at(self: Plane, x: f32, z: f32) f32 {
        return self.a * x + self.b * z + self.c;
    }
};

/// Least-squares plane y = a*x + b*z + c through the contour vertices
/// (verts laid out x,y,z,...). Degenerate (collinear in XZ) -> horizontal at mean Y.
pub fn fitPlane(verts: []const f32, nverts: usize) Plane {
    var sx: f64 = 0;
    var sz: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxz: f64 = 0;
    var szz: f64 = 0;
    var sxy: f64 = 0;
    var szy: f64 = 0;
    const n: f64 = @floatFromInt(nverts);
    for (0..nverts) |i| {
        const x: f64 = verts[i * 3 + 0];
        const y: f64 = verts[i * 3 + 1];
        const z: f64 = verts[i * 3 + 2];
        sx += x;
        sz += z;
        sy += y;
        sxx += x * x;
        sxz += x * z;
        szz += z * z;
        sxy += x * y;
        szy += z * y;
    }
    // Normal equations M*[a,b,c] = R, M = [[sxx,sxz,sx],[sxz,szz,sz],[sx,sz,n]],
    // R = [sxy,szy,sy]. Solved by Cramer's rule.
    const det = sxx * (szz * n - sz * sz) - sxz * (sxz * n - sz * sx) + sx * (sxz * sz - szz * sx);
    if (@abs(det) < 1e-6) {
        return .{ .a = 0, .b = 0, .c = @floatCast(sy / n) };
    }
    const da = sxy * (szz * n - sz * sz) - sxz * (szy * n - sz * sy) + sx * (szy * sz - szz * sy);
    const db = sxx * (szy * n - sz * sy) - sxy * (sxz * n - sz * sx) + sx * (sxz * sy - szy * sx);
    const dc = sxx * (szz * sy - szy * sz) - sxz * (sxz * sy - szy * sx) + sxy * (sxz * sz - szz * sx);
    return .{ .a = @floatCast(da / det), .b = @floatCast(db / det), .c = @floatCast(dc / det) };
}

/// Ray-cast point-in-polygon in the XZ plane (mirror of recast rcPointInPoly).
pub fn pointInPoly(nverts: usize, verts: []const f32, px: f32, pz: f32) bool {
    var c = false;
    var i: usize = 0;
    var j: usize = nverts - 1;
    while (i < nverts) : (i += 1) {
        const vix = verts[i * 3 + 0];
        const viz = verts[i * 3 + 2];
        const vjx = verts[j * 3 + 0];
        const vjz = verts[j * 3 + 2];
        if (((viz > pz) != (vjz > pz)) and
            (px < (vjx - vix) * (pz - viz) / (vjz - viz) + vix))
        {
            c = !c;
        }
        j = i;
    }
    return c;
}

test "fitPlane recovers a known sloped plane" {
    // y = 0.5*x + 0.25*z + 2  at 4 corners
    const v = [_]f32{
        0, 2.0,   0,
        4, 4.0,   0, // 0.5*4 + 2 = 4
        4, 5.0,   4, // 0.5*4 + 0.25*4 + 2 = 5
        0, 3.0,   4, // 0.25*4 + 2 = 3
    };
    const p = fitPlane(&v, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.a, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), p.b, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), p.c, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), p.at(4, 4), 1e-3);
}

test "fitPlane degenerate (collinear in XZ) -> horizontal at mean" {
    // all points on the line x=z, varied Y -> XZ-collinear -> fallback mean
    const v = [_]f32{ 0, 1, 0, 1, 3, 1, 2, 5, 2 };
    const p = fitPlane(&v, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.a, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.b, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), p.c, 1e-3); // mean(1,3,5)
}

test "pointInPoly square" {
    const sq = [_]f32{ 0, 0, 0, 4, 0, 0, 4, 0, 4, 0, 0, 4 };
    try std.testing.expect(pointInPoly(4, &sq, 2, 2));
    try std.testing.expect(!pointInPoly(4, &sq, 5, 2));
    try std.testing.expect(!pointInPoly(4, &sq, -1, 2));
}
```

- [ ] **Step 2: Run, expect PASS**

Run: `& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/convex_surface.zig`
Expected: `All 3 tests passed.`

> The module imports `recast-nav` but the math tests don't use it; standalone `zig test` should still compile since only `std` is exercised. If `@import("recast-nav")` makes standalone `zig test` fail ("import outside module"), move the `recast` import usage into Task 2 (the marker) and register the module in `demo/src/tests.zig` for `zig build demo-test`; report which path you used.

- [ ] **Step 3: Commit**

```bash
git add demo/src/convex_surface.zig
git commit -m "demo(convex): plane fit + point-in-poly for surface marking"
```

---

## Task 2: surface marker over CompactHeightfield

**Files:** Modify `demo/src/convex_surface.zig`

Reference for accessors (read them): `src/recast/heightfield.zig` — `CompactHeightfield{ width:i32, height:i32, bmin:Vec3, cs:f32, ch:f32, cells:[]CompactCell, spans:[]CompactSpan, areas:[]u8 }`; `CompactCell{ index:u24, count:u8 }`; `CompactSpan{ y:u16, ... }`. `recast.CompactHeightfield` is the exported type. **Confirm Vec3 component access** (`chf.bmin.x/.y/.z` vs `.data[0..2]`) against `recast.math.Vec3` and use the real one.

- [ ] **Step 1: Add the marker**

Append to `demo/src/convex_surface.zig`:

```zig
const CompactHeightfield = recast.CompactHeightfield;

/// Mark `area` on the compact heightfield within the XZ contour, hugging the
/// local surface: per column, anchor on the walkable span nearest the fitted
/// plane, then mark spans within [anchor - band_below, anchor + band_above].
/// Columns whose nearest span is farther than (band_below+band_above+ch) from
/// the plane are skipped (gap / other floor). Writes only `chf.areas`.
pub fn markConvexPolyAreaSurface(
    verts: []const f32,
    nverts: usize,
    band_below: f32,
    band_above: f32,
    area: u8,
    chf: *CompactHeightfield,
) void {
    if (nverts < 3) return;
    const plane = fitPlane(verts, nverts);
    const bminx = chf.bmin.x;
    const bminy = chf.bmin.y;
    const bminz = chf.bmin.z;
    const snap_max = band_below + band_above + chf.ch;

    var minx_f = verts[0];
    var maxx_f = verts[0];
    var minz_f = verts[2];
    var maxz_f = verts[2];
    for (1..nverts) |i| {
        minx_f = @min(minx_f, verts[i * 3 + 0]);
        maxx_f = @max(maxx_f, verts[i * 3 + 0]);
        minz_f = @min(minz_f, verts[i * 3 + 2]);
        maxz_f = @max(maxz_f, verts[i * 3 + 2]);
    }
    const inv_cs = 1.0 / chf.cs;
    var minx: i32 = @intFromFloat((minx_f - bminx) * inv_cs);
    var maxx: i32 = @intFromFloat((maxx_f - bminx) * inv_cs);
    var minz: i32 = @intFromFloat((minz_f - bminz) * inv_cs);
    var maxz: i32 = @intFromFloat((maxz_f - bminz) * inv_cs);
    minx = @max(minx, 0);
    maxx = @min(maxx, chf.width - 1);
    minz = @max(minz, 0);
    maxz = @min(maxz, chf.height - 1);
    if (maxx < minx or maxz < minz) return;

    var z: i32 = minz;
    while (z <= maxz) : (z += 1) {
        var x: i32 = minx;
        while (x <= maxx) : (x += 1) {
            const wx = bminx + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs;
            const wz = bminz + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs;
            if (!pointInPoly(nverts, verts, wx, wz)) continue;
            const expected = plane.at(wx, wz);

            const cell = chf.cells[@intCast(x + z * chf.width)];
            const start: usize = cell.index;
            const end: usize = start + cell.count;

            var best: ?usize = null;
            var best_d: f32 = std.math.floatMax(f32);
            var i: usize = start;
            while (i < end) : (i += 1) {
                const sy = bminy + @as(f32, @floatFromInt(chf.spans[i].y)) * chf.ch;
                const d = @abs(sy - expected);
                if (d < best_d) {
                    best_d = d;
                    best = i;
                }
            }
            if (best) |bi| {
                if (best_d > snap_max) continue;
                const anchor = bminy + @as(f32, @floatFromInt(chf.spans[bi].y)) * chf.ch;
                const lo = anchor - band_below;
                const hi = anchor + band_above;
                var k: usize = start;
                while (k < end) : (k += 1) {
                    const sy = bminy + @as(f32, @floatFromInt(chf.spans[k].y)) * chf.ch;
                    if (sy >= lo and sy <= hi) chf.areas[k] = area;
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add a marker test on a synthetic heightfield**

Add to `demo/src/convex_surface.zig`. Build a tiny 2×2 chf with a known surface plus an "upper floor" span and assert only the lower (surface) spans inside the contour are marked. Confirm the `CompactHeightfield`/`CompactCell` field names against `src/recast/heightfield.zig` and adapt the literal if a field differs (e.g. `CompactCell.init(index,count)` may be required instead of a bare struct literal):

```zig
test "markSurface marks the surface floor, not the upper floor" {
    const alloc = std.testing.allocator;
    // 2x2 grid, cs=1, ch=1, origin 0. Each column: a surface span at y=0 and an
    // upper-floor span at y=10. Plane fit ~ y=0 -> only the y=0 spans get marked.
    var cells = try alloc.alloc(recast.CompactCell, 4);
    defer alloc.free(cells);
    var spans = try alloc.alloc(recast.CompactSpan, 8);
    defer alloc.free(spans);
    var areas = try alloc.alloc(u8, 8);
    defer alloc.free(areas);
    @memset(areas, 0);
    for (0..4) |ci| {
        cells[ci] = .{ .index = @intCast(ci * 2), .count = 2 };
        spans[ci * 2 + 0] = .{ .y = 0, .reg = 0, .con = 0 }; // surface
        spans[ci * 2 + 1] = .{ .y = 10, .reg = 0, .con = 0 }; // upper floor
    }
    var chf: recast.CompactHeightfield = undefined;
    chf.width = 2;
    chf.height = 2;
    chf.bmin = .{ .x = 0, .y = 0, .z = 0 };
    chf.cs = 1;
    chf.ch = 1;
    chf.cells = cells;
    chf.spans = spans;
    chf.areas = areas;

    // contour covering the whole 2x2 at surface height (y=0), area = 7
    const v = [_]f32{ 0, 0, 0, 2, 0, 0, 2, 0, 2, 0, 0, 2 };
    markConvexPolyAreaSurface(&v, 4, 0.5, 0.5, 7, &chf);

    for (0..4) |ci| {
        try std.testing.expectEqual(@as(u8, 7), areas[ci * 2 + 0]); // surface marked
        try std.testing.expectEqual(@as(u8, 0), areas[ci * 2 + 1]); // upper floor NOT marked
    }
}
```

> If `recast.CompactCell`/`CompactSpan` cannot be brace-initialised (e.g. fields are not all listed / there is an init fn), use the real constructor and report it. If constructing a bare `CompactHeightfield` via `undefined` + field assignment fails because of an unlisted required field used by the marker, set only the fields the marker reads (width/height/bmin/cs/ch/cells/spans/areas).

- [ ] **Step 3: Build the demo-test (this module now imports recast-nav)**

Register in `demo/src/tests.zig`: add `_ = @import("convex_surface.zig");` inside the `test {}` block. Then:
```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo-test
```
Expected: all pass (incl. the marker test). If `zig test demo/src/convex_surface.zig` standalone still works (no module error), you may use that instead and skip the tests.zig registration — report which.

- [ ] **Step 4: Commit**

```bash
git add demo/src/convex_surface.zig demo/src/tests.zig
git commit -m "demo(convex): surface marker (per-column nearest span to plane +/- band)"
```

---

## Task 3: ConvexVolume mode + band fields

**Files:** Modify `demo/src/input_geom.zig`

- [ ] **Step 1: Add the enum + fields**

In `demo/src/input_geom.zig`, just above `pub const ConvexVolume`:
```zig
pub const VolumeMode = enum(u8) { prism = 0, surface = 1 };
```
And extend `ConvexVolume` (after its `id` field):
```zig
    mode: VolumeMode = .surface,
    band_below: f32 = 1.0,
    band_above: f32 = 1.0,
```
(All defaulted — existing `ConvexVolume{...}` literals keep compiling; `id` already defaults.)

- [ ] **Step 2: Build**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add demo/src/input_geom.zig
git commit -m "demo(geom): ConvexVolume gains mode + band fields (default surface)"
```

---

## Task 4: branch the build marking on mode (3 samples)

**Files:** Modify `demo/src/sample_solo.zig` (`:265-268`), `demo/src/sample_tile.zig`, `demo/src/sample_temp_obstacles.zig`

- [ ] **Step 1: Add the import + branch (Solo)**

In `sample_solo.zig`, add near the other imports:
```zig
const convex_surface = @import("convex_surface.zig");
```
Replace the marking loop (`:265-268`):
```zig
        for (geom.volumes.items) |*vol| {
            const nv: usize = @intCast(vol.nverts);
            rc.area.markConvexPolyArea(ctx, vol.verts[0 .. nv * 3], nv, vol.hmin, vol.hmax, vol.area, &chf);
        }
```
with:
```zig
        for (geom.volumes.items) |*vol| {
            const nv: usize = @intCast(vol.nverts);
            switch (vol.mode) {
                .prism => rc.area.markConvexPolyArea(ctx, vol.verts[0 .. nv * 3], nv, vol.hmin, vol.hmax, vol.area, &chf),
                .surface => convex_surface.markConvexPolyAreaSurface(vol.verts[0 .. nv * 3], nv, vol.band_below, vol.band_above, vol.area, &chf),
            }
        }
```

- [ ] **Step 2: Same for Tile and Temp Obstacles**

Find the equivalent `markConvexPolyArea` loop in `sample_tile.zig` and `sample_temp_obstacles.zig` (grep `markConvexPolyArea`) and apply the SAME import + switch. (The chf variable name may differ — use the local one. TempObstacles may mark per-tile; keep the same per-vol switch inside its existing loop.) Report the exact lines you changed.

- [ ] **Step 3: Build**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add demo/src/sample_solo.zig demo/src/sample_tile.zig demo/src/sample_temp_obstacles.zig
git commit -m "demo(samples): branch convex-volume marking on mode (prism/surface)"
```

---

## Task 5: tool_convex UI (mode toggle + band sliders) + stamp on create

**Files:** Modify `demo/src/tool_convex.zig`

- [ ] **Step 1: Add state**

In the `ConvexVolumeTool` struct (near `box_height`/`box_descent`), add:
```zig
    new_mode: @import("input_geom.zig").VolumeMode = .surface,
    band_above: f32 = 1.0,
    band_below: f32 = 1.0,
```

- [ ] **Step 2: Stamp mode/band on the created volume**

In `onClick`, where `addConvexVolume(...)` is called (both the offset and non-offset branches), after the call set the just-added volume's mode/band. Since `addConvexVolume` appends to `geom.volumes`, set the fields on the last element. Replace each `... catch {}; self.dirty = true;` (after addConvexVolume) so that immediately after a successful add you do:
```zig
                        if (self.geom.volumes.items.len > 0) {
                            const last = &self.geom.volumes.items[self.geom.volumes.items.len - 1];
                            last.mode = self.new_mode;
                            last.band_below = self.band_below;
                            last.band_above = self.band_above;
                        }
```
Also, for the `surface` mode make `hmin/hmax` a generous bbox so the marker's bbox cull doesn't clip: when `self.new_mode == .surface`, compute `minh = min(vertY) - self.band_below - 1` and `maxh = max(vertY) + self.band_above + 1` before the addConvexVolume call (keep the existing min..max computation for prism). Read the current minh/maxh code (it now spans min..max of verts) and branch it on `self.new_mode`. Report exactly how you branched it.

- [ ] **Step 3: drawMenu — mode toggle + band sliders**

In `drawMenu`, replace the Shape Ascent/Descent sliders block so it shows:
- a mode toggle (two radios) writing `self.new_mode`:
```zig
        if (ui.radio(@src(), self.new_mode == .surface, "Mode: Surface", 320)) self.new_mode = .surface;
        if (ui.radio(@src(), self.new_mode == .prism, "Mode: Prism", 321)) self.new_mode = .prism;
```
- band sliders when surface, the existing Shape Ascent/Descent when prism:
```zig
        if (self.new_mode == .surface) {
            ui.slider(@src(), "Band Above = {d:.1}", &self.band_above, 0.1, 10.0);
            ui.slider(@src(), "Band Below = {d:.1}", &self.band_below, 0.1, 10.0);
        } else {
            ui.slider(@src(), "Shape Ascent = {d:.1}", &self.box_height, 0.1, 20.0);
            ui.slider(@src(), "Shape Descent = {d:.1}", &self.box_descent, 0.1, 20.0);
        }
```
(Confirm radio id_extra 320/321 are free via `rg -n "ui.radio" demo/src`. If taken, pick a free pair and report.)

- [ ] **Step 4: Build**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add demo/src/tool_convex.zig
git commit -m "demo(convex): UI mode toggle (surface/prism) + band sliders"
```

---

## Task 6: persist mode/band in volumes.bin (version bump, legacy -> prism)

**Files:** Modify `demo/src/persist/scene_io.zig`

- [ ] **Step 1: Extend the volume record + bump version**

Read the existing volume codec in `scene_io.zig` (the volumes.bin encode/decode + its per-record format and the volumes file/format version constant). Add three fields to the per-volume record AFTER the existing fields (so order is stable): `mode: u8`, `band_below: f32`, `band_above: f32`. Bump the volumes format VERSION constant by 1.
On DECODE: branch on the record/format version — if the record is the OLD version (no mode/band), set `vol.mode = .prism`, `band_below/above = 1.0` (legacy volumes load as prisms); if NEW version, read the three fields. (The per-record chunk-header carries the payload length, so distinguish old vs new by the format version in the file header, or by record byte-length — use whichever the existing codec exposes; report which.)

- [ ] **Step 2: Update the round-trip test**

In the existing volumes round-trip test in `scene_io.zig`, set a custom `mode = .surface` + `band_below/above` on a test volume before save, and assert they survive load. Add a second assertion that a record written at the OLD version decodes as `.prism` (if feasible to construct; otherwise document that legacy-read is covered by the version branch and skip).

- [ ] **Step 3: demo-test**

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo-test
```
Expected: all pass (volumes round-trip incl. mode/band). Also `zig build demo` exit 0.

- [ ] **Step 4: Commit**

```bash
git add demo/src/persist/scene_io.zig
git commit -m "demo(persist): volumes.bin carries mode + band (version bump; legacy -> prism)"
```

---

## Self-Review

- **Spec coverage:** §3 data model → Task 3; §4 marker → Tasks 1-2; §5 build branch → Task 4; §6 UI → Task 5; §7 persistence → Task 6; §8 viz (out of scope) — intentionally not a task; §10 tests → marker/plane tests (T1-2) + round-trip (T6). All covered.
- **Placeholder scan:** none — full code for the marker/plane/marking; mechanical tasks specify exact edits + "report what you changed" where a real field/line must be confirmed against the codebase.
- **Type consistency:** `VolumeMode`/`mode`/`band_below`/`band_above` identical across Tasks 3/4/5/6; `markConvexPolyAreaSurface(verts, nverts, band_below, band_above, area, chf)` signature identical in Task 2 (def) and Task 4 (call); `fitPlane`/`pointInPoly` defined T1, used T2.
- **Known unknowns flagged for the implementer:** Vec3 component access (`bmin.x` vs `.data`), `CompactCell`/`CompactSpan` literal construction, the sample-specific chf var names, the scene_io volume codec's version mechanism — each step says to confirm against the real code and report.
