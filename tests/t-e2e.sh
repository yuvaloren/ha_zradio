#!/usr/bin/env bash
# t-e2e.sh — the whole install, both nodes, end to end: ./install.sh on a fake Proxmox cluster (tests/fake-node.sh,
# live: qm create really registers the VM), and in each VM the kit's REAL installer, run through the fake guest agent
# in a fake radio VM (tests/fake-guest.sh). Real: both installers, the answers files, the cloud-init file's contents
# (unpacked as cloud-init would), zradio-sync keys / trust / hello with real ssh keys. Fake: Proxmox, apt, systemd,
# the sticks, and ssh between the two VMs (it lets a connection through only when the keys really were exchanged).
. "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"
. "$TESTS_DIR/fake-guest.sh"
command -v ssh-keygen >/dev/null 2>&1 || { echo "  (ssh-keygen is not installed here: t-e2e.sh is skipped)"; finish; exit 0; }
C="$T/c"
. "$TESTS_DIR/fake-pair.sh"

echo "-- the first node (nodea): an answers file, nobody there"
cluster; guest 100 both 10.20.30.5; guest 101 both 10.20.30.6
printf '%s\n' INITIAL_ROLE=primary NAME=attic1 SELF=10.20.30.5/24 PEER=10.20.30.6 VIP=10.20.30.50/24 GATEWAY=10.20.30.1 > "$C/first.answers"
zvm "$C" --answers "$C/first.answers" --run; cp "$C/out" "$C/out1"
R1="$C/g/100/root"; R2="$C/g/101/root"
check "exit 0; the VM is in the cluster's files, tagged, running, on nodea" bash -c '[ "$2" = 0 ] && python3 -c "import json, sys; v = json.load(open(sys.argv[1]))[0]; assert (v[\"vmid\"], v[\"name\"], v[\"node\"], v[\"status\"], v[\"tags\"]) == (100, \"attic1\", \"nodea\", \"running\", \"zradio\"), v" "$1/vms.json"' _ "$C" "$RC"
check "the kit's real installer ran in the VM, from the files cloud-init put there: its own lines are in the node's output, and it ended clean" bash -c 'grep -q "| == 1. the kit.s files ==" "$1/out1" && grep -q "| .*this VM starts as the PRIMARY: its zigbee zwave stick(s) hold the networks and stay as they are" "$1/out1" && grep -q "OK    the kit is installed in attic1, as the initial primary" "$1/out1" && [ "$(cat "$2/root/zradio-install.rc")" = 0 ]' _ "$C" "$R1"
check "…installed where a radio VM has it: the tools, the conf with the answers, the units enabled, nothing started" bash -c '[ -x "$1/usr/local/sbin/zradio-serve" ] && [ "$(grep -v "^#" "$1/etc/zradio/zradio.conf" | tr "\n" " ")" = "NAME=attic1 SELF=10.20.30.5 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY=110 " ] && [ "$(cat "$1/var/lib/zradio/initial-role")" = primary ] && [ ! -e "$1/var/lib/zradio/standby-dirty" ] && grep -q "^systemctl enable zradio.target" "$2/calls" && ! grep -q "^systemctl start" "$2/calls"' _ "$R1" "$C/g/100"
check "the first VM of the pair: nothing to pair with yet, and it says what comes next" bash -c 'grep -q "Next: ./install.sh on the other node. It finds attic1" "$1/out1" && [ ! -e "$2/etc/zradio/sync.known_hosts" ]' _ "$C" "$R1"

echo "-- the second node (nodeb): no answers at all"
FAKE_NODE=nodeb zvm "$C" --run --start; cp "$C/out" "$C/out2"
check "exit 0; it found attic1, called itself attic2, took the other address, the same floating address, bridge and gateway" bash -c '[ "$2" = 0 ] && [ "$(grep -v "^#" "$1/etc/zradio/zradio.conf" | tr "\n" " ")" = "NAME=attic2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 " ] && grep -q "^ipconfig0: ip=10.20.30.6/24,gw=10.20.30.1$" "$3/pve/nodes/nodeb/qemu-server/101.conf" && grep -q "^net0: virtio,bridge=vmbr0$" "$3/pve/nodes/nodeb/qemu-server/101.conf"' _ "$R2" "$RC" "$C"
check "it is the initial STANDBY because attic1 is the primary: marked not filled by the real installer, which names the sticks that will be overwritten" bash -c '[ "$(cat "$1/var/lib/zradio/initial-role")" = standby ] && grep -q "^install.sh: the initial standby" "$1/var/lib/zradio/standby-dirty" && grep -q "| .*the zigbee zwave stick(s) hold a network today: it will be OVERWRITTEN" "$2/out2"' _ "$R2" "$C"
check "its own node's sticks: nodeb's entry added to the USB mappings nodea made" bash -c 'grep -q "^pvesh set /cluster/mapping/usb/zradio-10c4ea70 --map node=nodea,id=10c4:ea70 --map node=nodeb,id=10c4:ea70$" "$1/calls" || grep -q "^pvesh create /cluster/mapping/usb --id zradio-10c4ea70 --map node=nodeb" "$1/calls"' _ "$C"
check "the pairing, with real keys: each VM pinned the other's host key and allows the other's sync key — from its address, for the sync only" bash -c '
  k() { cut -d" " -f1,2 < "$1"; }
  grep -qxF "10.20.30.5 $(k "$1/etc/ssh/ssh_host_ed25519_key.pub")" "$2/etc/zradio/sync.known_hosts" && grep -qxF "10.20.30.6 $(k "$2/etc/ssh/ssh_host_ed25519_key.pub")" "$1/etc/zradio/sync.known_hosts" &&
  grep -qF "command=\"/usr/local/sbin/zradio-sync serve-ssh\",from=\"10.20.30.6\",restrict $(k "$2/etc/zradio/sync.key.pub") zradio-sync-peer" "$1/root/.ssh/authorized_keys" &&
  grep -qF "command=\"/usr/local/sbin/zradio-sync serve-ssh\",from=\"10.20.30.5\",restrict $(k "$1/etc/zradio/sync.key.pub") zradio-sync-peer" "$2/root/.ssh/authorized_keys"' _ "$R1" "$R2"
