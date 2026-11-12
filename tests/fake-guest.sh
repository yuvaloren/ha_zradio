# shellcheck shell=bash
# tests/fake-guest.sh — a fake radio VM for guest/install.sh: every path it writes is under <dir>/root
# (ZRADIO_INSTALL_ROOT); systemctl, apt-get, dpkg-query, keepalived, podman, id and ip are fakes in <dir>/bin
# (recorded in <dir>/calls); zradio-detect is a fake that writes the radios.conf / radios.json a detection would.
# Used by t-install.sh (the installer alone) and t-e2e.sh (the installer run from the node, through the guest agent).
vm() { # vm <dir> [radios: both|zwave-only|served|blank] [ser2net active: 0|1]
  local d=$1 radios=${2:-both} s=${3:-0}
  rm -rf "$d"; mkdir -p "$d/bin" "$d/root/etc/ssh"; : > "$d/calls"; : > "$d/pkgs"; echo "$s" > "$d/ser2net"; echo 0 > "$d/keepalived"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKeyFakeHostKey12 root@x" > "$d/root/etc/ssh/ssh_host_ed25519_key.pub"
  echo "# the package's file" > "$d/root/etc/ser2net.yaml"
  printf '%s\n' "# the pair" NAME=radio2 SELF=10.20.30.6 PEER=10.20.30.5 VIP=10.20.30.50/24 VRID=50 PRIORITY=100 > "$d/my.conf"
  local rec; rec="echo \"\$(basename \$0) \$*\" >> '$d/calls'"
  fake "$d/bin" id 'case "${1:-}" in -u) echo 0;; *) command -p id "$@";; esac'
  fake "$d/bin" ip 'printf "2: eth0    inet 192.168.1.44/24 scope global eth0\n3: eth1    inet 10.20.30.6/24 scope global eth1\n"'
  fake "$d/bin" systemctl "$rec; case \"\$1\" in is-active) u=\${*: -1}; [ \"\$(cat '$d/'\$u 2>/dev/null)\" = 1 ];; disable) case \" \$* \" in *' --now '*) echo 0 > '$d/'\${*: -1};; esac;; *) exit 0;; esac"
  fake "$d/bin" dpkg-query "grep -qx \"\${*: -1}\" '$d/pkgs' && { case \"\$*\" in *Status*) printf 'install ok installed';; *) printf '1.2.3-1';; esac; exit 0; }; exit 1"
  fake "$d/bin" apt-get "$rec; [ -f '$d/apt-fail' ] && exit 100; echo \"\${*: -1}\" >> '$d/pkgs'; case \"\${*: -1}\" in keepalived|ser2net) echo 1 > '$d/'\${*: -1};; esac; exit 0"
  fake "$d/bin" keepalived "$rec; [ -f '$d/kt-fail' ] && { echo 'Unknown keyword'; exit 1; }; exit 0"
  fake "$d/bin" podman "$rec; case \"\$1 \$2\" in 'image exists') [ -f '$d/have-image' ];; 'pull -q') : > '$d/have-image';; esac"
  cat > "$d/detect" <<SH
#!/usr/bin/env bash
echo "zradio-detect \$*" >> "$d/calls"
[ -f "$d/detect-fail" ] && { echo "FAIL  no Z-Wave or Zigbee stick found on this VM"; exit 1; }
mkdir -p "\$ZRADIO_DETECT_ETC"
case "$radios" in
  both|blank) printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=synced\nZIGBEE_FAMILY=znp\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
  zwave-only) printf 'ZWAVE=synced\nZWAVE_FAMILY=zwave-800\nZIGBEE=none\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
  served) printf 'ZWAVE=served\nZWAVE_FAMILY=zwave-500\nZIGBEE=served\nZIGBEE_FAMILY=ezsp\nZIGBEE_BAUD=115200\n' > "\$ZRADIO_DETECT_ETC/radios.conf";;
esac
net=true; [ "$radios" = blank ] && net=false
printf '{"radios": {"zwave": {"level": "%s", "holds_network": %s}, "zigbee": {"level": "%s", "holds_network": %s}}}\n' "\$(sed -n 's/^ZWAVE=//p' "\$ZRADIO_DETECT_ETC/radios.conf")" \$net "\$(sed -n 's/^ZIGBEE=//p' "\$ZRADIO_DETECT_ETC/radios.conf")" \$net > "\$ZRADIO_DETECT_ETC/radios.json"
echo "Z-Wave: found"; exit 0
SH
  chmod +x "$d/detect"
  printf '#!/usr/bin/env bash\necho "zigpy-setup $*" >> %q\nmkdir -p "$1/bin" && printf "#!/bin/sh\\n" > "$1/bin/zigpy" && chmod +x "$1/bin/zigpy"\n' "$d/calls" > "$d/zigpy-setup"; chmod +x "$d/zigpy-setup"
}
