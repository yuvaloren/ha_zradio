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
HOSTKEY=AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKeyFakeHostKey12      # the vote machine's SSH host key (ed25519, its base64 part)

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
  fake "$d/bin" sshd "[ \"\$1\" = -T ] && printf 'port %s\\npermitrootlogin %s\\npasswordauthentication yes\\n' \"\$(cat '$d/sshport' 2>/dev/null || echo 22)\" \"\$(cat '$d/prl' 2>/dev/null || echo prohibit-password)\""
  fake "$d/bin" docker "$rec
    case \"\$1\" in
      info) [ ! -f '$d/docker-down' ];;
      pull) [ ! -f '$d/pull-fail' ] || exit 1; cat '$d/registry' 2>/dev/null > '$d/base-id' || echo sha256:base1 > '$d/base-id';;      # the base, as the registry has it now
      inspect) case \"\$3 \$*\" in container*RestartCount*) [ -f '$d/container-dead' ] && echo 'true 3' || echo 'true 0';; container*) [ -f '$d/container' ];; image*'{{.Id}}'*) cat '$d/base-id' 2>/dev/null;; image*zradio.base*) cat '$d/image-base' 2>/dev/null;; image*) cat '$d/image' 2>/dev/null;; esac;;      # an image: the base's id, or ours' recipe label
      images) [ ! -f '$d/image' ] || echo \"id-\$(cat '$d/image')\";;
      rm) [ \"\$3\" != zradio-vote ] || rm -f '$d/container';;
      run) if [ \"\$2\" = -d ]; then : > '$d/container'; [ -z \"\${ZRADIO_VOTE_PASSWORD:-}\" ] || echo \"env ZRADIO_VOTE_PASSWORD=\$ZRADIO_VOTE_PASSWORD\" >> '$d/calls'; [ -z \"\${ZRADIO_VOTE_KEY:-}\" ] || echo \"env ZRADIO_VOTE_KEY=\$ZRADIO_VOTE_KEY\" >> '$d/calls'
           else printf '%s\n' \"\${*: -1}\" > '$d/image.sh'; [ -f '$d/base-id' ] || echo sha256:base1 > '$d/base-id'; [ ! -f '$d/build-fail' ] || { echo 'E: Unable to locate package corosync-qnetd'; exit 100; }; fi;;
      cp) cp \"\$2\" '$d/entrypoint.sh';;
      commit) printf '%s\n' \"\$*\" | sed -n 's/.*LABEL zradio.recipe=\([0-9]*\).*/\1/p' > '$d/image'; printf '%s\n' \"\$*\" | sed -n 's/.*LABEL zradio.base=\([a-z0-9:]*\).*/\1/p' > '$d/image-base';;
      exec) case \"\$*\" in *ssh_host_ed25519_key.pub*) echo 'ssh-ed25519 $HOSTKEY root@zradio-vote';; *cmdline*) cat '$d/procs' 2>/dev/null;; *) [ ! -f '$d/container-dead' ] && [ ! -f '$d/container-slow' ];; esac;;      # procs: the container's command lines
      logs) echo 'zradio-vote: the SSH server did not start';;
    esac"
}
vote() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VOTE_HOSTKEY_FILE="$d/ssh_host_ed25519_key.pub" ZRADIO_VOTE_SSH_DIR="$d/ssh" ZRADIO_VOTE_QNETD_PORT="${QP:-$OPEN}" ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" "$@" > "$d/out" 2>&1 < /dev/null; RC=$?; }
vote_ask() { local d=$1; shift; PATH="$d/bin:$PATH" ZRADIO_VOTE_HOSTKEY_FILE="$d/ssh_host_ed25519_key.pub" ZRADIO_VOTE_ASK=1 ZRADIO_VOTE_SSH_DIR="$d/ssh" ZRADIO_VOTE_QNETD_PORT="${QP:-$OPEN}" ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" "$@" > "$d/out" 2>&1; RC=$?; }

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
check "…and the registry is not asked for Debian's base image: a report downloads nothing" bash -c '! grep -q "^docker pull" "$1/calls"' _ "$T/d1"
QP=$CLOSED ZRADIO_VOTE_PW=abcdefgh2345 vote "$T/d1" --docker --ssh-port 2022 --run
check "--run: Debian's base image is asked for at the registry before the image is made from it (not whatever debian:13-slim this machine happens to hold)" bash -c 'p=$(grep -n -m1 "^docker pull debian:13-slim$" "$1/calls" | cut -d: -f1) && r=$(grep -n -m1 "^docker run --name zradio-vote-build debian:13-slim " "$1/calls" | cut -d: -f1) && [ "$p" -lt "$r" ]' _ "$T/d1"
check "--run: exit 0; the image made, then the container started on the machine's own network with a restart policy, the volume, the password and the port; no key, no apt-get" bash -c '
  [ "$2" = 0 ] && b=$(grep -n "^docker commit " "$1/calls" | cut -d: -f1) && r=$(grep -n "^docker run -d " "$1/calls" | cut -d: -f1) && [ "$b" -lt "$r" ] &&
  grep -qx "docker run -d --name zradio-vote --restart unless-stopped --network host --cap-drop NET_RAW --security-opt no-new-privileges -v zradio-vote:/etc/corosync/qnetd -e ZRADIO_VOTE_PASSWORD -e ZRADIO_VOTE_RUN -e ZRADIO_VOTE_SSH_PORT=2022 zradio-vote" "$1/calls" && grep -qx "env ZRADIO_VOTE_PASSWORD=abcd-efgh-2345" "$1/calls" && ! grep -q "ZRADIO_VOTE_KEY" "$1/calls" && ! grep -q "^apt-get" "$1/calls"' _ "$T/d1" "$RC"
check "…the password reaches the container in its environment, by name: it is on no command line (every user of the machine can read those)" bash -c '! grep "^docker " "$1/calls" | grep -q "abcd-efgh-2345"' _ "$T/d1"
check "…it ends with the kit's install line for a node (this machine's one address and the SSH port in it) and the password, with how long it is good" bash -c 'grep -qxF "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)\" _ --third-vote 192.0.2.9 --third-vote-port 2022 --third-vote-hostkey $2" "$1/out" && grep -q "The long word at its end is this container.s SSH host key: the node talks to nobody else" "$1/out" && grep -q "it closes two minutes after a node has set the vote up, an hour" "$1/out" && grep -q "It asks once for this password:    abcd-efgh-2345$" "$1/out" && grep -q "good until that node has left its key here, 30 minutes at most" "$1/out" && grep -q "the password of root INSIDE the container, on TCP 2022. Nothing of this machine was changed" "$1/out"' _ "$T/d1" "$HOSTKEY"
QP=$CLOSED vote "$T/d1" --docker --run
check "…a password of its own making: twelve letters and digits in three groups, none of them easy to misread, and another one each time" bash -c 'p=$(sed -n "s/.*this password: *//p" "$1/out") && [[ "$p" =~ ^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$ ]] && [ "$p" != abcd-efgh-2345 ] && grep -qx "env ZRADIO_VOTE_PASSWORD=$p" "$1/calls"' _ "$T/d1"
check "…the image is made with no builder (no docker build): a container of debian:13-slim that runs what --show image prints, the entrypoint of --show entrypoint copied in, a commit; that container removed" bash -c '
  ! grep -q "^docker build" "$1/calls" && [ "$(grep -E "^docker (run --name|cp|commit|rm -f zradio-vote-build)" "$1/calls" | sed -n "2,5p" | cut -d" " -f2 | tr "\n" " ")" = "run cp commit rm " ] &&
  grep -q "^docker run --name zradio-vote-build debian:13-slim sh -c " "$1/calls" && bash "$2" --show image | cmp -s - "$1/image.sh" && bash "$2" --show image | sh -n && bash "$2" --show entrypoint | cmp -s - "$1/entrypoint.sh" && [ -x "$1/entrypoint.sh" ]' _ "$T/d1" "$VOTE_TOOL"
check "…the commit: the volume, the entrypoint, no command left from the making, and a label that says what it was made from" bash -c 'grep -qE "^docker commit -c VOLUME /etc/corosync/qnetd -c ENTRYPOINT \[\"/entrypoint.sh\"\] -c CMD \[\] -c LABEL zradio.recipe=[0-9]+ -c LABEL zradio.base=sha256:base1 zradio-vote-build zradio-vote$" "$1/calls"' _ "$T/d1"
# (the entrypoint is only read here: that it parses, and the order of its lines. What it does when it runs — the
# password good once, dead after its time and after a restart, the SSH server closing — is tried in tests/vote-real.sh)
check "…the entrypoint is sh that parses; a password is marked as used before the door opens; qnetd is what stays in front" bash -c 'e=$(bash "$1" --show entrypoint) && printf "%s\n" "$e" | sh -n && printf "%s\n" "$e" | grep -q -- "-o PerSourcePenalties=no" && u=$(printf "%s\n" "$e" | grep -n "> \"\$D/password-used\"" | cut -d: -f1) && c=$(printf "%s\n" "$e" | grep -n "chpasswd" | cut -d: -f1) && [ "$u" -lt "$c" ] && printf "%s\n" "$e" | grep -q "usermod -p .\*. root" && [ "$(printf "%s\n" "$e" | tail -1)" = "exec corosync-qnetd -f" ]' _ "$VOTE_TOOL"
check "…the container answers on both ports, and where that was asked is said (on this machine itself: whether a node reaches them is the node's check); the machine itself is untouched: no authorized_keys of its root" bash -c 'grep -q "OK    the container answers on TCP 5403 (the vote) and TCP 2222 (SSH), asked on this machine itself. Whether a node reaches them (a firewall here?) is checked by the line below, on the node" "$1/out" && [ ! -e "$1/ssh/authorized_keys" ]' _ "$T/d1"
check "again (the container is there, the image is this version's): the container removed, then started; the image not made again; the volume is not removed" bash -c '[ "$(grep -E "^docker (rm|run|commit) " "$1/calls" | tail -2 | cut -d" " -f1-4)" = "docker rm -f zradio-vote
docker run -d --name" ] && [ "$(grep -c "^docker commit" "$1/calls")" = 1 ] && grep -q "OK    the image zradio-vote is here" "$1/out" && ! grep -q "volume" "$1/calls"' _ "$T/d1"
( trap '' PIPE; QP=$CLOSED vote "$T/d1" --docker --run )      # as under a CI runner or a service manager: a broken pipe is an error, not a signal
check "where a broken pipe is not a signal: a password all the same, and no error line from making it" bash -c '! grep -qi "broken pipe\|write error" "$1/out" && [[ "$(sed -n "s/.*this password: *//p" "$1/out")" =~ ^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$ ]]' _ "$T/d1"
echo 123 > "$T/d1/image"; QP=$CLOSED vote "$T/d1" --docker --run
check "an image of another version of the kit: made again, and the old image removed" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^docker commit" "$1/calls")" = 2 ] && grep -qx "docker rmi id-123" "$1/calls" && [ "$(cat "$1/image")" != 123 ]' _ "$T/d1" "$RC"
echo sha256:base2 > "$T/d1/registry"; QP=$CLOSED vote "$T/d1" --docker --run
check "Debian has a newer base image by now, the kit is the same: the image is made again, from that one (its packages are as old as its base)" bash -c '[ "$2" = 0 ] && [ "$(grep -c "^docker commit" "$1/calls")" = 3 ] && [ "$(cat "$1/base-id")" = sha256:base2 ]' _ "$T/d1" "$RC"
: > "$T/d1/pull-fail"; QP=$CLOSED vote "$T/d1" --docker --run
check "…the registry does not answer and the base image is here: said, and it goes on with the image that is here" bash -c '[ "$2" = 0 ] && grep -q "NOTE  the registry was not reached for a newer debian:13-slim" "$1/out" && grep -q "OK    the image zradio-vote is here" "$1/out" && [ "$(grep -c "^docker commit" "$1/calls")" = 3 ]' _ "$T/d1" "$RC"
ZRADIO_VOTE_PW_S=20 ZRADIO_VOTE_OPEN_S=600 QP=$CLOSED vote "$T/d1" --docker --run
check "the tests' shorter times (ZRADIO_VOTE_OPEN_S, ZRADIO_VOTE_PW_S) reach the container by name; without them it gets none" bash -c 'grep "^docker run -d " "$1/calls" | tail -n 1 | grep -q -- " -e ZRADIO_VOTE_SSH_PORT=2222 -e ZRADIO_VOTE_OPEN_S -e ZRADIO_VOTE_PW_S zradio-vote$" && [ "$(grep -c "^docker run -d .*_S " "$1/calls")" = 1 ]' _ "$T/d1"
machine "$T/d1f"; : > "$T/d1f/build-fail"; QP=$CLOSED vote "$T/d1f" --docker --run
check "the packages do not install: FAIL with the last lines of what was tried, exit 1; no image, no container, no password; the making's container removed" bash -c '[ "$2" = 1 ] && grep -q "      | E: Unable to locate package corosync-qnetd" "$1/out" && grep -q "FAIL  the image zradio-vote made.*: failed" "$1/out" && ! grep -qE "^docker (commit|run -d)" "$1/calls" && ! grep -q "this password" "$1/out" && [ "$(grep "^docker " "$1/calls" | tail -1)" = "docker rm -f zradio-vote-build" ]' _ "$T/d1f" "$RC"
machine "$T/d1k"; QP=$CLOSED vote "$T/d1k" --docker --key "$KEY" --run
check "--key: that key instead of a password — in the container's start, in what is said, and no password anywhere" bash -c '[ "$2" = 0 ] && grep -q -- "-e ZRADIO_VOTE_KEY -e ZRADIO_VOTE_RUN -e ZRADIO_VOTE_SSH_PORT=2222 zradio-vote" "$1/calls" && grep -qxF "env ZRADIO_VOTE_KEY=$3" "$1/calls" && ! grep -q PASSWORD "$1/calls" && grep -q "by the node.s key only" "$1/out" && grep -q "It asks for no password: that node.s key is let in here" "$1/out" && ! grep -q "this password" "$1/out"' _ "$T/d1k" "$RC" "$KEY"
machine "$T/d1a"; QP=$CLOSED vote_ask "$T/d1a" --docker <<< "n"
check "asked, and the answer is no: nothing done" bash -c '[ "$2" = 0 ] && grep -q "Go ahead?" "$1/out" && grep -q "Nothing was changed" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d1a" "$RC"
QP=$CLOSED vote_ask "$T/d1a" --docker <<< "y"
check "…yes: done in the same run" bash -c '[ "$2" = 0 ] && grep -q "^docker run " "$1/calls" && grep -q "ready to vote" "$1/out"' _ "$T/d1a" "$RC"
machine "$T/d2"; vote "$T/d2" --docker --run
check "the vote's port is taken on this machine (no container of ours): FAIL, exit 1, nothing built" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine (another corosync-qnetd?)" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d2" "$RC"
machine "$T/d3"; QP=$CLOSED vote "$T/d3" --docker --ssh-port "$OPEN" --run
check "the SSH port is taken: FAIL naming --ssh-port, exit 1, nothing built" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine: another one with --ssh-port" "$1/out" && ! grep -qE "^docker (run|commit)" "$1/calls"' _ "$T/d3" "$RC"
machine "$T/d3b"; : > "$T/d3b/container"; echo "/usr/sbin/sshd -D -e -p 2222 -h /etc/corosync/qnetd/ssh_host_ed25519_key corosync-qnetd -f" > "$T/d3b/procs"; QP=$CLOSED vote "$T/d3b" --docker --ssh-port "$OPEN" --run
check "again, with another --ssh-port than the container that is here has, and that port is taken: FAIL naming --ssh-port, exit 1; the container that is here is not removed, nothing is made" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine (not by the container zradio-vote that is here): another one with --ssh-port" "$1/out" && grep -q "The container zradio-vote that is here was not touched" "$1/out" && [ -f "$1/container" ] && ! grep -qE "^docker (rm|run|commit|pull)" "$1/calls"' _ "$T/d3b" "$RC"
echo "corosync-qnetd -f" > "$T/d3b/procs"; QP=$CLOSED vote "$T/d3b" --docker --ssh-port "$OPEN" --run
check "…the same port as before, but the container's SSH server closed long ago and something else listens there now: the same FAIL" bash -c '[ "$2" = 1 ] && grep -q "FAIL  TCP port .* is in use on this machine (not by the container zradio-vote that is here)" "$1/out" && [ -f "$1/container" ]' _ "$T/d3b" "$RC"
echo "sshd: /usr/sbin/sshd -D -e -p $OPEN -h /etc/corosync/qnetd/ssh_host_ed25519_key [listener] 0 of 10-100 startups corosync-qnetd -f" > "$T/d3b/procs"; QP=$CLOSED vote "$T/d3b" --docker --ssh-port "$OPEN" --run
check "…the port is held by the SSH server of the container that is here: that one goes before the new one starts — replaced, exit 0" bash -c '[ "$2" = 0 ] && grep -qx "docker rm -f zradio-vote" "$1/calls" && grep -q "^docker run -d " "$1/calls"' _ "$T/d3b" "$RC"
machine "$T/d4"; : > "$T/d4/container-dead"; QP=$CLOSED vote "$T/d4" --docker --run
check "the container does not answer after its start: FAIL with its last lines, exit 1, no line for the node, no password shown" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the container does not answer .* Its last lines: zradio-vote: the SSH server did not start" "$1/out" && ! grep -q "ready to vote" "$1/out" && ! grep -q "this password" "$1/out"' _ "$T/d4" "$RC"
check "…and it is removed again (docker would restart it for ever: each start a used password and an exit), which is said; its volume is not" bash -c '[ "$(grep "^docker " "$1/calls" | tail -1)" = "docker rm -f zradio-vote" ] && [ ! -f "$1/container" ] && grep -q "It was removed again: left there, docker would restart it for ever" "$1/out" && ! grep -q "volume rm" "$1/calls"' _ "$T/d4"
machine "$T/d5"; : > "$T/d5/docker-down"; vote "$T/d5" --docker --run
check "docker does not answer: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "docker does not answer here" "$1/out"' _ "$T/d5" "$RC"
machine "$T/d7"; fake "$T/d7/bin" ip 'printf "%s\n" "2: eth0    inet 192.0.2.9/24 scope global eth0" "3: eth1    inet 198.51.100.7/24 scope global eth1" "4: eth2    inet 169.254.3.4/16 scope global eth2" "5: docker0    inet 172.17.0.1/16 scope global docker0"'; QP=$CLOSED vote "$T/d7" --docker --run
check "a machine with two addresses of its own: the line leaves the address open, and the two are listed (not docker's, not a self-assigned one)" bash -c 'grep -q -- "_ --third-vote <this machine.s address> --third-vote-port 2222 --third-vote-hostkey AAAA[A-Za-z0-9+/]*$" "$1/out" && grep -q "This machine.s addresses (the one the nodes reach): 192.0.2.9 198.51.100.7 $" "$1/out"' _ "$T/d7"
# a machine without apt-get (a NAS): only the fakes and a handful of plain tools on PATH
machine "$T/d6"; rm "$T/d6/bin/apt-get"; mkdir "$T/d6/base"
for c in bash sh env cat sed awk grep mkdir chmod mktemp rm sleep tr cp basename head tail cksum; do ln -s "$(command -v "$c")" "$T/d6/base/$c"; done
# (ZRADIO_VOTE_PATH: where the script looks for docker beyond PATH. Not this machine's /usr/local/bin: a real docker there is no fake)
PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_PATH="$T/d6/nas" ZRADIO_VOTE_QNETD_PORT=$CLOSED ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null; RC=$?
check "no apt-get here, docker there: the container, by itself" bash -c '[ "$2" = 0 ] && grep -q "in a container" "$1/out" && grep -q "WOULD the image" "$1/out"' _ "$T/d6" "$RC"
rm "$T/d6/base/cksum"; PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_PATH="$T/d6/nas" ZRADIO_VOTE_QNETD_PORT=$CLOSED ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null
check "…and no cksum either: an image is never taken for this version's unseen, it is made" has "$T/d6/out" "WOULD the image"
mkdir "$T/d6/nas"; mv "$T/d6/bin/docker" "$T/d6/nas/docker"; PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_PATH="$T/d6/nas" ZRADIO_VOTE_QNETD_PORT=$CLOSED ZRADIO_VOTE_WAIT=1 bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null; RC=$?
check "docker is not on PATH but where a NAS keeps it (sudo there drops it from PATH): found there" bash -c '[ "$2" = 0 ] && grep -q "in a container" "$1/out" && grep -q "WOULD the image" "$1/out"' _ "$T/d6" "$RC"
rm "$T/d6/nas/docker"; PATH="$T/d6/bin:$T/d6/base" ZRADIO_VOTE_PATH="$T/d6/nas" bash "$VOTE_TOOL" > "$T/d6/out" 2>&1 < /dev/null; RC=$?
check "neither apt-get nor docker: exit 2, said" bash -c '[ "$2" = 2 ] && grep -q "neither apt-get nor docker" "$1/out"' _ "$T/d6" "$RC"

