# shellcheck shell=bash
# host/update.sh — sourced by install.sh when this node has a radio VM of the kit already: that VM, and the pair's other
# VM, brought to this kit. Nothing is rebuilt. The kit is sent into each VM through its guest agent and the kit's own
# installer runs there again (guest/install.sh --from-node --run): it replaces only the files that differ and does not
# stop the radios. A VM whose installed kit has this kit's CONTENT (guest/lib/zradio-kit-stamp.sh) is up to date and is
# left alone. The VM that does not serve goes first, so a failed update leaves the one that serves untouched.

if [ -n "$UPDATE" ]; then
  U=$(printf '%s\n' "$MINE" | awk -v n="$UPDATE" '$2 == n')
  [ -n "$U" ] || die "--update '$UPDATE': no radio VM of the kit (tag zradio) by that name on $NODE"
elif [ "$(printf '%s\n' "$MINE" | grep -c .)" -gt 1 ]; then
  die "more than one radio VM of the kit on $NODE ($(printf '%s\n' "$MINE" | awk '{ printf "%s ", $2 }')): say which with --update NAME"
else U=$MINE; fi
read -r UVMID UNAME _ <<< "$U"
[ -z "$ROLE$SELF$VIP$PAIR_BRIDGE" ] || warn "an update keeps $UNAME's own settings: --initial-role, --self, --vip and the like are for a new VM and are not used"

echo "== $UNAME on $NODE is a radio VM of this kit: an update to $KIT_VERSION ($([ $RUN = 1 ] && echo RUN || echo "report only: nothing is changed")) =="
# the pair: this VM, and the one on another node (when there is exactly one)
TARGETS=("$NODE $UVMID $UNAME")
OTHER=$(kit_vms elsewhere)
case "$(printf '%s\n' "$OTHER" | grep -c .)" in
  0) warn "no radio VM of the kit on another node: $UNAME has no peer yet";;
  1) read -r OVMID ONAME ONODE _ <<< "$OTHER"; TARGETS+=("$ONODE $OVMID $ONAME");;
  *) warn "more than one radio VM of the kit on other nodes ($(printf '%s\n' "$OTHER" | awk '{ printf "%s ", $2 }')): only $UNAME is updated here; run ./install.sh on each one's node";;
esac

# the pair's floating address is looked up here too: every end of this run names it, with the line for Home Assistant
# shellcheck disable=SC2086  # HA is five words
ha_say() { [ -z "$HA" ] || ha_lines $HA; }
# what each one runs now
TODO=() SERVES="" HA=""      # HA: what ha_lines takes, from the first VM that answers
for t in "${TARGETS[@]}"; do
  read -r tn ti tname <<< "$t"
  if ! agent_up "$tn" "$ti"; then bad "$tname on $tn does not answer (its guest agent): start it first (qm start $ti on $tn)"; continue; fi
  st=$(vm_kit "$tn" "$ti") || { bad "could not ask $tname which kit it runs (through its guest agent)"; continue; }
  tv=$(kv VERSION "$st"); tc=$(kv CONTENT "$st")
  [ "$(kv SERVING "$st")" = yes ] && SERVES=$tname
  if [ -z "$HA" ] && hv=$(kv HA_VIP "$st") && ip4 "$hv"; then
    zp=$(kv HA_ZWAVE_PORT "$st"); gp=$(kv HA_ZIGBEE_PORT "$st")
    HA="$hv ${zp:-6639} ${gp:-6638} $([ "$(kv HA_ZWAVE "$st")" = none ] && echo 0 || echo 1) $([ "$(kv HA_ZIGBEE "$st")" = none ] && echo 0 || echo 1)"
  fi
  if [ "$tc" = "$KIT_CONTENT" ]; then ok "$tname on $tn runs this kit already: $tv"
  else
    ok "$tname on $tn runs ${tv:+$tv, }$([ -n "$tc" ] && echo "not this kit" || echo "a kit from before versions were kept")$([ "$(kv SERVING "$st")" = yes ] && echo " — it serves the radios now")"
    if [ "$(kv SERVING "$st")" = yes ]; then TODO+=("$t"); else TODO=("$t" ${TODO[@]+"${TODO[@]}"}); fi   # the one that does not serve first
  fi
done
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL — nothing was changed =="; exit 1; }

if [ ${#TODO[@]} -eq 0 ]; then
  echo "== up to date: $(for t in "${TARGETS[@]}"; do read -r _ _ tname <<< "$t"; printf '%s ' "$tname"; done)run $KIT_VERSION =="
  ha_say
  exit 0
fi

if [ $RUN = 0 ]; then
  for t in "${TODO[@]}"; do
    read -r tn ti tname <<< "$t"
    would "send this kit into $tname ($tn) through its guest agent; its kit now kept as /opt/zradio/kit.previous"
    would "run the kit's installer in $tname (guest/install.sh --from-node --run): the files that differ are replaced, the radios keep running$([ "$tname" = "$SERVES" ] && echo " (it serves: it goes last)")"
  done
  ARGS=(--update "$UNAME" ${PASS[@]+"${PASS[@]}"})
  ha_say
  go_ahead "${ARGS[@]}"
fi

k=0
for t in "${TODO[@]}"; do
  read -r tn ti tname <<< "$t"; k=$((k + 1))
  echo "== $tname on $tn =="
  send_kit "$tn" "$ti" "$tname" || exit 1
  run_guest_installer "$tn" "$ti" "$tname" "bash /opt/zradio/kit/guest/install.sh --from-node --run"; rc=$?
  if [ $rc = 0 ]; then ok "$tname runs $KIT_VERSION now"
  else bad "the installer ended $([ $rc = 98 ] && echo "without an exit code" || echo "$rc") in $tname. Its lines are above. The kit it had is at /opt/zradio/kit.previous; to put it back: bash /opt/zradio/kit.previous/guest/install.sh --from-node --run$([ $k -lt ${#TODO[@]} ] && echo ". The other VM was not touched: it still runs its kit")"
    exit 1
  fi
done
[ $FAILS -eq 0 ] || { echo "== $FAILS FAIL =="; exit 1; }
echo "== done: $(for t in "${TARGETS[@]}"; do read -r _ _ tname <<< "$t"; printf '%s ' "$tname"; done)run $KIT_VERSION =="
ha_say
exit 0
