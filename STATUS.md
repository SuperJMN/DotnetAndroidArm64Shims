# STATUS

Snapshot of where the work stands. Update as tasks complete.

## Phase 0 — Discovery (done)

- [x] Confirmed `Microsoft.Android.Sdk.Linux` is x86_64-only on the host side.
- [x] Confirmed there is no `Microsoft.Android.Sdk.Linux-arm64` package on NuGet.
- [x] Confirmed `qemu-user-static` (Debian 5.2 and tonistiigi 9.x) cannot run the .NET SDK reliably on aarch64 — basic `dotnet new console` segfaults.
- [x] Inventoried which binaries in the pack are x86_64-only vs already aarch64 (see `README.md`).
- [x] Filed upstream ask: [dotnet/android#11184](https://github.com/dotnet/android/issues/11184).

## Phase 1 — Easy wins (in progress, awaiting CI run)

Order matters: the two `.so` shims are dependencies of MSBuild tasks that run before aapt2.

- [x] **`libMono.Unix.so` for linux-arm64.** Build script at `shims/libMono.Unix/build.sh`, symbol-parity verifier at `shims/libMono.Unix/verify-symbols.sh`. Pinned reference: 346 exported symbols extracted from upstream `Microsoft.Android.Sdk.Linux/36.1.53`.
- [x] **`libZipSharpNative-3-3.so` for linux-arm64.** Build script at `shims/libZipSharpNative/build.sh` (vendored libzip 1.10.1 built statically, then native wrapper). Soname suffix `-3-3` pinned in `pack-versions/36.1.53.env`.
- [x] CI: GitHub Actions matrix on `ubuntu-22.04-arm` at `.github/workflows/build-shims.yml`.

## Phase 2 — aapt2 (in progress, awaiting CI run)

- [x] Build path **picked: A**, slightly redirected. Termux dropped their aapt2 recipe (Option C is dead). We use [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) — a complete CMake build of AOSP `aapt2` with all deps vendored — invoked **without** the NDK toolchain file so it produces a vanilla glibc `aarch64` ELF on the host runner. See `docs/aapt2.md` for rationale and `shims/aapt2/build.sh` for the script.
- [x] Upstream `aapt2 version` extraction wired into `pack-versions/<v>.env::AAPT2_VERSION_STRING` and into `scripts/extract-reference-symbols.sh`.
- [x] `verify-version.sh` matches the daemon's `aapt2 version` against the pinned string byte-for-byte (CI fails on mismatch → blocks XA0111 in production).
- [x] `verify-daemon.sh` spawns `aapt2 daemon` and confirms it speaks before exiting (catches library-load failures the version string misses).

## Phase 3 — Distribution + integration (in progress)

- [x] GitHub release tarball assembly: `scripts/package-release.sh` produces `dist/shims-linux-arm64-<v>.tar.gz` + `SHA256SUMS` + outer `.sha256`. Release workflow at `.github/workflows/release.yml` triggers on tag push (`X.Y.Z`).
- [x] **Bootstrap script: `scripts/install-shims.sh`** (zero deps beyond `bash`/`curl`/`tar`/`sha256sum`). Auto-detects installed pack versions, downloads matching release, verifies `SHA256SUMS`, backs up originals to `tools/.x86_64-backup/` (and `tools/Linux/.x86_64-backup/` for `aapt2`), idempotent on re-run. CI smoke test in `build-shims.yml` exercises the full overlay against a fake pack tree.
- [ ] Integrate from [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer): when `RuntimeInformation.OSArchitecture == Arm64 && IsLinux`, before `dotnet publish` for an Android project, invoke `install-shims.sh`. (Out of scope of this repo — happens in DotnetDeployer.)

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
