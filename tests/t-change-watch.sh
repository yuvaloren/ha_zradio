#!/usr/bin/env bash
# t-change-watch.sh — guest/sbin/zradio-change-watch: (1) the two stream parsers through `parse-test`, on
# frames built to the Z-Wave Serial API and ZNP framing rules with their checksums [the layouts: zwave-js's
# AddNodeToNetworkRequest / RemoveNodeFromNetworkRequest and zigpy-znp's ZDO.MgmtPermitJoinReq / MgmtLeaveReq; the two
# requests Home Assistant really sent to the reference sticks are in the fixtures below, marked V]; (2) the "five quiet minutes,
# then one sync" pass through `check-test`, with zradio-sync, systemctl and logger as fakes; (3) which packets count,
# the streams followed and the clocks through `stream-test`, on segments written out as text. No socket is opened.
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
check "ACK bytes around a frame, two frames in one packet" eq "$(pt 'zwave 06060105004ac12150060105004bc1225206')" \
  "zwave add-node mode=1;zwave remove-node mode=1;"
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
ck() { # ck <dir> [seconds of passes]
  local d=$1; PATH="$d/bin:$PATH" ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_RUN="$d/run" ZRADIO_CHANGE_SYNC="$d/bin/zradio-sync" python3 \
  "$TOOL" check-test ${2:+"$2"} > "$d/out" 2>&1; RC=$?; }
env_ "$T/q0"; ck "$T/q0"
check "no mark: nothing" eq "$(cat "$T/q0/calls")" ""
env_ "$T/q1"; touch -d '2 minutes ago' "$T/q1/state/change-seen"; ck "$T/q1"
check "a mark 2 min old: not yet" bash -c '[ ! -s "$1/calls" ] && [ -e "$1/state/change-seen" ]' _ "$T/q1"
env_ "$T/q2"; touch -d '6 minutes ago' "$T/q2/state/change-seen"; ck "$T/q2"
check "a mark 6 min old on the active: one zradio-sync run --reason device-change" eq "$(cat "$T/q2/calls")" "zradio-sync run --reason device-change"
check "the mark is cleared, the start is counted, the journal has sync then synced" bash -c '[ ! -e "$1/state/change-seen" ] &&
  [ "$(grep -c . "$1/state/change-syncs")" = 1 ] && grep -q "event=change result=sync " "$1/journal" &&
  grep -q "event=change result=synced zradio-sync run ended rc=0" "$1/journal"' _ "$T/q2"
env_ "$T/q3" MASTER 1 1; touch -d '6 minutes ago' "$T/q3/state/change-seen"; ck "$T/q3" 1
check "the sync fails: said, the mark KEPT (the change is not on the standby) — and no second read for the same request at the next looks" bash -c \
  'grep -q "result=sync-failed zradio-sync run ended rc=1" "$1/journal" && [ -e "$1/state/change-seen" ] && [ "$(grep -c . "$1/calls")" = 1 ]' _ "$T/q3"
gen_at() { date -u -d "$1" +%Y%m%dT%H%M%SZ; }       # a sync's gen: the moment its read began
echo "{\"gen\": \"$(gen_at now)\", \"reason\": \"catch-up\"}" > "$T/q3/state/last-sync.json"; : > "$T/q3/journal"; ck "$T/q3"
check "…until zradio-sync's own retry has read after it: then the mark is dropped, with no sync of the watcher's" bash -c \
  '[ ! -e "$1/state/change-seen" ] && [ "$(grep -c . "$1/calls")" = 1 ] && grep -q "result=covered" "$1/journal"' _ "$T/q3"
env_ "$T/q4" BACKUP 0; touch -d '6 minutes ago' "$T/q4/state/change-seen"; ck "$T/q4"
check "this VM is not the active any more: the mark dropped, no sync" bash -c '[ ! -s "$1/calls" ] && [ ! -e "$1/state/change-seen" ] &&
  grep -q "result=dropped" "$1/journal"' _ "$T/q4"
env_ "$T/q5"; touch -d '6 minutes ago' "$T/q5/state/change-seen"; now=$(date +%s); for i in 1 2 3 4 5 6; do echo $((now - i * 600)); done \
  > "$T/q5/state/change-syncs"; ck "$T/q5"
check "six device-change syncs in the last 24 h: no seventh, one loud line, the mark kept" bash -c '[ ! -s "$1/calls" ] &&
  grep -q "result=loud 6 device-change syncs started in the last 24 h" "$1/journal" && [ -e "$1/state/change-seen" ]' _ "$T/q5"
