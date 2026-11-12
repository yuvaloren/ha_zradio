# ha_zradio

Two small VMs, one per Proxmox node, each on its own Z-Wave and Zigbee USB sticks. One of them serves the sticks to
Home Assistant over the network; the other stands by with **its sticks holding a synced copy of both networks**, and
takes over within seconds when the first one stops, dies, or loses a stick. Home Assistant talks to one floating
address and does not take part in the decision.

**Status: phase 1 of 4, under construction.** What is in this repository is the part that runs *inside* a radio VM,
and `host/zradio-vm`, which builds such a VM on a Proxmox node. The VM's side is extracted from the scripts that run
a real pair since 2026-11-11; both are tested against fakes (and against the real `ser2net`, `keepalived`,
`systemd-analyze` and `cloud-init` where installed). **This repository's own code has not yet run on real sticks,
and `zradio-vm` has not yet created a VM on a real node**: the first run of both is the rebuild of that pair from this
kit. Until that is recorded here, treat it as unproven.

## What it does, and what was measured

Measured on the reference pair (Aeotec Z-Stick 10 Pro with about 50 Z-Wave nodes; Sonoff ZBDongle-P; Z-Wave JS UI and ZHA),
running this kit's predecessor scripts:

| Event | Z-Wave back | Zigbee back |
|---|---|---|
| Planned switch (`zradio-switch --run`) | 1.3 s | 7 s |
| The serving VM dies | about 5 s | about 14 s |
| A stick is unplugged from the serving VM | 6 s | 8 s |
| A sync (nightly, and after a device is added or removed) | paused 14 s | paused 26–28 s |

A sync reads both sticks on the serving VM (about 12 s with the sticks offline), sends the set to the standby over
ssh, and the standby writes it onto its own sticks and verifies it (90–97 s, during which nothing is interrupted).

## What each radio gets

`zradio-detect` looks at the VM's USB serial ports, asks each one what it is (read-only) and gives it a level.
Nobody types a radio's name, port or id.

| Level | Families | Served and failed over | Standby kept silent | Standby is a copy |
|---|---|---|---|---|
| **synced** | Z-Wave 800 series; Zigbee on TI Z-Stack (ZNP: CC2652 sticks) | yes | yes | yes |
| **served** | every other Z-Wave or Zigbee stick | yes | no | no |

"Served" is the fallback, said on screen: the stick is served and the address fails over, but the kit does
not write to it, so the standby's stick of that family must hold no network, and after a takeover its network has to
be restored with Home Assistant's own tools. The serial settings of served-only sticks come from a list and are not
verified on hardware. `synced` is proven on one model per family (the two above).

Recognition starts from the USB lists Home Assistant's own Zigbee and Z-Wave integrations ship
(`guest/lib/usb-ids.json`, rebuilt by `tools/update-usb-ids.py`), then the stick's own answer decides.

## Layout

```
host/zradio-vm            on a Proxmox node: build that node's radio VM (below)
guest/install.sh          the installer: run inside each radio VM
guest/sbin/               zradio-detect  -serve  -notify  -sync  -apply  -switch  -gate  -change-watch  -render
guest/lib/                the probe, the Z-Wave JS UI restore client, templates, the USB list
guest/units/              systemd units
zradio.conf.example       the one config file
tests/                    bash tests/run.sh; tests/rehearse-election.sh (root: the real keepalived in two namespaces)
tools/                    maintenance (the USB list)
docs/DESIGN.md            how it works and why; what is not built
```

## Installing

You need two Proxmox nodes in one cluster, each with its own set of sticks; three free addresses on a network both
radio VMs and Home Assistant are on (one per VM, one floating); and this repository on each node (`git clone`, as root).

The installer asks what each node is **initially** — on the day of the install:

| initially | its radios | what happens to them |
|---|---|---|
| **primary** | are configured: the sticks on this node hold your networks | nothing. They stay as they are, and this VM serves them first |
| **standby** | **will be wiped** | the first sync overwrites them with the primary's networks, whatever they hold. Until then this VM does not serve |

Only initially: after that first sync the two VMs are equals. They swap at every failover and every switch, either
serves, and the question is never asked again (`zradio-serve status` says who serves today).

