#!/usr/bin/env bash
# t-sync.sh — guest/sbin/zradio-sync against two fake radio VMs in temp dirs (A: the active, B: the standby):
# ssh is a fake that runs the PEER's `zradio-sync serve-ssh` with the peer's own env (SSH_ORIGINAL_COMMAND = the last
# argument, as sshd's forced command gets it); systemctl (ser2net's state in a file), logger (the journal), id, sleep;
# zradio-probe.py as a python stub with the JSON keys the real probe printed on the reference sticks (ok, home_id_hex,
# node_count, rf.region, rf.tx_power_dbm, nvm_dump.bytes/size) and its "RF receive mode ON/OFF" line; zigpy as a fake
# that writes an open-coordinator backup with the keys zigpy-cli 2.0.0 writes (coordinator_ieee, pan_id, channel,
# network_key.key/frame_counter, devices); zradio-apply and zradio-serve as recording stubs (their own tests:
# t-apply.sh, t-serve.sh). tar, flock, timeout, ssh-keygen are real.
# The network key in the fakes is a made-up constant: no output and no journal line may ever hold it.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-sync"
NETKEY=a1b2c3d4e5f60718293a4b5c6d7e8f90

vm() { # vm <dir> <name> <self> <peer addr> <peer dir> <role: MASTER|BACKUP|none> <ser2net: 0|1>
  local d=$1 name=$2 self=$3 peer=$4 pd=$5 role=$6 s=$7
  rm -rf "$d"; mkdir -p "$d/bin" "$d/etc/ssh" "$d/state" "$d/run" "$d/dev" "$d/root.ssh"; : > "$d/calls"; : > "$d/journal"
  echo "$s" > "$d/ser2net"; [ "$role" = none ] || echo "$role 2026-11-12T00:00:00Z priority=100" > "$d/run/role"
  : > "$d/dev/zwave"; : > "$d/dev/zigbee"
  printf 'NAME=%s\nSELF=%s\nPEER=%s\nVIP=10.20.30.50/24\nVRID=50\nPRIORITY=100\nIFACE=\n' "$name" "$self" "$peer" > "$d/etc/zradio.conf"
  printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "$d/etc/radios.conf"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKeyFakeHostKey12 root@$name" > "$d/etc/ssh/host.pub"
  echo "placeholder" > "$d/etc/sync.key"; echo "$peer ssh-ed25519 AAAA" > "$d/etc/known"
  cat > "$d/env.sh" <<EOF
export PATH="$d/bin:\$PATH" ZRADIO_CONF="$d/etc/zradio.conf" ZRADIO_RADIOS="$d/etc/radios.conf" ZRADIO_SYNC_KEY="$d/etc/sync.key" ZRADIO_SYNC_KNOWN="$d/etc/known"
export ZRADIO_SYNC_AUTH="$d/root.ssh/authorized_keys" ZRADIO_SYNC_HOSTKEY="$d/etc/ssh/host.pub" ZRADIO_SYNC_SECRETS="$d/secrets/sync"
export ZRADIO_SYNC_STATE="$d/state" ZRADIO_SYNC_RUN="$d/run" ZRADIO_SYNC_PROBE="$d/probe.py" ZRADIO_SYNC_ZIGPY="$d/bin/zigpy"
export ZRADIO_SYNC_RESTORE="$d/restore.sh" ZRADIO_SYNC_SERVE="$d/serve" ZRADIO_SYNC_SELFCMD="$d/self" ZRADIO_SYNC_ZWAVE_TTY="$d/dev/zwave"
export ZRADIO_SYNC_ZIGBEE_TTY="$d/dev/zigbee" ZRADIO_SYNC_SSH="$d/bin/ssh" ZRADIO_SYNC_PAUSE=0 ZRADIO_SYNC_SWITCH="$d/switch"
EOF
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" sleep "$rec"
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  fake "$d/bin" ss "[ -f '$d/ss-broken' ] && exit 1; [ -f '$d/client' ] && echo 'ESTAB 0 0 10.20.30.50:6639 10.20.30.10:51234'; exit 0"
  printf '#!/usr/bin/env bash\necho "zradio-switch $*" >> %q\n[ -f %q ] && { echo "FAIL  the standby is not ready"; exit 1; }\necho "DONE  handed over"\n' "$d/calls" "$d/switch-fail" > "$d/switch"; chmod +x "$d/switch"
  fake "$d/bin" systemctl "case \"\$1\" in
    is-active) [ \"\$(cat '$d/ser2net')\" = 1 ];;
    start) $rec; [ -f '$d/nostart' ] && exit 1; echo 1 > '$d/ser2net';;
    stop)  $rec; echo 0 > '$d/ser2net';;
    *) $rec; exit 9;; esac"
  fake "$d/bin" ssh "$rec; [ -f '$d/ssh-down' ] && exit 255; cmd=\"\${*: -1}\"; ( . '$pd/env.sh'; SSH_ORIGINAL_COMMAND=\"\$cmd\" bash '$TOOL' serve-ssh )"
  fake "$d/bin" zigpy "$rec; [ -f '$d/zb-fail' ] && { echo 'Traceback: no SRSP'; exit 1; }
    key=$NETKEY; pan=1a2b; [ -f '$d/zb-blank' ] && { key=00000000000000000000000000000000; pan=ffff; }
    printf '{\"coordinator_ieee\": \"00124b00aabbccdd\", \"pan_id\": \"%s\", \"channel\": 25, \"extended_pan_id\": \"dd\", \"network_key\": {\"key\": \"%s\", \"frame_counter\": 4943413, \"sequence_number\": 0}, \"devices\": [{}, {}, {}], \"metadata\": {}}\n' \"\$pan\" \"\$key\" > \"\$5\""
  printf '#!/usr/bin/env bash\n. %q\nexec bash %q "$@"\n' "$d/env.sh" "$TOOL" > "$d/self"; chmod +x "$d/self"
  cat > "$d/probe.py" <<EOF
import json, os, sys
d = "$d"
open(d + "/calls", "a").write("zradio-probe.py " + " ".join(sys.argv[1:]) + "\\n")
knob = lambda n: os.path.exists(d + "/" + n)
if "--rf-receive" in sys.argv:
    m = sys.argv[sys.argv.index("--rf-receive") + 1]
    if knob("rf-" + m + "-fail"):
        print("   FAIL  Z-Wave on /dev/zradio-zwave: SetRFReceiveMode: no answer (CAN; CAN)", file=sys.stderr); sys.exit(1)
    print("   NOTE  Z-Wave: RF receive mode %s (SetRFReceiveMode answered success)" % m.upper(), file=sys.stderr)
    open(d + "/rf-state", "w").write(m)
out = {"zwave": {"ok": True, "home_id_hex": "0xD1A2B3C4", "node_count": 49, "rf": {"region": 9, "tx_power_dbm": 14.0}}}
if "--nvm-dump" in sys.argv:
    if knob("dump-fail"):
        print("   FAIL  Z-Wave on /dev/zradio-zwave: NVM read: no answer", file=sys.stderr); sys.exit(1)
    f = sys.argv[sys.argv.index("--nvm-dump") + 1]
    n = 2048 if knob("dump-short") else 40960
    open(f, "wb").write(b"\\x5a" * n)
    out["zwave"]["nvm_dump"] = {"bytes": n, "size": 40960, "file": f, "ext": True}