echo "-- the third machine with docker: a second look at what a run leaves behind"
machine "$T/e1"; : > "$T/e1/container-slow"; QP=$CLOSED vote "$T/e1" --docker --run
check "the new container runs, was never restarted, and does not answer the probe yet (a slow machine): FAIL, and it is LEFT there — docker is not restarting it, and a vote is not taken down for a probe" bash -c '[ "$2" = 1 ] && [ -f "$1/container" ] && [ "$(grep -c "^docker rm -f zradio-vote$" "$1/calls")" = 0 ] && grep -q "It runs, docker has not restarted it, and it was left there" "$1/out"' _ "$T/e1" "$RC"
machine "$T/e2"; QP=$CLOSED vote "$T/e2" --docker --run; echo sha256:base2 > "$T/e2/registry"; : > "$T/e2/calls"; QP=$CLOSED vote "$T/e2" --docker --run
check "a newer base: the image is made again, and the one before is removed AFTER the container that ran on it is gone (docker removes no image in use)" bash -c 'r=$(grep -n "^docker rm -f zradio-vote$" "$1/calls" | tail -1 | cut -d: -f1); i=$(grep -n "^docker rmi id-" "$1/calls" | tail -1 | cut -d: -f1); [ "$2" = 0 ] && [ -n "$r" ] && [ -n "$i" ] && [ "$r" -lt "$i" ]' _ "$T/e2" "$RC"
check "the base is pulled without -q (docker before 19.03 does not know it, and a NAS may have one)" bash -c 'grep -qx "docker pull debian:13-slim" "$1/calls"' _ "$T/e2"
machine "$T/e3"; QP=$CLOSED vote "$T/e3" --docker --run; rm -f "$T/e3/base-id"; : > "$T/e3/pull-fail"; : > "$T/e3/calls"; QP=$CLOSED vote "$T/e3" --docker --run
check "the base image was deleted here (it looks unused in a NAS's list) and the registry is not reached: the vote's own image is whole — used, nothing is built" bash -c '[ "$2" = 0 ] && ! grep -q "^docker commit" "$1/calls" && grep -q "OK    the image zradio-vote is here" "$1/out"' _ "$T/e3" "$RC"

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
: > "$T/m8/calls"; PATH="$T/m8/bin:$PATH" bash "$TOOL" --name --help > "$T/m8/out" 2>&1 < /dev/null; RC=$?
check "…--help as an option's value is no call for help, and nothing is handed over then: the node's installer says that this is no node; exit 2, nothing run" bash -c '[ "$2" = 2 ] && grep -q "^die: no qm / pvesh here: this runs on a Proxmox VE node" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/m8" "$RC"

