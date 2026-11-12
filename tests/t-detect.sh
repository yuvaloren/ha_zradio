#!/usr/bin/env bash
# t-detect.sh — guest/sbin/zradio-detect against a fake radio VM: a /dev with ttyUSB files, udevadm as a fake that
# prints each port's properties from a file (the property names and values are the ones udev printed for the reference
# sticks) and, on `trigger`, makes the SYMLINKs the written rules ask for; zradio-probe.py as a stub that answers per
# port and protocol from a knob file, or not at all; systemctl for ser2net's state. The real guest/lib/usb-ids.json is
# the list. Nothing reaches a stick.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-detect"
vm() { local d=$1; rm -rf "$d"; mkdir -p "$d/bin" "$d/dev" "$d/udev" "$d/answers" "$d/etc" "$d/rules.d"; : > "$d/calls"; echo 0 > "$d/ser2net"
  fake "$d/bin" systemctl "[ \"\$(cat '$d/ser2net')\" = 1 ]"
  fake "$d/bin" udevadm "case \"\$1\" in
    info) cat '$d/udev/'\$(basename \"\${*: -1}\") 2>/dev/null;;
    trigger) echo \"udevadm \$*\" >> '$d/calls'; for f in '$d'/rules.d/*.rules; do [ -f \"\$f\" ] || continue; grep -o 'SYMLINK+=\"[^\"]*\"' \"\$f\" | sed 's/.*=\"//; s/\"//' | while read -r n; do : > '$d/dev/'\$n; done; done;;
    *) echo \"udevadm \$*\" >> '$d/calls';; esac"
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
port() { # port <dir> <ttyname> <vid> <pid> <ID_MODEL> <iface> [serial] [ID_VENDOR]
  : > "$1/dev/$2"; printf 'DEVNAME=/dev/%s\nID_VENDOR_ID=%s\nID_MODEL_ID=%s\nID_MODEL=%s\nID_USB_INTERFACE_NUM=%s\nID_SERIAL_SHORT=%s\nID_VENDOR=%s\n' "$2" "$3" "$4" "$5" "$6" "${7:-S1}" "${8:-Silicon_Labs}" > "$1/udev/$2"; }
zw() { # zw <dir> <tty> [live|blank] [chip] [man type id]
  printf '{"verdict": "%s", "chip": "%s", "sdk": "7.23.2", "home_id_hex": "0xd1a2b3c4", "node_count": %s, "manufacturer_id": %s, "product_type": %s, "product_id": %s}\n' "${3:-live}" "${4:-0x08/0x00}" "$([ "${3:-live}" = live ] && echo 49 || echo 1)" "${5:-881}" "${6:-4}" "${7:-60}" > "$1/answers/$2.zwave"; }
zb() { printf '{"verdict": "%s", "version": "2.7.1", "code_revision": 20230507, "ieee": "00:12:4b:00:aa:bb:cc:dd", "device_state_name": "InitializedNotStarted"}\n' "${3:-live}" > "$1/answers/$2.zigbee"; }
det() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_DETECT_DEV="$d/dev" ZRADIO_DETECT_PROBE="$d/probe.py" ZRADIO_DETECT_ETC="$d/etc" ZRADIO_DETECT_UDEV_RULES="$d/rules.d/99-zradio.rules" python3 "$TOOL" "$@" > "$d/out" 2> "$d/err"; RC=$?; }
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
check "each port got its own protocol's probe only; the Aeotec's Zigbee port (no probe for EZSP) was sent nothing" eq "$(sort "$T/a/calls" | tr '\n' ';')" "probe zigbee ttyUSB0;probe zwave ttyUSB2;"
check "the Aeotec's Zigbee side is named and passed over, with the way to choose it" bash -c 'grep -q "^NOTE  .*/dev/ttyUSB1 is also a Zigbee radio .* NOT used: .*/dev/ttyUSB0 was chosen (it answered a probe). To use it instead: --use zigbee=" "$1/out"' _ "$T/a"
ref "$T/a2" blank; det "$T/a2"
check "the same sticks blank (a new standby): the same choice" bash -c '[ "$2" = 0 ] && grep -q "^Z-Wave: SYNCED on .*/ttyUSB2" "$1/out" && grep -q "^Zigbee: SYNCED on .*/ttyUSB0" "$1/out"' _ "$T/a2" "$RC"

