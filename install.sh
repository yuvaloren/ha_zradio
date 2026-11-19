#!/usr/bin/env bash
# install.sh — one radio VM of a zradio pair on THIS Proxmox VE node. Run it as root on each of the two nodes:
#     ./install.sh
# It asks what it needs, shows what it would do, and does it after a yes: the VM (Debian 13), this node's Z-Wave
# and/or Zigbee sticks passed through, the kit installed inside (through the guest agent), a watchdog that resets a
# hung VM, a hookscript for its start and its sticks' power. It starts with or without its sticks. No Proxmox HA: the two VMs decide who
# serves. The VM takes its own address from DHCP; the one address asked for is the floating one Home Assistant
# connects to. On the second node it takes the pair's settings from the first VM and introduces the two. On a node
# whose radio VM exists, it UPDATES this node's hookscript and both VMs of the pair to this kit (or says: up to date).
#
# Without a terminal nothing is asked: every answer is an option, and nothing is changed without --run.
#   --answers FILE           the options below as lines of a file, KEY=value (answers.example); for unattended runs
#   --sticks                 list this node's sticks and stop                --update NAME   which VM to update
#   --initial-role primary|standby
#                            primary: this node's sticks hold your networks and stay as they are.
#                            standby: this node's sticks WILL BE WIPED by the first sync.
#                            Only for the start: afterward the two VMs swap. (--first: a new house, no network yet)
#   --name NAME              the VM's name (default: zradio1; the pair's second VM after the first: attic1 -> attic2)
#   --vip A.B.C.D            the floating address: a free one of the VMs' network that DHCP does not hand out
#   --bridge BR              the network the VMs are on (default vmbr0). The VM's own address comes from DHCP there:
#                            RESERVE it for the VM in the DHCP server afterward (the run ends with the address).
#   --self A.B.C.D/NN  --peer A.B.C.D  --gateway A.B.C.D  --vip A.B.C.D/NN
#                            fixed addresses instead of DHCP: this VM, the other VM, the gateway
#   --pair-bridge BR         a link of its own between the nodes for --self; the floating address is on it too
#   --join NAME              the first radio VM, to pair with (found by itself when there is one);  --no-pair
#   --start                  put the VM into the pair at the end        --run   do it
#   more: --vrid --priority --pair-mac --usb-mapping --vmid --storage --snippets --memory --cores --disk --ssh-keys --conf KEY=VALUE
#         --no-usb --allow-no-radios --image-dir --stick-power HUB:PORT --no-stick-power --third-vote-port --third-vote-hostkey   (docs/DESIGN.md)
#   --third-vote A.B.C.D     not a VM: a third vote for a cluster of two nodes, from a machine at that address, where
#                            this same command went first (there it sets up the vote, and prints the line for here).
#
# Needs to reach GitHub: the table of known sticks is built from Home Assistant's USB lists at every run, into gen/.
# Tests: tests/t-host.sh, t-update.sh, t-e2e.sh (Proxmox and the guests are fakes there).
set -uo pipefail
# Env for the tests (tests/fake-node.sh; nothing a user sets). Where this node's things are: ZRADIO_VM_KIT (the kit's
# folder), ZRADIO_VM_SYS (/sys/bus/usb/devices), ZRADIO_VM_NET (/sys/class/net), ZRADIO_VM_PVE (/etc/pve),
# ZRADIO_VM_CACHE (the image cache), ZRADIO_VM_KEYS (root's authorized_keys). ZRADIO_VM_ASK=1: ask as on a terminal.
# ZRADIO_VM_WAIT, ZRADIO_VM_POLL: the seconds between two looks at a VM, and at a command in it or at the votes.
# For --third-vote (host/qdevice.sh): ZRADIO_VM_SSH_DIR (root's .ssh), ZRADIO_VM_QDEV_DB (a node's certificates for
# the vote), ZRADIO_VM_QNETD_PORT (the vote's TCP port).
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${ZRADIO_VM_KIT:-$HERE}
SYS=${ZRADIO_VM_SYS:-/sys/bus/usb/devices}
NETSYS=${ZRADIO_VM_NET:-/sys/class/net}
PVE=${ZRADIO_VM_PVE:-/etc/pve}
CACHE=${ZRADIO_VM_CACHE:-/var/lib/vz/template/cache}
WAIT=${ZRADIO_VM_WAIT:-5}
IMAGE_NAME=debian-13-generic-amd64.qcow2
RUN=0
NODE=$(hostname -s)
# Not a Proxmox node. Home Assistant (its terminal app, or its settings are here, or --radios names a pair): what to
# set there so that it uses the pair (homeassistant/install.sh). Any other machine: the one thing the kit installs
# there is a cluster's third vote (vote/install.sh). So the same line, and the same command, serve on every machine.
if ! { command -v qm >/dev/null 2>&1 && command -v pvesh >/dev/null 2>&1; }; then
  case " $* " in *" -h "*|*" --help "*) ;; *)
    if [ -n "${SUPERVISOR_TOKEN:-}" ] || [ -f /config/.storage/core.config_entries ] || [ -f /homeassistant/.storage/core.config_entries ] \
       || [[ " $* " == *" --radios "* ]] || [[ " $* " == *" --config "* ]]; then
      echo "This is Home Assistant, not a Proxmox node. The kit installs nothing here: it looks at how Home Assistant's"
      echo "Z-Wave and Zigbee are connected, and says what to set so that both use the radio pair (README, \"Connecting"
      echo "Home Assistant\")."
      exec bash "$HERE/homeassistant/install.sh" "$@"
    fi
    echo "This machine is not a Proxmox node (no qm, no pvesh). What the kit installs on any other machine is a"
    echo "Proxmox cluster's third vote, and nothing else (README, \"Two nodes or three\")."
    exec bash "$HERE/vote/install.sh" "$@";; esac
