#!/usr/bin/env bash
# t-serve.sh — the pair's role pieces (guest/sbin: zradio-serve, zradio-notify, zradio-render + keepalived.conf.tmpl)
# against fakes: systemctl (ser2net's state in a file; start/stop/is-active, recorded), logger (the journal lines), id
# (root), sleep (no wait), ip (recorded: nothing here may touch an address), and zradio-probe.py as a python stub that
# prints the lines and JSON keys the real probe printed on the reference sticks. Nothing here reaches a stick.
. "$(dirname "$0")/lib.sh"
SERVE="$KIT/guest/sbin/zradio-serve"; NOTIFY="$KIT/guest/sbin/zradio-notify"; RENDER="$KIT/guest/sbin/zradio-render"

host() { # host <dir> [ser2net: 0|1] [rf: ok|fail|ok-on-try-N] [zigbee state after reset: 0|9|fail]
  local d=$1 s=${2:-0} rf=${3:-ok} zb=${4:-0}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/dev" "$d/run"; : > "$d/calls"; : > "$d/journal"
  echo "$s" > "$d/ser2net"; echo "$rf" > "$d/rf"; echo "$zb" > "$d/zb"; echo 0 > "$d/rf-tries"
  : > "$d/dev/zwave"; : > "$d/dev/zigbee"
  printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "$d/radios.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" sleep ':'
  fake "$d/bin" ip "$rec; exit 0"
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  fake "$d/bin" systemctl "case \"\$1\" in
    is-active) [ \"\$(cat '$d/ser2net')\" = 1 ];;
    start) $rec; [ -f '$d/nostart' ] && exit 1; [ \"\${*: -1}\" = ser2net ] && echo 1 > '$d/ser2net'; exit 0;;
    stop)  $rec; [ -f '$d/nostop' ] && exit 1; [ \"\${*: -1}\" = ser2net ] && echo 0 > '$d/ser2net'; exit 0;;
    *) $rec; exit 9;; esac"
  cat > "$d/probe.py" <<EOF
import json, sys
open("$d/calls", "a").write("zradio-probe.py " + " ".join(sys.argv[1:]) + "\\n")
rf = open("$d/rf").read().strip(); zb = open("$d/zb").read().strip()
out = {}
if "--zwave" in sys.argv:
    if "--rf-receive" in sys.argv:
        n = int(open("$d/rf-tries").read()) + 1; open("$d/rf-tries", "w").write(str(n))
        answers = rf == "ok" or (rf.startswith("ok-on-try-") and n >= int(rf.rsplit("-", 1)[1]))
        if not answers:
            print("   FAIL  Z-Wave on /dev/zradio-zwave: SetRFReceiveMode(0): no answer (CAN; CAN)", file=sys.stderr); sys.exit(1)
        m = sys.argv[sys.argv.index("--rf-receive") + 1].upper()
        print("   NOTE  Z-Wave: RF receive mode set %s first (SetRFReceiveMode: success)" % m, file=sys.stderr)
        print("   NOTE  Z-Wave: RF receive mode %s (SetRFReceiveMode answered success)" % m, file=sys.stderr)
    print("   OK    Z-Wave on /dev/zradio-zwave: home ID 3517100996 (0xd1a2b3c4), 49 node(s)", file=sys.stderr)
    out["zwave"] = {"ok": True, "home_id_hex": "0xd1a2b3c4", "node_count": 49}
if "--zigbee" in sys.argv:
    if "--zigbee-reset" in sys.argv and zb == "fail":
        print("   FAIL  Zigbee on /dev/zradio-zigbee: SYS_RESET_REQ sent, no SYS_RESET_IND within 30 s", file=sys.stderr); sys.exit(1)
    import os
    st = int(zb) if "--zigbee-reset" in sys.argv else (int(open("$d/zb-ro").read()) if os.path.exists("$d/zb-ro") else 9)
    names = {0: "InitializedNotStarted", 9: "StartedAsCoordinator"}
    print("   OK    Zigbee on /dev/zradio-zigbee: IEEE 00:12:4b:00:aa:bb:cc:dd, state %s (%d)" % (names[st], st), file=sys.stderr)
    out["zigbee"] = {"ok": True, "ieee": "00:12:4b:00:aa:bb:cc:dd", "device_state": st, "device_state_name": names[st]}
