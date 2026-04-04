# rzwasi

`rzwasi` builds [Rizin](https://rizin.re) for browser environments with Emscripten. The generated `rizin.js` and `rizin.wasm` artifacts are consumed by [RzWeb](https://github.com/IndAlok/rzweb) and any other frontend that wants a browser-native reverse engineering core.

## Purpose

This repository is the WebAssembly build layer for Rizin. It keeps the browser build reproducible, applies the portability patches needed for Emscripten, and exports the additional `rzweb_*` ABI used by RzWeb for persistent sessions, project snapshots, command autocomplete, and command catalog lookups.

## Hosted Files

Prebuilt artifacts are published from GitHub Pages:

```text
https://indalok.github.io/rzwasi/rizin.js
https://indalok.github.io/rzwasi/rizin.wasm
```

## What The Build Supports

- Disassembly across the architectures and formats supported by the bundled Rizin release
- Parsing for ELF, PE, Mach-O, and raw binaries
- Analysis data such as functions, strings, imports, exports, sections, and graphs
- Write-enabled in-memory sessions when the caller opts into write mode
- Persistent `RzCore` sessions for browser apps that use the `rzweb_*` API instead of only `callMain()`

## RzWeb In Action

**Terminal**

![RzWeb Terminal](https://raw.githubusercontent.com/IndAlok/rzweb/main/public/Terminal.png)

**Control Flow Graph**

![RzWeb Graph](https://raw.githubusercontent.com/IndAlok/rzweb/main/public/Graph.png)

**Imports**

![RzWeb Imports](https://raw.githubusercontent.com/IndAlok/rzweb/main/public/Imports.png)

**Binary Info**

![RzWeb Binary Info](https://raw.githubusercontent.com/IndAlok/rzweb/main/public/BinInfo.png)

## Building

Use a Linux environment with Emscripten installed. Ubuntu 22.04 or newer is a good baseline.

### Requirements

- Emscripten SDK 3.1.50 or newer
- Python 3.8 or newer
- Meson
- Git

### Steps

```bash
git clone https://github.com/IndAlok/rzwasi
cd rzwasi

./setup.sh install
source ~/.emsdk/emsdk_env.sh

./build.sh
```

The compiled artifacts are written to `dist/`.

## Exported Browser APIs

### Traditional CLI entrypoint

The standard Emscripten entrypoint still works:

```javascript
Module.FS.writeFile('/work/binary', binaryData);
Module.callMain(['-q', '-c', 'afl', '/work/binary']);
```

`callMain()` remains stateless, which is useful for one-shot invocations and compatibility.

### Persistent session API used by RzWeb

`rzwasi` also exports browser-facing helpers for a persistent `RzCore` session:

- `rzweb_create_session`
- `rzweb_close_session`
- `rzweb_open_file`
- `rzweb_cmd`
- `rzweb_get_seek`
- `rzweb_save_project`
- `rzweb_load_project`
- `rzweb_get_last_error`
- `rzweb_autocomplete`
- `rzweb_get_command_catalog`

Minimal example:

```javascript
const createSession = Module.cwrap('rzweb_create_session', 'number', []);
const openFile = Module.cwrap('rzweb_open_file', 'number', ['number', 'string', 'number', 'number']);
const cmd = Module.cwrap('rzweb_cmd', 'string', ['number', 'string']);

Module.FS.writeFile('/work/sample.bin', binaryData);

const session = createSession();
openFile(session, '/work/sample.bin', 0, 1);
cmd(session, 'aaa');
console.log(cmd(session, 'aflj'));
```

## Build Patches

The build script applies the compatibility fixes needed for Emscripten automatically. That includes the browser-thread stubs, the `libzip` portability fix, the `io_shm` portability patch, and the target-local Meson changes that attach the `rzweb_*` session wrapper only to the `rizin` binary where it belongs.

## Limitations

- No debugger support in browser sandboxes
- No traditional networking workflows inside the browser runtime
- Single-threaded analysis and UI responsiveness still depend on browser and device limits
- Apps that rely only on `callMain()` remain stateless by design until they adopt the persistent session ABI

## Credits

Built by [IndAlok](https://github.com/IndAlok)

Based on [Rizin](https://rizin.re) by the Rizin Organization.
