#!/usr/bin/env python3
"""zradio-probe.py — identify a Z-Wave / Zigbee USB stick, read-only: a Z-Wave controller (Silicon Labs Serial API) and a
TI Z-Stack coordinator (ZNP, the Monitor and Test API). A few single-purpose writes exist behind their own flags; with
--wipe (only), a stick that holds a named network is blanked. Stdlib only (Python >= 3.9).

    zradio-probe.py --zwave /dev/zradio-zwave --zigbee /dev/zradio-zigbee     # the ttys (nothing else may hold them)
    ... --json                                                                # JSON on stdout, the human lines on stderr
  one write each, then the same reads:
    --soft-reset          Z-Wave SoftReset: the controller restarts and reloads its NVM (zradio-apply, after a restore)
    --rf-receive off|on   Z-Wave SetRFReceiveMode: the receiver off silences a standby's stick (zradio-serve, -sync, -apply)
    --zigbee-reset        ZNP SYS_RESET_REQ: the coordinator leaves the air until a host starts it (zradio-serve)
    --nvm-dump FILE       Z-Wave NVM read (Open/Read/Close), 0600 (zradio-sync's read; no write)
  for a person, run by no tool of the kit:
    --wipe --zwave TTY --zigbee TTY --expect-zwave-home-id N --expect-zigbee-ieee EUI64 --expect-zigbee-extpan EUI64

Who runs it: zradio-detect (the plain reads: which stick is what), zradio-serve (--rf-receive, --zigbee-reset, the plain
Zigbee read), zradio-sync (--rf-receive, --nvm-dump) and zradio-apply (--rf-receive, --soft-reset, the plain Z-Wave
read). --wipe and its --expect-* flags are for a person: the hand tool that blanks a retired stick, or the standby's
stick of a "served only" family (docs/DESIGN.md).

Local ttys only. A network port (ser2net's) leads to the stick of the VM that serves: once a network is copied, the
live stick and its copy answer the same identities, and only the host tells them apart; and ser2net hands its port to
the newest client, so even a read there would take the stick from Home Assistant. A port spec with "://" is a usage error.

Exit: 0 every radio asked for answered its mandatory reads; 1 one did not (or its tty is locked by another process);
2 usage. --wipe: 0 every stick wiped (and re-probed blank) or blank already; 1 a wipe failed (the other stick untouched);
3 refused — nothing was written to any stick. Times: --timeout per command (5 s), --budget per radio and phase (45 s);
--reset-timeout overrides the HardReset callback / SYS_RESET_IND bound (the drivers' 30 s).

What it may send:
  - reads: the functions in ZW_READ_ONLY / ZNP_READ_ONLY, and of SerialAPISetup and the NVM functions only the
    sub-commands in ZW_SETUP_GETS / ZW_NVM_READS. ZWave.request() and ZNP._exchange() — the one path every read takes
    to the wire — refuse anything else before a byte is sent.
  - each single-purpose write (SoftReset, SetRFReceiveMode, SYS_RESET_REQ) is sent by its own function, which writes
    its one frame itself and first checks that this session's flag allowed it (ZWave.allow_*, ZNP.allow_reset).
  - the wipe's writes (HardReset by ZWave.hard_reset; ZNP_WIPE through _exchange, with exactly zigpy-znp's NV items and
    value) only in a session made with --wipe.
  - the modem lines: the probe sets none, and clears HUPCL on the port so that closing it does not drop DTR and RTS
    (boards that wire them to the radio's reset or bootloader pins take a change for a command). Not avoided: Linux
    raises both lines when a port is opened — a change where they were down (a port not opened since it was plugged
    in, or one whose last user closed it with HUPCL set).

The wipe (a retired stick, or the standby stick of a "served only" family). Every stick is first probed read-only:
  Z-Wave  home ID = --expect-zwave-home-id -> the stale copy: wipe; only its own node (another home ID) -> blank: skip;
          anything else (another network, a node list that could not be read, no answer) -> refuse
  Zigbee  on a network as --expect-zigbee-ieee -> wipe; not on a network, not running, NV EXTENDED_PAN_ID not the
          network's -> blank: skip; not on a network but still running as that IEEE, or NV still holding the
          network's extended PAN (a wipe that stopped between the deletes and the reset) -> wipe again;
          anything else -> refuse
One refusal: nothing is written to any stick (exit 3). Then, Z-Wave first, each stale stick is wiped exactly as its
upstream driver does it and probed again; the first failure stops, and the result says what state the stick may be in.
  Z-Wave  zwave-js 15.29's hard reset: HardReset (0x42) [callback id 1], sent ONCE (a lost ACK is a FAIL whose
          re-probe decides), its ACK within 1.6 s, its callback within 30 s. Not sent: zwave-js's setControllerNIF
          before it and its "reset locally" notification to the nodes (from a stale copy that would reach the live
          network's nodes).
  Zigbee  zigpy-znp 1.1.0's reset_network_info + zigpy-cli's cleanup: SYS_OSAL_NV_DELETE of four items in order
          (ZNP_WIPE_DELETE_IDS, each only when NV_LENGTH says it exists), SYS_OSAL_NV_WRITE_EXT STARTUP_OPTION = 0x03
          (clear state and config), SYS_RESET_REQ (soft) and its SYS_RESET_IND within 30 s, then one more reset, not
          awaited. Each SREQ is sent once, 15 s at most.
  blank afterward: Z-Wave, a home ID other than the network's and only its own node; Zigbee, not on a network, not
  running as a coordinator, and NV EXTENDED_PAN_ID not the network's.

Why it reads the way it does:
  - Z-Wave: one NAK first, as zwave-js resets the link at startup; every frame received is ACKed; a request not ACKed
    within 1.6 s, or answered NAK/CAN, is sent again (3 attempts). A stick just powered on answers CAN and repeats
    SerialAPIStarted until ACKed: settle() answers that first.
  - Z-Wave verdict: live = a node other than the controller's own in either list — the classic one (ids 1-232,
    GetSerialApiInitData) or the Long Range one (ids 256+, GetLongRangeNodes, asked where the controller's function
    list has it: a network of Long Range devices only has nothing in the classic list). blank = neither has one.
    unknown, never blank = the classic list is empty of others and the Long Range list could not be read.
  - ZNP: the bootloader-skip byte 0xEF first (zigpy-znp toggles RTS/DTR as well; this does not).
  - ZNP verdict. Z-Stack 3 (SYS_PING's capabilities have APP_CNF: zigpy-znp's detect_zstack_version):
    BDBNODEISONANETWORK absent or not 0x01 = blank; 0x01 = live; a read that answers another status = unknown, never
    blank. That is the second half of zigpy-znp's rule (_load_network_info): it reads the NIB first, and calls a
    network not formed when the NIB has no channel or no key — so every stick blank here is not formed there, and
    one live here may still be not formed there. Z-Stack Home 1.2 (no APP_CNF; CC2531/CC2530) has no such item, and
    zigpy-znp judges it by the NIB alone, which this probe does not read: unknown, never blank.
References read: zwave-js 15.29.0 (packages/serial, packages/zwave-js Driver.ts) and 15.32.3 (Controller.ts
backupNVMRaw700 and getLongRangeNodes, GetLongRangeNodesMessages.ts), Silicon Labs' Serial API firmware
(simplicity_sdk zwave_ncp_serial_api/cmds_management.c: the GetLongRangeNodes answer) and zigpy-znp 1.1.0 (frames.py,
commands/, types/, api.py, nvram.py). [V] = verified on the reference sticks; [H] = not verified.
"""
from __future__ import annotations

