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
  fake "$d/bin" podman "$rec; case \"\$1 \$2\" in '--version ') echo 'podman version 5.4.2';; 'image exists') [ -f '$d/noimage' ] && exit 1 || exit 0;; 'container exists') [ -f '$d/ct-there' ];; 'run -d') [ ! -f '$d/run-fail' ] || { echo 'Error: crun: open /dev/zwave: Permission denied' >&2; exit 126; }; echo abc123;; 'stop -t') exit 0;; 'logs zradio-zui') echo 'INFO Z-WAVE: Controller status: Driver ready'; echo 'INFO Z-WAVE: Restoring NVM...';; 'rm -f') exit 0;; *) echo \"podman: unexpected \$*\" >&2; exit 9;; esac"
  fake "$d/bin" zigpy "$rec; [ ! -f '$d/zb-hangs' ] || [ \"\$4\" != restore ] || { echo \$\$ > '$d/zb-pid'; exec /bin/sleep 300; }; case \"\$4\" in restore) echo 'Restoring network...'; echo 'Network key: DEADBEEF'; echo 'done';; info) printf 'PAN ID:                0x1A2B\\nExtended PAN ID:       dd:aa:00:11:22:33:44:55\\nChannel:               25\\nDevice IEEE:           00:12:4b:00:aa:bb:cc:dd\\nNWK:                   0x0000\\nNetwork key:           11223344556677889900aabbccddeeff\\n'; c=\$(cat '$d/zb-counter' 2>/dev/null || echo 1000600); [ \"\$c\" = none ] || printf 'Network key counter:   %s\\n' \"\$c\";; *) exit 9;; esac"
  echo "$state" > "$d/stick"
  cat > "$d/tools/zui-restore.py" <<EOF
import sys
open("$d/calls", "a").write("zui-restore.py " + " ".join(sys.argv[1:]) + "\\n")
import os, time
if os.path.exists("$d/pass-hangs"): open("$d/in-pass", "w").close(); time.sleep(6)
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
run_tool() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_APPLY_RUN="$d/run" ZRADIO_APPLY_TOOLS="$d/tools" ZRADIO_APPLY_STATE="$d/state.d" ZRADIO_APPLY_ZUI_STORE="$d/zui" ZRADIO_APPLY_ZIGPY="$d/bin/zigpy" ZRADIO_APPLY_ZWAVE_TTY="$d/dev/zwave" ZRADIO_APPLY_ZIGBEE_TTY="$d/dev/zigbee" ZRADIO_RADIOS="$d/etc/radios.conf" ZRADIO_CONF="$d/etc/none.conf" bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }

echo "-- report mode: every check OK, nothing run"
host "$T/r"; run_tool "$T/r" --from "$T/r/set"
check "exit 0" eq "$RC" 0
check "REPORT ONLY" has "$T/r/out" "REPORT ONLY — nothing changed"
check "names the set" has "$T/r/out" "WOULD use the set in $T/r/set"
check "image present (the built-in pin when there is no conf)" has "$T/r/out" "OK    image docker.io/zwavejs/zwave-js-ui:11.27.0@sha256:0f3ad23ccf5ff2256ad8cc060ab0fc987b8f52a8427eac337f93b058fa628f35 present"
check "nothing but the checks ran" eq "$(grep -cvE '^podman (--version|image exists|container exists)' "$T/r/calls")" 0
: > "$T/r/ct-there"; : > "$T/r/calls"; run_tool "$T/r" --from "$T/r/set"
check "a Z-Wave JS UI container is there (a write under way): a look does not remove it, and says that --run would" bash -c '! grep -q "^podman rm" "$1/calls" && grep -q "container is there (a write under way, or a stale one): --run removes it first" "$1/out"' _ "$T/r"
rm "$T/r/ct-there"
run_tool "$T/r"
check "no --from: usage, exit 2" eq "$RC" 2

