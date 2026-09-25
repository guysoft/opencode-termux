#!/usr/bin/env bash
# Create distribution packages for OpenCode Android
#
# Usage: ./scripts/make-packages.sh
#
# Creates three package formats:
# 1. ZIP: opencode-${VERSION}-android-aarch64.zip (standalone)
# 2. Pacman: opencode-${VERSION}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode_${VERSION}_aarch64.deb (old Termux deb format)
#
# Package layout (all formats):
#   bin/opencode                  — wrapper script: sets LD_PRELOAD + LD_LIBRARY_PATH then execs real binary
#   libexec/opencode/opencode.bin — real opencode ELF binary
#   lib/libtagfix.so              — disables Android bionic TBI heap tagging at process start
#   lib/libc++_shared.so          — NDK C++ runtime needed by Bun's JIT-compiled modules
#   lib/libopentui.so             — opentui TUI renderer library (ARM64)
#   lib/librust_pty_arm64.so      — optional bun-pty PTY library (Android/Bionic ARM64 only)
#
# The wrapper + libtagfix.so fix "Pointer tag ... was truncated" SIGABRT on Android 11+.
# Root cause: Bun/JSC NaN-boxing clears the top byte of heap pointers; bionic's default
# software TBI tagging expects tag 0xB4 there and aborts on free() when it finds 0x00.
# Fix: mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE) called via an
# LD_PRELOAD constructor *inside* the opencode process (execv-based wrappers don't work
# because execv resets the tagging level on the new image).
#
# libopentui.so is shipped as a real file because Bun's /$bunfs/root/ virtual
# file system is not intercepted by the Android runtime, so dlopen/openat on
# embedded paths returns ENOENT. The PTY library is shipped only when an
# Android/Bionic build is available.
#
# ZIP install (flat layout — wrapper resolves siblings via $dir):
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
#   chmod +x $PREFIX/bin/opencode $PREFIX/bin/opencode.bin
#   (libc++_shared.so + libtagfix.so are picked up from $PREFIX/bin automatically)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

OPENCODE_BINARY="$DIST_DIR/opencode"
OPENCODE_DEBUG_BINARY="$DIST_DIR/opencode-debug"
WRAPPER_SCRIPT="$REPO_ROOT/bin/opencode"
DEBUG_WRAPPER_SCRIPT="$REPO_ROOT/bin/opencode-debug"
TAGFIX_SRC="$REPO_ROOT/src/libtagfix.c"
PKG_DIR="$WORK_DIR/packages"
ARM64_LIBOPENTUI="$DIST_DIR/libopentui.so"

if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    echo "       Run scripts/build-opencode.sh first."
    exit 1
fi

if [ ! -f "$WRAPPER_SCRIPT" ]; then
    echo "ERROR: Wrapper script not found at $WRAPPER_SCRIPT"
    exit 1
fi

if [ ! -f "$TAGFIX_SRC" ]; then
    echo "ERROR: libtagfix.c not found at $TAGFIX_SRC"
    exit 1
fi

if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opencode.sh first."
    exit 1
fi

# Verify the shipped native libraries are actually AArch64.
# e_machine for AArch64 is 0xb7 (little-endian at ELF offset 18).
check_elf_aarch64() {
    local file="$1"
    local name="$2"
    if [ ! -f "$file" ]; then
        echo "ERROR: $name not found at $file"
        exit 1
    fi
    local machine
    machine=$(od -An -t x1 -j 18 -N 2 "$file" | tr -d ' ')
    if [ "$machine" != "b700" ]; then
        echo "ERROR: $name is not AArch64 (e_machine=$machine)"
        exit 1
    fi
    echo "    Verified $name is AArch64"
}

check_android_shared_object() {
    local file="$1"
    local name="$2"
    local needed
    needed=$(readelf -d "$file" 2>/dev/null | grep 'Shared library:' || true)
    if echo "$needed" | grep -Eq 'libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|libutil\.so\.1'; then
        echo "ERROR: $name is linked against Linux/glibc libraries, not Android/Bionic:"
        echo "$needed"
        exit 1
    fi
    echo "    Verified $name has Android-compatible dynamic dependencies"
}

