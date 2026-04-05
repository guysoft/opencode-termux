# OpenCode for Termux (Android aarch64)

Build system for cross-compiling [OpenCode](https://github.com/anomalyco/opencode) to run natively on Android devices via [Termux](https://termux.dev/).

OpenCode is an AI-powered coding assistant for the terminal. It uses [Bun](https://bun.sh/) as its JavaScript runtime and compiles to a standalone binary via `bun build --compile`. Since Bun has no official Android support (marked "not planned"), this project cross-compiles Bun itself from source for Android/aarch64, including WebKit/JavaScriptCore.

## Quick Install (Termux)

```bash
# Download the latest release
curl -LO https://github.com/guysoft/opencode-termux/releases/latest/download/opencode-aarch64.pkg.tar.xz

# Install with pacman
pacman -U opencode-*-aarch64.pkg.tar.xz

# Or install the .deb
curl -LO https://github.com/guysoft/opencode-termux/releases/latest/download/opencode-aarch64.deb
dpkg -i opencode-*-aarch64.deb

# Run
opencode
```

Requires `ripgrep` (installed automatically as a dependency).

## What This Repo Contains

This repo contains **patch files and build scripts** only -- not the full source trees of Bun or WebKit (which are 1.1GB and 2.7GB respectively). The CI workflow clones upstream repos and applies patches during build.

```
opencode-termux/
  patches/
    bun/android-support.patch      # 33 files, Bun Android/aarch64 support
    webkit/android-support.patch   # 5 files, WebKit/JSC Android fixes
    zig/posix-android-sigaction.patch  # Zig stdlib sigaction/sigprocmask fix
    opentui/android-libc-link.patch  # Link NDK libc.so for Android dlopen
  scripts/
    apply-patches.sh               # Clone upstream repos + apply patches
    build-icu.sh                   # Cross-compile ICU 75.1 for Android
    build-webkit.sh                # Cross-compile WebKit/JSC for Android
    build-bun.sh                   # Cross-compile Bun for Android
    build-opentui.sh               # Build libopentui.so for Android
    build-opencode.sh              # Build OpenCode standalone binary
    make-packages.sh               # Create zip, pacman, and deb packages
    build-opencode-android.ts      # TypeScript build script (module graph extraction)
  cmake/
    webkit-android-toolchain.cmake # WebKit CMake cross-compilation toolchain
  .github/workflows/
    build.yml                      # GitHub Actions CI workflow
```

## Build Requirements

- **Build host**: x86_64 Linux (Ubuntu 22.04+)
- **RAM**: 16GB minimum (30GB recommended for WebKit link step)
- **Disk**: 60GB+ free space
- **CPU**: 8+ cores recommended

### Required tools

| Tool | Version | Purpose |
|------|---------|---------|
| Android NDK | r28b (28.1.13356709) | Cross-compiler toolchain |
| CMake | 3.20+ | Build system |
| Ninja | 1.10+ | Build tool |
| Rust | stable | lol-html crate (with `aarch64-linux-android` target) |
| Go | 1.20+ | BoringSSL |
| Zig | 0.15.2 | libopentui.so build |
| Bun | 1.1+ (host) | OpenCode bundling + build scripts |
| Python3 | 3.8+ | WebKit code generation |
| Ruby | 2.7+ | WebKit code generation |
| Perl | 5.20+ | WebKit code generation |

## Version Pins

| Component | Version/Commit |
|-----------|---------------|
| Bun | v1.2.13 (tag `bun-v1.2.13`) |
| WebKit/JSC | `017930ebf915121f8f593bef61cbbca82d78132d` (oven-sh/WebKit) |
| ICU | 75.1 |
| Android NDK | r28b |
| Android API level | 24 (Android 7.0+) |
| Zig (for opentui) | 0.15.2 |
| OpenCode | 1.3.13 |

## What Was Patched and Why

### Bun Patches (33 files)

Bun has zero Android support. Every patch falls into one of these categories:

**Build system (CMake/Zig)**
- Android NDK CMake toolchain (`cmake/toolchains/android-aarch64.cmake`)
- `-fPIC` instead of `-fno-pic` (Android requires position-independent code)
- Rust linker set to NDK's versioned clang for lol-html crate
- Zig `translate-c` given NDK sysroot headers (Zig has no bundled Android libc)
- TLS alignment assembly (`.tbss` with 64-byte alignment for Bionic)

**Syscall compatibility**
- `close_range()` fallback -- blocked by Android's seccomp filter in app processes; iterates `/proc/self/fd` instead
- `preadv2`/`pwritev2` return ENOSYS (not in Android kernel)
- `epoll_pwait2` return ENOSYS (not in Android kernel)
- `lchmod` return ENOSYS (not in Bionic)

**Bionic libc differences**
- `memmem`, `lstat`, `fstat`, `stat` as extern declarations (symbol visibility differences)
- `getifaddrs`/`freeifaddrs` extern wrappers (hidden by `__INTRODUCED_IN` macros)
- `pthread_setcancelstate` stubbed (Bionic has no POSIX thread cancellation)
- `posix_spawnattr_setsigdefault/setsigmask` stubbed (requires API 28, we target 24)
- No separate `-lpthread` (merged into libc on Bionic)

**JSC/JIT fixes**
- Signal-based VM traps disabled (`usePollingTraps=true`) -- Android's `debuggerd` intercepts SIGSEGV before the app's signal handler
- Wasm fault signal handler disabled -- uses explicit bounds checking instead
- Options set via `setenv("JSC_*")` before `JSC::initialize()` because `Options::initialize()` resets all options to defaults

**Standalone binary format**
- `StandaloneModuleGraph.zig` Offsets struct updated from 24 to 32 bytes to match host Bun v1.3.11 format (which generates the module graph)

### WebKit Patches (5 files)

- `bcmp` replaced with `memcmp` (bcmp is BSD, not available on Bionic)
- `aligned_alloc` replaced with `posix_memalign` (aligned_alloc requires API 28)
- `backtrace()` stubbed (requires API 33)
- `pthread_getname_np` stubbed (requires API 26)
- JSC `InitializeThreading.cpp`: force polling traps and disable Wasm signal handler on Android

### Zig Stdlib Patch (1 file)

- `sigaction()` and `sigprocmask()` bypass Bionic libc and use raw `rt_sigaction`/`rt_sigprocmask` syscalls on Android. Bionic's `sigaction` struct is 32 bytes with 8-byte `sigset_t`, but Zig's `linux.Sigaction` is 152 bytes with 128-byte `sigset_t`. The struct layout mismatch causes silent memory corruption.

## Build Pipeline

The build has 7 stages:

```
1. ICU 75.1         (host cross-build for Android, ~5 min)
2. WebKit/JSC       (cross-compile JSCOnly port, ~60-90 min)  [CACHED]
3. Bun binary       (CMake + Ninja, ~30-45 min)               [CACHED]
4. libopentui.so    (Zig build for aarch64-linux-android, ~2 min)
5. OpenCode bundle  (bun build --compile on host, ~30 sec)
6. Module graph     (extract from host binary, patch, append to Android Bun)
7. Packages         (zip + pacman + deb)
```

The expensive steps (WebKit, Bun) are cached by version/patch hash.

## How the Standalone Binary Works

Since `bun build --compile` has no Android cross-compilation target, we use a manual approach:

1. Use **host Bun** to `bun build --compile` OpenCode for the host platform
2. Extract the serialized **module graph** from the host standalone binary
3. Patch the module graph (fix `undici` global reference, swap x86_64 native libs with ARM64 versions)
4. Append the patched module graph to our **Android Bun** binary
5. Write a new 8-byte `total_byte_count` footer

The standalone binary format (ELF):
```
[Android Bun binary (~96 MB)]
[Module graph bytes (~46 MB)]
[total_byte_count as u64 LE (8 bytes)]
```

## Known Limitations

- **No auto-update**: The `bun upgrade` command is disabled on Android
- **File watching**: `@parcel/watcher` native module is x86_64; degrades gracefully to polling
- **TinyCC**: Not available on Android/aarch64; FFI compilation disabled
- **bun-pty**: Native PTY library works but requires ARM64 `librust_pty.so`

## Tested On

- Samsung Galaxy S10e (Android 12, Termux, aarch64)
- Meta Quest 2 (Android 12L, adb shell)

## Credits

- [OpenCode](https://github.com/anomalyco/opencode) by Anomaly
- [Bun](https://github.com/oven-sh/bun) by Oven
- [WebKit/JavaScriptCore](https://github.com/AAAstorga/WebKit) (oven-sh fork)
- [Termux](https://termux.dev/) -- terminal emulator for Android
- [OpenTUI](https://github.com/anomalyco/opentui) by Anomaly

## License

MIT
