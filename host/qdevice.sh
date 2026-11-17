# shellcheck shell=bash
# host/qdevice.sh — sourced by install.sh for --third-vote ADDRESS: a third vote for a cluster of two nodes, cast by
# corosync-qnetd on a third machine (vote/install.sh puts it there). The setup itself is Proxmox's own
# `pvecm qdevice setup`; this file gets the cluster ready for it and reads the result back:
#   - nothing to do: the cluster has a third vote already, or an odd number of nodes (pvecm sets none up then)
#   - the machine at ADDRESS is not ready yet: the line to run there (get.sh, which ends in vote/install.sh on a
#     machine that is not a Proxmox node)
#   - corosync-qdevice on every node that lacks it (apt-get; the other nodes over the cluster's own SSH). A node's
#     package lists are refreshed only when the first try to install fails, and that refresh may fail: apt-get
#     update ends non-zero on a node with Proxmox's enterprise repository and no subscription
#   - --third-vote-port N other than 22 (the container of vote/install.sh): an entry for ADDRESS in root's SSH
#     config, the one place pvecm's ssh, scp and ssh-copy-id all take the port from. Which port that config gives
#     now is asked of ssh itself (ssh -G), not read from the file. The entry is taken out again once the vote is
#     set up: left there, it would send every later ssh from this node to that address to the container
#   - that machine's SSH host key, which its line carries (--third-vote-hostkey), put into root's known_hosts before
#     anything logs in: the password is typed to that machine or to nobody. A line without the key (an older one):
#     the host key is trusted on first use, as Proxmox's own setup does
#   - this node's key left there with ssh-copy-id, which asks for the password that machine printed (once: pvecm's
#     own ssh-copy-id then finds the key in place)
#   - pvecm qdevice setup ADDRESS, then the votes: the cluster must keep its quorum without one node, and every node
#     must hold its own connection to the vote
# Tests: tests/t-vote.sh (fakes); tests/vote-real.sh runs the commands pvecm runs toward ADDRESS, with the real
# programs, against the container.
SSH_DIR=${ZRADIO_VM_SSH_DIR:-/root/.ssh}
QDEV_DB=${ZRADIO_VM_QDEV_DB:-/etc/corosync/qdevice/net/nssdb}     # where pvecm keeps a node's certificates for the vote
QNETD_PORT=${ZRADIO_VM_QNETD_PORT:-5403}
VOTE_LINE='bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _'      # the kit's one install line
CFG="$SSH_DIR/config"
KNOWN="$SSH_DIR/known_hosts"

