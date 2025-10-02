# Memory Model

Детальный разбор управления памятью в zig-recast.

---

## Overview

zig-recast использует **explicit allocator pattern** - основополагающий принцип Zig для управления памятью:

**Принципы:**
- ✅ **No hidden allocations** - все аллокации явные
- ✅ **Caller owns memory** - вызывающий владеет памятью
- ✅ **RAII pattern** - init/deinit pairs
- ✅ **No garbage collection** - полный контроль над памятью
- ✅ **No reference counting** - явное владение
- ✅ **Compile-time checks** - Zig проверяет использование памяти

---

## Allocator Pattern

### Базовый паттерн

```zig
const std = @import("std");

pub fn example() !void {
    // 1. Создаем allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // 2. Все структуры принимают allocator
    var heightfield = try Heightfield.init(
        allocator,
        width, height,
        &bmin, &bmax,
        cs, ch,
    );
    defer heightfield.deinit(allocator);  // ОБЯЗАТЕЛЬНО!

    // 3. Используем структуру
    // ...
}
```

### Ownership Rules

**Правило 1: Caller owns**
```zig
// Функция возвращает owned memory
pub fn createNavMeshData(allocator: Allocator, params: *NavMeshCreateParams) ![]u8 {
    const data = try allocator.alloc(u8, total_size);
    // ... fill data ...
    return data;  // Caller must free!
}

// Использование
const nav_data = try createNavMeshData(allocator, &params);
defer allocator.free(nav_data);  // Caller frees
```

**Правило 2: Explicit deinit**
```zig
// Все structures имеют deinit()
pub const Heightfield = struct {
    // ...

    pub fn deinit(self: *Heightfield, allocator: Allocator) void {
        for (self.spans) |span_opt| {
            if (span_opt) |span| {
                self.freeSpanList(allocator, span);
            }
        }
        allocator.free(self.spans);
    }
};

// Использование
var hf = try Heightfield.init(...);
defer hf.deinit(allocator);  // Явный cleanup
```

**Правило 3: No shared ownership**
```zig
// НЕПРАВИЛЬНО - нет shared ownership
var data = try allocator.alloc(u8, 100);
const ptr1 = data;
const ptr2 = data;  // Кто владеет? Кто освобождает?

// ПРАВИЛЬНО - single owner
var data = try allocator.alloc(u8, 100);
defer allocator.free(data);  // Единственный владелец
```

---

## Allocator Types

### 1. GeneralPurposeAllocator (GPA)

**Назначение:** Общего назначения, с leak detection

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,           // Enable safety checks
    .thread_safe = false,     // Single-threaded
    .verbose_log = false,     // No verbose logging
}){};
defer {
    const leaked = gpa.deinit();
    if (leaked == .leak) {
        @panic("Memory leak detected!");
    }
}

const allocator = gpa.allocator();
```

**Использование:**
- ✅ Development & testing
- ✅ Automatic leak detection
- ❌ Production (overhead)

### 2. ArenaAllocator

**Назначение:** Bulk allocation, single free

```zig
var arena = std.heap.ArenaAllocator.init(parent_allocator);
defer arena.deinit();  // Free all at once

const allocator = arena.allocator();

// Allocate много temporary data
const temp1 = try allocator.alloc(u8, 100);
const temp2 = try allocator.alloc(u8, 200);
const temp3 = try allocator.alloc(u8, 300);

