#!/usr/bin/env bash
# tests/vote-bash.sh — vote/install.sh run by the oldest bash its header promises (3.2), and by 4.4. The third
# machine is whatever is always on, often a NAS, and its bash is whatever it came with. Not one of tests/run.sh's
# files: it needs docker and the network (the images bash:3.2 and bash:4.4, Docker's own builds of those versions on
# Alpine). Linux or macOS:
#   bash tests/vote-bash.sh
# Real: the script, read and run by that bash, with that machine's own tools (busybox: sed, awk, grep, cksum, tr,
# head, mktemp, ip): its help, what it shows, what it refuses, a report, a question answered no, a run and a run again.
# A fake: docker, a sh script that records its calls. What docker itself makes of them is tests/vote-real.sh's.
. "$(dirname "$0")/lib.sh"
HOSTKEY=AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKeyFakeHostKey12
if ! docker info >/dev/null 2>&1; then      # no docker on a developer's machine: nothing to test. In CI that is a failure, not a pass
  [ -z "${CI:-}" ] || check "docker answers here (CI: this test must run)" false
  echo "SKIP  docker does not answer here: nothing was tested"; finish; exit
fi
chmod 755 "$T"; cp "$KIT/vote/install.sh" "$T/install.sh"
cat > "$T/docker" <<EOF
#!/bin/sh
# a docker that does nothing and says what it was asked: its state is files in /w
echo "docker \$*" | head -n 1 >> /w/calls
case "\$1" in
  info) ;;
  pull) echo sha256:base1 > /w/base-id;;
  inspect) case "\$3 \$*" in container*) [ -f /w/container ];; image*'{{.Id}}'*) cat /w/base-id 2>/dev/null;; image*) cat /w/image 2>/dev/null;; esac;;
  images) [ ! -f /w/image ] || echo id-1;;
  rm) [ "\$3" != zradio-vote ] || rm -f /w/container;;
  run) [ "\$2" != -d ] || : > /w/container;;
  cp) cp "\$2" /w/entrypoint.sh;;
  commit) echo "\$*" | sed -n 's/.*LABEL zradio.recipe=\([0-9]*\).*/\1/p' > /w/image;;
  exec) case "\$*" in *ssh_host_ed25519_key.pub*) echo "ssh-ed25519 $HOSTKEY root@zradio-vote";; *cmdline*) echo "sshd -D -e -p 2022 -h /etc/corosync/qnetd/ssh_host_ed25519_key";; esac;;
esac
EOF
# what runs in the container, by its sh: each run of the script by that machine's bash, its exit code and its lines
cat > "$T/drive.sh" <<'EOF'
mkdir -p /w/bin && cp /t/docker /w/bin/docker && chmod +x /w/bin/docker
export PATH=/w/bin:$PATH ZRADIO_VOTE_PATH=/w/none ZRADIO_VOTE_WAIT=1 ZRADIO_VOTE_SSH_DIR=/w/ssh
V=/t/install.sh
echo "BASH $(bash -c 'echo "$BASH_VERSION"')"
bash $V --help > /w/o 2>&1; echo "HELP rc=$? first=$(head -n 1 /w/o) last=$(tail -n 1 /w/o)"
bash $V --show image | sh -n && bash $V --show entrypoint | sh -n && [ "$(bash $V --show entrypoint | head -n 1)" = '#!/bin/sh' ] && echo "SHOW OK"
bash $V --ssh-port 99999 > /w/o 2>&1; echo "BADPORT rc=$? $(cat /w/o)"
bash $V --key 'not a key' > /w/o 2>&1; echo "BADKEY rc=$? $(cat /w/o)"
bash $V --ssh-port > /w/o 2>&1; echo "NOVALUE rc=$? $(cat /w/o)"
bash $V > /w/o 2>&1 < /dev/null; echo "REPORT rc=$?"; sed 's/^/R| /' /w/o; echo "REPORT calls: $(grep -cE '^docker (pull|run|commit|rm|cp)' /w/calls)"
echo n | ZRADIO_VOTE_ASK=1 bash $V > /w/o 2>&1; echo "ASKED rc=$?"; sed 's/^/A| /' /w/o
ZRADIO_VOTE_OPEN_S=600 bash $V --ssh-port 2022 --run > /w/o 2>&1 < /dev/null; echo "RUN rc=$?"; sed 's/^/X| /' /w/o; sed 's/^/C| /' /w/calls
: > /w/calls; bash $V --ssh-port 2022 --key 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfake+fake/fake== root@nodea' --run > /w/o 2>&1 < /dev/null; echo "AGAIN rc=$?"; sed 's/^/Y| /' /w/o; sed 's/^/D| /' /w/calls
EOF
chmod -R a+rX "$T"

