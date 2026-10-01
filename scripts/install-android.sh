#!/usr/bin/env bash
# Install OpenCode 2 for Android/Termux from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/guysoft/opencode-termux/main/scripts/install-android.sh | bash
#
# Downloads the newest release asset for your ABI, verifies it against the
# published SHA256SUMS, and installs it.
#
# Supported: aarch64 (arm64-v8a). Other ABIs are reported, not attempted.
#
# Environment:
#   OPENCODE2_VERSION   pin a release tag (default: latest)
#   OPENCODE2_PREFIX    install prefix (default: $PREFIX or the Termux prefix)

set -euo pipefail

REPO="guysoft/opencode-termux"
API="https://api.github.com/repos/${REPO}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform --
if [ "$(uname -s)" != "Android" ]; then
    die "this installer is for Android/Termux (uname -s is $(uname -s))"
fi

case "$(uname -m)" in
    aarch64|arm64) ABI="aarch64" ;;
    *) die "unsupported CPU architecture: $(uname -m) (only aarch64 is published)" ;;
esac

PREFIX="${OPENCODE2_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode2-install.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------------ release --
if [ -n "${OPENCODE2_VERSION:-}" ]; then
    TAG="$OPENCODE2_VERSION"
    log "using pinned release ${TAG}"
else
    log "resolving latest release"
    TAG="$(curl -fsSL "$API/releases/latest" \
           | grep -m1 '"tag_name"' \
           | sed -E 's/.*"([^"]+)".*/\1/')" || true
    [ -n "$TAG" ] || TAG="$(curl -fsSL "$API/tags" \
           | grep -m1 '"name"' \
           | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$TAG" ] || die "could not determine the latest release (offline?)"
    log "latest release is ${TAG}"
fi

# Prefer the .deb / .pkg.tar.xz; fall back to the flat zip.
ASSET_PKG="opencode2-${TAG}-1-${ABI}.pkg.tar.xz.pkg.tar.xz"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

# The release naming has varied across tags, so probe for what actually exists.
pick_asset() {
    for name in \
        "opencode2-${TAG#v}-1-${ABI}.pkg.tar.xz" \
        "opencode2-${TAG#v}_${ABI}.deb" \
        "opencode2-${TAG#v}-android-${ABI}.zip"
    do
        if curl -fsSLI -o /dev/null "${BASE}/${name}" 2>/dev/null; then
            printf '%s' "$name"; return 0
        fi
    done
    return 1
}

log "looking for a suitable release asset"
ASSET="$(pick_asset || true)"
[ -n "$ASSET" ] || die "no ${ABI} asset published for ${TAG}
       check the releases page: https://github.com/${REPO}/releases/tag/${TAG}"
log "asset: ${ASSET}"

# ---------------------------------------------------------------- download ---
curl -fSL --progress-bar -o "$WORK/pkg" "${BASE}/${ASSET}"

# Verify against the published SHA256SUMS when it exists.
if curl -fsSL -o "$WORK/SHA256SUMS" "${BASE}/SHA256SUMS" 2>/dev/null; then
    log "verifying checksum"
    ( cd "$WORK" && grep " ${ASSET}\$" SHA256SUMS > sums.txt ) \
        || die "SHA256SUMS does not list ${ASSET}"
    ( cd "$WORK" && sed -n 's/^([0-9a-f]\{64\}) .*/\1/p' sums.txt > want.txt )
    GOT="$(sha256sum "$WORK/pkg" | cut -d' ' -f1)"
    [ "$GOT" = "$(cat "$WORK/want.txt")" ] \
        || die "checksum mismatch for ${ASSET}
       expected $(cat "$WORK/want.txt")
       got      ${GOT}"
    log "checksum OK"
else
    warn "no SHA256SUMS published for ${TAG}; skipping verification"
fi

# ----------------------------------------------------------------- install --
case "$ASSET" in
    *.zip)
        log "installing from zip"
        mkdir -p "$WORK/x"
        unzip -q "$WORK/pkg" -d "$WORK/x" || die "unzip failed"
        mkdir -p "$PREFIX/libexec/opencode2"
        cp "$WORK/x/opencode2.bin" "$PREFIX/libexec/opencode2/opencode2.bin"
        cp "$WORK/x/libopentui.so" "$PREFIX/libexec/opencode2/libopentui.so"
        cp "$WORK/x/opencode2"      "$PREFIX/bin/opencode2"
        ;;
    *.deb)
        log "installing from deb"
        command -v dpkg >/dev/null 2>&1 && dpkg -i "$WORK/pkg" \
            || die "dpkg unavailable; download the .deb and run: dpkg -i ${ASSET}"
        ;;
    *)
        log "installing from pacman package"
        mkdir -p "$WORK/p" && tar -xf "$WORK/pkg" -C "$WORK/p"
        mkdir -p "$PREFIX/libexec/opencode2"
        cp "$WORK/p/data/data/com.termux/files/usr/bin/opencode2" \
           "$PREFIX/bin/opencode2"
        cp "$WORK/p/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin" \
           "$PREFIX/libexec/opencode2/opencode2.bin"
        cp "$WORK/p/data/data/com.termux/files/usr/libexec/opencode2/libopentui.so" \
           "$PREFIX/libexec/opencode2/libopentui.so"
        ;;
esac

chmod 755 "$PREFIX/bin/opencode2" \
         "$PREFIX/libexec/opencode2/opencode2.bin" 2>/dev/null || true
chmod 644 "$PREFIX/libexec/opencode2/libopentui.so" 2>/dev/null || true

# `opencode` is the friendly name; opencode2 is the real command.
if [ ! -e "$PREFIX/bin/opencode" ] || [ -L "$PREFIX/bin/opencode" ]; then
    ln -sf "$PREFIX/bin/opencode2" "$PREFIX/bin/opencode"
fi

# ripgrep is a declared runtime dependency.
if ! command -v rg >/dev/null 2>&1; then
    warn "ripgrep (rg) is missing and OpenCode needs it. Install with: pkg install ripgrep"
fi

# ------------------------------------------------------------------ verify --
log "verifying installation"
"$PREFIX/bin/opencode2" --version

cat <<EOF

$(printf '\033[1;32mOpenCode 2 installed successfully.\033[0m')

  version : ${TAG}
  prefix  : ${PREFIX}
  binary  : ${PREFIX}/libexec/opencode2/opencode2.bin
  renderer: ${PREFIX}/libexec/opencode2/libopentui.so

  run     : opencode
  update  : opencode2 upgrade

EOF