print(json.dumps(out))
EOF
}
serve() { local d=$1; shift
  PATH="$d/bin:$PATH" ZRADIO_SERVE_PROBE="$d/probe.py" ZRADIO_SERVE_ZWAVE_TTY="$d/dev/zwave" ZRADIO_SERVE_ZIGBEE_TTY="$d/dev/zigbee" \
    ZRADIO_SERVE_RUN="$d/run" ZRADIO_SERVE_STATE="$d/state" ZRADIO_RADIOS="$d/radios.conf" bash "$SERVE" "$@" > "$d/out" 2>&1; RC=$?; }
calls() { tr '\n' ';' < "$1/calls"; }

echo "-- up: the receiver on, then ser2net; the address is never this script's"
host "$T/u"; serve "$T/u" up
check "exit 0" eq "$RC" 0
check "the receiver first, ser2net second, nothing else" eq "$(calls "$T/u")" "zradio-probe.py --zwave $T/u/dev/zwave --rf-receive on --json;systemctl start ser2net;"
check "the line for ops" has "$T/u/journal" "-t zradio event=serve result=up the Z-Wave receiver is on and ser2net is started"
check "no failed marker" bash -c '[ ! -e "$1/run/serve-failed" ]' _ "$T/u"
check "no ip call (keepalived owns 10.20.30.50)" hasnt "$T/u/calls" "ip "
host "$T/u2" 1; serve "$T/u2" up
check "already serving: exit 0, no stick touched (the tty is ser2net's), no start" bash -c '[ "$2" = 0 ] && [ ! -s "$1/calls" ] && grep -q "result=up-already" "$1/journal"' _ "$T/u2" "$RC"
host "$T/u3" 0 ok-on-try-3; serve "$T/u3" up
check "CAN twice after power-on, an answer at the third try: exit 0, three receiver calls, then ser2net" bash -c '[ "$2" = 0 ] && [ "$(grep -c "rf-receive on" "$1/calls")" = 3 ] && [ "$(tail -1 "$1/calls")" = "systemctl start ser2net" ]' _ "$T/u3" "$RC"
host "$T/u4" 0 fail; serve "$T/u4" up
check "the receiver never answers: exit 1, four tries, ser2net NOT started, the marker, the line" bash -c '[ "$2" = 1 ] && [ "$(grep -c "rf-receive on" "$1/calls")" = 4 ] && ! grep -q "systemctl start" "$1/calls" && [ -e "$1/run/serve-failed" ] && grep -q "result=failed step=zwave-receiver" "$1/journal"' _ "$T/u4" "$RC"
host "$T/u5"; rm -f "$T/u5/dev/zigbee"; serve "$T/u5" up
check "a tty missing: exit 1, no stick call, no start, the marker" bash -c '[ "$2" = 1 ] && [ ! -s "$1/calls" ] && [ -e "$1/run/serve-failed" ] && grep -q "result=failed step=tty" "$1/journal"' _ "$T/u5" "$RC"
host "$T/u6"; touch "$T/u6/nostart"; serve "$T/u6" up
check "ser2net does not start: exit 1, the marker, the line" bash -c '[ "$2" = 1 ] && [ -e "$1/run/serve-failed" ] && grep -q "result=failed step=ser2net" "$1/journal"' _ "$T/u6" "$RC"
check "…and no serving turn is left behind (it is written before the ports open, and taken back)" bash -c '[ ! -e "$1/run/turn" ]' _ "$T/u6"
host "$T/u7"; : > "$T/u7/run/serve-failed"; serve "$T/u7" up
check "a clean up clears an older failed marker" bash -c '[ "$2" = 0 ] && [ ! -e "$1/run/serve-failed" ]' _ "$T/u7" "$RC"

