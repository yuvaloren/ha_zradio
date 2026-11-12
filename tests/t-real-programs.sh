#!/usr/bin/env bash
# t-real-programs.sh — the files the kit writes and ships, given to the REAL programs when they are installed here: ser2net loads
# the rendered /etc/ser2net.yaml and passes bytes both ways between a TCP port and a pty that stands in for a stick
# (socat); keepalived -t reads the rendered keepalived.conf; systemd-analyze reads the timer's calendar and every unit file. Skipped (said, 0 checks) where a program is missing.
# The only change made to the rendered ser2net file is the address (127.0.0.1 instead of the floating address) and
# the two device paths (the ptys). Not tested here: a real serial port's flow-control lines.
. "$(dirname "$0")/lib.sh"
RENDER="$KIT/guest/sbin/zradio-render"
PIDS=""; trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
printf '%s\n' NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 IFACE=eth9 ZWAVE_PORT=26639 ZIGBEE_PORT=26638 > "$T/zradio.conf"
r() { ZRADIO_CONF="$T/zradio.conf" ZRADIO_RADIOS="$T/radios.conf" bash "$RENDER" "$@"; }

if command -v ser2net >/dev/null && command -v socat >/dev/null; then
  echo "-- ser2net $(ser2net -v 2>&1 | head -1 | awk '{print $NF}') loads the rendered file and passes bytes"
  one() { # one <name> <radios.conf lines…>: render, start, talk through both ports
    local n=$1; shift; printf '%s\n' "$@" > "$T/radios.conf"; mkdir -p "$T/$n"
    socat -d -d pty,raw,echo=0,link="$T/$n/zwave" pty,raw,echo=0,link="$T/$n/zwave-far" 2>/dev/null & PIDS="$PIDS $!"
    socat -d -d pty,raw,echo=0,link="$T/$n/zigbee" pty,raw,echo=0,link="$T/$n/zigbee-far" 2>/dev/null & PIDS="$PIDS $!"
    for _ in $(seq 1 50); do [ -e "$T/$n/zwave-far" ] && [ -e "$T/$n/zigbee-far" ] && break; sleep 0.1; done
    r --ser2net | sed -e 's/tcp,10\.20\.30\.50,/tcp,127.0.0.1,/' -e "s#/dev/zradio-zwave#$T/$n/zwave#; s#/dev/zradio-zigbee#$T/$n/zigbee#" > "$T/$n/ser2net.yaml"
    ser2net -n -d -c "$T/$n/ser2net.yaml" > "$T/$n/log" 2>&1 & S2N=$!; PIDS="$PIDS $S2N"
    for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/26639) 2>/dev/null && break; sleep 0.1; done
  }
  talk() { # talk <port> <far pty> -> "<what the stick side got>|<what the TCP side got>"
    python3 - "$1" "$2" <<'PY'
import os, socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
far = os.open(sys.argv[2], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
def rd(f, n):
    buf = b""; end = time.time() + 5
    while len(buf) < n and time.time() < end:
        try: buf += f(n - len(buf))
        except (BlockingIOError, socket.timeout): time.sleep(0.05)
    return buf
time.sleep(0.3)
try: os.read(far, 100)                      # nothing may be waiting: no banner goes to the stick
except BlockingIOError: pass
s.sendall(b"\x01\x03\x00\x20\xdc"); got_far = rd(lambda n: os.read(far, n), 5)
os.write(far, b"\x06\xfe\x00\x61\x01\x60"); s.settimeout(0.2); got_tcp = rd(s.recv, 6)
print("%s|%s" % (got_far.hex(), got_tcp.hex()))
PY
  }
  one plain ZWAVE=synced ZIGBEE=synced ZIGBEE_FAMILY=znp
  check "the plain file (the reference sticks' settings): ser2net runs" kill -0 "$S2N"
  check "Z-Wave port: bytes arrive unchanged in both directions, no banner" eq "$(talk 26639 "$T/plain/zwave-far")" "01030020dc|06fe00610160"
  check "Zigbee port: the same" eq "$(talk 26638 "$T/plain/zigbee-far")" "01030020dc|06fe00610160"
  check "no error in ser2net's output" bash -c '! grep -qi "error\|invalid\|unknown" "$1"' _ "$T/plain/log"
  kill "$S2N" 2>/dev/null; wait "$S2N" 2>/dev/null
  one flow ZWAVE=served ZWAVE_FLOW=software ZWAVE_BAUD=57600 ZIGBEE=served ZIGBEE_FLOW=hardware ZIGBEE_BAUD=460800
  check "flow control written as rtscts / xonxoff and other baud rates: ser2net accepts the file" bash -c 'kill -0 "$1" && grep -q "460800n81,nobreak,local,rtscts" "$2/ser2net.yaml" && grep -q "57600n81,nobreak,local,xonxoff" "$2/ser2net.yaml" && ! grep -qi "invalid\|unknown" "$2/log"' _ "$S2N" "$T/flow"
  kill "$S2N" 2>/dev/null; wait "$S2N" 2>/dev/null
  one single ZWAVE=synced ZIGBEE=none
  check "one radio only: one connection in the file, ser2net runs" bash -c 'kill -0 "$1" && [ "$(grep -c "^connection:" "$2/ser2net.yaml")" = 1 ]' _ "$S2N" "$T/single"
else
  echo "SKIP  ser2net or socat is not installed here: the rendered ser2net.yaml was not given to ser2net"
fi

if command -v keepalived >/dev/null; then
  echo "-- $(keepalived --version 2>&1 | head -1 | cut -d' ' -f1,2) reads the rendered keepalived.conf"
  r > "$T/keepalived.conf"
  OUT=$(keepalived -t -f "$T/keepalived.conf" 2>&1); RC=$?
  # here the interface eth9 and /usr/local/sbin/zradio-serve do not exist: keepalived says so and that is expected.
  # What must not appear is a complaint about the file's own words.
  check "no unknown keyword, no syntax complaint" bash -c '! printf "%s" "$1" | grep -qiE "unknown keyword|syntax|unexpected|missing .*}|invalid"' _ "$OUT"
else
  echo "SKIP  keepalived is not installed here: the rendered keepalived.conf was not given to keepalived -t"
fi
if command -v systemd-analyze >/dev/null; then
  echo "-- systemd-analyze reads the timers' calendars"
  printf '%s\n' NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 SYNC_AT=03:15 SYNC_TZ=Europe/Berlin > "$T/zradio.conf"
  cal=$(r --timer | sed -n 's/^OnCalendar=//p')
  check "the rendered OnCalendar ($cal) is a calendar systemd accepts" bash -c 'systemd-analyze calendar "$1" >/dev/null 2>&1' _ "$cal"
  printf '%s\n' NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 > "$T/zradio.conf"
  cal=$(r --timer | sed -n 's/^OnCalendar=//p')
  check "the default ($cal, the VM's own time zone) too" bash -c '[ "$1" = "*-*-* 04:30:00" ] && systemd-analyze calendar "$1" >/dev/null 2>&1' _ "$cal"
  mkdir -p "$T/units"; cp "$KIT"/guest/units/* "$T/units/"; r --timer > "$T/units/zradio-sync.timer"
  OUT=$(for u in "$T"/units/*; do systemd-analyze verify "$u" 2>&1; done)
  # the programs the units name are not installed here ("is not executable", "not found"): expected. A word systemd
  # does not know in a unit file is not.
  check "systemd-analyze verify: no unknown key or section, nothing unparsable in the $(ls "$T/units" | wc -l | tr -d ' ') unit files" bash -c '! printf "%s" "$1" | grep -qiE "unknown (key|section)|failed to parse|invalid|bad unit"' _ "$OUT"
else
  echo "SKIP  systemd-analyze is not installed here"
fi
finish
