# rzwasi

Rizin compiled to WebAssembly. This repository contains the build scripts and patches needed to compile the Rizin reverse engineering framework for browser environments.

## Purpose

The goal is to run Rizin in a web browser. The build produces `rizin.wasm` and `rizin.js` files that can be loaded by any web application. The main consumer is [RzWeb](https://github.com/IndAlok/rzweb), which provides a complete browser-based RE interface.

## Hosted Files

Pre-built binaries are hosted on GitHub Pages and served via the repository's gh-pages branch:

```
https://indalok.github.io/rzwasi/rizin.js   (~2.5 MB)
https://indalok.github.io/rzwasi/rizin.wasm (~30 MB)
```

These files are automatically rebuilt whenever the main branch is updated.

## What Works

The WASM build preserves most of Rizin's functionality:

- **Disassembly** for x86, ARM, MIPS, PowerPC, SPARC, and other architectures
- **Format parsing** for ELF, PE, Mach-O, and raw binaries
- **Analysis** including function detection, cross-references, and control flow graphs
- **Hex editing** and raw byte manipulation
- **String extraction** and search
- **Write mode** for in-memory binary patching

## Building

You need a Linux environment with Emscripten installed. Ubuntu 22.04 or newer is recommended.

### Requirements

- Emscripten SDK 3.1.50 or newer
- Python 3.8 or newer
- Meson build system
- Git

### Steps

```bash
git clone https://github.com/IndAlok/rzwasi
cd rzwasi

./setup.sh install
source ~/.emsdk/emsdk_env.sh

./build.sh
```

The output files will be in the `dist/` directory.

## Build Patches

Compiling Rizin for Emscripten requires several patches. These are applied automatically by the build script:

**Threading** - WebAssembly is single-threaded. All thread-related functions are stubbed to execute synchronously.

**libzip** - The random number generation and some file operations are adapted for Emscripten's virtual filesystem.

**jemalloc** - Heap analysis internals are conditionally disabled because the required types do not exist in the WASM environment.

**Filesystem** - Uses Emscripten's in-memory filesystem. Binaries are written via `FS.writeFile()` before analysis.

## JavaScript Usage

```javascript
const Module = {
  locateFile: (path) => `https://indalok.github.io/rzwasi/${path}`,
  print: (text) => console.log(text),
  printErr: (text) => console.error(text),
  noInitialRun: true,
  onRuntimeInitialized: () => {
    Module.FS.writeFile('/work/binary', binaryData);
    Module.callMain(['-q', '-c', 'afl', '/work/binary']);
  }
};

const script = document.createElement('script');
script.src = 'https://indalok.github.io/rzwasi/rizin.js';
document.head.appendChild(script);
```

Each `callMain()` invocation is stateless - Rizin starts fresh every time. Chain commands with semicolons if you need state to persist, like `s main;pdf`.

## Limitations

- **No debugger** - ptrace is not available in browser sandboxes
- **No networking** - Network-based protocols are disabled
- **Single-threaded** - All analysis runs synchronously on the main thread
- **Stateless CLI** - Each command invocation starts fresh

## Version

Current build: Rizin 0.7.3

## Credits

Built by [IndAlok](https://github.com/IndAlok)

Based on [Rizin](https://rizin.re) by the Rizin Organization.
