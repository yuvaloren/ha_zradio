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
#           after a restart. That SSH server is for the setup: it closes by itself two minutes after a node has set
#           the vote up, an hour after this run at the latest, and stays closed until this script runs again.
#           Nothing of the machine itself is changed. The certificates live in the docker volume
#           zradio-vote and survive a rebuild. The image is made with docker run, cp and commit, not docker build: a
#           NAS's docker has no buildx, and docker build without it is the legacy builder docker is retiring. It is
#           made again when the kit makes it differently, or when Debian has a newer base image (asked at each --run).
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
# To remove the vote: `pvecm qdevice remove` on a node (and this machine's line out of that node's
# /root/.ssh/known_hosts); then here `docker rm -f zradio-vote && docker volume rm zradio-vote && docker rmi
# zradio-vote`, or `apt-get purge corosync-qnetd` (and a --key line out of root's authorized_keys).
# Tests: tests/t-vote.sh (fakes), tests/vote-real.sh (docker and the real programs), tests/vote-bash.sh (bash 3.2 and
# 4.4). Bash 3.2 or later. Env for the tests: ZRADIO_VOTE_NAME, ZRADIO_VOTE_SSH_DIR, ZRADIO_VOTE_HOSTKEY_FILE,
# ZRADIO_VOTE_QNETD_PORT, ZRADIO_VOTE_WAIT, ZRADIO_VOTE_ASK, ZRADIO_VOTE_PW, ZRADIO_VOTE_PATH, and the container's
# times in seconds: ZRADIO_VOTE_OPEN_S, ZRADIO_VOTE_SETTLE_S, ZRADIO_VOTE_PW_S.
set -uo pipefail
NAME=${ZRADIO_VOTE_NAME:-zradio-vote}                 # the container, its image and its volume
SSH_DIR=${ZRADIO_VOTE_SSH_DIR:-/root/.ssh}
HOSTKEY_FILE=${ZRADIO_VOTE_HOSTKEY_FILE:-/etc/ssh/ssh_host_ed25519_key.pub}      # Debian's package: this machine's own SSH host key
QNETD_PORT=5403                                        # corosync-qnetd's port
PROBE_PORT=${ZRADIO_VOTE_QNETD_PORT:-$QNETD_PORT}      # where the checks below look for it (the tests: another port)
WAIT=${ZRADIO_VOTE_WAIT:-20}                           # seconds to wait for it to answer
GET_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
KEY="" PORT=2222 DOCKER=0 RUN=0 FAILS=0 PW=""
ok() { printf '   OK    %s\n' "$*"; }
note() { printf '   NOTE  %s\n' "$*"; }
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
# no key of any kind in the image: the package makes a certificate authority, and that one belongs in the volume,
# made at the container's first start (the entrypoint), as the SSH host key is
rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* /etc/corosync/qnetd/nssdb
EOF
}
entrypoint() { cat <<'EOF'
#!/bin/sh
# zradio-vote: what runs in the container. The volume (/etc/corosync/qnetd) keeps the arbiter's certificates and the
# SSH server's host key.
# Who gets in as root over SSH, one of:
#   ZRADIO_VOTE_KEY       that public key, and nothing else
#   ZRADIO_VOTE_PASSWORD  that password, ONCE: from this start until a key has been left (ssh-copy-id), 30 minutes
#                         at most ($ZRADIO_VOTE_PW_S s, 1800). It is marked as used in the volume before the door
#                         opens, so a restart of the container never opens it again.
# For how long there is an SSH server at all: it is for the setup (pvecm qdevice setup, from a node). It closes
# $ZRADIO_VOTE_SETTLE_S s (120) after the vote signed a cluster's certificate, and $ZRADIO_VOTE_OPEN_S s (3600) after
# this start at the latest. That it is closed is written into the volume for this run of the installer
# (ZRADIO_VOTE_RUN), so a restart of the container does not open it again; the installer's next run does.
# Once it is closed, the SSH server and the loop that closed it stay in the process list as two dead entries, until
# the container restarts: corosync-qnetd is process 1 here, and it does not collect children that are not its own.
# They hold a process number each and nothing else. Left so on purpose: docker's --init would collect them, but
# needs docker-init on the machine, which a NAS's docker may lack; and a shell kept as process 1 to do it would
# have to hand docker's stop signal on to corosync-qnetd.
set -eu
D=/etc/corosync/qnetd
[ -f "$D/nssdb/qnetd-cacert.crt" ] || corosync-qnetd-certutil -i
[ -f "$D/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/ssh_host_ed25519_key"
mkdir -p /run/sshd /run/corosync-qnetd /root/.ssh
chmod 700 /root/.ssh
OPEN_S=${ZRADIO_VOTE_OPEN_S:-3600} SETTLE_S=${ZRADIO_VOTE_SETTLE_S:-120} PW_S=${ZRADIO_VOTE_PW_S:-1800} RUN_ID=${ZRADIO_VOTE_RUN:-}
ROOT=prohibit-password BY_PASSWORD=no PW_OPEN=0
if [ -n "${ZRADIO_VOTE_KEY:-}" ]; then
  printf '%s\n' "$ZRADIO_VOTE_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
elif [ -n "${ZRADIO_VOTE_PASSWORD:-}" ]; then
  MARK=$(printf '%s' "$ZRADIO_VOTE_PASSWORD" | sha256sum)
  if [ "$(cat "$D/password-used" 2>/dev/null || true)" = "$MARK" ]; then usermod -p '*' root      # a restart: that password is used up, here too
  else
    printf '%s\n' "$MARK" > "$D/password-used"
    echo "root:$ZRADIO_VOTE_PASSWORD" | chpasswd
    ROOT=yes BY_PASSWORD=yes PW_OPEN=1
  fi
fi
if [ -n "$RUN_ID" ] && [ "$(cat "$D/door-closed" 2>/dev/null || true)" = "$RUN_ID" ]; then
  echo "zradio-vote: no SSH server: it was closed after the setup (or after its hour). The kit's install line on this machine opens one again"
else
  : > /run/zradio-vote-start
  /usr/sbin/sshd -D -e -p "$ZRADIO_VOTE_SSH_PORT" -h "$D/ssh_host_ed25519_key" \
    -o PasswordAuthentication=$BY_PASSWORD -o KbdInteractiveAuthentication=no -o PermitRootLogin=$ROOT \
    -o PerSourcePenalties=no &      # the one client is the node: a mistyped password must not lock it out for minutes
  SSHD=$!
  sleep 1
  kill -0 $SSHD 2>/dev/null || { echo "zradio-vote: the SSH server did not start (is TCP port $ZRADIO_VOTE_SSH_PORT in use?)" >&2; exit 1; }
  ( n=0 end=$OPEN_S pw=$PW_OPEN signed=0
    while [ $n -lt $end ]; do
      sleep 2; n=$((n + 2))
      if [ $pw = 1 ] && { [ -s /root/.ssh/authorized_keys ] || [ $n -ge $PW_S ]; }; then
        usermod -p '*' root; pw=0; echo "zradio-vote: the one-time password is off"
      fi
      if [ $signed = 0 ] && [ -n "$(find "$D/nssdb" -name 'cluster-*.crt' -newer /run/zradio-vote-start 2>/dev/null | head -n 1)" ]; then
        signed=1; [ $((n + SETTLE_S)) -ge $end ] || end=$((n + SETTLE_S))      # a cluster's certificate was signed: the setup is through
      fi
    done
    [ $pw = 0 ] || usermod -p '*' root
    [ -z "$RUN_ID" ] || printf '%s\n' "$RUN_ID" > "$D/door-closed"
    kill $SSHD 2>/dev/null || true
    echo "zradio-vote: the SSH server is closed ($([ $signed = 1 ] && echo "a cluster's certificate was signed: the setup is done" || echo "nobody set the vote up in $OPEN_S s")). The kit's install line on this machine opens one again"
  ) &
fi
exec corosync-qnetd -f
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in --key|--ssh-port|--show) [ $# -ge 2 ] || die "$1 needs a value (--help)";; esac
  case "$1" in
  -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" 2>/dev/null | sed '$d'; exit 0;;
  --key) KEY=$2; shift 2;; --ssh-port) PORT=$2; shift 2;; --docker) DOCKER=1; shift;; --run) RUN=1; shift;;
  --show) case "${2:-}" in image) image;; entrypoint) entrypoint;; *) die "--show image|entrypoint";; esac; exit 0;;
  *) echo "unknown option: $1" >&2; exit 2;; esac; done
