#!/usr/bin/env bash
# package-release.sh
#
# Assembles the three shim binaries into a release tarball matching the layout
# documented in STATUS.md and emits SHA256SUMS alongside it.
#
#   dist/shims-linux-arm64-<PACK_VERSION>.tar.gz
#     ./aapt2
#     ./libMono.Unix.so
#     ./libZipSharpNative-<suffix>.so
#     ./SHA256SUMS
#
# Inputs come from out/linux-arm64/ (artifacts produced by shims/*/build.sh,
# or downloaded from the matrix CI artifacts in the release workflow).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK_VERSION="${PACK_VERSION:?PACK_VERSION must be set, e.g. PACK_VERSION=36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

IN_DIR="${IN_DIR:-$REPO_ROOT/out/linux-arm64}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
SUFFIX="${LIBZIPSHARP_SONAME_SUFFIX:-3-3}"

mkdir -p "$OUT_DIR"

REQUIRED=(
    "$IN_DIR/aapt2"
    "$IN_DIR/libMono.Unix.so"
    "$IN_DIR/libZipSharpNative-${SUFFIX}.so"
)
for f in "${REQUIRED[@]}"; do
    [[ -f "$f" ]] || { echo "!! missing artifact: $f"; exit 2; }
done

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp "${REQUIRED[@]}" "$STAGE/"
chmod +x "$STAGE/aapt2"

(cd "$STAGE" && sha256sum aapt2 libMono.Unix.so "libZipSharpNative-${SUFFIX}.so" > SHA256SUMS)

TARBALL="$OUT_DIR/shims-linux-arm64-${PACK_VERSION}.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" aapt2 libMono.Unix.so "libZipSharpNative-${SUFFIX}.so" SHA256SUMS

(cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")

echo ">> wrote $TARBALL"
echo ">> wrote $TARBALL.sha256"
ls -la "$OUT_DIR"
