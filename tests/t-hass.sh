#!/usr/bin/env bash
# t-hass.sh — Home Assistant's side (homeassistant/install.sh): what it says about a Home Assistant's Z-Wave and
# Zigbee, against stand-ins for Home Assistant's list of integrations (<config>/.storage/core.config_entries) with
# made-up keys in them. Real: the script and jq. A fake: ping. Also here: ./install.sh handing over to it, and get.sh
# on a machine without python (Home Assistant's terminal has none).
# The terminal app's own kind of machine (Alpine, busybox): tests/hass-real.sh.
. "$(dirname "$0")/lib.sh"
HASS_TOOL="$KIT/homeassistant/install.sh"
KEY=5ec4e75ec4e75ec4e75ec4e75ec4e7aa      # stands in for a network's key: it must never be shown

ha() { # ha <dir> <zha entry | -> <zwave_js entry | ->: a Home Assistant config folder with those entries and one other
  local d=$1; rm -rf "$d"; mkdir -p "$d/config/.storage" "$d/bin"
  python3 - "$d/config/.storage/core.config_entries" "$2" "$3" <<'PY'
import json, sys
out, zha, zw = sys.argv[1:4]
e = [{"domain": "sun", "disabled_by": None, "data": {}}]
if zha != "-": e.append({"domain": "zha", "disabled_by": None, "data": json.loads(zha)})
if zw != "-": e.append({"domain": "zwave_js", "disabled_by": None, "data": json.loads(zw)})
json.dump({"version": 1, "minor_version": 5, "key": "core.config_entries", "data": {"entries": e}}, open(out, "w"))
PY
  fake "$d/bin" ping "[ ! -f '$d/no-ping' ]"
}
zha() { printf '{"device": {"path": "%s", "baudrate": 115200, "flow_control": null}, "radio_type": "znp"}' "$1"; }
zw() { printf '{"use_addon": %s, "url": "%s", "usb_path": %s, "socket_path": %s, "s0_legacy_key": "%s", "s2_access_control_key": "%s", "lr_s2_authenticated_key": "%s"}' "$1" "$2" "$3" "$4" "$KEY" "$KEY" "$KEY"; }
hass() { local d=$1; shift; PATH="$d/bin:$PATH" bash "$HASS_TOOL" --config "$d/config" "$@" > "$d/out" 2>&1 < /dev/null; RC=$?; }
LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'

echo "-- what is refused"
ha "$T/u" - -
hass "$T/u" --radios 192.0.2.300; check "--radios that is no address: exit 2" eq "$RC" 2
hass "$T/u" --radios 192.0.2.50 --zwave-port 70000; check "--zwave-port that is no port: exit 2" eq "$RC" 2
hass "$T/u" --radios 192.0.2.50 --no-zwave --no-zigbee; check "--no-zwave and --no-zigbee: nothing to look at, exit 2" eq "$RC" 2
hass "$T/u" --radios 192.0.2.50 --frobnicate; check "an unknown option: exit 2" eq "$RC" 2
hass "$T/u"; check "no --radios, nothing in Home Assistant's settings, nobody to ask: exit 2, naming the option, and where the address is to be found (a node's install line, a radio VM's Notes)" bash -c '[ "$2" = 2 ] && grep -q "die: which pair? --radios A.B.C.D" "$1/out" && grep -q "name no network path for Z-Wave or Zigbee yet" "$1/out" && grep -q "on either Proxmox node, the kit.s install line" "$1/out" && grep -q "a radio VM (tag zradio) > Summary > Notes: \"served to Home Assistant on A.B.C.D\"" "$1/out"' _ "$T/u" "$RC"
PATH="$T/u/bin:$PATH" bash "$HASS_TOOL" --config "$T/nowhere" --radios 192.0.2.50 > "$T/u/out" 2>&1 < /dev/null; RC=$?
check "no Home Assistant settings there: exit 2, saying where to run it and where the steps by hand are" bash -c '[ "$2" = 2 ] && grep -q "settings were not found here" "$1/out" && grep -q "Terminal & SSH" "$1/out" && grep -q "Connecting Home Assistant" "$1/out"' _ "$T/u" "$RC"
echo '{"data": {"users": []}}' > "$T/u/config/.storage/core.config_entries"; hass "$T/u" --radios 192.0.2.50
check "a file that is not the list of integrations: exit 2" bash -c '[ "$2" = 2 ] && grep -q "is not Home Assistant.s list of integrations" "$1/out"' _ "$T/u" "$RC"
ha "$T/j" - -; mkdir "$T/j/base"
for c in bash sh env cat sed grep; do ln -s "$(command -v "$c")" "$T/j/base/$c"; done
PATH="$T/j/bin:$T/j/base" bash "$HASS_TOOL" --config "$T/j/config" --radios 192.0.2.50 > "$T/j/out" 2>&1 < /dev/null; RC=$?
check "no jq on this machine: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "die: needs jq" "$1/out"' _ "$T/j" "$RC"

