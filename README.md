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

Add the dependency to your `build.zig.zon` and import the module:

```zig
const recast = @import("recast-nav");

var ctx = recast.Context.init(allocator);

var config = recast.RecastConfig{
    .cs = 0.3,
    .ch = 0.2,
    .walkable_slope_angle = 45.0,
    .walkable_height = 20,
    .walkable_climb = 9,
    .walkable_radius = 8,
    .max_edge_len = 12,
    .max_simplification_error = 1.3,
    .min_region_area = 8,
    .merge_region_area = 20,
    .max_verts_per_poly = 6,
    .detail_sample_dist = 6.0,
    .detail_sample_max_error = 1.0,
    .bmin = recast.Vec3.init(0, 0, 0),
    .bmax = recast.Vec3.init(100, 10, 100),
};

// ... rasterize triangles, filter, build regions/contours/mesh,
//     then create Detour navmesh data and query it.
```

Runnable, end-to-end examples live in `examples/`:

- `simple_navmesh.zig` — bake a navmesh from a box.
- `pathfinding_demo.zig` — find and follow a path.
- `crowd_simulation.zig` — drive several agents to a goal.
- `dynamic_obstacles.zig` — tile cache + run-time obstacles.

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
