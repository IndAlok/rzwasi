#!/bin/bash
# SPDX-FileCopyrightText: 2024 IndAlok
# SPDX-License-Identifier: LGPL-3.0-only

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

if [ ! -d "${RIZIN_DIR}/.git" ]; then
    if [ "$RIZIN_VERSION" = "nightly" ]; then
        print_status "Cloning Rizin (nightly/HEAD)..."
        git clone --depth 1 https://github.com/rizinorg/rizin.git "${RIZIN_DIR}"
    else
        print_status "Cloning Rizin v${RIZIN_VERSION}..."
        git clone --depth 1 --branch "v${RIZIN_VERSION}" \
            https://github.com/rizinorg/rizin.git "${RIZIN_DIR}"
    fi
fi

cd "${RIZIN_DIR}"

if [ "$CLEAN" = true ] && [ -d "${BUILD_DIR}" ]; then
    rm -rf "${BUILD_DIR}"
fi

CROSS_FILE="${RIZIN_DIR}/wasm32-emscripten.txt"
cat > "${CROSS_FILE}" <<'EOF'
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
strip = 'emstrip'
ranlib = 'emranlib'

[built-in options]
c_args = ['-O2', '-DHAVE_PTY=0', '-DHAVE_FORK=0', '-D__EMSCRIPTEN__=1']
c_link_args = ['-sALLOW_MEMORY_GROWTH=1', '-sINITIAL_MEMORY=33554432', '-sTOTAL_STACK=8388608', '-sERROR_ON_UNDEFINED_SYMBOLS=0', '-sMODULARIZE=0', '-sEXPORT_ES6=0', '-sEXPORTED_RUNTIME_METHODS=FS,callMain,ccall,cwrap,print,printErr,setValue,getValue', '-sINVOKE_RUN=0', '-sFORCE_FILESYSTEM=1', '-sEXIT_RUNTIME=0', '-sASSERTIONS=0']

[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

print_status "Patching meson.build..."
sed -i "s/have_lrt = not \['windows', 'darwin', 'openbsd', 'android', 'haiku'\]/have_lrt = not ['windows', 'darwin', 'openbsd', 'android', 'haiku', 'emscripten']/g" meson.build 2>/dev/null || true
sed -i "s/have_ptrace = not \['windows', 'cygwin', 'sunos', 'haiku'\]/have_ptrace = not ['windows', 'cygwin', 'sunos', 'haiku', 'emscripten']/g" meson.build 2>/dev/null || true

print_status "Downloading subprojects..."
meson subprojects download || true

print_status "Patching libzip for Emscripten..."
LIBZIP_DIR=$(find subprojects -maxdepth 1 -name "libzip-*" -type d 2>/dev/null | head -1)

if [ -n "$LIBZIP_DIR" ] && [ -d "$LIBZIP_DIR" ]; then
    cat > "${LIBZIP_DIR}/lib/zip_random_unix.c" << 'RANDPATCH'
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

    STDIO_FILE="${LIBZIP_DIR}/lib/zip_source_file_stdio_named.c"
    if [ -f "$STDIO_FILE" ]; then
        sed -i '/#include <sys\/attr.h>/d' "$STDIO_FILE"
        sed -i 's/#ifdef HAVE_CLONEFILE/#if 0/g' "$STDIO_FILE"
        print_success "Patched zip_source_file_stdio_named.c"
    fi

    ZIPINT_H="${LIBZIP_DIR}/lib/zipint.h"
    if [ -f "$ZIPINT_H" ]; then
        cat >> "$ZIPINT_H" << 'EOF'

#ifdef __EMSCRIPTEN__
#include <string.h>
#ifndef memcpy_s
#define memcpy_s(dest, destsz, src, count) memcpy(dest, src, count)
#endif
#ifndef strncpy_s
#define strncpy_s(dest, destsz, src, count) strncpy(dest, src, count)
#endif
#ifndef strerror_s
#define strerror_s(buf, bufsz, errnum) (strncpy(buf, strerror(errnum), bufsz), buf[(bufsz)-1] = '\0', 0)
#endif
#endif
EOF
        print_success "Patched zipint.h"
    fi
else
    print_error "libzip not found"
fi

print_status "Patching Rizin source..."
HEAP_JEM_H="${RIZIN_DIR}/librz/include/rz_heap_jemalloc.h"
if [ -f "$HEAP_JEM_H" ]; then
    sed -i 's|#include <rz_jemalloc/internal/jemalloc_internal.h>|#ifndef __EMSCRIPTEN__\n#include <rz_jemalloc/internal/jemalloc_internal.h>\n#endif|g' "$HEAP_JEM_H"
    print_success "Patched rz_heap_jemalloc.h"
fi

print_status "Patching sys.c..."
SYS_C="${RIZIN_DIR}/librz/util/sys.c"
if [ -f "$SYS_C" ]; then
    sed -i '1s/^/#ifdef __EMSCRIPTEN__\n#include <emscripten.h>\n#endif\n/' "$SYS_C"
    sed -i 's|#include <execinfo.h>|#ifndef __EMSCRIPTEN__\n#include <execinfo.h>\n#endif|g' "$SYS_C"
    sed -i 's|#if HAVE_BACKTRACE|#if HAVE_BACKTRACE \&\& !defined(__EMSCRIPTEN__)|g' "$SYS_C"
    sed -i 's~#warning TODO: rz_sys_backtrace : unimplemented~#ifdef __EMSCRIPTEN__\n\tchar buf[1024];\n\tint len = emscripten_get_callstack(EM_LOG_C_STACK | EM_LOG_JS_STACK, buf, sizeof(buf));\n\tif (len > 0) { eprintf("%s\\n", buf); }\n\treturn;\n#else\n#warning TODO: rz_sys_backtrace : unimplemented\n#endif~g' "$SYS_C"
    print_success "Patched sys.c"
fi

print_status "Patching thread.h..."
THREAD_H="${RIZIN_DIR}/librz/util/thread.h"
STUBS_H="${SCRIPT_DIR}/patches/rz_emscripten_thread_stubs.h"

if [ -f "$THREAD_H" ] && [ -f "$STUBS_H" ]; then
    cp "$STUBS_H" "${RIZIN_DIR}/librz/include/rz_emscripten_thread_stubs.h"
    
    awk '
    /#error Threading library only supported for pthread and w32/ {
        print "#ifdef __EMSCRIPTEN__"
        print "#include <rz_emscripten_thread_stubs.h>"
        print "#else"
        print $0
        print "#endif"
        next
    }
    { print }
    ' "$THREAD_H" > "${THREAD_H}.patched"
    mv "${THREAD_H}.patched" "$THREAD_H"
    
    print_success "Patched thread.h"
