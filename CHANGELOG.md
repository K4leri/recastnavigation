# Changelog

All notable changes to zig-recast are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

_No unreleased changes._

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

[Unreleased]: https://github.com/K4leri/recastnavigation/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.5
[0.1.4]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.4
[0.1.3]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.3
[0.1.2]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.2
[0.1.1]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.1
[0.1.0]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0
[upstream #772]: https://github.com/recastnavigation/recastnavigation/pull/772
[upstream #766]: https://github.com/recastnavigation/recastnavigation/pull/766
[upstream #796]: https://github.com/recastnavigation/recastnavigation/pull/796