echo "-- the third machine: an option without its value; --docker without docker; a vote in service and an image that cannot be made"
machine "$T/o1"; vote "$T/o1" --docker --ssh-port
check "--ssh-port given last without a port: exit 2, said (it used to loop for ever)" bash -c '[ "$2" = 2 ] && grep -q "die: --ssh-port needs a value" "$1/out"' _ "$T/o1" "$RC"
vote "$T/o1" --key
check "…--key the same" bash -c '[ "$2" = 2 ] && grep -q "die: --key needs a value" "$1/out"' _ "$T/o1" "$RC"
vote "$T/o1" --docker --ssh-port 05403
check "--ssh-port 05403 is 5403, the vote's own port: exit 2" eq "$RC" 2
machine "$T/o2"; rm "$T/o2/bin/docker"; mkdir "$T/o2/base"
for c in bash sh env cat sed awk grep mkdir chmod mktemp rm sleep tr cp basename head tail cksum; do ln -s "$(command -v "$c")" "$T/o2/base/$c"; done
PATH="$T/o2/bin:$T/o2/base" ZRADIO_VOTE_PATH="$T/o2/nas" bash "$VOTE_TOOL" --docker > "$T/o2/out" 2>&1 < /dev/null; RC=$?
check "--docker on a machine without docker (it has apt-get): exit 2, saying that docker is what is missing" bash -c '[ "$2" = 2 ] && grep -q "die: --docker: there is no docker on this machine" "$1/out"' _ "$T/o2" "$RC"
machine "$T/o3"; : > "$T/o3/container"; echo 123 > "$T/o3/image"; : > "$T/o3/build-fail"; QP=$CLOSED vote "$T/o3" --docker --run
check "a vote is in service and the new image cannot be made: FAIL, exit 1, and the container that is here is NOT removed (the cluster keeps its vote)" bash -c '[ "$2" = 1 ] && [ -f "$1/container" ] && ! grep -qx "docker rm -f zradio-vote" "$1/calls" && grep -q "The container zradio-vote that is here was not touched" "$1/out" && ! grep -q "this password" "$1/out"' _ "$T/o3" "$RC"
rm "$T/o3/build-fail"; QP=$CLOSED vote "$T/o3" --docker --run
check "…once it can be made: the image first, then the old container removed, then the new one started" bash -c '[ "$2" = 0 ] && [ "$(grep -E "^docker (commit|rm -f zradio-vote$|run -d)" "$1/calls" | tail -3 | cut -d" " -f2 | tr "\n" " ")" = "commit rm run " ]' _ "$T/o3" "$RC"

