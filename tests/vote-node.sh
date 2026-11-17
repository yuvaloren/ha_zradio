#!/bin/bash
# tests/vote-node.sh — run by tests/vote-real.sh as root in a Debian 13 container that stands in for a Proxmox node:
#   vote-node.sh <the vote's address> <its SSH port> <cluster name> <the one-time password> <its SSH host key>
#   (the node's key: /t/id_rsa; the host key: the base64 word the vote's line ends with)
# 0. The door: no way in by key yet or with a wrong password. The host key from the line is put into known_hosts as
#    host/qdevice.sh puts it, and ssh then refuses a machine with another key. ssh-copy-id with the password and
#    StrictHostKeyChecking=yes, as host/qdevice.sh runs it (the password typed by sshpass here); then the password is
#    dead.
# 1. What `pvecm qdevice setup <address>` runs toward the vote's machine and on the node itself, command for command
#    (PVE 9.2, PVE/CLI/pvecm.pm, setup_qdevice), with the SSH port in root's ssh config only, as host/qdevice.sh
#    leaves it. Not pvecm itself: that needs a Proxmox node.
# 2. A real corosync (this one node) and corosync-qdevice, with the quorum section pvecm writes: the vote must count.
# 3. Another key, and no key: the vote's SSH server must refuse both. (Done right after 1: the SSH server closes
#    by itself a short while after the certificate was signed.)
set -u
ADDR=$1 PORT=$2 CLUSTER=$3 PASSWORD=$4 HOSTKEY=$5
DB=/etc/corosync/qdevice/net/nssdb
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null 2>&1 && apt-get install -y -q --no-install-recommends corosync corosync-qdevice openssh-client sshpass iproute2 >/dev/null 2>&1 || { echo "apt-get failed in the node's container"; exit 1; }
mkdir -p /root/.ssh && chmod 700 /root/.ssh && cp /t/id_rsa /t/id_rsa.pub /root/.ssh/ && chmod 600 /root/.ssh/id_rsa
echo "Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com" > /root/.ssh/config     # as on a Proxmox node
printf '\nHost %s\n    Port %s\n' "$ADDR" "$PORT" >> /root/.ssh/config

BY_PW=(-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no)
if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$ADDR" true 2>/dev/null; then echo "DOOR FAILED: root got in by key before any key was left"; exit 1; fi
if sshpass -p "not-the-pass-word" ssh "${BY_PW[@]}" "root@$ADDR" true 2>/dev/null; then echo "DOOR FAILED: root got in with a wrong password"; exit 1; fi
# the host key: a machine with another key is refused before anything is typed to it; then the line's key, as host/qdevice.sh pins it
printf '[%s]:%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherMachinesKeyAnotherMachinesKeyAnotherMach\n' "$ADDR" "$PORT" > /tmp/wrong-known
W=$(sshpass -p "$PASSWORD" ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/wrong-known -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 "root@$ADDR" true 2>&1) && { echo "HOSTKEY FAILED: ssh went to a machine whose key is not the one in known_hosts"; exit 1; }
printf '%s' "$W" | grep -qiE 'host key verification failed|identification has changed' || { echo "HOSTKEY FAILED: refused, but not for the host key: $W"; exit 1; }
( umask 077; touch /root/.ssh/known_hosts; ssh-keygen -R "[$ADDR]:$PORT" -f /root/.ssh/known_hosts >/dev/null 2>&1; printf '[%s]:%s ssh-ed25519 %s\n' "$ADDR" "$PORT" "$HOSTKEY" >> /root/.ssh/known_hosts )
echo "HOSTKEY OK"
sshpass -p "$PASSWORD" ssh-copy-id -i /root/.ssh/id_rsa -o ConnectTimeout=8 -o StrictHostKeyChecking=yes "root@$ADDR" > /tmp/copy-id.log 2>&1 || { echo "DOOR FAILED: ssh-copy-id with the one-time password:"; tail -5 /tmp/copy-id.log; exit 1; }
# the container looks for the key every two seconds, then turns the password off: tried until it is refused, 20 s at most
n=0; while sshpass -p "$PASSWORD" ssh "${BY_PW[@]}" "root@$ADDR" true 2>/dev/null; do n=$((n + 1)); [ $n -lt 20 ] || { echo "DOOR FAILED: the password still works 20 s after the key was left"; exit 1; }; sleep 1; done
echo "DOOR OK"