echo "-- a Home Assistant that uses the pair already: ZHA by its socket path, Z-Wave through the Z-Wave JS UI app"
ha "$T/a" "$(zha socket://192.0.2.50:6638)" "$(zw false ws://a0d7b954-zwavejs2mqtt:3000 null null)"; hass "$T/a" --radios 192.0.2.50
check "exit 0; a look only, said first" bash -c '[ "$2" = 0 ] && [ "$(head -1 "$1/out")" = "== Home Assistant and the radio pair at 192.0.2.50 (a look only: nothing is changed) ==" ]' _ "$T/a" "$RC"
check "the floating address answers a ping: OK" has "$T/a/out" "   OK    192.0.2.50 answers a ping from here"
check "Zigbee: OK, with the path ZHA uses" has "$T/a/out" "   OK    Zigbee (ZHA) uses the pair: socket://192.0.2.50:6638"
check "Z-Wave through a server: CHECK, not OK and not TODO — which server, that it cannot be seen from here, and what its serial port has to be" bash -c 'grep -q "^   CHECK Z-Wave: Home Assistant talks to the Z-Wave JS UI app (ws://a0d7b954-zwavejs2mqtt:3000). Which stick that server opens is set in the server, where this script cannot look" "$1/out" && grep -q "Settings > Z-Wave > \"Serial Port\": it has to be  tcp://192.0.2.50:6639" "$1/out" && ! grep -q "TODO" "$1/out"' _ "$T/a"
check "the last line: nothing to do but the one thing that cannot be seen; nothing was changed; no line to run again" bash -c '[ "$(tail -1 "$1/out")" = "== 1 that cannot be seen from here (CHECK). Nothing was changed. ==" ]' _ "$T/a"
check "no key of the Z-Wave network is in what is said" bash -c '! grep -q "$2" "$1/out" && ! grep -qi "s2_\|legacy_key" "$1/out"' _ "$T/a" "$KEY"
: > "$T/a/no-ping"; hass "$T/a" --radios 192.0.2.50
check "no answer to a ping: a NOTE with what to look at, and the rest all the same; exit 0" bash -c '[ "$2" = 0 ] && grep -q "^   NOTE  192.0.2.50 does not answer a ping from here" "$1/out" && grep -q "OK    Zigbee (ZHA) uses the pair" "$1/out"' _ "$T/a" "$RC"

echo "-- a Home Assistant with the sticks in its own machine: ZHA on a USB path, Z-Wave with the Z-Wave JS app"
ha "$T/b" "$(zha /dev/serial/by-id/usb-ITead_Sonoff-if00-port0)" "$(zw true ws://core-zwave-js:3000 '"/dev/ttyACM0"' null)"; hass "$T/b" --radios 192.0.2.50
check "Zigbee: TODO with the path in use, and Home Assistant's own menu names: change the adapter's settings, not migrate; the path to type; keep the network" bash -c '
  grep -q "^   TODO  Zigbee (ZHA) uses /dev/serial/by-id/usb-ITead_Sonoff-if00-port0 now (znp), not the pair" "$1/out" && grep -q "1. Settings > Devices & services > Zigbee Home Automation > the gear: ZHA.s own page" "$1/out" && grep -q "2. There, \"Migrate adapter\": Migrate. Then \"Change ZHA adapter settings\": Submit" "$1/out" &&
  grep -q "3. \"Change the current adapter.s settings\". NOT \"Migrate to a new adapter\"" "$1/out" && grep -q "4. \"Serial device path\": type  socket://192.0.2.50:6638$" "$1/out" && grep -q "\"Migrate manually\", then \"Keep adapter network settings\"" "$1/out"' _ "$T/b"
