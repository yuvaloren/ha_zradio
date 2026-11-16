#!/usr/bin/env bash
# t-vote.sh — the cluster's third vote, both ends, against fakes: vote/install.sh on the third machine (apt-get,
# docker, sshd and id are fakes that record their calls) and ./install.sh --third-vote on a node (the fake cluster of
# tests/fake-node.sh, plus fakes for ssh, apt-get, pvecm qdevice and the cluster's node list). Real: both scripts,
# the files they write, and a TCP listener that stands in for corosync-qnetd's port.
# The real programs (docker, sshd, corosync-qnetd, the certificate tools): tests/vote-real.sh.
. "$(dirname "$0")/lib.sh"
VOTE_TOOL="$KIT/vote/install.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"
KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfakefakefakefakefake+fake/fake== root@nodea"

# a listener that stands in for corosync-qnetd: something answers on a TCP port of this machine
python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16); print(s.getsockname()[1], flush=True)
while True: s.accept()[0].close()' > "$T/port" & LISTENER=$!
trap 'kill $LISTENER 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
OPEN=$(cat "$T/port"); CLOSED=1      # CLOSED: a port nothing listens on

# ============================================================================== the third machine: vote/install.sh
machine() { # machine <dir>: a machine with apt-get, docker and an SSH server, all fakes
  local d=$1 rec; rm -rf "$d"; mkdir -p "$d/bin" "$d/ssh"; : > "$d/calls"
  rec="printf '%s\n' \"\$(basename \$0) \$*\" | head -1 >> '$d/calls'"      # a call's first line: an argument may be a whole script
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" hostname 'echo nas'
  fake "$d/bin" ip 'echo "2: eth0    inet 192.0.2.9/24 brd 192.0.2.255 scope global eth0"'
  fake "$d/bin" apt-get "$rec; [ ! -f '$d/apt-fail' ] || exit 1; printf '#!/bin/sh\n' > '$d/bin/corosync-qnetd'; chmod +x '$d/bin/corosync-qnetd'"
  fake "$d/bin" sshd "[ \"\$1\" = -T ] && printf 'permitrootlogin %s\\npasswordauthentication yes\\n' \"\$(cat '$d/prl' 2>/dev/null || echo prohibit-password)\""
  fake "$d/bin" docker "$rec
    case \"\$1\" in
      info) [ ! -f '$d/docker-down' ];;
      inspect) case \"\$3\" in container) [ -f '$d/container' ];; image) cat '$d/image' 2>/dev/null;; esac;;      # an image: its recipe label
      images) [ ! -f '$d/image' ] || echo \"id-\$(cat '$d/image')\";;
      rm) [ \"\$3\" != zradio-vote ] || rm -f '$d/container';;
      run) if [ \"\$2\" = -d ]; then : > '$d/container'
           else printf '%s\n' \"\${*: -1}\" > '$d/image.sh'; [ ! -f '$d/build-fail' ] || { echo 'E: Unable to locate package corosync-qnetd'; exit 100; }; fi;;
      cp) cp \"\$2\" '$d/entrypoint.sh';;
      commit) printf '%s\n' \"\$*\" | sed -n 's/.*LABEL zradio.recipe=\([0-9]*\).*/\1/p' > '$d/image';;
      exec) [ ! -f '$d/container-dead' ];;
      logs) echo 'zradio-vote: the SSH server did not start';;
    esac"
}
vote() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VOTE_SSH_DIR="$d/ssh" ZRADIO_VOTE_QNETD_PORT="${QP:-$OPEN}" ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" "$@" > "$d/out" 2>&1 < /dev/null; RC=$?; }
vote_ask() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VOTE_ASK=1 ZRADIO_VOTE_SSH_DIR="$d/ssh" ZRADIO_VOTE_QNETD_PORT="${QP:-$OPEN}" ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" "$@" > "$d/out" 2>&1; RC=$?; }

echo "-- the third machine: what is refused before anything is looked at"
machine "$T/m0"
vote "$T/m0" --key "not a key"; check "a --key that is not a public key line: exit 2" eq "$RC" 2
vote "$T/m0" --key "$KEY
ssh-rsa AAAAsecond"; check "two lines as --key: exit 2" eq "$RC" 2
vote "$T/m0" --ssh-port 99999; check "--ssh-port that is no port: exit 2" eq "$RC" 2
vote "$T/m0" --ssh-port 5403; check "--ssh-port 5403 (the vote's own port): exit 2" eq "$RC" 2
check "none of these ran anything" bash -c '[ ! -s "$1/calls" ]' _ "$T/m0"

