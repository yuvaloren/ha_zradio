#!/usr/bin/env bash
# install.sh — makes THIS machine one radio VM of a zradio pair. Run INSIDE the VM as root, from a checkout of the kit
# (this file's directory holds sbin/, lib/ and units/). Report mode unless --run; re-runnable: nothing is rewritten
# that is already right, and a re-run is how a new version of the kit or a changed zradio.conf is put in place.
#
#   install.sh --conf my-zradio.conf [--run]     first install: the pair's one config file (zradio.conf.example)
#   install.sh [--run]                           later runs: /etc/zradio/zradio.conf is already there
#   --first        this VM serves first even though its sticks hold no network (a brand-new pair, new networks).
#                  Without it a VM whose "synced" sticks are blank is marked "not filled" and does not serve until the
#                  other VM's sync has written its networks onto them — so a new, empty standby can never take the
#                  radios away from the VM that has the house's devices.
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
#      /opt/zradio/zigpy (a Zigbee stick that is synced).
#   5. the rendered files: /etc/keepalived/keepalived.conf (checked with keepalived -t), /etc/ser2net.yaml (the
#      package's file is kept once as /etc/ser2net.yaml.dist), the nightly timer.
#   6. the units, and a drop-in for keepalived.service: the sticks are silenced first; a keepalived that dies comes
#      back by itself; a keepalived that stops (systemctl stop, a crash, the shutdown) stops this VM serving — its own
#      notify at a stop is not reliable [V: after a stop one VM's role file still said MASTER], and a crashed
#      keepalived runs none. Enabled: zradio-quiet (silent sticks at every boot), keepalived, the nightly sync, the
#      15-minute tick, the state line, the device-change watcher — and zradio.target, which names them all.
#      NOTHING IS STARTED: `systemctl start zradio.target`, or the next boot, puts this VM into the pair.
#   7. this VM's sync key (made if missing) and its two PUBLIC keys, with the line to run on the other VM.
# Refused before anything is changed: not root; a missing sibling file; a conf that does not check.
# Tests: tests/t-install.sh. Env for the tests: ZRADIO_INSTALL_ROOT (a prefix for every path written),
# ZRADIO_INSTALL_DETECT, ZRADIO_INSTALL_ZIGPY_SETUP, and systemctl / apt-get / dpkg-query / keepalived / podman on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${ZRADIO_INSTALL_ROOT:-}
RUN=0 CONF_SRC="" FIRST=0 DETECT=0 USE=()
while [ $# -gt 0 ]; do case "$1" in
  --run) RUN=1; shift;; --conf) CONF_SRC=$2; shift 2;; --first) FIRST=1; shift;; --detect) DETECT=1; shift;;
  --use) USE+=(--use "$2"); shift 2;;
  -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p}' "$0"; exit 0;; *) echo "unknown arg: $1" >&2; exit 2;; esac; done
FAILS=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
done_(){ printf 'DONE  %s\n' "$*"; }
would(){ printf 'WOULD %s\n' "$*"; }
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
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
SBIN="zradio-serve zradio-notify zradio-sync zradio-switch zradio-change-watch zradio-render zradio-detect zradio-apply"
LIBF="zradio-common.sh zradio-probe.py zui-restore.py zui-settings.json keepalived.conf.tmpl zradio-sync.timer usb-ids.json"
UNITS="zradio.target zradio-serve.service zradio-quiet.service zradio-hush.service zradio-sync.service zradio-sync-tick.service zradio-sync-tick.timer zradio-state.service zradio-state.timer zradio-change-watch.service"

echo "== 0. checks ($([ $RUN = 1 ] && echo RUN || echo REPORT) mode) =="
[ "$(id -u)" = 0 ] && ok "root" || bad "not root"
miss=""
for f in $SBIN; do [ -f "$HERE/sbin/$f" ] || miss="$miss sbin/$f"; done
for f in $LIBF; do [ -f "$HERE/lib/$f" ] || miss="$miss lib/$f"; done
for f in $UNITS; do [ -f "$HERE/units/$f" ] || miss="$miss units/$f"; done
[ -z "$miss" ] && ok "the kit's files are all here ($HERE)" || bad "missing in $HERE:$miss"
# shellcheck source=lib/zradio-common.sh
. "$HERE/lib/zradio-common.sh" || exit 2
if [ -n "$CONF_SRC" ]; then
  [ -r "$CONF_SRC" ] || { bad "--conf $CONF_SRC: no such file"; CONF_SRC=""; }
  ZR_CONF=${CONF_SRC:-$R/etc/zradio/zradio.conf}
