"""Build Gympath's cable machine models (cable_*.glb).

Every machine is made from code (no outside model, so no licence to carry):
steel frame, a selectorised weight stack with numbered plates, a selector
pin and the Gympath tracker on the head plate, guide rods, pulleys, the
cable routed over them, and the handle on it. Also the attachments and the
tracker alone (Waveshare ESP32-S3-LCD-1.28-B in its CNC case, the logo on
its screen).

Node prefixes: ft_ functional trainer, lp_ lat pulldown, sr_ seated row.
The parts that move are their own nodes:

    <stack>_head            head plate + selector stem + tracker (+ floating pulley)
    <stack>_plate_01..NN    plates, 01 is the top one (lightest)
    <stack>_pin             selector pin
    <stack>_seg_*           cable between the stack and the first fixed
                            pulley: origin at the top, scaled along Z
    *_pulley_*              pulley wheels (rotate about their axle)
    *_cable_out             cable from the last pulley to the handle: origin at
                            the pulley, scaled along its local Z
    *_handle                stop ball + carabiner + attachment
    *_handle_attach         the attachment (hangs at rest)
    ft_<L|R>_carriage       functional trainer carriage (up/down its column,
                            hole k: ft_carriage_z(k)), with ft_<L|R>_swivel
                            (turns about the cable) holding pulley D, and
                            ft_<L|R>_cable_drop (top pulley → carriage)
    ft_<L|R>_handle_att_*   d_handle / straight_bar / ankle_strap (one shown)
    ft_<L|R>_rope_*         rope whose strands aim at the hands (hidden)
    lp_seat, sr_bench       seat + thigh rollers / bench (slide to fit a body)

Each machine carries one 1 s animation per pin position, "lift_<kg>kg":
time 0..1 s is the stack going from rest to its full travel, so the app can
scrub currentTime with the tracker's displacement. For the Movement Studio
figures see fit_machines_to_figure.py, which bakes these parts into the
figure's own exercise clips.

Units: metres, glTF Y-up, the floor at y = 0.

    pip install bpy
    python tools/build_cable_machines.py out_dir [preview_dir]
"""
import math
import os
import sys

import bpy  # noqa: E402  (bpy first: it provides bmesh)
import bmesh
from mathutils import Matrix, Quaternion, Vector

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
PREVIEW = sys.argv[2] if len(sys.argv) > 2 else None
FPS = int(os.environ.get("FPS", 24))
# Material names get this prefix (the figure build uses "machine_", so the
# app can tell machine materials from muscle groups).
PREFIX = os.environ.get("MAT_PREFIX", "")
_HERE = os.path.dirname(os.path.abspath(__file__))
# The tracker's screen texture (tools/make_tracker_screen.py draws it from the logo).
SCREEN_TEX = os.environ.get("TRACKER_SCREEN") or next(
    (p for p in (os.path.join(_HERE, "tracker_screen.png"), os.path.join(_HERE, "..", "tex", "tracker_screen.png"))
     if os.path.exists(p)), "")
PLATE_T, PLATE_GAP = 0.025, 0.0015
PITCH = PLATE_T + PLATE_GAP
PLATE_W, PLATE_D = 0.30, 0.11
ROD_DX = 0.11
HIDE = 1e-4                  # scale of a hidden part (the glTF exporter drops the
                             # animation of anything under a zero scale)


# --------------------------------------------------------------------------
# Scene and materials
# --------------------------------------------------------------------------

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    sc = bpy.context.scene
    sc.render.fps = FPS
    sc.frame_start, sc.frame_end = 0, FPS
    global COLL, MATS, FONT
    COLL = bpy.data.collections.new("export")
    sc.collection.children.link(COLL)
    MATS = {}
    FONT = bpy.data.fonts.load("<builtin>")
    for name, rgb, metal, rough in MATERIALS:
        m = bpy.data.materials.new(PREFIX + name)
        try:
            m.use_nodes = True
        except Exception:
            pass
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        if bsdf is None:
            bsdf = m.node_tree.nodes.new("ShaderNodeBsdfPrincipled")
            out = m.node_tree.nodes.get("Material Output") or m.node_tree.nodes.new("ShaderNodeOutputMaterial")
            m.node_tree.links.new(bsdf.outputs[0], out.inputs[0])
        bsdf.inputs["Base Color"].default_value = (*rgb, 1)
        bsdf.inputs["Metallic"].default_value = metal
        bsdf.inputs["Roughness"].default_value = rough
        m.diffuse_color = (*rgb, 1)
        if name == "tracker_screen" and SCREEN_TEX:
            nt = m.node_tree
            img = nt.nodes.new("ShaderNodeTexImage")
            img.image = bpy.data.images.load(SCREEN_TEX)
            nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
            nt.links.new(img.outputs["Color"], bsdf.inputs["Emission Color"])
            bsdf.inputs["Emission Strength"].default_value = 1.6
        MATS[name] = m


# Names are kept stable so the app can recolour a material by name
# (model-viewer: model.getMaterialByName("frame").pbrMetallicRoughness...).
MATERIALS = [
    ("frame", (0.50, 0.53, 0.57), 0.55, 0.38),       # satin silver powder coat
    ("frame_dark", (0.045, 0.05, 0.055), 0.35, 0.45),  # carriages, brackets
    ("plate", (0.035, 0.037, 0.04), 0.25, 0.5),      # weight plates
    ("chrome", (0.92, 0.92, 0.94), 1.0, 0.1),
    ("aluminium", (0.72, 0.73, 0.75), 1.0, 0.28),
    ("rubber", (0.025, 0.025, 0.027), 0.0, 0.88),
    ("upholstery", (0.04, 0.04, 0.045), 0.0, 0.55),
    ("pulley", (0.06, 0.06, 0.065), 0.0, 0.32),      # nylon wheels
    ("cable", (0.015, 0.015, 0.017), 0.2, 0.35),
    ("shroud", (0.09, 0.095, 0.1), 0.3, 0.42),
    ("accent", (0.10, 0.80, 0.50), 0.1, 0.35),       # pin knobs, levers
    ("label", (0.90, 0.90, 0.88), 0.0, 0.45),        # plate numbers
    ("cavity", (0.004, 0.004, 0.004), 0.0, 0.9),
    ("tracker_case", (0.035, 0.036, 0.04), 0.85, 0.32),   # black anodised CNC aluminium
    ("tracker_back", (0.55, 0.57, 0.6), 0.0, 0.7),        # frosted acrylic bottom plate
    ("tracker_screen", (1.0, 1.0, 1.0), 0.0, 0.18),       # 1.28" round IPS, Gympath logo
]


# --------------------------------------------------------------------------
# Mesh helpers (all return objects linked into the export collection)
# --------------------------------------------------------------------------

def _obj(name, bm, mat, loc=(0, 0, 0), parent=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(MATS[mat] if isinstance(mat, str) else mat)
    ob = bpy.data.objects.new(name, me)
    COLL.objects.link(ob)
    ob.parent = parent
    ob.location = loc
    return ob


def empty(name, loc=(0, 0, 0), parent=None):
    ob = bpy.data.objects.new(name, None)
    COLL.objects.link(ob)
    ob.parent = parent
    ob.location = loc
    ob.empty_display_size = 0.05
    return ob


def box(name, size, loc, mat, bevel=0.004, seg=3, parent=None):
    """Axis-aligned box of size (x, y, z) centred at loc, edges rounded."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    b = min(bevel, min(size) * 0.45)
    if b > 0:
        bmesh.ops.bevel(bm, geom=bm.verts[:] + bm.edges[:], offset=b, segments=seg,
                        profile=0.5, affect="EDGES", clamp_overlap=True)
    return _obj(name, bm, mat, loc, parent)


def span(name, p0, p1, w, h, mat, bevel=0.006, parent=None):
    """Rectangular steel tube from p0 to p1 along one axis; w, h the section."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    ax = max(range(3), key=lambda i: abs(d[i]))
    size = [w, w, w]
    size[ax] = abs(d[ax])
    other = [i for i in range(3) if i != ax]
    size[other[0]], size[other[1]] = w, h
    return box(name, size, (p0 + p1) / 2, mat, bevel, 3, parent)


def _orient(bm, axis):
    """Turn a mesh built along +Z so that +Z points along axis."""
    q = Vector((0, 0, 1)).rotation_difference(Vector(axis).normalized())
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=q.to_matrix())


def rod(name, p0, p1, r, mat, seg=16, parent=None):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=seg, radius1=r, radius2=r, depth=d.length)
    _orient(bm, d)
    return _obj(name, bm, mat, (p0 + p1) / 2, parent)


