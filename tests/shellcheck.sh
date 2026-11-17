#!/usr/bin/env bash
# tests/shellcheck.sh — shellcheck over every shell script of the kit. One place that says which they are, for the
# tests' container (tests/Dockerfile) and for the workflow (.github/workflows/tests.yml):
#   bash tests/shellcheck.sh
# There is no list to keep: a shell script is a file whose first line is a bash or sh shebang, or the note a sourced
# file opens with to tell shellcheck its shell ("shellcheck shell=bash"). So a new script is checked from its first day.
# Not looked at: .git, and gen/ (what the kit generates; it is not kept in git).
# -x: a sourced file is followed. Warnings count, notes of style do not. Needs: shellcheck.
set -euo pipefail
cd "$(dirname "$0")/.."
files=()
while IFS= read -r f; do
  first=$(head -n 1 "$f" 2>/dev/null | tr -d '\000')
  case "$first" in '#!'*bash*|'#!'*/sh|'#!'*/sh' '*|'#!'*' sh'|'# shellcheck shell='*) files+=("${f#./}");; esac
done < <(find . -type f -not -path './.git/*' -not -path './gen/*' | LC_ALL=C sort)
[ ${#files[@]} -gt 0 ] || { echo "shellcheck.sh: no shell script found under $PWD" >&2; exit 2; }
echo "== shellcheck: ${#files[@]} scripts"
exec shellcheck -x -S warning "${files[@]}"
