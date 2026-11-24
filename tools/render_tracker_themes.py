"""Pictures of the tracker's rep screen themes for the app's theme picker.

Draws each theme the way the firmware does (same fonts, positions and
colours; see themeFresh / themeStroke / themeTempo / themeMinimal and the
Classic 7-segment screen in Gympath_Track.ino) mid-set:

    python tools/render_tracker_themes.py   -> mobile/assets/tracker/theme_<n>.png
"""
import math
import os
import sys

from PIL import Image, ImageDraw

sys.argv = sys.argv[:1]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import io, contextlib  # noqa: E402
with contextlib.redirect_stdout(io.StringIO()):
    import check_tracker_layout as L   # fonts + renderer  # noqa: E402

OUT = os.path.join(ROOT, "mobile", "assets", "tracker")
GREEN, BLUE, MUTED, MUTED_G, TRACK = (0, 255, 136), (56, 176, 248), (98, 145, 205), (106, 178, 139), (8, 44, 65)
S = 2   # supersampling for the arcs


def base():
    return Image.new("RGB", (240 * S, 240 * S), (0, 0, 0))


def arc(img, r, ir, a0, a1, col):
    """TFT_eSPI angles: 0 = bottom, clockwise."""
    d = ImageDraw.Draw(img)
    d.arc([(120 - r) * S, (120 - r) * S, (120 + r) * S, (120 + r) * S], a0 + 90, a1 + 90,
          fill=col, width=(r - ir) * S)


def finish(img, text_fn, path):
    img = img.resize((240, 240), Image.LANCZOS)
    text_fn(img)
    mask = Image.new("L", (240, 240), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, 239, 239], fill=255)
    out = Image.new("RGBA", (240, 240), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    out.save(path)


def seven_seg(img, n, color):
    seg = [(1, 1, 1, 1, 1, 1, 0), (0, 1, 1, 0, 0, 0, 0), (1, 1, 0, 1, 1, 0, 1), (1, 1, 1, 1, 0, 0, 1),
           (0, 1, 1, 0, 0, 1, 1), (1, 0, 1, 1, 0, 1, 1), (1, 0, 1, 1, 1, 1, 1), (1, 1, 1, 0, 0, 0, 0),
           (1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 0, 1, 1)]
    s = 6; w, h, vv = 6 * s, s, 7 * s
    txt = str(n); dw, sp = 8 * s, 2 * s
    W = len(txt) * dw + (len(txt) - 1) * sp; H = 17 * s
    x, y = 120 - W // 2, 120 - H // 2
    d = ImageDraw.Draw(img)
    for ch in txt:
        on = seg[int(ch)]
        rects = [(x + h, y, w, h), (x + w + h, y + h, h, vv), (x + w + h, y + vv + 2 * h, h, vv),
                 (x + h, y + 2 * vv + 2 * h, w, h), (x, y + vv + 2 * h, h, vv), (x, y + h, h, vv),
                 (x + h, y + vv + h, w, h)]
        for k, (rx, ry, rw, rh) in enumerate(rects):
            if on[k]:
                d.rectangle([rx, ry, rx + rw - 1, ry + rh - 1], fill=color)
        x += dw + sp


def main():
    os.makedirs(OUT, exist_ok=True)
    F = L.F
    # 0 Classic: speed ring (mid speed = green), 7-segment count
    img = base(); arc(img, 119, 105, 0, 360, (0, 200, 60))
    finish(img, lambda im: seven_seg(im, 7, (0, 200, 60)), os.path.join(OUT, "theme_0.png"))
    # 1 Stroke: ring filled 70 % while lifting
    img = base(); arc(img, 118, 104, 40, 320, TRACK); arc(img, 118, 104, 40, 40 + int(280 * 0.7), GREEN)
    def t1(im):
        L.V.render(im, F["FONT_BIG"], "7", 120, 112, (255, 255, 255))
        L.V.render(im, F["FONT_SMALL"], "reps", 120, 150, MUTED)
    finish(img, t1, os.path.join(OUT, "theme_1.png"))
    # 2 Tempo: lowering
    img = base(); arc(img, 118, 112, 0, 360, BLUE)
    def t2(im):
        L.V.render(im, F["FONT_MED"], "LOWER", 120, 62, BLUE)
        L.V.render(im, F["FONT_BIG"], "7", 120, 118, (255, 255, 255))
        L.V.render(im, F["FONT_SMALL"], "up 1.2s  down 2.4s", 120, 166, (255, 255, 255))
        L.V.render(im, F["FONT_TINY"], "last rep", 120, 186, MUTED)
    finish(img, t2, os.path.join(OUT, "theme_2.png"))
    # 3 Minimal: 7 dots
    img = base(); d = ImageDraw.Draw(img)
    for i in range(7):
        a = math.radians(i * 12)
        x, y = 120 + 108 * math.sin(a), 120 - 108 * math.cos(a)
        d.ellipse([(x - 4) * S, (y - 4) * S, (x + 4) * S, (y + 4) * S], fill=GREEN)
    finish(img, lambda im: L.V.render(im, F["FONT_BIG"], "7", 120, 120, (255, 255, 255)),
           os.path.join(OUT, "theme_3.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
