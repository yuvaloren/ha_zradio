#!/usr/bin/env bash
# t-hook.sh — the radio VM's hookscript (host/hook.sh), as Proxmox runs it: zradio-hook.sh <vmid> <phase>.
# Real: the script. Fake: the node. Its USB tree is the reference pair's first node as its kernel logged it at boot
# (2026-11-18): a TI hub with two faces (1-3, USB 2; 2-4, USB 3), a Genesys hub in its port 2, the Z-Wave stick
# (10c4:ea70) and the Zigbee stick (10c4:ea60) in that. The kernel is `sleep`: at each one, what hangs off a port that
# is switched off leaves the bus, and what hangs off one that is on comes (back) after <dir>/appear seconds.
#   knobs, files in <dir>: appear (seconds, default 2) · stuck (the hub comes only after its port was off and on)
#   dead-<bus-port> (that stick never comes) · running (ids of the running VMs) · state (systemctl is-system-running)
. "$(dirname "$0")/lib.sh"
HOOK="$KIT/host/hook.sh"

world() { # world <dir> [dark]: the node, with zradio1 (100) on it; dark: the sticks' ports are off, as after a stop
  local d=$1
  rm -rf "$d"; mkdir -p "$d/bin" "$d/sys" "$d/snip" "$d/pve/nodes/nodea/qemu-server" "$d/sys/1-3:1.0/1-3-port2" "$d/sys/2-4:1.0/2-4-port2" "$d/sys/1-0:1.0/usb1-port4"
  : > "$d/calls"; : > "$d/journal"; : > "$d/running"
  usb() { mkdir -p "$d/sys/$1"; echo "$2" > "$d/sys/$1/idVendor"; echo "$3" > "$d/sys/$1/idProduct"; }
  usb usb1 1d6b 0002; usb 1-3 0451 8142; usb 2-4 0451 8140; usb 1-4 0557 9241
  for p in 1-3:1.0/1-3-port2 2-4:1.0/2-4-port2 1-0:1.0/usb1-port4; do echo 0 > "$d/sys/$p/disable"; done
  cat > "$d/bin/kernel" <<SH
#!/usr/bin/env bash
# one second of the fake kernel
d="$d"; usb() { mkdir -p "\$d/sys/\$1"; echo "\$2" > "\$d/sys/\$1/idVendor"; echo "\$3" > "\$d/sys/\$1/idProduct"; }
if [ "\$(cat "\$d/sys/1-3:1.0/1-3-port2/disable")" = 1 ]; then
  rm -rf "\$d/sys/1-3.2" "\$d/sys/1-3.2.1" "\$d/sys/1-3.2.4"; echo 0 > "\$d/on-for"; rm -f "\$d/stuck"
else
  n=\$(( \$(cat "\$d/on-for" 2>/dev/null || echo 0) + 1 )); echo \$n > "\$d/on-for"
  if [ ! -f "\$d/stuck" ] && [ \$n -ge "\$(cat "\$d/appear" 2>/dev/null || echo 2)" ]; then
    usb 1-3.2 05e3 0610
    [ -f "\$d/dead-1-3.2.1" ] || usb 1-3.2.1 10c4 ea70
    [ -f "\$d/dead-1-3.2.4" ] || usb 1-3.2.4 10c4 ea60
  fi
fi
SH
  chmod +x "$d/bin/kernel"
  fake "$d/bin" sleep "echo \"sleep \$*\" >> '$d/calls'; case \"\$1\" in 0.*) ;; *) i=0; while [ \$i -lt \"\$1\" ]; do '$d/bin/kernel'; i=\$((i + 1)); done;; esac"
  fake "$d/bin" hostname 'echo nodea'
  fake "$d/bin" logger "shift 2; [ \"\$1\" != -- ] || shift; echo \"\$*\" >> '$d/journal'"      # logger -t zradio -- <line>
  cat > "$d/bin/systemctl" <<SH
#!/usr/bin/env bash
case "\$1" in
  is-system-running) cat "$d/state" 2>/dev/null || echo running;;
  is-active) [ -e "$d/helper-active" ];;
  stop) echo "systemctl \$*" >> "$d/calls"; rm -f "$d/helper-active";;
