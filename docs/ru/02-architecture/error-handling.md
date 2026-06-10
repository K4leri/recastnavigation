# Error Handling

Детальный разбор обработки ошибок в zig-recast.

---

## Overview

zig-recast использует **error union pattern** - основополагающий подход Zig для обработки ошибок:

**Принципы:**
- ✅ **No exceptions** - нет runtime overhead
- ✅ **Compile-time checks** - компилятор требует обработки ошибок
- ✅ **Explicit errors** - все ошибки явные
- ✅ **Error unions** - `!T` означает "может вернуть ошибку"
- ✅ **No hidden control flow** - нет невидимых `throws`
- ✅ **Zero cost** - if no error, no overhead

---

## Error Union Basics

### Синтаксис

```zig
// Function that can fail
pub fn createNavMesh(allocator: Allocator) !NavMesh {
    // !NavMesh = error!NavMesh = "может вернуть ошибку или NavMesh"

    if (something_wrong) {
        return error.OutOfMemory;
    }

    return NavMesh{ ... };
}

// Usage
const navmesh = try createNavMesh(allocator);  // Propagate error
// OR
const navmesh = createNavMesh(allocator) catch |err| {
    // Handle error
    std.debug.print("Error: {}\n", .{err});
    return err;
};
```

### Error Sets

```zig
// Define custom error set
const NavMeshError = error{
    OutOfMemory,
    InvalidInput,
    FileNotFound,
    CorruptedData,
};

// Function with explicit error set
pub fn loadNavMesh(path: []const u8) NavMeshError!NavMesh {
    // Can only return errors from NavMeshError
}

// Inferred error set
pub fn loadNavMeshAuto(path: []const u8) !NavMesh {
    // Error set inferred from function body
}
```

---

## Error Handling Patterns

### Pattern 1: Try (Propagate Error)

```zig
pub fn buildNavMesh(allocator: Allocator) !NavMesh {
    // Propagate error to caller
    var heightfield = try Heightfield.init(allocator, ...);
    defer heightfield.deinit(allocator);

    // If init() returns error, function returns immediately
    var compact = try buildCompactHeightfield(...);
    defer compact.deinit(allocator);

    return navmesh;
}
```

**Когда использовать:**
- ✅ Error не может быть обработан на текущем уровне
- ✅ Caller должен принять решение
- ✅ Default behavior для большинства случаев

### Pattern 2: Catch (Handle Error)

```zig
pub fn loadNavMeshSafe(path: []const u8, allocator: Allocator) ?NavMesh {
    const navmesh = loadNavMesh(path, allocator) catch |err| {
        std.debug.print("Failed to load: {}\n", .{err});
        return null;  // Return optional instead
    };

    return navmesh;
}

// Or with default value
pub fn getAreaCost(area: u8) f32 {
    return lookupAreaCost(area) catch 1.0;  // Default cost
}
```

**Когда использовать:**
- ✅ Error можно обработать на месте
- ✅ Есть fallback значение
- ✅ Logging/debugging

### Pattern 3: Catch with Payload

```zig
pub fn processData(data: []const u8) !Result {
    const result = parseData(data) catch |err| {
        // Access error value
        switch (err) {
            error.OutOfMemory => {
                std.debug.print("Out of memory!\n", .{});
                return err;  // Re-throw
            },
            error.InvalidInput => {
                std.debug.print("Invalid input, using default\n", .{});
                return Result.default();  // Fallback
            },
            else => return err,
        }
    };

    return result;
}
```

### Pattern 4: Error Unwrapping (If-Else)

```zig
pub fn safeOperation(allocator: Allocator) void {
    const result = dangerousOperation(allocator);

    if (result) |value| {
        // Success - use value
        processValue(value);
    } else |err| {
        // Error - handle
        std.debug.print("Error: {}\n", .{err});
    }
}
```

---

## Common Error Types in zig-recast

### 1. Memory Errors

```zig
const MemoryError = error{
    OutOfMemory,
};

pub fn allocateLargeBuffer(allocator: Allocator, size: usize) ![]u8 {
    return allocator.alloc(u8, size);  // May return OutOfMemory
}

// Usage
const buffer = try allocateLargeBuffer(allocator, 1000000);
defer allocator.free(buffer);
```

### 2. Validation Errors

