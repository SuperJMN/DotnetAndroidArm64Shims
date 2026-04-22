# libMono.Unix.so

P/Invoke target for `Mono.Unix` from various MSBuild Android tasks (file mode bits, symlinks, mmap helpers, etc.). The pack ships the x86_64 build only.

## Source

[mono/Mono.Posix](https://github.com/mono/Mono.Posix) — the modern home of what used to live in `mono/mono/support`. The native side is a small C library wrapping POSIX calls (`MonoPosixHelper`-style).

## Identifying the exact upstream version

Run on a host with the workload installed:

```
strings ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libMono.Unix.so | grep -iE 'mono|version|commit' | head
```

The .so usually embeds a build identifier or git hash. Match it when picking the source revision to build from.

## Build (sketch)

```
git clone https://github.com/mono/Mono.Posix
cd Mono.Posix/src/native
./autogen.sh
./configure --host=aarch64-linux-gnu
make
# Output: libMonoPosixHelper.so or similar — rename to libMono.Unix.so for the drop-in.
```

Verify before shipping:

```
nm -D --defined-only libMono.Unix.so > arm64.syms
nm -D --defined-only ~/.dotnet/packs/.../tools/libMono.Unix.so > x64.syms
diff arm64.syms x64.syms     # ideally empty; any missing symbol breaks a P/Invoke
```

## Effort

Low. A few hours including the symbol audit. No expected blockers — the codebase is portable C and has been built for arm64 in other contexts (Mono itself runs on arm64).

## Risks

- Symbol set drift across pack versions. If Microsoft adds a new P/Invoke entry point, our shim becomes stale and the matching MSBuild task fails with `EntryPointNotFoundException`. Mitigated by the `nm` diff in the build pipeline.