echo "-- --run, both networks: the container around each pass, the probe, zigpy restore + info, the record"
host "$T/w"; run_tool "$T/w" --run --from "$T/w/set"
check "exit 0" eq "$RC" 0
check "two passes, each: run, stop -t 2, logs kept, rm -f" eq "$(grep -E '^podman (run|stop|logs|rm)' "$T/w/calls" | sed "s#$T/w##g; s# -p .*##" | tr '\n' ';')" "podman run -d --name zradio-zui --pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges --device /dev/zwave:/dev/zwave;podman stop -t 2 zradio-zui;podman logs zradio-zui;podman rm -f zradio-zui;podman run -d --name zradio-zui --pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges --device /dev/zwave:/dev/zwave;podman stop -t 2 zradio-zui;podman logs zradio-zui;podman rm -f zradio-zui;"
check "both container logs landed in the set's dir" bash -c 'grep -q "Driver ready" "$1/set/zui-converting.log" && grep -q "Driver ready" "$1/set/zui-raw.log"' _ "$T/w"
check "the passes: converting, then raw — both with --force on a VM with no record of this set" eq "$(grep -oE '^zui-restore.py restore .*--mode (converting|raw)( --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180)( --force)?' "$T/w/calls" | sed 's/.*--mode //' | tr '\n' ';')" "converting --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180 --force;raw --expect-home-id 0xdeadbeef --expect-nodes 49 --wait 180 --force;"
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
host "$T/f2" converted; mkdir -p "$T/f2/state.d"; echo sync-20261112T123000Z > "$T/f2/state.d/restore-began-zwave"      # the write of this set began here, and stopped
run_tool "$T/f2" --run --from "$T/f2/set"
check "exit 0" eq "$RC" 0
check "converting skipped" has "$T/f2/out" "OK    the stick already holds home ID 0xdeadbeef with 49 nodes — the converting pass is skipped"
check "only the raw pass ran" eq "$(grep -oE '^zui-restore.py restore .*--mode (converting|raw)' "$T/f2/calls" | sed 's/.*--mode //' | tr '\n' ';')" "raw;"
host "$T/f2b" restored; mkdir -p "$T/f2b/state.d"; echo sync-20261112T123000Z > "$T/f2b/state.d/restore-began-zwave"; run_tool "$T/f2b" --run --from "$T/f2b/set"
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
check "no image: refused, names the pull" has "$T/x2/out" "not present — the installer pulls it (podman pull docker.io/zwavejs/zwave-js-ui:11.27.0@sha256:0f3ad23ccf5ff2256ad8cc060ab0fc987b8f52a8427eac337f93b058fa628f35)"
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

echo "-- the stick must hold THIS set: both passes unless the last record names it"
host "$T/f1" restored; run_tool "$T/f1" --run --only zwave --from "$T/f1/set"
check "no record of an earlier write (a rebuilt VM with its old stick) and the stick already answers right: both passes run all the same" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^podman run " "$1/calls")" = 2 ] && grep -q "no record that this set was written here" "$1/out"' _ "$T/f1" "$RC"
: > "$T/f1/calls"; run_tool "$T/f1" --run --only zwave --from "$T/f1/set"
check "…the same set again (a re-run): the record names it, nothing is written twice" bash -c '[ "$2" = 0 ] && ! grep -q "^podman run " "$1/calls"' _ "$T/f1" "$RC"
host "$T/f2" restored; mkdir -p "$T/f2/state.d"; echo '{"fetch": {"sets": {"zigbee": "sync-20261112T123000Z"}}}' > "$T/f2/state.d/last-restore.json"; run_tool "$T/f2" --run --only zwave --from "$T/f2/set"
check "the last record is of a Zigbee-only write (a raised counter): it names no Z-Wave set, so both passes run" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^podman run " "$1/calls")" = 2 ]' _ "$T/f2" "$RC"

echo "-- the Zigbee frame counter is read back"
host "$T/c1"; echo 600 > "$T/c1/zb-counter"; run_tool "$T/c1" --run --only zigbee --from "$T/c1/set"
check "the coordinator reads a counter BELOW the one written: FAIL (devices drop frames whose counter they have seen)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the coordinator.s frame counter reads 600, below the 1000600 that was written" "$1/out"' _ "$T/c1" "$RC"
host "$T/c2"; echo 1000700 > "$T/c2/zb-counter"; run_tool "$T/c2" --run --only zigbee --from "$T/c2/set"
check "at or above it: OK, and said" bash -c '[ "$2" = 0 ] && grep -q "OK    the coordinator.s frame counter reads 1000700 (written: 1000600)" "$1/out"' _ "$T/c2" "$RC"
host "$T/c3"; echo none > "$T/c3/zb-counter"; run_tool "$T/c3" --run --only zigbee --from "$T/c3/set"
check "zigpy names no counter: a warning that it was not read back, and the write stands" bash -c '[ "$2" = 0 ] && grep -q "WARN  zigpy.s info names no frame counter" "$1/out"' _ "$T/c3" "$RC"
check "the network key that zigpy's info prints is never shown" bash -c '! grep -q "11223344556677889900aabbccddeeff" "$1/out" "$2/out" "$3/out"' _ "$T/c1" "$T/c2" "$T/c3"

