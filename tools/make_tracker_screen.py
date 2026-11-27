"""Draw the tracker's screen (the Gympath logo on its round display) as a
texture for the 3D tracker: tools/tracker_screen.png.

    python tools/make_tracker_screen.py mobile/assets/logo.png tools/tracker_screen.png
"""
import sys

import numpy as np
from PIL import Image, ImageDraw

src, dst = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(src).convert("RGB")).astype(float)
ys, xs = np.where(a.max(axis=2) > 60)                     # the word mark on black
crop = a[ys.min() - 4:ys.max() + 5, xs.min() - 4:xs.max() + 5]
S, bg = 1024, np.array([6, 8, 10], float)
w = int(S * 0.74)
h = int(crop.shape[0] * w / crop.shape[1])
logo = np.asarray(Image.fromarray(crop.astype(np.uint8)).resize((w, h), Image.LANCZOS)).astype(float)
alpha = np.clip((logo.max(axis=2) - 30) / 60, 0, 1)[..., None]
out = np.tile(bg, (S, S, 1))
y0, x0 = (S - h) // 2 - 10, (S - w) // 2
out[y0:y0 + h, x0:x0 + w] = out[y0:y0 + h, x0:x0 + w] * (1 - alpha) + logo * alpha
img = Image.fromarray(out.astype(np.uint8))
green = tuple(int(v) for v in a[(a[:, :, 1] > 150) & (a[:, :, 0] < 120)].mean(axis=0))   # the logo's green
ImageDraw.Draw(img).ellipse((26, 26, S - 26, S - 26), outline=green, width=6)
img.save(dst)
