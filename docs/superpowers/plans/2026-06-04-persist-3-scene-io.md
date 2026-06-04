# Persist-3: scene_io (volumes/offmesh/.gset + archive) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development или superpowers:executing-plans. Шаги отмечены чекбоксами (`- [ ]`).
> **Дата:** 2026-06-04. **Версия Zig:** 0.16.0. **Проект:** `zig-recast`, ветка `feat/debug-platform`.
> **Источники (читаны, не ре-ресёрчить):** `docs/superpowers/specs/2026-06-04-00-foundation-design.md` §3.b; `docs/research/persistence-durability-research.md` (atomic write, пробелы Zig stdlib, XXH3, формат `.gset`). Образец формата: `demo/src/navmesh_io.zig`. IO-паттерн: `demo/src/io_util.zig`. Источник структур: `demo/src/input_geom.zig`.

---

## Goal

Модуль `demo/src/persist/scene_io.zig` — сериализация редактируемого состояния сцены в директорию-контейнер `.recastscene/`:

1. **`volumes.bin`** / **`offmesh.bin`** — наш бинарный формат (file-header + chunk-records, checksum) для convex volumes (со **стабильным `id`**) и off-mesh connections (6 параллельных массивов `InputGeom`). Round-trip save/load.
2. **`scene.gset` writer + reader** — **дословно** формат RecastDemo (`f`/`s`/`c`/`v`), чтобы `.gset` читался оригинальным RecastDemo без изменений. Семантика `f/s/c/v` не меняется. Writer + reader для `f`/`c`/`v` (`s` опционально).
3. **`packArchive(dir) -> file`** / **`unpackArchive(file) -> dir`** — свой простой tar-подобный контейнер: file-header + per-file chunk-header + checksum. Директория `.recastscene/` ⇄ один пересылаемый файл (решение владельца Q3: и директория, и архив-экспорт).

**Out of scope:** tiles/manifest (модули `tile_store`/`manifest`), реестры areas/flags (`registry_io`), сам durable-примитив `writeAtomic`/`checksum`/chunk-header (модуль 1 — **зависимость**, см. ниже).

---

## Architecture

`scene_io.zig` — demo-уровень (не ядро `src/*`): разрешены `usize`, owned-модель, `std.array_list.Managed`. Логика чисто-функциональная (сериализация в `[]u8` буфер и обратно через `Reader`-курсор), поэтому **полностью тестируется через `zig test demo/src/persist/scene_io.zig`** (standalone, без build-графа/прокси) — кроме `packArchive`/`unpackArchive` и финальных save-to-disk обёрток, которые касаются файловой системы (тестируются через временную директорию `std.testing.tmpDir`-аналог на `std.Io.Dir`, всё ещё в `zig test`).

Три слоя:

- **Pure codec** (volumes/offmesh/.gset): берёт `*const InputGeom` (или срезы) → пишет в `*std.array_list.Managed(u8)`; читает из `[]const u8` через `Reader` → мутирует `*InputGeom`. Курсор/put-хелперы — паттерн `navmesh_io.zig`. Бинарные форматы используют **chunk-header модуля 1** (file-header + per-record header с XXH3). `.gset` — чистый текст через `std.fmt` (формат RecastDemo, без header/checksum).
- **Disk wrappers**: `saveVolumes`/`loadVolumes`/`saveOffMesh`/`loadOffMesh`/`writeGset`/`readGset` — кодек + IO. Запись бинарников через `writeAtomic` (модуль 1). `.gset` пишется тоже через `writeAtomic` (atomic, но без нашего header — это требование совместимости).
- **Archive**: `packArchive(io, src_dir, out_file)` рекурсивно собирает файлы директории в один blob; `unpackArchive(io, in_file, dst_dir)` восстанавливает. Свой формат: file-header + последовательность per-file записей `[path_len:u16][path][chunk-header][bytes]`.

### Зависимости от модуля 1 (`write_atomic.zig` + `checksum.zig`) — реализуется ПЕРЕД этим модулем

Модуль 3 **импортирует** общий интерфейс модуля 1 и не дублирует его. Точные ожидаемые сигнатуры (как зафиксировано в общем контексте):

```zig
// demo/src/persist/write_atomic.zig (модуль 1 — НЕ в этом плане)
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void;

// demo/src/persist/checksum.zig (модуль 1 — НЕ в этом плане)
pub const Header = extern struct {
    magic: u32,
    version: u32,
    type_flags: u16,
    _pad: u16 = 0,           // выравнивание payload_len до 8
    payload_len: u64,
    checksum: u64,           // XXH3(type_flags || header_без_csum || payload)
};
pub const HEADER_SIZE: usize = @sizeOf(Header); // 32 байта (4+4+2+2+8+8 с _pad)

pub fn xxh3(bytes: []const u8) u64;

/// Записать [Header][payload] в buf; checksum считается по правилу выше.
pub fn putRecord(buf: *std.array_list.Managed(u8), magic: u32, version: u32, type_flags: u16, payload: []const u8) !void;

/// Прочитать один record из data[pos..]: проверить magic/version (через ожидаемые),
/// длину и checksum; вернуть срез payload и сдвинуть pos. Ошибки:
/// error.Truncated / error.WrongMagic / error.WrongVersion / error.ChecksumMismatch.
pub fn readRecord(data: []const u8, pos: *usize, expect_magic: u32, max_version: u32) ![]const u8;
```

> **ВАЖНО (порядок реализации):** если на момент работы над этим модулем `write_atomic.zig`/`checksum.zig` ещё не существуют — реализатор обязан сначала остановиться и согласовать/реализовать модуль 1 (это блокер). В Task 0 ниже — guard-проверка наличия модуля 1; при отсутствии — НЕ заглушать локально (дубль chunk-header разойдётся с модулем 1), а эскалировать.

Ошибки переиспользуются из `navmesh_io` через модуль 1: `Truncated`/`WrongMagic`/`WrongVersion` + добавленный `ChecksumMismatch`. `scene_io` добавляет только свои доменные: `error.BadGsetRow` (нечитаемая строка `.gset`), `error.TooManyVerts` (nverts > `MAX_CONVEXVOL_PTS`), `error.ArchivePathEscape` (path traversal в архиве).

---

## File Structure

- **Create** `demo/src/persist/scene_io.zig` — основной модуль (codec + disk-wrappers + archive + test-блок).
- **Modify** `demo/src/tests.zig` — добавить `_ = @import("persist/scene_io.zig");` в агрегатор (чтобы `zig build demo-test` подхватил тесты; модуль импортирует только `std` + `input_geom` + модуль 1, все std-only → компилируется standalone).
- **Depends on (модуль 1, отдельный план):** `demo/src/persist/write_atomic.zig`, `demo/src/persist/checksum.zig`.
- **Read-only зависимость:** `demo/src/input_geom.zig` (`InputGeom`, `ConvexVolume`, `MAX_CONVEXVOL_PTS`, `addConvexVolume`, `addOffMeshConnection`).

Magic-константы домена (выбраны не-конфликтующими с `'MSET'=0x4D534554` из `navmesh_io.zig`):

