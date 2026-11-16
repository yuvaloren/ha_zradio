# How ha_zradio works

Nothing here has run on real hardware yet. Numbers marked *measured* come from the pair of hand-written scripts this
kit was extracted from (two Proxmox VE 9 nodes; Aeotec Z-Stick 10 Pro; Sonoff ZBDongle-P; Z-Wave JS UI and ZHA).

## The pieces

| Piece | Standard part | The kit's part |
|---|---|---|
| A radio VM per node, with the node's sticks | Proxmox VM, USB mapping, a virtual watchdog | `install.sh` |
| A stick served as a TCP port | ser2net | the config |
| One floating address, held by one VM | keepalived | the health check, `zradio-notify` |
| A standby whose sticks are silent | — | `zradio-serve` |
| A standby whose sticks are a copy | zigpy, zwave-js | `zradio-sync`, `zradio-apply` |
| Knowing which stick is what | Home Assistant's USB lists | `zradio-detect` |

Home Assistant connects to `tcp://VIP:6639` (Z-Wave JS) and `socket://VIP:6638` (ZHA). It takes no part in deciding
who serves.

## Install (`install.sh`, on each Proxmox node)

`install.sh` is the entry point: options, checks, the table of known sticks. A new VM is `host/new-vm.sh`; on a node
whose radio VM exists it is an update, `host/update.sh`. What they share is `host/lib.sh`.

1. Checks, all before any change: the name and id are free; no **running** VM uses the sticks (or, with fixed
   addresses, the address).
2. The node's sticks get USB mappings; Debian 13's generic cloud image is downloaded and checksummed. A snippets
   storage that has a folder but not "snippets" in its content gets it added.
3. The VM is created with a cloud-init file that holds root's keys, the guest agent and the kit's `guest/` folder.
4. It starts, and starts again at every boot of the node. A virtual watchdog resets it when it hangs, and its
   kernel reboots it after a panic. No Proxmox HA: see "Two nodes or three" below.
5. Through the guest agent, the kit's own installer runs in the VM (`guest/install.sh`): packages, detection of the
   sticks, config files, units. Nothing is started.
6. On the second node: the first VM is told this VM's address, each VM gets the other's sync key and host key
   (`zradio-sync trust`), and the link is tried.
7. The VM is started in the pair if you say so.

The second node finds the first VM by its `zradio` tag and reads its addresses through the guest agent
(`pvesh … /agent/exec` reaches a VM on another node of the cluster).

**Addresses.** The floating address is the only one asked for. Each VM boots on DHCP, and its in-VM installer writes
the address it got into its `zradio.conf` (`SELF`). From then on that address is fixed as far as the pair goes:
keepalived's adverts and the sync's ssh trust both name it. So it has to be reserved in the DHCP server; each run
ends with the address and the MAC to reserve.

- *A VM whose address changes does not serve.* keepalived would still claim the floating address on the new one
  while the other VM can no longer hear it [V keepalived 2.3.3, in network namespaces], so `zradio-serve check` fails
  while no interface holds `SELF`. `zradio-serve status` and one journal line every 15 minutes say so.
- *The first VM has no peer until the second exists.* Its `zradio.conf` has no `PEER` and its keepalived.conf no
  unicast lines: it holds the floating address alone and sends VRRP's ordinary multicast adverts. The second node's
  run writes `PEER` into it (`guest/install.sh --peer`) and reloads its keepalived. On a VM that serves, the reload
  takes the floating address away for about 4 seconds [V keepalived 2.3.3], and the sticks with it.
- *Fixed addresses* (`--self`, `--peer`, `--gateway`, or `--pair-bridge`): nothing comes from DHCP, the first VM
  names its peer from the start, and none of the above applies.

**Primary or standby, initially.** The primary's sticks are left alone. The standby is marked "not filled" and does
not serve until the primary's first sync, whatever its sticks hold. A primary whose sticks hold no network is
refused unless `--first` (a new house). The answer is used once: after the first sync the two VMs swap freely.

### Options

Every question has an option; `--answers FILE` takes them as `KEY=value` lines.

