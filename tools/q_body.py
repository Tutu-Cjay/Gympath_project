"""Quaternius Universal Base Characters (CC0) as the app's body.

Loads a character (body, eyes, eyebrows) and its hairstyles, poses it from its
T-pose into the anatomy figure's rest pose by linear blend skinning, and gives
its joints under the anatomy rig's names, so the BodyParts3D muscles can be
fitted into it bone by bone and the rig, exercises and props use its joints.
"""
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
        # The bind pose (T-pose) is kept: the exported figure is skinned in
        # it, which is what Quaternius' skin weights are made for.
        for m in self.all_meshes():
            m["bind"] = m["verts"].copy()
        self.bind_joint = dict(self.joint)

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
            J[f"handtip_{s}"] = j[f"middle_04_leaf_{s}"]
            J[f"hip_{s}"] = j[f"thigh_{s}"]
            J[f"knee_{s}"] = j[f"calf_{s}"]
            J[f"ankle_{s}"] = j[f"foot_{s}"]
            J[f"toe_{s}"] = j[f"ball_leaf_{s}"]
        top = self.body["verts"][:, 2].max()
        spine = dict(mid_hip=(j["thigh_l"] + j["thigh_r"]) / 2, L4=j["spine_01"], T11=j["spine_02"],
                     T6=j["spine_03"], C7=j["neck_01"], C1=j["Head"],
                     head_top=np.array([0.0, j["Head"][1], top]))
        return J, spine