else ZR_CONF="$R/etc/zradio/zradio.conf"; fi
if zr_load_conf; then ok "$ZR_CONF checks: $NAME, $SELF ↔ $PEER, the floating address $VIP (VRID $VRID, priority $PRIORITY), ports $ZWAVE_PORT (Z-Wave) / $ZIGBEE_PORT (Zigbee)"
else bad "$ZR_ERR"; fi
echo "== checks: $FAILS FAIL =="
[ $FAILS -eq 0 ] || { echo "REFUSED: fix the FAIL lines; nothing was changed"; exit 1; }
export ZRADIO_LIB="$R/usr/local/lib/zradio" ZRADIO_CONF="$R/etc/zradio/zradio.conf" ZRADIO_RADIOS="$R/etc/zradio/radios.conf"
[ $RUN = 1 ] || export ZRADIO_LIB="$HERE/lib" ZRADIO_CONF="$ZR_CONF"      # report mode renders from the checkout
# shellcheck disable=SC2034  # read by zr_load_radios
ZR_RADIOS=$ZRADIO_RADIOS
export ZRADIO_DETECT_ETC="$R/etc/zradio" ZRADIO_DETECT_UDEV_RULES="$R/etc/udev/rules.d/99-zradio.rules"

echo "== 1. the kit's files =="
for f in $SBIN; do put "$HERE/sbin/$f" "/usr/local/sbin/$f" 755; done
for f in $LIBF; do put "$HERE/lib/$f" "/usr/local/lib/zradio/$f" 644; done
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
elif [ $RUN = 1 ]; then
  if "$DET" --write "${USE[@]}" 2>&1 | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = 0 ]; then done_ "the radios are detected and named"
  else bad "zradio-detect did not end clean — read its lines above (on a VM that serves, detection is refused: run install.sh without --detect there)"; exit 1; fi
  # a "synced" stick that holds no network is an empty copy: this VM may not serve until a sync has filled it
  blank=$(python3 -c 'import json, sys
try: r = json.load(open(sys.argv[1]))["radios"]
except Exception: r = {}
print(" ".join(k for k in sorted(r) if r[k].get("level") == "synced" and r[k].get("holds_network") is False))' "$R/etc/zradio/radios.json" 2>/dev/null)
  if [ -n "$blank" ] && [ $FIRST = 0 ]; then
    : > "$R/var/lib/zradio/standby-dirty"
    warn "the $blank stick(s) here hold no network: this VM is marked NOT FILLED ($R/var/lib/zradio/standby-dirty) and does not serve until the other VM's sync has written its networks onto them. (A brand-new pair with new networks: run again with --first on the VM that serves first.)"
  elif [ -n "$blank" ]; then
    rm -f "$R/var/lib/zradio/standby-dirty"; ok "--first: the $blank stick(s) hold no network and this VM may serve them all the same (Home Assistant forms the network)"
  fi
else would "zradio-detect --write ${USE[*]}  (nothing is typed: it lists the USB serial ports, asks each what it is, read-only, and names them)"; fi
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
  else ok "no synced Z-Wave stick: podman and the Z-Wave JS UI image are not needed"; fi
  if zr_has zigbee synced; then
    if [ -x "$R/opt/zradio/zigpy/bin/zigpy" ]; then ok "zigpy is at /opt/zradio/zigpy"
    elif [ $RUN = 1 ]; then
      pkg python3-venv || exit 1
      if [ -n "${ZRADIO_INSTALL_ZIGPY_SETUP:-}" ]; then "$ZRADIO_INSTALL_ZIGPY_SETUP" "$R/opt/zradio/zigpy"
      else python3 -m venv "$R/opt/zradio/zigpy" && "$R/opt/zradio/zigpy/bin/pip" install -q zigpy-cli; fi
      [ -x "$R/opt/zradio/zigpy/bin/zigpy" ] && done_ "zigpy installed in its own venv /opt/zradio/zigpy" || bad "zigpy did not install into /opt/zradio/zigpy (python3 -m venv + pip install zigpy-cli)"
    else would "python3 -m venv /opt/zradio/zigpy; pip install zigpy-cli"; fi
  else ok "no synced Zigbee stick: zigpy is not needed"; fi
fi
[ $FAILS -eq 0 ] || { echo "== FAILED before any service file was touched: $FAILS FAIL =="; exit 1; }

echo "== 5. the rendered files =="
TMP=$(mktemp -d) || exit 1; trap 'rm -rf "$TMP"' EXIT
RENDER="$R/usr/local/sbin/zradio-render"; [ $RUN = 1 ] || RENDER="$HERE/sbin/zradio-render"
if bash "$RENDER" --keepalived > "$TMP/keepalived.conf" 2> "$TMP/err"; then
  put "$TMP/keepalived.conf" /etc/keepalived/keepalived.conf 644
  if [ $RUN = 1 ]; then keepalived -t -f "$R/etc/keepalived/keepalived.conf" > "$TMP/kt" 2>&1 && ok "keepalived -t accepts the config" || bad "keepalived -t: $(tail -2 "$TMP/kt" | tr '\n' ' ')"; fi
else bad "keepalived.conf does not render: $(cat "$TMP/err")"; fi
if bash "$RENDER" --timer > "$TMP/zradio-sync.timer" 2> "$TMP/err"; then put "$TMP/zradio-sync.timer" /etc/systemd/system/zradio-sync.timer 644
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
if [ $RUN = 1 ]; then
  systemctl daemon-reload && systemctl enable zradio.target zradio-quiet.service keepalived.service zradio-sync.timer zradio-sync-tick.timer zradio-state.timer zradio-change-watch.service >/dev/null 2>&1 \
    && done_ "enabled: zradio-quiet (silent sticks at boot), keepalived, the nightly sync ($SYNC_AT${SYNC_TZ:+ $SYNC_TZ}), the 15-min tick, the state line, the device-change watcher — nothing started" \
    || bad "systemctl enable failed"
  systemctl disable ser2net >/dev/null 2>&1 || true
else would "systemctl daemon-reload; enable zradio.target, zradio-quiet, keepalived, zradio-sync.timer, zradio-sync-tick.timer, zradio-state.timer, zradio-change-watch (nothing is started)"; fi
# a re-run on a VM that is in the pair: say what still runs on the old files
if [ $RUN = 1 ]; then
  case " $CHANGED " in *" /etc/ser2net.yaml "*) active ser2net && warn "/etc/ser2net.yaml changed and ser2net is active (this VM serves): the new file is used from the next switch on (zradio-switch --run), or after 'systemctl restart ser2net' — a few seconds without radios for Home Assistant";; esac
  case " $CHANGED " in *" /etc/keepalived/keepalived.conf "*) active keepalived && warn "/etc/keepalived/keepalived.conf changed and keepalived is active: 'systemctl restart keepalived' puts it in place (on the active VM that hands the radios to the other one)";; esac
  case " $CHANGED " in *zradio-change-watch*) active zradio-change-watch && { systemctl restart zradio-change-watch >/dev/null 2>&1; ok "zradio-change-watch restarted on the new file (it only watches)"; };; esac
