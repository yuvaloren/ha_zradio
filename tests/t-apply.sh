#!/usr/bin/env bash
# t-apply.sh — guest/sbin/zradio-apply against fakes: podman (image exists / run / stop / rm, recorded), zigpy (restore
# writes a log, info prints the lines zigpy-cli prints — the identity only), systemctl (is-active from a state file),
# id (root), and the two python tools it drives as stubs in a fake TOOLS dir: zui-restore.py (DONE or FAIL by knob, argv
# recorded) and zradio-probe.py (--json with a home ID / node count / RF from the fake stick's state). The set is made
# the way zradio-sync's receive leaves it. Every path comes from the ZRADIO_APPLY_* env the tool offers.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-apply"

host() { # host <dir> [state: blank|converted|restored|stuck] [zui rc]
  # the fake stick's state: blank = its own home ID + 1 node, RF 9/14; converted = the image's home ID + 49 nodes but RF
  # 254/0 (what a converting pass left on the reference stick); restored = everything right; stuck = the home ID never
  # changes (what a raw pass alone did there). zui's fake advances blank→converted (converting) / converted→restored (raw)
  local d=$1 state=${2:-blank} zrc=${3:-0}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/tools" "$d/etc" "$d/zui" "$d/state" "$d/dev"; : > "$d/calls"
  echo '{"zwave": {"port": "/dev/zwave"}}' > "$d/zui/settings.json"
  : > "$d/dev/zwave"; : > "$d/dev/zigbee"
  printf 'ser2net=0\n' > "$d/units"
  printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "$d/etc/radios.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" sleep ':'
  fake "$d/bin" systemctl "case \"\$1\" in is-active) u=\${*: -1}; [ \"\$(sed -n \"s/^\$u=//p\" '$d/units')\" = 1 ];; *) echo \"systemctl: unexpected \$*\" >&2; exit 9;; esac"
  fake "$d/bin" podman "$rec; case \"\$1 \$2\" in '--version ') echo 'podman version 5.4.2';; 'image exists') [ -f '$d/noimage' ] && exit 1 || exit 0;; 'container exists') exit 1;; 'run -d') echo abc123;; 'stop -t') exit 0;; 'logs zradio-zui') echo 'INFO Z-WAVE: Controller status: Driver ready'; echo 'INFO Z-WAVE: Restoring NVM...';; 'rm -f') exit 0;; *) echo \"podman: unexpected \$*\" >&2; exit 9;; esac"
  fake "$d/bin" zigpy "$rec; case \"\$4\" in restore) echo 'Restoring network...'; echo 'Network key: DEADBEEF'; echo 'done';; info) printf 'PAN ID:                0x1A2B\\nExtended PAN ID:       dd:aa:00:11:22:33:44:55\\nChannel:               25\\nDevice IEEE:           00:12:4b:00:aa:bb:cc:dd\\nNWK:                   0x0000\\nNetwork key:           11223344556677889900aabbccddeeff\\nNetwork key counter:   1000600\\n';; *) exit 9;; esac"
  echo "$state" > "$d/stick"
  cat > "$d/tools/zui-restore.py" <<EOF
import sys
open("$d/calls", "a").write("zui-restore.py " + " ".join(sys.argv[1:]) + "\\n")
if $zrc: print("FAIL  restoreNVM refused: fake", file=sys.stderr); sys.exit($zrc)
mode = sys.argv[sys.argv.index("--mode") + 1]
st = open("$d/stick").read().strip()
if st == "stuck": pass
elif mode == "converting" and st == "blank": open("$d/stick", "w").write("converted")
elif mode == "raw" and st == "converted": open("$d/stick", "w").write("restored")
print("OK    the driver is up on the local stick"); print("DONE  restoreNVM(useRaw=%s) answered success after 15 s — stop the container NOW" % ("true" if mode == "raw" else "false"))
EOF
  cat > "$d/tools/zradio-probe.py" <<EOF
import json, sys
open("$d/calls", "a").write("zradio-probe.py " + " ".join(sys.argv[1:]) + "\\n")
st = open("$d/stick").read().strip()
view = {"blank": ("0xf4486cba", 1, 9, 14.0), "stuck": ("0xf4486cba", 49, 9, 14.0), "converted": ("0xdeadbeef", 49, 254, 0.0), "restored": ("0xdeadbeef", 49, 9, 14.0)}[st]
if "--soft-reset" in sys.argv: print("   NOTE  Z-Wave: SoftReset sent first", file=sys.stderr)
if "--rf-receive" in sys.argv: print("   NOTE  Z-Wave: RF receive mode %s (SetRFReceiveMode answered success)" % sys.argv[sys.argv.index("--rf-receive") + 1].upper(), file=sys.stderr)
print(json.dumps({"zwave": {"ok": True, "home_id_hex": view[0], "node_count": view[1], "sdk": "7.23.2", "rf": {"region": view[2], "tx_power_dbm": view[3]}, "verdict": "live"}}))
EOF
  mkset "$d/set"
}
mkset() { # mkset <dir> [region] [power]: a set as zradio-sync's receive leaves it
  mkdir -p "$1"; head -c 40960 /dev/zero > "$1/zwave-nvm.bin"; echo '{}' > "$1/zha-backup-restore.json"
  printf '{"format": "zradio sync v1", "sets": {"zwave": "sync-20261112T123000Z", "zigbee": "sync-20261112T123000Z"}, "identities": {"zwave": {"home_id": "0xdeadbeef", "nodes": 49, "rf_region": %s, "tx_power_dbm": %s}, "zigbee": {"ieee": "00:12:4b:00:aa:bb:cc:dd", "channel": 25, "pan_id": "1a2b"}}, "bump": {"from": 600, "to": 1000600, "how": "test"}}\n' "${2:-9}" "${3:-14.0}" > "$1/fetch.json"
}
run_tool() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_APPLY_TOOLS="$d/tools" ZRADIO_APPLY_STATE="$d/state.d" ZRADIO_APPLY_ZUI_STORE="$d/zui" ZRADIO_APPLY_ZIGPY="$d/bin/zigpy" ZRADIO_APPLY_ZWAVE_TTY="$d/dev/zwave" ZRADIO_APPLY_ZIGBEE_TTY="$d/dev/zigbee" ZRADIO_RADIOS="$d/etc/radios.conf" ZRADIO_CONF="$d/etc/none.conf" bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }

