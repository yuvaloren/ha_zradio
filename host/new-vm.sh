# shellcheck shell=bash
# host/new-vm.sh — sourced by install.sh: a new radio VM on this node (and, on the second node, its pairing with the
# first). The helpers are host/lib.sh's.

# ------------------------------------------------------------- the first radio VM, when this node gets the second
# A VM with the tag `zradio` on another node is the pair's first VM: its addresses, its bridge and its initial role
# decide this one's, and the two are introduced to each other at the end.
# A VM is tagged zradio-building from its creation until this run has finished with it (the kit installed in it, the
# pair introduced), and zradio from then on. So a run that stopped halfway leaves no VM that passes for a radio VM:
# nothing updates it, and the other node does not pair with it.
HALF=$(printf '%s\n' "$VMS" | awk -v me="$NODE" '$3 == me && (";" $5 ";") ~ /;zradio-building;/ { printf "%s%s (%s)", s, $2, $1; s = ", " }')
[ -z "$HALF" ] || die "$HALF on $NODE: a radio VM that an earlier run did not finish, or a drill (--no-usb). It is not updated and not built upon. Remove it, then this again: qm stop <id>; qm destroy <id> --purge; and its cloud-init file <name>-zradio.yaml in the snippets storage"
PNODE="" PVMID="" PNAME="" P_ROLE="" P_ZWAVE="" P_ZIGBEE=""
if [ $PAIR = 1 ] && [ $NOUSB = 0 ]; then
  if [ -n "$JOIN" ]; then C=$(printf '%s\n' "$VMS" | awk -v n="$JOIN" -v me="$NODE" '$2 == n && $3 != me')
    [ -n "$C" ] || die "--join '$JOIN': no VM of that name on another node of this cluster"
  else C=$(printf '%s\n' "$VMS" | awk -v me="$NODE" '$3 != me && (";" $5 ";") ~ /;zradio;/'); fi
  if [ "$(printf '%s\n' "$C" | grep -c .)" -gt 1 ]; then die "more than one radio VM on other nodes ($(printf '%s\n' "$C" | awk '{ printf "%s ", $2 }')): say which with --join NAME, or --no-pair"; fi
  if [ -n "$C" ]; then read -r PVMID PNAME PNODE _ <<< "$C"; fi
fi
INTRO=0; if [ $ASK = 1 ] && [ $NOUSB = 0 ] && [ $RUN = 0 ]; then INTRO=1; echo "== a radio VM for this node ($NODE) =="; fi
if [ -n "$PVMID" ] && [ $ASK = 1 ] && [ -z "$JOIN" ]; then
  echo "   $PNAME on $PNODE is a radio VM of this kit."
  ask "Is this node's VM the second of that pair? (n: a pair of its own)" y
  case "${ANS,,}" in n|no) PVMID="" PNODE="" PNAME="" PAIR=0;; *) JOIN=$PNAME;; esac
fi
if [ -n "$PVMID" ]; then
  agent_up "$PNODE" "$PVMID" || die "$PNAME on $PNODE does not answer (its guest agent): start it first — this node's VM takes its addresses from it and is introduced to it. (--no-pair: do neither.)"
  # shellcheck disable=SC2016  # the script runs in the VM
  PF=$(gx "$PNODE" "$PVMID" 20 'cat /etc/zradio/zradio.conf 2>/dev/null; echo; printf "INITIAL_ROLE=%s\n" "$(cat /var/lib/zradio/initial-role 2>/dev/null)"; sed -n "s/^\(ZWAVE\|ZIGBEE\)=/P_&/p" /etc/zradio/radios.conf 2>/dev/null') \
    || die "could not read $PNAME's configuration through its guest agent"
  pf() { printf '%s\n' "$PF" | sed -n "s/^$1=//p" | tail -1 | tr -dc 'A-Za-z0-9./:_-'; }
  P_SELF=$(pf SELF); P_PEER=$(pf PEER); P_ROLE=$(pf INITIAL_ROLE); P_ZWAVE=$(pf P_ZWAVE); P_ZIGBEE=$(pf P_ZIGBEE)
  ip4 "$P_SELF" || die "$PNAME has no /etc/zradio/zradio.conf with SELF: the kit is not installed in it"
  [ -z "$P_PEER" ] || ip4 "$P_PEER" || die "$PNAME's /etc/zradio/zradio.conf names a PEER that is no address: '$P_PEER'"
  [ -n "$PEER" ] || PEER=$P_SELF
  # what the two VMs of a pair share comes from the first one; an option of this run that says otherwise is refused
  P_VIP=$(pf VIP); P_VRID=$(pf VRID)
  [ -z "$VIP" ] || [ -z "$P_VIP" ] || [ "${VIP%/*}" = "${P_VIP%/*}" ] || die "--vip ${VIP%/*}: $PNAME holds the pair's floating address as ${P_VIP%/*}. Both VMs of a pair have the same one (--no-pair: a pair of its own)"
  [ -z "$VRID" ] || [ -z "$P_VRID" ] || [ "$VRID" = "$P_VRID" ] || die "--vrid $VRID: $PNAME has $P_VRID. Both VMs of a pair have the same one, or neither hears the other (--no-pair: a pair of its own)"
  [ -n "$VIP" ] || VIP=$P_VIP
  [ -n "$VRID" ] || VRID=$P_VRID
  for k in ZWAVE_PORT ZIGBEE_PORT SYNC_AT SYNC_TZ ELECTION ELECTION_WAIT ZUI_IMAGE ZIGPY_VERSION; do
    v=$(printf '%s\n' "$PF" | sed -n "s/^$k=//p" | tail -1 | tr -dc 'A-Za-z0-9./:_@+-'); mine=""
    for e in ${EXTRA[@]+"${EXTRA[@]}"}; do [ "${e%%=*}" != "$k" ] || mine=${e#*=}; done
    if [ -z "$v" ]; then [ -z "$mine" ] || warn "--conf $k=$mine: $PNAME's zradio.conf does not set $k (it runs with the default). The two VMs of a pair must agree on it"
    elif [ -z "$mine" ]; then EXTRA+=("$k=$v")
    elif [ "$mine" != "$v" ]; then die "--conf $k=$mine: $PNAME has $k=$v. Both VMs of a pair have the same one (leave the option out: it is taken from $PNAME)"; fi
  done
  # the network, from the first VM's own lines in the cluster's files: the ipconfig that holds its address, and that interface's bridge
  PC="$PVE/nodes/$PNODE/qemu-server/$PVMID.conf"
  pk=$(sed -n '/^\[/q; s/^ipconfig\([0-9]\):.*ip='"${P_SELF//./\\.}"'\/\([0-9]*\).*/\1 \2/p' "$PC" 2>/dev/null | head -1)
  pbr() { sed -n '/^\[/q; s/^net'"$1"':.*bridge=\([A-Za-z0-9._-]*\).*/\1/p' "$PC" | head -1; }
  [ -n "$BRIDGE" ] || BRIDGE=$(pbr 0)        # net0 is on the first VM's bridge, however the addresses are given
  if [ -n "$pk" ]; then                      # (none: the first VM has its address from DHCP, and so does this one)
    [ -n "$SELF" ] || [ -z "$P_PEER" ] || SELF="$P_PEER/${pk#* }"
    if [ "${pk% *}" = 0 ]; then [ -n "$GATEWAY" ] || GATEWAY=$(sed -n '/^\[/q; s/^ipconfig0:.*gw=\([0-9.]*\).*/\1/p' "$PC" | head -1)
    else [ -n "$PAIR_BRIDGE" ] || PAIR_BRIDGE=$(pbr "${pk% *}"); fi
  fi
  case "$P_ROLE" in
    primary) [ "${ROLE:-standby}" = standby ] || die "$PNAME was installed as the initial primary: this node's VM is the initial standby (two primaries would be two different sets of networks)"; ROLE=standby;;
    standby) [ "${ROLE:-primary}" = primary ] || die "$PNAME was installed as the initial standby: this node's VM is the initial primary"; ROLE=primary;;
  esac