def lathe(name, profile, mat, loc=(0, 0, 0), axis=(0, 0, 1), seg=24, closed=False,
          parent=None, scale=None):
    """Surface of revolution of profile [(r, z), ...] about axis (bottom→top)."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r < 1e-7:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / seg),
                                        r * math.sin(2 * math.pi * i / seg), z))
                          for i in range(seg)])
    pairs = list(zip(rings, rings[1:]))
    if closed:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        if len(a) == 1 and len(b) == 1:
            continue
        for i in range(seg):
            j = (i + 1) % seg
            if len(a) == 1:
                bm.faces.new((a[0], b[j], b[i]))
            elif len(b) == 1:
                bm.faces.new((a[i], a[j], b[0]))
            else:
                bm.faces.new((a[i], a[j], b[j], b[i]))
    if scale:
        bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    _orient(bm, axis)
    return _obj(name, bm, mat, loc, parent)


def disc(name, loc, axis, r, t, mat, seg=24, parent=None):
    return lathe(name, [(0, -t / 2), (r, -t / 2), (r, t / 2), (0, t / 2)], mat, loc, axis, seg,
                 parent=parent)


def torus_profile(R, r, n=10):
    return [(R + r * math.cos(t), r * math.sin(t))
            for t in (-math.pi / 2 + 2 * math.pi * k / n for k in range(n))]


def sphere(name, loc, r, mat, seg=16, parent=None):
    prof = [(r * math.sin(math.pi * k / 8), -r * math.cos(math.pi * k / 8)) for k in range(9)]
    prof[0], prof[-1] = (0, -r), (0, r)
    return lathe(name, prof, mat, loc, (0, 0, 1), seg, parent=parent)


def _curve_to_mesh(ob, mat):
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    name, loc, rot, par = ob.name, ob.location.copy(), ob.rotation_euler.copy(), ob.parent
    data = ob.data
    bpy.data.objects.remove(ob)
    bpy.data.curves.remove(data)
    me.materials.clear()
    me.materials.append(MATS[mat])
    new = bpy.data.objects.new(name, me)
    COLL.objects.link(new)
    new.parent, new.location, new.rotation_euler = par, loc, rot
    return new


def path(name, pts, r, mat, smooth=False, res=1, seg_u=8, parent=None):
    """Round tube along a polyline (or a smooth Bezier through pts)."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = res
    cu.use_fill_caps = True
    if smooth:
        sp = cu.splines.new("BEZIER")
        sp.bezier_points.add(len(pts) - 1)
        for bp, p in zip(sp.bezier_points, pts):
            bp.co = p
            bp.handle_left_type = bp.handle_right_type = "AUTO"
        cu.resolution_u = seg_u
    else:
        sp = cu.splines.new("POLY")
        sp.points.add(len(pts) - 1)
        for pt, p in zip(sp.points, pts):
            pt.co = (*p, 1)
    ob = bpy.data.objects.new(name, cu)
    COLL.objects.link(ob)
    ob.parent = parent
    return _curve_to_mesh(ob, mat)


def text(name, s, loc, rot, size, mat, parent=None, depth=0.0, align="CENTER"):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = s
    cu.font = FONT
    cu.size = size
    cu.extrude = depth
    cu.align_x = align
    cu.align_y = "CENTER"
    cu.resolution_u = 1
    ob = bpy.data.objects.new(name, cu)
    COLL.objects.link(ob)
    ob.parent = parent
    ob.location = loc
    ob.rotation_euler = rot
    return _curve_to_mesh(ob, mat)


FRONT = (math.pi / 2, 0, 0)          # text facing -Y (the user's side)


def bolt(name, loc, axis, mat="chrome", r=0.0075, parent=None):
    """Hex bolt head with a washer, its underside at loc, pointing along axis."""
    a = Vector(axis).normalized()
    out = [disc(name + "_w", Vector(loc) + a * 0.001, a, r * 1.45, 0.002, mat, 16, parent),
           disc(name, Vector(loc) + a * 0.0045, a, r, 0.005, mat, 6, parent)]
    return out