echo "-- --write: radios.conf, radios.json, the udev names"
ref "$T/w"; det "$T/w" --write
check "exit 0, DONE" bash -c '[ "$2" = 0 ] && grep -q "^DONE  " "$1/out"' _ "$T/w" "$RC"
check "radios.conf: the levels, families, names and serial settings" eq "$(grep -v '^#' "$T/w/etc/radios.conf" | tr '\n' ';')" "ZWAVE=synced;ZWAVE_FAMILY=zwave-800;ZWAVE_TTY=/dev/zradio-zwave;ZWAVE_BAUD=115200;ZWAVE_FLOW=none;ZIGBEE=synced;ZIGBEE_FAMILY=znp;ZIGBEE_TTY=/dev/zradio-zigbee;ZIGBEE_BAUD=115200;ZIGBEE_FLOW=none;"
check "the shell tools accept the file as written" bash -c '. "$1/guest/lib/zradio-common.sh"; ZR_RADIOS="$2" zr_load_radios && zr_has zwave synced && zr_has zigbee synced && [ "$ZIGBEE_FAMILY" = znp ]' _ "$KIT" "$T/w/etc/radios.conf"
check "the Z-Wave rule: by ids, product string and port number, no serial" has "$T/w/rules.d/99-zradio.rules" 'SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="10c4", ENV{ID_MODEL_ID}=="ea70", ENV{ID_MODEL}=="CP2105_Dual_USB_to_UART_Bridge_Controller", ENV{ID_USB_INTERFACE_NUM}=="01", SYMLINK+="zradio-zwave"'
check "the Zigbee rule" has "$T/w/rules.d/99-zradio.rules" 'SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="10c4", ENV{ID_MODEL_ID}=="ea60", ENV{ID_MODEL}=="Sonoff_Zigbee_3.0_USB_Dongle_Plus", ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="zradio-zigbee"'
check "udev reloaded and triggered; the names exist" bash -c 'grep -q "udevadm control --reload" "$1/calls" && grep -q "udevadm trigger" "$1/calls" && [ -e "$1/dev/zradio-zwave" ] && [ -e "$1/dev/zradio-zigbee" ]' _ "$T/w"
check "radios.json holds the identities the probes read, and every port" bash -c 'python3 -c "import json,sys; j=json.load(open(sys.argv[1])); assert j[\"radios\"][\"zwave\"][\"identity\"][\"home_id_hex\"]==\"0xd1a2b3c4\" and j[\"radios\"][\"zigbee\"][\"level\"]==\"synced\" and len(j[\"ports\"])==3" "$1/etc/radios.json"' _ "$T/w"
det "$T/w" --json
check "--json: the result on stdout, the table on stderr" bash -c 'python3 -c "import json,sys; j=json.load(open(sys.argv[1])); assert j[\"radios\"][\"zwave\"][\"level\"]==\"synced\"" "$1/out" && grep -q "USB serial ports" "$1/err"' _ "$T/w"