env_ "$T/q6"; touch -d '6 minutes ago' "$T/q6/state/change-seen"; now=$(date +%s); for i in 1 2 3 4 5 6; do echo $((now - 90000 - i)); done \
  > "$T/q6/state/change-syncs"; ck "$T/q6"
check "starts older than 24 h do not count" eq "$(cat "$T/q6/calls")" "zradio-sync run --reason device-change"

echo "-- a sync that read after the quiet time already holds the change (the nightly one, a catch-up): no second pause"
env_ "$T/v1"; touch -d '20 minutes ago' "$T/v1/state/change-seen"
echo "{\"gen\": \"$(gen_at '10 minutes ago')\", \"reason\": \"nightly\"}" > "$T/v1/state/last-sync.json"; ck "$T/v1"
check "the last sync's read began 10 min after the request: no sync, the mark dropped, said" bash -c '[ ! -s "$1/calls" ] &&
  [ ! -e "$1/state/change-seen" ] && grep -q "event=change result=covered" "$1/journal"' _ "$T/v1"
env_ "$T/v2"; touch -d '20 minutes ago' "$T/v2/state/change-seen"
echo "{\"gen\": \"$(gen_at '17 minutes ago')\"}" > "$T/v2/state/last-sync.json"; ck "$T/v2"
check "its read began 3 min after the request (inside the five minutes: the device may have joined after it): a sync" \
  eq "$(cat "$T/v2/calls")" "zradio-sync run --reason device-change"
env_ "$T/v3"; touch -d '20 minutes ago' "$T/v3/state/change-seen"
echo "{\"gen\": \"$(gen_at '2 hours ago')\"}" > "$T/v3/state/last-sync.json"; ck "$T/v3"
check "the last sync is older than the request: a sync" eq "$(cat "$T/v3/calls")" "zradio-sync run --reason device-change"
env_ "$T/v4"; touch -d '20 minutes ago' "$T/v4/state/change-seen"; echo 'not json' > "$T/v4/state/last-sync.json"; ck "$T/v4"
check "a record that does not read: a sync (never the other way)" eq "$(cat "$T/v4/calls")" "zradio-sync run --reason device-change"

echo "-- the sync is a child: the packets are read while it runs; only exit 0 drops the mark; 75 (busy) is asked again"
env_ "$T/n1"; fake "$T/n1/bin" zradio-sync "echo \"zradio-sync \$*\" >> '$T/n1/calls'; sleep 2"
touch -d '6 minutes ago' "$T/n1/state/change-seen"; ck "$T/n1"
check "a sync of 2 s: the watcher looks 5+ times while it runs, starts it once, drops the mark at its end" bash -c \
  '[ "$(grep -c "pass: the sync is running" "$1/out")" -ge 5 ] && [ "$(grep -c . "$1/calls")" = 1 ] && [ ! -e "$1/state/change-seen" ] &&
  grep -q "result=synced zradio-sync run ended rc=0" "$1/journal"' _ "$T/n1"
env_ "$T/n2"; fake "$T/n2/bin" zradio-sync "sleep 0.5; touch '$T/n2/state/change-seen'"
touch -d '6 minutes ago' "$T/n2/state/change-seen"; ck "$T/n2"
check "a request seen DURING the sync keeps its own five minutes" bash -c '[ -e "$1/state/change-seen" ] &&
  grep -q "result=synced" "$1/journal"' _ "$T/n2"
env_ "$T/b1" MASTER 1 75; touch -d '6 minutes ago' "$T/b1/state/change-seen"; ck "$T/b1" 1
check "another sync is running (exit 75): the mark kept, said once, the start does not count against the six a day" bash -c \
  '[ -e "$1/state/change-seen" ] && [ "$(grep -c "result=busy" "$1/journal")" = 1 ] && ! grep -q "result=synced" "$1/journal" &&
  [ "$(grep -c . "$1/state/change-syncs")" = 0 ] && [ "$(grep -c . "$1/calls")" = 1 ]' _ "$T/b1"