print(json.dumps(out))
EOF
  cat > "$d/restore.sh" <<EOF
echo "zradio-apply \$*" >> "$d/calls"
dir=""; prev=""; for x in "\$@"; do [ "\$prev" = --from ] && dir=\$x; prev=\$x; done
[ -e "$d/state/standby-dirty" ] && [ -e "$d/run/applying" ] && echo yes > "$d/marked-during-restore"
cp "\$dir/fetch.json" "$d/fetch-seen.json" 2>/dev/null
[ -f "\$dir/zha-backup-restore.json" ] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["network_key"]["frame_counter"])' "\$dir/zha-backup-restore.json" > "$d/restored-counter"
if [ -f "$d/restore-fail" ]; then echo "FAIL  after the converting pass the stick reads home ID '0xf4486cba' with '49' nodes"; exit 1; fi
echo "== done: restored and verified =="
EOF
  printf '#!/usr/bin/env bash\necho "zradio-serve $*" >> %q\n[ -f %q ] && exit 1\nexit 0\n' "$d/calls" "$d/serve-fail" > "$d/serve"; chmod +x "$d/serve"
}
pair() { vm "$1/a" radio1 10.20.30.5 10.20.30.6 "$1/b" MASTER 1; vm "$1/b" radio2 10.20.30.6 10.20.30.5 "$1/a" BACKUP 0; }
sync() { local d=$1; shift; ( . "$d/env.sh"; bash "$TOOL" "$@" ) > "$d/out" 2>&1; RC=$?; }
jf() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }
nokey() { ! grep -rqs "$NETKEY" "$1/out" "$1/journal" "$1/state" "$1/calls"; }

echo "-- the standby runs the nightly unit too: not the active, exit 0, nothing touched"
pair "$T/p0"; sync "$T/p0/b" run --reason nightly
check "exit 0, says why" bash -c '[ "$2" = 0 ] && grep -q "not the active (ser2net not active, keepalived.s last word BACKUP) — nothing to do" "$1/out"' _ "$T/p0/b" "$RC"
check "no call at all" eq "$(cat "$T/p0/b/calls")" ""

echo "-- one sync, both networks: hello, the pause (ser2net off, both reads, ser2net on), the set over ssh, applied, confirmed"
pair "$T/p1"; sync "$T/p1/a" run --reason nightly
A="$T/p1/a"; B="$T/p1/b"
check "exit 0" eq "$RC" 0
check "the Z-Wave order on the active: receiver off, the NVM read, receiver on" eq "$(grep -oE '^zradio-probe.py --zwave [^ ]+ (--rf-receive (on|off)|--budget 300 --nvm-dump)' "$A/calls" | sed 's/^zradio-probe.py --zwave [^ ]* //; s/--budget 300 //' | tr '\n' ';')" "--rf-receive off;--nvm-dump;--rf-receive on;"
check "zigpy's backup of the coordinator ran once" eq "$(grep -c '^zigpy radio znp .*/dev/zigbee backup ' "$A/calls")" 1
check "ser2net: stopped before the first read, started after the last, once each" eq "$(grep -nE '^(systemctl|zradio-probe.py|zigpy)' "$A/calls" | sed -n '1p;$p' | sed 's/^[0-9]*://; s/ --.*//' | tr '\n' ';')" "systemctl stop ser2net;systemctl start ser2net;"
check "the active serves again and its receiver is on" bash -c '[ "$(cat "$1/ser2net")" = 1 ] && [ "$(cat "$1/rf-state")" = on ]' _ "$A"
check "ssh: the sync key, the pinned host key, bound to SELF, to root@PEER — hello then receive" bash -c '[ "$(grep -c "^ssh -i $1/etc/sync.key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$1/etc/known .* -b 10.20.30.5 root@10.20.30.6 " "$1/calls")" = 2 ] && [ "$(grep -oE "(hello|receive)$" "$1/calls" | tr "\n" ";")" = "hello;receive;" ]' _ "$A"
check "the standby wrote the set with zradio-apply --run --from <in/current>, then silenced its sticks" eq "$(grep -E '^(zradio-apply|zradio-serve)' "$B/calls" | sed "s#$B##g" | tr '\n' ';')" "zradio-apply --run --from /secrets/sync/in/current;zradio-serve down;"
check "standby-dirty and applying were set while the restore ran, and are gone after it" bash -c '[ "$(cat "$1/marked-during-restore")" = yes ] && [ ! -e "$1/state/standby-dirty" ] && [ ! -e "$1/run/applying" ]' _ "$B"
check "the Zigbee counter the standby wrote: the active's reading + 1,000,000" eq "$(cat "$B/restored-counter")" 5943413
check "fetch.json as zradio-apply reads it: the identities and the active's RF config" bash -c '[ "$(python3 -c "import json,sys; f=json.load(open(sys.argv[1])); z=f[\"identities\"][\"zwave\"]; b=f[\"identities\"][\"zigbee\"]; print(z[\"home_id\"], z[\"nodes\"], z[\"rf_region\"], z[\"tx_power_dbm\"], b[\"ieee\"], b[\"pan_id\"], b[\"channel\"], f[\"sets\"][\"zwave\"][:5])" "$1/fetch-seen.json")" = "0xd1a2b3c4 49 9 14.0 00:12:4b:00:aa:bb:cc:dd 1a2b 25 sync-" ]' _ "$B"
GEN=$(jf "$A/state/last-sync.json" gen)
check "the active's record: gen, the reason, one try, the standby's answer" bash -c '[[ "$2" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && [ "$(python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r[\"reason\"], r[\"tries\"], r[\"answer\"].split()[0], r[\"peer\"])" "$1/state/last-sync.json")" = "nightly 1 SYNCED 10.20.30.6" ]' _ "$A" "$GEN"
check "the standby's record names the same gen for both networks" eq "$(jf "$B/state/synced.json" gen) $(jf "$B/state/synced.json" gens.zwave) $(jf "$B/state/synced.json" gens.zigbee)" "$GEN $GEN $GEN"
check "no image stays at rest: the active's read set is gone, the standby keeps the manifest only" bash -c '[ ! -e "$1/secrets/sync/out" ] && [ ! -e "$1/state/sync-pending.json" ] && [ "$(ls "$2/secrets/sync/in/current" | tr "\n" " ")" = "fetch.json manifest.json " ]' _ "$A" "$B"
check "journal: event=sync result=ok on the active with the pause, event=sync-apply result=ok on the standby" bash -c 'grep -qE "^-t zradio event=sync result=ok gen=$3 reason=nightly pause_s=[0-9.]+ total_s=[0-9.]+ tries=1 " "$1/journal" && grep -qE "^-t zradio event=sync-apply result=ok gen=$3 zwave=0xd1a2b3c4/49,zigbee=00:12:4b:00:aa:bb:cc:dd/1a2b/25,counter=5943413 " "$2/journal"' _ "$A" "$B" "$GEN"
check "the network key is in no output, journal, record or call on either side" bash -c 'nokey() { ! grep -rqs "$3" "$1/out" "$1/journal" "$1/state" "$1/calls"; }; nokey "$1" "" "$3" && nokey "$2" "" "$3"' _ "$A" "$B" "$NETKEY"
check "the set dirs are 0700" eq "$(stat -c %a "$B/secrets/sync" "$B/secrets/sync/in" "$B/secrets/sync/in/current" | tr '\n' ' ')" "700 700 700 "
sync "$A" tick
check "tick on the active right after: the standby holds the last sync, nothing read" bash -c '[ "$2" = 0 ] && grep -q "the standby holds this VM.s last sync" "$1/out" && [ "$(grep -c "systemctl stop" "$1/calls")" = 1 ]' _ "$A" "$RC"
sync "$B" status
check "status on the standby: the hello line with the gen, the record" bash -c 'grep -q "^HELLO name=radio2 role=BACKUP serving=no gen=$2 dirty=no applying=no" "$1/out" && grep -q "synced.json" "$1/out"' _ "$B" "$GEN"

