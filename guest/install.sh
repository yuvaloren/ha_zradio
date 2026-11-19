#!/usr/bin/env bash
# install.sh — makes THIS machine one radio VM of a zradio pair. Run INSIDE the VM as root, from a checkout of the kit
# (this file's directory holds sbin/, lib/ and units/). Report mode unless --run; re-runnable: nothing is rewritten
# that is already right, and a re-run is how a new version of the kit or a changed zradio.conf is put in place.
#
#   install.sh --conf my-zradio.conf [--run]     first install: the pair's one config file (zradio.conf.example)
#   install.sh [--run]                           later runs: /etc/zradio/zradio.conf is already there
#   --initial-role primary|standby   what this VM is on the day of the install. INITIAL, because the two VMs swap
#                  afterward (a failover, a switch) and either serves: the answer is used once, kept in
#                  /var/lib/zradio/initial-role, and saying the same again on a later run changes nothing.
#                    primary  this VM's sticks ARE the house's networks: they stay as they are, and this VM may serve
#                             them. Refused when a stick that would be synced holds no network — unless --first.
#                    standby  this VM's sticks WILL BE OVERWRITTEN with the primary's networks at the first sync,
#                             whatever they hold now. Until that sync has landed the VM is marked "not filled" and
#                             does not serve: a standby can never put an old or foreign network on the air.
#   --first        with --initial-role primary: the sticks hold no network yet (a new house; Home Assistant forms it).
#   Without --initial-role (the kit before the role was asked): a VM whose "synced" sticks are blank is marked "not
#                  filled" unless --first; a VM whose sticks hold any network may serve.
#   --from-node    run by ./install.sh on the Proxmox node, which pairs the two VMs itself: the trust line is not printed
#   --peer A.B.C.D the other radio VM's address, written into the conf this VM has (PEER). For the pair's first VM, which
#                  was installed before the second one had an address: keepalived.conf is rendered again, and a
#                  keepalived that runs is reloaded — the floating address is gone for about 4 seconds [V keepalived 2.3].
#   A conf without SELF: this machine's own address is written into it (the one on IFACE, else on the default route's
#                  interface) — for a VM whose address comes from DHCP. The pair knows the VM by that address from
#                  then on: RESERVE it for this VM in the DHCP server. A VIP without a prefix gets that address's.
#                  A conf without PEER: no peer yet (the first VM of a pair); --peer adds it later.
#   --detect       look at the USB ports again even though /etc/zradio/radios.conf exists (after changing a stick)
#   --use zigbee=/dev/ttyUSB3[:family]   passed to zradio-detect (repeatable)
#
# What --run does, in order:
#   1. the kit's files: /usr/local/sbin/zradio-* (0755 root: keepalived's enable_script_security wants root-owned
#      scripts nobody else can write), /usr/local/lib/zradio/, /etc/zradio/zradio.conf (from --conf)
#   2. Debian packages: keepalived, ser2net. A package that starts its service at install is stopped again and
#      ser2net is disabled at boot — only zradio-serve.service ever starts it.
#   3. the radios: zradio-detect --write (which sticks, which family, what the kit does with each; the names
#      /dev/zradio-zwave and /dev/zradio-zigbee). Skipped when radios.conf exists (--detect looks again).
#   4. what the detected radios need: podman and the pinned Z-Wave JS UI image (a Z-Wave stick that is synced: the
#      image writes a copied network onto it, and a sync must never wait for a download); zigpy in its own venv
#      /opt/zradio/zigpy (a Zigbee stick that is synced): zigpy-cli at the release zradio.conf pins (ZIGPY_VERSION),
#      and under it the libraries of lib/zigpy-constraints.txt. The venv is stamped with its release (zradio-pin);
#      when the conf pins another one, the venv is built again — and put back as it was if that fails.
#   5. the rendered files: /etc/keepalived/keepalived.conf (checked with keepalived -t), /etc/ser2net.yaml (the
#      package's file is kept once as /etc/ser2net.yaml.dist), the nightly timer.
#   6. the units, and a drop-in for keepalived.service: the sticks are silenced first; a keepalived that dies comes
#      back by itself; a keepalived that stops (systemctl stop, a crash, the shutdown) stops this VM serving — its own
#      notify at a stop is not reliable [V: after a stop one VM's role file still said MASTER], and a crashed
#      keepalived runs none. Enabled: zradio-quiet (silent sticks at every boot), keepalived, the nightly sync, the
#      15-minute tick, the state line, the device-change watcher, the election's gate (zradio-gate: observe mode
#      unless zradio.conf says ELECTION=act) — and zradio.target, which names them all.
#      NOTHING IS STARTED on a VM that is not in the pair: `systemctl start zradio.target`, or the next boot, puts it
#      there. On a VM that is (zradio.target is active), what runs all the time is put onto the new files: the gate
#      and the watcher are restarted when a file they read changed — while no sync runs here, because a restart ends
#      what they started; a timer whose file changed is restarted; a unit of the target that is not running (new in
#      this kit) is started. keepalived and a serving ser2net are never restarted here: the notes say what to do.
#   7. this VM's sync key (made if missing) and its two PUBLIC keys, with the line to run on the other VM.
# Refused before anything is changed: not root; a missing sibling file; a conf that does not check (a key that is not
# one of its own; a time systemd does not take: systemd-analyze calendar).
# Tests: tests/t-install.sh. Env for the tests: ZRADIO_INSTALL_ROOT (a prefix for every path written),
# ZRADIO_INSTALL_DETECT, ZRADIO_INSTALL_ZIGPY_SETUP (called with the venv's folder and the release),
# ZRADIO_INSTALL_WATCHDOG (the device), ZRADIO_INSTALL_SYSCTL, ZRADIO_INSTALL_HOSTKEY (this VM's public host key),
# ZRADIO_INSTALL_RESTART_WAIT (s to wait for a running sync before a restart), ZRADIO_IP (the `ip` command), and
# systemctl / apt-get / dpkg-query / keepalived / podman / systemd-analyze on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${ZRADIO_INSTALL_ROOT:-}
RUN=0 CONF_SRC="" FIRST=0 DETECT=0 USE=() ROLE="" BYNODE=0 SETPEER="" PEER_SAID=0
while [ $# -gt 0 ]; do
  case "$1" in --conf|--initial-role|--peer|--use) [ $# -ge 2 ] || { echo "$1 needs a value (--help)" >&2; exit 2; };; esac
  case "$1" in
  --run) RUN=1; shift;; --conf) CONF_SRC=$2; shift 2;; --first) FIRST=1; shift;; --detect) DETECT=1; shift;; --from-node) BYNODE=1; shift;; --initial-role) ROLE=$2; shift 2;; --peer) SETPEER=$2; PEER_SAID=1; shift 2;;
  --use) USE+=(--use "$2"); shift 2;;
  -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p}' "$0"; exit 0;; *) echo "unknown arg: $1" >&2; exit 2;; esac; done
