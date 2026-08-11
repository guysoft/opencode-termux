#!/usr/bin/env bash
# Create self-contained OpenCode packages for Termux/Android aarch64.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

OPENCODE_BINARY="$DIST_DIR/opencode"
ASSET_DIR="$DIST_DIR/opentui-assets"
WRAPPER="$SCRIPT_DIR/opencode-wrapper.sh"
PKG_DIR="$WORK_DIR/packages"
ARM64_LIBOPENTUI="$OPENTUI_SRC/packages/core/src/lib/${ANDROID_TRIPLE}.${ANDROID_API}/libopentui.so"
LIBCXX_SHARED="$NDK_SYSROOT/usr/lib/${ANDROID_TRIPLE}/libc++_shared.so"
TAGFIX_LIB="$DIST_DIR/libtagfix.so"

for required in "$OPENCODE_BINARY" "$WRAPPER" "$ASSET_DIR/@opentui/core/parser.worker.js" "$ARM64_LIBOPENTUI" "$LIBCXX_SHARED"; do
    if [ ! -e "$required" ]; then
        echo "ERROR: required runtime file not found: $required" >&2
        exit 1
    fi
done

"$ANDROID_CC" -shared -fPIC -O2 "$REPO_ROOT/src/libtagfix.c" -o "$TAGFIX_LIB"

PTY_LIB=""
for candidate in "$OPENCODE_SRC"/node_modules/.bun/bun-pty@*/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so; do
    if [ -f "$candidate" ]; then
        PTY_LIB="$candidate"
        break
    fi
done

BUILD_DATE=$(date +%s)
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

copy_flat_runtime() {
    local root="$1"
    mkdir -p "$root"
    install -m 755 "$WRAPPER" "$root/opencode"
    install -m 755 "$OPENCODE_BINARY" "$root/opencode.bin"
    cp -a "$ASSET_DIR" "$root/opentui-assets"
    install -m 755 "$TAGFIX_LIB" "$LIBCXX_SHARED" "$ARM64_LIBOPENTUI" "$root/"
    if [ -n "$PTY_LIB" ]; then
        install -m 755 "$PTY_LIB" "$root/librust_pty_arm64.so"
    fi
}

copy_installed_runtime() {
    local root="$1/data/data/com.termux/files/usr"
    mkdir -p "$root/bin" "$root/lib" "$root/libexec/opencode"
    install -m 755 "$WRAPPER" "$root/bin/opencode"
    install -m 755 "$OPENCODE_BINARY" "$root/libexec/opencode/opencode.bin"
    cp -a "$ASSET_DIR" "$root/libexec/opencode/opentui-assets"
    install -m 755 "$TAGFIX_LIB" "$root/lib/libtagfix.so"
    install -m 755 "$LIBCXX_SHARED" "$root/lib/libc++_shared.so"
    install -m 755 "$ARM64_LIBOPENTUI" "$root/lib/libopentui.so"
    if [ -n "$PTY_LIB" ]; then
        install -m 755 "$PTY_LIB" "$root/lib/librust_pty_arm64.so"
    fi
}

echo ">>> Creating self-contained ZIP package..."
ZIP_NAME="opencode-${OPENCODE_VERSION}-android-aarch64.zip"
ZIP_STAGING="$PKG_DIR/zip-staging"
copy_flat_runtime "$ZIP_STAGING"
(cd "$ZIP_STAGING" && zip -9 -r "$PKG_DIR/$ZIP_NAME" .)

echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR/pacman-staging"
copy_installed_runtime "$PACMAN_STAGING"
PACKAGE_SIZE=$(du -sb "$PACMAN_STAGING/data" | cut -f1)
cat > "$PACMAN_STAGING/.PKGINFO" <<EOF
pkgname = opencode
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = AI-powered coding assistant for Termux
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${PACKAGE_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
depend = proot
EOF
PACMAN_NAME="opencode-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
(cd "$PACMAN_STAGING" && tar cf - .PKGINFO data | xz -9 > "$PKG_DIR/$PACMAN_NAME")

echo ">>> Creating deb package..."
DEB_STAGING="$PKG_DIR/deb-staging"
copy_installed_runtime "$DEB_STAGING"
mkdir -p "$DEB_STAGING/DEBIAN"
INSTALLED_SIZE=$((PACKAGE_SIZE / 1024))
cat > "$DEB_STAGING/DEBIAN/control" <<EOF
Package: opencode
Version: ${OPENCODE_VERSION}
Architecture: aarch64
Maintainer: opencode-termux
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep, proot
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: AI-powered coding assistant for Termux/Android
EOF
(cd "$DEB_STAGING" && tar czf "$DEB_STAGING/data.tar.gz" data)
(cd "$DEB_STAGING/DEBIAN" && tar czf "$DEB_STAGING/control.tar.gz" control)
echo "2.0" > "$DEB_STAGING/debian-binary"
(cd "$DEB_STAGING" && ar rc "$PKG_DIR/opencode_${OPENCODE_VERSION}_aarch64.deb" debian-binary control.tar.gz data.tar.gz)

echo "=== Packages created ==="
ls -lh "$PKG_DIR/$ZIP_NAME" "$PKG_DIR/$PACMAN_NAME" "$PKG_DIR/opencode_${OPENCODE_VERSION}_aarch64.deb"
