# Alternative install: upstream musl build

If you don't want to wait for a fresh cross-compiled release here, there's a
parallel project that uses the **upstream** `opencode-linux-arm64-musl.tar.gz`
directly — no proot, no Bun cross-compile, no WebKit, no ICU. Just musl libc +
libstdc++/libgcc_s from Alpine plus a tiny libtagfix.so shim.

→ https://github.com/DEAD1nsane/opencode-termux-musl

```
curl -fsSL https://raw.githubusercontent.com/DEAD1nsane/opencode-termux-musl/main/install.sh | sh
```

Trade-offs vs this repo:

| | guysoft/opencode-termux | DEAD1nsane/opencode-termux-musl |
|---|---|---|
| opencode version | pinned to 1.17.9 | tracks upstream (1.18.29+) |
| Build complexity | 6-stage CI (~4 min warm) | one curl, no compile |
| Bun patches | 33 files (custom cross-compile) | none — uses upstream's binary |
| PTY support | yes (`librust_pty_arm64.so`) | no |
| libtagfix.so | yes | yes (same fix) |
| Tested on | Galaxy S10e, Quest 2 | Pixel 8 |

Both approaches use the same libtagfix trick to disable Android's TBI heap
tagging. The musl build's `libtagfix.so` is built on-device by the installer
from a ~20-line C file that calls `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL,
M_HEAP_TAGGING_LEVEL_NONE)`.
