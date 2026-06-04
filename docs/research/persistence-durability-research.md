# Durable-персистентность редактируемого navmesh для порта Recast & Detour на Zig 0.16

## TL;DR
- **Архитектура: гибрид «директория-контейнер».** Геометрию (`.gset` — без изменений, текст, читается RecastDemo + `.obj`) храните как есть; редактируемое состояние (реестры area-types/poly-flags, convex volumes, off-mesh connections в нашем бинарном виде) и тайлы TileCache — в директории сцены: один файл на тайл `tx_ty_layer.tile` + один `manifest`/`index` + append-only `journal`. Каждая запись — атомарная (temp → fsync → atomic rename → fsync каталога). Это даёт малый blast-radius, отсутствие переписывания всего мира на каждое мелкое изменение и частичное восстановление.
- **Durable-запись: write-temp → fsync(file) → atomic rename → fsync(dir).** В Zig 0.16 есть `std.Io.Dir.createFileAtomic` (старый `Dir.atomicFile`), но он **сам по себе не гарантирует fsync ни файла, ни каталога** — это надо делать вручную через `File.sync` (= fsync/FlushFileBuffers) и отдельный fsync дескриптора каталога. На Windows fsync каталога не существует как операции — это первый и главный пробел стандартной библиотеки, который надо закрывать платформенным кодом.
- **Целостность: per-tile/per-record заголовок magic+version+length+checksum (xxHash64/XXH3).** Битый тайл/запись детектируется и пропускается, остальной мир грузится (graceful degradation). Версионирование: добавить версию в наши бинарные форматы (она уже есть в `navmesh_io.zig`), а `.gset` оставить без версии (формат RecastDemo версии не имеет) — совместимость не ломается.

## Key Findings

