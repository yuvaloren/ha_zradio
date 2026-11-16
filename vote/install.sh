#!/usr/bin/env bash
# vote/install.sh — the third vote of a Proxmox cluster of two nodes, on a third machine that is always on (a NAS, a
# Pi, a small Linux box; never a VM on either node). It runs corosync-qnetd, the arbiter Proxmox's cluster manual
# names, and opens the door for ONE node's root over SSH, because Proxmox's own `pvecm qdevice setup` does the rest
# from that node. Two steps:
#   1. here, as root:  the kit's install line (get.sh: ./install.sh on a machine that is not a Proxmox node hands
#                      over to this script). It ends with the line for a node, and a one-time password.
#   2. on one node:    that line. It asks for the password once, and sets the vote up.
# Two ways, by what this machine has:
#   docker  (a NAS; or --docker): a container, zradio-vote, on the machine's own network: corosync-qnetd on TCP 5403
#           and an SSH server of its own on --ssh-port. Root gets in there with a one-time password this script
#           makes up: good until the node has left its key (it does that first), 30 minutes at most, and never again
#           after a restart. Nothing of the machine itself is changed. The certificates live in the docker volume
#           zradio-vote and survive a rebuild. The image is made with docker run, cp and commit, not docker build: a
#           NAS's docker has no buildx, and docker build without it is the legacy builder docker is retiring.
#   apt-get (Debian, Ubuntu, Raspberry Pi OS): Debian's corosync-qnetd package. The node logs in as root with root's
#           password of this machine, as Proxmox's manual has it; where the SSH server does not allow that: --docker,
#           or --key.
# It shows what it would do and does it after a y (or with --run). Run again, it replaces the container (a new
# password, another port) and keeps the certificates.
#   --key 'ssh-rsa AAAA… root@node'   no password at all: that node's public key (its /root/.ssh/id_rsa.pub) is let in
#   --ssh-port N                      the container's SSH port (default 2222): any free TCP port of this machine
#   --docker                          the container, on a machine that has apt-get too
#   --show image|entrypoint           print what the image is made with, or what the container runs, and stop
#   --run                             do it, no question
# To remove the vote: `pvecm qdevice remove` on a node; then here `docker rm -f zradio-vote && docker volume rm
# zradio-vote && docker rmi zradio-vote`, or `apt-get purge corosync-qnetd` (and a --key line out of root's
# authorized_keys).
# Tests: tests/t-vote.sh (fakes) and tests/vote-real.sh (docker and the real programs). Bash 3.2 or later.
set -uo pipefail
NAME=${ZRADIO_VOTE_NAME:-zradio-vote}                 # the container, its image and its volume
SSH_DIR=${ZRADIO_VOTE_SSH_DIR:-/root/.ssh}
QNETD_PORT=5403                                        # corosync-qnetd's port
PROBE_PORT=${ZRADIO_VOTE_QNETD_PORT:-$QNETD_PORT}      # where the checks below look for it (the tests: another port)
WAIT=${ZRADIO_VOTE_WAIT:-20}                           # seconds to wait for it to answer
GET_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
KEY="" PORT=2222 DOCKER=0 RUN=0 FAILS=0 PW=""
ok() { printf '   OK    %s\n' "$*"; }
bad() { printf '   FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
would() { printf '   WOULD %s\n' "$*"; }
done_() { printf '   DONE  %s\n' "$*"; }
die() { echo "die: $*" >&2; exit 2; }
step() { # step <what, in words> <command…>: run it (RUN) or say it
  local what=$1; shift
  if [ $RUN = 1 ]; then if "$@"; then done_ "$what"; else bad "$what: failed"; return 1; fi; else would "$what"; fi
}

BASE=debian:13-slim                                    # what the image starts from: Debian 13, as the nodes
image() { cat <<'EOF'
# zradio-vote: what is run once, in a container of debian:13-slim, to make the image: corosync-qnetd, and an SSH
# server for the one node that sets the vote up. The entrypoint is copied in afterward.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends corosync-qnetd openssh-server
rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
EOF
}
entrypoint() { cat <<'EOF'
#!/bin/sh
# zradio-vote: what runs in the container. The volume (/etc/corosync/qnetd) keeps the arbiter's certificates and the
# SSH server's host key. Who gets in as root over SSH, one of:
#   ZRADIO_VOTE_KEY       that public key, and nothing else
#   ZRADIO_VOTE_PASSWORD  that password, ONCE: from this start until a key has been left (ssh-copy-id), 30 minutes
#                         at most. It is marked as used in the volume before the door opens, so a restart of the
#                         container never opens it again.
set -eu
D=/etc/corosync/qnetd
[ -f "$D/nssdb/qnetd-cacert.crt" ] || corosync-qnetd-certutil -i
[ -f "$D/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/ssh_host_ed25519_key"
mkdir -p /run/sshd /run/corosync-qnetd /root/.ssh
chmod 700 /root/.ssh
ROOT=prohibit-password BY_PASSWORD=no
if [ -n "${ZRADIO_VOTE_KEY:-}" ]; then
  printf '%s\n' "$ZRADIO_VOTE_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
elif [ -n "${ZRADIO_VOTE_PASSWORD:-}" ]; then
  MARK=$(printf '%s' "$ZRADIO_VOTE_PASSWORD" | sha256sum)
  if [ "$(cat "$D/password-used" 2>/dev/null || true)" != "$MARK" ]; then
    printf '%s\n' "$MARK" > "$D/password-used"
    echo "root:$ZRADIO_VOTE_PASSWORD" | chpasswd
    ROOT=yes BY_PASSWORD=yes
    ( n=0; until [ -s /root/.ssh/authorized_keys ] || [ $n -ge 900 ]; do sleep 2; n=$((n + 1)); done
      usermod -p '*' root; echo "zradio-vote: the one-time password is off" ) &
  fi
fi
/usr/sbin/sshd -D -e -p "$ZRADIO_VOTE_SSH_PORT" -h "$D/ssh_host_ed25519_key" \
  -o PasswordAuthentication=$BY_PASSWORD -o KbdInteractiveAuthentication=no -o PermitRootLogin=$ROOT \
  -o PerSourcePenalties=no &      # the one client is the node: a mistyped password must not lock it out for minutes
sleep 1
kill -0 $! 2>/dev/null || { echo "zradio-vote: the SSH server did not start (is TCP port $ZRADIO_VOTE_SSH_PORT in use?)" >&2; exit 1; }
exec corosync-qnetd -f
EOF
}

while [ $# -gt 0 ]; do case "$1" in
  -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" 2>/dev/null | sed '$d'; exit 0;;
  --key) KEY=${2:-}; shift 2;; --ssh-port) PORT=${2:-}; shift 2;; --docker) DOCKER=1; shift;; --run) RUN=1; shift;;
  --show) case "${2:-}" in image) image;; entrypoint) entrypoint;; *) die "--show image|entrypoint";; esac; exit 0;;
  *) echo "unknown option: $1" >&2; exit 2;; esac; done
