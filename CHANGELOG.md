# Changelog

All notable changes to zig-recast are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.1] - 2026-06-06

### Added
- **In-app help for Area Type and Poly Flags.** Both concepts were easy to
  confuse; each section title now carries a hoverable **(?)** marker that pops a
  wrapped floating tooltip. *Area Type* (Tools → Convex): terrain class painted
  onto polygons, one per polygon, drives movement **cost**. *Poly Flags* (manager
  window): per-polygon capability bits (walk/swim/door/jump/disabled) the query
  filter includes/excludes to gate **passability** — and the link between them
  (an area type grants flags at build). New `ui.helpIcon` / `ui.sectionHelp`
  helpers. (`demo/src/ui.zig`, `demo/src/tool_convex.zig`, `demo/src/main.zig`)

### Fixed
- **Follow-mode path now crosses off-mesh connections.** The smooth/follow path
  (`smoothPath`) only handled the END steer flag, not
  `DT_STRAIGHTPATH_OFFMESH_CONNECTION`; since `moveAlongSurface` can't traverse an
  off-mesh link, the dotted path stalled at the connection mouth (never over the
  arrow nor on to the agent). Added the off-mesh branch 1:1 with upstream
  Tool_NavMeshTester (advance the corridor over the link via
  `getOffMeshConnectionPolyEndPoints`, teleport to the far endpoint, continue).
  Off-mesh scene save/load was verified correct (two new deterministic repro
  tests). (`demo/src/tool_navmesh_tester.zig`)

### Changed — internal dedup wave (demo-only, behaviour-identical)
Consolidated duplicated `demo/src/*` logic into shared modules with **zero**
behaviour change — proven by byte-identical navmesh hashes for all three samples
(solo `0x0830…`, tile `0xa64b…`, temp `0x4b27…`), byte-identical `.gset`/glb/JSON
exports, and green suites (`demo-test` 260/260, core 91/91). Faithful `src/*`
untouched. ~60+ duplicate copies removed across four tiers:
- **A1** — `io/json_emit.zig` (JSON emit), `ui.zig` rgba→Color helpers, crowd
  update-flags.
- **A2** — `navmesh_walk.zig`: one shared, bounds-checked read-only navmesh
  traversal (centroid / tile-and-poly / detail-vert / detail-tri iteration),
  migrated across 8 consumers.
- **B** — `persist/byteio.zig` (overflow-safe LE reader/writer) + record framing
  in `checksum.zig`; `io/glb.zig` (GLB container codec); comptime settings table.
- **C** — `sample.zig` shared build derivations (`deriveCfg` / `computeTileGrid`
  / `markConvexVolumes`) and `render/navmesh_layer.zig`, single-sourcing the
  solo/tile/temp samples' build + render.

## [0.2.0] - 2026-06-05

### Added — Navmesh Debug & Analysis Platform (demo GUI)

A large, self-contained set of developer tooling layered on top of the faithful
recast/detour core (faithful `src/*` untouched — only additive read-only getters;
all new logic lives under `demo/src/`). Delivered as six feature clusters plus a
foundation, on the `feat/debug-platform` branch (clusters A–J). Each feature was
implemented behind a two-stage review (spec compliance + code quality) with unit
tests for the load-bearing pure logic. The test suites stay green: `zig build
demo`, `zig build demo-test` (250/250), `zig build test` (91/91).

#### Foundation (Scene / Persist / Render / UI-shell)
- **Durable scene persistence** — a `.recastscene/` container (one shareable
  directory) holding the `.gset` (verbatim RecastDemo format), per-edit chunks,
  saved tiles, and a manifest. Every chunk carries a header (magic / version /
  payload length / **XXH3** checksum) and is written via an **atomic write**
  (create-temp → flush → fsync → replace → dir-fsync) so a crash mid-save can't
  corrupt the live file. Graceful degradation: a bad chunk is skipped with a
  warning and per-record recovery, not a hard failure. Save / Load + named save
  variants (scrollable list past 5). (`demo/src/persist/{write_atomic, checksum,
  registry_io, scene_io, scene_container, tile_store, manifest}.zig`)
- **Area-type / poly-flag registries** with names, colours, per-area movement
  cost, and poly-flag bits — replacing the hard-coded `SamplePolyAreas`.
