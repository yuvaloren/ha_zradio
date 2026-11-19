# shellcheck shell=bash disable=SC2034
# tests/fake-node.sh — a fake Proxmox cluster (nodea, nodeb) for ./install.sh: qm, pvesh, pvecm, pvesm, wget and hostname
# are fakes on PATH (recorded in <dir>/calls); the USB trees, /etc/pve, the image cache, the snippets storage and the
# bridges are folders. The guest agent is real bash: a script install.sh sends into a VM is RUN, with the VM's paths
# (/etc, /var, /root, /opt, /usr/local) turned into <dir>/g/<vmid>/root/… — so the scripts themselves are tested.
#   node <dir> [sticks on nodea: both|zwave|none|twins|dark]      the cluster's votes: <dir>/votes ("<total> <quorum>")
#   nodea's sticks hang off a hub in port 2 of a hub with two faces (1-3: USB 2, 2-4: USB 3), as on the reference
#   pair's nodes; the kernel's switch for a port is <sys>/<hub>:1.0/<hub>-port<n>/disable (dark: 1-3's port 2 is off).
#   qm set --hookscript and qm create --hookscript write the VM's hookscript line into its file under <dir>/pve.
#   the Debian image: the cache holds the one the web's list names (nothing to download). Knobs, files in <dir>:
#     web (the image the web has now, when it is another one), sum (the checksum its list gives instead of the
#     true one), list-fail (the list cannot be read), image-fail (the image's download breaks off halfway)
#   canned guests (the default): cloud-init, systemctl, zradio-sync and zradio-serve in the VM are fakes, and the
#     kit's installer "runs" by copying <dir>/install.log and install.rc into place.          knobs: files in <dir>
#     The VM's conf is the one cloud-init wrote; one without SELF (a VM on DHCP) gets the address in <dir>/lease.
#   live (touch <dir>/live): qm create really registers the VM in the cluster's files, and the guests are the fake
#     radio VMs of tests/fake-guest.sh, in which the kit's real installer runs (tests/t-e2e.sh).
#   state-<vmid> (running|stopped): what the VM's own node says, when the cluster's list (vms.json) lags behind it;
#     node-silent-<node>: that node does not answer for its VMs.
#   FAKE_NODE=nodeb: the command runs on the other node (its sticks: <dir>/sys-nodeb).
node() {
  local d=$1 sticks=${2:-both}
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
  for s in 1-3:1.0/1-3-port2 2-4:1.0/2-4-port2 1-0:1.0/usb1-port4; do mkdir -p "$d/sys/$s"; echo 0 > "$d/sys/$s/disable"; done
  [ "$sticks" != dark ] || echo 1 > "$d/sys/1-3:1.0/1-3-port2/disable"
  echo '[]' > "$d/usbmap.json"; echo '[]' > "$d/vms.json"
  echo '[{"storage":"local","type":"dir","content":"images,snippets,iso,vztmpl","path":"'"$d"'/store"},{"storage":"local-zfs","type":"zfspool","content":"images,rootdir"}]' > "$d/storages.json"
  echo image-from-the-web > "$d/cache/debian-13-generic-amd64.qcow2"; sha512sum < "$d/cache/debian-13-generic-amd64.qcow2" | cut -d' ' -f1 > "$d/cache/debian-13-generic-amd64.qcow2.sha512"
  printf '== 2. keepalived and ser2net (Debian'"'"'s packages) ==\nOK    keepalived 2.3.3 installed\nDONE  the radios are detected and named\n== installed ==\n' > "$d/install.log"
  echo 0 > "$d/install.rc"; echo "done" > "$d/ci-status"; printf 'ZWAVE=synced\nZIGBEE=synced\n' > "$d/radios.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" hostname 'echo "${FAKE_NODE:-nodea}"'
  echo "3 2" > "$d/votes"     # "<total votes> <quorum>": three votes by default; a test of two nodes without a third vote sets "2 2"
  fake "$d/bin" pvecm "case \"\$1\" in status) read -r t q < '$d/votes'; printf 'Expected votes:   %s\\nTotal votes:      %s\\nQuorum:           %s\\n' \"\$t\" \"\$t\" \"\$q\";; *) $rec;; esac"
  fake "$d/bin" pvesm "$rec"
  # the hookscript's helper, a unit of the node: is-active says whether one runs (<dir>/helper-active), systemd-run starts it
  fake "$d/bin" systemctl "case \"\$1\" in is-active) [ -e '$d/helper-active' ];; is-system-running) echo running;; stop) $rec; rm -f '$d/helper-active';; *) $rec;; esac"
  fake "$d/bin" systemd-run "$rec; [ -f '$d/no-helper' ] || : > '$d/helper-active'"
  fake "$d/bin" logger ':'
  fake "$d/bin" wget "$rec; out=\${*: -1}; web() { cat '$d/web' 2>/dev/null || echo image-from-the-web; }
    u=; for a; do case \"\$a\" in *://*) u=\$a;; esac; done      # the URL, wherever the options put it
    case \"\$u\" in
      */SHA512SUMS) [ ! -f '$d/list-fail' ] || { : > \"\$out\"; exit 4; }; printf '%s  debian-13-generic-amd64.qcow2\n' \"\$(cat '$d/sum' 2>/dev/null || web | sha512sum | cut -d' ' -f1)\" > \"\$out\";;
      *) [ ! -f '$d/image-fail' ] || { web | head -c 5 > \"\$out\"; exit 4; }; web > \"\$out\";;
    esac"
  fake "$d/bin" qm "$rec; [ ! -f '$d/qm-fail' ] || exit 1; case \"\$1\" in create) '$d/bin/vmreg' create \"\${@:2}\";; start) '$d/bin/vmreg' start \"\$2\";; set) '$d/bin/vmreg' set \"\${@:2}\";; esac; exit 0"
  fake "$d/bin" pvesh "case \"\$1 \$2\" in
    'get /cluster/mapping/usb') cat '$d/usbmap.json';;
    'get /cluster/resources') cat '$d/vms.json';;
    'get /cluster/nextid') if [ -f '$d/live' ]; then python3 -c 'import json,sys; print(max([99] + [v[\"vmid\"] for v in json.load(open(sys.argv[1]))]) + 1)' '$d/vms.json'; else echo 109; fi;;
    'get /storage') cat '$d/storages.json';;
    'get /storage/local') python3 -c 'import json,sys; print(json.dumps([s for s in json.load(open(sys.argv[1])) if s[\"storage\"] == \"local\"][0]))' '$d/storages.json';;
    *\\ /nodes/*/qemu/*/agent/*) exec '$d/bin/ga' \"\$@\";;
    get\\ /nodes/*/qemu/*/status/current) exec '$d/bin/vmstate' \"\$2\";;
    get\\ *) exit 2;;
    *) $rec; [ ! -f '$d/pvesh-fail' ];;
  esac"
  # vmstate: what a VM's own node says of it right now (pvesh get /nodes/<node>/qemu/<vmid>/status/current): what the
  # cluster's list has (vms.json), unless <dir>/state-<vmid> says running or stopped — on a real cluster the list lags
  # the node by up to 10 s after a shutdown or a start. <dir>/node-silent-<node>: that node gives no answer.
  cat > "$d/bin/vmstate" <<SH
#!/usr/bin/env bash
p=\${1#/nodes/}; node=\${p%%/*}; id=\${p#*/qemu/}; id=\${id%%/*}
[ ! -f "$d/node-silent-\$node" ] || exit 2
# a node answers for its own VMs only
on=\$(python3 -c 'import json, sys; print(next((v.get("node", "") for v in json.load(open(sys.argv[1])) if v.get("vmid") == int(sys.argv[2])), ""))' "$d/vms.json" "\$id")
[ -z "\$on" ] || [ "\$on" = "\$node" ] || exit 2
if [ -f "$d/state-\$id" ]; then s=\$(cat "$d/state-\$id")
else s=\$(python3 -c 'import json, sys; print(next((v.get("status", "") for v in json.load(open(sys.argv[1])) if v.get("vmid") == int(sys.argv[2])), ""))' "$d/vms.json" "\$id"); fi
[ -n "\$s" ] || exit 2
printf '{"status":"%s","vmid":%s}\\n' "\$s" "\$id"
SH
  chmod +x "$d/bin/vmstate"
  # vmreg: in a live cluster, qm create / start show up in the cluster's own files, as on a real one
  cat > "$d/bin/vmreg" <<SH
#!/usr/bin/env bash
# a hookscript given to qm create or qm set is in the VM's file from then on, live or not: install.sh reads it there
f="$d/pve/nodes/\${FAKE_NODE:-nodea}/qemu-server/\$2.conf"; i=3
while [ \$i -lt \$# ]; do j=\$((i + 1)); [ "\${!i}" != --hookscript ] || { touch "\$f"; sed -i '/^hookscript:/d' "\$f"; echo "hookscript: \${!j}" >> "\$f"; }
  # …and so is a usb line that qm set gives a VM
  if [ "\$1" = set ] && [[ "\${!i}" =~ ^--(usb[0-9]+)\$ ]]; then touch "\$f"; sed -i "/^\${BASH_REMATCH[1]}:/d" "\$f"; echo "\${BASH_REMATCH[1]}: \${!j}" >> "\$f"; fi
  i=\$j; done
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
            if k.startswith(("net", "ipconfig", "usb")) or k in ("name", "tags", "cicustom", "hookscript"): f.write("%s: %s\n" % (k, v))
elif verb == "set":
    o = dict(zip([a[2:] for a in rest[0::2]], rest[1::2]))
    for v in vms:
        if v["vmid"] == vmid and "tags" in o: v["tags"] = o["tags"]
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
    if [ ! -f "\$d/live" ] && [[ "\$script" == *"guest/install.sh --conf"* || "\$script" == *"guest/install.sh --from-node --run >"* ]]; then
      cp "\$d/install.log" "\$R/var/log/zradio-install.log"; cp "\$d/install.rc" "\$R/root/zradio-install.rc"; : > "\$G/x/\$n.out"; echo 0 > "\$G/x/\$n.rc"
      [ "\$(cat "\$d/install.rc")" != 0 ] || [ ! -f "\$R/opt/zradio/kit/gen/kit-version" ] || { mkdir -p "\$R/usr/local/lib/zradio"; cp "\$R/opt/zradio/kit/gen/kit-version" "\$R/usr/local/lib/zradio/kit-version"; }
      # …and its conf is in place: the one cloud-init wrote, with the VM's own address when that one names none (DHCP: <dir>/lease)
      if [ -f "\$R/root/zradio.conf" ]; then cp "\$R/root/zradio.conf" "\$R/etc/zradio/zradio.conf"; grep -q '^SELF=' "\$R/etc/zradio/zradio.conf" || echo "SELF=\$(cat "\$d/lease" 2>/dev/null || echo 10.20.30.77)" >> "\$R/etc/zradio/zradio.conf"; fi
    elif [ ! -f "\$d/live" ] && [[ "\$script" == *"guest/install.sh --peer "* ]]; then      # the first VM is told its peer (knob: <dir>/peer-fail)
      if [ -f "\$d/peer-fail" ]; then echo "FAIL  --peer: refused" > "\$G/x/\$n.out"; echo 1 > "\$G/x/\$n.rc"
      else pa=\${script#*--peer }; pa=\${pa%% *}; { grep -v '^PEER=' "\$R/etc/zradio/zradio.conf"; echo "PEER=\$pa"; } > "\$R/etc/zradio/zradio.conf.new" && mv "\$R/etc/zradio/zradio.conf.new" "\$R/etc/zradio/zradio.conf"
        cat "\$d/peer.log" 2>/dev/null > "\$G/x/\$n.out"; echo 0 > "\$G/x/\$n.rc"; fi
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
peer_dhcp() { # peer_dhcp <dir> <vmid> <name>: that first VM as one on DHCP — one interface, its own address filled in, no peer yet
  printf '%s\n' "NAME=$3" VIP=192.168.1.20/24 VRID=61 PRIORITY=110 "# this VM's own address on the day it was installed" SELF=192.168.1.31 > "$1/g/$2/root/etc/zradio/zradio.conf"
  vmconf "$1" "nodeb/$2" "name: $3" "net0: virtio=BC:24:11:00:00:01,bridge=vmbr1" "ipconfig0: ip=dhcp" "tags: zradio"
  : > "$1/calls"
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
