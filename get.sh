#!/usr/bin/env bash
# get.sh — ha_zradio onto this machine, then its installer. The one line to paste, as root, on each Proxmox node (a
# radio VM there), for a cluster's third vote on the third machine, and in Home Assistant's terminal (what to set
# there, so that it uses the pair). install.sh sees which of the three it is on:
#
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)"
#
# It downloads the kit from GitHub (the latest release; while there is none, main) into /opt/ha_zradio/<version> and
# runs ./install.sh there, on this terminal: the same questions, the same "Go ahead?". Before that "y" nothing on the
# node is changed but that folder.
#   Options for install.sh go after the line:     bash -c "$(curl -fsSL …/get.sh)" _ --sticks
#   Another version:                               ZRADIO_REF=<tag or branch> bash -c "$(curl -fsSL …/get.sh)"
# Not `curl … | bash`: the installer's questions need this terminal on stdin.
# Tests: tests/t-get.sh. Env for the tests: ZRADIO_REPO, ZRADIO_GITHUB, ZRADIO_GITHUB_API, ZRADIO_DEST.
set -uo pipefail
REPO=${ZRADIO_REPO:-yuvaloren/ha_zradio}
GH=${ZRADIO_GITHUB:-https://github.com}
API=${ZRADIO_GITHUB_API:-https://api.github.com}
DEST=${ZRADIO_DEST:-/opt/ha_zradio}
die() { echo "get.sh: $*" >&2; exit 2; }
[ "$(id -u)" = 0 ] || die "run this as root: the installer builds a VM on a Proxmox node, or sets up the cluster's third vote on another machine"
command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || die "needs curl and tar"      # no python here: Home Assistant's terminal has none
# the folder this script replaces things in: one of its own, never a system path
[[ "$DEST" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || die "ZRADIO_DEST '$DEST': an absolute path at least two levels deep"

REF=${ZRADIO_REF:-} RELEASE=""
if [ -z "$REF" ]; then          # the latest release. A repository without one (GitHub answers 404): main
  # Any other failure stops here: a node must not get main's unreleased code because GitHub was busy or out of reach.
  if ANSWER=$(curl -fsSL "$API/repos/$REPO/releases/latest" 2>&1); then
    RELEASE=$(printf '%s' "$ANSWER" | tr -d '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$RELEASE" ] || die "GitHub's answer names no latest release ($API/repos/$REPO/releases/latest). A version by name: ZRADIO_REF=<tag or branch> before the line"
  else
    case "$ANSWER" in *"error: 404"*) ;; *) die "could not ask GitHub for the latest release: $(printf '%s' "$ANSWER" | tail -n 1). Try again, or name a version: ZRADIO_REF=<tag or branch> before the line";; esac
  fi
  REF=${RELEASE:-main}
fi
[[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] && [[ "$REF" != *..* ]] || die "ZRADIO_REF '$REF': a tag or a branch name"
DIR="$DEST/${REF//\//-}"
URL="$GH/$REPO/archive/$REF.tar.gz"

echo "== ha_zradio $REF, from $GH/$REPO =="
mkdir -p "$DEST" || die "cannot make $DEST"
TMP=$(mktemp -d "$DEST/.get.XXXXXX") || die "no temporary folder in $DEST"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
curl -fsSL "$URL" -o "$TMP/kit.tgz" || die "the download failed: $URL"
mkdir "$TMP/kit" && tar -xzf "$TMP/kit.tgz" -C "$TMP/kit" --strip-components=1 2>/dev/null || die "$URL is not a tar.gz archive"
[ -f "$TMP/kit/install.sh" ] && [ -f "$TMP/kit/guest/install.sh" ] || die "$URL holds no install.sh and guest/: not the kit"
# the commit the archive was made from (GitHub writes it into the archive's header)
SHA=$(gzip -dc "$TMP/kit.tgz" 2>/dev/null | head -c 2048 | LC_ALL=C tr -d '\000' | LC_ALL=C sed -n 's/.*comment=\([0-9a-f]\{40\}\).*/\1/p' | head -n 1 | cut -c1-12)
# the kit's version, for its installers (guest/lib/zradio-kit-stamp.sh): a release by its tag, anything else as
# <tag or branch>@<commit>. Into the kit's gen/, the folder for what is generated and never kept in git.
mkdir -p "$TMP/kit/gen" && printf '%s\n' "$([ "$REF" = "$RELEASE" ] && echo "$REF" || echo "$REF${SHA:+@${SHA:0:7}}")" > "$TMP/kit/gen/version" \
  || die "cannot write $TMP/kit/gen/version"
if [ -e "$DIR" ]; then mv "$DIR" "$TMP/old" || die "cannot move the earlier download $DIR aside"; fi
mv "$TMP/kit" "$DIR" || die "cannot put the kit at $DIR"
cleanup; trap - EXIT
echo "   the kit is in $DIR${SHA:+ (commit $SHA)}. To run its installer again: cd $DIR && ./install.sh"
echo
exec bash "$DIR/install.sh" "$@"      # from the folder the line was pasted in: a file named in an option (--answers) is found
