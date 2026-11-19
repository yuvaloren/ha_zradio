#!/usr/bin/env bash
# t-get.sh — get.sh, the one line to paste on a node, against a fake GitHub: curl is a fake that serves local files
# for the release API and the archive. Nothing here reaches the network. The kit in the archives is a stand-in whose
# install.sh only says where it ran and with what.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/get.sh"

site() { # site <dir> [release tag, or nothing]: a fake GitHub with one kit archive, and curl/id on PATH
  local d=$1 tag=${2:-}; rm -rf "$d"; mkdir -p "$d/bin" "$d/src/ha_zradio-x/guest"; : > "$d/calls"
  printf '#!/usr/bin/env bash\necho "install.sh ran in $(cd "$(dirname "$0")" && pwd) with: $*"; echo "from the folder: $PWD"\n' > "$d/src/ha_zradio-x/install.sh"
  echo "# the guest" > "$d/src/ha_zradio-x/guest/install.sh"
  tar -C "$d/src" --format=pax --pax-option=comment=0123456789abcdef0123456789abcdef01234567 -czf "$d/kit.tgz" ha_zradio-x
  [ -z "$tag" ] || printf '{"tag_name": "%s", "name": "%s"}\n' "$tag" "$tag" > "$d/release.json"
  fake "$d/bin" id 'case "${1:-}" in -u) echo "${FAKE_UID:-0}";; *) command -p id "$@";; esac'
  fake "$d/bin" curl "echo \"curl \$*\" >> '$d/calls'; out=''; url=''
while [ \$# -gt 0 ]; do case \"\$1\" in -o) out=\$2; shift 2;; -*) shift;; *) url=\$1; shift;; esac; done
case \"\$url\" in
  */releases/latest) [ ! -f '$d/api-down' ] || { echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22; }
     [ -f '$d/release.json' ] || { echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; }; cat '$d/release.json';;
  */archive/*) [ -f '$d/down' ] && exit 22; cp '$d/kit.tgz' \"\$out\";;
  *) exit 22;; esac"
}
get() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_DEST="$d/opt/ha_zradio" ZRADIO_GITHUB=https://gh.example ZRADIO_GITHUB_API=https://api.example bash "$TOOL" "$@" > "$d/out" 2>&1 < /dev/null; RC=$?; }
left() { find "$1/opt/ha_zradio" -maxdepth 1 -name '.get.*' | grep -c .; }

echo "-- no release yet: main"
site "$T/a"; get "$T/a" --sticks
check "exit 0; asked GitHub for the latest release, then took main's archive" bash -c '[ "$2" = 0 ] && grep -q "^curl .*https://api.example/repos/yuvaloren/ha_zradio/releases/latest" "$1/calls" && grep -q "^curl .*https://gh.example/yuvaloren/ha_zradio/archive/main.tar.gz" "$1/calls"' _ "$T/a" "$RC"
check "the kit is unpacked in /opt/ha_zradio/main, and its install.sh ran THERE with the options given after the line" bash -c '[ -f "$1/opt/ha_zradio/main/guest/install.sh" ] && grep -q "^install.sh ran in $1/opt/ha_zradio/main with: --sticks$" "$1/out"' _ "$T/a"
check "said: which version, from where, where the kit is and how to run it again; nothing temporary left behind" bash -c 'grep -q "== ha_zradio main, from https://gh.example/yuvaloren/ha_zradio ==" "$1/out" && grep -q "the kit is in $1/opt/ha_zradio/main.*To run its installer again: cd $1/opt/ha_zradio/main && ./install.sh" "$1/out" && [ "$2" = 0 ]' _ "$T/a" "$(left "$T/a")"

echo "-- a release exists: that one"
site "$T/r" v0.2.0; get "$T/r"
check "the latest release's archive, in a folder of its own name" bash -c '[ "$2" = 0 ] && grep -q "archive/v0.2.0.tar.gz" "$1/calls" && ! grep -q "archive/main" "$1/calls" && grep -q "^install.sh ran in $1/opt/ha_zradio/v0.2.0 with: $" "$1/out"' _ "$T/r" "$RC"
check "…and the kit knows its version: the release's tag, in its gen/version (generated, never in git)" bash -c '[ "$(cat "$1/opt/ha_zradio/v0.2.0/gen/version")" = v0.2.0 ]' _ "$T/r"

echo "-- ZRADIO_REF: a version named; the same version again"
site "$T/b"; ZRADIO_REF=claude/phase1-guest-kit get "$T/b"
check "not a release: the version is <branch>@<commit>, the commit from the archive's header" bash -c '[ "$(cat "$1/opt/ha_zradio/claude-phase1-guest-kit/gen/version")" = "claude/phase1-guest-kit@0123456" ]' _ "$T/b"
check "a branch with a slash: its archive, the folder named with a dash, no release lookup" bash -c '[ "$2" = 0 ] && grep -q "archive/claude/phase1-guest-kit.tar.gz" "$1/calls" && ! grep -q "releases/latest" "$1/calls" && [ -f "$1/opt/ha_zradio/claude-phase1-guest-kit/install.sh" ]' _ "$T/b" "$RC"
echo "an old file" > "$T/b/opt/ha_zradio/claude-phase1-guest-kit/stale"; ZRADIO_REF=claude/phase1-guest-kit get "$T/b"
check "run again: the folder is replaced by the new download (an old file is gone), nothing temporary left" bash -c '[ "$2" = 0 ] && [ ! -e "$1/opt/ha_zradio/claude-phase1-guest-kit/stale" ] && [ -f "$1/opt/ha_zradio/claude-phase1-guest-kit/install.sh" ] && [ "$3" = 0 ]' _ "$T/b" "$RC" "$(left "$T/b")"

echo "-- GitHub does not answer the question about the latest release: no kit, and never main in its place"
site "$T/f" v0.2.0; : > "$T/f/api-down"; get "$T/f"
check "a 403 (GitHub's limit for one address) or any failure but 404: exit 2, said with what GitHub answered and with the way to name a version; nothing downloaded" bash -c '[ "$2" = 2 ] && grep -q "could not ask GitHub for the latest release: .*error: 403. Try again, or name a version: --ref <tag or branch> after the line.s _ (--main: the latest main)" "$1/out" && ! grep -q "archive/" "$1/calls" && [ ! -e "$1/opt/ha_zradio/main" ]' _ "$T/f" "$RC"
site "$T/g" v0.2.0; echo '{"message": "moved"}' > "$T/g/release.json"; get "$T/g"
check "an answer that names no release: exit 2, nothing downloaded" bash -c '[ "$2" = 2 ] && grep -q "names no latest release" "$1/out" && ! grep -q "archive/" "$1/calls"' _ "$T/g" "$RC"
echo "-- the installer runs from the folder the line was pasted in"
site "$T/c" v0.2.0; mkdir "$T/c/home"; ( cd "$T/c/home" && get "$T/c" --answers my.answers )
check "a file named in an option is looked for where the user is, not in the kit's folder" bash -c 'grep -qx "from the folder: $1/home" "$1/out" && grep -q "^install.sh ran in $1/opt/ha_zradio/v0.2.0 with: --answers my.answers$" "$1/out"' _ "$T/c"

echo "-- refused"
site "$T/x"; ZRADIO_REF=../../etc get "$T/x"
check "a version name with '..': refused, nothing downloaded" bash -c '[ "$2" = 2 ] && grep -q "the version .*(--ref, ZRADIO_REF): a tag or a branch name" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x" "$RC"
site "$T/d"; ZRADIO_REF=v1 get "$T/d"; : > "$T/d/down"; echo "keep" > "$T/d/opt/ha_zradio/v1/mine"; ZRADIO_REF=v1 get "$T/d"
check "the download fails: exit 2, said, the earlier download is left as it was, the installer not run, nothing temporary left" bash -c '[ "$2" = 2 ] && grep -q "get.sh: the download failed: https://gh.example/yuvaloren/ha_zradio/archive/v1.tar.gz" "$1/out" && [ -f "$1/opt/ha_zradio/v1/mine" ] && ! grep -q "install.sh ran" "$1/out" && [ "$3" = 0 ]' _ "$T/d" "$RC" "$(left "$T/d")"
site "$T/n"; rm -rf "$T/n/src/ha_zradio-x/guest"; tar -C "$T/n/src" -czf "$T/n/kit.tgz" ha_zradio-x; get "$T/n"
check "an archive that is not the kit: refused, nothing put in place" bash -c '[ "$2" = 2 ] && grep -q "holds no install.sh and guest/: not the kit" "$1/out" && [ ! -e "$1/opt/ha_zradio/main" ]' _ "$T/n" "$RC"
site "$T/u"; FAKE_UID=1000 get "$T/u"
check "not root: refused, nothing downloaded" bash -c '[ "$2" = 2 ] && grep -q "run this as root: the installer builds a VM on a Proxmox node" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/u" "$RC"
site "$T/p"; PATH="$T/p/bin:$PATH" ZRADIO_DEST=/opt bash "$TOOL" > "$T/p/out" 2>&1 < /dev/null; RC=$?
check "a folder of its own only: ZRADIO_DEST=/opt is refused" bash -c '[ "$2" = 2 ] && grep -q "ZRADIO_DEST ./opt.: an absolute path at least two levels deep" "$1/out"' _ "$T/p" "$RC"

check "the line in the header is the one in the README" bash -c 'l=$(sed -n "s/^#     \(bash -c .*\)$/\1/p" "$1/get.sh"); [ -n "$l" ] && grep -qF "$l" "$1/README.md"' _ "$KIT"
# (each of those scripts stands alone and so holds the line itself; here they are held to one another)
check "…and the one each script holds that prints it for another machine: the vote's installer, the node's two (the third vote, Home Assistant), Home Assistant's" bash -c 'l=$(sed -n "s/^#     \(bash -c .*\)$/\1/p" "$1/get.sh"); [ -n "$l" ] && for f in vote/install.sh host/qdevice.sh host/lib.sh homeassistant/install.sh; do [ "$(grep -cF -- "_LINE='"'"'$l _'"'"'" "$1/$f")" = 1 ] || { echo "        not as one literal in $f"; exit 1; }; done && [ "$(cat "$1"/install.sh "$1"/host/*.sh "$1"/vote/*.sh "$1"/homeassistant/*.sh | grep -c "raw.githubusercontent.com/.*/get.sh")" = 4 ]' _ "$KIT"

