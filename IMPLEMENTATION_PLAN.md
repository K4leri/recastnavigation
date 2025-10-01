# 🚀 RecastNavigation Zig - Полный План Реализации

## 📊 Статистика проекта

**Оригинальная библиотека:**
- **21,704** строк основного кода (C++)
- **6** основных модулей
- **50+** файлов исходного кода
- **7** тестовых файлов
- **Примеры:** RecastDemo с GUI

**Текущий прогресс:**
- ✅ **1,709** строк Zig (7.5%)
- ✅ Структуры данных
- ✅ Система сборки
- ❌ Алгоритмы построения
- ❌ Алгоритмы навигации
- ❌ Тесты
- ❌ Примеры

---

# 🎯 ФАЗА 0: Фундамент (ЗАВЕРШЕНА) ✅

## 0.1 Инфраструктура ✅
- [x] `build.zig` - система сборки
- [x] `src/root.zig` - точка входа
- [x] `README.md` - документация
- [x] `LICENSE` - лицензия
- [x] `.gitignore` - игнорирование файлов

## 0.2 Математика ✅
**Файл:** `src/math.zig`
- [x] `Vec3` - 3D векторы
- [x] `Vec2` - 2D векторы
- [x] `AABB` - ограничивающие объёмы
- [x] Утилиты: min, max, abs, sqr, clamp
- [x] Геометрия: triArea2D, closestPtPointTriangle, pointInPolygon
- [x] Битовые операции: nextPow2, ilog2, align4

## 0.3 Базовые структуры ✅
**Recast:**
- [x] `Config` - конфигурация
- [x] `Heightfield` - высотное поле
- [x] `CompactHeightfield` - компактное представление
- [x] `Span`, `SpanPool`, `CompactSpan`, `CompactCell`
- [x] `PolyMesh`, `PolyMeshDetail`
- [x] `Contour`, `ContourSet`
- [x] `HeightfieldLayer`, `HeightfieldLayerSet`

**Detour:**
- [x] `NavMesh`, `NavMeshParams`
- [x] `Poly`, `PolyDetail`
- [x] `Link`, `BVNode`
- [x] `OffMeshConnection`
- [x] `MeshTile`, `MeshHeader`
- [x] `Status`, `PolyRef`, `TileRef`

---

# 📦 ФАЗА 1: Модуль Recast - Построение NavMesh

## 1.1 Rasterization (Растеризация)
**Оригинал:** `Recast/Source/RecastRasterization.cpp` (629 строк)
**Цель:** `src/recast/rasterization.zig`

### Функции для реализации:
```zig
// Основные функции растеризации
pub fn rasterizeTriangle(
    ctx: *Context,
    v0: Vec3, v1: Vec3, v2: Vec3,
    area: u8,
    heightfield: *Heightfield,
    flag_merge_threshold: i32
) !bool

pub fn rasterizeTriangles(
    ctx: *Context,
    verts: []const f32,
    nv: i32,
    tris: []const i32,
    area_ids: []const u8,
    nt: i32,
    heightfield: *Heightfield,
    flag_merge_threshold: i32
) !bool

pub fn rasterizeTriangles_u16(
    ctx: *Context,
    verts: []const f32,
    nv: i32,
    tris: []const u16,
    area_ids: []const u8,
    nt: i32,
    heightfield: *Heightfield,
    flag_merge_threshold: i32
) !bool

// Вспомогательные функции
fn addSpan(
    heightfield: *Heightfield,
    x: i32, z: i32,
    smin: u16, smax: u16,
    area: u8,
    flag_merge_threshold: i32
) !void

fn dividePoly(
    buf: []Vec3,
    in: []Vec3,
    axis: i32,
    axis_dir: f32,
    out1: []Vec3,
    out2: []Vec3
) void
```

**Тесты:**
- Растеризация одиночного треугольника
- Растеризация меша
- Граничные случаи (вырожденные треугольники)
- Производительность на больших мешах

---

## 1.2 Filtering (Фильтрация)
**Оригинал:** `Recast/Source/RecastFilter.cpp` (321 строка)
**Цель:** `src/recast/filter.zig`

### Функции для реализации:
```zig
// Фильтрация низко висящих препятствий
pub fn filterLowHangingWalkableObstacles(
    ctx: *Context,
    walkable_climb: i32,
    heightfield: *Heightfield
) void

// Фильтрация выступов
pub fn filterLedgeSpans(
    ctx: *Context,
    walkable_height: i32,
    walkable_climb: i32,
    heightfield: *Heightfield
) void

// Фильтрация низких пролётов
pub fn filterWalkableLowHeightSpans(
    ctx: *Context,
    walkable_height: i32,
    heightfield: *Heightfield
) void

// Маркировка проходимых треугольников
pub fn markWalkableTriangles(
    ctx: *Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    nv: i32,
    tris: []const i32,
    nt: i32,
    area_ids: []u8
) void

// Очистка непроходимых треугольников
pub fn clearUnwalkableTriangles(
    ctx: *Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    nv: i32,
    tris: []const i32,
    nt: i32,
    area_ids: []u8
) void
```

**Тесты:**
- Фильтрация различных типов препятствий
- Пороговые значения
- Комбинации фильтров

---

## 1.3 Compact Heightfield (Компактное представление)
**Оригинал:** `Recast/Source/Recast.cpp` (функции построения CHF)
**Цель:** `src/recast/compact.zig`

### Функции для реализации:
```zig
// Построение компактного heightfield
pub fn buildCompactHeightfield(
    ctx: *Context,
    walkable_height: i32,
    walkable_climb: i32,
    heightfield: *const Heightfield,
    chf: *CompactHeightfield
) !bool

// Подсчёт spans
pub fn getHeightFieldSpanCount(
    ctx: *Context,
    heightfield: *const Heightfield
) i32

// Установка соединений между spans
fn setConnection(
    span: *CompactSpan,
    direction: u2,
    neighbor_idx: u8
) void

fn getConnection(
    span: *const CompactSpan,
    direction: u2
) u8
```

**Тесты:**
- Построение из простого heightfield
- Корректность соединений
- Граничные условия

---

## 1.4 Area Modification (Модификация областей)
**Оригинал:** `Recast/Source/RecastArea.cpp` (541 строка)
**Цель:** `src/recast/area.zig`

### Функции для реализации:
```zig
// Эрозия проходимой области
pub fn erodeWalkableArea(
    ctx: *Context,
    erosion_radius: i32,
    chf: *CompactHeightfield
) !bool

// Медианный фильтр
pub fn medianFilterWalkableArea(
    ctx: *Context,
    chf: *CompactHeightfield
) !bool

// Маркировка прямоугольной области
pub fn markBoxArea(
    ctx: *Context,
    bmin: Vec3,
    bmax: Vec3,
    area_id: u8,
    chf: *CompactHeightfield
) void

// Маркировка выпуклого полигона
pub fn markConvexPolyArea(
    ctx: *Context,
    verts: []const f32,
    nverts: i32,
    hmin: f32,
    hmax: f32,
    area_id: u8,
    chf: *CompactHeightfield
) void

// Маркировка цилиндра
pub fn markCylinderArea(
    ctx: *Context,
    pos: Vec3,
    r: f32,
    h: f32,
    area_id: u8,
    chf: *CompactHeightfield
) void

// Расширение полигона
pub fn offsetPoly(
    verts: []const f32,
    nverts: i32,
    offset: f32,
    out_verts: []f32,
    max_out_verts: i32
) i32
```

**Тесты:**
- Эрозия различных радиусов
- Маркировка областей разных форм
- Медианный фильтр

---