check "Z-Wave: TODO with the adapter in use; Reconfigure, the current adapter, Use Socket and the socket path" bash -c '
  grep -q "^   TODO  Z-Wave (the Z-Wave JS app) uses /dev/ttyACM0 now, not the pair" "$1/out" && grep -q "1. Settings > Devices & services > Z-Wave > the three dots > Reconfigure" "$1/out" &&
  grep -q "2. \"Reconfigure the current adapter\". NOT \"Migrate to a new adapter\"" "$1/out" && grep -q "USB: \"Use Socket\". \"Socket device path\": type  tcp://192.0.2.50:6639 " "$1/out"' _ "$T/b"
check "the last lines: two to do, nothing changed, and the kit's line to check afterward, with the address" bash -c '[ "$(tail -2 "$1/out" | head -1)" = "== 2 to do (TODO). Nothing was changed. ==" ] && [ "$(tail -1 "$1/out")" = "   Afterward, this again checks it:    $2 --radios 192.0.2.50 --config $1/config" ]' _ "$T/b" "$LINE"
check "exit 0 (it looked; the steps are the user.s), and no key shown" bash -c '[ "$2" = 0 ] && ! grep -q "$3" "$1/out"' _ "$T/b" "$RC" "$KEY"

echo "-- the Z-Wave JS app on the pair already; other ports; a kind the pair does not have"
ha "$T/c" "$(zha socket://192.0.2.50:7000)" "$(zw true ws://core-zwave-js:3000 null '"tcp://192.0.2.50:7001"')"; hass "$T/c" --radios 192.0.2.50 --zigbee-port 7000 --zwave-port 7001
check "both on the pair, on the ports named: two OK lines and 'Nothing to do'" bash -c '[ "$2" = 0 ] && grep -q "OK    Zigbee (ZHA) uses the pair: socket://192.0.2.50:7000" "$1/out" && grep -q "OK    Z-Wave (the Z-Wave JS app) uses the pair: tcp://192.0.2.50:7001" "$1/out" && [ "$(tail -1 "$1/out")" = "== Home Assistant uses the pair at 192.0.2.50. Nothing to do. ==" ]' _ "$T/c" "$RC"
hass "$T/c" --radios 192.0.2.50
check "the same Home Assistant against the usual ports: two TODO, with what each uses now" bash -c 'grep -q "TODO  Zigbee (ZHA) uses socket://192.0.2.50:7000 now" "$1/out" && grep -q "TODO  Z-Wave (the Z-Wave JS app) uses tcp://192.0.2.50:7001 now" "$1/out"' _ "$T/c"
hass "$T/c" --radios 192.0.2.50 --zigbee-port 7000 --no-zwave
check "--no-zwave: Z-Wave is not looked at or mentioned" bash -c '[ "$2" = 0 ] && ! grep -q "Z-Wave" "$1/out" && grep -q "Nothing to do" "$1/out"' _ "$T/c" "$RC"
hass "$T/c" --radios 192.0.2.50 --zwave-port 7001 --no-zigbee
check "--no-zigbee: Zigbee is not looked at or mentioned" bash -c '[ "$2" = 0 ] && ! grep -qi "zigbee\|ZHA" "$1/out" && grep -q "Nothing to do" "$1/out"' _ "$T/c" "$RC"
hass "$T/b" --radios 192.0.2.50 --zwave-port 7001 --no-zigbee
check "the line to run again carries the options it was run with" bash -c '[ "$(tail -1 "$1/out")" = "   Afterward, this again checks it:    $2 --radios 192.0.2.50 --zwave-port 7001 --no-zigbee --config $1/config" ]' _ "$T/b" "$LINE"

