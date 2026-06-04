# План: Persist Модуль 1 — Durable primitives (write_atomic + checksum)

> Статус: implementation-план (код НЕ написан). База всего Persist-слоя.
> Целевые файлы:
> - `demo/src/persist/write_atomic.zig`
> - `demo/src/persist/checksum.zig`
> Ветка: `feat/debug-platform`. Zig 0.16.0 (`C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe`).

---

## Goal

Реализовать два «кирпича», на которых стоит весь Persist (`scene.gset`, `edits/*`, `tiles/*.tile`, `manifest`):

1. **`write_atomic.zig`** — durable atomic запись файла: temp → write → flush → **явный `File.sync`** (с трактовкой EIO как фатальной) → atomic replace → **directory-fsync** (POSIX; Windows no-op). Закрывает три пробела Zig stdlib: `File.Atomic.replace` не делает fsync ни файла, ни каталога; нет кросс-платформенной обёртки directory-fsync; политику «EIO → недоверенное состояние» реализуем сами.
2. **`checksum.zig`** — контрольная сумма (`std.hash.XxHash3`, подтверждён в 0.16) + самоописывающийся chunk-header (magic/version/type_flags/payload_len/checksum) с pack/unpack/verify. Это формат заголовка из общего интерфейса, который переиспользуют модули edits/tiles/manifest.

**Не входит** в этот модуль: сам формат `.gset`, реестры, тайлы, manifest — они зависят от этого модуля и планируются отдельно.

## Architecture

```
demo/src/persist/
  checksum.zig      <- чистая логика (хеш + chunk pack/unpack/verify). Тест: zig test (in-source).
  write_atomic.zig  <- IO + платформенный код (dir-fsync). Тест: через временную директорию.
  persist_test.zig  <- агрегатор тестов модуля (root для нового build-step `persist-test`).
```

Зависимости направлены так: `write_atomic.zig` НЕ зависит от `checksum.zig` (это ортогональные примитивы — atomic-запись принимает уже готовые `bytes`). `checksum.zig` НЕ зависит от IO. Оба переиспользуют коды ошибок из `navmesh_io.zig` идейно (`Truncated`/`WrongMagic`/`WrongVersion`) и добавляют `ChecksumMismatch`.

Порядок реализации: **сначала `checksum.zig`** (чисто-логический, TDD через `zig test`), **потом `write_atomic.zig`** (IO, integration-тест через temp-dir). Это позволяет модулям-потребителям начать кодиться против `checksum` API раньше, чем будет готов durable-слой.

## Tech Stack — подтверждено по исходникам Zig 0.16.0 (НЕ ре-ресёрчить)

Проверено чтением `C:\Program Files\zig\zig-x86_64-windows-0.16.0\lib\std\...`:

| Что | Статус | Источник (файл:строка) |
|---|---|---|
| `std.hash.XxHash3` | **ПОДТВЕРЖДЁН** | `std/hash.zig:35`; `XxHash3.hash(seed: u64, input) u64` — `std/hash/xxhash.zig:581` |
| `std.hash.XxHash64` (fallback/стрим) | **ПОДТВЕРЖДЁН** | `std/hash.zig:36`; `init/update/final` — `xxhash.zig:177/187/217`, one-shot `hash` — `:232` |
| `std.hash.Crc32` (запасной fallback) | ПОДТВЕРЖДЁН | `std/hash.zig:10` |
| `Dir.createFileAtomic(io, sub_path, options) -> File.Atomic` | **ПОДТВЕРЖДЁН** | `std/Io/Dir.zig:1924`; options `{permissions, make_path, replace}` — `:1870` |
| `File.Atomic.replace(io)` / `.deinit(io)` / `.file` | **ПОДТВЕРЖДЁН** | `std/Io/File/Atomic.zig:77/23/9`. ВАЖНО: `replace` **закрывает** `af.file` ПЕРЕД rename — значит `File.sync` надо звать ДО `replace`, пока файл открыт. |
| `File.sync(io) SyncError!void` | **ПОДТВЕРЖДЁН** | `std/Io/File.zig:241`; `SyncError = {InputOutput, NoSpaceLeft, DiskQuota, AccessDenied} ...` — `:229`. EIO уже выделен как `error.InputOutput`. |
| `File.writer(io, buffer) -> Writer` | **ПОДТВЕРЖДЁН** | `std/Io/File.zig:600` |
| `Dir.handle: std.posix.fd_t` | **ПОДТВЕРЖДЁН** | `std/Io/Dir.zig:13,15` |
| `std.posix.fsync(fd)` обёртка | **ОТСУТСТВУЕТ в 0.16** | в `std/posix.zig` есть только `fdatasync`/`syncfs` (`:1263/1250`). fsync дескриптора каталога делаем через **raw** `std.posix.system.fsync(fd)` + ручная обработка errno. На Linux raw обёртка `std.os.linux.fsync` — `std/os/linux.zig:2791`. |

