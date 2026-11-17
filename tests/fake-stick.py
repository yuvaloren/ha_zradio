#!/usr/bin/env python3
"""tests/fake-stick.py — a pretend Z-Wave controller (Serial API) or Z-Stack coordinator (ZNP), for t-probe.sh: just
enough of each protocol for guest/lib/zradio-probe.py's reads, its single-purpose writes and its --wipe.

    fake-stick.py zwave|zigbee <config JSON> <log file>

It serves one end of a pty (the probe opens the other, as it would a stick's tty) and prints the pty's path on stdout
once it is ready. Every frame received is appended to the log as one line ("zwave <func> <payload hex>", "zigbee
<cmd0> <cmd1> <payload hex>"), so a test can say what was sent. It runs until it is killed.
Config, Z-Wave: {"home_id": 3517100996, "nodes": [1, 2, 3]}, and where a test needs them:
  "lr_nodes": [256, 300]   its Long Range nodes (GetLongRangeNodes); "lr": false = a controller without that function;
                           "lr_silent": true = one that lists the function and does not answer it
  "nvm_size": 500          the NVM's size (512); "nvm_max_read": 48 = a read that asks for more is answered with no
                           data (as some SDK versions do); "nvm_stall": 128 = the read at that offset is never answered
Zigbee: {"ieee": "00:12:4b:00:aa:bb:cc:dd", "on_network": true, "ext_pan": "dd:dd:dd:dd:dd:dd:dd:dd", "state": 9};
  "zstack": "1.2" = a Z-Stack Home 1.2 coordinator: no APP_CNF in its capabilities, no BDBNODEISONANETWORK item.
"""
import json, os, select, sys, termios, tty

# Z-Wave Serial API
ZW_SOF, ZW_ACK, ZW_NAK, ZW_CAN = 0x01, 0x06, 0x15, 0x18
ZW_REQUEST, ZW_RESPONSE = 0x00, 0x01
GET_INIT_DATA, GET_CAPABILITIES, SOFT_RESET, GET_PROTOCOL_VERSION = 0x02, 0x07, 0x08, 0x09
SERIAL_API_STARTED, SERIAL_API_SETUP, SET_RF_RECEIVE_MODE = 0x0A, 0x0B, 0x10
GET_CONTROLLER_ID, NVM_OPS, HARD_RESET, GET_LR_NODES = 0x20, 0x2E, 0x42, 0xDA
SETUP_GET_POWERLEVEL16, SETUP_GET_RF_REGION = 0x13, 0x20
NVM_OPEN, NVM_READ, NVM_CLOSE, NVM_OK, NVM_EOF = 0x00, 0x01, 0x03, 0x00, 0xFF
NODEMASK_BYTES = 29
OWN_NODE = 1
API_VERSION, CAPS_SIS = 10, 0b1000
CHIP_800 = 0x08
MANUFACTURER, PRODUCT_TYPE, PRODUCT_ID = 0x0371, 0x0004, 0x003C        # the Aeotec Z-Stick 10 Pro
FIRMWARE = (7, 23)
PROTOCOL = (0, 7, 23, 2)                                              # type, major, minor, patch
RF_REGION_USA_LR = 9
TX_POWER_DECI_DBM = 140                                               # 14.0 dBm
NVM_BYTES = bytes(range(256)) * 2                                     # 512 bytes the dump must return unchanged
LR_FIRST_NODE, LR_MASK_BYTES = 256, 128                               # the firmware's answer: one mask of 1024 nodes, from 256
NVM_CHUNK = 0x40                                                      # bytes a read answers: less than asked, as a real stick does
HOME_ID_AFTER_RESET = 0xE0E1E2E3                                      # a hard reset gives the stick a new home ID
FUNCS = {GET_INIT_DATA, GET_CAPABILITIES, SOFT_RESET, GET_PROTOCOL_VERSION, SERIAL_API_SETUP, SET_RF_RECEIVE_MODE,
         GET_CONTROLLER_ID, NVM_OPS, HARD_RESET}
FUNC_BITMASK_BYTES = 32