fi

echo "== 7. this VM's sync key =="
if [ $RUN = 1 ]; then
  if K=$(env ZRADIO_SYNC_KEY="$R/etc/zradio/sync.key" ZRADIO_SYNC_HOSTKEY="${ZRADIO_INSTALL_HOSTKEY:-$R/etc/ssh/ssh_host_ed25519_key.pub}" bash "$R/usr/local/sbin/zradio-sync" keys 2>&1); then
    done_ "the sync key is at /etc/zradio/sync.key (0600). On the OTHER radio VM ($PEER), as root, run:"
    printf "      zradio-sync trust --sync-key '%s' --host-key '%s'\n" "$(printf '%s\n' "$K" | sed -n 's/^SYNCKEY //p')" "$(printf '%s\n' "$K" | sed -n 's/^HOSTKEY //p')"
  else bad "zradio-sync keys: $K"; fi
else would "zradio-sync keys (make the sync key if missing; print the line the other VM runs to trust this one)"; fi
[ $RUN = 1 ] || { echo "REPORT ONLY — nothing was changed."; exit 0; }
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL =="; exit 1; }
echo "== installed. Next: the same on the other VM, the two 'zradio-sync trust' lines, then 'systemctl start zradio.target' — on the VM that holds the networks FIRST =="
exit 0
