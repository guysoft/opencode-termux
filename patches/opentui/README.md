# opentui patches

Patches applied to [anomalyco/opentui](https://github.com/anomalyco/opentui)
before cross-compiling `libopentui.so` for `aarch64-linux-android`.

Applied by `scripts/build-opentui-v2.sh`.

## `v2-0.5.10-android.patch`

Build/packaging changes needed to compile the native renderer with the Android
NDK and Zig: `build.zig` target wiring, a clipboard host shim, and an Android
`translate-c` shim.

## `negative-cell-coord-intcast.patch`

**Fixes a hard crash (SIGABRT) in the TUI on Android.**

### Symptom

Opening a session that has enough content to render aborts the process:

```
thread N panic: integer does not fit in destination type
packages/native/src/buffer.zig:925
  in setVisibleCellWithAlphaBlending
```

Bun then reports a backtrace full of `???` frames and exits 134. A fresh, empty
session renders fine; the crash needs transcript content, and it gets *more*
likely as the session grows. No JS stack is involved — it is a panic raised by
the native renderer and is not catchable from JavaScript.

### Cause

`setVisibleCellWithAlphaBlending` receives coordinates as `u32` and narrows them
to the `i32` that `isPointInScissor` expects:

```zig
inline fn setVisibleCellWithAlphaBlending(self: *OptimizedBuffer, x: u32, y: u32, ...) void {
    if (!self.isPointInScissor(@intCast(x), @intCast(y))) return;   // line 925
```

`u32` values above `i32` max (2147483647) have no `i32` representation, so
`@intCast` is undefined behaviour for them. `scripts/build-opentui-v2.sh` builds
with `-Doptimize=ReleaseSafe`, which keeps Zig's safety checks, so the invalid
cast is caught and turned into `abort()` — the whole CLI dies.

A coordinate of that magnitude is never a real screen position. It is an
off-buffer value that has wrapped, typically from signed arithmetic in the
layout/compositing code being narrowed back to `u32` (see the
`destX + placement.x - srcX` style computations elsewhere in `buffer.zig`).

The emitted code makes the mechanism explicit: each check is a single
`tbnz wN, #0x1f` — a test of bit 31, which is exactly the condition
"value >= 2^31" that makes the narrowing illegal.

Note the sibling function `validateAndIndex` already gets this right: its
`if (x >= self.width or y >= self.height) return null;` runs *before* the
`@intCast`, so the narrowing is always in range by the time it happens.
`setVisibleCellWithAlphaBlending` was simply missing that guard.

### Fix

Add the same bounds check ahead of the narrowing, so an off-buffer coordinate is
clipped (a no-op for that cell) instead of aborting the process:

```zig
if (x >= self.width or y >= self.height) return;
if (!self.isPointInScissor(@intCast(x), @intCast(y))) return;
```

`width`/`height` are `u32` and always far below `i32` max, so any `x`/`y` that
survives the guard is guaranteed to fit the `i32` cast.

This is a correctness fix, not a workaround: it makes the function obey the
invariant it already assumed. There is no reason to reject a cell that lies
outside the buffer, since it has nothing to draw on.

### Verification

Built with the patch, `opencode -c` at 24x60, 40x110 and 200x50 columns all run
indefinitely instead of aborting within seconds, and the backtrace disappears.
Rebuild and confirm the panic is gone:

```sh
scripts/build-opentui-v2.sh
scripts/build-opencode2-android.sh
scripts/make-packages-v2.sh
```
