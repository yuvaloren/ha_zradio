#!/usr/bin/env bash
# tests/try.sh — ./install.sh by hand, with nothing real behind it: a shell on the tests' fake two-node Proxmox
# cluster (tests/fake-pair.sh), in the tests' container (tests/Dockerfile). Needs: docker, a terminal.
#   tests/try.sh           # each node has a Z-Wave and a Zigbee stick, and they hold networks
#   tests/try.sh zwave     # a Z-Wave stick only
#   tests/try.sh blank     # both sticks, new: no network on them (a new house)
# Real: install.sh and every question and line it prints, the cloud-init file it writes, the kit's installer in each
# VM, the two VMs' keys. Fake: Proxmox (qm, pvesh, ha-manager), the image download, apt, systemd, the sticks.
# So this shows what the install looks and reads like. It proves nothing about Proxmox, a VM or a stick.
# Nothing outside the container is touched, and nothing is kept: leave the shell and start again for a new cluster.
set -uo pipefail
if [ "${1:-}" != --inside ]; then
  case "${1:-both}" in both|zwave|blank) ;; *) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 2;; esac
  [ -t 0 ] && [ -t 1 ] || { echo "try.sh: needs a terminal (the installer's questions are what it is for)" >&2; exit 2; }
  cd "$(dirname "$0")/.." || exit 2
  docker build -q -t zradio-tests - < tests/Dockerfile > /dev/null || exit 2
  exec docker run --rm -it -v "$PWD":/src:ro --entrypoint bash zradio-tests -c 'cp -R /src/. . && exec bash tests/try.sh --inside "$@"' -- "$@"
fi
KIND=${2:-both}
. "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034  # TOOL is what fake-node.sh runs
TOOL="$KIT/install.sh"
. "$TESTS_DIR/fake-node.sh"
. "$TESTS_DIR/fake-guest.sh"
C="$T/c"
. "$TESTS_DIR/fake-pair.sh"

case "$KIND" in zwave) cluster zwave; usb "$C/sys-nodeb" 2-2 0000 0000 "unplugged"; radios=zwave-only;; *) cluster both; radios=$KIND;; esac
# The VMs the installer will make: the cluster's next free ids. The pretend DHCP server gives the first one
# 192.168.1.31, the next 192.168.1.32, …; a VM given a fixed address (--self) has that one instead.
for id in 100 101 102 103; do
  guest "$id" "$radios" 0.0.0.0
  fake "$C/g/$id/bin" ip "R='$C/g/$id/root'; c=\$R/etc/zradio/zradio.conf; [ -f \"\$c\" ] || c=\$R/root/zradio.conf; s=\$(sed -n 's/^SELF=//p' \"\$c\" 2>/dev/null | tail -1); printf '2: eth0    inet %s/24 scope global eth0\n' \"\${s:-192.168.1.$((id - 69))}\""
done

cat > "$T/rc" <<RC
export PATH="$C/bin:\$PATH" ZRADIO_VM_NET="$C/net" ZRADIO_VM_PVE="$C/pve" ZRADIO_VM_CACHE="$C/cache" ZRADIO_VM_WAIT=0 ZRADIO_VM_POLL=0 ZRADIO_VM_KEYS="$C/keys"
on() { export FAKE_NODE=\$1; if [ "\$1" = nodea ]; then export ZRADIO_VM_SYS="$C/sys"; else export ZRADIO_VM_SYS="$C/sys-\$1"; fi; PS1="root@\$1:~/ha_zradio# "; }
nodea() { on nodea; }
nodeb() { on nodeb; }
vms() { python3 -c 'import json, sys; [print("%(vmid)s  %(name)-12s %(node)s  %(status)-8s tags=%(tags)s" % v) for v in json.load(open(sys.argv[1]))] or print("(no VM yet)")' "$C/vms.json"; }
calls() { grep -v '^guest: ' "$C/calls"; }
vmfiles() { (cd "$C/g" && find . -path './*/root/etc/zradio/*' -o -path './*/root/var/lib/zradio/*' -o -path './*/root/usr/local/sbin/*' | sort); echo "(under $C/g/<vmid>/root)"; }
cd "$KIT" && on nodea
cat <<'TXT'

  A pretend Proxmox cluster: nodea and nodeb. You are root on nodea, in the kit's folder.
      ./install.sh           the installer, as on a real node (./install.sh --help, --sticks)
      nodeb    nodea         go to the other node
      vms                    the cluster's VMs
      calls                  every qm, pvesh and ha-manager command the installer ran
      vmfiles                what the kit's installer put into each VM
      exit                   leave; the cluster is thrown away
  The pretend network is 192.168.1.0/24 and its DHCP server gives the VMs 192.168.1.31, .32, …
  The floating address is yours to make up: any other address of that network, like 192.168.1.20.

TXT
RC
bash --rcfile "$T/rc" -i
