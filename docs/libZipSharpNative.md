# libZipSharpNative-3-3.so

P/Invoke target for [LibZipSharp](https://github.com/xamarin/LibZipSharp), a thin C# wrapper around [libzip](https://libzip.org/) used by Android packaging tasks (zipalign-equivalent operations, AAB construction, asset packing). The version suffix `-3-3` corresponds to libzip 1.10 / API revision 3 (cross-check by `strings` if in doubt).

## Source

- Wrapper: [xamarin/LibZipSharp](https://github.com/xamarin/LibZipSharp). Has its own build that produces the native helper as a side artifact.
- Underlying lib: [nih-at/libzip](https://github.com/nih-at/libzip). The Xamarin project vendors a specific tagged version.

## Identifying the exact upstream version

```
strings ~/.dotnet/packs/Microsoft.Android.Sdk.Linux/<version>/tools/libZipSharpNative-3-3.so \
  | grep -iE 'libzip|version' | head
```

The libzip version string is embedded (e.g. `libzip 1.10.1`). Match it when configuring the build.

## Build (sketch)

```
git clone https://github.com/xamarin/LibZipSharp
cd LibZipSharp
git submodule update --init --recursive       # vendors libzip
# The repo uses a Cake build script; for a one-shot arm64 build, invoke CMake directly:
cmake -S external/libzip -B build/libzip-arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON
cmake --build build/libzip-arm64
# Then the native helper:
cmake -S native -B build/native-arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLIBZIP_INCLUDE_DIR=$(pwd)/external/libzip/lib \
  -DLIBZIP_LIBRARY=$(pwd)/build/libzip-arm64/lib/libzip.so
cmake --build build/native-arm64
```

(Adjust to whatever the current build script in LibZipSharp expects — the project moves around.)

The output `.so` should be renamed to `libZipSharpNative-3-3.so` to match the pack convention.

## Verify

Same `nm -D` symbol diff as for `libMono.Unix.so`. The set of exports is small (a couple of dozen `LZS_*` functions).

## Effort

Low. ~1 hour assuming the vendored libzip builds cleanly (it does on Debian / Pi OS — `apt install libz-dev` covers any extra deps).

## Risks

- If Microsoft bumps libzip across pack versions, the `-3-3` suffix could change to `-3-4` etc. The .NET task imports by literal name, so we have to track this and rebuild.