# Z-Stack MT (ZNP)
MT_SOF = 0xFE
SREQ_SYS, SRSP_SYS, AREQ_SYS, SREQ_UTIL, SRSP_UTIL = 0x21, 0x61, 0x41, 0x27, 0x67
SYS_PING, SYS_VERSION, NV_READ, NV_DELETE, NV_LENGTH, NV_WRITE_EXT = 0x01, 0x02, 0x08, 0x12, 0x13, 0x1D
SYS_RESET_REQ, SYS_RESET_IND, UTIL_GET_DEVICE_INFO = 0x00, 0x80, 0x00
NV_STARTUP_OPTION, NV_EXT_PAN, NV_ON_NETWORK = 0x0003, 0x002D, 0x0055
NV_FORMATION = (0x0F00, 0x0060, 0x005F)                               # HAS_CONFIGURED_ZSTACK1/3, ZIGPY_ZNP_MIGRATION_ID
STARTUP_CLEAR, STATE_HOLD = 0x03, 0x00
ZNP_CAPS, TRANSPORT, PRODUCT, ZNP_VERSION, CODE_REVISION = 0x0659, 2, 1, (2, 7, 1), 20230507
ZNP_CAPS_12, PRODUCT_12, ZNP_VERSION_12 = 0x0179, 0, (2, 6, 3)        # Z-Stack Home 1.2 on a CC2531, as zigpy-znp's own test fixture
                                                                      # answers: no APP_CNF (1 << 10) among its capabilities
DEVICE_TYPE_COORDINATOR, NWK_COORDINATOR = 0x07, 0x0000
STATUS_OK = 0x00
READ_CHUNK = 4096


def xor(data, start):
    for b in data:
        start ^= b
    return start


