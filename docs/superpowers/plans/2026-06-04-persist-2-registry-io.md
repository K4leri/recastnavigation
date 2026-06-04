# Persist module 2 — registry_io (area/flag реестры ⇄ диск) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: используй superpowers:subagent-driven-development или superpowers:executing-plans для пошаговой реализации. Шаги используют checkbox (`- [ ]`) для трекинга.

**Goal:** сериализовать runtime-реестры area-типов (`area_types.zig`, 64 слота: name/rgba/flags:u16/cost:f32/builtin/used) и poly-флагов (`poly_flags.zig`, 16 слотов: name/bit/builtin) в бинарные файлы `edits/areas.reg` и `edits/flags.reg` контейнера `.recastscene/` и обратно — durably (atomic write + XXH3-checksum + версия), с graceful degradation на битых данных. Загрузка восстанавливает РОВНО сохранённое состояние (минуя auto-bit/auto-id-allocation), поэтому в реестры добавляются публичные restore-функции.

**Architecture:**
- Новый файл `demo/src/persist/registry_io.zig` — два save/load-пары (`saveAreas`/`loadAreas`, `saveFlags`/`loadFlags`) поверх примитивов **модуля 1** (`write_atomic.zig` + `checksum.zig`/chunk-header). Формат файла = `[file header][record...]` (модель PNG/glTF, как описано в foundation-design §3.b и navmesh_io.zig). Каждая запись — один used-слот реестра.
- Дополнения в `area_types.zig` / `poly_flags.zig`: публичные `restoreType(...)` / `restoreFlag(...)` / `resetToBuiltins()`. Restore пишет в точный слот по id/bit (НЕ авто-аллокация), сохраняя builtin-семантику. `resetToBuiltins()` сбрасывает реестр к seed-состоянию перед загрузкой.
- **Порядок загрузки (инвариант foundation):** flags ДО areas (areas ссылаются на биты флагов). На уровне контейнера: реестры (flags→areas) ДО geom/volumes/offmesh ДО rebuild.
- Реестры пока остаются **module-global** (`var types`/`var flags`) — это согласуется с тем, что вынос в `Scene`-инстанс — отдельный foundation-шаг 5. registry_io работает с module-API напрямую; когда реестры станут полями `Scene`, сигнатуры save/load получат `*AreaRegistry`/`*FlagRegistry` без смены формата.

