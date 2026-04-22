# aapt2 (Android Asset Packaging Tool 2)

The big one. Compiles XML resources and packages them into the resource table of an APK / AAB. Invoked by every Android build.

## Source

Upstream lives in AOSP: [`frameworks/base/tools/aapt2`](https://cs.android.com/android/platform/superproject/+/master:frameworks/base/tools/aapt2/). The binary that ships in `Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2` is a vanilla AOSP build, the same one Google distributes via `sdkmanager "build-tools;<version>"`.

## Why we can't just `apt install`

There is no Debian / Raspberry Pi OS package for `aapt2`. The Android SDK side-loads its own. Termux ships an arm64 build but it's linked against Termux's libc paths (`/data/data/com.termux/files/usr/...`), so it won't run on a vanilla Debian install without unpacking and tweaking.

## Build options (and what we picked)

### A. Standalone CMake fork — **picked**

[lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) maintains a complete CMake-based build of `aapt2` (plus `aapt`, `aidl`, `zipalign`, `dexdump`, etc.) assembled from AOSP source with all dependencies vendored as git submodules. Their `build.py` driver targets the **Android NDK** (so the binaries normally end up bionic/Android), but the `CMakeLists.txt` files themselves are toolchain-agnostic — invoking CMake with the host `gcc`/`clang` produces a vanilla glibc executable.

Our `shims/aapt2/build.sh` does exactly that: clones lzhiyong's repo + submodules, runs `get_source.py` to apply their patches, then invokes `cmake` with **no** `-DCMAKE_TOOLCHAIN_FILE=...android.toolchain.cmake` and **no** `-DANDROID_*` flags. The build produces a stripped `aapt2` ELF for whatever architecture the host CMake is running on — `aarch64` on the `ubuntu-22.04-arm` runner.

**Pros**: small, self-contained, builds in ~30 min on a Pi 4. CMake recipe is already debugged. No NDK install needed.
**Cons**: lzhiyong's tip lags AOSP by months. We pin a commit that produces an `aapt2 version` string matching whatever pack we're shimming for; if no commit matches we fall back to B.

### B. AOSP source-of-truth (fallback)

`repo init && repo sync` against `platform/frameworks/base` plus the minimum dependency set, then `mma aapt2` under Soong. Tens of GB of checkout and Soong on arm64 is unhappy. Reserved for the case where lzhiyong has no commit matching the upstream `aapt2` version we need.

### C. ~~Termux recipe~~ — **abandoned**

Originally we planned to fork Termux's `packages/aapt2/build.sh`. Termux **no longer ships an aapt2 recipe** — only `aapt`. So this option is dead.

### D. ~~Pull from a community arm64 build~~ — **doesn't exist**

There is no public glibc linux-arm64 prebuilt of `aapt2` as of 2025 (Google maven publishes x86_64 / x86 / windows / osx only; tracked at [issuetracker.google.com/issues/227219818](https://issuetracker.google.com/issues/227219818)). We have to build it.

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
