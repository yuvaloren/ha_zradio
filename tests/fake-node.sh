# shellcheck shell=bash disable=SC2034
# tests/fake-node.sh — a fake Proxmox cluster (nodea, nodeb) for ./install.sh: qm, pvesh, ha-manager, wget and hostname
# are fakes on PATH (recorded in <dir>/calls); the USB trees, /etc/pve, the image cache, the snippets storage and the
# bridges are folders. The guest agent is real bash: a script install.sh sends into a VM is RUN, with the VM's paths
# (/etc, /var, /root, /opt, /usr/local) turned into <dir>/g/<vmid>/root/… — so the scripts themselves are tested.
#   node <dir> [sticks on nodea: both|zwave|none|twins|dark] [ha: 1|0]
#   canned guests (the default): cloud-init, systemctl, zradio-sync and zradio-serve in the VM are fakes, and the
#     kit's installer "runs" by copying <dir>/install.log and install.rc into place.          knobs: files in <dir>
#   live (touch <dir>/live): qm create really registers the VM in the cluster's files, and the guests are the fake
#     radio VMs of tests/fake-guest.sh, in which the kit's real installer runs (tests/t-e2e.sh).
#   FAKE_NODE=nodeb: the command runs on the other node (its sticks: <dir>/sys-nodeb).
node() {
  local d=$1 sticks=${2:-both} ha=${3:-1}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/gbin" "$d/sys" "$d/sys-nodeb" "$d/pve/nodes/nodea/qemu-server" "$d/pve/nodes/nodeb/qemu-server" "$d/cache" "$d/store/snippets" "$d/g" "$d/net/vmbr0/bridge" "$d/net/vmbr1/bridge" "$d/net/eth0"; : > "$d/calls"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyFakeKeyFakeKeyFakeKeyFakeKeyFakeKey1234 admin@x" > "$d/keys"
  usb() { mkdir -p "$1/$2"; echo "$3" > "$1/$2/idVendor"; echo "$4" > "$1/$2/idProduct"; echo "$5" > "$1/$2/product"; }
  local s; for s in "$d/sys" "$d/sys-nodeb"; do usb "$s" usb1 1d6b 0002 "xHCI Host Controller"; usb "$s" 1-4 0557 9241 "a keyboard"; done
  case "$sticks" in
    both) usb "$d/sys" 1-3.2.1 10c4 ea70 "CP2105 Dual USB to UART Bridge Controller"; usb "$d/sys" 1-3.2.4 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus";;
    zwave) usb "$d/sys" 1-3.2.1 10c4 ea70 "CP2105 Dual USB to UART Bridge Controller";;
    twins) usb "$d/sys" 1-3.2.1 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus"; usb "$d/sys" 1-3.2.4 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus";;
    none|dark) ;;
  esac
  usb "$d/sys-nodeb" 2-1 10c4 ea70 "CP2105 Dual USB to UART Bridge Controller"; usb "$d/sys-nodeb" 2-2 10c4 ea60 "Sonoff Zigbee 3.0 USB Dongle Plus"
  echo '[]' > "$d/usbmap.json"; echo '[]' > "$d/vms.json"
  echo '[{"storage":"local","type":"dir","content":"images,snippets,iso,vztmpl","path":"'"$d"'/store"},{"storage":"local-zfs","type":"zfspool","content":"images,rootdir"}]' > "$d/storages.json"
  echo "image-bytes" > "$d/cache/debian-13-generic-amd64.qcow2"; echo "abcdef0123456789abcdef" > "$d/cache/debian-13-generic-amd64.qcow2.sha512"
  printf '== 2. keepalived and ser2net (Debian'"'"'s packages) ==\nOK    keepalived 2.3.3 installed\nDONE  the radios are detected and named\n== installed ==\n' > "$d/install.log"
  echo 0 > "$d/install.rc"; echo "done" > "$d/ci-status"; echo "$ha" > "$d/ha"; printf 'ZWAVE=synced\nZIGBEE=synced\n' > "$d/radios.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" hostname 'echo "${FAKE_NODE:-nodea}"'
  fake "$d/bin" ha-manager "case \"\$1\" in status) [ \"\$(cat '$d/ha')\" = 1 ];; *) $rec; [ ! -f '$d/ha-fail' ] || exit 1; case \"\$1 \$3 \$4\" in 'set --state started') '$d/bin/vmreg' start \"\${2#vm:}\";; esac;; esac"
  fake "$d/bin" wget "$rec; out=\${*: -1}; case \"\$2\" in */SHA512SUMS) printf '%s  debian-13-generic-amd64.qcow2\n' \"\$(cat '$d/sum' 2>/dev/null || echo image-from-the-web | sha512sum | cut -d' ' -f1)\" > \"\$out\";; *) echo image-from-the-web > \"\$out\";; esac"
  fake "$d/bin" qm "$rec; [ ! -f '$d/qm-fail' ] || exit 1; case \"\$1\" in create) '$d/bin/vmreg' create \"\${@:2}\";; start) '$d/bin/vmreg' start \"\$2\";; esac; exit 0"
  fake "$d/bin" pvesh "case \"\$1 \$2\" in
    'get /cluster/mapping/usb') cat '$d/usbmap.json';;
    'get /cluster/resources') cat '$d/vms.json';;
    'get /cluster/nextid') if [ -f '$d/live' ]; then python3 -c 'import json,sys; print(max([99] + [v[\"vmid\"] for v in json.load(open(sys.argv[1]))]) + 1)' '$d/vms.json'; else echo 109; fi;;
    'get /storage') cat '$d/storages.json';;
    'get /storage/local') python3 -c 'import json,sys; print(json.dumps([s for s in json.load(open(sys.argv[1])) if s[\"storage\"] == \"local\"][0]))' '$d/storages.json';;
    *\\ /nodes/*/qemu/*/agent/*) exec '$d/bin/ga' \"\$@\";;
    get\\ *) exit 2;;
    *) $rec; [ ! -f '$d/pvesh-fail' ];;
  esac"
  # vmreg: in a live cluster, qm create / start show up in the cluster's own files, as on a real one
  cat > "$d/bin/vmreg" <<SH
#!/usr/bin/env bash
[ -f "$d/live" ] || exit 0
python3 - "$d" "\${FAKE_NODE:-nodea}" "\$@" <<'PY'
import json, sys
d, node, verb, vmid, rest = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
vms = json.load(open(d + "/vms.json"))
if verb == "create":
    o = dict(zip([a[2:] for a in rest[0::2]], rest[1::2]))
    vms.append({"vmid": vmid, "name": o["name"], "node": node, "status": "stopped", "tags": o.get("tags", ""), "type": "qemu"})
    with open("%s/pve/nodes/%s/qemu-server/%d.conf" % (d, node, vmid), "w") as f:
        for k, v in sorted(o.items()):
            if k.startswith(("net", "ipconfig", "usb")) or k in ("name", "tags", "cicustom"): f.write("%s: %s\n" % (k, v))
else:
    for v in vms:
        if v["vmid"] == vmid: v["status"] = "running"
json.dump(vms, open(d + "/vms.json", "w"))
PY
SH
  # ga: the guest agent — pvesh create|get /nodes/<node>/qemu/<vmid>/agent/{ping,exec,exec-status} …
  cat > "$d/bin/ga" <<SH
#!/usr/bin/env bash
d="$d"; verb=\$1; path=\$2; shift 2
id=\${path#/nodes/*/qemu/}; id=\${id%%/*}; what=\${path##*/}; G="\$d/g/\$id"; R="\$G/root"
script="" pid=""
while [ \$# -gt 0 ]; do case "\$1" in --input-data) script=\$2; shift 2;; --pid) pid=\$2; shift 2;; *) shift;; esac; done
up() { [ ! -f "\$d/agent-down" ] && [ ! -f "\$d/agent-down-\$id" ] && { [ ! -f "\$d/live" ] || [ -d "\$G" ]; }; }
mk() { # a canned guest, made at the first word to it; the cloud-init file of a VM this run created is put in place
  [ -d "\$R" ] && return 0
  mkdir -p "\$R/usr/local/sbin" "\$R/etc/zradio" "\$R/var/log" "\$R/var/lib/zradio" "\$R/root" "\$R/opt" "\$G/bin"
  cp "\$d/radios.conf" "\$R/etc/zradio/radios.conf"
  printf '#!/usr/bin/env bash\ncase "\$1" in keys) echo "SYNCKEY ssh-ed25519 %s"; echo "HOSTKEY ssh-ed25519 %s";; trust) [ ! -f %q ] || exit 1; echo "\$*" > %q;; peer-hello) [ ! -f %q ] || exit 255; echo "hello name=peer serving=no";; esac\n' \\
    "\$(printf 'SyncKeyOfVm%sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "\$id" | cut -c1-68)" "\$(printf 'HostKeyOfVm%sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "\$id" | cut -c1-68)" "\$d/trust-fail" "\$G/trusted" "\$d/hello-fail" > "\$R/usr/local/sbin/zradio-sync"
  printf '#!/usr/bin/env bash\necho "this VM: standby, ready"\n' > "\$R/usr/local/sbin/zradio-serve"
  chmod +x "\$R/usr/local/sbin/"*
}
files() { # the cloud-init file's write_files, as cloud-init would have put them (once)
  [ -f "\$G/ci-done" ] && return 0
  local name; name=\$(grep -m1 "^qm create \$id " "\$d/calls" | sed -n 's/.* --name \\([^ ]*\\).*/\\1/p')
  [ -n "\$name" ] && [ -f "\$d/store/snippets/\$name-zradio.yaml" ] || return 0
  python3 - "\$d/store/snippets/\$name-zradio.yaml" "\$R" <<'PY' && : > "\$G/ci-done"
import base64, os, sys, yaml
for f in yaml.safe_load(open(sys.argv[1])).get("write_files", []):
    p = sys.argv[2] + f["path"]; os.makedirs(os.path.dirname(p), exist_ok=True)
    data = base64.b64decode(f["content"]) if f.get("encoding") == "b64" else f["content"].encode()
    open(p, "wb").write(data)
PY
}
case "\$what" in
  ping) up;;
  exec) up || exit 1
    [ -f "\$d/live" ] || mk; mkdir -p "\$R/var/log" "\$R/root" "\$R/opt"; files      # (a real VM has these)
    mkdir -p "\$G/x"; n=\$(( \$(ls "\$G/x" | wc -l) + 1000 ))
    printf 'guest: %s\n' "\$(printf '%s' "\$script" | head -1 | cut -c1-240)" >> "\$d/calls"
    if [ ! -f "\$d/live" ] && [[ "\$script" == *"guest/install.sh --conf"* ]]; then
      cp "\$d/install.log" "\$R/var/log/zradio-install.log"; cp "\$d/install.rc" "\$R/root/zradio-install.rc"; : > "\$G/x/\$n.out"; echo 0 > "\$G/x/\$n.rc"
    else
      r=\$(printf '%s' "\$script" | sed -E "s#(^|[ \"'=<>(;])/(etc|var|root|opt|usr/local)/#\\\\1\$R/\\\\2/#g")
      ( [ ! -f "\$d/genv.sh" ] || . "\$d/genv.sh" "\$id"; cd "\$G" && PATH="\$G/bin:\$d/gbin:\$PATH" bash -c "\$r" ) > "\$G/x/\$n.out" 2> "\$G/x/\$n.err"; echo \$? > "\$G/x/\$n.rc"
    fi
    echo "{\"pid\": \$n}";;
  exec-status) python3 -c 'import json, sys; print(json.dumps({"exited": 1, "exitcode": int(open(sys.argv[1] + ".rc").read()), "out-data": open(sys.argv[1] + ".out").read()}))' "\$G/x/\$pid";;