**Вывод по checksum:** ре-порт xxHash НЕ нужен — `XxHash3` в stdlib. CRC32 как fallback оговорён ниже (опция компиляции), но по умолчанию `XxHash3`.

**Вывод по write_atomic:** AtomicFile (`createFileAtomic`) даёт нам temp→replace, но НЕ синкает. Durability добавляем вручную: `File.sync` до `replace`, directory-fsync после. directory-fsync на POSIX — единственный платформенный код (raw syscall + EINVAL no-op), на Windows — no-op (NTFS журналирует метаданные rename).

## File Structure (новые/изменённые)

```
demo/src/persist/checksum.zig       NEW
demo/src/persist/write_atomic.zig   NEW
demo/src/persist/persist_test.zig   NEW (root тестового модуля)
build.zig                           EDIT (+ step `persist-test`)
```

---

## Задача 1 — `checksum.zig`: хеш + chunk-header (TDD, чистая логика)

Тестируется `zig test demo/src/persist/checksum.zig` напрямую (нет IO, нет recast-nav). Идём TDD: сначала тест, потом реализация.

### Шаг 1.1 — Каркас файла, выбор хеша, коды ошибок

Создать `demo/src/persist/checksum.zig`:

```zig
//! Persist Модуль 1 — checksum + самоописывающийся chunk-header.
//! Хеш: std.hash.XxHash3 (подтверждён в Zig 0.16). Не криптостойкий — только
//! детект bitrot / оборванной записи (см. docs/research/persistence-durability-research.md).
//! Заголовок чанка: magic|version|type_flags|payload_len|checksum (модель PNG/glTF).

const std = @import("std");

/// Сид хеша фиксирован для детерминизма между запусками/машинами.
pub const HASH_SEED: u64 = 0;

/// Алгоритм хеша. По умолчанию XXH3. CRC32 — допустимый fallback (совместимость
/// инструментов / параллельное вычисление по блокам); переключается здесь.
pub const Algo = enum { xxh3, crc32 };
pub const ALGO: Algo = .xxh3;

/// Контрольная сумма payload (u64; для crc32 верхние 32 бита нулевые).
pub fn checksum(bytes: []const u8) u64 {
    return switch (ALGO) {
        .xxh3 => std.hash.XxHash3.hash(HASH_SEED, bytes),
        .crc32 => std.hash.Crc32.hash(bytes),
    };
}

/// Ошибки разбора чанка. Truncated/WrongMagic/WrongVersion — те же имена, что
/// в navmesh_io.zig (единый словарь ошибок Persist). ChecksumMismatch — новый.
pub const ChunkError = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
};
```

Проверка компиляции:
```
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" test demo/src/persist/checksum.zig
```
(Снять прокси перед любым zig-вызовом: `Remove-Item Env:\http_proxy,Env:\https_proxy -ErrorAction SilentlyContinue`.)

### Шаг 1.2 — Тест детерминизма checksum (RED)

Дописать в `checksum.zig`:

```zig
test "checksum детерминизм и чувствительность к байту" {
    const a = "recast-persist-chunk";
    try std.testing.expectEqual(checksum(a), checksum(a)); // детерминизм
    // изменение одного байта меняет хеш
    var b = a.*;
    b[0] ^= 0x01;
    try std.testing.expect(checksum(a) != checksum(&b));
    // пустой вход не паникует
    _ = checksum("");
}
```

Запустить — должен пройти сразу (функция уже есть); если упадёт — чинить `checksum`.