echo "-- report mode: every check OK, nothing run"
host "$T/r"; run_tool "$T/r" --from "$T/r/set"
check "exit 0" eq "$RC" 0
check "REPORT ONLY" has "$T/r/out" "REPORT ONLY — nothing changed"
check "names the set" has "$T/r/out" "WOULD use the set in $T/r/set"
check "image present (the built-in pin when there is no conf)" has "$T/r/out" "OK    image docker.io/zwavejs/zwave-js-ui:11.25.2 present"
check "nothing but the checks ran" eq "$(grep -cvE '^podman (--version|image exists|container exists)' "$T/r/calls")" 0
run_tool "$T/r"
check "no --from: usage, exit 2" eq "$RC" 2

echo "-- --run, both networks: the container around each pass, the probe, zigpy restore + info, the record"
host "$T/w"; run_tool "$T/w" --run --from "$T/w/set"
check "exit 0" eq "$RC" 0
check "two passes, each: run, stop -t 2, logs kept, rm -f" eq "$(grep -E '^podman (run|stop|logs|rm)' "$T/w/calls" | sed "s#$T/w##g; s# -p .*##" | tr '\n' ';')" "podman run -d --name zradio-zui --device /dev/zwave:/dev/zwave;podman stop -t 2 zradio-zui;podman logs zradio-zui;podman rm -f zradio-zui;podman run -d --name zradio-zui --device /dev/zwave:/dev/zwave;podman stop -t 2 zradio-zui;podman logs zradio-zui;podman rm -f zradio-zui;"
check "both container logs landed in the set's dir" bash -c 'grep -q "Driver ready" "$1/set/zui-converting.log" && grep -q "Driver ready" "$1/set/zui-raw.log"' _ "$T/w"
check "the passes: converting (no --force), then raw --force" eq "$(grep -oE '^zui-restore.py restore .*--mode (converting|raw)( --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180)( --force)?' "$T/w/calls" | sed 's/.*--mode //' | tr '\n' ';')" "converting --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180;raw --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180 --force;"
check "the probe calls: plain read; after each pass the receiver off at once, then --soft-reset + read; the receiver off once more at the end" eq "$(grep -oE '^zradio-probe.py --zwave [^ ]+( --soft-reset| --rf-receive off)? --json' "$T/w/calls" | sed 's/^zradio-probe.py --zwave [^ ]* //' | tr '\n' ';')" "--json;--rf-receive off --json;--soft-reset --json;--rf-receive off --json;--soft-reset --json;--rf-receive off --json;"
check "the receiver-off lines after each pass" bash -c 'grep -q "OK    the receiver is off right after the converting pass (try 1)" "$1" && grep -q "OK    the receiver is off right after the raw pass (try 1)" "$1"' _ "$T/w/out"
check "the receiver-off line at the end" has "$T/w/out" "OK    the stick's RF receiver is off until its next power-up"
check "the converting pass verified: home ID + nodes" has "$T/w/out" "OK    after the converting pass + SoftReset: home ID 0xdeadbeef with 49 nodes (serial read, no driver)"
check "the RF warn between the passes" has "$T/w/out" "WARN  RF before the raw pass: region '254' at '0' dBm"
check "the image and the expectations come from the set" has "$T/w/calls" "zui-restore.py restore --url http://127.0.0.1:8091 --nvm $T/w/set/zwave-nvm.bin --mode converting"
check "order: read, pass, stop, rf off, logs, read, pass, stop, rf off, logs, read, rf off" eq "$(grep -oE '^(zui-restore.py|podman stop|podman logs|zradio-probe.py)' "$T/w/calls" | tr '\n' ';')" "zradio-probe.py;zui-restore.py;podman stop;zradio-probe.py;podman logs;zradio-probe.py;zui-restore.py;podman stop;zradio-probe.py;podman logs;zradio-probe.py;zradio-probe.py;"
check "the raw pass verified: home ID kept, RF right" has "$T/w/out" "OK    after the raw pass + SoftReset: home ID 0xdeadbeef with 49 nodes, RF region 9 at 14 dBm"
check "zigpy restore on the coordinator with the raised backup" eq "$(grep -c "^zigpy radio znp $T/w/dev/zigbee restore $T/w/set/zha-backup-restore.json$" "$T/w/calls")" 1
check "zigpy restore's log kept, not shown (it holds the key)" bash -c '! grep -q "DEADBEEF" "$1/out" && grep -q "log lines kept in" "$1/out"' _ "$T/w"
check "zigpy info compared" has "$T/w/out" "OK    the coordinator reads IEEE 00:12:4b:00:aa:bb:cc:dd, PAN 0x1a2b, channel 25 (== the set)"
check "the network key never reaches the output" hasnt "$T/w/out" "11223344556677889900"
check "record written, naming the set" bash -c 'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); assert r[\"zwave\"][\"home_id_hex\"]==\"0xdeadbeef\" and r[\"zigbee\"][\"pan_id\"]==\"0x1a2b\" and r[\"fetch\"][\"sets\"][\"zwave\"]==\"sync-20261112T123000Z\"" "$1/state.d/last-restore.json"' _ "$T/w"
check "the done line hands over to the caller" has "$T/w/out" "the caller puts the sticks to silent standby next"