esac
SH
  chmod +x "$d/bin/systemctl"
  fake "$d/bin" systemd-run "echo \"systemd-run \$*\" >> '$d/calls'; [ ! -e '$d/no-systemd-run' ] || exit 1; : > '$d/helper-active'"
  # qm status <id>; qm guest exec <id> --timeout 20 -- <command> <mode>: the guest's answer is <dir>/guest-<mode> (none: no answer)
  cat > "$d/bin/qm" <<SH
#!/usr/bin/env bash
echo "qm \$*" >> "$d/calls"
case "\$1" in
  status) grep -qx "\$2" "$d/running" && echo 'status: running' || echo 'status: stopped';;
  guest) m="\${*: -1}"; [ -f "$d/guest-\$m" ] || exit 1
    python3 -c 'import json, sys; print(json.dumps({"exitcode": 0, "exited": 1, "out-data": open(sys.argv[1]).read()}))' "$d/guest-\$m";;
esac
SH
  chmod +x "$d/bin/qm"
  fake "$d/bin" pvesh "echo \"pvesh \$*\" >> '$d/calls'; cat '$d/usbmap.json'"
  echo '[{"id":"zradio-10c4ea70","map":["node=nodea,id=10c4:ea70","node=nodeb,id=10c4:ea70,path=2-1"]},{"id":"zradio-10c4ea60","map":["node=nodea,id=10c4:ea60"]}]' > "$d/usbmap.json"
  printf '%s\n' "name: zradio1" "usb0: mapping=zradio-10c4ea70" "usb1: mapping=zradio-10c4ea60" "hookscript: local:snippets/zradio-hook.sh" "" "[before-update]" "usb2: host=0557:9241" > "$d/pve/nodes/nodea/qemu-server/100.conf"
  cp "$HOOK" "$d/snip/zradio-hook.sh"
  if [ "${2:-}" = dark ]; then echo 1 > "$d/sys/1-3:1.0/1-3-port2/disable"; echo 1 > "$d/sys/2-4:1.0/2-4-port2/disable"; else echo 99 > "$d/on-for"; fi
  "$d/bin/kernel"
}
power() { local d=$1; shift; printf '%s\n' "$@" > "$d/snip/zradio-hook-100.conf"; }      # power <dir> <the lines of zradio1's conf…>
hook() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VM_SYS="$d/sys" ZRADIO_VM_PVE="$d/pve" bash "$d/snip/zradio-hook.sh" "$@" > "$d/out" 2>&1; RC=$?; }
ports() { echo "$(cat "$1/sys/1-3:1.0/1-3-port2/disable")$(cat "$1/sys/2-4:1.0/2-4-port2/disable")"; }      # 00: both faces on, 11: both off
slept() { grep -c '^sleep 1$' "$1/calls"; }
export -f ports slept

