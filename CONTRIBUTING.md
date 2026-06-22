# Contributing to rzwasi

`rzwasi` builds [Rizin](https://github.com/rizinorg/rizin) for WebAssembly and
exposes the persistent `rzweb_*` session API consumed by
[RzWeb](https://github.com/IndAlok/rzweb). This guide covers the build and how
to contribute changes.

## Quick links

- Community chat: [Telegram](https://telegram.dog/rizinweb)
- Frontend consumer: [RzWeb](https://github.com/IndAlok/rzweb)
- Upstream: [Rizin](https://github.com/rizinorg/rizin)

## How the build works

`build.sh` clones the pinned Rizin version (see [`VERSION`](VERSION)), applies the
Emscripten patches in [`patches/`](patches/), configures a static `wasm32`
Meson cross-build, and links the `rzweb_session_api.c` exports into the `rizin`
binary. Output lands in `dist/` (`rizin.js`, `rizin.wasm`, `VERSION`).

Key pieces:

| File | Purpose |
| --- | --- |
| `build.sh` | End-to-end build + patching + packaging |
| `setup.sh` | Install/activate the Emscripten SDK |
| `patches/rzweb_session_api.c` | The `rzweb_*` exported session API |
| `patches/*.py`, `patches/*.patch`, `patches/*.h` | Threading/emscripten source patches |

> Exported functions **must** be listed in `RZWEB_EXPORTED_FUNCTIONS` in
> `build.sh` (with a leading underscore) or Emscripten will dead-strip them.

## Prerequisites

- Linux or macOS (CI builds on `ubuntu-latest`)
- Emscripten SDK **3.1.50** — `./setup.sh install`
- `meson`, `ninja`, `python3`, `git`, `zip`

## Building locally

```bash
./setup.sh install           # one-time: fetch + activate emsdk 3.1.50
source ~/.emsdk/emsdk_env.sh  # put emcc on PATH
./build.sh -v 0.9.0          # build a specific Rizin version
# Optional experimental decompiler:
ENABLE_JSDEC=1 ./build.sh
```

Then point RzWeb at your local `dist/rizin.js` to test end-to-end.

## Before you open a PR

- Shell scripts pass `shellcheck --severity=error build.sh setup.sh`.
- Python patch scripts compile: `python -m py_compile patches/*.py`.
- A full `./build.sh` completes and the artifact loads in RzWeb.
- New C exports are registered in `RZWEB_EXPORTED_FUNCTIONS`.

CI runs the build on every PR, so a green check means the WASM still compiles.

## Reporting security issues

See [SECURITY.md](SECURITY.md), please just don't open issues publicly for
vulnerabilities.

## License

rzwasi is `LGPL-3.0-only` (see [LICENSE](LICENSE)); Rizin itself is licensed by
its upstream authors. Contributions are accepted under the repository license.
