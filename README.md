# ha_zradio

Two small VMs, one per Proxmox node, each on its own Z-Wave and Zigbee USB sticks. One of them serves the sticks to
Home Assistant over the network; the other stands by with **its sticks holding a synced copy of both networks**, and
takes over within seconds when the first one stops, dies, or loses a stick. Home Assistant talks to one floating
address and does not take part in the decision.

**Status: phase 1 of 4, under construction.** What is in this repository is the part that runs *inside* a radio VM.
It is extracted from the scripts that run a real pair since 2026-11-11 and is tested against fakes (and against the
real `ser2net`, `keepalived` and `systemd-analyze` where installed). **This repository's own code has not yet run on
real sticks**: its first hardware run is the rebuild of that pair from this kit. Until that is recorded here, treat it
as unproven.

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
guest/install.sh          the installer: run inside each radio VM
guest/sbin/               zradio-detect  -serve  -notify  -sync  -apply  -switch  -change-watch  -render
guest/lib/                the probe, the Z-Wave JS UI restore client, templates, the USB list
guest/units/              systemd units
zradio.conf.example       the one config file
tests/                    bash tests/run.sh
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
| `zradio-detect` | what the kit sees on the USB ports (on a VM that does not serve) |
| `journalctl -t zradio` | every decision, one line each: `event=… result=…` |

Each tool's header says what it does, what it refuses and why; `--help` prints it.

## Not built yet

- **The Proxmox side**: creating the VM, passing the sticks through, powering a stopped VM's USB ports down, and
  putting each radio VM under Proxmox HA restricted to its own node (so Proxmox restarts it but never moves it).
  Today that is done by hand.
- **One command per node and a pairing code** instead of the config file and the two `trust` lines (phase 2).
- **The Home Assistant integration**: status, "sync now", "switch", a sync without the pause, repair notices (phase 3).
- **More families synced**: Silicon Labs EZSP first; Zigbee2MQTT (phase 4). These need hardware this project does
  not have: reports are what moves a family from "served" to "synced".
- The silent-stick check in `zradio-change-watch` only observes (`result=would-wedge`); arming it is a setting.

## Tests

`bash tests/run.sh` — bash 4+, python3, util-linux, openssh-client (`ssh-keygen`). Where `ser2net`, `socat`,
`keepalived` and `systemd-analyze` are installed, the rendered config files are given to the real programs. Nothing
in the tests reaches a radio.

## License

MIT. The USB id list is derived from Home Assistant core's manifests (Apache-2.0).
