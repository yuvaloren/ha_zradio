#!/usr/bin/env bash
# t-install.sh — guest/install.sh against a fake radio VM: every path it writes under a temp root
# (ZRADIO_INSTALL_ROOT); systemctl, apt-get, dpkg-query, keepalived, podman, id and ip are fakes on PATH (recorded);
# zradio-detect is a fake that writes the radios.conf / radios.json a detection would (its own tests: t-detect.sh);
# the zigpy venv is made by a fake. zradio-render, zradio-sync (keys) and the common loader are the real ones.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/install.sh"
vm() { # vm <dir> [radios: both|zwave-only|served|blank] [ser2net active: 0|1]
  local d=$1 radios=${2:-both} s=${3:-0}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/root/etc/ssh"; : > "$d/calls"; : > "$d/pkgs"; echo "$s" > "$d/ser2net"; echo 0 > "$d/keepalived"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKeyFakeHostKey12 root@x" > "$d/root/etc/ssh/ssh_host_ed25519_key.pub"
  echo "# the package's file" > "$d/root/etc/ser2net.yaml"
  printf '%s\n' "# the pair" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 > "$d/my.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" ip 'printf "2: eth0    inet 192.168.1.44/24 scope global eth0\n3: eth1    inet 10.20.30.6/24 scope global eth1\n"'
  fake "$d/bin" systemctl "$rec; case \"\$1\" in is-active) u=\${*: -1}; [ \"\$(cat '$d/'\$u 2>/dev/null)\" = 1 ];; disable) case \" \$* \" in *' --now '*) echo 0 > '$d/'\${*: -1};; esac;; *) exit 0;; esac"
  fake "$d/bin" dpkg-query "grep -qx \"\${*: -1}\" '$d/pkgs' && { case \"\$*\" in *Status*) printf 'install ok installed';; *) printf '1.2.3-1';; esac; exit 0; }; exit 1"
  fake "$d/bin" apt-get "$rec; [ -f '$d/apt-fail' ] && exit 100; echo \"\${*: -1}\" >> '$d/pkgs'; case \"\${*: -1}\" in keepalived|ser2net) echo 1 > '$d/'\${*: -1};; esac; exit 0"
  fake "$d/bin" keepalived "$rec; [ -f '$d/kt-fail' ] && { echo 'Unknown keyword'; exit 1; }; exit 0"
  fake "$d/bin" podman "$rec; case \"\$1 \$2\" in 'image exists') [ -f '$d/have-image' ];; 'pull -q') : > '$d/have-image';; esac"
  cat > "$d/detect" <<SH
#!/usr/bin/env bash
echo "zradio-detect \$*" >> "$d/calls"
[ -f "$d/detect-fail" ] && { echo "FAIL  no Z-Wave or Zigbee stick found on this VM"; exit 1; }
mkdir -p "\$ZRADIO_DETECT_ETC"
case "$radios" in
  both|blank) printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
  zwave-only) printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=none\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
  served) printf 'ZWAVE=served\nZWAVE_FAMILY=zwave-500\nZIGBEE=served\nZIGBEE_FAMILY=ezsp\nZIGBEE_BAUD=115200\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
