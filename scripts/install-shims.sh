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
#   install-shims.sh --android-sdk-root /path
#                                          # override Android SDK root for
#                                          #   build-tools/zipalign overlay
#   install-shims.sh --release-base URL    # override github release base URL
#   install-shims.sh --manifest-url URL    # override compatibility.json URL
#   install-shims.sh --manifest /path      # use a local compatibility.json (offline)
#   install-shims.sh --skip-binutils       # skip the AOT toolchain overlay
#   install-shims.sh --skip-build-tools    # skip Android SDK build-tools
#                                          #   zipalign overlay
#   install-shims.sh --llvm-major N        # pin host LLVM major (default: auto-detect)
#   install-shims.sh --llvm-root /path     # use portable LLVM at /path/bin (skips
#                                          #   /usr/lib/llvm-* probing). Also
#                                          #   honored via $LLVM_ROOT env var.
#   install-shims.sh --dry-run             # print what would happen
#
# Idempotent: re-running with the shim already in place is a no-op (verified
# via SHA256SUMS comparison for files, and readlink target match for binutils
# symlinks). Originals are backed up to:
#   <pack>/tools/.x86_64-backup/
#   <pack>/tools/Linux/.x86_64-backup/
#   <pack>/tools/Linux/binutils/.x86_64-backup/
#   <android-sdk>/build-tools/<version>/.x86_64-backup/
#
# Resolution: tries to download a shim release whose tag equals the pack
# version. If none exists, consults compatibility.json (a sha256-anchored
# alias map) to find the release that ships byte-identical replacements
# for that pack's host binaries. This lets a single shim release cover an
# entire 35.0.x or 36.1.x sub-series without per-version rebuilds.
#
# Phase 6 (binutils / AOT): the 6 entries in tools/Linux/binutils/bin/
# (as, ld, llc, llvm-mc, llvm-objcopy, llvm-strip) are NOT bundled in the
# release tarball — they are symlinked at install time to host LLVM/binutils.
# Mapping is read from compatibility.json::binutils. Requires LLVM >= 15
# installed on the host (apt one-liner printed if missing). Skip with
# --skip-binutils if you're not doing AOT publishes.
#
# Dependencies on the host: bash, curl, tar, sha256sum, uname.

set -euo pipefail

RELEASE_BASE="${RELEASE_BASE:-https://github.com/SuperJMN/DotnetAndroidArm64Shims/releases/download}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/SuperJMN/DotnetAndroidArm64Shims/main/compatibility.json}"
PACK_ROOT="${PACK_ROOT:-$HOME/.dotnet/packs/Microsoft.Android.Sdk.Linux}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/.android-sdk}}"
TARGET_VERSION=""
DRY_RUN=0
MANIFEST_FILE=""
SKIP_BINUTILS=0
SKIP_BUILD_TOOLS=0
LLVM_MAJOR_OVERRIDE=""
LLVM_ROOT="${LLVM_ROOT:-}"
# Track final per-pack outcome so we exit with a sensible status code.
ANY_BINUTILS_FAILED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        TARGET_VERSION="$2"; shift 2 ;;
        --pack-root)      PACK_ROOT="$2"; shift 2 ;;
        --android-sdk-root) ANDROID_SDK_ROOT="$2"; shift 2 ;;
        --release-base)   RELEASE_BASE="$2"; shift 2 ;;
        --manifest-url)   MANIFEST_URL="$2"; shift 2 ;;
        --manifest)       MANIFEST_FILE="$2"; shift 2 ;;
        --skip-binutils|--no-binutils) SKIP_BINUTILS=1; shift ;;
        --skip-build-tools|--skip-zipalign) SKIP_BUILD_TOOLS=1; shift ;;
        --llvm-major)     LLVM_MAJOR_OVERRIDE="$2"; shift 2 ;;
        --llvm-root)      LLVM_ROOT="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,38p' "$0"
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
if [[ "$SKIP_BUILD_TOOLS" -eq 0 ]]; then
    echo ">> Android SDK root: $ANDROID_SDK_ROOT"
