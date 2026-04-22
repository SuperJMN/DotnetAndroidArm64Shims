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
