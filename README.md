# rzwasi

Rizin WebAssembly build scripts using Emscripten.

## Overview

This repository builds Rizin for WebAssembly using Emscripten, enabling browser-based binary analysis. The compiled WASM is used by rzweb to run Rizin in the browser.

## Build Process

The build script:
1. Clones Rizin source from the official repository
2. Applies patches for Emscripten compatibility (threading stubs)
3. Compiles using Emscripten SDK
4. Outputs rizin.js and rizin.wasm

## Threading Patches

Since Emscripten does not fully support pthreads in many environments, the build applies patches to:
- thread.c - Makes rz_th_new run callbacks synchronously
- thread_lock.c - Makes lock operations no-ops
- thread_sem.c - Stubs semaphore operations
- thread_cond.c - Stubs condition variable operations

This allows Rizin to run in single-threaded WASM mode.

## GitHub Actions

The repository includes a workflow that:
1. Sets up Emscripten SDK
2. Runs the build script
3. Deploys output to GitHub Pages

Output is available at: https://[username].github.io/rzwasi/

## Output Files

- rizin.js - Emscripten JavaScript loader
- rizin.wasm - Compiled Rizin binary

## Usage

Trigger the "Build Rizin WASM" workflow in GitHub Actions, or run locally:

```bash
./build.sh
```

Requires Emscripten SDK to be installed and activated.

## Limitations

- Single-threaded execution only
- Some analysis features may be slower than native Rizin
- Debugging features (-d flag) not available
- Memory limited by browser constraints

## License

LGPL-3.0-only
