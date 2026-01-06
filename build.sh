#!/bin/bash
# SPDX-FileCopyrightText: 2024 RizinOrg <info@rizin.re>
# SPDX-License-Identifier: LGPL-3.0-only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIZIN_VERSION="${RIZIN_VERSION:-0.7.3}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m✓\033[0m $1"; }

source "${SCRIPT_DIR}/setup.sh" env 2>/dev/null || {
    print_error "Run ./setup.sh install first"
    exit 1
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build Rizin for WebAssembly (WASI)

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
BUILD_DIR="${RIZIN_DIR}/build-wasi"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           rzwasi - Build Rizin for WebAssembly           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Version:   ${RIZIN_VERSION}"
echo "Output:    ${OUTPUT_DIR}"
echo "Jobs:      ${BUILD_JOBS}"
echo ""

if [ ! -d "${RIZIN_DIR}/.git" ]; then
    print_status "Cloning Rizin v${RIZIN_VERSION}..."
    git clone --depth 1 --branch "v${RIZIN_VERSION}" \
        https://github.com/rizinorg/rizin.git "${RIZIN_DIR}"
else
    print_status "Updating Rizin source..."
    cd "${RIZIN_DIR}"
    git fetch --tags
    git checkout "v${RIZIN_VERSION}" 2>/dev/null || git checkout "${RIZIN_VERSION}"
    cd "${SCRIPT_DIR}"
fi

if [ "$CLEAN" = true ] && [ -d "${BUILD_DIR}" ]; then
    print_status "Cleaning previous build..."
    rm -rf "${BUILD_DIR}"
fi

CROSS_FILE="${BUILD_DIR}/wasm32-wasi.txt"
mkdir -p "${BUILD_DIR}"

print_status "Generating Meson cross-file..."
cat > "${CROSS_FILE}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
ranlib = '${RANLIB}'

[built-in options]
c_args = ['-D_WASI_EMULATED_SIGNAL', '-D_WASI_EMULATED_PROCESS_CLOCKS', '-D__wasi__=1', '-DHAVE_PTHREAD=0', '-DHAVE_PTY=0', '-DHAVE_FORK=0', '-Os', '-flto', '--sysroot=${WASI_SYSROOT}', '--target=wasm32-wasi']
c_link_args = ['-flto', '-lwasi-emulated-signal', '-lwasi-emulated-process-clocks', '-Wl,-z,stack-size=8388608', '--sysroot=${WASI_SYSROOT}', '--target=wasm32-wasi']

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

print_status "Configuring Rizin for WASI..."
cd "${RIZIN_DIR}"

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
    -Duse_lzma=false \
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
    src="binrz/${tool}/${tool}"
    if [ -f "$src" ]; then
        cp "$src" "${OUTPUT_DIR}/${tool}.wasm"
        size=$(ls -lh "${OUTPUT_DIR}/${tool}.wasm" | awk '{print $5}')
        print_success "${tool}.wasm (${size})"
    fi
done

echo "${RIZIN_VERSION}" > "${OUTPUT_DIR}/VERSION"

print_status "Creating release archive..."
cd "${OUTPUT_DIR}"
zip -r "${SCRIPT_DIR}/rizin-${RIZIN_VERSION}-wasi.zip" ./*

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Build Complete!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Output: ${OUTPUT_DIR}"
echo "Archive: rizin-${RIZIN_VERSION}-wasi.zip"