echo "-- the third machine with docker: the container, and a one-time password for the node"
machine "$T/d1"; QP=$CLOSED vote "$T/d1" --docker
check "report: exit 0, the image and the container said, with the two ports and the one-time password; nothing made or started" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && grep -q "WOULD the image zradio-vote made" "$1/out" && grep -q "WOULD the container zradio-vote started: .* the vote on TCP 5403, the container.s own SSH server on TCP 2222 for the container.s root (not this machine.s), with a one-time password until a node has left its key" "$1/out" && ! grep -qE "^docker (run|cp|commit|rm)" "$1/calls" && grep -q "the same line with --run" "$1/out"' _ "$T/d1" "$RC"
check "…no password is made up, or shown, before it is done" bash -c '! grep -qi "this password" "$1/out"' _ "$T/d1"
QP=$CLOSED ZRADIO_VOTE_PW=abcdefgh2345 vote "$T/d1" --docker --ssh-port 2022 --run
check "--run: exit 0; the image made, then the container started on the machine's own network with a restart policy, the volume, the password and the port; no key, no apt-get" bash -c '
  [ "$2" = 0 ] && b=$(grep -n "^docker commit " "$1/calls" | cut -d: -f1) && r=$(grep -n "^docker run -d " "$1/calls" | cut -d: -f1) && [ "$b" -lt "$r" ] &&
  grep -qx "docker run -d --name zradio-vote --restart unless-stopped --network host -v zradio-vote:/etc/corosync/qnetd -e ZRADIO_VOTE_PASSWORD=abcd-efgh-2345 -e ZRADIO_VOTE_SSH_PORT=2022 zradio-vote" "$1/calls" && ! grep -q "ZRADIO_VOTE_KEY" "$1/calls" && ! grep -q "^apt-get" "$1/calls"' _ "$T/d1" "$RC"
check "…it ends with the kit's install line for a node (this machine's one address and the SSH port in it) and the password, with how long it is good" bash -c 'grep -qxF "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)\" _ --third-vote 192.0.2.9 --third-vote-port 2022" "$1/out" && grep -q "It asks once for this password:    abcd-efgh-2345$" "$1/out" && grep -q "good until that node has left its key here, 30 minutes at most" "$1/out" && grep -q "the password of root INSIDE the container, on TCP 2022. Nothing of this machine was changed" "$1/out"' _ "$T/d1"
QP=$CLOSED vote "$T/d1" --docker --run
check "…a password of its own making: twelve letters and digits in three groups, none of them easy to misread, and another one each time" bash -c 'p=$(sed -n "s/.*this password: *//p" "$1/out") && [[ "$p" =~ ^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$ ]] && [ "$p" != abcd-efgh-2345 ] && grep -q -- "-e ZRADIO_VOTE_PASSWORD=$p " "$1/calls"' _ "$T/d1"
check "…the image is made with no builder (no docker build): a container of debian:13-slim that runs what --show image prints, the entrypoint of --show entrypoint copied in, a commit; that container removed" bash -c '
  ! grep -q "^docker build" "$1/calls" && [ "$(grep -E "^docker (run --name|cp|commit|rm -f zradio-vote-build)" "$1/calls" | sed -n "2,5p" | cut -d" " -f2 | tr "\n" " ")" = "run cp commit rm " ] &&
  grep -q "^docker run --name zradio-vote-build debian:13-slim sh -c " "$1/calls" && bash "$2" --show image | cmp -s - "$1/image.sh" && bash "$2" --show image | sh -n && bash "$2" --show entrypoint | cmp -s - "$1/entrypoint.sh" && [ -x "$1/entrypoint.sh" ]' _ "$T/d1" "$VOTE_TOOL"
