#!/usr/bin/env bash
# Environment variables for building OpenCode for Android aarch64
# Source this file before running any build scripts:
#   source scripts/env.sh

set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Versions
export BUN_VERSION="${BUN_VERSION:-1.2.13}"
export BUN_TAG="bun-v${BUN_VERSION}"
export WEBKIT_COMMIT="${WEBKIT_COMMIT:-017930ebf915121f8f593bef61cbbca82d78132d}"
export ICU_VERSION="${ICU_VERSION:-75.1}"
export ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
export OPENCODE_VERSION="${OPENCODE_VERSION:-1.3.13}"
export ANDROID_API="${ANDROID_API:-24}"

# Android NDK
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
export ANDROID_ABI=arm64-v8a
export ANDROID_ARCH=aarch64
export ANDROID_TRIPLE="aarch64-linux-android"
export ANDROID_TRIPLE_API="${ANDROID_TRIPLE}${ANDROID_API}"

# NDK toolchain paths
export NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export NDK_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
export ANDROID_CC="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang"
export ANDROID_CXX="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang++"
export ANDROID_AR="${NDK_TOOLCHAIN}/bin/llvm-ar"
export ANDROID_RANLIB="${NDK_TOOLCHAIN}/bin/llvm-ranlib"
export ANDROID_STRIP="${NDK_TOOLCHAIN}/bin/llvm-strip"
export ANDROID_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
export ANDROID_LD="${NDK_TOOLCHAIN}/bin/ld.lld"

# Build directories (all relative to REPO_ROOT)
export WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build}"
export BUN_SRC="${WORK_DIR}/bun-src"
export WEBKIT_SRC="${WORK_DIR}/webkit-src"
export OPENTUI_SRC="${WORK_DIR}/opentui-src"
export OPENCODE_SRC="${WORK_DIR}/opencode-src"
export ICU_SRC="${WORK_DIR}/icu-src"

export DEPS_PREFIX="${WORK_DIR}/deps-android/prefix"
export WEBKIT_BUILD="${WORK_DIR}/webkit-build"
export WEBKIT_OUTPUT="${WORK_DIR}/webkit-android"
export BUN_BUILD="${WORK_DIR}/bun-build"
export DIST_DIR="${WORK_DIR}/dist"

# Number of parallel jobs (can be overridden for low-RAM machines)
export JOBS="${JOBS:-$(nproc)}"

echo "=== OpenCode Android Build Environment ==="
echo "Repo root:     ${REPO_ROOT}"
echo "Work dir:      ${WORK_DIR}"
echo "NDK:           ${ANDROID_NDK_HOME}"
echo "API Level:     ${ANDROID_API}"
echo "Target:        ${ANDROID_TRIPLE}"
echo "Bun version:   ${BUN_VERSION}"
echo "WebKit commit: ${WEBKIT_COMMIT}"
echo "OpenCode ver:  ${OPENCODE_VERSION}"
echo "Jobs:          ${JOBS}"
echo "==========================================="