| Option | |
|---|---|
| `--initial-role primary\|standby`, `--first` | above |
| `--name` | the VM's name (default `zradio1`, `zradio2`, …; the second VM of a pair after the first: `attic1` → `attic2`) |
| `--vip A.B.C.D` | the floating address: free, and outside what DHCP hands out |
| `--bridge` | the network the VMs are on (default `vmbr0`); each VM's own address comes from DHCP there |
| `--self A.B.C.D/NN`, `--peer`, `--gateway`, `--vip A.B.C.D/NN` | fixed addresses instead of DHCP: this VM, the other VM, the gateway |
| `--pair-bridge` | a separate link between the nodes for `--self`; `--bridge` is then DHCP. The floating address goes on the pair link too, so Home Assistant has to reach that link |
| `--join NAME`, `--no-pair` | the first VM to pair with (found by its tag); or none |
| `--start`, `--run` | start the VM in the pair; do it (report only without) |
| `--vrid`, `--priority`, `--pair-mac` | keepalived's router id (50) and priority; a fixed MAC |
| `--usb-mapping ID` (repeatable) | use USB mappings you already have |
| `--vmid`, `--storage`, `--snippets`, `--memory`, `--cores`, `--disk` | the VM (2 GB, 2 cores, 8 GB) |
| `--hookscript VOLID` | a hookscript of yours, for example one that powers the sticks' USB ports |
| `--ssh-keys FILE` | root's keys in the VM (default: the node's `authorized_keys`) |
| `--conf KEY=VALUE` (repeatable) | a line for the VM's `zradio.conf` ([zradio.conf.example](../zradio.conf.example)) |
| `--update NAME` | which radio VM of this node to update, where there are several |
| `--no-usb`, `--allow-no-radios` | a VM without sticks, to try the installer beside a running setup |
| `--sticks` | list the node's sticks and stop |

Without Proxmox: `bash guest/install.sh --conf zradio.conf --initial-role … --run` on two Debian 13 machines, then
the `zradio-sync trust` line each prints, run on the other. A conf without `SELF` takes the machine's own address;
one without `PEER` is a VM with no peer yet (`guest/install.sh --peer A.B.C.D --run` adds it). A newer kit is put in place
the same way: `bash guest/install.sh --run` from it, on each machine.

### Two nodes or three

