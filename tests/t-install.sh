#!/usr/bin/env bash
# t-install.sh — guest/install.sh against a fake radio VM: every path it writes under a temp root
# (ZRADIO_INSTALL_ROOT); systemctl, apt-get, dpkg-query, keepalived, podman, id and ip are fakes on PATH (recorded);
# zradio-detect is a fake that writes the radios.conf / radios.json a detection would (its own tests: t-detect.sh);
# the zigpy venv is made by a fake. zradio-render, zradio-sync (keys) and the common loader are the real ones.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/install.sh"
. "$TESTS_DIR/fake-guest.sh"
inst() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_INSTALL_ROOT="$d/root" ZRADIO_INSTALL_DETECT="$d/detect" ZRADIO_INSTALL_ZIGPY_SETUP="$d/zigpy-setup" bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }
R() { printf '%s/root%s' "$1" "$2"; }

echo "-- report mode: WOULD lines, nothing written, nothing installed"
vm "$T/r"; inst "$T/r" --conf "$T/r/my.conf"
check "exit 0, REPORT ONLY" bash -c '[ "$2" = 0 ] && grep -q "REPORT ONLY — nothing was changed" "$1/out"' _ "$T/r" "$RC"
check "the conf is read back in one line" has "$T/r/out" "radio2, 10.20.30.6 ↔ 10.20.30.5, the floating address 10.20.30.50/24 (VRID 50, priority 100), ports 6639 (Z-Wave) / 6638 (Zigbee)"
check "WOULD: the packages, the detection, the units" bash -c 'for w in "apt-get install -y keepalived" "apt-get install -y ser2net" "WOULD zradio-detect --write" "WOULD install /usr/local/sbin/zradio-serve (755)" "WOULD systemctl daemon-reload"; do grep -qF "$w" "$1/out" || exit 1; done' _ "$T/r"
check "nothing written under the root, no apt-get, no enable" bash -c '[ ! -e "$1/root/usr" ] && [ ! -e "$1/root/etc/zradio" ] && ! grep -qE "^(apt-get|podman pull|systemctl (enable|daemon-reload))" "$1/calls"' _ "$T/r"

echo "-- --run on a new VM whose sticks hold the networks"
vm "$T/w"; inst "$T/w" --conf "$T/w/my.conf" --run
check "exit 0" eq "$RC" 0
check "the nine tools 0755 and the library" bash -c 'for f in zradio-serve zradio-notify zradio-sync zradio-switch zradio-change-watch zradio-render zradio-detect zradio-apply zradio-gate; do [ "$(stat -c %a "$1/root/usr/local/sbin/$f")" = 755 ] || exit 1; done; for f in zradio-common.sh zradio-probe.py zui-restore.py usb-ids.json keepalived.conf.tmpl; do [ -f "$1/root/usr/local/lib/zradio/$f" ] || exit 1; done' _ "$T/w"
check "the conf is in place, byte for byte" cmp -s "$T/w/my.conf" "$(R "$T/w" /etc/zradio/zradio.conf)"
check "keepalived and ser2net installed; both stopped again and not enabled by their packages" bash -c 'grep -q "^apt-get install -y -q keepalived" "$1/calls" && grep -q "^apt-get install -y -q ser2net" "$1/calls" && grep -q "^systemctl disable --now ser2net" "$1/calls" && grep -q "^systemctl disable --now keepalived" "$1/calls" && [ "$(cat "$1/ser2net")" = 0 ]' _ "$T/w"
check "detection ran once, with --write" eq "$(grep -c '^zradio-detect --write$' "$T/w/calls")" 1
check "a synced Z-Wave stick: podman installed, the pinned image pulled" bash -c 'grep -q "^apt-get install -y -q podman" "$1/calls" && grep -q "^podman pull -q docker.io/zwavejs/zwave-js-ui:11.27.0@sha256:[0-9a-f]\{64\}$" "$1/calls"' _ "$T/w"
check "a synced Zigbee stick: zigpy in its own venv" bash -c 'grep -q "^zigpy-setup .*/opt/zradio/zigpy" "$1/calls" && [ -x "$1/root/opt/zradio/zigpy/bin/zigpy" ]' _ "$T/w"
# the real line (no setup hook): python3 -m venv, then pip with the PINNED release from zradio.conf's default
vm "$T/pin"; REALPY=$(command -v python3)
fake "$T/pin/bin" python3 "if [ \"\$1 \$2\" = '-m venv' ]; then mkdir -p \"\$3/bin\" && printf '#!/bin/sh\necho \"pip \$*\" >> %s\nprintf \"#!/bin/sh\\\\n\" > %s/bin/zigpy; chmod +x %s/bin/zigpy\n' '$T/pin/calls' \"\$3\" \"\$3\" > \"\$3/bin/pip\" && chmod +x \"\$3/bin/pip\"; else exec '$REALPY' \"\$@\"; fi"
PATH="$T/pin/bin:$PATH" ZRADIO_INSTALL_ROOT="$T/pin/root" ZRADIO_INSTALL_DETECT="$T/pin/detect" bash "$TOOL" --conf "$T/pin/my.conf" --run > "$T/pin/out" 2>&1
check "zigpy-cli is installed at a pinned release (2.0.0 unless zradio.conf says otherwise), not whatever is newest that day" bash -c 'grep -q "^pip install -q -c .*/guest/lib/zigpy-constraints.txt zigpy-cli==2.0.0$" "$1/calls" && grep -q "zigpy-cli 2.0.0 installed in its own venv" "$1/out"' _ "$T/pin"
vm "$T/pin2"; echo "ZIGPY_VERSION=latest" >> "$T/pin2/my.conf"; inst "$T/pin2" --conf "$T/pin2/my.conf" --run
check "ZIGPY_VERSION that is not a release number: the conf is refused, nothing installed" bash -c '[ "$2" != 0 ] && grep -q "ZIGPY_VERSION .latest.: a zigpy-cli release" "$1/out" && ! grep -q "^apt-get" "$1/calls"' _ "$T/pin2" "$RC"
check "keepalived.conf rendered for this VM (eth1 holds SELF) and checked with keepalived -t" bash -c 'grep -qx "    interface eth1" "$1/root/etc/keepalived/keepalived.conf" && grep -qx "    unicast_src_ip 10.20.30.6" "$1/root/etc/keepalived/keepalived.conf" && grep -q "^keepalived -t -f " "$1/calls"' _ "$T/w"
check "ser2net.yaml: both radios on the floating address; the package's file kept once as .dist" bash -c '[ "$(grep -c "accepter: tcp,10.20.30.50," "$1/root/etc/ser2net.yaml")" = 2 ] && grep -q "the package.s file" "$1/root/etc/ser2net.yaml.dist"' _ "$T/w"
check "the nightly timer at the default time" has "$(R "$T/w" /etc/systemd/system/zradio-sync.timer)" "OnCalendar=*-*-* 04:30:00"
check "the units and the keepalived drop-in (silent sticks first, Restart=always, a stop stops the serving)" bash -c 'for u in zradio.target zradio-gate.service zradio-serve.service zradio-quiet.service zradio-hush.service zradio-sync.service zradio-sync-tick.timer zradio-state.timer zradio-change-watch.service; do [ -f "$1/root/etc/systemd/system/$u" ] || exit 1; done; D="$1/root/etc/systemd/system/keepalived.service.d/10-zradio.conf"; grep -qx "After=zradio-quiet.service" "$D" && grep -qx "Restart=always" "$D" && grep -qx "ExecStopPost=/usr/local/sbin/zradio-notify INSTANCE RADIO STOP 0" "$D"' _ "$T/w"
check "a USB serial port that appears starts zradio-hush (a stick that comes back is silenced at once): the udev rule is installed" bash -c 'grep -qx "ACTION==\"add\", SUBSYSTEM==\"tty\", KERNEL==\"ttyUSB\*|ttyACM\*\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"zradio-hush.service\"" "$1/root/etc/udev/rules.d/99-zradio-hush.rules"' _ "$T/w"
check "enabled, nothing started; ser2net never enabled" bash -c 'grep -q "^systemctl enable zradio.target zradio-quiet.service keepalived.service zradio-sync.timer zradio-sync-tick.timer zradio-state.timer zradio-change-watch.service zradio-gate.service" "$1/calls" && ! grep -qE "^systemctl (start|restart|enable .*ser2net)" "$1/calls"' _ "$T/w"
check "the sync key is made (0600) and the line for the other VM is printed with both public keys" bash -c '[ "$(stat -c %a "$1/root/etc/zradio/sync.key")" = 600 ] && grep -qE "^      zradio-sync trust --sync-key .ssh-ed25519 [A-Za-z0-9+/=]+. --host-key .ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKey" "$1/out"' _ "$T/w"
check "no private key in the output" bash -c '! grep -q "PRIVATE KEY" "$1/out"' _ "$T/w"
check "sticks that hold networks: not marked 'not filled'" bash -c '[ ! -e "$1/root/var/lib/zradio/standby-dirty" ]' _ "$T/w"
check "the last line says who starts first" has "$T/w/out" "on the VM that holds the networks FIRST"

