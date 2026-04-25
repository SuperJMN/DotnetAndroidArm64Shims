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
  1. **Audit the whole `tools/Linux/binutils/bin/` directory**, not just `llc`. At minimum `as`, `ld`, `objcopy`, `objdump`, `llc`, `llvm-mc`, `llvm-objcopy`, `llvm-strip` are likely all x86_64 ELF and all reachable from AOT/NativeAOT codegen.
  2. Provide aarch64 replacements — either repackaged from the host's system binutils + LLVM packages (cheapest), or cross-built from the same upstream LLVM tag the pack pins (most faithful).
  3. Extend `scripts/install-shims.sh` and the release tarball to overlay the `binutils/` tree, mirroring the existing `tools/Linux/aapt2` overlay (with backup to `tools/Linux/binutils/.x86_64-backup/`).
  4. Add a verification step that runs `<binary> --version` for each shipped binutils binary on arm64 to catch ENOEXEC regressions in CI.
