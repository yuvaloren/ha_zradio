# ha_zradio

Z-Wave and Zigbee for Home Assistant that survive a dead server. Two small VMs, one per Proxmox node, each with its
own sticks. One serves the sticks to Home Assistant over the network; the other keeps a copy of both networks on its
sticks and takes over within seconds. Home Assistant talks to one floating address.

## Install

You need two Proxmox nodes in one cluster, a Z-Wave and/or Zigbee stick on each, and a network with DHCP that Home
Assistant can reach. Pick one free address on it that DHCP does not hand out: the floating address.

On the node whose sticks your devices are paired to, as root:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)"
```

It downloads the kit into `/opt/ha_zradio/<version>` and runs its installer (`./install.sh`) on your terminal. Or
clone the repository and run `./install.sh` yourself.

It asks a few questions, shows what it will do, and does it after a `y`. Then run the same on the other node: there
it finds the first VM, takes the pair's addresses and settings from it, and sets up the keys between the two. At the end it prints the
addresses to enter in Home Assistant.

**To update**, run the same line again, on each node. It finds the pair, says which kit each VM runs, and updates
the ones that need it (or says they are up to date) after a `y`; and it brings that node's hookscript up to date.
The radios keep running.

A radio VM starts with or without its sticks: its hookscript gives them a minute to be on the node's USB, and
Proxmox passes a stick through whenever it appears. A stick that stops answering is handed over first and healed
second: the other VM takes the radios, and this one tries a soft reset, a USB re-bind and, last, a power cycle.
Only the node can switch a stick's power, so name the hub port(s) the sticks hang off: `--stick-power HUB:PORT`
(`./install.sh --sticks` lists them). The hookscript then switches them on before the VM starts, off after it stops,
and off and on when the VM asks (docs/DESIGN.md, "The start, the sticks' power, and a stick that stays away").

Each VM gets its own address from DHCP, and the pair knows it by that address from then on. **Reserve it in your
DHCP server** (the VM's install ends with the address and the MAC). A VM whose address changes stops serving until it has
the old one back. Fixed addresses instead: `--self`, `--peer`, `--gateway`. With a link of its own between the
nodes (`--pair-bridge`), the floating address is on that link, and Home Assistant has to reach it there.

The one question to get right:

| This node is initially the… | Its sticks |
|---|---|
| **primary** | hold your networks. They stay as they are. |
| **standby** | **will be wiped**: the first sync overwrites them with the primary's networks. |

"Initially", because after that first sync the two VMs are equals and swap at every failover.

Without questions: `./install.sh --answers my.answers --run` ([answers.example](answers.example)), or every answer
as an option (`./install.sh --help`). Nothing is changed without `--run` or a `y`.

### Two nodes or three

Two nodes are enough: the two VMs decide between them which one serves, and either node can die. The kit does not use
Proxmox HA (on two nodes it would make the surviving node reboot itself); a VM that hangs is reset by its watchdog.

A third vote is optional, and recommended. Without it, while one node is down the cluster has no quorum, and Proxmox
starts no VM on the other node, at boot or by hand, until you run `pvecm expected 1` there. VMs already running keep
running, so a failover works without it; a power cut that only one node comes back from does not. The installer says
which case your cluster is in.

The third vote is Proxmox's QDevice: a small daemon on any always-on machine outside the cluster. A NAS, a Pi or a
small Linux box will do; a VM on either node will not. Two steps, each of which shows what it would do and does it
after a `y`:

1. **On that machine, as root:** the same install line as on the nodes. It sees that the machine is not a Proxmox
   node and says that it sets up the third vote there, not a radio VM. On Debian, Ubuntu or Raspberry Pi OS it
   installs Debian's `corosync-qnetd` package; anywhere else with docker (a NAS), or with `--docker`, it makes and
   starts a container. It ends with the line for a node, and with the container a one-time password. The line
   carries that machine's SSH host key, so the node talks to it and to nobody else. The container's SSH server is
   for this setup: it closes by itself afterward.
2. **On one node:** that line. It asks for the password once, installs `corosync-qdevice` on both nodes, runs
   Proxmox's own `pvecm qdevice setup`, and checks that the cluster now keeps its quorum without one node.

Both nodes must reach that machine on TCP port 5403. The node of step 2 also needs its SSH port: the container's
(2222 unless you choose another), or 22.

## Connecting Home Assistant

Home Assistant connects to the floating address, never to a VM: whichever VM serves holds it. The installer's last
lines give the two addresses, and a line for Home Assistant's terminal. Home Assistant's host must reach the
addresses, and each port takes one client at a time.

**What to set, for your Home Assistant.** In Home Assistant's terminal (Settings > Apps > Terminal & SSH; "Add-ons"
in older versions), the kit's install line:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/yuvaloren/ha_zradio/main/get.sh)" _ --radios <floating address>
```

