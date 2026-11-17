#!/usr/bin/env bash
# tests/hass-real.sh — Home Assistant's side on the kind of machine Home Assistant's terminal is (the Terminal & SSH
# app: Alpine Linux, busybox for tar, sed, head and ping, bash, curl, jq, and no python). Not one of tests/run.sh's
# files: it needs docker and the network (Alpine's packages). Linux or macOS:
#   bash tests/hass-real.sh
# Real: get.sh — the release looked up, the archive unpacked, the commit read from its header — then ./install.sh
# handing over to homeassistant/install.sh, all with that machine's own tools. The kit comes from this folder, packed
# the way GitHub packs a release (no tests/, the commit in the archive's header) and served from files.
# Not real: Home Assistant. Its list of integrations is a stand-in with made-up keys; no Home Assistant runs here,
# and nothing connects to a radio.
. "$(dirname "$0")/lib.sh"
IMAGE=alpine:3.24      # Home Assistant's Terminal & SSH app 10.6 is Alpine 3.24
KEY=5ec4e75ec4e75ec4e75ec4e75ec4e7aa
if ! docker info >/dev/null 2>&1; then      # no docker on a developer's machine: nothing to test. In CI that is a failure, not a pass
  [ -z "${CI:-}" ] || check "docker answers here (CI: this test must run)" false
  echo "SKIP  docker does not answer here: nothing was tested"; finish; exit
fi
chmod 755 "$T"; R=yuvaloren/ha_zradio
mkdir -p "$T/site/$R/archive" "$T/site/api/repos/$R/releases" "$T/config-a/.storage" "$T/config-b/.storage"
cp "$KIT/get.sh" "$T/get.sh"
( cd "$KIT" && git ls-files -co --exclude-standard | grep -vE '^(tests|\.github)/|^\.gitattributes$' ) | python3 -c '
import sys, tarfile
kit, out = sys.argv[1:3]
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT, pax_headers={"comment": "0123456789abcdef0123456789abcdef01234567"}) as t:
    for f in sys.stdin.read().split("\n"):
        if f: t.add(kit + "/" + f, arcname="ha_zradio-x/" + f)
' "$KIT" "$T/site/$R/archive/v9.9.9.tar.gz" || { echo "could not pack the kit"; exit 2; }
cp "$T/site/$R/archive/v9.9.9.tar.gz" "$T/site/$R/archive/main.tar.gz"
printf '{\n  "url": "https://api.github.com/repos/%s/releases/1",\n  "tag_name": "v9.9.9",\n  "name": "v9.9.9",\n  "draft": false\n}\n' "$R" > "$T/site/api/repos/$R/releases/latest"
entries() { printf '{"version": 1, "key": "core.config_entries", "data": {"entries": [{"domain": "sun", "disabled_by": null, "data": {}}, {"domain": "zha", "disabled_by": null, "data": {"device": {"path": "%s", "baudrate": 115200, "flow_control": null}, "radio_type": "znp"}}, {"domain": "zwave_js", "disabled_by": null, "data": {"use_addon": %s, "url": "%s", "usb_path": %s, "socket_path": null, "s0_legacy_key": "%s", "s2_access_control_key": "%s"}}]}}\n' "$1" "$2" "$3" "$4" "$KEY" "$KEY"; }
entries socket://192.0.2.50:6638 false ws://a0d7b954-zwavejs2mqtt:3000 null > "$T/config-a/.storage/core.config_entries"
entries /dev/serial/by-id/usb-ITead_Sonoff-if00-port0 true ws://core-zwave-js:3000 '"/dev/ttyACM0"' > "$T/config-b/.storage/core.config_entries"
chmod -R a+rX "$T"

# in the container: as Home Assistant's terminal has it — its token in the environment, its settings at /config
docker run --rm -v "$T":/t:ro -e SUPERVISOR_TOKEN=stand-in "$IMAGE" sh -c '
  apk add --no-cache bash jq curl >/dev/null 2>&1 || { echo "APK FAILED"; exit 9; }
  command -v python3 >/dev/null 2>&1 && echo "PYTHON IS HERE"
  ls -l /bin/tar /bin/sed | grep -c busybox | sed "s/^/BUSYBOX TOOLS: /"
  mkdir /config && cp -R /t/config-a/.storage /config/
  export ZRADIO_GITHUB=file:///t/site ZRADIO_GITHUB_API=file:///t/site/api
  echo "=== A"; bash /t/get.sh --radios 192.0.2.50; echo "rc=$?"; echo "version=$(cat /opt/ha_zradio/v9.9.9/gen/version)"; ls /opt/ha_zradio/v9.9.9 | tr "\n" " "; echo
  echo "=== B"; ZRADIO_REF=main bash /t/get.sh --radios 127.0.0.1 --config /t/config-b; echo "rc=$?"; echo "version=$(cat /opt/ha_zradio/main/gen/version)"
  echo "=== C"; bash /t/get.sh; echo "rc=$?"