echo "-- --only zwave: no zigpy; --only zigbee: no podman run"
host "$T/o1"; run_tool "$T/o1" --run --only zwave --from "$T/o1/set"
check "exit 0, no zigpy" bash -c '[ "$2" = 0 ] && ! grep -q zigpy "$1/calls"' _ "$T/o1" "$RC"
host "$T/o2"; run_tool "$T/o2" --run --only zigbee --from "$T/o2/set"
check "exit 0, no container" bash -c '[ "$2" = 0 ] && ! grep -q "podman run" "$1/calls"' _ "$T/o2" "$RC"
host "$T/o3"; rm -f "$T/o3/dev/zigbee" "$T/o3/set/zha-backup-restore.json"; run_tool "$T/o3" --run --only zwave --from "$T/o3/set"
check "--only zwave on a VM with no Zigbee stick and a set without a Zigbee backup: exit 0" eq "$RC" 0

echo "-- a stick that keeps its home ID through the converting pass: FAIL after one pass, no zigbee step"
host "$T/f1" stuck; run_tool "$T/f1" --run --from "$T/f1/set"
check "exit 1" eq "$RC" 1
check "names what it read and expected" has "$T/f1/out" "FAIL  after the converting pass the stick reads home ID '0xf4486cba' with '49' nodes — expected 0xdeadbeef with 49"
check "container stopped regardless" has "$T/f1/calls" "podman stop -t 2 zradio-zui"
check "one pass only, no raw" eq "$(grep -c '^zui-restore.py' "$T/f1/calls")" 1
check "zigbee not attempted" hasnt "$T/f1/calls" "zigpy"

