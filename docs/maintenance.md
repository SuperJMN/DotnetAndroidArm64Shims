# Maintenance runbook

How to keep this repo current with upstream `Microsoft.Android.Sdk.Linux`
releases. Most of the work is automated; this document covers what to do
in each scenario the watcher surfaces, plus the manual triggers for the
rare cases the automation doesn't cover.

## TL;DR — the happy path

You don't have to do anything. The [`watch-nuget`](.github/workflows/watch-nuget.yml)
workflow runs every Monday at 06:00 UTC. For each new pack version on
NuGet:

1. It downloads the upstream nupkg and sha256-fingerprints the three
   host binaries (`tools/Linux/aapt2`, `tools/libMono.Unix.so`,
   `tools/libZipSharpNative-3-3.so`).
2. If all three sha256s match an existing release's anchors in
   [`compatibility.json`](../compatibility.json) → opens an auto-mergeable
   PR adding an alias entry. **Merge it. That's the entire ritual.**
3. If any sha256 has drifted → opens an issue tagged `shim-drift`. See
   [Scenario A](#scenario-a-aapt2-version-string-bump-most-common) below.

You can also trigger it manually for a specific version:

```
gh workflow run watch-nuget.yml -R SuperJMN/DotnetAndroidArm64Shims \
  -f pack_version=37.0.0
```

---

## Scenario A: aapt2 version string bump (most common)

Symptom: the watcher opened a `shim-drift` issue. Drift report shows a
new `aapt2=` sha256 but the two `.so` sha256s match an existing release.

Root cause: AOSP cut a new `build-tools` snapshot (typically once a year),
so the AAPT2 version string changed (e.g. `2.20-13193326` → `2.21-XXXXXXXX`).
The .NET MSBuild tasks compare this string byte-for-byte and invalidate
caches when it differs, so we genuinely need a new `aapt2` build.

### Steps

1. **Identify the new aapt2 version string.** From the issue body, find
   the new aapt2 sha256. Then download the upstream pack and read the
   string off the binary directly:

   ```bash
   V=37.0.0   # the new pack version from the issue
   curl -fsSL -o /tmp/pack.nupkg \
     "https://www.nuget.org/api/v2/package/Microsoft.Android.Sdk.Linux/$V"
   mkdir -p /tmp/pack && unzip -q -o /tmp/pack.nupkg \
     "tools/Linux/aapt2" -d /tmp/pack
   # qemu-user-static needed if you're on x86_64; on arm64 just run it
   /tmp/pack/tools/Linux/aapt2 version
   # → "Android Asset Packaging Tool (aapt) 2.21-XXXXXXXX"
   ```

   The bit after the dash (`XXXXXXXX`) is the AOSP build ID.

2. **Create the env file.** Copy the closest existing `pack-versions/*.env`
   and edit the two aapt2 fields:

   ```bash
   cp pack-versions/36.1.53.env pack-versions/$V.env
   ```

   Edit `pack-versions/$V.env`:
   ```
   PACK_VERSION=37.0.0
   AAPT2_VERSION_STRING="Android Asset Packaging Tool (aapt) 2.21-XXXXXXXX"
   AAPT2_AOSP_BUILD_ID=XXXXXXXX
   ```

   Leave the `LIBZIP_VERSION`, `LIBZIPSHARP_SONAME_SUFFIX`, and symbol
   counts alone unless those *also* drifted (see Scenarios B and C).

3. **Dispatch the release build.**
   ```bash
   git add pack-versions/$V.env
   git commit -m "pack: add env for $V" && git push
   gh workflow run release.yml -R SuperJMN/DotnetAndroidArm64Shims \
     -f pack_version=$V
   ```
   Wait ~10 min for the green release.

4. **Add the new release's anchors to the manifest.** Compute them from
   the upstream pack you already downloaded in step 1:

   ```bash
   sha256sum /tmp/pack/tools/Linux/aapt2 \
             /tmp/pack/tools/libMono.Unix.so \
             /tmp/pack/tools/libZipSharpNative-3-3.so
   ```

   Add a new entry under `compatibility.json::anchors`:
   ```json
   "37.0.0": {
     "tools/Linux/aapt2":              "<new aapt2 sha256>",
     "tools/libMono.Unix.so":          "ce99f5…",
     "tools/libZipSharpNative-3-3.so": "cb52cc…"
   }
   ```

   Commit and push.

5. **Re-run the watcher.** Any other new pack versions in the same
   subseries will now be classified as aliasable to your new release and
   PR'd automatically:
   ```bash
   gh workflow run watch-nuget.yml -R SuperJMN/DotnetAndroidArm64Shims
   ```

6. **Close the drift issue** with a link to the new release.

Total time: ~30 minutes, ~10 of them waiting on the build.

---

## Scenario B: libZipSharpNative soname bump

Symptom: drift issue shows new `libzip` sha256 *and* the binary inside
the pack is at a new path (e.g. `tools/libZipSharpNative-3-4.so` instead
of `-3-3.so`).

Root cause: `libzip` upstream bumped its API revision. The .NET task
imports the native library by literal soname, so we need a new build
matching the new suffix.

### Steps

1. Update the upstream submodule pin in `shims/libZipSharpNative/`
   (verify the new soname suffix in the upstream `CMakeLists.txt`).
2. Bump `LIBZIPSHARP_SONAME_SUFFIX` in the pack-version env file.
3. **Update the watcher**: the binary path is hardcoded as
   `tools/libZipSharpNative-3-3.so` in
   [`.github/workflows/watch-nuget.yml`](../.github/workflows/watch-nuget.yml)
   and in `compatibility.json::anchors`. Both need the new suffix
   alongside the old one (the watcher should probe the pack's actual
   contents via `unzip -l` rather than hardcoding the name; if you hit
   this scenario, that refactor goes in the same PR).
4. Otherwise follow Scenario A from step 3.

This scenario has not been observed yet (libzip 1.10.x has held the
`-3-3` suffix since 2023).

---

## Scenario C: libMono.Unix.so symbol surface change

Symptom: drift issue shows new `mono` sha256. The build also fails at
`shims/libMono.Unix/verify-symbols.sh` because the upstream binary
exports more or fewer symbols than the pinned count.

Root cause: Microsoft pulled in a new Mono.Posix snapshot.

### Steps

1. Re-run `scripts/extract-reference-symbols.sh <new-version>` to dump
   the new symbol set into `shims/libMono.Unix/reference-symbols.txt`.
2. Diff against HEAD:
   ```bash
   git diff shims/libMono.Unix/reference-symbols.txt
   ```
   * **Symbols added**: usually safe — the shim might already export
     them via the same upstream submodule. Bump the submodule pin if
     needed.
   * **Symbols removed**: never observed, but if it happens our shim
     exports more than upstream, which is fine.
3. Update `MONO_POSIX_EXPECTED_SYMBOL_COUNT` and
   `LIBMONO_UNIX_EXPECTED_SYMBOL_COUNT` in the pack-version env file.
4. Otherwise follow Scenario A from step 3.

---

## Scenario D: a new host binary appears in the pack

Symptom: the watcher logs `pack layout differs for <version> (missing
one of the three host binaries)` and opens a drift issue listing the
version with no sha256s.

Root cause: Microsoft added (or removed, or renamed) a host binary in
the pack. This is structural — re-evaluate scope.

### Steps

1. Inspect the pack contents:
   ```bash
   curl -fsSL -o /tmp/pack.nupkg \
     "https://www.nuget.org/api/v2/package/Microsoft.Android.Sdk.Linux/<version>"
   unzip -l /tmp/pack.nupkg | grep -E '(tools/Linux/|tools/lib).*\.(so|exe)?$'
   ```
2. Compare to the table in [`README.md`](../README.md#whats-in-scope).
3. If the new binary is in scope (host-side, x86_64, called by MSBuild
   tasks), add a build recipe under `shims/<name>/` and wire it through
   `.github/workflows/release.yml`.
4. If it's out of scope (device payload, optional AOT toolchain), update
   the README and add the new path to a watcher allowlist so future
   scans don't keep flagging it.

This scenario has not been observed since the repo was created.

---

## Scenario E: completely new pack series (e.g. 37.x ships)

Symptom: a 37.x pack version on NuGet, no existing 37.x release in this
repo, watcher opens a drift issue.

Treat as Scenario A (the aapt2 string almost always changes between
major series). Optionally also re-baseline by running
`scripts/extract-reference-symbols.sh` against the latest version of the
new series and updating the comparison row in
[`README.md`](../README.md#coverage-model-one-release-many-pack-versions).

---

## Manual fingerprint inspection (debugging)

To see what the watcher would do for a specific version without running
the workflow:

```bash
V=36.1.53
curl -fsSL -o /tmp/pack.nupkg \
  "https://www.nuget.org/api/v2/package/Microsoft.Android.Sdk.Linux/$V"
mkdir -p /tmp/pack && unzip -q -o /tmp/pack.nupkg \
  "tools/Linux/aapt2" \
  "tools/libMono.Unix.so" \
  "tools/libZipSharpNative-3-3.so" \
  -d /tmp/pack
sha256sum /tmp/pack/tools/Linux/aapt2 \
          /tmp/pack/tools/libMono.Unix.so \
          /tmp/pack/tools/libZipSharpNative-3-3.so
```

Cross-reference against `compatibility.json::anchors` to find the
matching release tag, or note which sha256 has drifted.

---

## Verifying a release tarball after the fact

```bash
TAG=35.0.105
curl -fsSL -o /tmp/shims.tar.gz \
  "https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases/download/$TAG/shims-linux-arm64-$TAG.tar.gz"
mkdir -p /tmp/shims && tar -C /tmp/shims -xzf /tmp/shims.tar.gz
(cd /tmp/shims && sha256sum -c SHA256SUMS)
file /tmp/shims/aapt2 /tmp/shims/libMono.Unix.so /tmp/shims/libZipSharpNative-3-3.so
# expect: aarch64 ELF for aapt2; aarch64 shared object for the .so files
```

---

## When to archive this repo

When [dotnet/android#11184](https://github.com/dotnet/android/issues/11184)
ships an official `Microsoft.Android.Sdk.Linux` arm64 host pack:

1. Confirm the official pack works on a Pi 4 with the
   [Pokémon-Battle-Engine](https://github.com/SuperJMN/Pokemon) canary.
2. Update [DotnetDeployer](https://github.com/SuperJMN/DotnetDeployer)'s
   `AndroidArm64ShimInstaller` to no-op when the upstream arm64 pack is
   detected.
3. Add a banner to this README pointing at the upstream pack.
4. Disable `watch-nuget.yml`.
5. Archive on GitHub.

Don't delete the releases — DotnetDeployer pins to specific shim tags
for older pack versions and may continue to need them for a while.