| Файл | magic (u32) | ASCII | version |
|---|---|---|---|
| `volumes.bin` file-header | `0x52564F4C` | `'RVOL'` | 1 |
| `volumes.bin` record | `0x31564F56` | `'VOV1'` | 1 |
| `offmesh.bin` file-header | `0x52464D4F` | `'RFMO'`→`OMFR` LE | 1 |
| `offmesh.bin` record | `0x314D464F` | `'OFM1'` | 1 |
| archive file-header | `0x52415243` | `'RARC'`→`CRAR` LE | 1 |
| archive per-file record | `0x52464C46` | `'FLFR'` | 1 |

> Замечание: ASCII-направление неважно (это просто u32-сентинелы для детекта формата); важна уникальность относительно `'MSET'` и между собой. Записывать/читать как `.little` (как в `navmesh_io.zig`).

---

## Формат payload-ов (точно)

### volumes.bin

File = `[file-header magic=RVOL ver=1, payload = тело][...]` — но проще: один file-record, payload которого = `[count:u32][volume-record × count]`. Каждый volume-record (record magic=VOV1) payload:

```
id:        u32     // ConvexVolume.id — СТАБИЛЬНЫЙ, обязательно сохраняем
area:      u8
_pad:      u8 x3   // выравнивание
nverts:    i32     // 1..=MAX_CONVEXVOL_PTS
hmin:      f32
hmax:      f32
verts:     f32 × (nverts*3)   // x,y,z по точке
```

Решение: **один внешний file-record** содержит `[count:u32]` + конкатенацию payload-ов внутренних volume-records (каждый со своим chunk-header → битый volume пропускается независимо, graceful degradation). Это даёт per-volume checksum.

### offmesh.bin

Один file-record, payload = `[count:u32]` + `count` off-mesh-records (magic=OFM1). Каждый off-mesh-record payload (поля из 6 параллельных массивов `InputGeom`):

```
id:     u32     // off_id (index-derived 1000+i — сохраняем как есть; см. NOTE в input_geom)
flags:  u16
area:   u8
dir:    u8      // bidir
rad:    f32
verts:  f32 × 6 // startXYZ, endXYZ (off_verts[i*6..][0..6])
```

### scene.gset (RecastDemo, дословно — НЕ менять)

Из durability-research §«Формат .gset» (verbatim `fprintf`):

- `f %s\n` — путь к мешу (`.obj`).
- `s %f %f %f %f %f %f %f %f %f %f %d %f %f %d %f %f %f %f %f %f %f\n` (21 поле) — build settings. **Опционально** (только если переданы). Порядок: cellSize, cellHeight, agentHeight, agentRadius, agentMaxClimb, agentMaxSlope, regionMinSize, regionMergeSize, edgeMaxLen, edgeMaxError, **vertsPerPoly(int)**, detailSampleDist, detailSampleMaxError, **partitionType(int)**, bmin[0..2], bmax[0..2], tileSize.
- `c %f %f %f %f %f %f %f %d %d %d\n` (10 полей) — off-mesh: startX,startY,startZ,endX,endY,endZ, rad(float), bidir(int), area(int), flags(int).
- `v %d %d %f %f\n` (4 поля) — convex volume: nverts(int), area(int), hmin(float), hmax(float); затем **`nverts` строк** `%f %f %f\n` (x y z) **без префикса**.

Reader диспетчеризует по `row[0]`, неизвестные префиксы **игнорирует** (как RecastDemo). `id` в `.gset` НЕ хранится (его нет в формате RecastDemo) — стабильные id живут только в `volumes.bin`/`offmesh.bin`.

### archive (.recastscene → один файл)

File = `[file-header magic=RARC ver=1, payload=[file_count:u32]]` затем `file_count` per-file записей. Каждая per-file запись:

```
[path_len:u16][path_bytes: path_len]   // относительный POSIX-путь (forward slash), напр. "edits/volumes.bin"
[record magic=FLFR ver=1, payload = содержимое файла]   // chunk-header даёт per-file checksum
```

Порядок файлов — **отсортированный по пути** (детерминизм для byte-теста идемпотентности). При `unpack`: создать поддиректории, проверить отсутствие `..`/абсолютных путей (`error.ArchivePathEscape`), записать каждый файл (через `writeAtomic` или прямой write — внутри свежей dst-директории atomic не критичен, но используем `writeAtomic` для единообразия).

---

## Task 0: Guard — наличие модуля 1

- [ ] **Step 0.1: убедиться, что модуль 1 существует и экспортирует ожидаемый API.**

Команда (снять прокси перед любым zig-вызовом):

```powershell
$env:http_proxy=$null; $env:https_proxy=$null
Test-Path demo/src/persist/write_atomic.zig
Test-Path demo/src/persist/checksum.zig
```

Если файлов нет — **СТОП**: реализовать сначала модуль 1 (отдельный план persist-1). Не дублировать chunk-header локально. Если сигнатуры модуля 1 отличаются от раздела «Зависимости» выше — адаптировать вызовы в этом плане под фактический API модуля 1 (он source of truth для header/checksum), сохранив семантику.

---

## Task 1: scene_io.zig каркас + volumes codec (TDD)

**Files:** Create `demo/src/persist/scene_io.zig`. Test: тот же файл.

- [ ] **Step 1.1: Шапка модуля, импорты, put-хелперы, Reader-курсор.**

```zig
//! scene_io — сериализация редактируемого состояния сцены (volumes/offmesh/.gset)
//! + архив-контейнер (директория .recastscene/ <-> один файл).
//! Бинарники (volumes.bin/offmesh.bin/archive) используют chunk-header модуля 1
//! (file-header + per-record header с XXH3, graceful degradation битых записей).
//! scene.gset — ДОСЛОВНО формат RecastDemo (f/s/c/v), читается оригинальным
//! RecastDemo; семантику НЕ менять (durability-research §«Формат .gset»).

const std = @import("std");
const input_geom = @import("../input_geom.zig");
const wa = @import("write_atomic.zig");
const cks = @import("checksum.zig");

const InputGeom = input_geom.InputGeom;
const ConvexVolume = input_geom.ConvexVolume;
const MAX_CONVEXVOL_PTS = input_geom.MAX_CONVEXVOL_PTS;
const Managed = std.array_list.Managed;

// --- domain magics (LE u32, не конфликтуют с 'MSET'=0x4D534554) ---
const VOL_FILE_MAGIC: u32 = 0x52564F4C; // file-header volumes.bin
const VOL_REC_MAGIC: u32 = 0x31564F56; // per-volume record
const OFF_FILE_MAGIC: u32 = 0x52464D4F; // file-header offmesh.bin
const OFF_REC_MAGIC: u32 = 0x314D464F; // per-offmesh record
const ARC_FILE_MAGIC: u32 = 0x52415243; // archive file-header
const ARC_REC_MAGIC: u32 = 0x52464C46; // archive per-file record
const FORMAT_VERSION: u32 = 1;

pub const Error = error{
    BadGsetRow,
    TooManyVerts,
    ArchivePathEscape,
};

// --- put-хелперы (LE), паттерн navmesh_io.zig ---
fn putU16(buf: *Managed(u8), v: u16) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}
fn putU32(buf: *Managed(u8), v: u32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}
fn putI32(buf: *Managed(u8), v: i32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}
fn putF32(buf: *Managed(u8), v: f32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}

// --- Reader-курсор (паттерн navmesh_io.zig) ---
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

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
    fn i32_(self: *Reader) !i32 {
        return @bitCast(try self.u32_());
    }
    fn f32_(self: *Reader) !f32 {
        return @bitCast(try self.u32_());
    }
    fn u8_(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.Truncated;
        self.pos += n;
    }
};
```

