#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64
#
# Usage: ./scripts/build-bun.sh
#
# This configures and builds Bun using CMake + Ninja with the Android NDK.
# Requires WebKit to be built first (scripts/build-webkit.sh).
#
# The Zig vendor patch is applied here after the build system downloads Zig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

# Verify prerequisites
if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi

if [ ! -d "$WEBKIT_OUTPUT/lib" ]; then
    echo "ERROR: WebKit not built. Run scripts/build-webkit.sh first."
    exit 1
fi

# Create build directory
mkdir -p "$BUN_BUILD"

# CMake toolchain is inside the patched Bun source
BUN_TOOLCHAIN="$BUN_SRC/cmake/toolchains/android-aarch64.cmake"
if [ ! -f "$BUN_TOOLCHAIN" ]; then
    echo "ERROR: Android toolchain not found at $BUN_TOOLCHAIN"
    echo "       Did apply-patches.sh run successfully?"
    exit 1
fi

# Configure
echo ">>> Configuring Bun..."
cd "$BUN_BUILD"

cmake \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BUN_TOOLCHAIN" \
    -DANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LTO=OFF \
    -DBUN_LINK_ONLY=OFF \
    -DWEBKIT_LOCAL=ON \
    -DWEBKIT_PATH="$WEBKIT_OUTPUT" \
    "$BUN_SRC"

echo ""
echo ">>> Configure complete."

# Apply Zig vendor patch AFTER Bun's build system downloads Zig
# The Zig source is downloaded to $BUN_SRC/vendor/zig/ during configure or first build
ZIG_POSIX="$BUN_SRC/vendor/zig/lib/std/posix.zig"
if [ -f "$ZIG_POSIX" ]; then
    echo ">>> Applying Zig vendor patch (sigaction/sigprocmask Android bypass)..."
    cd "$BUN_SRC"
    # The zig patch uses vendor/zig paths - apply from bun source root
    if patch --dry-run -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" 2>/dev/null; then
        patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch"
        echo "    Zig patch applied successfully"
    else
        echo "    Zig patch already applied or doesn't match (may need manual intervention)"
    fi
else
    echo "WARNING: Zig vendor not yet downloaded ($ZIG_POSIX not found)"
    echo "         Will attempt to apply patch after first build attempt."
fi

# Build
echo ">>> Building Bun (this will take 30-45 minutes)..."
ninja -j"$JOBS" 2>&1 || {
    # If build failed and Zig was just downloaded, try applying patch and rebuilding
    if [ -f "$ZIG_POSIX" ]; then
        echo ">>> Build failed. Trying to apply Zig patch and rebuild..."
        cd "$BUN_SRC"
        if patch --dry-run -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" 2>/dev/null; then
            patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch"
            echo "    Zig patch applied. Rebuilding..."
            cd "$BUN_BUILD"
            ninja -j"$JOBS"
        else
            echo "ERROR: Build failed and Zig patch couldn't be applied"
            exit 1
        fi
    else
        echo "ERROR: Build failed"
        exit 1
    fi
}

# Verify output
BUN_BINARY="$BUN_BUILD/bun"
if [ ! -f "$BUN_BINARY" ]; then
    # Try bun-profile (unstripped)
    BUN_BINARY="$BUN_BUILD/bun-profile"
fi

if [ ! -f "$BUN_BINARY" ]; then
    echo "ERROR: Bun binary not found after build"
    exit 1
fi

echo ""
echo "=== Bun build complete ==="
echo "Binary: $BUN_BINARY"
echo "Size: $(du -h "$BUN_BINARY" | cut -f1)"
file "$BUN_BINARY"