def screen_disc(name, center, normal, r, mat, seg=48, parent=None):
    """Flat disc with planar UVs (texture upright: +Z of the world)."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new()
    c = bm.verts.new((0, 0, 0))
    ring = [bm.verts.new((r * math.cos(2 * math.pi * i / seg), r * math.sin(2 * math.pi * i / seg), 0))
            for i in range(seg)]
    for i in range(seg):
        f = bm.faces.new((c, ring[i], ring[(i + 1) % seg]))
        for lp in f.loops:
            lp[uv].uv = (0.5 + lp.vert.co.x / (2 * r), 0.5 + lp.vert.co.y / (2 * r))
    _orient(bm, normal)
    return _obj(name, bm, mat, center, parent)


def tracker(name, loc, parent=None):
    """The Gympath tracker: Waveshare ESP32-S3-LCD-1.28-B in its CNC metal case
    (outline drawing: bezel Φ48 × 2, body Φ46 × 9.5, window Φ33), screen
    facing -Y. Origin at the centre of the back (the side that sits on the
    machine, held by its magnet)."""
    loc, f = Vector(loc), Vector((0, -1, 0))
    prof = [(0.0205, 0), (0.0226, 0), (0.023, 0.0004), (0.023, 0.0093), (0.0236, 0.0095), (0.024, 0.0099),
            (0.024, 0.0109), (0.0236, 0.0115), (0.0171, 0.0115), (0.0166, 0.0111), (0.0166, 0.0104),
            (0.0205, 0.0104)]
    out = [shade(lathe(name + "_case", prof, "tracker_case", loc, f, 40, closed=True, parent=parent))]
    out.append(disc(name + "_back", loc + f * 0.0009, f, 0.0206, 0.0016, "tracker_back", 48, parent))
    out.append(screen_disc(name + "_screen", loc + f * 0.0106, f, 0.0166, "tracker_screen", 48, parent))
    # USB-C opening at the bottom of the body
    out.append(box(name + "_usb", (0.0089, 0.0032, 0.003), loc + f * 0.0052 + Vector((0, 0, -0.0222)),
                   "cavity", 0.0012, 2, parent))
    return out


def merge(objs, name, parent=None, loc=None):
    """Join objects (any materials) into one mesh node under parent."""
    bpy.context.view_layer.update()
    base = Matrix.Translation(loc) if loc is not None else Matrix()
    pw = (parent.matrix_world if parent else Matrix()) @ base
    pinv = pw.inverted()
    mats, bm = [], bmesh.new()
    for ob in objs:
        me = ob.data.copy()
        me.transform(pinv @ ob.matrix_world)
        remap = []
        for m in me.materials:
            if m not in mats:
                mats.append(m)
            remap.append(mats.index(m))
        for p in me.polygons:
            p.material_index = remap[p.material_index] if remap else 0
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    for ob in objs:
        data = ob.data
        bpy.data.objects.remove(ob)
        if data and data.users == 0:
            bpy.data.meshes.remove(data)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(38))
    ob = bpy.data.objects.new(name, me)
    COLL.objects.link(ob)
    ob.parent = parent
    if loc is not None:
        ob.location = loc
    return ob


def shade(ob):
    for p in ob.data.polygons:
        p.use_smooth = True
    ob.data.set_sharp_from_angle(angle=math.radians(38))
    return ob


# --------------------------------------------------------------------------
# Machine parts
# --------------------------------------------------------------------------

def arc_pts(c, R, a0, a1, step=12):
    """Points on a circle in the YZ plane (angle 0 = +Y, 90° = +Z)."""
    n = max(2, int(abs(a1 - a0) / step) + 1)
    return [(c[0] + R * math.cos(math.radians(a0 + (a1 - a0) * k / (n - 1))),
             c[1] + R * math.sin(math.radians(a0 + (a1 - a0) * k / (n - 1)))) for k in range(n)]


def pulley(name, x, c, R, static, parent, width=0.026, cheek=True):
    """Nylon wheel (own node, axle along X) with aluminium cheek plates."""
    w = width
    prof = [(0.011, -w / 2), (R - 0.004, -w / 2), (R, -w / 2 + 0.003), (R, -0.006),
            (R - 0.008, -0.0015), (R - 0.008, 0.0015), (R, 0.006), (R, w / 2 - 0.003),
            (R - 0.004, w / 2), (0.011, w / 2)]
    wheel = lathe(name, prof, "pulley", (x, c[0], c[1]), (1, 0, 0), 28, closed=True, parent=parent)
    shade(wheel)
    # spokes/web: recess ring on each face
    for s in (-1, 1):
        static.append(disc(name + f"_hub{s}", (x + s * (w / 2 + 0.002), c[0], c[1]), (1, 0, 0),
                           0.016, 0.004, "aluminium", 16, parent))
    static.append(rod(name + "_axle", (x - w / 2 - 0.016, c[0], c[1]), (x + w / 2 + 0.016, c[0], c[1]),
                      0.006, "chrome", 12, parent))
    if cheek:
        for s in (-1, 1):
            static.append(disc(name + f"_cheek{s}", (x + s * (w / 2 + 0.007), c[0], c[1]), (1, 0, 0),
                               R + 0.014, 0.005, "aluminium", 28, parent))
        static += bolt(name + "_nut", (x + w / 2 + 0.0095, c[0], c[1]), (1, 0, 0), parent=parent)
    return wheel


def weight_stack(tag, cx, cy, n, kg, parent, static, floating_pulley=False, rod_top=1.95, tracker_dx=-0.075):
    """Plates, head plate, stem, pin. Returns dict of moving nodes and heights."""
    z0 = 0.14                                  # bottom of the stack (on bumpers)
    plates = []
    for i in range(n):                         # i = 0 is the top plate
        zc = z0 + (n - 1 - i) * PITCH + PLATE_T / 2
        parts = [box(f"{tag}_p{i}", (PLATE_W, PLATE_D, PLATE_T), (cx, cy, zc), "plate", 0.0035, 2, parent)]
        # pin slot on the front face, rod bushings showing on the face edges
        parts.append(box(f"{tag}_slot{i}", (0.028, 0.002, 0.011), (cx, cy - PLATE_D / 2, zc), "cavity", 0, 1, parent))
        parts.append(text(f"{tag}_n{i}", str(kg * (i + 1)), (cx + 0.085, cy - PLATE_D / 2 - 0.0003, zc), FRONT,
                          0.017, "label", parent))
        parts.append(text(f"{tag}_kg{i}", "kg", (cx + 0.118, cy - PLATE_D / 2 - 0.0003, zc - 0.0035), FRONT,
                          0.008, "label", parent))
        p = merge(parts, f"{tag}_plate_{i + 1:02d}", parent, Vector((cx, cy, zc)))
        plates.append(p)
    top = z0 + n * PITCH
    zh = top + 0.02                            # head plate centre
    head = [box(f"{tag}_hp", (PLATE_W + 0.01, PLATE_D + 0.006, 0.04), (cx, cy, zh), "frame_dark", 0.008, 3, parent)]
    head.append(box(f"{tag}_hpcap", (PLATE_W - 0.04, PLATE_D - 0.03, 0.006), (cx, cy, zh + 0.023), "shroud", 0.002, 2, parent))
    for s in (-1, 1):                          # bushings riding the guide rods
        head.append(lathe(f"{tag}_bush{s}", [(0, -0.03), (0.022, -0.03), (0.022, 0.03), (0, 0.03)], "chrome",
                          (cx + s * ROD_DX, cy, zh + 0.005), seg=20, parent=parent))
    head.append(rod(f"{tag}_stem", (cx, cy, z0 - 0.01), (cx, cy, zh), 0.011, "chrome", 14, parent))
    head.append(lathe(f"{tag}_stemtip", [(0, 0), (0.011, 0.012), (0.011, 0.014), (0, 0.014)], "chrome",
                      (cx, cy, z0 - 0.024), seg=14, parent=parent))
    head_top = zh + 0.026
    if floating_pulley:                        # 2:1 — yoke carrying a pulley
        zp = head_top + 0.075
        for s in (-1, 1):
            head.append(box(f"{tag}_yoke{s}", (0.006, 0.06, 0.1), (cx + s * 0.022, cy, head_top + 0.045),
                            "frame_dark", 0.004, 2, parent))
        head.append(rod(f"{tag}_yaxle", (cx - 0.03, cy, zp), (cx + 0.03, cy, zp), 0.006, "chrome", 12, parent))
        attach = zp
    else:                                      # cable eye bolt on the head plate
        head.append(lathe(f"{tag}_eyebase", [(0, 0), (0.014, 0), (0.014, 0.01), (0.008, 0.018), (0, 0.018)],
                          "chrome", (cx, cy, head_top - 0.003), seg=16, parent=parent))
        head.append(lathe(f"{tag}_eye", torus_profile(0.009, 0.0035, 8), "chrome", (cx, cy, head_top + 0.026),
                          (1, 0, 0), 14, closed=True, parent=parent))
        attach = head_top + 0.03
    if tracker_dx is not None:                 # the Gympath tracker, on the head plate
        head += tracker(f"{tag}_tracker", (cx + tracker_dx, cy - PLATE_D / 2 - 0.003, zh), parent)
    head = merge(head, f"{tag}_head", parent, Vector((cx, cy, zh)))
    # selector pin at its default plate
    pin_k = 6
    zk = plates[pin_k - 1].location.z
    pin = [rod(f"{tag}_pinshaft", (cx, cy - PLATE_D / 2 - 0.012, zk), (cx, cy + 0.01, zk), 0.0055, "chrome", 12, parent),
           lathe(f"{tag}_knob", [(0, 0), (0.012, 0.0), (0.016, 0.012), (0.014, 0.03), (0.008, 0.036), (0, 0.037)],
                 "accent", (cx, cy - PLATE_D / 2 - 0.012, zk), (0, -1, 0), 18, parent=parent),
           lathe(f"{tag}_lanyard", torus_profile(0.008, 0.0015, 6), "chrome", (cx, cy - PLATE_D / 2 - 0.045, zk),
                 (0, 0, 1), 10, closed=True, parent=parent)]
    pin = merge(pin, f"{tag}_pin", parent, Vector((cx, cy, zk)))
    # guide rods, bumpers, rod caps (static)
    for s in (-1, 1):
        static.append(rod(f"{tag}_rod{s}", (cx + s * ROD_DX, cy, 0.07), (cx + s * ROD_DX, cy, rod_top), 0.0125, "chrome", 16, parent))
        static.append(lathe(f"{tag}_bump{s}", [(0, 0), (0.03, 0), (0.03, 0.04), (0.026, 0.05), (0, 0.05)], "rubber",
                            (cx + s * ROD_DX, cy, z0 - 0.05), seg=20, parent=parent))
        static.append(lathe(f"{tag}_rcap{s}", [(0, 0), (0.022, 0), (0.022, 0.03), (0, 0.03)], "frame_dark",
                            (cx + s * ROD_DX, cy, rod_top - 0.03), seg=16, parent=parent))
    return dict(plates=plates, head=head, pin=pin, attach=attach, z0=z0, top=top, pin_k=pin_k)


def stack_tower(tag, cx, cy, top_z, parent, static, rod_top, feet=(0.30, 0.30), panel=True):
    """Two uprights flanking the stack, base rails, rod mounts, rear shroud."""
    ux = 0.205
    for s in (-1, 1):
        x = cx + s * ux
        static.append(span(f"{tag}_up{s}", (x, cy, 0.06), (x, cy, top_z), 0.06, 0.10, "frame"))
        static.append(span(f"{tag}_rail{s}", (x, cy - feet[0], 0.03), (x, cy + feet[1], 0.03), 0.07, 0.05, "frame"))
        for e, y in (("f", cy - feet[0] + 0.035), ("b", cy + feet[1] - 0.035)):
            static.append(box(f"{tag}_foot{s}{e}", (0.08, 0.07, 0.012), (x, y, 0.0), "rubber", 0.003, 2))
            static.append(box(f"{tag}_endcap{s}{e}", (0.072, 0.006, 0.052),
                              (x, y + (-0.035 if e == "f" else 0.035), 0.03), "rubber", 0.002, 1))
        # rod mount arms (top) — the centre stays free for the cable
        static.append(span(f"{tag}_rodarm{s}", (x - s * 0.03, cy, rod_top + 0.02), (cx + s * 0.08, cy, rod_top + 0.02),
                           0.05, 0.04, "frame_dark"))
        for k, z in enumerate((0.09, rod_top - 0.25, top_z - 0.05)):
            static += bolt(f"{tag}_bolt{s}{k}", (x, cy - 0.05, z), (0, -1, 0))
        static += bolt(f"{tag}_bolt{s}b", (x, cy - 0.05, 0.03), (0, -1, 0))
    static.append(span(f"{tag}_base", (cx - ux, cy, 0.075), (cx + ux, cy, 0.075), 0.08, 0.05, "frame"))
    static.append(span(f"{tag}_top", (cx - ux - 0.03, cy, top_z + 0.03), (cx + ux + 0.03, cy, top_z + 0.03), 0.10, 0.06, "frame"))
    for s in (-1, 1):
        static.append(box(f"{tag}_topcap{s}", (0.006, 0.10, 0.06), (cx + s * (ux + 0.063), cy, top_z + 0.03), "rubber", 0.002, 1))
    if panel:
        static.append(box(f"{tag}_shroud", (2 * ux - 0.06, 0.008, top_z - 0.25), (cx, cy + 0.07, (top_z + 0.16) / 2),
                          "shroud", 0.003, 2))
        # vent slots on the shroud
        for k in range(9):
            static.append(box(f"{tag}_vent{k}", (0.22, 0.002, 0.008), (cx, cy + 0.0655, 0.35 + k * 0.025), "cavity", 0, 1))
        # weight placard
        static.append(box(f"{tag}_placard", (0.12, 0.002, 0.16), (cx, cy + 0.0655, top_z - 0.30), "label", 0.004, 2))
        for k in range(5):
            static.append(box(f"{tag}_pl{k}", (0.09 - (k % 2) * 0.02, 0.0012, 0.006),
                              (cx, cy + 0.0643, top_z - 0.25 - k * 0.022), "cavity", 0, 1))


def cable_line(name, pts2, x, r=0.0032, parent=None):
    """Cable along a polyline in the YZ plane at height x."""
    return path(name, [(x, y, z) for y, z in pts2], r, "cable", parent=parent)


def cable_segment(name, top, length, parent=None, axis=(0, 0, -1)):
    """Straight cable: origin at `top`, body along `axis` (scaled along local Z)."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=0.0032, radius2=0.0032, depth=length)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -length / 2))
    ob = _obj(name, bm, "cable", top, parent)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, -1)).rotation_difference(Vector(axis))
    shade(ob)
    return ob


def reparent(ob, parent):
    bpy.context.view_layer.update()
    w = ob.matrix_world.copy()
    ob.parent = parent
    ob.matrix_parent_inverse = Matrix()
    ob.matrix_world = w


def handle_assembly(name, end, direction, builders, parent, shown=None):
    """Stop ball + carabiner + attachment(s) at the cable end, along direction.

    Built along local -Z; the group is turned so -Z points along direction.
    The attachment node hangs straight down at rest. builders: one builder,
    or {name: builder} — each its own node <name>_att_<k>, only `shown` at
    full size (the others scaled to 0, an animation can swap them).
    """
    g = empty(name, end, parent)
    g.rotation_mode = "QUATERNION"
    q = Vector((0, 0, -1)).rotation_difference(Vector(direction))
    g.rotation_quaternion = q
    parts = [lathe(name + "_ball", [(0, -0.022), (0.012, -0.0195), (0.021, -0.008), (0.022, 0.0), (0.021, 0.008),
                                    (0.012, 0.0195), (0.0035, 0.022), (0, 0.022)],
                   "rubber", (0, 0, -0.022), seg=18, parent=g),
             lathe(name + "_ferrule", [(0, 0), (0.006, 0), (0.006, 0.02), (0, 0.02)], "chrome", (0, 0, -0.062), seg=10, parent=g),
             lathe(name + "_crab", torus_profile(0.013, 0.003, 8), "chrome", (0, 0, -0.072), (1, 0, 0), 16, closed=True,
                   parent=g, scale=(1, 1.9, 1))]
    shade(parts[0])
    merge(parts, name + "_hardware", g)
    a = empty(name + "_attach", (0, 0, -0.098), g)
    a.rotation_mode = "QUATERNION"
    a.rotation_quaternion = q.inverted()           # hang straight down
    atts = {}
    if callable(builders):
        merge(builders(name + "_att", a), name + "_attach_mesh", a)
    else:
        for k, b in builders.items():
            e = empty(f"{name}_att_{k}", (0, 0, 0), a)
            merge(b(f"{name}_{k}", e), f"{name}_att_{k}_mesh", e)
            if k != shown:
                e.scale = (HIDE, HIDE, HIDE)
            atts[k] = e
    return g, a, q, atts