echo "-- pre-start without stick power: the start waits for the sticks"
world "$T/a"; hook "$T/a" 100 pre-start
check "both sticks on the bus: exit 0 at once, no wait" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 0 ] && grep -q "the sticks are on this node.s USB (after 0 s)" "$1/out"' _ "$T/a" "$RC"
check "…and one line in the journal: ok, 0 s" bash -c 'grep -qx "event=hook result=ok vm=zradio1 phase=pre-start waited_s=0 cycled=no" "$1/journal"' _ "$T/a"
world "$T/b"; rm -rf "$T/b/sys/1-3.2" "$T/b/sys/1-3.2.1" "$T/b/sys/1-3.2.4"; echo 0 > "$T/b/on-for"; echo 19 > "$T/b/appear"; hook "$T/b" 100 pre-start
check "a hub that comes 19 s late (the reference pair's cold boot of 2026-11-09): the start waits for it, exit 0" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 19 ] && grep -q "waited_s=19 cycled=no" "$1/journal"' _ "$T/b" "$RC"
world "$T/c"; rm -rf "$T/c/sys/1-3.2.4"; : > "$T/c/dead-1-3.2.4"; power "$T/c" "WAIT=6"; hook "$T/c" 100 pre-start
check "a stick that never comes: refused after WAIT seconds, exit 1, and the stick is named" bash -c '[ "$2" = 1 ] && [ "$(slept "$1")" = 6 ] && grep -q "REFUSED: not on this node.s USB after 6 s: 10c4:ea60\. zradio1 names a stick through a USB mapping, and Proxmox starts no VM whose mapped stick is absent\. Is it plugged in" "$1/out" && ! grep -q "ea70" "$1/out"' _ "$T/c" "$RC"
check "…in the journal too" bash -c 'grep -qx "event=hook result=refused vm=zradio1 phase=pre-start waited_s=6 cycled=no missing=10c4:ea60" "$1/journal"' _ "$T/c"
check "…and no port was touched: there is no stick power here" bash -c '[ "$(ports "$1")" = 00 ]' _ "$T/c"
world "$T/d"; echo '[{"id":"zradio-10c4ea70","map":["node=nodea,id=10c4:ea70,path=1-4"]},{"id":"zradio-10c4ea60","map":["node=nodea,id=10c4:ea60"]}]' > "$T/d/usbmap.json"; power "$T/d" "WAIT=1"; hook "$T/d" 100 pre-start
check "a mapping that names a port: the stick has to be at that port, as Proxmox wants it" bash -c '[ "$2" = 1 ] && grep -q "10c4:ea70 at 1-4" "$1/out"' _ "$T/d" "$RC"
world "$T/e"; printf '%s\n' "name: plain" "net0: virtio,bridge=vmbr0" > "$T/e/pve/nodes/nodea/qemu-server/100.conf"; rm -rf "$T/e/sys/1-3.2.1"; hook "$T/e" 100 pre-start
check "a VM without a stick in its config: exit 0, nothing waited for" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 0 ]' _ "$T/e" "$RC"
world "$T/f"; printf '%s\n' "name: zradio1" "usb0: host=1-3.2.1" "usb1: host=0x10c4:0xea60" > "$T/f/pve/nodes/nodea/qemu-server/100.conf"; hook "$T/f" 100 pre-start
check "sticks named without a mapping (host=<bus-port>, host=<vid:pid>): waited for the same way" bash -c '[ "$2" = 0 ] && ! grep -q REFUSED "$1/out"' _ "$T/f" "$RC"
rm -rf "$T/f/sys/1-3.2.1"; : > "$T/f/dead-1-3.2.1"; power "$T/f" "WAIT=1"; hook "$T/f" 100 pre-start
check "…and one of them never comes: after WAIT the VM starts without it (Proxmox passes a stick named by host= through when it appears)" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 1 ] && grep -q "not on this node.s USB after 1 s: the device at 1-3.2.1\. zradio1 starts without" "$1/out" && ! grep -q REFUSED "$1/out"' _ "$T/f" "$RC"
check "…said in the journal: started-without, and what is missing" bash -c 'grep -qx "event=hook result=started-without vm=zradio1 phase=pre-start waited_s=1 cycled=no missing=the_device_at_1-3.2.1" "$1/journal"' _ "$T/f"

world "$T/f2"; echo '[]' > "$T/f2/usbmap.json"; rm -rf "$T/f2/sys/1-3.2.1"; hook "$T/f2" 100 pre-start
check "Proxmox names no device for the VM's mappings on this node: said (task log and journal), not waited for, and the start is left to Proxmox" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 0 ] && grep -q "the USB mapping zradio-10c4ea70 names nothing on this node" "$1/out" && grep -q "result=fail vm=zradio1 phase=pre-start unresolved=zradio-10c4ea60" "$1/journal"' _ "$T/f2" "$RC"

