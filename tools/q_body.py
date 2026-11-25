"""Quaternius Universal Base Characters (CC0) as the app's body.

Loads a character (body, eyes, eyebrows) and its hairstyles, poses it from its
T-pose into the anatomy figure's rest pose by linear blend skinning, and gives
its joints under the anatomy rig's names, so the BodyParts3D muscles can be
fitted into it bone by bone and the rig, exercises and props use its joints.
"""
import math
import os

import numpy as np

import quaternius

PACK = "Universal Base Characters[Standard]"
CHAR = {"male": "Superhero_Male_FullBody.gltf", "female": "Superhero_Female_FullBody.gltf"}
# The darker skin textures carry the underwear in black; the app tints the
# skin itself (the texture is used in grey).
SKIN_TEXTURE = {"male": "T_Superhero_Male_Dark.png", "female": "T_Superhero_Female_Dark_BaseColor.png"}
NORMAL_TEXTURE = {"male": "T_Superhero_Male_Normal.png", "female": "T_Superhero_Female_Normal.png"}
# App hair id -> Quaternius hairstyle file.
HAIR = {"male": {"hair_buzz": "Hair_Buzzed", "hair_short": "Hair_SimpleParted"},
        "female": {"hair_bun": "Hair_Buns"}}
BROWS = {"male": "Eyebrows_Regular", "female": "Eyebrows_Female"}

# The hands are closed round a handle in the figure itself (degrees each
# finger joint bends towards the palm: knuckle, middle, tip). The fingers
# have no bones of their own in the app's rig, so this is the one grip all
# exercises share; the bar sits in its hollow (Character.grip_frame).
FINGER_CURL = {"index": (58, 78, 48), "middle": (62, 82, 50),
               "ring": (66, 85, 52), "pinky": (70, 88, 55)}
# Thumb: wrapped round the handle the other way, over the index finger:
# where its middle joint, last joint and tip go, in cm from the centre of
# the grip along (hand axis, palm normal, across the palm towards the
# little finger).
THUMB_PATH = ((-3.6, 2.6, -3.0), (-0.2, 3.6, -2.5), (3.1, 3.4, -2.0))

# Quaternius bone -> anatomy rig bone (fingers fold into the hand, toes into
# the foot, root into the pelvis).
def rig_bone(q):
    if q in ("root", "pelvis"):
        return "pelvis"
    if q == "neck_01":
        return "neck"
    if q == "Head":
        return "head"
    for part in ("index", "middle", "pinky", "ring", "thumb"):
        if q.startswith(part + "_"):
            return "hand_" + q[-1]
    if q.startswith("ball_"):
        return "foot_" + q[-1]
    return q


def _axis_angle(axis, deg):
    """Rotation matrix about a unit axis (right hand), degrees."""
    a = np.asarray(axis, float)
    a = a / np.linalg.norm(a)
    t = math.radians(deg)
    k = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * k + (1 - math.cos(t)) * (k @ k)


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


