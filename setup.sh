#!/bin/bash
# SPDX-FileCopyrightText: 2024 RizinOrg <info@rizin.re>
# SPDX-License-Identifier: LGPL-3.0-only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASI_SDK_VERSION="${WASI_SDK_VERSION:-24}"
WASI_SDK_PATH="${WASI_SDK_PATH:-${SCRIPT_DIR}/.wasi-sdk}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m✓\033[0m $1"; }

install_wasi_sdk() {
    if [ -d "${WASI_SDK_PATH}/bin" ]; then
        print_success "WASI SDK already installed at ${WASI_SDK_PATH}"
        return 0
    fi

    print_status "Installing WASI SDK ${WASI_SDK_VERSION}..."
    
    local os arch
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) print_error "Unsupported OS"; exit 1 ;;
    esac
    
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) print_error "Unsupported architecture"; exit 1 ;;
    esac

    local ext="tar.gz"
    [ "$os" = "windows" ] && ext="zip"
    
    local url="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/wasi-sdk-${WASI_SDK_VERSION}.0-${arch}-${os}.${ext}"
    
    print_status "Downloading WASI SDK..."
    
    local tmpdir tmpfile
    tmpdir="$(mktemp -d)"
    tmpfile="${tmpdir}/wasi-sdk.${ext}"
    
    curl -fSL --progress-bar -o "$tmpfile" "$url" || wget -q --show-progress -O "$tmpfile" "$url"
    
    print_status "Extracting..."
    mkdir -p "${WASI_SDK_PATH}"
    
    if [ "$ext" = "zip" ]; then
        unzip -q "$tmpfile" -d "$tmpdir"
    else
        tar xzf "$tmpfile" -C "$tmpdir"
    fi
    
    mv "${tmpdir}"/wasi-sdk-*/* "${WASI_SDK_PATH}/"
    rm -rf "$tmpdir"
    
    print_success "WASI SDK installed"
}

export_env() {
    export WASI_SDK_PATH
    export WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
    export CC="${WASI_SDK_PATH}/bin/clang"
    export CXX="${WASI_SDK_PATH}/bin/clang++"
    export AR="${WASI_SDK_PATH}/bin/ar"
    export RANLIB="${WASI_SDK_PATH}/bin/ranlib"
    export STRIP="${WASI_SDK_PATH}/bin/strip"
    export NM="${WASI_SDK_PATH}/bin/nm"
    
    if [ ! -x "$CC" ]; then
        print_error "WASI SDK not installed. Run: $0 install"
        return 1
    fi
}

case "${1:-install}" in
    install) install_wasi_sdk ;;
    env) export_env ;;
    *) echo "Usage: $0 {install|env}"; exit 1 ;;
esac
