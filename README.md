# zig-recast

A Zig port of the [Recast & Detour](https://github.com/recastnavigation/recastnavigation)
navigation-mesh toolkit — navmesh baking, pathfinding, crowd simulation, and a
tile cache for dynamic obstacles.

English | [Русский](README.ru.md)

![zig-recast demo](docs/recast_demo.png)

The screenshot above is the bundled GUI demo (`zig build run-demo`), a Zig/dvui
rebuild of the original RecastDemo tools.

## What this is

The code follows the upstream C++ structure closely — file-for-file and, where
it matters, line-for-line — so it can be checked against the reference and track
its updates. The port keeps the original `i32` core fields and data layout for
fidelity, and adds Zig conventions on top: explicit allocators, error unions
instead of boolean returns, and `defer`-based cleanup.

It is an active port (version `0.1.x`), not a finished 1.0. The core pipelines
work and are covered by tests, but some upstream corners are deliberately
simplified or still being filled in — see [Status](#status).

## Modules

| Module | Purpose |
| --- | --- |
| `recast` | Build a navmesh from triangle soup: heightfield → compact heightfield → regions → contours → poly mesh → detail mesh. |
| `detour` | Runtime navmesh + queries: A\* and sliced pathfinding, string-pulling, raycast, nearest-poly, random points, wall distance. |
| `detour_crowd` | Multi-agent steering: path corridors, local boundary, obstacle avoidance, async replanning through a path queue. |
| `detour_tilecache` | Compressed tiles with run-time obstacles (box / cylinder / oriented box) and incremental navmesh rebuilds. |
| `debug` | Debug-draw primitives and binary dump/read of intermediate structures (used by the demo). |

## Requirements

- **Zig 0.16.0** (the demo dependency `dvui` requires it; the library itself is
  plain Zig). Earlier 0.15.x will not build.

## Build & test

```bash
zig build                 # build the library
zig build test            # unit + integration tests
zig build test-integration

zig build examples        # build the example executables
zig build bench-recast    # benchmarks: -recast / -detour / -crowd
```

## Run the demo

A dvui GUI (GLFW + OpenGL) that loads geometry, bakes a navmesh, and exposes the
RecastDemo tools — NavMesh Tester, Crowd, Tile, and the debug overlays.

```bash
zig build run-demo
```

## Library usage

Add the dependency to your `build.zig.zon` and import the module. The build
pipeline is namespaced — the `recast` half (alias it `rc`) bakes a mesh, the
`detour` half (alias it `dt`) queries it; the common types (`Vec3`, `Context`,
`RecastConfig`, `Heightfield`, …) are re-exported at the root. The build functions
sit under file-namespaces (`rc.rasterization`, `rc.filter`, `rc.region`, …) that
mirror the upstream C++ source files. Sketch of the flow (declarations elided —
see the example below for the complete, compiling code):

```zig
const nav = @import("recast-nav");
const rc = nav.recast; // Recast: build the mesh
const dt = nav.detour; // Detour: query it

var ctx = nav.Context.init(allocator);

// 1. Bake: triangles -> heightfield -> compact -> regions -> contours -> mesh.
//    `verts` is flat []f32 xyz, `indices` is []i32. Filters return void; the
//    build steps fill structs you init'd (Heightfield/CompactHeightfield/...).
try rc.rasterization.rasterizeTriangles(&ctx, verts, indices, areas, &hf, cfg.walkable_climb);
rc.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
try rc.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
try rc.region.buildRegions(&ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, allocator);
try rc.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, 0, allocator);
try rc.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

// 2. Hand the mesh to Detour, then query it.
const data = try dt.createNavMeshData(&create_params, allocator);
var navmesh = try dt.NavMesh.init(allocator, nav_params);
_ = try navmesh.addTile(data, .{ .free_data = false }, 0);

const query = try dt.NavMeshQuery.init(allocator);
try query.initQuery(&navmesh, 2048);
_ = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path, &path_count);
```

The full version of the above — every step, allocation, and error path — is
`examples/03_full_pathfinding.zig`. Run it with `zig build run-example`.

## Examples

Every example builds **and runs** in CI (`zig build examples` builds all,
`zig build run-<name>` runs one). They are the living, executable reference for
the API:

| Example | Demonstrates |
|---|---|
| `03_full_pathfinding` | complete bake → navmesh → `findPath`/`findStraightPath` |
| `simple_navmesh` | the minimal bake (triangles → navmesh data) |
| `pathfinding_demo` | query suite: nearest poly, path, raycast, area & wall queries |
| `02_tiled_navmesh` | two stitched tiles, a path crossing the tile border |
| `06_offmesh_connections` | an off-mesh link (jump/teleport) bridging disconnected areas |
| `crowd_simulation` | DetourCrowd steering several agents to a shared goal |
| `dynamic_obstacles` | DetourTileCache run-time obstacles re-routing a path |
| `advanced/custom_areas` | custom area types + per-area query cost |
| `advanced/hierarchical_pathfinding` | sliced/incremental pathfinding across frames |
| `advanced/streaming_world` | tiles streamed in/out as an agent moves |

## Differences from the C++ version

- **Memory** — every builder takes an explicit `std.mem.Allocator`; there is no
  global allocator. Structures own their buffers and free them in `deinit`.
- **Errors** — fallible operations return Zig error unions (`!T`) instead of
  `bool` + out-params.
- **Types** — core recast/detour fields stay `i32` to mirror the C++ layout
  (many are signed sentinels); `usize` getters are layered on top for clean Zig
  call sites.

## Status

The Recast bake, Detour queries, crowd, and tile cache pipelines are
implemented and exercised by the unit and integration suites (`zig build test`,
currently green). Known, deliberate deviations from upstream are tracked in
`.agent/core-changes-justification.md` — for example the ledge-span comparison
follows current upstream `main` (disputed by an open upstream PR), and a few
serialization/endian helpers exist mainly for completeness.

## Roadmap

Correctness and fidelity come first; performance work is next, and it is
**measurement-driven** rather than guesswork:

- **Profile with Tracy** — instrument the Recast bake, Detour queries, and the
  crowd update with Tracy zones and capture traces over representative scenes
  (the `bench/` scenario harness is being built for exactly this).
- **Then optimize the hot spots the traces actually show**, likely candidates:
  - SIMD (`@Vector`) for the hot vector / geometry math.
  - Fewer allocations on the pathfinding hot path (reuse node pools / scratch
    buffers).
  - `comptime` specialization where it removes branching.
  - Cache-friendlier data layout for the rasterization / region passes if they
    dominate a trace.

Each item lands only if a Tracy trace shows it is worth it.

Beyond the 1:1 port, one optional module is on the radar:

- **Influence maps (`DetourInfluence`)** — a tactical layer over the navmesh
  (threat / visibility / territory fields with temporal decay and
  "find the safest spot" queries), in the spirit of the upstream proposal
  ([discussion #794](https://github.com/recastnavigation/recastnavigation/discussions/794)).
  An independent, opt-in module like DetourCrowd — only once the core port is
  solid.

## Layout

```
src/
  math.zig            vectors, geometry helpers
  context.zig         build context + logging sink
  recast/             navmesh baking pipeline
  detour/             navmesh runtime + queries + builder
  detour_crowd/       crowd, corridor, avoidance, path queue
  detour_tilecache/   tile cache + obstacles
  debug/              debug-draw + dump
examples/             runnable usage examples
bench/                benchmarks
demo/                 dvui GUI demo (zig build run-demo)
test/                 unit + integration tests
```

## License

zlib, the same as upstream RecastNavigation. See [LICENSE](LICENSE).

Original C++ Recast & Detour © Mikko Mononen. This is an independent Zig port.

## Links

- [RecastNavigation](https://github.com/recastnavigation/recastnavigation) — the C++ reference
- [Zig](https://ziglang.org/)
