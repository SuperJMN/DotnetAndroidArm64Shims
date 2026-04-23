#!/usr/bin/env bash
# Build aapt2 for linux-arm64 (vanilla glibc).
#
# Strategy: cross-compile via the Android NDK (host = linux-x86_64) targeting
# arm64-v8a, statically linked against bionic. The resulting binary runs
# transparently on any aarch64 Linux kernel — verified on Raspberry Pi OS
# bullseye — because the syscall ABI between arm64 bionic-static and arm64
# Linux is compatible. See docs/aapt2.md (Option F) for the full rationale.
#
# Builds on top of ReVanced/aapt2's CMake recipe (which already wires up the
# AOSP submodule jungle to compile under CMake instead of Soong). We patch
# two source files so the produced binary's `aapt2 version` output matches
# pack-versions/<v>.env::AAPT2_VERSION_STRING byte-for-byte — a mismatch
# trips XA0111 in every subsequent .NET Android build.
#
# Output:
#   out/linux-arm64/aapt2   (statically-linked bionic ELF, stripped)
#
# Required environment:
#   ANDROID_NDK     path to NDK r27c (or compatible). If unset, we download
#                   r27c into build/ndk/ — convenient for CI.
#   PROTOC_PATH     path to protoc 21.12 binary. If unset, we download.
#
# Required apt packages (host = linux-x86_64): see apt-deps.txt.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACK_VERSION="${PACK_VERSION:-36.1.53}"
# shellcheck disable=SC1090
source "$REPO_ROOT/pack-versions/$PACK_VERSION.env"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/aapt2}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/linux-arm64}"
SRC_REPO="https://github.com/ReVanced/aapt2"
REVANCED_REF="${REVANCED_REF:-v1.1.0}"
NDK_VERSION="${NDK_VERSION:-r27c}"
PROTOC_VERSION="${PROTOC_VERSION:-21.12}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

# --- 1. Source ---------------------------------------------------------------
SRC_DIR="$WORK_DIR/src"
if [[ ! -d "$SRC_DIR/.git" ]]; then
    echo ">> cloning $SRC_REPO @ $REVANCED_REF (with submodules)"
    git clone --recurse-submodules --shallow-submodules --depth 1 \
        --branch "$REVANCED_REF" "$SRC_REPO" "$SRC_DIR"
else
    echo ">> reusing existing checkout at $SRC_DIR"
fi

# --- 2. Force-stamp version string -------------------------------------------
# aapt2's `version` output is "Android Asset Packaging Tool (aapt) <X>.<Y>-<id>"
# where:
#   <X>.<Y>  comes from sMajorVersion/sMinorVersion in base/tools/aapt2/util/Util.cpp
#   <id>     comes from soong_build_number, a global char buffer that Soong
#            patches at link time (see soong/cc/libbuildversion/libbuildversion.cpp).
#
# ReVanced's CMake doesn't run that link-time patcher, so unpatched their build
# emits "(aapt) 2.19-" (empty id). We sed both files to force the exact string
# from pack-versions/<v>.env.
UTIL_CPP="$SRC_DIR/submodules/base/tools/aapt2/util/Util.cpp"
LIBBV_CPP="$SRC_DIR/submodules/soong/cc/libbuildversion/libbuildversion.cpp"
[[ -f "$UTIL_CPP"  ]] || { echo "!! expected $UTIL_CPP — submodules not initialised?"; exit 3; }
[[ -f "$LIBBV_CPP" ]] || { echo "!! expected $LIBBV_CPP — submodules not initialised?"; exit 3; }

# Parse "Android Asset Packaging Tool (aapt) MAJOR.MINOR-BUILDID".
re='Android Asset Packaging Tool \(aapt\) ([0-9]+)\.([0-9]+)-(.+)$'
if [[ ! "$AAPT2_VERSION_STRING" =~ $re ]]; then
    echo "!! cannot parse AAPT2_VERSION_STRING='$AAPT2_VERSION_STRING'"
    exit 4
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
BUILDID="${BASH_REMATCH[3]}"
echo ">> stamping aapt version → ${MAJOR}.${MINOR}-${BUILDID}"

