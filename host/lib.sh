# shellcheck shell=bash
# host/lib.sh — what install.sh and its parts (host/new-vm.sh, host/update.sh, host/qdevice.sh) share on the node:
# the output lines, the cluster's lists, a command in a VM through its guest agent, and the cluster's votes.
# Sourced by install.sh after it has set KIT, SYS, PVE, NODE and RUN; TABLE is set before any function here is called.

FAILS=0
ok() { printf '   OK    %s\n' "$*"; }
bad() { printf '   FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '   NOTE  %s\n' "$*"; }
would() { printf '   WOULD %s\n' "$*"; }
done_() { printf '   DONE  %s\n' "$*"; }
die() { echo "die: $*" >&2; exit 2; }
do_() { # do_ <command…>: run it (--run) or say it
  if [ "$RUN" = 1 ]; then if "$@"; then done_ "$*"; else bad "$* failed"; return 1; fi; else would "$*"; fi
}
ip4() { local o; [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done; }
cidr() { local a=${1%/*} p=${1##*/}; [ "$1" != "$a" ] && ip4 "$a" && [[ "$p" =~ ^[0-9]{1,2}$ ]] && [ "$p" -ge 8 ] && [ "$p" -le 32 ]; }
in_net() { # in_net <A.B.C.D/NN> <E.F.G.H>: 0 when the address is in that network
  python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in ipaddress.ip_interface(sys.argv[1]).network else 1)' "$1" "$2" 2>/dev/null
}
name_ok() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; }
br_ok() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,14}$ ]]; }

ASK=0; if { [ -t 0 ] && [ -t 1 ]; } || [ "${ZRADIO_VM_ASK:-0}" = 1 ]; then ASK=1; fi
ask() { # ask <prompt> [default]: one line from the person into ANS
  printf '   %s%s: ' "$1" "${2:+ [$2]}"; read -r ANS || die "no answer (without a terminal every answer is an option: ./install.sh --help)"
  [ -n "$ANS" ] || ANS=${2:-}
}
go_ahead() { # go_ahead <the options of the same run>: after a report, "Go ahead?" — yes runs it again with --run
  echo "REPORT ONLY — nothing was changed."
  [ $ASK = 1 ] || exit 0
  printf '   Go ahead? [y/N]: '; read -r ANS || ANS=n
  case "${ANS,,}" in y|yes) echo; exec bash "$0" "$@" --run;; esac
  printf '   Nothing was changed. The same without the questions:\n      ./install.sh'; printf ' %q' "$@" --run; echo
  exit 0
}

