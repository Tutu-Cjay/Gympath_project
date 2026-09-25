#!/usr/bin/env python3
"""Gympath guided IMU rotation test — зааварчилгаатай туршилт + автомат шинжилгээ.

Алхам бүрд консол дээр заавар өгнө ("одоо X тэнхлэгээр эргүүл" г.м.),
алхам бүрийн өгөгдлийг тэмдэглэж, дууссаны дараа position drift /
gravity residual / gyro зэргийг сегмент бүрээр шинжилж PASS/FAIL
дүгнэлт гаргана. Бүх түүхий өгөгдөл CSV log-д хадгалагдана.

Зорилго: эргэлтийн үед position буруу бодогдож байгаа эсэхийг тоогоор
батлах — эргэлт хийхэд position drift их байвал orientation/gravity
filtering-д асуудал байна гэсэн үг.

Usage:
    python imu_rotation_test.py [--port COM3] [--baud 115200]

Dependencies:
    pip install pyserial numpy
"""

import argparse
import re
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import imu_debug_viewer as viewer  # noqa: E402  (reuse reader infra)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# (name, instruction, seconds, type) — type: still | rotation | translation
STEPS = [
    ("still_baseline",
     "ХӨДӨЛГӨӨНГҮЙ БАРЬ — ширээн дээр тогтвортой тавиад бүү хүр",
     8, "still"),
    ("roll_x",
     "X тэнхлэгээр ЭРГҮҮЛ (roll): нэг ирмэгээ ширээнд тулсан хэвээр ±90° налуулж\n"
     "    буцааж 3 удаа давт. (Ирмэгээр эргүүлэхэд sensor ~5см нумаар хөдөлдөг нь\n"
     "    хэвийн — төгсгөлд нь position 0 руугаа буцах ёстой)",
     10, "rotation"),
    ("pitch_y",
     "Y тэнхлэгээр ЭРГҮҮЛ (pitch): нөгөө ирмэгээ тулаад ±90° налуулж буцааж\n"
     "    3 удаа давт. (Sensor-ийн ~5см нуман хөдөлгөөн хэвийн)",
     10, "rotation"),
    ("yaw_z",
     "Z тэнхлэгээр ЭРГҮҮЛ (yaw): хавтгай дээрээ цагийн зүү шиг ±90° эргүүлж 3 удаа давт.\n"
     "    Байрнаас нь БҮҮ ХӨДӨЛГӨ — зөвхөн эргүүл!",
     10, "rotation"),
    ("translate_z",
     "ЭРГҮҮЛЭЛГҮЙГЭЭР дээш-доош ~20 см зөөж 3 удаа давт (чиглэлээ хадгал)",
     10, "translation"),
    ("slide_x",
     "Ширээн дээр ХАВТГАЙ хэвээр нь баруун тийш ~30 см ШУЛУУН гулсуулж буцаа, 3 удаа.\n"
     "    Ширээнээс БҮҮ ӨРГӨ, БҮҮ ЭРГҮҮЛ — зөвхөн гулсуул!",
     10, "translation"),
    ("slide_y",
     "Одоо урагшаа ~30 см ШУЛУУН гулсуулж буцаа, 3 удаа.\n"
     "    Ширээнээс БҮҮ ӨРГӨ, БҮҮ ЭРГҮҮЛ — зөвхөн гулсуул!",
     10, "translation"),
    ("still_final",
     "Дахин ХӨДӨЛГӨӨНГҮЙ тавь",
     6, "still"),
]

# verdict thresholds [m]
TH_STILL_DRIFT = 0.02      # stationary: position must not move
TH_ROT_DRIFT = 0.08        # pure rotation: small leakage tolerated
TH_ROT_EXCURSION = 0.15    # pure rotation: max wander from start
TH_TRANS_MIN = 0.08        # translation step must register at least this
TH_TRANS_DRIFT = 0.30      # translation: must roughly return to start
SETTLE_MS = 1500           # discard segment head — hand still repositioning


def beep(freq=880, ms=180):
    try:
        import winsound
        winsound.Beep(freq, ms)
    except Exception:
        print("\a", end="", flush=True)


def open_test_log(log_dir):
    log_dir.mkdir(parents=True, exist_ok=True)
    name = datetime.now().strftime("rotation_test_%Y%m%d_%H%M%S")
    f = open(log_dir / f"{name}.csv", "w", encoding="utf-8", newline="\n")
    f.write("# GYMPATH ROTATION TEST LOG — pc_ms prepended to each data line\n")
    f.write("# pc_ms," + ",".join(viewer.COLUMNS) + "\n")
    return f, log_dir / f"{name}.csv", log_dir / f"{name}_report.txt"


def latest_t(state):
    with state.lock:
        return state.data["t"][-1] if state.data["t"] else None


def gravity_from_calib(state):
    m = re.search(r"gravityMag=([-\d.eE]+)", state.calib_text)
    return float(m.group(1)) if m else 9.81


