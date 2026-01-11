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
# IMPORTANT: NO -pthread flag to avoid generating worker.js files
# Web Workers cannot be loaded cross-origin, which breaks our split architecture
# (rizin.js bundled locally, rizin.wasm loaded from GitHub Pages)
c_args = ['-O2', '-DHAVE_PTY=0', '-DHAVE_FORK=0', '-D__EMSCRIPTEN__=1']
# CRITICAL EXPORTS:
# - FS: Filesystem access for mounting files
# - callMain: Allow JavaScript to start the program
# - stdin/stdout handling via print/printErr
c_link_args = ['-sALLOW_MEMORY_GROWTH=1', '-sINITIAL_MEMORY=33554432', '-sTOTAL_STACK=8388608', '-sERROR_ON_UNDEFINED_SYMBOLS=0', '-sMODULARIZE=0', '-sEXPORT_ES6=0', '-sEXPORTED_RUNTIME_METHODS=FS,callMain,ccall,cwrap,print,printErr,setValue,getValue', '-sINVOKE_RUN=0', '-sFORCE_FILESYSTEM=1', '-sEXIT_RUNTIME=0', '-sASSERTIONS=0']

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

# NOTE: Threads dependency patching is done AFTER meson setup by modifying build.ninja directly
# This is more reliable than trying to patch meson.build which has complex dependency detection

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

    # Patch zipint.h to shim memcpy_s and strncpy_s (missing in Emscripten)
    ZIPINT_H="${LIBZIP_DIR}/lib/zipint.h"
    if [ -f "$ZIPINT_H" ]; then
        # Append shims to the end of the file
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
        print_success "Patched zipint.h with secure string shims"
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

# CRITICAL: Patch thread.h to add Emscripten stub types
# Without this, the build fails with "#error Threading library only supported for pthread and w32"
print_status "Patching librz/util/thread.h for Emscripten..."
THREAD_H="${RIZIN_DIR}/librz/util/thread.h"
STUBS_H="${SCRIPT_DIR}/patches/rz_emscripten_thread_stubs.h"

if [ -f "$THREAD_H" ] && [ -f "$STUBS_H" ]; then
    # Copy stubs header to Rizin include directory
    cp "$STUBS_H" "${RIZIN_DIR}/librz/include/rz_emscripten_thread_stubs.h"
    
    # Use awk for reliable multi-line replacement
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
    
    print_success "Patched thread.h with Emscripten stubs"
else
    print_error "Could not find thread.h or stubs header"
fi

# CRITICAL: Patch thread.c to run callbacks synchronously in Emscripten
# The key is to check __EMSCRIPTEN__ FIRST, BEFORE HAVE_PTHREAD
# because Emscripten defines HAVE_PTHREAD for pthread emulation but it hangs
print_status "Patching librz/util/thread.c for Emscripten (synchronous execution)..."
THREAD_C="${RIZIN_DIR}/librz/util/thread.c"
if [ -f "$THREAD_C" ]; then
    # Use Python with regex for flexible pattern matching
    python3 << PYSCRIPT
import re
import sys

filepath = "${THREAD_C}"
with open(filepath, 'r') as f:
    content = f.read()

original = content
modified = False

# Patch rz_th_new: Find "# if HAVE_PTHREAD" followed by pthread_create within rz_th_new function
# Use regex to handle any whitespace variations
pattern_new = r'(RZ_API RZ_OWN RzThread \*rz_th_new\([^}]+?)(#\s*if\s+HAVE_PTHREAD\s*\nif \(!pthread_create)'
def replace_new(m):
    return m.group(1) + """#if defined(__EMSCRIPTEN__)
\t/* Emscripten: Run callback synchronously */
\tth->terminated = false;
\tth->retv = th->function(th->user);
\tth->terminated = true;
\treturn th;
#elif HAVE_PTHREAD
if (!pthread_create"""

content, count = re.subn(pattern_new, replace_new, content, flags=re.DOTALL)
if count > 0:
    print(f"Patched rz_th_new ({count} replacement)")
    modified = True
else:
    print("WARNING: Could not find rz_th_new pattern")

