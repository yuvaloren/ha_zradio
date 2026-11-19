# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables set here are read by the tools that source this file
# zradio-common.sh — sourced by the zradio tools inside a radio VM: the two config files, checked before they are read;
# and the few helpers every tool needs (the role, the journal, the marker files, the Z-Wave receiver).
#
#   /etc/zradio/zradio.conf   what a person (or the node's install.sh) decided: this VM's name, the pair's addresses, the
#                             ports. THE one file to edit. See zradio.conf.example.
#   /etc/zradio/radios.conf   what zradio-detect found on this VM's USB ports: which radios, which family, and what the
#                             kit can do with each ("synced" or "served"). Written by `zradio-detect --write`; edit it
#                             only to overrule the detection.
#
# Both are shell assignments and nothing else: a line that is not `KEY=value` with a harmless value refuses the whole
# file (it is sourced by root), and so does a key that is not one of the file's own (ZR_CONF_KEYS, ZR_RADIOS_KEYS): a
# mistyped key would leave its default in force without a word, and a key such as STATE or PATH would overwrite a
# variable of the tool that sources it. Functions return 1 with the reason in ZR_ERR; the caller decides how to say it.
# Env for the tests: ZRADIO_CONF, ZRADIO_RADIOS, ZRADIO_IP (the `ip` command).
ZR_CONF=${ZRADIO_CONF:-/etc/zradio/zradio.conf}
ZR_RADIOS=${ZRADIO_RADIOS:-/etc/zradio/radios.conf}
ZR_ERR=""
# The Z-Wave JS UI the standby writes a copy with (ZUI_IMAGE overrides): a release by its tag AND by the digest of its
# image index (what the registry answers for that tag, for every architecture). The tag says which release it is; the
# digest is what podman pulls, so that the image is the one the kit was tried with whatever the tag points at later.
# A release is taken here only after a sync with it was seen on a pair (tests/check-pins.sh says when there is one).
ZR_ZUI_IMAGE=docker.io/zwavejs/zwave-js-ui:11.27.0@sha256:0f3ad23ccf5ff2256ad8cc060ab0fc987b8f52a8427eac337f93b058fa628f35
# How that image is run (zradio-apply for a write; guest/install.sh once, to see that it starts so on this machine):
# never pulled then (a sync must not depend on the internet, nor take whatever a tag points at that day); as root for
# the stick, with no capability but the one that opens a device file whatever its owner; it can gain none.
ZR_ZUI_RUN_OPTS="--pull=never --cap-drop=all --cap-add=DAC_OVERRIDE --security-opt no-new-privileges"
ZR_LOG_MAX=400          # a journal line is cut here: the longest the tools write (a sync's identities) fits
ZR_RF_TRIES=4           # SetRFReceiveMode tries: right after power-on a Z-Wave stick answers CAN for about 5 s
ZR_RF_PAUSE=3           # s between two of those tries
ZR_LOCK_WAIT=${ZRADIO_SERVE_LOCK_WAIT:-90}   # s a tool waits for the sticks lock (zradio-serve.service's stop timeout)

