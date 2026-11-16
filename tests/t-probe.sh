#!/usr/bin/env bash
# t-probe.sh — guest/lib/zradio-probe.py, the real one, against pretend sticks (tests/fake-stick.py): a Z-Wave
# controller and a Z-Stack coordinator that speak just enough of their protocols, behind a pty (a local tty, as the
# probe opens a stick) or a TCP port (as ser2net's raw port). Each stick logs every frame it receives, so a check can
# say what was written. Nothing here reaches a real stick.
. "$(dirname "$0")/lib.sh"
PROBE="$KIT/guest/lib/zradio-probe.py"
STICK="$TESTS_DIR/fake-stick.py"
PIDS=""; trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
HOME_ID=3517100996; HOME_HEX=0xd1a2b3c4; OTHER_HOME=305419896
IEEE=00:12:4b:00:aa:bb:cc:dd; OTHER_IEEE=00:12:4b:00:11:22:33:44; EXTPAN=dd:dd:dd:dd:dd:dd:dd:dd
ZW_LIVE="{\"home_id\": $HOME_ID, \"nodes\": [1, 2, 3, 5]}"
ZW_OTHER="{\"home_id\": $OTHER_HOME, \"nodes\": [1, 7]}"
ZW_BLANK="{\"home_id\": $OTHER_HOME, \"nodes\": [1]}"
ZB_LIVE="{\"ieee\": \"$IEEE\", \"on_network\": true, \"ext_pan\": \"$EXTPAN\", \"state\": 9}"
ZB_BLANK="{\"ieee\": \"$OTHER_IEEE\", \"on_network\": false, \"state\": 0}"
# an interrupted wipe: the deletes done, no STARTUP_OPTION write, no reset — not on a network, not running, the
# network's extended PAN still in NV
ZB_HALF="{\"ieee\": \"$IEEE\", \"on_network\": false, \"ext_pan\": \"$EXTPAN\", \"state\": 0}"
WIPE=(--wipe --expect-zwave-home-id "$HOME_ID" --expect-zigbee-ieee "$IEEE" --expect-zigbee-extpan "$EXTPAN" --json)

