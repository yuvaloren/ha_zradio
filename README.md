# ha_zradio

Z-Wave and Zigbee for Home Assistant that survive a dead server. Two small VMs, one per Proxmox node, each with its
own sticks. One serves the sticks to Home Assistant over the network; the other keeps a copy of both networks on its
sticks and takes over within seconds. Home Assistant talks to one floating address.

**Status: under construction, and not yet run on real hardware.** The code is tested against a fake Proxmox cluster
and fake sticks only. The scripts it grew out of have run one real pair since 2026-11-11.

## Install

You need two Proxmox nodes in one cluster, a Z-Wave and/or Zigbee stick on each, and a network with DHCP that Home
Assistant can reach. Pick one free address on it that DHCP does not hand out: the floating address.

On the node whose sticks your devices are paired to, as root:

```
git clone https://github.com/yuvaloren/ha_zradio.git && cd ha_zradio
./install.sh
```

It asks a few questions, shows what it will do, and does it after a `y`. Then run the same on the other node: there
it finds the first VM, takes the network from it, and sets up the keys between the two. At the end it prints the
addresses to enter in Home Assistant.

Each VM gets its own address from DHCP, and the pair knows it by that address from then on. **Reserve it in your
DHCP server** (each run ends with the address and the MAC). A VM whose address changes stops serving until it has
the old one back. Fixed addresses instead: `--self`, `--peer`, `--gateway`.

The one question to get right:

| This node is initially the… | Its sticks |
|---|---|
| **primary** | hold your networks. They stay as they are. |
| **standby** | **will be wiped**: the first sync overwrites them with the primary's networks. |

"Initially", because after that first sync the two VMs are equals and swap at every failover.

Without questions: `./install.sh --answers my.answers --run` ([answers.example](answers.example)), or every answer
as an option (`./install.sh --help`). Nothing is changed without `--run` or a `y`.

## Which sticks

The VM works out by itself which stick is what. Either kind may be missing.

| | Sticks | Fails over | Standby holds a copy |
|---|---|---|---|
| **synced** | Z-Wave 800 series; Zigbee on TI Z-Stack (CC2652) | yes | yes |
| **served** | every other Z-Wave or Zigbee stick | yes | no — restore with Home Assistant's tools after a takeover |

## Day to day

In a radio VM (`qm guest exec <id> -- <command>` on its node, or ssh):

| Command | |
|---|---|
| `zradio-serve status` | who serves, and anything holding this VM back |
| `zradio-sync run --reason manual` | sync now (pauses the radios about 12 s) |
| `zradio-switch --run` | hand the radios to the other VM |
| `journalctl -t zradio` | every decision, one line each |

## What to expect

Measured on the pair this kit was extracted from (about 50 Z-Wave nodes):

| Event | Z-Wave back | Zigbee back |
|---|---|---|
| Planned switch | 1.3 s | 7 s |
| The serving VM dies | about 5 s | about 14 s |
| A sync (nightly, and after a device is added or removed) | paused 14 s | paused 26–28 s |

## More

- [docs/DESIGN.md](docs/DESIGN.md): how it works, every option, what is not built.
- Tests: `bash tests/run.sh` on Linux, `bash tests/docker.sh` anywhere else (macOS lacks the GNU tools they need).
  No hardware needed; they also run on every push (`.github/workflows/tests.yml`).
- To see the install without a Proxmox node: `tests/try.sh` (needs docker) is a shell on a pretend two-node cluster
  where `./install.sh` asks and prints what it would on a real one. Proxmox, the VMs and the sticks are fakes.
- MIT. The USB id list is derived from Home Assistant core (Apache-2.0).
