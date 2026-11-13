#!/usr/bin/env bash
# install.sh — one radio VM of a zradio pair on THIS Proxmox VE node. Run it as root on each of the two nodes, from a
# checkout of the kit:
#
#     ./install.sh
#
# It asks what it needs, shows what it would do, and does it after a yes: the VM (Debian 13), this node's Z-Wave
# and/or Zigbee sticks passed through, the kit installed inside (through the guest agent), the VM under Proxmox HA
# and pinned to this node. On the second node it takes the addresses from the first VM and introduces the two VMs to
# each other (their sync keys), so nothing is typed twice and nothing is pasted. Either kind of stick may be missing.
#
# Without a terminal nothing is asked: every answer is an option, and nothing is changed without --run.
#   --answers FILE           the options below as lines of a file, KEY=value (answers.example); for unattended runs
#   --sticks                 list this node's sticks and stop
#   --initial-role primary|standby
#                            primary: this node's sticks hold your networks and stay as they are.
#                            standby: this node's sticks WILL BE WIPED by the first sync.
#                            Only for the start: afterward the two VMs swap. (--first: a new house, no network yet)
#   --name NAME              the VM's name (default: the first free of zradio1, zradio2, …)
#   --self A.B.C.D/NN  --peer A.B.C.D  --vip A.B.C.D/NN      this VM, the other VM, the floating address
#   --bridge BR  --gateway A.B.C.D                            the network they are on (default vmbr0)
#   --pair-bridge BR         a link of its own between the nodes for --self (--bridge is then DHCP, no --gateway)
#   --join NAME              the first radio VM, to pair with (found by itself when there is one);  --no-pair
#   --start                  put the VM into the pair at the end        --run   do it
#   more: --vrid --priority --pair-mac --usb-mapping --vmid --storage --snippets --memory --cores --disk --hookscript
#         --ssh-keys --conf KEY=VALUE --no-ha --no-usb --allow-no-radios --image-dir   (docs/DESIGN.md, "Options")
#
# Tests: tests/t-host.sh and tests/t-e2e.sh (Proxmox and the guest are fakes there). Not yet run on a real node.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${ZRADIO_VM_KIT:-$HERE}
SYS=${ZRADIO_VM_SYS:-/sys/bus/usb/devices}
NETSYS=${ZRADIO_VM_NET:-/sys/class/net}
PVE=${ZRADIO_VM_PVE:-/etc/pve}
CACHE=${ZRADIO_VM_CACHE:-/var/lib/vz/template/cache}
WAIT=${ZRADIO_VM_WAIT:-5}
IMAGE_NAME=debian-13-generic-amd64.qcow2

FAILS=0
ok() { printf '   OK    %s\n' "$*"; }
bad() { printf '   FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '   NOTE  %s\n' "$*"; }
would() { printf '   WOULD %s\n' "$*"; }
done_() { printf '   DONE  %s\n' "$*"; }
RUN=0
do_() { # do_ <command…>: run it (--run) or say it
  if [ $RUN = 1 ]; then if "$@"; then done_ "$*"; else bad "$* failed"; return 1; fi; else would "$*"; fi
}
ip4() { local o; [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done; }
cidr() { local a=${1%/*} p=${1##*/}; [ "$1" != "$a" ] && ip4 "$a" && [[ "$p" =~ ^[0-9]{1,2}$ ]] && [ "$p" -ge 8 ] && [ "$p" -le 32 ]; }
NODE=$(hostname -s)
TABLE="$KIT/guest/lib/usb-ids.json"
[ -r "$TABLE" ] || { echo "die: no $TABLE — run this from a checkout of the kit" >&2; exit 2; }

sticks_here() { # one line per USB device of this node that the kit's table names: "<bus-port> <vid:pid> <kinds> <product>"
  python3 - "$TABLE" "$SYS" <<'PY'
import json, os, sys
table, sysdir = sys.argv[1:3]
kinds = {}
for e in json.load(open(table))["entries"]:
    kinds.setdefault((e["vid"].lower(), e["pid"].lower()), set()).add(e["kind"])
def rd(p):
    try: return open(p).read().strip()
    except OSError: return ""
for d in sorted(os.listdir(sysdir)) if os.path.isdir(sysdir) else []:
    v, p = rd(os.path.join(sysdir, d, "idVendor")).lower(), rd(os.path.join(sysdir, d, "idProduct")).lower()
    if (v, p) in kinds:
        print(d, "%s:%s" % (v, p), "+".join(sorted(kinds[(v, p)])), rd(os.path.join(sysdir, d, "product")) or "-")
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
for v in vms: print(v.get("vmid"), v.get("name", "-"), v.get("node", "-"), v.get("status", "-"), v.get("tags") or "-")'
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

# ----------------------------------------------------------------------------------------------------- the answers
NAME="" ROLE="" SELF="" PEER="" VIP="" VRID="" PRIORITY="" BRIDGE="" PAIR_BRIDGE="" GATEWAY="" PAIR_MAC="" VMID="" STORAGE="" SNIP=local
MEMORY=2048 CORES=2 DISK=8G HOOK="" KEYS=${ZRADIO_VM_KEYS:-/root/.ssh/authorized_keys} FIRST=0 START=0 HA=1 NORADIOS=0 NOUSB=0
IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/latest
USBMAPS=() EXTRA=() STICKS=0 JOIN="" PAIR=1 PASS=()
die() { echo "die: $*" >&2; exit 2; }
# --answers FILE: the options as lines, KEY=value (INITIAL_ROLE=primary, SELF=…, USB_MAPPING=… once per mapping) and
# yes/no for the ones without a value (FIRST=yes, START=yes, NO_PAIR=yes …). An option on the command line wins.
# RUN is not an answer: nothing is changed without --run on the command line.
A=(); F=()
while [ $# -gt 0 ]; do if [ "$1" = --answers ]; then
    [ -r "${2:-}" ] || die "--answers '${2:-}': no such file"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue;; esac
      [[ "$line" =~ ^([A-Z][A-Z_]*)=(.*)$ ]] || die "--answers $2: not KEY=value: $line"
      k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; o="--$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"
      case "$k" in
        RUN|ANSWERS|STICKS|HELP) die "--answers $2: $k is not an answer (it belongs on the command line)";;
        FIRST|START|NO_PAIR|NO_HA|NO_USB|ALLOW_NO_RADIOS) case "$v" in yes) F+=("$o");; no) ;; *) die "--answers $2: $k is yes or no";; esac;;
        *) F+=("$o" "$v");;
      esac
    done < "$2"; shift 2
  else A+=("$1"); shift; fi; done
