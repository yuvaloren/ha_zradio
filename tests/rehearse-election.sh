#!/usr/bin/env bash
# rehearse-election.sh — the election of docs/DESIGN.md §3a with the REAL keepalived and the kit's real tools, on one
# machine: two network namespaces on a veth pair stand in for the two radio VMs. Not part of tests/run.sh: it needs
# root, keepalived, iproute2 and ~4 minutes, and it starts processes.
#
# Real here: keepalived (VRRP, the health script, notify), zradio-serve / -notify / -gate / -sync / -switch / -apply,
# the rendered keepalived.conf, `ss` (is a client connected?), TCP between the namespaces.
# Stand-ins: the sticks (a probe stub; a zigpy stub whose "coordinator" is a file holding the frame counter), ser2net
# (a TCP listener on the floating address), systemd (a small dispatcher that runs what the units would), ssh between
# the VMs (the peer's forced command run in the peer's namespace), Home Assistant (a client that keeps reconnecting
# to the floating address); the link between the nodes (a bridge here; a cut link is a port taken out of it). ~4 minutes. The radios are Zigbee "synced" + Z-Wave "served": no Z-Wave image is written here.
# ELECTION=act (scenario 7: observe), ELECTION_WAIT=20 (the smallest allowed), the gate's own loop (zradio-gate run) with its idle pace at 6 s instead of 60, a returning standby asking for its sync after 6 s
# of the peer's serving instead of 60, the state line every 45 s.
#
#   sudo bash tests/rehearse-election.sh          # PASS/FAIL lines with times; exit 0 when all pass
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
R=${REHEARSE_DIR:-/root/zradio-rehearse}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
# this script removes and rebuilds $R/a and $R/b: the directory must be one of its own, never a system path
[[ "$R" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || { echo "REHEARSE_DIR '$R': an absolute path at least two levels deep, of this script's own"; exit 2; }
command -v keepalived >/dev/null && command -v ss >/dev/null || { echo "needs keepalived and ss"; exit 2; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
T0=$(date +%s.%N); t() { awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN { printf "%5.1f s", b - a }'; }
ns() { echo "zr$1"; }; addr() { [ "$1" = a ] && echo 10.20.30.5 || echo 10.20.30.6; }; other() { [ "$1" = a ] && echo b || echo a; }

cleanup() {
  for x in a b; do [ -d "$R/$x" ] && stop_vm $x; done 2>/dev/null
  ip netns del zra 2>/dev/null; ip netns del zrb 2>/dev/null; ip link del zrbr 2>/dev/null; ip link del zrpa 2>/dev/null; ip link del zrpb 2>/dev/null
  return 0
}
mkvm() { # mkvm <a|b> <priority>: the VM's directory, config, stand-ins
  local x=$1 prio=$2 d="$R/$1" o; o=$(other "$x")
  rm -rf "${R:?}/${x:?}"; mkdir -p "$d/bin" "$d/run" "$d/state" "$d/dev" "$d/etc" "$d/secrets"; : > "$d/journal"; : > "$d/dev/zw"; : > "$d/dev/zb"
  printf '%s\n' "NAME=radio$x" "SELF=$(addr "$x")" "PEER=$(addr "$o")" VIP=10.20.30.50/24 VRID=50 "PRIORITY=$prio" "IFACE=v$x" ELECTION=act ELECTION_WAIT=20 > "$d/etc/zradio.conf"
  printf '%s\n' ZWAVE=served ZWAVE_FAMILY=zwave-700 "ZWAVE_TTY=$d/dev/zw" ZIGBEE=synced ZIGBEE_FAMILY=znp "ZIGBEE_TTY=$d/dev/zb" > "$d/etc/radios.conf"
  echo "placeholder" > "$d/etc/sync.key"; echo "$(addr "$o") ssh-ed25519 AAAA" > "$d/etc/known"; echo 1000 > "$d/counter"
  cat > "$d/env" <<EOF
export PATH="$d/bin:\$PATH" ZRADIO_LIB="$KIT/guest/lib" ZRADIO_CONF="$d/etc/zradio.conf" ZRADIO_RADIOS="$d/etc/radios.conf"
export ZRADIO_SERVE_RUN="$d/run" ZRADIO_SERVE_STATE="$d/state" ZRADIO_SERVE_PROBE="$d/probe.py" ZRADIO_SERVE_PAUSE=0 ZRADIO_NOTIFY_RUN="$d/run" ZRADIO_NOTIFY_STATE="$d/state"
export ZRADIO_SYNC_RUN="$d/run" ZRADIO_SYNC_STATE="$d/state" ZRADIO_SYNC_SECRETS="$d/secrets" ZRADIO_SYNC_KEY="$d/etc/sync.key" ZRADIO_SYNC_KNOWN="$d/etc/known"
export ZRADIO_SYNC_PROBE="$d/probe.py" ZRADIO_SYNC_ZIGPY="$d/bin/zigpy" ZRADIO_SYNC_RESTORE="$KIT/guest/sbin/zradio-apply" ZRADIO_SYNC_SERVE="$KIT/guest/sbin/zradio-serve"
export ZRADIO_SYNC_SELFCMD="$KIT/guest/sbin/zradio-sync" ZRADIO_SYNC_SSH="$d/bin/ssh" ZRADIO_SYNC_SWITCH="$KIT/guest/sbin/zradio-switch" ZRADIO_SYNC_RETRY_PAUSES=""
export ZRADIO_SWITCH_SYNC="$KIT/guest/sbin/zradio-sync" ZRADIO_SWITCH_STATE="$d/state" ZRADIO_SWITCH_RUN="$d/run"
export ZRADIO_GATE_SYNC="$KIT/guest/sbin/zradio-sync" ZRADIO_GATE_RUN="$d/run" ZRADIO_GATE_STATE="$d/state" ZRADIO_GATE_SERVE="$KIT/guest/sbin/zradio-serve" ZRADIO_GATE_SERVING_FOR=6 ZRADIO_GATE_IDLE=6 ZRADIO_GATE_POKE_EVERY=20 ZRADIO_GATE_PREEMPT_EVERY=20
export ZRADIO_APPLY_STATE="$d/state" ZRADIO_APPLY_ZIGPY="$d/bin/zigpy"
EOF
  printf 'import json, sys\nprint("   NOTE  RF receive mode %%s" %% ("ON" if "on" in sys.argv else "OFF"), file=sys.stderr)\nprint(json.dumps({"zwave": {"ok": True}, "zigbee": {"ok": True, "device_state": 0, "device_state_name": "InitializedNotStarted"}}))\n' > "$d/probe.py"
  # zigpy: the "coordinator" is $d/counter (the frame counter on the stick); one network identity for both VMs
  cat > "$d/bin/zigpy" <<EOF
#!/usr/bin/env bash
case "\$4" in
  backup) printf '{"coordinator_ieee": "00124b00aabbccdd", "pan_id": "1a2b", "channel": 25, "network_key": {"key": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "frame_counter": %s}, "devices": []}\n' "\$(cat $d/counter)" > "\$5";;
  restore) python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["network_key"]["frame_counter"])' "\$5" > $d/counter;;
  info) printf 'PAN ID:                0x1A2B\nChannel:               25\nDevice IEEE:           00:12:4b:00:aa:bb:cc:dd\n';;
esac
EOF
  # ssh: the peer's forced command, run in the peer's namespace — unless the peer is "dead"
  cat > "$d/bin/ssh" <<EOF
#!/usr/bin/env bash
[ -e "$R/$o/dead" ] && exit 255
[ -e "$R/cut" ] && exit 255
cmd="\${*: -1}"
exec ip netns exec $(ns "$o") env -i bash -c '. "$R/$o/env"; SSH_ORIGINAL_COMMAND="\$1" exec bash "$KIT/guest/sbin/zradio-sync" serve-ssh' _ "\$cmd"
EOF
  printf '#!/usr/bin/env bash\necho "$(date +%%H:%%M:%%S.%%N | cut -c1-12) $*" >> %q\n' "$d/journal" > "$d/bin/logger"
  # systemd: what the units would run. The serve unit's start/stop are queued behind one another, as systemd's jobs are.
  cat > "$d/bin/systemctl" <<EOF
#!/usr/bin/env bash
S=$KIT/guest/sbin; d=$d
# systemd starts a unit with none of the caller's open files; a child of this stand-in would inherit the caller's
# locks (zradio-serve's lock on the sticks) and hold them for as long as the "daemon" lives
for f in /proc/\$\$/fd/*; do n=\${f##*/}; case \$n in 0|1|2|255) ;; *) eval "exec \$n>&-";; esac; done 2>/dev/null
alive() { [ -f "\$d/\$1.pid" ] && kill -0 "\$(cat "\$d/\$1.pid")" 2>/dev/null; }
u="\${*: -1}"
case "\$1" in
  is-active) case "\$u" in ser2net) alive ser2net;; keepalived) alive keepalived;; *) exit 3;; esac;;
  start|stop)
    case "\$1 \$u" in
      "start ser2net") alive ser2net || { python3 $R/listener.py & echo \$! > "\$d/ser2net.pid"; sleep 0.3; };;
      "stop ser2net") alive ser2net && kill "\$(cat "\$d/ser2net.pid")"; rm -f "\$d/ser2net.pid"; sleep 0.1;;
      "start zradio-serve.service") ( flock 9; bash \$S/zradio-serve up ) 9>"\$d/unit.lock" >/dev/null 2>&1 &;;
      "stop zradio-serve.service") ( flock 9; bash \$S/zradio-serve down ) 9>"\$d/unit.lock" >/dev/null 2>&1 &;;
      "start zradio-hush.service") ( bash \$S/zradio-serve hush ) >/dev/null 2>&1 &;;
      "start zradio-sync-tick.service") ( bash \$S/zradio-sync tick ) >> "\$d/tick.log" 2>&1 &;;
      "stop keepalived") alive keepalived && { kill "\$(cat "\$d/keepalived.pid")"; for _ in \$(seq 1 30); do alive keepalived || break; sleep 0.1; done; }; bash \$S/zradio-notify INSTANCE RADIO STOP 0;;
      "start keepalived") alive keepalived || { keepalived -P -n -l -f "\$d/keepalived.conf" -p "\$d/keepalived.pid" -r "\$d/vrrp.pid" >> "\$d/keepalived.log" 2>&1 & sleep 0.2; };;
    esac;;