echo "-- a second run: everything is current, nothing is installed or detected again"
: > "$T/w/calls"; inst "$T/w" --run
check "exit 0 without --conf (the installed conf is used)" eq "$RC" 0
check "no DONE … installed line, no apt-get, no detection, no pull" bash -c '! grep -q "^DONE  .* installed" "$1/out" && ! grep -qE "^(apt-get|zradio-detect|podman pull|zigpy-setup)" "$1/calls"' _ "$T/w"
cp "$T/w/root/etc/zradio/sync.key" "$T/w/key1"; inst "$T/w" --run
check "the sync key is the same one" cmp -s "$T/w/key1" "$(R "$T/w" /etc/zradio/sync.key)"
inst "$T/w" --run --detect --use zigbee=/dev/ttyUSB3
check "--detect looks again, --use is passed on" has "$T/w/calls" "zradio-detect --write --use zigbee=/dev/ttyUSB3"

echo "-- --initial-role (what the VM is on the day of the install; the two swap later): the primary's sticks stay as they are; the standby does not serve before the primary's first sync"
vm "$T/rs" both; inst "$T/rs" --conf "$T/rs/my.conf" --initial-role standby --run
check "standby whose sticks HOLD a network (an old copy, another house's): marked NOT FILLED all the same, and told what will be overwritten" bash -c '[ "$2" = 0 ] && [ -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "WARN  this VM starts as the STANDBY: it is marked NOT FILLED" "$1/out" && grep -q "the zigbee zwave stick(s) hold a network today: it will be OVERWRITTEN" "$1/out" && grep -q "the two VMs are equals and swap" "$1/out" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = standby ] && grep -q "^install.sh: the initial standby" "$1/root/var/lib/zradio/standby-dirty"' _ "$T/rs" "$RC"
sc0() { : > "$1/tty"; ZRADIO_RADIOS="$1/root/etc/zradio/radios.conf" ZRADIO_SERVE_STATE="$1/root/var/lib/zradio" ZRADIO_SERVE_RUN="$1/run" ZRADIO_SERVE_ZWAVE_TTY="$1/tty" ZRADIO_SERVE_ZIGBEE_TTY="$1/tty" bash "$KIT/guest/sbin/zradio-serve" check; }
sc0 "$T/rs"; check "…zradio-serve check refuses to serve: that network cannot reach the air from here" eq "$?" 1
rm -f "$T/rs/root/var/lib/zradio/standby-dirty"      # months later: a sync filled it, there was a failover, it is the VM that serves or served
inst "$T/rs" --initial-role standby --detect --run
check "THE SWAP: the same line run again later does not mark the VM — the initial role is used once" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "OK    this VM was installed as the initial standby before: that is asked once, and nothing about it was changed" "$1/out" && ! grep -q "starts as the STANDBY" "$1/out"' _ "$T/rs" "$RC"
: > "$T/rs/root/var/lib/zradio/standby-dirty"        # zradio-sync's own mark (empty): a set is being written onto the sticks
inst "$T/rs" --initial-role primary --detect --run
check "a VM in the middle of being filled by a sync, said to be the primary: refused, zradio-sync's mark stays" bash -c '[ "$2" = 1 ] && [ -e "$1/root/var/lib/zradio/standby-dirty" ] && [ ! -s "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "FAIL  this VM is to start as the PRIMARY, but a set from the other VM was being written" "$1/out" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = standby ]' _ "$T/rs" "$RC"
sc0 "$T/rs"; check "…and it still does not serve" eq "$?" 1
printf 'zwave\nzigbee\n' > "$T/rs/root/var/lib/zradio/standby-dirty"        # zradio-sync's mark as it is now: the networks in doubt
inst "$T/rs" --initial-role primary --detect --run
check "…the same with the mark that names the networks: refused, and the mark is as it was (it is not the installer's to lift)" bash -c '[ "$2" = 1 ] && [ "$(tr "\n" " " < "$1/root/var/lib/zradio/standby-dirty")" = "zwave zigbee " ] && grep -q "FAIL  this VM is to start as the PRIMARY, but a set from the other VM was being written" "$1/out"' _ "$T/rs" "$RC"
rm -f "$T/rs/root/var/lib/zradio/standby-dirty" "$T/rs/root/var/lib/zradio/initial-role"; echo '{"gen":"g1"}' > "$T/rs/root/var/lib/zradio/synced.json"
inst "$T/rs" --initial-role standby --detect --run       # a VM from before the role was asked, filled by a sync
check "a standby that a sync has filled and that never had an initial role: not marked, the role is kept" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "filled by a sync before" "$1/out" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = standby ]' _ "$T/rs" "$RC"
vm "$T/rc" both; inst "$T/rc" --conf "$T/rc/my.conf" --initial-role standby --run; inst "$T/rc" --initial-role primary --detect --run
check "the wrong answer, corrected before any sync (standby -> primary): the installer lifts its own mark, and says what it was" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = primary ] && grep -q "WARN  this VM was installed as the initial standby before; it is the initial primary now" "$1/out"' _ "$T/rc" "$RC"
inst "$T/rc" --initial-role standby --detect --run
check "…and back (primary -> standby): marked again, by the installer" bash -c '[ "$2" = 0 ] && grep -q "^install.sh:" "$1/root/var/lib/zradio/standby-dirty" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = standby ]' _ "$T/rc" "$RC"
vm "$T/rs2" blank; inst "$T/rs2" --conf "$T/rs2/my.conf" --initial-role standby --run
check "standby with empty sticks: marked the same way" bash -c '[ "$2" = 0 ] && [ -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "(the zigbee zwave stick(s) are empty)" "$1/out"' _ "$T/rs2" "$RC"
vm "$T/rp" both; inst "$T/rp" --conf "$T/rp/my.conf" --initial-role primary --run
check "primary whose sticks hold the networks: not marked, said" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "OK    this VM starts as the PRIMARY: its zigbee zwave stick(s) hold the networks and stay as they are" "$1/out" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = primary ]' _ "$T/rp" "$RC"
vm "$T/rp2" blank; inst "$T/rp2" --conf "$T/rp2/my.conf" --initial-role primary --run
check "primary whose sticks are EMPTY: refused — a new house says --first; devices on the other node means this one is the standby" bash -c '[ "$2" = 1 ] && grep -q "FAIL  this VM is to start as the PRIMARY, but its zigbee zwave stick(s) hold no network" "$1/out" && grep -q "then that node is the primary and this one the standby" "$1/out" && ! grep -q "enable.*zradio.target" "$1/calls"' _ "$T/rp2" "$RC"
check "…and it is left marked NOT FILLED: started by hand all the same, it does not serve the empty sticks" bash -c '[ -e "$1/root/var/lib/zradio/standby-dirty" ] && ! grep -q "this VM starts as the PRIMARY" "$1/out" && [ ! -e "$1/root/var/lib/zradio/initial-role" ]' _ "$T/rp2"
sc0 "$T/rp2"; check "…zradio-serve check says no" eq "$?" 1
inst "$T/rp2" --initial-role primary --first --detect --run
check "…the same with --first (a new house): accepted, may serve" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "starts as the PRIMARY: --first: the zigbee zwave stick(s) hold no network yet" "$1/out" && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = primary ]' _ "$T/rp2" "$RC"
inst "$T/rp" --initial-role standby --run
check "a later run WITHOUT --detect does not change the role: said, the primary is not marked" bash -c '[ "$2" = 0 ] && grep -q "role standby is applied when the radios are looked at, once: nothing about it was changed on this run" "$1/out" && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && [ "$(cat "$1/root/var/lib/zradio/initial-role")" = primary ]' _ "$T/rp" "$RC"
vm "$T/rx"; inst "$T/rx" --conf "$T/rx/my.conf" --initial-role standby --first --run
check "--initial-role standby --first: refused before anything" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/rx" "$RC"
inst "$T/rx" --conf "$T/rx/my.conf" --initial-role master --run
check "--initial-role that is neither primary nor standby: refused before anything" bash -c '[ "$2" = 2 ] && [ ! -s "$1/calls" ]' _ "$T/rx" "$RC"