**Tech Stack:** Zig 0.16.0 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`). Реестры чисто-логические (std-only зависимости через `recast.debug.rgba`) → unit-тесты round-trip через `zig test`. Запись на диск (atomic/fsync) тестируется integration-тестом во временной директории. Перед `zig build` снимать proxy-env (`$env:http_proxy`/`$env:https_proxy`).

> **Зависимость от модуля 1 (ОБЯЗАТЕЛЬНА, реализуется ПЕРВЫМ):** этот модуль использует из `demo/src/persist/`:
> - `write_atomic.writeAtomic(io, dir, name, bytes) !void` — atomic durable запись.
> - `checksum.xxh3(bytes) u64` — XXH3/xxHash64.
> - `checksum.ChunkHeader` (pack/unpack) + `checksum.FileHeader` — заголовок `magic:u32, version:u32, type_flags:u16, payload_len:u64, checksum:u64`, где `checksum = xxh3(type_flags_le ++ header_без_csum ++ payload)`.
> - Ошибки `error.Truncated`/`error.WrongMagic`/`error.WrongVersion`/`error.ChecksumMismatch` (реэкспорт из navmesh_io + новая ChecksumMismatch).
>
> Если на момент реализации модуля 1 эти имена отличаются — адаптировать вызовы в Задачах 3-4, формат записей НЕ меняя. Ниже в плане приведён локальный fallback-хелпер на случай, если модуль 1 ещё не готов (помечен **FALLBACK**), чтобы registry_io можно было разрабатывать/тестировать независимо.

---

## File Structure

- **Modify** `demo/src/poly_flags.zig` — добавить `pub fn resetToBuiltins() void` и `pub fn restoreFlag(bit_index: usize, nm: []const u8, builtin: bool) void`. Чисто аддитивно (новые публичные функции, существующее поведение не меняется).
- **Modify** `demo/src/area_types.zig` — добавить `pub fn resetToBuiltins() void` и `pub fn restoreType(id: usize, t: AreaType) void`. Аддитивно.
- **Create** `demo/src/persist/registry_io.zig` — `saveAreas`/`loadAreas`/`saveFlags`/`loadFlags` + внутренний Reader/put-хелперы + self-test блок (round-trip in-memory) + integration-тест (диск).

Порядок реализации: **Задача 1 (poly_flags restore) → Задача 2 (area_types restore) → Задача 3 (flags.reg I/O) → Задача 4 (areas.reg I/O) → Задача 5 (integration + build)**. Задачи 1-2 разблокируют 3-4 (restore нужен для load). Flags-пара (3) идёт раньше areas-пары (4), повторяя инвариант порядка загрузки.

---

## Формат файлов (нормативный)

Оба файла: `[FileHeader][Record 0][Record 1]...`. Числа little-endian (как navmesh_io.zig `std.mem.readInt(..., .little)`).

**FileHeader** (per-domain magic, общий layout из foundation §3.b):
```
magic:       u32   // areas.reg = 0x41524547 ('AREG'); flags.reg = 0x464C4547 ('FLEG')
version:     u32   // = REG_VERSION (1)
type_flags:  u16   // 0 = file header
payload_len: u64   // число записей (record count) — НЕ байты; reader итерирует по count
checksum:    u64   // xxh3 по всему телу файла (все записи) — детект bitrot файла целиком
```

**Area record** (areas.reg, фикс-длина — у AreaType нет переменной части кроме имени, которое пишем фикс-буфером 24 байта + длина):
```
type_flags:  u16   // 1 = area record; bit0 of high byte зарезервирован под builtin? -> НЕТ, builtin отдельным полем
id:          u8    // слот 0..63 (целевой слот для restoreType)
builtin:     u8    // 0/1
r,g,b,a:     u8 x4
flags:       u16   // poly-flags bitmask
cost:        f32
name_len:    u8    // 0..24
name:        [24]u8 // фикс-буфер (NAME_CAP area_types = 24); хвост нулями
csum:        u64   // xxh3(record_bytes_без_csum)
```
Размер area record = 2+1+1+4+2+4+1+24+8 = 47 байт.

**Flag record** (flags.reg):
```
type_flags:  u16   // 1 = flag record
bit_index:   u8    // 0..15 (целевой слот для restoreFlag)
builtin:     u8    // 0/1
name_len:    u8    // 0..20 (NAME_CAP poly_flags = 20)
name:        [20]u8
csum:        u64   // xxh3(record_bytes_без_csum)
```
Размер flag record = 2+1+1+1+20+8 = 33 байта.

> Per-record csum + file-level csum избыточны намеренно: file-csum даёт быстрый «всё-или-ничего» при загрузке, per-record csum позволяет пропустить ОДНУ битую запись и грузить остальные (graceful degradation, foundation §3.b). При несовпадении file-csum reader НЕ падает — переходит к per-record валидации.

---

## Task 1: poly_flags.zig — resetToBuiltins + restoreFlag

**Files:**
- Modify: `demo/src/poly_flags.zig`
- Test: тот же файл (расширить/добавить `test` блок)

- [ ] **Step 1.1: добавить restore-функции**

В `poly_flags.zig` после `removeFlag` (конец файла) добавить:

```zig
/// Сбросить реестр к seed-состоянию (walk/swim/door/jump + reserved). Используется
/// загрузкой реестра (registry_io) ПЕРЕД применением сохранённых флагов, чтобы
/// получить ровно сохранённое состояние без авто-аллокации бит.
pub fn resetToBuiltins() void {
    initialized = false;
    ensureInit();
}