env_ "$T/b2"; fake "$T/b2/bin" zradio-sync "echo \"zradio-sync \$*\" >> '$T/b2/calls'; [ \"\$(grep -c . '$T/b2/calls')\" -ge 2 ] || exit 75"
touch -d '6 minutes ago' "$T/b2/state/change-seen"; ZRADIO_CHANGE_BUSY_RETRY=1 ck "$T/b2" 3
check "busy, then asked again after the wait: the second run ends, the mark is dropped, one start counted" bash -c \
  '[ "$(grep -c . "$1/calls")" = 2 ] && [ ! -e "$1/state/change-seen" ] && [ "$(grep -c . "$1/state/change-syncs")" = 1 ] &&
  grep -q "result=synced" "$1/journal"' _ "$T/b2"
gone() { local p; for p in $(cat "$1"); do [ ! -e "/proc/$p" ] || grep -q '^State:[[:space:]]*Z' "/proc/$p/status" 2>/dev/null || return 1; done; }
env_ "$T/k1"; fake "$T/k1/bin" zradio-sync "echo \$\$ > '$T/k1/pids'; sleep 15 & echo \$! >> '$T/k1/pids'; wait"
touch -d '6 minutes ago' "$T/k1/state/change-seen"; ZRADIO_CHANGE_SYNC_BOUND=1 ck "$T/k1" 3
check "a sync that outlives its bound: ended with all it started, said loudly, the mark kept" bash -c \
  'grep -q "result=loud .*zradio-sync run did not end in 1 s" "$1/journal" && [ -e "$1/state/change-seen" ] && [ "$(grep -c . "$1/pids")" = 2 ]' \
  _ "$T/k1"
check "…its processes are gone" gone "$T/k1/pids"

echo "-- a stick that stopped answering: requests counted until the stick sends anything"
wt() { printf '%s\n' "$@" | python3 "$TOOL" wedge-test 2>&1 | tr '\n' ';'; }
check "5 requests, the first 181 s ago, no byte from the stick: wedged" eq "$(wt '-5 stick zwave' '0 host zwave 7' '40 host zwave 7' '80 host zwave 7' \
  '120 host zwave 7' '170 host zwave 7' '181 check')" "181: zwave wedged, 5 unanswered for 181 s;"
check "the same at 179 s: not yet" eq "$(wt '0 host zwave 7' '40 host zwave 7' '80 host zwave 7' '120 host zwave 7' '170 host zwave 7' '179 check')" \
  "179: nothing;"
check "4 requests in 10 minutes: too few to judge" eq "$(wt '0 host zwave 7' '100 host zwave 7' '300 host zwave 7' '500 host zwave 7' '600 check')" \
  "600: nothing;"
check "one byte from the stick clears the count; the clock starts with the next request" eq "$(wt '0 host zwave 7' '10 host zwave 7' '20 host zwave 7' \
  '30 host zwave 7' '40 host zwave 7' '170 stick zwave' '175 host zwave 7' '200 check' '360 check')" "200: nothing;360: nothing;"
check "the host's one-byte Z-Wave ACKs ask for no answer: not counted" eq "$(wt '0 host zwave 1' '10 host zwave 1' '20 host zwave 1' '30 host zwave 1' \
  '40 host zwave 1' '50 host zwave 1' '400 check')" "400: nothing;"
check "a quiet house (no request at all): nothing, however long" eq "$(wt '0 stick zwave' '5000 check')" "5000: nothing;"
check "the two sticks are judged apart: Zigbee answers, Z-Wave does not" eq "$(wt '-5 stick zwave' '0 host zwave 7' '1 host zigbee 9' '2 stick zigbee' \
  '30 host zwave 7' '31 host zigbee 9' '32 stick zigbee' '60 host zwave 7' '90 host zwave 7' '120 host zwave 7' '200 check')" \
  "200: zwave wedged, 5 unanswered for 200 s;"
check "ZNP: frames of 5+ bytes count, the coordinator silent 3 min: wedged" eq "$(wt '-5 stick zigbee' '0 host zigbee 5' '30 host zigbee 5' \
  '60 host zigbee 5' '90 host zigbee 5' '120 host zigbee 5' '150 host zigbee 5' '185 check')" "185: zigbee wedged, 6 unanswered for 185 s;"

check "a stick this process never heard answer is never judged (the 2026-11-11 incident: the capture saw no answers at all)" eq "$(wt \
  '0 host zigbee 9' '30 host zigbee 9' '60 host zigbee 9' '90 host zigbee 9' '120 host zigbee 9' '150 host zigbee 9' '400 check')" "400: nothing;"

