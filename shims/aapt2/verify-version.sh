#!/usr/bin/env bash
# Run `aapt2 version` and assert the output matches the pinned upstream string.
# A mismatch here would trip XA0111 ("Unsupported version of AAPT2") on every
# subsequent .NET Android build, so CI must fail loudly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

ARTIFACT="${ARTIFACT:-$REPO_ROOT/out/linux-arm64/aapt2}"
[[ -x "$ARTIFACT" ]] || { echo "missing or non-executable artifact: $ARTIFACT"; exit 2; }

ACTUAL="$("$ARTIFACT" version 2>&1 | tr -d '\r' | head -1)"
EXPECTED="$AAPT2_VERSION_STRING"

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "!! aapt2 version mismatch — would trip XA0111 in .NET Android builds"
    echo "   expected: $EXPECTED"
    echo "   got:      $ACTUAL"
    exit 1
fi

echo "OK  aapt2 version matches: $ACTUAL"