- **Render layer** (`demo/src/render/`) — a per-polygon visit/colour pass that
  parameterises the faithful tile walk with a visibility predicate + colour
  callback, so the navmesh can be recoloured/filtered without touching the core
  `debugDrawNavMesh`. (`color_scheme`, `poly_visit`, `components`, `scheme_state`,
  `filter_state`, `view_state`, `isolation`, `legend`, `overlay`, `minimap`,
  `capture`)
- **UI shell** — input gate (keyboard hotkeys suppressed while a text field has
  focus), a tool registry (single source of truth for the tool radios + the
  control hint), and movable/resizable floating windows for the diagnostic panels.

#### Cluster F — Editing / authoring UX (`demo/src/edit/`)
- **Undo / redo** with a fixed-depth ring buffer and a command-pattern `EditOp`
  (add/delete/edit volume & off-mesh, area/flag registry edits, **composite**
  group edits as one undo unit, whole-registry snapshot) + **autosave**.
- **Snap** (`snap.zig`) — vertex / edge / grid / object snapping with a **live
  marker under the cursor**; Ctrl bypasses; per-mode radius/step.
- **Multi-select** (`selection.zig`) — rubber-band box-select, Ctrl+click toggle,
  group **move** (drift-free), **copy/paste** (Ctrl+C/V, fresh ids, offset), and
  **group delete** — all undo-able as single composite commands. Selection is by
  stable id, surviving undo/redo churn.
- **Property inspector** (`inspector.zig`) — numeric edit of a single selected
  volume (hmin/hmax/area/mode/band) or off-mesh (start/end/radius/dir/area/flags),
  staged + Apply = one undo op; the volume's prism/surface/height/band edits show
  a **live 3D preview** before Apply commits + rebuilds.
- **Surface-band convex volumes** (`convex_surface.zig`) — a convex volume can now
  **drape the navmesh surface** (Surface mode) instead of being a flat min/max
  prism: a plane is fit to the hull and each column is marked within a band ± the
  fitted surface, so the painted area hugs sloped / terraced ground. Prism mode
  (flat box) stays as the toggle alternative. Mode + band are set at creation and
  editable in the inspector; both modes round-trip through the scene format.
  (`tool_convex.zig`, `convex_surface.zig`, `input_geom.ConvexVolume.mode/band`)
- **Presets** (`presets.zig`) — save/apply named area+flag presets over the
  `registry_io` format (`presets/*.reg`), Replace or Merge, undo-able; OOM-safe.
- **Incremental tile rebuild** (Tile sample) — rebuilds only dirty tiles (±1
  expansion) on edit; proven byte-for-byte identical to a full rebuild by a
  regression test (`test/integration/incremental_rebuild_test.zig`).

#### Cluster E — Visualization / render
- **Colour schemes** — recolour the navmesh by **area / flags / height / tile /
  component / cost** (green→red). Live, with a **legend** overlay (swatches for
  discrete schemes, a gradient bar with min/max for continuous).
- **Clipping plane + layer isolation** — read overlapping floors one at a time:
  clip above / below / slab by a Y slider (spanning the **navmesh** height range)
  + isolation show-only / dim-others by tile / area / flags.
- **Wireframe** toggle + per-group visibility (input mesh / navmesh / off-mesh /
  convex / labels).
- **Polygon overlay labels** — poly-ref / centroid / area / cost over polys
  (none / hovered / all, auto-capped).
- **Minimap** — top-down overview (bbox, tile grid, off-mesh + convex markers,
  camera look-at marker) with click / tile (tx,ty) / poly-ref **fly-to**.
- **Frame-sequence capture** — `glReadPixels` → durable PPM frames + manifest,
  orbit or live, with a `--capture=<dir>,<frames>` headless CLI flag (assemble
  with `ffmpeg -i frame_%05d.ppm out.mp4`).

#### Cluster A — Query diagnostics (`demo/src/diag/`)
- **Why-no-path verdict** (`why_no_path.zig`, `diagnose.zig`) — a decision machine
  that explains a failed route in plain language: invalid endpoint / same poly /
  **different components** (a real topological gap) / **filtered-by-flags** /
  **blocked-by-cost** / node-limit, using a user-filter-aware reachability BFS to
  separate "flags blocked it" from "cost steered around it".
- **Stepped A* / Dijkstra player** (`astar_player.zig`) — play / pause / advance-1
  / advance-N / finish over the sliced API, with a **Play-speed throttle**;
  per-frame visited / frontier / current-best / partial-corridor highlight and
  g/h/f labels.
- **Funnel / portal debug** (`funnel.zig`) — portal left/right edges, all-crossings
  waypoints, and turn/apex highlights of the string-pulling.
