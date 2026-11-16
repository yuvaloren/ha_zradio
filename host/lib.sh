# shellcheck shell=bash
# host/lib.sh — what install.sh and its parts (host/new-vm.sh, host/update.sh, host/qdevice.sh) share on the node:
# the output lines, the cluster's lists, a command in a VM through its guest agent, and the cluster's votes.
# Sourced by install.sh after it has set KIT, SYS, PVE, NODE, RUN and TABLE.

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
    rm -rf /opt/zradio/kit.previous; [ ! -d /opt/zradio/kit ] || mv /opt/zradio/kit /opt/zradio/kit.previous
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
    chunk=$(gx "$1" "$2" 20 "L=$at"'; f=/var/log/zradio-install.log; n=$(wc -l < $f); [ "$n" -le "$L" ] || sed -n "$((L + 1)),${n}p" $f; echo "@@at $n"; [ ! -f /root/zradio-install.rc ] || echo "@@rc $(cat /root/zradio-install.rc)"') || chunk=""
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
  gx "$1" "$2" 20 'cat /usr/local/lib/zradio/kit-version 2>/dev/null; v=$(sed -n "s/^VIP=//p" /etc/zradio/zradio.conf 2>/dev/null | tail -1)
    if [ -n "$v" ] && ip -o -4 addr show 2>/dev/null | grep -q " inet ${v%/*}/"; then echo SERVING=yes; else echo SERVING=no; fi'
}
kv() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | tail -1 | tr -dc 'A-Za-z0-9./@:_+-'; }     # kv <KEY> <text of KEY=value lines>