echo "-- pre-start with stick power: the ports are switched on, and off and on once for a hub that hangs"
world "$T/g" dark; power "$T/g" "POWER_PORTS=1-3:2 2-4:2"; hook "$T/g" 100 pre-start
check "the ports were off: both faces are switched on, the sticks come, exit 0" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && grep -q "waited_s=2 cycled=no" "$1/journal"' _ "$T/g" "$RC"
world "$T/h" dark; : > "$T/h/stuck"; power "$T/h" "POWER_PORTS=1-3:2 2-4:2" "CYCLE_AFTER=5" "WAIT=30"; hook "$T/h" 100 pre-start
check "a hub that does not come: after CYCLE_AFTER seconds the ports are switched off and on once, it comes, exit 0" bash -c '[ "$2" = 0 ] && grep -q "not on the USB after 5 s: 10c4:ea70, 10c4:ea60. The ports 1-3:2 2-4:2 are switched off and on once" "$1/out" && grep -q "waited_s=7 cycled=yes" "$1/journal" && [ "$(ports "$1")" = 00 ]' _ "$T/h" "$RC"
check "…off for 3 s in between" bash -c 'grep -qx "sleep 3" "$1/calls" && [ "$(grep -c "^sleep 3$" "$1/calls")" = 1 ]' _ "$T/h"
world "$T/i" dark; : > "$T/i/dead-1-3.2.1"; power "$T/i" "POWER_PORTS=1-3:2 2-4:2" "CYCLE_AFTER=3" "WAIT=9"; hook "$T/i" 100 pre-start
check "a dead stick: switched off and on once, refused after WAIT, the stick named, exit 1" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: not on this node.s USB after 9 s: 10c4:ea70 (ports 1-3:2 2-4:2, switched off and on once: yes)" "$1/out" && [ "$(grep -c "^sleep 3$" "$1/calls")" = 1 ]' _ "$T/i" "$RC"
check "…and the ports are off again: no stick stays powered without its VM" bash -c '[ "$(ports "$1")" = 11 ]' _ "$T/i"
world "$T/j"; power "$T/j" "POWER_PORTS=1-3:2 9-9:1"; hook "$T/j" 100 pre-start
check "a port of the conf that is not there (its hub is gone): said, and the start still goes by the sticks" bash -c '[ "$2" = 0 ] && grep -q "the port 9-9:1 has no switch here" "$1/out"' _ "$T/j" "$RC"
world "$T/k" dark; echo 1 > "$T/k/sys/1-0:1.0/usb1-port4/disable"; power "$T/k" "POWER_PORTS=1-3:2 2-4:2 1:4"; hook "$T/k" 100 pre-start
check "a port of a root hub (1:4): its switch is found too" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/sys/1-0:1.0/usb1-port4/disable")" = 0 ]' _ "$T/k" "$RC"

echo "-- two VMs on one stick"
other() { printf '%s\n' "name: $2" "${@:3}" > "$1/pve/nodes/nodea/qemu-server/9001.conf"; }     # other <dir> <name> <conf lines…>
world "$T/m" dark; power "$T/m" "POWER_PORTS=1-3:2 2-4:2"; echo 0 > "$T/m/sys/1-3:1.0/1-3-port2/disable"; echo 99 > "$T/m/on-for"; "$T/m/bin/kernel"
other "$T/m" drill "usb0: mapping=zradio-10c4ea70"; echo 9001 > "$T/m/running"; hook "$T/m" 100 pre-start
check "another VM runs on this node with one of the sticks: the start is refused at once, and it is named" bash -c '[ "$2" = 1 ] && [ "$(slept "$1")" = 0 ] && grep -q "REFUSED: drill runs on this node with one of this VM.s sticks" "$1/out" && grep -qx "event=hook result=refused vm=zradio1 phase=pre-start other=drill" "$1/journal"' _ "$T/m" "$RC"
check "…and no port was switched under it" bash -c '[ "$(ports "$1")" = 01 ]' _ "$T/m"
: > "$T/m/running"; hook "$T/m" 100 pre-start
check "that VM is stopped: it is in nobody's way" eq "$RC" 0
world "$T/n"; other "$T/n" kvm "usb0: host=1-4"; echo 9001 > "$T/n/running"; hook "$T/n" 100 pre-start
check "a running VM with another USB device (a keyboard, by its port): not in the way" eq "$RC" 0
other "$T/n" clone "usb0: host=1-3.2.4"; hook "$T/n" 100 pre-start
check "a running VM that names the stick by its port: refused" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: clone runs" "$1/out"' _ "$T/n" "$RC"

