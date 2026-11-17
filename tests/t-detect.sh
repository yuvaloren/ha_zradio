#!/usr/bin/env bash
# t-detect.sh — guest/sbin/zradio-detect against a fake radio VM: a /dev with ttyUSB files, udevadm as a fake that
# prints each port's properties from a file (the property names and values are the ones udev printed for the reference
# sticks) and, on `trigger`, makes the SYMLINKs the written rules ask for; zradio-probe.py as a stub that answers per
# port and protocol from a knob file, or not at all; systemctl for ser2net's state. The list is the real table, built
# as an install builds it (from the tests' copies of Home Assistant's lists). Nothing reaches a stick.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-detect"
python3 "$KIT/guest/lib/zradio-usb-ids.py" --out "$T/usb-ids.json" 2>/dev/null || { echo "t-detect.sh: the table did not build"; exit 1; }
export ZRADIO_DETECT_IDS="$T/usb-ids.json"
vm() { local d=$1; rm -rf "$d"; mkdir -p "$d/bin" "$d/dev" "$d/udev" "$d/answers" "$d/etc" "$d/rules.d"; : > "$d/calls"; echo 0 > "$d/ser2net"
  fake "$d/bin" systemctl "[ \"\$(cat '$d/ser2net')\" = 1 ]"
  fake "$d/bin" udevadm "case \"\$1\" in
    info) cat '$d/udev/'\$(basename \"\${*: -1}\") 2>/dev/null;;
    trigger) echo \"udevadm \$*\" >> '$d/calls'; python3 '$d/trigger.py' '$d';;
    *) echo \"udevadm \$*\" >> '$d/calls';; esac"
  cat > "$d/trigger.py" <<'PY'
# what udev does with the written rules: a SYMLINK goes to the port whose properties match every ENV{…} of its rule.
# Two ports that match: the last one gets the name (with udev, whichever comes last — it can change at a reboot).
# A name no rule gives any more is taken away. <dir>/misname: the port that gets every name, whatever the rules say
# (a rule that matches the wrong port).
import glob, os, re, sys
d = sys.argv[1]
for link in glob.glob(d + "/dev/zradio-*"): os.remove(link)
for f in glob.glob(d + "/rules.d/*.rules"):
    for line in open(f):
        m = re.search(r'SYMLINK\+="([^"]*)"', line)
        if not m: continue
        conds = re.findall(r'ENV\{(\w+)\}=="((?:[^"\\]|\\.)*)"', line)
        match = []
        for u in sorted(glob.glob(d + "/udev/*")):
            props = dict(l.rstrip("\n").split("=", 1) for l in open(u) if "=" in l)
            if all(props.get(k, "") == v for k, v in conds): match.append(os.path.basename(u))
        if os.path.exists(d + "/misname"): match = [open(d + "/misname").read().strip()]
        link = os.path.join(d, "dev", m.group(1))
        if os.path.lexists(link): os.remove(link)
        if match: os.symlink(os.path.join(d, "dev", match[-1]), link)
PY
  cat > "$d/probe.py" <<PY
import json, os, sys
kind = "zwave" if "--zwave" in sys.argv else "zigbee"
tty = sys.argv[sys.argv.index("--" + kind) + 1]
open("$d/calls", "a").write("probe %s %s\n" % (kind, os.path.basename(tty)))
f = "$d/answers/%s.%s" % (os.path.basename(tty), kind)
if os.path.exists(f): print(json.dumps({kind: dict(json.load(open(f)), ok=True)}))
else:
    print("   FAIL  no answer", file=sys.stderr); print(json.dumps({kind: {"ok": False, "error": "no answer within the budget"}})); sys.exit(1)
