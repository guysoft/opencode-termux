#!/usr/bin/env sh
# patch-opentui-crash.sh - stop the OpenCode 2 TUI from aborting (SIGABRT)
#
#   sh patch-opentui-crash.sh                 # patch the installed library
#   OPENCODE2_LIB=/path/to/libopentui.so sh patch-opentui-crash.sh
#
# ## Why this exists
#
# Opening an OpenCode 2 session with enough content to render kills the whole
# CLI:
#
#   thread N panic: integer does not fit in destination type
#   packages/native/src/buffer.zig:925
#     in setVisibleCellWithAlphaBlending
#
# followed by a Bun backtrace full of `???` frames and exit code 134. A fresh
# session is fine; the crash needs transcript content, and gets more likely as
# the session grows.
#
# The cause is in the native renderer, not in JavaScript. Cell coordinates reach
# `setVisibleCellWithAlphaBlending` as u32 and are narrowed to the i32 that
# `isPointInScissor` takes. A u32 above 2147483647 cannot be represented as an
# i32, so the @intCast is undefined behaviour. The library is built
# ReleaseSafe, so Zig's safety check turns that into abort() instead of letting
# the cell be skipped.
#
# Such a coordinate is never a real screen position - it is an off-buffer value
# that wrapped. The correct behaviour is to clip it, which is what the upstream
# source fix does (patches/opentui/negative-cell-coord-intcast.patch).
#
# ## What this script does
#
# For releases that already contain the source fix there is nothing to do and
# the script says so. For older ones it edits the shipped binary: each
# "coordinate >= 2^31 -> panic" branch is repointed at the function's own
# existing early-return path, the same one its ordinary off-screen visibility
# tests already use. A negative or out-of-range cell is then simply not drawn,
# which is the intended behaviour.
#
# Only the 19-bit branch offset of each instruction changes. The opcode, the
# bit-test position and the register are bit-identical, so no code is added,
# removed, or re-laid-out. The patch is verified before and after, and the
# original library is always kept as <name>.orig.
#
# Re-running is safe: an already-patched library is detected and left alone.
# To undo: cp libopentui.so.orig libopentui.so

set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LIB="${OPENCODE2_LIB:-$PREFIX/libexec/opencode2/libopentui.so}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v objdump >/dev/null 2>&1 || warn "objdump not found; verification will be limited"

[ -f "$LIB" ] || die "libopentui.so not found at:
       $LIB
       set OPENCODE2_LIB=/path/to/libopentui.so to point at it"

log "target: $LIB"

python3 - "$LIB" <<'PY'
import os, re, struct, subprocess, sys

lib = sys.argv[1]
data = bytearray(open(lib, 'rb').read())

# --- locate the file offset of a virtual address -----------------------------
e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
phentsize = struct.unpack_from('<H', data, 0x36)[0]
phnum = struct.unpack_from('<H', data, 0x38)[0]
segs = []
for i in range(phnum):
    b = e_phoff + i * phentsize
    p_type, = struct.unpack_from('<I', data, b)
    p_off, p_va, _pa, p_fsz, _msz = struct.unpack_from('<QQQQQ', data, b + 8)
    if p_type == 1:  # PT_LOAD
        segs.append((p_va, p_off, p_fsz))

def file_off(va):
    for va_base, off, fsz in segs:
        if va_base <= va < va_base + fsz:
            return off + (va - va_base)
    raise SystemExit('error: vaddr %#x is not mapped' % va)

def word(va):
    return struct.unpack_from('<I', data, file_off(va))[0]