echo "-- --only zwave: no zigpy on the active, --only zwave on the standby, the Zigbee gen stays"
: > "$A/calls"; : > "$B/calls"; sleep() { command sleep "$@"; }; command sleep 1.1
sync "$A" run --only zwave
G2=$(jf "$A/state/last-sync.json" gen)
check "exit 0, a newer gen" bash -c '[ "$1" = 0 ] && [[ "$2" > "$3" ]]' _ "$RC" "$G2" "$GEN"
check "no zigpy call; the standby's restore got --only zwave" bash -c '! grep -q "^zigpy" "$1/calls" && grep -q "^zradio-apply --run --from .*/in/current --only zwave$" "$2/calls"' _ "$A" "$B"
check "the standby's record: zwave at the new gen, zigbee at the old one" eq "$(jf "$B/state/synced.json" gens.zwave) $(jf "$B/state/synced.json" gens.zigbee)" "$G2 $GEN"

echo "-- the standby does not answer: nothing is read (no pause), a pending mark that costs no retry wait, exit 1"
pair "$T/p2"; : > "$T/p2/a/ssh-down"; sync "$T/p2/a" run --reason nightly
check "exit 1, step=hello, says nothing was read" bash -c '[ "$2" = 1 ] && grep -q "step=hello reason=nightly — the standby (10.20.30.6) did not answer: nothing was read" "$1/out"' _ "$T/p2/a" "$RC"
check "ser2net never stopped, no probe, no zigpy" bash -c '! grep -qE "^(systemctl|zradio-probe.py|zigpy)" "$1/calls"' _ "$T/p2/a"
check "pending: attempts 0" eq "$(jf "$T/p2/a/state/sync-pending.json" attempts)" 0
rm -f "$T/p2/a/ssh-down"; sync "$T/p2/a" tick
check "tick once the standby is back: a full sync at once (reason catch-up), pending cleared" bash -c '[ "$2" = 0 ] && [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"reason\"])" "$1/state/last-sync.json")" = catch-up ] && [ ! -e "$1/state/sync-pending.json" ]' _ "$T/p2/a" "$RC"

echo "-- the peer says it serves (two actives): nothing read, nothing sent"
pair "$T/p3"; echo 1 > "$T/p3/b/ser2net"; sync "$T/p3/a" run
check "exit 1, names it" bash -c '[ "$2" = 1 ] && grep -q "the peer says it serves" "$1/out" && ! grep -q "systemctl stop" "$1/calls"' _ "$T/p3/a" "$RC"
echo "MASTER x priority=1" > "$T/p3/b/run/role"; echo 0 > "$T/p3/b/ser2net"
( . "$T/p3/b/env.sh"; printf 'x' | SSH_ORIGINAL_COMMAND=receive bash "$TOOL" serve-ssh ) > "$T/p3/b/out" 2>&1; RC=$?
check "receive on a VM whose last word is MASTER: REFUSED, no restore" bash -c '[ "$2" = 1 ] && grep -q "^REFUSED this VM serves" "$1/out" && ! grep -q "zradio-apply" "$1/calls"' _ "$T/p3/b" "$RC"
( . "$T/p3/b/env.sh"; SSH_ORIGINAL_COMMAND="cat /etc/shadow" bash "$TOOL" serve-ssh ) > "$T/p3/b/out" 2>&1; RC=$?
check "the forced command runs hello, receive, poke or yield, nothing else" bash -c '[ "$2" = 1 ] && grep -q "REFUSED: this key runs hello, receive, poke or yield, nothing else" "$1/out"' _ "$T/p3/b" "$RC"

echo "-- the receiver does not come back on after the read: serve-failed, ser2net stays stopped, loud; nothing sent"
pair "$T/p4"; : > "$T/p4/a/rf-on-fail"; sync "$T/p4/a" run
check "exit 1" eq "$RC" 1
check "serve-failed is set (keepalived's check fails: the standby takes the role)" bash -c '[ -e "$1/run/serve-failed" ]' _ "$T/p4/a"
check "ser2net is not started again on a stick that may be deaf" bash -c '[ "$(cat "$1/ser2net")" = 0 ] && ! grep -q "systemctl start" "$1/calls"' _ "$T/p4/a"
check "four tries, then the loud line" bash -c '[ "$(grep -c -- "--rf-receive on" "$1/calls")" = 4 ] && grep -q "event=sync result=loud step=zwave-receiver" "$1/journal"' _ "$T/p4/a"
check "nothing was sent to the standby" bash -c '! grep -q "receive$" "$1/calls" && ! grep -q zradio-apply "$2/calls"' _ "$T/p4/a" "$T/p4/b"

echo "-- reads that fail or do not check: the active serves again, nothing sent, pending"
pair "$T/p5"; : > "$T/p5/a/dump-fail"; sync "$T/p5/a" run
check "the NVM read fails: exit 1, step=read-zwave, receiver back on, ser2net back" bash -c '[ "$2" = 1 ] && grep -q "step=read-zwave — the NVM read failed" "$1/out" && [ "$(cat "$1/rf-state")" = on ] && [ "$(cat "$1/ser2net")" = 1 ]' _ "$T/p5/a" "$RC"
pair "$T/p5b"; : > "$T/p5b/a/zb-fail"; sync "$T/p5b/a" run
check "zigpy's backup fails: exit 1, step=read-zigbee, serving again, nothing sent" bash -c '[ "$2" = 1 ] && grep -q "step=read-zigbee" "$1/out" && [ "$(cat "$1/ser2net")" = 1 ] && ! grep -q "receive$" "$1/calls"' _ "$T/p5b/a" "$RC"
pair "$T/p5c"; : > "$T/p5c/a/zb-blank"; sync "$T/p5c/a" run
check "a coordinator that is on no network (blank key): step=check, the set dropped, pending" bash -c '[ "$2" = 1 ] && grep -q "step=check .*the coordinator is not on a network" "$1/out" && [ ! -e "$1/secrets/sync/out" ] && [ -f "$1/state/sync-pending.json" ]' _ "$T/p5c/a" "$RC"
pair "$T/p5d"; : > "$T/p5d/a/dump-short"; sync "$T/p5d/a" run
check "a short NVM read: step=check names the bytes" bash -c '[ "$2" = 1 ] && grep -q "the NVM read is short: 2048 of 40960 bytes" "$1/out"' _ "$T/p5d/a" "$RC"
pair "$T/p5e"; : > "$T/p5e/a/nostart"; sync "$T/p5e/a" run
check "ser2net does not start after the read: serve-failed, loud" bash -c '[ -e "$1/run/serve-failed" ] && grep -q "result=loud step=ser2net" "$1/journal"' _ "$T/p5e/a"