echo "-- without --initial-role (as before): a new standby with blank sticks is marked 'not filled'; --first lifts that"
vm "$T/b" blank; inst "$T/b" --conf "$T/b/my.conf" --run
check "exit 0, the marker is there, and the reason is said" bash -c '[ "$2" = 0 ] && [ -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "WARN  the zigbee zwave stick(s) here hold no network: this VM is marked NOT FILLED" "$1/out"' _ "$T/b" "$RC"
sc() { : > "$1/tty"; ZRADIO_RADIOS="$1/root/etc/zradio/radios.conf" ZRADIO_SERVE_STATE="$1/root/var/lib/zradio" ZRADIO_SERVE_RUN="$1/run" ZRADIO_SERVE_ZWAVE_TTY="$1/tty" ZRADIO_SERVE_ZIGBEE_TTY="$1/tty" bash "$KIT/guest/sbin/zradio-serve" check; }
sc "$T/b"; check "zradio-serve check refuses to serve on that marker (the sticks' ttys are there)" eq "$?" 1
rm -f "$T/b/root/var/lib/zradio/standby-dirty"; sc "$T/b"; check "…and passes once a sync has cleared it" eq "$?" 0
vm "$T/b2" blank; inst "$T/b2" --conf "$T/b2/my.conf" --run --first
check "--first: no marker (a brand-new pair: this VM may serve blank sticks)" bash -c '[ "$2" = 0 ] && [ ! -e "$1/root/var/lib/zradio/standby-dirty" ] && grep -q "OK    --first" "$1/out"' _ "$T/b2" "$RC"

echo "-- only what the radios need"
vm "$T/s" served; inst "$T/s" --conf "$T/s/my.conf" --run
check "served-only sticks: no podman, no image, no zigpy; ser2net.yaml still has both" bash -c '[ "$2" = 0 ] && ! grep -qE "podman|zigpy-setup" "$1/calls" && [ "$(grep -c "^connection:" "$1/root/etc/ser2net.yaml")" = 2 ]' _ "$T/s" "$RC"
vm "$T/z" zwave-only; inst "$T/z" --conf "$T/z/my.conf" --run
check "a Z-Wave stick only: podman, no zigpy, one connection" bash -c '[ "$2" = 0 ] && grep -q "podman pull" "$1/calls" && ! grep -q zigpy-setup "$1/calls" && [ "$(grep -c "^connection:" "$1/root/etc/ser2net.yaml")" = 1 ]' _ "$T/z" "$RC"

