"""MakeHuman bodies (CC0 data from MPFB2) posed and placed to match the
BodyParts3D anatomy figure, for building the female model.

Only MPFB's data files are read (base mesh, shape targets, game-engine rig and
skin weights); no MPFB code runs. Coordinates are returned in the anatomy
model's frame: metres, Z up, the figure facing -Y, +X its left side.
"""
import gzip
import json
import os

import numpy as np

RACES = ("african", "asian", "caucasian")


def read_obj(path):
    verts, faces, groups = [], [], []
    group = ""
    with open(path) as fh:
        for line in fh:
            if line.startswith("v "):
                verts.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("g "):
                group = line.split()[1]
            elif line.startswith("f "):
                faces.append([int(p.split("/")[0]) - 1 for p in line.split()[1:]])
                groups.append(group)
    return np.array(verts), faces, groups


def _target(data, rel):
    path = os.path.join(data, "targets", rel)
    out = []
    with gzip.open(path, "rt") as fh:
        for line in fh:
            if line.strip() and not line.startswith("#"):
                p = line.split()
                out.append((int(p[0]), float(p[1]), float(p[2]), float(p[3])))
    idx = np.array([o[0] for o in out], int)
    d = np.array([o[1:] for o in out])
    return idx, d


def shaped(data, sex, muscle=0.0, flat_chest=False):
    """Base mesh shaped as a young adult of `sex` ("male" / "female").

    muscle: 0 = average, 1 = MakeHuman's maximum muscle.
    flat_chest: female with the smallest cup (used to warp the muscles, so the
    pectorals follow the ribcage and not the breasts).
    """
    v, faces, groups = read_obj(os.path.join(data, "3dobjs", "base.obj"))
    md = "macrodetails/"
    terms = [(f"{md}{r}-{sex}-young.target.gz", 1 / 3) for r in RACES]
    for build, w in (("maxmuscle", muscle), ("averagemuscle", 1 - muscle)):
        if w <= 0:
            continue
        terms.append((f"{md}universal-{sex}-young-{build}-averageweight.target.gz", w))
        terms.append((f"{md}proportions/{sex}-young-{build}-averageweight-idealproportions.target.gz", w))
    if sex == "female" and flat_chest:
        terms.append(("breast/female-young-averagemuscle-averageweight-mincup-averagefirmness.target.gz", 1.0))
    for rel, w in terms:
        if not os.path.exists(os.path.join(data, "targets", rel)):
            continue
        idx, d = _target(data, rel)
        if len(idx):
            v[idx] += w * d.reshape(-1, 3)
    # MakeHuman: decimetres, Y up, facing +Z  ->  metres, Z up, facing -Y.
    return np.stack([v[:, 0], -v[:, 2], v[:, 1]], axis=1) * 0.1, faces, groups


def joints(verts, faces, groups):
    """Centre of every joint-* marker cube, by group name."""
    idx = {}
    for f, g in zip(faces, groups):
        if g.startswith("joint-"):
            idx.setdefault(g, set()).update(f)
    return {g: verts[sorted(i)].mean(axis=0) for g, i in idx.items()}


def _rotation(a, b):
    """Rotation matrix turning direction a onto direction b."""
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    v = np.cross(a, b)
    c = float(a @ b)
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3)
    k = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + k + k @ k * (1 / (1 + c))


