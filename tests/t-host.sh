#!/usr/bin/env bash
# t-host.sh — host/zradio-vm against a fake Proxmox node: qm, pvesh, ha-manager and wget are fakes on PATH (recorded
# in <node>/calls); the USB device tree, /etc/pve, the image cache and the snippets directory are folders of the test.
# Real: the tool, the kit's stick table and guest folder, tar/base64, python3 (the cloud-init file is parsed as YAML
# and the kit inside it is unpacked and compared with guest/). No VM is made anywhere.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/host/zradio-vm"
node() { # node <dir> [sticks: both|none|twins|dark] [ha: 1|0]
  local d=$1 sticks=${2:-both} ha=${3:-1}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/sys" "$d/pve/nodes/nodea/qemu-server" "$d/pve/nodes/nodeb/qemu-server" "$d/cache" "$d/store/snippets"; : > "$d/calls"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyFakeKeyFakeKeyFakeKeyFakeKeyFakeKey1234 admin@x" > "$d/keys"
  usb() { mkdir -p "$d/sys/$1"; echo "$2" > "$d/sys/$1/idVendor"; echo "$3" > "$d/sys/$1/idProduct"; echo "$4" > "$d/sys/$1/product"; }
  usb usb1 1d6b 0002 "xHCI Host Controller"; usb 1-4 0557 9241 "a keyboard"
  case "$sticks" in
    both) usb 1-3.2.1 10c4 ea70 "CP2105 Dual USB to UART Bridge Controller"; usb 1-3.2.4 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus";;
    twins) usb 1-3.2.1 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus"; usb 1-3.2.4 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus";;
    none|dark) ;;
  esac
  echo '[]' > "$d/usbmap.json"; echo '[]' > "$d/vms.json"
  echo '[{"storage":"local","type":"dir","content":"images,snippets,iso,vztmpl","path":"'"$d"'/store"},{"storage":"local-zfs","type":"zfspool","content":"images,rootdir"}]' > "$d/storages.json"
  echo "image-bytes" > "$d/cache/debian-13-generic-amd64.qcow2"; echo "abcdef0123456789abcdef" > "$d/cache/debian-13-generic-amd64.qcow2.sha512"
  printf '== 2. keepalived and ser2net (Debian'"'"'s packages) ==\nOK    keepalived 2.3.3 installed\nDONE  the radios are detected and named\nDONE  the sync key is at /etc/zradio/sync.key (0600). On the OTHER radio VM (10.20.30.5), as root, run:\n      zradio-sync trust --sync-key '"'"'ssh-ed25519 AAAAkey'"'"' --host-key '"'"'ssh-ed25519 AAAAhost'"'"'\n== installed. Next: … ==\n' > "$d/install.log"
  echo 0 > "$d/install.rc"; echo "done" > "$d/ci-status"; echo "$ha" > "$d/ha"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" hostname 'echo nodea'
  fake "$d/bin" pvesh "case \"\$1 \$2\" in
    'get /cluster/mapping/usb') cat '$d/usbmap.json';;
    'get /cluster/resources') cat '$d/vms.json';;
    'get /cluster/nextid') echo 109;;
    'get /storage') cat '$d/storages.json';;
    'get /storage/local') python3 -c 'import json,sys; print(json.dumps([s for s in json.load(open(sys.argv[1])) if s[\"storage\"] == \"local\"][0]))' '$d/storages.json';;
    get\\ *) exit 2;;
    *) $rec; [ ! -f '$d/pvesh-fail' ];;
  esac"
  fake "$d/bin" ha-manager "case \"\$1\" in status) [ \"\$(cat '$d/ha')\" = 1 ];; *) $rec; [ ! -f '$d/ha-fail' ];; esac"
  fake "$d/bin" wget "$rec; out=\${*: -1}; case \"\$2\" in */SHA512SUMS) printf '%s  debian-13-generic-amd64.qcow2\n' \"\$(cat '$d/sum' 2>/dev/null || echo image-from-the-web | sha512sum | cut -d' ' -f1)\" > \"\$out\";; *) echo image-from-the-web > \"\$out\";; esac"
  # qm: create/set/start recorded; the guest answers from the node's knob files
  cat > "$d/bin/qm" <<SH