exchange() {
  set -e
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -i /root/.ssh/id_rsa "root@$ADDR" 'command -v corosync-qnetd-certutil'     # host/qdevice.sh
  ssh-copy-id -i /root/.ssh/id_rsa "root@$ADDR"                                                                           # pvecm, from here on
  ssh -o BatchMode=yes -lroot "$ADDR" corosync-qnetd-certutil -i || true
  scp -o BatchMode=yes "root@[$ADDR]:/etc/corosync/qnetd/nssdb/qnetd-cacert.crt" /tmp/qnetd-cacert.crt
  corosync-qdevice-net-certutil -i -c /tmp/qnetd-cacert.crt
  corosync-qdevice-net-certutil -r -n "$CLUSTER"
  scp -o BatchMode=yes "$DB/qdevice-net-node.crq" "root@[$ADDR]:/tmp"
  ssh -o BatchMode=yes -lroot "$ADDR" corosync-qnetd-certutil -s -c /tmp/qdevice-net-node.crq -n "$CLUSTER"
  scp -o BatchMode=yes "root@[$ADDR]:/etc/corosync/qnetd/nssdb/cluster-$CLUSTER.crt" "$DB"
  corosync-qdevice-net-certutil -M -c "$DB/cluster-$CLUSTER.crt"
  test -s "$DB/qdevice-net-node.p12"
}
if ( exchange ) > /tmp/exchange.log 2>&1; then echo "EXCHANGE OK"; else echo "EXCHANGE FAILED:"; tail -15 /tmp/exchange.log; exit 1; fi

# another key, and none: refused (asked while the SSH server is still there; a refused connection would prove nothing)
ssh-keygen -q -t ed25519 -N '' -f /tmp/other
O=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentitiesOnly=yes -p "$PORT")
ssh "${O[@]}" -i /root/.ssh/id_rsa "root@$ADDR" true 2>/dev/null || { echo "REFUSAL FAILED: the SSH server is gone already: nothing was asked"; exit 1; }
if ssh "${O[@]}" -i /tmp/other "root@$ADDR" true 2>/dev/null || ssh "${O[@]}" -o PubkeyAuthentication=no "root@$ADDR" true 2>/dev/null; then echo "REFUSAL FAILED: root got in without the node's key"; exit 1; fi
echo "REFUSAL OK"

IP=$(ip -4 -o addr show scope global | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
cat > /etc/corosync/corosync.conf <<EOF
totem {
  version: 2
  cluster_name: $CLUSTER
  transport: knet
  crypto_cipher: none
  crypto_hash: none
}
nodelist {
  node {
    ring0_addr: $IP
    name: n1
    nodeid: 1
    quorum_votes: 1
  }
}
quorum {
  provider: corosync_votequorum
  device {
    model: net
    votes: 1
    net {
      algorithm: ffsplit
      host: $ADDR
      tls: on
    }
  }
}
logging {
  to_stderr: yes
  to_syslog: no
}
EOF
mkdir -p /var/run/corosync /var/run/corosync-qdevice /var/lib/corosync
corosync -f > /tmp/corosync.log 2>&1 &
for _ in $(seq 1 20); do corosync-cfgtool -s >/dev/null 2>&1 && break; sleep 1; done
corosync-quorumtool -s 2>/dev/null | grep -q '^Total votes: *1' && echo "ALONE: 1 of 2 votes"
corosync-qdevice -f > /tmp/qdevice.log 2>&1 &
for _ in $(seq 1 30); do corosync-quorumtool -s 2>/dev/null | grep -q '^Total votes: *2' && break; sleep 1; done
Q=$(corosync-quorumtool -s 2>&1); D=$(corosync-qdevice-tool -s 2>&1)
if printf '%s\n' "$Q" | grep -q '^Total votes: *2' && printf '%s\n' "$Q" | grep -q '^Quorate: *Yes' && printf '%s\n' "$Q" | grep -q 'A,V,NMW' && printf '%s\n' "$D" | grep -q 'State:.*Connected'; then echo "VOTE OK"
else echo "VOTE FAILED:"; printf '%s\n' "$Q" "$D"; tail -8 /tmp/qdevice.log; exit 1; fi

