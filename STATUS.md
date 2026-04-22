# STATUS

Snapshot of where the work stands. Update as tasks complete.

## Phase 0 — Discovery (done)

- [x] Confirmed `Microsoft.Android.Sdk.Linux` is x86_64-only on the host side.
- [x] Confirmed there is no `Microsoft.Android.Sdk.Linux-arm64` package on NuGet.
- [x] Confirmed `qemu-user-static` (Debian 5.2 and tonistiigi 9.x) cannot run the .NET SDK reliably on aarch64 — basic `dotnet new console` segfaults.
- [x] Inventoried which binaries in the pack are x86_64-only vs already aarch64 (see `README.md`).
- [x] Filed upstream ask: [dotnet/android#11184](https://github.com/dotnet/android/issues/11184).

## Phase 1 — Easy wins (TODO)

Order matters: the two `.so` shims are dependencies of MSBuild tasks that run before aapt2.

- [ ] **`libMono.Unix.so` for linux-arm64.** Source: [mono/Mono.Posix](https://github.com/mono/Mono.Posix). Standard autotools build. Verify ABI compatibility with the .so currently in `tools/libMono.Unix.so` of pack `36.1.53` (`nm -D` to compare exported symbols).
- [ ] **`libZipSharpNative-3-3.so` for linux-arm64.** Source: [xamarin/LibZipSharp](https://github.com/xamarin/LibZipSharp). Pin to the same `libzip` version Microsoft uses (check the `.so` strings to extract upstream commit / version).
- [ ] CI: GitHub Actions matrix entry building these on `ubuntu-22.04-arm` (free arm64 runners now available for public repos as of 2025).

## Phase 2 — aapt2 (TODO, the hard one)

- [ ] Decide build path. Options:
  - **A. Standalone CMake fork** maintained externally (e.g. [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools)). Pros: small, fast. Cons: lags AOSP; we'd inherit lag and risk version-mismatch errors against newer packs.
  - **B. Build from AOSP** with `lunch sdk-eng && m aapt2`. Pros: matches whatever Android Studio ships. Cons: needs ~300 GB AOSP checkout, repo tooling, and Soong build system on arm64.
  - **C. Extract Termux's build recipe** and adapt away from Termux paths. Termux ships aapt2 for arm64 in `termux-packages/packages/aapt2/`.
- [ ] Establish a procedure to find the **exact upstream commit** Microsoft used for the `aapt2` in a given pack version (it embeds a version string — `aapt2 version` prints it).
- [ ] Cross-check that the rebuilt aapt2 reports the same `Daemon Mode` protocol version as the upstream one (the .NET MSBuild task speaks to it via stdin/stdout).
- [ ] Define error mode if version check fails (`XA0111`): clear message pointing back here.

## Phase 3 — Distribution + integration (TODO)

- [ ] GitHub release per upstream pack version. Naming: tag = upstream version, e.g. `36.1.53`. Asset layout:
  ```
  shims-linux-arm64-36.1.53.tar.gz
    aapt2
    libMono.Unix.so
    libZipSharpNative-3-3.so
    SHA256SUMS
  ```
- [ ] Bootstrap CLI (e.g. `install-shims.sh` or a small dotnet tool) that:
  1. Detects current host (must be linux-arm64).
  2. Lists installed `Microsoft.Android.Sdk.Linux` versions under `~/.dotnet/packs/`.
  3. For each, downloads the matching shim release and overlays it (backing up originals to `tools/.x86_64-backup/`).
  4. Idempotent and safe to re-run.
- [ ] Integrate from [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer): when `RuntimeInformation.OSArchitecture == Arm64 && IsLinux`, before `dotnet publish` for an Android project, invoke the bootstrap.

## Phase 4 — Validation on rpi4 (TODO)

- [ ] Run shim install on the rpi4 worker.
- [ ] Trigger DotnetDeployer for the [Pokémon-Battle-Engine](https://github.com/SuperJMN/Pokemon) repo from the Fleet UI.
- [ ] Verify the produced APK installs and launches on a physical Android device.
- [ ] Time the build (rough budget: native arm64 publish should be 2–5× slower than amd64 due to Pi 4 CPU, but no qemu overhead).

## Phase 5 — Maintenance loop (TODO, ongoing)

- [ ] CI watcher: poll [the NuGet feed](https://www.nuget.org/packages/Microsoft.Android.Sdk.Linux) for new versions, open an issue here when a new one appears.
- [ ] Document the bump procedure end-to-end so it's a 30-minute task, not a half-day archaeology session.

## Out of scope (for now)

- AOT / NativeAOT scenarios → would require porting `llc`, `llvm-mc`, `llvm-objcopy`, `llvm-strip`, `lld*` to arm64. Doable (LLVM upstream supports linux-aarch64) but materially more work and few users hit it. Re-evaluate after Phase 4.
- Targeting Android x86 / x86_64 from arm64 hosts (only relevant for emulator debug).

## Done-ness criteria

We declare v1 done when, on the rpi4, this works end-to-end with no manual intervention:

```
git clone https://github.com/SuperJMN/Pokemon
cd Pokemon
dotnet publish src/PokemonBattleEngine.Gui.Android -c Release -f net10.0-android
# → produces a signed APK in bin/Release/net10.0-android/
```

…and the same flow runs through DotnetDeployer when the Fleet worker picks up the job.
