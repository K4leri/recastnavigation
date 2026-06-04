# Scene skeleton (foundation step 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `Scene` aggregate (the future point-of-truth for editable world state) plus stable per-object ids for convex volumes, as a tested, dependency-light skeleton that later foundation steps (persistence, clusters F/I/H) consume.

**Architecture:** A new `demo/src/scene.zig` defines `DirtyBits` (change tracking), `SceneMeta` (name + format version) and a thin `Scene` struct that holds a `*InputGeom` plus `meta`/`dirty`. It does NOT take ownership of `geom` or migrate the module-global `area_types`/`poly_flags` yet (that is foundation step 5, via transitional wrappers). Convex volumes gain a monotonic stable `id` (off-mesh already has `off_id`), satisfying owner decision D2. This increment adds NO `main.zig` changes — wiring happens when persistence first reads a `Scene`.

**Tech Stack:** Zig 0.16 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`). Standalone unit tests via `zig test <file>` (no build graph / proxy needed). `scene.zig` imports `input_geom.zig`, which only depends on `std` + `io_util` (also std-only), so `zig test demo/src/scene.zig` compiles standalone.

---

## File Structure

- **Create** `demo/src/scene.zig` — `DirtyBits`, `SceneMeta`, `Scene` aggregator. Owns `meta`+`dirty`, borrows `*InputGeom`. Self-test block.
- **Modify** `demo/src/input_geom.zig` — add `id: u32 = 0` to `ConvexVolume`; add `next_volume_id: u32 = 1` to `InputGeom`; assign the id in `addConvexVolume`. Extend the existing test block (or add one) for id stability.

Both pieces are additive and behaviour-preserving: nothing reads the new id yet, and `Scene` is not instantiated anywhere yet. This is an intentionally inert, fully-tested skeleton (the next foundation step — persistence — is its first consumer).

---

## Task 1: scene.zig (DirtyBits + SceneMeta + Scene)

**Files:**
- Create: `demo/src/scene.zig`
- Test: same file (Zig `test` block)

- [ ] **Step 1: Write the module with its tests**

Create `demo/src/scene.zig`:

```zig
//! Scene — the aggregate of editable world state (foundation step 2 skeleton).
//! Intended to become the single point-of-truth that persistence serialises and
//! that tools/clusters read. For now it borrows the existing `InputGeom` and owns
//! only the NEW pieces (meta + dirty tracking); the module-global area/flag
//! registries are migrated in a later step (foundation step 5) via transitional
//! wrappers, so they are deliberately NOT moved here yet.

const std = @import("std");
const InputGeom = @import("input_geom.zig").InputGeom;

/// On-disk format version for the scene container (edits/manifest). Bumped when
/// the serialised layout changes; readers use it for backward compatibility.
pub const FORMAT_VERSION: u32 = 1;

/// What changed since the last save. Drives "needs rebuild" / "needs save"
/// decisions and (later) which tiles/registries to re-serialise.
pub const DirtyBits = struct {
    geom: bool = false,
    areas: bool = false,
    flags: bool = false,
    tiles: bool = false,

    pub fn any(self: DirtyBits) bool {
        return self.geom or self.areas or self.flags or self.tiles;
    }
    pub fn clear(self: *DirtyBits) void {
        self.* = .{};
    }
    pub fn markAll(self: *DirtyBits) void {
        self.* = .{ .geom = true, .areas = true, .flags = true, .tiles = true };
    }
};

