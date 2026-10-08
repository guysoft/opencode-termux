# OpenCode 1.17.10 for Android/Termux (aarch64) — v0.2.2 preview

## Summary

Upgrade from OpenCode **1.17.9** to **1.17.10**, with OpenTUI **0.4.2** (`@opentui/core` gitHead `3e2d0aabeb47923f05adc6f1052401367cfde3d4`).

This build carries forward the Android fixes from [v0.2.1](https://github.com/guysoft/opencode-termux/releases/tag/v0.2.1) and fixes [#9](https://github.com/guysoft/opencode-termux/issues/9).

## What changed in 1.17.10

- OpenCode bumped to **1.17.10**
- OpenTUI bumped from **0.3.4** to **0.4.2**
- Android OpenTUI patch updated for 0.4.2 Yoga C++ / NDK `libc++_shared.so` linking
- Yoga callback allocator switched to `page_allocator` for Android Zig builds
- All v0.2.1 runtime fixes preserved:
  - real filesystem `libopentui.so` via `OPENTUI_LIB_PATH`
  - bundled `libtagfix.so` and `libc++_shared.so`
  - TUI audio disabled
  - OpenTUI built with `ReleaseFast` (no Zig integer safety traps)
  - native span-feed cleanup protection
  - FFI `toU32()` sanitization and `useFeedOutput = false`

## Validation

### Android 15 (SM-G970F, SDK 35)

- Installed `opencode_1.17.10_aarch64.deb`
- `opencode --version` reports `1.17.10`
- 5-prompt interactive smoke passed:
  - `working?`
  - `what can you do?`
  - `run ls`
  - `explain this session briefly`
  - `run ls again and summarize the files`
- TTY log scan: **no** `panic`, `Unexpected`, `Effect`, `Error`, `thread panic`, or `integer does not fit` markers

### Android 12 (daily driver)

- Pending device connection for the same 5-prompt smoke test
- Use pacman package on pacman-based Termux installs

## Install

**Termux (pacman):**
```bash
pacman -U opencode-1.17.10-1-aarch64.pkg.tar.xz
```

**Termux (dpkg):**
```bash
dpkg -i opencode_1.17.10_aarch64.deb
```

**Standalone (zip):**
```bash
unzip opencode-1.17.10-android-aarch64.zip -d $PREFIX/bin/
chmod +x $PREFIX/bin/opencode $PREFIX/bin/opencode.bin
```

## Android compatibility fixes

1. **Pointer tag SIGABRT** — `libtagfix.so` disables bionic heap tagging before JSC starts.
2. **OpenTUI load failure** — ships real `libopentui.so`; wrapper sets `OPENTUI_LIB_PATH`.
3. **Missing libc++** — ships NDK `libc++_shared.so` with `LD_LIBRARY_PATH` setup.
4. **TUI thread panic** — OpenTUI built `ReleaseFast` with audio/span-feed guards and FFI `u32` sanitization.

If opencode still crashes with a Zig panic, run `opencode-debug` and paste the full stack trace.

## Build info

- Bun: v1.2.13 (cross-compiled for Android aarch64)
- OpenCode: 1.17.10
- OpenTUI: 0.4.2 (`3e2d0aabeb47923f05adc6f1052401367cfde3d4`)
- WebKit/JSC: 017930ebf915121f8f593bef61cbbca82d78132d
- Android API level: 24
- NDK: r28b

## Release recommendation

- Publish as **pre-release** `v0.2.2-rc1` after Android 12 smoke passes
- Promote to **v0.2.2** final once both Android 12 and 15 are green