- [ ] **Step 1.2: encodeVolumes (pure) — собрать payload одного volume-record и внешний file-record.**

```zig
/// Сериализовать один convex volume в payload (без chunk-header — его навесит putRecord).
fn encodeVolumePayload(buf: *Managed(u8), vol: *const ConvexVolume) !void {
    if (vol.nverts < 1 or vol.nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
    try putU32(buf, vol.id);
    try buf.append(vol.area);
    try buf.appendSlice(&[_]u8{ 0, 0, 0 }); // _pad
    try putI32(buf, vol.nverts);
    try putF32(buf, vol.hmin);
    try putF32(buf, vol.hmax);
    const n: usize = @intCast(vol.nverts);
    var i: usize = 0;
    while (i < n * 3) : (i += 1) try putF32(buf, vol.verts[i]);
}

/// Сериализовать ВСЕ volumes в owned-буфер: [file-header][count:u32][volume-record × count].
/// Внешний file-record содержит count + конкатенацию per-volume records (каждый со
/// своим chunk-header → битый volume пропускается независимо при чтении).
pub fn encodeVolumes(alloc: std.mem.Allocator, geom: *const InputGeom) !Managed(u8) {
    // 1) тело file-record: count + per-volume records
    var inner = Managed(u8).init(alloc);
    defer inner.deinit();
    try putU32(&inner, @intCast(geom.volumes.items.len));
    for (geom.volumes.items) |*vol| {
        var vp = Managed(u8).init(alloc);
        defer vp.deinit();
        try encodeVolumePayload(&vp, vol);
        try cks.putRecord(&inner, VOL_REC_MAGIC, FORMAT_VERSION, 0, vp.items);
    }
    // 2) внешний file-record
    var out = Managed(u8).init(alloc);
    errdefer out.deinit();
    try cks.putRecord(&out, VOL_FILE_MAGIC, FORMAT_VERSION, 0, inner.items);
    return out;
}
```

- [ ] **Step 1.3: decodeVolumes (pure) — прочитать в InputGeom (через addConvexVolume, чтобы id/next_volume_id были согласованы).**

> Семантика загрузки: используем `addConvexVolume`, который присваивает СВОЙ монотонный id и игнорирует сохранённый. Но нам нужен СТАБИЛЬНЫЙ id. Поэтому: добавляем volume напрямую в `geom.volumes` с сохранённым id и поднимаем `next_volume_id` до `max(id)+1`, чтобы последующие add не переиспользовали id. (Это требует read-only-совместимого доступа к полям `InputGeom` — они `pub`, поля `volumes`/`next_volume_id` доступны.)

```zig
/// Загрузить volumes из бинарного блоба в geom (очищает существующие volumes).
/// Битый per-volume record пропускается + логируется (graceful degradation).
pub fn decodeVolumes(geom: *InputGeom, data: []const u8) !void {
    var pos: usize = 0;
    const inner = try cks.readRecord(data, &pos, VOL_FILE_MAGIC, FORMAT_VERSION);

    geom.volumes.clearRetainingCapacity();
    var max_id: u32 = 0;

    var r = Reader{ .data = inner };
    const count = try r.u32_();
    var loaded: u32 = 0;
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        // прочитать per-volume record по абсолютному смещению inner[r.pos..]
        var rpos = r.pos;
        const payload = cks.readRecord(inner, &rpos, VOL_REC_MAGIC, FORMAT_VERSION) catch |e| {
            std.log.warn("scene_io: пропуск битого volume #{d}: {s}", .{ k, @errorName(e) });
            // не можем безопасно продолжить без длины записи -> прекращаем
            break;
        };
        r.pos = rpos;
        decodeOneVolume(geom, payload, &max_id) catch |e| {
            std.log.warn("scene_io: volume #{d} отброшен: {s}", .{ k, @errorName(e) });
            continue;
        };
        loaded += 1;
    }
    geom.next_volume_id = max_id + 1;
    _ = loaded;
}

fn decodeOneVolume(geom: *InputGeom, payload: []const u8, max_id: *u32) !void {
    var r = Reader{ .data = payload };
    var vol = ConvexVolume{};
    vol.id = try r.u32_();
    vol.area = try r.u8_();
    try r.skip(3); // _pad
    vol.nverts = try r.i32_();
    if (vol.nverts < 1 or vol.nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
    vol.hmin = try r.f32_();
    vol.hmax = try r.f32_();
    const n: usize = @intCast(vol.nverts);
    var i: usize = 0;
    while (i < n * 3) : (i += 1) vol.verts[i] = try r.f32_();
    if (vol.id > max_id.*) max_id.* = vol.id;
    try geom.volumes.append(vol);
}
```

> **Замечание о readRecord и графе пропуска:** при битом per-volume record мы не можем узнать его длину, чтобы перепрыгнуть к следующему (header сам мог быть повреждён). Стратегия: внешний file-record уже прошёл checksum целиком → если он валиден, внутренние записи целы; если внешний бит — `decodeVolumes` вернёт ошибку до цикла. Per-volume checksum здесь — defense-in-depth (детект логической рассинхронизации), а не независимый recovery. Это осознанный компромисс; для независимого пропуска нужен формат с явной длиной перед каждой записью (chunk-header модуля 1 её и содержит — `payload_len`), поэтому если `readRecord` корректно читает `payload_len` даже при битом payload-checksum, можно продолжать. Реализатор: уточнить у модуля 1, возвращает ли `readRecord` при `ChecksumMismatch` всё же сдвинутый `pos` (тогда `continue` вместо `break`). **Открытый вопрос OQ1.**

- [ ] **Step 1.4: Тест round-trip volumes.**

```zig
test "volumes.bin round-trip preserves stable id and geometry" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0.5, 2.0, 7);
    try g.addConvexVolume(&tri, 3, -1.0, 1.0, 3);
    g.deleteConvexVolume(0); // дырка в id -> остался id=2
    try g.addConvexVolume(&tri, 3, 0.0, 5.0, 1); // id=3

    var blob = try encodeVolumes(alloc, &g);
    defer blob.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try decodeVolumes(&g2, blob.items);

    try std.testing.expectEqual(g.volumes.items.len, g2.volumes.items.len);
    for (g.volumes.items, g2.volumes.items) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try std.testing.expectEqual(a.area, b.area);
        try std.testing.expectEqual(a.nverts, b.nverts);
        try std.testing.expectEqual(a.hmin, b.hmin);
        try std.testing.expectEqual(a.hmax, b.hmax);
        const n: usize = @intCast(a.nverts);
        try std.testing.expectEqualSlices(f32, a.verts[0 .. n * 3], b.verts[0 .. n * 3]);
    }
    // next_volume_id восстановлен так, что новый add не переиспользует id
    try std.testing.expect(g2.next_volume_id > 3);
}
```

