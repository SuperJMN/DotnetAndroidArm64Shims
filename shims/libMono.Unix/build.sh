#!/usr/bin/env bash
# Build libMono.Unix.so for linux-arm64.
#
# Source: https://github.com/mono/Mono.Posix
# The native helper is a small C library wrapping POSIX calls. The pack ships
# it as `tools/libMono.Unix.so`. We rebuild for aarch64 and drop in the same
# place via install-shims.sh.
#
# Output:
#   out/linux-arm64/libMono.Unix.so   (stripped)
#
# Runs on a clean linux-arm64 host (ubuntu-22.04-arm CI runner). Required apt
# packages are listed in `apt-deps.txt` next to this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/libMono.Unix}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/mono/Mono.Posix"
# Pin the source revision. Mono.Posix is fairly stable; bump only if a new
# pack version exposes a P/Invoke entry point we don't ship yet (verify-symbols
# will catch this).
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

# The native sources live under src/native. Layout has shifted across revisions
# so we probe a couple of plausible roots.
NATIVE_DIR=""
for candidate in src/native src/Mono.Posix/native external/Mono.Posix/src/native; do
    if [[ -d "$WORK_DIR/src/$candidate" ]]; then
        NATIVE_DIR="$WORK_DIR/src/$candidate"
        break
    fi
done
[[ -n "$NATIVE_DIR" ]] || { echo "!! could not locate Mono.Posix native sources"; ls "$WORK_DIR/src"; exit 2; }
echo ">> native sources: $NATIVE_DIR"

cd "$NATIVE_DIR"

# Mono.Posix uses autotools when present, falling back to a plain Makefile in
# older revisions. Try autotools first.
if [[ -f autogen.sh ]]; then
    echo ">> autotools build"
    ./autogen.sh
    ./configure
    make -j"$(nproc)"
elif [[ -f configure ]]; then
    ./configure
    make -j"$(nproc)"
elif [[ -f Makefile ]]; then
    echo ">> plain make"
    make -j"$(nproc)"
elif [[ -f CMakeLists.txt ]]; then
    echo ">> cmake build"
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j"$(nproc)"
else
    echo "!! no recognised build system in $NATIVE_DIR"
    ls -la
    exit 3
fi

# Locate the produced .so. Upstream names vary (libMonoPosixHelper.so,
# libMono-Posix.so, etc.). We rename to the pack's expected file name.
PRODUCED=""
while IFS= read -r -d '' f; do
    PRODUCED="$f"; break
done < <(find . -maxdepth 4 -type f \( -name 'libMonoPosixHelper*.so*' -o -name 'libMono.Unix.so*' -o -name 'libMono-Posix*.so*' \) -print0)
[[ -n "$PRODUCED" ]] || { echo "!! produced .so not found"; find . -name '*.so*' -type f; exit 4; }

cp "$PRODUCED" "$OUT_DIR/libMono.Unix.so"
strip --strip-unneeded "$OUT_DIR/libMono.Unix.so"
file "$OUT_DIR/libMono.Unix.so"
echo ">> wrote $OUT_DIR/libMono.Unix.so"
