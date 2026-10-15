#!/usr/bin/env bash
set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build-v2}"

# App version baked into the binary (shown by "opencode2 --version").
# This is the OpenCode 2 app line, independent of this repo release tags.
export OPENCODE_VERSION="${OPENCODE_VERSION:-2.0.0-android-termux.2}"
export OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-android-termux}"

# Release/package version for this repo downloads and tag names.
export RELEASE_VERSION="${RELEASE_VERSION:-1.0.3}"

export BUN_VERSION="${BUN_VERSION:-1.4.2}"
export OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.10}"
export ANDROID_API="${ANDROID_API:-29}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/home/guy/Android/Sdk/ndk/28.2.13676358}"
export ZIG_BIN="${ZIG_BIN:-/home/guy/.local/zig/zig-x86_64-linux-0.16.0/zig}"
export HOST_BUN="${HOST_BUN:-/home/guy/.local/bin/bun}"
export OPENCODE_WORKTREE="${OPENCODE_WORKTREE:-/home/guy/workspace/opencode/oc-v2}"
export DIST_DIR="${DIST_DIR:-${WORK_DIR}/dist}"
export PACKAGE_DIR="${PACKAGE_DIR:-${WORK_DIR}/packages}"

export NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export NDK_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
export BIONIC_SYSROOT_INC="${WORK_DIR}/bionic-include"
export ZIG_LIBC="${WORK_DIR}/bionic-libc.txt"
export OPENTUI_LIB="${WORK_DIR}/libopentui.so"
