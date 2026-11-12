#!/usr/bin/env python3
"""zradio-probe.py — identify a Z-Wave / Zigbee USB stick, read-only: a Z-Wave controller (Silicon Labs Serial API) and a
TI Z-Stack coordinator (ZNP, the Monitor and Test API). A few single-purpose writes exist behind their own flags (below);
with --wipe (only), a stick that holds a named network is blanked. Stdlib only (Python >= 3.9).

    zradio-probe.py --zwave /dev/zradio-zwave --zigbee /dev/zradio-zigbee          # the ttys directly (nothing else open)
    zradio-probe.py --zwave tcp://127.0.0.1:16639 --zigbee tcp://127.0.0.1:16638   # through a ser2net port
    ... --json                                                                     # JSON on stdout, the human lines on stderr
    zradio-probe.py --wipe --zwave TTY --zigbee TTY --expect-zwave-home-id N --expect-zigbee-ieee XX:… --expect-zigbee-extpan XX:…   # see "The wipe"

Who runs it: zradio-detect (which stick is what), zradio-serve (--rf-receive on|off, --zigbee-reset: the two ways a
standby stick is kept silent), zradio-sync (--nvm-dump: the Z-Wave half of a sync's read) and zradio-apply (--soft-reset
and the reads that verify a written set). Without one of those flags or --wipe it never changes a stick: every command
it can send is in ZW_READ_ONLY / ZNP_READ_ONLY below, and the send functions refuse anything else. The WRITE commands
(ZW_WIPE, ZNP_WIPE and the AREQ SYS_RESET_REQ, with the exact NV items and value zigpy-znp uses) exist only behind
--wipe: every write path checks it before a byte is sent. --wipe opens LOCAL ttys only — a tcp:// port with --wipe is a
usage error: once a network is copied, the live stick and its copy answer the same identities, and through a network
port only the host would tell them apart; this tool has no host checks of its own, so it refuses the transport instead.

The wipe (for a stick that holds a copy of a network and must hold none: a retired stick, or the standby stick of a
"served only" family). Every radio given is first probed READ-ONLY, as without --wipe, and classified:
  Z-Wave  home ID = --expect-zwave-home-id → the stale copy: wipe · the node list holds only its own node (and another
          home ID) → blank already: skip · anything else (another network, no answer) → refuse
  Zigbee  on a network AND IEEE = --expect-zigbee-ieee → the stale copy: wipe · not on a network, not running as a
          coordinator, and NV EXTENDED_PAN_ID ≠ --expect-zigbee-extpan → blank: skip · not on a network but STILL running
          as that IEEE, or not running while NV still holds the network's extended PAN (a wipe that stopped between the
          deletes and the reset) → the stale copy: wipe again · anything else (another coordinator on a
          network, "unknown", no answer) → refuse
One refusal → nothing is written to ANY stick (exit 3). Then, Z-Wave first, each stale stick is wiped exactly as its
upstream driver does it — nothing more — and probed again (read-only); the first failure stops (exit 1), the other
stick untouched, and the result says what state the failed one may be in:
  Z-Wave (zwave-js v15.29.0, the driver of HA's Z-Wave JS UI 11.24.1): Driver.ts L3769-3802 hardReset() →
          Controller.ts L1984-2019 hardReset() → `HardResetRequest` (serial/src/serialapi/capability/HardResetRequest.ts
          L31-37: REQUEST, FUNC 0x42 = FunctionType.HardReset "Reset controller and node info to default (original)
          values", message/Constants.ts L91; payload = [callback id]; @expectedCallback(HardReset)). One frame is on the
          wire at a time: zwave-js re-sends it when no ACK arrives within 1600 ms, at most attempts.controller = 3 times
          (Driver.ts L6978-6989: isMissingControllerACK → continue attemptMessage; mayRetrySerialAPICommand at L7128
          covers the OTHER errors, not this one), and never on NAK/CAN — those become Controller_MessageDropped
          (StateMachineShared.ts) and the loop gives up. This tool sends it ONCE: a lost ACK is a FAIL whose re-probe
          decides the state. It awaits its ACK within 1600 ms (Driver.ts L327), then the callback — a
          REQUEST 0x42 whose callback id matches (Message.ts L382-395) — within
          30 s (Driver.ts L7316-7317: getCallbackTimeout() ?? timeouts.sendDataCallback = 30000, L335). The callback id
          is 1: a session's first (Driver.ts L6446 createWrappingCounter(0xff), shared/src/wrappingCounter.ts: starts at
          1). After it zwave-js destroys its controller object and interviews the stick again (Driver.ts L3800-3801
          initializeControllerAndNodes: GetSerialApiCapabilities, … — reads, then its normal start-up: the RF config, the
          NIF, a soft reset, for any driver start); a 700/800 stick may restart its Serial API (SerialAPIStarted 0x0A,
          handled by Driver.ts L5465 handleSerialAPIStartedUnexpectedly): ACKed and noted (this tool only listens for it
          for 1 s after the callback; nothing is sent). Here the "interview" is the read-only probe again: blank = a home
          ID ≠ the network's AND only its own node.
          NOT sent (decided): Driver.ts L3796 setControllerNIF() before the reset (a driver set-up write that
          zwave-js repeats at every start, L2089) and Controller.ts L1999 sendResetLocallyNotification() to the
          controller's associated nodes (from zwave-js's own cache, not the stick; sent from THIS stale stick it would
          reach the live network's nodes, which now answer to the live controller with the same home ID).
  Zigbee  (zigpy-znp 1.1.0, ZHA's in HA 2026.9.3: zha 2.2.2 pins zigpy-znp==1.1.0; zigpy-cli `zigpy radio znp <port>
          reset` = radio.py L162-164 app.connect() + app.reset_network_info(), then radio_cleanup L78-80 app.shutdown()):
          zigbee/application.py L112-117 → api.py L327-344 ZNP.reset_network_info(): nvram.py L84-98 osal_delete() of
          HAS_CONFIGURED_ZSTACK1 0x0F00, HAS_CONFIGURED_ZSTACK3 0x0060, ZIGPY_ZNP_MIGRATION_ID 0x005F, BDBNODEISONANETWORK
          0x0055 in that order (each: SYS_OSAL_NV_LENGTH 0x21 0x13; 0 = absent, skipped; else SYS_OSAL_NV_DELETE 0x21 0x12
          with that length — its status is returned and ignored by reset_network_info); nvram.py L100-146 osal_write()
          of STARTUP_OPTION 0x0003 = ClearState|ClearConfig (types/named.py L349-353: 0x02|0x01 = 0x03): NV_LENGTH must
          be 1 (else KeyError/ValueError, L109-121), then SYS_OSAL_NV_WRITE_EXT 0x21 0x1D (id u16, offset u16 0, value
          LongBytes [0x03]) answering SUCCESS (L139-146); then api.py L628-638 reset(): the AREQ SYS_RESET_REQ 0x41 0x00
          Type=Soft (0x01; commands/sys.py L87-105, named.py L339-341) and its SYS_RESET_IND 0x41 0x80 (L609-620) awaited
          ≤ 30 s (request_callback_rsp, config.py L99 async_response_timeout 30); then zigpy-cli's cleanup: zigpy
          application.py L579-602 shutdown() → zigbee/application.py L74-79 disconnect() → reset(wait_for_reset=False):
          one more SYS_RESET_REQ soft, not awaited. SREQs are sent once, ≤ 15 s each (ZNP.request: no retry,
          config.py L98 sync_request_timeout 15). Z-Stack clears its network state and configuration at that boot; the
          IEEE stays the chip's own (a zigpy restore writes the network's coordinator IEEE onto the OTHER stick, not this
          one — here it is the network's only when the network was formed on this stick [H]). Blank = not on a network
          (zigpy-znp's own rule), not running as a coordinator (device state 0x08/0x09: a ZNP holds after a reset
          until a host starts it [H], so a running one was started from its NV — not cleared) and, when
          --expect-zigbee-extpan is given, NV EXTENDED_PAN_ID ≠ the network's (the four deletes leave
          it alone and Z-Stack clears it only at the boot STARTUP_OPTION requests).

Z-Wave (Serial API; zwave-js 15.29.0 is the reference read here — packages/serial/src/message/{Message,MessageHeaders,
Constants}.ts, packages/serial/src/serialapi/{memory,capability}/*Messages.ts, packages/zwave-js/src/lib/driver/Driver.ts):
  frame  SOF 0x01, LEN (= payload + 3: TYPE, FUNC, CHECKSUM), TYPE 0x00 request / 0x01 response, FUNC, payload,
         CHECKSUM = 0xFF XOR every byte from LEN through the payload (Message.ts computeChecksum)
  flow   the host ACKs (0x06) every valid frame it receives and NAKs (0x15) one whose checksum is wrong (Driver.ts
         handleDecodeError); a request the controller answers with NAK/CAN, or does not ACK within 1600 ms (Driver.ts
         timeouts.ack, "A sending interface MUST wait for 1600ms or more"), is sent again — 3 attempts in all
         (attempts.controller = 3), 100 ms + 1000 ms x (attempt - 1) apart [H: the Host API spec's back-off, INS12350,
         not re-read here]. A REQUEST frame from the controller while we wait (a callback: a node's report, SerialAPIStarted)
         is ACKed and otherwise ignored.
  start  one NAK first, as zwave-js does to reset the communication on Serial API startup (Driver.ts detectMode)
  reads  0x20 GetControllerId  → home ID (u32 BE) + own node ID (1 byte, or 2 in 16-bit node-ID mode: told by the length)
         0x02 GetSerialApiInitData → API version, capabilities, 29-byte node bitmask (bit i of byte j = node 8j+i+1), chip
         0x07 GetSerialApiCapabilities → firmware x.y, manufacturer/product type/product id (u16 BE), function bitmask
         0x09 GetProtocolVersion (700/800 series: type, major, minor, patch → "7.23.2") when the bitmask lists it,
         else 0x15 GetControllerVersion ("Z-Wave 7.23\0" + library type) as the fallback.
         NOTE: 0x28 is sometimes named for GetProtocolVersion; it is ZW_NVRGetValue in zwave-js's FunctionType
         table ("UNKNOWN_FUNC_UNKNOWN_0x28 = 0x28, // ZW_NVRGetValue(offset, length)") — 0x09 is GetProtocolVersion.
  verdict blank = the classic node list holds only the controller's own node [H: Long Range nodes are not in that list
         (zwave-js reads them with 0xDA GetLongRangeNodes, not sent here); a blank stick has none].

Zigbee (Z-Stack MT / ZNP; zigpy-znp 0.14.3 is the reference read here — zigpy_znp/frames.py, types/commands.py,
commands/{sys,util,ubl}.py, types/nvids.py, api.py, nvram.py):
  frame  SOF 0xFE, LEN (payload only), CMD0 = type << 5 | subsystem, CMD1 = command id, payload,
         FCS = XOR of LEN, CMD0, CMD1 and the payload (frames.py TransportFrame.checksum)
  types  SREQ 0x20 | sub, answered by SRSP 0x60 | sub; AREQ 0x40 | sub = an unsolicited indication, ignored;
         an SRSP 0x60 0x00 is the RPC error "command not recognized" (ErrorCode, the request's CMD0, CMD1)
  start  the bootloader-skip byte 0xEF (zigpy-znp ubl.py: BootloaderRunMode.FORCE_RUN = FORCE_BOOT 0x10 ^ 0xFF; zigbee-
         herdsman writes the same single byte and waits 1 s), wait 1 s, discard what came in. A running Z-Stack drops it
         (the MT parser skips bytes until a SOF). zigpy-znp ALSO toggles RTS/DTR to reset the CC2652 (api.py
         _skip_bootloader); through raw ser2net there are no modem lines to toggle — neither here nor for ZHA's socket://
         [H: the Sonoff's reset/bootloader lines stay quiet through ser2net (nobreak,local)]
  reads  SYS_PING 0x21 0x01 → capabilities (u16 LE)
         SYS_VERSION 0x21 0x02 → transport, product, major, minor, maint [, code revision u32 LE, bootloader type, rev]
         UTIL_GET_DEVICE_INFO 0x27 0x00 → status, IEEE (8 bytes LE, printed MSB first as 00:12:4b:…), short address,
           device type, device state [, associated devices]
         SYS_OSAL_NV_LENGTH 0x21 0x13 (id u16 LE) → item length u16 LE (commands/sys.py OSALNVLength: "A returned length
           of zero indicates that the NV item does not exist"), then SYS_OSAL_NV_READ 0x21 0x08 (id u16 LE, offset u8) →
           status, length, value — of item 0x0055 BDBNODEISONANETWORK (types/nvids.py)
  verdict (zigpy-znp's own rule, re-read from github.com/zigpy/zigpy-znp dev — nvram.py
         osal_read: length 0 → KeyError "NV item does not exist"; the read must answer SUCCESS (RspStatus=SUCCESS: any
         other status raises, INVALID_PARAMETER as a SecurityError); api.py load_network_info: a KeyError → NetworkNotFormed;
         _load_network_info: BDBNODEISONANETWORK != 1 → NetworkNotFormed):
         blank   = not on a network: the item does not exist (length 0), or it reads with status 0 and a value != 0x01
         live    = on a network: status 0, value 0x01
         unknown = anything else — the read answered a non-zero status (types/named.py Status: 0x02 INVALID_PARAMETER,
                   0x0A NV_OPER_FAILED, …) or a short answer: NOT blank
         The device state (UTIL_GET_DEVICE_INFO) is printed beside it (StartedAsCoordinator = 0x09 on a formed network).

Exit: 0 every radio asked for answered its mandatory reads; 1 one did not (or a tty is locked by someone else); 2 usage.
--wipe: 0 every radio wiped (and re-probed blank) or blank already; 1 a wipe failed (the other untouched); 3 refused —
nothing was written to any stick. Times are bounded: --timeout per command (default 5 s), --budget per radio and phase
(default 45 s), --connect-timeout (5 s); the wipe's own waits are the drivers' (above), --reset-timeout overrides the
callback / SYS_RESET_IND bound (default 30 s).
"""
from __future__ import annotations

