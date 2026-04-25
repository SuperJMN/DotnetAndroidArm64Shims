# LLVM toolchain (Phase 6 — packaged in v1) ✅

The pack ships an LLVM bundle under `tools/Linux/binutils/`:

- `bin/as`, `bin/ld` — host binutils used as the GNU assembler / linker for AOT-emitted code.
- `bin/llc`, `bin/llvm-mc`, `bin/llvm-objcopy`, `bin/llvm-strip`, plus `lib/liblld*.so.*`, `libLLVM-*.so` — the LLVM tools.

These are **only** invoked by the AOT and NativeAOT publish paths. The default Mono APK build (which is what most apps including the Pokémon canary use) does not touch them — so v1 of the shim package shipped without them. Phase 6 packages an in-the-wild AOT fix that was first applied by hand on the rpi4 worker; the install script now does the equivalent automatically.

## Implementation (v1)

**Strategy:** host-installed LLVM, **not** bundled. `scripts/install-shims.sh` symlinks the 6 x86_64 binaries inside `tools/Linux/binutils/bin/` to host-installed equivalents:

```
binutils/bin/as           → /usr/bin/as                       (system binutils, aarch64)
binutils/bin/ld           → /usr/lib/llvm-{N}/bin/ld.lld      (LLD as drop-in for ld)
binutils/bin/llc          → /usr/lib/llvm-{N}/bin/llc
binutils/bin/llvm-mc      → /usr/lib/llvm-{N}/bin/llvm-mc
binutils/bin/llvm-objcopy → /usr/lib/llvm-{N}/bin/llvm-objcopy
binutils/bin/llvm-strip   → /usr/lib/llvm-{N}/bin/llvm-strip
```

`{N}` is the highest LLVM major present on the host that's ≥ 15, picked from `compatibility.json::binutils.preferred_llvm_majors` (default `[19,18,17,16,15]`). Override with `install-shims.sh --llvm-major 18`. Originals are backed up to `tools/Linux/binutils/.x86_64-backup/`. Idempotent on re-run. If the host has no acceptable LLVM, the script prints the apt one-liner below and exits with code 7 — the .so/aapt2 overlay still succeeded, so the install is "partial" rather than rolled back. Re-run after installing LLVM, or pass `--skip-binutils` if you don't need AOT.

### User prerequisite (one apt one-liner)

The shim's only new prereq for AOT publishes:

```bash
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key |
  sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/apt.llvm.org.gpg
echo "deb http://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-19 main" |
  sudo tee /etc/apt/sources.list.d/llvm-19.list
sudo apt-get update
sudo apt-get install -y llvm-19 lld-19 binutils
```

Validated on Pi OS bullseye and Ubuntu jammy. apt.llvm.org publishes aarch64 packages for both. Bullseye-backports is **not** sufficient — it does not ship LLVM ≥ 15 for arm64.

### Why host-installed and not bundled

| Option           | Tarball delta             | Prereqs                           | Verdict |
|------------------|---------------------------|-----------------------------------|---------|
| Bundle           | +~50 MB compressed (the LLVM 18 .so set; the 6 bin/ entries themselves are ~1 MB) | None (works on a fresh Pi)        | Rejected for v1 |
| Host-installed   | 0                         | `llvm-19 lld-19 binutils` via apt | **Chosen** |

Rationale:
1. The bundled path would have to ship the matching `lib/libLLVM-*.so.18.1` + `liblld*.so.18.1` (~95 MB uncompressed) for the cross-built `bin/` entries to load, ballooning the release artifact.
2. Anyone doing serious Pi-4 .NET dev already has LLVM/binutils available or trivially obtainable — the friction is one apt command, not a build-from-source ordeal.
3. The host-installed strategy decouples our release cadence from upstream LLVM bumps in the SDK pack: when Microsoft moves from LLVM 18 to 19 inside the pack (as has happened across the 35.x → 36.x series), our shim doesn't need a rebuild — only a manifest update to bump `binutils.preferred_llvm_majors`. See `docs/maintenance.md` Scenario F.

Revisit only if user feedback shows the apt prereq is too friction-heavy.