class Character:
    def __init__(self, root, sex):
        self.sex = sex
        base = os.path.join(root, PACK, "Base Characters", "Godot - UE")
        self.tex_dir = os.path.join(root, PACK, "Base Characters", "Textures")
        g = quaternius.Gltf(os.path.join(base, CHAR[sex]))
        self.names, self.joint, self.parent = g.skeleton()
        meshes = g.meshes()
        self.body = max(meshes, key=lambda m: len(m["verts"]))
        self.eyes = next(m for m in meshes if m["material"] == "MI_Eyes")
        self.eye_texture = g.texture_path("MI_Eyes")
        for m in meshes:
            m["joint_names"] = self.names
        hair_dir = os.path.join(root, PACK, "Hairstyles", "Rigged to Head Bone", "glTF (Godot -Unreal)")
        self.hair = {}
        for app_id, fname in list(HAIR[sex].items()) + [("brows", BROWS[sex])]:
            h = quaternius.Gltf(os.path.join(hair_dir, fname + ".gltf"))
            hn, hj, _ = h.skeleton()
            # Hairstyles are modelled on one head: move it onto this one.
            off = self.joint["Head"] - hj["Head"]
            for m in h.meshes():
                m["verts"] = m["verts"] + off
                m["joint_names"] = hn
                self.hair.setdefault(app_id, []).append(m)
        # Children of every bone, root first.
        kids = {}
        for n in self.names:
            kids.setdefault(self.parent[n], []).append(n)
        self.order = []

        def visit(n):
            self.order.append(n)
            for c in kids.get(n, []):
                visit(c)

        for n in self.names:
            if self.parent[n] not in self.names:
                visit(n)
        self._close_hands()
        # The bind pose (T-pose) is kept: the exported figure is skinned in
        # it, which is what Quaternius' skin weights are made for.
        for m in self.all_meshes():
            m["bind"] = m["verts"].copy()
        self.bind_joint = dict(self.joint)

    def _hand_axes(self, s, joint=None):
        """Wrist, hand axis (wrist to middle knuckle), palm normal and the
        across-the-palm direction (index to little finger) of hand s."""
        j = self.joint if joint is None else joint
        w = j[f"hand_{s}"]
        h = j[f"middle_01_{s}"] - w
        h = h / np.linalg.norm(h)
        b = j[f"pinky_01_{s}"] - j[f"index_01_{s}"]
        b = b - h * (b @ h)
        b = b / np.linalg.norm(b)
        n = np.cross(h, b)
        # the thumb sits on the palm side
        if (j[f"thumb_02_{s}"] - j[f"middle_01_{s}"]) @ n < 0:
            n = -n
        return w, h, n, b

    def _close_hands(self):
        """Bend the fingers and thumb round a handle (FINGER_CURL), in the
        T-pose, by the figure's own finger weights."""
        R, T = {}, {}
        axes = {s: self._hand_axes(s) for s in "lr"}
        for n in self.order:
            p = self.parent[n]
            r = R.get(p, np.eye(3))
            t = T.get(p, np.zeros(3))
            local = np.eye(3)
            s = n[-1]
            part = n.split("_")[0]
            if s in "lr" and n.endswith(("_01_" + s, "_02_" + s, "_03_" + s)) and \
                    part in ("index", "middle", "ring", "pinky"):
                _, h, nrm, _ = axes[s]
                k = int(n.split("_")[1]) - 1
                child = n.replace(f"_0{k + 1}_", f"_0{k + 2}_")
                if child not in self.joint:
                    child = n.replace(f"_0{k + 1}_", f"_0{k + 2}_leaf_")
                f = self.joint[child] - self.joint[n]
                f = f / np.linalg.norm(f)
                bend = np.cross(f, nrm)           # turns f towards the palm
                local = _axis_angle(bend, FINGER_CURL[part][k])
            hp = r @ self.joint[n] + t
            r = r @ local
            t = hp - r @ self.joint[n]
            R[n], T[n] = r, t
        for m in [self.body]:
            jn = m["joint_names"]
            v = m["verts"]
            out = np.zeros_like(v)
            nrm = np.zeros_like(v)
            Rs = np.stack([R[jn[i]] for i in range(len(jn))])
            Ts = np.stack([T[jn[i]] for i in range(len(jn))])
            for k in range(4):
                idx = m["joints"][:, k]
                w = m["weights"][:, k][:, None]
                out += w * (np.einsum("nij,nj->ni", Rs[idx], v) + Ts[idx])
                nrm += w * np.einsum("nij,nj->ni", Rs[idx], m["normals"])
            tot = m["weights"].sum(axis=1)[:, None]
            m["verts"] = out / np.maximum(tot, 1e-9)
            m["normals"] = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        self.joint = {n: R[n] @ self.joint[n] + T[n] for n in self.names}
        # the thumb round the handle (THUMB_PATH), joint by joint
        aims = {}
        for s in "lr":
            g = self.grip_frame(s, bind=False)
            pts = [self.joint[f"thumb_01_{s}"]] + [
                g["centre"] + (x * g["h"] + y * g["n"] + z * g["b"]) / 100 for x, y, z in THUMB_PATH]
            for k in range(3):
                aims[f"thumb_0{k + 1}_{s}"] = pts[k + 1] - pts[k]
        self.pose(aims)

    def grip_frame(self, s, bind=True):
        """Where a handle sits in hand s: the centre of the hollow of the
        closed fingers, and the hand's axes (wrist, hand axis, palm normal,
        across the palm = the handle's direction)."""
        j = self.bind_joint if bind else self.joint
        w, h, n, b = self._hand_axes(s, j)
        # circle through the middle finger's joints, in the plane (h, n)
        pts = np.array([j[f"middle_0{k}_{s}"] for k in (1, 2, 3)] + [j[f"middle_04_leaf_{s}"]])
        o = pts.mean(axis=0)
        u = np.stack([(pts - o) @ h, (pts - o) @ n], axis=1)
        A = np.c_[2 * u, np.ones(len(u))]
        cx, cy, c0 = np.linalg.lstsq(A, (u ** 2).sum(axis=1), rcond=None)[0]
        radius = math.sqrt(c0 + cx * cx + cy * cy)
        centre = o + cx * h + cy * n
        return dict(centre=centre, wrist=w, h=h, n=n, b=b, radius=radius)

    def all_meshes(self):
        out = [self.body, self.eyes]
        for ms in self.hair.values():
            out += ms
        return out

    def pose(self, aims):
        """Turn bones (Quaternius names) to point along aims[bone] (towards
        their first child), children following. Poses every mesh in place and
        returns the posed joint positions."""
        R, T = {}, {}
        first_child = {}
        for n in self.names:
            p = self.parent[n]
            if p in self.names and p not in first_child:
                first_child[p] = n
        for n in self.order:
            p = self.parent[n]
            r = R.get(p, np.eye(3))
            t = T.get(p, np.zeros(3))
            if n in aims:
                h = self.joint[n]
                tail = self.joint[first_child[n]]
                cur = r @ (tail - h)
                extra = _rotation(cur, np.asarray(aims[n], float))
                hp = r @ h + t
                r = extra @ r
                t = hp - r @ h
            R[n], T[n] = r, t
        for m in self.all_meshes():
            jn = m["joint_names"]
            v = m["verts"]
            out = np.zeros_like(v)
            nrm = np.zeros_like(v)
            for k in range(4):
                idx = m["joints"][:, k]
                w = m["weights"][:, k][:, None]
                Rs = np.stack([R[jn[i]] for i in range(len(jn))])
                Ts = np.stack([T[jn[i]] for i in range(len(jn))])
                out += w * (np.einsum("nij,nj->ni", Rs[idx], v) + Ts[idx])
                nrm += w * np.einsum("nij,nj->ni", Rs[idx], m["normals"])
            tot = m["weights"].sum(axis=1)[:, None]
            m["verts"] = out / np.maximum(tot, 1e-9)
            m["normals"] = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        self.joint = {n: R[n] @ self.joint[n] + T[n] for n in self.names}
        return self.joint

    def rig_weights(self, m, bone_names):
        """A mesh's skin weights on the anatomy rig's bones (N, len(bone_names))."""
        jn = m["joint_names"]
        col = np.array([bone_names.index(rig_bone(n)) for n in jn])
        w = np.zeros((len(m["verts"]), len(bone_names)))
        for k in range(4):
            np.add.at(w, (np.arange(len(w)), col[m["joints"][:, k]]), m["weights"][:, k])
        return w / np.maximum(w.sum(axis=1, keepdims=True), 1e-9)

    def rig_joints(self, bind=False):
        """Joint positions under the anatomy model's J names, plus the spine
        landmarks (mid_hip, L4, T11, T6, C7, C1, head_top); of the posed
        figure, or with bind=True of the T-pose it is skinned in."""
        j = self.bind_joint if bind else self.joint
        J = {}
        for s in "lr":
            J[f"sternal_{s}"] = j[f"clavicle_{s}"]
            J[f"shoulder_{s}"] = j[f"upperarm_{s}"]
            J[f"elbow_{s}"] = j[f"lowerarm_{s}"]
            J[f"wrist_{s}"] = j[f"hand_{s}"]
            # the hand bone runs along the palm (the fingers are curled)
            J[f"handtip_{s}"] = j[f"hand_{s}"] + 1.84 * (j[f"middle_01_{s}"] - j[f"hand_{s}"])
            J[f"hip_{s}"] = j[f"thigh_{s}"]
            J[f"knee_{s}"] = j[f"calf_{s}"]
            J[f"ankle_{s}"] = j[f"foot_{s}"]
            J[f"toe_{s}"] = j[f"ball_leaf_{s}"]
        top = self.body["verts"][:, 2].max()
        spine = dict(mid_hip=(j["thigh_l"] + j["thigh_r"]) / 2, L4=j["spine_01"], T11=j["spine_02"],
                     T6=j["spine_03"], C7=j["neck_01"], C1=j["Head"],
                     head_top=np.array([0.0, j["Head"][1], top]))
        return J, spine
