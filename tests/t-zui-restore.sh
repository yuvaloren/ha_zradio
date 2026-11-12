#!/usr/bin/env bash
# t-zui-restore.sh — guest/lib/zui-restore.py against tests/fake-zui.py, a stand-in that speaks the WebSocket,
# engine.io and socket.io framing Z-Wave JS UI speaks (the client's frames must be masked, its attachment must arrive
# as one binary frame). What the real Z-Wave JS UI answers to restoreNVM on a real stick is not tested here.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/lib/zui-restore.py"
srv() { # srv <dir> [knob…]: a fake on a free port; URL set
  local d=$1; shift; mkdir -p "$d"; rm -f "$d/port"
  python3 "$TESTS_DIR/fake-zui.py" "$d/port" "$d" "$@" & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do [ -s "$d/port" ] && break; sleep 0.05; done
  URL="http://127.0.0.1:$(cat "$d/port")"
}
PIDS=""; trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
head -c 40960 /dev/urandom > "$T/nvm.bin"

echo "-- read: the driver's view"
srv "$T/a"
OUT=$(python3 "$TOOL" read --url "$URL" --wait 5 2>&1); RC=$?
check "exit 0, the home ID as hex, ready" bash -c '[ "$1" = 0 ] && printf "%s" "$2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"ready\"] and d[\"home_id_hex\"]==\"0xf4486cba\" and d[\"nodes\"]==1"' _ "$RC" "$OUT"

echo "-- restore: the image travels as one binary frame, byte for byte"
OUT=$(python3 "$TOOL" restore --url "$URL" --nvm "$T/nvm.bin" --mode converting --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 5 2>&1); RC=$?
check "exit 0, DONE" bash -c '[ "$1" = 0 ] && printf "%s" "$2" | grep -q "^DONE  restoreNVM(useRaw=false) answered success"' _ "$RC" "$OUT"
check "the fake received exactly the file" cmp -s "$T/nvm.bin" "$T/a/received.bin"
check "converting = useRaw false; one read first" eq "$(grep -v closed "$T/a/calls" | tail -2 | tr '\n' ';')" "driverFunction;restoreNVM useRaw=false bytes=40960;"
check "the progress line is printed, the image is not" bash -c 'printf "%s" "$1" | grep -q "controller: Restoring NVM" && [ "$(printf "%s" "$1" | wc -c)" -lt 2000 ]' _ "$OUT"
OUT=$(python3 "$TOOL" restore --url "$URL" --nvm "$T/nvm.bin" --mode raw --force --wait 5 2>&1); RC=$?
check "raw = useRaw true" bash -c '[ "$1" = 0 ] && grep -q "restoreNVM useRaw=true bytes=40960" "$2"' _ "$RC" "$T/a/calls"

echo "-- a stick that already holds the network: nothing written unless --force"
mkdir -p "$T/b"; echo $((0xdeadbeef)) > "$T/b/home"; srv "$T/b"
OUT=$(python3 "$TOOL" restore --url "$URL" --nvm "$T/nvm.bin" --expect-home-id 0xdeadbeef --expect-nodes 1 --wait 5 2>&1); RC=$?
check "already restored: exit 0, no restoreNVM call" bash -c '[ "$1" = 0 ] && printf "%s" "$2" | grep -q "already restored" && ! grep -q restoreNVM "$3"' _ "$RC" "$OUT" "$T/b/calls"

echo "-- refusals and noise"
srv "$T/c" refuse
OUT=$(python3 "$TOOL" restore --url "$URL" --nvm "$T/nvm.bin" --wait 5 2>&1); RC=$?
check "restoreNVM answers success=false: exit 1, FAIL names the message" bash -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -q "FAIL  restoreNVM refused: fake refusal"' _ "$RC" "$OUT"
srv "$T/d" notready
OUT=$(python3 "$TOOL" read --url "$URL" --wait 1 2>&1); RC=$?
check "a driver that never gets ready: exit 1 after --wait" bash -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -q "no ready driver"' _ "$RC" "$OUT"
srv "$T/e" ping binary-event
OUT=$(python3 "$TOOL" restore --url "$URL" --nvm "$T/nvm.bin" --wait 5 2>&1); RC=$?
check "engine.io pings and a binary event before the answer do not derail the call" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$RC" "$T/nvm.bin" "$T/e/received.bin"
OUT=$(python3 "$TOOL" read --url "http://127.0.0.1:1" --wait 1 2>&1); RC=$?
check "nothing listens: exit 1, no traceback" bash -c '[ "$1" = 1 ] && ! printf "%s" "$2" | grep -q Traceback' _ "$RC" "$OUT"
OUT=$(python3 "$TOOL" restore --url "$URL" --wait 1 2>&1); RC=$?
check "restore without --nvm: usage, exit 2" eq "$RC" 2
finish