check_needed_library() {
    local file="$1"
    local name="$2"
    local library="$3"
    if ! readelf -d "$file" 2>/dev/null | grep -q "Shared library: \\[$library\\]"; then
        echo "ERROR: $name is missing NEEDED: $library"
        exit 1
    fi
    echo "    Verified $name declares NEEDED: $library"
}

check_elf_aarch64 "$ARM64_LIBOPENTUI" "libopentui.so"
check_android_shared_object "$ARM64_LIBOPENTUI" "libopentui.so"
check_needed_library "$ARM64_LIBOPENTUI" "libopentui.so" "libc.so"

# Locate bun-pty's ARM64 PTY library (shipped with the npm package)
OPENCODE_PKG="${OPENCODE_PKG:-$OPENCODE_SRC/packages/opencode}"
RUST_PTY_ARM64=""
for candidate in \
    "$DIST_DIR/librust_pty_arm64.so" \
    "$OPENCODE_SRC/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so" \
    "$OPENCODE_PKG/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so" \
    "$REPO_ROOT/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so"
do
    if [ -f "$candidate" ]; then
        if readelf -d "$candidate" 2>/dev/null | grep 'Shared library:' | grep -Eq 'libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|libutil\.so\.1'; then
            echo "WARNING: skipping Linux/glibc PTY library candidate: $candidate"
            continue
        fi
        RUST_PTY_ARM64="$candidate"
        break
    fi
done

if [ -z "$RUST_PTY_ARM64" ]; then
    echo "WARNING: Android-compatible librust_pty_arm64.so not found; PTY features may not work"
else
    check_elf_aarch64 "$RUST_PTY_ARM64" "librust_pty_arm64.so"
    check_android_shared_object "$RUST_PTY_ARM64" "librust_pty_arm64.so"
fi

echo "=== Creating packages for OpenCode v${OPENCODE_VERSION} ==="

BINARY_SIZE=$(stat -c%s "$OPENCODE_BINARY")
BUILD_DATE=$(date +%s)

# Clean up
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# ==========================================
# Compile libtagfix.so (Android aarch64)
# ==========================================
echo ">>> Compiling libtagfix.so..."
TAGFIX_SO="$PKG_DIR/libtagfix.so"
"$ANDROID_CC" -shared -fPIC -O2 -o "$TAGFIX_SO" "$TAGFIX_SRC"
echo "    Compiled $(stat -c%s "$TAGFIX_SO") bytes"
check_elf_aarch64 "$TAGFIX_SO" "libtagfix.so"

TAGFIX_SIZE=$(stat -c%s "$TAGFIX_SO")

# libc++_shared.so is required at runtime by Bun's JIT-compiled modules.
# Android's /system/lib64/ only ships libc++.so, not libc++_shared.so.
echo ">>> Copying libc++_shared.so..."
LIBCPP_SHARED_SRC="$NDK_SYSROOT/usr/lib/$ANDROID_TRIPLE/libc++_shared.so"
if [ ! -f "$LIBCPP_SHARED_SRC" ]; then
    echo "ERROR: libc++_shared.so not found at $LIBCPP_SHARED_SRC"
    exit 1
fi
cp "$LIBCPP_SHARED_SRC" "$PKG_DIR/libc++_shared.so"
LIBCPP_SIZE=$(stat -c%s "$PKG_DIR/libc++_shared.so")
echo "    Copied $(stat -c%s "$PKG_DIR/libc++_shared.so") bytes"
check_elf_aarch64 "$PKG_DIR/libc++_shared.so" "libc++_shared.so"

# libopentui.so must be shipped as a real file because Bun's /$bunfs/root/
# virtual paths are not intercepted on Android.
echo ">>> Copying libopentui.so..."
cp "$ARM64_LIBOPENTUI" "$PKG_DIR/libopentui.so"
if ! readelf -d "$PKG_DIR/libopentui.so" 2>/dev/null | grep -q 'Shared library: \[libm\.so\]'; then
    patchelf --add-needed libm.so "$PKG_DIR/libopentui.so"