check "…the commit: the volume, the entrypoint, no command left from the making, and a label that says what it was made from" bash -c 'grep -qE "^docker commit -c VOLUME /etc/corosync/qnetd -c ENTRYPOINT \[\"/entrypoint.sh\"\] -c CMD \[\] -c LABEL zradio.recipe=[0-9]+ zradio-vote-build zradio-vote$" "$1/calls"' _ "$T/d1"
check "…the entrypoint is sh that parses; a password is marked as used before the door opens; qnetd is what stays in front" bash -c 'e=$(bash "$1" --show entrypoint) && printf "%s\n" "$e" | sh -n && printf "%s\n" "$e" | grep -q -- "-o PerSourcePenalties=no" && u=$(printf "%s\n" "$e" | grep -n "> \"\$D/password-used\"" | cut -d: -f1) && c=$(printf "%s\n" "$e" | grep -n "chpasswd" | cut -d: -f1) && [ "$u" -lt "$c" ] && printf "%s\n" "$e" | grep -q "usermod -p .\*. root" && [ "$(printf "%s\n" "$e" | tail -1)" = "exec corosync-qnetd -f" ]' _ "$VOTE_TOOL"
check "…the container answers on both ports (asked inside it); the machine itself is untouched: no authorized_keys of its root" bash -c 'grep -q "OK    the container answers on TCP" "$1/out" && [ ! -e "$1/ssh/authorized_keys" ]' _ "$T/d1"
check "again (the container is there, the image is this version's): the container removed, then started; the image not made again; the volume is not removed" bash -c '[ "$(grep -E "^docker (rm|run|commit) " "$1/calls" | tail -2 | cut -d" " -f1-4)" = "docker rm -f zradio-vote
docker run -d --name" ] && [ "$(grep -c "^docker commit" "$1/calls")" = 1 ] && grep -q "OK    the image zradio-vote is here" "$1/out" && ! grep -q "volume" "$1/calls"' _ "$T/d1"
( trap '' PIPE; QP=$CLOSED vote "$T/d1" --docker --run )      # as under a CI runner or a service manager: a broken pipe is an error, not a signal
check "where a broken pipe is not a signal: a password all the same, and no error line from making it" bash -c '! grep -qi "broken pipe\|write error" "$1/out" && [[ "$(sed -n "s/.*this password: *//p" "$1/out")" =~ ^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$ ]]' _ "$T/d1"
echo 123 > "$T/d1/image"; QP=$CLOSED vote "$T/d1" --docker --run
check "an image of another version of the kit: made again, and the old image removed" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^docker commit" "$1/calls")" = 2 ] && grep -qx "docker rmi id-123" "$1/calls" && [ "$(cat "$1/image")" != 123 ]' _ "$T/d1" "$RC"
machine "$T/d1f"; : > "$T/d1f/build-fail"; QP=$CLOSED vote "$T/d1f" --docker --run
check "the packages do not install: FAIL with the last lines of what was tried, exit 1; no image, no container, no password; the making's container removed" bash -c '[ "$2" = 1 ] && grep -q "      | E: Unable to locate package corosync-qnetd" "$1/out" && grep -q "FAIL  the image zradio-vote made.*: failed" "$1/out" && ! grep -qE "^docker (commit|run -d)" "$1/calls" && ! grep -q "this password" "$1/out" && [ "$(grep "^docker " "$1/calls" | tail -1)" = "docker rm -f zradio-vote-build" ]' _ "$T/d1f" "$RC"
machine "$T/d1k"; QP=$CLOSED vote "$T/d1k" --docker --key "$KEY" --run
check "--key: that key instead of a password — in the container's start, in what is said, and no password anywhere" bash -c '[ "$2" = 0 ] && grep -q -- "-e ZRADIO_VOTE_KEY=$3 -e ZRADIO_VOTE_SSH_PORT=2222 zradio-vote" "$1/calls" && ! grep -q PASSWORD "$1/calls" && grep -q "by the node.s key only" "$1/out" && grep -q "It asks for no password: that node.s key is let in here" "$1/out" && ! grep -q "this password" "$1/out"' _ "$T/d1k" "$RC" "$KEY"
machine "$T/d1a"; QP=$CLOSED vote_ask "$T/d1a" --docker <<< "n"
check "asked, and the answer is no: nothing done" bash -c '[ "$2" = 0 ] && grep -q "Go ahead?" "$1/out" && grep -q "Nothing was changed" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d1a" "$RC"
QP=$CLOSED vote_ask "$T/d1a" --docker <<< "y"
check "…yes: done in the same run" bash -c '[ "$2" = 0 ] && grep -q "^docker run " "$1/calls" && grep -q "ready to vote" "$1/out"' _ "$T/d1a" "$RC"
machine "$T/d2"; vote "$T/d2" --docker --run
check "the vote's port is taken on this machine (no container of ours): FAIL, exit 1, nothing built" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine (another corosync-qnetd?)" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d2" "$RC"
machine "$T/d3"; QP=$CLOSED vote "$T/d3" --docker --ssh-port "$OPEN" --run
check "the SSH port is taken: FAIL naming --ssh-port, exit 1, nothing built" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine: another one with --ssh-port" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d3" "$RC"
machine "$T/d4"; : > "$T/d4/container-dead"; QP=$CLOSED vote "$T/d4" --docker --run
check "the container does not answer after its start: FAIL with its last lines, exit 1, no line for the node, no password shown" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the container does not answer .* Its last lines: zradio-vote: the SSH server did not start" "$1/out" && ! grep -q "ready to vote" "$1/out" && ! grep -q "this password" "$1/out"' _ "$T/d4" "$RC"
machine "$T/d5"; : > "$T/d5/docker-down"; vote "$T/d5" --docker --run
check "docker does not answer: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "docker does not answer here" "$1/out"' _ "$T/d5" "$RC"
machine "$T/d7"; fake "$T/d7/bin" ip 'printf "%s\n" "2: eth0    inet 192.0.2.9/24 scope global eth0" "3: eth1    inet 198.51.100.7/24 scope global eth1" "4: eth2    inet 169.254.3.4/16 scope global eth2" "5: docker0    inet 172.17.0.1/16 scope global docker0"'; QP=$CLOSED vote "$T/d7" --docker --run
check "a machine with two addresses of its own: the line leaves the address open, and the two are listed (not docker's, not a self-assigned one)" bash -c 'grep -q -- "_ --third-vote <this machine.s address> --third-vote-port 2222$" "$1/out" && grep -q "This machine.s addresses (the one the nodes reach): 192.0.2.9 198.51.100.7 $" "$1/out"' _ "$T/d7"
# a machine without apt-get (a NAS): only the fakes and a handful of plain tools on PATH
machine "$T/d6"; rm "$T/d6/bin/apt-get"; mkdir "$T/d6/base"
for c in bash sh env cat sed awk grep mkdir chmod mktemp rm sleep tr cp basename head tail cksum; do ln -s "$(command -v "$c")" "$T/d6/base/$c"; done
PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_QNETD_PORT=$CLOSED ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null; RC=$?
check "no apt-get here, docker there: the container, by itself" bash -c '[ "$2" = 0 ] && grep -q "in a container" "$1/out" && grep -q "WOULD the image" "$1/out"' _ "$T/d6" "$RC"
rm "$T/d6/base/cksum"; PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_QNETD_PORT=$CLOSED ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null
check "…and no cksum either: an image is never taken for this version's unseen, it is made" has "$T/d6/out" "WOULD the image"
rm "$T/d6/bin/docker"; PATH="$T/d6/bin:$T/d6/base" bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null; RC=$?
check "neither apt-get nor docker: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "neither apt-get nor docker" "$1/out"' _ "$T/d6" "$RC"

