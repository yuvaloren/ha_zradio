#!/usr/bin/env bash
# tests/run.sh — every test of the kit, against fakes only: no radio, no VM, no network. One command:
#   bash tests/run.sh              # all t-*.sh; exit 0 with "totals: N PASS, 0 FAIL" last
#   bash tests/run.sh t-serve.sh
# Needs: Linux — bash 4+, GNU coreutils and sed, util-linux (flock), python3. On macOS: bash tests/docker.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 2
tests=("$@"); [ ${#tests[@]} -gt 0 ] || tests=(t-*.sh)
p=0; f=0
for t in "${tests[@]}"; do
  echo "== $t"
  out=$(bash "$t" 2>&1); rc=$?
  printf '%s\n' "$out"
  line=$(printf '%s\n' "$out" | sed -n 's/^# .*: \([0-9]*\) PASS, \([0-9]*\) FAIL$/\1 \2/p' | tail -1)
  if [ -z "$line" ]; then echo "  FAIL  $t did not finish (rc $rc)"; f=$((f + 1)); continue; fi
  p=$((p + ${line% *})); f=$((f + ${line#* }))
  [ $rc -eq 0 ] || [ "${line#* }" -gt 0 ] || { echo "  FAIL  $t exited $rc with no FAIL line"; f=$((f + 1)); }
done
echo "# totals: $p PASS, $f FAIL"
[ $f -eq 0 ]