echo "-- other families: served only, said plainly"
vm "$T/c"; port "$T/c" ttyACM0 1cf1 0030 ConBee_II 00 DE1 dresden_elektronik_ingenieurtechnik_GmbH; det "$T/c" --write
check "a ConBee II: Zigbee SERVED (deconz), no Z-Wave, exit 0" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SERVED on " "$1/out" && grep -q "^Z-Wave: none" "$1/out" && grep -q "NOT silenced and NOT copied (family deconz is not proven" "$1/out"' _ "$T/c" "$RC"
check "nothing was sent to it" eq "$(grep -c '^probe' "$T/c/calls")" 0
check "its serial settings are flagged as unverified" has "$T/c/out" "come from the list and are not verified on this model"
check "radios.conf: ZWAVE=none, ZIGBEE=served" eq "$(grep -v '^#' "$T/c/etc/radios.conf" | head -3 | tr '\n' ';')" "ZWAVE=none;ZIGBEE=served;ZIGBEE_FAMILY=deconz;"
vm "$T/c2"; port "$T/c2" ttyACM0 0658 0200 "" 00 "" 0658; zw "$T/c2" ttyACM0 live 0x05/0x00 134 1 90; det "$T/c2"
check "a 500-series Z-Wave stick (chip 0x05): SERVED (zwave-500)" bash -c '[ "$2" = 0 ] && grep -q "^Z-Wave: SERVED on " "$1/out" && grep -q "family zwave-500 is not proven" "$1/out"' _ "$T/c2" "$RC"
vm "$T/c3"; port "$T/c3" ttyUSB0 10c4 ea60 Zooz_ZST39_800_Z-Wave_Stick 00; zw "$T/c3" ttyUSB0 live 0x08/0x00 634 4 1552; det "$T/c3"
check "a stick that is in no list but answers the Z-Wave Serial API as 800 series: found, synced" bash -c '[ "$2" = 0 ] && grep -q "^Z-Wave: SYNCED on " "$1/out"' _ "$T/c3" "$RC"
check "…it got both probes in turn until one answered (Z-Wave first)" eq "$(tr '\n' ';' < "$T/c3/calls")" "probe zwave ttyUSB0;"
vm "$T/c4"; port "$T/c4" ttyUSB0 0403 6001 FT232R_USB_UART 00 FT1 FTDI; zb "$T/c4" ttyUSB0; det "$T/c4"
check "an unlisted bridge that answers ZNP: Zigbee synced (znp); both probes were tried" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SYNCED on " "$1/out" && [ "$(tr "\n" ";" < "$1/calls")" = "probe zwave ttyUSB0;probe zigbee ttyUSB0;" ]' _ "$T/c4" "$RC"
vm "$T/c5"; port "$T/c5" ttyUSB0 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 00 X; port "$T/c5" ttyUSB1 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 01 X
zw "$T/c5" ttyUSB1 live 0x07/0x00 881 4 60; det "$T/c5"
check "the proven product wins over an unexpected chip byte: the Aeotec is synced whatever its chip byte reads" bash -c 'grep -q "^Z-Wave: SYNCED on " "$1/out"' _ "$T/c5"
check "an Aeotec alone: its own Zigbee port is the Zigbee radio, served (ezsp)" bash -c 'grep -q "^Zigbee: SERVED on .*/ttyUSB0" "$1/out"' _ "$T/c5"

echo "-- not radios; nothing found"
vm "$T/n"; port "$T/n" ttyUSB0 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 00 X; port "$T/n" ttyUSB1 10c4 ea70 CP2105_Dual_USB_to_UART_Bridge_Controller 01 X
port "$T/n" ttyUSB2 067b 2303 USB-Serial_Controller 00 P1 Prolific; det "$T/n" --write
check "a CP2105 that answers nothing and a console cable: no radio, exit 1, nothing written" bash -c '[ "$2" = 1 ] && grep -q "FAIL  no Z-Wave or Zigbee stick found" "$1/out" && grep -q "nothing was written" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/n" "$RC"
check "the CP2105's port 0 is not taken for a Zigbee radio when port 1 is no Z-Wave controller" has "$T/n/out" "did not answer: not a radio"
vm "$T/n2"; det "$T/n2"
check "no serial port at all: exit 1, says to check the passthrough" bash -c '[ "$2" = 1 ] && grep -q "is the USB device passed through" "$1/out"' _ "$T/n2" "$RC"

echo "-- two sticks of one kind"
ref "$T/t"; port "$T/t" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/t" ttyUSB3 live; det "$T/t" --write
check "two coordinators that both hold a network: undecided, exit 1, nothing written" bash -c '[ "$2" = 1 ] && grep -q "FAIL  two Zigbee sticks the kit cannot choose between" "$1/out" && [ ! -e "$1/etc/radios.conf" ]' _ "$T/t" "$RC"
det "$T/t" --use zigbee="$T/t/dev/ttyUSB3" --write
check "--use names one: exit 0, that port gets the name" bash -c '[ "$2" = 0 ] && grep -q "ZigStar_UZG-01" "$1/rules.d/99-zradio.rules" && grep -q "^Zigbee: SYNCED on .*/ttyUSB3" "$1/out"' _ "$T/t" "$RC"
ref "$T/t2"; port "$T/t2" ttyUSB3 1a86 7523 ZigStar_UZG-01 00 Z9 QinHeng; zb "$T/t2" ttyUSB3 blank; det "$T/t2"
check "one holds a network, one is blank: the one with the network is chosen, the other named" bash -c '[ "$2" = 0 ] && grep -q "^Zigbee: SYNCED on .*/ttyUSB0" "$1/out" && grep -q "NOTE  .*/ttyUSB3 is also a Zigbee radio" "$1/out"' _ "$T/t2" "$RC"
vm "$T/t3"; port "$T/t3" ttyUSB0 10c4 ea60 Sonoff_Zigbee_3.0_USB_Dongle_Plus 00 A ITead; port "$T/t3" ttyUSB1 10c4 ea60 Sonoff_Zigbee_3.0_USB_Dongle_Plus 00 B ITead
zb "$T/t3" ttyUSB0 live; zb "$T/t3" ttyUSB1 blank; det "$T/t3" --write
check "two sticks of the same model: the rule for the chosen one carries its serial" has "$T/t3/rules.d/99-zradio.rules" 'ENV{ID_SERIAL_SHORT}=="A", SYMLINK+="zradio-zigbee"'

echo "-- refusals"
ref "$T/s"; echo 1 > "$T/s/ser2net"; det "$T/s" --write
check "on a VM that serves: refused, no probe sent, nothing written" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: ser2net is active" "$1/err" && [ ! -s "$1/calls" ] && [ ! -e "$1/etc/radios.conf" ]' _ "$T/s" "$RC"
det "$T/s" --no-probe
check "--no-probe there: the list's view, nothing sent" bash -c '[ "$2" = 0 ] && grep -q "not probed (--no-probe)" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/s" "$RC"
det "$T/s" --no-probe --write
check "--write without the probe: refused (exit 2)" eq "$RC" 2
det "$T/a" --use zwave=ttyUSB2
check "--use with a name that is not a path: usage (exit 2)" eq "$RC" 2
det "$T/a" --use zigbee=/dev/nonesuch
check "--use for a port that is not there: exit 1, said" bash -c '[ "$2" = 1 ] && grep -q "no such serial port here" "$1/out"' _ "$T/a" "$RC"
check "--help: exit 0, names the levels" bash -c 'python3 "$1" --help | grep -q "synced   Z-Wave 800 series"' _ "$TOOL"
finish