import argparse
import hashlib
import errno
import fcntl
import json
import os
import select
import signal
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
# the GETs only: SetRFRegion 0x40 / SetPowerlevel 0x04 are never sent
ZW_SETUP_GETS = {ZW_SETUP_GET_SUPPORTED, ZW_SETUP_GET_POWERLEVEL, ZW_SETUP_GET_POWERLEVEL16, ZW_SETUP_GET_RF_REGION}
ZW_GET_LR_NODES = 0xDA             # FunctionType.GetLongRangeNodes: REQUEST [segment] → RESPONSE [more nodes 0|1, segment, mask
                                   # length, mask…]; bit 0 of segment n = node 256 + 128 n (GetLongRangeNodesMessages.ts). The
                                   # firmware answers one mask of all its nodes in segment 0 and "no more" (cmds_management.c)
                                   # [H: read in the two sources, not yet asked of a stick]
ZW_LR_FIRST_NODE, ZW_LR_NODES_PER_SEGMENT, ZW_LR_MAX_NODE = 256, 128, 4000   # getFirstNodeId; consts.ts NUM_LR_NODES_PER_SEGMENT, MAX_NODES_LR
ZW_LR_SEGMENTS = (ZW_LR_MAX_NODE - ZW_LR_FIRST_NODE) // ZW_LR_NODES_PER_SEGMENT + 1   # as far as a stick that always says "more" is followed
ZW_RF_REGIONS = {0: "Europe", 1: "USA", 2: "Australia/New Zealand", 3: "Hong Kong", 5: "India", 6: "Israel", 7: "Russia",
                 8: "China", 9: "USA (Long Range)", 11: "Europe (Long Range)", 32: "Japan", 33: "Korea", 254: "Unknown",
                 255: "Default (EU)"}   # zwave-js RFRegion enum, the driver's names