def record_steps(state):
    """Run the guided sequence; returns [(name, instr, type, t0, t1), ...]."""
    segments = []
    for i, (name, instr, dur, typ) in enumerate(STEPS, 1):
        print(f"\n━━━ Алхам {i}/{len(STEPS)} — {name} ━━━")
        print(f"  ▶ {instr}")
        for c in (3, 2, 1):
            print(f"    ... {c}")
            beep(660, 120)
            time.sleep(1)
        beep(1100, 250)
        print(f"  ● БИЧИЖ БАЙНА — {dur} секунд")
        t0 = latest_t(state)
        for s in range(dur):
            time.sleep(1)
            print(f"    {dur - s - 1}s үлдлээ", end="\r", flush=True)
        t1 = latest_t(state)
        beep(880, 150)
        print(f"\n  ✔ дууслаа (device t: {t0} → {t1})")
        if t0 is None or t1 is None or t1 <= t0:
            print("  ⚠ энэ алхамд өгөгдөл ирээгүй!")
        segments.append((name, instr, typ, t0, t1))
    return segments


def analyze(state, segments, gravity):
    """Per-segment metrics + verdicts; returns the report as a string."""
    snap = state.snapshot()
    arr = {c: np.asarray(snap[c], dtype=float) for c in viewer.COLUMNS}
    have_raw = bool(np.any(arr["rax"]) or np.any(arr["ray"]) or np.any(arr["raz"]))
    have_gyro = bool(np.any(arr["rgx"]) or np.any(arr["rgy"]) or np.any(arr["rgz"]))

    lines = []
    lines.append("GYMPATH ROTATION TEST REPORT")
    lines.append(f"generated: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"calib: {state.calib_text}")
    lines.append(f"samples total: {len(arr['t'])}   gravityMag: {gravity:.4f} m/s²")
    if not have_raw:
        lines.append("NOTE: raw accel columns are all zero — firmware without "
                     "rax/ray/raz (re-upload latest DEBUG_STREAM firmware).")
    lines.append("")

    overall_fail = []
    for name, _instr, typ, t0, t1 in segments:
        lines.append(f"── {name}  [{typ}] " + "─" * max(1, 40 - len(name)))
        if t0 is None or t1 is None or t1 <= t0:
            lines.append("   no data — SKIPPED")
            lines.append("")
            continue
        m = (arr["t"] >= t0 + SETTLE_MS) & (arr["t"] <= t1)
        n = int(m.sum())
        if n < 5:
            lines.append(f"   only {n} samples — SKIPPED")
            lines.append("")
            continue

        dur_s = (t1 - t0) / 1000.0
        rate = n / dur_s
        pos = np.column_stack((arr["px"][m], arr["py"][m], arr["pz"][m]))
        k = min(5, n)
        p_start = np.median(pos[:k], axis=0)
        p_end = np.median(pos[-k:], axis=0)
        drift = float(np.linalg.norm(p_end - p_start))
        excur = float(np.max(np.linalg.norm(pos - p_start, axis=1)))
        # (stream has no gyro columns — euler range below shows rotation amount)
        lin = np.sqrt(arr["ax"][m]**2 + arr["ay"][m]**2 + arr["az"][m]**2)
        vel = np.sqrt(arr["vx"][m]**2 + arr["vy"][m]**2 + arr["vz"][m]**2)
        zupt_pct = 100.0 * float(np.mean(arr["zupt"][m]))
        roll_rng = float(arr["roll"][m].max() - arr["roll"][m].min())
        pitch_rng = float(arr["pitch"][m].max() - arr["pitch"][m].min())
        yaw_rng = float(arr["yaw"][m].max() - arr["yaw"][m].min())

        dt_ms = np.diff(arr["t"][m])
        lines.append(f"   samples {n}  ({rate:.1f} Hz over {dur_s:.1f}s)   "
                     f"sample dt med/max: {np.median(dt_ms):.0f}/{dt_ms.max():.0f} ms")
        lines.append(f"   pos drift end-start : {drift*100:7.1f} cm")
        lines.append(f"   pos max excursion   : {excur*100:7.1f} cm")
        lines.append(f"   lin accel mean/max  : {lin.mean():6.2f} / {lin.max():6.2f} m/s²")
        lines.append(f"   |vel| max           : {vel.max():6.3f} m/s")
        lines.append(f"   euler range r/p/y   : {roll_rng:5.0f}° / {pitch_rng:5.0f}° / {yaw_rng:5.0f}°")
        lines.append(f"   ZUPT active         : {zupt_pct:5.1f}% of samples")
        if have_raw:
            raw_norm = np.sqrt(arr["rax"][m]**2 + arr["ray"][m]**2 + arr["raz"][m]**2)
            dev = np.abs(raw_norm - gravity)
            lines.append(f"   |raw acc|-g dev     : mean {dev.mean():5.2f}  max {dev.max():5.2f} m/s²")

        # gyro ↔ euler cross-check: detects unit/axis/sign mapping errors.
        # Physical ±90°×3 swings should integrate to ≥500° of gyro travel on
        # the swung axis, and euler travel on the matching axis should agree.
        if have_gyro and typ == "rotation" and n > 20:
            t_s = arr["t"][m] / 1000.0
            dts = np.maximum(np.diff(t_s), 1e-3)
            g3 = np.vstack((arr["rgx"][m], arr["rgy"][m], arr["rgz"][m]))  # rad/s
            trav_g = np.degrees(np.sum(np.abs(g3[:, 1:]) * dts, axis=1))
            eul = np.vstack([np.unwrap(np.radians(arr[c][m]))
                             for c in ("roll", "pitch", "yaw")])
            trav_e = np.degrees(np.sum(np.abs(np.diff(eul, axis=1)), axis=1))
            gyro_max = float(np.max(np.sqrt(np.sum(g3**2, axis=0))))
            lines.append(f"   gyro max            : {gyro_max:6.2f} rad/s "
                         f"({np.degrees(gyro_max):.0f}°/s)")
            lines.append(f"   gyro travel x/y/z   : {trav_g[0]:6.0f}° /{trav_g[1]:6.0f}° /{trav_g[2]:6.0f}°")
            lines.append(f"   euler travel r/p/y  : {trav_e[0]:6.0f}° /{trav_e[1]:6.0f}° /{trav_e[2]:6.0f}°")
            deul = np.diff(eul, axis=1) / dts
            match = []
            for i in range(3):
                gi = g3[i, 1:]
                if np.std(gi) < 1e-3:
                    match.append(f"g{'xyz'[i]}→ - ")
                    continue
                cors = [float(np.corrcoef(gi, deul[j])[0, 1])
                        if np.std(deul[j]) > 1e-3 else 0.0 for j in range(3)]
                j = int(np.argmax(np.abs(cors)))
                match.append(f"g{'xyz'[i]}→{'rpy'[j]}({cors[j]:+.2f})")
            lines.append(f"   gyro↔euler match    : {'  '.join(match)}")

        if typ == "still":
            ok = drift < TH_STILL_DRIFT
            verdict = "PASS" if ok else f"FAIL (drift {drift*100:.1f}cm ≥ {TH_STILL_DRIFT*100:.0f}cm)"
        elif typ == "rotation":
            ok = drift < TH_ROT_DRIFT and excur < TH_ROT_EXCURSION
            verdict = ("PASS" if ok else
                       f"FAIL (rotation leaked into position: drift {drift*100:.1f}cm, "
                       f"excursion {excur*100:.1f}cm)")
        else:  # translation
            ok = excur > TH_TRANS_MIN and drift < TH_TRANS_DRIFT
            if excur <= TH_TRANS_MIN:
                verdict = f"FAIL (translation barely registered: excursion {excur*100:.1f}cm)"
            elif drift >= TH_TRANS_DRIFT:
                verdict = f"FAIL (did not return to start: drift {drift*100:.1f}cm)"
            else:
                verdict = "PASS"
        if not ok:
            overall_fail.append(name)
        lines.append(f"   verdict             : {verdict}")
        lines.append("")

    lines.append("═" * 56)
    if overall_fail:
        lines.append(f"OVERALL: FAIL — {', '.join(overall_fail)}")
        if any(s.startswith(("roll", "pitch", "yaw")) for s in overall_fail):
            lines.append("Rotation segments failing → attitude/gravity residual is "
                         "still leaking into linear acceleration during rotation.")
            lines.append("Tuning candidates: ACC_GATE_FRAC, GYRO_DAMP_GAIN, "
                         "MAHONY_TWO_KP in IMU_path.ino.")
    else:
        lines.append("OVERALL: PASS — rotation no longer corrupts position.")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Guided IMU rotation test")
    ap.add_argument("--port", help="serial port (e.g. COM3); auto-detect if omitted")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--log-dir", default=str(Path(__file__).parent / "logs"))
    args = ap.parse_args()

    state = viewer.StreamState(maxlen=500_000)
    stop_event = threading.Event()
    log_file, log_path, report_path = open_test_log(Path(args.log_dir))
    print(f"[log] {log_path}")

    reader = threading.Thread(target=viewer.serial_reader,
                              args=(args, state, stop_event, log_file),
                              daemon=True)
    reader.start()

    print("Төхөөрөмж холбогдохыг хүлээж байна...")
    t_wait = time.time()
    while state.line_count < 10:
        time.sleep(0.5)
        if time.time() - t_wait > 30:
            stop_event.set()
            sys.exit("30s дотор өгөгдөл ирсэнгүй — DEBUG_STREAM=1 firmware "
                     "болон портоо шалгана уу.")
    gravity = gravity_from_calib(state)
    print(f"Холбогдлоо ({state.port_name}), gravityMag={gravity:.3f}. Туршилт эхэлж байна!")

    try:
        segments = record_steps(state)
    except KeyboardInterrupt:
        stop_event.set()
        sys.exit("\nтаслагдлаа — log хадгалагдсан")

    stop_event.set()
    reader.join(timeout=3)
    log_file.flush()
    log_file.close()

    report = analyze(state, segments, gravity)
    print("\n" + report)
    report_path.write_text(report, encoding="utf-8")
    print(f"\n[report] {report_path}")
    print(f"[log]    {log_path}")
    print(f"Replay:  python imu_debug_viewer.py --replay \"{log_path}\"")


if __name__ == "__main__":
    main()