**1. On the initial primary's node** — the one whose sticks your devices are paired to:

```
cd ha_zradio
host/zradio-vm sticks
host/zradio-vm create --self 192.0.2.11/24 --peer 192.0.2.12 --vip 192.0.2.10/24 --gateway 192.0.2.1
```

`sticks` lists the Z-Wave and Zigbee sticks it sees and changes nothing. `create` asks **initially primary or
standby** (answer `primary` here; `--initial-role primary` says it up front) and what the VM shall be called (Enter
takes `zradio1`; `--name` says it up front), and then reports every step it would take. Read it, then run the same
line with `--run`. Some minutes later it shows what the installer in the VM found — which stick is what, and whether
each will be *synced* or only *served* — and one `zradio-sync trust …` line.

The installer in the VM checks the answer against the sticks: a primary whose sticks turn out to hold no network is
refused and left unable to serve, because that answer was meant for the other node (or the house is new, below).
It cannot check the other mistake — `standby` said on the node that holds your networks. It names the sticks that
hold a network and says they will be overwritten; read that line before the pair is started.

- The pair on a link of its own between the nodes instead of the LAN: `--pair-bridge <bridge>` in place of `--gateway`.
- A VM that has the sticks today (a Z-Wave JS or Zigbee2MQTT VM, Home Assistant itself) must be shut down or have the
  sticks taken out of it first; the tool refuses while a running VM holds them.
- A new house, no device paired yet: still `primary`, and answer `n` when it asks whether the sticks hold your
  networks (`--initial-role primary --first`). Home Assistant forms the networks on this node's sticks.

**2. On the initial standby's node**, the same with the two addresses swapped:

```
host/zradio-vm create --initial-role standby --self 192.0.2.12/24 --peer 192.0.2.11 --vip 192.0.2.10/24 --gateway 192.0.2.1 --run
```

When nobody is there to answer (a script, a pipe), `--initial-role` must be said: the tool does not guess it.

**3. Introduce the two VMs to each other.** Each `create` ended with a `zradio-sync trust …` line: run the first VM's
line in the second VM and the second's in the first. A command gets into a VM by `ssh root@<its address>` (root's keys
are the node's own `authorized_keys`) or, on its node, as `qm guest exec <id> -- <the command>`.

**4. Start the pair**, in each VM:

```
systemctl start zradio.target
zradio-serve status
```

The initial primary serves; within 15 minutes it writes its networks onto the standby's sticks (`zradio-sync run`
on the serving VM does it now). The standby cannot take the radios before that, in whichever order the two are
started. From that first sync on the two swap, and "primary" was only the word for who held the networks on the
day of the install (that VM also has the higher priority, 110 against 100, so it wins a tie).

The answer is used once and kept in the VM (`/var/lib/zradio/initial-role`): running the installer again later
with the same answer changes nothing — it neither marks a VM that has since become the one that serves, nor
frees one that a sync is in the middle of filling. A wrong answer is corrected by running `install.sh --detect
--initial-role <the other>` in the VM before the pair is started.

**5. Point Home Assistant at the floating address:** Z-Wave JS `tcp://192.0.2.10:6639`, ZHA `socket://192.0.2.10:6638`.

What this leaves to you today, and is meant to go away (see "Not built yet"): choosing the three addresses, typing them
on both nodes, and step 3.

### Without Proxmox's help

On any two Debian 13 machines that have the sticks (the *generic* cloud image if it is a VM: the `-cloud` kernel has
no USB), a fixed address each, and a network shared with each other and with Home Assistant:

1. Copy `zradio.conf.example`, fill it in (two addresses, the floating address, a name) — once per machine.
2. On **each**, as root: `bash guest/install.sh --conf zradio.conf --initial-role primary` (or `--initial-role
   standby`, the table above) reads back what it would do; add `--run` to do it. It installs the packages, detects
   the sticks, and starts nothing.
3. Then steps 3 to 5 above.

## Day to day (on a radio VM, as root)