## 1.5 Region Building (Построение регионов)
**Оригинал:** `Recast/Source/RecastRegion.cpp` (1,893 строки!)
**Цель:** `src/recast/region.zig`

### Функции для реализации:
```zig
// Построение distance field
pub fn buildDistanceField(
    ctx: *Context,
    chf: *CompactHeightfield
) !bool

// Построение регионов (watershed)
pub fn buildRegions(
    ctx: *Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32
) !bool

// Построение регионов (monotone)
pub fn buildRegionsMonotone(
    ctx: *Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32
) !bool

// Построение слоёв (layers)
pub fn buildLayerRegions(
    ctx: *Context,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32
) !bool

// Вспомогательные структуры
const Region = struct {
    span_count: i32,
    id: u16,
    area_type: u8,
    remap: bool,
    visited: bool,
    overlap: bool,
    connections: std.ArrayList(u16),
    floors: std.ArrayList(i32),
};
```

**Тесты:**
- Watershed алгоритм
- Monotone разбиение
- Слияние малых регионов
- Производительность

---

## 1.6 Contour Building (Построение контуров)
**Оригинал:** `Recast/Source/RecastContour.cpp` (1,077 строк)
**Цель:** `src/recast/contour.zig`

### Функции для реализации:
```zig
// Построение контуров
pub fn buildContours(
    ctx: *Context,
    chf: *const CompactHeightfield,
    max_error: f32,
    max_edge_len: i32,
    cset: *ContourSet,
    build_flags: i32
) !bool

// Упрощение контуров (Douglas-Peucker)
fn simplifyContour(
    points: []i32,
    simplified: []i32,
    max_error: f32,
    max_edge_len: i32,
    build_flags: i32
) i32

// Удаление вырожденных сегментов
fn removeDegenerateSegments(
    simplified: []i32
) void

// Вспомогательные функции
fn walkContour(
    x: i32, y: i32, i: i32,
    chf: *const CompactHeightfield,
    flags: []u8,
    points: []i32
) i32

fn distancePtSeg(
    x: i32, z: i32,
    px: i32, pz: i32,
    qx: i32, qz: i32
) f32
```

**Тесты:**
- Построение контуров из регионов
- Упрощение с различными параметрами
- Граничные случаи

---

## 1.7 Polygon Mesh Building (Построение полигональной сетки)
**Оригинал:** `Recast/Source/RecastMesh.cpp` (1,477 строк)
**Цель:** `src/recast/mesh.zig`

### Функции для реализации:
```zig
// Построение полигональной сетки
pub fn buildPolyMesh(
    ctx: *Context,
    cset: *const ContourSet,
    nvp: i32,
    mesh: *PolyMesh
) !bool

// Слияние полигональных сеток
pub fn mergePolyMeshes(
    ctx: *Context,
    meshes: []*PolyMesh,
    nmeshes: i32,
    mesh: *PolyMesh
) !bool

// Копирование полигональной сетки
pub fn copyPolyMesh(
    ctx: *Context,
    src: *const PolyMesh,
    dst: *PolyMesh
) !bool

// Внутренние функции
fn triangulate(
    n: i32,
    verts: []const i32,
    indices: []i32,
    tris: []u16
) i32

fn buildMeshAdjacency(
    polys: []u16,
    npolys: i32,
    nverts: i32,
    vertsPerPoly: i32
) void

fn getPolyMergeValue(
    polys: []u16,
    pa: i32, pb: i32,
    verts: []u16,
    ea: *i32, eb: *i32,
    nvp: i32
) i32

fn mergePolys(
    polys: []u16,
    pa: i32, pb: i32,
    ea: i32, eb: i32,
    nvp: i32
) void
```

**Тесты:**
- Триангуляция контуров
- Слияние полигонов
- Слияние нескольких мешей
- Граничные рёбра

---

## 1.8 Detail Mesh Building (Построение детальной сетки)
**Оригинал:** `Recast/Source/RecastMeshDetail.cpp` (1,143 строки)
**Цель:** `src/recast/detail.zig`

### Функции для реализации:
```zig
// Построение детальной сетки
pub fn buildPolyMeshDetail(
    ctx: *Context,
    mesh: *const PolyMesh,
    chf: *const CompactHeightfield,
    sample_dist: f32,
    sample_max_error: f32,
    dmesh: *PolyMeshDetail
) !bool

// Слияние детальных сеток
pub fn mergePolyMeshDetails(
    ctx: *Context,
    meshes: []*PolyMeshDetail,
    nmeshes: i32,
    dmesh: *PolyMeshDetail
) !bool

// Вспомогательные структуры
const HeightPatch = struct {
    data: []u16,
    xmin: i32, ymin: i32,
    width: i32, height: i32,
};

// Внутренние функции
fn getHeightData(
    chf: *const CompactHeightfield,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    border_size: i32,
    hp: *HeightPatch,
    region: i32
) bool

fn buildPolyDetail(
    ctx: *Context,
    in_: []const f32,
    nin: i32,
    sample_dist: f32,
    sample_max_error: f32,
    chf: *const CompactHeightfield,
    hp: *const HeightPatch,
    verts: []f32,
    nverts: *i32,
    tris: []u8,
    ntris: *i32,
    edges: []i32,
    samples: []i32
) void

fn seedArrayWithPolyCenter(
    chf: *const CompactHeightfield,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    bs: i32,
    hp: *const HeightPatch,
    array: []i32
) void

fn delaunayHull(
    ctx: *Context,
    npts: i32,
    pts: []const f32,
    nhull: i32,
    hull: []const i32,
    tris: []u8,
    edges: []i32
) i32

fn getJitterX(i: i32) i32
fn getJitterY(i: i32) i32
```

**Тесты:**
- Построение детальной сетки
- Семплирование высот
- Delaunay триангуляция
- Слияние детальных сеток

---

## 1.9 Heightfield Layers (Слои высотного поля)
**Оригинал:** `Recast/Source/RecastLayers.cpp` (621 строка)
**Цель:** `src/recast/layers.zig`

### Функции для реализации:
```zig
// Построение слоёв heightfield
pub fn buildHeightfieldLayers(
    ctx: *Context,
    chf: *const CompactHeightfield,
    border_size: i32,
    walkable_height: i32,
    lset: *HeightfieldLayerSet
) !bool

// Вспомогательные структуры
const LayerId = struct {
    index: i32,
    count: i32,
    base_id: i32,
};

// Внутренние функции
fn contains(
    a: []const u8,
    an: i32,
    v: u8
) bool
```

**Тесты:**
- Построение слоёв
- Многослойная геометрия
- Перекрывающиеся области

---

## 1.10 Recast Utilities
**Оригинал:** `Recast/Source/RecastAlloc.cpp`, `RecastAssert.cpp`
**Цель:** Интеграция в Zig идиомы

```zig
// Аллокаторы уже встроены в Zig
// Assert можно использовать std.debug.assert
```

---

# 🧭 ФАЗА 2: Модуль Detour - Навигация и Pathfinding

## 2.1 NavMesh Builder
**Оригинал:** `Detour/Source/DetourNavMeshBuilder.cpp` (531 строка)
**Цель:** `src/detour/builder.zig`