// No need to free individually - arena.deinit() frees all
```

**Использование:**
- ✅ Temporary data (pipeline stages)
- ✅ Batch operations
- ✅ Simplifies cleanup
- ❌ Long-lived data (no individual free)

**Пример в Recast:**
```zig
pub fn buildNavMesh(parent_allocator: Allocator, config: Config) !NavMesh {
    // Arena for temporary pipeline data
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();  // Free all temporary data

    const temp_allocator = arena.allocator();

    // All temporary structures use arena
    var heightfield = try Heightfield.init(temp_allocator, ...);
    var compact = try buildCompactHeightfield(ctx, temp_allocator, ...);
    var contours = try buildContours(ctx, temp_allocator, ...);
    // No need to deinit - arena handles it

    // Final NavMesh uses parent_allocator (long-lived)
    const navmesh = try NavMesh.init(parent_allocator);
    return navmesh;
}
```

### 3. FixedBufferAllocator

**Назначение:** Stack-based, no heap allocation

```zig
var buffer: [1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
const allocator = fba.allocator();

// All allocations come from buffer
const data = try allocator.alloc(u8, 100);  // From stack buffer

// OutOfMemory if buffer exhausted
const data2 = try allocator.alloc(u8, 2000);  // Error!
```

**Использование:**
- ✅ Small, bounded allocations
- ✅ No heap fragmentation
- ✅ Embedded systems
- ❌ Variable-sized data

### 4. PageAllocator

**Назначение:** Direct OS allocation (large pages)

```zig
const allocator = std.heap.page_allocator;

// Large allocations
const large_data = try allocator.alloc(u8, 1024 * 1024);  // 1 MB
defer allocator.free(large_data);
```

**Использование:**
- ✅ Large buffers (>4KB)
- ✅ Memory-mapped files
- ❌ Small allocations (waste)

### 5. C Allocator

**Назначение:** Interop с C libraries

```zig
const allocator = std.heap.c_allocator;

// Uses malloc/free
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);
```

---

## Memory Patterns in zig-recast

### Pattern 1: Pipeline Stages

Каждый этап pipeline выделяет и освобождает свои данные:

```zig
pub fn buildNavMeshComplete(allocator: Allocator, config: Config) !NavMesh {
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stage 1: Heightfield
    var heightfield = try Heightfield.init(allocator, ...);
    defer heightfield.deinit(allocator);

    // ... rasterize ...

    // Stage 2: Compact
    var compact = try buildCompactHeightfield(&ctx, allocator, ...);
    defer compact.deinit(allocator);

    // Stage 3: Regions
    try buildDistanceField(&ctx, &compact);
    try buildRegions(&ctx, allocator, &compact, ...);

    // Stage 4: Contours
    var contours = try buildContours(&ctx, allocator, &compact, ...);
    defer contours.deinit(allocator);

    // Stage 5: PolyMesh
    var poly_mesh = try buildPolyMesh(&ctx, allocator, &contours, ...);
    defer poly_mesh.deinit(allocator);

    // Stage 6: DetailMesh
    var detail_mesh = try buildPolyMeshDetail(&ctx, allocator, &poly_mesh, &compact, ...);
    defer detail_mesh.deinit(allocator);

    // Stage 7: NavMesh data (returned to caller)
    const nav_data = try builder.createNavMeshData(allocator, &params);
    return nav_data;  // Caller owns
}
```

### Pattern 2: Temporary Scratch Space

```zig
pub fn processLargeData(allocator: Allocator, data: []const u8) !Result {
    // Arena for scratch space
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    // Temporary buffers
    const temp_buffer = try scratch.alloc(u8, data.len * 2);
    const work_space = try scratch.alloc(WorkItem, 1000);

    // Process...
    const result = processInternal(temp_buffer, work_space, data);

    // Copy result to permanent storage
    const output = try allocator.alloc(u8, result.len);
    @memcpy(output, result);

    return output;  // Scratch freed automatically
}
```

### Pattern 3: Resize/Grow Strategies

```zig
pub fn addItem(self: *ArrayList, item: Item, allocator: Allocator) !void {
    // Need more space?
    if (self.len >= self.capacity) {
        // Grow by 2x
        const new_capacity = self.capacity * 2;
        const new_data = try allocator.alloc(Item, new_capacity);

        // Copy old data
        @memcpy(new_data[0..self.len], self.data[0..self.len]);

        // Free old
        allocator.free(self.data);

        // Update
        self.data = new_data;
        self.capacity = new_capacity;
    }

    // Add item
    self.data[self.len] = item;
    self.len += 1;
}
```

---

## Memory Usage Analysis

### Heightfield Stage

```zig
// Memory usage
const cells = width * height;
const avg_spans_per_cell = 1.5;  // Typical for flat terrain
const span_size = @sizeOf(Span);  // ~32 bytes

const total_spans = cells * avg_spans_per_cell;
const memory = total_spans * span_size;

// Example: 100x100 grid
// 10,000 cells * 1.5 * 32 = 480 KB
```

**Optimization:**
- Use arena for span allocation
- Pre-allocate span pool if span count known

### Compact Heightfield Stage

```zig
// More efficient than Heightfield
const span_count = countWalkableSpans(heightfield);
const compact_span_size = @sizeOf(CompactSpan);  // ~16 bytes
const cell_size = @sizeOf(CompactCell);  // ~8 bytes

const memory =
    (width * height * cell_size) +  // Cells
    (span_count * compact_span_size) +  // Spans
    (span_count * @sizeOf(u8));  // Areas

// Example: 10,000 cells, 15,000 spans
// 10,000 * 8 + 15,000 * 16 + 15,000 * 1 = 335 KB
```

### Region Building Stage

```zig
// Distance field (uses compact.max_distance for stacks)
const max_distance: u32 = 100;  // Typical
const stacks = try allocator.alloc(std.ArrayList(u32), max_distance + 1);
defer {
    for (stacks) |stack| stack.deinit();
    allocator.free(stacks);
}