fi
# shellcheck source=host/lib.sh
. "$HERE/host/lib.sh"

# ----------------------------------------------------------------------------------------------------- the answers
NAME="" ROLE="" SELF="" PEER="" VIP="" VRID="" PRIORITY="" BRIDGE="" PAIR_BRIDGE="" GATEWAY="" PAIR_MAC="" VMID="" STORAGE="" SNIP=local
MEMORY=2048 CORES=2 DISK=8G NOPOWER=0 KEYS=${ZRADIO_VM_KEYS:-/root/.ssh/authorized_keys} FIRST=0 START=0 NORADIOS=0 NOUSB=0
IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/latest
USBMAPS=() POWER=() EXTRA=() STICKS=0 JOIN="" PAIR=1 PASS=() UPDATE="" THIRD=0 VOTE="" VOTE_PORT=22 VOTE_HOSTKEY=""
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
        FIRST|START|NO_PAIR|NO_USB|ALLOW_NO_RADIOS|NO_STICK_POWER) case "$v" in yes) F+=("$o");; no) ;; *) die "--answers $2: $k is yes or no";; esac;;
        *) F+=("$o" "$v");;
      esac
    done < "$2"; shift 2
  else A+=("$1"); shift; fi; done
set -- ${F[@]+"${F[@]}"} ${A[@]+"${A[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in --name|--initial-role|--self|--peer|--vip|--vrid|--priority|--bridge|--pair-bridge|--gateway|--join|--update|--pair-mac|--vmid|--storage|--snippets|--memory|--cores|--disk|--stick-power|--third-vote|--third-vote-port|--third-vote-hostkey|--ssh-keys|--image-dir|--usb-mapping|--conf)
    [ $# -ge 2 ] || die "$1 needs a value (./install.sh --help)";; esac
  case "$1" in
  -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p}' "$0"; exit 0;;
  --sticks) STICKS=1; shift;; --run) RUN=1; shift;; --first) FIRST=1; shift;; --start) START=1; shift;; --no-pair) PAIR=0; shift;;
  --allow-no-radios) NORADIOS=1; PASS+=("$1"); shift;; --no-usb) NOUSB=1; PASS+=("$1"); shift;;
  --name) NAME=$2; shift 2;; --initial-role) ROLE=$2; shift 2;; --self) SELF=$2; shift 2;; --peer) PEER=$2; shift 2;; --vip) VIP=$2; shift 2;; --vrid) VRID=$2; shift 2;;
  --priority) PRIORITY=$2; shift 2;; --bridge) BRIDGE=$2; shift 2;; --pair-bridge) PAIR_BRIDGE=$2; shift 2;; --gateway) GATEWAY=$2; shift 2;; --join) JOIN=$2; shift 2;; --update) UPDATE=$2; shift 2;;
  --pair-mac) PAIR_MAC=$2; PASS+=("$1" "$2"); shift 2;; --vmid) VMID=$2; PASS+=("$1" "$2"); shift 2;; --storage) STORAGE=$2; PASS+=("$1" "$2"); shift 2;; --snippets) SNIP=$2; PASS+=("$1" "$2"); shift 2;;
  --memory) MEMORY=$2; PASS+=("$1" "$2"); shift 2;; --cores) CORES=$2; PASS+=("$1" "$2"); shift 2;; --disk) DISK=$2; PASS+=("$1" "$2"); shift 2;; --stick-power) POWER+=("$2"); PASS+=("$1" "$2"); shift 2;; --no-stick-power) NOPOWER=1; PASS+=("$1"); shift;;
  --third-vote) THIRD=1; VOTE=$2; shift 2;; --third-vote-port) VOTE_PORT=$2; shift 2;; --third-vote-hostkey) VOTE_HOSTKEY=$2; shift 2;;
  --ssh-keys) KEYS=$2; PASS+=("$1" "$2"); shift 2;; --image-dir) IMAGE_DIR=$2; PASS+=("$1" "$2"); shift 2;; --usb-mapping) USBMAPS+=("$2"); PASS+=("$1" "$2"); shift 2;; --conf) EXTRA+=("$2"); PASS+=("$1" "$2"); shift 2;;
  *) echo "unknown option: $1 (./install.sh --help)" >&2; exit 2;; esac; done
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox node"
# (reached on a machine that is no node only when --help is some option's value, which keeps the hand-over above from happening)
command -v qm >/dev/null 2>&1 && command -v pvesh >/dev/null 2>&1 || die "no qm / pvesh here: this runs on a Proxmox VE node"
if [ $THIRD = 1 ]; then      # the cluster's third vote, not a VM: no sticks, no kit for a guest
  # shellcheck source=host/qdevice.sh
  . "$HERE/host/qdevice.sh"