echo "-- down: ser2net stopped, then the receiver off, then the coordinator reset"
host "$T/d" 1; serve "$T/d" down
check "exit 0" eq "$RC" 0
check "the order: stop, receiver off, coordinator reset" eq "$(calls "$T/d")" "systemctl stop ser2net;zradio-probe.py --zwave $T/d/dev/zwave --rf-receive off --json;zradio-probe.py --zigbee $T/d/dev/zigbee --zigbee-reset --json;"
check "the line for ops" has "$T/d/journal" "event=serve result=down ser2net is stopped, the Z-Wave receiver is off, the coordinator is reset"
host "$T/d2" 0; serve "$T/d2" down
check "already standing by (boot: zradio-quiet): no stop call, both sticks still silenced, exit 0" bash -c '[ "$2" = 0 ] && ! grep -q "systemctl stop" "$1/calls" && grep -q "rf-receive off" "$1/calls" && grep -q "zigbee-reset" "$1/calls"' _ "$T/d2" "$RC"
host "$T/d3" 1 ok 9; serve "$T/d3" down
check "the coordinator runs the network after the reset (state 9): exit 1, said loudly" bash -c '[ "$2" = 1 ] && grep -q "result=loud step=zigbee — the coordinator is in state StartedAsCoordinator (9)" "$1/journal" && ! grep -q "result=down" "$1/journal"' _ "$T/d3" "$RC"
host "$T/d4" 1 fail 0; serve "$T/d4" down
check "the receiver will not switch off: exit 1, loud, and the coordinator is still reset" bash -c '[ "$2" = 1 ] && grep -q "result=loud step=zwave-receiver" "$1/journal" && grep -q "zigbee-reset" "$1/calls"' _ "$T/d4" "$RC"
host "$T/d5" 1; touch "$T/d5/nostop"; serve "$T/d5" down
check "ser2net will not stop: exit 1, loud, no stick call (the ttys are still ser2net's)" bash -c '[ "$2" = 1 ] && grep -q "result=loud step=ser2net" "$1/journal" && ! grep -q "zradio-probe.py" "$1/calls"' _ "$T/d5" "$RC"
host "$T/d6" 1 ok fail; serve "$T/d6" down
check "the coordinator reset gets no answer: exit 1, loud" bash -c '[ "$2" = 1 ] && grep -q "result=loud step=zigbee — the coordinator reset did not answer" "$1/journal"' _ "$T/d6" "$RC"
host "$T/d7" 1; rm -f "$T/d7/dev/zwave"; serve "$T/d7" down
check "a stick that is gone is skipped, the other is silenced: exit 0" bash -c '[ "$2" = 0 ] && ! grep -q "rf-receive" "$1/calls" && grep -q "zigbee-reset" "$1/calls"' _ "$T/d7" "$RC"

echo "-- check: keepalived's health script"
host "$T/c"; serve "$T/c" check
check "both ttys, no marker: 0" eq "$RC" 0
check "check touches nothing and logs nothing" bash -c '[ ! -s "$1/calls" ] && [ ! -s "$1/journal" ]' _ "$T/c"
rm -f "$T/c/dev/zwave"; serve "$T/c" check
check "a tty gone: 1 (the address goes to the peer)" eq "$RC" 1
host "$T/c2"; : > "$T/c2/run/applying"; serve "$T/c2" check
check "a synced image is being written: 1" eq "$RC" 1
host "$T/c3"; : > "$T/c3/run/serve-failed"; serve "$T/c3" check
check "up failed just now: 1 (held out)" eq "$RC" 1
touch -d '10 minutes ago' "$T/c3/run/serve-failed"; serve "$T/c3" check
check "up failed 10 min ago (hold 300 s): 0 again" eq "$RC" 0
serve "$T/c3" status
check "status names the role, the ttys and the marker" bash -c 'grep -q "ser2net: not active (standby)" "$1/out" && grep -q "marker: .*serve-failed" "$1/out" && [ "$(grep -c "present" "$1/out")" = 2 ]' _ "$T/c3"
serve "$T/c3" bogus
check "an unknown verb: exit 2" eq "$RC" 2

echo "-- zradio-notify: keepalived's states become systemd jobs, nothing else"
notify() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_NOTIFY_RUN="$d/run" ZRADIO_NOTIFY_STATE="$d/state" bash "$NOTIFY" "$@" > "$d/out" 2>&1; RC=$?; }
host "$T/n"; notify "$T/n" INSTANCE RADIO MASTER 100
check "MASTER: start --no-block zradio-serve.service" eq "$(calls "$T/n")" "systemctl start --no-block zradio-serve.service;"
check "the role is recorded, the line is logged" bash -c 'grep -q "^MASTER 20..-..-..T..:..:..Z priority=100$" "$1/run/role" && grep -q "event=role state=MASTER instance=RADIO priority=100" "$1/journal"' _ "$T/n"
check "…and zradio-gate is told that the role changed (gate-kick)" bash -c '[ -e "$1/run/gate-kick" ]' _ "$T/n"
for st in FAULT STOP; do
  host "$T/n-$st"; notify "$T/n-$st" INSTANCE RADIO "$st" 100
  check "$st: stop --no-block zradio-serve.service" eq "$(calls "$T/n-$st")" "systemctl stop --no-block zradio-serve.service;"