echo "-- refusals and failures"
vm "$T/x1"; printf '%s\n' NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 > "$T/x1/my.conf"; inst "$T/x1" --conf "$T/x1/my.conf" --run
check "a conf that does not check: REFUSED, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  SELF and PEER are both" "$1/out" && grep -q "REFUSED" "$1/out" && [ ! -e "$1/root/usr" ] && ! grep -q "^apt-get" "$1/calls"' _ "$T/x1" "$RC"
vm "$T/x2"; inst "$T/x2" --run
check "no conf anywhere: REFUSED, says where it belongs" bash -c '[ "$2" = 1 ] && grep -q "copy zradio.conf.example there" "$1/out"' _ "$T/x2" "$RC"
vm "$T/x3"; : > "$T/x3/detect-fail"; inst "$T/x3" --conf "$T/x3/my.conf" --run
check "no stick found: exit 1 after the files and packages, before any service file" bash -c '[ "$2" = 1 ] && grep -q "FAIL  zradio-detect did not end clean" "$1/out" && [ ! -e "$1/root/etc/keepalived/keepalived.conf" ] && ! grep -q "^systemctl enable" "$1/calls"' _ "$T/x3" "$RC"
vm "$T/x4"; mkdir -p "$T/x4/root/etc/keepalived"; echo "# the config this VM runs with" > "$T/x4/root/etc/keepalived/keepalived.conf"; : > "$T/x4/kt-fail"; inst "$T/x4" --conf "$T/x4/my.conf" --run
check "…and the file is tried BEFORE it is put in place: the config the VM runs with is left as it was" bash -c '[ "$(cat "$1/root/etc/keepalived/keepalived.conf")" = "# the config this VM runs with" ] && grep -q "is left as it was" "$1/out"' _ "$T/x4"
check "keepalived -t rejects the rendered file: exit 1, nothing enabled" bash -c '[ "$2" = 1 ] && grep -q "FAIL  keepalived -t" "$1/out" && ! grep -q "^systemctl enable" "$1/calls"' _ "$T/x4" "$RC"
# (podman's list, as it is for an image pulled by its digest: no tag; and an earlier pin's, pulled by its tag)
vm "$T/im"; printf '%s\n' "714decaa6080 docker.io/zwavejs/zwave-js-ui:<none>" "4f9744b6069c docker.io/zwavejs/zwave-js-ui:11.25.2" > "$T/im/images"; inst "$T/im" --conf "$T/im/my.conf" --run
check "an image of an earlier pin is on the VM: removed by its id once the pinned one is here (400 MB of a small disk); the pinned one is not touched" bash -c '[ "$2" = 0 ] && grep -qx "podman rmi 4f9744b6069c" "$1/calls" && [ "$(grep -c "^podman rmi" "$1/calls")" = 1 ] && grep -q "DONE  image docker.io/zwavejs/zwave-js-ui:11.25.2 removed (an earlier pin" "$1/out" && grep -q "^podman images --noheading .* --filter reference=docker.io/zwavejs/zwave-js-ui$" "$1/calls"' _ "$T/im" "$RC"
vm "$T/im2"; echo "4f9744b6069c docker.io/zwavejs/zwave-js-ui:11.25.2" > "$T/im2/images"; : > "$T/im2/rmi-fail"; inst "$T/im2" --conf "$T/im2/my.conf" --run
check "…it cannot be removed (a container still uses it): a warning, and the install goes on" bash -c '[ "$2" = 0 ] && grep -q "WARN  image docker.io/zwavejs/zwave-js-ui:11.25.2 (an earlier pin) could not be removed" "$1/out"' _ "$T/im2" "$RC"
check "the pins agree: the example conf names the Z-Wave JS UI image and the zigpy-cli release the kit itself pins" bash -c 'z=$(sed -n "s/^ZR_ZUI_IMAGE=\([^ ]*\).*/\1/p" "$1/guest/lib/zradio-common.sh") && [ -n "$z" ] && grep -qx "ZUI_IMAGE=$z" "$1/zradio.conf.example" && v=$(sed -n "s/^ *ZIGPY_VERSION=\([0-9][0-9a-z.]*\)$/\1/p" "$1/guest/lib/zradio-common.sh" | head -1) && [ -n "$v" ] && grep -qx "#ZIGPY_VERSION=$v" "$1/zradio.conf.example"' _ "$KIT"
vm "$T/x5"; inst "$T/x5" --conf "$T/x5/my.conf" --run --peer
check "--peer given last without an address: exit 2, said (it used to loop for ever), nothing done" bash -c '[ "$2" = 2 ] && grep -q "^--peer needs a value" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/x5" "$RC"
vm "$T/x5"; : > "$T/x5/apt-fail"; inst "$T/x5" --conf "$T/x5/my.conf" --run
check "apt-get fails: exit 1 at the package, no detection" bash -c '[ "$2" = 1 ] && grep -q "FAIL  apt-get install keepalived failed" "$1/out" && ! grep -q "^zradio-detect" "$1/calls"' _ "$T/x5" "$RC"

echo "-- a re-run on a VM that serves: detection is not repeated, and a changed port is said, not sprung on Home Assistant"
vm "$T/a"; inst "$T/a" --conf "$T/a/my.conf" --run; echo 1 > "$T/a/ser2net"; echo 1 > "$T/a/keepalived"; : > "$T/a/calls"
echo "ZWAVE_PORT=7001" >> "$T/a/my.conf"; inst "$T/a" --conf "$T/a/my.conf" --run
check "exit 0; no detection, ser2net not restarted or stopped" bash -c '[ "$2" = 0 ] && ! grep -q "^zradio-detect" "$1/calls" && ! grep -qE "^systemctl (restart|stop|disable --now) ser2net" "$1/calls"' _ "$T/a" "$RC"
check "the new port is in the file and a WARN says when it takes effect" bash -c 'grep -q "accepter: tcp,10.20.30.50,7001" "$1/root/etc/ser2net.yaml" && grep -q "WARN  /etc/ser2net.yaml changed and ser2net is active" "$1/out"' _ "$T/a"
check "--help names the steps" bash -c 'bash "$1" --help | grep -q "NOTHING IS STARTED"' _ "$TOOL"