esac
EOF
  chmod +x "$d/bin/"*
  for w in check notify; do
    printf '#!/usr/bin/env bash\n. %q\nexec bash %q %s "$@"\n' "$d/env" "$KIT/guest/sbin/zradio-$([ $w = check ] && echo serve || echo notify)" "$([ $w = check ] && echo check)" > "$d/$w"; chmod 755 "$d/$w"
  done
  ( . "$d/env"; bash "$KIT/guest/sbin/zradio-render" ) | sed -e "s|/usr/local/sbin/zradio-serve check|$d/check|" -e "s|/usr/local/sbin/zradio-notify|$d/notify|" > "$d/keepalived.conf"
}
vx() { local x=$1; shift; ip netns exec "$(ns "$x")" env -i bash -c '. "$1/env"; shift; "$@"' _ "$R/$x" "$@"; }      # a command "inside" a VM
boot_vm() { # boot: the gate's boot-wait, the sticks silenced, keepalived, the gate, the state beat
  local x=$1 d="$R/$1"
  rm -f "${R:?}/${x:?}/dead"; rm -rf "${R:?}/${x:?}/run"; mkdir -p "$d/run"
  vx "$x" bash "$KIT/guest/sbin/zradio-gate" arm >/dev/null
  vx "$x" bash "$KIT/guest/sbin/zradio-serve" down >/dev/null
  vx "$x" systemctl start keepalived
  vx "$x" bash "$KIT/guest/sbin/zradio-gate" run >> "$d/gate.log" 2>&1 & disown        # the service's own loop
  # the state line's own timer is a minute in a real VM; here 45 s — so a version that advances within seconds was
  # advanced by the gate (it runs the beat itself while a confirmed turn is not used yet), not by this loop
  vx "$x" bash -c "while :; do sleep 45; bash $KIT/guest/sbin/zradio-sync beat >/dev/null 2>&1; done" 2>/dev/null & disown
}
stop_vm() { # a hard death: every process of the VM is killed at once, nothing is told to anyone
  local x=$1 d="$R/$1" pids
  : > "$d/dead"
  for _ in 1 2 3; do pids=$(ip netns pids "$(ns "$x")" 2>/dev/null); [ -n "$pids" ] || break; kill -9 $pids 2>/dev/null; sleep 0.2; done
  rm -f "${R:?}/${x:?}"/*.pid
  ip -n "$(ns "$x")" addr del 10.20.30.50/24 dev "v$x" 2>/dev/null
}
serves() { local d="$R/$1"; [ -f "$d/ser2net.pid" ] && kill -0 "$(cat "$d/ser2net.pid")" 2>/dev/null && ip -n "$(ns "$1")" -4 addr show dev "v$1" | grep -q "10.20.30.50"; }
waitfor() { # waitfor <seconds> <command…>
  local n=$1; shift; for _ in $(seq 1 $((n * 5))); do "$@" && return 0; sleep 0.2; done; return 1; }
ver() { cat "$R/$1/state/version" 2>/dev/null || echo "term=0 used=no"; }
setver() { echo "term=$2 used=$3" > "$R/$1/state/version"; }
jhas() { grep -q "$2" "$R/$1/journal"; }
term() { ver "$1" | sed -n 's/^term=\([0-9]*\) .*/\1/p'; }
el() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN { printf "%.0f", b - a }'; }      # whole seconds since <epoch>
cut_link() { : > "$R/cut"; ip link set zrpb nomaster; }                  # ($R/cut: the stand-in for ssh does not use the network)
heal_link() { unlink "$R/cut"; ip link set zrpb master zrbr; }
veris() { [ "$(ver "$1")" = "$2" ]; }; turnis() { [ "$(cat "$R/$1/run/turn" 2>/dev/null)" = "$2" ]; }
held() { [ -e "$R/$1/state/outdated" ] && [ -e "$R/$1/run/hold" ]; }; unheld() { [ ! -e "$R/$1/run/hold" ]; }
ha() { # Home Assistant: a client in VM <x>'s namespace (it lives on that node) that keeps a connection to the floating address
  pkill -f "$R/ha-client.py" 2>/dev/null; sleep 0.2; ip netns exec "$(ns "$1")" python3 "$R/ha-client.py" 2>/dev/null & disown; }

trap cleanup EXIT
mkdir -p "$R"; chmod 755 "$R"
cat > "$R/listener.py" <<'EOF'
import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.setsockopt(socket.SOL_IP, 15, 1)   # IP_FREEBIND: the address may arrive later
s.bind(("10.20.30.50", 6638)); s.listen(4)
def hold(c):
    try:
        while c.recv(100): pass
    except OSError: pass
while True:
    c, _ = s.accept(); threading.Thread(target=hold, args=(c,), daemon=True).start()
EOF
cat > "$R/ha-client.py" <<'EOF'
import socket, time
while True:
    try:
        c = socket.create_connection(("10.20.30.50", 6638), timeout=1); c.settimeout(None)
        c.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        for o, v in ((socket.TCP_KEEPIDLE, 1), (socket.TCP_KEEPINTVL, 1), (socket.TCP_KEEPCNT, 2)): c.setsockopt(socket.IPPROTO_TCP, o, v)
        while c.recv(100): pass
    except OSError: pass
    time.sleep(0.5)
EOF
cleanup
ip netns add zra; ip netns add zrb
# each VM's interface is one end of a veth pair; the other ends are ports of a bridge here: the "switch" between the
# two nodes. A cut link is a port taken out of the bridge — both VMs keep their carrier, as with a failed switch.
ip link add zrbr type bridge stp_state 0 forward_delay 0 && ip link set zrbr up
for x in a b; do ip link add "v$x" netns "$(ns $x)" type veth peer name "zrp$x"; ip link set "zrp$x" master zrbr; ip link set "zrp$x" up; done
for x in a b; do ip -n "$(ns $x)" addr add "$(addr $x)/24" dev "v$x"; ip -n "$(ns $x)" link set "v$x" up; ip -n "$(ns $x)" link set lo up; done
mkvm a 100; mkvm b 110           # b has the HIGHER priority: where a must win, it wins on its version, not on priority

echo "== 1. both boot; a holds the networks in use (term 3, used), b a synced copy; a boots 4 s LATER than b   [$(t)]"
setver a 3 yes; setver b 3 no
boot_vm b; sleep 4; boot_vm a
waitfor 30 serves a && ok "a serves ($(t)) — the later boot with the lower priority, because its copy is the newer one" || no "a does not serve after 30 s"
serves b && no "b serves too" || ok "b stands by"
waitfor 15 jhas b "result=standby" && jhas a "result=claim" && ok "the journals: a 'claim', b 'standby'" || no "journals: a=$(grep -o 'result=[a-z-]*' "$R/a/journal" | sort -u | tr '\n' ' ') b=$(grep -o 'result=[a-z-]*' "$R/b/journal" | sort -u | tr '\n' ' ')"
waitfor 5 turnis a confirmed && ok "a's turn is confirmed" || no "a's turn is '$(cat "$R/a/run/turn" 2>/dev/null)'"

if [ "${REHEARSE_UPTO:-9}" -ge 2 ]; then
echo "== 2. Home Assistant connects; a dies hard; b takes over and its version advances; a returns: outdated, held   [$(t)]"
ha a; sleep 3
[ "$(ver a)" = "term=3 used=yes" ] && ok "a's version is unchanged by a client (it was already the copy in use): $(ver a)" || no "a's version: $(ver a)"
ha b                                                  # Home Assistant lives on b's node from here on (a's node is about to die)
T1=$(date +%s.%N); stop_vm a
waitfor 15 serves b && ok "b serves $(el "$T1") s after a's death (a clean standby: no wait)" || no "b did not take over"
waitfor 10 veris b "term=4 used=yes" && ok "Home Assistant connected to b; a did not answer: b's version advanced to $(ver b)" || no "b's version: $(ver b) (turn $(cat "$R/b/run/turn" 2>/dev/null); ss: $(vx b ss -Htn state established '( sport = :6638 )' | head -1))"
boot_vm a
waitfor 10 held a && ok "a is back: outdated ($(cat "$R/a/state/outdated")) and held" || no "a is not held: outdated=$(cat "$R/a/state/outdated" 2>/dev/null) hold=$([ -e "$R/a/run/hold" ] && echo yes || echo no)"
serves a && no "a serves" || ok "a does not serve"

if [ "${REHEARSE_UPTO:-9}" -ge 3 ]; then
echo "== 3. a blip of the serving VM (its keepalived gone for 6 s) while a is outdated: the older copy must NOT take the radios   [$(t)]"
vx b bash -c 'kill $(cat '"$R"'/b/keepalived.pid)'; sleep 6
serves a && no "a took the radios during the blip" || ok "a stayed out during the blip (held)"
vx b bash "$KIT/guest/sbin/zradio-notify" INSTANCE RADIO STOP 0; vx b systemctl start keepalived
waitfor 20 serves b && ok "b serves again after its keepalived returned ($(t))" || no "b does not serve again"
waitfor 15 veris b "term=5 used=yes" && ok "b had released its claim when its keepalived stopped, and took it again with Home Assistant back: $(ver b)" || no "b's version after the blip: $(ver b)"
waitfor 40 veris a "term=5 used=no" && ok "a asked for its sync and got it: version $(ver a), outdated cleared: $([ -e "$R/a/state/outdated" ] && echo no || echo yes), Zigbee counter on a's stick $(cat "$R/a/counter") (b's reading 1000 + 1000000)" || no "a was not synced: $(ver a); a journal tail: $(tail -3 "$R/a/journal" | cut -c1-200)"
waitfor 10 unheld a && ok "the hold is lifted: a is an ordinary standby again" || no "a is still held"

if [ "${REHEARSE_UPTO:-9}" -ge 4 ]; then
echo "== 4. a is outdated again (b moved on), b dies: a waits the standard wait, raises its counter, serves provisionally; b returns and takes the radios back   [$(t)]"
setver b 6 yes; echo 1300000 > "$R/b/counter"; echo 1300000 > "$R/b/state/counter-floor"     # b has moved on: a newer term, a higher counter
waitfor 15 held a && ok "a sees b a term ahead: outdated and held again" || no "a is not held"
C0=$(cat "$R/a/counter"); T1=$(date +%s.%N); stop_vm b; ha a
sleep 12; serves a && no "a served after 12 s (before the standard wait)" || ok "12 s after b's death a still waits (the standard wait is 20 s here)"
waitfor 45 serves a && ok "a serves $(el "$T1") s after b's death" || no "a never served"
waitfor 5 turnis a provisional && ok "the turn is provisional" || no "the turn is '$(cat "$R/a/run/turn" 2>/dev/null)'"
[ "$(cat "$R/a/counter")" -gt 1300000 ] && ok "a raised its Zigbee counter before serving: $C0 → $(cat "$R/a/counter") (above b's last known 1300000)" || no "a's counter is $(cat "$R/a/counter")"
sleep 5; [ "$(ver a)" = "term=5 used=no" ] && ok "Home Assistant uses a, and a's version does NOT advance in a provisional turn: $(ver a)" || no "a's version moved: $(ver a)"
CA=$(cat "$R/a/counter"); T1=$(date +%s.%N); ha b; boot_vm b
waitfor 40 serves b && ok "b is back and serves again $(el "$T1") s after its boot (it preempted the older copy)" || no "b did not take the radios back; b journal: $(grep -o 'result=[a-z-]* [^—]*' "$R/b/journal" | tail -4 | tr '\n' '|' | cut -c1-400)"
waitfor 10 sh -c "! [ -f $R/a/ser2net.pid ]" && ok "a stopped serving" || no "a still serves"
[ "$(cat "$R/b/counter")" -gt "$CA" ] && ok "b raised its counter above a's before taking over: $(cat "$R/b/counter") > $CA" || no "b's counter $(cat "$R/b/counter") is not above a's $CA"
waitfor 10 jhas b "result=preempted" && jhas a "result=yield" && ok "the journals: b 'preempted', a 'yield'" || no "journals lack preempted/yield"
[ "$(ver b)" = "term=7 used=yes" ] && held a && ok "the turn b took back is a new term ($(ver b)); a is outdated against it and held until b's sync" || no "after the preemption: b $(ver b), a held=$(held a && echo y || echo n) ($(cat "$R/a/state/outdated" 2>/dev/null))"
waitfor 40 veris a "term=7 used=no" && ok "b synced a afterwards: a holds $(ver a), counter $(cat "$R/a/counter"); one preemption, then quiet" || no "a was not synced after the preemption: $(ver a)"
sleep 8; serves b && ! serves a && [ "$(grep -c 'result=preempt ' "$R/b/journal")" = 1 ] && ok "8 s later: b still serves, a stands by, exactly one preemption in b's journal (no flapping)" || no "not stable: b serves=$(serves b && echo y || echo n) a serves=$(serves a && echo y || echo n) preempts=$(grep -c 'result=preempt ' "$R/b/journal")"

if [ "${REHEARSE_UPTO:-9}" -ge 5 ]; then
echo "== 5. a planned switch (zradio-switch --run on b) stands: the VM that gave the radios away does not take them back   [$(t)]"
T1=$(date +%s.%N); vx b bash "$KIT/guest/sbin/zradio-switch" --run > "$R/switch.out" 2>&1; RC=$?
[ $RC = 0 ] && ok "zradio-switch --run on b: exit 0 after $(el "$T1") s ($(grep -c '^DONE' "$R/switch.out") DONE lines)" || no "zradio-switch: exit $RC: $(grep -E '^(FAIL|REFUSED)' "$R/switch.out" | head -2 | tr '\n' '|' | cut -c1-300)"
waitfor 10 serves a && ! serves b && ok "a serves, b stands by" || no "after the switch: a serves=$(serves a && echo y || echo n) b serves=$(serves b && echo y || echo n)"
jhas b "event=version result=released term=7 used=no" && ok "b released its claim when its keepalived stopped — before a took over (b: $(ver b))" || no "b did not release: $(ver b)"
waitfor 15 veris a "term=8 used=yes" && ok "Home Assistant reconnected to a; b answered and was not ahead: a's version advanced to $(ver a)" || no "a's version: $(ver a), turn $(cat "$R/a/run/turn" 2>/dev/null)"
waitfor 40 veris b "term=8 used=no" && ok "a synced b in its turn: b holds $(ver b)" || no "b was not synced by a: $(ver b)"
sleep 6; serves a && ! serves b && [ "$(grep -c 'result=preempt ' "$R/b/journal")" = 1 ] && ! jhas a "result=preempt " && ok "6 s later a still serves: nobody preempted (the switch stands)" || no "the switch did not stand: a serves=$(serves a && echo y || echo n), preempt lines a=$(grep -c 'result=preempt ' "$R/a/journal") b=$(grep -c 'result=preempt ' "$R/b/journal")"

if [ "${REHEARSE_UPTO:-9}" -ge 6 ]; then
echo "== 6. a cut link: both serve; Home Assistant keeps using a; at the heal keepalived gives the address to b (the higher priority) — and the version brings the radios back to a   [$(t)]"
ha a; sleep 3                                         # Home Assistant lives on a's node: during the cut it reaches a only
CB0=$(cat "$R/b/counter"); ADV0=$(grep -c 'event=version result=advanced' "$R/b/journal"); BK0=$(grep -c 'event=role state=BACKUP' "$R/a/journal"); T1=$(date +%s.%N); cut_link
waitfor 15 serves b && ok "the link is cut: b serves too, $(el "$T1") s later (two actives, as before this feature: two VMs cannot tell a cut link from a dead peer)" || no "b did not claim during the cut"
sleep 6; serves a && [ "$(ver b)" = "term=8 used=no" ] && ok "a still serves Home Assistant; b serves nobody and its version did not advance ($(ver b))" || no "during the cut: a serves=$(serves a && echo y || echo n), b $(ver b)"
T1=$(date +%s.%N); heal_link
waitfor 15 sh -c "[ \$(grep -c 'event=role state=BACKUP' $R/a/journal) -gt $BK0 ]" && ok "the link is back: keepalived leaves the address with b (priority 110 over 100) — a is displaced $(el "$T1") s after the heal" || no "a was not displaced after the heal"
waitfor 45 sh -c "grep -q 'result=preempted' $R/a/journal" && serves a && ok "a serves again $(el "$T1") s after the heal: the copy Home Assistant was using won, not the priority (a's journal: preempt, preempted)" || no "a did not get the radios back; a: $(grep -o 'result=[a-z-]* [^—]*' "$R/a/journal" | grep -v 'state\|down\|up ' | tail -3 | tr '\n' '|' | cut -c1-400)"
waitfor 10 sh -c "! [ -f $R/b/ser2net.pid ]" && jhas b "result=yield" && ok "b handed over when asked and stopped serving$(jhas b 'result=behind' && echo " (it had noticed by itself that a was ahead: 'behind')")" || no "b still serves, or no 'yield' in its journal"
[ "$(ver a)" = "term=9 used=yes" ] && held b && ok "a's turn is a new term ($(ver a)); b is outdated against it and held" || no "after the heal: a $(ver a), b held=$(held b && echo y || echo n) ($(cat "$R/b/state/outdated" 2>/dev/null))"
[ "$(cat "$R/a/counter")" -gt "$CB0" ] && ok "a raised its Zigbee counter above b's before taking the radios back ($(cat "$R/a/counter") > $CB0)" || no "a's counter $(cat "$R/a/counter") is not above b's $CB0"
[ "$(grep -c 'event=version result=advanced' "$R/b/journal")" = "$ADV0" ] && ok "b's version never advanced on its own, cut or healed: what it held was never taken for the newer copy" || no "b advanced its version: $(ver b)"
waitfor 40 veris b "term=9 used=no" && waitfor 5 unheld b && ok "a synced b afterwards: b holds $(ver b) and is an ordinary standby" || no "b after the heal: $(ver b), held=$([ -e "$R/b/run/hold" ] && echo y || echo n)"
sleep 8; serves a && ! serves b && [ "$(grep -c 'result=preempt ' "$R/a/journal")" = 1 ] && [ "$(grep -c 'result=preempt ' "$R/b/journal")" = 1 ] && ok "8 s later: a serves, b stands by, one preemption each in the whole run (no flapping)" || no "not stable after the heal: a serves=$(serves a && echo y || echo n) b serves=$(serves b && echo y || echo n) preempts a=$(grep -c 'result=preempt ' "$R/a/journal") b=$(grep -c 'result=preempt ' "$R/b/journal")"

if [ "${REHEARSE_UPTO:-9}" -ge 7 ]; then
echo "== 7. ELECTION=observe (the default): the situation of 4 again — the pair behaves as it did before this feature, and says where act mode would differ   [$(t)]"
stop_vm a; stop_vm b
for x in a b; do sed -i 's/^ELECTION=act$/ELECTION=observe/' "$R/$x/etc/zradio.conf"; cp "$R/$x/journal" "$R/$x/journal.act"; : > "$R/$x/journal"; done
unlink "$R/a/state/outdated" 2>/dev/null; unlink "$R/b/state/outdated" 2>/dev/null
setver a 4 no; setver b 5 yes; CA=$(cat "$R/a/counter")
T1=$(date +%s.%N); boot_vm a
waitfor 20 serves a && ok "a (the older copy) boots alone and serves $(el "$T1") s after its boot: observe mode holds nobody back" || no "a does not serve in observe mode"
waitfor 10 jhas a "result=would-provisional" && jhas a "result=would-wait" && ok "a's journal: would-wait, then would-provisional (it serves where act mode would still be asking the peer)" || no "a's journal: $(grep -o 'result=would-[a-z]*' "$R/a/journal" | sort -u | tr '\n' ' ')"
turnis a confirmed && ok "the turn itself is 'confirmed', as before this feature" || no "a's turn: $(cat "$R/a/run/turn" 2>/dev/null)"
boot_vm b
waitfor 15 jhas b "result=would-preempt" && ok "b (the newer copy) returns and says would-preempt: in act mode the radios would come back to it" || no "no would-preempt in b's journal: $(grep -o 'result=[a-z-]*' "$R/b/journal" | sort -u | tr '\n' ' ')"
vx a bash "$KIT/guest/sbin/zradio-sync" tick >> "$R/a/tick.log" 2>&1      # a's 15-minute timer fires
waitfor 10 veris b "term=4 used=no" && ok "…and, as before this feature, a's next timer sync writes the OLDER copy over b's newer one (b: term=5 used=yes → $(ver b))" || no "b was not synced by a: $(ver b)"
jhas b "result=would-refuse" && ok "b's journal says so: would-refuse (act mode refuses a set of a lower term)" || no "no would-refuse in b's journal"
sleep 6
serves a && ! serves b && ok "a still serves and b stands by: nothing was taken in observe mode" || no "observe mode changed who serves: a=$(serves a && echo y || echo n) b=$(serves b && echo y || echo n)"
[ "$(cat "$R/a/counter")" = "$CA" ] && ok "a's Zigbee counter was not raised ($CA); b's is the ordinary sync's ($(cat "$R/b/counter") = a's + 1000000)" || no "a's counter moved: $CA → $(cat "$R/a/counter")"
[ ! -e "$R/a/run/hold" ] && [ ! -e "$R/b/run/hold" ] && [ ! -e "$R/b/run/boot-wait" ] && ! grep -q "result=preempt \|result=yield \|result=raised " "$R/a/journal" "$R/b/journal" && ok "no hold, no boot-wait where zradio-serve looks; no preempt, yield or raise in either journal" || no "an act-mode action happened in observe mode"

fi; fi; fi; fi; fi; fi
echo "# rehearse-election: $PASS PASS, $FAIL FAIL   [$(t)]"
[ "$FAIL" -eq 0 ]