- **Side-by-side filter comparison** (`filter_compare.zig`) — run the same query
  under up to three include/exclude filters at once, each route in its own colour
  with a poly-count / cost / reaches legend.
- **Connected components** (`components.zig`) — flood-fill island colouring; feeds
  the component colour scheme and the why-no-path component test.
- **Reachability heatmap** (`reachability.zig`) — a Dijkstra flood from a source
  poly (honouring the filter), painting each reachable poly green→red by travel
  cost; unreachable = grey.

#### Cluster B — Build-pipeline introspection
- **Per-stage build inspector** (`build_stats.zig`) — counts + wall-clock time for
  each of the 7 Recast stages, in a panel.
- **Param diff** — delta of every stage's counts/ms vs the previous build.
- **Artifact detectors** (`artifacts.zig`) — degenerate detail triangles, tiny
  (sliver) polys, dead-end (single-link) polys, with a bright 3D culprit
  highlight (beacon + cross).
- **Polygon table inspector** (`poly_inspect.zig`) — area / flags / neighbours /
  links / height range of the clicked poly, replacing the old stderr dump.

#### Cluster C — Profiling / performance
- **Build profiler + run history** (`profiler.zig`) — a 16-build ring with a
  stage stacked-bar + a total-time sparkline.
- **Route-query benchmark** (`query_bench.zig`) — K random `findPath` runs →
  latency **p50 / p95 / p99 / min / max / avg**, success rate, avg visited nodes,
  and a latency histogram.
- **Memory budget** (`mem_budget.zig`) — navmesh / polymesh / detail bytes,
  per-tile data size, tile-cache raw vs compressed.

#### Cluster G — Validation / regression
- **Navmesh linter** (`navmesh_lint.zig`) — static findings: isolated islands,
  null-area polys, degenerate polys, dangling off-mesh, orphan tiles; a Validation
  panel + a `--lint` CLI whose exit code = the error-finding count (CI gate).
- **Integrity verifier** (`navmesh_verify.zig`) — structural invariants: freelist
  consistency, valid link refs, portal symmetry (off-mesh links correctly
  excluded), off-mesh endpoints, salt freshness; a Verify panel + a `--verify`
  CLI whose exit code = the violation count. Proven free of false positives on a
  real two-tile stitched fixture.

#### Cluster D — Import / export / interop (`demo/src/io/`, `demo/src/cli/`)
- **Geometry import beyond `.obj`** — STL (binary + ASCII), PLY (ASCII + binary
  LE/BE), and glTF 2.0 / `.glb` (TRIANGLES, `POSITION` + indices, node world
  transforms, `.glb` BIN + `data:`-base64 buffers). A single extension dispatch
  feeds the same model as `.obj`; the input-mesh dropdown and scene loader now
  accept `*.obj/.stl/.ply/.gltf/.glb`. Each parser is `std`-only, unit-tested, and
  passed an opus correctness pass (tab/exponent ASCII STL; PLY x/y/z-by-role +
  index validation + big-endian; glTF `byteStride`-from-bufferView + quaternion
  node compose). Triangle indices are range-checked at the single import sink, so
  a malformed mesh is rejected, not crashed-on. (`import_{stl,ply,gltf,geom}.zig`)
- **Navmesh geometry export** — `.obj` (arbitrary-arity faces) and a minimal
  `.glb` (4-byte-aligned chunks, `POSITION` min/max, u16/u32 indices).
  (`export_obj.zig`, `export_gltf.zig`, `nav_export.zig`)
- **Metrics JSON** — a deterministic, versioned schema (settings snapshot, bounds,
  tile/poly/vert counts, per-area histogram, build-ms, navmesh verify-hash);
  GUI Export button + headless. Non-finite floats are normalised so the output is
  always valid JSON. (`export_metrics.zig`)
- **Query-results export** — the tester's current query as CSV + JSON
  (`export_query.zig`); **SVG** top-down topology export (`export_svg.zig`).
- **Headless build CLI** — `recast_demo build --geom <p> [--cfg k=v,…] --metrics
  <out|->` builds a navmesh with **no window / no GL** (reuses the GUI build path,
  so the numbers are identical) and can emit the navmesh / `.obj` / `.glb` / SVG;
  CI-friendly exit codes. (`cli/headless_build.zig`, `cli/cli.zig`)