PY
}
port() { # port <dir> <ttyname> <vid> <pid> <ID_MODEL> <iface> [serial] [ID_VENDOR] [ID_PATH | none]: by default each port has a USB path of its own
  : > "$1/dev/$2"; printf 'DEVNAME=/dev/%s\nID_VENDOR_ID=%s\nID_MODEL_ID=%s\nID_MODEL=%s\nID_USB_INTERFACE_NUM=%s\nID_SERIAL_SHORT=%s\nID_VENDOR=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "${7-S1}" "${8:-Silicon_Labs}" > "$1/udev/$2"
  [ "${9:-}" = none ] || printf 'ID_PATH=%s\n' "${9:-pci-0000:00:14.0-usb-0:${2#tty}:1.$6}" >> "$1/udev/$2"; }
zw() { # zw <dir> <tty> [live|blank|unknown] [chip] [man type id]
  printf '{"verdict": "%s", "chip": "%s", "sdk": "7.23.2", "home_id_hex": "0xd1a2b3c4", "node_count": %s, %s}\n' \
    "${3:-live}" "${4:-0x08/0x00}" "$([ "${3:-live}" = live ] && echo 49 || echo 1)" \
    "$(printf '"manufacturer_id": %s, "product_type": %s, "product_id": %s' "${5:-881}" "${6:-4}" "${7:-60}")" > "$1/answers/$2.zwave"; }
zb() { # zb <dir> <tty> [live|blank|unknown] [Z-Stack: 3|1.2]
  printf '{"verdict": "%s", "zstack": "%s", "version": "2.7.1", "code_revision": 20230507, "ieee": "00:12:4b:00:aa:bb:cc:dd", "device_state_name": "InitializedNotStarted"}\n' \
  "${3:-live}" "${4:-3}" > "$1/answers/$2.zigbee"; }
det() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_DETECT_DEV="$d/dev" ZRADIO_DETECT_PROBE="$d/probe.py" ZRADIO_DETECT_ETC="${ETC_DIR:-$d/etc}" ZRADIO_DETECT_LOCK="$d/sticks.lock" ZRADIO_DETECT_LOCK_WAIT=1 \
  ZRADIO_DETECT_UDEV_RULES="$d/rules.d/99-zradio.rules" python3 "$TOOL" "$@" > "$d/out" 2> "$d/err"; RC=$?; }
ref() { # the reference set: a Sonoff ZBDongle-P and an Aeotec Z-Stick 10 Pro (two ports)
  vm "$1"; port "$1" ttyUSB0 10c4 ea60 Sonoff_Zigbee_3.0_USB_Dongle_Plus 00 SONOFF1 ITead
  port "$1" ttyUSB1 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 00 AEO1
  port "$1" ttyUSB2 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 01 AEO1
  zb "$1" ttyUSB0 "${2:-live}"; zw "$1" ttyUSB2 "${2:-live}"; }

echo "-- the reference sticks: both found, both synced, nothing typed"
ref "$T/a"; det "$T/a"
check "exit 0, report only" bash -c '[ "$2" = 0 ] && grep -q "REPORT ONLY" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/a" "$RC"
check "Z-Wave: synced on the Aeotec's port 1" bash -c 'grep -q "^Z-Wave: SYNCED on .*/dev/ttyUSB2" "$1/out"' _ "$T/a"
check "Zigbee: synced on the Sonoff" bash -c 'grep -q "^Zigbee: SYNCED on .*/dev/ttyUSB0" "$1/out"' _ "$T/a"
check "each port got its own protocol's probe only; the Aeotec's Zigbee port (no probe for EZSP) was sent nothing" \
  eq "$(sort "$T/a/calls" | tr '\n' ';')" "probe zigbee ttyUSB0;probe zwave ttyUSB2;"
check "the Aeotec's Zigbee side is named and passed over, with the way to choose it" bash -c \
  'grep -q "^NOTE  .*/dev/ttyUSB1 is also a Zigbee radio .* NOT used: .*/dev/ttyUSB0 was chosen (it answered a probe)\. To use it instead: --use zigbee=" \
     "$1/out"' \
  _ "$T/a"
ref "$T/a2" blank; det "$T/a2"
check "the same sticks blank (a new standby): the same choice" bash -c '[ "$2" = 0 ] && grep -q "^Z-Wave: SYNCED on .*/ttyUSB2" "$1/out" &&
  grep -q "^Zigbee: SYNCED on .*/ttyUSB0" "$1/out"' _ "$T/a2" "$RC"