def sym_at(va):
    try:
        out = subprocess.run(['nm', '-C', lib], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return '?'
    best = None
    for line in out.splitlines():
        p = line.split(None, 2)
        if len(p) == 3 and p[1].lower() in ('t', 'w'):
            try:
                a = int(p[0], 16)
            except ValueError:
                continue
            if a <= va and (best is None or a > best[0]):
                best = (a, p[2])
    return best[1] if best else '?'

# --- what we are fixing ------------------------------------------------------
# Each entry is a "tbnz wN, #0x1f -> <panic pad>" branch. Bit 31 set means the
# u32 coordinate is >= 2^31, which cannot be narrowed to i32. We repoint it at
# the enclosing function's existing early-return path, so the cell is clipped.
#
# The replacement encodings are NOT computed: in TBNZ the 5-bit bit-position
# field overlaps the 19-bit branch offset, so masking one can silently corrupt
# the other. They were produced by the NDK assembler instead, which is the
# authority on the encoding:
#
#   aarch64-linux-android-clang -c <<< 'tbnz w1,#31,.+40'   ->  37f80141
#
# and each replacement was cross-checked to differ from the original only in
# the branch-offset bits.
#
#   (vaddr, symbol, original word, replacement word, panic pad, return path)
PATCHES = [
    (0x2eaa64, 'setCellWithAlphaBlendingCell', 0x37f81b61, 0x37f80141, 0x2eadd0, 0x2eaa8c),
    (0x2eaa68, 'setCellWithAlphaBlendingCell', 0x37f81b42, 0x37f80122, 0x2eadd0, 0x2eaa8c),
    (0x2eaac0, 'setCellWithAlphaBlendingCell', 0x37f8188c, 0x37fffe6c, 0x2eadd0, 0x2eaa8c),
    (0x2eaaE4, 'setCellWithAlphaBlendingCell', 0x37f8176a, 0x37fffd4a, 0x2eadd0, 0x2eaa8c),
    (0x2b6268, 'bufferDrawChar',               0x37f81f02, 0x37f81ba2, 0x2b6648, 0x2b65dc),
    (0x2b626c, 'bufferDrawChar',               0x37f81ee3, 0x37f81b83, 0x2b6648, 0x2b65dc),
    (0x2b6290, 'bufferDrawChar',               0x37f81dd0, 0x37f81a70, 0x2b6648, 0x2b65dc),
    (0x2b62b4, 'bufferDrawChar',               0x37f81cae, 0x37f8194e, 0x2b6648, 0x2b65dc),
]

# How many branches still reach each panic pad. objdump prints the branch
# target inside angle brackets, e.g. "b.ne 0x2eadd0 <symbol+0x3f8>".
def count_branches_to(target):
    try:
        out = subprocess.run(['objdump', '-d', lib], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return None
    needle = '0x%x <' % target
    n = 0
    for line in out.splitlines():
        head, _tab, tail = line.partition('\t')
        if not tail:
            continue
        mnem = tail.split()[0] if tail.split() else ''
        # Branch mnemonics: b, bl, b.<cond>, cbz/cbnz, tbz/tbnz.
        if re.match(r'^(b|cb|tb)', mnem) and needle in tail:
            n += 1
    return n

# --- already fixed? ----------------------------------------------------------
pads = sorted({p[4] for p in PATCHES})   # index 4 = panic pad
remaining = {pad: count_branches_to(pad) for pad in pads}
if all(v == 0 for v in remaining.values() if v is not None):
    print('==> already patched: no branch reaches the panic pads any more.')
    print('    Nothing to do.')
    raise SystemExit(0)

# --- back up -----------------------------------------------------------------
bak = lib + '.orig'
if not os.path.exists(bak):
    with open(bak, 'wb') as f:
        f.write(data)
    os.chmod(bak, 0o755)
    print('==> backup written: %s' % bak)
else:
    print('==> backup already present: %s' % bak)

# --- apply -------------------------------------------------------------------
print('==> patching (panic -> clip/early-return):')
changed = 0
for va, sym, expect_old, expect_new, _pad, _ret in PATCHES:
    off = file_off(va)
    cur = struct.unpack_from('<I', data, off)[0]

    if cur == expect_new:
        print('    %#-9x %-28s already patched' % (va, sym))
        continue
    if cur != expect_old:
        print('    %#-9x %-28s SKIPPED (unexpected bytes %#010x, want %#010x)'
              % (va, sym, cur, expect_old))
        continue

    struct.pack_into('<I', data, off, expect_new)
    print('    %#-9x %-28s %#010x -> %#010x' % (va, sym, cur, expect_new))
    changed += 1

if changed == 0:
    print('error: nothing was patched; the library may be a different build.')
    raise SystemExit(1)

with open(lib, 'wb') as f:
    f.write(data)
os.chmod(lib, 0o755)
print('==> %d instruction(s) patched' % changed)

# --- verify ------------------------------------------------------------------
print('==> verifying')
ok = True
for va, sym, _old, expect_new, _pad, _ret in PATCHES:
    got = word(va)
    if got != expect_new:
        print('    %#-9x %-28s BAD: %#010x, expected %#010x' % (va, sym, got, expect_new))
        ok = False
    else:
        print('    %#-9x %-28s ok' % (va, sym))
if not ok:
    raise SystemExit('error: post-patch verification failed')

for pad in pads:
    n = count_branches_to(pad)
    if n is None:
        print('    (objdump unavailable, skipped branch census)')
    else:
        state = 'OK' if n == 0 else 'STILL %d BRANCH(ES)' % n
        print('    branches reaching panic pad %#x: %d  %s' % (pad, n, state))
        if n:
            ok = False

if not ok:
    raise SystemExit('error: verification failed')

print()
print('==> done. The TUI will no longer abort on out-of-range cell coordinates.')
print('    rollback: cp %s.orig %s' % (os.path.basename(lib), lib))
PY
