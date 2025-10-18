# Recast Pipeline

Детальный разбор процесса построения Navigation Mesh через Recast pipeline.

---

## Overview

Recast pipeline преобразует triangle mesh в navigation mesh через серию этапов:

```
Input Mesh → Heightfield → Compact → Regions → Contours → PolyMesh → DetailMesh
```

Каждый этап решает конкретную задачу и передает данные следующему этапу.

---

## Pipeline Stages

### Stage 1: Rasterization (Triangle Mesh → Heightfield)

**Цель:** Преобразовать triangle mesh в voxel heightfield

**Процесс:**
```zig
// 1. Create heightfield
var heightfield = try Heightfield.init(
    allocator,
    width, height,  // grid dimensions
    &bmin, &bmax,   // bounds
    cs, ch,         // cell size, cell height
);

// 2. Mark walkable triangles
const areas = try allocator.alloc(u8, tri_count);
markWalkableTriangles(ctx, slope_angle, verts, indices, areas);

// 3. Rasterize triangles into heightfield
try rasterizeTriangles(ctx, verts, indices, areas, &heightfield, walkable_climb);
```

**Что происходит:**
1. **Grid creation** - создается 2D grid (width × height)
2. **Triangle projection** - каждый triangle проецируется на grid
3. **Span creation** - для каждой grid cell создаются spans (voxel columns)
4. **Height recording** - записываются min/max высоты для каждого span

**Структура Heightfield:**
```zig
pub const Heightfield = struct {
    width: u32,          // Grid width
    height: u32,         // Grid height
    bmin: [3]f32,        // Bounds min
    bmax: [3]f32,        // Bounds max
    cs: f32,             // Cell size (XZ plane)
    ch: f32,             // Cell height (Y axis)
    spans: []?*Span,     // Span lists for each cell
};

pub const Span = struct {
    smin: u32,           // Min height
    smax: u32,           // Max height
    area: u8,            // Area type
    next: ?*Span,        // Next span in column
};
```

**Пример:**
```
Input:
  Triangle at Y=0 to Y=5
  Cell size = 0.3

Output:
  Span: smin=0 (0*0.2), smax=25 (5/0.2)
  Area: WALKABLE_AREA (63)
```

---

### Stage 2: Filtering

**Цель:** Удалить non-walkable obstacles и features

**Три фильтра:**

#### 2.1 Filter Low Hanging Obstacles
```zig
filterLowHangingWalkableObstacles(ctx, walkable_climb, &heightfield);
```
- Находит obstacles ниже walkable_climb
- Помечает их как walkable (если достаточно низкие)

#### 2.2 Filter Ledge Spans
```zig
filterLedgeSpans(ctx, walkable_height, walkable_climb, &heightfield);
```
- Обнаруживает ledges (края обрывов)
- Помечает spans на краях как unwalkable

#### 2.3 Filter Low Height Spans
```zig
filterWalkableLowHeightSpans(ctx, walkable_height, &heightfield);
```
- Находит spans с низким потолком
- Помечает их как unwalkable (нельзя пройти)

**Результат:** Все unwalkable spans помечены area=NULL_AREA (0)

---

### Stage 3: Compaction (Heightfield → Compact Heightfield)

**Цель:** Сжать heightfield и построить neighbor connectivity

**Процесс:**
```zig
var compact = try buildCompactHeightfield(
    ctx,
    allocator,
    walkable_height,
    walkable_climb,
    &heightfield,
);
```

**Что происходит:**
1. **Filter spans** - удаляются NULL_AREA spans
2. **Build connectivity** - для каждого span строятся connections к соседям
3. **Compaction** - spans упаковываются в linear array

**Структура Compact Heightfield:**
```zig
pub const CompactHeightfield = struct {
    width: u32,
    height: u32,
    span_count: u32,
    walkable_height: u32,
    walkable_climb: u32,
    max_distance: u32,
    max_regions: u32,
    bmin: [3]f32,
    bmax: [3]f32,
    cs: f32,
    ch: f32,
    cells: []CompactCell,    // Grid cells
    spans: []CompactSpan,    // All spans (linear)
    areas: []u8,             // Area IDs
};

pub const CompactSpan = struct {
    y: u16,         // Height
    reg: u16,       // Region ID
    con: u32,       // Connections (4 directions)
    h: u8,          // Height above floor
};
```

**Connections encoding:**
```
con: u32 = [dir3:8][dir2:8][dir1:8][dir0:8]
  dir0 = West  (-X)
  dir1 = North (+Z)
  dir2 = East  (+X)
  dir3 = South (-Z)

Value: neighbor span index или NOT_CONNECTED (0x3F = 63)
```

---

### Stage 4: Distance Field & Regions

**Цель:** Разделить walkable area на regions

#### 4.1 Build Distance Field
```zig
try buildDistanceField(ctx, &compact);
```

