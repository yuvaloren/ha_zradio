# How ha_zradio works

[README.md](../README.md) says how to install and use the kit. This document says how it works and why, part by
part. Numbers marked *measured* come from the pair of hand-written scripts the kit was extracted from (two Proxmox
VE 9 nodes; Aeotec Z-Stick 10 Pro; Sonoff ZBDongle-P; Z-Wave JS UI and ZHA). "What has run where" is at the end.

## The pieces

| Piece | Standard part | The kit's part |
|---|---|---|
| A radio VM per node, with the node's sticks | Proxmox VM, USB passthrough, a hookscript, a virtual watchdog | `install.sh`, `host/` |
| A VM that starts only with its sticks there, and sticks that are dark while it is stopped | Proxmox hookscript; the kernel's switch for a hub port | `host/hook.sh` |
| Knowing which stick is what | Home Assistant's USB lists | `zradio-detect` |
| A stick served as a TCP port | ser2net | the config (`zradio-render`) |
| One floating address, held by one VM | keepalived | the health check, `zradio-notify` |
| A standby whose sticks are silent | — | `zradio-serve` |
| A standby whose sticks are a copy | zigpy, zwave-js | `zradio-sync`, `zradio-apply`, `zradio-change-watch` |
| Which copy is the newer one | — | `zradio-gate` |
| Handing the radios over on purpose | — | `zradio-switch` |
| A third vote for a cluster of two nodes | corosync-qnetd, `pvecm qdevice` | `vote/install.sh`, `host/qdevice.sh` |
| What to set in Home Assistant | — | `homeassistant/install.sh` |

Home Assistant connects to `tcp://VIP:6639` (Z-Wave JS) and `socket://VIP:6638` (ZHA), where VIP is the floating
address. It takes no part in deciding who serves.

## One install line, three kinds of machine

`get.sh` is the line to paste. It asks GitHub for the latest release, downloads that release's archive into
`/opt/ha_zradio/<version>`, and runs its `install.sh` with the options given after the line. `--main` right after
the line's `_` takes the latest `main` instead of the latest release, and `--ref <tag or branch>` any other version
(`ZRADIO_REF=<tag or branch>` before the line does the same). The two are `get.sh`'s own and come before
`install.sh`'s options. Where GitHub says there is no release yet, it takes `main`;
where GitHub does not answer the question, it stops, so that no machine gets unreleased code by accident. It needs
bash, curl and tar, and no python: Home Assistant's terminal has none.

The line always runs `main`'s `get.sh`, and the archive is checked by TLS only. Whoever can push to the repository
decides what the line runs as root.

`install.sh` then sees where it is:

| The machine | What runs |
|---|---|
| a Proxmox node (`qm` and `pvesh` are there) without a radio VM | a new radio VM: `host/new-vm.sh` |
| a Proxmox node with a radio VM | an update of the pair: `host/update.sh` |
| a Proxmox node, with `--third-vote ADDRESS` | the node's end of the third vote: `host/qdevice.sh` |
| Home Assistant (its terminal app, or its settings are there, or `--radios` / `--config` is given) | `homeassistant/install.sh` |
| any other machine | the third vote: `vote/install.sh` |

Every one of them shows what it would do and changes nothing without `--run` or a `y`.

## Recognizing the sticks

A list first, then a read-only question to the stick (`zradio-detect`).

The list (`gen/usb-ids.json`) is built at every install from Home Assistant's own USB lists, at the commit
`guest/lib/usb-annotations.json` pins, merged with the kit's notes in that file (`guest/lib/zradio-usb-ids.py`). A
match is a hint. The answer comes from the stick: a port hinted Z-Wave, or not hinted at all, is asked for its
controller id over the Z-Wave Serial API; a port hinted Zigbee is asked for its version over TI's ZNP. Nothing is
written and nothing goes on the air. Whether a stick holds a network is asked the same way: a Z-Wave controller for
its node list and, where it has one, its Long Range node list; a coordinator for whether it is on a network. An
answer that cannot be told is "unknown", never "empty". Nothing generated is kept in git: it all goes into the kit's
`gen/` folder.

Each kind of stick gets a level, written to `/etc/zradio/radios.conf`:

- **synced**: Z-Wave 800 series, and Zigbee on TI Z-Stack 3 (a CC2652). Served, kept silent on the standby, and
  copied.
- **served**: every other stick, a coordinator on Z-Stack Home 1.2 (CC2531, CC2530) among them. Served and failed
  over, but the kit has no proven way to silence or copy it. So the standby's stick of such a family must hold no
  network when it goes in (blanked with its maker's or Home Assistant's tools), and after a takeover the network is
  restored with Home Assistant's own tools. Serial settings of served-only sticks come from
  public documentation and are not verified; `ZWAVE_BAUD`, `ZIGBEE_BAUD` and the `_FLOW` keys in `radios.conf`
  overrule them.

One stick per kind per VM. After a stick is replaced: `guest/install.sh --detect --run` in the VM. `--use
zigbee=/dev/ttyUSB3` names the port where detection cannot choose; it does not overrule what a stick answered (a
port that answered as Z-Wave is not taken as Zigbee).

