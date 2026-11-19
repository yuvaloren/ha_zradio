#!/usr/bin/env bash
# t-update.sh — ./install.sh on a node whose radio VM exists: the update of the pair to this kit (host/update.sh),
# against the fake cluster of tests/fake-node.sh. The guests are canned: the kit really is sent into them in pieces
# and unpacked, and the version stamp really is compared; the kit's installer in them is canned (it "succeeds" by
# installing the stamp it was sent). tests/t-e2e.sh runs the real installer in an update.
. "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"

pair() { # pair <dir> [nohook]: attic1 (109) on nodea, this node, and attic2 (110) on nodeb, both running an older kit; attic2
  # serves. Each node has the kit's hookscript and its VM has it — or, with nohook, neither: a pair of 0.1.0, from before it
  local d=$1 id node name R
  node "$d"
  [ "${2:-}" = nohook ] || cp "$KIT/host/hook.sh" "$d/store/snippets/zradio-hook.sh"
  for x in "109 nodea attic1" "110 nodeb attic2"; do
    read -r id node name <<< "$x"; R="$d/g/$id/root"
    PATH="$d/bin:$PATH" pvesh create "/nodes/$node/qemu/$id/agent/exec" --command bash --input-data true > /dev/null   # the canned guest
    printf '%s\n' "NAME=$name" VIP=192.168.1.20/24 VRID=50 PRIORITY=100 > "$R/etc/zradio/zradio.conf"
    mkdir -p "$R/usr/local/lib/zradio"; printf 'VERSION=v0.0.9\nCONTENT=0000000000000000\n' > "$R/usr/local/lib/zradio/kit-version"
    python3 -c 'import json, sys; v = json.load(open(sys.argv[1])); v.append({"vmid": int(sys.argv[2]), "name": sys.argv[3], "node": sys.argv[4], "status": "running", "tags": "zradio", "type": "qemu"}); json.dump(v, open(sys.argv[1], "w"))' "$d/vms.json" "$id" "$name" "$node"
    vmconf "$d" "$node/$id" "name: $name" "cicustom: user=local:snippets/$name-zradio.yaml" "usb0: mapping=zradio-10c4ea70" "usb1: mapping=zradio-10c4ea60" "tags: zradio"
    [ "${2:-}" = nohook ] || echo "hookscript: local:snippets/zradio-hook.sh" >> "$d/pve/nodes/$node/qemu-server/$id.conf"
  done
  echo '[{"id":"zradio-10c4ea70","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70"]},{"id":"zradio-10c4ea60","map":["node=nodea,id=10c4:ea60","node=nodeb,id=10c4:ea60"]}]' > "$d/usbmap.json"
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
sed -i '/^usb/d' "$T/w/pve/nodes/nodea/qemu-server/109.conf"          # (attic1's sticks out of the way: this one is about the name)
zvm "$T/w" --name attic5 --initial-role primary --vip 192.168.1.21 --no-pair --vmid 150
check "--name of a VM that does not exist: a new VM, not an update" bash -c '! grep -q "an update to" "$1/out" && grep -q "WOULD qm create" "$1/out"' _ "$T/w"
: > "$T/w/agent-down-110"; zvm "$T/w" --run
check "the other VM does not answer: refused before anything is sent, with how to start it" bash -c '[ "$2" = 1 ] && grep -q "attic2 on nodeb does not answer (its guest agent): start it first" "$1/out" && [ "$(pieces "$1")" = 0 ]' _ "$T/w" "$RC"

echo "-- a second try after a failed update keeps the kit to go back to"
pair "$T/k"; for id in 109 110; do mkdir -p "$T/k/g/$id/root/opt/zradio/kit/gen"; echo "the kit that works" > "$T/k/g/$id/root/opt/zradio/kit/marker"; echo "CONTENT=0000000000000000" > "$T/k/g/$id/root/opt/zradio/kit/gen/kit-version"; done
echo 1 > "$T/k/install.rc"; zvm "$T/k" --run
check "the first failed try: the kit the VM had is kit.previous" bash -c '[ "$2" = 1 ] && [ "$(cat "$1/g/109/root/opt/zradio/kit.previous/marker")" = "the kit that works" ] && [ ! -e "$1/g/109/root/opt/zradio/kit/marker" ]' _ "$T/k" "$RC"
zvm "$T/k" --run
check "the second try with the same kit: kit.previous is still the kit that works, not the one that just failed" bash -c '[ "$2" = 1 ] && [ "$(cat "$1/g/109/root/opt/zradio/kit.previous/marker" 2>/dev/null)" = "the kit that works" ] && [ -f "$1/g/109/root/opt/zradio/kit/guest/install.sh" ]' _ "$T/k" "$RC"

echo "-- a pair from before the hookscript (0.1.0): this node's part comes first, and needs no answer from a VM"
stale() { printf 'VERSION=x\nCONTENT=%s\n' "$(sed -n 's/^CONTENT=//p' "$KIT/gen/kit-version")" > "$1/g/$2/root/usr/local/lib/zradio/kit-version"; }     # that VM's kit is this kit already
pair "$T/h" nohook; stale "$T/h" 109; stale "$T/h" 110; zvm "$T/h"
check "report: the hookscript it would put on this node and attach to this node's VM; nothing is changed" bash -c '[ "$2" = 0 ] && grep -q "WOULD put the kit.s hookscript on nodea: $1/store/snippets/zradio-hook.sh" "$1/out" && grep -q "WOULD qm set 109 --hookscript local:snippets/zradio-hook.sh" "$1/out" && grep -q "^REPORT ONLY" "$1/out" && ! grep -q "^== up to date" "$1/out" && [ ! -e "$1/store/snippets/zradio-hook.sh" ] && ! grep -q "^qm " "$1/calls"' _ "$T/h" "$RC"
check "…and the other node's VM has none either: said, with what to do there (a node keeps its own copy)" bash -c 'grep -q "NOTE  attic2 on nodeb does not have the kit.s hookscript yet: a node keeps its own copy, so run ./install.sh on nodeb too" "$1/out"' _ "$T/h"
zvm "$T/h" --run
check "--run: the hookscript is on the node (the kit's file, executable) and on the VM; the VMs' kits were current, so nothing was sent" bash -c '[ "$2" = 0 ] && cmp -s "$1/store/snippets/zradio-hook.sh" "$3/host/hook.sh" && [ -x "$1/store/snippets/zradio-hook.sh" ] && grep -qx "qm set 109 --hookscript local:snippets/zradio-hook.sh" "$1/calls" && grep -qx "hookscript: local:snippets/zradio-hook.sh" "$1/pve/nodes/nodea/qemu-server/109.conf" && [ "$(pieces "$1")" = 0 ] && grep -q "^== up to date" "$1/out"' _ "$T/h" "$RC" "$KIT"
check "…the other node's VM was not touched: its hookscript is its node's to set" bash -c '! grep -q "^qm set 110" "$1/calls" && ! grep -q hookscript "$1/pve/nodes/nodeb/qemu-server/110.conf"' _ "$T/h"
: > "$T/h/calls"; zvm "$T/h" --run
check "the same again: all there, nothing done" bash -c '[ "$2" = 0 ] && grep -q "OK    the kit.s hookscript is on nodea" "$1/out" && grep -q "OK    attic1 has the kit.s hookscript" "$1/out" && ! grep -q "^qm " "$1/calls"' _ "$T/h" "$RC"
echo "# an older hookscript" > "$T/h/store/snippets/zradio-hook.sh"; zvm "$T/h" --run
check "the node's copy is another file than the kit's: replaced" bash -c '[ "$2" = 0 ] && cmp -s "$1/store/snippets/zradio-hook.sh" "$3/host/hook.sh"' _ "$T/h" "$RC" "$KIT"
FAKE_NODE=nodeb zvm "$T/h" --run
check "the same on the other node: its copy, its VM" bash -c '[ "$2" = 0 ] && grep -qx "qm set 110 --hookscript local:snippets/zradio-hook.sh" "$1/calls" && grep -q "^== up to date" "$1/out" && ! grep -q "does not have the kit.s hookscript" "$1/out"' _ "$T/h" "$RC"

pair "$T/d" nohook; stale "$T/d" 110; : > "$T/d/agent-down-109"; sed -i 's/"name": "attic1", "node": "nodea", "status": "running"/"name": "attic1", "node": "nodea", "status": "stopped"/' "$T/d/vms.json"; zvm "$T/d" --run
check "this node's VM is stopped (its start found no stick, and there was no hookscript to wait): the hookscript is put on it all the same, exit 0" bash -c '[ "$2" = 0 ] && grep -qx "qm set 109 --hookscript local:snippets/zradio-hook.sh" "$1/calls" && [ -x "$1/store/snippets/zradio-hook.sh" ]' _ "$T/d" "$RC"
check "…and it says that the VM's kit was not looked at, and how to start it" bash -c 'grep -q "NOTE  attic1 on nodea is not running: which kit it holds was not looked at. Start it (qm start 109 on nodea), then this again" "$1/out" && grep -q "^== done on nodea; not looked at, because not running: attic1 ==" "$1/out"' _ "$T/d"

echo "-- stick power on a VM that exists"
pair "$T/e"; stale "$T/e" 109; stale "$T/e" 110; zvm "$T/e" --stick-power 1-3:2 --stick-power 2-4:2 --run
check "--stick-power: this VM's conf beside the hookscript; the VM keeps running, nothing is switched" bash -c '[ "$2" = 0 ] && grep -qx "POWER_PORTS=1-3:2 2-4:2" "$1/store/snippets/zradio-hook-109.conf" && [ "$(cat "$1/sys/1-3:1.0/1-3-port2/disable")" = 0 ] && ! grep -q "^qm " "$1/calls"' _ "$T/e" "$RC"
echo "WAIT=200" >> "$T/e/store/snippets/zradio-hook-109.conf"; zvm "$T/e" --run
check "a later run without the option: the ports stay, said" bash -c '[ "$2" = 0 ] && grep -q "OK    stick power: attic1.s ports are 1-3:2 2-4:2" "$1/out" && grep -qx "POWER_PORTS=1-3:2 2-4:2" "$1/store/snippets/zradio-hook-109.conf"' _ "$T/e" "$RC"
zvm "$T/e" --stick-power 1-3:2 --run
check "other ports: written, and a WAIT someone set in the conf is kept" bash -c '[ "$2" = 0 ] && grep -qx "POWER_PORTS=1-3:2" "$1/store/snippets/zradio-hook-109.conf" && grep -qx "WAIT=200" "$1/store/snippets/zradio-hook-109.conf"' _ "$T/e" "$RC"
zvm "$T/e" --no-stick-power --run
check "--no-stick-power: no ports any more, WAIT kept" bash -c '[ "$2" = 0 ] && ! grep -q POWER_PORTS "$1/store/snippets/zradio-hook-109.conf" && grep -qx "WAIT=200" "$1/store/snippets/zradio-hook-109.conf"' _ "$T/e" "$RC"
pair "$T/e2" nohook; zvm "$T/e2" --stick-power 1:4 --run
check "a port this VM's sticks do not hang off: refused before anything, the hookscript included" bash -c '[ "$2" = 1 ] && grep -q "the stick at 1-3.2.1 is below none of them" "$1/out" && [ ! -e "$1/store/snippets/zradio-hook.sh" ] && ! grep -q "^qm " "$1/calls" && [ "$(pieces "$1")" = 0 ]' _ "$T/e2" "$RC"
pair "$T/e3"; echo '[{"storage":"local","type":"dir","content":"images,iso","path":"'"$T/e3"'/store"}]' > "$T/e3/storages.json"; zvm "$T/e3" --run
check "the storage of the VM's cloud-init file holds no snippets any more: refused, with the option that names another" bash -c '[ "$2" = 2 ] && grep -q "die: the storage .local. holds no snippets on nodea" "$1/out"' _ "$T/e3" "$RC"

echo "-- the sticks of a pair of 0.1.0 are named through USB mappings: named directly (host=) on a stopped VM, so that it starts with or without them"
pair "$T/u1"; zvm "$T/u1"
check "report, and the VM runs: its stick lines are left (a change would unplug the sticks), and it is said what to do, in order" bash -c '[ "$2" = 0 ] && ! grep -q "qm set 109 --usb" "$1/out" && grep -q "NOTE  attic1 names 2 stick(s) through USB mappings and runs: Proxmox will refuse its next start if a stick is not on nodea then. This installer names them directly (host=) while attic1 is stopped: qm shutdown 109, then ./install.sh again, then qm start 109 — the VM that does not serve first" "$1/out"' _ "$T/u1" "$RC"
zvm "$T/u1" --run
check "--run on the running VM: no usb line is touched" bash -c '! grep -q "^qm set 109 --usb" "$1/calls" && grep -q "^usb0: mapping=zradio-10c4ea70$" "$1/pve/nodes/nodea/qemu-server/109.conf"' _ "$T/u1"
stopped() { : > "$1/agent-down-109"; sed -i 's/"name": "attic1", "node": "nodea", "status": "running"/"name": "attic1", "node": "nodea", "status": "stopped"/' "$1/vms.json"; }
pair "$T/u2"; stopped "$T/u2"; zvm "$T/u2"
check "the VM is stopped, report: it says the two lines it would set" bash -c 'grep -q "WOULD qm set 109 --usb0 host=10c4:ea70" "$1/out" && grep -q "WOULD qm set 109 --usb1 host=10c4:ea60" "$1/out" && ! grep -q "^qm " "$1/calls"' _ "$T/u2"
zvm "$T/u2" --run
check "--run: each stick by its id; the other node's VM and the mappings themselves are not touched" bash -c '[ "$2" = 0 ] && grep -qx "qm set 109 --usb0 host=10c4:ea70" "$1/calls" && grep -qx "qm set 109 --usb1 host=10c4:ea60" "$1/calls" && ! grep -q "^qm set 110 --usb\|^pvesh \(set\|create\|delete\) /cluster/mapping" "$1/calls"' _ "$T/u2" "$RC"
: > "$T/u2/calls"; zvm "$T/u2" --run
check "the same again: nothing to change, and said" bash -c '! grep -q "^qm set 109 --usb" "$1/calls" && grep -q "OK    attic1.s sticks are named directly (host=): it starts with or without them" "$1/out"' _ "$T/u2"
pair "$T/u3"; stopped "$T/u3"
echo '[{"id":"zradio-10c4ea60-1","map":["node=nodea,id=10c4:ea60,path=1-3.2.1"]},{"id":"zradio-10c4ea60-2","map":["node=nodea,id=10c4:ea60,path=1-3.2.4"]},{"id":"zwave","map":["node=nodea,id=10c4:ea70"]}]' > "$T/u3/usbmap.json"
vmconf "$T/u3" nodea/109 "name: attic1" "cicustom: user=local:snippets/attic1-zradio.yaml" "usb0: mapping=zradio-10c4ea60-1,usb3=1" "usb1: mapping=zradio-10c4ea60-2" "usb2: mapping=zwave" "hookscript: local:snippets/zradio-hook.sh" "tags: zradio"
zvm "$T/u3" --run
check "two sticks of one id (mappings with a port): each by its socket, and the line's other settings stay" bash -c 'grep -qx "qm set 109 --usb0 host=1-3.2.1,usb3=1" "$1/calls" && grep -qx "qm set 109 --usb1 host=1-3.2.4" "$1/calls"' _ "$T/u3"
check "a USB mapping the kit did not make (--usb-mapping): left as it is, and said what that means for a start" bash -c '! grep -q "^qm set 109 --usb2" "$1/calls" && grep -q "NOTE  attic1.s usb2 is the USB mapping zwave, which the kit did not make: left as it is. Proxmox refuses a start of attic1 while that stick is not on nodea" "$1/out"' _ "$T/u3"

echo "-- the hookscript's helper on a VM that runs already (a VM that starts gets it from its post-start)"
pair "$T/v1"; zvm "$T/v1" --stick-power 1-3:2 --stick-power 2-4:2
check "report with stick power: it would start the helper" bash -c 'grep -q "WOULD start attic1.s helper on nodea (zradio-heal-109.service): it switches the sticks. power off and on when attic1 asks, 3 times a day at most" "$1/out" && ! grep -q "^systemd-run" "$1/calls"' _ "$T/v1"
zvm "$T/v1" --stick-power 1-3:2 --stick-power 2-4:2 --run
check "--run: started through the hookscript's own post-start, as a unit of the node" bash -c '[ "$2" = 0 ] && grep -q "^systemd-run --quiet --collect --unit zradio-heal-109 .*/store/snippets/zradio-hook.sh 109 heal$" "$1/calls" && grep -q "DONE  attic1.s helper on nodea (zradio-heal-109.service)" "$1/out"' _ "$T/v1" "$RC"
: > "$T/v1/calls"; zvm "$T/v1" --run
check "the same again: it runs, nothing is started" bash -c '! grep -q "^systemd-run\|^systemctl stop" "$1/calls" && grep -q "OK    attic1.s helper runs on nodea (zradio-heal-109.service)" "$1/out"' _ "$T/v1"
echo "# an older hookscript" > "$T/v1/store/snippets/zradio-hook.sh"; : > "$T/v1/calls"; zvm "$T/v1" --run
check "a new hookscript: the helper that runs the old one is stopped and started again" bash -c 'a=$(grep -n "^systemctl stop zradio-heal-109.service" "$1/calls" | cut -d: -f1); b=$(grep -n "^systemd-run .*zradio-heal-109 " "$1/calls" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$T/v1"
pair "$T/v2"; zvm "$T/v2" --run
check "no stick power: no helper (it would have nothing to switch)" bash -c '! grep -q "^systemd-run" "$1/calls" && ! grep -q "helper" "$1/out"' _ "$T/v2"
pair "$T/v3"; : > "$T/v3/no-helper"; zvm "$T/v3" --stick-power 1-3:2 --stick-power 2-4:2 --run
check "the helper does not start: a NOTE that says what is missing until the VM's next start; the update is not failed over it" bash -c '[ "$2" = 0 ] && grep -q "NOTE  attic1.s helper did not start on nodea" "$1/out"' _ "$T/v3" "$RC"
pair "$T/v4"; stopped "$T/v4"; zvm "$T/v4" --stick-power 1-3:2 --stick-power 2-4:2 --run
check "a stopped VM: no helper now (its start brings it)" bash -c '! grep -q "^systemd-run" "$1/calls"' _ "$T/v4"
finish
