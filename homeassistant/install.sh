#!/usr/bin/env bash
# homeassistant/install.sh — Home Assistant's side of a zradio pair: is its Z-Wave and its Zigbee connected to the
# pair's floating address, and if not, what to change, step by step. Run it where Home Assistant's settings are: in
# Home Assistant's terminal (the Terminal & SSH app), with the kit's install line (get.sh: ./install.sh sees Home
# Assistant and hands over to this script), or on any machine with --config.
#
# It CHANGES NOTHING in Home Assistant, and installs nothing. It reads which serial path the Zigbee integration
# (ZHA) and the Z-Wave integration use, from Home Assistant's own list of integrations
# (<config>/.storage/core.config_entries: those fields only, never a key), and says OK, or the steps for this Home
# Assistant. Why it does not do the steps itself: Home Assistant changes these paths only through its own setup
# dialogs (they stop the integration, try the stick, then save), the terminal app has no access to them, and the
# file read here must never be edited by hand. Run again after the steps, it checks them.
#   --radios A.B.C.D     the pair's floating address. Without it, it is looked for in Home Assistant's own settings
#                        (a network path that ZHA or the Z-Wave JS app uses already), and where that finds nothing
#                        it says where the address is to be found: the kit's install line on either Proxmox node
#                        ends with this line and the address in it, and a radio VM's Notes in Proxmox name it.
#   --zwave-port N       the pair's Z-Wave port (default 6639)       --no-zwave    the pair has no Z-Wave stick
#   --zigbee-port N      the pair's Zigbee port (default 6638)       --no-zigbee   the pair has no Zigbee stick
#   --config DIR         Home Assistant's config folder (default: /config or /homeassistant, where the terminal app
#                        has it)
# It does not connect to the pair's ports: each takes one client, and a second one would cut Home Assistant off.
# For the same reason it does not search the network for the pair: those two ports are all that would answer.
# The menu names are Home Assistant 2026.11's. Needs bash and jq (the terminal app has both); no python.
# Tests: tests/t-hass.sh (fakes) and tests/hass-real.sh (the terminal app's kind of machine: Alpine, busybox).
set -uo pipefail
ADDR="" ZP=6639 GP=6638 ZW=1 ZB=1 CONF=${ZRADIO_HA_CONFIG:-} TODO=0 UNSEEN=0
GET_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
ok() { printf '   OK    %s\n' "$*"; }
note() { printf '   NOTE  %s\n' "$*"; }
todo() { printf '   TODO  %s\n' "$*"; TODO=$((TODO + 1)); }
unseen() { printf '   CHECK %s\n' "$*"; UNSEEN=$((UNSEEN + 1)); }
steps() { local n=0 s; for s in "$@"; do n=$((n + 1)); printf '         %d. %s\n' "$n" "$s"; done; }      # what to do, numbered
die() { echo "die: $*" >&2; exit 2; }
ip4() { [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ]; }
port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

while [ $# -gt 0 ]; do case "$1" in
  -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" 2>/dev/null | sed '$d'; exit 0;;
  --radios) ADDR=${2:-}; shift 2;; --zwave-port) ZP=${2:-}; shift 2;; --zigbee-port) GP=${2:-}; shift 2;;
  --no-zwave) ZW=0; shift;; --no-zigbee) ZB=0; shift;; --config) CONF=${2:-}; shift 2;;
  *) echo "unknown option: $1" >&2; exit 2;; esac; done