**Алгоритм:**
1. **Mark boundaries** - spans с <4 neighbors получают dist=0
2. **Pass 1 (forward)** - propagate distances вперед (top-left → bottom-right)
3. **Pass 2 (backward)** - propagate distances назад (bottom-right → top-left)

**Distance formula:**
- Cardinal direction: `dist[neighbor] + 2`
- Diagonal direction: `dist[neighbor] + 3`

**Результат:** `compact.max_distance` содержит максимальное расстояние

#### 4.2 Build Regions (Watershed)
```zig
try buildRegions(ctx, allocator, &compact, min_region_area, merge_region_area);
```

**Watershed Algorithm:**
1. **Erosion** - удаляем boundary spans (dist < min_boundary_dist)
2. **Expand regions** - flood-fill от highest distance spans
3. **Merge small regions** - объединяем regions < min_region_area

**Multi-Stack System:**
```zig
var stacks: [256]std.ArrayList(u32) = undefined;  // One stack per distance level

// Process from highest to lowest distance
var level = max_distance;
while (level > 0) : (level -= 1) {
    // Process all spans at this distance level
    for (stacks[level].items) |span_idx| {
        // Expand region...
    }
}
```

**Результат:** Каждому span присвоен region ID

---

### Stage 5: Contour Extraction

**Цель:** Извлечь контуры каждого region

```zig
var contour_set = try buildContours(
    ctx,
    allocator,
    &compact,
    max_simplification_error,
    max_edge_len,
);
```

**Процесс:**

#### 5.1 Walk Contour
```zig
// For each region
for (0..max_regions) |reg_id| {
    // Find starting span
    const start_span = findStartSpan(reg_id);

    // Walk clockwise around boundary
    var verts = ArrayList([4]i32).init(allocator);
    walkContour(start_span, &verts);
}
```

**Walk правила:**
- Start from leftmost span
- Walk clockwise
- Record corner positions (x, y, z, region_connection)

#### 5.2 Simplify Contour (Douglas-Peucker)
```zig
simplifyContour(&raw_verts, &simplified_verts, max_error);
```

**Douglas-Peucker algorithm:**
1. Проводим line от first vertex к last vertex
2. Находим vertex с max perpendicular distance
3. Если distance > threshold, split и recurse
4. Иначе, удаляем intermediate vertices

#### 5.3 Remove Degenerate Segments
```zig
removeDegenerateSegments(&verts);
```

**Удаляются:**
- Zero-length edges
- Collinear vertices
- Self-intersecting segments

**Результат:** Упрощенные контуры для каждого region

---

### Stage 6: Polygon Mesh

**Цель:** Построить polygon mesh из contours

```zig
var poly_mesh = try buildPolyMesh(
    ctx,
    allocator,
    &contour_set,
    max_verts_per_poly,
);
```

**Процесс:**

#### 6.1 Triangulate Contours
```zig
// For each contour
for (contours) |contour| {
    // Ear clipping triangulation
    const tris = triangulate(contour.verts);

    // Add triangles to mesh
    for (tris) |tri| {
        addTriangle(&poly_mesh, tri);
    }
}
```

**Ear Clipping:**
1. Find "ear" triangle (vertex + 2 neighbors, no vertices inside)
2. Cut ear, add to mesh
3. Repeat until done

#### 6.2 Merge Polygons
```zig
// Merge triangles into larger polygons
mergePolygons(&poly_mesh, max_verts_per_poly);
```

**Merging rules:**
- Share an edge
- Convex result
- Total vertices ≤ max_verts_per_poly

**Структура PolyMesh:**
```zig
pub const PolyMesh = struct {
    verts: []u16,           // Vertices (x,y,z interleaved)
    polys: []u16,           // Polygons (vertex indices)
    regs: []u16,            // Region IDs
    flags: []u16,           // Flags
    areas: []u8,            // Area types
    vert_count: u32,
    poly_count: u32,
    nvp: u32,               // Max verts per poly
    bmin: [3]f32,
    bmax: [3]f32,
    cs: f32,
    ch: f32,
};
```

---

### Stage 7: Detail Mesh

**Цель:** Добавить height detail для accurate queries

```zig
var detail_mesh = try buildPolyMeshDetail(
    ctx,
    allocator,
    &poly_mesh,
    &compact,
    sample_dist,
    sample_max_error,
);
```

**Процесс:**

#### 7.1 Sample Heights
```zig
// For each polygon
for (polys) |poly| {
    // Sample height at regular intervals
    const samples = sampleHeights(poly, &compact, sample_dist);

    // Add detail vertices
    for (samples) |sample| {
        addDetailVertex(&detail_mesh, sample);
    }
}
```

#### 7.2 Delaunay Triangulation
```zig
// Triangulate sampled points
const tris = delaunayHull(detail_verts);
```

**Delaunay properties:**
- No point inside circumcircle of any triangle
- Maximizes minimum angle