#!/usr/bin/env bash
j() { python3 -c 'import json,sys; print(json.dumps({"exitcode": int(sys.argv[1]), "exited": 1, "out-data": sys.stdin.read()}))' "\$1"; }
case "\$1" in
  agent) [ -f "$d/agent-down" ] && exit 1; exit 0;;
  guest)
    case "\$2" in
      cmd) echo '[{"name":"lo","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1"}]},{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"192.0.2.44"}]},{"name":"eth1","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.20.30.6"}]}]';;
      exec) shift 6; echo "guest: \$*" >> "$d/calls"   # guest exec <id> --timeout <n> -- <command…>
        case "\$*" in
          "cloud-init status") printf 'status: %s\n' "\$(cat "$d/ci-status")" | j 0;;
          "cat /root/zradio-install.rc") j 0 < "$d/install.rc";;
          "cat /var/log/zradio-install.log") j 0 < "$d/install.log";;
          "systemctl start zradio.target") : | j "\$([ -f "$d/start-fail" ] && echo 1 || echo 0)";;
          *zradio-serve\ status) echo "this VM: standby, ready" | j 0;;
          *) : | j 0;;
        esac;;
    esac;;
  *) echo "qm \$*" >> "$d/calls"; [ ! -f "$d/qm-fail" ];;
esac
SH
  chmod +x "$d/bin/qm"
}
zvm() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VM_SYS="$d/sys" ZRADIO_VM_PVE="$d/pve" ZRADIO_VM_CACHE="$d/cache" ZRADIO_VM_WAIT=0 ZRADIO_VM_KEYS="$d/keys" bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }
BASE=(--name zr2 --self 10.20.30.6/24 --peer 10.20.30.5 --vip 10.20.30.50/24 --pair-bridge vmbrpair)
vmconf() { printf '%s\n' "${@:3}" > "$1/pve/nodes/${2%%/*}/qemu-server/${2##*/}.conf"; }      # vmconf <dir> <node>/<id> <lines…>

echo "-- sticks: what the node has that the kit knows"
node "$T/s"; zvm "$T/s" sticks
check "both sticks listed by port and id, with the kinds the table gives them; the keyboard is not" bash -c '[ "$2" = 0 ] && grep -q "1-3.2.1 *10c4:ea70 .*CP2105" "$1/out" && grep -q "1-3.2.4 *10c4:ea60 .*zigbee.*Sonoff" "$1/out" && ! grep -q keyboard "$1/out" && grep -c "none yet" "$1/out" | grep -qx 2' _ "$T/s" "$RC"
echo '[{"id":"zwave","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70"]},{"id":"elsewhere","map":["node=nodeb,id=10c4:ea60"]}]' > "$T/s/usbmap.json"; zvm "$T/s" sticks
check "a mapping that names the stick on THIS node is shown; one for another node only is not" bash -c 'grep -q "10c4:ea70 .*USB mapping here: zwave" "$1/out" && grep -q "10c4:ea60 .*USB mapping here: none yet" "$1/out"' _ "$T/s"
check "sticks changes nothing" bash -c '[ ! -s "$1/calls" ]' _ "$T/s"
node "$T/s0" none; zvm "$T/s0" sticks
check "no stick: exit 1, and how a stick the table does not know is passed through" bash -c '[ "$2" = 1 ] && grep -q "use --usb-mapping" "$1/out"' _ "$T/s0" "$RC"

