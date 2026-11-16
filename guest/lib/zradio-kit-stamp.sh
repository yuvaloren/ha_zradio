#!/usr/bin/env bash
# zradio-kit-stamp.sh <kit folder> — writes <kit>/gen/kit-version: which kit this is. Run by both installers (the node's
# install.sh, and guest/install.sh when no node gave it one); the VM keeps a copy as /usr/local/lib/zradio/kit-version,
# which is how a later ./install.sh tells whether that VM is up to date. Two lines, KEY=value:
#   VERSION  for people. What get.sh wrote into gen/version (a release's tag, or <branch>@<commit>); else, in a git
#            clone, `git describe` (v0.1.0, v0.1.0-3-g08df12f, or a commit before the first tag; -dirty with changes
#            not committed); else "unknown".
#   CONTENT  for the comparison: a hash of every file the VM installs from the kit (guest/ and the table of sticks).
#            The same CONTENT is the same files, whatever VERSION says, so a changed file is never "up to date".
set -uo pipefail
kit=${1:?usage: zradio-kit-stamp.sh <kit folder>}
[ -d "$kit/guest" ] && [ -f "$kit/gen/usb-ids.json" ] || { echo "zradio-kit-stamp: $kit has no guest/ or no gen/usb-ids.json" >&2; exit 2; }
version=""; [ ! -f "$kit/gen/version" ] || version=$(tr -dc 'A-Za-z0-9./@_+-' < "$kit/gen/version")
[ -n "$version" ] || [ ! -e "$kit/.git" ] || version=$(git -c safe.directory="$kit" -C "$kit" describe --tags --always --dirty 2>/dev/null)
content=$(cd "$kit" && find guest gen/usb-ids.json -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
printf 'VERSION=%s\nCONTENT=%s\n' "${version:-unknown}" "$content" > "$kit/gen/kit-version.tmp" && mv -f "$kit/gen/kit-version.tmp" "$kit/gen/kit-version"
