"""Offline test bench for the tracker's motion tracking (firmware/Gympath_Track).

Simulates a QMI8658 on a cable machine's weight stack (any mounting angle)
during sets of reps — noise, residual gyro bias, accelerometer scale
error, pulley vibration, the stack landing on the pile, pauses at the top
and bottom — and runs the firmware's tracking (a line-by-line port of
calibStep / trackStep / repStep) on it, then compares with the truth:
rep count, range of each rep, lifting velocity, drift of the resting
position.

    python tools/track_sim.py [seeds]    # before (≤1.3.x) vs now (1.4.0+)

Tracker(improved=True) is the firmware since 1.4.0; keep it in step with
trackStep() when the tracking changes, and check the numbers here first.
"""
import math
import sys

import numpy as np

G = 9.80665
FS = 1000.0                         # IMU output data rate (Hz)
DT = 1 / FS


# ------------------------------------------------------------ scenarios
def profile(reps=10, rng_m=0.40, up_s=1.0, down_s=1.6, top_hold=0.0,
            bottom_hold=0.6, start_rest=1.5, end_rest=1.5, varied=True, seed=0,
            bottom_gap=0.0):
    """True stack height z(t) (m) and rep table [(t_start, t_top, t_end, range)]."""
    r = np.random.default_rng(seed)
    z = [np.zeros(int(start_rest * FS))]
    t = start_rest
    table = []
    for i in range(reps):
        k = 1 + (r.uniform(-0.15, 0.15) if varied else 0)
        rm = rng_m * (1 + (r.uniform(-0.1, 0.1) if varied else 0))
        tu, td = up_s * k, down_s * k
        n_u, n_d = int(tu * FS), int(td * FS)
        lo0 = bottom_gap if i > 0 else 0.0          # where this rep starts
        lo1 = bottom_gap if i < reps - 1 else 0.0   # and where it ends
        s = np.linspace(0, 1, n_u, endpoint=False)
        up = lo0 + (rm - lo0) * (1 - np.cos(np.pi * s)) / 2
        s = np.linspace(0, 1, n_d, endpoint=False)
        dn = lo1 + (rm - lo1) * (1 + np.cos(np.pi * s)) / 2
        t0 = t
        z += [up, np.full(int(top_hold * FS), rm), dn, np.full(int(bottom_hold * FS), lo1)]
        t += tu + top_hold + td + bottom_hold
        table.append((t0, t0 + tu, t0 + tu + top_hold + td, rm - max(lo0, lo1) if False else rm - (lo0 + lo1) / 2, 0))
    z.append(np.zeros(int(end_rest * FS)))
    return np.concatenate(z), table


def imu(z, seed=1, tilt=None, vib=0.25, landing=True, gyro_bias_dps=0.05,
        acc_noise=0.035, gyro_noise_dps=0.35, scale_err=0.01, acc_bias=0.03):
    """Accelerometer (m/s², body) and gyro (rad/s, body) for height z."""
    r = np.random.default_rng(seed)
    n = len(z)
    v = np.gradient(z, DT)
    a = np.gradient(v, DT)
    # specific force in the world frame (Z up) + small sway of the stack
    f = np.zeros((n, 3))
    f[:, 2] = a + G
    moving = np.abs(v) > 0.01
    sway = np.zeros((n, 2))
    if vib:
        tt = np.arange(n) * DT
        for k, fr in enumerate((23.0, 37.0)):          # pulley / cable hum
            sway[:, k] = vib * np.sin(2 * np.pi * fr * tt + r.uniform(0, 6)) * moving
        f[:, 2] += vib * 0.6 * np.sin(2 * np.pi * 31.0 * tt) * moving
    f[:, :2] += sway
    if landing:   # the stack touching down on the pile: a damped knock
        idx = np.where((np.abs(v[:-1]) > 0.05) & (np.abs(v[1:]) <= 0.05) & (z[1:] < 0.01))[0]
        for i in idx:
            # ringing with no net push: the derivative of a decaying pulse
            k = np.arange(min(60, n - i) + 1)
            pulse = np.exp(-k / 6) * np.sin(2 * np.pi * k / 8)
            f[i + k[:-1], 2] += 12 * 4 * np.diff(pulse)
    # mounting: any orientation
    if tilt is None:
        q = r.normal(size=4); q /= np.linalg.norm(q)
    else:
        q = tilt
    w0, x, y, zq = q
    R = np.array([[1 - 2 * (y * y + zq * zq), 2 * (x * y - zq * w0), 2 * (x * zq + y * w0)],
                  [2 * (x * y + zq * w0), 1 - 2 * (x * x + zq * zq), 2 * (y * zq - x * w0)],
                  [2 * (x * zq - y * w0), 2 * (y * zq + x * w0), 1 - 2 * (x * x + y * y)]])
    fb = f @ R            # world → body (R^T applied row-wise)
    scale = 1 + r.uniform(-scale_err, scale_err, 3)
    acc = fb * scale + r.uniform(-acc_bias, acc_bias, 3) + r.normal(0, acc_noise, (n, 3))
    gb = np.radians(r.uniform(-gyro_bias_dps, gyro_bias_dps, 3))
    gyr = gb + np.radians(r.normal(0, gyro_noise_dps, (n, 3)))
    # small rocking of the stack while it moves (±0.5°, 2 Hz)
    rock = np.radians(0.5) * 2 * np.pi * 2 * np.cos(2 * np.pi * 2 * np.arange(n) * DT) * moving
    gyr[:, 0] += rock
    return acc, gyr