# --------------------------------------------------------------------------
# Attachments (ring at the origin, body hanging along -Z)
# --------------------------------------------------------------------------

def ring(name, parent, r=0.016):
    return lathe(name + "_ring", torus_profile(r, 0.0045, 10), "chrome", (0, 0, 0), (0, 1, 0), 18, closed=True,
                 parent=parent)


def grip(name, c, axis, length, r, parent, mat="rubber"):
    """Rubber grip with ribs and end flanges along axis, centred at c."""
    prof = [(0, -length / 2 - 0.006), (r + 0.006, -length / 2 - 0.006), (r + 0.006, -length / 2)]
    ribs = 7
    for k in range(ribs + 1):
        z = -length / 2 + length * k / ribs
        prof.append((r if k % 2 == 0 else r - 0.0012, z))
    prof += [(r + 0.006, length / 2), (r + 0.006, length / 2 + 0.006), (0, length / 2 + 0.006)]
    return shade(lathe(name, prof, mat, c, axis, 18, parent=parent))


def att_d_handle(name, p):
    out = [ring(name, p)]
    out.append(lathe(name + "_swivel", [(0, 0), (0.012, 0), (0.012, 0.03), (0.007, 0.035), (0, 0.035)], "aluminium",
                     (0, 0, -0.05), seg=14, parent=p))
    for s in (-1, 1):
        out.append(path(name + f"_strap{s}", [(0, 0, -0.045), (s * 0.03, 0, -0.06), (s * 0.068, 0, -0.12),
                                              (s * 0.074, 0, -0.175), (s * 0.074, 0, -0.19)],
                        0.0065, "chrome", smooth=True, res=2, seg_u=6, parent=p))
    out.append(rod(name + "_core", (-0.074, 0, -0.19), (0.074, 0, -0.19), 0.009, "chrome", 12, p))
    out.append(grip(name + "_grip", (0, 0, -0.19), (1, 0, 0), 0.115, 0.017, p))
    return out


def att_straight_bar(name, p, half=0.25, grip_c=None, grip_len=0.12):
    """Straight bar (half-length `half`); rubber grips centred at ±grip_c."""
    grip_c = half - 0.075 if grip_c is None else grip_c
    out = [ring(name, p)]
    out.append(lathe(name + "_hub", [(0, 0), (0.02, 0), (0.024, 0.012), (0.024, 0.05), (0.012, 0.06), (0, 0.062)],
                     "aluminium", (0, 0, -0.085), seg=20, parent=p))
    out.append(rod(name + "_neck", (0, 0, -0.03), (0, 0, -0.03 - 0.03), 0.007, "chrome", 12, p))
    out.append(rod(name + "_bar", (-half, 0, -0.09), (half, 0, -0.09), 0.0145, "chrome", 20, p))
    for s in (-1, 1):
        out.append(grip(name + f"_grip{s}", (s * grip_c, 0, -0.09), (1, 0, 0), grip_len, 0.0175, p))
        out.append(lathe(name + f"_end{s}", [(0, 0), (0.017, 0), (0.017, 0.01), (0.012, 0.016), (0, 0.016)], "rubber",
                         (s * half, 0, -0.09), (s, 0, 0), 16, parent=p))
    return out


def straight_bar(half, grip_c, grip_len):
    return lambda name, p: att_straight_bar(name, p, half, grip_c, grip_len)


# Bars sized for the Movement Studio figures' grips (half the hand spacing,
# over the three body sizes): pushdown 0.20–0.36 m, curl 0.31–0.52, row 0.18–0.32.
att_pushdown_bar = straight_bar(0.42, 0.275, 0.20)
att_curl_bar = straight_bar(0.60, 0.42, 0.24)
att_row_bar = straight_bar(0.40, 0.25, 0.20)

# Lat bar: straight to ±LAT_FLAT, a bend of LAT_BEND, then sloping down
# LAT_SLOPE per metre to its ends. lat_drop(h): how far below the straight
# part the bar is at h from the centre (where a hand at h holds it).
LAT_HALF, LAT_FLAT, LAT_BEND, LAT_SLOPE = 0.62, 0.28, 0.08, 0.30


def lat_drop(h):
    h = abs(h)
    if h <= LAT_FLAT:
        return 0.0
    if h <= LAT_FLAT + LAT_BEND:
        return LAT_SLOPE * (h - LAT_FLAT) ** 2 / (2 * LAT_BEND)
    return LAT_SLOPE * (h - LAT_FLAT - LAT_BEND / 2)


def att_lat_bar(name, p, half=LAT_HALF):
    out = [ring(name, p)]
    out.append(lathe(name + "_hub", [(0, 0), (0.02, 0), (0.024, 0.012), (0.024, 0.05), (0.012, 0.06), (0, 0.062)],
                     "aluminium", (0, 0, -0.085), seg=20, parent=p))
    out.append(rod(name + "_neck", (0, 0, -0.03), (0, 0, -0.06), 0.007, "chrome", 12, p))
    xs = [x / 100 for x in range(-int(half * 100), int(half * 100) + 1, 2)]
    out.append(path(name + "_bar", [(x, 0, -0.09 - lat_drop(x)) for x in xs], 0.0145, "chrome", res=3, parent=p))
    slope = math.atan(LAT_SLOPE)
    for s in (-1, 1):
        dirv = Vector((s * math.cos(slope), 0, -math.sin(slope)))
        gx = 0.47
        out.append(grip(name + f"_grip{s}", (s * gx, 0, -0.09 - lat_drop(gx)), dirv, 0.22, 0.0175, p))
        out.append(lathe(name + f"_end{s}", [(0, 0), (0.017, 0), (0.017, 0.01), (0.012, 0.016), (0, 0.016)], "rubber",
                         Vector((s * half, 0, -0.09 - lat_drop(half))), dirv, 16, parent=p))
    return out


def att_rope(name, p):
    out = [ring(name, p)]
    out.append(lathe(name + "_collar", [(0, 0), (0.018, 0), (0.024, 0.01), (0.024, 0.04), (0.016, 0.05), (0, 0.05)],
                     "chrome", (0, 0, -0.075), seg=20, parent=p))
    out.append(rod(name + "_neck", (0, 0, -0.03), (0, 0, -0.03 - 0.03), 0.006, "chrome", 12, p))
    for s in (-1, 1):
        pts = [(0, 0, -0.07), (s * 0.02, 0, -0.12), (s * 0.05, 0, -0.25), (s * 0.06, 0, -0.38)]
        out.append(path(name + f"_strand{s}", pts, 0.0125, "cable", smooth=True, res=2, seg_u=10, parent=p))
        # whipped end above the stopper
        out.append(lathe(name + f"_whip{s}", [(0, 0), (0.0145, 0), (0.0145, 0.03), (0, 0.03)], "accent",
                         (s * 0.06, 0, -0.395), (0, 0, 1), 16, parent=p))
        out.append(lathe(name + f"_stop{s}", [(0, 0), (0.026, 0.004), (0.031, 0.02), (0.028, 0.038), (0.014, 0.046),
                                              (0, 0.047)], "rubber", (s * 0.063, 0, -0.43), (0, 0, 1), 20, parent=p))
    return out


def att_v_bar(name, p):
    """Close-grip row handle: neutral grips along local Y (vertical in use)."""
    out = [ring(name, p)]
    out.append(lathe(name + "_swivel", [(0, 0), (0.013, 0), (0.013, 0.035), (0, 0.04)], "aluminium",
                     (0, 0, -0.07), seg=14, parent=p))
    out.append(rod(name + "_stem", (0, 0, -0.035), (0, 0, -0.12), 0.0095, "chrome", 14, p))
    for s in (-1, 1):
        out.append(path(name + f"_arm{s}", [(0, 0, -0.11), (s * 0.02, 0, -0.14), (s * 0.06, 0, -0.2), (s * 0.068, 0, -0.235)],
                        0.0095, "chrome", smooth=True, res=2, seg_u=6, parent=p))
        out.append(rod(name + f"_core{s}", (s * 0.068, -0.065, -0.235), (s * 0.068, 0.065, -0.235), 0.008, "chrome", 12, p))
        out.append(grip(name + f"_grip{s}", (s * 0.068, 0, -0.235), (0, 1, 0), 0.115, 0.0165, p))
    out.append(rod(name + "_brace", (-0.068, 0, -0.235), (0.068, 0, -0.235), 0.0075, "chrome", 12, p))
    return out


def att_ankle_strap(name, p):
    out = [ring(name, p)]
    out.append(lathe(name + "_d", torus_profile(0.02, 0.003, 8), "chrome", (0, 0, -0.03), (0, 1, 0), 16, closed=True,
                     parent=p, scale=(1.2, 1, 1)))
    prof = [(0.055 + 0.006 * math.cos(t), 0.025 * math.sin(t)) for t in
            (-math.pi / 2 + 2 * math.pi * k / 10 for k in range(10))]
    out.append(lathe(name + "_cuff", prof, "upholstery", (0, 0, -0.11), (0, 1, 0), 28, closed=True, parent=p,
                     scale=(1, 1.15, 1)))
    out.append(box(name + "_velcro", (0.05, 0.075, 0.012), (0, 0, -0.165), "accent", 0.004, 2, p))
    return out


ATTACHMENTS = {
    "d_handle": att_d_handle,
    "straight_bar": att_straight_bar,
    "lat_bar": att_lat_bar,
    "rope": att_rope,
    "v_bar": att_v_bar,
    "ankle_strap": att_ankle_strap,
}


# --------------------------------------------------------------------------
# Animation (one NLA track per pin position → one glTF animation each)
# --------------------------------------------------------------------------