Detection fails rather than guess. A stick the list names as Z-Wave or as Z-Stack that does not answer that protocol
is not taken as it is, and no other stick is taken in its place: it says how to try again or name the stick. Each
chosen port gets a udev rule by what it is (ids, product name, port number); where a second port would match the
same rule, the serial is added, or for two sticks with the same serial, the USB port they are in. After udev has
made the names, each must lead to the port that was chosen, and only then is `radios.conf` written: a detection that
fails puts the earlier rules back and leaves the earlier `radios.conf` as it was. Detection holds the same lock as
every tool that talks to a stick.

## Serving and standing by

Both VMs run keepalived as `BACKUP` with `nopreempt`: whoever holds the floating address keeps it until it stops,
dies, or fails its health check. keepalived's notify script (`zradio-notify`) starts and stops
`zradio-serve.service`, and nothing else moves the role. The two VMs send their adverts to each other's address, and
an advert from any other address is not taken: VRRP version 3 has no authentication, and without that check any
machine of the network could claim the address [V keepalived 2.3.3: an advert of priority 250 from a third machine
displaced the pair without the check, and did not with it].

- **Serving** (`zradio-serve up`): the Z-Wave receiver on, then ser2net. Only on a VM whose interfaces hold the
  floating address (keepalived sets it before it runs the notify [V keepalived 2.3.3]).
- **Standing by** (`zradio-serve down`): ser2net stopped, the Z-Wave receiver off, the Zigbee coordinator reset. A
  standby must be silent: a powered copy of a Z-Wave controller acknowledges frames and slows the mesh (*measured*:
  2 of 121 commands took 14–16 s), and a second Zigbee coordinator on the air is worse. It is silenced again at
  boot, at every return to standby, and every 15 minutes: a stick that re-enumerates comes back listening.

The health check (`zradio-serve check`, every 3 s) fails, and the address goes to the other VM, when:

- `radios.conf` names no radio, or a stick's serial port is gone;
- no interface holds this VM's own address (below, "Addresses");
- a copy is being written to the sticks or was not written to the end;
- serving failed to start less than 5 minutes ago;
- this VM has held the floating address for 30 s, ser2net is not active, and nobody is at the sticks (below);
- the election's gate holds this VM (only with `ELECTION=act`);
- a stick was declared hung (only when that is armed, below).

**The role and the serving must agree.** keepalived gives the role and systemd starts the serving; if a start or a
stop never gets the sticks, or ser2net dies, the two drift apart and nothing else would notice. So the health check
takes a VM out for 5 minutes when it has held the address for 30 s without serving: the other VM takes over, and
this one is tried again afterward. The check counts those 30 s itself, from the first time it sees that: at a
takeover the address is there a moment before anything else knows. The other way round, a VM that serves without the address is stopped by `hush` (at every
return to standby, and from the 15-minute tick). "Holds the address" is what the VM's interfaces show. keepalived's
last word, which the notify script writes down, counts only where that cannot be seen: keepalived does not wait for
its notify scripts, and two that come within milliseconds can be written in either order. Every tool that works on
the sticks holds one lock, and both checks look at it: a start, a stop or a sync's read that is under way is left to
finish. A start that turned the receiver on and then failed turns it off again.

**A hung stick.** A stick can stop answering while its serial port is still there. `zradio-change-watch` sees it
from the packets: requests from Home Assistant with nothing coming back, 5 or more, the first of them 180 s ago. The
VM that serves then gives the radios up (its health check fails on the mark `stick-wedged`) and the other VM takes
them: **fail over first, then heal.** There is no setting for it. Two guards come from a real outage, in which an
earlier version of this check took the radios away from two healthy sticks in turn: a stick is judged only after the
watcher has seen it answer once, and a VM declares at most two hung sticks in a day. (`ZRADIO_CHANGE_WEDGE=observe`
in the unit's environment, a drop-in for `zradio-change-watch.service`, makes the check log `result=would-wedge`
and do nothing else: for a pair on which it misfires.)

**Healing** is `zradio-serve hush`, on a VM that does not serve: at every return to standby, every 15 minutes, and
the moment a stick's serial port appears (a udev rule starts it). A stick that does not answer there is tried rung
by rung, and each rung that works ends it (`event=serve result=healed stick=… by=…`):

1. a soft reset over the serial line (Z-Wave SoftReset; Z-Stack `SYS_RESET_REQ`);
2. the stick's USB device taken from its driver and given back, as if it were plugged in again without losing its
   power (at most 4 times a day per stick);
3. its power. A VM cannot switch that; the node can ("The start, the sticks' power, and a stick that stays away").
   The VM writes `want-power`, and the node's helper asks for it every 5 minutes.

A stick whose serial port is missing for 5 minutes is asked for the same way: that is a hub that did not come back.
When the sticks are there and answer, the request and `stick-wedged` are removed and the VM is a standby that may
serve again. A served-only stick is never asked a question, so none of this reaches it: its mark is removed by hand
after the stick was power-cycled.

The watcher counts a packet only once this VM's own kernel has acknowledged it on that connection. A packet that
somebody else on the network made up, with Home Assistant's address on it, starts no sync and counts toward no hung
stick. Where the VM's own packets do not pass the interface it watches, it says so once (`result=loud blind`).

## The sync

The serving VM's sticks are read and the standby's are written (`zradio-sync`). It runs:

- nightly, at `SYNC_AT`;
- from the 15-minute tick, when the standby does not hold the serving VM's last copy (after a takeover, a failed
  sync, a rebuilt standby). A standby that is up also asks for it once the other VM has served for a minute, where
  the two have a stick of the same family to sync;