**Команда:**
```powershell
$env:http_proxy=$null; $env:https_proxy=$null
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/persist/scene_io.zig
```
(Standalone: модуль импортирует только std + input_geom + модуль 1 — все std-only.)

---

## Task 2: offmesh codec (TDD)

**Files:** edit `scene_io.zig`. Test: тот же файл.

- [ ] **Step 2.1: encodeOffMesh (pure).**

```zig
fn encodeOffMeshPayload(buf: *Managed(u8), g: *const InputGeom, i: usize) !void {
    try putU32(buf, g.off_id.items[i]);
    try putU16(buf, g.off_flags.items[i]);
    try buf.append(g.off_area.items[i]);
    try buf.append(g.off_dir.items[i]);
    try putF32(buf, g.off_rad.items[i]);
    const v = g.off_verts.items[i * 6 ..][0..6];
    for (v) |c| try putF32(buf, c);
}

pub fn encodeOffMesh(alloc: std.mem.Allocator, geom: *const InputGeom) !Managed(u8) {
    var inner = Managed(u8).init(alloc);
    defer inner.deinit();
    const count = geom.offMeshCount();
    try putU32(&inner, @intCast(count));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var op = Managed(u8).init(alloc);
        defer op.deinit();
        try encodeOffMeshPayload(&op, geom, i);
        try cks.putRecord(&inner, OFF_REC_MAGIC, FORMAT_VERSION, 0, op.items);
    }
    var out = Managed(u8).init(alloc);
    errdefer out.deinit();
    try cks.putRecord(&out, OFF_FILE_MAGIC, FORMAT_VERSION, 0, inner.items);
    return out;
}
```

- [ ] **Step 2.2: decodeOffMesh (pure).**

> Загрузка через прямое заполнение параллельных массивов (НЕ через `addOffMeshConnection`, т.к. тот пересчитывает `off_id` как `1000+len` и затёр бы сохранённый id). Очищаем существующие off-mesh.

```zig
pub fn decodeOffMesh(geom: *InputGeom, data: []const u8) !void {
    var pos: usize = 0;
    const inner = try cks.readRecord(data, &pos, OFF_FILE_MAGIC, FORMAT_VERSION);

    geom.off_verts.clearRetainingCapacity();
    geom.off_rad.clearRetainingCapacity();
    geom.off_dir.clearRetainingCapacity();
    geom.off_area.clearRetainingCapacity();
    geom.off_flags.clearRetainingCapacity();
    geom.off_id.clearRetainingCapacity();

    var r = Reader{ .data = inner };
    const count = try r.u32_();
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        var rpos = r.pos;
        const payload = cks.readRecord(inner, &rpos, OFF_REC_MAGIC, FORMAT_VERSION) catch |e| {
            std.log.warn("scene_io: пропуск битого off-mesh #{d}: {s}", .{ k, @errorName(e) });
            break;
        };
        r.pos = rpos;
        decodeOneOffMesh(geom, payload) catch |e| {
            std.log.warn("scene_io: off-mesh #{d} отброшен: {s}", .{ k, @errorName(e) });
            continue;
        };
    }
}

fn decodeOneOffMesh(geom: *InputGeom, payload: []const u8) !void {
    var r = Reader{ .data = payload };
    const id = try r.u32_();
    const flags = try r.u16_();
    const area = try r.u8_();
    const dir = try r.u8_();
    const rad = try r.f32_();
    var v: [6]f32 = undefined;
    for (&v) |*c| c.* = try r.f32_();
    try geom.off_verts.appendSlice(&v);
    try geom.off_rad.append(rad);
    try geom.off_dir.append(dir);
    try geom.off_area.append(area);
    try geom.off_flags.append(flags);
    try geom.off_id.append(id);
}
```

- [ ] **Step 2.3: Тест round-trip offmesh.**

```zig
test "offmesh.bin round-trip preserves all parallel arrays" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.5, 1, 9, 0xABCD);
    try g.addOffMeshConnection(.{ -1, 0, 1 }, .{ 2, 2, 2 }, 1.25, 0, 2, 0x0001);

    var blob = try encodeOffMesh(alloc, &g);
    defer blob.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try decodeOffMesh(&g2, blob.items);

    try std.testing.expectEqual(g.offMeshCount(), g2.offMeshCount());
    try std.testing.expectEqualSlices(f32, g.off_verts.items, g2.off_verts.items);
    try std.testing.expectEqualSlices(f32, g.off_rad.items, g2.off_rad.items);
    try std.testing.expectEqualSlices(u8, g.off_dir.items, g2.off_dir.items);
    try std.testing.expectEqualSlices(u8, g.off_area.items, g2.off_area.items);
    try std.testing.expectEqualSlices(u16, g.off_flags.items, g2.off_flags.items);
    try std.testing.expectEqualSlices(u32, g.off_id.items, g2.off_id.items);
}
```

---

## Task 3: scene.gset writer + reader (TDD, byte-проверка)

**Files:** edit `scene_io.zig`. Test: тот же файл.

> **Критично:** `.gset` пишется через `std.fmt`, **без** нашего header/checksum. Формат — дословно RecastDemo. `%f` в C по умолчанию печатает 6 знаков после запятой; в Zig `{d}` для f32 печатает кратчайшее представление → НЕ совпадёт byte-в-byte с RecastDemo. RecastDemo при чтении использует `sscanf("%f")`, которому формат печати безразличен — поэтому **функциональная** совместимость (RecastDemo прочитает) важнее byte-identity с конкретным выводом C. Byte-тест в этом плане сверяет наш writer против **нашего же зафиксированного ожидаемого текста** (golden string), а не против вывода C-`printf`. Для печати f32 используем `{d}` (кратчайшее точное) — это валидный вход для `sscanf("%f")`.

- [ ] **Step 3.1: GsetSettings struct (опц. поля для строки `s`).**

```zig
/// Параметры строки `s` .gset (build settings). Опционально: если null — строка `s` не пишется.
pub const GsetSettings = struct {
    cell_size: f32,
    cell_height: f32,
    agent_height: f32,
    agent_radius: f32,
    agent_max_climb: f32,
    agent_max_slope: f32,
    region_min_size: f32,
    region_merge_size: f32,
    edge_max_len: f32,
    edge_max_error: f32,
    verts_per_poly: i32,
    detail_sample_dist: f32,
    detail_sample_max_error: f32,
    partition_type: i32,
    bmin: [3]f32,
    bmax: [3]f32,
    tile_size: f32,
};
```

- [ ] **Step 3.2: writeGsetText (pure → буфер).**