class Anim:
    def __init__(self):
        self.tracks = {}       # anim name -> list of (obj, [(frame, path, value)])

    def key(self, anim, ob, frame, prop, value):
        self.tracks.setdefault(anim, {}).setdefault(ob.name, (ob, []))[1].append((frame, prop, value))

    def bake(self):
        for anim, objs in self.tracks.items():
            for ob, keys in objs.values():
                rest = {p: getattr(ob, p).copy() for _, p, _ in keys}
                ad = ob.animation_data or ob.animation_data_create()
                ad.action = None
                for f, prop, v in sorted(keys, key=lambda k: k[0]):
                    setattr(ob, prop, v)
                    ob.keyframe_insert(prop, frame=f)
                act = ad.action
                act.name = f"{anim}__{ob.name}"
                tr = ad.nla_tracks.new()
                tr.name = anim
                tr.mute = True            # rest pose stays the rest pose
                st = tr.strips.new(anim, 0, act)
                st.action_frame_start, st.action_frame_end = 0, FPS
                ad.action = None
                for p, v in rest.items():
                    setattr(ob, p, v)


def lift_anims(anim, machine, stacks, kg, travel, pulleys, segs, out, handle, ratio):
    """stacks: list of weight_stack dicts; pulleys: [(obj, R, sign)];
    segs: [(obj, L0)] shortening by travel; out: [(obj, L0)] lengthening by
    ratio*travel; handle: [(group, attach, q, direction)]."""
    n = len(stacks[0]["plates"])
    for k in range(1, n + 1):
        name = f"lift_{kg * k}kg"
        for st in stacks:
            moving = [st["head"]] + st["plates"][:k]
            for ob in moving:
                z = ob.location.z
                anim.key(name, ob, 0, "location", Vector((ob.location.x, ob.location.y, z)))
                anim.key(name, ob, FPS, "location", Vector((ob.location.x, ob.location.y, z + travel)))
            zk = st["plates"][k - 1].location.z
            pin = st["pin"]
            anim.key(name, pin, 0, "location", Vector((pin.location.x, pin.location.y, zk)))
            anim.key(name, pin, FPS, "location", Vector((pin.location.x, pin.location.y, zk + travel)))
        for ob, R, sign in pulleys:
            ob.rotation_mode = "XYZ"
            base = ob.rotation_euler.copy()
            end = base.copy()
            end.x += sign * ratio * travel / R
            anim.key(name, ob, 0, "rotation_euler", base)
            anim.key(name, ob, FPS, "rotation_euler", end)
        for ob, L0 in segs:
            anim.key(name, ob, 0, "scale", Vector((1, 1, 1)))
            anim.key(name, ob, FPS, "scale", Vector((1, 1, (L0 - travel) / L0)))
        for ob, L0 in out:
            anim.key(name, ob, 0, "scale", Vector((1, 1, 1)))
            anim.key(name, ob, FPS, "scale", Vector((1, 1, (L0 + ratio * travel) / L0)))
        for g, a, q, d in handle:
            p0 = g.location.copy()
            anim.key(name, g, 0, "location", p0)
            anim.key(name, g, FPS, "location", p0 + Vector(d).normalized() * ratio * travel)
            rest = a.rotation_quaternion.copy()
            ident = Quaternion()
            anim.key(name, a, 0, "rotation_quaternion", rest)
            anim.key(name, a, FPS * 0.12, "rotation_quaternion", rest.slerp(ident, 0.7))
            anim.key(name, a, FPS * 0.25, "rotation_quaternion", ident)
            anim.key(name, a, FPS, "rotation_quaternion", ident)


# --------------------------------------------------------------------------
# Machines
# --------------------------------------------------------------------------

ROPE_STRAND = 0.42           # collar to the stopper, each strand
FT_CX = 0.98                 # tower centres at ±FT_CX (the figure's chest-fly pulleys)
FT_HOLES = 30


def ft_hole_z(k):
    """Height of carriage hole k (0 = lowest) on a functional-trainer column."""
    return 0.25 + k * 0.06


def ft_carriage_z(k):
    """Carriage centre with its pop-pin in hole k."""
    return ft_hole_z(k) - 0.05


FT_RD, FT_ZA = 0.045, 2.00


def rope_dynamic(name, parent):
    """Triceps rope for animation: collar + two strands of fixed length
    ROPE_STRAND (they only turn, towards the hands) + stoppers past the hands."""
    col = empty(name + "_collar", (0, 0, 0), parent)
    merge([ring(name, col),
           lathe(name + "_c", [(0, 0), (0.018, 0), (0.024, 0.01), (0.024, 0.04), (0.016, 0.05), (0, 0.05)],
                 "chrome", (0, 0, -0.075), seg=20, parent=col),
           rod(name + "_neck", (0, 0, -0.03), (0, 0, -0.06), 0.006, "chrome", 12, col)], name + "_collar_mesh", col)
    out = {"collar": col}
    for s in ("l", "r"):
        st = empty(f"{name}_strand_{s}", (0, 0, 0), parent)
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=0.0125, radius2=0.0125, depth=ROPE_STRAND)
        bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -ROPE_STRAND / 2))
        shade(_obj(f"{name}_strand_{s}_mesh", bm, "cable", (0, 0, 0), st))
        stop = empty(f"{name}_stop_{s}", (0, 0, 0), parent)
        merge([lathe(name + f"_stop{s}", [(0, 0), (0.026, 0.004), (0.031, 0.02), (0.028, 0.038), (0.014, 0.046),
                                         (0, 0.047)], "rubber", (0, 0, -0.06), (0, 0, 1), 20, parent=stop),
               lathe(name + f"_whip{s}", [(0, 0), (0.0145, 0), (0.0145, 0.03), (0, 0.03)], "accent",
                     (0, 0, -0.03), (0, 0, 1), 16, parent=stop)], f"{name}_stop_{s}_mesh", stop)
        st.rotation_mode = stop.rotation_mode = "QUATERNION"
        for e in (st, stop):
            e.scale = (HIDE, HIDE, HIDE)
        out["strand_" + s], out["stop_" + s] = st, stop
    col.scale = (HIDE, HIDE, HIDE)
    col.rotation_mode = "QUATERNION"
    return out


FT_ATTACHMENTS = {"d_handle": att_d_handle, "straight_bar": att_straight_bar, "pushdown_bar": att_pushdown_bar,
                  "curl_bar": att_curl_bar, "ankle_strap": att_ankle_strap}