ip4 "$VOTE" || die "--third-vote '$VOTE': the machine's IPv4 address (pvecm qdevice setup takes an address, not a name)"
[[ "$VOTE_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$VOTE_PORT" -ge 1 ] && [ "$VOTE_PORT" -le 65535 ] || die "--third-vote-port '$VOTE_PORT': a TCP port"
[ -z "$VOTE_HOSTKEY" ] || [[ "$VOTE_HOSTKEY" =~ ^AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]{40,60}=*$ ]] || die "--third-vote-hostkey: the long word at the end of the line that machine printed (its ed25519 SSH host key), whole"
# how ssh names that machine in known_hosts, and its line there when the key came with the option
if [ "$VOTE_PORT" = 22 ]; then KH_NAME=$VOTE; else KH_NAME="[$VOTE]:$VOTE_PORT"; fi
KH_LINE="$KH_NAME ssh-ed25519 $VOTE_HOSTKEY"
STRICT=accept-new; [ -z "$VOTE_HOSTKEY" ] || STRICT=yes
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
  # gets in and corosync-qnetd is there), closed (nothing answers on the SSH port), badkey (the machine that answers
  # has another SSH host key than the line names), or denied (anything else: the key is not there yet). One
  # connection only: an SSH server counts failed logins against the address they come from (a Debian machine's own
  # does; the kit's container has that switched off, PerSourcePenalties=no).
  local e t="" o=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  if [ -n "$VOTE_HOSTKEY" ]; then
    t=$(mktemp) || return 1; printf '%s\n' "$KH_LINE" > "$t"
    o=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$t" -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519)
  fi
  if e=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${o[@]}" -o LogLevel=ERROR \
      -i "$SSH_DIR/id_rsa" -p "$VOTE_PORT" "root@$VOTE" 'command -v corosync-qnetd-certutil' 2>&1 >/dev/null < /dev/null); then PROBE=keyed
  elif printf '%s' "$e" | grep -qiE 'refused|timed out|no route|unreachable'; then PROBE=closed
  elif printf '%s' "$e" | grep -qiE 'host key verification failed|identification has changed|no matching host key'; then PROBE=badkey
  else PROBE=denied; fi
  [ -z "$t" ] || rm -f "$t"
}
pin_host() { # that machine's host key into root's known_hosts, in place of any other key recorded for it there
  ( umask 077; mkdir -p "$SSH_DIR" && touch "$KNOWN" && { ssh-keygen -R "$KH_NAME" -f "$KNOWN" >/dev/null 2>&1 || true; } && printf '%s\n' "$KH_LINE" >> "$KNOWN" )
}
port_open() { timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; }
has_device() { awk '/^quorum[ \t]*\{/ { q = 1 } q && /^[ \t]*device[ \t]*\{/ { f = 1 } q && /^\}/ { q = 0 } END { exit !f }' "$PVE/corosync.conf"; }
qdevice_here() { command -v corosync-qdevice-net-certutil >/dev/null 2>&1; }
# One command line, for this node and (over SSH) the others. A first try that fails: the lists are refreshed
# and it is tried once more. The first try's error is not shown then, nor what apt-get update says: update ends
# non-zero for a repository that refuses (the enterprise one without a subscription), and the second try tells.
QDEV_INSTALL='DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice 2>/dev/null || { apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -q -y install corosync-qdevice; }'
install_here() { bash -c "$QDEV_INSTALL" >/dev/null; }
HOST_NOTE='# ha_zradio: the third vote of this cluster (./install.sh --third-vote); pvecm qdevice setup logs in there'
host_entry() { printf '\n%s\nHost %s\n    Port %s\n' "$HOST_NOTE" "$VOTE" "$VOTE_PORT"; }
add_host() { ( umask 077; host_entry >> "$CFG" ); }
del_host() { # the entry add_host wrote, those lines and no other: a Host entry of the user's own is not this script's to remove
  python3 - "$CFG" "$(host_entry)" <<'PY'
import os, sys
p, block = sys.argv[1], sys.argv[2] + "\n"
s = open(p).read()
if block not in s: sys.exit(1)
fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, os.stat(p).st_mode & 0o777)
with os.fdopen(fd, "w") as f: f.write(s.replace(block, "", 1))
os.replace(p + ".tmp", p)
PY
}
ssh_port() { # ssh_port <config file>: the port ssh would use toward the vote's machine with that file as root's config
  # (22: the file names none for it; nothing: ssh cannot read the file). Asked of ssh itself: a Host line holds
  # patterns, of the entries that fit the FIRST Port counts, and a keyword comes in any letter case, with "=" too.
  ssh -G -F "$1" "root@$VOTE" 2>/dev/null < /dev/null | awk '$1 == "port" && p == "" { p = $2 } END { print p }'
}
qdev_connected() { # qdev_connected <name> <ip> <this node 1|0>: that node's corosync-qdevice holds a connection to the vote
  if [ "$3" = 1 ]; then corosync-qdevice-tool -s 2>&1 < /dev/null; else node_ssh "$1" "$2" 'corosync-qdevice-tool -s' 2>&1 < /dev/null; fi | grep -E '^State:[[:space:]]*Connected' >/dev/null
}
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
while read -r n ip online here; do      # the same on the other node: pvecm would stop there, halfway
  [ "$here" = 0 ] && [ "$online" = 1 ] || continue
  [ -z "$(node_ssh "$n" "$ip" "[ ! -d '$QDEV_DB' ] || echo LEFTOVER" 2>/dev/null < /dev/null)" ] || bad "certificates of an earlier third vote are still on $n ($QDEV_DB): remove ${QDEV_DB%/net/nssdb} there"
done <<< "$M"
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
[ "$PROBE" != badkey ] || bad "the machine that answers at $VOTE on SSH port $VOTE_PORT is not the one that printed this line: its SSH host key is another one. Nothing was sent to it. A container that was rebuilt with a new volume has a new key: use the line it printed last"
stop_on_fail "nothing was changed"
KEYED=0; [ "$PROBE" != keyed ] || KEYED=1
if [ $KEYED = 1 ]; then ok "$VOTE answers on TCP $QNETD_PORT, lets root of this node in by key on SSH port $VOTE_PORT, and has corosync-qnetd"
else ok "$VOTE answers on TCP $QNETD_PORT and on SSH port $VOTE_PORT; this node's key is not there yet"; fi

# corosync-qdevice on every node
while read -r n ip _ here; do
  if [ "$here" = 1 ]; then
    if qdevice_here; then ok "corosync-qdevice is installed on $n"; else step "apt-get install corosync-qdevice on $n" install_here < /dev/null; fi
  elif node_ssh "$n" "$ip" 'command -v corosync-qdevice-net-certutil' >/dev/null 2>&1 < /dev/null; then ok "corosync-qdevice is installed on $n"
  elif node_ssh "$n" "$ip" true >/dev/null 2>&1 < /dev/null; then step "apt-get install corosync-qdevice on $n (over the cluster's SSH)" node_ssh "$n" "$ip" "{ $QDEV_INSTALL; } >/dev/null" < /dev/null
  else bad "no SSH from this node to root@$n ($ip): Proxmox's own cluster commands need it too (pvecm updatecerts)"; fi
done <<< "$M"
stop_on_fail

