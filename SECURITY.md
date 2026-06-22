# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately**, don't open a public
issue.

- Use [GitHub private vulnerability reporting](https://github.com/IndAlok/rzwasi/security/advisories/new), or
- Reach a maintainer (currently me only) via the [Telegram community](https://telegram.dog/rizinweb).

## Scope

rzwasi produces the Rizin WebAssembly module and the `rzweb_*` session API.
Security-relevant areas include:

- The `rzweb_session_api.c` boundary (input handling, memory ownership of the
  returned strings/buffers).
- The Emscripten patches under `patches/` that alter Rizin's threading, I/O, and
  console behavior.
- Sandbox expectations: the module is designed to run untrusted binaries inside
  the browser's WebAssembly sandbox.

Vulnerabilities in **Rizin itself** (not the WASM port) should be reported
upstream to [rizinorg/rizin](https://github.com/rizinorg/rizin/security).

## Supported versions

Fixes target the Rizin version pinned in [`VERSION`](VERSION) and `main`.
