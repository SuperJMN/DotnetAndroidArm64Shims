#!/usr/bin/env bash
# Basic functional smoke test for the linux-arm64 zipalign shim.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
ZIPALIGN="${ZIPALIGN:-$OUT_DIR/zipalign}"

[[ -x "$ZIPALIGN" ]] || { echo "!! zipalign not executable: $ZIPALIGN"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'hello zipalign\n' > "$tmp/file.txt"
(cd "$tmp" && zip -q sample.zip file.txt)

"$ZIPALIGN" -f -p 4 "$tmp/sample.zip" "$tmp/aligned.zip"
"$ZIPALIGN" -c -p 4 "$tmp/aligned.zip"

echo "OK zipalign smoke test passed"
