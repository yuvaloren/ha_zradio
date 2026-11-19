#!/usr/bin/env bash
# host/hook.sh — a radio VM's hookscript on its Proxmox node. ./install.sh copies it into the node's snippets storage
# as zradio-hook.sh and attaches it (qm set <id> --hookscript); Proxmox runs it as `zradio-hook.sh <vmid> <phase>`.
#
#   pre-start   Gives the VM's USB sticks time to be on this node's bus, then lets the VM start, with them or without:
#               a stick that comes later is passed through by Proxmox when it appears (a stick named by host=, which is
#               how the kit names them), and the VM stays out of the pair until it has its sticks. With stick power
#               (below) the ports are switched on first; a stick still missing after CYCLE_AFTER seconds gets them
#               switched off and on once (a hub that hung needs that). After WAIT seconds the VM starts all the same.
#               REFUSED only: while another running VM of this node has one of the sticks; and after WAIT for a stick
#               the VM names through a USB mapping, because Proxmox itself refuses that start ("USB Mapping invalid").
#   post-start  With stick power: the helper is started (below).
#   post-stop   With stick power: the helper is stopped and the ports are switched off, so a stopped VM's sticks are
#               not on the air. Not while the node itself shuts down (the sticks are then there at its boot, with no
#               power-on to wait for), and not while another running VM of this node has one of the sticks.
#   any other phase of Proxmox: nothing.
#
# The helper (`zradio-hook.sh <vmid> heal`, a systemd unit zradio-heal-<vmid> that lives as long as the VM runs; no
# file of it is installed). A VM cannot switch its own sticks' power, so once a minute the helper asks it, through the
# guest agent, whether it wants that (`zradio-serve power-wanted`: a stick that stays silent or absent on a VM that
# does not serve). When it does, the ports are switched off for 3 s and on again, and the VM is told (`zradio-serve
# power-done`): at most HEAL_MAX times in 24 hours, HEAL_GAP seconds apart, never while another running VM of this
# node has one of the sticks. `heal-once` is one look.
#
# Stick power is per VM: zradio-hook-<vmid>.conf beside this script, KEY=value (./install.sh writes it):
#   POWER_PORTS=1-3:2 2-4:2      hub:port, as uhubctl names them. A USB 3 hub is two hubs: name the port on both.
#   WAIT=60                      seconds a start waits for the sticks
#   CYCLE_AFTER=25               seconds after which the ports are switched off and on
#   HEAL_MAX=3  HEAL_GAP=900     the helper's power cycles in 24 hours at most, and the seconds between two
# A port is switched through the kernel's file for it (…/<hub>-port<n>/disable, Linux 6.0 and later), the one uhubctl
# writes. Whether that cuts the stick's power or only disconnects it is the hub's doing; the kit cannot see which.
# Every run leaves a line in the node's journal (journalctl -t zradio): event=hook result=… vm=… phase=…
# Tests: tests/t-hook.sh. Env for them, as install.sh's: ZRADIO_VM_SYS, ZRADIO_VM_PVE; ZRADIO_HOOK_RUN.
set -uo pipefail
VMID=${1:-}; PHASE=${2:-}
case "$PHASE" in pre-start|post-start|post-stop|heal|heal-once) ;; *) exit 0;; esac
[[ "$VMID" =~ ^[0-9]+$ ]] || exit 0
SYS=${ZRADIO_VM_SYS:-/sys/bus/usb/devices}
CONFS="${ZRADIO_VM_PVE:-/etc/pve}/nodes/$(hostname -s)/qemu-server"
HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/zradio-hook-$VMID.conf"
HEAL_RUN=${ZRADIO_HOOK_RUN:-/run/zradio-hook}      # the helper's own notes (this boot's): the cycles it made, what it said
conf() { local v; v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1); echo "${v:-$2}"; }      # conf <KEY> <default>
num() { local v; v=$(conf "$1" "$2"); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "$2"; }         # num <KEY> <default>
POWER_PORTS=$(conf POWER_PORTS ""); WAIT=$(num WAIT 60); CYCLE_AFTER=$(num CYCLE_AFTER 25)
HEAL_MAX=$(num HEAL_MAX 3); HEAL_GAP=$(num HEAL_GAP 900); HEAL_EVERY=$(num HEAL_EVERY 60)
vm_name() { local n; n=$(sed -n '/^\[/q; s/^name: *//p' "$CONFS/$1.conf" 2>/dev/null | head -1); echo "${n:-VM $1}"; }
[ "$PHASE" = pre-start ] || [ -n "$POWER_PORTS" ] || exit 0      # without stick power only a start has something to do
NAME=$(vm_name "$VMID")
UNIT="zradio-heal-$VMID"
say() { echo "zradio-hook: $NAME, $PHASE: $*" >&2; }                      # the task's log
note() { logger -t zradio -- "event=hook result=$1 vm=$NAME phase=$PHASE ${*:2}" 2>/dev/null || true; }   # the journal