echo "-- a VM whose address comes from DHCP: a conf without SELF, and without PEER (the pair's first VM)"
C() { printf '%s/root/etc/zradio/zradio.conf' "$1"; }
vm "$T/dh"; printf '%s\n' "# a pair on DHCP" NAME=attic1 VIP=192.168.1.50 VRID=50 PRIORITY=110 > "$T/dh/dhcp.conf"
inst "$T/dh" --conf "$T/dh/dhcp.conf" --initial-role primary --run
check "exit 0; this machine's own address is in the installed conf as SELF, the floating address got its prefix, and there is no PEER" bash -c '[ "$3" = 0 ] && grep -qx "SELF=192.168.1.44" "$1" && grep -qx "VIP=192.168.1.50/24" "$1" && ! grep -q "^PEER=" "$1" && ! grep -q "SELF" "$2/dhcp.conf"' _ "$(C "$T/dh")" "$T/dh" "$RC"
check "said: which address, on which interface, that it is to be RESERVED — and that this VM has no peer yet" bash -c 'grep -q "WARN  SELF: .*192.168.1.44/24 on eth0.*RESERVE it for this VM in your DHCP server" "$1/out" && grep -q "WARN  no PEER: this VM has no peer yet" "$1/out" && grep -q "attic1, 192.168.1.44 ↔ no peer yet, the floating address 192.168.1.50/24" "$1/out"' _ "$T/dh"
check "its keepalived.conf has no unicast lines: it holds the floating address alone" bash -c '! grep -q "unicast_" "$1/root/etc/keepalived/keepalived.conf" && grep -q "192.168.1.50/24 dev eth0" "$1/root/etc/keepalived/keepalived.conf"' _ "$T/dh"
inst "$T/dh" --conf "$T/dh/dhcp.conf" --run
check "the same line again: nothing is rewritten" bash -c '[ "$2" = 0 ] && grep -q "OK    /etc/zradio/zradio.conf is current" "$1/out" && grep -q "OK    /etc/keepalived/keepalived.conf is current" "$1/out"' _ "$T/dh" "$RC"
echo 1 > "$T/dh/keepalived"          # the VM is in the pair by now: keepalived runs
inst "$T/dh" --peer 192.168.1.45 --from-node --run
check "--peer (the second VM exists now): PEER is in the conf, keepalived.conf has the unicast lines, nothing is detected again" bash -c '[ "$3" = 0 ] && grep -qx "PEER=192.168.1.45" "$1" && grep -qx "SELF=192.168.1.44" "$1" && grep -A3 "unicast_src_ip 192.168.1.44" "$2/root/etc/keepalived/keepalived.conf" | grep -q "^ *192.168.1.45$" && [ "$(grep -c "^zradio-detect" "$2/calls")" = 1 ]' _ "$(C "$T/dh")" "$T/dh" "$RC"
check "…and the keepalived that runs is reloaded, with what that costs said" bash -c 'grep -q "^systemctl reload keepalived" "$1/calls" && grep -q "DONE  keepalived reloaded: this VM sends its adverts to its peer 192.168.1.45 now.*about 4 seconds" "$1/out" && ! grep -q "systemctl restart keepalived" "$1/out"' _ "$T/dh"
inst "$T/dh" --conf "$T/dh/dhcp.conf" --run
check "a later run with the first conf (it names no peer) does not take the peer away" bash -c '[ "$2" = 0 ] && grep -qx "PEER=192.168.1.45" "$1" && grep -q "OK    /etc/zradio/zradio.conf is current"  "$3/out"' _ "$(C "$T/dh")" "$RC" "$T/dh"
inst "$T/dh" --peer 192.168.1 --run
check "--peer with something that is no address: refused, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  --peer .192.168.1.: the other radio VM.s IPv4 address" "$3/out" && grep -qx "PEER=192.168.1.45" "$1"' _ "$(C "$T/dh")" "$RC" "$T/dh"
vm "$T/dh2"; printf '%s\n' NAME=attic1 VIP=10.20.30.50 VRID=50 PRIORITY=110 IFACE=eth1 > "$T/dh2/c"; inst "$T/dh2" --conf "$T/dh2/c" --initial-role primary --run
check "IFACE in the conf: the address on THAT interface is the VM's" bash -c '[ "$2" = 0 ] && grep -qx "SELF=10.20.30.6" "$1" && grep -qx "VIP=10.20.30.50/24" "$1"' _ "$(C "$T/dh2")" "$RC"
vm "$T/dh3"; fake "$T/dh3/bin" ip 'case "$*" in *route*) echo "default via 10.20.30.1 dev eth1 proto dhcp src 10.20.30.6 metric 100";; *) printf "2: eth0    inet 192.168.1.44/24 scope global eth0\n3: eth1    inet 10.20.30.6/24 scope global dynamic eth1\n";; esac'
printf '%s\n' NAME=attic1 VIP=10.20.30.50 VRID=50 PRIORITY=110 > "$T/dh3/c"; inst "$T/dh3" --conf "$T/dh3/c" --initial-role primary --run
check "no IFACE: the address on the default route's interface, not the first one listed" bash -c '[ "$2" = 0 ] && grep -qx "SELF=10.20.30.6" "$1"' _ "$(C "$T/dh3")" "$RC"
vm "$T/dh4"; printf '%s\n' NAME=attic1 VIP=10.9.9.50 VRID=50 PRIORITY=110 > "$T/dh4/c"; inst "$T/dh4" --conf "$T/dh4/c" --initial-role primary --run
check "a floating address outside the VM's own network: refused before anything is changed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the floating address 10.9.9.50 is not in this VM.s network (its own address is 192.168.1.44/24)" "$1/out" && [ ! -e "$1/root/etc/zradio/zradio.conf" ] && ! grep -q "^apt-get" "$1/calls"' _ "$T/dh4" "$RC"
vm "$T/dh5"; fake "$T/dh5/bin" ip ':'; printf '%s\n' NAME=attic1 VIP=192.168.1.50 VRID=50 PRIORITY=110 > "$T/dh5/c"; inst "$T/dh5" --conf "$T/dh5/c" --initial-role primary --run
check "no SELF in the conf and no address on the machine: refused, saying so" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .* names no SELF, and this machine has no IPv4 address to take" "$1/out" && [ ! -e "$1/root/etc/zradio/zradio.conf" ]' _ "$T/dh5" "$RC"
vm "$T/dh6"; grep -v '^PEER=' "$T/dh6/my.conf" > "$T/dh6/c"; inst "$T/dh6" --conf "$T/dh6/c" --initial-role primary --run
check "a fixed SELF and no PEER: installed as a VM without a peer; its address is its own business (no RESERVE line)" bash -c '[ "$2" = 0 ] && grep -q "WARN  no PEER" "$1/out" && ! grep -q "RESERVE" "$1/out" && ! grep -q "unicast_" "$1/root/etc/keepalived/keepalived.conf"' _ "$T/dh6" "$RC"

