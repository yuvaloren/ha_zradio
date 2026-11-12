#!/usr/bin/env python3
"""zui-restore.py — an NVM restore onto THIS VM's Z-Wave stick through a LOCAL Z-Wave JS UI: the restoreNVM call of
Z-Wave JS UI's own socket API, against a Z-Wave JS UI that zradio-apply runs in a podman container for the minutes of
the write, on http://127.0.0.1:8091. Runs inside a radio VM; python3 stdlib only (a small socket.io v4 client over one
WebSocket is part of this file).

  python3 zui-restore.py read    [--url http://127.0.0.1:8091] [--wait S]
      the driver's own view, as JSON on stdout: {ready, home_id, home_id_hex, nodes, sdk, firmware, rf_region, tx_power}
      (driverFunction, read-only). --wait S keeps asking until the driver is ready or S seconds pass (exit 1 then).
  python3 zui-restore.py restore --nvm FILE [--mode raw|converting] [--expect-home-id 0x… --expect-nodes N] [--url …] [--wait S]
      1. read (as above; the driver must be ready);
      2. already the expected home ID with the expected node count → "already restored", nothing written, exit 0
         (--force writes anyway: the raw pass that repairs the RF config runs on a stick that already answers right);
      3. restoreNVM(<FILE's bytes>, useRaw); the CONTROLLER_CMD progress lines printed; exit 0 on success.
         --mode raw (useRaw=true): the image written as it is; zwave-js then DESTROYS its driver ("Activating the NVM
         backup requires a driver restart!") and Z-Wave JS UI restarts it. --mode converting (useRaw=false): zwave-js
         backs the TARGET's NVM up, migrates the image into it (migrateNVM) and writes that, then soft-resets and
         restarts its driver itself — the pass that gives a blank stick the image's HOME ID [V Aeotec Z-Stick 10 Pro:
         a raw pass alone left a blank stick on its own home ID with the image's node table]. Both: the CALLER stops
         the container the instant this exits, so a restarted driver never interviews the mesh next to the live
         controller; the stick is then verified with read-only serial reads (zradio-probe.py --soft-reset).
Why the raw pass exists: zwave-js's converting restore copies an image byte-for-byte only when the target's application
version >= its protocol version — true for Silicon Labs reference firmware, false for the Aeotec Z-Stick 10 Pro
(application version 2.0.0): the converted image's RF config was ignored by the 7.23 firmware (region unknown, 0 dBm).
Exit 0 ok, 1 FAIL, 2 usage. Nothing here prints the image or any key.
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time


class HAError(Exception):
    """Z-Wave JS UI answered with an error."""

    def __init__(self, code, message):
        Exception.__init__(self, "%s: %s" % (code, message))
        self.code = code
        self.message = message


class NotAnswering(Exception):
    """No answer (refused, timed out, dropped)."""


class WSTimeout(NotAnswering):
    pass


class WSClosed(NotAnswering):
    pass


def ws_mask(data, key):
    n = len(data)
    if n == 0:
        return b""
    k = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(k, "big")).to_bytes(n, "big")


class WSConn(object):
    def __init__(self, sock, leftover=b""):
        self.sock = sock
        self.buf = bytearray(leftover)
        self.frag_op = None
        self.frag = []

    def send_frame(self, opcode, payload):
        n = len(payload)
        hdr = bytearray([0x80 | opcode])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack("!H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack("!Q", n)
        key = os.urandom(4)
        hdr += key
        try:
            self.sock.sendall(bytes(hdr) + ws_mask(payload, key))
        except socket.timeout:
            raise WSClosed("send timed out")
        except OSError as e:
            raise WSClosed("send failed: %s" % e)

    def send_text(self, text):
        self.sock.settimeout(60)
        self.send_frame(0x1, text.encode("utf-8"))

    def _parse(self):
        b = self.buf
        if len(b) < 2:
            return None
        fin, op, masked, n, i = b[0] & 0x80, b[0] & 0x0F, b[1] & 0x80, b[1] & 0x7F, 2
        if n == 126:
            if len(b) < 4:
                return None
            n, i = struct.unpack("!H", bytes(b[2:4]))[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, i = struct.unpack("!Q", bytes(b[2:10]))[0], 10
        key = None
        if masked:
            if len(b) < i + 4:
                return None
            key, i = bytes(b[i:i + 4]), i + 4
        if len(b) < i + n:
            return None
        payload = bytes(b[i:i + n])
        del b[:i + n]
        if key:
            payload = ws_mask(payload, key)
        return fin, op, payload

    def _fill(self, deadline):
        remaining = deadline - time.time()
        if remaining <= 0:
            raise WSTimeout("no message within the bound")
        self.sock.settimeout(min(remaining, 30.0))
        try:
            data = self.sock.recv(262144)
        except socket.timeout:
            return
        except OSError as e:
            raise WSClosed("receive failed: %s" % e)
        if not data:
            raise WSClosed("the connection was closed")
        self.buf += data

    def recv_text(self, deadline):
        """The next whole text message (continuations joined); pings answered on the way; WSTimeout at the deadline."""
        while True:
            f = self._parse()
            if f is None:
                self._fill(deadline)
                continue
            fin, op, payload = f
            if op == 0x9:                       # ping → pong with the same payload (§5.5.2)
                self.send_frame(0xA, payload)
                continue
            if op == 0xA:                       # unsolicited pong
                continue
            if op == 0x8:                       # close: echo it, then the connection is gone (§5.5.1)
                try:
                    self.send_frame(0x8, payload[:2])
                except NotAnswering:
                    pass
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1005
                raise WSClosed("the WebSocket was closed (code %d)" % code)
            if op in (0x1, 0x2):
                if self.frag_op is not None:
                    raise WSClosed("protocol error: a new message inside a fragmented one")
                if fin:
                    return payload.decode("utf-8")
                self.frag_op, self.frag = op, [payload]
                continue
            if op == 0x0:
                if self.frag_op is None:
                    raise WSClosed("protocol error: a continuation frame without a first frame")
                self.frag.append(payload)
                if fin:
                    data = b"".join(self.frag)
                    self.frag_op, self.frag = None, []
                    return data.decode("utf-8")
                continue
            raise WSClosed("protocol error: opcode %d" % op)

    def close(self):
        try:
            self.sock.settimeout(2)
            self.send_frame(0x8, struct.pack("!H", 1000))
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass




class ZuiSocket(object):
    """socket.io v4 over one WebSocket to a Z-Wave JS UI (what its own web page speaks). Binary attachments travel as
    binary frames (both ways); a Buffer in any event Z-Wave JS UI emits arrives as a binary frame too, so the receive
    loop keeps the opcode and never decodes a binary message as text."""

    def __init__(self, ha, entry, sess, timeout=30.0):
        self.ha, self.timeout = ha, timeout
        self.ack_id = 100
        path = entry.rstrip("/") + "/socket.io/?EIO=4&transport=websocket"
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host = ha.host if ha.port in (80, 443) else "%s:%d" % (ha.host, ha.port)
        try:
            sock = socket.create_connection((ha.host, ha.port), timeout=timeout)
            req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                   "Sec-WebSocket-Version: 13\r\nUser-Agent: zradio\r\n\r\n"
                   % (path, host, key))
            sock.sendall(req.encode("ascii"))
            raw = b""
            deadline = time.time() + timeout
            while b"\r\n\r\n" not in raw:
                if time.time() > deadline or len(raw) > 65536:
                    raise NotAnswering("no WebSocket handshake from Z-Wave JS UI's socket.io")
                chunk = sock.recv(4096)
                if not chunk:
                    raise NotAnswering("the connection closed during the WebSocket handshake")
                raw += chunk
        except OSError as e:
            raise NotAnswering("Z-Wave JS UI's socket.io: %s" % e)
        head, leftover = raw.split(b"\r\n\r\n", 1)
        status = head.decode("latin-1").split("\r\n")[0]
        if status.split()[1:2] != ["101"]:
            sock.close()
            raise NotAnswering("Z-Wave JS UI's socket.io WebSocket answered %r" % status)
        self.ws = WSConn(sock, leftover)
        deadline = time.time() + timeout
        first = self._next(deadline)
        if not first.startswith("0"):
            raise NotAnswering("engine.io: expected the open packet, got %r" % first[:40])
        self.ws.send_text("40")                             # socket.io CONNECT to the default namespace
        while True:
            m = self._next(deadline)
            if m.startswith("40"):
                break
            if m.startswith("44"):
                raise HAError("socket.io", "Z-Wave JS UI refused the connection: %s" % m[2:200])

    def _recv_message(self, deadline):
        """The next whole WebSocket message as (opcode, bytes): pings answered, close honoured, binary kept."""
        ws = self.ws
        while True:
            f = ws._parse()
            if f is None:
                ws._fill(deadline)
                continue
            fin, op, payload = f
            if op == 0x9:
                ws.send_frame(0xA, payload)
                continue
            if op == 0xA:
                continue
            if op == 0x8:
                try:
                    ws.send_frame(0x8, payload[:2])
                except Exception:
                    pass
                raise WSClosed("Z-Wave JS UI closed the WebSocket")
            if op in (0x1, 0x2):
                if ws.frag_op is not None:
                    raise WSClosed("protocol error: a new message inside a fragmented one")
                if fin:
                    return op, payload
                ws.frag_op, ws.frag = op, [payload]
                continue
            if op == 0x0:
                if ws.frag_op is None:
                    raise WSClosed("protocol error: a continuation frame without a first frame")
                ws.frag.append(payload)
                if fin:
                    op0, data = ws.frag_op, b"".join(ws.frag)
                    ws.frag_op, ws.frag = None, []
                    return op0, data
                continue
            raise WSClosed("protocol error: opcode %d" % op)

    def _next(self, deadline):
        """The next socket.io TEXT message; engine.io pings answered; binary attachments skipped (never decoded);
        events are left to the caller (INIT carries the network keys — never printed)."""
        while True:
            op, payload = self._recv_message(deadline)
            if op == 0x2:
                continue
            m = payload.decode("utf-8", "replace")
            if m == "2":
                self.ws.send_text("3")
                continue
            return m

    def call(self, api, args, timeout=None, on_event=None, binary=None):
        """ZWAVE_API {api, args} with an ack -> Z-Wave JS UI's {success, message, result}. binary: one attachment
        (bytes) replacing the args' {"_placeholder": true, "num": 0}."""
        self.ack_id += 1
        aid = self.ack_id
        payload = {"api": api, "args": args}
        if binary is None:
            self.ws.send_text("42%d%s" % (aid, json.dumps(["ZWAVE_API", payload])))
        else:
            self.ws.send_text("451-%d%s" % (aid, json.dumps(["ZWAVE_API", payload])))
            self.ws.sock.settimeout(60)
            self.ws.send_frame(0x2, binary)
        deadline = time.time() + (timeout or self.timeout)
        want = "43%d" % aid
        while True:
            m = self._next(deadline)
            if m.startswith(want) or (m.startswith("46") and ("-%d[" % aid) in m[:16]):
                body = json.loads(m[m.index("["):])
                return body[0] if isinstance(body, list) and body else body
            if m.startswith("42") and on_event:
                try:
                    ev = json.loads(m[2:])
                    on_event(ev[0], ev[1] if len(ev) > 1 else None)
                except (ValueError, IndexError):
                    pass

    def close(self):
        self.ws.close()