```zig
/// Сериализовать .gset в текстовый буфер (формат RecastDemo, дословно).
/// mesh_name -> строка `f`; settings (опц.) -> строка `s`; off-mesh -> `c`; volumes -> `v`.
pub fn writeGsetText(alloc: std.mem.Allocator, geom: *const InputGeom, mesh_name: []const u8, settings: ?GsetSettings) !Managed(u8) {
    var out = Managed(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();

    // f %s
    try w.print("f {s}\n", .{mesh_name});

    // s (21 поле, опционально)
    if (settings) |s| {
        try w.print("s {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
            s.cell_size,         s.cell_height,        s.agent_height,
            s.agent_radius,      s.agent_max_climb,    s.agent_max_slope,
            s.region_min_size,   s.region_merge_size,  s.edge_max_len,
            s.edge_max_error,    s.verts_per_poly,     s.detail_sample_dist,
            s.detail_sample_max_error, s.partition_type, s.bmin[0],
            s.bmin[1],           s.bmin[2],            s.bmax[0],
            s.bmax[1],           s.bmax[2],            s.tile_size,
        });
    }

    // c (off-mesh): startXYZ endXYZ rad bidir area flags
    var i: usize = 0;
    while (i < geom.offMeshCount()) : (i += 1) {
        const v = geom.off_verts.items[i * 6 ..][0..6];
        try w.print("c {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
            v[0], v[1], v[2], v[3], v[4], v[5],
            geom.off_rad.items[i],
            @as(i32, geom.off_dir.items[i]),
            @as(i32, geom.off_area.items[i]),
            @as(i32, geom.off_flags.items[i]),
        });
    }

    // v (convex volume): nverts area hmin hmax, затем nverts строк "x y z"
    for (geom.volumes.items) |*vol| {
        try w.print("v {d} {d} {d} {d}\n", .{
            vol.nverts, @as(i32, vol.area), vol.hmin, vol.hmax,
        });
        const n: usize = @intCast(vol.nverts);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const p = vol.verts[k * 3 ..][0..3];
            try w.print("{d} {d} {d}\n", .{ p[0], p[1], p[2] });
        }
    }

    return out;
}
```

> Примечание по `w`: в Zig 0.16 `Managed(u8).writer()` возвращает writer с `.print`. Если API изменился (writergate), использовать `std.io.Writer`-адаптер или `out.print`-эквивалент; реализатор сверяет с фактическим `std.array_list.Managed` 0.16. Альтернатива без writer: `try out.appendSlice(try std.fmt.allocPrint(alloc, ...))` с `defer alloc.free`.

- [ ] **Step 3.3: readGsetText (pure → mesh_name + мутирует geom через add*).**

Reader диспетчеризует по первому токену строки; неизвестные префиксы игнорирует.

```zig
pub const GsetParsed = struct {
    mesh_name: []u8, // owned, освобождает вызывающий
    has_settings: bool,
    settings: GsetSettings,
};

/// Прочитать .gset: заполнить geom (off-mesh+volumes), вернуть mesh_name (owned) и settings.
/// Неизвестные строки игнорируются (как RecastDemo). Строка `v` тянет nverts последующих
/// строк координат.
pub fn readGsetText(alloc: std.mem.Allocator, geom: *InputGeom, text: []const u8) !GsetParsed {
    var mesh_name: []u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(mesh_name);
    var has_settings = false;
    var settings: GsetSettings = undefined;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 1) continue;
        switch (line[0]) {
            'f' => {
                const rest = std.mem.trim(u8, line[1..], " \t");
                alloc.free(mesh_name);
                mesh_name = try alloc.dupe(u8, rest);
            },
            's' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                settings = try parseSettings(&it);
                has_settings = true;
            },
            'c' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                const f = struct {
                    fn nf(t: *std.mem.TokenIterator(u8, .scalar)) !f32 {
                        return std.fmt.parseFloat(f32, t.next() orelse return error.BadGsetRow);
                    }
                    fn ni(t: *std.mem.TokenIterator(u8, .scalar)) !i32 {
                        return std.fmt.parseInt(i32, t.next() orelse return error.BadGsetRow, 10);
                    }
                };
                const sx = try f.nf(&it); const sy = try f.nf(&it); const sz = try f.nf(&it);
                const ex = try f.nf(&it); const ey = try f.nf(&it); const ez = try f.nf(&it);
                const rad = try f.nf(&it);
                const bidir = try f.ni(&it);
                const area = try f.ni(&it);
                const flags = try f.ni(&it);
                try geom.addOffMeshConnection(
                    .{ sx, sy, sz }, .{ ex, ey, ez }, rad,
                    @intCast(bidir), @intCast(area), @intCast(@as(u32, @bitCast(flags)) & 0xFFFF),
                );
            },
            'v' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                const nverts = try std.fmt.parseInt(i32, it.next() orelse return error.BadGsetRow, 10);
                const area = try std.fmt.parseInt(i32, it.next() orelse return error.BadGsetRow, 10);
                const hmin = try std.fmt.parseFloat(f32, it.next() orelse return error.BadGsetRow);
                const hmax = try std.fmt.parseFloat(f32, it.next() orelse return error.BadGsetRow);
                if (nverts < 1 or nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
                const n: usize = @intCast(nverts);
                var verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined;
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const vline = std.mem.trim(u8, lines.next() orelse return error.BadGsetRow, " \t\r");
                    var vit = std.mem.tokenizeScalar(u8, vline, ' ');
                    verts[k * 3 + 0] = try std.fmt.parseFloat(f32, vit.next() orelse return error.BadGsetRow);
                    verts[k * 3 + 1] = try std.fmt.parseFloat(f32, vit.next() orelse return error.BadGsetRow);
                    verts[k * 3 + 2] = try std.fmt.parseFloat(f32, vit.next() orelse return error.BadGsetRow);
                }
                try geom.addConvexVolume(verts[0 .. n * 3], nverts, hmin, hmax, @intCast(area));
            },
            else => {}, // неизвестный префикс — игнор (как RecastDemo)
        }
    }

    return .{ .mesh_name = mesh_name, .has_settings = has_settings, .settings = settings };
}

fn parseSettings(it: *std.mem.TokenIterator(u8, .scalar)) !GsetSettings {
    const nf = struct {
        fn f(t: *std.mem.TokenIterator(u8, .scalar)) !f32 {
            return std.fmt.parseFloat(f32, t.next() orelse return error.BadGsetRow);
        }
        fn i(t: *std.mem.TokenIterator(u8, .scalar)) !i32 {
            return std.fmt.parseInt(i32, t.next() orelse return error.BadGsetRow, 10);
        }
    };
    return .{
        .cell_size = try nf.f(it), .cell_height = try nf.f(it), .agent_height = try nf.f(it),
        .agent_radius = try nf.f(it), .agent_max_climb = try nf.f(it), .agent_max_slope = try nf.f(it),
        .region_min_size = try nf.f(it), .region_merge_size = try nf.f(it), .edge_max_len = try nf.f(it),
        .edge_max_error = try nf.f(it), .verts_per_poly = try nf.i(it), .detail_sample_dist = try nf.f(it),
        .detail_sample_max_error = try nf.f(it), .partition_type = try nf.i(it),
        .bmin = .{ try nf.f(it), try nf.f(it), try nf.f(it) },
        .bmax = .{ try nf.f(it), try nf.f(it), try nf.f(it) },
        .tile_size = try nf.f(it),
    };
}
```