// Memory: ~100 stacks * ~100 items * 4 bytes = ~40 KB
```

### NavMesh Data

```zig
// Final NavMesh data size
const vert_count: usize = 500;
const poly_count: usize = 400;
const link_count: usize = 1200;
const detail_vert_count: usize = 2000;
const detail_tri_count: usize = 1500;

const size =
    @sizeOf(MeshHeader) +  // 88 bytes
    (vert_count * 12) +  // Vertices (x,y,z floats)
    (poly_count * @sizeOf(Poly)) +  // ~40 bytes each
    (link_count * @sizeOf(Link)) +  // ~16 bytes each
    (detail_vert_count * 12) +  // Detail verts
    (detail_tri_count * 4) +  // Detail tris
    (poly_count * 2 * @sizeOf(BVNode));  // BVH tree

// Example calculation:
// 88 + 6,000 + 16,000 + 19,200 + 24,000 + 6,000 + 64,000
// ≈ 135 KB
```

### NavMeshQuery

```zig
const max_nodes: usize = 2048;
const node_size = @sizeOf(Node);  // ~44 bytes
const hash_size = nextPow2(max_nodes / 4);  // 512

const memory =
    (max_nodes * node_size) +  // Nodes: ~90 KB
    (hash_size * 4) +  // Hash table: 2 KB
    (max_nodes * 4) +  // Next table: 8 KB
    (max_nodes * 8) +  // Open list: 16 KB
    (64 * node_size);  // Tiny pool: ~3 KB

// Total: ~120 KB
```

---

## Memory Leak Detection

### Debug Mode

```zig
// GPA automatically detects leaks in Debug mode
test "no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expect(leaked == .ok);  // Fails if leak
    }

    const allocator = gpa.allocator();

    var heightfield = try Heightfield.init(allocator, ...);
    defer heightfield.deinit(allocator);

    // Test operations...
}
```

### Manual Tracking

```zig
const Tracker = struct {
    allocations: usize = 0,
    deallocations: usize = 0,

    fn track(self: *Tracker, allocator: Allocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ...) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        // ... actual allocation ...
    }

    fn free(ctx: *anyopaque, buf: []u8, ...) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.deallocations += 1;
        // ... actual free ...
    }
};
```

---

## Best Practices

### 1. Use Arena for Temporary Data

```zig
// GOOD - arena for temporary data
pub fn processData(allocator: Allocator, input: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const temp = arena.allocator();

    const buffer1 = try temp.alloc(u8, 1000);
    const buffer2 = try temp.alloc(u8, 2000);
    // No individual frees needed
}

// BAD - manual tracking
pub fn processDataBad(allocator: Allocator, input: []const u8) !Result {
    const buffer1 = try allocator.alloc(u8, 1000);
    defer allocator.free(buffer1);

    const buffer2 = try allocator.alloc(u8, 2000);
    defer allocator.free(buffer2);

    // Error-prone if early returns
}
```

### 2. Defer Cleanup Immediately

```zig
// GOOD - defer immediately after allocation
var data = try allocator.alloc(u8, 100);
defer allocator.free(data);

// BAD - defer later (easy to forget, errors in between)
var data = try allocator.alloc(u8, 100);
// ... много кода ...
defer allocator.free(data);  // Might be skipped if error
```

### 3. Use comptime for Fixed Sizes

```zig
// GOOD - stack allocation for known size
fn processSmallArray(items: [10]u32) void {
    // No allocation needed
}

// BAD - heap allocation for fixed size
fn processSmallArrayBad(allocator: Allocator) !void {
    const items = try allocator.alloc(u32, 10);
    defer allocator.free(items);
}
```

### 4. Return Owned Slices

```zig
// GOOD - clear ownership
pub fn createData(allocator: Allocator) ![]u8 {
    const data = try allocator.alloc(u8, 100);
    return data;  // Caller owns
}

// Usage
const data = try createData(allocator);
defer allocator.free(data);

// BAD - unclear ownership
pub fn createDataBad(allocator: Allocator) ![]u8 {
    var data = try allocator.alloc(u8, 100);
    // ... fill data ...
    return data;  // Who frees? Caller? Function?
    // Document it!
}
```

### 5. Document Ownership

```zig
/// Creates NavMesh data. Caller owns returned memory.
/// Use `allocator.free()` to free.
pub fn createNavMeshData(
    allocator: Allocator,
    params: *NavMeshCreateParams,
) ![]u8 {
    // ...
}