- **Upstream diff** — `recast_demo diff --a a.json --b b.json [--eps f]` compares
  two metric snapshots (exact counts/strings, eps-tolerant floats, areas matched
  by id) with a CI exit code — a direct faithful-port validation hook against
  C++ recast. (`cli/diff.zig`)

#### Cluster I — Reproducibility / sharing (`demo/src/persist/`)
- **`.recastbundle` single-file archive** — packs a whole `.recastscene/` container
  plus a repro section into one shareable file (per-entry XXH32 checksum,
  bounds-/corruption-safe; never panics on a malformed bundle). Export / Import
  Bundle buttons + drag-a-bundle-onto-the-exe / `recast_demo bundle import`.
  (`persist/bundle.zig`, `bundle_io.zig`)
- **Repro query manifest** — Export Bundle snapshots the tester's current
  query + result as `repro/query.json` (the "expected" for compare on import).
- **Determinism verify-hash** — metrics carry an **XXH3** over the navmesh tile
  bytes; the same geom + settings yields a byte-identical hash across runs
  (verified), and any divergence from an upstream build shows up in `diff`.

#### Cluster J — Dynamics / runtime (`demo/src/diag/`, crowd + tilecache)
- **Crowd why-stuck** — classifies *why* an agent isn't moving (off-navmesh /
  no-target / pending / no-path / partial / blocked-by-neighbours / arrived) from
  its already-stored fields; short tags over stuck agents + an explain line for
  the selection. (`diag/why_stuck.zig`)
- **TileCache time-line** — an obstacle event journal, a **Step-rebuild** toggle
  (regeneration becomes visible over frames instead of drained silently per
  frame), and an amber wire-box highlight of each tile currently regenerating.
- **Crowd analytics** — live graphs of stuck-count, avg/max speed, and max
  proximity-grid density; **dynamic off-mesh toggle** — disable all off-mesh links
  at runtime and watch agents reroute.
- **Crowd record / replay** — record user actions to an append-only journal, then
  replay them deterministically forward at a fixed `dt` (binary save/load).
  (`diag/crowd_replay.zig`)

#### Cluster H — Scripting / headless (`demo/src/cli/`)
- **Config-file run** — `recast_demo headless --config run.json`: a declarative
  `{geom, sample, settings, queries[], outputs}` executed with no window.
- **Query script** — `findPath` / `findStraightPath` / `raycast` / `findNearestPoly`
  / `findDistanceToWall` run headless against the built navmesh → CSV/JSON results.
  (`cli/headless_query.zig`)
- **Batch matrix** — `recast_demo batch --matrix "cell_size=0.2,0.3,0.5;agent_radius=
  0.4,0.6"`: a cartesian parameter sweep → a per-cell table (polys, verts,
  build-ms, queries found/total). (`cli/headless_run.zig`)
- All headless modes share the GL-free build path and report CI-friendly exit
  codes; `area_types`/`poly_flags` remain process-global, so headless is
  one-scene-per-process for now (parallel workers are a later step).

### Fixed
- **`zig build test` no longer aborts on Windows.** Dozens of integration tests run
  the full recast pipeline, and `Context.log` streamed hundreds of `[PROGRESS]`
  lines to the test process's stderr, which the build server captures over
  `--listen=-`; the spam raced the result-manifest read and crashed the build
  runner ("unable to read results of configure phase … FileNotFound"). `Context.log`
  now suppresses output under `builtin.is_test` (logging only — no algorithm or
  demo behaviour change). Core suite: 91/91 green. (`src/context.zig`)
- **Select/Edit Properties inspector fixed.** Editing a selected convex volume /
  off-mesh now actually shows its fields: the panel was emitted *inside* an
  unscoped horizontal box and clipped off-screen. Sliders that snapped to the
  minimum, jittered across digit-width changes, or blew the value "into space" are
  replaced with drag-only, scene-relative-range sliders; volume edits now show a
  **live 3D preview** (prism/surface, height, band, area) before Apply commits and
  rebuilds, and Ctrl+Z undoes. (`demo/src/main.zig`, `input_geom.zig`)
- **Debug-draw of a stale / invalid poly-ref no longer crashes the GUI.** The
  faithful `debugDrawNavMeshPoly` indexes `mesh.tiles[decoded.tile]` guarded only
  by `max_tiles`; a path ref that survived a navmesh swap could index past the
  actual `tiles` slice and panic. The Test-Navmesh path highlight now draws each
  polygon itself with a bounds check on every tile-vertex access (validating via
  `getTileAndPolyByRef`), never calling the unguarded faithful path; the lint and
  crowd overlays gained the same `tiles.len` guard. (`demo/src/`)