echo "-- the third machine with apt-get: the key on a line of its own; an SSH server on another port"
machine "$T/o4"; printf 'ssh-ed25519 AAAAsomeoneelse x@y' > "$T/o4/ssh/authorized_keys"; vote "$T/o4" --key "$KEY" --run
check "authorized_keys that ends without a newline: the key is added as a line of its own, the one before is whole" bash -c '[ "$2" = 0 ] && [ "$(sed -n 1p "$1/ssh/authorized_keys")" = "ssh-ed25519 AAAAsomeoneelse x@y" ] && [ "$(sed -n 2p "$1/ssh/authorized_keys")" = "$3" ] && [ "$(wc -l < "$1/ssh/authorized_keys")" = 2 ]' _ "$T/o4" "$RC" "$KEY"
check "…the package lists are refreshed before the package is installed" bash -c 'u=$(grep -n "^apt-get -q update" "$1/calls" | cut -d: -f1) && i=$(grep -n "^apt-get -q -y install corosync-qnetd" "$1/calls" | cut -d: -f1) && [ "$u" -lt "$i" ]' _ "$T/o4"
check "…the machine's SSH server is on port 22: the line for a node names no port" bash -c 'grep -q -- "_ --third-vote 192.0.2.9$" "$1/out"' _ "$T/o4"
machine "$T/o6"; echo "ssh-ed25519 $HOSTKEY root@box" > "$T/o6/ssh_host_ed25519_key.pub"; vote "$T/o6" --key "$KEY" --run
check "…the machine has an ed25519 SSH host key: the line for a node carries it (the test machine's own key, if it has one, is never read)" bash -c '[ "$2" = 0 ] && grep -q -- "_ --third-vote 192.0.2.9 --third-vote-hostkey $3$" "$1/out" && grep -q "The long word at its end is this machine.s SSH host key" "$1/out"' _ "$T/o6" "$RC" "$HOSTKEY"
# (the 0.1.0 run failed on GitHub's runner and passed here: the runner has an SSH server and its host keys, the tests'
# container had neither. Where the machine is the tests' own image or the runner, it has them: tests/Dockerfile)
[ -z "${CI:-}${ZRADIO_TESTS_IMAGE:-}" ] || check "…and this test machine has an SSH host key and an sshd of its own, as GitHub's runner has: the lines above were printed beside them" bash -c '[ -s /etc/ssh/ssh_host_ed25519_key.pub ] && command -v sshd >/dev/null'
machine "$T/o5"; echo 2200 > "$T/o5/sshport"; vote "$T/o5" --key "$KEY" --run
check "…on another port: the line for a node carries it" bash -c '[ "$2" = 0 ] && grep -q -- "_ --third-vote 192.0.2.9 --third-vote-port 2200$" "$1/out"' _ "$T/o5" "$RC"

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
    'qdevice setup') $rec; echo 'INFO: initializing qnetd server'; grep -q '^Host 127.0.0.1\$' '$d/ssh/config' && : > '$d/entry-at-setup'; [ ! -f '$d/setup-fail' ] || { echo 'QDevice certificate store already initialised, set force to delete!'; exit 255; }
      sed -i 's/^  provider: corosync_votequorum\$/&\\n  device {\\n    model: net\\n    votes: 1\\n    net {\\n      algorithm: ffsplit\\n      host: '\"\$3\"'\\n      tls: on\\n    }\\n  }/' '$d/pve/corosync.conf'
      [ -f '$d/no-vote' ] || echo '3 2' > '$d/votes';;
    *) $rec;;
  esac"
  # apt-get, on either node (FAKE_APT_NODE: the fake ssh runs the other node's command here). Knobs: apt-stale (the
  # package is not in the lists until an update), apt-enterprise (update ends non-zero: a repository that refuses,
  # as Proxmox's enterprise one does without a subscription), apt-broken (the package cannot be installed at all)
  fake "$d/bin" apt-get "$rec; n=\${FAKE_APT_NODE:-nodea}
    case \" \$* \" in
      *' update '*) : > '$d/apt-updated-'\$n; [ ! -f '$d/apt-enterprise' ] || { echo 'E: Failed to fetch https://enterprise.proxmox.com/debian/pve/dists/trixie/InRelease  401  Unauthorized' >&2; exit 100; };;
      *' install '*) if [ -f '$d/apt-broken' ] || { [ -f '$d/apt-stale' ] && [ ! -f '$d/apt-updated-'\$n ]; }; then echo 'E: Unable to locate package corosync-qdevice' >&2; exit 100; fi
        if [ \$n = nodea ]; then printf '#!/bin/sh\n' > '$d/bin/corosync-qdevice-net-certutil'; chmod +x '$d/bin/corosync-qdevice-net-certutil'; else : > '$d/qdevice-nodeb'; fi;;
    esac"
  fake "$d/bin" corosync-qdevice-tool "[ -f '$d/qdev-down-nodea' ] && echo 'State:			Connect not active' || echo 'State:			Connected'"
  fake "$d/bin" ssh-copy-id "$rec; echo 'Number of key(s) added: 1'; [ ! -f '$d/wrong-password' ] || { echo 'Permission denied, please try again.'; exit 1; }; : > '$d/keyed'"
  # ssh: what it would do with a config (ssh -G) is asked of the real one; every connection is a fake
  fake "$d/bin" ssh "[ \"\$1\" != -G ] || exec '$(command -v ssh)' \"\$@\"
    $rec
    case \"\$*\" in *StrictHostKeyChecking=yes*) [ ! -f '$d/hostkey-mismatch' ] || { echo 'Host key verification failed.' >&2; exit 255; };; esac
    case \"\$*\" in
      *' -p 22 '*) echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; exit 255;;
      *StrictHostKeyChecking=accept-new*) [ -f '$d/keyed' ] && [ ! -f '$d/hostkey-changed' ] && [ ! -f '$d/no-qnetd' ];;
      *'command -v corosync-qnetd-certutil'*) [ -f '$d/keyed' ] && [ ! -f '$d/no-qnetd' ];;
      *'command -v corosync-qdevice-net-certutil'*) [ -f '$d/qdevice-nodeb' ];;
      *'apt-get -q -y install corosync-qdevice'*) FAKE_APT_NODE=nodeb bash -c \"\${*: -1}\";;      # the other node's command, run here
      *'corosync-qdevice-tool -s'*) [ -f '$d/qdev-down-nodeb' ] && echo 'State:			Connect not active' || echo 'State:			Connected';;
      *LEFTOVER*) [ ! -f '$d/leftover-nodeb' ] || echo LEFTOVER;;
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
  a=$(n "^apt-get -q -y install corosync-qdevice" "$1") && b=$(n "^ssh -e none -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=nodeb root@192.0.2.2 -- { DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice 2>/dev/null || { apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice; }; } >/dev/null$" "$1") &&
  c=$(n "^ssh-copy-id -i .*/ssh/id_rsa -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new root@127.0.0.1$" "$1") && h=$(n "^ssh -o BatchMode=yes .*StrictHostKeyChecking=accept-new .* root@127.0.0.1 command -v corosync-qnetd-certutil" "$1") && p=$(n "^pvecm qdevice setup 127.0.0.1$" "$1") &&
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$h" ] && [ "$h" -lt "$p" ]' _ "$T/n3"
check "…ssh-copy-id and the login after it go through the config (no -p on those calls), as pvecm will, and leave the host key to ssh to record in root's own known_hosts: accept-new, and no other file named for it" bash -c '[ "$(grep -cE "^(ssh-copy-id|ssh) .*StrictHostKeyChecking=accept-new" "$1/calls")" = 2 ] && ! grep -E "^ssh-copy-id|accept-new" "$1/calls" | grep -qE -- " -p |KnownHostsFile"' _ "$T/n3"
check "…that machine saw ONE login that could fail before the password was asked for (its SSH server may count them against this node's address): the look with nothing recorded, and no other connection to it before ssh-copy-id" bash -c 'c=$(grep -n -m1 "^ssh-copy-id" "$1/calls" | cut -d: -f1) && [ "$(head -n "$((c - 1))" "$1/calls" | grep -c "root@127.0.0.1")" = 1 ] && [ "$(grep -c "UserKnownHostsFile=/dev/null" "$1/calls")" = 1 ]' _ "$T/n3"
check "…the package lists of the nodes are fresh: corosync-qdevice installed at the first try, no apt-get update" bash -c '[ "$(grep -c "^apt-get -q -y install corosync-qdevice" "$1/calls")" = 2 ] && ! grep -q "^apt-get .*update" "$1/calls"' _ "$T/n3"
check "…root's ssh config had the entry for the address while pvecm ran, and is as it was before once the vote is set up: nothing of root's goes to the container by mistake later" bash -c '[ -f "$1/entry-at-setup" ] && [ "$(cat "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ] && grep -q "DONE  the entry for 127.0.0.1 is out of .*/ssh/config again" "$1/out"' _ "$T/n3" "$OPEN"
check "…both nodes are asked for their own connection to the vote" bash -c 'grep -q "OK    nodea holds a connection to the vote" "$1/out" && grep -q "OK    nodeb holds a connection to the vote" "$1/out"' _ "$T/n3"
check "…ssh-copy-id's and pvecm's lines are shown, and the votes read back: the cluster keeps its quorum without one node" bash -c 'grep -q "      | Number of key(s) added: 1" "$1/out" && grep -q "      | INFO: initializing qnetd server" "$1/out" && grep -q "OK    the cluster keeps its quorum without one node now (3 votes, 2 needed)" "$1/out"' _ "$T/n3"
: > "$T/n3/calls"; tv "$T/n3" "${V[@]}" --run
check "again: the cluster has its third vote, named; exit 0, nothing run" bash -c '[ "$2" = 0 ] && grep -q "OK    this cluster has a third vote already (its machine: 127.0.0.1)" "$1/out" && grep -q "pvecm qdevice remove, then this again" "$1/out" && [ ! -s "$1/calls" ]' _ "$T/n3" "$RC"
echo "2 2" > "$T/n3/votes"; tv "$T/n3" "${V[@]}"
check "…a third vote that is configured but does not vote: FAIL, exit 1" bash -c '[ "$2" = 1 ] && grep -q "FAIL  but it does NOT keep its quorum without one node now (2 vote(s), 2 needed)" "$1/out"' _ "$T/n3" "$RC"
cluster "$T/n3b"; tv "$T/n3b" "${V[@]}"
check "a report: one login at that machine too (the look), and it is the only connection to it" bash -c '[ "$(grep -c "root@127.0.0.1" "$1/calls")" = 1 ] && [ "$(grep -c "UserKnownHostsFile=/dev/null" "$1/calls")" = 1 ]' _ "$T/n3b"
cluster "$T/n4"; tv_ask "$T/n4" "${V[@]}" <<< "y"
check "asked, yes: it is done in the same sitting" bash -c '[ "$2" = 0 ] && grep -q "Go ahead?" "$1/out" && grep -q "^ssh-copy-id" "$1/calls" && grep -qx "pvecm qdevice setup 127.0.0.1" "$1/calls"' _ "$T/n4" "$RC"
cluster "$T/n5"; : > "$T/n5/keyed"; : > "$T/n5/qdevice-nodeb"; printf '#!/bin/sh\n' > "$T/n5/bin/corosync-qdevice-net-certutil"; chmod +x "$T/n5/bin/corosync-qdevice-net-certutil"; tv "$T/n5" "${V[@]}" --run
check "this node's key is there already (that machine was given it, or an earlier run), corosync-qdevice on both nodes: no password asked, nothing installed, set up all the same" bash -c '[ "$2" = 0 ] && grep -q "lets root of this node in by key" "$1/out" && ! grep -q "^ssh-copy-id" "$1/calls" && ! grep -q "apt-get" "$1/calls" && grep -qx "pvecm qdevice setup 127.0.0.1" "$1/calls"' _ "$T/n5" "$RC"
cluster "$T/n6"; printf 'Host 127.0.0.1\n    Port %s\n' "$OPEN" >> "$T/n6/ssh/config"; tv "$T/n6" "${V[@]}" --run
check "the ssh config has an entry of the user's own for the address already: said, not written twice, and left there afterward (it is not this script's)" bash -c '[ "$2" = 0 ] && grep -q "OK    .*/ssh/config has 127.0.0.1 on port" "$1/out" && [ "$(grep -c "^Host " "$1/ssh/config")" = 1 ] && ! grep -q "is out of" "$1/out"' _ "$T/n6" "$RC"
cluster "$T/n7"; : > "$T/n7/qdev-down-nodeb"; tv "$T/n7" "${V[@]}" --run
check "the vote counts, but the OTHER node holds no connection to it: FAIL naming that node and what it means, exit 1" bash -c '[ "$2" = 1 ] && grep -q "OK    nodea holds a connection to the vote" "$1/out" && grep -q "FAIL  nodeb holds no connection to the vote at 127.0.0.1 .*Left alone, nodeb would lose its quorum" "$1/out" && ! grep -q "^== done" "$1/out"' _ "$T/n7" "$RC"
cluster "$T/n8"; : > "$T/n8/leftover-nodeb"; tv "$T/n8" "${V[@]}" --run
check "certificates of an earlier vote on the OTHER node: FAIL before anything is changed (pvecm would stop there, halfway)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  certificates of an earlier third vote are still on nodeb" "$1/out" && ! grep -qE "^(pvecm|ssh-copy-id|apt-get)" "$1/calls" && [ "$(cat "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ]' _ "$T/n8" "$RC"