echo "-- the third machine with apt-get: Debian's package; the node gets in with root's password, or with --key"
machine "$T/m1"; echo yes > "$T/m1/prl"; vote "$T/m1"
check "root may log in with its password there: report, exit 0, the package said, no key asked for or written" bash -c '[ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && grep -q "OK    the SSH server here lets root in with its password" "$1/out" && grep -q "WOULD apt-get install corosync-qnetd" "$1/out" && ! grep -q "authorized_keys" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m1" "$RC"
vote "$T/m1" --run
check "--run: exit 0, the package installed with apt-get, no docker, no authorized_keys touched" bash -c '[ "$2" = 0 ] && grep -qx "apt-get -q -y install corosync-qnetd" "$1/calls" && ! grep -q "^docker" "$1/calls" && [ ! -e "$1/ssh/authorized_keys" ]' _ "$T/m1" "$RC"
check "…the vote's port answers: said; the line for a node without a port (SSH is on 22), and which password it asks for" bash -c 'grep -q "OK    corosync-qnetd answers on TCP" "$1/out" && grep -q -- "_ --third-vote 192.0.2.9$" "$1/out" && grep -q "It asks once for root.s password of this machine" "$1/out"' _ "$T/m1"
machine "$T/m2"; vote "$T/m2" --run
check "an SSH server that takes no password for root (Debian's default), and no --key: FAIL with both ways out, exit 1, nothing installed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the SSH server here does not let root in with a password (PermitRootLogin prohibit-password, PasswordAuthentication yes)" "$1/out" && grep -q "Either --docker" "$1/out" && grep -q "or --key with the node.s public key" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m2" "$RC"
vote "$T/m2" --key "$KEY" --run
check "…with --key: the package, and the key is root's one authorized key, the file for root only" bash -c '[ "$2" = 0 ] && grep -qx "apt-get -q -y install corosync-qnetd" "$1/calls" && [ "$(cat "$1/ssh/authorized_keys")" = "$3" ] && [ "$(stat -c %a "$1/ssh/authorized_keys")" = 600 ] && [ "$(stat -c %a "$1/ssh")" = 700 ] && grep -q "It asks for no password" "$1/out"' _ "$T/m2" "$RC" "$KEY"
: > "$T/m2/calls"; vote "$T/m2" --key "$KEY" --run
check "…again: nothing installed twice, the key not added twice" bash -c '[ "$2" = 0 ] && [ ! -s "$1/calls" ] && [ "$(grep -c . "$1/ssh/authorized_keys")" = 1 ] && grep -q "OK    corosync-qnetd is installed" "$1/out"' _ "$T/m2" "$RC"
machine "$T/m2b"; echo no > "$T/m2b/prl"; vote "$T/m2b" --key "$KEY" --run
check "an SSH server that does not let root in at all, with --key: FAIL, exit 1, nothing installed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the SSH server here does not let root in (PermitRootLogin no)" "$1/out" && grep -q "or use --docker" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m2b" "$RC"
machine "$T/m3"; echo yes > "$T/m3/prl"; QP=$CLOSED vote "$T/m3" --run
check "the package installed but nothing answers on the vote's port: FAIL, exit 1" bash -c '[ "$2" = 1 ] && grep -q "FAIL  nothing answers on TCP" "$1/out"' _ "$T/m3" "$RC"
machine "$T/m4"; : > "$T/m4/apt-fail"; vote "$T/m4" --key "$KEY" --run
check "apt-get fails: FAIL, exit 1, the key is not added" bash -c '[ "$2" = 1 ] && grep -q "FAIL  apt-get install corosync-qnetd.*failed" "$1/out" && [ ! -e "$1/ssh/authorized_keys" ]' _ "$T/m4" "$RC"

