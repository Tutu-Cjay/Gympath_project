"""Realistic avatar head: the MakeHuman head (CC0 data from MPFB2) with its
own face-shape targets, new eyeballs, MakeHuman's lashes, and brows / hair /
beard / glasses made as shells over its surface (MakeHuman's separate hair
assets are not used).

Everything is returned in MakeHuman's frame as produced by mh_body.shaped()
(metres, Z up, facing -Y); the caller moves it with the same scale and offset
as the body. Regions are written in head-local units: x to the figure's left,
y forward (towards the face), z up; about 2 units from chin to crown, 0 at
eye level.

Pieces carry a material name the app switches on and colours:
  head (skin tone)  lips  sclera  iris (eye colour)  pupil  lashes
  brows_thin / brows_thick            (one shown)
  hair_<style>                        (one shown, style set per sex)
  beard_stubble / beard_full          (male, one or none)
  glasses_round / glasses_square      (one or none)

Each piece is (material, verts, faces, deltas): deltas gives every piece
vertex its offset for each face shape ({shape: (N, 3)}), or is None for a
piece that moves rigidly with the mean of info["follow"][piece index].
"""
import math

import numpy as np

import mh_body
from mesh_util import ellipsoid, merge, tube, vertex_normals

FACE_SHAPES = ["FaceRound", "FaceSquare", "FaceLong", "FaceHeart"]
HAIR = {
    "male": ["hair_buzz", "hair_short", "hair_side", "hair_curly"],
    "female": ["hair_bob", "hair_long", "hair_ponytail", "hair_bun", "hair_pixie"],
}

# Face shapes as mixes of MakeHuman targets; "Oval" (the default) is baked in.
# SHAPE_GAIN makes them read at phone size.
SHAPE_GAIN = 1.4
BASE_TARGETS = [("head/head-oval.target.gz", 0.5)]
SHAPE_TARGETS = {
    "FaceRound": [("head/head-round.target.gz", 1.0), ("head/head-fat-incr.target.gz", 0.4),
                  ("head/head-oval.target.gz", -0.5)],
    "FaceSquare": [("head/head-square.target.gz", 1.0), ("chin/chin-width-incr.target.gz", 0.5),
                   ("head/head-oval.target.gz", -0.5)],
    "FaceLong": [("head/head-scale-horiz-decr.target.gz", 0.35), ("chin/chin-height-incr.target.gz", 0.8),
                 ("head/head-scale-vert-incr.target.gz", 0.15)],
    "FaceHeart": [("head/head-invertedtriangular.target.gz", 1.0), ("chin/chin-width-decr.target.gz", 0.5),
                  ("forehead/forehead-temple-incr.target.gz", 0.5), ("head/head-oval.target.gz", -0.5)],
}


def target_delta(data, rel, n, w=1.0):
    """A MakeHuman target as per-vertex offsets in the output frame."""
    idx, d = mh_body._target(data, rel)
    out = np.zeros((n, 3))
    if len(idx):
        d = d.reshape(-1, 3) * w
        out[idx] = np.stack([d[:, 0], -d[:, 2], d[:, 1]], axis=1) * 0.1
    return out


def group_faces(faces, groups, name):
    tris = []
    for f, g in zip(faces, groups):
        if g == name:
            tris.append([f[0], f[1], f[2]])
            if len(f) == 4:
                tris.append([f[0], f[2], f[3]])
    return np.array(tris, int).reshape(-1, 3)


# ------------------------------------------------------- field splitting ----
def split(verts, faces, field, attrs):
    """Cut the triangles along field == 0 (linear on each edge).

    attrs (N, k) is interpolated with the positions. Returns
    (V, A, inside, outside): one new vertex per cut edge is appended;
    inside / outside are the faces where the field is > 0 / <= 0.
    """
    n = len(verts)
    pos = field > 0
    ia, ib, tt = [], [], []
    new = {}

    def cut(a, b):
        key = (min(a, b), max(a, b))
        if key not in new:
            fa, fb = field[key[0]], field[key[1]]
            new[key] = n + len(ia)
            ia.append(key[0])
            ib.append(key[1])
            tt.append(float(fa / (fa - fb)))
        return new[key]

    inside, outside = [], []
    cnt = pos[faces].sum(axis=1)
    inside += list(faces[cnt == 3])
    outside += list(faces[cnt == 0])
    for f in faces[(cnt == 1) | (cnt == 2)]:
        p = pos[f]
        lone = p if p.sum() == 1 else ~p
        k = int(np.argmax(lone))
        a, b, c = f[k], f[(k + 1) % 3], f[(k + 2) % 3]
        ab, ac = cut(a, b), cut(a, c)
        one, two = [[a, ab, ac]], [[ab, b, c], [ab, c, ac]]
        if p.sum() == 1:
            inside += one
            outside += two
        else:
            outside += one
            inside += two
    ia, ib, tt = np.array(ia, int), np.array(ib, int), np.array(tt)[:, None]
    V = np.concatenate([verts, verts[ia] * (1 - tt) + verts[ib] * tt])
    A = np.concatenate([attrs, attrs[ia] * (1 - tt) + attrs[ib] * tt])
    return V, A, np.array(inside, int).reshape(-1, 3), np.array(outside, int).reshape(-1, 3)


