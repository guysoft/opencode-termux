#!/usr/bin/env bash
# Build a patched Bun runtime for Android aarch64 that converts seccomp SIGSYS
# traps into ENOSYS, so calls with an ENOSYS fallback (close_range, openat2,
# fchmodat2, pidfd_open, clone3, ...) work under Android's SECCOMP_RET_TRAP
# policy instead of killing the process with "Bad system call" (exit 159).
#
# Upstream: oven-sh/bun#30766 / #39060, fix in PR #39775 and #30769.
# Maintained as patches/bun/android-seccomp-sigsys.patch.
#
# Output: ${BUN_ANDROID_OUT:-$DIST_DIR/bun-android}/bun
#
# Host requirements: Rust (bun's pinned nightly), Ninja, CMake, LLVM 21
# (clang + lld), Android NDK r26+ ($ANDROID_NDK_HOME).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

BUN_SRC="${BUN_SRC:-${WORK_DIR}/bun-android}"
BUN_TAG="bun-v${BUN_VERSION}"
OUT_DIR="${BUN_ANDROID_OUT:-${DIST_DIR}/bun-android}"
PATCH="$REPO_ROOT/patches/bun/android-seccomp-sigsys.patch"

echo "=== Building patched Bun ${BUN_VERSION} for Android aarch64 ==="

if [ ! -d "$BUN_SRC/.git" ]; then
  git clone --depth 1 --branch "$BUN_TAG" https://github.com/oven-sh/bun.git "$BUN_SRC"
fi
git -C "$BUN_SRC" checkout -f "$BUN_TAG"
git -C "$BUN_SRC" clean -fdq src
git -C "$BUN_SRC" apply "$PATCH"
echo ">>> applied $PATCH"

# Host LLVM 21 toolchain.
# - $BUN_TOOLCHAIN_LLVM, if set, is used verbatim (dir with bin/clang, bin/ld.lld).
# - else if clang-21 + ld.lld-21 are discoverable on PATH, the build finds them.
# - else assemble a writable toolchain from the Ubuntu packages (no sudo):
#   clang-21 lives in /usr/lib/llvm-21; lld-21 is fetched with apt-get download.
TC="${BUN_TOOLCHAIN_LLVM:-}"
RES="${BUN_LLVM_RESOURCE_DIR:-${WORK_DIR}/llvm21-resource}"
if [ -z "$TC" ] && ! command -v ld.lld-21 >/dev/null 2>&1; then
  echo ">>> assembling LLVM 21 toolchain (no sudo) under ${WORK_DIR}"
  TC="${WORK_DIR}/llvm21-toolchain"; rm -rf "$TC"; mkdir -p "$TC/bin"
  for b in clang clang++ llvm-ar llvm-nm llvm-objcopy llvm-ranlib llvm-strip llvm-readelf; do
    [ -e "/usr/lib/llvm-21/bin/$b" ] && ln -sf "/usr/lib/llvm-21/bin/$b" "$TC/bin/$b"
  done
  LLD_DEB="${WORK_DIR}/lld-21.deb"
  if [ ! -f "$LLD_DEB" ]; then (cd "$WORK_DIR" && apt-get download lld-21); fi
  rm -rf "${WORK_DIR}/lld21-extract"
  dpkg-deb -x "$WORK_DIR"/lld-21_*.deb "${WORK_DIR}/lld21-extract"
  ln -sf "$(echo "${WORK_DIR}"/lld21-extract/usr/lib/llvm-21/bin/lld)" "$TC/bin/lld"
  ln -sf "$TC/bin/lld" "$TC/bin/ld.lld"

  # clang's resource dir must be writable so NDK compiler-rt can be linked in,
  # and clang must be pointed at it (the system dir is root-owned).
  NDKRT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang"
  NDKRT="$(ls -d ${NDKRT}/*/lib 2>/dev/null | head -1)"
  rm -rf "$RES"; cp -a /usr/lib/llvm-21/lib/clang/21 "$RES"
  ARCH=aarch64
  mkdir -p "$RES/lib/aarch64-unknown-linux-android${ANDROID_API}" "$RES/lib/linux/$ARCH"
  ln -sf "$NDKRT/linux/libclang_rt.builtins-${ARCH}-android.a" "$RES/lib/aarch64-unknown-linux-android${ANDROID_API}/libclang_rt.builtins.a"
  ln -sf "$NDKRT/linux/${ARCH}/libunwind.a" "$RES/lib/aarch64-unknown-linux-android${ANDROID_API}/libunwind.a"
  ln -sf "$NDKRT/linux/libclang_rt.builtins-${ARCH}-android.a" "$RES/lib/linux/libclang_rt.builtins-${ARCH}-android.a"
  ln -sf "$NDKRT/linux/${ARCH}/libunwind.a" "$RES/lib/linux/${ARCH}/libunwind.a"
  printf '#!/bin/sh\nexec /usr/lib/llvm-21/bin/clang -resource-dir=%s "$@"\n' "$RES" > "$TC/bin/clang"
  printf '#!/bin/sh\nexec /usr/lib/llvm-21/bin/clang++ -resource-dir=%s "$@"\n' "$RES" > "$TC/bin/clang++"
  chmod +x "$TC/bin/clang" "$TC/bin/clang++"
fi

echo ">>> building (NDK=$ANDROID_NDK_HOME, LLVM=${TC:-system})"
ENVV=(ANDROID_NDK_ROOT="$ANDROID_NDK_HOME")
[ -n "$TC" ] && ENVV+=(BUN_TOOLCHAIN_LLVM="$TC")
(cd "$BUN_SRC" && env "${ENVV[@]}" "$HOST_BUN" scripts/build.ts \
  --profile=android-release --build-dir=build/android-release)

mkdir -p "$OUT_DIR"
cp "$BUN_SRC/build/android-release/bun" "$OUT_DIR/bun"
chmod 755 "$OUT_DIR/bun"
echo ">>> patched Android Bun: $OUT_DIR/bun ($(stat -c%s "$OUT_DIR/bun") bytes)"