echo "-- the kit's own installer on a machine that is not a Proxmox node: the third vote, said first"
machine "$T/m8"; PATH="$T/m8/bin:$PATH" ZRADIO_VOTE_SSH_DIR="$T/m8/ssh" ZRADIO_VOTE_QNETD_PORT=$CLOSED bash "$TOOL" --docker > "$T/m8/out" 2>&1 < /dev/null; RC=$?
check "./install.sh there: it says this is no Proxmox node and what it installs instead, then the vote's own report; exit 0, nothing done" bash -c '[ "$2" = 0 ] && [ "$(head -1 "$1/out")" = "This machine is not a Proxmox node (no qm, no pvesh). What the kit installs on any other machine is a" ] && grep -q "^== the third vote on nas, in a container (report only" "$1/out" && grep -q "^REPORT ONLY" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/m8" "$RC"
PATH="$T/m8/bin:$PATH" ZRADIO_VOTE_ASK=1 ZRADIO_VOTE_WAIT=1 ZRADIO_VOTE_SSH_DIR="$T/m8/ssh" ZRADIO_VOTE_QNETD_PORT=$CLOSED bash "$TOOL" --docker > "$T/m8/out" 2>&1 <<< "y"; RC=$?
check "…on a terminal: one question, and after the y the vote is set up and the line and the password for a node are shown — nothing asked of a node first" bash -c '[ "$2" = 0 ] && [ "$(grep -c "\[y/N\]" "$1/out")" = 1 ] && grep -q "ready to vote" "$1/out" && grep -q "It asks once for this password" "$1/out" && grep -q "^docker run " "$1/calls"' _ "$T/m8" "$RC"
check "…--help there is still the installer's own help" bash -c 'PATH="$1/bin:$PATH" bash "$2" --help | grep -q "^#   --third-vote A.B.C.D"' _ "$T/m8" "$TOOL"

# ================================================================================ a node: ./install.sh --third-vote
cluster() { # cluster <dir>: the fake cluster, two nodes and two votes, no third vote; the vote's machine up (its vote and its
  # SSH port answer: the listener), this node's key not there yet
  local d=$1 rec; node "$d"; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  echo "2 2" > "$d/votes"; mkdir -p "$d/ssh"
  echo "$KEY" > "$d/ssh/id_rsa.pub"; echo "Ciphers aes128-ctr,aes256-ctr" > "$d/ssh/config"
  printf '%s\n' 'totem {' '  cluster_name: test' '  config_version: 2' '}' 'quorum {' '  provider: corosync_votequorum' '}' > "$d/pve/corosync.conf"
  echo '[{"type":"cluster","name":"test","nodes":2,"quorate":1},{"type":"node","name":"nodea","ip":"192.0.2.1","online":1,"local":1},{"type":"node","name":"nodeb","ip":"192.0.2.2","online":1,"local":0}]' > "$d/status.json"
  mv "$d/bin/pvesh" "$d/bin/pvesh.kit"
  fake "$d/bin" pvesh "case \"\$1 \$2\" in 'get /cluster/status') cat '$d/status.json';; *) exec '$d/bin/pvesh.kit' \"\$@\";; esac"
  fake "$d/bin" pvecm "case \"\$1 \$2\" in
    status\\ *) [ -f '$d/votes' ] || exit 1; read -r t q < '$d/votes'; printf 'Expected votes:   %s\\nTotal votes:      %s\\nQuorum:           %s\\n' \"\$t\" \"\$t\" \"\$q\";;
    'qdevice setup') $rec; echo 'INFO: initializing qnetd server'; [ ! -f '$d/setup-fail' ] || { echo 'QDevice certificate store already initialised, set force to delete!'; exit 255; }
      sed -i 's/^  provider: corosync_votequorum\$/&\\n  device {\\n    model: net\\n    votes: 1\\n    net {\\n      algorithm: ffsplit\\n      host: '\"\$3\"'\\n      tls: on\\n    }\\n  }/' '$d/pve/corosync.conf'
      [ -f '$d/no-vote' ] || echo '3 2' > '$d/votes';;
    *) $rec;;
  esac"
  fake "$d/bin" apt-get "$rec; printf '#!/bin/sh\n' > '$d/bin/corosync-qdevice-net-certutil'; chmod +x '$d/bin/corosync-qdevice-net-certutil'"
  fake "$d/bin" ssh-copy-id "$rec; echo 'Number of key(s) added: 1'; [ ! -f '$d/wrong-password' ] || { echo 'Permission denied, please try again.'; exit 1; }; : > '$d/keyed'"
  fake "$d/bin" ssh "$rec
    case \"\$*\" in
      *' -p 22 '*) echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; exit 255;;
      *StrictHostKeyChecking=accept-new*) [ -f '$d/keyed' ] && [ ! -f '$d/hostkey-changed' ] && [ ! -f '$d/no-qnetd' ] && echo \"\${*: -2:1} ssh-ed25519 AAAAhostkey\" >> '$d/ssh/known_hosts';;
      *'command -v corosync-qnetd-certutil'*) [ -f '$d/keyed' ] && [ ! -f '$d/no-qnetd' ];;
      *'command -v corosync-qdevice-net-certutil'*) [ -f '$d/qdevice-nodeb' ];;
      *'apt-get -q -y install corosync-qdevice'*) : > '$d/qdevice-nodeb';;
      *) [ ! -f '$d/no-node-ssh' ];;
    esac"
}
tv() { local d=$1; shift; export ZRADIO_VM_SSH_DIR="$d/ssh" ZRADIO_VM_QDEV_DB="$d/qdevice/net/nssdb" ZRADIO_VM_QNETD_PORT="${QP:-$OPEN}"; zvm "$d" "$@"; }
tv_ask() { local d=$1; shift; export ZRADIO_VM_SSH_DIR="$d/ssh" ZRADIO_VM_QDEV_DB="$d/qdevice/net/nssdb" ZRADIO_VM_QNETD_PORT="${QP:-$OPEN}"; ask "$d" "$@"; }
V=(--third-vote 127.0.0.1 --third-vote-port "$OPEN")      # the listener stands in for the machine's SSH port too

