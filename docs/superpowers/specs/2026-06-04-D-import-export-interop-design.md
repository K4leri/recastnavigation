# Кластер D — Импорт / экспорт / интероп

> **Статус:** дизайн-документ (НЕ реализация, НЕ код). Кластерный спек поверх
> спека-фундамента `2026-06-04-00-foundation-design.md`.
> **Дата:** 2026-06-04. **Версия Zig:** 0.16.0. **Проект:** `zig-recast`.
> **Область:** `demo/src/*` (GUI + headless), опора на `src/*` (faithful-ядро,
> НЕ меняем) и на подсистемы фундамента Scene (3.a) / Persist (3.b) /
> Render (3.c) / UI-shell (3.d).

Этот спек **ссылается** на подсистемы фундамента и **не переопределяет** их.
Где написано «через Persist» / «через Scene» — имеется в виду API, спроектированный
в фундаменте (§3.a/3.b), который к моменту реализации D должен существовать
(см. §5 «зависимости от ещё-не-реализованного фундамента»).

## Оглавление

1. [Цель и ценность для developer-user](#1-цель-и-ценность-для-developer-user)
2. [Scope (in / out / YAGNI)](#2-scope-in--out--yagni)
3. [Фичи (приоритезированы)](#3-фичи-приоритезированы)
   - [D1 — Импорт геометрии: glTF/glb, PLY, STL](#d1--импорт-геометрии-gltfglb-ply-stl)
   - [D2 — Экспорт навмеша как геометрии: .obj / glTF полигонов](#d2--экспорт-навмеша-как-геометрии-obj--gltf-полигонов)
   - [D3 — Экспорт метрик навмеша: JSON](#d3--экспорт-метрик-навмеша-json)
   - [D4 — Экспорт путей/запросов: CSV / JSON](#d4--экспорт-путейзапросов-csv--json)
   - [D5 — CLI / headless-построение с метриками](#d5--cli--headless-построение-с-метриками)
   - [D6 — Сравнение с эталоном upstream C++ (diff навмеша)](#d6--сравнение-с-эталоном-upstream-c-diff-навмеша)
   - [D7 — Экспорт топологии: SVG / скриншот (опц.)](#d7--экспорт-топологии-svg--скриншот-опц)
4. [Архитектура (новые файлы, точки интеграции)](#4-архитектура-новые-файлы-точки-интеграции)
5. [Открытые вопросы / допущения к владельцу](#5-открытые-вопросы--допущения-к-владельцу)
6. [Риски](#6-риски)
7. [Этапы реализации (порядок)](#7-этапы-реализации-порядок)

---

## 1. Цель и ценность для developer-user

Сейчас интероп демо узок (`FEATURES.md` §10–11):

- **Вход** — только `.obj` (`input_geom.zig:77 loadMesh`, вершины `v` + грани `f`
  с триангуляцией веером; нормали/материалы игнорируются, `FEATURES.md:451`).
- **Выход** — только бинарный MSET *собранного* navmesh (`navmesh_io.zig`,
  magic 'MSET', VERSION 1), пути захардкожены по типу сэмпла
  (`FEATURES.md:415-419`).
- **Нет** экспорта навмеша как читаемой геометрии, нет машиночитаемых метрик
  для CI/регрессий, нет экспорта результатов запросов, нет headless-режима
  (есть только визуальные `--bench`/`--cyclemodes`, `main.zig`/`FEATURES.md:427`),
  нет сравнения с upstream-эталоном.

**Кластер D** превращает инструмент в узел data-pipeline:
developer-user может (а) затащить геометрию из своего пайплайна (glTF/PLY/STL,
не только `.obj`), (б) вытащить навмеш и его метрики в форматах, которые читают
другие инструменты и CI (`.obj`/glTF/JSON/CSV), (в) построить навмеш **без GUI**
из скрипта/CI и получить метрики, (г) **сравнить** свой Zig-навмеш с эталоном
C++ recastnavigation на том же входе — это прямой инструмент валидации
faithful-порта (главная цель проекта по `CLAUDE.md`).

Ценность: воспроизводимый «вход → навмеш → числа → diff с upstream» становится
встроенным сценарием, а не ad-hoc скриптами. D — это «края» сцены (что входит /
что выходит); ядро durability — у Persist (3.b), модель — у Scene (3.a).

---

## 2. Scope (in / out / YAGNI)

### Входит (in)

- **Импорт-парсеры** дополнительных форматов геометрии в ту же модель, что и
  `loadMesh`: STL (бинарный + ASCII), PLY (бинарный LE/BE + ASCII), glTF 2.0 /
  glb (только меши/`POSITION`+индексы, мировые трансформации узлов). Результат —
  `verts`/`tris` `InputGeom` (та же точка, куда пишет `.obj`).
- **Экспорт навмеша как геометрии:** `.obj` (полигоны навмеша → грани) и
  glTF/glb (минимальный, индексированные треугольники). Источник — `dt.NavMesh`
  (обход тайлов/полигонов) либо recast `PolyMesh` (`src/recast/polymesh.zig`,
  `vertCount`/`polyCount`/`nvp`).
- **Экспорт метрик** навмеша в JSON (стабильная схема: bounds, #tiles, #polys,
  #verts, per-area-гистограмма, build-time, settings-снимок).
- **Экспорт результатов запросов** (пути/raycast/etc. из tester'а) в CSV и JSON.
- **CLI/headless**: подкоманда сборки навмеша из входной геометрии + сцены-правок
  (через Scene/Persist) без открытия окна; печать/запись метрик (D3) и опц.
  экспорт навмеша (D2). Переиспользует существующий парс аргументов в `main.zig`.
- **Diff с upstream C++**: канонизация обоих навмешей в общий нейтральный формат
  (метрики D3 + опц. геометрия D2), машинный diff с допусками (eps), отчёт.
- **Регистрация** GUI-точек (кнопки Export…/Import…) через UI-shell (3.d
  `tool_registry`/`panel`).

### Не входит (out / YAGNI)

- **Свой durable-контейнер.** Сохранение/загрузка *сцены целиком*
  (`.recastscene/`, atomic write, checksum, manifest, архив) — это **Persist
  (3.b)**, не D. D добавляет только **обменные** форматы (interchange), которые
  читают внешние инструменты; они не обязаны быть durable/atomic (это разовые
  артефакты-выгрузки).
- **Изменение формата `.gset`** и MSET-формата — нельзя (faithful/upstream-совместимость,
  фундамент §2, риск R7). `.gset` пишет Persist (3.b `scene_io`), не D.
- **Запуск самого C++ recastnavigation** из Zig (FFI/линковка/сборка C++).
  D6 работает с **артефактами**, которые C++-сторона уже выдала (см. §5 Q6).
- Полноценный glTF (анимации, скины, PBR-материалы, KHR-расширения, sparse
  accessors, Draco). Берём узкий путь: меш-примитивы `TRIANGLES`,
  `POSITION` + опц. `indices`, иерархия узлов для трансформации.
- Импорт навмеша из чужих движков (Unity/UE navmesh-форматы) — отдельный кластер
  при потребности.
- FBX/USD/Collada (тяжёлые SDK-зависимости) — YAGNI.
- PNG/растровый скриншот топологии из headless (нет GL-контекста) — D7 даёт
  только **SVG** (векторная проекция, без GL); растровый скрин остаётся за
  GUI-`--bench`-путём.

---

## 3. Фичи (приоритезированы)

Приоритет: **P0** D1, D3, D5 (вход + числа + headless — ядро ценности и базис D6);
**P1** D2, D4, D6; **P2** D7.

Легенда зависимостей: **Sc**=Scene(3.a), **P**=Persist(3.b), **R**=Render(3.c),
**U**=UI-shell(3.d), **src/**=faithful-ядро.

---

### D1 — Импорт геометрии: glTF/glb, PLY, STL — **P0**

**Что.** Парсеры STL/PLY/glTF, наполняющие тот же приёмник, что `loadMesh`:
`InputGeom.verts`/`tris` (после — `computeBounds`/`computeNormals`, уже есть
`input_geom.zig:120-122`). Точка диспетча — расширение файла.

**Зачем.** Реальные ассеты редко в `.obj`. glTF/glb — де-факто обменный формат;
STL — частый выход CAD/печати; PLY — частый выход сканеров/процедурной генерации.
Без них developer-user вручную конвертит в `.obj` (теряя точность/масштаб).

**UX.** Дропдаун входного меша (`Properties`, `FEATURES.md:46-49`) начинает
показывать `*.gltf`/`*.glb`/`*.ply`/`*.stl` (расширить `scanDirectory` вызовы,
`io_util.zig:64`, ныне сканирует один ext). Выбор → загрузка → авто-`reset view`
(существующий путь по bounds). Ошибки парса → в окно Log (`bctx.context().log`).
Кнопка **Import Geometry…** в shell-панели для произвольного пути.

**Данные.**
- STL: 80-байт header + `u32` triangle count + N×(normal 3×f32 + 3 verts 3×f32 +
  attr u16); ASCII — `facet normal/outer loop/vertex`. Нормали файла игнорируем
  (как для `.obj`, `FEATURES.md:451`) — считаем сами. Дедуп вершин опц. (YAGNI на
  старте: STL без индексов → можно эмитить verts as-is, tris подряд).
- PLY: header `ply`/`format ascii|binary_little_endian|binary_big_endian`,
  `element vertex N`/`property float x|y|z…`, `element face M`/`property list
  uchar int vertex_indices`. Триангуляция веером полигонных граней (как `.obj`,
  `input_geom.zig:111-116`).
- glTF/glb: glb — `glTF` magic + version + JSON-chunk + BIN-chunk; gltf — JSON +
  внешние/`data:`-base64 буферы. Читаем `meshes[].primitives[]` с
  `mode==TRIANGLES`, accessor `POSITION` (`VEC3`/`FLOAT`) + опц. `indices`
  (`SCALAR` u16/u32). Применяем мировую матрицу узла (умножение по иерархии
  `nodes`/`scenes`) — переиспользуем `mat.zig`/`mat`-хелперы демо.
- Единая ось/масштаб: см. §5 Q1 (Y-up предполагается, как у recast).

**Зависимости.** **Sc** (пишем в `Scene.geom`/`InputGeom`; через переходную
обёртку «активная сцена» фундамента 3.a). `io_util.zig` (`readWholeFile`,
`scanDirectory`). `mat.zig` (трансформации узлов glTF). `src/` — не трогаем.
**U** — кнопка импорта (опц., дропдаун достаточно). Без P/R.

---

### D3 — Экспорт метрик навмеша: JSON — **P0**

**Что.** Сериализация числового профиля собранного навмеша + снимка настроек в
JSON со **стабильной версионированной схемой** (`schema_version`). Источник —
`dt.NavMesh` (обход `mesh.tiles`, как `navmesh_io.zig:31-34`/`48`) + при наличии
recast-промежуточных (`PolyMesh`) для per-stage чисел.

**Зачем.** Машиночитаемые числа — база CI-регрессий и D6 (diff). Сейчас метрики
только в окне Log как текст (`FEATURES.md:56`). JSON = «золотой снимок» для G и
вход для diff-инструментов.

**UX.** Кнопка **Export Metrics (JSON)…** (shell-панель). В headless (D5) —
флаг `--metrics=out.json` или stdout. Поля (черновик схемы):
```
{ "schema_version":1, "source":{"geom":"dungeon.obj","sample":"solo"},
  "settings":{ cell_size, cell_height, agent_height, agent_radius, agent_max_climb,
               agent_max_slope, region_min_size, region_merge_size, edge_max_len,
               edge_max_error, verts_per_poly, detail_sample_dist, detail_sample_max_error,
               partition, tile_size? },
  "bounds":{ "min":[x,y,z], "max":[x,y,z] },
  "navmesh":{ "num_tiles":N, "num_polys":N, "num_verts":N, "max_polys":N },
  "areas":[ {"id":0,"name":"Ground","poly_count":N}, ... ],
  "build_ms": 12.34 }
```

**Данные.** Settings берём из единой `Scene.settings` (фундамент 3.a решение Q6).
`build_ms` — `PerfTimer` (`io_util.zig:98`). Площадь/гистограмма по area — обход
полигонов тайлов (`poly.getArea()` в ядре). Имена area — из `AreaRegistry` (3.a)
или `area_types.zig` (переходно). JSON-эмиттер: `std.json.Stringify`/ручной
writer; **детерминированный порядок ключей** (важно для diff).

**Зависимости.** **Sc** (settings/areas/bounds). `src/detour/navmesh.zig`
(обход тайлов/полигонов — read-only). **U** (кнопка). `io_util.writeWholeFile`.
Без P (это interchange-артефакт, не durable-контейнер) — но D5/D6 потребляют его.

---

### D5 — CLI / headless-построение с метриками — **P0**

**Что.** Подкоманда: загрузить геометрию (D1-форматы) + опц. сцену-правки
(`.recastscene` через **Persist 3.b** или `.gset`), построить навмеш выбранным
сэмплом, выгрузить метрики (D3) и опц. навмеш (D2/MSET) — **без окна/GL**.

**Зачем.** CI, batch-обработка, воспроизводимость, основа D6. Сейчас headless
нет: `--bench`/`--cyclemodes` всё равно открывают окно и крутят рендер
(`FEATURES.md:427-434`).

**UX (CLI).** Расширить существующий парс аргументов `main.zig` (там уже
`--bench`/`--draw`/`--cam`, `FEATURES.md:427`). Пример:
```
recast_demo build --geom dungeon.obj --sample solo \
    --cfg cells=0.3,agent_radius=0.6,partition=watershed \
    --metrics out.json --out-navmesh nav.bin [--out-obj nav.obj]
recast_demo build --scene world.recastscene --metrics out.json
```
Без `--geom/--scene` и без `build` → текущее GUI-поведение (обратная совместимость).
Exit-code ≠ 0 при ошибке сборки/парса (CI-дружелюбно). Прогресс/ошибки → stderr,
метрики → файл или stdout.

**Данные.** Ключевой архитектурный момент: **build-конвейер сэмпла должен
вызываться без GL-контекста**. Сейчас сэмплы (`sample_solo.zig` и т.д.) держат
build-логику; нужно убедиться, что `handleBuild`-путь отделим от рендера. На
старте — самостоятельный headless-builder поверх `src/recast`/`src/detour`
напрямую (faithful-конвейер rasterize→…→Detour-данные), **переиспользуя те же
параметры** `CommonSettings`, чтобы числа совпадали с GUI-сборкой (см. §5 Q3,
риск R3). `BuildContext` (`build_context.zig`) для тайминга/лога — он не зависит
от GL.

**Зависимости.** **Sc** (модель/настройки **без module-global** — критично:
headless требует инстанс-area/flags, фундамент 3.a решение Q2/этап 5). **P**
(загрузка `.recastscene`/`.gset`, если `--scene`). `src/recast`+`src/detour`
(сам конвейер). D3 (метрики), D2 (опц. экспорт). **Не** R/U. **Зависит от
ещё-не-реализованного:** Persist (для `--scene`) и полного выноса module-global
(для чистого headless) — см. §5.

---

### D2 — Экспорт навмеша как геометрии: .obj / glTF полигонов — **P1**

**Что.** Записать полигоны навмеша как меш: `.obj` (`v` + `f`, полигоны
произвольной арности — `.obj` их поддерживает) и минимальный glTF/glb
(триангулировать веером, индексы u16/u32, `POSITION`). Источник: `dt.NavMesh`
(обход тайлов/полигонов/вершин) или recast `PolyMesh`
(`src/recast/polymesh.zig`: `verts`/`polys`/`nvp`/`vertCount`/`polyCount`).

**Зачем.** Открыть навмеш в Blender/MeshLab/любом вьювере, использовать как
коллизию/визуал в движке, диффать геометрически (D6). Сейчас навмеш «застрял»
в бинарном MSET.

**UX.** Кнопка **Export NavMesh → .obj / glTF…** (shell-панель) + headless
`--out-obj`/`--out-gltf` (D5). Опции: экспорт из финального `dt.NavMesh`
(world-space, с off-mesh опц.) vs из recast `PolyMesh` (до Detour). На старте —
из `dt.NavMesh` (то, что реально используется на рантайме).

**Данные.** `.obj`: распаковать `u16`-координаты `PolyMesh` через `bmin`+`cs/ch`
в мировые f32 (как делает debug-draw) либо взять f32-верты из detail-mesh
(`PolyMeshDetail.verts`, `polymesh.zig:140`). Грани = полигоны (для `PolyMesh`
учесть терминатор `RC_MESH_NULL_IDX`/арность ≤ `nvp`). glTF: единственный mesh,
один buffer (`.bin` для `.gltf` или встроенный chunk для `.glb`), accessor min/max
для `POSITION` (требование спеки glTF).

**Зависимости.** `src/recast/polymesh.zig` / `src/detour/navmesh.zig` (read-only
обход). **Sc** (bounds/cs/ch из settings для распаковки `u16`). `io_util`. **U**.
Без P/R.

---

### D4 — Экспорт путей/запросов: CSV / JSON — **P1**

**Что.** Выгрузить результаты Detour-запросов из tester'а
(`tool_navmesh_tester.zig`): для каждого запроса — тип, start/end, статус, длина
пути, число полигонов/waypoint'ов, сами точки (straight-path corners), список
poly-refs, время. CSV (плоская таблица «по запросу») + JSON (вложенно, с точками).

**Зачем.** Анализ покрытия pathfinding'а, регрессии «тот же запрос → тот же
путь», импорт в таблицы/ноутбуки. Сейчас результаты только визуальны + счётчик
`polys: N waypoints: M` (`FEATURES.md:197`).

**UX.** Кнопка **Export Query Results…** в панели Tools при активном tester'е
(через U). Источник — текущий результат tester'а (буфер straight-path до 2048
точек, `FEATURES.md:176`) либо прогон всех загруженных Test Cases
(`testcase.zig`, `FEATURES.md:393-407`) → батч-CSV (`T<index>`, OK/fail, ms).

**Данные.** CSV: `query_id,type,sx,sy,sz,ex,ey,ez,status,path_len,npolys,nwaypoints,ms`.
JSON: то же + `"corners":[[x,y,z,flags,ref],…]`, `"path":[ref,…]`. Флаги/include/
exclude фильтра запроса (`FEATURES.md:193`) тоже фиксируем — для воспроизводимости.

**Зависимости.** `tool_navmesh_tester.zig` (нужен публичный аксессор результата —
read-only геттер; не переписываем tester, добавляем экспорт-вызов).
`testcase.zig` (батч). **U** (кнопка). `io_util`. Без P/R/Sc-мутаций.

---

### D6 — Сравнение с эталоном upstream C++ (diff навмеша) — **P1**

**Что.** На одном входе (geom + settings) сравнить Zig-навмеш с эталоном C++
recastnavigation. Канонизировать оба в нейтральные артефакты (метрики D3 +
опц. геометрия D2), диффать с числовыми допусками (eps), выдать отчёт
«идентично / расходится в X».

**Зачем.** Прямая проверка faithful-порта — **главная цель проекта** (`CLAUDE.md`:
сверка с upstream C++). Это инструмент непрерывной валидации, а не разовая.

**UX (две стадии).**
- **Стадия 1 (метрики-diff, дёшево):** `recast_demo diff --a a.json --b b.json
  [--eps 1e-4]` — сравнивает два D3-JSON (Zig vs эталон). Отчёт: совпавшие/
  разошедшиеся поля, %-расхождение по #polys/#verts/bounds/per-area.
- **Стадия 2 (структурный diff, опц.):** сравнение геометрии навмеша (D2-выгрузки):
  соответствие полигонов/вершин с допуском, выявление «лишних/недостающих»
  полигонов. Сложнее (нет канонического порядка полигонов между реализациями) —
  YAGNI до подтверждённой потребности, начинаем с метрик.

**Откуда эталон.** D **не** собирает/линкует C++ (out, §2). Эталон — артефакт,
который C++-сторона уже произвела: либо D3-совместимый JSON, который пишет
форк RecastDemo, либо MSET-`.bin` от upstream → грузим (`navmesh_io.load`) →
канонизируем в метрики на нашей стороне. См. §5 Q6 (формат эталона — вопрос
владельцу). MSET от upstream совместим (формат портирован 1-в-1).

**Данные.** Сравнение — по стабильной схеме D3 (детерминированный порядок).
Числовые поля — допуск eps (float-несовпадения ожидаемы); счётчики — точное
равенство или порог. Отчёт — текст (stderr) + опц. JSON (`--out diff.json`),
exit-code ≠ 0 при расхождении сверх порога (CI-гейт).

**Зависимости.** D3 (схема/канон), D2 (стадия 2). `navmesh_io.zig` (грузить
upstream-MSET). **Возможна синергия со skill `recast-benchmarking`** (там уже
есть identity-gate «идентичный выход» между Zig и C++) — переиспользовать его
методологию сравнения, не дублировать. Без R/U (CLI). **P** — опц. (если эталон
в `.recastscene`).

---

### D7 — Экспорт топологии: SVG / скриншот (опц.) — **P2**

**Что.** Векторная проекция навмеша/контуров на плоскость (top-down XZ) в **SVG**
(полигоны как `<polygon>` с заливкой по area-цвету, рёбра, опц. off-mesh-дуги,
легенда). Работает **в headless** (нет GL). Растровый PNG — через существующий
GUI-`--bench`-путь (не D7).

**Зачем.** Лёгкий обзорный артефакт топологии для доков/ревью/тикетов без
запуска GUI; диффабельный визуально (SVG — текст).

**UX.** `recast_demo build … --out-svg topo.svg` (D5) + кнопка **Export SVG…** в GUI.
Проекция XZ (как мини-карта), цвета area — из **R `color_scheme`** (3.c) если
доступна, иначе из `area_types`.

**Данные.** Обход полигонов навмеша → 2D-полигоны (отбросить Y) → SVG-path/polygon
+ viewBox по bounds. Off-mesh — линии/дуги. Без зависимостей от GL/dvui.

**Зависимости.** `src/detour/navmesh.zig` (обход). **R** `color_scheme` (3.c,
опц. — для совпадения цветов с GUI). **U** (кнопка). `io_util`.

---

## 4. Архитектура (новые файлы, точки интеграции)

Всё — **demo-уровень** (`demo/src/`, snake_case, по `.agent/project_structure.md`).
Faithful-ядро `src/*` не меняем; обходы навмеша/полимеша — через существующие
read-only API (`navmesh.zig` `getTile`/обход `tiles`, `polymesh.zig`
`vertCount`/`polyCount`/`nvp`). Геттеры usize на структурах — паттерн CLAUDE.md.

### 4.1 Новые файлы

```
demo/src/io/                          # обменные (interchange) форматы — НЕ durable
├── import_stl.zig     # D1: STL bin+ASCII -> InputGeom.verts/tris
├── import_ply.zig     # D1: PLY ascii/bin LE+BE -> InputGeom.verts/tris
├── import_gltf.zig    # D1: glTF/glb meshes/primitives(TRIANGLES) + node-трансформы
├── import_geom.zig    # D1: диспетч по расширению (obj|stl|ply|gltf|glb);
│                       #     .obj делегирует существующему InputGeom.loadMesh
├── export_obj.zig     # D2: dt.NavMesh|PolyMesh -> .obj (v/f)
├── export_gltf.zig    # D2: dt.NavMesh|PolyMesh -> glTF/glb (TRIANGLES, POSITION+indices)
├── export_metrics.zig # D3: dt.NavMesh + Scene.settings -> JSON (schema_version)
├── export_query.zig   # D4: tester/testcase результаты -> CSV/JSON
└── export_svg.zig     # D7: dt.NavMesh -> SVG (top-down XZ)

demo/src/cli/
├── cli.zig            # D5: парс подкоманд build/diff; маршрутизация headless vs GUI
├── headless_build.zig # D5: безоконный конвейер (src/recast+src/detour) на Scene.settings
└── diff.zig           # D6: сравнение D3-JSON (a vs b) + отчёт/exit-code
```

> `import_geom.zig` — **единая точка** загрузки геометрии; существующий
> `InputGeom.loadMesh` (`input_geom.zig:77`) становится одним из бэкендов
> (ветка `.obj`). Это держит «куда складывать verts/tris» в одном месте и не
> ломает текущий `.obj`-путь.

### 4.2 Точки интеграции

- **Импорт (D1).** Дропдаун входного меша и `scanDirectory` (`io_util.zig:64`,
  ныне один ext) — расширить на набор расширений; загрузка идёт через
  `io/import_geom.zig` вместо прямого `loadMesh`. Приёмник — `Scene.geom`
  (через переходную обёртку «активная сцена», фундамент 3.a).
- **Экспорт GUI (D2/D3/D4/D7).** Кнопки в панелях через **UI-shell 3.d**:
  `panel.zig` дескриптор / `tool_registry`. Экспорт-кнопки навмеша — в
  `Properties` рядом с Save/Load (`FEATURES.md:413`); экспорт запросов — в панели
  Tools при активном tester'е (`tool_registry` `ToolEntry`). **Не** правим
  монолитный `main.zig` напрямую — регистрируемся через shell (риск R5 фундамента).
- **CLI (D5/D6).** Расширить существующий парс аргументов в `main.zig`
  (где `--bench`/`--draw`/`--cam`, `FEATURES.md:427`): при подкоманде
  `build`/`diff` → ветка `cli/cli.zig` (headless, без создания окна/GL),
  иначе текущий GUI-путь. Нужна точка «до инициализации dvui/glfw».
- **Метрики/diff (D3/D6).** Источник чисел — обход `dt.NavMesh.tiles`
  (как `navmesh_io.zig:31`/`48`) + `Scene.settings` (единая копия, 3.a Q6).
- **Persist-граница (явно).** Durable save/load **сцены** = Persist (3.b
  `scene_io`/`tile_store`/`manifest`/`packArchive`). D вызывает Persist для
  `--scene`-загрузки (D5) и для опц. эталона в `.recastscene` (D6), но **сам**
  durable-форматов не вводит. MSET остаётся в `navmesh_io.zig` (не дублируем).

### 4.3 Конвенции типов

- Парсеры/эмиттеры — demo-уровень: можно usize/owned-буферы, `Managed`-списки
  (как `InputGeom`). На границе с faithful-ядром (`i32`-поля `PolyMesh`/навмеша) —
  касты `@intCast` норма (CLAUDE.md). Read-only обход ядра — без мутаций.
- JSON/CSV — детерминированный порядок полей (требование D6-diff).

---

## 5. Открытые вопросы / допущения к владельцу

> Явно — НЕ угадываю. Помечены допущения, на которых построен спек.

- **Q1 — Ось/масштаб импорта.** glTF канонически Y-up правосторонний; STL/PLY
  оси произвольны (часто Z-up из CAD). Делаем ли авто-конверсию осей или грузим
  «как есть» (developer сам выравнивает)? *Допущение:* грузим как есть (Y-up,
  как recast/`.obj`); glTF node-трансформы применяем, глобальную смену осей —
  нет. Опц. флаг `--up=y|z` — отдельный вопрос.
- **Q2 — Зависимость на glTF-парсер.** Писать минимальный свой (узкий путь:
  JSON через `std.json` + accessors) или тянуть Zig-библиотеку (zgltf и т.п.,
  лицензия/0.16-совместимость)? *Допущение:* свой минимальный (`std.json` +
  ручной разбор буферов/accessors) — узкий контролируемый путь, без внешней зав-ти.
  Подтвердить.
- **Q3 — Headless-builder: отдельный или общий с сэмплами?** Build-логика сейчас
  в сэмплах (`sample_solo.zig` и т.д.) и может быть сцеплена с GL/состоянием
  демо. Выносим общий безоконный конвейер (риск дублирования числовой логики ⇒
  расхождение GUI vs headless) или рефакторим сэмплы так, чтобы build-путь
  вызывался без GL? *Допущение:* на старте — самостоятельный headless-builder
  поверх `src/recast`+`src/detour` с **теми же** `CommonSettings`; долгосрочно —
  общий extracted build-путь. Решение влияет на риск R3.
- **Q4 — Формат метрик (D3) — наша схема или совместимость с upstream?** Делаем
  свою стабильную JSON-схему, или подгоняем под формат, который умеет
  выдавать форк upstream RecastDemo (для D6 без конвертера)? *Допущение:* своя
  схема + конвертер upstream→наша в `diff.zig`. Зависит от Q6.
- **Q5 — D4: текущий результат или батч?** Экспорт запросов — только текущий
  результат активного tester'а, или батч всех Test Cases? *Допущение:* оба, но
  P0 — текущий результат; батч — поверх `testcase.zig`.
- **Q6 — Источник эталона для D6.** Откуда берём C++-эталон: (а) upstream-MSET
  `.bin` (грузим `navmesh_io.load`, канонизируем у нас), (б) JSON, который пишет
  модифицированный C++ RecastDemo, (в) что-то ещё? Есть ли у владельца уже
  собранный upstream, способный выдавать артефакт? *Допущение:* (а) MSET от
  upstream как первичный путь (формат портирован 1-в-1) + (б) как опция. **Это
  блокирует объём D6** — нужен ответ.
- **Q7 — Зависимость от готовности фундамента.** D5 (чистый headless) требует
  выноса `area_types`/`poly_flags` из module-global (фундамент 3.a, этап 5) и
  Persist (3.b) для `--scene`. На момент D они могут быть не готовы. Стартуем D
  с подмножества, не требующего этого (D1/D2/D3/D4 на geom-only + текущая
  «активная сцена»-обёртка), а полный headless-`--scene` — после фундамент-этапов
  4–5? *Допущение:* да, поэтапно (см. §7).

---

## 6. Риски

- **R-D1 — Дублирование build-логики (GUI vs headless).** Отдельный
  headless-builder может разойтись с сэмпловым по числам → метрики/diff врут.
  *Митигация:* единый `CommonSettings`-вход; интеграционный тест «GUI-сборка и
  headless-сборка на одном geom дают одинаковые метрики D3» (`test/integration/`).
  Долгосрочно — extracted общий build-путь (Q3).
- **R-D2 — glTF-сложность.** Полный glTF огромен; даже узкий путь (accessors,
  компонентные типы, byteStride, base64/glb-chunks, node-иерархия) нетривиален.
  *Митигация:* строго ограничить (TRIANGLES + POSITION[+indices], без
  sparse/Draco/extensions), явные ошибки на неподдержанное, тесты на эталонных
  glb из спеки glTF-Sample-Models.
- **R-D3 — Несовпадение порядка/индексации в D6.** Между Zig и C++ порядок
  полигонов/вершин навмеша может отличаться при идентичной геометрии → ложный
  structural-diff. *Митигация:* стадия 1 (метрики, порядко-независимые) первична;
  structural-diff (стадия 2) — с канонизацией/сортировкой, YAGNI до потребности.
  Использовать identity-gate подход из skill `recast-benchmarking`.
- **R-D4 — eps/допуски в diff.** Слишком строгий eps → шумные провалы CI; слишком
  слабый → пропуск регрессий. *Митигация:* раздельные допуски (точные счётчики vs
  eps-float), конфигурируемый `--eps`, документировать дефолты.
- **R-D5 — PLY/STL endian/варианты.** PLY имеет BE-бинарь и переменные property-
  типы; STL — ASCII vs binary с неоднозначным детектом (header-эвристика).
  *Митигация:* поддержать ascii+LE/BE для PLY, детект STL по размеру/`solid`-
  префиксу с фолбэком; тесты на оба варианта.
- **R-D6 — Persist не готов к началу D.** `--scene`-вход (D5) и `.recastscene`-
  эталон (D6) зависят от 3.b. *Митигация:* поэтапность (§7): geom-only фичи D
  не блокируются Persist'ом; `--scene` включаем после фундамент-этапа 4.
- **R-D7 — Раздувание `main.zig` парсом CLI.** *Митигация:* весь парс подкоманд —
  в `cli/cli.zig`; `main.zig` только маршрутизирует (GUI vs CLI) до init dvui.
- **R-D8 — Утечка module-global в headless.** Пока `area_types`/`poly_flags`
  глобальны (3.a Q2), два headless-инстанса/CI-параллелизм конфликтуют.
  *Митигация:* до фундамент-этапа 5 — один инстанс на процесс; полный
  параллельный headless — после выноса в Scene-поля.

---

## 7. Этапы реализации (порядок)

Порядок: сначала фичи, не зависящие от ещё-не-готового фундамента (geom-only),
затем — после фундамент-этапов 4 (Persist) и 5 (вынос module-global).

1. **D1 импорт (P0, geom-only).** `io/import_geom.zig` диспетч + `import_stl.zig`
   + `import_ply.zig`; `loadMesh` → бэкенд `.obj`. Расширить `scanDirectory`/
   дропдаун. Тесты на эталонных STL/PLY. *Не требует Persist.*
2. **D1 glTF (P0).** `io/import_gltf.zig` (узкий путь, Q2). Тесты на glb из
   glTF-Sample-Models. *Не требует Persist.*
3. **D3 метрики JSON (P0).** `io/export_metrics.zig` (схема v1, детерминир.
   порядок) поверх обхода `dt.NavMesh` + `Scene.settings`. Кнопка через U.
   *Базис для D5/D6.*
4. **D5 headless build (P0, geom-only).** `cli/cli.zig` + `cli/headless_build.zig`:
   `build --geom … --metrics …` без окна. Маршрутизация в `main.zig`.
   Интеграционный тест «GUI vs headless метрики совпадают» (риск R-D1).
   *`--scene` пока НЕ включаем (ждёт Persist).*
5. **D2 экспорт навмеша (P1).** `io/export_obj.zig` + `io/export_gltf.zig`;
   кнопки + `--out-obj/--out-gltf` в headless.
6. **D4 экспорт запросов (P1).** `io/export_query.zig` (CSV+JSON), read-only
   геттер результата в tester'е; батч поверх `testcase.zig`.
7. **D6 diff (P1, стадия 1).** `cli/diff.zig`: метрики-diff двух D3-JSON +
   exit-code. Канонизация upstream-MSET → метрики (после ответа Q6).
   Синергия со skill `recast-benchmarking`.
8. **Интеграция с Persist (после фундамент-этапа 4).** `--scene
   world.recastscene` в D5; `.recastscene`-эталон в D6. Через Persist 3.b API.
9. **Полный headless/параллелизм (после фундамент-этапа 5).** Снять
   ограничение «один инстанс на процесс» (вынос module-global, риск R-D8).
10. **D7 SVG (P2).** `io/export_svg.zig` + `--out-svg`; цвета из R `color_scheme`
    (3.c) при наличии. D6 стадия 2 (structural-diff) — только при подтверждённой
    потребности (YAGNI, риск R-D3).

Критический путь ценности: **D1 → D3 → D5 → D6(стадия 1)** (вход → числа →
headless → валидация против upstream — прямая цель проекта).
