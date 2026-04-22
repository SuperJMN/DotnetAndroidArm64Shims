# aapt2 (Android Asset Packaging Tool 2)

The big one. Compiles XML resources and packages them into the resource table of an APK / AAB. Invoked by every Android build.

## Source

Upstream lives in AOSP: [`frameworks/base/tools/aapt2`](https://cs.android.com/android/platform/superproject/+/master:frameworks/base/tools/aapt2/). The binary that ships in `Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2` is a vanilla AOSP build, the same one Google distributes via `sdkmanager "build-tools;<version>"`.

## Why we can't just `apt install`

There is no Debian / Raspberry Pi OS package for `aapt2`. The Android SDK side-loads its own. Termux ships an arm64 build but it's linked against Termux's libc paths (`/data/data/com.termux/files/usr/...`), so it won't run on a vanilla Debian install without unpacking and tweaking.

## Build options (and what we picked)

### Status (as of attempt 2): **blocked** — pivoting

CI run #1 proved that the strategy below ("just don't pass the NDK toolchain") doesn't survive contact with reality. lzhiyong's root `CMakeLists.txt` unconditionally `add_subdirectory(lib)` / `(platform-tools)` / `(others)`, and `lib/CMakeLists.txt` `include()`s `libcutils.cmake`, `libselinux.cmake`, `libsepol.cmake`, `libandroidfw.cmake`, `libincfs.cmake`, `libprocessgroup.cmake`, `libopenscreen.cmake`, etc. Most of these are bionic-only (Android libc + Android-specific kernel headers); they don't configure on glibc.

Even narrowing the build to just the `aapt2` target via `ninja aapt2` doesn't help — CMake's *configure* step parses every `add_subdirectory()` regardless of which target we later build, so the bionic `.cmake` recipes blow up before we get to compile a single file.

`build-tools/aapt2.cmake` confirms the dep chain: `aapt2` links `libandroidfw libincfs libselinux libsepol libpackagelistparser libutils libcutils libziparchive libbase libbuildversion liblog protobuf::libprotoc protobuf::libprotobuf expat crypto ssl pcre2-8 png_static c++_static dl`. That's effectively half of AOSP `system/core` + `frameworks/base/libs/androidfw`. Patching it down to glibc-friendly subset is a real porting effort, not a build-script fix.

**v1 ships without aapt2.** The two `.so` shims unblock most of the .NET Android MSBuild graph; `aapt2` becomes a separate workstream tracked here. Users who have a working `aapt2` from another source (e.g. an Android-on-Linux distro) can drop it in `~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<v>/tools/Linux/aapt2` themselves.

### A. ~~Standalone CMake fork (lzhiyong)~~ — **abandoned**

[lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) maintains a CMake build of `aapt2` (plus `aapt`, `aidl`, `zipalign`, `dexdump`) assembled from AOSP source with all dependencies vendored as git submodules. We initially picked this thinking the recipe was toolchain-agnostic. It isn't — the included `.cmake` files target the Android NDK / bionic libc and don't configure on glibc (see "Status" above).

### B. AOSP source-of-truth (next to try)

`repo init && repo sync` against `platform/frameworks/base` plus the minimum dependency set, then build `aapt2` under Soong. Tens of GB of checkout. Soong on arm64 is reportedly unhappy. This is now the most-likely path forward despite the heaviness.

### C. ~~Termux recipe~~ — **abandoned**

Originally we planned to fork Termux's `packages/aapt2/build.sh`. Termux **no longer ships an aapt2 recipe** — only `aapt`. So this option is dead.

### D. ~~Pull from a community arm64 build~~ — **doesn't exist**

There is no public glibc linux-arm64 prebuilt of `aapt2` as of 2025 (Google maven publishes x86_64 / x86 / windows / osx only; tracked at [issuetracker.google.com/issues/227219818](https://issuetracker.google.com/issues/227219818)). We have to build it.

### E. Patch lzhiyong heavily (maybe)

In principle one could `sed` the bionic `add_subdirectory(...)` lines out of lzhiyong's root CMakeLists, then port each of `libcutils` / `libselinux` / `libsepol` / `libandroidfw` / `libincfs` / `libpackagelistparser` to build against glibc. That's a multi-week porting job and gets us a binary that's likely to drift from upstream's `aapt2 version` string anyway. Not pursuing.

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