fi
for f in guest/install.sh guest/sbin/zradio-serve guest/lib/zradio-common.sh guest/lib/zradio-usb-ids.py guest/lib/usb-annotations.json guest/units/zradio.target host/hook.sh; do [ -r "$KIT/$f" ] || die "the kit's $f is missing next to this script"; done
# The table of sticks the kit knows is not kept in git: it is built here, at every run, into the kit's own gen/ folder
# (the only place the kit writes what it generates), from Home Assistant's USB lists at the commit the kit pins and the
# kit's notes on each stick. The VM gets it inside the kit (step 3).
GEN="$KIT/gen"; TABLE="$GEN/usb-ids.json"
mkdir -p "$GEN" || die "cannot make $GEN (the kit's folder for what it generates)"
IDS_SAID=$(python3 "$KIT/guest/lib/zradio-usb-ids.py" --out "$TABLE" 2>&1) \
  || die "the table of the sticks the kit knows could not be built: $(printf '%s\n' "$IDS_SAID" | grep -m1 FAIL | sed 's/^FAIL  //'). It is built from Home Assistant's USB lists on GitHub: this node has to reach raw.githubusercontent.com"
TABLE_SAID=$(printf '%s\n' "$IDS_SAID" | sed -n 's/^usb-ids.json: //p')
bash "$KIT/guest/lib/zradio-kit-stamp.sh" "$KIT" || die "could not stamp the kit's version (guest/lib/zradio-kit-stamp.sh)"
KIT_VERSION=$(kv VERSION "$(cat "$GEN/kit-version")"); KIT_CONTENT=$(kv CONTENT "$(cat "$GEN/kit-version")")
if [ $STICKS = 1 ]; then
  echo "The sticks on $NODE that the kit knows (the VM itself finds out which is what):"
  show_sticks || { echo "      none. A stick the kit's table does not know can still be passed through: make a USB mapping for it and use --usb-mapping."; exit 1; }
  echo "The hub ports above each (for --stick-power, nearest first; uhubctl says which hubs switch their ports' power: ppps):"
  sticks_here | while read -r port _; do printf '      %-10s %s\n' "$port" "$(ports_above "$port")"; done
  exit 0
fi

VMS=$(vm_lines)

# A radio VM of the kit on this node already (and no --name for another one): this run updates it, and the pair's
# other VM, instead of building one. --update NAME says which, where there are several.
MINE=$(kit_vms here)
if [ -n "$UPDATE" ] || { [ -n "$MINE" ] && [ $NOUSB = 0 ] && { [ -z "$NAME" ] || printf '%s\n' "$MINE" | awk -v n="$NAME" '$2 == n { f = 1 } END { exit !f }'; }; }; then
  # shellcheck source=host/update.sh
  . "$HERE/host/update.sh"
else
  # shellcheck source=host/new-vm.sh
  . "$HERE/host/new-vm.sh"
fi
