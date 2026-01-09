#!/bin/bash
# SPDX-FileCopyrightText: 2024 RizinOrg <info@rizin.re>
# SPDX-License-Identifier: LGPL-3.0-only
#
# Build Rizin for WebAssembly using Emscripten

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIZIN_VERSION="${RIZIN_VERSION:-0.7.3}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m✓\033[0m $1"; }

CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) RIZIN_VERSION="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -j|--jobs) BUILD_JOBS="$2"; shift 2 ;;
        -c|--clean) CLEAN=true; shift ;;
        -h|--help) echo "Usage: $0 [-v VER] [-o DIR] [-j N] [-c] [-h]"; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

RIZIN_DIR="${SCRIPT_DIR}/.rizin-src"
BUILD_DIR="${RIZIN_DIR}/build-wasm"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           rzwasi - Build Rizin for WebAssembly           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "Version: ${RIZIN_VERSION} | Jobs: ${BUILD_JOBS}"
echo ""

if ! command -v emcc &> /dev/null; then
    print_error "Emscripten not found. Install emsdk first."
    exit 1
fi
print_status "Emscripten: $(emcc --version | head -1)"

# Clone Rizin
if [ ! -d "${RIZIN_DIR}/.git" ]; then
    print_status "Cloning Rizin v${RIZIN_VERSION}..."
    git clone --depth 1 --branch "v${RIZIN_VERSION}" \
        https://github.com/rizinorg/rizin.git "${RIZIN_DIR}"
fi

cd "${RIZIN_DIR}"

# Clean if requested
if [ "$CLEAN" = true ] && [ -d "${BUILD_DIR}" ]; then
    rm -rf "${BUILD_DIR}"
fi

# Store cross-file outside build directory to avoid meson conflicts
CROSS_FILE="${RIZIN_DIR}/wasm32-emscripten.txt"
cat > "${CROSS_FILE}" <<'EOF'
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
strip = 'emstrip'
ranlib = 'emranlib'

[built-in options]
# CRITICAL: -pthread must be in BOTH c_args AND c_link_args
# This ensures ALL object files are compiled with atomics/bulk-memory features
# Without this, wasm-ld fails with "--shared-memory is disallowed" errors
c_args = ['-Os', '-pthread', '-DHAVE_PTY=0', '-DHAVE_FORK=0', '-D__EMSCRIPTEN__=1']
c_link_args = ['-pthread', '-sALLOW_MEMORY_GROWTH=1', '-sINITIAL_MEMORY=33554432', '-sTOTAL_STACK=8388608', '-sERROR_ON_UNDEFINED_SYMBOLS=0']