echo "-- post-stop: the ports go off, unless…"
world "$T/p"; power "$T/p" "POWER_PORTS=1-3:2 2-4:2"; hook "$T/p" 100 post-stop
check "both faces are switched off, exit 0, said in the journal" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 11 ] && grep -qx "event=hook result=ok vm=zradio1 phase=post-stop ports=off" "$1/journal"' _ "$T/p" "$RC"
world "$T/q"; power "$T/q" "POWER_PORTS=1-3:2 2-4:2"; echo stopping > "$T/q/state"; hook "$T/q" 100 post-stop
check "the node is shutting down: the ports stay on (the sticks are there at its boot)" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && grep -qx "event=hook result=left-on vm=zradio1 phase=post-stop why=node-stopping" "$1/journal"' _ "$T/q" "$RC"
world "$T/r"; power "$T/r" "POWER_PORTS=1-3:2 2-4:2"; other "$T/r" zradio1b "usb0: mapping=zradio-10c4ea60"; echo 9001 > "$T/r/running"; hook "$T/r" 100 post-stop
check "another running VM has one of the sticks (a backup that started a stopped copy and stops it again): the ports stay on" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && grep -q "result=left-on vm=zradio1 phase=post-stop other=zradio1b" "$1/journal"' _ "$T/r" "$RC"
world "$T/s"; hook "$T/s" 100 post-stop
check "no stick power: nothing is switched, and Proxmox is asked nothing" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && [ ! -s "$1/journal" ] && [ ! -s "$1/calls" ]' _ "$T/s" "$RC"
world "$T/t"; power "$T/t" "POWER_PORTS=1-3:2 9-9:1"; hook "$T/t" 100 post-stop
check "a port that cannot be switched: said in the journal, the others are off, and the stop is not failed over it" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/sys/1-3:1.0/1-3-port2/disable")" = 1 ] && grep -q "result=fail vm=zradio1 phase=post-stop" "$1/journal"' _ "$T/t" "$RC"

echo "-- the phases it has nothing to do in"
world "$T/u" dark; power "$T/u" "POWER_PORTS=1-3:2 2-4:2"
# shellcheck disable=SC2086  # no phase at all is one of the cases
for ph in pre-stop "" nonsense; do hook "$T/u" 100 $ph; [ "$RC" = 0 ] || break; done
check "pre-stop, no phase, an unknown one: exit 0, nothing read, nothing switched" bash -c '[ "$2" = 0 ] && [ ! -s "$1/calls" ] && [ "$(ports "$1")" = 11 ]' _ "$T/u" "$RC"
hook "$T/u" "" pre-start
check "no VM id: exit 0" eq "$RC" 0
echo "-- a start without the sticks (the kit's own lines, host=): never refused for a stick"
hostvm() { printf '%s\n' "name: zradio1" "usb0: host=10c4:ea70" "usb1: host=10c4:ea60" "hookscript: local:snippets/zradio-hook.sh" > "$1/pve/nodes/nodea/qemu-server/100.conf"; }
world "$T/v" dark; hostvm "$T/v"; : > "$T/v/dead-1-3.2.1"; power "$T/v" "POWER_PORTS=1-3:2 2-4:2" "CYCLE_AFTER=3" "WAIT=9"; hook "$T/v" 100 pre-start
check "a dead stick: the ports switched off and on once, and after WAIT the VM starts all the same, exit 0" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 9 ] && grep -q "zradio1 starts without" "$1/out" && grep -qx "event=hook result=started-without vm=zradio1 phase=pre-start waited_s=9 cycled=yes missing=10c4:ea70" "$1/journal"' _ "$T/v" "$RC"
check "…and the ports stay on: the stick is passed through when it comes" bash -c '[ "$(ports "$1")" = 00 ]' _ "$T/v"
world "$T/w"; hostvm "$T/w"; rm -rf "$T/w/sys/1-3.2" "$T/w/sys/1-3.2.1" "$T/w/sys/1-3.2.4"; echo 0 > "$T/w/on-for"; : > "$T/w/stuck"; hook "$T/w" 100 pre-start
check "no stick power and a hub that never comes: the wait is 60 s, then the VM starts without its sticks" bash -c '[ "$2" = 0 ] && [ "$(slept "$1")" = 60 ] && grep -q "result=started-without .*waited_s=60 cycled=no missing=10c4:ea70,_10c4:ea60" "$1/journal"' _ "$T/w" "$RC"
world "$T/x" dark; hostvm "$T/x"; power "$T/x" "POWER_PORTS=1-3:2 2-4:2"; echo 0 > "$T/x/sys/1-3:1.0/1-3-port2/disable"; echo 99 > "$T/x/on-for"; "$T/x/bin/kernel"
other "$T/x" drill "usb0: host=10c4:ea70"; echo 9001 > "$T/x/running"; hook "$T/x" 100 pre-start
check "another running VM with one of the sticks: still refused" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: drill runs" "$1/out"' _ "$T/x" "$RC"

