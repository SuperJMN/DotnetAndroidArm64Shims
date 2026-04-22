#!/usr/bin/env bash
# Build libZipSharpNative-3-3.so for linux-arm64.
#
# Source: https://github.com/dotnet/android-libzipsharp
#   (xamarin/LibZipSharp moved to dotnet/android-libzipsharp)
#
# We delegate to upstream's own build.sh which knows the correct two-phase
# CMake recipe (deps with -DBUILD_DEPENDENCIES=ON, then native lib with
# -DBUILD_LIBZIP=ON). Trying to recreate that here drifts every time
# upstream rearranges include paths.
#
# Output:
#   out/linux-arm64/libZipSharpNative-<suffix>.so   (stripped)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/libZipSharpNative}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/dotnet/android-libzipsharp"
LIBZIPSHARP_REF="${LIBZIPSHARP_REF:-main}"
SONAME_SUFFIX="${LIBZIPSHARP_SONAME_SUFFIX:-3-3}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [[ ! -d "$WORK_DIR/src/.git" ]]; then
    echo ">> cloning $SRC_REPO @ $LIBZIPSHARP_REF (with submodules)"
    git clone --recurse-submodules --depth 1 --branch "$LIBZIPSHARP_REF" \
        "$SRC_REPO" "$WORK_DIR/src"
else
    echo ">> reusing existing checkout at $WORK_DIR/src"
    git -C "$WORK_DIR/src" fetch --depth 1 origin "$LIBZIPSHARP_REF"
    git -C "$WORK_DIR/src" checkout FETCH_HEAD
    git -C "$WORK_DIR/src" submodule update --init --recursive --depth 1
fi

cd "$WORK_DIR/src"

echo ">> running upstream build.sh"
chmod +x ./build.sh
./build.sh

# Output: lzsbuild/lib/Linux/lib/libZipSharpNative-X-Y.so.X.Y.Z (with SOVERSION
# symlinks alongside).
PRODUCED=""
while IFS= read -r f; do
    PRODUCED="$f"; break
done < <(find "$WORK_DIR/src/lzsbuild" -type f -name "libZipSharpNative-*.so*" -not -name '*.dbg' | sort)
[[ -n "$PRODUCED" ]] || {
    echo "!! libZipSharpNative-*.so not produced; tree:"
    find "$WORK_DIR/src/lzsbuild" -name '*.so*' 2>/dev/null || true
    exit 4
}
echo ">> produced: $PRODUCED"

# Extract the actual SONAME suffix from the file (e.g. "3-3" or "3-4") so we
# don't ship a misnamed file if upstream bumped libzip.
ACTUAL_SUFFIX="$(basename "$PRODUCED" | sed -nE 's/^libZipSharpNative-([0-9]+-[0-9]+).*$/\1/p')"
[[ -n "$ACTUAL_SUFFIX" ]] || ACTUAL_SUFFIX="$SONAME_SUFFIX"
if [[ "$ACTUAL_SUFFIX" != "$SONAME_SUFFIX" ]]; then
    echo "!! SONAME suffix drift: pin says '$SONAME_SUFFIX', upstream produced '$ACTUAL_SUFFIX'"
    echo "   → bump LIBZIPSHARP_SONAME_SUFFIX in pack-versions/$PACK_VERSION.env"
    exit 5
fi

TARGET="$OUT_DIR/libZipSharpNative-${ACTUAL_SUFFIX}.so"
cp "$PRODUCED" "$TARGET"
strip --strip-unneeded "$TARGET"
file "$TARGET"
echo ">> wrote $TARGET"