for v in 3.2 4.4; do
  echo "-- vote/install.sh under bash $v"
  O="$T/out-$v"
  docker run --rm -v "$T":/t:ro "bash:$v" sh /t/drive.sh > "$O" 2>&1; RC=$?
  check "the machine: bash $v ran it all (the container ended clean)" bash -c '[ "$2" = 0 ] && grep -q "^BASH $3\." "$1"' _ "$O" "$RC" "$v"; [ "$FAIL" = 0 ] || cat "$O"
  check "no line of the script is beyond that bash: no syntax error, no bad substitution, no unbound variable anywhere" bash -c '! grep -qiE "syntax error|bad substitution|unbound variable|command not found|not a valid identifier|invalid option" "$1"' _ "$O"
  check "--help: the header, from its first line to the last before the code" bash -c 'grep -q "^HELP rc=0 first=# vote/install.sh — the third vote of a Proxmox cluster.* last=# times in seconds: " "$1"' _ "$O"
  check "--show image and --show entrypoint: two sh scripts that parse" has "$O" "SHOW OK"
  check "what is refused is refused the same: a port that is none, a key that is none, an option without its value (exit 2, said)" bash -c 'grep -q "^BADPORT rc=2 die: --ssh-port .99999.: a TCP port" "$1" && grep -q "^BADKEY rc=2 die: --key: not one public key line" "$1" && grep -q "^NOVALUE rc=2 die: --ssh-port needs a value" "$1"' _ "$O"
  check "no apt-get there, docker on PATH: a report of the container, exit 0, and docker was asked for nothing that changes anything" bash -c 'grep -q "^REPORT rc=0$" "$1" && grep -q "^R| == the third vote on .*, in a container (report only" "$1" && grep -q "^R|    WOULD the image zradio-vote made" "$1" && grep -q "^R|    WOULD the container zradio-vote started" "$1" && grep -q "^R| REPORT ONLY" "$1" && grep -qx "REPORT calls: 0" "$1"' _ "$O"
  check "asked, and the answer is no: nothing done" bash -c 'grep -q "^ASKED rc=0$" "$1" && grep -q "^A|    Go ahead? \[y/N\]:    Nothing was changed.$" "$1"' _ "$O"
  check "--run: exit 0; the base image asked for, the image made, the container started with a password by name, this run's name, the port and the tests' time" bash -c '
    grep -q "^RUN rc=0$" "$1" && [ "$(grep -E "^C\| docker (pull|run --name|cp|commit|run -d)" "$1" | cut -d" " -f3 | tr "\n" " ")" = "pull run cp commit run " ] &&
    grep -qE "^C\| docker commit -c VOLUME /etc/corosync/qnetd -c ENTRYPOINT \[\"/entrypoint.sh\"\] -c CMD \[\] -c LABEL zradio.recipe=[0-9]+ -c LABEL zradio.base=[a-z0-9:]* zradio-vote-build zradio-vote$" "$1" &&
    grep -qx "C| docker run -d --name zradio-vote --restart unless-stopped --network host --cap-drop NET_RAW --security-opt no-new-privileges -v zradio-vote:/etc/corosync/qnetd -e ZRADIO_VOTE_PASSWORD -e ZRADIO_VOTE_RUN -e ZRADIO_VOTE_SSH_PORT=2022 -e ZRADIO_VOTE_OPEN_S zradio-vote" "$1"' _ "$O"
  check "…it ends with the line for a node (the port and the host key in it) and a password of twelve letters and digits in three groups" bash -c 'grep -qE "^X\|       bash -c \"\\\$\(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh\)\" _ --third-vote [^ ]+ --third-vote-port 2022 --third-vote-hostkey $2$" "$1" && grep -qE "^X\|    It asks once for this password:    [a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$" "$1"' _ "$O" "$HOSTKEY"
  check "again, with --key: the container that is here goes first (its own SSH server holds the port), the image is not made again, the key is what gets in" bash -c '
    grep -q "^AGAIN rc=0$" "$1" && grep -q "^Y|    OK    the image zradio-vote is here" "$1" && ! grep -q "^D| docker commit" "$1" &&
    [ "$(grep -E "^D\| docker (rm -f zradio-vote$|run -d)" "$1" | cut -d" " -f3 | tr "\n" " ")" = "rm run " ] && grep -q "^D| docker run -d .* -e ZRADIO_VOTE_KEY -e ZRADIO_VOTE_RUN -e ZRADIO_VOTE_SSH_PORT=2022 zradio-vote$" "$1" && grep -q "^Y|    It asks for no password" "$1"' _ "$O"
done
finish