```zig
const ValidationError = error{
    InvalidParam,
    InvalidInput,
    NullPointer,
};

pub fn validateConfig(config: *const Config) ValidationError!void {
    if (config.cs <= 0) return error.InvalidParam;
    if (config.ch <= 0) return error.InvalidParam;
    if (config.walkable_height == 0) return error.InvalidParam;
}

// Usage
try validateConfig(&config);  // Will propagate if invalid
```

### 3. State Errors

```zig
const StateError = error{
    NoNavMesh,
    NotInitialized,
    AlreadyInitialized,
};

pub const NavMeshQuery = struct {
    nav: ?*const NavMesh,

    pub fn findPath(...) StateError!usize {
        const nav = self.nav orelse return error.NoNavMesh;

        // Use nav...
    }
};
```

### 4. Data Errors

```zig
const DataError = error{
    CorruptedData,
    InvalidMagic,
    InvalidVersion,
    ChecksumMismatch,
};

pub fn loadNavMeshData(data: []const u8) DataError!NavMesh {
    if (data.len < 4) return error.CorruptedData;

    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != NAVMESH_MAGIC) return error.InvalidMagic;

    // ...
}
```

---

## Error Handling in Pipeline

### Recast Pipeline

```zig
pub fn buildNavMeshComplete(
    allocator: Allocator,
    config: Config,
) !NavMesh {
    // Validate config
    try validateConfig(&config);

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stage 1: Heightfield
    var heightfield = try Heightfield.init(allocator, ...) catch |err| {
        ctx.log(.Error, "Failed to create heightfield: {}", .{err});
        return err;
    };
    defer heightfield.deinit(allocator);

    // Stage 2: Rasterization
    try rasterizeTriangles(&ctx, ...) catch |err| {
        ctx.log(.Error, "Rasterization failed: {}", .{err});
        return err;
    };

    // Stage 3: Compact
    var compact = try buildCompactHeightfield(&ctx, allocator, ...) catch |err| {
        ctx.log(.Error, "Compaction failed: {}", .{err});
        return err;
    };
    defer compact.deinit(allocator);

    // ... остальные этапы ...

    return navmesh;
}
```

### Detour Queries

```zig
pub fn findPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    path: []PolyRef,
) !usize {
    // Validate input
    if (start_ref == 0 or end_ref == 0) {
        return error.InvalidParam;
    }

    const nav = self.nav orelse return error.NoNavMesh;

    // Validate poly refs
    _ = nav.getTileAndPolyByRef(start_ref) catch |err| {
        std.debug.print("Invalid start_ref: {}\n", .{err});
        return error.InvalidParam;
    };

    _ = nav.getTileAndPolyByRef(end_ref) catch |err| {
        std.debug.print("Invalid end_ref: {}\n", .{err});
        return error.InvalidParam;
    };

    // Perform A*
    return performAStar(...);
}
```

---

## Status Pattern (C++ Compatibility)

Для совместимости с C++ API, используется `Status` structure:

```zig
pub const Status = struct {
    failure: bool = false,
    success: bool = false,
    in_progress: bool = false,
    partial_result: bool = false,

    // Error flags
    invalid_param: bool = false,
    buffer_too_small: bool = false,

    pub fn ok() Status {
        return .{ .success = true };
    }

    pub fn failed() Status {
        return .{ .failure = true };
    }

    pub fn isSuccess(self: Status) bool {
        return self.success;
    }

    pub fn isFailure(self: Status) bool {
        return self.failure;
    }
};

// Usage
pub fn findPath(...) !Status {
    if (invalid_input) {
        return Status{
            .failure = true,
            .invalid_param = true,
        };
    }

    if (path.len < result_size) {
        return Status{
            .success = true,
            .partial_result = true,
            .buffer_too_small = true,
        };
    }

    return Status.ok();
}

// Calling code
const status = try query.findPath(...);

if (status.isFailure()) {
    if (status.invalid_param) {
        std.debug.print("Invalid parameters\n", .{});
    }
} else if (status.buffer_too_small) {
    std.debug.print("Warning: partial result\n", .{});
}
```

---

## Error Context & Logging

### Context Logging