echo "-- the standby's restore fails: three tries without a second read, FAILED, the read set kept, the standby dirty"
pair "$T/p6"; : > "$T/p6/b/restore-fail"; sync "$T/p6/a" run --reason nightly
A="$T/p6/a"; B="$T/p6/b"
check "exit 1, step=apply, three tries" bash -c '[ "$2" = 1 ] && grep -q "step=apply .* tries=3 — not confirmed by the standby (last answer: FAILED gen=" "$1/out"' _ "$A" "$RC"
check "one read only; the retry pauses 30 s and 120 s" bash -c '[ "$(grep -c "systemctl stop" "$1/calls")" = 1 ] && [ "$(grep "^sleep" "$1/calls" | tr "\n" ";")" = "sleep 30;sleep 120;" ]' _ "$A"
check "the read set and the pending mark stay on the active (0700)" bash -c '[ -f "$1/secrets/sync/out/manifest.json" ] && [ -f "$1/secrets/sync/out/zwave-nvm.bin" ] && [ "$(stat -c %a "$1/secrets/sync/out")" = 700 ] && [ -f "$1/state/sync-pending.json" ]' _ "$A"
check "the standby: standby-dirty stays, applying is gone, the set is kept, no zradio-serve down, the journal names the FAIL line" bash -c '[ -e "$1/state/standby-dirty" ] && [ ! -e "$1/run/applying" ] && [ -f "$1/secrets/sync/in/current/zwave-nvm.bin" ] && ! grep -q "zradio-serve" "$1/calls" && grep -q "event=sync-apply result=failed gen=.* step=restore rc=1 — FAIL  after the converting pass" "$1/journal"' _ "$B"
sync "$B" hello
check "hello says dirty=yes" has "$B/out" "dirty=yes"
sync "$A" tick
check "tick on the active minutes later: the next try waits its turn (no read, no send)" bash -c 'grep -q "the next try waits its turn" "$1/out" && [ "$(grep -c "receive$" "$1/calls")" = 3 ]' _ "$A"
rm -f "$B/restore-fail"; : > "$B/calls"; sync "$B" tick
check "tick on the standby: the kept set is written again, dirty cleared, sticks silenced" bash -c '[ "$2" = 0 ] && grep -q "^SYNCED gen=" "$1/out" && [ ! -e "$1/state/standby-dirty" ] && [ "$(grep -cE "^(zradio-apply --run --from|zradio-serve down)" "$1/calls")" = 2 ]' _ "$B" "$RC"
: > "$B/restore-fail"; : > "$B/state/standby-dirty"; sync "$B" tick
check "a set written to the end keeps no image: reapply has nothing to write, says so" bash -c 'grep -q "REFUSED BAD no zwave-nvm.bin" "$1/out"' _ "$B"
rm -f "$B/restore-fail"; touch -d '20 minutes ago' "$A/state/sync-pending.json"; : > "$A/calls"; sync "$A" tick
check "tick on the active after the wait: the kept set is sent again — no read, no pause — and confirmed" bash -c '[ "$2" = 0 ] && ! grep -qE "^(systemctl|zradio-probe.py|zigpy)" "$1/calls" && grep -q "the read set of the last attempt is sent again" "$1/out" && [ ! -e "$1/state/sync-pending.json" ] && [ ! -e "$1/secrets/sync/out" ] && [ ! -e "$3/state/standby-dirty" ]' _ "$A" "$RC" "$B"

echo "-- zradio-serve down fails after the restore: FAILED step=silence, dirty stays"
pair "$T/p7"; : > "$T/p7/b/serve-fail"; ZRADIO_SYNC_RETRY_PAUSES="" sync "$T/p7/a" run
check "exit 1 after one try, the answer names the step" bash -c '[ "$2" = 1 ] && grep -q "last answer: FAILED gen=.* step=silence" "$1/out" && [ -e "$3/state/standby-dirty" ]' _ "$T/p7/a" "$RC" "$T/p7/b"

echo "-- a set older than the one the standby holds; a set that was changed on the way"
pair "$T/p8"; echo '{"gen": "29991231T000000Z", "gens": {}}' > "$T/p8/b/state/synced.json"; sync "$T/p8/a" run
check "stale: REFUSED, no retry (a refusal does not change by asking again), no restore" bash -c '[ "$2" = 1 ] && grep -q "REFUSED stale: this VM holds 29991231T000000Z" "$1/out" && ! grep -q "^sleep" "$1/calls" && ! grep -q zradio-apply "$3/calls"' _ "$T/p8/a" "$RC" "$T/p8/b"
pair "$T/p9"; sync "$T/p9/a" run; B="$T/p9/b"
mkdir -p "$T/p9/set"; head -c 40960 /dev/zero > "$T/p9/set/zwave-nvm.bin"
printf '{"format": "zradio sync v1", "gen": "29990101T000000Z", "only": "zwave", "zwave": {"home_id": "0xd1a2b3c4", "nodes": 49, "rf_region": 9, "tx_power_dbm": 14.0, "sha256": "%064d"}}\n' 0 > "$T/p9/set/manifest.json"
: > "$B/calls"; ( . "$B/env.sh"; tar -C "$T/p9/set" -cf - manifest.json zwave-nvm.bin | SSH_ORIGINAL_COMMAND=receive bash "$TOOL" serve-ssh ) > "$B/out" 2>&1; RC=$?
check "an image that is not the manifest's sha256: REFUSED, nothing written, not dirty" bash -c '[ "$2" = 1 ] && grep -q "^REFUSED BAD zwave-nvm.bin does not match the manifest.s sha256" "$1/out" && ! grep -q zradio-apply "$1/calls" && [ ! -e "$1/state/standby-dirty" ]' _ "$B" "$RC"
echo x > "$T/p9/set/extra.sh"; ( . "$B/env.sh"; tar -C "$T/p9/set" -cf - manifest.json zwave-nvm.bin extra.sh | SSH_ORIGINAL_COMMAND=receive bash "$TOOL" serve-ssh ) > "$B/out" 2>&1
check "a file that is not part of a set: REFUSED" has "$B/out" "REFUSED BAD unexpected file(s) in the set: extra.sh"
( . "$B/env.sh"; echo "not a tar" | SSH_ORIGINAL_COMMAND=receive bash "$TOOL" serve-ssh ) > "$B/out" 2>&1
check "a stream that is not a tar: FAILED, nothing kept" bash -c 'grep -q "^FAILED the stream was not a tar" "$1/out" && [ ! -e "$1/secrets/sync/in/incoming" ]' _ "$B"

