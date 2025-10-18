# TileCache

Dynamic obstacles и incremental NavMesh rebuilding.

---

## Overview

TileCache обеспечивает поддержку динамических препятствий на NavMesh:
- **Dynamic obstacles** - cylinder, box, oriented box
- **Incremental rebuilding** - обновление только affected tiles
- **Tile compression** - экономия памяти
- **Async updates** - постепенное обновление NavMesh

```
Add Obstacle → Mark Affected Tiles → Rebuild Queue → Update NavMesh
```

**Use cases:**
- Динамические двери и препятствия
- Разрушаемые объекты
- Временные блокировки
- Изменяемая среда

---

## TileCache

Основной manager для dynamic obstacles.

### Structure

```zig
pub const TileCache = struct {
    allocator: Allocator,
    params: TileCacheParams,

    // Tiles
    tiles: []CompressedTile,
    pos_lookup: []?*CompressedTile,
    next_free_tile: ?*CompressedTile,
    tile_count: i32,

    // Obstacles
    obstacles: []TileCacheObstacle,
    next_free_obstacle: ?*TileCacheObstacle,

    // Updates
    update: [MAX_UPDATE]CompressedTileRef,
    nupdate: i32,

    // Requests
    requests: [MAX_REQUESTS]ObstacleRequest,
    nrequest: i32,

    // NavMesh
    navmesh: *NavMesh,

    // Compressor
    tcomp: ?TileCacheCompressor,

    // Mesh processor
    tmproc: ?TileCacheMeshProcess,

    pub fn init(
        allocator: Allocator,
        params: *const TileCacheParams,
        nav: *NavMesh,
    ) !*TileCache

    pub fn deinit(self: *TileCache) void
};
```

### Parameters

```zig
pub const TileCacheParams = struct {
    orig: [3]f32,                    // Origin
    cs: f32,                         // Cell size
    ch: f32,                         // Cell height
    width: i32,                      // Tile width (cells)
    height: i32,                     // Tile height (cells)
    walkable_height: f32,            // Agent height
    walkable_radius: f32,            // Agent radius
    walkable_climb: f32,             // Agent max climb
    max_simplification_error: f32,   // Contour simplification
    max_tiles: i32,                  // Max tile count
    max_obstacles: i32,              // Max obstacle count
};
```

---

## Obstacles

Динамические препятствия трех типов.

### Types

```zig
pub const ObstacleType = enum(u8) {
    cylinder,
    box,              // Axis-aligned bounding box
    oriented_box,     // Oriented bounding box
};

pub const TileCacheObstacle = struct {
    shape: union(ObstacleType) {
        cylinder: ObstacleCylinder,
        box: ObstacleBox,
        oriented_box: ObstacleOrientedBox,
    },

    touched: [MAX_TOUCHED_TILES]CompressedTileRef,
    pending: [MAX_TOUCHED_TILES]CompressedTileRef,
    salt: u16,
    state: ObstacleState,
    ntouched: u8,
    npending: u8,
    next: ?*TileCacheObstacle,
};
```

### Obstacle Shapes

```zig
// Cylinder
pub const ObstacleCylinder = struct {
    pos: [3]f32,      // Center position
    radius: f32,      // Radius
    height: f32,      // Height
};

// Axis-aligned box
pub const ObstacleBox = struct {
    bmin: [3]f32,     // Min bounds
    bmax: [3]f32,     // Max bounds
};

// Oriented box
pub const ObstacleOrientedBox = struct {
    center: [3]f32,
    half_extents: [3]f32,
    rot_aux: [2]f32,  // Rotation (cos/sin encoding)
};
```

### States

```zig
pub const ObstacleState = enum(u8) {
    empty,            // Not in use
    processing,       // Being added
    processed,        // Active obstacle
    removing,         // Being removed
};
```

---

## Operations

### Add Tile

```zig
// Add compressed tile to cache
pub fn addTile(
    self: *TileCache,
    data: []const u8,
    flags: CompressedTileFlags,
    result: *CompressedTileRef,
) !Status

// Remove tile
pub fn removeTile(
    self: *TileCache,
    ref: CompressedTileRef,
    data: *[]u8,
    data_size: *i32,
) !Status
```

### Add Obstacles

```zig
// Add cylinder obstacle
pub fn addObstacle(
    self: *TileCache,
    pos: *const [3]f32,
    radius: f32,
    height: f32,
    result: *ObstacleRef,
) !Status

// Add box obstacle
pub fn addBoxObstacle(
    self: *TileCache,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    result: *ObstacleRef,
) !Status

// Add oriented box obstacle
pub fn addBoxObstacleOriented(
    self: *TileCache,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    yRadians: f32,
    result: *ObstacleRef,
) !Status

// Remove obstacle
pub fn removeObstacle(self: *TileCache, ref: ObstacleRef) !Status
```