echo "-- a Home Assistant with neither yet; an integration that is disabled; a server of the user's own"
ha "$T/n" - -; hass "$T/n" --radios 192.0.2.50
check "neither: two TODO, each with how to add it on the pair; for Zigbee, the warning about the automatic setup" bash -c '[ "$2" = 0 ] && grep -q "TODO  Zigbee: Home Assistant has no Zigbee Home Automation (ZHA) yet" "$1/out" && grep -q "NOT \"Set up automatically\": that one erases the stick" "$1/out" && grep -q "TODO  Z-Wave: Home Assistant has no Z-Wave integration yet" "$1/out" && grep -q "\"Socket device path\": type  tcp://192.0.2.50:6639 " "$1/out"' _ "$T/n" "$RC"
ha "$T/d" "$(zha socket://192.0.2.50:6638)" "$(zw false 'ws://me:hunter2@10.1.2.3:3000' null null)"
python3 - "$T/d/config/.storage/core.config_entries" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
for e in j["data"]["entries"]:
    if e["domain"] == "zha": e["disabled_by"] = "user"
json.dump(j, open(sys.argv[1], "w"))
PY
hass "$T/d" --radios 192.0.2.50
check "a ZHA that is disabled is not in use: Zigbee is to be added" has "$T/d/out" "TODO  Zigbee: Home Assistant has no Zigbee Home Automation (ZHA) yet"
check "a server of the user's own: CHECK, its address without the user and password in it" bash -c 'grep -q "CHECK Z-Wave: Home Assistant talks to a Z-Wave JS server of your own (ws://10.1.2.3:3000)" "$1/out" && ! grep -q "hunter2" "$1/out"' _ "$T/d"
check "…both counted in the last lines" bash -c 'grep -qx "== 1 to do (TODO). 1 that cannot be seen from here (CHECK). Nothing was changed. ==" "$1/out"' _ "$T/d"

echo "-- an entry for a discovered stick the user ignored; ZHA's other spelling of a network path; an option without its value"
ha "$T/ig" "$(zha socket://192.0.2.50:6638)" -
python3 - "$T/ig/config/.storage/core.config_entries" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
j["data"]["entries"] += [{"domain": "zha", "source": "ignore", "disabled_by": None, "data": {}}, {"domain": "zwave_js", "source": "ignore", "disabled_by": None, "data": {}}]
json.dump(j, open(sys.argv[1], "w"))
PY
hass "$T/ig" --radios 192.0.2.50
check "ignored discoveries are not integrations: ZHA is OK once and nothing says it has no path; Z-Wave is to be added, not a server to look into" bash -c '[ "$2" = 0 ] && [ "$(grep -c "Zigbee" "$1/out")" = 1 ] && grep -q "OK    Zigbee (ZHA) uses the pair" "$1/out" && grep -q "TODO  Z-Wave: Home Assistant has no Z-Wave integration yet" "$1/out" && ! grep -q "CHECK" "$1/out"' _ "$T/ig" "$RC"
ha "$T/tc" "$(zha tcp://192.0.2.50:6638)" -; hass "$T/tc" --no-zwave
check "ZHA set to tcp://, which it reads as socket://: the address is found there, and that path is OK" bash -c '[ "$2" = 0 ] && grep -q "OK    Zigbee (ZHA) uses the pair: tcp://192.0.2.50:6638" "$1/out" && grep -q "Nothing to do" "$1/out"' _ "$T/tc" "$RC"
hass "$T/tc" --radios
check "--radios given last without an address: exit 2, said (it used to loop for ever)" bash -c '[ "$2" = 2 ] && grep -q "die: --radios needs a value" "$1/out"' _ "$T/tc" "$RC"
PATH="$T/tc/bin:$PATH" bash "$HASS_TOOL" --radios 192.0.2.50 --no-zwave --config > "$T/tc/out" 2>&1 < /dev/null; RC=$?
check "…--config the same" bash -c '[ "$2" = 2 ] && grep -q "die: --config needs a value" "$1/out"' _ "$T/tc" "$RC"
ZRADIO_HA_CONFIG="$T/b/config" PATH="$T/b/bin:$PATH" bash "$HASS_TOOL" --radios 192.0.2.50 > "$T/b/out" 2>&1 < /dev/null
check "the line to run again names --config only when the run did" bash -c '[ "$(tail -1 "$1/out")" = "   Afterward, this again checks it:    $2 --radios 192.0.2.50" ]' _ "$T/b" "$LINE"
check "a ping that is answered says that and no more (it cannot know what answered)" bash -c 'grep -qx "   OK    192.0.2.50 answers a ping from here" "$1/out"' _ "$T/b"

