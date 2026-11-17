#!/usr/bin/env bash
# tests/docker.sh — tests/run.sh in a Linux container (tests/Dockerfile), for a machine that is not Linux. The tests
# need GNU coreutils and sed and util-linux's flock; macOS has none of them. Needs: docker.
#   bash tests/docker.sh              # shellcheck (tests/shellcheck.sh), then every t-*.sh. The workflow runs these
#                                     # on a push, and then the three tests that need docker themselves
#                                     # (tests/vote-bash.sh, tests/vote-real.sh, tests/hass-real.sh)
#   bash tests/docker.sh t-serve.sh   # only that file, no shellcheck
# The clone is mounted read-only; nothing is written into it. The first run builds the image (about a minute).
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t zradio-tests - < tests/Dockerfile > /dev/null
exec docker run --rm -v "$PWD":/src:ro zradio-tests "$@"