echo "-- the container: started with the least it needs, never pulled here, and never left running"
host "$T/h1"; run_tool "$T/h1" --run --only zwave --from "$T/h1/set"
check "podman run: no pull at a write (a sync must not depend on the internet), no capabilities but the one a device file may need, no new privileges" bash -c 'grep "^podman run " "$1/calls" | head -1 | grep -q -- "-d --name zradio-zui --pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges --device "' _ "$T/h1"
host "$T/h2"; : > "$T/h2/run-fail"; run_tool "$T/h2" --run --only zwave --from "$T/h2/set"
check "podman run fails: FAIL with what podman said" bash -c '[ "$2" = 1 ] && grep -q "FAIL  podman run zradio-zui failed: Error: crun: open /dev/zwave: Permission denied" "$1/out"' _ "$T/h2" "$RC"
host "$T/h3"; : > "$T/h3/pass-hangs"
( PATH="$T/h3/bin:$PATH" ZRADIO_APPLY_RUN="$T/h3/run" ZRADIO_APPLY_TOOLS="$T/h3/tools" ZRADIO_APPLY_STATE="$T/h3/state.d" ZRADIO_APPLY_ZUI_STORE="$T/h3/zui" ZRADIO_APPLY_ZIGPY="$T/h3/bin/zigpy" ZRADIO_APPLY_ZWAVE_TTY="$T/h3/dev/zwave" ZRADIO_APPLY_ZIGBEE_TTY="$T/h3/dev/zigbee" ZRADIO_RADIOS="$T/h3/etc/radios.conf" ZRADIO_CONF="$T/h3/etc/none.conf" exec bash "$TOOL" --run --only zwave --from "$T/h3/set" ) > "$T/h3/out" 2>&1 & KP=$!
for _ in $(seq 1 100); do [ -e "$T/h3/in-pass" ] && break; command -p sleep 0.1; done
kill -TERM "$KP"; wait "$KP" 2>/dev/null
check "the writer is killed during a pass (a timeout, a stopped unit): the container does not stay on the stick, and the receiver is turned off" bash -c 'a=$(grep -n "^podman run " "$1/calls" | tail -1 | cut -d: -f1) && r=$(grep -n "^podman rm -f zradio-zui" "$1/calls" | tail -1 | cut -d: -f1) && o=$(grep -n -- "--rf-receive off" "$1/calls" | tail -1 | cut -d: -f1) && [ -n "$a" ] && [ -n "$r" ] && [ -n "$o" ] && [ "$a" -lt "$r" ] && [ "$a" -lt "$o" ]' _ "$T/h3"

host "$T/h4"; : > "$T/h4/zb-hangs"
( PATH="$T/h4/bin:$PATH" ZRADIO_APPLY_RUN="$T/h4/run" ZRADIO_APPLY_TOOLS="$T/h4/tools" ZRADIO_APPLY_STATE="$T/h4/state.d" ZRADIO_APPLY_ZUI_STORE="$T/h4/zui" ZRADIO_APPLY_ZIGPY="$T/h4/bin/zigpy" ZRADIO_APPLY_ZWAVE_TTY="$T/h4/dev/zwave" ZRADIO_APPLY_ZIGBEE_TTY="$T/h4/dev/zigbee" ZRADIO_RADIOS="$T/h4/etc/radios.conf" ZRADIO_CONF="$T/h4/etc/none.conf" timeout -k 2 3 bash "$TOOL" --run --only zigbee --from "$T/h4/set" ) > "$T/h4/out" 2>&1; RC=$?
check "the write's time limit (zradio-sync's, around the whole writer) ends while zigpy runs: zigpy ends with it — it is not left restoring a coordinator that is silenced the next moment" bash -c '[ "$2" = 124 ] && [ -s "$1/zb-pid" ] && ! kill -0 "$(cat "$1/zb-pid")" 2>/dev/null' _ "$T/h4" "$RC"
kill "$(cat "$T/h4/zb-pid" 2>/dev/null)" 2>/dev/null

echo "-- never on a VM that holds the role"
host "$T/g1"; mkdir -p "$T/g1/run"; echo "MASTER 2026-11-12T00:00:00Z priority=100" > "$T/g1/run/role"; run_tool "$T/g1" --run --from "$T/g1/set"
check "keepalived's last word is MASTER (ser2net may be stopped for a read): refused, nothing written" bash -c '[ "$2" = 1 ] && grep -q "FAIL  keepalived.s last word here is MASTER" "$1/out" && ! grep -qE "^(podman run|zigpy)" "$1/calls"' _ "$T/g1" "$RC"

echo "-- --help"
OUT=$(bash "$TOOL" --help 2>&1); RC=$?
check "exit 0" eq "$RC" 0
check "names the steps" eq "$(printf '%s\n' "$OUT" | grep -c '^#   [0-4]\.')" 5

finish
