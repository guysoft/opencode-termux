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

# Pin opentui to the exact version that OpenCode depends on.
# This commit corresponds to @opentui/core v0.4.5 (dereferenced tag). We still patch its Zig
# build so the produced .so has a NEEDED: libc.so entry for Android dlopen().
OPENTUI_COMMIT="0c8c4f7cff2927e3df63a9757a45eff9a343611c"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui (commit $OPENTUI_COMMIT)..."
    git clone https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
    cd "$OPENTUI_SRC"
    git checkout "$OPENTUI_COMMIT"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
    # Ensure we are on the pinned commit
    cd "$OPENTUI_SRC"
    CURRENT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "$OPENTUI_COMMIT" ]; then
        echo "    Resetting to pinned commit $OPENTUI_COMMIT (was $CURRENT)..."
        git fetch origin 2>/dev/null || true
        git checkout --force "$OPENTUI_COMMIT"
    fi
    git reset --hard "$OPENTUI_COMMIT" >/dev/null
fi

OPENTUI_PATCH="$REPO_ROOT/patches/opentui/android-libc-link.patch"
if [ -f "$OPENTUI_PATCH" ] && [ "${OPENTUI_SKIP_PATCH:-}" != "1" ]; then
    echo ">>> Applying opentui Android patch..."
    cd "$OPENTUI_SRC"
    if git apply --check "$OPENTUI_PATCH" 2>/dev/null; then
        git apply "$OPENTUI_PATCH"
        echo "    Patch applied successfully"
    else
        # Check if it was already applied (idempotent re-run)
        if git apply --check --reverse "$OPENTUI_PATCH" 2>/dev/null; then
            echo "    Patch already applied, skipping"
        else
            echo "ERROR: opentui Android patch does not apply cleanly to commit $OPENTUI_COMMIT"
            echo "       Regenerate patches/opentui/android-libc-link.patch against this commit."
            exit 1
        fi
    fi
else
    echo ">>> Skipping opentui Android patch"
fi

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

if [ "${OPENTUI_SKIP_ANDROID_RUNTIME_PATCH:-}" != "1" ]; then
    echo ">>> Patching opentui Android runtime paths..."
    python3 - "$OPENTUI_ZIG_DIR" <<'PY'
import sys
from pathlib import Path

zig_dir = Path(sys.argv[1])
lib_zig = zig_dir / "lib.zig"
span_feed_zig = zig_dir / "native-span-feed.zig"
yoga_zig = zig_dir / "yoga.zig"


def replace_export_body(text: str, signature: str, body: str) -> str:
    start = text.find(signature)
    if start == -1:
        raise SystemExit(f"missing signature: {signature}")
    brace = text.find("{", start + len(signature))
    if brace == -1:
        raise SystemExit(f"missing body for: {signature}")
    depth = 0
    end = brace
    while end < len(text):
        char = text[end]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end += 1
                break
        end += 1
    return text[:brace] + "{\n" + body.rstrip() + "\n}" + text[end:]


