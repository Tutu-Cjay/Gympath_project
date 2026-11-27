"""Render the figure with its machine at chosen moments of its clips (a check).

    python tools/check_figure.py fig/anatomy_male.glb prev/fig "LatPulldown:0,54" "FacePull:0,54" ...
"""
import math
import sys

import bpy
from mathutils import Vector

glb, out = sys.argv[1], sys.argv[2]
jobs = [(a.split(":")[0], [int(x) for x in a.split(":")[1].split(",")]) for a in sys.argv[3:]]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
sc = bpy.context.scene
sc.render.fps = 30
import addon_utils  # noqa: E402
addon_utils.enable("cycles", default_set=True)
sc.render.engine = "CYCLES"
sc.cycles.samples = 24
sc.cycles.use_denoising = True
sc.render.resolution_x = sc.render.resolution_y = 640
w = bpy.data.worlds.new("w")
sc.world = w
w.node_tree.nodes["Background"].inputs[0].default_value = (0.35, 0.4, 0.45, 1)
for nm, rot, e in (("key", (0.8, 0.2, -0.7), 3.5), ("fill", (1.1, -0.3, 2.4), 1.2)):
    ld = bpy.data.lights.new(nm, "SUN")
    ld.energy = e
    lo = bpy.data.objects.new(nm, ld)
    lo.rotation_euler = rot
    sc.collection.objects.link(lo)
cd = bpy.data.cameras.new("c")
cd.lens = 30
cam = bpy.data.objects.new("c", cd)
sc.collection.objects.link(cam)
sc.camera = cam
VIEW = {} if False else {
    "LatPulldown": ((-2.4, -2.8, 1.9), (0, -0.4, 1.15)),
    "SeatedCableRow": ((-3.0, -1.6, 1.5), (0, -0.8, 0.7)),
    "TricepPushdown": ((-2.6, -2.6, 1.7), (0, -0.5, 1.1)),
    "CableBicepCurl": ((-2.6, -2.6, 1.6), (0, -0.5, 1.0)),
    "CableChestFly": ((-2.2, -3.6, 1.8), (0, 0, 1.15)),
    "FacePull": ((-3.0, -2.6, 1.8), (0, -0.7, 1.2)),
}
for clip, frames in jobs:
    n = 0
    for ob in bpy.data.objects:
        if ob.animation_data:
            ob.animation_data.action = None
            for tr in ob.animation_data.nla_tracks:
                tr.mute = True
    act = bpy.data.actions[clip]
    for slot in act.slots:
        ob = bpy.data.objects.get(slot.identifier[2:])
        if ob is None:
            continue
        ad = ob.animation_data or ob.animation_data_create()
        ad.action = act
        ad.action_slot = slot
        n += 1
    print(clip, "animated objects:", n)
    import os
    alt = os.environ.get("VIEW")
    loc, tgt = (tuple(map(float, alt.split("|")[0].split(","))), tuple(map(float, alt.split("|")[1].split(",")))) \
        if alt else VIEW[clip.split("@")[0]]
    cam.location = loc
    cam.rotation_mode = "QUATERNION"
    cam.rotation_quaternion = (Vector(tgt) - Vector(loc)).to_track_quat("-Z", "Y")
    for f in frames:
        sc.frame_set(f)
        sc.render.filepath = f"{out}_{clip}_{f}.png"
        bpy.ops.render.render(write_still=True)
