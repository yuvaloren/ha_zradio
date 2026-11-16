# shellcheck shell=bash
# tests/fake-pair.sh — a whole pair's worth of fakes, on top of tests/fake-node.sh (live) and tests/fake-guest.sh: the
# two-node cluster in $C, the fake radio VMs a qm create will find there, and ssh between them. Sourced after those
# two, with C set. Used by t-e2e.sh (the whole install, checked) and try.sh (the same cluster, by hand).
guest() { # guest <vmid> <radios> <its address>: the fake radio VM a qm create will find
  vm "$C/g/$1" "$2"; : > "$C/g/$1/root/etc/ssh/ssh_host_ed25519_key.pub"; rm -f "$C/g/$1/root/etc/ssh/ssh_host_ed25519_key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "root@vm$1" -f "$C/g/$1/root/etc/ssh/ssh_host_ed25519_key"
  fake "$C/g/$1/bin" ip "printf '2: eth0    inet %s/24 scope global eth0\n' '$3'"
}
cluster() { # a fresh two-node cluster; the VMs will get the ids 100 (nodea) and 101 (nodeb)
  node "$C" "${1:-both}"; : > "$C/live"
  cat > "$C/genv.sh" <<SH
G="$C/g/\$1"; R="\$G/root"
export ZRADIO_INSTALL_ROOT="\$R" ZRADIO_INSTALL_DETECT="\$G/detect" ZRADIO_INSTALL_ZIGPY_SETUP="\$G/zigpy-setup"
export ZRADIO_LIB="\$R/usr/local/lib/zradio" ZRADIO_CONF="\$R/etc/zradio/zradio.conf" ZRADIO_RADIOS="\$R/etc/zradio/radios.conf"
export ZRADIO_SYNC_KEY="\$R/etc/zradio/sync.key" ZRADIO_SYNC_KNOWN="\$R/etc/zradio/sync.known_hosts" ZRADIO_SYNC_AUTH="\$R/root/.ssh/authorized_keys"
export ZRADIO_SYNC_HOSTKEY="\$R/etc/ssh/ssh_host_ed25519_key.pub" ZRADIO_SYNC_STATE="\$R/var/lib/zradio" ZRADIO_SYNC_RUN="\$G/run" ZRADIO_SYNC_SSH="$C/gbin/ssh" ZRADIO_SYNC_LOGGER=true
SH
  # ssh between the VMs: -i <key> … -o UserKnownHostsFile=<file> … -b <self> root@<peer> <command>. It connects only
  # if the caller pinned exactly the peer's host key and the peer allows exactly the caller's sync key, from its address.
  cat > "$C/gbin/ssh" <<SH
#!/usr/bin/env bash
key="" known="" self="" dest="" cmd=""
while [ \$# -gt 0 ]; do case "\$1" in -i) key=\$2; shift 2;; -b) self=\$2; shift 2;; -o) case "\$2" in UserKnownHostsFile=*) known=\${2#*=};; esac; shift 2;; root@*) dest=\${1#root@}; cmd=\$2; break;; *) shift;; esac; done
for g in "$C"/g/*; do [ "\$(sed -n 's/^SELF=//p' "\$g/root/etc/zradio/zradio.conf" 2>/dev/null)" = "\$dest" ] && peer=\$g; done
[ -n "\${peer:-}" ] || { echo "ssh: connect to host \$dest: No route to host" >&2; exit 255; }
grep -qxF "\$dest \$(cut -d' ' -f1,2 < "\$peer/root/etc/ssh/ssh_host_ed25519_key.pub")" "\$known" 2>/dev/null || { echo "Host key verification failed." >&2; exit 255; }
grep -F "\$(cut -d' ' -f1,2 < "\$key.pub")" "\$peer/root/root/.ssh/authorized_keys" 2>/dev/null | grep -q "from=\"\$self\",restrict" || { echo "Permission denied (publickey)." >&2; exit 255; }
. "$C/genv.sh" "\$(basename "\$peer")"; PATH="\$peer/bin:\$PATH" SSH_ORIGINAL_COMMAND="\$cmd" bash "\$peer/root/usr/local/sbin/zradio-sync" serve-ssh
SH
  chmod +x "$C/gbin/ssh"
}
