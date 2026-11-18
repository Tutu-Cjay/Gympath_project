"""Build the Movement Studio anatomy model (mobile/assets/models/anatomy_<sex>.glb).

Takes the real muscle shapes of BodyParts3D (one mesh per muscle) and its skin,
rigs them to a simple skeleton and bakes one animation per cable exercise.
Each muscle group becomes its own material, so the app highlights a muscle by
tinting that muscle's actual geometry -- nothing is painted onto a surface.
The skin is a see-through layer on top, so the figure reads as a person while
the working muscles show through in their real shape.

    pip install bpy numpy scipy
    git clone --depth 1 https://github.com/Kevin-Mattheus-Moerman/BodyParts3D
    python tools/build_anatomy_model.py BodyParts3D/assets/BodyParts3D_data \
        mobile/assets/models/anatomy_male.glb [preview_dir]
    ANATOMY_SEX=female MPFB_DATA=mpfb2/src/mpfb/data python tools/build_anatomy_model.py \
        BodyParts3D/assets/BodyParts3D_data mobile/assets/models/anatomy_female.glb

The female body and head come from MakeHuman (MPFB2 data,
CC0): see tools/real_head.py and tools/mh_body.py.

Data: BodyParts3D, (c) The Database Center for Life Science, licensed under
CC Attribution-Share Alike 2.1 Japan. The generated .glb is a derivative of
that data and carries the same licence; the app must show the credit line.
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
from mathutils import Matrix, Vector

DATA = sys.argv[1]
OUT = sys.argv[2]
PREVIEW_DIR = sys.argv[3] if len(sys.argv) > 3 else None
CACHE = os.environ.get("ANATOMY_CACHE")
# ANATOMY_SEX=female builds the female figure; it needs MPFB_DATA, the
# mpfb2/src/mpfb/data folder (CC0 MakeHuman data).
SEX = os.environ.get("ANATOMY_SEX", "male")
MPFB_DATA = os.environ.get("MPFB_DATA", "")
if not MPFB_DATA:
    sys.exit("MPFB_DATA must point at mpfb2/src/mpfb/data (the head is MakeHuman's)")

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
MUSCLE_INFLATE = 0.0035
# Avatar head: eyes (the app colours the iris) and hair styles, shown one at a
# time by the app. Male hair: caps over the scalp (base, extra on top, m);
# female: one fixed style, a ponytail (shells from tools/real_head.py).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import real_head  # noqa: E402
HAIR_STYLES = {"hair_buzz": (0.0025, 0.0), "hair_short": (0.006, 0.010)}
FEMALE_HAIR = ["hair_ponytail"]     # the female figure has one fixed look
FACE_MATERIALS = (["sclera", "iris", "pupil", "lashes"]
                  + (FEMALE_HAIR if SEX == "female" else list(HAIR_STYLES)))
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
        upper=((0.10, 0.03, -1.0), (0.10, -0.10, -0.99)),
        fore=((0.06, -0.10, -0.99), (0.02, -0.62, 0.78)),
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
STACK_TRAVEL = 0.32          # how far the weight stack rises at full contraction
STACK_BASE, STACK_HEIGHT = 0.10, 0.36
PROP_BONES = ["prop_bar", "prop_cable_a", "prop_cable_b", "prop_cable_c", "prop_stack",
              "prop_frame", "prop_pulley_a", "prop_pulley_b", "prop_seat_a", "prop_seat_b"]
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
# MakeHuman female differs from a MakeHuman male in the same pose and place
# (the female's chest is taken flat for that, so the pectorals follow the
# ribcage, not the breasts). Her skin is the MakeHuman female body itself.
import mh_body  # noqa: E402
pair = mh_body.posed_pair(MPFB_DATA, J)
if SEX == "female":
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
    # segment (an arm resting on the hip follows the arm, not the hip).
    def anat_segment(pts):
        best = np.full(len(pts), 1e9)
        label = np.zeros(len(pts), int)
        for k, (a, b) in enumerate(segment_lines()):
            ab = b - a
            t = np.clip(((pts - a) @ ab) / (ab @ ab), 0, 1)
            d = np.linalg.norm(pts - (a + t[:, None] * ab), axis=1)
            closer = d < best
            best[closer], label[closer] = d[closer], SEGMENT_ID[SEGMENT_LINES[k][0]]
        return label

    delta = pair["female_flat"] - pair["male"]
    trees = {}
    for seg in set(SEGMENT_ID.values()):
        ix = body_ix[mh_seg[body_ix] == seg]
        if len(ix) < 12:
            print("female warp: segment", seg, "has", len(ix), "vertices; using all")
            ix = body_ix
        trees[seg] = (cKDTree(pair["male"][ix]), delta[ix])
    print("female warp segments:", {k: int((mh_seg[body_ix] == v).sum()) for k, v in SEGMENT_ID.items()})

    def warp(pts):
        out = pts.copy()
        label = anat_segment(pts)
        for seg, (tree, dl) in trees.items():
            sel = label == seg
            if not sel.any():
                continue
            d, i = tree.query(pts[sel], k=12)
            w = 1.0 / (d + 0.015) ** 2
            out[sel] += (dl[i] * w[:, :, None]).sum(axis=1) / w.sum(axis=1)[:, None]
        return out

    for p in under_parts:
        p["verts"] = warp(p["verts"])
    remap = -np.ones(len(pair["female"]), int)
    remap[body_ix] = np.arange(len(body_ix))
    skin["verts"], skin["faces"] = pair["female"][body_ix], remap[tris]
    skin["weights"] = mh_w[body_ix] / np.maximum(mh_w[body_ix].sum(axis=1, keepdims=True), 1e-9)
    skin["orig_verts"] = skin["verts"]
    # Keep every muscle a little under the female skin.
    sn = np.zeros_like(skin["verts"])
    fn = np.cross(skin["verts"][skin["faces"][:, 1]] - skin["verts"][skin["faces"][:, 0]],
                  skin["verts"][skin["faces"][:, 2]] - skin["verts"][skin["faces"][:, 0]])
    for k in range(3):
        np.add.at(sn, skin["faces"][:, k], fn)
    sn /= np.maximum(np.linalg.norm(sn, axis=1, keepdims=True), 1e-12)
    skin_tree = cKDTree(skin["verts"])
    for p in parts:
        _, i = skin_tree.query(p["verts"])
        depth = ((p["verts"] - skin["verts"][i]) * sn[i]).sum(axis=1)
        # 15 mm leaves room for the 3.5 mm inflation and the coarser skin.
        out = depth > -0.015
        p["verts"][out] -= sn[i][out] * (depth[out] + 0.015)[:, None]
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
BONE_NAMES = list(BONES)


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
# The head is the skin's own head, drawn solid, with eyes (iris coloured by the
# app) and hair. The male's eyes are BodyParts3D's eyeballs; the female's
# head is MakeHuman's (her skin is the MakeHuman body), with its eyes, lashes
# and hair styles from tools/real_head.py. The neck line where the solid head
# starts sits under the chin.
FEMALE = SEX == "female"
NECK_Z = C7[2] + 0.55 * (C1[2] - C7[2])
female_pieces = []
if FEMALE:
    real_head.BASE_TARGETS = []        # exactly the skin's head
    _, pieces, _, head_info = real_head.build(MPFB_DATA, "female")
    s_mh, t_mh = pair["scale"], pair["offset"]["female"]
    for mat, pv, pf, _ in pieces:
        if mat in ("sclera", "iris", "pupil", "lashes") or mat in FEMALE_HAIR:
            female_pieces.append((mat, pv * s_mh + t_mh, pf))
    head_pts = np.concatenate([pv for mat, pv, pf, _ in pieces if mat in ("head", "lips")]) * s_mh + t_mh
    head_centre = head_info["centre"] * s_mh + t_mh
    head_scale = head_info["scale"] * s_mh
    chin_z = head_pts[(np.abs(head_pts[:, 0]) < 0.02) & (head_pts[:, 1] < head_centre[1] - 0.5 * head_scale), 2].min()
    NECK_Z = min(NECK_Z, chin_z - 0.014)
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
parts = [p for p in parts if len(p["faces"]) >= 4]
for p in parts:
    p["normals"] = vertex_normals(p["verts"], p["faces"])
    p["fade"] = neck_fade(p["verts"][:, 2])
    push = MUSCLE_INFLATE * p["fade"] - 0.004 * (1 - p["fade"])
    p["verts"] = p["verts"] + p["normals"] * push[:, None]

material_names = [g for g, _ in GROUPS] + ["other_muscle"] + STATIC_MATERIALS
all_verts, all_faces, all_mats, all_w = [], [], [], []
offset = 0
for p in parts:
    all_verts.append(p["verts"])
    all_faces.append(p["faces"] + offset)
    all_mats.append(np.full(len(p["faces"]), material_names.index(group_of(p))))
    all_w.append(skin_weights(p))
    offset += len(p["verts"])

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
sv[:, 1] = sv[:, 1] + (panel_y - sv[:, 1]) * blend
# Folds that were flattened onto the panel now face backwards: drop them.
tri = sv[skin["faces"]]
facing_back = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])[:, 1] >= 0
flat = (blend[skin["faces"]] > 0.98).all(axis=1)
skin["faces"] = skin["faces"][~(flat & facing_back)]

under_pts = np.concatenate([p["verts"] for p in under_parts])
under_w = np.concatenate([skin_weights(p) for p in under_parts])
near_d, near_i = cKDTree(under_pts).query(skin["verts"], k=8)
falloff = 1.0 / (near_d + 0.004) ** 2
skin_w = (under_w[near_i] * falloff[:, :, None]).sum(axis=1)
skin_w /= skin_w.sum(axis=1, keepdims=True)
if "weights" in skin:
    # MakeHuman skin brings its own weights; vertices added by the slicing
    # take those of the nearest original vertex.
    _, orig = cKDTree(skin["orig_verts"]).query(skin["verts"])
    skin_w = np.zeros((len(skin["verts"]), len(BONE_NAMES)))
    for k, b in enumerate(BONE_SEGMENTS):
        skin_w[:, BONE_NAMES.index(b)] = skin["weights"][orig, k]
# Male eyes: BodyParts3D's eyeballs, seen through an almond-shaped opening
# cut in the skin in front of each.
male_eyes = []
if not FEMALE:
    eb = weld(read_stl("FMA12513"))[0]
    eb[:, 2] -= ground
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


if FEMALE:
    for mat, v, f in female_pieces:
        add_rigid(mat, v, f)
else:
    for c, r in male_eyes:
        fwd = np.array([0.06 if c[0] > 0 else -0.06, -1.0, 0.0])
        for mat, (v, f) in real_head.eyeball(c, r * 0.97, fwd).items():
            add_rigid(mat, v, f)


# --- male hair ----------------------------------------------------------------
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
if not FEMALE:
    head_faces = skin["faces"][head]
    head_v = np.unique(head_faces)
    hv = skin["verts"]
    top_z = hv[head_v, 2].max()
    front_y, back_y = hv[head_v, 1].min(), hv[head_v, 1].max()
    along = np.clip((hv[:, 1] - front_y) / (back_y - front_y), 0, 1)   # 0 forehead .. 1 back
    hairline = (top_z - 0.085) + ((C1[2] + 0.005) - (top_z - 0.085)) * along ** 1.15
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
    ("prop_bar", "equipment", rod_mesh((0, -0.5, 0), (0, 0.5, 0), 0.014)),
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
    ("prop_seat_a", "pad", rod_mesh((-0.26, -0.30, 0.215), (0.26, -0.30, 0.215), 0.05, 12)),
    ("prop_seat_a", "equipment", box_mesh((0, -0.30, -0.05), (0.05, 0.05, 0.44))),
    # Row bench: long pad, two legs and the foot plate.
    ("prop_seat_b", "pad", box_mesh((0, -0.05, -0.035), (0.34, 0.95, 0.07))),
    ("prop_seat_b", "equipment", box_mesh((0, 0.25, -0.27), (0.07, 0.07, 0.40))),
    ("prop_seat_b", "equipment", box_mesh((0, -0.35, -0.27), (0.07, 0.07, 0.40))),
    ("prop_seat_b", "equipment", box_mesh((0, -0.92, -0.16), (0.50, 0.04, 0.34))),
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
    if name == "skin" or name.startswith("neck"):
        bsdf.inputs["Alpha"].default_value = SKIN_COLOR[3]
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
        else:
            m.blend_method = "BLEND"
    bsdf.inputs["Metallic"].default_value = 0.7 if name in ("equipment", "cable") else 0.0
    mesh.materials.append(m)

body = bpy.data.objects.new("Anatomy", mesh)
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
P0 = REST["pelvis"].to_translation()
HIP_REST = Vector(J["hip_l"])
SHANK = (Vector(J["ankle_l"]) - Vector(J["knee_l"])).length


def solve_props(ex_name, pose, c, hip_z):
    """Where the machine parts are for this pose."""
    cfg = MACHINE[ex_name]
    grips = {}
    for s in "lr":
        m = pose[f"hand_{s}"]
        grips[s] = m.to_translation() + (m.to_3x3() @ Vector((0, 1, 0))).normalized() * 0.075
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
        out["prop_cable_b"] = place(p1 + Vector((0, 0, 0.05)), top)
    else:
        across = grips["l"] - grips["r"]
        length = cfg["bar"] if cfg["bar"] else across.length + 0.06
        rot = Vector((0, 1, 0)).rotation_difference(across.normalized()).to_matrix().to_4x4()
        out["prop_bar"] = Matrix.Translation(mid) @ rot @ Matrix.Diagonal((1, length, 1, 1))
        out["prop_cable_a"] = place(mid, p1)
        out["prop_cable_c"] = place(p1, p2)
        out["prop_cable_b"] = place(p2, top)
    if ex_name == "LatPulldown":
        out["prop_seat_a"] = place((0, pose["pelvis"].to_translation().y + 0.02, hip_z - 0.10))
    if ex_name == "SeatedCableRow":
        out["prop_seat_b"] = place((0, pose["pelvis"].to_translation().y + 0.02, hip_z - 0.10))
    return out


def solve_pose(ex_name, c):
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


frames = int(round(REP_SECONDS * FPS))
scene.frame_start, scene.frame_end = 0, frames
arm.animation_data_create()
actions = {}
for ex_name, ex in EXERCISES.items():
    action = bpy.data.actions.new(ex_name)
    arm.animation_data.action = action
    last = {}
    for f in range(0, frames + 1, 2):
        key_pose(solve_pose(ex_name, contraction(f / frames)), f, last)
    actions[ex_name] = action
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
    export_morph=False,
    export_morph_normal=False,
    export_morph_tangent=False,
    export_cameras=False,
    export_lights=False,
)
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
        ex_name, yaw, t = shot.split(":")
        for track in arm.animation_data.nla_tracks:
            track.mute = track.name != ex_name
        a = math.radians(float(yaw))
        cam.location = target + Vector((math.sin(a) * 4.6, -math.cos(a) * 4.6, 0.35))
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.frame_set(int(round(float(t) * frames)))
        scene.render.filepath = os.path.join(PREVIEW_DIR, f"{ex_name}_{yaw}_{t}.png")
        bpy.ops.render.render(write_still=True)