done
host "$T/n-BACKUP"; notify "$T/n-BACKUP" INSTANCE RADIO BACKUP 100
check "BACKUP: stop the serving, then hush the standby's sticks (a stick back after a FAULT listens)" eq "$(calls "$T/n-BACKUP")" "systemctl stop --no-block zradio-serve.service;systemctl start --no-block zradio-hush.service;"
for st in FAULT STOP; do
  host "$T/r-$st"; mkdir -p "$T/r-$st/state"; echo "term=4 used=yes" > "$T/r-$st/state/version"; notify "$T/r-$st" INSTANCE RADIO MASTER 100; notify "$T/r-$st" INSTANCE RADIO "$st" 100
  check "MASTER -> $st: this VM gave the radios up — its version no longer claims the copy in use, said once" bash -c '[ "$(cat "$1/state/version")" = "term=4 used=no" ] && [ "$(grep -c "event=version result=released term=4 used=no" "$1/journal")" = 1 ]' _ "$T/r-$st"
done
notify "$T/r-STOP" INSTANCE RADIO STOP 100
check "a second STOP (keepalived's own and the unit's ExecStopPost): nothing more" eq "$(grep -c "result=released" "$T/r-STOP/journal")" 1
host "$T/r2"; mkdir -p "$T/r2/state"; echo "term=4 used=yes" > "$T/r2/state/version"; notify "$T/r2" INSTANCE RADIO MASTER 100; notify "$T/r2" INSTANCE RADIO BACKUP 100
check "MASTER -> BACKUP (displaced by the other MASTER when a cut link heals): the claim is KEPT" eq "$(cat "$T/r2/state/version")" "term=4 used=yes"
host "$T/r3"; mkdir -p "$T/r3/state"; echo "term=4 used=yes" > "$T/r3/state/version"; notify "$T/r3" INSTANCE RADIO FAULT 100; notify "$T/r3" INSTANCE RADIO BACKUP 100
check "a boot (FAULT, then BACKUP, never MASTER): the claim of the VM that died serving is KEPT for the comparison" eq "$(cat "$T/r3/state/version")" "term=4 used=yes"
host "$T/n2"; notify "$T/n2" INSTANCE RADIO DELETED 100
check "an unknown state: exit 2, no systemd job, said in the journal" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ] && grep -q "event=role result=ignored state=DELETED" "$1/journal"' _ "$T/n2" "$RC"
host "$T/n3"; notify "$T/n3"
check "no arguments: exit 2, no systemd job" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/n3" "$RC"

echo "-- zradio-render: keepalived.conf from the conf; any network, the interface found by the address it holds"
conf() { # conf <dir> <lines…>: a conf, and a fake `ip` on which eth1 holds 10.20.30.6 and ens19 holds 192.168.7.21
  local d=$1; shift; rm -rf "$d"; mkdir -p "$d/bin"; printf '%s\n' "$@" > "$d/zradio.conf"
  fake "$d/bin" ip 'printf "1: lo    inet 127.0.0.1/8 scope host lo\\n2: eth0    inet 192.168.1.44/24 brd 192.168.1.255 scope global eth0\\n3: eth1    inet 10.20.30.6/24 brd 10.20.30.255 scope global eth1\\n3: eth1    inet 10.20.30.50/24 scope global secondary eth1\\n4: ens19    inet 192.168.7.21/22 scope global ens19\\n"'
}
render() { local d=$1; PATH="$d/bin:$PATH" ZRADIO_CONF="$d/zradio.conf" bash "$RENDER" > "$d/out" 2> "$d/err"; RC=$?; }
conf "$T/r" "# radio2" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 IFACE=
render "$T/r"
check "exit 0" eq "$RC" 0
for want in "    router_id radio2" "    state BACKUP" "    nopreempt" "    interface eth1" "    virtual_router_id 50" "    priority 100" "    unicast_src_ip 10.20.30.6" "        10.20.30.5" "        10.20.30.50/24 dev eth1" '    script "/usr/local/sbin/zradio-serve check"' '    notify "/usr/local/sbin/zradio-notify"'; do
  check "rendered: $(printf '%s' "$want" | sed 's/^ *//')" bash -c 'grep -qxF -- "$2" "$1"' _ "$T/r/out" "$want"