echo "-- the table of known sticks in the VM: the node's, or built here into the kit's gen/"
kitcopy() { rm -rf "$1/kit"; mkdir -p "$1/kit"; cp -R "$KIT/guest" "$KIT/zradio.conf.example" "$1/kit/"; }
vm "$T/t1"; kitcopy "$T/t1"; TOOL="$T/t1/kit/guest/install.sh" inst "$T/t1" --conf "$T/t1/my.conf" --run
check "on its own (no node): built here, into the kit's gen/, installed as /usr/local/lib/zradio/usb-ids.json" bash -c '[ "$2" = 0 ] && grep -q "OK    the table of the sticks the kit knows, built now into $1/kit/gen: 25 sticks" "$1/out" && cmp -s "$1/kit/gen/usb-ids.json" "$1/root/usr/local/lib/zradio/usb-ids.json" && [ "$(ls "$1/kit")" = "$(printf "gen\nguest\nzradio.conf.example")" ]' _ "$T/t1" "$RC"
vm "$T/t2"; kitcopy "$T/t2"; mkdir -p "$T/t2/kit/gen"; echo '{"format": "zradio usb ids v1", "entries": [], "home_assistant_core_commit": "from-the-node"}' > "$T/t2/kit/gen/usb-ids.json"
ZRADIO_USB_IDS_SOURCE="$T/t2/nowhere" TOOL="$T/t2/kit/guest/install.sh" inst "$T/t2" --conf "$T/t2/my.conf" --from-node --run
check "run by the node: the node's table is used as it is — nothing fetched, nothing rebuilt" bash -c 'grep -q "OK    the table of the sticks the kit knows came with the kit (the node built it)" "$1/out" && grep -q from-the-node "$1/root/usr/local/lib/zradio/usb-ids.json"' _ "$T/t2"
vm "$T/t3"; kitcopy "$T/t3"; ZRADIO_USB_IDS_SOURCE="$T/t3/nowhere" TOOL="$T/t3/kit/guest/install.sh" inst "$T/t3" --conf "$T/t3/my.conf" --run
check "on its own, and Home Assistant's lists cannot be read: refused before anything is changed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the table of the sticks the kit knows could not be built: Home Assistant.s USB list for zha" "$1/out" && grep -q "REFUSED" "$1/out" && [ ! -e "$1/root/usr" ] && [ ! -e "$1/kit/gen/usb-ids.json" ]' _ "$T/t3" "$RC"
gen() { ZRADIO_USB_IDS_SOURCE="$2" python3 "$KIT/guest/lib/zradio-usb-ids.py" --out "$1" > /dev/null 2>&1; }
mkdir -p "$T/u/src"; cp -R "$TESTS_DIR/fixtures/ha-core/." "$T/u/src/"; rm "$T/u/src/zwave_js/manifest.json"; echo old > "$T/u/ids.json"; gen "$T/u/ids.json" "$T/u/src"; RC=$?
check "the generator: one list missing → exit 1, and the file it was to write is left as it was (no half table)" bash -c '[ "$2" = 1 ] && [ "$(cat "$1/ids.json")" = old ] && [ ! -e "$1/ids.json.tmp" ]' _ "$T/u" "$RC"
gen "$T/u/a.json" "$TESTS_DIR/fixtures/ha-core"; gen "$T/u/b.json" "$TESTS_DIR/fixtures/ha-core"
check "…the same sources give the same table, byte for byte" cmp -s "$T/u/a.json" "$T/u/b.json"

echo "-- which kit this VM runs (the node's ./install.sh compares it at an update)"
check "a run installs the kit's version stamp: VERSION and CONTENT, the same as the kit's gen/kit-version" bash -c 'f="$1/root/usr/local/lib/zradio/kit-version"; grep -q "^VERSION=." "$f" && grep -qE "^CONTENT=[0-9a-f]{16}$" "$f" && cmp -s "$f" "$2/gen/kit-version"' _ "$T/w" "$KIT"
vm "$T/k1"; kitcopy "$T/k1"; mkdir -p "$T/k1/kit/gen"; cp "$KIT/gen/usb-ids.json" "$T/k1/kit/gen/"; printf 'VERSION=v9.9.9\nCONTENT=abcdefabcdefabcd\n' > "$T/k1/kit/gen/kit-version"
TOOL="$T/k1/kit/guest/install.sh" inst "$T/k1" --conf "$T/k1/my.conf" --from-node --run
check "run by the node: the node's stamp is the one installed (its VERSION names the download)" bash -c '[ "$2" = 0 ] && grep -q "^VERSION=v9.9.9$" "$1/root/usr/local/lib/zradio/kit-version"' _ "$T/k1" "$RC"
vm "$T/k2"; : > "$T/k2/apt-fail"; inst "$T/k2" --conf "$T/k2/my.conf" --run
check "a run that fails does not claim the new kit: no stamp installed" bash -c '[ "$2" != 0 ] && [ ! -e "$1/root/usr/local/lib/zradio/kit-version" ]' _ "$T/k2" "$RC"

