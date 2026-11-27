"""Put the detailed cable machines into the Movement Studio figures.

    pip install bpy numpy
    python tools/fit_machines_to_figure.py mobile/assets/models/anatomy_male.glb out/anatomy_male.glb
    python tools/fit_machines_to_figure.py mobile/assets/models/anatomy_female.glb out/anatomy_female.glb

The figure (tools/build_anatomy_model.py) carries a simple stand-in machine:
prop_* bones whose clips say, frame by frame, where the bar or the single
handles are (in the hands), where the pulleys, the stack and the seat are.
This script reads those clips, builds the detailed machines
(build_cable_machines.py), places the right one for each exercise and bakes
its parts into clips of the same names, so they play together with the
figure:

  - the machine sits where the figure's pulley is (the cable leaves at p1);
  - the carriage of the functional trainer goes to the hole for the exercise
    (top for pushdown and fly, bottom for curl, face height for face pull),
    its swivel turns towards the handle;
  - the handle (lat bar, V-bar, straight bar, rope, D-handles) follows the
    figure's grip, the cable runs from the pulley to it;
  - the stack rises by the cable drawn out (÷2 on the 2:1 trainer), the
    pulleys turn, the cable segments over the stack shorten;
  - the seat / bench slides to the figure's;
  - the machines of the other exercises are scaled to 0.

The stand-in props are scaled to 0 (their channels removed). Machine
materials are named "machine_*"; the app keeps them out of the muscle tint.
"""
import math
import os
import sys

FIG_IN, FIG_OUT = sys.argv[1], sys.argv[2]
os.environ.setdefault("MAT_PREFIX", "machine_")
os.environ["FPS"] = "30"
sys.argv = [sys.argv[0], "/tmp/_machines_unused"]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
import bpy  # noqa: E402
from mathutils import Matrix, Quaternion, Vector  # noqa: E402

import build_cable_machines as B  # noqa: E402
import gltf_io as G  # noqa: E402

FPS, STEP = 30, 2
RX90 = np.array([[1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0], [0, 0, 0, 1]], float)   # glTF → Blender
PROPS = ["prop_bar", "prop_handle_l", "prop_handle_r", "prop_pulley_a", "prop_pulley_b", "prop_stack",
         "prop_seat_a", "prop_seat_b"]

# Exercise → machine, its turn about Z (the figure faces -Y), the sides used
# (functional trainer: tower → what it holds), carriage hole, attachment.
EX = {
    "LatPulldown": dict(m="lp", yaw=math.pi),
    "SeatedCableRow": dict(m="sr", yaw=math.pi),
    "TricepPushdown": dict(m="ft", yaw=math.pi, sides={"R": "bar"}, hole=29, att="pushdown_bar"),
    "CableBicepCurl": dict(m="ft", yaw=math.pi, sides={"R": "bar"}, hole=0, att="curl_bar"),
    "FacePull": dict(m="ft", yaw=math.pi, sides={"R": "rope"}, hole=25, att=None),
    "CableChestFly": dict(m="ft", yaw=0.0, sides={"R": "l", "L": "r"}, hole=29, att="d_handle"),
}
# How far below the ring each attachment's grip is (its builder's geometry).
GRIP_DROP = {"lat_bar": 0.09, "v_bar": 0.235, "straight_bar": 0.09, "d_handle": 0.19, "pushdown_bar": 0.09,
             "curl_bar": 0.09, "row_bar": 0.09}
ROPE_STRAND = B.ROPE_STRAND
V_GRIP = 0.068               # V-bar grips at ±V_GRIP (att_v_bar)


# ------------------------------------------------------------ the figure ----
fj, fb = G.read_glb(FIG_IN)
NID = {nd.get("name"): i for i, nd in enumerate(fj["nodes"])}
CLIPS = {}
for an in fj["animations"]:
    tr = G.node_tracks(fj, fb, an)
    dur = max(tt[-1] for n in tr for (tt, _, _) in tr[n].values())
    frames = list(range(0, int(round(dur * FPS)) + 1, STEP))
    data = {p: [Matrix((RX90 @ G.node_matrix(fj, tr, NID[p], f / FPS)).tolist()) for f in frames] for p in PROPS}
    if os.environ.get("ONLY_CLIP") and an["name"] not in os.environ["ONLY_CLIP"].split(","):
        continue
    CLIPS[an["name"]] = (frames, data)