/// Scene identity/metadata persisted alongside the geometry and registries.
pub const SceneMeta = struct {
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    format_version: u32 = FORMAT_VERSION,

    pub fn name(self: *const SceneMeta) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn setName(self: *SceneMeta, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

/// Aggregate of editable world state. Borrows `geom` (does not own/free it);
/// owns `meta` and `dirty`. Accessors are the start of the point-of-truth API
/// and grow as clusters need them.
pub const Scene = struct {
    geom: *InputGeom,
    meta: SceneMeta = .{},
    dirty: DirtyBits = .{},

    pub fn init(geom: *InputGeom) Scene {
        return .{ .geom = geom };
    }

    pub fn volumeCount(self: *const Scene) usize {
        return self.geom.volumes.items.len;
    }
    pub fn offMeshCount(self: *const Scene) usize {
        return self.geom.off_id.items.len;
    }
};

test "DirtyBits any/clear/markAll" {
    var d = DirtyBits{};
    try std.testing.expect(!d.any());
    d.geom = true;
    try std.testing.expect(d.any());
    d.clear();
    try std.testing.expect(!d.any());
    d.markAll();
    try std.testing.expect(d.geom and d.areas and d.flags and d.tiles);
}

test "SceneMeta name + default version" {
    var m = SceneMeta{};
    try std.testing.expectEqual(@as(u32, FORMAT_VERSION), m.format_version);
    try std.testing.expectEqualStrings("", m.name());
    m.setName("nav_test");
    try std.testing.expectEqualStrings("nav_test", m.name());
}

test "Scene borrows geom and reports counts" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var scene = Scene.init(&geom);
    try std.testing.expectEqual(@as(usize, 0), scene.volumeCount());
    try std.testing.expectEqual(@as(usize, 0), scene.offMeshCount());
    try std.testing.expect(!scene.dirty.any());
}
```

- [ ] **Step 2: Run the tests, expect PASS**

Run: `& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/scene.zig`
Expected: `All 3 tests passed.`

> If standalone compilation fails because `input_geom.zig` pulls a build-graph-only
> dependency (it should not — only `std`/`io_util`), report it as BLOCKED with the
> exact error rather than working around it; the controller will switch this test to
> `zig build test`.

- [ ] **Step 3: Commit**

```bash
git add demo/src/scene.zig
git commit -m "demo(scene): add Scene skeleton (DirtyBits, SceneMeta, aggregate)"
```

---

## Task 2: Stable ids for convex volumes

**Files:**
- Modify: `demo/src/input_geom.zig` — `ConvexVolume` (line ~13-19), `InputGeom` struct fields (line ~21-38), `addConvexVolume` (line ~188-189), test block.

Off-mesh connections already carry `off_id`; convex volumes have no stable
identity, which breaks selection/undo (cluster F) and repro (cluster I). Add a
monotonic id so an id is never reused even after a volume is removed.

- [ ] **Step 1: Add the id field to ConvexVolume**

Replace (`demo/src/input_geom.zig:13-19`):

```zig
pub const ConvexVolume = struct {
    verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined,
    nverts: i32 = 0,
    hmin: f32 = 0,
    hmax: f32 = 0,
    area: u8 = 0,
};
```

with:

```zig
pub const ConvexVolume = struct {
    verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined,
    nverts: i32 = 0,
    hmin: f32 = 0,
    hmax: f32 = 0,
    area: u8 = 0,
    /// Stable identity, assigned monotonically by InputGeom.addConvexVolume.
    /// Never reused, so selection/undo (cluster F) and repro (cluster I) can
    /// reference a volume across add/remove. 0 = unassigned.
    id: u32 = 0,
};
```

- [ ] **Step 2: Add the monotonic counter to InputGeom**

Add a field to the `InputGeom` struct. Insert after the `off_id: Managed(u32),`
line (`:38`):

```zig
    /// Next stable convex-volume id (monotonic; never reused). Starts at 1 so 0
    /// stays the "unassigned" sentinel.
    next_volume_id: u32 = 1,
```

(The field has a default, so the existing `InputGeom.init` struct literal at
`:40-53` does NOT need changing — it may omit `next_volume_id`.)

- [ ] **Step 3: Assign the id in addConvexVolume**

Replace (`:188-189`):

```zig
    pub fn addConvexVolume(self: *InputGeom, verts: []const f32, nverts: i32, minh: f32, maxh: f32, area: u8) !void {
        var vol = ConvexVolume{ .nverts = nverts, .hmin = minh, .hmax = maxh, .area = area };
```

with:

```zig
    pub fn addConvexVolume(self: *InputGeom, verts: []const f32, nverts: i32, minh: f32, maxh: f32, area: u8) !void {
        var vol = ConvexVolume{ .nverts = nverts, .hmin = minh, .hmax = maxh, .area = area, .id = self.next_volume_id };
        self.next_volume_id += 1;
```

(The rest of `addConvexVolume` — copying verts and `try self.volumes.append(vol)` —
stays unchanged. The `self.next_volume_id += 1;` line goes immediately after the
`var vol = ...;` line.)

- [ ] **Step 4: Add a test for id stability**

Append this test at the end of `demo/src/input_geom.zig` (inside the file's
top-level scope, alongside any existing `test` blocks):

```zig
test "addConvexVolume assigns monotonic non-reused ids" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 }; // 3 verts
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);

    try std.testing.expectEqual(@as(u32, 1), geom.volumes.items[0].id);
    try std.testing.expectEqual(@as(u32, 2), geom.volumes.items[1].id);
    try std.testing.expectEqual(@as(u32, 3), geom.volumes.items[2].id);
    // counter never rewinds, so the next id is strictly greater than any assigned
    try std.testing.expectEqual(@as(u32, 4), geom.next_volume_id);
}
```

> If `input_geom.zig` has no `const std = @import("std");` at file scope, add it (it
> almost certainly already imports std). Use the existing import if present — do not
> duplicate it.

- [ ] **Step 5: Run the tests, expect PASS**

Run: `& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/input_geom.zig`
Expected: all tests pass, including `addConvexVolume assigns monotonic non-reused ids`.

- [ ] **Step 6: Build the demo to confirm the new field didn't break callers**

```bash
powershell -NoProfile -Command "Get-Process recast_demo -ErrorAction SilentlyContinue | Stop-Process -Force"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
"C:/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe" build demo
```
Expected: exit 0. (`ConvexVolume` literals elsewhere omit `id`, which is fine — it
defaults to 0; serialisation/copy sites just carry the extra field.)

- [ ] **Step 7: Commit**

```bash
git add demo/src/input_geom.zig
git commit -m "demo(geom): stable monotonic id for convex volumes"
```

---

## Self-Review

- **Spec coverage (foundation §3.a + roadmap step 2 + decision D2):** `Scene`/`SceneMeta`/`DirtyBits` ✓ (Task 1); stable per-object id for volumes ✓ (Task 2). Module-global migration and `main.zig` wiring are explicitly deferred (Architecture) to foundation step 5 / the persistence step — NOT in scope here. `CommonSettings` unification (D6/Q6) likewise deferred until a consumer needs it (YAGNI).
- **Placeholder scan:** none — exact paths, code, commands.
- **Type consistency:** `DirtyBits`/`SceneMeta`/`Scene`/`FORMAT_VERSION` defined once and used consistently; `Scene.init(geom: *InputGeom)` matches the test usage; `next_volume_id` (InputGeom) and `id` (ConvexVolume) named identically across Task 2 steps.
- **Behaviour invariants:** Task 2 only ADDS fields with defaults; no existing `ConvexVolume{...}` literal or `addConvexVolume` caller changes meaning (id defaults to 0 where unset, assigned where created). Build-verify (Task 2 Step 6) guards against a caller that constructs `ConvexVolume` positionally (none expected — all use field-named literals).