### Функции для реализации:
```zig
// Создание NavMesh данных из PolyMesh
pub fn createNavMeshData(
    params: *const NavMeshCreateParams,
    out_data: *[]u8,
    out_data_size: *i32
) !bool

// Параметры создания
pub const NavMeshCreateParams = struct {
    verts: []const u16,
    vert_count: i32,
    polys: []const u16,
    poly_areas: []const u8,
    poly_flags: []const u16,
    poly_count: i32,
    nvp: i32,
    detail_meshes: []const u32,
    detail_verts: []const f32,
    detail_verts_count: i32,
    detail_tris: []const u8,
    detail_tri_count: i32,
    off_mesh_con_verts: []const f32,
    off_mesh_con_rad: []const f32,
    off_mesh_con_flags: []const u16,
    off_mesh_con_areas: []const u8,
    off_mesh_con_dir: []const u8,
    off_mesh_con_user_id: []const u32,
    off_mesh_con_count: i32,
    user_id: u32,
    tile_x: i32,
    tile_y: i32,
    tile_layer: i32,
    bmin: Vec3,
    bmax: Vec3,
    walkable_height: f32,
    walkable_radius: f32,
    walkable_climb: f32,
    cs: f32,
    ch: f32,
    build_bv_tree: bool,
};

// Вспомогательные функции
fn classifyOffMeshPoint(
    pt: Vec3,
    bmin: Vec3,
    bmax: Vec3
) u8

fn createBVTree(
    ctx: *Context,
    verts: []const u16,
    polys: []const u16,
    npolys: i32,
    nvp: i32,
    cs: f32,
    ch: f32,
    nnodes: i32,
    nodes: []BVNode
) bool
```

**Тесты:**
- Создание навмеша из PolyMesh
- Off-mesh connections
- BVH дерево
- Валидация данных

---

## 2.2 NavMesh Core
**Оригинал:** `Detour/Source/DetourNavMesh.cpp` (1,852 строки)
**Цель:** `src/detour/navmesh.zig` (расширение)

### Функции для реализации:
```zig
// Управление тайлами
pub fn addTile(
    self: *NavMesh,
    data: []u8,
    data_size: i32,
    flags: i32,
    last_ref: TileRef,
    result: *TileRef
) !Status

pub fn removeTile(
    self: *NavMesh,
    ref: TileRef,
    data: *[]u8,
    data_size: *i32
) !Status

// Запросы тайлов
pub fn getTileAt(
    self: *const NavMesh,
    x: i32, y: i32, layer: i32
) ?*const MeshTile

pub fn getTilesAt(
    self: *const NavMesh,
    x: i32, y: i32,
    tiles: []?*const MeshTile,
    max_tiles: i32
) i32

pub fn getTileByRef(
    self: *const NavMesh,
    ref: TileRef
) ?*const MeshTile

pub fn getTileAndPolyByRef(
    self: *const NavMesh,
    ref: PolyRef,
    tile: **const MeshTile,
    poly: **const Poly
) Status

// Модификация состояния
pub fn setPolyFlags(
    self: *NavMesh,
    ref: PolyRef,
    flags: u16
) Status

pub fn getPolyFlags(
    self: *const NavMesh,
    ref: PolyRef,
    result_flags: *u16
) Status

pub fn setPolyArea(
    self: *NavMesh,
    ref: PolyRef,
    area: u8
) Status

pub fn getPolyArea(
    self: *const NavMesh,
    ref: PolyRef,
    result_area: *u8
) Status

// Сериализация состояния
pub fn storeTileState(
    self: *const NavMesh,
    tile: *const MeshTile,
    data: []u8,
    max_data_size: i32
) Status

pub fn restoreTileState(
    self: *NavMesh,
    tile: *MeshTile,
    data: []const u8,
    max_data_size: i32
) Status

// Off-mesh connections
pub fn getOffMeshConnectionPolyEndPoints(
    self: *const NavMesh,
    prev_ref: PolyRef,
    poly_ref: PolyRef,
    start_pos: *Vec3,
    end_pos: *Vec3
) Status

pub fn getOffMeshConnectionByRef(
    self: *const NavMesh,
    ref: PolyRef
) ?*const OffMeshConnection

// Внутренние функции
fn connectExtLinks(
    self: *NavMesh,
    tile: *MeshTile,
    target: *MeshTile,
    side: i32
) void

fn connectExtOffMeshLinks(
    self: *NavMesh,
    tile: *MeshTile,
    target: *MeshTile,
    side: i32
) void

fn unconnectLinks(
    self: *NavMesh,
    tile: *MeshTile,
    target: *MeshTile
) void

fn connectIntLinks(
    self: *NavMesh,
    tile: *MeshTile
) void

fn baseOffMeshLinks(
    self: *NavMesh,
    tile: *MeshTile
) void
```

**Тесты:**
- Добавление/удаление тайлов
- Связывание тайлов
- Off-mesh connections
- Сериализация/десериализация

---

## 2.3 NavMesh Query (Запросы навигации)
**Оригинал:** `Detour/Source/DetourNavMeshQuery.cpp` (2,741 строка!)
**Цель:** `src/detour/query.zig`

### Основные структуры:
```zig
pub const NavMeshQuery = struct {
    nav: *const NavMesh,
    tiny_node_pool: *NodePool,
    node_pool: *NodePool,
    open_list: *NodeQueue,
    query_data: QueryData,
    allocator: std.mem.Allocator,
};

pub const Filter = struct {
    area_cost: [MAX_AREAS]f32 = [_]f32{1.0} ** MAX_AREAS,
    include_flags: u16 = 0xffff,
    exclude_flags: u16 = 0,

    pub fn passFilter(
        self: *const Filter,
        ref: PolyRef,
        tile: *const MeshTile,
        poly: *const Poly
    ) bool;

    pub fn getCost(
        self: *const Filter,
        pa: Vec3, pb: Vec3,
        prev_ref: PolyRef,
        prev_tile: *const MeshTile,
        prev_poly: *const Poly,
        cur_ref: PolyRef,
        cur_tile: *const MeshTile,
        cur_poly: *const Poly,
        next_ref: PolyRef,
        next_tile: *const MeshTile,
        next_poly: *const Poly
    ) f32;
};

pub const RaycastHit = struct {
    t: f32 = 0,
    hit_normal: Vec3 = Vec3.zero(),
    hit_edge_index: i32 = 0,
    path: []PolyRef,
    path_count: i32 = 0,
    max_path: i32,
    path_cost: f32 = 0,
};
```

