#!/usr/bin/env bash
# Smoke-test an OpenCode Termux .deb on a rooted Android device.
#
# Usage:
#   scripts/smoke-android-package.sh path/to/opencode_*.deb [adb-device]

set -euo pipefail

DEB_PATH="${1:-}"
DEVICE="${2:-}"
TERMUX_USER="${TERMUX_USER:-u0_a228}"
TERMUX_UID="${TERMUX_UID:-10228}"
PREFIX="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
REMOTE_DEB="/data/local/tmp/opencode-smoke.deb"
REMOTE_DLOPEN="/data/local/tmp/opencode-test-dlopen"
LOG_DIR="$HOME_DIR/opencode-smoke"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$DEB_PATH" ] || [ ! -f "$DEB_PATH" ]; then
    echo "usage: $0 path/to/opencode_*.deb [adb-device]" >&2
    exit 2
fi

ADB=(adb)
if [ -n "$DEVICE" ]; then
    ADB+=( -s "$DEVICE" )
fi

run_termux() {
    local command="export HOME=$HOME_DIR PREFIX=$PREFIX PATH=$PREFIX/bin:/system/bin LD_LIBRARY_PATH=$PREFIX/lib TMPDIR=$PREFIX/tmp TERM=xterm-256color; $*"
    "${ADB[@]}" shell "su $TERMUX_USER -c $(printf '%q' "$command")"
}

echo ">>> Device"
"${ADB[@]}" shell 'getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.model'
"${ADB[@]}" shell 'su -c id >/dev/null'

echo ">>> Installing package"
"${ADB[@]}" push "$DEB_PATH" "$REMOTE_DEB" >/dev/null
run_termux "mkdir -p '$LOG_DIR' && dpkg -i '$REMOTE_DEB' >'$LOG_DIR/install.log' 2>&1"
run_termux "sed -n '1,120p' '$LOG_DIR/install.log'"

echo ">>> Verifying package layout"
run_termux "test -x '$PREFIX/bin/opencode'"
run_termux "test -x '$PREFIX/libexec/opencode/opencode.bin'"
run_termux "test -f '$PREFIX/lib/libtagfix.so'"
run_termux "test -f '$PREFIX/lib/libopentui.so'"
run_termux "grep -q '../libexec/opencode/opencode.bin' '$PREFIX/bin/opencode'"
run_termux "if [ -e '$PREFIX/lib/librust_pty_arm64.so' ]; then echo 'PTY library present'; else echo 'PTY library omitted'; fi"

echo ">>> Verifying dlopen(libopentui.so)"
HELPER_BIN="${TMPDIR:-/tmp}/opencode-test-dlopen-aarch64"
HELPER_SRC="$SCRIPT_DIR/test-dlopen.c"
ANDROID_CC="${ANDROID_CC:-}"
if [ -z "$ANDROID_CC" ]; then
    for ndk in \
        "${ANDROID_NDK_HOME:-}" \
        /opt/android-ndk \
        /home/guy/Android/Sdk/ndk/28.1.13356709
    do
        if [ -x "$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang" ]; then
            ANDROID_CC="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
            break
        fi
    done
fi
if [ ! -x "$HELPER_BIN" ] && [ -f "$HELPER_SRC" ] && [ -x "$ANDROID_CC" ]; then
    "$ANDROID_CC" -O2 -fPIE -pie -o "$HELPER_BIN" "$HELPER_SRC" -ldl
fi
if [ -x "$HELPER_BIN" ]; then
    "${ADB[@]}" push "$HELPER_BIN" "$REMOTE_DLOPEN" >/dev/null
else
    echo "WARNING: test-dlopen helper unavailable; skipping explicit dlopen probe"
fi
if "${ADB[@]}" shell "test -x '$REMOTE_DLOPEN'"; then
    run_termux "'$REMOTE_DLOPEN' '$PREFIX/lib/libopentui.so'"
fi

echo ">>> Running opencode --version"
run_termux "opencode --version >'$LOG_DIR/version.log' 2>&1; cat '$LOG_DIR/version.log'"

echo ">>> Running TUI smoke"
run_termux "timeout 15 script -q -c 'opencode --print-logs --log-level DEBUG' /dev/null >'$LOG_DIR/tui.log' 2>&1; echo TUI_EXIT=\$? >>'$LOG_DIR/tui.log'"
run_termux "grep -E 'Failed to initialize|Pointer tag|Aborted|loading internal tui plugin|TUI_EXIT' '$LOG_DIR/tui.log' || true"

echo ">>> Checking crash reports"
"${ADB[@]}" shell 'logcat -d -t 300 | grep -E "Pointer tag|opencode|libopentui|librust_pty" | tail -n 80' || true

echo "PASS: Android package smoke completed"
