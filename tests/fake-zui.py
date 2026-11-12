#!/usr/bin/env python3
"""fake-zui.py — a stand-in for Z-Wave JS UI's socket.io endpoint, for tests/t-zui-restore.sh: one WebSocket at a time,
engine.io v4 open packet, socket.io CONNECT, ZWAVE_API calls with acks (driverFunction, restoreNVM with one binary
attachment). Usage: fake-zui.py PORTFILE STATEDIR [knob…]. It writes its port to PORTFILE, the image it received to
STATEDIR/received.bin and every call to STATEDIR/calls. Knobs: refuse (restoreNVM answers success=false), notready
(driver.ready false), ping (an engine.io ping before every answer), binary-event (a binary frame before the answer)."""
import base64, hashlib, json, os, socket, struct, sys

portfile, state, knobs = sys.argv[1], sys.argv[2], set(sys.argv[3:])
home = int(open(os.path.join(state, "home")).read()) if os.path.exists(os.path.join(state, "home")) else 0xF4486CBA


def frame(op, payload):
    n = len(payload); h = bytearray([0x80 | op])
    if n < 126: h.append(n)
    elif n < 65536: h.append(126); h += struct.pack("!H", n)
    else: h.append(127); h += struct.pack("!Q", n)
    return bytes(h) + payload


def recv_frame(c, buf):
    def need(n):
        while len(buf) < n:
            d = c.recv(65536)
            if not d: raise EOFError
            buf.extend(d)
    need(2); op = buf[0] & 0x0F; masked = buf[1] & 0x80; n = buf[1] & 0x7F; i = 2
    if n == 126: need(4); n = struct.unpack("!H", bytes(buf[2:4]))[0]; i = 4
    elif n == 127: need(10); n = struct.unpack("!Q", bytes(buf[2:10]))[0]; i = 10
    assert masked, "a client frame must be masked"
    need(i + 4 + n); key = bytes(buf[i:i + 4]); data = bytes(b ^ key[j % 4] for j, b in enumerate(buf[i + 4:i + 4 + n]))
    del buf[:i + 4 + n]
    return op, data


s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(4)
open(portfile + ".tmp", "w").write(str(s.getsockname()[1])); os.replace(portfile + ".tmp", portfile)
while True:
    c, _ = s.accept(); buf = bytearray()
    try:
        req = b""
        while b"\r\n\r\n" not in req: req += c.recv(4096)
        key = [l.split(b":", 1)[1].strip() for l in req.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
        acc = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        c.sendall(frame(1, b'0{"sid":"x","upgrades":[],"pingInterval":25000,"pingTimeout":20000}'))
        pending = None
        while True:
            op, data = recv_frame(c, buf)
            if op == 8: break
            if op == 2 and pending:
                aid, payload = pending; pending = None
                open(os.path.join(state, "received.bin"), "wb").write(data)
                open(os.path.join(state, "calls"), "a").write("restoreNVM useRaw=%s bytes=%d\n" % (json.dumps(payload["args"][1]), len(data)))
                c.sendall(frame(1, ('42["CONTROLLER_CMD",{"status":"Restoring NVM..."}]').encode()))
                if "binary-event" in knobs:
                    c.sendall(frame(1, b'451-["INIT",{"_placeholder":true,"num":0}]')); c.sendall(frame(2, b"\x00\xff\xfe"))
                res = {"success": False, "message": "fake refusal"} if "refuse" in knobs else {"success": True, "message": "ok"}
                c.sendall(frame(1, ("43%d%s" % (aid, json.dumps([res]))).encode())); continue
            m = data.decode()
            if m == "40": c.sendall(frame(1, b'40{"sid":"y"}')); continue
            if m == "3": continue
            if m.startswith("451-"):
                j = m.index("["); pending = (int(m[4:j]), json.loads(m[j:])[1]); continue
            if m.startswith("42"):
                j = m.index("["); aid = int(m[2:j]); payload = json.loads(m[j:])[1]
                open(os.path.join(state, "calls"), "a").write("%s\n" % payload["api"])
                if "ping" in knobs: c.sendall(frame(1, b"2"))
                res = {"success": True, "result": {"ready": "notready" not in knobs, "homeId": home, "nodes": 1, "sdk": "7.23.2", "fw": "2.0", "rfRegion": 9, "txPower": {"powerlevel": 14}}}
                c.sendall(frame(1, ("43%d%s" % (aid, json.dumps([res]))).encode()))
    except (EOFError, OSError, AssertionError) as e:
        open(os.path.join(state, "calls"), "a").write("closed: %s\n" % type(e).__name__)
    finally:
        c.close()