- [ ] **Step 3.4: Тест byte-format (golden) + round-trip.**

```zig
test "gset writer emits exact RecastDemo row format" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 0, 0, 0 }, .{ 1, 1, 1 }, 0.5, 1, 2, 3);
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0, 4, 5);

    var txt = try writeGsetText(alloc, &g, "mesh.obj", null);
    defer txt.deinit();

    const expected =
        "f mesh.obj\n" ++
        "c 0 0 0 1 1 1 0.5 1 2 3\n" ++
        "v 3 5 0 4\n" ++
        "0 0 0\n" ++
        "1 0 0\n" ++
        "0 0 1\n";
    try std.testing.expectEqualStrings(expected, txt.items);
}

test "gset round-trip (write -> read) preserves off-mesh and volumes" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.75, 0, 1, 7);
    const tri = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    try g.addConvexVolume(&tri, 3, -1, 3, 9);

    var txt = try writeGsetText(alloc, &g, "x.obj", null);
    defer txt.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    var parsed = try readGsetText(alloc, &g2, txt.items);
    defer alloc.free(parsed.mesh_name);

    try std.testing.expectEqualStrings("x.obj", parsed.mesh_name);
    try std.testing.expectEqual(@as(usize, 1), g2.offMeshCount());
    try std.testing.expectEqual(@as(usize, 1), g2.volumes.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), g2.off_rad.items[0], 1e-6);
    try std.testing.expectEqual(@as(i32, 3), g2.volumes.items[0].nverts);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), g2.volumes.items[0].hmax, 1e-6);
}
```

> **Риск golden-теста:** точный текст `{d}` для f32 (`0.5`, `0.75`) зависит от формат-кода Zig 0.16. Если `{d}` печатает `5.0e-01` или иначе — golden придётся подправить под фактический вывод (это допустимо: цель — стабильность нашего writer + читаемость `sscanf`). Реализатор: при первом прогоне зафиксировать фактический вывод в `expected`. Семантика RecastDemo не нарушается (любой валидный float-литерал парсится `sscanf`).

---

## Task 4: disk-wrappers (volumes/offmesh/.gset save/load) — integration

**Files:** edit `scene_io.zig`. Test: тот же файл (через `std.Io.Dir` + временная директория).

- [ ] **Step 4.1: save/load обёртки.**

```zig
/// Записать volumes.bin в dir (atomic, через модуль 1).
pub fn saveVolumes(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *const InputGeom) !void {
    var blob = try encodeVolumes(alloc, geom);
    defer blob.deinit();
    try wa.writeAtomic(io, dir, "volumes.bin", blob.items);
}

pub fn loadVolumes(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *InputGeom) !void {
    const bytes = try dir.readFileAlloc(io, "volumes.bin", alloc, .unlimited);
    defer alloc.free(bytes);
    try decodeVolumes(geom, bytes);
}

pub fn saveOffMesh(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *const InputGeom) !void {
    var blob = try encodeOffMesh(alloc, geom);
    defer blob.deinit();
    try wa.writeAtomic(io, dir, "offmesh.bin", blob.items);
}

pub fn loadOffMesh(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *InputGeom) !void {
    const bytes = try dir.readFileAlloc(io, "offmesh.bin", alloc, .unlimited);
    defer alloc.free(bytes);
    try decodeOffMesh(geom, bytes);
}

/// Записать scene.gset (atomic, БЕЗ нашего header — формат RecastDemo as-is).
pub fn writeGset(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *const InputGeom, mesh_name: []const u8, settings: ?GsetSettings) !void {
    var txt = try writeGsetText(alloc, geom, mesh_name, settings);
    defer txt.deinit();
    try wa.writeAtomic(io, dir, "scene.gset", txt.items);
}

pub fn readGset(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, geom: *InputGeom) !GsetParsed {
    const text = try dir.readFileAlloc(io, "scene.gset", alloc, .unlimited);
    defer alloc.free(text);
    return readGsetText(alloc, geom, text);
}
```

> `std.Io.Dir.readFileAlloc(io, sub_path, alloc, .unlimited)` — подтверждён в `io_util.zig:11`. `dir` — уже открытая директория `.recastscene/edits/` (для volumes/offmesh) или `.recastscene/` (для .gset). Вызывающий (manifest/scene-level) открывает нужную поддиректорию.

- [ ] **Step 4.2: integration-тест save→load на временной директории.**

```zig
test "saveVolumes -> loadVolumes through disk round-trips" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmp.dir — std.fs.Dir; нужен std.Io.Dir. В 0.16 std.fs.Dir мигрировал в std.Io.Dir.
    // Используем путь через cwd + уникальное имя, если tmpDir несовместим. См. примечание ниже.

    var g = InputGeom.init(alloc);
    defer g.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0, 1, 4);

    const dir = std.Io.Dir{ .handle = tmp.dir.fd }; // адаптация fd -> Io.Dir (см. примечание)
    try saveVolumes(io, dir, alloc, &g);

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try loadVolumes(io, dir, alloc, &g2);
    try std.testing.expectEqual(g.volumes.items.len, g2.volumes.items.len);
    try std.testing.expectEqual(g.volumes.items[0].id, g2.volumes.items[0].id);
}
```

> **ПРИМЕЧАНИЕ (Zig 0.16 tmpDir/Io.Dir несостыковка — OQ2):** В 0.16 `std.testing.tmpDir` и `std.fs.Dir` мигрируют в `std.Io`. Точная конструкция `std.Io.Dir` из tmp-handle **не подтверждена** в этой сессии — реализатор должен сверить актуальный API: либо `std.Io.Dir.cwd().openDir(io, tmp_path, .{})`, либо прямой `std.Io.Dir{ .handle = ... }`. Если tmpDir несовместим — создать уникальную поддиректорию в cwd (`.recastscene_test_<rand>/`) через `std.Io.Dir.cwd().makeDir`/`makePath`, использовать её, удалить в `defer`. Pure-кодек-тесты (Task 1-3) от этого НЕ зависят — disk-тесты можно временно пометить и отложить до подтверждения API, не блокируя основную логику.

---

## Task 5: packArchive / unpackArchive (TDD + integration)

**Files:** edit `scene_io.zig`. Test: тот же файл.

- [ ] **Step 5.1: Рекурсивный сбор относительных путей директории (отсортированный).**