echo "-- a node: the vote's machine is not ready yet"
cluster "$T/n1"; QP=$CLOSED tv "$T/n1" "${V[@]}"
check "nothing answers on the vote's port: exit 0, said, nothing changed" bash -c '[ "$2" = 0 ] && grep -q "127.0.0.1 is not ready to vote: nothing answers there on TCP" "$1/out" && grep -q "^== nothing was changed ==" "$1/out"' _ "$T/n1" "$RC"
check "…the line for that machine: the kit's one install line, with nothing after it (no key of this node to carry over)" bash -c 'grep -qxF "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)\" _" "$1/out" && ! grep -q "ssh-rsa" "$1/out"' _ "$T/n1"
check "…no ssh config written, nothing installed, no key sent, no pvecm qdevice" bash -c '[ "$(cat "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ] && ! grep -qE "^(apt-get|pvecm|ssh-copy-id)" "$1/calls"' _ "$T/n1"
QP=$CLOSED tv "$T/n1" "${V[@]}" --run; check "…with --run: the same, and exit 1 (it was not done)" eq "$RC" 1
cluster "$T/n2"; tv "$T/n2" --third-vote 127.0.0.1
check "the vote answers but nothing does on the SSH port (22 here: the container's port was not given): said, with where the port is; exit 0" bash -c '[ "$2" = 0 ] && grep -q "is not ready to vote: its vote answers (TCP .*), but nothing answers on SSH port 22. The line that machine printed has the port (--third-vote-port N)" "$1/out" && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/n2" "$RC"

