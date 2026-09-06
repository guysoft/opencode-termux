#!/bin/sh
# install.sh — install opencode (upstream musl build) on Termux/Android
#
# Downloads the latest upstream opencode release (musl-linked, aarch64),
# extracts the musl dynamic linker + libstdc++/libgcc_s from Alpine,
# patches the binary's interpreter, and installs everything under $PREFIX.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/guysoft/opencode-termux/main/musl/install.sh | sh
# Or after cloning:
#   ./musl/install.sh
#
# Re-running is safe: it always re-downloads the latest upstream release.
#
# Requires: curl, tar (Termux has both by default).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$HOME/tmp}"
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
REPO="${REPO:-anomalyco/opencode}"
INSTALL_NAME="${INSTALL_NAME:-opencode}"

WORK="$TMPDIR/opencode-musl-install.$$"
mkdir -p "$WORK" "$TMPDIR"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Pick Termux arch (must be aarch64 — opencode upstream has no armv7 build).
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || die "Only aarch64 is supported (got: $ARCH)."

# Resolve latest version if requested.
if [ "$OPENCODE_VERSION" = "latest" ]; then
  log "Resolving latest opencode version..."
  OPENCODE_VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
  [ -n "$OPENCODE_VERSION" ] || die "Could not resolve latest version."
fi
log "Installing opencode $OPENCODE_VERSION"

# Pick a working Alpine mirror. Resolve the latest released Alpine version
# dynamically (so we don't pin to a version that goes EOL and 404s), then
# pick the latest matching .apk from its index.
log "Resolving Alpine release..."
ALPINE_VERSION=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/" \
  | grep -oE 'v[0-9]+\.[0-9]+/' | sort -uV | tail -1 | tr -d /)
[ -n "$ALPINE_VERSION" ] || die "Could not determine latest Alpine version."
log "Using Alpine $ALPINE_VERSION."

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VERSION/main/aarch64"
ALPINE_INDEX=$(curl -fsSL "$ALPINE_BASE/" \
  | grep -oE '(musl|libstdc\+\+|libgcc)-[0-9][^"<]*\.apk' | sort -uV)

MUSL_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^musl-' | tail -1)
LIBSTDC_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libstdc\+\+-' | tail -1)
LIBGCC_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libgcc-' | tail -1)

[ -n "$MUSL_PKG"    ] || die "Could not find musl .apk in $ALPINE_BASE/"
[ -n "$LIBSTDC_PKG" ] || die "Could not find libstdc++ .apk in $ALPINE_BASE/"
[ -n "$LIBGCC_PKG"  ] || die "Could not find libgcc .apk in $ALPINE_BASE/"
log "Using $MUSL_PKG, $LIBSTDC_PKG, $LIBGCC_PKG."

# Download upstream binary.
log "Downloading upstream musl binary..."
TARBALL="opencode-linux-arm64-musl.tar.gz"
URL="https://github.com/$REPO/releases/download/$OPENCODE_VERSION/$TARBALL"
curl -fsSL -o "$WORK/$TARBALL" "$URL" || die "Download failed: $URL"

# Download Alpine musl + C++ libs.
log "Downloading musl libc + libstdc++/libgcc_s from Alpine..."
curl -fsSL -o "$WORK/$MUSL_PKG"      "$ALPINE_BASE/$MUSL_PKG"      || die "musl download failed"
curl -fsSL -o "$WORK/$LIBSTDC_PKG"   "$ALPINE_BASE/$LIBSTDC_PKG"   || die "libstdc++ download failed"
curl -fsSL -o "$WORK/$LIBGCC_PKG"    "$ALPINE_BASE/$LIBGCC_PKG"    || die "libgcc download failed"

# Extract everything.
log "Extracting..."
cd "$WORK"
tar -xzf "$TARBALL" || die "Failed to extract tarball"
mkdir -p musl-libs
for pkg in "$MUSL_PKG" "$LIBSTDC_PKG" "$LIBGCC_PKG"; do
  (cd musl-libs && tar -xzf "../$pkg") || die "Failed to extract $pkg"
done

[ -f opencode ] || die "Tarball did not contain 'opencode' binary."

# Discover the actual libstdc++ filename in the extracted package. The
# upstream binary's DT_NEEDED entries reference "libstdc++.so.6" (the SONAME),
# so we install the versioned file and create a libstdc++.so.6 symlink to it.
LIBSTDC_FILE=$(ls musl-libs/usr/lib/libstdc++.so.6.*.* 2>/dev/null | head -1)
[ -n "$LIBSTDC_FILE" ] || die "Could not find libstdc++.so.6.* in extracted package."
log "Using $LIBSTDC_FILE."

# Install musl loader + libs into $PREFIX/lib.
log "Installing musl libs to $PREFIX/lib..."
install -d "$PREFIX/lib"
install -m 755 musl-libs/lib/ld-musl-aarch64.so.1  "$PREFIX/lib/"
install -m 755 musl-libs/usr/lib/libgcc_s.so.1     "$PREFIX/lib/"
install -m 755 "$LIBSTDC_FILE"                     "$PREFIX/lib/"
rm -f "$PREFIX/lib/libstdc++.so.6"
ln -s "$(basename "$LIBSTDC_FILE")" "$PREFIX/lib/libstdc++.so.6"

# Build libresolvefix.so — LD_PRELOAD shim that redirects musl's
# /etc/resolv.conf reads to Termux's $PREFIX/etc/resolv.conf.
log "Building libresolvefix.so..."
if ! command -v clang >/dev/null 2>&1; then
  warn "clang not found; attempting Termux install..."
  pkg install -y clang || die "Please install clang: pkg install clang"
