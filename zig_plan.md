Отличная задача! Вот детализированный промт для грамотного переписывания RecastNavigation @recastnavigation\ на Zig, учитывающий все преимущества языка и его идеологию.

## 🎯 Цель проекта

Полностью переписать библиотеку RecastNavigation на Zig версии 0.14.0, используя все преимущества языка: безопасность памяти, компиляцию времени выполнения, явные аллокации, и современные подходы к проектированию.

## 📋 Фазы реализации

### **Фаза 1: Анализ и проектирование**

```
1. Изучить структуру оригинальной библиотеки:
   - Анализ всех модулей: Recast, Detour, DetourCrowd, DetourTileCache
   - Понимание математических структур (векторы, матрицы)
   - Идентификация всех точек аллокации памяти

2. Проектирование архитектуры на Zig:
   - Определить интерфейсы модулей
   - Спроектировать систему управления памятью
   - Определить стратегию обработки ошибок
```

### **Фаза 2: Настройка проекта и инфраструктуры**

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const recast = b.addModule("recast", .{
        .source_file = .{ .path = "src/recast.zig" },
    });

    // Настройка тестов, примеров, бенчмарков
}
```

### **Фаза 3: Базовые типы и утилиты**

```zig
// src/math.zig - Переписать с учетом строгой типизации Zig
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    // comptime методы где возможно
    pub inline fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }
};
```

### **Фаза 4: Явная система управления памятью**

```zig
// src/allocator.zig
pub const RecastAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RecastAllocator {
        return .{ .allocator = allocator };
    }

    // Замена rcAlloc/rcFree
    pub fn alloc(self: RecastAllocator, comptime T: type, count: usize) ![]T {
        return self.allocator.alloc(T, count);
    }

    pub fn free(self: RecastAllocator, memory: anytype) void {
        self.allocator.free(memory);
    }
};
```

### **Фаза 5: Переписывание основных модулей**

#### **5.1 Модуль Recast**

```zig
// src/recast.zig
pub const Heightfield = struct {
    width: i32,
    height: i32,
    bounds: [6]f32,
    cells: []Cell,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: i32, height: i32) !Heightfield {
        const cells = try allocator.alloc(Cell, @intCast(width * height));
        return Heightfield{
            .width = width,
            .height = height,
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Heightfield) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};
```

#### **5.2 Модуль Detour**

```zig
// src/detour.zig
pub const NavMesh = struct {
    params: NavMeshParams,
    tiles: std.ArrayListUnmanaged(NavMeshTile),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, params: NavMeshParams) !NavMesh {
        return NavMesh{
            .params = params,
            .tiles = .{},
            .allocator = allocator,
        };
    }

    // Обработка ошибок вместо возврата статусов
    pub fn addTile(self: *NavMesh, data: []const u8) !void {
        if (data.len == 0) return error.EmptyTileData;
        // ...
    }
};
```

### **Фаза 6: Оптимизации и безопасность**

```zig
// Использование comptime для специализации
pub fn buildNavMesh(
    comptime build_type: BuildType,
    allocator: std.mem.Allocator,
    settings: NavMeshBuildSettings,
) !NavMesh {
    return switch (build_type) {
        .high_quality => try HighQualityBuilder.build(allocator, settings),
        .fast => try FastBuilder.build(allocator, settings),
    };
}

// Безопасные интерфейсы с проверками
pub fn findPath(
    self: *const NavMesh,
    start: Vec3,
    end: Vec3,
    path: *std.ArrayList(Vec3),
) !void {
    if (!self.isPointInMesh(start)) return error.StartPointOutsideMesh;
    if (!self.isPointInMesh(end)) return error.EndPointOutsideMesh;

    // Реализация поиска пути
}
```

### **Фаза 7: Тестирование и валидация**

```zig
// test/recast_test.zig
test "heightfield creation and destruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var hf = try Heightfield.init(arena.allocator(), 100, 100);
    // автоматическое освобождение через defer
}

test "navmesh pathfinding" {
    const mesh = try createTestNavMesh(std.testing.allocator);
    defer mesh.deinit();

    const path = try mesh.findPath(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 10, .y = 0, .z = 10 });
    try expect(path.items.len > 0);
}
```

## 🚀 Ключевые улучшения Zig

### **1. Безопасность памяти**

- Явные аллокаторы вместо глобальных malloc/free
- Автоматическое освобождение с `defer`
- Проверки времени компиляции

### **2. Обработка ошибок**

```zig
// Вместо возврата bool/status
pub fn loadTile(self: *NavMesh, data: []const u8) !void {
    if (data.len < @sizeOf(TileHeader))
        return error.InvalidTileData;
    // ...
}
```

### **3. Производительность**

- `comptime` для специализации алгоритмов
- `inline` для критических функций
- Строгая типизация для лучшей оптимизации

### **4. Интероперабельность**

```zig
// Совместимость с C API где необходимо
pub export fn dtCreateNavMesh() ?*dtNavMesh {
    const allocator = std.heap.c_allocator;
    return dtNavMesh.create(allocator) catch return null;
}
```

## 📁 Структура проекта

```
recast-zig/
├── src/
│   ├── main.zig              # Пример использования
│   ├── recast/               # Основной модуль Recast
│   ├── detour/               # Навигация по готовой сетке
│   ├── detour_crowd/         # Управление толпой
│   ├── detour_tilecache/     # Кэширование тайлов
│   ├── math.zig              # Вектора, матрицы, геометрия
│   └── allocator.zig         # Система управления памятью
├── test/
│   ├── recast_test.zig
│   ├── detour_test.zig
│   └── integration_test.zig
├── examples/
│   ├── simple_navmesh.zig
│   └── crowd_simulation.zig
└── build.zig
```

## 🎯 Критерии качества

1. **Полная совместимость** с оригинальным API где это имеет смысл
2. **Нулевые неявные аллокации** - вся память явно управляется
3. **Comprehensive тестирование** с >90% покрытием
4. **Документация** в стиле Zig с примерами
5. **Производительность** не хуже C++ версии
6. **Безопасность** - отсутствие неопределенного поведения