check "…and the link works: the new VM's hello reached attic1's own zradio-sync through it" bash -c 'grep -q "OK    attic2 reached attic1 over the sync.s own link: " "$1/out2" && grep -q "The pair is complete: attic1 on nodea, attic2 on nodeb" "$1/out2"' _ "$C"
check "--start: started in the pair (the standby does not serve: its sticks are not filled yet)" bash -c 'grep -q "^systemctl start zradio.target" "$1/g/101/calls" && grep -q "DONE  systemctl start zradio.target in attic2" "$1/out2"' _ "$C"
check "run from the node, the VM's installer does not ask for anything to be pasted: no trust line, no 'next' list" bash -c '! grep -q "zradio-sync trust --sync-key" "$1/out1" "$1/out2" && grep -q "| == installed ==" "$1/out2"' _ "$C"
check "the private halves never left their VM: no private key in the node's output or in the cloud-init files" bash -c '! grep -rq "PRIVATE KEY" "$1/out1" "$1/out2" "$1/store/snippets" "$1/calls"' _ "$C"

echo "-- the same pair, a new house with one kind of stick, both nodes by questions"
cluster zwave; guest 100 zwave-only 192.168.1.21; guest 101 zwave-only 192.168.1.22
sed -i 's/both|blank) printf/blank) printf/; s/net=true; \[ "zwave-only" = blank \] \&\& net=false/net=false/' "$C/g/100/detect" "$C/g/101/detect"     # new sticks: no network on them
ask "$C" <<< $'primary\nn\n\n\n192.168.1.20\ny\ny'; cp "$C/out" "$C/out1"       # one address: the floating one. The VMs' own come from "DHCP" (their ip)
check "node 1, by questions: primary, 'n' to 'do the sticks hold your networks' — the real installer accepts the empty stick as a new house" bash -c '[ "$2" = 0 ] && grep -q "| .*starts as the PRIMARY: --first: the zwave stick(s) hold no network yet" "$1/out1" && [ ! -e "$1/g/100/root/var/lib/zradio/standby-dirty" ] && grep -q "^systemctl start zradio.target" "$1/g/100/calls"' _ "$C" "$RC"
check "…one Z-Wave stick: one USB line, and only the Z-Wave address for Home Assistant" bash -c 'grep -c "^usb" "$1/pve/nodes/nodea/qemu-server/100.conf" | grep -qx 1 && grep -q "radios: Z-Wave yes, Zigbee none" "$1/out1" && grep -q "Z-Wave JS → tcp://192.168.1.20:6639$" "$1/out1" && ! grep -q ZHA "$1/out1"' _ "$C"
usb "$C/sys-nodeb" 2-2 0000 0000 "unplugged"
FAKE_NODE=nodeb ask "$C" <<< $'\n\ny\ny'; cp "$C/out" "$C/out2"
check "node 2, by questions: four Enters and two y — joined, paired, started; the standby's empty stick waits for the first sync" bash -c '[ "$2" = 0 ] && grep -q "The pair is complete: zradio1 on nodea, zradio2 on nodeb" "$1/out2" && [ -e "$1/g/101/root/var/lib/zradio/standby-dirty" ] && [ -s "$1/g/101/root/etc/zradio/sync.known_hosts" ] && grep -q "^systemctl start zradio.target" "$1/g/101/calls" && ! grep -q "does not fail over" "$1/out2"' _ "$C" "$RC"
check "the VMs' own addresses came from DHCP: each real installer wrote the one its VM has into its conf, and the floating address got that network's prefix" bash -c '
  [ "$(grep -v "^#" "$1/g/101/root/etc/zradio/zradio.conf" | sort | tr "\n" " ")" = "NAME=zradio2 PEER=192.168.1.21 PRIORITY=100 SELF=192.168.1.22 VIP=192.168.1.20/24 VRID=50 " ] &&
  grep -q "| WARN  SELF: .* 192.168.1.21/24 on eth0" "$1/out1" && grep -q "RESERVE 192.168.1.21 for zradio1" "$1/out1" && grep -q "RESERVE 192.168.1.22 for zradio2" "$1/out2"' _ "$C"
check "the first VM had no peer until the second existed, and node 2's run told it (the real installer, --peer): PEER, the unicast lines, the sync's trust from that address" bash -c '
  grep -q "| WARN  no PEER: this VM has no peer yet" "$1/out1" && grep -q "DONE  zradio1 knows its peer now: 192.168.1.22" "$1/out2" &&
  [ "$(grep -v "^#" "$1/g/100/root/etc/zradio/zradio.conf" | sort | tr "\n" " ")" = "NAME=zradio1 PEER=192.168.1.22 PRIORITY=110 SELF=192.168.1.21 VIP=192.168.1.20/24 VRID=50 " ] &&
  grep -A2 "unicast_src_ip 192.168.1.21" "$1/g/100/root/etc/keepalived/keepalived.conf" | grep -q "^ *192.168.1.22$" && grep -q "from=\"192.168.1.22\",restrict" "$1/g/100/root/root/.ssh/authorized_keys"' _ "$C"
[ -z "${E2E_KEEP:-}" ] || { rm -rf "$E2E_KEEP"; cp -r "$T" "$E2E_KEEP"; }
finish
