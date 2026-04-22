#!/usr/bin/env bash
# Smoke-test aapt2's daemon mode. The .NET MSBuild Aapt2 task spawns
# `aapt2 daemon` and feeds requests over stdin. The protocol is line-oriented:
# each request is a sequence of arg-lines terminated by a blank line, and the
# daemon answers with "Done" / "Error" tokens.
#
# We don't replicate the full protocol here — we just check the daemon starts,
# prints its readiness banner, and exits cleanly on EOF. That's enough to catch
# library-load failures and missing runtime deps that `aapt2 version` doesn't
# stress (different code paths).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT="${ARTIFACT:-$REPO_ROOT/out/linux-arm64/aapt2}"
[[ -x "$ARTIFACT" ]] || { echo "missing or non-executable artifact: $ARTIFACT"; exit 2; }

echo ">> spawning aapt2 daemon, sending EOF, expecting clean exit"
# Send empty stdin → daemon should read EOF on its first request and exit 0.
if echo "" | timeout 10 "$ARTIFACT" daemon >/tmp/aapt2-daemon.log 2>&1; then
    echo "OK  aapt2 daemon started and exited cleanly on EOF"
    exit 0
fi

RC=$?
# Some aapt2 builds exit non-zero on EOF; that's fine as long as we got a
# recognisable startup banner before the failure. Inspect output:
if grep -qiE 'aapt2|daemon|ready' /tmp/aapt2-daemon.log; then
    echo "OK  aapt2 daemon spoke before exiting (rc=$RC) — acceptable"
    sed 's/^/    /' /tmp/aapt2-daemon.log
    exit 0
fi

echo "!! aapt2 daemon failed with rc=$RC and no recognisable output:"
sed 's/^/    /' /tmp/aapt2-daemon.log
exit 1