echo "-- create, report mode: everything is said, nothing is done"
node "$T/r"; zvm "$T/r" create "${BASE[@]}"
check "exit 0, REPORT ONLY, no qm / pvesh / ha-manager / wget call, no file written" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && [ ! -s "$1/calls" ] && [ -z "$(ls "$1/store/snippets")" ]' _ "$T/r" "$RC"
check "it says the two USB mappings it would make, the VM, the HA resource, the strict rule and the start — in that order" bash -c '
  o=$(grep -n "WOULD" "$1/out"); l() { printf "%s\n" "$o" | grep -m1 -- "$1" | cut -d: -f1; }
  a=$(l "pvesh create /cluster/mapping/usb --id zradio-10c4ea70 --map node=nodea,id=10c4:ea70"); b=$(l "pvesh create /cluster/mapping/usb --id zradio-10c4ea60 --map node=nodea,id=10c4:ea60")
  c=$(l "qm create 109 --name zr2"); e=$(l "ha-manager add vm:109 --state stopped --max_restart 3 --max_relocate 0"); f=$(l "ha-manager rules add node-affinity zr2-on-nodea --resources vm:109 --nodes nodea --strict 1"); g=$(l "ha-manager set vm:109 --state started")
  [ -n "$a" ] && [ -n "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$e" ] && [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ]' _ "$T/r"
check "the VM as it would be: both networks, both sticks, onboot" bash -c 'grep "WOULD qm create" "$1/out" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=dhcp --net1 virtio,bridge=vmbrpair --ipconfig1 ip=10.20.30.6/24 .*--onboot 1 .*--usb0 mapping=zradio-10c4ea70 --usb1 mapping=zradio-10c4ea60"' _ "$T/r"

echo "-- create --run on a clean node"
node "$T/c"; zvm "$T/c" create "${BASE[@]}" --run
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
check "…and its one command is the kit's installer, with its log and its exit code kept" python3 -c '
import sys, yaml
r = yaml.safe_load(open(sys.argv[1]))["runcmd"]
assert r[0] == ["systemctl", "enable", "--now", "qemu-guest-agent"]
assert r[1][2] == "mkdir -p /opt/zradio/kit && tar -xzf /root/zradio-kit.tgz -C /opt/zradio/kit"
assert r[2][2] == "bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --run --detect > /var/log/zradio-install.log 2>&1; echo $? > /root/zradio-install.rc", r[2][2]' "$Y"
if command -v cloud-init >/dev/null 2>&1; then
  check "…and the real cloud-init accepts the file (cloud-init schema)" bash -c 'cloud-init schema --config-file "$1" 2>&1 | grep -q "^Valid schema"' _ "$Y"
else echo "  (cloud-init is not installed here: its schema check of the file is skipped)"; fi
check "the VM carries that file, the tag and a description that says what it is" bash -c 'grep "^qm create" "$1/calls" | grep -q -- "--cicustom user=local:snippets/zr2-zradio.yaml .*--tags zradio --description zr2: one radio VM of a zradio pair"' _ "$T/c"
check "the installer's result is shown: the radios it found and the line for the other VM; not its OK lines" bash -c 'grep -q "| DONE  the radios are detected and named" "$1/out" && grep -q "zradio-sync trust --sync-key" "$1/out" && ! grep -q "keepalived 2.3.3 installed" "$1/out" && grep -q "the kit is installed in zr2" "$1/out"' _ "$T/c"
check "the VM's addresses are shown; without --start it is NOT put into the pair" bash -c 'grep -q "addresses: eth0 192.0.2.44, eth1 10.20.30.6" "$1/out" && grep -q "NOT in the pair yet" "$1/out" && ! grep -q "guest: systemctl start zradio.target" "$1/calls"' _ "$T/c"

