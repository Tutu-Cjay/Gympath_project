"""How far each hand's grip is from the handle it holds, per clip (a check).

    python tools/check_grips.py fig/anatomy_male.glb
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gltf_io as G  # noqa: E402

j, b = G.read_glb(sys.argv[1])
N = {nd.get("name"): i for i, nd in enumerate(j["nodes"])}
P = G.parents(j)
A = {a["name"]: a for a in j["animations"]}
tr = G.node_tracks(j, b, A["CableChestFly"])
# grip in hand space, from the chest fly D-handles (grip centre: 0.19 below the ring)
GL = {}
for s, side in (("l", "R"), ("r", "L")):
    hw = G.node_world(j, tr, N[f"hand_{s}"], 1.0, P)
    aw = G.node_world(j, tr, N[f"ft_{side}_handle_att_d_handle"], 1.0, P)
    GL[s] = (np.linalg.inv(hw) @ aw @ np.array([0, -0.19, 0, 1]))[:3]
LINE = {"LatPulldown": ("lp_handle_attach", "lat"), "SeatedCableRow": ("sr_handle_att_v_bar", "v"),
        "TricepPushdown": ("ft_R_handle_att_pushdown_bar", "bar"), "CableBicepCurl": ("ft_R_handle_att_curl_bar", "bar")}
import build_cable_machines as B  # noqa: E402
for clip in A:
    ex = clip.split("@")[0]
    tr = G.node_tracks(j, b, A[clip])
    errs, slide = [], []
    for t in np.linspace(0, 4, 41):
        g = {s: (G.node_world(j, tr, N[f"hand_{s}"], t, P) @ np.r_[GL[s], 1])[:3] for s in "lr"}
        if ex in LINE:
            node, kind = LINE[ex]
            aw = G.node_world(j, tr, N[node], t, P)
            for s in "lr":
                loc = (np.linalg.inv(aw) @ np.r_[g[s], 1])[:3]        # glTF local: x along the bar
                if kind == "v":                                        # V-bar grips: x ±0.068, 0.235 down
                    errs.append(np.hypot(abs(loc[0]) - 0.068, loc[1] + 0.235) + max(0.0, abs(loc[2]) - 0.05))
                    slide.append(loc[2])
                    continue
                want_y = -0.09 - (B.lat_drop(loc[0]) if kind == "lat" else 0.0)
                errs.append(np.hypot(loc[1] - want_y, loc[2]))
                slide.append(loc[0])
        elif ex == "FacePull":
            for s in "lr":
                st = G.node_world(j, tr, N[f"ft_R_rope_strand_{s}"], t, P)
                L = np.linalg.norm(st[:3, :3] @ np.array([0, 0, 1.0]))
                end = st[:3, 3] + st[:3, :3] @ np.array([0, -B.ROPE_STRAND, 0])
                errs.append(np.linalg.norm(end - g[s]))
                slide.append(L)
        elif ex == "CableChestFly":
            for s, side in (("l", "R"), ("r", "L")):
                aw = G.node_world(j, tr, N[f"ft_{side}_handle_att_d_handle"], t, P)
                errs.append(np.linalg.norm((aw @ np.array([0, -0.19, 0, 1]))[:3] - g[s]))
    sl = np.array(slide).reshape(-1, 2) if slide else None
    extra = ""
    if sl is not None and ex == "SeatedCableRow":
        extra = f", along the grips {sl[:, 0].min() * 1000:+.0f}..{sl[:, 0].max() * 1000:+.0f} mm"
    elif sl is not None and ex in LINE:
        extra = f", grip along bar {sl[:, 0].min():+.3f}..{sl[:, 0].max():+.3f} m (slides {np.ptp(sl[:, 0]) * 1000:.1f} mm)"
    if ex == "FacePull":
        extra = f", strand scale {sl.min():.4f}..{sl.max():.4f}"
    print(f"{clip:20s} hand off the handle: max {max(errs) * 1000:5.1f} mm{extra}")