class ZWave:
    def __init__(self, cfg):
        self.home_id = cfg.get("home_id", 0xD1A2B3C4)
        self.nodes = list(cfg.get("nodes", [OWN_NODE]))
        self.lr_nodes = list(cfg.get("lr_nodes", []))
        self.lr, self.lr_silent = cfg.get("lr", True), cfg.get("lr_silent", False)
        self.nvm = NVM_BYTES[:cfg.get("nvm_size", len(NVM_BYTES))]
        self.nvm_max_read, self.nvm_stall = cfg.get("nvm_max_read", 0xFF), cfg.get("nvm_stall")
        self.rf_on = True

    @staticmethod
    def frame(typ, func, payload=b""):
        body = bytes([len(payload) + 3, typ, func]) + payload
        return bytes([ZW_SOF]) + body + bytes([xor(body, 0xFF)])

    def feed(self, buf, log):
        """Whole frames out of buf (consumed); what to send back."""
        out = b""
        while buf:
            if buf[0] != ZW_SOF:
                del buf[0]                   # the host's ACK/NAK/CAN, or noise
                continue
            if len(buf) < 2 or len(buf) < buf[1] + 2:
                break
            raw = bytes(buf[:buf[1] + 2])
            del buf[:buf[1] + 2]
            if xor(raw[1:-1], 0xFF) != raw[-1]:
                out += bytes([ZW_NAK])
                continue
            func, pl = raw[3], raw[4:-1]
            log("zwave 0x%02x %s" % (func, pl.hex()))
            out += bytes([ZW_ACK]) + self.answer(func, pl)
        return out

    def answer(self, func, pl):
        r = lambda payload: self.frame(ZW_RESPONSE, func, payload)
        if func == GET_CONTROLLER_ID:
            return r(self.home_id.to_bytes(4, "big") + bytes([OWN_NODE]))
        if func == GET_INIT_DATA:
            mask = bytearray(NODEMASK_BYTES)
            for n in self.nodes:
                mask[(n - 1) // 8] |= 1 << ((n - 1) % 8)
            return r(bytes([API_VERSION, CAPS_SIS, NODEMASK_BYTES]) + bytes(mask) + bytes([CHIP_800, 0]))
        if func == GET_CAPABILITIES:
            bm = bytearray(FUNC_BITMASK_BYTES)
            for f in FUNCS | ({GET_LR_NODES} if self.lr else set()):
                bm[(f - 1) // 8] |= 1 << ((f - 1) % 8)
            return r(bytes(FIRMWARE) + MANUFACTURER.to_bytes(2, "big") + PRODUCT_TYPE.to_bytes(2, "big")
                     + PRODUCT_ID.to_bytes(2, "big") + bytes(bm))
        if func == GET_PROTOCOL_VERSION:
            return r(bytes(PROTOCOL) + bytes(2))
        if func == SERIAL_API_SETUP and pl[:1] == bytes([SETUP_GET_RF_REGION]):
            return r(bytes([SETUP_GET_RF_REGION, RF_REGION_USA_LR]))
        if func == SERIAL_API_SETUP and pl[:1] == bytes([SETUP_GET_POWERLEVEL16]):
            return r(bytes([SETUP_GET_POWERLEVEL16]) + TX_POWER_DECI_DBM.to_bytes(2, "big") + bytes(2))
        if func == SET_RF_RECEIVE_MODE:
            self.rf_on = bool(pl[0])
            return r(bytes([1]))                                       # success
        if func == SOFT_RESET:                                         # no response: the restart says so
            return self.frame(ZW_REQUEST, SERIAL_API_STARTED, bytes(3))
        if func == GET_LR_NODES and self.lr and not self.lr_silent:    # [more nodes, segment, mask length, mask]: all in segment 0
            mask = bytearray(LR_MASK_BYTES)
            for n in self.lr_nodes if pl[0] == 0 else []:
                mask[(n - LR_FIRST_NODE) // 8] |= 1 << ((n - LR_FIRST_NODE) % 8)
            return r(bytes([0, pl[0], LR_MASK_BYTES]) + bytes(mask))
        if func == HARD_RESET:                                         # the callback, with the request's callback id
            self.home_id, self.nodes, self.lr_nodes = HOME_ID_AFTER_RESET, [OWN_NODE], []
            return self.frame(ZW_REQUEST, HARD_RESET, pl[:1])
        if func == NVM_OPS:
            cmd = pl[0]
            if cmd == NVM_OPEN:
                return r(bytes([NVM_OK, 0]) + len(self.nvm).to_bytes(2, "big"))
            if cmd == NVM_READ:
                off = int.from_bytes(pl[2:4], "big")
                if off == self.nvm_stall:
                    return b""                                         # ACKed, never answered
                data = self.nvm[off:off + min(pl[1], NVM_CHUNK)] if pl[1] <= self.nvm_max_read else b""
                st = NVM_EOF if data and off + len(data) >= len(self.nvm) else NVM_OK
                return r(bytes([st, len(data)]) + off.to_bytes(2, "big") + data)
            if cmd == NVM_CLOSE:
                return r(bytes([NVM_OK, 0, 0, 0]))
        return b""                                                     # anything else: ACKed, not answered


class ZNP:
    def __init__(self, cfg):
        self.ieee = bytes(reversed(bytes.fromhex(cfg.get("ieee", "00:12:4b:00:aa:bb:cc:dd").replace(":", ""))))
        self.state = cfg.get("state", 9)
        self.old = cfg.get("zstack") == "1.2"
        self.nv = {NV_STARTUP_OPTION: bytes([0])}
        if cfg.get("on_network", True):
            self.nv.update({i: bytes([0x55]) for i in NV_FORMATION})
            if not self.old:
                self.nv[NV_ON_NETWORK] = bytes([1])
        if cfg.get("ext_pan"):
            self.nv[NV_EXT_PAN] = bytes(reversed(bytes.fromhex(cfg["ext_pan"].replace(":", ""))))

    @staticmethod
    def frame(cmd0, cmd1, payload=b""):
        body = bytes([len(payload), cmd0, cmd1]) + payload
        return bytes([MT_SOF]) + body + bytes([xor(body, 0)])

    def feed(self, buf, log):
        out = b""
        while buf:
            if buf[0] != MT_SOF:
                del buf[0]                   # the bootloader-skip byte, or noise
                continue
            if len(buf) < 2 or len(buf) < buf[1] + 5:
                break
            raw = bytes(buf[:buf[1] + 5])
            del buf[:buf[1] + 5]
            if xor(raw[1:-1], 0) != raw[-1]:
                continue
            c0, c1, pl = raw[2], raw[3], raw[4:-1]
            log("zigbee 0x%02x 0x%02x %s" % (c0, c1, pl.hex()))
            out += self.answer(c0, c1, pl)
        return out

    def answer(self, c0, c1, pl):
        nv_id = int.from_bytes(pl[0:2], "little")
        if (c0, c1) == (SREQ_SYS, SYS_PING):
            return self.frame(SRSP_SYS, c1, (ZNP_CAPS_12 if self.old else ZNP_CAPS).to_bytes(2, "little"))
        if (c0, c1) == (SREQ_SYS, SYS_VERSION):
            return self.frame(SRSP_SYS, c1, bytes((TRANSPORT, PRODUCT_12) + ZNP_VERSION_12 if self.old else (TRANSPORT, PRODUCT) + ZNP_VERSION)
                              + CODE_REVISION.to_bytes(4, "little"))
        if (c0, c1) == (SREQ_UTIL, UTIL_GET_DEVICE_INFO):
            return self.frame(SRSP_UTIL, c1, bytes([STATUS_OK]) + self.ieee + NWK_COORDINATOR.to_bytes(2, "little")
                              + bytes([DEVICE_TYPE_COORDINATOR, self.state, 0]))
        if (c0, c1) == (SREQ_SYS, NV_LENGTH):
            return self.frame(SRSP_SYS, c1, len(self.nv.get(nv_id, b"")).to_bytes(2, "little"))
        if (c0, c1) == (SREQ_SYS, NV_READ):
            v = self.nv.get(nv_id, b"")
            return self.frame(SRSP_SYS, c1, bytes([STATUS_OK, len(v)]) + v)
        if (c0, c1) == (SREQ_SYS, NV_DELETE):
            self.nv.pop(nv_id, None)
            return self.frame(SRSP_SYS, c1, bytes([STATUS_OK]))
        if (c0, c1) == (SREQ_SYS, NV_WRITE_EXT):
            n = int.from_bytes(pl[4:6], "little")
            self.nv[nv_id] = pl[6:6 + n]
            return self.frame(SRSP_SYS, c1, bytes([STATUS_OK]))
        if (c0, c1) == (AREQ_SYS, SYS_RESET_REQ):
            if self.nv.get(NV_STARTUP_OPTION) == bytes([STARTUP_CLEAR]):   # Z-Stack clears the network at this boot
                for i in (NV_ON_NETWORK, NV_EXT_PAN) + NV_FORMATION:
                    self.nv.pop(i, None)
                self.nv[NV_STARTUP_OPTION] = bytes([0])
            self.state = STATE_HOLD                                    # a ZNP holds after a reset until a host starts it
            return self.frame(AREQ_SYS, SYS_RESET_IND, bytes([0, TRANSPORT, PRODUCT]) + bytes(ZNP_VERSION))
        return b""


def main():
    kind, cfg, logf = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
    stick = (ZWave if kind == "zwave" else ZNP)(cfg)

    def log(line):
        with open(logf, "a") as f:
            f.write(line + "\n")

    open(logf, "a").close()
    master, slave = os.openpty()
    tty.setraw(slave)                        # kept open: the master never sees the far end go away between probes
    a = termios.tcgetattr(slave)
    a[2] |= termios.HUPCL                    # as a serial port starts out (a pty does not): "drop DTR and RTS at the last close"
    termios.tcsetattr(slave, termios.TCSANOW, a)
    print(os.ttyname(slave), flush=True)
    buf = bytearray()
    while True:
        select.select([master], [], [])
        buf += os.read(master, READ_CHUNK)
        reply = stick.feed(buf, log)
        if reply:
            os.write(master, reply)


if __name__ == "__main__":
    main()
