# shellcheck shell=bash
# host/qdevice.sh — sourced by install.sh for --third-vote ADDRESS: a third vote for a cluster of two nodes, cast by
# corosync-qnetd on a third machine (vote/install.sh puts it there). The setup itself is Proxmox's own
# `pvecm qdevice setup`; this file gets the cluster ready for it and reads the result back:
#   - nothing to do: the cluster has a third vote already, or an odd number of nodes (pvecm sets none up then)
#   - the machine at ADDRESS is not ready yet: the line to run there (get.sh, which ends in vote/install.sh on a
#     machine that is not a Proxmox node)
#   - corosync-qdevice on every node that lacks it (apt-get; the other nodes over the cluster's own SSH)
#   - --third-vote-port N other than 22 (the container of vote/install.sh): an entry for ADDRESS in root's SSH
#     config, the one place pvecm's ssh, scp and ssh-copy-id all take the port from
#   - this node's key left there with ssh-copy-id, which asks for the password that machine printed (once: pvecm's
#     own ssh-copy-id then finds the key in place); its SSH host key recorded, trusted on this first use
#   - pvecm qdevice setup ADDRESS, then the votes: the cluster must keep its quorum without one node
# Tests: tests/t-vote.sh (fakes); tests/t-vote-real.sh runs the commands pvecm runs toward ADDRESS, with the real
# programs, against the container. Not yet run on a real cluster.
SSH_DIR=${ZRADIO_VM_SSH_DIR:-/root/.ssh}
QDEV_DB=${ZRADIO_VM_QDEV_DB:-/etc/corosync/qdevice/net/nssdb}     # where pvecm keeps a node's certificates for the vote
QNETD_PORT=${ZRADIO_VM_QNETD_PORT:-5403}
VOTE_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
CFG="$SSH_DIR/config"

ip4 "$VOTE" || die "--third-vote '$VOTE': the machine's IPv4 address (pvecm qdevice setup takes an address, not a name)"
[[ "$VOTE_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$VOTE_PORT" -ge 1 ] && [ "$VOTE_PORT" -le 65535 ] || die "--third-vote-port '$VOTE_PORT': a TCP port"
[ -r "$PVE/corosync.conf" ] || die "this node is in no cluster (no $PVE/corosync.conf): a third vote is for a cluster of two nodes"

members() { # the cluster's nodes: "<name> <ip> <online 1|0> <this node 1|0>"
  pvesh get /cluster/status --output-format json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except ValueError: d = []
for n in d:
    if n.get("type") == "node": print(n.get("name"), n.get("ip") or "-", int(bool(n.get("online"))), int(bool(n.get("local"))))'
}
node_ssh() { # node_ssh <name> <ip> <command>: on another node of the cluster, the way Proxmox itself goes there
  local kh="$PVE/nodes/$1/ssh_known_hosts" o=(-o BatchMode=yes -o ConnectTimeout=8 -o "HostKeyAlias=$1")
  [ ! -f "$kh" ] || o+=(-o "UserKnownHostsFile=$kh" -o GlobalKnownHostsFile=none)
  ssh -e none "${o[@]}" "root@$2" -- "$3"
}
vote_probe() { # one login at the vote's machine with this node's key, nothing recorded. PROBE becomes: keyed (root
  # gets in and corosync-qnetd is there), closed (nothing answers on the SSH port), or denied (anything else: the
  # key is not there yet). One connection only: an SSH server counts failed logins against the address they come from.
  local e
  if e=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -i "$SSH_DIR/id_rsa" -p "$VOTE_PORT" "root@$VOTE" 'command -v corosync-qnetd-certutil' 2>&1 >/dev/null < /dev/null); then PROBE=keyed
  elif printf '%s' "$e" | grep -qiE 'refused|timed out|no route|unreachable'; then PROBE=closed
  else PROBE=denied; fi
}
port_open() { timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; }
has_device() { awk '/^quorum[ \t]*\{/ { q = 1 } q && /^[ \t]*device[ \t]*\{/ { f = 1 } q && /^\}/ { q = 0 } END { exit !f }' "$PVE/corosync.conf"; }
qdevice_here() { command -v corosync-qdevice-net-certutil >/dev/null 2>&1; }
QDEV_INSTALL='DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice'
install_here() { bash -c "$QDEV_INSTALL" >/dev/null; }
add_host() { ( umask 077; printf '\n# ha_zradio: the third vote of this cluster (./install.sh --third-vote); pvecm qdevice setup logs in there\nHost %s\n    Port %s\n' "$VOTE" "$VOTE_PORT" >> "$CFG" ); }
step() { # step <what, in words> <command…>: run it (--run) or say it
  local what=$1; shift
  if [ "$RUN" = 1 ]; then if "$@"; then done_ "$what"; else bad "$what: failed"; return 1; fi; else would "$what"; fi
}
stop_on_fail() { [ $FAILS -eq 0 ] || { echo "== $FAILS FAIL — ${1:-the third vote is not set up} =="; exit 1; }; }