echo "-- asked for the address on a terminal"
ha "$T/q" "$(zha socket://192.0.2.50:6638)" -
PATH="$T/q/bin:$PATH" ZRADIO_HA_ASK=1 bash "$HASS_TOOL" --config "$T/q/config" --no-zwave > "$T/q/out" 2>&1 <<< "192.0.2.50"; RC=$?
check "an address typed as the answer is used" bash -c '[ "$2" = 0 ] && grep -q "Is 192.0.2.50 the pair.s floating address? \[Y/n, or the address\]" "$1/out" && grep -q "OK    Zigbee (ZHA) uses the pair: socket://192.0.2.50:6638" "$1/out"' _ "$T/q" "$RC"
PATH="$T/q/bin:$PATH" ZRADIO_HA_ASK=1 bash "$HASS_TOOL" --config "$T/q/config" > "$T/q/out" 2>&1 <<< "the attic"; RC=$?
check "an answer that is no address: exit 2" eq "$RC" 2

echo "-- no --radios: the address is looked for in Home Assistant's own settings"
ha "$T/f" "$(zha socket://192.0.2.50:6638)" "$(zw true ws://core-zwave-js:3000 '"/dev/ttyACM0"' null)"; hass "$T/f"
check "ZHA is on a network path, nobody to ask: that address is taken, and said to be taken from there; Zigbee OK, Z-Wave TODO; exit 0" bash -c '[ "$2" = 0 ] && grep -q "     - Zigbee (ZHA) is set to socket://192.0.2.50:6638" "$1/out" && grep -q "^   NOTE  192.0.2.50 is taken as the pair.s floating address from Home Assistant.s own settings (Zigbee (ZHA) is set to socket://192.0.2.50:6638). Another pair: --radios A.B.C.D" "$1/out" && grep -q "OK    Zigbee (ZHA) uses the pair" "$1/out" && grep -q "TODO  Z-Wave (the Z-Wave JS app) uses /dev/ttyACM0 now" "$1/out" && grep -q "_ --radios 192.0.2.50 --config $1/config$" "$1/out"' _ "$T/f" "$RC"
check "…with --radios nothing is said to be taken from anywhere" bash -c '! grep -q "is taken as" "$1/out"' _ "$T/b"
ha "$T/f2" "$(zha /dev/ttyUSB0)" "$(zw true ws://core-zwave-js:3000 null '"tcp://192.0.2.60:6639"')"; hass "$T/f2"
check "only the Z-Wave JS app is on a network path: its address is taken; Z-Wave OK, Zigbee TODO" bash -c '[ "$2" = 0 ] && grep -q "from Home Assistant.s own settings (Z-Wave (the Z-Wave JS app) is set to tcp://192.0.2.60:6639)" "$1/out" && grep -q "OK    Z-Wave (the Z-Wave JS app) uses the pair: tcp://192.0.2.60:6639" "$1/out" && grep -q "TODO  Zigbee (ZHA) uses /dev/ttyUSB0 now" "$1/out"' _ "$T/f2" "$RC"
ha "$T/f3" "$(zha socket://192.0.2.50:6638)" "$(zw true ws://core-zwave-js:3000 null '"tcp://192.0.2.60:6639"')"; hass "$T/f3"
check "the two are on different addresses, nobody to ask: both shown, exit 2 — it does not pick one" bash -c '[ "$2" = 2 ] && grep -q "Zigbee (ZHA) is set to socket://192.0.2.50:6638" "$1/out" && grep -q "Z-Wave (the Z-Wave JS app) is set to tcp://192.0.2.60:6639" "$1/out" && grep -q "die: which pair?" "$1/out" && ! grep -q "^== Home Assistant and the radio pair" "$1/out"' _ "$T/f3" "$RC"
ha "$T/f4" "$(zha socket://zigbee.example:6638)" "$(zw false ws://10.1.2.3:3000 null null)"; hass "$T/f4"
check "a path by name, and a Z-Wave server's own address, are not taken for the pair's: exit 2 with where to find it" bash -c '[ "$2" = 2 ] && grep -q "name no network path" "$1/out" && grep -q "Where the pair.s floating address is to be found" "$1/out"' _ "$T/f4" "$RC"
PATH="$T/f/bin:$PATH" ZRADIO_HA_ASK=1 bash "$HASS_TOOL" --config "$T/f/config" > "$T/f/out" 2>&1 <<< ""; RC=$?
check "on a terminal it is asked, and Enter takes the address found; nothing is said to be assumed" bash -c '[ "$2" = 0 ] && grep -q "Is 192.0.2.50 the pair.s floating address?" "$1/out" && grep -q "== Home Assistant and the radio pair at 192.0.2.50" "$1/out" && ! grep -q "is taken as" "$1/out"' _ "$T/f" "$RC"
PATH="$T/f/bin:$PATH" ZRADIO_HA_ASK=1 bash "$HASS_TOOL" --config "$T/f/config" > "$T/f/out" 2>&1 <<< "n
192.0.2.77"; RC=$?
check "…'n', then another address: that one is used, and both are then to do" bash -c '[ "$2" = 0 ] && grep -q "== Home Assistant and the radio pair at 192.0.2.77" "$1/out" && grep -q "TODO  Zigbee (ZHA) uses socket://192.0.2.50:6638 now" "$1/out"' _ "$T/f" "$RC"
PATH="$T/u/bin:$PATH" ZRADIO_HA_ASK=1 bash "$HASS_TOOL" --config "$T/n/config" > "$T/n/out" 2>&1 <<< "192.0.2.50"; RC=$?
check "nothing found, on a terminal: where to find it, then the question" bash -c '[ "$2" = 0 ] && grep -q "Where the pair.s floating address is to be found" "$1/out" && grep -q "The pair.s floating address \[A.B.C.D\]: " "$1/out" && grep -q "== Home Assistant and the radio pair at 192.0.2.50" "$1/out"' _ "$T/n" "$RC"

