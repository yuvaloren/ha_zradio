#!/usr/bin/env bash
# tests/vote-real.sh — the cluster's third vote with the REAL programs. Not one of tests/run.sh's files: it needs
# docker, the network (Debian's packages), and TCP 5403 and 22522 free on the docker host. Linux or macOS:
#   bash tests/vote-real.sh
# Real: vote/install.sh --docker --run (the image is made, the container started); then, in a Debian 13 container
# that stands in for a Proxmox node (tests/vote-node.sh): the node's key left there with the one-time password; the
# commands `pvecm qdevice setup` runs toward the vote's machine, over SSH on the container's port; a corosync node
# whose corosync-qdevice asks the container for its vote, with certificates from that exchange; and a login with
# another key. Then the container restarted, and vote/install.sh again: replaced, its certificates kept.
# Not real: pvecm itself and a Proxmox cluster (two nodes, /etc/pve): host/qdevice.sh has only tests/t-vote.sh's fakes.
. "$(dirname "$0")/lib.sh"
VOTE_TOOL="$KIT/vote/install.sh"
export ZRADIO_VOTE_NAME=zradio-vote-test
PORT=22522
if ! docker info >/dev/null 2>&1; then echo "SKIP  docker does not answer here: nothing was tested"; finish; exit; fi
cleanup() { docker rm -f "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker volume rm "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker rmi "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker rm -f "$ZRADIO_VOTE_NAME" >/dev/null 2>&1; docker volume rm "$ZRADIO_VOTE_NAME" >/dev/null 2>&1     # what an interrupted run left
ssh-keygen -q -t rsa -b 3072 -N '' -C root@node -f "$T/id_rsa" || { echo "ssh-keygen failed"; exit 2; }      # the node's key, as a Proxmox node has one
cp "$TESTS_DIR/vote-node.sh" "$T/"; chmod 755 "$T"; chmod 644 "$T/id_rsa"      # the node's container reads them as its own root
ca() { docker exec "$ZRADIO_VOTE_NAME" sh -c 'cat /etc/corosync/qnetd/nssdb/qnetd-cacert.crt /etc/corosync/qnetd/ssh_host_ed25519_key.pub' 2>/dev/null; }

pw() { sed -n 's/.*this password: *//p' "$1"; }

echo "-- vote/install.sh --docker --run: the container, and its one-time password"
bash "$VOTE_TOOL" --docker --ssh-port "$PORT" --run > "$T/out" 2>&1 < /dev/null; RC=$?
check "exit 0, made and started, both ports answer, the line for a node with the port, a password" bash -c '[ "$2" = 0 ] && grep -q "DONE  the image" "$1/out" && grep -q "DONE  the container" "$1/out" && grep -q "OK    the container answers on TCP 5403 (the vote) and TCP '"$PORT"' (SSH)" "$1/out" && grep -q -- "--third-vote-port '"$PORT"'" "$1/out" && [ -n "$3" ]' _ "$T" "$RC" "$(pw "$T/out")"; [ "$FAIL" = 0 ] || cat "$T/out"
# no command: docker writes that as null or as [], by its version (28.0.4: [], 28.5 and 29: null)
check "the image: the entrypoint and no command after it, the volume, the label of what it was made from; the container it was made in is gone" bash -c 'c=$(docker inspect --type image -f "{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.Volumes}}" "$1"); echo "   the image: $c"; { [ "$c" = "[\"/entrypoint.sh\"] null {\"/etc/corosync/qnetd\":{}}" ] || [ "$c" = "[\"/entrypoint.sh\"] [] {\"/etc/corosync/qnetd\":{}}" ]; } && [[ "$(docker inspect --type image -f "{{ index .Config.Labels \"zradio.recipe\" }}" "$1")" =~ ^[0-9]+$ ]] && ! docker inspect --type container "$1-build" >/dev/null 2>&1' _ "$ZRADIO_VOTE_NAME"
check "corosync-qnetd runs in it and takes TLS clients" bash -c 'docker exec "$1" corosync-qnetd-tool -s 2>&1 | grep -q "TLS:.*Supported"' _ "$ZRADIO_VOTE_NAME"
check "the container restarts by itself, and is on the machine's own network" bash -c '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.NetworkMode}}" "$1")" = "unless-stopped host" ]' _ "$ZRADIO_VOTE_NAME"
CA1=$(ca)

echo "-- a node (Debian 13, the real ssh, scp, ssh-copy-id, certificate tools, corosync and corosync-qdevice)"
node_run() { docker run --rm --network host --privileged --shm-size 256m -v "$T":/t:ro debian:13-slim bash /t/vote-node.sh 127.0.0.1 "$PORT" "$1" "$2" > "$T/node.out" 2>&1; }
node_run realtest "$(pw "$T/out")"
check "the door: shut for a key and for a wrong password; the one-time password lets ssh-copy-id leave the node's key; then the password is dead" has "$T/node.out" "DOOR OK"; [ "$FAIL" = 0 ] || cat "$T/node.out"
check "pvecm's certificate exchange, command for command, over SSH on the port from root's ssh config" has "$T/node.out" "EXCHANGE OK"
check "a corosync node alone has 1 of 2 votes; with its corosync-qdevice connected to the container it has 2 and is quorate" bash -c 'grep -q "ALONE: 1 of 2 votes" "$1" && grep -q "VOTE OK" "$1"' _ "$T/node.out"
check "the certificate the container signed for that cluster is in its volume" docker exec "$ZRADIO_VOTE_NAME" test -s /etc/corosync/qnetd/nssdb/cluster-realtest.crt
check "root with another key, or with none, is refused" has "$T/node.out" "REFUSAL OK"

echo "-- the container restarted (the machine rebooted): the vote is back, the used password is not"
docker restart "$ZRADIO_VOTE_NAME" >/dev/null; sleep 3
check "corosync-qnetd answers again, with the same certificate authority and SSH host key" bash -c 'docker exec "$1" corosync-qnetd-tool -s 2>&1 | grep -q "TLS:.*Supported" && [ -n "$2" ] && [ "$2" = "$3" ]' _ "$ZRADIO_VOTE_NAME" "$CA1" "$(ca)"
check "the SSH server takes no password at all now" bash -c 'docker logs "$1" 2>&1 | grep -q "the one-time password is off" && ! docker exec "$1" sh -c "cat /proc/*/cmdline 2>/dev/null | tr \"\\0\" \" \"" | grep -q "PasswordAuthentication=yes"' _ "$ZRADIO_VOTE_NAME"

echo "-- vote/install.sh again: the container replaced, its certificates kept, a new password"
OLD=$(pw "$T/out"); IMG=$(docker images -q "$ZRADIO_VOTE_NAME")
bash "$VOTE_TOOL" --docker --ssh-port "$PORT" --run > "$T/out2" 2>&1 < /dev/null; RC=$?
check "exit 0, the old container removed first; the image is the same one, not made again" bash -c '[ "$2" = 0 ] && grep -q "DONE  the container .* that is here removed" "$1/out2" && grep -q "OK    the image .* is here" "$1/out2" && [ -n "$3" ] && [ "$3" = "$(docker images -q "$4")" ]' _ "$T" "$RC" "$IMG" "$ZRADIO_VOTE_NAME"; [ "$FAIL" = 0 ] || cat "$T/out2"
check "the same certificate authority and the same SSH host key as before" bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$CA1" "$(ca)"
check "another password than the first" bash -c '[ -n "$2" ] && [ "$1" != "$2" ]' _ "$OLD" "$(pw "$T/out2")"
finish