```zig
pub const Context = struct {
    allocator: Allocator,
    log_enabled: bool = true,
    timer_enabled: bool = false,

    pub const LogCategory = enum {
        Error,
        Warning,
        Info,
        Debug,
    };

    pub fn log(
        self: *Context,
        category: LogCategory,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (!self.log_enabled) return;

        const prefix = switch (category) {
            .Error => "[ERROR] ",
            .Warning => "[WARN]  ",
            .Info => "[INFO]  ",
            .Debug => "[DEBUG] ",
        };

        std.debug.print(prefix ++ fmt ++ "\n", args);
    }
};

// Usage
ctx.log(.Error, "Failed to allocate {d} bytes", .{size});
ctx.log(.Warning, "Polygon count exceeds recommended limit", .{});
ctx.log(.Info, "NavMesh built with {d} polygons", .{poly_count});
```

### Error Recovery

```zig
pub fn buildRegionsRobust(
    ctx: *Context,
    allocator: Allocator,
    compact: *CompactHeightfield,
    min_region_area: u32,
    merge_region_area: u32,
) !void {
    // Try watershed algorithm
    buildRegions(ctx, allocator, compact, min_region_area, merge_region_area) catch |err| {
        ctx.log(.Warning, "Watershed failed: {}, trying fallback", .{err});

        // Fallback: simpler region building
        buildRegionsSimple(ctx, allocator, compact) catch |fallback_err| {
            ctx.log(.Error, "Fallback also failed: {}", .{fallback_err});
            return fallback_err;
        };

        ctx.log(.Info, "Fallback succeeded", .{});
    };
}
```

---

## Assertions vs Errors

### When to Use Assertions

```zig
// Assertions for programmer errors (bugs)
pub fn addSpan(self: *Heightfield, x: u32, y: u32, span: Span) void {
    std.debug.assert(x < self.width);   // Bug if violated
    std.debug.assert(y < self.height);  // Bug if violated

    // Add span...
}

// Removed in ReleaseFast
```

### When to Use Errors

```zig
// Errors for runtime failures
pub fn loadNavMesh(path: []const u8) !NavMesh {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        // Runtime error - file might not exist
        return err;
    };
    defer file.close();

    // Read and parse...
}
```

**Правило:**
- **Assertions**: programmer errors, bugs, preconditions
- **Errors**: runtime failures, user input, external data

---

## Testing Error Paths

### Unit Tests

```zig
test "heightfield init - invalid params" {
    const allocator = std.testing.allocator;

    // Should fail with invalid width
    const result = Heightfield.init(
        allocator,
        0,  // Invalid!
        10,
        &.{ 0, 0, 0 },
        &.{ 10, 10, 10 },
        0.3,
        0.2,
    );

    try std.testing.expectError(error.InvalidParam, result);
}

test "navmesh query - no navmesh" {
    const allocator = std.testing.allocator;

    var query = try NavMeshQuery.init(allocator, null, 2048);
    defer query.deinit();

    var start_ref: PolyRef = 0;
    const result = query.findNearestPoly(&.{ 0, 0, 0 }, &.{ 1, 1, 1 }, &QueryFilter.init(), &start_ref, null);

    try std.testing.expectError(error.NoNavMesh, result);
}
```

### Integration Tests

```zig
test "pipeline - corrupted input" {
    const allocator = std.testing.allocator;

    // Corrupted mesh data
    const vertices = [_]f32{
        std.math.nan(f32),  // Invalid!
        0.0,
        0.0,
    };

    const result = buildNavMesh(allocator, &vertices, ...);

    try std.testing.expectError(error.InvalidInput, result);
}
```

---

## Best Practices

### 1. Always Handle Errors

```zig
// GOOD - explicit error handling
const navmesh = try createNavMesh(allocator);
defer navmesh.deinit();

// GOOD - catch with fallback
const navmesh = createNavMesh(allocator) catch {
    std.debug.print("Using default navmesh\n", .{});
    return NavMesh.default();
};

// BAD - ignoring errors (compilation error!)
const navmesh = createNavMesh(allocator);  // ERROR: must handle error
```

### 2. Use Descriptive Error Names

```zig
// GOOD
return error.WalkableHeightTooSmall;
return error.InvalidPolyRefSalt;

// BAD
return error.Error;
return error.Fail;
```

### 3. Log Before Returning Error