echo "-- nothing is written: Home Assistant's file is as it was"
ha "$T/w" "$(zha /dev/ttyUSB0)" "$(zw true ws://core-zwave-js:3000 '"/dev/ttyACM0"' null)"; B=$(sha256sum "$T/w/config/.storage/core.config_entries"; ls -la "$T/w/config/.storage")
hass "$T/w" --radios 192.0.2.50
check "the same bytes, the same folder" eq "$(sha256sum "$T/w/config/.storage/core.config_entries"; ls -la "$T/w/config/.storage")" "$B"

echo "-- ./install.sh on a machine that is not a Proxmox node: Home Assistant, or the third vote"
ha "$T/i" "$(zha socket://192.0.2.50:6638)" -; mkdir "$T/i/base"
# a machine without qm and pvesh: only the fakes and plain tools on PATH
for c in bash sh env cat sed awk grep jq hostname dirname head tail; do ln -s "$(command -v "$c")" "$T/i/base/$c"; done
PATH="$T/i/bin:$T/i/base" bash "$KIT/install.sh" --radios 192.0.2.50 --config "$T/i/config" --no-zwave > "$T/i/out" 2>&1 < /dev/null; RC=$?
check "--radios: it says this is Home Assistant and that nothing is installed here, then the look" bash -c '[ "$2" = 0 ] && head -1 "$1/out" | grep -qx "This is Home Assistant, not a Proxmox node. The kit installs nothing here: it looks at how Home Assistant.s" && grep -q "^== Home Assistant and the radio pair at 192.0.2.50" "$1/out" && grep -q "Nothing to do" "$1/out"' _ "$T/i" "$RC"
PATH="$T/i/bin:$T/i/base" SUPERVISOR_TOKEN=x bash "$KIT/install.sh" > "$T/i/out" 2>&1 < /dev/null; RC=$?
check "in a Home Assistant app (its token is in the environment), no options: Home Assistant's side, which then names what it needs" bash -c '[ "$2" = 2 ] && grep -q "^This is Home Assistant" "$1/out" && grep -q "die: " "$1/out" && ! grep -q "third vote" "$1/out"' _ "$T/i" "$RC"
PATH="$T/i/bin:$T/i/base" bash "$KIT/install.sh" > "$T/i/out" 2>&1 < /dev/null; RC=$?
check "neither: the third vote, as before" bash -c 'grep -q "^This machine is not a Proxmox node" "$1/out" && ! grep -q "This is Home Assistant" "$1/out"' _ "$T/i"