print("clips:", ", ".join(CLIPS))


# ------------------------------------------- hands onto the handle (IK) ----
# The figure's hands are placed by its own build; here each is moved (two-
# bone IK: upper arm + forearm, the hand keeps its turn) onto the rigid
# attachment: on a bar the hands keep one spacing all through the clip (no
# sliding), on the lat bar they sit on its bent part, on the rope at the end
# of its fixed-length strands. Helper bones follow (half the joint's turn).
def to_b(v):
    return Vector((v[0], -v[2], v[1]))


def to_g(v):
    return np.array([v[0], v[2], -v[1]])


def q_of(m):
    t = np.trace(m)
    if t > 0:
        r = math.sqrt(1 + t) * 2
        q = [(m[2, 1] - m[1, 2]) / r, (m[0, 2] - m[2, 0]) / r, (m[1, 0] - m[0, 1]) / r, r / 4]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        r = math.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [r / 4, (m[0, 1] + m[1, 0]) / r, (m[0, 2] + m[2, 0]) / r, (m[2, 1] - m[1, 2]) / r]
    elif m[1, 1] > m[2, 2]:
        r = math.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / r, r / 4, (m[1, 2] + m[2, 1]) / r, (m[0, 2] - m[2, 0]) / r]
    else:
        r = math.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / r, (m[1, 2] + m[2, 1]) / r, r / 4, (m[1, 0] - m[0, 1]) / r]
    q = np.array(q)
    return q / np.linalg.norm(q)


def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz])


def q_inv(q):
    return np.array([-q[0], -q[1], -q[2], q[3]])


def q_half(q):
    return G._slerp(np.array([0, 0, 0, 1.0]), q / np.linalg.norm(q), 0.5)


def rot_between(a, b):
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(np.dot(a, b))
    if c < -0.999999:
        p = np.cross(a, [1, 0, 0] if abs(a[0]) < 0.9 else [0, 1, 0])
        p /= np.linalg.norm(p)
        return 2 * np.outer(p, p) - np.eye(3)
    k = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + k + k @ k / (1 + c)


def unscaled(m):
    r = m[:3, :3].copy()
    return r / np.linalg.norm(r, axis=0)


PAR = G.parents(fj)
NODES = fj["nodes"]
ANIM = {a["name"]: a for a in fj["animations"]}
# Where the handle sits in each hand (hand-bone space): from the chest fly,
# whose handle props sit exactly in the grip.
GRIP_LOCAL, GRIP_AXIS = {}, {}
for s in "lr":
    trk = G.node_tracks(fj, fb, ANIM["CableChestFly"])
    hw = G.node_world(fj, trk, NID[f"hand_{s}"], 1.0, PAR)
    gp = G.node_world(fj, trk, NID[f"prop_handle_{s}"], 1.0, PAR)[:3, 3]
    GRIP_LOCAL[s] = (np.linalg.inv(hw) @ np.r_[gp, 1])[:3]
    ax = G.node_world(fj, trk, NID[f"prop_handle_{s}"], 1.0, PAR)[:3, 1]
    GRIP_AXIS[s] = unscaled(hw).T @ (ax / np.linalg.norm(ax))       # in hand space
REST_Q = {n: np.array(NODES[NID[n]].get("rotation", [0, 0, 0, 1]), float) for n in NID if n}
HANDS = {}           # clip -> {"l"/"r": [grip (Blender) per machine frame]}
ROPE = {}            # clip -> [(bottom, zdir) (Blender) per machine frame]


def add_accessor(arr):
    global fb
    arr = np.ascontiguousarray(arr, np.float32)
    fb += b"\x00" * ((4 - len(fb) % 4) % 4)
    fj["bufferViews"].append({"buffer": 0, "byteOffset": len(fb), "byteLength": arr.nbytes})
    fb += arr.tobytes()
    fj["accessors"].append({"bufferView": len(fj["bufferViews"]) - 1, "componentType": 5126, "count": len(arr),
                            "type": "VEC4"})
    return len(fj["accessors"]) - 1


