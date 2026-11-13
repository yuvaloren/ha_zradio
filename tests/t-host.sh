#!/usr/bin/env bash
# t-host.sh — ./install.sh against a fake Proxmox cluster (tests/fake-node.sh): every option, question, refusal and
# failure of the node's side. The guests are canned here; tests/t-e2e.sh runs the kit's real installer in them.
# Real: install.sh, the kit's stick table and guest folder, tar/base64, python3 + PyYAML (the cloud-init file is
# parsed, and the kit inside it is unpacked and compared with guest/). No VM is made anywhere.
. "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"
BASE=(--name zr2 --initial-role standby --self 10.20.30.6/24 --peer 10.20.30.5 --vip 10.20.30.50/24 --pair-bridge vmbrpair)

echo "-- sticks: what the node has that the kit knows"
node "$T/s"; zvm "$T/s" --sticks
check "both sticks listed by port and id, with the kinds the table gives them; the keyboard is not" bash -c '[ "$2" = 0 ] && grep -q "1-3.2.1 *10c4:ea70 .*CP2105" "$1/out" && grep -q "1-3.2.4 *10c4:ea60 .*zigbee.*Sonoff" "$1/out" && ! grep -q keyboard "$1/out" && ! grep -q "USB mapping" "$1/out"' _ "$T/s" "$RC"
echo '[{"id":"zwave","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70"]},{"id":"elsewhere","map":["node=nodeb,id=10c4:ea60"]}]' > "$T/s/usbmap.json"; zvm "$T/s" --sticks
check "a mapping that names the stick on THIS node is shown; one for another node only is not" bash -c 'grep -q "10c4:ea70 .*(USB mapping: zwave)" "$1/out" && ! grep -q "10c4:ea60 .*USB mapping" "$1/out"' _ "$T/s"
check "sticks changes nothing" bash -c '[ ! -s "$1/calls" ]' _ "$T/s"
node "$T/s0" none; zvm "$T/s0" --sticks
check "no stick: exit 1, and how a stick the table does not know is passed through" bash -c '[ "$2" = 1 ] && grep -q "use --usb-mapping" "$1/out"' _ "$T/s0" "$RC"

echo "-- create, report mode: everything is said, nothing is done"
node "$T/r"; zvm "$T/r" "${BASE[@]}"
check "exit 0, REPORT ONLY, no qm / pvesh / ha-manager / wget call, no file written" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && [ ! -s "$1/calls" ] && [ -z "$(ls "$1/store/snippets")" ]' _ "$T/r" "$RC"
check "it says the two USB mappings it would make, the VM, the HA resource, the strict rule and the start — in that order" bash -c '
  o=$(grep -n "WOULD" "$1/out"); l() { printf "%s\n" "$o" | grep -m1 -- "$1" | cut -d: -f1; }
  a=$(l "pvesh create /cluster/mapping/usb --id zradio-10c4ea70 --map node=nodea,id=10c4:ea70"); b=$(l "pvesh create /cluster/mapping/usb --id zradio-10c4ea60 --map node=nodea,id=10c4:ea60")
  c=$(l "qm create 109 --name zr2"); e=$(l "ha-manager add vm:109 --state stopped --max_restart 3 --max_relocate 0"); f=$(l "ha-manager rules add node-affinity zr2-on-nodea --resources vm:109 --nodes nodea --strict 1"); g=$(l "ha-manager set vm:109 --state started")
  [ -n "$a" ] && [ -n "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$e" ] && [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ]' _ "$T/r"
check "the VM as it would be: both networks, both sticks, onboot" bash -c 'grep "WOULD qm create" "$1/out" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=dhcp --net1 virtio,bridge=vmbrpair --ipconfig1 ip=10.20.30.6/24 .*--onboot 1 .*--usb0 mapping=zradio-10c4ea70 --usb1 mapping=zradio-10c4ea60"' _ "$T/r"

echo "-- create --run on a clean node"
node "$T/c"; zvm "$T/c" "${BASE[@]}" --run
check "exit 0" eq "$RC" 0
check "the calls, in order: mappings, VM, disk, HA resource stopped, the strict rule, only then started" bash -c '
  n() { grep -n -m1 -- "$1" "$2/calls" | cut -d: -f1; }
  a=$(n "^pvesh create /cluster/mapping/usb --id zradio-10c4ea70" "$1"); b=$(n "^qm create 109 " "$1"); c=$(n "^qm set 109 --scsi0 local-zfs:0,import-from=.*debian-13-generic-amd64.qcow2,discard=on" "$1"); d=$(n "^qm disk resize 109 scsi0 8G" "$1")
  e=$(n "^ha-manager add vm:109 --state stopped" "$1"); f=$(n "^ha-manager rules add node-affinity zr2-on-nodea .*--strict 1" "$1"); g=$(n "^ha-manager set vm:109 --state started" "$1")
  [ -n "$a" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ] && ! grep -q "^qm start" "$1/calls"' _ "$T/c"