lib_text = lib_zig.read_text()
audio_bodies = {
    "export fn createAudioEngine(options_ptr: ?*const native_audio.CreateOptions) NativeHandle": """    _ = options_ptr;
    return INVALID_HANDLE;""",
    "export fn audioRefreshPlaybackDevices(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioGetPlaybackDeviceCount(engine_handle: NativeHandle) u32": """    _ = engine_handle;
    return 0;""",
    "export fn audioGetPlaybackDeviceName(engine_handle: NativeHandle, index: u32, out_ptr: [*]u8, max_len: u32) u32": """    _ = engine_handle;
    _ = index;
    _ = out_ptr;
    _ = max_len;
    return 0;""",
    "export fn audioIsPlaybackDeviceDefault(engine_handle: NativeHandle, index: u32) bool": """    _ = engine_handle;
    _ = index;
    return false;""",
    "export fn audioSelectPlaybackDevice(engine_handle: NativeHandle, index: u32) i32": """    _ = engine_handle;
    _ = index;
    return native_audio.Status.err_invalid;""",
    "export fn audioClearPlaybackDeviceSelection(engine_handle: NativeHandle) void": """    _ = engine_handle;""",
    "export fn audioStart(engine_handle: NativeHandle, options_ptr: ?*const native_audio.StartOptions) i32": """    _ = engine_handle;
    _ = options_ptr;
    return native_audio.Status.err_invalid;""",
    "export fn audioStartMixer(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioStop(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioLoad(engine_handle: NativeHandle, data_ptr: ?[*]const u8, data_len: u32, out_sound_id: ?*u32) i32": """    _ = engine_handle;
    _ = data_ptr;
    _ = data_len;
    _ = out_sound_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioUnload(engine_handle: NativeHandle, sound_id: u32) i32": """    _ = engine_handle;
    _ = sound_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioPlay(engine_handle: NativeHandle, sound_id: u32, options_ptr: ?*const native_audio.VoiceOptions, out_voice_id: ?*u32) i32": """    _ = engine_handle;
    _ = sound_id;
    _ = options_ptr;
    _ = out_voice_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioStopVoice(engine_handle: NativeHandle, voice_id: u32) i32": """    _ = engine_handle;
    _ = voice_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetVoiceGroup(engine_handle: NativeHandle, voice_id: u32, group_id: u32) i32": """    _ = engine_handle;
    _ = voice_id;
    _ = group_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioCreateGroup(engine_handle: NativeHandle, name_ptr: ?[*]const u8, name_len: u32, out_group_id: ?*u32) i32": """    _ = engine_handle;
    _ = name_ptr;
    _ = name_len;
    _ = out_group_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetGroupVolume(engine_handle: NativeHandle, group_id: u32, volume: f32) i32": """    _ = engine_handle;
    _ = group_id;
    _ = volume;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetMasterVolume(engine_handle: NativeHandle, volume: f32) i32": """    _ = engine_handle;
    _ = volume;
    return native_audio.Status.err_invalid;""",
    "export fn audioMixToBuffer(engine_handle: NativeHandle, out_ptr: ?[*]f32, frame_count: u32, channels: u8) i32": """    _ = engine_handle;
    _ = out_ptr;
    _ = frame_count;
    _ = channels;
    return native_audio.Status.err_invalid;""",
    "export fn audioEnableTap(engine_handle: NativeHandle, enabled: bool, capacity_frames: u32) i32": """    _ = engine_handle;
    _ = enabled;
    _ = capacity_frames;
    return native_audio.Status.err_invalid;""",
    "export fn audioReadTap(engine_handle: NativeHandle, out_ptr: ?[*]f32, frame_count: u32, channels: u8, out_frames_read: ?*u32) i32": """    _ = engine_handle;
    _ = out_ptr;
    _ = frame_count;
    _ = channels;
    _ = out_frames_read;
    return native_audio.Status.err_invalid;""",
    "export fn audioGetStats(engine_handle: NativeHandle, out_stats: ?*native_audio.Stats) i32": """    _ = engine_handle;
    _ = out_stats;
    return native_audio.Status.err_invalid;""",
}
for signature, body in audio_bodies.items():
    lib_text = replace_export_body(lib_text, signature, body)
lib_zig.write_text(lib_text)

span_text = span_feed_zig.read_text()
span_text = span_text.replace("        errdefer stream.destroy();", "        errdefer allocator.destroy(stream);")
span_text = replace_export_body(
    span_text,
    "pub export fn destroyNativeSpanFeed(stream: ?*Stream) void",
    "    _ = stream;",
)
span_feed_zig.write_text(span_text)

yoga_text = yoga_zig.read_text()
yoga_text = yoga_text.replace(
    "const callback_allocator = std.heap.c_allocator;",
    "const callback_allocator = std.heap.page_allocator;",
)
yoga_zig.write_text(yoga_text)

# v0.4.5 dropped implicit libc linking. miniaudio_shim.c and yoga's
# C++ files need malloc/free/posix_memalign, so turn link_libc back on.
build_zig = zig_dir / "build.zig"
bz = build_zig.read_text()
if ".link_libc = true" not in bz:
    old = ".optimize = optimize,\n    });"
    new = ".optimize = optimize,\n        .link_libc = true,\n    });"
    if old in bz:
        bz = bz.replace(old, new, 1)
        build_zig.write_text(bz)
        print(">>> build.zig: set .link_libc = true")
    else:
        print(">>> build.zig: WARNING anchor not found")
        print(bz)
PY
fi

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

# Zig 0.15.2 does not ship prebuilt Bionic libc. Provide a libc.txt that
# points at the NDK sysroot, then pass it via --libc. See ziglang/zig#23906.
NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
NDK_SYSROOT="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
API_LEVEL="${ANDROID_API:-29}"
if [ ! -d "$NDK_SYSROOT/usr/lib/aarch64-linux-android/$API_LEVEL" ]; then
  AVAIL=$(ls "$NDK_SYSROOT/usr/lib/aarch64-linux-android/" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  [ -n "$AVAIL" ] && API_LEVEL="$AVAIL"
fi
LIBC_TXT="$OPENTUI_ZIG_DIR/libc-android.txt"
{
  echo "include_dir=$NDK_SYSROOT/usr/include"
  echo "sys_include_dir=$NDK_SYSROOT/usr/include/aarch64-linux-android"
  echo "crt_dir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/$API_LEVEL"
  echo "msvc_lib_dir="
  echo "kernel32_lib_dir="
  echo "gcc_dir="
} > "$LIBC_TXT"
echo ">>> Generated libc.txt for API $API_LEVEL:"
cat "$LIBC_TXT"

"$ZIG_BIN" build \
    -Dtarget=aarch64-linux-android \
    -Doptimize=ReleaseFast \
    --libc "$LIBC_TXT" \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-android/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/aarch64-linux-android/libopentui.so"
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

# Show dynamic section for debugging. Android builds must include
# NEEDED: libc.so so dlopen() can resolve symbols such as getauxval.
echo ">>> Dynamic section of libopentui.so:"
readelf -d "$LIBOPENTUI" 2>/dev/null | grep -E "NEEDED|FLAGS|SONAME" || echo "    (no dynamic dependencies)"
if ! readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
    echo ">>> Adding missing NEEDED: libc.so with patchelf..."
    if ! command -v patchelf >/dev/null 2>&1; then
        echo "ERROR: libopentui.so is missing NEEDED: libc.so and patchelf is unavailable"
        exit 1
    fi
    patchelf --add-needed libc.so "$LIBOPENTUI"
    readelf -d "$LIBOPENTUI" 2>/dev/null | grep -E "NEEDED|FLAGS|SONAME" || true
    if ! readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
        echo "ERROR: failed to add NEEDED: libc.so"
        exit 1
    fi
fi