- five quiet minutes after a device was added or removed. `zradio-change-watch` reads the packets Home Assistant
  sends to the sticks' ports and looks for the requests that change a network's membership. At most 6 such syncs
  start in a day. The request stays noted until a sync has read the sticks after the quiet time: one that failed, or
  found another sync running, does not lose it.

One sync runs at a time. A second one ends at once with exit code 75, which the units count as no failure.

The steps:

1. The serving VM asks the standby whether it is there. No answer: nothing is read, and there is no pause.
2. It stops ser2net, reads both sticks, and starts ser2net again, unless the VM lost the role during the read: then
   the sticks are left silent. This is the one pause Home Assistant sees (*measured*: the reads take 7 s and 12 s,
   side by side; Home Assistant had Z-Wave back after 14 s and Zigbee after 26–28 s).
3. The set goes to the standby over ssh. The standby checks it, marks itself not ready, writes it
   (`zradio-apply`), reads the identities back, silences the sticks, and clears the mark (*measured*: 90–97 s).
4. The copy's Zigbee frame counter is the original's plus 1,000,000, so a standby that takes over never repeats one.
   After the write it is read back from the coordinator: one below what was written fails the write.

Every step has a time limit, and a step that is cut off ends as a failure with the sticks silent: a read 90 s, the
standby's write 6 minutes, the wait for it 7. A set that was read is sent again without a second read only in the
same serving turn, for 20 hours at most, and never for a device change: that sync is about what changed since.

**Writing a stick.** Z-Wave: the NVM image is restored by Z-Wave JS UI in a podman container, in two passes (one
that converts the image for this stick, one raw that repairs the RF settings), each verified by serial reads. Both
passes run unless the VM's own record says this very set was written before: what a stick answers does not say
whose routes it holds. The container is stopped the moment the call answers, and removed however the write ends. It
runs with the one capability it needs to open the stick and can gain no other. The image is pulled at install, by
its release and by the digest the registry answers for it, and never at a write: a sync does not need the internet,
and does not take whatever a tag points to that day. The installer also starts it once with those rights, without a
stick: a machine whose podman does not start it so fails its install, or its update at the standby, and not its
first sync. Zigbee: zigpy restores the coordinator backup; zigpy-cli is
installed at a pinned release with a pinned set of libraries under it (`guest/lib/zigpy-constraints.txt`).

Nothing is written onto the sticks of a VM that serves or holds the role.

**What holds it together.** A VM never serves a set that was not written to the end. A write that fails is followed
by the same silencing as a good one: a coordinator that the write left on the air does not stay there. A sync that
is interrupted during its read turns the receiver on before ser2net starts again. One lock orders every change
to the sticks: `zradio-serve`'s up, down and hush and the sync's read hold it; a standby's write takes it to mark
itself on a VM that does not serve, and up and hush look at those marks under it. The mark of a write that did not
end names the network it was for, and only a good write of that network clears it. A failed sync is retried without
a second read; a failed read waits 15 minutes, doubling, 6 hours at most, because each read is a pause.

**Trust between the two VMs.** One ssh key per VM, made at install. In the other VM's `authorized_keys` it may run
one command (`zradio-sync serve-ssh`: hello, receive, poke, yield), from the peer's address only, with `restrict`.
Each VM's host key is pinned on the other. The set at rest is root-only, and no key, NVM byte or Zigbee network key
goes to stdout or the journal.

## Who serves when it is not obvious

Each VM keeps a version of the networks it holds, a counter `(term, used)`. In either mode:

1. The term goes up when Home Assistant connects to a VM that knows it holds the newest copy.
2. A VM that gives the radios up (a switch, a shutdown, a failed health check) drops its claim to the copy in use.

`ELECTION=observe`, the default, logs what the gate (`zradio-gate`) would do and acts on nothing. With
`ELECTION=act` on both VMs:

3. At boot a VM waits for the other one (`ELECTION_WAIT`, 60 s). The higher version serves; a tie goes to priority.
4. A VM that knows it is behind is held until a sync lands. If the other VM stays away for the wait, it serves.
5. A VM with a strictly newer copy takes the radios back from one that serves an older copy, asking at most once
   in 5 minutes. After a takeover that did not hold (the other VM serves again, because this one could not), it
   waits twice as long each time, 6 hours at most.

Observe mode keeps its files apart (`/run/zradio/observe`, `/var/lib/zradio/observe`); a change of mode removes the
other mode's files. During a cut link both VMs still serve; this only decides which copy survives the heal.
`zradio-gate status` shows the files and what they mean, and changes nothing. The version and the gate's files
change together under one lock, which the notify script takes as well.

## The planned switch

`zradio-switch --run`, in the VM that serves. It checks that the standby answers and is ready, syncs first when the
standby does not hold the last copy, and stops keepalived: the last advert has priority 0, so the standby takes the
address at once. When the standby says it serves, keepalived is started again here, as the standby (*measured*:
Z-Wave back after 1.3 s, Zigbee after 7 s). If the standby does not take the role in 20 s, this VM takes it back.
A switch that is interrupted (Ctrl-C, a dropped session) starts keepalived here again on its way out, and one that
finds another sync running refuses before it stops anything.

## In a radio VM