/// Восстановить флаг в ТОЧНЫЙ слот `bit_index` (минуя auto-bit-allocation addFlag).
/// builtin-слоты (0..3) при загрузке только переименовываются (имя редактируемо),
/// reserved-бит (RESERVED_BIT) игнорируется. Кастомные флаги (builtin=false)
/// занимают свободный слот как used. No-op при выходе за диапазон или попадании
/// в reserved-бит.
pub fn restoreFlag(bit_index: usize, nm: []const u8, builtin: bool) void {
    ensureInit();
    if (bit_index >= MAX_FLAGS) return;
    const bit = @as(u16, 1) << @intCast(bit_index);
    if (bit == RESERVED_BIT) return;
    flags[bit_index] = .{ .used = true, .builtin = builtin };
    flags[bit_index].setName(nm);
}
```

- [ ] **Step 1.2: тест restore**

Добавить в конец `poly_flags.zig`:

```zig
test "restoreFlag overwrites exact slot, resetToBuiltins reseeds" {
    resetToBuiltins();
    try std.testing.expectEqualStrings("walk", get(0).?.name());
    // переименовать builtin + добавить кастомный в слот 5
    restoreFlag(0, "stride", true);
    restoreFlag(5, "ladder", false);
    try std.testing.expectEqualStrings("stride", get(0).?.name());
    try std.testing.expect(get(0).?.builtin);
    try std.testing.expectEqualStrings("ladder", get(5).?.name());
    try std.testing.expect(!get(5).?.builtin);
    try std.testing.expectEqual(@as(?u16, 1 << 5), bitOf(5));
    // reserved-бит игнорируется
    restoreFlag(4, "nope", false); // bit 4 = RESERVED_BIT
    try std.testing.expectEqual(@as(?u16, null), bitOf(4));
    // reset стирает кастомный
    resetToBuiltins();
    try std.testing.expectEqual(@as(?*Flag, null), get(5));
    try std.testing.expectEqualStrings("walk", get(0).?.name());
}
```

Команда теста:
```powershell
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test "E:\Projects\CS2\navMesh\movement\fullProject\recast\zig-recast\demo\src\poly_flags.zig" --dep recast-nav -Mroot=...
```
> ВНИМАНИЕ: `poly_flags.zig` импортирует `sample.zig`, который тянет `dvui`/`recast`. Standalone `zig test` НЕ скомпилируется без модуль-графа. Поэтому Задачи 1-2 тестируются через `zig build demo-test` (integration, см. Задачу 5), а не одиночным `zig test`. Тест-блоки пишем здесь, запускаем в Задаче 5.

**Verify:** `RESERVED_BIT = sample.SamplePolyFlags.disabled = 0x10` (bit 4) — restore слота 4 = no-op, подтверждено sample.zig:34.

---

## Task 2: area_types.zig — resetToBuiltins + restoreType

**Files:**
- Modify: `demo/src/area_types.zig`
- Test: тот же файл

- [ ] **Step 2.1: добавить restore-функции**

В `area_types.zig` после `removeType` (конец файла) добавить:

```zig
/// Сбросить реестр к seed-состоянию (Ground..Jump). Используется загрузкой реестра
/// ПЕРЕД применением сохранённых типов, чтобы builtin-цвета/cost/имена вернулись к
/// дефолтам, а затем были перезаписаны ровно сохранённым состоянием.
pub fn resetToBuiltins() void {
    initialized = false;
    ensureInit();
}

/// Восстановить тип в ТОЧНЫЙ слот `id` (минуя auto-id-allocation addType). Копирует
/// все поля из `t` (used/builtin/name/rgba/flags/cost) как есть — load передаёт ровно
/// то, что было сохранено, включая отредактированные builtin cost/color. No-op при
/// id вне диапазона.
pub fn restoreType(id: usize, t: AreaType) void {
    ensureInit();
    if (id >= MAX_AREA_TYPES) return;
    types[id] = t;
}
```

> `restoreType` принимает готовый `AreaType` (а не россыпь аргументов) — это компактнее для call-site в load и тривиально расширяемо при добавлении полей. `name_buf`/`name_len` уже внутри `AreaType`, копируются value-семантикой.

- [ ] **Step 2.2: тест restore**

Добавить в `area_types.zig`:

```zig
test "restoreType overwrites exact slot, resetToBuiltins reseeds" {
    resetToBuiltins();
    try std.testing.expectEqualStrings("Ground", get(0).?.name());
    try std.testing.expectEqual(@as(f32, 1.0), get(0).?.cost);
    // отредактировать builtin Ground (cost+color) и восстановить
    var edited = get(0).?.*;
    edited.cost = 3.5;
    edited.r = 10;
    edited.g = 20;
    edited.b = 30;
    restoreType(0, edited);
    try std.testing.expectEqual(@as(f32, 3.5), get(0).?.cost);
    try std.testing.expectEqual(@as(u8, 10), get(0).?.r);
    try std.testing.expect(get(0).?.builtin); // builtin сохранён
    // кастомный тип в слот 40
    var custom = AreaType{ .used = true, .builtin = false, .r = 1, .g = 2, .b = 3, .a = 4, .flags = 0x09, .cost = 7.0 };
    custom.setName("Lava");
    restoreType(40, custom);
    try std.testing.expectEqualStrings("Lava", get(40).?.name());
    try std.testing.expectEqual(@as(u16, 0x09), get(40).?.flags);
    // reset стирает кастомный и возвращает Ground.cost=1.0
    resetToBuiltins();
    try std.testing.expectEqual(@as(?*AreaType, null), get(40));
    try std.testing.expectEqual(@as(f32, 1.0), get(0).?.cost);
}
```

(Запуск — Задача 5, причина та же: `area_types.zig` импортирует `recast`/`sample`.)

---

## Task 3: registry_io.zig — flags.reg (save/load) + примитивы

**Files:**
- Create: `demo/src/persist/registry_io.zig`
- Test: self-test блок in-memory (Задача 5 — диск)

- [ ] **Step 3.1: создать файл с шапкой, импортами, put/Reader-хелперами**

```zig
//! Сериализация runtime-реестров area-типов и poly-флагов в edits/areas.reg и
//! edits/flags.reg контейнера .recastscene/ и обратно.
//!
//! Формат: [FileHeader][Record...] — самоописывающиеся чанки (модель PNG/glTF,
//! см. foundation-design §3.b). FileHeader.checksum = xxh3 по телу файла;
//! каждая запись несёт свой per-record xxh3 для graceful degradation (битая
//! запись пропускается, остальные грузятся).
//!
//! ПОРЯДОК ЗАГРУЗКИ (инвариант): флаги ДО area-типов (area-типы ссылаются на биты
//! флагов через поле flags:u16). На уровне контейнера реестры грузятся ДО
//! geom/volumes/offmesh ДО rebuild.
//!
//! Зависит от модуля 1 (persist/write_atomic.zig + persist/checksum.zig):
//! writeAtomic / xxh3. См. FALLBACK-блок, если модуль 1 ещё не готов.

