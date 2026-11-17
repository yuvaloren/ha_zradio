#!/usr/bin/env bash
# t-probe.sh — guest/lib/zradio-probe.py, the real one, against pretend sticks (tests/fake-stick.py): a Z-Wave
# controller and a Z-Stack coordinator that speak just enough of their protocols, behind a pty (a local tty, as the
# probe opens a stick). Each stick logs every frame it receives, so a check can say what was written. Nothing here
# reaches a real stick.
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

stick() { # stick <name> <zwave|zigbee> <config JSON>: a pretend stick; its tty in $PORT, its log $T/<name>.log
  local fd
  exec {fd}< <(exec python3 "$STICK" "$2" "$3" "$T/$1.log")
  PIDS="$PIDS $!"
  read -r PORT <&"$fd"          # the stick prints its tty once it listens: no waiting on a clock
}
probe() { python3 "$PROBE" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(d)' "$T/out" "$1"; }
zw_funcs() { cut -d' ' -f2 "$T/$1.log" | sort -u | tr '\n' ' '; }              # the functions a Z-Wave stick received
zb_writes() { grep -cE '^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 ' "$T/$1.log"; } # its NV deletes and writes, its resets

echo "-- read-only: a Z-Wave controller and a Z-Stack coordinator"
stick zw zwave "$ZW_LIVE"; ZW=$PORT
stick zb zigbee "$ZB_LIVE"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" --json
check "exit 0" eq "$RC" 0
check "Z-Wave home ID, node count, verdict, RF" \
  eq "$(j zwave.home_id_hex) $(j zwave.node_count) $(j zwave.verdict) $(j zwave.rf.region) $(j zwave.rf.tx_power_dbm)" "$HOME_HEX 4 live 9 14.0"
check "Zigbee IEEE, state, on a network; Z-Stack 3 by its capabilities" \
  eq "$(j zigbee.ieee) $(j zigbee.device_state) $(j zigbee.on_network) $(j zigbee.verdict) $(j zigbee.zstack)" "$IEEE 9 True live 3"
check "only reads reached the Z-Wave stick (GetControllerId, InitData, Capabilities, ProtocolVersion, Setup GETs, GetLongRangeNodes)" \
  eq "$(zw_funcs zw)" "0x02 0x07 0x09 0x0b 0x20 0xda "
check "no write reached the coordinator" eq "$(zb_writes zb)" 0
check "the human lines go to stderr with --json" bash -c 'grep -q "^   OK    Z-Wave on " "$1" && grep -q "^   OK    Zigbee on " "$1"' _ "$T/err"
check "the port is left with HUPCL cleared: closing it does not drop DTR and RTS (lines that reset some radios)" \
  bash -c '[[ "$(stty -F "$1" -a)" == *" -hupcl "* ]]' _ "$ZW"
probe --zwave tcp://127.0.0.1:1 --json
check "a network port instead of a tty: a usage error (through ser2net it would be the LIVE stick, taken from Home Assistant)" \
  bash -c '[ "$1" = 2 ] && grep -q "opens local ttys only" "$2"' _ "$RC" "$T/err"
check "the read path refuses a write whatever the caller: SerialAPISetup SetRFRegion, an NVM Write, HardReset — no byte sent" python3 -B - "$PROBE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("probe", sys.argv[1]); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
class Wire:
    spec, sent = "wire", b""
    def write(self, data, deadline): Wire.sent += data
    def read_some(self, deadline): return b""
z = p.ZWave(Wire(), 0.1, p.Budget(1))
for func, payload in ((p.ZW_SERIAL_API_SETUP, b"\x40\x01"), (p.ZW_NVM_OPS, b"\x02\x01\x00\x00\xaa"),
                      (p.ZW_NVM_OPS_EXT, b"\x02\x01\x00\x00\x00\x00\xaa"), (p.ZW_HARD_RESET, b"\x01")):
    try: z.request(func, "a write", payload)
    except p.ProbeError as e:
        if "refusing" not in str(e): sys.exit("0x%02x: %s" % (func, e))
    else: sys.exit("0x%02x was sent" % func)
sys.exit(1 if Wire.sent else 0)
PY

echo "-- a network is live when either node list has a node other than the controller: Long Range nodes (256+) have their own"
stick lr zwave "{\"home_id\": $HOME_ID, \"nodes\": [1], \"lr_nodes\": [256, 300]}"
probe --zwave "$PORT" --json
check "a controller whose devices are all Long Range: LIVE, the Long Range nodes read" \
  eq "$RC $(j zwave.verdict) $(j zwave.lr_nodes) $(j zwave.node_count) $(j zwave.lr_node_count)" "0 live [256, 300] 1 2"
stick lr0 zwave "{\"home_id\": $OTHER_HOME, \"nodes\": [1], \"lr\": false}"
probe --zwave "$PORT" --json
check "a controller whose function list has no GetLongRangeNodes: not asked, blank by its classic list" \
  eq "$RC $(j zwave.verdict) $(j zwave.lr_nodes) $(grep -c '^zwave 0xda' "$T/lr0.log")" "0 blank [] 0"
stick lrs zwave "{\"home_id\": $OTHER_HOME, \"nodes\": [1], \"lr_silent\": true}"
probe --zwave "$PORT" --timeout 0.3 --json
check "a controller that lists GetLongRangeNodes and does not answer it: UNKNOWN, never blank" eq "$RC $(j zwave.verdict) $(j zwave.lr_nodes)" "0 unknown None"
probe --wipe --zwave "$PORT" --expect-zwave-home-id "$HOME_ID" --timeout 0.3 --json
check "…and --wipe does not skip it as blank: refused" eq "$RC $(j zwave.wipe.plan)" "3 refuse"

echo "-- Z-Stack Home 1.2 (CC2531/CC2530): its network state is not in the item the probe reads"
stick old zigbee "{\"ieee\": \"$IEEE\", \"on_network\": true, \"state\": 0, \"zstack\": \"1.2\"}"
probe --zigbee "$PORT" --json
check "a 1.2 coordinator on a network: named 1.2 (no APP_CNF in its capabilities), UNKNOWN — never blank" \
  eq "$RC $(j zigbee.zstack) $(j zigbee.verdict) $(j zigbee.on_network)" "0 1.2 unknown None"
probe --wipe --zigbee "$PORT" --expect-zigbee-ieee "$OTHER_IEEE" --expect-zigbee-extpan "$EXTPAN" --json
check "…and --wipe does not skip it as blank: refused, nothing written" eq "$RC $(j zigbee.wipe.plan) $(zb_writes old)" "3 refuse 0"

echo "-- the single-purpose writes"
stick rf zwave "$ZW_LIVE"
probe --zwave "$PORT" --rf-receive off --json
check "--rf-receive off: SetRFReceiveMode(0) sent, success said the way zradio-serve looks for it" \
  bash -c '[ "$1" = 0 ] && grep -q "^zwave 0x10 00$" "$2" && grep -q "RF receive mode OFF" "$3"' _ "$RC" "$T/rf.log" "$T/err"
probe --zwave tcp://127.0.0.1:1 --rf-receive off
check "--rf-receive on a network port: a usage error (it would silence the live controller)" \
  bash -c '[ "$1" = 2 ] && grep -q "opens local ttys only" "$2"' _ "$RC" "$T/err"
probe --zwave "$PORT" --soft-reset --json
check "--soft-reset: SoftReset sent, the restart seen, then the reads" \
  bash -c '[ "$1" = 0 ] && grep -q "^zwave 0x08 $" "$2" && [ "$3" = True ]' _ "$RC" "$T/rf.log" "$(j zwave.soft_reset.serial_api_started)"
check "…and says so" bash -c 'grep -q "^   NOTE  Z-Wave: SoftReset sent first — ACK in .* s, SerialAPIStarted seen after .* s; the reads" "$1"' _ "$T/err"
probe --zwave "$PORT" --nvm-dump "$T/nvm.bin" --json
check "--nvm-dump: the stick's 512 bytes, unchanged, in a 0600 file" bash -c '[ "$1" = 0 ] && [ "$2" = 512 ] && [ "$(stat -c %a "$3")" = 600 ] &&
  python3 -c "import sys; sys.exit(open(sys.argv[1], \"rb\").read() != bytes(range(256)) * 2)" "$3"' _ "$RC" "$(j zwave.nvm_dump.bytes)" "$T/nvm.bin"
probe --zwave "$PORT" --nvm-dump "$T/no-such-dir/nvm.bin" --json
check "--nvm-dump to a file that cannot be made: the tool's own FAIL line, exit 1, no traceback" \
  bash -c '[ "$1" = 1 ] && grep -q "^   FAIL  Z-Wave on .*no-such-dir/nvm.bin" "$2" && ! grep -q Traceback "$2"' _ "$RC" "$T/err"
stick zr zigbee "$ZB_LIVE"
probe --zigbee "$PORT" --zigbee-reset --json
check "--zigbee-reset: SYS_RESET_REQ sent, nothing written to NV; the coordinator holds (state 0), still on its network" \
  bash -c '[ "$1" = 0 ] && grep -q "^zigbee 0x41 0x00 01$" "$2" && ! grep -qE "^zigbee 0x21 0x(12|1d) " "$2" && [ "$3" = "0 True" ]' \
  _ "$RC" "$T/zr.log" "$(j zigbee.device_state) $(j zigbee.on_network)"
check "…and says it stays quiet" has "$T/err" "the reads below are after the reboot: state InitializedNotStarted = QUIET (not started"

echo "-- the NVM read, as zwave-js's backupNVMRaw700 does it"
NV="\"home_id\": $HOME_ID, \"nodes\": [1, 2]"
stick nv1 zwave "{$NV, \"nvm_size\": 500}"
probe --zwave "$PORT" --nvm-dump "$T/nvm1.bin" --json
check "no read asks for more than is left: 0xff first, then the size the stick answers in, the last read clamped (52 bytes)" \
  eq "$RC $(j zwave.nvm_dump.bytes) $(sed -n 's/^zwave 0x2e 01\(..\).*/\1/p' "$T/nv1.log" | uniq | tr '\n' ' ')" "0 500 ff 40 34 "
stick nv2 zwave "{$NV, \"nvm_max_read\": 48}"
probe --zwave "$PORT" --nvm-dump "$T/nvm2.bin" --json
check "a stick that answers a long read with no data: read again 48 bytes at a time (zwave-js's fallback), the whole NVM, then closed" \
  bash -c '[ "$1" = "0 512" ] && [ "$(tail -n 1 "$3")" = "zwave 0x2e 03" ] &&
  python3 -c "import sys; sys.exit(open(sys.argv[1], \"rb\").read() != bytes(range(256)) * 2)" "$2"' _ "$RC $(j zwave.nvm_dump.bytes)" "$T/nvm2.bin" "$T/nv2.log"
stick nv3 zwave "{$NV, \"nvm_stall\": 128}"
probe --zwave "$PORT" --nvm-dump "$T/nvm3.bin" --timeout 1 --budget 3 --json
check "the budget is spent in the middle of the read: FAIL, no file — and the NVM is closed all the same" \
  bash -c '[ "$1" = 1 ] && [ ! -e "$2" ] && [ "$(tail -n 1 "$3")" = "zwave 0x2e 03" ]' _ "$RC" "$T/nvm3.bin" "$T/nv3.log"
stick nv4 zwave "{$NV, \"nvm_stall\": 128}"
python3 "$PROBE" --zwave "$PORT" --nvm-dump "$T/nvm4.bin" --timeout 30 --json > "$T/out" 2> "$T/err" & PP=$!
for _ in $(seq 100); do grep -q '^zwave 0x2e 01..0080$' "$T/nv4.log" && break; sleep 0.1; done      # the read that is never answered
kill -TERM $PP; wait $PP; RC=$?
check "SIGTERM in the middle of the read (zradio-sync's timeout): the NVM is closed before the probe ends, with its own FAIL line" \
  bash -c '[ "$1" = 1 ] && [ ! -e "$2" ] && [ "$(tail -n 1 "$3")" = "zwave 0x2e 03" ] && grep -q "^   FAIL  Z-Wave on .*SIGTERM" "$4"' \
  _ "$RC" "$T/nvm4.bin" "$T/nv4.log" "$T/err"

echo "-- --wipe"
probe --wipe --zwave tcp://127.0.0.1:1 --expect-zwave-home-id "$HOME_ID"
check "a network port: a usage error (only a host could tell the live stick from its copy)" \
  bash -c '[ "$1" = 2 ] && grep -q "opens local ttys only" "$2"' _ "$RC" "$T/err"
stick wr1 zwave "$ZW_OTHER"; ZW=$PORT; stick wr2 zigbee "$ZB_LIVE"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "the Z-Wave stick holds ANOTHER network: refused (exit 3), the Zigbee stale copy not wiped either" \
  bash -c '[ "$1" = 3 ] && [ "$2" = "refuse not-run" ] && grep -q "nothing was written to any stick" "$3"' \
  _ "$RC" "$(j zwave.wipe.plan) $(j zigbee.wipe.result)" "$T/err"
check "…nothing written: no HardReset, no NV delete or write, no reset" \
  bash -c '! grep -q "^zwave 0x42 " "$1" && [ "$(grep -cE "^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 " "$2")" = 0 ]' _ "$T/wr1.log" "$T/wr2.log"
stick ww1 zwave "$ZW_LIVE"; ZW=$PORT; stick ww2 zigbee "$ZB_LIVE"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "two stale copies: exit 0, both wiped and re-probed blank" \
  eq "$RC $(j zwave.wipe.result) $(j zigbee.wipe.result) $(j zwave.wipe.state)" "0 wiped wiped blank"
check "Z-Wave: HardReset sent ONCE, callback id 1" eq "$(grep -c '^zwave 0x42 ' "$T/ww1.log") $(grep '^zwave 0x42 ' "$T/ww1.log")" "1 zwave 0x42 01"
check "Zigbee: zigpy-znp's writes in its order — the four deletes, STARTUP_OPTION = 0x03, the reset, the closing reset" \
  eq "$(grep -E '^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 ' "$T/ww2.log" | tr '\n' ';')" \
  "zigbee 0x21 0x12 000f0100;zigbee 0x21 0x12 60000100;zigbee 0x21 0x12 5f000100;zigbee 0x21 0x12 55000100;$(
  )zigbee 0x21 0x1d 03000000010003;zigbee 0x41 0x00 01;zigbee 0x41 0x00 01;"
stick wb1 zwave "$ZW_BLANK"; ZW=$PORT; stick wb2 zigbee "$ZB_BLANK"; ZB=$PORT
probe --zwave "$ZW" --zigbee "$ZB" "${WIPE[@]}"
check "blank sticks: skipped, exit 0, nothing written" bash -c '[ "$1" = "0 skipped skipped" ] && ! grep -q "^zwave 0x42 " "$2" &&
  [ "$(grep -cE "^zigbee 0x21 0x(12|1d) |^zigbee 0x41 0x00 " "$3")" = 0 ]' _ "$RC $(j zwave.wipe.result) $(j zigbee.wipe.result)" "$T/wb1.log" "$T/wb2.log"
stick wh zigbee "$ZB_HALF"
probe --wipe --zigbee "$PORT" --expect-zigbee-ieee "$IEEE" --expect-zigbee-extpan "$EXTPAN" --json
check "an interrupted Zigbee wipe (not on a network, the extended PAN still the network's): wiped again, then blank" \
  eq "$RC $(j zigbee.wipe.plan) $(j zigbee.wipe.result) $(j zigbee.wipe.after.nv_extpan)" "0 wipe wiped "
finish
