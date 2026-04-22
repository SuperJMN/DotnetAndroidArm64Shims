#!/usr/bin/env bash
# extract-reference-symbols.sh
#
# Downloads Microsoft.Android.Sdk.Linux/<PACK_VERSION> from NuGet, unpacks it,
# and emits the reference fingerprints that the verify-*.sh scripts compare
# against in CI:
#
#   out/arm64-reference/<PACK_VERSION>/
#     libMono.Unix.syms          # sorted symbol list (nm -D --defined-only)
#     libZipSharpNative.syms
#     aapt2.version              # exact `aapt2 version` output
#     versions.env               # extracted version strings (sanity)
#
# Usage:
#   PACK_VERSION=36.1.53 ./scripts/extract-reference-symbols.sh
#
# Runs on any glibc Linux host (x86_64 or arm64). aapt2 is x86_64 ELF so the
# `aapt2 version` step is skipped on arm64 hosts and the value is read from
# pack-versions/<PACK_VERSION>.env instead.

set -euo pipefail

PACK_VERSION="${PACK_VERSION:?PACK_VERSION must be set, e.g. PACK_VERSION=36.1.53}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/reference/$PACK_VERSION}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/arm64-reference/$PACK_VERSION}"
NUPKG_URL="https://www.nuget.org/api/v2/package/Microsoft.Android.Sdk.Linux/$PACK_VERSION"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [[ ! -f "$WORK_DIR/pack.nupkg" ]]; then
    echo ">> downloading $NUPKG_URL"
    curl -fsSL -o "$WORK_DIR/pack.nupkg" "$NUPKG_URL"
fi

if [[ ! -d "$WORK_DIR/pack" ]]; then
    echo ">> unpacking nupkg"
    unzip -q "$WORK_DIR/pack.nupkg" -d "$WORK_DIR/pack"
fi

PACK="$WORK_DIR/pack"
LIBMONO="$PACK/tools/libMono.Unix.so"
LIBZIPSHARP="$PACK/tools/libZipSharpNative-3-3.so"
AAPT2="$PACK/tools/Linux/aapt2"

for f in "$LIBMONO" "$LIBZIPSHARP" "$AAPT2"; do
    [[ -f "$f" ]] || { echo "missing: $f"; exit 2; }
done

echo ">> extracting symbol lists"
nm -D --defined-only "$LIBMONO"     | awk '{print $3}' | sort -u > "$OUT_DIR/libMono.Unix.syms"
nm -D --defined-only "$LIBZIPSHARP" | awk '{print $3}' | sort -u > "$OUT_DIR/libZipSharpNative.syms"

echo ">> extracting aapt2 version"
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "x86_64" ]]; then
    chmod +x "$AAPT2"
    "$AAPT2" version > "$OUT_DIR/aapt2.version"
else
    # On arm64 we can't execute the x86_64 ELF directly. Trust the pinned env.
    PIN_FILE="$REPO_ROOT/pack-versions/$PACK_VERSION.env"
    if [[ -f "$PIN_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$PIN_FILE"
        echo "$AAPT2_VERSION_STRING" > "$OUT_DIR/aapt2.version"
        echo "   (read from $PIN_FILE: $AAPT2_VERSION_STRING)"
    else
        echo "!! cannot run aapt2 on $HOST_ARCH and no pin file at $PIN_FILE"
        exit 3
    fi
fi

echo ">> writing versions.env"
{
    echo "PACK_VERSION=$PACK_VERSION"
    echo "AAPT2_VERSION_STRING=\"$(cat "$OUT_DIR/aapt2.version")\""
    echo "LIBZIP_VERSION_DETECTED=$(strings "$LIBZIPSHARP" | grep -E '^1\.[0-9]+\.[0-9]+$' | head -1 || echo unknown)"
    echo "LIBMONO_UNIX_SYMBOL_COUNT=$(wc -l < "$OUT_DIR/libMono.Unix.syms")"
    echo "LIBZIPSHARPNATIVE_SYMBOL_COUNT=$(wc -l < "$OUT_DIR/libZipSharpNative.syms")"
} > "$OUT_DIR/versions.env"

echo ">> done. reference data in $OUT_DIR"
cat "$OUT_DIR/versions.env"