echo "== a third vote for this cluster, cast by $VOTE ($([ "$RUN" = 1 ] && echo RUN || echo "report only: nothing is changed")) =="
if has_device; then
  ok "this cluster has a third vote already (its machine: $(sed -n 's/^[ \t]*host:[ \t]*//p' "$PVE/corosync.conf" | head -1)). To move it to $VOTE: pvecm qdevice remove, then this again"
  if quorum_alone; then ok "and it keeps its quorum without one node ($(votes | sed 's/ / votes, /') needed)"
  else bad "but it does NOT keep its quorum without one node now ($(votes | sed 's/ / vote(s), /') needed): the vote's machine does not answer the nodes (corosync-qdevice-tool -s)"; fi
  stop_on_fail "the third vote does not vote"; exit 0
fi
M=$(members); [ -n "$M" ] || die "no answer from pvesh get /cluster/status"
N=$(printf '%s\n' "$M" | grep -c .)
if [ $((N % 2)) = 1 ]; then
  ok "this cluster has $N node(s), an odd number: Proxmox sets up a third vote for an even number only. Nothing to do"
  exit 0
fi
while read -r n _ online _; do [ "$online" = 1 ] || bad "node $n is offline: pvecm qdevice setup needs every node online"; done <<< "$M"
[ -r "$SSH_DIR/id_rsa.pub" ] || bad "$SSH_DIR/id_rsa.pub is missing: pvecm logs into $VOTE with that key (a Proxmox node has it; ssh-keygen -t rsa -N '' -f $SSH_DIR/id_rsa makes one)"
[ ! -d "$QDEV_DB" ] || bad "certificates of an earlier third vote are still at $QDEV_DB: pvecm qdevice setup refuses then. Remove ${QDEV_DB%/net/nssdb} on each node (pvecm qdevice remove does it for a vote that is still configured)"
stop_on_fail "nothing was changed"

# the vote's machine: its vote and its SSH server answer, or the line that makes it so
WHY="" PROBE=""
if ! port_open "$VOTE" "$QNETD_PORT"; then WHY="nothing answers there on TCP $QNETD_PORT (corosync-qnetd)"
else vote_probe; [ "$PROBE" != closed ] || WHY="its vote answers (TCP $QNETD_PORT), but nothing answers on SSH port $VOTE_PORT. The line that machine printed has the port (--third-vote-port N)"; fi
if [ -n "$WHY" ]; then
  echo "   $VOTE is not ready to vote: $WHY."
  echo "   On that machine, as root, the kit's install line (any always-on machine with docker or apt-get; not a VM on"
  echo "   these nodes). There it sets up the vote, not a radio VM, and ends with the line to run here:"
  echo
  echo "      $VOTE_LINE"
  echo
  echo "== nothing was changed =="
  [ "$RUN" = 0 ] || exit 1
  exit 0
fi
# Root of this node gets in there by key already (an earlier run, or that machine was given the key), or the key
# has yet to be left there: ssh-copy-id, which asks for the password that machine printed.
KEYED=0; [ "$PROBE" != keyed ] || KEYED=1
if [ $KEYED = 1 ]; then ok "$VOTE answers on TCP $QNETD_PORT, lets root of this node in by key on SSH port $VOTE_PORT, and has corosync-qnetd"
else ok "$VOTE answers on TCP $QNETD_PORT and on SSH port $VOTE_PORT; this node's key is not there yet"; fi