check "the image in the cache is used: nothing downloaded" bash -c '! grep -q "^wget" "$1/calls"' _ "$T/c"
Y="$T/c/store/snippets/zr2-zradio.yaml"
check "the cloud-init file parses; root over keys only; the agent package; the hostname" python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert open(sys.argv[1]).readline().strip() == "#cloud-config"
assert d["hostname"] == "zr2" and d["ssh_pwauth"] is False and d["packages"] == ["qemu-guest-agent"]
assert d["users"][0]["name"] == "root" and d["users"][0]["ssh_authorized_keys"] == [open(sys.argv[2]).read().strip()]' "$Y" "$T/c/keys"
check "…the VM's zradio.conf: exactly the six values, checked by the kit's own loader" bash -c '
  python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print([f for f in d[\"write_files\"] if f[\"path\"] == \"/root/zradio.conf\"][0][\"content\"], end=\"\")" "$1" > "$2/zradio.conf"
  [ "$(grep -v "^#" "$2/zradio.conf" | tr "\n" " ")" = "NAME=zr2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 " ] &&
  ZRADIO_CONF="$2/zradio.conf" bash -c ". \"$3/guest/lib/zradio-common.sh\"; zr_load_conf"' _ "$Y" "$T/c" "$KIT"
check "…the kit inside it unpacks to the same files as guest/ here (and the example conf), nothing else" bash -c '
  python3 -c "import sys, yaml, base64; d = yaml.safe_load(open(sys.argv[1])); f = [f for f in d[\"write_files\"] if f[\"path\"] == \"/root/zradio-kit.tgz\"][0]; assert f[\"encoding\"] == \"b64\"; sys.stdout.buffer.write(base64.b64decode(f[\"content\"]))" "$1" > "$2/kit.tgz"
  mkdir -p "$2/unpacked" && tar -xzf "$2/kit.tgz" -C "$2/unpacked" && diff -r "$2/unpacked/guest" "$3/guest" && cmp -s "$2/unpacked/zradio.conf.example" "$3/zradio.conf.example" && [ "$(ls "$2/unpacked" | tr "\n" " ")" = "guest zradio.conf.example " ]' _ "$Y" "$T/c" "$KIT"
check "…and cloud-init runs nothing of the kit: the node's install.sh does, through the guest agent" python3 -c '
import sys, yaml
assert yaml.safe_load(open(sys.argv[1]))["runcmd"] == [["systemctl", "enable", "--now", "qemu-guest-agent"]]' "$Y"
if command -v cloud-init >/dev/null 2>&1; then
  check "…and the real cloud-init accepts the file (cloud-init schema)" bash -c 'cloud-init schema --config-file "$1" 2>&1 | grep -q "^Valid schema"' _ "$Y"
else echo "  (cloud-init is not installed here: its schema check of the file is skipped)"; fi
check "the VM carries that file, the tag and a description that says what it is" bash -c 'grep "^qm create" "$1/calls" | grep -q -- "--cicustom user=local:snippets/zr2-zradio.yaml .*--tags zradio --description zr2: one radio VM of a zradio pair"' _ "$T/c"
check "the kit is unpacked in the VM and its installer run there, through the guest agent — as the initial standby, with its log and exit code kept" bash -c '
  n() { grep -n -m1 -F -- "$1" "$2/calls" | cut -d: -f1; }
  a=$(n "guest: cloud-init status" "$1"); b=$(n "guest: mkdir -p /opt/zradio/kit && tar -xzf /root/zradio-kit.tgz -C /opt/zradio/kit" "$1")
  c=$(n "guest: bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role standby > /var/log/zradio-install.log 2>&1; echo \$? > /root/zradio-install.rc" "$1")
  [ -n "$a" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]' _ "$T/c"
check "…the kit really is in the VM: the files cloud-init put there unpack to guest/install.sh" bash -c 'cmp -s "$1/g/109/root/opt/zradio/kit/guest/install.sh" "$2/guest/install.sh" && grep -q "^NAME=zr2$" "$1/g/109/root/root/zradio.conf"' _ "$T/c" "$KIT"
check "the installer's lines are shown as it runs, each once" bash -c 'grep -c "| DONE  the radios are detected and named" "$1/out" | grep -qx 1 && grep -q "| OK    keepalived 2.3.3 installed" "$1/out" && grep -q "the kit is installed in zr2, as the initial standby" "$1/out"' _ "$T/c"
check "what the VM found is said, and where Home Assistant connects — one line per kind of stick" bash -c 'grep -q "zr2.s radios: Z-Wave yes, Zigbee yes" "$1/out" && grep -q "Z-Wave JS → tcp://10.20.30.50:6639  ZHA → socket://10.20.30.50:6638" "$1/out"' _ "$T/c"
check "without --start it is NOT put into the pair, and the command that does it is said" bash -c 'grep -q "NOTE  zr2 is installed and not started. To start it: qm guest exec 109 -- systemctl start zradio.target" "$1/out" && ! grep -q "guest: systemctl start zradio.target" "$1/calls"' _ "$T/c"
check "the first VM of a pair: no pairing step, and the next thing to do is said" bash -c '! grep -q "zradio-sync" "$1/calls" && grep -q "Next: ./install.sh on the other node" "$1/out"' _ "$T/c"

echo "-- one kind of stick only"
node "$T/k"; printf 'ZWAVE=synced\nZIGBEE=none\n' > "$T/k/radios.conf"; zvm "$T/k" "${BASE[@]}" --run
check "a VM that found only a Z-Wave stick: installed, said, and only the Z-Wave line for Home Assistant" bash -c '[ "$2" = 0 ] && grep -q "radios: Z-Wave yes, Zigbee none" "$1/out" && grep -q "Z-Wave JS → tcp://10.20.30.50:6639$" "$1/out" && ! grep -q "ZHA" "$1/out"' _ "$T/k" "$RC"
node "$T/k2" zwave; printf 'ZWAVE=none\nZIGBEE=served\n' > "$T/k2/radios.conf"; zvm "$T/k2" "${BASE[@]}" --conf ZIGBEE_PORT=7000 --run
check "one stick on the node: one USB mapping, one usb line; only Zigbee found: only the ZHA line, on the port of --conf" bash -c '[ "$2" = 0 ] && grep "^qm create" "$1/calls" | grep -q -- "--usb0 mapping=zradio-10c4ea70 --tags" && grep -q "radios: Z-Wave none, Zigbee yes" "$1/out" && grep -q "ZHA → socket://10.20.30.50:7000" "$1/out" && ! grep -q "Z-Wave JS" "$1/out"' _ "$T/k2" "$RC"

echo "-- options"
node "$T/o"; zvm "$T/o" "${BASE[@]/standby/primary}" --run --start --first --hookscript local:snippets/my-hook.sh --conf SYNC_TZ=Europe/Berlin --conf ELECTION=observe --vmid 150 --priority 110 --vrid 77 --pair-mac BC:24:11:0A:63:36 --memory 1024 --cores 1 --disk 12G
check "--start joins the pair after the install; --first reaches the kit's installer in the VM" bash -c '[ "$2" = 0 ] && grep -q "guest: systemctl start zradio.target" "$1/calls" && grep -q "guest: bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role primary --first > " "$1/calls" && grep -q "it is in the pair" "$1/out"' _ "$T/o" "$RC"
check "--hookscript, --vmid, --pair-mac, --memory, --cores, --disk reach qm" bash -c 'grep "^qm create 150 " "$1/calls" | grep -q -- "--cores 1 --memory 1024 .*--net1 virtio=BC:24:11:0A:63:36,bridge=vmbrpair .*--hookscript local:snippets/my-hook.sh" && grep -q "^qm disk resize 150 scsi0 12G" "$1/calls"' _ "$T/o"
check "--conf lines, --priority and --vrid reach zradio.conf" bash -c 'grep -q "^      SYNC_TZ=Europe/Berlin$" "$1" && grep -q "^      ELECTION=observe$" "$1" && grep -q "^      PRIORITY=110$" "$1" && grep -q "^      VRID=77$" "$1"' _ "$T/o/store/snippets/zr2-zradio.yaml"
node "$T/o2"; zvm "$T/o2" --name zr2 --initial-role standby --self 192.0.2.6/24 --peer 192.0.2.5 --vip 192.0.2.50/24 --gateway 192.0.2.1 --no-ha --run
check "no --pair-bridge: one interface, --self on the LAN with the gateway" bash -c '[ "$2" = 0 ] && grep "^qm create" "$1/calls" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=192.0.2.6/24,gw=192.0.2.1 --serial0" && ! grep -q "net1" "$1/calls"' _ "$T/o2" "$RC"
check "--no-ha: a plain qm start, no ha-manager call" bash -c 'grep -q "^qm start 109" "$1/calls" && ! grep -q "^ha-manager" "$1/calls"' _ "$T/o2"
zvm "$T/o2" --name zr3 --initial-role standby --self 192.0.2.6/24 --peer 192.0.2.5 --vip 192.0.2.50/24
check "no --pair-bridge and no --gateway: refused before anything (exit 2)" bash -c '[ "$2" = 2 ] && grep -q "gateway A.B.C.D is needed" "$1/out"' _ "$T/o2" "$RC"

echo "-- primary or standby: the one thing the tool will not guess"
NOROLE=(--name zr2 --self 10.20.30.6/24 --peer 10.20.30.5 --vip 10.20.30.50/24 --pair-bridge vmbrpair)
node "$T/q1"; zvm "$T/q1" "${NOROLE[@]}" --run
check "no --initial-role and nobody to ask: refused before anything, with what each role means for the node's radios — and that it is only for the start" bash -c '[ "$2" = 2 ] && grep -q "what this node is INITIALLY" "$1/out" && grep -q "the two swap later" "$1/out" && grep -q "role primary (its radios are configured" "$1/out" && grep -q "role standby (its radios will be wiped" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/q1" "$RC"
node "$T/q2"; zvm "$T/q2" "${NOROLE[@]}" --initial-role standby --run
check "--initial-role standby: said in capitals that the sticks WILL BE OVERWRITTEN; the installer in the VM is told; priority 100" bash -c '[ "$2" = 0 ] && grep -q "NOTE  this node starts as the STANDBY: its sticks WILL BE OVERWRITTEN" "$1/out" && grep -q "install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role standby > " "$1/calls" && grep -q "^      PRIORITY=100$" "$1/store/snippets/zr2-zradio.yaml" && grep -q "installed in zr2, as the initial standby" "$1/out"' _ "$T/q2" "$RC"
node "$T/q3"; zvm "$T/q3" "${NOROLE[@]}" --initial-role primary --run
check "--initial-role primary: its sticks stay as they are; the installer is told; priority 110 (it wins a tie)" bash -c '[ "$2" = 0 ] && grep -q "OK    this node starts as the PRIMARY: its sticks hold your networks and stay as they are" "$1/out" && grep -q -- "--run --detect --initial-role primary > " "$1/calls" && grep -q "^      PRIORITY=110$" "$1/store/snippets/zr2-zradio.yaml"' _ "$T/q3" "$RC"
node "$T/q4"; zvm "$T/q4" "${NOROLE[@]}" --initial-role primary --priority 77 --run
check "--priority said: it is the one used" bash -c 'grep -q "^      PRIORITY=77$" "$1/store/snippets/zr2-zradio.yaml"' _ "$T/q4"
node "$T/q5"; zvm "$T/q5" "${NOROLE[@]}" --initial-role standby --first --run
check "--initial-role standby with --first: refused (a standby is filled by the sync)" bash -c '[ "$2" = 2 ] && grep -q "first is for the initial primary of a new house" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/q5" "$RC"
node "$T/q6"; zvm "$T/q6" "${NOROLE[@]}" --initial-role both --run
check "--initial-role that is neither: refused" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/q6" "$RC"
node "$T/q7"; ask "$T/q7" "${NOROLE[@]}" --run <<< 'standby'
check "someone is there: asked what the node is INITIALLY (the two swap), in the words that matter (configured / WILL BE WIPED); 'standby' is the standby" bash -c '[ "$2" = 0 ] && grep -q "Is this node INITIALLY the primary or the standby of the pair?" "$1/out" && grep -q "the two are equals and swap" "$1/out" && grep -q "primary  its radios are configured" "$1/out" && grep -q "standby  its radios WILL BE WIPED" "$1/out" && grep -q -- "--detect --initial-role standby > " "$1/calls"' _ "$T/q7" "$RC"
node "$T/q8"; ask "$T/q8" "${NOROLE[@]}" --run <<< $'dunno\nPrimary\nn'
check "an answer that is neither is asked again; a primary is asked whether its sticks hold the networks — 'n' is a new house (--first)" bash -c '[ "$2" = 0 ] && [ "$(grep -o "primary or standby: " "$1/out" | wc -l)" = 2 ] && grep -q "already hold your Z-Wave / Zigbee networks" "$1/out" && grep -q -- "--detect --initial-role primary --first > " "$1/calls" && grep -q "starts as the PRIMARY: a new house" "$1/out"' _ "$T/q8" "$RC"
node "$T/q9"; ask "$T/q9" "${NOROLE[@]}" --run <<< $'p\n'
check "…Enter there: the sticks hold the networks (no --first)" bash -c '[ "$2" = 0 ] && grep -q -- "--detect --initial-role primary > " "$1/calls"' _ "$T/q9" "$RC"
node "$T/q10"; ask "$T/q10" "${NOROLE[@]}" --run < /dev/null
check "no answer at all: refused, nothing made" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/q10" "$RC"

echo "-- the second node: everything from the first VM, and the two introduced to each other"
node "$T/j"; peer_vm "$T/j" 120 zradio1 primary; zvm "$T/j"
check "no option at all, report mode: the first VM is found by its tag and read through its guest agent; nothing is changed" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && ! grep -qE "^(qm|pvesh|ha-manager|wget) " "$1/calls" && grep -q "^guest: cat /etc/zradio/zradio.conf" "$1/calls" && [ -z "$(ls "$1/store/snippets")" ]' _ "$T/j" "$RC"
check "…this VM would be zradio2, with the addresses swapped, on the first VM's bridges, the initial STANDBY (the first is the primary)" bash -c 'grep "WOULD qm create 109 --name zradio2 " "$1/out" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=dhcp --net1 virtio,bridge=vmbrpair --ipconfig1 ip=10.20.30.6/24" && grep -q "NAME=zradio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=61 PRIORITY=100" "$1/out" && grep -q "starts as the STANDBY: its sticks WILL BE OVERWRITTEN" "$1/out" && grep -q "WOULD introduce zradio2 and zradio1 (nodeb) to each other" "$1/out"' _ "$T/j"
zvm "$T/j" --run --start
check "--run: built, installed as the initial standby, exit 0" bash -c '[ "$2" = 0 ] && grep -q "guest: bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role standby > " "$1/calls" && grep -q "^      VRID=61$" "$1/store/snippets/zradio2-zradio.yaml"' _ "$T/j" "$RC"
check "each VM is given the OTHER's sync key and host key (zradio-sync trust), on its own node" bash -c 'grep -q "^trust --sync-key ssh-ed25519 SyncKeyOfVm109A* --host-key ssh-ed25519 HostKeyOfVm109A*$" "$1/g/120/trusted" && grep -q "^trust --sync-key ssh-ed25519 SyncKeyOfVm120A* --host-key ssh-ed25519 HostKeyOfVm120A*$" "$1/g/109/trusted" && grep -q "DONE  zradio1 trusts zradio2" "$1/out" && grep -q "DONE  zradio2 trusts zradio1" "$1/out"' _ "$T/j"
check "…then the link is tried (peer-hello), BEFORE the start; the end says the pair is complete" bash -c '
  n() { grep -n -m1 -F -- "$1" "$2/calls" | cut -d: -f1; }
  a=$(n "zradio-sync trust" "$1"); b=$(n "guest: /usr/local/sbin/zradio-sync peer-hello" "$1"); c=$(n "guest: systemctl start zradio.target" "$1")
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && grep -q "zradio2 reached zradio1 over the sync.s own link: hello name=peer" "$1/out" && grep -q "The pair is complete: zradio1 on nodeb, zradio2 on nodea. zradio1 writes its networks onto the other" "$1/out"' _ "$T/j"
check "fixed addresses: the first VM already names this one as its peer — it is not told again, and nothing is to be reserved" bash -c '! grep -q -- "install.sh --peer" "$1/calls" && ! grep -q "RESERVE" "$1/out" && ! grep -q "WOULD tell zradio1" "$1/out"' _ "$T/j"
node "$T/j2"; peer_vm "$T/j2" 120 zradio1 standby; zvm "$T/j2"
check "the first VM is the initial STANDBY: this one is the initial primary" bash -c '[ "$2" = 0 ] && grep -q "starts as the PRIMARY" "$1/out" && grep -q "PRIORITY=110" "$1/out"' _ "$T/j2" "$RC"
zvm "$T/j2" --initial-role standby
check "…and saying standby too is refused: the pair would have nobody holding the networks" bash -c '[ "$2" = 2 ] && grep -q "zradio1 was installed as the initial standby: this node.s VM is the initial primary" "$1/out"' _ "$T/j2" "$RC"
node "$T/j3"; peer_vm "$T/j3" 120 zradio1 primary; zvm "$T/j3" --initial-role primary --run
check "two primaries: refused before anything" bash -c '[ "$2" = 2 ] && grep -q "two primaries would be two different sets of networks" "$1/out" && ! grep -q "^qm" "$1/calls"' _ "$T/j3" "$RC"
zvm "$T/j3" --peer 10.20.30.9 --run
check "addresses that do not fit the first VM's: refused before anything" bash -c '[ "$2" = 2 ] && grep -q "the two do not fit" "$1/out" && ! grep -q "^qm" "$1/calls"' _ "$T/j3" "$RC"
: > "$T/j3/agent-down-120"; zvm "$T/j3" --run
check "the first VM does not answer: refused before anything, and why it is needed" bash -c '[ "$2" = 2 ] && grep -q "zradio1 on nodeb does not answer (its guest agent): start it first" "$1/out" && ! grep -q "^qm" "$1/calls"' _ "$T/j3" "$RC"
: > "$T/j3/calls"; zvm "$T/j3" "${BASE[@]}" --no-pair --run
check "--no-pair: a VM of its own, the other one is neither read nor touched" bash -c '[ "$2" = 0 ] && ! grep -q "zradio-sync" "$1/calls" && ! grep -q "zradio.conf 2>/dev/null" "$1/calls" && [ ! -e "$1/g/120/trusted" ]' _ "$T/j3" "$RC"
node "$T/j4"; peer_vm "$T/j4" 120 zradio1 primary; peer_vm "$T/j4" 121 attic1 primary; zvm "$T/j4" --run
check "two radio VMs on other nodes: it does not pick one" bash -c '[ "$2" = 2 ] && grep -q "more than one radio VM on other nodes (zradio1 attic1 ): say which with --join NAME" "$1/out"' _ "$T/j4" "$RC"
zvm "$T/j4" --join attic1 --name attic2 --run
check "--join names it" bash -c '[ "$2" = 0 ] && [ -s "$1/g/121/trusted" ] && [ ! -e "$1/g/120/trusted" ]' _ "$T/j4" "$RC"
node "$T/j5"; peer_vm "$T/j5" 120 zradio1 primary ZWAVE=synced ZIGBEE=none; zvm "$T/j5" --run
check "this node has a Zigbee stick and the first VM has none: built, and said that Zigbee does not fail over" bash -c '[ "$2" = 0 ] && grep -q "NOTE  zradio2 has a Zigbee stick and zradio1 has none: Zigbee is served only while zradio2 is the one that serves" "$1/out" && ! grep -q "Z-Wave stick and" "$1/out"' _ "$T/j5" "$RC"
node "$T/j6"; peer_vm "$T/j6" 120 zradio1 primary; : > "$T/j6/hello-fail"; zvm "$T/j6" --run --start
check "the two do not reach each other after the keys: exit 1, nothing started" bash -c '[ "$2" = 1 ] && grep -q "FAIL  zradio2 does not reach zradio1 at 10.20.30.5 over ssh" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/j6" "$RC"
node "$T/j7"; peer_vm "$T/j7" 120 zradio1 primary; : > "$T/j7/trust-fail"; zvm "$T/j7" --run --start
check "zradio-sync trust fails in a VM: exit 1, nothing started" bash -c '[ "$2" = 1 ] && grep -q "FAIL  zradio-sync trust failed in zradio1" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/j7" "$RC"
node "$T/j8"; peer_vm "$T/j8" 120 zradio1 primary; sed -i 's/SyncKeyOfVm%s/Sync KeyOfVm%s; touch x/' "$T/j8/bin/ga"; rm -rf "$T/j8/g/120"; echo '[]' > "$T/j8/vms.json"; peer_vm "$T/j8" 120 zradio1 primary; zvm "$T/j8" --run
check "a VM answers with something that is not a public key: nothing of it is passed on" bash -c '[ "$2" = 1 ] && grep -q "could not read the two VMs. public keys" "$1/out" && ! grep -q "zradio-sync trust" "$1/calls"' _ "$T/j8" "$RC"

echo "-- the walk-through: someone is there, nothing is given"
node "$T/w"; echo 192.168.1.31 > "$T/w/lease"; vmconf "$T/w" nodea/109 "net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0"; ask "$T/w" <<< $'primary\n\n\n\n192.168.1.20\ny\nn'
check "the first node: asked for the role, the name, the bridge and ONE address, the floating one — then shown the plan, then 'Go ahead?'" bash -c '
  o() { grep -b -o -F -- "$1" "$2/out" | head -1 | cut -d: -f1; }       # where in the output (the prompts share a line: the answers are not echoed)
  a=$(o "The sticks here that the kit knows" "$1"); b=$(o "initially primary or standby: " "$1"); c=$(o "the name of this node" "$1"); e=$(o "bridges: vmbr0 vmbr1" "$1")
  f=$(o "The VM gets its own address from that network" "$1"); g=$(o "the floating address (like 192.168.1.20): " "$1"); i=$(o "REPORT ONLY" "$1"); j=$(o "Go ahead? [y/N]" "$1")
  [ "$2" = 0 ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$e" ] && [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ] && [ "$g" -lt "$i" ] && [ "$i" -lt "$j" ]' _ "$T/w" "$RC"
check "…its own address, the other VM's and the gateway are NOT asked" bash -c '! grep -q "address there, with its prefix" "$1/out" && ! grep -q "the other radio VM.s address" "$1/out" && ! grep -q "the gateway of that network" "$1/out"' _ "$T/w"
check "…after 'y' it is built on DHCP: ip=dhcp, and a conf with the floating address and neither SELF nor PEER (the VM fills its own in)" bash -c 'grep "^qm create 109 --name zradio1 " "$1/calls" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=dhcp --serial0" && grep -q "^      VIP=192.168.1.20$" "$1/store/snippets/zradio1-zradio.yaml" && ! grep -qE "^      (SELF|PEER)=" "$1/store/snippets/zradio1-zradio.yaml" && grep -q -- "--initial-role primary > " "$1/calls" && grep -q "OK    zradio1 takes its own address from the DHCP server on vmbr0; the floating address is 192.168.1.20" "$1/out"' _ "$T/w"
check "…the address DHCP gave the VM is read back from it and said, with its MAC, as the one to RESERVE; the floating one is to stay out of the range" bash -c 'grep -q "OK    zradio1.s own address is 192.168.1.31, from DHCP" "$1/out" && grep -q "RESERVE 192.168.1.31 for zradio1 (MAC BC:24:11:AA:BB:CC), and keep 192.168.1.20 out of the range it hands out" "$1/out" && grep -q "a VM whose address changes stops serving" "$1/out"' _ "$T/w"
check "…'Start it now?' is asked at the end, with what starting means; 'n': installed, not started" bash -c 'grep -q "it takes the floating address 192.168.1.20 and serves this node.s sticks" "$1/out" && grep -q "Start it now? \[y/n\]" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls" && grep -q "== done: zradio1 on nodea ==" "$1/out"' _ "$T/w"
node "$T/w2"; ask "$T/w2" <<< $'standby\nattic\n\n10.1.1\n10.1.1.20\nn'
check "an address that is not one is asked again; 'n' at 'Go ahead?': nothing is changed, and the same as one command line is shown" bash -c '[ "$2" = 0 ] && [ "$(grep -o "the floating address (like 192.168.1.20): " "$1/out" | wc -l)" = 2 ] && ! grep -qE "^(qm|pvesh|ha-manager) " "$1/calls" && grep -q "Nothing was changed. The same without the questions:" "$1/out" && grep -q "./install.sh --name attic --initial-role standby --vip 10.1.1.20 --vrid 50 --priority 100 --bridge vmbr0 --run" "$1/out"' _ "$T/w2" "$RC"
node "$T/w2s"; ask "$T/w2s" --self 10.1.1.21/24 <<< $'standby\nattic\n\n10.1.1.22\n10.1.1.20\n10.1.1.1\nn'
check "--self: fixed addresses instead — the other VM's, the floating one and the gateway are asked, and nothing is DHCP" bash -c '[ "$2" = 0 ] && grep -q "the other radio VM.s address" "$1/out" && grep -q "the gateway of that network" "$1/out" && ! grep -q "DHCP server" "$1/out" && grep -q "WOULD qm create 109 .*--ipconfig0 ip=10.1.1.21/24,gw=10.1.1.1" "$1/out" && grep -q "./install.sh --name attic --initial-role standby --self 10.1.1.21/24 --peer 10.1.1.22 --vip 10.1.1.20/24 --vrid 50 --priority 100 --bridge vmbr0 --gateway 10.1.1.1 --run" "$1/out"' _ "$T/w2s" "$RC"
node "$T/w3"; peer_vm "$T/w3" 120 zradio1 primary; ask "$T/w3" <<< $'\n\ny\ny'
check "the second node: asked only whether it joins the first VM, the name, 'Go ahead?' and 'Start?' — no address, no role" bash -c '[ "$2" = 0 ] && grep -q "zradio1 on nodeb is a radio VM of this kit" "$1/out" && grep -q "this node starts as the STANDBY: the sticks here WILL BE WIPED by the first sync" "$1/out" && ! grep -q "initially primary or standby: " "$1/out" && ! grep -q "address there" "$1/out" && ! grep -q "bridge \[" "$1/out"' _ "$T/w3" "$RC"
check "…built, paired, started" bash -c 'grep -q "^qm create 109 --name zradio2 " "$1/calls" && [ -s "$1/g/120/trusted" ] && [ -s "$1/g/109/trusted" ] && grep -q "guest: systemctl start zradio.target" "$1/calls" && grep -q "it stands by, and serves only after the primary.s first sync" "$1/out"' _ "$T/w3"
node "$T/w4"; peer_vm "$T/w4" 120 zradio1 primary; ask "$T/w4" <<< $'n\nprimary\ny\nother1\n\n10.1.1.20\ny\nn'
check "'n' to joining: a pair of its own — everything is asked, the other VM is left alone" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name other1 " "$1/calls" && [ ! -e "$1/g/120/trusted" ] && ! grep -q "zradio-sync" "$1/calls"' _ "$T/w4" "$RC"
node "$T/wd"; peer_vm "$T/wd" 120 zradio1 primary; peer_dhcp "$T/wd" 120 zradio1; echo 192.168.1.32 > "$T/wd/lease"; printf 'DONE  keepalived reloaded: this VM sends its adverts to its peer 192.168.1.32 now.\n' > "$T/wd/peer.log"; ask "$T/wd" <<< $'\n\ny\ny'
check "the second node, the first VM on DHCP: this one is on DHCP too, on the first one's bridge — no address is asked" bash -c '[ "$2" = 0 ] && ! grep -q "the floating address (like" "$1/out" && ! grep -q "address there" "$1/out" && grep -q "its address comes from DHCP on vmbr1, zradio1.s is 192.168.1.31, the floating address 192.168.1.20/24" "$1/out" && grep "^qm create 109 --name zradio2 " "$1/calls" | grep -q -- "--net0 virtio,bridge=vmbr1 --ipconfig0 ip=dhcp --serial0"' _ "$T/wd" "$RC"
check "…its conf names the first VM as its peer, and no address of its own" bash -c 'grep -q "^      PEER=192.168.1.31$" "$1/store/snippets/zradio2-zradio.yaml" && grep -q "^      VIP=192.168.1.20/24$" "$1/store/snippets/zradio2-zradio.yaml" && ! grep -q "^      SELF=" "$1/store/snippets/zradio2-zradio.yaml"' _ "$T/wd"
check "…the first VM is told this VM's address (the kit's installer there, --peer) BEFORE the keys; a reload of its keepalived is shown" bash -c '
  n() { grep -n -m1 -- "$1" "$2/calls" | cut -d: -f1; }
  a=$(n "^guest: bash /opt/zradio/kit/guest/install.sh --peer 192.168.1.32 --from-node --run" "$1"); b=$(n "zradio-sync keys" "$1")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && grep -qx "PEER=192.168.1.32" "$1/g/120/root/etc/zradio/zradio.conf" && grep -q "DONE  zradio1 knows its peer now: 192.168.1.32" "$1/out" && grep -q "      | DONE  keepalived reloaded" "$1/out" && grep -q "WOULD tell zradio1 (nodeb) this VM.s address once DHCP has given it one" "$1/out"' _ "$T/wd"
check "…paired, started, and this VM's address is the one to reserve" bash -c '[ -s "$1/g/120/trusted" ] && [ -s "$1/g/109/trusted" ] && grep -q "guest: systemctl start zradio.target" "$1/calls" && grep -q "The pair is complete: zradio1 on nodeb, zradio2 on nodea" "$1/out" && grep -q "RESERVE 192.168.1.32 for zradio2" "$1/out"' _ "$T/wd"
node "$T/wf"; peer_vm "$T/wf" 120 zradio1 primary; peer_dhcp "$T/wf" 120 zradio1; : > "$T/wf/peer-fail"; zvm "$T/wf" --run --start
check "the first VM cannot be told its peer: exit 1, no keys exchanged, nothing started" bash -c '[ "$2" = 1 ] && grep -q "FAIL  zradio1 could not be told its peer.s address 10.20.30.77" "$1/out" && ! grep -q "zradio-sync" "$1/calls" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/wf" "$RC"
node "$T/wg"; zvm "$T/wg" --initial-role primary --vip 192.168.1.20 --gateway 192.168.1.1
check "DHCP and --gateway: refused (the gateway is DHCP's)" bash -c '[ "$2" = 2 ] && grep -q "die: --gateway goes with --self" "$1/out"' _ "$T/wg" "$RC"
zvm "$T/wg" --initial-role primary
check "…no --vip and nobody to ask: refused, naming the one address that is needed" bash -c '[ "$2" = 2 ] && grep -q "die: --vip .*: the floating address Home Assistant connects to" "$1/out" && grep -q "The VM.s own address comes from DHCP" "$1/out"' _ "$T/wg" "$RC"
node "$T/w5"; ask "$T/w5" "${BASE[@]}" <<< 'y'
check "every answer given as an option, someone there: no question but 'Go ahead?' and 'Start it now?' (no answer to that: not started)" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name zr2 " "$1/calls" && ! grep -q "the name of this node" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/w5" "$RC"

echo "-- --answers FILE: the same without anyone there"
node "$T/an"; printf '%s\n' "# my pair" "" INITIAL_ROLE=primary FIRST=yes NAME=attic1 SELF=10.1.1.21/24 PEER=10.1.1.22 VIP=10.1.1.20/24 GATEWAY=10.1.1.1 BRIDGE=vmbr1 START=yes CONF=SYNC_TZ=Europe/Berlin MEMORY=1024 > "$T/an/a"
zvm "$T/an" --answers "$T/an/a"
check "without --run: report only, whatever the file says" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/an" "$RC"
zvm "$T/an" --answers "$T/an/a" --run
check "with --run: built from the file — the VM, its conf, the role, --first, started" bash -c '[ "$2" = 0 ] && grep "^qm create 109 --name attic1 " "$1/calls" | grep -q -- "--memory 1024 .*--net0 virtio,bridge=vmbr1 --ipconfig0 ip=10.1.1.21/24,gw=10.1.1.1" && grep -q "^      SYNC_TZ=Europe/Berlin$" "$1/store/snippets/attic1-zradio.yaml" && grep -q -- "--initial-role primary --first > " "$1/calls" && grep -q "guest: systemctl start zradio.target" "$1/calls"' _ "$T/an" "$RC"
node "$T/an2"; cp "$T/an/a" "$T/an2/a"; zvm "$T/an2" --answers "$T/an2/a" --name other --run
check "an option on the command line wins over the file" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name other " "$1/calls"' _ "$T/an2" "$RC"
for badline in "RUN=yes" "FIRST=maybe" "no equals sign" "NO_SUCH_THING=1" "lower=1"; do
  node "$T/an3"; printf '%s\n' INITIAL_ROLE=primary SELF=10.1.1.21/24 PEER=10.1.1.22 VIP=10.1.1.20/24 GATEWAY=10.1.1.1 "$badline" > "$T/an3/a"; zvm "$T/an3" --answers "$T/an3/a" --run
  check "an answers file with the line '$badline': refused before anything" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/an3" "$RC"
done
zvm "$T/an3" --answers "$T/an3/nosuch" --run
check "no such answers file: refused" bash -c '[ "$2" = 2 ] && grep -q "no such file" "$1/out"' _ "$T/an3" "$RC"
check "answers.example is a valid answers file (report mode, on the fake node)" bash -c 'd=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VM_SYS="$d/sys" ZRADIO_VM_NET="$d/net" ZRADIO_VM_PVE="$d/pve" ZRADIO_VM_CACHE="$d/cache" ZRADIO_VM_KEYS="$d/keys" bash "$1" --answers "$2/answers.example" < /dev/null | grep -q "^REPORT ONLY"' _ "$T/an3" "$TOOL" "$KIT"

echo "-- the VM's name is the user's: a flag, a question, or the first free default"
NONAME=(--initial-role standby --self 10.20.30.6/24 --peer 10.20.30.5 --vip 10.20.30.50/24 --pair-bridge vmbrpair)
node "$T/n1"; zvm "$T/n1" "${NONAME[@]}" --run
check "no --name and nobody to ask: zradio1, said" bash -c '[ "$2" = 0 ] && grep -q "NOTE  no --name: this VM is called zradio1" "$1/out" && grep -q "^qm create 109 --name zradio1 " "$1/calls" && [ -f "$1/store/snippets/zradio1-zradio.yaml" ] && grep -q "^      NAME=zradio1$" "$1/store/snippets/zradio1-zradio.yaml"' _ "$T/n1" "$RC"
node "$T/n2"; echo '[{"vmid":105,"name":"zradio1","node":"nodeb","status":"running"}]' > "$T/n2/vms.json"; zvm "$T/n2" "${NONAME[@]}" --run
check "…the second node of a pair: zradio1 exists in the cluster, this one is zradio2" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name zradio2 " "$1/calls"' _ "$T/n2" "$RC"
node "$T/n2a"; peer_vm "$T/n2a" 120 radio1 primary; zvm "$T/n2a" --run
check "…the first VM has a name of its own: the second is named after it (radio1 -> radio2), and that is said" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name radio2 " "$1/calls" && grep -q "NOTE  no --name: this VM is called radio2 (after radio1, the pair.s first VM)" "$1/out"' _ "$T/n2a" "$RC"
node "$T/n2b"; peer_vm "$T/n2b" 120 attic primary; ask "$T/n2b" <<< $'\n\nn'
check "…a first VM whose name ends in no number (attic): attic2 is offered as the default" bash -c '[ "$2" = 0 ] && grep -q "the name of this node.s radio VM \[attic2\]: " "$1/out" && grep -q "WOULD qm create 109 --name attic2 " "$1/out"' _ "$T/n2b" "$RC"
node "$T/n2c"; peer_vm "$T/n2c" 120 radio1 primary; python3 -c 'import json, sys; v = json.load(open(sys.argv[1])); v.append({"vmid": 130, "name": "radio2", "node": "nodea", "status": "stopped", "tags": "", "type": "qemu"}); json.dump(v, open(sys.argv[1], "w"))' "$T/n2c/vms.json"; zvm "$T/n2c"
check "…radio2 is taken by another VM: radio3" bash -c '[ "$2" = 0 ] && grep -q "WOULD qm create 109 --name radio3 " "$1/out"' _ "$T/n2c" "$RC"
node "$T/n3"; ask "$T/n3" "${NONAME[@]}" --run <<< $'Kitchen Radio\nattic-radio'
check "someone is there: asked, with the default shown; a name that will not do is asked again; the answer is the name everywhere" bash -c '[ "$2" = 0 ] && grep -q "the name of this node.s radio VM \[zradio1\]: " "$1/out" && grep -q "a short lower-case name" "$1/out" && grep -q "^qm create 109 --name attic-radio " "$1/calls" && grep -q "^hostname: attic-radio$" "$1/store/snippets/attic-radio-zradio.yaml" && grep -q "rules add node-affinity attic-radio-on-nodea" "$1/calls"' _ "$T/n3" "$RC"
node "$T/n4"; ask "$T/n4" "${NONAME[@]}" <<< ""
check "…Enter takes the default; in report mode nothing is made" bash -c '[ "$2" = 0 ] && grep -q "WOULD qm create 109 --name zradio1 " "$1/out" && [ ! -s "$1/calls" ]' _ "$T/n4" "$RC"

echo "-- USB mappings: yours, the cluster's, twins"
# (the JSON as a PVE 9.2 cluster prints it: description, digest and type beside id and map; resources with their other fields)
node "$T/m"; echo '[{"description":"a Zigbee stick; per-node entry","digest":"bebca8ef7d2cfaacc993da4be2368544977c2c14","id":"zigbee","map":["node=nodea,id=10c4:ea60"],"type":"usb"},{"description":"a Z-Wave stick","digest":"bebca8ef7d2cfaacc993da4be2368544977c2c14","id":"zwave","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70"],"type":"usb"}]' > "$T/m/usbmap.json"
echo '[{"cpu":0.01,"disk":0,"id":"qemu/102","maxcpu":2,"maxmem":4294967296,"name":"other","node":"nodea","status":"running","template":0,"type":"qemu","uptime":5,"vmid":102},{"id":"qemu/104","name":"more","node":"nodeb","status":"running","type":"qemu","vmid":104}]' > "$T/m/vms.json"
vmconf "$T/m" nodea/102 "agent: enabled=1" "ipconfig0: ip=dhcp" "net0: virtio=BC:24:11:62:1B:1D,bridge=vmbr0" "usb0: host=0557:9241"
zvm "$T/m" "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "--usb-mapping: those two are passed through, none is made" bash -c '[ "$2" = 0 ] && grep "^qm create" "$1/calls" | grep -q -- "--usb0 mapping=zwave --usb1 mapping=zigbee" && ! grep -q "^pvesh" "$1/calls"' _ "$T/m" "$RC"
zvm "$T/m" "${BASE[@]}" --name zr9 --usb-mapping zwave --usb-mapping nosuch
check "a mapping with no entry for this node: refused, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "USB mapping .nosuch. has no entry for nodea" "$1/out" && grep -q "nothing was changed" "$1/out"' _ "$T/m" "$RC"
node "$T/m2" dark; cp "$T/m/usbmap.json" "$T/m2/usbmap.json"; zvm "$T/m2" "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee
check "the mapped sticks are not on the bus (their ports are off) and there is no hookscript: refused" bash -c '[ "$2" = 1 ] && grep -c "no USB device 10c4:ea.0 on nodea right now" "$1/out" | grep -qx 2' _ "$T/m2" "$RC"
zvm "$T/m2" "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --hookscript local:snippets/ports.sh
check "…with a hookscript: said, and accepted (the hook switches the ports on before the start)" bash -c '[ "$2" = 0 ] && grep -c "NOTE  mapping .*taken as a port your hookscript switches on" "$1/out" | grep -qx 2' _ "$T/m2" "$RC"
node "$T/m3"; echo '[{"id":"zradio-10c4ea70","map":["node=nodeb,id=10c4:ea70"]},{"id":"zradio-10c4ea60","map":["node=nodea,id=10c4:ea60"]}]' > "$T/m3/usbmap.json"; zvm "$T/m3" "${BASE[@]}" --run
check "the second node of a pair: the kit's mapping exists for the OTHER node — this node's entry is added to it, the other's kept" bash -c 'grep -q "^pvesh set /cluster/mapping/usb/zradio-10c4ea70 --map node=nodeb,id=10c4:ea70 --map node=nodea,id=10c4:ea70$" "$1/calls" && ! grep -q "pvesh create" "$1/calls" && ! grep -q "zradio-10c4ea60 --map" "$1/calls"' _ "$T/m3"
node "$T/m4" twins; zvm "$T/m4" "${BASE[@]}" --run
check "two sticks of the same model: one mapping each, told apart by their port" bash -c 'grep -q "^pvesh create /cluster/mapping/usb --id zradio-10c4ea60-1 --map node=nodea,id=10c4:ea60,path=1-3.2.1 " "$1/calls" && grep -q "^pvesh create /cluster/mapping/usb --id zradio-10c4ea60-2 --map node=nodea,id=10c4:ea60,path=1-3.2.4 " "$1/calls" && grep "^qm create" "$1/calls" | grep -q -- "--usb0 mapping=zradio-10c4ea60-1 --usb1 mapping=zradio-10c4ea60-2"' _ "$T/m4"
node "$T/m5" none; zvm "$T/m5" "${BASE[@]}" --run
check "no stick at all: refused, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "no stick on nodea" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m5" "$RC"
zvm "$T/m5" "${BASE[@]}" --run --allow-no-radios
check "--allow-no-radios (a drill): the VM is built without a USB line" bash -c '[ "$2" = 0 ] && grep -q "^qm create" "$1/calls" && ! grep -q "usb0" "$1/calls"' _ "$T/m5" "$RC"

echo "-- --no-usb: a drill on a node whose sticks are in use"
node "$T/d"; echo '[{"id":"zwave","map":["node=nodea,id=10c4:ea70"]},{"id":"zigbee","map":["node=nodea,id=10c4:ea60"]}]' > "$T/d/usbmap.json"; echo '[{"vmid":101,"name":"live1","node":"nodea","status":"running"}]' > "$T/d/vms.json"
vmconf "$T/d" nodea/101 "usb0: mapping=zwave" "usb1: mapping=zigbee" "ipconfig1: ip=10.20.30.5/24"
echo 1 > "$T/d/install.rc"; printf 'DONE  keepalived 2.3.3 installed\n    FAIL  no Z-Wave or Zigbee stick found on this VM\nFAIL  zradio-detect did not end clean — read its lines above\n' > "$T/d/install.log"
zvm "$T/d" --name zr-drill --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --run
check "the live VM holds both sticks; --no-usb builds beside it without a USB line and without touching a mapping" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name zr-drill" "$1/calls" && ! grep -q "usb0" "$1/calls" && ! grep -q "^pvesh" "$1/calls"' _ "$T/d" "$RC"
check "the installer's \"no stick\" end is the drill's expected end: said so, exit 0, and how to remove the drill" bash -c 'grep -q "the drill went as far as a VM without a stick can" "$1/out" && grep -q "To remove it: ha-manager rules remove zr-drill-on-nodea; ha-manager remove vm:109; qm stop 109; qm destroy 109 --purge" "$1/out"' _ "$T/d" "$RC"
check "the drill is under Proxmox HA like the real thing (the rule and the restart are what it is for)" bash -c 'grep -q "^ha-manager rules add node-affinity zr-drill-on-nodea .*--strict 1" "$1/calls" && grep -q "^ha-manager set vm:109 --state started" "$1/calls"' _ "$T/d"
echo 1 > "$T/d/install.rc"; printf 'FAIL  apt-get install keepalived failed\n' > "$T/d/install.log"; echo '[{"vmid":101,"name":"live1","node":"nodea","status":"running"}]' > "$T/d/vms.json"
zvm "$T/d" --name zr-drill2 --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --run
check "the line the drill is recognized by is the one the kit's installer really prints when the detection fails" bash -c 'grep -q "bad \"zradio-detect did not end clean" "$1/guest/install.sh" && grep -q "printf .FAIL  %s" "$1/guest/install.sh"' _ "$KIT"
check "a drill whose installer failed for ANOTHER reason is a failure" bash -c '[ "$2" = 1 ] && grep -q "the installer ended 1 in zr-drill2" "$1/out"' _ "$T/d" "$RC"
zvm "$T/d" --name zr-drill3 --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --start
check "--no-usb with --start, or with --usb-mapping: refused" bash -c '[ "$2" = 2 ] && grep -q "is a drill" "$1/out"' _ "$T/d" "$RC"

echo "-- refused before anything is changed"
node "$T/x"; echo '[{"vmid":101,"name":"zr2","node":"nodeb","status":"stopped"}]' > "$T/x/vms.json"; zvm "$T/x" "${BASE[@]}" --run
check "a VM of that name exists (even stopped, even on the other node): refused — this tool never rebuilds one" bash -c '[ "$2" = 1 ] && grep -q "a VM named zr2 exists already (on nodeb, stopped)" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x" "$RC"
node "$T/x2"; echo '[{"vmid":150,"name":"other","node":"nodea","status":"running"}]' > "$T/x2/vms.json"; zvm "$T/x2" "${BASE[@]}" --vmid 150 --run
check "the id is taken: refused" bash -c '[ "$2" = 1 ] && grep -q "the id 150 is taken (other)" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x2" "$RC"
node "$T/x3"; echo '[{"vmid":108,"name":"old2","node":"nodea","status":"running"}]' > "$T/x3/vms.json"; vmconf "$T/x3" nodea/108 "ipconfig1: ip=10.20.30.6/24" "usb0: host=1-1"; zvm "$T/x3" "${BASE[@]}" --run
check "a RUNNING VM has --self already: refused (two VMs on one address)" bash -c '[ "$2" = 1 ] && grep -q "old2 runs with the address 10.20.30.6 already" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x3" "$RC"
echo '[{"vmid":108,"name":"old2","node":"nodea","status":"stopped"}]' > "$T/x3/vms.json"; zvm "$T/x3" "${BASE[@]}" --run
check "…the same VM stopped (the one this VM replaces): said, and the build goes on" bash -c '[ "$2" = 0 ] && grep -q "NOTE  old2 (stopped) is configured with 10.20.30.6 too: it must stay stopped" "$1/out" && grep -q "^qm create" "$1/calls"' _ "$T/x3" "$RC"
node "$T/x4"; cp "$T/m/usbmap.json" "$T/x4/usbmap.json"; echo '[{"vmid":108,"name":"old2","node":"nodea","status":"running"}]' > "$T/x4/vms.json"; vmconf "$T/x4" nodea/108 "usb0: mapping=zwave" "usb1: mapping=zigbee"
zvm "$T/x4" "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "a RUNNING VM on this node passes the same mapping through: refused (two VMs on one stick)" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device 10c4:ea.0 (mapping z[a-z]* here) passed through already" "$1/out" | grep -qx 2 && [ ! -s "$1/calls" ]' _ "$T/x4" "$RC"
zvm "$T/x4" "${BASE[@]}" --run
check "…and so is building with the kit's OWN mappings while that VM runs on the same sticks under other mapping names" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device" "$1/out" | grep -qx 2 && [ ! -s "$1/calls" ]' _ "$T/x4" "$RC"
vmconf "$T/x4" nodea/108 "usb0: host=10C4:EA70" "usb1: host=1-9"; zvm "$T/x4" "${BASE[@]}" --run
check "…or passed through by its id (host=vid:pid), whatever the letter case: refused for that stick, not for the other" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device" "$1/out" | grep -qx 1 && grep -q "USB device 10c4:ea70" "$1/out"' _ "$T/x4" "$RC"
vmconf "$T/x4" nodea/108 "usb0: mapping=zwave2" "[snap1]" "usb0: mapping=zwave"; zvm "$T/x4" "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "…a mapping whose name only starts the same, or a usb line in a snapshot's section, is not this stick: not refused" eq "$RC" 0
echo '[{"vmid":108,"name":"old2","node":"nodea","status":"stopped"}]' > "$T/x4/vms.json"; vmconf "$T/x4" nodea/108 "usb0: mapping=zwave" "usb1: mapping=zigbee"; : > "$T/x4/calls"; zvm "$T/x4" "${BASE[@]}" --name zr8 --usb-mapping zwave --usb-mapping zigbee --run
check "…the same VM STOPPED still carries the sticks: the build goes on (stopping it was the point)" eq "$RC" 0
check "…and it is said that its usb lines should come off (something may start it: a backup in stop mode does)" bash -c 'grep -c "NOTE  old2 (not running) on nodea still has the USB device" "$1/out" | grep -qx 2' _ "$T/x4"
node "$T/x5" both 0; zvm "$T/x5" "${BASE[@]}" --run
check "Proxmox HA does not answer and --no-ha was not said: refused" bash -c '[ "$2" = 1 ] && grep -q "ha-manager status does not answer" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x5" "$RC"
node "$T/x6"; echo '[{"storage":"local","type":"dir","content":"images,iso","path":"/x"},{"storage":"local-zfs","type":"zfspool","content":"images"}]' > "$T/x6/storages.json"; zvm "$T/x6" "${BASE[@]}" --run
check "the snippets storage does not hold snippets: refused, with the command that allows it" bash -c '[ "$2" = 1 ] && grep -q "does not hold snippets (pvesm set local --content" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x6" "$RC"
node "$T/x7"; : > "$T/x7/keys"; zvm "$T/x7" "${BASE[@]}" --run
check "no public key for root: refused (the VM would have no way in)" bash -c '[ "$2" = 1 ] && grep -q "no public key in" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x7" "$RC"
for bad in "--name Zr2" "--self 10.20.30.6" "--peer 10.20.30.6" "--vip 10.20.30.5/24" "--vrid 0" "--priority 255" "--conf NAME=x" "--conf lower=1" "--hookscript /root/hook.sh" "--disk 8"; do
  node "$T/a"; zvm "$T/a" "${BASE[@]}" $bad --run
  check "refused before anything: $bad" bash -c '[ "$2" = 2 ] && grep -q "^die: " "$1/out" && [ ! -s "$1/calls" ]' _ "$T/a" "$RC"
done

echo "-- the image: downloaded once, and only when its checksum is the published one"
node "$T/i"; find "$T/i/cache" -type f -delete; zvm "$T/i" "${BASE[@]}" --run
check "no image in the cache: downloaded, checked against SHA512SUMS, kept" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/cache/debian-13-generic-amd64.qcow2")" = image-from-the-web ] && [ -s "$1/cache/debian-13-generic-amd64.qcow2.sha512" ] && grep -q "^wget -q https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS" "$1/calls"' _ "$T/i" "$RC"
node "$T/i2"; find "$T/i2/cache" -type f -delete; echo 0000 > "$T/i2/sum"; zvm "$T/i2" "${BASE[@]}" --run
check "the checksum does not match: no image kept, no VM made" bash -c '[ "$2" = 1 ] && grep -q "sha512 mismatch" "$1/out" && [ -z "$(ls "$1/cache")" ] && ! grep -q "^qm create" "$1/calls"' _ "$T/i2" "$RC"

echo "-- when a step fails"
node "$T/f"; : > "$T/f/qm-fail"; zvm "$T/f" "${BASE[@]}" --run
check "qm create fails: said, exit 1, and nothing after it (no HA entry for a VM that does not exist)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  qm create 109 .* failed" "$1/out" && ! grep -q "^ha-manager" "$1/calls" && ! grep -q "^qm set" "$1/calls"' _ "$T/f" "$RC"
node "$T/f2"; : > "$T/f2/ha-fail"; zvm "$T/f2" "${BASE[@]}" --run
check "ha-manager add fails: the VM is not started" bash -c '[ "$2" = 1 ] && ! grep -q "state started" "$1/calls" && ! grep -q "^qm start" "$1/calls"' _ "$T/f2" "$RC"
node "$T/f3"; : > "$T/f3/agent-down"; zvm "$T/f3" "${BASE[@]}" --run
check "the guest agent never answers: exit 1, where to look" bash -c '[ "$2" = 1 ] && grep -q "no guest agent in" "$1/out" && grep -q "qm terminal 109" "$1/out"' _ "$T/f3" "$RC"
node "$T/f4"; echo error > "$T/f4/ci-status"; zvm "$T/f4" "${BASE[@]}" --run --start
check "cloud-init ends in error: exit 1, the VM is not put into the pair" bash -c '[ "$2" = 1 ] && grep -q "cloud-init ended .error." "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/f4" "$RC"
node "$T/f5"; echo 1 > "$T/f5/install.rc"; printf 'FAIL  zradio-detect did not end clean\n== 1 FAIL ==\n' > "$T/f5/install.log"; zvm "$T/f5" "${BASE[@]}" --run --start
check "the kit's installer failed in the VM: its FAIL line is shown, exit 1, the VM is not put into the pair" bash -c '[ "$2" = 1 ] && grep -q "| *FAIL  zradio-detect did not end clean" "$1/out" && grep -q "the installer ended 1 in zr2" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/f5" "$RC"

echo "-- help"
check "--help: one command, what it asks, that nothing is changed without --run; short" bash -c 'h=$(bash "$1" --help); printf "%s\n" "$h" | grep -q "^#     ./install.sh$" && printf "%s\n" "$h" | grep -q "standby: this node.s sticks WILL BE WIPED" && printf "%s\n" "$h" | grep -q "Only for the start" && printf "%s\n" "$h" | grep -q "nothing is changed without --run" && [ "$(printf "%s\n" "$h" | wc -l)" -le 32 ] && ! printf "%s\n" "$h" | grep -q "^set -uo"' _ "$TOOL"
finish