fi

# ------------------------------------------------------------------------------- what is still missing: asked for
if [ $INTRO = 1 ]; then
  if [ ${#USBMAPS[@]} -eq 0 ]; then
    echo "   The sticks here that the kit knows (the VM finds out by itself which is Z-Wave and which is Zigbee; one kind alone is fine):"
    show_sticks || echo "      none"
  fi
  if [ -n "$PVMID" ]; then
    echo "   This VM joins $PNAME on $PNODE: its address $([ -n "$SELF" ] && echo "$SELF" || echo "comes from DHCP${BRIDGE:+ on $BRIDGE}"), $PNAME's is $PEER, the floating address ${VIP:-?}."
    [ "$ROLE" != standby ] || echo "   $PNAME is the initial primary, so this node starts as the STANDBY: the sticks here WILL BE WIPED by the first sync."
    [ "$ROLE" != primary ] || echo "   $PNAME is the initial standby, so this node starts as the PRIMARY: the sticks here hold your networks and stay as they are."
  fi
fi
if [ -z "$ROLE" ] && [ $NOUSB = 0 ]; then                  # the one question nobody can answer for the user
  [ $ASK = 1 ] || die "say what this node is INITIALLY: --initial-role primary (its radios are configured: the sticks here hold your networks) or --initial-role standby (its radios will be wiped: the sticks here are overwritten with the primary's networks). Only for the start: the two swap later"
  echo "   Is this node INITIALLY the primary or the standby of the pair?"
  echo "   (Only for the start: after the first sync the two are equals and swap at a failover or a switch.)"
  echo "      primary  its radios are configured: the sticks here hold your networks. They stay as they are."
  echo "      standby  its radios WILL BE WIPED: the sticks here are overwritten with the primary's networks."
  while :; do
    ask "initially primary or standby"
    case "${ANS,,}" in primary|p) ROLE=primary; break;; standby|s) ROLE=standby; break;; esac
  done
  if [ "$ROLE" = primary ] && [ $FIRST = 0 ]; then
    ask "Do the sticks here already hold your Z-Wave / Zigbee networks? (n: a new house, nothing paired yet)" y
    case "${ANS,,}" in n|no) FIRST=1;; esac
  fi
