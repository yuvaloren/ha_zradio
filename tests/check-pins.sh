#!/usr/bin/env bash
# tests/check-pins.sh — the versions the kit pins where Dependabot cannot see them, held against what their makers
# say today. Not one of tests/run.sh's files: it needs the network and docker. Weekly in CI (.github/workflows/pins.yml),
# and whenever a pin changes:
#   bash tests/check-pins.sh
#
#   the pin                                      where                               what is asked
#   the Z-Wave JS UI image (it writes a copied   guest/lib/zradio-common.sh          the Node.js inside it, at endoflife.date:
#   Z-Wave network onto the standby's stick)     (ZR_ZUI_IMAGE), zradio.conf.example   end of life, or within 60 days -> ERROR;
#                                                                                    a newer release of the image -> warning
#   zigpy-cli (reads and writes a Zigbee stick)  guest/lib/zradio-common.sh          at PyPI: the pinned release gone or
#                                                (ZIGPY_VERSION)                       yanked -> ERROR; a newer one -> warning
#   Debian 13 (the radio VM, the third vote's    install.sh, vote/install.sh,        at endoflife.date: end of life, or
#   image, the tests' own image)                 tests/Dockerfile                      within 60 days -> ERROR
#
# A pin that is behind is a warning, not a failure: a newer Z-Wave JS UI or zigpy writes sticks, and is taken only
# after a sync with it was seen on a pair. An end of life is a failure: nothing unsupported is shipped.
# Lines are GitHub's annotations (::error::, ::warning::, ::notice::), readable in a terminal too. Exit 1 on any ERROR.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
SOON=60      # days before an end of life from which the pin fails
ERRORS=0
err() { echo "::error::$*"; ERRORS=$((ERRORS + 1)); }
get() { curl -fsSL --retry 3 --max-time 30 "$1"; }      # get <url>: its body, or nothing and a non-zero exit
gh_get() { # gh_get <url>: the same from GitHub's API, as the workflow's token where there is one (GITHUB_TOKEN). Without
  # one, a runner shares its address's small allowance with every other runner, and is answered 403 as often as not.
  # The token goes to curl on its standard input, never on a command line.
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" | curl -fsSL --retry 3 --max-time 30 -K - "$1"
  else get "$1"; fi
}