def fit_hands(clip):
    an = ANIM[clip]
    ex = clip.split("@")[0]
    trk = G.node_tracks(fj, fb, an)
    ua = NID["upperarm_l"]
    times = trk[ua]["rotation"][0]
    grips = {s: [] for s in "lr"}
    worlds = []
    for t in times:
        w = {}
        for s in "lr":
            w[s] = {n: G.node_world(fj, trk, NID[f"{n}_{s}"], t, PAR) for n in ("clavicle", "upperarm", "lowerarm", "hand")}
            grips[s].append((w[s]["hand"] @ np.r_[GRIP_LOCAL[s], 1])[:3])
        worlds.append(w)
    gl, gr = np.array(grips["l"]), np.array(grips["r"])
    half = np.linalg.norm(gl - gr, axis=1) / 2
    h0 = float(half.mean())
    targets = {s: [] for s in "lr"}
    rope, axes, zs = [], [], []
    for i, t in enumerate(times):
        mid, across = (gl[i] + gr[i]) / 2, (gl[i] - gr[i]) / (2 * half[i])
        p1 = G.node_world(fj, trk, NID["prop_pulley_a"], t, PAR)[:3, 3]
        z = p1 - mid
        z = z - across * z.dot(across)
        z /= np.linalg.norm(z)
        zs.append(z)
        if ex == "CableChestFly":
            tl, tr_ = gl[i], gr[i]                 # one handle per hand: already in it
        elif ex == "FacePull":                     # rope: strands of fixed length
            hh = min(half[i], ROPE_STRAND - 0.002)
            bottom = mid + z * max(math.sqrt(ROPE_STRAND ** 2 - hh ** 2), 0.10)
            tl = bottom + (gl[i] - bottom) / np.linalg.norm(gl[i] - bottom) * ROPE_STRAND
            tr_ = bottom + (gr[i] - bottom) / np.linalg.norm(gr[i] - bottom) * ROPE_STRAND
            rope.append((to_b(bottom), to_b(z)))
        elif ex == "SeatedCableRow":               # V-bar: its two grips (neutral grip)
            tl, tr_ = mid + across * V_GRIP, mid - across * V_GRIP
            axes.append(np.cross(z, across))       # the grips' axis: the V-bar's local Y
        else:                                      # rigid bar: one spacing
            down = -z * (B.lat_drop(h0) if ex == "LatPulldown" else 0.0)
            tl, tr_ = mid + across * h0 + down, mid - across * h0 + down
        targets["l"].append(tl)
        targets["r"].append(tr_)
    # the hands' turn (onto the grips' axis when the attachment asks for it)
    HR = {s: [] for s in "lr"}
    for s in "lr":
        # palm: down at the start of the clip (the figure's overhand grip); on
        # the V-bar it faces the other hand, the grip's axis along the V's grip
        palm_l = unscaled(worlds[0][s]["hand"]).T @ np.array([0.0, -1.0, 0.0])
        ah = GRIP_AXIS[s] / np.linalg.norm(GRIP_AXIS[s])
        ph = palm_l - ah * np.dot(palm_l, ah)
        ph /= np.linalg.norm(ph)
        fh = np.column_stack([ah, ph, np.cross(ah, ph)])
        prev = None
        for i in range(len(times)):
            hr_new = unscaled(worlds[i][s]["hand"])
            if axes:
                med = (gr[i] - gl[i]) if s == "l" else (gl[i] - gr[i])
                best = None
                for sign in (1, -1):
                    aw = sign * axes[i] / np.linalg.norm(axes[i])
                    pw = med - aw * np.dot(med, aw)
                    pw /= np.linalg.norm(pw)
                    R = np.column_stack([aw, pw, np.cross(aw, pw)]) @ fh.T
                    turn = math.acos(max(-1.0, min(1.0, (np.trace(R @ hr_new.T) - 1) / 2)))
                    if prev is not None and np.dot(aw, prev) < 0:
                        turn += 10                 # no flip from frame to frame
                    if best is None or turn < best[0]:
                        best = (turn, R, aw)
                hr_new, prev = best[1], best[2]
            HR[s].append(hr_new)

    def wrist(s, i, target):
        hw = worlds[i][s]["hand"]
        return target - HR[s][i] @ (GRIP_LOCAL[s] * np.linalg.norm(hw[:3, :3], axis=0))

    def short(s, i, target):
        w = worlds[i][s]
        S, E, W = w["upperarm"][:3, 3], w["lowerarm"][:3, 3], w["hand"][:3, 3]
        reach = np.linalg.norm(E - S) + np.linalg.norm(W - E) - 0.002
        return np.linalg.norm(wrist(s, i, target) - S) - reach

    if ex == "SeatedCableRow":                     # out of reach: bring the handle in
        for i in range(len(times)):
            for _ in range(8):
                over = max(short("l", i, targets["l"][i]), short("r", i, targets["r"][i]))
                if over <= 0:
                    break
                for s in "lr":
                    targets[s][i] = targets[s][i] - zs[i] * (over + 0.002)
    moved = 0.0
    for s in "lr":
        q = {n: [] for n in ("upperarm", "lowerarm", "hand", "shoulder_h", "elbow_h")}
        for i, t in enumerate(times):
            w = worlds[i][s]
            cw, uw, lw, hw = w["clavicle"], w["upperarm"], w["lowerarm"], w["hand"]
            S, E, W = uw[:3, 3], lw[:3, 3], hw[:3, 3]
            g = grips[s][i]
            hr_new = HR[s][i]
            W2 = wrist(s, i, targets[s][i])
            moved = max(moved, float(np.linalg.norm(targets[s][i] - g)))
            a, b_ = np.linalg.norm(E - S), np.linalg.norm(W - E)
            dv = W2 - S
            d = float(np.clip(np.linalg.norm(dv), abs(a - b_) + 1e-4, a + b_ - 1e-4))
            u = dv / np.linalg.norm(dv)
            x = (a * a - b_ * b_ + d * d) / (2 * d)
            y = math.sqrt(max(a * a - x * x, 0.0))
            v = (E - S) - u * np.dot(E - S, u)
            v = v / np.linalg.norm(v) if np.linalg.norm(v) > 1e-9 else np.cross(u, [0, 1, 0])
            if os.environ.get("DEBUG_IK") and abs(d - np.linalg.norm(dv)) > 1e-3:
                print(f"  {clip} {s} t={t:.2f}: arm too short by {(np.linalg.norm(dv) - d) * 1000:.0f} mm")
            E2, W2 = S + u * x + v * y, S + u * d
            R1 = rot_between(E - S, E2 - S)
            R2 = rot_between(R1 @ (W - E), W2 - E2)
            ur, lr_, hr, cr = R1 @ unscaled(uw), R2 @ R1 @ unscaled(lw), hr_new, unscaled(cw)
            if axes:                               # the forearm takes the hand's turn (pronation)
                fstar = hr @ (unscaled(lw).T @ unscaled(hw)).T
                qd = q_of(fstar @ lr_.T)
                dax = (W2 - E2) / np.linalg.norm(W2 - E2)
                tw = np.r_[dax * np.dot(qd[:3], dax), qd[3]]
                tw /= np.linalg.norm(tw)
                lr_ = G.quat_mat(tw) @ lr_
            lu, ll, lh = q_of(cr.T @ ur), q_of(ur.T @ lr_), q_of(lr_.T @ hr)
            sh = q_mul(q_half(q_mul(lu, q_inv(REST_Q[f"upperarm_{s}"]))), REST_Q[f"shoulder_h_{s}"])
            eh = q_mul(q_half(q_mul(ll, q_inv(REST_Q[f"lowerarm_{s}"]))), REST_Q[f"elbow_h_{s}"])
            for n, val in (("upperarm", lu), ("lowerarm", ll), ("hand", lh), ("shoulder_h", sh), ("elbow_h", eh)):
                if q[n] and np.dot(q[n][-1], val) < 0:
                    val = -val
                q[n].append(val)
        for n, vals in q.items():
            node = NID[f"{n}_{s}"]
            for ch in an["channels"]:
                if ch["target"].get("node") == node and ch["target"]["path"] == "rotation":
                    smp = an["samplers"][ch["sampler"]]
                    assert len(G.accessor(fj, fb, smp["input"])) == len(times)
                    smp["output"] = add_accessor(np.array(vals))
    # the corrected grips at the machine's frames (every STEP frames)
    fr = CLIPS[clip][0]
    idx = [int(round(f / FPS / (times[1] - times[0]))) for f in fr]
    HANDS[clip] = {s: [to_b(targets[s][k]) for k in idx] for s in "lr"}
    if rope:
        ROPE[clip] = [rope[k] for k in idx]
    print(f"{clip}: hands moved up to {moved * 100:.1f} cm" + (f", grip spacing {2 * h0:.3f} m" if ex not in
                                                               ("FacePull", "CableChestFly") else ""))