case "$ROLE" in ""|primary|standby) ;; *) echo "--initial-role '$ROLE': primary (its sticks hold the networks today) or standby (its sticks will be overwritten)" >&2; exit 2;; esac
[ "$ROLE" != standby ] || [ $FIRST = 0 ] || { echo "--first is for the initial primary of a new house: a standby's sticks are filled by the primary's sync" >&2; exit 2; }
# the library first: the report lines (ok, warn, bad, done_, would) and the conf's checks are its own
[ -r "$HERE/lib/zradio-common.sh" ] || { echo "FAIL  $HERE/lib/zradio-common.sh is missing: this is not a whole kit. Nothing was changed" >&2; exit 2; }
# shellcheck source=lib/zradio-common.sh
. "$HERE/lib/zradio-common.sh" || exit 2
FAILS=0
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
RESTART_WAIT=${ZRADIO_INSTALL_RESTART_WAIT:-300}      # s a restart waits for a sync that runs here
sync_idle() { # 0 when no sync runs on this VM (zradio-sync's two locks are free), and they stay taken by the shell
  # that asked: ALWAYS called in a subshell, which gives them back when it ends; 3 when one runs
  local d="$R/run/zradio"
  [ -d "$d" ] || return 0
  exec 8>"$d/sync-out.lock" 9>"$d/sync-in.lock" || return 3
  flock -n 8 && flock -n 9 || return 3
}
idle_restart() { # idle_restart <unit> <note>: restart a unit that runs all the time, while no sync runs here. A restart
  # ends everything the unit started (systemd stops its whole control group): the watcher's device-change sync in the
  # middle of its read, the gate's raise of the Zigbee counter in the middle of its write.
  local left=$RESTART_WAIT rc
  while :; do
    ( sync_idle || exit 3; systemctl restart "$1" >/dev/null 2>&1 ) 2>/dev/null; rc=$?
    case $rc in
      0) ok "$1 restarted on the new files ($2)"; return 0;;
      3) ;;
      *) warn "systemctl restart $1 failed: it runs on the old files until it is restarted"; return 0;;
    esac
    [ "$left" -gt 0 ] || break
    sleep $(( left < 5 ? left : 5 )); left=$(( left < 5 ? 0 : left - 5 ))
  done
  warn "a sync is running here, for more than $RESTART_WAIT s now: $1 was not restarted and runs on the old files. When the sync has ended (zradio-sync status): systemctl restart $1"
}
installed() { dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
CHANGED=""          # the files this run changed, for the notes at the end
put() { # put <source> <dest under $R> <mode>: installed only when it differs
  local src=$1 dst="$R$2" mode=$3
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then ok "$2 is current"; return 0; fi
  if [ $RUN = 1 ]; then mkdir -p "$(dirname "$dst")" && install -m "$mode" "$src" "$dst.part" && mv -f "$dst.part" "$dst" && { done_ "$2 installed ($mode)"; CHANGED="$CHANGED $2"; } || bad "$2 not installed"
  else would "install $2 ($mode)"; fi
}
pkg() { # pkg <name> [stop: the service the package starts]
  if installed "$1"; then ok "$1 $(dpkg-query -W -f '${Version}' "$1" 2>/dev/null) is installed"; return 0; fi
  if [ $RUN = 0 ]; then would "apt-get install -y $1"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$1" >/dev/null 2>&1 && done_ "$1 $(dpkg-query -W -f '${Version}' "$1" 2>/dev/null) installed" || { bad "apt-get install $1 failed"; return 1; }
  if [ -n "${2:-}" ]; then systemctl disable --now "$2" >/dev/null 2>&1; active "$2" && bad "$2 was started by its package and did not stop" || ok "$2 is stopped and not enabled (its package starts it; only the pair may)"; fi
}
SBIN="zradio-serve zradio-notify zradio-sync zradio-switch zradio-change-watch zradio-render zradio-detect zradio-apply zradio-gate"
LIBF="zradio-common.sh zradio-probe.py zui-restore.py zui-settings.json keepalived.conf.tmpl zradio-sync.timer"
UNITS="zradio.target zradio-serve.service zradio-quiet.service zradio-hush.service zradio-sync.service zradio-sync-tick.service zradio-sync-tick.timer zradio-state.service zradio-state.timer zradio-change-watch.service zradio-gate.service"

echo "== 0. checks ($([ $RUN = 1 ] && echo RUN || echo REPORT) mode) =="
[ "$(id -u)" = 0 ] && ok "root" || bad "not root"
miss=""
for f in $SBIN; do [ -f "$HERE/sbin/$f" ] || miss="$miss sbin/$f"; done
for f in $LIBF zradio-usb-ids.py usb-annotations.json zradio-kit-stamp.sh zigpy-constraints.txt; do [ -f "$HERE/lib/$f" ] || miss="$miss lib/$f"; done
for f in $UNITS; do [ -f "$HERE/units/$f" ] || miss="$miss units/$f"; done
[ -z "$miss" ] && ok "the kit's files are all here ($HERE)" || bad "missing in $HERE:$miss"
TIMER_HELD=0        # 1 while this run holds zradio-sync.timer stopped (step 5); timer_release starts it again
timer_release() { # after systemd has read the timer's file again. Also on every way out of this script (the trap)
  [ "$TIMER_HELD" = 1 ] || return 0; TIMER_HELD=0
  systemctl daemon-reload >/dev/null 2>&1
  systemctl start zradio-sync.timer >/dev/null 2>&1 && ok "zradio-sync.timer was stopped while its file changed and runs again: the nightly sync is next at $SYNC_AT${SYNC_TZ:+ $SYNC_TZ}, not now" \
    || bad "systemctl start zradio-sync.timer failed: the nightly sync does not run until it is started"
}
TMP=$(mktemp -d) || exit 1; trap 'timer_release; rm -rf "$TMP"' EXIT
if [ -n "$CONF_SRC" ]; then
  [ -r "$CONF_SRC" ] || { bad "--conf $CONF_SRC: no such file"; CONF_SRC=""; }
  ZR_CONF=${CONF_SRC:-$R/etc/zradio/zradio.conf}
else ZR_CONF="$R/etc/zradio/zradio.conf"; fi
CONF_NAME=$ZR_CONF
[ $PEER_SAID = 0 ] || zr_ip4 "$SETPEER" || { bad "--peer '$SETPEER': the other radio VM's IPv4 address"; SETPEER=""; }
# What the conf leaves open is filled in here, into a copy that is then checked and installed like any other: SELF
# (this machine's own address), the VIP's prefix (that address's), PEER (--peer; else the one this VM already has).
if [ -r "$ZR_CONF" ] && zr_kv_only "$ZR_CONF"; then
  cv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1; }
  setkv() { # setkv <KEY> <value> <comment>: in place when the key has a line, else at the end under the comment
    if grep -q "^$1=" "$TMP/zradio.conf"; then sed -i "s|^$1=.*|$1=$2|" "$TMP/zradio.conf"; else printf '# %s\n%s=%s\n' "$3" "$1" "$2" >> "$TMP/zradio.conf"; fi
  }
  cp "$ZR_CONF" "$TMP/zradio.conf"
  c_self=$(cv SELF "$ZR_CONF"); c_vip=$(cv VIP "$ZR_CONF"); c_peer=$(cv PEER "$ZR_CONF"); own=""
  if [ -z "$c_self" ] || { [ -n "$c_vip" ] && [ "$c_vip" = "${c_vip%/*}" ]; }; then
    # this machine's addresses: "<interface> <address/prefix>" per line; the one that counts is SELF's, else the one on
    # IFACE, else the one on the default route's interface, else the first
    addrs=$("${ZRADIO_IP:-ip}" -o -4 addr show scope global 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')
    dev=$(cv IFACE "$ZR_CONF"); [ -n "$dev" ] || dev=$("${ZRADIO_IP:-ip}" -o -4 route show default 2>/dev/null | sed -n 's/^default .* dev \([^ ]*\).*/\1/p' | head -1)
    if [ -n "$c_self" ]; then own=$(printf '%s\n' "$addrs" | awk -v a="$c_self" '{ split($2, x, "/"); if (x[1] == a) { print; exit } }')
    else
      own=$(printf '%s\n' "$addrs" | awk -v d="$dev" 'd != "" && $1 == d { print; exit }'); [ -n "$own" ] || own=$(printf '%s\n' "$addrs" | head -1)
      if [ -n "$own" ]; then
        a=${own#* }; setkv SELF "${a%/*}" "this VM's own address on the day it was installed. It came from the network (DHCP): reserve it for this VM there"
        SELF_TAKEN="$a ${own% *}"          # "<address/prefix> <interface>", for the line below
      else bad "$CONF_NAME names no SELF, and this machine has no IPv4 address to take (ip -o -4 addr show scope global): give it one, or write SELF into the conf"; fi
    fi
    if [ -n "$own" ] && [ -n "$c_vip" ] && [ "$c_vip" = "${c_vip%/*}" ]; then
      setkv VIP "$c_vip/${own##*/}" "the floating address"
      python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in ipaddress.ip_interface(sys.argv[1]).network else 1)' "${own#* }" "$c_vip" 2>/dev/null \
        || bad "the floating address $c_vip is not in this VM's network (its own address is ${own#* }): the floating address is a free address of the same network"
    fi
  fi
  if [ -n "$SETPEER" ]; then
    [ -z "$c_peer" ] || [ "$c_peer" = "$SETPEER" ] || warn "PEER was $c_peer in $CONF_NAME: it is $SETPEER now (--peer)"
    setkv PEER "$SETPEER" "the other radio VM's address (the node's install.sh wrote it when the second VM was installed)"
  elif [ -z "$c_peer" ] && [ -n "$CONF_SRC" ]; then
    was=$(cv PEER "$R/etc/zradio/zradio.conf")           # a re-run with the first conf does not take the peer away again
    [ -z "$was" ] || setkv PEER "$was" "the other radio VM's address (the node's install.sh wrote it when the second VM was installed)"
  fi
  if ! cmp -s "$ZR_CONF" "$TMP/zradio.conf"; then CONF_SRC="$TMP/zradio.conf"; ZR_CONF=$CONF_SRC; fi
elif [ $PEER_SAID = 1 ]; then bad "--peer: there is no conf to write it into ($ZR_CONF)"; fi
if zr_load_conf; then ok "$CONF_NAME checks: $NAME, $SELF ↔ ${PEER:-no peer yet}, the floating address $VIP (VRID $VRID, priority $PRIORITY), ports $ZWAVE_PORT (Z-Wave) / $ZIGBEE_PORT (Zigbee)"
  [ -z "${SELF_TAKEN:-}" ] || warn "SELF: $CONF_NAME names no address for this VM, so the one it has is written into its conf: ${SELF_TAKEN%% *} on ${SELF_TAKEN#* }$(m=$(cat "/sys/class/net/${SELF_TAKEN#* }/address" 2>/dev/null); [ -z "$m" ] || echo " (MAC $m)"). The pair knows this VM by that address from now on: RESERVE it for this VM in your DHCP server. A VM whose address changes does not serve (zradio-serve status says so)"
  [ -n "$PEER" ] || warn "no PEER: this VM has no peer yet. It holds the floating address alone (keepalived sends VRRP's ordinary multicast adverts) until the pair's other VM is installed and this one is told its address (the node's install.sh does that; by hand: install.sh --peer A.B.C.D --run)"
  # the nightly timer's time, as it will be rendered: systemd says whether it is one. (The conf's own check knows a
  # time zone by its shape only; a mistyped one gives a timer that systemd does not load — and no sync at night.)
  cal="*-*-* $SYNC_AT:00${SYNC_TZ:+ $SYNC_TZ}"
  if ! command -v systemd-analyze >/dev/null 2>&1; then warn "systemd-analyze is not here: the nightly sync's time ($cal) was not checked"
  elif systemd-analyze calendar "$cal" >/dev/null 2>&1; then ok "the nightly sync's time is one systemd takes: $cal"
  else bad "SYNC_AT / SYNC_TZ: systemd does not take '$cal' as a time (systemd-analyze calendar). A time zone is a name such as Europe/Berlin (timedatectl list-timezones), or empty for the VM's own. With this one the nightly sync would never run"; fi
else bad "$ZR_ERR"; fi
# the table of the sticks the kit knows, in the kit's gen/ folder (never kept in git): run by the node, the one the
# node built and put into the kit; otherwise built here, now
GEN="$(cd "$HERE/.." && pwd)/gen"; IDS="$GEN/usb-ids.json"
if [ $BYNODE = 1 ] && [ -f "$IDS" ]; then ok "the table of the sticks the kit knows came with the kit (the node built it)"
elif [ -f "$HERE/lib/zradio-usb-ids.py" ]; then
  if mkdir -p "$GEN" && said=$(python3 "$HERE/lib/zradio-usb-ids.py" --out "$IDS" 2>&1); then ok "the table of the sticks the kit knows, built now into $GEN: $(printf '%s\n' "$said" | sed -n 's/^usb-ids.json: //p')"
  else bad "the table of the sticks the kit knows could not be built: $(printf '%s\n' "${said:-cannot make $GEN}" | grep -m1 -v '^usb-ids' | sed 's/^FAIL  //'). It is built from Home Assistant's USB lists on GitHub: this machine has to reach raw.githubusercontent.com"; fi
fi
echo "== checks: $FAILS FAIL =="
[ $FAILS -eq 0 ] || { echo "REFUSED: fix the FAIL lines; nothing was changed"; exit 1; }
export ZRADIO_LIB="$R/usr/local/lib/zradio" ZRADIO_CONF="$R/etc/zradio/zradio.conf" ZRADIO_RADIOS="$R/etc/zradio/radios.conf"
[ $RUN = 1 ] || export ZRADIO_LIB="$HERE/lib" ZRADIO_CONF="$ZR_CONF"      # report mode renders from the checkout
# shellcheck disable=SC2034  # read by zr_load_radios
ZR_RADIOS=$ZRADIO_RADIOS
export ZRADIO_DETECT_ETC="$R/etc/zradio" ZRADIO_DETECT_UDEV_RULES="$R/etc/udev/rules.d/99-zradio.rules"

echo "== 1. the kit's files =="
# the library before the tools that source it: a new tool beside the old library, for the moment in between, would
# call a function the old library does not have (a new library beside an old tool lacks nothing the old tool calls)
for f in $LIBF; do put "$HERE/lib/$f" "/usr/local/lib/zradio/$f" 644; done
for f in $SBIN; do put "$HERE/sbin/$f" "/usr/local/sbin/$f" 755; done
put "$IDS" /usr/local/lib/zradio/usb-ids.json 644
[ -z "$CONF_SRC" ] || put "$CONF_SRC" /etc/zradio/zradio.conf 644
if [ -f "$R/etc/zradio/zui/settings.json" ]; then ok "/etc/zradio/zui/settings.json exists (Z-Wave JS UI's own store: left as it is)"
elif [ $RUN = 1 ]; then mkdir -p "$R/etc/zradio/zui" && install -m 644 "$HERE/lib/zui-settings.json" "$R/etc/zradio/zui/settings.json" && done_ "/etc/zradio/zui/settings.json (the store of the container that writes a copied Z-Wave network)"
else would "install /etc/zradio/zui/settings.json"; fi
if [ $RUN = 1 ]; then mkdir -p "$R/var/lib/zradio" "$R/etc/zradio/.secrets" && chmod 700 "$R/etc/zradio/.secrets"; fi

echo "== 2. keepalived and ser2net (Debian's packages) =="
pkg keepalived keepalived || exit 1
pkg ser2net ser2net || exit 1

echo "== 3. the radios on this VM's USB ports =="
DET=${ZRADIO_INSTALL_DETECT:-$R/usr/local/sbin/zradio-detect}
if [ -f "$R/etc/zradio/radios.conf" ] && [ $DETECT = 0 ]; then ok "/etc/zradio/radios.conf exists: detection is not repeated (--detect looks again)"
  [ -z "$ROLE" ] || warn "--initial-role $ROLE is applied when the radios are looked at, once: nothing about it was changed on this run (the VM is installed already; who serves today: zradio-serve status; a VM that never had an initial role gets one with --detect, while it does not serve)"
elif [ $RUN = 1 ]; then
  if "$DET" --write "${USE[@]}" 2>&1 | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = 0 ]; then done_ "the radios are detected and named"
  else bad "zradio-detect did not end clean — read its lines above (on a VM that serves, detection is refused: run install.sh without --detect there)"; exit 1; fi
  # a "synced" stick that holds no network is an empty copy: this VM may not serve until a sync has filled it
  blank=$(python3 -c 'import json, sys
try: r = json.load(open(sys.argv[1]))["radios"]
except Exception: r = {}
print(" ".join(k for k in sorted(r) if r[k].get("level") == "synced" and r[k].get("holds_network") is False))' "$R/etc/zradio/radios.json" 2>/dev/null)
  held=$(python3 -c 'import json, sys
try: r = json.load(open(sys.argv[1]))["radios"]
except Exception: r = {}
print(" ".join(k for k in sorted(r) if r[k].get("level") == "synced" and r[k].get("holds_network") is True))' "$R/etc/zradio/radios.json" 2>/dev/null)
  unk=$(python3 -c 'import json, sys
try: r = json.load(open(sys.argv[1]))["radios"]
except Exception: r = {}
print(" ".join(k for k in sorted(r) if r[k].get("level") == "synced" and r[k].get("holds_network") is None))' "$R/etc/zradio/radios.json" 2>/dev/null)
  [ -z "$unk" ] || warn "it could not be told whether the $unk stick(s) hold a network (zradio-detect's lines above say why). Nothing is marked for them: they count as holding one. If they are empty, this VM must not serve first — install it as the standby (--initial-role standby), and the other VM's sync fills them"
  # The INITIAL role: who holds the house's networks on the day of the install. Afterward the two VMs swap freely
  # (a failover, a switch), so it is applied ONCE — the answer is kept in initial-role, and a later run that says the
  # same again changes nothing: it would otherwise mark a VM that has long since become the one that serves, or
  # unmark one that a sync is in the middle of filling. The mark itself says who set it: the installer writes a
  # line into it that begins "install.sh:"; zradio-sync's own (a set being written) is empty or names the networks in
  # doubt — the installer never lifts that one.
  MARK="$R/var/lib/zradio/standby-dirty"; WAS=$(cat "$R/var/lib/zradio/initial-role" 2>/dev/null | tr -dc a-z)
  sync_mark=0; if [ -e "$MARK" ] && ! grep -q '^install\.sh:' "$MARK" 2>/dev/null; then sync_mark=1; fi      # (zradio-sync's: empty, or the networks in doubt)
  if [ -n "$ROLE" ] && [ "$WAS" = "$ROLE" ]; then
    ok "this VM was installed as the initial $ROLE before: that is asked once, and nothing about it was changed (the two swap since then — who serves today: zradio-serve status)"
  elif [ "$ROLE" = standby ]; then
    if [ -s "$R/var/lib/zradio/synced.json" ]; then ok "initially the standby: its sticks were filled by a sync before ($R/var/lib/zradio/synced.json) — not marked again"
    else
      [ $sync_mark = 1 ] || echo "install.sh: the initial standby, not filled yet" > "$MARK"
      warn "this VM starts as the STANDBY: it is marked NOT FILLED ($MARK) and does not serve until the primary's first sync has written the house's networks onto its sticks. What they hold now is replaced then${held:+ — the $held stick(s) hold a network today: it will be OVERWRITTEN}${blank:+ (the $blank stick(s) are empty)}. After that sync the two VMs are equals and swap"
    fi
    echo standby > "$R/var/lib/zradio/initial-role"
    [ -z "$WAS" ] || warn "this VM was installed as the initial $WAS before; it is the initial standby now"
  elif [ "$ROLE" = primary ]; then
    if [ $sync_mark = 1 ]; then
      bad "this VM is to start as the PRIMARY, but a set from the other VM was being written onto its sticks and did not finish ($MARK is zradio-sync's): what they hold is not a whole network. Nothing was changed; the other VM's next sync finishes it (zradio-sync status)."
      exit 1
    fi
    if [ -n "$blank" ] && [ $FIRST = 0 ]; then
      bad "this VM is to start as the PRIMARY, but its $blank stick(s) hold no network. A new house with no network yet: run again with --first (Home Assistant forms the network). Your devices are on the OTHER node's sticks: then that node is the primary and this one the standby (--initial-role standby). Nothing was started, and this VM is marked NOT FILLED ($MARK): it does not serve empty sticks, whoever starts it."
      echo "install.sh: a primary whose sticks hold no network" > "$MARK"
      exit 1
    fi
    rm -f "$MARK"
    pmsg="${held:+its $held stick(s) hold the networks and stay as they are}"; [ -z "$blank" ] || pmsg="${pmsg:+$pmsg; }--first: the $blank stick(s) hold no network yet and Home Assistant forms it"
    ok "this VM starts as the PRIMARY: ${pmsg:-its sticks stay as they are (none of them is one the kit copies, so there was no network to look for)}. After the first sync the two VMs are equals and swap"
    echo primary > "$R/var/lib/zradio/initial-role"
    [ -z "$WAS" ] || warn "this VM was installed as the initial $WAS before; it is the initial primary now"
  elif [ -n "$blank" ] && [ $FIRST = 0 ]; then
    [ $sync_mark = 1 ] || echo "install.sh: sticks without a network" > "$MARK"
    warn "the $blank stick(s) here hold no network: this VM is marked NOT FILLED ($MARK) and does not serve until the other VM's sync has written its networks onto them. (A brand-new pair with new networks: run again with --first on the VM that serves first.)"
  elif [ -n "$blank" ]; then
    [ $sync_mark = 1 ] || rm -f "$MARK"; ok "--first: the $blank stick(s) hold no network and this VM may serve them all the same (Home Assistant forms the network)"
  fi
else would "zradio-detect --write ${USE[*]}  (nothing is typed: it lists the USB serial ports, asks each what it is, read-only, and names them)${ROLE:+; then as the initial $ROLE: $([ "$ROLE" = standby ] && echo "marked NOT FILLED until the primary's first sync" || echo "its sticks stay as they are and may be served")}"; fi
if zr_load_radios 2>/dev/null; then RADIOS_KNOWN=1; ok "radios: Z-Wave $ZWAVE${ZWAVE_FAMILY:+ ($ZWAVE_FAMILY)}, Zigbee $ZIGBEE${ZIGBEE_FAMILY:+ ($ZIGBEE_FAMILY)}"
else RADIOS_KNOWN=0; [ $RUN = 1 ] && { bad "$ZR_ERR"; exit 1; }; fi

echo "== 4. what these radios need =="
if [ $RADIOS_KNOWN = 0 ]; then would "by what is detected: podman + $ZUI_IMAGE for a synced Z-Wave stick; zigpy in /opt/zradio/zigpy for a synced Zigbee stick"
else
  if zr_has zwave synced; then
    pkg podman || exit 1
    if podman image exists "$ZUI_IMAGE" 2>/dev/null; then ok "image $ZUI_IMAGE is present"
    elif [ $RUN = 1 ]; then podman pull -q "$ZUI_IMAGE" >/dev/null 2>&1 && done_ "image $ZUI_IMAGE pulled" || bad "podman pull $ZUI_IMAGE failed (the standby could not write a copied Z-Wave network)"
    else would "podman pull $ZUI_IMAGE"; fi
    # Started once the way a write starts it (ZR_ZUI_RUN_OPTS), with no stick and no port: its own Node.js says its
    # version. Where this machine's podman does not start it so, that is known now — on an update, at the standby,
    # before the VM that serves is touched — and not at the first sync that has to write.
    if [ $RUN = 1 ] && podman image exists "$ZUI_IMAGE" 2>/dev/null; then
      # shellcheck disable=SC2086  # the options, as words
      if nv=$(podman run --rm $ZR_ZUI_RUN_OPTS --entrypoint node "$ZUI_IMAGE" --version 2>&1); then ok "the image starts with the rights a write gives it (Node.js $(printf '%s' "$nv" | tail -n 1 | tr -dc 'v0-9.'))"
      else bad "the image $ZUI_IMAGE does not start with the rights a write gives it (podman run --rm $ZR_ZUI_RUN_OPTS --entrypoint node … --version): $(printf '%s' "$nv" | tail -n 1 | cut -c1-200). This VM could not write a copied Z-Wave network"; fi
    fi
    # an image of the same name from an earlier pin: 400 MB of a small disk that nothing uses any more. Only once the
    # pinned one is here; one that a running container still uses stays (podman refuses to remove it).
    # (By image id: an image pulled by its digest has no tag in podman's list. [V podman 5.4.2, Debian 13])
    if [ $RUN = 1 ] && podman image exists "$ZUI_IMAGE" 2>/dev/null; then
      keep=$(podman image inspect --format '{{.Id}}' "$ZUI_IMAGE" 2>/dev/null); repo=${ZUI_IMAGE%%@*}; repo=${repo%:*}
      while read -r id old; do
        [ -n "$id" ] && [ -n "$keep" ] && [ "${keep#"$id"}" = "$keep" ] || continue      # (the list has an id's first characters)
        podman rmi "$id" >/dev/null 2>&1 && done_ "image $old removed (an earlier pin; ${ZUI_IMAGE%%@*} is the one in use)" || warn "image $old (an earlier pin) could not be removed: podman rmi $id"
      done < <(podman images --noheading --format '{{.ID}} {{.Repository}}:{{.Tag}}' --filter "reference=$repo" 2>/dev/null)
    fi
  else ok "no synced Z-Wave stick: podman and the Z-Wave JS UI image are not needed"; fi
  if zr_has zigbee synced; then
    # zigpy-cli at the pinned release, and under it the libraries the kit names (lib/zigpy-constraints.txt: pip alone
    # would take whatever is newest on the day, and two VMs made months apart would write with different code). The
    # venv says which release it holds (zradio-pin); one of a kit that did not stamp it is asked through its pip.
    VENV="$R/opt/zradio/zigpy"; PIN="zigpy-cli==$ZIGPY_VERSION"; CONS="$HERE/lib/zigpy-constraints.txt"
    cons=(); grep -qx "$PIN" "$CONS" 2>/dev/null && cons=(-c "$CONS")
    has=$(head -n 1 "$VENV/zradio-pin" 2>/dev/null)
    if [ -x "$VENV/bin/zigpy" ] && [ -z "$has" ]; then
      v=$("$VENV/bin/pip" show zigpy-cli 2>/dev/null | sed -n 's/^Version: //p' | head -n 1)
      if [ "$v" = "$ZIGPY_VERSION" ]; then has=$PIN; [ $RUN = 0 ] || echo "$PIN" > "$VENV/zradio-pin"; else has="zigpy-cli==${v:-?}"; fi
    fi
    if [ -x "$VENV/bin/zigpy" ] && [ "$has" = "$PIN" ]; then
      ok "zigpy-cli $ZIGPY_VERSION is at /opt/zradio/zigpy"
      # the libraries under it, against the kit's set: said where they differ (a venv made on another day)
      if [ ${#cons[@]} -gt 0 ]; then
        fr=$("$VENV/bin/pip" freeze 2>/dev/null) || fr=""; odd=""
        for lib in zigpy zigpy-znp; do
          h=$(printf '%s\n' "$fr" | sed -n "s/^$lib==//p" | head -n 1); k=$(sed -n "s/^$lib==//p" "$CONS" | head -n 1)
          [ -z "$h" ] || [ -z "$k" ] || [ "$h" = "$k" ] || odd="$odd${odd:+, }$lib $h here, $k in the kit's set"
        done
        [ -z "$odd" ] || warn "the libraries under zigpy-cli are those of the day this venv was made: $odd. The two VMs of a pair should hold the same (this line on the other VM says what it holds). To take the kit's set here: rm -rf /opt/zradio/zigpy and this installer again — on the standby, and let a sync show that it still writes"
      fi
    elif [ $RUN = 1 ]; then
      pkg python3-venv || exit 1
      if ! ( sync_idle ); then bad "zigpy-cli is to be installed again ($has here, $PIN in the conf) and a sync is running on this VM, which uses it: run this installer again when the sync has ended"
      else
        [ ${#cons[@]} -gt 0 ] || warn "the kit names no set of libraries for $PIN (lib/zigpy-constraints.txt is for $(grep -m1 '^zigpy-cli==' "$CONS" 2>/dev/null)): pip takes the newest that fit"
        rm -rf "$VENV.old"; [ ! -e "$VENV" ] || mv "$VENV" "$VENV.old"      # (a venv cannot be made elsewhere and moved: its scripts name its path)
        if [ -n "${ZRADIO_INSTALL_ZIGPY_SETUP:-}" ]; then "$ZRADIO_INSTALL_ZIGPY_SETUP" "$VENV" "$ZIGPY_VERSION"
        else python3 -m venv "$VENV" && "$VENV/bin/pip" install -q "${cons[@]}" "$PIN"; fi
        if [ -x "$VENV/bin/zigpy" ] && echo "$PIN" > "$VENV/zradio-pin"; then
          done_ "zigpy-cli $ZIGPY_VERSION installed in its own venv /opt/zradio/zigpy$([ ! -e "$VENV.old" ] || echo " (in place of $has)")"; rm -rf "$VENV.old"
        else
          rm -rf "$VENV"; put_back=""; if [ -e "$VENV.old" ]; then mv "$VENV.old" "$VENV" && put_back=" The venv that was there ($has) is put back"; fi
          bad "zigpy-cli $ZIGPY_VERSION did not install into /opt/zradio/zigpy (python3 -m venv + pip install $PIN; this machine has to reach pypi.org).$put_back"
        fi
      fi
    else would "python3 -m venv /opt/zradio/zigpy; pip install $PIN$([ -z "$has" ] || echo " (in place of $has)")"; fi
  else ok "no synced Zigbee stick: zigpy is not needed"; fi
fi
[ $FAILS -eq 0 ] || { echo "== FAILED before any service file was touched: $FAILS FAIL =="; exit 1; }

echo "== 5. the rendered files =="
RENDER="$R/usr/local/sbin/zradio-render"; [ $RUN = 1 ] || RENDER="$HERE/sbin/zradio-render"
if bash "$RENDER" --keepalived > "$TMP/keepalived.conf" 2> "$TMP/err"; then
  # tried BEFORE it is put in place: a file keepalived rejects must never replace the one a VM runs with (keepalived
  # would go on until its next start, and then not start)
  if [ $RUN = 0 ]; then put "$TMP/keepalived.conf" /etc/keepalived/keepalived.conf 644
  # (its words count as well as its exit code: an unknown keyword is said and skipped, with exit 0 [V keepalived 2.3.3])
  elif keepalived -t -f "$TMP/keepalived.conf" > "$TMP/kt" 2>&1 && ! grep -qi 'unknown keyword' "$TMP/kt"; then put "$TMP/keepalived.conf" /etc/keepalived/keepalived.conf 644; ok "keepalived -t accepts the config"
  else bad "keepalived -t refuses the new config: $(grep -i -m2 'unknown keyword' "$TMP/kt" | tr '\n' ' ')$(tail -2 "$TMP/kt" | tr '\n' ' ') — /etc/keepalived/keepalived.conf is left as it was"; fi
else bad "keepalived.conf does not render: $(cat "$TMP/err")"; fi
# The nightly timer, and a time that changes (SYNC_AT, SYNC_TZ). A timer that has run keeps the moment; at the next
# daemon-reload systemd finds the NEW time's next turn after that moment already past and runs the sync on the spot
# (2026-11-18: an update did that on the VM that served — 12 s without radios in the evening). A timer that is stopped
# while its file changes and started after the reload forgets its last run: the sync next runs when the clock says so
# [V systemd 255: tests/timer-real.sh]. So: stopped here, started below, right after the reload.
if bash "$RENDER" --timer > "$TMP/zradio-sync.timer" 2> "$TMP/err"; then
  if [ -f "$R/etc/systemd/system/zradio-sync.timer" ] && ! cmp -s "$TMP/zradio-sync.timer" "$R/etc/systemd/system/zradio-sync.timer" && active zradio-sync.timer; then
    if [ $RUN = 0 ]; then would "stop zradio-sync.timer while its file changes and start it after the reload (a new time must not run the sync now)"
    elif systemctl stop zradio-sync.timer >/dev/null 2>&1; then TIMER_HELD=1
    else warn "systemctl stop zradio-sync.timer failed: if its time changes, systemd may run the nightly sync at the reload below (about 12 s without radios on the VM that serves)"; fi
  fi
  put "$TMP/zradio-sync.timer" /etc/systemd/system/zradio-sync.timer 644
else bad "the nightly timer does not render: $(cat "$TMP/err")"; fi
if [ $RADIOS_KNOWN = 1 ]; then
  if bash "$RENDER" --ser2net > "$TMP/ser2net.yaml" 2> "$TMP/err"; then
    if [ $RUN = 1 ] && [ -f "$R/etc/ser2net.yaml" ] && [ ! -f "$R/etc/ser2net.yaml.dist" ] && ! grep -q "zradio-render --ser2net" "$R/etc/ser2net.yaml"; then cp -p "$R/etc/ser2net.yaml" "$R/etc/ser2net.yaml.dist"; fi
    put "$TMP/ser2net.yaml" /etc/ser2net.yaml 644
  else bad "ser2net.yaml does not render: $(cat "$TMP/err")"; fi
else would "render /etc/ser2net.yaml from the detected radios"; fi
[ $FAILS -eq 0 ] || { echo "== FAILED before the units were touched: $FAILS FAIL =="; exit 1; }

echo "== 6. the units =="
for u in $UNITS; do put "$HERE/units/$u" "/etc/systemd/system/$u" 644; done
printf '# zradio (install.sh): silent sticks first; a keepalived that dies comes back by itself; a keepalived that stops\n# (systemctl stop, a crash, the shutdown) stops this VM serving — its own notify at a stop is not reliable.\n[Unit]\nAfter=zradio-quiet.service\n[Service]\nRestart=always\nRestartSec=2\nExecStopPost=/usr/local/sbin/zradio-notify INSTANCE RADIO STOP 0\n' > "$TMP/dropin"
put "$TMP/dropin" /etc/systemd/system/keepalived.service.d/10-zradio.conf 644
# A VM that hangs or panics comes back by itself (the kit uses no Proxmox HA): systemd feeds the VM's virtual watchdog
# (the node's install.sh gives the VM one, set to reset it), and the kernel reboots after a panic. On a machine without
# a watchdog device only the panic part applies.
WATCHDOG_S=30            # seconds without systemd feeding the watchdog before the VM is reset
PANIC_REBOOT_S=10        # seconds from a kernel panic to the reboot
WDOG=${ZRADIO_INSTALL_WATCHDOG:-/dev/watchdog}
printf '# zradio (install.sh): a kernel panic reboots this VM\nkernel.panic = %s\n' "$PANIC_REBOOT_S" > "$TMP/panic"
put "$TMP/panic" /etc/sysctl.d/90-zradio.conf 644
if [ -e "$WDOG" ]; then
  printf '# zradio (install.sh): systemd feeds the VM'"'"'s watchdog; a hung VM is reset after %s s\n[Manager]\nRuntimeWatchdogSec=%ss\n' "$WATCHDOG_S" "$WATCHDOG_S" > "$TMP/watchdog"
  put "$TMP/watchdog" /etc/systemd/system.conf.d/90-zradio-watchdog.conf 644
else ok "no watchdog device ($WDOG): a hung machine is not reset by one (a radio VM the node made has one)"; fi
# A stick that appears (plugged in, its port switched on again, its USB device given back to the driver) powers up with
# its receiver on: zradio-serve hush silences it at once, and takes back a request for its power. A no-op on a VM that serves.
printf '%s\n' '# zradio (install.sh): a USB serial port that appears is a radio stick coming back: zradio-serve hush looks at it at once' \
  'ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyUSB*|ttyACM*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="zradio-hush.service"' > "$TMP/hushrule"
put "$TMP/hushrule" /etc/udev/rules.d/99-zradio-hush.rules 644
if [ $RUN = 1 ] && [ -z "$R" ] && [[ " $CHANGED " == *" /etc/udev/rules.d/99-zradio-hush.rules "* ]]; then udevadm control --reload >/dev/null 2>&1 || warn "udevadm control --reload failed: the new rule is read at the next boot"; fi
if [ $RUN = 1 ]; then
  systemctl daemon-reload && systemctl enable zradio.target zradio-quiet.service keepalived.service zradio-sync.timer zradio-sync-tick.timer zradio-state.timer zradio-change-watch.service zradio-gate.service >/dev/null 2>&1 \
    && done_ "enabled: zradio-quiet (silent sticks at boot), keepalived, the nightly sync ($SYNC_AT${SYNC_TZ:+ $SYNC_TZ}), the 15-min tick, the state line, the device-change watcher, the election's gate (ELECTION=$ELECTION) — nothing started" \
    || bad "systemctl enable failed"
  timer_release      # whatever the lines above said: the nightly sync must not stay without its timer
  systemctl disable ser2net >/dev/null 2>&1 || true
else would "systemctl daemon-reload; enable zradio.target, zradio-quiet, keepalived, zradio-sync.timer, zradio-sync-tick.timer, zradio-state.timer, zradio-change-watch, zradio-gate (nothing is started on a VM that is not in the pair)"; fi
# a re-run on a VM that is in the pair: say what still runs on the old files
if [ $RUN = 1 ]; then
  case " $CHANGED " in *" /etc/ser2net.yaml "*) active ser2net && warn "/etc/ser2net.yaml changed and ser2net is active (this VM serves): the new file is used from the next switch on (zradio-switch --run), or after 'systemctl restart ser2net' — a few seconds without radios for Home Assistant";; esac
  case " $CHANGED " in *" /etc/keepalived/keepalived.conf "*)
    if active keepalived && [ -n "$SETPEER" ]; then
      systemctl reload keepalived >/dev/null 2>&1 && done_ "keepalived reloaded: this VM sends its adverts to its peer $SETPEER now. On the VM that serves, the floating address was gone for about 4 seconds; Home Assistant connects again by itself" \
        || bad "systemctl reload keepalived failed: this VM does not talk to its peer $SETPEER yet ('systemctl restart keepalived' puts the new file in place)"
    elif active keepalived; then warn "/etc/keepalived/keepalived.conf changed and keepalived is active: 'systemctl restart keepalived' puts it in place (on the active VM that hands the radios to the other one)"; fi;; esac
  case " $CHANGED " in *" /etc/sysctl.d/90-zradio.conf "*) "${ZRADIO_INSTALL_SYSCTL:-sysctl}" -q -p "$R/etc/sysctl.d/90-zradio.conf" >/dev/null 2>&1 && ok "kernel.panic = $PANIC_REBOOT_S is in effect" || warn "sysctl did not take /etc/sysctl.d/90-zradio.conf now: it does at the next boot";; esac
  case " $CHANGED " in *" /etc/systemd/system.conf.d/90-zradio-watchdog.conf "*) systemctl daemon-reexec >/dev/null 2>&1 && ok "systemd feeds the watchdog now (RuntimeWatchdogSec=${WATCHDOG_S}s)" || warn "systemctl daemon-reexec failed: systemd feeds the watchdog from the next boot";; esac
  # What runs all the time reads its files once: the watcher its own file and the two confs, the gate its own, the
  # conf and the library every tool sources.
  case " $CHANGED " in *zradio-change-watch*|*" /etc/zradio/zradio.conf "*) ! active zradio-change-watch.service || idle_restart zradio-change-watch.service "it only watches";; esac
  case " $CHANGED " in *zradio-gate*|*zradio-common.sh*|*" /etc/zradio/zradio.conf "*) ! active zradio-gate.service || idle_restart zradio-gate.service "ELECTION=$ELECTION";; esac
  for t in zradio-sync-tick.timer zradio-state.timer; do      # (zradio-sync.timer: stopped and started around its change, above)
    case " $CHANGED " in *" /etc/systemd/system/$t "*) ! active "$t" || { systemctl restart "$t" >/dev/null 2>&1 && ok "$t restarted: its new times are in force" || warn "systemctl restart $t failed: it keeps its old times until then"; };; esac
  done
  # a VM that is in the pair, and a unit of the target that is not running: new in this kit (enabled above, which
  # starts nothing), or stopped by hand. Not keepalived: whoever stopped that took this VM out of the pair on purpose.
  if active zradio.target; then
    for u in zradio-gate.service zradio-change-watch.service zradio-sync.timer zradio-sync-tick.timer zradio-state.timer; do
      active "$u" || { systemctl start "$u" >/dev/null 2>&1 && done_ "$u started (this VM is in the pair and it was not running: new in this kit, or stopped)" || bad "systemctl start $u failed"; }
    done
  fi
fi

echo "== 7. this VM's sync key =="
if [ $RUN = 1 ]; then
  if K=$(env ZRADIO_SYNC_KEY="$R/etc/zradio/sync.key" ZRADIO_SYNC_HOSTKEY="${ZRADIO_INSTALL_HOSTKEY:-$R/etc/ssh/ssh_host_ed25519_key.pub}" bash "$R/usr/local/sbin/zradio-sync" keys 2>&1); then
    if [ $BYNODE = 1 ]; then done_ "the sync key is at /etc/zradio/sync.key (0600)"
    else
      done_ "the sync key is at /etc/zradio/sync.key (0600). On the OTHER radio VM${PEER:+ ($PEER)}, as root, run:"
      printf "      zradio-sync trust --sync-key '%s' --host-key '%s'\n" "$(printf '%s\n' "$K" | sed -n 's/^SYNCKEY //p')" "$(printf '%s\n' "$K" | sed -n 's/^HOSTKEY //p')"
    fi
  else bad "zradio-sync keys: $K"; fi
else would "zradio-sync keys (make the sync key if missing; print the line the other VM runs to trust this one)"; fi
# which kit this VM runs, for a later ./install.sh on the node: the node's stamp when it sent the kit, else made here.
# Installed last, so that a run that failed does not claim the new kit.
STAMP="$GEN/kit-version"
if [ $BYNODE = 0 ] || [ ! -f "$STAMP" ]; then bash "$HERE/lib/zradio-kit-stamp.sh" "$(dirname "$GEN")" || bad "the kit's version could not be stamped (lib/zradio-kit-stamp.sh)"; fi
[ $FAILS -ne 0 ] || [ ! -f "$STAMP" ] || put "$STAMP" /usr/local/lib/zradio/kit-version 644
[ $RUN = 1 ] || { echo "REPORT ONLY — nothing was changed."; exit 0; }
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL =="; exit 1; }
if [ $BYNODE = 1 ]; then echo "== installed =="          # the node's install.sh pairs the two VMs and starts them
else echo "== installed. Next: the same on the other VM, the two 'zradio-sync trust' lines, then 'systemctl start zradio.target' — $([ -n "$ROLE" ] && echo "in both" || echo "on the VM that holds the networks FIRST") =="; fi
exit 0