fi
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

    echo ">>   downloading $url" >&2
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

# --- binutils overlay (Phase 6: AOT toolchain) -------------------------------
#
# Unlike aapt2 / .so shims, binutils is NOT bundled in the release tarball.
# We symlink the 6 pack binaries to host LLVM/binutils. Mapping comes from
# compatibility.json::binutils.mapping; LLVM major is auto-detected from
# /usr/lib/llvm-{19..15}/bin/llc (override with --llvm-major).
#
# This keeps the tarball tiny (the bundled alternative would be ~50 MB
# compressed for arm64 LLVM 18 .so files alone) at the cost of one apt
# prereq on the host. The recipe is documented in docs/llvm-toolchain.md.

BINUTILS_BINARIES=(as ld llc llvm-mc llvm-objcopy llvm-strip)
BINUTILS_PACK_DIR_REL="tools/Linux/binutils/bin"
BINUTILS_BACKUP_DIR_REL="tools/Linux/binutils/.x86_64-backup"

# Defaults used if compatibility.json can't be loaded (offline + no --manifest).
# Kept in sync with compatibility.json::binutils as a safety net.
DEFAULT_LLVM_MAJORS=(19 18 17 16 15)
declare -A DEFAULT_BINUTILS_MAP=(
    [as]="/usr/bin/as"
    [ld]="/usr/lib/llvm-{llvm}/bin/ld.lld"
    [llc]="/usr/lib/llvm-{llvm}/bin/llc"
    [llvm-mc]="/usr/lib/llvm-{llvm}/bin/llvm-mc"
    [llvm-objcopy]="/usr/lib/llvm-{llvm}/bin/llvm-objcopy"
    [llvm-strip]="/usr/lib/llvm-{llvm}/bin/llvm-strip"
)

# Read array values from compatibility.json::binutils. Falls back to the
# DEFAULT_* tables above when the manifest is unavailable. Echoes one entry
# per line on stdout, in input order. The minimal grep-based extractor
# mirrors resolve_alias() — we deliberately stay jq-free.
manifest_llvm_majors() {
    if load_manifest 2>/dev/null; then
        local arr
        arr="$(printf '%s' "$MANIFEST_CACHE" \
            | tr -d '\n' \
            | grep -oE '"preferred_llvm_majors"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
            | head -1 \
            | grep -oE '[0-9]+' || true)"
        if [[ -n "$arr" ]]; then
            printf '%s\n' "$arr"
            return 0
        fi
    fi
    printf '%s\n' "${DEFAULT_LLVM_MAJORS[@]}"
}