for clip in CLIPS:
    fit_hands(clip)


# ----------------------------------------------------------- the machines --
B.reset()
ft_root, _, FT = B.functional_trainer()
lp_root, _, LP = B.lat_pulldown()
sr_root, _, SR = B.seated_row()
ROOTS = {"ft": ft_root, "lp": lp_root, "sr": sr_root}
bpy.context.view_layer.update()

REST = {}          # object → its rest values


def track(ob, euler=False):
    if ob.name in REST:
        return
    if not euler and ob.rotation_mode != "QUATERNION":
        q = ob.rotation_euler.to_quaternion()
        ob.rotation_mode = "QUATERNION"
        ob.rotation_quaternion = q
    REST[ob.name] = dict(location=ob.location.copy(), scale=ob.scale.copy(),
                         rot=("rotation_euler", ob.rotation_euler.copy()) if euler
                         else ("rotation_quaternion", ob.rotation_quaternion.copy()))


KEYS = {}           # clip → object name → [(frame, {prop: value})]


def key(clip, ob, f, **props):
    KEYS.setdefault(clip, {}).setdefault(ob.name, []).append((f, props))


def key_matrix(clip, ob, f, local):
    loc, rot, sc = local.decompose()
    key(clip, ob, f, location=loc, rotation_quaternion=rot, scale=sc)


