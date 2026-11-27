"""Small glTF 2.0 helpers: read/write .glb, read accessors, sample node
animation (LINEAR / STEP), merge one .glb into another."""
import json
import struct

import numpy as np

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def read_glb(path):
    data = open(path, "rb").read()
    magic, version, length = struct.unpack("<4sII", data[:12])
    assert magic == b"glTF" and version == 2, path
    pos, j, b = 12, None, b""
    while pos < length:
        size, kind = struct.unpack("<I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + size]
        if kind == b"JSON":
            j = json.loads(chunk)
        elif kind == b"BIN\x00":
            b = bytes(chunk)
        pos += 8 + size
    return j, b


def write_glb(path, j, b):
    if j.get("buffers"):
        j["buffers"][0]["byteLength"] = len(b)
    js = json.dumps(j, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    b += b"\x00" * ((4 - len(b) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(b)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(js), b"JSON") + js)
        f.write(struct.pack("<I4s", len(b), b"BIN\x00") + b)


def accessor(j, b, i):
    a = j["accessors"][i]
    bv = j["bufferViews"][a["bufferView"]]
    dt = np.dtype(COMP[a["componentType"]])
    n = NCOMP[a["type"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0) or dt.itemsize * n
    raw = np.frombuffer(b, dtype=np.uint8, count=stride * (a["count"] - 1) + dt.itemsize * n, offset=off)
    out = np.lib.stride_tricks.as_strided(raw, shape=(a["count"], dt.itemsize * n), strides=(stride, 1))
    out = np.ascontiguousarray(out).view(dt).reshape(a["count"], n)
    if a.get("normalized"):
        out = out.astype(np.float64) / np.iinfo(dt).max
    return out.astype(np.float64)


def _slerp(q0, q1, t):
    d = float(np.dot(q0, q1))
    if d < 0:
        q1, d = -q1, -d
    if d > 0.9995:
        q = q0 + t * (q1 - q0)
    else:
        th = np.arccos(d)
        q = (np.sin((1 - t) * th) * q0 + np.sin(t * th) * q1) / np.sin(th)
    return q / np.linalg.norm(q)


def sample(times, values, interp, t, path):
    if t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    k = int(np.searchsorted(times, t) - 1)
    if interp == "STEP":
        return values[k]
    u = (t - times[k]) / (times[k + 1] - times[k])
    if path == "rotation":
        return _slerp(values[k], values[k + 1], u)
    return values[k] + u * (values[k + 1] - values[k])


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def trs(t, r, s):
    m = np.eye(4)
    m[:3, :3] = quat_mat(r) @ np.diag(s)
    m[:3, 3] = t
    return m


def node_tracks(j, b, anim):
    """{node index: {path: (times, values, interp)}} for one animation."""
    out = {}
    for ch in anim["channels"]:
        s = anim["samplers"][ch["sampler"]]
        n = ch["target"].get("node")
        if n is None:
            continue
        out.setdefault(n, {})[ch["target"]["path"]] = (accessor(j, b, s["input"])[:, 0],
                                                      accessor(j, b, s["output"]),
                                                      s.get("interpolation", "LINEAR"))
    return out


def node_matrix(j, tracks, n, t):
    nd = j["nodes"][n]
    vals = {"translation": nd.get("translation", [0, 0, 0]), "rotation": nd.get("rotation", [0, 0, 0, 1]),
            "scale": nd.get("scale", [1, 1, 1])}
    for p, (tt, vv, ip) in tracks.get(n, {}).items():
        if p in vals:
            vals[p] = sample(tt, vv, ip, t, p)
    return trs(np.array(vals["translation"], float), np.array(vals["rotation"], float), np.array(vals["scale"], float))


def _offset_textures(o, toff):
    if isinstance(o, dict):
        for k, v in o.items():
            if k.endswith("Texture") and isinstance(v, dict) and "index" in v:
                v["index"] += toff
            _offset_textures(v, toff)
    elif isinstance(o, list):
        for v in o:
            _offset_textures(v, toff)


def merge(base, bbin, add, abin, scene_nodes=True):
    """Append everything of `add` to `base`. Animations with the same name
    are joined into one (their channels play together)."""
    pad = (4 - len(bbin) % 4) % 4
    bbin = bbin + b"\x00" * pad
    boff = len(bbin)
    off = {k: len(base.get(k, [])) for k in ("bufferViews", "accessors", "images", "samplers", "textures",
                                              "materials", "meshes", "nodes")}
    for bv in add.get("bufferViews", []):
        bv = dict(bv)
        bv["buffer"] = 0
        bv["byteOffset"] = bv.get("byteOffset", 0) + boff
        base.setdefault("bufferViews", []).append(bv)
    for a in add.get("accessors", []):
        a = dict(a)
        if "bufferView" in a:
            a["bufferView"] += off["bufferViews"]
        base.setdefault("accessors", []).append(a)
    for im in add.get("images", []):
        im = dict(im)
        if "bufferView" in im:
            im["bufferView"] += off["bufferViews"]
        base.setdefault("images", []).append(im)
    for s in add.get("samplers", []):
        base.setdefault("samplers", []).append(dict(s))
    for t in add.get("textures", []):
        t = json.loads(json.dumps(t))
        if "source" in t:
            t["source"] += off["images"]
        if "sampler" in t:
            t["sampler"] += off["samplers"]
        base.setdefault("textures", []).append(t)
    for m in add.get("materials", []):
        m = json.loads(json.dumps(m))
        _offset_textures(m, off["textures"])
        base.setdefault("materials", []).append(m)
    for me in add.get("meshes", []):
        me = json.loads(json.dumps(me))
        for p in me["primitives"]:
            p["attributes"] = {k: v + off["accessors"] for k, v in p["attributes"].items()}
            if "indices" in p:
                p["indices"] += off["accessors"]
            if "material" in p:
                p["material"] += off["materials"]
            if "targets" in p:
                p["targets"] = [{k: v + off["accessors"] for k, v in tg.items()} for tg in p["targets"]]
        base.setdefault("meshes", []).append(me)
    for nd in add.get("nodes", []):
        nd = json.loads(json.dumps(nd))
        if "mesh" in nd:
            nd["mesh"] += off["meshes"]
        if "children" in nd:
            nd["children"] = [c + off["nodes"] for c in nd["children"]]
        assert "skin" not in nd and "camera" not in nd
        base.setdefault("nodes", []).append(nd)
    if scene_nodes:
        sc = base["scenes"][base.get("scene", 0)]
        sc["nodes"] += [n + off["nodes"] for n in add["scenes"][add.get("scene", 0)]["nodes"]]
    byname = {a["name"]: a for a in base.get("animations", [])}
    for an in add.get("animations", []):
        tgt = byname.get(an["name"])
        if tgt is None:
            tgt = {"name": an["name"], "channels": [], "samplers": []}
            base.setdefault("animations", []).append(tgt)
            byname[an["name"]] = tgt
        soff = len(tgt["samplers"])
        for s in an["samplers"]:
            s = dict(s)
            s["input"] += off["accessors"]
            s["output"] += off["accessors"]
            tgt["samplers"].append(s)
        for c in an["channels"]:
            c = json.loads(json.dumps(c))
            c["sampler"] += soff
            c["target"]["node"] += off["nodes"]
            tgt["channels"].append(c)
    for k in ("extensionsUsed", "extensionsRequired"):
        u = sorted(set(base.get(k, [])) | set(add.get(k, [])))
        if u:
            base[k] = u
    return base, bbin + abin


def parents(j):
    p = {}
    for i, nd in enumerate(j["nodes"]):
        for c in nd.get("children", []):
            p[c] = i
    return p


def node_world(j, tracks, n, t, par=None, cache=None):
    """World matrix of node n at time t (parents' animation included)."""
    par = parents(j) if par is None else par
    m = node_matrix(j, tracks, n, t)
    while n in par:
        n = par[n]
        m = node_matrix(j, tracks, n, t) @ m
    return m
