#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script:
# 1. Clones OpenCode if needed
# 2. Uses the ARM64 libopentui.so built by scripts/build-opentui.sh
# 3. Synthesizes @opentui/core-linux-arm64 in node_modules for ARM64 Android
# 4. Runs the TypeScript build script to create the standalone binary
# 5. Restores original @opentui/core-linux-x64 files
#
# Requires:
# - Android Bun binary built (scripts/build-bun.sh)
# - opentui ARM64 .so built (scripts/build-opentui.sh)
# - Host Bun installed (for bundling)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

HOST_BUN="${HOST_BUN:-bun}"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="

# Clone OpenCode if needed
if [ ! -d "$OPENCODE_SRC/.git" ]; then
    echo ">>> Cloning OpenCode..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC"
else
    echo ">>> OpenCode source exists at $OPENCODE_SRC"
    cd "$OPENCODE_SRC"
    CURRENT=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "v${OPENCODE_VERSION}" ]; then
        echo "    Checking out v${OPENCODE_VERSION} (was $CURRENT)..."
        git fetch --tags origin "v${OPENCODE_VERSION}" 2>/dev/null || true
        git checkout --force "v${OPENCODE_VERSION}"
    fi
fi

OPENCODE_PKG="$OPENCODE_SRC/packages/opencode"

# Install OpenCode dependencies
echo ">>> Installing OpenCode dependencies..."
cd "$OPENCODE_SRC"
"$HOST_BUN" install --ignore-scripts

# Find the Android bun binary
ANDROID_BUN="$BUN_BUILD/bun"
if [ ! -f "$ANDROID_BUN" ]; then
    echo "ERROR: Android bun binary not found at $ANDROID_BUN"
    echo "       Run scripts/build-bun.sh first."
    exit 1
fi

# Use the ARM64 libopentui.so built by scripts/build-opentui.sh.
# build-opentui.sh checks out opentui v0.4.2 (the version OpenCode depends on)
# and cross-compiles it for aarch64-linux-android, producing:
#   $OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so
echo ">>> Locating ARM64 libopentui.so from opentui build..."

# Determine the @opentui/core version OpenCode depends on for the synthesized
# core-linux-arm64 package metadata. The package may be hoisted to the workspace
# root or kept inside packages/opencode/node_modules.
OPENTUI_CORE_PKG_JSON=""
for candidate in \
    "$OPENCODE_PKG/node_modules/@opentui/core/package.json" \
    "$OPENCODE_SRC/node_modules/@opentui/core/package.json"
do
    if [ -f "$candidate" ]; then
        OPENTUI_CORE_PKG_JSON="$candidate"
        break
    fi
done
if [ -z "$OPENTUI_CORE_PKG_JSON" ]; then
    echo "ERROR: @opentui/core not installed. Run bun install first."
    echo "       Searched:"
    echo "         $OPENCODE_PKG/node_modules/@opentui/core/package.json"
    echo "         $OPENCODE_SRC/node_modules/@opentui/core/package.json"
    exit 1
fi
OPENTUI_CORE_VERSION=$(jq -r '.version' "$OPENTUI_CORE_PKG_JSON")
echo "    @opentui/core version: $OPENTUI_CORE_VERSION"

ARM64_LIBOPENTUI="$OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opentui.sh first."
    exit 1
fi
echo "    Using ARM64 libopentui.so ($(du -h "$ARM64_LIBOPENTUI" | cut -f1))"

is_android_shared_object() {
    local file="$1"
    local needed
    needed=$(readelf -d "$file" 2>/dev/null | grep 'Shared library:' || true)
    ! echo "$needed" | grep -Eq 'libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|libutil\.so\.1'
}

# Find all @opentui/core-linux-x64 package directories under node_modules.
# We must patch every occurrence because Bun's module resolver can pick up
# the package from multiple hoisted locations, and the .so inside each one
# must be ARM64 and must load from a real filesystem path on Android
# (Bun's /$bunfs/root/ virtual paths are not reliably intercepted on Android).
OPENTUI_PACKAGES=()
while IFS= read -r -d '' pkg_dir; do
    OPENTUI_PACKAGES+=("$pkg_dir")
done < <(find "$OPENCODE_SRC" -path '*/node_modules/@opentui/core-linux-x64' -type d -print0 2>/dev/null || true)