echo "-- the standby's tick drops a read set and a pending mark left from an earlier turn as the active"
pair "$T/pa"; B="$T/pa/b"; mkdir -p "$B/secrets/sync/out"; echo '{"gen":"20261101T000000Z","only":""}' > "$B/secrets/sync/out/manifest.json"; echo '{"gen":"x","attempts":1}' > "$B/state/sync-pending.json"
sync "$B" tick
check "dropped, said" bash -c '[ ! -e "$1/secrets/sync/out" ] && [ ! -e "$1/state/sync-pending.json" ] && grep -q "from an earlier turn as the active: dropped" "$1/out"' _ "$B"

echo "-- tick on the active: a standby that holds another gen (a takeover, a rebuilt standby) gets a sync"
pair "$T/pb"; sync "$T/pb/a" run; echo '{"gen": "20200101T000000Z", "gens": {}}' > "$T/pb/b/state/synced.json"; : > "$T/pb/a/calls"; command sleep 1.1; sync "$T/pb/a" tick
check "a read and a send, reason catch-up" bash -c '[ "$2" = 0 ] && grep -q "systemctl stop ser2net" "$1/calls" && grep -q "reason=catch-up" "$1/journal"' _ "$T/pb/a" "$RC"

echo "-- --rehearse: a VM that does not serve reads its own sticks and leaves them silent; refused on one that serves"
vm "$T/pc" radio2 10.20.30.6 10.20.30.5 "$T/pc" BACKUP 0; echo 'export ZRADIO_SYNC_PEER=10.20.30.6' >> "$T/pc/env.sh"; sync "$T/pc" run --rehearse
check "exit 0 against itself (ZRADIO_SYNC_PEER = SELF)" eq "$RC" 0
check "ser2net never touched; the receiver calls: off, the read, off again — never on" bash -c '! grep -q "^systemctl \(stop\|start\)" "$1/calls" && ! grep -q -- "--rf-receive on" "$1/calls" && [ "$(grep -c -- "--rf-receive off" "$1/calls")" = 2 ] && [ "$(cat "$1/rf-state")" = off ]' _ "$T/pc"
check "read, sent to itself, written, silenced" eq "$(grep -oE '^(zigpy radio znp [^ ]+ backup|zradio-apply --run|zradio-serve down)' "$T/pc/calls" | sed "s#$T/pc##" | tr '\n' ';')" "zigpy radio znp /dev/zigbee backup;zradio-apply --run;zradio-serve down;"
pair "$T/pd"; sync "$T/pd/a" run --rehearse
check "--rehearse on the active: REFUSED, nothing called" bash -c '[ "$2" = 1 ] && grep -q "^REFUSED: --rehearse on a VM that serves" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/pd/a" "$RC"

echo "-- keys and trust"
pair "$T/pk"; A="$T/pk/a"; B="$T/pk/b"; rm -f "$A/etc/sync.key"
sync "$A" keys; KA=$(sed -n 's/^SYNCKEY //p' "$A/out"); HA=$(sed -n 's/^HOSTKEY //p' "$A/out")
check "keys: an ed25519 key made 0600, the two PUBLIC keys printed as two words each, nothing else" bash -c '[ "$(stat -c %a "$1/etc/sync.key")" = 600 ] && [[ "$2" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] && [[ "$3" =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKey ]] && [ "$(wc -l < "$1/out")" = 2 ] && ! grep -q PRIVATE "$1/out"' _ "$A" "$KA" "$HA"
cp "$A/etc/sync.key" "$T/pk/key1"; sync "$A" keys
check "keys again: the same key, not a new one" bash -c 'cmp -s "$1/etc/sync.key" "$2" && [ "$(sed -n "s/^SYNCKEY //p" "$1/out")" = "$3" ]' _ "$A" "$T/pk/key1" "$KA"
echo "ssh-ed25519 AAAAOTHERKEY someone@laptop" > "$B/root.ssh/authorized_keys"
sync "$B" trust --sync-key "$KA" --host-key "$HA"
check "trust on the peer: exit 0" eq "$RC" 0
check "known_hosts: PEER and its host key, one line" eq "$(cat "$B/etc/known")" "10.20.30.5 $HA"
check "authorized_keys: the forced command, from=PEER, restrict; the other key kept; 0600" bash -c '[ "$(grep -c . "$1/root.ssh/authorized_keys")" = 2 ] && grep -q "^ssh-ed25519 AAAAOTHERKEY someone@laptop$" "$1/root.ssh/authorized_keys" && grep -qF "command=\"$1/self serve-ssh\",from=\"10.20.30.5\",restrict $2 zradio-sync-peer" "$1/root.ssh/authorized_keys" && [ "$(stat -c %a "$1/root.ssh/authorized_keys")" = 600 ]' _ "$B" "$KA"
sync "$B" trust --sync-key "$KA" --host-key "$HA" --peer 10.20.30.6
check "trust again (another peer address): the line replaced, not added" bash -c '[ "$(grep -c "serve-ssh" "$1/root.ssh/authorized_keys")" = 1 ] && grep -q "from=\"10.20.30.6\"" "$1/root.ssh/authorized_keys" && [ "$(cat "$1/etc/known")" = "10.20.30.6 $2" ]' _ "$B" "$HA"
sync "$B" trust --sync-key "ssh-ed25519 AAAA x; rm -rf /" --host-key "$HA"
check "a key that is not two clean words: refused (exit 2), nothing changed" bash -c '[ "$2" = 2 ] && [ "$(grep -c "serve-ssh" "$1/root.ssh/authorized_keys")" = 1 ]' _ "$B" "$RC"
rm -f "$A/etc/known"; sync "$A" run
check "run on a VM that is not paired: step=keys, nothing read" bash -c '[ "$2" = 1 ] && grep -q "step=keys" "$1/out" && ! grep -q "systemctl stop" "$1/calls"' _ "$A" "$RC"

echo "-- beat: the state line for ops, from both roles; the standby's tick hushes its sticks"
pair "$T/pe"; sync "$T/pe/a" beat; sync "$T/pe/b" beat
check "the active's line" has "$T/pe/a/journal" "-t zradio event=state name=radio1 role=MASTER serving=yes gen=none dirty=no applying=no zwave=synced:zwave-800 zigbee=synced:znp term=0 used=no turn=none client=no outdated=no wait=no prio=100 zbfloor=0 last=none"
check "the standby's line" has "$T/pe/b/journal" "-t zradio event=state name=radio2 role=BACKUP serving=no gen=none dirty=no applying=no zwave=synced:zwave-800 zigbee=synced:znp term=0 used=no turn=none client=no outdated=no wait=no prio=100 zbfloor=0 last=none"
sync "$T/pe/b" tick
check "the standby's tick: zradio-serve hush, nothing else" eq "$(cat "$T/pe/b/calls")" "zradio-serve hush"
: > "$T/pe/b/state/standby-dirty"; : > "$T/pe/b/calls"; sync "$T/pe/b" tick
check "a dirty standby with no kept set: no hush on half-written sticks" eq "$(cat "$T/pe/b/calls")" ""