port "$ZP" || die "--zwave-port '$ZP': a TCP port"
port "$GP" || die "--zigbee-port '$GP': a TCP port"
[ $ZW = 1 ] || [ $ZB = 1 ] || die "--no-zwave and --no-zigbee: nothing is left to look at"
command -v jq >/dev/null 2>&1 || die "needs jq, to read Home Assistant's list of integrations. Home Assistant's Terminal & SSH app has it; elsewhere, install jq"
if [ -z "$CONF" ]; then for d in /config /homeassistant; do [ ! -f "$d/.storage/core.config_entries" ] || { CONF=$d; break; }; done; fi
F="$CONF/.storage/core.config_entries"
[ -n "$CONF" ] && [ -r "$F" ] || die "Home Assistant's settings were not found here (${CONF:-/config}/.storage/core.config_entries). Run this in Home Assistant's terminal (Settings > Apps > Terminal & SSH), or name Home Assistant's config folder with --config DIR. The steps by hand: the kit's README, \"Connecting Home Assistant\""
jq -e '.data.entries | type == "array"' "$F" >/dev/null 2>&1 || die "$F is not Home Assistant's list of integrations (no .data.entries in it)"
ASK=0; if { [ -t 0 ] && [ -t 1 ]; } || [ "${ZRADIO_HA_ASK:-0}" = 1 ]; then ASK=1; fi
SEP=$'\x1f'      # between fields: the unit separator, not a tab (read would fold empty fields between tabs into one)
FOUND=""         # where the address came from, when Home Assistant's own settings gave it
where() { # where the floating address is to be found
  echo "   Where the pair's floating address is to be found:"
  echo "     - on either Proxmox node, the kit's install line: it says how the pair is, and ends with this line and the address in it"
  echo "     - in Proxmox, a radio VM (tag zradio) > Summary > Notes: \"served to Home Assistant on A.B.C.D\""
}
if [ -z "$ADDR" ]; then
  # Home Assistant's own settings may name it already: a network path of ZHA, or of the Z-Wave JS app
  HOSTS=() SAID=()
  while IFS=$SEP read -r what path; do
    [[ "$path" =~ ^(socket|tcp)://([0-9.]+):[0-9]+$ ]] || continue
    h=${BASH_REMATCH[2]}; ip4 "$h" || continue
    case " ${HOSTS[*]-} " in *" $h "*) ;; *) HOSTS+=("$h");; esac
    SAID+=("$what is set to $path")
  done < <(jq -r '.data.entries[] | select(.disabled_by == null) | if .domain == "zha" then "Zigbee (ZHA)\u001f" + (.data.device.path // "") elif .domain == "zwave_js" and .data.use_addon == true then "Z-Wave (the Z-Wave JS app)\u001f" + (.data.socket_path // "") else empty end' "$F")
  if [ ${#HOSTS[@]} -gt 0 ]; then echo "   No --radios. In Home Assistant's own settings:"; printf '     - %s\n' "${SAID[@]}"; else echo "   No --radios, and Home Assistant's settings name no network path for Z-Wave or Zigbee yet."; fi
  if [ ${#HOSTS[@]} = 1 ]; then
    if [ $ASK = 1 ]; then
      printf "   Is %s the pair's floating address? [Y/n, or the address]: " "${HOSTS[0]}"; read -r ANS || ANS=n
      case "$ANS" in ''|y|Y|yes|Yes|YES) ADDR=${HOSTS[0]};; n|N|no|No|NO) ;; *) ADDR=$ANS;; esac
    else ADDR=${HOSTS[0]}; FOUND=${SAID[0]}; fi
  fi
  if [ -z "$ADDR" ]; then
    [ ${#HOSTS[@]} -gt 1 ] || where
    [ $ASK = 1 ] || die "which pair? --radios A.B.C.D, the pair's floating address"
    printf "   The pair's floating address [A.B.C.D]: "; read -r ADDR || ADDR=""
  fi
fi
ip4 "$ADDR" || die "--radios '$ADDR': the pair's floating address, A.B.C.D"
WANT_ZB="socket://$ADDR:$GP" WANT_ZW="tcp://$ADDR:$ZP"

# one integration's entries, the named fields only; an entry the user disabled is not in use
entries() { local d=$1; shift; jq -r --arg d "$d" ".data.entries[] | select(.domain == \$d and .disabled_by == null) | [$*] | map(. // \"\" | tostring) | join(\"\\u001f\")" "$F"; }

echo "== Home Assistant and the radio pair at $ADDR (a look only: nothing is changed) =="
[ -z "$FOUND" ] || note "$ADDR is taken as the pair's floating address from Home Assistant's own settings ($FOUND). Another pair: --radios A.B.C.D"
if command -v ping >/dev/null 2>&1; then
  if ping -c 1 -W 2 "$ADDR" >/dev/null 2>&1; then ok "$ADDR answers a ping from here: a radio VM holds the floating address"
  else note "$ADDR does not answer a ping from here. Is a radio VM serving (zradio-serve status in it)? Does this machine reach that network? (Some firewalls drop pings.)"; fi
fi

if [ $ZB = 1 ]; then
  Z=$(entries zha '.data.device.path, .data.radio_type')
  if [ -z "$Z" ]; then
    todo "Zigbee: Home Assistant has no Zigbee Home Automation (ZHA) yet. To add it, on the pair:"
    steps "Settings > Devices & services > Add integration > Zigbee Home Automation." \
          "\"Serial device path\": type  $WANT_ZB  (if it then asks: the adapter type of the pair's stick — ZNP for a TI CC2652, EZSP for Silicon Labs — speed 115200, flow control none)." \
          "The pair's sticks hold your network: \"Set up manually\", then \"Keep adapter network settings\". NOT \"Set up automatically\": that one erases the stick and creates a new network. (A new house, no devices yet: \"Set up automatically\".)"
  else
    while IFS=$SEP read -r path radio; do
      if [ "$path" = "$WANT_ZB" ]; then ok "Zigbee (ZHA) uses the pair: $path"
      else
        todo "Zigbee (ZHA) uses ${path:-no path} now${radio:+ ($radio)}, not the pair. With the stick that holds your network in the pair:"
        steps "Settings > Devices & services > Zigbee Home Automation > Configure (the gear)." \
              "\"Change ZHA adapter settings\": Submit. ZHA makes a backup and stops." \
              "\"Change the current adapter's settings\". NOT \"Migrate to a new adapter\": that one resets the old stick first." \
              "\"Serial device path\": type  $WANT_ZB" \
              "If it asks how to migrate: \"Migrate manually\", then \"Keep adapter network settings\". The stick already holds the network; nothing is written to it. ZHA starts again."
      fi
    done <<< "$Z"
  fi
fi

if [ $ZW = 1 ]; then
  Z=$(entries zwave_js '.data.use_addon, .data.url, .data.usb_path, .data.socket_path')
  if [ -z "$Z" ]; then
    todo "Z-Wave: Home Assistant has no Z-Wave integration yet. To add it, on the pair:"
    steps "Settings > Devices & services > Add integration > Z-Wave." \
          "\"Custom installation\", and keep \"Use the Z-Wave JS app\" on. It installs the app." \
          "\"Socket device path\": type  $WANT_ZW  and leave the USB choice empty." \
          "The pair's sticks hold your network: say that the network exists, and enter its S0/S2 keys. (A new house: a new network.)"
  else
    while IFS=$SEP read -r addon url usb sock; do
      if [ "$addon" = true ]; then
        cur=${sock:-$usb}
        if [ "$cur" = "$WANT_ZW" ]; then ok "Z-Wave (the Z-Wave JS app) uses the pair: $cur"
        else
          todo "Z-Wave (the Z-Wave JS app) uses ${cur:-no adapter} now, not the pair. With the stick that holds your network in the pair:"
          steps "Settings > Devices & services > Z-Wave > the three dots > Reconfigure." \
                "\"Reconfigure the current adapter\". NOT \"Migrate to a new adapter\": that one copies the network onto another stick." \
                "Keep \"Use the Z-Wave JS app\" on." \
                "USB: \"Use Socket\". \"Socket device path\": type  $WANT_ZW  The keys stay as they are. Submit: the app starts again."
        fi
      else
        url=$(printf '%s' "$url" | sed 's#//[^/@]*@#//#')      # a URL's user and password, if it has any, are not shown
        case "$url" in *zwavejs2mqtt*|*zwave-js-ui*|*zwavejsui*) who="the Z-Wave JS UI app"; open="Open Z-Wave JS UI (Home Assistant's sidebar, or Settings > Apps > Z-Wave JS UI > Open web UI).";;
          *) who="a Z-Wave JS server of your own"; open="Open that server's own page (Z-Wave JS UI: port 8091 of its machine).";; esac
        unseen "Z-Wave: Home Assistant talks to $who${url:+ ($url)}. Which stick that server opens is set in the server, where this script cannot look. There:"
        steps "$open" \
              "Settings > Z-Wave > \"Serial Port\": it has to be  $WANT_ZW" \
              "If you changed it: Save. The S0/S2 keys stay as they are. Home Assistant's Z-Wave integration needs no change."
      fi
    done <<< "$Z"
  fi
fi

if [ $TODO = 0 ] && [ $UNSEEN = 0 ]; then echo "== Home Assistant uses the pair at $ADDR. Nothing to do. =="
else
  echo "== $([ $TODO = 0 ] || echo "$TODO to do (TODO). ")$([ $UNSEEN = 0 ] || echo "$UNSEEN that cannot be seen from here (CHECK). ")Nothing was changed. =="
  [ $TODO = 0 ] || echo "   Afterward, this again checks it:    $GET_LINE --radios $ADDR$([ "$ZP" = 6639 ] || echo " --zwave-port $ZP")$([ "$GP" = 6638 ] || echo " --zigbee-port $GP")$([ $ZW = 1 ] || echo " --no-zwave")$([ $ZB = 1 ] || echo " --no-zigbee")"
fi
exit 0