done
check "the interface is the one that holds SELF (eth1, not eth0)" hasnt "$T/r/out" "eth0"
check "no placeholder left" bash -c '! grep -q "@[A-Z]*@" "$1"' _ "$T/r/out"
check "braces balance" eq "$(grep -o '{' "$T/r/out" | wc -l | tr -d ' ')" "$(grep -o '}' "$T/r/out" | wc -l | tr -d ' ')"
conf "$T/r2" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.60/24 VRID=60 PRIORITY=100 IFACE=eth9
render "$T/r2"
check "another address and VRID, a named interface: rendered as given, the first address appears nowhere" bash -c '[ "$2" = 0 ] && grep -qxF "        10.20.30.60/24 dev eth9" "$1" && grep -qxF "    virtual_router_id 60" "$1" && ! grep -q "10\.20\.30\.50" "$1"' _ "$T/r2/out" "$RC"
conf "$T/r3" NAME=zr-b SELF=192.168.7.21 PEER=192.168.7.20 VIP=192.168.7.250/22 VRID=7 PRIORITY=90 ZWAVE_PORT=7001 ZIGBEE_PORT=7002 SYNC_AT=03:15 SYNC_TZ=Europe/Berlin
render "$T/r3"
check "a pair on an ordinary LAN (a /22, no dedicated link): rendered on the interface that holds SELF" bash -c '[ "$2" = 0 ] && grep -qxF "    interface ens19" "$1" && grep -qxF "        192.168.7.250/22 dev ens19" "$1" && grep -qxF "    unicast_src_ip 192.168.7.21" "$1"' _ "$T/r3/out" "$RC"
mkdir -p "$T/ex/bin"; fake "$T/ex/bin" ip 'printf "3: eth1    inet 10.20.30.5/24 scope global eth1\\n"'
PATH="$T/ex/bin:$PATH" ZRADIO_CONF="$KIT/zradio.conf.example" bash "$RENDER" > "$T/ex/out" 2> "$T/ex/err"; RC=$?
check "zradio.conf.example itself checks and renders (the example never drifts from the checks)" bash -c '[ "$2" = 0 ] && grep -qxF "    router_id radio1" "$1/out" && [ ! -s "$1/err" ]' _ "$T/ex" "$RC"
refused() { # refused <name> <expected words> <conf lines…>
  local name=$1 words=$2; shift 2; conf "$T/x" "$@"; render "$T/x"
  check "refused: $name" bash -c '[ "$3" = 1 ] && [ ! -s "$1/out" ] && grep -q -- "$2" "$1/err"' _ "$T/x" "$words" "$RC"
}
refused "SELF = PEER" "SELF and PEER are both" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY=100
refused "the VIP is this VM's own address" "is SELF or PEER" NAME=radio2 SELF=10.20.30.50 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100
refused "a PEER that is not an address" "PEER '10.20.30.999'" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.999 VIP=10.20.30.50/24 VRID=50 PRIORITY=100
refused "a VIP without a prefix" "VIP '10.20.30.50'" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50 VRID=50 PRIORITY=100
refused "VRID 0" "VRID '0'" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=0 PRIORITY=100
refused "no PRIORITY" "PRIORITY ''" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50
refused "the two ports are the same" "two different ports" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 ZWAVE_PORT=6638
refused "a sync time that is not HH:MM" "SYNC_AT '4.30'" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 SYNC_AT=4.30
refused "a line that is not KEY=value (the conf is sourced)" "not KEY=value" NAME=radio2 'touch /tmp/x' SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100
refused "a value with a command in it" "not KEY=value" NAME=radio2 'PEER=$(reboot)' SELF=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY=100
refused "no interface holds SELF" "no interface holds SELF 10.20.30.77" NAME=radio2 SELF=10.20.30.77 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100

echo "-- standby-dirty (a synced set not written to the end; on disk, so a reboot keeps it): check fails, up refuses"
host "$T/dy"; mkdir -p "$T/dy/state"; : > "$T/dy/state/standby-dirty"
serve "$T/dy" check
check "check: exit 1 while standby-dirty exists" eq "$RC" 1
serve "$T/dy" up
check "up: refused, ser2net not started, the receiver not touched" bash -c '[ "$2" = 1 ] && grep -q "failed  step=dirty" "$1/out" && ! grep -q "start" "$1/calls" && ! grep -q -- "--rf-receive" "$1/calls"' _ "$T/dy" "$RC"
serve "$T/dy" status
check "status names the marker" has "$T/dy/out" "a synced image was not written to the end"
rm -f "$T/dy/state/standby-dirty"; rm -f "$T/dy/run/serve-failed"
serve "$T/dy" check
check "check: exit 0 once it is cleared" eq "$RC" 0