echo "-- a stick already converted (a re-run after a stop between the passes): the converting pass is skipped, the raw one runs"
host "$T/f2" converted; run_tool "$T/f2" --run --from "$T/f2/set"
check "exit 0" eq "$RC" 0
check "converting skipped" has "$T/f2/out" "OK    the stick already holds home ID 0xdeadbeef with 49 nodes — the converting pass is skipped"
check "only the raw pass ran" eq "$(grep -oE '^zui-restore.py restore .*--mode (converting|raw)' "$T/f2/calls" | sed 's/.*--mode //' | tr '\n' ';')" "raw;"
host "$T/f2b" restored; run_tool "$T/f2b" --run --from "$T/f2b/set"
check "a stick that already holds the set: both passes skipped, exit 0" bash -c '[ "$1" = 0 ] && ! grep -q "^zui-restore.py" "$2" && grep -q "the raw pass is skipped" "$3"' _ "$RC" "$T/f2b/calls" "$T/f2b/out"

echo "-- another set than the last one written: both passes forced although the stick already answers right"
host "$T/n1" restored; mkdir -p "$T/n1/state.d"; echo '{"ts": "old", "fetch": {"sets": {"zwave": "sync-20261111T123000Z"}}}' > "$T/n1/state.d/last-restore.json"; run_tool "$T/n1" --run --from "$T/n1/set"
check "exit 0" eq "$RC" 0
check "the WARN names both sets" has "$T/n1/out" "WARN  another set than the last one written (sync-20261111T123000Z → sync-20261112T123000Z): both passes run (--force)"
check "both passes with --force" eq "$(grep -oE '^zui-restore.py restore .*--mode (converting|raw).*' "$T/n1/calls" | grep -c -- '--force')" 2
host "$T/n2" restored; mkdir -p "$T/n2/state.d"; echo '{"ts": "old", "fetch": {"sets": {"zwave": "sync-20261112T123000Z"}}}' > "$T/n2/state.d/last-restore.json"; run_tool "$T/n2" --run --from "$T/n2/set"
check "the same set: nothing forced, passes skipped" bash -c '[ "$1" = 0 ] && ! grep -q "^zui-restore.py" "$2"' _ "$RC" "$T/n2/calls"
host "$T/n3" restored; mkdir -p "$T/n3/state.d"; echo '{"ts": "old", "fetch": {"sets": {"zwave": "sync-20261112T123000Z"}}}' > "$T/n3/state.d/last-restore.json"; run_tool "$T/n3" --run --force --from "$T/n3/set"
check "--force on the same set: both passes forced, exit 0" bash -c '[ "$1" = 0 ] && [ "$(grep -oE "^zui-restore.py restore .*--mode (converting|raw).*" "$2" | grep -c -- --force)" = 2 ]' _ "$RC" "$T/n3/calls"
check "--force says so" has "$T/n3/out" "WARN  --force: both passes run whatever the stick holds"