The kit does not use Proxmox HA. The pair decides by itself which VM serves, so HA would only restart a crashed VM on
its own node. The price is too high: a node that runs an HA resource and loses the cluster's quorum reboots itself
after 60 s (Proxmox's HA manual). In a cluster of two nodes, the death of one takes the other's quorum, so HA would
reboot the very node whose VM is taking over. Instead, a radio VM has a virtual watchdog (`qm … --watchdog
model=i6300esb,action=reset`) that systemd in the VM feeds, and the kernel reboots after a panic. Not covered: the
VM's QEMU process itself dying. Then the other VM serves until someone starts this one (`qm start`).

What a third vote (three nodes, or two and a QDevice) still adds, and why the installer recommends one (it does not
require it): a node without quorum starts no VM. A start checks quorum first (`check_cfs_quorum` in qemu-server's
`vm_start`), and at boot Proxmox waits for quorum with no time limit (`startall` in pve-manager). With two nodes and no
third vote, while one node is down the other starts no radio VM, at boot or by hand, until someone runs `pvecm expected
1` on it; VMs already running are not affected. The installer says so on such a cluster.

### The third vote (`./install.sh --third-vote`, `vote/install.sh`)

The vote is Proxmox's own QDevice (its cluster manual, "Corosync External Vote Support"): `corosync-qnetd` on a
third machine, `corosync-qdevice` on the nodes, and `pvecm qdevice setup <address>` on one node, which makes the
certificates and writes the cluster's configuration. The kit writes none of that itself. It does what that command
needs done first, on both ends, and reads the votes back afterward.

`pvecm qdevice setup` logs into the third machine as root over SSH (`ssh-copy-id`, then `ssh` and `scp`) and runs
`corosync-qnetd-certutil` there. A NAS has no `apt-get` for that tool and no root login to give away. So
`vote/install.sh`, on the third machine, works two ways:

- **With docker** (a NAS, or `--docker`): a container, `zradio-vote`, built on the machine from Debian 13 with
  `corosync-qnetd` and `openssh-server`. It runs on the machine's own network (`--network host`, no port mapping in
  between, so qnetd sees the nodes' own addresses): the vote on TCP 5403, and an SSH server of its own on `--ssh-port`
  (default 2222). The arbiter's certificates and the SSH host key are in the docker volume `zradio-vote`; running the
  script again replaces the container and keeps them. Nothing of the machine itself is changed.
- **With `apt-get`** and no docker asked for (Debian, Ubuntu, Raspberry Pi OS): Debian's `corosync-qnetd` package. It
  changes no SSH setting.

**How the node gets in.** The third machine goes first and needs nothing from a node. The container's root gets a
one-time password that the script makes up and shows: twelve letters and digits. The node's first act is
`ssh-copy-id` with it; from then on it uses its key, as `pvecm` does. The password is good from the container's
start until a key has been left, 30 minutes at most. It is marked as used in the volume before the door opens, so a
restart of the container (the machine rebooting) never opens it again; only running the script again does, with a
new password. The password and the key open the container, not the machine. On the `apt-get` path there is no
password to make up: the node asks for root's own password of that machine, as in Proxmox's manual, and the script
refuses where the SSH server does not take one for root (Debian's default) and names the two ways out, `--docker`
or `--key`. `--key '<a node's /root/.ssh/id_rsa.pub>'`, on either path, lets that key in and uses no password at all;
it is the way for a run without a terminal.

It is one file with the container's two scripts inside it (`--show image|entrypoint`): what makes the image, and
what the container runs. The image is made with `docker run`, `docker cp` and `docker commit`, not `docker build`: a
NAS's docker has no buildx, and `docker build` without it is the legacy builder that docker is retiring. The image
carries a label of what it was made from, so a second run makes it again only after the kit changed. `./install.sh` on a
machine that is not a Proxmox node (no `qm`, no `pvesh`) says so and hands over to it, so the one install line
(`get.sh`) is the same on all three machines. It shows what it would do and asks before doing it.

On the node, `./install.sh --third-vote <address>` (`host/qdevice.sh`) builds no VM. It ends early when the cluster
has a third vote already or an odd number of nodes (`pvecm` sets one up for an even number only). While the third
machine does not answer on TCP 5403 or on its SSH port, it prints the line to run there. Once it answers:

1. `corosync-qdevice` is installed on every node that lacks it; on the other node over the SSH the cluster's nodes
   have between them, with the options Proxmox itself uses to go there.
2. For an SSH port other than 22 (`--third-vote-port`), root's `~/.ssh/config` gets an entry for the address.
   `pvecm` has no option for a port; that file is the one place its `ssh`, `scp` and `ssh-copy-id` all read one from.
3. Unless this node's key is there already: `ssh-copy-id`, which asks for the password. The machine's SSH host key
   is recorded then, trusted on this first use. A login by key must then find `corosync-qnetd` there.
4. `pvecm qdevice setup <address>`, its lines shown. Its own `ssh-copy-id` finds the key in place and asks nothing.
5. The votes are read back until the cluster keeps its quorum without one node, or it says that it does not.

Refused before step 4, because `pvecm` would stop halfway and leave certificates behind: a node offline, no SSH to
the other node, certificates of an earlier vote still on the node, an entry for the address in the SSH config with
another port, a wrong password.

To remove the vote: `pvecm qdevice remove` on a node; on the third machine `docker rm -f zradio-vote`, `docker volume
rm zradio-vote`, `docker rmi zradio-vote`, or `apt-get purge corosync-qnetd` and the key's line out of root's
`authorized_keys`.

## Updating (`host/update.sh`)

`./install.sh` (or the one line of `get.sh`) on a node whose radio VM exists updates that VM and the pair's other one.
Each VM's kit has a stamp, `/usr/local/lib/zradio/kit-version`: `VERSION` for people, and `CONTENT`, a hash of every
file the VM installs from the kit (`guest/lib/zradio-kit-stamp.sh`). A VM whose `CONTENT` is this kit's is up to date
and left alone. Otherwise the kit is sent into it through the guest agent, in pieces (Proxmox takes at most 64 KiB per
call), checked, and unpacked into `/opt/zradio/kit`, with the one before kept as `/opt/zradio/kit.previous`. Then the
kit's installer runs there again (`guest/install.sh --from-node --run`). It replaces only the files that differ,
keeps the VM's conf, role and keys, and does not stop the radios. The VM that does not serve goes first: if its
update fails, the one that serves is not touched. The stamp is installed last, so a failed run never claims the new
kit.

**Versions.** No version number is kept in a file. A release is a git tag (`v0.1.0`); `get.sh` takes the latest
release (`main` while there is none) and writes the version into the kit's `gen/version`: the tag, or
`<branch>@<commit>` for anything else. In a clone, the version is `git describe` (`v0.1.0-3-g08df12f`, `-dirty` with
uncommitted changes).

## Serving and standing by

Both VMs run keepalived as `BACKUP` with `nopreempt`: whoever holds the address keeps it until it stops, dies or
fails its health check (every 3 s: a stick gone, a half-written copy, a hung stick).

- **Serving:** the Z-Wave receiver on, then ser2net.
- **Standing by:** ser2net stopped, the Z-Wave receiver off, the Zigbee coordinator reset. A standby must be silent:
  a powered copy of a Z-Wave controller acknowledges frames and slows the mesh (*measured*: 2 of 121 commands took
  14–16 s), and a second Zigbee coordinator on the air is worse. It is silenced again at boot and every 15 minutes.

## The sync

Nightly, 15 minutes after the serving VM changed, and five quiet minutes after a device was added or removed.

1. The serving VM asks the standby whether it is there. No answer: nothing is read, no pause.
2. It stops ser2net, reads both sticks (*measured*: about 12 s), and starts ser2net again, unless the VM lost the
   role during the read: then the sticks are left silent.
3. The set goes to the standby over ssh (one key, one forced command, the host key pinned). The standby checks it,
   marks itself not ready, writes it, reads it back, silences the sticks, and clears the mark (*measured*: 90–97 s).
4. The copy's Zigbee frame counter is the original's plus 1,000,000, so a standby that takes over never repeats one.

A VM never serves a set that was not written to the end. One lock orders every change to the sticks: zradio-serve's
up, down and hush and the sync's read hold it; a standby's write takes it to mark itself (applying, standby-dirty) on
a VM that does not serve, and up and hush look at those marks under it.

## Who serves when it is not obvious (`ELECTION=observe`, the default: logged, not acted on)

Each VM keeps a version of the networks, a counter `(term, used)`. With `ELECTION=act` on both VMs:

1. The term goes up when Home Assistant connects to a VM that knows it holds the newest copy.
2. A VM that gives the radios up (a switch, a shutdown, a failed health check) drops its claim to the copy in use.
3. At boot a VM waits for the other one (`ELECTION_WAIT`, 60 s). The higher version serves; a tie goes to priority.
4. A VM that knows it is behind is held until a sync lands. If the other VM stays away for the wait, it serves.
5. A VM with a strictly newer copy takes the radios back from one that serves an older copy, once.

Observe mode keeps its files apart (`/run/zradio/observe`, `/var/lib/zradio/observe`); a change of mode removes the
other mode's files.

Rehearsed with the real keepalived in two network namespaces (`sudo bash tests/rehearse-election.sh`); not on a
radio VM. During a cut link both VMs still serve; this only decides which copy survives the heal.

## Recognizing the sticks

A list first, then a read-only question to the stick. The list (`gen/usb-ids.json`) is built at every install from
Home Assistant's own USB lists, at the commit `guest/lib/usb-annotations.json` pins, merged with the kit's notes in that
file (`guest/lib/zradio-usb-ids.py`). Nothing generated is kept in git: it all goes into the kit's `gen/` folder.
Z-Wave 800 series and TI Z-Stack sticks are **synced**; every other stick is **served** only. One stick per kind per
VM. Serial settings of served-only sticks come from public documentation and are not verified.

## Not built

- Proposing free addresses; powering a stopped VM's USB ports off.
- A Home Assistant integration (status, "sync now", "switch"); a sync without the pause.
- More families synced (Silicon Labs EZSP first); Zigbee2MQTT.
- The hung-stick check only observes.
- A restart of a VM whose QEMU process died (no Proxmox HA, above): the other VM serves until it is started.

## Tests

`bash tests/run.sh` runs everything against fakes: bash, python3 with PyYAML, openssh-client. `t-vote.sh` covers the
third vote's two ends the same way. `bash tests/vote-real.sh` is apart, because it needs docker and the network: it
builds and starts the vote's container, then a Debian 13 container in the place of a node leaves its key there with
the one-time password, runs the commands `pvecm qdevice setup` runs toward it, and a real corosync node with
`corosync-qdevice` gets its second vote from it. `pvecm` itself has not been run against it. The tests are for
development: a release's archive, which is what `get.sh` puts on a machine, carries no `tests/` (`.gitattributes`). `t-host.sh` covers
`install.sh` on a fake Proxmox cluster; `t-e2e.sh` installs a whole pair, with the kit's real installer running in
fake VMs and real keys exchanged. Where ser2net, keepalived and cloud-init are installed, the files the kit writes
are also given to the real programs.