def aim(start, end, length0=1.0):
    """Matrix: at start, local -Z towards end, scaled along Z to reach it."""
    d = Vector(end) - Vector(start)
    q = Vector((0, 0, -1)).rotation_difference(d.normalized())
    return Matrix.Translation(start) @ q.to_matrix().to_4x4() @ Matrix.Diagonal((1, 1, d.length / length0, 1))


def frame_from(x, z, origin):
    x = x.normalized()
    z = (z - x * z.dot(x)).normalized()
    y = z.cross(x)
    return Matrix(((x.x, y.x, z.x, origin.x), (x.y, y.y, z.y, origin.y), (x.z, y.z, z.z, origin.z), (0, 0, 0, 1)))


def handle_world(ring, exitp):
    u = (ring - exitp).normalized()
    q = Vector((0, 0, -1)).rotation_difference(u)
    return Matrix.Translation(ring - u * 0.098) @ q.to_matrix().to_4x4()


# Everything that moves in any clip is keyed in every clip (rest if unused).
for r in ROOTS.values():
    track(r)
for side in "LR":
    st = FT["stacks"][side]
    for ob in [st["head"], st["pin"]] + st["plates"]:
        track(ob)
    for ob, _ in FT["pulleys"][side]:
        track(ob, euler=True)
    for ob in (FT["carriage"][side], FT["swivel"][side], FT["drop"][side][0], FT["out"][side][0]):
        track(ob)
    g, a, atts = FT["handle"][side]
    for ob in [g, a] + list(atts.values()) + list(FT["rope"][side].values()):
        track(ob)
for seg, _ in FT["segs"]:
    track(seg)
for P in (LP, SR):
    st = P["stack"]
    for ob in [st["head"], st["pin"]] + st["plates"] + [P["out"][0]] + list(P["handle"]) + [s for s, _ in P["segs"]]:
        track(ob)
    for ob, _ in P["pulleys"]:
        track(ob, euler=True)
track(LP["seat"])
track(SR["bench"])
for e in SR["atts"].values():
    track(e)
