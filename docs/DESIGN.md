# How ha_zradio works

Nothing here has run on real hardware yet. Numbers marked *measured* come from the pair of hand-written scripts this
kit was extracted from (two Proxmox VE 9 nodes; Aeotec Z-Stick 10 Pro; Sonoff ZBDongle-P; Z-Wave JS UI and ZHA).

## The pieces

| Piece | Standard part | The kit's part |
|---|---|---|
| A radio VM per node, with the node's sticks | Proxmox VM, USB mapping, Proxmox HA | `install.sh` |
| A stick served as a TCP port | ser2net | the config |
| One floating address, held by one VM | keepalived | the health check, `zradio-notify` |
| A standby whose sticks are silent | — | `zradio-serve` |
| A standby whose sticks are a copy | zigpy, zwave-js | `zradio-sync`, `zradio-apply` |
| Knowing which stick is what | Home Assistant's USB lists | `zradio-detect` |

Home Assistant connects to `tcp://VIP:6639` (Z-Wave JS) and `socket://VIP:6638` (ZHA). It takes no part in deciding
who serves.

## Install (`install.sh`, on each Proxmox node)

1. Checks, all before any change: the name and id are free; no **running** VM uses the sticks (or, with fixed
   addresses, the address).
2. The node's sticks get USB mappings; Debian 13's generic cloud image is downloaded and checksummed.
3. The VM is created with a cloud-init file that holds root's keys, the guest agent and the kit's `guest/` folder.
4. It becomes a Proxmox HA resource with a **strict** node rule, then starts: Proxmox restarts it on this node and
   never moves it to the other node's sticks.
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
| `--name` | the VM's name (default `zradio1`, `zradio2`, …; the second VM of a pair after the first: `radio1` → `radio2`) |
| `--vip A.B.C.D` | the floating address: free, and outside what DHCP hands out |
| `--bridge` | the network the VMs are on (default `vmbr0`); each VM's own address comes from DHCP there |
| `--self A.B.C.D/NN`, `--peer`, `--gateway`, `--vip A.B.C.D/NN` | fixed addresses instead of DHCP: this VM, the other VM, the gateway |
| `--pair-bridge` | a separate link between the nodes for `--self`; `--bridge` is then DHCP |
| `--join NAME`, `--no-pair` | the first VM to pair with (found by its tag); or none |
| `--start`, `--run` | start the VM in the pair; do it (report only without) |
| `--vrid`, `--priority`, `--pair-mac` | keepalived's router id (50) and priority; a fixed MAC |
| `--usb-mapping ID` (repeatable) | use USB mappings you already have |
| `--vmid`, `--storage`, `--snippets`, `--memory`, `--cores`, `--disk` | the VM (2 GB, 2 cores, 8 GB) |
| `--hookscript VOLID` | a hookscript of yours, for example one that powers the sticks' USB ports |
| `--ssh-keys FILE` | root's keys in the VM (default: the node's `authorized_keys`) |
| `--conf KEY=VALUE` (repeatable) | a line for the VM's `zradio.conf` ([zradio.conf.example](../zradio.conf.example)) |
| `--no-ha` | no Proxmox HA (a node that is in no cluster) |
| `--no-usb`, `--allow-no-radios` | a VM without sticks, to try the installer beside a running setup |
| `--sticks` | list the node's sticks and stop |

Without Proxmox: `bash guest/install.sh --conf zradio.conf --initial-role … --run` on two Debian 13 machines, then
the `zradio-sync trust` line each prints, run on the other. A conf without `SELF` takes the machine's own address;
one without `PEER` is a VM with no peer yet (`guest/install.sh --peer A.B.C.D --run` adds it).

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
2. It stops ser2net, reads both sticks (*measured*: about 12 s), and starts ser2net again.
3. The set goes to the standby over ssh (one key, one forced command, the host key pinned). The standby checks it,
   marks itself not ready, writes it, reads it back, silences the sticks, and clears the mark (*measured*: 90–97 s).
4. The copy's Zigbee frame counter is the original's plus 1,000,000, so a standby that takes over never repeats one.

A VM never serves a set that was not written to the end. One lock covers every operation on the sticks.

## Who serves when it is not obvious (`ELECTION=observe`, the default: logged, not acted on)

Each VM keeps a version of the networks, a counter `(term, used)`. With `ELECTION=act` on both VMs:

1. The term goes up when Home Assistant connects to a VM that knows it holds the newest copy.
2. A VM that gives the radios up (a switch, a shutdown, a failed health check) drops its claim to the copy in use.
3. At boot a VM waits for the other one (`ELECTION_WAIT`, 60 s). The higher version serves; a tie goes to priority.
4. A VM that knows it is behind is held until a sync lands. If the other VM stays away for the wait, it serves.
5. A VM with a strictly newer copy takes the radios back from one that serves an older copy, once.

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

## Tests

`bash tests/run.sh` runs everything against fakes: bash, python3 with PyYAML, openssh-client. `t-host.sh` covers
`install.sh` on a fake Proxmox cluster; `t-e2e.sh` installs a whole pair, with the kit's real installer running in
fake VMs and real keys exchanged. Where ser2net, keepalived and cloud-init are installed, the files the kit writes
are also given to the real programs.
