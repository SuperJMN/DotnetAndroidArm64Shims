#!/usr/bin/env bash
# Build aapt2 for linux-arm64 (vanilla glibc).
#
# Strategy: clone lzhiyong/android-sdk-tools (a curated CMake build of AOSP's
# aapt2 with all transitive deps vendored as submodules), run their source-prep
# script to apply local patches, then invoke CMake **without** the NDK toolchain
# file. That makes CMake fall back to the host compiler — gcc/clang on glibc —
# producing a native linux-arm64 ELF instead of an Android bionic one.
#
# Output:
#   out/linux-arm64/aapt2   (stripped)
#
# Required apt packages: see apt-deps.txt.
#
# Pinning: aapt2 emits "Android Asset Packaging Tool (aapt) 2.20-<aosp-build-id>".
# The .NET MSBuild target Aapt2VersionRegex caches this exact string in
# obj/aapt2.version and uses string equality to invalidate compiled .flata.
# A mismatch trips XA0111 at every subsequent build. Our verify-version.sh
# diffs against pack-versions/<v>.env::AAPT2_VERSION_STRING.
#
# If lzhiyong's tip doesn't match the AOSP build id we need for this pack,
# bump LZHIYONG_REF below to a commit that does (their submodule heads track
# AOSP tags).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/aapt2}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/lzhiyong/android-sdk-tools"
LZHIYONG_REF="${LZHIYONG_REF:-master}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [[ ! -d "$WORK_DIR/src/.git" ]]; then
    echo ">> cloning $SRC_REPO @ $LZHIYONG_REF"
    git clone --branch "$LZHIYONG_REF" "$SRC_REPO" "$WORK_DIR/src"
else
    echo ">> reusing existing checkout at $WORK_DIR/src"
    git -C "$WORK_DIR/src" fetch origin "$LZHIYONG_REF"
    git -C "$WORK_DIR/src" checkout "$LZHIYONG_REF"
fi

cd "$WORK_DIR/src"

# Apply any local patches BEFORE running get_source.py so their patches stack
# on top of ours cleanly.
if [[ -d "$REPO_ROOT/shims/aapt2/patches" ]]; then
    shopt -s nullglob
    for p in "$REPO_ROOT/shims/aapt2/patches/"*.patch; do
        echo ">> applying $p"
        git apply --whitespace=nowarn "$p"
    done
    shopt -u nullglob
fi

# get_source.py clones every AOSP submodule lzhiyong's CMake recipe needs
# (frameworks/base, system/core, libbase, libpng, expat, protobuf, etc.) and
# runs a small set of sed patches that make the AOSP source compile under
# CMake instead of Soong. Only run if the src/ tree doesn't already have them.
if [[ ! -d "src/base" ]]; then
    echo ">> running get_source.py (downloads AOSP submodules)"
    python3 get_source.py
fi

# Stamp the aapt2 version string into platform_tools_version.h so the produced
# binary reports exactly what the pack expects. lzhiyong defaults to a fixed
# tools version, but the actual `aapt2 version` string is built from
# Tools.h::sBuildId, which Soong patches at build time. We force-override here.
PT_VERSION_HDR="src/soong/cc/libbuildversion/include/platform_tools_version.h"
if [[ -f "$PT_VERSION_HDR" ]]; then
    AAPT2_BUILD_ID="${AAPT2_AOSP_BUILD_ID:-13193326}"
    echo ">> stamping aapt2 build id $AAPT2_BUILD_ID into $PT_VERSION_HDR"
    cat > "$PT_VERSION_HDR" <<EOF
#pragma once
// Overwritten by shims/aapt2/build.sh — pin to upstream pack $PACK_VERSION.
#define PLATFORM_TOOLS_VERSION "$AAPT2_BUILD_ID"
EOF
fi

BUILD_DIR="$WORK_DIR/build"
mkdir -p "$BUILD_DIR"

# Use system protoc if available — bundled abseil/protobuf is heavy to build
# and the version constraint is "no newer than 3.21.12" (see lzhiyong's
# CMakeLists.txt). Ubuntu 22.04 ships 3.12.4 which is fine.
PROTOC_FLAG=()
if command -v protoc >/dev/null 2>&1; then
    PROTOC_VER="$(protoc --version | awk '{print $2}')"
    echo ">> using system protoc $PROTOC_VER"
    PROTOC_FLAG=("-DPROTOC_PATH=$(command -v protoc)")
fi

echo ">> configuring (no NDK toolchain — host glibc build)"
cmake -GNinja -S "$WORK_DIR/src" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -Dprotobuf_BUILD_TESTS=OFF \
    -DABSL_PROPAGATE_CXX_STD=ON \
    "${PROTOC_FLAG[@]}"

echo ">> building aapt2"
ninja -C "$BUILD_DIR" -j"$(nproc)" aapt2

PRODUCED="$(find "$BUILD_DIR" -maxdepth 4 -type f -name aapt2 -executable | head -1)"
[[ -n "$PRODUCED" ]] || { echo "!! aapt2 binary not produced"; find "$BUILD_DIR" -name aapt2; exit 4; }

cp "$PRODUCED" "$OUT_DIR/aapt2"
chmod +x "$OUT_DIR/aapt2"
strip --strip-unneeded "$OUT_DIR/aapt2"
file "$OUT_DIR/aapt2"
echo ">> wrote $OUT_DIR/aapt2"