PIN_K = 6           # the pin under plate 6 (30 kg)


def lift_stack(clip, st, f, d):
    for ob in [st["head"]] + st["plates"][:PIN_K]:
        r = REST[ob.name]["location"]
        key(clip, ob, f, location=Vector((r.x, r.y, r.z + d)))
    zk = REST[st["plates"][PIN_K - 1].name]["location"].z
    r = REST[st["pin"].name]["location"]
    key(clip, st["pin"], f, location=Vector((r.x, r.y, zk + d)))


def turn_pulleys(clip, pulleys, f, dl, sign=-1):
    for ob, R in pulleys:
        e = REST[ob.name]["rot"][1].copy()
        e.x += sign * dl / R
        key(clip, ob, f, rotation_euler=e)


def place_attachment(kind, grip, across, toward):
    """World frame of the attachment node: its grip at `grip`, its bar along
    `across`, its ring towards `toward` (the pulley)."""
    z = (toward - grip)
    x = across if across.length > 1e-6 else Vector((1, 0, 0))
    m = frame_from(x, z, grip)
    zdir = Vector((m[0][2], m[1][2], m[2][2]))
    return Matrix.Translation(zdir * GRIP_DROP[kind]) @ m, grip + zdir * GRIP_DROP[kind]


def single_machine(clip, P, cfg, Mroot, frames, data, kind):
    """Lat pulldown / seated row."""
    inv = Mroot.inverted()
    exitp_w = Mroot @ P["exit"]
    g, a = P["handle"]
    co, l0 = P["out"]
    L0 = None
    travel = 0.75
    for i, f in enumerate(frames):
        bar = data["prop_bar"][i]
        mid = bar.to_translation()
        across = Vector((bar[0][1], bar[1][1], bar[2][1]))
        if kind == "v_bar":                    # where the hands were fitted to its grips
            hl, hr = HANDS[clip]["l"][i], HANDS[clip]["r"][i]
            mid, across = (hl + hr) / 2, hl - hr
        att_w, ring = place_attachment(kind, mid, across, exitp_w)
        gw = handle_world(ring, exitp_w)
        key_matrix(clip, g, f, inv @ gw)
        key_matrix(clip, a, f, gw.inverted() @ att_w)
        key_matrix(clip, co, f, inv @ aim(exitp_w, gw.to_translation(), l0))
        L = (gw.to_translation() - exitp_w).length
        L0 = L if L0 is None else L0
        d = min(max(0.0, (L - L0) / P["ratio"]), travel)
        lift_stack(clip, P["stack"], f, d)
        turn_pulleys(clip, P["pulleys"], f, L - L0)
        for seg, sl0 in P["segs"]:
            key(clip, seg, f, scale=Vector((1, 1, (sl0 - d) / sl0)))