### Шаг 1.3 — Структура `ChunkHeader` + pack (RED→GREEN)

Заголовок строго фиксированного размера, little-endian, поля по убыванию выравнивания, без паддинга в сериализации (пишем поле-в-поле, не `toBytes(struct)` — чтобы не зависеть от layout). checksum покрывает `type_flags || header_без_csum || payload` (как в общем интерфейсе владельца).

```zig
/// Размер сериализованного заголовка в байтах: 4+4+2+8+8 = 26.
pub const HEADER_SIZE: usize = 4 + 4 + 2 + 8 + 8;

pub const ChunkHeader = struct {
    magic: u32,
    version: u32,
    type_flags: u16,
    payload_len: u64,
    checksum: u64,

    /// Вычислить checksum по правилу: XXH3(type_flags(LE) || header_prefix || payload),
    /// где header_prefix = magic|version|type_flags|payload_len (всё, КРОМЕ самого checksum).
    /// type_flags входит дважды намеренно — повторяем дословную формулу общего интерфейса
    /// (type_flags || header_без_csum || payload), это безвредно и фиксирует контракт.
    pub fn computeChecksum(magic: u32, version: u32, type_flags: u16, payload: []const u8) u64 {
        var h = std.hash.XxHash3.init(HASH_SEED);
        var tf: [2]u8 = undefined;
        std.mem.writeInt(u16, &tf, type_flags, .little);
        h.update(&tf); // ведущий type_flags
        var pre: [4 + 4 + 2 + 8]u8 = undefined;
        std.mem.writeInt(u32, pre[0..4], magic, .little);
        std.mem.writeInt(u32, pre[4..8], version, .little);
        std.mem.writeInt(u16, pre[8..10], type_flags, .little);
        std.mem.writeInt(u64, pre[10..18], payload.len, .little);
        h.update(&pre);
        h.update(payload);
        return h.final();
    }

    /// Сформировать заголовок для payload (checksum считается здесь).
    pub fn init(magic: u32, version: u32, type_flags: u16, payload: []const u8) ChunkHeader {
        return .{
            .magic = magic,
            .version = version,
            .type_flags = type_flags,
            .payload_len = payload.len,
            .checksum = computeChecksum(magic, version, type_flags, payload),
        };
    }

    /// Сериализовать заголовок в 26 байт (LE, поле-в-поле).
    pub fn pack(self: ChunkHeader) [HEADER_SIZE]u8 {
        var out: [HEADER_SIZE]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], self.magic, .little);
        std.mem.writeInt(u32, out[4..8], self.version, .little);
        std.mem.writeInt(u16, out[8..10], self.type_flags, .little);
        std.mem.writeInt(u64, out[10..18], self.payload_len, .little);
        std.mem.writeInt(u64, out[18..26], self.checksum, .little);
        return out;
    }
};
```

> Замечание по XxHash3 streaming: `init`/`update`/`final` подтверждены для `XxHash64`; для `XxHash3` в `xxhash.zig` есть `hash` (one-shot). Если у `XxHash3` в этой версии нет публичного `init/update/final` — заменить `computeChecksum` на one-shot: собрать `tf || pre || payload` в локальный буфер и вызвать `std.hash.XxHash3.hash(HASH_SEED, buf)`. **Шаг проверки:** перед написанием `computeChecksum` грепнуть `grep -n "pub fn init\|pub fn update\|pub fn final" lib/std/hash/xxhash.zig` в секции `XxHash3` (строки ~423+). Если нет — использовать one-shot вариант ниже:

```zig
// Альтернатива computeChecksum через one-shot (если у XxHash3 нет update/final):
pub fn computeChecksumOneShot(
    alloc: std.mem.Allocator,
    magic: u32, version: u32, type_flags: u16, payload: []const u8,
) !u64 {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, type_flags, .little);
    try buf.appendSlice(&tmp);
    var pre: [18]u8 = undefined;
    std.mem.writeInt(u32, pre[0..4], magic, .little);
    std.mem.writeInt(u32, pre[4..8], version, .little);
    std.mem.writeInt(u16, pre[8..10], type_flags, .little);
    std.mem.writeInt(u64, pre[10..18], payload.len, .little);
    try buf.appendSlice(&pre);
    try buf.appendSlice(payload);
    return std.hash.XxHash3.hash(HASH_SEED, buf.items);
}
```

