#!/usr/bin/env bash
# t-gate.sh — guest/sbin/zradio-gate, one `step` at a time with the clock given (ZRADIO_GATE_NOW), against fakes:
# zradio-sync (peer-hello answers a line from a file or not at all; hello, peer-poke, peer-yield and self-raise are
# recorded, their answers set by knobs), systemctl (ser2net's state in a file), logger, id, sleep. And the real
# zradio-serve `check` on the files the gate writes. Nothing reaches a VM, a stick or keepalived: what keepalived does
# with a failing check is rehearsed separately (tests/rehearse-election.sh).
. "$(dirname "$0")/lib.sh"
TOOL="$KIT/guest/sbin/zradio-gate"; SERVE="$KIT/guest/sbin/zradio-serve"
vm() { # vm <dir> [act|observe] [priority] [ser2net 0|1]
  local d=$1 mode=${2:-act} prio=${3:-110} s=${4:-0}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/run" "$d/state" "$d/dev"; : > "$d/calls"; : > "$d/journal"; echo "$s" > "$d/ser2net"; : > "$d/dev/zw"; : > "$d/dev/zb"
  printf '%s\n' NAME=radio1 SELF=10.20.30.5 PEER=10.20.30.6 VIP=10.20.30.50/24 VRID=50 PRIORITY="$prio" ELECTION="$mode" > "$d/zradio.conf"
  printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "$d/radios.conf"
  echo "BACKUP x priority=$prio" > "$d/run/role"; echo "YIELDED" > "$d/yield-answer"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" sleep ':'
  fake "$d/bin" logger "echo \"\$*\" >> '$d/journal'"
  fake "$d/bin" systemctl "[ \"\$(cat '$d/ser2net')\" = 1 ]"
  fake "$d/bin" zradio-serve "[ ! -f '$d/unfit' ]"      # its check: fails while the knob file is there
  fake "$d/bin" zradio-sync "case \"\$1\" in
    peer-hello) [ -f '$d/peer' ] || exit 255; cat '$d/peer';;
    hello) echo \"HELLO name=radio1 gen=\$(cat '$d/mygen' 2>/dev/null || echo none)\";;
    peer-poke) echo \"zradio-sync \$*\" >> '$d/calls'; echo 'POKED the tick runs now';;
    peer-yield) echo \"zradio-sync \$*\" >> '$d/calls'; cat '$d/yield-answer';;
    self-raise) echo \"zradio-sync \$*\" >> '$d/calls'; [ ! -f '$d/raise-fail' ];;
    *) echo \"zradio-sync \$*\" >> '$d/calls';; esac"
}
peer() { # peer <dir> [field=value…]: what the other VM answers to hello; `peer <dir> -` = no answer
  local d=$1; shift; [ "${1:-}" = - ] && { rm -f "$d/peer"; return; }
  declare -A f=([role]=BACKUP [serving]=no [gen]=none [dirty]=no [applying]=no [term]=0 [used]=no [turn]=none [client]=no [outdated]=no [wait]=no [prio]=100 [zbfloor]=0 [last]=none)
  local kv; for kv in "$@"; do f[${kv%%=*}]=${kv#*=}; done
  echo "HELLO name=radio2 role=${f[role]} serving=${f[serving]} gen=${f[gen]} dirty=${f[dirty]} applying=${f[applying]} zwave=synced:zwave-800 zigbee=synced:znp term=${f[term]} used=${f[used]} turn=${f[turn]} client=${f[client]} outdated=${f[outdated]} wait=${f[wait]} prio=${f[prio]} zbfloor=${f[zbfloor]} last=${f[last]}" > "$d/peer"
}
gate() { local d=$1 t=$2; shift 2
  PATH="$d/bin:$PATH" ZRADIO_CONF="$d/zradio.conf" ZRADIO_RADIOS="$d/radios.conf" ZRADIO_GATE_SYNC="$d/bin/zradio-sync" ZRADIO_GATE_SERVE="$d/bin/zradio-serve" ZRADIO_GATE_RUN="$d/run" ZRADIO_GATE_STATE="$d/state" ZRADIO_GATE_NOW="$t" ZRADIO_GATE_ROLE_TRIES=2 bash "$TOOL" "${@:-step}" > "$d/out" 2>&1; RC=$?; }
chk() { local d=$1; PATH="$d/bin:$PATH" ZRADIO_RADIOS="$d/radios.conf" ZRADIO_SERVE_RUN="$d/run" ZRADIO_SERVE_STATE="$d/state" ZRADIO_SERVE_ZWAVE_TTY="$d/dev/zw" ZRADIO_SERVE_ZIGBEE_TTY="$d/dev/zb" bash "$SERVE" check; }
v() { echo "term=$2 used=$3" > "$1/state/version"; }
j() { grep -c "event=election result=$2 " "$1/journal"; }

echo "-- boot: nothing is claimed before the peer was asked"
vm "$T/a"; v "$T/a" 4 yes; gate "$T/a" 1000 arm
check "arm: boot-wait holds the time, the journal says wait" bash -c '[ "$(cat "$1/run/boot-wait")" = 1000 ] && grep -q "event=election result=wait boot" "$1/journal"' _ "$T/a"
chk "$T/a"; check "zradio-serve check fails while boot-wait is there (keepalived keeps this VM out)" eq "$?" 1
peer "$T/a" -; gate "$T/a" 1030
check "the peer does not answer, 30 s in: still waiting" bash -c '[ -e "$1/run/boot-wait" ] && [ ! -e "$1/run/gate-alone" ]' _ "$T/a"
gate "$T/a" 1060
check "60 s without an answer: this VM may claim, provisionally (gate-alone), and says so" bash -c '[ ! -e "$1/run/boot-wait" ] && [ -e "$1/run/gate-alone" ] && grep -q "result=alone the peer did not answer for 60 s" "$1/journal"' _ "$T/a"
chk "$T/a"; check "…and zradio-serve check passes" eq "$?" 0
vm "$T/a2"; v "$T/a2" 4 yes; gate "$T/a2" 1000 arm; touch -d '10 minutes ago' "$T/a2/run/boot-wait"; chk "$T/a2"
check "a boot-wait file older than five minutes (the gate died) no longer keeps the VM out" eq "$?" 0

echo "-- boot, the peer answers"
vm "$T/b"; v "$T/b" 4 yes; gate "$T/b" 1000 arm; peer "$T/b" serving=yes role=MASTER term=5 used=yes turn=confirmed client=yes zbfloor=7000000; gate "$T/b" 1003
check "the peer serves a higher term: outdated (its term and counter floor kept), held, boot-wait gone" bash -c '[ "$(cat "$1/state/outdated")" = "term=5 zbfloor=7000000" ] && [ -e "$1/run/hold" ] && [ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/gate-alone" ]' _ "$T/b"
chk "$T/b"; check "zradio-serve check fails on the hold: a blip of the serving VM does not hand the radios to this copy" eq "$?" 1
vm "$T/b2"; v "$T/b2" 4 no; gate "$T/b2" 1000 arm; peer "$T/b2" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes; gate "$T/b2" 1003
check "the peer serves the same term: an ordinary standby — no hold, not outdated" bash -c '[ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/hold" ] && [ ! -e "$1/state/outdated" ] && grep -q "result=standby" "$1/journal"' _ "$T/b2"
vm "$T/b3"; v "$T/b3" 4 yes; gate "$T/b3" 1000 arm; peer "$T/b3" term=4 used=no; gate "$T/b3" 1003
check "both up, neither serves, this VM was the one in use: it may claim at once (a confirmed turn: no gate-alone)" bash -c '[ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/gate-alone" ] && grep -q "result=claim" "$1/journal"' _ "$T/b3"
vm "$T/b4"; v "$T/b4" 4 no; gate "$T/b4" 1000 arm; peer "$T/b4" term=4 used=yes; gate "$T/b4" 1003
check "both up, the PEER was the one in use: this VM keeps waiting for it to claim" bash -c '[ -e "$1/run/boot-wait" ] && [ "$(wc -l < "$1/journal")" = 1 ]' _ "$T/b4"
peer "$T/b4" term=4 used=yes serving=yes role=MASTER turn=confirmed; gate "$T/b4" 1012
check "…and stands by once it serves" bash -c '[ ! -e "$1/run/boot-wait" ] && grep -q "result=standby" "$1/journal"' _ "$T/b4"
vm "$T/b5"; v "$T/b5" 4 no; gate "$T/b5" 1000 arm; peer "$T/b5" term=4 used=yes dirty=yes; gate "$T/b5" 1061
check "the peer was the one in use (same term) but cannot serve for 60 s: this VM claims as the standby of a failover — a confirmed turn, no gate-alone" bash -c '[ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/gate-alone" ] && [ ! -e "$1/state/outdated" ] && grep -q "result=claim the peer was the one in use" "$1/journal"' _ "$T/b5"
vm "$T/b5b"; v "$T/b5b" 4 yes; gate "$T/b5b" 1000 arm; peer "$T/b5b" term=5 used=yes dirty=yes zbfloor=7000000; gate "$T/b5b" 1030
check "the peer holds a HIGHER term and does not serve, 30 s in: still waiting for it" bash -c '[ -e "$1/run/boot-wait" ] && [ ! -s "$1/calls" ]' _ "$T/b5b"
gate "$T/b5b" 1061
check "…60 s: this VM is outdated, its counter raised above the peer's floor, and it may serve provisionally (no hold, no gate-alone)" bash -c '[ "$(cat "$1/state/outdated")" = "term=5 zbfloor=7000000" ] && [ "$(cat "$1/calls")" = "zradio-sync self-raise --above 7000000" ] && [ -e "$1/run/outdated-may-serve" ] && [ ! -e "$1/run/hold" ] && [ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/gate-alone" ] && grep -q "result=release the peer holds term 5" "$1/journal"' _ "$T/b5b"
chk "$T/b5b"; check "…zradio-serve check passes" eq "$?" 0
gate "$T/b5b" 1071; gate "$T/b5b" 1200
check "the peer keeps answering without serving: this VM stays released, no second raise" bash -c '[ ! -e "$1/run/hold" ] && [ -e "$1/run/outdated-may-serve" ] && [ "$(grep -c self-raise "$1/calls")" = 1 ] && ! grep -q held-again "$1/journal"' _ "$T/b5b"
peer "$T/b5b" term=5 used=yes serving=yes role=MASTER turn=confirmed; gate "$T/b5b" 1210
check "the peer serves after all, before this VM did: held again" bash -c '[ -e "$1/run/hold" ] && [ ! -e "$1/run/outdated-may-serve" ] && grep -q "result=held-again" "$1/journal"' _ "$T/b5b"
vm "$T/b6" act 110; v "$T/b6" 4 no; gate "$T/b6" 1000 arm; peer "$T/b6" term=4 used=no prio=100; gate "$T/b6" 1003
check "level versions: the higher PRIORITY claims" bash -c '[ ! -e "$1/run/boot-wait" ]' _ "$T/b6"
vm "$T/b7" act 100; v "$T/b7" 4 no; gate "$T/b7" 1000 arm; peer "$T/b7" term=4 used=no prio=110; gate "$T/b7" 1003
check "…and the lower one waits" bash -c '[ -e "$1/run/boot-wait" ]' _ "$T/b7"
vm "$T/b8" act 110 1; gate "$T/b8" 1000 arm
check "arm on a VM that serves (an upgrade): nothing armed" bash -c '[ ! -e "$1/run/boot-wait" ]' _ "$T/b8"

echo "-- preemption: a strictly older copy that serves — and nothing else"
vm "$T/p"; v "$T/p" 5 yes; gate "$T/p" 1000 arm; peer "$T/p" serving=yes role=MASTER term=4 used=yes turn=provisional client=yes zbfloor=6000000; gate "$T/p" 1003
check "the peer serves an older copy provisionally: counter raised above its floor first, then it is asked to hand over" eq "$(tr '\n' ';' < "$T/p/calls")" "zradio-sync self-raise --above 6000000;zradio-sync peer-yield;"
check "boot-wait is gone (this VM must be an eligible standby to be handed the radios); the journal: preempt, preempted" bash -c '[ ! -e "$1/run/boot-wait" ] && [ ! -e "$1/run/hold" ] && grep -q "result=preempt the peer serves term=4" "$1/journal" && grep -q "result=preempted" "$1/journal"' _ "$T/p"
check "the turn it takes back is a new term: term 6, used — written before the peer is asked (the peer marks itself outdated against it)" eq "$(cat "$T/p/state/version")" "term=6 used=yes"
check "…and the note of that term is gone once the peer handed over" bash -c '[ ! -e "$1/run/preempt-term" ]' _ "$T/p"
gate "$T/p" 1013
check "the next step does not ask again (one attempt in five minutes)" eq "$(grep -c peer-yield "$T/p/calls")" 1
vm "$T/p2"; v "$T/p2" 4 yes; gate "$T/p2" 1000 arm; peer "$T/p2" serving=yes role=MASTER term=4 used=no turn=confirmed client=yes zbfloor=5; gate "$T/p2" 1003
check "the peer serves the same term but was never the copy in use, and this VM was (it died hard and is back first, or a cut link healed): the radios are taken back, whatever the peer's turn" eq "$(tr '\n' ';' < "$T/p2/calls")" "zradio-sync self-raise --above 5;zradio-sync peer-yield;"
vm "$T/p3"; v "$T/p3" 4 no; peer "$T/p3" serving=yes role=MASTER term=4 used=no turn=confirmed client=no; gate "$T/p3" 2000
check "level versions (this VM released its claim at a planned switch or when it failed): the failover or switch STANDS" bash -c '[ ! -s "$1/calls" ] && ! grep -q preempt "$1/journal"' _ "$T/p3"
vm "$T/p3b"; v "$T/p3b" 4 no; peer "$T/p3b" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes last=x; echo x > "$T/p3b/mygen"; gate "$T/p3b" 2000
check "…and all the more once the peer is used" bash -c '[ ! -s "$1/calls" ]' _ "$T/p3b"
vm "$T/p4"; v "$T/p4" 5 yes; peer "$T/p4" serving=yes role=MASTER term=4 used=yes turn=provisional; : > "$T/p4/raise-fail"; gate "$T/p4" 2000
check "the counter cannot be raised: no handover is asked for, a loud line" bash -c '! grep -q peer-yield "$1/calls" && grep -q "result=loud preempt: this VM.s Zigbee counter could not be raised" "$1/journal"' _ "$T/p4"
vm "$T/p5"; v "$T/p5" 5 yes; peer "$T/p5" serving=yes role=MASTER term=4 used=yes turn=provisional; echo "FAULT x" > "$T/p5/run/role"; gate "$T/p5" 2000
check "keepalived here is not a standby yet: the peer is not asked to hand over into nothing" bash -c '! grep -q peer-yield "$1/calls" && grep -q "result=loud preempt: keepalived here did not reach BACKUP" "$1/journal"' _ "$T/p5"
check "…and no new term was written for a turn that was not taken" eq "$(cat "$T/p5/state/version")" "term=5 used=yes"
vm "$T/p6"; v "$T/p6" 5 yes; peer "$T/p6" serving=yes role=MASTER term=4 used=yes turn=provisional; echo "REFUSED observe mode" > "$T/p6/yield-answer"; gate "$T/p6" 2000; gate "$T/p6" 2100; gate "$T/p6" 2301
check "the peer refuses: said loudly; tried again only after five minutes" bash -c '[ "$(grep -c peer-yield "$1/calls")" = 2 ] && [ "$(grep -c "result=loud preempt: the peer did not hand over (REFUSED observe mode)" "$1/journal")" = 2 ]' _ "$T/p6"
check "…and the two attempts took ONE new term between them, not one each" eq "$(cat "$T/p6/state/version")" "term=6 used=yes"

echo "-- an outdated standby: held while the peer answers, released after the standard wait of silence"
vm "$T/o"; v "$T/o" 4 yes; echo "term=5 zbfloor=7000000" > "$T/o/state/outdated"; : > "$T/o/run/hold"; peer "$T/o" serving=yes role=MASTER term=5 used=yes turn=confirmed client=yes last=20261112T043000Z; echo 20261112T043000Z > "$T/o/mygen"; gate "$T/o" 3000
check "the peer answers: still held, nothing asked" bash -c '[ -e "$1/run/hold" ] && [ ! -e "$1/run/outdated-may-serve" ] && [ ! -s "$1/calls" ]' _ "$T/o"
peer "$T/o" -; gate "$T/o" 3010; gate "$T/o" 3050
check "the peer silent for 40 s: still held" bash -c '[ -e "$1/run/hold" ] && [ ! -s "$1/calls" ]' _ "$T/o"
gate "$T/o" 3070
check "silent for 60 s: the counter raised above the peer's floor, the hold lifted, said" bash -c '[ ! -e "$1/run/hold" ] && [ -e "$1/run/outdated-may-serve" ] && [ "$(cat "$1/calls")" = "zradio-sync self-raise --above 7000000" ] && grep -q "result=release the peer has been silent for 60 s" "$1/journal"' _ "$T/o"
chk "$T/o"; check "zradio-serve check passes now: keepalived lets this older copy serve" eq "$?" 0
gate "$T/o" 3080
check "no second raise at the next step" eq "$(grep -c self-raise "$T/o/calls")" 1
peer "$T/o" serving=yes role=MASTER term=5 used=yes turn=confirmed client=yes; gate "$T/o" 3090
check "the peer is back before this VM served: held again" bash -c '[ -e "$1/run/hold" ] && [ ! -e "$1/run/outdated-may-serve" ] && grep -q "result=held-again" "$1/journal"' _ "$T/o"
vm "$T/o2"; v "$T/o2" 4 no; peer "$T/o2" serving=yes role=MASTER term=6 used=yes turn=confirmed client=yes zbfloor=8; gate "$T/o2" 3000
check "a standby that finds the serving peer a term ahead (it missed a turn): outdated and held" bash -c '[ "$(cat "$1/state/outdated")" = "term=6 zbfloor=8" ] && [ -e "$1/run/hold" ]' _ "$T/o2"
vm "$T/o3"; v "$T/o3" 6 no; echo "term=6 zbfloor=8" > "$T/o3/state/outdated"; : > "$T/o3/run/hold"; peer "$T/o3" serving=yes role=MASTER term=6 used=yes turn=confirmed client=yes; gate "$T/o3" 3000
check "an outdated mark that no longer holds (the peer's term is not above this VM's): settled, the hold lifted" bash -c '[ ! -e "$1/state/outdated" ] && [ ! -e "$1/run/hold" ] && grep -q "result=settled" "$1/journal"' _ "$T/o3"
vm "$T/o4"; v "$T/o4" 4 yes; echo "term=5 zbfloor=7000000" > "$T/o4/state/outdated"; gate "$T/o4" 1000 arm; peer "$T/o4" -; gate "$T/o4" 1061
check "an outdated VM that boots alone: after the wait, its counter is raised before it may claim" bash -c '[ "$(cat "$1/calls")" = "zradio-sync self-raise --above 7000000" ] && [ ! -e "$1/run/boot-wait" ] && [ -e "$1/run/gate-alone" ]' _ "$T/o4"
gate "$T/o4" 1071; gate "$T/o4" 1200
check "…and it is raised once, not again while the peer stays silent" eq "$(grep -c self-raise "$T/o4/calls")" 1
vm "$T/o5"; v "$T/o5" 4 yes; echo "term=5 zbfloor=7000000" > "$T/o5/state/outdated"; : > "$T/o5/run/hold"; peer "$T/o5" term=5 used=yes dirty=yes zbfloor=7200000; gate "$T/o5" 3000; gate "$T/o5" 3040
check "the peer answers but does not serve, 40 s: still held" bash -c '[ -e "$1/run/hold" ] && [ ! -s "$1/calls" ]' _ "$T/o5"
gate "$T/o5" 3061
check "…for 60 s: released as after silence, the counter raised above the floor the peer names NOW" bash -c '[ ! -e "$1/run/hold" ] && [ "$(cat "$1/calls")" = "zradio-sync self-raise --above 7200000" ] && grep -q "result=release the peer has not served for 60 s" "$1/journal"' _ "$T/o5"
vm "$T/o6"; v "$T/o6" 4 no; : > "$T/o6/run/gate-alone"; peer "$T/o6" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes; gate "$T/o6" 3000
check "a standby that booted alone and hears the peer later: gate-alone is gone (its next turn is an ordinary failover, confirmed)" bash -c '[ ! -e "$1/run/gate-alone" ]' _ "$T/o6"

echo "-- a VM that was in use and cannot serve gives its claim up"
vm "$T/u"; v "$T/u" 4 yes; : > "$T/u/unfit"; peer "$T/u" term=4 used=no; gate "$T/u" 7000; gate "$T/u" 7030
check "its own health check fails (a stick is gone), 30 s: the claim stands" eq "$(cat "$T/u/state/version")" "term=4 used=yes"
gate "$T/u" 7061
check "…for the standard wait: used=no, said with the reason — the VM that serves can become the newest copy" bash -c '[ "$(cat "$1/state/version")" = "term=4 used=no" ] && grep -q "result=released this VM.s own health check has failed for 60 s" "$1/journal"' _ "$T/u"
vm "$T/u2"; v "$T/u2" 4 yes; : > "$T/u2/unfit"; peer "$T/u2" term=4 used=no; gate "$T/u2" 7000; rm -f "$T/u2/unfit"; gate "$T/u2" 7030; : > "$T/u2/unfit"; gate "$T/u2" 7065
check "a check that passes in between starts the count again" eq "$(cat "$T/u2/state/version")" "term=4 used=yes"
vm "$T/u3"; v "$T/u3" 4 yes; : > "$T/u3/unfit"; echo "term=5 zbfloor=1" > "$T/u3/state/outdated"; : > "$T/u3/run/hold"; peer "$T/u3" serving=yes role=MASTER term=5 used=yes turn=confirmed last=x; echo x > "$T/u3/mygen"; gate "$T/u3" 7000; gate "$T/u3" 7100
check "a VM the gate itself holds back is not 'unable to serve': nothing released on that account" bash -c '! grep -q "result=released" "$1/journal"' _ "$T/u3"

echo "-- the sync of a returning standby is asked for at once, not at the next 15-minute tick"
vm "$T/k"; v "$T/k" 4 no; echo 20261111T043000Z > "$T/k/mygen"; peer "$T/k" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes last=none; gate "$T/k" 5000; gate "$T/k" 5030
check "the peer has served for 30 s: not yet (Home Assistant is still reconnecting)" eq "$(grep -c peer-poke "$T/k/calls")" 0
gate "$T/k" 5060
check "after a minute: one poke, said" bash -c '[ "$(grep -c peer-poke "$1/calls")" = 1 ] && grep -q "result=poke the serving peer has not synced this VM in its turn" "$1/journal"' _ "$T/k"
gate "$T/k" 5120; gate "$T/k" 5300
check "not again within five minutes" eq "$(grep -c peer-poke "$T/k/calls")" 1
gate "$T/k" 5361
check "again after five minutes when the sync still has not landed" eq "$(grep -c peer-poke "$T/k/calls")" 2
vm "$T/k2"; v "$T/k2" 4 no; echo 20261112T043000Z > "$T/k2/mygen"; peer "$T/k2" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes last=20261112T043000Z; gate "$T/k2" 5000; gate "$T/k2" 5100
check "a standby that holds the peer's last sync asks for nothing" bash -c '[ ! -s "$1/calls" ]' _ "$T/k2"

echo "-- serving provisionally: confirmed once the peer answers and is not ahead"
vm "$T/s" act 110 1; v "$T/s" 4 yes; echo provisional > "$T/s/run/turn"; : > "$T/s/run/gate-alone"; peer "$T/s" -; gate "$T/s" 6000
check "no answer: still provisional" eq "$(cat "$T/s/run/turn")" provisional
peer "$T/s" term=4 used=no; gate "$T/s" 6010
check "the peer answers with an older or level copy: confirmed, gate-alone gone" bash -c '[ "$(cat "$1/run/turn")" = confirmed ] && [ ! -e "$1/run/gate-alone" ] && grep -q "result=confirmed" "$1/journal"' _ "$T/s"
vm "$T/s2" act 110 1; v "$T/s2" 4 yes; echo provisional > "$T/s2/run/turn"; peer "$T/s2" term=5 used=yes; gate "$T/s2" 6000
check "the peer answers and is ahead: this turn stays provisional (the peer's own gate takes the radios back)" bash -c '[ "$(cat "$1/run/turn")" = provisional ] && [ ! -s "$1/calls" ]' _ "$T/s2"
vm "$T/s3" act 110 1; v "$T/s3" 4 no; echo provisional > "$T/s3/run/turn"; echo "term=5 zbfloor=7" > "$T/s3/state/outdated"; peer "$T/s3" term=0 used=no; gate "$T/s3" 6000
check "an outdated VM serves provisionally and the peer comes back EMPTY (rebuilt: term 0): settled and confirmed — it is the newest copy there is" bash -c '[ "$(cat "$1/run/turn")" = confirmed ] && [ ! -e "$1/state/outdated" ] && grep -q "result=settled" "$1/journal" && grep -q "result=confirmed" "$1/journal"' _ "$T/s3"
vm "$T/s4" act 110 1; v "$T/s4" 4 no; echo confirmed > "$T/s4/run/turn"; peer "$T/s4" term=4 used=no; gate "$T/s4" 6000
check "serving a confirmed turn that was not used yet: the gate has the version looked at now (zradio-sync beat --quiet), not at the next minute" eq "$(cat "$T/s4/calls")" "zradio-sync beat --quiet"
vm "$T/s5" act 110 1; v "$T/s5" 4 yes; echo confirmed > "$T/s5/run/turn"; peer "$T/s5" term=4 used=no; gate "$T/s5" 6000
check "…and not once it is used" bash -c '[ ! -s "$1/calls" ]' _ "$T/s5"

echo "-- run: the loop's pace, and zradio-notify's kick"
slp() { fake "$1/bin" sleep "echo \"sleep \$*\" >> '$1/calls'; $2"; }      # sleeps are recorded (and may do something)
vm "$T/r1"; v "$T/r1" 4 yes; gate "$T/r1" 1000 arm; peer "$T/r1" -; slp "$T/r1" :; ZRADIO_GATE_ROUNDS=2 gate "$T/r1" 1010 run
check "waiting at boot: the next look after 3 s" eq "$(tr '\n' ';' < "$T/r1/calls")" "sleep 3;"
vm "$T/r2"; v "$T/r2" 4 no; echo x > "$T/r2/mygen"; peer "$T/r2" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes last=x; slp "$T/r2" :; ZRADIO_GATE_ROUNDS=2 ZRADIO_GATE_IDLE=4 gate "$T/r2" 2000 run
check "a standby with nothing pending: the usual pace (here 4 s), in one-second steps" eq "$(tr '\n' ';' < "$T/r2/calls")" "sleep 1;sleep 1;sleep 1;sleep 1;"
vm "$T/r3"; v "$T/r3" 4 no; echo x > "$T/r3/mygen"; peer "$T/r3" serving=yes role=MASTER term=4 used=yes turn=confirmed client=yes last=x
slp "$T/r3" "[ \"\$(grep -c '^sleep' '$T/r3/calls')\" != 2 ] || : > '$T/r3/run/gate-kick'"; ZRADIO_GATE_ROUNDS=2 ZRADIO_GATE_IDLE=30 gate "$T/r3" 2000 run
check "a role change (zradio-notify's gate-kick) ends the wait: the next look after 2 s, not 30" eq "$(grep -c '^sleep' "$T/r3/calls")" 2
check "…and the kick is taken (removed before the look it caused)" bash -c '[ ! -e "$1/run/gate-kick" ]' _ "$T/r3"
vm "$T/r4" act 110 1; v "$T/r4" 4 no; echo confirmed > "$T/r4/run/turn"; peer "$T/r4" term=4 used=no; slp "$T/r4" :; ZRADIO_GATE_ROUNDS=2 ZRADIO_GATE_IDLE=6 gate "$T/r4" 2000 run
check "serving a confirmed turn nobody uses yet: between two looks, the light version check every 3 s" eq "$(tr '\n' ';' < "$T/r4/calls")" "zradio-sync beat --quiet;sleep 3;zradio-sync beat --quiet;sleep 3;zradio-sync beat --quiet;zradio-sync beat --quiet;"

echo "-- ELECTION=observe (the default): every decision is said as would-…, nothing is held, nobody is asked"
vm "$T/obs" observe; v "$T/obs" 4 yes; gate "$T/obs" 1000 arm
check "arm: no boot-wait where zradio-serve looks; would-wait in the journal" bash -c '[ ! -e "$1/run/boot-wait" ] && [ -e "$1/run/observe/boot-wait" ] && grep -q "result=would-wait" "$1/journal"' _ "$T/obs"
chk "$T/obs"; check "zradio-serve check passes: the VM is not held back" eq "$?" 0
peer "$T/obs" serving=yes role=MASTER term=5 used=yes turn=confirmed client=yes; gate "$T/obs" 1003
check "the peer is a term ahead: would-outdated; no hold where zradio-serve looks" bash -c 'grep -q "result=would-outdated" "$1/journal" && [ ! -e "$1/run/hold" ]' _ "$T/obs"
chk "$T/obs"; check "…check still passes" eq "$?" 0
vm "$T/obs2" observe; v "$T/obs2" 5 yes; peer "$T/obs2" serving=yes role=MASTER term=4 used=yes turn=provisional zbfloor=6000000; gate "$T/obs2" 2000
check "a peer that would be preempted: would-preempt, no counter raised, nobody asked" bash -c 'grep -q "result=would-preempt" "$1/journal" && [ ! -s "$1/calls" ]' _ "$T/obs2"
vm "$T/obs3" observe; v "$T/obs3" 4 yes; echo "term=5 zbfloor=7" > "$T/obs3/state/outdated"; peer "$T/obs3" -; gate "$T/obs3" 3000; gate "$T/obs3" 3061
check "an outdated standby whose peer falls silent: would-release, no counter raised" bash -c 'grep -q "result=would-release" "$1/journal" && grep -q "result=would-raise" "$1/journal" && [ ! -s "$1/calls" ]' _ "$T/obs3"
vm "$T/obs4" observe; v "$T/obs4" 4 no; gate "$T/obs4" 1000 arm; echo 1 > "$T/obs4/ser2net"; peer "$T/obs4" -; gate "$T/obs4" 1004; gate "$T/obs4" 1010
check "observe: the VM serves 4 s after boot, where act mode would still be asking the peer: would-provisional, said once, noted for the peer" bash -c '[ "$(grep -c "result=would-provisional" "$1/journal")" = 1 ] && [ "$(cat "$1/run/observe/turn")" = provisional ] && [ ! -e "$1/run/turn" ]' _ "$T/obs4"
gate "$T/obs4" 1061
check "…the question is asked to the end although it serves: would-alone after the wait" bash -c 'grep -q "result=would-alone" "$1/journal" && [ ! -e "$1/run/observe/boot-wait" ]' _ "$T/obs4"
peer "$T/obs4" term=4 used=no; gate "$T/obs4" 1100
check "…and when the peer answers and is not ahead: would-confirmed, the note is gone" bash -c 'grep -q "result=would-confirmed" "$1/journal" && [ ! -e "$1/run/observe/turn" ] && [ ! -e "$1/run/observe/gate-alone" ]' _ "$T/obs4"
vm "$T/obs5" observe; v "$T/obs5" 5 yes; peer "$T/obs5" serving=yes role=MASTER term=4 used=yes turn=confirmed zbfloor=6000000; gate "$T/obs5" 2000
check "observe on both: the peer serves and this VM holds the newer networks: would-preempt, nobody asked" bash -c 'grep -q "result=would-preempt .*in act mode the radios would be here" "$1/journal" && [ ! -s "$1/calls" ]' _ "$T/obs5"
vm "$T/obs6" observe 110 1; v "$T/obs6" 4 yes; peer "$T/obs6" term=4 used=no; gate "$T/obs6" 2000
check "observe, serving, nothing in doubt: no would- line at all" bash -c '! grep -q "would-" "$1/journal"' _ "$T/obs6"
gate "$T/obs" 1 status
check "status names the mode and the version" has "$T/obs/out" "election: observe (standard wait 60 s); this VM: term 4, used yes"
vm "$T/bad2"; echo "ELECTION_WAIT=10" >> "$T/bad2/zradio.conf"; gate "$T/bad2" 1
check "ELECTION_WAIT below 20 s (less than a VM needs from its claim to serving): refused" bash -c '[ "$2" = 2 ] && grep -q "ELECTION_WAIT .10.: 20-600 seconds" "$1/out"' _ "$T/bad2" "$RC"
vm "$T/bad"; echo "ELECTION=maybe" >> "$T/bad/zradio.conf"; gate "$T/bad" 1
check "ELECTION with another word: refused (exit 2)" bash -c '[ "$2" = 2 ] && grep -q "ELECTION .maybe.: observe or act" "$1/out"' _ "$T/bad" "$RC"
check "--help names the rule for preemption" bash -c 'bash "$1" --help | grep -q "A serving peer is preempted when its version is strictly lower"' _ "$TOOL"
finish
