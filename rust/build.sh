#!/bin/bash
# Builds the Rust core; leaves libnc_core.a in rust/target/release so Xcode can link it.
#
# Toolchain lookup: $NC_RUST_TOOLCHAIN, then cargo on PATH, then the isolated toolchain from the
# rewrite evaluation (nc-rewrite-eval/.toolchain).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-release}"

if [ -n "${NC_RUST_TOOLCHAIN:-}" ]; then
    export PATH="$NC_RUST_TOOLCHAIN:$PATH"
elif ! command -v cargo >/dev/null 2>&1; then
    EVAL=/Volumes/TiPro9000/deepseek/nc-rewrite-eval/.toolchain
    if [ -x "$EVAL/cargo/bin/cargo" ]; then
        export RUSTUP_HOME="$EVAL/rustup"
        export CARGO_HOME="$EVAL/cargo"
        export PATH="$EVAL/cargo/bin:$PATH"
    else
        echo "nc_core: no cargo found; set NC_RUST_TOOLCHAIN to a bin directory" >&2
        exit 1
    fi
fi

cd "$HERE"
if [ "$PROFILE" = "debug" ]; then
    cargo build
else
    cargo build --release
fi

LIB="$HERE/target/$PROFILE/libnc_core.a"
if [ ! -f "$LIB" ]; then
    echo "nc_core: $LIB was not produced" >&2
    exit 1
fi
echo "nc_core: built $LIB"
