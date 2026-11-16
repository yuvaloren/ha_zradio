#!/usr/bin/env bash
# t-update.sh — ./install.sh on a node whose radio VM exists: the update of the pair to this kit (host/update.sh),
# against the fake cluster of tests/fake-node.sh. The guests are canned: the kit really is sent into them in pieces
# and unpacked, and the version stamp really is compared; the kit's installer in them is canned (it "succeeds" by
# installing the stamp it was sent). tests/t-e2e.sh runs the real installer in an update.
. "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"

pair() { # pair <dir>: attic1 (109) on nodea, this node, and attic2 (110) on nodeb, both running an older kit; attic2 serves
  local d=$1 id node name R
  node "$d"
  for x in "109 nodea attic1" "110 nodeb attic2"; do
    read -r id node name <<< "$x"; R="$d/g/$id/root"
    PATH="$d/bin:$PATH" pvesh create "/nodes/$node/qemu/$id/agent/exec" --command bash --input-data true > /dev/null   # the canned guest
    printf '%s\n' "NAME=$name" VIP=192.168.1.20/24 VRID=50 PRIORITY=100 > "$R/etc/zradio/zradio.conf"
    mkdir -p "$R/usr/local/lib/zradio"; printf 'VERSION=v0.0.9\nCONTENT=0000000000000000\n' > "$R/usr/local/lib/zradio/kit-version"
    python3 -c 'import json, sys; v = json.load(open(sys.argv[1])); v.append({"vmid": int(sys.argv[2]), "name": sys.argv[3], "node": sys.argv[4], "status": "running", "tags": "zradio", "type": "qemu"}); json.dump(v, open(sys.argv[1], "w"))' "$d/vms.json" "$id" "$name" "$node"
  done
  fake "$d/g/110/bin" ip 'echo "2: eth0    inet 192.168.1.20/24 scope global secondary eth0"'      # attic2 holds the floating address
  : > "$d/calls"
}
pieces() { grep -c "^guest: printf '%s' '" "$1/calls"; }
export -f pieces

echo "-- report: what each VM runs, and what an update would do"
pair "$T/a"; zvm "$T/a"
check "a radio VM on this node: an update, not a new VM; report only, exit 0" bash -c '[ "$2" = 0 ] && grep -q "== attic1 on nodea is a radio VM of this kit: an update to " "$1/out" && grep -q "^REPORT ONLY" "$1/out" && ! grep -q "qm create" "$1/out"' _ "$T/a" "$RC"
check "both VMs of the pair: which kit each runs, and which one serves" bash -c 'grep -q "OK    attic1 on nodea runs v0.0.9, not this kit$" "$1/out" && grep -q "OK    attic2 on nodeb runs v0.0.9, not this kit — it serves the radios now" "$1/out"' _ "$T/a"
check "the one that does not serve goes first" bash -c 'a=$(grep -n "WOULD send this kit into attic1" "$1/out" | cut -d: -f1); b=$(grep -n "WOULD send this kit into attic2" "$1/out" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && grep -q "(it serves: it goes last)" "$1/out"' _ "$T/a"
check "nothing was sent, nothing run: only questions to the guests" bash -c '[ "$(pieces "$1")" = 0 ] && ! grep -q "guest/install.sh" "$1/calls"' _ "$T/a"

echo "-- --run: the kit goes into each VM, and its installer runs there"
zvm "$T/a" --run
check "exit 0, and it ends saying both run this kit" bash -c '[ "$2" = 0 ] && grep -q "^== done: attic1 attic2 run " "$1/out"' _ "$T/a" "$RC"
check "the kit is sent in pieces small enough for the guest agent (at most 48 KiB a script): more than one piece per VM" bash -c 'n=$(pieces "$1"); [ "$n" -ge 4 ] && [ $((n % 2)) = 0 ] && ! grep -q "did not reach" "$1/out"' _ "$T/a"
check "…and arrives whole: the VM's kit is this kit's guest folder" bash -c 'for id in 109 110; do diff -r "$1/g/$id/root/opt/zradio/kit/guest" "$2/guest" >/dev/null || exit 1; cmp -s "$1/g/$id/root/opt/zradio/kit/gen/kit-version" "$2/gen/kit-version" || exit 1; done' _ "$T/a" "$KIT"
check "the installer runs as an update: no --conf, no --detect, no role" bash -c '[ "$(grep -c "^guest: bash /opt/zradio/kit/guest/install.sh --from-node --run > " "$1/calls")" = 2 ] && ! grep -q "guest/install.sh --conf" "$1/calls"' _ "$T/a"
check "attic1, which does not serve, is updated first" bash -c 'a=$(grep -n "^== attic1 on nodea ==" "$1/out" | cut -d: -f1); b=$(grep -n "^== attic2 on nodeb ==" "$1/out" | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ]' _ "$T/a"
check "each VM's stamp is now this kit's" bash -c 'for id in 109 110; do cmp -s "$1/g/$id/root/usr/local/lib/zradio/kit-version" "$2/gen/kit-version" || exit 1; done' _ "$T/a" "$KIT"
check "nothing of Proxmox: no qm, no pvesh outside the guest agent" bash -c '! grep -qE "^(qm|ha-manager|pvesm) " "$1/calls"' _ "$T/a"