ASK=0; if { [ -t 0 ] && [ -t 1 ]; } || [ "${ZRADIO_VOTE_ASK:-0}" = 1 ]; then ASK=1; fi
KEY_RE='^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [A-Za-z0-9@._:+-]+)?$'
[ -z "$KEY" ] || [[ "$KEY" =~ $KEY_RE ]] || die "--key: not one public key line (type, key, and at most a one-word comment)"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && [ "$PORT" != "$QNETD_PORT" ] || die "--ssh-port '$PORT': a TCP port, and not $QNETD_PORT (the vote's own)"
PATH=$PATH:/usr/local/bin:/var/packages/ContainerManager/target/usr/bin     # where a NAS keeps docker; sudo there drops it from PATH
if [ $DOCKER = 0 ] && command -v apt-get >/dev/null 2>&1; then MODE=apt
elif command -v docker >/dev/null 2>&1; then MODE=docker
else die "this machine has neither apt-get nor docker: the vote needs one of the two"; fi

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }      # something on this machine listens on that TCP port
addresses() { # this machine's own IPv4 addresses: not docker's bridges, not self-assigned ones
  ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ && $4 !~ /^169\.254\./ { sub(/\/.*/, "", $4); printf "%s ", $4 }'
}
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qnetd >/dev/null; }
add_key() { mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR" && printf '%s\n' "$KEY" >> "$SSH_DIR/authorized_keys" && chmod 600 "$SSH_DIR/authorized_keys"; }
recipe() { { echo "$BASE"; image; entrypoint; } | cksum | tr -d ' \t'; }      # what the image is made from, as one number
built() { local r; r=$(recipe); [ -n "$r" ] && [ "$(docker inspect --type image -f '{{ index .Config.Labels "zradio.recipe" }}' "$NAME" 2>/dev/null)" = "$r" ]; }
build() { # the image, with no builder: a container of $BASE that installs the packages, the entrypoint copied in, a commit
  local b=$NAME-build t old rc=1
  t=$(mktemp -d) || return 1
  entrypoint > "$t/entrypoint.sh"; chmod 0755 "$t/entrypoint.sh"
  old=$(docker images -q "$NAME" 2>/dev/null)
  docker rm -f "$b" >/dev/null 2>&1
  if docker run --name "$b" "$BASE" sh -c "$(image)" > "$t/log" 2>&1 \
     && docker cp "$t/entrypoint.sh" "$b:/entrypoint.sh" >> "$t/log" 2>&1 \
     && docker commit -c 'VOLUME /etc/corosync/qnetd' -c 'ENTRYPOINT ["/entrypoint.sh"]' -c 'CMD []' -c "LABEL zradio.recipe=$(recipe)" "$b" "$NAME" >> "$t/log" 2>&1
  then rc=0; [ -z "$old" ] || [ "$old" = "$(docker images -q "$NAME" 2>/dev/null)" ] || docker rmi "$old" >/dev/null 2>&1      # the image before this one
  else tail -5 "$t/log" | sed 's/^/      | /'; fi
  docker rm -f "$b" >/dev/null 2>&1; rm -rf "$t"; return $rc
}
remove() { docker rm -f "$NAME" >/dev/null; }
password() { # twelve letters and digits that are not mistaken for one another, in three groups
  local p; p=${ZRADIO_VOTE_PW:-$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'a-hjkmnp-z2-9')}; p=${p:0:12}      # a bounded read: no pipe is cut short
  [ ${#p} = 12 ] && printf '%s-%s-%s' "${p:0:4}" "${p:4:4}" "${p:8:4}"
}
start() { # the node gets in with --key's key, or with a one-time password made up here
  local who
  if [ -n "$KEY" ]; then who="ZRADIO_VOTE_KEY=$KEY"; else PW=$(password) && [ -n "$PW" ] || return 1; who="ZRADIO_VOTE_PASSWORD=$PW"; fi
  docker run -d --name "$NAME" --restart unless-stopped --network host -v "$NAME:/etc/corosync/qnetd" -e "$who" -e "ZRADIO_VOTE_SSH_PORT=$PORT" "$NAME" >/dev/null
}
in_container() { docker exec "$NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }     # the port answers, seen from inside

apt_steps() {
  local prl pwa
  [ "$(id -u)" = 0 ] || die "run this as root"
  if command -v sshd >/dev/null 2>&1; then
    prl=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }'); pwa=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2 }')
    if [ -n "$KEY" ]; then
      case "$prl" in yes|prohibit-password|without-password) ok "the SSH server here lets root in by key (PermitRootLogin $prl)";;
        *) bad "the SSH server here does not let root in (PermitRootLogin ${prl:-unknown}): pvecm qdevice setup logs in as root. Set 'PermitRootLogin prohibit-password' in /etc/ssh/sshd_config and reload ssh, or use --docker";; esac
    elif [ "$prl" = yes ] && [ "$pwa" = yes ]; then ok "the SSH server here lets root in with its password: the node asks for it once, and leaves its key"
    else bad "the SSH server here does not let root in with a password (PermitRootLogin ${prl:-unknown}, PasswordAuthentication ${pwa:-unknown}), which is how the node gets in the first time. Either --docker (a container, with a one-time password of its own), or --key with the node's public key (its /root/.ssh/id_rsa.pub)"; fi
  else bad "no SSH server here: pvecm qdevice setup logs in as root over SSH (apt-get install openssh-server), or use --docker"; fi
  [ $FAILS = 0 ] || return 1
  if command -v corosync-qnetd >/dev/null 2>&1; then ok "corosync-qnetd is installed"
  else step "apt-get install corosync-qnetd (Debian's package; it starts by itself, now and at boot)" apt_install || return 1; fi
  if [ -z "$KEY" ]; then :
  elif grep -qxF "$KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then ok "the node's key is in $SSH_DIR/authorized_keys"
  else step "the node's key added to $SSH_DIR/authorized_keys: root of that node may log in here" add_key || return 1; fi
  [ $RUN = 1 ] || return 0
  local i=0; until port_open "$PROBE_PORT"; do i=$((i + 1)); [ $i -lt "$WAIT" ] || break; sleep 1; done
  if port_open "$PROBE_PORT"; then ok "corosync-qnetd answers on TCP $QNETD_PORT"; else bad "nothing answers on TCP $QNETD_PORT here: systemctl status corosync-qnetd"; fi
}
docker_steps() {
  docker info >/dev/null 2>&1 || die "docker does not answer here: run this as root (or as a user who may use docker)"
  if docker inspect --type container "$NAME" >/dev/null 2>&1; then
    step "the container $NAME that is here removed (its certificates stay, in the volume $NAME)" remove || return 1
  else
    ! port_open "$PROBE_PORT" || bad "TCP port $QNETD_PORT is in use on this machine (another corosync-qnetd?): the vote needs it"
    ! port_open "$PORT" || bad "TCP port $PORT is in use on this machine: another one with --ssh-port"
    [ $FAILS = 0 ] || return 1
  fi
  if built; then ok "the image $NAME is here, as this version of the kit makes it"
  else
    [ $RUN = 0 ] || echo "   making the image (Debian 13 and two packages: a minute or two)…"
    step "the image $NAME made: Debian 13, corosync-qnetd, openssh-server (--show image)" build || return 1
  fi
  step "the container $NAME started: on this machine's own network, restarted with docker; the vote on TCP $QNETD_PORT, the container's own SSH server on TCP $PORT for the container's root (not this machine's), $([ -n "$KEY" ] && echo "by the node's key only" || echo "with a one-time password until a node has left its key")" start || return 1
  [ $RUN = 1 ] || return 0
  local i=0; until in_container "$PROBE_PORT" && in_container "$PORT"; do i=$((i + 1)); [ $i -lt "$WAIT" ] || break; sleep 1; done
  if in_container "$PROBE_PORT" && in_container "$PORT"; then ok "the container answers on TCP $QNETD_PORT (the vote) and TCP $PORT (SSH)"
  else bad "the container does not answer on TCP $QNETD_PORT and $PORT. Its last lines: $(docker logs --tail 5 "$NAME" 2>&1 | tr '\n' ' ')"; fi
}
steps() {
  echo "== the third vote on $(hostname), $([ $MODE = apt ] && echo "from Debian's package" || echo "in a container") ($([ $RUN = 1 ] && echo RUN || echo "report only: nothing is changed")) =="
  "${MODE}_steps"; [ $FAILS = 0 ]
}