const std = @import("std");
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");

// === зависимость от модуля 1 ===
const write_atomic = @import("write_atomic.zig");
const checksum = @import("checksum.zig");
const writeAtomic = write_atomic.writeAtomic;
const xxh3 = checksum.xxh3;

pub const Error = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
} || std.mem.Allocator.Error;

const REG_VERSION: u32 = 1;
const AREAS_MAGIC: u32 = 0x41524547; // 'AREG'
const FLAGS_MAGIC: u32 = 0x464C4547; // 'FLEG'

const TYPE_FILE_HEADER: u16 = 0;
const TYPE_RECORD: u16 = 1;

const AREA_NAME_CAP: usize = 24; // area_types NAME_CAP
const FLAG_NAME_CAP: usize = 20; // poly_flags NAME_CAP
const AREA_REC_LEN: usize = 47;
const FLAG_REC_LEN: usize = 33;

// --- put-хелперы (little-endian, как navmesh_io.zig) ---
const Buf = std.array_list.Managed(u8);
fn putU8(b: *Buf, v: u8) !void {
    try b.append(v);
}
fn putU16(b: *Buf, v: u16) !void {
    try b.appendSlice(&std.mem.toBytes(v));
}
fn putU32(b: *Buf, v: u32) !void {
    try b.appendSlice(&std.mem.toBytes(v));
}
fn putU64(b: *Buf, v: u64) !void {
    try b.appendSlice(&std.mem.toBytes(v));
}
fn putF32(b: *Buf, v: f32) !void {
    try b.appendSlice(&std.mem.toBytes(v));
}