echo "-- options"
node "$T/o"; zvm "$T/o" create "${BASE[@]}" --run --start --first --hookscript local:snippets/my-hook.sh --conf SYNC_TZ=Europe/Berlin --conf ELECTION=observe --vmid 150 --priority 110 --vrid 77 --pair-mac BC:24:11:0A:63:36 --memory 1024 --cores 1 --disk 12G
check "--start joins the pair after the install; --first reaches install.sh" bash -c '[ "$2" = 0 ] && grep -q "guest: systemctl start zradio.target" "$1/calls" && grep -q "install.sh --conf /root/zradio.conf --run --detect --first > " "$1/store/snippets/zr2-zradio.yaml" && grep -q "it is in the pair" "$1/out"' _ "$T/o" "$RC"
check "--hookscript, --vmid, --pair-mac, --memory, --cores, --disk reach qm" bash -c 'grep "^qm create 150 " "$1/calls" | grep -q -- "--cores 1 --memory 1024 .*--net1 virtio=BC:24:11:0A:63:36,bridge=vmbrpair .*--hookscript local:snippets/my-hook.sh" && grep -q "^qm disk resize 150 scsi0 12G" "$1/calls"' _ "$T/o"
check "--conf lines, --priority and --vrid reach zradio.conf" bash -c 'grep -q "^      SYNC_TZ=Europe/Berlin$" "$1" && grep -q "^      ELECTION=observe$" "$1" && grep -q "^      PRIORITY=110$" "$1" && grep -q "^      VRID=77$" "$1"' _ "$T/o/store/snippets/zr2-zradio.yaml"
node "$T/o2"; zvm "$T/o2" create --name zr2 --self 192.0.2.6/24 --peer 192.0.2.5 --vip 192.0.2.50/24 --gateway 192.0.2.1 --no-ha --run
check "no --pair-bridge: one interface, --self on the LAN with the gateway" bash -c '[ "$2" = 0 ] && grep "^qm create" "$1/calls" | grep -q -- "--net0 virtio,bridge=vmbr0 --ipconfig0 ip=192.0.2.6/24,gw=192.0.2.1 --serial0" && ! grep -q "net1" "$1/calls"' _ "$T/o2" "$RC"
check "--no-ha: a plain qm start, no ha-manager call" bash -c 'grep -q "^qm start 109" "$1/calls" && ! grep -q "^ha-manager" "$1/calls"' _ "$T/o2"
zvm "$T/o2" create --name zr3 --self 192.0.2.6/24 --peer 192.0.2.5 --vip 192.0.2.50/24
check "no --pair-bridge and no --gateway: refused before anything (exit 2)" bash -c '[ "$2" = 2 ] && grep -q "gateway A.B.C.D is needed" "$1/out"' _ "$T/o2" "$RC"