### Функции для реализации:
```zig
// === Инициализация ===
pub fn init(
    nav: *const NavMesh,
    max_nodes: i32,
    allocator: std.mem.Allocator
) !NavMeshQuery

pub fn deinit(self: *NavMeshQuery) void

// === Ближайшие запросы ===
pub fn findNearestPoly(
    self: *NavMeshQuery,
    center: Vec3,
    half_extents: Vec3,
    filter: *const Filter,
    nearest_ref: *PolyRef,
    nearest_pt: *Vec3
) Status

pub fn queryPolygons(
    self: *NavMeshQuery,
    center: Vec3,
    half_extents: Vec3,
    filter: *const Filter,
    polys: []PolyRef,
    poly_count: *i32,
    max_polys: i32
) Status

pub fn findLocalNeighbourhood(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    center_pos: Vec3,
    radius: f32,
    filter: *const Filter,
    result_ref: []PolyRef,
    result_parent: []PolyRef,
    result_count: *i32,
    max_result: i32
) Status

// === Поиск пути (A*) ===
pub fn findPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: Vec3,
    end_pos: Vec3,
    filter: *const Filter,
    path: []PolyRef,
    path_count: *i32,
    max_path: i32
) Status

pub fn initSlicedFindPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: Vec3,
    end_pos: Vec3,
    filter: *const Filter,
    options: u32
) Status

pub fn updateSlicedFindPath(
    self: *NavMeshQuery,
    max_iter: i32,
    done_iters: *i32
) Status

pub fn finalizeSlicedFindPath(
    self: *NavMeshQuery,
    path: []PolyRef,
    path_count: *i32,
    max_path: i32
) Status

pub fn finalizeSlicedFindPathPartial(
    self: *NavMeshQuery,
    existing: []const PolyRef,
    existing_size: i32,
    path: []PolyRef,
    path_count: *i32,
    max_path: i32
) Status

// === Прямой путь (straight path) ===
pub fn findStraightPath(
    self: *const NavMeshQuery,
    start_pos: Vec3,
    end_pos: Vec3,
    path: []const PolyRef,
    path_size: i32,
    straight_path: []Vec3,
    straight_path_flags: []u8,
    straight_path_refs: []PolyRef,
    straight_path_count: *i32,
    max_straight_path: i32,
    options: i32
) Status

// === Raycast ===
pub fn raycast(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    start_pos: Vec3,
    end_pos: Vec3,
    filter: *const Filter,
    t: *f32,
    hit_normal: *Vec3,
    path: []PolyRef,
    path_count: *i32,
    max_path: i32
) Status

pub fn raycast_v2(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    start_pos: Vec3,
    end_pos: Vec3,
    filter: *const Filter,
    options: u32,
    hit: *RaycastHit,
    prev_ref: PolyRef
) Status

// === Движение вдоль поверхности ===
pub fn moveAlongSurface(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    start_pos: Vec3,
    end_pos: Vec3,
    filter: *const Filter,
    result_pos: *Vec3,
    visited: []PolyRef,
    visited_count: *i32,
    max_visited_size: i32
) Status

// === Высота и позиционирование ===
pub fn getPolyHeight(
    self: *const NavMeshQuery,
    ref: PolyRef,
    pos: Vec3,
    height: *f32
) Status

pub fn findDistanceToWall(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    center_pos: Vec3,
    max_radius: f32,
    filter: *const Filter,
    hit_dist: *f32,
    hit_pos: *Vec3,
    hit_normal: *Vec3
) Status

pub fn closestPointOnPoly(
    self: *const NavMeshQuery,
    ref: PolyRef,
    pos: Vec3,
    closest: *Vec3,
    pos_over_poly: *bool
) Status

pub fn closestPointOnPolyBoundary(
    self: *const NavMeshQuery,
    ref: PolyRef,
    pos: Vec3,
    closest: *Vec3
) Status

// === Валидация ===
pub fn isValidPolyRef(
    self: *const NavMeshQuery,
    ref: PolyRef,
    filter: *const Filter
) bool

pub fn isInClosedList(
    self: *const NavMeshQuery,
    ref: PolyRef
) bool

// === Вспомогательные функции ===
pub fn getPathFromDijkstraSearch(
    self: *NavMeshQuery,
    end_ref: PolyRef,
    path: []PolyRef,
    path_count: *i32,
    max_path: i32
) Status

pub fn getAttachedNavMesh(
    self: *const NavMeshQuery
) *const NavMesh
```

**Тесты:**
- A* pathfinding на различных мешах
- Raycast с препятствиями
- Движение вдоль поверхности
- Straight path оптимизация
- Sliced pathfinding
- Граничные случаи

---

## 2.4 Node Pool (Пул узлов для A*)
**Оригинал:** `Detour/Source/DetourNode.cpp` (292 строки)
**Цель:** `src/detour/node.zig`

### Структуры и функции:
```zig
pub const Node = struct {
    pos: Vec3,
    cost: f32,
    total: f32,
    pidx: u32,  // parent index
    flags: u8,
    id: PolyRef,
};

pub const NodePool = struct {
    nodes: []Node,
    first: []u16,
    next: []u16,
    max_nodes: i32,
    hash_size: i32,
    node_count: i32,
    allocator: std.mem.Allocator,

    pub fn init(max_nodes: i32, hash_size: i32, allocator: std.mem.Allocator) !NodePool;
    pub fn deinit(self: *NodePool) void;
    pub fn clear(self: *NodePool) void;
    pub fn getNode(self: *NodePool, id: PolyRef, flags: u8) ?*Node;
    pub fn findNode(self: *const NodePool, id: PolyRef) ?*const Node;
    pub fn getNodeIdx(self: *const NodePool, node: *const Node) u32;
    pub fn getNodeAtIdx(self: *const NodePool, idx: u32) ?*Node;
    pub fn getMemUsed(self: *const NodePool) i32;
};

pub const NodeQueue = struct {
    heap: []Node,
    capacity: i32,
    size: i32,
    allocator: std.mem.Allocator,

    pub fn init(n: i32, allocator: std.mem.Allocator) !NodeQueue;
    pub fn deinit(self: *NodeQueue) void;
    pub fn clear(self: *NodeQueue) void;
    pub fn top(self: *NodeQueue) ?*Node;
    pub fn pop(self: *NodeQueue) ?*Node;
    pub fn push(self: *NodeQueue, node: *Node) void;
    pub fn modify(self: *NodeQueue, node: *Node) void;
    pub fn empty(self: *const NodeQueue) bool;
};
```

**Тесты:**
- Добавление/удаление узлов
- Очередь с приоритетом
- Хеш-таблица узлов

---

## 2.5 Detour Common (Общие функции)
**Оригинал:** `Detour/Source/DetourCommon.cpp` (571 строка)
**Цель:** `src/detour/common_funcs.zig`

### Функции для реализации:
```zig
// Пересечения
pub fn intersectSegmentPoly2D(
    p0: Vec3, p1: Vec3,
    verts: []const Vec3,
    nverts: i32,
    tmin: *f32, tmax: *f32,
    seg_min: *i32, seg_max: *i32
) bool

pub fn intersectSegSeg2D(
    ap: Vec3, aq: Vec3,
    bp: Vec3, bq: Vec3,
    s: *f32, t: *f32
) bool

// Расстояния
pub fn distancePtSegSqr2D(
    pt: Vec3,
    p: Vec3, q: Vec3,
    t: *f32
) f32

pub fn distancePtPolyEdgesSqr(
    pt: Vec3,
    verts: []const Vec3,
    nverts: i32,
    ed: []f32,
    et: []f32
) f32

// Точка в полигоне
pub fn pointInPolygon(
    pt: Vec3,
    verts: []const Vec3,
    nverts: i32
) bool

// Ближайшая точка на треугольнике
pub fn closestPtPointTriangle(
    closest: *Vec3,
    p: Vec3,
    a: Vec3, b: Vec3, c: Vec3
) void

pub fn closestHeightPointTriangle(
    p: Vec3,
    a: Vec3, b: Vec3, c: Vec3,
    h: *f32
) bool

// Случайная точка в полигоне
pub fn randomPointInConvexPoly(
    pts: []const Vec3,
    npts: i32,
    areas: []f32,
    s: f32, t: f32,
    out: *Vec3
) void

// Перекрытие полигонов
pub fn overlapPolyPoly2D(
    polya: []const Vec3, npolya: i32,
    polyb: []const Vec3, npolyb: i32
) bool

// Центр полигона
pub fn calcPolyCenter(
    tc: *Vec3,
    idx: []const u16,
    nidx: i32,
    verts: []const Vec3
) void
```

**Тесты:**
- Пересечения сегментов
- Точка в полигоне
- Расстояния до рёбер
- Случайные точки

---

# 👥 ФАЗА 3: Модуль DetourCrowd - Управление толпой

## 3.1 Crowd Manager
**Оригинал:** `DetourCrowd/Source/DetourCrowd.cpp` (1,558 строк)
**Цель:** `src/detour_crowd/crowd.zig`