```zig
// GOOD
pub fn buildRegions(...) !void {
    if (compact.span_count == 0) {
        ctx.log(.Error, "No spans in compact heightfield", .{});
        return error.InvalidInput;
    }

    // ...
}

// Usage provides context
```

### 4. Defer for Cleanup on Error

```zig
// GOOD - defer ensures cleanup even on error
pub fn complexOperation(allocator: Allocator) !Result {
    var buffer1 = try allocator.alloc(u8, 100);
    defer allocator.free(buffer1);  // Freed even if error below

    var buffer2 = try allocator.alloc(u8, 200);
    defer allocator.free(buffer2);

    try riskyOperation(buffer1, buffer2);  // May error, but cleanup still happens

    return result;
}

// BAD - manual cleanup
pub fn complexOperationBad(allocator: Allocator) !Result {
    var buffer1 = try allocator.alloc(u8, 100);
    var buffer2 = try allocator.alloc(u8, 200);

    riskyOperation(buffer1, buffer2) catch |err| {
        allocator.free(buffer2);  // Easy to forget!
        allocator.free(buffer1);
        return err;
    };

    allocator.free(buffer2);
    allocator.free(buffer1);
    return result;
}
```

### 5. Error Unions in Return Types

```zig
// GOOD - explicit error set
pub fn loadFile(path: []const u8) FileError![]u8 {
    // ...
}

// GOOD - inferred error set
pub fn processData(data: []const u8) !Result {
    // ...
}

// GOOD - no errors
pub fn calculateDistance(a: [3]f32, b: [3]f32) f32 {
    // Cannot fail
}

// BAD - optional when error union is better
pub fn loadFileBad(path: []const u8) ?[]u8 {
    // Lost error information!
}
```

---

## Common Errors in zig-recast

### OutOfMemory

**Причина:**
- Allocator не может выделить память
- Слишком большой NavMesh
- Недостаточно RAM

**Обработка:**
```zig
const navmesh = createNavMesh(allocator, &config) catch |err| {
    if (err == error.OutOfMemory) {
        std.debug.print("Out of memory. Try reducing:\n", .{});
        std.debug.print("  - Cell size (cs)\n", .{});
        std.debug.print("  - Max nodes in query\n", .{});
        return err;
    }
    return err;
};
```

### InvalidParam

**Причина:**
- Неправильные параметры конфигурации
- Нулевые ссылки
- Некорректные bounds

**Обработка:**
```zig
try validateConfig(&config);  // Validate early

// Or handle
validateConfig(&config) catch |err| {
    std.debug.print("Invalid config: {}\n", .{err});
    config = Config.default();  // Use defaults
};
```

### NoNavMesh

**Причина:**
- NavMeshQuery не инициализирован
- NavMesh не загружен

**Обработка:**
```zig
const path_count = query.findPath(...) catch |err| {
    if (err == error.NoNavMesh) {
        std.debug.print("NavMesh not loaded!\n", .{});
        // Load navmesh...
    }
    return err;
};
```

---

## Advanced Patterns

### Error Chaining

```zig
pub fn loadAndProcessNavMesh(path: []const u8, allocator: Allocator) !NavMesh {
    // Chain of operations, any can fail
    const data = try loadFile(path, allocator);
    defer allocator.free(data);

    const header = try parseHeader(data);
    try validateHeader(&header);

    const navmesh = try deserializeNavMesh(data, allocator);
    try validateNavMesh(&navmesh);

    return navmesh;
}
```

### Result Type Pattern

```zig
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,

        pub fn unwrap(self: Result(T)) !T {
            return switch (self) {
                .ok => |value| value,
                .err => |e| e,
            };
        }
    };
}

// Usage
pub fn compute() Result(f32) {
    if (something_wrong) {
        return .{ .err = error.Failed };
    }
    return .{ .ok = 42.0 };
}
```

---

## Next Steps

- 📖 [Memory Model](memory-model.md) - управление памятью
- 🔍 [Creating NavMesh Guide](../04-guides/creating-navmesh.md) - практическое руководство
- 🧪 [Testing Guide](../04-guides/testing.md) - тестирование с ошибками

---

## References

- [Zig Error Handling](https://ziglang.org/documentation/master/#Errors)
- [Error Union Type](https://ziglang.org/documentation/master/#Error-Union-Type)
- [Error Set Type](https://ziglang.org/documentation/master/#Error-Set-Type)
