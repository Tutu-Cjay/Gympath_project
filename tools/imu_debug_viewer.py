#!/usr/bin/env python3
"""Gympath IMU serial debug viewer + logger (pyqtgraph UI).

Reads the CSV debug stream from the ESP32 firmware (DEBUG_STREAM=1 in
IMU_path.ino), logs every line to a timestamped CSV file, and shows a
realtime dashboard that never blocks (serial reading runs in a thread,
rendering is OpenGL-accelerated pyqtgraph):

  * 3D view: device path, current position, and three RGB axis triads
    (X=red, Y=green, Z=blue):
       - bright triad   → ZUPT-estimated origin
       - moving triad   → live device pose (roll/pitch/yaw)
       - faded triad    → initial pose from boot calibration (qInit)
    Mouse: drag = rotate, wheel = zoom. "Follow device" recenters camera.
  * time series: accel, velocity, position vs origin, displacement,
    rep phase + ZUPT, euler angles

Usage:
    python imu_debug_viewer.py                  # auto-detect COM port
    python imu_debug_viewer.py --port COM3
    python imu_debug_viewer.py --list-ports     # show available ports
    python imu_debug_viewer.py --no-plot        # log only (headless)
    python imu_debug_viewer.py --replay logs/imu_log_20260610_120000.csv

Dependencies:
    pip install pyserial pyqtgraph PySide6 PyOpenGL numpy
"""

import argparse
import re
import sys
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("pyserial is required:  pip install pyserial")

# Device CSV columns — must match the firmware "# COLUMNS" line.
# rax/ray/raz = raw body-frame accel [m/s²]; rgx/rgy/rgz = bias-corrected
# gyro [rad/s] (both added for rotation analysis).
COLUMNS = ["t", "ax", "ay", "az", "vx", "vy", "vz",
           "px", "py", "pz", "ox", "oy", "oz", "disp",
           "roll", "pitch", "yaw", "env", "phase", "zupt", "reps",
           "rax", "ray", "raz", "rgx", "rgy", "rgz"]
LEGACY_NCOLS = (21, 24)  # older stream formats (no raw accel / no raw gyro)

SAMPLE_HZ = 250  # firmware debug stream upper bound (5 ms gate, B8-F15+)


class StreamState:
    """Thread-shared ring buffers for the parsed stream."""

    def __init__(self, maxlen):
        self.lock = threading.Lock()
        self.data = {c: deque(maxlen=maxlen) for c in COLUMNS}
        self.calib_text = "waiting for # CALIB line (resets with device)..."
        self.qinit = None        # (w, x, y, z) from boot calibration
        self.line_count = 0
        self.bad_lines = 0
        self.connected = False
        self.port_name = "-"

    def add_metadata(self, line):
        with self.lock:
            if line.startswith("# CALIB"):
                self.calib_text = line[2:].strip()
                m = re.search(r"qInit=([-\d.eE]+),([-\d.eE]+),([-\d.eE]+),([-\d.eE]+)",
                              line)
                if m:
                    self.qinit = tuple(float(g) for g in m.groups())

    def add_sample(self, values):
        with self.lock:
            for c, v in zip(COLUMNS, values):
                self.data[c].append(v)
            self.line_count += 1

    def snapshot(self):
        with self.lock:
            return {c: list(d) for c, d in self.data.items()}


def parse_line(line, state):
    """Parse one device line; returns True if it was a data sample."""
    line = line.strip()
    if not line:
        return False
    if line.startswith("#"):
        state.add_metadata(line)
        return False
    parts = line.split(",")
    if len(parts) in LEGACY_NCOLS:
        parts = parts + ["0"] * (len(COLUMNS) - len(parts))
    if len(parts) != len(COLUMNS):
        state.bad_lines += 1
        return False
    try:
        values = [float(p) for p in parts]
    except ValueError:
        state.bad_lines += 1
        return False
    state.add_sample(values)
    return True


def autodetect_port():
    """Pick the most likely ESP32 serial port."""
    candidates = []
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        score = 0
        for kw, pts in (("espressif", 5), ("esp32", 5), ("cp210", 4),
                        ("ch340", 4), ("ch343", 4), ("ch910", 4),
                        ("usb serial", 3), ("usb", 1)):
            if kw in desc:
                score = max(score, pts)
        candidates.append((score, p.device, p.description))
    candidates.sort(reverse=True)
    if not candidates or candidates[0][0] == 0:
        return None
    return candidates[0][1]