READ_CODE = ("const c = driver.controller; "
             "return {ready: driver.ready, homeId: c.homeId, nodes: c.nodes.size, sdk: c.sdkVersion, "
             "fw: c.firmwareVersion, rfRegion: c.rfRegion, txPower: c.txPower};")


def stub(url):
    """host and port of the local Z-Wave JS UI, as ZuiSocket reads them."""
    if not url.startswith("http://"):
        print("usage error: --url must be http://host:port (the local container; no TLS)", file=sys.stderr)
        sys.exit(2)
    hp = url[len("http://"):].rstrip("/")
    host, _, port = hp.partition(":")
    return argparse.Namespace(host=host, port=int(port or 80))


def read_once(ha, timeout):
    sock = ZuiSocket(ha, "", "", timeout=timeout)
    try:
        res = sock.call("driverFunction", [READ_CODE], timeout=timeout)
    finally:
        sock.close()
    if not isinstance(res, dict) or not res.get("success"):
        raise HAError("driverFunction", "%s" % (res.get("message") if isinstance(res, dict) else res))
    r = res.get("result") or {}
    hid = r.get("homeId")
    return {"ready": bool(r.get("ready")), "home_id": hid, "home_id_hex": (hex(int(hid)) if hid is not None else None),
            "nodes": r.get("nodes"), "sdk": r.get("sdk"), "firmware": r.get("fw"), "rf_region": r.get("rfRegion"),
            "tx_power": r.get("txPower")}