stick() { # stick <name> <zwave|zigbee> <pty|tcp> <config JSON>: a pretend stick; its port spec in $PORT, its log $T/<name>.log
  local fd
  exec {fd}< <(exec python3 "$STICK" "$2" "$4" "$T/$1.log" "$3")
  PIDS="$PIDS $!"
  read -r PORT <&"$fd"          # the stick prints its port once it listens: no waiting on a clock
}
probe() { python3 "$PROBE" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(d)' "$T/out" "$1"; }
zw_funcs() { cut -d' ' -f2 "$T/$1.log" | sort -u | tr '\n' ' '; }              # the functions a Z-Wave stick received
zb_writes() { grep -cE '^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 ' "$T/$1.log"; } # its NV deletes and writes, its resets

echo "-- read-only: a Z-Wave controller and a Z-Stack coordinator, over a local tty and over tcp://"
for how in pty tcp; do
  stick zw-$how zwave $how "$ZW_LIVE"; ZW=$PORT
  stick zb-$how zigbee $how "$ZB_LIVE"; ZB=$PORT
  probe --zwave "$ZW" --zigbee "$ZB" --json
  check "$how: exit 0" eq "$RC" 0
  check "$how: Z-Wave home ID, node count, verdict, RF" \
    eq "$(j zwave.home_id_hex) $(j zwave.node_count) $(j zwave.verdict) $(j zwave.rf.region) $(j zwave.rf.tx_power_dbm)" "$HOME_HEX 4 live 9 14.0"
  check "$how: Zigbee IEEE, state, on a network" \
    eq "$(j zigbee.ieee) $(j zigbee.device_state) $(j zigbee.on_network) $(j zigbee.verdict)" "$IEEE 9 True live"
  check "$how: only reads reached the Z-Wave stick (GetControllerId, InitData, Capabilities, ProtocolVersion, Setup GETs)" \
    eq "$(zw_funcs zw-$how)" "0x02 0x07 0x09 0x0b 0x20 "
  check "$how: no write reached the coordinator" eq "$(zb_writes zb-$how)" 0
  check "$how: the human lines go to stderr with --json" bash -c 'grep -q "^   OK    Z-Wave on " "$1" && grep -q "^   OK    Zigbee on " "$1"' _ "$T/err"
done

echo "-- the single-purpose writes, local tty only"
stick rf zwave pty "$ZW_LIVE"
probe --zwave "$PORT" --rf-receive off --json
check "--rf-receive off: SetRFReceiveMode(0) sent, success said the way zradio-serve looks for it" \
  bash -c '[ "$1" = 0 ] && grep -q "^zwave 0x10 00$" "$2" && grep -q "RF receive mode OFF" "$3"' _ "$RC" "$T/rf.log" "$T/err"
probe --zwave tcp://127.0.0.1:1 --rf-receive off
check "--rf-receive through tcp://: a usage error (it would silence the live controller)" \
  bash -c '[ "$1" = 2 ] && grep -q "opens a local tty only" "$2"' _ "$RC" "$T/err"
probe --zwave "$PORT" --soft-reset --json
check "--soft-reset: SoftReset sent, the restart seen, then the reads" \
  bash -c '[ "$1" = 0 ] && grep -q "^zwave 0x08 $" "$2" && [ "$3" = True ]' _ "$RC" "$T/rf.log" "$(j zwave.soft_reset.serial_api_started)"
check "…and says so" bash -c 'grep -q "^   NOTE  Z-Wave: SoftReset sent first — ACK in .* s, SerialAPIStarted seen after .* s; the reads" "$1"' _ "$T/err"
probe --zwave "$PORT" --nvm-dump "$T/nvm.bin" --json
check "--nvm-dump: the stick's 512 bytes, unchanged, in a 0600 file" bash -c '[ "$1" = 0 ] && [ "$2" = 512 ] && [ "$(stat -c %a "$3")" = 600 ] &&
  python3 -c "import sys; sys.exit(open(sys.argv[1], \"rb\").read() != bytes(range(256)) * 2)" "$3"' _ "$RC" "$(j zwave.nvm_dump.bytes)" "$T/nvm.bin"
stick zr zigbee pty "$ZB_LIVE"
probe --zigbee "$PORT" --zigbee-reset --json
check "--zigbee-reset: SYS_RESET_REQ sent, nothing written to NV; the coordinator holds (state 0), still on its network" \
  bash -c '[ "$1" = 0 ] && grep -q "^zigbee 0x41 0x00 01$" "$2" && ! grep -qE "^zigbee 0x21 0x(12|1d) " "$2" && [ "$3" = "0 True" ]' \
  _ "$RC" "$T/zr.log" "$(j zigbee.device_state) $(j zigbee.on_network)"
check "…and says it stays quiet" has "$T/err" "the reads below are after the reboot: state InitializedNotStarted = QUIET (not started"

echo "-- --wipe"
stick wt zwave tcp "$ZW_LIVE"
probe --wipe --zwave "$PORT" --expect-zwave-home-id "$HOME_ID"
check "a tcp:// port: a usage error before anything is sent (only a host could tell the live stick from its copy)" \
  bash -c '[ "$1" = 2 ] && grep -q "wipe opens local ttys only" "$2" && [ ! -s "$3" ]' _ "$RC" "$T/err" "$T/wt.log"
stick wr1 zwave pty "$ZW_OTHER"; ZW=$PORT; stick wr2 zigbee pty "$ZB_LIVE"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "the Z-Wave stick holds ANOTHER network: refused (exit 3), the Zigbee stale copy not wiped either" \
  bash -c '[ "$1" = 3 ] && [ "$2" = "refuse not-run" ] && grep -q "nothing was written to any stick" "$3"' \
  _ "$RC" "$(j zwave.wipe.plan) $(j zigbee.wipe.result)" "$T/err"
check "…nothing written: no HardReset, no NV delete or write, no reset" \
  bash -c '! grep -q "^zwave 0x42 " "$1" && [ "$(grep -cE "^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 " "$2")" = 0 ]' _ "$T/wr1.log" "$T/wr2.log"
stick ww1 zwave pty "$ZW_LIVE"; ZW=$PORT; stick ww2 zigbee pty "$ZB_LIVE"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "two stale copies: exit 0, both wiped and re-probed blank" \
  eq "$RC $(j zwave.wipe.result) $(j zigbee.wipe.result) $(j zwave.wipe.state)" "0 wiped wiped blank"
check "Z-Wave: HardReset sent ONCE, callback id 1" eq "$(grep -c '^zwave 0x42 ' "$T/ww1.log") $(grep '^zwave 0x42 ' "$T/ww1.log")" "1 zwave 0x42 01"
check "Zigbee: zigpy-znp's writes in its order — the four deletes, STARTUP_OPTION = 0x03, the reset, the closing reset" \
  eq "$(grep -E '^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 ' "$T/ww2.log" | tr '\n' ';')" \
  "zigbee 0x21 0x12 000f0100;zigbee 0x21 0x12 60000100;zigbee 0x21 0x12 5f000100;zigbee 0x21 0x12 55000100;$(
  )zigbee 0x21 0x1d 03000000010003;zigbee 0x41 0x00 01;zigbee 0x41 0x00 01;"
stick wb1 zwave pty "$ZW_BLANK"; ZW=$PORT; stick wb2 zigbee pty "$ZB_BLANK"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "blank sticks: skipped, exit 0, nothing written" bash -c '[ "$1" = "0 skipped skipped" ] && ! grep -q "^zwave 0x42 " "$2" &&
  [ "$(grep -cE "^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 " "$3")" = 0 ]' _ "$RC $(j zwave.wipe.result) $(j zigbee.wipe.result)" "$T/wb1.log" "$T/wb2.log"
stick wh zigbee pty "$ZB_HALF"
probe --wipe --zigbee "$PORT" --expect-zigbee-ieee "$IEEE" --expect-zigbee-extpan "$EXTPAN" --json
check "an interrupted Zigbee wipe (not on a network, the extended PAN still the network's): wiped again, then blank" \
  eq "$RC $(j zigbee.wipe.plan) $(j zigbee.wipe.result) $(j zigbee.wipe.after.nv_extpan)" "0 wipe wiped "
finish