# ------------------------------------------------------------------------------------------- the cluster's lists
sticks_here() { # one line per USB device of this node that the kit's table names: "<bus-port> <vid:pid> <kinds> <product>"
  # Matched as the VM matches (zradio-detect): the USB id, and the entry's glob on the product string and its
  # manufacturer where it has them. A plain serial adapter that shares a chip's USB id with a stick is not one.
  python3 - "$TABLE" "$SYS" <<'PY'
import fnmatch, json, os, sys
table, sysdir = sys.argv[1:3]
entries = json.load(open(table))["entries"]
def rd(p):
    try: return open(p).read().strip()
    except OSError: return ""
for d in sorted(os.listdir(sysdir)) if os.path.isdir(sysdir) else []:
    v, p = rd(os.path.join(sysdir, d, "idVendor")).lower(), rd(os.path.join(sysdir, d, "idProduct")).lower()
    product, maker = rd(os.path.join(sysdir, d, "product")), rd(os.path.join(sysdir, d, "manufacturer"))
    kinds = {e["kind"] for e in entries
             if (e["vid"].lower(), e["pid"].lower()) == (v, p)
             and fnmatch.fnmatch(product.lower(), e.get("description", "*"))
             and (not e.get("manufacturer") or fnmatch.fnmatch(maker.lower(), "*%s*" % e["manufacturer"]))}
    if kinds: print(d, "%s:%s" % (v, p), "+".join(sorted(kinds)), product or "-")
PY
}
mappings() { # the cluster's USB mappings: "<id> <node> <vid:pid> <path or ->" per entry (nothing when there are none)
  pvesh get /cluster/mapping/usb --output-format json 2>/dev/null | python3 -c '
import json, sys
try: maps = json.load(sys.stdin)
except ValueError: maps = []
for m in maps:
    for e in m.get("map", []):
        f = dict(x.split("=", 1) for x in e.split(",") if "=" in x)
        print(m["id"], f.get("node", "-"), f.get("id", "-").lower(), f.get("path", "-"))'
}
vm_lines() { # every VM of the cluster: "<vmid> <name> <node> <status> <tags or ->"
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c '
import json, sys
try: vms = json.load(sys.stdin)
except ValueError: vms = []
for v in vms: print(v.get("vmid"), "_".join(str(v.get("name") or "-").split()), v.get("node", "-"), v.get("status", "-"), v.get("tags") or "-")'
}
kit_vms() { # kit_vms here|elsewhere: the kit's radio VMs (tag zradio) on this node, or on the other nodes: vm_lines' lines
  printf '%s\n' "$VMS" | awk -v me="$NODE" -v w="$1" '(";" $5 ";") ~ /;zradio;/ && (w == "here") == ($3 == me)'
}
usb_present() { # usb_present <vid:pid>: a USB device with that id is on this node right now (in the table or not)
  python3 - "$SYS" "$1" <<'PY'
import os, sys
d, want = sys.argv[1:3]
def rd(p):
    try: return open(p).read().strip().lower()
    except OSError: return ""
sys.exit(0 if any(rd(os.path.join(d, x, "idVendor")) + ":" + rd(os.path.join(d, x, "idProduct")) == want
                  for x in (os.listdir(d) if os.path.isdir(d) else [])) else 1)
PY
}
show_sticks() { # the sticks of this node that the kit's table names, one per line; 1 when there is none
  local S M port id kinds product m
  S=$(sticks_here); M=$(mappings)
  [ -n "$S" ] || return 1
  while read -r port id kinds product; do
    [ -n "$port" ] || continue
    m=$(printf '%s\n' "$M" | awk -v n="$NODE" -v i="$id" -v p="$port" '$2 == n && $3 == i && ($4 == "-" || $4 == p) { print $1 }' | tr '\n' ' ')
    printf '      %-10s %s  %-14s %s%s\n' "$port" "$id" "$kinds" "$product" "${m:+   (USB mapping: ${m% })}"
  done <<< "$S"
}

