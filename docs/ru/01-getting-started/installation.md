# Installation & Setup

Руководство по установке Zig и настройке проекта zig-recast.

---

## Требования

### Минимальные требования

- **Zig**: версия 0.14.0 или новее
- **Операционная система**: Windows, Linux, или macOS
- **RAM**: 4 GB (рекомендуется 8 GB)
- **Диск**: 500 MB свободного места

### Рекомендуемые инструменты

- **Git**: для клонирования репозитория
- **Visual Studio Code** или другой редактор с поддержкой Zig
- **ZLS (Zig Language Server)**: для автодополнения и навигации

---

## Установка Zig

### Windows

#### Способ 1: Скачать binary
1. Перейдите на [ziglang.org/download](https://ziglang.org/download/)
2. Скачайте архив для Windows (x86_64)
3. Распакуйте в `C:\zig\` (или любую другую директорию)
4. Добавьте `C:\zig\` в PATH:
   ```cmd
   setx PATH "%PATH%;C:\zig\"
   ```

#### Способ 2: Через Scoop
```powershell
scoop install zig
```

#### Способ 3: Через Chocolatey
```powershell
choco install zig
```

### Linux

#### Ubuntu/Debian
```bash
# Через snap
sudo snap install zig --classic --beta

# Или скачать binary
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /usr/local/zig
export PATH=$PATH:/usr/local/zig
```

#### Arch Linux
```bash
pacman -S zig
```

### macOS

#### Через Homebrew
```bash
brew install zig
```

#### Через MacPorts
```bash
sudo port install zig
```

---

## Проверка установки

Проверьте что Zig установлен правильно:

```bash
zig version
```

Вы должны увидеть:
```
0.14.0 или новее
```

---

## Клонирование репозитория

### Через Git

```bash
git clone https://github.com/your-org/zig-recast.git
cd zig-recast
```

### Скачать архив

1. Перейдите на GitHub страницу проекта
2. Нажмите "Code" → "Download ZIP"
3. Распакуйте архив
4. Откройте терминал в директории проекта

---

## Структура проекта

После клонирования вы увидите:

```
zig-recast/
├── build.zig              # Build configuration
├── build.zig.zon          # Dependencies
├── src/                   # Source code
│   ├── root.zig          # Library entry point
│   ├── math.zig          # Math utilities
│   ├── recast/           # Recast module
│   └── detour/           # Detour module
├── test/                  # Unit tests
│   ├── integration/      # Integration tests
│   └── *.zig            # Unit test files
├── examples/              # Examples
├── docs/                  # Documentation
└── README.md
```

---

## Первая сборка

Соберите проект чтобы проверить что все работает:

```bash
zig build
```

Вы должны увидеть:
```
Build succeeded
```

---

## Настройка редактора

### Visual Studio Code

1. **Установите расширение Zig**:
   - Откройте VS Code
   - Перейдите в Extensions (Ctrl+Shift+X)
   - Найдите "Zig Language"
   - Установите расширение от zigtools

2. **Установите ZLS (Zig Language Server)**:
   ```bash
   # Windows (через scoop)
   scoop install zls

   # Linux/macOS
   git clone https://github.com/zigtools/zls
   cd zls
   zig build -Doptimize=ReleaseSafe
   sudo cp zig-out/bin/zls /usr/local/bin/
   ```

3. **Настройте VS Code settings.json**:
   ```json
   {
     "zig.zls.enableAutofix": true,
     "zig.zls.enableSnippets": true,
     "zig.buildOnSave": false
   }
   ```

### Vim/Neovim

1. **Установите vim-zig plugin**:
   ```vim
   " Через vim-plug
   Plug 'ziglang/zig.vim'
   ```

2. **Настройте LSP с ZLS**:
   ```lua
   -- Neovim с nvim-lspconfig
   require'lspconfig'.zls.setup{}
   ```

### Emacs

```elisp
;; Добавьте в init.el
(use-package zig-mode
  :hook (zig-mode . lsp-deferred))
```

---

## Проверка работоспособности

### Запуск тестов

```bash
zig build test
```

Должны пройти все 191 тестов:
```
All 191 tests passed.
```

### Запуск примера

```bash
zig build examples
./zig-out/bin/simple_navmesh
```

Вы должны увидеть вывод:
```
Creating NavMesh...
NavMesh created successfully!
```

---

## Настройка путей (опционально)

### Добавление в PATH

Если вы хотите использовать zig-recast из любой директории:

**Windows:**
```cmd
setx PATH "%PATH%;C:\path\to\zig-recast\zig-out\bin"
```

**Linux/macOS:**
```bash
echo 'export PATH=$PATH:/path/to/zig-recast/zig-out/bin' >> ~/.bashrc
source ~/.bashrc
```

---

## Troubleshooting

### Ошибка: "zig: command not found"

**Решение:** Zig не добавлен в PATH. Повторите шаги добавления в PATH.

### Ошибка: "unable to find zig installation"

**Решение:**
1. Проверьте что Zig установлен: `zig version`
2. Переустановите Zig по инструкции выше

### Ошибка сборки: "FileNotFound"

**Решение:** Убедитесь что вы находитесь в корневой директории проекта:
```bash
cd zig-recast
zig build
```

### ZLS не работает

**Решение:**
1. Проверьте версию ZLS: `zls --version`
2. ZLS должен быть compatible с вашей версией Zig
3. Переустановите ZLS если версии не совпадают

### Медленная сборка на Windows

**Решение:** Добавьте antivirus исключение для директории проекта и `zig-cache/`.

---

## Следующие шаги

После успешной установки:

1. 📖 [Quick Start Guide](quick-start.md) - создайте свой первый NavMesh
2. 🏗️ [Building & Testing](building.md) - узнайте больше о сборке
3. 📚 [Architecture Overview](../02-architecture/overview.md) - понимание архитектуры

---

## Дополнительные ресурсы

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [Zig Learn](https://ziglearn.org/)
- [ZLS GitHub](https://github.com/zigtools/zls)
- [Zig Forum](https://ziggit.dev/)

---

**Помощь:** Если у вас возникли проблемы, создайте [GitHub Issue](https://github.com/your-org/zig-recast/issues).