### Основные структуры:
```zig
pub const CrowdAgent = struct {
    active: bool,
    state: CrowdAgentState,
    corridor: PathCorridor,
    boundary: LocalBoundary,
    topography_opt_time: f32,
    neis: [DT_CROWDAGENT_MAX_NEIGHBOURS]CrowdNeighbour,
    nneis: i32,
    desired_speed: f32,
    npos: Vec3,
    disp: Vec3,
    dvel: Vec3,
    nvel: Vec3,
    vel: Vec3,
    params: CrowdAgentParams,
    corners: [DT_CROWDAGENT_MAX_CORNERS]Vec3,
    ncorners: i32,
    target_state: MoveRequestState,
    target_ref: PolyRef,
    target_pos: Vec3,
    target_path_q_ref: PathQueueRef,
    target_replan: bool,
    target_replan_time: f32,
};

pub const CrowdAgentParams = struct {
    radius: f32,
    height: f32,
    max_acceleration: f32,
    max_speed: f32,
    collision_query_range: f32,
    path_optimization_range: f32,
    separation_weight: f32,
    update_flags: u8,
    obstacle_avoidance_type: u8,
    query_filter_type: u8,
    user_data: ?*anyopaque,
};

pub const Crowd = struct {
    max_agents: i32,
    agents: []CrowdAgent,
    active_agents: []CrowdAgent,
    agent_anims: []CrowdAgentAnimation,
    path_q: PathQueue,
    avoidance_params: [DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS]ObstacleAvoidanceParams,
    avoidance_query: ObstacleAvoidanceQuery,
    grid: ProximityGrid,
    path_result: []PolyRef,
    max_path_result: i32,
    ext: Vec3,
    filters: [DT_CROWD_MAX_QUERY_FILTER_TYPE]QueryFilter,
    max_agent_radius: f32,
    velocity_sample_count: i32,
    nav_query: NavMeshQuery,
    allocator: std.mem.Allocator,
};
```

### Функции для реализации:
```zig
// Инициализация
pub fn init(
    max_agents: i32,
    max_agent_radius: f32,
    nav: *NavMesh,
    allocator: std.mem.Allocator
) !Crowd

pub fn deinit(self: *Crowd) void

// Управление агентами
pub fn addAgent(
    self: *Crowd,
    pos: Vec3,
    params: *const CrowdAgentParams
) i32

pub fn updateAgentParameters(
    self: *Crowd,
    idx: i32,
    params: *const CrowdAgentParams
) void

pub fn removeAgent(
    self: *Crowd,
    idx: i32
) void

// Запросы
pub fn getAgent(
    self: *Crowd,
    idx: i32
) ?*CrowdAgent

pub fn getActiveAgents(
    self: *Crowd,
    agents: []?*CrowdAgent,
    max_agents: i32
) i32

pub fn getEditableFilter(
    self: *Crowd,
    i: i32
) *QueryFilter

pub fn getFilter(
    self: *const Crowd,
    i: i32
) *const QueryFilter

// Цели и движение
pub fn requestMoveTarget(
    self: *Crowd,
    idx: i32,
    ref: PolyRef,
    pos: Vec3
) bool

pub fn requestMoveVelocity(
    self: *Crowd,
    idx: i32,
    vel: Vec3
) bool

pub fn resetMoveTarget(
    self: *Crowd,
    idx: i32
) bool

// Обновление симуляции
pub fn update(
    self: *Crowd,
    dt: f32,
    debug: ?*CrowdAgentDebugInfo
) void

// Избегание препятствий
pub fn getObstacleAvoidanceParams(
    self: *const Crowd,
    idx: i32
) *const ObstacleAvoidanceParams

pub fn setObstacleAvoidanceParams(
    self: *Crowd,
    idx: i32,
    params: *const ObstacleAvoidanceParams
) void

// Внутренние функции
fn updateTopologyOptimization(
    self: *Crowd,
    agents: []?*CrowdAgent,
    nagents: i32,
    dt: f32
) void

fn checkPathValidity(
    self: *Crowd,
    agents: []?*CrowdAgent,
    nagents: i32,
    dt: f32
) void

fn updateMoveRequest(
    self: *Crowd,
    dt: f32
) void
```

**Тесты:**
- Добавление/удаление агентов
- Навигация к цели
- Избегание друг друга
- Производительность на 100+ агентах

---

## 3.2 Path Corridor
**Оригинал:** `DetourCrowd/Source/DetourPathCorridor.cpp` (442 строки)
**Цель:** `src/detour_crowd/corridor.zig`

### Функции:
```zig
pub const PathCorridor = struct {
    pos: Vec3,
    target: Vec3,
    path: []PolyRef,
    npath: i32,
    max_path: i32,
    allocator: std.mem.Allocator,

    pub fn init(max_path: i32, allocator: std.mem.Allocator) !PathCorridor;
    pub fn deinit(self: *PathCorridor) void;
    pub fn reset(self: *PathCorridor, ref: PolyRef, pos: Vec3) void;
    pub fn findCorners(self: *PathCorridor, corners: []Vec3, corner_flags: []u8, corner_polys: []PolyRef, max_corners: i32, navquery: *NavMeshQuery, filter: *const Filter) i32;
    pub fn optimizePathVisibility(self: *PathCorridor, next: Vec3, path_opt_range: f32, navquery: *NavMeshQuery, filter: *const Filter) void;
    pub fn optimizePathTopology(self: *PathCorridor, navquery: *NavMeshQuery, filter: *const Filter) bool;
    pub fn moveOverOffmeshConnection(self: *PathCorridor, offMeshConRef: PolyRef, refs: []PolyRef, start_pos: *Vec3, end_pos: *Vec3, navquery: *NavMeshQuery) bool;
    pub fn movePosition(self: *PathCorridor, npos: Vec3, navquery: *NavMeshQuery, filter: *const Filter) bool;
    pub fn moveTargetPosition(self: *PathCorridor, npos: Vec3, navquery: *NavMeshQuery, filter: *const Filter) bool;
    pub fn setCorridor(self: *PathCorridor, target: Vec3, path: []const PolyRef, npath: i32) void;
    pub fn fixPathStart(self: *PathCorridor, safeRef: PolyRef, safePos: Vec3) bool;
    pub fn trimInvalidPath(self: *PathCorridor, safeRef: PolyRef, safePos: []const f32, navquery: *NavMeshQuery, filter: *const Filter) bool;
    pub fn isValid(self: *const PathCorridor, maxLookAhead: i32, navquery: *NavMeshQuery, filter: *const Filter) bool;
};
```

**Тесты:**
- Оптимизация пути
- Движение вдоль коридора
- Off-mesh connections

---

## 3.3 Obstacle Avoidance
**Оригинал:** `DetourCrowd/Source/DetourObstacleAvoidance.cpp` (760 строк)
**Цель:** `src/detour_crowd/avoidance.zig`

