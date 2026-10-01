# musl — upstream musl binary for Termux

Alternative installer that reuses opencode's official musl-linked ARM64 binary instead of cross-compiling Bun for Android.

## Why

The main build cross-compiles Bun v1.2.13 + WebKit/JSC (~6-stage CI pipeline) and ships `libtagfix.so` to work around bionic's heap-pointer tagging. On Android 16, the pointer-tag crash returns because the shim only covers `malloc`/`free` — kernel-level tagged-address enforcement on other syscalls still triggers the abort.

musl's allocator does not tag heap pointers, so the crash never happens. The tradeoff is that we need:
- `libresolvefix.so` (redirect musl's DNS to bionic's resolver)
- HTTP proxy (Bun's io_uring networking is broken on Android)

## Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/guysoft/opencode-termux/main/musl/install.sh | sh
```

Or after cloning:

```sh
./musl/install.sh
```

## What it does

1. Downloads the latest upstream `opencode-linux-arm64-musl.tar.gz`
2. Downloads Alpine's `ld-musl-aarch64.so.1` + musl-compiled `libstdc++`/`libgcc_s`
3. Installs them to `$PREFIX/lib`
4. Uses `patchelf` to retarget the binary's interpreter to the musl loader
5. Builds and installs `libresolvefix.so` (DNS resolution shim)
6. Installs a local HTTP proxy (`proxy.py`) for Bun's broken io_uring networking
7. Installs a wrapper that sets up the environment and runs the binary

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Installer script |
| `libresolvefix.c` | LD_PRELOAD shim: redirects musl's `/etc/resolv.conf` to Termux's copy, forwards `getaddrinfo()` to bionic |
| `proxy.py` | HTTP proxy for Bun's broken io_uring networking on Android |

## Requirements

- Termux (Android 7.0+ / API 24+, aarch64)
- `curl`, `tar`, `patchelf`, `clang` (installer installs missing deps automatically)
- `python3` (for the HTTP proxy)