- **Hotkey conflicts resolved.** Camera reset moved off `F` to `R` (`F` / `Home`
  no longer reset the view); the cull-winding / voxel-variant dev toggles moved
  off `C` / `V` to `K` / `J`, so `Ctrl+C` / `Ctrl+V` copy-paste no longer also
  fire them and corrupt the view.
- **The tile-cache → navmesh bake path now works** (`dtTileCache::buildNavMeshTile`).
  It was unexercised by the existing tests (they add obstacles but never add layer
  tiles), which hid five faithful-port bugs. Found and fixed while adding a real
  end-to-end regression test (`test/integration/tilecache_navmesh_test.zig`):
  1. `@memset` filled the `[]u16` polygon arrays with `0x00ff` instead of the
     `0xffff` null-index sentinel — Zig's `@memset` writes per-element, not the
     per-byte fill C++ `memset(...,0xff,...)` produces — so `createNavMeshData`
     mis-parsed every polygon. Fixed at all six sites in
     `src/detour_tilecache/builder.zig`.
  2. `buildNavMeshTile` passed the header-stripped `tile.compressed` to the
     decompressor, which reads the layer header from offset 0 (a double strip); now
     passes the full `tile.data`, matching upstream.
  3. `getPolyMergeValue` bounded its vertex slice with the not-yet-synced
     `mesh.nverts` (still 0 inside the contour loop) instead of the live count.
  4. The polygon-merge compaction did `@memcpy(pb, last)` which Zig rejects when
     `pb` *is* the last poly (self-alias); added the same `pb.ptr != last.ptr`
     guard core `rcBuildPolyMesh` already uses.
  5. Tile-cache navmesh tiles were added with `free_data=false` and the rebuild
     `removeTile` result was discarded, leaking the old tile every bake. They now
     use `DT_TILE_FREE_DATA`, and `dtNavMesh::removeTile` frees owned data instead
     of always handing it back (matching upstream).
- **All 10 examples build and run again.** They had rotted against Zig 0.16 (the
  removed `std.heap.GeneralPurposeAllocator`) and against the current namespaced
  library API (`recast.recast.<step>.*` / `recast.detour.*`), so `zig build
  examples` did not even compile and most examples were print-only stubs. Every
  example was rewritten to the current API and now does real work — full bake +
  pathfinding, tiled/stitched navmesh, off-mesh connections, crowd steering,
  tile-cache obstacles, custom area costs, sliced pathfinding, tile streaming —
  each with a `DebugAllocator` leak check. (`examples/`, `build.zig`)
- **Release binaries are now portable across CPUs.** The release CI built the demo
  with native CPU features of the GitHub Actions runner, so ReleaseFast could emit
  AVX-512 / newer instructions that crash with an illegal-instruction *and no log*
  on user machines with a different CPU. The release now builds with an explicit
  baseline target (`-Dtarget=x86_64-windows` / `x86_64-linux` / `aarch64-macos`),
  so the binary runs on any x86_64 / arm64. (`.github/workflows/release.yml`)

### Added
- **CI workflow** (`.github/workflows/ci.yml`): on every push/PR it runs the
  library tests, the integration tests, and builds **and runs** all 10 examples
  (`zig build run-examples`) as a runtime smoke test, so the examples can't
  silently rot against the API again.
- **64-bit poly/tile refs for very large worlds** (`zig build -Dpolyref64=true`),
  the comptime equivalent of the C++ `DT_POLYREF64` compile flag. A single build
  option flips `PolyRef`/`TileRef`/`CompressedTileRef` from `u32` to `u64` and the
  salt/tile/poly bit layout (DT_POLYREF64: salt 16 / tile 28 / poly 20), deriving
  the shift/mask widths from the ref type — no hand-editing of the source. Default
  stays 32-bit. The whole thing is comptime-folded (no runtime cost). Note: the
  tile-data layout differs between the two modes (the `Link` section grows), so
  navmeshes are not interchangeable across `-Dpolyref64`; pick the mode at build
  time and regenerate. (`build.zig`, `src/detour/common.zig`, `src/detour/navmesh.zig`,
  `src/detour_tilecache/tilecache.zig`)

## [0.1.7] - 2026-06-03

