#!/usr/bin/env bash
# t-change-watch.sh — guest/sbin/zradio-change-watch: (1) the two stream parsers through `parse-test`, on
# frames built to the Z-Wave Serial API and ZNP framing rules with their checksums [the layouts: zwave-js's
# AddNodeToNetworkRequest / RemoveNodeFromNetworkRequest and zigpy-znp's ZDO.MgmtPermitJoinReq / MgmtLeaveReq; the two
# requests Home Assistant really sent to the reference sticks are in the fixtures below, marked V]; (2) the "five quiet minutes,
# then one sync" pass through `check-test`, with zradio-sync, systemctl and logger as fakes. No socket is opened.
. "$(dirname "$0")/lib.sh"
export PYTHONDONTWRITEBYTECODE=1
TOOL="$KIT/guest/sbin/zradio-change-watch"
pt() { printf '%s\n' "$@" | python3 "$TOOL" parse-test 2>&1 | tr '\n' ';'; }

echo "-- Z-Wave: the requests that change membership, and the ones that do not"
check "AddNodeToNetwork, any node (mode 0xC1): seen" eq "$(pt 'zwave 0105004ac12150')" "zwave add-node mode=1;"
check "AddNodeToNetwork stop (mode 5): ignored" eq "$(pt 'zwave 0105004ac50075')" ""
check "SmartStart listening (mode 9, the driver's start): ignored" eq "$(pt 'zwave 0105004a4900f9')" ""
check "RemoveNodeFromNetwork (mode 1): seen; its stop (mode 5): ignored" eq "$(pt 'zwave 0105004bc12252' 'zwave 0105004b0500b4')" "zwave remove-node mode=1;"
check "RemoveFailedNode: seen" eq "$(pt 'zwave 010500612a2392')" "zwave remove-failed-node;"
check "an ordinary SendData frame: ignored" eq "$(pt 'zwave 010e00a90103028611250000000030da')" ""
check "ACK bytes around a frame, two frames in one packet" eq "$(pt 'zwave 06060105004ac12150060105004bc1225206')" "zwave add-node mode=1;zwave remove-node mode=1;"
check "one frame split over two packets" eq "$(pt 'zwave 010500' 'zwave 4ac12150')" "zwave add-node mode=1;"
check "a wrong checksum: not a frame" eq "$(pt 'zwave 0105004ac12151')" ""
check "the same bytes inside a SendData payload do not count twice or wrongly (frame boundaries hold)" eq "$(pt 'zwave 010c00a90105004ac12150250081')" ""
check "a RESPONSE frame (type 01) with func 0x4A: ignored (host requests only)" eq "$(pt 'zwave 0104014a01b1')" ""

echo "-- Zigbee: permit-join with a duration, a leave request; everything else ignored"
check "ZDO_MGMT_PERMIT_JOIN_REQ, 60 s: seen" eq "$(pt 'zigbee fe0525360200003c0129')" "zigbee permit-join duration=60;"
check "permit-join with duration 0 (closing the network; ZHA's start): ignored" eq "$(pt 'zigbee fe0525360ffcff00001a')" ""
check "ZDO_MGMT_LEAVE_REQ: seen" eq "$(pt 'zigbee fe0b2534123401020304050607080034')" "zigbee leave-request;"
check "an AF data request: ignored" eq "$(pt 'zigbee fe0d240112340101060005001e0301020310')" ""
check "split over two packets, garbage before it" eq "$(pt 'zigbee 0011fe05253602' 'zigbee 00003c0129')" "zigbee permit-join duration=60;"
check "a wrong FCS: not a frame" eq "$(pt 'zigbee fe0525360200003c0128')" ""