if [ ${#OPENTUI_PACKAGES[@]} -eq 0 ]; then
    echo "ERROR: Could not find @opentui/core-linux-x64 in node_modules"
    echo "       The build will embed the wrong architecture"
    exit 1
fi

# Backup list: "so_path:backup_path index_path:backup_path ..."
OPENTUI_BACKUPS=()

echo ">>> Patching @opentui/core-linux-x64 packages for Android aarch64..."
for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
    so_file="$pkg_dir/libopentui.so"
    idx_file=""
    if [ -f "$pkg_dir/index.js" ]; then
        idx_file="$pkg_dir/index.js"
    elif [ -f "$pkg_dir/index.ts" ]; then
        idx_file="$pkg_dir/index.ts"
    fi

    if [ ! -f "$so_file" ]; then
        echo "WARNING: $so_file not found, skipping $pkg_dir"
        continue
    fi

    # Backup and swap the .so
    so_backup="${so_file}.x64.bak"
    cp "$so_file" "$so_backup"
    cp "$ARM64_LIBOPENTUI" "$so_file"
    OPENTUI_BACKUPS+=("$so_file:$so_backup")
    echo "    Swapped $so_file"

    # Patch the index file to load from filesystem on Android.
    # Bun's /$bunfs/root/ virtual path works on desktop Linux but is not
    # intercepted by the Android runtime, so the dlopen/openat fails with ENOENT.
    # We fall back to a real Termux filesystem path via OPENTUI_LIB_PATH.
    if [ -n "$idx_file" ]; then
        idx_backup="${idx_file}.bak"
        cp "$idx_file" "$idx_backup"
        cat > "$idx_file" <<'IDXEOF'
module.exports = process.env["OPENTUI_LIB_PATH"] || "/data/data/com.termux/files/usr/lib/libopentui.so";
IDXEOF
        OPENTUI_BACKUPS+=("$idx_file:$idx_backup")
        echo "    Patched $idx_file"
    fi
done

# Synthesize @opentui/core-linux-arm64 so opentui's platform detection resolves
# the correct package on Android/Termux arm64. The host build only installs
# core-linux-x64, so the arm64 optional dependency is missing. Without this,
# zig.ts throws "opentui is not supported on the current platform: linux-arm64".
CORE_LINUX_ARM64_DIR="$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64"
if [ ! -d "$CORE_LINUX_ARM64_DIR" ]; then
    echo ">>> Creating @opentui/core-linux-arm64 package..."
    mkdir -p "$CORE_LINUX_ARM64_DIR"
    cat > "$CORE_LINUX_ARM64_DIR/package.json" <<EOF
{
  "name": "@opentui/core-linux-arm64",
  "version": "$OPENTUI_CORE_VERSION",
  "main": "index.js",
  "license": "MIT"
}
EOF
    cp "$ARM64_LIBOPENTUI" "$CORE_LINUX_ARM64_DIR/libopentui.so"
    cat > "$CORE_LINUX_ARM64_DIR/index.js" <<'EOF'
module.exports = process.env["OPENTUI_LIB_PATH"] || "/data/data/com.termux/files/usr/lib/libopentui.so";
EOF
    echo "    Created $CORE_LINUX_ARM64_DIR"
else
    echo ">>> @opentui/core-linux-arm64 already exists, updating .so and version..."
    cat > "$CORE_LINUX_ARM64_DIR/package.json" <<EOF
{
  "name": "@opentui/core-linux-arm64",
  "version": "$OPENTUI_CORE_VERSION",
  "main": "index.js",
  "license": "MIT"
}
EOF
    cp "$ARM64_LIBOPENTUI" "$CORE_LINUX_ARM64_DIR/libopentui.so"
    cat > "$CORE_LINUX_ARM64_DIR/index.js" <<'EOF'
module.exports = process.env["OPENTUI_LIB_PATH"] || "/data/data/com.termux/files/usr/lib/libopentui.so";
EOF
fi

# Patch @opentui/core's generated FFI wrapper. Bun validates numeric arguments
# against the declared FFI type before Zig sees them; Android terminal/layout
# churn can briefly produce negative viewport sizes, which otherwise throws
# "integer does not fit in destination type" for u32 arguments.
echo ">>> Patching @opentui/core FFI u32 boundary..."
while IFS= read -r -d '' opentui_js; do
    if grep -q "function toU32(value)" "$opentui_js" && grep -q "OPENTUI_LIB_PATH" "$opentui_js" && grep -q "if (true) return null;" "$opentui_js"; then
        echo "    $opentui_js already patched"
        continue
    fi
    if ! grep -q "textBufferViewSetViewport(view, x, y, width, height)" "$opentui_js"; then
        continue
    fi
    python3 - "$opentui_js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'if (isBunfsPath(targetLibPath)) {\n  targetLibPath = targetLibPath.replace("../", "");\n}\nif (!existsSync2(targetLibPath)) {',
    'if (isBunfsPath(targetLibPath)) {\n  targetLibPath = targetLibPath.replace("../", "");\n}\nif (process.env["OPENTUI_LIB_PATH"]) {\n  targetLibPath = process.env["OPENTUI_LIB_PATH"];\n}\nif (!existsSync2(targetLibPath)) {',
)
text = text.replace(
    'function toNumber(value) {\n  return typeof value === "bigint" ? Number(value) : value;\n}\n',
    'function toNumber(value) {\n  return typeof value === "bigint" ? Number(value) : value;\n}\nfunction toU32(value) {\n  if (!Number.isFinite(value) || value <= 0) return 0;\n  return Math.min(Math.trunc(value), 4294967295);\n}\n',
)
text = text.replace(
    'this.opentui.symbols.textBufferViewSetWrapWidth(view, width);',
    'this.opentui.symbols.textBufferViewSetWrapWidth(view, toU32(width));',
)
text = text.replace(
    'this.opentui.symbols.textBufferViewSetFirstLineOffset(view, offset);',
    'this.opentui.symbols.textBufferViewSetFirstLineOffset(view, toU32(offset));',
)
text = text.replace(
    'this.opentui.symbols.textBufferViewSetViewportSize(view, width, height);',
    'this.opentui.symbols.textBufferViewSetViewportSize(view, toU32(width), toU32(height));',
)
text = text.replace(
    'this.opentui.symbols.textBufferViewSetViewport(view, x, y, width, height);',
    'this.opentui.symbols.textBufferViewSetViewport(view, toU32(x), toU32(y), toU32(width), toU32(height));',
)
text = text.replace(
    'this.opentui.symbols.textBufferViewMeasureForDimensions(view, width, height, resultPtr);',
    'this.opentui.symbols.textBufferViewMeasureForDimensions(view, toU32(width), toU32(height), resultPtr);',
)
text = text.replace(
    '  static create(options = {}) {\n    return new Audio(resolveRenderLib(), options);\n  }\n',
    '  static create(options = {}) {\n    if (true) return null;\n    return new Audio(resolveRenderLib(), options);\n  }\n',
)
text = text.replace(
    '    const useFeedOutput = !this._usesProcessStdout && !useMemoryBufferedOutput;',
    '    const useFeedOutput = false;',
)
path.write_text(text)
PY
    echo "    Patched $opentui_js"
done < <(find "$OPENCODE_SRC" -path '*/node_modules/@opentui/core/index-*.js' -type f -print0 2>/dev/null || true)

# Patch OpenCode source for Android/Termux runtime constraints.
# We cannot modify the upstream source directly, so apply local patches here.
echo ">>> Patching OpenCode source for Android/Termux..."

# 1. Keep cache/tmp paths inside the Termux home directory.
#    Bun resolves os.tmpdir() to /data/local/tmp on Android, which the Termux
#    app sandbox cannot mkdir/read under normal app context.
GLOBAL_TS="$OPENCODE_SRC/packages/core/src/global.ts"
if [ -f "$GLOBAL_TS" ]; then
    if ! grep -q 'home.startsWith("/data/data/com.termux/")' "$GLOBAL_TS"; then
        perl -i -pe '
            s/^const app = "opencode"$/const app = "opencode"\nconst home = process.env.OPENCODE_TEST_HOME ?? os.homedir()\nconst isAndroid = Boolean(\n  process.env.TERMUX_VERSION || process.env.ANDROID_ROOT || home.startsWith("\/data\/data\/com.termux\/"),\n)/;
            s/^const cache = path\.join\(xdgCache!, app\)$/const cache = isAndroid ? path.join(home, ".cache", app) : path.join(xdgCache!, app)/;
            s/^const tmp = path\.join\(os\.tmpdir\(\), app\)$/const tmp = isAndroid ? path.join(cache, "tmp") : path.join(os.tmpdir(), app)/;
            s/return process\.env\.OPENCODE_TEST_HOME \?\? os\.homedir\(\)/return home/;
        ' "$GLOBAL_TS"
        echo "    Patched $GLOBAL_TS (Termux cache/tmp paths)"
    else
        echo "    $GLOBAL_TS already patched"
    fi
fi

# 2. Disable the file watcher on Android/Termux.
#    @parcel/watcher bundles the host (x86_64) native binding on a Linux build
#    machine, which dlopen's on ARM64 Android and crashes. Until the ARM64
#    binding is bundled, simply disable file watching.
WATCHER_TS="$OPENCODE_SRC/packages/core/src/filesystem/watcher.ts"
if [ ! -f "$WATCHER_TS" ]; then
    WATCHER_TS="$OPENCODE_PKG/src/file/watcher.ts"
fi
if [ -f "$WATCHER_TS" ]; then
    if ! grep -q "TERMUX_VERSION" "$WATCHER_TS"; then
        perl -i -pe '
            s/^(\s*const watcher = lazy\(\(\): typeof import\("(.*)"\) \| undefined => \{)/$1\n  if (process.env.TERMUX_VERSION \|\| process.env.ANDROID_ROOT) return/
        ' "$WATCHER_TS"
        echo "    Patched $WATCHER_TS (disable file watcher on Android)"
    else
        echo "    $WATCHER_TS already patched"
    fi
fi

# 3. Skip config-dir dependency installs on Android/Termux.
#    In a bun build --compile binary, process.execPath is the compiled opencode
#    binary, so `bun install` becomes `opencode.bin install`, which fails.
#    User plugins are not supported in the Termux build anyway.
CONFIG_TS="$OPENCODE_PKG/src/config/config.ts"
if [ -f "$CONFIG_TS" ]; then
    if ! grep -q "TERMUX_VERSION" "$CONFIG_TS"; then
        perl -i -0777 -pe '
            s/(\n\s*)const dep = yield\* npmSvc\n\s+\.install\(dir,/$1if (process.env.TERMUX_VERSION || process.env.ANDROID_ROOT) {\n$1  yield* Effect.logInfo("skipping dependency install on Android Termux", { dir })\n$1} else {\n$1  const dep = yield* npmSvc\n$1    .install(dir,/;
            s/(\n\s*)deps\.push\(dep\)/$1deps.push(dep)\n$1}/;
        ' "$CONFIG_TS"
        echo "    Patched $CONFIG_TS (skip dependency install on Android)"
    else
        echo "    $CONFIG_TS already patched"
    fi
fi

# 4. Allow BunProc.which() to use a real bun binary if one is shipped.
BUNPROC_TS="$OPENCODE_PKG/src/bun/index.ts"
if [ -f "$BUNPROC_TS" ]; then
    if ! grep -q "OPENCODE_BUN_PATH" "$BUNPROC_TS"; then
        perl -i -0777 -pe '
            s/  export function which\(\) \{\n    return process\.execPath\n  \}/  export function which() {\n    return process.env.OPENCODE_BUN_PATH \|\| process.execPath\n  }/
        ' "$BUNPROC_TS"
        echo "    Patched $BUNPROC_TS (OPENCODE_BUN_PATH support)"
    else
        echo "    $BUNPROC_TS already patched"
    fi
fi

# 5. Disable TUI audio on the Android/Termux build.
#    OpenTUI audio group handling panics on Android after a few prompt responses.
AUDIO_TS="$OPENCODE_SRC/packages/tui/src/audio.ts"
if [ -f "$AUDIO_TS" ]; then
    if ! grep -q 'const disableAudio = true' "$AUDIO_TS"; then
        perl -i -0777 -pe '
            s/const disableAudio = process\.platform === "linux" \&\& process\.arch === "arm64"\n//;
            s/const disableAudio = process\.execPath\.includes\("\/data\/data\/com\.termux\/"\)\n//;
            s/const disableAudio = process\.env\["OPENCODE_DISABLE_TUI_AUDIO"\] === "1"\n//;
            s/(const sounds = new Map<string, Promise<AudioSound \| null>>\(\)\n)/$1const disableAudio = true\n/;
            s/function getAudio\(\) \{\n/function getAudio() {\n  if (disableAudio) {\n    audio = null\n    return null\n  }\n/;
        ' "$AUDIO_TS"
        echo "    Patched $AUDIO_TS (disable TUI audio on Android)"
    else
        echo "    $AUDIO_TS already patched"
    fi
fi

# 6. Add diagnostic logging around createCliRenderer/render in the TUI app.
#    The TUI hangs on Android with no output; we need to know whether
#    createCliRenderer succeeds, throws, or never returns.
APP_TSX="$OPENCODE_PKG/src/cli/cmd/tui/app.tsx"
if [ -f "$APP_TSX" ]; then
    if ! grep -q "OPENCODE_ANDROID_DIAG" "$APP_TSX"; then
        perl -i -0777 -pe '
            s/(const renderer = await createCliRenderer\(rendererConfig\(input\.config\)\))/console.error("[OPENCODE_ANDROID_DIAG] before createCliRenderer");\n    $1/;
            s/(await createCliRenderer\(rendererConfig\(input\.config\)\))/await createCliRenderer(rendererConfig(input.config)).then((r) => {\n      console.error("[OPENCODE_ANDROID_DIAG] createCliRenderer resolved");\n      return r;\n    }).catch((e) => {\n      console.error("[OPENCODE_ANDROID_DIAG] createCliRenderer rejected:", e);\n      throw e;\n    })/;
            s/(await render\(\(\) => \{)/console.error("[OPENCODE_ANDROID_DIAG] before render");\n    await render(() => {/;
        ' "$APP_TSX"
        echo "    Patched $APP_TSX (TUI diagnostics)"
    else
        echo "    $APP_TSX already patched"
    fi
fi

# 5. Work around missing type-only AWS ESM exports that Bun 1.3.2 still tries
#    to resolve while bundling. Newer Bun versions are better here, but 1.3.2
#    remains pinned because its standalone module graph is compatible with the
#    Android Bun 1.2.13 runtime.
AWS_COGNITO_INDEX="$OPENCODE_SRC/node_modules/.bun/@aws-sdk+credential-provider-cognito-identity@"*/node_modules/@aws-sdk/credential-provider-cognito-identity/dist-es/index.js
for aws_index in $AWS_COGNITO_INDEX; do
    if [ -f "$aws_index" ]; then
        cat > "$aws_index" <<'AWSEOF'
const unsupported = () => {
  throw new Error("@aws-sdk/credential-provider-cognito-identity is not bundled in the Android build")
}
export const fromCognitoIdentity = unsupported
export const fromCognitoIdentityPool = unsupported
AWSEOF
        echo "    Patched $aws_index (stub optional Cognito provider)"
    fi
done

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$REPO_ROOT/scripts/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    ANDROID_BUN="$ANDROID_BUN" \
    OUTPUT_DIR="$DIST_DIR" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

# Clean up copied script
rm -f "$BUILD_SCRIPT_LOCAL"

# Restore original @opentui/core-linux-x64 files
if [ ${#OPENTUI_BACKUPS[@]} -gt 0 ]; then
    echo ">>> Restoring original @opentui/core-linux-x64 files..."
    for backup_spec in "${OPENTUI_BACKUPS[@]}"; do
        orig="${backup_spec%%:*}"
        backup="${backup_spec##*:}"
        if [ -f "$backup" ]; then
            mv "$backup" "$orig"
        fi
    done
fi

# ============================================================
# Optional: build opencode-debug using bun-profile (unstripped)
# ============================================================
# bun-profile keeps DWARF symbols so Zig's panic handler prints
# file:line stack traces. Non-fatal: skip gracefully if absent.
ANDROID_DEBUG_BUN="$BUN_BUILD/bun-profile"
if [ -f "$ANDROID_DEBUG_BUN" ]; then
    echo ""
    echo ">>> Building OpenCode debug variant (bun-profile, unstripped)..."
    DEBUG_OUTPUT_DIR="$DIST_DIR/.debug-tmp"
    DEBUG_BINARY="$DIST_DIR/opencode-debug"

    # Re-patch @opentui/core-linux-x64 for the second build pass
    DEBUG_OPENTUI_BACKUPS=()
    for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
        so_file="$pkg_dir/libopentui.so"
        idx_file=""
        if [ -f "$pkg_dir/index.js" ]; then
            idx_file="$pkg_dir/index.js"
        elif [ -f "$pkg_dir/index.ts" ]; then
            idx_file="$pkg_dir/index.ts"
        fi
        if [ -f "$so_file" ]; then
            debug_backup="${so_file}.x64.debug-bak"
            cp "$so_file" "$debug_backup"
            cp "$ARM64_LIBOPENTUI" "$so_file"
            DEBUG_OPENTUI_BACKUPS+=("$so_file:$debug_backup")
        fi
        if [ -n "$idx_file" ] && [ -f "$idx_file" ]; then
            debug_idx_backup="${idx_file}.debug-bak"
            cp "$idx_file" "$debug_idx_backup"
            cat > "$idx_file" <<'IDXEOF'
module.exports = process.env["OPENTUI_LIB_PATH"] || "/data/data/com.termux/files/usr/lib/libopentui.so";
IDXEOF
            DEBUG_OPENTUI_BACKUPS+=("$idx_file:$debug_idx_backup")
        fi
    done

    cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
    cd "$OPENCODE_PKG"
    OPENCODE_VERSION="$OPENCODE_VERSION" \
        ANDROID_BUN="$ANDROID_DEBUG_BUN" \
        OUTPUT_DIR="$DEBUG_OUTPUT_DIR" \
        OPENCODE_DIR="$OPENCODE_PKG" \
        "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL" && \
        mv "$DEBUG_OUTPUT_DIR/opencode" "$DEBUG_BINARY" && \
        echo "    Debug binary: $DEBUG_BINARY ($(du -h "$DEBUG_BINARY" | cut -f1))" || \
        echo "    WARNING: Debug variant build failed, skipping"

    rm -f "$BUILD_SCRIPT_LOCAL"
    rm -rf "$DEBUG_OUTPUT_DIR"

    # Restore @opentui/core-linux-x64 files after debug build
    if [ ${#DEBUG_OPENTUI_BACKUPS[@]} -gt 0 ]; then
        echo ">>> Restoring @opentui/core-linux-x64 files after debug build..."
        for backup_spec in "${DEBUG_OPENTUI_BACKUPS[@]}"; do
            orig="${backup_spec%%:*}"
            backup="${backup_spec##*:}"
            if [ -f "$backup" ]; then
                mv "$backup" "$orig"
            fi
        done
    fi
else
    echo ">>> bun-profile not found, skipping debug variant"
    echo "    (run 'ninja bun-profile' in the bun-build dir to enable it)"
fi

# Stage ARM64 libopentui.so for packaging. This MUST happen after the
# TypeScript build script because build-opencode-android.ts clears OUTPUT_DIR
# (which is DIST_DIR) at the start of its run.
mkdir -p "$DIST_DIR"
cp "$ARM64_LIBOPENTUI" "$DIST_DIR/libopentui.so"
echo ">>> Staged ARM64 libopentui.so for packaging"

# Stage ARM64 librust_pty_arm64.so for packaging if available.
# bun-pty ships a prebuilt ARM64 .so; make-packages.sh will include it so
# PTY features work on Android (Bun's /$bunfs/root/ paths are not intercepted).
RUST_PTY_ARM64_CANDIDATE=""
for candidate in \
    "$OPENCODE_SRC/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so" \
    "$OPENCODE_PKG/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so"
do
    if [ -f "$candidate" ]; then
        RUST_PTY_ARM64_CANDIDATE="$candidate"
        break
    fi
done
if [ -n "$RUST_PTY_ARM64_CANDIDATE" ] && is_android_shared_object "$RUST_PTY_ARM64_CANDIDATE"; then
    cp "$RUST_PTY_ARM64_CANDIDATE" "$DIST_DIR/librust_pty_arm64.so"
    echo ">>> Staged ARM64 librust_pty_arm64.so for packaging"
elif [ -n "$RUST_PTY_ARM64_CANDIDATE" ]; then
    rm -f "$DIST_DIR/librust_pty_arm64.so"
    echo ">>> WARNING: found ARM64 librust_pty_arm64.so, but it is linked for Linux/glibc; omitting from Android package"
else
    echo ">>> WARNING: librust_pty_arm64.so not found; PTY features may not work"
fi

# Verify output
OPENCODE_BINARY="$DIST_DIR/opencode"
if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    exit 1
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Binary: $OPENCODE_BINARY"
echo "Size: $(du -h "$OPENCODE_BINARY" | cut -f1)"
file "$OPENCODE_BINARY"