class Rig:
    def __init__(self, data):
        self.bones = json.load(open(os.path.join(data, "rigs", "standard", "rig.game_engine.json")))
        self.weights = json.load(open(os.path.join(data, "rigs", "standard",
                                                   "weights.game_engine.json")))["weights"]
        self.order = []
        children = {}
        for n, b in self.bones.items():
            children.setdefault(b["parent"], []).append(n)

        def visit(n):
            self.order.append(n)
            for c in children.get(n, []):
                visit(c)

        for root in children.get("", []):
            visit(root)

    def head(self, bone, cubes):
        return cubes[self.bones[bone]["head"]["cube_name"]]

    def tail(self, bone, cubes):
        return cubes[self.bones[bone]["tail"]["cube_name"]]

    def pose(self, verts, cubes, aims):
        """Linear-blend-skin `verts` so each bone in `aims` points along the
        given direction (rotating about its head, children following)."""
        R, T = {}, {}
        for n in self.order:
            parent = self.bones[n]["parent"]
            r = R.get(parent, np.eye(3))
            t = T.get(parent, np.zeros(3))
            if n in aims:
                h = self.head(n, cubes)
                cur = r @ (self.tail(n, cubes) - h)
                extra = _rotation(cur, np.asarray(aims[n], float))
                hp = r @ h + t
                r = extra @ r
                t = hp - r @ h
            R[n], T[n] = r, t
        out = np.zeros_like(verts)
        total = np.zeros(len(verts))
        for n, pairs in self.weights.items():
            if n not in R or not pairs:
                continue
            ix = np.array([p[0] for p in pairs])
            w = np.array([p[1] for p in pairs])
            out[ix] += w[:, None] * (verts[ix] @ R[n].T + T[n])
            total[ix] += w
        unweighted = total < 1e-6
        out[~unweighted] /= total[~unweighted, None]
        out[unweighted] = verts[unweighted]
        moved = {k: None for k in cubes}
        return out, R, T, moved


def fit_scale_translate(src, dst):
    """Uniform scale s and translation t minimising |s*src + t - dst|."""
    ms, md = src.mean(axis=0), dst.mean(axis=0)
    a, b = src - ms, dst - md
    s = float((a * b).sum() / (a * a).sum())
    return s, md - s * ms


# Anatomy joint names (see build_anatomy_model.J) and the MakeHuman bones
# whose head marks the same joint.
MATCH = {
    "shoulder_{s}": ("upperarm_{s}", "head"),
    "elbow_{s}": ("lowerarm_{s}", "head"),
    "wrist_{s}": ("hand_{s}", "head"),
    "hip_{s}": ("thigh_{s}", "head"),
    "knee_{s}": ("calf_{s}", "head"),
    "ankle_{s}": ("foot_{s}", "head"),
}
LIMBS = [("upperarm", "shoulder", "elbow"), ("lowerarm", "elbow", "wrist"),
         ("thigh", "hip", "knee"), ("calf", "knee", "ankle")]


def posed_pair(data, anat_joints, female_muscle=0.3):
    """Male and female MakeHuman bodies in the anatomy figure's pose and place.

    Returns dict with "male", "female", "female_flat" vertex arrays (same
    topology), "faces", "groups" and the body-only face mask.
    """
    rig = Rig(data)
    out = {}
    for key, sex, muscle, flat in (("male", "male", 0.0, False),
                                   ("female", "female", female_muscle, False),
                                   ("female_flat", "female", female_muscle, True)):
        v, faces, groups = shaped(data, sex, muscle, flat)
        cubes = joints(v, faces, groups)
        ground = cubes["joint-ground"][2]
        v[:, 2] -= ground
        cubes = {k: c - np.array([0, 0, ground]) for k, c in cubes.items()}
        aims = {}
        for s in "lr":
            for bone, a, b in LIMBS:
                aims[f"{bone}_{s}"] = anat_joints[f"{b}_{s}"] - anat_joints[f"{a}_{s}"]
        posed, R, T, _ = rig.pose(v, cubes, aims)
        # Where the matched joints went.
        src, dst = [], []
        for s in "lr":
            for aj, (bone, end) in MATCH.items():
                bn = bone.format(s=s)
                p = rig.head(bn, cubes)
                parent = rig.bones[bn]["parent"]
                src.append(R[parent] @ p + T[parent])
                dst.append(anat_joints[aj.format(s=s)])
        out[key] = (posed, np.array(src), np.array(dst))
        out["ground_" + key] = ground
        out["faces"], out["groups"] = faces, groups
    # One placement for all three, fitted on the male: the female keeps her
    # own height and proportions relative to him.
    s, t = fit_scale_translate(out["male"][1], out["male"][2])
    for key in ("male", "female", "female_flat"):
        out[key] = out[key][0] * s + t
    # Unposed coordinates from shaped() (the head is not posed) -> anatomy
    # frame: p * scale + offset[key].
    out["scale"] = s
    out["offset"] = {k: t - s * np.array([0, 0, out.pop("ground_" + k)])
                     for k in ("male", "female", "female_flat")}
    return out
