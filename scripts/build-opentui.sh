#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# OpenCode's TUI renderer (@opentui/core) uses a native Zig library.
# The upstream build targets aarch64-linux (musl), which fails on Android
# because getauxval cannot be resolved. We build for aarch64-linux-android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui v${OPENTUI_VERSION}..."
    git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
fi

# Avoid Linux-only dl/pthread linker flags for the Android target.
OPENTUI_PATCH="$REPO_ROOT/patches/opentui/android-libc-link.patch"
if [ -f "$OPENTUI_PATCH" ]; then
    echo ">>> Applying opentui Android patch..."
    cd "$OPENTUI_SRC"
    if ! git apply --check "$OPENTUI_PATCH" 2>/dev/null; then
        echo "    Patch already applied or does not apply cleanly, skipping"
    else
        git apply "$OPENTUI_PATCH"
        echo "    Patch applied successfully"
    fi
fi

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

ZIG_LIBC_CONFIG="$OPENTUI_ZIG_DIR/.zig-android-libc.conf"
sed \
    -e "s|@NDK_SYSROOT@|$NDK_SYSROOT|g" \
    -e "s|@ANDROID_TRIPLE@|$ANDROID_TRIPLE|g" \
    -e "s|@ANDROID_API@|$ANDROID_API|g" \
    "$REPO_ROOT/configs/zig-android-libc.conf.in" > "$ZIG_LIBC_CONFIG"
trap 'rm -f "$ZIG_LIBC_CONFIG"' EXIT

"$ZIG_BIN" build \
    -Dtarget=aarch64-linux-android.24 \
    -Doptimize=ReleaseSafe \
    --libc "$ZIG_LIBC_CONFIG" \
    --sysroot "$NDK_SYSROOT" \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-android.24/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/${ANDROID_TRIPLE}.${ANDROID_API}/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $LIBOPENTUI"
echo "Size: $(du -h "$LIBOPENTUI" | cut -f1)"
file "$LIBOPENTUI"

# Verify the .so has NEEDED: libc.so (required for Android dlopen)
if readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
    echo "OK: libopentui.so has NEEDED: libc.so (required for Android)"
else
    echo "ERROR: libopentui.so is missing NEEDED: libc.so dependency"
    echo "       Android dlopen() will fail without this."
    echo "       Ensure ANDROID_NDK_HOME and its NDK sysroot are configured."
    readelf -d "$LIBOPENTUI" 2>/dev/null | grep NEEDED || echo "       (no NEEDED entries found)"
    exit 1
fi