| Where | What |
|---|---|
| `/etc/zradio/zradio.conf` | the pair as this VM sees it: the one file to edit ([zradio.conf.example](../zradio.conf.example)) |
| `/etc/zradio/radios.conf`, `radios.json` | what `zradio-detect` found |
| `/etc/zradio/sync.key` | this VM's sync key (0600) |
| `/var/lib/zradio` | what must survive a reboot: the version, the sync records, the marks of a write in progress |
| `/run/zradio` | this boot's state: the turn, the gate's marks, the locks |
| `/opt/zradio/kit`, `kit.previous` | the kit the VM was installed from, and the one before |
| `/usr/local/sbin/zradio-*`, `/usr/local/lib/zradio` | the tools; `kit-version` there is the stamp an update compares |

`zradio.target` is "this VM takes part in the pair": it pulls in keepalived, the gate, the watcher and the timers
(nightly sync, 15-minute tick, the state line every minute). `systemctl start zradio.target` puts a VM into the
pair, and it is enabled, so a reboot does too.

A changed setting takes effect when the installer runs again in the VM: edit `/etc/zradio/zradio.conf`, then `bash
/opt/zradio/kit/guest/install.sh --run`. The two conf files hold the kit's own keys and nothing else: a line that is
not `KEY=value`, or a key the kit does not know (a typo), refuses the file, and every tool says which. The
installer asks systemd whether the sync's time is one (`systemd-analyze calendar`) and keepalived whether it takes
the new config, before either is put in place.

On a VM that is in the pair, the installer puts what runs onto the new files: the gate and the watcher are
restarted when a file they read changed, a timer when its times changed, and a unit that is new in the kit is
started. The nightly sync's timer is stopped while its file changes and started after systemd has read it again: a
timer that has run and is read again with a new time whose turn has passed since runs at that moment, and that
would be a sync, 12 s without radios, at the time of an update (`tests/timer-real.sh` shows both). A restart of the gate or the watcher would end a sync they started, so it waits while one runs (5 minutes
at most, then it says what to run later). keepalived and a serving ser2net are not restarted: the installer's notes
say what a changed file of theirs needs. A changed `ZIGPY_VERSION` builds zigpy's venv again, and puts the old one
back if that fails.

Every decision is one journal line, `zradio: event=… result=…` (`journalctl -t zradio`). `event=state`, once a
minute on both VMs, is the line for monitoring: who serves, which copy each holds, whether the standby is ready.

## Installing a radio VM (`install.sh` on a Proxmox node)

`install.sh` is the entry point: options, checks, the table of known sticks. What the two paths share is
`host/lib.sh`. A new VM, by the numbers the run prints:

0. Checks, all before any change: the name and id are free; no **running** VM uses the sticks (or, with fixed
   addresses, the address).
1. The node's sticks are found, and each gets a line in the VM's config that names it by what it is
   (`usb0: host=<vendor>:<product>`), or by its socket (`host=<bus>-<port>`) where two sticks have the same id.
2. Debian 13's generic cloud image is downloaded and checked against the `SHA512SUMS` beside it. Debian signs
   neither; HTTPS is what vouches for them. A cached image is checked against the checksum kept with it before it is
   used, and a run asks the list whether the image is still Debian's current one. Where that cannot be had, a whole
   cached image is used, and the run says so.
3. A cloud-init file is written: root's keys, the guest agent, the kit's `guest/` folder. A snippets storage that
   has a folder but not "snippets" in its content gets it added. The kit's hookscript goes into the same storage.
4. The VM is created: started at every boot of the node, with a virtual watchdog and the hookscript. Its tag is `zradio-building`
   until step 7 is done, and `zradio` from then on: a run that stops halfway leaves no VM that passes for a radio VM.
   Nothing updates it or pairs with it, the run ends with how to remove it, and the next run refuses to build beside
   it.
5. It starts, and the run waits for its guest agent and for cloud-init.
6. Through the guest agent, the kit's own installer runs in the VM (`guest/install.sh`): packages, detection of the
   sticks, config files, units. Nothing is started.
7. On the second node: the first VM is told this VM's address, each VM gets the other's sync key and host key
   (`zradio-sync trust`), and the link is tried.
8. The VM is started in the pair if you say so.

The second node finds the first VM by its `zradio` tag and reads its conf through the guest agent (`pvesh …
/agent/exec` reaches a VM on another node of the cluster). What a pair shares comes from there: the floating
address, the router id, the ports, the sync's time, the election's mode, the pinned versions. An option of the
second run that says otherwise is refused.

