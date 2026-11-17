#!/usr/bin/env bash
# tests/vote-real.sh — the cluster's third vote with the REAL programs. Not one of tests/run.sh's files: it needs
# docker, the network (Debian's packages), and TCP 5403 and 22522 free on the docker host. Linux or macOS:
#   bash tests/vote-real.sh
# Real: vote/install.sh --docker --run (the image is made, the container started); then, in a Debian 13 container
# that stands in for a Proxmox node (tests/vote-node.sh): the node's key left there with the one-time password; the
# commands `pvecm qdevice setup` runs toward the vote's machine, over SSH on the container's port; a corosync node
# whose corosync-qdevice asks the container for its vote, with certificates from that exchange; and a login with
# another key. The SSH host key the line carries is the container's, and ssh refuses another. Then the SSH server
# closes by itself (the times shortened here); the container restarted: still closed; vote/install.sh again:
# replaced, its certificates kept, an SSH server again. Then the password's own ends, each tried with a real login:
# good while it is fresh, dead once its time is over (shortened here), and dead after a restart of the container.
# Not real: pvecm itself and a Proxmox cluster (two nodes, /etc/pve): host/qdevice.sh has only tests/t-vote.sh's fakes.
. "$(dirname "$0")/lib.sh"
VOTE_TOOL="$KIT/vote/install.sh"
export ZRADIO_VOTE_NAME=zradio-vote-test
PORT=22522
if ! docker info >/dev/null 2>&1; then      # no docker on a developer's machine: nothing to test. In CI that is a failure, not a pass
  [ -z "${CI:-}" ] || check "docker answers here (CI: this test must run)" false
  echo "SKIP  docker does not answer here: nothing was tested"; finish; exit