echo "-- USB mappings: yours, the cluster's, twins"
# (the JSON as a PVE 9.2 cluster prints it: description, digest and type beside id and map; resources with their other fields)
node "$T/m"; echo '[{"description":"a Zigbee stick; per-node entry","digest":"bebca8ef7d2cfaacc993da4be2368544977c2c14","id":"zigbee","map":["node=nodea,id=10c4:ea60"],"type":"usb"},{"description":"a Z-Wave stick","digest":"bebca8ef7d2cfaacc993da4be2368544977c2c14","id":"zwave","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70"],"type":"usb"}]' > "$T/m/usbmap.json"
echo '[{"cpu":0.01,"disk":0,"id":"qemu/102","maxcpu":2,"maxmem":4294967296,"name":"other","node":"nodea","status":"running","template":0,"type":"qemu","uptime":5,"vmid":102},{"id":"qemu/104","name":"more","node":"nodeb","status":"running","type":"qemu","vmid":104}]' > "$T/m/vms.json"
vmconf "$T/m" nodea/102 "agent: enabled=1" "ipconfig0: ip=dhcp" "net0: virtio=BC:24:11:62:1B:1D,bridge=vmbr0" "usb0: host=0557:9241"
zvm "$T/m" create "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "--usb-mapping: those two are passed through, none is made" bash -c '[ "$2" = 0 ] && grep "^qm create" "$1/calls" | grep -q -- "--usb0 mapping=zwave --usb1 mapping=zigbee" && ! grep -q "^pvesh" "$1/calls"' _ "$T/m" "$RC"
zvm "$T/m" create "${BASE[@]}" --name zr9 --usb-mapping zwave --usb-mapping nosuch
check "a mapping with no entry for this node: refused, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "USB mapping .nosuch. has no entry for nodea" "$1/out" && grep -q "nothing was changed" "$1/out"' _ "$T/m" "$RC"
node "$T/m2" dark; cp "$T/m/usbmap.json" "$T/m2/usbmap.json"; zvm "$T/m2" create "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee
check "the mapped sticks are not on the bus (their ports are off) and there is no hookscript: refused" bash -c '[ "$2" = 1 ] && grep -c "no USB device 10c4:ea.0 on nodea right now" "$1/out" | grep -qx 2' _ "$T/m2" "$RC"
zvm "$T/m2" create "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --hookscript local:snippets/ports.sh
check "…with a hookscript: said, and accepted (the hook switches the ports on before the start)" bash -c '[ "$2" = 0 ] && grep -c "NOTE  mapping .*taken as a port your hookscript switches on" "$1/out" | grep -qx 2' _ "$T/m2" "$RC"
node "$T/m3"; echo '[{"id":"zradio-10c4ea70","map":["node=nodeb,id=10c4:ea70"]},{"id":"zradio-10c4ea60","map":["node=nodea,id=10c4:ea60"]}]' > "$T/m3/usbmap.json"; zvm "$T/m3" create "${BASE[@]}" --run
check "the second node of a pair: the kit's mapping exists for the OTHER node — this node's entry is added to it, the other's kept" bash -c 'grep -q "^pvesh set /cluster/mapping/usb/zradio-10c4ea70 --map node=nodeb,id=10c4:ea70 --map node=nodea,id=10c4:ea70$" "$1/calls" && ! grep -q "pvesh create" "$1/calls" && ! grep -q "zradio-10c4ea60 --map" "$1/calls"' _ "$T/m3"
node "$T/m4" twins; zvm "$T/m4" create "${BASE[@]}" --run
check "two sticks of the same model: one mapping each, told apart by their port" bash -c 'grep -q "^pvesh create /cluster/mapping/usb --id zradio-10c4ea60-1 --map node=nodea,id=10c4:ea60,path=1-3.2.1 " "$1/calls" && grep -q "^pvesh create /cluster/mapping/usb --id zradio-10c4ea60-2 --map node=nodea,id=10c4:ea60,path=1-3.2.4 " "$1/calls" && grep "^qm create" "$1/calls" | grep -q -- "--usb0 mapping=zradio-10c4ea60-1 --usb1 mapping=zradio-10c4ea60-2"' _ "$T/m4"
node "$T/m5" none; zvm "$T/m5" create "${BASE[@]}" --run
check "no stick at all: refused, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "no stick on nodea" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m5" "$RC"
zvm "$T/m5" create "${BASE[@]}" --run --allow-no-radios
check "--allow-no-radios (a drill): the VM is built without a USB line" bash -c '[ "$2" = 0 ] && grep -q "^qm create" "$1/calls" && ! grep -q "usb0" "$1/calls"' _ "$T/m5" "$RC"