# root's SSH config: the port of the vote's machine, where it is not 22
HAVE=22; [ ! -e "$CFG" ] || HAVE=$(ssh_port "$CFG")
if [ -z "$HAVE" ]; then bad "ssh cannot read $CFG ($(ssh -G -F "$CFG" "root@$VOTE" 2>&1 >/dev/null < /dev/null | head -1)): pvecm's ssh would stop at it too. Mend that file first"
elif [ "$HAVE" = "$VOTE_PORT" ]; then [ "$VOTE_PORT" = 22 ] || ok "$CFG has $VOTE on port $VOTE_PORT"
else      # would an entry at the file's end give the port? Not when one before it names a port for this address: ssh is asked, with the entry added to a copy
  WITH=""; t=$(mktemp) && { cat "$CFG" 2>/dev/null; host_entry; } > "$t" && WITH=$(ssh_port "$t"); rm -f "${t:-}"
  if [ "$WITH" = "$VOTE_PORT" ]; then step "an entry for $VOTE in $CFG, Port $VOTE_PORT: pvecm's ssh and scp take the port from there" add_host
  else bad "$CFG names port $HAVE for $VOTE already (an entry for that address, or a pattern it fits; ssh -G root@$VOTE shows what ssh makes of the file): change it there to $VOTE_PORT, or remove it"; fi
fi
stop_on_fail

# that machine's SSH host key: from the line (known before anything is said to it), or trusted on first use
if [ -n "$VOTE_HOSTKEY" ]; then
  if grep -qxF "$KH_LINE" "$KNOWN" 2>/dev/null; then ok "$KNOWN has that machine's SSH host key, the one its line names"
  else step "that machine's SSH host key, as its line names it, in $KNOWN: this node talks to that machine or to nobody" pin_host; fi
  stop_on_fail
else warn "the line names no SSH host key (--third-vote-hostkey; the line that machine prints has it): the key of whatever answers at $VOTE is trusted on this first use, as Proxmox's own setup does"; fi

COPY_ID="this node's key left at $VOTE (ssh-copy-id): it asks ONCE for the password that machine printed (the kit's container: its one-time password; a Debian machine: root's password there)"
if [ "$RUN" = 0 ]; then
  [ $KEYED = 1 ] || would "$COPY_ID"
  would "pvecm qdevice setup $VOTE"
  HKA=(); [ -z "$VOTE_HOSTKEY" ] || HKA=(--third-vote-hostkey "$VOTE_HOSTKEY")
  go_ahead --third-vote "$VOTE" --third-vote-port "$VOTE_PORT" ${HKA[@]+"${HKA[@]}"}
fi

if [ $KEYED = 0 ]; then
  echo "   ssh-copy-id to root@$VOTE — the password that machine printed:"
  if ssh-copy-id -i "$SSH_DIR/id_rsa" -o ConnectTimeout=8 -o "StrictHostKeyChecking=$STRICT" "root@$VOTE" 2>&1 | sed 's/^/      | /'; [ "${PIPESTATUS[0]}" = 0 ]; then done_ "$COPY_ID"
  else bad "ssh-copy-id to root@$VOTE failed (its lines are above). A wrong or expired password: the install line on that machine again gives a new one. \"Connection closed\" after several tries, where the vote is from Debian's package: that machine's own SSH server holds this address off for a while; wait a minute (the kit's container never does). No terminal here to type it on: give that machine this node's key instead (its --key, with $SSH_DIR/id_rsa.pub). A changed host key (its container rebuilt with a new volume): ssh-keygen -R '[$VOTE]:$VOTE_PORT'"; fi
  stop_on_fail
fi
if ssh -o BatchMode=yes -o ConnectTimeout=8 -o "StrictHostKeyChecking=$STRICT" -i "$SSH_DIR/id_rsa" "root@$VOTE" 'command -v corosync-qnetd-certutil' >/dev/null < /dev/null; then
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
# every node its own connection: the node that is left alone one day is the one that needs the vote
while read -r n ip _ here; do
  i=0; until qdev_connected "$n" "$ip" "$here"; do i=$((i + 1)); [ $i -lt 15 ] || break; sleep "${ZRADIO_VM_POLL:-1}"; done
  if qdev_connected "$n" "$ip" "$here"; then ok "$n holds a connection to the vote"
  else bad "$n holds no connection to the vote at $VOTE (TCP $QNETD_PORT): does that node reach it? Left alone, $n would lose its quorum (corosync-qdevice-tool -s on $n)"; fi
done <<< "$M"
# the SSH config entry was for the setup: nothing of Proxmox logs in there again, and other things of root's might
if [ "$VOTE_PORT" != 22 ] && grep -qxF "$HOST_NOTE" "$CFG" 2>/dev/null; then
  del_host && done_ "the entry for $VOTE is out of $CFG again (it was for the setup; that machine's host key stays in $SSH_DIR/known_hosts)" \
    || warn "the entry for $VOTE in $CFG could not be taken out: remove the three lines under \"# ha_zradio\" there by hand"
fi
stop_on_fail
echo "== done: $VOTE casts this cluster's third vote =="
exit 0