echo "-- what is synced follows radios.conf on both VMs: the kinds 'synced' on both, with the same family"
radios() { printf '%s\n' "${@:2}" > "$1/etc/radios.conf"; }
pair "$T/q1"; radios "$T/q1/a" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=none; radios "$T/q1/b" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=none
sync "$T/q1/a" run
check "a pair with Z-Wave sticks only: one sync of the Z-Wave network, no zigpy call, the standby got --only zwave" bash -c '[ "$3" = 0 ] && ! grep -q "^zigpy" "$1/calls" && grep -q "^zradio-apply --run --from .* --only zwave$" "$2/calls" && grep -q "event=sync result=ok" "$1/journal"' _ "$T/q1/a" "$T/q1/b" "$RC"
pair "$T/q2"; radios "$T/q2/a" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=served ZIGBEE_FAMILY=ezsp; radios "$T/q2/b" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=served ZIGBEE_FAMILY=ezsp
sync "$T/q2/a" run
check "a served-only Zigbee stick is never read: no zigpy call, the Z-Wave network is synced" bash -c '[ "$3" = 0 ] && ! grep -q "^zigpy" "$1/calls" && grep -q -- "--only zwave$" "$2/calls"' _ "$T/q2/a" "$T/q2/b" "$RC"
pair "$T/q3"; radios "$T/q3/b" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=served ZIGBEE_FAMILY=ezsp
sync "$T/q3/a" run
check "the standby's Zigbee stick is another family: only Z-Wave is synced, and a note says the other network is not copied" bash -c '[ "$3" = 0 ] && ! grep -q "^zigpy" "$1/calls" && grep -q -- "--only zwave$" "$2/calls" && grep -q "event=sync result=note only zwave is synced on both VMs" "$1/journal"' _ "$T/q3/a" "$T/q3/b" "$RC"
pair "$T/q4"; radios "$T/q4/b" ZWAVE=synced ZWAVE_FAMILY=zwave-700 ZIGBEE=none
sync "$T/q4/a" run
check "no kind matches (another Z-Wave family, no Zigbee stick): result=mismatch, nothing read, no pause, exit 1" bash -c '[ "$3" = 1 ] && grep -q "event=sync result=mismatch" "$1/journal" && ! grep -q "systemctl stop" "$1/calls" && ! grep -q "receive$" "$1/calls" && [ ! -e "$1/state/sync-pending.json" ]' _ "$T/q4/a" "$T/q4/b" "$RC"
sync "$T/q3/a" run --only zigbee
check "--only for a kind that is not synced on both: refused before any read" bash -c '[ "$2" = 1 ] && grep -q "step=radios" "$1/out" && ! grep -q "^zigpy" "$1/calls"' _ "$T/q3/a" "$RC"
pair "$T/q5"; radios "$T/q5/a" ZWAVE=served ZIGBEE=served; : > "$T/q5/a/calls"
sync "$T/q5/a" run; R1=$RC; sync "$T/q5/a" tick
check "nothing on the active is 'synced': run and tick end 0 without a call (no ssh, no pause)" bash -c '[ "$2" = 0 ] && [ "$3" = 0 ] && [ ! -s "$1/calls" ] && grep -q "nothing to sync" "$1/out"' _ "$T/q5/a" "$R1" "$RC"
pair "$T/q6"; sync "$T/q6/a" run; B="$T/q6/b"; radios "$B" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=none
mkdir -p "$T/q6/set"; head -c 40960 /dev/zero > "$T/q6/set/zwave-nvm.bin"; : > "$B/calls"
python3 - "$T/q6/set" <<'PY'
import hashlib, json, sys
d = sys.argv[1]; sha = lambda n: hashlib.sha256(open(d + "/" + n, "rb").read()).hexdigest()
z = {"coordinator_ieee": "00124b00aabbccdd", "pan_id": "1a2b", "channel": 25, "network_key": {"key": "a1" * 16, "frame_counter": 5}}
json.dump(z, open(d + "/zha-backup.json", "w"))
m = {"format": "zradio sync v1", "gen": "29990101T000000Z", "only": "",
     "zwave": {"home_id": "0xd1a2b3c4", "nodes": 49, "rf_region": 9, "tx_power_dbm": 14.0, "sha256": sha("zwave-nvm.bin")},
     "zigbee": {"ieee": "00:12:4b:00:aa:bb:cc:dd", "pan_id": "1a2b", "channel": 25, "sha256": sha("zha-backup.json")}}
json.dump(m, open(d + "/manifest.json", "w"))
PY
( . "$B/env.sh"; tar -C "$T/q6/set" -cf - manifest.json zwave-nvm.bin zha-backup.json | SSH_ORIGINAL_COMMAND=receive bash "$TOOL" serve-ssh ) > "$B/out" 2>&1; RC=$?
check "a set with a Zigbee image for a standby that has no synced Zigbee stick: REFUSED, nothing written, not dirty" bash -c '[ "$2" = 1 ] && grep -q "^REFUSED no synced zigbee stick here" "$1/out" && ! grep -q zradio-apply "$1/calls" && [ ! -e "$1/state/standby-dirty" ]' _ "$B" "$RC"
pair "$T/q7"; rm -f "$T/q7/b/etc/radios.conf"; sync "$T/q7/b" hello
check "a VM with no radios.conf says none / none in its hello (nothing is synced onto it)" has "$T/q7/b/out" "zwave=none zigbee=none"

echo "-- the version: a sync carries the active's term; the standby's copy is that term, not yet used"
act() { echo "ELECTION=act" >> "$1/etc/zradio.conf"; }
ver() { cat "$1/state/version" 2>/dev/null; }
pair "$T/v1"; echo "term=4 used=yes" > "$T/v1/a/state/version"; : > "$T/v1/b/state/outdated"; : > "$T/v1/b/run/hold"; sync "$T/v1/a" run
check "exit 0; the manifest's term reached the standby: term=4 used=no" bash -c '[ "$2" = 0 ] && [ "$(cat "$1/state/version")" = "term=4 used=no" ]' _ "$T/v1/b" "$RC"
check "a landed sync settles 'outdated' and lifts the hold" bash -c '[ ! -e "$1/state/outdated" ] && [ ! -e "$1/run/hold" ]' _ "$T/v1/b"
check "the Zigbee counter floors: the active's own reading, the standby's written value" eq "$(cat "$T/v1/a/state/counter-floor") $(cat "$T/v1/b/state/counter-floor")" "4943413 5943413"
pair "$T/v2"; act "$T/v2/b"; echo "term=4 used=yes" > "$T/v2/a/state/version"; echo "term=6 used=no" > "$T/v2/b/state/version"; sync "$T/v2/a" run
check "ELECTION=act: a set of a lower term is refused by the VM that is ahead, nothing written, its version kept" bash -c '[ "$3" = 1 ] && grep -q "REFUSED older term: the set is term 4, this VM holds 6" "$1/out" && ! grep -q zradio-apply "$2/calls" && [ "$(cat "$2/state/version")" = "term=6 used=no" ]' _ "$T/v2/a" "$T/v2/b" "$RC"
pair "$T/v3"; echo "term=4 used=yes" > "$T/v3/a/state/version"; echo "term=6 used=no" > "$T/v3/b/state/version"; sync "$T/v3/a" run
check "observe mode (the default): the same set is written as before (nothing is refused for its term)" bash -c '[ "$2" = 0 ] && grep -q zradio-apply "$1/calls"' _ "$T/v3/b" "$RC"
check "…and the standby's journal says what act mode would have done: would-refuse" has "$T/v3/b/journal" "event=sync-apply result=would-refuse"