The install reaches: GitHub (the kit, Home Assistant's USB lists), cloud.debian.org (the image), Debian's mirrors
(packages), docker.io (the Z-Wave JS UI image) and PyPI (zigpy-cli).

**Addresses.** The floating address is the only one asked for. Each VM boots on DHCP, and its in-VM installer writes
the address it got into its `zradio.conf` (`SELF`). From then on that address is fixed as far as the pair goes:
keepalived's adverts and the sync's ssh trust both name it. So it has to be reserved in the DHCP server; a new VM's
run ends with the address and the MAC to reserve.

- *A VM whose address changes does not serve.* keepalived would still claim the floating address on the new one
  while the other VM can no longer hear it [V keepalived 2.3.3, in network namespaces], so the health check fails
  while no interface holds `SELF`. `zradio-serve status` and one journal line every 15 minutes say so.
- *The first VM has no peer until the second exists.* Its `zradio.conf` has no `PEER` and its keepalived.conf no
  unicast lines: it holds the floating address alone and sends VRRP's ordinary multicast adverts. The second node's
  run writes `PEER` into it (`guest/install.sh --peer`) and reloads its keepalived. On a VM that serves, the reload
  takes the floating address away for about 4 seconds [V keepalived 2.3.3], and the sticks with it.
- *Fixed addresses* (`--self`, `--peer`, `--gateway`): nothing comes from DHCP, the first VM names its peer from
  the start, and neither point above applies. With `--pair-bridge`, the pair's own link carries the fixed addresses
  and the floating one, and the VM's first interface (`--bridge`) is still on DHCP.

**Primary or standby, initially.** The primary's sticks are left alone. The standby is marked "not filled" and does
not serve until the primary's first sync, whatever its sticks hold. A primary whose sticks hold no network is
refused unless `--first` (a new house). The answer is used once: after the first sync the two VMs swap freely.

### Options

Every question has an option. `--answers FILE` takes them as `KEY=value` lines ([answers.example](../answers.example)):
`--initial-role` is `INITIAL_ROLE=`, an option without a value is `=yes`, `USB_MAPPING` once per mapping. `--run` is
not an answer: it belongs on the command line.

| Option | |
|---|---|
| `--initial-role primary\|standby`, `--first` | above. No default on a pair's first VM |
| `--name` | the VM's name (default `zradio1` … `zradio9`; the second VM of a pair after the first: `attic1` → `attic2`) |
| `--vip A.B.C.D` | the floating address: free, and outside what DHCP hands out. No default |
| `--bridge` | the network the VMs are on (default `vmbr0`); each VM's own address comes from DHCP there |
| `--self A.B.C.D/NN`, `--peer`, `--gateway`, `--vip A.B.C.D/NN` | fixed addresses instead of DHCP: this VM, the other VM, the gateway |
| `--pair-bridge` | a separate link between the nodes for `--self`. The floating address goes on it too, so Home Assistant has to reach that link |
| `--join NAME`, `--no-pair` | the first VM to pair with (found by its tag); or none |
| `--start`, `--run` | start the VM in the pair; do it (report only without) |
| `--vrid`, `--priority`, `--pair-mac` | keepalived's router id (50) and priority (110 for the primary, 100 for the standby); a fixed MAC |
| `--usb-mapping ID` (repeatable) | use USB mappings you already have (five devices at most). Proxmox refuses a start of the VM while a mapped stick is absent |
| `--vmid`, `--storage`, `--snippets` | the VM's id (the next free one), its disk's storage (the first of `local-zfs`, `local-lvm`, `local`), the snippets storage (`local`) |
| `--memory`, `--cores`, `--disk` | 2048 (MB), 2, `8G` |
| `--stick-power HUB:PORT` (repeatable), `--no-stick-power` | the hub ports that switch this node's sticks' power ("The start, the sticks' power, and a stick that stays away"); none |
| `--ssh-keys FILE` | root's keys in the VM (default: the node's `authorized_keys`) |
| `--conf KEY=VALUE` (repeatable) | a line for a new VM's `zradio.conf`: one of that file's keys that has no option of its own ([zradio.conf.example](../zradio.conf.example)). An update keeps the VM's own file |
| `--image-dir URL` | where the Debian image and its `SHA512SUMS` are (default: cloud.debian.org): `https://…`, `file:///folder` on the node, or `http://…` with a note |
| `--update NAME` | which radio VM of this node to update, where there are several |
| `--no-usb`, `--allow-no-radios` | a VM without sticks, to try the installer beside a running setup |
| `--sticks` | list the node's sticks and stop |
| `--third-vote A.B.C.D`, `--third-vote-port N`, `--third-vote-hostkey KEY` | not a VM: the third vote (below). The line the third machine prints has all three |