echo "-- a node: the vote's machine is up, and this node's key is not there yet"
cluster "$T/n3"; tv "$T/n3" "${V[@]}"
check "report: exit 0, REPORT ONLY; corosync-qdevice on both nodes, the ssh config entry, the key left there (the password asked once), pvecm — in that order" bash -c '
  [ "$2" = 0 ] && grep -q "^REPORT ONLY" "$1/out" && o=$(grep -n "WOULD" "$1/out") && l() { printf "%s\n" "$o" | grep -m1 -- "$1" | cut -d: -f1; } &&
  a=$(l "apt-get install corosync-qdevice on nodea") && b=$(l "apt-get install corosync-qdevice on nodeb (over the cluster.s SSH)") && c=$(l "an entry for 127.0.0.1 in .*/ssh/config, Port $3") && h=$(l "this node.s key left at 127.0.0.1 (ssh-copy-id): it asks ONCE for the password that machine printed") && p=$(l "pvecm qdevice setup 127.0.0.1") &&
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$h" ] && [ "$h" -lt "$p" ]' _ "$T/n3" "$RC" "$OPEN"
check "…the look at that machine records no host key (it is thrown away), and nothing was done: no apt-get, no key sent, no pvecm qdevice, the ssh config as it was" bash -c 'grep "command -v corosync-qnetd-certutil" "$1/calls" | grep -q "StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null .* -p $2 root@127.0.0.1" && [ ! -e "$1/ssh/known_hosts" ] && ! grep -qE "^(apt-get|pvecm|ssh-copy-id)" "$1/calls" && ! grep -q "apt-get -q -y install" "$1/calls" && [ "$(cat "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ]' _ "$T/n3" "$OPEN"
check "…no sticks looked for, no VM named: this is not a VM build" bash -c '! grep -qiE "stick|qm create|zradio1" "$1/out"' _ "$T/n3"
: > "$T/n3/calls"; tv "$T/n3" "${V[@]}" --run
check "--run: exit 0, done" bash -c '[ "$2" = 0 ] && grep -q "^== done: 127.0.0.1 casts this cluster.s third vote ==" "$1/out"' _ "$T/n3" "$RC"
check "…the calls in order: corosync-qdevice here, on the other node (Proxmox's own way there), ssh-copy-id, the login by key, then pvecm qdevice setup" bash -c '
  n() { grep -n -m1 -- "$1" "$2/calls" | cut -d: -f1; }
  a=$(n "^apt-get -q -y install corosync-qdevice" "$1") && b=$(n "^ssh -e none -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=nodeb root@192.0.2.2 -- DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice" "$1") &&
  c=$(n "^ssh-copy-id -i .*/ssh/id_rsa -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new root@127.0.0.1$" "$1") && h=$(n "^ssh -o BatchMode=yes .*StrictHostKeyChecking=accept-new .* root@127.0.0.1 command -v corosync-qnetd-certutil" "$1") && p=$(n "^pvecm qdevice setup 127.0.0.1$" "$1") &&
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$h" ] && [ "$h" -lt "$p" ]' _ "$T/n3"
check "…ssh-copy-id and the login after it go through the config (no -p on those calls), as pvecm will; the host key is recorded" bash -c '! grep -E "^ssh-copy-id|accept-new" "$1/calls" | grep -q -- " -p " && grep -q "^root@127.0.0.1 ssh-ed25519" "$1/ssh/known_hosts"' _ "$T/n3"
check "…root's ssh config: what was there, then one entry for the address with the port" bash -c '[ "$(head -1 "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ] && [ "$(grep -c "^Host " "$1/ssh/config")" = 1 ] && [ "$(grep -A1 "^Host 127.0.0.1$" "$1/ssh/config" | tail -1)" = "    Port $2" ]' _ "$T/n3" "$OPEN"
check "…ssh-copy-id's and pvecm's lines are shown, and the votes read back: the cluster keeps its quorum without one node" bash -c 'grep -q "      | Number of key(s) added: 1" "$1/out" && grep -q "      | INFO: initializing qnetd server" "$1/out" && grep -q "OK    the cluster keeps its quorum without one node now (3 votes, 2 needed)" "$1/out"' _ "$T/n3"
: > "$T/n3/calls"; tv "$T/n3" "${V[@]}" --run
check "again: the cluster has its third vote, named; exit 0, nothing run" bash -c '[ "$2" = 0 ] && grep -q "OK    this cluster has a third vote already (its machine: 127.0.0.1)" "$1/out" && grep -q "pvecm qdevice remove, then this again" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/n3" "$RC"
echo "2 2" > "$T/n3/votes"; tv "$T/n3" "${V[@]}"
check "…a third vote that is configured but does not vote: FAIL, exit 1" bash -c '[ "$2" = 1 ] && grep -q "FAIL  but it does NOT keep its quorum without one node now (2 vote(s), 2 needed)" "$1/out"' _ "$T/n3" "$RC"
check "…that machine saw ONE login that could fail in this run (its SSH server counts them against this node's address), and no bare connection to its SSH port" bash -c '[ "$(grep -c "UserKnownHostsFile=/dev/null" "$1/calls")" = 0 ]' _ "$T/n3"
cluster "$T/n3b"; tv "$T/n3b" "${V[@]}"
check "…a report: one such login" bash -c '[ "$(grep -c "UserKnownHostsFile=/dev/null" "$1/calls")" = 1 ]' _ "$T/n3b"
cluster "$T/n4"; tv_ask "$T/n4" "${V[@]}" <<< "y"
check "asked, yes: it is done in the same sitting" bash -c '[ "$2" = 0 ] && grep -q "Go ahead?" "$1/out" && grep -q "^ssh-copy-id" "$1/calls" && grep -qx "pvecm qdevice setup 127.0.0.1" "$1/calls"' _ "$T/n4" "$RC"
cluster "$T/n5"; : > "$T/n5/keyed"; : > "$T/n5/qdevice-nodeb"; printf '#!/bin/sh\n' > "$T/n5/bin/corosync-qdevice-net-certutil"; chmod +x "$T/n5/bin/corosync-qdevice-net-certutil"; tv "$T/n5" "${V[@]}" --run
check "this node's key is there already (that machine was given it, or an earlier run), corosync-qdevice on both nodes: no password asked, nothing installed, set up all the same" bash -c '[ "$2" = 0 ] && grep -q "lets root of this node in by key" "$1/out" && ! grep -q "^ssh-copy-id" "$1/calls" && ! grep -q "apt-get" "$1/calls" && grep -qx "pvecm qdevice setup 127.0.0.1" "$1/calls"' _ "$T/n5" "$RC"
cluster "$T/n6"; printf 'Host 127.0.0.1\n    Port %s\n' "$OPEN" >> "$T/n6/ssh/config"; tv "$T/n6" "${V[@]}" --run
check "the ssh config has the entry already: said, not written twice" bash -c '[ "$2" = 0 ] && grep -q "OK    .*/ssh/config has 127.0.0.1 on port" "$1/out" && [ "$(grep -c "^Host " "$1/ssh/config")" = 1 ]' _ "$T/n6" "$RC"