### Функции:
```zig
pub const ObstacleCircle = struct {
    p: Vec3,
    vel: Vec3,
    dvel: Vec3,
    rad: f32,
    dp: Vec3,
    np: Vec3,
};

pub const ObstacleSegment = struct {
    p: Vec3, q: Vec3,
    touch: bool,
};

pub const ObstacleAvoidanceDebugData = struct {
    nsamples: i32,
    max_samples: i32,
    vel: []Vec3,
    ssize: []f32,
    pen: []f32,
    vpen: []f32,
    vcpen: []f32,
    spen: []f32,
    tpen: []f32,
};

pub const ObstacleAvoidanceQuery = struct {
    max_circles: i32,
    circles: []ObstacleCircle,
    ncircles: i32,
    max_segments: i32,
    segments: []ObstacleSegment,
    nsegments: i32,
    params: ObstacleAvoidanceParams,
    inv_h_grid: f32,
    inv_v_grid: f32,
    max_grid: i32,
    grid_size: i32,
    grid: []u16,
    allocator: std.mem.Allocator,

    pub fn init(maxCircles: i32, maxSegments: i32, allocator: std.mem.Allocator) !ObstacleAvoidanceQuery;
    pub fn deinit(self: *ObstacleAvoidanceQuery) void;
    pub fn reset(self: *ObstacleAvoidanceQuery) void;
    pub fn addCircle(self: *ObstacleAvoidanceQuery, pos: Vec3, rad: f32, vel: Vec3, dvel: Vec3) void;
    pub fn addSegment(self: *ObstacleAvoidanceQuery, p: Vec3, q: Vec3) void;
    pub fn sampleVelocityGrid(self: *ObstacleAvoidanceQuery, pos: Vec3, rad: f32, vmax: f32, vel: Vec3, dvel: Vec3, nvel: *Vec3, params: *const ObstacleAvoidanceParams, debug: ?*ObstacleAvoidanceDebugData) i32;
    pub fn sampleVelocityAdaptive(self: *ObstacleAvoidanceQuery, pos: Vec3, rad: f32, vmax: f32, vel: Vec3, dvel: Vec3, nvel: *Vec3, params: *const ObstacleAvoidanceParams, debug: ?*ObstacleAvoidanceDebugData) i32;
};

pub const ObstacleAvoidanceParams = struct {
    vel_bias: f32,
    weight_desired_vel: f32,
    weight_current_vel: f32,
    weight_side: f32,
    weight_toi: f32,
    horiz_time: f32,
    grid_size: u8,
    adaptive_divs: u8,
    adaptive_rings: u8,
    adaptive_depth: u8,
};
```

**Тесты:**
- RVO (Reciprocal Velocity Obstacle)
- Grid sampling
- Adaptive sampling

---

## 3.4 Local Boundary
**Оригинал:** `DetourCrowd/Source/DetourLocalBoundary.cpp` (201 строка)
**Цель:** `src/detour_crowd/boundary.zig`

### Функции:
```zig
pub const LocalBoundary = struct {
    center: Vec3,
    segs: [DT_LOCAL_BOUNDARY_MAX_SEGS * 3]Vec3,
    nsegs: i32,
    polys: [DT_LOCAL_BOUNDARY_MAX_POLYS]PolyRef,
    npolys: i32,

    pub fn init() LocalBoundary;
    pub fn reset(self: *LocalBoundary) void;
    pub fn update(self: *LocalBoundary, ref: PolyRef, pos: Vec3, collisionQueryRange: f32, navquery: *NavMeshQuery, filter: *const Filter) void;
    pub fn isValid(self: *const LocalBoundary, navquery: *NavMeshQuery, filter: *const Filter) bool;
};
```

---

## 3.5 Proximity Grid
**Оригинал:** `DetourCrowd/Source/DetourProximityGrid.cpp` (210 строк)
**Цель:** `src/detour_crowd/grid.zig`

### Функции:
```zig
pub const ProximityGrid = struct {
    cell_size: f32,
    inv_cell_size: f32,
    pool: []u16,
    pool_head: i32,
    pool_size: i32,
    buckets: []u16,
    bucket_size: i32,
    bounds: [4]f32,
    allocator: std.mem.Allocator,

    pub fn init(poolSize: i32, cellSize: f32, allocator: std.mem.Allocator) !ProximityGrid;
    pub fn deinit(self: *ProximityGrid) void;
    pub fn clear(self: *ProximityGrid) void;
    pub fn addItem(self: *ProximityGrid, id: u16, minx: f32, miny: f32, maxx: f32, maxy: f32) void;
    pub fn queryItems(self: *const ProximityGrid, minx: f32, miny: f32, maxx: f32, maxy: f32, ids: []u16, maxIds: i32) i32;
};
```

---

## 3.6 Path Queue
**Оригинал:** `DetourCrowd/Source/DetourPathQueue.cpp` (243 строки)
**Цель:** `src/detour_crowd/path_queue.zig`

### Функции:
```zig
pub const PathQueue = struct {
    const MAX_QUEUE = 8;
    const PathQuery = struct {
        ref: PathQueueRef,
        start_pos: Vec3,
        end_pos: Vec3,
        start_ref: PolyRef,
        end_ref: PolyRef,
        path: []PolyRef,
        npath: i32,
        status: Status,
        keep_alive: i32,
        filter: Filter,
    };

    queue: [MAX_QUEUE]PathQuery,
    next_handle: PathQueueRef,
    max_path_size: i32,
    queue_head: i32,
    navquery: NavMeshQuery,
    allocator: std.mem.Allocator,

    pub fn init(maxPathSize: i32, maxSearchNodeCount: i32, nav: *NavMesh, allocator: std.mem.Allocator) !PathQueue;
    pub fn deinit(self: *PathQueue) void;
    pub fn update(self: *PathQueue, max_iters: i32) void;
    pub fn request(self: *PathQueue, startRef: PolyRef, endRef: PolyRef, startPos: Vec3, endPos: Vec3, filter: *const Filter) PathQueueRef;
    pub fn getRequestStatus(self: *const PathQueue, ref: PathQueueRef) Status;
    pub fn getPathResult(self: *PathQueue, ref: PathQueueRef, path: []PolyRef, npath: *i32, maxPath: i32) Status;
};
```

---

# 🔲 ФАЗА 4: Модуль DetourTileCache - Динамические препятствия

## 4.1 Tile Cache Core
**Оригинал:** `DetourTileCache/Source/DetourTileCache.cpp` (1,257 строк)
**Цель:** `src/detour_tilecache/tilecache.zig`

### Основные структуры:
```zig
pub const TileCacheObstacle = struct {
    const Type = enum { cylinder, box, oriented_box };

    type: Type,
    pos: Vec3,
    radius: f32,
    height: f32,
    bmin: Vec3,
    bmax: Vec3,
    rotAux: [2]f32,
    center: Vec3,
    extents: Vec3,
    next: u16,
    salt: u16,
    state: u8,
    pending: []u8,
    touched: []u8,
};

pub const TileCache = struct {
    params: TileCacheParams,
    lcp: TileCacheLayerHeaderCompressor,
    lmesh: *TileCacheMeshProcess,
    talloc: *TileCacheAlloc,
    tcomp: *TileCacheCompressor,
    tmproc: []TileCacheMeshProcess,
    ntmproc: i32,
    obstacles: []TileCacheObstacle,
    next_free_obstacle: u16,
    pos_lookup: []?*TileCacheLayer,
    tiles: []TileCacheLayer,
    salt_bits: u32,
    tile_bits: u32,
    reqs: []ObstacleRequest,
    nreqs: i32,
    update: []u8,
    nupdate: i32,
    navmesh: *NavMesh,
    allocator: std.mem.Allocator,

    pub fn init(params: *const TileCacheParams, talloc: *TileCacheAlloc, tcomp: *TileCacheCompressor, tmproc: *TileCacheMeshProcess, allocator: std.mem.Allocator) !TileCache;
    pub fn deinit(self: *TileCache) void;
    pub fn addTile(self: *TileCache, data: []u8, dataSize: i32, flags: u8, result: *TileRef) Status;
    pub fn removeTile(self: *TileCache, ref: TileRef, data: *[]u8, dataSize: *i32) Status;
    pub fn addObstacle(self: *TileCache, pos: Vec3, radius: f32, height: f32, result: *ObstacleRef) Status;
    pub fn removeObstacle(self: *TileCache, ref: ObstacleRef) Status;
    pub fn update(self: *TileCache, dt: f32, navmesh: *NavMesh, upToDate: *bool) Status;
    pub fn buildNavMeshTilesAt(self: *TileCache, tx: i32, ty: i32, navmesh: *NavMesh) Status;
    pub fn buildNavMeshTile(self: *TileCache, ref: TileRef, navmesh: *NavMesh) Status;
};
```