echo "-- the declaration: the marker zradio-serve check fails on, one loud line, a limit of two a day; no setting for it"
env_ "$T/w00"; PATH="$T/w00/bin:$PATH" ZRADIO_CHANGE_STATE="$T/w00/state" ZRADIO_CHANGE_RUN="$T/w00/run" python3 "$TOOL" declare-test zwave 7 190 > "$T/w00/out" 2>&1
check "with nothing set, the check is on: True, and stick-wedged is written" bash -c 'grep -q "^True$" "$1/out" && grep -q "^zwave 20" "$1/state/stick-wedged" && grep -q "result=loud wedged stick=zwave" "$1/journal"' _ "$T/w00"
check "…and its line says what comes next: zradio-serve hush tries to bring the stick back" bash -c 'grep -q "zradio-serve hush now tries to bring the stick back (a soft reset, a USB re-bind, then its power through the node)" "$1/journal"' _ "$T/w00"
env_ "$T/w0"; PATH="$T/w0/bin:$PATH" ZRADIO_CHANGE_WEDGE=observe ZRADIO_CHANGE_STATE="$T/w0/state" ZRADIO_CHANGE_RUN="$T/w0/run" python3 "$TOOL" declare-test zwave 7 190 > "$T/w0/out" 2>&1
check "ZRADIO_CHANGE_WEDGE=observe in the unit's environment (a pair whose check misfires): False, no marker, one would-wedge line that is not loud" bash -c 'grep -q "^False$" "$1/out" &&
  [ ! -e "$1/state/stick-wedged" ] &&
  grep -q "event=change result=would-wedge stick=zwave — 7 requests unanswered for 190 s; observe mode" "$1/journal" &&
  ! grep -q "result=loud" "$1/journal"' _ "$T/w0"
dt() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_CHANGE_WEDGE=act ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_RUN="$d/run" python3 "$TOOL" \
  declare-test "$@" > "$d/out" 2>&1; }
env_ "$T/w1"; dt "$T/w1" zwave 7 190
check "on the active: True, stick-wedged names the stick, the line is loud and says what was seen" bash -c 'grep -q "^True$" "$1/out" &&
  grep -q "^zwave 20..-..-..T" "$1/state/stick-wedged" &&
  grep -q "event=change result=loud wedged stick=zwave — Home Assistant sent 7 requests in 190 s and the stick answered nothing" "$1/journal"' _ "$T/w1"
env_ "$T/w2" BACKUP 0; dt "$T/w2" zwave 7 190
check "on a VM that does not serve: nothing declared" bash -c 'grep -q "^False$" "$1/out" && [ ! -e "$1/state/stick-wedged" ] &&
  [ ! -s "$1/journal" ]' _ "$T/w2"
env_ "$T/w3"; now=$(date +%s); printf '%s\n%s\n' $((now - 3600)) $((now - 7200)) > "$T/w3/state/wedge-declared"; dt "$T/w3" zigbee 9 200
check "two declarations in the last 24 h already: not a third — a loud line, no marker" bash -c 'grep -q "^False$" "$1/out" &&
  [ ! -e "$1/state/stick-wedged" ] && grep -q "result=loud wedged-not-declared stick=zigbee" "$1/journal"' _ "$T/w3"
env_ "$T/w4"; now=$(date +%s); printf '%s\n%s\n' $((now - 90000)) $((now - 95000)) > "$T/w4/state/wedge-declared"; dt "$T/w4" zigbee 9 200
check "declarations older than 24 h do not count" bash -c 'grep -q "^True$" "$1/out" && [ -e "$1/state/stick-wedged" ]' _ "$T/w4"

echo "-- which packets count: only the host's bytes that this VM's own kernel acknowledged on that connection"
HA=10.20.30.10:51234; ZW=10.20.30.50:6639; BAD=10.20.30.66:4444
ADD=0105004ac12150; REM=0105004bc12252; REQ=010e00a90103028611250000000030da     # 7, 7 and 16 bytes
SEEN_ADD="result=seen zwave add-node mode=1 — the standby is synced after 300 quiet s;"
SEEN_REM="result=seen zwave remove-node mode=1 — the standby is synced after 300 quiet s;"
sx() { # sx <dir> <stream-test lines…>: on the active, observe mode; what it said, as one line, in OUT
  local d=$1; shift; env_ "$d"
  OUT=$(printf '%s\n' "$@" | PATH="$d/bin:$PATH" ZRADIO_CHANGE_WEDGE=observe ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_RUN="$d/run" python3 "$TOOL" stream-test 2>&1 | tr '\n' ';'); }