// --- Reader (курсор, как navmesh_io.zig Reader) ---
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn u8_(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn u16_(self: *Reader) !u16 {
        if (self.pos + 2 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn u32_(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn u64_(self: *Reader) !u64 {
        if (self.pos + 8 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn f32_(self: *Reader) !f32 {
        return @bitCast(try self.u32_());
    }
    fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }
};
```

> **FALLBACK** (только если модуль 1 НЕ готов на момент реализации — заменить две строки `const writeAtomic`/`const xxh3` локальными реализациями, чтобы разрабатывать независимо; УДАЛИТЬ при готовности модуля 1):
> ```zig
> // FALLBACK xxh3: std.hash.XxHash3 (есть в Zig 0.16 std.hash)
> fn xxh3(b: []const u8) u64 {
>     return std.hash.XxHash3.hash(0, b);
> }
> // FALLBACK writeAtomic: НЕ atomic (io_util.writeWholeFile) — только для теста
> fn writeAtomic(io: std.Io, dir: []const u8, name: []const u8, data: []const u8) !void {
>     const io_util = @import("../io_util.zig");
>     var pb: [4096]u8 = undefined;
>     const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
>     _ = io;
>     try io_util.writeWholeFile(path, data, std.heap.page_allocator);
> }
> ```
> Проверь наличие `std.hash.XxHash3` в установленном Zig 0.16 командой ниже (Self-Review) — если имя иное (`std.hash.xxhash.XxHash3`), скорректируй и в модуле 1.

- [ ] **Step 3.2: serializeFlags (в буфер) + saveFlags (atomic)**

```zig
/// Сериализовать реестр флагов в буфер (без записи на диск). Owned-буфер.
pub fn serializeFlags(alloc: std.mem.Allocator) !Buf {
    poly_flags.ensureInit();
    var body = Buf.init(alloc);
    errdefer body.deinit();

    var rec_count: u32 = 0;
    var i: usize = 0;
    while (i < poly_flags.MAX_FLAGS) : (i += 1) {
        const f = poly_flags.get(i) orelse continue; // пропускает unused + reserved
        var rec = Buf.init(alloc);
        defer rec.deinit();
        try putU16(&rec, TYPE_RECORD);
        try putU8(&rec, @intCast(i)); // bit_index
        try putU8(&rec, if (f.builtin) 1 else 0);
        const nm = f.name();
        try putU8(&rec, @intCast(nm.len));
        var name_buf = [_]u8{0} ** FLAG_NAME_CAP;
        @memcpy(name_buf[0..nm.len], nm);
        try rec.appendSlice(&name_buf);
        const cs = xxh3(rec.items); // per-record csum по байтам ДО csum
        try putU64(&rec, cs);
        std.debug.assert(rec.items.len == FLAG_REC_LEN);
        try body.appendSlice(rec.items);
        rec_count += 1;
    }

    // file header впереди тела
    var out = Buf.init(alloc);
    errdefer out.deinit();
    try putU32(&out, FLAGS_MAGIC);
    try putU32(&out, REG_VERSION);
    try putU16(&out, TYPE_FILE_HEADER);
    try putU64(&out, rec_count); // payload_len = число записей
    try putU64(&out, xxh3(body.items)); // file-csum по телу
    try out.appendSlice(body.items);
    return out;
}

/// Записать реестр флагов в <dir>/flags.reg durably (atomic). `dir` — путь к edits/.
pub fn saveFlags(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var out = try serializeFlags(alloc);
    defer out.deinit();
    try writeAtomic(io, dir, "flags.reg", out.items);
}
```

- [ ] **Step 3.3: loadFlags (parse + graceful)**

```zig
/// Загрузить реестр флагов из буфера в module-global poly_flags. Вызывает
/// resetToBuiltins() и применяет сохранённые слоты через restoreFlag. Битые записи
/// пропускаются+логируются (graceful degradation). Возвращает число применённых.
pub fn deserializeFlags(data: []const u8) Error!usize {
    var r = Reader{ .data = data };
    if (try r.u32_() != FLAGS_MAGIC) return error.WrongMagic;
    if (try r.u32_() != REG_VERSION) return error.WrongVersion;
    const type_flags = try r.u16_();
    if (type_flags != TYPE_FILE_HEADER) return error.WrongMagic;
    const rec_count = try r.u64_();
    const file_csum = try r.u64_();
    const body = data[r.pos..];
    const body_ok = xxh3(body) == file_csum;
    if (!body_ok) {
        std.log.warn("flags.reg: file checksum mismatch — пробую per-record recovery", .{});
    }

    poly_flags.resetToBuiltins();
    var applied: usize = 0;
    var n: u64 = 0;
    while (n < rec_count) : (n += 1) {
        if (r.remaining() < FLAG_REC_LEN) {
            std.log.warn("flags.reg: truncated at record {d}", .{n});
            break;
        }
        const rec_start = r.pos;
        const tf = try r.u16_();
        const bit_index = try r.u8_();
        const builtin = (try r.u8_()) != 0;
        const name_len = try r.u8_();
        const name_bytes = try r.bytes(FLAG_NAME_CAP);
        const csum = try r.u64_();
        // per-record валидация
        const rec_no_csum = data[rec_start .. r.pos - 8];
        if (tf != TYPE_RECORD or name_len > FLAG_NAME_CAP or xxh3(rec_no_csum) != csum) {
            std.log.warn("flags.reg: bad record {d} (skipped)", .{n});
            continue;
        }
        poly_flags.restoreFlag(bit_index, name_bytes[0..name_len], builtin);
        applied += 1;
    }
    return applied;
}

/// Прочитать <dir>/flags.reg и применить к poly_flags. Если файла нет — оставить
/// builtin-состояние (resetToBuiltins) и вернуть 0.
pub fn loadFlags(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !usize {
    var pb: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/flags.reg", .{dir});
    const file = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            poly_flags.resetToBuiltins();
            return 0;
        },
        else => return e,
    };
    defer alloc.free(file);
    return deserializeFlags(file);
}
```

> `loadFlags`/`saveFlags` принимают `io: std.Io` явно (как io_util.zig работает через `std.Io.Threaded`). Caller (scene_io/manifest, не в этом модуле) создаёт `Threaded` и передаёт `io`. Для standalone-теста создаём `Threaded` локально.

---

## Task 4: registry_io.zig — areas.reg (save/load)

**Files:**
- Modify: `demo/src/persist/registry_io.zig`

- [ ] **Step 4.1: serializeAreas + saveAreas**

```zig
/// Сериализовать реестр area-типов в буфер. Owned-буфер.
pub fn serializeAreas(alloc: std.mem.Allocator) !Buf {
    area_types.ensureInit();
    var body = Buf.init(alloc);
    errdefer body.deinit();

    var rec_count: u32 = 0;
    var id: usize = 0;
    while (id < area_types.MAX_AREA_TYPES) : (id += 1) {
        const t = area_types.get(id) orelse continue; // только used
        var rec = Buf.init(alloc);
        defer rec.deinit();
        try putU16(&rec, TYPE_RECORD);
        try putU8(&rec, @intCast(id));
        try putU8(&rec, if (t.builtin) 1 else 0);
        try putU8(&rec, t.r);
        try putU8(&rec, t.g);
        try putU8(&rec, t.b);
        try putU8(&rec, t.a);
        try putU16(&rec, t.flags);
        try putF32(&rec, t.cost);
        const nm = t.name();
        try putU8(&rec, @intCast(nm.len));
        var name_buf = [_]u8{0} ** AREA_NAME_CAP;
        @memcpy(name_buf[0..nm.len], nm);
        try rec.appendSlice(&name_buf);
        const cs = xxh3(rec.items);
        try putU64(&rec, cs);
        std.debug.assert(rec.items.len == AREA_REC_LEN);
        try body.appendSlice(rec.items);
        rec_count += 1;
    }

    var out = Buf.init(alloc);
    errdefer out.deinit();
    try putU32(&out, AREAS_MAGIC);
    try putU32(&out, REG_VERSION);
    try putU16(&out, TYPE_FILE_HEADER);
    try putU64(&out, rec_count);
    try putU64(&out, xxh3(body.items));
    try out.appendSlice(body.items);
    return out;
}

/// Записать реестр area-типов в <dir>/areas.reg durably.
pub fn saveAreas(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var out = try serializeAreas(alloc);
    defer out.deinit();
    try writeAtomic(io, dir, "areas.reg", out.items);
}
```

- [ ] **Step 4.2: deserializeAreas + loadAreas**

```zig
/// Загрузить area-типы из буфера в module-global area_types. resetToBuiltins() +
/// restoreType. Битые записи пропускаются. Возвращает число применённых.
/// ВАЖНО: вызывать ПОСЛЕ loadFlags (area.flags ссылается на биты флагов).
pub fn deserializeAreas(data: []const u8) Error!usize {
    var r = Reader{ .data = data };
    if (try r.u32_() != AREAS_MAGIC) return error.WrongMagic;
    if (try r.u32_() != REG_VERSION) return error.WrongVersion;
    if (try r.u16_() != TYPE_FILE_HEADER) return error.WrongMagic;
    const rec_count = try r.u64_();
    const file_csum = try r.u64_();
    const body = data[r.pos..];
    if (xxh3(body) != file_csum) {
        std.log.warn("areas.reg: file checksum mismatch — per-record recovery", .{});
    }

    area_types.resetToBuiltins();
    var applied: usize = 0;
    var n: u64 = 0;
    while (n < rec_count) : (n += 1) {
        if (r.remaining() < AREA_REC_LEN) {
            std.log.warn("areas.reg: truncated at record {d}", .{n});
            break;
        }
        const rec_start = r.pos;
        const tf = try r.u16_();
        const id = try r.u8_();
        const builtin = (try r.u8_()) != 0;
        const rr = try r.u8_();
        const gg = try r.u8_();
        const bb = try r.u8_();
        const aa = try r.u8_();
        const flags = try r.u16_();
        const cost = try r.f32_();
        const name_len = try r.u8_();
        const name_bytes = try r.bytes(AREA_NAME_CAP);
        const csum = try r.u64_();
        const rec_no_csum = data[rec_start .. r.pos - 8];
        if (tf != TYPE_RECORD or name_len > AREA_NAME_CAP or xxh3(rec_no_csum) != csum) {
            std.log.warn("areas.reg: bad record {d} (skipped)", .{n});
            continue;
        }
        var t = area_types.AreaType{
            .used = true,
            .builtin = builtin,
            .r = rr,
            .g = gg,
            .b = bb,
            .a = aa,
            .flags = flags,
            .cost = cost,
        };
        t.setName(name_bytes[0..name_len]);
        area_types.restoreType(id, t);
        applied += 1;
    }
    return applied;
}

/// Прочитать <dir>/areas.reg и применить. Нет файла -> resetToBuiltins, вернуть 0.
pub fn loadAreas(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !usize {
    var pb: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/areas.reg", .{dir});
    const file = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            area_types.resetToBuiltins();
            return 0;
        },
        else => return e,
    };
    defer alloc.free(file);
    return deserializeAreas(file);
}

/// Удобный комбинированный загрузчик: flags ДО areas (инвариант порядка).
pub fn loadAll(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    _ = try loadFlags(alloc, io, dir);
    _ = try loadAreas(alloc, io, dir);
}

/// Удобный комбинированный сейв.
pub fn saveAll(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    try saveFlags(alloc, io, dir);
    try saveAreas(alloc, io, dir);
}
```

---

## Task 5: тесты round-trip (in-memory + диск) и сборка

**Files:**
- Modify: `demo/src/persist/registry_io.zig` (test-блок)
- Подключить файл к demo-тест-графу (см. Step 5.3)

- [ ] **Step 5.1: in-memory round-trip тест (serialize→deserialize, без диска)**

Добавить в `registry_io.zig`:

```zig
test "registry round-trip: custom type+flag, edited builtin cost/color" {
    const alloc = std.testing.allocator;

    // 1) исходное состояние: reset, отредактировать builtin, добавить кастом
    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    // добавить кастомный флаг (auto-bit) и кастомный тип (auto-id)
    const ladder_bit = poly_flags.addFlag("ladder").?; // занимает первый свободный (bit 5..; 4=reserved)
    const lava_id = area_types.addType().?;
    {
        const t = area_types.get(lava_id).?;
        t.cost = 9.0;
        t.flags = sample_walk | ladder_bit;
        t.r = 7;
        t.g = 8;
        t.b = 9;
        t.setName("Lava");
    }
    // отредактировать builtin Ground (cost+color)
    {
        const g = area_types.get(0).?;
        g.cost = 4.25;
        g.r = 11;
        g.g = 22;
        g.b = 33;
    }
    // переименовать builtin walk-флаг
    poly_flags.get(0).?.setName("stride");

    // 2) serialize
    var flags_buf = try serializeFlags(alloc);
    defer flags_buf.deinit();
    var areas_buf = try serializeAreas(alloc);
    defer areas_buf.deinit();

    // 3) reset (имитация фрешстарта) -> deserialize (flags ДО areas)
    _ = try deserializeFlags(flags_buf.items);
    _ = try deserializeAreas(areas_buf.items);

    // 4) проверки: кастомы восстановлены ровно
    try std.testing.expectEqualStrings("stride", poly_flags.get(0).?.name());
    try std.testing.expect(poly_flags.get(0).?.builtin);
    // ladder восстановлен в свой слот
    var found_ladder = false;
    for (0..poly_flags.MAX_FLAGS) |i| {
        if (poly_flags.get(i)) |f| {
            if (std.mem.eql(u8, f.name(), "ladder")) {
                found_ladder = true;
                try std.testing.expect(!f.builtin);
            }
        }
    }
    try std.testing.expect(found_ladder);
    // Lava
    const lava = area_types.get(lava_id).?;
    try std.testing.expectEqualStrings("Lava", lava.name());
    try std.testing.expectEqual(@as(f32, 9.0), lava.cost);
    try std.testing.expectEqual(@as(u8, 7), lava.r);
    try std.testing.expect(!lava.builtin);
    // отредактированный builtin Ground
    const g = area_types.get(0).?;
    try std.testing.expectEqual(@as(f32, 4.25), g.cost);
    try std.testing.expectEqual(@as(u8, 11), g.r);
    try std.testing.expect(g.builtin);
}

const sample_walk: u16 = 0x01; // SamplePolyFlags.walk — локальная константа для теста
```

- [ ] **Step 5.2: graceful-degradation тест (битый csum записи)**

```zig
test "registry load skips corrupt record, keeps the rest" {
    const alloc = std.testing.allocator;
    poly_flags.resetToBuiltins();
    _ = poly_flags.addFlag("ladder");
    _ = poly_flags.addFlag("crouch");
    var buf = try serializeFlags(alloc);
    defer buf.deinit();

    // испортить байт в ПЕРВОЙ записи (после file header = 4+4+2+8+8 = 26 байт)
    // первый record byte после хедера; портим имя -> per-record csum не сойдётся
    buf.items[26 + 4] ^= 0xFF; // внутри name-буфера первой записи

    poly_flags.resetToBuiltins();
    const applied = try deserializeFlags(buf.items);
    // одна запись битая -> пропущена; остальные применены
    try std.testing.expect(applied >= 1);
}
```

- [ ] **Step 5.3: disk integration-тест (atomic write -> read)**

```zig
test "registry disk round-trip via saveAll/loadAll" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // временный каталог (Zig 0.16: createDirPath, НЕ makeDir)
    const dir = "zig-cache-test-registry";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    _ = poly_flags.addFlag("ladder");
    const id = area_types.addType().?;
    area_types.get(id).?.cost = 5.0;
    area_types.get(id).?.setName("Custom");

    try saveAll(alloc, io, dir);

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    try loadAll(alloc, io, dir);

    try std.testing.expectEqual(@as(f32, 5.0), area_types.get(id).?.cost);
    try std.testing.expectEqualStrings("Custom", area_types.get(id).?.name());
}
```

> Если модуль 1 ещё не готов и используется **FALLBACK** writeAtomic, этот тест всё равно проходит (FALLBACK пишет неатомарно, но корректно). При готовом модуле 1 заменить FALLBACK и перезапустить.

- [ ] **Step 5.4: подключить registry_io.zig к demo-тест-графу и собрать**

Найти, как `demo-test`/`demo-fast` собирают тесты (предположительно `build.zig` агрегирует demo-модули). registry_io должен попасть в test-step. Если есть единый `tests.zig`/root, добавить `_ = @import("persist/registry_io.zig");`. Проверить существующий механизм:
```powershell
Select-String -Path "E:\Projects\CS2\navMesh\movement\fullProject\recast\zig-recast\build.zig" -Pattern "demo-test|addTest|test_step"
```

Снять proxy и собрать/протестировать:
```powershell
$env:http_proxy=$null; $env:https_proxy=$null
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build demo-test 2>&1 | Select-Object -Last 40
```

Также прогнать standalone area_types/poly_flags тесты в составе demo-test (Задачи 1-2).

---

## Self-Review (выполнить перед сдачей)

1. **XXH3 в Zig 0.16 stdlib — ПОДТВЕРЖДЕНО.** `std.hash.XxHash3 = xxhash.XxHash3` (hash.zig:35), сигнатура `pub fn hash(seed: u64, input: anytype) u64` (hash/xxhash.zig:232). То есть `std.hash.XxHash3.hash(0, bytes)` доступен БЕЗ внешней зависимости — модуль 1 строит `checksum.xxh3` тривиально поверх него (`return std.hash.XxHash3.hash(0, b);`). FALLBACK-блок и боевой код совпадают. Решение Q5 владельца (XXH3) реализуемо stdlib-средствами — внешний порт НЕ нужен.
2. **std.Io.Dir сигнатуры в 0.16 — ПОДТВЕРЖДЕНО** (сверено с lib/std/Io/Dir.zig установленного 0.16):
   - `readFileAlloc(dir, io, sub_path, gpa, limit: Io.Limit)` — есть (Dir.zig:1326), используется в io_util.zig:11. Лимит `.unlimited` валиден.
   - `deleteTree(dir, io, sub_path)` — есть (Dir.zig:1401).
   - **Создание каталога = `createDirPath(dir, io, sub_path)`** (Dir.zig:843), НЕ `makeDir` (такого имени в 0.16 нет). В тесте 5.3 используется `createDirPath`.
   - `createFileAtomic` — есть (Dir.zig:1924) — это база для writeAtomic модуля 1.
3. **Размеры записей** — `std.debug.assert(rec.items.len == AREA_REC_LEN/FLAG_REC_LEN)` ловит расхождение формата на этапе теста. Пересчитать вручную при изменении полей.
4. **Инвариант порядка** — `loadAll` зовёт `loadFlags` ДО `loadAreas`; `deserializeAreas` doc явно об этом предупреждает. Проверено: area.flags — это bitmask, его значение НЕ зависит от того, какие флаги зарегистрированы (биты пишутся как есть), но семантика (что бит = "ladder") валидна только если флаг восстановлен раньше — поэтому порядок важен для консистентности UI/фильтров, не для самих байтов.
5. **builtin-семантика** — restore сохраняет `builtin`-флаг записи. Отредактированный builtin (Ground cost=4.25) остаётся builtin после load (имя/cost/color редактируемы, builtin-статус — нет). Тест 5.1 это проверяет.
6. **reserved-бит** — `restoreFlag(4, ...)` = no-op (RESERVED_BIT 0x10). serializeFlags никогда не пишет слот 4 (get(4)=null). Симметрично.
7. **`writeAtomic` fsync-семантика** — ответственность модуля 1; registry_io лишь вызывает. НЕ дублировать fsync здесь.
8. **Утечки** — все `Buf` имеют `defer .deinit()` или `errdefer` + возвращаются owned (caller делает `defer out.deinit()`). Прогнать тесты под `std.testing.allocator` (детект утечек) — уже так в тестах.

---

## Открытые вопросы к владельцу

1. **Формат имени: фикс-буфер vs varint.** План пишет имя фикс-буфером (24/20 байт) для простоты фикс-длины записи и быстрого skip. Альтернатива — `name_len` + ровно `name_len` байт (компактнее, но запись переменной длины усложняет per-record skip). Подтвердить выбор фикс-буфера (рекомендуется — записи мелкие, реестры маленькие).
2. **payload_len = число записей, а не байт.** В foundation §3.b `payload_len:u64` описан как «длина тела». Здесь для file-header трактуем как record-count (тело самоописываемо через фикс-длину записей + file-csum). Для per-record skip это эквивалентно. Подтвердить, либо сменить на «байты тела» для дословного соответствия модулю 1 (тогда reader делит на REC_LEN).
3. **Куда писать имена слотов > NAME_CAP.** setName уже усекает до NAME_CAP — данные на диске никогда не превышают cap. ОК?
4. **resetToBuiltins через `initialized=false; ensureInit()`** — самый дешёвый сброс (переиспользует seed). Это трогает приватный `initialized`. Альтернатива — вынести seed в отдельную `reseed()`. Текущий вариант минимально-инвазивен. Подтвердить.

---
```