zr_kv_only() { # zr_kv_only <file>: 0 when every line is blank, a comment, or KEY=value
  local odd
  odd=$(grep -vE '^[[:space:]]*(#.*)?$' "$1" | grep -vE '^[A-Z][A-Z0-9_]*=[A-Za-z0-9./:_@+-]*$' | head -1) || true
  [ -z "$odd" ]
}
ZR_CONF_KEYS="NAME SELF PEER VIP VRID PRIORITY IFACE ZWAVE_PORT ZIGBEE_PORT SYNC_AT SYNC_TZ ELECTION ELECTION_WAIT ZUI_IMAGE ZIGPY_VERSION"
ZR_RADIOS_KEYS="ZWAVE ZWAVE_FAMILY ZWAVE_TTY ZWAVE_BAUD ZWAVE_FLOW ZIGBEE ZIGBEE_FAMILY ZIGBEE_TTY ZIGBEE_BAUD ZIGBEE_FLOW"
zr_keys_only() { # zr_keys_only <file> "<keys>": 0 when every KEY of the file is one of those; else 1, the first other in ZR_ODD
  local k; ZR_ODD=""
  while IFS= read -r k; do
    case " $2 " in *" $k "*) ;; *) ZR_ODD=$k; return 1;; esac
  done < <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1")
  return 0
}
zr_ip4() { # zr_ip4 <text>: 0 for a dotted IPv4 host address, 1-223 first, not 127 (.0 / .255 ends: prefixes vary)
  local a=$1 o
  [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
  o=$((10#${BASH_REMATCH[1]}))
  [ "$o" -ge 1 ] && [ "$o" -le 223 ] && [ "$o" != 127 ]
}
zr_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

zr_load_conf() { # the pair's conf into NAME SELF PEER VIP VRID PRIORITY IFACE ZWAVE_PORT ZIGBEE_PORT SYNC_AT SYNC_TZ
  #                ELECTION ELECTION_WAIT ZUI_IMAGE ZIGPY_VERSION
  NAME="" SELF="" PEER="" VIP="" VRID="" PRIORITY="" IFACE=""
  ZWAVE_PORT=6639 ZIGBEE_PORT=6638 SYNC_AT=04:30 SYNC_TZ="" ELECTION=observe ELECTION_WAIT=60
  ZUI_IMAGE=$ZR_ZUI_IMAGE
  ZIGPY_VERSION=2.0.0
  [ -r "$ZR_CONF" ] || { ZR_ERR="no $ZR_CONF (copy zradio.conf.example there and fill it in)"; return 1; }
  zr_kv_only "$ZR_CONF" \
    || { ZR_ERR="$ZR_CONF holds a line that is not KEY=value (it is sourced: nothing else may be in it)"; return 1; }
  zr_keys_only "$ZR_CONF" "$ZR_CONF_KEYS" \
    || { ZR_ERR="$ZR_CONF: $ZR_ODD: not a key of this file (a typo? Its keys: $ZR_CONF_KEYS)"; return 1; }
  # shellcheck disable=SC1090
  . "$ZR_CONF"
  [[ "$NAME" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { ZR_ERR="NAME '$NAME': a short lower-case name"; return 1; }
  zr_ip4 "$SELF" || { ZR_ERR="SELF '$SELF': this VM's own IPv4 address"; return 1; }
  [ -z "$PEER" ] || zr_ip4 "$PEER" \
    || { ZR_ERR="PEER '$PEER': the other radio VM's IPv4 address (empty: this VM has no peer yet)"; return 1; }
  local vip_a=${VIP%/*} vip_p=${VIP##*/}
  [ "$VIP" != "$vip_a" ] && zr_ip4 "$vip_a" && [[ "$vip_p" =~ ^[0-9]{1,2}$ ]] && [ "$vip_p" -ge 8 ] && [ "$vip_p" -le 32 ] \
    || { ZR_ERR="VIP '$VIP': the floating address as A.B.C.D/prefix"; return 1; }
  [ "$SELF" != "$PEER" ] || { ZR_ERR="SELF and PEER are both $SELF"; return 1; }
  [ "$SELF" != "$vip_a" ] && [ "$PEER" != "$vip_a" ] \
    || { ZR_ERR="the VIP $vip_a is SELF or PEER: the floating address is a third one"; return 1; }
  [[ "$VRID" =~ ^[0-9]+$ ]] && [ "$VRID" -ge 1 ] && [ "$VRID" -le 255 ] || { ZR_ERR="VRID '$VRID': 1-255"; return 1; }
  [[ "$PRIORITY" =~ ^[0-9]+$ ]] && [ "$PRIORITY" -ge 1 ] && [ "$PRIORITY" -le 254 ] \
    || { ZR_ERR="PRIORITY '$PRIORITY': 1-254"; return 1; }
  [ -z "$IFACE" ] || [[ "$IFACE" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,14}$ ]] \
    || { ZR_ERR="IFACE '$IFACE': an interface name, or empty"; return 1; }
  zr_port "$ZWAVE_PORT" && zr_port "$ZIGBEE_PORT" && [ "$ZWAVE_PORT" != "$ZIGBEE_PORT" ] \
    || { ZR_ERR="ZWAVE_PORT '$ZWAVE_PORT' / ZIGBEE_PORT '$ZIGBEE_PORT': two different ports, 1024-65535"; return 1; }
  [[ "$SYNC_AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { ZR_ERR="SYNC_AT '$SYNC_AT': HH:MM"; return 1; }
  [ -z "$SYNC_TZ" ] || [[ "$SYNC_TZ" =~ ^[A-Za-z][A-Za-z0-9_+/-]{1,40}$ ]] \
    || { ZR_ERR="SYNC_TZ '$SYNC_TZ': a time zone name (Europe/Berlin), or empty for the VM's own"; return 1; }
  case "$ELECTION" in observe|act) ;; *) ZR_ERR="ELECTION '$ELECTION': observe or act"; return 1;; esac
  [[ "$ELECTION_WAIT" =~ ^[0-9]{2,3}$ ]] && [ "$ELECTION_WAIT" -ge 20 ] && [ "$ELECTION_WAIT" -le 600 ] \
    || { ZR_ERR="ELECTION_WAIT '$ELECTION_WAIT': 20-600 seconds (a VM needs about 10 s from its claim to serving;"
         ZR_ERR="$ZR_ERR a shorter wait gives up on it too early)"; return 1; }
  [[ "$ZUI_IMAGE" =~ ^[a-z0-9][a-z0-9./_-]*:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?$ ]] \
    || { ZR_ERR="ZUI_IMAGE '$ZUI_IMAGE': registry/name:tag, or registry/name:tag@sha256:<64 hex digits> (a pinned release)"; return 1; }
  [[ "$ZIGPY_VERSION" =~ ^[0-9]+(\.[0-9a-z]+){1,3}$ ]] \
    || { ZR_ERR="ZIGPY_VERSION '$ZIGPY_VERSION': a zigpy-cli release, like 2.0.0 (a pinned version)"; return 1; }
  return 0
}

zr_load_radios() { # what zradio-detect found into ZWAVE / ZIGBEE (none|served|synced), *_FAMILY, *_TTY, *_BAUD, *_FLOW
  ZWAVE=none ZIGBEE=none ZWAVE_FAMILY="" ZIGBEE_FAMILY=""
  ZWAVE_TTY=/dev/zradio-zwave ZIGBEE_TTY=/dev/zradio-zigbee
  ZWAVE_BAUD=115200 ZIGBEE_BAUD=115200 ZWAVE_FLOW=none ZIGBEE_FLOW=none
  [ -r "$ZR_RADIOS" ] || { ZR_ERR="no $ZR_RADIOS (zradio-detect --write makes it)"; return 1; }
  zr_kv_only "$ZR_RADIOS" || { ZR_ERR="$ZR_RADIOS holds a line that is not KEY=value"; return 1; }
  zr_keys_only "$ZR_RADIOS" "$ZR_RADIOS_KEYS" \
    || { ZR_ERR="$ZR_RADIOS: $ZR_ODD: not a key of this file (its keys: $ZR_RADIOS_KEYS)"; return 1; }
  # shellcheck disable=SC1090
  . "$ZR_RADIOS"
  local k
  for k in "$ZWAVE" "$ZIGBEE"; do case "$k" in none|served|synced) ;;
    *) ZR_ERR="$ZR_RADIOS: a level is '$k', not none, served or synced"; return 1;; esac; done
  for k in "$ZWAVE_BAUD" "$ZIGBEE_BAUD"; do
    [[ "$k" =~ ^[0-9]{4,7}$ ]] || { ZR_ERR="$ZR_RADIOS: a baud rate is '$k'"; return 1; }; done
  for k in "$ZWAVE_FLOW" "$ZIGBEE_FLOW"; do case "$k" in none|hardware|software) ;;
    *) ZR_ERR="$ZR_RADIOS: a flow control is '$k', not none, hardware or software"; return 1;; esac; done
  return 0
}
zr_has() { # zr_has zwave|zigbee [level]: this VM has that radio (at that level)
  local lv; case "$1" in zwave) lv=$ZWAVE;; zigbee) lv=$ZIGBEE;; *) return 1;; esac
  if [ $# -ge 2 ]; then [ "$lv" = "$2" ]; else [ "$lv" != none ]; fi
}