echo "-- a node: corosync-qdevice where the package lists are stale"
cluster "$T/q1"; : > "$T/q1/apt-stale"; : > "$T/q1/apt-enterprise"; tv "$T/q1" "${V[@]}" --run
check "the package is not in the lists of either node: the lists are refreshed (whatever apt-get update's exit code: an enterprise repository without a subscription fails it) and the install tried once more; set up, exit 0" bash -c '[ "$2" = 0 ] && [ "$(grep -E "^apt-get " "$1/calls" | cut -d" " -f2- | tr "\n" ";")" = "-q -y install corosync-qdevice;-q update;-q -y install corosync-qdevice;-q -y install corosync-qdevice;-q update;-q -y install corosync-qdevice;" ] && grep -q "DONE  apt-get install corosync-qdevice on nodea" "$1/out" && grep -q "DONE  apt-get install corosync-qdevice on nodeb" "$1/out" && grep -q "^== done" "$1/out"' _ "$T/q1" "$RC"; [ "$FAIL" = 0 ] || cat "$T/q1/out"
check "…the first try's error and the refused repository's lines are not shown: it worked" bash -c '! grep -q "Unable to locate\|401" "$1/out"' _ "$T/q1"
cluster "$T/q2"; : > "$T/q2/apt-broken"; tv "$T/q2" "${V[@]}" --run
check "the package cannot be installed, refreshed lists or not: apt-get's own line shown for each node, FAIL, exit 1, no key sent, no pvecm qdevice" bash -c '[ "$2" = 1 ] && [ "$(grep -c "E: Unable to locate package corosync-qdevice" "$1/out")" = 2 ] && grep -q "FAIL  apt-get install corosync-qdevice on nodea: failed" "$1/out" && grep -q "FAIL  apt-get install corosync-qdevice on nodeb .*: failed" "$1/out" && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/q2" "$RC"

