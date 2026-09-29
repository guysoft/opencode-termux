#!/usr/bin/env bash
# Create distribution packages for OpenCode 2 (opencode2) for Android
#
# Usage: ./scripts/make-packages-v2.sh
#
# Creates three package formats:
# 1. ZIP: opencode2-${OPENCODE_VERSION}-android-aarch64.zip (standalone binary)
# 2. Pacman: opencode2-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode2_${OPENCODE_VERSION}_aarch64.deb (Termux deb format)
#
# Layouts (the wrapper supports both):
#   zip:      opencode2, opencode2.bin, libopentui.so in one directory
#   packages: $PREFIX/bin/opencode2, $PREFIX/libexec/opencode2/opencode2.bin,
#             $PREFIX/libexec/opencode2/libopentui.so
#
# All v2 files live under bin/ and libexec/opencode2/ so the package never
# shares a path with the v1 "opencode" package (which owns lib/libopentui.so).
# The two can therefore be installed side by side.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

BIN="$DIST_DIR/opencode2.bin"
LIB="$OPENTUI_LIB"
OUT="$PACKAGE_DIR"
rm -rf "$OUT"
mkdir -p "$OUT" "$DIST_DIR/flat"
test -x "$BIN"
test -f "$LIB"

echo "=== Creating packages for opencode2 v${OPENCODE_VERSION} ==="

# ==========================================
# Wrapper (identical file ships in zip, pacman, deb)
# ==========================================
cat > "$DIST_DIR/flat/opencode2" <<'WEOF'
#!/data/data/com.termux/files/usr/bin/sh
# opencode2 - wrapper for the OpenCode 2 CLI on Android/Termux
#
# Path resolution order (supports both layouts):
#   flat zip:    opencode2, opencode2.bin, libopentui.so in the same directory
#   installed:   bin/opencode2 and libexec/opencode2/{opencode2.bin,libopentui.so}
set -eu

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="$(CDPATH= cd -- "$(dirname "$SELF")" && pwd)"

# Termux markers, in case we are launched outside a Termux shell
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Locate the native library directory. Prefer the private installed package
# layout (libexec/opencode2) over the flat zip layout (libs next to the
# wrapper), so upgrades never pick up a stale flat-layout library.
NATIVE_LIB_DIR=""
for candidate in "$DIR/../libexec/opencode2" "$PREFIX/libexec/opencode2" "$DIR"; do
    if [ -f "$candidate/libopentui.so" ]; then
        NATIVE_LIB_DIR="$candidate"
        break
    fi
done
if [ -n "$NATIVE_LIB_DIR" ]; then
    # opentui renderer library is loaded from the real filesystem on Android.
    export OPENTUI_LIB_PATH="$NATIVE_LIB_DIR/libopentui.so"
    export LD_LIBRARY_PATH="$NATIVE_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# @parcel/watcher only bundles a host-arch native binding in this build;
# disable it on Android/Termux to avoid a dlopen architecture mismatch.
export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER="${OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER:-true}"

# Locate opencode2.bin. Prefer the installed package layout first so
# upgrades do not accidentally execute a stale flat-layout binary.
REAL_BIN=""
for candidate in \
    "$DIR/../libexec/opencode2/opencode2.bin" \
    "$PREFIX/libexec/opencode2/opencode2.bin" \
    "$DIR/opencode2.bin"
do
    if [ -x "$candidate" ]; then
        REAL_BIN="$candidate"
        break
    fi
done

if [ -z "$REAL_BIN" ]; then
    echo "opencode2: error: could not find opencode2.bin" >&2
    exit 127
fi

CONFIG_FILE="$HOME/.config/opencode/service.json"
PORT=4096

if [ -f "$CONFIG_FILE" ]; then
    DETECTED_PORT=$(sed -n 's/.*"port":[[:space:]]*\([0-9]\+\).*/\1/p' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$DETECTED_PORT" ]; then
        PORT="$DETECTED_PORT"
    else
        "$REAL_BIN" service set port "$PORT" >/dev/null 2>&1
    fi
fi

ensure_service() {
    if ! curl -s -o /dev/null -I "http://127.0.0.1:$PORT/" 2>/dev/null; then
        echo "Starting OpenCode background service on port $PORT..."
        "$REAL_BIN" service start >/dev/null 2>&1
    fi
}

open_browser() {
    (
        for _ in {1..25}; do
            if curl -s -o /dev/null -I "http://127.0.0.1:$PORT/" 2>/dev/null; then
                am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT" -p com.android.chrome >/dev/null 2>&1 \
                    || termux-open-url "http://127.0.0.1:$PORT" >/dev/null 2>&1
                break
            fi
            sleep 0.2
        done
    ) < /dev/null >/dev/null 2>&1 &
}

# Service management shortcuts
case "${1:-}" in
    status)
        STATUS=$("$REAL_BIN" service status 2>/dev/null || echo "stopped")
        if [ "$STATUS" = "stopped" ] || [ -z "$STATUS" ]; then
            echo "OpenCode service: stopped"
        else
            echo "OpenCode service: running at $STATUS"
        fi
        exit 0
        ;;
    stop)
        "$REAL_BIN" service stop
        echo "OpenCode service stopped."
        exit 0
        ;;
    start)
        "$REAL_BIN" service start
        exit 0
        ;;
    restart)
        "$REAL_BIN" service restart
        exit 0
        ;;
