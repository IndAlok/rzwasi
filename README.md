# rzwasi

Build Rizin for WebAssembly (WASI).

This repository provides scripts to compile [Rizin](https://rizin.re) to WebAssembly, enabling browser-based reverse engineering via projects like [rzweb](https://github.com/rizinorg/rzweb).

## Quick Start

```bash
# Install WASI SDK
./setup.sh install

# Build Rizin WASM (default: v0.7.3)
./build.sh

# Build specific version
./build.sh -v 0.7.2
```

Output files are in `dist/`:
- `rizin.wasm` - Main Rizin binary
- `rz-bin.wasm`, `rz-asm.wasm`, etc. - Additional tools

## Requirements

- Linux or macOS (Windows via WSL)
- Bash, Git, curl/wget
- Python 3 with pip
- Meson, Ninja

## Usage

```
./build.sh [OPTIONS]

Options:
  -v, --version VER   Rizin version to build (default: 0.7.3)
  -o, --output DIR    Output directory (default: ./dist)
  -j, --jobs N        Parallel build jobs (default: auto)
  -c, --clean         Clean build before starting
  -h, --help          Show help
```

## CI/CD

Push a tag to create a release:

```bash
git tag v0.7.3
git push origin v0.7.3
```

The GitHub Actions workflow automatically builds and uploads the WASM files.

## Using with rzweb

Download releases from this repository and place in rzweb's `public/` folder:

```bash
curl -LO https://github.com/rizinorg/rzwasi/releases/download/v0.7.3/rizin-0.7.3-wasi.zip
unzip rizin-0.7.3-wasi.zip -d rzweb/public/
```

## License

LGPL-3.0-only