sx "$T/s1" "0 in $HA $ZW PA 1000 500 $ADD" "0.01 out $ZW $HA A 500 1007" "20 check"
check "a connection that was open before the watcher started (no SYN seen): its first request counts, once" eq "$OUT" "$SEEN_ADD"
check "…and change-seen is there" test -e "$T/s1/state/change-seen"
sx "$T/s2" "0 in $HA $ZW S 999 0" "0 out $ZW $HA SA 499 1000" "0 in $HA $ZW A 1000 500" "1 in $HA $ZW PA 1000 500 $REQ" \
  "1 out $ZW $HA PA 500 1016 0601" "2 in $HA $ZW PA 1016 502 06$ADD" "2.2 out $ZW $HA A 502 1024" "20 check"
check "a connection opened under the watcher's eyes: the request in its second segment" eq "$OUT" "$SEEN_ADD"
sx "$T/s3" "0 in $BAD $ZW PA 1000 0 $ADD" "0 out $ZW $BAD R 0 0" "20 check"
check "one forged segment, no connection (the kernel answers with a reset): nothing said" eq "$OUT" ""
check "…and no change-seen" test ! -e "$T/s3/state/change-seen"
sx "$T/s4" "0 in $BAD $ZW S 999 0" "0 out $ZW $BAD SA 7000 1000" "0.1 in $BAD $ZW PA 1000 1 $ADD" "0.1 out $ZW $BAD R 1 0" \
  "0.2 in $BAD $ZW PA 1007 1 $ADD" "20 check"
check "a forged SYN, then data (the kernel's SYN-ACK is no acknowledgment of data): nothing" bash -c '[ -z "$1" ] && [ ! -e "$2" ]' \
  _ "$OUT" "$T/s4/state/change-seen"
sx "$T/s5" "0 in $HA $ZW PA 1000 500 $REQ" "0 out $ZW $HA A 500 1016" "1 in $HA $ZW PA 900000 500 $REM" "1 out $ZW $HA A 500 1016" \
  "2 in $HA $ZW PA 1100 500 $REM" "2 out $ZW $HA A 500 1016" "3 in $HA $ZW PA 1016 500 $ADD" "3 out $ZW $HA A 500 1023" "20 check"
check "forged with Home Assistant's own address and port, sequence numbers the kernel does not expect: only the real request" \
  eq "$OUT" "$SEEN_ADD"
sx "$T/s6" "0 in $HA $ZW PA 1000 500 $ADD" "0 out $ZW $HA A 500 1007" "1 in $HA $ZW PA 1000 500 $ADD" "1 out $ZW $HA A 500 1007" "20 check"
check "a retransmission of bytes already read: read once" eq "$OUT" "$SEEN_ADD"
sx "$T/s7" "0 in $HA $ZW PA 1000 500 $REQ" "0 out $ZW $HA A 500 1016" "1 in $HA $ZW PA 1019 500 4ac12150" "1 in $HA $ZW PA 1016 500 010500" \
  "1 out $ZW $HA A 500 1023" "20 check"
check "a frame over two segments that arrive out of order: read in the order of their bytes" eq "$OUT" "$SEEN_ADD"
sx "$T/s8" "0 in $HA $ZW PA 1000 500 010500" "0 out $ZW $HA A 500 1003" "1 in $HA $ZW PA 1010 500 4ac12150$REM" "1 out $ZW $HA A 500 1021" "20 check"
check "a segment the watcher was not handed (a hole): no frame is built across it; the frame after it is read" eq "$OUT" "$SEEN_REM"
sx "$T/s9" "0 in $HA $ZW PA 1000 500 $ADD$ADD$ADD$ADD$ADD" "0 out $ZW $HA A 500 1035" "3 check" "12 check" "20 check"
check "five requests in one segment: one line at once, one more for the other four — not a logger per frame" bash -c \
  '[ "$1" = "$2""result=seen 4 more add/remove requests in the last 12 s (the last: zwave add-node mode=1);" ] && [ "$(grep -c . "$3")" = 2 ]' \
  _ "$OUT" "$SEEN_ADD" "$T/s9/journal"