> Решение: предпочесть streaming-вариант (без аллокатора). Если API не совпал — переключиться на one-shot. **Открытый пункт для исполнителя**, не для владельца.

### Шаг 1.4 — unpack + verify

```zig
/// Разобрать заголовок из ведущих HEADER_SIZE байт. Проверяет magic/version и,
/// если payload доступен в buf после заголовка, проверяет checksum.
/// expect_magic/expect_version — ожидаемые значения вызывающего домена.
pub fn unpackHeader(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
) ChunkError!ChunkHeader {
    if (buf.len < HEADER_SIZE) return error.Truncated;
    const hdr = ChunkHeader{
        .magic = std.mem.readInt(u32, buf[0..4], .little),
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .type_flags = std.mem.readInt(u16, buf[8..10], .little),
        .payload_len = std.mem.readInt(u64, buf[10..18], .little),
        .checksum = std.mem.readInt(u64, buf[18..26], .little),
    };
    if (hdr.magic != expect_magic) return error.WrongMagic;
    if (hdr.version != expect_version) return error.WrongVersion;
    return hdr;
}

/// Полный разбор чанка [header|payload]: вернуть срез payload, проверив длину и checksum.
/// Срез указывает внутрь buf (no-copy). Graceful degradation: вызывающий ловит ошибку
/// и пропускает битый чанк, продолжая грузить остальные.
pub fn parseChunk(
    buf: []const u8,
    expect_magic: u32,
    expect_version: u32,
) ChunkError![]const u8 {
    const hdr = try unpackHeader(buf, expect_magic, expect_version);
    const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
    if (buf.len < HEADER_SIZE + plen) return error.Truncated;
    const payload = buf[HEADER_SIZE .. HEADER_SIZE + plen];
    const want = ChunkHeader.computeChecksum(hdr.magic, hdr.version, hdr.type_flags, payload);
    if (want != hdr.checksum) return error.ChecksumMismatch;
    return payload;
}

/// Сериализовать целый чанк [header|payload] в выделенный буфер (owned).
pub fn buildChunk(
    alloc: std.mem.Allocator,
    magic: u32, version: u32, type_flags: u16, payload: []const u8,
) ![]u8 {
    const hdr = ChunkHeader.init(magic, version, type_flags, payload);
    const out = try alloc.alloc(u8, HEADER_SIZE + payload.len);
    @memcpy(out[0..HEADER_SIZE], &hdr.pack());
    @memcpy(out[HEADER_SIZE..], payload);
    return out;
}
```

### Шаг 1.5 — Тесты chunk round-trip + corruption (RED→GREEN)

```zig
test "chunk pack/unpack round-trip" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541; // 'AREA' пример домена
    const VERSION: u32 = 1;
    const payload = "hello durable world";
    const chunk = try buildChunk(a, MAGIC, VERSION, 0x00, payload);
    defer a.free(chunk);

    const got = try parseChunk(chunk, MAGIC, VERSION);
    try std.testing.expectEqualSlices(u8, payload, got);

    // неверный magic/version
    try std.testing.expectError(error.WrongMagic, parseChunk(chunk, 0xDEADBEEF, VERSION));
    try std.testing.expectError(error.WrongVersion, parseChunk(chunk, MAGIC, 2));
}

test "chunk corruption detect -> ChecksumMismatch" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const chunk = try buildChunk(a, MAGIC, 1, 0x00, "payload-bytes-xyz");
    defer a.free(chunk);
    // портим один байт payload
    chunk[HEADER_SIZE + 3] ^= 0x40;
    try std.testing.expectError(error.ChecksumMismatch, parseChunk(chunk, MAGIC, 1));
}

test "truncated header и truncated payload" {
    const a = std.testing.allocator;
    const MAGIC: u32 = 0x41524541;
    const chunk = try buildChunk(a, MAGIC, 1, 0x00, "0123456789");
    defer a.free(chunk);
    try std.testing.expectError(error.Truncated, parseChunk(chunk[0 .. HEADER_SIZE - 1], MAGIC, 1));
    try std.testing.expectError(error.Truncated, parseChunk(chunk[0 .. HEADER_SIZE + 2], MAGIC, 1));
}
```

