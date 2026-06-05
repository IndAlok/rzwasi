#!/bin/bash
# SPDX-FileCopyrightText: 2024 IndAlok
# SPDX-License-Identifier: LGPL-3.0-only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '\r\n' || echo "0.8.2")
RIZIN_VERSION="${RIZIN_VERSION:-$DEFAULT_VERSION}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# Optional jsdec decompiler (rizinorg/jsdec -> the `pdd` command). OFF by default.
ENABLE_JSDEC="${ENABLE_JSDEC:-0}"
JSDEC_VERSION="${JSDEC_VERSION:-0.8.0}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32mâœ“\033[0m $1"; }

# build_jsdec_wasm: compile the jsdec decompiler into ${JSDEC_STATIC_LIB}.
build_jsdec_wasm() {
    print_status "Building jsdec decompiler (experimental)..."

    if [ ! -d "${JSDEC_DIR}/.git" ]; then
        print_status "Cloning jsdec v${JSDEC_VERSION}..."
        git clone --depth 1 --branch "v${JSDEC_VERSION}" \
            https://github.com/rizinorg/jsdec.git "${JSDEC_DIR}"
    fi

    local gen_dir="${JSDEC_DIR}/.gen"
    local native_build="${JSDEC_DIR}/.build-native"
    local wasm_obj="${JSDEC_DIR}/.obj-wasm"
    local qjs_dir="${JSDEC_DIR}/subprojects/libquickjs"

    (
        cd "${JSDEC_DIR}"

        print_status "jsdec: downloading subprojects (quickjs-ng)..."
        meson subprojects download

        # Native codegen tools only. build_type=standalone avoids any rizin dep.
        print_status "jsdec: building native qjsc + modjs_gen..."
        rm -rf "${native_build}"
        CC=cc CC_FOR_BUILD=cc meson setup "${native_build}" -Dbuild_type=standalone >/dev/null
        ninja -C "${native_build}" qjsc modjs_gen

        print_status "jsdec: generating bytecode headers..."
        mkdir -p "${gen_dir}/js"
        "${native_build}/qjsc" -m -N main_bytecode -o "${gen_dir}/js/bytecode.h" "js/jsdec-plugin.js"
        "${native_build}/modjs_gen" "${gen_dir}/js/bytecode.h" "${gen_dir}/js/bytecode_mod.h"
    )

    # Reuse rizin's exact -I/-D flags so jsdec sees the same rizin headers.
    print_status "jsdec: collecting rizin compile flags..."
    local rizin_flags
    rizin_flags=$(python3 - "${BUILD_DIR}/compile_commands.json" <<'PY'
import json, os, shlex, sys

with open(sys.argv[1]) as f:
    entries = json.load(f)

# Pick any core/librz object so we inherit the full rizin include + define set.
chosen = None
for e in entries:
    f = e.get("file", "")
    if "/librz/" in f.replace("\\", "/"):
        chosen = e
        if "/librz/core/" in f.replace("\\", "/"):
            break
if not chosen:
    chosen = entries[0]

directory = chosen.get("directory", ".")
args = chosen.get("arguments") or shlex.split(chosen.get("command", ""))

out = []
i = 0
while i < len(args):
    a = args[i]
    if a.startswith("-I"):
        val = a[2:] or (args[i + 1] if i + 1 < len(args) else "")
        if a == "-I":
            i += 1
        if val and not os.path.isabs(val):
            val = os.path.normpath(os.path.join(directory, val))
        out.append("-I" + val)
    elif a.startswith("-D"):
        out.append(a)
    i += 1

# De-dup, preserve order.
seen = set()
print(" ".join(x for x in out if not (x in seen or seen.add(x))))
PY
    )

    rm -rf "${wasm_obj}"
    mkdir -p "${wasm_obj}"

    # quickjs-ng core. NOTE (experimental): single-threaded emscripten, the JS
    # engine is compiled without -pthread
    local qjs_args="-O2 -D__EMSCRIPTEN__=1 -D_GNU_SOURCE=1 -fvisibility=hidden -Wno-implicit-fallthrough -Wno-sign-compare -Wno-unused-parameter -I${qjs_dir}"
    print_status "jsdec: compiling quickjs-ng (wasm)..."
    for src in cutils libbf libregexp libunicode quickjs; do
        emcc ${qjs_args} -c "${qjs_dir}/${src}.c" -o "${wasm_obj}/qjs_${src}.o"
    done

    # jsdec C sources. -DCORELIB drops the dlopen `rizin_plugin` struct, leaving
    # rz_core_plugin_jsdec for static linking. gen_dir provides "js/bytecode*.h".
    local jsdec_inc="-I${JSDEC_DIR} -I${JSDEC_DIR}/c -I${JSDEC_DIR}/include -I${qjs_dir} -I${gen_dir}"
    print_status "jsdec: compiling plugin sources (wasm)..."
    for src in jsdec base64 jsdec-plugin; do
        emcc -O2 -D__EMSCRIPTEN__=1 -DCORELIB ${jsdec_inc} ${rizin_flags} \
            -c "${JSDEC_DIR}/c/${src}.c" -o "${wasm_obj}/jsdec_${src//-/_}.o"
    done

    print_status "jsdec: archiving ${JSDEC_STATIC_LIB##*/}..."
    rm -f "${JSDEC_STATIC_LIB}"
    emar rcs "${JSDEC_STATIC_LIB}" "${wasm_obj}"/*.o
    print_success "jsdec static library ready"
}

CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) RIZIN_VERSION="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -j|--jobs) BUILD_JOBS="$2"; shift 2 ;;
        -c|--clean) CLEAN=true; shift ;;
        --jsdec) ENABLE_JSDEC=1; shift ;;
        -h|--help) echo "Usage: $0 [-v VER] [-o DIR] [-j N] [-c] [--jsdec] [-h]"; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

RIZIN_DIR="${SCRIPT_DIR}/.rizin-src"
BUILD_DIR="${RIZIN_DIR}/build-wasm"
JSDEC_DIR="${SCRIPT_DIR}/.jsdec-src"
# Static archive the jsdec WASM objects are bundled into; the rizin link step
# pulls it in.
JSDEC_STATIC_LIB="${BUILD_DIR}/libjsdec.a"

echo "â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—"
echo "â•‘           rzwasi - Build Rizin for WebAssembly           â•‘"
echo "â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
echo "Version: ${RIZIN_VERSION} | Jobs: ${BUILD_JOBS}"
if [ "${ENABLE_JSDEC}" = "1" ]; then
    echo "jsdec decompiler: ENABLED (v${JSDEC_VERSION}, experimental)"
else
    echo "jsdec decompiler: disabled (set ENABLE_JSDEC=1 or pass --jsdec)"
fi
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
c_link_args = ['-sALLOW_MEMORY_GROWTH=1', '-sINITIAL_MEMORY=33554432', '-sTOTAL_STACK=8388608', '-sERROR_ON_UNDEFINED_SYMBOLS=0', '-sMODULARIZE=0', '-sEXPORT_ES6=0', '-sEXPORTED_RUNTIME_METHODS=FS,callMain,ccall,cwrap,print,printErr,setValue,getValue', '-sEXPORTED_FUNCTIONS=_main,_malloc,_free', '-sINVOKE_RUN=0', '-sFORCE_FILESYSTEM=1', '-sEXIT_RUNTIME=0', '-sASSERTIONS=0']

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

    COMPAT_H="${LIBZIP_DIR}/lib/compat.h"
    if [ -f "$COMPAT_H" ]; then
        sed -i 's/^#ifndef HAVE_FTELLO$/#if !defined(HAVE_FTELLO) \&\& !defined(__EMSCRIPTEN__)/' "$COMPAT_H"
        print_success "Patched compat.h"
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
SESSION_API_SRC="${SCRIPT_DIR}/patches/rzweb_session_api.c"
SESSION_API_DEST="${RIZIN_DIR}/binrz/rizin/rzweb_session_api.c"
RIZIN_MESON="${RIZIN_DIR}/binrz/rizin/meson.build"
RZWEB_EXPORTED_FUNCTIONS="_main,_malloc,_free,_rzweb_create_session,_rzweb_close_session,_rzweb_open_file,_rzweb_cmd,_rzweb_get_seek,_rzweb_save_project,_rzweb_load_project,_rzweb_get_last_error,_rzweb_autocomplete,_rzweb_get_command_catalog"

if [ -f "$SESSION_API_SRC" ]; then
    cp "$SESSION_API_SRC" "$SESSION_API_DEST"
    JSDEC_LINK_LIB=""
    if [ "${ENABLE_JSDEC}" = "1" ]; then
        JSDEC_LINK_LIB="${JSDEC_STATIC_LIB}"
    fi
    python3 - "$RIZIN_MESON" "$RZWEB_EXPORTED_FUNCTIONS" "$JSDEC_LINK_LIB" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
exports = sys.argv[2]
jsdec_lib = sys.argv[3] if len(sys.argv) > 3 else ""
text = path.read_text()
original = text

single_source = "rizin_exe = executable('rizin', 'rizin.c',"
wrapped_sources = "rizin_exe = executable('rizin', ['rizin.c', 'rzweb_session_api.c'],"

if single_source in text:
    text = text.replace(single_source, wrapped_sources, 1)
elif wrapped_sources not in text:
    raise SystemExit("Could not find rizin executable definition to patch")

target_start = text.find("rizin_exe = executable('rizin'")
if target_start == -1:
    raise SystemExit("Could not locate rizin executable block")

target_end = text.find("\n)\n", target_start)
if target_end == -1:
    raise SystemExit("Could not find end of rizin executable block")

block = text[target_start:target_end + 3]

# When jsdec is enabled, append its prebuilt static archive to the link line and
# define RZWEB_ENABLE_JSDEC so rzweb_session_api.c registers the plugin.
link_items = [f"'-sEXPORTED_FUNCTIONS={exports}'"]
if jsdec_lib:
    link_items.append(repr(jsdec_lib))
link_args_line = f"  link_args: [{', '.join(link_items)}],\n"

if "link_args:" in block:
    block = re.sub(r"  link_args: \[[^\n]*\],\n", link_args_line, block, count=1)
else:
    marker = "  install: true,\n"
    if marker not in block:
        raise SystemExit("Could not find install marker in rizin executable block")
    block = block.replace(marker, link_args_line + marker, 1)

if jsdec_lib and "RZWEB_ENABLE_JSDEC" not in block:
    c_args_line = "  c_args: ['-DRZWEB_ENABLE_JSDEC'],\n"
    marker = "  install: true,\n"
    if marker in block:
        block = block.replace(marker, c_args_line + marker, 1)

if block != text[target_start:target_end + 3]:
    text = text[:target_start] + block + text[target_end + 3:]

if text != original:
    path.write_text(text)
PY
    print_success "Patched rizin target for rzweb persistent session exports"
else
    print_error "Could not find rzweb_session_api.c"
    exit 1
fi

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

print_status "Patching io_shm.c..."
IO_SHM_C="${RIZIN_DIR}/librz/io/p/io_shm.c"
if [ -f "$IO_SHM_C" ]; then
    python3 - "$IO_SHM_C" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

text = text.replace(
    "#if HAVE_HEADER_LINUX_ASHMEM_H || HAVE_HEADER_SYS_SHM_H || __WINDOWS__",
    "#if (HAVE_HEADER_LINUX_ASHMEM_H || HAVE_HEADER_SYS_SHM_H || __WINDOWS__) && !defined(__EMSCRIPTEN__)",
    1,
)
text = text.replace("shm->id = atoi(ptr);", "shm->id = atoi(name);")
text = text.replace("rz_str_djb2_hash(ptr);", "rz_str_djb2_hash(name);")

if text != original:
    path.write_text(text)
PY
    print_success "Patched io_shm.c"
fi

print_status "Patching cons.c for Emscripten output..."
CONS_C="${RIZIN_DIR}/librz/cons/cons.c"
if [ -f "$CONS_C" ]; then
    # Add emscripten.h include at the top
    if ! grep -q "include <emscripten.h>" "$CONS_C"; then
        sed -i '1s/^/#ifdef __EMSCRIPTEN__\n#include <emscripten.h>\n#endif\n/' "$CONS_C"
    fi
    
    # Replace __cons_write_ll to use EM_ASM for WASM output
    # Find the function and add Emscripten-specific code at the start
    sed -i '/^static inline void __cons_write_ll(const char \*buf, int len) {$/,/^#if __WINDOWS__/ {
        /^static inline void __cons_write_ll(const char \*buf, int len) {$/ {
            a\
#ifdef __EMSCRIPTEN__\
	if (len > 0) {\
		char *tmp = malloc(len + 1);\
		if (tmp) {\
			memcpy(tmp, buf, len);\
			tmp[len] = '"'"'\\0'"'"';\
			EM_ASM({ if (Module.print) Module.print(UTF8ToString($0)); }, tmp);\
			free(tmp);\
		}\
	}\
	return;\
#endif
        }
    }' "$CONS_C"
    print_success "Patched cons.c"
else
    print_error "cons.c not found"
fi

print_status "Patching thread.h..."
THREAD_H="${RIZIN_DIR}/librz/util/thread.h"
STUBS_H="${SCRIPT_DIR}/patches/rz_emscripten_thread_stubs.h"

if [ -f "$THREAD_H" ] && [ -f "$STUBS_H" ]; then
    cp "$STUBS_H" "${RIZIN_DIR}/librz/include/rz_emscripten_thread_stubs.h"
    
    # Patch 1: Replace #error with Emscripten include
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
    
    # Patch 2: Wrap struct rz_th_t so Emscripten uses stubs struct with terminated field
    sed -i 's/^struct rz_th_t {/#ifndef __EMSCRIPTEN__\nstruct rz_th_t {/' "$THREAD_H"
    sed -i '/struct rz_th_t {/,/^};/{s/^};$/};\n#endif/}' "$THREAD_H"
    
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

# jsdec must be built here, after meson setup (rizin gen headers +
# compile_commands.json exist, userconf is patched) and before ninja links rizin.
if [ "${ENABLE_JSDEC}" = "1" ]; then
    build_jsdec_wasm
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