esac

# Password management command
if [ "${1:-}" = "password" ]; then
    shift
    CURRENT_PASS=$(sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null)
    case "${1:-}" in
        set)
            if [ -z "${2:-}" ]; then
                echo "Usage: opencode password set <new_password>" >&2
                exit 1
            fi
            "$REAL_BIN" service set password "$2" >/dev/null 2>&1
            echo "Password updated to: $2"
            if curl -s -o /dev/null -I "http://127.0.0.1:$PORT/" 2>/dev/null; then
                "$REAL_BIN" service restart >/dev/null 2>&1
                echo "Service restarted to apply new password."
            fi
            exit 0
            ;;
        reset)
            "$REAL_BIN" service set password "opencode" >/dev/null 2>&1
            echo "Password reset to: opencode"
            if curl -s -o /dev/null -I "http://127.0.0.1:$PORT/" 2>/dev/null; then
                "$REAL_BIN" service restart >/dev/null 2>&1
                echo "Service restarted."
            fi
            exit 0
            ;;
        *)
            echo "OpenCode Password Settings:"
            echo "  Current Password: ${CURRENT_PASS:-none}"
            echo ""
            echo "Commands:"
            echo "  opencode password set <pw>  - Change password"
            echo "  opencode password reset     - Reset password to 'opencode'"
            exit 0
            ;;
    esac
fi

# Dedicated web mode
if [ "${1:-}" = "web" ]; then
    shift
    if [ $# -gt 0 ]; then
        exec "$REAL_BIN" serve "$@"
    fi
    ensure_service
    open_browser
    echo "OpenCode Web UI running at http://127.0.0.1:$PORT"
    exit 0
fi

# Explicit CLI mode
if [ "${1:-}" = "--cli" ] || [ "${1:-}" = "cli" ] || [ "${1:-}" = "--no-web" ]; then
    shift
    ensure_service
    exec "$REAL_BIN" "$@"
fi

# Pass administrative commands and help directly to the real binary
case "${1:-}" in
    --help|-h|--version|-v|--completions|service|update|upgrade|uninstall|models|auth|mcp|plugin|stats|api|acp|reload|run|session|pair)
        exec "$REAL_BIN" "$@"
        ;;
esac

# Standalone mode should run directly without service or browser automation
for arg in "$@"; do
    if [ "$arg" = "--standalone" ]; then
        exec "$REAL_BIN" "$@"
    fi
done

# If arguments were provided, launch directly without the menu
if [ $# -gt 0 ] || [ ! -t 0 ]; then
    ensure_service
    exec "$REAL_BIN" "$@"
fi

# Interactive menu for choosing run mode
show_menu() {
    local selected=0

    # Hide cursor
    printf "\033[?25l"

    cleanup() {
        printf "\033[?25h\n"
        exit 0
    }
    trap cleanup INT TERM

    while true; do
        local current_pass=$(sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null)

        local options=(
            "CLI (Terminal Interface)"
            "Web UI (Browser: http://127.0.0.1:4096)"
            "Dual Mode (CLI + Web UI)"
            "Stop Service"
            "View Password [${current_pass:-none}]"
            "Exit"
        )
        local total=${#options[@]}

        render() {
            printf "\n\033[1;36m  OpenCode Launcher\033[0m\n"
            printf "\033[90m  Use ↑/↓ or j/k to navigate, Enter to select:\033[0m\n\n"
            for i in "${!options[@]}"; do
                if [ "$i" -eq "$selected" ]; then
                    printf "  \033[1;32m❯ %d) %s\033[0m\n" "$((i + 1))" "${options[$i]}"
                else
                    printf "    \033[90m%d) %s\033[0m\n" "$((i + 1))" "${options[$i]}"
                fi
            done
            printf "\n"
        }

        render
        local lines=$((total + 5))

        while true; do
            IFS= read -rsn1 char
            if [[ "$char" == $'\x1b' ]]; then
                read -rsn2 -t 0.1 rest
                if [[ "$rest" == '[A' ]]; then
                    if [ "$selected" -gt 0 ]; then
                        selected=$((selected - 1))
                    else
                        selected=$((total - 1))
                    fi
                elif [[ "$rest" == '[B' ]]; then
                    if [ "$selected" -lt $((total - 1)) ]; then
                        selected=$((selected + 1))
                    else
                        selected=0
                    fi
                fi
            elif [[ "$char" == "k" || "$char" == "K" ]]; then
                if [ "$selected" -gt 0 ]; then
                    selected=$((selected - 1))
                else
                    selected=$((total - 1))
                fi
            elif [[ "$char" == "j" || "$char" == "J" ]]; then
                if [ "$selected" -lt $((total - 1)) ]; then
                    selected=$((selected + 1))
                else
                    selected=0
                fi
            elif [[ -z "$char" ]]; then
                break 2
            elif [[ "$char" == "q" || "$char" == "Q" ]]; then
                selected=$((total - 1))
                break 2
            elif [[ "$char" =~ ^[1-6]$ ]]; then
                selected=$((char - 1))
                break 2
            fi

            printf "\033[%dA" "$lines"
            render
        done
        break
    done

    # Restore cursor
    printf "\033[?25h"

    case "$selected" in
        0)
            ensure_service
            exec "$REAL_BIN"
            ;;
        1)
            ensure_service
            open_browser
            echo "OpenCode Web UI running at http://127.0.0.1:$PORT"
            exit 0
            ;;
        2)
            ensure_service
            open_browser
            exec "$REAL_BIN"
            ;;
        3)
            "$REAL_BIN" service stop
            echo "OpenCode service stopped."
            exit 0
            ;;
        4)
            echo "Current password is: ${current_pass:-none}"
            echo "To change it, run: opencode password set <new_password>"
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
}