```zig
/// Собрать отсортированный список относительных POSIX-путей всех файлов под dir (рекурсивно).
/// Возвращает owned-срез owned-строк (вызывающий освобождает каждую и срез).
fn collectFiles(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) ![][]u8 {
    var list = Managed([]u8).init(alloc);
    errdefer {
        for (list.items) |s| alloc.free(s);
        list.deinit();
    }
    try walkInto(io, alloc, dir, "", &list);
    std.mem.sort([]u8, list.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.toOwnedSlice();
}

fn walkInto(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, prefix: []const u8, list: *Managed([]u8)) !void {
    var d = try dir.openDir(io, if (prefix.len == 0) "." else prefix, .{ .iterate = true });
    defer if (prefix.len != 0) d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const rel = if (prefix.len == 0)
            try alloc.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, e.name });
        switch (e.kind) {
            .file => try list.append(rel),
            .directory => {
                defer alloc.free(rel);
                try walkInto(io, alloc, dir, rel, list);
            },
            else => alloc.free(rel),
        }
    }
}
```

> **Примечание:** рекурсия через `prefix` относительно КОРНЯ архива `dir` (не вложенный openDir на каждый уровень — проще для путей). Реализатор может упростить: открыть `dir.openDir(io, prefix, .{.iterate})` каждый раз от корня. Точная семантика `iterate()`/`Dir.Entry.kind` — как в `io_util.zig:80-85` (подтверждено).

- [ ] **Step 5.2: packArchive.**

```zig
/// Упаковать всю директорию src_dir в один файл out_path (atomic) в каталоге out_dir.
pub fn packArchive(io: std.Io, alloc: std.mem.Allocator, src_dir: std.Io.Dir, out_dir: std.Io.Dir, out_name: []const u8) !void {
    const files = try collectFiles(io, alloc, src_dir);
    defer {
        for (files) |s| alloc.free(s);
        alloc.free(files);
    }

    var inner = Managed(u8).init(alloc);
    defer inner.deinit();
    try putU32(&inner, @intCast(files.len));
    for (files) |rel| {
        try putU16(&inner, @intCast(rel.len));
        try inner.appendSlice(rel);
        const content = try src_dir.readFileAlloc(io, rel, alloc, .unlimited);
        defer alloc.free(content);
        try cks.putRecord(&inner, ARC_REC_MAGIC, FORMAT_VERSION, 0, content);
    }

    var out = Managed(u8).init(alloc);
    defer out.deinit();
    try cks.putRecord(&out, ARC_FILE_MAGIC, FORMAT_VERSION, 0, inner.items);
    try wa.writeAtomic(io, out_dir, out_name, out.items);
}
```

- [ ] **Step 5.3: unpackArchive (с проверкой path-escape).**

```zig
/// Распаковать архив in_path (в каталоге in_dir) в директорию dst_dir (создаёт поддиректории).
pub fn unpackArchive(io: std.Io, alloc: std.mem.Allocator, in_dir: std.Io.Dir, in_name: []const u8, dst_dir: std.Io.Dir) !void {
    const blob = try in_dir.readFileAlloc(io, in_name, alloc, .unlimited);
    defer alloc.free(blob);

    var pos: usize = 0;
    const inner = try cks.readRecord(blob, &pos, ARC_FILE_MAGIC, FORMAT_VERSION);

    var r = Reader{ .data = inner };
    const count = try r.u32_();
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        const plen = try r.u16_();
        if (r.pos + plen > inner.len) return error.Truncated;
        const rel = inner[r.pos .. r.pos + plen];
        r.pos += plen;
        if (!isSafeRelPath(rel)) return error.ArchivePathEscape;

        var rpos = r.pos;
        const content = cks.readRecord(inner, &rpos, ARC_REC_MAGIC, FORMAT_VERSION) catch |e| {
            std.log.warn("scene_io: пропуск битого файла '{s}' в архиве: {s}", .{ rel, @errorName(e) });
            break; // длина неизвестна -> не можем перепрыгнуть (см. OQ1)
        };
        r.pos = rpos;

        // создать поддиректории пути
        if (std.fs.path.dirnamePosix(rel)) |parent| {
            try dst_dir.makePath(io, parent);
        }
        try wa.writeAtomic(io, dst_dir, rel, content);
    }
}

/// Запретить абсолютные пути и `..`-выход за пределы dst.
fn isSafeRelPath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (rel.len >= 2 and rel[1] == ':') return false; // C:\
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}
```

> `dst_dir.makePath(io, parent)` / `writeAtomic` с под-путём `"edits/volumes.bin"` — `writeAtomic` модуля 1 должен поддерживать sub_path с `/` (создаёт temp рядом с целью в той же поддиректории). Если `writeAtomic` НЕ принимает вложенный путь — реализатор открывает поддиректорию `dst_dir.openDir(io, parent, .{})` и пишет туда базовым именем. **OQ3.**

- [ ] **Step 5.4: Тест pack→unpack идемпотентность.**

```zig
test "packArchive -> unpackArchive is idempotent (byte-identical files)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // создать src-директорию с двумя файлами в подкаталоге
    const root = std.Io.Dir.cwd();
    try root.makePath(io, "arc_test_src/edits");
    defer root.deleteTree(io, "arc_test_src") catch {};
    try root.writeFile(io, .{ .sub_path = "arc_test_src/scene.gset", .data = "f mesh.obj\n" });
    try root.writeFile(io, .{ .sub_path = "arc_test_src/edits/volumes.bin", .data = "\x01\x02\x03\x04" });

    var src = try root.openDir(io, "arc_test_src", .{ .iterate = true });
    defer src.close(io);

    try packArchive(io, alloc, src, root, "arc_test.bin");
    defer root.deleteFile(io, "arc_test.bin") catch {};

    try root.makePath(io, "arc_test_dst");
    defer root.deleteTree(io, "arc_test_dst") catch {};
    var dst = try root.openDir(io, "arc_test_dst", .{});
    defer dst.close(io);

    try unpackArchive(io, alloc, root, "arc_test.bin", dst);

    const a = try dst.readFileAlloc(io, "scene.gset", alloc, .unlimited);
    defer alloc.free(a);
    const b = try dst.readFileAlloc(io, "edits/volumes.bin", alloc, .unlimited);
    defer alloc.free(b);
    try std.testing.expectEqualStrings("f mesh.obj\n", a);
    try std.testing.expectEqualSlices(u8, "\x01\x02\x03\x04", b);
}
```

> **OQ2/OQ4 риски:** `std.Io.Dir.cwd().makePath/deleteTree/deleteFile/writeFile/openDir` — имена методов сверить с фактическим 0.16 (`io_util.zig` подтверждает `openDir`/`iterate`/`writeFile`/`readFileAlloc`/`close`; `makePath`/`deleteTree`/`deleteFile` — по аналогии с `std.fs.Dir`, но в `Io.Dir` могут называться иначе). Если disk-тесты упираются в нестабильный API — pure-кодек архива (encode/decode в `[]u8`) можно вынести в отдельные `packToBytes`/`unpackFromBytes` и тестировать БЕЗ диска (рекомендуется как defense — см. Self-Review).

---

## Task 6: Регистрация в test-агрегаторе

- [ ] **Step 6.1: добавить импорт в `demo/src/tests.zig`.**

```zig
    _ = @import("persist/scene_io.zig");
```
(после строки `_ = @import("render/color_scheme.zig");`)

- [ ] **Step 6.2: прогон через build-граф.**

```powershell
$env:http_proxy=$null; $env:https_proxy=$null
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build demo-test
```

