# Спек-фундамент: универсальный navmesh debug/анализ-инструмент

> **Статус:** дизайн-документ (НЕ реализация). Cross-cutting фундамент, на который
> ссылаются кластерные спеки A–J.
> **Дата:** 2026-06-04. **Версия Zig:** 0.16.0. **Проект:** `zig-recast`.
> **Область:** `demo/src/*` (GUI), опора на `src/*` (faithful-порт ядра).

## Оглавление

1. [Цель и ценность для developer-user](#1-цель-и-ценность-для-developer-user)
2. [Scope (in / out / YAGNI)](#2-scope-in--out--yagni)
3. [Подсистемы фундамента](#3-подсистемы-фундамента)
   - [3.a Модель данных сцены (Scene)](#3a-модель-данных-сцены-scene)
   - [3.b Персистентность (durable-контейнер)](#3b-персистентность-durable-контейнер)
   - [3.c Render / overlay-инфраструктура](#3c-render--overlay-инфраструктура)
   - [3.d UI-shell конвенции](#3d-ui-shell-конвенции)
4. [Карта зависимостей кластеров A–J](#4-карта-зависимостей-кластеров-aj)
5. [Открытые вопросы / допущения](#5-открытые-вопросы--допущения)
6. [Риски](#6-риски)
7. [Этапы внедрения фундамента](#7-этапы-внедрения-фундамента)

---

## 1. Цель и ценность для developer-user

Сейчас демо (`demo/src/`) — это faithful-порт `recastnavigation/RecastDemo`:
интерактивный визуализатор с тремя сэмплами, 16 debug-режимами, инструментами
(tester/prune/offmesh/convex/crowd) и MSET-сохранением *собранного* navmesh.
Но состояние **сцены** (convex volumes, off-mesh, реестры area/flags) живёт
только в RAM текущей сессии (см. `FEATURES.md` §11 «Нет персистентности
состояния сцены»), а инструментарий ориентирован на демонстрацию, не на
систематический debug/анализ навмеша как у инженера-пользователя.

**Фундамент** — это четыре сквозные подсистемы, которые превращают демо в
расширяемую платформу:

- **Единая модель данных сцены** (`Scene`) — то, что инструменты читают/пишут и
  что сериализуется атомарно и целостно. Сейчас состояние размазано по
  `InputGeom` (параллельные массивы), глобальным `area_types`/`poly_flags` и
  полям сэмплов; кластерам нужна одна точка истины.
- **Durable-персистентность** — гибрид-контейнер сцены (геометрия + правки +
  тайлы), atomic write + checksum + версии. Без неё невозможны кластеры
  I (шаринг/воспроизводимость), D (импорт/экспорт), H (headless).
- **Переиспользуемый render/overlay-слой** — цветовые схемы, легенды, изоляция,
  выделение полигонов поверх существующего `debug_draw_gl` + `ui.screenText`.
  База для всех визуализаций (кластер E).
- **UI-shell конвенции** — единый паттерн регистрации инструмента/панели/окна и
  гейты ввода, чтобы каждый кластер добавлял фичи единообразно, а не правил
  гигантский `main.zig`.

Ценность: developer-user получает воспроизводимый, сохраняемый, расширяемый
рабочий стол, где «почему запрос не нашёл путь», «что сломалось в билде»,
«сколько это стоит», «поделись сценой» — становятся встроенными сценариями, а не
ad-hoc `std.debug.print` (как сейчас в инспекции полигона `main.zig:480-491`).

---

## 2. Scope (in / out / YAGNI)

### Входит (in)

- Дизайн структуры `Scene` (агрегатор), её владение под-моделями и API для
  инструментов. **Без переписывания** существующих `InputGeom`/`area_types`/
  `poly_flags` — фундамент их *оборачивает* и добавляет точку истины.
- Дизайн durable-слоя: `writeAtomic`, header magic/version/checksum (XXH3),
  `registry_io`, `tile-store`, `manifest`, директория-контейнер, этапы 0→1→2.
  Распиливается из готового `compass_artifact_*.md` — **не ре-ресёрчим**.
- Дизайн render/overlay-расширений к `debug_draw_gl.zig`/`ui.zig`: цветовые
  схемы, легенды, изоляция/clipping, выделение полигонов.
- Конвенции UI-shell: интерфейс «панель/окно/инструмент», гейты ввода
  (`ui_mouse`/`ui_keyboard` уже введены, `main.zig:225-226`).
- Карта зависимостей: какой кластер на какую подсистему опирается.

### Не входит (out / YAGNI)

- Реализация кода фундамента (это делают последующие PR по этому спеку).
- Реализация самих кластеров A–J (отдельные спеки).
- Сетевой шаринг/облако, multi-user, undo/redo-движок (кластеры F/I решат сами,
  фундамент только готовит модель данных под это).
- Полноценный LSM/база (compass-док явно: для нашего масштаба избыточно).
- Замена `dvui`/`zgl`/рендер-бэкенда. Замена faithful-ядра `src/*`.
- Криптостойкие хэши/подписи (XXH3 достаточно — детект bitrot, не защита от
  атак; compass §«Контрольные суммы»).
- Изменение формата `.gset` (compass: не трогаем, расширяемся только sidecar-
  файлами).
- Кроссплатформенный idle-perfect fsync на экзотических ФС (закрываем
  NTFS/ext4-кейс; см. риски).

---

## 3. Подсистемы фундамента

### 3.a Модель данных сцены (Scene)

#### Что делает

`Scene` — единый агрегат редактируемого состояния мира, отделённый от
визуализации и от собранного navmesh. Это **point of truth**, которую
сериализует персистентность (3.b) и которой оперируют инструменты и кластеры.

Сейчас состояние фрагментировано:

| Что | Где сейчас | Форма |
|---|---|---|
| Геометрия (verts/tris/normals/bounds) | `input_geom.zig` `InputGeom` | `Managed(f32/i32)` |
| Convex volumes | `input_geom.zig` `volumes: Managed(ConvexVolume)` | массив структур |
| Off-mesh connections | `input_geom.zig` `off_verts/off_rad/off_dir/off_area/off_flags/off_id` | **6 параллельных** `Managed` |
| Area-типы (name/color/flags/cost) | `area_types.zig` | **глобальный** `var types: [64]AreaType` |
| Poly-флаги (name/bit) | `poly_flags.zig` | **глобальный** `var flags: [16]Flag` |
| Build-настройки | `sample.zig` `CommonSettings` + per-sample | копии в каждом сэмпле |
| Собранный navmesh | `dt.NavMesh` в сэмпле | бинарь MSET (`navmesh_io.zig`) |

Проблемы для кластеров: (1) `area_types`/`poly_flags` — **module-global**
(`var types`, `var flags`, `ensureInit()`), а не часть инстанса сцены — нельзя
иметь две сцены/сравнивать/headless-инстанс; (2) off-mesh как 6 параллельных
массивов хрупок при сериализации/редактировании; (3) нет идентификатора/версии
сцены; (4) settings дублируются (`solo.settings`/`tile.settings`/`temp.settings`).

#### Интерфейс (дизайн, не финальный код)

```
// demo/src/scene.zig — НОВЫЙ агрегатор. Владеет под-моделями, отдаёт стабильный API.
pub const Scene = struct {
    alloc: std.mem.Allocator,
    geom: InputGeom,              // переиспользуем как есть (verts/tris/volumes/offmesh)
    areas: AreaRegistry,          // ВЫНЕСТИ area_types из module-global в инстанс
    flags: FlagRegistry,          // ВЫНЕСТИ poly_flags из module-global в инстанс
    settings: CommonSettings,     // единственная копия настроек сборки
    meta: SceneMeta,              // имя/uuid/версия формата/ссылка на geometry(.obj/.gset)
    dirty: DirtyBits,             // что изменилось с последнего save (geom/areas/flags/tiles)

    pub fn init(alloc) Scene;
    pub fn deinit(self) void;
    // снимок для сериализации (3.b) — без копий, срезы во владение Scene:
    pub fn snapshot(self) SceneSnapshot;
};
```

Конвенции (см. `.agent/project_structure.md` + CLAUDE.md):

- Файл `demo/src/scene.zig` (snake_case). Это **demo-уровень** (не ядро) —
  можно usize/owned-модель, ядро `src/*` не трогаем.
- `AreaRegistry`/`FlagRegistry` — рефактор `area_types.zig`/`poly_flags.zig` из
  module-global в struct-инстанс. **Совместимость:** оставить тонкие
  module-обёртки на «текущую активную сцену» на переходный период, чтобы
  `tool_*.zig`/`main.zig` не переписывать одним PR.
- Геттеры usize на структурах (CLAUDE.md): `vertCount()`/`triCount()`/
  `offMeshCount()` уже есть в `InputGeom` — паттерн сохраняем.
- Off-mesh: **внутри оставляем параллельные массивы** (faithful с `InputGeom`),
  но даём *view*-геттер `offMesh(i) -> OffMeshConn` для чистых call-sites и
  сериализации (закрывает хрупкость без ломки `addOffMeshConnection`).

#### Зависимости

- Опирается на: `input_geom.zig`, `area_types.zig`, `poly_flags.zig`,
  `sample.zig` (`CommonSettings`).
- Используется: персистентностью (3.b сериализует `SceneSnapshot`), всеми
  инструментами (3.d передаёт `*Scene` вместо `*InputGeom`), кластерами F/G/I.

---

### 3.b Персистентность (durable-контейнер)

> Дистилляция из `compass_artifact_wf-97dad774-...md`. Решения берём оттуда,
> не ре-ресёрчим.

#### Что делает

Сохраняет/загружает **сцену целиком** durably: геометрия + правки (area/flags/
volumes/offmesh) + тайлы навмеша, с атомарностью, целостностью (checksum),
версионированием и graceful degradation (битый тайл не роняет мир).

#### Архитектура: гибрид «директория-контейнер»

Из compass (§TL;DR, §НАПРАВЛЕНИЕ 2). Сцена — это **директория**, не один файл:

```
<scene>.recastscene/
├── scene.gset          # геометрия — формат RecastDemo, ТЕКСТ, версии НЕТ, as-is fprintf
│                       #   (читается RecastDemo + .obj). compass §«Формат .gset».
├── *.obj               # сам меш (ссылка из .gset строкой `f %s`)
├── edits/              # НАШИ бинарные реестры (есть version+magic+XXH3):
│   ├── areas.reg       #   area-типы: name/color(rgba)/flags(u16)/cost(f32)
│   ├── flags.reg       #   poly-флаги: name/bit
│   ├── volumes.bin     #   convex volumes (наш формат, НЕ в .gset)
│   └── offmesh.bin     #   off-mesh connections (наш формат, НЕ в .gset)
├── tiles/              # по файлу на (tx,ty,layer): tx_ty_layer.tile
│   └── 0_0_0.tile      #   dtCompressedTile/MSET-blob + per-tile header+checksum
└── manifest            # список тайлов, версии форматов, ссылки на geometry;
                        #   atomic-rename ПОСЛЕДНИМ = точка переключения версии мира
```

Почему гибрид (compass-таблица стратегий): минимальный write-amp на мелкую
правку (1 тайл / 1 запись), малый blast-radius (битый тайл ≠ битый мир),
стриминг больших миров, `.gset` остаётся совместим с upstream RecastDemo.

#### Durable-запись: точный рецепт (compass §НАПРАВЛЕНИЕ 1)

Порядок (POSIX): `creat(temp в том же каталоге) → write → flush(buffered) →
File.sync(temp) [проверить EIO!] → atomic rename(temp→dest) → fsync(dir)`.

Windows/NTFS: `temp → write → FlushFileBuffers(=File.sync) → atomic replace
(NtSetInformationFile+FILE_RENAME_INFORMATION, Zig делает внутри) → fsync
каталога НЕ нужен и недоступен` (NTFS журналирует метаданные).

В Zig 0.16: `std.Io.Dir.createFileAtomic(io, path, .{.replace=true})` →
`AtomicFile`; пишем через writer + `flush()`, затем **явный** `File.sync`, затем
`af.replace(io)`.

#### Пробелы Zig 0.16 stdlib и как закрывать (compass §«Что ОТСУТСТВУЕТ»)

| Пробел | Закрытие |
|---|---|
| `createFileAtomic`/`AtomicFile` **не делает fsync** ни файла, ни каталога | явный `File.sync(temp)` ДО `replace()`; directory-fsync ПОСЛЕ |
| Нет кросс-платформ. directory-fsync | POSIX: открыть `Dir` + `std.posix.fsync(dir.fd)`, обработать `EINVAL` (issue #15563/#17950). Windows: no-op |
| macOS `F_FULLFSYNC` не обёрнут | прямой `std.c.fcntl(F_FULLFSYNC)` (не приоритет — цель Win/Linux) |
| `EIO` из fsync | трактовать как фатальную, **не ретраить вслепую** (урок fsyncgate, compass §Key Findings) |
| Windows ACL-rename | при нужде — `ReplaceFileW` напрямую (не требуется по умолчанию) |

> compass §Caveats: перед релизом сверить `AtomicFile.zig`/`windows.zig` на
> Codeberg — репозиторий Zig переехал, дословно `replace()`-семантику в
> исследовании подтвердить не удалось. Безопасное допущение: делаем fsync вручную.

#### Целостность: header + checksum (compass §НАПРАВЛЕНИЕ 3)

Per-file и per-record/per-tile заголовок:

```
magic:        u32   // per-domain ('MSET' уже есть в navmesh_io.zig:11; для edits/tiles — свои)
version:      u32   // как navmesh_io.zig VERSION; монотонно растёт
type/flags:   u16
payload_len:  u64   // длина тела -> частичный парсинг + skip битого
checksum:     u64   // XXH3/xxHash64(type || header_no_csum || payload)
```

Файл = `[file header][record 0][record 1]...` — самоописывающиеся чанки (модель
PNG/glTF/RIFF, compass). **XXH3/xxHash64** — детект bitrot/обрыва, не защита от
атак (compass §«Контрольные суммы»: XXH3 31.5 GB/s, на пределе RAM).

**Graceful degradation:** при загрузке итерируемся по записям; не сошлись
magic/version/length/checksum — пропустить+залогировать, грузить остальное.
Ошибки маппим на уже существующие в `navmesh_io.zig` (`Truncated`/`WrongMagic`/
`WrongVersion`, строки 89-91) + добавить `ChecksumMismatch`.

#### Версионирование

- Наши бинарные форматы (edits/tiles): `magic+version`, reader читает N−k версий
  (upgrade-on-load), на старшей неизвестной — `WrongVersion` для записи (не краш
  всего). MSET уже версионирован (`navmesh_io.zig` VERSION=1).
- `.gset`: **версии нет и не вводим** — расширяемся только sidecar `edits/`,
  семантику `f/s/c/v` не меняем (compass §«Формат .gset»: off-mesh=`c`,
  convex=`v`, settings=`s`, mesh=`f`, дословные fprintf-форматы там же).

#### Конкретные модули (дизайн)

```
demo/src/persist/
├── write_atomic.zig    # writeAtomic(dir, name, bytes): createFileAtomic -> flush ->
│                       #   File.sync -> replace -> dirFsync(POSIX). Базовый кирпич ВСЕГО.
├── checksum.zig        # XXH3/xxHash64 обёртка + chunk-header pack/unpack
├── registry_io.zig     # areas.reg / flags.reg <-> AreaRegistry/FlagRegistry (3.a)
├── scene_io.zig        # volumes.bin / offmesh.bin; .gset writer (as-is fprintf)
├── tile_store.zig      # tiles/tx_ty_layer.tile: ключ (tx,ty,layer) из
│                       #   dtTileCacheLayerHeader; тело = MSET/dtCompressedTile blob
└── manifest.zig        # manifest read/write; коммит-порядок (тайлы->fsync->manifest)
```

Переиспользуем: `io_util.zig` (`readWholeFile`/`writeWholeFile`/`std.Io.Threaded`
паттерн, строки 7-20) — `writeAtomic` строится поверх того же `std.Io.Dir.cwd()`/
`io`-паттерна. MSET reader/writer (`navmesh_io.zig`) — образец Reader-курсора и
put-хелперов (строки 14-22, 59-81), переиспользуется для `tile_store`.

#### Этапы (compass §Recommendations)

- **Этап 0** (минимум): монолит-файл сцены + `writeAtomic` + header(magic/version/
  XXH3) на всех наших бинарниках; `.gset` as-is. Порог перехода: save > ~200-500 мс
  или файл > ~64-128 МБ.
- **Этап 1** (масштаб): `tiles/tx_ty_layer.tile` + `manifest`; коммит-порядок
  (новые тайлы → fsync каждого → fsync `tiles/` → atomic-rename `manifest` →
  fsync корня). Загрузка — стриминг + пропуск битых.
- **Этап 2** (частые правки): append-only `journal` правок area/flags/volumes/
  offmesh + компакция по порогам. Полноценный LSM НЕ нужен (compass).

#### Зависимости

- Опирается на: `Scene`/`SceneSnapshot` (3.a), `io_util.zig`, `navmesh_io.zig`
  (MSET-образец), TileCache (`src/detour_tilecache`).
- Используется: кластерами D/H/I (фундаментально), F (save после правки),
  G (золотые снимки для регрессий).

---

### 3.c Render / overlay-инфраструктура

#### Что делает

Переиспользуемый слой над `debug_draw_gl.zig` (3D) и `ui.zig` (2D-текст), чтобы
**любая** debug-визуализация (кластер E и др.) получала из коробки: цветовые
схемы, легенды, изоляцию/clipping, выделение полигонов — без дублирования.

#### Что уже есть (база)

- `DebugDrawGL` (`debug_draw_gl.zig`): vtable `begin/vertex/vertexXYZ/end/
  depthMask/texture/areaToCol`, батчинг в VBO, толстые линии через screen-quad
  (`expandThickLines`, 345), QUADS→tris, туман, **переопределяемый**
  `area_to_col: ?*const fn(u32)u32` (112) — уже хук цветовой схемы.
- Цвет-хелперы (`src/debug/debug_draw.zig`): `rgba`/`intToCol`/`transCol`/
  `darkenCol`/`lerpCol`/`multCol`/`calcBoxColors` (63-143) — палитра готова.
- Debug-draw навмеша (`src/debug/detour_debug.zig`): `debugDrawNavMesh`,
  `debugDrawNavMeshPoly(mesh, ref, col)` (117) — **примитив выделения полигона
  уже есть**, `debugDrawNavMeshPolysWithFlags` (100), `...Portals`/`...BVTree`/
  `...Nodes`.
- Геометрия: `appendCircle`/`appendArc`/`appendBoxWire` (`debug_draw.zig`).
- Overlay-текст: `ui.screenText`/`screenTextEx` (`ui.zig` 44-66) — worldspace/
  screen-текст с центрированием; `cam.worldToScreen` (используется в
  `main.zig:912`). Перф-счётчики кадра `dd_gl.draw_calls`/`verts_uploaded`.

#### Что добавить (дизайн)

```
demo/src/render/
├── color_scheme.zig   # enum ColorScheme { area, region, flags, height, component, cost }
│                      #   + fn colorForPoly(scheme, ctx) u32. Ставится в
│                      #   DebugDrawGL.area_to_col ИЛИ применяется per-poly при обходе тайлов.
├── legend.zig         # 2D-легенда (свотчи цвет->подпись) поверх dvui-кадра, через
│                      #   ui.screenText + dvui.box. Привязана к активной ColorScheme.
├── overlay.zig        # хелперы worldspace-аннотаций (ref/cost/height над полигоном) —
│                      #   обобщение разрозненных screenTextEx из main.zig:894-985
├── isolation.zig      # фильтр видимости: рисовать только {tile|region|poly|component}=X
│                      #   (per-poly предикат при обходе; "show only" / "dim others")
└── highlight.zig      # выделение набора полигонов поверх debugDrawNavMeshPoly +
                       #   подсветка/контур (переиспользует tester polys/parent подсветку)
```

Ключевые решения:

- **Цветовые схемы** — единый `ColorScheme` вместо хардкода в `sampleAreaToCol`
  (`sample.zig:53`) и `vtAreaToCol` (`debug_draw_gl.zig:391`). По area уже есть;
  добавляем region/flags/height/component/cost. Схема ставится в существующий
  хук `area_to_col` или применяется при per-poly обходе (для height/cost нужен
  контекст полигона, не только area — поэтому второй путь).
- **Изоляция/clipping** — не GL-clip-плоскости, а **предикат видимости** при
  обходе полигонов тайла («show only region N», «dim others» через
  `transCol`/`darkenCol`). Дёшево, переиспользует существующий обход
  `debugDrawNavMesh`.
- **Выделение** — обобщить уже работающую в tester'е подсветку (`polys`/`parent`
  массивы + `debugDrawNavMeshPoly`) в `highlight.zig`, чтобы why-no-path
  (кластер A) и валидация (G) рисовали наборы полигонов одинаково.
- **Легенды** — 2D поверх dvui-кадра (как hint-текст `main.zig:968-984`),
  привязка к активной схеме.

#### Зависимости

- Опирается на: `debug_draw_gl.zig`, `src/debug/*`, `ui.zig`, `camera.zig`
  (`worldToScreen`).
- Используется: **всеми** кластерами с визуализацией; E — основной потребитель,
  A/G/J — выделение/изоляция/легенды. Это базовая подсистема (см. §4).

---

### 3.d UI-shell конвенции

#### Что делает

Единый паттерн добавления инструмента/панели/окна + гейты ввода, чтобы кластеры
не правили монолитный `main.zig` (>1000 строк, всё инлайн) и не дублировали
dispatch.

#### Что уже есть (база)

- Диспетч инструмента: `ActiveTool` enum (`main.zig:37`), ручной свитч на
  click/render/menu (`main.zig:477-498`, `599-606`, `682-689`).
- Интерфейс `SampleTool` vtable (`sample.zig:125-172`):
  `toolType/reset/drawMenu/onClick/onToggle/step/update/render/renderOverlay` —
  **готовый контракт инструмента**, но текущие `tool_*.zig` вызываются напрямую,
  не через него.
- Окна: `dvui.floatingWindow` с фикс-`Rect` по краям (`main.zig:643-659`),
  hideable через `app.show_*` чекбоксы (`app_state.zig:15-18`) + `show_flags`
  (`main.zig:238`).
- Гейты ввода: `ui_mouse` (курсор над панелью) / `ui_keyboard` (фокус в
  textfield) — **уже введены** (`main.zig:225-226`, обновляются `991-992`),
  применяются к камере/хоткеям/пикингу/Esc (`main.zig:362,396,436,464`).
- Панели: Tools (лево), Properties (право), Log (низ), Test Cases, Poly Flags.
- Логирование: `BuildContext` (`build_context.zig`), `bctx.context().log(...)`,
  окно Log (`main.zig:774-785`).

#### Что добавить (дизайн)

```
demo/src/shell/
├── tool_registry.zig  # реестр инструментов: []ToolEntry { id, label, hint, vtable:*SampleTool }
│                      #   заменяет ручной ActiveTool-свитч единым циклом dispatch.
│                      #   Кластер регистрирует свой инструмент = добавляет ToolEntry.
├── panel.zig          # дескриптор окна: PanelDesc { title, rect_fn, visible:*bool, draw_fn }
│                      #   обобщает повтор floatingWindow+windowHeader+scrollArea.
└── input_gate.zig     # инкапсуляция ui_mouse/ui_keyboard + хелперы "claimMouse"/"claimKbd"
                       #   чтобы кластерам не дублировать !ui_mouse && !ui_keyboard.
```

Ключевые решения:

- **Реестр инструментов** через существующий `SampleTool` vtable: кластер
  добавляет `ToolEntry` (label/hint + vtable), а main-цикл итерирует реестр для
  радиокнопок (`main.zig:674-679`), click/render/menu-dispatch. Hint-строка
  (`main.zig:969-976`) переезжает в `ToolEntry.hint`.
- **Дескриптор панели** обобщает паттерн `floatingWindow + windowHeader +
  scrollArea + open_flag` (повторён 5 раз в `main.zig`). Hideable-окна =
  `visible: *bool`.
- **Гейты ввода** — формализовать уже введённые `ui_mouse`/`ui_keyboard` в
  `input_gate.zig` (без смены семантики), дать кластерам общий хелпер вместо
  копипасты `!ui_mouse and !ui_keyboard` (например `main.zig:436`).
- **Не ломать faithful-сэмплы**: `Sample` vtable (`sample.zig:207`) и
  `CommonSettings` UI (`drawCommonSettings`) остаются как есть; shell —
  надстройка над диспетчем, не замена сэмплов.

#### Зависимости

- Опирается на: `sample.zig` (`SampleTool` vtable), `dvui`, `ui.zig`,
  `app_state.zig`, `build_context.zig`.
- Используется: **всеми** кластерами, добавляющими инструмент/панель. Каждый
  кластер A/F/G/J регистрирует инструменты через shell.

---

## 4. Карта зависимостей кластеров A–J

Подсистемы фундамента: **Sc**=Scene(3.a), **P**=Persist(3.b), **R**=Render/
overlay(3.c), **U**=UI-shell(3.d).

| Кластер | Тема | Sc | P | R | U | Примечание |
|---|---|:--:|:--:|:--:|:--:|---|
| **A** | Диагностика запросов (why-no-path) | ● | ○ | ●● | ● | выделение полигонов (R.highlight), overlay-аннотации (ref/cost/filter); инструмент через U |
| **B** | Интроспекция build-конвейера | ● | ○ | ●● | ● | визуализация стадий rasterize→regions→contours (R.color_scheme/isolation); читает settings из Sc |
| **C** | Профилирование / перф | ○ | ○ | ● | ● | расширяет `dd_gl.draw_calls`/Tracy; перф-overlay (R), панель (U) |
| **D** | Импорт / экспорт / интероп | ●● | ●● | ○ | ● | сериализация Sc через P; форматы (MSET/.gset/.obj/glTF); фундаментально на Sc+P |
| **E** | Визуализация / рендер | ○ | ○ | ●● | ● | **основной потребитель R**; новые схемы/легенды/изоляция |
| **F** | Редактирование / authoring UX | ●● | ●● | ● | ●● | мутирует Sc, сохраняет через P; undo/redo поверх Sc.DirtyBits; инструменты через U |
| **G** | Корректность / валидация / регрессии | ● | ●● | ● | ● | золотые снимки сцены/навмеша через P; выделение нарушений через R |
| **H** | Скриптинг / headless | ●● | ●● | ○ | ○ | **Sc без module-global** (3.a-рефактор обязателен!); P для загрузки; без R/U |
| **I** | Воспроизводимость / шаринг | ●● | ●● | ○ | ○ | durable-контейнер сцены = P; uuid/версия в Sc.meta; **базовый кластер** |
| **J** | Динамика / рантайм (crowd/tilecache) | ● | ● | ● | ● | tile-store (P) для tilecache-слоёв; overlay агентов (R, уже частично в main.zig) |

● = опирается, ●● = фундаментально зависит, ○ = слабо/опционально.

**Базовые кластеры (фундамент для остальных):**

- **R (render-инфра, 3.c)** — почти все кластеры визуализируют; E/A/B/G строятся
  поверх схем/выделения/изоляции.
- **P + Sc (персистентность + модель, 3.b/3.a)** — D/H/I/F/G невозможны без
  durable-сцены и точки истины. **I и D — фундаментальны**; **H требует
  обязательного выноса `area_types`/`poly_flags` из module-global** (3.a), иначе
  headless-инстансы конфликтуют по глобальному состоянию.

Порядок реализации кластеров диктуется этим: сначала Sc+P+R+U (фундамент), затем
I/D/E (на готовом фундаменте), затем A/B/F/G/H/C/J.

---

## 5. Открытые вопросы / допущения (к владельцу)

> **РЕШЕНО владельцем (2026-06-04):**
> - **Q1 macOS:** отложить — приоритет Win(NTFS)+Linux(ext4), macOS best-effort.
> - **Q2 module-global → инстанс:** через переходные обёртки на «активную сцену»,
>   по-кластерная миграция (не big-bang).
> - **Q3 контейнер:** директория `.recastscene/` как рабочий формат **+
>   обязательный экспорт/импорт всей сцены одним архив-файлом** (для пересылки).
>   То есть single-file-архив входит в фундамент-персистентность, не откладывается:
>   `scene_io` получает `packArchive`/`unpackArchive` (директория ⇄ один файл).
> - **Q4 этап персистентности:** **стартуем сразу с этапа 1 (per-tile + manifest)**,
>   а не с монолита. Atomic-примитивы/checksum (бывший этап 0) — это базис под
>   per-tile, делаются вместе. Цель — большие миры с самого начала.
> - **Q5 checksum:** **XXH3/xxHash64** (нужен Zig-порт/зависимость — внести в этап).
> - **Q6 settings:** единая копия в `Scene.settings`, сэмплы читают её.
> - **Q7 граница render/E:** обобщённые механизмы (схемы/легенды/изоляция/
>   выделение) — в фундамент (3.c); конкретные новые визуализации — в кластер E.

Ниже — исходные формулировки (историческая справка):

1. **Целевые ОС персистентности.** compass закрывает Win(NTFS)+Linux(ext4).
   Нужен ли durable-путь для macOS (`F_FULLFSYNC`) сейчас, или отложить?
   *Допущение:* Win+Linux первоочередно, macOS — best-effort.
2. **Module-global → инстанс (3.a).** Вынос `area_types`/`poly_flags` из
   `var types`/`var flags` в `Scene` — это касается ~всех `tool_*.zig` и
   `main.zig`. Делаем сразу (обязательно для H) или через переходные
   module-обёртки на «активную сцену»? *Допущение:* обёртки на переходный период.
3. **Граница `.recastscene`-директории vs совместимость.** Гибрид-контейнер —
   директория. Нужна ли опция «один-файл-архив» (zip-подобный) для удобного
   шаринга (кластер I), или директории достаточно? *Допущение:* директория на
   этапах 0-1, single-file-архив — отдельный вопрос кластера I.
4. **С какого этапа персистентности стартуем.** compass даёт 0→1→2. Начинаем с
   этапа 0 (монолит+atomic+checksum) и растём по порогам, или сразу per-tile
   (этап 1)? *Допущение:* этап 0, переход по порогам (save>200-500мс / >64-128МБ).
5. **Checksum-алгоритм.** XXH3 (нет в stdlib — нужна зависимость/порт) vs CRC32
   (проще, но медленнее). *Допущение:* XXH3/xxHash64 (compass-рекомендация),
   если нет приемлемого Zig-XXH3 — CRC32 как допустимая альтернатива.
6. **Settings: единая копия (3.a).** Сейчас `CommonSettings` дублируется в
   solo/tile/temp. Унифицировать в `Scene.settings`, или оставить per-sample
   (faithful с upstream)? *Допущение:* единая копия в Scene, сэмплы читают её.
7. **Объём кластера E vs 3.c.** Где граница: что попадает в фундамент-render
   (3.c) vs в кластер E? *Допущение:* в фундамент — обобщённые механизмы
   (схемы/легенды/изоляция/выделение), в E — конкретные новые визуализации.

---

## 6. Риски

- **R1 — Zig 0.16 движущаяся цель (compass §Caveats).** `fs`→`Io`-миграция,
  часть API со stub-`@panic` в `Io.Threaded` (issue #25738), `createFileAtomic`/
  `AtomicFile.replace` fsync-семантика дословно не подтверждена. *Митигация:*
  делаем fsync вручную (безопасное допущение); сверить `AtomicFile.zig`/
  `windows.zig` на Codeberg перед реализацией этапа 0.
- **R2 — directory-fsync на POSIX** исторически ловил `unreachable` на `EINVAL`
  (issue #15563/#17950). *Митигация:* обрабатывать `EINVAL` самим в обёртке
  `write_atomic.zig`.
- **R3 — Рефактор module-global (3.a)** трогает много call-sites
  (`tool_*.zig`/`main.zig`). Большой PR → риск регрессий faithful-поведения.
  *Митигация:* переходные обёртки, по-кластерная миграция, регрессионные тесты
  (`test/integration/`).
- **R4 — fsync ≠ durability на железе** (compass: FUA не уважается частью SATA;
  диск может игнорировать flush). *Митигация:* вне зоны кода; документировать
  ограничение, не давать ложных гарантий power-loss.
- **R5 — Раздувание `main.zig`.** Без U-shell (3.d) каждый кластер увеличивает
  монолит. *Митигация:* shell делать рано, до кластеров A/F/G/J.
- **R6 — Производительность render-обхода при изоляции/схемах.** Per-poly
  предикат на больших навмешах. *Митигация:* предикаты дешёвые (сравнение
  region/area-id), переиспользуем существующий батчинг VBO; контролировать
  `dd_gl.draw_calls`/`verts_uploaded`.
- **R7 — `.gset`-совместимость.** Любое изменение семантики `f/s/c/v` ломает
  RecastDemo-совместимость (compass §«Формат .gset»). *Митигация:* расширения
  только в `edits/`-sidecar, `.gset` пишем дословным fprintf as-is.

---

## 7. Этапы внедрения фундамента (порядок)

Порядок выбран так, чтобы каждый шаг разблокировал максимум кластеров и не
ломал faithful-поведение.

1. **U-shell минимум (3.d).** `input_gate.zig` (формализация уже введённых
   `ui_mouse`/`ui_keyboard`) + `tool_registry.zig` поверх существующего
   `SampleTool` vtable. Разгружает `main.zig` ДО прихода новых инструментов.
   *Разблокирует:* единообразную регистрацию для всех кластеров.
2. **Scene-агрегатор каркас (3.a).** `scene.zig` оборачивает существующие
   `InputGeom`/`area_types`/`poly_flags`/`CommonSettings` + `SceneMeta`
   (uuid/версия) + `DirtyBits`. Module-global пока через переходные обёртки.
   *Разблокирует:* точку истины для P и всех кластеров.
3. **Render/overlay-инфра (3.c).** `color_scheme.zig` + `highlight.zig` +
   `overlay.zig` (обобщение существующих screenText/areaToCol/debugDrawNavMeshPoly);
   затем `legend.zig` + `isolation.zig`. *Разблокирует:* E (основной), A/B/G.
4. **Персистентность — per-tile с самого начала (3.b, решение Q4).**
   `write_atomic.zig` (базовый кирпич: createFileAtomic→flush→File.sync→replace→
   dirFsync) + `checksum.zig` (**XXH3**, Zig-порт/зависимость) + header
   magic/version/XXH3 на всех бинарниках. Сразу директория-контейнер:
   `registry_io`/`scene_io` (edits/), `tile_store.zig` (tiles/tx_ty_layer.tile),
   `manifest.zig` + коммит-порядок (тайлы→fsync→manifest→fsync); `.gset` writer
   as-is. Плюс `scene_io.packArchive`/`unpackArchive` (директория ⇄ один файл для
   пересылки, решение Q3). *Разблокирует:* I/D/G/F (save/load сцены + шаринг),
   большие миры/стриминг (J).
5. **Вынос module-global в инстанс (3.a, полный).** Завершить рефактор
   `area_types`/`poly_flags` из `var`-глобалей в `Scene`-поля, снять переходные
   обёртки. *Разблокирует:* H (headless/множественные сцены).
6. **Персистентность этап 2 (3.b, при необходимости).** append-only `journal` +
   компакция — только если профиль правок этого потребует (частые мелкие
   area/flags-правки). YAGNI до подтверждённой потребности.

Критический путь для большинства кластеров: **1 → 2 → 3 → 4**. Шаги 5-6 —
по мере прихода H и роста сцен.