# echoes the host-path template for the given pack-relative path; empty on miss.
manifest_binutils_target() {
    local rel="$1" key="${1##*/}"
    if load_manifest 2>/dev/null; then
        local escaped
        # shellcheck disable=SC2016  # single-quoted sed script: \& is sed backref, not a shell expansion
        escaped="$(printf '%s' "$rel" | sed 's/[.[\*^$()+?{|/]/\\&/g')"
        # Scope the lookup to the binutils.mapping block so we don't accidentally
        # match the same key under per-release `anchors` (which holds sha256s).
        local mapping_block
        mapping_block="$(printf '%s' "$MANIFEST_CACHE" \
            | awk '
                /"binutils"[[:space:]]*:[[:space:]]*\{/ { in_b=1 }
                in_b && /"mapping"[[:space:]]*:[[:space:]]*\{/ { in_m=1; depth=1; next }
                in_m {
                    n=gsub(/\{/,"{"); depth+=n
                    n=gsub(/\}/,"}"); depth-=n
                    print
                    if (depth<=0) exit
                }
            ')"
        local v
        v="$(printf '%s' "$mapping_block" \
            | grep -oE "\"$escaped\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" \
            | head -1 \
            | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/')"
        if [[ -n "$v" ]]; then
            printf '%s' "$v"
            return 0
        fi
    fi
    printf '%s' "${DEFAULT_BINUTILS_MAP[$key]:-}"
}

detect_host_llvm() {
    if [[ -n "$LLVM_ROOT" ]]; then
        # When a portable LLVM is provided, no version probing is needed —
        # the templates will be redirected to "$LLVM_ROOT/bin/<basename>"
        # by overlay_binutils. We still echo a value so callers and logs
        # have something to show.
        if [[ ! -x "$LLVM_ROOT/bin/llc" ]]; then
            echo "!!   --llvm-root '$LLVM_ROOT' but '$LLVM_ROOT/bin/llc' missing or not executable" >&2
            return 1
        fi
        echo "portable"
        return 0
    fi
    if [[ -n "$LLVM_MAJOR_OVERRIDE" ]]; then
        if [[ -x "/usr/lib/llvm-$LLVM_MAJOR_OVERRIDE/bin/llc" ]]; then
            echo "$LLVM_MAJOR_OVERRIDE"
            return 0
        fi
        echo "!!   --llvm-major $LLVM_MAJOR_OVERRIDE pinned but /usr/lib/llvm-$LLVM_MAJOR_OVERRIDE/bin/llc not found" >&2
        return 1
    fi
    local v
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        if [[ -x "/usr/lib/llvm-$v/bin/llc" ]]; then
            echo "$v"
            return 0
        fi
    done < <(manifest_llvm_majors)
    return 1
}

print_llvm_install_recipe() {
    local codename
    # shellcheck disable=SC1091  # /etc/os-release is sourced opportunistically; OK when missing
    codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-bullseye}")"
    cat >&2 <<EOF
   no LLVM >= 15 found under /usr/lib/llvm-*/bin/. The .NET Android SDK 36.x
   emits LLVM IR using opaque pointers (introduced in LLVM 15+); without it,
   AOT publishes fail at the llc step.

   Install with apt.llvm.org (validated on Pi OS bullseye, aarch64):

     wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \\
       sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/apt.llvm.org.gpg
     echo 'deb http://apt.llvm.org/$codename/ llvm-toolchain-$codename-19 main' | \\
       sudo tee /etc/apt/sources.list.d/llvm-19.list
     sudo apt-get update
     sudo apt-get install -y llvm-19 lld-19 binutils

   Re-run install-shims.sh after install. If you don't need AOT publishes,
   pass --skip-binutils (the .so + aapt2 shims will still install).
EOF
}

overlay_symlink() {
    local src="$1" dst="$2" backup_dir="$3"

    if [[ ! -e "$src" ]]; then
        echo "!!     host source missing: $src" >&2
        return 30
    fi

    # Idempotency: existing symlink already pointing at $src — done.
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        echo "   = $(basename "$dst") already symlinked to $src, skipping"
        return 0
    fi

    # Back up the original x86_64 file, but only the first time and only if
    # what's currently at $dst is a real file (not one of our prior symlinks).
    if [[ -f "$dst" && ! -L "$dst" ]]; then
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
        echo "   [dry] symlink $dst -> $src"
    else
        ln -snf "$src" "$dst"
        echo "   * symlinked $dst -> $src"
    fi
}

overlay_binutils() {
    local pack="$1"
    local bindir="$pack/$BINUTILS_PACK_DIR_REL"
    local backup_dir="$pack/$BINUTILS_BACKUP_DIR_REL"

    if [[ ! -d "$bindir" ]]; then
        echo "   ! no $BINUTILS_PACK_DIR_REL/ in pack — predates the AOT toolchain layout, skipping binutils"
        return 0
    fi

    [[ -x /usr/bin/as ]] || {
        echo "!! host missing /usr/bin/as. Install with: sudo apt-get install -y binutils" >&2
        return 6
    }

    local llvm_major
    if ! llvm_major="$(detect_host_llvm)"; then
        print_llvm_install_recipe
        return 7
    fi
    if [[ "$llvm_major" == "portable" ]]; then
        echo "   using portable LLVM at $LLVM_ROOT/bin/"
    else
        echo "   detected host LLVM $llvm_major under /usr/lib/llvm-$llvm_major/"
    fi

    local rc=0
    local bin
    for bin in "${BINUTILS_BINARIES[@]}"; do
        local rel="$BINUTILS_PACK_DIR_REL/$bin"
        local template
        template="$(manifest_binutils_target "$rel")"
        if [[ -z "$template" ]]; then
            echo "!!     no host mapping for $rel in compatibility.json or defaults" >&2
            rc=8; continue
        fi
        local src
        if [[ "$llvm_major" == "portable" && "$template" == /usr/lib/llvm-*/bin/* ]]; then
            # Redirect any /usr/lib/llvm-{llvm}/bin/<x> mapping to the
            # portable LLVM root. Non-LLVM mappings (e.g. /usr/bin/as for
            # binutils) pass through unchanged.
            src="$LLVM_ROOT/bin/${template##*/}"
        else
            src="${template//\{llvm\}/$llvm_major}"
        fi
        if ! overlay_symlink "$src" "$bindir/$bin" "$backup_dir"; then
            rc=$?
        fi
    done
    return $rc
}

# --- Android SDK build-tools overlay -----------------------------------------
#
# zipalign is not part of Microsoft.Android.Sdk.Linux. sdkmanager installs it
# under <android-sdk>/build-tools/<version>/zipalign, so it must be patched
# separately and only after build-tools are present on disk.

overlay_build_tools_zipalign() {
    local src="$1"
    local build_tools_root="$ANDROID_SDK_ROOT/build-tools"

    if [[ "$SKIP_BUILD_TOOLS" -eq 1 ]]; then
        echo "   ! Android SDK build-tools overlay skipped (--skip-build-tools). Signed APK publishes may fail at zipalign."
        return 0
    fi

    if [[ ! -f "$src" ]]; then
        echo "   ! zipalign not present in this release tarball — skipping Android SDK build-tools overlay"
        return 0
    fi

    if [[ ! -d "$build_tools_root" ]]; then
        echo "   ! Android SDK build-tools root not found: $build_tools_root"
        echo "     skipping zipalign overlay; re-run after sdkmanager installs build-tools"
        return 0
    fi

    local versions=()
    while IFS= read -r v; do
        versions+=("$v")
    done < <(find "$build_tools_root" -mindepth 2 -maxdepth 2 -type f -name zipalign -printf '%h\n' \
        | xargs -r -n1 basename \
        | sort -V)

    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "   ! no build-tools/*/zipalign found under $build_tools_root"
        echo "     skipping zipalign overlay; re-run after sdkmanager installs build-tools"
        return 0
    fi

    local v
    for v in "${versions[@]}"; do
        echo "   > Android SDK build-tools $v"
        overlay_one "$src" \
                    "$build_tools_root/$v/zipalign" \
                    "$build_tools_root/$v/.x86_64-backup"
    done
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

    if [[ "$SKIP_BINUTILS" -eq 1 ]]; then
        echo "   ! binutils overlay skipped (--skip-binutils). AOT publishes will fail."
    else
        if ! overlay_binutils "$pack"; then
            ANY_BINUTILS_FAILED=1
        fi
    fi

    overlay_build_tools_zipalign "$workdir/zipalign"

    rm -rf "$workdir"
done

echo ""
if [[ "$ANY_BINUTILS_FAILED" -eq 1 ]]; then
    echo "PARTIAL  .so + aapt2 shims installed; binutils overlay had errors (see above)."
    echo "         Re-run after fixing the host LLVM install, or pass --skip-binutils"
    echo "         if you don't need AOT publishes."
    exit 6
fi
echo "OK  shim install complete."
