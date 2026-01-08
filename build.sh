#!/bin/bash
# SPDX-FileCopyrightText: 2024 RizinOrg <info@rizin.re>
# SPDX-License-Identifier: LGPL-3.0-only
#
# Build Rizin for WebAssembly using Emscripten
# Based on radare2's wasm.sh approach

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIZIN_VERSION="${RIZIN_VERSION:-0.7.3}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m✓\033[0m $1"; }

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build Rizin for WebAssembly (Emscripten)

Options:
  -v, --version VER   Rizin version to build (default: ${RIZIN_VERSION})
  -o, --output DIR    Output directory (default: ./dist)
  -j, --jobs N        Parallel build jobs (default: auto)
  -c, --clean         Clean build before starting
  -h, --help          Show this help
EOF
}

CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) RIZIN_VERSION="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -j|--jobs) BUILD_JOBS="$2"; shift 2 ;;
        -c|--clean) CLEAN=true; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

RIZIN_DIR="${SCRIPT_DIR}/.rizin-src"
BUILD_DIR="${RIZIN_DIR}/build-wasm"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           rzwasi - Build Rizin for WebAssembly           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Version:   ${RIZIN_VERSION}"
echo "Output:    ${OUTPUT_DIR}"
echo "Jobs:      ${BUILD_JOBS}"
echo ""

if ! command -v emcc &> /dev/null; then
    print_error "Emscripten (emcc) not found. Please install and activate emsdk first."
    print_status "Install emsdk: https://emscripten.org/docs/getting_started/downloads.html"
    exit 1
fi

print_status "Using Emscripten: $(emcc --version | head -1)"

if [ ! -d "${RIZIN_DIR}/.git" ]; then
    print_status "Cloning Rizin v${RIZIN_VERSION}..."
    git clone --depth 1 --branch "v${RIZIN_VERSION}" \
        https://github.com/rizinorg/rizin.git "${RIZIN_DIR}"
else
    print_status "Using existing Rizin source..."
    cd "${RIZIN_DIR}"
    git fetch --tags 2>/dev/null || true
    git checkout "v${RIZIN_VERSION}" 2>/dev/null || git checkout "${RIZIN_VERSION}" 2>/dev/null || true
    cd "${SCRIPT_DIR}"
fi

print_status "Applying Emscripten compatibility patches..."
cd "${RIZIN_DIR}"

if grep -q "'emscripten'" meson.build 2>/dev/null; then
    print_success "Patches already applied"
else
    sed -i "s/have_lrt = not \['windows', 'darwin', 'openbsd', 'android', 'haiku'\]/have_lrt = not ['windows', 'darwin', 'openbsd', 'android', 'haiku', 'emscripten', 'wasi']/g" meson.build
    sed -i "s/have_ptrace = not \['windows', 'cygwin', 'sunos', 'haiku'\]/have_ptrace = not ['windows', 'cygwin', 'sunos', 'haiku', 'emscripten', 'wasi']/g" meson.build
    print_success "Applied meson.build patches for Emscripten"
fi

if [ "$CLEAN" = true ] && [ -d "${BUILD_DIR}" ]; then
    print_status "Cleaning previous build..."
    rm -rf "${BUILD_DIR}"
fi

CROSS_FILE="${BUILD_DIR}/wasm32-emscripten.txt"
mkdir -p "${BUILD_DIR}"

print_status "Generating Meson cross-file for Emscripten..."
cat > "${CROSS_FILE}" <<'EOF'
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
strip = 'emstrip'
ranlib = 'emranlib'

[built-in options]
c_args = ['-Os', '-DHAVE_PTHREAD=0', '-DHAVE_PTY=0', '-DHAVE_FORK=0', '-DHAVE_LIB_RT=0']
c_link_args = ['-sALLOW_MEMORY_GROWTH=1', '-sTOTAL_STACK=8388608', '-sERROR_ON_UNDEFINED_SYMBOLS=0']

[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

print_status "Configuring Rizin for WebAssembly..."

meson setup "${BUILD_DIR}" \
    --cross-file "${CROSS_FILE}" \
    --default-library=static \
    --prefer-static \
    -Dstatic_runtime=true \
    -Duse_sys_capstone=disabled \
    -Duse_sys_magic=disabled \
    -Duse_sys_libzip=disabled \
    -Duse_sys_zlib=disabled \
    -Duse_sys_lz4=disabled \
    -Duse_sys_xxhash=disabled \
    -Duse_sys_openssl=disabled \
    -Duse_sys_tree_sitter=disabled \
    -Duse_sys_pcre2=disabled \
    -Duse_sys_lzma=disabled \
    -Duse_sys_libzstd=disabled \
    -Duse_lzma=false \
    -Duse_zlib=false \
    -Denable_tests=false \
    -Denable_rz_test=false \
    -Dcli=enabled \
    -Dportable=true \
    -Ddebugger=false

print_status "Building Rizin (this may take a while)..."
cd "${BUILD_DIR}"
ninja -j${BUILD_JOBS}

print_status "Packaging..."
mkdir -p "${OUTPUT_DIR}"

TOOLS="rizin rz-bin rz-asm rz-hash rz-diff rz-find rz-ax"
for tool in $TOOLS; do
    src="binrz/${tool}/${tool}.js"
    wasm_src="binrz/${tool}/${tool}.wasm"
    if [ -f "$wasm_src" ]; then
        cp "$wasm_src" "${OUTPUT_DIR}/${tool}.wasm"
        size=$(ls -lh "${OUTPUT_DIR}/${tool}.wasm" | awk '{print $5}')
        print_success "${tool}.wasm (${size})"
    elif [ -f "$src" ]; then
        cp "$src" "${OUTPUT_DIR}/${tool}.js"
        print_success "${tool}.js"
    fi
done

echo "${RIZIN_VERSION}" > "${OUTPUT_DIR}/VERSION"

print_status "Creating release archive..."
cd "${OUTPUT_DIR}"
zip -r "${SCRIPT_DIR}/rizin-${RIZIN_VERSION}-wasm.zip" ./*

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Build Complete!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Output: ${OUTPUT_DIR}"
echo "Archive: rizin-${RIZIN_VERSION}-wasm.zip"