echo "-- the converting restore refused: FAIL after the container is stopped"
host "$T/f3" blank 1; run_tool "$T/f3" --run --from "$T/f3/set"
check "exit 1" eq "$RC" 1
check "stop came before the FAIL" eq "$(grep -oE '^(podman stop|zui-restore.py)' "$T/f3/calls" | tr '\n' ';')" "zui-restore.py;podman stop;"
check "names the pass and the rc" has "$T/f3/out" "FAIL  the converting pass did not succeed (rc 1)"

echo "-- refusals in the checks: nothing is written"
host "$T/x1"; sed -i 's/^ser2net=0/ser2net=1/' "$T/x1/units"; run_tool "$T/x1" --run --from "$T/x1/set"
check "ser2net active: refused, nothing run" bash -c '[ "$2" = 1 ] && grep -q "FAIL  ser2net is active — a radio VM that serves never writes over itself" "$1/out" && ! grep -q "podman run" "$1/calls"' _ "$T/x1" "$RC"
host "$T/x2"; : > "$T/x2/noimage"; run_tool "$T/x2" --run --from "$T/x2/set"
check "no image: refused, names the pull" has "$T/x2/out" "not present — the installer pulls it (podman pull docker.io/zwavejs/zwave-js-ui:11.25.2)"
host "$T/x3"; rm -f "$T/x3/set/zwave-nvm.bin"; run_tool "$T/x3" --run --from "$T/x3/set"
check "a set without the image: refused, nothing run" bash -c '[ "$2" = 1 ] && grep -q "no zwave-nvm.bin" "$1/out" && ! grep -q "podman run" "$1/calls"' _ "$T/x3" "$RC"
host "$T/x4"; rm -f "$T/x4/dev/zwave"; run_tool "$T/x4" --run --from "$T/x4/set"
check "the Z-Wave tty gone: refused" bash -c '[ "$2" = 1 ] && grep -q "FAIL  no .*/dev/zwave" "$1/out"' _ "$T/x4" "$RC"
host "$T/x5"; echo '{"sets": {"zwave": "s"}, "identities": {"zwave": {"home_id": "0xdeadbeef", "nodes": 49}}}' > "$T/x5/set/fetch.json"; run_tool "$T/x5" --run --only zwave --from "$T/x5/set"
check "a set that names no RF config to verify against: refused before any write" bash -c '[ "$2" = 1 ] && grep -q "names no Z-Wave identity" "$1/out" && ! grep -q "podman run" "$1/calls"' _ "$T/x5" "$RC"

echo "-- the set's own RF config is what the raw pass must leave; the image pin comes from the conf"
host "$T/fr2"; mkset "$T/fr2/set" 1 10; run_tool "$T/fr2" --run --from "$T/fr2/set"
check "a set that names another RF config (region 1 at 10 dBm): the stick's 9 at 14 is a FAIL, exit 1" bash -c '[ "$2" = 1 ] && grep -q "expected 0xdeadbeef / 49 / 1 at 10" "$1/out"' _ "$T/fr2" "$RC"
host "$T/im"; printf '%s\n' NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 ZUI_IMAGE=docker.io/zwavejs/zwave-js-ui:12.0.1 > "$T/im/etc/none.conf"; run_tool "$T/im" --from "$T/im/set"
check "ZUI_IMAGE in zradio.conf is the image used" has "$T/im/out" "OK    image docker.io/zwavejs/zwave-js-ui:12.0.1 present"

echo "-- --help"
OUT=$(bash "$TOOL" --help 2>&1); RC=$?
check "exit 0" eq "$RC" 0
check "names the steps" eq "$(printf '%s\n' "$OUT" | grep -c '^#   [0-4]\.')" 5

finish