**Without Proxmox:** `bash guest/install.sh --conf zradio.conf --initial-role … --run` on two Debian 13 machines,
then the `zradio-sync trust` line each prints, run on the other, then `systemctl start zradio.target` on both. A
conf without `SELF` takes the machine's own address; one without `PEER` is a VM with no peer yet (`guest/install.sh
--peer A.B.C.D --run` adds it). A newer kit is put in place the same way: `bash guest/install.sh --run` from it, on
each machine.

## Two nodes or three

**No Proxmox HA.** The pair decides by itself which VM serves, so HA would only restart a crashed VM on its own
node. The price is too high: a node that runs an HA resource and loses the cluster's quorum reboots itself after
60 s (Proxmox's HA manual). In a cluster of two nodes, the death of one takes the other's quorum, so HA would reboot
the very node whose VM is taking over. Instead, a radio VM has a virtual watchdog (`qm … --watchdog
model=i6300esb,action=reset`) that systemd in the VM feeds: 30 s without it and the VM is reset. Its kernel reboots
10 s after a panic. Not covered: the VM's QEMU process itself dying. Then the other VM serves until someone starts
this one (`qm start`).

**What a third vote still adds**, and why the installer recommends one without requiring it: a node without quorum
starts no VM. A start checks quorum first (`check_cfs_quorum` in qemu-server's `vm_start`), and at boot Proxmox
waits for quorum with no time limit (`startall` in pve-manager). With two nodes and no third vote, while one node is
down the other starts no radio VM, at boot or by hand, until someone runs `pvecm expected 1` on it. VMs already
running are not affected, so a failover works; a power cut that only one node comes back from does not.

## The start, the sticks' power, and a stick that stays away (`host/hook.sh`)

**A radio VM starts with or without its sticks.** Proxmox passes a stick through when it appears, at the start or
any time later, when the VM's config names the stick itself (`usbN: host=…`): that is how the installer names
them. (A stick named through a USB *mapping* is checked by Proxmox at every start, and the start is refused while it
is absent: "USB Mapping invalid". At a node's boot nothing tries again, and the node is without its radio VM. Kit
0.1.0 made mappings; an update names the sticks directly instead, on a VM that is stopped, because the change would
unplug the sticks of a running one.) A VM without a stick is up, says so (`event=state`), and stays out of the pair
until the stick is there.

Every radio VM has the kit's hookscript, a file in each node's snippets storage (`zradio-hook.sh`, attached with
`qm set --hookscript`):

- **Before a start** it gives the sticks a minute (`WAIT`) to be on the node's USB, so that a VM that boots with the
  node silences them in its first seconds. Then the VM starts, and the journal says what was missing
  (`result=started-without`).
- It refuses a start in one case: another running VM of the node has one of the sticks. The second VM would take
  them from the first.

*Measured* on the reference pair's first node: at a warm reboot both sticks were on the bus before Proxmox started
anything; after a cold boot their hub came 19 s after its port had power.

**Stick power** (`--stick-power HUB:PORT`, once per port; kept in `zradio-hook-<vmid>.conf` beside the hookscript).
A Z-Wave stick that has power answers on the air whether or not anything talks to it. Where the sticks hang off a
hub port whose power can be switched, the hookscript switches it:

- **on** before the wait. A stick still missing after `CYCLE_AFTER` (25 s) gets the ports switched off and on once:
  a hub that hung comes back that way.
- **off** after the VM has stopped. Not while the node itself shuts down: the sticks are then there at its boot,
  and the start has no power-on to wait for. Not while another running VM of the node has one of the sticks: a
  backup in stop mode starts a stopped copy of a VM and stops it again (*measured*, with a hookscript that did not
  look: the radios were cut under the VM that served, for a night).
- **never at the node's boot.** Ports that are switched off at boot and on again by the start put a power-on into
  every boot (*measured*: of two boots that did, both left the node without its radio VM). What a boot leaves on
  the air until the VM silences its sticks is a Z-Wave receiver, for the seconds the VM takes to start.
- **off and on while the VM runs, when the VM asks.** A stick that stays silent after a soft reset and a USB
  re-bind, or whose serial port stays away, needs its power cycled, and only the node can do that. The hookscript's
  `post-start` starts a helper, the unit `zradio-heal-<vmid>` (`systemd-run`: no file of it is installed, and it
  ends with the VM). Every 5 minutes it asks the VM through the guest agent (`zradio-serve power-wanted`: one `qm`
  a look, which is all it costs the node). A VM that
  serves, or is about to, never asks. When it asks, the ports go off for 3 s and on again, the VM is told
  (`power-done`), and the stick is looked at as soon as its port is back. At most 3 times in 24 hours, 15 minutes
  apart, and never while another running VM of the node has one of the sticks. There is no setting for it; it needs
  `--stick-power`, because without the ports there is nothing to switch.

The kit does not look for the port. Whether a hub cuts a port's power or only disconnects it cannot be read from
the node (many hubs say they switch and do not), so the ports are named: `./install.sh --sticks` lists the hub
ports above each stick, and `uhubctl` shows which hubs say they switch (`ppps`). A USB 3 hub is two hubs, one per
speed, and its port goes dark only when it is switched on both. Where the kernel links the two, the installer adds
the other one itself; where it does not, both are named. Every stick has to hang off one of the named ports, or the
run is refused. The switch is the kernel's own file for the port (`…/<hub>-port<n>/disable`, Linux 6.0 and later),
the one `uhubctl` writes; `uhubctl` itself is not needed.

A backup of a **stopped** radio VM in stop mode starts it for the length of the backup: its sticks have power for
that long, with nothing that silences them.

Every run leaves a line in the node's journal: `journalctl -t zradio` (`event=hook result=ok waited_s=…`,
`started-without`, `refused`, `left-on`, `cycled`, `capped`, `held`, `fail`).

## The third vote (`vote/install.sh`, `host/qdevice.sh`)

The vote is Proxmox's own QDevice (its cluster manual, "Corosync External Vote Support"): `corosync-qnetd` on a
third machine, `corosync-qdevice` on the nodes, and `pvecm qdevice setup <address>` on one node, which makes the
certificates and writes the cluster's configuration. The kit writes none of that itself. It does what that command
needs done first, on both ends, and reads the votes back afterward. The two scripts' headers have the steps; the
reasons are here.

- **Why a container.** `pvecm qdevice setup` logs into the third machine as root over SSH and runs
  `corosync-qnetd-certutil` there. A NAS has no `apt-get` for that tool and no root login to give away. So where
  there is no `apt-get` (or with `--docker`), the vote is a container, `zradio-vote`: Debian 13 with
  `corosync-qnetd` and an SSH server of its own, on the machine's own network (`--network host`: qnetd sees the
  nodes' own addresses). Nothing of the machine itself is changed. Where there is `apt-get`, it is Debian's package.
- **Why no `docker build`.** A NAS's docker has no buildx, and `docker build` without it is the legacy builder that
  docker is retiring. The image is made with `docker run`, `docker cp` and `docker commit`, and carries a label of
  what it was made from: the kit's files and the Debian base image, which every `--run` pulls. A second run makes it
  again after the kit changed or Debian published a newer base, and not otherwise.
- **Why a one-time password.** The third machine goes first and needs nothing from a node. The container's root
  gets a password that the script makes up and shows; the node's first act is `ssh-copy-id` with it, and from then
  on it uses its key, as `pvecm` does. The password is good from the container's start until a key has been left,
  30 minutes at most. It is marked as used in the volume before the door opens, so a restart of the container never
  opens it again. It opens the container, not the machine. On the `apt-get` path the node asks for root's own
  password of that machine, as in Proxmox's manual. `--key` lets a node's public key in and uses no password.
- **Why an entry in root's SSH config on the node.** `pvecm` has no option for a port. For the container's SSH port
  that file is the one place its `ssh`, `scp` and `ssh-copy-id` all read one from. The entry is taken out again once
  the vote is set up: left there, it would send every later `ssh` of root's to that address to the container.
- **Why every node is asked.** The votes are counted on one node, and they add up there even when the other node
  cannot reach the vote. So each node's own connection is read (`corosync-qdevice-tool -s`): the node that is left
  alone one day is the one that needs it.
- **Why the line carries a host key.** The password is typed into `ssh-copy-id` on the node. The line the third
  machine prints ends with its SSH host key, the node puts it into root's `known_hosts` before anything logs in, and
  every login insists on it: the password goes to that machine or to nobody. A line without the key is still taken,
  and the key is then trusted on first use, as Proxmox's own setup does.
- **Why the SSH server closes.** It is for the setup. Two minutes after the vote has signed a cluster's certificate,
  and an hour after the script ran at the latest, the container stops its SSH server and writes that into the
  volume, so a restart does not open it again. The script's next run does.
- **What the container may do.** It is on the machine's own network, which the vote needs. It runs without raw
  sockets and may not gain privileges; no key of any kind is in its image (the certificate authority and the SSH
  host key are made in the volume at the first start); the password reaches it in its environment, not on a command
  line. A second run makes the new image before it removes the container that is in service. Every run checks that
  the SSH port is free or held by this container's own SSH server. A new container that does not answer and that
  docker keeps restarting is removed, with a line that says the vote is down; one that runs and only does not answer
  yet is left there.
- **Why the node's script refuses early.** `pvecm` would stop halfway and leave certificates behind: a node
  offline, no SSH to the other node, certificates of an earlier vote still on the node, an SSH config that sends
  the address to another port (ssh itself is asked: a pattern that fits counts, and so does a file ssh cannot read),
  a wrong password. `corosync-qdevice` is installed after one `apt-get update` where the first try fails.

## Home Assistant's side (`homeassistant/install.sh`)

It reads how Home Assistant's Z-Wave and Zigbee are connected and says what to set. From Home Assistant's list of
integrations (`<config>/.storage/core.config_entries`) it takes, for ZHA, the serial path and the adapter type, and
for Z-Wave, whether the integration runs the Z-Wave JS app, the app's USB or socket path, and the server's address.
Only those fields are read; the Z-Wave keys are in the same file and are never taken out of it.

| What Home Assistant has | It says |
|---|---|
| the pair's path already | `OK` |
| another path (a stick in its own machine) | `TODO`, with the steps in Home Assistant's own pages |
| no such integration | `TODO`, with how to add it on the pair |
| Z-Wave through a server it cannot look into (Z-Wave JS UI, or a server elsewhere) | `CHECK`, with where that server's serial port is set |

What it does not do, and why:

- **It makes none of the changes.** ZHA and the Z-Wave integration change their path in a dialog that stops the
  integration, tries the stick, and saves. From the terminal app, Home Assistant's own API is closed (it answers 401
  to the app's token), Z-Wave JS UI's is not reachable, and the file read here is Home Assistant's own state, which
  must not be edited under it.
- **It does not connect to the pair's ports, and does not search the network for the pair.** Each port takes one
  client, and ser2net gives it to the newest one: a look would cut Home Assistant off. Nothing else of the pair
  answers. Whether the floating address is there is asked with a ping.
- **It cannot tell that Home Assistant is connected**, only what it is set to. From the pair's side, in the VM that
  serves: `ss -tn state established '( sport = :6639 or sport = :6638 )'` lists Home Assistant's connections.

**The floating address**, when `--radios` does not give it, is looked for in the same file: a `socket://` or
`tcp://` path with a numeric address that ZHA or the Z-Wave JS app uses already. One such address is asked about on
a terminal, and taken (and said to be taken) without one; two different ones are shown and none is picked. Where
there is none, the script says where the address is: `./install.sh` on a node with a radio VM reads it from the VM
and ends with the line for Home Assistant, and each radio VM's Notes in Proxmox name it.