> Если `scene_io` импортирует модуль 1, а тот тянет platform-IO — проверить, что `demo-test`-модуль (target=host, optimize=Debug) компилирует его без dvui/glfw. `scene_io` НЕ зависит от GL/UI → должен пройти.

---

## Self-Review

- [ ] **Стабильный id volumes** сохраняется и восстанавливается; `next_volume_id` поднимается до `max(id)+1` (последующий add не переиспользует id). Проверено тестом Task 1.4.
- [ ] **off_id** сохраняется как есть (index-derived 1000+i), загрузка НЕ через `addOffMeshConnection` (иначе перетёрся бы). Проверено Task 2.3.
- [ ] **`.gset` совместимость:** writer эмитит дословно `f`/`s`/`c`/`v` в порядке и с числом полей из durability-research §«Формат .gset» (f=1, s=21, c=10, v=4+nverts строк). Семантика не менялась. Reader игнорирует неизвестные префиксы (как RecastDemo). Цель «читается оригинальным RecastDemo» — выполняется, т.к. `sscanf("%f"/"%d")` парсит наш `{d}`-вывод.
- [ ] **Header/checksum НЕ дублируются** — берутся из модуля 1 (`cks.putRecord`/`readRecord`). Magic-домены не конфликтуют с `'MSET'` и между собой.
- [ ] **Graceful degradation:** битый file-record → ошибка до цикла; битый per-record → warn+`break` (ограничение, см. OQ1). `.gset` битая строка → `error.BadGsetRow` (строгий парсинг — `.gset` это не наш durable-формат, fail-fast уместен; альтернатива — skip-строки — обсудить с владельцем, OQ5).
- [ ] **Path-escape** в архиве заблокирован (`isSafeRelPath`: нет `..`, абсолютных, `C:\`). Детерминизм архива — сортировка путей.
- [ ] **Pure vs disk разделено:** encode/decode/writeGsetText/readGsetText — чистые, тестируются standalone `zig test`. Disk/archive — через `std.Io.Dir` (риск нестабильного 0.16 API изолирован; рекомендация — выделить `packToBytes`/`unpackFromBytes` для disk-free теста архива).
- [ ] **Zig 0.16 риски** (compass §Caveats) учтены: writer API `Managed.writer()` (Task 3.2 примечание), `tmpDir`/`Io.Dir`-конструкция (OQ2), имена `makePath`/`deleteTree` (OQ4), sub_path в `writeAtomic` (OQ3) — все помечены как «сверить с фактическим API», pure-логика от них не зависит.
- [ ] **Порядок реализации:** Task 0 (guard модуля 1) → 1 → 2 → 3 (pure, не блокируется диском) → 4 → 5 (disk) → 6. Pure-таски дают ценность даже если disk-API потребует доработки.

---

## Команды (сводка)

```powershell
# снять прокси ВСЕГДА перед zig
$env:http_proxy=$null; $env:https_proxy=$null
$zig = "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe"

# standalone unit-тесты модуля (Task 1-5)
& $zig test demo/src/persist/scene_io.zig

# через build-граф (Task 6)
& $zig build demo-test
```

---

## Открытые вопросы к владельцу

- **OQ1 (recovery-гранулярность бинарников):** при битом per-record (volume/offmesh/archive-file) мы не можем безопасно перепрыгнуть к следующему, т.к. длина неизвестна, если `readRecord` не вернёт сдвинутый `pos` при `ChecksumMismatch`. Должен ли `readRecord` модуля 1 при mismatch всё же отдавать `payload_len` из header и двигать `pos` (тогда `continue` вместо `break` → независимый пропуск битых записей)? Это решение модуля 1, влияет на нашу graceful degradation.
- **OQ2/OQ4 (Zig 0.16 disk-API):** точная конструкция `std.Io.Dir` из tmp-handle и имена `makePath`/`deleteTree`/`deleteFile`/`writeFile` в `Io.Dir` не подтверждены в этой сессии (`io_util.zig` подтверждает только `openDir`/`iterate`/`writeFile`/`readFileAlloc`/`close`). Согласовать с модулем 1, который первым трогает `Io.Dir`-write-путь.
- **OQ3 (writeAtomic + sub_path):** принимает ли `writeAtomic(io, dir, name, bytes)` вложенный `name` вида `"edits/volumes.bin"` (создаёт temp в той же поддиректории)? Или вызывающий обязан передавать уже открытую поддиректорию? Влияет на `unpackArchive`.
- **OQ5 (.gset строгость):** при нечитаемой строке `.gset` — `error.BadGsetRow` (fail-fast, текущий выбор) или skip-строки (как RecastDemo игнорирует неизвестные префиксы, но НЕ битые известные)? RecastDemo-поведение: `sscanf` с недобором полей оставляет мусор — фактически undefined. Предлагаю fail-fast для нашего writer-output (мы его контролируем) — подтвердить.
- **OQ6 (settings источник):** строка `s` (21 поле) берётся из `Scene.settings`/`CommonSettings` (решение Q6 — единая копия). Маппинг полей `CommonSettings` → `GsetSettings` уточнить, когда `scene.zig` будет иметь финальный `settings` (сейчас писать `s` опционально, `null` = не писать).

---

## Что подтверждено / не подтверждено из Zig 0.16 stdlib

**Подтверждено (по `io_util.zig`/`navmesh_io.zig` в репозитории):**
- `std.Io.Threaded.init(alloc, .{})` → `.io()`; `std.Io.Dir.cwd()`; `dir.openDir(io, path, .{.iterate=true})`; `dir.iterate()` + `it.next(io)` → `entry.kind`/`entry.name`; `dir.close(io)`; `dir.readFileAlloc(io, path, alloc, .unlimited)`; `dir.writeFile(io, .{.sub_path,.data})`.
- `std.mem.readInt(.., .little)`, `std.mem.toBytes`, `std.mem.splitScalar`, `std.mem.tokenizeScalar`, `std.mem.trim`, `std.fmt.parseFloat`/`parseInt`, `std.mem.sort` — паттерн из `input_geom.zig`/`io_util.zig`.
- `std.array_list.Managed(T)` дефолт (CLAUDE.md); поля `InputGeom` (`volumes`, `off_*`, `next_volume_id`) `pub` и прямо доступны.

**НЕ подтверждено (реализатор обязан сверить — помечено OQ):**
- `Managed(u8).writer()` + `.print` (writergate 0.16) — Task 3.2.
- `std.testing.tmpDir` совместимость с `std.Io.Dir`; конструкция `Io.Dir` из fd — Task 4.2 (OQ2).
- `Io.Dir.makePath`/`deleteTree`/`deleteFile` имена — Task 5 (OQ4).
- Сигнатура/sub_path-семантика `writeAtomic`, наличие `checksum.zig` API (`putRecord`/`readRecord`/`Header`) — модуль 1, Task 0 guard (OQ3).
- `std.fs.path.dirnamePosix` присутствие в 0.16 — Task 5.3 (есть в `std.fs.path`; при отсутствии — ручной поиск последнего `/`).