ZW_NVM_OPS = 0x2E                  # FunctionType.NVMOperations (700+): [cmd, length, offset u16, data…]
ZW_NVM_OPS_EXT = 0x3D              # FunctionType.ExtendedNVMOperations: the same with a u32 offset
ZW_NVM_OPEN, ZW_NVM_READ, ZW_NVM_CLOSE = 0x00, 0x01, 0x03          # NVMOperationsCommand; Write (0x02) is never sent
ZW_NVM_READS = {ZW_NVM_OPEN, ZW_NVM_READ, ZW_NVM_CLOSE}
ZW_NVM_STATUS = {0x00: "OK", 0x01: "Error", 0x02: "OperationMismatch", 0x03: "OperationInterference",
                 0x04: "SubCommandNotSupported", 0xFF: "EndOfFile"}
ZW_NVM_CHUNK, ZW_NVM_FALLBACK_CHUNK = 0xFF, 48   # backupNVMRaw700: the first read's length; FALLBACK_NVM_CHUNK_SIZE
ZW_NVM_CLOSE_S = 3.0               # the Close's own time, whatever is left of the budget (under the 5 s zradio-sync's
                                   # `timeout -k 5` gives between its SIGTERM and its SIGKILL)
ZW_READ_ONLY = {ZW_GET_INIT_DATA, ZW_GET_CAPABILITIES, ZW_GET_PROTOCOL_VERSION, ZW_GET_CONTROLLER_VERSION, ZW_GET_CONTROLLER_ID,
                ZW_GET_LR_NODES, ZW_SERIAL_API_SETUP, ZW_NVM_OPS, ZW_NVM_OPS_EXT}
# of these, the functions that carry a sub-command, and the sub-commands that are reads (request() refuses the others)
ZW_READ_SUBS = {ZW_SERIAL_API_SETUP: ZW_SETUP_GETS, ZW_NVM_OPS: ZW_NVM_READS, ZW_NVM_OPS_EXT: ZW_NVM_READS}
ZW_SOFT_RESET = 0x08               # FunctionType.SoftReset: the controller restarts and reloads its NVM (what activates a
                                   # restored NVM image). A WRITE of its own kind (a restart, no data): --soft-reset only
ZW_HARD_RESET = 0x42               # FunctionType.HardReset — a WRITE: --wipe only
ZW_SET_RF_RECEIVE_MODE = 0x10      # FunctionType.SetRFReceiveMode: REQUEST [enabled 0|1] → RESPONSE [success] (zwave-js's
                                   # toggleRF, what it sends around an NVM restore). The
                                   # receiver off = the stick ACKs nothing on the air (a powered copy goes quiet): --rf-receive only
ZW_SERIAL_API_STARTED = 0x0A       # FunctionType.SerialAPIStarted: sent by the stick after a restart
ZW_WIPE = {ZW_HARD_RESET}          # the only Z-Wave write this tool can send (with --wipe)
ZW_CALLBACK_TIMEOUT = 30.0         # zwave-js timeouts.sendDataCallback: the callback wait
ZW_NODEMASK_BYTES = 29             # NUM_NODEMASK_BYTES: "Controller Nodes MUST set this field to 29"
ZW_ACK_TIMEOUT = 1.6               # zwave-js timeouts.ack (1600 ms)
ZW_ACK_CAP = 8.0             # s: the longest one wait for an ACK lasts, however many other frames the stick sends meanwhile
ZW_ATTEMPTS = 3                    # zwave-js attempts.controller
ZW_BUSY_ATTEMPTS = 6               # this tool's own sends (SoftReset, SetRFReceiveMode) on a stick busy with the mesh's frames

MT_SOF = 0xFE                      # frames.py TransportFrame.SOF
MT_SREQ, MT_AREQ, MT_SRSP = 0x20, 0x40, 0x60   # CommandType SREQ=1, AREQ=2, SRSP=3, shifted into CMD0's top 3 bits
MT_SYS, MT_UTIL, MT_RPC = 0x01, 0x07, 0x00     # Subsystem.SYS, Subsystem.UTIL, Subsystem.RPCError
MT_SKIP_BOOTLOADER = 0xEF          # ubl.py BootloaderRunMode.FORCE_RUN
ZNP_SYS_PING, ZNP_SYS_VERSION, ZNP_SYS_OSAL_NV_READ, ZNP_SYS_OSAL_NV_LENGTH = 0x01, 0x02, 0x08, 0x13   # commands/sys.py
ZNP_UTIL_GET_DEVICE_INFO = 0x00                                       # commands/util.py
ZNP_READ_ONLY = {(MT_SYS, ZNP_SYS_PING), (MT_SYS, ZNP_SYS_VERSION), (MT_SYS, ZNP_SYS_OSAL_NV_READ), (MT_SYS, ZNP_SYS_OSAL_NV_LENGTH),
                 (MT_UTIL, ZNP_UTIL_GET_DEVICE_INFO)}
MT_CAP_APP_CNF = 1 << 10           # types/commands.py MTCapabilities.APP_CNF: "Z-Stack 1.2 does not have the AppConfig
                                   # subsystem" (api.py detect_zstack_version: the bit absent = 1.2, present = 3.0 or 3.30+)
                                   # [H: zigpy-znp's own fixtures answer 0x0659 for Z-Stack 3 and 0x0179 for a CC2531 on
                                   # 1.2 (tests/conftest.py); no 1.2 stick was asked by this probe]