# --------------------------------------------------------------------- the VM's hookscript, and the sticks' power
# host/hook.sh is every radio VM's hookscript: it lets the VM start only once its sticks are on the node's USB, and
# switches their ports' power where --stick-power names the ports (docs/DESIGN.md, "The start, and the sticks'
# power"). A copy per node, in the snippets storage, and per VM a conf beside it.
HOOK_FILE=zradio-hook.sh
port_ok() { [[ "$1" =~ ^[0-9]+(-[0-9]+(\.[0-9]+)*)?:[0-9]+$ ]]; }       # hub:port as uhubctl names them: 1-3:2, or 1:4 on a root hub
port_dir() { # port_dir <hub:port>: the kernel's folder for that port, which holds its switch (`disable`); 1 when there is none
  local h=${1%:*} p=${1##*:}
  if [[ "$h" == *-* ]]; then set -- "$SYS/$h":*/"$h-port$p"; else set -- "$SYS/$h-0":*/"usb$h-port$p"; fi
  [ -e "$1/disable" ] && echo "$1"
}
peer_of() { # peer_of <hub:port>: the same socket's port on the hub's other face (USB 2 / USB 3), where the kernel knows it
  local d b
  d=$(port_dir "$1") && [ -e "$d/peer" ] || return 1
  b=$(basename "$(readlink -f "$d/peer")"); b=${b#usb}
  [[ "$b" =~ ^(.+)-port([0-9]+)$ ]] && echo "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
}
below() { # below <hub:port> <bus-port>: the device at that bus-port hangs off that port
  local h=${1%:*} at
  if [[ "$h" == *-* ]]; then at="$h.${1##*:}"; else at="$h-${1##*:}"; fi
  [ "$2" = "$at" ] || [[ "$2" == "$at".* ]]
}
ports_above() { # ports_above <bus-port>: the hub ports a device hangs off, nearest first (1-3.2.1: 1-3.2:1 1-3:2 1:3)
  local d=$1 out=""
  while [[ "$d" == *.* ]]; do out="$out${d%.*}:${d##*.} "; d=${d%.*}; done
  echo "$out${d%-*}:${d##*-}"
}
vm_sticks() { # vm_sticks <vmid>: where the sticks of that VM of this node are on the bus now, one bus-port per line
  local line v id path
  while read -r line; do
    case "$line" in
      *mapping=*) v=${line##*mapping=}; v=${v%%,*}; read -r id path <<< "$(mappings | awk -v m="$v" -v n="$NODE" '$1 == m && $2 == n { print $3, $4; exit }')";;
      *host=*) v=${line##*host=}; v=${v%%,*}; v=${v//0x/}; if [[ "$v" == *:* ]]; then id=${v,,} path=-; else id=- path=$v; fi;;
      *) continue;;
    esac
    [ -n "$id" ] || continue
    if [ "$path" != - ]; then [ ! -e "$SYS/$path/idVendor" ] || echo "$path"
    else sticks_at "$id"; fi
  done < <(sed -n '/^\[/q; /^usb[0-9]*:/p' "$PVE/nodes/$NODE/qemu-server/$1.conf" 2>/dev/null)
}
sticks_at() { # sticks_at <vid:pid>: the bus-ports of this node's USB devices with that id
  local d
  for d in "$SYS"/*; do
    [ -r "$d/idVendor" ] && [ "$(cat "$d/idVendor"):$(cat "$d/idProduct" 2>/dev/null)" = "$1" ] && echo "${d##*/}"
  done
  return 0
}
power_check() { # power_check <name> <the sticks' bus-ports, one per line>: --stick-power's ports, checked and completed
  # (POWER). Nothing is changed. A port that is off now hides what is below it: its sticks cannot be looked at.
  local p q s off=0 n=${#POWER[@]}
  [ "$n" -gt 0 ] || return 0
  for p in "${POWER[@]}"; do
    port_ok "$p" || { bad "--stick-power '$p': hub:port as uhubctl names them, like 1-3:2"; continue; }
    q=$(port_dir "$p") || { bad "--stick-power $p: no such port on $NODE that the kernel can switch (no $SYS/…-port${p##*:}/disable: its hub is not there, or the kernel is older than 6.0)"; continue; }
    [ "$(cat "$q/disable" 2>/dev/null)" != 1 ] || { off=1; warn "the port $p is switched off now: the hookscript switches it on before $1 starts"; }
    if q=$(peer_of "$p") && [[ " ${POWER[*]} " != *" $q "* ]]; then POWER+=("$q"); ok "the port $p is $q on its hub's other face (USB 2 / USB 3): both are switched"; fi
  done
  [ $FAILS -eq 0 ] || return 0
  while read -r s; do
    [ -n "$s" ] || continue
    for p in "${POWER[@]}"; do ! below "$p" "$s" || continue 2; done
    bad "--stick-power ${POWER[*]}: the stick at $s is below none of them (it hangs off: $(ports_above "$s")). Its power would stay on"
  done <<< "$2"
  [ -n "$2" ] || [ $off = 1 ] || warn "--stick-power: none of $1's sticks is on $NODE's USB now, so whether they hang off ${POWER[*]} was not looked at"
  [ ${#POWER[@]} -ne 1 ] || warn "--stick-power ${POWER[0]}: one port. A USB 3 hub is two hubs (uhubctl lists both), and its port goes dark only when it is switched on both: name the other one too if this is such a hub"
  ok "stick power: $1's hookscript switches ${POWER[*]} on before a start and off after a stop, and off and on when $1 asks (a stick that stays silent)"
}
usb_host_lines() { # usb_host_lines <vmid> <name> <the VM runs: yes|no>: a stick the VM names through one of the kit's own USB
  # mappings (zradio-<vid><pid>, as kit 0.1.0 made them) is named directly instead (host=). Proxmox checks a mapping at
  # every start and refuses the start while the stick is absent; a stick named by host= is passed through when it
  # appears, and the VM starts without it. Only on a stopped VM: on a running one the change would unplug the stick.
  # USB_CHANGES: lines changed or to change; USB_LEFT: lines left because the VM runs.
  local id=$1 name=$2 line key val v mid mpath spec
  USB_CHANGES=0; USB_LEFT=0
  while read -r line; do
    key=${line%%:*}; val=${line#*: }; v=${val##*mapping=}; v=${v%%,*}
    [[ "$v" =~ ^zradio-[0-9a-f]{8}(-[0-9]+)?$ ]] || { warn "$name's $key is the USB mapping $v, which the kit did not make: left as it is. Proxmox refuses a start of $name while that stick is not on $NODE"; continue; }
    read -r mid mpath <<< "$(mappings | awk -v m="$v" -v n="$NODE" '$1 == m && $2 == n { print $3, $4; exit }')"
    [ -n "$mid" ] || { warn "$name's $key: the USB mapping $v has no entry for $NODE: left as it is"; continue; }
    if [ "$mpath" != - ]; then spec="host=$mpath"; else spec="host=$mid"; fi
    if [ "$3" = yes ]; then USB_LEFT=$((USB_LEFT + 1)); continue; fi
    USB_CHANGES=$((USB_CHANGES + 1))
    do_ qm set "$id" "--$key" "${val/mapping=$v/$spec}" || return 1
  done < <(sed -n '/^\[/q; /^usb[0-9]*:.*mapping=/p' "$PVE/nodes/$NODE/qemu-server/$id.conf" 2>/dev/null)
  [ $USB_LEFT = 0 ] || warn "$name names $USB_LEFT stick(s) through USB mappings and runs: Proxmox will refuse its next start if a stick is not on $NODE then. This installer names them directly (host=) while $name is stopped: qm shutdown $id, then ./install.sh again, then qm start $id — the VM that does not serve first"
  [ $USB_CHANGES -gt 0 ] || [ $USB_LEFT -gt 0 ] || ok "$name's sticks are named directly (host=): it starts with or without them"
}
helper_setup() { # helper_setup <vmid> <name> <the VM runs: yes|no> <stick power: yes|no>: the hookscript's helper for a VM that
  # runs already (a VM that starts gets it from its post-start). Started when it is not there; started again on a new hookscript.
  [ "$3" = yes ] && [ "$4" = yes ] || return 0
  local unit="zradio-heal-$1.service"
  if systemctl is-active --quiet "$unit" 2>/dev/null && [ "${HOOK_FILE_NEW:-0}" = 0 ]; then ok "$2's helper runs on $NODE ($unit): it switches the sticks' power when $2 asks"; return 0; fi
  HOOK_CHANGES=$((HOOK_CHANGES + 1))
  if [ "$RUN" = 1 ]; then
    systemctl stop "$unit" 2>/dev/null || true
    "$SNIPDIR/$HOOK_FILE" "$1" post-start >/dev/null 2>&1
    if systemctl is-active --quiet "$unit" 2>/dev/null; then done_ "$2's helper on $NODE ($unit): it switches the sticks' power off and on when $2 asks"
    else warn "$2's helper did not start on $NODE ($SNIPDIR/$HOOK_FILE $1 post-start; journalctl -t zradio): until $2's next start, its sticks' power is not switched when it asks"; fi
  else would "start $2's helper on $NODE ($unit): it switches the sticks' power off and on when $2 asks, 3 times a day at most"; fi
}
hook_setup() { # hook_setup <vmid> <name> <attach: yes|no>: this node's copy of the hookscript, the VM's stick power, and the
  # hook on the VM (no: qm create attaches it). Needs SNIP and SNIPDIR. Counts in HOOK_CHANGES what was not as it should be.
  local id=$1 name=$2 conf="$SNIPDIR/zradio-hook-$1.conf" have want keep
  HOOK_CHANGES=0; HOOK_FILE_NEW=0
  if cmp -s "$KIT/host/hook.sh" "$SNIPDIR/$HOOK_FILE" && [ -x "$SNIPDIR/$HOOK_FILE" ]; then ok "the kit's hookscript is on $NODE: $SNIPDIR/$HOOK_FILE"
  else HOOK_CHANGES=$((HOOK_CHANGES + 1)); HOOK_FILE_NEW=1
    if [ "$RUN" = 1 ]; then
      mkdir -p "$SNIPDIR" && install -m 0755 "$KIT/host/hook.sh" "$SNIPDIR/$HOOK_FILE.tmp" && mv -f "$SNIPDIR/$HOOK_FILE.tmp" "$SNIPDIR/$HOOK_FILE" \
        && done_ "the kit's hookscript on $NODE: $SNIPDIR/$HOOK_FILE" || { bad "could not write $SNIPDIR/$HOOK_FILE"; return 1; }
    else would "put the kit's hookscript on $NODE: $SNIPDIR/$HOOK_FILE (before each start it gives $name's sticks a minute to be on the USB)"; fi
  fi
  have=$(sed -n 's/^POWER_PORTS=//p' "$conf" 2>/dev/null | tail -1)
  if [ ${#POWER[@]} -gt 0 ]; then want="${POWER[*]}"; elif [ "$NOPOWER" = 1 ]; then want=""; else want=$have; fi
  if [ "$want" = "$have" ]; then
    ok "stick power: $([ -n "$have" ] && echo "$name's ports are $have ($conf)" || echo "none for $name: its sticks' ports stay as they are (--stick-power HUB:PORT names the ports to switch)")"
  else HOOK_CHANGES=$((HOOK_CHANGES + 1))
    if [ "$RUN" = 1 ]; then
      keep=$(grep -vE '^(POWER_PORTS=|# )' "$conf" 2>/dev/null)          # WAIT and CYCLE_AFTER, when someone set them
      { echo "# $name's stick power: written by ha_zradio's install.sh on $NODE, read by $HOOK_FILE (its header has the keys)"
        [ -z "$want" ] || echo "POWER_PORTS=$want"; [ -z "$keep" ] || printf '%s\n' "$keep"; } > "$conf.tmp" && mv -f "$conf.tmp" "$conf" \
        && done_ "$conf: $([ -n "$want" ] && echo "POWER_PORTS=$want" || echo "no stick power")" || { bad "could not write $conf"; return 1; }
    else would "write $conf: $([ -n "$want" ] && echo "POWER_PORTS=$want" || echo "no stick power (was: $have)")"; fi
  fi
  [ "$3" = yes ] || return 0
  have=$(sed -n '/^\[/q; s/^hookscript: *//p' "$PVE/nodes/$NODE/qemu-server/$id.conf" 2>/dev/null | head -1)
  if [ "$have" = "$SNIP:snippets/$HOOK_FILE" ]; then ok "$name has the kit's hookscript"
  else HOOK_CHANGES=$((HOOK_CHANGES + 1))
    [ -z "$have" ] || warn "$name has another hookscript, $have: the kit's takes its place (a VM has one)"
    do_ qm set "$id" --hookscript "$SNIP:snippets/$HOOK_FILE" || return 1
  fi
}

# ------------------------------------------------------------------------------------------------- the votes
# (A third vote is set up by host/qdevice.sh: ./install.sh --third-vote.)
# The kit does not use Proxmox HA: the pair decides itself which VM serves, and HA's one use here (restarting a VM on
# its own node) would cost a node that loses the cluster's quorum a reboot by its watchdog — in a cluster of two nodes,
# the survivor of the other's death. A radio VM gets a virtual watchdog instead (qm create --watchdog), which resets a
# guest that hangs, and the guest reboots on a kernel panic (guest/install.sh).
# What the votes still decide: a node starts its VMs at boot (onboot) only once the cluster has quorum. Proxmox's
# startall waits for it with no time limit (pve-manager, PVE/API2/Nodes.pm). In a cluster of two nodes and no third
# vote, a node that boots while the other is down starts no radio VM until someone runs `pvecm expected 1` there.
votes() { # "<total votes now> <votes needed for quorum>" from pvecm status; nothing when there is no cluster
  pvecm status 2>/dev/null | awk '/^Total votes:/ { t = $3 } /^Quorum:/ { q = $2 } END { if (t != "" && q != "") print t, q }'
}
quorum_alone() { # 0 when the cluster keeps its quorum without one of its nodes (one vote each, in Proxmox)
  local v; v=$(votes); [ -n "$v" ] && [ $(( ${v% *} - 1 )) -ge "${v#* }" ]
}
quorum_check() { # an OK line, or the NOTE on what two votes cost
  local v; v=$(votes)
  if quorum_alone; then ok "the cluster keeps its quorum without one node (${v% *} votes, ${v#* } needed): a node that boots while the other is down starts its radio VM"
  else warn "$([ -n "$v" ] && echo "this cluster has ${v% *} vote(s) and needs ${v#* }" || echo "no answer from pvecm status"): while one node is down, Proxmox starts no VM on the other, $NAME among them, at boot or by hand, until you run 'pvecm expected 1' there. VMs already running keep running, and the pair fails over without it. Recommended: a third vote (./install.sh --third-vote ADDRESS; README, \"Two nodes or three\")"; fi
}

# --------------------------------------------------------------------------------- a command in a VM, on any node
# Through the guest agent and Proxmox's own API (pvesh reaches a VM on the other node of the cluster too): bash in
# the VM, the script on its stdin. gx prints the script's stdout and returns its exit code (98: no answer).
GA_MAX=49152      # bytes of one script: Proxmox takes at most 64 KiB of input-data (qemu-server's Agent.pm)
gx_start() { # gx_start <node> <vmid> <script>: prints the pid
  pvesh create "/nodes/$1/qemu/$2/agent/exec" --command bash --input-data "$3" --output-format json 2>/dev/null | python3 -c '
import json, sys
try: print(int(json.load(sys.stdin)["pid"]))
except Exception: sys.exit(98)'
}
gx_wait() { # gx_wait <node> <vmid> <pid> <seconds>
  local t=0 rc
  while :; do
    pvesh get "/nodes/$1/qemu/$2/agent/exec-status" --pid "$3" --output-format json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except ValueError: sys.exit(98)
if not d.get("exited"): sys.exit(99)
sys.stdout.write(d.get("out-data", "")); sys.exit(min(int(d.get("exitcode", 97)), 96))'
    rc=$?; [ $rc = 99 ] || return $rc
    t=$((t + 1)); [ $t -lt "$4" ] || return 98; sleep "${ZRADIO_VM_POLL:-1}"
  done
}
gx() { local pid; pid=$(gx_start "$1" "$2" "$4") || return 98; gx_wait "$1" "$2" "$pid" "$3"; }   # gx <node> <vmid> <seconds> <script>
agent_up() { pvesh create "/nodes/$1/qemu/$2/agent/ping" >/dev/null 2>&1; }

kit_tar() { # the kit as the VM gets it, a .tgz on stdout: its guest folder, what the node generated for it, the example conf
  tar -C "$KIT" --owner=0 --group=0 --sort=name -czf - guest gen/usb-ids.json gen/kit-version zradio.conf.example
}
send_kit() { # send_kit <node> <vmid> <name>: this kit into the VM's /opt/zradio/kit, the one it had kept as kit.previous
  local b64 sum i=0 n
  b64=$(kit_tar | base64 -w0); sum=$(printf '%s' "$b64" | base64 -d | sha256sum | cut -c1-64)
  n=$(( (${#b64} + GA_MAX - 1) / GA_MAX ))
  while [ $i -lt $n ]; do      # in pieces: one script carries at most GA_MAX bytes
    gx "$1" "$2" 30 "printf '%s' '${b64:$((i * GA_MAX)):$GA_MAX}' $([ $i = 0 ] && echo '>' || echo '>>') /root/zradio-kit.b64" >/dev/null \
      || { bad "the kit did not reach $3 (piece $((i + 1)) of $n, through its guest agent)"; return 1; }
    i=$((i + 1))
  done
  # shellcheck disable=SC2016  # the script runs in the VM
  gx "$1" "$2" 60 'set -e; base64 -d /root/zradio-kit.b64 > /root/zradio-kit.tgz; rm -f /root/zradio-kit.b64
    [ "$(sha256sum < /root/zradio-kit.tgz | cut -c1-64)" = '"$sum"' ] || { echo "the kit arrived damaged"; exit 1; }
    rm -rf /opt/zradio/kit.new; mkdir -p /opt/zradio/kit.new; tar -xzf /root/zradio-kit.tgz -C /opt/zradio/kit.new
    # the kit before is kept, to go back to. A second try with the same kit keeps the one that is kept already.
    if [ -d /opt/zradio/kit ] && [ -d /opt/zradio/kit.previous ] && cmp -s /opt/zradio/kit/gen/kit-version /opt/zradio/kit.new/gen/kit-version; then rm -rf /opt/zradio/kit
    else rm -rf /opt/zradio/kit.previous; [ ! -d /opt/zradio/kit ] || mv /opt/zradio/kit /opt/zradio/kit.previous; fi
    mv /opt/zradio/kit.new /opt/zradio/kit' >/dev/null \
    && done_ "the kit is in $3 ($n piece(s) through its guest agent, checked): /opt/zradio/kit, the one before it kept as /opt/zradio/kit.previous" \
    || { bad "the kit did not unpack in $3 (its old kit, if any, is still at /opt/zradio/kit)"; return 1; }
}
run_guest_installer() { # run_guest_installer <node> <vmid> <name> <command>: the kit's installer in the VM, its lines shown here
  # as they come; returns its exit code (98: it did not end within the wait). Its log in the VM: /var/log/zradio-install.log
  local at=0 rc="" n=0 chunk got
  gx "$1" "$2" 20 'rm -f /root/zradio-install.rc' >/dev/null || { bad "$3 does not answer (its guest agent)"; return 98; }
  gx_start "$1" "$2" "$4 > /var/log/zradio-install.log 2>&1; echo \$? > /root/zradio-install.rc" >/dev/null \
    || { bad "the installer did not start in $3"; return 98; }
  echo "   the kit's installer in $3 (its log there: /var/log/zradio-install.log):"
  GUEST_LOG=""
  while :; do     # its finished lines as they come (@@at: how many were sent so far); the last round carries the exit code (@@rc)
    # shellcheck disable=SC2016  # the script runs in the VM
    # (the exit code is looked for BEFORE the lines are counted: an installer that ends in between is seen next round, whole)
    chunk=$(gx "$1" "$2" 20 "L=$at"'; f=/var/log/zradio-install.log; r=""; [ ! -f /root/zradio-install.rc ] || r=$(cat /root/zradio-install.rc); n=$(wc -l < $f); [ "$n" -le "$L" ] || sed -n "$((L + 1)),${n}p" $f; echo "@@at $n"; [ -z "$r" ] || echo "@@rc $r"') || chunk=""
    rc=$(printf '%s\n' "$chunk" | sed -n 's/^@@rc \([0-9]*\)$/\1/p' | tail -1)
    got=$(printf '%s\n' "$chunk" | sed -n 's/^@@at \([0-9]*\)$/\1/p' | tail -1); [ -z "$got" ] || at=$got
    chunk=$(printf '%s\n' "$chunk" | sed '/^@@\(rc\|at\) [0-9]*$/d; /^$/d')
    if [ -n "$chunk" ]; then printf '%s\n' "$chunk" | sed 's/^/      | /'; GUEST_LOG="$GUEST_LOG$chunk"$'\n'; fi
    [ -z "$rc" ] || return "$rc"
    n=$((n + 1)); [ $n -lt 360 ] || return 98; sleep "$WAIT"
  done
}
vm_kit() { # vm_kit <node> <vmid>: "VERSION=…", "CONTENT=…" of the kit installed in the VM (none: a kit from before
  # versions were kept), and SERVING=yes|no (it holds the floating address now)
  # shellcheck disable=SC2016  # the script runs in the VM
  # and where Home Assistant connects: HA_VIP, HA_ZWAVE_PORT, HA_ZIGBEE_PORT (empty: the usual one), HA_ZWAVE, HA_ZIGBEE (none: no such stick)
  gx "$1" "$2" 20 'cat /usr/local/lib/zradio/kit-version 2>/dev/null; v=$(sed -n "s/^VIP=//p" /etc/zradio/zradio.conf 2>/dev/null | tail -1)
    if [ -n "$v" ] && ip -o -4 addr show 2>/dev/null | grep -q " inet ${v%/*}/"; then echo SERVING=yes; else echo SERVING=no; fi
    echo "HA_VIP=${v%/*}"; for k in ZWAVE_PORT ZIGBEE_PORT; do echo "HA_$k=$(sed -n "s/^$k=//p" /etc/zradio/zradio.conf 2>/dev/null | tail -1)"; done
    for k in ZWAVE ZIGBEE; do echo "HA_$k=$(sed -n "s/^$k=//p" /etc/zradio/radios.conf 2>/dev/null | tail -1)"; done'
}
GET_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
ha_lines() { # ha_lines <floating address> <Z-Wave port> <Zigbee port> <Z-Wave stick: 1|0> <Zigbee stick: 1|0>: where Home
  # Assistant connects, and the kit's line for Home Assistant's terminal (homeassistant/install.sh) with the address in it
  echo "   In Home Assistant:$([ "$4" = 1 ] && echo "  Z-Wave JS → tcp://$1:$2")$([ "$5" = 1 ] && echo "  ZHA → socket://$1:$3")"
  echo "   What to set where, for your Home Assistant: this line in Home Assistant's terminal (Settings > Apps > Terminal & SSH):"
  echo "      $GET_LINE --radios $1$([ "$2" = 6639 ] || echo " --zwave-port $2")$([ "$3" = 6638 ] || echo " --zigbee-port $3")$([ "$4" = 1 ] || echo " --no-zwave")$([ "$5" = 1 ] || echo " --no-zigbee")"
}
kv() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | tail -1 | tr -dc 'A-Za-z0-9./@:_+-'; }     # kv <KEY> <text of KEY=value lines>
