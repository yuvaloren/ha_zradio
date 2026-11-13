#!/usr/bin/env bash
# get.sh — ha_zradio onto this Proxmox node, then its installer. The one line to paste, as root, on each node:
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
[ "$(id -u)" = 0 ] || die "run this as root on a Proxmox node: the installer builds a VM"
command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || die "needs curl, tar and python3 (a Proxmox node has all three)"
# the folder this script replaces things in: one of its own, never a system path
[[ "$DEST" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || die "ZRADIO_DEST '$DEST': an absolute path at least two levels deep"

REF=${ZRADIO_REF:-}
if [ -z "$REF" ]; then          # the latest release; a repository without one: main
  REF=$(curl -fsSL "$API/repos/$REPO/releases/latest" 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null) || REF=""
  [ -n "$REF" ] || REF=main
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
SHA=$(python3 -c 'import sys, tarfile; print(tarfile.open(sys.argv[1]).pax_headers.get("comment", "")[:12])' "$TMP/kit.tgz" 2>/dev/null)
if [ -e "$DIR" ]; then mv "$DIR" "$TMP/old" || die "cannot move the earlier download $DIR aside"; fi
mv "$TMP/kit" "$DIR" || die "cannot put the kit at $DIR"
cleanup; trap - EXIT
echo "   the kit is in $DIR${SHA:+ (commit $SHA)}. To run its installer again: cd $DIR && ./install.sh"
echo
cd "$DIR" || die "cannot enter $DIR"
exec bash ./install.sh "$@"
