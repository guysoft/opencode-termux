#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64
#
# Usage: ./scripts/build-bun.sh
#
# This configures and builds Bun using CMake + Ninja with the Android NDK.
# Requires WebKit to be built first (scripts/build-webkit.sh).
#
# The Zig vendor patch (sigaction/sigprocmask bypass) must be applied AFTER
# Bun's build system downloads its custom Zig fork, but BEFORE the bun-zig
# target compiles. We accomplish this by running `ninja clone-zig` first to
# trigger the download, then applying the patch, then running the full build.
#
# The Zig cache must also be cleared between runs to avoid stale cache entries
# referencing files from deleted source trees (which causes FileNotFound errors
# in translate-c output lookup).

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

# Zig cache directory setup.
#
# Zig uses two cache locations:
#   1. --cache-dir (explicit): $BUN_BUILD/cache/zig/local (set by CMake)
#   2. .zig-cache (implicit): $BUN_SRC/.zig-cache (Zig's default CWD-local cache)
#
# On successful builds, Zig hardlinks files between them. The translate-c step
# writes c-headers-for-zig.zig to one location, and build-obj looks it up from
# the other. If they're separate directories and one is missing/stale, we get
# "file_hash FileNotFound" errors.
#
# Fix: Symlink .zig-cache -> the explicit cache dir so both paths resolve to
# the same physical location. Clear both first to avoid stale entries.
echo ">>> Setting up Zig cache directories..."
rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
mkdir -p "$BUN_BUILD/cache/zig/local"
mkdir -p "$BUN_BUILD/cache/zig/global"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
echo "    Symlinked $BUN_SRC/.zig-cache -> $BUN_BUILD/cache/zig/local"

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

# Download Zig vendor BEFORE the full build.
# The clone-zig target downloads Bun's custom Zig fork to $BUN_SRC/vendor/zig/.
# We need Zig downloaded first so we can patch posix.zig before compilation starts.
echo ">>> Downloading Zig vendor (clone-zig target)..."
cd "$BUN_BUILD"
ninja clone-zig || true  # May not exist as a standalone target in all versions

# Apply Zig vendor patch AFTER download, BEFORE build
ZIG_POSIX="$BUN_SRC/vendor/zig/lib/std/posix.zig"
if [ -f "$ZIG_POSIX" ]; then
    echo ">>> Applying Zig vendor patch (sigaction/sigprocmask Android bypass)..."
    cd "$BUN_SRC"
    if patch --dry-run -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" >/dev/null 2>&1; then
        patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch"
        echo "    Zig patch applied successfully."
    else
        # Check if already applied by looking for the Android bypass code
        if grep -q "comptime builtin.abi.isAndroid()" "$ZIG_POSIX" 2>/dev/null; then
            echo "    Zig patch already applied."
        else
            echo "WARNING: Zig patch doesn't match cleanly. Trying with --fuzz..."
            patch -p1 --fuzz=3 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" || {
                echo "ERROR: Could not apply Zig patch. Manual intervention required."
                exit 1
            }
        fi
    fi
else
    echo "WARNING: Zig vendor not yet downloaded ($ZIG_POSIX not found)."
    echo "         Zig may be downloaded during the build. If the build fails,"
    echo "         re-run this script to apply the patch and retry."
fi

# Build
echo ">>> Building Bun (this will take 30-45 minutes)..."
echo "    .zig-cache -> $(readlink -f "$BUN_SRC/.zig-cache" 2>/dev/null || echo 'NOT A SYMLINK')"
cd "$BUN_BUILD"
ninja -j"$JOBS" 2>&1 || {
    echo ""
    echo ">>> Build failed. Checking if Zig was downloaded during the build..."
    # If Zig was just downloaded during the build and the patch wasn't applied,
    # apply it now and retry
    if [ -f "$ZIG_POSIX" ] && ! grep -q "comptime builtin.abi.isAndroid()" "$ZIG_POSIX" 2>/dev/null; then
        echo ">>> Zig downloaded during build but patch not applied. Applying now..."
        cd "$BUN_SRC"
        patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" || {
            echo "ERROR: Zig patch failed to apply"
            exit 1
        }
        echo "    Zig patch applied. Clearing Zig cache and rebuilding..."
        rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
        mkdir -p "$BUN_BUILD/cache/zig/local" "$BUN_BUILD/cache/zig/global"
        ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
        cd "$BUN_BUILD"
        ninja -j"$JOBS"
    else
        echo "ERROR: Build failed (Zig patch was already applied — different error)"
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