def ft_side(clip, side, how, cfg, Mroot, frames, data):
    inv = Mroot.inverted()
    cx = FT["cx"][side]
    carn, sw = FT["carriage"][side], FT["swivel"][side]
    hc = B.ft_carriage_z(cfg["hole"])
    cr = REST[carn.name]["location"]
    car_loc = Vector((cr.x, cr.y, hc))
    swl = REST[sw.name]["location"]
    pivot = car_loc + swl                      # machine-local
    zD = hc - 0.06
    drop, dl0 = FT["drop"][side]
    co, l0 = FT["out"][side]
    g, a, atts = FT["handle"][side]
    rope = FT["rope"][side]
    RD = FT["RD"]
    L0, travel = None, 0.85
    for i, f in enumerate(frames):
        key(clip, carn, f, location=car_loc)
        key(clip, drop, f, scale=Vector((1, 1, (B.FT_ZA - zD) / dl0)))
        if how in ("l", "r"):
            hm = data[f"prop_handle_{how}"][i]
            grip_l = inv @ hm.to_translation()
            across_l = inv.to_3x3() @ Vector((hm[0][1], hm[1][1], hm[2][1]))
            kind = "d_handle"
        else:
            bar = data["prop_bar"][i]
            grip_l = inv @ bar.to_translation()
            yc = Vector((bar[0][1], bar[1][1], bar[2][1]))
            across_l = inv.to_3x3() @ yc
            kind = cfg["att"] or "straight_bar"
        target = grip_l
        for _ in range(2):                     # swivel and exit point, then the ring
            h = target - pivot
            yaw = math.atan2(h.x, -h.y)
            dc = pivot + Matrix.Rotation(yaw, 3, "Z") @ Vector((0, -RD, 0))
            exitp = dc + (target - dc).normalized() * RD
            if how == "rope":
                hands = [inv @ HANDS[clip][s_][i] for s_ in "lr"]
                bw, zw = ROPE[clip][i]
                bottom, zdir = inv @ bw, (inv.to_3x3() @ zw).normalized()
                ring = bottom + zdir * 0.075
                att_l = frame_from(hands[0] - hands[1], zdir, ring)
            else:
                att_l, ring = place_attachment(kind, grip_l, across_l, exitp)
            target = ring
        key(clip, sw, f, rotation_quaternion=Quaternion((0, 0, 1), yaw))
        gl = handle_world(ring, exitp)
        key_matrix(clip, g, f, gl)
        key_matrix(clip, co, f, aim(exitp, gl.to_translation(), l0))
        for k, e in atts.items():
            key(clip, e, f, scale=Vector((1, 1, 1)) if k == kind and how != "rope" else Vector((B.HIDE,) * 3))
        if how == "rope":
            key_matrix(clip, a, f, gl.inverted() @ att_l)
            key_matrix(clip, rope["collar"], f, att_l)
            for s, hand in zip("lr", hands):
                key_matrix(clip, rope["strand_" + s], f, aim(bottom, hand, (hand - bottom).length))
                key_matrix(clip, rope["stop_" + s], f, aim(hand, hand + (hand - bottom).normalized(), 1.0))
        else:
            key_matrix(clip, a, f, gl.inverted() @ att_l)
        L = (gl.to_translation() - exitp).length
        L0 = L if L0 is None else L0
        d = min(max(0.0, (L - L0) / FT["ratio"]), travel)
        lift_stack(clip, FT["stacks"][side], f, d)
        pa, pb, pd, pp = FT["pulleys"][side]
        turn_pulleys(clip, [pa, pb, pd], f, L - L0)
        turn_pulleys(clip, [pp], f, d, sign=1)
        for seg, sl0 in FT["segs"]:
            if seg.name.startswith(f"ft_stack_{side}_"):
                key(clip, seg, f, scale=Vector((1, 1, (sl0 - d) / sl0)))


for clip, (frames, data) in CLIPS.items():
    cfg = EX[clip.split("@")[0]]
    p1 = data["prop_pulley_a"][0].to_translation()
    rz = Matrix.Rotation(cfg["yaw"], 4, "Z")
    if cfg["m"] == "lp":
        ref = LP["exit"]
    elif cfg["m"] == "sr":
        ref = SR["exit"]
    else:                                      # pulley D of the tower that p1 belongs to
        side = "R"
        ref = Vector((FT["cx"][side], REST[FT["carriage"][side].name]["location"].y
                      + REST[FT["swivel"][side].name]["location"].y - FT["RD"], 0))
    off = Vector((p1.x, p1.y, 0)) - (rz @ Vector((ref.x, ref.y, 0)))
    Mroot = Matrix.Translation(off) @ rz
    for name, r in ROOTS.items():
        on = name == cfg["m"]
        for f in (frames[0], frames[-1]):
            key(clip, r, f, location=off if on else Vector(), rotation_quaternion=rz.to_quaternion() if on else Quaternion(),
                scale=Vector((1, 1, 1)) if on else Vector((B.HIDE,) * 3))
    if cfg["m"] == "lp":
        single_machine(clip, LP, cfg, Mroot, frames, data, "lat_bar")
        seat = Mroot.inverted() @ data["prop_seat_a"][0].to_translation()
        r = REST[LP["seat"].name]["location"]
        key(clip, LP["seat"], frames[0], location=Vector((r.x, seat.y, seat.z)))
    elif cfg["m"] == "sr":
        single_machine(clip, SR, cfg, Mroot, frames, data, "v_bar")
        for k, e in SR["atts"].items():
            key(clip, e, frames[0], scale=Vector((1, 1, 1)) if k == "v_bar" else Vector((B.HIDE,) * 3))
        pad = Mroot.inverted() @ (data["prop_seat_b"][0].to_translation() + Vector((0, -0.05, 0)))
        r = REST[SR["bench"].name]["location"]
        key(clip, SR["bench"], frames[0], location=Vector((r.x, pad.y, min(pad.z, r.z))))
    else:
        for side, how in cfg["sides"].items():
            ft_side(clip, side, how, cfg, Mroot, frames, data)