echo "-- --write: radios.conf, radios.json, the udev names"
ref "$T/w"; det "$T/w" --write
check "exit 0, DONE" bash -c '[ "$2" = 0 ] && grep -q "^DONE  " "$1/out"' _ "$T/w" "$RC"
want="ZWAVE=synced;ZWAVE_FAMILY=zwave-800;ZWAVE_TTY=/dev/zradio-zwave;ZWAVE_BAUD=115200;ZWAVE_FLOW=none;"
want+="ZIGBEE=synced;ZIGBEE_FAMILY=znp;ZIGBEE_TTY=/dev/zradio-zigbee;ZIGBEE_BAUD=115200;ZIGBEE_FLOW=none;"
check "radios.conf: the levels, families, names and serial settings" eq "$(grep -v '^#' "$T/w/etc/radios.conf" | tr '\n' ';')" "$want"
check "the shell tools accept the file as written" bash -c '. "$1/guest/lib/zradio-common.sh"; ZR_RADIOS="$2" zr_load_radios &&
  zr_has zwave synced && zr_has zigbee synced && [ "$ZIGBEE_FAMILY" = znp ]' _ "$KIT" "$T/w/etc/radios.conf"
check "the Z-Wave rule: by ids, product string and port number, no serial" has "$T/w/rules.d/99-zradio.rules" \
  'SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="10c4", ENV{ID_MODEL_ID}=="ea70", ENV{ID_MODEL}=="CP2105_Dual_USB_to_UART_Bridge_Controller", '\
'ENV{ID_USB_INTERFACE_NUM}=="01", SYMLINK+="zradio-zwave"'
check "the Zigbee rule" has "$T/w/rules.d/99-zradio.rules" \
  'SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="10c4", ENV{ID_MODEL_ID}=="ea60", ENV{ID_MODEL}=="Sonoff_Zigbee_3.0_USB_Dongle_Plus", '\
'ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="zradio-zigbee"'
check "udev reloaded and triggered; the names exist" bash -c 'grep -q "udevadm control --reload" "$1/calls" &&
  grep -q "udevadm trigger" "$1/calls" && [ -e "$1/dev/zradio-zwave" ] && [ -e "$1/dev/zradio-zigbee" ]' _ "$T/w"
check "radios.json holds the identities the probes read, and every port" bash -c \
  'python3 -c "import json,sys; j=json.load(open(sys.argv[1])); r=j[\"radios\"]