import argparse
import hashlib
import errno
import fcntl
import json
import os
import select
import socket
import sys
import termios
import time

ZW_SOF, ZW_ACK, ZW_NAK, ZW_CAN = 0x01, 0x06, 0x15, 0x18   # MessageHeaders.ts
ZW_REQUEST, ZW_RESPONSE = 0x00, 0x01                      # MessageType
ZW_GET_INIT_DATA = 0x02            # FunctionType.GetSerialApiInitData
ZW_GET_CAPABILITIES = 0x07         # FunctionType.GetSerialApiCapabilities
ZW_GET_PROTOCOL_VERSION = 0x09     # FunctionType.GetProtocolVersion ("700 series")
ZW_GET_CONTROLLER_VERSION = 0x15   # FunctionType.GetControllerVersion
ZW_GET_CONTROLLER_ID = 0x20        # FunctionType.GetControllerId ("Get Home ID and Controller Node ID")
ZW_SERIAL_API_SETUP = 0x0B         # FunctionType.SerialAPISetup: sub-commands; only the GET ones below are ever sent
ZW_SETUP_GET_SUPPORTED = 0x01      # SerialAPISetupCommand.GetSupportedCommands  (zwave-js SerialAPISetupMessages.ts)
ZW_SETUP_GET_POWERLEVEL = 0x08     # SerialAPISetupCommand.GetPowerlevel → [sub, powerlevel int8 dBm, measured0dBm int8]
ZW_SETUP_GET_POWERLEVEL16 = 0x13   # SerialAPISetupCommand.GetPowerlevel16Bit → [sub, int16 BE 0.1 dBm, int16 BE 0.1 dBm] — the
                                   # 7.x firmware answers 0x08 with 0x7f (= "use the 16-bit one") [V a 7.23.2 stick 2026-10-29]
ZW_SETUP_GET_RF_REGION = 0x20      # SerialAPISetupCommand.GetRFRegion  → [sub, region]  (9 = USA Long Range)
ZW_SETUP_GETS = {ZW_SETUP_GET_SUPPORTED, ZW_SETUP_GET_POWERLEVEL, ZW_SETUP_GET_POWERLEVEL16, ZW_SETUP_GET_RF_REGION}   # SetRFRegion 0x40 / SetPowerlevel 0x04: never
ZW_RF_REGIONS = {0: "Europe", 1: "USA", 2: "Australia/New Zealand", 3: "Hong Kong", 5: "India", 6: "Israel", 7: "Russia",
                 8: "China", 9: "USA (Long Range)", 11: "Europe (Long Range)", 32: "Japan", 33: "Korea", 254: "Unknown",
                 255: "Default (EU)"}   # zwave-js RFRegion enum (core/src/definitions/RFRegion.ts), the driver's names
ZW_NVM_OPS = 0x2E                  # FunctionType.NVMOperations (700+): [cmd, length, offset u16, data…] — Open 0 / Read 1 / Write 2 / Close 3
ZW_NVM_OPS_EXT = 0x3D              # FunctionType.ExtendedNVMOperations: the same with a u32 offset [V zwave-js serial/message/Constants.ts, nvm/*Messages.ts 2026-10-29]
ZW_NVM_OPEN, ZW_NVM_READ, ZW_NVM_WRITE, ZW_NVM_CLOSE = 0x00, 0x01, 0x02, 0x03
ZW_NVM_STATUS = {0x00: "OK", 0x01: "Error", 0x02: "OperationMismatch", 0x03: "OperationInterference", 0x04: "SubCommandNotSupported", 0xFF: "EndOfFile"}
ZW_READ_ONLY = {ZW_GET_INIT_DATA, ZW_GET_CAPABILITIES, ZW_GET_PROTOCOL_VERSION, ZW_GET_CONTROLLER_VERSION, ZW_GET_CONTROLLER_ID,
                ZW_SERIAL_API_SETUP, ZW_NVM_OPS, ZW_NVM_OPS_EXT}   # the NVM functions: Open/Read/Close only (nvm_dump guards the sub-command)
ZW_SOFT_RESET = 0x08               # FunctionType.SoftReset (SerialAPI "soft reset": the controller restarts and reloads its NVM;
                                   # zwave-js Driver.softReset — what activates a restored NVM image, Controller.ts restoreNVMRaw's
                                   # comment [V read 2026-10-29]). A WRITE of its own kind (a restart, no data): --soft-reset only
ZW_HARD_RESET = 0x42               # FunctionType.HardReset (zwave-js message/Constants.ts L91) — a WRITE: --wipe only
ZW_SET_RF_RECEIVE_MODE = 0x10      # FunctionType.SetRFReceiveMode (zwave-js SetRFReceiveModeMessages.ts: REQUEST [enabled 0|1] →
                                   # RESPONSE [success]; Driver.toggleRF — what zwave-js sends around an NVM restore). The
                                   # receiver off = the stick ACKs nothing on the air (a powered copy goes quiet): --rf-receive only
ZW_SERIAL_API_STARTED = 0x0A       # FunctionType.SerialAPIStarted (Constants.ts L29): sent by the stick after a restart
ZW_WIPE = {ZW_HARD_RESET}          # the only Z-Wave write this tool can send (with --wipe)
ZW_CALLBACK_TIMEOUT = 30.0         # Driver.ts L335 timeouts.sendDataCallback: the callback wait (L7316-7317)
ZW_NODEMASK_BYTES = 29             # NUM_NODEMASK_BYTES: "Controller Nodes MUST set this field to 29"
ZW_ACK_TIMEOUT = 1.6               # Driver.ts timeouts.ack (1600 ms)
ZW_ATTEMPTS = 3                    # Driver.ts attempts.controller
ZW_BUSY_ATTEMPTS = 6               # this tool's own sends (SoftReset, SetRFReceiveMode) on a stick busy with the mesh's frames

MT_SOF = 0xFE                      # frames.py TransportFrame.SOF
MT_SREQ, MT_AREQ, MT_SRSP = 0x20, 0x40, 0x60   # CommandType SREQ=1, AREQ=2, SRSP=3, shifted into CMD0's top 3 bits
MT_SYS, MT_UTIL, MT_RPC = 0x01, 0x07, 0x00     # Subsystem.SYS, Subsystem.UTIL, Subsystem.RPCError
MT_SKIP_BOOTLOADER = 0xEF          # ubl.py BootloaderRunMode.FORCE_RUN
ZNP_SYS_PING, ZNP_SYS_VERSION, ZNP_SYS_OSAL_NV_READ, ZNP_SYS_OSAL_NV_LENGTH = 0x01, 0x02, 0x08, 0x13   # commands/sys.py
ZNP_UTIL_GET_DEVICE_INFO = 0x00                                       # commands/util.py
ZNP_READ_ONLY = {(MT_SYS, ZNP_SYS_PING), (MT_SYS, ZNP_SYS_VERSION), (MT_SYS, ZNP_SYS_OSAL_NV_READ), (MT_SYS, ZNP_SYS_OSAL_NV_LENGTH),
                 (MT_UTIL, ZNP_UTIL_GET_DEVICE_INFO)}
NV_BDBNODEISONANETWORK = 0x0055    # types/nvids.py OsalNvIds.BDBNODEISONANETWORK ("bdbNodeIsOnANetwork attribute")
NV_EXT_PAN_ID = 0x002D             # types/nvids.py OsalNvIds.EXTENDED_PAN_ID — read-only on the wipe path: an interrupted
                                   # wipe (deletes done, no STARTUP_OPTION write, no reset) leaves the network's value here
# the wipe (zigpy-znp 1.1.0 api.py L327-344 reset_network_info; the WRITE commands — --wipe only, these items only)
ZNP_SYS_OSAL_NV_DELETE, ZNP_SYS_OSAL_NV_WRITE_EXT = 0x12, 0x1D                      # commands/sys.py L258-266, L487-500
ZNP_SYS_RESET_REQ, ZNP_SYS_RESET_IND = 0x00, 0x80                                  # AREQs: commands/sys.py L87-105, L609-620
ZNP_WIPE = {(MT_SYS, ZNP_SYS_OSAL_NV_DELETE), (MT_SYS, ZNP_SYS_OSAL_NV_WRITE_EXT)}  # the SREQ writes (+ the AREQ reset)
NV_HAS_CONFIGURED_ZSTACK1, NV_HAS_CONFIGURED_ZSTACK3, NV_ZIGPY_ZNP_MIGRATION_ID, NV_STARTUP_OPTION = 0x0F00, 0x0060, 0x005F, 0x0003  # nvids.py L40-50
ZNP_WIPE_DELETE_IDS = (NV_HAS_CONFIGURED_ZSTACK1, NV_HAS_CONFIGURED_ZSTACK3, NV_ZIGPY_ZNP_MIGRATION_ID, NV_BDBNODEISONANETWORK)   # its order
STARTUP_CLEAR = 0x03               # StartupOptions.ClearState (1 << 1) | ClearConfig (1 << 0): types/named.py L349-353
RESET_SOFT = 0x01                  # ResetType.Soft (named.py L339-341)
ZNP_WRITE_TIMEOUT = 15.0           # config.py L98 sync_request_timeout: an SREQ's SRSP (ZNP.request: sent once)
ZNP_ARSP_TIMEOUT = 30.0            # config.py L99 async_response_timeout: request_callback_rsp's bound (the SYS_RESET_IND)
ZNP_RUNNING_STATES = {0x08, 0x09}   # StartingAsCoordinator, StartedAsCoordinator (types/commands.py DeviceState)
ZNP_DEVICE_STATES = {               # types/commands.py DeviceState
    0x00: "InitializedNotStarted", 0x01: "InitializedNotConnected", 0x02: "DiscoveringPANs", 0x03: "Joining",
    0x04: "ReJoiningSecureScanningCurrentChannel", 0x05: "JoinedNotAuthenticated", 0x06: "JoinedAsEndDevice",
    0x07: "JoinedAsRouter", 0x08: "StartingAsCoordinator", 0x09: "StartedAsCoordinator", 0x0A: "LostParent",
    0x0B: "SendingKeepAliveToParent", 0x0C: "BackoffBeforeRejoin", 0x0D: "RejoinSecureScanningAllChannels",
    0x0E: "RejoinInsecureScanningCurrentChannel", 0x0F: "RejoinInsecureScanningAllChannels"}


