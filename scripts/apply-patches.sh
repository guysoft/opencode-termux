#!/usr/bin/env bash
# Clone upstream repos and apply Android patches
#
# Usage: ./scripts/apply-patches.sh
#
# This script:
# 1. Clones oven-sh/bun at the pinned tag
# 2. Clones oven-sh/WebKit at the pinned commit
# 3. Applies patches from patches/
# 4. The Zig vendor patch is applied later by build-bun.sh after Bun's
#    build system downloads Zig

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Applying Patches ==="

# --- Clone Bun ---
if [ ! -d "$BUN_SRC/.git" ]; then
    echo ">>> Cloning Bun v${BUN_VERSION}..."
    git clone --depth 1 --branch "${BUN_TAG}" https://github.com/oven-sh/bun.git "$BUN_SRC"
else
    echo ">>> Bun source already exists at $BUN_SRC"
fi

# Apply Bun patch
echo ">>> Applying Bun Android patches..."
cd "$BUN_SRC"
git checkout -- . 2>/dev/null || true  # Reset any previous patches
git apply --stat "$REPO_ROOT/patches/bun/android-support.patch"
git apply "$REPO_ROOT/patches/bun/android-support.patch"
echo "    Bun patches applied successfully"

# --- Clone WebKit ---
if [ ! -d "$WEBKIT_SRC/.git" ]; then
    echo ">>> Cloning WebKit at commit ${WEBKIT_COMMIT}..."
    git clone --depth 1 https://github.com/AAAstorga/WebKit.git "$WEBKIT_SRC"
    cd "$WEBKIT_SRC"
    git fetch origin "${WEBKIT_COMMIT}" --depth=1
    git checkout "${WEBKIT_COMMIT}"
else
    echo ">>> WebKit source already exists at $WEBKIT_SRC"
fi

# Apply WebKit patch
echo ">>> Applying WebKit Android patches..."
cd "$WEBKIT_SRC"
git checkout -- . 2>/dev/null || true  # Reset any previous patches
git apply --stat "$REPO_ROOT/patches/webkit/android-support.patch"
git apply "$REPO_ROOT/patches/webkit/android-support.patch"
echo "    WebKit patches applied successfully"

echo ""
echo "=== Patches Applied ==="
echo "Bun source:    $BUN_SRC"
echo "WebKit source: $WEBKIT_SRC"
echo ""
echo "NOTE: The Zig vendor patch (patches/zig/posix-android-sigaction.patch)"
echo "      will be applied by build-bun.sh after Zig is downloaded by the"
echo "      Bun build system."