The steps name Home Assistant 2026.11's pages and menus. Two choices in them matter: for a stick that holds a
network, ZHA's "Set up automatically" and "Migrate to a new adapter" both write to a stick, and the steps say which
choice does not.

## Updating (`host/update.sh`)

`./install.sh` (or the install line) on a node whose radio VM exists updates that VM and the pair's other one.
Each VM's kit has a stamp, `/usr/local/lib/zradio/kit-version`: `VERSION` for people, and `CONTENT`, a hash of every
file the VM installs from the kit (`guest/lib/zradio-kit-stamp.sh`). A VM whose `CONTENT` is this kit's is up to date
and left alone. Otherwise the kit is sent into it through the guest agent, in pieces (Proxmox takes at most 64 KiB per
call), checked, and unpacked into `/opt/zradio/kit`, with the one before kept as `/opt/zradio/kit.previous`. Then the
kit's installer runs there again (`guest/install.sh --from-node --run`). It replaces only the files that differ,
keeps the VM's conf, role and keys, and does not stop the radios ("In a radio VM" says what it restarts). The VM that does not serve goes first: if its
update fails, the one that serves is not touched. The stamp is installed last, so a failed run never claims the new
kit. To put the kit before back: `bash /opt/zradio/kit.previous/guest/install.sh --from-node --run` in the VM.