sx "$T/s10" "0 in $HA 10.20.30.6:6639 PA 1000 500 $ADD" "0 out $ZW $HA A 500 1007" "20 check"
check "the acknowledgment belongs to another of this VM's addresses: not this connection" eq "$OUT" ""
BIG=$(for _ in $(seq 300); do printf %s "$REQ"; done); BIG="$BIG$ADD$BIG"       # 9607 bytes
sx "$T/s11" "0 in $HA $ZW PA 1000 500 $BIG" "0.04 out $ZW $HA A 500 10607" "20 check"
check "a connection's first segment is 9607 bytes (several, joined by the network card), a request in the middle: kept whole, read" \
  eq "$OUT" "$SEEN_ADD"

echo "-- the silent-stick count takes the same packets only, and its ages a clock that never steps"
STICK="-5 out $ZW $HA PA 400 1000 0601"                      # the stick has been heard
five() { local i; for i in 0 1 2 3 4; do echo "$((${1:-0} + i)) in $HA $ZW PA $((1000 + 16 * i)) 402 $REQ"; echo "$((${1:-0} + i)) out $ZW $HA A 402 $((1016 + 16 * i))"; done; }
mapfile -t L < <(five); sx "$T/x1" "$STICK" "${L[@]}" "185 check"
check "5 requests the kernel took and the stick did not answer, 185 s: would-wedge (observe)" \
  bash -c 'case "$1" in "result=would-wedge stick=zwave — 5 requests unanswered for 185 s; observe mode"*) ;; *) exit 1;; esac' _ "$OUT"
mapfile -t L < <(for i in 0 1 2 3 4 5; do echo "$i in $BAD $ZW PA $((1000 + 16 * i)) 0 $REQ"; done)
sx "$T/x2" "$STICK" "${L[@]}" "185 check"
check "6 forged requests, 185 s: they are no requests of Home Assistant's — nothing" eq "$OUT" ""
mapfile -t L < <(five); sx "$T/x3" "$STICK" "${L[@]}" "6 clock 300" "10 check"
check "the wall clock steps 300 s forward (a time sync): no 180 s of silence out of nothing" eq "$OUT" ""
mapfile -t L < <(five 1); sx "$T/x4" "$STICK" "0 check" "${L[@]}" "6 clock -3600" "190 check"
check "the wall clock steps an hour back: the looks go on, the count stands (189 s)" \
  bash -c 'case "$1" in "result=would-wedge stick=zwave — 5 requests unanswered for 189 s;"*) ;; *) exit 1;; esac' _ "$OUT"
mapfile -t L < <(for i in $(seq 0 24); do echo "$((i * 3)) in $HA $ZW PA $((1000 + 16 * i)) 402 $REQ"; done)
sx "$T/x5" "${L[@]}" "80 check" "90 check"
check "requests arrive and nothing this VM sends from the port is ever seen (its answers leave by another interface): one loud line" bash -c \
  '[ "$(grep -c "result=loud blind port=6639" "$1")" = 1 ]' _ "$T/x5/journal"

echo "-- the streams followed are bounded; a connection's end drops its stream"
mapfile -t L < <(for i in $(seq 1 3000); do echo "0 in 10.$((i % 250)).$((i / 250)).7:$((20000 + i)) $ZW PA 1000 0 $ADD"; done)
sx "$T/y1" "${L[@]}" "1 state"
check "segments from 3000 addresses and ports: 64 kept at most, none of them followed" eq "$OUT" "streams=0 unproven=64;"
mapfile -t L < <(for i in $(seq 1 40); do echo "0 in 10.20.30.10:$((20000 + i)) $ZW PA 1000 500 $REQ"; echo "0 out $ZW 10.20.30.10:$((20000 + i)) A 500 1016"; done)
sx "$T/y2" "${L[@]}" "1 state"
check "40 real connections: the 16 used last are followed" eq "$OUT" "streams=16 unproven=0;"
mapfile -t L < <(for i in $(seq 1 3000); do echo "1 in 10.$((i % 250)).$((i / 250)).7:$((20000 + i)) $ZW PA 1000 0 $ADD"; done)
sx "$T/y3" "0 in $HA $ZW PA 1000 500 010500" "0 out $ZW $HA A 500 1003" "${L[@]}" "2 in $HA $ZW PA 1003 500 4ac12150" "2 out $ZW $HA A 500 1007" "20 check"
check "a flood of forged segments does not push Home Assistant's connection out: a frame begun before it is read after it" eq "$OUT" "$SEEN_ADD"
sx "$T/y4" "0 in $HA $ZW PA 1000 500 $REQ" "0 out $ZW $HA A 500 1016" "1 state" "2 in $HA $ZW FA 1016 500" "2 out $ZW $HA FA 500 1017" "3 state"
check "the connection is closed (this VM's FIN): its stream is dropped" eq "$OUT" "streams=1 unproven=0;streams=0 unproven=0;"
sx "$T/y5" "0 in $HA $ZW PA 1000 500 $REQ" "0 out $ZW $HA A 500 1016" "1 in $HA $ZW R 5555 0" "1 state" "2 in $HA $ZW R 1016 0" "2 state"
check "a reset from the host: only the one the kernel takes (the next byte's number) drops the stream" eq "$OUT" "streams=1 unproven=0;streams=0 unproven=0;"
sx "$T/y6" "0 in $HA $ZW PA 1000 500 010500" "0 out $ZW $HA A 500 1003" "1 in $HA $ZW S 4999 0" "1 out $ZW $HA SA 800 5000" "1 in $HA $ZW A 5000 801" \
  "2 in $HA $ZW PA 5000 801 4ac12150$REM" "2 out $ZW $HA A 801 5011" "20 check"
