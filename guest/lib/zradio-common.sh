# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables set here are read by the tools that source this file
# zradio-common.sh — sourced by the zradio tools inside a radio VM: the two config files, checked before they are read.
#
#   /etc/zradio/zradio.conf   what a person (or the node helper) decided: this VM's name, the pair's addresses, the
#                             ports. THE one file to edit. See zradio.conf.example.
#   /etc/zradio/radios.conf   what zradio-detect found on this VM's USB ports: which radios, which family, and what the
#                             kit can do with each ("synced" or "served"). Written by `zradio-detect --write`; edit it
#                             only to overrule the detection.
#
# Both are shell assignments and nothing else: a line that is not `KEY=value` with a harmless value refuses the whole
# file (it is sourced by root). Functions return 1 with the reason in ZR_ERR; the caller decides how to say it.
# Env for the tests: ZRADIO_CONF, ZRADIO_RADIOS, ZRADIO_IP (the `ip` command).
ZR_CONF=${ZRADIO_CONF:-/etc/zradio/zradio.conf}
ZR_RADIOS=${ZRADIO_RADIOS:-/etc/zradio/radios.conf}
ZR_ERR=""

zr_kv_only() { # zr_kv_only <file>: 0 when every line is blank, a comment, or KEY=value
  local odd
  odd=$(grep -vE '^[[:space:]]*(#.*)?$' "$1" | grep -vE '^[A-Z][A-Z0-9_]*=[A-Za-z0-9./:_@+-]*$' | head -1) || true
  [ -z "$odd" ]
}
zr_ip4() { # zr_ip4 <text>: 0 for a dotted IPv4 host address (no 0.x, no 224+, no .0 / .255 ends are NOT checked: prefixes vary)
  local a=$1 o
  [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
  [ "$((10#${BASH_REMATCH[1]}))" -ge 1 ] && [ "$((10#${BASH_REMATCH[1]}))" -le 223 ] && [ "$((10#${BASH_REMATCH[1]}))" != 127 ]
}
zr_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

zr_load_conf() { # the pair's conf into NAME SELF PEER VIP VRID PRIORITY IFACE ZWAVE_PORT ZIGBEE_PORT SYNC_AT SYNC_TZ ZUI_IMAGE ZIGPY_VERSION
  NAME="" SELF="" PEER="" VIP="" VRID="" PRIORITY="" IFACE=""
  ZWAVE_PORT=6639 ZIGBEE_PORT=6638 SYNC_AT=04:30 SYNC_TZ="" ELECTION=observe ELECTION_WAIT=60
  ZUI_IMAGE=docker.io/zwavejs/zwave-js-ui:11.25.2
  ZIGPY_VERSION=2.0.0
  [ -r "$ZR_CONF" ] || { ZR_ERR="no $ZR_CONF (copy zradio.conf.example there and fill it in)"; return 1; }
  zr_kv_only "$ZR_CONF" || { ZR_ERR="$ZR_CONF holds a line that is not KEY=value (it is sourced: nothing else may be in it)"; return 1; }
  # shellcheck disable=SC1090
  . "$ZR_CONF"
  [[ "$NAME" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { ZR_ERR="NAME '$NAME': a short lower-case name"; return 1; }
  zr_ip4 "$SELF" || { ZR_ERR="SELF '$SELF': this VM's own IPv4 address"; return 1; }
  [ -z "$PEER" ] || zr_ip4 "$PEER" || { ZR_ERR="PEER '$PEER': the other radio VM's IPv4 address (empty: this VM has no peer yet)"; return 1; }
  local vip_a=${VIP%/*} vip_p=${VIP##*/}
  [ "$VIP" != "$vip_a" ] && zr_ip4 "$vip_a" && [[ "$vip_p" =~ ^[0-9]{1,2}$ ]] && [ "$vip_p" -ge 8 ] && [ "$vip_p" -le 32 ] \
    || { ZR_ERR="VIP '$VIP': the floating address as A.B.C.D/prefix"; return 1; }
  [ "$SELF" != "$PEER" ] || { ZR_ERR="SELF and PEER are both $SELF"; return 1; }
  [ "$SELF" != "${VIP%/*}" ] && [ "$PEER" != "${VIP%/*}" ] || { ZR_ERR="the VIP ${VIP%/*} is SELF or PEER: the floating address is a third one"; return 1; }
  [[ "$VRID" =~ ^[0-9]+$ ]] && [ "$VRID" -ge 1 ] && [ "$VRID" -le 255 ] || { ZR_ERR="VRID '$VRID': 1-255"; return 1; }
  [[ "$PRIORITY" =~ ^[0-9]+$ ]] && [ "$PRIORITY" -ge 1 ] && [ "$PRIORITY" -le 254 ] || { ZR_ERR="PRIORITY '$PRIORITY': 1-254"; return 1; }
  [ -z "$IFACE" ] || [[ "$IFACE" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,14}$ ]] || { ZR_ERR="IFACE '$IFACE': an interface name, or empty"; return 1; }
  zr_port "$ZWAVE_PORT" && zr_port "$ZIGBEE_PORT" && [ "$ZWAVE_PORT" != "$ZIGBEE_PORT" ] || { ZR_ERR="ZWAVE_PORT '$ZWAVE_PORT' / ZIGBEE_PORT '$ZIGBEE_PORT': two different ports, 1024-65535"; return 1; }
  [[ "$SYNC_AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { ZR_ERR="SYNC_AT '$SYNC_AT': HH:MM"; return 1; }
  [ -z "$SYNC_TZ" ] || [[ "$SYNC_TZ" =~ ^[A-Za-z][A-Za-z0-9_+/-]{1,40}$ ]] || { ZR_ERR="SYNC_TZ '$SYNC_TZ': a time zone name (Europe/Berlin), or empty for the VM's own"; return 1; }
  case "$ELECTION" in observe|act) ;; *) ZR_ERR="ELECTION '$ELECTION': observe or act"; return 1;; esac
  [[ "$ELECTION_WAIT" =~ ^[0-9]{2,3}$ ]] && [ "$ELECTION_WAIT" -ge 20 ] && [ "$ELECTION_WAIT" -le 600 ] || { ZR_ERR="ELECTION_WAIT '$ELECTION_WAIT': 20-600 seconds (a VM needs about 10 s from its claim to serving; a shorter wait gives up on it too early)"; return 1; }
  [[ "$ZUI_IMAGE" =~ ^[a-z0-9][a-z0-9./_-]*:[A-Za-z0-9._-]+$ ]] || { ZR_ERR="ZUI_IMAGE '$ZUI_IMAGE': registry/name:tag (a pinned tag)"; return 1; }
  [[ "$ZIGPY_VERSION" =~ ^[0-9]+(\.[0-9a-z]+){1,3}$ ]] || { ZR_ERR="ZIGPY_VERSION '$ZIGPY_VERSION': a zigpy-cli release, like 2.0.0 (a pinned version)"; return 1; }
  return 0
}

zr_load_radios() { # what zradio-detect found into ZWAVE / ZIGBEE (none|served|synced), *_FAMILY, *_TTY, *_BAUD, *_FLOW
  ZWAVE=none ZIGBEE=none ZWAVE_FAMILY="" ZIGBEE_FAMILY=""
  ZWAVE_TTY=/dev/zradio-zwave ZIGBEE_TTY=/dev/zradio-zigbee ZWAVE_BAUD=115200 ZIGBEE_BAUD=115200 ZWAVE_FLOW=none ZIGBEE_FLOW=none
  [ -r "$ZR_RADIOS" ] || { ZR_ERR="no $ZR_RADIOS (zradio-detect --write makes it)"; return 1; }
  zr_kv_only "$ZR_RADIOS" || { ZR_ERR="$ZR_RADIOS holds a line that is not KEY=value"; return 1; }
  # shellcheck disable=SC1090
  . "$ZR_RADIOS"
  local k
  for k in "$ZWAVE" "$ZIGBEE"; do case "$k" in none|served|synced) ;; *) ZR_ERR="$ZR_RADIOS: a level is '$k', not none, served or synced"; return 1;; esac; done
  for k in "$ZWAVE_BAUD" "$ZIGBEE_BAUD"; do [[ "$k" =~ ^[0-9]{4,7}$ ]] || { ZR_ERR="$ZR_RADIOS: a baud rate is '$k'"; return 1; }; done
  for k in "$ZWAVE_FLOW" "$ZIGBEE_FLOW"; do case "$k" in none|hardware|software) ;; *) ZR_ERR="$ZR_RADIOS: a flow control is '$k', not none, hardware or software"; return 1;; esac; done
  return 0
}
zr_has() { # zr_has zwave|zigbee [level]: this VM has that radio (at that level)
  local lv; case "$1" in zwave) lv=$ZWAVE;; zigbee) lv=$ZIGBEE;; *) return 1;; esac
  if [ $# -ge 2 ]; then [ "$lv" = "$2" ]; else [ "$lv" != none ]; fi
}

# The version of the networks a VM's sticks hold (docs/DESIGN.md §3a): a counter, never a clock. `term` goes up when
# Home Assistant starts using a VM in a confirmed serving turn; a sync gives the standby the active's term with used=no.
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
  ZR_IFACE=$("${ZRADIO_IP:-ip}" -o -4 addr show 2>/dev/null | awk -v a="$SELF" '{ split($4, x, "/"); if (x[1] == a) { print $2; exit } }')
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
