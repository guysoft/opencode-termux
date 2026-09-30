#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

src="${OPENTUI_SRC:-${WORK_DIR}/opentui-${OPENTUI_VERSION}}"
mkdir -p "$WORK_DIR"
if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git "$src"
fi
git -C "$src" apply "$REPO_ROOT/patches/opentui/v2-0.5.10-android.patch" 2>/dev/null || true
# Clip off-buffer cell coordinates before the u32 -> i32 narrowing in
# setVisibleCellWithAlphaBlending. Without this, a coordinate >= 2^31 trips the
# ReleaseSafe @intCast check and aborts the whole process (SIGABRT) instead of
# just skipping the cell. See patches/opentui/README.md.
git -C "$src" apply "$REPO_ROOT/patches/opentui/negative-cell-coord-intcast.patch"

rm -rf "$BIONIC_SYSROOT_INC"
mkdir -p "$BIONIC_SYSROOT_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_SYSROOT_INC/"
cp -a "$NDK_SYSROOT/usr/include/aarch64-linux-android/." "$BIONIC_SYSROOT_INC/"
mkdir -p "$BIONIC_SYSROOT_INC/__opentui"
cat > "$BIONIC_SYSROOT_INC/__opentui/miniaudio_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../miniaudio.h"
EOF
cat > "$BIONIC_SYSROOT_INC/__opentui/Yoga_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../yoga/yoga/Yoga.h"
EOF

cat > "$ZIG_LIBC" <<EOF
include_dir=$BIONIC_SYSROOT_INC
sys_include_dir=$BIONIC_SYSROOT_INC
crt_dir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/29
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

export ANDROID_NDK_HOME BIONIC_SYSROOT_INC ZIG_LIBC
cd "$src/packages/native"
"$ZIG_BIN" build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
cp "lib/aarch64-linux-android/libopentui.so" "$OPENTUI_LIB"