echo "-- a node: what is refused"
cluster "$T/r0"; : > "$T/r0/wrong-password"; tv "$T/r0" "${V[@]}" --run
check "a wrong or expired password: ssh-copy-id's lines shown, FAIL with how to get a new one (and the way without a terminal), exit 1, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "      | Permission denied, please try again." "$1/out" && grep -q "FAIL  ssh-copy-id to root@127.0.0.1 failed" "$1/out" && grep -q "the install line on that machine again gives a new one" "$1/out" && grep -q "its --key, with .*/ssh/id_rsa.pub" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r0" "$RC"
cluster "$T/r0b"; : > "$T/r0b/no-qnetd"; : > "$T/r0b/keyed"; tv "$T/r0b" "${V[@]}" --run
check "root gets in there but corosync-qnetd is not there (some other machine's SSH): FAIL, exit 1, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "FAIL  ssh to root@127.0.0.1 by key failed with the port from .*, or corosync-qnetd is not installed there" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r0b" "$RC"
cluster "$T/r1"; printf 'Host backup 127.0.0.1\n    Port 2200\n' >> "$T/r1/ssh/config"; tv "$T/r1" "${V[@]}" --run
check "the ssh config names the address with another port: FAIL, exit 1, the file untouched, no key sent, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*/ssh/config has an entry for 127.0.0.1 already, with port 2200" "$1/out" && [ "$(grep -c "^Host " "$1/ssh/config")" = 1 ] && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/r1" "$RC"
cluster "$T/r2"; sed -i 's/"name":"nodeb","ip":"192.0.2.2","online":1/"name":"nodeb","ip":"192.0.2.2","online":0/' "$T/r2/status.json"; tv "$T/r2" "${V[@]}" --run
check "a node is offline: FAIL (pvecm needs every node), exit 1, nothing changed" bash -c '[ "$2" = 1 ] && grep -q "FAIL  node nodeb is offline" "$1/out" && grep -q "nothing was changed" "$1/out" && ! grep -qE "^(apt-get|pvecm|ssh)" "$1/calls"' _ "$T/r2" "$RC"
cluster "$T/r3"; mkdir -p "$T/r3/qdevice/net/nssdb"; tv "$T/r3" "${V[@]}" --run
check "certificates of an earlier vote are still on the node: FAIL with what to remove, before pvecm would refuse halfway" bash -c '[ "$2" = 1 ] && grep -q "FAIL  certificates of an earlier third vote are still at .*/qdevice/net/nssdb" "$1/out" && grep -q "Remove .*/qdevice on each node" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r3" "$RC"
cluster "$T/r4"; rm "$T/r4/ssh/id_rsa.pub"; tv "$T/r4" "${V[@]}"
check "no id_rsa.pub (the key pvecm logs in with): FAIL, exit 1" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*/ssh/id_rsa.pub is missing" "$1/out"' _ "$T/r4" "$RC"
cluster "$T/r5"; echo '[{"type":"node","name":"nodea","ip":"192.0.2.1","online":1,"local":1},{"type":"node","name":"nodeb","ip":"192.0.2.2","online":1,"local":0},{"type":"node","name":"nodec","ip":"192.0.2.3","online":1,"local":0}]' > "$T/r5/status.json"; tv "$T/r5" "${V[@]}" --run
check "three nodes: nothing to do (Proxmox sets a third vote up for an even number only), exit 0, nothing run" bash -c '[ "$2" = 0 ] && grep -q "OK    this cluster has 3 node(s), an odd number" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/r5" "$RC"
cluster "$T/r6"; : > "$T/r6/no-node-ssh"; tv "$T/r6" "${V[@]}" --run
check "no SSH from this node to the other: FAIL, exit 1, no key sent, no pvecm qdevice (it would stop halfway)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  no SSH from this node to root@nodeb (192.0.2.2)" "$1/out" && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/r6" "$RC"
cluster "$T/r7"; : > "$T/r7/keyed"; : > "$T/r7/hostkey-changed"; tv "$T/r7" "${V[@]}" --run
check "the login by key through the config fails (a changed host key): FAIL with the ssh-keygen -R line for that address and port, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -qF "ssh-keygen -R '"'"'[127.0.0.1]:$3'"'"'" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r7" "$RC" "$OPEN"
cluster "$T/r8"; : > "$T/r8/setup-fail"; tv "$T/r8" "${V[@]}" --run
check "pvecm qdevice setup fails: its lines shown, FAIL with its exit code and how to start over, exit 1" bash -c '[ "$2" = 1 ] && grep -q "      | QDevice certificate store already initialised" "$1/out" && grep -q "FAIL  pvecm qdevice setup ended 255" "$1/out" && ! grep -q "^== done" "$1/out"' _ "$T/r8" "$RC"
cluster "$T/r9"; : > "$T/r9/no-vote"; tv "$T/r9" "${V[@]}" --run
check "set up, but the votes stay at two (the nodes do not reach the vote): FAIL, exit 1, where to look" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the vote is configured, but the cluster still has 2 vote(s) and needs 2" "$1/out" && grep -q "corosync-qdevice-tool -s" "$1/out"' _ "$T/r9" "$RC"
cluster "$T/r10"; tv "$T/r10" --third-vote nas.example --run
check "a name instead of an address: exit 2 (pvecm takes an address)" bash -c '[ "$2" = 2 ] && grep -q "the machine.s IPv4 address" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/r10" "$RC"
tv "$T/r10" --third-vote 127.0.0.1 --third-vote-port ssh; check "a port that is no port: exit 2" eq "$RC" 2
cluster "$T/r11"; rm "$T/r11/pve/corosync.conf"; tv "$T/r11" "${V[@]}"
check "a node in no cluster: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "this node is in no cluster" "$1/out"' _ "$T/r11" "$RC"

echo "-- the kit names no file that is not in it"
check "every host/*.sh, vote/*.sh and homeassistant/*.sh a script or a document names exists" bash -c 'cd "$1" && ! grep -rhoE "\b(host|vote|homeassistant)/[a-z0-9-]+\.sh\b" --include="*.sh" --include="*.md" --include="*.example" . | sort -u | while read -r f; do [ -f "$f" ] || echo "$f"; done | grep .' _ "$KIT"
finish