**Структура DetailMesh:**
```zig
pub const PolyMeshDetail = struct {
    meshes: []u32,      // [base_vert, vert_count, base_tri, tri_count] per poly
    verts: []f32,       // Vertices (x,y,z)
    tris: []u8,         // Triangles (indices + flags)
    mesh_count: u32,
    vert_count: u32,
    tri_count: u32,
};
```

---

## Configuration Parameters

### Grid Resolution
```zig
cs: f32 = 0.3,  // Cell size (XZ plane)
ch: f32 = 0.2,  // Cell height (Y axis)
```
- **Меньше** → больше деталей, больше памяти
- **Больше** → меньше деталей, меньше памяти

### Agent Parameters
```zig
walkable_height: u32 = 20,      // Min ceiling height (cells)
walkable_climb: u32 = 9,         // Max step height (cells)
walkable_radius: u32 = 8,        // Agent radius (cells)
walkable_slope_angle: f32 = 45.0, // Max slope (degrees)
```

### Region Parameters
```zig
min_region_area: u32 = 8,       // Min region size (cells²)
merge_region_area: u32 = 20,    // Merge threshold (cells²)
```

### Polygon Parameters
```zig
max_edge_len: u32 = 12,                // Max edge length (cells)
max_simplification_error: f32 = 1.3,   // Simplification tolerance
max_verts_per_poly: u32 = 6,           // Max vertices per polygon
```

### Detail Parameters
```zig
detail_sample_dist: f32 = 6.0,         // Sample spacing
detail_sample_max_error: f32 = 1.0,    // Max height error
```

---

## Performance Characteristics

### Time Complexity

| Stage | Complexity | Dominant Factor |
|-------|------------|-----------------|
| Rasterization | O(T × G) | T=triangles, G=grid cells per tri |
| Filtering | O(S) | S=spans |
| Compaction | O(S) | S=spans |
| Distance Field | O(S) | S=spans, 2 passes |
| Regions (Watershed) | O(S × log D) | D=max distance |
| Contours | O(R × V) | R=regions, V=verts per contour |
| PolyMesh | O(V + P) | V=verts, P=polygons |
| DetailMesh | O(P × D²) | P=polygons, D=samples per poly |

### Memory Usage

| Structure | Size | Formula |
|-----------|------|---------|
| Heightfield | ~1-5 MB | width × height × avg_spans × 32 bytes |
| Compact HF | ~500 KB - 2 MB | span_count × 16 bytes |
| ContourSet | ~100-500 KB | regions × verts_per_contour × 16 bytes |
| PolyMesh | ~50-200 KB | poly_count × nvp × 2 bytes |
| DetailMesh | ~100 KB - 1 MB | detail_tri_count × 12 bytes |

---

## Best Practices

### 1. Choose Appropriate Cell Size

```zig
// Rule of thumb: cs = agent_radius / 2
const agent_radius = 0.6;  // meters
const cs = agent_radius / 2.0;  // 0.3 meters
```

### 2. Balance Detail vs Performance

```zig
// High detail (slow, accurate)
cs = 0.1, ch = 0.05

// Medium detail (balanced)
cs = 0.3, ch = 0.2

// Low detail (fast, coarse)
cs = 0.5, ch = 0.4
```

### 3. Adjust Region Parameters

```zig
// Small environments
min_region_area = 8
merge_region_area = 20

// Large open areas
min_region_area = 64
merge_region_area = 200
```

---

## Debugging Tips

### Visualize Intermediate Results

```zig
// After each stage, log statistics
std.debug.print("Heightfield: {} spans\n", .{countSpans(&heightfield)});
std.debug.print("Compact: {} spans\n", .{compact.span_count});
std.debug.print("Regions: {} regions\n", .{countRegions(&compact)});
std.debug.print("Contours: {} contours\n", .{contour_set.contours.len});
std.debug.print("PolyMesh: {} polys\n", .{poly_mesh.poly_count});
```

### Common Issues

**Too many/few regions:**
- Adjust `min_region_area` and `merge_region_area`

**Jagged contours:**
- Increase `max_simplification_error`

**Missing walkable areas:**
- Check `walkable_slope_angle` and `walkable_height`

**Large polygons:**
- Decrease `max_edge_len` or `max_verts_per_poly`

---

## Next Steps

- 📖 [Detour Pipeline](detour-pipeline.md) - pathfinding и queries
- 💾 [Memory Model](memory-model.md) - управление памятью
- 🔍 [Creating NavMesh Guide](../04-guides/creating-navmesh.md) - практическое руководство

---

## References

- [Recast Paper](http://digestingduck.blogspot.com/2009/03/recast-navigation-mesh-generation.html)
- [Watershed Algorithm](https://en.wikipedia.org/wiki/Watershed_(image_processing))
- [Douglas-Peucker](https://en.wikipedia.org/wiki/Ramer%E2%80%93Douglas%E2%80%93Peucker_algorithm)
