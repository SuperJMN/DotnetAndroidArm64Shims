#!/usr/bin/env bash
# Compare exported symbols of the freshly built libMono.Unix.so against the
# upstream x86_64 binary. The .NET MSBuild tasks P/Invoke into specific entry
# points; any missing one becomes EntryPointNotFoundException at runtime, so
# CI must fail loudly here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"

ARTIFACT="${ARTIFACT:-$REPO_ROOT/out/linux-arm64/libMono.Unix.so}"
REFERENCE="${REFERENCE:-$REPO_ROOT/out/arm64-reference/$PACK_VERSION/libMono.Unix.syms}"

[[ -f "$ARTIFACT" ]]  || { echo "missing artifact: $ARTIFACT"; exit 2; }
[[ -f "$REFERENCE" ]] || { echo "missing reference: $REFERENCE (run scripts/extract-reference-symbols.sh)"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
nm -D --defined-only "$ARTIFACT" | awk '{print $3}' | sort -u > "$TMP/built.syms"

# Symbols present in the upstream x86_64 binary that our build is missing.
# These break P/Invoke. Auto-injected glibc / linker symbols (_init, _fini,
# __bss_start, _edata, _end) can drift harmlessly between toolchains, so we
# filter them out of the diff.
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

# Extra symbols on our side are fine but log them so reviewers can sanity-check.
comm -13 \
    <(grep -Ev "$FILTER" "$REFERENCE" | sort -u) \
    <(grep -Ev "$FILTER" "$TMP/built.syms" | sort -u) \
    > "$TMP/extra.syms" || true

EXTRA_COUNT=$(wc -l < "$TMP/extra.syms")
TOTAL=$(wc -l < "$TMP/built.syms")
echo "OK  libMono.Unix.so: all upstream symbols present ($TOTAL exported, $EXTRA_COUNT extras)."