echo "-- a new turn as the active drops the sync records of earlier turns (the peer gets one sync in every turn)"
host "$T/nt"; mkdir -p "$T/nt/state"; echo '{"gen": "20261112T002145Z"}' > "$T/nt/state/synced.json"; echo '{"gen": "20261112T001339Z"}' > "$T/nt/state/last-sync.json"
serve "$T/nt" up
check "up: exit 0, both records gone" bash -c '[ "$2" = 0 ] && [ ! -e "$1/state/synced.json" ] && [ ! -e "$1/state/last-sync.json" ]' _ "$T/nt" "$RC"
echo '{"gen": "20261112T050000Z"}' > "$T/nt/state/last-sync.json"; serve "$T/nt" up
check "up on a VM that serves already: nothing done, this turn's record stays" bash -c 'grep -q "up-already" "$1/out" && [ -f "$1/state/last-sync.json" ]' _ "$T/nt"
host "$T/nf" 0 fail; mkdir -p "$T/nf/state"; echo '{"gen": "x"}' > "$T/nf/state/synced.json"; serve "$T/nf" up
check "an up that fails keeps the records (this VM did not start a turn)" bash -c '[ "$2" = 1 ] && [ -f "$1/state/synced.json" ]' _ "$T/nf" "$RC"

echo "-- hush (the standby kept silent by the tick): receiver off, no coordinator reset unless it runs the network"
host "$T/hu"; echo 0 > "$T/hu/zb-ro"; serve "$T/hu" hush
check "exit 0; one receiver-off, one read-only Zigbee read, no reset" bash -c '[ "$2" = 0 ] && [ "$(grep -c -- "--rf-receive off" "$1/calls")" = 1 ] && grep -q "^zradio-probe.py --zigbee [^ ]* --json" "$1/calls" && ! grep -q -- "--zigbee-reset" "$1/calls"' _ "$T/hu" "$RC"
host "$T/hs" 1; serve "$T/hs" hush
check "on a VM that serves: nothing touched" bash -c '[ "$2" = 0 ] && grep -q "this VM serves" "$1/out" && ! grep -q zradio-probe "$1/calls"' _ "$T/hs" "$RC"
host "$T/hr"; serve "$T/hr" hush
check "a standby coordinator that runs the network (state 9): a loud line and a reset" bash -c 'grep -q "result=loud step=zigbee — hush: the standby.s coordinator runs the network (state 9)" "$1/journal" && grep -q -- "--zigbee-reset" "$1/calls"' _ "$T/hr"
host "$T/hf" 0 fail; echo 0 > "$T/hf/zb-ro"; serve "$T/hf" hush
check "the receiver does not answer: exit 1, a loud line" bash -c '[ "$2" = 1 ] && grep -q "result=loud step=zwave-receiver — hush" "$1/journal"' _ "$T/hf" "$RC"

echo "-- down with a stick's tty gone says so; hush stands back for MASTER and for a set being written"
host "$T/dg"; rm -f "$T/dg/dev/zwave"; serve "$T/dg" down
check "down: exit 0, down-partial names the tty, no receiver call" bash -c '[ "$2" = 0 ] && grep -q "down-partial  ser2net is stopped; no tty for .*/dev/zwave: that stick could not be silenced" "$1/out" && ! grep -q -- "--rf-receive" "$1/calls"' _ "$T/dg" "$RC"
host "$T/hm"; echo "MASTER x priority=1" > "$T/hm/run/role"; serve "$T/hm" hush
check "hush while keepalived's last word is MASTER (up is about to run): nothing touched" bash -c '[ "$2" = 0 ] && ! grep -q zradio-probe "$1/calls"' _ "$T/hm" "$RC"
host "$T/ha"; : > "$T/ha/run/applying"; serve "$T/ha" hush
check "hush while a synced set is being written: nothing touched" bash -c '[ "$2" = 0 ] && ! grep -q zradio-probe "$1/calls"' _ "$T/ha" "$RC"
host "$T/lk"; ( exec 7>"$T/lk/run/sticks.lock"; flock 7; command sleep 2 ) &
for _ in $(seq 1 100); do [ -e "$T/lk/run/sticks.lock" ] && ! flock -n "$T/lk/run/sticks.lock" true 2>/dev/null && break; command sleep 0.05; done   # the holder has the lock (a fixed pause was not enough under load: 1 FAIL in one full run, 2026-11-11)
t0=$(date +%s.%N); serve "$T/lk" up; t1=$(date +%s.%N); wait
check "up waits for the sticks lock (a hush or down still running), then serves" bash -c '[ "$1" = 0 ] && awk -v a="$2" -v b="$3" "BEGIN { exit !(b - a > 1.0) }" && [ "$(cat "$4/ser2net")" = 1 ]' _ "$RC" "$t0" "$t1" "$T/lk"