check "a new connection from the same address and port (this VM's SYN-ACK): a fresh stream, nothing of the old one's bytes" eq "$OUT" "$SEEN_REM"

echo "-- the ports, the interface and the parsers come from zradio.conf and radios.conf, read by zradio-common.sh"
cset() { # cset <dir> <conf lines…> -- <radios lines…>: a pair's conf with these lines added, `ip` and logger as fakes
  local d=$1; shift; rm -rf "$d"; mkdir -p "$d/bin"; : > "$d/radios"; : > "$d/journal"; local f="$d/conf"
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  printf '%s\n' NAME=radio2 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 > "$f"
  for l in "$@"; do if [ "$l" = -- ]; then f="$d/radios"; else echo "$l" >> "$f"; fi; done
  fake "$d/bin" ip 'printf "1: lo    inet 127.0.0.1/8 scope host lo\\n2: eth0    inet 192.168.1.44/24 scope global eth0\\n'\
'3: eth1    inet 10.20.30.6/24 scope global eth1\\n"'; }
cw() { # cw <dir> <door> [seconds]: that door on the conf of <dir>, ended after <seconds>
  local d=$1; PATH="$d/bin:$PATH" ZRADIO_CONF="$d/conf" ZRADIO_RADIOS="$d/radios" ZRADIO_CHANGE_STATE="$d/state" ZRADIO_CHANGE_LOOK_EVERY=1 \
    timeout "${3:-20}" python3 "$TOOL" "$2" > "$d/out" 2>&1; RC=$?; }
ct() { local d=$1; cset "$@"; cw "$d" conf-test; }
ct "$T/c1" SELF=10.20.30.6 -- ZWAVE=synced ZIGBEE=synced ZIGBEE_FAMILY=znp
check "the defaults: 6638 Zigbee / 6639 Z-Wave, the interface that holds SELF, ZNP parsed" \
  eq "$(cat "$T/c1/out")" "iface=eth1 ports=6638:zigbee,6639:zwave zigbee_parsed=True"
ct "$T/c2" SELF=192.168.1.44 ZWAVE_PORT=7001 ZIGBEE_PORT=7002 -- ZWAVE=synced ZIGBEE=served ZIGBEE_FAMILY=ezsp
check "other ports, a LAN address, a Zigbee family that is not parsed" \
  eq "$(cat "$T/c2/out")" "iface=eth0 ports=7001:zwave,7002:zigbee zigbee_parsed=False"
ct "$T/c3" SELF=10.20.30.6 IFACE=ens19 -- ZWAVE=synced ZIGBEE=none
check "IFACE named in the conf wins; a kind that is 'none' has no port to watch" \
  eq "$(cat "$T/c3/out")" "iface=ens19 ports=6639:zwave zigbee_parsed=False"
ct "$T/c4" SELF=10.9.9.9 -- ZWAVE=synced
check "no interface holds SELF: said, exit 1" bash -c '[ "$2" != 0 ] && grep -q "no interface holds SELF 10.9.9.9" "$1/out"' _ "$T/c4" "$RC"
ct "$T/c5" 'SELF=10.20.30.6; reboot' -- ZWAVE=synced
check "a conf line that is not KEY=value: the whole conf is refused, as by the shell tools" \
  bash -c '[ "$2" != 0 ] && grep -q "holds a line that is not KEY=value" "$1/out"' _ "$T/c5" "$RC"