set -- ${F[@]+"${F[@]}"} ${A[@]+"${A[@]}"}
while [ $# -gt 0 ]; do case "$1" in
  -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p}' "$0"; exit 0;;
  --sticks) STICKS=1; shift;; --run) RUN=1; shift;; --first) FIRST=1; shift;; --start) START=1; shift;; --no-pair) PAIR=0; shift;;
  --no-ha) HA=0; PASS+=("$1"); shift;; --allow-no-radios) NORADIOS=1; PASS+=("$1"); shift;; --no-usb) NOUSB=1; PASS+=("$1"); shift;;
  --name) NAME=$2; shift 2;; --initial-role) ROLE=$2; shift 2;; --self) SELF=$2; shift 2;; --peer) PEER=$2; shift 2;; --vip) VIP=$2; shift 2;; --vrid) VRID=$2; shift 2;;
  --priority) PRIORITY=$2; shift 2;; --bridge) BRIDGE=$2; shift 2;; --pair-bridge) PAIR_BRIDGE=$2; shift 2;; --gateway) GATEWAY=$2; shift 2;; --join) JOIN=$2; shift 2;;
  --pair-mac) PAIR_MAC=$2; PASS+=("$1" "$2"); shift 2;; --vmid) VMID=$2; PASS+=("$1" "$2"); shift 2;; --storage) STORAGE=$2; PASS+=("$1" "$2"); shift 2;; --snippets) SNIP=$2; PASS+=("$1" "$2"); shift 2;;
  --memory) MEMORY=$2; PASS+=("$1" "$2"); shift 2;; --cores) CORES=$2; PASS+=("$1" "$2"); shift 2;; --disk) DISK=$2; PASS+=("$1" "$2"); shift 2;; --hookscript) HOOK=$2; PASS+=("$1" "$2"); shift 2;;
  --ssh-keys) KEYS=$2; PASS+=("$1" "$2"); shift 2;; --image-dir) IMAGE_DIR=$2; PASS+=("$1" "$2"); shift 2;; --usb-mapping) USBMAPS+=("$2"); PASS+=("$1" "$2"); shift 2;; --conf) EXTRA+=("$2"); PASS+=("$1" "$2"); shift 2;;
  *) echo "unknown option: $1 (./install.sh --help)" >&2; exit 2;; esac; done
name_ok() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; }
br_ok() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,14}$ ]]; }
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox node"
command -v qm >/dev/null 2>&1 && command -v pvesh >/dev/null 2>&1 || die "no qm / pvesh here: this runs on a Proxmox VE node"
for f in install.sh sbin/zradio-serve lib/zradio-common.sh units/zradio.target; do [ -r "$KIT/guest/$f" ] || die "the kit's guest/$f is missing next to this script"; done
if [ $STICKS = 1 ]; then
  echo "The sticks on $NODE that the kit knows (the VM itself finds out which is what):"
  show_sticks || { echo "      none. A stick the kit's table does not know can still be passed through: make a USB mapping for it and use --usb-mapping."; exit 1; }
  exit 0
fi

# --------------------------------------------------------------------------------- a command in a VM, on any node
# Through the guest agent and Proxmox's own API (pvesh reaches a VM on the other node of the cluster too): bash in
# the VM, the script on its stdin. gx prints the script's stdout and returns its exit code (98: no answer).
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

ASK=0; if { [ -t 0 ] && [ -t 1 ]; } || [ "${ZRADIO_VM_ASK:-0}" = 1 ]; then ASK=1; fi
ask() { # ask <prompt> [default]: one line from the person into ANS
  printf '   %s%s: ' "$1" "${2:+ [$2]}"; read -r ANS || die "no answer (without a terminal every answer is an option: ./install.sh --help)"
  [ -n "$ANS" ] || ANS=${2:-}
}
VMS=$(vm_lines)

# ------------------------------------------------------------- the first radio VM, when this node gets the second
# A VM with the tag `zradio` on another node is the pair's first VM: its addresses, its bridge and its initial role
# decide this one's, and the two are introduced to each other at the end.
PNODE="" PVMID="" PNAME="" P_ROLE="" P_ZWAVE="" P_ZIGBEE=""
if [ $PAIR = 1 ] && [ $NOUSB = 0 ]; then
  if [ -n "$JOIN" ]; then C=$(printf '%s\n' "$VMS" | awk -v n="$JOIN" -v me="$NODE" '$2 == n && $3 != me')
    [ -n "$C" ] || die "--join '$JOIN': no VM of that name on another node of this cluster"
  else C=$(printf '%s\n' "$VMS" | awk -v me="$NODE" '$3 != me && (";" $5 ";") ~ /;zradio;/'); fi
  if [ "$(printf '%s\n' "$C" | grep -c .)" -gt 1 ]; then die "more than one radio VM on other nodes ($(printf '%s\n' "$C" | awk '{ printf "%s ", $2 }')): say which with --join NAME, or --no-pair"; fi
  if [ -n "$C" ]; then read -r PVMID PNAME PNODE _ <<< "$C"; fi
fi
INTRO=0; if [ $ASK = 1 ] && [ $NOUSB = 0 ] && [ $RUN = 0 ]; then INTRO=1; echo "== a radio VM for this node ($NODE) =="; fi
if [ -n "$PVMID" ] && [ $ASK = 1 ] && [ -z "$JOIN" ]; then
  echo "   $PNAME on $PNODE is a radio VM of this kit."
  ask "Is this node's VM the second of that pair? (n: a pair of its own)" y
  case "${ANS,,}" in n|no) PVMID="" PNODE="" PNAME="" PAIR=0;; *) JOIN=$PNAME;; esac