# Idempotent sed: only rewrite if the canonical upstream literal is still there.
sed -i -E "s|sMajorVersion = \"[0-9]+\";|sMajorVersion = \"${MAJOR}\";|" "$UTIL_CPP"
sed -i -E "s|sMinorVersion = \"[0-9]+\";|sMinorVersion = \"${MINOR}\";|" "$UTIL_CPP"
sed -i    "s|#define PLACEHOLDER \"SOONG BUILD NUMBER PLACEHOLDER\"|#define PLACEHOLDER \"${BUILDID}\"|" "$LIBBV_CPP"

# Sanity-check the patches landed.
grep -q "sMajorVersion = \"${MAJOR}\";" "$UTIL_CPP" \
    || { echo "!! sMajorVersion patch did not apply — upstream may have changed Util.cpp"; exit 5; }
grep -q "sMinorVersion = \"${MINOR}\";" "$UTIL_CPP" \
    || { echo "!! sMinorVersion patch did not apply — upstream may have changed Util.cpp"; exit 5; }
grep -q "PLACEHOLDER \"${BUILDID}\""    "$LIBBV_CPP" \
    || { echo "!! soong_build_number patch did not apply — upstream may have moved the define"; exit 5; }

# --- 3. Apply ReVanced's local patches (idempotent) -------------------------
cd "$SRC_DIR"
if [[ ! -f ".our-patch-applied" ]]; then
    echo ">> running ReVanced patch.sh"
    bash patch.sh
    touch ".our-patch-applied"
fi

# --- 4. Toolchain ------------------------------------------------------------
if [[ -z "${ANDROID_NDK:-}" ]]; then
    NDK_ROOT="$WORK_DIR/ndk/android-ndk-${NDK_VERSION}"
    if [[ ! -d "$NDK_ROOT" ]]; then
        mkdir -p "$WORK_DIR/ndk"
        cd "$WORK_DIR/ndk"
        echo ">> downloading Android NDK ${NDK_VERSION} (linux-x86_64)"
        curl -fsSL -o "ndk.zip" \
            "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
        unzip -q "ndk.zip" && rm "ndk.zip"
        cd "$SRC_DIR"
    fi
    export ANDROID_NDK="$NDK_ROOT"
fi
echo ">> using ANDROID_NDK=$ANDROID_NDK"

if [[ -z "${PROTOC_PATH:-}" ]]; then
    PROTOC_DIR="$WORK_DIR/protoc"
    if [[ ! -x "$PROTOC_DIR/bin/protoc" ]]; then
        mkdir -p "$PROTOC_DIR"
        cd "$PROTOC_DIR"
        echo ">> downloading protoc ${PROTOC_VERSION} (linux-x86_64)"
        curl -fsSL -o "protoc.zip" \
            "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip"
        unzip -q "protoc.zip" && rm "protoc.zip"
        chmod +x bin/protoc
        cd "$SRC_DIR"
    fi
    export PROTOC_PATH="$PROTOC_DIR/bin/protoc"
    export PATH="$PROTOC_DIR/bin:$PATH"
fi
echo ">> using PROTOC_PATH=$PROTOC_PATH"

# --- 5. Build ----------------------------------------------------------------
cd "$SRC_DIR"
# ReVanced's build.sh wraps cmake+ninja. It picks up ANDROID_NDK from the env.
# It produces build/bin/aapt2-arm64-v8a (statically linked, stripped).
echo ">> running ReVanced build.sh arm64-v8a"
bash build.sh arm64-v8a

PRODUCED="$SRC_DIR/build/bin/aapt2-arm64-v8a"
[[ -x "$PRODUCED" ]] || { echo "!! expected $PRODUCED"; ls -la "$SRC_DIR/build/bin/" 2>/dev/null || true; exit 6; }

cp "$PRODUCED" "$OUT_DIR/aapt2"
chmod +x "$OUT_DIR/aapt2"
file "$OUT_DIR/aapt2"
echo ">> wrote $OUT_DIR/aapt2 ($(du -h "$OUT_DIR/aapt2" | awk '{print $1}'))"

echo ">> aapt2 version (sanity check before verify-version.sh):"
"$OUT_DIR/aapt2" version