# corosync-qdevice on every node
while read -r n ip _ here; do
  if [ "$here" = 1 ]; then
    if qdevice_here; then ok "corosync-qdevice is installed on $n"; else step "apt-get install corosync-qdevice on $n" install_here; fi
  elif node_ssh "$n" "$ip" 'command -v corosync-qdevice-net-certutil' >/dev/null 2>&1 < /dev/null; then ok "corosync-qdevice is installed on $n"
  elif node_ssh "$n" "$ip" true >/dev/null 2>&1 < /dev/null; then step "apt-get install corosync-qdevice on $n (over the cluster's SSH)" node_ssh "$n" "$ip" "$QDEV_INSTALL >/dev/null" < /dev/null
  else bad "no SSH from this node to root@$n ($ip): Proxmox's own cluster commands need it too (pvecm updatecerts)"; fi
done <<< "$M"
stop_on_fail

# root's SSH config: the port of the vote's machine, where it is not 22
HAVE=$(awk -v h="$VOTE" '$1 == "Host" { m = 0; for (i = 2; i <= NF; i++) if ($i == h) { m = 1; f = 1 } } m && tolower($1) == "port" { p = $2 } END { if (f) print (p == "" ? 22 : p) }' "$CFG" 2>/dev/null)
if [ "${HAVE:-22}" = "$VOTE_PORT" ]; then [ "$VOTE_PORT" = 22 ] || ok "$CFG has $VOTE on port $VOTE_PORT"
elif [ -n "$HAVE" ]; then bad "$CFG has an entry for $VOTE already, with port $HAVE: change it there to $VOTE_PORT, or remove it"
else step "an entry for $VOTE in $CFG, Port $VOTE_PORT: pvecm's ssh and scp take the port from there" add_host; fi
stop_on_fail

COPY_ID="this node's key left at $VOTE (ssh-copy-id): it asks ONCE for the password that machine printed (the kit's container: its one-time password; a Debian machine: root's password there)"
if [ "$RUN" = 0 ]; then
  [ $KEYED = 1 ] || would "$COPY_ID"
  would "pvecm qdevice setup $VOTE"
  go_ahead --third-vote "$VOTE" --third-vote-port "$VOTE_PORT"
fi

# the SSH host key of that machine is trusted on this first use: ssh-copy-id and pvecm then ask nothing about it
if [ $KEYED = 0 ]; then
  echo "   ssh-copy-id to root@$VOTE — the password that machine printed:"
  if ssh-copy-id -i "$SSH_DIR/id_rsa" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$VOTE" 2>&1 | sed 's/^/      | /'; [ "${PIPESTATUS[0]}" = 0 ]; then done_ "$COPY_ID"
  else bad "ssh-copy-id to root@$VOTE failed (its lines are above). A wrong or expired password: the install line on that machine again gives a new one. \"Connection closed\" after several tries: that machine's SSH server holds this address off for a while; wait a minute. No terminal here to type it on: give that machine this node's key instead (its --key, with $SSH_DIR/id_rsa.pub). A changed host key (its container rebuilt with a new volume): ssh-keygen -R '[$VOTE]:$VOTE_PORT'"; fi
  stop_on_fail
fi
if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i "$SSH_DIR/id_rsa" "root@$VOTE" 'command -v corosync-qnetd-certutil' >/dev/null < /dev/null; then
  done_ "root of this node gets in at $VOTE by key, with the port from $CFG; corosync-qnetd is there; its SSH host key is in $SSH_DIR/known_hosts"
else bad "ssh to root@$VOTE by key failed with the port from $CFG, or corosync-qnetd is not installed there. If that machine's host key changed (its container rebuilt with a new volume): ssh-keygen -R '[$VOTE]:$VOTE_PORT', then this again"; fi
stop_on_fail
echo "   pvecm qdevice setup $VOTE (Proxmox's own; its lines):"
pvecm qdevice setup "$VOTE" 2>&1 < /dev/null | sed 's/^/      | /'; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || bad "pvecm qdevice setup ended $rc. Its lines are above. To start over: pvecm qdevice remove (when the cluster shows a Qdevice), and remove ${QDEV_DB%/net/nssdb} on each node"
stop_on_fail
i=0; until quorum_alone; do i=$((i + 1)); [ $i -lt 30 ] || break; sleep "${ZRADIO_VM_POLL:-1}"; done
if quorum_alone; then ok "the cluster keeps its quorum without one node now ($(votes | sed 's/ / votes, /') needed): a node that boots while the other is down starts its VMs"
else bad "the vote is configured, but the cluster still has $(votes | sed 's/ / vote(s) and needs /'): the nodes do not reach $VOTE on TCP $QNETD_PORT? (corosync-qdevice-tool -s on each node)"; fi
stop_on_fail
echo "== done: $VOTE casts this cluster's third vote =="
exit 0