echo "-- a node: root's ssh config, read the way ssh reads it (ssh -G)"
cluster "$T/e1"; printf 'host 127.0.0.1\n    port=%s\n' "$OPEN" >> "$T/e1/ssh/config"; cp "$T/e1/ssh/config" "$T/e1/config.before"; tv "$T/e1" "${V[@]}" --run
check "an entry of the user's own in other letters (host, port=N): seen as what it is — nothing written, nothing taken out" bash -c '[ "$2" = 0 ] && grep -q "OK    .*/ssh/config has 127.0.0.1 on port" "$1/out" && ! grep -q "an entry for 127.0.0.1 in" "$1/out" && ! grep -q "is out of" "$1/out" && cmp -s "$1/ssh/config" "$1/config.before"' _ "$T/e1" "$RC"
cluster "$T/e2"; printf 'Host 127.0.0.*\n    Port 2200\n' >> "$T/e2/ssh/config"; cp "$T/e2/ssh/config" "$T/e2/config.before"; tv "$T/e2" "${V[@]}" --run
check "a pattern that fits the address, with another port: FAIL naming that port (an entry added below it would not win), exit 1, the file untouched, no key sent" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*/ssh/config names port 2200 for 127.0.0.1 already" "$1/out" && cmp -s "$1/ssh/config" "$1/config.before" && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/e2" "$RC"
cluster "$T/e3"; printf 'Host *\n    Port %s\n' "$OPEN" >> "$T/e3/ssh/config"; tv "$T/e3" "${V[@]}"
check "a pattern that gives the right port (Host *): nothing to add" bash -c '[ "$2" = 0 ] && grep -q "OK    .*/ssh/config has 127.0.0.1 on port" "$1/out" && ! grep -q "WOULD an entry for 127.0.0.1" "$1/out"' _ "$T/e3" "$RC"
cluster "$T/e4"; printf 'Host *\n    Port 2200\nHost 127.0.0.1\n    Port %s\n' "$OPEN" >> "$T/e4/ssh/config"; tv "$T/e4" "${V[@]}"
check "two entries fit, and ssh takes the FIRST port it meets, not the last: FAIL with that one" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*/ssh/config names port 2200 for 127.0.0.1 already" "$1/out"' _ "$T/e4" "$RC"
cluster "$T/e5"; printf 'Host 127.0.0.1\n    Port %s\nHost *\n    Port 2200\n' "$OPEN" >> "$T/e5/ssh/config"; tv "$T/e5" "${V[@]}"
check "…the other way around: the right port comes first, OK" bash -c '[ "$2" = 0 ] && grep -q "OK    .*/ssh/config has 127.0.0.1 on port" "$1/out"' _ "$T/e5" "$RC"
cluster "$T/e6"; printf 'Hots 127.0.0.1\n' >> "$T/e6/ssh/config"; tv "$T/e6" "${V[@]}" --run
check "a config ssh itself cannot read: FAIL with ssh's own line, exit 1, nothing written, no key sent (pvecm's ssh would stop at it)" bash -c '[ "$2" = 1 ] && grep -q "FAIL  ssh cannot read .*/ssh/config (.*Bad configuration option: hots" "$1/out" && ! grep -q "^Host " "$1/ssh/config" && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/e6" "$RC"; [ "$FAIL" = 0 ] || cat "$T/e6/out"
cluster "$T/e7"; rm "$T/e7/ssh/config"; tv "$T/e7" "${V[@]}" --run
check "no ssh config at all: one is made for the setup with the entry in it (pvecm ran with it), and the entry is out of it afterward" bash -c '[ "$2" = 0 ] && [ -f "$1/entry-at-setup" ] && [ -f "$1/ssh/config" ] && ! grep -q "Host\|Port" "$1/ssh/config" && [ "$(stat -c %a "$1/ssh/config")" = 600 ]' _ "$T/e7" "$RC"