fi
RESOLVEFIX_SRC="$WORK/libresolvefix.c"
if [ -f "$SCRIPT_DIR/libresolvefix.c" ]; then
  cp "$SCRIPT_DIR/libresolvefix.c" "$RESOLVEFIX_SRC"
else
  curl -fsSL -o "$RESOLVEFIX_SRC" \
    "https://raw.githubusercontent.com/guysoft/opencode-termux/main/musl/libresolvefix.c" \
    || die "Could not download libresolvefix.c"
fi
clang -shared -fPIC -o "$WORK/libresolvefix.so" "$RESOLVEFIX_SRC" \
  -Wl,--dynamic-linker="$PREFIX/lib/ld-musl-aarch64.so.1" \
  -L"$PREFIX/lib" -nostdlib \
  || die "Failed to compile libresolvefix.so"
install -m 755 "$WORK/libresolvefix.so" "$PREFIX/lib/"

# Install the HTTP proxy — Bun's io_uring-based networking doesn't work
# on Android, so we route API requests through a Python proxy on localhost.
log "Installing HTTP proxy..."
PROXY_SRC="$WORK/proxy.py"
if [ -f "$SCRIPT_DIR/proxy.py" ]; then
  cp "$SCRIPT_DIR/proxy.py" "$PROXY_SRC"
else
  curl -fsSL -o "$PROXY_SRC" \
    "https://raw.githubusercontent.com/guysoft/opencode-termux/main/musl/proxy.py" \
    || die "Could not download proxy.py"
fi
install -d "$PREFIX/libexec/opencode"
install -m 755 "$PROXY_SRC" "$PREFIX/libexec/opencode/proxy.py"

# Install the opencode binary into $PREFIX/libexec.
log "Installing opencode binary..."
install -d "$PREFIX/libexec/opencode"
install -m 755 opencode "$PREFIX/libexec/opencode/opencode-musl.bin"

# Patch the interpreter to point at the installed musl loader.
# patchelf is provided by the 'patchelf' Termux package.
if ! command -v patchelf >/dev/null 2>&1; then
  warn "patchelf not found; attempting Termux install..."
  pkg install -y patchelf || die "Please install patchelf: pkg install patchelf"
fi
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
  "$PREFIX/libexec/opencode/opencode-musl.bin"

# Install wrapper script.
log "Installing wrapper script..."
install -d "$PREFIX/bin"
cat > "$PREFIX/bin/$INSTALL_NAME" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/sh
# opencode wrapper for the upstream musl-linked build.
#
# Why this exists: opencode upstream is a musl-linked binary that uses
# musl's libc, so a plain 'exec' would inherit the user's environment
# unchanged. The previous Termux wrappers (guysoft) LD_PRELOAD'd glibc
# shims and used env vars aimed at glibc-linked binaries. When the
# user upgrades and keeps their old wrapper, the glibc-only symbols
# (__register_atfork, __errno, __strlen_chk, etc.) referenced by those
# shims don't exist in musl, causing a crash before main() even runs.
#
# This wrapper:
#   - clears LD_PRELOAD (so any stale glibc shim is dropped),
#   - loads libresolvefix.so (redirects musl's /etc/resolv.conf
#     reads to Termux's $PREFIX/etc/resolv.conf for DNS),
#   - sets the env vars opencode needs on Android (no TUI audio,
#     no @parcel/watcher, sane TMPDIRs, TERM for the TUI),
#   - runs the binary against the musl loader we just installed.
#
# NOTE: we do NOT use env -i. On Android, DNS resolution depends on
# bionic's resolver which reads system properties and Android's netd
# daemon — not env vars, but the resolver needs access to the system
# libraries that provide these. env -i strips everything and breaks
# DNS completely (curl returns "Could not resolve host"). Instead we
# set only what we need and unset what we don't.
unset LD_PRELOAD
export LD_PRELOAD="$PREFIX/lib/libresolvefix.so"
export HOME
export PATH
export PREFIX
export TERM="${TERM:-xterm-256color}"
export LANG="${LANG:-en_US.UTF-8}"
export TMPDIR="${TMPDIR:-$HOME/tmp}"
export TEMP="${TMPDIR:-$HOME/tmp}"
export TMP="${TMPDIR:-$HOME/tmp}"
export TERMUX_VERSION
export ANDROID_ROOT="${ANDROID_ROOT:-/system}"
export LD_LIBRARY_PATH="$PREFIX/lib"
export OPENCODE_DISABLE_TUI_AUDIO=1
export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER=true
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
export NODE_EXTRA_CA_CERTS="$PREFIX/etc/tls/cert.pem"
export CURL_CA_BUNDLE="$PREFIX/etc/tls/cert.pem"
export HTTP_PROXY="http://127.0.0.1:8080"
export http_proxy="http://127.0.0.1:8080"
export HTTPS_PROXY="http://127.0.0.1:8080"
export https_proxy="http://127.0.0.1:8080"

# Start the HTTP proxy if not already running.
# Bun's io_uring networking doesn't work on Android, so API requests
# go through this Python proxy on localhost.
if ! pgrep -f "proxy.py" >/dev/null 2>&1; then
  nohup python3 "$PREFIX/libexec/opencode/proxy.py" >/dev/null 2>&1 &
  sleep 0.3
fi

exec "$PREFIX/libexec/opencode/opencode-musl.bin" "$@"
WRAPPER
chmod +x "$PREFIX/bin/$INSTALL_NAME"

log "Done. Try: $INSTALL_NAME --version"
"$PREFIX/bin/$INSTALL_NAME" --version