echo "-- --no-usb: a drill on a node whose sticks are in use"
node "$T/d"; echo '[{"id":"zwave","map":["node=nodea,id=10c4:ea70"]},{"id":"zigbee","map":["node=nodea,id=10c4:ea60"]}]' > "$T/d/usbmap.json"; echo '[{"vmid":101,"name":"live1","node":"nodea","status":"running"}]' > "$T/d/vms.json"
vmconf "$T/d" nodea/101 "usb0: mapping=zwave" "usb1: mapping=zigbee" "ipconfig1: ip=10.20.30.5/24"
echo 1 > "$T/d/install.rc"; printf 'DONE  keepalived 2.3.3 installed\n    FAIL  no Z-Wave or Zigbee stick found on this VM\nFAIL  zradio-detect did not end clean — read its lines above\n' > "$T/d/install.log"
zvm "$T/d" create --name zr-drill --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --run
check "the live VM holds both sticks; --no-usb builds beside it without a USB line and without touching a mapping" bash -c '[ "$2" = 0 ] && grep -q "^qm create 109 --name zr-drill" "$1/calls" && ! grep -q "usb0" "$1/calls" && ! grep -q "^pvesh" "$1/calls"' _ "$T/d" "$RC"
check "the installer's \"no stick\" end is the drill's expected end: said so, exit 0, and how to remove the drill" bash -c 'grep -q "the drill went as far as a VM without a stick can" "$1/out" && grep -q "To remove it: ha-manager remove vm:109; ha-manager rules remove zr-drill-on-nodea; qm stop 109; qm destroy 109 --purge" "$1/out"' _ "$T/d" "$RC"
check "the drill is under Proxmox HA like the real thing (the rule and the restart are what it is for)" bash -c 'grep -q "^ha-manager rules add node-affinity zr-drill-on-nodea .*--strict 1" "$1/calls" && grep -q "^ha-manager set vm:109 --state started" "$1/calls"' _ "$T/d"
echo 1 > "$T/d/install.rc"; printf 'FAIL  apt-get install keepalived failed\n' > "$T/d/install.log"; echo '[{"vmid":101,"name":"live1","node":"nodea","status":"running"}]' > "$T/d/vms.json"
zvm "$T/d" create --name zr-drill2 --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --run
check "the line the drill is recognised by is the one the kit's installer really prints when the detection fails" bash -c 'grep -q "bad \"zradio-detect did not end clean" "$1/guest/install.sh" && grep -q "printf .FAIL  %s" "$1/guest/install.sh"' _ "$KIT"
check "a drill whose installer failed for ANOTHER reason is a failure" bash -c '[ "$2" = 1 ] && grep -q "install.sh ended 1 in zr-drill2" "$1/out"' _ "$T/d" "$RC"
zvm "$T/d" create --name zr-drill3 --self 10.20.30.77/24 --peer 10.20.30.78 --vip 10.20.30.79/24 --pair-bridge vmbrpair --no-usb --start
check "--no-usb with --start, or with --usb-mapping: refused" bash -c '[ "$2" = 2 ] && grep -q "is a drill" "$1/out"' _ "$T/d" "$RC"