def open_log(log_dir):
    log_dir.mkdir(parents=True, exist_ok=True)
    name = datetime.now().strftime("imu_log_%Y%m%d_%H%M%S.csv")
    path = log_dir / name
    f = open(path, "w", encoding="utf-8", newline="\n")
    f.write("# GYMPATH IMU LOG — pc_ms prepended to each data line\n")
    f.write("# pc_ms," + ",".join(COLUMNS) + "\n")
    return f, path


def serial_reader(args, state, stop_event, log_file):
    """Background thread: keep the port open, parse + log every line."""
    while not stop_event.is_set():
        port = args.port or autodetect_port()
        if port is None:
            state.connected = False
            time.sleep(2)
            continue
        try:
            with serial.Serial(port, args.baud, timeout=1) as ser:
                state.connected = True
                state.port_name = port
                print(f"[serial] connected to {port} @ {args.baud}")
                unflushed = 0
                while not stop_event.is_set():
                    raw = ser.readline()
                    if not raw:
                        continue
                    line = raw.decode("ascii", errors="replace").strip()
                    if not line:
                        continue
                    if line.startswith("#"):
                        log_file.write(line + "\n")
                        parse_line(line, state)
                    elif parse_line(line, state):
                        log_file.write(f"{int(time.time() * 1000)},{line}\n")
                    unflushed += 1
                    if unflushed >= 50:
                        log_file.flush()
                        unflushed = 0
        except (serial.SerialException, OSError) as e:
            state.connected = False
            print(f"[serial] {e} — retrying in 2s")
            time.sleep(2)
    state.connected = False


def replay_reader(args, state, stop_event):
    """Background thread: feed a previously logged file in real time."""
    path = Path(args.replay)
    if not path.exists():
        sys.exit(f"replay file not found: {path}")
    state.connected = True
    state.port_name = f"replay:{path.name}"
    prev_t = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if stop_event.is_set():
                return
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                state.add_metadata(line)
                continue
            parts = line.split(",")
            if len(parts) in (len(COLUMNS) + 1, *(n + 1 for n in LEGACY_NCOLS)):
                parts = parts[1:]  # drop logger's pc_ms prefix
            if parse_line(",".join(parts), state) and args.speed > 0:
                t = state.data["t"][-1]
                if prev_t is not None and t > prev_t:
                    time.sleep(min((t - prev_t) / 1000.0 / args.speed, 0.5))
                prev_t = t
    print("[replay] end of file")
    state.connected = False


def run_headless(state, stop_event):
    try:
        while not stop_event.is_set():
            time.sleep(1)
            snap = state.snapshot()
            if snap["t"]:
                print(f"lines={state.line_count}  reps={int(snap['reps'][-1])}  "
                      f"disp={snap['disp'][-1]:.3f}m  "
                      f"phase={'ACTIVE' if snap['phase'][-1] else 'REST'}  "
                      f"zupt={'on' if snap['zupt'][-1] else 'off'}")
            else:
                print(f"waiting for data... (connected={state.connected})")
    except KeyboardInterrupt:
        pass


# ───────────────────────────── Qt / pyqtgraph UI ─────────────────────────────