echo "-- a VM that hangs or panics comes back by itself"
vm "$T/kp"; inst "$T/kp" --conf "$T/kp/my.conf" --run
check "kernel.panic: the VM reboots 10 s after a panic, and the setting is applied at once" bash -c 'grep -q "^kernel.panic = 10$" "$1/root/etc/sysctl.d/90-zradio.conf" && grep -q "kernel.panic = 10 is in effect" "$1/out"' _ "$T/kp"
check "no watchdog device here: no watchdog setting, and said" bash -c '[ ! -e "$1/root/etc/systemd/system.conf.d/90-zradio-watchdog.conf" ] && grep -q "no watchdog device" "$1/out"' _ "$T/kp"
vm "$T/wd"; : > "$T/wd/watchdog"; ZRADIO_INSTALL_WATCHDOG="$T/wd/watchdog" inst "$T/wd" --conf "$T/wd/my.conf" --run
check "a watchdog device: systemd feeds it (RuntimeWatchdogSec=30s), and systemd is re-executed to take it now" bash -c '[ "$2" = 0 ] && grep -q "^RuntimeWatchdogSec=30s$" "$1/root/etc/systemd/system.conf.d/90-zradio-watchdog.conf" && grep -q "^systemctl daemon-reexec" "$1/calls"' _ "$T/wd" "$RC"
: > "$T/wd/calls"; ZRADIO_INSTALL_WATCHDOG="$T/wd/watchdog" inst "$T/wd" --run
check "…run again: nothing changed, systemd not re-executed" bash -c '[ "$2" = 0 ] && ! grep -q "daemon-reexec" "$1/calls" && grep -q "/etc/systemd/system.conf.d/90-zradio-watchdog.conf is current" "$1/out"' _ "$T/wd" "$RC"
echo "-- zigpy: the release the conf pins is the one installed — on a VM that was installed before, too"
check "a new venv is stamped with the release it holds" eq "$(cat "$T/w/root/opt/zradio/zigpy/zradio-pin" 2>/dev/null)" "zigpy-cli==2.0.0"
check "the kit's set of libraries (guest/lib/zigpy-constraints.txt) is for the release the kit pins, and names zigpy and zigpy-znp" bash -c 'v=$(sed -n "s/^ *ZIGPY_VERSION=\([0-9][0-9a-z.]*\)$/\1/p" "$1/guest/lib/zradio-common.sh" | head -n 1) && [ -n "$v" ] && grep -qx "zigpy-cli==$v" "$1/guest/lib/zigpy-constraints.txt" && grep -q "^zigpy==[0-9]" "$1/guest/lib/zigpy-constraints.txt" && grep -q "^zigpy-znp==[0-9]" "$1/guest/lib/zigpy-constraints.txt"' _ "$KIT"
vm "$T/zv"; inst "$T/zv" --conf "$T/zv/my.conf" --run; echo "ZIGPY_VERSION=2.0.1" >> "$T/zv/my.conf"; : > "$T/zv/calls"; inst "$T/zv" --conf "$T/zv/my.conf" --run
check "ZIGPY_VERSION changed in the conf: the venv is built again with that release, and nothing of the old one stays" bash -c '[ "$2" = 0 ] && grep -q "^zigpy-setup .*/opt/zradio/zigpy 2.0.1$" "$1/calls" && [ "$(cat "$1/root/opt/zradio/zigpy/zradio-pin")" = "zigpy-cli==2.0.1" ] && grep -q "DONE  zigpy-cli 2.0.1 installed" "$1/out" && [ ! -e "$1/root/opt/zradio/zigpy.old" ]' _ "$T/zv" "$RC"
: > "$T/zv/calls"; inst "$T/zv" --run
check "…run again: nothing is built" bash -c '[ "$2" = 0 ] && ! grep -q "^zigpy-setup" "$1/calls" && grep -q "OK    zigpy-cli 2.0.1 is at /opt/zradio/zigpy" "$1/out"' _ "$T/zv" "$RC"
vm "$T/zf"; inst "$T/zf" --conf "$T/zf/my.conf" --run; echo "ZIGPY_VERSION=2.0.1" >> "$T/zf/my.conf"; : > "$T/zf/zigpy-fail"; inst "$T/zf" --conf "$T/zf/my.conf" --run
check "the new release does not install: FAIL, and the venv that was there is put back (this VM can still write a copy)" bash -c '[ "$2" != 0 ] && grep -q "FAIL  zigpy-cli 2.0.1 did not install" "$1/out" && [ -x "$1/root/opt/zradio/zigpy/bin/zigpy" ] && [ "$(cat "$1/root/opt/zradio/zigpy/zradio-pin")" = "zigpy-cli==2.0.0" ] && [ ! -e "$1/root/opt/zradio/zigpy.old" ]' _ "$T/zf" "$RC"
vm "$T/zo"; inst "$T/zo" --conf "$T/zo/my.conf" --run; rm "$T/zo/root/opt/zradio/zigpy/zradio-pin"; : > "$T/zo/calls"; inst "$T/zo" --run
check "a venv of an earlier kit (no stamp) and pip says it holds the pinned release: stamped, not built again" bash -c '[ "$2" = 0 ] && ! grep -q "^zigpy-setup" "$1/calls" && [ "$(cat "$1/root/opt/zradio/zigpy/zradio-pin")" = "zigpy-cli==2.0.0" ]' _ "$T/zo" "$RC"
printf 'zigpy==2.3.0\nzigpy-cli==2.0.0\nzigpy-znp==1.1.1\n' > "$T/zo/zigpy-freeze"; inst "$T/zo" --run
check "the libraries under it are not the ones the kit installs today: said, with both versions (the two VMs of a pair should hold the same)" bash -c '[ "$2" = 0 ] && grep -q "WARN  .*zigpy 2.3.0 here, [0-9.]* in the kit.s set" "$1/out" && ! grep -q "zigpy-znp 1.1.1 here" "$1/out"' _ "$T/zo" "$RC"
rm "$T/zo/root/opt/zradio/zigpy/zradio-pin"; echo 1.9.0 > "$T/zo/zigpy-has"; : > "$T/zo/calls"; inst "$T/zo" --run
check "no stamp and pip says ANOTHER release: built again" bash -c '[ "$2" = 0 ] && grep -q "^zigpy-setup .*/opt/zradio/zigpy 2.0.0$" "$1/calls"' _ "$T/zo" "$RC"

echo "-- the conf's time zone and keepalived's word are checked by the programs themselves"
vm "$T/tz"; echo "SYNC_TZ=Europe/Berln" >> "$T/tz/my.conf"; inst "$T/tz" --conf "$T/tz/my.conf" --run
check "a time zone systemd does not know (a typo): refused before anything is changed — the timer would never fire, without a word" bash -c '[ "$2" != 0 ] && grep -q "FAIL  .*Europe/Berln" "$1/out" && [ ! -e "$1/root/etc/zradio/zradio.conf" ] && [ ! -e "$1/root/etc/systemd/system/zradio-sync.timer" ]' _ "$T/tz" "$RC"
vm "$T/tz2"; echo "SYNC_TZ=Europe/Berlin" >> "$T/tz2/my.conf"; inst "$T/tz2" --conf "$T/tz2/my.conf" --run
check "one it knows: installed with it" bash -c '[ "$2" = 0 ] && grep -q "^OnCalendar=.* Europe/Berlin$" "$1/root/etc/systemd/system/zradio-sync.timer"' _ "$T/tz2" "$RC"
vm "$T/kw"; : > "$T/kw/kt-warn"; inst "$T/kw" --conf "$T/kw/my.conf" --run
check "keepalived -t names an unknown keyword and exits 0 all the same [V 2.3.3]: refused, the file is not put in place" bash -c '[ "$2" != 0 ] && grep -q "FAIL  keepalived -t refuses the new config" "$1/out" && [ ! -e "$1/root/etc/keepalived/keepalived.conf" ]' _ "$T/kw" "$RC"

echo "-- the units: a sync that was busy is no failure, and one with retries is not cut off"
for u in zradio-sync.service zradio-sync-tick.service; do
  check "$u: exit 75 (another sync is running) counts as success; 30 minutes for a run with its retries" bash -c 'grep -qx "SuccessExitStatus=75" "$1" && grep -qx "TimeoutStartSec=1800" "$1"' _ "$KIT/guest/units/$u"
done

