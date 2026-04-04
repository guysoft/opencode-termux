#!/usr/bin/env bash
# Cross-compile ICU 75.1 for Android aarch64
#
# Usage: ./scripts/build-icu.sh
#
# ICU is required by WebKit/JSC. The Android NDK does not ship ICU libraries,
# so we must build them from source.
#
# This produces static libraries and headers in $DEPS_PREFIX.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ICU_VERSION_UNDERSCORE="${ICU_VERSION//./_}"
ICU_TARBALL="icu4c-${ICU_VERSION_UNDERSCORE}-src.tgz"
ICU_URL="https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION_UNDERSCORE//_/-}/${ICU_TARBALL}"
ICU_HOST_BUILD="${WORK_DIR}/icu-host-build"
ICU_ANDROID_BUILD="${WORK_DIR}/icu-android-build"

echo "=== Building ICU ${ICU_VERSION} for Android aarch64 ==="

# Download ICU source
if [ ! -d "$ICU_SRC/source" ]; then
    echo ">>> Downloading ICU ${ICU_VERSION}..."
    mkdir -p "$ICU_SRC"
    cd "$WORK_DIR"
    curl -LO "$ICU_URL"
    tar xf "$ICU_TARBALL" -C "$ICU_SRC" --strip-components=1
    rm -f "$ICU_TARBALL"
fi

# Build host ICU tools first (required for cross-build)
if [ ! -f "$ICU_HOST_BUILD/bin/icupkg" ]; then
    echo ">>> Building host ICU tools..."
    mkdir -p "$ICU_HOST_BUILD"
    cd "$ICU_HOST_BUILD"
    "$ICU_SRC/source/configure" --prefix="$(pwd)/install"
    make -j"$JOBS"
    make install
else
    echo ">>> Host ICU tools already built"
fi

# Cross-compile ICU for Android
if [ ! -f "$DEPS_PREFIX/lib/libicuuc.a" ]; then
    echo ">>> Cross-compiling ICU for Android aarch64..."
    mkdir -p "$ICU_ANDROID_BUILD"
    cd "$ICU_ANDROID_BUILD"
    "$ICU_SRC/source/configure" \
        --host=aarch64-linux-android \
        --with-cross-build="$ICU_HOST_BUILD" \
        --prefix="$DEPS_PREFIX" \
        CC="$ANDROID_CC" \
        CXX="$ANDROID_CXX" \
        AR="$ANDROID_AR" \
        RANLIB="$ANDROID_RANLIB" \
        CFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1" \
        CXXFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1" \
        --enable-static --disable-shared
    make -j"$JOBS"
    make install
else
    echo ">>> ICU already built at $DEPS_PREFIX"
fi

echo ""
echo "=== ICU ${ICU_VERSION} build complete ==="
echo "Libraries:"
ls -la "$DEPS_PREFIX/lib/libicu"*.a
echo "Headers: $DEPS_PREFIX/include/unicode/"