NV_BDBNODEISONANETWORK = 0x0055    # types/nvids.py OsalNvIds.BDBNODEISONANETWORK ("bdbNodeIsOnANetwork attribute"): Z-Stack 3 only
NV_EXT_PAN_ID = 0x002D             # types/nvids.py OsalNvIds.EXTENDED_PAN_ID — read-only on the wipe path: an interrupted
                                   # wipe (deletes done, no STARTUP_OPTION write, no reset) leaves the network's value here
# the wipe (zigpy-znp's reset_network_info; the WRITE commands — --wipe only, these items only)
ZNP_SYS_OSAL_NV_DELETE, ZNP_SYS_OSAL_NV_WRITE_EXT = 0x12, 0x1D                      # commands/sys.py
ZNP_SYS_RESET_REQ, ZNP_SYS_RESET_IND = 0x00, 0x80                                  # AREQs: commands/sys.py
ZNP_WIPE = {(MT_SYS, ZNP_SYS_OSAL_NV_DELETE), (MT_SYS, ZNP_SYS_OSAL_NV_WRITE_EXT)}  # the SREQ writes (+ the AREQ reset)
NV_HAS_CONFIGURED_ZSTACK1, NV_HAS_CONFIGURED_ZSTACK3 = 0x0F00, 0x0060                # types/nvids.py OsalNvIds
NV_ZIGPY_ZNP_MIGRATION_ID, NV_STARTUP_OPTION = 0x005F, 0x0003
# the items reset_network_info deletes, in its order
ZNP_WIPE_DELETE_IDS = (NV_HAS_CONFIGURED_ZSTACK1, NV_HAS_CONFIGURED_ZSTACK3, NV_ZIGPY_ZNP_MIGRATION_ID, NV_BDBNODEISONANETWORK)
STARTUP_CLEAR = 0x03               # StartupOptions.ClearState (1 << 1) | ClearConfig (1 << 0)
RESET_SOFT = 0x01                  # ResetType.Soft
ZNP_WRITE_TIMEOUT = 15.0           # zigpy-znp sync_request_timeout: an SREQ's SRSP (ZNP.request: sent once)
ZNP_ARSP_TIMEOUT = 30.0            # zigpy-znp async_response_timeout: request_callback_rsp's bound (the SYS_RESET_IND)
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
    """A byte stream to a stick: a tty path (raw 115200 8N1, flock'd)."""

    def __init__(self, spec: str):
        self.spec = spec
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
            # HUPCL off: with it (a port's default) the kernel drops DTR and RTS at the last close, and each probe would
            # end with a pulse on lines some boards wire to the radio's reset or bootloader pins. The setting stays
            # with the port until a program sets its own.
            a[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.HUPCL | getattr(termios, "CRTSCTS", 0))
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
                n = os.write(self.fd, view)
            except BlockingIOError:
                continue
            except OSError as e:
                raise ProbeError(f"{self.spec}: write failed: {e}") from None
            view = view[n:]

    def read_some(self, deadline: float) -> bytes:
        """Bytes that arrive before the deadline (b'' on timeout); the device going away is an error."""
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return b""
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return b""
            try:
                chunk = os.read(self.fd, 4096)
            except BlockingIOError:
                continue
            except OSError as e:
                if e.errno == errno.EIO:
                    raise ProbeError(f"{self.spec}: I/O error (the device went away?)") from None
                raise ProbeError(f"{self.spec}: read failed: {e}") from None
            if not chunk:
                raise ProbeError(f"{self.spec}: end of file (the device went away?)")
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
        self.funcs = None                     # the functions the stick lists (GetSerialApiCapabilities), once probe() read them
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
        # the read-only promise, enforced here: every read goes to the wire through this function and no other
        if func not in ZW_READ_ONLY:
            raise ProbeError(f"refusing to send Z-Wave function 0x{func:02x}: not a read-only query")
        if func in ZW_READ_SUBS and (not payload or payload[0] not in ZW_READ_SUBS[func]):
            raise ProbeError(f"refusing to send Z-Wave function 0x{func:02x} with sub-command {payload[:1].hex() or '(none)'}: not a read")
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
            cap = time.monotonic() + ZW_ACK_CAP        # frames that keep coming must not keep this waiting for ever
            while True:
                u = self._next(min(time.monotonic() + ZW_ACK_TIMEOUT, cap))
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
            cap = time.monotonic() + ZW_ACK_CAP        # frames that keep coming must not keep this waiting for ever
            while True:
                u = self._next(min(time.monotonic() + ZW_ACK_TIMEOUT, cap))
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
        """zwave-js's HardResetRequest, as its controller sends it (see the module docstring): REQUEST 0x42
        [callback id 1], ONE attempt, the ACK, then the callback REQUEST 0x42 [1]. Raises WipeFailed with the state the
        stick may be in; returns the timings. A WRITE: refused unless this session was made with --wipe."""
        if not self.allow_wipe or ZW_HARD_RESET not in ZW_WIPE:
            raise ProbeError("refusing to send Z-Wave function 0x42 (HardReset): a write, and this is not --wipe")
        cb = 1                                   # a zwave-js session's first callback id
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
            # one attempt only, as zwave-js: a NAK/CAN means the stick did not take the frame; no ACK, that it may
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
            if typ == ZW_REQUEST and fn == ZW_HARD_RESET and pl[:1] == bytes([cb]):   # the callback for this request
                break
            if typ == ZW_REQUEST and fn == ZW_SERIAL_API_STARTED:
                started = True
                self.notes.append("SerialAPIStarted (0x0a) while waiting for the HardReset callback — ACKed")
                continue
            self.notes.append("while waiting for the HardReset callback: a frame (type %d, func 0x%02x) — ACKed, ignored" % (typ, fn))
        res = {"ack_s": round(t1 - t0, 2), "callback_s": round(time.monotonic() - t1, 2), "serial_api_started": started}
        # a 700/800 stick may restart its Serial API after the reset: give it a moment to say so
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
        """One NVM operation, Open/Read/Close (request() refuses any other): (status, offset_or_size, data)."""
        if cmd == ZW_NVM_READ:
            payload = bytes([cmd, length]) + (offset.to_bytes(4, "big") if ext else offset.to_bytes(2, "big"))
        else:
            payload = bytes([cmd])
        pl = self.request(ZW_NVM_OPS_EXT if ext else ZW_NVM_OPS, f"NVM{'Ext' if ext else ''}Operations/{ {0: 'Open', 1: 'Read', 3: 'Close'}.get(cmd, cmd) }", payload)
        if len(pl) < 2:
            raise ProbeError(f"NVM operation 0x{cmd:02x}: a {len(pl)}-byte answer")
        status, n = pl[0], pl[1]
        w = 4 if ext else 2
        off = int.from_bytes(pl[2:2 + w], "big") if len(pl) >= 2 + w else 0
        data = pl[2 + w:2 + w + n] if n and len(pl) >= 2 + w + n else b""
        return status, off, data

    def nvm_dump(self, funcs) -> dict:
        """The controller's NVM as zwave-js's backupNVMRaw700 reads it — Open; Read 0xff bytes, then in the size the stick
        answers in, never more than is left; a read answered with no data ("some SDK versions return an empty buffer
        when trying to read a buffer that is too long") once more 48 bytes at a time; Close, whatever happened — without
        the RF toggle it does first (this is for an IDLE stick: nothing writes its NVM meanwhile). A read, no RF:
        {"size", "data", "ext"} — the bytes are returned to the caller, never printed."""
        ext = funcs is not None and ZW_NVM_OPS_EXT in funcs
        if funcs is not None and not ext and ZW_NVM_OPS not in funcs:
            raise ProbeError("the stick lists neither NVMOperations (0x2e) nor ExtendedNVMOperations (0x3d)")
        out = bytearray()
        size, chunk, refused = 0, ZW_NVM_CHUNK, False
        try:
            st, size, _ = self.nvm_op(ext, ZW_NVM_OPEN)
            if st != 0:
                refused = True      # the stick said it did not open its NVM: nothing to close
                raise ProbeError(f"NVM open: status {ZW_NVM_STATUS.get(st, st)}")
            while len(out) < size:
                at = len(out)
                st, _, data = self.nvm_op(ext, ZW_NVM_READ, min(chunk, size - at), at)
                if st not in (0x00, 0xFF):
                    raise ProbeError(f"NVM read at {at}: status {ZW_NVM_STATUS.get(st, st)}")
                if not data:
                    if chunk > ZW_NVM_FALLBACK_CHUNK:
                        chunk = ZW_NVM_FALLBACK_CHUNK
                        self.notes.append(f"NVM read at {at}: no data — reading {chunk} bytes at a time")
                        continue
                    if st == 0xFF:      # "a read may legitimately end exactly at the end of the NVM"
                        break
                    raise ProbeError(f"NVM read at {at}: no data (status {ZW_NVM_STATUS.get(st, st)})")
                data = data[:size - at]          # "avoid overflowing the result buffer if the controller returns too much data"
                out += data
                chunk = min(chunk, len(data))
                if st == 0xFF:
                    break
        finally:
            if not refused:
                # zwave-js: "Whatever happens, close the NVM" — also when the budget is spent or SIGTERM stopped the
                # read (run()), so the Close has its own time
                self.budget.end = max(self.budget.end, time.monotonic() + ZW_NVM_CLOSE_S)
                try:
                    self.nvm_op(ext, ZW_NVM_CLOSE)
                except ProbeError as e:
                    self.notes.append(f"NVM close: {e}")
        return {"size": size, "ext": ext, "data": bytes(out)}

    def setup_get(self, sub: int, name: str) -> bytes:
        """SerialAPISetup with one GET sub-command (request() refuses any other); the answer minus its echoed sub-command byte."""
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

    def lr_nodes(self) -> list:
        """The Long Range nodes (ids 256+), as zwave-js's getLongRangeNodes reads them: GetLongRangeNodes segment by
        segment while the stick says there are more. zwave-js asks where SerialAPIStarted said the controller does
        Long Range — seen only after a restart, which a read may not cause; this asks where the function is listed."""
        nodes: list = []
        for segment in range(ZW_LR_SEGMENTS):
            pl = self.request(ZW_GET_LR_NODES, "GetLongRangeNodes", bytes([segment]))
            if len(pl) < 3 or len(pl) < 3 + pl[2]:
                raise ProbeError(f"GetLongRangeNodes: no node list in the answer ({pl.hex()})")
            first = ZW_LR_FIRST_NODE + ZW_LR_NODES_PER_SEGMENT * pl[1]      # by the segment the stick says it answers
            nodes += [first + 8 * j + i for j, byte in enumerate(pl[3:3 + pl[2]]) for i in range(8) if byte & (1 << i)]
            if not pl[0]:
                break
        return sorted({n for n in nodes if n <= ZW_LR_MAX_NODE})   # "the controller may report bits outside the valid range"

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
        # the Long Range nodes are in no list read so far. lr_nodes None = not known: asked and not answered
        out["lr_nodes"] = [] if funcs is not None and ZW_GET_LR_NODES not in funcs else None
        if out["lr_nodes"] is None:
            try:
                out["lr_nodes"] = self.lr_nodes()
            except ProbeError as e:
                self.notes.append(f"GetLongRangeNodes: {e} — the Long Range nodes are not known: this stick is not called blank")
        out["lr_node_count"] = len(out["lr_nodes"] or [])
        own = out["own_node_id"]
        out["verdict"] = "live" if out["nodes"] != [own] or out["lr_nodes"] else "unknown" if out["lr_nodes"] is None else "blank"
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
        so no caller can reach the wire with a write this tool did not authorize."""
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
        # SYS_OSAL_NV_WRITE_EXT: Id u16 LE, Offset u16 LE (not 8 bits), Value LongBytes
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
        """The AREQ SYS_RESET_REQ Type=Soft (zigpy-znp's reset()) — a WRITE (the stick reboots): --wipe or --zigbee-reset only."""
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
        """zigpy-znp's ZNP.reset_network_info(), then zigpy-cli's closing reset (the module docstring).
        Raises WipeFailed with the state the stick may be in. A WRITE: refused unless this session was made with --wipe."""
        if not self.allow_wipe:
            raise ProbeError("refusing the ZNP network reset: writes, and this is not --wipe")
        res: dict = {"deleted": [], "absent": []}
        for nv in ZNP_WIPE_DELETE_IDS:                 # nvram.py osal_delete
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
            ln = self.nv_length(NV_STARTUP_OPTION)    # nvram.py osal_write(create=False)
        except ProbeError as e:
            raise WipeFailed("%s — %s" % (e, state_mid), "unknown") from None
        if ln != 1:
            raise WipeFailed("STARTUP_OPTION (0x0003) has length %d, not 1: zigpy-znp's osal_write raises here (%s) — "
                             "nothing more sent; %s" % (ln, "KeyError" if ln == 0 else "ValueError", state_mid), "unknown")
        try:
            st = self.nv_write_startup()
        except ProbeError as e:
            raise WipeFailed("%s — %s" % (e, state_mid), "unknown") from None
        if st != 0:   # RspStatus=SUCCESS (nvram.py)
            raise WipeFailed("SYS_OSAL_NV_WRITE_EXT(STARTUP_OPTION) answered status 0x%02x, not SUCCESS: STARTUP_OPTION not "
                             "written, no reset sent — %s" % (st, state_mid), "unknown")
        res["startup_option"] = "0x%02x" % STARTUP_CLEAR
        t0 = time.monotonic()
        self.reset_req()                              # api.py reset(): request_callback_rsp(ResetReq, ResetInd)
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
                    raise RPCError(f"{name}: the radio does not recognize it (RPC error {pl[:1].hex()}, request {pl[1:3].hex()})")
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
        if len(pl) < 2 or pl[0] != 0 or len(pl) < 2 + pl[1]:
            raise ProbeError(f"SYS_OSAL_NV_READ(EXTENDED_PAN_ID): status {('0x%02x' % pl[0]) if pl else 'missing'}, {len(pl)} byte(s)")
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
        caps = int.from_bytes(pl[0:2], "little") if len(pl) >= 2 else None
        out["capabilities"] = f"0x{caps:04x}" if caps is not None else None
        # zigpy-znp's detect_zstack_version: no AppConfig subsystem = Z-Stack Home 1.2; with it, 3.0 or 3.30+ ("3" here)
        out["zstack"] = None if caps is None else "3" if caps & MT_CAP_APP_CNF else "1.2"
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
        if out["zstack"] != "3":
            # BDBNODEISONANETWORK is Z-Stack 3's: on Home 1.2 it is absent on a stick that runs a network, and zigpy-znp
            # does not ask for it there (its rule for 1.2 is the NIB, not read here). Absent must not read as blank.
            out["on_network"] = None
            out["verdict"] = "unknown"
            out["nv_why"] = ("Z-Stack Home 1.2 (no APP_CNF in its capabilities %s): it keeps no BDBNODEISONANETWORK" % out["capabilities"]
                             if out["zstack"] else "SYS_PING answered no capabilities: Z-Stack 3 or Home 1.2 is not known, BDBNODEISONANETWORK not asked")
            return out
        # zigpy-znp's test of that item, in its order (nvram.py osal_read): the item's length first — 0 = it does not exist
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


def write_private(path: str, data: bytes) -> None:
    """The file, 0600 from the moment it exists (not made with the umask and narrowed afterward)."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            os.fchmod(fd, 0o600)      # a file that was there keeps its mode otherwise
            f.write(data)
    except OSError as e:
        raise ProbeError(f"--nvm-dump {path}: {e.strerror}") from None


def on_sigterm(signum, frame):
    """SIGTERM while the NVM is open (zradio-sync's `timeout`): an error raised where the read stands, so that nvm_dump's
    finally sends the Close. A second SIGTERM does not stop that Close."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise ProbeError("stopped by SIGTERM")


def run(kind: str, spec: str, args) -> dict:
    budget = Budget(args.budget)
    res: dict = {"port": spec, "ok": False, "error": None, "verdict": "unknown"}
    t0 = time.monotonic()
    link = None
    proto = None
    try:
        link = Link(spec)
        proto = (ZWave if kind == "zwave" else ZNP)(link, args.timeout, budget)
        if kind == "zwave" and args.soft_reset:        # --soft-reset: the restart first, then the reads
            proto.allow_soft_reset = True
            res["soft_reset"] = proto.soft_reset(args.reset_timeout or 5.0)
            proto.allow_soft_reset = False
        if kind == "zwave" and args.rf_receive:        # --rf-receive off|on: the receiver, then the reads
            proto.allow_rf_mode = True
            res["rf_receive"] = proto.rf_receive(args.rf_receive == "on")
            proto.allow_rf_mode = False
        if kind == "zigbee" and args.zigbee_reset:     # --zigbee-reset: the reboot first, then the reads
            proto.allow_reset = True
            res["zigbee_reset"] = proto.quiet(args.reset_timeout or ZNP_ARSP_TIMEOUT)
            proto.allow_reset = False
        res.update(proto.probe())
        if kind == "zwave" and args.nvm_dump:          # --nvm-dump: after the reads, the NVM to a file
            was = signal.signal(signal.SIGTERM, on_sigterm)
            try:
                d = proto.nvm_dump(proto.funcs)
            finally:
                signal.signal(signal.SIGTERM, was)
            write_private(args.nvm_dump, d["data"])
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
        lines = [] if not sr else [
            f"   NOTE  {tag}: SoftReset sent first — ACK in {sr['ack_s']} s, SerialAPIStarted "
            f"{'seen' if sr['serial_api_started'] else 'NOT seen'} after {sr['started_s']} s; the reads below are after the restart"]
        rm = r.get("rf_receive")
        if rm:
            lines.append(f"   NOTE  {tag}: RF receive mode set {'ON' if rm['enabled'] else 'OFF'} first (SetRFReceiveMode: success); "
                         f"the reads below are with it {'on' if rm['enabled'] else 'off'}")
        lines += [f"   OK    {tag} on {r['port']}: home ID {r['home_id']} ({r['home_id_hex']}), own node {r['own_node_id']}"
                 f" ({r['node_id_bits']}-bit IDs), {r['node_count']} node(s) {r['nodes'][:12]}{' …' if r['node_count'] > 12 else ''},"
                 f" {'Long Range nodes not known' if r['lr_nodes'] is None else '%d Long Range node(s)' % r['lr_node_count']},"
                 f" {r['role']}{' SIS' if r['sis'] else ''}, SDK {r.get('sdk', '?')} ({r.get('sdk_source', 'unknown')}){ident}"
                 f"{rf_text(r.get('rf') or {})} → {r['verdict'].upper()}"]
        if nd:
            lines.append(f"   NOTE  {tag}: NVM dumped to {nd['file']}: {nd['bytes']} of {nd['size']} bytes "
                         f"({'32' if nd['ext'] else '16'}-bit ops), sha256 {nd['sha256'][:16]}…")
    else:
        fw = f"{r.get('version', '?')}" + (f" build {r['code_revision']}" if "code_revision" in r else "") + (
            f" (Z-Stack {'Home 1.2' if r['zstack'] == '1.2' else '3'})" if r.get("zstack") else "")
        net = {True: "ON a network", False: "not on a network"}.get(r["on_network"], "cannot tell whether it is on a network")
        zr = r.get("zigbee_reset")
        quiet = r['device_state'] not in ZNP_RUNNING_STATES
        lines = [] if not zr else [
            f"   NOTE  {tag}: SYS_RESET_REQ sent first — SYS_RESET_IND after {zr['reset_ind_s']} s (reason {zr['reason']}); "
            f"the reads below are after the reboot: state {r['device_state_name']} = "
            + ("QUIET (not started: it stays off the air until a host starts it)" if quiet
               else "RUNNING — the firmware started the network by itself")]
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
        if r["verdict"] == "unknown":
            return "refuse", ("home ID %s ≠ the network's %d and only its own node in the classic list, but its Long Range "
                              "nodes could not be read — not proven blank" % (r["home_id_hex"], want))
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
        return ("network" if r["home_id"] == args.expect_zwave_home_id else
                {"blank": "blank", "unknown": "unknown"}.get(r["verdict"], "other"))
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
    net = {True: "ON a network", False: "not on a network"}.get(r.get("on_network"), "on a network: unknown")
    return "IEEE %s, %s, state %s" % (r["ieee"], net, r.get("device_state_name"))


def wipe_main(args, kinds) -> int:
    tag = {"zwave": "Z-Wave", "zigbee": "Zigbee"}
    result: dict = {"probe": "zradio-probe.py", "mode": "wipe", "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "expect": {"zwave_home_id": args.expect_zwave_home_id, "zigbee_ieee": args.expect_zigbee_ieee,
                               "zigbee_extpan": args.expect_zigbee_extpan}}
    lines: list = []
    links: dict = {}
    rc = 0
    try:
        # 1. every stick identified READ-ONLY first — the decision below rests on these answers alone
        for kind in kinds:
            spec = getattr(args, kind)
            try:
                links[kind] = Link(spec)
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
    p.add_argument("--zwave", metavar="TTY", help="the Z-Wave controller's tty")
    p.add_argument("--zigbee", metavar="TTY", help="the Z-Stack coordinator's tty")
    p.add_argument("--json", action="store_true", help="JSON on stdout (the human lines go to stderr)")
    p.add_argument("--timeout", type=float, default=5.0, help="seconds per command (default 5)")
    p.add_argument("--budget", type=float, default=45.0, help="seconds per radio, all attempts included (default 45)")
    p.add_argument("--wipe", action="store_true", help="WRITE: wipe each stick that holds the expected network (identified read-only first)")
    p.add_argument("--soft-reset", action="store_true", help="--zwave: SoftReset (0x08) the controller first — it reloads "
                   "its NVM (what makes a raw NVM restore visible); then the normal read-only probe")
    p.add_argument("--rf-receive", choices=("off", "on"), default=None, help="--zwave: SetRFReceiveMode (0x10) the "
                   "controller's receiver off|on first (off = a powered, undriven copy ACKs nothing on the air; on again, or any "
                   "restart, undoes it); then the normal read-only probe")
    p.add_argument("--zigbee-reset", action="store_true", help="--zigbee: SYS_RESET_REQ (soft) the coordinator first "
                   "— it leaves the air until a host starts it (ZDO_STARTUP_FROM_APP: ZHA's connect); nothing written; then the "
                   "normal read-only probe (device_state says whether it stayed quiet)")
    p.add_argument("--nvm-dump", metavar="FILE", default=None, help="--zwave: after the probe, read the controller's NVM "
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
        p.error("--expect-zwave-home-id, --expect-zigbee-ieee, --expect-zigbee-extpan and --reset-timeout are for --wipe only "
                "(--reset-timeout also for --soft-reset / --zigbee-reset)")
    for k in ("zwave", "zigbee"):
        spec = getattr(args, k)
        if spec and "://" in spec:
            # Once a network is copied, the live stick and its copy answer the same home ID and coordinator IEEE: only
            # the HOST tells them apart, and this tool has no host checks. And ser2net gives its port to the newest
            # client (kickolduser): a read there takes the stick from Home Assistant.
            p.error("this tool opens local ttys only: %s is a network port — through ser2net it would reach the LIVE "
                    "stick of the VM that serves, and take it from Home Assistant" % spec)
    if args.soft_reset and (args.wipe or not args.zwave):
        p.error("--soft-reset goes with --zwave (and not with --wipe)")
    if args.rf_receive and (args.wipe or not args.zwave):
        p.error("--rf-receive goes with --zwave (and not with --wipe)")
    if args.zigbee_reset and (args.wipe or not args.zigbee):
        p.error("--zigbee-reset goes with --zigbee (and not with --wipe)")
    if args.nvm_dump and (args.wipe or not args.zwave):
        p.error("--nvm-dump goes with --zwave (and not with --wipe)")
    if args.wipe:
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