# The version of the networks a VM's sticks hold (docs/DESIGN.md, "Who serves when it is not obvious"): a counter,
# never a clock. `term` goes up when Home Assistant starts using a VM in a confirmed serving turn; a sync gives the
# standby the active's term with used=no.
zr_version_read() { # zr_version_read <state dir>: into ZR_TERM, ZR_USED (0 / no when there is no record)
  ZR_TERM=0 ZR_USED=no
  local l; l=$(cat "$1/version" 2>/dev/null) || return 0
  if [[ "$l" =~ ^term=([0-9]{1,9})\ used=(yes|no)$ ]]; then ZR_TERM=$((10#${BASH_REMATCH[1]})); ZR_USED=${BASH_REMATCH[2]}; fi
  return 0
}
zr_version_write() { # zr_version_write <state dir> <term> <yes|no>
  mkdir -p "$1" && printf 'term=%s used=%s\n' "$2" "$3" > "$1/version.tmp" && mv -f "$1/version.tmp" "$1/version"
}
zr_vkey() { # zr_vkey <term> <yes|no>: one number; the higher one is the more advanced copy
  local u=0; [ "$2" = yes ] && u=1
  [[ "$1" =~ ^[0-9]{1,9}$ ]] || { echo 0; return; }
  echo $(( 10#$1 * 2 + u ))
}

zr_iface() { # the pair's interface into ZR_IFACE: IFACE from the conf, else the one that holds SELF; 1 when none does.
  # (Sets a variable instead of printing: called as $(zr_iface) the reason in ZR_ERR would stay in the subshell.)
  ZR_IFACE=${IFACE:-}
  [ -z "$ZR_IFACE" ] || return 0
  ZR_IFACE=$("${ZRADIO_IP:-ip}" -o -4 addr show 2>/dev/null \
    | awk -v a="$SELF" '{ split($4, x, "/"); if (x[1] == a) { print $2; exit } }')
  [ -n "$ZR_IFACE" ] || { ZR_ERR="no interface holds SELF $SELF (set IFACE in $ZR_CONF, or give this VM that address)"; return 1; }
}
zr_holds_self() { # 0 when an interface of this VM holds SELF — or when that cannot be told (no `ip`, no answer). 1: the
  # VM's address is not the one the pair knows it by (an address from DHCP that changed); what it holds instead is in
  # ZR_HOLDS. The other VM cannot hear this one then, and keepalived would still claim the floating address
  # [V keepalived 2.3: MASTER within 4 s on an address that is not its unicast_src_ip] — so such a VM does not serve.
  local out; ZR_HOLDS=""
  out=$("${ZRADIO_IP:-ip}" -o -4 addr show scope global 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  ZR_HOLDS=$(printf '%s\n' "$out" | awk '{ split($4, x, "/"); printf "%s%s", (n++ ? " " : ""), x[1] }')
  printf '%s\n' "$out" | awk -v a="$SELF" '{ split($4, x, "/"); if (x[1] == a) f = 1 } END { exit !f }'
}

# ---------------------------------------------------------------- what the tools tell each other
# Files under RUN (/run/zradio: gone at boot) and STATE (/var/lib/zradio: kept). Each tool sets RUN and STATE (its own
# env knobs, for the tests) and then calls zr_markers. One lock orders every change to the sticks: STICKS_LOCK.
zr_markers() {
  ROLE_F="$RUN/role"                 # keepalived's last word: MASTER|BACKUP|FAULT|STOP <time> (zradio-notify)
  STICKS_LOCK="$RUN/sticks.lock"     # held while a tool talks to the sticks (zr_sticks_lock)
  VERSION_LOCK="$RUN/version.lock"   # held while the version and the election's files change together (zr_version_lock)
  TURN_F="$RUN/turn"                 # this serving turn: confirmed | provisional (zradio-serve up, zradio-gate)
  WOULD_TURN="$RUN/observe/turn"     # ELECTION=observe: act mode would have made this turn provisional (zradio-gate)
  FAILED="$RUN/serve-failed"         # `zradio-serve up` failed: out of the election for a while
  APPLYING="$RUN/applying"           # a set is being written onto the sticks (zradio-sync)
  DIRTY="$STATE/standby-dirty"       # a set was not written to the end: this VM may not serve (zradio-sync)
  WEDGED="$STATE/stick-wedged"       # a stick stopped answering (zradio-change-watch; zradio-serve hush clears it)
  WANT="$STATE/want-power"           # `<stick> <epoch>`: this VM asks its node to switch the sticks' power off and on
                                     # (zradio-serve hush writes it; the node's helper, host/hook.sh, reads it)
  POWERED="$STATE/power-cycled"      # the epoch of the node's last such power cycle (zradio-serve power-done)
  MISSING_SINCE="$STATE/missing-since"  # the epoch a stick's tty was first seen missing (zradio-serve down, hush)
  zr_gate_files "$RUN" "$STATE"
}
zr_gate_files() { # zr_gate_files <run dir> <state dir>: the election's files there (zradio-gate writes them; in act
  # mode under RUN and STATE, where zradio-serve and zradio-sync read them)
  BOOT_WAIT="$1/boot-wait"           # at boot: the peer was not asked yet — this VM claims nothing
  HOLD="$1/hold"                     # outdated, and the peer may still serve: this VM may not
  MAY_SERVE="$1/outdated-may-serve"  # outdated, but the peer has not served for the standard wait: released
  ALONE="$1/gate-alone"              # nobody answered at boot: a turn started now is provisional
  OUTDATED="$2/outdated"             # the peer holds a higher term: `term=N zbfloor=N` (on disk: a reboot keeps it)
}

zr_holds_vip() { # 0: an interface of this VM holds the floating address now; 1: none does; 2: it cannot be told (no
  # conf read, no `ip`, no answer). This is the truth about the role. keepalived's last word (the role file) comes
  # through notify scripts that keepalived forks without waiting: two that come within milliseconds of each other can
  # be written in either order, and the file then says the opposite of what is.
  local out; [ -n "${VIP:-}" ] || return 2
  out=$("${ZRADIO_IP:-ip}" -o -4 addr show 2>/dev/null) || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | awk -v a="${VIP%/*}" '{ split($4, x, "/"); if (x[1] == a) f = 1 } END { exit !f }'
}
zr_serving() { "${SYSTEMCTL:-systemctl}" is-active --quiet ser2net 2>/dev/null; }   # ser2net runs: this VM serves
zr_role() { cut -d' ' -f1 "$ROLE_F" 2>/dev/null || echo none; }                    # keepalived's last word
zr_master_or_serving() { zr_serving || [ "$(zr_role)" = MASTER ]; }                # this VM serves, or is about to
zr_now() { printf '%s' "${EPOCHREALTIME:-$(date +%s)}"; }                          # seconds, with a fraction
zr_since() { awk -v a="$1" -v b="$(zr_now)" 'BEGIN { printf "%.1f", b - a }'; }    # zr_since <zr_now's>: seconds since
zr_need_root() { [ "$(id -u)" = 0 ] || { echo "die: run as root" >&2; exit 2; }; }
zr_sticks_lock() { # take STICKS_LOCK on fd 7, waiting at most ZR_LOCK_WAIT s; 1 when it did not come
  mkdir -p "$(dirname "$STICKS_LOCK")" && exec 7>"$STICKS_LOCK" && flock -w "$ZR_LOCK_WAIT" 7
}
zr_sticks_unlock() { exec 7>&-; }
zr_version_lock() { # take VERSION_LOCK on fd 6 (a sync's landing, zradio-gate's writes, a yield's mark): a few file writes
  mkdir -p "$(dirname "$VERSION_LOCK")" && exec 6>"$VERSION_LOCK" && flock -w "$ZR_LOCK_WAIT" 6
}
zr_version_unlock() { exec 6>&-; }

zr_field() { # zr_field "<k=v k=v …>" <k>: the first value of k in a line of words (a hello line), or nothing
  local w words; read -ra words <<<"$1"
  for w in "${words[@]}"; do [ "${w%%=*}" != "$2" ] || { printf '%s\n' "${w#*=}"; return 0; }; done
}
zr_json() { # zr_json <file|-> <key.key…>: one value of a JSON file (- = stdin), or nothing (no file, not JSON, no key)
  python3 -c 'import json, sys
try: d = json.load(sys.stdin if sys.argv[1] == "-" else open(sys.argv[1]))
except Exception: d = None
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null
}

zr_log() { # zr_log <event> <result> <text>: one journal line `zradio: event=… result=… text` (LOGGER: the caller's)
  "${LOGGER:-logger}" -t zradio "event=$1 result=$2 $(printf '%s' "$3" | tr '\n"' ' _' | cut -c1-"$ZR_LOG_MAX")" \
    2>/dev/null || true
}
zr_say() { printf '%s  %s\n' "$2" "$3"; zr_log "$@"; }    # zr_say <event> <result> <text>: on stdout and in the journal

# The report-mode tools' lines (zradio-apply, zradio-switch, guest/install.sh): a FAIL is counted.
FAILS=${FAILS:-0}
ok()    { printf 'OK    %s\n' "$*"; }
warn()  { printf 'WARN  %s\n' "$*"; }
bad()   { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
done_() { printf 'DONE  %s\n' "$*"; }
would() { printf 'WOULD %s\n' "$*"; }

zr_receiver() { # zr_receiver on|off <tty> <stderr file> [tries] [pause]: SetRFReceiveMode through PROBE (the caller's),
  # tried again on no answer; 0 when the stick said success (at try ZR_RF_TRY)
  local want=$1 tty=$2 err=$3 tries=${4:-$ZR_RF_TRIES} pause=${5:-$ZR_RF_PAUSE} i
  for ((i = 1; i <= tries; i++)); do
    python3 "$PROBE" --zwave "$tty" --rf-receive "$want" --json >/dev/null 2>"$err" \
      && grep -q "RF receive mode ${want^^}" "$err" && { ZR_RF_TRY=$i; return 0; }
    [ "$i" = "$tries" ] || sleep "$pause"
  done
  return 1
}