# ------------------------------------------------------------ the firmware
class Tracker:
    """Port of the firmware (calibStep, trackStep, repStep). Constants as in
    Gympath_Track.ino; IMPROVED switches on the new tracking."""

    def __init__(self, improved=False):
        self.improved = improved
        self.ZUPT_ACC_TH, self.ZUPT_GYRO_TH, self.ZUPT_TIME_S = 0.15, 0.08, 0.08
        self.ACC_LPF, self.ACC_DEADBAND, self.VEL_LEAK = 0.35, 0.04, 0.30
        self.AXIS_REALIGN, self.BIAS_REFINE = 0.02, 0.002
        self.REP_MIN_DISP, self.REP_RETURN_FRAC = 0.05, 0.60
        if improved:
            self.VEL_LEAK = 0.02        # drift handled at rest instead
            self.ACC_DEADBAND = 0.0
            self.HOME_SNAP = 0.03
            self.MAX_SEG_S = 8.0        # longer without rest: no back-correction
            self.ZUPT_MAX_V = 0.12      # m/s
            self.ZUPT_LONG_S = 1.5      # s
            self.BOTTOM_SNAP = 0.06     # m
            self.BOTTOM_VEL = True
            self.BOTTOM_GAIN = 0.5
        self.reset_motion()
        self.reps = 0
        self.calibrated = False

    def reset_motion(self):
        self.aF = self.v = self.p = 0.0
        self.still = 0.0
        self.zupt = False
        self.rep_base = self.p; self.rep_peak = 0.0; self.rep_dir = 0; self.last_dir = 0
        self.seg_t = 0.0            # time moving since the last rest
        self.v_at_still = 0.0
        self.home = 0.0
        self.last_bottom = 0.0

    def calibrate(self, acc, gyr):
        a = acc.mean(axis=0)
        self.gbias = gyr.mean(axis=0)
        self.gmag = np.linalg.norm(a)
        self.up = a / self.gmag
        self.reset_motion()
        self.calibrated = True

    def step(self, a, w, dt=DT):
        w = w - self.gbias
        c = np.cross(w, self.up)
        self.up = self.up - c * dt
        self.up /= np.linalg.norm(self.up)
        mag = math.sqrt(a @ a)
        wm = math.sqrt(w @ w)
        was = self.zupt
        if abs(mag - self.gmag) < self.ZUPT_ACC_TH and wm < self.ZUPT_GYRO_TH:
            if self.still == 0.0:
                self.v_at_still = self.v       # velocity when it went quiet
            self.still += dt
        else:
            self.still = 0.0
        if self.improved:
            # Quiet sensors alone also happen mid-stroke, at constant speed
            # (a slow, smooth lowering): only call it rest when the speed we
            # are tracking is low too, or it has been quiet for a long time.
            self.zupt = self.still > self.ZUPT_TIME_S and (
                abs(self.v) < self.ZUPT_MAX_V or self.still > self.ZUPT_LONG_S)
        else:
            self.zupt = self.still > self.ZUPT_TIME_S
        aUp = a @ self.up - self.gmag
        self.aF += self.ACC_LPF * (aUp - self.aF)
        aUse = 0.0 if abs(self.aF) < self.ACC_DEADBAND else self.aF
        if self.zupt:
            if self.improved and not was:
                # Back-correct the movement that just ended: it began and
                # ended at rest, so any velocity left is drift; assuming it
                # grew evenly, the position is off by half its area.
                T = self.seg_t
                if 0 < T < self.MAX_SEG_S:
                    self.p -= self.v_at_still * T / 2 + self.v * self.ZUPT_TIME_S
                if abs(self.p - self.home) < self.HOME_SNAP:
                    self.p = self.home           # back on the pile
            self.v = 0.0
            self.last_bottom = self.p
            an = a / mag
            self.up += self.AXIS_REALIGN * (an - self.up)
            self.gbias += self.BIAS_REFINE * w
            self.up /= np.linalg.norm(self.up)
            self.gmag += 0.01 * (mag - self.gmag)
            self.seg_t = 0.0
        else:
            v_before = self.v
            self.v += aUse * dt
            self.v *= math.exp(-self.VEL_LEAK * dt)
            self.seg_t += dt
            if self.improved and v_before < 0 <= self.v and self.seg_t > 0.3:
                # Bottom of a stroke without a rest (reps back to back): the
                # stack comes back to about where the last stroke started,
                # so most of the gap is drift (position and the velocity
                # error that built it up evenly since then).
                e = self.p - self.last_bottom
                if abs(e) < self.BOTTOM_SNAP:
                    k = self.BOTTOM_GAIN
                    self.p -= k * e
                    if self.BOTTOM_VEL:
                        self.v -= k * 2 * e / self.seg_t
                self.last_bottom = self.p
                self.seg_t = 0.0
        self.p += self.v * dt
        self.rep_step()

    def rep_step(self):
        if self.rep_dir == 0:
            d = self.p - self.rep_base
            if self.zupt:
                self.rep_base = self.p; self.last_dir = 0
            elif self.last_dir != 0 and d * self.last_dir < 0:
                self.rep_base = self.p
            d = self.p - self.rep_base
            if abs(d) >= self.REP_MIN_DISP:
                self.rep_dir = 1 if d > 0 else -1
                self.rep_peak = abs(d)
            return
        out = (self.p - self.rep_base) * self.rep_dir
        self.rep_peak = max(self.rep_peak, out)
        if out <= (1 - self.REP_RETURN_FRAC) * self.rep_peak:
            self.reps += 1
            self.last_dir = self.rep_dir; self.rep_dir = 0; self.rep_base = self.p


