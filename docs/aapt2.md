# aapt2 (Android Asset Packaging Tool 2)

The big one. Compiles XML resources and packages them into the resource table of an APK / AAB. Invoked by every Android build.

## Source

Upstream lives in AOSP: [`frameworks/base/tools/aapt2`](https://cs.android.com/android/platform/superproject/+/master:frameworks/base/tools/aapt2/). The binary that ships in `Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2` is a vanilla AOSP build, the same one Google distributes via `sdkmanager "build-tools;<version>"`.

## Why we can't just `apt install`

There is no Debian / Raspberry Pi OS package for `aapt2`. The Android SDK side-loads its own. Termux ships an arm64 build but it's linked against Termux's libc paths (`/data/data/com.termux/files/usr/...`), so it won't run on a vanilla Debian install without unpacking and tweaking.

## Build options (and what we picked)

### Status: **active — Option F (ReVanced static-bionic via NDK)**

After options A–E hit dead ends (see below), validation on the Pi (`jmn@rpi4`, Pi OS bullseye) showed that **statically-linked arm64-v8a bionic binaries run transparently on Linux arm64 + glibc**. The arm64 syscall ABI is identical between mainline Linux and Android kernels; bionic libc is fully self-contained inside the static binary. Empirically, ReVanced's published `aapt2-arm64-v8a` from `v1.1.0` runs on Pi OS bullseye and reports `Android Asset Packaging Tool (aapt) 2.19-` (correct, just an older version + missing build-id).

We therefore build aapt2 by **cross-compiling from the ReVanced/aapt2 fork using the Android NDK r27c**, then **sed-patching two source files** before build to force the `aapt2 version` output to byte-match `pack-versions/<v>.env::AAPT2_VERSION_STRING` — required because XA0111 has no override.

Key points:

- **Host = linux-x86_64** (Google publishes the NDK x86_64-only). The .so jobs continue running on `ubuntu-22.04-arm`; aapt2 has its own `ubuntu-22.04` job in `.github/workflows/build-shims.yml` and `release.yml`.
- **Output is arm64-v8a static-bionic ELF**, fully runnable on any aarch64 Linux. Verified with `qemu-user-static` in CI and natively on Pi.
- **Version stamping** is two `sed` operations:
  - `submodules/base/tools/aapt2/util/Util.cpp::sMinorVersion` → `"20"` (or whatever pack expects)
  - `submodules/soong/cc/libbuildversion/libbuildversion.cpp::PLACEHOLDER` macro → the AOSP build id (e.g. `"13193326"`). This char buffer is normally patched at link time by Soong; ReVanced's CMake doesn't run that patcher, hence the empty build-id in their stock binary.
- **No bionic .so dependencies leak** because the NDK toolchain links bionic statically into the binary.

See `shims/aapt2/build.sh` for the full recipe. The script is idempotent — it skips already-cloned source, already-applied patches, and already-downloaded NDK/protoc.

### A. ~~Standalone CMake fork (lzhiyong)~~ — **abandoned**

[lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) maintains a CMake build of `aapt2` (plus `aapt`, `aidl`, `zipalign`, `dexdump`) assembled from AOSP source with all dependencies vendored as git submodules. We initially picked this thinking the recipe was toolchain-agnostic. It isn't — the included `.cmake` files target the Android NDK / bionic libc and don't configure on glibc. Killed in CI run #1 (see lzhiyong's root `CMakeLists.txt` `add_subdirectory(lib)` etc., which include bionic-only `libcutils.cmake`, `libselinux.cmake`, `libsepol.cmake`, `libandroidfw.cmake`, `libincfs.cmake`, `libprocessgroup.cmake`, `libopenscreen.cmake`).

### B. ~~AOSP source-of-truth (Soong + repo)~~ — **superseded by F**

`repo init && repo sync` against `platform/frameworks/base` plus the minimum dependency set, then build `aapt2` under Soong. Tens of GB of checkout. Soong on arm64 is reportedly unhappy. Option F gives us the same binary characteristics for a fraction of the build cost, since ReVanced has already done the heavy lifting of wiring AOSP submodules under CMake.

### C. ~~Termux recipe~~ — **abandoned**

Originally we planned to fork Termux's `packages/aapt2/build.sh`. Termux **no longer ships an aapt2 recipe** — only `aapt`. So this option is dead.

### D. ~~Pull from a community arm64 build~~ — **partially exists**

There is no public **glibc** linux-arm64 prebuilt of `aapt2` as of 2025 (Google maven publishes x86_64 / x86 / windows / osx only; tracked at [issuetracker.google.com/issues/227219818](https://issuetracker.google.com/issues/227219818)). However, ReVanced/aapt2 publishes a **static-bionic arm64-v8a** binary that, as discovered during option-F prototyping, *does* run on Linux arm64 — that's the foundation we built F on top of.

### E. ~~Patch lzhiyong heavily~~ — **abandoned**

In principle one could `sed` the bionic `add_subdirectory(...)` lines out of lzhiyong's root CMakeLists, then port each of `libcutils` / `libselinux` / `libsepol` / `libandroidfw` / `libincfs` / `libpackagelistparser` to build against glibc. That's a multi-week porting job and gets us a binary that's likely to drift from upstream's `aapt2 version` string anyway. Not pursuing.

### F. **ReVanced static-bionic via NDK** — **active (see Status above)**

## Verification checklist before publishing a build

1. `aapt2 version` reports the same string as the x86_64 binary in the matching pack version (enforced by `shims/aapt2/verify-version.sh`).
2. Daemon mode handshakes correctly: spawn `aapt2 daemon` and round-trip a small `compile` request through stdin/stdout (`shims/aapt2/verify-daemon.sh`).
3. End-to-end: build the Pokémon canary with the shim and confirm the produced `.apk` installs on a real device (Phase 4).

## Why version exactness matters

The .NET Android targets verify `aapt2 version` against an expected value baked into the pack. Mismatch → `error XA0111: Unsupported version of AAPT2 (X.Y.Z) found at /path. Expected version is A.B.C`. There is no override flag; the only way through is to ship the right version.

## Open caveat

ReVanced's submodules currently track `platform-tools 35.0.2` (aapt2 source 2.19), and we force the version string to `2.20-13193326` to match pack `36.1.53`'s expected value. Differences between aapt2 2.19 and 2.20 source are minimal for vanilla `dotnet new android` builds, but worth re-validating when bumping pack versions.