echo "-- the same again: up to date"
: > "$T/a/calls"; zvm "$T/a" --run
check "up to date: said, exit 0, nothing sent, no installer run" bash -c '[ "$2" = 0 ] && grep -q "^== up to date: attic1 attic2 run " "$1/out" && grep -q "OK    attic1 on nodea runs this kit already" "$1/out" && [ "$(pieces "$1")" = 0 ] && ! grep -q "guest/install.sh" "$1/calls"' _ "$T/a" "$RC"
sed -i 's/^VERSION=.*/VERSION=something-else/' "$T/a/g/109/root/usr/local/lib/zradio/kit-version"; zvm "$T/a"
check "the same files under another version name: still up to date (CONTENT decides, not VERSION)" bash -c 'grep -q "^== up to date" "$1/out"' _ "$T/a"
check "…and it ends with where Home Assistant connects and the line for Home Assistant's terminal: the pair's floating address, looked up in the VM" bash -c 'grep -q "^   In Home Assistant:  Z-Wave JS → tcp://192.168.1.20:6639  ZHA → socket://192.168.1.20:6638$" "$1/out" && [ "$(tail -1 "$1/out")" = "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)\" _ --radios 192.168.1.20" ]' _ "$T/a"
sed -i 's/^CONTENT=.*/CONTENT=1111111111111111/' "$T/a/g/110/root/usr/local/lib/zradio/kit-version"; : > "$T/a/calls"; zvm "$T/a" --run
check "one VM with other files: only that one is updated" bash -c '[ "$2" = 0 ] && grep -q "^== attic2 on nodeb ==" "$1/out" && ! grep -q "^== attic1 on nodea ==" "$1/out" && [ "$(grep -c "guest/install.sh --from-node --run" "$1/calls")" = 1 ]' _ "$T/a" "$RC"

pair "$T/s"; rm -f "$T/s/g/110/bin/ip"; fake "$T/s/g/109/bin" ip 'echo "2: eth0    inet 192.168.1.20/24 scope global secondary eth0"'; zvm "$T/s" --run
check "this node's VM is the one that serves: the other node's VM is updated first" bash -c '[ "$2" = 0 ] && a=$(grep -n "^== attic2 on nodeb ==" "$1/out" | cut -d: -f1) && b=$(grep -n "^== attic1 on nodea ==" "$1/out" | cut -d: -f1) && [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$T/s" "$RC"

echo "-- a kit from before versions were kept; a failed installer"
pair "$T/o"; rm -f "$T/o/g/109/root/usr/local/lib/zradio/kit-version"; zvm "$T/o"
check "no stamp in the VM: said, and updated" bash -c 'grep -q "attic1 on nodea runs a kit from before versions were kept" "$1/out" && grep -q "WOULD send this kit into attic1" "$1/out"' _ "$T/o"
pair "$T/f"; echo 1 > "$T/f/install.rc"; zvm "$T/f" --run
check "the installer fails in the first VM: exit 1, said with the way back, and the VM that serves is NOT touched" bash -c '[ "$2" = 1 ] && grep -q "the installer ended 1 in attic1" "$1/out" && grep -q "/opt/zradio/kit.previous" "$1/out" && grep -q "The other VM was not touched" "$1/out" && [ ! -d "$1/g/110/root/opt/zradio/kit" ]' _ "$T/f" "$RC"
check "…and the failed VM does not claim the new kit" bash -c 'grep -q "^CONTENT=0000000000000000$" "$1/g/109/root/usr/local/lib/zradio/kit-version"' _ "$T/f"

echo "-- which VM; a VM that does not answer"
pair "$T/w"; zvm "$T/w" --update attic9
check "--update with a name that is no radio VM here: refused, exit 2" bash -c '[ "$2" = 2 ] && grep -q "update .attic9.: no radio VM of the kit (tag zradio) by that name on nodea" "$1/out"' _ "$T/w" "$RC"
zvm "$T/w" --name attic1
check "--name of the VM that exists: the same update" bash -c '[ "$2" = 0 ] && grep -q "is a radio VM of this kit: an update" "$1/out"' _ "$T/w" "$RC"
zvm "$T/w" --name attic5 --initial-role primary --vip 192.168.1.21 --no-pair --vmid 150
check "--name of a VM that does not exist: a new VM, not an update" bash -c '! grep -q "an update to" "$1/out" && grep -q "WOULD qm create" "$1/out"' _ "$T/w"
: > "$T/w/agent-down-110"; zvm "$T/w" --run
check "the other VM does not answer: refused before anything is sent, with how to start it" bash -c '[ "$2" = 1 ] && grep -q "attic2 on nodeb does not answer (its guest agent): start it first" "$1/out" && [ "$(pieces "$1")" = 0 ]' _ "$T/w" "$RC"
finish