### Что реально даёт Zig 0.16 stdlib (проверено)
- `std.fs`/`std.fs.File`/`std.fs.Dir` в 0.16 мигрируют в `std.Io` (PR #30232 «std: migrate all `fs` APIs to `Io`»); большинство операций теперь принимают параметр `io` и живут в `std.Io.Dir`. Это последствие переработки Reader/Writer («writergate») и введения `std.Io` backend (`Io.Threaded`, `Io.Evented`, `Io.Uring`). Часть API в `Io.Threaded` ещё имеет stub-ы `@panic` (issue #25738).
- Атомарная запись: `std.Io.Dir.createFileAtomic(io, path, .{ .replace = true })` возвращает `AtomicFile`; пишем через `af.file.writer(io, buf)`, затем `writer.interface.flush()` и `af.replace(io)`. Есть и стратегия «link» (когда целевого файла не должно существовать). Это прямая замена удалённого `Dir.atomicFile` (подтверждено на форуме Ziggit, февраль 2026).
- Rename: Zig реализует rename через `posix.renameat`; на Windows это идёт не через `MoveFileEx`/`ReplaceFile`, а через NT-API `NtSetInformationFile` с `FILE_RENAME_INFORMATION` (политика Zig — «Prefer the Native API over Win32»; в 0.16 почти вся stdlib переведена на низкоуровневые ntdll-вызовы, из kernel32 в I/O-пути остался практически только `CreateProcessW`).
- `File.sync` существует и означает именно fsync: «Blocks until all pending file contents and metadata modifications for the file have been synchronized… Note that this does not ensure that metadata for the directory containing the file has also reached disk». То есть **fsync каталога stdlib за нас не делает**.

### Точная схема надёжной записи (из первоисточников)
- «Files are hard» (Dan Luu) и доклад «Files are fraught with peril»: POSIX-rename атомарен **только при нормальной работе, не при краше**; на mainstream-ФС есть режимы, где rename не атомарен на краше (исключение — btrfs, и то только при замене существующего файла, плюс известны баги атомарности rename, найденные в Mohan et al., OSDI'18). Поэтому одного rename недостаточно — нужен порядок `creat;write;fsync(file);fsync(dir);rename;fsync(dir)`.
- Необходим fsync **и файла, и родительского каталога**: иначе после rename и краша запись о файле может не попасть на диск (подтверждено в обсуждениях POSIX и в write-file-atomic#64).
- «fsyncgate» — Jonathan Corbet, «PostgreSQL's fsync() surprise», LWN.net, апрель 2018 (https://lwn.net/Articles/752063/); проблему сообщил Craig Ringer на pgsql-hackers в конце марта 2018. На Linux < 4.13 ошибка отложенной записи могла теряться, а повторный `fsync()` мог ложно вернуть успех, очистив флаг ошибки страницы (AS_EIO) → тихая потеря данных. Цитата из исходного треда (Craig Ringer): «Pg should PANIC on fsync() EIO return. Retrying fsync() is not OK at least on Linux… The retry succeeded, because the prior fsync() cleared the AS_EIO bad page flag.» Исправление error-handling fsync в Linux пришло в ядре 4.13 (работа Jeff Layton, errseq_t). PostgreSQL стал делать PANIC на сбое fsync, начиная с коммита (Nov 2018, авторы Thomas Munro, Andres Freund, Robert Haas, Craig Ringer); бэкпортировано в PostgreSQL 11, 10, 9.6, 9.5 и 9.4 (источник: PostgreSQL wiki «Fsync Errors»). Практический смысл для нас: **проверять ошибку каждого fsync и не считать повторный fsync безопасным** — при `EIO` считать состояние недоверенным. Глубокий разбор: Anthony Rebello et al., «Can Applications Recover from fsync Failures?», USENIX ATC 2020.
- SQLite «Atomic Commit»: коммит — это момент удаления rollback-journal; durability требует двух fsync (журнал, затем файл данных). Режим `synchronous=EXTRA` отдельно синкает **каталог** после удаления журнала — прямое подтверждение необходимости directory-fsync. Под default-настройками коммиты SQLite не durable при power-loss — иллюстрация, что атомарность ≠ durability.

### Windows / NTFS специфика (из MSDN/Microsoft и Postgres-тредов)
- `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`: документация не гарантирует атомарность; по словам инженера MS (Doug Cook), «usually atomic, but in some cases it silently falls back to a non-atomic method». Также `MoveFileEx` падает с ошибкой, если целевой файл открыт другим процессом (баг в Postgres на Windows: «could not rename temporary statistics file»). NTFS журналирует **метаданные**, поэтому replace-rename часто атомарен, но это нигде не задокументировано.
- `ReplaceFile`: рекомендуется Microsoft как замена `MoveFile`, сохраняет атрибуты/ACL/время создания, есть исследование MS Research, утверждающее атомарность; требует, чтобы целевой файл существовал (иначе нужен fallback на `MoveFileEx`).
- `NtSetInformationFile` + `FILE_RENAME_INFORMATION` (с флагом `FILE_RENAME_POSIX_SEMANTICS` на Win10+) — самый «атомарный» способ; именно его использует Zig.
- `FlushFileBuffers` («The Old New Thing», 2017): на Windows 8+ надёжно коммитит на физический диск (NTFS перешёл с FUA на `FLUSH_CACHE`, обязательную для совместимости с Win8). `FILE_FLAG_WRITE_THROUGH` сам по себе не гарантирует обхода кэша диска на EIDE/SATA (драйверы не уважают FUA). **Нет операции «fsync каталога» на Windows** (WASI-issue #756): `FlushFileBuffers` работает только по файлам, способа синкнуть directory-entry нет — на Windows directory-fsync шаг просто опускается (NTFS-журнал метаданных закрывает эту дыру для самого rename).

### Контрольные суммы
- По официальному бенчмарку xxHash (Intel i7-9700K, Ubuntu 20.04, clang v10 -O3): **XXH3 (SSE2) 64-бит = 31.5 GB/s, XXH64 = 19.4 GB/s, MD5 = 0.6 GB/s, SHA1 = 0.8 GB/s**; сам xxHash «работает на пределе скорости RAM» (референс последовательного чтения RAM в той же таблице = 28.0 GB/s).
- Про CRC32: автор xxHash Yann Collet (Cyan4973) в issue #62 отвечает на заявление «аппаратный crc32 ~3× быстрее xxhash»: «Hardware crc32c by itself is not competitive… it cannot keep up with ILP, which most modern hash algorithms use… I have found several implementations which can best XXH64 speed, but none yet that can best XXH3.» Теоретический потолок SSE4.2-CRC32 ~20.5 GB/s @3GHz, но на практике инструкция ограничена зависимостью по данным; XXH3 за счёт ILP обгоняет.
- Для нашей задачи (детект bitrot и частичной записи, **не** защита от злоумышленника) рекомендуется **XXH3/xxHash64** per-tile/per-record: максимум скорости, достаточно энтропии, есть в экосистеме. CRC32 — допустимая альтернатива, если важна совместимость инструментов или out-of-order/parallel вычисление по блокам.
- Форматы с per-chunk-checksum как образец: PNG (4-байтный CRC32 на каждый chunk, считается по type+data, присутствует всегда даже для пустых chunk-ов), GLB/glTF (magic `0x46546C67`, version=2, length; чанки JSON `0x4E4F534A` и BIN `0x004E4942` с 4-байтным выравниванием), SQLite WAL (покадровые checksum). Это модель «magic + version + поток самоописывающихся чанков с длиной», что и нужно для частичного парсинга.

### Формат `.gset` (точно, из InputGeom.cpp, ветка main — verbatim fprintf/sscanf)
Формат строковый, line-prefix; **версии в нём нет**. Чтобы не сломать совместимость с RecastDemo, писать его нужно тем же `fprintf`-форматом:
- `f %s` — путь к мешу (`.obj`).
- `s` (build settings, 21 поле, только если settings заданы): `"s %f %f %f %f %f %f %f %f %f %f %d %f %f %d %f %f %f %f %f %f %f\n"` → cellSize, cellHeight, agentHeight, agentRadius, agentMaxClimb, agentMaxSlope, regionMinSize, regionMergeSize, edgeMaxLen, edgeMaxError, **vertsPerPoly(int)**, detailSampleDist, detailSampleMaxError, **partitionType(int)**, navMeshBMin[0..2], navMeshBMax[0..2], tileSize.
- `c` (off-mesh connection, 10 полей): `"c %f %f %f %f %f %f %f %d %d %d\n"` → startX,startY,startZ, endX,endY,endZ, rad(float), bidir(int), area(int), flags(int). При чтении: `addOffMeshConnection(startPos, endPos, rad, (unsigned char)bidir, (unsigned char)area, (unsigned short)flags)`.
- `v` (convex volume): `"v %d %d %f %f\n"` → nverts(int), area(int), hmin(float), hmax(float); затем **`nverts` строк по 3 float** `"%f %f %f\n"` (x y z) **без префикса**.

Важно: в текущем main off-mesh = префикс **`c`**, convex volume = **`v`** (не `o`). Чтение через `parseRow`/`sscanf` с теми же форматами и в том же порядке полей. RecastDemo при загрузке диспетчеризует по `row[0]` и игнорирует неизвестные префиксы — это даёт нам безопасный канал расширения **только через отдельные файлы**, не через `.gset`.

### Detour TileCache (для маппинга гранулярности)
- `dtTileCache::addTile(data, dataSize, flags, result)` / `removeTile(ref, data, dataSize)` — данные тайла это «просто blob», который можно хранить где угодно; tile cache хранит навигируемую область как сжатый heightfield-слой. `dtCompressedTile` содержит `salt`, `header` (`dtTileCacheLayerHeader` с tx/ty/tlayer), `compressed`/`compressedSize`, `data`/`dataSize`, `flags`.
- Формат tilecache имеет свой magic и версию (DetourTileCacheBuilder.h): **`DT_TILECACHE_MAGIC = 'D'<<24 | 'T'<<16 | 'L'<<8 | 'R'` (='DTLR'), `DT_TILECACHE_VERSION = 1`**; плюс `DT_TILECACHE_NULL_AREA=0`, `DT_TILECACHE_WALKABLE_AREA=63`, `DT_TILECACHE_NULL_IDX=0xffff`.
- Рекомендация из рассылки Recast для больших миров: «add to cache only the tiles that fit into memory», добавлять слои `addTile()`, затем `buildNavMeshTilesAt()`. Tile cache ≈ 2× память static-navmesh, но даёт быстрый rebuild и динамические препятствия. Это естественно ложится на per-tile файлы, ключ — (tx,ty,layer).

## Details

### НАПРАВЛЕНИЕ 1 — Durable-запись: рецепт и пробелы Zig

**Эталонный рецепт (POSIX), пошагово:**
1. Создать temp-файл в **том же каталоге**, что и цель (rename атомарен только в пределах одной ФС/каталога; иначе `EXDEV`).
2. `write`/`pwrite` всех данных. Для буферизованного `std.Io.Writer` — обязательный `flush()` (иначе данные осядут в user-space буфере).
3. `File.sync(temp)` — fsync содержимого+метаданных файла. **Проверить ошибку**; при `EIO` считать операцию проваленной (урок fsyncgate), не ретраить «вслепую».
4. Atomic `rename(temp → dest)` в том же каталоге.
5. **fsync дескриптора каталога** — чтобы directory-entry о rename попала на диск.
6. (Желательно) повторно убедиться в отсутствии ошибок; для критичных коммитов — fsync каталога после удаления временных артефактов.

**Эталонный рецепт (Windows/NTFS):**
1. Temp-файл в том же каталоге.
2. Запись; затем `FlushFileBuffers(handle)` (= `File.sync`) — на Win8+ надёжно коммитит на диск.
3. Atomic replace: `NtSetInformationFile`+`FILE_RENAME_INFORMATION` (Zig идёт этим путём) либо `ReplaceFileW`/`MoveFileExW(MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)`. NTFS журналирует метаданные → сам rename атомарен на уровне метаданных.
4. **fsync каталога не нужен и недоступен** — на Windows нет directory-fsync; целостность directory-entry обеспечивает NTFS-журнал метаданных.

**Конкретные вызовы:**
- POSIX: `std.posix.fsync(fd)` (через `File.sync`); `std.posix.renameat`; для каталога — открыть каталог и `fsync` его fd. На macOS для реального сброса кэша диска нужен `fcntl(F_FULLFSYNC)` — в stdlib не оборачивается, нужен прямой вызов.
- Windows: `FlushFileBuffers` (через `File.sync`); rename — `NtSetInformationFile` (Zig внутренне) либо kernel32 `ReplaceFileW`/`MoveFileExW` напрямую через `std.os.windows`/`extern`.

**Что ОТСУТСТВУЕТ в Zig 0.16 stdlib и как закрывать:**
1. **fsync каталога** — нет кросс-платформенной обёртки. POSIX: открыть `Dir` и вызвать `std.posix.fsync(dir.fd)` напрямую (исторически `fsync` на dir-fd ловил `unreachable` на `EINVAL` — issue #15563/#17950; нужно обрабатывать самому/патчить switch). Windows: no-op.
2. **AtomicFile не делает fsync** ни файла, ни каталога — durability на нас: явный `File.sync` до `replace()` и явный directory-fsync после.
3. **macOS `F_FULLFSYNC`** — не обёрнут; вызывать `std.c.fcntl`/`std.posix.fcntl` напрямую.
4. **Гарантии Windows-rename** — Zig использует `NtSetInformationFile`; если нужна семантика `ReplaceFile` (сохранение ACL/атрибутов) — звать kernel32 напрямую.
5. **fsync error semantics** — stdlib возвращает ошибку, но политику «PANIC/недоверенное состояние на EIO» реализуем сами.

**Подводные камни (явно):** перезапись «на месте» с truncate (нельзя — при краше теряется и старое, и новое); вера «rename атомарен → данные на диске» (нет: атомарность ≠ durability); переупорядочивание записей без барьера fsync; ложный успех повторного fsync после EIO; temp-файл в другом каталоге/ФС (rename перестаёт быть атомарным).

### НАПРАВЛЕНИЕ 2 — Гранулярность и архитектура для больших миров

**Сравнение стратегий:**

| Стратегия | Write-amp на мелкое изменение | Blast-radius | Скорость загрузки большого мира | Сложность | Кросс-консистентность |
|---|---|---|---|---|---|
| Монолит (1 файл, полная перезапись) | Очень высокая (весь файл) | Весь мир | Грузить всё сразу; медленно/много RAM | Низкая | Тривиально (1 atomic rename) |
| Per-tile файлы (tx_ty_layer) | Минимальная (1 тайл) | 1 тайл | Стриминг/частичная загрузка | Средняя (много файлов, индекс) | Нужен индекс/манифест + порядок коммитов |
| Append-only log + компакция (LSM-like) | Низкая (последовательная дозапись) | Хвост лога | Реплей лога; компакция нужна | Высокая | Реплей восстанавливает порядок |
| **Гибрид (геометрия монолит/.gset + правки в логе/sidecar + тайлы per-file)** | Низкая | Тайл/запись | Стриминг тайлов + быстрый старт | Средняя-высокая | Манифест + журнал |

**Рекомендация:** для нашего масштаба (от средних сцен до open-world в гигабайты тайлов) — **гибрид**:
- `scene.gset` + `*.obj` — геометрия, текст, формат RecastDemo, меняется редко, пишется монолитно atomic-rename.
- `edits/` — наши бинарные реестры (area-types: name/color/cost/flags; poly-flags; convex volumes; off-mesh connections в нашем формате с версией) — маленькие, пишутся целиком atomic-rename, при желании поверх append-only журнала правок.
- `tiles/` — по файлу на (tx,ty,layer), внутри — сжатый TileCache-blob (наш `navmesh_io.zig`/Detour-сериализация) + наш заголовок с checksum. Меняется только изменённый тайл.
- `manifest` — список тайлов, версии форматов, ссылки на geometry; обновляется atomic-rename последним, после fsync всех новых тайлов (порядок коммита: тайлы → fsync → манифест → fsync каталога). Это и есть точка атомарного «переключения» версии мира, аналог super-journal в SQLite.

**Логика LSM (RocksDB/LevelDB):** последовательные дешёвые записи + фоновая компакция; ключевой компромисс — write/read/space amplification (RUM-конъюнктура). Для нас полноценный LSM избыточен, но **append-only журнал правок area/flags** между snapshot-ами тайлов даёт дешёвую запись и восстановление реплеем; периодическая компакция = пере-сохранение тайлов и обрезка журнала. Помнить про write-amplification leveled-компакции (до ~10× на переход уровня) — поэтому держим число «уровней» минимальным: журнал → snapshot, без многоуровневой иерархии.

**Маппинг на существующее (не переизобретать):** `dtCompressedTile`-blob кладём как тело per-tile файла; (tx,ty,layer) из `dtTileCacheLayerHeader` — ключ имени файла. `addTile`/`removeTile`/`buildNavMeshTilesAt` уже умеют принимать «blob откуда угодно» — наш слой только читает файл и отдаёт указатель. Сохраняем существующие magic/version из `navmesh_io.zig` и TileCache (`DT_TILECACHE_MAGIC='DTLR'`/`DT_TILECACHE_VERSION=1`).

**Миграция «один файл → per-tile» без переписывания всего:** ввести `manifest` с полем формата; если монолит — читать по-старому; при первом сохранении писать новые/изменённые тайлы как отдельные файлы и помечать их в манифесте, оставляя неизменённые в старом контейнере (lazy split). Старый монолит остаётся валидным fallback, пока все тайлы не вынесены; затем удалить его одним atomic-шагом после fsync манифеста.

### НАПРАВЛЕНИЕ 3 — Целостность, восстановление, версионирование

**Заголовок (на файл и на запись/тайл):**
```
magic: u32         // напр. наш per-domain magic
version: u16/u32   // версия формата (как в navmesh_io.zig)
flags/type: u16
payload_len: u64   // длина тела — для частичного парсинга и skip
checksum: u64      // XXH3/xxHash64(type || header_no_csum || payload)
```
Файл = `[file header][record/tile 0][record 1]...`, каждая запись самоописывающаяся (length + checksum), как PNG-chunks/RIFF/glTF.

**Что ловит checksum:** bitrot (одиночные/множественные флипы), частичную/оборванную запись (несовпадение length/checksum), «мусор в хвосте» после краша. **Чего не ловит:** логически валидную, но семантически неверную запись; целенаправленную подделку (xxHash не криптостойкий — для нас не требуется).

**Частичное восстановление (graceful degradation):** при загрузке итерируемся по записям; если magic/version/length/checksum не сходятся — **пропускаем запись/тайл и логируем**, продолжая грузить остальные. Битый один тайл в open-world не должен ронять весь мир — именно ради этого per-tile + per-tile checksum. Ошибки маппим на существующие в `navmesh_io.zig`: `Truncated`/`WrongMagic`/`WrongVersion` + добавить `ChecksumMismatch`.

**Бэкапы/ротация/откат:** перед перезаписью `manifest`/тайла — снапшот предыдущей версии (N последних: `manifest.0..N`); т.к. atomic-rename и так оставляет старый файл до момента замены, дешёвый откат = переключить манифест на предыдущую версию. Для тайлов — хранить 1–2 предыдущих поколения до успешной компакции.

**Политика версионирования:**
- Наши бинарные форматы (тайлы, реестры): `magic+version`, монотонно растущая версия; reader поддерживает чтение N−k версий (backward compat), при старшей неизвестной версии — `WrongVersion` и отказ грузить именно эту запись, а не падение всего (forward compat). Миграция — на чтении (upgrade-on-load) с последующей пере-записью в новой версии.
- `.gset`: **версии нет и не вводим** — формат RecastDemo строковый, добавление новых строк его не ломает (RecastDemo игнорирует неизвестные line-prefix через `parseRow`), но менять семантику `f/s/c/v` нельзя. Любые наши расширения — только в отдельных файлах `edits/`, не в `.gset`.

## Recommendations

**Стадия 0 (минимум, ~неделя):** Монолит + atomic rename + checksum.
- Реализовать `writeAtomic(dir, name, bytes)`: `createFileAtomic` → запись → `flush` → **явный `File.sync`** → `replace` → **directory-fsync (POSIX)**. Это базовый кирпич для всего.
- Добавить `file header` (magic+version+XXH3) ко всем нашим бинарным файлам; `.gset` писать as-is тем же fprintf-форматом.
- Порог перехода дальше: если полное сохранение мира > ~200–500 мс или файл > ~64–128 МБ — переходить на per-tile.

**Стадия 1 (масштабирование):** Per-tile файлы + manifest.
- `tiles/tx_ty_layer.tile` с per-tile заголовком/checksum; `manifest` с версиями и списком.
- Порядок коммита: новые тайлы → fsync каждого → fsync каталога `tiles/` → atomic-rename `manifest` → fsync корня сцены.
- Загрузка: стриминг тайлов по запросу (как советует Recast для больших миров), пропуск битых.

**Стадия 2 (частые правки):** Append-only журнал + компакция.
- Правки area-types/poly-flags/volumes/offmesh — дозаписью в `journal` (каждая запись с checksum); восстановление — реплей поверх последнего snapshot манифеста.
- Компакция по порогам: журнал > X МБ, или > Y записей, или при явном «Save» — пере-сохранить затронутые тайлы/реестры и обрезать журнал atomic-replace.

**Что изменит решение (триггеры):** мир целиком влезает в RAM и сохраняется редко → можно остаться на монолите; целевые ФС только NTFS/ext4 с журналом метаданных → можно ослабить directory-fsync; требование защиты от подделки → заменить xxHash на криптохэш (BLAKE3/SHA-256).

**Обязательный платформенный код (закрыть пробелы stdlib):** (1) directory-fsync на POSIX с корректной обработкой `EINVAL`; (2) явный `File.sync` перед `replace` (AtomicFile не синкает); (3) macOS `F_FULLFSYNC` через прямой `fcntl`; (4) трактовка `EIO` из fsync как фатальной (урок fsyncgate); (5) при желании — `ReplaceFileW` напрямую на Windows, если нужна сохранность ACL.

## Caveats
- **AtomicFile/createFileAtomic и fsync (частично не верифицировано):** подтверждено, что `File.sync` = fsync и что stdlib не синкает каталог; что именно `AtomicFile.replace/finish` делает с fsync в 0.16 — по исходнику дословно подтвердить не удалось (репозиторий Zig переехал с GitHub на Codeberg, raw-исходник `lib/std/fs/AtomicFile.zig` не открылся в этой сессии). Исторически (0.13–0.15) `finish()` **не** вызывал fsync ни файла, ни каталога — поэтому рекомендация делать fsync вручную остаётся в силе как безопасная по умолчанию. Перед релизом сверьтесь с `AtomicFile.zig` на Codeberg (`https://codeberg.org/ziglang/zig/src/branch/master/lib/std/fs/AtomicFile.zig`) и с `lib/std/os/windows.zig` (поиск `renameat`, `FileRenameInformation`).
- **Windows-rename Zig:** что Zig использует `NtSetInformationFile`+`FILE_RENAME_INFORMATION` — основано на устоявшейся реализации и политике «Prefer Native API», дословной цитаты из `windows.zig` текущей версии получить не удалось.
- **`.gset` префиксы:** проверены по актуальному `main` (off-mesh = `c`, convex = `v`, settings = `s`, mesh = `f`; форматы fprintf/sscanf приведены дословно). В более старых форках/версиях префиксы/набор полей могли отличаться — при поддержке старых файлов проверяйте конкретную версию RecastDemo.
- **Zig 0.16 — движущаяся цель:** идёт активная миграция `fs`→`Io` (часть API ещё со stub-ами `@panic` в `Io.Threaded`), сигнатуры с параметром `io` могут уточняться. Названия (`createFileAtomic`, `File.sync`) проверены по релиз-нотам 0.16 и форуму Ziggit (февраль 2026).
- **fsync ≠ абсолютная гарантия:** на уровне железа диск может игнорировать flush; FUA не уважается частью SATA/EIDE. Полная защита от power-loss требует корректного железа/UPS — вне зоны ответственности кода.