echo "-- beat: the term goes up once, when Home Assistant uses a confirmed turn"
pair "$T/b1"; A="$T/b1/a"; echo "term=4 used=no" > "$A/state/version"; echo confirmed > "$A/run/turn"; sync "$A" beat
check "serving, confirmed, but no client yet: no advance; hello says client=no" bash -c '[ "$(cat "$1/state/version")" = "term=4 used=no" ] && grep -q " client=no " "$1/out"' _ "$A"
: > "$A/client"; sync "$A" beat
check "a client is connected: term 5, used, said once in the journal, and the state line shows it" bash -c '[ "$(cat "$1/state/version")" = "term=5 used=yes" ] && grep -q "event=version result=advanced term=5" "$1/journal" && grep -q "event=state .* term=5 used=yes turn=confirmed client=yes" "$1/journal"' _ "$A"
sync "$A" beat
check "the next beat does not advance again" eq "$(ver "$A"); $(grep -c 'event=version' "$A/journal")" "term=5 used=yes; 1"
pair "$T/b2"; A="$T/b2/a"; echo "term=4 used=no" > "$A/state/version"; echo provisional > "$A/run/turn"; : > "$A/client"; sync "$A" beat
check "a provisional turn never advances, client or not" eq "$(ver "$A")" "term=4 used=no"
pair "$T/b3"; A="$T/b3/a"; echo confirmed > "$A/run/turn"; : > "$A/client"; : > "$A/ss-broken"; sync "$A" beat
check "ss does not work: client=unknown, no advance (never a guess)" bash -c '[ ! -e "$1/state/version" ] && grep -q " client=unknown " "$1/out"' _ "$A"
pair "$T/b4"; B="$T/b4/b"; echo confirmed > "$B/run/turn"; : > "$B/client"; sync "$B" beat
check "a standby never advances" bash -c '[ ! -e "$1/state/version" ]' _ "$B"
pair "$T/bq"; A="$T/bq/a"; echo "term=4 used=no" > "$A/state/version"; echo confirmed > "$A/run/turn"; : > "$A/client"; sync "$A" beat --quiet
check "beat --quiet (zradio-gate's look every few seconds): the version advances, and NO state line is written" bash -c '[ "$(cat "$1/state/version")" = "term=5 used=yes" ] && ! grep -q "event=state" "$1/journal" && [ ! -s "$1/out" ]' _ "$A"
pair "$T/b5"; A="$T/b5/a"; echo "term=4 used=no" > "$A/state/version"; echo confirmed > "$A/run/turn"; echo "term=5 zbfloor=9" > "$A/state/outdated"; : > "$A/client"; sync "$A" beat
check "observe mode: an 'outdated' VM that Home Assistant uses advances like any other, and is not outdated any more (it IS the copy in use)" bash -c '[ "$(cat "$1/state/version")" = "term=5 used=yes" ] && [ ! -e "$1/state/outdated" ]' _ "$A"
pair "$T/b6"; A="$T/b6/a"; act "$A"; echo "term=4 used=no" > "$A/state/version"; echo "term=4 used=yes" > "$T/b6/b/state/version"; echo confirmed > "$A/run/turn"; : > "$A/client"; sync "$A" beat
check "ELECTION=act, the peer answers and is AHEAD (a cut link healed; an old active back first): no advance, the turn is provisional now, said" bash -c '[ "$(cat "$1/state/version")" = "term=4 used=no" ] && [ "$(cat "$1/run/turn")" = provisional ] && grep -q "event=election result=behind Home Assistant is connected here, but the peer answers and holds the newer networks (term=4 used=yes; this VM term=4 used=no)" "$1/journal"' _ "$A"
check "…and the state line of that beat shows it" has "$A/out" " term=4 used=no turn=provisional client=yes "
pair "$T/b7"; A="$T/b7/a"; echo "term=4 used=no" > "$A/state/version"; echo "term=4 used=yes" > "$T/b7/b/state/version"; echo confirmed > "$A/run/turn"; : > "$A/client"; sync "$A" beat
check "observe mode, the same: would-behind is said, and the version advances as before this feature" bash -c '[ "$(cat "$1/state/version")" = "term=5 used=yes" ] && [ "$(cat "$1/run/turn")" = confirmed ] && grep -q "event=election result=would-behind" "$1/journal"' _ "$A"
pair "$T/b8"; A="$T/b8/a"; act "$A"; echo "term=4 used=no" > "$A/state/version"; echo "term=9 used=yes" > "$T/b8/b/state/version"; echo confirmed > "$A/run/turn"; : > "$A/client"; : > "$A/ssh-down"; sync "$A" beat
check "ELECTION=act, the peer does not answer (it is dead, or the link is cut): the version advances — this is the failover" eq "$(ver "$A")" "term=5 used=yes"
pair "$T/b9"; A="$T/b9/a"; act "$A"; echo "term=4 used=no" > "$A/state/version"; echo "term=4 used=no" > "$T/b9/b/state/version"; echo confirmed > "$A/run/turn"; : > "$A/client"; sync "$A" beat
check "ELECTION=act, the peer answers and is level (it released its claim): the version advances" eq "$(ver "$A")" "term=5 used=yes"

echo "-- poke and yield: the two things a peer may ask besides hello and receive"
pair "$T/k1"; A="$T/k1/a"; B="$T/k1/b"; sync "$B" peer-poke
check "poke from the standby: the active starts its tick now, without waiting" bash -c 'grep -q "^POKED" "$2/out" && grep -q "^systemctl start --no-block zradio-sync-tick.service" "$1/calls"' _ "$A" "$B"
sync "$A" peer-poke
check "poke to a VM that does not serve: ignored" bash -c 'grep -q "^IGNORED" "$1/out" && ! grep -q "sync-tick" "$2/calls"' _ "$A" "$B"
echo "term=5 used=yes" > "$B/state/version"; echo "term=4 used=yes" > "$A/state/version"; sync "$B" peer-yield
check "yield in observe mode: refused, said as would-yield on the serving VM, no switch" bash -c 'grep -q "^REFUSED observe mode" "$2/out" && grep -q "event=election result=would-yield" "$1/journal" && ! grep -q "^zradio-switch" "$1/calls"' _ "$A" "$B"
act "$A"; sync "$B" peer-yield
check "ELECTION=act and the asker is ahead: the serving VM runs zradio-switch --run --yield and answers YIELDED" bash -c 'grep -q "^YIELDED" "$2/out" && grep -q "^zradio-switch --run --yield$" "$1/calls"' _ "$A" "$B"
: > "$A/calls"; echo "term=4 used=no" > "$B/state/version"; sync "$B" peer-yield
check "the asker is not ahead (term 4 unused against term 4 used): refused, no switch" bash -c 'grep -q "^REFUSED not more advanced" "$2/out" && ! grep -q "^zradio-switch" "$1/calls"' _ "$A" "$B"
echo "term=5 used=yes" > "$B/state/version"; : > "$A/switch-fail"; sync "$B" peer-yield
check "the handover fails on the serving VM: FAILED with its reason, a loud line" bash -c 'grep -q "^FAILED yield: FAIL  the standby is not ready" "$2/out" && grep -q "event=election result=loud yield" "$1/journal"' _ "$A" "$B"
( . "$B/env.sh"; SSH_ORIGINAL_COMMAND="yield 9 yes" bash "$TOOL" serve-ssh ) > "$B/out" 2>&1
check "yield on a VM that does not serve: refused" has "$B/out" "REFUSED this VM does not serve"
: > "$A/calls"; ( . "$A/env.sh"; SSH_ORIGINAL_COMMAND="yield 9 yes; reboot" bash "$TOOL" serve-ssh ) > "$A/out" 2>&1
check "anything glued to the two arguments: refused as malformed, nothing run" bash -c 'grep -q "REFUSED yield wants <term> <yes|no>" "$1/out" && ! grep -q "^zradio-switch" "$1/calls"' _ "$A"
( . "$A/env.sh"; SSH_ORIGINAL_COMMAND="yield x yes" bash "$TOOL" serve-ssh ) > "$A/out" 2>&1
check "yield with a term that is not a number: refused" has "$A/out" "REFUSED yield wants <term> <yes|no>"

