# Changelog

All notable changes to zig-recast are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

_No unreleased changes._

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

[Unreleased]: https://github.com/K4leri/recastnavigation/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.1
[0.1.0]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0
[upstream #772]: https://github.com/recastnavigation/recastnavigation/pull/772
[upstream #766]: https://github.com/recastnavigation/recastnavigation/pull/766
[upstream #796]: https://github.com/recastnavigation/recastnavigation/pull/796