Запуск: `zig test demo/src/persist/checksum.zig` — все 5 тестов зелёные.

**Self-review Задачи 1:** (1) формула checksum дословно повторяет контракт владельца (`type_flags || header_без_csum || payload`); (2) LE-сериализация поле-в-поле — не зависит от struct layout/ABI; (3) `payload_len: u64` → `usize` через `std.math.cast` (на 32-бит платформе огромная длина даст `Truncated`, не паника); (4) `parseChunk` no-copy — срез внутрь входного буфера; (5) имена ошибок совпадают с `navmesh_io.zig`.

---

## Задача 2 — `write_atomic.zig`: durable запись + dirFsync (integration через temp-dir)

Зависит от Задачи 1 НЕ по коду (ортогонально), но реализуется второй. IO-тесты — через временную директорию `std.testing.tmpDir`. Сборка/тест через build-step `persist-test` (Задача 3), либо прямой `zig test`.

### Шаг 2.1 — Каркас, импорт, типы ошибок

`demo/src/persist/write_atomic.zig`:

```zig
//! Persist Модуль 1 — durable atomic запись.
//! Рецепт (POSIX): createFileAtomic(temp) -> write -> flush -> File.sync[EIO фатально]
//!   -> replace(atomic rename) -> dirFsync(каталог).
//! Windows: File.sync = FlushFileBuffers; replace -> NtSetInformationFile rename;
//!   dirFsync = no-op (NTFS журналирует метаданные rename).
//! Закрывает пробелы stdlib: File.Atomic.replace НЕ синкает ни файл, ни каталог;
//! нет кросс-платформенной dir-fsync обёртки; политику "EIO -> недоверенно" реализуем сами.
//! См. docs/research/persistence-durability-research.md (НАПРАВЛЕНИЕ 1).

const std = @import("std");
const builtin = @import("builtin");

/// Ошибки durable-записи. DurabilityFailed — фатальный EIO из fsync (урок fsyncgate:
/// повторный fsync небезопасен; состояние считаем недоверенным).
pub const WriteAtomicError = error{
    DurabilityFailed,
} || std.Io.Dir.CreateFileAtomicError
  || std.Io.File.WriteError
  || std.Io.File.Atomic.ReplaceError;
```

> Точные имена error-set'ов проверить при компиляции (`std.Io.File.WriteError` может называться `Writer.Error`; см. шаг 2.3). Если набор не собирается — заменить на `anyerror`-свободный union по факту вызовов. Это локальный compile-time вопрос, не архитектурный.

### Шаг 2.2 — `dirFsync`: directory-fsync (POSIX raw + Windows no-op)