assert r[\"zwave\"][\"identity\"][\"home_id_hex\"]==\"0xd1a2b3c4\" and r[\"zigbee\"][\"level\"]==\"synced\" and len(j[\"ports\"])==3" "$1/etc/radios.json"' \
  _ "$T/w"
det "$T/w" --json
check "--json: the result on stdout, the table on stderr" bash -c \
  'python3 -c "import json,sys; j=json.load(open(sys.argv[1])); assert j[\"radios\"][\"zwave\"][\"level\"]==\"synced\"" "$1/out" &&
  grep -q "USB serial ports" "$1/err"' _ "$T/w"

echo "-- other families: served only, said plainly"
vm "$T/c"; port "$T/c" ttyACM0 1cf1 0030 ConBee_II 00 DE1 dresden_elektronik_ingenieurtechnik_GmbH; det "$T/c" --write
check "a ConBee II: Zigbee SERVED (deconz), no Z-Wave, exit 0" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SERVED on " "$1/out" &&
  grep -q "^Z-Wave: none" "$1/out" && grep -q "NOT silenced and NOT copied (family deconz is not proven" "$1/out"' _ "$T/c" "$RC"
check "nothing was sent to it" eq "$(grep -c '^probe' "$T/c/calls")" 0
check "its serial settings are flagged as unverified" has "$T/c/out" "come from the list and are not verified on this model"
check "radios.conf: ZWAVE=none, ZIGBEE=served" eq "$(grep -v '^#' "$T/c/etc/radios.conf" | head -3 | tr '\n' ';')" \
  "ZWAVE=none;ZIGBEE=served;ZIGBEE_FAMILY=deconz;"
vm "$T/c2"; port "$T/c2" ttyACM0 0658 0200 "" 00 "" 0658; zw "$T/c2" ttyACM0 live 0x05/0x00 134 1 90; det "$T/c2"
check "a 500-series Z-Wave stick (chip 0x05): SERVED (zwave-500)" bash -c '[ "$2" = 0 ] && grep -q "^Z-Wave: SERVED on " "$1/out" &&
  grep -q "family zwave-500 is not proven" "$1/out"' _ "$T/c2" "$RC"
vm "$T/c3"; port "$T/c3" ttyUSB0 10c4 ea60 Zooz_ZST39_800_Z-Wave_Stick 00; zw "$T/c3" ttyUSB0 live 0x08/0x00 634 4 1552; det "$T/c3"
check "a stick that is in no list but answers the Z-Wave Serial API as 800 series: found, synced" bash -c '[ "$2" = 0 ] &&
  grep -q "^Z-Wave: SYNCED on " "$1/out"' _ "$T/c3" "$RC"
check "…it got both probes in turn until one answered (Z-Wave first)" eq "$(tr '\n' ';' < "$T/c3/calls")" "probe zwave ttyUSB0;"
vm "$T/c4"; port "$T/c4" ttyUSB0 0403 6001 FT232R_USB_UART 00 FT1 FTDI; zb "$T/c4" ttyUSB0; det "$T/c4"
check "an unlisted bridge that answers ZNP: Zigbee synced (znp); both probes were tried" bash -c '[ "$2" = 0 ] &&
  grep -q "^Zigbee: SYNCED on " "$1/out" && [ "$(tr "\n" ";" < "$1/calls")" = "probe zwave ttyUSB0;probe zigbee ttyUSB0;" ]' _ "$T/c4" "$RC"
vm "$T/c5"; port "$T/c5" ttyUSB0 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 00 X; port "$T/c5" ttyUSB1 10c4 ea70 \
  CP2105_Dual_USB_to_UART_Bridge_Controller 01 X
zw "$T/c5" ttyUSB1 live 0x07/0x00 881 4 60; det "$T/c5"
check "the proven product wins over an unexpected chip byte: the Aeotec is synced whatever its chip byte reads" bash -c \
  'grep -q "^Z-Wave: SYNCED on " "$1/out"' _ "$T/c5"
check "an Aeotec alone: its own Zigbee port is the Zigbee radio, served (ezsp)" bash -c 'grep -q "^Zigbee: SERVED on .*/ttyUSB0" "$1/out"' _ "$T/c5"
vm "$T/c6"; port "$T/c6" ttyUSB0 10c4 8b34 BV_2010_10 00 B1 Bitron_Video; printf 'ID_MODEL_ENC=BV\\x202010\\x2f10\n' >> "$T/c6/udev/ttyUSB0"; det "$T/c6" --write
check "a product string with a slash (udev's ID_MODEL has _ in its place): matched by ID_MODEL_ENC — the Bitron stick is Zigbee SERVED (ezsp), sent nothing" \
  bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SERVED on .*/ttyUSB0" "$1/out" && grep -q "BV 2010/10" "$1/out" && grep -q "^ZIGBEE_FAMILY=ezsp$" "$1/etc/radios.conf" &&
  ! grep -q "^probe" "$1/calls"' _ "$T/c6" "$RC"
check "…and its udev rule names it by udev's own ID_MODEL" has "$T/c6/rules.d/99-zradio.rules" 'ENV{ID_MODEL}=="BV_2010_10"'
vm "$T/c7"; port "$T/c7" ttyACM0 0451 16a8 TI_CC2531_USB_CDC 00 C1 Texas_Instruments; zb "$T/c7" ttyACM0 unknown 1.2; det "$T/c7" --json
check "a coordinator that answers ZNP as Z-Stack Home 1.2 (a CC2531): SERVED (znp-legacy), never synced; whether it holds a network is not known" bash -c \
  '[ "$2" = 0 ] && grep -q "^Zigbee: SERVED on .*family znp-legacy is not proven" "$1/err" && python3 -c "import json,sys; z=json.load(open(sys.argv[1]))[\"radios\"][\"zigbee\"]
assert (z[\"level\"], z[\"family\"], z[\"holds_network\"]) == (\"served\", \"znp-legacy\", None), z" "$1/out"' _ "$T/c7" "$RC"
ref "$T/c8"; zw "$T/c8" ttyUSB2 unknown; det "$T/c8" --json
check "a Z-Wave controller whose Long Range nodes could not be read: neither blank nor holding a network (the installer decides nothing on it)" bash -c \
  '[ "$2" = 0 ] && grep -q "cannot tell whether it holds a network" "$1/err" && python3 -c "import json,sys; z=json.load(open(sys.argv[1]))[\"radios\"][\"zwave\"]
assert z[\"level\"] == \"synced\" and z[\"holds_network\"] is None, z" "$1/out"' _ "$T/c8" "$RC"

echo "-- not radios; nothing found"
vm "$T/n"; port "$T/n" ttyUSB0 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 00 X; port "$T/n" ttyUSB1 10c4 ea70 \
  CP2105_Dual_USB_to_UART_Bridge_Controller 01 X
port "$T/n" ttyUSB2 067b 2303 USB-Serial_Controller 00 P1 Prolific; det "$T/n" --write
check "a CP2105 that answers nothing and a console cable: no radio, exit 1, nothing written" bash -c '[ "$2" = 1 ] &&
  grep -q "FAIL  no Z-Wave or Zigbee stick found" "$1/out" && grep -q "nothing was written" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/n" "$RC"
check "the CP2105's port 0 is not taken for a Zigbee radio when port 1 is no Z-Wave controller" has "$T/n/out" "did not answer: not a radio"
vm "$T/n2"; det "$T/n2"
check "no serial port at all: exit 1, says to check the passthrough" bash -c '[ "$2" = 1 ] && grep -q "is the USB device passed through" "$1/out"' _ \
  "$T/n2" "$RC"

echo "-- two sticks of one kind"
ref "$T/t"; port "$T/t" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/t" ttyUSB3 live; det "$T/t" --write
check "two coordinators that both hold a network: undecided, exit 1, nothing written" bash -c '[ "$2" = 1 ] &&
  grep -q "FAIL  two Zigbee sticks the kit cannot choose between" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/t" "$RC"
det "$T/t" --use zigbee="$T/t/dev/ttyUSB3" --write
check "--use names one: exit 0, that port gets the name" bash -c '[ "$2" = 0 ] && grep -q "ZigStar_UZG-01" "$1/rules.d/99-zradio.rules" &&
  grep -q "^Zigbee: SYNCED on .*/ttyUSB3" "$1/out"' _ "$T/t" "$RC"
ref "$T/t2"; port "$T/t2" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/t2" ttyUSB3 blank; det "$T/t2"
check "one holds a network, one is blank: the one with the network is chosen, the other named" bash -c '[ "$2" = 0 ] &&
  grep -q "^Zigbee: SYNCED on .*/ttyUSB0" "$1/out" && grep -q "NOTE  .*/ttyUSB3 is also a Zigbee radio" "$1/out"' _ "$T/t2" "$RC"
vm "$T/t3"; port "$T/t3" ttyUSB0 10c4 ea60 Sonoff_Zigbee_3.0_USB_Dongle_Plus 00 A ITead; port "$T/t3" ttyUSB1 10c4 ea60 \
  Sonoff_Zigbee_3.0_USB_Dongle_Plus 00 B ITead
zb "$T/t3" ttyUSB0 live; zb "$T/t3" ttyUSB1 blank; det "$T/t3" --write
check "two sticks of the same model: the rule for the chosen one carries its serial" has "$T/t3/rules.d/99-zradio.rules" \
  'ENV{ID_SERIAL_SHORT}=="A", SYMLINK+="zradio-zigbee"'

echo "-- refusals"
ref "$T/s"; echo 1 > "$T/s/ser2net"; det "$T/s" --write
check "on a VM that serves: refused, no probe sent, nothing written" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: ser2net is active" "$1/err" &&
  [ ! -s "$1/calls" ] && [ ! -e "$1/etc/radios.conf" ]' _ "$T/s" "$RC"
det "$T/s" --no-probe
check "--no-probe there: the list's view, nothing sent" bash -c '[ "$2" = 0 ] && grep -q "not probed (--no-probe)" "$1/out" && [ ! -s "$1/calls" ]' _ \
  "$T/s" "$RC"
det "$T/s" --no-probe --write
check "--write without the probe: refused (exit 2)" eq "$RC" 2
det "$T/a" --use zwave=ttyUSB2
check "--use with a name that is not a path: usage (exit 2)" eq "$RC" 2
det "$T/a" --use zigbee=/dev/nonesuch
check "--use for a port that is not there: exit 1, said" bash -c '[ "$2" = 1 ] && grep -q "no such serial port here" "$1/out"' _ "$T/a" "$RC"
det "$T/a" --use zigbee="$T/a/dev/ttyUSB2:znp" --write
check "--use zigbee= for the port that answered the Z-Wave probe: refused, nothing written — the stick's own answer stands" bash -c '[ "$2" = 1 ] &&
  grep -q "FAIL  --use zigbee=.*/ttyUSB2: that port answered the Z-Wave probe" "$1/out" && ! grep -q "^Zigbee: .* on .*/ttyUSB2" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/a" "$RC"
det "$T/a" --use zwave="$T/a/dev/ttyUSB1" --use zigbee="$T/a/dev/ttyUSB1"
check "--use names one port for both kinds: usage (exit 2), no probe sent" bash -c '[ "$2" = 2 ] && grep -q "one port is one radio" "$1/err"' _ "$T/a" "$RC"
det "$T/c2" --use zwave="$T/c2/dev/ttyACM0:zwave-800"
check "--use with a family the stick's own answer contradicts (a 500 series named zwave-800): refused, not raised to synced" bash -c '[ "$2" = 1 ] &&
  grep -q "FAIL  --use zwave=.*/ttyACM0:zwave-800: the stick answered as zwave-500" "$1/out" && ! grep -q SYNCED "$1/out"' _ "$T/c2" "$RC"
ref "$T/x1"; ZRADIO_DETECT_SYSTEMCTL="$T/x1/no-such-systemctl" det "$T/x1"
check "systemctl cannot be run: refused in the tool's own words (it cannot tell whether this VM serves), no traceback, no probe sent" bash -c '[ "$2" = 1 ] &&
  grep -q "^REFUSED: cannot tell whether this VM serves" "$1/err" && ! grep -q Traceback "$1/err" && [ ! -s "$1/calls" ]' _ "$T/x1" "$RC"
check "--help: exit 0, names the levels" bash -c 'python3 "$1" --help | grep -q "synced   Z-Wave 800 series"' _ "$TOOL"

echo "-- a name must land on the stick that was chosen: two sticks udev cannot tell apart; a rule that matches another port"
twins() { vm "$1"; port "$1" ttyUSB0 1a86 7523 ZigStar_UZG-01 00 0001 QinHeng "${2:-}"; port "$1" ttyUSB1 1a86 7523 ZigStar_UZG-01 00 0001 QinHeng "${2:-}"; zb "$1" ttyUSB0 live; zb "$1" ttyUSB1 blank; }
twins "$T/q1"; det "$T/q1" --write
check "two sticks with the same id, product and serial (a clone's factory serial): the rule names the chosen one by the USB port it is in" bash -c '[ "$2" = 0 ] && grep -q "ENV{ID_PATH}==\"pci-0000:00:14.0-usb-0:USB0:1.00\", SYMLINK+=\"zradio-zigbee\"" "$1/rules.d/99-zradio.rules" && ! grep -q ID_SERIAL_SHORT "$1/rules.d/99-zradio.rules"' _ "$T/q1" "$RC"; [ "$FAIL" = 0 ] || cat "$T/q1/out" "$T/q1/rules.d/99-zradio.rules"
check "…and the name is the chosen port's, not its twin's" eq "$(basename "$(readlink "$T/q1/dev/zradio-zigbee")")" ttyUSB0
twins "$T/q2" none; det "$T/q2" --write
check "…with nothing udev knows that sets them apart: FAIL, exit 1, nothing written — never a name that either stick may get" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*ttyUSB0 and .*ttyUSB1 cannot be told apart" "$1/out" && grep -q "nothing was written" "$1/out" && [ ! -e "$1/etc/radios.conf" ] && [ ! -e "$1/rules.d/99-zradio.rules" ]' _ "$T/q2" "$RC"
ref "$T/q3"; echo ttyUSB1 > "$T/q3/misname"; det "$T/q3" --write
check "udev gives a name to another port than the one chosen: FAIL naming both, exit 1 (the name existing is not enough)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  udev gave /dev/zradio-zigbee to .*ttyUSB1, not to .*ttyUSB0" "$1/out" && ! grep -q "^DONE" "$1/out"' _ "$T/q3" "$RC"
check "…and nothing stays behind that names a device the kit must not use: no radios.conf, no radios.json, the rules taken back" bash -c \
  '[ ! -e "$1/etc/radios.conf" ] && [ ! -e "$1/etc/radios.json" ] && [ ! -e "$1/rules.d/99-zradio.rules" ] && grep -q "nothing was written" "$1/out"' _ "$T/q3"
ref "$T/q3b"; det "$T/q3b" --write; mkdir "$T/q3b/was"; cp "$T/q3b/etc/radios.conf" "$T/q3b/etc/radios.json" "$T/q3b/rules.d/99-zradio.rules" "$T/q3b/was/"
port "$T/q3b" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/q3b" ttyUSB3 live; echo ttyUSB1 > "$T/q3b/misname"
det "$T/q3b" --use zigbee="$T/q3b/dev/ttyUSB3" --write
check "the same on a VM detected before: exit 1, and radios.conf, radios.json and the rules are the earlier run's, byte for byte" bash -c '[ "$2" = 1 ] &&
  cmp -s "$1/was/radios.conf" "$1/etc/radios.conf" && cmp -s "$1/was/radios.json" "$1/etc/radios.json" && cmp -s "$1/was/99-zradio.rules" "$1/rules.d/99-zradio.rules" &&
  grep -q "are as they were before this run" "$1/out"' _ "$T/q3b" "$RC"
ref "$T/q3c"; ETC_DIR="$T/q3c/calls/etc" det "$T/q3c" --write
check "radios.conf cannot be written (its folder cannot be made): the tool's own FAIL line, exit 1, no traceback, the rules taken back" bash -c '[ "$2" = 1 ] &&
  grep -q "^FAIL  .*radios.* not written" "$1/out" && ! grep -q Traceback "$1/err" && [ ! -e "$1/rules.d/99-zradio.rules" ]' _ "$T/q3c" "$RC"

echo "-- a stick the list names and that does not answer its own protocol is never taken as it is"
ref "$T/q4"; rm "$T/q4/answers/ttyUSB0.zigbee"; det "$T/q4" --write
check "the Sonoff (Z-Stack by the list) does not answer: FAIL with how to try again or name it, exit 1, nothing written — the Aeotec's own Zigbee port is NOT taken in its place" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*ttyUSB0 is a Zigbee stick by the list (.*) and did not answer the Zigbee probe" "$1/out" && grep -q -- "--use zigbee=.*ttyUSB0:znp" "$1/out" && ! grep -q "^Zigbee: SERVED" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/q4" "$RC"; [ "$FAIL" = 0 ] || cat "$T/q4/out"
det "$T/q4" --use zigbee="$T/q4/dev/ttyUSB0:znp" --write
check "…named by hand: taken, served (a level is only as good as what the stick answered)" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SERVED on .*/ttyUSB0" "$1/out"' _ "$T/q4" "$RC"
ref "$T/q5"; rm "$T/q5/answers/ttyUSB0.zigbee"; port "$T/q5" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/q5" ttyUSB3 live; det "$T/q5"
check "…another Zigbee stick answered: that one is chosen, and the silent one is named as not used" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SYNCED on .*/ttyUSB3" "$1/out" && grep -q "NOTE  .*/ttyUSB0 is also a Zigbee radio" "$1/out"' _ "$T/q5" "$RC"

echo "-- the sticks lock: detection does not talk to a stick while another tool of the kit does"
ref "$T/q6"; flock "$T/q6/sticks.lock" sleep 3 & LP=$!; sleep 0.5; det "$T/q6" --write; wait $LP 2>/dev/null      # (the holder is left to end: its sleep keeps the lock)
check "the lock is held (a hush, a sync): refused after the wait, no probe sent, nothing written" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: the sticks are in use by another zradio tool" "$1/err" && [ ! -s "$1/calls" ] && [ ! -e "$1/etc/radios.conf" ]' _ "$T/q6" "$RC"
det "$T/q6" --write
check "…free again: detection runs" eq "$RC" 0

echo "-- the table's sources are checked before anything is built from them: the pin, each list's shape and size"
tbl() { rm -rf "$1"; mkdir -p "$1/lib" "$1/src"; cp "$KIT/guest/lib/zradio-usb-ids.py" "$KIT/guest/lib/usb-annotations.json" "$1/lib/"
  cp -R "$TESTS_DIR/fixtures/ha-core/." "$1/src/"; echo old > "$1/ids.json"; }
build() { ZRADIO_USB_IDS_SOURCE="$1/src" python3 "$1/lib/zradio-usb-ids.py" --out "$1/ids.json" > "$1/out" 2> "$1/err"; RC=$?; }
said() { [ "$RC" = 1 ] && grep -q "^FAIL  .*$2" "$1/err" && ! grep -q Traceback "$1/err" && [ "$(cat "$1/ids.json")" = old ]; }   # said <dir> <text>: refused in one FAIL line, the table as it was
tbl "$T/i0"; build "$T/i0"
check "the kit's own pin and the lists as they are: built" bash -c '[ "$2" = 0 ] && grep -q "\"entries\"" "$1/ids.json"' _ "$T/i0" "$RC"
tbl "$T/i1"; sed -i 's/"home_assistant_core_commit": "[0-9a-f]*"/"home_assistant_core_commit": "main"/' "$T/i1/lib/usb-annotations.json"; build "$T/i1"
check "the pin is a branch name, not a commit: refused (a branch moves; every install must build the same table)" said "$T/i1" "home_assistant_core_commit"
tbl "$T/i2"; echo '[]' > "$T/i2/src/zha/manifest.json"; build "$T/i2"
check "a list that is JSON of another shape: refused, no traceback" said "$T/i2" "Home Assistant's USB list for zha"
tbl "$T/i3"; echo '{"usb": [{"vid": 4292, "pid": "EA60", "description": "*x*", "known_devices": ["x"]}]}' > "$T/i3/src/zha/manifest.json"; build "$T/i3"
check "an entry whose vid is not a string: refused, no traceback" said "$T/i3" "Home Assistant's USB list for zha"
tbl "$T/i4"; echo '{"usb": [{"vid": "10C4", "pid": "EA60", "description": "*x*", "known_devices": "x"}]}' > "$T/i4/src/zha/manifest.json"; build "$T/i4"
check "an entry whose known_devices is not a list (it would stop every detection): refused" said "$T/i4" "Home Assistant's USB list for zha"
tbl "$T/i5"; python3 -c 'import json, sys; json.dump({"usb": [], "pad": "x" * (1 << 21)}, open(sys.argv[1], "w"))' "$T/i5/src/zha/manifest.json"; build "$T/i5"
check "a list of 2 MB (the real ones are a few kB): not read to the end, refused" said "$T/i5" "larger than"
finish