def run(z, table, acc, gyr, improved):
    t = Tracker(improved)
    n_cal = int(0.5 * FS)
    t.calibrate(acc[:n_cal], gyr[:n_cal])
    P, V, R = [], [], []
    for i in range(n_cal, len(z)):
        t.step(acc[i], gyr[i])
        P.append(t.p); V.append(t.v); R.append(t.reps)
    P, V, R = np.array(P), np.array(V), np.array(R)
    zt = z[n_cal:] - z[n_cal]
    vt = np.gradient(z, DT)[n_cal:]
    # rep windows like the app (between counts)
    errs_range, errs_vel = [], []
    for (t0, ttop, t1, rm, _) in table:
        i0 = int(t0 * FS) - n_cal; i1 = int(t1 * FS) - n_cal; itop = int(ttop * FS) - n_cal
        if i0 < 0:
            continue
        est = P[i0:i1 + 1].max() - P[i0:i1 + 1].min()
        errs_range.append((est - rm) / rm * 100)
        up_v = V[i0:itop]
        tv = vt[i0 + n_cal - n_cal:itop]
        if len(up_v):
            errs_vel.append((up_v[up_v > 0.03].mean() - tv[tv > 0.03].mean()) / tv[tv > 0.03].mean() * 100)
    rest = P[-int(1.0 * FS):].mean() - zt[-int(1.0 * FS):].mean()
    return dict(reps=int(R[-1]), true=len(table),
                range_err=float(np.mean(np.abs(errs_range))),
                range_bias=float(np.mean(errs_range)),
                vel_err=float(np.mean(np.abs(errs_vel))),
                drift_cm=float(abs(rest) * 100),
                rms_cm=float(np.sqrt(np.mean((P - zt) ** 2)) * 100))


SCENARIOS = {
    "steady 10 reps": dict(),
    "pause at top 1 s": dict(top_hold=1.0),
    "no rest between reps": dict(bottom_hold=0.0),
    "slow eccentric 3 s": dict(down_s=3.0),
    "short range 15 cm": dict(rng_m=0.15),
    "fast 0.6 s up": dict(up_s=0.6, down_s=0.9),
    "long set 20 reps": dict(reps=20),
    "back to back, 4 cm off pile": dict(bottom_hold=0.0, bottom_gap=0.04),
    "back to back, 10 cm off pile": dict(bottom_hold=0.0, bottom_gap=0.10),
}


def main():
    rows = []
    for name, kw in SCENARIOS.items():
        res = {False: [], True: []}
        for seed in range(int(sys.argv[1]) if len(sys.argv) > 1 else 6):
            z, table = profile(seed=seed, **kw)
            acc, gyr = imu(z, seed=seed + 100)
            for imp in (False, True):
                res[imp].append(run(z, table, acc, gyr, imp))
        rows.append((name, res))
    keys = ["reps ok", "range |err| %", "range bias %", "velocity |err| %", "rest drift cm", "rms cm"]
    print(f"{'scenario':24s} {'':8s}" + "".join(f"{k:>18s}" for k in keys))
    for name, res in rows:
        for imp in (False, True):
            r = res[imp]
            ok = sum(x["reps"] == x["true"] for x in r)
            vals = [f"{ok}/{len(r)}",
                    f"{np.mean([x['range_err'] for x in r]):.1f}",
                    f"{np.mean([x['range_bias'] for x in r]):+.1f}",
                    f"{np.mean([x['vel_err'] for x in r]):.1f}",
                    f"{np.mean([x['drift_cm'] for x in r]):.1f}",
                    f"{np.mean([x['rms_cm'] for x in r]):.1f}"]
            print(f"{name if not imp else '':24s} {'new' if imp else 'now':8s}" + "".join(f"{v:>18s}" for v in vals))


if __name__ == "__main__":
    main()
