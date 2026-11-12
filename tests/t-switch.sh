#!/usr/bin/env bash
# t-switch.sh — guest/sbin/zradio-switch against fakes: zradio-sync (peer-hello answers from a file that the
# fake systemctl rewrites when keepalived stops — the standby taking the role; run recorded, rc by knob), systemctl
# (ser2net / keepalived state in files, recorded), logger, id, sleep. Nothing reaches a stick or a network.
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-switch"
vm() { # vm <dir> [role: MASTER|BACKUP] [ser2net: 1|0] [peer takes over: yes|no] [peer gen] [my gen]
  local d=$1 role=${2:-MASTER} s=${3:-1} takes=${4:-yes} pg=${5:-20261112T001339Z} mg=${6-20261112T001339Z}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/state" "$d/run"; : > "$d/calls"; : > "$d/journal"
  echo "$s" > "$d/ser2net"; echo 1 > "$d/keepalived"; echo "$role 2026-11-12T00:00:00Z priority=110" > "$d/run/role"
  [ -z "$mg" ] || echo "{\"gen\": \"$mg\"}" > "$d/state/last-sync.json"
  echo "HELLO name=radio2 role=BACKUP serving=no gen=$pg dirty=no applying=no" > "$d/peer"; echo "$takes" > "$d/takes"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" sleep ':'
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  fake "$d/bin" systemctl "case \"\$1\" in
    is-active) u=\${*: -1}; [ \"\$(cat '$d/'\$u)\" = 1 ] && { [ \"\$2\" = --quiet ] || echo active; exit 0; }; [ \"\$2\" = --quiet ] || echo inactive; exit 3;;
    stop) $rec; [ -f '$d/nostop' ] && exit 1; echo 0 > '$d/keepalived'; echo 0 > '$d/ser2net'
          [ \"\$(cat '$d/takes')\" = yes ] && sed -i 's/role=BACKUP serving=no/role=MASTER serving=yes/' '$d/peer'; exit 0;;
    start) $rec; echo 1 > '$d/keepalived'; [ -e '$d/run/hold' ] && : > '$d/held-at-start'; exit 0;;
    *) $rec; exit 9;; esac"
  fake "$d/sync" zradio-sync "$rec; case \"\$1\" in peer-hello) [ -f '$d/peer-down' ] && exit 255; cat '$d/peer';; run) [ -f '$d/sync-fail' ] && { echo 'failed  step=apply'; exit 1; }; g=20261112T050000Z; echo \"{\\\"gen\\\": \\\"\$g\\\"}\" > '$d/state/last-sync.json'; sed -i \"s/gen=[^ ]*/gen=\$g/\" '$d/peer'; echo 'ok  gen='\$g;; esac"
}
sw() { local d=$1; shift
  PATH="$d/bin:$PATH" ZRADIO_SWITCH_SYNC="$d/sync/zradio-sync" ZRADIO_SWITCH_STATE="$d/state" ZRADIO_SWITCH_RUN="$d/run" ZRADIO_SWITCH_WAIT=2 bash "$TOOL" "$@" > "$d/out" 2>&1; RC=$?; }

echo "-- report mode on the active, the standby holds the last sync: WOULD lines, nothing changed"
vm "$T/r"; sw "$T/r"
check "exit 0, REPORT ONLY, no sync planned" bash -c '[ "$2" = 0 ] && grep -q "REPORT ONLY — nothing changed" "$1/out" && grep -q "the standby holds this VM.s last sync (20261112T001339Z): taken as it is" "$1/out" && ! grep -q "WOULD zradio-sync run" "$1/out"' _ "$T/r" "$RC"
check "nothing but the hello was called" eq "$(tr '\n' ';' < "$T/r/calls")" "zradio-sync peer-hello;"

echo "-- --run: keepalived stopped here, the standby says MASTER and serving, keepalived started here again"
vm "$T/w"; sw "$T/w" --run
check "exit 0" eq "$RC" 0
check "the calls in order: hello, stop keepalived, hello (the standby took it), start keepalived — no sync" eq "$(tr '\n' ';' < "$T/w/calls")" "zradio-sync peer-hello;systemctl stop keepalived;zradio-sync peer-hello;systemctl start keepalived;"
check "says how long the standby took" bash -c 'grep -qE "DONE  the standby says MASTER and serving [0-9.]+ s after the stop; keepalived runs here again" "$1/out"' _ "$T/w"
check "journal: event=switch result=ok with took_s" bash -c 'grep -qE "^-t zradio event=switch result=ok took_s=[0-9.]+ " "$1/journal"' _ "$T/w"

echo "-- the standby holds another set: one sync first, then the switch; --sync forces one"
vm "$T/s1" MASTER 1 yes 20261101T000000Z; sw "$T/s1" --run
check "exit 0; sync before the stop" bash -c '[ "$2" = 0 ] && [ "$(grep -oE "^(zradio-sync run --reason switch|systemctl stop keepalived)" "$1/calls" | tr "\n" ";")" = "zradio-sync run --reason switch;systemctl stop keepalived;" ]' _ "$T/s1" "$RC"
vm "$T/s2"; sw "$T/s2" --run --sync
check "--sync: a sync although the standby holds the last one" has "$T/s2/calls" "zradio-sync run --reason switch"
vm "$T/s3" MASTER 1 yes 20261101T000000Z; : > "$T/s3/sync-fail"; sw "$T/s3" --run
check "the sync fails: exit 1, keepalived never stopped (this VM still serves)" bash -c '[ "$2" = 1 ] && ! grep -q "systemctl stop" "$1/calls" && grep -q "no switch onto a copy that was not confirmed" "$1/out" && grep -q "event=switch result=failed step=sync" "$1/journal"' _ "$T/s3" "$RC"
vm "$T/s4" MASTER 1 yes 20261112T001339Z ""; sw "$T/s4"
check "no last-sync record here: a sync is planned" has "$T/s4/out" "WOULD zradio-sync run --reason switch"