echo "-- --main and --ref: the latest main, or a version by name, without anything before the line"
site "$T/m1" v1.2.3; get "$T/m1" --main --sticks
check "--main with a release out: GitHub is not asked for the latest release, main's archive is taken" bash -c '[ "$2" = 0 ] && ! grep -q "releases/latest" "$1/calls" && grep -q "^curl .*https://gh.example/yuvaloren/ha_zradio/archive/main.tar.gz" "$1/calls" && [ -f "$1/opt/ha_zradio/main/install.sh" ]' _ "$T/m1" "$RC"
check "…its version is main and the commit, not a release's name" bash -c '[ "$(cat "$1/opt/ha_zradio/main/gen/version")" = "main@0123456" ]' _ "$T/m1"
check "…and --main is this script's own: install.sh gets only what came after it" bash -c 'grep -q "with: --sticks$" "$1/out"' _ "$T/m1"
site "$T/m2" v1.2.3; get "$T/m2" --ref v1.0.0 --stick-power 1-3:2
check "--ref <tag>: that archive, and the rest goes to install.sh" bash -c '[ "$2" = 0 ] && grep -q "archive/v1.0.0.tar.gz" "$1/calls" && grep -q "with: --stick-power 1-3:2$" "$1/out" && ! grep -q "releases/latest" "$1/calls"' _ "$T/m2" "$RC"
site "$T/m3"; get "$T/m3" --ref
check "--ref without a name: refused, nothing downloaded" bash -c '[ "$2" = 2 ] && grep -q "\-\-ref needs a tag or a branch name" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m3" "$RC"
site "$T/m4" v1.2.3; get "$T/m4" --sticks --main
check "an option of install.sh first: what follows is install.sh's too (--main is not taken from the middle)" bash -c 'grep -q "archive/v1.2.3.tar.gz" "$1/calls" && grep -q "with: --sticks --main$" "$1/out"' _ "$T/m4"
finish