fi
cleanup() { docker rm -f "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker volume rm "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker rmi "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker rm -f "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker volume rm "$ZRADIO_VOTE_NAME" >/dev/null 2>&1     # what an interrupted run left
ssh-keygen -q -t rsa -b 3072 -N '' -C root@node -f "$T/id_rsa" || { echo "ssh-keygen failed"; exit 2; }      # the node's key, as a Proxmox node has one
cp "$TESTS_DIR/vote-node.sh" "$T/"; chmod 755 "$T"; chmod 644 "$T/id_rsa"      # the node's container reads them as its own root
printf '#!/bin/sh\nprintf "%%s\\n" "$PW"\n' > "$T/ask"; chmod 755 "$T/ask"      # what ssh asks for a password (login, below)
ca() { docker exec "$ZRADIO_VOTE_NAME" sh -c 'cat /etc/corosync/qnetd/nssdb/qnetd-cacert.crt /etc/corosync/qnetd/ssh_host_ed25519_key.pub' 2>/dev/null; }

pw() { sed -n 's/.*this password: *//p' "$1"; }
hk() { sed -n 's/.* --third-vote-hostkey \([A-Za-z0-9+/=]*\)$/\1/p' "$1"; }       # the host key at the end of the line for a node
ssh_port() { docker exec "$ZRADIO_VOTE_NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" >/dev/null 2>&1; }      # the SSH port answers
until_() { local n=$1 i=0; shift; until "$@"; do i=$((i + 1)); [ "$i" -lt "$n" ] || return 1; sleep 1; done; }      # until_ <seconds> <command…>: wait for it, no longer
qnetd_up() { docker exec "$ZRADIO_VOTE_NAME" corosync-qnetd-tool -s 2>&1 | grep "TLS:.*Supported" >/dev/null; }
said() { docker logs "$ZRADIO_VOTE_NAME" 2>&1 | grep -- "$1" >/dev/null; }      # the container's log has that line
login() { # login <password>: ONE login as root with that password at the container's SSH server, by a real ssh (the
  # one in the vote's own image, in a container beside it; ssh has the password from $T/ask). Prints IN, or ssh's lines.
  docker run --rm --network host -v "$T":/t:ro --entrypoint ssh -e "PW=$1" -e SSH_ASKPASS=/t/ask -e SSH_ASKPASS_REQUIRE=force "$ZRADIO_VOTE_NAME" \
    -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
    -p "$PORT" root@127.0.0.1 echo IN 2>&1 < /dev/null
}
export ZRADIO_VOTE_SETTLE_S=20 ZRADIO_VOTE_OPEN_S=600      # the SSH server's times, shortened: 20 s after a certificate is signed

echo "-- vote/install.sh --docker --run: the container, and its one-time password"
bash "$VOTE_TOOL" --docker --ssh-port "$PORT" --run > "$T/out" 2>&1 < /dev/null; RC=$?
check "exit 0, made and started, both ports answer, the line for a node with the port, a password" bash -c '[ "$2" = 0 ] && grep -q "DONE  the image" "$1/out" && grep -q "DONE  the container" "$1/out" && grep -q "OK    the container answers on TCP 5403 (the vote) and TCP '"$PORT"' (SSH)" "$1/out" && grep -q -- "--third-vote-port '"$PORT"'" "$1/out" && [ -n "$3" ]' _ "$T" "$RC" "$(pw "$T/out")"; [ "$FAIL" = 0 ] || cat "$T/out"
# no command: docker writes that as null or as [], by its version (28.0.4: [], 28.5 and 29: null)
check "the image: the entrypoint and no command after it, the volume, the label of what it was made from; the container it was made in is gone" bash -c 'c=$(docker inspect --type image -f "{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.Volumes}}" "$1"); echo "   the image: $c"; { [ "$c" = "[\"/entrypoint.sh\"] null {\"/etc/corosync/qnetd\":{}}" ] || [ "$c" = "[\"/entrypoint.sh\"] [] {\"/etc/corosync/qnetd\":{}}" ]; } && [[ "$(docker inspect --type image -f "{{ index .Config.Labels \"zradio.recipe\" }}" "$1")" =~ ^[0-9]+$ ]] && ! docker inspect --type container "$1-build" >/dev/null 2>&1' _ "$ZRADIO_VOTE_NAME"
check "no key of any kind is in the image: no certificate database, no SSH host key (both are made in the volume, at the first start)" bash -c 'docker run --rm --entrypoint sh "$1" -c "[ ! -e /etc/corosync/qnetd/nssdb ] && ! ls /etc/ssh/ssh_host_* >/dev/null 2>&1 && ! ls /etc/corosync/qnetd/ssh_host_* >/dev/null 2>&1"' _ "$ZRADIO_VOTE_NAME"
# (docker writes the capability as NET_RAW or as CAP_NET_RAW, by its version)
check "the container may not gain privileges and has no raw sockets; the password is not in its command line" bash -c 'o=$(docker inspect -f "{{.HostConfig.SecurityOpt}} {{.HostConfig.CapDrop}}" "$1"); echo "   the container: $o"; { [ "$o" = "[no-new-privileges] [NET_RAW]" ] || [ "$o" = "[no-new-privileges] [CAP_NET_RAW]" ]; } && ! docker inspect -f "{{.Path}} {{.Args}}" "$1" | grep -q "$2"' _ "$ZRADIO_VOTE_NAME" "$(pw "$T/out")"
check "corosync-qnetd runs in it and takes TLS clients" bash -c 'docker exec "$1" corosync-qnetd-tool -s 2>&1 | grep -q "TLS:.*Supported"' _ "$ZRADIO_VOTE_NAME"
check "the container restarts by itself, and is on the machine's own network" bash -c '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.NetworkMode}}" "$1")" = "unless-stopped host" ]' _ "$ZRADIO_VOTE_NAME"
CA1=$(ca)

echo "-- a node (Debian 13, the real ssh, scp, ssh-copy-id, certificate tools, corosync and corosync-qdevice)"
check "the line for a node ends with the container's own SSH host key" bash -c '[ -n "$2" ] && [ "$2" = "$(docker exec "$1" cat /etc/corosync/qnetd/ssh_host_ed25519_key.pub | cut -d" " -f2)" ]' _ "$ZRADIO_VOTE_NAME" "$(hk "$T/out")"
node_run() { docker run --rm --network host --privileged --shm-size 256m -v "$T":/t:ro debian:13-slim bash /t/vote-node.sh 127.0.0.1 "$PORT" "$1" "$2" "$3" > "$T/node.out" 2>&1; }
node_run realtest "$(pw "$T/out")" "$(hk "$T/out")"
check "the host key from the line: ssh refuses a machine with another key, and works with this one pinned (StrictHostKeyChecking=yes)" has "$T/node.out" "HOSTKEY OK"
check "the door: shut for a key and for a wrong password; the one-time password lets ssh-copy-id leave the node's key; then the password is dead" has "$T/node.out" "DOOR OK"; [ "$FAIL" = 0 ] || cat "$T/node.out"
check "pvecm's certificate exchange, command for command, over SSH on the port from root's ssh config" has "$T/node.out" "EXCHANGE OK"
check "a corosync node alone has 1 of 2 votes; with its corosync-qdevice connected to the container it has 2 and is quorate" bash -c 'grep -q "ALONE: 1 of 2 votes" "$1" && grep -q "VOTE OK" "$1"' _ "$T/node.out"
check "the certificate the container signed for that cluster is in its volume" docker exec "$ZRADIO_VOTE_NAME" test -s /etc/corosync/qnetd/nssdb/cluster-realtest.crt
check "root with another key, or with none, is refused" has "$T/node.out" "REFUSAL OK"

echo "-- the SSH server was for the setup: it closes by itself once a cluster's certificate is signed"
until_ 45 said "the SSH server is closed"
check "closed a short while after the setup, and said why; the vote goes on" bash -c 'docker logs "$1" 2>&1 | grep -q "the SSH server is closed (a cluster.s certificate was signed: the setup is done)" && docker exec "$1" corosync-qnetd-tool -s 2>&1 | grep -q "TLS:.*Supported"' _ "$ZRADIO_VOTE_NAME"
check "nothing answers on its SSH port any more" bash -c '! docker exec "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$2" 2>/dev/null' _ "$ZRADIO_VOTE_NAME" "$PORT"

echo "-- the container restarted (the machine rebooted): the vote is back, the used password is not, and no SSH server"
docker restart "$ZRADIO_VOTE_NAME" >/dev/null; until_ 20 qnetd_up
check "after the restart there is still no SSH server (it is closed for this run of the installer), and the container says so" bash -c 'docker logs "$1" 2>&1 | grep -q "no SSH server: it was closed after the setup" && ! docker exec "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$2" 2>/dev/null' _ "$ZRADIO_VOTE_NAME" "$PORT"
check "corosync-qnetd answers again, with the same certificate authority and SSH host key" bash -c 'docker exec "$1" corosync-qnetd-tool -s 2>&1 | grep -q "TLS:.*Supported" && [ -n "$2" ] && [ "$2" = "$3" ]' _ "$ZRADIO_VOTE_NAME" "$CA1" "$(ca)"

echo "-- vote/install.sh again: the container replaced, its certificates kept, a new password"
OLD=$(pw "$T/out"); IMG=$(docker images -q "$ZRADIO_VOTE_NAME")
ZRADIO_VOTE_PW_S=20 bash "$VOTE_TOOL" --docker --ssh-port "$PORT" --run > "$T/out2" 2>&1 < /dev/null; RC=$?      # the password's time: 20 s, not 30 minutes
check "exit 0, the old container removed first; the image is the same one, not made again" bash -c '[ "$2" = 0 ] && grep -q "DONE  the container .* that is here removed" "$1/out2" && grep -q "OK    the image .* is here" "$1/out2" && [ -n "$3" ] && [ "$3" = "$(docker images -q "$4")" ]' _ "$T" "$RC" "$IMG" "$ZRADIO_VOTE_NAME"; [ "$FAIL" = 0 ] || cat "$T/out2"
check "the same certificate authority and the same SSH host key as before" bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$CA1" "$(ca)"
check "another password than the first" bash -c '[ -n "$2" ] && [ "$1" != "$2" ]' _ "$OLD" "$(pw "$T/out2")"
check "an SSH server again, with the same host key in the line" bash -c 'docker exec "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$2" 2>/dev/null && [ -n "$3" ] && [ "$3" = "$4" ]' _ "$ZRADIO_VOTE_NAME" "$PORT" "$(hk "$T/out")" "$(hk "$T/out2")"

echo "-- the one-time password, tried with real logins: good while fresh, dead when its time is over, dead after a restart"
check "the first password is dead in the new container: Permission denied" bash -c 'printf "%s\n" "$1" | grep -q "Permission denied" && ! printf "%s\n" "$1" | grep -qx IN' _ "$(login "$OLD")"
L=$(login "$(pw "$T/out2")")
check "the new one gets root in (no key was left: it stays good until its time is over)" eq "$L" IN
until_ 40 said "the one-time password is off"
L=$(login "$(pw "$T/out2")")
check "its time is over (20 s here, 30 minutes for a user) and nobody left a key: the container says the password is off, the same login is refused, and the SSH server is still there for a key" bash -c 'printf "%s\n" "$1" | grep -q "Permission denied" && ! printf "%s\n" "$1" | grep -qx IN && docker logs "$2" 2>&1 | grep -q "the one-time password is off" && docker exec "$2" bash -c "exec 3<>/dev/tcp/127.0.0.1/$3" 2>/dev/null' _ "$L" "$ZRADIO_VOTE_NAME" "$PORT"; [ "$FAIL" = 0 ] || { echo "$L"; docker logs --tail 8 "$ZRADIO_VOTE_NAME"; }
bash "$VOTE_TOOL" --docker --ssh-port "$PORT" --run > "$T/out3" 2>&1 < /dev/null; RC=$?
check "vote/install.sh a third time, while the container's SSH server is open on that very port: the port is the container's own, so no refusal; replaced, exit 0" bash -c '[ "$2" = 0 ] && ! grep -q "is in use" "$1/out3" && grep -q "DONE  the container .* that is here removed" "$1/out3" && grep -q "OK    the container answers" "$1/out3"' _ "$T" "$RC"; [ "$FAIL" = 0 ] || cat "$T/out3"
L=$(login "$(pw "$T/out3")")
check "its password gets root in" eq "$L" IN
docker restart "$ZRADIO_VOTE_NAME" >/dev/null; until_ 20 ssh_port
L=$(login "$(pw "$T/out3")")
check "the container restarted before any node came (the machine rebooted): an SSH server again, and the password, 30 minutes young, is refused — it was marked as used at the first start" bash -c 'printf "%s\n" "$1" | grep -q "Permission denied" && ! printf "%s\n" "$1" | grep -qx IN && docker exec "$2" bash -c "exec 3<>/dev/tcp/127.0.0.1/$3" 2>/dev/null' _ "$L" "$ZRADIO_VOTE_NAME" "$PORT"; [ "$FAIL" = 0 ] || { echo "$L"; docker logs --tail 8 "$ZRADIO_VOTE_NAME"; }
finish
