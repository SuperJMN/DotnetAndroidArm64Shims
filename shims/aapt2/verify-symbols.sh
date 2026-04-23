#!/usr/bin/env bash
# verify-symbols.sh — for aapt2 this is a wrapper that runs the two real
# acceptance checks (the name is kept for parity with the other shims so CI
# can call shims/<shim>/verify-symbols.sh uniformly).
#
#   1. version-string parity — must match pack-versions/<v>.env exactly,
#      otherwise XA0111 trips on every .NET Android build.
#   2. daemon mode smoke test — exercises a different code path than `version`
#      and catches library-load / runtime-init failures.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== aapt2 verify-version =="
bash "$HERE/verify-version.sh"

echo ""
echo "== aapt2 verify-daemon =="
bash "$HERE/verify-daemon.sh"

echo ""
echo "OK  aapt2 passed both checks"