echo "-- five quiet minutes, then one sync"
env_() { # env_ <dir> [role] [ser2net] [sync rc]
  local d=$1; rm -rf "$d"; mkdir -p "$d/bin" "$d/state" "$d/run"; : > "$d/calls"; : > "$d/journal"
  echo "${2:-MASTER} x priority=1" > "$d/run/role"; echo "${3:-1}" > "$d/ser2net"
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  fake "$d/bin" systemctl "[ \"\$(cat '$d/ser2net')\" = 1 ]"
  fake "$d/bin" zradio-sync "echo \"zradio-sync \$*\" >> '$d/calls'; exit ${4:-0}"
}
ck() { local d=$1; PATH="$d/bin:$PATH" ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_RUN="$d/run" ZRADIO_CHANGE_SYNC="$d/bin/zradio-sync" python3 "$TOOL" check-test > "$d/out" 2>&1; RC=$?; }
env_ "$T/q0"; ck "$T/q0"
check "no mark: nothing" eq "$(cat "$T/q0/calls")" ""
env_ "$T/q1"; touch -d '2 minutes ago' "$T/q1/state/change-seen"; ck "$T/q1"
check "a mark 2 min old: not yet" bash -c '[ ! -s "$1/calls" ] && [ -e "$1/state/change-seen" ]' _ "$T/q1"
env_ "$T/q2"; touch -d '6 minutes ago' "$T/q2/state/change-seen"; ck "$T/q2"
check "a mark 6 min old on the active: one zradio-sync run --reason device-change" eq "$(cat "$T/q2/calls")" "zradio-sync run --reason device-change"
check "the mark is cleared, the start is counted, the journal has sync then synced" bash -c '[ ! -e "$1/state/change-seen" ] && [ "$(grep -c . "$1/state/change-syncs")" = 1 ] && grep -q "event=change result=sync " "$1/journal" && grep -q "event=change result=synced zradio-sync run ended rc=0" "$1/journal"' _ "$T/q2"
env_ "$T/q3" MASTER 1 1; touch -d '6 minutes ago' "$T/q3/state/change-seen"; ck "$T/q3"
check "the sync fails: said (zradio-sync's own pending mark makes the tick retry), the mark cleared — no second read every 5 s" bash -c 'grep -q "result=sync-failed zradio-sync run ended rc=1" "$1/journal" && [ ! -e "$1/state/change-seen" ]' _ "$T/q3"
env_ "$T/q4" BACKUP 0; touch -d '6 minutes ago' "$T/q4/state/change-seen"; ck "$T/q4"
check "this VM is not the active any more: the mark dropped, no sync" bash -c '[ ! -s "$1/calls" ] && [ ! -e "$1/state/change-seen" ] && grep -q "result=dropped" "$1/journal"' _ "$T/q4"
env_ "$T/q5"; touch -d '6 minutes ago' "$T/q5/state/change-seen"; now=$(date +%s); for i in 1 2 3 4 5 6; do echo $((now - i * 600)); done > "$T/q5/state/change-syncs"; ck "$T/q5"
check "six device-change syncs in the last 24 h: no seventh, one loud line, the mark kept" bash -c '[ ! -s "$1/calls" ] && grep -q "result=loud 6 device-change syncs started in the last 24 h" "$1/journal" && [ -e "$1/state/change-seen" ]' _ "$T/q5"
env_ "$T/q6"; touch -d '6 minutes ago' "$T/q6/state/change-seen"; now=$(date +%s); for i in 1 2 3 4 5 6; do echo $((now - 90000 - i)); done > "$T/q6/state/change-syncs"; ck "$T/q6"
check "starts older than 24 h do not count" eq "$(cat "$T/q6/calls")" "zradio-sync run --reason device-change"
echo "-- a stick that stopped answering: requests counted until the stick sends anything"
wt() { printf '%s\n' "$@" | python3 "$TOOL" wedge-test 2>&1 | tr '\n' ';'; }
check "5 requests, the first 181 s ago, no byte from the stick: wedged" eq "$(wt '-5 stick zwave' '0 host zwave 7' '40 host zwave 7' '80 host zwave 7' '120 host zwave 7' '170 host zwave 7' '181 check')" "181: zwave wedged, 5 unanswered for 181 s;"
check "the same at 179 s: not yet" eq "$(wt '0 host zwave 7' '40 host zwave 7' '80 host zwave 7' '120 host zwave 7' '170 host zwave 7' '179 check')" "179: nothing;"
check "4 requests in 10 minutes: too few to judge" eq "$(wt '0 host zwave 7' '100 host zwave 7' '300 host zwave 7' '500 host zwave 7' '600 check')" "600: nothing;"
check "one byte from the stick clears the count; the clock starts with the next request" eq "$(wt '0 host zwave 7' '10 host zwave 7' '20 host zwave 7' '30 host zwave 7' '40 host zwave 7' '170 stick zwave' '175 host zwave 7' '200 check' '360 check')" "200: nothing;360: nothing;"
check "the host's one-byte Z-Wave ACKs ask for no answer: not counted" eq "$(wt '0 host zwave 1' '10 host zwave 1' '20 host zwave 1' '30 host zwave 1' '40 host zwave 1' '50 host zwave 1' '400 check')" "400: nothing;"
check "a quiet house (no request at all): nothing, however long" eq "$(wt '0 stick zwave' '5000 check')" "5000: nothing;"
check "the two sticks are judged apart: Zigbee answers, Z-Wave does not" eq "$(wt '-5 stick zwave' '0 host zwave 7' '1 host zigbee 9' '2 stick zigbee' '30 host zwave 7' '31 host zigbee 9' '32 stick zigbee' '60 host zwave 7' '90 host zwave 7' '120 host zwave 7' '200 check')" "200: zwave wedged, 5 unanswered for 200 s;"
check "ZNP: frames of 5+ bytes count, the coordinator silent 3 min: wedged" eq "$(wt '-5 stick zigbee' '0 host zigbee 5' '30 host zigbee 5' '60 host zigbee 5' '90 host zigbee 5' '120 host zigbee 5' '150 host zigbee 5' '185 check')" "185: zigbee wedged, 6 unanswered for 185 s;"