echo "-- get.sh on a machine without python (Home Assistant's terminal)"
G="$T/g"; mkdir -p "$G/bin" "$G/base" "$G/src/ha_zradio-x/guest"
printf '#!/usr/bin/env bash\necho "install.sh ran with: $*"\n' > "$G/src/ha_zradio-x/install.sh"; echo "# the guest" > "$G/src/ha_zradio-x/guest/install.sh"
tar -C "$G/src" --format=pax --pax-option=comment=0123456789abcdef0123456789abcdef01234567 -czf "$G/kit.tgz" ha_zradio-x
printf '{\n  "url": "https://api.example/x",\n  "tag_name": "v0.3.0",\n  "name": "v0.3.0",\n  "body": "notes with \\"tag_name\\": \\"nope\\" in them"\n}\n' > "$G/release.json"
fake "$G/bin" id 'echo 0'
fake "$G/bin" curl "out=''; url=''
while [ \$# -gt 0 ]; do case \"\$1\" in -o) out=\$2; shift 2;; -*) shift;; *) url=\$1; shift;; esac; done
case \"\$url\" in */releases/latest) cat '$G/release.json';; */archive/*) cp '$G/kit.tgz' \"\$out\";; *) exit 22;; esac"
for c in bash sh env cat cp sed grep tar gzip head tr cut mktemp mkdir mv rm; do ln -s "$(command -v "$c")" "$G/base/$c"; done      # cp is for the fake curl
PATH="$G/bin:$G/base" ZRADIO_DEST="$G/opt/ha_zradio" bash "$KIT/get.sh" --radios 192.0.2.50 > "$G/out" 2>&1 < /dev/null; RC=$?
check "no python3 on PATH: the latest release is found in GitHub's answer (several lines; a look-alike inside its notes is not taken), unpacked, and the installer run with the options" bash -c '[ "$2" = 0 ] && grep -q "^== ha_zradio v0.3.0, from " "$1/out" && grep -q "^install.sh ran with: --radios 192.0.2.50$" "$1/out" && [ "$(cat "$1/opt/ha_zradio/v0.3.0/gen/version")" = v0.3.0 ]' _ "$G" "$RC"; [ "$FAIL" = 0 ] || cat "$G/out"
PATH="$G/bin:$G/base" ZRADIO_REF=main ZRADIO_DEST="$G/opt/ha_zradio" bash "$KIT/get.sh" > "$G/out" 2>&1 < /dev/null; RC=$?
check "…and a branch: the commit is read from the archive's header without python" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/opt/ha_zradio/main/gen/version")" = "main@0123456" ] && grep -q "(commit 0123456789ab)" "$1/out"' _ "$G" "$RC"
check "get.sh itself runs no python3" bash -c '! grep -q "python3" "$1"' _ "$KIT/get.sh"
check "every ZRADIO_HA_* knob homeassistant/install.sh reads is named in its header" bash -c 'k=$(grep -oE "ZRADIO_HA_[A-Z_]+" "$1" | sort -u) && [ -n "$k" ] && c=$(sed -n "1,/^set -uo pipefail\$/p" "$1") && for n in $k; do printf "%s\n" "$c" | grep -qw "$n" || { echo "        not named: $n"; exit 1; }; done' _ "$HASS_TOOL"
finish
