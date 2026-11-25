"""Build the Movement Studio models (mobile/assets/models/anatomy_<sex>.glb).

The figure is Quaternius' Universal Base Character of that sex (CC0). The real
muscle shapes of BodyParts3D (one mesh per muscle) are fitted into it bone by
bone, and each muscle group is drawn exactly on the skin: the skin over a
group's muscles (found by rays going straight in from the skin) becomes that
group's own material, cut along clean outlines, so the app lights a muscle up
in its real shape. The figure is rigged to a simple skeleton on its own
joints, with one baked animation per cable exercise.

    pip install bpy numpy scipy pillow
    git clone --depth 1 https://github.com/Kevin-Mattheus-Moerman/BodyParts3D
    # Quaternius "Universal Base Characters" (Standard, free) unzipped in pack/
    QUATERNIUS=pack ANATOMY_SEX=male python tools/build_anatomy_model.py \
        BodyParts3D/assets/BodyParts3D_data mobile/assets/models/anatomy_male.glb
    QUATERNIUS=pack ANATOMY_SEX=female python tools/build_anatomy_model.py \
        BodyParts3D/assets/BodyParts3D_data mobile/assets/models/anatomy_female.glb

ANATOMY_BODY=bodyparts3d builds the earlier see-through BodyParts3D figure.

Data: BodyParts3D, (c) The Database Center for Life Science, licensed under
CC Attribution-Share Alike 2.1 Japan; the muscle outlines in the .glb derive
from it and carry the same licence, and the app shows the credit line.
Characters, hair and textures: Quaternius, CC0.
"""
import collections
import math
import os
import re
import sys

import bpy
import bmesh
import numpy as np
from scipy.spatial import cKDTree
from mathutils import Matrix, Quaternion, Vector

DATA = sys.argv[1]
OUT = sys.argv[2]
PREVIEW_DIR = sys.argv[3] if len(sys.argv) > 3 else None
CACHE = os.environ.get("ANATOMY_CACHE")
# ANATOMY_SEX=female builds the female figure; it needs MPFB_DATA, the
# mpfb2/src/mpfb/data folder (CC0 MakeHuman data).
SEX = os.environ.get("ANATOMY_SEX", "male")
MPFB_DATA = os.environ.get("MPFB_DATA", "")
if not MPFB_DATA and os.environ.get("ANATOMY_BODY", "quaternius") != "quaternius":
    sys.exit("MPFB_DATA must point at mpfb2/src/mpfb/data")

FPS = 30
REP_SECONDS = 4.0
# Rep timeline (fractions of one rep): rest, pull, hold, return, rest.
T_PULL, T_HOLD, T_RETURN, T_REST = 0.10, 0.45, 0.55, 0.92

TARGET_TRIANGLES = 200_000   # muscles + bones budget after edge-collapse decimation
SKIN_TRIANGLES = 46_000
SKIN_ID = "FMA7163"

MUSCLE_COLOR = (0.42, 0.43, 0.46, 1.0)   # resting muscles blend into the skin
SKIN_COLOR = (0.30, 0.31, 0.35, 0.45)    # alpha: how much muscle shows through
SHORTS_COLOR = (0.05, 0.055, 0.065, 1.0)

# Muscles are pushed out along their normals by this much (m): the raw scans
# sit well inside the skin and read thin through it.
MUSCLE_INFLATE = 0.0035 if os.environ.get("ANATOMY_SEX", "male") == "male" else 0.0
# Avatar head: eyes (the app colours the iris) and hair styles, shown one at a
# time by the app. Hair: caps over the scalp (base, extra on top, m).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import real_head  # noqa: E402
# The female figure has one fixed look: hair pulled back into a ponytail.
HAIR_STYLES = ({"hair_ponytail": (0.004, 0.006)} if SEX == "female"
               else {"hair_buzz": (0.0025, 0.0), "hair_short": (0.006, 0.010)})
FACE_MATERIALS = ["sclera", "iris", "pupil"] + list(HAIR_STYLES)
# The solid head fades into the see-through body over the neck: this many
# bands (materials neck1..neckN, each a bit more solid) over NECK_FADE metres.
NECK_BANDS = 8
NECK_FADE = 0.085

# Muscle groups the app can highlight: material name -> name pattern.
GROUPS = [
    ("lats", r"latissimus dorsi|teres major"),
    ("traps", r"trapezius"),
    ("rhomboids", r"rhomboid"),
    ("rear_delts", r"spinal part of .* deltoid"),
    ("side_delts", r"acromial part of .* deltoid"),
    ("front_delts", r"clavicular part of .* deltoid"),
    ("rotator_cuff", r"infraspinatus|teres minor|supraspinatus|subscapularis"),
    ("pecs", r"pectoralis major"),
    ("biceps", r"biceps brachii|brachialis|coracobrachialis"),
    ("triceps", r"triceps brachii|anconeus"),
    ("forearms", r"brachioradialis|carpi|digitorum superficialis|digitorum profundus|"
                 r"extensor digitorum$|extensor digiti minimi|extensor indicis|pollicis longus|"
                 r"palmaris|pronator|supinator"),
    ("abs", r"rectus abdominis|pyramidalis"),
    ("obliques", r"external oblique|internal oblique"),
    ("serratus", r"serratus anterior"),
    ("erectors", r"iliocostalis|longissimus|spinalis|multifidus"),
    ("glutes", r"gluteus"),
    ("quads", r"rectus femoris|vastus"),
    ("hamstrings", r"biceps femoris|semitendinosus|semimembranosus"),
    ("calves", r"gastrocnemius|soleus"),
]
SKIP = r"anal sphincter|levator ani|coccyge|pubo|puborectalis|iliococcygeus"

# Which bones may move a muscle ({s} = l / r). First match wins.
ARM_TORSO = ("pelvis", "spine_01", "spine_02", "spine_03", "upperarm_{s}")
RULES = [
    (r"latissimus dorsi|teres major|pectoralis major", ARM_TORSO + ("clavicle_{s}",), True),
    (r"pectoralis minor|subclavius|serratus anterior", ("spine_02", "spine_03", "clavicle_{s}"), False),
    (r"deltoid", ("clavicle_{s}", "upperarm_{s}"), False),
    (r"infraspinatus|teres minor|supraspinatus|subscapularis", ("clavicle_{s}", "upperarm_{s}"), True),
    (r"trapezius|rhomboid|levator scapulae", ("spine_02", "spine_03", "neck", "head", "clavicle_{s}"), False),
    (r"biceps brachii|brachialis|coracobrachialis|triceps brachii|anconeus",
     ("upperarm_{s}", "lowerarm_{s}"), False),
    (r"hand|pollicis brevis|opponens pollicis|adductor pollicis|flexor retinaculum",
     ("lowerarm_{s}", "hand_{s}"), False),
    (r"brachioradialis|carpi|digitorum superficialis|digitorum profundus|extensor digitorum$|"
     r"extensor digiti minimi|extensor indicis|pollicis longus|palmaris|pronator|supinator",
     ("upperarm_{s}", "lowerarm_{s}", "hand_{s}"), False),
    (r"foot|hallucis brevis|digitorum brevis|flexor accessorius|abductor hallucis",
     ("calf_{s}", "foot_{s}"), False),
    (r"gastrocnemius|soleus|plantaris|popliteus|tibialis|fibularis|digitorum longus|"
     r"hallucis longus|calcaneal", ("thigh_{s}", "calf_{s}", "foot_{s}"), False),
    (r"gluteus|piriformis|obturator|gemellus|quadratus femoris|psoas|iliacus|tensor fasciae|"
     r"iliotibial|sartorius|gracilis|adductor|pectineus|rectus femoris|vastus|biceps femoris|"
     r"semitendinosus|semimembranosus|inguinal",
     ("pelvis", "spine_01", "thigh_{s}", "calf_{s}"), False),
    (r"sternocleidomastoid|scalenus|splenius|capitis|cervicis|longus colli|hyoid|thyroid|"
     r"digastric|platysma|cervical", ("spine_03", "neck", "head"), False),
    (r"masseter|temporalis|pterygoid|buccinator|oris|oculi|nasi|nasalis|frontalis|occipitalis|"
     r"zygomaticus|risorius|mentalis|procerus|supercilii|epicranius|temporoparietalis|labii",
     ("head",), False),
    (r".", ("pelvis", "spine_01", "spine_02", "spine_03"), False),
]

# Cable exercises: arm directions (left arm; +X = left, -Y = front, +Z = up)
# at the start and at the peak of the pull, torso lean (deg, + = forward) and
# shoulder-blade retraction (deg) at start/peak.
EXERCISES = {
    "LatPulldown": dict(
        upper=((0.45, -0.15, 0.88), (0.58, 0.10, -0.81)),
        fore=((0.12, -0.10, 0.99), (-0.06, -0.46, 0.89)),
        lean=(0, -8), retract=(-4, 10)),
    "SeatedCableRow": dict(
        upper=((0.12, -0.95, -0.30), (0.28, 0.72, -0.63)),
        fore=((-0.04, -1.0, -0.06), (-0.04, -0.98, 0.14)),
        lean=(9, -3), retract=(-8, 14)),
    "TricepPushdown": dict(
        upper=((0.10, 0.04, -1.0), (0.10, 0.06, -1.0)),
        fore=((-0.10, -0.80, 0.58), (0.02, -0.10, -0.99)),
        lean=(9, 9), retract=(0, 0)),
    "CableBicepCurl": dict(
        # the bar starts resting on the front of the thighs
        upper=((0.10, -0.06, -1.0), (0.10, -0.12, -0.99)),
        fore=((0.06, -0.38, -0.92), (0.02, -0.62, 0.78)),
        lean=(0, 0), retract=(0, 0)),
    "CableChestFly": dict(
        upper=((0.90, 0.22, -0.28), (0.24, -0.90, -0.34)),
        fore=((0.90, -0.34, -0.12), (-0.36, -0.90, -0.10)),
        lean=(8, 8), retract=(8, -10)),
    "FacePull": dict(
        upper=((0.12, -0.97, 0.16), (0.92, 0.24, 0.12)),
        fore=((-0.05, -0.99, 0.10), (0.12, -0.45, 0.88)),
        lean=(0, -4), retract=(-8, 14)),
}


# Seated exercises: thigh / shin directions (left leg) and hip height (m).
# hip=None puts the thighs level, feet flat on the floor.
SEATED = {
    "LatPulldown": dict(thigh=(0.10, -0.995, 0.0), calf=(0.0, 0.0, -1.0), hip=None),
    "SeatedCableRow": dict(thigh=(0.09, -0.97, 0.20), calf=(0.0, -0.72, -0.69), hip=0.47),
}

# The machine around the figure, per exercise (metres; figure stands at the
# origin facing -Y). p1 = pulley the handle hangs from, p2 = pulley above the
# weight stack, stack = foot of the weight stack, bar = handle length
# (None = follow the hands, 0 = no bar). Chest fly has one pulley per hand.
MACHINE = {
    "LatPulldown": dict(p1=(0, -0.20, 2.12), p2=(0, -0.95, 2.12), stack=(0, -0.95), bar=1.15),
    "SeatedCableRow": dict(p1=(0, -1.45, 0.80), p2=(0, -1.75, 2.05), stack=(0, -1.75), bar=0.24),
    "TricepPushdown": dict(p1=(0, -0.52, 2.12), p2=(0, -1.00, 2.12), stack=(0, -1.00), bar=0.50),
    "CableBicepCurl": dict(p1=(0, -0.72, 0.14), p2=(0, -1.05, 2.05), stack=(0, -1.05), bar=0.50),
    "CableChestFly": dict(p1=(0.98, 0.25, 1.95), p2=(-0.98, 0.25, 1.95), stack=(0.98, 0.25), bar=0),
    "FacePull": dict(p1=(0, -1.35, 1.62), p2=(0, -1.62, 2.05), stack=(0, -1.62), bar=None),
}
# How the hands hold the handle. "fixed": a rigid bar, the hands stay the
# same distance apart all through the rep (that at the start), the arms
# reach it by IK; "follow": a rope / single handles, the hands move freely.
# palm: which way the palms face at the start (overhand / underhand); the
# hand turns so the handle lies across the palm, in the closed fingers.
GRIP = {
    "LatPulldown": dict(width="fixed", palm=(0, -1, 0)),
    "SeatedCableRow": dict(width="fixed", palm=(0, 0, -1)),
    "TricepPushdown": dict(width="fixed", palm=(0, 0, -1)),
    "CableBicepCurl": dict(width="fixed", palm=(0, -1, 0)),
    "FacePull": dict(width="follow", palm=(0, 0, -1)),
    "CableChestFly": None,                 # one handle per hand, as it falls
}
BAR_RADIUS = 0.016
STACK_TRAVEL = 0.32          # how far the weight stack rises at full contraction
STACK_BASE, STACK_HEIGHT = 0.10, 0.36
PROP_BONES = ["prop_bar", "prop_cable_a", "prop_cable_b", "prop_cable_c", "prop_stack",
              "prop_frame", "prop_pulley_a", "prop_pulley_b", "prop_seat_a", "prop_seat_b",
              "prop_handle_l", "prop_handle_r"]
STATIC_MATERIALS = (["skin"] + [f"neck{i}" for i in range(1, NECK_BANDS + 1)]
                    + ["head"] + FACE_MATERIALS + ["shorts", "equipment", "cable", "tracker", "pad"])


# ----------------------------------------------------------------- data ----
def read_stl(part):
    raw = open(os.path.join(DATA, "stl", part + ".stl"), "rb").read()
    count = int(np.frombuffer(raw[80:84], "<u4")[0])
    if 84 + count * 50 != len(raw):          # ASCII STL
        found = re.findall(rb"vertex\s+(\S+)\s+(\S+)\s+(\S+)", raw)
        return np.array(found, dtype=float).reshape(-1, 3, 3) * 0.001
    rec = np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    return np.frombuffer(raw[84:], dtype=rec, count=count)["v"].astype(float) * 0.001


def weld(tris):
    """Index a triangle soup: identical corner positions become one vertex."""
    pts = np.round(tris.reshape(-1, 3), 6)
    verts, inverse = np.unique(pts, axis=0, return_inverse=True)
    faces = inverse.reshape(-1, 3)
    ok = (faces[:, 0] != faces[:, 1]) & (faces[:, 1] != faces[:, 2]) & (faces[:, 0] != faces[:, 2])
    return verts, faces[ok].astype(np.int32)


def decimate(verts, faces, target):
    """Edge-collapse one part down to about `target` triangles."""
    if len(faces) <= target:
        return verts, faces
    me = bpy.data.meshes.new("tmp")
    me.from_pydata(verts.tolist(), [], faces.tolist())
    me.update()
    ob = bpy.data.objects.new("tmp", me)
    bpy.context.scene.collection.objects.link(ob)
    mod = ob.modifiers.new("d", "DECIMATE")
    mod.ratio = target / len(faces)
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)
    out = ob.data
    v = np.zeros(len(out.vertices) * 3)
    out.vertices.foreach_get("co", v)
    out.calc_loop_triangles()
    f = np.zeros(len(out.loop_triangles) * 3, dtype=np.int32)
    out.loop_triangles.foreach_get("vertices", f)
    me = out
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    return v.reshape(-1, 3), f.reshape(-1, 3)


def load_parts():
    if CACHE and os.path.exists(CACHE):
        z = np.load(CACHE, allow_pickle=True)
        return list(z["parts"])
    names = dict(line.rstrip("\n").split("\t")
                 for line in open(os.path.join(DATA, "parts_list_e.txt")).readlines()[1:])
    children = collections.defaultdict(list)
    for line in open(os.path.join(DATA, "conventional_part_of.txt")).readlines()[1:]:
        cols = line.rstrip("\n").split("\t")
        children[cols[0]].append(cols[2])
    have = {f[:-4] for f in os.listdir(os.path.join(DATA, "stl"))}

    def leaves(root, acc):
        if root in have:
            acc.add(root)
        for c in children.get(root, []):
            leaves(c, acc)
        return acc

    parts = []
    for kind, root in (("muscle", "FMA72954"), ("bone", "FMA23881")):
        for pid in sorted(leaves(root, set())):
            name = names[pid]
            if re.search(SKIP, name):
                continue
            verts, faces = weld(read_stl(pid))
            if len(faces) < 4:
                continue
            parts.append(dict(id=pid, name=name, kind=kind, verts=verts, faces=faces))

    # Share the triangle budget by surface area; muscles the app can highlight
    # get the most detail, bones (mostly hidden under muscle) the least.
    def area(p):
        t = p["verts"][p["faces"]]
        return 0.5 * np.linalg.norm(np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]), axis=1).sum()

    def importance(p):
        if p["kind"] == "bone":
            return 0.35
        return 1.0 if any(re.search(pat, p["name"]) for _, pat in GROUPS) else 0.6

    share = np.array([area(p) * importance(p) for p in parts])
    budget = np.maximum(24, TARGET_TRIANGLES * share / share.sum())
    for p, tris in zip(parts, budget):
        p["verts"], p["faces"] = decimate(p["verts"], p["faces"], int(tris))
    verts, faces = decimate(*weld(read_stl(SKIN_ID)), SKIN_TRIANGLES)
    parts.append(dict(id=SKIN_ID, name="skin", kind="skin", verts=verts, faces=faces))
    if CACHE:
        np.savez_compressed(CACHE, parts=np.array(parts, dtype=object))
    return parts


