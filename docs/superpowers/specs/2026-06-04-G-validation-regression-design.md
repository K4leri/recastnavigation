# Спек кластера G: «Корректность / валидация / регрессии»

> **Статус:** дизайн-документ (НЕ реализация, НЕ код). Кластерный спек поверх
> [спека-фундамента](2026-06-04-00-foundation-design.md).
> **Дата:** 2026-06-04. **Версия Zig:** 0.16.0. **Проект:** `zig-recast`.
> **Область:** `demo/src/*` (GUI + CLI-проверки), опора на `src/*` (faithful-ядро,
> НЕ меняем) и на подсистемы фундамента **Sc**(3.a) / **P**(3.b) / **R**(3.c) /
> **U**(3.d).
>
> **Этот спек НЕ переопределяет подсистемы фундамента.** Он их *потребляет*:
> золотые снимки идут через Persist (3.b), выделение нарушений — через
> Render/overlay (3.c), регистрация инструмента/панели — через UI-shell (3.d),
> данные сцены — через Scene (3.a). Карта зависимостей кластера G в фундаменте:
> §4, строка `G | ● | ●● | ● | ●` (Persist — фундаментальная зависимость).

## Оглавление

1. [Цель и ценность для developer-user](#1-цель-и-ценность-для-developer-user)
2. [Scope (in / out / YAGNI)](#2-scope-in--out--yagni)
3. [Фичи (приоритезированы)](#3-фичи-приоритезированы)
   - [G1. Линтер навмеша (статические инварианты)](#g1-линтер-навмеша-статические-инварианты)
   - [G2. Рантайм-инварианты связности/ссылок (verify)](#g2-рантайм-инварианты-связностиссылок-verify)
   - [G3. Golden-тесты сцены/навмеша (регрессии в CI)](#g3-golden-тесты-сценынавмеша-регрессии-в-ci)
   - [G4. Линтер сцены (pre-build: volumes/offmesh/areas)](#g4-линтер-сцены-pre-build-volumesoffmeshareas)
   - [G5. Property-based фаззинг параметров build](#g5-property-based-фаззинг-параметров-build)
4. [Архитектура](#4-архитектура)
5. [Открытые вопросы / допущения к владельцу](#5-открытые-вопросы--допущения-к-владельцу)
6. [Риски](#6-риски)
7. [Этапы реализации (порядок)](#7-этапы-реализации-порядок)

---

## 1. Цель и ценность для developer-user

Сейчас «корректность» навмеша держится на (а) faithful-сверке с upstream C++ и
(б) точечных регрессионных интеграционных тестах — `test/integration/`:
`removetile_link_leak_test.zig` (утечка порталов через freelist),
`tilecache_navmesh_test.zig` (4 бага bake-пути), `detail_conformance_test.zig`,
`recast_pipeline_test.zig`. Это ловит *уже найденные* баги ядра. Чего нет:

- **Линтера результата сборки** — изолированные островки, off-mesh «в никуда»,
  нулевые/вырожденные регионы, мусорные area/flags. Developer-user видит «странный»
  навмеш только глазами в debug-draw, без машинной диагностики.
- **Машинной проверки рантайм-инвариантов** — целостность freelist-пула линков,
  симметрия порталов, валидность всех `PolyRef`, согласованность off-mesh
  endpoint-полигонов. Сейчас это размазано по ad-hoc тестам (см. `countFreeLinks`
  / `linksToTile` в `removetile_link_leak_test.zig:28-51` — отличные кирпичи, но
  не вынесены в переиспользуемый verifier).
- **Golden-регрессий на уровне сцены/навмеша** — «эталонный навмеш на тестовой
  сцене», ловящий *неожиданную* регрессию (а не только known-bug). Сейчас
  эталона целого навмеша нет; `dump_roundtrip_test.zig` проверяет лишь roundtrip.
- **Фаззинга параметров build** — конвейер падает/виснет/выдаёт мусор на
  экстремальных комбинациях `CommonSettings` (cs→0, radius≫tile, slope=90, и т.д.)
  без систематической проверки.

**Ценность.** Developer-user получает: (1) красную/жёлтую диагностику «что не так
с этим навмешем» прямо в GUI, с выделением нарушений на сцене (через R.highlight);
(2) `recast_demo --lint scene.recastscene` / `--verify` для CI и headless;
(3) golden-снимок как защиту от регрессий при правках ядра/фундамента; (4)
фаззер, который ловит краши/паники конвейера до пользователя. Это превращает
«faithful-порт, который вроде работает» в «порт с воспроизводимыми гарантиями
корректности».

---

## 2. Scope (in / out / YAGNI)

### Входит (in)

- **Линтер навмеша** (`demo/src/validate/navmesh_lint.zig`): набор правил поверх
  собранного `dt.NavMesh` — изолированные компоненты связности, off-mesh без
  валидного endpoint-полигона, вырожденные/нулевые регионы и area, дубль-вершины
  полигонов. Чистый read-only обход тайлов/линков.
- **Линтер сцены** (`demo/src/validate/scene_lint.zig`): pre-build проверки
  `Scene` (3.a) — самопересечение/невыпуклость convex volume, off-mesh-точки вне
  навигируемой геометрии, area-id вне реестра, нулевая площадь volume.
- **Рантайм-verifier** (`demo/src/validate/navmesh_verify.zig`): инварианты
  структуры — freelist-целостность пула линков, симметрия порталов (A→B ⇒ B→A),
  валидность всех `PolyRef` в линках, off-mesh endpoint-консистентность.
  Обобщает кирпичи из `removetile_link_leak_test.zig`.
- **Golden-тесты** (`test/integration/regression/golden_navmesh_test.zig` +
  фикстуры): эталонный детерминированный снимок навмеша на фиксированной сцене,
  сравнение в CI; обновление эталона по флагу `--update-golden`.
- **Property-based фаззер** (`demo/src/validate/build_fuzz.zig` + headless
  раннер): генерация валидных-по-схеме `CommonSettings`, прогон конвейера,
  проверка «не паникует / возвращает корректный Status / проходит verifier».
- **GUI-панель «Validation»** (через U-shell 3.d): запуск линтера/verifier,
  список нарушений, клик→выделение нарушения на сцене (через R 3.c).
- **CLI-режимы** `--lint`, `--verify`, `--fuzz-build`, `--update-golden`
  (расширение разбора аргументов `main.zig`, см. FEATURES §10).

### Не входит (out / YAGNI)

- **Изменение faithful-ядра `src/*`.** Вся логика — demo-уровень read-only поверх
  ядра. Если линтер обнаружит, что инвариант нарушает само ядро — это баг ядра,
  заводится отдельно (issue + регрессионный тест), но G его не «чинит».
- **Полноценный SMT/символьный верификатор** конвейера. Фаззер — property-based
  (рандом + shrink), не формальное доказательство.
- **Кросс-валидация «Zig vs C++ recastnavigation» байт-в-байт.** Это отдельная
  задача (recast-benchmarking identity-gate, см. skill). G сравнивает Zig-навмеш
  с *Zig-эталоном* (golden), не с C++.
- **Авто-исправление нарушений** (auto-repair/auto-prune). G — *диагностика*;
  правки — кластер F. G может предложить «запустить Prune» как подсказку, но не
  мутирует сцену сам (кроме явного пользовательского действия в кластере F).
- **Перф-регрессии** (время сборки/память) — это кластер C (профилирование).
  G ловит регрессии *корректности*, не скорости.
- **Фаззинг произвольной геометрии** (рандомные меши). Стартуем с фаззинга
  *параметров* на фиксированном наборе мешей. Геометрический фаззинг — YAGNI до
  потребности.
- **Networked/distributed golden-хранилище.** Эталоны — файлы в репозитории
  (`test_data/golden/`), под git-LFS если крупные.

---

## 3. Фичи (приоритезированы)

Приоритет: **G1 ≈ G2 > G3 > G4 > G5**. G1/G2 дают немедленную диагностическую
ценность и опираются на уже-готовое ядро (не ждут фундамент целиком). G3 требует
Persist (3.b) для снимка. G4 требует Scene (3.a). G5 — последним (нужны
стабильные G1/G2 как оракул «не сломалось»).

---

### G1. Линтер навмеша (статические инварианты)

**Что.** Read-only обход собранного `dt.NavMesh`, выдающий список «находок»
(`Finding{ severity, rule, refs[], message }`). Правила:

| ID | Правило | Severity | Как детектится |
|---|---|:--:|---|
| `LINT_ISLANDS` | Изолированные островки (компоненты связности, недостижимые от «основной» массы) | warn | flood-fill по линкам (обобщение `floodNavmesh`, `tool_prune.zig:86-120`), подсчёт компонент; компоненты с долей полигонов < порога → находка |
| `LINT_OFFMESH_DANGLING` | Off-mesh-связь «в никуда»: endpoint не привязался к полигону | error | `getOffMeshConnectionByRef` (`navmesh.zig:701`) + проверка, что оба конца off-mesh-поли реально слинкованы с land-поли (есть Link с `edge` off-mesh) |
| `LINT_NULL_REGION` | Полигоны с area==0 (RC_NULL_AREA), просочившиеся в навмеш | warn | обход `poly.getArea()` по тайлам |
| `LINT_DEGENERATE_POLY` | Дубль-вершины / нулевая площадь полигона | warn | проверка vert-индексов поли на дубли + знаковая площадь по проекции XZ |
| `LINT_ORPHAN_TILE` | Тайл с polygons, но без единого внешнего портала (при multi-tile) | info | подсчёт ext-линков тайла (`linksToTile`-паттерн, `removetile_link_leak_test.zig:38`) |

**Зачем.** «Почему агент не доходит / off-mesh не сработал / area не покрасилась»
— переводится из «смотри глазами в debug-draw» в машинный отчёт. `LINT_ISLANDS`
особенно ценен: prune-инструмент уже умеет flood-fill, но не *сообщает* о
проблеме автоматически.

**UX.** Панель «Validation» (U-shell): кнопка **Lint NavMesh** → список находок,
группированных по severity (error/warn/info), с цветовыми бэйджами. Клик по
находке → камера к нарушению + выделение `refs[]` через **R.highlight**
(`debugDrawNavMeshPoly`, foundation 3.c). Off-mesh-находки рисуют проблемный
коннектор красным. CLI: `recast_demo --lint <scene>` печатает находки в stdout,
exit-code = число error-находок (для CI).

**Данные.** Вход: `*const dt.NavMesh` (из активного сэмпла). Выход:
`[]Finding` (owned). Никакой мутации навмеша. Компоненты связности — временный
`NavmeshFlags`-подобный per-tile буфер (как `tool_prune.zig:30-82`).

**Зависимости.**
- Ядро `src/detour/navmesh.zig`: `decodePolyId` (353), `getTileAndPolyByRefUnsafe`
  (661), `getOffMeshConnectionByRef` (701), `getPolyRefBase`, `MeshTile.links`,
  `Poly.first_link`, `NULL_LINK`.
- **R (3.c):** `highlight.zig` (выделение набора полигонов), `overlay.zig`
  (аннотация ref/правила над полигоном).
- **U (3.d):** регистрация панели через `panel.zig`.
- **Sc (3.a):** опционально — `AreaRegistry`/`FlagRegistry` для расшифровки
  area-id/flag-bit в имена в сообщениях (если фундамент готов; иначе — числа).

---

### G2. Рантайм-инварианты связности/ссылок (verify)

**Что.** Структурный verifier целостности `dt.NavMesh` (отличие от G1: G1 —
«семантика навмеша плохая», G2 — «структура данных битая/несогласованная»).
Инварианты:

| ID | Инвариант | Как |
|---|---|---|
| `VERIFY_FREELIST` | Сумма (allocated links + free links) == `header.max_link_count` на каждом тайле; freelist без циклов | `countFreeLinks`-обход (`removetile_link_leak_test.zig:28`) + подсчёт занятых через poly.first_link-цепочки |
| `VERIFY_LINK_REFS` | Каждый `link.ref` валиден (`isValidPolyRef`, `navmesh.zig:692`) или 0 | обход всех links всех тайлов |
| `VERIFY_PORTAL_SYMMETRY` | Если поли A слинкован с B через портал, у B есть обратный линк на A | двусторонний обход ext-линков соседних тайлов |
| `VERIFY_OFFMESH_ENDPOINTS` | У каждого off-mesh-поли ровно те линки, что описаны в `OffMeshConnection`; salt/tile в ref совпадают | `getOffMeshConnectionByRef` + сверка |
| `VERIFY_SALT` | Все живые ref-ы имеют salt текущего тайла (нет stale-ref после remove/add) | `decodePolyId().salt == tile.salt` |

**Зачем.** Эти инварианты — то, что *тихо* ломалось в реальных багах (см.
шапку `removetile_link_leak_test.zig`: leak порталов; `tilecache_navmesh_test.zig`:
0xff-memset). Verifier ловит такой класс регрессий *на любом* навмеше, а не
только на двух фикстурах. Идеален как post-condition после tilecache-update /
removeTile / addTile.

**UX.** Кнопка **Verify Integrity** в панели Validation; «зелёный чек» или список
нарушенных инвариантов с tile/poly/link-индексами. CLI: `--verify <scene>`,
exit-code ≠ 0 при любом нарушении (для CI-гейта). Опция «verify after every
tilecache update» (чекбокс) — для отлова рантайм-деградации в Temp Obstacles
(see FEATURES §2 «tilecache обновляется покадрово»).

**Данные.** Вход `*const dt.NavMesh`. Выход `[]Invariant Violation`. Read-only.
Кирпичи `countFreeLinks`/`linksToTile` **выносятся из теста** в
`navmesh_verify.zig` и переиспользуются и тестом, и GUI, и CLI (устраняет
дублирование).

**Зависимости.**
- Ядро: `navmesh.zig` `isValidPolyRef` (692), `decodePolyId` (353),
  `getTileAndPolyByRefUnsafe` (661), `getOffMeshConnectionByRef` (701),
  `MeshTile{links, links_free_list, salt, header}`, `Link{ref, next, edge}`,
  `NULL_LINK` (`detour/common.zig`).
- **U (3.d):** панель.
- **R (3.c):** highlight нарушенного линка/поли (опционально).
- НЕ зависит от Persist — работает на in-memory навмеше.

---

### G3. Golden-тесты сцены/навмеша (регрессии в CI)

**Что.** Детерминированный эталон («golden») собранного навмеша на фиксированной
тестовой сцене. Тест: загрузить сцену → собрать навмеш с фиксированными
`CommonSettings` → сериализовать снимок → сравнить с эталоном
(`test_data/golden/<name>.golden`). Несовпадение = регрессия (fail в CI).
Обновление эталона — `--update-golden` (осознанное действие, не авто).

**Снимок (что именно сравниваем).** НЕ сырой MSET-байт-дамп (хрупок к
несемантическим перестановкам, allocator-зависим). Вместо — **канонический
семантический дайджест**:
- per-tile: `poly_count`, `vert_count`, отсортированные area-гистограммы,
  bounds (квантованные);
- глобально: число компонент связности (из G1), число off-mesh, суммарное
  число линков, XXH3-хэш канонизированного потока (verts квантованы, polys
  с отсортированными соседями).

Это устойчиво к незначимым различиям, но ловит реальные изменения топологии.
Хэш — **XXH3** (тот же, что Persist 3.b использует для checksum — переиспользуем
`persist/checksum.zig`).

**Зачем.** Ловит *неожиданную* регрессию при рефакторинге ядра/фундамента:
«я поправил region-merge, и навмеш на dungeon.obj изменился» — golden краснеет
сразу в CI, до релиза. G1/G2 проверяют инварианты (что-то «плохо»); G3 проверяет
*стабильность* (что-то «изменилось»).

**UX.** Преимущественно CI/headless (`zig build test`). GUI-обвязки минимум:
кнопка **Snapshot → clipboard/file** (для ручного создания эталона) опциональна.
CLI: `recast_demo --update-golden <scene>` пересоздаёт эталон.

**Данные.** Эталоны — файлы `test_data/golden/*.golden` (бинарь с
magic/version/XXH3, формат как edits-реестры Persist 3.b). Фикстуры-сцены —
существующие `.obj` из `test_data` (напр. `nav_test.obj`, `dungeon.obj`) +
зафиксированные настройки в коде теста.

**Зависимости.**
- **P (3.b):** `persist/checksum.zig` (XXH3), формат chunk-header (magic/version/
  checksum) для `.golden`-файла; опционально `scene_io` для загрузки сцены-фикстуры
  (иначе — прямая загрузка `.obj` как в существующих тестах
  `real_mesh_test.zig`).
- Ядро: весь recast-конвейер (rasterize→…→createNavMeshData), как в
  `recast_pipeline_test.zig` / `removetile_link_leak_test.zig:57` (`buildFlatTile`).
- **G1/G2** как часть дайджеста (число компонент / линков).
- **Блокер:** требует Persist-checksum (этап 4 фундамента) ИЛИ временный CRC32/
  std.hash до его готовности (см. открытый вопрос Q3).

---

### G4. Линтер сцены (pre-build: volumes/offmesh/areas)

**Что.** Проверки **до** сборки, на уровне `Scene` (3.a) — ловят ошибки разметки
раньше, чем они испортят навмеш:

| ID | Правило | Severity |
|---|---|:--:|
| `SCENE_VOLUME_SELFINT` | Самопересечение контура convex volume (рёбра пересекаются) | error |
| `SCENE_VOLUME_NONCONVEX` | Контур не выпуклый (знак векторного произведения меняется) | warn |
| `SCENE_VOLUME_ZEROAREA` | Нулевая/околонулевая площадь полигона volume, или hmin≥hmax | error |
| `SCENE_OFFMESH_OFFGEOM` | Off-mesh endpoint висит вне досягаемости геометрии (XZ-проекция не над мешем / далеко от любого полигона по высоте) | warn |
| `SCENE_AREA_UNKNOWN` | volume/offmesh ссылается на area-id вне `AreaRegistry` | error |
| `SCENE_FLAG_UNKNOWN` | offmesh/area ссылается на flag-bit вне `FlagRegistry` | warn |

**Зачем.** Convex-инструмент строит оболочку gift-wrapping (FEATURES §4.4), но
пользователь может натыкать точки, дающие вырожденный/самопересекающийся контур;
off-mesh легко поставить «в воздух». Линтер сцены ловит это до Build, экономя
цикл пересборки и объясняя «почему зона/прыжок не сработали».

**UX.** Авто-прогон при изменении сцены (debounced) ИЛИ кнопка **Lint Scene**;
находки рисуются прямо на проблемном volume/offmesh (R.highlight по геометрии,
не по навмешу). Интеграция с auto-rebuild-уведомлением (FEATURES §3): рядом с
`! Navmesh rebuild needed` — `! N scene issues`.

**Данные.** Вход — `*const Scene` (геометрия + volumes + offmesh + реестры).
Read-only. Геометрические проверки (self-intersection, convexity, area) —
2D на XZ-проекции контура.

**Зависимости.**
- **Sc (3.a) — фундаментальна.** Нужны `Scene.geom` (verts/tris/bounds),
  `volumes` (контуры), off-mesh view-геттер `offMesh(i)` (foundation 3.a
  обещает его взамен 6 параллельных массивов), `AreaRegistry`/`FlagRegistry`.
  **Блокер:** до выноса area/flags из module-global (3.a-рефактор) проверки
  area/flag используют переходные module-обёртки (foundation Q2).
- **R (3.c):** highlight геометрии volume/offmesh.
- **U (3.d):** панель.
- Ядро: `input_geom.zig` (для XZ-over-mesh теста — raycast/point-in-mesh,
  Möller–Trumbore уже есть в demo, FEATURES §4).

---

### G5. Property-based фаззинг параметров build

**Что.** Генератор валидных-по-схеме `CommonSettings` (cs/ch/height/radius/climb/
slope/region-sizes/edge-len/error/nvp/detail-dist/error) + tile-size, прогон
полного конвейера на фиксированном наборе мешей, проверка свойств:

- **P-NOPANIC:** конвейер не паникует и не зацикливается (timeout-guard).
- **P-STATUS:** возвращает корректный `Status` (success ИЛИ явная ошибка, не
  «success с мусором»).
- **P-VERIFY:** при success — навмеш проходит G2-verifier (структура цела).
- **P-LINT-SANE:** при success — нет error-находок G1 «catastrophic» класса
  (напр. все полигоны изолированы при заведомо связной геометрии).

При нарушении — **shrink** параметров к минимальному воспроизводящему набору +
печать seed для детерминированного повтора.

**Зачем.** Конвейер имеет много числовых краёв (cs→0 ⇒ гигантская сетка;
radius≫tile ⇒ эрозия съедает всё; slope=90 ⇒ всё walkable; min_region>area).
Фаззер систематически находит краш/панику/hang до пользователя — то, что
faithful-сверка с C++ не гарантирует (C++ тоже может падать на этих краях).

**UX.** В основном headless: `recast_demo --fuzz-build [--seed N] [--iters K]`,
печать «K iters, M failures, seeds: …». GUI — опциональная кнопка «Fuzz (100
iters)» с прогресс-баром (не приоритет). Найденные seed-краши → кандидаты в
регрессионные тесты `test/integration/regression/`.

**Данные.** Вход: набор мешей-фикстур + диапазоны параметров (из UI-слайдеров,
FEATURES §3 — те же min/max). Выход: отчёт + список (seed, settings, симптом).
Детерминизм через `std.Random.DefaultPrng` с явным seed.

**Зависимости.**
- Ядро: весь recast-конвейер.
- **G1 + G2** как оракулы свойств (P-VERIFY/P-LINT) — **поэтому G5 после них.**
- **Sc (3.a):** `CommonSettings` как единая структура параметров (foundation Q6).
- НЕ требует R/U (headless-first). НЕ требует Persist.

---

## 4. Архитектура

### Новые файлы (по `.agent/project_structure.md`)

**Demo-уровень — логика валидации (стабильная → `demo/src/`, не `dev/`, т.к.
это продуктовая фича GUI):**

```
demo/src/validate/
├── finding.zig         # Finding{ severity:enum{error,warn,info}, rule:enum, refs:[]PolyRef,
│                       #   geom_refs:[]u32, message:[]const u8 }; общий тип для G1/G2/G4.
│                       #   Severity-агрегатор, форматтер для stdout/панели.
├── navmesh_lint.zig    # G1: lintNavMesh(*const dt.NavMesh, alloc) ![]Finding.
│                       #   Внутри: connectedComponents() (обобщённый floodNavmesh),
│                       #   правила LINT_*. Read-only.
├── navmesh_verify.zig  # G2: verifyNavMesh(*const dt.NavMesh, alloc) ![]Violation.
│                       #   ВЫНОС countFreeLinks/linksToTile из removetile_link_leak_test.zig
│                       #   в pub-функции; инварианты VERIFY_*.
├── scene_lint.zig      # G4: lintScene(*const Scene, alloc) ![]Finding.
│                       #   Геом-предикаты: polyIsConvex/polySelfIntersects/polyArea2D (XZ).
├── build_fuzz.zig      # G5: генератор CommonSettings, прогон, shrink, репорт.
│                       #   Оракулы = navmesh_verify + navmesh_lint.
└── digest.zig          # G3: canonicalDigest(*const dt.NavMesh, alloc) -> NavMeshDigest;
                        #   сериализация/сравнение через persist/checksum (XXH3).
```

**GUI-обвязка (через U-shell 3.d — НЕ правим монолит main.zig напрямую):**

```
demo/src/shell/        # (создаётся фундаментом 3.d; G лишь регистрируется)
  └── (G добавляет PanelDesc "Validation" через panel.zig + tool_registry при нужде)
```

Панель «Validation» — это `PanelDesc{ title:"Validation", visible:*bool, draw_fn }`
по конвенции foundation 3.d (`main.zig` floatingWindow-паттерн). `draw_fn` рисует
кнопки Lint/Verify/Lint Scene + scroll-список Finding'ов; клик → callback в
R.highlight. Гейты ввода — через `input_gate.zig` (foundation 3.d).

**CLI (расширение `main.zig` arg-разбора, FEATURES §10):**

```
--lint <scene>          -> validate.navmesh_lint, печать, exit=error-count
--verify <scene>        -> validate.navmesh_verify, exit≠0 при violation
--lint-scene <scene>    -> validate.scene_lint
--fuzz-build [opts]     -> validate.build_fuzz (headless)
--update-golden <scene> -> regenerate test_data/golden/*.golden
```

CLI-режимы для `--lint`/`--verify`/`--fuzz` работают **headless** (без GUI-цикла)
— требуют, чтобы Scene/конвейер не зависели от module-global UI-состояния. Это
совпадает с требованием кластера H (foundation §4: «H требует обязательного
выноса area_types/poly_flags из module-global»). До завершения 3.a-рефактора
(этап 5 фундамента) headless-CLI работает через переходные обёртки на «активную
сцену» (foundation Q2) — допустимо для одиночного процесса.

**Тесты (по `.agent/project_structure.md` §test/):**

```
test/integration/regression/
├── golden_navmesh_test.zig    # G3: эталон на фикс-сцене, сравнение дайджеста.
├── navmesh_verify_test.zig    # G2: verifier на заведомо валидном/битом навмеше
│                              #   (битый строится через прямую порчу link.ref/freelist).
└── scene_lint_test.zig        # G4: volume self-intersection/convexity unit-кейсы.
test/integration/all.zig       # добавить @import новых тестов.
```

Существующие `removetile_link_leak_test.zig` / `tilecache_navmesh_test.zig`
**рефакторятся** на переиспользование `navmesh_verify.zig` (тест зовёт публичный
`verifyNavMesh` вместо локальных `countFreeLinks`), устраняя дублирование. Это
снижает риск расхождения «тест проверяет одно, GUI — другое».

### Точки интеграции

- **Render (3.c):** G1/G2 выделяют полигоны-нарушители через `render/highlight.zig`
  (`debugDrawNavMeshPoly`, `detour_debug.zig:117`); G4 — геометрию volume/offmesh.
  Severity → цвет из палитры (`debug_draw.zig` `rgba`/`transCol`). Легенда правил
  через `render/legend.zig`.
- **Persist (3.b):** G3 переиспользует `persist/checksum.zig` (XXH3) и формат
  chunk-header (magic/version/checksum) для `.golden`. Загрузка сцены-фикстуры —
  через `persist/scene_io` (когда готов) или прямой `.obj` до того.
- **Scene (3.a):** G4 целиком на `Scene`; G1/G2 опционально читают
  `AreaRegistry`/`FlagRegistry` для человекочитаемых имён в сообщениях; G5 — на
  `Scene.settings`.
- **UI-shell (3.d):** панель Validation + CLI-флаги; гейты ввода.

**Faithful-ядро `src/*` — НЕ трогаем.** Все verify/lint — read-only обходы через
существующие публичные геттеры (`getTileAndPolyByRefUnsafe`, `decodePolyId`,
`isValidPolyRef`, `getOffMeshConnectionByRef`). Если какой-то инвариант требует
поля без публичного геттера — добавляем **геттер** (usize-конвенция CLAUDE.md),
не меняем логику.

---

## 5. Открытые вопросы / допущения к владельцу

> Не угадываю — выношу явно.

1. **Q1 — Что считать «островком» (LINT_ISLANDS)?** Любой компонент связности,
   не являющийся крупнейшим? Или порог по доле полигонов (напр. <1% → находка)?
   Или достижимость от заданной точки/тайла (как Prune)? *Допущение:* крупнейший
   компонент = «основной», прочие = находки `warn`; порог настраиваемый (default
   1 поли — сообщать о любом отдельном островке).

2. **Q2 — Семантика golden-дайджеста (G3): насколько строгий?** Полный
   квантованный хэш геометрии (ловит любое смещение вершины) vs только
   топологический инвариант (counts/компоненты/area-гистограмма, игнор координат)?
   Строгий ловит больше, но краснеет на любой допустимой не-детерминированности
   (порядок аллокаций, float-ассоциативность). *Допущение:* **топологический +
   квантованные bounds** (устойчив, ловит реальные регрессии); полный
   координатный хэш — опциональный «strict»-режим.

3. **Q3 — XXH3 для G3: ждать Persist-этап-4 или временный хэш?** G3 зависит от
   `persist/checksum.zig`, который по плану фундамента приходит на этапе 4. Если
   G стартует раньше — использовать `std.hash.XxHash3`/`Wyhash` из stdlib как
   времянку с миграцией на общий `checksum.zig` потом? *Допущение:* временно
   `std.hash` из stdlib, мигрировать на `persist/checksum.zig` когда готов
   (формат `.golden` сразу с magic/version, чтобы миграция = bump version).

4. **Q4 — Детерминизм конвейера для golden (G3).** Гарантирован ли *байт-в-байт*
   детерминированный навмеш при фиксированных входах+настройках на одной
   платформе? Если в ядре есть зависимость от порядка обхода
   hash-map/allocator-адресов — golden будет флакать. *Нужно подтвердить
   эмпирически* (прогнать сборку N раз, сверить дайджест). *Допущение:* для
   фиксированной платформы детерминирован; если нет — дайджест огрубляется до
   стабильного подмножества (Q2).

5. **Q5 — Scope фаззера (G5): только параметры или и геометрия?** Я заложил
   только фаззинг `CommonSettings` на фикс-мешах (out: рандом-геометрия).
   Достаточно ли, или нужен генератор простых рандом-мешей (квады/рампы)?
   *Допущение:* только параметры в v1; геометрия — YAGNI до потребности.

6. **Q6 — Куда складывать crash-репро фаззера?** Авто-генерить
   `test/integration/regression/fuzz_<seed>_test.zig`, или копить seed'ы в
   `test_data/fuzz_corpus` и прогонять одним параметризованным тестом?
   *Допущение:* corpus-файл seed'ов + один раннер-тест (меньше файлов,
   детерминированный CI-прогон).

7. **Q7 — Зависимость от готовности фундамента: можно ли начать G1/G2 ДО
   Persist/Scene?** G1/G2 нужны только ядро + R(highlight) + U(панель). Стартовать
   ими, пока 3.a/3.b в работе, или ждать весь фундамент? *Допущение:* **G1/G2
   стартуют сразу** на готовом ядре; highlight/панель — через минимальный
   foundation 3.c/3.d (этапы 1+3); G3/G4/G5 ждут Persist/Scene.

8. **Q8 — Severity-политика для CI exit-code.** `--lint` exit = error-count;
   а warn-находки фейлят CI или нет? *Допущение:* CI-гейт = только `error`
   (+ любой G2-violation); `warn`/`info` информационные, не фейлят (иначе
   шумные островки заблокируют пайплайн).

---

## 6. Риски

- **G-R1 — Флаки golden (детерминизм ядра).** Если recast-конвейер
  недетерминирован между прогонами (allocator-порядок, float-ассоциативность),
  golden краснеет ложно. *Митигация:* топологический дайджест (Q2), эмпирическая
  проверка детерминизма (Q4) ДО внедрения G3, квантование координат.
- **G-R2 — Дрейф «тест vs GUI vs CLI».** Если verifier-логика дублируется (как
  сейчас в тесте), GUI и тест могут проверять разное. *Митигация:* единый
  `navmesh_verify.zig`, тесты рефакторятся на него (см. §4).
- **G-R3 — Ложные срабатывания линтера на валидном навмеше.** «Островок» может
  быть легитимным (изолированная платформа); off-mesh «в никуда» — намеренным.
  *Митигация:* severity warn (не error) для эвристик; настраиваемые пороги;
  возможность игнора правила.
- **G-R4 — Зависимость от ещё-не-готового фундамента.** G4 требует Scene-рефактор
  (module-global → инстанс), G3 — Persist-checksum. Старт G целиком до фундамента
  невозможен. *Митигация:* фазировка — G1/G2 на голом ядре (Q7), G3/G4/G5 после
  соответствующих этапов фундамента (4 и 2/5).
- **G-R5 — Фаззер ловит баги *ядра*, которые мы не чиним (out-of-scope).**
  P-NOPANIC упадёт на реальной панике recast — но G не правит `src/*`. *Митигация:*
  фаззер-находка = issue + регрессионный тест; фикс ядра — отдельный PR вне G
  (faithful-сверка с C++: воспроизводится ли там же).
- **G-R6 — Стоимость verify на больших навмешах в рантайме.** «Verify after every
  tilecache update» — O(links) каждый кадр. *Митигация:* off по умолчанию, только
  для отладки; быстрые инварианты (freelist/refs) дёшевы, дорогие (portal-symmetry)
  — по кнопке.
- **G-R7 — Хрупкость golden к легитимным изменениям ядра.** Каждый осознанный
  апгрейд алгоритма требует `--update-golden` + ревью diff'а. *Митигация:*
  процедура обновления документирована; diff дайджеста человекочитаем (counts),
  не сырой байт-дамп.

---

## 7. Этапы реализации (порядок)

Порядок повторяет приоритет §3 и уважает готовность фундамента (foundation §7:
U-shell→Scene→Render→Persist→…).

1. **G2 verifier-ядро (+ рефактор тестов).** `validate/finding.zig` +
   `validate/navmesh_verify.zig`: вынести `countFreeLinks`/`linksToTile` из
   `removetile_link_leak_test.zig` в публичные функции, реализовать VERIFY_*.
   Рефакторить существующие тесты на него. `navmesh_verify_test.zig`. **Зависит
   только от ядра** — можно начинать сразу, параллельно фундаменту. *Разблокирует:*
   оракул для G3/G5, CLI `--verify`.

2. **G1 linter-ядро.** `validate/navmesh_lint.zig`: `connectedComponents`
   (обобщить `floodNavmesh`), правила LINT_*. Зависит от ядра + (для GUI)
   foundation R.highlight (3.c) и U-панель (3.d). CLI `--lint` headless — сразу;
   GUI-выделение — когда готовы 3.c/3.d. *Разблокирует:* диагностику в GUI/CI.

3. **GUI-панель Validation.** Регистрация `PanelDesc` через foundation 3.d;
   кнопки Lint/Verify; список Finding'ов; клик→R.highlight (3.c). Требует
   foundation этапы 1 (U-shell) + 3 (Render). *Разблокирует:* developer-user UX.

4. **G3 golden-тесты.** `validate/digest.zig` + `golden_navmesh_test.zig` +
   фикстуры `test_data/golden/`. Сначала эмпирически проверить детерминизм (Q4).
   Хэш — времянка `std.hash` → миграция на `persist/checksum.zig` (foundation
   этап 4). `--update-golden`. *Разблокирует:* CI-защиту от регрессий.

5. **G4 scene-linter.** `validate/scene_lint.zig` + `scene_lint_test.zig`.
   **Требует foundation Scene (этап 2, частично 5 для area/flags-инстанса).**
   Геом-предикаты (convexity/self-int/area2D) автономны и тестируются юнитами
   сразу; интеграция со `Scene` — по готовности 3.a. *Разблокирует:* pre-build
   диагностику.

6. **G5 build-фаззер.** `validate/build_fuzz.zig` + corpus + раннер-тест. Требует
   стабильные G1+G2 (оракулы) и `Scene.settings` (foundation Q6). Headless CLI
   `--fuzz-build`. Найденные seed'ы → corpus + (по решению Q6) регрессии.
   *Разблокирует:* проактивный отлов краш-краёв конвейера.

**Критический путь:** G2 → G1 → (панель) → G3. G4/G5 подключаются по мере
готовности Scene/оракулов. G2 не блокируется фундаментом и стартует первым.