echo "-- a re-run on a VM that is in the pair: what runs is put onto the new files"
check "report mode names the gate among what is enabled" bash -c 'grep -q "WOULD systemctl daemon-reload; enable .*zradio-gate" "$1/out"' _ "$T/r"
vm "$T/up"; inst "$T/up" --conf "$T/up/my.conf" --run
for u in zradio.target zradio-gate.service zradio-change-watch.service zradio-sync.timer zradio-sync-tick.timer; do echo 1 > "$T/up/$u"; done
echo "# an older kit's" >> "$T/up/root/usr/local/lib/zradio/zradio-common.sh"; : > "$T/up/calls"; inst "$T/up" --run
check "zradio-common.sh changed (every tool sources it): the gate, which runs all the time, is restarted on it" bash -c '[ "$2" = 0 ] && grep -qx "systemctl restart zradio-gate.service" "$1/calls"' _ "$T/up" "$RC"
check "a unit the target wants that is not running here (new in this kit): started; what runs already, and keepalived, are not touched" bash -c 'grep -qx "systemctl start zradio-state.timer" "$1/calls" && ! grep -qE "^systemctl start (zradio-sync.timer|zradio-sync-tick.timer|zradio-gate.service|zradio-change-watch.service|keepalived)" "$1/calls"' _ "$T/up"
echo "SYNC_AT=03:15" >> "$T/up/my.conf"; : > "$T/up/calls"; inst "$T/up" --conf "$T/up/my.conf" --run
check "SYNC_AT changed: the nightly timer, which is running, is restarted (systemd keeps the old time until then); the gate reads the new conf" bash -c '[ "$2" = 0 ] && grep -qx "systemctl restart zradio-sync.timer" "$1/calls" && grep -qx "systemctl restart zradio-gate.service" "$1/calls"' _ "$T/up" "$RC"
echo "# again" >> "$T/up/root/usr/local/lib/zradio/zradio-common.sh"; mkdir -p "$T/up/root/run/zradio"
( exec 9>"$T/up/root/run/zradio/sync-out.lock"; flock 9; sleep 3 ) & LP=$!
sleep 0.3; : > "$T/up/calls"; ZRADIO_INSTALL_RESTART_WAIT=1 inst "$T/up" --run; wait "$LP"
check "a sync runs here (restarting the gate or the watcher ends what they started — a self-raise, a device-change sync): not restarted, and said with the line to run later" bash -c '[ "$2" = 0 ] && ! grep -q "^systemctl restart zradio-gate" "$1/calls" && grep -q "WARN  .*a sync is running here.*systemctl restart zradio-gate.service" "$1/out"' _ "$T/up" "$RC"
vm "$T/nu"; inst "$T/nu" --conf "$T/nu/my.conf" --run
check "a VM that is not in the pair yet (zradio.target not started): nothing is started or restarted" bash -c '! grep -qE "^systemctl (start|restart)" "$1/calls"' _ "$T/nu"

echo "-- a stick whose network could not be told"
vm "$T/hn"; : > "$T/hn/detect-unknown"; inst "$T/hn" --conf "$T/hn/my.conf" --run --initial-role primary
check "the initial primary, and detection could not tell whether its sticks hold a network: said (it is neither 'holds' nor 'blank')" bash -c '[ "$2" = 0 ] && grep -q "WARN  .*could not be told whether the zigbee zwave stick(s) hold a network" "$1/out"' _ "$T/hn" "$RC"
echo "-- an update: the library before the tools that need it; a venv built again does not hold the restarts back"
vm "$T/lo"; inst "$T/lo" --conf "$T/lo/my.conf" --run
check "zradio-common.sh is put in place before the tools (a new tool beside the old library would not find the library's new functions, for the moment in between)" bash -c 'l=$(grep -n "/usr/local/lib/zradio/zradio-common.sh installed" "$1/out" | cut -d: -f1); s=$(grep -n "/usr/local/sbin/zradio-serve installed" "$1/out" | cut -d: -f1); [ -n "$l" ] && [ -n "$s" ] && [ "$l" -lt "$s" ]' _ "$T/lo"
vm "$T/zr"; inst "$T/zr" --conf "$T/zr/my.conf" --run
for u in zradio.target zradio-gate.service zradio-change-watch.service zradio-sync.timer zradio-sync-tick.timer zradio-state.timer; do echo 1 > "$T/zr/$u"; done
mkdir -p "$T/zr/root/run/zradio"; echo "ZIGPY_VERSION=2.0.1" >> "$T/zr/my.conf"; : > "$T/zr/calls"; ZRADIO_INSTALL_RESTART_WAIT=1 inst "$T/zr" --conf "$T/zr/my.conf" --run
check "the venv is built again on a VM that is in the pair, and no sync runs: the gate and the watcher are restarted all the same (the installer's own look at the sync's locks must not pass for a sync)" bash -c '[ "$2" = 0 ] && grep -q "^zigpy-setup .* 2.0.1$" "$1/calls" && grep -qx "systemctl restart zradio-gate.service" "$1/calls" && grep -qx "systemctl restart zradio-change-watch.service" "$1/calls" && ! grep -q "a sync is running here" "$1/out"' _ "$T/zr" "$RC"
echo "-- the Z-Wave JS UI image is started once, with the rights a write gives it, before any sync depends on it"
check "after the pull: the image's own Node.js is run with exactly those rights — no stick, no port — and its answer is shown" bash -c 'grep -q "^podman run --rm --pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges --entrypoint node docker.io/zwavejs/zwave-js-ui:[^ ]* --version$" "$1/calls" && grep -q "OK    the image starts with the rights a write gives it (Node.js v24.22.1)" "$1/out"' _ "$T/lo"
check "the rights are the ones zradio-apply runs the container with (one definition, in the library)" bash -c 'grep -q "^ZR_ZUI_RUN_OPTS=\"--pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges\"" "$1/guest/lib/zradio-common.sh" && grep -q "podman run -d --name \"\$CT\" \$ZR_ZUI_RUN_OPTS " "$1/guest/sbin/zradio-apply" && grep -q "podman run --rm \$ZR_ZUI_RUN_OPTS " "$1/guest/install.sh"' _ "$KIT"
vm "$T/sf"; : > "$T/sf/start-fail"; inst "$T/sf" --conf "$T/sf/my.conf" --run
check "the image does not start with them on this machine: FAIL with podman's words, before a unit is touched — an update stops at the standby" bash -c '[ "$2" != 0 ] && grep -q "FAIL  the image .* does not start with the rights a write gives it .*Operation not permitted" "$1/out" && [ ! -e "$1/root/etc/systemd/system/zradio.target" ]' _ "$T/sf" "$RC"
finish