## Validated reproduction recipe (2026-04-25, kept for reference)

Manually shimmed on the Rpi4 worker (Debian 11 bullseye, aarch64, `Microsoft.Android.Sdk.Linux` 36.1.53) and confirmed end-to-end: `dotnet publish -c Release -f net10.0-android -r android-arm64` of the Pokémon project produces a signed APK (~85 MB) and AAB (~81 MB). The implementation above is a packaging of this recipe.

### 1. Exact set of x86_64 binaries in `tools/Linux/binutils/bin/`

`file` survey on pack 36.1.53:

| Binary        | Type                       | Notes                                              |
|---------------|----------------------------|----------------------------------------------------|
| `as`          | ELF 64-bit LSB, x86-64     | GNU assembler (NOT LLVM)                           |
| `ld`          | ELF 64-bit LSB, x86-64     | GNU linker                                         |
| `llc`         | ELF 64-bit LSB, x86-64     | LLVM static compiler — used by AOT IR → asm        |
| `llvm-mc`     | ELF 64-bit LSB, x86-64     | LLVM machine-code playground (assembler driver)    |
| `llvm-objcopy`| ELF 64-bit LSB, x86-64     |                                                    |
| `llvm-strip`  | ELF 64-bit LSB, x86-64     |                                                    |

Other entries in the directory (per-arch wrappers like `aarch64-linux-android-as`, `arm-linux-androideabi-ld`, etc.) are already arm64-friendly stubs and do **not** need shimming. There are **no** `objcopy`, `objdump`, `lld`, `lld-link`, `wasm-ld` binaries in this directory in pack 36.1.53.

(Pack 35.0.105 ships **byte-identical** binutils — same sha256s for all 6 entries. `llvm-objcopy` is also byte-identical to `llvm-strip` in both packs; they're the same binary under two names.)

### 2. Minimum LLVM major: 15

LLVM 11 (Debian bullseye stock) **does not work**. The Microsoft Android SDK 36.x emits LLVM IR using **opaque pointers** (`ptr`), introduced in LLVM 15+. Trying it with LLVM 11 yields:

```
.../llc: error: environment.arm64-v8a.ll:32:2: error: expected type
        ptr, ; char* android_package_name
                      ^
.../llc: error: typemaps.arm64-v8a.ll:16:2: error: expected type
        ptr, ; TypeMapModuleEntry map
                      ^
error XA3006: Could not compile native assembly file: environment.arm64-v8a.ll
```

Validated working: **LLVM 19.1.7** (`llvm-19` from `apt.llvm.org/bullseye`, `llvm-toolchain-bullseye-19 main`). Anything ≥ 15 should work; staying close to upstream's current major (≥ 18) is the safer choice.

### 3. Original symptom (kept for ENOEXEC web search hits)

```
System.ComponentModel.Win32Exception (8): An error occurred trying to start process
'/home/<user>/.dotnet/packs/Microsoft.Android.Sdk.Linux/<ver>/tools/Linux/binutils/bin/llc'
with working directory 'obj/Release/net*-android/android/'. Exec format error
```

`errno 8` = `ENOEXEC`: the kernel refuses to exec the binary because it is x86_64 ELF on an aarch64 host. After running `install-shims.sh` against an SDK pack on a host with LLVM ≥ 15 installed, this exception no longer occurs — the publish proceeds through `llc` → `as` → `ld.lld` and produces a signed arm64-v8a APK.

## Resolved questions

- **Bundle or host-install LLVM?** Host-install for v1 (see "Why host-installed and not bundled" above). Revisit if user feedback shows the apt prereq is too painful.
- **Is `ld.lld` an acceptable drop-in for `ld` long-term?** Yes for the validated Mono+AOT path. The Android workload's link line uses options LLD supports natively — no flag translation needed. If a future workload starts depending on GNU-ld-only flags, override the `ld` mapping in `compatibility.json::binutils.mapping` to point at `/usr/bin/ld`.
- **Does the IR-emission path need aarch64-tuned `--mtriple`/`--mcpu`?** No. LLVM 19 accepts the SDK's stock invocation as-is.
