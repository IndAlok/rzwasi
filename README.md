# rzwasi

Rizin reverse engineering framework compiled to WebAssembly for browser-based binary analysis.

## What This Is

This repository contains the build infrastructure to compile [Rizin](https://rizin.re) to WebAssembly using Emscripten. The resulting `rizin.wasm` and `rizin.js` files enable running the full Rizin CLI in web browsers.

Used by [RzWeb](https://github.com/IndAlok/rzweb) to provide a complete browser-based reverse engineering environment.

## Hosted Files

Pre-built WASM is hosted on GitHub Pages:

```
https://indalok.github.io/rzwasi/rizin.js   (~2.5MB)
https://indalok.github.io/rzwasi/rizin.wasm (~30MB)
```

## Features Preserved

The WASM build includes:
- Full disassembly engine (x86, ARM, MIPS, PPC, SPARC, etc.)
- Binary format parsers (ELF, PE, Mach-O, raw)
- Analysis engine (function detection, xrefs, CFG)
- Hex editor capabilities
- String extraction
- Import/export analysis
- Section mapping
- Write mode (in-memory patching)

## Build Requirements

- Linux environment (Ubuntu 22.04+ recommended)
- Emscripten SDK 3.1.50+
- Python 3.8+
- Meson build system
- Git

## Building

```bash
git clone https://github.com/IndAlok/rzwasi
cd rzwasi

./setup.sh
./build.sh
```

Output files: `rizin/build/binrz/rizin/rizin.js` and `rizin.wasm`

## Build Patches

The build applies several patches for Emscripten compatibility:

**Threading**: WASM is single-threaded, thread functions execute synchronously.

**libzip**: Random number generation and file operations adapted for Emscripten's virtual filesystem.

**jemalloc**: Heap analysis internals conditionally disabled (types don't exist in WASM environment).

**Filesystem**: Uses Emscripten's in-memory FS. Files are written via `FS.writeFile()` before analysis.

## Usage in JavaScript

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

## Limitations

- **No debugger**: ptrace not available in browser sandbox
- **No networking**: Network-based protocols disabled
- **Single-threaded**: All analysis runs synchronously
- **CLI mode**: Each `callMain()` is stateless - combine commands with semicolons

## Version

Current build: Rizin 0.9.0 (dev branch)

## Credits

Built by [IndAlok](https://github.com/IndAlok)

Based on [Rizin](https://rizin.re) by the Rizin Organization.