В 0.16 нет `std.posix.fsync(fd)`. На POSIX зовём raw `std.posix.system.fsync(fd)` и сами разбираем errno: `EINVAL` трактуем как **успех** (некоторые ФС/каталоги не поддерживают fsync на dir-fd — issue #15563/#17950, это НЕ ошибка durability), `EIO` → фатально.

```zig
/// fsync дескриптора каталога. POSIX: raw fsync(fd) с EINVAL=no-op, EIO=фатально.
/// Windows: no-op (нет directory-fsync; NTFS-журнал метаданных закрывает дыру для rename).
pub fn dirFsync(dir: std.Io.Dir) WriteAtomicError!void {
    if (builtin.os.tag == .windows) return; // no-op
    const fd = dir.handle; // std.posix.fd_t (см. Dir.zig:13)
    while (true) {
        const rc = std.posix.system.fsync(fd);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue, // прерван сигналом — повторить
            .INVAL, .BADF, .ROFS => return, // dir-fd не поддерживает fsync -> считаем no-op
            .IO => return error.DurabilityFailed, // EIO -> недоверенное состояние, фатально
            else => return error.DurabilityFailed,
        }
    }
}
```

> Сверить во время реализации: тип возврата `std.posix.system.fsync` (на Linux это `usize` из syscall, см. `os/linux.zig:2791`; на других — libc `c_int`). `std.posix.errno(rc)` принимает оба. Если `system.fsync` отсутствует для целевого ОС — fallback на `std.os.linux.fsync` под `comptime` ветку по `builtin.os.tag`. На Windows ветка недостижима (ранний return).

### Шаг 2.3 — `writeAtomic`: основной рецепт

КЛЮЧЕВОЙ инвариант (из чтения `File/Atomic.zig:77`): `replace()` **закрывает** `af.file` перед rename. Значит `File.sync` обязан быть ДО `replace`, пока файл открыт. После `replace` файл закрыт — синкать поздно.

```zig
/// Durable atomic запись `bytes` в `dir/name`. По возврату данные на диске
/// (с точностью до гарантий железа). Перезапись существующего файла безопасна.
pub fn writeAtomic(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) WriteAtomicError!void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true });
    errdefer af.deinit(io); // удалит temp при ошибке до replace

    // 1) запись через буферизованный writer + ОБЯЗАТЕЛЬНЫЙ flush.
    var wbuf: [4096]u8 = undefined;
    var w = af.file.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush(); // иначе данные осядут в user-space буфере

    // 2) ЯВНЫЙ fsync файла ДО replace (replace закрывает файл). EIO -> фатально.
    af.file.sync(io) catch |e| switch (e) {
        error.InputOutput => return error.DurabilityFailed, // fsyncgate: не ретраить
        else => return e,
    };

    // 3) atomic rename temp -> name.
    try af.replace(io);
    af.deinit(io); // освобождает ресурсы; файл уже materialized (replace сбросил флаги)

    // 4) directory-fsync, чтобы directory-entry о rename попала на диск (POSIX).
    try dirFsync(dir);
}
```

> Проверить при компиляции имена методов writer'а: в 0.16 `file.writer(io, buf)` возвращает `File.Writer` с полем-интерфейсом `.interface` (`std.Io.Writer`) и методами `writeAll`/`flush`. Если флешится иначе (`w.flush()` напрямую) — поправить по сигнатуре из `std/Io/File.zig:600` и `std/Io/Writer.zig`. Сам поток рецепта (write→flush→sync→replace→dirFsync) не меняется.
>
> `af.deinit(io)` после успешного `replace`: по `Atomic.zig:23` deinit идемпотентен — `file_open=false` и `file_exists=false` после replace, deinit только закроет `close_dir_on_deinit` если был. Двойной путь (errdefer + явный deinit) безопасен, т.к. после успешного `replace` errdefer не сработает.

### Шаг 2.4 — Хелпер открытия каталога сцены (удобство потребителей)

Тонкая обёртка: гарантировать существование каталога-контейнера и вернуть `Dir` для серии `writeAtomic`. Нужна модулям edits/tiles (они пишут много файлов в один каталог и должны звать `dirFsync` после батча).

```zig
/// Открыть (создав при необходимости) каталог-контейнер. Вызывающий закрывает Dir.
pub fn openContainerDir(io: std.Io, parent: std.Io.Dir, sub_path: []const u8) !std.Io.Dir {
    parent.makePath(io, sub_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return parent.openDir(io, sub_path, .{ .iterate = true });
}
```

> Проверить имя `makePath`/`makeDir` в `Dir.zig` (в io_util.zig используется `openDir(io, path, .{...})` — подтверждает сигнатуру с `io`). Если `makePath` отсутствует — использовать `makeDir` + игнор `PathAlreadyExists`.

### Шаг 2.5 — Integration-тесты (temp-dir round-trip + overwrite + dirFsync)

```zig
const testing = std.testing;

fn tmpIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{});
}

test "writeAtomic round-trip: записать и прочитать" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{}); // std.fs.Dir-обёртка? см. примечание ниже
    defer tmp.cleanup();
    const dir: std.Io.Dir = .{ .handle = tmp.dir.fd };

    const payload = "durable round-trip payload";
    try writeAtomic(io, dir, "a.bin", payload);

    const got = try dir.readFileAlloc(io, "a.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, payload, got);
}

test "writeAtomic перезапись существующего" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: std.Io.Dir = .{ .handle = tmp.dir.fd };

    try writeAtomic(io, dir, "b.bin", "first-version-data");
    try writeAtomic(io, dir, "b.bin", "second"); // короче -> размер должен обновиться

    const got = try dir.readFileAlloc(io, "b.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, "second", got);
}

test "dirFsync не падает на временном каталоге" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = io;
    const dir: std.Io.Dir = .{ .handle = tmp.dir.fd };
    try dirFsync(dir); // POSIX: успех или EINVAL=no-op; Windows: no-op
}
```

> **Примечание по `testing.tmpDir`:** в 0.16 `std.testing.tmpDir(.{})` возвращает структуру с полем `.dir` (тип `std.Io.Dir` ИЛИ legacy `std.fs.Dir`). Проверить при реализации: `grep -n "pub fn tmpDir\|pub const TmpDir" lib/std/testing.zig`. Если `.dir` уже `std.Io.Dir` — использовать напрямую (`const dir = tmp.dir;`), убрать ручную обёртку `.{ .handle = ... }`. Если возвращает legacy `std.fs.Dir` с полем `.fd` — обернуть как показано. Это единственное место теста, чувствительное к статусу миграции testing → Io. Round-trip-чтение `readFileAlloc(io, ...)` уже подтверждено рабочим в `io_util.zig:11`.

**Self-review Задачи 2:** (1) `File.sync` строго ДО `replace` — иначе синк после close (баг durability); (2) EIO → `DurabilityFailed`, без ретрая (fsyncgate); (3) `dirFsync` EINVAL = no-op (иначе ложный fail на ФС без dir-fsync); Windows = ранний return; (4) `flush()` обязателен после буферизованного writer; (5) `errdefer af.deinit` чистит temp при любой ошибке до replace; (6) перезапись короче — `createFileAtomic` пишет в новый temp, replace заменяет целиком (старый размер не «протекает»).

---

## Задача 3 — Сборка тестов: build-step `persist-test`

Persist-тесты не требуют dvui/glfw, но `write_atomic` требует IO (`std.Io.Threaded`) — это есть в stdlib, доп. зависимостей нет. `checksum` не требует ничего. Делаем отдельный шаг по образцу `demo-test` (`build.zig:68-78`).

### Шаг 3.1 — Агрегатор `persist_test.zig`

`demo/src/persist/persist_test.zig`:

```zig
//! Агрегатор тестов Persist Модуля 1. Root для build-step `persist-test`.
comptime {
    _ = @import("checksum.zig");
    _ = @import("write_atomic.zig");
}
```

### Шаг 3.2 — Регистрация шага в `build.zig`

После блока `demo-test` (после строки 78) добавить:

```zig
    // Тесты Persist (Модуль 1: write_atomic + checksum). Не требуют dvui/glfw.
    {
        const persist_mod = b.createModule(.{
            .root_source_file = b.path("demo/src/persist/persist_test.zig"),
            .target = target,
            .optimize = .Debug,
        });
        const persist_test = b.addTest(.{ .root_module = persist_mod });
        const persist_test_step = b.step("persist-test", "Тесты Persist (write_atomic + checksum)");
        persist_test_step.dependOn(&b.addRunArtifact(persist_test).step);
    }
```

### Шаг 3.3 — Запуск

```powershell
Remove-Item Env:\http_proxy, Env:\https_proxy -ErrorAction SilentlyContinue
& "C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe" build persist-test
```
Все тесты обеих Задач зелёные. (Альтернатива для checksum в отрыве: `zig test demo/src/persist/checksum.zig`.)

**Self-review Задачи 3:** (1) отдельный root-модуль обходит lazy-compilation Zig (паттерн из CLAUDE.md / build.zig); (2) `.Debug` — максимум safety-проверок для IO-кода; (3) шаг не тянет recast-nav — изоляция от тяжёлых зависимостей.

---

## Порядок реализации (резюме зависимостей)

1. **Задача 1** (`checksum.zig`) — первой: чистая логика, разблокирует потребителей формата заголовка.
2. **Задача 3 частично** (`persist_test.zig` + build-step) — чтобы был запуск.
3. **Задача 2** (`write_atomic.zig`) — durable IO поверх подтверждённого AtomicFile API.

Модули 2+ (edits/tiles/manifest) импортируют из этого модуля:
- `checksum.buildChunk` / `checksum.parseChunk` / `checksum.ChunkHeader` / `checksum.ChunkError`;
- `write_atomic.writeAtomic` / `write_atomic.dirFsync` / `write_atomic.openContainerDir`.
Порядок коммита тайлов (новые тайлы → fsync каждого → `dirFsync(tiles/)` → atomic-rename manifest → `dirFsync(root)`) реализуется В НИХ через эти примитивы — здесь только кирпичи.

---

## Общий Self-Review плана

- **Подтверждено по исходникам 0.16:** `std.hash.XxHash3`/`XxHash64`/`Crc32`; `Dir.createFileAtomic`→`File.Atomic`; `File.Atomic.replace` закрывает файл (→ sync до replace); `File.sync` с выделенным `error.InputOutput` (EIO); `Dir.handle: posix.fd_t`; отсутствие `std.posix.fsync` (только `fdatasync`/`syncfs`) → raw `system.fsync` для dir-fsync.
- **НЕ подтверждено дословно (помечено в шагах как «проверить при компиляции»):** наличие у `XxHash3` streaming `init/update/final` (есть one-shot `hash` — fallback готов); точные имена error-set `File.WriteError`/`Writer.Error`; `File.Writer.interface.flush`/`writeAll` против `w.flush`; тип возврата `std.posix.system.fsync` по ОС; форма `std.testing.tmpDir` (`.dir` как `Io.Dir` vs legacy `fs.Dir`); имя `Dir.makePath`. Все пять — локальные compile-time правки, архитектуру не меняют; для каждого в плане дан конкретный grep и fallback.
- **Durability-инварианты соблюдены:** flush→sync(EIO фатально)→replace→dirFsync; temp в том же каталоге (createFileAtomic гарантирует); EINVAL dir-fsync = no-op; Windows dir-fsync = no-op.
- **Тестируемость:** checksum — `zig test` (детерминизм, round-trip, corruption→ChecksumMismatch, truncation); write_atomic — temp-dir round-trip + overwrite + dirFsync; оба через `zig build persist-test`.

## Открытые вопросы к владельцу

1. **Endianness формата.** План фиксирует **little-endian** для chunk-header (целевые платформы — x86_64/aarch64 LE; совпадает с `navmesh_io.zig`, который пишет `std.mem.toBytes` нативно). Подтверждаешь LE как формат-на-диске (а не «нативный»)? Это влияет на переносимость файлов между машинами.
2. **HASH_SEED = 0.** Фиксированный сид для детерминизма. Оставляем 0 или хочешь доменный сид (напр. из magic) для разнесения коллизий между типами чанков? (Рекомендация: 0 — проще, checksum и так per-domain через magic в формуле.)
3. **CRC32 fallback — оставлять ли как compile-time опцию `ALGO`?** Сейчас в плане она есть (на случай совместимости инструментов). Если CRC32-путь не нужен — упростить до жёсткого XXH3 (убрать `enum Algo`). Решение твоё.
4. **macOS `F_FULLFSYNC`** в плане НЕ реализован (целевые ОС — Windows/Linux). Если macOS в области поддержки — добавить ветку `fcntl(F_FULLFSYNC)` в `File.sync`-обёртку отдельной задачей. Подтверди, что macOS вне scope Модуля 1.

## Что из Zig 0.16 stdlib подтвердил / не подтвердил

**Подтвердил (чтением lib/std):** `std.hash.XxHash3.hash`, `XxHash64.{init,update,final,hash}`, `Crc32.hash`; `std.Io.Dir.createFileAtomic` + `CreateFileAtomicOptions{permissions,make_path,replace}` + возврат `File.Atomic`; `File.Atomic.{replace,deinit,link,file}` и факт закрытия файла внутри `replace`; `File.sync` + `SyncError` с `InputOutput`; `File.writer`; `Dir.handle: std.posix.fd_t`; **отсутствие** `std.posix.fsync` (есть только `fdatasync`/`syncfs`/`sync`); raw `std.os.linux.fsync`.

**Не подтвердил дословно (нужна проверка при кодинге, fallback в плане есть):** streaming-API у `XxHash3`; точные error-set'ы writer'а и имя `.interface.flush`; сигнатура/возврат `std.posix.system.fsync` per-OS; форма `std.testing.tmpDir` относительно миграции в `std.Io.Dir`; наличие `Dir.makePath`.