### Функции:
```zig
// Добавление/удаление препятствий различных форм
pub fn addBoxObstacle(self: *TileCache, bmin: Vec3, bmax: Vec3, result: *ObstacleRef) Status;
pub fn addOrientedBoxObstacle(self: *TileCache, center: Vec3, extents: Vec3, yRadians: f32, result: *ObstacleRef) Status;

// Запросы препятствий
pub fn getObstacleByRef(self: *TileCache, ref: ObstacleRef) ?*const TileCacheObstacle;
pub fn getObstacleCount(self: *const TileCache) i32;

// Управление тайлами
pub fn getTileAt(self: *const TileCache, tx: i32, ty: i32, tlayer: i32) ?*const CompressedTile;
pub fn getTileRef(self: *const TileCache, tile: *const CompressedTile) TileRef;
pub fn getTileByRef(self: *const TileCache, ref: TileRef) ?*const CompressedTile;
```

**Тесты:**
- Добавление/удаление препятствий
- Обновление навмеша
- Различные формы препятствий
- Производительность

---

## 4.2 Tile Cache Builder
**Оригинал:** `DetourTileCache/Source/DetourTileCacheBuilder.cpp` (669 строк)
**Цель:** `src/detour_tilecache/builder.zig`

### Функции:
```zig
pub fn buildTileCacheLayer(
    comp: *TileCacheCompressor,
    header: *TileCacheLayerHeader,
    heights: []const u8,
    areas: []const u8,
    cons: []const u8,
    data: *[]u8,
    data_size: *i32
) Status;

pub fn freeTileCacheLayer(alloc: *TileCacheAlloc, layer: *TileCacheLayer) void;

pub fn buildTileCacheRegions(
    alloc: *TileCacheAlloc,
    layer: *TileCacheLayer,
    walkable_climb: i32
) Status;

pub fn buildTileCacheContours(
    alloc: *TileCacheAlloc,
    layer: *TileCacheLayer,
    walkable_climb: i32,
    max_error: f32,
    lcset: *TileCacheContourSet
) Status;

pub fn buildTileCachePolyMesh(
    alloc: *TileCacheAlloc,
    lcset: *TileCacheContourSet,
    mesh: *TileCachePolyMesh
) Status;

pub fn markCylinderArea(
    layer: *TileCacheLayer,
    orig: Vec3,
    cs: f32,
    ch: f32,
    pos: Vec3,
    radius: f32,
    height: f32,
    area_id: u8
) void;

pub fn markBoxArea(
    layer: *TileCacheLayer,
    orig: Vec3,
    cs: f32,
    ch: f32,
    bmin: Vec3,
    bmax: Vec3,
    area_id: u8
) void;
```

**Тесты:**
- Построение сжатых слоёв
- Маркировка областей
- Декомпрессия

---

# 🔧 ФАЗА 5: Debug Utils

## 5.1 Recast Debug Draw
**Оригинал:** `DebugUtils/Source/RecastDebugDraw.cpp` (1,044 строки)
**Цель:** `src/debug/recast_debug.zig`

### Функции:
```zig
pub fn debugDrawHeightfieldSolid(dd: *DebugDrawer, hf: *const Heightfield) void;
pub fn debugDrawHeightfieldWalkable(dd: *DebugDrawer, hf: *const Heightfield) void;
pub fn debugDrawCompactHeightfieldSolid(dd: *DebugDrawer, chf: *const CompactHeightfield) void;
pub fn debugDrawCompactHeightfieldRegions(dd: *DebugDrawer, chf: *const CompactHeightfield) void;
pub fn debugDrawCompactHeightfieldDistance(dd: *DebugDrawer, chf: *const CompactHeightfield) void;
pub fn debugDrawHeightfieldLayer(dd: *DebugDrawer, layer: *const HeightfieldLayer, idx: i32) void;
pub fn debugDrawRegionConnections(dd: *DebugDrawer, cset: *const ContourSet, alpha: f32) void;
pub fn debugDrawRawContours(dd: *DebugDrawer, cset: *const ContourSet, alpha: f32) void;
pub fn debugDrawContours(dd: *DebugDrawer, cset: *const ContourSet, alpha: f32) void;
pub fn debugDrawPolyMesh(dd: *DebugDrawer, mesh: *const PolyMesh) void;
pub fn debugDrawPolyMeshDetail(dd: *DebugDrawer, dmesh: *const PolyMeshDetail) void;
```

---

## 5.2 Detour Debug Draw
**Оригинал:** `DebugUtils/Source/DetourDebugDraw.cpp` (346 строк)
**Цель:** `src/debug/detour_debug.zig`

### Функции:
```zig
pub fn debugDrawNavMesh(dd: *DebugDrawer, mesh: *const NavMesh, flags: u8) void;
pub fn debugDrawNavMeshTile(dd: *DebugDrawer, mesh: *const NavMesh, tile: *const MeshTile) void;
pub fn debugDrawNavMeshBVTree(dd: *DebugDrawer, mesh: *const NavMesh) void;
pub fn debugDrawNavMeshNodes(dd: *DebugDrawer, query: *const NavMeshQuery) void;
pub fn debugDrawNavMeshPolysWithFlags(dd: *DebugDrawer, mesh: *const NavMesh, polyFlags: u16, col: u32) void;
pub fn debugDrawNavMeshPoly(dd: *DebugDrawer, mesh: *const NavMesh, ref: PolyRef, col: u32) void;
```

---

## 5.3 Recast Dump
**Оригинал:** `DebugUtils/Source/RecastDump.cpp` (577 строк)
**Цель:** `src/debug/dump.zig`

### Функции:
```zig
pub fn dumpPolyMeshToObj(mesh: *const PolyMesh, file: std.fs.File) !void;
pub fn dumpPolyMeshDetailToObj(dmesh: *const PolyMeshDetail, file: std.fs.File) !void;
pub fn dumpContourSet(cset: *const ContourSet, file: std.fs.File) !void;
```

---

# 🧪 ФАЗА 6: Тесты

## 6.1 Recast Tests
**Оригинал:** `Tests/Recast/`
**Цель:** `test/recast/`

### Тестовые файлы:
```zig
// test/recast/filter_test.zig
test "filterLowHangingWalkableObstacles"
test "filterLedgeSpans"
test "filterWalkableLowHeightSpans"

// test/recast/rasterize_test.zig
test "rasterizeTriangle basic"
test "rasterizeTriangle degenerate"
test "rasterizeTriangles mesh"

// test/recast/region_test.zig
test "buildDistanceField"
test "buildRegions watershed"
test "buildRegions monotone"
test "region merging"

// test/recast/contour_test.zig
test "buildContours simple"
test "simplifyContour"
test "contour edge cases"

// test/recast/mesh_test.zig
test "buildPolyMesh"
test "mergePolyMeshes"
test "polygon triangulation"

// test/recast/detail_test.zig
test "buildPolyMeshDetail"
test "height sampling"
test "delaunay triangulation"

// test/recast/alloc_test.zig
test "span allocation"
test "pool allocation"
test "memory leaks"
```

---

## 6.2 Detour Tests
**Оригинал:** `Tests/Detour/Tests_Detour.cpp`
**Цель:** `test/detour/`