echo "-- refused before anything is changed"
node "$T/x"; echo '[{"vmid":101,"name":"zr2","node":"nodeb","status":"stopped"}]' > "$T/x/vms.json"; zvm "$T/x" create "${BASE[@]}" --run
check "a VM of that name exists (even stopped, even on the other node): refused — this tool never rebuilds one" bash -c '[ "$2" = 1 ] && grep -q "a VM named zr2 exists already (on nodeb, stopped)" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x" "$RC"
node "$T/x2"; echo '[{"vmid":150,"name":"other","node":"nodea","status":"running"}]' > "$T/x2/vms.json"; zvm "$T/x2" create "${BASE[@]}" --vmid 150 --run
check "the id is taken: refused" bash -c '[ "$2" = 1 ] && grep -q "the id 150 is taken (other)" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x2" "$RC"
node "$T/x3"; echo '[{"vmid":108,"name":"old2","node":"nodea","status":"running"}]' > "$T/x3/vms.json"; vmconf "$T/x3" nodea/108 "ipconfig1: ip=10.20.30.6/24" "usb0: host=1-1"; zvm "$T/x3" create "${BASE[@]}" --run
check "a RUNNING VM has --self already: refused (two VMs on one address)" bash -c '[ "$2" = 1 ] && grep -q "old2 runs with the address 10.20.30.6 already" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x3" "$RC"
echo '[{"vmid":108,"name":"old2","node":"nodea","status":"stopped"}]' > "$T/x3/vms.json"; zvm "$T/x3" create "${BASE[@]}" --run
check "…the same VM stopped (the one this VM replaces): said, and the build goes on" bash -c '[ "$2" = 0 ] && grep -q "NOTE  old2 (stopped) is configured with 10.20.30.6 too: it must stay stopped" "$1/out" && grep -q "^qm create" "$1/calls"' _ "$T/x3" "$RC"
node "$T/x4"; cp "$T/m/usbmap.json" "$T/x4/usbmap.json"; echo '[{"vmid":108,"name":"old2","node":"nodea","status":"running"}]' > "$T/x4/vms.json"; vmconf "$T/x4" nodea/108 "usb0: mapping=zwave" "usb1: mapping=zigbee"
zvm "$T/x4" create "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "a RUNNING VM on this node passes the same mapping through: refused (two VMs on one stick)" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device 10c4:ea.0 (mapping z[a-z]* here) passed through already" "$1/out" | grep -qx 2 && [ ! -s "$1/calls" ]' _ "$T/x4" "$RC"
zvm "$T/x4" create "${BASE[@]}" --run
check "…and so is building with the kit's OWN mappings while that VM runs on the same sticks under other mapping names" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device" "$1/out" | grep -qx 2 && [ ! -s "$1/calls" ]' _ "$T/x4" "$RC"
vmconf "$T/x4" nodea/108 "usb0: host=10C4:EA70" "usb1: host=1-9"; zvm "$T/x4" create "${BASE[@]}" --run
check "…or passed through by its id (host=vid:pid), whatever the letter case: refused for that stick, not for the other" bash -c '[ "$2" = 1 ] && grep -c "the running VM old2 on nodea has the USB device" "$1/out" | grep -qx 1 && grep -q "USB device 10c4:ea70" "$1/out"' _ "$T/x4" "$RC"
vmconf "$T/x4" nodea/108 "usb0: mapping=zwave2" "[snap1]" "usb0: mapping=zwave"; zvm "$T/x4" create "${BASE[@]}" --usb-mapping zwave --usb-mapping zigbee --run
check "…a mapping whose name only starts the same, or a usb line in a snapshot's section, is not this stick: not refused" eq "$RC" 0
echo '[{"vmid":108,"name":"old2","node":"nodea","status":"stopped"}]' > "$T/x4/vms.json"; vmconf "$T/x4" nodea/108 "usb0: mapping=zwave" "usb1: mapping=zigbee"; : > "$T/x4/calls"; zvm "$T/x4" create "${BASE[@]}" --name zr8 --usb-mapping zwave --usb-mapping zigbee --run
check "…the same VM STOPPED still carries the sticks: the build goes on (stopping it was the point)" eq "$RC" 0
check "…and it is said that its usb lines should come off (something may start it: a backup in stop mode does)" bash -c 'grep -c "NOTE  old2 (not running) on nodea still has the USB device" "$1/out" | grep -qx 2' _ "$T/x4"
node "$T/x5" both 0; zvm "$T/x5" create "${BASE[@]}" --run
check "Proxmox HA does not answer and --no-ha was not said: refused" bash -c '[ "$2" = 1 ] && grep -q "ha-manager status does not answer" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x5" "$RC"
node "$T/x6"; echo '[{"storage":"local","type":"dir","content":"images,iso","path":"/x"},{"storage":"local-zfs","type":"zfspool","content":"images"}]' > "$T/x6/storages.json"; zvm "$T/x6" create "${BASE[@]}" --run
check "the snippets storage does not hold snippets: refused, with the command that allows it" bash -c '[ "$2" = 1 ] && grep -q "does not hold snippets (pvesm set local --content" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x6" "$RC"
node "$T/x7"; : > "$T/x7/keys"; zvm "$T/x7" create "${BASE[@]}" --run
check "no public key for root: refused (the VM would have no way in)" bash -c '[ "$2" = 1 ] && grep -q "no public key in" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x7" "$RC"
for bad in "--name Zr2" "--self 10.20.30.6" "--peer 10.20.30.6" "--vip 10.20.30.5/24" "--vrid 0" "--priority 255" "--conf NAME=x" "--conf lower=1" "--hookscript /root/hook.sh" "--disk 8"; do
  node "$T/a"; zvm "$T/a" create "${BASE[@]}" $bad --run
  check "refused before anything: $bad" bash -c '[ "$2" = 2 ] && grep -q "^die: " "$1/out" && [ ! -s "$1/calls" ]' _ "$T/a" "$RC"
