#!/usr/bin/env bash
# package-release.sh
#
# Assembles the shim binaries into a release tarball matching the layout
# documented in STATUS.md and emits SHA256SUMS alongside it.
#
#   dist/shims-linux-arm64-<PACK_VERSION>.tar.gz
#     ./aapt2
#     ./zipalign
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

# Required for v1: the two .so libs. aapt2 is optional — if present we ship it,
# if not the tarball is still useful (the .so libs unblock most of the build;
# aapt2 alone can be supplied separately via PATH). See docs/aapt2.md.
REQUIRED=(
    "$IN_DIR/libMono.Unix.so"
    "$IN_DIR/libZipSharpNative-${SUFFIX}.so"
)
for f in "${REQUIRED[@]}"; do
    [[ -f "$f" ]] || { echo "!! missing artifact: $f"; exit 2; }
done

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp "${REQUIRED[@]}" "$STAGE/"

CONTENTS=(libMono.Unix.so "libZipSharpNative-${SUFFIX}.so")
if [[ -f "$IN_DIR/aapt2" ]]; then
    cp "$IN_DIR/aapt2" "$STAGE/"
    chmod +x "$STAGE/aapt2"
    CONTENTS+=(aapt2)
    echo ">> including aapt2"
else
    echo ">> aapt2 not present in $IN_DIR — packaging without it (v1 partial)"
fi

if [[ -f "$IN_DIR/zipalign" ]]; then
    cp "$IN_DIR/zipalign" "$STAGE/"
    chmod +x "$STAGE/zipalign"
    CONTENTS+=(zipalign)
    echo ">> including zipalign"
else
    echo ">> zipalign not present in $IN_DIR — packaging without it"
fi

(cd "$STAGE" && sha256sum "${CONTENTS[@]}" > SHA256SUMS)

TARBALL="$OUT_DIR/shims-linux-arm64-${PACK_VERSION}.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "${CONTENTS[@]}" SHA256SUMS

(cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")

echo ">> wrote $TARBALL"
echo ">> wrote $TARBALL.sha256"
ls -la "$OUT_DIR"
