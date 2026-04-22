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
| `tools/Linux/binutils/bin/{as,ld,llc,llvm-mc,llvm-objcopy,llvm-strip}` and `lib*.so.*` | dotnet/android prebuilt LLVM | Optional / deferred | **Only** AOT and NativeAOT scenarios |

Everything else under the pack is already shipped as aarch64 (`tools/lib/arm64-v8a/*` are *device* payloads, `aarch64-linux-android-*` are cross-compilers that target Android arm64 — those run on the host but the pack already bundles aarch64 ELFs for them).

## What's out of scope

- AOT / NativeAOT publishing on arm64 hosts. The native LLVM toolchain (`llc`, `llvm-mc`, `lld*`) would also need arm64 builds. Mono APK targets (the default for most apps) **do not require** these, so we skip them in v1.
- Targeting Android x86 / x86_64 from an arm64 host. Those Android-side cross-compilers are x86_64 ELFs in the pack; only matters for emulator-targeted debug builds.
- Windows / macOS host arm64. Out of scope, different pack (`Microsoft.Android.Sdk.Windows`, `…Darwin`).

## Strategy

1. Build the shim binaries for `linux-arm64` in CI on every relevant `Microsoft.Android.Sdk.Linux` upstream release.
2. Publish them as **GitHub releases**, one tag per upstream pack version (e.g. `36.1.53`, `35.0.105`).
3. Provide a small bootstrap script + documented CLI to overlay them onto an installed pack:
   ```
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/Linux/aapt2
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libMono.Unix.so
   ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libZipSharpNative-3-3.so
   ```
4. Downstream consumers (e.g. [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer)) call the bootstrap before invoking `dotnet publish`.

## Test platform

A Raspberry Pi 4 (4 GB, Raspberry Pi OS 64-bit, kernel 6.x, .NET SDK 10.0.202) hosting a [DotnetFleet](https://github.com/SuperJMN/DotnetFleet) worker. Real-world canary project: [Pokémon-Battle-Engine](https://github.com/SuperJMN/Pokemon) — Avalonia app with a `net10.0-android` head producing arm64-v8a APK + AAB.

If the shimmed pack can produce a signed, installable APK from this canary on the Pi, we ship.

## Maintenance burden (be honest)

`aapt2` enforces a strict version match against the pack (`error XA0111: Unsupported version of AAPT2`). Microsoft ships a new pack roughly every month, sometimes more. **Each upstream version requires rebuilding and tagging a matching shim release.** This is the price of admission until upstream provides arm64 hosts.

If/when [dotnet/android#11184](https://github.com/dotnet/android/issues/11184) is resolved, archive this repo.

## Component docs

- [`docs/aapt2.md`](docs/aapt2.md)
- [`docs/libMono.Unix.md`](docs/libMono.Unix.md)
- [`docs/libZipSharpNative.md`](docs/libZipSharpNative.md)
- [`docs/llvm-toolchain.md`](docs/llvm-toolchain.md) (deferred)
- [`STATUS.md`](STATUS.md) — roadmap and current state

## License

Each vendored component keeps its upstream license (Apache 2.0 for AOSP/aapt2, MIT/Apache 2.0 for the Mono/Xamarin pieces). Build scripts and integration glue in this repo: MIT.