# Patch rz_th_wait: Find "# if HAVE_PTHREAD" followed by void *thret within rz_th_wait function
pattern_wait = r'(RZ_API bool rz_th_wait\([^}]+?)(#\s*if\s+HAVE_PTHREAD\s*\nvoid \*thret)'
def replace_wait(m):
    return m.group(1) + """#if defined(__EMSCRIPTEN__)
\t/* Already executed synchronously */
\treturn true;
#elif HAVE_PTHREAD
void *thret"""

content, count = re.subn(pattern_wait, replace_wait, content, flags=re.DOTALL)
if count > 0:
    print(f"Patched rz_th_wait ({count} replacement)")
    modified = True
else:
    print("WARNING: Could not find rz_th_wait pattern")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
    print("thread.c patching complete!")
else:
    print("ERROR: No patches applied to thread.c")
    # Don't exit with error - try alternative approach below

PYSCRIPT

    # Fallback: If Python regex failed, try simple sed approach  
    if ! grep -q "defined(__EMSCRIPTEN__)" "$THREAD_C"; then
        print_status "Python patch failed, trying sed fallback..."
        # Insert Emscripten check before HAVE_PTHREAD in rz_th_new
        sed -i '/rz_th_new/,/^}$/{
            s/# if HAVE_PTHREAD/# if defined(__EMSCRIPTEN__)\n\t\/* Emscripten: sync *\/\n\tth->terminated = false;\n\tth->retv = th->function(th->user);\n\tth->terminated = true;\n\treturn th;\n# elif HAVE_PTHREAD/
        }' "$THREAD_C"
        sed -i '/rz_th_wait/,/^}$/{
            s/# if HAVE_PTHREAD/# if defined(__EMSCRIPTEN__)\n\treturn true;\n# elif HAVE_PTHREAD/
        }' "$THREAD_C"
    fi

    # Verify patch was applied
    if grep -q "defined(__EMSCRIPTEN__)" "$THREAD_C"; then
        print_success "Patched thread.c for Emscripten synchronous execution"
    else
        print_error "Failed to patch thread.c - Emscripten check not found"
        echo "=== thread.c rz_th_new section ===" 
        sed -n '/rz_th_new/,/^}/p' "$THREAD_C" | head -30
        exit 1  
    fi
fi

# Patch thread_lock.c to be no-ops for Emscripten (single-threaded)
print_status "Patching librz/util/thread_lock.c for Emscripten..."
THREAD_LOCK_C="${RIZIN_DIR}/librz/util/thread_lock.c"
if [ -f "$THREAD_LOCK_C" ]; then
    # Use awk to insert #elif __EMSCRIPTEN__ before #elif __WINDOWS__ in each function
    awk '
    # For rz_th_lock_new: insert before #elif __WINDOWS__
    /^#elif __WINDOWS__/ && !lock_new_done {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no locking needed */"
        lock_new_done = 1
    }
    
    { print }
    ' "$THREAD_LOCK_C" > "${THREAD_LOCK_C}.patched"
    mv "${THREAD_LOCK_C}.patched" "$THREAD_LOCK_C"
    
    # Now patch the individual lock functions - insert before #endif
    awk '
    /rz_th_lock_enter/ { in_lock_enter = 1 }
    /rz_th_lock_tryenter/ { in_lock_enter = 0; in_lock_tryenter = 1 }
    /rz_th_lock_leave/ { in_lock_tryenter = 0; in_lock_leave = 1 }
    /rz_th_lock_free/ { in_lock_leave = 0; in_lock_free = 1 }
    
    /^#endif$/ && in_lock_enter == 1 {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no-op */"
        in_lock_enter = 0
    }
    
    /^#endif$/ && in_lock_tryenter == 1 {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\treturn true; /* Single-threaded: always succeed */"
        in_lock_tryenter = 0
    }
    
    /^#endif$/ && in_lock_leave == 1 {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no-op */"
        in_lock_leave = 0
    }
    
    /^#endif$/ && in_lock_free == 1 {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no-op */"
        in_lock_free = 0
    }
    
    { print }
    ' "$THREAD_LOCK_C" > "${THREAD_LOCK_C}.patched"
    mv "${THREAD_LOCK_C}.patched" "$THREAD_LOCK_C"
    
    print_success "Patched thread_lock.c for Emscripten"
fi

