"""Read Quaternius' Universal Base Characters (CC0) glTF files.

Only the data is read (no glTF library needed): meshes with UVs and skin
weights, the skeleton's bind pose, and the textures' paths. Coordinates are
returned in the anatomy model's frame: metres, Z up, the figure facing -Y,
+X its left side (glTF is Y up and the characters face +Z).
"""
import json
import os

import numpy as np

_TYPES = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_SIZES = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def to_z_up(p):
    """glTF (Y up, facing +Z) -> anatomy frame (Z up, facing -Y)."""
    p = np.asarray(p, float)
    return np.stack([p[..., 0], -p[..., 2], p[..., 1]], axis=-1)


class Gltf:
    def __init__(self, path):
        self.path = path
        self.dir = os.path.dirname(path)
        self.g = json.load(open(path))
        self.buffers = [open(os.path.join(self.dir, b["uri"]), "rb").read() for b in self.g["buffers"]]

    def accessor(self, i):
        a = self.g["accessors"][i]
        v = self.g["bufferViews"][a["bufferView"]]
        dt = np.dtype(_TYPES[a["componentType"]])
        n = _SIZES[a["type"]]
        off = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = v.get("byteStride", 0) or dt.itemsize * n
        raw = np.frombuffer(self.buffers[v["buffer"]], dtype=np.uint8,
                            count=stride * (a["count"] - 1) + dt.itemsize * n, offset=off)
        out = np.lib.stride_tricks.as_strided(raw, shape=(a["count"], dt.itemsize * n), strides=(stride, 1))
        out = np.ascontiguousarray(out).view(dt).reshape(a["count"], n)
        if a.get("normalized"):
            out = out.astype(np.float64) / np.iinfo(dt).max
        return out if n > 1 else out[:, 0]

    def node_matrix(self, n):
        node = self.g["nodes"][n]
        if "matrix" in node:
            return np.array(node["matrix"], float).reshape(4, 4).T
        t = np.array(node.get("translation", [0, 0, 0]), float)
        x, y, z, w = node.get("rotation", [0, 0, 0, 1])
        s = np.array(node.get("scale", [1, 1, 1]), float)
        r = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        m = np.eye(4)
        m[:3, :3] = r * s
        m[:3, 3] = t
        return m

    def world_matrices(self):
        parent = {}
        for i, node in enumerate(self.g["nodes"]):
            for c in node.get("children", []):
                parent[c] = i
        out = {}

        def world(i):
            if i not in out:
                m = self.node_matrix(i)
                out[i] = world(parent[i]) @ m if i in parent else m
            return out[i]

        for i in range(len(self.g["nodes"])):
            world(i)
        return out

    def skeleton(self):
        """Bind-pose joint positions {name: xyz} (anatomy frame) and parents."""
        sk = self.g["skins"][0]
        ibm = self.accessor(sk["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
        names = [self.g["nodes"][j]["name"] for j in sk["joints"]]
        pos = {n: to_z_up(np.linalg.inv(m)[:3, 3]) for n, m in zip(names, ibm)}
        parent = {}
        for i, node in enumerate(self.g["nodes"]):
            for c in node.get("children", []):
                parent[self.g["nodes"][c]["name"]] = self.g["nodes"][i]["name"]
        return names, pos, {n: parent.get(n) for n in names}

    def meshes(self):
        """Every skinned primitive: dict(name, material, verts, normals, uv,
        faces, joints (N, 4) as joint names index, weights (N, 4))."""
        out = []
        world = self.world_matrices()
        for ni, node in enumerate(self.g["nodes"]):
            if "mesh" not in node:
                continue
            mesh = self.g["meshes"][node["mesh"]]
            skinned = "skin" in node
            for prim in mesh["primitives"]:
                a = prim["attributes"]
                v = self.accessor(a["POSITION"]).astype(float)
                nrm = self.accessor(a["NORMAL"]).astype(float) if "NORMAL" in a else np.zeros_like(v)
                if not skinned:
                    m = world[ni]
                    v = v @ m[:3, :3].T + m[:3, 3]
                    nrm = nrm @ m[:3, :3].T
                mat = self.g["materials"][prim["material"]]["name"] if "material" in prim else ""
                out.append(dict(
                    name=mesh["name"], material=mat,
                    verts=to_z_up(v), normals=to_z_up(nrm),
                    uv=self.accessor(a["TEXCOORD_0"]).astype(float) if "TEXCOORD_0" in a else None,
                    faces=self.accessor(prim["indices"]).astype(int).reshape(-1, 3),
                    joints=self.accessor(a["JOINTS_0"]).astype(int) if "JOINTS_0" in a else None,
                    weights=self.accessor(a["WEIGHTS_0"]).astype(float) if "WEIGHTS_0" in a else None,
                ))
        return out

    def texture_path(self, material, slot="baseColorTexture"):
        for m in self.g["materials"]:
            if m["name"] != material:
                continue
            pbr = m.get("pbrMetallicRoughness", {})
            t = pbr.get(slot) if slot != "normalTexture" else m.get("normalTexture")
            if not t:
                return None
            img = self.g["images"][self.g["textures"][t["index"]]["source"]]
            return os.path.join(self.dir, img["uri"]) if "uri" in img else None
        return None