### Fixed
- **Demo now runs on GPUs without OpenGL 4.5** (reported: "entry point
  glGetnTexImage not found!" on a GL 4.1 driver). Two independent causes:
  1. `zgl.loadExtensions` resolves the *entire* GL set up to 4.6 via
     `wglGetProcAddress` and errors if **any** entry point is missing; the demo
     called it with `try`, so a driver lacking the unused GL 4.5 robustness
     functions (`glGetnTexImage`, `glGetnUniformdv`, …) was killed at startup.
     The error is now ignored — every function the demo actually needs loads
     independently. (`demo/src/main.zig`)
  2. The 3D debug renderer used zgl wrappers that map to **GL 4.5 Direct State
     Access** (`createBuffer`→`glCreateBuffers`, `createVertexArray`→
     `glCreateVertexArrays`, `createTexture`→`glCreateTextures`,
     `textureParameter`→`glTextureParameteri`). On a 4.1 driver those are null,
     so the demo would have crashed at renderer init even after fix (1). They are
     now behind a runtime `hasDSA()` check (GL ≥ 4.5 or `GL_ARB_direct_state_access`):
     DSA is used where available, with a classic core GL 3.3 fallback
     (`glGen*`+bind / `glTexParameteri`) otherwise. The chosen path is logged at
     startup (`[GL] DSA=yes/no`). Verified by a full per-call GL-version audit:
     the only remaining >3.3 calls are `glProgramUniform*` (GL 4.1 core), which
     the reporting driver supports. (`demo/src/debug_draw_gl.zig`)

### Performance
- Comptime-unrolled the fixed 4-direction loops in `getHeightData`,
  `erodeWalkableArea` and `medianFilterWalkableArea` (output-identical micro-opt).
  (`src/recast/detail.zig`, `src/recast/area.zig`)

### Changed
- Crowd: `sampleVelocityAdaptive` now uses `usize` for `ndivs`/`nrings`
  directly, dropping 4 redundant casts (byte-identical). (`src/detour_crowd/obstacle_avoidance.zig`)

## [0.1.6] - 2026-06-03

### Added
- **Demo crowd: "Show Perf Graph".** Re-implemented the upstream graph renderer
  (left `#if 0` in RecastDemo) on dvui — a `ValueHistory` ring buffer plus a 2D
  line graph (background, sample polyline, legend with running average). Plots
  the crowd update time (ms) and the velocity sample count per tick.

### Fixed
- **Demo crowd: new agents now join the active move target.** Creating an agent
  while the crowd already has a target left the new agent standing still; it now
  immediately requests the current target, 1:1 with `CrowdToolState::addAgent`
  (`if (targetPolyRef) requestMoveTarget(...)`).

## [0.1.5] - 2026-06-03

### Fixed
- **Crowd: agents no longer collapse into a single point at high density.** The
  neighbour search kept the *first* `MAX_NEIGHBOURS` agents the proximity grid
  happened to return (arbitrary order) instead of the *closest* ones. In a dense
  crowd the grid returns up to 32 agents and the closest/overlapping neighbours
  were often dropped, so collision resolution never pushed those agents apart and
  they merged onto one another. Now uses a sorted insertion that keeps the closest
  `MAX_NEIGHBOURS` — 1:1 with `dtCrowd`'s `addNeighbour` (`DetourCrowd.cpp`). A
  36-agent converge-on-one-target repro went from 264 overlapping pairs (fully
  collapsed) to 2–5. Pre-existing since ≤ v0.1.3 (not a v0.1.4 regression).
  (`src/detour_crowd/crowd.zig`)

### Performance
- `rcBuildRegions` (watershed) is now **O(n) again — 20–110× faster** on every
  navmesh build, restoring exact parity with C++ (de_ancient @8M: 44 710 ms →
  1 389 ms vs C++ 1 384 ms). `expandRegions` reconstructed each cell's "used"
  mark with a nested linear scan over `dirty_entries` (O(stack²) → O(n^1.5..2)
  watershed); now it marks in place the instant a region is found, 1:1 with
  upstream (`RecastRegion.cpp` `stack[j].index = -1`). **Output is unchanged**
  (poly/vert counts identical; `undulating.obj` still 374 verts / 216 polys).
  Found via the Tracy `ZIG_VS_CPP_PERF` benchmark.

### Demo
- Removed the leftover debug window-title marker (`RecastDemo voxel V=…`); the
  title is now just `RecastDemo — zig + dvui`. The `V` voxel-render-variant
  toggle stays (logs to the console).

## [0.1.4] - 2026-06-02

### Demo
- Surface checker texture now matches RecastDemo: per-triangle triplanar UV
  (1:1 `duDebugDrawTriMesh` — UV axes are the two perpendicular to the dominant
  normal axis). Walls previously got `(x, z)` UVs for every triangle, so the
  texture smeared vertically and only vertical grid lines showed; now floors and
  walls both render the full square grid. Added `DebugDrawGL.vertexUV`.
- Draw the input-mesh bounds wireframe box (1:1 `Sample::render` —
  `duDebugDrawBoxWire`, white 255/255/255/128) in all three samples.
- Removed the non-upstream ground grid (RecastDemo draws no floor grid).

### Tests
- Pinned the `filterLedgeSpans` operator question (upstream [#772]) with two
  regression tests (`test/filter_test.zig`): the canonical flat-10×10 edge test
  (1:1 with upstream main's merged `rcFilterLedgeSpans` test — operator-agnostic,
  passes under both `>=`/`<` and `>`/`<=`), and the #772 pillar scenario — the
  only input where the operator matters. We follow upstream **main** (`>=`/`<`),
  which collapses the whole interior to ledge where #772's open/unmerged `>`/`<=`
  would keep the diagonal; the second test is the canary that flips if #772 ever
  lands. See `.agent/core-changes-justification.md`.

[#772]: https://github.com/recastnavigation/recastnavigation/pull/772

## [0.1.3] - 2026-06-02

### Fixed
- Detail mesh now conforms to the input surface again. `polyMinExtent` collapsed
  to ~0 — it took a plain min over all vertex/edge pairs instead of the min over
  edges of the *per-edge max* distance — so most polygons satisfied
  `minExtent < sampleDist*2` and skipped internal detail sampling, and the
  navmesh stopped following undulating terrain. Now 1:1 with `rcPolyMinExtent`;
  the `undulating.obj` sample matches the C++ reference detail mesh
  (~216 meshes / ~2800 verts / ~3200 tris, vs the buggy ~2429 / ~2441). Added a
  regression test (`detail_conformance_test`).

## [0.1.2] - 2026-06-02

### Added
- Recast: `mergePolyMeshes` (port of `rcMergePolyMeshes`); region filter/merge in
  `buildRegionsMonotone`.
- Detour: `getOffMeshConnectionByRef`; `findRandomPoint` / `findRandomPointAroundCircle`;
  byte-order (endian) swap for navmesh tile data and tile-cache headers.
- Crowd: asynchronous sliced pathfinding through the path queue (preserves
  `DT_PARTIAL_RESULT`).
- Debug: binary dump/read for `ContourSet` and `CompactHeightfield`.

### Fixed
- Demo: hard crash when building an offset convex volume (`@min` result-type narrowing
  overflowed `u4`).
- Demo: off-mesh connections and convex volumes now stay visible across tool switches
  (e.g. when switching to Crowd).

### Changed
- Demo: removed the worldspace-label backdrop.

### Docs
- Rewrote the README (English + Russian), added the GUI demo screenshot and a
  Tracy-profiling / influence-map roadmap.

## [0.1.1] - 2026-06-02

### Changed
- Release demo binaries are now built in **ReleaseFast** (faster) instead of ReleaseSafe.
  A dedicated `demo-fast` / `run-demo-fast` build target was added; the default `demo` /
  `run-demo` target stays ReleaseSafe for development. The release CI workflow now builds
  `demo-fast`. (`build.zig`, `.github/workflows/release.yml`)

## [0.1.0] - 2026-06-02

First tagged release. A pure-Zig port of Recast & Detour (recast / detour / crowd /
tilecache) for Zig 0.16, plus an interactive GUI demo (a port of RecastDemo on dvui +
GLFW/OpenGL). Prebuilt demo binaries for Windows / Linux / macOS are built natively via
GitHub Actions.

Release: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0

### Added
- **GUI demo** (`demo/`, a RecastDemo port on dvui 0.5 + zgl): solo/tile/temp-obstacle
  samples, navmesh tester, off-mesh / convex / crowd tools, voxel/contour/navmesh draw modes.
- **Crowd tool, 1:1 with `Tool_Crowd.cpp`**: option changes reapply to existing agents
  (`updateAgentParameters`), VO / neighbour / label overlays (`%.3f` distance), `SPACE`
  run/pause, `1` single-step, 4 obstacle-avoidance presets (Avoidance Quality 0–3).
- **Standalone asset resolver**: the demo locates `test_data` next to the exe / in the cwd /
  up the tree — `recast_demo` runs from any directory.
- `rcAddSpan` — public wrapper with a `smin >= smax` guard (1:1 `RecastRasterization.cpp`).
- `dtCrowd.updateAgentParameters`, `CrowdAgentDebugInfo`, `normalizeSamples` for VO debug.
- Optional `LogSink` in `Context` (routes logs to the demo Log panel).
- **Cross-platform build** (Windows / Linux / macOS × x86_64 / aarch64) and a GitHub Actions
  workflow (`.github/workflows/release.yml`) that builds native demo binaries on each OS and
  publishes them to the Release.

### Changed
- **ztracy is now optional**: a no-op stub (`demo/src/ztracy_stub.zig`) by default; the real
  ztracy is pulled in only with `-Dtracy`. The demo builds with no external dependencies
  (CI / fresh clone).
- Demo assets are installed next to the exe (`zig-out/bin/test_data`).
- CI installs Zig 0.16.0 via a direct download from `ziglang.org/download` (Zig sources moved
  to Codeberg; the old download index used by `setup-zig` no longer resolves it).
- Added `.gitattributes` (LF line-ending normalization), cleaned up dev scratch artifacts,
  removed the dead `query-diff` target from `build.zig`.

### Fixed
- **detail mesh**: `getHeight` rewritten to the upstream spiral search (pick height by
  `|nh*ch − fy|`, ring-based early-exit); `seedArrayWithPolyCenter` rewritten to a correct
  DFS-to-center; added a guard against `distToTriMesh` on an empty triangle list
  ([upstream #796]) — fixes UB on large navmeshes. (`src/recast/detail.zig`)
- **math**: `distancePtSegSqr2D` now clamps to the segment instead of measuring distance to the
  infinite line (1:1 `DetourCommon.cpp:170-184`). (`src/math.zig`)
- **`filterLedgeSpans`**: operators aligned with **upstream main** (`>=` / `<`,
  `RecastFilter.cpp:120,133`). The `>` / `<=` alternative from the open [upstream #772] was
  **not adopted** — no upstream consensus. _(corrects an earlier changelog note that claimed the
  opposite.)_ (`src/recast/filter.zig`)
- **detour(navmesh)**: poly-id bit-count guard in `addTile` — large-world support
  (1:1 `DetourNavMesh.cpp:927`). (`src/detour/navmesh.zig`)
- **crowd**: neighbour indices converted active→global (1:1 `DetourCrowd.cpp:1095`) — fixes
  corrupted separation/collision/rendering when agents have been removed. (`src/detour_crowd/crowd.zig`)
- **crowd(path_corridor)**: fixed copy direction in `mergeCorridorStartMoved/Shortcut`
  (restored `memmove` semantics — corridor-tail corruption on left shifts). (`src/detour_crowd/path_corridor.zig`)
- **recast(layers)**: fixed a usize underflow in the overlap loop and a `deinit` crash from an
  unset layer allocator. (`src/recast/layers.zig`)
- **recast(mesh)**: zero-initialize temporary buffers in `removeVertex` (determinism under the
  debug allocator). (`src/recast/mesh.zig`)
- Consistent rasterization rounding — floor instead of truncation at tile boundaries
  ([upstream #766]). (`src/recast/rasterization.zig`)

Related bug investigations: `docs/bug_fixes/github_issues/`
(ISSUE_687, ISSUE_766, ISSUE_772, ISSUE_780, ISSUE_783, ISSUE_788, ISSUE_793).

### Known divergences from upstream C++
- `crowd.updateMoveRequest` — a simplified synchronous `findPath` (no async sliced-pathfinding,
  no old/new path merge with trackback removal).
- `path_queue.getPathResult` — drops detail bits (harmless under the synchronous move-request path).

---

## Change categories

- `Added` — new functionality
- `Changed` — changes to existing functionality
- `Deprecated` — functionality to be removed soon
- `Removed` — removed functionality
- `Fixed` — bug fixes
- `Security` — vulnerability fixes

[Unreleased]: https://github.com/K4leri/recastnavigation/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.7
[0.1.6]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.6
[0.1.5]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.5
[0.1.4]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.4
[0.1.3]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.3
[0.1.2]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.2
[0.1.1]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.1
[0.1.0]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0
[upstream #772]: https://github.com/recastnavigation/recastnavigation/pull/772
[upstream #766]: https://github.com/recastnavigation/recastnavigation/pull/766
[upstream #796]: https://github.com/recastnavigation/recastnavigation/pull/796
