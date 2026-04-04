#!/usr/bin/env bash
# Cross-compile TinyCC (libtcc.a) for Android aarch64
#
# Usage: ./scripts/build-tinycc.sh
#
# Bun uses TinyCC for its built-in C compiler. We need to cross-compile
# libtcc.a as a static library for Android aarch64.
#
# Source: oven-sh/tinycc (Bun's fork of TinyCC)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

TINYCC_COMMIT="${TINYCC_COMMIT:-b91835d8701523e895a2b447713630069514e291}"
TINYCC_SRC="${WORK_DIR}/tinycc-src"
TINYCC_BUILD="${TINYCC_SRC}/build-android"

echo "=== Building TinyCC (libtcc.a) for Android aarch64 ==="

# Check if already built and installed
if [ -f "$WEBKIT_OUTPUT/lib/libtcc.a" ]; then
    echo ">>> libtcc.a already exists at $WEBKIT_OUTPUT/lib/libtcc.a"
    ls -la "$WEBKIT_OUTPUT/lib/libtcc.a"
    exit 0
fi

# Clone TinyCC source
if [ ! -d "$TINYCC_SRC/.git" ]; then
    echo ">>> Cloning TinyCC at commit ${TINYCC_COMMIT}..."
    mkdir -p "$TINYCC_SRC"
    cd "$TINYCC_SRC"
    git init
    git remote add origin https://github.com/oven-sh/tinycc.git
    git fetch --depth=1 origin "${TINYCC_COMMIT}"
    git checkout FETCH_HEAD
else
    echo ">>> TinyCC source already exists at $TINYCC_SRC"
fi

# Build libtcc.a
echo ">>> Compiling TinyCC for Android aarch64..."
rm -rf "$TINYCC_BUILD"
mkdir -p "$TINYCC_BUILD"

SOURCES=(
    libtcc.c
    tccpp.c
    tccgen.c
    tccelf.c
    tccasm.c
    tccrun.c
    arm64-gen.c
    arm64-link.c
    arm-asm.c
)

cd "$TINYCC_SRC"

for src in "${SOURCES[@]}"; do
    echo "  Compiling $src..."
    $ANDROID_CC \
        -O2 -fPIC -Wall -fno-strict-aliasing \
        -DONE_SOURCE=0 \
        '-DTCC_LIBTCC1="\0"' \
        '-DTCC_VERSION="0.9.27"' \
        -DTCC_TARGET_ARM64 \
        -I"$TINYCC_SRC" \
        -I"$TINYCC_SRC/include" \
        -c "$src" \
        -o "$TINYCC_BUILD/${src%.c}.o"
done

echo ">>> Creating libtcc.a..."
$ANDROID_AR rcs "$TINYCC_BUILD/libtcc.a" "$TINYCC_BUILD"/*.o

# Install to webkit-android output (where Bun's CMake expects it)
mkdir -p "$WEBKIT_OUTPUT/lib"
cp "$TINYCC_BUILD/libtcc.a" "$WEBKIT_OUTPUT/lib/"

echo ""
echo "=== TinyCC build complete ==="
echo "Library: $WEBKIT_OUTPUT/lib/libtcc.a"
ls -la "$WEBKIT_OUTPUT/lib/libtcc.a"
file "$WEBKIT_OUTPUT/lib/libtcc.a"