ZUI=$(sed -n 's/^ZR_ZUI_IMAGE=\([^ ]*\).*/\1/p' guest/lib/zradio-common.sh)      # name:tag@sha256:…
ZUI_NAME=${ZUI%%@*}; ZUI_TAG=${ZUI_NAME##*:}; ZUI_DIGEST=${ZUI#*@}; [ "$ZUI_DIGEST" != "$ZUI" ] || ZUI_DIGEST=""
ZIGPY=$(sed -n 's/^ *ZIGPY_VERSION=\([0-9][0-9a-z.]*\)$/\1/p' guest/lib/zradio-common.sh | head -n 1)
[ -n "$ZUI" ] && [ -n "$ZIGPY" ] || { err "could not read the pins from guest/lib/zradio-common.sh (ZR_ZUI_IMAGE, ZIGPY_VERSION)"; exit 1; }
echo "the pins: $ZUI; zigpy-cli $ZIGPY; Debian 13"

# an end-of-life date of endoflife.date, judged: eol <product> <cycle> <what it is in the kit>
eol() {
  local f; f=$(mktemp) || { err "no temporary file"; return; }
  if ! get "https://endoflife.date/api/$1.json" > "$f"; then rm -f "$f"; err "endoflife.date did not answer for $1: the end of life of $3 could not be checked"; return; fi
  python3 - "$f" "$1" "$2" "$3" "$SOON" <<'PY' || ERRORS=$((ERRORS + 1))
import datetime, json, sys
path, product, cycle, what, soon = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
try: cycles = json.load(open(path))
except ValueError: print("::error::endoflife.date's answer for %s is not JSON" % product); sys.exit(1)
c = next((x for x in cycles if str(x.get("cycle")) == cycle), None)
if c is None: print("::error::%s %s (%s) is not in endoflife.date's list" % (product, cycle, what)); sys.exit(1)
today = datetime.datetime.now(datetime.timezone.utc).date()
e = c.get("eol")
if e is True: print("::error::%s %s (%s) is END OF LIFE" % (product, cycle, what)); sys.exit(1)
if isinstance(e, str):
    left = (datetime.date.fromisoformat(e) - today).days
    if left <= 0: print("::error::%s %s (%s) is END OF LIFE since %s" % (product, cycle, what, e)); sys.exit(1)
    if left <= soon: print("::error::%s %s (%s) reaches its end of life on %s, in %d days" % (product, cycle, what, e, left)); sys.exit(1)
    print("ok: %s %s (%s) is supported until %s (%d days)" % (product, cycle, what, e, left))
else: print("ok: %s %s (%s) has no end of life announced" % (product, cycle, what))
newest_lts = next((str(x.get("cycle")) for x in cycles if x.get("lts")), None)
if product == "nodejs" and newest_lts and newest_lts != cycle:
    print("::notice::Node.js %s is not the newest LTS line any more (%s is): the image's maker decides when it moves" % (cycle, newest_lts))
PY
  rm -f "$f"
}

# 1. the Node.js inside the pinned Z-Wave JS UI image
if NODE=$(docker run --rm --entrypoint node "$ZUI" --version 2>/dev/null) && [[ "$NODE" =~ ^v([0-9]+)\. ]]; then
  eol nodejs "${BASH_REMATCH[1]}" "the Node.js $NODE in $ZUI"
else err "could not run node in $ZUI (docker, or the image is gone from its registry): the pinned image could not be checked"; fi

# 2. a newer Z-Wave JS UI
if LATEST=$(gh_get https://api.github.com/repos/zwave-js/zwave-js-ui/releases/latest | tr -d '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p') && [ -n "$LATEST" ]; then
  if [ "$LATEST" = "$ZUI_TAG" ]; then echo "ok: Z-Wave JS UI $ZUI_TAG is the newest release"
  else echo "::warning::Z-Wave JS UI $ZUI_TAG is pinned and $LATEST is out. To take it: try a sync with ZUI_IMAGE=${ZUI_NAME%:*}:$LATEST in a pair's zradio.conf, then move ZR_ZUI_IMAGE (guest/lib/zradio-common.sh: the tag and its digest) and zradio.conf.example"; fi
else echo "::warning::GitHub did not say what the newest Z-Wave JS UI is: not compared"; fi

# 2b. the pinned digest is what the registry answers for the pinned tag today (a tag that was moved, or a digest that
#     was mistyped, would have every new VM pull something else than the kit says, or nothing)
if [ -n "$ZUI_DIGEST" ]; then
  REPO=${ZUI_NAME%:*}; REPO=${REPO#docker.io/}
  TOKEN=$(get "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  NOW=$(curl -fsSI --retry 3 --max-time 30 -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.index.v1+json" -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/$REPO/manifests/$ZUI_TAG" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
  if [ -z "$NOW" ]; then echo "::warning::the registry did not say what $ZUI_NAME is today: the pinned digest was not compared"
  elif [ "$NOW" = "$ZUI_DIGEST" ]; then echo "ok: the pinned digest is what the registry answers for $ZUI_NAME"
  else err "$ZUI_NAME is $NOW at the registry today, and the kit pins $ZUI_DIGEST: the tag was moved, or the pin is wrong"; fi
else echo "::warning::the Z-Wave JS UI image is pinned by its tag only ($ZUI): a tag can be moved"; fi

# 3. zigpy-cli at PyPI
PYPI=$(mktemp)
if get https://pypi.org/pypi/zigpy-cli/json > "$PYPI"; then
  python3 - "$PYPI" "$ZIGPY" <<'PY' || ERRORS=$((ERRORS + 1))
import json, sys
d, pin = json.load(open(sys.argv[1])), sys.argv[2]
files = d.get("releases", {}).get(pin)
if not files: print("::error::zigpy-cli %s is not at PyPI any more: a new radio VM could not install it" % pin); sys.exit(1)
if all(f.get("yanked") for f in files): print("::error::zigpy-cli %s was yanked at PyPI (%s)" % (pin, files[0].get("yanked_reason") or "no reason given")); sys.exit(1)
latest = d.get("info", {}).get("version")
if latest == pin: print("ok: zigpy-cli %s is the newest release" % pin)
else: print("::warning::zigpy-cli %s is pinned and %s is out. To take it: try a sync with ZIGPY_VERSION=%s in a pair's zradio.conf (both VMs), then move the default in guest/lib/zradio-common.sh" % (pin, latest, latest))
PY
else echo "::warning::PyPI did not answer for zigpy-cli: not compared"; fi
rm -f "$PYPI"

# 4. Debian 13, in the three places that name it
grep -q 'IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/' install.sh && grep -q '^BASE=debian:13-slim' vote/install.sh && grep -q '^FROM debian:13$' tests/Dockerfile \
  || err "the kit's three Debian pins no longer all say Debian 13 (install.sh IMAGE_DIR, vote/install.sh BASE, tests/Dockerfile FROM): this check asks about 13 only"
eol debian 13 "the radio VM's image, the third vote's image and the tests' image"

[ $ERRORS = 0 ] || { echo "== $ERRORS ERROR: a pin is, or is about to be, unsupported =="; exit 1; }
echo "== the pins are supported =="