# The cluster's USB mappings for this node, "<mapping> <vid:pid> <bus-port or ->" each. Read once: pvesh takes a second.
MAPS=$(pvesh get /cluster/mapping/usb --output-format json 2>/dev/null | python3 -c '
import json, sys
try: maps = json.load(sys.stdin)
except ValueError: maps = []
for m in maps:
    for e in m.get("map", []):
        f = dict(x.split("=", 1) for x in e.split(",") if "=" in x)
        if f.get("node") == sys.argv[1]: print(m["id"], f.get("id", "-").lower(), f.get("path", "-"))' "$(hostname -s)")
usb_lines() { sed -n '/^\[/q; /^usb[0-9]*:/p' "$CONFS/$1.conf" 2>/dev/null; }      # the current config, not its snapshots
devices_of() { # devices_of <vmid>: what its usb lines name on this node, "<vid:pid or -> <bus-port or ->" each
  local line v
  while read -r line; do
    case "$line" in
      *mapping=*) v=${line##*mapping=}; v=${v%%,*}; printf '%s\n' "$MAPS" | awk -v m="$v" '$1 == m { print $2, $3 }';;
      *host=*) v=${line##*host=}; v=${v%%,*}; v=${v//0x/}; if [[ "$v" == *:* ]]; then echo "${v,,} -"; else echo "- $v"; fi;;
    esac
  done < <(usb_lines "$1")
}
where() { # where <vid:pid or -> <bus-port or ->: "<bus-port> <vid:pid>" of that device on the bus; 1 when it is not there
  local d id
  for d in "$SYS"/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$2" = - ] || [ "${d##*/}" = "$2" ] || continue
    id="$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)"; id=${id,,}
    [ "$1" = - ] || [ "$id" = "$1" ] || continue
    echo "${d##*/} $id"; return 0
  done
  return 1
}
DEVS=$(devices_of "$VMID")
all_there() { # 0 when every stick of this VM is on the bus; else 1, and what is missing is printed
  local id path out=""
  while read -r id path; do
    [ -z "$id" ] || where "$id" "$path" >/dev/null || out="$out${out:+, }$([ "$id" = - ] && echo "the device at $path" || echo "$id$([ "$path" = - ] || echo " at $path")")"
  done <<< "$DEVS"
  [ -z "$out" ] || { echo "$out"; return 1; }
}
other_vm() { # another VM of this node that runs and has one of this VM's sticks: its name is printed
  local f id oid opath at aid mid mpath
  for f in "$CONFS"/*.conf; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .conf); [ "$id" != "$VMID" ] || continue
    while read -r oid opath; do
      # a running VM's stick is on the bus: where it is and what it is are read there, and compared with this VM's lines
      [ -n "$oid" ] && read -r at aid <<< "$(where "$oid" "$opath")" && [ -n "$at" ] || continue
      while read -r mid mpath; do
        [ -n "$mid" ] || continue
        { [ "$mid" = - ] || [ "$mid" = "$aid" ]; } && { [ "$mpath" = - ] || [ "$mpath" = "$at" ]; } || continue
        case "$(qm status "$id" 2>/dev/null)" in *running*) vm_name "$id"; return 0;; esac
      done <<< "$DEVS"
    done <<< "$(devices_of "$id")"
  done
  return 1
}
port_file() { # port_file <hub:port>: the kernel's switch for that port; 1 when there is none
  local h=${1%:*} p=${1##*:}
  if [[ "$h" == *-* ]]; then set -- "$SYS/$h":*/"$h-port$p"/disable; else set -- "$SYS/$h-0":*/"usb$h-port$p"/disable; fi
  [ -e "$1" ] && echo "$1"
}
power() { # power on|off: every port of POWER_PORTS, where it is not that way already; 1 when one could not be switched
  local want=0 p f rc=0
  [ "$1" = on ] || want=1
  for p in $POWER_PORTS; do
    f=$(port_file "$p") || { say "the port $p has no switch here (no $SYS/…-port${p##*:}/disable: a kernel before 6.0, or its hub is gone)"; rc=1; continue; }
    [ "$(cat "$f" 2>/dev/null)" = "$want" ] || echo "$want" 2>/dev/null > "$f" || { say "the port $p could not be switched $1 ($f)"; rc=1; }
  done
  [ "$1" = on ] || sleep 0.2      # a USB 3 hub takes a moment to switch off (uhubctl waits 150 ms)
  return $rc
}
in_vm() { # in_vm <words of a command…>: its stdout, through the guest agent; 1 when it did not end with 0 in 20 s
  qm guest exec "$VMID" --timeout 20 -- "$@" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except ValueError: sys.exit(1)
if d.get("exitcode") != 0: sys.exit(1)
sys.stdout.write(d.get("out-data", ""))'
}
heal_once() { # one look of the helper: does the VM want its sticks' power switched off and on, and may it be done?
  local out want kind since now last n o seen="$HEAL_RUN/$VMID.said" log="$HEAL_RUN/$VMID.cycles"
  out=$(in_vm /usr/local/sbin/zradio-serve power-wanted) || return 0      # no answer, or a kit in the VM without the question
  want=$(printf '%s\n' "$out" | sed -n 's/^WANT //p' | head -1)
  [ -n "$want" ] || return 0
  kind=$(printf '%s\n' "$want" | sed -n 's/.*stick=\([a-z,]*\).*/\1/p'); since=$(printf '%s\n' "$want" | sed -n 's/.*since=\([0-9]*\).*/\1/p')
  mkdir -p "$HEAL_RUN" 2>/dev/null || return 0
  once() { [ "$(cat "$seen" 2>/dev/null)" = "$1 $since" ] && return 1; echo "$1 $since" > "$seen"; }   # one line per request and reason
  if o=$(other_vm); then ! once other || note held "stick=${kind:-?} other=$o — $o runs on this node with one of these sticks"; return 0; fi
  now=$(date +%s); last=$(tail -n 1 "$log" 2>/dev/null); n=$(awk -v now="$now" 'now - $1 < 86400' "$log" 2>/dev/null | grep -c .)
  if [ "$n" -ge "$HEAL_MAX" ]; then ! once capped || note capped "stick=${kind:-?} cycles_24h=$n — the limit (HEAL_MAX=$HEAL_MAX): not switched again. The stick wants a look"; return 0; fi
  [[ "$last" =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$HEAL_GAP" ] && return 0      # the last cycle's sticks are still on their way
  echo "$now" >> "$log"
  if power off; then sleep 3; power on; fi
  note cycled "stick=${kind:-?} ports=${POWER_PORTS// /,} cycles_24h=$((n + 1)) — off for 3 s and on again, because $NAME asked"
  in_vm /usr/local/sbin/zradio-serve power-done >/dev/null || true
  return 0
}

case "$PHASE" in
  pre-start)
    # a mapping of the VM that has no entry for this node in Proxmox's answer: not waited for, and said. Proxmox decides.
    for m in $(sed -n '/^\[/q; s/^usb[0-9]*:.*mapping=\([^,]*\).*/\1/p' "$CONFS/$VMID.conf" 2>/dev/null); do
      printf '%s\n' "$MAPS" | awk -v m="$m" '$1 == m { f = 1 } END { exit !f }' || { say "the USB mapping $m names nothing on this node (pvesh get /cluster/mapping/usb): not waited for"; note fail "unresolved=$m"; }
    done
    [ -n "$DEVS" ] || exit 0          # no stick in its config: nothing to wait for
    if o=$(other_vm); then
      say "REFUSED: $o runs on this node with one of this VM's sticks. Two VMs on one stick: stop $o first"
      note refused "other=$o"; exit 1
    fi
    [ -z "$POWER_PORTS" ] || power on
    t=0; cycled=no
    until m=$(all_there); do
      if [ "$t" -ge "$WAIT" ]; then
        if usb_lines "$VMID" | grep -q 'mapping='; then      # Proxmox checks a mapping itself and would end this start
          [ -z "$POWER_PORTS" ] || power off
          say "REFUSED: not on this node's USB after $WAIT s: $m$([ -n "$POWER_PORTS" ] && echo " (ports $POWER_PORTS, switched off and on once: $cycled)"). $NAME names a stick through a USB mapping, and Proxmox starts no VM whose mapped stick is absent. Is it plugged in? lsusb on the node; then qm start $VMID. The kit's ./install.sh on this node, with $NAME stopped, names its sticks so that it starts without them"
          note refused "waited_s=$t cycled=$cycled missing=${m// /_}"; exit 1
        fi
        say "not on this node's USB after $WAIT s: $m$([ -n "$POWER_PORTS" ] && echo " (ports $POWER_PORTS, switched off and on once: $cycled)"). $NAME starts without: Proxmox passes a stick through when it appears, and until then $NAME stays out of the pair"
        note started-without "waited_s=$t cycled=$cycled missing=${m// /_}"; exit 0
      fi
      if [ -n "$POWER_PORTS" ] && [ $cycled = no ] && [ "$t" -ge "$CYCLE_AFTER" ]; then
        say "not on the USB after $t s: $m. The ports $POWER_PORTS are switched off and on once"
        power off; sleep 3; power on; cycled=yes
      fi
      sleep 1; t=$((t + 1))
    done
    say "the sticks are on this node's USB (after $t s$([ $cycled = no ] || echo ", and the ports switched off and on"))"
    note ok "waited_s=$t cycled=$cycled"
    exit 0;;
  post-start)
    if systemctl is-active --quiet "$UNIT.service" 2>/dev/null; then exit 0; fi
    if systemd-run --quiet --collect --unit "$UNIT" --description "zradio: $NAME's sticks, their power switched when it asks (ha_zradio)" \
         -p Restart=on-failure -p RestartSec=60 "$HERE/$(basename "$0")" "$VMID" heal 2>/dev/null; then note ok "helper=$UNIT"
    else say "the helper $UNIT did not start (systemd-run): $NAME's sticks are not power-cycled when it asks"; note fail "helper=not-started"; fi
    exit 0;;                          # a start is never failed over the helper
  heal)
    while :; do
      case "$(qm status "$VMID" 2>/dev/null)" in *running*) ;; *) exit 0;; esac
      heal_once
      sleep "$HEAL_EVERY"
    done;;
  heal-once) heal_once; exit 0;;
  post-stop)
    systemctl stop "$UNIT.service" 2>/dev/null || true
    if [ "$(systemctl is-system-running 2>/dev/null)" = stopping ]; then
      say "the ports $POWER_PORTS stay on: the node is shutting down"; note left-on "why=node-stopping"
    elif o=$(other_vm); then
      say "the ports $POWER_PORTS stay on: $o runs on this node with one of these sticks"; note left-on "other=$o"
    elif power off; then say "the ports $POWER_PORTS are off"; note ok "ports=off"
    else note fail "ports=not-switched"; fi
    exit 0;;                          # a stop is never failed over a port
esac
