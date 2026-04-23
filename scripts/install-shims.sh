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
#   install-shims.sh --manifest-url URL    # override compatibility.json URL
#   install-shims.sh --manifest /path      # use a local compatibility.json (offline)
#   install-shims.sh --dry-run             # print what would happen
#
# Idempotent: re-running with the shim already in place is a no-op (verified
# via SHA256SUMS comparison). Originals are backed up to:
#   <pack>/tools/.x86_64-backup/
#   <pack>/tools/Linux/.x86_64-backup/
#
# Resolution: tries to download a shim release whose tag equals the pack
# version. If none exists, consults compatibility.json (a sha256-anchored
# alias map) to find the release that ships byte-identical replacements
# for that pack's host binaries. This lets a single shim release cover an
# entire 35.0.x or 36.1.x sub-series without per-version rebuilds.
#
# Dependencies on the host: bash, curl, tar, sha256sum, uname.

set -euo pipefail

RELEASE_BASE="${RELEASE_BASE:-https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases/download}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/SuperJMN/DotnetAndroidArm64Shims/main/compatibility.json}"
PACK_ROOT="${PACK_ROOT:-$HOME/.dotnet/packs/Microsoft.Android.Sdk.Linux}"
TARGET_VERSION=""
DRY_RUN=0
MANIFEST_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      TARGET_VERSION="$2"; shift 2 ;;
        --pack-root)    PACK_ROOT="$2"; shift 2 ;;
        --release-base) RELEASE_BASE="$2"; shift 2 ;;
        --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
        --manifest)     MANIFEST_FILE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,28p' "$0"
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

# --- compatibility manifest --------------------------------------------------
# Maps pack versions that have no shim release of their own to the release
# whose tarball shims the same upstream binaries (verified bit-for-bit).
# We try the literal pack version first; only on a miss do we consult the
# manifest. That way a freshly-published shim release at the literal tag
# always wins over a stale alias.
MANIFEST_CACHE=""
load_manifest() {
    [[ -n "$MANIFEST_CACHE" ]] && return 0

    if [[ -n "$MANIFEST_FILE" ]]; then
        [[ -f "$MANIFEST_FILE" ]] \
            || { echo "!!   --manifest path not found: $MANIFEST_FILE"; return 1; }
        MANIFEST_CACHE="$(cat "$MANIFEST_FILE")"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if curl -fsSL --retry 3 -o "$tmp" "$MANIFEST_URL" 2>/dev/null; then
        MANIFEST_CACHE="$(cat "$tmp")"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

resolve_alias() {
    # echoes the release tag that should serve $1, or empty on miss.
    local version="$1"
    load_manifest || return 0

    # Minimal grep-based JSON read: matches "<version>": "<tag>". Robust enough
    # for a flat string→string map and avoids requiring jq on the host.
    # Escape regex metachars in the version (dots, plus, dash, etc).
    local escaped
    # shellcheck disable=SC2016  # single-quoted sed script is intentional; \& is sed backref, not a shell expansion
    escaped="$(printf '%s' "$version" | sed 's/[.[\*^$()+?{|]/\\&/g')"
    printf '%s' "$MANIFEST_CACHE" \
        | grep -oE "\"$escaped\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" \
        | head -1 \
        | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/'
}

# --- per-version overlay -----------------------------------------------------
fetch_release() {
    local tag="$1" workdir="$2"
    local url="$RELEASE_BASE/$tag/shims-linux-arm64-$tag.tar.gz"
    local tarball="$workdir/shims.tar.gz"

    echo ">>   downloading $url"
    if ! curl -fsSL --retry 3 -o "$tarball" "$url"; then
        return 10
    fi

    tar -tzf "$tarball" >/dev/null 2>&1 \
        || { echo "!!   tarball is corrupt"; return 11; }

    tar -C "$workdir" -xzf "$tarball"
    (cd "$workdir" && sha256sum -c SHA256SUMS) \
        || { echo "!!   SHA256SUMS verification failed"; return 12; }
}

# Tries the literal version first; on 404 falls back to compatibility.json
# alias. Echoes the resolved tag on stdout (caller relies on the side-effect
# of populating $workdir).
fetch_release_for_pack() {
    local version="$1" workdir="$2"
    local rc

    if fetch_release "$version" "$workdir"; then
        echo "$version"
        return 0
    fi
    rc=$?
    [[ $rc -eq 10 ]] || return $rc

    local alias_tag
    alias_tag="$(resolve_alias "$version")"
    if [[ -z "$alias_tag" ]]; then
        echo "!!   no shim release for pack version $version" >&2
        echo "     and no alias in compatibility.json." >&2
        echo "     File an issue at https://github.com/SuperJMN/DotnetAndroidArm64Shims/issues" >&2
        echo "     so we can sha256-fingerprint the new pack and either alias or rebuild." >&2
        return 10
    fi

    echo ">>   no release at literal tag $version; manifest aliases to $alias_tag" >&2
    if fetch_release "$alias_tag" "$workdir"; then
        echo "$alias_tag"
        return 0
    fi
    echo "!!   alias $alias_tag for $version is published in manifest but the release is unavailable" >&2
    return 10
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

    if ! resolved_tag="$(fetch_release_for_pack "$v" "$workdir")"; then
        echo "!! skipping $v"
        rm -rf "$workdir"
        continue
    fi
    [[ "$resolved_tag" == "$v" ]] \
        || echo ">>   serving $v from release $resolved_tag (compatibility manifest)"

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