fi
if [ -n "$PVMID" ]; then
  agent_up "$PNODE" "$PVMID" || die "$PNAME on $PNODE does not answer (its guest agent): start it first — this node's VM takes its addresses from it and is introduced to it. (--no-pair: do neither.)"
  # shellcheck disable=SC2016  # the script runs in the VM
  PF=$(gx "$PNODE" "$PVMID" 20 'cat /etc/zradio/zradio.conf 2>/dev/null; printf "INITIAL_ROLE=%s\n" "$(cat /var/lib/zradio/initial-role 2>/dev/null)"; sed -n "s/^\(ZWAVE\|ZIGBEE\)=/P_&/p" /etc/zradio/radios.conf 2>/dev/null') \
    || die "could not read $PNAME's configuration through its guest agent"
  pf() { printf '%s\n' "$PF" | sed -n "s/^$1=//p" | tail -1 | tr -dc 'A-Za-z0-9./:_-'; }
  P_SELF=$(pf SELF); P_PEER=$(pf PEER); P_ROLE=$(pf INITIAL_ROLE); P_ZWAVE=$(pf P_ZWAVE); P_ZIGBEE=$(pf P_ZIGBEE)
  ip4 "$P_SELF" && ip4 "$P_PEER" || die "$PNAME has no /etc/zradio/zradio.conf with SELF and PEER: the kit is not installed in it"
  [ -n "$PEER" ] || PEER=$P_SELF
  [ -n "$VIP" ] || VIP=$(pf VIP)
  [ -n "$VRID" ] || VRID=$(pf VRID)
  # the network, from the first VM's own lines in the cluster's files: the ipconfig that holds its address, and that interface's bridge
  PC="$PVE/nodes/$PNODE/qemu-server/$PVMID.conf"
  pk=$(sed -n '/^\[/q; s/^ipconfig\([0-9]\):.*ip='"${P_SELF//./\\.}"'\/\([0-9]*\).*/\1 \2/p' "$PC" 2>/dev/null | head -1)
  if [ -n "$pk" ]; then
    [ -n "$SELF" ] || SELF="$P_PEER/${pk#* }"
    pbr() { sed -n '/^\[/q; s/^net'"$1"':.*bridge=\([A-Za-z0-9._-]*\).*/\1/p' "$PC" | head -1; }
    if [ "${pk% *}" = 0 ]; then
      [ -n "$BRIDGE" ] || BRIDGE=$(pbr 0)
      [ -n "$GATEWAY" ] || GATEWAY=$(sed -n '/^\[/q; s/^ipconfig0:.*gw=\([0-9.]*\).*/\1/p' "$PC" | head -1)
    else
      [ -n "$BRIDGE" ] || BRIDGE=$(pbr 0)
      [ -n "$PAIR_BRIDGE" ] || PAIR_BRIDGE=$(pbr "${pk% *}")
    fi
  fi
  case "$P_ROLE" in
    primary) [ "${ROLE:-standby}" = standby ] || die "$PNAME was installed as the initial primary: this node's VM is the initial standby (two primaries would be two different sets of networks)"; ROLE=standby;;
    standby) [ "${ROLE:-primary}" = primary ] || die "$PNAME was installed as the initial standby: this node's VM is the initial primary"; ROLE=primary;;
  esac
fi

# ------------------------------------------------------------------------------- what is still missing: asked for
if [ $INTRO = 1 ]; then
  if [ ${#USBMAPS[@]} -eq 0 ]; then
    echo "   The sticks here that the kit knows (the VM finds out by itself which is Z-Wave and which is Zigbee; one kind alone is fine):"
    show_sticks || echo "      none"
  fi
  if [ -n "$PVMID" ]; then
    echo "   This VM joins $PNAME on $PNODE: its address ${SELF:-?}, $PNAME's $PEER, the floating address ${VIP:-?}."
    [ "$ROLE" != standby ] || echo "   $PNAME is the initial primary, so this node starts as the STANDBY: the sticks here WILL BE WIPED by the first sync."
    [ "$ROLE" != primary ] || echo "   $PNAME is the initial standby, so this node starts as the PRIMARY: the sticks here hold your networks and stay as they are."
  fi
fi
if [ -z "$ROLE" ] && [ $NOUSB = 0 ]; then                  # the one question nobody can answer for the user
  [ $ASK = 1 ] || die "say what this node is INITIALLY: --initial-role primary (its radios are configured: the sticks here hold your networks) or --initial-role standby (its radios will be wiped: the sticks here are overwritten with the primary's networks). Only for the start: the two swap later"
  echo "   Is this node INITIALLY the primary or the standby of the pair?"
  echo "   (Only for the start: after the first sync the two are equals and swap at a failover or a switch.)"
  echo "      primary  its radios are configured: the sticks here hold your networks. They stay as they are."
  echo "      standby  its radios WILL BE WIPED: the sticks here are overwritten with the primary's networks."
  while :; do
    ask "initially primary or standby"
    case "${ANS,,}" in primary|p) ROLE=primary; break;; standby|s) ROLE=standby; break;; esac
  done
  if [ "$ROLE" = primary ] && [ $FIRST = 0 ]; then
    ask "Do the sticks here already hold your Z-Wave / Zigbee networks? (n: a new house, nothing paired yet)" y
    case "${ANS,,}" in n|no) FIRST=1;; esac
  fi
fi
[ $NOUSB = 0 ] || [ -n "$ROLE" ] || ROLE=standby          # a drill has no radios: the harmless role
if [ -z "$NAME" ]; then                 # the name is the user's: offered, asked for when someone is there
  for i in 1 2 3 4 5 6 7 8 9; do
    printf '%s\n' "$VMS" | awk -v n="zradio$i" '$2 == n { f = 1 } END { exit !f }' || { NAME="zradio$i"; break; }
  done
  [ -n "$NAME" ] || die "zradio1 … zradio9 are all taken: name this VM with --name"
  if [ $ASK = 1 ]; then
    while :; do
      ask "the name of this node's radio VM" "$NAME"
      if name_ok "$ANS"; then NAME=$ANS; break; fi
      echo "         a short lower-case name (letters, digits, -), please"
    done
  else NAME_NOTE="no --name: this VM is called $NAME (the first free of zradio1, zradio2, …)"; fi
fi
if [ $ASK = 1 ] && [ $NOUSB = 0 ]; then
  if [ -z "$BRIDGE" ] && [ -z "$PAIR_BRIDGE" ]; then
    brs=$(for b in "$NETSYS"/*/bridge; do [ -d "$b" ] && basename "$(dirname "$b")"; done | tr '\n' ' ')
    echo "   The network the two radio VMs and Home Assistant share — this node's bridges: ${brs:-none found}"
    while :; do ask "bridge" "$([ -d "$NETSYS/vmbr0/bridge" ] && echo vmbr0)"; br_ok "$ANS" && break; done; BRIDGE=$ANS
  fi
  while ! cidr "$SELF"; do ask "this VM's address there, with its prefix (like 192.168.1.21/24)"; SELF=$ANS; done
  while ! ip4 "$PEER"; do ask "the other radio VM's address (the second node's VM gets it)"; PEER=$ANS; done
  while ! cidr "$VIP"; do ask "the floating address Home Assistant will connect to"; VIP=$ANS; ip4 "$VIP" && VIP="$VIP/${SELF##*/}"; done
  if [ -z "$PAIR_BRIDGE" ]; then while ! ip4 "$GATEWAY"; do ask "the gateway of that network"; GATEWAY=$ANS; done; fi
fi
[ -n "$BRIDGE" ] || BRIDGE=vmbr0
[ -n "$VRID" ] || VRID=50