fi
LIBOPENTUI_SIZE=$(stat -c%s "$PKG_DIR/libopentui.so")
echo "    Copied $(stat -c%s "$PKG_DIR/libopentui.so") bytes"
check_needed_library "$PKG_DIR/libopentui.so" "libopentui.so" "libm.so"

# librust_pty_arm64.so is also needed as a real file on Android.
RUST_PTY_SIZE=0
if [ -n "$RUST_PTY_ARM64" ]; then
    echo ">>> Copying librust_pty_arm64.so..."
    cp "$RUST_PTY_ARM64" "$PKG_DIR/librust_pty_arm64.so"
    RUST_PTY_SIZE=$(stat -c%s "$PKG_DIR/librust_pty_arm64.so")
    echo "    Copied $(stat -c%s "$PKG_DIR/librust_pty_arm64.so") bytes"
fi

INSTALLED_SIZE=$(( (BINARY_SIZE + TAGFIX_SIZE + LIBOPENTUI_SIZE + RUST_PTY_SIZE + 8192) / 1024 ))  # rough kB estimate

# ==========================================
# 1. ZIP package (flat layout)
# ==========================================
# All three files are placed at the top level so a single
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
# drops wrapper, real binary, and libtagfix.so together.
# The wrapper resolves siblings via $dir (dirname of $0).
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode-${OPENCODE_VERSION}-android-aarch64.zip"
cp "$OPENCODE_BINARY" "$PKG_DIR/opencode.bin"
cp "$WRAPPER_SCRIPT"  "$PKG_DIR/opencode"
chmod 755 "$PKG_DIR/opencode" "$PKG_DIR/opencode.bin"
cd "$PKG_DIR"
ZIP_FILES="opencode opencode.bin libtagfix.so libc++_shared.so libopentui.so"
if [ -f "$PKG_DIR/librust_pty_arm64.so" ]; then
    ZIP_FILES="$ZIP_FILES librust_pty_arm64.so"
fi
zip -9 "$PKG_DIR/$ZIP_NAME" $ZIP_FILES

# Add debug variant to the same ZIP if it was built
if [ -f "$OPENCODE_DEBUG_BINARY" ] && [ -f "$DEBUG_WRAPPER_SCRIPT" ]; then
    cp "$OPENCODE_DEBUG_BINARY" "$PKG_DIR/opencode-debug.bin"
    cp "$DEBUG_WRAPPER_SCRIPT"  "$PKG_DIR/opencode-debug"
    chmod 755 "$PKG_DIR/opencode-debug" "$PKG_DIR/opencode-debug.bin"
    cd "$PKG_DIR"
    zip -9 "$PKG_DIR/$ZIP_NAME" opencode-debug opencode-debug.bin
    echo "    Added debug variant (opencode-debug / opencode-debug.bin) to $ZIP_NAME"
fi
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR/pacman-staging"
PACMAN_USR="$PACMAN_STAGING/data/data/com.termux/files/usr"
mkdir -p "$PACMAN_USR/bin" "$PACMAN_USR/libexec/opencode" "$PACMAN_USR/lib"

cp "$WRAPPER_SCRIPT" "$PACMAN_USR/bin/opencode"
chmod 755 "$PACMAN_USR/bin/opencode"

cp "$OPENCODE_BINARY" "$PACMAN_USR/libexec/opencode/opencode.bin"
chmod 755 "$PACMAN_USR/libexec/opencode/opencode.bin"

cp "$TAGFIX_SO" "$PACMAN_USR/lib/libtagfix.so"
chmod 644 "$PACMAN_USR/lib/libtagfix.so"

cp "$PKG_DIR/libopentui.so" "$PACMAN_USR/lib/libopentui.so"
chmod 644 "$PACMAN_USR/lib/libopentui.so"

if [ -f "$PKG_DIR/librust_pty_arm64.so" ]; then
    cp "$PKG_DIR/librust_pty_arm64.so" "$PACMAN_USR/lib/librust_pty_arm64.so"
    chmod 644 "$PACMAN_USR/lib/librust_pty_arm64.so"
fi

