"""USB test bridge: Gympath tracker (UART) <-> app on an Android emulator (TCP).

    Tracker --USB 921600--> serial_bridge.py --TCP 127.0.0.1:7700--> emulator app
            <------------- Start / Stop / Zero -------------------------------'

The emulator has no Bluetooth, so the app's debug "USB test link" connects to
10.0.2.2:7700 (= this PC's 127.0.0.1:7700) instead.  The bridge puts the
firmware into test mode ("TEST 1") when the app connects and back out
("TEST 0") when it leaves.  Line protocol (see Gympath_Track.ino):

    device -> app   V,<version>   T,<hex 20 B TrackPacket>   M,<hex 60 B MotionPacket>
    app -> device   C,<cmd>,<seq>       cmd 0 STOP, 1 START, 2 ZERO

Usage:
    python tools/serial_bridge.py               # auto-detect the COM port
    python tools/serial_bridge.py --port COM5
    python tools/serial_bridge.py --sim         # no tracker: synthetic cable reps
"""
import argparse
import math
import socket
import struct
import sys
import threading
import time

BAUD = 921600
FORWARD = ("T,", "M,", "V,")


def autodetect_port():
    from serial.tools import list_ports
    best = (0, None)
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        for kw, pts in (("espressif", 5), ("esp32", 5), ("cp210", 4),
                        ("ch340", 4), ("ch343", 4), ("ch910", 4),
                        ("usb serial", 3), ("usb", 1)):
            if kw in desc and pts > best[0]:
                best = (pts, p.device)
    return best[1]


class SerialDevice:
    """The real tracker over UART."""

    def __init__(self, port):
        self.port = port
        self.ser = None
        self.test = False       # re-sent after a USB drop + reopen
        self._open()

    def _open(self):
        import serial
        try:
            self.ser = serial.Serial(self.port, BAUD, timeout=0.1)
            self.ser.reset_input_buffer()
            return True
        except Exception:
            self.ser = None
            return False

    def _drop(self, err):
        print(f"[bridge] USB link lost ({type(err).__name__}) - reconnecting…")
        try:
            self.ser.close()
        except Exception:
            pass
        self.ser = None

    def _reopen(self):
        # cable wiggle / device reset: keep retrying, then restore test mode
        while not self._open():
            time.sleep(0.5)
        print(f"[bridge] USB link back on {self.port}")
        if self.test:
            time.sleep(1.0)     # opening the port resets the ESP32; let it boot
            self.write_line("TEST 1")

    def write_line(self, line):
        if line.startswith("TEST "):
            self.test = line == "TEST 1"
        if self.ser is None:
            return
        try:
            self.ser.write((line + "\n").encode())
        except Exception as e:
            self._drop(e)

    def read_line(self):
        if self.ser is None:
            self._reopen()
            return None
        try:
            raw = self.ser.readline()
        except Exception as e:
            self._drop(e)
            return None
        return raw.decode(errors="replace").strip() if raw else None

    def close(self):
        if self.ser:
            self.ser.close()