def side_of(name):
    if re.search(r"\bleft\b", name):
        return "l"
    if re.search(r"\bright\b", name):
        return "r"
    return ""


bpy.ops.wm.read_factory_settings(use_empty=True)
parts = load_parts()
ground = min(p["verts"][:, 2].min() for p in parts)
for p in parts:
    p["verts"][:, 2] -= ground
by_name = {p["name"]: p for p in parts}
skin = by_name["skin"]
# Bones only place the joints and guide the skin weights; they are not drawn
# (the skin covers what the muscles leave open).
under_parts = [p for p in parts if p["kind"] != "skin"]
parts = [p for p in parts if p["kind"] == "muscle"]
print(len(parts), "muscles,", sum(len(p["faces"]) for p in parts), "triangles +",
      len(skin["faces"]), "skin")


# ------------------------------------------------------------- skeleton ----
def slab(name, lo, hi):
    """Centroid of the part's vertices between two height fractions."""
    v = by_name[name]["verts"]
    z0, z1 = v[:, 2].min(), v[:, 2].max()
    sel = v[(v[:, 2] >= z0 + lo * (z1 - z0)) & (v[:, 2] <= z0 + hi * (z1 - z0))]
    return sel.mean(axis=0)


def centroid(name):
    return by_name[name]["verts"].mean(axis=0)