# Create .PKGINFO
cat > "$PACMAN_STAGING/.PKGINFO" << EOF
pkgname = opencode
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = AI-powered coding assistant for the terminal
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${INSTALLED_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
depend = libc++
EOF

PACMAN_NAME="opencode-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
cd "$PACMAN_STAGING"
tar cf - .PKGINFO data | xz -9 > "$PKG_DIR/$PACMAN_NAME"
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (old Termux format)
# ==========================================
echo ">>> Creating deb package..."
DEB_STAGING="$PKG_DIR/deb-staging"
# Note: the extra leading 'data/' under deb-staging is intentional.
# The packaging step does: cd deb-staging/data && tar ... data
# so the data.tar.gz contains data/data/com.termux/... which dpkg
# extracts to /data/data/com.termux/... (the real Termux prefix).
DEB_USR="$DEB_STAGING/data/data/data/com.termux/files/usr"
mkdir -p "$DEB_USR/bin" "$DEB_USR/libexec/opencode" "$DEB_USR/lib"
mkdir -p "$DEB_STAGING/DEBIAN"

cp "$WRAPPER_SCRIPT" "$DEB_USR/bin/opencode"
chmod 755 "$DEB_USR/bin/opencode"

cp "$OPENCODE_BINARY" "$DEB_USR/libexec/opencode/opencode.bin"
chmod 755 "$DEB_USR/libexec/opencode/opencode.bin"

cp "$TAGFIX_SO" "$DEB_USR/lib/libtagfix.so"
chmod 644 "$DEB_USR/lib/libtagfix.so"

cp "$PKG_DIR/libopentui.so" "$DEB_USR/lib/libopentui.so"
chmod 644 "$DEB_USR/lib/libopentui.so"

if [ -f "$PKG_DIR/librust_pty_arm64.so" ]; then
    cp "$PKG_DIR/librust_pty_arm64.so" "$DEB_USR/lib/librust_pty_arm64.so"
    chmod 644 "$DEB_USR/lib/librust_pty_arm64.so"
fi

# Create control file
cat > "$DEB_STAGING/DEBIAN/control" << EOF
Package: opencode
Version: ${OPENCODE_VERSION}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep, libc++
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: AI-powered coding assistant for the terminal
 OpenCode is an AI-powered coding assistant that runs in the terminal.
 This package provides a standalone binary compiled for Android/Termux,
 with a heap-tagging fix for Android 11+ (fixes SIGABRT on Pixel 8,
 S24 Ultra, Poco F7, and other devices with bionic TBI tagging enabled).
EOF

DEB_NAME="opencode_${OPENCODE_VERSION}_aarch64.deb"

# Build deb manually (dpkg-deb may not be available)
cd "$DEB_STAGING/data"
tar czf "$DEB_STAGING/data.tar.gz" data
cd "$DEB_STAGING/DEBIAN"
tar czf "$DEB_STAGING/control.tar.gz" control
echo "2.0" > "$DEB_STAGING/debian-binary"
cd "$DEB_STAGING"
ar rc "$PKG_DIR/$DEB_NAME" debian-binary control.tar.gz data.tar.gz
echo "    Created $DEB_NAME"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$PKG_DIR"/*.{zip,xz,deb} 2>/dev/null
echo ""
echo "Install on Termux:"
echo "  Pacman: pacman -U $PACMAN_NAME"
echo "  Deb:    dpkg -i $DEB_NAME"
echo ""
echo "  Standalone (zip) — installs wrapper + binary + libs into bin/:"
echo "    unzip $ZIP_NAME -d \$PREFIX/bin/"
echo "    chmod +x \$PREFIX/bin/opencode \$PREFIX/bin/opencode.bin"
echo "    # shipped libraries: libtagfix.so libc++_shared.so libopentui.so
    # optional if available: librust_pty_arm64.so
    # (pacman/deb rely on Termux's own libc++_shared.so package instead)"
echo ""
echo "  Debug variant (if included in zip) — use when opencode crashes with a Zig panic:"
echo "    chmod +x \$PREFIX/bin/opencode-debug \$PREFIX/bin/opencode-debug.bin"
echo "    opencode-debug  # prints file:line stack trace on panic"