def functional_trainer(cx0=FT_CX):
    """Dual adjustable pulley (functional trainer / cable crossover), 2:1.

    Each carriage is its own node (moves up and down its column), with a
    swivel (turns towards the handle) holding pulley D; the cable from the
    top pulley to the carriage is a segment scaled along Z.
    """
    root = empty("functional_trainer")
    static, pulleys, segs, outs, handles, stacks, helpers = [], [], [], [], [], [], []
    parts = {k: {} for k in ("stacks", "carriage", "drop", "swivel", "pulley_D", "out", "handle", "rope",
                             "pulleys", "cx")}
    top_z, rod_top = 2.12, 1.95
    zA = FT_ZA
    RA = RB = 0.05
    RP, RD = 0.04, FT_RD
    hc = ft_carriage_z(15)                      # carriage centre at rest
    for side, cx in (("L", -cx0), ("R", cx0)):
        cy = 0.15
        yc = cy - 0.20                          # carriage column
        tg = f"ft_stack_{side}"
        inner = -1 if cx > 0 else 1             # side of the column facing the centre
        stack_tower(tg, cx, cy, top_z, root, static, rod_top)
        st = weight_stack(tg, cx, cy, 19, 5, root, static, floating_pulley=True, rod_top=rod_top,
                          tracker_dx=inner * 0.075)
        stacks.append(st)
        parts["stacks"][side], parts["cx"][side] = st, cx
        # column, its base, top link, hole marks
        static.append(span(f"{side}_col", (cx, yc, 0.06), (cx, yc, top_z + 0.06), 0.075, 0.075, "frame"))
        static.append(span(f"{side}_colbase", (cx - 0.205, yc, 0.03), (cx + 0.205, yc, 0.03), 0.07, 0.05, "frame"))
        static.append(span(f"{side}_toplink", (cx, yc, top_z + 0.03), (cx, cy - 0.05, top_z + 0.03), 0.08, 0.06, "frame"))
        static.append(box(f"{side}_gusset", (0.006, 0.12, 0.12), (cx, yc + 0.07, top_z - 0.04), "frame", 0.002, 1))
        for k in range(FT_HOLES):
            z = ft_hole_z(k)
            static.append(disc(f"{side}_hole{k}", (cx + inner * 0.0377, yc, z), (inner, 0, 0), 0.0085, 0.001, "cavity", 10))
            static.append(text(f"{side}_num{k}", str(k + 1), (cx - inner * 0.023, yc - 0.0377, z), FRONT, 0.013, "label"))
        # anchor eye for the 2:1 cable, top pulleys
        zF = 2.04
        static.append(box(f"{side}_anchor", (0.03, 0.03, 0.06), (cx, cy + RP, top_z - 0.03), "frame_dark", 0.004, 2))
        static.append(lathe(f"{side}_aeye", torus_profile(0.008, 0.003, 8), "chrome", (cx, cy + RP, zF + 0.002),
                            (1, 0, 0), 12, closed=True))
        a_c = (cy - RP - RA, zA)
        b_c = (yc - 0.075 + RB, zA)
        pa = pulley(f"ft_{side}_pulley_A", cx, a_c, RA, static, root)
        pb = pulley(f"ft_{side}_pulley_B", cx, b_c, RB, static, root)
        for nm, c in (("A", a_c), ("B", b_c)):
            static.append(box(f"{side}_hang{nm}", (0.05, 0.02, top_z - c[1] - 0.0), (cx, c[0], (top_z + c[1]) / 2 + 0.01),
                              "frame_dark", 0.003, 2))
        # floating pulley on the head plate (moves with it)
        zp = st["attach"]
        fhw = []
        pp = pulley(f"ft_{side}_pulley_float", cx, (cy, zp), RP, fhw, root, width=0.022, cheek=False)
        merge(fhw, f"{tg}_float_hw", st["head"])
        reparent(pp, st["head"])
        # cable: anchor → down to floating pulley → up to A → over B
        L0 = zF - zp
        segs.append((cable_segment(f"{tg}_seg_anchor", (cx, cy + RP, zF), L0, root), L0))
        L1 = zA - zp
        segs.append((cable_segment(f"{tg}_seg_up", (cx, cy - RP, zA), L1, root), L1))
        fl = cable_line(f"{tg}_cable_float", arc_pts((cy, zp), RP, 0, -180), cx)
        reparent(fl, st["head"])
        static.append(cable_line(f"{side}_cable_main", arc_pts(a_c, RA, 0, 90) + arc_pts(b_c, RB, 90, 180), cx))
        # B → carriage: its own segment (the carriage moves)
        ycab = yc - 0.075                       # the cable's line down the column
        zD = hc - 0.06                          # pulley D (on the swivel) centre
        drop = cable_segment(f"ft_{side}_cable_drop", (cx, ycab, zA), zA - zD, root)
        parts["drop"][side] = (drop, zA - zD)
        # carriage
        carn = empty(f"ft_{side}_carriage", (cx, yc, hc), root)
        car = [box(f"{side}_sleeve", (0.115, 0.115, 0.24), (cx, yc, hc), "frame_dark", 0.01, 3)]
        for z in (hc - 0.12, hc + 0.12):
            car.append(box(f"{side}_wiper{z:.2f}", (0.12, 0.12, 0.012), (cx, yc, z), "rubber", 0.004, 2))
        car.append(rod(f"{side}_poppin", (cx + inner * 0.057, yc, hc + 0.05), (cx + inner * 0.11, yc, hc + 0.05),
                       0.006, "chrome", 12))
        car.append(lathe(f"{side}_popknob", [(0, 0), (0.014, 0), (0.018, 0.014), (0.016, 0.03), (0, 0.033)], "accent",
                         (cx + inner * 0.11, yc, hc + 0.05), (inner, 0, 0), 18))
        car.append(path(f"{side}_lever", [(cx + inner * 0.057, yc - 0.03, hc - 0.03), (cx + inner * 0.10, yc - 0.03, hc - 0.03),
                                          (cx + inner * 0.13, yc - 0.03, hc - 0.07)], 0.008, "chrome", smooth=True, res=2))
        car.append(grip(f"{side}_levergrip", (cx + inner * 0.135, yc - 0.03, hc - 0.085), (inner * 0.3, 0, -1), 0.06, 0.012,
                        None, "accent"))
        car.append(box(f"{side}_swarm", (0.05, 0.03, 0.03), (cx, yc - 0.065, zD + 0.085), "frame_dark", 0.005, 2))
        merge(car, f"ft_{side}_carriage_mesh", carn)
        # swivel: turns about the cable's line; pivot tube, housing, pulley D
        sw = empty(f"ft_{side}_swivel", (0, ycab - yc, zD - hc), carn)
        sw.rotation_mode = "XYZ"
        bpy.context.view_layer.update()
        swp = [lathe(f"{side}_pivot", [(0.006, 0), (0.019, 0), (0.019, 0.04), (0.006, 0.04)], "aluminium",
                     (cx, ycab, zD + 0.06), seg=18, closed=True)]
        for s_ in (-1, 1):
            swp.append(box(f"{side}_hous{s_}", (0.006, 2 * RD + 0.03, 2 * RD + 0.05), (cx + s_ * 0.022, ycab - RD, zD + 0.005),
                           "frame_dark", 0.012, 3))
        swp.append(box(f"{side}_housbot", (0.05, 0.04, 0.012), (cx, ycab - RD - 0.01, zD - RD - 0.012), "frame_dark", 0.004, 2))
        swp.append(cable_line(f"{side}_cable_D", arc_pts((ycab - RD, zD), RD, 0, -90), cx))
        pd = pulley(f"ft_{side}_pulley_D", cx, (ycab - RD, zD), RD, swp, root, cheek=False)
        merge(swp, f"ft_{side}_swivel_mesh", sw)
        reparent(pd, sw)
        parts["carriage"][side], parts["swivel"][side], parts["pulley_D"][side] = carn, sw, pd
        pulleys += [(pa, RA, -1), (pb, RB, -1), (pd, RD, -1), (pp, RP, 1)]
        parts["pulleys"][side] = [(pa, RA), (pb, RB), (pd, RD), (pp, RP)]
        # cable out of D (forward), stop ball, handle with its attachments
        exitp = (cx, ycab - RD, zD - RD)
        l0 = 0.03
        co = cable_segment(f"ft_{side}_cable_out", exitp, l0, root, axis=(0, -1, 0))
        outs.append((co, l0))
        parts["out"][side] = (co, l0)
        g, a, q, atts = handle_assembly(f"ft_{side}_handle", (cx, ycab - RD - l0, zD - RD), (0, -1, 0),
                                        FT_ATTACHMENTS, root, shown="d_handle")
        handles.append((g, a, q, (0, -1, 0)))
        parts["handle"][side] = (g, a, atts)
        parts["rope"][side] = rope_dynamic(f"ft_{side}_rope", root)
        # storage hook with a rope / straight bar on the outer upright
        out_x = cx - inner * 0.235
        for k, (z, att) in enumerate(((1.62, att_rope), (1.30, att_straight_bar))):
            static.append(path(f"{side}_hook{k}", [(out_x - inner * 0.0, cy, z - 0.03), (out_x - inner * 0.05, cy, z - 0.03),
                                                   (out_x - inner * 0.07, cy, z), (out_x - inner * 0.065, cy, z + 0.02)],
                               0.006, "chrome", smooth=True, res=2))
            if (side == "L") == (k == 0):
                hold = empty(f"{side}_stored{k}", (out_x - inner * 0.068, cy, z - 0.016))
                hold.rotation_euler = (0, 0, math.pi / 2)
                bpy.context.view_layer.update()
                static += att(f"{side}_store{k}", hold)
                helpers.append(hold)
    # crossbars, pull-up bar with multi-grips, floor deck
    gap = cx0 - 0.235                           # inner faces of the towers
    static.append(span("front_beam", (-cx0, -0.05, top_z + 0.09), (cx0, -0.05, top_z + 0.09), 0.08, 0.08, "frame"))
    static.append(span("rear_beam", (-gap, 0.15, top_z + 0.03), (gap, 0.15, top_z + 0.03), 0.08, 0.06, "frame"))
    for s in (-1, 1):
        bx = s * (cx0 - 0.22)
        static.append(box(f"pu_bracket{s}", (0.012, 0.20, 0.05), (bx, -0.13, top_z + 0.09), "frame_dark", 0.004, 2))
        static += bolt(f"pu_bolt{s}", (bx + 0.006, -0.08, top_z + 0.09), (1, 0, 0))
        static.append(box(f"pu_mid{s}", (0.012, 0.20, 0.05), (s * 0.40, -0.13, top_z + 0.09), "frame_dark", 0.004, 2))
    static.append(rod("pullup_bar", (-(cx0 - 0.07), -0.22, top_z + 0.09), (cx0 - 0.07, -0.22, top_z + 0.09), 0.016, "chrome", 20))
    for s in (-1, 1):
        static.append(grip(f"pu_grip{s}", (s * (cx0 - 0.15), -0.22, top_z + 0.09), (1, 0, 0), 0.14, 0.019, None))
        static.append(path(f"pu_angle{s}", [(s * 0.22, -0.22, top_z + 0.09), (s * 0.22, -0.30, top_z + 0.06),
                                            (s * 0.20, -0.38, top_z + 0.005)], 0.015, "chrome", smooth=True, res=2))
        static.append(grip(f"pu_agrip{s}", (s * 0.205, -0.36, top_z + 0.02), (0, -0.85, -0.5), 0.10, 0.018, None))
    static.append(box("deck", (2 * gap, 0.80, 0.022), (0, -0.05, 0.011), "rubber", 0.006, 2))
    static.append(box("deck_trim", (2 * gap + 0.02, 0.82, 0.008), (0, -0.05, 0.004), "aluminium", 0.003, 1))
    for k in range(7):
        static.append(box(f"deck_rib{k}", (2 * gap - 0.06, 0.012, 0.004), (0, -0.40 + k * 0.115, 0.023), "rubber", 0.0015, 1))
    for s in (-1, 1):
        static.append(span(f"deck_link{s}", (s * gap, 0.15, 0.03), (s * (cx0 - 0.205), 0.15, 0.03), 0.07, 0.05, "frame"))
    merge(static, "functional_trainer_frame", root)
    for h in helpers:
        bpy.data.objects.remove(h)
    anim = Anim()
    travel, ratio = 0.85, 2.0
    lift_anims(anim, root, stacks, 5, travel, pulleys, segs, outs, handles, ratio)
    root["travel_m"], root["ratio"], root["kg_per_plate"] = travel, ratio, 5
    parts.update(ratio=ratio, segs=segs, hc_rest=hc, RD=RD)
    return root, anim, parts