echo "-- the helper: started with the VM, stopped with it"
world "$T/y"; hostvm "$T/y"; power "$T/y" "POWER_PORTS=1-3:2 2-4:2"; hook "$T/y" 100 post-start
check "post-start with stick power: the helper is started as a unit of its own, zradio-heal-<vmid>, running this script's heal" bash -c '[ "$2" = 0 ] && grep -q "^systemd-run --quiet --collect --unit zradio-heal-100 .*/snip/zradio-hook.sh 100 heal$" "$1/calls" && grep -qx "event=hook result=ok vm=zradio1 phase=post-start helper=zradio-heal-100" "$1/journal"' _ "$T/y" "$RC"
hook "$T/y" 100 post-start
check "…once: a second post-start finds it running" bash -c '[ "$(grep -c "^systemd-run" "$1/calls")" = 1 ]' _ "$T/y"
hook "$T/y" 100 post-stop
check "post-stop: the helper is stopped, and the ports go off" bash -c 'grep -qx "systemctl stop zradio-heal-100.service" "$1/calls" && [ "$(ports "$1")" = 11 ]' _ "$T/y"
world "$T/z"; hostvm "$T/z"; hook "$T/z" 100 post-start
check "post-start without stick power: no helper (it would have nothing to switch), nothing read" bash -c '[ "$2" = 0 ] && [ ! -s "$1/calls" ] && [ ! -s "$1/journal" ]' _ "$T/z" "$RC"
world "$T/z2"; hostvm "$T/z2"; power "$T/z2" "POWER_PORTS=1-3:2 2-4:2"; : > "$T/z2/no-systemd-run"; hook "$T/z2" 100 post-start
check "the helper does not start: said, and the start is not failed over it" bash -c '[ "$2" = 0 ] && grep -q "the helper zradio-heal-100 did not start" "$1/out" && grep -q "result=fail .*helper=not-started" "$1/journal"' _ "$T/z2" "$RC"

