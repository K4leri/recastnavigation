# Спек кластера A: «Диагностика запросов (why-no-path)»

> **Статус:** дизайн-документ (НЕ реализация, НЕ код). Кластерный спек поверх
> фундамента. **Дата:** 2026-06-04. **Версия Zig:** 0.16.0. **Проект:** `zig-recast`.
> **Область:** `demo/src/*` (GUI), опора на faithful-ядро `src/*` (без правок ядра).
>
> **Фундамент-зависимость:** этот спек **ссылается** на подсистемы фундамента
> (`docs/superpowers/specs/2026-06-04-00-foundation-design.md`), а не переопределяет их:
> Scene (3.a), Persist (3.b), Render/overlay (3.c: `highlight`/`overlay`/`isolation`/
> `color_scheme`/`legend`), UI-shell (3.d: `tool_registry`/`panel`/`input_gate`).
> По карте §4 фундамента кластер A: Sc=●, P=○, **R=●●**, U=●.

## Оглавление

1. [Цель + ценность для developer-user](#1-цель--ценность-для-developer-user)
2. [Scope (in / out / YAGNI)](#2-scope-in--out--yagni)
3. [Фичи (приоритезированы)](#3-фичи-приоритезированы)
4. [Архитектура](#4-архитектура)
5. [Открытые вопросы / допущения к владельцу](#5-открытые-вопросы--допущения-к-владельцу)
6. [Риски](#6-риски)
7. [Этапы реализации (порядок)](#7-этапы-реализации-порядок)

---

## 1. Цель + ценность для developer-user

Сейчас `tool_navmesh_tester.zig` показывает **результат** запроса (путь, polys,
waypoints) и счётчик `polys: N  waypoints: M`, но не **причину** результата.
Когда `findPath` возвращает `partial_result`, или путь не находится вовсе, или
сглаживание обрывается — developer-user видит «пусто/обрезано» и вынужден
гадать: не та компонента связности? отфильтровано по флагам? стоимость отрезала
ветку? упёрлись в лимит узлов? Сейчас единственный диагностический канал —
`std.debug.print` инспекции полигона (`main.zig:480-491`) и неструктурированные
строки статуса.

Ядро `src/detour/query.zig` уже отдаёт **богатую** диагностику, которая в демо
сейчас выбрасывается:

- A*-внутренности доступны через `NodePool` (`query.zig:191`): узлы с флагами
  `open`/`closed` (`NodeFlags`, `query.zig:154`), `cost`/`total` (g и f),
  `pidx` (родитель), `pos`. Геттеры `getNodePool()` (`query.zig:567`),
  `isInClosedList()` (`query.zig:584`), `getNodeCount()` (`query.zig:321`).
- Sliced-API уже **пошаговый**: `initSlicedFindPath`/`updateSlicedFindPath(max_iter,
  done_iters)`/`finalizeSlicedFindPath` (`query.zig:3028/3101/3296`) —
  `updateSlicedFindPath` принимает `max_iter` и пишет фактически выполненные
  итерации в `done_iters`. Это **готовый движок проигрывания A* по шагам**.
- `Status` (`common.zig:21`) различает `partial_result`, `out_of_nodes`,
  `invalid_param`, `buffer_too_small`, `in_progress` — точные коды «почему».
- `QueryFilter.passFilter` (`query.zig:35`) и `getCost`/`area_cost`
  (`query.zig:49,79`) — точки, где запрос отсекает полигон по флагам/стоимости.
- `findPolysAroundCircle` (`query.zig:2641`), `getPolyWallSegments`
  (`query.zig:3669`) — основа reachability/component-анализа без правок ядра.

**Ценность.** Кластер A превращает tester из «показать ответ» в «объяснить
ответ»: developer-user получает (1) пошаговое проигрывание A*/Dijkstra с
подсветкой open/closed и числами g/h/f; (2) авто-вердикт «почему нет пути» с
конкретной причиной (разные компоненты / фильтр / стоимость / лимит узлов /
partial); (3) funnel/portal-отладку string-pulling; (4) сравнение того же
запроса под разными фильтрами бок-о-бок; (5) раскраску компонент связности
(islands); (6) reachability-heatmap от точки. Всё это — **demo-уровень поверх
готового ядра**, ничего в `src/*` менять не нужно.

---

## 2. Scope (in / out / YAGNI)

### Входит (in)

- Новый demo-инструмент «Query Diagnostics» (отдельный от tester'а), регистрируемый
  через U-shell (`tool_registry`), плюс «диагностический оверлей», который можно
  включить и поверх существующего `Test Navmesh`.
- Пошаговый проигрыватель A* (и Dijkstra-режим — A* с `H_SCALE=0` концептуально)
  поверх **существующего** sliced-API: play/pause/step/step-N/reset; подсветка
  open/closed/current/path; аннотации g/h/f на полигонах.
- Авто-классификатор «why-no-path»: машина решений, дающая один из вердиктов
  {same-poly, different-components, filtered-by-flags, blocked-by-cost,
  partial-node-limit, partial-no-goal, invalid-endpoint, ok}.
- Funnel/portal-отладка: визуализация portal left/right, apex, и шагов
  string-pulling из `findStraightPath` (через `STRAIGHTPATH_ALL_CROSSINGS`).
- Side-by-side сравнение запроса под N (2-3) разными `QueryFilter`.
- Компоненты связности (islands): flood-fill по линкам, окраска через
  `color_scheme=component`; «start и end в одной компоненте?».
- Reachability-heatmap от точки: Dijkstra-разлив по cost/distance, окраска
  градиентом через `color_scheme=cost`.

### Не входит (out)

- **Правки faithful-ядра `src/detour/*`.** Весь A-код — demo-уровень. Если для
  введения «инструментированного шага» потребуется хук в ядре — это отдельный
  вопрос владельцу (см. §5 Q1), по умолчанию НЕ трогаем.
- Перереализация A*/Dijkstra в demo. Используем `updateSlicedFindPath` как движок;
  собственный Dijkstra-разлив для heatmap/islands — это **не** дубль pathfind, а
  отдельный обход (BFS/Dijkstra по линкам), допустимый на demo-уровне.
- Сами обобщённые механизмы render (схемы/легенды/изоляция/выделение) — они в
  фундаменте 3.c; A только **потребляет** их.
- Персистентность результатов диагностики (сохранение «случая» в сцену) — это
  кластеры G/I; A слабо-опционально (P=○) может сериализовать start/end/filter,
  но по умолчанию held-in-RAM.

### YAGNI

- Запись/реплей timeline'а A* в файл, экспорт «трейса» — пока RAM-only.
- Diff двух A*-трейсов покадрово (только бок-о-бок результатов фильтров — этого
  достаточно для 90% «почему другой путь»).
- Поддержка off-mesh-специфики в пошаговом плеере сверх того, что уже даёт
  `cross_side`/links — показываем как обычные переходы.
- Произвольное число параллельных фильтров; ограничиваемся 2-3 (UI-ёмкость).
- Тепловая карта по «времени», только по cost/distance.

---

## 3. Фичи (приоритезированы)

Приоритет: **P0** (ядро ценности, минимальный риск), **P1** (высокая ценность),
**P2** (приятно иметь).

### A1 (P0) — Авто-разбор «почему нет пути» (why-no-path verdict)

**Что.** Декларативная машина решений, которая по `(start_ref, end_ref, filter,
status)` выдаёт человекочитаемый вердикт + подсветку «виновника».

**Зачем.** Самый частый вопрос developer-user'а; даёт мгновенный ответ без
ручного перебора. Все нужные сигналы уже есть в ядре.

**Логика классификации (порядок проверок).**
1. `start_ref == 0 || end_ref == 0` (findNearestPoly не нашёл) → **invalid-endpoint**
   (точка вне navmesh / отфильтрована при поиске ближайшего). Подсветить радиус
   поиска `half_extents`.
2. `start_ref == end_ref` → **same-poly** (тривиально ok).
3. Компонентный тест (см. A5): start-компонента ≠ end-компонента → **different-components**.
   Подсветить обе компоненты разными цветами (R.highlight + color_scheme=component).
4. Запустить `findPath`; читать `Status`:
   - `out_of_nodes` (`common.zig:30`) → **partial-node-limit** (увеличить
     `max_nodes` в `initQuery`, `query.zig:520`). Показать `getNodeCount()` vs
     `getMaxNodes()`.
   - `partial_result` без `out_of_nodes` → **partial-no-goal** (goal недостижим в
     заданном фильтре, путь оборван на ближайшем узле). Подсветить `last_best`.
   - `invalid_param` → **invalid-endpoint**.
   - success, path[last]==end_ref → **ok**.
5. Если компоненты совпали, но пути нет/partial — дифференцировать
   **filtered-by-flags** vs **blocked-by-cost**: повторить компонентный flood-fill
   с «нейтральным» фильтром (include=0xffff, exclude=0, все area_cost=1). Если при
   нейтральном фильтре путь есть, а при пользовательском нет:
   - различие в достижимости (флаги) → **filtered-by-flags**: найти граничный
     полигон, который `passFilter`==false, подсветить (R.highlight).
   - достижимость та же, но cost-ветка отрезана эвристикой/area_cost (огромный
     `area_cost`) → **blocked-by-cost** (мягкий вердикт: путь дороже, не
     «невозможен»; показать суммарную стоимость).

**UX.** Панель-вердикт (через U.panel) с иконкой статуса, одной строкой-причиной
и кнопкой «Explain» (раскрывает детали: счётчики узлов, граничный полигон,
компоненты). При наведении — подсветка виновника в 3D.

**Данные.** `start_ref`/`end_ref`/`filter` из инструмента; `Status` из findPath;
`getNodePool()`/`getNodeCount()`/`getMaxNodes()`; компонент-индекс из A5;
нейтральный `QueryFilter.init()`.

**Зависимости.** Ядро: `query.zig` findPath/Status/QueryFilter/NodePool;
`getPolyWallSegments`/`findPolysAroundCircle` для flood-fill. Фундамент:
**R.highlight** (подсветка виновника), **U.panel** (вердикт-панель), **Sc**
(чтение flags/area-реестров для объяснения какой флаг отфильтровал).

---

### A2 (P0) — Пошаговый проигрыватель A* / Dijkstra

**Что.** Контролируемое проигрывание поиска: play/pause, step (1 итерация),
step-N (по 20, как сейчас в tester sliced — `tool_navmesh_tester.zig` step
делает 20 итераций), reset. На каждом кадре — подсветка open-list (один цвет),
closed-list (другой), текущего best-node, восстановленного пути-до-best.
Аннотации g (`Node.cost`), h (вычисляется как `total - cost`), f (`Node.total`)
над полигонами.

**Зачем.** Делает A* наблюдаемым; обучающая и отладочная ценность; видно, как
эвристика ведёт фронт, где он «застревает», почему обрывается.

**Движок.** **Не пишем свой A*.** Используем sliced-API:
- `initSlicedFindPath(start, end, spos, epos, filter, options)` (`query.zig:3028`).
- На каждый «step» — `updateSlicedFindPath(step_size, &done)` (`query.zig:3101`),
  `step_size=1` для покадрового, `=20` для быстрого.
- После каждого апдейта читаем `getNodePool()` и итерируем `node_pool.nodes[0..
  node_count]`: по `flags.open`/`flags.closed` раскрашиваем; `top()` open-list'а
  (`NodeQueue.top()`, `query.zig:381`) = текущий фронт; путь-до-узла строим по
  `pidx` (как `getPathToNode`, `query.zig:1000`, но read-only обход в demo).
- Dijkstra-режим: концептуально A* с h=0. Поскольку ядро жёстко применяет
  `H_SCALE=0.999` (`query.zig:3128`), «честный Dijkstra» через sliced недоступен
  без правки ядра. Решение: Dijkstra-режим обслуживается **отдельным
  demo-обходом** (см. A5/A6 разлив), а пошаговый плеер A2 показывает только A*
  (с пометкой в UI). Альтернатива — Q1 владельцу (хук h-scale в ядро).

**UX.** Под-панель «A* Player» (U.panel): транспорт (⏮ reset / ⏯ play-pause /
⏭ step / ⏩ step-20), индикатор `iter: K, open: O, closed: C, status`.
В 3D: open=голубой, closed=серый-полупрозрачный (R.color_scheme + transCol),
current=жёлтый контур (R.highlight), путь-до-best=чёрная линия (как
существующий pathCol). Числа g/h/f — через **R.overlay** (worldspace-текст над
центром полигона; обобщение `ui.screenTextEx` из `main.zig:894-985`). Тумблер
«показывать g/h/f» (дорого на больших фронтах — R6 фундамента).

**Данные.** `NodePool.nodes` (id/pos/flags/cost/total/pidx); `NodeQueue.top`;
`done_iters`; `Status`.

**Зависимости.** Ядро: sliced-API + `NodePool`/`NodeQueue`/`Node`. Фундамент:
**R.color_scheme** (open/closed окраска), **R.highlight** (current + path),
**R.overlay** (g/h/f аннотации), **U.panel** (транспорт), **U.input_gate**
(хоткеи play/step не должны срабатывать при фокусе в textfield).

---

### A3 (P1) — Funnel / portal отладка string-pulling

**Что.** Визуализация работы `findStraightPath` (`query.zig:1135`): для текущего
poly-path рисуем порталы (left/right точки между соседними полигонами через
`getPortalPoints`, `query.zig:1109`), движущийся apex, и итоговые corner-точки.
Опционально — порталы area-crossing через `STRAIGHTPATH_ALL_CROSSINGS`/
`STRAIGHTPATH_AREA_CROSSINGS` (`appendPortals`, options в `query.zig:1144`).

**Зачем.** Funnel-алгоритм — главный источник «путь срезает странно/не туда».
Видеть left/right воронку и apex-перескоки делает баги string-pulling видимыми.

**UX.** Тумблер «Show Funnel». В 3D: для каждой пары path[i],path[i+1] —
left-точка (синяя), right-точка (красная), отрезок портала; apex-перескоки —
жёлтые маркеры; финальные corners окрашены по флагу (start/end/offmesh — как уже
делает straight-режим tester'а). Аннотация индекса портала (R.overlay).

**Данные.** `path: []PolyRef` из findPath; `getPortalPoints` (left/right/types);
`findStraightPath` с `straight_path_flags`/`straight_path_refs`.

**Зависимости.** Ядро: `getPortalPoints`/`findStraightPath`. Фундамент:
**R.highlight**/**R.overlay**. Sc: нет.

---

### A4 (P1) — Сравнение запроса под разными фильтрами (side-by-side)

**Что.** Тот же `(start, end)`, 2-3 независимых `QueryFilter` (разные
include/exclude/area_cost). Запускаем findPath для каждого, рисуем пути разными
цветами + сводную таблицу: path-len, cost, status (ok/partial), node-count.

**Зачем.** «Почему агент с фильтром swim идёт иначе, чем walk» — мгновенно видно.
Дёшево: переиспользует существующий путь рисования, меняется только filter.

**UX.** Панель «Compare Filters»: 2-3 слота, каждый — копия include/exclude
чекбоксов (как в tester'е, `tool_navmesh_tester.zig:89`) + цвет-свотч. Таблица
итогов. В 3D — N путей разными цветами + легенда (R.legend).

**Данные.** N×`QueryFilter`; N×findPath результат (path/cost/status). Cost
считаем суммой `filter.getCost` по сегментам пути (или из A*-`last_best.cost`).

**Зависимости.** Ядро: findPath/QueryFilter/getCost. Фундамент: **R.legend**
(цвет→фильтр), **R.highlight** (N путей), **U.panel**. Sc: чтение реестра флагов
(имена для чекбоксов).

---

### A5 (P1) — Компоненты связности (islands)

**Что.** Разбиение всех полигонов навмеша на компоненты связности по линкам
(flood-fill, как `tool_prune.zig`, см. FEATURES §4.2). Окраска каждой компоненты
своим цветом (`color_scheme=component`). Запрос «start-компонента == end-компонента?»
— фундамент для вердикта A1 шаг 3.

**Зачем.** «Разные острова» — частая причина no-path; раскраска делает топологию
видимой; переиспользуется в A1.

**Логика.** Обход: для каждого непосещённого полигона BFS по линкам тайла
(`first_link`/`links[].next`/`links[].ref`, как в findPath `query.zig:862-863`),
учитывая фильтр (опционально — компоненты под текущим фильтром vs «сырая»
топология). Кешировать `component_id: []u16` по (tile,poly), инвалидировать при
rebuild навмеша (хук `setNavMesh`).

**UX.** Тумблер «Show Components» + счётчик «N components». Клик по компоненте —
изолировать (R.isolation «show only»). Старт/энд подписаны номером компоненты.

**Данные.** Все tile/poly навмеша; `links`; опционально `passFilter`.
Кеш `component_id`.

**Зависимости.** Ядро: navmesh tile/poly/links, `passFilter`. Фундамент:
**R.color_scheme=component**, **R.isolation** (показать только компоненту),
**R.legend**. Sc: нет (читает собранный навмеш, не Scene).

---

### A6 (P2) — Reachability-heatmap от точки

**Что.** От start-полигона — Dijkstra-разлив (по cost через `filter.getCost`,
либо по евклидовой дистанции) до всех достижимых полигонов; окраска градиентом
(`color_scheme=cost`): близко=зелёный … далеко/дорого=красный, недостижимо=серое.

**Зачем.** «Куда вообще можно дойти и за сколько» — наглядно показывает зону
достижимости, дорогие коридоры, влияние area_cost.

**Логика.** Собственный demo-Dijkstra (не sliced — нам нужен полный разлив, а не
путь к одной цели): min-heap по накопленной стоимости, релаксация по линкам с
`filter.getCost(edgeMid…)`. Можно переиспользовать `NodeQueue`/`NodePool` ядра
напрямую (они pub), либо demo-структуру. Лимит узлов настраиваемый.

**UX.** Тумблер «Reachability». Слайдер max-cost (обрезка разлива). Легенда-шкала
градиента (R.legend). Аннотация cost при наведении на полигон (R.overlay).

**Данные.** start_ref; links; `filter.getCost`/`getEdgeMidPoint`
(`query.zig:894`). Буфер `cost_to: []f32` по полигонам.

**Зависимости.** Ядро: links/getCost/getEdgeMidPoint; опц. `NodeQueue`.
Фундамент: **R.color_scheme=cost** (градиент), **R.legend**, **R.overlay**.

---

### Приоритезация (итог)

| Фича | Приор. | Главная зависимость | Риск |
|---|:--:|---|:--:|
| A1 why-no-path verdict | **P0** | R.highlight, U.panel, A5 | низкий |
| A2 A* step-player | **P0** | sliced-API, R.overlay, U.panel | средн. (g/h/f перф) |
| A3 funnel/portal debug | P1 | getPortalPoints, R.overlay | низкий |
| A4 compare filters | P1 | QueryFilter, R.legend | низкий |
| A5 components/islands | P1 | links flood-fill, R.color_scheme | низкий |
| A6 reachability-heatmap | P2 | Dijkstra-разлив, R.color_scheme | средн. (перф больших) |

A1 зависит от A5 (компонентный тест) → A5 делать вместе с/до A1.

---

## 4. Архитектура

### Новые файлы `demo/src/` (по `.agent/project_structure.md`: snake_case, demo-уровень)

```
demo/src/diag/                       # НОВЫЙ модуль кластера A
├── tool_query_diag.zig   # SampleTool-инструмент «Query Diagnostics».
│                         #   Владеет start/end/filter(s), вызывает why-no-path,
│                         #   A*-player, funnel, compare. Регистрируется в U.tool_registry.
│                         #   Может работать как оверлей поверх Test Navmesh (общий start/end).
├── why_no_path.zig       # Машина решений A1: fn classify(query,start,end,filter,
│                         #   components) -> Verdict{ kind, culprit_poly?, detail }.
│                         #   Чистая логика, тестируемая в test/integration без GUI.
├── astar_player.zig      # A2: обёртка над sliced-API (init/update/finalize) +
│                         #   снимок open/closed/current/g/h/f для рендера. RAM-state:
│                         #   iter, status, snapshot узлов. БЕЗ своего A*.
├── funnel_debug.zig      # A3: извлечение порталов (getPortalPoints по path) +
│                         #   apex/corners из findStraightPath для визуализации.
├── filter_compare.zig    # A4: N слотов QueryFilter + прогон findPath + сводка.
├── components.zig        # A5: flood-fill компонент по линкам; кеш component_id[],
│                         #   инвалидация на setNavMesh; componentOf(ref)->u16.
└── reachability.zig      # A6: Dijkstra-разлив cost_to[]; gradient-данные для heatmap.
```

### Точки интеграции

- **Регистрация инструмента (U-shell 3.d).** `tool_query_diag.zig` реализует
  существующий `SampleTool` vtable (`sample.zig:125-172`:
  `toolType/reset/drawMenu/onClick/onToggle/step/update/render/renderOverlay`) и
  добавляется как `ToolEntry` в `shell/tool_registry.zig`. **Не** правим
  `ActiveTool`-свитч `main.zig` напрямую — это и есть смысл U-shell. До готовности
  `tool_registry` (фундамент шаг 1) — временно через существующий ручной свитч
  (`main.zig:477-498`), с пометкой TODO на миграцию.
- **start/end picking.** Переиспользуем механику tester'а: `onClick`
  ставит start (LMB) / end (Shift+LMB), `findNearestPoly` (`query.zig:1046`) для
  ref'ов. Чтобы не дублировать — вынести общий `pickEndpoints` хелпер или делить
  состояние с `tool_navmesh_tester.zig` (Q2 владельцу).
- **A*-player транспорт.** `step()` vtable-метод (`sample.zig`) уже вызывается
  по хоткею «1» (FEATURES §4.5) — переиспользуем для step. Play/pause —
  собственный хоткей через **U.input_gate** (gate по `ui_keyboard`,
  `main.zig:226`).
- **Рендер.** `render()`/`renderOverlay()` инструмента вызывают:
  - **R.highlight** (`render/highlight.zig`) — наборы полигонов (open/closed/
    components/culprit/paths). Обобщает уже работающую в tester'е подсветку
    `polys`/`parent` + `debugDrawNavMeshPoly` (`detour_debug.zig:117`).
  - **R.color_scheme** (`render/color_scheme.zig`) — `component` и `cost` схемы
    (новые значения enum из 3.c) для islands/heatmap.
  - **R.overlay** (`render/overlay.zig`) — worldspace g/h/f, cost, индексы
    порталов (обобщение `ui.screenTextEx`).
  - **R.isolation** (`render/isolation.zig`) — «show only component N».
  - **R.legend** (`render/legend.zig`) — фильтр→цвет, компонента→цвет,
    cost-градиент-шкала.
- **Чтение реестров (Scene 3.a).** Имена флагов/area (для чекбоксов фильтров и
  объяснения «какой флаг отфильтровал») — через `Scene.flags`/`Scene.areas`
  (геттеры 3.a). На переходный период — текущие module-global `poly_flags`/
  `area_types` (как сейчас в tester'е, `tool_navmesh_tester.zig:10-11`).

### Конвенции (`.agent/project_structure.md` + CLAUDE.md)

- Файлы `demo/src/diag/*.zig` — demo-уровень: usize, owned-структуры, можно
  ArrayList(Managed). Ядро `src/*` НЕ трогаем (faithful 1-в-1 с C++ recast).
- `why_no_path.zig` и `components.zig` пишутся как **чистые функции над данными
  навмеша** (без GUI), чтобы покрыть тестами в `test/integration/`
  (`why_no_path_*.zig`, `components_*.zig`).
- `PolyRef`/`Status`/i32-сентинелы ядра не переводим в usize — используем
  как есть на границе (касты на call-site — норма по CLAUDE.md).

### Что НЕ передизайниваем (ссылки на фундамент)

- Подсистемы R (3.c) и U (3.d) — берём готовыми; A только потребитель. Если в
  3.c нет нужного примитива (напр. cost-градиент-легенда) — это **запрос в
  кластер E / фундамент-3.c**, не реализация внутри A (см. Q3).
- Persist (3.b) — A не пишет в durable по умолчанию (P=○).

---

## 5. Открытые вопросы / допущения к владельцу

> Явные, НЕ угаданы. Где есть рабочее допущение — помечено *Допущение*.

1. **Dijkstra в пошаговом плеере (A2).** Ядро жёстко применяет `H_SCALE=0.999`
   в sliced (`query.zig:3128`) — «честный Dijkstra» (h=0) через sliced-API
   невозможен без правки ядра. Варианты: (а) плеер показывает только A*, Dijkstra
   обслуживается отдельным demo-разливом (A6) без пошагового UI; (б) добавить в
   ядро опциональный `h_scale`-параметр/опцию (минимальная правка faithful).
   *Допущение:* (а) — НЕ трогаем ядро, Dijkstra-плеер вне scope, A6 даёт разлив.
2. **Общее состояние с `tool_navmesh_tester.zig`.** start/end/filter дублируют
   tester. Делать Query Diagnostics (i) отдельным инструментом с собственным
   start/end, (ii) оверлеем-режимом внутри tester'а, или (iii) делить общий
   `Endpoints`-объект? *Допущение:* (i) отдельный инструмент + общий хелпер
   `pickEndpoints`; оверлей поверх tester — P2.
3. **Граница A vs фундамент-3.c для новых визуальных примитивов.** cost-градиент-
   легенда, component-палитра, worldspace g/h/f — это обобщённые механизмы (→ в
   3.c/кластер E по решению Q7 фундамента) или специфика A (→ в `diag/`)?
   *Допущение:* механизмы (схема/легенда/оверлей-движок) — в 3.c; конкретные
   вызовы/компоновка под диагностику — в `diag/`.
4. **Компоненты: «сырая» топология vs под-фильтром.** Islands считать по голым
   линкам или с учётом текущего `passFilter` (фильтр может «разрезать» компоненту)?
   Для вердикта A1 нужны **обе**: сырая (топологический остров) + фильтрованная
   (различить different-components от filtered-by-flags). *Допущение:* считаем обе,
   кешируем раздельно.
5. **«blocked-by-cost» как вердикт.** Строго говоря, бесконечной стоимости в
   ядре нет (`area_cost` — множитель, не барьер); огромный cost лишь делает путь
   дорогим, не невозможным. Считать ли «очень дорогой путь» отдельным вердиктом,
   и каков порог? *Допущение:* мягкий вердикт «path-expensive» (информативный),
   не «no-path»; порога нет — показываем суммарную стоимость, решает человек.
6. **Зависимость от готовности фундамента.** A1/A2 требуют R.highlight+R.overlay+
   U.panel/tool_registry, которых пока НЕТ (фундамент шаги 1,3). Стартуем A после
   фундамента шагов 1→3, или делаем A с временными inline-обёртками (риск
   раздувания `main.zig`, R5 фундамента)? *Допущение:* ждём фундамент 1+3; до
   того — только чистая логика `why_no_path.zig`/`components.zig` (без GUI, под
   тесты).

---

## 6. Риски

- **A-R1 — Зависимость от ещё-не-реализованного фундамента.** R.highlight/overlay/
  isolation/color_scheme/legend (3.c) и U.tool_registry/panel/input_gate (3.d)
  пока только спроектированы. Без них A1/A2/A4/A5/A6 не имеют куда рисовать/
  регистрироваться. *Митигация:* критический путь = фундамент 1→3 перед A;
  начинать с GUI-независимой логики (`why_no_path`/`components`) под тесты (Q6).
- **A-R2 — Перф аннотаций g/h/f и оверлеев (A2).** Worldspace-текст над сотнями
  узлов open/closed на больших навмешах — дорого (R6 фундамента). *Митигация:*
  аннотации g/h/f по умолчанию выкл; лимит на число подписей (top-K по f);
  контролировать `dd_gl.draw_calls`/`verts_uploaded`.
- **A-R3 — Перф полного Dijkstra-разлива (A6) и flood-fill компонент (A5)** на
  больших multi-tile навмешах. *Митигация:* кеш `component_id`/`cost_to`,
  пересчёт только на rebuild (`setNavMesh`); лимит узлов с graceful-обрывом;
  обходы read-only, без аллокаций в кадре.
- **A-R4 — Семантическая точность вердикта (A1).** Риск ложного «filtered-by-flags»
  vs «blocked-by-cost» (см. Q5) — границы размыты. *Митигация:* вердикт +
  «Explain» с фактами (счётчики/граничный полигон/стоимость), не безапелляционный
  ярлык; чистая логика под unit-тесты с синтетическими навмешами.
- **A-R5 — Дрейф со sliced-API ядра.** A2 полагается на `updateSlicedFindPath`/
  `getNodePool` внутренности (open/closed/pidx). Если ядро поменяет sliced —
  плеер сломается. *Митигация:* A2 читает только pub-API (`getNodePool`,
  `NodeQueue.top`, `Node`-поля), не дублирует приватную логику; регрессионный
  тест на «K итераций → ожидаемые open/closed counts».
- **A-R6 — Раздувание `main.zig` до прихода U-shell.** Если A зарегистрировать
  через ручной свитч (`main.zig:477-498`) до `tool_registry`. *Митигация:*
  держать всю A-логику в `diag/*`, в `main.zig` — только одну строку диспетча;
  мигрировать на `tool_registry` как только готов.
- **A-R7 — start/end дубль с tester'ом** (Q2) → рассинхрон состояний.
  *Митигация:* общий `pickEndpoints`/`Endpoints` либо явное «A — отдельный
  инструмент со своим состоянием».

---

## 7. Этапы реализации (порядок)

Порядок: сначала GUI-независимая логика (тестируемая без фундамента), затем
визуализация по мере готовности R/U-подсистем.

1. **A5-core + A1-core (без GUI).** `components.zig` (flood-fill, кеш, сырая+
   фильтрованная) и `why_no_path.zig` (классификатор `classify(...) -> Verdict`).
   Чистые функции над навмешем. Покрыть `test/integration/why_no_path_*.zig`,
   `components_*.zig` синтетическими навмешами (разные острова / фильтр-разрез /
   node-limit). **Не требует фундамента-GUI** → можно начинать сразу.
   *Разблокирует:* вердикт-движок для A1, компонентный тест.
2. **Каркас инструмента + интеграция U-shell.** `tool_query_diag.zig` как
   `SampleTool`; регистрация через `tool_registry` (после фундамент-шаг 1).
   start/end picking (общий хелпер, Q2). Пока без визуализации — только текстовый
   вердикт A1 в панели (U.panel). *Зависит:* фундамент U (3.d).
3. **A1 визуализация + A5 окраска.** Подключить R.highlight (culprit/компоненты),
   R.color_scheme=component, R.legend, R.isolation. *Зависит:* фундамент R (3.c).
4. **A2 A*-player.** `astar_player.zig` поверх sliced-API; транспорт (U.panel/
   input_gate); open/closed/current/path через R; g/h/f через R.overlay (за
   тумблером). *Зависит:* R+U.
5. **A3 funnel + A4 compare.** `funnel_debug.zig` (порталы/apex/corners),
   `filter_compare.zig` (N фильтров, сводка, R.legend). Обе — поверх готовых R/U.
6. **A6 reachability-heatmap (P2).** `reachability.zig` Dijkstra-разлив +
   R.color_scheme=cost + R.legend-шкала. Последним — наиболее перф-чувствительно
   и наименее критично.

**Критический путь:** этап 1 (можно начинать без фундамента) → фундамент(1,3) →
этапы 2,3 (A1/A5 полноценно) → 4 (A2) → 5 → 6.
