# ROOT CAUSE: Multi-Stack System in C++ Watershed

## 🎯 КРИТИЧЕСКАЯ НАХОДКА

**Zig и C++ используют РАЗНЫЕ алгоритмы управления стеком в watershed!**

## C++ Реализация (RecastRegion.cpp:1553-1612)

### Multi-Stack System

```cpp
const int LOG_NB_STACKS = 3;
const int NB_STACKS = 1 << LOG_NB_STACKS;  // NB_STACKS = 8
rcTempVector<LevelStackEntry> lvlStacks[NB_STACKS];  // 8 стеков!

while (level > 0)
{
    level = level >= 2 ? level-2 : 0;
    sId = (sId+1) & (NB_STACKS-1);  // Циклический переход между стеками

    if (sId == 0)
        sortCellsByLevel(level, chf, srcReg, NB_STACKS, lvlStacks, 1);
    else
        appendStacks(lvlStacks[sId-1], lvlStacks[sId], srcReg);

    expandRegions(expandIters, level, chf, srcReg, srcDist, lvlStacks[sId], false);

    for (int j = 0; j<lvlStacks[sId].size(); j++)
    {
        // Flood fill from lvlStacks[sId]
    }
}
```

### sortCellsByLevel (lines 470-505)

```cpp
static void sortCellsByLevel(unsigned short startLevel,
                              rcCompactHeightfield& chf,
                              const unsigned short* srcReg,
                              unsigned int nbStacks,
                              rcTempVector<LevelStackEntry>* stacks,
                              unsigned short loglevelsPerStack)  // = 1
{
    startLevel = startLevel >> loglevelsPerStack;

    for (unsigned int j=0; j<nbStacks; ++j)
        stacks[j].clear();

    // Распределяет cells по 8 стекам на основе их distance level
    for (int y = 0; y < h; ++y)
    {
        for (int x = 0; x < w; ++x)
        {
            for each span i:
                int level = chf.dist[i] >> loglevelsPerStack;  // Деление на 2
                int sId = startLevel - level;
                if (sId >= nbStacks) continue;
                if (sId < 0) sId = 0;

                stacks[sId].push_back(LevelStackEntry(x, y, i));
        }
    }
}
```

**Ключевой момент**: `loglevelsPerStack = 1` означает, что каждый стек обрабатывает диапазон из **2 уровней** distance.

### appendStacks (lines 508-519)

```cpp
static void appendStacks(const rcTempVector<LevelStackEntry>& srcStack,
                         rcTempVector<LevelStackEntry>& dstStack,
                         const unsigned short* srcReg)
{
    // Копирует необработанные cells из предыдущего стека
    for (int j=0; j<srcStack.size(); j++)
    {
        int i = srcStack[j].index;
        if ((i < 0) || (srcReg[i] != 0))
            continue;
        dstStack.push_back(srcStack[j]);
    }
}
```

## Zig Реализация (region.zig:1056-1106)

### Single Stack System

```zig
var stack = std.ArrayList(LevelStackEntry).init(allocator);

while (level > 0) {
    level = if (level >= 2) level - 2 else 0;

    try expandRegions(expand_iters, level, chf, src_reg, src_dist, &stack, true, allocator);

    // Очищает стек!
    stack.clearRetainingCapacity();

    // Собирает все cells на этом level
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            for each span i:
                if (chf.dist[i] >= level and src_reg[i] == 0) {
                    try stack.append(.{ .x = x, .y = y, .index = i });
                }
        }
    }

    // Flood fill from single stack
    for (stack.items) |current| {
        // ...
    }
}
```

## 🔍 Почему это важно?

### Распределение по стекам в C++

С `NB_STACKS=8` и `loglevelsPerStack=1`, cells распределяются так:

- **Stack 0**: distance levels в диапазоне [level, level+1]
- **Stack 1**: distance levels в диапазоне [level-2, level-1]
- **Stack 2**: distance levels в диапазоне [level-4, level-3]
- **Stack 3**: distance levels в диапазоне [level-6, level-5]
- ...
- **Stack 7**: самые низкие levels

### Порядок обработки

**C++**:
1. sId=0: sortCellsByLevel → создает 8 стеков, отсортированных по distance
2. Обрабатывает Stack 0 (самые высокие distance)
3. sId=1: appendStacks → копирует необработанные из Stack 0 в Stack 1
4. Обрабатывает Stack 1
5. sId=2: appendStacks → копирует из Stack 1 в Stack 2
6. И так далее...

**Zig**:
1. Собирает ВСЕ cells с `dist >= level` в один стек
2. Обрабатывает их в порядке итерации (y, x)
3. Очищает стек
4. Переходит к следующему level

### Последствия

Порядок обработки cells **КРИТИЧЕСКИ** влияет на то, какие spans попадут в какие регионы во время flood fill!

Когда несколько регионов "конкурируют" за один span, побеждает тот, который обработан **первым**. Поскольку C++ и Zig обрабатывают cells в разном порядке, spans распределяются по-разному!

## 📊 Пример расхождения

### Регион 43:
- **C++**: 44 spans (обработан раньше, захватил больше spans)
- **Zig**: 1 span (обработан позже, большинство spans уже забраны другими регионами)

### Регион 44:
- **C++**: 127 spans
- **Zig**: 2 spans

Разница в **169 spans** между этими двумя регионами!

## 🎯 Решение

### Вариант 1: Портировать Multi-Stack систему (РЕКОМЕНДУЕТСЯ)

Реализовать в Zig:
1. ✅ Создать массив из 8 стеков
2. ✅ Реализовать `sortCellsByLevel`
3. ✅ Реализовать `appendStacks`
4. ✅ Изменить цикл watershed для использования циклического sId
5. ✅ Обрабатывать стеки последовательно, как в C++

**Плюсы:**
- 100% соответствие с C++ алгоритмом
- Гарантированно одинаковый результат

**Минусы:**
- Более сложный код
- Требует понимания multi-stack логики

### Вариант 2: Изменить порядок итерации в Zig

Попытаться подобрать порядок обработки cells, который даст тот же результат.

**Плюсы:**
- Проще в реализации

**Минусы:**
- Не гарантирует 100% соответствие
- Трудно подобрать правильный порядок

## 📝 План действий

1. ✅ Найдена root cause: multi-stack vs single-stack
2. 🔄 **Следующее**: Реализовать multi-stack систему в Zig
   - Создать массив из 8 стеков
   - Портировать sortCellsByLevel
   - Портировать appendStacks
   - Изменить цикл watershed
3. ⏸️ Запустить тесты и проверить результаты
4. ⏸️ Подтвердить 100% соответствие (432/206/44)

## 💡 Ключевой инсайт

**mergeAndFilterRegions работает КОРРЕКТНО** ✅

**Watershed partitioning использует РАЗНЫЕ алгоритмы в C++ и Zig** ❌

Это объясняет ВСЕ расхождения в region span counts!
