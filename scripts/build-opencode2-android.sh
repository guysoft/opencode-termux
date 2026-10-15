#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

mkdir -p "$DIST_DIR"
cd "$OPENCODE_WORKTREE"
export PATH="$(dirname "$HOST_BUN"):$PATH"
export BUN_COMPILE_RELEASE="bun-v${BUN_VERSION}"
export OPENCODE_VERSION OPENCODE_CHANNEL

# Embed the patched Android Bun runtime (scripts/build-bun-android.sh) when
# present, so opencode2 carries the seccomp SIGSYS fix (oven-sh/bun#39775).
if [ -z "${OPENCODE_BUN_RUNTIME:-}" ]; then
  CANDIDATE="${BUN_ANDROID_OUT:-$DIST_DIR/bun-android}/bun"
  [ -x "$CANDIDATE" ] && export OPENCODE_BUN_RUNTIME="$CANDIDATE"
fi

"$HOST_BUN" install --ignore-scripts
cd packages/cli
"$HOST_BUN" run script/build.ts \
  --target=opencode2-linux-arm64-android \
  --skip-web-ui \
  --outdir="$DIST_DIR/cli"
cp "$DIST_DIR/cli/cli-linux-arm64-android/bin/opencode2" "$DIST_DIR/opencode2.bin"
chmod 755 "$DIST_DIR/opencode2.bin"
test -s "$OPENTUI_LIB"