class ProbeError(Exception):
    pass


class Budget:
    """An overall deadline for one radio; every wait is the smaller of its own timeout and what is left."""

    def __init__(self, seconds: float):
        self.end = time.monotonic() + seconds

    def until(self, seconds: float) -> float:
        return min(time.monotonic() + seconds, self.end)

    def spent(self) -> bool:
        return time.monotonic() >= self.end


class Link:
    """A byte stream to a stick: a tty path (raw 115200 8N1, flock'd) or tcp://host:port (ser2net's raw accepter)."""

    def __init__(self, spec: str, connect_timeout: float):
        self.spec = spec
        self.sock = None
        if spec.startswith("tcp://"):
            host, _, port = spec[len("tcp://"):].rpartition(":")
            if not host or not port.isdigit():
                raise ProbeError(f"cannot read {spec!r} (want tcp://host:port)")
            try:
                self.sock = socket.create_connection((host.strip("[]"), int(port)), timeout=connect_timeout)
            except OSError as e:
                raise ProbeError(f"connect {spec}: {e}") from None
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.sock.setblocking(False)
            self.fd = self.sock.fileno()
        else:
            try:
                self.fd = os.open(spec, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            except OSError as e:
                raise ProbeError(f"open {spec}: {e.strerror}") from None
            try:   # never share a stick with a running ser2net/ZHA/zwave-js (ser2net's serialdev flocks it too: gensio flock=true)
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(self.fd)
                raise ProbeError(f"{spec} is locked by another process — not touching it") from None
            try:
                a = termios.tcgetattr(self.fd)
                a[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP | termios.INLCR
                          | termios.IGNCR | termios.ICRNL | termios.IXON | termios.IXOFF | termios.IXANY)
                a[1] &= ~termios.OPOST
                a[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | getattr(termios, "CRTSCTS", 0))
                a[2] |= termios.CS8 | termios.CREAD | termios.CLOCAL
                a[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
                a[4] = a[5] = termios.B115200
                a[6][termios.VMIN] = 0
                a[6][termios.VTIME] = 0
                termios.tcsetattr(self.fd, termios.TCSANOW, a)
                termios.tcflush(self.fd, termios.TCIOFLUSH)
            except termios.error as e:
                os.close(self.fd)
                raise ProbeError(f"{spec}: not a serial port ({e})") from None

    def write(self, data: bytes, deadline: float) -> None:
        view = memoryview(data)
        while view:
            left = deadline - time.monotonic()
            if left <= 0:
                raise ProbeError(f"{self.spec}: write timed out")
            _, w, _ = select.select([], [self.fd], [], left)
            if not w:
                continue
            try:
                n = self.sock.send(view) if self.sock else os.write(self.fd, view)
            except BlockingIOError:
                continue
            except OSError as e:
                raise ProbeError(f"{self.spec}: write failed: {e}") from None
            view = view[n:]

    def read_some(self, deadline: float) -> bytes:
        """Bytes that arrive before the deadline (b'' on timeout); the far end closing is an error."""
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return b""
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return b""
            try:
                chunk = self.sock.recv(4096) if self.sock else os.read(self.fd, 4096)
            except BlockingIOError:
                continue
            except OSError as e:
                if e.errno == errno.EIO:
                    raise ProbeError(f"{self.spec}: I/O error (the device went away?)") from None
                raise ProbeError(f"{self.spec}: read failed: {e}") from None
            if not chunk:
                raise ProbeError(f"{self.spec}: the far end closed the connection"
                                 + (" (ser2net could not open the device?)" if self.sock else ""))
            return chunk

    def drain(self, quiet: float, limit: float) -> int:
        """Discard input until nothing arrived for `quiet` seconds (at most `limit` seconds); the count discarded."""
        end, n = time.monotonic() + limit, 0
        while time.monotonic() < end:
            chunk = self.read_some(min(time.monotonic() + quiet, end))
            if not chunk:
                break
            n += len(chunk)
        return n

    def close(self) -> None:
        try:
            if self.sock:
                self.sock.close()
            else:
                os.close(self.fd)
        except OSError:
            pass


def xor(data: bytes, start: int) -> int:
    for b in data:
        start ^= b
    return start


# --------------------------------------------------------------------------------------------- Z-Wave Serial API
class WipeFailed(ProbeError):
    """A wipe that stopped midway: why, and what state the stick may be in (network | blank | unknown)."""

    def __init__(self, msg: str, state: str):
        ProbeError.__init__(self, msg)
        self.state = state


class ZWave:
    def __init__(self, link: Link, timeout: float, budget: Budget, allow_wipe: bool = False):
        self.link, self.timeout, self.budget = link, timeout, budget
        self.allow_wipe = allow_wipe          # True only with --wipe: the one write (HardReset) is sent only then
        self.allow_soft_reset = False         # True only with --soft-reset (read_only sets it): SoftReset (0x08) before the reads
        self.allow_rf_mode = False            # True only with --rf-receive: SetRFReceiveMode (0x10) before the reads
        self.settled = False                  # settle() done once per session (the stick's own start-up frames answered)
        self.buf = bytearray()
        self.notes: list[str] = []
        self.sent: list[str] = []

    @staticmethod
    def frame(func: int, payload: bytes = b"") -> bytes:
        body = bytes([len(payload) + 3, ZW_REQUEST, func]) + payload
        return bytes([ZW_SOF]) + body + bytes([xor(body, 0xFF)])

    def _next(self, deadline: float):
        """The next unit: ('hdr', ACK|NAK|CAN) or ('frame', type, func, payload); None at the deadline."""
        while True:
            while self.buf:
                b0 = self.buf[0]
                if b0 in (ZW_ACK, ZW_NAK, ZW_CAN):
                    del self.buf[0]
                    return ("hdr", b0)
                if b0 == ZW_SOF:
                    if len(self.buf) < 2:
                        break
                    total = self.buf[1] + 2
                    if self.buf[1] < 3:
                        del self.buf[0]
                        self.notes.append("a SOF with an impossible length — discarded")
                        continue
                    if len(self.buf) < total:
                        break
                    raw = bytes(self.buf[:total])
                    del self.buf[:total]
                    if xor(raw[1:-1], 0xFF) != raw[-1]:
                        self.link.write(bytes([ZW_NAK]), time.monotonic() + 1)   # Driver.ts: invalid data → NAK
                        self.notes.append(f"a frame with a bad checksum (func 0x{raw[3]:02x}) — NAKed")
                        continue
                    self.link.write(bytes([ZW_ACK]), time.monotonic() + 1)       # Driver.ts: "all good, send ACK"
                    return ("frame", raw[2], raw[3], raw[4:-1])
                skip = 1   # garbage: up to the next byte that can start a unit (SerialAPIParser.ts)
                while skip < len(self.buf) and self.buf[skip] not in (ZW_SOF, ZW_ACK, ZW_NAK, ZW_CAN):
                    skip += 1
                self.notes.append(f"{skip} stray byte(s) discarded")
                del self.buf[:skip]
            chunk = self.link.read_some(deadline)
            if not chunk:
                return None
            self.buf += chunk

    def settle(self, quiet: float = 0.5, limit: float = 3.0) -> int:
        """Read and answer whatever the stick is sending on its own until `quiet` s of silence (at most `limit` s): a
        stick just powered on repeats its SerialAPIStarted (0x0a) until it is ACKed and answers CAN to anything sent
        meanwhile [V 2026-10-29: "21 bytes pending", then CAN; CAN on the first request]. _next ACKs each frame
        (a NAK would make it resend); the units' count is returned (0 = nothing pending)."""
        end, n = time.monotonic() + limit, 0
        while time.monotonic() < end:
            u = self._next(min(end, time.monotonic() + quiet))
            if u is None:
                break
            n += 1
            if u[0] == "frame":
                self.notes.append("pending at the start: %s (func 0x%02x) — ACKed" % (
                    "SerialAPIStarted" if u[2] == ZW_SERIAL_API_STARTED else "a frame", u[2]))
            else:
                self.notes.append("pending at the start: a %s header — ignored" % {ZW_ACK: "ACK", ZW_NAK: "NAK", ZW_CAN: "CAN"}[u[1]])
        return n

    def request(self, func: int, name: str, payload: bytes = b"") -> bytes:
        if func not in ZW_READ_ONLY:   # the read-only promise, enforced
            raise ProbeError(f"refusing to send Z-Wave function 0x{func:02x}: not a read-only query")
        raw = self.frame(func, payload)
        why = []
        for attempt in range(1, ZW_ATTEMPTS + 1):
            if self.budget.spent():
                break
            self.link.write(raw, time.monotonic() + 2)
            self.sent.append(f"0x{func:02x}")
            got = "timeout"
            ack_by = self.budget.until(ZW_ACK_TIMEOUT)
            while True:
                u = self._next(ack_by)
                if u is None:
                    break
                if u[0] == "hdr":
                    got = {ZW_ACK: "ACK", ZW_NAK: "NAK", ZW_CAN: "CAN"}[u[1]]
                    break
                self.notes.append(f"while waiting for the ACK of {name}: an unsolicited frame (type {u[1]}, func 0x{u[2]:02x}) — ACKed, ignored")
            if got == "ACK":
                rsp_by = self.budget.until(self.timeout)
                while True:
                    u = self._next(rsp_by)
                    if u is None:
                        got = f"no response in {self.timeout:g} s"
                        break
                    if u[0] == "hdr":
                        continue
                    _, typ, fn, pl = u
                    if typ == ZW_RESPONSE and fn == func:
                        if attempt > 1:
                            self.notes.append(f"{name} answered on attempt {attempt} (before: {'; '.join(why)})")
                        return pl
                    self.notes.append(f"while waiting for {name}: {'a callback' if typ == ZW_REQUEST else 'a response'} (func 0x{fn:02x}) — ACKed, ignored")
            why.append(got)
            if attempt < ZW_ATTEMPTS and not self.budget.spent():
                time.sleep(min(0.1 + 1.0 * (attempt - 1), max(0.0, self.budget.end - time.monotonic())))
        raise ProbeError(f"{name} (0x{func:02x}): no answer ({'; '.join(why) or 'the radio budget is spent'})")

    def soft_reset(self, started_timeout: float = 5.0) -> dict:
        """SoftReset (0x08), no payload: ACK, then the stick restarts its Serial API and says so (SerialAPIStarted 0x0a,
        ~1.5 s on 700/800 series — zwave-js waits for it the same way). Reloads the NVM — the step that makes a raw NVM
        restore visible (2026-10-29: after restoreNVMRaw the stick kept answering its old home ID through a VBUS cut
        [V], and came back restored after this). A restart only, nothing written: --soft-reset only."""
        if not self.allow_soft_reset:
            raise ProbeError("refusing to send Z-Wave function 0x08 (SoftReset): a restart, and this is not --soft-reset")
        if not self.settled:
            self.settle()
            self.settled = True
        t0 = time.monotonic()
        ack = "no ACK in 1.6 s"
        for attempt in range(1, ZW_BUSY_ATTEMPTS + 1):   # a CAN/NAK = the stick is busy (after zwave-js's own reset, or delivering
            if attempt > 1:                              # the mesh's frames to a powered copy): answer what it sends, then again
                self.notes.append("SoftReset attempt %d: the stick answered %s — its pending frames answered, again" % (attempt - 1, ack))
                self.settle(0.3, 1.5)
            self.link.write(self.frame(ZW_SOFT_RESET), time.monotonic() + 2)
            self.sent.append("0x08 SoftReset")
            ack = "no ACK in 1.6 s"
            while True:
                u = self._next(time.monotonic() + ZW_ACK_TIMEOUT)
                if u is None:
                    break
                if u[0] == "hdr":
                    ack = {ZW_ACK: "ACK", ZW_NAK: "NAK", ZW_CAN: "CAN"}[u[1]]
                    break
                self.notes.append("while waiting for the ACK of SoftReset: a frame (type %d, func 0x%02x) — ACKed, ignored" % (u[1], u[2]))
            if ack == "ACK":
                break
        if ack != "ACK":
            raise ProbeError("SoftReset (0x08): %s after %d attempts — the stick did not take the request" % (ack, ZW_BUSY_ATTEMPTS))
        t1 = time.monotonic()
        started = False
        while True:
            u = self._next(t1 + started_timeout)
            if u is None:
                break
            if u[0] == "frame" and u[1] == ZW_REQUEST and u[2] == ZW_SERIAL_API_STARTED:
                started = True
                break
        if not started:
            self.notes.append("SoftReset ACKed but no SerialAPIStarted (0x0a) within %g s — reading on regardless" % started_timeout)
            time.sleep(1.5)
        n = self.link.drain(0.5, 2.0)
        return {"ack_s": round(t1 - t0, 2), "serial_api_started": started, "started_s": round(time.monotonic() - t1, 2), "drained": n}

    def rf_receive(self, enabled: bool) -> dict:
        """SetRFReceiveMode (0x10) [1|0] → RESPONSE [success] — zwave-js's toggleRF (SetRFReceiveModeMessages.ts [V 2026-10-29]).
        Off: the controller's receiver is off until it is turned on again or the controller restarts (a SoftReset, a power
        cycle, zwave-js's own start-up) — the way a powered, undriven copy is silenced (it
        would otherwise ACK frames addressed to node 1 next to the live controller). A WRITE of its own kind: --rf-receive only."""
        if not self.allow_rf_mode:
            raise ProbeError("refusing to send Z-Wave function 0x10 (SetRFReceiveMode): this is not --rf-receive")
        if not self.settled:
            self.settle()
            self.settled = True
        raw = self.frame(ZW_SET_RF_RECEIVE_MODE, bytes([1 if enabled else 0]))
        why = []
        for attempt in range(1, ZW_BUSY_ATTEMPTS + 1):
            if attempt > 1:          # CAN = our frame collided with one the stick was sending (a live mesh delivers
                self.settle(0.3, 1.5)   # 0xa8 frames to a powered copy all the time): answer those, then again
            self.link.write(raw, time.monotonic() + 2)
            self.sent.append("0x10 SetRFReceiveMode(%d)" % (1 if enabled else 0))
            got = "no ACK in 1.6 s"
            while True:
                u = self._next(time.monotonic() + ZW_ACK_TIMEOUT)
                if u is None:
                    break
                if u[0] == "hdr":
                    got = {ZW_ACK: "ACK", ZW_NAK: "NAK", ZW_CAN: "CAN"}[u[1]]
                    break
                self.notes.append("while waiting for the ACK of SetRFReceiveMode: a frame (type %d, func 0x%02x) — ACKed, ignored" % (u[1], u[2]))
            if got == "ACK":
                rsp_by = time.monotonic() + self.timeout
                while True:
                    u = self._next(rsp_by)
                    if u is None:
                        got = "no response in %g s" % self.timeout
                        break
                    if u[0] == "hdr":
                        continue
                    _, typ, fn, pl = u
                    if typ == ZW_RESPONSE and fn == ZW_SET_RF_RECEIVE_MODE:
                        success = bool(pl[0]) if pl else False
                        if not success:
                            raise ProbeError("SetRFReceiveMode(%d): the controller answered failure (%s)" % (1 if enabled else 0, pl.hex()))
                        self.notes.append("RF receive mode %s (SetRFReceiveMode answered success%s)" % (
                            "ON" if enabled else "OFF", "" if attempt == 1 else " on attempt %d" % attempt))
                        return {"enabled": enabled, "success": True, "attempt": attempt}
                    self.notes.append("while waiting for SetRFReceiveMode: a frame (type %d, func 0x%02x) — ACKed, ignored" % (typ, fn))
            why.append(got)
        raise ProbeError("SetRFReceiveMode(%d): no answer (%s)" % (1 if enabled else 0, "; ".join(why)))

    def hard_reset(self, callback_timeout: float = ZW_CALLBACK_TIMEOUT) -> dict:
        """zwave-js's HardResetRequest, as Controller.ts L2003-2006 sends it (see the module docstring): REQUEST 0x42
        [callback id 1], ONE attempt, the ACK, then the callback REQUEST 0x42 [1]. Raises WipeFailed with the state the
        stick may be in; returns the timings. A WRITE: refused unless this session was made with --wipe."""
        if not self.allow_wipe or ZW_HARD_RESET not in ZW_WIPE:
            raise ProbeError("refusing to send Z-Wave function 0x42 (HardReset): a write, and this is not --wipe")
        cb = 1                                   # Driver.ts L6446: createWrappingCounter(0xff) starts at 1
        self.link.write(self.frame(ZW_HARD_RESET, bytes([cb])), time.monotonic() + 2)
        self.sent.append("0x42 HardReset (callback id 1)")
        t0 = time.monotonic()
        ack = "no ACK in 1.6 s"
        while True:
            u = self._next(t0 + ZW_ACK_TIMEOUT)
            if u is None:
                break
            if u[0] == "hdr":
                ack = {ZW_ACK: "ACK", ZW_NAK: "NAK", ZW_CAN: "CAN"}[u[1]]
                break
            self.notes.append("while waiting for the ACK of HardReset: a frame (type %d, func 0x%02x) — ACKed, ignored" % (u[1], u[2]))
        if ack != "ACK":
            # one attempt only (Driver.ts L7128): a NAK/CAN means the stick did not take the frame; no ACK, that it may
            # not have arrived — either way nothing says it reset
            raise WipeFailed("HardReset (0x42): %s — the stick did not accept the request (sent once, as zwave-js does: no "
                             "retry); it should be as it was" % ack, "network")
        t1 = time.monotonic()
        started = False
        while True:
            u = self._next(t1 + callback_timeout)
            if u is None:
                raise WipeFailed("HardReset (0x42): ACKed, but no callback within %g s — the stick may or may not have "
                                 "reset" % callback_timeout, "unknown")
            if u[0] == "hdr":
                continue
            _, typ, fn, pl = u
            if typ == ZW_REQUEST and fn == ZW_HARD_RESET and pl[:1] == bytes([cb]):   # Message.ts L382-395
                break
            if typ == ZW_REQUEST and fn == ZW_SERIAL_API_STARTED:
                started = True
                self.notes.append("SerialAPIStarted (0x0a) while waiting for the HardReset callback — ACKed")
                continue
            self.notes.append("while waiting for the HardReset callback: a frame (type %d, func 0x%02x) — ACKed, ignored" % (typ, fn))
        res = {"ack_s": round(t1 - t0, 2), "callback_s": round(time.monotonic() - t1, 2), "serial_api_started": started}
        # a 700/800 stick may restart its Serial API after the reset (Driver.ts L5465): give it a moment to say so
        end = time.monotonic() + 1.0
        while time.monotonic() < end:
            u = self._next(end)
            if u is None:
                break
            if u[0] == "frame" and u[1] == ZW_REQUEST and u[2] == ZW_SERIAL_API_STARTED:
                res["serial_api_started"] = True
                self.notes.append("SerialAPIStarted (0x0a) after the HardReset callback — ACKed (the stick restarted its Serial API)")
        return res

    def nvm_op(self, ext: bool, cmd: int, length: int = 0, offset: int = 0) -> tuple:
        """One NVM operation (Open/Read/Close — Write is refused here, whatever the caller): (status, offset_or_size, data)."""
        if cmd not in (ZW_NVM_OPEN, ZW_NVM_READ, ZW_NVM_CLOSE):
            raise ProbeError(f"refusing NVM operation 0x{cmd:02x}: only Open/Read/Close are reads")
        if cmd == ZW_NVM_READ:
            payload = bytes([cmd, length]) + (offset.to_bytes(4, "big") if ext else offset.to_bytes(2, "big"))
        else:
            payload = bytes([cmd])
        pl = self.request(ZW_NVM_OPS_EXT if ext else ZW_NVM_OPS, f"NVM{'Ext' if ext else ''}Operations/{ {0: 'Open', 1: 'Read', 3: 'Close'}[cmd] }", payload)
        if len(pl) < 2:
            raise ProbeError(f"NVM operation 0x{cmd:02x}: a {len(pl)}-byte answer")
        status, n = pl[0], pl[1]
        w = 4 if ext else 2
        off = int.from_bytes(pl[2:2 + w], "big") if len(pl) >= 2 + w else 0
        data = pl[2 + w:2 + w + n] if n and len(pl) >= 2 + w + n else b""
        return status, off, data

    def nvm_dump(self, funcs) -> dict:
        """The controller's NVM as zwave-js's backupNVMRaw reads it (Open → Read in the chunk size the stick answers →
        Close), without the RF toggle it does first (this is for an IDLE stick: nothing writes its NVM meanwhile) — a
        read, no RF: {"size", "data", "ext"} — the bytes are returned to the caller, never printed."""
        ext = funcs is not None and ZW_NVM_OPS_EXT in funcs
        if funcs is not None and not ext and ZW_NVM_OPS not in funcs:
            raise ProbeError("the stick lists neither NVMOperations (0x2e) nor ExtendedNVMOperations (0x3d)")
        st, size, _ = self.nvm_op(ext, ZW_NVM_OPEN)
        if st != 0:
            raise ProbeError(f"NVM open: status {ZW_NVM_STATUS.get(st, st)}")
        out = bytearray()
        try:
            offset = 0
            while offset < size:
                st, off, data = self.nvm_op(ext, ZW_NVM_READ, 0xFF, offset)
                if st not in (0x00, 0xFF):
                    raise ProbeError(f"NVM read at {offset}: status {ZW_NVM_STATUS.get(st, st)}")
                if not data:
                    raise ProbeError(f"NVM read at {offset}: no data (status {ZW_NVM_STATUS.get(st, st)})")
                out += data
                offset += len(data)
                if st == 0xFF:
                    break
        finally:
            try:
                self.nvm_op(ext, ZW_NVM_CLOSE)
            except ProbeError as e:
                self.notes.append(f"NVM close: {e}")
        return {"size": size, "ext": ext, "data": bytes(out)}

    def setup_get(self, sub: int, name: str) -> bytes:
        """SerialAPISetup with one GET sub-command (the allow-list above); the answer minus its echoed sub-command byte."""
        if sub not in ZW_SETUP_GETS:
            raise ProbeError(f"refusing SerialAPISetup sub-command 0x{sub:02x}: not a GET")
        pl = self.request(ZW_SERIAL_API_SETUP, f"SerialAPISetup/{name}", bytes([sub]))
        if not pl or pl[0] != sub:
            raise ProbeError(f"{name}: the stick answered sub-command 0x{pl[0]:02x} instead of 0x{sub:02x}" if pl else f"{name}: empty answer")
        return pl[1:]

    def rf_read(self) -> dict:
        """{region, region_name, tx_power_dbm, measured_0dbm} or {'error': …} — never fatal for the probe."""
        rf: dict = {}
        try:
            pl = self.setup_get(ZW_SETUP_GET_RF_REGION, "GetRFRegion")
            rf["region"] = pl[0] if pl else None
            rf["region_name"] = ZW_RF_REGIONS.get(rf["region"], f"region {rf['region']}")
        except ProbeError as e:
            rf["error"] = f"GetRFRegion: {e}"
            self.notes.append(f"GetRFRegion: {e} — RF region unknown, not fatal")
            return rf
        try:
            pl = self.setup_get(ZW_SETUP_GET_POWERLEVEL16, "GetPowerlevel16Bit")
            if len(pl) >= 4:
                rf["tx_power_dbm"] = int.from_bytes(pl[0:2], "big", signed=True) / 10.0
                rf["measured_0dbm"] = int.from_bytes(pl[2:4], "big", signed=True) / 10.0
                rf["power_source"] = "GetPowerlevel16Bit (0x13)"
                return rf
            self.notes.append(f"GetPowerlevel16Bit: a {len(pl)}-byte answer — trying the 8-bit read")
        except ProbeError as e:
            self.notes.append(f"GetPowerlevel16Bit: {e} — trying the 8-bit read")
        try:
            pl = self.setup_get(ZW_SETUP_GET_POWERLEVEL, "GetPowerlevel")
            v = int.from_bytes(pl[0:1], "big", signed=True) if pl else None
            if v == 0x7F or v is None:
                rf["tx_power_dbm"] = None
                self.notes.append("GetPowerlevel answered 0x7f (= use the 16-bit read, which also failed) — tx power unknown, not fatal")
            else:
                rf["tx_power_dbm"] = float(v)
                rf["measured_0dbm"] = float(int.from_bytes(pl[1:2], "big", signed=True)) if len(pl) >= 2 else None
                rf["power_source"] = "GetPowerlevel (0x08)"
        except ProbeError as e:
            rf["tx_power_dbm"] = None
            self.notes.append(f"GetPowerlevel: {e} — tx power unknown, not fatal")
        return rf

    def probe(self) -> dict:
        out: dict = {"protocol": "Z-Wave Serial API"}
        if not self.settled:
            self.link.write(bytes([ZW_NAK]), time.monotonic() + 2)   # zwave-js: a NAK resets the communication at startup
            self.settle()
            self.settled = True
        pl = self.request(ZW_GET_CONTROLLER_ID, "GetControllerId")
        if len(pl) < 5:
            raise ProbeError(f"GetControllerId: a {len(pl)}-byte answer (want ≥ 5)")
        out["home_id"] = int.from_bytes(pl[0:4], "big")
        out["home_id_hex"] = f"0x{out['home_id']:08x}"
        out["node_id_bits"] = 16 if len(pl) >= 6 else 8   # Primitive.ts parseNodeID: 1 byte, or 2 in 16-bit mode
        out["own_node_id"] = int.from_bytes(pl[4:6], "big") if len(pl) >= 6 else pl[4]
        pl = self.request(ZW_GET_INIT_DATA, "GetSerialApiInitData")
        if len(pl) < 3 + ZW_NODEMASK_BYTES or pl[2] != ZW_NODEMASK_BYTES:
            raise ProbeError(f"GetSerialApiInitData: no {ZW_NODEMASK_BYTES}-byte node list in the answer ({pl.hex()})")
        api, caps = pl[0], pl[1]
        out["api_version"] = f"{api - 9} (official)" if api >= 10 else f"{api} (legacy)"
        # GetSerialApiInitDataMessages.ts: the firmware keeps the "old" bit meanings
        out["role"] = "secondary" if caps & 0b0100 else "primary"
        out["sis"] = bool(caps & 0b1000)
        out["end_node"] = bool(caps & 0b0001)
        mask = pl[3:3 + ZW_NODEMASK_BYTES]
        out["nodes"] = [8 * j + i + 1 for j, byte in enumerate(mask) for i in range(8) if byte & (1 << i)]
        out["node_count"] = len(out["nodes"])
        rest = pl[3 + ZW_NODEMASK_BYTES:]
        if len(rest) >= 2:
            out["chip"] = f"0x{rest[0]:02x}/0x{rest[1]:02x}"
        funcs = None
        self.funcs = None
        try:
            pl = self.request(ZW_GET_CAPABILITIES, "GetSerialApiCapabilities")
            if len(pl) >= 8:
                out["firmware"] = f"{pl[0]}.{pl[1]}"
                out["manufacturer_id"] = int.from_bytes(pl[2:4], "big")
                out["product_type"] = int.from_bytes(pl[4:6], "big")
                out["product_id"] = int.from_bytes(pl[6:8], "big")
                bm = pl[8:8 + 32]
                funcs = {8 * j + i + 1 for j, byte in enumerate(bm) for i in range(8) if byte & (1 << i)}
                self.funcs = funcs
        except ProbeError as e:
            self.notes.append(f"GetSerialApiCapabilities: {e} — identity unknown, not fatal")
        if funcs is None or ZW_GET_PROTOCOL_VERSION in funcs:
            try:
                pl = self.request(ZW_GET_PROTOCOL_VERSION, "GetProtocolVersion")
                if len(pl) >= 4:
                    out["protocol_type"] = pl[0]
                    out["sdk"] = f"{pl[1]}.{pl[2]}.{pl[3]}"
                    out["sdk_source"] = "GetProtocolVersion (0x09)"
                    if len(pl) >= 6 and int.from_bytes(pl[4:6], "big"):
                        out["app_framework_build"] = int.from_bytes(pl[4:6], "big")
            except ProbeError as e:
                self.notes.append(f"GetProtocolVersion: {e} — falling back to GetControllerVersion")
        if "sdk" not in out:
            try:
                pl = self.request(ZW_GET_CONTROLLER_VERSION, "GetControllerVersion")
                s = pl.split(b"\0", 1)[0].decode("ascii", "replace")
                out["library"] = s
                if len(pl) > len(s) + 1:
                    out["library_type"] = pl[len(s) + 1]
                out["sdk"] = s.split()[-1] if s.split() else s   # "Z-Wave 7.23" → "7.23" (no patch level here)
                out["sdk_source"] = "GetControllerVersion (0x15)"
            except ProbeError as e:
                self.notes.append(f"GetControllerVersion: {e} — SDK unknown, not fatal")
        own = out["own_node_id"]
        out["verdict"] = "blank" if out["nodes"] == [own] else "live"
        # the RF config (for the check after a restore): SerialAPISetup GET sub-commands only — read-only,
        # no RF transmission; the driver's "RF region USA (Long Range)" / "powerlevel 14 dBm" lines come from the same reads
        out["rf"] = self.rf_read()
        return out


# --------------------------------------------------------------------------------------------- Z-Stack MT (ZNP)
class RPCError(ProbeError):
    pass


class ZNP:
    def __init__(self, link: Link, timeout: float, budget: Budget, allow_wipe: bool = False, read_ext_pan: bool = False):
        self.link, self.timeout, self.budget = link, timeout, budget
        self.allow_wipe = allow_wipe          # True only with --wipe: the writes (ZNP_WIPE, SYS_RESET_REQ) only then
        self.allow_reset = False              # True only with --zigbee-reset: SYS_RESET_REQ alone (no NV write) before the reads
        self.read_ext_pan = read_ext_pan      # True only for a --wipe session: after a blank verdict, also read
                                              # EXTENDED_PAN_ID (the plain probe sends nothing extra)
        self.buf = bytearray()
        self.notes: list[str] = []
        self.sent: list[str] = []

    @staticmethod
    def frame(cmd0: int, cmd1: int, payload: bytes = b"") -> bytes:
        body = bytes([len(payload), cmd0, cmd1]) + payload
        return bytes([MT_SOF]) + body + bytes([xor(body, 0)])

    def _next(self, deadline: float):
        while True:
            while self.buf:
                if self.buf[0] != MT_SOF:
                    skip = 1
                    while skip < len(self.buf) and self.buf[skip] != MT_SOF:
                        skip += 1
                    self.notes.append(f"{skip} stray byte(s) discarded")
                    del self.buf[:skip]
                    continue
                if len(self.buf) < 2:
                    break
                ln = self.buf[1]
                if ln > 250:   # frames.py: "Frame length cannot exceed 250 bytes"
                    del self.buf[0]
                    self.notes.append("a SOF with an impossible length — discarded")
                    continue
                total = ln + 5
                if len(self.buf) < total:
                    break
                raw = bytes(self.buf[:total])
                del self.buf[:total]
                if xor(raw[1:-1], 0) != raw[-1]:
                    self.notes.append(f"a frame with a bad FCS (0x{raw[2]:02x} 0x{raw[3]:02x}) — dropped")
                    continue
                return raw[2], raw[3], raw[4:-1]
            chunk = self.link.read_some(deadline)
            if not chunk:
                return None
            self.buf += chunk

    def sreq(self, sub: int, cid: int, name: str, payload: bytes = b"", attempts: int = 2) -> bytes:
        if (sub, cid) not in ZNP_READ_ONLY:   # the read-only promise, enforced
            raise ProbeError(f"refusing to send ZNP 0x{MT_SREQ | sub:02x} 0x{cid:02x}: not a read-only query")
        return self._exchange(sub, cid, name, payload, attempts, self.timeout)

    def _wipe_gate_ok(self, cid: int, payload: bytes) -> bool:
        """The two write SREQs' exact shape: command from ZNP_WIPE, an NV item of reset_network_info's
        four for DELETE, and the one STARTUP_OPTION value for WRITE_EXT. Checked in _exchange — the lowest send path —
        so no caller can reach the wire with a write this tool did not authorise."""
        nv = int.from_bytes(payload[0:2], "little")
        return (MT_SYS, cid) in ZNP_WIPE and not (
            (cid == ZNP_SYS_OSAL_NV_DELETE and (len(payload) != 4 or nv not in ZNP_WIPE_DELETE_IDS))
            or (cid == ZNP_SYS_OSAL_NV_WRITE_EXT and payload != self.startup_write_payload()))

    def _write(self, cid: int, name: str, payload: bytes) -> int:
        """One of zigpy-znp's own WRITE SREQs (the wipe), checked against the allow-list — the command, the NV item and,
        for the write, the value — before a byte is sent; sent once (ZNP.request has no retry), ≤ 15 s. → its Status."""
        if not self.allow_wipe:
            raise ProbeError("refusing to send %s: a write, and this is not --wipe" % name)
        if not self._wipe_gate_ok(cid, payload):
            raise ProbeError("refusing to send %s (0x21 0x%02x %s): not one of zigpy-znp's reset_network_info writes" % (name, cid, payload.hex()))
        pl = self._exchange(MT_SYS, cid, name, payload, 1, ZNP_WRITE_TIMEOUT)
        if len(pl) < 1:
            raise WipeFailed("%s: an empty answer" % name, "unknown")
        return pl[0]

    @staticmethod
    def startup_write_payload() -> bytes:
        # SYS_OSAL_NV_WRITE_EXT: Id u16 LE, Offset u16 LE (commands/sys.py L494: "This *not* 8 bits"), Value LongBytes
        # (types/basic.py: a u16 LE length, then the bytes) — STARTUP_OPTION 0x0003 = 0x03 at offset 0
        return NV_STARTUP_OPTION.to_bytes(2, "little") + (0).to_bytes(2, "little") + (1).to_bytes(2, "little") + bytes([STARTUP_CLEAR])

    def nv_length(self, nv: int) -> int:
        pl = self.sreq(MT_SYS, ZNP_SYS_OSAL_NV_LENGTH, "SYS_OSAL_NV_LENGTH(0x%04x)" % nv, payload=nv.to_bytes(2, "little"))
        if len(pl) < 2:
            raise ProbeError("SYS_OSAL_NV_LENGTH(0x%04x): a %d-byte answer" % (nv, len(pl)))
        return int.from_bytes(pl[0:2], "little")

    def nv_delete(self, nv: int, length: int) -> int:
        return self._write(ZNP_SYS_OSAL_NV_DELETE, "SYS_OSAL_NV_DELETE(0x%04x)" % nv, nv.to_bytes(2, "little") + length.to_bytes(2, "little"))

    def nv_write_startup(self) -> int:
        return self._write(ZNP_SYS_OSAL_NV_WRITE_EXT, "SYS_OSAL_NV_WRITE_EXT(STARTUP_OPTION = 0x03)", self.startup_write_payload())

    def reset_req(self) -> None:
        """The AREQ SYS_RESET_REQ Type=Soft (api.py L628-640 reset()) — a WRITE (the stick reboots): --wipe or --zigbee-reset only."""
        if not (self.allow_wipe or self.allow_reset):
            raise ProbeError("refusing to send SYS_RESET_REQ: this is not --wipe or --zigbee-reset")
        self.link.write(self.frame(MT_AREQ | MT_SYS, ZNP_SYS_RESET_REQ, bytes([RESET_SOFT])), time.monotonic() + 2)
        self.sent.append("0x41 0x00 SYS_RESET_REQ (soft)")

    def wait_reset_ind(self, bound: float):
        end = time.monotonic() + bound
        while True:
            u = self._next(end)
            if u is None:
                return None
            c0, c1, pl = u
            if c0 == MT_AREQ | MT_SYS and c1 == ZNP_SYS_RESET_IND:
                return pl
            self.notes.append("while waiting for SYS_RESET_IND: 0x%02x 0x%02x — ignored" % (c0, c1))

    def quiet(self, reset_timeout: float = ZNP_ARSP_TIMEOUT) -> dict:
        """--zigbee-reset: SYS_RESET_REQ (soft) alone, then SYS_RESET_IND — nothing written to NV. A Z-Stack ZNP coordinator
        does not start its network after a reset until a host sends ZDO_STARTUP_FROM_APP (zigpy-znp does at every
        connect) [H until the first read: the probe after it reports device_state — InitializedNotStarted = quiet; a
        running state = the firmware auto-started]. The way a powered, undriven standby
        coordinator is silenced (a second coordinator of the same PAN on the air); ZHA's next connect through ser2net starts it again."""
        if not self.allow_reset:
            raise ProbeError("refusing to send SYS_RESET_REQ: this is not --zigbee-reset")
        self.skip_bootloader()
        t0 = time.monotonic()
        self.reset_req()
        pl = self.wait_reset_ind(reset_timeout)
        if pl is None:
            raise ProbeError("SYS_RESET_REQ sent, no SYS_RESET_IND within %g s" % reset_timeout)
        self.notes.append("SYS_RESET_IND after %.1f s: reason %s, transport %s, product %s, version %s" % (
            time.monotonic() - t0, pl[0] if pl else "?", pl[1] if len(pl) > 1 else "?", pl[2] if len(pl) > 2 else "?",
            ".".join(str(b) for b in pl[3:6]) if len(pl) >= 6 else "?"))
        time.sleep(0.5)
        return {"reset_ind_s": round(time.monotonic() - t0, 2), "reason": pl[0] if pl else None}

    def network_reset(self, reset_timeout: float = ZNP_ARSP_TIMEOUT) -> dict:
        """zigpy-znp's ZNP.reset_network_info() (api.py L327-344), then zigpy-cli's closing reset (the module docstring).
        Raises WipeFailed with the state the stick may be in. A WRITE: refused unless this session was made with --wipe."""
        if not self.allow_wipe:
            raise ProbeError("refusing the ZNP network reset: writes, and this is not --wipe")
        res: dict = {"deleted": [], "absent": []}
        for nv in ZNP_WIPE_DELETE_IDS:                 # nvram.py L84-98 osal_delete
            try:
                ln = self.nv_length(nv)
            except ProbeError as e:
                raise WipeFailed("%s — deleted so far: %s" % (e, res["deleted"] or "nothing"), "network" if not res["deleted"] else "unknown") from None
            if ln == 0:
                res["absent"].append("0x%04x" % nv)
                continue
            try:
                st = self.nv_delete(nv, ln)
            except ProbeError as e:
                raise WipeFailed("%s — deleted so far: %s" % (e, res["deleted"] or "nothing"), "unknown") from None
            res["deleted"].append({"id": "0x%04x" % nv, "len": ln, "status": st})
            if st != 0:
                self.notes.append("SYS_OSAL_NV_DELETE(0x%04x) answered status 0x%02x (zigpy-znp ignores it, so does this)" % (nv, st))
        gone = ", ".join(d["id"] for d in res["deleted"] if d["status"] == 0) or "none"
        state_mid = ("the formation items deleted (%s) but the network itself NOT cleared: the stick reads as not on a "
                     "network (BDBNODEISONANETWORK gone) while its network keys and PAN are still in NV — re-run the wipe" % gone)
        try:
            ln = self.nv_length(NV_STARTUP_OPTION)    # nvram.py L100-121 osal_write(create=False)
        except ProbeError as e:
            raise WipeFailed("%s — %s" % (e, state_mid), "unknown") from None
        if ln != 1:
            raise WipeFailed("STARTUP_OPTION (0x0003) has length %d, not 1: zigpy-znp's osal_write raises here (%s) — "
                             "nothing more sent; %s" % (ln, "KeyError" if ln == 0 else "ValueError", state_mid), "unknown")
        try:
            st = self.nv_write_startup()
        except ProbeError as e:
            raise WipeFailed("%s — %s" % (e, state_mid), "unknown") from None
        if st != 0:   # RspStatus=SUCCESS (nvram.py L145)
            raise WipeFailed("SYS_OSAL_NV_WRITE_EXT(STARTUP_OPTION) answered status 0x%02x, not SUCCESS: STARTUP_OPTION not "
                             "written, no reset sent — %s" % (st, state_mid), "unknown")
        res["startup_option"] = "0x%02x" % STARTUP_CLEAR
        t0 = time.monotonic()
        self.reset_req()                              # api.py L634-638 reset(): request_callback_rsp(ResetReq, ResetInd)
        ind = self.wait_reset_ind(reset_timeout)
        if ind is None:
            raise WipeFailed("no SYS_RESET_IND within %g s of SYS_RESET_REQ: STARTUP_OPTION is set to clear the state and "
                             "the config, so the stick clears its network at its next boot — it did not report one" % reset_timeout, "unknown")
        res["reset_ind_s"] = round(time.monotonic() - t0, 2)
        res["reset_reason"] = ind[0] if ind else None
        self.reset_req()                              # zigpy-cli's cleanup: disconnect() → reset(wait_for_reset=False)
        return res

    def _exchange(self, sub: int, cid: int, name: str, payload: bytes, attempts: int, timeout: float) -> bytes:
        if (sub, cid) not in ZNP_READ_ONLY and not (self.allow_wipe and self._wipe_gate_ok(cid, payload)):
            raise ProbeError(f"refusing to send ZNP 0x{MT_SREQ | sub:02x} 0x{cid:02x}: not in the allow-list")
        raw = self.frame(MT_SREQ | sub, cid, payload)
        why = []
        for attempt in range(1, attempts + 1):
            if self.budget.spent():
                break
            self.link.write(raw, time.monotonic() + 2)
            self.sent.append(f"0x{MT_SREQ | sub:02x} 0x{cid:02x}")
            by = self.budget.until(timeout)
            while True:
                u = self._next(by)
                if u is None:
                    why.append(f"no SRSP in {timeout:g} s")
                    break
                c0, c1, pl = u
                if c0 == MT_SRSP | sub and c1 == cid:
                    if attempt > 1:
                        self.notes.append(f"{name} answered on attempt {attempt}")
                    return pl
                if c0 == MT_SRSP | MT_RPC and c1 == 0x00:   # commands/rpc_error: CommandNotRecognized
                    raise RPCError(f"{name}: the radio does not recognise it (RPC error {pl[:1].hex()}, request {pl[1:3].hex()})")
                kind = "an AREQ" if c0 & 0xE0 == MT_AREQ else "an unexpected frame"
                self.notes.append(f"while waiting for {name}: {kind} 0x{c0:02x} 0x{c1:02x} — ignored")
        raise ProbeError(f"{name}: no answer ({'; '.join(why) or 'the radio budget is spent'})")

    def skip_bootloader(self) -> None:
        self.link.write(bytes([MT_SKIP_BOOTLOADER]), time.monotonic() + 2)
        self.sent.append("0xef (bootloader skip)")
        time.sleep(1.0)
        n = self.link.drain(0.2, 2.0)
        if n:
            self.notes.append(f"{n} byte(s) after the bootloader skip — discarded")

    def _read_ext_pan(self, out: dict) -> None:
        """--wipe sessions only, after a blank verdict: zigpy-znp's reset deletes no extended PAN — Z-Stack
        clears it at the boot STARTUP_OPTION requests. So NV 0x002D still holding the network's value means the wipe
        stopped between the deletes and the reset; absent or another value is a stick that does not hold the network."""
        ln = self.nv_length(NV_EXT_PAN_ID)
        if ln == 0:
            out["nv_extpan"] = ""                                     # the item does not exist (a cleared/fresh stick)
            return
        pl = self.sreq(MT_SYS, ZNP_SYS_OSAL_NV_READ, "SYS_OSAL_NV_READ(EXTENDED_PAN_ID)",
                       payload=NV_EXT_PAN_ID.to_bytes(2, "little") + bytes([0]))
        if pl[0] != 0 or len(pl) < 2 + pl[1]:
            raise ProbeError(f"SYS_OSAL_NV_READ(EXTENDED_PAN_ID): status 0x{pl[0]:02x}, {len(pl)} byte(s)")
        value = pl[2:2 + pl[1]]
        out["nv_extpan"] = ":".join(f"{b:02x}" for b in reversed(value)) if len(value) == 8 else value.hex()

    def probe(self) -> dict:
        out: dict = {"protocol": "TI Z-Stack MT (ZNP)"}
        self.skip_bootloader()
        try:
            pl = self.sreq(MT_SYS, ZNP_SYS_PING, "SYS_PING", attempts=1)
        except RPCError:
            raise
        except ProbeError as e:
            self.notes.append(f"SYS_PING: {e} — the bootloader skip once more")
            self.skip_bootloader()
            pl = self.sreq(MT_SYS, ZNP_SYS_PING, "SYS_PING", attempts=2)
        out["capabilities"] = f"0x{int.from_bytes(pl[0:2], 'little'):04x}" if len(pl) >= 2 else None
        try:
            pl = self.sreq(MT_SYS, ZNP_SYS_VERSION, "SYS_VERSION")
            if len(pl) >= 5:
                out["transport_rev"], out["product_id"] = pl[0], pl[1]
                out["version"] = f"{pl[2]}.{pl[3]}.{pl[4]}"
            if len(pl) >= 9:
                out["code_revision"] = int.from_bytes(pl[5:9], "little")   # the firmware build date, e.g. 20230507
        except ProbeError as e:
            self.notes.append(f"SYS_VERSION: {e} — firmware unknown, not fatal")
        pl = self.sreq(MT_UTIL, ZNP_UTIL_GET_DEVICE_INFO, "UTIL_GET_DEVICE_INFO")
        if len(pl) < 14:
            raise ProbeError(f"UTIL_GET_DEVICE_INFO: a {len(pl)}-byte answer (want ≥ 14)")
        out["device_info_status"] = pl[0]
        out["ieee"] = ":".join(f"{b:02x}" for b in reversed(pl[1:9]))   # EUI64, little-endian on the wire
        out["nwk"] = f"0x{int.from_bytes(pl[9:11], 'little'):04x}"
        out["device_type"] = pl[11]
        out["device_state"] = pl[12]
        out["device_state_name"] = ZNP_DEVICE_STATES.get(pl[12], "unknown")
        # zigpy-znp's own test, in its order (nvram.py osal_read): the item's length first — 0 = it does not exist
        pl = self.sreq(MT_SYS, ZNP_SYS_OSAL_NV_LENGTH, "SYS_OSAL_NV_LENGTH(BDBNODEISONANETWORK)",
                       payload=NV_BDBNODEISONANETWORK.to_bytes(2, "little"))
        if len(pl) < 2:
            raise ProbeError(f"SYS_OSAL_NV_LENGTH: a {len(pl)}-byte answer")
        out["nv_len"] = int.from_bytes(pl[0:2], "little")
        if out["nv_len"] == 0:
            out["nv_value"] = ""
            out["on_network"] = False          # KeyError → NetworkNotFormed (api.py load_network_info)
            out["verdict"] = "blank"
            out["nv_why"] = "BDBNODEISONANETWORK does not exist (length 0)"
            if self.read_ext_pan:
                self._read_ext_pan(out)
            return out
        pl = self.sreq(MT_SYS, ZNP_SYS_OSAL_NV_READ, "SYS_OSAL_NV_READ(BDBNODEISONANETWORK)",
                       payload=NV_BDBNODEISONANETWORK.to_bytes(2, "little") + bytes([0]))
        if len(pl) < 2:
            raise ProbeError(f"SYS_OSAL_NV_READ: a {len(pl)}-byte answer")
        out["nv_status"] = pl[0]
        value = pl[2:2 + pl[1]]
        out["nv_value"] = value.hex()
        if pl[0] != 0 or len(value) < 1:
            # zigpy-znp reads with RspStatus=SUCCESS: anything else is an error there, never "not formed" — so not blank
            out["on_network"] = None
            out["verdict"] = "unknown"
            out["nv_why"] = f"BDBNODEISONANETWORK (length {out['nv_len']}) read answered status 0x{pl[0]:02x}" + ("" if pl[0] else ", no value")
            return out
        out["on_network"] = value[0] == 0x01   # api.py _load_network_info: != 1 → NetworkNotFormed
        out["verdict"] = "live" if out["on_network"] else "blank"
        out["nv_why"] = f"BDBNODEISONANETWORK = 0x{value[0]:02x}"
        if self.read_ext_pan and out["verdict"] == "blank":
            self._read_ext_pan(out)
        return out


def run(kind: str, spec: str, args) -> dict:
    budget = Budget(args.budget)
    res: dict = {"port": spec, "ok": False, "error": None, "verdict": "unknown"}
    t0 = time.monotonic()
    link = None
    proto = None
    try:
        link = Link(spec, args.connect_timeout)
        proto = (ZWave if kind == "zwave" else ZNP)(link, args.timeout, budget)
        if kind == "zwave" and getattr(args, "soft_reset", False):      # --soft-reset: the restart first, then the reads
            proto.allow_soft_reset = True
            res["soft_reset"] = proto.soft_reset(args.reset_timeout or 5.0)
            proto.allow_soft_reset = False
        if kind == "zwave" and getattr(args, "rf_receive", None):       # --rf-receive off|on: the receiver, then the reads
            proto.allow_rf_mode = True
            res["rf_receive"] = proto.rf_receive(args.rf_receive == "on")
            proto.allow_rf_mode = False
        if kind == "zigbee" and getattr(args, "zigbee_reset", False):   # --zigbee-reset: the reboot first, then the reads
            proto.allow_reset = True
            res["zigbee_reset"] = proto.quiet(args.reset_timeout or ZNP_ARSP_TIMEOUT)
            proto.allow_reset = False
        res.update(proto.probe())
        if kind == "zwave" and getattr(args, "nvm_dump", None):         # --nvm-dump: after the reads, the NVM to a file
            d = proto.nvm_dump(getattr(proto, "funcs", None))
            with open(args.nvm_dump, "wb") as f:
                f.write(d["data"])
            os.chmod(args.nvm_dump, 0o600)
            res["nvm_dump"] = {"file": args.nvm_dump, "size": d["size"], "bytes": len(d["data"]), "ext": d["ext"],
                               "sha256": hashlib.sha256(d["data"]).hexdigest()}
        res["ok"] = True
    except ProbeError as e:
        res["error"] = str(e)
    finally:
        if link:
            link.close()
        if proto:
            res["notes"] = proto.notes
            res["sent"] = proto.sent
        res["seconds"] = round(time.monotonic() - t0, 2)
    return res


def rf_text(rf: dict) -> str:
    if not rf or "region" not in rf:
        return ""
    pw = rf.get("tx_power_dbm")
    return f", RF {rf.get('region_name')} ({rf.get('region')}){f' at {pw:g} dBm' if pw is not None else ''}"


def human(kind: str, r: dict) -> list[str]:
    tag = "Z-Wave" if kind == "zwave" else "Zigbee"
    if not r["ok"]:
        return [f"   FAIL  {tag} on {r['port']}: {r['error']} ({r['seconds']} s)"]
    if kind == "zwave":
        ident = ""
        if "manufacturer_id" in r:
            ident = f", manufacturer 0x{r['manufacturer_id']:04x} product {r['product_type']}/{r['product_id']}, firmware {r['firmware']}"
        nd = r.get("nvm_dump")
        sr = r.get("soft_reset")
        lines = [] if not sr else [f"   NOTE  {tag}: SoftReset sent first — ACK in {sr['ack_s']} s, SerialAPIStarted {'seen' if sr['serial_api_started'] else 'NOT seen'} after {sr['started_s']} s; the reads below are after the restart"]
        rm = r.get("rf_receive")
        if rm:
            lines.append(f"   NOTE  {tag}: RF receive mode set {'ON' if rm['enabled'] else 'OFF'} first (SetRFReceiveMode: success); the reads below are with it {'on' if rm['enabled'] else 'off'}")
        lines += [f"   OK    {tag} on {r['port']}: home ID {r['home_id']} ({r['home_id_hex']}), own node {r['own_node_id']}"
                 f" ({r['node_id_bits']}-bit IDs), {r['node_count']} node(s) {r['nodes'][:12]}{' …' if r['node_count'] > 12 else ''},"
                 f" {r['role']}{' SIS' if r['sis'] else ''}, SDK {r.get('sdk', '?')} ({r.get('sdk_source', 'unknown')}){ident}"
                 f"{rf_text(r.get('rf') or {})} → {r['verdict'].upper()}"]
        if nd:
            lines.append(f"   NOTE  {tag}: NVM dumped to {nd['file']}: {nd['bytes']} of {nd['size']} bytes ({'32' if nd['ext'] else '16'}-bit ops), sha256 {nd['sha256'][:16]}…")
    else:
        fw = f"{r.get('version', '?')}" + (f" build {r['code_revision']}" if "code_revision" in r else "")
        net = {True: "ON a network", False: "not on a network"}.get(r["on_network"], "cannot tell whether it is on a network")
        zr = r.get("zigbee_reset")
        lines = [] if not zr else [f"   NOTE  {tag}: SYS_RESET_REQ sent first — SYS_RESET_IND after {zr['reset_ind_s']} s (reason {zr['reason']}); the reads below are after the reboot: state {r['device_state_name']} = {'QUIET (not started: it stays off the air until a host starts it)' if r['device_state'] not in ZNP_RUNNING_STATES else 'RUNNING — the firmware started the network by itself'}"]
        lines += [f"   OK    {tag} on {r['port']}: IEEE {r['ieee']}, nwk {r['nwk']}, state {r['device_state_name']}"
                 f" ({r['device_state']}), {r.get('nv_why', '?')} → {net}, firmware {fw} → {r['verdict'].upper()}"]
    lines += [f"   NOTE  {tag}: {n}" for n in r.get("notes", [])]
    return lines


# --------------------------------------------------------------------------------------------- the wipe (--wipe only)
def classify(kind: str, r: dict, args) -> tuple:
    """The read-only probe's answer → ("wipe" | "skip" | "refuse", why) — the module docstring's rules."""
    if not r.get("ok"):
        return "refuse", "it did not answer the read-only probe (%s) — not identified" % r.get("error")
    if kind == "zwave":
        want = args.expect_zwave_home_id
        if r["home_id"] == want:
            return "wipe", "home ID %d = the network's (%s, %d node(s)): the stale copy" % (want, r["home_id_hex"], r["node_count"])
        if r["verdict"] == "blank":
            return "skip", "blank already: home ID %s ≠ the network's %d, only its own node %d" % (r["home_id_hex"], want, r["own_node_id"])
        return "refuse", "ANOTHER network: home ID %d (%s), %d nodes — not the network's %d" % (r["home_id"], r["home_id_hex"], r["node_count"], want)
    want = args.expect_zigbee_ieee
    if r["verdict"] == "live" and r["ieee"] == want:
        return "wipe", "on a network as coordinator IEEE %s = the network's (state %s): the stale copy" % (want, r.get("device_state_name"))
    if r["verdict"] == "blank":
        if r.get("device_state") in ZNP_RUNNING_STATES:
            if r["ieee"] == want:
                # BDBNODEISONANETWORK is deleted before STARTUP_OPTION is written — a stick that reads
                # not-on-a-network yet runs as the network's coordinator holds its network in NV; zigpy-znp's reset is
                # idempotent
                return "wipe", ("reads not on a network but runs as coordinator IEEE %s = the network's (state %s): a "
                                "wipe that stopped before the reset — wipe again" % (want, r.get("device_state_name")))
            return "refuse", ("reads not on a network yet runs (state %s) as IEEE %s ≠ the network's %s — not proven "
                              "the stale copy" % (r.get("device_state_name"), r["ieee"], want))
        if r["ieee"] == want and args.expect_zigbee_extpan and r.get("nv_extpan") == args.expect_zigbee_extpan:
            # deletes done, no STARTUP_OPTION write, no reset — the stick is not running, but Z-Stack only
            # clears the extended PAN at the boot STARTUP_OPTION requests, so NV still holds it here
            return "wipe", ("reads not on a network but NV EXTENDED_PAN_ID still = the network's %s: a wipe that stopped "
                            "before the reset — wipe again" % args.expect_zigbee_extpan)
        return "skip", "blank already: not on a network (%s%s)" % (
            r.get("nv_why"),
            ", NV EXTENDED_PAN_ID %s ≠ the network's" % (r.get("nv_extpan") or "absent") if "nv_extpan" in r else "")
    if r["verdict"] == "live":
        return "refuse", "on a network as ANOTHER coordinator: IEEE %s ≠ the network's %s" % (r["ieee"], want)
    return "refuse", "cannot tell whether it is on a network (%s) — not proven the stale copy" % r.get("nv_why")


def state_of(kind: str, r: dict, args) -> str:
    """What a stick holds now, from a read-only probe: network (the stale copy — also one that reads not-on-a-network but
    runs, or ran, as its coordinator) | blank | partial (an interrupted ZNP wipe: reads not-on-a-network and does not run,
    yet NV still holds the network's extended PAN) | other | unknown."""
    if not r.get("ok"):
        return "unknown"
    if kind == "zwave":
        return "network" if r["home_id"] == args.expect_zwave_home_id else "blank" if r["verdict"] == "blank" else "other"
    if r["verdict"] == "live":
        return "network" if r["ieee"] == args.expect_zigbee_ieee else "other"
    if r["verdict"] == "blank" and r.get("device_state") in ZNP_RUNNING_STATES:
        # M1(a) at the state level: a stick that reads not-on-a-network yet RUNS was started from its NV — it holds a network
        return "network" if r["ieee"] == args.expect_zigbee_ieee else "other"
    if (r["verdict"] == "blank" and r["ieee"] == args.expect_zigbee_ieee and args.expect_zigbee_extpan
            and r.get("nv_extpan") == args.expect_zigbee_extpan):
        return "partial"
    return "blank" if r["verdict"] == "blank" else "unknown"


def session(kind: str, link: Link, args, allow_wipe: bool):
    if kind == "zwave":
        return ZWave(link, args.timeout, Budget(args.budget), allow_wipe=allow_wipe)
    # the EXTENDED_PAN_ID read belongs to the wipe's questions only — a plain probe sends nothing extra
    return ZNP(link, args.timeout, Budget(args.budget), allow_wipe=allow_wipe,
               read_ext_pan=args.expect_zigbee_extpan is not None)


def read_only(kind: str, link: Link, args) -> dict:
    """The probe on an open link, by a session that cannot write (allow_wipe False)."""
    res: dict = {"port": link.spec, "ok": False, "error": None, "verdict": "unknown"}
    t0 = time.monotonic()
    p = session(kind, link, args, False)
    try:
        res.update(p.probe())
        res["ok"] = True
    except ProbeError as e:
        res["error"] = str(e)
    res["notes"], res["sent"], res["seconds"] = p.notes, p.sent, round(time.monotonic() - t0, 2)
    return res


def ident(kind: str, r: dict) -> str:
    if not r.get("ok"):
        return "no answer (%s)" % r.get("error")
    if kind == "zwave":
        return "home ID %d (%s), %d node(s)" % (r["home_id"], r["home_id_hex"], r["node_count"])
    return "IEEE %s, %s, state %s" % (r["ieee"], {True: "ON a network", False: "not on a network"}.get(r.get("on_network"), "on a network: unknown"), r.get("device_state_name"))


def wipe_main(args, kinds) -> int:
    tag = {"zwave": "Z-Wave", "zigbee": "Zigbee"}
    result: dict = {"probe": "zradio-probe.py", "mode": "wipe", "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "expect": {"zwave_home_id": args.expect_zwave_home_id, "zigbee_ieee": args.expect_zigbee_ieee,
                               "zigbee_extpan": getattr(args, "expect_zigbee_extpan", None)}}
    lines: list = []
    links: dict = {}
    rc = 0
    try:
        # 1. every stick identified READ-ONLY first — the decision below rests on these answers alone
        for kind in kinds:
            spec = getattr(args, kind)
            try:
                links[kind] = Link(spec, args.connect_timeout)
                r = read_only(kind, links[kind], args)
            except ProbeError as e:
                r = {"port": spec, "ok": False, "error": str(e), "verdict": "unknown", "notes": [], "sent": [], "seconds": 0}
            plan, why = classify(kind, r, args)
            r["wipe"] = {"plan": plan, "why": why, "result": {"wipe": "pending", "skip": "skipped", "refuse": "refused"}[plan],
                         "state": state_of(kind, r, args)}
            result[kind] = r
            lines += human(kind, r)
            lines.append("   PLAN  %s on %s: %s → %s" % (tag[kind], r["port"], why, {
                "wipe": "WIPE (%s)" % ("zwave-js's hard reset" if kind == "zwave" else "zigpy-znp's network reset"),
                "skip": "SKIP (nothing to wipe)", "refuse": "REFUSED"}[plan]))
        refused = [k for k in kinds if result[k]["wipe"]["plan"] == "refuse"]
        if refused:
            for k in kinds:
                if result[k]["wipe"]["plan"] == "wipe":
                    result[k]["wipe"]["result"] = "not-run"
            lines.append("   FAIL  refused: %s — nothing was written to any stick" % "; ".join(
                "the %s stick: %s" % (tag[k], result[k]["wipe"]["why"]) for k in refused))
            rc = 3
        # 2. the wipes, Z-Wave first; the first failure stops (the other stick is not touched)
        for kind in (kinds if not refused else []):
            w = result[kind]["wipe"]
            if w["plan"] != "wipe":
                continue
            if rc:
                w["result"] = "not-run"
                lines.append("   NOTE  %s on %s: not wiped — the wipe stopped at the failure above" % (tag[kind], result[kind]["port"]))
                continue
            w["at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            p = session(kind, links[kind], args, True)
            err, est = None, None
            try:
                if kind == "zwave":
                    w["detail"] = p.hard_reset(args.reset_timeout or ZW_CALLBACK_TIMEOUT)
                else:
                    w["detail"] = p.network_reset(args.reset_timeout or ZNP_ARSP_TIMEOUT)
            except WipeFailed as e:
                err, est = str(e), e.state
            except ProbeError as e:
                err, est = str(e), "unknown"
            w["sent"], w["notes"] = p.sent, p.notes
            lines += ["   NOTE  %s (wipe): %s" % (tag[kind], n) for n in p.notes]
            # 3. the stick probed again, read-only — what it holds now, whatever happened above
            after = read_only(kind, links[kind], args)
            w["after"] = after
            w["state"] = state_of(kind, after, args) if after["ok"] else (est or "unknown")
            blank = after["ok"] and after["verdict"] == "blank" and (kind != "zwave" or after["home_id"] != args.expect_zwave_home_id)
            if blank and kind == "zigbee" and after.get("device_state") in ZNP_RUNNING_STATES:
                # after the soft reset a ZNP holds (DEV_HOLD) until a host starts it [H: Z-Stack's HOLD_AUTO_START for ZNP
                # builds]: a coordinator that runs again was started from its NV — the network was not cleared
                blank = False
                err = err or "the coordinator runs a network again after the reset (state %s): Z-Stack did not clear it" % after.get("device_state_name")
            if blank and kind == "zigbee" and args.expect_zigbee_extpan and \
                    after.get("nv_extpan") == args.expect_zigbee_extpan:
                # the post-wipe side: Z-Stack clears EXTENDED_PAN_ID at the boot STARTUP_OPTION requested —
                # still holding it, this stick was not cleared (an interrupted wipe reads "not on a network" too)
                blank = False
                err = err or ("NV EXTENDED_PAN_ID still = the network's %s after the reset: Z-Stack did not clear the "
                              "network" % args.expect_zigbee_extpan)
            if kind == "zigbee" and err is not None and w["state"] == "blank":
                # a failed ZNP wipe is never recorded "blank" — BDBNODEISONANETWORK is deleted BEFORE the
                # reset, so the re-probe can read "not on a network" while the network's keys/PAN are still in NV
                w["state"] = est if est and est != "blank" else "partial"
            if err is None and blank:
                w["result"] = "wiped"
                d = w["detail"]
                how = ("HardReset (0x42, callback id 1): ACK after %.1f s, callback after %.1f s%s" % (
                    d["ack_s"], d["callback_s"], ", then SerialAPIStarted" if d.get("serial_api_started") else "") if kind == "zwave" else
                    "zigpy-znp's network reset: deleted %s (absent: %s), STARTUP_OPTION = 0x03, SYS_RESET_IND after %.1f s, "
                    "zigpy-cli's closing reset" % (", ".join(x["id"] for x in d["deleted"]) or "none", ", ".join(d["absent"]) or "none", d["reset_ind_s"]))
                lines.append("   DONE  %s on %s: %s → re-probed: %s → BLANK (wiped)" % (tag[kind], result[kind]["port"], how, ident(kind, after)))
            else:
                w["result"] = "failed"
                lines.append("   FAIL  %s on %s: %s — re-probed now: %s → the stick's state: %s%s" % (
                    tag[kind], result[kind]["port"], err or "the wipe ran, but the stick is not blank", ident(kind, after), w["state"],
                    "" if after["ok"] else " (the probe after the wipe did not answer: power-cycle the stick, then run the wipe again)"))
                rc = 1
    finally:
        for link in links.values():
            link.close()
    print("\n".join(lines), file=sys.stderr if args.json else sys.stdout)
    if args.json:
        print(json.dumps(result, indent=1, sort_keys=True))
    return rc


def ieee_arg(v: str) -> str:
    v = v.strip().lower()
    parts = v.split(":")
    if len(parts) != 8 or not all(len(x) == 2 and all(c in "0123456789abcdef" for c in x) for x in parts):
        raise argparse.ArgumentTypeError("an EUI-64 like 00:12:4b:00:aa:bb:cc:dd")
    return v


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Read-only identification of a Z-Wave Serial API controller and a Z-Stack ZNP coordinator; "
                                            "--wipe (only) blanks the stale copies of a network (the module docstring).")
    p.add_argument("--zwave", metavar="PORT", help="tty path or tcp://host:port of the Z-Wave controller")
    p.add_argument("--zigbee", metavar="PORT", help="tty path or tcp://host:port of the Z-Stack coordinator")
    p.add_argument("--json", action="store_true", help="JSON on stdout (the human lines go to stderr)")
    p.add_argument("--timeout", type=float, default=5.0, help="seconds per command (default 5)")
    p.add_argument("--budget", type=float, default=45.0, help="seconds per radio, all attempts included (default 45)")
    p.add_argument("--connect-timeout", type=float, default=5.0, help="seconds for a tcp:// connect (default 5)")
    p.add_argument("--wipe", action="store_true", help="WRITE: wipe each stick that holds the expected network (identified read-only first)")
    p.add_argument("--soft-reset", action="store_true", help="--zwave, local tty only: SoftReset (0x08) the controller first — it reloads "
                   "its NVM (what makes a raw NVM restore visible); then the normal read-only probe")
    p.add_argument("--rf-receive", choices=("off", "on"), default=None, help="--zwave, local tty only: SetRFReceiveMode (0x10) the "
                   "controller's receiver off|on first (off = a powered, undriven copy ACKs nothing on the air; on again, or any "
                   "restart, undoes it); then the normal read-only probe")
    p.add_argument("--zigbee-reset", action="store_true", help="--zigbee, local tty only: SYS_RESET_REQ (soft) the coordinator first "
                   "— it leaves the air until a host starts it (ZDO_STARTUP_FROM_APP: ZHA's connect); nothing written; then the "
                   "normal read-only probe (device_state says whether it stayed quiet)")
    p.add_argument("--nvm-dump", metavar="FILE", default=None, help="--zwave, local tty only: after the probe, read the controller's NVM "
                   "(Open/Read/Close, as zwave-js backs it up; no RF toggle: for an idle stick) into FILE (0600) — its size and sha256 in the result")
    p.add_argument("--expect-zwave-home-id", type=lambda v: int(v, 0), default=None, metavar="N",
                   help="--wipe: the network's Z-Wave home ID (decimal or 0x…): a controller with it is the stale copy")
    p.add_argument("--expect-zigbee-ieee", type=ieee_arg, default=None, metavar="EUI64",
                   help="--wipe: the network's coordinator IEEE: a coordinator on a network with it is the stale copy")
    p.add_argument("--expect-zigbee-extpan", type=ieee_arg, default=None, metavar="EUI64",
                   help="--wipe --zigbee: the network's extended PAN ID (EUI64): NV still holding it means a wipe that "
                        "stopped between the deletes and the reset")
    p.add_argument("--reset-timeout", type=float, default=None, metavar="S",
                   help="--wipe: the HardReset callback / SYS_RESET_IND bound (default: the drivers' 30 s)")
    args = p.parse_args(argv)
    if not args.zwave and not args.zigbee:
        p.error("give --zwave and/or --zigbee")
    if not args.wipe and (args.expect_zwave_home_id is not None or args.expect_zigbee_ieee
                          or args.expect_zigbee_extpan or (args.reset_timeout is not None and not (args.soft_reset or args.zigbee_reset))):
        p.error("--expect-zwave-home-id, --expect-zigbee-ieee, --expect-zigbee-extpan and --reset-timeout are for --wipe only (--reset-timeout also for --soft-reset / --zigbee-reset)")
    if args.soft_reset:
        if args.wipe or not args.zwave:
            p.error("--soft-reset goes with --zwave (and not with --wipe)")
        if args.zwave.startswith("tcp://"):
            p.error("--soft-reset opens a local tty only: %s is a tcp:// port (through ser2net this would restart the LIVE controller)" % args.zwave)
    if args.rf_receive:
        if args.wipe or not args.zwave:
            p.error("--rf-receive goes with --zwave (and not with --wipe)")
        if args.zwave.startswith("tcp://"):
            p.error("--rf-receive opens a local tty only: %s is a tcp:// port (through ser2net this would silence the LIVE controller)" % args.zwave)
    if args.zigbee_reset:
        if args.wipe or not args.zigbee:
            p.error("--zigbee-reset goes with --zigbee (and not with --wipe)")
        if args.zigbee.startswith("tcp://"):
            p.error("--zigbee-reset opens a local tty only: %s is a tcp:// port (through ser2net this would reboot the LIVE coordinator)" % args.zigbee)
    if args.nvm_dump:
        if args.wipe or not args.zwave:
            p.error("--nvm-dump goes with --zwave (and not with --wipe)")
        if args.zwave.startswith("tcp://"):
            p.error("--nvm-dump opens a local tty only: %s is a tcp:// port (the LIVE stick's NVM is not for dumping through ser2net)" % args.zwave)
    if args.wipe:
        # the wipe's last line of defence. Once a network is copied, the LIVE sticks answer the same home ID and
        # coordinator IEEE as the copy — only the HOST tells them apart, and zradio-probe has no host checks. The
        # wipe therefore runs on local ttys only: a tcp:// port (ser2net) is a usage error, exit 2.
        for k in ("zwave", "zigbee"):
            spec = getattr(args, k)
            if spec and spec.startswith("tcp://"):
                p.error("--wipe opens local ttys only: %s is a tcp:// port — through ser2net this would reach the LIVE "
                        "sticks of the target host" % spec)
        if args.zwave and args.expect_zwave_home_id is None:
            p.error("--wipe --zwave needs --expect-zwave-home-id (the network's home ID: what the stale copy holds)")
        if args.zigbee and not args.expect_zigbee_ieee:
            p.error("--wipe --zigbee needs --expect-zigbee-ieee (the network's coordinator IEEE: what the stale copy holds)")
        if args.zigbee and not args.expect_zigbee_extpan:
            p.error("--wipe --zigbee needs --expect-zigbee-extpan (the network's extended PAN ID: without it a wipe that "
                    "stopped before the reset cannot be told from a blank stick)")
        return wipe_main(args, [k for k in ("zwave", "zigbee") if getattr(args, k)])
    result: dict = {"probe": "zradio-probe.py", "time": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    lines: list[str] = []
    for kind in ("zwave", "zigbee"):
        spec = getattr(args, kind)
        if spec:
            result[kind] = run(kind, spec, args)
            lines += human(kind, result[kind])
    ok = all(result[k]["ok"] for k in ("zwave", "zigbee") if k in result)
    print("\n".join(lines), file=sys.stderr if args.json else sys.stdout)
    if args.json:
        print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