echo "-- a node: the vote machine's SSH host key comes with the line, and is known before anything is said to that machine"
cluster "$T/h1"; tv "$T/h1" "${V[@]}" --third-vote-hostkey "$HOSTKEY" --run
check "exit 0; the key is in root's known_hosts under the name ssh looks it up by, before the password is typed" bash -c '[ "$2" = 0 ] && grep -qxF "[127.0.0.1]:$3 ssh-ed25519 $4" "$1/ssh/known_hosts" && grep -q "DONE  that machine.s SSH host key, as its line names it" "$1/out" && a=$(grep -n "that machine.s SSH host key, as its line names it" "$1/out" | cut -d: -f1) && b=$(grep -n "ssh-copy-id to root@127.0.0.1" "$1/out" | cut -d: -f1) && [ "$a" -lt "$b" ]' _ "$T/h1" "$RC" "$OPEN" "$HOSTKEY"; [ "$FAIL" = 0 ] || cat "$T/h1/out"
check "…every login then insists on that key: ssh-copy-id and the look afterward with StrictHostKeyChecking=yes, none with accept-new; the first look too, against a file of its own" bash -c 'grep "^ssh-copy-id" "$1/calls" | grep -q "StrictHostKeyChecking=yes" && ! grep -q "accept-new" "$1/calls" && grep "command -v corosync-qnetd-certutil" "$1/calls" | head -1 | grep -q "StrictHostKeyChecking=yes -o UserKnownHostsFile=/"' _ "$T/h1"
check "…and nothing says that a key was trusted on first use" bash -c '! grep -q "trusted on this first use" "$1/out"' _ "$T/h1"
tv "$T/h1" "${V[@]}" --third-vote-hostkey "$HOSTKEY"
cluster "$T/h2"; : > "$T/h2/hostkey-mismatch"; tv "$T/h2" "${V[@]}" --third-vote-hostkey "$HOSTKEY" --run
check "another machine answers at that address (its host key is not the line's): FAIL, exit 1, and nothing is sent to it — no password asked, no key left, no pvecm" bash -c '[ "$2" = 1 ] && grep -q "FAIL  the machine that answers at 127.0.0.1 on SSH port .* is not the one that printed this line" "$1/out" && ! grep -qE "^(ssh-copy-id|pvecm|apt-get)" "$1/calls" && [ ! -e "$1/ssh/known_hosts" ] && [ "$(cat "$1/ssh/config")" = "Ciphers aes128-ctr,aes256-ctr" ]' _ "$T/h2" "$RC"
cluster "$T/h3"; echo "[127.0.0.1]:$OPEN ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnOlderKeyOfAnEarlierContainerAAAAAAAAAAAAAAAA" > "$T/h3/ssh/known_hosts"; echo "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepThisLineKeepThisLineKeepThisLineKeepTh" >> "$T/h3/ssh/known_hosts"
tv "$T/h3" "${V[@]}" --third-vote-hostkey "$HOSTKEY" --run
check "an older key for that address is in known_hosts (a container rebuilt with a new volume): replaced by the line's, other hosts' lines kept" bash -c '[ "$2" = 0 ] && [ "$(grep -c "127.0.0.1" "$1/ssh/known_hosts")" = 1 ] && grep -qF "ssh-ed25519 $3" "$1/ssh/known_hosts" && grep -q "^other.example " "$1/ssh/known_hosts"' _ "$T/h3" "$RC" "$HOSTKEY"
cluster "$T/h4"; tv "$T/h4" "${V[@]}" --third-vote-hostkey "not-a-key"
check "--third-vote-hostkey that is no ed25519 key: exit 2" eq "$RC" 2
cluster "$T/h5"; tv "$T/h5" "${V[@]}"
check "a line without the key (an older one): said, with what that means, and it goes on as before" bash -c '[ "$2" = 0 ] && grep -q "NOTE  the line names no SSH host key (--third-vote-hostkey; .*trusted on this first use, as Proxmox.s own setup does" "$1/out"' _ "$T/h5" "$RC"