Before any of that, the run puts this node's own part right: the hookscript's file, the VM's stick power when
`--stick-power` or `--no-stick-power` says so, the hookscript on this node's VM, and its helper when the VM runs.
On a VM that is stopped it also names the sticks directly where kit 0.1.0 had named them through USB mappings
(`qm shutdown`, the installer, `qm start`: the VM that does not serve first); on a running VM it says that this is
still to do. That needs no answer from a VM, so it also reaches a VM that is stopped; such a VM's kit is looked at
once it runs. The hookscript is a file of
each node: the VMs' kits are updated from either node, the hookscripts by a run on each.

**Versions.** No version number is kept in a file. A release is a GitHub release of a git tag (`v0.1.0`): `get.sh`
asks GitHub for the latest release, so a tag alone is not found. It writes the version into the kit's
`gen/version`: the tag, or `<branch>@<commit>` for anything taken with `ZRADIO_REF`. In a clone, the version is `git
describe` (`v0.1.0-3-g08df12f`, `-dirty` with uncommitted changes).

## Not built

- Proposing free addresses.
- A Home Assistant integration (status, "sync now", "switch"); a sync without the pause.
- More families synced (Silicon Labs EZSP first); Zigbee2MQTT.
- The pair announcing itself on the network, so that Home Assistant finds it.
- A restart of a VM whose QEMU process died (no Proxmox HA, above): the other VM serves until it is started.
- A hung stick that still acknowledges: the check counts a stick as answering when it sends anything at all. Pairing
  each request of Home Assistant with its own answer would see that case, and in half the time; it wants a capture
  from a live pair first.
- Removing a radio VM: `qm stop`, `qm destroy --purge`, and its cloud-init file and `zradio-hook-<vmid>.conf` in
  the snippets storage, by hand.

Built, and off until you turn it on: the election (`ELECTION=act`). It only logs by default.

## Tests

The tests are for development. A release's archive, which is what `get.sh` puts on a machine, carries no `tests/`
(`.gitattributes`).

| | Runs | Real | Not real |
|---|---|---|---|
| `bash tests/run.sh` (Linux), `bash tests/docker.sh` (anywhere) | every `t-*.sh` | the kit's scripts, the files they write, real ssh keys; where ser2net, keepalived and cloud-init are installed, their files are given to the real programs | Proxmox, the VMs, the sticks, Home Assistant, the network |
| `bash tests/vote-real.sh` (docker) | the third vote | the container; ssh, `ssh-copy-id` and the one-time password, its end after its time and after a restart; the commands `pvecm qdevice setup` runs; a corosync node getting its vote | `pvecm` itself, a Proxmox cluster |
| `bash tests/vote-bash.sh` (docker) | the third vote's script under bash 3.2 and 4.4 (what a NAS may have) | bash | docker (a fake) |
| `bash tests/hass-real.sh` (docker) | Home Assistant's side | the install line and the script on the kind of machine Home Assistant's terminal is (Alpine, busybox, no python) | Home Assistant |
| `sudo bash tests/rehearse-election.sh` | the election | keepalived, in two network namespaces | radio VMs, sticks |
| `sudo ZRADIO_THROWAWAY=1 bash tests/timer-real.sh` (a throwaway Linux) | the nightly timer across a change of its time | systemd, a timer like `zradio-sync.timer`, `daemon-reload` | the installer (`t-install.sh` holds it to the order shown) |

`bash tests/check-pins.sh` (docker, the network) is not a test of the kit but of what it pins where Dependabot cannot
see it: the Z-Wave JS UI image (the Node.js inside it), zigpy-cli and Debian 13, against their makers' end-of-life
dates, and the image's pinned digest against what the registry answers for its tag. An end of life, or one within
60 days, fails; a newer release is a warning, because a version that writes sticks is taken only after a sync with
it was seen on a pair. It runs weekly in CI and whenever a pin changes.

`tests/run.sh` needs bash 4 or later, GNU coreutils and sed, util-linux, python3 with PyYAML, openssh-client and jq.
`tests/try.sh` (docker) is a shell on a pretend two-node cluster, to see the install without a node.

**What has run where.** On real hardware, one pair: the install on two Proxmox VE 9 nodes, the third vote in its
container on a NAS with `pvecm qdevice setup`, Home Assistant's side on Home Assistant OS, an update of both VMs,
and the hookscript at a VM's stop and start with stick power (the ports of a USB 3 hub off after the stop, on before
the start, the sticks back within a second), its helper started and stopped with the VM and asking through the guest
agent. Not on real hardware: a start without a stick (that Proxmox starts a VM without a stick named by `host=` is
from its manual), a power cycle that a VM asked for, the healing of a stick that does not answer (a soft reset, a
USB re-bind), the hung-stick check declaring a stick, the third vote from Debian's package, the election in `act`
mode, served-only sticks, and Home Assistant's own Z-Wave JS app on the pair (the pair above uses Z-Wave JS UI).