show_menu
WEOF

cp "$BIN" "$DIST_DIR/flat/opencode2.bin"
cp "$LIB" "$DIST_DIR/flat/libopentui.so"
chmod 755 "$DIST_DIR/flat/opencode2" "$DIST_DIR/flat/opencode2.bin"

# ==========================================
# 1. ZIP package
# ==========================================
echo ">>> Creating ZIP package..."
ZIP="$OUT/opencode2-${OPENCODE_VERSION}-android-aarch64.zip"
(cd "$DIST_DIR/flat" && zip -9 "$ZIP" opencode2 opencode2.bin libopentui.so >/dev/null)
echo "    Created $ZIP"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
STAGE="$OUT/pacman-stage"
mkdir -p "$STAGE/data/data/com.termux/files/usr/bin"
mkdir -p "$STAGE/data/data/com.termux/files/usr/libexec/opencode2"
cp "$DIST_DIR/flat/opencode2" "$STAGE/data/data/com.termux/files/usr/bin/opencode2"
cp "$BIN" "$STAGE/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
cp "$LIB" "$STAGE/data/data/com.termux/files/usr/libexec/opencode2/libopentui.so"
chmod 755 "$STAGE/data/data/com.termux/files/usr/bin/opencode2"
chmod 755 "$STAGE/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
cat > "$STAGE/.PKGINFO" <<PEOF
pkgname = opencode2
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = OpenCode 2 AI coding assistant for Android/Termux
url = https://github.com/guysoft/opencode-termux
builddate = $(date +%s)
packager = opencode-termux
size = $(stat -c%s "$BIN")
arch = aarch64
license = MIT
depend = ripgrep
PEOF

PACMAN_NAME="opencode2-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
(cd "$STAGE" && tar cf - .PKGINFO data | xz -9 > "$OUT/$PACMAN_NAME")
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (Termux)
# ==========================================
echo ">>> Creating deb package..."
DEB_STAGE="$OUT/deb-stage"
mkdir -p "$DEB_STAGE/data/data/data" "$DEB_STAGE/DEBIAN"
cp -a "$STAGE/data/data/." "$DEB_STAGE/data/data/data/"
cat > "$DEB_STAGE/DEBIAN/control" <<DEOF
Package: opencode2
Version: ${OPENCODE_VERSION}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: $(du -sk "$DEB_STAGE/data" | cut -f1)
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/guysoft/opencode-termux
Description: OpenCode 2 AI coding assistant for Android/Termux
 This package provides the OpenCode v2 CLI (opencode2) and the Android
 OpenTUI renderer. It installs alongside the v1 opencode package.
DEOF
printf '2.0\n' > "$DEB_STAGE/debian-binary"
(cd "$DEB_STAGE/data" && tar czf "$DEB_STAGE/data.tar.gz" data)
(cd "$DEB_STAGE/DEBIAN" && tar czf "$DEB_STAGE/control.tar.gz" control)
(cd "$DEB_STAGE" && ar rc "$OUT/opencode2_${OPENCODE_VERSION}_aarch64.deb" debian-binary control.tar.gz data.tar.gz)
DEB_NAME="opencode2_${OPENCODE_VERSION}_aarch64.deb"
echo "    Created $DEB_NAME"

# ==========================================
# Summary
# ==========================================
rm -rf "$STAGE" "$DEB_STAGE"
(cd "$OUT" && sha256sum "$DEB_NAME" "$PACMAN_NAME" "opencode2-${OPENCODE_VERSION}-android-aarch64.zip" > SHA256SUMS)
echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$OUT"/*.{zip,xz,deb} "$OUT/SHA256SUMS"
echo ""
echo "Install on Termux:"
echo "  pacman -U $PACMAN_NAME"
echo "  dpkg -i $DEB_NAME"
echo "  unzip opencode2-${OPENCODE_VERSION}-android-aarch64.zip"
