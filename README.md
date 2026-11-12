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

## Installing by hand (until the Proxmox helper exists)

You need two Proxmox nodes, each with its own set of sticks, and on each node a Debian 13 VM (the *generic* cloud
image: the `-cloud` kernel has no USB) with the node's sticks passed through, a fixed address, and a network it shares
with the other VM and with Home Assistant.

1. Copy `zradio.conf.example`, fill it in (two addresses, the floating address, a name) — once per VM.
2. On **each** VM, as root: `bash guest/install.sh --conf zradio.conf` reads back what it would do; add `--run` to do
   it. It installs the packages, detects the sticks, and starts nothing.
3. Each run ends by printing a `zradio-sync trust …` line. Run VM A's line on VM B and B's on A.
4. `systemctl start zradio.target` on the VM whose sticks hold your networks **first**; then on the other. The first
   serves; its 15-minute tick fills the second VM's sticks. A new VM with blank sticks cannot take the radios before
   it is filled (the installer marks it; `--first` is for a pair that starts with no network at all).
5. Point Home Assistant at the floating address: Z-Wave JS `tcp://<VIP>:6639`, ZHA `socket://<VIP>:6638`.

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

## A radio VM from nothing: `host/zradio-vm`

On each Proxmox node, as root, from a checkout of this repository:

```
host/zradio-vm sticks                     # what is plugged into this node that the kit knows; changes nothing
host/zradio-vm create --name zradio1 --self 192.0.2.11/24 --peer 192.0.2.12 --vip 192.0.2.10/24 --gateway 192.0.2.1
host/zradio-vm create …the same… --run    # without --run it only says what it would do
```

It makes the VM from Debian 13's cloud image, passes this node's sticks through (Proxmox USB mappings; the VM finds
out by itself which stick is what), installs the kit inside by cloud-init, makes the VM a Proxmox HA resource with a
**strict** node rule — Proxmox restarts it here and never moves it onto the other node's sticks — and only then starts
it. It ends by showing what the installer found and the `zradio-sync trust` line for the other VM. The VM joins the
pair at `systemctl start zradio.target` (or with `--start`). `--pair-bridge BR` puts the pair's traffic on a link of
its own; `--usb-mapping ID` uses mappings you already have; `--hookscript` attaches a hookscript of yours.

It refuses, before anything is changed, a name or id that is taken, a **running** VM that already uses the address or
one of the sticks, a missing key for root, and a node without Proxmox HA unless `--no-ha` is said. It never rebuilds
or removes a VM. **Not built:** switching a stopped VM's USB ports off (a stick keeps its radio on while it has power:
a site with a hub that can switch ports brings its own hookscript for now).

## Not built yet

- **One command per node and a pairing code** instead of the config file and the two `trust` lines (phase 2).
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
