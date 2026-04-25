# DotnetAndroidArm64Shims

Native **linux-arm64** replacements for the host-side binaries that ship inside `Microsoft.Android.Sdk.Linux`, so that `dotnet publish -f net*-android` can run **natively on aarch64 hosts** (Raspberry Pi 4/5, Ampere/Graviton VMs, Apple Silicon Linux VMs, etc.).

> Tracking the upstream ask in [dotnet/android#11184](https://github.com/dotnet/android/issues/11184). If/when Microsoft publishes an official linux-arm64 host pack, this repo becomes obsolete.

## Why this exists

The .NET SDK is published for `linux-arm64` and `dotnet workload install android` happily completes on an arm64 host — but the workload pack (`Microsoft.Android.Sdk.Linux`) ships **only x86_64 ELF binaries** for the build-host tools. Triggering a publish from arm64 fails immediately with:

```
error XA0111: Unsupported version of AAPT2
```

…or the equivalent `cannot execute binary file: Exec format error` once you look closer. The .NET MSBuild tasks then P/Invoke into x86_64 `.so` files and crash.

`qemu-user-static` is **not** a viable workaround. The .NET runtime hits threading / signal-handling bugs under qemu-user (PLINQ ETW provider init failure, `dotnet new console` segfaults). Confirmed empirically with both Debian's qemu 5.2 and `tonistiigi/binfmt`'s qemu 9.x.

## What's in scope

These are the **only** host binaries that need an arm64 build (verified against `Microsoft.Android.Sdk.Linux/36.1.53` and `35.0.105`):

| Binary | Source | Effort | Required for |
|---|---|---|---|
| `tools/Linux/aapt2` | AOSP `frameworks/base/tools/aapt2` | Medium-high | Every APK/AAB build (resource compilation) |
| `tools/libMono.Unix.so` | [mono/Mono.Posix](https://github.com/mono/Mono.Posix) | Low | Most MSBuild Android tasks (P/Invoke) |
| `tools/libZipSharpNative-3-3.so` | [xamarin/LibZipSharp](https://github.com/xamarin/LibZipSharp) | Low | Zip/AAB packaging |
| `tools/Linux/binutils/bin/{as,ld,llc,llvm-mc,llvm-objcopy,llvm-strip}` | Host LLVM ≥ 15 + system binutils (symlinked, not bundled) | Symlinks at install time | AOT and NativeAOT publish paths |

Everything else under the pack is already shipped as aarch64 (`tools/lib/arm64-v8a/*` are *device* payloads, `aarch64-linux-android-*` are cross-compilers that target Android arm64 — those run on the host but the pack already bundles aarch64 ELFs for them).

> **AOT prerequisite (one-time, only if you publish with `RunAOTCompilation=true`):** install `llvm-19 lld-19 binutils` from `apt.llvm.org`. See [`docs/llvm-toolchain.md`](docs/llvm-toolchain.md) for the apt one-liner. `install-shims.sh` will print it and exit non-zero if it can't find LLVM ≥ 15 on the host. Pass `--skip-binutils` to opt out if you only do Mono APK builds.

## What's out of scope

- Targeting Android x86 / x86_64 from an arm64 host. Those Android-side cross-compilers are x86_64 ELFs in the pack; only matters for emulator-targeted debug builds.
- Windows / macOS host arm64. Out of scope, different pack (`Microsoft.Android.Sdk.Windows`, `…Darwin`).
- Bundling LLVM/binutils inside the shim tarball (host-installed via apt is the chosen v1 strategy — see `docs/llvm-toolchain.md` "Why host-installed and not bundled").

## Strategy

1. Build the shim binaries for `linux-arm64` in CI on every relevant `Microsoft.Android.Sdk.Linux` upstream release.
2. Publish them as **GitHub releases**, one tag per *binary fingerprint* (not per pack version — see [coverage model](#coverage-model-one-release-many-pack-versions) below).
3. Provide a small bootstrap script + documented CLI to overlay them onto an installed pack:
   ```
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libMono.Unix.so
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libZipSharpNative-3-3.so
   ```
4. Downstream consumers (e.g. [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer)) call the bootstrap before invoking `dotnet publish`.

## Coverage model: one release, many pack versions

Microsoft re-publishes the workload pack often, but the *host binaries* inside it almost never change. Across every `Microsoft.Android.Sdk.Linux` version we sha256-fingerprinted (15 versions in the 35.0.x and 36.1.x series, including 36.99 previews), only **two distinct host-binary fingerprints** exist:

| Series | aapt2 sha256 | aapt2 version | libMono.Unix.so | libZipSharpNative |
|---|---|---|---|---|
| All 35.0.x | `d1096e…` | 2.19-11948202 | `ce99f5…` | `cb52cc…` |
| All 36.x (incl. previews) | `1a6a39…` | 2.20-13193326 | `ce99f5…` | `cb52cc…` |

Both `.so` files are **byte-identical for every version checked** — `aapt2` changed exactly once between the 35.x and 36.x series.

So we maintain a [`compatibility.json`](compatibility.json) manifest at the repo root: a sha256-anchored map from pack version → shim release tag whose tarball ships byte-identical replacements. [`scripts/install-shims.sh`](scripts/install-shims.sh) tries the literal pack-version tag first; on a miss it consults the manifest. A single `35.0.105` release covers the entire 35.0.x series; a single `36.1.53` release covers the entire 36.x series (so far).

A weekly [NuGet watcher workflow](.github/workflows/watch-nuget.yml) keeps the manifest current automatically — see the [Maintenance runbook](docs/maintenance.md).

## Test platform

A Raspberry Pi 4 (4 GB, Raspberry Pi OS 64-bit, kernel 6.x, .NET SDK 10.0.202) hosting a [DotnetFleet](https://github.com/SuperJMN/DotnetFleet) worker. Real-world canary project: [Pokémon-Battle-Engine](https://github.com/SuperJMN/Pokemon) — Avalonia app with a `net10.0-android` head producing arm64-v8a APK + AAB.

If the shimmed pack can produce a signed, installable APK from this canary on the Pi, we ship.

## Maintenance burden

`aapt2` enforces a strict version match against the pack (`error XA0111: Unsupported version of AAPT2`). The good news: empirically Microsoft only bumps the `aapt2` version string when AOSP cuts a new build-tools snapshot — roughly once a year — and ships dozens of pack versions in between with the same host binaries. The [coverage model above](#coverage-model-one-release-many-pack-versions) means most new pack releases are picked up automatically by the watcher with **zero rebuilds**.

When a real binary bump *does* happen, the watcher opens an actionable issue with the new sha256s and a one-click `release.yml` dispatch link. End-to-end procedure: see the [Maintenance runbook](docs/maintenance.md).

If/when [dotnet/android#11184](https://github.com/dotnet/android/issues/11184) is resolved, archive this repo.

## Component docs

- [`docs/aapt2.md`](docs/aapt2.md)
- [`docs/libMono.Unix.md`](docs/libMono.Unix.md)
- [`docs/libZipSharpNative.md`](docs/libZipSharpNative.md)
- [`docs/llvm-toolchain.md`](docs/llvm-toolchain.md) (deferred)
- [`docs/maintenance.md`](docs/maintenance.md) — runbook for new pack versions, drift, and binary bumps
- [`STATUS.md`](STATUS.md) — roadmap and current state

## License

Each vendored component keeps its upstream license (Apache 2.0 for AOSP/aapt2, MIT/Apache 2.0 for the Mono/Xamarin pieces). Build scripts and integration glue in this repo: MIT.