def lat_pulldown():
    root = empty("lat_pulldown")
    static, pulleys, segs, outs, handles = [], [], [], [], []
    cx, cy, top_z, rod_top = 0.0, 0.50, 2.22, 1.98
    RA = RB = 0.05
    zA = 2.10
    tg = "lp_stack"
    stack_tower(tg, cx, cy, top_z, root, static, rod_top, feet=(0.30, 0.25))
    st = weight_stack(tg, cx, cy, 20, 5, root, static, rod_top=rod_top)
    # boom to the front pulley, gusset
    yb = -0.05
    static.append(span("boom", (0, cy + 0.05, top_z + 0.11), (0, yb - 0.09, top_z + 0.11), 0.08, 0.10, "frame"))
    static.append(box("boom_cap", (0.08, 0.006, 0.10), (0, yb - 0.093, top_z + 0.11), "rubber", 0.002, 1))
    static.append(path("boom_gusset", [(0, cy - 0.05, top_z - 0.20), (0, cy - 0.30, top_z + 0.06)], 0.02, "frame", res=1))
    a_c, b_c = (cy - RA, zA), (yb, zA)
    pa = pulley("lp_pulley_A", 0, a_c, RA, static, root)
    pb = pulley("lp_pulley_B", 0, b_c, RB, static, root)
    for nm, c in (("A", a_c), ("B", b_c)):
        static.append(box(f"hang{nm}", (0.05, 0.02, top_z + 0.06 - c[1]), (0, c[0], (top_z + 0.06 + c[1]) / 2), "frame_dark", 0.003, 2))
    pulleys += [(pa, RA, -1), (pb, RB, -1)]
    L0 = a_c[1] - st["attach"]
    segs.append((cable_segment("lp_stack_seg", (0, cy, a_c[1]), L0, root), L0))
    static.append(cable_line("cable_main", arc_pts(a_c, RA, 0, 90) + arc_pts(b_c, RB, 90, 180), 0))
    exitp = (0, yb - RB, zA)
    l0 = 0.22
    co = cable_segment("lp_cable_out", exitp, l0, root)
    outs.append((co, l0))
    g, a, q, _ = handle_assembly("lp_handle", (0, yb - RB, zA - l0), (0, 0, -1), att_lat_bar, root)
    handles.append((g, a, q, (0, 0, -1)))
    # base: tower crossbar, spine, front stabiliser
    static.append(span("tower_cross", (-0.205, cy - 0.30, 0.03), (0.205, cy - 0.30, 0.03), 0.07, 0.05, "frame"))
    static.append(span("spine", (0, cy - 0.30, 0.035), (0, -0.62, 0.035), 0.08, 0.06, "frame"))
    static.append(span("stabiliser", (-0.34, -0.62, 0.03), (0.34, -0.62, 0.03), 0.07, 0.05, "frame"))
    for s in (-1, 1):
        static.append(box(f"stab_foot{s}", (0.08, 0.08, 0.012), (s * 0.30, -0.62, 0.0), "rubber", 0.003, 2))
        static.append(box(f"stab_cap{s}", (0.006, 0.072, 0.052), (s * 0.343, -0.62, 0.03), "rubber", 0.002, 1))
    # seat and thigh pads: one node (origin: top centre of the seat pad), it
    # slides on the posts to fit the figure
    ys, yt = -0.36, -0.06              # seat / thigh rollers (the figure's layout)
    seat_top = 0.4925
    seat = empty("lp_seat", (0, ys, seat_top), root)
    static.append(span("seat_post", (0, ys, 0.06), (0, ys, 0.36), 0.065, 0.065, "frame"))
    static.append(span("thigh_post", (0, yt + 0.02, 0.06), (0, yt + 0.02, 0.58), 0.06, 0.06, "frame"))
    sp = [span("seat_sleeve", (0, ys, 0.26), (0, ys, 0.40), 0.08, 0.08, "frame_dark"),
          rod("seat_pin", (0, ys - 0.04, 0.33), (0, ys - 0.09, 0.33), 0.006, "chrome", 12),
          lathe("seat_knob", [(0, 0), (0.014, 0), (0.018, 0.014), (0.016, 0.03), (0, 0.033)], "accent",
                (0, ys - 0.09, 0.33), (0, -1, 0), 18),
          box("seat_base", (0.34, 0.32, 0.015), (0, ys, 0.41), "frame_dark", 0.004, 2),
          box("seat_pad", (0.36, 0.34, 0.075), (0, ys, 0.455), "upholstery", 0.03, 4),
          box("seat_seam", (0.362, 0.342, 0.004), (0, ys, 0.445), "rubber", 0.012, 2),
          span("thigh_inner", (0, yt + 0.02, 0.50), (0, yt + 0.02, 0.74), 0.045, 0.045, "chrome"),
          span("thigh_sleeve", (0, yt + 0.02, 0.52), (0, yt + 0.02, 0.60), 0.075, 0.075, "frame_dark"),
          rod("thigh_pin", (0, yt - 0.02, 0.56), (0, yt - 0.07, 0.56), 0.006, "chrome", 12),
          lathe("thigh_knob", [(0, 0), (0.014, 0), (0.018, 0.014), (0.016, 0.03), (0, 0.033)], "accent",
                (0, yt - 0.07, 0.56), (0, -1, 0), 18),
          rod("thigh_axle", (-0.29, yt, 0.75), (0.29, yt, 0.75), 0.013, "chrome", 16),
          box("thigh_tee", (0.07, 0.05, 0.05), (0, yt + 0.01, 0.75), "frame_dark", 0.008, 2)]
    for s in (-1, 1):
        sp.append(shade(lathe(f"thigh_roll{s}", [(0, -0.10), (0.05, -0.10), (0.062, -0.09), (0.065, -0.06), (0.065, 0.06),
                                                (0.062, 0.09), (0.05, 0.10), (0, 0.10)], "upholstery",
                              (s * 0.155, yt, 0.75), (1, 0, 0), 24)))
        sp.append(disc(f"thigh_cap{s}", (s * 0.29, yt, 0.75), (1, 0, 0), 0.02, 0.012, "rubber", 16))
    merge(sp, "lp_seat_mesh", seat)
    merge(static, "lat_pulldown_frame", root)
    anim = Anim()
    travel, ratio = 0.75, 1.0
    lift_anims(anim, root, [st], 5, travel, pulleys, segs, outs, handles, ratio)
    root["travel_m"], root["ratio"], root["kg_per_plate"] = travel, ratio, 5
    parts = dict(stack=st, segs=segs, pulleys=[(pa, RA), (pb, RB)], out=(co, l0), handle=(g, a), seat=seat,
                 exit=Vector(exitp), ratio=ratio)
    return root, anim, parts


SR_PULLEY_Z = 0.85           # low pulley centre: the cable leaves at 0.80 m (the figure's)


def seated_row():
    root = empty("seated_row")
    static, pulleys, segs, outs, handles = [], [], [], [], []
    cx, cy, top_z, rod_top = 0.0, 1.05, 1.80, 1.62
    RA = RB = RC = 0.05
    zA = 1.70
    tg = "sr_stack"
    stack_tower(tg, cx, cy, top_z, root, static, rod_top, feet=(0.25, 0.25))
    st = weight_stack(tg, cx, cy, 20, 5, root, static, rod_top=rod_top)
    yfront = 0.80
    a_c, b_c, c_c = (cy - RA, zA), (yfront, zA), (0.70, SR_PULLEY_Z)
    # arm to the front, cable column, pulleys
    static.append(span("top_arm", (0, cy, top_z + 0.03), (0, yfront - 0.04, top_z + 0.03), 0.07, 0.06, "frame"))
    static.append(span("cable_col", (0, yfront + 0.025, 0.06), (0, yfront + 0.025, top_z), 0.06, 0.05, "frame"))
    static.append(span("col_base", (-0.205, yfront + 0.025, 0.03), (0.205, yfront + 0.025, 0.03), 0.07, 0.05, "frame"))
    for s in (-1, 1):
        static.append(span(f"col_link{s}", (s * 0.205, yfront + 0.025, 0.03), (s * 0.205, cy - 0.25, 0.03), 0.07, 0.05, "frame"))
    pa = pulley("sr_pulley_A", 0, a_c, RA, static, root)
    pb = pulley("sr_pulley_B", 0, b_c, RB, static, root)
    pc = pulley("sr_pulley_C", 0, c_c, RC, static, root)
    static.append(box("hangA", (0.05, 0.02, top_z - zA), (0, a_c[0], (top_z + zA) / 2), "frame_dark", 0.003, 2))
    static.append(box("hangB", (0.05, 0.03, top_z - zA), (0, b_c[0], (top_z + zA) / 2), "frame_dark", 0.003, 2))
    for s in (-1, 1):
        static.append(box(f"Cbr{s}", (0.006, 0.13, 0.08), (s * 0.026, 0.74, c_c[1] + 0.01), "frame_dark", 0.01, 3))
    pulleys += [(pa, RA, -1), (pb, RB, -1), (pc, RC, -1)]
    L0 = a_c[1] - st["attach"]
    segs.append((cable_segment("sr_stack_seg", (0, cy, a_c[1]), L0, root), L0))
    static.append(cable_line("cable_main", arc_pts(a_c, RA, 0, 90) + arc_pts(b_c, RB, 90, 180) +
                             arc_pts(c_c, RC, 0, -90), 0))
    exitp = (0, c_c[0], c_c[1] - RC)
    l0 = 0.40
    co = cable_segment("sr_cable_out", exitp, l0, root, axis=(0, -1, 0))
    outs.append((co, l0))
    g, a, q, sr_atts = handle_assembly("sr_handle", (0, c_c[0] - l0, c_c[1] - RC), (0, -1, 0),
                                       {"v_bar": att_v_bar, "row_bar": att_row_bar}, root, shown="v_bar")
    handles.append((g, a, q, (0, -1, 0)))
    # footplate, tilted back 18°, on a post from the floor beam
    yfp = 0.17                       # foot plate (the figure's feet), bench below
    fpe = empty("fp_pivot", (0, yfp, 0.27))
    fpe.rotation_euler = (-math.radians(18), 0, 0)
    fp = [box("footplate", (0.46, 0.012, 0.36), (0, 0, 0), "frame_dark", 0.006, 2, fpe)]
    for s in (-1, 1):
        fp.append(box(f"footpad{s}", (0.17, 0.006, 0.30), (s * 0.12, -0.008, 0), "rubber", 0.004, 2, fpe))
        for k in range(8):
            fp.append(box(f"footrib{s}{k}", (0.15, 0.004, 0.007), (s * 0.12, -0.012, (k - 3.5) * 0.036), "rubber",
                          0.0015, 1, fpe))
        fp.append(box(f"fp_lip{s}", (0.012, 0.045, 0.36), (s * 0.236, -0.012, 0), "frame_dark", 0.004, 2, fpe))
    fp.append(box("fp_heel", (0.46, 0.05, 0.02), (0, -0.02, -0.17), "frame_dark", 0.004, 2, fpe))
    static += fp
    static.append(span("fp_post", (0, yfp + 0.08, 0.06), (0, yfp + 0.08, 0.36), 0.06, 0.06, "frame"))
    static.append(span("fp_arm", (0, yfp + 0.08, 0.30), (0, yfp + 0.02, 0.30), 0.05, 0.04, "frame"))
    # floor beam (static); bench on its own node (origin: top centre of the pad)
    yb_ = -0.72                      # bench pad centre
    static.append(span("floor_beam", (0, yfront, 0.035), (0, yb_ - 0.58, 0.035), 0.08, 0.06, "frame"))
    static.append(span("front_stab", (-0.30, yb_ - 0.53, 0.03), (0.30, yb_ - 0.53, 0.03), 0.07, 0.05, "frame"))
    for s in (-1, 1):
        static.append(box(f"stab_foot{s}", (0.08, 0.08, 0.012), (s * 0.26, yb_ - 0.53, 0.0), "rubber", 0.003, 2))
        static.append(box(f"stab_cap{s}", (0.006, 0.072, 0.052), (s * 0.303, yb_ - 0.53, 0.03), "rubber", 0.002, 1))
    pad_top = 0.37
    bench = empty("sr_bench", (0, yb_, pad_top), root)
    bp = []
    for y in (yb_ - 0.33, yb_ + 0.34):
        bp.append(span(f"bench_leg{y}", (0, y, 0.066), (0, y, 0.24), 0.07, 0.07, "frame"))
        bp += bolt(f"bench_bolt{y}", (0.035, y, 0.10), (1, 0, 0))
        bp.append(box(f"bench_shoe{y}", (0.09, 0.09, 0.012), (0, y, 0.071), "frame_dark", 0.003, 2))
    bp.append(span("bench_beam", (0, yb_ - 0.43, 0.26), (0, yb_ + 0.44, 0.26), 0.08, 0.05, "frame"))
    bp.append(box("bench_base", (0.28, 0.86, 0.015), (0, yb_, 0.292), "frame_dark", 0.004, 2))
    bp.append(box("bench_pad", (0.30, 0.90, 0.07), (0, yb_, 0.335), "upholstery", 0.028, 4))
    bp.append(box("bench_seam", (0.302, 0.902, 0.004), (0, yb_, 0.325), "rubber", 0.012, 2))
    merge(bp, "sr_bench_mesh", bench)
    merge(static, "seated_row_frame", root)
    bpy.data.objects.remove(fpe)
    anim = Anim()
    travel, ratio = 0.75, 1.0
    lift_anims(anim, root, [st], 5, travel, pulleys, segs, outs, handles, ratio)
    root["travel_m"], root["ratio"], root["kg_per_plate"] = travel, ratio, 5
    parts = dict(stack=st, segs=segs, pulleys=[(pa, RA), (pb, RB), (pc, RC)], out=(co, l0), handle=(g, a),
                 atts=sr_atts, bench=bench, exit=Vector(exitp), ratio=ratio)
    return root, anim, parts