check "a stick this process never heard answer is never judged (the 2026-11-11 incident: the capture saw no answers at all)" eq "$(wt '0 host zigbee 9' '30 host zigbee 9' '60 host zigbee 9' '90 host zigbee 9' '120 host zigbee 9' '150 host zigbee 9' '400 check')" "400: nothing;"

echo "-- the declaration: observe by default; armed: the marker zradio-serve check fails on, one loud line, a limit of two a day"
env_ "$T/w0"; PATH="$T/w0/bin:$PATH" ZRADIO_CHANGE_STATE="$T/w0/state" ZRADIO_CHANGE_RUN="$T/w0/run" python3 "$TOOL" declare-test zwave 7 190 > "$T/w0/out" 2>&1
check "observe mode (the default): False, no marker, one would-wedge line that is not loud" bash -c 'grep -q "^False$" "$1/out" && [ ! -e "$1/state/stick-wedged" ] && grep -q "event=change result=would-wedge stick=zwave — 7 requests unanswered for 190 s; observe mode" "$1/journal" && ! grep -q "result=loud" "$1/journal"' _ "$T/w0"
dt() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_CHANGE_WEDGE=act ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_RUN="$d/run" python3 "$TOOL" declare-test "$@" > "$d/out" 2>&1; }
env_ "$T/w1"; dt "$T/w1" zwave 7 190
check "on the active: True, stick-wedged names the stick, the line is loud and says what was seen" bash -c 'grep -q "^True$" "$1/out" && grep -q "^zwave 20..-..-..T" "$1/state/stick-wedged" && grep -q "event=change result=loud wedged stick=zwave — Home Assistant sent 7 requests in 190 s and the stick answered nothing" "$1/journal"' _ "$T/w1"
env_ "$T/w2" BACKUP 0; dt "$T/w2" zwave 7 190
check "on a VM that does not serve: nothing declared" bash -c 'grep -q "^False$" "$1/out" && [ ! -e "$1/state/stick-wedged" ] && [ ! -s "$1/journal" ]' _ "$T/w2"
env_ "$T/w3"; now=$(date +%s); printf '%s\n%s\n' $((now - 3600)) $((now - 7200)) > "$T/w3/state/wedge-declared"; dt "$T/w3" zigbee 9 200
check "two declarations in the last 24 h already: not a third — a loud line, no marker" bash -c 'grep -q "^False$" "$1/out" && [ ! -e "$1/state/stick-wedged" ] && grep -q "result=loud wedged-not-declared stick=zigbee" "$1/journal"' _ "$T/w3"
env_ "$T/w4"; now=$(date +%s); printf '%s\n%s\n' $((now - 90000)) $((now - 95000)) > "$T/w4/state/wedge-declared"; dt "$T/w4" zigbee 9 200
check "declarations older than 24 h do not count" bash -c 'grep -q "^True$" "$1/out" && [ -e "$1/state/stick-wedged" ]' _ "$T/w4"