def subdivide(verts, attrs, faces):
    """Split every triangle into four at its edge midpoints."""
    n = len(verts)
    e = np.sort(np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]]), axis=1)
    uniq, inv = np.unique(e, axis=0, return_inverse=True)
    inv = inv.reshape(3, -1).T + n
    V = np.concatenate([verts, (verts[uniq[:, 0]] + verts[uniq[:, 1]]) / 2])
    A = np.concatenate([attrs, (attrs[uniq[:, 0]] + attrs[uniq[:, 1]]) / 2])
    a, b, c = faces.T
    ab, bc, ca = inv.T
    F = np.concatenate([np.stack([a, ab, ca], 1), np.stack([ab, b, bc], 1),
                        np.stack([ca, bc, c], 1), np.stack([ab, bc, ca], 1)])
    return V, A, F


def compact(V, A, faces):
    used = np.unique(faces)
    remap = -np.ones(len(V), int)
    remap[used] = np.arange(len(used))
    return V[used], A[used], remap[faces]


def eyeball(centre, radius, forward, n_lon=36):
    """Sphere with its pole looking `forward`, split into sclera, iris and
    pupil by the angle from the pole. Returns {material: (verts, faces)}."""
    fwd = forward / np.linalg.norm(forward)
    side = np.cross(fwd, [0, 0, 1.0])
    side /= np.linalg.norm(side)
    up = np.cross(side, fwd)
    lat = np.concatenate([[0.0, 0.10, 0.19], np.linspace(0.26, 0.47, 4), np.linspace(0.6, math.pi, 12)])
    rings = []
    for th in lat:
        # A slight cornea bulge over the iris.
        r = radius * (1 + 0.07 * max(0.0, 1 - th / 0.47))
        rings.append([centre + r * (math.cos(th) * fwd + math.sin(th) * (math.cos(p) * side + math.sin(p) * up))
                      for p in np.linspace(0, 2 * math.pi, n_lon, endpoint=False)])
    v = np.array(rings).reshape(-1, 3)
    out = {"pupil": [], "iris": [], "sclera": []}
    for i in range(len(lat) - 1):
        mat = "pupil" if lat[i + 1] <= 0.2 else "iris" if lat[i + 1] <= 0.48 else "sclera"
        for j in range(n_lon):
            a, b = i * n_lon + j, i * n_lon + (j + 1) % n_lon
            out[mat] += [[a, b, b + n_lon], [a, b + n_lon, a + n_lon]]
    return {m: (v, np.array(f)) for m, f in out.items()}