echo "-- stick-wedged (zradio-change-watch: a stick answered nothing while Home Assistant kept asking)"
host "$T/wg"; mkdir -p "$T/wg/state"; echo "zwave 2026-11-12T02:40:00Z" > "$T/wg/state/stick-wedged"
serve "$T/wg" check
check "check: exit 1 while stick-wedged exists (keepalived hands the radios over)" eq "$RC" 1
serve "$T/wg" up
check "up: refused, names the stick, nothing started" bash -c '[ "$2" = 1 ] && grep -q "failed  step=wedged — .*stick-wedged (zwave 2026-11-12T02:40:00Z)" "$1/out" && ! grep -q "start" "$1/calls"' _ "$T/wg" "$RC"
rm -f "$T/wg/run/serve-failed"; echo 0 > "$T/wg/zb-ro"; serve "$T/wg" hush
check "hush with both sticks answering: stick-wedged removed, said" bash -c '[ "$2" = 0 ] && [ ! -e "$1/state/stick-wedged" ] && grep -q "unwedged  both sticks answer again" "$1/out"' _ "$T/wg" "$RC"
serve "$T/wg" check
check "check: exit 0 again" eq "$RC" 0
host "$T/wh" 0 fail; mkdir -p "$T/wh/state"; echo "zwave x" > "$T/wh/state/stick-wedged"; echo 0 > "$T/wh/zb-ro"; serve "$T/wh" hush
check "hush with the Z-Wave stick still silent: stick-wedged stays, exit 1" bash -c '[ "$2" = 1 ] && [ -e "$1/state/stick-wedged" ] && grep -q "stick-wedged stays" "$1/out"' _ "$T/wh" "$RC"

echo "-- radios.conf decides which sticks there are and what is done to each"
only() { # only <dir> <radios.conf lines…>: a host whose radios.conf is the lines given
  local d=$1; shift; host "$d"; printf '%s\n' "$@" > "$d/radios.conf"; }
