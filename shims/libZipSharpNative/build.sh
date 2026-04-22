#!/usr/bin/env bash
# Build libZipSharpNative-3-3.so for linux-arm64.
#
# Source:
#   wrapper:   https://github.com/xamarin/LibZipSharp
#   libzip:    https://github.com/nih-at/libzip   (vendored as submodule)
#
# Output:
#   out/linux-arm64/libZipSharpNative-3-3.so   (stripped)
#
# The `-3-3` soname suffix matches the upstream x86_64 binary in pack 36.1.53.
# If a future pack bumps libzip past API revision 3, this file name changes
# and a new shim release is needed (see pack-versions/<v>.env).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/libZipSharpNative}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/xamarin/LibZipSharp"
LIBZIPSHARP_REF="${LIBZIPSHARP_REF:-main}"
SONAME_SUFFIX="${LIBZIPSHARP_SONAME_SUFFIX:-3-3}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [[ ! -d "$WORK_DIR/src/.git" ]]; then
    echo ">> cloning $SRC_REPO @ $LIBZIPSHARP_REF"
    git clone --recurse-submodules --depth 1 --branch "$LIBZIPSHARP_REF" "$SRC_REPO" "$WORK_DIR/src"
else
    echo ">> reusing existing checkout at $WORK_DIR/src"
    git -C "$WORK_DIR/src" fetch --depth 1 origin "$LIBZIPSHARP_REF"
    git -C "$WORK_DIR/src" checkout FETCH_HEAD
    git -C "$WORK_DIR/src" submodule update --init --recursive --depth 1
fi

cd "$WORK_DIR/src"

# Locate vendored libzip. Path has moved between LibZipSharp revisions.
LIBZIP_DIR=""
for candidate in external/libzip native/libzip libzip; do
    if [[ -f "$candidate/CMakeLists.txt" ]]; then
        LIBZIP_DIR="$candidate"
        break
    fi
done
[[ -n "$LIBZIP_DIR" ]] || { echo "!! could not locate vendored libzip"; find . -maxdepth 3 -name CMakeLists.txt; exit 2; }
echo ">> vendored libzip at $LIBZIP_DIR"

# Build libzip statically — we want a single self-contained .so to drop in.
echo ">> building libzip"
cmake -S "$LIBZIP_DIR" -B "$WORK_DIR/build-libzip" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_REGRESS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_DOC=OFF \
    -DENABLE_BZIP2=OFF \
    -DENABLE_LZMA=OFF \
    -DENABLE_ZSTD=OFF
cmake --build "$WORK_DIR/build-libzip" -j"$(nproc)"

# Native wrapper. LibZipSharp's CMake layout has also drifted; try the common
# spots in order.
NATIVE_DIR=""
for candidate in native LibZipSharp.Native; do
    if [[ -f "$candidate/CMakeLists.txt" ]]; then
        NATIVE_DIR="$candidate"
        break
    fi
done
[[ -n "$NATIVE_DIR" ]] || { echo "!! could not locate native wrapper sources"; find . -maxdepth 3 -name CMakeLists.txt; exit 3; }
echo ">> native wrapper at $NATIVE_DIR"

LIBZIP_INCLUDE="$WORK_DIR/src/$LIBZIP_DIR/lib"
LIBZIP_BUILD_INCLUDE="$WORK_DIR/build-libzip"
LIBZIP_AR="$(find "$WORK_DIR/build-libzip" -name 'libzip.a' | head -1)"
[[ -n "$LIBZIP_AR" ]] || { echo "!! libzip.a not produced"; find "$WORK_DIR/build-libzip" -name '*.a'; exit 4; }
echo ">> libzip static archive: $LIBZIP_AR"

cmake -S "$NATIVE_DIR" -B "$WORK_DIR/build-native" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DLIBZIP_INCLUDE_DIR=$LIBZIP_INCLUDE;$LIBZIP_BUILD_INCLUDE" \
    "-DLIBZIP_LIBRARY=$LIBZIP_AR"
cmake --build "$WORK_DIR/build-native" -j"$(nproc)"

PRODUCED="$(find "$WORK_DIR/build-native" -maxdepth 3 -type f -name '*.so*' | head -1)"
[[ -n "$PRODUCED" ]] || { echo "!! native .so not produced"; find "$WORK_DIR/build-native" -name '*.so*'; exit 5; }

TARGET="$OUT_DIR/libZipSharpNative-${SONAME_SUFFIX}.so"
cp "$PRODUCED" "$TARGET"
strip --strip-unneeded "$TARGET"
file "$TARGET"
echo ">> wrote $TARGET"
