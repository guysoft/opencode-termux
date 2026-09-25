#!/usr/bin/env bash
# Run the standard 5-prompt OpenCode TUI smoke test on a rooted Android device.
#
# This script installs the package, starts a logged opencode session, and scans
# the TTY log for crash markers. Interactive prompts must be sent separately
# (mobile MCP or manual Termux typing):
#   1. working?
#   2. what can you do?
#   3. run ls
#   4. explain this session briefly
#   5. run ls again and summarize the files
#
# Usage:
#   scripts/smoke-android-5prompt.sh path/to/package [adb-device]
#
# Package may be .deb, .pkg.tar.xz, or .zip (zip installs into $PREFIX/bin).

set -euo pipefail

PKG_PATH="${1:-}"
DEVICE="${2:-}"
TERMUX_USER="${TERMUX_USER:-}"
TERMUX_UID="${TERMUX_UID:-}"
PREFIX="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
REMOTE_PKG="/data/local/tmp/opencode-smoke-pkg"
LOG_ROOT="$HOME_DIR/opencode-smoke-5prompt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$PKG_PATH" ] || [ ! -f "$PKG_PATH" ]; then
    echo "usage: $0 path/to/opencode-package [.deb|.pkg.tar.xz|.zip] [adb-device]" >&2
    exit 2
fi

ADB=(adb)
if [ -n "$DEVICE" ]; then
    ADB+=( -s "$DEVICE" )
fi

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "ERROR: no adb device available" >&2
    exit 1
fi

if [ -z "$TERMUX_USER" ]; then
    TERMUX_USER="$("${ADB[@]}" shell 'stat -c %U /data/data/com.termux/files/home' | tr -d '\r')"
fi
if [ -z "$TERMUX_UID" ]; then
    TERMUX_UID="$("${ADB[@]}" shell 'stat -c %u /data/data/com.termux/files/home' | tr -d '\r')"
fi

run_termux() {
    local command="export HOME=$HOME_DIR PREFIX=$PREFIX PATH=$PREFIX/bin:/system/bin LD_LIBRARY_PATH=$PREFIX/lib TMPDIR=$PREFIX/tmp TERM=xterm-256color; $*"
    "${ADB[@]}" shell "su $TERMUX_USER -c $(printf '%q' "$command")"
}

MARKER_RE='panic|Unexpected|Effect|Error|thread panic|integer does not fit'

echo ">>> Device"
"${ADB[@]}" shell 'getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.model'
echo ">>> Termux user: $TERMUX_USER (uid $TERMUX_UID)"

echo ">>> Installing package"
"${ADB[@]}" push "$PKG_PATH" "$REMOTE_PKG" >/dev/null
case "$PKG_PATH" in
    *.deb)
        run_termux "dpkg -i '$REMOTE_PKG'"
        ;;
    *.pkg.tar.xz)
        run_termux "pacman -U --noconfirm '$REMOTE_PKG'"
        ;;
    *.zip)
        run_termux "mkdir -p '$PREFIX/bin' && unzip -o '$REMOTE_PKG' -d '$PREFIX/bin'"
        run_termux "chmod +x '$PREFIX/bin/opencode' '$PREFIX/bin/opencode.bin'"
        ;;
    *)
        echo "ERROR: unsupported package type: $PKG_PATH" >&2
        exit 2
        ;;
esac

run_termux "opencode --version"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$LOG_ROOT/$STAMP"
LATEST_PATH="$HOME_DIR/opencode-smoke-5prompt-latest-path.txt"

echo ">>> Starting logged TUI session"
echo "    Log dir (on device): $LOG_DIR"
run_termux "mkdir -p '$LOG_DIR' && echo '$LOG_DIR' > '$LATEST_PATH' && nohup script -q '$LOG_DIR/tty.log' -c 'opencode --print-logs --log-level DEBUG' >/dev/null 2>&1 &"

cat <<EOF

Send these 5 prompts in Termux, then exit opencode with /exit:

  1. working?
  2. what can you do?
  3. run ls
  4. explain this session briefly
  5. run ls again and summarize the files

After the session ends, scan logs with:

  D=\$(cat $LATEST_PATH)
  grep -Ein '$MARKER_RE' "\$D/tty.log" || echo SMOKE_MARKERS_NONE

EOF
