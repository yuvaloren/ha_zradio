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
- At install a node is **initially** the primary (its sticks hold the networks and are left alone) or the standby
  (its sticks will be overwritten). The installer asks and does not guess. A standby carries the same mark from
  the install until the primary's first sync, whatever its sticks hold, so an old copy on them never reaches the
  air; a "primary" whose sticks hold no network is refused and marked, unless the house is new (`--first`).
  **Initial, because the two swap:** after the first sync either serves, so the answer is used once and kept
  (`initial-role`). The same answer on a later run changes nothing — it would otherwise mark the VM that serves
  today, or free one that a sync is filling. The installer's mark carries a line of text and zradio-sync's own is
  empty: the installer lifts only its own.
- A new VM whose synced sticks hold no network does not serve until a sync has filled them.
- A returning VM is synced once by the serving VM's next tick. Until that sync it is a standby with an older copy:
  with the election of §3a armed (`ELECTION=act`) it is held out of the claim for that time and asks for the sync at
  once; in observe mode (the default) that window is as long as it was — up to 15 minutes in which a failure of
  the serving VM puts the older copy on the air, with a Zigbee frame counter that may be behind what the devices
  have seen.
- A standby stick is silenced at boot, at every change to standby and every 15 minutes: a stick that re-enumerates
  or loses power for a moment comes back listening.
- One lock around every operation on the sticks.
- A check that can take the radios away from a VM runs in observe mode first. (2026-11-11: a first version of the
  silent-stick check could not see the sticks' answers, declared two healthy sticks hung in turn, and no VM served
  for 2 min 22 s.)

## 3a. Who serves when it is not obvious — built 2026-11-11, **off by default** (`ELECTION=observe`)

Without this, the first VM whose keepalived starts wins, and a VM that returns after a failure is an ordinary
standby from its first second, with an older copy until the next sync. Priority cannot fix that: it shortens the
claim timer by at most one second [V sandbox, keepalived 2.2.8: priority 100 started 2 s before priority 200 — the
100 served]. The rules follow DRBD's wait-for-connection and outdated peer, and Galera's "start from the most
advanced node" [source: drbd.conf(5); Galera crash recovery]. keepalived still decides who serves; `zradio-gate`
only makes `zradio-serve check` fail for a VM that should not claim yet, and asks a serving VM to hand over.

**Status.** The rules below were rehearsed with the real keepalived and this kit's real tools — `zradio-gate`'s own
loop included — in two network namespaces [V sandbox: `tests/rehearse-election.sh`, 52 checks, seven scenarios,
four runs in a row without a failure].
The sticks, ser2net, systemd, ssh and Home Assistant are stand-ins there. **Nothing of this has run on a radio VM.**
It can take the radios away from a VM, so it ships in observe mode: every decision is a `would-…` journal line and
nothing is held, raised or taken.

1. **A version that is a counter, not a clock:** `(term, used)` in `/var/lib/zradio/version`. A sync gives the
   standby the active's term with `used = no`. The term goes up by one when Home Assistant is first connected to a
   VM in a *confirmed* serving turn — when the networks really start to move on from that VM's sticks. Before it
   advances, the VM asks the peer: **it never advances past a peer that answers and is ahead** (then its turn
   becomes provisional and the peer takes the radios back). A VM that serves with no client does not advance.
2. **A VM that gives the radios up no longer claims the copy in use.** keepalived stopped (a planned switch, a
   shutdown) or the VM's own health check failed: `used` goes back to `no` at that moment (`zradio-notify`), before
   the other VM takes over. So a failover or a planned switch *stands*: the VM that gave up is level with the VM
   that took over, not ahead of it. A VM that dies hard, or is displaced by the other one when a cut link heals,
   keeps its claim — unless it then cannot serve (a stick gone): after the standard wait of a failing health check
   it gives the claim up too, so a broken VM never stands above the one that works.
3. **Wait for the peer before claiming.** At boot a VM asks the other one for its version, for up to the *standard
   wait* (`ELECTION_WAIT`, 60 s). Both up: the higher version claims at once; equal versions: the higher
   `PRIORITY`. No answer for the whole wait: it serves, provisionally.
4. **Confirmed or provisional.** A turn is provisional when the VM serves without knowing it holds the newest
   copy: nobody answered at boot, or it is outdated (rule 5). A provisional turn never advances the version. It
   becomes confirmed when the peer answers and is not ahead.