[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

# Patch main meson.build
print_status "Patching meson.build..."
sed -i "s/have_lrt = not \['windows', 'darwin', 'openbsd', 'android', 'haiku'\]/have_lrt = not ['windows', 'darwin', 'openbsd', 'android', 'haiku', 'emscripten']/g" meson.build 2>/dev/null || true
sed -i "s/have_ptrace = not \['windows', 'cygwin', 'sunos', 'haiku'\]/have_ptrace = not ['windows', 'cygwin', 'sunos', 'haiku', 'emscripten']/g" meson.build 2>/dev/null || true

# Step 1: Initial meson setup to download subprojects (may fail, that's ok)
print_status "Downloading subprojects..."
meson subprojects download || true

# Step 2: Patch libzip source files
print_status "Patching libzip for Emscripten..."
LIBZIP_DIR=$(find subprojects -maxdepth 1 -name "libzip-*" -type d 2>/dev/null | head -1)

if [ -n "$LIBZIP_DIR" ] && [ -d "$LIBZIP_DIR" ]; then
    # Replace zip_random_unix.c with Emscripten-compatible version
    cat > "${LIBZIP_DIR}/lib/zip_random_unix.c" << 'RANDPATCH'
/* zip_random_unix.c - Emscripten-compatible random (patched) */
#include <stdlib.h>
#include <time.h>
#include "zipint.h"

static int seeded = 0;

ZIP_EXTERN bool
zip_secure_random(zip_uint8_t *buffer, zip_uint16_t length) {
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    for (zip_uint16_t i = 0; i < length; i++) {
        buffer[i] = (zip_uint8_t)(rand() & 0xFF);
    }
    return true;
}

ZIP_EXTERN zip_uint32_t
zip_random_uint32(void) {
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    return ((zip_uint32_t)rand() << 16) | (rand() & 0xFFFF);
}
RANDPATCH
    print_success "Patched zip_random_unix.c"

    # Patch zip_source_file_stdio_named.c to remove sys/attr.h
    STDIO_FILE="${LIBZIP_DIR}/lib/zip_source_file_stdio_named.c"
    if [ -f "$STDIO_FILE" ]; then
        sed -i '/#include <sys\/attr.h>/d' "$STDIO_FILE"
        sed -i 's/#ifdef HAVE_CLONEFILE/#if 0/g' "$STDIO_FILE"
        print_success "Patched zip_source_file_stdio_named.c"
    fi
else
    print_error "libzip not found - subprojects may not have downloaded"
fi

# Patch rz_heap_jemalloc.h to skip jemalloc internals for Emscripten
# The jemalloc headers have types (nstime_t, JM_NBINS, NPSIZES) that don't exist in Emscripten
print_status "Patching Rizin source for Emscripten compatibility..."
HEAP_JEM_H="${RIZIN_DIR}/librz/include/rz_heap_jemalloc.h"
if [ -f "$HEAP_JEM_H" ]; then
    # Guard the problematic jemalloc include
    sed -i 's|#include <rz_jemalloc/internal/jemalloc_internal.h>|#ifndef __EMSCRIPTEN__\n#include <rz_jemalloc/internal/jemalloc_internal.h>\n#endif|g' "$HEAP_JEM_H"
    print_success "Patched rz_heap_jemalloc.h"
fi

# Patch librz/util/sys.c to implement backtrace using Emscripten API
# We inject the implementation directly into the source
print_status "Patching librz/util/sys.c for WASM backtrace..."
SYS_C="${RIZIN_DIR}/librz/util/sys.c"
if [ -f "$SYS_C" ]; then
    # Add include at the top
    sed -i '1s/^/#ifdef __EMSCRIPTEN__\n#include <emscripten.h>\n#endif\n/' "$SYS_C"
    
    # Guard execinfo.h include (not available in Emscripten)
    sed -i 's|#include <execinfo.h>|#ifndef __EMSCRIPTEN__\n#include <execinfo.h>\n#endif|g' "$SYS_C"

    # Guard the HAVE_BACKTRACE block to exclude Emscripten
    # This prevents the standard backtrace() calls from being compiled
    sed -i 's|#if HAVE_BACKTRACE|#if HAVE_BACKTRACE \&\& !defined(__EMSCRIPTEN__)|g' "$SYS_C"
    
    # Replace the TODO warning with actual implementation
    # The pattern matches the warning line in rz_sys_backtrace function
    # We use ~ as delimiter because the C code contains | (bitwise OR)
    sed -i 's~#warning TODO: rz_sys_backtrace : unimplemented~#ifdef __EMSCRIPTEN__\n\tchar buf[1024];\n\tint len = emscripten_get_callstack(EM_LOG_C_STACK | EM_LOG_JS_STACK, buf, sizeof(buf));\n\tif (len > 0) { eprintf("%s\\n", buf); }\n\treturn;\n#else\n#warning TODO: rz_sys_backtrace : unimplemented\n#endif~g' "$SYS_C"
    print_success "Patched librz/util/sys.c for WASM backtrace"
fi

# Step 3: Clean build directory and run full meson setup
print_status "Configuring Rizin..."
rm -rf "${BUILD_DIR}"
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

# Step 4: Patch generated rz_userconf.h to disable Emscripten-incompatible features
# We keep HAVE_PTHREAD=1 as Emscripten supports it (with -pthread flag passed to both compiler and linker)
print_status "Patching rz_userconf.h for Emscripten..."
USERCONF="${BUILD_DIR}/rz_userconf.h"
if [ -f "$USERCONF" ]; then
    # Disable fork (not available in WASM)
    sed -i 's/#define HAVE_FORK.*1/#define HAVE_FORK 0/g' "$USERCONF"
    # Enable HAVE_BACKTRACE (we implemented it in sys.c)
    # sed -i 's/#define HAVE_BACKTRACE.*1/#define HAVE_BACKTRACE 0/g' "$USERCONF"
    # Disable PTY functions (not available in WASM)
    sed -i 's/#define HAVE_OPENPTY.*1/#define HAVE_OPENPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_FORKPTY.*1/#define HAVE_FORKPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_LOGIN_TTY.*1/#define HAVE_LOGIN_TTY 0/g' "$USERCONF"
    # Disable jemalloc heap analysis (jemalloc internals use types not available in Emscripten)
    # This does NOT affect Rizin's own memory allocator, only the debugging of external jemalloc heaps
    sed -i 's/#define HAVE_JEMALLOC.*1/#define HAVE_JEMALLOC 0/g' "$USERCONF"
    print_success "Patched rz_userconf.h"
fi

# Step 5: Build
print_status "Building Rizin..."
cd "${BUILD_DIR}"
ninja -j${BUILD_JOBS}

# Step 5: Package
print_status "Packaging..."
mkdir -p "${OUTPUT_DIR}"
for tool in rizin rz-bin rz-asm rz-hash rz-diff rz-find rz-ax; do
    for ext in wasm js; do
        src="binrz/${tool}/${tool}.${ext}"
        [ -f "$src" ] && cp "$src" "${OUTPUT_DIR}/" && print_success "${tool}.${ext}"
    done
done
echo "${RIZIN_VERSION}" > "${OUTPUT_DIR}/VERSION"

# Create ZIP artifact for release
if command -v zip >/dev/null; then
    print_status "Creating ZIP artifact..."
    ZIP_NAME="rizin-${RIZIN_VERSION}-wasm.zip"
    (cd "${OUTPUT_DIR}" && zip -r "../${ZIP_NAME}" .)
    print_success "Created ${ZIP_NAME}"
else
    print_error "zip command not found, skipping zip creation"
fi

echo ""
print_success "Build complete! Output: ${OUTPUT_DIR}"