### Update

```zig
// Update tile cache (process obstacle changes)
pub fn update(
    self: *TileCache,
    dt: f32,
    navmesh: *NavMesh,
    upToDate: ?*bool,
) !Status

// Build NavMesh tile from compressed data
pub fn buildNavMeshTile(
    self: *TileCache,
    ref: CompressedTileRef,
    navmesh: *NavMesh,
) !Status

// Build all NavMesh tiles
pub fn buildNavMeshTilesAt(
    self: *TileCache,
    tx: i32,
    ty: i32,
    navmesh: *NavMesh,
) !Status
```

### Queries

```zig
// Get obstacle by reference
pub fn getObstacleByRef(
    self: *TileCache,
    ref: ObstacleRef,
) ?*const TileCacheObstacle

// Query obstacles in bounds
pub fn queryTiles(
    self: *const TileCache,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    results: []CompressedTileRef,
    result_count: *i32,
) !Status

// Get tiles at grid location
pub fn getTilesAt(
    self: *const TileCache,
    tx: i32,
    ty: i32,
    tiles: []CompressedTileRef,
    max_tiles: i32,
) i32
```

---

## Tile Compression

Сжатие tile data для экономии памяти.

### Compressor Interface

```zig
pub const TileCacheCompressor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        compress: *const fn (
            ptr: *anyopaque,
            buffer: []const u8,
            compressed: []u8,
            max_compressed_size: i32,
            compressed_size: *i32,
        ) i32,

        decompress: *const fn (
            ptr: *anyopaque,
            compressed: []const u8,
            compressed_size: i32,
            buffer: []u8,
            max_buffer_size: i32,
            buffer_size: *i32,
        ) i32,
    };

    pub fn compress(
        self: *TileCacheCompressor,
        buffer: []const u8,
        compressed: []u8,
        max_compressed_size: i32,
        compressed_size: *i32,
    ) i32

    pub fn decompress(
        self: *TileCacheCompressor,
        compressed: []const u8,
        compressed_size: i32,
        buffer: []u8,
        max_buffer_size: i32,
        buffer_size: *i32,
    ) i32
};
```

---

## Mesh Processing

Callback для модификации mesh перед созданием NavMesh tile.

```zig
pub const TileCacheMeshProcess = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (
            ptr: *anyopaque,
            params: *anyopaque,  // NavMeshCreateParams
            poly_areas: []u8,
            poly_flags: []u16,
        ) void,
    };

    pub fn process(
        self: *TileCacheMeshProcess,
        params: *anyopaque,
        poly_areas: []u8,
        poly_flags: []u16,
    ) void
};
```

---

## Complete Example

### Basic Usage

```zig
const std = @import("std");
const nav = @import("zig-recast");

pub fn tileCacheExample(
    allocator: Allocator,
    navmesh: *nav.detour.NavMesh,
) !void {
    // 1. Configure TileCache
    const tc_params = nav.detour_tilecache.TileCacheParams{
        .orig = .{ 0, 0, 0 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 48,
        .height = 48,
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .max_simplification_error = 1.3,
        .max_tiles = 256,
        .max_obstacles = 128,
    };

    // 2. Create TileCache
    var tc = try nav.detour_tilecache.TileCache.init(
        allocator,
        &tc_params,
        navmesh,
    );
    defer tc.deinit();

    // 3. Add tiles (from pre-built data)
    // var tile_data = ...; // Compressed tile data
    // var tile_ref: nav.detour_tilecache.CompressedTileRef = undefined;
    // _ = try tc.addTile(tile_data, .{}, &tile_ref);

    // 4. Add dynamic obstacle (cylinder)
    var obs_ref: nav.detour_tilecache.ObstacleRef = undefined;
    const obs_pos = [3]f32{ 5.0, 0.0, 5.0 };

    _ = try tc.addObstacle(
        &obs_pos,
        1.0,    // radius
        2.0,    // height
        &obs_ref,
    );

    std.debug.print("Obstacle added: {d}\n", .{obs_ref});

    // 5. Update TileCache (rebuilds affected tiles)
    var up_to_date: bool = false;

    while (!up_to_date) {
        _ = try tc.update(0.0, navmesh, &up_to_date);
    }

    std.debug.print("NavMesh updated\n", .{});

    // 6. Remove obstacle
    _ = try tc.removeObstacle(obs_ref);

    // 7. Update again
    up_to_date = false;
    while (!up_to_date) {
        _ = try tc.update(0.0, navmesh, &up_to_date);
    }

    std.debug.print("Obstacle removed, NavMesh updated\n", .{});
}
```