else
    print_error "Could not find thread.h or stubs header"
fi

print_status "Patching thread files (Python)..."
PATCH_SCRIPT="${SCRIPT_DIR}/patches/patch_threads.py"
if [ -f "$PATCH_SCRIPT" ]; then
    python3 "$PATCH_SCRIPT" "$RIZIN_DIR"
    if [ $? -ne 0 ]; then
        print_error "Python thread patching failed!"
        exit 1
    fi
    print_success "Thread files patched"
else
    print_error "Could not find patch_threads.py script!"
    exit 1
fi

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

print_status "Removing pthread flags..."
find "${BUILD_DIR}" -name "*.ninja" -type f | while read ninja_file; do
    sed -i 's/ -pthread//g' "$ninja_file"
    sed -i 's/ -sPTHREAD_POOL_SIZE=[0-9]*//g' "$ninja_file"
    sed -i 's/ --shared-memory//g' "$ninja_file"
    sed -i 's/ --import-memory//g' "$ninja_file"
done
print_success "Pthread flags removed"

print_status "Patching rz_userconf.h..."
USERCONF="${BUILD_DIR}/rz_userconf.h"
if [ -f "$USERCONF" ]; then
    sed -i 's/#define HAVE_FORK.*1/#define HAVE_FORK 0/g' "$USERCONF"
    sed -i 's/#define HAVE_PTHREAD.*1/#define HAVE_PTHREAD 0/g' "$USERCONF"
    sed -i 's/#define HAVE_OPENPTY.*1/#define HAVE_OPENPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_FORKPTY.*1/#define HAVE_FORKPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_LOGIN_TTY.*1/#define HAVE_LOGIN_TTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_JEMALLOC.*1/#define HAVE_JEMALLOC 0/g' "$USERCONF"
    print_success "Patched rz_userconf.h"
fi

print_status "Building Rizin..."
cd "${BUILD_DIR}"
ninja -j${BUILD_JOBS}

print_status "Packaging..."
mkdir -p "${OUTPUT_DIR}"
for tool in rizin rz-bin rz-asm rz-hash rz-diff rz-find rz-ax; do
    for ext in wasm js; do
        src="binrz/${tool}/${tool}.${ext}"
        [ -f "$src" ] && cp "$src" "${OUTPUT_DIR}/" && print_success "${tool}.${ext}"
    done
done
echo "${RIZIN_VERSION}" > "${OUTPUT_DIR}/VERSION"

if command -v zip >/dev/null; then
    print_status "Creating ZIP..."
    ZIP_NAME="rizin-${RIZIN_VERSION}-wasm.zip"
    (cd "${OUTPUT_DIR}" && zip -r "../${ZIP_NAME}" .)
    print_success "Created ${ZIP_NAME}"
fi

echo ""
print_success "Build complete! Output: ${OUTPUT_DIR}"