def read_ready(ha, wait, timeout):
    """The driver's view once it is ready, or None after `wait` seconds (the last error printed)."""
    deadline = time.time() + wait
    last = None
    while True:
        try:
            v = read_once(ha, timeout)
            if v["ready"] and v["home_id"] is not None:
                return v
            last = "driver not ready yet (%s)" % json.dumps(v)
        except Exception as e:           # the container may not listen yet; the driver may be starting
            last = "%s: %s" % (type(e).__name__, str(e)[:120])
        if time.time() > deadline:
            print("FAIL  no ready driver at the local Z-Wave JS UI within %ds — last: %s" % (wait, last), file=sys.stderr)
            return None
        time.sleep(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["read", "restore"])
    ap.add_argument("--url", default="http://127.0.0.1:8091")
    ap.add_argument("--nvm", help="the NVM image to write (restore)")
    ap.add_argument("--mode", choices=["raw", "converting"], default="raw", help="restoreNVM useRaw=true (raw) or the converting restore")
    ap.add_argument("--force", action="store_true", help="write even when the stick already answers the expected home ID + nodes")
    ap.add_argument("--expect-home-id", type=lambda v: int(v, 0), default=None)
    ap.add_argument("--expect-nodes", type=int, default=None)
    ap.add_argument("--wait", type=float, default=120.0, help="seconds to wait for a ready driver (default 120)")
    ap.add_argument("--timeout", type=float, default=30.0, help="seconds per socket call (default 30)")
    a = ap.parse_args()
    ha = stub(a.url)

    v = read_ready(ha, a.wait, a.timeout)
    if v is None:
        return 1
    if a.cmd == "read":
        print(json.dumps(v, sort_keys=True))
        return 0

    if not a.nvm:
        print("usage error: restore needs --nvm FILE", file=sys.stderr)
        return 2
    try:
        image = open(a.nvm, "rb").read()
    except OSError as e:
        print("FAIL  cannot read %s: %s" % (a.nvm, e), file=sys.stderr)
        return 1
    print("OK    the driver is up on the local stick: home ID %s, %s nodes, SDK %s, fw %s, RF region %s at %s dBm" % (
        v["home_id_hex"], v["nodes"], v["sdk"], v["firmware"], v["rf_region"], v["tx_power"]))
    if not a.force and a.expect_home_id is not None and v["home_id"] == a.expect_home_id and \
            (a.expect_nodes is None or v["nodes"] == a.expect_nodes):
        print("DONE  already restored: the stick holds home ID %s with %s nodes — nothing written" % (v["home_id_hex"], v["nodes"]))
        return 0
    use_raw = (a.mode == "raw")
    print("restoreNVM(%s: %d bytes, useRaw=%s) — the radio is off while the image is written; then zwave-js %s"
          % (os.path.basename(a.nvm), len(image), "true" if use_raw else "false",
             "destroys its driver" if use_raw else "soft-resets and restarts its driver (the converting pass)"))
    t0 = time.time()
    last = {"msg": None}

    def on_event(name, payload):
        if name == "CONTROLLER_CMD" and isinstance(payload, dict):
            m = payload.get("status") or payload.get("message")
            if m and m != last["msg"]:
                last["msg"] = m
                print("      controller: %s" % m)
    sock = ZuiSocket(ha, "", "", timeout=max(a.timeout, 60.0))
    try:
        res = sock.call("restoreNVM", [{"_placeholder": True, "num": 0}, use_raw], timeout=600, on_event=on_event, binary=image)
    except Exception as e:
        print("FAIL  restoreNVM did not answer: %s: %s" % (type(e).__name__, str(e)[:200]), file=sys.stderr)
        return 1
    finally:
        try:
            sock.close()
        except Exception:
            pass
    if not isinstance(res, dict) or not res.get("success"):
        print("FAIL  restoreNVM refused: %s" % (res.get("message") if isinstance(res, dict) else res), file=sys.stderr)
        return 1
    print("DONE  restoreNVM(useRaw=%s) answered success after %.0f s — the image is on the stick; stop the container NOW (the "
          "restarted driver must not talk to the mesh), then verify with zradio-probe.py" % ("true" if use_raw else "false", time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