echo "-- the standby does not take the role: keepalived started here again, exit 1"
vm "$T/n" MASTER 1 no; sw "$T/n" --run
check "exit 1, says so, keepalived running here again" bash -c '[ "$2" = 1 ] && grep -q "did not say MASTER and serving within 2 s" "$1/out" && [ "$(cat "$1/keepalived")" = 1 ] && grep -q "event=switch result=failed step=takeover" "$1/journal"' _ "$T/n" "$RC"

echo "-- refusals: not the active; a standby that does not answer, is dirty, or serves"
vm "$T/x1" BACKUP 0; sw "$T/x1" --run
check "on the standby: refused, nothing stopped" bash -c '[ "$2" = 1 ] && grep -q "FAIL  this VM is not the active" "$1/out" && ! grep -q "systemctl stop" "$1/calls"' _ "$T/x1" "$RC"
vm "$T/x2"; : > "$T/x2/peer-down"; sw "$T/x2" --run
check "the standby does not answer: no switch into the dark" bash -c '[ "$2" = 1 ] && grep -q "no switch into the dark" "$1/out" && ! grep -q "systemctl stop" "$1/calls"' _ "$T/x2" "$RC"
vm "$T/x3"; sed -i 's/dirty=no/dirty=yes/' "$T/x3/peer"; sw "$T/x3" --run
check "a dirty standby: refused" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the standby is not ready to take the role: HELLO .* dirty=yes" "$1/out" && ! grep -q "systemctl stop" "$1/calls"' _ "$T/x3" "$RC"
vm "$T/x4"; : > "$T/x4/nostop"; sw "$T/x4" --run
check "keepalived does not stop: exit 1, says this VM still serves" bash -c '[ "$2" = 1 ] && grep -q "systemctl stop keepalived failed — this VM still serves" "$1/out"' _ "$T/x4" "$RC"
OUT=$(bash "$TOOL" --help 2>&1); RC=$?
check "--help: exit 0, names the steps" bash -c '[ "$1" = 0 ] && printf "%s" "$2" | grep -q "zradio-switch \[--run\] \[--sync\]" && printf "%s" "$2" | grep -q "^#   3\. wait"' _ "$RC" "$OUT"
echo "-- --yield (asked for by a more advanced peer): no sync from the older copy; this VM is outdated afterwards"
vm "$T/y" MASTER 1 yes 20261101T000000Z 20261112T001339Z; sed -i 's/$/ term=5 used=yes zbfloor=7000000 wait=no/' "$T/y/peer"; echo "term=4 used=yes" > "$T/y/state/version"; sw "$T/y" --run --yield
check "exit 0; the standby does not hold this VM's last sync, yet no sync is run" bash -c '[ "$2" = 0 ] && ! grep -q "zradio-sync run" "$1/calls" && grep -q "OK    --yield" "$1/out"' _ "$T/y" "$RC"
check "keepalived stopped and started again; outdated holds the peer's term and counter floor" bash -c 'grep -q "^systemctl stop keepalived" "$1/calls" && grep -q "^systemctl start keepalived" "$1/calls" && [ "$(cat "$1/state/outdated")" = "term=5 zbfloor=7000000" ]' _ "$T/y"
check "this VM no longer claims to be the copy in use" eq "$(cat "$T/y/state/version")" "term=4 used=no"
check "…and it is HELD before keepalived runs here again: not one second as a standby that could take the radios back with the older copy" bash -c '[ -e "$1/run/hold" ] && [ -e "$1/held-at-start" ]' _ "$T/y"
vm "$T/y1" MASTER 1 no; sed -i 's/$/ term=5 used=yes zbfloor=7000000 wait=no/' "$T/y1/peer"; sw "$T/y1" --run --yield
check "--yield and the peer does not take the radios: exit 1, and this VM is neither outdated nor held (it serves again)" bash -c '[ "$2" = 1 ] && [ ! -e "$1/state/outdated" ] && [ ! -e "$1/run/hold" ]' _ "$T/y1" "$RC"
vm "$T/y2"; echo "term=4 used=yes" > "$T/y2/state/version"; sw "$T/y2" --run
check "an ordinary planned switch also drops 'used' (the role was given away knowingly), and marks nothing outdated, holds nothing" bash -c '[ "$(cat "$1/state/version")" = "term=4 used=no" ] && [ ! -e "$1/state/outdated" ] && [ ! -e "$1/run/hold" ]' _ "$T/y2"
vm "$T/y3"; sed -i 's/$/ wait=yes/' "$T/y3/peer"; sw "$T/y3" --run
check "a standby that is itself held back (wait=yes) is not ready: no switch" bash -c '[ "$2" = 1 ] && ! grep -q "stop keepalived" "$1/calls"' _ "$T/y3" "$RC"

finish