def run_qt(args, state, stop_event, log_path=None):
    try:
        import numpy as np
        import pyqtgraph as pg
        import pyqtgraph.opengl as gl
        from pyqtgraph.Qt import QtCore, QtWidgets
    except ImportError as e:
        sys.exit(f"{e}\nInstall UI deps:  pip install pyqtgraph PySide6 PyOpenGL numpy")

    try:
        import imu_rotation_test as rt  # guided-test steps + analysis
    except Exception:
        rt = None

    pg.setConfigOptions(antialias=True, background="#101418", foreground="#cfd8dc")

    # rotation helpers ────────────────────────────────────────────────────
    def euler_to_R(roll_deg, pitch_deg, yaw_deg):
        r, p, y = np.radians([roll_deg, pitch_deg, yaw_deg])
        cr, sr = np.cos(r), np.sin(r)
        cp, sp = np.cos(p), np.sin(p)
        cy, sy = np.cos(y), np.sin(y)
        Rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
        Ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]])
        Rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
        return Rz @ Ry @ Rx

    def quat_to_R(w, x, y, z):
        return np.array([
            [1 - 2*(y*y + z*z), 2*(x*y - w*z),     2*(x*z + w*y)],
            [2*(x*y + w*z),     1 - 2*(x*x + z*z), 2*(y*z - w*x)],
            [2*(x*z - w*y),     2*(y*z + w*x),     1 - 2*(x*x + y*y)],
        ])

    def triad_verts(center, R, length):
        """6 vertices for an RGB axis triad (3 line segments)."""
        c = np.asarray(center, dtype=float)
        pts = []
        for i in range(3):
            pts.append(c)
            pts.append(c + R[:, i] * length)
        return np.array(pts)

    def triad_colors(alpha):
        return np.array(
            [[1.0, 0.30, 0.30, alpha]] * 2 +   # X red
            [[0.30, 1.0, 0.30, alpha]] * 2 +   # Y green
            [[0.35, 0.60, 1.0, alpha]] * 2)    # Z blue

    IDENTITY = np.eye(3)

    app = pg.mkQApp("Gympath IMU Debug")
    win = QtWidgets.QMainWindow()
    win.setWindowTitle("Gympath IMU Debug — pos / origin / pose")
    win.resize(1500, 920)

    central = QtWidgets.QWidget()
    vbox = QtWidgets.QVBoxLayout(central)
    vbox.setContentsMargins(8, 6, 8, 6)
    vbox.setSpacing(6)

    # top status bar ──────────────────────────────────────────────────────
    top = QtWidgets.QHBoxLayout()
    status = QtWidgets.QLabel("waiting for data...")
    status.setTextFormat(QtCore.Qt.TextFormat.RichText)
    status.setStyleSheet("font-size: 13px; color: #cfd8dc;")
    follow_cb = QtWidgets.QCheckBox("Follow device")
    follow_cb.setChecked(True)
    follow_cb.setStyleSheet("color: #cfd8dc;")
    test_btn = QtWidgets.QPushButton("▶ Guided test")
    test_btn.setStyleSheet(
        "color: #0a0a0a; background: #00e676; font-weight: bold; padding: 4px 12px;")
    top.addWidget(status, stretch=1)
    top.addWidget(test_btn)
    top.addWidget(follow_cb)
    vbox.addLayout(top)

    calib_lbl = QtWidgets.QLabel(state.calib_text)
    calib_lbl.setStyleSheet("font-size: 11px; color: #78909c;")
    vbox.addWidget(calib_lbl)

    pos_lbl = QtWidgets.QLabel("pos —")
    pos_lbl.setStyleSheet(
        "font-family: Consolas, monospace; font-size: 12px; color: #b0bec5;")
    vbox.addWidget(pos_lbl)

    # big instruction banner for the guided test
    instr_lbl = QtWidgets.QLabel("")
    instr_lbl.setWordWrap(True)
    instr_lbl.setVisible(False)
    vbox.addWidget(instr_lbl)

    splitter = QtWidgets.QSplitter()
    vbox.addWidget(splitter, stretch=1)

    # 3D view ─────────────────────────────────────────────────────────────
    view = gl.GLViewWidget()
    view.setBackgroundColor("#101418")
    view.setCameraPosition(distance=1.4, elevation=22, azimuth=45)

    grid = gl.GLGridItem()
    grid.setSize(4, 4)
    grid.setSpacing(0.1, 0.1)
    grid.setColor((255, 255, 255, 70))
    view.addItem(grid)

    path_item = gl.GLLinePlotItem(mode="line_strip", width=2.0, antialias=True)
    view.addItem(path_item)

    cur_pt = gl.GLScatterPlotItem(size=11, color=(1.0, 0.65, 0.15, 1.0))
    view.addItem(cur_pt)

    origin_triad = gl.GLLinePlotItem(mode="lines", width=4.0, antialias=True)
    view.addItem(origin_triad)

    pose_triad = gl.GLLinePlotItem(mode="lines", width=3.0, antialias=True)
    view.addItem(pose_triad)

    # world frame / initial pose — FIXED at (0,0,0), never moves.
    # Shown as identity from startup; rotation updates once qInit arrives.
    init_triad = gl.GLLinePlotItem(mode="lines", width=2.5, antialias=True)
    init_triad.setData(pos=triad_verts((0, 0, 0), IDENTITY, 0.2),
                       color=triad_colors(0.55))
    view.addItem(init_triad)

    splitter.addWidget(view)

    # 2D time-series column ───────────────────────────────────────────────
    glw = pg.GraphicsLayoutWidget()
    splitter.addWidget(glw)
    splitter.setSizes([820, 680])

    RGB = ("#ff6666", "#66dd66", "#6699ff")

    def add_plot(title, row):
        p = glw.addPlot(row=row, col=0)
        p.setLabel("left", title)
        p.showGrid(x=True, y=True, alpha=0.15)
        p.setMouseEnabled(x=False, y=False)
        return p

    p_acc = add_plot("accel [m/s²]", 0)
    p_vel = add_plot("vel [m/s]", 1)
    p_pos = add_plot("pos vs origin [m]", 2)
    p_dsp = add_plot("disp [m]", 3)
    p_flg = add_plot("phase / ZUPT", 4)
    p_eul = add_plot("euler [°]", 5)
    for p in (p_vel, p_pos, p_dsp, p_flg, p_eul):
        p.setXLink(p_acc)
    p_flg.setYRange(-0.1, 1.2)
    p_eul.setLabel("bottom", "time [s]")

    curves = {}
    for i, c in enumerate(("ax", "ay", "az")):
        curves[c] = p_acc.plot(pen=pg.mkPen(RGB[i], width=1.3), name=c)
    for i, c in enumerate(("vx", "vy", "vz")):
        curves[c] = p_vel.plot(pen=pg.mkPen(RGB[i], width=1.3))
    for i, c in enumerate(("px", "py", "pz")):
        curves[c] = p_pos.plot(pen=pg.mkPen(RGB[i], width=1.3))
    for i, c in enumerate(("ox", "oy", "oz")):
        curves[c] = p_pos.plot(pen=pg.mkPen(RGB[i], width=1.2,
                                            style=QtCore.Qt.PenStyle.DashLine))
    curves["disp"] = p_dsp.plot(pen=pg.mkPen("#ffaa33", width=1.8))
    curves["phase"] = p_flg.plot(pen=pg.mkPen("#ff5577", width=1.4))
    curves["zupt"] = p_flg.plot(pen=pg.mkPen("#33ccff", width=1.2))
    for i, c in enumerate(("roll", "pitch", "yaw")):
        curves[c] = p_eul.plot(pen=pg.mkPen(RGB[i], width=1.3))

    # guided rotation test — instructions shown in the GUI while the live
    # 3D/chart views keep running, report shown in a dialog at the end ────
    STYLE_WAIT = ("font-size: 20px; font-weight: bold; color: #0a0a0a; "
                  "background: #ffd54f; padding: 10px; border-radius: 6px;")
    STYLE_REC = ("font-size: 20px; font-weight: bold; color: #eaffea; "
                 "background: #1b5e20; padding: 10px; border-radius: 6px;")

    test = {"active": False, "step": -1, "phase": "", "until": 0.0,
            "t0": None, "segments": []}

    def latest_device_t():
        with state.lock:
            return state.data["t"][-1] if state.data["t"] else None

    def test_start():
        if test["active"] or rt is None or log_path is None:
            return
        test.update(active=True, step=-1, segments=[])
        test_btn.setEnabled(False)
        test_next_step()

    def test_next_step():
        test["step"] += 1
        if test["step"] >= len(rt.STEPS):
            test_finish()
            return
        test["phase"] = "countdown"
        test["until"] = time.monotonic() + 3.5
        instr_lbl.setVisible(True)
        rt.beep(660, 120)

    def test_finish():
        test["active"] = False
        test_btn.setEnabled(True)
        instr_lbl.setStyleSheet(STYLE_WAIT)
        instr_lbl.setText("Шинжилж байна...")
        QtWidgets.QApplication.processEvents()
        # analyze from the full session log — the GUI ring buffer only
        # holds the chart window, not the whole test
        big = StreamState(1_000_000)
        try:
            with open(log_path, encoding="utf-8") as f:
                for ln in f:
                    ln = ln.strip()
                    if not ln:
                        continue
                    if ln.startswith("#"):
                        big.add_metadata(ln)
                        continue
                    parts = ln.split(",")
                    if len(parts) in (len(COLUMNS) + 1,
                                      *(x + 1 for x in LEGACY_NCOLS)):
                        parts = parts[1:]  # pc_ms prefix
                    parse_line(",".join(parts), big)
        except OSError as e:
            instr_lbl.setText(f"log унших алдаа: {e}")
            return
        report = rt.analyze(big, test["segments"], rt.gravity_from_calib(big))
        rp = Path(args.log_dir) / datetime.now().strftime(
            "rotation_test_%Y%m%d_%H%M%S_report.txt")
        rp.write_text(report, encoding="utf-8")
        instr_lbl.setVisible(False)
        print(report)
        print(f"[report] {rp}")
        dlg = QtWidgets.QDialog(win)
        dlg.setWindowTitle(f"Rotation test report — {rp.name}")
        lay = QtWidgets.QVBoxLayout(dlg)
        txt = QtWidgets.QPlainTextEdit(report)
        txt.setReadOnly(True)
        txt.setStyleSheet("font-family: Consolas, monospace; font-size: 12px;")
        lay.addWidget(txt)
        dlg.resize(740, 660)
        dlg.show()

    def test_tick():
        if not test["active"]:
            return
        name, instr, dur, typ = rt.STEPS[test["step"]]
        head = f"Алхам {test['step'] + 1}/{len(rt.STEPS)} — {name}"
        if test["phase"] == "countdown":
            remain = test["until"] - time.monotonic()
            if remain <= 0:
                test["phase"] = "record"
                test["until"] = time.monotonic() + dur
                test["t0"] = latest_device_t()
                rt.beep(1100, 200)
            else:
                instr_lbl.setStyleSheet(STYLE_WAIT)
                instr_lbl.setText(f"{head}\n{instr}\nБэлд... {int(remain) + 1}")
        if test["phase"] == "record":
            remain = test["until"] - time.monotonic()
            if remain <= 0:
                t1 = latest_device_t()
                test["segments"].append((name, instr, typ, test["t0"], t1))
                rt.beep(880, 150)
                test_next_step()
            else:
                instr_lbl.setStyleSheet(STYLE_REC)
                instr_lbl.setText(f"{head}\n{instr}\n● БИЧИЖ БАЙНА — {int(remain) + 1}s")

    if rt is None or args.replay or log_path is None:
        test_btn.setEnabled(False)
        test_btn.setToolTip("Guided test нь зөвхөн live serial горимд ажиллана")
    else:
        test_btn.clicked.connect(test_start)
    test_timer = QtCore.QTimer()
    test_timer.timeout.connect(test_tick)
    test_timer.start(200)

    # periodic update ─────────────────────────────────────────────────────
    shown_qinit = [None]

    def update():
        snap = state.snapshot()
        t = snap["t"]
        conn = "🟢" if state.connected else "🔴"
        if len(t) < 2:
            status.setText(f"{conn} waiting for data...  port={state.port_name}  "
                           f"lines={state.line_count}")
            calib_lbl.setText(state.calib_text)
            return

        tr = (np.asarray(t) - t[0]) / 1000.0
        tmax = float(tr[-1])

        # time series
        for c in ("ax", "ay", "az", "vx", "vy", "vz",
                  "px", "py", "pz", "ox", "oy", "oz",
                  "disp", "phase", "zupt", "roll", "pitch", "yaw"):
            curves[c].setData(tr, snap[c])
        p_acc.setXRange(max(0.0, tmax - args.window), tmax + 0.2, padding=0)

        # 3D path with fading tail
        pos = np.column_stack((snap["px"], snap["py"], snap["pz"]))
        n = len(pos)
        col = np.empty((n, 4), dtype=float)
        col[:, 0], col[:, 1], col[:, 2] = 0.75, 0.80, 0.85
        col[:, 3] = np.linspace(0.06, 0.9, n)
        path_item.setData(pos=pos, color=col)
        cur_pt.setData(pos=pos[-1:].copy())

        # origin triad (bright) at ZUPT origin
        org = np.array([snap["ox"][-1], snap["oy"][-1], snap["oz"][-1]])
        origin_triad.setData(pos=triad_verts(org, IDENTITY, 0.15),
                             color=triad_colors(1.0))

        # live device pose triad at current position
        R = euler_to_R(snap["roll"][-1], snap["pitch"][-1], snap["yaw"][-1])
        pose_triad.setData(pos=triad_verts(pos[-1], R, 0.10),
                           color=triad_colors(0.95))

        # world frame triad: stays at (0,0,0); rotation set once per CALIB
        if state.qinit is not None and shown_qinit[0] != state.qinit:
            shown_qinit[0] = state.qinit
            Rq = quat_to_R(*state.qinit)
            init_triad.setData(pos=triad_verts((0, 0, 0), Rq, 0.2),
                               color=triad_colors(0.55))

        if follow_cb.isChecked():
            mid = (org + pos[-1]) / 2.0
            view.opts["center"] = pg.Vector(*mid)
            # keep the grid under the device even when position has drifted
            # far from the world origin; snapping to the 0.1 m spacing makes
            # the translation invisible (lines map onto themselves)
            grid.resetTransform()
            grid.translate(round(mid[0], 1), round(mid[1], 1), round(mid[2], 1))
            view.update()

        # always-visible numeric readout
        dx, dy, dz = pos[-1] - org
        pos_lbl.setText(
            f"pos    x {pos[-1][0]:+9.3f}   y {pos[-1][1]:+9.3f}   z {pos[-1][2]:+9.3f}  [m]      "
            f"origin x {org[0]:+9.3f}   y {org[1]:+9.3f}   z {org[2]:+9.3f}  [m]      "
            f"disp   x {dx:+7.3f}   y {dy:+7.3f}   z {dz:+7.3f}  [m]")

        phase = ("<span style='color:#ff5577'><b>ACTIVE</b></span>"
                 if snap["phase"][-1] else "<span style='color:#90a4ae'>REST</span>")
        zupt = ("<span style='color:#33ccff'><b>ZUPT</b></span>"
                if snap["zupt"][-1] else "moving")
        status.setText(
            f"{conn}  <b style='font-size:16px;color:#00e676'>"
            f"reps {int(snap['reps'][-1])}</b> &nbsp; {phase} &nbsp; {zupt} &nbsp; "
            f"disp <b>{snap['disp'][-1]:.3f} m</b> &nbsp;|&nbsp; "
            f"port {state.port_name} &nbsp; lines {state.line_count} "
            f"(bad {state.bad_lines})")
        calib_lbl.setText(
            state.calib_text +
            "   —   triads: fixed at (0,0,0)=world frame / init pose, "
            "bright=ZUPT origin (follows drift), moving=device pose")

    timer = QtCore.QTimer()
    timer.timeout.connect(update)
    timer.start(33)  # ~30 FPS

    if args.test_exit_ms:
        QtCore.QTimer.singleShot(args.test_exit_ms, app.quit)

    win.setCentralWidget(central)
    win.show()
    try:
        app.exec()
    finally:
        stop_event.set()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", help="serial port (e.g. COM3); auto-detect if omitted")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--window", type=float, default=15.0,
                    help="time-series window in seconds (default 15)")
    ap.add_argument("--log-dir", default=str(Path(__file__).parent / "logs"))
    ap.add_argument("--no-plot", action="store_true", help="log only, no GUI")
    ap.add_argument("--list-ports", action="store_true")
    ap.add_argument("--replay", help="visualize a previously logged CSV file")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="replay speed multiplier (0 = as fast as possible)")
    ap.add_argument("--test-exit-ms", type=int, default=0, help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.list_ports:
        for p in list_ports.comports():
            print(f"{p.device:10s} {p.description}")
        return

    maxlen = int(args.window * SAMPLE_HZ * 1.2) + 100
    state = StreamState(maxlen)
    stop_event = threading.Event()

    if args.replay:
        reader = threading.Thread(target=replay_reader,
                                  args=(args, state, stop_event), daemon=True)
        log_path = None
    else:
        log_file, log_path = open_log(Path(args.log_dir))
        print(f"[log] writing to {log_path}")
        reader = threading.Thread(target=serial_reader,
                                  args=(args, state, stop_event, log_file),
                                  daemon=True)
    reader.start()

    try:
        if args.no_plot:
            run_headless(state, stop_event)
        else:
            run_qt(args, state, stop_event, log_path)
    finally:
        stop_event.set()
        reader.join(timeout=3)
        if log_path:
            log_file.flush()
            log_file.close()
            print(f"[log] saved {log_path}")


if __name__ == "__main__":
    main()
