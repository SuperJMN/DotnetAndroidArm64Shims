#!/usr/bin/env bash
# nm-diff the freshly built libZipSharpNative against the upstream binary.
# Same logic as shims/libMono.Unix/verify-symbols.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

ARTIFACT="${ARTIFACT:-$REPO_ROOT/out/linux-arm64/libZipSharpNative-${LIBZIPSHARP_SONAME_SUFFIX:-3-3}.so}"
REFERENCE="${REFERENCE:-$REPO_ROOT/out/arm64-reference/$PACK_VERSION/libZipSharpNative.syms}"

[[ -f "$ARTIFACT" ]]  || { echo "missing artifact: $ARTIFACT"; exit 2; }
[[ -f "$REFERENCE" ]] || { echo "missing reference: $REFERENCE (run scripts/extract-reference-symbols.sh)"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
nm -D --defined-only "$ARTIFACT" | awk '{print $3}' | sort -u > "$TMP/built.syms"

FILTER='^(_init|_fini|__bss_start|_edata|_end)$'
comm -23 \
    <(grep -Ev "$FILTER" "$REFERENCE" | sort -u) \
    <(grep -Ev "$FILTER" "$TMP/built.syms" | sort -u) \
    > "$TMP/missing.syms"

if [[ -s "$TMP/missing.syms" ]]; then
    echo "!! symbols missing from arm64 build (P/Invoke would fail):"
    sed 's/^/   /' "$TMP/missing.syms"
    exit 1
fi

TOTAL=$(wc -l < "$TMP/built.syms")
echo "OK  libZipSharpNative: all upstream symbols present ($TOTAL exported)."
