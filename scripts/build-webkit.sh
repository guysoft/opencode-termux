#!/usr/bin/env bash
# Cross-compile WebKit/JavaScriptCore for Android aarch64
#
# Usage: ./scripts/build-webkit.sh
#
# This builds the JSCOnly port of WebKit, producing static libraries
# and headers in the layout that Bun's CMake expects.
#
# Requires ICU to be built first (scripts/build-icu.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

TOOLCHAIN="$REPO_ROOT/cmake/webkit-android-toolchain.cmake"

# Compiler flags matching oven-sh/WebKit's Dockerfile
DEFAULT_CFLAGS="-fno-omit-frame-pointer -ffunction-sections -fdata-sections -faddrsig -DU_STATIC_IMPLEMENTATION=1"
RELEASE_FLAGS="-O3 -DNDEBUG=1"

echo "=== Building WebKit/JSC for Android aarch64 ==="
echo "WebKit source: $WEBKIT_SRC"
echo "Build dir:     $WEBKIT_BUILD"
echo "Output dir:    $WEBKIT_OUTPUT"
echo "ICU prefix:    $DEPS_PREFIX"
echo "Toolchain:     $TOOLCHAIN"
echo ""

# Verify ICU is built
if [ ! -f "$DEPS_PREFIX/lib/libicuuc.a" ]; then
    echo "ERROR: ICU not built. Run scripts/build-icu.sh first."
    exit 1
fi

# Update toolchain with current paths
# The toolchain file has hardcoded paths that need to be parameterized
# We create a temporary toolchain with correct paths
TOOLCHAIN_TMP="$WORK_DIR/webkit-android-toolchain.cmake"
sed \
    -e "s|/home/guy/Android/Sdk/ndk/28.1.13356709|${ANDROID_NDK_HOME}|g" \
    -e "s|/home/guy/opencode-termux/deps-android/prefix|${DEPS_PREFIX}|g" \
    "$TOOLCHAIN" > "$TOOLCHAIN_TMP"

# Create build directory
mkdir -p "$WEBKIT_BUILD"

# Configure
echo ">>> Configuring WebKit/JSC..."
cd "$WEBKIT_BUILD"

cmake \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_TMP" \
    -DPORT=JSCOnly \
    -DENABLE_STATIC_JSC=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_THIN_ARCHIVES=OFF \
    -DUSE_BUN_JSC_ADDITIONS=ON \
    -DUSE_BUN_EVENT_LOOP=ON \
    -DENABLE_BUN_SKIP_FAILING_ASSERTIONS=ON \
    -DENABLE_FTL_JIT=ON \
    -DENABLE_REMOTE_INSPECTOR=ON \
    -DALLOW_LINE_AND_COLUMN_NUMBER_IN_BUILTINS=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_FLAGS="$DEFAULT_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$DEFAULT_CFLAGS -fno-exceptions -fno-c++-static-destructors" \
    -DCMAKE_C_FLAGS_RELEASE="$RELEASE_FLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$RELEASE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
    -DICU_ROOT="$DEPS_PREFIX" \
    -DICU_INCLUDE_DIRS="$DEPS_PREFIX/include" \
    "$WEBKIT_SRC"

echo ""
echo ">>> Configure complete. Building..."

# Build JSC target
cmake --build "$WEBKIT_BUILD" --config Release --target jsc -- -j"$JOBS"

# Build private headers
echo ">>> Building private headers..."
ninja -C "$WEBKIT_BUILD" JavaScriptCore_CopyPrivateHeaders 2>/dev/null || true

echo ""
echo ">>> Build complete. Installing to $WEBKIT_OUTPUT..."

# Install to output directory
mkdir -p "$WEBKIT_OUTPUT"/{lib,include/JavaScriptCore,include/wtf,include/bmalloc,include/unicode}

# Copy static libraries
cp "$WEBKIT_BUILD"/lib/*.a "$WEBKIT_OUTPUT/lib/" 2>/dev/null || true

# Copy ICU libraries
cp "$DEPS_PREFIX/lib/libicudata.a" "$WEBKIT_OUTPUT/lib/"
cp "$DEPS_PREFIX/lib/libicui18n.a" "$WEBKIT_OUTPUT/lib/"
cp "$DEPS_PREFIX/lib/libicuuc.a" "$WEBKIT_OUTPUT/lib/"

# Copy cmakeconfig.h
cp "$WEBKIT_BUILD/cmakeconfig.h" "$WEBKIT_OUTPUT/include/"

# Copy headers
find "$WEBKIT_BUILD/JavaScriptCore/DerivedSources/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \;
find "$WEBKIT_BUILD/JavaScriptCore/Headers/JavaScriptCore/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \; 2>/dev/null || true
find "$WEBKIT_BUILD/JavaScriptCore/PrivateHeaders/JavaScriptCore/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \; 2>/dev/null || true

# Copy WTF headers
cp -r "$WEBKIT_BUILD/WTF/Headers/wtf/"* "$WEBKIT_OUTPUT/include/wtf/" 2>/dev/null || true

# Copy bmalloc headers
cp -r "$WEBKIT_BUILD/bmalloc/Headers/bmalloc/"* "$WEBKIT_OUTPUT/include/bmalloc/" 2>/dev/null || true

# Copy ICU unicode headers
cp -r "$DEPS_PREFIX/include/unicode/"* "$WEBKIT_OUTPUT/include/unicode/"

# Create cmakeconfig.h at root of WEBKIT_OUTPUT (needed by SetupWebKit.cmake)
cp "$WEBKIT_BUILD/cmakeconfig.h" "$WEBKIT_OUTPUT/"
echo "#define BUN_WEBKIT_VERSION \"${WEBKIT_COMMIT}\"" >> "$WEBKIT_OUTPUT/cmakeconfig.h"

# Set up directory structure that SetupWebKit.cmake expects for WEBKIT_LOCAL
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/Headers/JavaScriptCore"
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/PrivateHeaders/JavaScriptCore"
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/DerivedSources/inspector"
mkdir -p "$WEBKIT_OUTPUT/bmalloc/Headers"
mkdir -p "$WEBKIT_OUTPUT/WTF/Headers"

# Copy headers into the WEBKIT_LOCAL layout
cp -r "$WEBKIT_OUTPUT/include/JavaScriptCore/"* "$WEBKIT_OUTPUT/JavaScriptCore/Headers/JavaScriptCore/" 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/JavaScriptCore/"* "$WEBKIT_OUTPUT/JavaScriptCore/PrivateHeaders/JavaScriptCore/" 2>/dev/null || true
find "$WEBKIT_BUILD/JavaScriptCore/DerivedSources/" -name "*.json" -exec cp {} "$WEBKIT_OUTPUT/JavaScriptCore/DerivedSources/inspector/" \; 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/bmalloc" "$WEBKIT_OUTPUT/bmalloc/Headers/" 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/wtf" "$WEBKIT_OUTPUT/WTF/Headers/" 2>/dev/null || true

echo ""
echo "=== WebKit/JSC build complete ==="
echo "Libraries:"
ls -la "$WEBKIT_OUTPUT/lib/"
echo ""
echo "Headers:"
find "$WEBKIT_OUTPUT/include" -maxdepth 2 -type d
