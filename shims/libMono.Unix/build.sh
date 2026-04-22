#!/usr/bin/env bash
# Build libMono.Unix.so for linux-arm64.
#
# Source:  https://github.com/mono/mono.posix
#
# We invoke the upstream CMakeLists at src/native/ directly. Passing
# -DTARGET_PLATFORM=host-linux-x64 on an arm64 host is the documented way to
# produce a *native* build (toolchain.linux.cmake sets IS_CROSS_BUILD=False
# for any host-linux-* value other than arm64/arm/armv6, leaving the system
# compiler untouched). Result: a native aarch64 ELF without pulling in
# cross-compile toolchain packages.
#
# Output:
#   out/linux-arm64/libMono.Unix.so   (stripped)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/libMono.Unix}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/mono/mono.posix"
MONO_POSIX_REF="${MONO_POSIX_REF:-main}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [[ ! -d "$WORK_DIR/src/.git" ]]; then
    echo ">> cloning $SRC_REPO @ $MONO_POSIX_REF"
    git clone --depth 1 --branch "$MONO_POSIX_REF" "$SRC_REPO" "$WORK_DIR/src"
else
    echo ">> reusing existing checkout at $WORK_DIR/src"
    git -C "$WORK_DIR/src" fetch --depth 1 origin "$MONO_POSIX_REF"
    git -C "$WORK_DIR/src" checkout FETCH_HEAD
fi

BUILD_DIR="$WORK_DIR/build"
rm -rf "$BUILD_DIR"

echo ">> configuring (native arm64 via TARGET_PLATFORM=host-linux-x64)"
cmake -GNinja -B "$BUILD_DIR" -S "$WORK_DIR/src/src/native" \
    -DCMAKE_BUILD_TYPE=Release \
    -DTARGET_PLATFORM=host-linux-x64 \
    -DSTRIP_DEBUG=ON

echo ">> building"
cmake --build "$BUILD_DIR" -j"$(nproc)"

# Locate the produced .so. CMake puts it in build/lib/ by default. The
# upstream target name is `Mono.Unix` so the output is libMono.Unix.so
# (potentially with a SOVERSION suffix and a symlink chain).
PRODUCED=""
while IFS= read -r f; do
    PRODUCED="$f"; break
done < <(find "$BUILD_DIR" -type f -name 'libMono.Unix.so*' -not -name '*.dbg' | sort)
[[ -n "$PRODUCED" ]] || {
    echo "!! libMono.Unix.so not produced; tree:"
    find "$BUILD_DIR" -name '*.so*'
    exit 4
}
echo ">> produced: $PRODUCED"

cp "$PRODUCED" "$OUT_DIR/libMono.Unix.so"
strip --strip-unneeded "$OUT_DIR/libMono.Unix.so"
file "$OUT_DIR/libMono.Unix.so"
echo ">> wrote $OUT_DIR/libMono.Unix.so"