esac
net=true; [ "$radios" = blank ] && net=false
printf '{"radios": {"zwave": {"level": "%s", "holds_network": %s}, "zigbee": {"level": "%s", "holds_network": %s}}}\n' "\$(sed -n 's/^ZWAVE=//p' "\$ZRADIO_DETECT_ETC/radios.conf")" \$net "\$(sed -n 's/^ZIGBEE=//p' "\$ZRADIO_DETECT_ETC/radios.conf")" \$net > "\$ZRADIO_DETECT_ETC/radios.json"
echo "Z-Wave: found"; exit 0
SH
  chmod +x "$d/detect"
  printf '#!/usr/bin/env bash\necho "zigpy-setup $*" >> %q\nmkdir -p "$1/bin" && printf "#!/bin/sh\\n" > "$1/bin/zigpy" && chmod +x "$1/bin/zigpy"\n' "$d/calls" > "$d/zigpy-setup"; chmod +x "$d/zigpy-setup"
}
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
check "a synced Z-Wave stick: podman installed, the pinned image pulled" bash -c 'grep -q "^apt-get install -y -q podman" "$1/calls" && grep -q "^podman pull -q docker.io/zwavejs/zwave-js-ui:11.25.2" "$1/calls"' _ "$T/w"
check "a synced Zigbee stick: zigpy in its own venv" bash -c 'grep -q "^zigpy-setup .*/opt/zradio/zigpy" "$1/calls" && [ -x "$1/root/opt/zradio/zigpy/bin/zigpy" ]' _ "$T/w"
# the real line (no setup hook): python3 -m venv, then pip with the PINNED release from zradio.conf's default
vm "$T/pin"; REALPY=$(command -v python3)
fake "$T/pin/bin" python3 "if [ \"\$1 \$2\" = '-m venv' ]; then mkdir -p \"\$3/bin\" && printf '#!/bin/sh\necho \"pip \$*\" >> %s\nprintf \"#!/bin/sh\\\\n\" > %s/bin/zigpy; chmod +x %s/bin/zigpy\n' '$T/pin/calls' \"\$3\" \"\$3\" > \"\$3/bin/pip\" && chmod +x \"\$3/bin/pip\"; else exec '$REALPY' \"\$@\"; fi"
PATH="$T/pin/bin:$PATH" ZRADIO_INSTALL_ROOT="$T/pin/root" ZRADIO_INSTALL_DETECT="$T/pin/detect" bash "$TOOL" --conf "$T/pin/my.conf" --run > "$T/pin/out" 2>&1
check "zigpy-cli is installed at a pinned release (2.0.0 unless zradio.conf says otherwise), not whatever is newest that day" bash -c 'grep -qx "pip install -q zigpy-cli==2.0.0" "$1/calls" && grep -q "zigpy-cli 2.0.0 installed in its own venv" "$1/out"' _ "$T/pin"
vm "$T/pin2"; echo "ZIGPY_VERSION=latest" >> "$T/pin2/my.conf"; inst "$T/pin2" --conf "$T/pin2/my.conf" --run
check "ZIGPY_VERSION that is not a release number: the conf is refused, nothing installed" bash -c '[ "$2" != 0 ] && grep -q "ZIGPY_VERSION .latest.: a zigpy-cli release" "$1/out" && ! grep -q "^apt-get" "$1/calls"' _ "$T/pin2" "$RC"
check "keepalived.conf rendered for this VM (eth1 holds SELF) and checked with keepalived -t" bash -c 'grep -qx "    interface eth1" "$1/root/etc/keepalived/keepalived.conf" && grep -qx "    unicast_src_ip 10.20.30.6" "$1/root/etc/keepalived/keepalived.conf" && grep -q "^keepalived -t -f " "$1/calls"' _ "$T/w"
check "ser2net.yaml: both radios on the floating address; the package's file kept once as .dist" bash -c '[ "$(grep -c "accepter: tcp,10.20.30.50," "$1/root/etc/ser2net.yaml")" = 2 ] && grep -q "the package.s file" "$1/root/etc/ser2net.yaml.dist"' _ "$T/w"
check "the nightly timer at the default time" has "$(R "$T/w" /etc/systemd/system/zradio-sync.timer)" "OnCalendar=*-*-* 04:30:00"
check "the units and the keepalived drop-in (silent sticks first, Restart=always, a stop stops the serving)" bash -c 'for u in zradio.target zradio-gate.service zradio-serve.service zradio-quiet.service zradio-hush.service zradio-sync.service zradio-sync-tick.timer zradio-state.timer zradio-change-watch.service; do [ -f "$1/root/etc/systemd/system/$u" ] || exit 1; done; D="$1/root/etc/systemd/system/keepalived.service.d/10-zradio.conf"; grep -qx "After=zradio-quiet.service" "$D" && grep -qx "Restart=always" "$D" && grep -qx "ExecStopPost=/usr/local/sbin/zradio-notify INSTANCE RADIO STOP 0" "$D"' _ "$T/w"
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
vm "$T/x4"; : > "$T/x4/kt-fail"; inst "$T/x4" --conf "$T/x4/my.conf" --run
check "keepalived -t rejects the rendered file: exit 1, nothing enabled" bash -c '[ "$2" = 1 ] && grep -q "FAIL  keepalived -t" "$1/out" && ! grep -q "^systemctl enable" "$1/calls"' _ "$T/x4" "$RC"
vm "$T/x5"; : > "$T/x5/apt-fail"; inst "$T/x5" --conf "$T/x5/my.conf" --run
check "apt-get fails: exit 1 at the package, no detection" bash -c '[ "$2" = 1 ] && grep -q "FAIL  apt-get install keepalived failed" "$1/out" && ! grep -q "^zradio-detect" "$1/calls"' _ "$T/x5" "$RC"

echo "-- a re-run on a VM that serves: detection is not repeated, and a changed port is said, not sprung on Home Assistant"
vm "$T/a"; inst "$T/a" --conf "$T/a/my.conf" --run; echo 1 > "$T/a/ser2net"; echo 1 > "$T/a/keepalived"; : > "$T/a/calls"
echo "ZWAVE_PORT=7001" >> "$T/a/my.conf"; inst "$T/a" --conf "$T/a/my.conf" --run
check "exit 0; no detection, ser2net not restarted or stopped" bash -c '[ "$2" = 0 ] && ! grep -q "^zradio-detect" "$1/calls" && ! grep -qE "^systemctl (restart|stop|disable --now) ser2net" "$1/calls"' _ "$T/a" "$RC"
check "the new port is in the file and a WARN says when it takes effect" bash -c 'grep -q "accepter: tcp,10.20.30.50,7001" "$1/root/etc/ser2net.yaml" && grep -q "WARN  /etc/ser2net.yaml changed and ser2net is active" "$1/out"' _ "$T/a"
check "--help names the steps" bash -c 'bash "$1" --help | grep -q "NOTHING IS STARTED"' _ "$TOOL"
finish