# ------------------------------------------------------------------ bake ----
def same(a, b):
    if isinstance(a, Quaternion):
        return abs(a.dot(b)) > 1 - 1e-9
    return (Vector(a) - Vector(b)).length < 1e-6


for clip, (frames, _) in CLIPS.items():
    per = KEYS.get(clip, {})
    for name, rest in REST.items():
        ob = bpy.data.objects[name]
        keys = per.get(name, [])
        props = {}
        for f, pr in keys:
            for p, v in pr.items():
                props.setdefault(p, {})[f] = v
        rot_path = rest["rot"][0]
        base = {"location": rest["location"], "scale": rest["scale"], rot_path: rest["rot"][1]}
        ad = ob.animation_data or ob.animation_data_create()
        ad.action = None
        for p, v0 in base.items():
            series = props.get(p) or {frames[0]: v0}
            fs = sorted(series)
            if p == "rotation_quaternion":            # no sign flips between keys (they
                prev = None                           # would swing the part round)
                for x in fs:
                    q = series[x].copy()
                    if prev is not None and prev.dot(q) < 0:
                        q.negate()
                    series[x] = prev = q
            if all(same(series[x], series[fs[0]]) for x in fs):
                fs = [fs[0]]
            val = series[fs[0]]
            for f in sorted(set([frames[0], frames[-1]] + fs)):
                if f in series:
                    val = series[f]
                setattr(ob, p, val)
                ob.keyframe_insert(p, frame=f)
        act = ad.action
        act.name = f"{clip}__{name}"
        tr = ad.nla_tracks.new()
        tr.name = clip
        st = tr.strips.new(clip, 0, act)
        tr.mute = True
        ad.action = None
        for p, v0 in base.items():
            setattr(ob, p, v0)
    print("baked", clip)
for r in ROOTS.values():                       # hidden unless a clip shows it
    r.scale = (B.HIDE,) * 3

if os.environ.get("DEBUG_ANIM"):
    for n in ("lp_handle", "lat_pulldown"):
        ob = bpy.data.objects[n]
        ad = ob.animation_data
        print(n, [(t.name, t.mute, [(st.name, st.action.name, getattr(st, "action_slot", None)) for st in t.strips]) for t in ad.nla_tracks])
bpy.context.scene.frame_start = 0
bpy.context.scene.frame_end = max(fr[-1] for fr, _ in CLIPS.values())
tmp = FIG_OUT + ".machines.glb"
B.export(tmp, keep_constant=True)
mj, mb = G.read_glb(tmp)
if not os.environ.get("KEEP_TMP"):
    os.remove(tmp)

# ---------------------------------------------------- merge into figure ----
prop_ids = {NID[n] for n in NID if n and n.startswith("prop_")}
for an in fj["animations"]:
    keep = [c for c in an["channels"] if c["target"].get("node") not in prop_ids]
    used = sorted({c["sampler"] for c in keep})
    remap = {s: i for i, s in enumerate(used)}
    an["samplers"] = [an["samplers"][s] for s in used]
    for c in keep:
        c["sampler"] = remap[c["sampler"]]
    an["channels"] = keep
for i in prop_ids:
    fj["nodes"][i]["scale"] = [1e-4, 1e-4, 1e-4]
fj, fb = G.merge(fj, fb, mj, mb)
fj.setdefault("asset", {})["extras"] = {"machines": "tools/fit_machines_to_figure.py"}
G.write_glb(FIG_OUT, fj, fb)
print("wrote", FIG_OUT, os.path.getsize(FIG_OUT) // 1024, "KB")