Without `--radios` it looks for the address in Home Assistant's own settings (ZHA or the Z-Wave JS app may use it
already) and asks. If you do not know the address: the install line on either Proxmox node says how the pair is and
ends with this line, the address filled in; and each radio VM's Notes in Proxmox name it. It does not search the
network for the pair: the pair's two ports are all that would answer, and touching them cuts Home Assistant off.

It changes nothing in Home Assistant. It reads how Home Assistant's Z-Wave and Zigbee are connected now, and says
`OK`, or the steps for your setup, with the names of the menus (Home Assistant 2026.11's). Run it again afterward
and it checks them. It does not do the steps for you: Home Assistant changes these paths only in its own dialogs,
which stop the integration and try the stick before they save.

The same steps by hand:

**Zigbee (ZHA).** The path is `socket://<floating address>:6638`.

- ZHA that used a stick on its own machine, with that stick now in the pair: Settings > Devices & services > Zigbee
  Home Automation > the gear. On ZHA's page, "Migrate adapter": Migrate. Confirm the backup, then choose "Change the
  current adapter's settings" (not "Migrate to a new adapter"), and type the path as the serial device path. If it
  asks how to migrate: "Migrate manually", then "Keep adapter network settings". The stick already holds the network.
- A new ZHA: Add integration > Zigbee Home Automation, and the same path. With sticks that hold your network, choose
  "Set up manually", then "Keep adapter network settings". "Set up automatically" erases the stick and creates a new
  network: that one is for a new house.

**Z-Wave.** Home Assistant's Z-Wave integration talks to a Z-Wave JS server, and that server opens the stick. The
path is `tcp://<floating address>:6639`; your network's S0/S2 keys stay as they are.

- Z-Wave JS UI (the app, or a container of your own): in its own page, Settings > Z-Wave > Serial Port. The Z-Wave
  integration itself needs no change. The install line above cannot look into this server; it says so.
- Home Assistant's own Z-Wave JS app: Settings > Devices & services > Z-Wave > the three dots > Reconfigure >
  "Reconfigure the current adapter" > USB: "Use Socket", and the path as the socket device path.

The ports are neither authenticated nor encrypted: keep them on a trusted network. The reference pair runs ZHA and
Z-Wave JS UI; the Z-Wave JS app's socket path has not been run with the kit.

**Replacing a pair you already have:** give the new pair the same floating address and ports, and Home Assistant
needs no change. It reconnects by itself.

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
| `zradio-sync run --reason manual` | sync now (Home Assistant is without the radios for 15 to 30 s) |
| `zradio-sync status` | the last sync, and what the standby holds |
| `zradio-sync reapply` | on the standby: write the last received copy onto its sticks again (after a write that failed) |
| `zradio-switch --run` | hand the radios to the other VM |
| `zradio-gate status` | the election on this VM: its version of the networks, its marks, and what they mean |
| `systemctl start zradio.target` | put this VM into the pair (a reboot does too); `systemctl stop keepalived` takes it out |
| `journalctl -t zradio` | every decision, one line each |

## What to expect

Measured on the pair this kit was extracted from (about 50 Z-Wave nodes):

| Event | Z-Wave back | Zigbee back |
|---|---|---|
| Planned switch | 1.3 s | 7 s |
| The serving VM dies | about 5 s | about 14 s |
| A sync (nightly, and after a device is added or removed) | after 14 s | after 26–28 s |

## More

- [docs/DESIGN.md](docs/DESIGN.md): how it works and why, every option, what is not built, what has run where.
- Versions: a release is a GitHub release of a git tag; the installers stamp each VM with the kit it runs
  (docs/DESIGN.md, "Updating"). The latest `main` instead of the latest release: `--main` right after the install
  line's `_` (`bash -c "$(curl -fsSL …/get.sh)" _ --main`); any other version: `--ref <tag or branch>` there.
- Tests: `bash tests/run.sh` on Linux, `bash tests/docker.sh` anywhere else (macOS lacks the GNU tools they need).
  No hardware needed; they also run on every push (`.github/workflows/tests.yml`). `bash tests/vote-real.sh` (needs
  docker) tests the third vote's container with the real programs, `bash tests/vote-bash.sh` its script under the
  old bash a NAS may have, and `bash tests/hass-real.sh` Home Assistant's side on the kind of machine its terminal
  is.
- To see the install without a Proxmox node: `tests/try.sh` (needs docker) is a shell on a pretend two-node cluster
  where `./install.sh` asks and prints what it would on a real one. Proxmox, the VMs and the sticks are fakes.
- MIT. The list of known sticks is built at install time from Home Assistant core's USB lists (Apache-2.0); the
  install needs to reach GitHub for it.
