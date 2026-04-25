# LLVM toolchain (deferred — out of scope for v1)

The pack ships an LLVM bundle under `tools/Linux/binutils/`:

- `bin/as`, `bin/ld` — host binutils used as the GNU assembler / linker for AOT-emitted code.
- `bin/llc`, `bin/llvm-mc`, `bin/llvm-objcopy`, `bin/llvm-strip`, plus `lib/liblld*.so.*`, `libLLVM-*.so` — the LLVM tools.

These are **only** invoked by the AOT and NativeAOT publish paths. The default Mono APK build (which is what most apps including the Pokémon canary use) does not touch them.

## Why we're skipping them

- Materially more work: the LLVM bundle is ~200 MB and built from a pinned LLVM tag with Android-specific patches.
- Limited audience among the actual users of this shim repo.
- Easier to revisit after Phase 4 confirms the simple Mono path works end-to-end.

## When we'd come back

If a user reports needing `PublishAot=true` or `RunAOTCompilation=true` on an arm64 host, reopen this doc and:

1. Identify the pinned LLVM tag from the pack (`llc --version` will print it).
2. Cross-build LLVM for `linux-aarch64` using upstream's CMake (well-supported).
3. Add to the shim release tarball.
4. Bump the bootstrap script to overlay the `binutils/` directory too.

Until then: if a user tries to AOT-publish on arm64, DotnetDeployer should detect this and emit a clear error pointing here.

## Pending: confirmed reproduction (next iteration)

**Status:** triggered in the wild — promote from "deferred" to actionable TODO.

- **Symptom.** Building an Android project with `RunAOTCompilation=true` (Release config) on linux-arm64 fails the moment MSBuild invokes `llc`:

  ```
  System.ComponentModel.Win32Exception (8): An error occurred trying to start process
  '/home/<user>/.dotnet/packs/Microsoft.Android.Sdk.Linux/<ver>/tools/Linux/binutils/bin/llc'
  with working directory 'obj/Release/net*-android/android/'. Exec format error
  ```

  `errno 8` = `ENOEXEC`: the kernel refuses to exec the binary because it is x86_64 ELF on an aarch64 host.

- **Root cause.** The entire `tools/Linux/binutils/bin/` directory inside `Microsoft.Android.Sdk.Linux` is shipped as x86_64 ELF. The current shim set (`aapt2`, `libZipSharpNative-3-3.so`, `libMono.Unix.so` — see `scripts/install-shims.sh`) does **not** cover any of the binutils binaries, so AOT publish paths break immediately on arm64 hosts even with shims installed.

- **Pinned context.** Reproduced on a Raspberry Pi 4 (Debian/Ubuntu arm64) against `Microsoft.Android.Sdk.Linux` **36.1.53**, driven from the [DotnetFleet](https://github.com/SuperJMN/DotnetFleet) build pipeline.

- **Action item for the next iteration.**
  1. **Audit the whole `tools/Linux/binutils/bin/` directory**, not just `llc`. See the validated list below.
  2. Provide aarch64 replacements — either repackaged from the host's system binutils + LLVM packages (cheapest, validated below), or cross-built from the same upstream LLVM tag the pack pins (most faithful).
  3. Extend `scripts/install-shims.sh` and the release tarball to overlay the `binutils/` tree, mirroring the existing `tools/Linux/aapt2` overlay (with backup to `tools/Linux/binutils/.x86_64-backup/`).
  4. Add a verification step that runs `<binary> --version` for each shipped binutils binary on arm64 to catch ENOEXEC regressions in CI.

## Validated reproduction recipe (2026-04-25)

Manually shimmed on the same Rpi4 worker (Debian 11 bullseye, aarch64, `Microsoft.Android.Sdk.Linux` 36.1.53) and confirmed end-to-end: `dotnet publish -c Release -f net10.0-android -r android-arm64` of the Pokémon project produces a signed APK (~85 MB) and AAB (~81 MB). The recipe below is therefore the cheapest known-good path; the next-iteration shim package can implement it directly.

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

Other entries in the directory (per-arch wrappers like `aarch64-linux-android-as`, `arm-linux-androideabi-ld`, etc.) are already arm64-friendly stubs and do **not** need shimming.

There are **no** `objcopy`, `objdump`, `lld`, `lld-link`, `wasm-ld` binaries in this directory in pack 36.1.53. (Earlier drafts of this doc listed them speculatively.)

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

### 3. Verified mapping (drop-in replacements)

```
binutils/bin/as           →  /usr/bin/as                       # GNU binutils 2.35.2 (system, aarch64)
binutils/bin/ld           →  /usr/lib/llvm-19/bin/ld.lld       # LLD 19.1.7 — drop-in for ld
binutils/bin/llc          →  /usr/lib/llvm-19/bin/llc          # LLVM 19.1.7
binutils/bin/llvm-mc      →  /usr/lib/llvm-19/bin/llvm-mc      # LLVM 19.1.7
binutils/bin/llvm-objcopy →  /usr/lib/llvm-19/bin/llvm-objcopy # LLVM 19.1.7
binutils/bin/llvm-strip   →  /usr/lib/llvm-19/bin/llvm-strip   # LLVM 19.1.7
```

`ld.lld` works as a drop-in for the GNU `ld` interface that the Android workload invokes — no flag translation needed for the Pokémon (Mono+AOT) path. If a future workload starts depending on GNU-ld-only flags, fall back to `/usr/bin/ld` from system binutils for the `ld` slot.

### 4. Package source

For Debian/Ubuntu arm64 hosts, the canonical source for a recent enough LLVM is the official llvm.org apt repository, which **does** publish aarch64 packages for bullseye:

```bash
wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key |
  gpg --dearmor -o /etc/apt/trusted.gpg.d/apt.llvm.org.gpg
echo "deb http://apt.llvm.org/bullseye/ llvm-toolchain-bullseye-19 main" \
  > /etc/apt/sources.list.d/llvm-19.list
apt-get update
apt-get install -y llvm-19 lld-19 binutils
```

(Bullseye-backports is **not** sufficient — it does not ship LLVM ≥ 15 for arm64.)

### 5. Open questions for the next iteration

- Whether to **bundle** the LLVM/binutils binaries inside the shim release tarball (large: ~150 MB compressed) or to depend on a host-installed LLVM (small: just symlinks). The validated recipe above is the host-installed variant — far cheaper to ship, but pushes one more apt prerequisite onto the user.
- Whether `ld.lld` is acceptable long-term, or whether the shim should provide a real GNU `ld` for stricter compatibility.
- Whether the IR-emission path also needs aarch64-tuned `--mtriple`/`--mcpu` overrides; with LLVM 19 the build succeeded with the SDK's stock invocation, so currently no.