' > "$T/out" 2>&1; RC=$?
A=$(sed -n '/^=== A$/,/^=== B$/p' "$T/out"); B=$(sed -n '/^=== B$/,/^=== C$/p' "$T/out"); C=$(sed -n '/^=== C$/,$p' "$T/out")

echo "-- Home Assistant's terminal's kind of machine: Alpine, busybox, no python"
check "the container ran; it has no python, and its tar and sed are busybox's" bash -c '[ "$2" = 0 ] && ! grep -q "APK FAILED\|PYTHON IS HERE" "$1/out" && grep -qx "BUSYBOX TOOLS: 2" "$1/out"' _ "$T" "$RC"; [ "$FAIL" = 0 ] || cat "$T/out"
echo "-- the kit's install line there, on a Home Assistant that uses the pair already (Z-Wave through the Z-Wave JS UI app)"
check "get.sh: the latest release found, unpacked into /opt/ha_zradio/v9.9.9, the version written; no tests in it" bash -c 'grep -q "^== ha_zradio v9.9.9, from file:///t/site/" <<< "$1" && grep -qx "version=v9.9.9" <<< "$1" && grep -q "^LICENSE README.md .*homeassistant host install.sh vote" <<< "$1" && ! grep -qw tests <<< "$1"' _ "$A"
check "./install.sh sees Home Assistant (no option names it) and hands over" bash -c 'grep -q "^This is Home Assistant, not a Proxmox node" <<< "$1" && grep -q "^== Home Assistant and the radio pair at 192.0.2.50 (a look only" <<< "$1"' _ "$A"
check "an address that does not answer: a NOTE (busybox's ping), and it goes on" bash -c 'grep -q "^   NOTE  192.0.2.50 does not answer a ping from here" <<< "$1"' _ "$A"
check "Zigbee OK, Z-Wave CHECK, exit 0" bash -c 'grep -q "^   OK    Zigbee (ZHA) uses the pair: socket://192.0.2.50:6638" <<< "$1" && grep -q "^   CHECK Z-Wave: Home Assistant talks to the Z-Wave JS UI app (ws://a0d7b954-zwavejs2mqtt:3000)" <<< "$1" && grep -q "it has to be  tcp://192.0.2.50:6639" <<< "$1" && grep -qx "rc=0" <<< "$1"' _ "$A"
echo "-- a branch, and a Home Assistant with the sticks in its own machine"
check "the commit is read from the archive's header by busybox's tools: main@0123456" bash -c 'grep -qx "version=main@0123456" <<< "$1" && grep -q "(commit 0123456789ab)" <<< "$1"' _ "$B"
check "an address that answers: OK" bash -c 'grep -q "^   OK    127.0.0.1 answers a ping from here" <<< "$1"' _ "$B"
check "two TODO with what each uses now and the steps; the line to check afterward; exit 0" bash -c 'grep -q "^   TODO  Zigbee (ZHA) uses /dev/serial/by-id/usb-ITead_Sonoff-if00-port0 now (znp), not the pair" <<< "$1" && grep -q "^   TODO  Z-Wave (the Z-Wave JS app) uses /dev/ttyACM0 now, not the pair" <<< "$1" && grep -q "4. \"Serial device path\": type  socket://127.0.0.1:6638$" <<< "$1" && grep -qx "== 2 to do (TODO). Nothing was changed. ==" <<< "$1" && grep -q "Afterward, this again checks it: .* _ --radios 127.0.0.1 --config /t/config-b$" <<< "$1" && grep -qx "rc=0" <<< "$1"' _ "$B"
echo "-- the bare install line: no address given"
check "the address is found in Home Assistant's own settings (ZHA's path), said to be taken from there, and the look goes on; exit 0" bash -c 'grep -q "     - Zigbee (ZHA) is set to socket://192.0.2.50:6638" <<< "$1" && grep -q "^   NOTE  192.0.2.50 is taken as the pair.s floating address from Home Assistant.s own settings" <<< "$1" && grep -q "^   OK    Zigbee (ZHA) uses the pair" <<< "$1" && grep -qx "rc=0" <<< "$1"' _ "$C"
check "no key of a network anywhere in what was said" bash -c '! grep -q "$2" "$1/out"' _ "$T" "$KEY"
finish