echo "-- self-raise: this VM's own Zigbee counter above a number, before an older copy goes on the air"
pair "$T/s1"; B="$T/s1/b"; sync "$B" self-raise --above 9000000
check "exit 0 on the standby" eq "$RC" 0
check "its own backup is read, written back through zradio-apply (--only zigbee), then silenced" eq "$(grep -E '^(zigpy|zradio-apply|zradio-serve)' "$B/calls" | sed "s#$B##g; s# /secrets.*raise/zha-backup.json##" | tr '\n' ';')" "zigpy radio znp /dev/zigbee backup;zradio-apply --run --only zigbee --from /secrets/sync/in/raise;zradio-serve down;"
check "the counter written is max(read 4943413, 9000000) + 1000000" eq "$(cat "$B/restored-counter")" "10000000"
check "the floor is recorded, the markers are gone, no image stays, the journal has the two numbers and no key" bash -c '[ "$(cat "$1/state/counter-floor")" = 10000000 ] && [ ! -e "$1/state/standby-dirty" ] && [ ! -e "$1/run/applying" ] && [ ! -e "$1/secrets/sync/in/raise" ] && grep -q "event=election result=raised .*4943413 → 10000000" "$1/journal"' _ "$B"
check "the network key is nowhere in the output or the journal" nokey "$B"
pair "$T/s2"; B="$T/s2/b"; sync "$B" self-raise --above 100
check "a number below the stick's own reading: the reading + 1000000" eq "$(cat "$B/restored-counter")" "5943413"
pair "$T/s3"; sync "$T/s3/a" self-raise --above 100
check "on a VM that serves: refused, the stick is not touched" bash -c '[ "$2" = 1 ] && grep -q "^REFUSED this VM serves" "$1/out" && ! grep -q "^zigpy" "$1/calls"' _ "$T/s3/a" "$RC"
pair "$T/s4"; B="$T/s4/b"; : > "$B/zb-blank"; sync "$B" self-raise --above 100
check "a coordinator that holds no network: exit 1, a loud line, nothing written" bash -c '[ "$2" = 1 ] && grep -q "result=loud self-raise: BAD this coordinator is not on a network" "$1/journal" && ! grep -q zradio-apply "$1/calls"' _ "$B" "$RC"
pair "$T/s5"; B="$T/s5/b"; : > "$B/restore-fail"; sync "$B" self-raise --above 100
check "the write fails: exit 1, standby-dirty stays (a half-written stick does not serve)" bash -c '[ "$2" = 1 ] && [ -e "$1/state/standby-dirty" ] && [ ! -e "$1/run/applying" ]' _ "$B" "$RC"
pair "$T/s6"; B="$T/s6/b"; radios "$B" ZWAVE=synced ZWAVE_FAMILY=zwave-800 ZIGBEE=served ZIGBEE_FAMILY=ezsp; sync "$B" self-raise --above 100
check "no synced Zigbee stick: nothing to raise, exit 0, no call" bash -c '[ "$2" = 0 ] && [ ! -s "$1/calls" ]' _ "$B" "$RC"

echo "-- the conf and the usage"
pair "$T/pz"; echo 'PEER=$(reboot)' >> "$T/pz/a/etc/zradio.conf"; sync "$T/pz/a" hello
check "a conf line that is not KEY=value: refused before it is sourced" bash -c '[ "$2" = 2 ] && grep -q "holds a line that is not KEY=value" "$1/out"' _ "$T/pz/a" "$RC"
OUT=$(bash "$TOOL" --help 2>&1); RC=$?
check "--help: exit 0, names run, tick, trust and what never happens" bash -c '[ "$1" = 0 ] && for w in "zradio-sync run" "zradio-sync tick" "zradio-sync trust" "What never happens"; do printf "%s" "$2" | grep -qF "$w" || exit 1; done' _ "$RC" "$OUT"

echo "-- a VM without a peer yet; a VM whose own address changed"
vm "$T/np" radio1 10.20.30.5 10.20.30.6 "$T/np-none" MASTER 1; sed -i '/^PEER=/d' "$T/np/etc/zradio.conf"; fake "$T/np/bin" ip 'printf "2: eth0    inet 10.20.30.5/24 scope global eth0\n"'
sync "$T/np" peer-hello
check "peer-hello without a PEER in the conf: no ssh, exit 255, 'no peer yet'" bash -c '[ "$2" = 255 ] && grep -q "no peer yet (PEER is not set" "$1/out" && ! grep -q "^ssh" "$1/calls"' _ "$T/np" "$RC"
sync "$T/np" run
check "run without a PEER: nothing to sync, exit 0, no stick touched, no failure in the journal" bash -c '[ "$2" = 0 ] && grep -q "no peer yet .*nothing to sync" "$1/out" && ! grep -q "zradio-probe" "$1/calls" && ! grep -q "result=failed" "$1/journal"' _ "$T/np" "$RC"
sync "$T/np" tick
check "tick without a PEER: exit 0, quiet" bash -c '[ "$2" = 0 ] && ! grep -q "result=failed\|result=loud" "$1/journal"' _ "$T/np" "$RC"
vm "$T/ac" radio1 10.20.30.5 10.20.30.6 "$T/ac-none" BACKUP 0; fake "$T/ac/bin" ip 'printf "2: eth0    inet 10.20.30.5/24 scope global eth0\n"'
sync "$T/ac" tick
check "tick while the VM holds its address: no word about it" bash -c '! grep -q "event=address" "$1/journal"' _ "$T/ac"
fake "$T/ac/bin" ip 'printf "2: eth0    inet 10.20.30.99/24 scope global dynamic eth0\n"'
sync "$T/ac" tick
check "tick when the VM's address is not SELF any more: one loud journal line with both addresses and what to do" bash -c '[ "$(grep -c "event=address result=loud this VM does not hold its address 10.20.30.5 any more (it holds 10.20.30.99)" "$1/journal")" = 1 ] && grep -q "reservation in the DHCP server" "$1/journal"' _ "$T/ac"

finish