def attachment(name):
    root = empty(f"attachment_{name}")
    merge(ATTACHMENTS[name](name, root), f"attachment_{name}_mesh", root)
    return root, None, None


def tracker_model():
    root = empty("gympath_tracker")
    merge(tracker("tracker", (0, 0, 0), root), "gympath_tracker_mesh", root)
    return root, None, None


# --------------------------------------------------------------------------
# Export and preview
# --------------------------------------------------------------------------

def export(path_, keep_constant=False):
    bpy.context.view_layer.update()
    lc = bpy.context.view_layer.layer_collection.children["export"]
    bpy.context.view_layer.active_layer_collection = lc
    bpy.context.scene.frame_set(0)
    bpy.ops.export_scene.gltf(filepath=path_, export_format="GLB", use_active_collection=True,
                              export_apply=True, export_animations=True, export_animation_mode="NLA_TRACKS",
                              export_yup=True, export_extras=True, export_cameras=False, export_lights=False,
                              # a constant channel still matters when it differs from rest (a
                              # machine shown in one clip only), so keep them when asked
                              export_optimize_animation_size=not keep_constant,
                              export_optimize_animation_keep_anim_object=keep_constant)


def tri_count():
    n = 0
    for ob in COLL.all_objects:
        if ob.type == "MESH":
            n += sum(len(p.vertices) - 2 for p in ob.data.polygons)
    return n


def render(path_, views, size=(1100, 1100)):
    import addon_utils
    addon_utils.enable("cycles", default_set=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = int(os.environ.get("SAMPLES", 48))
    sc.cycles.use_denoising = True
    sc.render.resolution_x, sc.render.resolution_y = size
    sc.render.film_transparent = False
    world = bpy.data.worlds.new("w")
    sc.world = world
    try:
        world.use_nodes = True
    except Exception:
        pass
    bg = world.node_tree.nodes.get("Background") or world.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.045, 0.06, 0.07, 1)
    bg.inputs[1].default_value = 1.0
    aux = bpy.data.collections.new("aux")
    sc.collection.children.link(aux)
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=6)
    me = bpy.data.meshes.new("floor")
    bm.to_mesh(me)
    floor = bpy.data.objects.new("floor", me)
    fm = bpy.data.materials.new("floor")
    try:
        fm.use_nodes = True
    except Exception:
        pass
    fm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.07, 0.08, 0.09, 1)
    fm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.7
    me.materials.append(fm)
    aux.objects.link(floor)
    for nm, loc, energy, sz in (("key", (-2.5, -3.5, 4.0), 900, 3), ("fill", (3.5, -2.0, 2.5), 350, 3),
                                ("rim", (0.5, 3.5, 3.5), 500, 2.5)):
        ld = bpy.data.lights.new(nm, "AREA")
        ld.energy, ld.size = energy, sz
        lo = bpy.data.objects.new(nm, ld)
        lo.location = loc
        lo.rotation_mode = "QUATERNION"
        lo.rotation_quaternion = (Vector((0, 0, 0.8)) - Vector(loc)).to_track_quat("-Z", "Y")
        aux.objects.link(lo)
    cd = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cd)
    aux.objects.link(cam)
    sc.camera = cam
    outs = []
    for k, (loc, target, lens) in enumerate(views):
        cd.lens = lens
        cam.location = loc
        cam.rotation_mode = "QUATERNION"
        cam.rotation_quaternion = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y")
        sc.render.filepath = f"{path_}_{k}.png"
        bpy.ops.render.render(write_still=True)
        outs.append(sc.render.filepath)
    return outs


VIEWS = {
    "functional_trainer": [((-3.3, -4.9, 2.0), (0, 0.0, 1.05), 38), ((1.42, -0.95, 1.45), (0.98, 0.0, 1.05), 40),
                           ((1.12, -0.55, 0.95), (0.98, 0.15, 0.55), 35)],
    "lat_pulldown": [((-2.9, -3.0, 1.9), (0, 0.0, 1.05), 38), ((0.6, -0.9, 2.3), (0, 0.1, 1.9), 35)],
    "seated_row": [((-3.4, -2.8, 1.8), (0, -0.1, 0.7), 38), ((1.0, -0.1, 1.0), (0, 0.55, 0.6), 35)],
    "attachments": [((0.0, -4.2, 0.9), (0.0, 0, 0.42), 36)],
    "tracker": [((0.06, -0.14, 0.07), (0, -0.006, 0.03), 60), ((0.10, 0.08, 0.0), (0, 0, 0.026), 60)],
}


def main():
    os.makedirs(OUT, exist_ok=True)
    report = []
    only = os.environ.get("ONLY")
    for name, fn in (("functional_trainer", functional_trainer), ("lat_pulldown", lat_pulldown),
                     ("seated_row", seated_row)):
        if only and only != name:
            continue
        reset()
        root, anim, _ = fn()
        if anim:
            anim.bake()
        tris = tri_count()
        if PREVIEW:
            os.makedirs(PREVIEW, exist_ok=True)
            render(os.path.join(PREVIEW, name), VIEWS[name])
        export(os.path.join(OUT, f"cable_{name}.glb"))
        report.append((name, tris))
    for name in ATTACHMENTS if not only or only == "attachments" else ():
        reset()
        attachment(name)
        report.append((f"attachment_{name}", tri_count()))
        export(os.path.join(OUT, f"cable_attachment_{name}.glb"))
    if PREVIEW and (not only or only == "attachments"):      # all attachments side by side
        reset()
        x = -1.45
        for name, w in zip(ATTACHMENTS, (0.16, 0.52, 1.22, 0.14, 0.16, 0.14)):
            r, _, _ = attachment(name)
            r.location = (x + w / 2, 0, 0.62)
            x += w + 0.16
        render(os.path.join(PREVIEW, "attachments"), VIEWS["attachments"], (1600, 700))
    if not only or only == "tracker":
        reset()
        troot, _, _ = tracker_model()
        report.append(("tracker", tri_count()))
        export(os.path.join(OUT, "cable_tracker.glb"))
        if PREVIEW:
            troot.location.z = 0.03
            render(os.path.join(PREVIEW, "tracker"), VIEWS["tracker"], (900, 900))
    for name, tris in report:
        print(f"{name:32s} {tris:7d} triangles")


if __name__ == "__main__":
    main()