### Custom Mesh Processor

```zig
const CustomMeshProcessor = struct {
    pub fn process(
        ptr: *anyopaque,
        params_ptr: *anyopaque,
        poly_areas: []u8,
        poly_flags: []u16,
    ) void {
        _ = ptr;
        _ = params_ptr;

        // Mark all polygons as walkable
        for (poly_areas, 0..) |*area, i| {
            area.* = 0;  // WALKABLE_AREA
            poly_flags[i] = 0x01;  // WALK flag
        }
    }

    pub fn asMeshProcess(self: *CustomMeshProcessor) nav.detour_tilecache.TileCacheMeshProcess {
        return .{
            .ptr = self,
            .vtable = &.{
                .process = process,
            },
        };
    }
};

// Usage
var processor = CustomMeshProcessor{};
var mesh_proc = processor.asMeshProcess();

// Set in TileCache
tc.tmproc = mesh_proc;
```

---

## Update Loop

TileCache update происходит постепенно:

```zig
pub fn update(self: *TileCache, dt: f32, navmesh: *NavMesh, upToDate: ?*bool) !Status {
    // 1. Process obstacle requests (add/remove)
    processRequests();

    // 2. Process obstacles (mark affected tiles)
    processObstacles();

    // 3. Build NavMesh tiles (limited per frame)
    const max_updates_per_frame = 4;
    var updates_done: i32 = 0;

    while (updates_done < max_updates_per_frame and self.nupdate > 0) {
        const tile_ref = self.update[0];

        // Rebuild tile
        try self.buildNavMeshTile(tile_ref, navmesh);

        // Remove from queue
        self.nupdate -= 1;
        for (0..@intCast(self.nupdate)) |i| {
            self.update[i] = self.update[i + 1];
        }

        updates_done += 1;
    }

    // Check if all updates done
    if (upToDate) |ptr| {
        ptr.* = (self.nupdate == 0);
    }

    return Status.ok();
}
```

---

## Performance

### Memory

```zig
// Uncompressed tile: ~50-200 KB
// Compressed tile: ~10-50 KB (with compression)
// Obstacle: ~100 bytes
```

### Update Cost

- **Add obstacle**: O(1) - только mark affected tiles
- **Rebuild tile**: O(T) - где T = tile build time (~1-5ms)
- **Max updates per frame**: Ограничен для избежания frame drops

### Recommendations

```zig
// Max obstacles per second
const max_add_per_sec = 10;

// Update budget per frame
const max_rebuilds_per_frame = 4;  // ~4-20ms budget

// Compression ratio
// Typically 2-5x smaller with basic compression
```

---

## Best Practices

### 1. Batch Obstacle Changes

```zig
// GOOD - batch adds
for (obstacle_positions) |pos| {
    _ = try tc.addObstacle(&pos, radius, height, &ref);
}
// Then update once
while (!up_to_date) {
    _ = try tc.update(dt, navmesh, &up_to_date);
}

// BAD - update after each add
for (obstacle_positions) |pos| {
    _ = try tc.addObstacle(&pos, radius, height, &ref);
    while (!up_to_date) {
        _ = try tc.update(dt, navmesh, &up_to_date);  // Expensive!
    }
}
```

### 2. Use Appropriate Obstacle Types

```zig
// Cylinder - для круглых препятствий (columns, trees)
_ = try tc.addObstacle(&pos, radius, height, &ref);

// Box - для прямоугольных (crates, walls)
_ = try tc.addBoxObstacle(&bmin, &bmax, &ref);

// Oriented box - для rotated objects (rare, more expensive)
_ = try tc.addBoxObstacleOriented(&center, &half_extents, rotation, &ref);
```

### 3. Update Budget

```zig
// Spread updates across frames
var updates_this_frame: i32 = 0;
const max_updates = 4;

while (updates_this_frame < max_updates and !up_to_date) {
    const status = try tc.update(dt, navmesh, &up_to_date);
    if (status.isSuccess()) {
        updates_this_frame += 1;
    }
}
```

---

## Constants

```zig
pub const MAX_TOUCHED_TILES: usize = 8;
const MAX_REQUESTS: usize = 64;
const MAX_UPDATE: usize = 64;
```

---

## See Also

- 📖 [Detour API](../03-api-reference/detour-api.md)
- 🏗️ [Detour Pipeline](detour-pipeline.md)
- 🏗️ [Recast Pipeline](recast-pipeline.md)