if [ $RUN = 0 ]; then
  steps || { echo "== $FAILS FAIL — nothing was changed =="; exit 1; }
  echo "REPORT ONLY — nothing was changed."
  [ $ASK = 1 ] || { echo "   To do it: the same line with --run at its end."; exit 0; }
  printf '   Go ahead? [y/N]: '; read -r ANS || ANS=n
  case "$ANS" in y|Y|yes|Yes|YES) echo; RUN=1;; *) echo "   Nothing was changed."; exit 0;; esac
fi
steps || { echo "== $FAILS FAIL =="; exit 1; }
A=$(addresses); ADDR="<this machine's address>"
# shellcheck disable=SC2086  # the addresses, as words
set -- $A; [ $# != 1 ] || ADDR=$1
echo "== this machine is ready to vote. Now, on ONE of the cluster's nodes, as root:"
echo
echo "      $GET_LINE --third-vote $ADDR$([ $MODE = docker ] && echo " --third-vote-port $PORT")"
echo
if [ -n "$KEY" ]; then echo "   It asks for no password: that node's key is let in here."
elif [ $MODE = docker ]; then
  echo "   It asks once for this password:    $PW"
  echo "   The password is good until that node has left its key here, 30 minutes at most. This line again: a new one."
  echo "   It is the password of root INSIDE the container, on TCP $PORT. Nothing of this machine was changed: not its"
  echo "   root, not its passwords, not its SSH server."
else echo "   It asks once for root's password of this machine."; fi
[ $# = 1 ] || [ -z "$A" ] || echo "   This machine's addresses (the one the nodes reach): $A"