ASK=0; if { [ -t 0 ] && [ -t 1 ]; } || [ "${ZRADIO_VOTE_ASK:-0}" = 1 ]; then ASK=1; fi
KEY_RE='^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [A-Za-z0-9@._:+-]+)?$'
[ -z "$KEY" ] || [[ "$KEY" =~ $KEY_RE ]] || die "--key: not one public key line (type, key, and at most a one-word comment)"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && PORT=$((10#$PORT)) && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && [ "$PORT" != "$QNETD_PORT" ] || die "--ssh-port '$PORT': a TCP port, and not $QNETD_PORT (the vote's own)"
# where a NAS keeps docker (sudo there drops it from PATH), and where sshd is (su without a login leaves /usr/sbin out)
PATH=$PATH:${ZRADIO_VOTE_PATH-/usr/local/bin:/var/packages/ContainerManager/target/usr/bin:/usr/sbin:/sbin}
if [ $DOCKER = 0 ] && command -v apt-get >/dev/null 2>&1; then MODE=apt
elif command -v docker >/dev/null 2>&1; then MODE=docker
elif [ $DOCKER = 1 ]; then die "--docker: there is no docker on this machine"
else die "this machine has neither apt-get nor docker: the vote needs one of the two"; fi

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }      # something on this machine listens on that TCP port
addresses() { # this machine's own IPv4 addresses: not docker's bridges, not self-assigned ones
  ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ && $4 !~ /^169\.254\./ { sub(/\/.*/, "", $4); printf "%s ", $4 }'
}
apt_install() { # (the lists first: a freshly installed machine has none. A list that does not load is apt-get install's to say)
  apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qnetd >/dev/null
}
add_key() { # a line of its own: a file that ends without a newline gets one first
  local f="$SSH_DIR/authorized_keys"
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR" || return 1
  [ ! -s "$f" ] || [ -z "$(tail -c 1 "$f")" ] || echo >> "$f" || return 1
  printf '%s\n' "$KEY" >> "$f" && chmod 600 "$f"
}
base_id() { docker inspect --type image -f '{{.Id}}' "$BASE" 2>/dev/null; }      # the base image this machine holds: nothing, or its id
made_from() { docker inspect --type image -f '{{ index .Config.Labels "zradio.base" }}' "$NAME" 2>/dev/null; }      # the base our image was made from
recipe() { # what the image is made from, as one number. Where this machine no longer holds the base (deleted: it looks
  # unused in a NAS's list of images), the one our image names stands in: the image is whole without its base.
  local b; b=$(base_id); [ -n "$b" ] || b=$(made_from)
  { echo "$BASE"; echo "$b"; image; entrypoint; } | cksum | tr -d ' \t'
}
built() { local r; r=$(recipe); [ -n "$r" ] && [ "$(docker inspect --type image -f '{{ index .Config.Labels "zradio.recipe" }}' "$NAME" 2>/dev/null)" = "$r" ]; }
build() { # the image, with no builder: a container of $BASE that installs the packages, the entrypoint copied in, a commit
  local b=$NAME-build t old rc=1; OLD_IMAGE=""
  t=$(mktemp -d) || return 1
  entrypoint > "$t/entrypoint.sh"; chmod 0755 "$t/entrypoint.sh"
  old=$(docker images -q "$NAME" 2>/dev/null)
  docker rm -f "$b" >/dev/null 2>&1
  if docker run --name "$b" "$BASE" sh -c "$(image)" > "$t/log" 2>&1 \
     && docker cp "$t/entrypoint.sh" "$b:/entrypoint.sh" >> "$t/log" 2>&1 \
     && docker commit -c 'VOLUME /etc/corosync/qnetd' -c 'ENTRYPOINT ["/entrypoint.sh"]' -c 'CMD []' -c "LABEL zradio.recipe=$(recipe)" -c "LABEL zradio.base=$(base_id)" "$b" "$NAME" >> "$t/log" 2>&1
  then rc=0; [ -z "$old" ] || [ "$old" = "$(docker images -q "$NAME" 2>/dev/null)" ] || OLD_IMAGE=$old      # the image before this one: removed once no container runs on it
  else tail -5 "$t/log" | sed 's/^/      | /'; fi
  docker rm -f "$b" >/dev/null 2>&1; rm -rf "$t"; return $rc
}
remove() { docker rm -f "$NAME" >/dev/null; }
password() { # twelve letters and digits that are not mistaken for one another, in three groups
  local p; p=${ZRADIO_VOTE_PW:-$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'a-hjkmnp-z2-9')}; p=${p:0:12}      # a bounded read: no pipe is cut short
  [ ${#p} = 12 ] && printf '%s-%s-%s' "${p:0:4}" "${p:4:4}" "${p:8:4}"
}
start() { # the node gets in with --key's key, or with a one-time password made up here
  # The password goes to docker in the environment, by name: on the command line every user of this machine could
  # read it (ps). The container may not gain privileges, and has no raw sockets on the machine's network.
  # ZRADIO_VOTE_RUN names this run: the container writes it into the volume when it closes its SSH server, so that a
  # restart keeps it closed and the next run of this script opens one again.
  local who=ZRADIO_VOTE_KEY knobs=() k
  if [ -n "$KEY" ]; then export ZRADIO_VOTE_KEY="$KEY"; else PW=$(password) && [ -n "$PW" ] || return 1; export ZRADIO_VOTE_PASSWORD="$PW"; who=ZRADIO_VOTE_PASSWORD; fi
  ZRADIO_VOTE_RUN=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9'); export ZRADIO_VOTE_RUN=${ZRADIO_VOTE_RUN:0:16}
  [ ${#ZRADIO_VOTE_RUN} = 16 ] || return 1
  for k in ZRADIO_VOTE_OPEN_S ZRADIO_VOTE_SETTLE_S ZRADIO_VOTE_PW_S; do [ -z "${!k:-}" ] || knobs+=(-e "$k"); done      # the tests' shorter times
  docker run -d --name "$NAME" --restart unless-stopped --network host --cap-drop NET_RAW --security-opt no-new-privileges \
    -v "$NAME:/etc/corosync/qnetd" -e "$who" -e ZRADIO_VOTE_RUN -e "ZRADIO_VOTE_SSH_PORT=$PORT" ${knobs[@]+"${knobs[@]}"} "$NAME" >/dev/null
}
host_key() { # the SSH host key the node will meet (ed25519, its base64 part), for the line the node runs: nothing or a key
  local k
  if [ $MODE = docker ]; then k=$(docker exec "$NAME" cat /etc/corosync/qnetd/ssh_host_ed25519_key.pub 2>/dev/null)
  else k=$(cat "$HOSTKEY_FILE" 2>/dev/null); fi
  k=$(printf '%s\n' "$k" | awk '$1 == "ssh-ed25519" { print $2; exit }')
  [[ "$k" =~ ^AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]{40,60}=*$ ]] && printf '%s' "$k"
}
# the port answers, seen from inside: the container is on the machine's own network, so that is this machine's
# loopback. It says that the two programs run; that a node reaches them from the LAN is the node's check (host/qdevice.sh)
in_container() { docker exec "$NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
ssh_here() { # ssh_here <port>: the SSH server of the container that is here listens on that port (it goes with the container)
  docker exec "$NAME" sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\000" " "' 2>/dev/null | grep "sshd -D -e -p $1 " >/dev/null      # (not grep -q: it would leave the pipe early)
}

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
  local there=0; ! docker inspect --type container "$NAME" >/dev/null 2>&1 || there=1
  # The two ports are free, or held by the container that is here, which goes before the new one starts. The vote's
  # port is taken to be that container's. The SSH port is looked at: --ssh-port may name another one this time, and
  # the container's SSH server may have closed long ago, with something else on its port since. A container started
  # on a taken port would end and be restarted by docker, for ever.
  [ $there = 1 ] || ! port_open "$PROBE_PORT" || bad "TCP port $QNETD_PORT is in use on this machine (another corosync-qnetd?): the vote needs it"
  ! port_open "$PORT" || { [ $there = 1 ] && ssh_here "$PORT"; } || bad "TCP port $PORT is in use on this machine$([ $there = 0 ] || echo " (not by the container $NAME that is here)"): another one with --ssh-port"
  [ $FAILS = 0 ] || { [ $there = 0 ] || echo "         The container $NAME that is here was not touched: it goes on as it was."; return 1; }
  # Debian's base image as the registry has it now, not whatever this machine holds under that name: the image is
  # made from it, and made again when it is a newer one (the packages in the image are as old as its base)
  # (no -q: docker before 19.03 does not know it for pull, and a NAS may have one)
  local base_was; base_was=$(base_id)
  if [ $RUN = 1 ] && ! docker pull "$BASE" >/dev/null 2>&1 && [ -n "$(base_id)" ]; then
    note "the registry was not reached for a newer $BASE: the one this machine holds is used"
  fi
  # the image first: a vote that is in service is not taken down for an image that then cannot be made
  if built; then ok "the image $NAME is here, as this version of the kit makes it$([ $RUN = 1 ] || echo " from the $BASE this machine holds (--run asks the registry for a newer one)")"
  else
    [ $RUN = 0 ] || echo "   making the image (Debian 13 and two packages: a minute or two)…"
    step "the image $NAME made: Debian 13, corosync-qnetd, openssh-server (--show image)" build || { [ $there = 0 ] || echo "         The container $NAME that is here was not touched: it goes on as it was."; return 1; }
  fi
  [ $there = 0 ] || step "the container $NAME that is here removed (its certificates stay, in the volume $NAME)" remove || return 1
  step "the container $NAME started: on this machine's own network, restarted with docker; the vote on TCP $QNETD_PORT, the container's own SSH server on TCP $PORT for the container's root (not this machine's), $([ -n "$KEY" ] && echo "by the node's key only" || echo "with a one-time password until a node has left its key")" start || return 1
  [ $RUN = 1 ] || return 0
  # the image before this one, and the base it was made from: nothing runs on them now (docker removes no image that
  # is in use, and says nothing of it here: another container of this machine may hold the base)
  [ -z "${OLD_IMAGE:-}" ] || docker rmi "$OLD_IMAGE" >/dev/null 2>&1 || true
  [ -z "$base_was" ] || [ "$base_was" = "$(base_id)" ] || docker rmi "$base_was" >/dev/null 2>&1 || true
  local i=0; until in_container "$PROBE_PORT" && in_container "$PORT"; do i=$((i + 1)); [ $i -lt "$WAIT" ] || break; sleep 1; done
  if in_container "$PROBE_PORT" && in_container "$PORT"; then ok "the container answers on TCP $QNETD_PORT (the vote) and TCP $PORT (SSH), asked on this machine itself. Whether a node reaches them (a firewall here?) is checked by the line below, on the node"
  else
    bad "the container does not answer on TCP $QNETD_PORT and $PORT. Its last lines: $(docker logs --tail 5 "$NAME" 2>&1 | tr '\n' ' ')"
    # One that ends and is started again by docker is not left there: with its restart policy that would go on for
    # ever, each start with nothing to give. One that runs and was never restarted stays: it may only be slow, or its
    # SSH server may listen where this probe does not look, and the vote itself may be in service.
    if [ "$(docker inspect --type container -f '{{.State.Running}} {{.RestartCount}}' "$NAME" 2>/dev/null)" = "true 0" ]; then
      echo "         It runs, docker has not restarted it, and it was left there. Look again in a minute (this line once more: it changes nothing that is right), or read: docker logs $NAME"
    else
      ! remove 2>/dev/null || echo "         It was removed again: left there, docker would restart it for ever. Its certificates stay in the volume $NAME$([ $there = 0 ] || echo "; the vote that was in service here is down until this line has run again")."
    fi
  fi
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
SSHP=$PORT; [ $MODE = docker ] || SSHP=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')      # Debian's package: this machine's own SSH server
HK=$(host_key) || HK=""
echo "      $GET_LINE --third-vote $ADDR$([ "${SSHP:-22}" = 22 ] || echo " --third-vote-port $SSHP")${HK:+ --third-vote-hostkey $HK}"
echo
if [ -n "$KEY" ]; then echo "   It asks for no password: that node's key is let in here."
elif [ $MODE = docker ]; then
  echo "   It asks once for this password:    $PW"
  echo "   The password is good until that node has left its key here, 30 minutes at most. This line again: a new one."
  echo "   It is the password of root INSIDE the container, on TCP $PORT. Nothing of this machine was changed: not its"
  echo "   root, not its passwords, not its SSH server."
else echo "   It asks once for root's password of this machine."; fi
[ -z "$HK" ] || echo "   The long word at its end is this $([ $MODE = docker ] && echo "container's" || echo "machine's") SSH host key: the node talks to nobody else."
[ $MODE != docker ] || echo "   The container's SSH server is for this setup: it closes two minutes after a node has set the vote up, an hour
   from now at the latest. This line again opens one."
[ $# = 1 ] || [ -z "$A" ] || echo "   This machine's addresses (the one the nodes reach): $A"
