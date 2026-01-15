#!/bin/bash
# SPDX-FileCopyrightText: 2024 IndAlok
# SPDX-License-Identifier: LGPL-3.0-only

set -e

EMSDK_VERSION="${EMSDK_VERSION:-3.1.50}"
EMSDK_DIR="${EMSDK_DIR:-${HOME}/.emsdk}"

print_status() { echo -e "\033[1;34m==>\033[0m $1"; }
print_error() { echo -e "\033[1;31mError:\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m✓\033[0m $1"; }

install_emsdk() {
    print_status "Installing Emscripten SDK ${EMSDK_VERSION}..."
    
    if [ ! -d "${EMSDK_DIR}" ]; then
        print_status "Cloning emsdk..."
        git clone https://github.com/emscripten-core/emsdk.git "${EMSDK_DIR}"
    fi
    
    cd "${EMSDK_DIR}"
    git pull 2>/dev/null || true
    ./emsdk install ${EMSDK_VERSION}
    ./emsdk activate ${EMSDK_VERSION}
    
    print_success "Emscripten SDK installed"
}

activate_emsdk() {
    if [ ! -d "${EMSDK_DIR}" ]; then
        print_error "emsdk not found at ${EMSDK_DIR}"
        print_status "Run: $0 install"
        return 1
    fi
    
    source "${EMSDK_DIR}/emsdk_env.sh" 2>/dev/null
    
    if command -v emcc &> /dev/null; then
        print_success "Emscripten activated: $(emcc --version | head -1)"
        return 0
    else
        print_error "Failed to activate Emscripten"
        return 1
    fi
}

export_env() {
    if [ ! -d "${EMSDK_DIR}" ]; then
        print_error "emsdk not found"
        return 1
    fi
    
    source "${EMSDK_DIR}/emsdk_env.sh" 2>/dev/null
    
    export CC="emcc"
    export CXX="em++"
    export AR="emar"
    export RANLIB="emranlib"
    export STRIP="emstrip"
}

case "${1:-env}" in
    install) install_emsdk ;;
    activate) activate_emsdk ;;
    env) export_env ;;
    *)
        echo "Usage: $0 {install|activate|env}"
        exit 1
        ;;
esac