5. **An outdated VM is held, and serves only after the standard wait** (decision: Yuval, 2026-11-11). A VM that
   learns the peer's term is higher is *outdated* until a sync lands: it does not claim, so a blip of the serving
   VM never hands the radios to an older copy. It asks the serving VM for the sync as soon as that one has served
   for a minute (not at the next 15-minute tick). When the peer has not served for the standard wait, it raises
   its own Zigbee frame counter above the peer's last known one and serves provisionally.
6. **A newer copy takes the radios back — once.** A VM whose version is strictly higher than that of the VM that
   serves raises its Zigbee counter above the peer's, takes a new term, and asks the peer to hand over (the planned
   switch, without a sync from the older copy). It does so within a second of becoming a standby (`zradio-notify`
   wakes the gate at every role change), otherwise at the gate's next look (a minute when nothing is pending). The
   peer is outdated against the new term — held from the moment it hands over — until the sync has landed; then
   the versions are level and nothing preempts again. What changed on the older copy while it served (a device
   added there) is overwritten by that sync. At most one attempt in five minutes. Who can be ahead of a serving VM, given rule 2: the VM Home Assistant was using when a cut link split
   the pair; an old active that died hard and is back before the new one was used; a newer copy that returns while
   an outdated one serves provisionally.
7. A set of a lower term is refused by a standby that holds a higher one.

What the rehearsal showed [V sandbox, standard wait 20 s there; the same times, to the second, in three runs]:

| Scenario | Result |
|---|---|
| Both boot; the VM whose copy was in use boots 4 s later and has the lower priority | it serves (10 s after its own boot); the other stands by |
| The serving VM dies hard; it returns | the standby serves after 5 s and its term advances with Home Assistant connected; the returning VM is outdated and held |
| The serving VM's keepalived is gone for 6 s while the other is outdated | the outdated VM stays out; it is synced on request afterwards and the hold is lifted |
| The serving VM dies while the other is outdated | the outdated VM serves after 36 s (the wait of 20 s, the gate's pace, the counter raised, keepalived's claim), provisionally, its term unchanged; the newer VM returns and serves again 8 s after its boot; one preemption, then quiet |
| A planned switch | stands: the VM that gave the radios away released its claim first; nobody preempts |
| A cut link; Home Assistant on the lower-priority side | both serve during the cut (as before: two VMs cannot tell a cut link from a dead peer); at the heal keepalived leaves the address with the higher priority, and 4 s later the radios are back on the side Home Assistant was using |
| The same as the fourth, in observe mode | the pair behaves as before this feature (the older copy serves after 4 s, and its next sync overwrites the newer one); the journals say `would-wait`, `would-provisional`, `would-preempt`, `would-refuse` |

What it costs when armed: a VM that claims at boot serves about 10 s after its boot instead of about 4 s (the check
fails first and must pass twice); a VM that boots with nobody answering serves after the standard wait plus about
10 s; an outdated VM whose peer disappears serves after the standard wait plus up to half a minute. A failover to a
standby that is already up is as fast as before. A preemption interrupts Home Assistant like a planned switch — and
after a cut link twice: once when keepalived moves the address at the heal, once when the radios go back.

Limits and open points:

- **[H] The Zigbee counter in and after a provisional turn.** Each change of hands to a VM that was not synced in
  between is preceded by a raise of that VM's own counter by a million above the other's last known one (zigpy
  backup → raise → restore, the write path of the sync). Rehearsed on a stand-in for the coordinator only: not on a
  stick, not with devices.
- **Both VMs shut down cleanly:** both released their claim (rule 2), the versions are level, and the higher
  priority serves — with the last synced copy, as after any failover.
- **During a cut link both VMs serve**, as before: two coordinators with the same identity are on the air. This
  feature only decides which copy survives the heal. A third witness would be the textbook answer; not planned.
- **Both VMs must run the same mode.** A VM in act mode that asks a VM in observe mode to hand over is refused
  (and says so loudly every five minutes).
- Observe mode logs each VM's own decision from what it actually sees. Because nothing is held, the two VMs can
  end up where act mode would not have put them, and the lines after that point describe that other world.

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
| 1 (this) | the VM's side, one config file, detection, the "served" fallback; `host/zradio-vm` (the VM itself: cloud image, the sticks by USB mapping, the kit by cloud-init, Proxmox HA with a strict node rule) — built 2026-11-12, tested against fakes, its cloud-init file checked by cloud-init's own schema and decoder [V sandbox, cloud-init 26.2]; **not yet run on a node** | the reference pair rebuilt from this repository |
| 2 | one command with no addresses typed (proposes a free address), a pairing code instead of the two `trust` lines, switching a stopped VM's USB ports off, one ser2net per port so one stick's read does not pause the other [H] | two commands on a clean Proxmox pair |
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