class SimDevice:
    """Stand-in tracker: ~30 cm cable reps every 2.5 s after START."""

    def __init__(self):
        self.test = False
        self.state = 0          # 0 idle, 1 calib, 2 track
        self.t0 = 0.0
        self.zero = 0.0
        self.last_seq = -1
        self.out = []
        self.next_t = time.time()

    def write_line(self, line):
        now = time.time()
        if line == "TEST 1":
            self.test, self.state = True, 0
            self.out.append("V,sim-1.0.0")
        elif line == "TEST 0":
            self.test, self.state = False, 0
        elif line.startswith("C,") and self.test:
            cmd, seq = (int(x) for x in line[2:].split(","))
            if seq == self.last_seq:
                return
            self.last_seq = seq
            if cmd == 1:
                self.state, self.t0, self.zero = 1, now, 0.0
            elif cmd == 0:
                self.state = 0
            elif cmd == 2 and self.state == 2:
                self.zero = self._raw(now)[0]

    def _raw(self, now):
        t = now - self.t0 - 0.6
        w = 2 * math.pi / 2.5
        p = 0.15 * (1 - math.cos(w * t))           # 0 … 30 cm
        v = 0.15 * w * math.sin(w * t)
        a = 0.15 * w * w * math.cos(w * t)
        reps = int(t // 2.5)                       # counted once back at 0
        return p, v, a, max(reps, 0)

    def read_line(self):
        if self.out:
            return self.out.pop(0)
        now = time.time()
        if not self.test or now < self.next_t:
            time.sleep(0.005)
            return None
        self.next_t = now + 0.02
        ms = int(now * 1000) & 0xFFFFFFFF
        p = v = a = 0.0
        reps = 0
        if self.state == 1 and now - self.t0 >= 0.6:
            self.state = 2
        if self.state == 2:
            p, v, a, reps = self._raw(now)
            p -= self.zero
        still = 1 if abs(v) < 0.04 else 0
        tp = struct.pack("<IfffhBB", ms, a, v, p, reps, self.state, still)
        mp = struct.pack("<I13fi", ms, 0, 0, a, 0, 0, 0, abs(a),
                         0, 0, v, 0, 0, p, reps)
        self.out.append("M," + mp.hex())
        return "T," + tp.hex()

    def close(self):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="COM port (default: auto-detect)")
    ap.add_argument("--tcp", type=int, default=7700, help="TCP port (default 7700)")
    ap.add_argument("--sim", action="store_true", help="simulate the tracker")
    args = ap.parse_args()

    if args.sim:
        dev = SimDevice()
        print("[bridge] SIM tracker (no hardware)")
    else:
        port = args.port or autodetect_port()
        if not port:
            sys.exit("[bridge] no tracker COM port found - plug it in or use --port / --sim")
        dev = SerialDevice(port)
        print(f"[bridge] tracker on {port} @ {BAUD}")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.tcp))
    srv.listen(1)
    print(f"[bridge] waiting for the app on 127.0.0.1:{args.tcp} "
          f"(emulator: 10.0.2.2:{args.tcp})")

    client = None
    lock = threading.Lock()
    stats = {"T": 0, "M": 0, "C": 0}

    def device_reader():
        nonlocal client
        last = time.time()
        while True:
            line = dev.read_line()
            if line and line.startswith(FORWARD):
                with lock:
                    c = client
                if c:
                    try:
                        c.sendall((line + "\n").encode())
                        stats[line[0]] = stats.get(line[0], 0) + 1
                    except OSError:
                        pass
                if line.startswith("V,"):
                    print(f"[bridge] firmware {line[2:]}")
            elif line and not line.startswith("#"):
                print(f"[device] {line}")
            if time.time() - last >= 5:
                last = time.time()
                if client:
                    print(f"[bridge] 5 s: track {stats['T']}  motion {stats['M']}  "
                          f"cmds {stats['C']}")
                stats.update(T=0, M=0)

    threading.Thread(target=device_reader, daemon=True).start()

    try:
        while True:
            conn, addr = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"[bridge] app connected from {addr[0]}")
            dev.write_line("TEST 1")
            with lock:
                client = conn
            buf = b""
            try:
                while True:
                    data = conn.recv(256)
                    if not data:
                        break
                    buf += data
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        line = raw.decode(errors="replace").strip()
                        if line.startswith("C,"):
                            stats["C"] += 1
                            print(f"[app] {line}")
                            dev.write_line(line)
            except OSError:
                pass
            with lock:
                client = None
            conn.close()
            dev.write_line("TEST 0")
            print("[bridge] app disconnected - tracker back to BLE mode")
    except KeyboardInterrupt:
        pass
    finally:
        dev.write_line("TEST 0")
        dev.close()


if __name__ == "__main__":
    main()
