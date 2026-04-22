# aapt2 (Android Asset Packaging Tool 2)

The big one. Compiles XML resources and packages them into the resource table of an APK / AAB. Invoked by every Android build.

## Source

Upstream lives in AOSP: [`frameworks/base/tools/aapt2`](https://cs.android.com/android/platform/superproject/+/master:frameworks/base/tools/aapt2/). The binary that ships in `Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2` is a vanilla AOSP build, the same one Google distributes via `sdkmanager "build-tools;<version>"`.

## Why we can't just `apt install`

There is no Debian / Raspberry Pi OS package for `aapt2`. The Android SDK side-loads its own. Termux ships an arm64 build but it's linked against Termux's libc paths (`/data/data/com.termux/files/usr/...`), so it won't run on a vanilla Debian install without unpacking and tweaking.

## Build options (pick one in Phase 2)

### A. Standalone CMake fork

Several community forks build `aapt2` with a regular CMake script, untangling it from Soong (AOSP's build system):

- [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) — builds aapt2 + apksigner + d8/r8 for arm64 Linux. Last bumped commit lags AOSP by months.
- A few smaller forks on GitHub of the same lineage.

**Pros**: small repo, fast build (~15 min on the rpi4).  
**Cons**: lags AOSP. Microsoft bumps `aapt2` with each pack release; the .NET task hard-fails on version mismatch (`error XA0111: Unsupported version of AAPT2`). We'd be in a constant catch-up game with the fork upstream.

### B. AOSP source-of-truth

Use `repo init && repo sync` against `platform/frameworks/base` plus the minimum set of dependencies, then `mma aapt2`.

**Pros**: matches whatever Google ships.  
**Cons**: AOSP checkout is enormous. Even the trimmed manifest (`platform/build`, `platform/frameworks/base`, `platform/system/core`, libpng, expat, protobuf, etc.) runs into the tens of GB and needs Soong, which doesn't run great on arm64.

### C. Termux recipe, de-Termux-ified

Termux's [`packages/aapt2/build.sh`](https://github.com/termux/termux-packages/blob/master/packages/aapt2/build.sh) plus [`patches/`](https://github.com/termux/termux-packages/tree/master/packages/aapt2) is a curated set of patches that make AOSP's `aapt2` build standalone with CMake. We could fork it, strip the Termux-specific libc paths, and produce a "vanilla glibc / arm64" build.

**Pros**: leverages real maintenance work (Termux tracks each new aapt2 release within days). Smallest delta to keep current.  
**Cons**: we'd still need to track Termux's bumps and re-run our de-Termux pass for each version.

**Tentative pick: C**, with B as the fallback if Termux's lag becomes a problem.

## Verification checklist before publishing a build

1. `aapt2 version` reports the same string as the x86_64 binary in the matching pack version.
2. Daemon mode handshakes correctly: spawn `aapt2 daemon` and round-trip a small `compile` request through stdin/stdout (the .NET MSBuild task speaks this protocol).
3. End-to-end: build the Pokémon canary with the shim and confirm the produced `.apk` installs on a real device.

## Why version exactness matters

The .NET Android targets verify `aapt2 version` against an expected value baked into the pack. Mismatch → `error XA0111: Unsupported version of AAPT2 (X.Y.Z) found at /path. Expected version is A.B.C`. There is no override flag; the only way through is to ship the right version.

## Dependencies (typical for AOSP-style aapt2 build)

- libpng
- protobuf (libprotobuf-lite)
- expat
- zlib
- C++17 compiler (gcc 11+ or clang 14+, both fine on Pi OS bookworm)

All available via `apt install` on Debian / Raspberry Pi OS.

## Rough size budget

The x86_64 binary in pack `36.1.53` is around 14 MB stripped. Expect similar for arm64.
