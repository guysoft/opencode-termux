#!/data/data/com.termux/files/usr/bin/sh
# OpenCode Android launcher: supplies writable /tmp, native libraries and
# OpenTUI's real filesystem assets before starting the standalone binary.

set -e

dir="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-/data/data/com.termux/files/usr}"

export ANDROID_ROOT="${ANDROID_ROOT:-/system}"
export TERMUX_VERSION="${TERMUX_VERSION:-opencode-termux}"
export TMPDIR="${OPENCODE_TMPDIR:-${HOME:-/data/data/com.termux/files/home}/tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export OPENCODE_DISABLE_TUI_AUDIO="${OPENCODE_DISABLE_TUI_AUDIO:-1}"
mkdir -p "$TMPDIR" 2>/dev/null || true

for candidate in \
    "$prefix/libexec/opencode/opentui-assets" \
    "$dir/../libexec/opencode/opentui-assets" \
    "$dir/opentui-assets"
do
    if [ -f "$candidate/@opentui/core/parser.worker.js" ]; then
        export OTUI_ASSET_ROOT="$(cd "$candidate" && pwd)"
        break
    fi
done

native_lib_dir=""
for candidate in "$prefix/lib" "$dir/../lib" "$dir"
do
    if [ -f "$candidate/libtagfix.so" ]; then
        native_lib_dir="$candidate"
        break
    fi
done

if [ -n "$native_lib_dir" ]; then
    export LD_PRELOAD="$native_lib_dir/libtagfix.so${LD_PRELOAD:+:$LD_PRELOAD}"
    export LD_LIBRARY_PATH="$native_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export OPENTUI_LIB_PATH="$native_lib_dir/libopentui.so"
    if [ -f "$native_lib_dir/librust_pty_arm64.so" ]; then
        export BUN_PTY_LIB="$native_lib_dir/librust_pty_arm64.so"
    fi
    export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER="${OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER:-true}"
    if [ -x "$native_lib_dir/bun" ]; then
        export OPENCODE_BUN_PATH="$native_lib_dir/bun"
    fi
else
    echo "opencode: warning: native library directory not found" >&2
fi

for candidate in \
    "$prefix/libexec/opencode/opencode.bin" \
    "$dir/../libexec/opencode/opencode.bin" \
    "$dir/opencode.bin"
do
    if [ -x "$candidate" ]; then
        if command -v proot >/dev/null 2>&1; then
            exec proot -b "$prefix/tmp:/tmp" "$candidate" "$@"
        fi
        exec "$candidate" "$@"
    fi
done

echo "opencode: error: opencode.bin not found" >&2
exit 127
