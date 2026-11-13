# shellcheck shell=bash
# tests/lib.sh — the shared pieces of the kit's tests (tests/run.sh runs them all): PASS/FAIL counters, a temp dir per
# test file, fakes on PATH. Nothing here reaches a radio, a VM or a network: every systemd, ssh, podman and stick
# command a tool runs is a fake the test writes.
set -uo pipefail
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # KIT is the tests' root
KIT=$(cd "$TESTS_DIR/.." && pwd)            # the repository under test
# The table of known sticks is built from Home Assistant's USB lists: here from the tests' copies of them, never GitHub.
export ZRADIO_USB_IDS_SOURCE="$TESTS_DIR/fixtures/ha-core"
PASS=0; FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/zradio-test.XXXXXX") && [ -d "$T" ] || { echo "lib.sh: no temp dir (mktemp failed)" >&2; exit 2; }; trap 'rm -rf "$T"' EXIT
check() { # check <name> <command…>: one PASS or FAIL line
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); printf '  PASS  %s\n' "$name"; else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"; fi
}
qgrep() { grep "$@" >/dev/null; }            # never grep -q at the end of a pipeline (SIGPIPE under pipefail)
has()    { grep -qF -- "$2" "$1"; }          # has <file> <text>
hasnt()  { ! grep -qF -- "$2" "$1"; }
eq()     { [ "$1" = "$2" ] || { printf '        want [%s] got [%s]\n' "$2" "$1"; return 1; }; }
finish() { printf '# %s: %d PASS, %d FAIL\n' "$(basename "$0")" "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }
fake() { # fake <dir> <name> <body>: an executable bash fake on a PATH dir
  mkdir -p "$1"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
