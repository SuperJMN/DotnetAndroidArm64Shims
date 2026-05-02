#!/usr/bin/env bash
# Fetch a linux-arm64 zipalign binary.
#
# Source: lzhiyong/android-sdk-tools publishes static aarch64 Android SDK
# build-tools. The zipalign binary is an arm64-v8a static-bionic executable,
# which runs directly on Linux/aarch64 hosts.
#
# Output:
#   out/linux-arm64/zipalign

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/zipalign}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"

ZIPALIGN_SOURCE_VERSION="${ZIPALIGN_SOURCE_VERSION:-35.0.2}"
ZIPALIGN_SOURCE_URL="${ZIPALIGN_SOURCE_URL:-https://github.com/lzhiyong/android-sdk-tools/releases/download/$ZIPALIGN_SOURCE_VERSION/android-sdk-tools-static-aarch64.zip}"
ZIPALIGN_SOURCE_SHA256="${ZIPALIGN_SOURCE_SHA256:-db1cea2c4454d5f9c5a802646b2d1cf560b4ee7badbe23e51ab8e1881bb50fc2}"
ZIPALIGN_BINARY_SHA256="${ZIPALIGN_BINARY_SHA256:-3fd87420929ca4c590748106f5a9b7cb81324341c1e90d4fea3c09c941c72618}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

archive="$WORK_DIR/android-sdk-tools-static-aarch64-$ZIPALIGN_SOURCE_VERSION.zip"
if [[ ! -f "$archive" ]]; then
    echo ">> downloading $ZIPALIGN_SOURCE_URL"
    curl -fsSL --retry 3 -o "$archive" "$ZIPALIGN_SOURCE_URL"
else
    echo ">> reusing $archive"
fi

printf '%s  %s\n' "$ZIPALIGN_SOURCE_SHA256" "$archive" | sha256sum -c -

rm -rf "$WORK_DIR/extract"
mkdir -p "$WORK_DIR/extract"
unzip -q "$archive" build-tools/zipalign -d "$WORK_DIR/extract"

produced="$WORK_DIR/extract/build-tools/zipalign"
[[ -f "$produced" ]] || { echo "!! expected $produced"; exit 2; }
printf '%s  %s\n' "$ZIPALIGN_BINARY_SHA256" "$produced" | sha256sum -c -

install -m 0755 "$produced" "$OUT_DIR/zipalign"
file "$OUT_DIR/zipalign"
echo ">> wrote $OUT_DIR/zipalign ($(du -h "$OUT_DIR/zipalign" | awk '{print $1}'))"
