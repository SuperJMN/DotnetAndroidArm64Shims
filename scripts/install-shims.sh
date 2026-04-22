#!/usr/bin/env bash
# install-shims.sh
#
# Overlays linux-arm64 shim binaries onto an installed Microsoft.Android.Sdk.Linux
# pack so that `dotnet publish -f net*-android` can run on aarch64 hosts.
#
# Usage:
#   install-shims.sh                       # detect installed pack(s), shim all
#   install-shims.sh --version 36.1.53     # only this pack version
#   install-shims.sh --pack-root /path     # override pack search root
#   install-shims.sh --release-base URL    # override github release base URL
#   install-shims.sh --dry-run             # print what would happen
#
# Idempotent: re-running with the shim already in place is a no-op (verified
# via SHA256SUMS comparison). Originals are backed up to:
#   <pack>/tools/.x86_64-backup/
#   <pack>/tools/Linux/.x86_64-backup/
#
# Dependencies on the host: bash, curl, tar, sha256sum, uname.

set -euo pipefail

RELEASE_BASE="${RELEASE_BASE:-https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases/download}"
PACK_ROOT="${PACK_ROOT:-$HOME/.dotnet/packs/Microsoft.Android.Sdk.Linux}"
TARGET_VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      TARGET_VERSION="$2"; shift 2 ;;
        --pack-root)    PACK_ROOT="$2"; shift 2 ;;
        --release-base) RELEASE_BASE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "!! unknown arg: $1"; exit 2 ;;
    esac
done

# --- host check --------------------------------------------------------------
HOST_ARCH="$(uname -m)"
HOST_OS="$(uname -s)"
if [[ "$HOST_OS" != "Linux" || "$HOST_ARCH" != "aarch64" ]]; then
    echo "!! this bootstrap targets linux-aarch64 hosts. Detected: $HOST_OS/$HOST_ARCH"
    exit 3
fi

# --- find pack versions ------------------------------------------------------
if [[ ! -d "$PACK_ROOT" ]]; then
    echo "!! pack root not found: $PACK_ROOT"
    echo "   install the workload first:  dotnet workload install android"
    exit 4
fi

VERSIONS=()
if [[ -n "$TARGET_VERSION" ]]; then
    [[ -d "$PACK_ROOT/$TARGET_VERSION" ]] \
        || { echo "!! requested version $TARGET_VERSION not installed under $PACK_ROOT"; exit 5; }
    VERSIONS=("$TARGET_VERSION")
else
    while IFS= read -r v; do
        VERSIONS+=("$v")
    done < <(find "$PACK_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V)
    [[ ${#VERSIONS[@]} -gt 0 ]] || { echo "!! no installed pack versions under $PACK_ROOT"; exit 5; }
fi

echo ">> host: $HOST_OS/$HOST_ARCH"
echo ">> pack root: $PACK_ROOT"
echo ">> versions to shim: ${VERSIONS[*]}"

# --- per-version overlay -----------------------------------------------------
fetch_release() {
    local version="$1" workdir="$2"
    local url="$RELEASE_BASE/$version/shims-linux-arm64-$version.tar.gz"
    local tarball="$workdir/shims.tar.gz"

    echo ">>   downloading $url"
    if ! curl -fsSL --retry 3 -o "$tarball" "$url"; then
        echo "!!   no shim release published for pack version $version"
        echo "     check https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases"
        return 10
    fi

    tar -tzf "$tarball" >/dev/null 2>&1 \
        || { echo "!!   tarball is corrupt"; return 11; }

    tar -C "$workdir" -xzf "$tarball"
    (cd "$workdir" && sha256sum -c SHA256SUMS) \
        || { echo "!!   SHA256SUMS verification failed"; return 12; }
}

overlay_one() {
    local src="$1" dst="$2" backup_dir="$3"
    [[ -f "$src" ]] || { echo "!!     missing in tarball: $(basename "$src")"; return 20; }

    if [[ -f "$dst" ]]; then
        # Idempotency: if the installed file already matches the shim, skip.
        if cmp -s "$src" "$dst"; then
            echo "   = $(basename "$dst") already shimmed (sha matches), skipping"
            return 0
        fi
        # First time: back up the original x86_64 binary.
        mkdir -p "$backup_dir"
        if [[ ! -f "$backup_dir/$(basename "$dst")" ]]; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "   [dry] backup $dst -> $backup_dir/"
            else
                cp -p "$dst" "$backup_dir/$(basename "$dst")"
                echo "   + backed up original to $backup_dir/$(basename "$dst")"
            fi
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "   [dry] install $src -> $dst"
    else
        install -m 0755 "$src" "$dst"
        echo "   * installed $dst"
    fi
}

for v in "${VERSIONS[@]}"; do
    pack="$PACK_ROOT/$v"
    echo ""
    echo ">> shimming $pack"

    workdir="$(mktemp -d)"

    if ! fetch_release "$v" "$workdir"; then
        echo "!! skipping $v"
        rm -rf "$workdir"
        continue
    fi

    # Determine libZipSharpNative suffix from what the tarball contains —
    # avoids hardcoding -3-3 and survives future libzip API bumps.
    libzipsharp="$(find "$workdir" -maxdepth 1 -name 'libZipSharpNative-*.so' | head -1)"
    [[ -n "$libzipsharp" ]] || { echo "!! no libZipSharpNative-*.so in tarball"; rm -rf "$workdir"; continue; }

    overlay_one "$workdir/libMono.Unix.so" \
                "$pack/tools/libMono.Unix.so" \
                "$pack/tools/.x86_64-backup"

    overlay_one "$libzipsharp" \
                "$pack/tools/$(basename "$libzipsharp")" \
                "$pack/tools/.x86_64-backup"

    if [[ -f "$workdir/aapt2" ]]; then
        overlay_one "$workdir/aapt2" \
                    "$pack/tools/Linux/aapt2" \
                    "$pack/tools/Linux/.x86_64-backup"
    else
        echo "   ! aapt2 not present in this release tarball — skipping"
        echo "     (the .so libs are installed; aapt2 must be provided separately"
        echo "      until the v1.x release that includes it ships)"
    fi

    rm -rf "$workdir"
done

echo ""
echo "OK  shim install complete."