fi
[ $NOUSB = 0 ] || [ -n "$ROLE" ] || ROLE=standby          # a drill has no radios: the harmless role
if [ -z "$NAME" ]; then                 # the name is the user's: offered, asked for when someone is there
  taken() { printf '%s\n' "$VMS" | awk -v n="$1" '$2 == n { f = 1 } END { exit !f }'; }
  NAME_WHY="the first free of zradio1, zradio2, …"
  if [ -n "$PVMID" ]; then              # the pair's second VM is named after the first: radio1 -> radio2, attic -> attic2
    base=$(printf '%s' "$PNAME" | sed 's/[0-9]*$//'); n=${PNAME#"$base"}; n=$((10#${n:-1}))
    for i in 1 2 3 4 5 6 7 8 9; do c="$base$((n + i))"; if name_ok "$c" && ! taken "$c"; then NAME=$c; NAME_WHY="after $PNAME, the pair's first VM"; break; fi; done
  fi
  if [ -z "$NAME" ]; then for i in 1 2 3 4 5 6 7 8 9; do taken "zradio$i" || { NAME="zradio$i"; break; }; done; fi
  [ -n "$NAME" ] || die "zradio1 … zradio9 are all taken: name this VM with --name"
  if [ $ASK = 1 ]; then
    while :; do
      ask "the name of this node's radio VM" "$NAME"
      if name_ok "$ANS"; then NAME=$ANS; break; fi
      echo "         a short lower-case name (letters, digits, -), please"
    done
  else NAME_NOTE="no --name: this VM is called $NAME ($NAME_WHY)"; fi
fi
if [ $ASK = 1 ] && [ $NOUSB = 0 ]; then
  if [ -z "$BRIDGE" ] && [ -z "$PAIR_BRIDGE" ]; then
    brs=$(for b in "$NETSYS"/*/bridge; do [ -d "$b" ] && basename "$(dirname "$b")"; done | tr '\n' ' ')
    echo "   Which of this node's bridges is on the network the radio VMs will use? This VM, the other node's radio VM and the"
    echo "   floating address each get an address on that network. Home Assistant only has to reach it, from wherever it runs."
    echo "   This node's bridges: ${brs:-none found}"
    while :; do ask "bridge" "$([ -d "$NETSYS/vmbr0/bridge" ] && echo vmbr0)"; br_ok "$ANS" && break; done; BRIDGE=$ANS
  fi
  if [ -z "$SELF" ] && [ -z "$PAIR_BRIDGE" ]; then          # the VM's own address: DHCP's. One address is the user's to pick
    if ! ip4 "$VIP" && ! cidr "$VIP"; then
      echo "   The VM gets its own address from that network's DHCP server. One address is yours to pick: the floating address"
      echo "   Home Assistant connects to — a free address of that network that the DHCP server does not hand out."
      while ! ip4 "$VIP" && ! cidr "$VIP"; do ask "the floating address (like 192.168.1.20)"; VIP=$ANS; done
    fi
  else                                                       # fixed addresses (--self, or a pair link of its own)
    while ! cidr "$SELF"; do ask "this VM's address there, with its prefix (like 192.168.1.21/24)"; SELF=$ANS; done
    while ! ip4 "$PEER"; do ask "the other radio VM's address (the second node's VM gets it)"; PEER=$ANS; done
    while ! cidr "$VIP"; do ask "the floating address Home Assistant will connect to"; VIP=$ANS; ip4 "$VIP" && VIP="$VIP/${SELF##*/}"; done
    if [ -z "$PAIR_BRIDGE" ]; then while ! ip4 "$GATEWAY"; do ask "the gateway of that network"; GATEWAY=$ANS; done; fi
  fi
fi
[ -n "$BRIDGE" ] || BRIDGE=vmbr0
[ -n "$VRID" ] || VRID=50

[ -z "$NAME" ] || name_ok "$NAME" || die "--name '$NAME': a short lower-case name (letters, digits, -)"
DHCP=0; if [ -z "$SELF" ] && [ -z "$PAIR_BRIDGE" ]; then DHCP=1; fi       # no --self: the VM's own address is DHCP's
if [ $DHCP = 1 ]; then
  ip4 "$VIP" || cidr "$VIP" || die "--vip '$VIP': the floating address Home Assistant connects to (A.B.C.D — a free address of the VMs' network that DHCP does not hand out). The VM's own address comes from DHCP; fixed addresses instead: --self, --peer, --gateway"
  [ -z "$GATEWAY" ] || die "--gateway goes with --self (a fixed address). Without --self the VM takes its address and its gateway from DHCP"
  [ -z "$PEER" ] || ip4 "$PEER" || die "--peer '$PEER': the other radio VM's address"
  [ "$PEER" != "${VIP%/*}" ] || die "--peer and --vip are two different addresses"
else
  cidr "$SELF" || die "--self '$SELF': this VM's address as A.B.C.D/prefix"
  ip4 "$PEER" || die "--peer '$PEER': the other radio VM's address"
  cidr "$VIP" || die "--vip '$VIP': the floating address as A.B.C.D/prefix"
  [ "${SELF%/*}" != "$PEER" ] && [ "${SELF%/*}" != "${VIP%/*}" ] && [ "$PEER" != "${VIP%/*}" ] || die "--self, --peer and --vip are three different addresses"
  # the floating address is put on the interface that holds SELF: with --pair-bridge, that is the pair's own link
  in_net "$SELF" "${VIP%/*}" || die "--vip ${VIP%/*} is not on the network of --self $SELF. The floating address goes onto the same interface as this VM's own address$([ -n "$PAIR_BRIDGE" ] && echo " (with --pair-bridge: the link $PAIR_BRIDGE), so Home Assistant has to reach that network")"
fi
[[ "$VRID" =~ ^[0-9]+$ ]] && [ "$VRID" -ge 1 ] && [ "$VRID" -le 255 ] || die "--vrid '$VRID': 1-255"
[ -z "$PRIORITY" ] || { [[ "$PRIORITY" =~ ^[0-9]+$ ]] && [ "$PRIORITY" -ge 1 ] && [ "$PRIORITY" -le 254 ]; } || die "--priority '$PRIORITY': 1-254"
case "$ROLE" in primary|standby) ;; *) die "--initial-role '$ROLE': primary (this node's radios are configured) or standby (this node's radios will be wiped) — what the node is at the start; the two swap later";; esac
[ "$ROLE" != standby ] || [ $FIRST = 0 ] || die "--first is for the initial primary of a new house: a standby's sticks are filled by the primary's sync"
br_ok "$BRIDGE" || die "--bridge '$BRIDGE'"
[ -z "$PAIR_BRIDGE" ] || br_ok "$PAIR_BRIDGE" || die "--pair-bridge '$PAIR_BRIDGE'"
if [ $DHCP = 0 ] && [ -z "$PAIR_BRIDGE" ]; then ip4 "$GATEWAY" || die "without --pair-bridge the pair talks over the LAN on net0: --gateway A.B.C.D is needed with --self"; fi
[ -z "$PAIR_MAC" ] || [[ "$PAIR_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || die "--pair-mac '$PAIR_MAC'"
[ -z "$VMID" ] || { [[ "$VMID" =~ ^[0-9]{3,9}$ ]] && [ "$VMID" -ge 100 ]; } || die "--vmid '$VMID'"
[[ "$MEMORY" =~ ^[0-9]{3,6}$ ]] && [[ "$CORES" =~ ^[0-9]{1,2}$ ]] && [[ "$DISK" =~ ^[0-9]+G$ ]] || die "--memory MB, --cores N, --disk <n>G"
for m in ${POWER[@]+"${POWER[@]}"}; do port_ok "$m" || die "--stick-power '$m': hub:port as uhubctl names them, like 1-3:2"; done
[ $NOPOWER = 0 ] || [ ${#POWER[@]} -eq 0 ] || die "--stick-power and --no-stick-power contradict each other"
[ $NOUSB = 0 ] || [ ${#POWER[@]} -eq 0 ] || die "--no-usb is a drill without sticks: there is no power to switch (--stick-power)"
IMAGE_DIR=${IMAGE_DIR%/}
[[ "$IMAGE_DIR" =~ ^(https?://|file:///)[][A-Za-z0-9._~:/@%+-]+$ ]] || die "--image-dir '$IMAGE_DIR': where the Debian image and its SHA512SUMS are — https://…, or file:///folder for a folder of this node"
for m in ${USBMAPS[@]+"${USBMAPS[@]}"}; do [[ "$m" =~ ^[A-Za-z][A-Za-z0-9_-]{0,60}$ ]] || die "--usb-mapping '$m'"; done
[ $NOUSB = 0 ] || [ ${#USBMAPS[@]} -eq 0 ] || die "--no-usb and --usb-mapping contradict each other"
[ $NOUSB = 0 ] || [ $START = 0 ] || die "--no-usb is a drill: a VM without a stick is not put into a pair (--start)"
for e in ${EXTRA[@]+"${EXTRA[@]}"}; do
  [[ "$e" =~ ^[A-Z][A-Z0-9_]*=[A-Za-z0-9./:_@+-]*$ ]] || die "--conf '$e': KEY=value"
  case "${e%%=*}" in NAME|SELF|PEER|VIP|VRID|PRIORITY) die "--conf ${e%%=*}: that one has its own option";;
    # (the keys of zradio.conf that have no option of their own: guest/lib/zradio-common.sh refuses a conf with any other)
    IFACE|ZWAVE_PORT|ZIGBEE_PORT|SYNC_AT|SYNC_TZ|ELECTION|ELECTION_WAIT|ZUI_IMAGE|ZIGPY_VERSION) ;;
    *) die "--conf ${e%%=*}: not a key of zradio.conf (zradio.conf.example lists them)";; esac
done
if [ -n "$PVMID" ]; then
  [ "$PEER" = "$P_SELF" ] || die "$PNAME says it is $P_SELF; this VM would have its peer at $PEER — the two do not fit (--no-pair: a pair of its own)"
  [ $DHCP = 1 ] || [ -z "$P_PEER" ] || [ "${SELF%/*}" = "$P_PEER" ] || die "$PNAME says it is $P_SELF and expects its peer at $P_PEER; this VM would be ${SELF%/*} with its peer at $PEER — the two do not fit (--no-pair: a pair of its own)"
fi
[ -n "$PRIORITY" ] || { [ "$ROLE" = primary ] && PRIORITY=110 || PRIORITY=100; }
# every answer as options: what a terminal-less run of the same would be, and what the confirmed run is started with
ARGS=(--name "$NAME" --initial-role "$ROLE"); [ -z "$SELF" ] || ARGS+=(--self "$SELF"); [ -z "$PEER" ] || ARGS+=(--peer "$PEER")
ARGS+=(--vip "$VIP" --vrid "$VRID" --priority "$PRIORITY" --bridge "$BRIDGE")
[ -z "$PAIR_BRIDGE" ] || ARGS+=(--pair-bridge "$PAIR_BRIDGE"); [ -z "$GATEWAY" ] || ARGS+=(--gateway "$GATEWAY")
[ $FIRST = 0 ] || ARGS+=(--first); [ $START = 0 ] || ARGS+=(--start)
if [ -n "$PVMID" ]; then ARGS+=(--join "$PNAME"); elif [ $PAIR = 0 ]; then ARGS+=(--no-pair); fi
ARGS+=(${PASS[@]+"${PASS[@]}"})
echo "== 0. checks ($NODE; $([ $RUN = 1 ] && echo RUN || echo "report only: nothing is changed")) =="
[ -z "${NAME_NOTE:-}" ] || warn "$NAME_NOTE"
ok "the sticks the kit knows: $TABLE_SAID"
case "$ROLE" in
  primary) ok "this node starts as the PRIMARY: $([ $FIRST = 1 ] && echo "a new house — its sticks hold no network yet, Home Assistant forms it" || echo "its sticks hold your networks and stay as they are (the installer in the VM checks that they do)")";;
  standby) [ $NOUSB = 1 ] || warn "this node starts as the STANDBY: its sticks WILL BE OVERWRITTEN with the primary's networks at the first sync, whatever they hold now; the VM does not serve before that";;
esac
[ -n "$VMS" ] || warn "the cluster lists no VM at all (pvesh get /cluster/resources): the name and address checks have nothing to look at"
if printf '%s\n' "$VMS" | awk -v n="$NAME" '$2 == n { f = 1 } END { exit !f }'; then
  bad "a VM named $NAME exists already ($(printf '%s\n' "$VMS" | awk -v n="$NAME" '$2 == n { print "on " $3 ", " $4 }')). This tool builds a new VM and never rebuilds one: pick another name, or remove that VM yourself first"
else ok "no VM is named $NAME"; fi
if [ -z "$VMID" ]; then VMID=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc 0-9); [[ "$VMID" =~ ^[0-9]{3,9}$ ]] || { bad "pvesh get /cluster/nextid gave no id: name one with --vmid"; VMID=0; }; fi
if printf '%s\n' "$VMS" | awk -v i="$VMID" '$1 == i { f = 1 } END { exit !f }'; then bad "the id $VMID is taken ($(printf '%s\n' "$VMS" | awk -v i="$VMID" '$1 == i { print $2 }'))"; else ok "$NAME gets the id $VMID"; fi
[ $DHCP = 0 ] || ok "$NAME takes its own address from the DHCP server on $BRIDGE; the floating address is ${VIP%/*}"
[ -z "$PAIR_BRIDGE" ] || ok "the pair talks over $PAIR_BRIDGE ($SELF and $PEER), and the floating address ${VIP%/*} is on that link too: Home Assistant has to reach it there"
# another VM with this address: refused when it runs; said when it is stopped (the VM this one replaces)
for f in "$PVE"/nodes/*/qemu-server/*.conf; do
  [ -f "$f" ] && [ $DHCP = 0 ] || continue
  grep -qE "^ipconfig[0-9]+:.*ip=${SELF%/*}/" "$f" || continue
  oid=$(basename "$f" .conf); oname=$(printf '%s\n' "$VMS" | awk -v i="$oid" '$1 == i { print $2 }'); ost=$(printf '%s\n' "$VMS" | awk -v i="$oid" '$1 == i { print $4 }')
  if [ "$ost" = running ]; then bad "${oname:-VM $oid} runs with the address ${SELF%/*} already: two VMs on one address. Stop it first (it is the VM this one replaces?), or give this one another --self"
  else warn "${oname:-VM $oid} (${ost:-stopped}) is configured with ${SELF%/*} too: it must stay stopped while $NAME runs"; fi
done
if [ -z "$STORAGE" ]; then
  STORAGE=$(pvesh get /storage --output-format json 2>/dev/null | python3 -c '
import json, sys
try: st = {s["storage"]: s for s in json.load(sys.stdin)}
except ValueError: st = {}
for n in ("local-zfs", "local-lvm", "local"):
    if n in st and "images" in st[n].get("content", ""): print(n); break')
fi
[ -n "$STORAGE" ] && ok "the disk goes onto $STORAGE" || bad "no storage for the disk: none of local-zfs, local-lvm, local holds images — name one with --storage"
# the cloud-init file is a "snippet": a storage with a folder (a path) that holds snippets. One that has the folder but
# not snippets in its content gets them added (step 3); its other content stays as it is
read -r SNIPDIR SNIPCONTENT <<< "$(pvesh get "/storage/$SNIP" --output-format json 2>/dev/null | python3 -c '
import json, sys
try: s = json.load(sys.stdin)
except ValueError: s = {}
print(s.get("path", "-"), s.get("content", "-"))')"
SNIPADD=0
if [ -z "$SNIPDIR" ] || [ "$SNIPDIR" = - ]; then bad "the storage '$SNIP' has no folder for the cloud-init file (snippets): name one that has, with --snippets"
else
  case ",$SNIPCONTENT," in *,snippets,*) ;; *) SNIPADD=1;; esac
  SNIPDIR="$SNIPDIR/snippets"
  ok "the cloud-init file goes to $SNIPDIR ($SNIP$([ $SNIPADD = 0 ] || echo ", which gets snippets added to what it holds: $SNIPCONTENT"))"
fi
[ -s "$KEYS" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$KEYS" && ok "root's keys for the VM: $(grep -cE '^(ssh-|ecdsa-|sk-)' "$KEYS") from $KEYS" \
  || bad "no public key in $KEYS: the VM would have no way in (--ssh-keys FILE)"
case "$IMAGE_DIR" in
  file://*) [ -d "${IMAGE_DIR#file://}" ] || bad "--image-dir $IMAGE_DIR: no such folder on this node";;
  *) command -v wget >/dev/null 2>&1 || bad "no wget on this node: the Debian image and its checksum list are fetched with it (apt-get install wget; or from a folder of this node: --image-dir file:///folder)"
    [ "${IMAGE_DIR%%:*}" != http ] || warn "--image-dir $IMAGE_DIR is plain http: nothing protects the image or its checksum list on the way (both come over that link). Yours to decide; https and file:/// do not have that";;
esac
quorum_check

echo "== 1. the sticks on $NODE =="
S=$(sticks_here); M=$(mappings)
vm_with_usb() { # vm_with_usb running|idle <vid:pid> [<bus-port>]: prints the name of a VM on this node (running / not running)
  # whose usb lines reach that device — through any USB mapping whose entry for this node names it, or by host=<vid:pid> /
  # host=<bus-port>
  local want=$1 f id line v; shift
  for f in "$PVE"/nodes/"$NODE"/qemu-server/*.conf; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .conf)
    if printf '%s\n' "$VMS" | awk -v i="$id" '$1 == i && $4 == "running" { f = 1 } END { exit !f }'; then [ "$want" = running ] || continue; else [ "$want" = idle ] || continue; fi
    while read -r line; do
      case "$line" in
        *mapping=*) v=${line##*mapping=}; v=${v%%,*}
          printf '%s\n' "$M" | awk -v m="$v" -v n="$NODE" -v i="$1" -v p="${2:--}" '$1 == m && $2 == n && $3 == i && ($4 == "-" || p == "-" || $4 == p) { f = 1 } END { exit !f }' || continue;;
        *host=*) v=${line##*host=}; v=${v%%,*}; v=${v#0x}
          [ "${v,,}" = "$1" ] || { [ -n "${2:-}" ] && [ "$v" = "$2" ]; } || continue;;
        *) continue;;
      esac
      v=$(printf '%s\n' "$VMS" | awk -v i="$id" '$1 == i { print $2 }'); echo "${v:-VM $id}"; return 0
    done < <(sed -n '/^\[/q; /^usb[0-9]*:/p' "$f")          # the current config only, not its snapshots' sections
  done
  return 1
}
USE=()            # the VM's usb lines, in order: host=<vid:pid>, host=<bus-port>, or mapping=<id> (--usb-mapping)
DEVS=()           # the device behind each: "<vid:pid> <bus-port or ->"
if [ $NOUSB = 1 ]; then
  warn "--no-usb: no USB device is passed through. This VM is a drill of the tool: its installer will end with 'no stick found'"
elif [ ${#USBMAPS[@]} -gt 0 ]; then
  for m in "${USBMAPS[@]}"; do
    e=$(printf '%s\n' "$M" | awk -v m="$m" -v n="$NODE" '$1 == m && $2 == n { print $3; exit }')
    if [ -z "$e" ]; then bad "the USB mapping '$m' has no entry for $NODE (pvesh get /cluster/mapping/usb)"; continue; fi
    if usb_present "$e"; then
      ok "mapping $m: $e is plugged into $NODE"
    elif [ ${#POWER[@]} -gt 0 ]; then warn "mapping $m: no $e on $NODE's USB right now — taken as a stick whose port (--stick-power ${POWER[*]}) the hookscript switches on before the start"
    else bad "mapping $m: no USB device $e on $NODE right now"; fi
    USE+=("mapping=$m"); DEVS+=("$e $(printf '%s\n' "$M" | awk -v m="$m" -v n="$NODE" '$1 == m && $2 == n { print $4; exit }')")
  done
  [ ${#USE[@]} -eq 0 ] || warn "--usb-mapping: Proxmox checks a mapped stick at every start and refuses the start while it is not on $NODE. Without the option the kit names each stick itself (host=), and $NAME starts with or without it"
else
  [ -n "$S" ] && printf '%s\n' "$S" | sed 's/^/         found: /'
  while read -r port id _; do
    [ -n "$port" ] || continue
    # A stick is named by what it is (host=<vid:pid>): Proxmox passes it through whenever it is on the node, in any
    # socket, and starts the VM without it. Two sticks of one id cannot be told apart that way: each by its socket.
    n=$(printf '%s\n' "$S" | awk -v i="$id" '$2 == i { c++ } END { print c + 0 }')
    if [ "$n" -gt 1 ]; then
      USE+=("host=$port"); ok "$id at $port: $NAME gets it by its socket (host=$port), because $n sticks here have that id. It has to stay in that socket"
    else USE+=("host=$id"); ok "$id: $NAME gets it by its id (host=$id), in whichever socket it is"; fi
    DEVS+=("$id $port")
  done <<< "$S"
  if [ ${#USE[@]} -eq 0 ]; then
    if [ $NORADIOS = 1 ]; then warn "no stick on $NODE that the kit's table names — the VM is built without one (--allow-no-radios)"
    else bad "no stick on $NODE that the kit's table names (./install.sh --sticks). A stick the table does not know: make a USB mapping for it and pass --usb-mapping; a drill without sticks: --allow-no-radios"; fi
  fi
fi
[ ${#USE[@]} -le 5 ] || bad "${#USE[@]} USB devices: a VM takes five here (usb0-usb4) — name the ones you mean with --usb-mapping"
power_check "$NAME" "$(for dv in ${DEVS[@]+"${DEVS[@]}"}; do read -r did dpath <<< "$dv"; if [ "$dpath" != - ] && [ -n "$dpath" ]; then echo "$dpath"; else sticks_at "$did"; fi; done)"
i=0
for m in ${USE[@]+"${USE[@]}"}; do
  read -r did dpath <<< "${DEVS[$i]}"; i=$((i + 1)); [ "$dpath" != - ] || dpath=""
  if r=$(vm_with_usb running "$did" "$dpath"); then bad "the running VM $r on $NODE has the USB device $did ($m here) passed through already: two VMs on one stick. Stop it first (it is the VM this one replaces?)"
  elif r=$(vm_with_usb idle "$did" "$dpath"); then warn "$r (not running) on $NODE still has the USB device $did in its config: take that usb line off it while $NAME uses the stick — anything that starts it (a backup in stop mode does) would reach for the stick"; fi
done

[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL — nothing was changed =="; exit 1; }

echo "== 2. the Debian image =="
# What vouches for the image is HTTPS to cloud.debian.org. Debian publishes no signature of SHA512SUMS beside its cloud
# images (that folder holds the images, their .json files and SHA512SUMS, nothing else: looked at on 2026-11-16), so
# the list comes from the same server as the image: it catches a download that was damaged or cut short, not a server
# that lies. A cached image is used only when it is the file its stored checksum was made of, and --run asks the list
# whether it is still Debian's image (the one under `latest` is replaced every week or two). When the list or the
# newer image cannot be had, a whole cached image is used, and that is said.
img_get() { # img_get <file> <to>: one file of --image-dir
  case "$IMAGE_DIR" in file://*) cp "${IMAGE_DIR#file://}/$1" "$2" 2>/dev/null;; *) wget -q -T 20 -t 2 "$IMAGE_DIR/$1" -O "$2";; esac      # (two tries of 20 s: a server that is not reached must not hold the run)
}
IMG="$CACHE/$IMAGE_NAME"; HAVE=""          # HAVE: the cached image's checksum, when it is whole
if [ -s "$IMG" ] && [ -s "$IMG.sha512" ]; then
  HAVE=$(sha512sum "$IMG" | awk '{ print $1 }')
  [ "$HAVE" = "$(awk '{ print $1; exit }' "$IMG.sha512")" ] || { warn "the cached image $IMG is not the file its checksum was stored for (damaged, or replaced by hand): it is not used"; HAVE=""; }
fi
if [ $RUN = 0 ]; then
  if [ -n "$HAVE" ]; then ok "image cached, and whole by its stored checksum: $IMG (${HAVE:0:16}…)"
    would "ask $IMAGE_DIR/SHA512SUMS whether that is still Debian's image, and download the one there when it is not"
  else would "download $IMAGE_DIR/$IMAGE_NAME and SHA512SUMS, check, keep under $CACHE"; fi
else
  mkdir -p "$CACHE" || { bad "cannot make $CACHE"; exit 1; }
  trap 'rm -f "$CACHE/SHA512SUMS.tmp" "$IMG.tmp"' EXIT          # however this ends, nothing half-downloaded stays in the cache
  want=""; ! img_get SHA512SUMS "$CACHE/SHA512SUMS.tmp" || want=$(awk -v n="$IMAGE_NAME" '$2 == n { print $1; exit }' "$CACHE/SHA512SUMS.tmp")
  if [ -z "$want" ]; then
    [ -n "$HAVE" ] || { bad "$IMAGE_DIR/SHA512SUMS could not be read, or names no $IMAGE_NAME: the image's checksum is not known, so it is not downloaded"; exit 1; }
    warn "$IMAGE_DIR/SHA512SUMS could not be read, or names no $IMAGE_NAME: whether Debian has a newer image is not known. The cached one is used: $IMG (${HAVE:0:16}…)"
  elif [ "$want" = "$HAVE" ]; then ok "image cached, whole, and still the one at $IMAGE_DIR: $IMG (${HAVE:0:16}…)"
  else
    got=""; ! img_get "$IMAGE_NAME" "$IMG.tmp" || got=$(sha512sum "$IMG.tmp" | awk '{ print $1 }')
    if [ "$got" = "$want" ]; then
      mv -f "$IMG.tmp" "$IMG" && echo "$got" > "$IMG.sha512" || { bad "could not put the image into $CACHE"; exit 1; }
      done_ "image $IMAGE_NAME, sha512 ${got:0:16}… (from $IMAGE_DIR$([ -z "$HAVE" ] || echo ": the image there now, in place of the cached one"))"
    elif [ -n "$HAVE" ]; then warn "the newer image at $IMAGE_DIR did not arrive whole ($([ -n "$got" ] && echo "its list says ${want:0:16}…, the file is ${got:0:16}…" || echo "the download failed")). The cached one is used: $IMG (${HAVE:0:16}…)"
    elif [ -z "$got" ]; then bad "the download of $IMAGE_DIR/$IMAGE_NAME failed"; exit 1
    else bad "sha512 mismatch for $IMAGE_NAME (the list says $want, the file is $got). While Debian puts a new image there the two can differ for a while: later again"; exit 1; fi
  fi
  rm -f "$CACHE/SHA512SUMS.tmp" "$IMG.tmp"; trap - EXIT
fi

echo "== 3. the cloud-init file $SNIPDIR/$NAME-zradio.yaml =="
mk_user_data() {
  local kit64
  kit64=$(kit_tar | base64 -w 76 | sed 's/^/      /')
  cat <<EOF
#cloud-config
# $NAME: one radio VM of a zradio pair (ha_zradio's install.sh on $NODE, $(date -u +%F)). Debian 13 generic; root over keys
# only. The kit's files are put here; install.sh on the node runs the kit's installer through the guest agent.
hostname: $NAME
disable_root: false
ssh_pwauth: false
package_update: true
packages:
  - qemu-guest-agent
users:
  - name: root
    ssh_authorized_keys:
$(grep -E '^(ssh-|ecdsa-|sk-)' "$KEYS" | python3 -c 'import json, sys
for line in sys.stdin: print("      - " + json.dumps(line.rstrip("\n")))')
write_files:
  - path: /root/zradio.conf
    permissions: "0600"
    content: |
      # written by install.sh on $NODE; the installed copy is /etc/zradio/zradio.conf
      NAME=$NAME
$([ $DHCP = 1 ] || printf '      SELF=%s\n' "${SELF%/*}"; [ -z "$PEER" ] || printf '      PEER=%s\n' "$PEER"; printf '      VIP=%s' "$VIP")
      VRID=$VRID
      PRIORITY=$PRIORITY
$(for e in ${EXTRA[@]+"${EXTRA[@]}"}; do printf '      %s\n' "$e"; done)
  - path: /root/zradio-kit.tgz
    permissions: "0600"
    encoding: b64
    content: |
$kit64
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
}
[ $SNIPADD = 0 ] || do_ pvesm set "$SNIP" --content "$([ "$SNIPCONTENT" = - ] || echo "$SNIPCONTENT,")snippets" || exit 1
if [ $RUN = 1 ]; then
  mkdir -p "$SNIPDIR" && mk_user_data > "$SNIPDIR/$NAME-zradio.yaml.tmp" && mv -f "$SNIPDIR/$NAME-zradio.yaml.tmp" "$SNIPDIR/$NAME-zradio.yaml" \
    && done_ "$SNIPDIR/$NAME-zradio.yaml ($(wc -c < "$SNIPDIR/$NAME-zradio.yaml" | tr -d ' ') bytes: root's keys, the guest agent, the kit's guest folder, zradio.conf)" \
    || { bad "could not write $SNIPDIR/$NAME-zradio.yaml"; exit 1; }
else would "write $SNIPDIR/$NAME-zradio.yaml: root's keys, qemu-guest-agent, the kit's guest folder, zradio.conf (NAME=$NAME$([ $DHCP = 1 ] && echo ", its own address filled in by the VM" || echo " SELF=${SELF%/*}")${PEER:+ PEER=$PEER} VIP=$VIP VRID=$VRID PRIORITY=$PRIORITY${EXTRA[*]:+ ${EXTRA[*]}})"; fi

hook_setup "$VMID" "$NAME" no || exit 1

echo "== 4. the VM $NAME ($VMID) =="
if [ -n "$PAIR_BRIDGE" ]; then NETS=(--net0 "virtio,bridge=$BRIDGE" --ipconfig0 ip=dhcp --net1 "virtio${PAIR_MAC:+=$PAIR_MAC},bridge=$PAIR_BRIDGE" --ipconfig1 "ip=$SELF")
elif [ $DHCP = 1 ]; then NETS=(--net0 "virtio${PAIR_MAC:+=$PAIR_MAC},bridge=$BRIDGE" --ipconfig0 ip=dhcp)
else NETS=(--net0 "virtio${PAIR_MAC:+=$PAIR_MAC},bridge=$BRIDGE" --ipconfig0 "ip=$SELF,gw=$GATEWAY"); fi
USBS=(); i=0; for m in ${USE[@]+"${USE[@]}"}; do USBS+=("--usb$i" "$m"); i=$((i + 1)); done
do_ qm create "$VMID" --name "$NAME" --ostype l26 --machine q35 --bios ovmf --cores "$CORES" --memory "$MEMORY" --cpu host --scsihw virtio-scsi-single \
    --agent enabled=1 "${NETS[@]}" --serial0 socket --vga serial0 --onboot 1 --watchdog model=i6300esb,action=reset --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
    --ide2 "$STORAGE:cloudinit" --cicustom "user=$SNIP:snippets/$NAME-zradio.yaml" ${USBS[@]+"${USBS[@]}"} --hookscript "$SNIP:snippets/$HOOK_FILE" \
    --tags zradio-building --description "$NAME: one radio VM of a zradio pair — this node's Z-Wave / Zigbee sticks, served to Home Assistant on ${VIP%/*} while it holds that address, kept silent otherwise. Pinned to $NODE (its sticks are here). https://github.com/yuvaloren/ha_zradio" || exit 1
# from here on a run that stops leaves a VM behind: say how to start over, whatever line it stopped at
[ "$RUN" = 0 ] || trap 'rc=$?; [ $rc = 0 ] || echo "== $NAME ($VMID) was not finished: nothing updates it or pairs with it as it is. To start over: qm stop $VMID; qm destroy $VMID --purge; rm -f $SNIPDIR/$NAME-zradio.yaml $SNIPDIR/zradio-hook-$VMID.conf; then this again =="' EXIT
do_ qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$CACHE/$IMAGE_NAME,discard=on" || exit 1
do_ qm disk resize "$VMID" scsi0 "$DISK" || exit 1
do_ qm set "$VMID" --boot order=scsi0 || exit 1

echo "== 5. the start =="
do_ qm start "$VMID" || { [ "$RUN" = 0 ] || echo "   (a start the hookscript refused says why above: the sticks it waited for)"; exit 1; }

echo "== 6. the kit, installed in $NAME through its guest agent =="
if [ $RUN = 0 ]; then
  would "wait for the guest agent and cloud-init; unpack the kit in the VM and run its installer there (guest/install.sh --run --detect --initial-role $ROLE$([ $FIRST = 1 ] && echo ' --first')), its lines shown here"
  if [ -n "$PVMID" ]; then
    [ $DHCP = 0 ] && [ -n "$P_PEER" ] || would "tell $PNAME ($PNODE) this VM's address once DHCP has given it one (PEER in its zradio.conf; its keepalived is reloaded: when $PNAME serves, the floating address is gone for about 4 seconds)"
    would "introduce $NAME and $PNAME ($PNODE) to each other: each one's sync key and host key into the other (zradio-sync keys / trust), then a hello over that link"
  elif [ $NOUSB = 0 ]; then warn "this is the pair's first VM: run ./install.sh on the other node next — it finds $NAME and takes the pair's addresses and settings from it"; fi
  [ $START = 0 ] || would "systemctl start zradio.target in $NAME: it joins the pair"
  go_ahead "${ARGS[@]}"
fi
n=0; until agent_up "$NODE" "$VMID"; do n=$((n + 1)); [ $n -lt 60 ] || break; sleep "$WAIT"; done
agent_up "$NODE" "$VMID" && ok "the guest agent answers" || { bad "no guest agent in $((60 * WAIT)) s — the VM's console: qm terminal $VMID"; exit 1; }
st=""; n=0
while :; do
  st=$(gx "$NODE" "$VMID" 20 'cloud-init status' | awk '/^status:/ { print $2 }')
  case "$st" in done|error|degraded) break;; esac
  n=$((n + 1)); [ $n -lt 240 ] || break; sleep "$WAIT"
done
case "$st" in done|degraded) ok "cloud-init finished ($st)";; *) bad "cloud-init ended '${st:-no answer}' — in the VM: /var/log/cloud-init-output.log"; exit 1;; esac
gx "$NODE" "$VMID" 60 'mkdir -p /opt/zradio/kit && tar -xzf /root/zradio-kit.tgz -C /opt/zradio/kit' >/dev/null \
  || { bad "the kit did not unpack in $NAME (/root/zradio-kit.tgz, written by cloud-init)"; exit 1; }
INST="bash /opt/zradio/kit/guest/install.sh --conf /root/zradio.conf --from-node --run --detect --initial-role $ROLE$([ $FIRST = 1 ] && echo ' --first')"
run_guest_installer "$NODE" "$VMID" "$NAME" "$INST"; rc=$?
if [ $rc = 0 ]; then ok "the kit is installed in $NAME, as the initial $ROLE"
elif [ $NOUSB = 1 ] && printf '%s' "$GUEST_LOG" | grep -q "FAIL  zradio-detect did not end clean"; then
  ok "the drill went as far as a VM without a stick can: the VM, cloud-init, the kit unpacked, its packages — and the installer stopped at the detection, with no stick to find"
  trap - EXIT
  echo "== a drill. To remove it: qm stop $VMID; qm destroy $VMID --purge; and the file $SNIPDIR/$NAME-zradio.yaml =="
  exit 0
else bad "the installer ended $([ $rc = 98 ] && echo "without an exit code" || echo "$rc") in $NAME — nothing was started there. Its lines are above; to see it fail again in the VM: $INST"; exit 1; fi
VSELF=$(gx "$NODE" "$VMID" 20 'sed -n "s/^SELF=//p" /etc/zradio/zradio.conf' | tail -1 | tr -dc 0-9.)
ip4 "$VSELF" || { bad "could not read $NAME's own address from its /etc/zradio/zradio.conf (SELF)"; exit 1; }
VMAC=$(sed -n '/^\[/q; s/^net0:[^,]*=\([0-9A-Fa-f:]\{17\}\).*/\1/p' "$PVE/nodes/$NODE/qemu-server/$VMID.conf" 2>/dev/null | head -1)
[ $DHCP = 0 ] || ok "$NAME's own address is $VSELF, from DHCP: it is in its zradio.conf now, and the pair knows it by that address"
RAD=$(gx "$NODE" "$VMID" 20 'grep -E "^(ZWAVE|ZIGBEE)=" /etc/zradio/radios.conf')
ZW=$(printf '%s\n' "$RAD" | sed -n 's/^ZWAVE=//p' | tr -dc a-z); ZB=$(printf '%s\n' "$RAD" | sed -n 's/^ZIGBEE=//p' | tr -dc a-z)
has_kind() { case "$1" in served|synced) return 0;; *) return 1;; esac; }
ok "$NAME's radios: Z-Wave $(has_kind "$ZW" && echo yes || echo "none"), Zigbee $(has_kind "$ZB" && echo yes || echo "none")"
if [ -n "$PVMID" ]; then
  for k in Z-Wave:$ZW:$P_ZWAVE Zigbee:$ZB:$P_ZIGBEE; do
    IFS=: read -r kn mine theirs <<< "$k"
    if has_kind "$mine" && ! has_kind "$theirs"; then warn "$NAME has a $kn stick and $PNAME has none: $kn is served only while $NAME is the one that serves — it does not fail over"
    elif ! has_kind "$mine" && has_kind "$theirs"; then warn "$PNAME has a $kn stick and $NAME has none: $kn is served only while $PNAME is the one that serves — it does not fail over"; fi
  done
fi

if [ -n "$PVMID" ]; then
  echo "== 7. $NAME and $PNAME, introduced to each other =="
  keyre='^ssh-ed25519 [A-Za-z0-9+/=]{60,80}$'
  keys_of() { # keys_of <node> <vmid>: "SYNC<TAB>HOST", both checked
    local k s h; k=$(gx "$1" "$2" 30 '/usr/local/sbin/zradio-sync keys') || return 1
    s=$(printf '%s\n' "$k" | sed -n 's/^SYNCKEY //p'); h=$(printf '%s\n' "$k" | sed -n 's/^HOSTKEY //p')
    [[ "$s" =~ $keyre ]] && [[ "$h" =~ $keyre ]] || return 1
    printf '%s\t%s\n' "$s" "$h"
  }
  trust() { # trust <node> <vmid> <name> <"SYNC<TAB>HOST" of the other> <the other's name>
    gx "$1" "$2" 30 "/usr/local/sbin/zradio-sync trust --sync-key '${4%%$'\t'*}' --host-key '${4##*$'\t'}'" >/dev/null \
      && done_ "$3 trusts $5: its host key pinned, its sync key allowed to run the sync and nothing else" || { bad "zradio-sync trust failed in $3"; return 1; }
  }
  if [ "$P_PEER" != "$VSELF" ]; then     # the first VM was installed before this one had an address
    if TP=$(gx "$PNODE" "$PVMID" 180 "bash /opt/zradio/kit/guest/install.sh --peer $VSELF --from-node --run 2>&1"); then
      done_ "$PNAME knows its peer now: $VSELF (PEER in its zradio.conf, its keepalived.conf rendered again)"
      printf '%s\n' "$TP" | grep -E '^(DONE  keepalived reloaded|WARN  /etc/keepalived)' | sed 's/^/      | /'
    else printf '%s\n' "$TP" | grep -E '^(FAIL|REFUSED|unknown arg)' | sed 's/^/      | /'
      bad "$PNAME could not be told its peer's address $VSELF (in $PNAME: bash /opt/zradio/kit/guest/install.sh --peer $VSELF --run). Nothing was started"; exit 1; fi
  fi
  if KM=$(keys_of "$NODE" "$VMID") && KP=$(keys_of "$PNODE" "$PVMID"); then
    trust "$PNODE" "$PVMID" "$PNAME" "$KM" "$NAME" && trust "$NODE" "$VMID" "$NAME" "$KP" "$PNAME" || exit 1
    if h=$(gx "$NODE" "$VMID" 40 '/usr/local/sbin/zradio-sync peer-hello'); then ok "$NAME reached $PNAME over the sync's own link: $(printf '%s' "$h" | head -1 | cut -c1-120)"
    else bad "$NAME does not reach $PNAME at $P_SELF over ssh (zradio-sync peer-hello): the two are on the same network? Nothing was started"; exit 1; fi
  else bad "could not read the two VMs' public keys (zradio-sync keys in $NAME and in $PNAME)"; exit 1; fi
fi

if qm set "$VMID" --tags zradio >/dev/null; then trap - EXIT; done_ "$NAME is a radio VM of the kit from here on (its tag: zradio): ./install.sh on this node updates it"
else bad "qm set $VMID --tags zradio failed: $NAME stays marked as not finished"; exit 1; fi

echo "== $([ -n "$PVMID" ] && echo 8 || echo 7). the start =="
if [ $START = 0 ] && [ $ASK = 1 ]; then
  echo "   Starting $NAME puts it into the pair: $([ "$ROLE" = primary ] && echo "it takes the floating address ${VIP%/*} and serves this node's sticks" || echo "it stands by, and serves only after the primary's first sync has filled its sticks")."
  while :; do printf '   Start it now? [y/n]: '; read -r ANS || ANS=n; case "${ANS,,}" in y|yes) START=1; break;; n|no) break;; esac; done
fi
if [ $START = 1 ]; then
  gx "$NODE" "$VMID" 90 'systemctl start zradio.target' >/dev/null && done_ "systemctl start zradio.target in $NAME: it is in the pair" || bad "systemctl start zradio.target failed in $NAME"
  gx "$NODE" "$VMID" 30 '/usr/local/sbin/zradio-serve status' | sed 's/^/      | /'
else warn "$NAME is installed and not started. To start it: qm guest exec $VMID -- systemctl start zradio.target"; fi
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL =="; exit 1; }
zp=6639; gp=6638; for e in ${EXTRA[@]+"${EXTRA[@]}"}; do case "$e" in ZWAVE_PORT=*) zp=${e#*=};; ZIGBEE_PORT=*) gp=${e#*=};; esac; done
echo "== done: $NAME on $NODE =="
if [ -n "$PVMID" ]; then echo "   The pair is complete: $PNAME on $PNODE, $NAME on $NODE. $([ "$ROLE" = standby ] && echo "$PNAME" || echo "$NAME") writes its networks onto the other's sticks within 15 minutes of both being started."
else echo "   Next: ./install.sh on the other node. It finds $NAME, takes the pair's addresses and settings from it, and introduces the two to each other."; fi
if [ $DHCP = 1 ]; then
  echo "   In your DHCP server (the router): RESERVE $VSELF for $NAME${VMAC:+ (MAC $VMAC)}, and keep ${VIP%/*} out of the range it hands out."
  echo "   The pair knows $NAME by $VSELF: a VM whose address changes stops serving until it has that address back."
fi
ha_lines "${VIP%/*}" "$zp" "$gp" "$(has_kind "$ZW" && echo 1 || echo 0)" "$(has_kind "$ZB" && echo 1 || echo 0)"
echo "   Who serves, and why: qm guest exec $VMID -- zradio-serve status"
exit 0