def smoothstep(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


# ---------------------------------------------------------------- build ----
def build(data, sex):
    """The head in MakeHuman's frame: (verts, pieces, morphs, info).

    verts  - the shaped MakeHuman mesh (all vertices)
    pieces - see the module docstring; the first two are the head skin
             ("head" and "lips"), cut off low on the neck
    morphs - {face shape: per-MakeHuman-vertex deltas}
    info   - centre / scale of the head-local frame, eye centres, follow
    """
    female = sex == "female"
    v, faces, groups = mh_body.shaped(data, sex, 0.3 if female else 0.0)
    n = len(v)
    for rel, w in BASE_TARGETS:
        v = v + target_delta(data, rel, n, w)
    morphs = {name: SHAPE_GAIN * sum(target_delta(data, rel, n, w) for rel, w in terms)
              for name, terms in SHAPE_TARGETS.items()}

    body = group_faces(faces, groups, "body")
    rig = mh_body.Rig(data)
    hw = np.zeros(n)
    for ix, w in rig.weights["head"]:
        hw[ix] += w
    cubes = mh_body.joints(v, faces, groups)
    head_v = np.unique(body[(hw[body] > 0.5).all(axis=1)])
    top = v[head_v, 2].max()
    chin = cubes["joint-jaw"][2] - 0.018 * (0.9 if female else 1.0)
    cz, sc = (top + chin) / 2, (top - chin) / 2
    cy = (v[head_v, 1].min() + v[head_v, 1].max()) / 2
    centre = np.array([0.0, cy, cz])

    def local(p):
        return np.stack([p[:, 0] / sc, -(p[:, 1] - cy) / sc, (p[:, 2] - cz) / sc], axis=1)

    L = local(v)
    normals = vertex_normals(v, body)
    names = list(morphs)
    # The head and neck down to the shoulders; the caller cuts it lower.
    region = body[(L[body][:, :, 2] > -2.3).all(axis=1) & (np.abs(L[body][:, :, 0]) < 1.4).all(axis=1)]
    hv = np.unique(region)
    remap = -np.ones(n, int)
    remap[hv] = np.arange(len(hv))
    skin_f = remap[region]
    skin_v = v[hv]
    # Per-vertex attributes carried through cutting and subdividing:
    # normal (3) and the morph deltas (3 per shape).
    skin_a = np.concatenate([normals[hv]] + [morphs[k][hv] for k in names], axis=1)
    pieces = []
    info = dict(centre=centre, scale=sc, local=local)

    def deltas(A):
        return {k: A[:, 3 + 3 * i: 6 + 3 * i] for i, k in enumerate(names)}

    def cut(field_fn, levels=0, margin=0.25):
        """Skin faces split along field_fn(local coords) == 0, subdividing
        `levels` times first where the field is within `margin`."""
        V, A, F = skin_v, skin_a, skin_f
        f = field_fn(local(V))
        if levels:
            near = (f[F] > -margin).any(axis=1)
            V, A, F = compact(V, A, F[near])
            for _ in range(levels):
                V, A, F = subdivide(V, A, F)
            f = field_fn(local(V))
        V, A, fin, fout = split(V, F, f, A)
        return V, A, fin, fout, field_fn(local(V))

    # Head skin and lips.
    mouth_z = -0.64 if female else -0.63
    lip_w = 0.26 if female else 0.23

    def mouth(P, margin=0.0):
        """> 0 inside an ellipse around the lips grown by `margin`."""
        e = 1 - (P[:, 0] / (lip_w + margin)) ** 2 - ((P[:, 2] - mouth_z) / (0.075 + margin)) ** 2
        return np.where(P[:, 1] > 0.5, e, -1.0)

    V, A, fin, fout, _ = cut(mouth)
    for mat, F in (("head", fout), ("lips", fin)):
        pv, pa, pf = compact(V, A, F)
        pieces.append((mat, pv, pf, deltas(pa)))

    def shell(mat, field_fn, thickness_fn, edge, levels=1):
        """Surface over field > 0, rising from the outline to
        thickness_fn(local coords) metres over `edge` local units."""
        V, A, fin, _, f = cut(field_fn, levels, margin=edge + 0.1)
        V, A, F = compact(V, A, fin)
        f = field_fn(local(V))
        nn = A[:, :3] / np.maximum(np.linalg.norm(A[:, :3], axis=1, keepdims=True), 1e-12)
        th = np.broadcast_to(thickness_fn(local(V)), (len(V),))
        V = V + nn * (th * smoothstep(np.maximum(f, 0) / edge) + 0.0004)[:, None]
        pieces.append((mat, V, F, deltas(A)))

    # Eyes: new eyeballs where MakeHuman's helper eyes are.
    follow = {}
    eyes = []
    eye_ix = []
    for s in "lr":
        ix = np.unique(group_faces(faces, groups, f"helper-{s}-eye"))
        eye_ix.append(ix)
        c = v[ix].mean(axis=0)
        r = np.linalg.norm(v[ix] - c, axis=1).mean()
        eyes.append((c, r))
        fwd = np.array([0.05 if s == "l" else -0.05, -1.0, 0.0])
        for mat, (ev, ef) in eyeball(c, r * 0.97, fwd).items():
            pieces.append((mat, ev, ef, None))
            follow[len(pieces) - 1] = ix
    info["eyes"] = eyes

    # Lashes: MakeHuman's lash helpers (upper and lower).
    for s in "lr":
        for k in (1, 2):
            tri = group_faces(faces, groups, f"helper-{s}-eyelashes-{k}")
            used = np.unique(tri)
            rm = -np.ones(n, int)
            rm[used] = np.arange(len(used))
            pieces.append(("lashes", v[used], rm[tri], {m: morphs[m][used] for m in names}))

    # Brows: from above the inner eye corner out past the outer one, with a
    # soft arch; thin or thick.
    eye_z = local(np.array([eyes[0][0]]))[0][2]
    for style, (h_in, h_out, lift, th) in {"brows_thin": (0.035, 0.018, 0.20, 0.0012),
                                           "brows_thick": (0.060, 0.030, 0.19, 0.0020)}.items():
        def brow(P, h_in=h_in, h_out=h_out, lift=lift):
            t = (np.abs(P[:, 0]) - 0.08) / 0.50
            mid = eye_z + lift + 0.07 * np.sin(np.clip(t, 0, 1) * math.pi * 0.8) - 0.05 * np.clip(t - 0.7, 0, 1)
            half = h_in + (h_out - h_in) * np.clip(t, 0, 1)
            f = np.minimum(half - np.abs(P[:, 2] - mid), np.minimum(t, 1 - t) * 0.3)
            return np.where(P[:, 1] > 0.2, f, -1.0)
        shell(style, brow, lambda P, th=th: th + 0 * P[:, 0], 0.015, levels=2)

    # Hair: shells over the scalp, kept off the ears.
    def ears(P):
        e = 1 - ((np.abs(P[:, 0]) - 0.82) / 0.24) ** 2 - ((P[:, 1] + 0.05) / 0.34) ** 2 - ((P[:, 2] + 0.08) / 0.44) ** 2
        return np.clip(e, 0, 1)

    def above(P):
        return P[:, 2] - hairline(P[:, 1], female) - 0.6 * ears(P)

    def topf(P):
        return smoothstep((P[:, 2] - 0.3) / 0.6)

    def hair(style, thick, field=above):
        shell(style, field, lambda P: thick(P) * sc, 0.12)

    if not female:
        hair("hair_buzz", lambda P: 0.020 + 0 * P[:, 0])
        hair("hair_short", lambda P: 0.045 + 0.10 * topf(P) + 0.05 * np.clip(P[:, 1] - 0.3, 0, 1))
        hair("hair_side", lambda P: 0.06 + 0.14 * topf(P) * np.clip(0.6 + P[:, 0], 0, 1.4) / 1.4
             + 0.06 * np.clip(P[:, 1] - 0.4, 0, 1))

        def curls(P):
            ang = np.arctan2(P[:, 0], P[:, 1])
            elev = np.arcsin(np.clip(P[:, 2] / np.maximum(np.linalg.norm(P, axis=1), 1e-9), -1, 1))
            return 0.07 + 0.07 * topf(P) + 0.035 * np.abs(np.sin(9 * ang) * np.sin(9 * elev))
        hair("hair_curly", curls)
    else:
        def long_field(P):
            # Down to the jaw line all round, leaving the face oval open.
            face = 1 - (P[:, 0] / 0.64) ** 2 - ((P[:, 2] + 0.30) / 0.86) ** 2
            w = smoothstep((P[:, 1] - 0.05) / 0.35)
            open_face = -0.35 * face * w + (1 - w)
            crown = above(P) + 0.9 * (1 - smoothstep(P[:, 1] / 0.4))
            return np.minimum.reduce([P[:, 2] + 0.95, open_face, crown]) - 1.2 * ears(P)

        def bob_t(P):
            # Fuller towards the ends, at the sides and back.
            flare = smoothstep((-P[:, 2] - 0.1) / 0.8) * smoothstep((0.55 - P[:, 1]) / 0.4)
            return 0.06 + 0.08 * topf(P) + 0.10 * flare
        hair("hair_bob", bob_t, long_field)
        hair("hair_pixie", lambda P: 0.04 + 0.07 * topf(P) + 0.05 * np.clip(P[:, 1] - 0.2, 0, 1))
        hair("hair_long", bob_t, long_field)
        cv, cf = curtain()
        pieces.append(("hair_long", to_mh(cv, centre, sc), cf, None))

        def tight(P):
            return 0.03 + 0.03 * topf(P)
        hair("hair_ponytail", tight)
        tail = [[0, -0.72 - 0.38 * math.sin(t * 2.0) + 0.1 * t, 0.42 - 1.7 * t] for t in np.linspace(0, 1, 14)]
        rad = 0.10 + 0.08 * np.sin(np.linspace(0.25, 1, 14) * math.pi) ** 0.7 * np.linspace(1, 0.4, 14)
        tv, tf = tube(tail, rad, 12)
        pieces.append(("hair_ponytail", to_mh(tv, centre, sc), tf, None))
        hair("hair_bun", tight)
        bv, bf = ellipsoid((0, -0.70, 0.80), (0.25, 0.23, 0.23), 18, 12)
        pieces.append(("hair_bun", to_mh(bv, centre, sc), bf, None))

    # Beard (male): jaw, chin and upper lip; the lips stay free.
    if not female:
        def beard(P):
            ax, ay, az = np.abs(P[:, 0]), P[:, 1], P[:, 2]
            # Upper edge: under the nose in the middle, rising along the cheek
            # to the sideburn in front of the ear; at the back it stops in
            # front of the ear, and under the chin it runs down to the neck.
            line = -0.46 + 0.42 * smoothstep((ax - 0.28) / 0.46)
            back = ay - 0.30 + 0.65 * smoothstep((-az - 0.55) / 0.35)
            return np.minimum.reduce([line - az, back, az + 1.04, -mouth(P, 0.045)])
        shell("beard_stubble", beard, lambda P: 0.0007 + 0 * P[:, 0], 0.06)
        shell("beard_full", beard, lambda P: (0.035 + 0.05 * smoothstep((-P[:, 2] - 0.6) / 0.5)) * sc, 0.10)

    # Glasses, in front of the eyes (built in head-local units).
    temple_x = np.abs(L[(L[:, 2] > 0) & (L[:, 2] < 0.2) & (L[:, 1] > 0.3) & (L[:, 1] < 0.5), 0]).max() + 0.04
    for style in ("glasses_round", "glasses_square"):
        parts, rims = [], []
        for (c, r), s in zip(eyes, (1, -1)):
            gc = local(c[None])[0] + np.array([0, 0.24, 0.0])
            pts = []
            for a in np.linspace(0, 2 * math.pi, 33):
                ca, sa = math.cos(a), math.sin(a)
                if style == "glasses_square":
                    ca = np.sign(ca) * abs(ca) ** 0.5
                    sa = np.sign(sa) * abs(sa) ** 0.5
                pts.append(gc + [0.20 * ca, 0, 0.15 * sa])
            parts.append(tube(pts, 0.016, 6, cap=False))
            rims.append(gc)
            parts.append(tube([gc + [s * 0.20, 0, 0.02], [s * temple_x, gc[1] - 0.12, gc[2] + 0.03],
                               [s * (temple_x + 0.05), -0.15, gc[2] - 0.02]], 0.014, 6))
        parts.append(tube([rims[0] - [0.20, 0, -0.03], rims[1] + [0.20, 0, 0.03]], 0.014, 6))
        gv, gf = merge(parts)
        pieces.append((style, to_mh(gv, centre, sc), gf, None))
        follow[len(pieces) - 1] = np.concatenate(eye_ix)
    # Other rigid pieces (hair extras) follow the crown.
    crown = np.where(L[:, 2] > 0.8)[0]
    for k, p in enumerate(pieces):
        if p[3] is None and k not in follow:
            follow[k] = crown
    info["follow"] = follow
    return v, pieces, morphs, info


def to_mh(p, centre, sc):
    """Head-local units -> MakeHuman frame."""
    return np.stack([p[:, 0] * sc, centre[1] - p[:, 1] * sc, centre[2] + p[:, 2] * sc], axis=1)


def hairline(y, female):
    """Height (local units) above which the scalp has hair, by front-back."""
    front, side, back = (0.50, 0.10, -0.80) if female else (0.55, 0.15, -0.70)
    return np.where(y > 0, side + (front - side) * smoothstep(y / 0.8),
                    side + (back - side) * smoothstep(-y / 0.8))


def curtain():
    """Long hair falling behind to between the shoulder blades (local units)."""
    rows = []
    for i, z in enumerate(np.linspace(-0.45, -2.3, 14)):
        r = 1.0 + 0.05 * min(1, i / 4)
        rows.append([[math.sin(a) * r * 0.80, -math.cos(a) * r * 0.82 - 0.06 - 0.12 * i / 13, z]
                     for a in np.linspace(-1.9, 1.9, 22)])
    rows = np.array(rows)
    w = rows.shape[1]
    cf = []
    for i in range(rows.shape[0] - 1):
        for j in range(w - 1):
            a = i * w + j
            cf += [[a, a + w, a + w + 1], [a, a + w + 1, a + 1]]
    return rows.reshape(-1, 3), np.array(cf)