done

echo "-- the image: downloaded once, and only when its checksum is the published one"
node "$T/i"; find "$T/i/cache" -type f -delete; zvm "$T/i" create "${BASE[@]}" --run
check "no image in the cache: downloaded, checked against SHA512SUMS, kept" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/cache/debian-13-generic-amd64.qcow2")" = image-from-the-web ] && [ -s "$1/cache/debian-13-generic-amd64.qcow2.sha512" ] && grep -q "^wget -q https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS" "$1/calls"' _ "$T/i" "$RC"
node "$T/i2"; find "$T/i2/cache" -type f -delete; echo 0000 > "$T/i2/sum"; zvm "$T/i2" create "${BASE[@]}" --run
check "the checksum does not match: no image kept, no VM made" bash -c '[ "$2" = 1 ] && grep -q "sha512 mismatch" "$1/out" && [ -z "$(ls "$1/cache")" ] && ! grep -q "^qm create" "$1/calls"' _ "$T/i2" "$RC"

echo "-- when a step fails"
node "$T/f"; : > "$T/f/qm-fail"; zvm "$T/f" create "${BASE[@]}" --run
check "qm create fails: said, exit 1, and nothing after it (no HA entry for a VM that does not exist)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  qm create 109 .* failed" "$1/out" && ! grep -q "^ha-manager" "$1/calls" && ! grep -q "^qm set" "$1/calls"' _ "$T/f" "$RC"
node "$T/f2"; : > "$T/f2/ha-fail"; zvm "$T/f2" create "${BASE[@]}" --run
check "ha-manager add fails: the VM is not started" bash -c '[ "$2" = 1 ] && ! grep -q "state started" "$1/calls" && ! grep -q "^qm start" "$1/calls"' _ "$T/f2" "$RC"
node "$T/f3"; : > "$T/f3/agent-down"; zvm "$T/f3" create "${BASE[@]}" --run
check "the guest agent never answers: exit 1, where to look" bash -c '[ "$2" = 1 ] && grep -q "no guest agent in" "$1/out" && grep -q "qm terminal 109" "$1/out"' _ "$T/f3" "$RC"
node "$T/f4"; echo error > "$T/f4/ci-status"; zvm "$T/f4" create "${BASE[@]}" --run --start
check "cloud-init ends in error: exit 1, the VM is not put into the pair" bash -c '[ "$2" = 1 ] && grep -q "cloud-init ended .error." "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/f4" "$RC"
node "$T/f5"; echo 1 > "$T/f5/install.rc"; printf 'FAIL  zradio-detect did not end clean\n== 1 FAIL ==\n' > "$T/f5/install.log"; zvm "$T/f5" create "${BASE[@]}" --run --start
check "the kit's installer failed in the VM: its FAIL line is shown, exit 1, the VM is not put into the pair" bash -c '[ "$2" = 1 ] && grep -q "| *FAIL  zradio-detect did not end clean" "$1/out" && grep -q "install.sh ended 1 in zr2" "$1/out" && ! grep -q "guest: systemctl start" "$1/calls"' _ "$T/f5" "$RC"

echo "-- help"
check "--help names both commands and says that nothing is changed without --run" bash -c 'bash "$1" --help | grep -q "zradio-vm sticks" && bash "$1" --help | grep -q "zradio-vm create --name NAME" && bash "$1" --help | grep -q "Report mode unless --run" && ! bash "$1" --help | grep -q "^set -uo"' _ "$TOOL"
finish