| Command | What it does |
|---|---|
| `zradio-serve status` | this VM's role, its sticks, anything holding it back |
| `zradio-sync status` | what was last synced, and whether the standby holds it |
| `zradio-sync run --reason manual` | on the serving VM: sync now (pauses the radios about 12 s) |
| `zradio-switch` / `zradio-switch --run` | check, then hand the radios to the standby |
| `zradio-gate status` | this VM's version of the networks (term, used), and whether it is waiting, outdated or held |
| `zradio-detect` | what the kit sees on the USB ports (on a VM that does not serve) |
| `journalctl -t zradio` | every decision, one line each: `event=… result=…` |

Each tool's header says what it does, what it refuses and why; `--help` prints it.

## Who serves when it is not obvious (built, off by default)

Which VM serves after both boot together, after a failed VM returns with an older copy, or after the link between
the nodes was cut — decided by a version of the networks each VM keeps (a counter, not a clock), not by which
keepalived started first. `docs/DESIGN.md` §3a has the rules and what a rehearsal with the real keepalived showed.

It ships as `ELECTION=observe`: the pair behaves exactly as without it, and every decision it *would* take is a
journal line (`journalctl -t zradio | grep would-`). `ELECTION=act` in `zradio.conf` on **both** VMs, then
`systemctl restart zradio-gate` on both, arms it. Before arming: read some days of `would-` lines; have one sync run
(`zradio-sync run --reason manual` on the serving VM) so both VMs hold the same term (`zradio-gate status`); and
know what it costs — a VM that boots with nobody answering serves after `ELECTION_WAIT` (60 s) plus about 10 s
instead of after 4 s, and a VM with an older copy whose peer disappears after that wait plus up to half a minute. **It has not run on a radio VM, and its handling of the Zigbee frame counter has not been
tried with devices.**

## What `host/zradio-vm create` does

It makes the VM from Debian 13's cloud image, passes this node's sticks through (Proxmox USB mappings; the VM finds
out by itself which stick is what), installs the kit inside by cloud-init, makes the VM a Proxmox HA resource with a
**strict** node rule — Proxmox restarts it here and never moves it onto the other node's sticks — and only then starts
it. The VM joins the pair at `systemctl start zradio.target` (or with `--start`). `--initial-role primary|standby` is
the question above, answered up front (it sets up the first day only); `--priority` overrides what the role gives.
`--usb-mapping ID` uses USB mappings you already have; `--hookscript` attaches a hookscript of yours; `--vmid`,
`--storage`, `--memory`, `--cores`, `--disk` are what they say; `--no-usb` builds a VM without sticks, to try the tool
beside a running setup.

It refuses, before anything is changed, a name or id that is taken, a **running** VM that already uses the address or
one of the sticks, a missing key for root, and a node without Proxmox HA unless `--no-ha` is said. It never rebuilds
or removes a VM. **Not built:** switching a stopped VM's USB ports off (a stick keeps its radio on while it has power:
a site with a hub that can switch ports brings its own hookscript for now).

## Not built yet

- **Nothing typed twice, nothing pasted** (phase 2): the first node proposes free addresses, the second node finds
  the first VM in the cluster and takes everything from it, and the two VMs are introduced without the `trust` lines.
- **The Home Assistant integration**: status, "sync now", "switch", a sync without the pause, repair notices (phase 3).
- **More families synced**: Silicon Labs EZSP first; Zigbee2MQTT (phase 4). These need hardware this project does
  not have: reports are what moves a family from "served" to "synced".
- The silent-stick check in `zradio-change-watch` only observes (`result=would-wedge`); arming it is a setting.

## Tests

`bash tests/run.sh` — bash 4+, python3 (with PyYAML for `t-host.sh`), util-linux, openssh-client (`ssh-keygen`). Where `ser2net`, `socat`,
`keepalived` and `systemd-analyze` are installed, the rendered config files are given to the real programs. Nothing
in the tests reaches a radio.

`sudo bash tests/rehearse-election.sh` (about 3 minutes; needs keepalived and iproute2) plays seven situations with
the real keepalived and the kit's own tools in two network namespaces on one machine: both VMs booting, a hard
death and return, a short outage, an outdated VM serving and being preempted, a planned switch, a cut link, and
observe mode. It creates and removes two namespaces, a bridge and `/root/zradio-rehearse`; run it on a scratch
machine, not on a radio VM.

## License

MIT. The USB id list is derived from Home Assistant core's manifests (Apache-2.0).
