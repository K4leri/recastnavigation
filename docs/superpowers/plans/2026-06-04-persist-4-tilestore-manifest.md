# Persist (модуль 4): tile_store + manifest + saveScene/loadScene — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: используйте superpowers:subagent-driven-development (рекомендуется) или superpowers:executing-plans, чтобы реализовывать план задача-за-задачей. Шаги используют чекбоксы (`- [ ]`) для трекинга.

> **Дата:** 2026-06-04. **Версия Zig:** 0.16.0 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`). **Проект:** `zig-recast`, ветка `feat/debug-platform`. **Спек:** `docs/superpowers/specs/2026-06-04-00-foundation-design.md` §3.b. **Research (НЕ ре-ресёрчить):** `docs/research/persistence-durability-research.md`.

---

## Goal

Реализовать «верхний» слой durable-персистентности `.recastscene/`:
- **`tile_store.zig`** — чтение/запись тайлов навмеша по файлу на ключ `(tx,ty,layer)`: `tiles/tx_ty_layer.tile`. Тело файла = MSET/tile-blob (как `navmesh_io.zig`), обёрнутый нашим chunk-header'ом из модуля 1 (magic/version/type/payload_len/XXH3-checksum). Ключ файла берётся из заголовка тайла (`dtTileCacheLayerHeader.tx/ty/tlayer` для TileCache-blob, либо из `dtMeshHeader.x/y/layer` для прямого MSET-tile).
- **`manifest.zig`** — самоописывающийся индекс контейнера: версии форматов, список тайлов, ссылка на geometry (`scene.gset`). Пишется **последним** через atomic-rename — это точка переключения версии мира. Строгий порядок коммита: новые тайлы → fsync каждого → fsync `tiles/` → atomic-rename `manifest` → fsync корня.
- **`scene_container.zig`** — оркестратор `saveScene(scene_dir, ...)` / `loadScene(scene_dir, ...)`: writeAtomic всего (registry_io + scene_io + tile_store) в правильном порядке коммита; load в инвариантном порядке (реестры → geom/volumes/offmesh → rebuild → tiles).

**Не входит (out):** реализация модулей 1–3 (этот план их **потребляет** и явно помечает зависимости); UI-кнопки реализуются как отдельный инкремент (точки интеграции в `main.zig` описаны, не кодируются); append-only journal (этап 2, YAGNI); single-file pack/unpack архив (решение владельца Q3 — отдельный инкремент `scene_io.packArchive`, этот план только оставляет под него хук в манифесте).

---

## Architecture

```
demo/src/persist/
├── write_atomic.zig    # МОДУЛЬ 1 (ЗАВИСИМОСТЬ, не в этом плане):
│                       #   writeAtomic(io, dir, name, bytes), ChunkHeader pack/unpack,
│                       #   checksum (XXH3/xxHash64), ошибки Truncated/WrongMagic/
│                       #   WrongVersion/ChecksumMismatch, dirFsync.
├── registry_io.zig     # МОДУЛЬ 2 (ЗАВИСИМОСТЬ): areas.reg/flags.reg load/save.
├── scene_io.zig        # МОДУЛЬ 3 (ЗАВИСИМОСТЬ): scene.gset writer, volumes.bin,
│                       #   offmesh.bin load/save.
├── tile_store.zig      # ЭТОТ ПЛАН: tiles/tx_ty_layer.tile
├── manifest.zig        # ЭТОТ ПЛАН: manifest read/write + commit-порядок
└── scene_container.zig # ЭТОТ ПЛАН: saveScene/loadScene оркестратор
```

**Поток данных save:** `saveScene` берёт `*Scene` (geom/areas/flags/settings/meta) + собранный `*dt.NavMesh` (и опц. `*dtTileCache`) → пишет `scene.gset`+`*.obj` (модуль 3) → `edits/{areas.reg,flags.reg,volumes.bin,offmesh.bin}` (модули 2,3) → `tiles/*.tile` (этот план) с fsync каждого → `manifest` atomic-rename последним (этот план) → fsync корня.

**Поток данных load:** `loadScene` читает `manifest` → проверяет версии → `registry_io.load` (реестры areas/flags — СНАЧАЛА, инвариант) → `scene_io` geom/volumes/offmesh → caller делает rebuild навмеша → `tile_store` грузит тайлы (стриминг, пропуск битых).

**Ключевое решение по ключу тайла.** В `.recastscene/` тайлы могут быть двух природ (см. spec §3.b и research §«Detour TileCache»):
1. **MSET-tile** (static navmesh, как сейчас в `navmesh_io.zig`): blob начинается с `dtMeshHeader`, координаты `x/y/layer`.
2. **TileCache compressed layer** (динамика, кластер J): blob начинается с `TileCacheLayerHeader` (`src/detour_tilecache/builder.zig:18`), magic `'DTLR'` (`TILECACHE_MAGIC`), координаты `tx/ty/tlayer`.

Чтобы `tile_store` был единым, ключ `(tx,ty,layer)` вычисляется из заголовка blob'а в зависимости от `TileKind`, хранимого в нашем chunk-header `type_flags` (бит 0 = kind). Имя файла — `"{tx}_{ty}_{layer}.tile"`. Это решение фиксируется в `TileKind` enum ниже.

**Faithful-границы.** `tile_store`/`manifest`/`scene_container` — demo-уровень (`demo/src/persist/`), здесь разрешены `usize`/owned-модель. Касты на границе с i32-полями ядра (`dt.NavMesh.params.max_tiles`, `TileCacheLayerHeader.tx`) — норма (CLAUDE.md). Аддитивные read-only геттеры в `src/*` (если понадобятся, напр. итерация тайлов TileCache) помечаются явным комментарием `// additive read-only getter for persist (module 4)`.

---

## Tech Stack / сборка и тест

- **Сборка:** только Zig 0.16. Перед любым `zig build` снимать прокси:
  ```powershell
  $env:http_proxy=$null; $env:https_proxy=$null
  & "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build demo-test
  ```
- `tile_store`/`manifest`/`scene_container` импортируют `recast-nav` (для `dt.NavMesh`, `detour_tilecache`) и модули 1–3 → тестируются через **`zig build demo-test`** (агрегатор `demo/src/tests.zig`), НЕ standalone `zig test` (тот же режим, что `render/color_scheme.zig`, см. его план).
- Чисто-логические части `manifest` (парсинг/round-trip строки манифеста на байтах в памяти) пишутся **TDD** и проверяются в том же агрегаторе.
- IO-интеграция (реальная директория на диске) — integration-тест в `test/integration/` (round-trip save→load через временную папку), запуск через `zig build` integration-шаг (`build.zig:125`).

---

## File Structure

- **Create** `demo/src/persist/tile_store.zig` — `TileKind`, `TileKey`, `keyFromBlob`, `tileFileName`, `writeTile`, `readTile`, `saveAllTiles`, `loadAllTiles`. Тесты в том же файле.
- **Create** `demo/src/persist/manifest.zig` — `Manifest`, `ManifestEntry`, `serialize`/`parse`, `commitManifest` (atomic-rename). Тесты в том же файле.
- **Create** `demo/src/persist/scene_container.zig` — `saveScene`, `loadScene`, `SaveInput`, `LoadResult`. Тесты-заглушки + хук для integration.
- **Modify** `demo/src/tests.zig` — добавить три модуля в агрегатор.
- **Create** `test/integration/persist_roundtrip.zig` — round-trip всей сцены через временную директорию (см. Task 5).
- **Modify** `build.zig` — добавить integration-файл в integration-шаг (если не подхватывается через `import`).
- **(описать, НЕ кодировать)** `demo/src/main.zig` — точки интеграции кнопок Save Scene / Load Scene (Task 6).

---

## Зависимости и порядок реализации

ЭТОТ ПЛАН зависит от **модуля 1** (обязательно) и **модулей 2,3** (для оркестратора). Реализовывать строго ПОСЛЕ них. Интерфейсы модуля 1, на которые опираемся ДОСЛОВНО (определены в `write_atomic.zig`, см. spec §3.b «Конкретные модули» и общий интерфейс задания):

```zig
// === ИНТЕРФЕЙС МОДУЛЯ 1 (write_atomic.zig) — потребляется здесь как есть ===

/// Durable atomic write: createFileAtomic -> write -> flush -> File.sync ->
/// replace -> dirFsync(POSIX; Windows no-op). `dir` — открытый каталог-назначение.
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void;

/// fsync дескриптора каталога (POSIX; Windows no-op). Вызывается после
/// группы atomic-rename'ов (commit-порядок).
pub fn dirFsync(io: std.Io, dir: std.Io.Dir) !void;

/// Заголовок записи/файла. Размер фиксирован = HEADER_SIZE байт (LE).
/// payload_len — длина тела (для skip битого). checksum = XXH3(type_flags ||
/// header_без_csum || payload).
pub const ChunkHeader = struct {
    magic: u32,
    version: u32,
    type_flags: u16,
    payload_len: u64,
    checksum: u64,

    pub const SIZE: usize = 4 + 4 + 2 + 8 + 8; // = 26, см. модуль 1
    pub fn write(self: ChunkHeader, buf: *std.array_list.Managed(u8)) !void;
    /// Читает заголовок из data[0..]. Не валидирует checksum/payload.
    pub fn read(data: []const u8) error{Truncated}!ChunkHeader;
};

/// Считает XXH3/xxHash64(type_flags || header_без_csum || payload).
pub fn checksum(type_flags: u16, header_no_csum: []const u8, payload: []const u8) u64;

/// Упаковать [header][payload] с пересчитанным checksum в buf.
pub fn packChunk(buf: *std.array_list.Managed(u8), magic: u32, version: u32,
    type_flags: u16, payload: []const u8) !void;

/// Проверить и вернуть payload-срез из data; ошибки Truncated/WrongMagic/
/// WrongVersion/ChecksumMismatch.
pub fn unpackChunk(data: []const u8, expect_magic: u32, max_version: u32)
    error{ Truncated, WrongMagic, WrongVersion, ChecksumMismatch }!struct {
        version: u32, type_flags: u16, payload: []const u8, total: usize,
    };

pub const Error = error{ Truncated, WrongMagic, WrongVersion, ChecksumMismatch };
```

> **ВАЖНО (риск R1 из spec):** точная сигнатура `writeAtomic`/`ChunkHeader.SIZE`/`packChunk` фиксируется при реализации модуля 1. Если они разойдутся — править этот план синхронно. Здесь предполагается интерфейс из spec §3.b. `HEADER_SIZE` взять из `write_atomic.zig` (`ChunkHeader.SIZE`), не хардкодить число.

Интерфейсы модулей 2,3 (потребляются оркестратором):
```zig
// registry_io.zig (модуль 2):
pub fn saveAreas(io: std.Io, dir: std.Io.Dir, areas: *const AreaRegistry) !void;
pub fn loadAreas(io: std.Io, dir: std.Io.Dir, areas: *AreaRegistry) Error!void;
pub fn saveFlags(io: std.Io, dir: std.Io.Dir, flags: *const FlagRegistry) !void;
pub fn loadFlags(io: std.Io, dir: std.Io.Dir, flags: *FlagRegistry) Error!void;
// scene_io.zig (модуль 3):
pub fn saveGset(io: std.Io, dir: std.Io.Dir, geom: *const InputGeom, settings: *const CommonSettings) !void;
pub fn saveVolumes(io: std.Io, dir: std.Io.Dir, geom: *const InputGeom) !void;
pub fn saveOffmesh(io: std.Io, dir: std.Io.Dir, geom: *const InputGeom) !void;
pub fn loadGeom(io: std.Io, dir: std.Io.Dir, geom: *InputGeom, settings: *CommonSettings) Error!void;
pub fn loadVolumes(io: std.Io, dir: std.Io.Dir, geom: *InputGeom) Error!void;
pub fn loadOffmesh(io: std.Io, dir: std.Io.Dir, geom: *InputGeom) Error!void;
```
Если фактические сигнатуры модулей 2/3 будут другими — оркестратор (`scene_container.zig`) адаптируется; tile_store/manifest от них НЕ зависят.

**Порядок задач:** Task 1 (tile_store, чисто над модулем 1) → Task 2 (manifest, чисто над модулем 1) → Task 3 (commit-порядок в manifest) → Task 4 (scene_container, нужны модули 2,3) → Task 5 (integration) → Task 6 (UI-точки, описание).

---

## Task 1: tile_store.zig — per-tile файлы

**Files:**
- Create: `demo/src/persist/tile_store.zig`
- Modify: `demo/src/tests.zig` (добавить импорт)

Зависит от: **модуль 1** (`packChunk`/`unpackChunk`/`writeAtomic`/`ChunkHeader`).

- [ ] **Step 1 (TDD): ключ тайла и имя файла из blob'а**

Чисто-логическая часть — пишется первой, тестируется в памяти. Создать `demo/src/persist/tile_store.zig`:

```zig
//! tile_store — per-tile файлы контейнера `.recastscene/tiles/`.
//! Один файл на ключ (tx,ty,layer): `tiles/tx_ty_layer.tile`.
//! Тело файла = chunk(модуль 1){ magic='TILE', version=1, type_flags=kind,
//! payload = tile-blob }. payload-blob — это либо MSET-tile (dtMeshHeader),
//! либо TileCache compressed layer (TileCacheLayerHeader, magic 'DTLR').
//! Ключ берётся из заголовка blob'а (см. keyFromBlob).
//!
//! ЗАВИСИТ от модуля 1 (write_atomic.zig): packChunk/unpackChunk/writeAtomic/ChunkHeader.

const std = @import("std");
const recast = @import("recast-nav");
const wa = @import("write_atomic.zig");

const dt = recast.detour;
const tc = recast.detour_tilecache;

/// Магия нашего chunk-обёртки тайла (НЕ путать с внутренним 'DTLR' blob'а).
pub const TILE_MAGIC: u32 = 0x454C4954; // 'TILE' (LE: 'T''I''L''E')
pub const TILE_VERSION: u32 = 1;

/// Природа payload-blob'а внутри .tile. Кодируется в chunk-header type_flags бит 0.
pub const TileKind = enum(u1) {
    /// MSET static-navmesh tile: payload начинается с dtMeshHeader (x/y/layer).
    mset = 0,
    /// TileCache compressed layer: payload начинается с TileCacheLayerHeader
    /// (magic 'DTLR', tx/ty/tlayer).
    tilecache = 1,
};

pub const TileKey = struct {
    tx: i32,
    ty: i32,
    layer: i32,
};

/// Извлечь ключ (tx,ty,layer) из tile-blob'а по его природе. Faithful-доступ к
/// заголовкам ядра; касты i32->i32 не нужны (поля уже i32).
pub fn keyFromBlob(kind: TileKind, blob: []const u8) error{Truncated}!TileKey {
    switch (kind) {
        .tilecache => {
            const H = tc.TileCacheLayerHeader;
            if (blob.len < @sizeOf(H)) return error.Truncated;
            const h: *const H = @ptrCast(@alignCast(blob.ptr));
            return .{ .tx = h.tx, .ty = h.ty, .layer = h.tlayer };
        },
        .mset => {
            // dtMeshHeader: поля x,y,layer (i32). Берём через геттер ядра.
            const H = dt.MeshHeader;
            if (blob.len < @sizeOf(H)) return error.Truncated;
            const h: *const H = @ptrCast(@alignCast(blob.ptr));
            return .{ .tx = h.x, .ty = h.y, .layer = h.layer };
        },
    }
}

/// Имя файла тайла. Буфер должен быть >= 48 байт. Возвращает срез внутри buf.
pub fn tileFileName(buf: []u8, key: TileKey) []const u8 {
    return std.fmt.bufPrint(buf, "{d}_{d}_{d}.tile", .{ key.tx, key.ty, key.layer }) catch unreachable;
}

test "tileFileName format" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("3_5_0.tile", tileFileName(&buf, .{ .tx = 3, .ty = 5, .layer = 0 }));
    try std.testing.expectEqualStrings("-1_0_2.tile", tileFileName(&buf, .{ .tx = -1, .ty = 0, .layer = 2 }));
}

test "keyFromBlob tilecache reads header coords" {
    var hdr = std.mem.zeroes(tc.TileCacheLayerHeader);
    hdr.magic = tc.TILECACHE_MAGIC;
    hdr.version = tc.TILECACHE_VERSION;
    hdr.tx = 7;
    hdr.ty = 8;
    hdr.tlayer = 1;
    const blob = std.mem.asBytes(&hdr);
    const key = try keyFromBlob(.tilecache, blob);
    try std.testing.expectEqual(@as(i32, 7), key.tx);
    try std.testing.expectEqual(@as(i32, 8), key.ty);
    try std.testing.expectEqual(@as(i32, 1), key.layer);
}

test "keyFromBlob truncated" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.Truncated, keyFromBlob(.tilecache, &tiny));
}
```

> **Проверить при реализации:** имя экспортируемого типа заголовка static-tile в `recast.detour` (предполагается `dt.MeshHeader` с полями `x/y/layer`; если в порте он называется иначе или поля называются иначе — подставить фактическое). Если static-tile в этом проекте сохраняется ТОЛЬКО через `navmesh_io.MSET` целиком (а не per-tile с координатами в заголовке), то для этапа 1 можно ограничиться `TileKind.tilecache`, а MSET-ветку оставить за флагом и пометить TODO. Это открытый вопрос к владельцу (см. ниже).

- [ ] **Step 2: writeTile / readTile (один тайл, chunk-обёртка)**

Добавить в `tile_store.zig`:

```zig
/// Результат чтения тайла: природа + срез payload (внутри owned-буфера caller'а).
pub const ReadTile = struct {
    kind: TileKind,
    key: TileKey,
    payload: []const u8, // срез внутри прочитанного файла
};

/// Сериализовать один tile-blob в chunk-байты (в buf). Не пишет на диск.
pub fn packTile(buf: *std.array_list.Managed(u8), kind: TileKind, blob: []const u8) !void {
    const type_flags: u16 = @intFromEnum(kind);
    try wa.packChunk(buf, TILE_MAGIC, TILE_VERSION, type_flags, blob);
}

/// Записать один тайл durably в каталог tiles_dir. Имя берётся из ключа blob'а.
pub fn writeTile(
    io: std.Io,
    alloc: std.mem.Allocator,
    tiles_dir: std.Io.Dir,
    kind: TileKind,
    blob: []const u8,
) !void {
    const key = try keyFromBlob(kind, blob);
    var name_buf: [48]u8 = undefined;
    const name = tileFileName(&name_buf, key);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try packTile(&buf, kind, blob);

    try wa.writeAtomic(io, tiles_dir, name, buf.items);
}

/// Прочитать и распаковать один файл .tile из data (весь файл). Возвращает
/// природу/ключ/payload. Ошибки модуля 1 (битый тайл -> ChecksumMismatch и т.п.).
pub fn parseTile(data: []const u8) wa.Error!ReadTile {
    const r = try wa.unpackChunk(data, TILE_MAGIC, TILE_VERSION);
    const kind: TileKind = @enumFromInt(@as(u1, @truncate(r.type_flags)));
    const key = keyFromBlob(kind, r.payload) catch return error.Truncated;
    return .{ .kind = kind, .key = key, .payload = r.payload };
}

test "packTile/parseTile round-trip" {
    const alloc = std.testing.allocator;
    var hdr = std.mem.zeroes(tc.TileCacheLayerHeader);
    hdr.magic = tc.TILECACHE_MAGIC;
    hdr.version = tc.TILECACHE_VERSION;
    hdr.tx = 2; hdr.ty = 3; hdr.tlayer = 0;
    const blob = std.mem.asBytes(&hdr);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try packTile(&buf, .tilecache, blob);

    const got = try parseTile(buf.items);
    try std.testing.expectEqual(TileKind.tilecache, got.kind);
    try std.testing.expectEqual(@as(i32, 2), got.key.tx);
    try std.testing.expectEqualSlices(u8, blob, got.payload);
}

test "parseTile detects corruption" {
    const alloc = std.testing.allocator;
    var hdr = std.mem.zeroes(tc.TileCacheLayerHeader);
    hdr.magic = tc.TILECACHE_MAGIC; hdr.version = tc.TILECACHE_VERSION;
    const blob = std.mem.asBytes(&hdr);
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try packTile(&buf, .tilecache, blob);
    // флипнуть байт в payload -> checksum mismatch
    buf.items[buf.items.len - 1] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, parseTile(buf.items));
}
```

- [ ] **Step 3: saveAllTiles из dt.NavMesh (MSET-набор)**

Итерация валидных тайлов навмеша как в `navmesh_io.zig:31-33,48-54`. Каждый тайл — отдельный файл. Возвращает список ключей для записи в манифест.

```zig
/// Записать ВСЕ валидные тайлы static-navmesh в tiles_dir, по файлу на тайл.
/// Возвращает owned-список TileKey (caller освобождает) — для манифеста.
/// fsync каждого файла делает writeAtomic; fsync самого tiles_dir — caller
/// (commit-порядок, см. manifest.commitTiles).
pub fn saveAllTiles(
    io: std.Io,
    alloc: std.mem.Allocator,
    tiles_dir: std.Io.Dir,
    mesh: *const dt.NavMesh,
) ![]TileKey {
    var keys = std.array_list.Managed(TileKey).init(alloc);
    errdefer keys.deinit();

    for (mesh.tiles) |*t| {
        if (t.header == null or t.data_size == 0) continue;
        const blob = t.data[0..@intCast(t.data_size)];
        try writeTile(io, alloc, tiles_dir, .mset, blob);
        try keys.append(try keyFromBlob(.mset, blob));
    }
    return keys.toOwnedSlice();
}
```

- [ ] **Step 4: loadTile (стриминг по ключу, graceful skip)**

`tile_store` не строит навмеш сам (это делает caller через `mesh.addTile`), а отдаёт owned-копию payload по ключу. Битый файл → ошибка, caller логирует и пропускает.

```zig
/// Прочитать файл тайла по ключу из tiles_dir. Возвращает owned-копию blob'а
/// (caller освобождает и передаёт в mesh.addTile / tileCache.addTile).
/// Ошибки: FileNotFound (нет файла) + Error (битый тайл).
pub fn loadTile(
    io: std.Io,
    alloc: std.mem.Allocator,
    tiles_dir: std.Io.Dir,
    key: TileKey,
) (wa.Error || std.Io.Dir.OpenError || error{ OutOfMemory, Truncated })!ReadTile {
    var name_buf: [48]u8 = undefined;
    const name = tileFileName(&name_buf, key);
    const data = try tiles_dir.readFileAlloc(io, name, alloc, .unlimited);
    errdefer alloc.free(data);
    const parsed = try parseTile(data); // payload — срез внутри data
    return .{ .kind = parsed.kind, .key = parsed.key, .payload = data }; // payload=весь файл; см. примечание
}
```

> **Примечание по владению:** `parseTile` отдаёт срез *внутри* файла. Для loadTile удобнее вернуть весь owned-`data` (caller освобождает один буфер) и отдельно offset payload, ИЛИ скопировать payload в новый буфер и освободить `data`. Выбрать второй вариант (чистое владение) при реализации:
> ```zig
> const parsed = try parseTile(data);
> const owned = try alloc.dupe(u8, parsed.payload);
> alloc.free(data);
> return .{ .kind = parsed.kind, .key = parsed.key, .payload = owned };
> ```
> Тогда сигнатура освобождения у caller'а — `alloc.free(read.payload)`. Зафиксировать в doc-комментарии.

- [ ] **Step 5: подключить в агрегатор тестов**

Изменить `demo/src/tests.zig`, добавив после строки `_ = @import("render/color_scheme.zig");`:
```zig
    _ = @import("persist/tile_store.zig");
```

- [ ] **Step 6: собрать и прогнать**
```powershell
$env:http_proxy=$null; $env:https_proxy=$null
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build demo-test
```
Ожидание: все `tile_store`-тесты зелёные.

---

## Task 2: manifest.zig — индекс контейнера

**Files:**
- Create: `demo/src/persist/manifest.zig`
- Modify: `demo/src/tests.zig`

Зависит от: **модуль 1**. Манифест — это chunk(модуль 1){ magic='RMAN', version=1, payload = сериализованная структура }.

- [ ] **Step 1 (TDD): структура и сериализация payload'а**

Манифест self-describing: версии форматов всех под-файлов, ссылка на geometry, список тайлов. Бинарный payload (фиксированный заголовок + массивы), обёрнут chunk-header'ом снаружи (его checksum защищает весь манифест целиком).

```zig
//! manifest — индекс контейнера `.recastscene/manifest`.
//! Самоописывающий чанк (модуль 1): magic='RMAN', version=1, payload =
//! { format-версии под-форматов, ссылка на geometry (scene.gset), список
//! TileKey }. Пишется ПОСЛЕДНИМ atomic-rename'ом = точка переключения версии
//! мира (commit-порядок: тайлы->fsync->manifest->fsync корня).
//!
//! ЗАВИСИТ от модуля 1 (write_atomic.zig) и tile_store.zig (TileKey).

const std = @import("std");
const wa = @import("write_atomic.zig");
const tile_store = @import("tile_store.zig");

pub const MANIFEST_MAGIC: u32 = 0x4E414D52; // 'RMAN'
pub const MANIFEST_VERSION: u32 = 1;
pub const MANIFEST_NAME = "manifest";

/// Версии под-форматов контейнера — чтобы loadScene мог отказать/мигрировать
/// конкретный под-файл, не роняя весь мир (spec §Версионирование).
pub const FormatVersions = struct {
    scene: u32 = 1, // общий FORMAT_VERSION сцены (scene.zig)
    areas: u32 = 1,
    flags: u32 = 1,
    volumes: u32 = 1,
    offmesh: u32 = 1,
    tile: u32 = tile_store.TILE_VERSION,
};

pub const Manifest = struct {
    versions: FormatVersions = .{},
    /// Относительный путь к geometry-описанию внутри контейнера.
    gset_name: []const u8 = "scene.gset",
    /// Список тайлов, присутствующих в tiles/. Порядок не значим.
    tiles: []const tile_store.TileKey = &.{},

    /// Сериализовать payload (БЕЗ chunk-header — его добавит writeManifest).
    /// Формат payload (LE):
    ///   FormatVersions: 6 x u32
    ///   gset_name: u32 len + bytes
    ///   tiles: u32 count + count*(3 x i32)
    pub fn serializePayload(self: Manifest, buf: *std.array_list.Managed(u8)) !void {
        const put32 = struct {
            fn f(b: *std.array_list.Managed(u8), v: u32) !void {
                try b.appendSlice(&std.mem.toBytes(v));
            }
        }.f;
        try put32(buf, self.versions.scene);
        try put32(buf, self.versions.areas);
        try put32(buf, self.versions.flags);
        try put32(buf, self.versions.volumes);
        try put32(buf, self.versions.offmesh);
        try put32(buf, self.versions.tile);
        try put32(buf, @intCast(self.gset_name.len));
        try buf.appendSlice(self.gset_name);
        try put32(buf, @intCast(self.tiles.len));
        for (self.tiles) |k| {
            try buf.appendSlice(&std.mem.toBytes(k.tx));
            try buf.appendSlice(&std.mem.toBytes(k.ty));
            try buf.appendSlice(&std.mem.toBytes(k.layer));
        }
    }
};

/// Курсор чтения payload'а (аналог Reader из navmesh_io.zig:59-81).
const PReader = struct {
    data: []const u8,
    pos: usize = 0,
    fn u32_(self: *PReader) error{Truncated}!u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn i32_(self: *PReader) error{Truncated}!i32 {
        return @bitCast(try self.u32_());
    }
    fn bytes(self: *PReader, n: usize) error{Truncated}![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Распарсить payload в Manifest. gset_name и tiles — owned (caller освобождает
/// через freeManifest).
pub fn parsePayload(alloc: std.mem.Allocator, payload: []const u8) error{ Truncated, OutOfMemory }!Manifest {
    var r = PReader{ .data = payload };
    var m = Manifest{};
    m.versions = .{
        .scene = try r.u32_(),
        .areas = try r.u32_(),
        .flags = try r.u32_(),
        .volumes = try r.u32_(),
        .offmesh = try r.u32_(),
        .tile = try r.u32_(),
    };
    const gname_len = try r.u32_();
    const gname = try r.bytes(gname_len);
    m.gset_name = try alloc.dupe(u8, gname);
    errdefer alloc.free(m.gset_name);

    const count = try r.u32_();
    var tiles = try alloc.alloc(tile_store.TileKey, count);
    errdefer alloc.free(tiles);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        tiles[i] = .{ .tx = try r.i32_(), .ty = try r.i32_(), .layer = try r.i32_() };
    }
    m.tiles = tiles;
    return m;
}

pub fn freeManifest(alloc: std.mem.Allocator, m: Manifest) void {
    alloc.free(m.gset_name);
    alloc.free(m.tiles);
}

test "manifest payload round-trip" {
    const alloc = std.testing.allocator;
    const keys = [_]tile_store.TileKey{
        .{ .tx = 0, .ty = 0, .layer = 0 },
        .{ .tx = -2, .ty = 5, .layer = 1 },
    };
    const m = Manifest{ .gset_name = "scene.gset", .tiles = &keys };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try m.serializePayload(&buf);

    const got = try parsePayload(alloc, buf.items);
    defer freeManifest(alloc, got);

    try std.testing.expectEqualStrings("scene.gset", got.gset_name);
    try std.testing.expectEqual(@as(usize, 2), got.tiles.len);
    try std.testing.expectEqual(@as(i32, -2), got.tiles[1].tx);
    try std.testing.expectEqual(tile_store.TILE_VERSION, got.versions.tile);
}

test "manifest truncated payload" {
    const alloc = std.testing.allocator;
    var tiny = [_]u8{0} ** 8;
    try std.testing.expectError(error.Truncated, parsePayload(alloc, &tiny));
}
```

- [ ] **Step 2: writeManifest / readManifest (chunk-обёртка над payload'ом)**

```zig
/// Записать манифест durably (atomic-rename) в scene_dir. ПОСЛЕДНИЙ шаг коммита.
/// fsync файла делает writeAtomic; fsync scene_dir — caller (commitWorld).
pub fn writeManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir: std.Io.Dir,
    m: Manifest,
) !void {
    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try m.serializePayload(&payload);

    var chunk = std.array_list.Managed(u8).init(alloc);
    defer chunk.deinit();
    try wa.packChunk(&chunk, MANIFEST_MAGIC, MANIFEST_VERSION, 0, payload.items);

    try wa.writeAtomic(io, scene_dir, MANIFEST_NAME, chunk.items);
}

/// Прочитать манифест. Битый манифест = фатально (без него мир не загрузить).
pub fn readManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir: std.Io.Dir,
) !Manifest {
    const data = try scene_dir.readFileAlloc(io, MANIFEST_NAME, alloc, .unlimited);
    defer alloc.free(data);
    const r = try wa.unpackChunk(data, MANIFEST_MAGIC, MANIFEST_VERSION);
    return parsePayload(alloc, r.payload);
}
```

- [ ] **Step 3: подключить в агрегатор**

`demo/src/tests.zig`: добавить `_ = @import("persist/manifest.zig");`. Собрать `zig build demo-test`.

---

## Task 3: commit-порядок (в manifest.zig)

**Files:** Modify `demo/src/persist/manifest.zig`.

Spec §3.b «commit-порядок»: новые тайлы → fsync каждого → fsync `tiles/` → atomic-rename `manifest` → fsync корня. fsync каждого тайла делает `writeTile`/`writeAtomic` (модуль 1). Здесь — финальные barrier'ы.

- [ ] **Step 1: commitWorld**

```zig
/// Завершить коммит мира ПОСЛЕ того как все тайлы записаны (writeTile сделал
/// fsync каждого) и все edits-файлы записаны: fsync tiles_dir -> atomic-rename
/// manifest -> fsync scene_dir. Это атомарная точка переключения версии мира.
pub fn commitWorld(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir: std.Io.Dir,
    tiles_dir: std.Io.Dir,
    m: Manifest,
) !void {
    // 1) Все тайлы уже на диске (writeTile -> writeAtomic делает File.sync+replace).
    //    Барьер каталога tiles/: directory-entry новых тайлов на диск.
    try wa.dirFsync(io, tiles_dir);
    // 2) Манифест — atomic-rename (writeAtomic внутри делает File.sync+replace).
    try writeManifest(io, alloc, scene_dir, m);
    // 3) Барьер корня: directory-entry нового manifest на диск.
    try wa.dirFsync(io, scene_dir);
}
```

> **Инвариант (НЕ нарушать):** `commitWorld` вызывается ТОЛЬКО после успешной записи ВСЕХ тайлов и edits-файлов. Если хоть один тайл упал — манифест не переключается, старая версия мира остаётся валидной (старый manifest + старые тайлы на месте, atomic-rename не тронул их). Это даёт «всё-или-ничего» на уровне переключения манифеста.

- [ ] **Step 2: тест порядка (логический, через мок-каталог опционально)**

Полный тест commitWorld требует реального каталога → переносится в integration (Task 5). Здесь добавить doc-тест-комментарий и оставить unit-покрытие на serialize/parse.

---

## Task 4: scene_container.zig — saveScene / loadScene

**Files:**
- Create: `demo/src/persist/scene_container.zig`
- Modify: `demo/src/tests.zig`

Зависит от: модули 1,2,3 + tile_store + manifest. Оркестратор склеивает всё в правильном порядке коммита и загрузки.

- [ ] **Step 1: SaveInput / LoadResult и saveScene**

```zig
//! scene_container — оркестратор saveScene/loadScene для `.recastscene/`.
//! Склеивает registry_io (модуль 2) + scene_io (модуль 3) + tile_store +
//! manifest в строгом порядке коммита (spec §3.b):
//!   geom/edits -> тайлы (fsync каждого) -> fsync tiles/ -> manifest (atomic) ->
//!   fsync корня.
//! loadScene соблюдает ИНВАРИАНТ порядка загрузки: реестры areas/flags СНАЧАЛА,
//! затем geom/volumes/offmesh, затем rebuild (caller), затем tiles.
//!
//! ЗАВИСИТ от модулей 1,2,3, tile_store, manifest.

const std = @import("std");
const recast = @import("recast-nav");
const wa = @import("write_atomic.zig");
const registry_io = @import("registry_io.zig");
const scene_io = @import("scene_io.zig");
const tile_store = @import("tile_store.zig");
const manifest = @import("manifest.zig");

const dt = recast.detour;
const scene_mod = @import("../scene.zig");

/// Всё, что нужно для сохранения сцены. Caller владеет указателями.
pub const SaveInput = struct {
    scene: *const scene_mod.Scene, // geom + meta (areas/flags пока через scene.zig геттеры/обёртки)
    areas: *const registry_io.AreaRegistry,
    flags: *const registry_io.FlagRegistry,
    settings: *const recast.???.CommonSettings, // фактический тип из sample.zig
    mesh: *const dt.NavMesh, // собранный навмеш (источник тайлов)
};

/// Сохранить сцену в директорию scene_dir_path (создаётся, если нет).
/// Порядок коммита строгий (см. модульный комментарий).
pub fn saveScene(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir_path: []const u8,
    in: SaveInput,
) !void {
    // 0) Создать контейнер и поддиректории.
    try std.Io.Dir.cwd().makePath(io, scene_dir_path);
    var scene_dir = try std.Io.Dir.cwd().openDir(io, scene_dir_path, .{});
    defer scene_dir.close(io);
    try scene_dir.makePath(io, "edits");
    try scene_dir.makePath(io, "tiles");
    var edits_dir = try scene_dir.openDir(io, "edits", .{});
    defer edits_dir.close(io);
    var tiles_dir = try scene_dir.openDir(io, "tiles", .{ .iterate = true });
    defer tiles_dir.close(io);

    // 1) Геометрия: scene.gset (текст, as-is) + *.obj (модуль 3).
    try scene_io.saveGset(io, scene_dir, &in.scene.geom, in.settings);

    // 2) edits/: реестры (модуль 2) + volumes/offmesh (модуль 3). Каждый -
    //    atomic-rename с fsync файла внутри (модуль 1).
    try registry_io.saveAreas(io, edits_dir, in.areas);
    try registry_io.saveFlags(io, edits_dir, in.flags);
    try scene_io.saveVolumes(io, edits_dir, &in.scene.geom);
    try scene_io.saveOffmesh(io, edits_dir, &in.scene.geom);
    try wa.dirFsync(io, edits_dir); // барьер каталога edits/

    // 3) Тайлы: по файлу, fsync каждого внутри writeTile. Собираем ключи.
    const keys = try tile_store.saveAllTiles(io, alloc, tiles_dir, in.mesh);
    defer alloc.free(keys);

    // 4) Манифест ПОСЛЕДНИМ + барьеры (commit-порядок).
    const m = manifest.Manifest{
        .versions = .{},
        .gset_name = "scene.gset",
        .tiles = keys,
    };
    try manifest.commitWorld(io, alloc, scene_dir, tiles_dir, m);
}
```

> **Уточнить при реализации:** точный тип `CommonSettings` (из `demo/src/sample.zig`) и как `Scene` отдаёт areas/flags. На момент этого плана `scene.zig` (skeleton) ещё НЕ владеет registries (foundation step 5) — поэтому `SaveInput` принимает `areas`/`flags` ОТДЕЛЬНО (через переходные обёртки активной сцены, spec Q2). Когда step 5 завершится — переместить их в `scene`. Псевдо-тип `recast.???.CommonSettings` заменить на фактический импорт `@import("../sample.zig").CommonSettings`.

- [ ] **Step 2: loadScene с инвариантом порядка**

```zig
/// Результат загрузки: caller получает заполненные geom/areas/flags/settings и
/// делает rebuild навмеша сам, затем зовёт loadTilesInto.
pub const LoadResult = struct {
    versions: manifest.FormatVersions,
    tiles: []const tile_store.TileKey, // owned; освободить через manifest.freeManifest-аналог
};

/// Фаза 1 загрузки: manifest -> реестры -> geom/volumes/offmesh.
/// ИНВАРИАНТ: areas/flags грузятся ДО geom/volumes (иначе area-id в volume даст
/// fallback-цвет/cost/flags, spec §«Порядок загрузки»).
/// Caller после этого делает rebuild навмеша, затем loadTilesInto (фаза 2).
pub fn loadScene(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir_path: []const u8,
    out_geom: *scene_io.InputGeom,
    out_areas: *registry_io.AreaRegistry,
    out_flags: *registry_io.FlagRegistry,
    out_settings: *@import("../sample.zig").CommonSettings,
) !LoadResult {
    var scene_dir = try std.Io.Dir.cwd().openDir(io, scene_dir_path, .{});
    defer scene_dir.close(io);

    // 0) Манифест ПЕРВЫМ (точка истины версий и списка тайлов). Битый = фатально.
    const m = try manifest.readManifest(io, alloc, scene_dir);
    // tiles переносим в LoadResult; gset_name освобождаем здесь.
    alloc.free(m.gset_name);

    var edits_dir = scene_dir.openDir(io, "edits", .{}) catch |e| switch (e) {
        // Нет каталога edits/ -> пустые реестры (graceful, spec edge "отсутствие .regset").
        error.FileNotFound => {
            return .{ .versions = m.versions, .tiles = m.tiles };
        },
        else => return e,
    };
    defer edits_dir.close(io);

    // 1) РЕЕСТРЫ СНАЧАЛА (инвариант). Отсутствие/битость .reg -> дефолтные
    //    реестры + лог (graceful). loadAreas/loadFlags сами обрабатывают
    //    FileNotFound -> оставить дефолт.
    registry_io.loadAreas(io, edits_dir, out_areas) catch |e| switch (e) {
        error.FileNotFound, error.ChecksumMismatch, error.WrongMagic, error.WrongVersion, error.Truncated => {
            std.log.warn("persist: areas.reg missing/corrupt ({any}); using defaults", .{e});
        },
        else => return e,
    };
    registry_io.loadFlags(io, edits_dir, out_flags) catch |e| switch (e) {
        error.FileNotFound, error.ChecksumMismatch, error.WrongMagic, error.WrongVersion, error.Truncated => {
            std.log.warn("persist: flags.reg missing/corrupt ({any}); using defaults", .{e});
        },
        else => return e,
    };

    // 2) geom (.gset/.obj) + volumes + offmesh ПОСЛЕ реестров.
    try scene_io.loadGeom(io, scene_dir, out_geom, out_settings);
    scene_io.loadVolumes(io, edits_dir, out_geom) catch |e| std.log.warn("persist: volumes.bin: {any}", .{e});
    scene_io.loadOffmesh(io, edits_dir, out_geom) catch |e| std.log.warn("persist: offmesh.bin: {any}", .{e});

    // tiles НЕ грузим здесь — caller сначала делает rebuild, затем loadTilesInto.
    return .{ .versions = m.versions, .tiles = m.tiles };
}

/// Фаза 2: загрузить тайлы из манифеста в уже построенный навмеш. Битый/
/// отсутствующий тайл -> пропуск+лог (graceful degradation, spec §3.b).
pub fn loadTilesInto(
    io: std.Io,
    alloc: std.mem.Allocator,
    scene_dir_path: []const u8,
    keys: []const tile_store.TileKey,
    mesh: *dt.NavMesh,
) !void {
    var scene_dir = try std.Io.Dir.cwd().openDir(io, scene_dir_path, .{});
    defer scene_dir.close(io);
    var tiles_dir = try scene_dir.openDir(io, "tiles", .{});
    defer tiles_dir.close(io);

    for (keys) |key| {
        const rt = tile_store.loadTile(io, alloc, tiles_dir, key) catch |e| {
            std.log.warn("persist: skip tile {d}_{d}_{d}: {any}", .{ key.tx, key.ty, key.layer, e });
            continue;
        };
        // payload — owned-копия (см. примечание loadTile). mesh.addTile с
        // free_data=true забирает владение, как navmesh_io.zig:111.
        const data = try alloc.dupe(u8, rt.payload);
        alloc.free(rt.payload);
        _ = mesh.addTile(data, dt.TileFlags{ .free_data = true }, 0) catch |e| {
            std.log.warn("persist: addTile failed {d}_{d}_{d}: {any}", .{ key.tx, key.ty, key.layer, e });
            alloc.free(data);
        };
    }
    _ = alloc; // keys освобождает caller
}

/// Освободить tiles-список из LoadResult.
pub fn freeLoadResult(alloc: std.mem.Allocator, r: LoadResult) void {
    alloc.free(r.tiles);
}
```

> **Edge «неизвестный area-id»:** не ошибка персистентности — это семантика рендера/cost. Гарантируется ИНВАРИАНТОМ порядка (реестры до geom): если area-id из volume отсутствует в загруженном `areas.reg`, рендер берёт fallback-цвет, но НЕ падает. Тест в Task 5 проверяет, что при загрузке в правильном порядке area-id резолвится; при намеренной порче порядка — деградирует, не крашится.

> **Edge «битый тайл»:** `loadTile` возвращает `ChecksumMismatch`/`Truncated`/`FileNotFound` → `loadTilesInto` ловит, логирует, `continue`. Мир грузится без этого тайла.

> **Edge «отсутствует .regset/edits»:** `openDir("edits")` → `FileNotFound` → ранний возврат с дефолтными реестрами; `loadAreas`/`loadFlags` `FileNotFound` → дефолты + warn.

- [ ] **Step 3: подключить в агрегатор**

`demo/src/tests.zig`: `_ = @import("persist/scene_container.zig");`. Собрать `zig build demo-test`. На этом этапе модули 2,3 должны существовать (зависимость) — иначе сборка упадёт на импортах; это сигнал, что Task 4 нельзя начинать раньше модулей 2,3.

---

## Task 5: Integration round-trip тест

**Files:**
- Create: `test/integration/persist_roundtrip.zig`
- Modify: `build.zig` (если integration-шаг не подхватывает файл через общий импорт — добавить).

Полный round-trip всей сцены через реальную временную директорию: geom+registries+volumes+offmesh+navmesh-tiles → save → load → сравнить. Плюс edge-кейсы.

- [ ] **Step 1: round-trip happy path**

```zig
//! Integration: durable round-trip сцены (.recastscene/) save -> load -> equal.
const std = @import("std");
const recast = @import("recast-nav");
const scene_container = @import("../../demo/src/persist/scene_container.zig");
const tile_store = @import("../../demo/src/persist/tile_store.zig");
const manifest = @import("../../demo/src/persist/manifest.zig");

fn tmpSceneDir(alloc: std.mem.Allocator) ![]u8 {
    // Уникальная подпапка в системном tmp (Io.Dir). Имя из timestamp.
    const ts = std.time.nanoTimestamp();
    return std.fmt.allocPrint(alloc, "zig-cache/test-scene-{d}.recastscene", .{ts});
}

test "scene round-trip: geom+registries+tiles" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_path = try tmpSceneDir(alloc);
    defer alloc.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    // 1) Построить минимальную сцену: geom с 1 volume + 1 offmesh, реестры с
    //    кастомным area-id, навмеш с >=1 тайлом (через sample build или
    //    сконструированный dt.NavMesh с одним addTile).
    //    ... (использовать существующий sample_solo build на тестовой геометрии
    //        test_data, либо собрать единственный тайл вручную) ...

    // 2) saveScene
    // try scene_container.saveScene(io, alloc, dir_path, .{ ... });

    // 3) Проверить структуру: manifest существует, tiles/ непуст.
    var sd = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer sd.close(io);
    const mdata = try sd.readFileAlloc(io, manifest.MANIFEST_NAME, alloc, .unlimited);
    defer alloc.free(mdata);
    try std.testing.expect(mdata.len > 0);

    // 4) loadScene (фаза 1) -> rebuild -> loadTilesInto (фаза 2)
    // 5) Сравнить: число тайлов, число volumes/offmesh, area-id резолвится.
}
```

> Конкретное построение сцены адаптировать к фактическому API `Scene`/`saveScene`. Если поднять полный sample в integration дорого — собрать **один** tile-blob вручную (заголовок `TileCacheLayerHeader` + минимальный payload), записать `tile_store.writeTile`, прочитать `loadTile`, сравнить байты payload. Это покрывает tile_store+manifest независимо от sample-сборки.

- [ ] **Step 2: edge — битый тайл пропускается**

```zig
test "corrupt tile is skipped, rest loads" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir_path = try tmpSceneDir(alloc);
    defer alloc.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().makePath(io, dir_path);
    var sd = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer sd.close(io);
    try sd.makePath(io, "tiles");
    var td = try sd.openDir(io, "tiles", .{});
    defer td.close(io);

    // Записать валидный тайл, затем испортить байт на диске.
    var hdr = std.mem.zeroes(recast.detour_tilecache.TileCacheLayerHeader);
    hdr.magic = recast.detour_tilecache.TILECACHE_MAGIC;
    hdr.version = recast.detour_tilecache.TILECACHE_VERSION;
    hdr.tx = 0; hdr.ty = 0; hdr.tlayer = 0;
    try tile_store.writeTile(io, alloc, td, .tilecache, std.mem.asBytes(&hdr));

    // Перезаписать файл мусором -> loadTile должен вернуть ошибку.
    try td.writeFile(io, .{ .sub_path = "0_0_0.tile", .data = "garbage-not-a-chunk" });
    const res = tile_store.loadTile(io, alloc, td, .{ .tx = 0, .ty = 0, .layer = 0 });
    try std.testing.expectError(error.Truncated, res); // или WrongMagic, в зависимости от длины
}
```

- [ ] **Step 3: edge — отсутствует edits/ (нет .reg)**

Сохранить сцену без реестров (или удалить `edits/` после save), `loadScene` должен вернуть дефолтные реестры без ошибки. Проверить, что `loadScene` не падает и `versions` корректны.

- [ ] **Step 4: запуск**
```powershell
$env:http_proxy=$null; $env:https_proxy=$null
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build test   # integration-шаг (build.zig:125)
```
Сверить имя шага в `build.zig` (строки 98/125 — `unit_tests`/`integration_tests`); подставить фактический step-name.

---

## Task 6: точки интеграции в UI / main.zig (ОПИСАНИЕ, не реализация)

Этот план НЕ правит `main.zig` (риск R5/раздувание + foundation step порядок). Здесь — точные точки, чтобы последующий UI-инкремент знал, что трогать.

- [ ] **Точка 1 — кнопки Save Scene / Load Scene.** В правой Properties-панели или в меню рядом с существующими Save/Load navmesh. `navmesh_io.save/load` сейчас вызывается из контекста сэмпла (`main.zig` использует `navmesh_io` — см. `sample_*.zig`). Добавить две кнопки `dvui.button("Save Scene")` / `"Load Scene"`, которые зовут `scene_container.saveScene`/`loadScene` с `*Scene` активной сцены, `*dt.NavMesh` из сэмпла, `CommonSettings`, активными `AreaRegistry`/`FlagRegistry` (через переходные обёртки, пока step 5 не завершён).

- [ ] **Точка 2 — диалог выбора `.recastscene/`.** Текущий выбор файлов — `io_util.scanDirectory(dir, ext)` (`io_util.zig:64`). Добавить ветку: при выборе сохранения/загрузки сцены сканировать каталоги с суффиксом `.recastscene` (не файлы). Нужен новый хелпер `scanDirectories(alloc, dir, suffix)` рядом с `scanDirectory` ИЛИ фильтр `entry.kind == .directory && endsWith(name, ".recastscene")`. Указать: модальный список как у выбора `.gset`/MSET.

- [ ] **Точка 3 — порядок при Load в UI.** loadScene заполняет geom/registries/settings (фаза 1) → UI должен инициировать **rebuild навмеша** сэмпла (как кнопка Build) → затем `loadTilesInto` (фаза 2). Альтернатива: если сохранённые тайлы самодостаточны (static MSET), грузить тайлы напрямую в новый `dt.NavMesh` без rebuild (как `navmesh_io.load`), а geom/registries — для редактирования. Решение зависит от того, нужен ли rebuild или достаточно загруженных тайлов — **открытый вопрос к владельцу** (см. ниже).

- [ ] **Точка 4 — dirty/meta.** После успешного `saveScene` — `scene.dirty.clear()` (`scene.zig` DirtyBits). После `loadScene` — `scene.meta.setName(<имя контейнера>)`, `scene.dirty.clear()`.

- [ ] **Точка 5 — лог.** Все save/load-операции через `bctx.context().log(.progress, ...)` (как `main.zig:1087`), пропуски битых тайлов — `.warn`.

---

## Self-Review (чек-лист перед сдачей)

- [ ] **Зависимость от модуля 1 явная и не дублирует логику.** tile_store/manifest НЕ реализуют свой checksum/atomic — только зовут `wa.packChunk`/`unpackChunk`/`writeAtomic`/`dirFsync`. Если модуль 1 ещё не готов — Task 1–4 не компилируются (это правильный сигнал порядка).
- [ ] **Commit-порядок соблюдён дословно** (spec §3.b): тайлы (fsync каждого в writeTile) → fsync tiles/ → manifest atomic-rename → fsync корня. Реализован в `manifest.commitWorld`, вызывается из `saveScene` ПОСЛЕДНИМ.
- [ ] **Load-инвариант соблюдён:** manifest → areas/flags → geom/volumes/offmesh → (rebuild caller) → tiles. Реализован в `loadScene` + `loadTilesInto`.
- [ ] **Graceful degradation:** битый тайл/манифест-запись/отсутствующий edits — пропуск+лог, не краш (кроме битого manifest — он фатален, без него версия мира неизвестна). Покрыто тестами Task 5.2/5.3.
- [ ] **Ключ тайла из заголовка blob'а** (не из имени) — `keyFromBlob`; имя файла генерится из ключа. Покрыто тестом Task 1.1.
- [ ] **Владение памятью:** `saveAllTiles`/`parsePayload`/`loadTile` отдают owned, caller освобождает (`free*`-функции). `addTile(free_data=true)` забирает владение data, как `navmesh_io.zig:111`. errdefer на промежуточных alloc.
- [ ] **i32-границы ядра:** `TileCacheLayerHeader.tx/ty/tlayer`, `dt.MeshHeader.x/y/layer`, `mesh.params.max_tiles` остаются i32; касты только на границе с usize (alloc/slice). Соответствует CLAUDE.md.
- [ ] **std.Io 0.16:** `std.Io.Dir.cwd()`, `openDir(io,...)`, `readFileAlloc(io,...)`, `makePath(io,...)`, `deleteTree(io,...)`, `close(io)` — все с `io`-параметром (как `io_util.zig:11,19,75`). `Io.Threaded` для теста (как `io_util.zig:8`).
- [ ] **Сборка чистая:** `zig build demo-test` (unit) + `zig build test` (integration) зелёные, прокси снят.

---

## Caveats / Zig 0.16, что подтверждено / НЕ подтверждено

**Подтверждено (по коду в репо):**
- `std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited)` и `writeFile(io, .{.sub_path,.data})` — рабочие сигнатуры (`io_util.zig:11,19`).
- `std.Io.Dir.openDir(io, path, .{.iterate=true})`, `dir.iterate()`, `it.next(io)`, `dir.close(io)` — рабочие (`io_util.zig:75-81`).
- `Io.Threaded.init(alloc, .{})` + `.io()` — рабочий паттерн (`io_util.zig:8-11`).
- `TileCacheLayerHeader` (поля `magic/version/tx/ty/tlayer`, все i32) — `src/detour_tilecache/builder.zig:18-34`. `TILECACHE_MAGIC`/`TILECACHE_VERSION` там же (`builder.zig:6-7`).
- `CompressedTile.data/header` — `tilecache.zig:36-43`. `dt.NavMesh.tiles[*].{header,data,data_size}` + `getTileRef` — `navmesh_io.zig:31-54`.
- Reader-курсор и put-хелперы — образец `navmesh_io.zig:14-22,59-81` (переиспользован в manifest `PReader`).

**НЕ подтверждено / требует проверки при реализации (помечено в плане):**
- `std.Io.Dir.makePath(io,...)` / `deleteTree(io,...)` — точные имена/сигнатуры в 0.16 (миграция fs→Io, часть API со stub-`@panic`, spec R1). Сверить с `std.Io.Dir`; если `makePath` отсутствует — собрать через `makeDir` рекурсивно.
- Интерфейс **модуля 1** (`writeAtomic`/`ChunkHeader.SIZE`/`packChunk`/`unpackChunk`/`dirFsync`/`checksum`) — предполагается из spec §3.b; финальная сигнатура фиксируется при реализации модуля 1, синхронизировать.
- Имя/поля заголовка static-tile в `recast.detour` (`dt.MeshHeader` с `x/y/layer`) — проверить фактический экспорт; возможно static-tile в этом порте сохраняется только целиком (MSET), тогда per-tile MSET-ветку отложить за флаг (см. открытый вопрос Q-B).
- Тип `CommonSettings` и доступ к `AreaRegistry`/`FlagRegistry` через `Scene` — зависит от состояния foundation step 2/5; на момент плана registries передаются в `SaveInput`/`loadScene` отдельно (переходные обёртки, spec Q2).
- `dirFsync` на POSIX с `EINVAL` (issue #15563/#17950) — закрывается в модуле 1, здесь только вызывается.

---

## Открытые вопросы к владельцу

- **Q-A (rebuild vs direct-load тайлов).** При Load: грузить сохранённые тайлы напрямую в новый `dt.NavMesh` (быстро, как `navmesh_io.load`) ИЛИ всегда делать full rebuild из geom+settings, а тайлы использовать только для TileCache-динамики? От этого зависит UI-точка 3 и нужен ли `loadTilesInto` для static-навмеша вообще. *Допущение в плане:* поддержать оба — static MSET-тайлы грузятся напрямую (`loadTilesInto`), rebuild опционален.
- **Q-B (MSET-tile per-file).** Сейчас static navmesh сохраняется одним MSET-файлом (`navmesh_io.zig`). Дробить его на per-tile файлы `tx_ty_layer.tile` (нужны координаты `x/y/layer` из `dtMeshHeader` — подтвердить, что они там есть и валидны для solo/tile сэмплов) ИЛИ хранить static как единый `tiles/navmesh.mset`, а per-tile — только для TileCache (кластер J)? *Допущение:* per-tile для обоих, ключ из заголовка; если у solo-навмеша координаты тайла нулевые/невалидны — fallback на единый MSET-blob.
- **Q-C (single-file архив).** Решение Q3 владельца требует `packArchive`/`unpackArchive` (директория ⇄ один файл). Этот план оставляет хук (формат самоописывающийся), но реализацию архива относит к `scene_io` (модуль 3) / отдельному инкременту. Подтвердить, что архив НЕ входит в этот модуль 4.
- **Q-D (где живут settings при save).** `CommonSettings` пишется в `scene.gset` строкой `s` (модуль 3, формат RecastDemo) ИЛИ дублируется в наш бинарник? *Допущение:* в `scene.gset` (as-is, совместимость с RecastDemo), модуль 3 владеет.