echo "-- a node: what is refused"
cluster "$T/r0"; : > "$T/r0/wrong-password"; tv "$T/r0" "${V[@]}" --run
check "a wrong or expired password: ssh-copy-id's lines shown, FAIL with how to get a new one (and the way without a terminal), exit 1, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "      | Permission denied, please try again." "$1/out" && grep -q "FAIL  ssh-copy-id to root@127.0.0.1 failed" "$1/out" && grep -q "the install line on that machine again gives a new one" "$1/out" && grep -q "its --key, with .*/ssh/id_rsa.pub" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r0" "$RC"
check "…an SSH server that holds this address off after failed tries is said of the machine it is true of: one that votes from Debian's package (the kit's container has that switched off)" bash -c 'grep -q "\"Connection closed\" after several tries, where the vote is from Debian.s package: that machine.s own SSH server holds this address off for a while; wait a minute (the kit.s container never does)" "$1/out" && bash "$2" --show entrypoint | grep -q -- "-o PerSourcePenalties=no"' _ "$T/r0" "$VOTE_TOOL"
cluster "$T/r0b"; : > "$T/r0b/no-qnetd"; : > "$T/r0b/keyed"; tv "$T/r0b" "${V[@]}" --run
check "root gets in there but corosync-qnetd is not there (some other machine's SSH): FAIL, exit 1, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "FAIL  ssh to root@127.0.0.1 by key failed with the port from .*, or corosync-qnetd is not installed there" "$1/out" && ! grep -q "^pvecm" "$1/calls"' _ "$T/r0b" "$RC"
cluster "$T/r1"; printf 'Host backup 127.0.0.1\n    Port 2200\n' >> "$T/r1/ssh/config"; tv "$T/r1" "${V[@]}" --run
check "the ssh config names the address with another port: FAIL, exit 1, the file untouched, no key sent, no pvecm qdevice" bash -c '[ "$2" = 1 ] && grep -q "FAIL  .*/ssh/config names port 2200 for 127.0.0.1 already" "$1/out" && [ "$(grep -c "^Host " "$1/ssh/config")" = 1 ] && ! grep -qE "^(pvecm|ssh-copy-id)" "$1/calls"' _ "$T/r1" "$RC"
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

echo "-- the script says what the tests hang on; the kit names no file that is not in it"
# (the script itself, without the two texts it carries for the container; KEY, PASSWORD, RUN and SSH_PORT are what it
# gives the container, named in the entrypoint's own comments)
check "every ZRADIO_VOTE_* knob vote/install.sh reads is named in its header" bash -c 'k=$(awk "/<<.EOF.\$/ { h = 1 } !h { print } /^EOF\$/ { h = 0 }" "$1" | grep -oE "ZRADIO_VOTE_[A-Z_]+" | sort -u | grep -vxE "ZRADIO_VOTE_(KEY|PASSWORD|RUN|SSH_PORT)") && [ "$(printf "%s\n" "$k" | grep -c .)" -ge 8 ] && c=$(sed -n "1,/^set -uo pipefail\$/p" "$1") && for n in $k; do printf "%s\n" "$c" | grep -qw "$n" || { echo "        not named: $n"; exit 1; }; done' _ "$VOTE_TOOL"
# (gen/ is not the kit: what is generated, and notes that are not kept in git)
check "every host/*.sh, vote/*.sh, homeassistant/*.sh and tests/*.sh a script or a document names exists" bash -c 'cd "$1" && ! grep -rhoE "\b(host|vote|homeassistant|tests)/[a-z0-9-]+\.sh\b" --include="*.sh" --include="*.md" --include="*.example" --include="*.yml" --include=Dockerfile --exclude-dir=gen --exclude-dir=.git . | sort -u | while read -r f; do [ -f "$f" ] || echo "$f"; done | grep .' _ "$KIT"
finish