[ -z "$NAME" ] || name_ok "$NAME" || die "--name '$NAME': a short lower-case name (letters, digits, -)"
cidr "$SELF" || die "--self '$SELF': this VM's address as A.B.C.D/prefix"
ip4 "$PEER" || die "--peer '$PEER': the other radio VM's address"
cidr "$VIP" || die "--vip '$VIP': the floating address as A.B.C.D/prefix"
[ "${SELF%/*}" != "$PEER" ] && [ "${SELF%/*}" != "${VIP%/*}" ] && [ "$PEER" != "${VIP%/*}" ] || die "--self, --peer and --vip are three different addresses"
[[ "$VRID" =~ ^[0-9]+$ ]] && [ "$VRID" -ge 1 ] && [ "$VRID" -le 255 ] || die "--vrid '$VRID': 1-255"
[ -z "$PRIORITY" ] || { [[ "$PRIORITY" =~ ^[0-9]+$ ]] && [ "$PRIORITY" -ge 1 ] && [ "$PRIORITY" -le 254 ]; } || die "--priority '$PRIORITY': 1-254"
case "$ROLE" in primary|standby) ;; *) die "--initial-role '$ROLE': primary (this node's radios are configured) or standby (this node's radios will be wiped) — what the node is at the start; the two swap later";; esac
[ "$ROLE" != standby ] || [ $FIRST = 0 ] || die "--first is for the initial primary of a new house: a standby's sticks are filled by the primary's sync"
br_ok "$BRIDGE" || die "--bridge '$BRIDGE'"
[ -z "$PAIR_BRIDGE" ] || br_ok "$PAIR_BRIDGE" || die "--pair-bridge '$PAIR_BRIDGE'"
if [ -z "$PAIR_BRIDGE" ]; then ip4 "$GATEWAY" || die "without --pair-bridge the pair talks over the LAN on net0: --gateway A.B.C.D is needed with --self"; fi
[ -z "$PAIR_MAC" ] || [[ "$PAIR_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || die "--pair-mac '$PAIR_MAC'"
[ -z "$VMID" ] || { [[ "$VMID" =~ ^[0-9]{3,9}$ ]] && [ "$VMID" -ge 100 ]; } || die "--vmid '$VMID'"
[[ "$MEMORY" =~ ^[0-9]{3,6}$ ]] && [[ "$CORES" =~ ^[0-9]{1,2}$ ]] && [[ "$DISK" =~ ^[0-9]+G$ ]] || die "--memory MB, --cores N, --disk <n>G"
[ -z "$HOOK" ] || [[ "$HOOK" =~ ^[A-Za-z0-9_-]+:snippets/[A-Za-z0-9._-]+$ ]] || die "--hookscript '$HOOK': a volume id like local:snippets/my-hook.sh"
for m in ${USBMAPS[@]+"${USBMAPS[@]}"}; do [[ "$m" =~ ^[A-Za-z][A-Za-z0-9_-]{0,60}$ ]] || die "--usb-mapping '$m'"; done
[ $NOUSB = 0 ] || [ ${#USBMAPS[@]} -eq 0 ] || die "--no-usb and --usb-mapping contradict each other"
[ $NOUSB = 0 ] || [ $START = 0 ] || die "--no-usb is a drill: a VM without a stick is not put into a pair (--start)"
for e in ${EXTRA[@]+"${EXTRA[@]}"}; do
  [[ "$e" =~ ^[A-Z][A-Z0-9_]*=[A-Za-z0-9./:_@+-]*$ ]] || die "--conf '$e': KEY=value"
  case "${e%%=*}" in NAME|SELF|PEER|VIP|VRID|PRIORITY) die "--conf ${e%%=*}: that one has its own option";; esac
done
if [ -n "$PVMID" ]; then [ "$PEER" = "$P_SELF" ] && [ "${SELF%/*}" = "$P_PEER" ] || die "$PNAME says it is $P_SELF and expects its peer at $P_PEER; this VM would be ${SELF%/*} with its peer at $PEER — the two do not fit (--no-pair: a pair of its own)"; fi
[ -n "$PRIORITY" ] || { [ "$ROLE" = primary ] && PRIORITY=110 || PRIORITY=100; }
# every answer as options: what a terminal-less run of the same would be, and what the confirmed run is started with
ARGS=(--name "$NAME" --initial-role "$ROLE" --self "$SELF" --peer "$PEER" --vip "$VIP" --vrid "$VRID" --priority "$PRIORITY" --bridge "$BRIDGE")
[ -z "$PAIR_BRIDGE" ] || ARGS+=(--pair-bridge "$PAIR_BRIDGE"); [ -z "$GATEWAY" ] || ARGS+=(--gateway "$GATEWAY")
[ $FIRST = 0 ] || ARGS+=(--first); [ $START = 0 ] || ARGS+=(--start)
if [ -n "$PVMID" ]; then ARGS+=(--join "$PNAME"); elif [ $PAIR = 0 ]; then ARGS+=(--no-pair); fi
ARGS+=(${PASS[@]+"${PASS[@]}"})
echo "== 0. checks ($NODE; $([ $RUN = 1 ] && echo RUN || echo "report only: nothing is changed")) =="
[ -z "${NAME_NOTE:-}" ] || warn "$NAME_NOTE"
case "$ROLE" in
  primary) ok "this node starts as the PRIMARY: $([ $FIRST = 1 ] && echo "a new house — its sticks hold no network yet, Home Assistant forms it" || echo "its sticks hold your networks and stay as they are (the installer in the VM checks that they do)")";;
  standby) [ $NOUSB = 1 ] || warn "this node starts as the STANDBY: its sticks WILL BE OVERWRITTEN with the primary's networks at the first sync, whatever they hold now; the VM does not serve before that";;
esac
[ -n "$VMS" ] || warn "the cluster lists no VM at all (pvesh get /cluster/resources): the name and address checks have nothing to look at"
if printf '%s\n' "$VMS" | awk -v n="$NAME" '$2 == n { f = 1 } END { exit !f }'; then
  bad "a VM named $NAME exists already ($(printf '%s\n' "$VMS" | awk -v n="$NAME" '$2 == n { print "on " $3 ", " $4 }')). This tool builds a new VM and never rebuilds one: pick another name, or remove that VM yourself first"
else ok "no VM is named $NAME"; fi
if [ -z "$VMID" ]; then VMID=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc 0-9); [[ "$VMID" =~ ^[0-9]{3,9}$ ]] || { bad "pvesh get /cluster/nextid gave no id: name one with --vmid"; VMID=0; }; fi
if printf '%s\n' "$VMS" | awk -v i="$VMID" '$1 == i { f = 1 } END { exit !f }'; then bad "the id $VMID is taken ($(printf '%s\n' "$VMS" | awk -v i="$VMID" '$1 == i { print $2 }'))"; else ok "$NAME gets the id $VMID"; fi
# another VM with this address: refused when it runs; said when it is stopped (the VM this one replaces)
for f in "$PVE"/nodes/*/qemu-server/*.conf; do
  [ -f "$f" ] || continue
  grep -qE "^ipconfig[0-9]+:.*ip=${SELF%/*}/" "$f" || continue
  oid=$(basename "$f" .conf); oname=$(printf '%s\n' "$VMS" | awk -v i="$oid" '$1 == i { print $2 }'); ost=$(printf '%s\n' "$VMS" | awk -v i="$oid" '$1 == i { print $4 }')
  if [ "$ost" = running ]; then bad "${oname:-VM $oid} runs with the address ${SELF%/*} already: two VMs on one address. Stop it first (it is the VM this one replaces?), or give this one another --self"
  else warn "${oname:-VM $oid} (${ost:-stopped}) is configured with ${SELF%/*} too: it must stay stopped while $NAME runs"; fi
done
if [ -z "$STORAGE" ]; then
  STORAGE=$(pvesh get /storage --output-format json 2>/dev/null | python3 -c '
import json, sys
try: st = {s["storage"]: s for s in json.load(sys.stdin)}
except ValueError: st = {}
for n in ("local-zfs", "local-lvm", "local"):
    if n in st and "images" in st[n].get("content", ""): print(n); break')
fi
[ -n "$STORAGE" ] && ok "the disk goes onto $STORAGE" || bad "no storage for the disk: none of local-zfs, local-lvm, local holds images — name one with --storage"
SNIPDIR=$(pvesh get "/storage/$SNIP" --output-format json 2>/dev/null | python3 -c '
import json, sys
try: s = json.load(sys.stdin)
except ValueError: s = {}
print(s.get("path", "") if "snippets" in s.get("content", "") else "")')
[ -n "$SNIPDIR" ] && { SNIPDIR="$SNIPDIR/snippets"; ok "the cloud-init file goes to $SNIPDIR ($SNIP)"; } \
  || bad "the storage '$SNIP' does not hold snippets (pvesm set $SNIP --content <what it has now>,snippets — or name another with --snippets)"
[ -s "$KEYS" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$KEYS" && ok "root's keys for the VM: $(grep -cE '^(ssh-|ecdsa-|sk-)' "$KEYS") from $KEYS" \
  || bad "no public key in $KEYS: the VM would have no way in (--ssh-keys FILE)"
if [ $HA = 1 ]; then
  command -v ha-manager >/dev/null 2>&1 && ha-manager status >/dev/null 2>&1 && ok "Proxmox HA answers: the VM becomes a resource pinned to $NODE" \
    || bad "ha-manager status does not answer (a node that is in no cluster has no HA: --no-ha)"
fi

echo "== 1. the sticks on $NODE =="
S=$(sticks_here); M=$(mappings)
vm_with_usb() { # vm_with_usb running|idle <vid:pid> [<bus-port>]: prints the name of a VM on this node (running / not running)
  # whose usb lines reach that device — through any USB mapping whose entry for this node names it, or by host=<vid:pid> /
  # host=<bus-port>
  local want=$1 f id line v; shift
  for f in "$PVE"/nodes/"$NODE"/qemu-server/*.conf; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .conf)
    if printf '%s\n' "$VMS" | awk -v i="$id" '$1 == i && $4 == "running" { f = 1 } END { exit !f }'; then [ "$want" = running ] || continue; else [ "$want" = idle ] || continue; fi
    while read -r line; do
      case "$line" in
        *mapping=*) v=${line##*mapping=}; v=${v%%,*}
          printf '%s\n' "$M" | awk -v m="$v" -v n="$NODE" -v i="$1" -v p="${2:--}" '$1 == m && $2 == n && $3 == i && ($4 == "-" || p == "-" || $4 == p) { f = 1 } END { exit !f }' || continue;;
        *host=*) v=${line##*host=}; v=${v%%,*}; v=${v#0x}
          [ "${v,,}" = "$1" ] || { [ -n "${2:-}" ] && [ "$v" = "$2" ]; } || continue;;
        *) continue;;
      esac
      v=$(printf '%s\n' "$VMS" | awk -v i="$id" '$1 == i { print $2 }'); echo "${v:-VM $id}"; return 0
    done < <(sed -n '/^\[/q; /^usb[0-9]*:/p' "$f")          # the current config only, not its snapshots' sections
  done
  return 1
}
USE=()            # the mapping ids the VM gets, in order
DEVS=()           # the device behind each: "<vid:pid> <bus-port or ->"
TODO=()           # "create <id> <vid:pid> <path|->" or "extend <id> <vid:pid> <path|->"
if [ $NOUSB = 1 ]; then
  warn "--no-usb: no USB device is passed through. This VM is a drill of the tool: its installer will end with 'no stick found'"
elif [ ${#USBMAPS[@]} -gt 0 ]; then
  for m in "${USBMAPS[@]}"; do
    e=$(printf '%s\n' "$M" | awk -v m="$m" -v n="$NODE" '$1 == m && $2 == n { print $3; exit }')
    if [ -z "$e" ]; then bad "the USB mapping '$m' has no entry for $NODE (pvesh get /cluster/mapping/usb)"; continue; fi
    if usb_present "$e"; then
      ok "mapping $m: $e is plugged into $NODE"
    elif [ -n "$HOOK" ]; then warn "mapping $m: no $e on $NODE's USB right now — taken as a port your hookscript switches on before the start"
    else bad "mapping $m: no USB device $e on $NODE right now"; fi
    USE+=("$m"); DEVS+=("$e $(printf '%s\n' "$M" | awk -v m="$m" -v n="$NODE" '$1 == m && $2 == n { print $4; exit }')")
  done
else
  [ -n "$S" ] && printf '%s\n' "$S" | sed 's/^/         found: /'
  declare -A SEEN=()
  while read -r port id kinds product; do
    [ -n "$port" ] || continue
    n=$(printf '%s\n' "$S" | awk -v i="$id" '$2 == i { c++ } END { print c + 0 }')
    base="zradio-${id/:/}"
    if [ "$n" -gt 1 ]; then SEEN[$id]=$(( ${SEEN[$id]:-0} + 1 )); mid="$base-${SEEN[$id]}"; path=$port; else mid=$base; path=-; fi
    have=$(printf '%s\n' "$M" | awk -v m="$mid" -v nn="$NODE" '$1 == m { any = 1 } $1 == m && $2 == nn { here = 1 } END { print (here ? "here" : (any ? "other" : "none")) }')
    case "$have" in
      here) ok "USB mapping $mid names $id on $NODE already";;
      other) TODO+=("extend $mid $id $path");;
      none) TODO+=("create $mid $id $path");;
    esac
    USE+=("$mid"); DEVS+=("$id $path")
  done <<< "$S"
  if [ ${#USE[@]} -eq 0 ]; then
    if [ $NORADIOS = 1 ]; then warn "no stick on $NODE that the kit's table names — the VM is built without one (--allow-no-radios)"
    else bad "no stick on $NODE that the kit's table names (./install.sh --sticks). A stick the table does not know: make a USB mapping for it and pass --usb-mapping; a drill without sticks: --allow-no-radios"; fi
  fi
fi
[ ${#USE[@]} -le 5 ] || bad "${#USE[@]} USB devices: a VM takes five here (usb0-usb4) — name the ones you mean with --usb-mapping"
i=0
for m in ${USE[@]+"${USE[@]}"}; do
  read -r did dpath <<< "${DEVS[$i]}"; i=$((i + 1)); [ "$dpath" != - ] || dpath=""
  if r=$(vm_with_usb running "$did" "$dpath"); then bad "the running VM $r on $NODE has the USB device $did (mapping $m here) passed through already: two VMs on one stick. Stop it first (it is the VM this one replaces?)"
  elif r=$(vm_with_usb idle "$did" "$dpath"); then warn "$r (not running) on $NODE still has the USB device $did in its config: take that usb line off it while $NAME uses the stick — anything that starts it (a backup in stop mode does) would reach for the stick"; fi
done

[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL — nothing was changed =="; exit 1; }

for t in ${TODO[@]+"${TODO[@]}"}; do
  read -r verb mid id path <<< "$t"
  entry="node=$NODE,id=$id"; [ "$path" = - ] || entry="$entry,path=$path"
  if [ "$verb" = create ]; then
    do_ pvesh create /cluster/mapping/usb --id "$mid" --map "$entry" --description "zradio: a radio stick, one entry per node (made by ha_zradio)" || exit 1
  else # the mapping exists for another node: every entry it has, plus this node's
    args=(); while read -r _ on oid opath; do [ -n "$on" ] || continue; o="node=$on,id=$oid"; [ "$opath" = - ] || o="$o,path=$opath"; args+=(--map "$o"); done <<< "$(printf '%s\n' "$M" | awk -v m="$mid" '$1 == m')"
    do_ pvesh set "/cluster/mapping/usb/$mid" "${args[@]}" --map "$entry" || exit 1
  fi
done

echo "== 2. the Debian image =="
if [ -s "$CACHE/$IMAGE_NAME" ] && [ -s "$CACHE/$IMAGE_NAME.sha512" ]; then ok "image cached: $CACHE/$IMAGE_NAME ($(cut -c1-16 "$CACHE/$IMAGE_NAME.sha512")…)"
elif [ $RUN = 1 ]; then
  mkdir -p "$CACHE"
  ( cd "$CACHE" && wget -q "$IMAGE_DIR/SHA512SUMS" -O SHA512SUMS.tmp && wget -q "$IMAGE_DIR/$IMAGE_NAME" -O "$IMAGE_NAME.tmp" ) || { bad "download from $IMAGE_DIR failed"; exit 1; }
  want=$(awk -v n="$IMAGE_NAME" '$2 == n { print $1 }' "$CACHE/SHA512SUMS.tmp"); got=$(sha512sum "$CACHE/$IMAGE_NAME.tmp" | awk '{ print $1 }')
  if [ -n "$want" ] && [ "$want" = "$got" ]; then mv -f "$CACHE/$IMAGE_NAME.tmp" "$CACHE/$IMAGE_NAME"; echo "$got" > "$CACHE/$IMAGE_NAME.sha512"; unlink "$CACHE/SHA512SUMS.tmp"; done_ "image $IMAGE_NAME, sha512 ${got:0:16}… (from $IMAGE_DIR)"
  else unlink "$CACHE/$IMAGE_NAME.tmp"; unlink "$CACHE/SHA512SUMS.tmp"; bad "sha512 mismatch for $IMAGE_NAME (the list says ${want:-nothing}, the file is $got)"; exit 1; fi
else would "download $IMAGE_DIR/$IMAGE_NAME and SHA512SUMS, check, keep under $CACHE"; fi

echo "== 3. the cloud-init file $SNIPDIR/$NAME-zradio.yaml =="
mk_user_data() {
  local kit64
  kit64=$(tar -C "$KIT" --owner=0 --group=0 --sort=name -czf - guest zradio.conf.example | base64 -w 76 | sed 's/^/      /')
  cat <<EOF
#cloud-config
# $NAME: one radio VM of a zradio pair (ha_zradio's install.sh on $NODE, $(date -u +%F)). Debian 13 generic; root over keys
# only. The kit's files are put here; install.sh on the node runs the kit's installer through the guest agent.
hostname: $NAME
disable_root: false
ssh_pwauth: false
package_update: true
packages:
  - qemu-guest-agent
users:
  - name: root
    ssh_authorized_keys:
$(grep -E '^(ssh-|ecdsa-|sk-)' "$KEYS" | sed 's/^/      - /')
write_files:
  - path: /root/zradio.conf
    permissions: "0600"
    content: |
      # written by install.sh on $NODE; the installed copy is /etc/zradio/zradio.conf
      NAME=$NAME
      SELF=${SELF%/*}
      PEER=$PEER
      VIP=$VIP
      VRID=$VRID
      PRIORITY=$PRIORITY
$(for e in ${EXTRA[@]+"${EXTRA[@]}"}; do printf '      %s\n' "$e"; done)
  - path: /root/zradio-kit.tgz
    permissions: "0600"
    encoding: b64
    content: |
$kit64
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
}
if [ $RUN = 1 ]; then
  mkdir -p "$SNIPDIR" && mk_user_data > "$SNIPDIR/$NAME-zradio.yaml.tmp" && mv -f "$SNIPDIR/$NAME-zradio.yaml.tmp" "$SNIPDIR/$NAME-zradio.yaml" \
    && done_ "$SNIPDIR/$NAME-zradio.yaml ($(wc -c < "$SNIPDIR/$NAME-zradio.yaml" | tr -d ' ') bytes: root's keys, the guest agent, the kit's guest folder, zradio.conf)" \
    || { bad "could not write $SNIPDIR/$NAME-zradio.yaml"; exit 1; }
else would "write $SNIPDIR/$NAME-zradio.yaml: root's keys, qemu-guest-agent, the kit's guest folder, zradio.conf (NAME=$NAME SELF=${SELF%/*} PEER=$PEER VIP=$VIP VRID=$VRID PRIORITY=$PRIORITY${EXTRA[*]:+ ${EXTRA[*]}})"; fi

echo "== 4. the VM $NAME ($VMID) =="
NETS=(--net0 "virtio,bridge=$BRIDGE")
if [ -n "$PAIR_BRIDGE" ]; then
  NETS+=(--ipconfig0 ip=dhcp --net1 "virtio${PAIR_MAC:+=$PAIR_MAC},bridge=$PAIR_BRIDGE" --ipconfig1 "ip=$SELF")
else NETS=(--net0 "virtio${PAIR_MAC:+=$PAIR_MAC},bridge=$BRIDGE" --ipconfig0 "ip=$SELF,gw=$GATEWAY"); fi
USBS=(); i=0; for m in ${USE[@]+"${USE[@]}"}; do USBS+=("--usb$i" "mapping=$m"); i=$((i + 1)); done
do_ qm create "$VMID" --name "$NAME" --ostype l26 --machine q35 --bios ovmf --cores "$CORES" --memory "$MEMORY" --cpu host --scsihw virtio-scsi-single \
    --agent enabled=1 "${NETS[@]}" --serial0 socket --vga serial0 --onboot 1 --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
    --ide2 "$STORAGE:cloudinit" --cicustom "user=$SNIP:snippets/$NAME-zradio.yaml" ${USBS[@]+"${USBS[@]}"} ${HOOK:+--hookscript "$HOOK"} \
    --tags zradio --description "$NAME: one radio VM of a zradio pair — this node's Z-Wave / Zigbee sticks, served to Home Assistant on ${VIP%/*} while it holds that address, kept silent otherwise. Pinned to $NODE (its sticks are here). https://github.com/yuvaloren/ha_zradio" || exit 1
do_ qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$CACHE/$IMAGE_NAME,discard=on" || exit 1
do_ qm disk resize "$VMID" scsi0 "$DISK" || exit 1
do_ qm set "$VMID" --boot order=scsi0 || exit 1

echo "== 5. $([ $HA = 1 ] && echo "Proxmox HA: pinned to $NODE, then started" || echo "the start (no HA)") =="
if [ $HA = 1 ]; then
  do_ ha-manager add "vm:$VMID" --state stopped --max_restart 3 --max_relocate 0 --comment "zradio: $NAME, on $NODE's sticks" || exit 1
  do_ ha-manager rules add node-affinity "$NAME-on-$NODE" --resources "vm:$VMID" --nodes "$NODE" --strict 1 --comment "zradio: $NAME serves $NODE's own sticks and never runs elsewhere" || exit 1
  do_ ha-manager set "vm:$VMID" --state started || exit 1
else do_ qm start "$VMID" || exit 1; fi

echo "== 6. the kit, installed in $NAME through its guest agent =="
if [ $RUN = 0 ]; then
  would "wait for the guest agent and cloud-init; unpack the kit in the VM and run its installer there (guest/install.sh --run --detect --initial-role $ROLE$([ $FIRST = 1 ] && echo ' --first')), its lines shown here"
  if [ -n "$PVMID" ]; then would "introduce $NAME and $PNAME ($PNODE) to each other: each one's sync key and host key into the other (zradio-sync keys / trust), then a hello over that link"
  elif [ $NOUSB = 0 ]; then warn "this is the pair's first VM: run ./install.sh on the other node next — it finds $NAME and takes everything from it"; fi
  [ $START = 0 ] || would "systemctl start zradio.target in $NAME: it joins the pair"
  echo "REPORT ONLY — nothing was changed."
  [ $ASK = 1 ] || exit 0
  printf '   Go ahead? [y/N]: '; read -r ANS || ANS=n
  case "${ANS,,}" in y|yes) echo; exec bash "$0" "${ARGS[@]}" --run;; esac
  printf '   Nothing was changed. The same without the questions:\n      ./install.sh'; printf ' %q' "${ARGS[@]}" --run; echo
  exit 0
fi
n=0; until agent_up "$NODE" "$VMID"; do n=$((n + 1)); [ $n -lt 60 ] || break; sleep "$WAIT"; done
agent_up "$NODE" "$VMID" && ok "the guest agent answers" || { bad "no guest agent in $((60 * WAIT)) s — the VM's console: qm terminal $VMID$([ -n "$HOOK" ] && echo " (a hookscript that refused the start says so in the task log)")"; exit 1; }
st=""; n=0
while :; do
  st=$(gx "$NODE" "$VMID" 20 'cloud-init status' | awk '/^status:/ { print $2 }')
  case "$st" in done|error|degraded) break;; esac
  n=$((n + 1)); [ $n -lt 240 ] || break; sleep "$WAIT"
done
case "$st" in done|degraded) ok "cloud-init finished ($st)";; *) bad "cloud-init ended '${st:-no answer}' — in the VM: /var/log/cloud-init-output.log"; exit 1;; esac
gx "$NODE" "$VMID" 60 'mkdir -p /opt/zradio/kit && tar -xzf /root/zradio-kit.tgz -C /opt/zradio/kit && rm -f /root/zradio-install.rc && : > /var/log/zradio-install.log' >/dev/null \
  || { bad "the kit did not unpack in $NAME (/root/zradio-kit.tgz, written by cloud-init)"; exit 1; }
INST="bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role $ROLE$([ $FIRST = 1 ] && echo ' --first')"
gx_start "$NODE" "$VMID" "$INST > /var/log/zradio-install.log 2>&1; echo \$? > /root/zradio-install.rc" >/dev/null || { bad "the installer did not start in $NAME"; exit 1; }
echo "   the kit's installer in $NAME (its log there: /var/log/zradio-install.log):"
at=0; rc=""; n=0; LOG=""
while :; do     # its finished lines as they come (@@at: how many were sent so far); the last round carries the exit code (@@rc)
  # shellcheck disable=SC2016  # the script runs in the VM
  chunk=$(gx "$NODE" "$VMID" 20 "L=$at"'; f=/var/log/zradio-install.log; n=$(wc -l < $f); [ "$n" -le "$L" ] || sed -n "$((L + 1)),${n}p" $f; echo "@@at $n"; [ ! -f /root/zradio-install.rc ] || echo "@@rc $(cat /root/zradio-install.rc)"') || chunk=""
  rc=$(printf '%s\n' "$chunk" | sed -n 's/^@@rc \([0-9]*\)$/\1/p' | tail -1)
  got=$(printf '%s\n' "$chunk" | sed -n 's/^@@at \([0-9]*\)$/\1/p' | tail -1); [ -z "$got" ] || at=$got
  chunk=$(printf '%s\n' "$chunk" | sed '/^@@\(rc\|at\) [0-9]*$/d; /^$/d')
  if [ -n "$chunk" ]; then printf '%s\n' "$chunk" | sed 's/^/      | /'; LOG="$LOG$chunk"$'\n'; fi
  [ -z "$rc" ] || break
  n=$((n + 1)); [ $n -lt 360 ] || break; sleep "$WAIT"
done
if [ "$rc" = 0 ]; then ok "the kit is installed in $NAME, as the initial $ROLE"
elif [ $NOUSB = 1 ] && printf '%s' "$LOG" | grep -q "FAIL  zradio-detect did not end clean"; then
  ok "the drill went as far as a VM without a stick can: the VM, cloud-init, the kit unpacked, its packages — and the installer stopped at the detection, with no stick to find"
  echo "== a drill. To remove it: $([ $HA = 1 ] && echo "ha-manager rules remove $NAME-on-$NODE; ha-manager remove vm:$VMID; ")qm stop $VMID; qm destroy $VMID --purge; and the file $SNIPDIR/$NAME-zradio.yaml =="
  exit 0
else bad "the installer ended ${rc:-without an exit code} in $NAME — nothing was started there. Its lines are above; to run it again in the VM: $INST"; exit 1; fi
RAD=$(gx "$NODE" "$VMID" 20 'grep -E "^(ZWAVE|ZIGBEE)=" /etc/zradio/radios.conf')
ZW=$(printf '%s\n' "$RAD" | sed -n 's/^ZWAVE=//p' | tr -dc a-z); ZB=$(printf '%s\n' "$RAD" | sed -n 's/^ZIGBEE=//p' | tr -dc a-z)
has_kind() { case "$1" in served|synced) return 0;; *) return 1;; esac; }
ok "$NAME's radios: Z-Wave $(has_kind "$ZW" && echo yes || echo "none"), Zigbee $(has_kind "$ZB" && echo yes || echo "none")"
if [ -n "$PVMID" ]; then
  for k in Z-Wave:$ZW:$P_ZWAVE Zigbee:$ZB:$P_ZIGBEE; do
    IFS=: read -r kn mine theirs <<< "$k"
    if has_kind "$mine" && ! has_kind "$theirs"; then warn "$NAME has a $kn stick and $PNAME has none: $kn is served only while $NAME is the one that serves — it does not fail over"
    elif ! has_kind "$mine" && has_kind "$theirs"; then warn "$PNAME has a $kn stick and $NAME has none: $kn is served only while $PNAME is the one that serves — it does not fail over"; fi
  done
fi

if [ -n "$PVMID" ]; then
  echo "== 7. $NAME and $PNAME, introduced to each other =="
  keyre='^ssh-ed25519 [A-Za-z0-9+/=]{60,80}$'
  keys_of() { # keys_of <node> <vmid>: "SYNC<TAB>HOST", both checked
    local k s h; k=$(gx "$1" "$2" 30 '/usr/local/sbin/zradio-sync keys') || return 1
    s=$(printf '%s\n' "$k" | sed -n 's/^SYNCKEY //p'); h=$(printf '%s\n' "$k" | sed -n 's/^HOSTKEY //p')
    [[ "$s" =~ $keyre ]] && [[ "$h" =~ $keyre ]] || return 1
    printf '%s\t%s\n' "$s" "$h"
  }
  trust() { # trust <node> <vmid> <name> <"SYNC<TAB>HOST" of the other> <the other's name>
    gx "$1" "$2" 30 "/usr/local/sbin/zradio-sync trust --sync-key '${4%%$'\t'*}' --host-key '${4##*$'\t'}'" >/dev/null \
      && done_ "$3 trusts $5: its host key pinned, its sync key allowed to run the sync and nothing else" || { bad "zradio-sync trust failed in $3"; return 1; }
  }
  if KM=$(keys_of "$NODE" "$VMID") && KP=$(keys_of "$PNODE" "$PVMID"); then
    trust "$PNODE" "$PVMID" "$PNAME" "$KM" "$NAME" && trust "$NODE" "$VMID" "$NAME" "$KP" "$PNAME" || exit 1
    if h=$(gx "$NODE" "$VMID" 40 '/usr/local/sbin/zradio-sync peer-hello'); then ok "$NAME reached $PNAME over the sync's own link: $(printf '%s' "$h" | head -1 | cut -c1-120)"
    else bad "$NAME does not reach $PNAME at $PEER over ssh (zradio-sync peer-hello): the two are on the same network? Nothing was started"; exit 1; fi
  else bad "could not read the two VMs' public keys (zradio-sync keys in $NAME and in $PNAME)"; exit 1; fi
fi

echo "== $([ -n "$PVMID" ] && echo 8 || echo 7). the start =="
if [ $START = 0 ] && [ $ASK = 1 ]; then
  echo "   Starting $NAME puts it into the pair: $([ "$ROLE" = primary ] && echo "it takes the floating address ${VIP%/*} and serves this node's sticks" || echo "it stands by, and serves only after the primary's first sync has filled its sticks")."
  while :; do printf '   Start it now? [y/n]: '; read -r ANS || ANS=n; case "${ANS,,}" in y|yes) START=1; break;; n|no) break;; esac; done
fi
if [ $START = 1 ]; then
  gx "$NODE" "$VMID" 90 'systemctl start zradio.target' >/dev/null && done_ "systemctl start zradio.target in $NAME: it is in the pair" || bad "systemctl start zradio.target failed in $NAME"
  gx "$NODE" "$VMID" 30 '/usr/local/sbin/zradio-serve status' | sed 's/^/      | /'
else warn "$NAME is installed and not started. To start it: qm guest exec $VMID -- systemctl start zradio.target"; fi
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL =="; exit 1; }
zp=6639; gp=6638; for e in ${EXTRA[@]+"${EXTRA[@]}"}; do case "$e" in ZWAVE_PORT=*) zp=${e#*=};; ZIGBEE_PORT=*) gp=${e#*=};; esac; done
echo "== done: $NAME on $NODE =="
if [ -n "$PVMID" ]; then echo "   The pair is complete: $PNAME on $PNODE, $NAME on $NODE. $([ "$ROLE" = standby ] && echo "$PNAME" || echo "$NAME") writes its networks onto the other's sticks within 15 minutes of both being started."
else echo "   Next: ./install.sh on the other node. It finds $NAME, takes the addresses from it and pairs the two."; fi
echo "   In Home Assistant:$(has_kind "$ZW" && echo "  Z-Wave JS → tcp://${VIP%/*}:$zp")$(has_kind "$ZB" && echo "  ZHA → socket://${VIP%/*}:$gp")"
echo "   Who serves, and why: qm guest exec $VMID -- zradio-serve status"
exit 0