ct "$T/c6" SELF=10.20.30.6 ZWAVE_PORT=80 -- ZWAVE=synced
check "a port the shell tools refuse is refused here too" bash -c '[ "$2" != 0 ] && grep -q "ZWAVE_PORT .80." "$1/out"' _ "$T/c6" "$RC"
ct "$T/c7" SELF=10.20.30.6 -- 'ZWAVE=synced; reboot'
check "a radios.conf that does not load: no radio to watch (as before)" eq "$(cat "$T/c7/out")" "iface=eth1 ports= zigbee_parsed=False"


echo "-- nothing to watch: the service waits and looks again (the unit restarts whatever exits: every 5 s, for ever)"
cset "$T/e1" SELF=10.20.30.6 -- ZWAVE=none ZIGBEE=none; cw "$T/e1" run 3
check "no radio in radios.conf: still running after 3 s and three looks, ONE journal line" bash -c '[ "$2" = 124 ] &&
  [ "$(grep -c "event=change result=waiting" "$1/journal")" = 1 ] && grep -q "names no radio" "$1/journal"' _ "$T/e1" "$RC"
cset "$T/e2" SELF=10.9.9.9 -- ZWAVE=synced; cw "$T/e2" run 3
check "no interface holds SELF: the same" bash -c '[ "$2" = 124 ] && [ "$(grep -c "event=change result=waiting" "$1/journal")" = 1 ] &&
  grep -q "no interface holds SELF 10.9.9.9" "$1/journal"' _ "$T/e2" "$RC"
cset "$T/e3" SELF=10.20.30.6 -- ZWAVE=none; cw "$T/e3" wait-test & sleep 1.5; echo ZWAVE=synced > "$T/e3/radios"; wait $!
check "a radio appears (zradio-detect --write): the watcher goes on with it, no restart needed" bash -c \
  'grep -qx "iface=eth1 ports=6639:zwave zigbee_parsed=False" "$1/out" && grep -q "result=waiting" "$1/journal"' _ "$T/e3"

echo "-- the TCP segment in an IPv4 packet (what the packet socket hands over)"
st() { printf '%s\n' "$@" | python3 "$TOOL" segment-test 2>&1 | tr '\n' ';'; }
check "Home Assistant's request to the Z-Wave port: addresses, ports, sequence, flags, the payload" \
  eq "$(st 4500002f00010000400600000a141e0a0a141e32c82219ef000003e80000000050180400000000000105004ac12150)" \
  "src=10.20.30.10 dst=10.20.30.50 sport=51234 dport=6639 seq=1000 ack=0 flags=0x18 payload=0105004ac12150;"
check "IP and TCP options, Ethernet padding after the packet: the payload is where the headers say, and ends at the total length" \
  eq "$(st 4600003f00010000400600000a141e0a0a141e3201010101c82219ef000003e800000000801804000000000001010101010101010101010101\
05004ac12150000000000000)" "src=10.20.30.10 dst=10.20.30.50 sport=51234 dport=6639 seq=1000 ack=0 flags=0x18 payload=0105004ac12150;"
check "a SYN to the Zigbee port: no payload" eq "$(st 4500002800010000400600000a141e0a0a141e32c82219ee0000004d000000005002040000000000)" \
  "src=10.20.30.10 dst=10.20.30.50 sport=51234 dport=6638 seq=77 ack=0 flags=0x02 payload=;"
check "this VM's acknowledgment on its way to the host: the acknowledgment number" \
  eq "$(st 4500002800010000400600000a141e320a141e0a19efc82200001388000003ef5010040000000000)" \
  "src=10.20.30.50 dst=10.20.30.10 sport=6639 dport=51234 seq=5000 ack=1007 flags=0x10 payload=;"
check "UDP, and a packet too short for a TCP header: not a segment" \
  eq "$(st 4500002000010000401100000a141e0a0a141e3214e919ef000c000061626364 4500001800010000400600000a141e0a0a141e32c822)" \
  "not a TCP segment;not a TCP segment;"
check "an IP header length that leaves no room for the TCP header: not a segment (no exception)" \
  eq "$(st 4f00002800010000400600000a141e0a0a141e32c82219ef000003e80000000050180400000000000000)" "not a TCP segment;"

check "--help: exit 0, names what it looks for" bash -c 'python3 "$1" --help | grep -q "0x4A AddNodeToNetwork" &&
  python3 "$1" --help | grep -q "ZDO_MGMT_PERMIT_JOIN_REQ"' _ "$TOOL"
finish