# Patch thread_sem.c for Emscripten
print_status "Patching librz/util/thread_sem.c for Emscripten..."
THREAD_SEM_C="${RIZIN_DIR}/librz/util/thread_sem.c"
if [ -f "$THREAD_SEM_C" ]; then
    # Insert #elif defined(__EMSCRIPTEN__) BEFORE #elif __WINDOWS__ in rz_th_sem_new
    # IMPORTANT: Cannot use #endif matching because there's a nested #if RZ_SEM_NAMED_ONLY block
    awk '
    /rz_th_sem_new/ { in_sem_new = 1 }
    /rz_th_sem_free/ { in_sem_new = 0 }
    
    # Insert BEFORE #elif __WINDOWS__ to avoid nested #if issues
    /^#elif __WINDOWS__/ && in_sem_new == 1 && !sem_new_patched {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no semaphore init needed */"
        sem_new_patched = 1
    }
    
    { print }
    ' "$THREAD_SEM_C" > "${THREAD_SEM_C}.patched"
    mv "${THREAD_SEM_C}.patched" "$THREAD_SEM_C"
    print_success "Patched thread_sem.c for Emscripten"
fi

# Patch thread_cond.c for Emscripten
print_status "Patching librz/util/thread_cond.c for Emscripten..."
THREAD_COND_C="${RIZIN_DIR}/librz/util/thread_cond.c"
if [ -f "$THREAD_COND_C" ]; then
    # Insert #elif defined(__EMSCRIPTEN__) BEFORE #elif __WINDOWS__ in rz_th_cond_new
    awk '
    /rz_th_cond_new/ { in_cond_new = 1 }
    /rz_th_cond_signal/ { in_cond_new = 0 }
    
    /^#elif __WINDOWS__/ && in_cond_new == 1 && !cond_new_patched {
        print "#elif defined(__EMSCRIPTEN__)"
        print "\t/* Single-threaded: no condition var init needed */"
        cond_new_patched = 1
    }
    
    { print }
    ' "$THREAD_COND_C" > "${THREAD_COND_C}.patched"
    mv "${THREAD_COND_C}.patched" "$THREAD_COND_C"
    print_success "Patched thread_cond.c for Emscripten"
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

# CRITICAL: Patch generated build.ninja to remove ALL pthread-related flags
# Meson's threads dependency detection works even on Emscripten and there's no
# clean way to disable it. Instead, we patch the generated ninja files to remove
# all pthread-related linker flags after meson setup completes.
print_status "Removing pthread flags from build.ninja files..."
find "${BUILD_DIR}" -name "*.ninja" -type f | while read ninja_file; do
    # Remove -pthread flag
    sed -i 's/ -pthread//g' "$ninja_file"
    # Remove -sPTHREAD_POOL_SIZE=N flags
    sed -i 's/ -sPTHREAD_POOL_SIZE=[0-9]*//g' "$ninja_file"
    # Remove --shared-memory related flags that require atomics
    sed -i 's/ --shared-memory//g' "$ninja_file"
    sed -i 's/ --import-memory//g' "$ninja_file"
done
print_success "Removed pthread flags from all ninja files"

# Step 4: Patch generated rz_userconf.h to disable Emscripten-incompatible features
print_status "Patching rz_userconf.h for Emscripten..."
USERCONF="${BUILD_DIR}/rz_userconf.h"
if [ -f "$USERCONF" ]; then
    # Disable fork (not available in WASM)
    sed -i 's/#define HAVE_FORK.*1/#define HAVE_FORK 0/g' "$USERCONF"
    # CRITICAL: Disable pthread (we removed -pthread linker flags, so threads don't work)
    sed -i 's/#define HAVE_PTHREAD.*1/#define HAVE_PTHREAD 0/g' "$USERCONF"
    # Disable PTY functions (not available in WASM)
    sed -i 's/#define HAVE_OPENPTY.*1/#define HAVE_OPENPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_FORKPTY.*1/#define HAVE_FORKPTY 0/g' "$USERCONF"
    sed -i 's/#define HAVE_LOGIN_TTY.*1/#define HAVE_LOGIN_TTY 0/g' "$USERCONF"
    # Disable jemalloc heap analysis (jemalloc internals use types not available in Emscripten)
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