### Тестовые файлы:
```zig
// test/detour/navmesh_test.zig
test "NavMesh initialization"
test "addTile"
test "removeTile"
test "tile linking"

// test/detour/query_test.zig
test "findNearestPoly"
test "findPath A*"
test "findPath sliced"
test "raycast"
test "moveAlongSurface"
test "findStraightPath"

// test/detour/node_test.zig
test "NodePool allocation"
test "NodeQueue priority"
test "node hashing"

// test/detour/common_test.zig
test "intersectSegmentPoly2D"
test "closestPtPointTriangle"
test "pointInPolygon"
```

---

## 6.3 DetourCrowd Tests
**Оригинал:** `Tests/DetourCrowd/Tests_DetourPathCorridor.cpp`
**Цель:** `test/crowd/`

### Тестовые файлы:
```zig
// test/crowd/corridor_test.zig
test "PathCorridor init"
test "optimizePathVisibility"
test "optimizePathTopology"

// test/crowd/crowd_test.zig
test "Crowd agent management"
test "agent movement"
test "collision avoidance"

// test/crowd/avoidance_test.zig
test "obstacle avoidance RVO"
test "velocity sampling"
```

---

## 6.4 Benchmarks
**Оригинал:** `Tests/Recast/Bench_rcVector.cpp`
**Цель:** `bench/`

### Benchmark файлы:
```zig
// bench/pathfinding_bench.zig
test "benchmark A* performance"
test "benchmark large mesh"
test "benchmark crowd simulation"

// bench/rasterize_bench.zig
test "benchmark triangle rasterization"
test "benchmark large triangle count"

// bench/region_bench.zig
test "benchmark watershed"
test "benchmark distance field"
```

---

# 📚 ФАЗА 7: Примеры и документация

## 7.1 Базовые примеры

### `examples/01_simple_navmesh.zig` ✅
Создание простого навмеша из геометрии

### `examples/02_tiled_navmesh.zig`
Многотайловый навмеш

### `examples/03_pathfinding.zig`
Поиск пути между двумя точками

### `examples/04_crowd_simulation.zig`
Симуляция толпы

### `examples/05_dynamic_obstacles.zig`
Динамические препятствия с TileCache

### `examples/06_offmesh_connections.zig`
Off-mesh соединения (прыжки, двери, телепорты)

---

## 7.2 Продвинутые примеры

### `examples/advanced/custom_areas.zig`
Пользовательские области с разными стоимостями

### `examples/advanced/hierarchical_pathfinding.zig`
Иерархический поиск пути

### `examples/advanced/streaming_world.zig`
Стриминг большого мира

---

## 7.3 Документация

### `docs/API.md`
Полная документация API

### `docs/MIGRATION.md`
Миграция с C++ на Zig версию

### `docs/PERFORMANCE.md`
Гайд по оптимизации

### `docs/ALGORITHMS.md`
Описание алгоритмов

---

# 🎨 ФАЗА 8: Zig Идиомы и Оптимизации

## 8.1 Comptime специализация
```zig
// Специализация для разных типов навмеша
pub fn buildNavMesh(
    comptime mesh_type: enum { solo, tiled },
    allocator: std.mem.Allocator,
    config: Config
) !NavMesh {
    return switch (mesh_type) {
        .solo => buildSoloMesh(allocator, config),
        .tiled => buildTiledMesh(allocator, config),
    };
}
```

## 8.2 SIMD оптимизации
```zig
// Векторизация расстояний
pub fn distanceFieldSIMD(
    chf: *CompactHeightfield
) void {
    // Использовать @Vector для ускорения
    const Vec4f = @Vector(4, f32);
    // ...
}
```

## 8.3 Улучшенная обработка ошибок
```zig
pub const RecastError = error {
    InvalidConfig,
    OutOfMemory,
    InvalidGeometry,
    TooManyRegions,
    BuildFailed,
};

pub const DetourError = error {
    InvalidNavMesh,
    PathNotFound,
    InvalidQuery,
    NodePoolExhausted,
};
```

## 8.4 Zero-allocation path API
```zig
// Для hot-path без аллокаций
pub fn findPathNoAlloc(
    query: *NavMeshQuery,
    path_buffer: []PolyRef, // pre-allocated
    start: PolyRef,
    end: PolyRef,
    ...
) ![]PolyRef {
    // Использует pre-allocated buffer
}
```

---

# 📈 Метрики успеха

## Функциональные требования
- [ ] 100% функциональная совместимость с C++ версией
- [ ] Все 50+ файлов переписаны
- [ ] Все тесты портированы и проходят
- [ ] Примеры работают

## Производительность
- [ ] A* не медленнее C++ версии (±5%)
- [ ] Rasterization не медленнее (±10%)
- [ ] Crowd симуляция: 100+ агентов @ 60 FPS

## Качество кода
- [ ] 90%+ test coverage
- [ ] Zero memory leaks (valgrind/asan)
- [ ] Zero UB (Zig's safety checks)
- [ ] Документация для всех публичных API

## Идиомы Zig
- [ ] Явные аллокаторы везде
- [ ] Error unions вместо bool/status
- [ ] Comptime где возможно
- [ ] SIMD для критических секций

---

# ⏱️ Оценка времени

## По фазам (реалистичная оценка):
1. **ФАЗА 1 (Recast)**: 40-50 часов
2. **ФАЗА 2 (Detour)**: 35-45 часов
3. **ФАЗА 3 (Crowd)**: 25-30 часов
4. **ФАЗА 4 (TileCache)**: 15-20 часов
5. **ФАЗА 5 (Debug)**: 10-15 часов
6. **ФАЗА 6 (Tests)**: 20-25 часов
7. **ФАЗА 7 (Examples/Docs)**: 15-20 часов
8. **ФАЗА 8 (Optimizations)**: 20-25 часов

**ИТОГО: 180-230 часов чистой работы**

## Разбивка по неделям (если работать 20 ч/неделю):
- **9-12 недель** = 2-3 месяца

---

# 🚀 Стратегия реализации

## Приоритеты:
1. **P0 (Критично)**: Фазы 1-2 (Recast + Detour core)
2. **P1 (Важно)**: Фаза 3 (Crowd), Тесты
3. **P2 (Желательно)**: Фаза 4 (TileCache), Debug utils
4. **P3 (Опционально)**: Примеры, документация, оптимизации

## Milestone plan:
- **Milestone 1** (4 недели): Recast полностью
- **Milestone 2** (3 недели): Detour pathfinding
- **Milestone 3** (2 недели): Crowd simulation
- **Milestone 4** (2 недели): Tests + bugfixes
- **Milestone 5** (1 неделя): Polish + docs

---

# 🎯 Начать с...

Рекомендую начинать в следующем порядке:

1. `src/recast/rasterization.zig` - фундаментальный алгоритм
2. `src/recast/filter.zig` - простые фильтры
3. `src/recast/compact.zig` - построение CHF
4. `src/recast/region.zig` - самый сложный модуль
5. `src/recast/contour.zig`
6. `src/recast/mesh.zig`
7. Затем переходить к Detour

---

# ✅ Чеклист готовности к продакшну

- [ ] Все модули реализованы
- [ ] Все тесты проходят
- [ ] Нет memory leaks
- [ ] Нет undefined behavior
- [ ] Производительность проверена
- [ ] API документирован
- [ ] Примеры работают
- [ ] CI/CD настроен
- [ ] Benchmark suite готов
- [ ] Semantic versioning
- [ ] CHANGELOG.md
- [ ] Совместимость с C API (extern)

---

**Готов начать полную реализацию?** 🚀