echo "-- the helper's look: the VM asks, the node switches its sticks' power off and on"
heal() { local d=$1; shift; ZRADIO_HOOK_RUN="$d/run" ZRADIO_HOOK_QEMU="$d/qrun" hook "$d" 100 "${1:-heal-once}"; }      # heal <dir> [phase]
asks() { echo "WANT stick=zwave since=1795000000" > "$1/guest-power-wanted"; : > "$1/guest-power-done"; }
helper() { world "$1"; hostvm "$1"; power "$1" "POWER_PORTS=1-3:2 2-4:2" "${@:2}"; echo 100 > "$1/running"; mkdir -p "$1/qrun"; echo $$ > "$1/qrun/100.pid"; }      # helper <dir> [conf lines…]: zradio1 runs (its QEMU's pid file: a process that lives, this one)
helper "$T/h1"; echo "NO" > "$T/h1/guest-power-wanted"; heal "$T/h1"
check "the VM does not ask: nothing is switched, nothing said" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && [ ! -s "$1/journal" ] && ! grep -q "^sleep" "$1/calls"' _ "$T/h1" "$RC"
helper "$T/h2"; heal "$T/h2"
check "the VM does not answer (its agent, or a kit without the question): nothing" bash -c '[ "$2" = 0 ] && [ "$(ports "$1")" = 00 ] && [ ! -s "$1/journal" ]' _ "$T/h2" "$RC"
helper "$T/h4"; asks "$T/h4"; heal "$T/h4"
check "it asks: both faces off for 3 s and on again, said, and the VM is told" bash -c 'grep -qx "sleep 3" "$1/calls" && [ "$(ports "$1")" = 00 ] && grep -q "^event=hook result=cycled vm=zradio1 phase=heal-once stick=zwave ports=1-3:2,2-4:2 cycles_24h=1 " "$1/journal" && grep -q "^qm guest exec 100 --timeout 20 -- /usr/local/sbin/zradio-serve power-done$" "$1/calls"' _ "$T/h4"
check "…the sticks really left the bus in between (the fake kernel saw the ports off)" bash -c '[ "$(cat "$1/on-for")" -le 3 ]' _ "$T/h4"
heal "$T/h4"
check "…a second look right after: not again (HEAL_GAP: the sticks are still on their way)" bash -c '[ "$(grep -c "result=cycled" "$1/journal")" = 1 ] && [ "$(grep -c "^sleep 3$" "$1/calls")" = 1 ]' _ "$T/h4"
helper "$T/h5" "HEAL_GAP=0" "HEAL_MAX=2"; asks "$T/h5"; heal "$T/h5"; heal "$T/h5"; heal "$T/h5"; heal "$T/h5"
check "HEAL_MAX cycles in 24 hours, then no more: capped, said once" bash -c '[ "$(grep -c "result=cycled" "$1/journal")" = 2 ] && [ "$(grep -c "result=capped" "$1/journal")" = 1 ] && grep -q "result=capped .*cycles_24h=2" "$1/journal"' _ "$T/h5"
helper "$T/h5b" "HEAL_GAP=0"; asks "$T/h5b"; for _ in 1 2 3 4 5; do heal "$T/h5b"; done
check "…three a day where the conf says nothing" bash -c '[ "$(grep -c "result=cycled" "$1/journal")" = 3 ]' _ "$T/h5b"
helper "$T/h5c"; asks "$T/h5c"; mkdir -p "$T/h5c/run"; echo $(( $(date +%s) - 899 )) > "$T/h5c/run/100.cycles"; heal "$T/h5c"
check "…and 15 minutes apart: a cycle 899 s ago holds the next one back" bash -c '! grep -q "result=cycled" "$1/journal" && [ "$(ports "$1")" = 00 ] && ! grep -q "^sleep 3" "$1/calls"' _ "$T/h5c"
echo $(( $(date +%s) - 901 )) > "$T/h5c/run/100.cycles"; heal "$T/h5c"
check "…one 901 s ago does not" bash -c 'grep -q "result=cycled .*cycles_24h=2" "$1/journal"' _ "$T/h5c"
helper "$T/h6" "HEAL_MAX=1"; asks "$T/h6"; mkdir -p "$T/h6/run"; echo $(( $(date +%s) - 90000 )) > "$T/h6/run/100.cycles"; heal "$T/h6"
check "a cycle more than 24 hours ago does not count" bash -c 'grep -q "result=cycled .*cycles_24h=1" "$1/journal"' _ "$T/h6"
helper "$T/h7"; asks "$T/h7"; other "$T/h7" drill "usb0: host=10c4:ea60"; echo 9001 >> "$T/h7/running"; heal "$T/h7"
check "another running VM of the node has one of the sticks: held, nothing switched under it" bash -c '[ "$(ports "$1")" = 00 ] && ! grep -q "^sleep 3" "$1/calls" && grep -q "result=held .*other=drill" "$1/journal"' _ "$T/h7"
# (the loop's own tests: `sleep` there ends the VM at the helper's pause, and ends a loop that will not end by itself)
looping() { fake "$1/bin" sleep "echo \"sleep \$*\" >> '$1/calls'; [ \"\$1\" != 300 ] || rm -f '$1/qrun/100.pid'; [ \$(grep -c '^sleep' '$1/calls') -lt 8 ] || kill \$PPID"; }
helper "$T/h8"; asks "$T/h8"; looping "$T/h8"; rm -f "$T/h8/qrun/100.pid"; heal "$T/h8" heal
check "the loop (heal): a VM that does not run (no pid file of its QEMU) ends it at once, and nobody is asked" bash -c '[ "$2" = 0 ] && ! grep -q "guest exec" "$1/calls"' _ "$T/h8" "$RC"
helper "$T/h8b"; asks "$T/h8b"; looping "$T/h8b"; echo 4194399 > "$T/h8b/qrun/100.pid"; heal "$T/h8b" heal      # (above the kernel's highest pid)
check "…and a pid file whose process is gone (a QEMU that died): the same" bash -c '[ "$2" = 0 ] && ! grep -q "guest exec" "$1/calls"' _ "$T/h8b" "$RC"
helper "$T/h9"; asks "$T/h9"; looping "$T/h9"; heal "$T/h9" heal
check "…while it runs: a look, 5 minutes, and again; it ends with the VM" bash -c '[ "$2" = 0 ] && [ "$(grep -c "power-wanted" "$1/calls")" = 1 ] && grep -qx "sleep 300" "$1/calls"' _ "$T/h9" "$RC"
helper "$T/h10"; echo "NO" > "$T/h10/guest-power-wanted"; looping "$T/h10"; heal "$T/h10" heal
check "…and a look that finds nothing to do costs the node one qm, the question to the VM: no qm status (every qm is a second of CPU)" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^qm " "$1/calls")" = 1 ] && grep -q "^qm guest exec 100 .*power-wanted" "$1/calls"' _ "$T/h10" "$RC"
finish
