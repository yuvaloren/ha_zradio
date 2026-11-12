# How zradio works, and what is not built

Legend, used throughout this project: **[V]** measured or observed on real hardware, with what it was measured on ·
**[source]** read in upstream code or documentation, not run here · **[H]** an estimate or a design idea, unproven ·
**[?]** to check before building on it.

The reference pair: two Proxmox VE 9 nodes; per node an Aeotec Z-Stick 10 Pro (Z-Wave 800 series, SDK 7.23) and a
Sonoff ZBDongle-P (CC2652P, Z-Stack); Home Assistant OS with Z-Wave JS UI and ZHA; live since 2026-11-11 on the
scripts this kit was extracted from.

## 1. The pieces

| Piece | What it is | Standard part | The kit's part |
|---|---|---|---|
| A radio VM per node | Debian, the node's sticks passed through | Proxmox VM, USB passthrough | `guest/install.sh` |
| Serving a stick | a raw TCP port per stick on the floating address | ser2net | the rendered config |
| Who serves | one floating address, held by one VM | keepalived (VRRP, unicast) | the health check and the role script |
| A silent standby | the standby's sticks hold the networks and say nothing | — | `zradio-serve down / hush` |
| A synced standby | the standby's sticks are a copy of the active's | zigpy (Zigbee), zwave-js (Z-Wave) | `zradio-sync`, `zradio-apply` |
| Knowing the sticks | which stick is what | Home Assistant's USB lists | `zradio-detect`, the probe |

Home Assistant connects to `tcp://VIP:6639` (Z-Wave JS) and `socket://VIP:6638` (ZHA) and is not otherwise involved.

## 2. Roles

Both VMs run keepalived with `state BACKUP` and `nopreempt`: whoever holds the address keeps it until it stops, dies
or fails its health check; a VM that comes back stays the standby.

- **Serving** (`zradio-serve up`, started by keepalived's notify on MASTER): the Z-Wave receiver on, then ser2net.
- **Standing by** (`zradio-serve down`): ser2net stopped; the Z-Wave receiver **off** (SetRFReceiveMode); the Zigbee
  coordinator **reset**, which leaves a Z-Stack coordinator off the air until a host starts it.
- **Health** (`zradio-serve check`, every 3 s): fails when a stick's tty is gone, when a synced set is half written,
  when a stick was declared hung, or shortly after a failed attempt to serve.

Why a standby must be silent [V]: a powered Z-Wave stick that holds the live home ID and has no driver still receives
the mesh and acknowledges frames addressed to the controller (357 bytes of mesh traffic in 25 s with the receiver on,
0 with it off); with a copy listening, 2 of 121 routed commands on the live mesh took 14–16 s. A second Zigbee
coordinator of the same network on the air is worse.

## 3. The sync

Triggers: nightly; 15 minutes after the serving VM changed (once per turn); five quiet minutes after a device was
added or removed (noticed in the packets Home Assistant sends to the sticks' ports — the watcher never connects to
them); and a 15-minute catch-up tick with back-off after a failure.

1. The active asks the standby whether it is there and not serving. No answer: nothing is read, no pause.
2. The active stops ser2net and reads both sticks at once: Z-Wave receiver off → NVM read → receiver on; zigpy's
   backup of the coordinator. ser2net starts again. [V: 6.7 s and 11.7 s; Home Assistant's Z-Wave is back after
   about 14 s, Zigbee after 26–28 s.]
3. The set goes to the standby over ssh (one key, one forced command, the peer's host key pinned). The standby
   checks it (hashes, identities, not older than what it holds), marks itself *not ready*, writes it — Z-Wave in two
   passes through a local Z-Wave JS UI container (a converting restore gives the stick the home ID and node table; a
   raw one repairs the RF configuration the first can damage), Zigbee with zigpy's restore — verifies both sticks by
   reading them back, silences them, clears the mark and answers `SYNCED`. [V: 90–97 s.]
4. The Zigbee frame counter on the copy is the active's reading plus 1,000,000 [V: the reference network's counter
   grows 20–30 thousand a day], so a standby that takes over never sends a counter the devices have already seen.

Rails, each from something that went wrong or nearly did:

- A VM never serves a stick set that was not written to the end (a mark on disk, set before the first write).
- A new VM whose synced sticks hold no network does not serve until a sync has filled them.
- A returning VM is synced once by the serving VM's next tick. **Gap, until §3a is built:** until that sync (up to
  15 minutes) the returning VM is a standby with an older copy — if the serving VM failed in that window, the older
  copy would serve at once, with a Zigbee frame counter that may be behind what the devices have seen.
- A standby stick is silenced at boot, at every change to standby and every 15 minutes: a stick that re-enumerates
  or loses power for a moment comes back listening.
- One lock around every operation on the sticks.
- A check that can take the radios away from a VM runs in observe mode first. (2026-11-11: a first version of the
  silent-stick check could not see the sticks' answers, declared two healthy sticks hung in turn, and no VM served
  for 2 min 22 s.)

## 3a. Who serves when it is not obvious — decided 2026-11-11, **not built yet**

Today the first VM whose keepalived starts wins, and a VM that returns after a failure is an ordinary standby from
its first second, with an older copy until the next sync. Priority cannot fix that: it shortens the claim timer by
at most one second [V sandbox, keepalived 2.2.8: priority 100 started 2 s before priority 200 — the 100 served].
The decided behaviour, after DRBD's wait-for-connection and outdated peer, and Galera's "start from the most
advanced node" [source: drbd.conf(5); Galera crash recovery]:

