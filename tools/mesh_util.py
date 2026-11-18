"""Small mesh primitives for the avatar head (numpy only)."""
import math

import numpy as np


# ------------------------------------------------------------ primitives ----
def sphere(nu=40, nv=28):
    """Unit UV sphere: vertices and triangles (poles shared)."""
    verts = [(0.0, 0.0, 1.0)]
    for i in range(1, nv):
        th = math.pi * i / nv
        for j in range(nu):
            ph = 2 * math.pi * j / nu
            verts.append((math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)))
    verts.append((0.0, 0.0, -1.0))
    v = np.array(verts)
    f = []
    for j in range(nu):
        f.append([0, 1 + j, 1 + (j + 1) % nu])
    for i in range(nv - 2):
        a, b = 1 + i * nu, 1 + (i + 1) * nu
        for j in range(nu):
            j2 = (j + 1) % nu
            f += [[a + j, b + j, b + j2], [a + j, b + j2, a + j2]]
    last = len(v) - 1
    base = 1 + (nv - 2) * nu
    for j in range(nu):
        f.append([base + j, last, base + (j + 1) % nu])
    return v, np.array(f)


def ellipsoid(center, radii, nu=16, nv=12):
    v, f = sphere(nu, nv)
    return v * np.asarray(radii) + np.asarray(center), f


def tube(points, radius, sides=8, cap=True):
    """Closed tube along a polyline; radius may vary per point."""
    p = np.asarray(points, float)
    r = np.broadcast_to(np.asarray(radius, float), (len(p),))
    verts, faces = [], []
    prev = None
    for i in range(len(p)):
        t = p[min(i + 1, len(p) - 1)] - p[max(i - 1, 0)]
        t /= np.linalg.norm(t) + 1e-12
        if prev is None:
            ref = np.array([0, 0, 1.0]) if abs(t[2]) < 0.9 else np.array([1.0, 0, 0])
            prev = np.cross(t, ref)
        n1 = prev - t * (prev @ t)
        n1 /= np.linalg.norm(n1) + 1e-12
        n2 = np.cross(t, n1)
        prev = n1
        for k in range(sides):
            a = 2 * math.pi * k / sides
            verts.append(p[i] + r[i] * (math.cos(a) * n1 + math.sin(a) * n2))
    for i in range(len(p) - 1):
        for k in range(sides):
            a, b = i * sides + k, i * sides + (k + 1) % sides
            faces += [[a, a + sides, b + sides], [a, b + sides, b]]
    if cap:
        for end, flip in ((0, True), (len(p) - 1, False)):
            c = len(verts)
            verts.append(p[end])
            for k in range(sides):
                a, b = end * sides + k, end * sides + (k + 1) % sides
                faces.append([c, b, a] if flip else [c, a, b])
    return np.array(verts), np.array(faces)


def merge(pieces):
    vs, fs, off = [], [], 0
    for v, f in pieces:
        vs.append(v)
        fs.append(f + off)
        off += len(v)
    return np.concatenate(vs), np.concatenate(fs)


def vertex_normals(v, f):
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    n = np.zeros_like(v)
    for k in range(3):
        np.add.at(n, f[:, k], fn)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    if ((v - v.mean(axis=0)) * n).sum() < 0:
        n = -n
    return n