only "$T/zo" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=none; rm -f "$T/zo/dev/zigbee"
serve "$T/zo" check
check "a Z-Wave stick only: check passes without a Zigbee tty" eq "$RC" 0
serve "$T/zo" up
check "up: the receiver on, ser2net started" bash -c '[ "$2" = 0 ] && grep -q -- "--rf-receive on" "$1/calls" && [ "$(cat "$1/ser2net")" = 1 ]' _ "$T/zo" "$RC"
serve "$T/zo" down
check "down: the receiver off, no Zigbee call at all" bash -c '[ "$2" = 0 ] && grep -q -- "--rf-receive off" "$1/calls" && ! grep -q -- "--zigbee" "$1/calls" && grep -q "result=down ser2net is stopped, the Z-Wave receiver is off — silent standby" "$1/journal"' _ "$T/zo" "$RC"
only "$T/bo" ZWAVE=none ZIGBEE=synced ZIGBEE_FAMILY=znp; rm -f "$T/bo/dev/zwave"
serve "$T/bo" up
check "a Zigbee stick only: up starts ser2net, no receiver call" bash -c '[ "$2" = 0 ] && ! grep -q -- "--rf-receive" "$1/calls" && grep -q "result=up ser2net is started" "$1/journal"' _ "$T/bo" "$RC"
serve "$T/bo" down
check "down: the coordinator reset, no Z-Wave call" bash -c '[ "$2" = 0 ] && grep -q -- "--zigbee-reset" "$1/calls" && ! grep -q -- "--zwave" "$1/calls"' _ "$T/bo" "$RC"
only "$T/so" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=served ZIGBEE_FAMILY=ezsp
serve "$T/so" up; serve "$T/so" down
check "a served-only Zigbee stick is never touched: up and down make no Zigbee call, down says why" bash -c '! grep -q -- "--zigbee" "$1/calls" && grep -q "Zigbee (ezsp) is served only: not touched (its standby stick must hold no network)" "$1/journal"' _ "$T/so"
rm -f "$T/so/dev/zigbee"; serve "$T/so" check
check "…but its tty must be there: check fails when it is gone" eq "$RC" 1
only "$T/s2" ZWAVE=served ZWAVE_FAMILY=zwave-500 ZIGBEE=served ZIGBEE_FAMILY=deconz
serve "$T/s2" up
check "both served only: up starts ser2net and touches no stick" bash -c '[ "$2" = 0 ] && ! grep -q zradio-probe "$1/calls" && [ "$(cat "$1/ser2net")" = 1 ]' _ "$T/s2" "$RC"
serve "$T/s2" hush
host "$T/s3"; printf 'ZWAVE=served\nZIGBEE=served\n' > "$T/s3/radios.conf"; serve "$T/s3" hush
check "hush on a standby with served-only sticks: nothing touched, exit 0" bash -c '[ "$2" = 0 ] && ! grep -q zradio-probe "$1/calls"' _ "$T/s3" "$RC"
only "$T/nn" ZWAVE=none ZIGBEE=none
serve "$T/nn" check
check "no radio at all: check fails (this VM never takes the address)" eq "$RC" 1
serve "$T/nn" up
check "…and up refuses, saying so" bash -c '[ "$2" = 1 ] && grep -q "step=radios" "$1/journal" && ! grep -q "systemctl start" "$1/calls"' _ "$T/nn" "$RC"
host "$T/nr"; rm -f "$T/nr/radios.conf"
serve "$T/nr" check
check "no radios.conf (detection never ran): check fails" eq "$RC" 1
serve "$T/nr" down
check "…down still stops ser2net and ends 0 (the boot must not hang on it), and says no stick was silenced" bash -c '[ "$2" = 0 ] && grep -q "down-partial" "$1/out"' _ "$T/nr" "$RC"
only "$T/bad" 'ZWAVE=synced; reboot'
serve "$T/bad" check
check "a radios.conf with anything but KEY=value is not read: check fails" eq "$RC" 1
serve "$T/s2" status
check "status names the levels" has "$T/s2/out" "radios: Z-Wave served (zwave-500), Zigbee served (deconz)"

echo "-- a serving turn is confirmed or provisional (docs/DESIGN.md 3a); only ELECTION=act makes one provisional"
actconf() { printf '%s\n' NAME=radio1 SELF=10.20.30.5 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY=110 "ELECTION=$2" > "$1/zradio.conf"; }
host "$T/t1"; mkdir -p "$T/t1/state"; echo "term=5 zbfloor=7" > "$T/t1/state/outdated"; serve "$T/t1" up
check "observe mode (no conf, or ELECTION=observe): an outdated VM that serves is an ordinary, confirmed turn — as before" eq "$(cat "$T/t1/run/turn")" confirmed
host "$T/t2"; mkdir -p "$T/t2/state"; echo "term=5 zbfloor=7" > "$T/t2/state/outdated"; actconf "$T/t2" act; ZRADIO_CONF="$T/t2/zradio.conf" serve "$T/t2" up
check "ELECTION=act, outdated: the turn is provisional and the journal says what follows from that" bash -c '[ "$(cat "$1/run/turn")" = provisional ] && grep -q "event=serve result=provisional .*it is outdated: term=5 zbfloor=7" "$1/journal"' _ "$T/t2"
host "$T/t3"; : > "$T/t3/run/gate-alone"; actconf "$T/t3" act; ZRADIO_CONF="$T/t3/zradio.conf" serve "$T/t3" up
check "ELECTION=act, nobody answered at boot: provisional" eq "$(cat "$T/t3/run/turn")" provisional
host "$T/t4"; actconf "$T/t4" act; ZRADIO_CONF="$T/t4/zradio.conf" serve "$T/t4" up
check "ELECTION=act, a clean standby taking over: confirmed" eq "$(cat "$T/t4/run/turn")" confirmed
serve "$T/t4" down
check "down ends the turn" bash -c '[ ! -e "$1/run/turn" ]' _ "$T/t4"
mkdir -p "$T/t4/state"; echo "term=7 used=yes" > "$T/t4/state/version"; : > "$T/t4/run/hold"; serve "$T/t4" check
check "check fails on the gate's hold" eq "$RC" 1
serve "$T/t4" status
check "status shows the version and the hold" bash -c 'grep -q "version: term 7, used yes" "$1/out" && grep -q "marker: .*hold" "$1/out"' _ "$T/t4"

finish