/// Initializes NavMesh. Caller must call `deinit()`.
pub fn init(allocator: Allocator) !NavMesh {
    // ...
}
```

---

## Common Patterns

### Pattern 1: Init/Deinit Pair

```zig
pub const MyStruct = struct {
    data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, size: usize) !MyStruct {
        const data = try allocator.alloc(u8, size);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MyStruct) void {
        self.allocator.free(self.data);
    }
};

// Usage
var my_struct = try MyStruct.init(allocator, 100);
defer my_struct.deinit();
```

### Pattern 2: ArrayList-style

```zig
pub const DynamicArray = struct {
    items: []Item,
    len: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) DynamicArray {
        return .{
            .items = &.{},
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicArray) void {
        self.allocator.free(self.items);
    }

    pub fn append(self: *DynamicArray, item: Item) !void {
        if (self.len >= self.items.len) {
            const new_cap = @max(self.items.len * 2, 8);
            self.items = try self.allocator.realloc(self.items, new_cap);
        }
        self.items[self.len] = item;
        self.len += 1;
    }
};
```

### Pattern 3: Builder Pattern

```zig
pub const NavMeshBuilder = struct {
    allocator: Allocator,
    config: Config,
    heightfield: ?Heightfield = null,
    compact: ?CompactHeightfield = null,

    pub fn init(allocator: Allocator, config: Config) NavMeshBuilder {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *NavMeshBuilder) void {
        if (self.heightfield) |*hf| hf.deinit(self.allocator);
        if (self.compact) |*c| c.deinit(self.allocator);
    }

    pub fn buildHeightfield(self: *NavMeshBuilder) !void {
        self.heightfield = try Heightfield.init(self.allocator, ...);
    }

    pub fn buildCompact(self: *NavMeshBuilder) !void {
        self.compact = try buildCompactHeightfield(...);
    }
};
```

---

## Testing Memory Safety

### Unit Test Example

```zig
test "heightfield memory safety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expect(leaked == .ok);
    }

    const allocator = gpa.allocator();

    var heightfield = try Heightfield.init(
        allocator,
        10, 10,
        &.{ 0, 0, 0 },
        &.{ 10, 10, 10 },
        0.3, 0.2,
    );
    defer heightfield.deinit(allocator);

    // Add some spans
    try heightfield.addSpan(allocator, 5, 5, .{
        .smin = 0,
        .smax = 10,
        .area = 1,
        .next = null,
    });

    // GPA will verify no leaks on deinit
}
```

### Integration Test

```zig
test "full pipeline memory safety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expect(leaked == .ok);
    }

    const allocator = gpa.allocator();

    // Run full pipeline
    const nav_data = try buildNavMeshComplete(allocator, test_config);
    defer allocator.free(nav_data);

    // No leaks should be detected
}
```

---

## Performance Tips

### 1. Pre-allocate When Possible

```zig
// GOOD - single allocation
const items = try allocator.alloc(Item, known_count);
defer allocator.free(items);

for (0..known_count) |i| {
    items[i] = calculateItem(i);
}

// BAD - many allocations
var list = std.ArrayList(Item).init(allocator);
defer list.deinit();

for (0..known_count) |_| {
    try list.append(calculateItem(i));  // May reallocate multiple times
}
```

### 2. Reuse Buffers

```zig
pub const QueryEngine = struct {
    buffer: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, buffer_size: usize) !QueryEngine {
        return .{
            .buffer = try allocator.alloc(u8, buffer_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueryEngine) void {
        self.allocator.free(self.buffer);
    }

    pub fn query(self: *QueryEngine, data: []const u8) !Result {
        // Reuse buffer instead of allocating new one each time
        @memcpy(self.buffer[0..data.len], data);
        return processBuffer(self.buffer[0..data.len]);
    }
};
```

### 3. Use Stack for Small Data

```zig
// GOOD - stack allocation
fn processSmallData() void {
    var buffer: [256]u8 = undefined;
    // Use buffer
}

// BAD - heap for small data
fn processSmallDataBad(allocator: Allocator) !void {
    const buffer = try allocator.alloc(u8, 256);
    defer allocator.free(buffer);
    // Use buffer
}
```

---

## Next Steps

- 📖 [Error Handling](error-handling.md) - обработка ошибок в zig-recast
- 🔍 [Performance Guide](../04-guides/performance.md) - оптимизация памяти
- 🏗️ [Creating NavMesh](../04-guides/creating-navmesh.md) - практическое применение

---

## References

- [Zig Memory Allocators](https://ziglang.org/documentation/master/#Choosing-an-Allocator)
- [RAII in Zig](https://ziglearn.org/chapter-1/#defer)
- [GeneralPurposeAllocator](https://ziglang.org/documentation/master/std/#std.heap.GeneralPurposeAllocator)
