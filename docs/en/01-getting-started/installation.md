# Installation & Setup

[Русская версия](../../ru/01-getting-started/installation.md) | **English**

Guide to installing Zig and setting up the zig-recast project.

---

## Requirements

### Minimum Requirements

- **Zig**: version 0.14.0 or newer
- **Operating System**: Windows, Linux, or macOS
- **RAM**: 4 GB (8 GB recommended)
- **Disk**: 500 MB free space

### Recommended Tools

- **Git**: for cloning the repository
- **Visual Studio Code** or another editor with Zig support
- **ZLS (Zig Language Server)**: for autocompletion and navigation

---

## Installing Zig

### Windows

#### Method 1: Download Binary
1. Go to [ziglang.org/download](https://ziglang.org/download/)
2. Download the archive for Windows (x86_64)
3. Extract to `C:\zig\` (or any other directory)
4. Add `C:\zig\` to PATH:
   ```cmd
   setx PATH "%PATH%;C:\zig\"
   ```

#### Method 2: Via Scoop
```powershell
scoop install zig
```

#### Method 3: Via Chocolatey
```powershell
choco install zig
```

### Linux

#### Ubuntu/Debian
```bash
# Via snap
sudo snap install zig --classic --beta

# Or download binary
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

#### Via Homebrew
```bash
brew install zig
```

#### Via MacPorts
```bash
sudo port install zig
```

---

## Verify Installation

Check that Zig is installed correctly:

```bash
zig version
```

You should see:
```
0.14.0 or newer
```

---

## Clone Repository

### Via Git

```bash
git clone https://github.com/your-org/zig-recast.git
cd zig-recast
```

### Download Archive

1. Go to the GitHub project page
2. Click "Code" → "Download ZIP"
3. Extract the archive
4. Open terminal in the project directory

---

## Project Structure

After cloning you will see:

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

## First Build

Build the project to verify everything works:

```bash
zig build
```

You should see:
```
Build succeeded
```

---

## Editor Setup

### Visual Studio Code

1. **Install Zig Extension**:
   - Open VS Code
   - Go to Extensions (Ctrl+Shift+X)
   - Search for "Zig Language"
   - Install extension from zigtools

2. **Install ZLS (Zig Language Server)**:
   ```bash
   # Windows (via scoop)
   scoop install zls

   # Linux/macOS
   git clone https://github.com/zigtools/zls
   cd zls
   zig build -Doptimize=ReleaseSafe
   sudo cp zig-out/bin/zls /usr/local/bin/
   ```

3. **Configure VS Code settings.json**:
   ```json
   {
     "zig.zls.enableAutofix": true,
     "zig.zls.enableSnippets": true,
     "zig.buildOnSave": false
   }
   ```

### Vim/Neovim

1. **Install vim-zig plugin**:
   ```vim
   " Via vim-plug
   Plug 'ziglang/zig.vim'
   ```

2. **Configure LSP with ZLS**:
   ```lua
   -- Neovim with nvim-lspconfig
   require'lspconfig'.zls.setup{}
   ```

### Emacs

```elisp
;; Add to init.el
(use-package zig-mode
  :hook (zig-mode . lsp-deferred))
```

---

## Verify Functionality

### Run Tests

```bash
zig build test
```

All 191 tests should pass:
```
All 191 tests passed.
```

### Run Example

```bash
zig build examples
./zig-out/bin/simple_navmesh
```

You should see output:
```
Creating NavMesh...
NavMesh created successfully!
```

---

## Configure Paths (Optional)

### Add to PATH

If you want to use zig-recast from any directory:

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

### Error: "zig: command not found"

**Solution:** Zig is not in PATH. Repeat the steps to add to PATH.

### Error: "unable to find zig installation"

**Solution:**
1. Check that Zig is installed: `zig version`
2. Reinstall Zig following the instructions above

### Build Error: "FileNotFound"

**Solution:** Make sure you're in the project root directory:
```bash
cd zig-recast
zig build
```

### ZLS Not Working

**Solution:**
1. Check ZLS version: `zls --version`
2. ZLS must be compatible with your Zig version
3. Reinstall ZLS if versions don't match

### Slow Build on Windows

**Solution:** Add antivirus exception for the project directory and `zig-cache/`.

---

## Next Steps

After successful installation:

1. 📖 [Quick Start Guide](quick-start.md) - create your first NavMesh
2. 🏗️ [Building & Testing](building.md) - learn more about building
3. 📚 [Architecture Overview](../02-architecture/overview.md) - understand the architecture

---

## Additional Resources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [Zig Learn](https://ziglearn.org/)
- [ZLS GitHub](https://github.com/zigtools/zls)
- [Zig Forum](https://ziggit.dev/)

---

**Help:** If you have issues, create a [GitHub Issue](https://github.com/your-org/zig-recast/issues).