esac
SH
  chmod +x "$d/bin/vmreg" "$d/bin/ga"
  fake "$d/gbin" cloud-init "printf 'status: %s\n' \"\$(cat '$d/ci-status')\""
  fake "$d/gbin" systemctl "[ ! -f '$d/start-fail' ]"
}
zvm() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VM_SYS="$d/sys$([ "${FAKE_NODE:-nodea}" = nodea ] || echo "-$FAKE_NODE")" ZRADIO_VM_NET="$d/net" ZRADIO_VM_PVE="$d/pve" ZRADIO_VM_CACHE="$d/cache" ZRADIO_VM_WAIT=0 ZRADIO_VM_POLL=0 ZRADIO_VM_KEYS="$d/keys" bash "$TOOL" "$@" > "$d/out" 2>&1 < /dev/null; RC=$?; }   # nobody there to answer
ask() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VM_ASK=1 ZRADIO_VM_SYS="$d/sys$([ "${FAKE_NODE:-nodea}" = nodea ] || echo "-$FAKE_NODE")" ZRADIO_VM_NET="$d/net" ZRADIO_VM_PVE="$d/pve" ZRADIO_VM_CACHE="$d/cache" ZRADIO_VM_WAIT=0 ZRADIO_VM_POLL=0 ZRADIO_VM_KEYS="$d/keys" bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }   # answers on stdin (a here-string, not a pipe: RC must be this shell's)
vmconf() { printf '%s\n' "${@:3}" > "$1/pve/nodes/${2%%/*}/qemu-server/${2##*/}.conf"; }      # vmconf <dir> <node>/<id> <lines…>
peer_vm() { # peer_vm <dir> <vmid> <name> <initial role> [radios.conf lines…]: the pair's first VM, on nodeb, installed and running (canned)
  local d=$1 id=$2 name=$3 role=$4 R="$1/g/$2/root"; shift 4
  PATH="$d/bin:$PATH" pvesh create "/nodes/nodeb/qemu/$id/agent/exec" --command bash --input-data true > /dev/null       # makes the canned guest
  printf '%s\n' "NAME=$name" SELF=10.20.30.5 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=61 PRIORITY=110 > "$R/etc/zradio/zradio.conf"
  [ -z "$role" ] || echo "$role" > "$R/var/lib/zradio/initial-role"
  [ $# -eq 0 ] || printf '%s\n' "$@" > "$R/etc/zradio/radios.conf"
  python3 -c 'import json, sys; v = json.load(open(sys.argv[1])); v.append({"vmid": int(sys.argv[2]), "name": sys.argv[3], "node": "nodeb", "status": "running", "tags": "zradio", "type": "qemu"}); json.dump(v, open(sys.argv[1], "w"))' "$d/vms.json" "$id" "$name"
  vmconf "$d" "nodeb/$id" "name: $name" "net0: virtio=BC:24:11:00:00:01,bridge=vmbr0" "ipconfig0: ip=dhcp" "net1: virtio=BC:24:11:00:00:02,bridge=vmbrpair" "ipconfig1: ip=10.20.30.5/24" "tags: zradio"
  : > "$d/calls"
}