def compute_joints():
    """Joint positions from the bone meshes (rest pose)."""
    J = {}
    for s, word in (("l", "left"), ("r", "right")):
        J[f"shoulder_{s}"] = slab(f"{word} humerus", 0.90, 1.0)
        J[f"elbow_{s}"] = slab(f"{word} humerus", 0.0, 0.05)
        wrist_r, wrist_u = slab(f"{word} radius", 0.0, 0.05), slab(f"{word} ulna", 0.0, 0.05)
        J[f"wrist_{s}"] = (wrist_r + wrist_u) / 2
        femur = by_name[f"{word} femur"]["verts"]
        top = femur[femur[:, 2] > femur[:, 2].max() - 0.05]
        inner = top[np.argsort(np.abs(top[:, 0]))[: max(8, len(top) // 3)]]
        J[f"hip_{s}"] = inner.mean(axis=0)
        J[f"knee_{s}"] = slab(f"{word} femur", 0.0, 0.05)
        J[f"ankle_{s}"] = slab(f"{word} tibia", 0.0, 0.04)
        clav = by_name[f"{word} clavicle"]["verts"]
        J[f"sternal_{s}"] = clav[np.argsort(np.abs(clav[:, 0]))[: max(8, len(clav) // 12)]].mean(axis=0)
        scap = by_name[f"{word} scapula"]["verts"]
        J[f"scap_{s}"] = scap.mean(axis=0)
        J[f"scap_low_{s}"] = scap[np.argsort(scap[:, 2])[: max(8, len(scap) // 20)]].mean(axis=0)

    hand_bones = {"l": [], "r": []}
    foot_bones = {"l": [], "r": []}
    for p in under_parts:
        if p["kind"] != "bone":
            continue
        c = p["verts"].mean(axis=0)
        s = "l" if c[0] > 0 else "r"
        if c[2] < J[f"wrist_{s}"][2] + 0.005 and np.linalg.norm(c - J[f"wrist_{s}"]) < 0.24 \
                and abs(c[0]) > abs(J[f"hip_{s}"][0]) + 0.06:
            hand_bones[s].append(p)
        if c[2] < J[f"ankle_{s}"][2] + 0.01:
            foot_bones[s].append(p)
    for s in "lr":
        hv = np.concatenate([p["verts"] for p in hand_bones[s]])
        J[f"handtip_{s}"] = hv[np.argsort(hv[:, 2])[: len(hv) // 10]].mean(axis=0)
        fv = np.concatenate([p["verts"] for p in foot_bones[s]])
        J[f"toe_{s}"] = fv[np.argsort(fv[:, 1])[: len(fv) // 12]].mean(axis=0)
        J[f"heel_{s}"] = fv[np.argsort(-fv[:, 1])[: len(fv) // 12]].mean(axis=0)

    mid_hip = (J["hip_l"] + J["hip_r"]) / 2
    L4 = centroid("fourth lumbar vertebra")
    T11 = centroid("eleventh thoracic vertebra")
    T6 = centroid("sixth thoracic vertebra")
    C7 = centroid("seventh cervical vertebra")
    C1 = centroid("atlas")
    for v in (L4, T11, T6, C7, C1):
        v[0] = 0.0
    mid_hip[0] = 0.0
    head_top = C1 + np.array([0, -0.02, 0.19])
    return J, mid_hip, L4, T11, T6, C7, C1, head_top


J, mid_hip, L4, T11, T6, C7, C1, head_top = compute_joints()

# Skeleton bones (same order as BONES below) and the body segment of each.
BONE_SEGMENTS = ["pelvis", "spine_01", "spine_02", "spine_03", "neck", "head"] + [
    f"{b}_{s}" for s in "lr" for b in ("clavicle", "upperarm", "lowerarm", "hand",
                                       "thigh", "calf", "foot")]
SEGMENT_OF = {b: ("torso" if b in ("pelvis", "spine_01", "spine_02", "spine_03")
                  or b.startswith("clavicle") else "head" if b in ("neck", "head") else b)
              for b in BONE_SEGMENTS}
SEGMENT_ID = {name: k for k, name in enumerate(sorted(set(SEGMENT_OF.values())))}
SEGMENT_LINES = [("torso", "mid_hip", "L4"), ("torso", "L4", "T11"), ("torso", "T11", "T6"),
                 ("torso", "T6", "C7"), ("head", "C7", "head_top")] + [
    (f"{b}_{s}", f"{a1}_{s}", f"{a2}_{s}") for s in "lr" for b, a1, a2 in (
        ("upperarm", "shoulder", "elbow"), ("lowerarm", "elbow", "wrist"),
        ("hand", "wrist", "handtip"), ("thigh", "hip", "knee"), ("calf", "knee", "ankle"),
        ("foot", "ankle", "toe"))]


def segment_lines():
    named = dict(J, mid_hip=mid_hip, L4=L4, T11=T11, T6=T6, C7=C7, head_top=head_top)
    return [(np.asarray(named[a]), np.asarray(named[b])) for _, a, b in SEGMENT_LINES]


# --------------------------------------------------------- female body ----
# The female figure keeps BodyParts3D's muscles and bones, warped by how a
# MakeHuman female differs from a MakeHuman male in the same pose and place.
# Her skin is BodyParts3D's skin warped the same way, so skin and muscles
# stay together exactly as on the male figure.
# ------------------------------------------------- Quaternius body ----
# The body the app shows is Quaternius' Universal Base Character (CC0) of the
# user's sex. It is posed from its T-pose into this figure's rest pose, and
# BodyParts3D's muscles and bones are fitted into it segment by segment so its
# joints and the anatomy's coincide: each limb segment maps bone onto bone
# (length along it, thickness across it as measured on the two skins), and the
# torso maps cross-section onto cross-section along the spine. From here on
# the rig, exercises and props use its joints.
QBODY = os.environ.get("ANATOMY_BODY", "quaternius") == "quaternius"
# How much farther out a hanging arm swings (upper arm, forearm), per unit of
# "pointing down", on the broader Quaternius build.
ARM_SPREAD = (0.36, 0.22) if QBODY else (0.13, 0.10)
QUAT_ROOT = os.environ.get("QUATERNIUS", "")
if QBODY:
    import q_body  # noqa: E402
    QCHAR = q_body.Character(QUAT_ROOT, SEX)
    aims = {}
    for s_ in "lr":
        # Its build is broader than the anatomy figure's: the arms hang out a
        # little more (ARM_SPREAD) so they clear the lats and the armpit
        # keeps its shape.
        up = J[f"elbow_{s_}"] - J[f"shoulder_{s_}"]
        lo = J[f"wrist_{s_}"] - J[f"elbow_{s_}"]
        sx = 1 if s_ == "l" else -1
        up = up / np.linalg.norm(up) + np.array([sx * ARM_SPREAD[0], 0, 0])
        lo = lo / np.linalg.norm(lo) + np.array([sx * ARM_SPREAD[1], 0, 0])
        aims[f"upperarm_{s_}"] = up
        aims[f"lowerarm_{s_}"] = lo
        aims[f"thigh_{s_}"] = J[f"knee_{s_}"] - J[f"hip_{s_}"]
        aims[f"calf_{s_}"] = J[f"ankle_{s_}"] - J[f"knee_{s_}"]
    QCHAR.pose(aims)
    JQ, SQ = QCHAR.rig_joints()
    A_named = dict(J, mid_hip=mid_hip, L4=L4, T11=T11, T6=T6, C7=C7, C1=C1, head_top=head_top)
    Q_named = dict(JQ, **SQ)
    a_skin = skin["verts"]
    q_body_v = QCHAR.body["verts"]
    q_w = QCHAR.rig_weights(QCHAR.body, BONE_SEGMENTS)
    q_seg = np.array([SEGMENT_OF[BONE_SEGMENTS[k]] for k in q_w.argmax(axis=1)])
    seg_names = sorted(set(SEGMENT_OF.values()))

    def soft_segments(pts, named):
        """Soft weights (N, segments) by distance to each segment's lines."""
        D = np.full((len(pts), len(seg_names)), 1e9)
        for seg, a_, b_ in SEGMENT_LINES:
            a0, b0 = np.asarray(named[a_]), np.asarray(named[b_])
            ab = b0 - a0
            t = np.clip(((pts - a0) @ ab) / (ab @ ab), 0, 1)
            d = np.linalg.norm(pts - (a0 + t[:, None] * ab), axis=1)
            c = seg_names.index(seg)
            D[:, c] = np.minimum(D[:, c], d)
        rel = D - D.min(axis=1, keepdims=True)
        W = np.where(rel < 0.08, np.exp(-rel / 0.015), 0.0)
        return W / W.sum(axis=1, keepdims=True), D

    Wa_skin, _ = soft_segments(a_skin, A_named)
    a_seg = np.array(seg_names)[Wa_skin.argmax(axis=1)]

    # Limbs: bone onto bone.
    limb_map = {}
    for seg, a_, b_ in SEGMENT_LINES:
        if seg in ("torso", "head"):
            continue
        ha, ta = np.asarray(A_named[a_]), np.asarray(A_named[b_])
        hq, tq = np.asarray(Q_named[a_]), np.asarray(Q_named[b_])
        ua, uq = (ta - ha) / np.linalg.norm(ta - ha), (tq - hq) / np.linalg.norm(tq - hq)

        def radius(pts, h, u, length):
            """Median distance from the bone, over its middle half."""
            d = pts - h
            t = (d @ u) / length
            mid = (t > 0.25) & (t < 0.75)
            d = d[mid] if mid.sum() > 20 else d
            return np.median(np.linalg.norm(d - (d @ u)[:, None] * u, axis=1))
        la, lq = np.linalg.norm(ta - ha), np.linalg.norm(tq - hq)
        ra = radius(a_skin[a_seg == seg], ha, ua, la) if (a_seg == seg).sum() > 20 else 1.0
        rq = radius(q_body_v[q_seg == seg], hq, uq, lq) if (q_seg == seg).sum() > 20 else 1.0
        limb_map[seg] = (ha, ua, hq, q_body._rotation(ua, uq),
                         np.linalg.norm(tq - hq) / np.linalg.norm(ta - ha), rq / ra)
    print("Quaternius fit, limb (length, thickness) ratios:",
          {k: (round(v[4], 2), round(v[5], 2)) for k, v in limb_map.items()})

    # Torso: cross-section onto cross-section along the spine.
    def spine_t(z, named):
        return (z - named["mid_hip"][2]) / (named["C7"][2] - named["mid_hip"][2])
    bins = np.arange(-0.7, 1.75, 0.05)

    def sections(pts, named):
        t = spine_t(pts[:, 2], named)
        rows = []
        for b in bins:
            sel = np.abs(t - b) < 0.05
            if sel.sum() < 12:
                rows.append([np.nan] * 3)
                continue
            q = pts[sel]
            y0, y1 = np.percentile(q[:, 1], [2, 98])
            x0, x1 = np.percentile(q[:, 0], [2, 98])
            rows.append([(y0 + y1) / 2, max((x1 - x0) / 2, 0.02), max((y1 - y0) / 2, 0.02)])
        rows = np.array(rows)
        for k in range(3):
            ok = ~np.isnan(rows[:, k])
            rows[:, k] = np.interp(bins, bins[ok], rows[ok, k])
        return rows
    sec_a = sections(a_skin[np.isin(a_seg, ["torso", "head"])], A_named)
    sec_q = sections(q_body_v[np.isin(q_seg, ["torso", "head"])], Q_named)

    def map_torso(pts):
        t = spine_t(pts[:, 2], A_named)
        a_ = np.stack([np.interp(t, bins, sec_a[:, k]) for k in range(3)], 1)
        q_ = np.stack([np.interp(t, bins, sec_q[:, k]) for k in range(3)], 1)
        z = Q_named["mid_hip"][2] + t * (Q_named["C7"][2] - Q_named["mid_hip"][2])
        x = pts[:, 0] * q_[:, 1] / a_[:, 1]
        y = q_[:, 0] + (pts[:, 1] - a_[:, 0]) * q_[:, 2] / a_[:, 2]
        return np.stack([x, y, z], 1)

    def map_limb(pts, seg):
        ha, ua, hq, R, s_ax, s_rad = limb_map[seg]
        d = pts - ha
        along = (d @ ua)[:, None] * ua
        return hq + (along * s_ax + (d - along) * s_rad) @ R.T

    def to_quaternius(pts):
        W, _ = soft_segments(pts, A_named)
        out = np.zeros_like(pts)
        for c, seg in enumerate(seg_names):
            sel = W[:, c] > 1e-4
            if not sel.any():
                continue
            f = map_torso(pts[sel]) if seg in ("torso", "head") else map_limb(pts[sel], seg)
            out[sel] += f * W[sel, c][:, None]
        return out

    for p in under_parts:
        p["verts"] = to_quaternius(p["verts"])
    extra = {k: to_quaternius(np.asarray(J[k])[None])[0] for k in J if k.startswith(("scap", "heel"))}
    # The muscles were fitted in the posed figure (arms down like the
    # anatomy's); the rig and the exported skin use Quaternius' T-pose, the
    # pose its skin weights are made for, so a raised arm blends into the
    # body as it should.
    JB, SB = QCHAR.rig_joints(bind=True)
    J = dict(JB, **extra)
    mid_hip, L4, T11, T6, C7, C1, head_top = (SB[k] for k in ("mid_hip", "L4", "T11", "T6", "C7", "C1", "head_top"))
if not QBODY:
    import mh_body  # noqa: E402
    pair = mh_body.posed_pair(MPFB_DATA, J)
if SEX == "female" and not QBODY:
    tris = []
    for f, g in zip(pair["faces"], pair["groups"]):
        if g == "body":
            tris.append([f[0], f[1], f[2]])
            if len(f) == 4:
                tris.append([f[0], f[2], f[3]])
    tris = np.array(tris)
    body_ix = np.unique(tris)

    # Body segment of every MakeHuman vertex (its dominant bone), mapped to
    # the anatomy skeleton's bone names.
    def anat_bone(b):
        side = b[-1] if b[-2:] in ("_l", "_r") else ""
        if b in ("Root", "pelvis"):
            return "pelvis"
        if b == "neck_01":
            return "neck"
        if b.split("_")[0] in ("thumb", "index", "middle", "ring", "pinky"):
            return f"hand_{side}"
        if b.startswith("ball_"):
            return f"foot_{side}"
        return b

    mh_w = np.zeros((len(pair["female"]), len(BONE_SEGMENTS)))
    for b, pairs in mh_body.Rig(MPFB_DATA).weights.items():
        nb = anat_bone(b)
        if nb not in BONE_SEGMENTS or not pairs:
            continue
        ix = np.array([q[0] for q in pairs])
        mh_w[ix, BONE_SEGMENTS.index(nb)] += np.array([q[1] for q in pairs])
    mh_seg = np.array([SEGMENT_ID[SEGMENT_OF[BONE_SEGMENTS[k]]] for k in mh_w.argmax(axis=1)])

    # Each anatomy vertex moves with the MakeHuman vertices of its own
    # segment (an arm resting on the hip follows the arm, not the hip),
    # blended over several cm where segments meet, so the skin and the
    # muscle just under it always move alike.
    def segment_distances(pts):
        ids = sorted(set(SEGMENT_ID.values()))
        D = np.full((len(pts), len(ids)), 1e9)
        for k, (a, b) in enumerate(segment_lines()):
            ab = b - a
            t = np.clip(((pts - a) @ ab) / (ab @ ab), 0, 1)
            d = np.linalg.norm(pts - (a + t[:, None] * ab), axis=1)
            c = ids.index(SEGMENT_ID[SEGMENT_LINES[k][0]])
            D[:, c] = np.minimum(D[:, c], d)
        return ids, D

    seg_ix = {}
    for seg in set(SEGMENT_ID.values()):
        ix = body_ix[mh_seg[body_ix] == seg]
        if len(ix) < 12:
            print("female warp: segment", seg, "has", len(ix), "vertices; using all")
            ix = body_ix
        seg_ix[seg] = (cKDTree(pair["male"][ix]), ix)
    print("female warp segments:", {k: int((mh_seg[body_ix] == v).sum()) for k, v in SEGMENT_ID.items()})

    def warp(pts, target="female"):
        delta = pair[target] - pair["male"]
        ids, D = segment_distances(pts)
        rel = D - D.min(axis=1, keepdims=True)
        W = np.where(rel < 0.15, np.exp(-rel / 0.035), 0.0)
        W /= W.sum(axis=1, keepdims=True)
        move = np.zeros_like(pts)
        for c, seg in enumerate(ids):
            sel = W[:, c] > 1e-4
            if not sel.any():
                continue
            tree, ix = seg_ix[seg]
            d, i = tree.query(pts[sel], k=12)
            w = 1.0 / (d + 0.015) ** 2
            field = (delta[ix][i] * w[:, :, None]).sum(axis=1) / w.sum(axis=1)[:, None]
            move[sel] += field * W[sel, c][:, None]
        return pts + move

    # Skin weights are worked out on the unwarped figure (see below), where
    # the arms are clear of the body as on the male.
    for p in under_parts:
        p["male_verts"] = p["verts"].copy()
    male_skin = skin["verts"].copy()
    # Muscles, bones and skin all move by the same field, so the muscles sit
    # under the skin exactly as on the male (the sports top covers the bust).
    for p in under_parts:
        p["verts"] = warp(p["verts"], "female")
    skin["verts"] = warp(skin["verts"], "female")
    female_skin = skin["verts"].copy()
    J, mid_hip, L4, T11, T6, C7, C1, head_top = compute_joints()

# name -> (head, tail, parent)
BONES = collections.OrderedDict([
    ("pelvis", (mid_hip, L4, None)),
    ("spine_01", (L4, T11, "pelvis")),
    ("spine_02", (T11, T6, "spine_01")),
    ("spine_03", (T6, C7, "spine_02")),
    ("neck", (C7, C1, "spine_03")),
    ("head", (C1, head_top, "neck")),
])
for s in "lr":
    BONES[f"clavicle_{s}"] = (J[f"sternal_{s}"], J[f"shoulder_{s}"], "spine_03")
    BONES[f"upperarm_{s}"] = (J[f"shoulder_{s}"], J[f"elbow_{s}"], f"clavicle_{s}")
    BONES[f"lowerarm_{s}"] = (J[f"elbow_{s}"], J[f"wrist_{s}"], f"upperarm_{s}")
    BONES[f"hand_{s}"] = (J[f"wrist_{s}"], J[f"handtip_{s}"], f"lowerarm_{s}")
    BONES[f"thigh_{s}"] = (J[f"hip_{s}"], J[f"knee_{s}"], "pelvis")
    BONES[f"calf_{s}"] = (J[f"knee_{s}"], J[f"ankle_{s}"], f"thigh_{s}")
    BONES[f"foot_{s}"] = (J[f"ankle_{s}"], J[f"toe_{s}"], f"calf_{s}")
# Helper bones (Quaternius figure): one at the shoulder, hip, elbow and knee
# that turns half as far as the bone below the joint. The skin around the
# joint follows it, so a bend is shared out over the joint instead of the
# skin being averaged between two bones (which pinches and folds it).
# name -> (bone above the joint, bone below it, bones counted as "above",
#          reach of the joint's skin in metres)
HELPERS = {}
if QBODY:
    for s_ in "lr":
        HELPERS[f"shoulder_h_{s_}"] = (f"clavicle_{s_}", f"upperarm_{s_}",
                                       (f"clavicle_{s_}", "spine_03", "spine_02"), 0.13)
        HELPERS[f"elbow_h_{s_}"] = (f"upperarm_{s_}", f"lowerarm_{s_}", (f"upperarm_{s_}",), 0.08)
        HELPERS[f"hip_h_{s_}"] = ("pelvis", f"thigh_{s_}", ("pelvis", "spine_01"), 0.12)
        HELPERS[f"knee_h_{s_}"] = (f"thigh_{s_}", f"calf_{s_}", (f"thigh_{s_}",), 0.09)
    for h, (above, below, _, _) in HELPERS.items():
        head_, tail_ = np.asarray(BONES[below][0]), np.asarray(BONES[below][1])
        BONES[h] = (head_, head_ + 0.3 * (tail_ - head_), above)
BONE_NAMES = list(BONES)


def add_helper_weights(w, v):
    """Hand each joint's blended skin over to its helper bone."""
    w = w.copy()
    for h, (above, below, above_set, reach) in HELPERS.items():
        a = w[:, [BONE_NAMES.index(b) for b in above_set]].sum(axis=1)
        b_ = w[:, BONE_NAMES.index(below)]
        tot = a + b_
        t = np.where(tot > 1e-6, b_ / np.maximum(tot, 1e-6), 0.0)
        joint = np.asarray(BONES[below][0])
        near = np.exp(-(np.linalg.norm(v - joint, axis=1) / reach) ** 2)
        f = 0.75 * 4 * t * (1 - t) * near * (tot > 0.05)
        cols = [BONE_NAMES.index(x) for x in above_set] + [BONE_NAMES.index(below)]
        w[:, cols] *= (1 - f)[:, None]
        w[:, BONE_NAMES.index(h)] += f * tot
    return w / np.maximum(w.sum(axis=1, keepdims=True), 1e-9)


def box(a, b, half_width, front):
    """Proxy lines for a torso segment: its axis, both flanks and the front wall."""
    a, b = np.array(a), np.array(b)
    w, f = np.array([half_width, 0, 0]), np.array([0, -front, 0])
    return [(a, b), (a + w, b + w), (a - w, b - w), (a + f, b + f),
            (a + w * 0.7 + f * 0.7, b + w * 0.7 + f * 0.7),
            (a - w * 0.7 + f * 0.7, b - w * 0.7 + f * 0.7)]


# Lines used to measure "how close is this vertex to that bone".
PROXY = {
    "pelvis": box(mid_hip, L4, 0.13, 0.10) + [(J["hip_l"], J["hip_r"])],
    "spine_01": box(L4, T11, 0.125, 0.13),
    "spine_02": box(T11, T6, 0.135, 0.17),
    "spine_03": box(T6, C7, 0.12, 0.15),
    "neck": [(C7, C1)],
    "head": [(C1, head_top), (C1 + np.array([0, -0.08, 0.02]), head_top + np.array([0, -0.06, -0.06]))],
}
for s in "lr":
    PROXY[f"clavicle_{s}"] = [(J[f"sternal_{s}"], J[f"shoulder_{s}"]),
                              (J[f"scap_{s}"], J[f"shoulder_{s}"]),
                              (J[f"scap_{s}"], J[f"scap_low_{s}"])]
    PROXY[f"upperarm_{s}"] = [(J[f"shoulder_{s}"], J[f"elbow_{s}"])]
    PROXY[f"lowerarm_{s}"] = [(J[f"elbow_{s}"], J[f"wrist_{s}"])]
    PROXY[f"hand_{s}"] = [(J[f"wrist_{s}"], J[f"handtip_{s}"])]
    PROXY[f"thigh_{s}"] = [(J[f"hip_{s}"], J[f"knee_{s}"])]
    PROXY[f"calf_{s}"] = [(J[f"knee_{s}"], J[f"ankle_{s}"])]
    PROXY[f"foot_{s}"] = [(J[f"ankle_{s}"], J[f"toe_{s}"]), (J[f"ankle_{s}"], J[f"heel_{s}"])]


def distance_to(bone, pts):
    best = np.full(len(pts), 1e9)
    for a, b in PROXY[bone]:
        ab = b - a
        t = np.clip(((pts - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
        best = np.minimum(best, np.linalg.norm(pts - (a + t[:, None] * ab), axis=1))
    return best


def skin_weights(part):
    """(n, n_bones) weight matrix for one part."""
    pts = part["verts"]
    w = np.zeros((len(pts), len(BONE_NAMES)))
    s = side_of(part["name"]) or ("l" if pts[:, 0].mean() > 0 else "r")
    if part["kind"] == "bone":
        name = part["name"]
        if re.search(r"scapula|clavicle", name):
            bone = f"clavicle_{s}"
        else:
            c = pts.mean(axis=0)[None, :]
            bone = min(BONE_NAMES, key=lambda b: distance_to(b, c)[0])
        w[:, BONE_NAMES.index(bone)] = 1
        return w
    for pattern, bones, arm_needs_height in RULES:
        if re.search(pattern, part["name"]):
            break
    sides = [side_of(part["name"])] if side_of(part["name"]) else ["l", "r"]
    allowed = []
    for b in bones:
        for sd in (sides if "{s}" in b else [""]):
            nm = b.format(s=sd)
            if nm not in allowed:
                allowed.append(nm)
    dist = np.stack([distance_to(b, pts) for b in allowed], axis=1)
    if arm_needs_height:
        # Only the tendon end near the shoulder may follow the arm.
        for k, b in enumerate(allowed):
            if b.startswith("upperarm"):
                low = pts[:, 2] < J[f"shoulder_{b[-1]}"][2] - 0.085
                dist[low, k] = 1e9
    soft = np.exp(-(dist - dist.min(axis=1, keepdims=True)) / 0.022)
    soft /= soft.sum(axis=1, keepdims=True)
    for k, b in enumerate(allowed):
        w[:, BONE_NAMES.index(b)] = soft[:, k]
    return w


def group_of(part):
    for group, pattern in GROUPS:
        if re.search(pattern, part["name"]):
            return group
    return "other_muscle"


# ---------------------------------------------------------------- build ----
scene = bpy.context.scene
scene.render.fps = FPS

def vertex_normals(v, f):
    """Area-weighted vertex normals, flipped to point away from the centroid."""
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    n = np.zeros_like(v)
    for k in range(3):
        np.add.at(n, f[:, k], fn)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    if ((v - v.mean(axis=0)) * n).sum() < 0:
        n = -n
    return n


# --- avatar head ---------------------------------------------------------------
# The head is the skin's own head, drawn solid, with BodyParts3D's eyes (the
# app colours the iris) and hair. The neck line where the solid head starts
# sits just under the jaw.
FEMALE = SEX == "female"
NECK_Z = C7[2] + 0.55 * (C1[2] - C7[2])
print("neck line", round(NECK_Z, 3), "C7", round(C7[2], 3), "C1", round(C1[2], 3))


# The head is drawn solid, so the face and scalp muscles are never seen; they
# would only poke through the thin face skin once inflated.
_neck_cut = NECK_Z
parts = [p for p in parts
         if not (p["verts"][:, 2].mean() > _neck_cut and abs(p["verts"][:, 0].mean()) < 0.14)]
# Near the head the skin is thin and fades to solid: muscles there are not
# inflated but pulled slightly in (so they never poke through), and whatever
# lies under the solid head is dropped.
_fade_bottom = _neck_cut - NECK_FADE


def neck_fade(z):
    """1 below the neck fade, 0 from its middle up."""
    return np.clip((_fade_bottom + NECK_FADE * 0.5 - z) / (NECK_FADE * 0.5), 0, 1)


for p in parts:
    v, f = p["verts"], p["faces"]
    keep_f = ~(v[f][:, :, 2] > _neck_cut - 0.35 * NECK_FADE).any(axis=1)
    if not keep_f.all():
        used = np.unique(f[keep_f])
        remap = -np.ones(len(v), int)
        remap[used] = np.arange(len(used))
        p["verts"], p["faces"] = v[used], remap[f[keep_f]]
        if "male_verts" in p:
            p["male_verts"] = p["male_verts"][used]
parts = [p for p in parts if len(p["faces"]) >= 4]

# Fitness view: only the muscles people train and recognise are drawn (the
# groups above), without the deep ones that lie under them. Small and deep
# muscles only add clutter showing through the skin.
DEEP = r"multifidus|internal oblique|gluteus minimus|digitorum profundus|pronator quadratus|" \
       r"supinator|flexor pollicis longus|coracobrachialis|subscapularis"
_before = len(parts)
parts = [p for p in parts if group_of(p) != "other_muscle" and not re.search(DEEP, p["name"])]
print("fitness muscles:", len(parts), "of", _before)


def taubin(v, f, rounds=6, lam=0.5, mu=-0.53):
    """Smooth a mesh without shrinking it (removes the faceting left by
    decimation, keeps the muscle's shape)."""
    from scipy.sparse import coo_matrix
    n = len(v)
    i = np.concatenate([f[:, 0], f[:, 1], f[:, 2], f[:, 1], f[:, 2], f[:, 0]])
    j = np.concatenate([f[:, 1], f[:, 2], f[:, 0], f[:, 0], f[:, 1], f[:, 2]])
    adj = coo_matrix((np.ones(len(i)), (i, j)), shape=(n, n)).tocsr()
    adj.data[:] = 1.0
    deg = np.maximum(np.asarray(adj.sum(axis=1)).ravel(), 1)[:, None]
    for _ in range(rounds):
        for k in (lam, mu):
            v = v + k * (adj @ v / deg - v)
    return v


for p in parts:
    p["verts"] = taubin(p["verts"], p["faces"])
for p in parts:
    p["normals"] = vertex_normals(p["verts"], p["faces"])
    p["fade"] = neck_fade(p["verts"][:, 2])
    push = MUSCLE_INFLATE * p["fade"] - 0.004 * (1 - p["fade"])
    p["verts"] = p["verts"] + p["normals"] * push[:, None]

if SEX == "female" and not QBODY:
    # Her clothes are opaque: muscle under them is never seen but could poke
    # through the reshaped skin, so the parts of torso and hip muscles that
    # lie under the shorts and the sports top are left out.
    _hip = (J["hip_l"][2] + J["hip_r"][2]) / 2
    _bands = [(_hip - 0.17, _hip + 0.125, ("torso", "thigh_l", "thigh_r")),
              (T11[2] + 0.45 * (T6[2] - T11[2]), C7[2] - 0.11, ("torso",))]
    _lines = list(zip([n for n, _, _ in SEGMENT_LINES], segment_lines()))
    dropped = 0
    for p in parts:
        v, f = p["verts"], p["faces"]
        best = np.full(len(v), 1e9)
        seg = np.empty(len(v), dtype=object)
        for name, (sa, sb) in _lines:
            ab = sb - sa
            t = np.clip(((v - sa) @ ab) / (ab @ ab), 0, 1)
            d = np.linalg.norm(v - (sa + t[:, None] * ab), axis=1)
            closer = d < best
            best[closer], seg[closer] = d[closer], name
        hidden = np.zeros(len(v), bool)
        for lo, hi, segs in _bands:
            hidden |= (v[:, 2] > lo + 0.01) & (v[:, 2] < hi - 0.01) & np.isin(seg, segs)
        drop = hidden[f].all(axis=1)
        if drop.any():
            dropped += int(drop.sum())
            p["faces"] = f[~drop]
    parts = [p for p in parts if len(p["faces"]) >= 4]
    print("female: left out", dropped, "muscle triangles under her clothes")

if QBODY:
    # The body is opaque: each muscle group is a region of its skin, plus
    # "skin" (between and beyond them), the eyes, brows and hair styles.
    STATIC_MATERIALS = (["skin", "shorts", "sclera", "iris", "pupil", "brows"] + list(q_body.HAIR[SEX])
                        + ["equipment", "cable", "tracker", "pad"])
    FACE_MATERIALS = ["sclera", "iris", "pupil", "brows"] + list(q_body.HAIR[SEX])
    # A group's region over the underwear is its own material (<group>_cloth)
    # so it can light up in the cloth's colour.
    material_names = ([g for g, _ in GROUPS] + [g + "_cloth" for g, _ in GROUPS]
                      + STATIC_MATERIALS)
else:
    material_names = [g for g, _ in GROUPS] + ["other_muscle"] + STATIC_MATERIALS
all_verts, all_faces, all_mats, all_w, all_uv = [], [], [], [], []
offset = 0
for p in ([] if QBODY else parts):
    all_verts.append(p["verts"])
    all_faces.append(p["faces"] + offset)
    all_mats.append(np.full(len(p["faces"]), material_names.index(group_of(p))))
    all_w.append(skin_weights(p))
    offset += len(p["verts"])

# --------------------------------------------------- Quaternius skin ----
def smooth_field(field, faces, n_verts, rounds):
    """Average a per-vertex field with its mesh neighbours a few times."""
    from scipy.sparse import coo_matrix, identity
    i = np.concatenate([faces[:, 0], faces[:, 1], faces[:, 2], faces[:, 1], faces[:, 2], faces[:, 0]])
    j = np.concatenate([faces[:, 1], faces[:, 2], faces[:, 0], faces[:, 0], faces[:, 1], faces[:, 2]])
    adj = coo_matrix((np.ones(len(i)), (i, j)), shape=(n_verts, n_verts)).tocsr()
    adj.data[:] = 1.0
    adj = adj + identity(n_verts, format="csr")
    deg = np.asarray(adj.sum(axis=1)).ravel()
    for _ in range(rounds):
        field = adj @ field / (deg[:, None] if field.ndim == 2 else deg)
    return field


# Body shape morphs the user sets in the app (glTF morph targets on the
# skin, in the rest pose). Each is a smooth push of the skin: small enough
# that the skin stays on its bones.
BODY_MORPHS = []          # (first vertex, {morph: deltas})
MORPH_NAMES = ["Muscle", "BodyFat", "Shoulders", "Waist", "Chest"]


def body_morphs(v, f, w, share, groups):
    n = vertex_normals(v, f)
    bi = {b: BONE_NAMES.index(b) for b in BONE_NAMES}

    def wsum(*names):
        return sum(w[:, bi[b]] for b in names)

    def bump(z, centre, width):
        return np.exp(-((z - centre) / width) ** 2)

    def smoothed(x, rounds=6):
        return smooth_field(x, f, len(v), rounds)
    z, x = v[:, 2], v[:, 0]
    hip_z = (J["hip_l"][2] + J["hip_r"][2]) / 2
    waist_z = L4[2] + 0.06
    torso = wsum("pelvis", "spine_01", "spine_02", "spine_03")
    front, back = np.clip(-n[:, 1], 0, 1), np.clip(n[:, 1], 0, 1)
    gshare = {g: share[:, k] for k, g in enumerate(groups)}

    def g(*names):
        return sum(gshare.get(k, 0) for k in names)
    out = {}
    # Muscle: every trained group swells, limbs and chest most.
    m = (g("pecs", "front_delts", "side_delts", "rear_delts", "biceps", "triceps", "traps", "lats",
           "quads", "hamstrings", "calves", "glutes", "forearms") + 0.5 * g("abs", "obliques", "serratus",
                                                                           "rhomboids", "erectors"))
    out["Muscle"] = n * (0.020 * smoothed(np.clip(m, 0, 1)))[:, None]
    # Body fat, where it gathers on a man or on a woman.
    if SEX == "female":
        amt = (0.020 * bump(z, waist_z - 0.03, 0.10) * front * torso
               + 0.018 * bump(z, waist_z, 0.08) * np.abs(n[:, 0]) * torso
               + 0.020 * bump(z, hip_z, 0.12) * wsum("pelvis", "thigh_l", "thigh_r") * (0.5 + back)
               + 0.015 * bump(z, hip_z - 0.16, 0.14) * wsum("thigh_l", "thigh_r")
               + 0.012 * wsum("upperarm_l", "upperarm_r") * (0.4 + back)
               + 0.016 * bump(z, T6[2], 0.08) * front * torso)
    else:
        amt = (0.038 * bump(z, waist_z - 0.02, 0.11) * front * torso
               + 0.024 * bump(z, waist_z, 0.08) * np.abs(n[:, 0]) * torso
               + 0.014 * bump(z, hip_z, 0.12) * wsum("pelvis", "thigh_l", "thigh_r")
               + 0.012 * bump(z, hip_z - 0.16, 0.14) * wsum("thigh_l", "thigh_r")
               + 0.008 * wsum("upperarm_l", "upperarm_r")
               + 0.012 * bump(z, T6[2], 0.08) * front * torso)
    out["BodyFat"] = n * (1.9 * smoothed(amt))[:, None]
    # Shoulders: rounder deltoids and traps, a little wider.
    sh = smoothed(np.clip(g("front_delts", "side_delts", "rear_delts", "traps"), 0, 1))
    near = np.maximum(np.exp(-(np.linalg.norm(v - J["shoulder_l"], axis=1) / 0.12) ** 2),
                      np.exp(-(np.linalg.norm(v - J["shoulder_r"], axis=1) / 0.12) ** 2))
    out["Shoulders"] = n * (0.020 * sh)[:, None] + np.stack([np.sign(x) * 0.022 * near,
                                                            np.zeros_like(x), np.zeros_like(x)], 1)
    # Waist: in or out around the body's axis (the app goes both ways).
    cy = np.median(v[torso > 0.8, 1]) if (torso > 0.8).any() else 0.0
    radial = np.stack([x, v[:, 1] - cy, np.zeros_like(x)], 1)
    radial /= np.maximum(np.linalg.norm(radial, axis=1, keepdims=True), 1e-6)
    out["Waist"] = radial * (0.05 * smoothed(bump(z, waist_z, 0.09) * torso))[:, None]
    # Chest: pectorals, or the bust.
    ch = g("pecs") + (bump(z, T6[2] - 0.03, 0.07) * front * torso * 0.6 if SEX == "female" else 0)
    out["Chest"] = n * ((0.040 if SEX == "female" else 0.026) * smoothed(np.clip(ch, 0, 1)))[:, None]
    return out


def add_piece(mat, v, f, w, uv=None):
    global offset
    all_verts.append(v)
    all_faces.append(f + offset)
    all_mats.append(np.full(len(f), material_names.index(mat)) if isinstance(mat, str) else mat)
    all_w.append(w)
    all_uv.append(uv if uv is not None else np.zeros((len(v), 2)))
    offset += len(v)


if QBODY:
    # Muscle groups drawn exactly on the skin: from every skin point a ray
    # goes straight in (along the inward normal); the first fitted muscle it
    # meets gives the point its group, so each group covers precisely the
    # skin over its muscles and a deeper muscle is hidden by the one over
    # it. The point labels are smoothed over the surface and the skin is cut
    # along their half-way lines, with a thin line of plain skin between
    # neighbouring groups, so the outlines are clean curves.
    RAY_START, RAY_DEPTH = 0.025, 0.08     # m outside the skin, m inside it
    LINE = 0.12                            # gap between groups (label units)
    GAP_FILL_RINGS = 4
    from mathutils import Vector as _V
    from mathutils.bvhtree import BVHTree
    qb = QCHAR.body
    qv, qf = qb["verts"], qb["faces"]
    attrs = np.concatenate([qb["uv"], QCHAR.rig_weights(qb, BONE_NAMES), qb["bind"]], axis=1)
    qv, attrs, qf = real_head.subdivide(qv, attrs, qf)
    NB = len(BONE_NAMES)
    groups = [g for g, _ in GROUPS if any(group_of(p) == g for p in parts)]
    m_verts, m_faces, m_group, o = [], [], [], 0
    for p in parts:
        m_verts.append(p["verts"])
        m_faces.append(p["faces"] + o)
        m_group.append(np.full(len(p["faces"]), groups.index(group_of(p))))
        o += len(p["verts"])
    m_group = np.concatenate(m_group)
    bvh = BVHTree.FromPolygons([_V(v) for v in np.concatenate(m_verts)],
                               np.concatenate(m_faces).tolist(), epsilon=0.0)
    qn = vertex_normals(qv, qf)
    no_muscle = [BONE_NAMES.index(b) for b in BONE_NAMES if b == "head" or b.startswith(("hand", "foot"))]
    off_body = attrs[:, 2:2 + NB][:, no_muscle].sum(axis=1) > 0.5
    label = np.full(len(qv), -1)
    for i in np.where(~off_body)[0]:
        hit = bvh.ray_cast(_V(qv[i] + qn[i] * RAY_START), _V(-qn[i]), RAY_START + RAY_DEPTH)
        if hit[2] is not None:
            label[i] = m_group[hit[2]]
    # Tidy the labels so every group reads as one clean shape: a majority
    # vote among neighbours removes stray points, then specks of a group (or
    # of bare skin) smaller than MIN_PATCH points join what surrounds them.
    from scipy.sparse import coo_matrix, identity
    from scipy.sparse.csgraph import connected_components
    MIN_PATCH = 40
    ei = np.concatenate([qf[:, 0], qf[:, 1], qf[:, 2]])
    ej = np.concatenate([qf[:, 1], qf[:, 2], qf[:, 0]])
    adj = coo_matrix((np.ones(len(ei)), (ei, ej)), shape=(len(qv), len(qv))).tocsr()
    adj = ((adj + adj.T) > 0).astype(float)
    adj_self = adj + identity(len(qv), format="csr")
    NONE = len(groups)
    lab = np.where(label >= 0, label, NONE)

    def onehot(l):
        return coo_matrix((np.ones(len(l)), (np.arange(len(l)), l)), shape=(len(l), NONE + 1)).tocsr()
    for _ in range(2):
        lab = np.asarray((adj_self @ onehot(lab)).argmax(axis=1)).ravel()
        lab[off_body] = NONE
    for _ in range(2):
        r, c = adj.nonzero()
        keep = lab[r] == lab[c]
        sub = coo_matrix((np.ones(keep.sum()), (r[keep], c[keep])), shape=adj.shape)
        ncomp, comp = connected_components(sub, directed=False)
        sizes = np.bincount(comp, minlength=ncomp)
        small = (sizes[comp] < MIN_PATCH) & ~off_body
        if not small.any():
            break
        # Each small patch takes the label most common around it.
        around = adj @ onehot(np.where(small, NONE, lab))
        around = np.asarray(around.todense())
        around[:, NONE] *= 0.5
        for k in np.unique(comp[small]):
            members = comp == k
            lab[members] = int(around[members].sum(axis=0).argmax())
    # Bare strips the rays missed between groups (the flanks under the arms,
    # where the broader build has more body than the anatomy's muscles) are
    # filled from the groups beside them, a few rings at a time.
    for _ in range(GAP_FILL_RINGS):
        bare = (lab == NONE) & ~off_body
        votes = np.asarray((adj @ onehot(lab)).todense())
        votes[:, NONE] = 0
        take = bare & (votes.sum(axis=1) > 0)
        lab[take] = votes[take].argmax(axis=1)
    label = np.where(lab == NONE, -1, lab)
    print("skin points over a muscle:", round(float((label >= 0).mean()), 2))
    # Smoothed share of each group around every point.
    ind = np.zeros((len(qv), len(groups)))
    ind[label >= 0, label[label >= 0]] = 1.0
    ind = smooth_field(ind, qf, len(qv), 4)
    attrs = np.concatenate([attrs, ind], axis=1)
    # The underwear (black in the texture) is cut out along its edge first.
    from PIL import Image as _Image
    tex = np.asarray(_Image.open(os.path.join(QCHAR.tex_dir, q_body.SKIN_TEXTURE[SEX]))
                     .convert("L").resize((1024, 1024))).astype(float) / 255
    tex /= np.percentile(tex, 90)

    def texture_at(uv):
        x = np.clip((uv[:, 0] % 1.0) * 1023, 0, 1023).astype(int)
        y = np.clip((uv[:, 1] % 1.0) * 1023, 0, 1023).astype(int)
        return tex[y, x]
    qv, attrs, cloth_f, bare_f = real_head.split(qv, qf, 0.6 - texture_at(attrs[:, :2]), attrs)

    def regions(rest):
        """Split faces into the groups' regions; returns (rest, [(group, faces)])."""
        global qv, attrs
        out = []
        for gi, g in enumerate(groups):
            share = attrs[:, 2 + NB + 3:]
            other = np.delete(share, gi, axis=1).max(axis=1)
            field = np.minimum(share[:, gi] - 0.5, share[:, gi] - other - LINE)
            near = (field[rest] > -0.3).any(axis=1)
            if not near.any():
                continue
            qv, attrs, fin, fout = real_head.split(qv, rest[near], field, attrs)
            out.append((g, fin))
            rest = np.concatenate([rest[~near], fout])
        return rest, out
    bare_rest, bare_regions = regions(bare_f)
    cloth_rest, cloth_regions = regions(cloth_f)
    print("skin regions:", {g: len(f) for g, f in bare_regions})
    pieces = ([("skin", bare_rest), ("shorts", cloth_rest)] + bare_regions
              + [(g + "_cloth", f) for g, f in cloth_regions])
    faces_all = np.concatenate([f for _, f in pieces])
    mats_all = np.concatenate([np.full(len(f), material_names.index(n)) for n, f in pieces])
    used = np.unique(faces_all)
    remap = -np.ones(len(qv), int)
    remap[used] = np.arange(len(used))
    w = attrs[used, 2:2 + NB]
    w = w / np.maximum(w.sum(axis=1, keepdims=True), 1e-9)
    sv_, sf_ = attrs[used, 2 + NB:2 + NB + 3], remap[faces_all]      # T-pose positions
    w = add_helper_weights(w, sv_)
    BODY_MORPHS.append((offset, body_morphs(sv_, sf_, w, attrs[used, 2 + NB + 3:], groups)))
    add_piece(mats_all, sv_, sf_, w, attrs[used, :2])
    skin_range = (offset - len(used), offset)

    # Eyes: iris and pupil cut as circles in the eye texture's UV space.
    eye = QCHAR.eyes
    ew = QCHAR.rig_weights(eye, BONE_NAMES)
    uvm = np.stack([eye["uv"][:, 0] % 1.0, eye["uv"][:, 1]], axis=1)
    rad = np.linalg.norm(uvm - np.array([0.494, 0.499]), axis=1)
    ev, ea, f_iris, f_sclera = real_head.split(eye["bind"], eye["faces"], 0.112 - rad,
                                               np.concatenate([ew, eye["uv"]], axis=1))
    uvm = np.stack([ea[:, -2] % 1.0, ea[:, -1]], axis=1)
    rad = np.linalg.norm(uvm - np.array([0.494, 0.499]), axis=1)
    ev, ea, f_pupil, f_iris = real_head.split(ev, f_iris, 0.048 - rad, ea)
    eye_mats = np.concatenate([np.full(len(f_sclera), material_names.index("sclera")),
                               np.full(len(f_iris), material_names.index("iris")),
                               np.full(len(f_pupil), material_names.index("pupil"))])
    add_piece(eye_mats, ev, np.concatenate([f_sclera, f_iris, f_pupil]), ea[:, :-2], ea[:, -2:])

    # Brows and hair styles (Quaternius'), moving with the head.
    for app_id, meshes in QCHAR.hair.items():
        for m in meshes:
            add_piece("brows" if app_id == "brows" else app_id, m["bind"], m["faces"],
                      QCHAR.rig_weights(m, BONE_NAMES), m["uv"])
else:
    # The skin follows whatever lies right under it: each skin vertex takes the
    # blended weights of the nearest muscle / bone vertices. That keeps the arm's
    # skin with the arm even where it hangs close to the ribs.
    def slice_at(verts, faces, heights):
        """Cut the surface along horizontal planes so a region can end on a clean line."""
        me = bpy.data.meshes.new("tmp")
        me.from_pydata(verts.tolist(), [], faces.tolist())
        bm = bmesh.new()
        bm.from_mesh(me)
        for z in heights:
            bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-6,
                                   plane_co=(0, 0, z), plane_no=(0, 0, 1))
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        bm.verts.ensure_lookup_table()
        v = np.array([vert.co[:] for vert in bm.verts])
        f = np.array([[vert.index for vert in face.verts] for face in bm.faces], dtype=np.int32)
        bm.free()
        bpy.data.meshes.remove(me)
        return v, f


    # Shorts: the band of skin between mid-thigh and the waist, as its own material.
    hip_z = (J["hip_l"][2] + J["hip_r"][2]) / 2
    hem_z, waist_z = hip_z - 0.17, hip_z + 0.125
    if SEX == "female":
        # Under her shorts the hip muscles sit close to the skin: pull them 6 mm
        # towards the bone axis so they never show through the cloth.
        for p in parts:
            v = p["verts"]
            sel = (v[:, 2] > hem_z - 0.02) & (v[:, 2] < waist_z + 0.02)
            if not sel.any():
                continue
            q = v[sel]
            best, axis_pt = np.full(len(q), 1e9), np.zeros_like(q)
            for a, b in segment_lines():
                ab = b - a
                t = np.clip(((q - a) @ ab) / (ab @ ab), 0, 1)
                c = a + t[:, None] * ab
                d = np.linalg.norm(q - c, axis=1)
                closer = d < best
                best[closer], axis_pt[closer] = d[closer], c[closer]
            out = (q - axis_pt) / np.maximum(best, 1e-9)[:, None]
            v[sel] = q - out * np.minimum(0.006, 0.5 * best)[:, None]
    # Head: opaque, from just under the jaw up.
    neck_z = NECK_Z
    neck_cuts = [neck_z - NECK_FADE * i / NECK_BANDS for i in range(1, NECK_BANDS + 1)]
    # Female sports top: from under the bust to the upper chest.
    bust_lo = T11[2] + 0.45 * (T6[2] - T11[2])
    bust_hi = C7[2] - 0.11
    top_cuts = (bust_lo, bust_hi) if SEX == "female" else ()
    skin["verts"], skin["faces"] = slice_at(skin["verts"], skin["faces"],
                                            (hem_z, waist_z, neck_z, *neck_cuts, *top_cuts))
    # Give the shorts a plain front panel: pull the middle of the front onto one
    # smooth plane just ahead of the thighs, fading out to the sides and the waist.
    sv = skin["verts"]
    band = (sv[:, 2] > hem_z - 0.01) & (sv[:, 2] < waist_z)
    flank = band & (np.abs(sv[:, 0]) > 0.07) & (np.abs(sv[:, 0]) < 0.11)
    panel_y = np.percentile(sv[flank, 1], 2) - 0.018
    across = np.clip((0.115 - np.abs(sv[:, 0])) / 0.05, 0, 1)   # fully flat for |x| < 6.5 cm
    up = np.clip((waist_z - sv[:, 2]) / (waist_z - hip_z - 0.02), 0, 1)
    blend = np.where(band & (sv[:, 1] < 0), (across * across * (3 - 2 * across)) * up, 0.0)
    if SEX == "female":
        # Her shorts: only the crotch is smoothed (the male figure's shape
        # there), pulled back onto the level of the skin beside it.
        crotch = (sv[:, 2] > hip_z - 0.16) & (sv[:, 2] < hip_z + 0.04) & (sv[:, 1] < 0)
        side = crotch & (np.abs(sv[:, 0]) > 0.05) & (np.abs(sv[:, 0]) < 0.08)
        panel_y = np.median(sv[side, 1])
        across = np.clip((0.075 - np.abs(sv[:, 0])) / 0.035, 0, 1)
        vert = np.clip(np.minimum((sv[:, 2] - (hip_z - 0.16)) / 0.04, (hip_z + 0.04 - sv[:, 2]) / 0.04), 0, 1)
        blend = np.where(crotch & (sv[:, 1] < panel_y), across * across * (3 - 2 * across) * vert, 0.0)

    sv[:, 1] = sv[:, 1] + (panel_y - sv[:, 1]) * blend
    # Folds that were flattened onto the panel now face backwards: drop them.
    tri = sv[skin["faces"]]
    facing_back = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])[:, 1] >= 0
    flat = (blend[skin["faces"]] > 0.98).all(axis=1)
    if SEX != "female":      # her smoothing is gentle; dropping folds would leave holes
        skin["faces"] = skin["faces"][~(flat & facing_back)]

    under_pts = np.concatenate([p["verts"] for p in under_parts])
    under_w = np.concatenate([skin_weights(p) for p in under_parts])
    query_pts = skin["verts"]
    if SEX == "female":
        # Back to the male shape. Slicing keeps the original vertices first (in
        # order) and appends the cut points, which lie on original edges: those
        # take their nearest original vertex.
        n0 = len(female_skin)
        i = np.arange(len(skin["verts"]))
        if len(i) > n0:
            _, i[n0:] = cKDTree(female_skin).query(skin["verts"][n0:])
        query_pts = male_skin[i] + (skin["verts"] - female_skin[i])
        under_pts = np.concatenate([p["male_verts"] for p in under_parts])
    near_d, near_i = cKDTree(under_pts).query(query_pts, k=8)
    falloff = 1.0 / (near_d + 0.004) ** 2
    skin_w = (under_w[near_i] * falloff[:, :, None]).sum(axis=1)
    skin_w /= skin_w.sum(axis=1, keepdims=True)
    # Eyes: BodyParts3D's eyeballs, seen through an almond-shaped opening cut in
    # the skin in front of each.
    male_eyes = []
    if True:
        eb = weld(read_stl("FMA12513"))[0]
        eb[:, 2] -= ground
        if FEMALE:
            eb = warp(eb, "female")
        for side in (eb[eb[:, 0] > 0], eb[eb[:, 0] <= 0]):
            c = (side.min(axis=0) + side.max(axis=0)) / 2
            male_eyes.append((c, (side.max(axis=0) - side.min(axis=0)).mean() / 2))
        sv = skin["verts"]
        field = np.full(len(sv), -1.0)
        for c, r in male_eyes:
            dx, dz = (sv[:, 0] - c[0]) / (0.82 * r), (sv[:, 2] - c[2] - 0.08 * r) / (0.36 * r)
            f = 1 - dx * dx - dz * dz
            field = np.maximum(field, np.where((sv[:, 1] < c[1]) & (sv[:, 1] > c[1] - 2.5 * r), f, -1.0))
        V, A, fin, fout = real_head.split(sv, skin["faces"], field, skin_w)
        V, A, F = real_head.compact(V, A, fout)
        skin["verts"], skin["faces"], skin_w = V, F, A
        print("eye openings:", len(fin), "skin triangles removed")
    lower = [BONE_NAMES.index(b) for b in ("pelvis", "spine_01", "thigh_l", "thigh_r")]
    centre = skin["verts"][skin["faces"]].mean(axis=1)
    on_hips = skin_w[skin["faces"]][:, :, lower].sum(axis=2).mean(axis=1) > 0.5
    shorts = (centre[:, 2] > hem_z) & (centre[:, 2] < waist_z) & on_hips
    head = (centre[:, 2] > neck_z) & (np.abs(centre[:, 0]) < 0.14)
    skin_mat = np.full(len(skin["faces"]), material_names.index("skin"))
    skin_mat[shorts] = material_names.index("shorts")
    if SEX == "female":
        # Sports top: the torso from under the bust to the upper chest.
        torso_ix = [BONE_NAMES.index(b) for b in ("spine_01", "spine_02", "spine_03",
                                                  "clavicle_l", "clavicle_r")]
        on_torso = skin_w[skin["faces"]][:, :, torso_ix].sum(axis=2).mean(axis=1) > 0.6
        top = on_torso & (centre[:, 2] > bust_lo) & (centre[:, 2] < bust_hi)
        skin_mat[top] = material_names.index("shorts")
        # Her clothes sit a little off the skin, so no muscle shows through them.
        from mesh_util import vertex_normals as _vn
        sv = skin["verts"]
        cn = _vn(sv, skin["faces"])
        best, axis_pt = np.full(len(sv), 1e9), np.zeros_like(sv)
        for sa, sb in segment_lines():
            ab = sb - sa
            t = np.clip(((sv - sa) @ ab) / (ab @ ab), 0, 1)
            q = sa + t[:, None] * ab
            d = np.linalg.norm(sv - q, axis=1)
            closer = d < best
            best[closer], axis_pt[closer] = d[closer], q[closer]
        cn *= np.sign(((sv - axis_pt) * cn).sum(axis=1) + 1e-12)[:, None]
        cloth = np.unique(skin["faces"][skin_mat == material_names.index("shorts")])
        sv[cloth] += cn[cloth] * 0.007
    skin_mat[head] = material_names.index("head")
    # Neck bands: band 1 sits just under the head (most solid), band N lowest.
    near_neck = (np.abs(centre[:, 0]) < 0.14) & ~head & ~shorts
    for i in range(1, NECK_BANDS + 1):
        lo, hi = neck_z - NECK_FADE * i / NECK_BANDS, neck_z - NECK_FADE * (i - 1) / NECK_BANDS
        band = near_neck & (centre[:, 2] > lo) & (centre[:, 2] <= hi)
        skin_mat[band] = material_names.index(f"neck{i}")
    all_verts.append(skin["verts"])
    all_faces.append(skin["faces"] + offset)
    all_mats.append(skin_mat)
    all_w.append(skin_w)
    skin_range = (offset, offset + len(skin["verts"]))
    if os.environ.get("SURFACE_DUMP"):
        np.savez(os.environ["SURFACE_DUMP"], skin_v=skin["verts"], skin_f=skin["faces"], skin_mat=skin_mat,
                 mat_names=np.array(material_names), head=head,
                 mv=np.concatenate([p["verts"] for p in parts]),
                 mg=np.concatenate([np.full(len(p["verts"]), group_of(p)) for p in parts]))
    offset += len(skin["verts"])
    head_bone = BONE_NAMES.index("head")


    def add_rigid(mat, v, f):
        """A piece that moves with the head."""
        global offset
        all_verts.append(v)
        all_faces.append(f + offset)
        all_mats.append(np.full(len(f), material_names.index(mat)))
        w = np.zeros((len(v), len(BONE_NAMES)))
        w[:, head_bone] = 1
        all_w.append(w)
        offset += len(v)


    if True:
        for c, r in male_eyes:
            fwd = np.array([0.06 if c[0] > 0 else -0.06, -1.0, 0.0])
            for mat, (v, f) in real_head.eyeball(c, r * 0.97, fwd).items():
                add_rigid(mat, v, f)


    # --- hair -------------------------------------------------------------------
    def smooth_field(field, faces, n_verts, rounds):
        """Average a per-vertex field with its mesh neighbours a few times."""
        from scipy.sparse import coo_matrix, identity
        i = np.concatenate([faces[:, 0], faces[:, 1], faces[:, 2], faces[:, 1], faces[:, 2], faces[:, 0]])
        j = np.concatenate([faces[:, 1], faces[:, 2], faces[:, 0], faces[:, 0], faces[:, 1], faces[:, 2]])
        adj = coo_matrix((np.ones(len(i)), (i, j)), shape=(n_verts, n_verts)).tocsr()
        adj.data[:] = 1.0
        adj = adj + identity(n_verts, format="csr")
        deg = np.asarray(adj.sum(axis=1)).ravel()
        for _ in range(rounds):
            field = adj @ field / (deg[:, None] if field.ndim == 2 else deg)
        return field


    # Scalp: head skin above a hairline that runs from the forehead down to the
    # nape. Each style is a copy of it pushed out along the (smoothed) normals,
    # thinning to nothing at the hairline so the edge blends into the skin.
    if True:
        head_faces = skin["faces"][head]
        head_v = np.unique(head_faces)
        hv = skin["verts"]
        top_z = hv[head_v, 2].max()
        front_y, back_y = hv[head_v, 1].min(), hv[head_v, 1].max()
        along = np.clip((hv[:, 1] - front_y) / (back_y - front_y), 0, 1)   # 0 forehead .. 1 back
        front_hl = top_z - (0.072 if FEMALE else 0.085)   # hers is pulled back
        hairline = front_hl + ((C1[2] + 0.005) - front_hl) * along ** 1.15
        above = hv[:, 2] - hairline
        scalp_faces = head_faces[(above[head_faces] > 0).all(axis=1)]
        scalp_n = smooth_field(vertex_normals(hv, skin["faces"]), skin["faces"], len(hv), 6)
        scalp_n /= np.maximum(np.linalg.norm(scalp_n, axis=1, keepdims=True), 1e-12)
        taper = np.clip(above / 0.03, 0, 1)
        taper = taper * taper * (3 - 2 * taper)
        on_top = np.clip(above / 0.08, 0, 1)
        for style, (base, extra) in HAIR_STYLES.items():
            used = np.unique(scalp_faces)
            remap = -np.ones(len(hv), int)
            remap[used] = np.arange(len(used))
            lift = (base + extra * on_top[used]) * taper[used] + 0.0008
            all_verts.append(hv[used] + scalp_n[used] * lift[:, None])
            all_faces.append(remap[scalp_faces] + offset)
            all_mats.append(np.full(len(scalp_faces), material_names.index(style)))
            all_w.append(skin_w[used])
            offset += len(used)
        if FEMALE:
            # Ponytail: from inside the back of the head, out and down.
            back = hv[head_v][hv[head_v, 2] > top_z - 0.09]
            by = back[:, 1].max()
            z0 = top_z - 0.07
            pts = [[0, by - 0.03, z0 + 0.01], [0, by + 0.015, z0 - 0.005], [0, by + 0.04, z0 - 0.04],
                   [0, by + 0.05, z0 - 0.10], [0, by + 0.045, z0 - 0.17], [0, by + 0.035, z0 - 0.23]]
            from mesh_util import tube
            tv, tf = tube(pts, [0.022, 0.024, 0.022, 0.018, 0.013, 0.007], 14)
            add_rigid("hair_ponytail", tv, tf)


# ---------------------------------------------------------------- props ----
def box_mesh(centre, size):
    c, h = np.array(centre, float), np.array(size, float) / 2
    v = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]) * h + c
    f = np.array([[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5], [0, 4, 5], [0, 5, 1],
                  [2, 3, 7], [2, 7, 6], [0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]])
    return v, f


def rod_mesh(a, b, radius, sides=10):
    """Closed cylinder from a to b."""
    a, b = np.array(a, float), np.array(b, float)
    axis = (b - a) / np.linalg.norm(b - a)
    side = np.cross(axis, [0, 0, 1] if abs(axis[2]) < 0.9 else [1, 0, 0])
    side /= np.linalg.norm(side)
    other = np.cross(axis, side)
    ring = [math.cos(2 * math.pi * k / sides) * side + math.sin(2 * math.pi * k / sides) * other
            for k in range(sides)]
    v = np.array([a + r * radius for r in ring] + [b + r * radius for r in ring] + [a, b])
    f = []
    for k in range(sides):
        n = (k + 1) % sides
        f += [[k, n, sides + n], [k, sides + n, sides + k],
              [2 * sides, n, k], [2 * sides + 1, sides + k, sides + n]]
    return v, np.array(f)


# Each prop is modelled around the origin and moved by its own bone.
PROPS = [
    ("prop_bar", "equipment", rod_mesh((0, -0.5, 0), (0, 0.5, 0), BAR_RADIUS, 14)),
    # single handles (chest fly), one in each hand
    ("prop_handle_l", "equipment", rod_mesh((0, -0.07, 0), (0, 0.07, 0), BAR_RADIUS, 12)),
    ("prop_handle_r", "equipment", rod_mesh((0, -0.07, 0), (0, 0.07, 0), BAR_RADIUS, 12)),
    ("prop_cable_a", "cable", rod_mesh((0, 0, 0), (0, 1, 0), 0.004, 6)),
    ("prop_cable_b", "cable", rod_mesh((0, 0, 0), (0, 1, 0), 0.004, 6)),
    ("prop_cable_c", "cable", rod_mesh((0, 0, 0), (0, 1, 0), 0.004, 6)),
    ("prop_stack", "equipment", box_mesh((0, 0, STACK_HEIGHT / 2), (0.30, 0.11, STACK_HEIGHT))),
    # The Gympath tracker, clipped to the front of the top plate.
    ("prop_stack", "tracker", box_mesh((0, 0.07, STACK_HEIGHT - 0.05), (0.075, 0.03, 0.045))),
    ("prop_frame", "equipment", rod_mesh((0.17, 0, 0), (0.17, 0, 2.12), 0.012, 8)),
    ("prop_frame", "equipment", rod_mesh((-0.17, 0, 0), (-0.17, 0, 2.12), 0.012, 8)),
    ("prop_frame", "equipment", box_mesh((0, 0, 0.03), (0.46, 0.22, 0.06))),
    ("prop_frame", "equipment", box_mesh((0, 0, 2.14), (0.46, 0.10, 0.05))),
    ("prop_pulley_a", "equipment", rod_mesh((-0.02, 0, 0), (0.02, 0, 0), 0.055, 14)),
    ("prop_pulley_b", "equipment", rod_mesh((-0.02, 0, 0), (0.02, 0, 0), 0.055, 14)),
    # Pulldown seat: pad, post and the roller that holds the thighs down.
    ("prop_seat_a", "pad", box_mesh((0, 0, -0.035), (0.40, 0.36, 0.07))),
    ("prop_seat_a", "equipment", box_mesh((0, 0, -0.27), (0.07, 0.07, 0.40))),
    ("prop_seat_a", "pad", rod_mesh((-0.26, -0.30, 0.24), (0.26, -0.30, 0.24), 0.05, 12)),
    ("prop_seat_a", "equipment", box_mesh((0, -0.30, -0.05), (0.05, 0.05, 0.44))),
    # Row bench: long pad, two legs and the foot plate.
    ("prop_seat_b", "pad", box_mesh((0, -0.05, -0.035), (0.34, 0.95, 0.07))),
    ("prop_seat_b", "equipment", box_mesh((0, 0.25, -0.27), (0.07, 0.07, 0.40))),
    ("prop_seat_b", "equipment", box_mesh((0, -0.35, -0.27), (0.07, 0.07, 0.40))),
    ("prop_seat_b", "equipment", box_mesh((0, -0.945, -0.16), (0.50, 0.04, 0.34))),
]
prop_ranges = []
for bone, mat, (pv, pf) in PROPS:
    all_verts.append(pv)
    all_faces.append(pf + offset)
    all_mats.append(np.full(len(pf), material_names.index(mat)))
    all_w.append(np.zeros((len(pv), len(BONE_NAMES))))
    prop_ranges.append((bone, offset, offset + len(pv)))
    offset += len(pv)

V = np.concatenate(all_verts)
F = np.concatenate(all_faces)
MAT = np.concatenate(all_mats)
W = np.concatenate(all_w)

mesh = bpy.data.meshes.new("Anatomy")
mesh.vertices.add(len(V))
mesh.vertices.foreach_set("co", V.astype(np.float32).ravel())
mesh.loops.add(len(F) * 3)
mesh.loops.foreach_set("vertex_index", F.astype(np.int32).ravel())
mesh.polygons.add(len(F))
mesh.polygons.foreach_set("loop_start", np.arange(0, len(F) * 3, 3, dtype=np.int32))
mesh.polygons.foreach_set("loop_total", np.full(len(F), 3, dtype=np.int32))
mesh.polygons.foreach_set("material_index", MAT.astype(np.int32))
mesh.polygons.foreach_set("use_smooth", np.ones(len(F), dtype=bool))
mesh.update(calc_edges=True)
mesh.validate()
if QBODY:
    UVS = np.concatenate([u if u is not None else np.zeros((len(v), 2)) for u, v in
                          zip(all_uv + [None] * (len(all_verts) - len(all_uv)), all_verts)])
    uv_layer = mesh.uv_layers.new(name="UVMap")
    loop_uv = UVS[F.ravel()].copy()
    loop_uv[:, 1] = 1.0 - loop_uv[:, 1]          # glTF V runs down, Blender's up
    uv_layer.data.foreach_set("uv", loop_uv.astype(np.float32).ravel())

TEXTURES = {}
if QBODY:
    # Quaternius' skin texture without its colour (the app sets the tone),
    # its normal map, and the hair texture in grey (the app sets the colour).
    from PIL import Image, ImageOps
    tex_dir = os.path.join(os.path.dirname(os.path.abspath(OUT)) if False else
                           os.environ.get("TMPDIR", "/tmp"), "gympath_textures_" + SEX)
    os.makedirs(tex_dir, exist_ok=True)

    def grey(src, dst, size=1024, gain=1.0):
        im = ImageOps.grayscale(Image.open(src).convert("RGB")).resize((size, size), Image.LANCZOS)
        a = np.asarray(im).astype(float)
        ref = np.percentile(a, 90)
        a = np.clip(a / max(ref, 1) * 255 * gain, 0, 255).astype(np.uint8)
        Image.fromarray(a).convert("RGB").save(dst, quality=88)
        return dst

    def resized(src, dst, size=1024):
        Image.open(src).convert("RGB").resize((size, size), Image.LANCZOS).save(dst, quality=92)
        return dst
    TEXTURES["skin"] = grey(os.path.join(QCHAR.tex_dir, q_body.SKIN_TEXTURE[SEX]), os.path.join(tex_dir, "skin.jpg"))
    TEXTURES["skin_n"] = resized(os.path.join(QCHAR.tex_dir, q_body.NORMAL_TEXTURE[SEX]), os.path.join(tex_dir, "skin_n.jpg"))
    for k in (1, 2):
        TEXTURES[f"hair{k}"] = grey(os.path.join(QCHAR.tex_dir, f"T_Hair_{k}_BaseColor.png"),
                                    os.path.join(tex_dir, f"hair{k}.jpg"), 512, 0.95)
        TEXTURES[f"hair{k}_n"] = resized(os.path.join(QCHAR.tex_dir, f"T_Hair_{k}_Normal.png"),
                                         os.path.join(tex_dir, f"hair{k}_n.jpg"), 512)
    IMAGES = {k: bpy.data.images.load(v) for k, v in TEXTURES.items()}
    for k in IMAGES:
        if k.endswith("_n"):
            IMAGES[k].colorspace_settings.name = "Non-Color"


def textured(m, bsdf, base, normal):
    nt = m.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = IMAGES[base]
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    ntex = nt.nodes.new("ShaderNodeTexImage")
    ntex.image = IMAGES[normal]
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(ntex.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])


for name in material_names:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = {
        "skin": SKIN_COLOR, "shorts": SHORTS_COLOR, "equipment": (0.11, 0.12, 0.14, 1.0),
        "cable": (0.55, 0.57, 0.60, 1.0), "tracker": (0.0, 1.0, 0.53, 1.0),
        "pad": (0.035, 0.035, 0.04, 1.0)}.get(name, MUSCLE_COLOR)
    bsdf.inputs["Roughness"].default_value = {
        "shorts": 0.85, "pad": 0.8, "equipment": 0.4, "cable": 0.35}.get(name, 0.55)
    if name == "tracker":
        bsdf.inputs["Emission Color"].default_value = (0.0, 1.0, 0.53, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 1.5
    if name == "head":
        bsdf.inputs["Base Color"].default_value = SKIN_COLOR[:3] + (1.0,)
    face = {"sclera": (0.92, 0.92, 0.9), "iris": (0.15, 0.08, 0.03), "pupil": (0.01, 0.01, 0.01),
            "lashes": (0.01, 0.01, 0.01)}
    if name in face:
        bsdf.inputs["Base Color"].default_value = face[name] + (1.0,)
        bsdf.inputs["Roughness"].default_value = 0.25 if name in ("sclera", "iris", "pupil") else 0.6
    elif name in FACE_MATERIALS:      # hair
        bsdf.inputs["Base Color"].default_value = (0.02, 0.018, 0.016, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.9
    if name.startswith("neck"):
        bsdf.inputs["Base Color"].default_value = SKIN_COLOR
    if QBODY and (name in ("skin", "shorts") or name.replace("_cloth", "") in dict(GROUPS)):
        textured(m, bsdf, "skin", "skin_n")
        bsdf.inputs["Roughness"].default_value = 0.6
    elif QBODY and (name == "brows" or name.startswith("hair_")):
        atlas = "hair2" if QCHAR.hair[name][0]["material"] == "MI_Hair_2" else "hair1"
        textured(m, bsdf, atlas, atlas + "_n")
        bsdf.inputs["Roughness"].default_value = 0.8
    elif name == "skin" or name.startswith("neck"):
        bsdf.inputs["Alpha"].default_value = SKIN_COLOR[3]
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
        else:
            m.blend_method = "BLEND"
    bsdf.inputs["Metallic"].default_value = 0.7 if name in ("equipment", "cable") else 0.0
    mesh.materials.append(m)

body = bpy.data.objects.new("Anatomy", mesh)
if QBODY and BODY_MORPHS:
    body.shape_key_add(name="Basis", from_mix=False)
    for name in MORPH_NAMES:
        delta = np.zeros_like(V)
        for start, d in BODY_MORPHS:
            delta[start:start + len(d[name])] = d[name]
        sk = body.shape_key_add(name=name, from_mix=False)
        sk.data.foreach_set("co", (V + delta).astype(np.float32).ravel())
        sk.value = 0.0
scene.collection.objects.link(body)

arm_data = bpy.data.armatures.new("Rig")
arm = bpy.data.objects.new("Rig", arm_data)
scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
for name, (head, tail, parent) in BONES.items():
    eb = arm_data.edit_bones.new(name)
    eb.head, eb.tail = Vector(head), Vector(tail)
for name, (head, tail, parent) in BONES.items():
    if parent:
        arm_data.edit_bones[name].parent = arm_data.edit_bones[parent]
for name in PROP_BONES:
    eb = arm_data.edit_bones.new(name)
    eb.head, eb.tail = Vector((0, 0, 0)), Vector((0, 0.1, 0))
bpy.ops.object.mode_set(mode="OBJECT")

for k, name in enumerate(BONE_NAMES):
    vg = body.vertex_groups.new(name=name)
    col = W[:, k]
    for i in np.nonzero(col > 0.01)[0]:
        vg.add([int(i)], float(col[i]), "REPLACE")
for name in PROP_BONES:
    vg = body.vertex_groups.new(name=name)
    for bone, start, end in prop_ranges:
        if bone == name:
            vg.add(list(range(start, end)), 1.0, "REPLACE")

body.parent = arm
body.modifiers.new("Armature", "ARMATURE").object = arm

# ------------------------------------------------------------ animation ----
REST = {b.name: b.matrix_local.copy() for b in arm_data.bones}
ORDER = []


def visit(b):
    ORDER.append(b.name)
    for child in b.children:
        visit(child)


for b in arm_data.bones:
    if b.parent is None:
        visit(b)
PARENT = {b.name: (b.parent.name if b.parent else None) for b in arm_data.bones}


def smooth(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def contraction(t):
    if t < T_PULL:
        return 0.0
    if t < T_HOLD:
        return smooth((t - T_PULL) / (T_HOLD - T_PULL))
    if t < T_RETURN:
        return 1.0
    if t < T_REST:
        return 1 - smooth((t - T_RETURN) / (T_REST - T_RETURN))
    return 0.0


def slerp(a, b, t):
    a, b = Vector(a).normalized(), Vector(b).normalized()
    return a.slerp(b, t).normalized()


def lerp(a, b, t):
    return a + (b - a) * t


def place(start, end=None, scale=None):
    """Transform for a prop: moved to `start`; with `end`, its +Y axis is aimed
    at `end` and stretched to reach it."""
    start = Vector(start)
    if end is None:
        m = Matrix.Translation(start)
        if scale is not None:
            m = m @ Matrix.Diagonal((scale, scale, scale, 1))
        return m
    d = Vector(end) - start
    rot = Vector((0, 1, 0)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    return Matrix.Translation(start) @ rot @ Matrix.Diagonal((1, max(d.length, 1e-4), 1, 1))


HIDDEN = Matrix.Diagonal((1e-4, 1e-4, 1e-4, 1))
# Where the handle sits in each hand, rest pose: the hollow of the closed
# fingers (q_body.FINGER_CURL), the palm normal and the hand's axis.
if QBODY:
    GRIP0 = {}
    for s_ in "lr":
        g_ = QCHAR.grip_frame(s_, bind=True)
        GRIP0[s_] = dict(centre=Vector(g_["centre"]), n=Vector(g_["n"]), h=Vector(g_["h"]))
        print(f"grip {s_}: hollow radius {g_['radius'] * 100:.1f} cm")
else:
    GRIP0 = {s_: dict(centre=Vector(J[f"wrist_{s_}"]) + 0.075 * (Vector(J[f"handtip_{s_}"]) - Vector(J[f"wrist_{s_}"])).normalized(),
                      n=Vector((0, 0, -1)), h=(Vector(J[f"handtip_{s_}"]) - Vector(J[f"wrist_{s_}"])).normalized())
             for s_ in "lr"}


def grip_point(pose, s):
    """The handle's place in hand s, posed."""
    return (pose[f"hand_{s}"] @ REST[f"hand_{s}"].inverted()) @ GRIP0[s]["centre"]


def frame(h, n):
    """Rotation whose columns are h, n and h x n (orthonormalised)."""
    h = h.normalized()
    n = (n - h * n.dot(h)).normalized()
    return Matrix((h, n, h.cross(n))).transposed()


def two_bone(S, W, L1, L2, E_hint):
    """Elbow and (reachable) wrist for shoulder S, wrist target W, bone
    lengths L1, L2; the elbow bends towards E_hint."""
    d = W - S
    # Soft reach: near full extension a two-bone arm's elbow angle changes
    # ever faster for the same hand travel, then stops dead at the limit (a
    # snap). Past 92% of the arm's length the reach eases in exponentially
    # towards 98.5% instead, so the arm straightens smoothly and never quite
    # locks (a slight bend also lets the elbow stay clear of the trunk).
    full = L1 + L2
    soft, hard = 0.92 * full, 0.985 * full
    reach = d.length
    if reach > soft:
        reach = soft + (hard - soft) * (1 - math.exp(-(reach - soft) / (hard - soft)))
    dist = max(reach, abs(L1 - L2) + 1e-4)
    dn = d.normalized()
    a = (L1 * L1 - L2 * L2 + dist * dist) / (2 * dist)
    hgt = math.sqrt(max(L1 * L1 - a * a, 0.0))
    pole = E_hint - S
    pole = pole - dn * pole.dot(dn)
    if pole.length < 1e-6:
        pole = Vector((0, 1, 0)) - dn * dn.y
    pole.normalize()
    return S + dn * a + pole * hgt, S + dn * dist


BAR_WIDTH = {}       # exercise -> hand distance on a fixed bar (from its start pose)
PALM_K = {}          # (exercise, side) -> which way the palm turns, set at c = 0
IK_MISS = collections.defaultdict(float)


def hold_handle(ex_name, pose, adjust=None):
    """Put both hands on the handle: the handle across each palm in the
    closed fingers, and on a fixed bar the hands always the same distance
    apart (the arms reach it by two-bone IK; the elbows keep bending the way
    the exercise's arm directions bend them)."""
    g = GRIP.get(ex_name)
    if not g:
        return
    fk = {s: grip_point(pose, s) for s in "lr"}
    mid = (fk["l"] + fk["r"]) / 2
    across = (fk["l"] - fk["r"]).normalized()
    shift = adjust["shift"] if adjust else Vector()
    if g["width"] == "fixed":
        if ex_name not in BAR_WIDTH:
            BAR_WIDTH[ex_name] = (fk["l"] - fk["r"]).length
        half = BAR_WIDTH[ex_name] / 2
        target = {"l": mid + shift + across * half, "r": mid + shift - across * half}
    else:
        target = {s: fk[s] + shift for s in "lr"}
    for s in "lr":
        up, lo, hand = f"upperarm_{s}", f"lowerarm_{s}", f"hand_{s}"
        S = pose[up].to_translation()
        E0 = pose[lo].to_translation()
        W0 = pose[hand].to_translation()
        L1 = (REST[lo].to_translation() - REST[up].to_translation()).length
        L2 = (REST[hand].to_translation() - REST[lo].to_translation()).length
        rest_h, rest_n = GRIP0[s]["h"], GRIP0[s]["n"]
        off0 = GRIP0[s]["centre"] - REST[hand].to_translation()
        fore = (W0 - E0).normalized()
        n_fk = ((pose[hand] @ REST[hand].inverted()).to_3x3() @ rest_n).normalized()
        E, W = E0, W0
        for _ in range(4):
            # hand along the forearm, square to the handle; the palm the
            # way the grip says, without flipping between frames
            h = (fore - across * fore.dot(across)).normalized()
            n = h.cross(across).normalized()
            # The palm's side, the same for every call at the same c (no
            # memory of earlier calls, so the rep loops without a turn):
            # relative to where the arm motion alone would turn the palm,
            # fixed once at the rep's start to the grip's way (overhand...).
            key = (ex_name, s)
            if key not in PALM_K:
                PALM_K[key] = 1 if n.dot(Vector(g["palm"])) * n.dot(n_fk) >= 0 else -1
            if n.dot(n_fk) * PALM_K[key] < 0:
                n = -n
            R = frame(h, n) @ frame(rest_h, rest_n).transposed()
            W_goal = target[s] - R @ off0
            E, W = two_bone(S, W_goal, L1, L2, E0)
            # the elbow swung out from the body round the shoulder-wrist
            # line (bigger bodies hold their arms further out)
            flare = adjust["elbow"][s].x if adjust else 0.0
            if abs(flare) > 1e-6:
                axis = (W - S).normalized()
                side = 1 if s == "l" else -1
                cands = [S + Quaternion(axis, a) @ (E - S) for a in (flare, -flare)]
                E = max(cands, key=lambda e: side * e.x)
            fore = (W - E).normalized()
        IK_MISS[ex_name] = max(IK_MISS[ex_name], (W - W_goal).length)
        # upper arm and forearm swung onto the solved elbow and wrist
        clav = f"clavicle_{s}"
        base_u = pose[clav] @ REST[clav].inverted() @ REST[up]
        cur = (base_u.to_3x3() @ Vector((0, 1, 0))).normalized()
        rot_u = cur.rotation_difference((E - S).normalized()).to_matrix() @ base_u.to_3x3()
        pose[up] = Matrix.Translation(S) @ rot_u.to_4x4()
        base_l = pose[up] @ REST[up].inverted() @ REST[lo]
        cur = (base_l.to_3x3() @ Vector((0, 1, 0))).normalized()
        rot_l = cur.rotation_difference(fore).to_matrix() @ base_l.to_3x3()
        rot_h = R @ REST[hand].to_3x3()
        # the forearm takes half the hand's turn about its axis (the wrist
        # alone would wring the skin)
        carried = rot_l @ REST[lo].to_3x3().inverted() @ REST[hand].to_3x3()
        q = (rot_h @ carried.inverted()).to_quaternion()
        v = Vector((q.x, q.y, q.z))
        tw = Quaternion((q.w, *(fore * v.dot(fore))))
        if tw.magnitude > 1e-9:
            tw.normalize()
            rot_l = Quaternion().slerp(tw, 0.5).to_matrix() @ rot_l
        pose[lo] = Matrix.Translation(base_l.to_translation()) @ rot_l.to_4x4()
        pose[hand] = Matrix.Translation(W) @ rot_h.to_4x4()
P0 = REST["pelvis"].to_translation()
HIP_REST = Vector(J["hip_l"])
SHANK = (Vector(J["ankle_l"]) - Vector(J["knee_l"])).length


# ------------------------------------------------------------ collisions ----
# The posed figure and machine are checked for parts passing into each
# other: an arm or hand into the trunk, head or thighs, the bar or a cable
# into the body. Every vertex belongs to one body segment (its strongest
# bone); a point is inside a segment when it lies behind that segment's
# nearest skin.
from mathutils.bvhtree import BVHTree  # noqa: E402

PROP_OF = np.full(len(V), -1)
for _bone, _a, _b in prop_ranges:
    PROP_OF[_a:_b] = PROP_BONES.index(_bone)
_NOT_BODY = set(FACE_MATERIALS) | {"brows", "equipment", "cable", "tracker", "pad"} | \
    {m for m in material_names if m.startswith("hair_")}
_body_face = np.array([material_names[m] not in _NOT_BODY for m in MAT]) & (PROP_OF[F[:, 0]] < 0)


def _segment(b):
    if b.startswith(("upperarm", "shoulder_h")):
        return "uarm_" + b[-1]
    if b.startswith(("lowerarm", "elbow_h")):
        return "farm_" + b[-1]
    if b.startswith("hand"):
        return "hand_" + b[-1]
    if b.startswith(("thigh", "hip_h")):
        return "thigh_" + b[-1]
    if b.startswith(("calf", "knee_h", "foot")):
        return "shin_" + b[-1]
    if b in ("head", "neck"):
        return "head"
    return "torso"


SEGS = sorted({_segment(b) for b in BONE_NAMES})
_body_v = np.zeros(len(V), bool)
_body_v[np.unique(F[_body_face])] = True
SEG_OF = np.full(len(V), -1)
SEG_OF[_body_v] = [SEGS.index(_segment(BONE_NAMES[k])) for k in W[_body_v].argmax(axis=1)]
# a face belongs to the segment most of its corners belong to
_fs = SEG_OF[F]
FACE_SEG = np.where(_fs[:, 1] == _fs[:, 2], _fs[:, 1], _fs[:, 0])
FACE_SEG[~_body_face] = -1
_bone_cols = [(k, np.nonzero(W[:, k] > 1e-4)[0]) for k in range(len(BONE_NAMES))]


def _along(bone, ix):
    """How far along its bone (0 head .. 1 tail) each vertex lies, at rest."""
    h, t = np.array(REST[bone].to_translation()), np.array(BONES[bone][1])
    return ((V[ix] - h) @ (t - h)) / ((t - h) @ (t - h))


# the far end of the upper arm (elbow) and of the forearm (wrist): the parts
# that can pass into the trunk / the upper arm; near the joint they touch
PART_IX = {}
for _s in "lr":
    for _seg, _bone, _from in (("uarm", f"upperarm_{_s}", 0.45), ("farm", f"lowerarm_{_s}", 0.35)):
        _ix = np.nonzero(SEG_OF == SEGS.index(f"{_seg}_{_s}"))[0]
        PART_IX[f"{_seg}far_{_s}"] = _ix[_along(_bone, _ix) > _from]
for _seg in SEGS:
    PART_IX[_seg] = np.nonzero(SEG_OF == SEGS.index(_seg))[0]
# seat pads and plates (prop, centre, size) / rollers (prop, a, b, radius)
PAD_BOXES = [("prop_seat_a", (0, 0, -0.035), (0.40, 0.36, 0.07)), ("prop_seat_b", (0, -0.05, -0.035), (0.34, 0.95, 0.07)),
             ("prop_seat_b", (0, -0.945, -0.16), (0.50, 0.04, 0.34))]
PAD_RODS = [("prop_seat_a", (-0.26, -0.30, 0.24), (0.26, -0.30, 0.24), 0.05)]
SEAT_SQUASH = 0.015          # a seat gives a little under the body
_Vh = np.c_[V, np.ones(len(V))]

# Body shapes the animation is fitted to: the avatar's body sliders (glTF
# morph targets) all at 0, half and full. Each exercise gets one clip per
# level ("Name", "Name@1", "Name@2"); the app plays the one for the
# smallest level that holds its avatar, so nothing passes into anything
# whatever the sliders (a slimmer body only stands a little clearer).
SHAPE_LEVELS = [0.0, 0.5, 1.0]
MORPH_D = {}
if QBODY and BODY_MORPHS:
    for _name in MORPH_NAMES:
        MORPH_D[_name] = np.zeros_like(V)
        for _start, _d in BODY_MORPHS:
            MORPH_D[_name][_start:_start + len(_d[_name])] = _d[_name]
CUR_LEVEL = 0


def set_shape(level):
    """Check collisions on the body with every slider at SHAPE_LEVELS[level]."""
    global _Vh, CUR_LEVEL
    CUR_LEVEL = level
    v = V + sum((SHAPE_LEVELS[level] * d for d in MORPH_D.values()), np.zeros_like(V))
    _Vh = np.c_[v, np.ones(len(V))]


def posed_verts(pose):
    """Every vertex of the figure and machine in this pose (linear blend)."""
    out = np.zeros((len(V), 3))
    for k, ix in _bone_cols:
        m = np.array(pose[BONE_NAMES[k]] @ REST[BONE_NAMES[k]].inverted())
        out[ix] += W[ix, k, None] * (_Vh[ix] @ m.T)[:, :3]
    for name in PROP_BONES:
        ix = np.nonzero(PROP_OF == PROP_BONES.index(name))[0]
        if len(ix) and name in pose:
            m = np.array(pose[name] @ REST[name].inverted())
            out[ix] = (_Vh[ix] @ m.T)[:, :3]
    return out


def _bvh(P, seg):
    faces = F[FACE_SEG == SEGS.index(seg)]
    return BVHTree.FromPolygons([Vector(p) for p in P], faces.tolist(), epsilon=0.0), P[faces]


def winding(p, tris):
    """Generalised winding number of point p for triangles (M, 3, 3):
    about 1 inside a closed outward-facing surface, 0 outside; a segment of
    the skin is open where it meets the next one, which only takes a little
    off."""
    a, b, c = tris[:, 0] - p, tris[:, 1] - p, tris[:, 2] - p
    la, lb, lc = (np.linalg.norm(x, axis=1) for x in (a, b, c))
    det = np.einsum("ij,ij->i", a, np.cross(b, c))
    div = la * lb * lc + np.einsum("ij,ij->i", a, b) * lc + \
        np.einsum("ij,ij->i", b, c) * la + np.einsum("ij,ij->i", c, a) * lb
    return float(np.arctan2(det, div).sum() / (2 * math.pi))


def _line_points(pose, name, n=24):
    """Points along a rod prop's axis (bar, cable), posed."""
    m = pose[name] @ REST[name].inverted()
    return [m @ Vector((0, y, 0)) for y in np.linspace(-0.5 if name == "prop_bar" else 0.0, 0.5 if name == "prop_bar" else 1.0, n)]


# who may not pass into whom: (moving part, segment), how deep is allowed
# (m; skin meets skin a little where limbs rest on each other)
CONTACT = 0.006
PAIRS = [(f"{a}_{s}", b) for s in "lr" for a in ("hand", "farm") for b in ("torso", "head", "thigh_l", "thigh_r")] + \
        [(f"uarm_{s}", "head") for s in "lr"] + [("farm_l", "farm_r"), ("hand_l", "hand_r")] + \
        [(f"uarmfar_{s}", "torso") for s in "lr"] + [(f"farmfar_{s}", f"uarm_{s}") for s in "lr"] + \
        [(f"hand_{s}", f"uarm_{s}") for s in "lr"]


def penetrations(pose, P=None, seat=False):
    """Deepest passing of each pair in this pose: {(part, segment): (depth m,
    outward direction at the deepest point)}."""
    if P is None:
        P = posed_verts(pose)
    trees = {}
    out = {}

    def tree(seg):
        if seg not in trees:
            trees[seg] = _bvh(P, seg)
        return trees[seg]

    def deepest(points, seg, radius=0.0):
        """Deepest point really inside the segment: behind its nearest skin
        and (checked from the deepest down) with a winding number over 1/2."""
        t, tris = tree(seg)
        cands = []
        for p in points:
            hit = t.find_nearest(Vector(p), 0.25)
            if hit[0] is None:
                continue
            sd = (Vector(p) - hit[0]).dot(hit[1])
            if radius - sd > CONTACT and (sd < 0 or hit[3] < radius):
                cands.append((radius - sd, np.asarray(p, float), hit[1].copy()))
        cands.sort(key=lambda x: -x[0])
        for d, p, nrm in cands[:10]:
            if winding(p, tris) > 0.5:
                return d, nrm
        return 0.0, None

    for part, seg in PAIRS:
        d, nrm = deepest(P[PART_IX[part][::2]], seg)
        if d > CONTACT:
            out[(part, seg)] = (d, nrm)
    # the body on the seat pads: no deeper than a pad gives
    body = P[_body_v]
    for bi, (prop, centre, size) in enumerate(PAD_BOXES):
        m = pose[prop] @ REST[prop].inverted()
        if m.to_3x3().determinant() < 1e-6:
            continue
        loc = (np.c_[body, np.ones(len(body))] @ np.array(m.inverted()).T)[:, :3] - np.array(centre)
        inside = (np.abs(loc) < np.array(size) / 2).all(axis=1)
        if inside.any():
            d = (np.array(size) / 2 - np.abs(loc[inside])).min(axis=1).max()
            if d > SEAT_SQUASH:
                out[(f"{prop}#{bi}", "body")] = (d - SEAT_SQUASH, None)
    for prop, a, b, r in PAD_RODS:
        m = pose[prop] @ REST[prop].inverted()
        if m.to_3x3().determinant() < 1e-6:
            continue
        loc = (np.c_[body, np.ones(len(body))] @ np.array(m.inverted()).T)[:, :3]
        a, b = np.array(a), np.array(b)
        t = np.clip((loc - a) @ (b - a) / ((b - a) @ (b - a)), 0, 1)
        dist = np.linalg.norm(loc - (a + t[:, None] * (b - a)), axis=1)
        d = r - dist.min()
        if d > SEAT_SQUASH:
            out[(prop + "_roller", "body")] = (d - SEAT_SQUASH, None)
    for prop, radius in (("prop_bar", BAR_RADIUS), ("prop_cable_a", 0.004), ("prop_cable_b", 0.004),
                         ("prop_cable_c", 0.004)):
        if pose[prop].to_3x3().determinant() < 1e-9:
            continue                           # hidden in this exercise
        pts = _line_points(pose, prop)
        for seg in ("torso", "head", "thigh_l", "thigh_r", "shin_l", "shin_r", "uarm_l", "uarm_r",
                    "farm_l", "farm_r"):
            d, nrm = deepest(pts, seg, radius)
            if d > CONTACT:
                out[(prop, seg)] = (d, nrm)
    return out


def solve_props(ex_name, pose, c, hip_z):
    """Where the machine parts are for this pose."""
    cfg = MACHINE[ex_name]
    grips = {s: grip_point(pose, s) for s in "lr"}
    mid = (grips["l"] + grips["r"]) / 2
    p1, p2 = Vector(cfg["p1"]), Vector(cfg["p2"])
    foot = Vector((cfg["stack"][0], cfg["stack"][1], 0))
    top = foot + Vector((0, 0, STACK_BASE + STACK_HEIGHT + STACK_TRAVEL * c))
    out = {name: HIDDEN.copy() for name in PROP_BONES}
    out["prop_stack"] = place(foot + Vector((0, 0, STACK_BASE + STACK_TRAVEL * c)))
    out["prop_frame"] = place(foot)
    out["prop_pulley_a"], out["prop_pulley_b"] = place(p1), place(p2)
    if cfg["bar"] == 0:                       # one cable per hand (chest fly)
        out["prop_cable_a"] = place(grips["l"], p1)
        out["prop_cable_c"] = place(grips["r"], p2)
        for s in "lr":                        # a handle across each palm
            rot = (pose[f"hand_{s}"] @ REST[f"hand_{s}"].inverted()).to_3x3()
            across_palm = rot @ GRIP0[s]["n"].cross(GRIP0[s]["h"])
            turn = Vector((0, 1, 0)).rotation_difference(across_palm.normalized()).to_matrix().to_4x4()
            out[f"prop_handle_{s}"] = Matrix.Translation(grips[s]) @ turn
        out["prop_cable_b"] = place(p1 + Vector((0, 0, 0.05)), top)
    else:
        across = grips["l"] - grips["r"]
        # a bar a little wider than the hands' grip, at least its own length
        length = max(cfg["bar"], across.length + 0.22) if cfg["bar"] else across.length + 0.06
        rot = Vector((0, 1, 0)).rotation_difference(across.normalized()).to_matrix().to_4x4()
        out["prop_bar"] = Matrix.Translation(mid) @ rot @ Matrix.Diagonal((1, length, 1, 1))
        out["prop_cable_a"] = place(mid, p1)
        out["prop_cable_c"] = place(p1, p2)
        out["prop_cable_b"] = place(p2, top)
    if ex_name == "LatPulldown":
        out["prop_seat_a"] = place((0, pose["pelvis"].to_translation().y + 0.02, hip_z - 0.10))
    if ex_name == "SeatedCableRow":
        fit = ROW_SEAT.get("fit")
        if fit:                               # fitted to the figure (fit_row_seat)
            out["prop_seat_b"] = place(fit)
        else:
            out["prop_seat_b"] = place((0, pose["pelvis"].to_translation().y + 0.02, hip_z - 0.108))
    return out


def solve_pose(ex_name, c, adjust=None):
    ex = EXERCISES[ex_name]
    seat = SEATED.get(ex_name)
    hip_z = HIP_REST.z
    if seat:
        hip_z = seat["hip"] if seat["hip"] else Vector(J["ankle_l"]).z + SHANK
    pelvis_pos = P0 + Vector((0, 0, hip_z - HIP_REST.z))
    pose = {}
    lean = math.radians(lerp(ex["lean"][0], ex["lean"][1], c))
    retract = math.radians(lerp(ex["retract"][0], ex["retract"][1], c))
    aims = {}
    for s, sx in (("l", 1.0), ("r", -1.0)):
        for bone, key in ((f"upperarm_{s}", "upper"), (f"lowerarm_{s}", "fore")):
            d = slerp(ex[key][0], ex[key][1], c)
            if SEX == "female" or QBODY:
                # A hanging arm swings out a little more so it clears the
                # lats and hips of the broader builds.
                d = Vector((d.x + ARM_SPREAD[0 if key == "upper" else 1] * max(0.0, -d.z), d.y, d.z)).normalized()
            aims[bone] = Vector((d.x * sx, d.y, d.z))
        aims[f"hand_{s}"] = aims[f"lowerarm_{s}"]
        if seat:
            for bone, key in ((f"thigh_{s}", "thigh"), (f"calf_{s}", "calf")):
                d = Vector(seat[key]).normalized()
                aims[bone] = Vector((d.x * sx, d.y, d.z))
    for name in ORDER:
        if name in PROP_BONES:
            continue
        parent = PARENT[name]
        base = REST[name].copy() if parent is None else \
            pose[parent] @ REST[parent].inverted() @ REST[name]
        m = base
        here = Matrix.Translation(base.to_translation())
        if name == "pelvis":
            m = Matrix.Translation(pelvis_pos) @ base.to_3x3().to_4x4()
        elif name.startswith("foot") and seat and seat["hip"] is None:
            m = here @ REST[name].to_3x3().to_4x4()      # feet flat on the floor
        elif name in ("spine_01", "spine_02", "spine_03"):
            # Lean from the lower back; + = forward (towards -Y).
            m = here @ Matrix.Rotation(lean / 3, 4, "X") @ base.to_3x3().to_4x4()
        elif name.startswith("clavicle"):
            # Shoulder blades squeeze back around the vertical axis.
            sx = 1.0 if name.endswith("l") else -1.0
            m = here @ Matrix.Rotation(-sx * retract, 4, "Z") @ base.to_3x3().to_4x4()
        elif name in aims:
            current = (base.to_3x3() @ Vector((0, 1, 0))).normalized()
            swing = current.rotation_difference(aims[name]).to_matrix()
            m = here @ (swing @ base.to_3x3()).to_4x4()
        pose[name] = m
    if adjust is None:
        adjust = adjust_at(ex_name, c)
    hold_handle(ex_name, pose, adjust)
    # Helper bones turn half as far as the bone below their joint.
    for h, (above, below, _, _) in HELPERS.items():
        base_b = pose[above] @ REST[above].inverted() @ REST[below]
        turn = (pose[below].to_3x3() @ base_b.to_3x3().inverted()).to_quaternion()
        half = Quaternion().slerp(turn, 0.5).to_matrix()
        base_h = pose[above] @ REST[above].inverted() @ REST[h]
        pose[h] = Matrix.Translation(base_h.to_translation()) @ (half @ base_h.to_3x3()).to_4x4()
    for name, transform in solve_props(ex_name, pose, c, hip_z).items():
        pose[name] = transform @ REST[name]
    return pose


def key_pose(pose, frame, last):
    for name in ORDER:
        parent = PARENT[name]
        base = REST[name] if parent is None else pose[parent] @ REST[parent].inverted() @ REST[name]
        loc, q, scale = (base.inverted() @ pose[name]).decompose()
        if name in last and last[name].dot(q) < 0:
            q.negate()
        last[name] = q.copy()
        pb = arm.pose.bones[name]
        pb.rotation_quaternion = q
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if name == "pelvis" or name in PROP_BONES:
            pb.location = loc
            pb.keyframe_insert("location", frame=frame)
        if name in PROP_BONES:
            pb.scale = scale
            pb.keyframe_insert("scale", frame=frame)


# ----------------------------------------------------- collision fixes ----
# Where a pose has parts passing into each other, the bar (the hands) moves
# out of the body and the elbows out from the trunk, by as much as they
# went in. Solved at points through the rep, then smoothed, so the
# correction itself moves smoothly.
ADJUST = {}                  # exercise -> [(c, adjust)]
# exactly the contractions the animation is keyed at (every 2nd frame)
_nf = int(round(REP_SECONDS * FPS))
ADJ_GRID = np.array(sorted({round(contraction(f / _nf), 6) for f in range(0, _nf + 1, 2)}))
MARGIN = 0.008
MAX_SHIFT = 0.22             # m the bar may move from its path
MAX_FLARE = 0.9              # rad the elbows may swing out


def _zero_adjust():
    return dict(shift=Vector(), elbow={"l": Vector(), "r": Vector()})


def adjust_at(ex_name, c):
    table = ADJUST.get((ex_name, CUR_LEVEL))
    if not table:
        return None
    cs = [t for t, _ in table]
    k = int(np.clip(np.searchsorted(cs, c) - 1, 0, len(cs) - 2))
    f = (c - cs[k]) / (cs[k + 1] - cs[k])
    a, b = table[k][1], table[k + 1][1]
    return dict(shift=a["shift"].lerp(b["shift"], f),
                elbow={s: a["elbow"][s].lerp(b["elbow"][s], f) for s in "lr"})


def _fix(ex_name, c, adj, tries=16, elbows=True):
    """Move the bar / elbows (adj, in place) until nothing passes into
    anything at contraction c; returns what is left (m)."""
    pen = {}
    for _ in range(tries):
        pose = solve_pose(ex_name, float(c), adj)
        pen = penetrations(pose)
        push, elbow = Vector(), {"l": Vector(), "r": Vector()}
        for (a, b), (d, nrm) in pen.items():
            if nrm is None:
                continue
            step = d + MARGIN
            # the bar moves out the way the skin faces, in the body's middle
            # plane (left and right pushes cancel): forward when the skin
            # faces sideways
            out = Vector((0, nrm.y, nrm.z))
            out = out.normalized() if out.length > 0.3 else Vector((0, -1, 0))
            if a.startswith("uarmfar"):            # elbow into the trunk:
                elbow[a[-1]] += Vector((step * 6.0, 0, 0))   # swing it out (rad)
                push += out * step * 0.2           # and the hands a little forward
            elif a.startswith("farmfar"):          # elbow bent into itself:
                mid = (pose["upperarm_l"].to_translation() + pose["upperarm_r"].to_translation()) / 2
                bar = (grip_point(pose, "l") + grip_point(pose, "r")) / 2
                push += (bar - mid).normalized() * step * 0.5   # reach further
            else:                                  # hands, forearms, bar, cable
                push += out * step * 0.5
        if push.length < 1e-4 and all(v.length < 1e-4 for v in elbow.values()):
            break
        push.x = 0.0                               # the bar stays centred
        adj["shift"] += push
        if adj["shift"].length > MAX_SHIFT:        # never a different exercise
            adj["shift"] *= MAX_SHIFT / adj["shift"].length
        for s in "lr":
            if elbows:
                adj["elbow"][s].x = min(adj["elbow"][s].x + elbow[s].x, MAX_FLARE)
    _fix.last = pen
    return max((d for d, _ in pen.values()), default=0.0)


def solve_adjust(ex_name):
    if not GRIP.get(ex_name):
        return None
    solve_pose(ex_name, 0.0, _zero_adjust())    # palm way and bar width: from the start
    raw = []
    for c in ADJ_GRID:
        adj = _zero_adjust()
        _fix(ex_name, c, adj)
        raw.append(adj)
    n = len(raw)

    def smooth(vals, reach, sigma):
        """Per axis: the strongest value within `reach` grid points, then a
        Gaussian blur; so a correction ramps in and out gently and is still
        whole where it is needed."""
        arr = np.array([[v.x, v.y, v.z] for v in vals])
        wide = np.zeros_like(arr)
        for i in range(n):
            win = arr[max(0, i - reach):i + reach + 1]
            wide[i] = win[np.abs(win).argmax(axis=0), [0, 1, 2]]
        k = np.exp(-0.5 * (np.arange(-3 * sigma, 3 * sigma + 1) / sigma) ** 2) if sigma else np.ones(1)
        out = np.zeros_like(wide)
        for i in range(n):
            idx = np.clip(np.arange(i - len(k) // 2, i + len(k) // 2 + 1), 0, n - 1)
            out[i] = (wide[idx] * k[:, None]).sum(axis=0) / k.sum()
        return [Vector(v) for v in out]
    # Smooth by construction: each value becomes the strongest within
    # REACH grid points, then a Gaussian of at most that reach, so every
    # point keeps at least the correction it needed and nothing jumps.
    # the elbows hold one place through the rep, as far out as the rep
    # ever needs them (a moving elbow in a pushdown or curl looks wrong)
    elbows = {s: [Vector((max(a["elbow"][s].x for a in raw), 0, 0))] * n for s in "lr"}
    if any(e[0].x > 0 for e in elbows.values()):
        # with the elbows held out all the rep, the bar's moves again
        for i, c in enumerate(ADJ_GRID):
            raw[i] = dict(shift=Vector(), elbow={s: elbows[s][i].copy() for s in "lr"})
            _fix(ex_name, c, raw[i], elbows=False)
    shift = smooth([a["shift"] for a in raw], 18, 6)
    table = [(float(c), dict(shift=shift[i], elbow={s: elbows[s][i] for s in "lr"}))
             for i, c in enumerate(ADJ_GRID)]
    for c, adj in table:
        pen = penetrations(solve_pose(ex_name, c, adj))
        left = max((d for d, _ in pen.values()), default=0.0)
        if left > 0.005:
            print(f"  {ex_name}@{CUR_LEVEL} c={c:.2f}: {left * 100:.1f} cm left after fixing",
                  {f"{a}->{b}": round(d * 100, 1) for (a, b), (d, _) in pen.items()})
    print(f"  {ex_name} @{CUR_LEVEL} corrections: bar (cm)", [round(a["shift"].length * 100, 1) for _, a in table],
          "elbows out (deg)", [round(math.degrees(a["elbow"]["l"].x)) for _, a in table])
    return table


ROW_SEAT = {}


def fit_row_seat():
    """The row bench under this figure: its pad just under the seat bones and
    the foot plate just against the soles (each pressed in by a few mm)."""
    pose = solve_pose("SeatedCableRow", 0.0)
    P = posed_verts(pose)
    body = P[_body_v]
    feet = np.isin(SEG_OF, [SEGS.index("shin_l"), SEGS.index("shin_r")])
    sole = P[feet & _body_v][:, 1].min() + 0.006
    # the foot plate's back face is 0.925 m in front of the bench's origin,
    # the pad runs from 0.525 m in front of it to 0.425 m behind
    y0 = sole + 0.925
    under = (np.abs(body[:, 0]) < 0.17) & (body[:, 1] > y0 - 0.525) & (body[:, 1] < y0 + 0.425)
    top = body[under, 2].min() + 0.006
    ROW_SEAT["fit"] = (0.0, y0, top)
    print(f"row bench (shape {SHAPE_LEVELS[CUR_LEVEL]}): pad top {top:.3f} m, foot plate at {sole:.3f} m")


frames = int(round(REP_SECONDS * FPS))
scene.frame_start, scene.frame_end = 0, frames
arm.animation_data_create()
actions = {}
LEVELS = range(len(SHAPE_LEVELS)) if MORPH_D and os.environ.get("COLLISIONS", "1") == "1" else [0]
if os.environ.get("SHAPE_LEVELS_ONLY"):
    LEVELS = [int(x) for x in os.environ["SHAPE_LEVELS_ONLY"].split(",")]
JERKS = {}                   # clip -> [(deg, bone, frame)] sudden turns between keys


def jerk_check(clip, poses):
    """Bones that turn much more between two keys than the keys around
    them (a snap, not a fast but smooth move): the turn against the
    average of its neighbours' turns."""
    names = [n for n in poses[0] if not n.startswith("prop_")]
    out = []
    for n in names:
        turn = []
        for a, b in zip(poses, poses[1:]):
            q = (b[n].to_3x3() @ a[n].to_3x3().inverted()).to_quaternion()
            turn.append(math.degrees(2 * math.acos(min(1.0, abs(q.w)))))
        for i in range(len(turn)):
            near = [turn[j] for j in (i - 2, i - 1, i + 1, i + 2) if 0 <= j < len(turn)]
            spike = turn[i] - sum(near) / len(near)
            if spike > 4.0:
                out.append((round(spike, 1), n, 2 * (i + 1)))
    for s in "lr":                            # the hands' path: no jumps
        g = [grip_point(p, s) for p in poses]
        step = [(b - a).length * 100 for a, b in zip(g, g[1:])]
        for i in range(len(step)):
            near = [step[j] for j in (i - 2, i - 1, i + 1, i + 2) if 0 <= j < len(step)]
            if step[i] - sum(near) / len(near) > 1.5:
                out.append((round(step[i] - sum(near) / len(near), 1), f"grip_{s} (cm)", 2 * (i + 1)))
    trace = os.environ.get("JERK_TRACE", "")
    if trace and trace.split(":")[0] == clip:
        n = trace.split(":")[1]
        turn = []
        for a, b in zip(poses, poses[1:]):
            q = (b[n].to_3x3() @ a[n].to_3x3().inverted()).to_quaternion()
            turn.append(round(math.degrees(2 * math.acos(min(1.0, abs(q.w)))), 1))
        print(f"trace {clip} {n}:", turn)
        print(f"trace {clip} c:", [round(contraction(2 * i / int(round(REP_SECONDS * FPS))), 3) for i in range(len(poses))])
        if ADJUST.get((clip.split("@")[0], CUR_LEVEL)):
            print("trace flare:", [round(math.degrees(adjust_at(clip.split("@")[0], contraction(2 * i / int(round(REP_SECONDS * FPS))))["elbow"]["l"].x), 1) for i in range(len(poses))])
    out.sort(reverse=True)
    JERKS[clip] = out
    print(f"jerks {clip}:", out[:6] if out else "none")
for level in LEVELS:
    set_shape(level)
    if QBODY:
        fit_row_seat()
    for ex_name, ex in EXERCISES.items():
        only = os.environ.get("COLLISIONS_ONLY")
        if os.environ.get("COLLISIONS", "1") == "1" and (not only or ex_name in only.split(",")):
            ADJUST[(ex_name, level)] = solve_adjust(ex_name)
        clip = ex_name if level == 0 else f"{ex_name}@{level}"
        action = bpy.data.actions.new(clip)
        arm.animation_data.action = action
        last = {}
        poses = []
        for f in range(0, frames + 1, 2):
            pose = solve_pose(ex_name, contraction(f / frames))
            poses.append({k: v.copy() for k, v in pose.items()})
            key_pose(pose, f, last)
        jerk_check(clip, poses)
        actions[clip] = action
set_shape(0)
if QBODY:
    fit_row_seat()
slot = arm.animation_data.action_slot if hasattr(arm.animation_data, "action_slot") else None
arm.animation_data.action = None
for ex_name, action in actions.items():
    track = arm.animation_data.nla_tracks.new()
    track.name = ex_name
    strip = track.strips.new(ex_name, 0, action)
    strip.name = ex_name
    if slot is not None and hasattr(strip, "action_slot") and action.slots:
        strip.action_slot = action.slots[0]
    track.mute = True

# ------------------------------------------------------ collision report ----
def collision_report():
    P0_ = posed_verts({n: REST[n] for n in REST})
    t_ = _bvh(P0_, "torso")[0]
    hit_ = t_.find_nearest(REST["spine_02"].to_translation())
    print("torso normals point", "out" if (REST["spine_02"].to_translation() - hit_[0]).dot(hit_[1]) < 0 else "IN")
    for level in LEVELS:
        set_shape(level)
        if QBODY:
            fit_row_seat()
        _report_level(level)
    set_shape(0)


def _report_level(level):
    total = 0.0
    only = os.environ.get("COLLISIONS_ONLY")
    for ex_name in EXERCISES:
        if only and ex_name not in only.split(","):
            continue
        worst = {}
        for c in ADJ_GRID[::2]:
            for k, (d, _) in penetrations(solve_pose(ex_name, float(c))).items():
                if d > worst.get(k, (0, 0))[0]:
                    worst[k] = (d, round(float(c), 1))
        total += sum(d for d, _ in worst.values())
        print(f"collisions {ex_name}@{level}:", ", ".join(f"{a}->{b} {d * 100:.1f}cm@{c}" for (a, b), (d, c) in
                                                   sorted(worst.items(), key=lambda kv: -kv[1][0])) or "none")
    print(f"collisions @{level} total depth {total * 100:.1f} cm")


if os.environ.get("COLLISIONS", "1") == "1":
    collision_report()

# --------------------------------------------------------------- export ----
os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(
    filepath=OUT,
    export_format="GLB",
    export_yup=True,
    export_animations=True,
    export_animation_mode="NLA_TRACKS",
    export_skins=True,
    export_morph=QBODY,
    export_morph_normal=False,
    export_morph_tangent=False,
    export_cameras=False,
    export_lights=False,
    export_image_format="JPEG" if QBODY else "AUTO",
)
print("bar widths:", {k: round(v, 3) for k, v in BAR_WIDTH.items()},
      "IK reach shortfall (m):", {k: round(v, 3) for k, v in IK_MISS.items()})
print("wrote", OUT, round(os.path.getsize(OUT) / 1e6, 2), "MB;",
      len(mesh.vertices), "vertices,", len(mesh.polygons), "triangles")

# -------------------------------------------------------------- preview ----
if PREVIEW_DIR:
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    tint = os.environ.get("PREVIEW_TINT", "")
    for name in tint.split(","):
        if name in bpy.data.materials:
            node = bpy.data.materials[name].node_tree.nodes["Principled BSDF"]
            node.inputs["Base Color"].default_value = (0.0, 0.9, 0.45, 1.0)
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 12
    scene.cycles.device = "CPU"
    scene.render.resolution_x, scene.render.resolution_y = 480, 560
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.22, 0.24, 0.27, 1)
    scene.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.5
    sun.rotation_euler = (math.radians(50), 0, math.radians(-35))
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    cam.data.lens = float(os.environ.get("PREVIEW_LENS", "70"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    target = Vector((0, 0.0, float(os.environ.get("PREVIEW_Z", "0.95"))))
    shots = os.environ.get("PREVIEW_SHOTS", "LatPulldown:0:0.5,LatPulldown:180:0.5").split(",")
    for shot in shots:
        ex_name, yaw, t, *close = shot.split(":")
        target = Vector((0, 0.0, float(os.environ.get("PREVIEW_Z", "0.95"))))
        dist = 4.6
        if close and close[0] in ("l", "r"):  # name:yaw:t:hand:distance
            target = grip_point(solve_pose(ex_name, contraction(float(t))), close[0])
            dist = float(close[1])
        elif close:                           # name:yaw:t:x:y:z:distance
            target = Vector(tuple(float(x) for x in close[:3]))
            dist = float(close[3])
        for track in arm.animation_data.nla_tracks:
            track.mute = track.name != ex_name
        # "Name@k": the clip fitted to shape level k, shown on that body
        level = int(ex_name.split("@")[1]) if "@" in ex_name else 0
        if body.data.shape_keys:
            for kb in body.data.shape_keys.key_blocks[1:]:
                kb.value = SHAPE_LEVELS[level]
        a = math.radians(float(yaw))
        cam.location = target + Vector((math.sin(a) * dist, -math.cos(a) * dist, 0.35 * dist / 4.6))
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.frame_set(int(round(float(t) * frames)))
        scene.render.filepath = os.path.join(PREVIEW_DIR, f"{ex_name}_{yaw}_{t}{'_close' if close else ''}.png")
        bpy.ops.render.render(write_still=True)