echo "-- the ports, the interface and the parsers come from zradio.conf and radios.conf"
ct() { # ct <dir> <conf lines…> -- <radios lines…>
  local d=$1; shift; rm -rf "$d"; mkdir -p "$d/bin"; : > "$d/conf"; : > "$d/radios"; local f="$d/conf"
  for l in "$@"; do if [ "$l" = -- ]; then f="$d/radios"; else echo "$l" >> "$f"; fi; done
  fake "$d/bin" ip 'printf "1: lo    inet 127.0.0.1/8 scope host lo\\n2: eth0    inet 192.168.1.44/24 scope global eth0\\n3: eth1    inet 10.20.30.6/24 scope global eth1\\n"'
  PATH="$d/bin:$PATH" ZRADIO_CONF="$d/conf" ZRADIO_RADIOS="$d/radios" python3 "$TOOL" conf-test > "$d/out" 2>&1; RC=$?; }
ct "$T/c1" SELF=10.20.30.6 -- ZWAVE=synced ZIGBEE=synced ZIGBEE_FAMILY=znp
check "the defaults: 6638 Zigbee / 6639 Z-Wave, the interface that holds SELF, ZNP parsed" eq "$(cat "$T/c1/out")" "iface=eth1 ports=6638:zigbee,6639:zwave zigbee_parsed=True"
ct "$T/c2" SELF=192.168.1.44 ZWAVE_PORT=7001 ZIGBEE_PORT=7002 -- ZWAVE=synced ZIGBEE=served ZIGBEE_FAMILY=ezsp
check "other ports, a LAN address, a Zigbee family that is not parsed" eq "$(cat "$T/c2/out")" "iface=eth0 ports=7001:zwave,7002:zigbee zigbee_parsed=False"
ct "$T/c3" SELF=10.20.30.6 IFACE=ens19 -- ZWAVE=synced ZIGBEE=none
check "IFACE named in the conf wins; a kind that is 'none' has no port to watch" eq "$(cat "$T/c3/out")" "iface=ens19 ports=6639:zwave zigbee_parsed=False"
ct "$T/c4" SELF=10.9.9.9 -- ZWAVE=synced
check "no interface holds SELF: said, exit 1" bash -c '[ "$2" != 0 ] && grep -q "no interface holds SELF 10.9.9.9" "$1/out"' _ "$T/c4" "$RC"
ct "$T/c5" 'SELF=10.20.30.6; reboot' -- ZWAVE=synced
check "a conf line that is not KEY=value is not taken (no SELF: said)" bash -c '[ "$2" != 0 ] && grep -q "no SELF" "$1/out"' _ "$T/c5" "$RC"

check "--help: exit 0, names what it looks for" bash -c 'python3 "$1" --help | grep -q "0x4A AddNodeToNetwork" && python3 "$1" --help | grep -q "ZDO_MGMT_PERMIT_JOIN_REQ"' _ "$TOOL"
finish
