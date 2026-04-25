# STATUS

Snapshot of where the work stands. Update as tasks complete.

## Phase 0 — Discovery (done)

- [x] Confirmed `Microsoft.Android.Sdk.Linux` is x86_64-only on the host side.
- [x] Confirmed there is no `Microsoft.Android.Sdk.Linux-arm64` package on NuGet.
- [x] Confirmed `qemu-user-static` (Debian 5.2 and tonistiigi 9.x) cannot run the .NET SDK reliably on aarch64 — basic `dotnet new console` segfaults.
- [x] Inventoried which binaries in the pack are x86_64-only vs already aarch64 (see `README.md`).
- [x] Filed upstream ask: [dotnet/android#11184](https://github.com/dotnet/android/issues/11184).

## Phase 1 — Easy wins (done) ✅

Released as [`36.1.53`](https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases/tag/36.1.53) — partial v1 (no aapt2 yet).


Order matters: the two `.so` shims are dependencies of MSBuild tasks that run before aapt2.

- [x] **`libMono.Unix.so` for linux-arm64.** Build script at `shims/libMono.Unix/build.sh` invokes upstream `mono/mono.posix`'s CMake at `src/native/` with `-DTARGET_PLATFORM=host-linux-x64` (which on an arm64 host yields a native arm64 build per `cmake/toolchain.linux.cmake`). Symbol-parity verifier at `shims/libMono.Unix/verify-symbols.sh`. Pinned reference: 346 exported symbols extracted from upstream `Microsoft.Android.Sdk.Linux/36.1.53`.
- [x] **`libZipSharpNative-3-3.so` for linux-arm64.** Build script at `shims/libZipSharpNative/build.sh` delegates to upstream `dotnet/android-libzipsharp`'s own `build.sh` (two-phase CMake: `-DBUILD_DEPENDENCIES=ON` then `-DBUILD_LIBZIP=ON`). Soname suffix `-3-3` pinned in `pack-versions/36.1.53.env`.
- [x] CI: GitHub Actions matrix on `ubuntu-22.04-arm` at `.github/workflows/build-shims.yml`.

## Phase 2 — aapt2 (done) ✅

**Strategy: Option F — ReVanced/aapt2 cross-compiled via Android NDK r27c, version-stamped via sed.** Produces a static-bionic arm64-v8a binary that runs natively on Linux arm64. See [`docs/aapt2.md`](docs/aapt2.md) for the full rationale and why Options A–E were abandoned.

- [x] **Discovery: static-bionic arm64-v8a binaries run on Linux arm64 + glibc.** Validated empirically on Pi OS bullseye with ReVanced's stock `aapt2-arm64-v8a` from `v1.1.0` — `aapt2 version` exits 0.
- [x] **Build script `shims/aapt2/build.sh`** clones ReVanced/aapt2 v1.1.0, sed-patches `Util.cpp` (`sMinorVersion`) + `libbuildversion.cpp` (`soong_build_number[128]` initializer) to force the exact `AAPT2_VERSION_STRING` from `pack-versions/<v>.env`, downloads NDK r27c + protoc 21.12 if not in env, runs ReVanced's `patch.sh` + `build.sh arm64-v8a`. Idempotent.
- [x] CI workflows split: aapt2 builds on `ubuntu-22.04` (x86_64 — NDK is x86_64-only) in a separate `build-aapt2` job, the `.so` shims continue on `ubuntu-22.04-arm` inside debian:11. Both feed the release packaging step.
- [x] `verify-version.sh` and `verify-daemon.sh` re-enabled in CI via `verify-symbols.sh` wrapper (uniform CI invocation across shims).
- [x] Release `36.1.53` republished including native arm64 aapt2; validated end-to-end on Pi 4 (8 GB): `dotnet publish -c Release -f net10.0-android` of vanilla canary completes in **3m40s** (vs ~4 min with qemu-x86_64 fallback), produces signed APK, installs and launches successfully on Pixel device.

## Phase 3 — Distribution + integration (in progress)

- [x] GitHub release tarball assembly: `scripts/package-release.sh` produces `dist/shims-linux-arm64-<v>.tar.gz` + `SHA256SUMS` + outer `.sha256`. Release workflow at `.github/workflows/release.yml` triggers on tag push (`X.Y.Z`).
- [x] **Bootstrap script: `scripts/install-shims.sh`** (zero deps beyond `bash`/`curl`/`tar`/`sha256sum`). Auto-detects installed pack versions, downloads matching release, verifies `SHA256SUMS`, backs up originals to `tools/.x86_64-backup/` (and `tools/Linux/.x86_64-backup/` for `aapt2`), idempotent on re-run. CI smoke test in `build-shims.yml` exercises the full overlay against a fake pack tree.
- [ ] Integrate from [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer): when `RuntimeInformation.OSArchitecture == Arm64 && IsLinux`, before `dotnet publish` for an Android project, invoke `install-shims.sh`. (Out of scope of this repo — happens in DotnetDeployer.)

## Phase 4 — Validation on rpi4 (done) ✅

- [x] Run shim install on the rpi4 worker. ✅ (Pi OS bullseye, glibc 2.31, dotnet SDK 10.0.202, pack 36.1.53.)
- [x] Build a vanilla `dotnet new android` template via `dotnet publish -c Release -f net10.0-android`. ✅ Produces signed APK + AAB. **~4 min** end-to-end on Pi 4 (8 GB) — the .so shims load cleanly; aapt2 still runs via qemu-x86_64 (binfmt_misc) until Phase 2 lands a native one.
- [x] **Install + launch the APK on a real Android device.** ✅ Pixel device, cold start 234 ms, no FATAL/AndroidRuntime errors, `Hello, Android!` rendered. Activity displayed via `ActivityTaskManager: Displayed com.companyname.CanaryApp/...MainActivity: +234ms`.
- [ ] Trigger DotnetDeployer for the [Pokémon-Battle-Engine](https://github.com/SuperJMN/Pokemon) repo from the Fleet UI. (Out of scope — DotnetDeployer integration. **Currently blocked by Phase 6**: the Pokémon project's Release publish hits the AOT codegen path on `net10.0-android` and fails on the x86_64 `binutils/bin/llc`. Manually validated to work after applying the Phase 6 recipe by hand.)

> **glibc baseline**: shims are now built inside `debian:11` (glibc 2.31) so they load on Pi OS bullseye. Building on the bare `ubuntu-22.04-arm` runner produced binaries depending on `GLIBC_2.33` (versioned `stat`/`fstat`/`lstat`/`mknod`), which fails to load on bullseye. Fixed in commit `56263e4`.

## Phase 5 — Maintenance loop (in progress)

- [x] **sha256-anchored compatibility manifest** (`compatibility.json`): a single shim release covers an entire pack subseries. Verified empirically — across all 35.0.x and 36.1.x pack versions (15 checked, including 36.1.99 and 36.99 previews), only 2 distinct host-binary fingerprints exist. Both `.so` files are byte-identical for *every* version; `aapt2` changed exactly once (35.x→36.x). `install-shims.sh` consults the manifest as a fallback when no release exists at the literal pack-version tag.
- [x] **CI watcher** (`.github/workflows/watch-nuget.yml`): weekly cron polls the NuGet feed; for each new pack version, sha256-fingerprints the three host binaries; opens an auto-mergeable PR if all three sha256s match an existing release's anchors (zero-rebuild expansion), or an actionable issue with the drifted sha256s and a one-click `release.yml` dispatch link otherwise.
- [x] **Bump runbook** (`docs/maintenance.md`): scenario-driven recipe for each kind of upstream change (aapt2 string bump, libzip soname bump, Mono.Posix symbol surface change, new host binary, new pack series). Linked from README under "Maintenance burden". Happy-path procedure is "merge the auto-PR".

## Phase 6 — AOT / binutils shim (done) ✅

Promoted from "out of scope" after a confirmed in-the-wild reproduction **and** a manually-validated end-to-end fix on the rpi4 worker (signed APK + AAB produced for the Pokémon project). The recipe is now mechanical — see [`docs/llvm-toolchain.md`](docs/llvm-toolchain.md) "Validated reproduction recipe (2026-04-25)" for the verified set of binaries, minimum LLVM major (15+, validated with 19.1.7), drop-in mapping, and apt source.

- [x] **Ship aarch64 replacements for the 6 x86_64 binaries** in `tools/Linux/binutils/bin/`: `as`, `ld`, `llc`, `llvm-mc`, `llvm-objcopy`, `llvm-strip`. Strategy: host-installed (symlinks to `/usr/bin/as` and `/usr/lib/llvm-{N}/bin/*`) instead of bundling — keeps the tarball ~50 MB smaller and aligns with the validated rpi4 recipe.
- [x] **Extend `scripts/install-shims.sh`** to overlay the `binutils/bin/` tree, mirroring the existing `tools/Linux/aapt2` overlay pattern (back up originals to `tools/Linux/binutils/.x86_64-backup/`, idempotent on re-run, sha256-anchored via `compatibility.json`). New flags: `--skip-binutils`, `--llvm-major <N>`. Exit code 6 = partial install (.so/aapt2 succeeded, binutils failed — re-runnable).
- [x] **Decide bundling vs. host-installed LLVM.** Bundled would add ~50 MB compressed (~95 MB uncompressed lib/) for marginal UX gain; host-installed needs one apt one-liner. Decision: **host-installed for v1**, documented in `docs/llvm-toolchain.md` "Implementation (v1)". Revisit only if user feedback shows the apt prereq is too friction-heavy.
- [x] **CI smoke step**: extended `.github/workflows/build-shims.yml` to install LLVM 19 on the arm64 runner, stand up a fake pack tree with `binutils/bin/` placeholders, run `install-shims.sh`, assert each of the 6 entries is symlinked to the expected target, `--version` runs cleanly, backups exist, and re-run is idempotent. Plus a separate `--skip-binutils` smoke. Full `dotnet publish -c Release -f net*-android -r android-arm64` lives in `.github/workflows/aot-smoke.yml` (weekly + dispatch, `continue-on-error: true` for now).
- [x] **Watcher (`watch-nuget.yml`) extended** to fingerprint the 6 binutils binaries too. If only the binutils sha256s drift (LLVM major bump in the pack), the issue body points the maintainer at `compatibility.json::binutils.preferred_llvm_majors` rather than triggering a needless `release.yml` rebuild.

## Out of scope (for now)

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

> **Status update (2026-04-25):** the Pokémon end-to-end flow has been manually validated on the rpi4 worker after applying the Phase 6 shim recipe by hand (LLVM 19 + system binutils symlinked into `tools/Linux/binutils/bin/`). The `dotnet publish` produces both a signed APK (~85 MB) and AAB (~81 MB).
>
> **Status update (Phase 6 packaged):** the recipe now ships out of the box. `install-shims.sh` does the symlink overlay automatically, gated on a host-installed LLVM ≥ 15 (one apt one-liner — see `docs/llvm-toolchain.md`). The rpi4 worker no longer needs the manual fix; reinstalling the shim package preserves the AOT path. v1 done-ness reached.