1. **A version that is a counter, not a clock:** `(term, used)`. A sync gives the standby the active's term with
   `used = no`. The term goes up by one when Home Assistant first connects to a VM in a serving turn that is
   *confirmed* (rule 3) — that is, when the network really starts to move on from that VM's sticks. A VM that serves
   with no client (a cut link, with Home Assistant on the other side) does not advance.
2. **Wait for the peer before claiming.** At boot a VM asks the other one for its version, for up to the *standard
   wait* (60 s). Both up: the higher version serves; equal versions: the configured priority. No answer: it serves.
3. **Confirmed or provisional.** A turn is confirmed when the VM knew, from the peer itself, that nobody was ahead
   of it: a clean, in-sync standby taking over, or a boot comparison it won. A VM that serves because nobody
   answered serves *provisionally*: its version does not advance.
4. **An outdated VM serves after the standard wait, not after 4 seconds** (decision: Yuval, 2026-11-11). A VM that
   knows the peer's term is higher is outdated until a sync lands. If the peer falls silent it waits the standard
   wait, then serves provisionally — a short blip of the serving VM never hands the radios to an older copy.
5. **A more advanced VM preempts — once.** When a VM with a strictly higher version finds the other one serving,
   it asks it to hand over (the planned-switch mechanism) and then syncs it. Nothing else ever preempts, and after
   the sync the versions are equal, so this cannot oscillate. What changed on the less advanced VM while it served
   (a device added there) is overwritten by that sync.
6. The serving VM syncs a returning peer as soon as it sees it, not at the next 15-minute tick.

Open, to settle while building:

- **[H] Zigbee in and after a provisional turn.** An older copy's frame counter may be below what the devices have
  already seen, and after it served, the returning VM's counter may be below *its*. Each such change of hands
  probably needs the taker to raise its own stick's counter first (zigpy backup → raise → restore, the proven write
  path, inside the wait). Not measured.
- Two nodes cannot tell a dead peer from a cut link; rule 1's "used" is what keeps a cut link from picking the wrong
  side afterwards. A third witness would be the textbook answer and is not planned.
- Everything here can take the radios away from a VM: it goes onto real VMs in observe mode first.

## 4. Recognising the radios

1. **The list**: USB vendor:product, product string and port number, looked up in `guest/lib/usb-ids.json` —
   Home Assistant's own USB lists for ZHA, Z-Wave JS and its Connect hardware [source], plus this project's
   annotations (`tools/usb-annotations.json`: family, serial settings, which port of a two-port adapter). The list
   gives a hint.
2. **The probe**, read-only: Z-Wave Serial API identification [V on the reference stick]; TI ZNP version and
   network state [V]. A port the list names gets its own protocol's probe only (so the reference sticks never see
   the other protocol's bytes). A port with no hint gets both in turn; that a stick ignores the first bytes of a
   protocol it does not speak is **[H]** — expected from both framings (checksummed, distinct start bytes), tried
   on no stick.
3. **The level**: `synced` for a Z-Wave 800 series chip [source: zwave-js's chip table] and for ZNP; `served` for
   everything else. EZSP, deCONZ and ZiGate sticks are recognised from the list alone and never sent anything: the
   kit has no probe for them yet.

Limits today: one stick per kind per VM. The families and serial settings in the annotations are from public
documentation and **not verified on hardware** unless marked proven (two entries).

## 5. What is not built

| Phase | Content | Proves |
|---|---|---|
| 1 (this) | the VM's side, one config file, detection, the "served" fallback | the reference pair rebuilt from this repository |
| 2 | a Proxmox helper script per node (creates the VM, passes the sticks through, proposes a free address), a pairing code instead of the two `trust` lines, one ser2net per port so one stick's read does not pause the other [H] | two commands on a clean Proxmox pair |
| 3 | a Home Assistant integration (HACS): status, "sync now", "switch", repair notices; a sync that reads through Home Assistant's own backup APIs, without the pause [H]; device add/remove events instead of the packet watcher | the pause gone; no separate monitoring needed |
| 4 | more families synced (EZSP first), Zigbee2MQTT, a hardware table filled by reports | a wide variety of setups |

Decisions taken:

- A VM, not a container (Proxmox manages it; USB hot-plug and device permissions differ least between setups).
- keepalived always decides who serves — Home Assistant may ask for a switch, never decide one.
- **Each radio VM is a Proxmox HA resource, restricted to its own node by a strict node-affinity rule** (2026-11-11).
  Proxmox restarts a radio VM that dies and never moves it: on the other node it would be handed that node's sticks,
  which the other radio VM holds. This is the stock mechanism for a guest whose device passthrough exists on a subset
  of nodes [source: ha-manager(1), PVE 9.2: "restrict the HA resource to that subset with a strict node affinity
  rule"; "if none of the defined nodes are available, the resource will be stopped"]. A plain VM with `onboot` — what
  the reference pair ran on its first day — is started only when its node boots: a crashed VM stayed down until
  someone noticed. Restart-in-place under such a rule is **[H]** here until drilled.

Open questions:

- [?] Can zwave-js restore an NVM without a running driver on the target stick's network? (The container exists
  because it starts one.)
- [?] What ZHA needs in a `_zigbee-coordinator._tcp` announcement to offer setup, and whether it follows an address
  that moves.
- [?] EZSP: is a coordinator silent after a reset? zigpy's tool warns that its address can be written only once.
- [?] Z-Wave 700 and 500 series: SetRFReceiveMode and the two-pass restore behave as on 800? Unknown.
- [?] What Home Assistant does when a takeover hands it a *blank* served-only stick (the expected answer: a repair
  notice offering a restore; not tried).
