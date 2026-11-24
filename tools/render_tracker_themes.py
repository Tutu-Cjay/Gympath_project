"""Pictures of the tracker's rep screen themes for the app's theme picker.

Draws each theme the way the firmware does (same fonts, positions and
colours; see themeFresh / themeStroke / themeTempo / themeMinimal and the
Classic 7-segment screen in Gympath_Track.ino) mid-set:

    python tools/render_tracker_themes.py   -> mobile/assets/tracker/theme_<n>.png
                                               mobile/assets/tracker/digits_<n>.png

digits_<n>.png: the rep count in each number style (firmware drawCount).
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


def seven_seg_round(n, color, s=6, cy=120, scale=4, cx=120):
    """Rounded segments, anti-aliased (fillSmoothRoundRect): drawn large and
    scaled down. Returns an RGBA layer."""
    seg = [(1, 1, 1, 1, 1, 1, 0), (0, 1, 1, 0, 0, 0, 0), (1, 1, 0, 1, 1, 0, 1), (1, 1, 1, 1, 0, 0, 1),
           (0, 1, 1, 0, 0, 1, 1), (1, 0, 1, 1, 0, 1, 1), (1, 0, 1, 1, 1, 1, 1), (1, 1, 1, 0, 0, 0, 0),
           (1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 0, 1, 1)]
    w, h, vv = 6 * s, s, 7 * s
    txt = str(n); dw, sp = 8 * s, 2 * s
    W = len(txt) * dw + (len(txt) - 1) * sp; H = 17 * s
    x, y = cx - W // 2, cy - H // 2
    big = Image.new("L", (240 * scale, 240 * scale), 0)
    d = ImageDraw.Draw(big)
    for ch in txt:
        on = seg[int(ch)]
        rects = [(x + h, y, w, h), (x + w + h, y + h, h, vv), (x + w + h, y + vv + 2 * h, h, vv),
                 (x + h, y + 2 * vv + 2 * h, w, h), (x, y + vv + 2 * h, h, vv), (x, y + h, h, vv),
                 (x + h, y + vv + h, w, h)]
        for k, (rx, ry, rw, rh) in enumerate(rects):
            if not on[k]:
                continue
            if k in (0, 3, 6): rx += 1; rw -= 2
            else: ry += 1; rh -= 2
            d.rounded_rectangle([rx * scale, ry * scale, (rx + rw) * scale - 1, (ry + rh) * scale - 1],
                                radius=(s // 2) * scale, fill=255)
        x += dw + sp
    mask = big.resize((240, 240), Image.LANCZOS)
    layer = Image.new("RGB", (240, 240), color)
    return layer, mask


def seven_seg(img, n, color, cx=120):
    seg = [(1, 1, 1, 1, 1, 1, 0), (0, 1, 1, 0, 0, 0, 0), (1, 1, 0, 1, 1, 0, 1), (1, 1, 1, 1, 0, 0, 1),
           (0, 1, 1, 0, 0, 1, 1), (1, 0, 1, 1, 0, 1, 1), (1, 0, 1, 1, 1, 1, 1), (1, 1, 1, 0, 0, 0, 0),
           (1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 0, 1, 1)]
    s = 6; w, h, vv = 6 * s, s, 7 * s
    txt = str(n); dw, sp = 8 * s, 2 * s
    W = len(txt) * dw + (len(txt) - 1) * sp; H = 17 * s
    x, y = cx - W // 2, 120 - H // 2
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
    # number styles: the count "128" as Classic / Minimal show it
    for i in range(4):
        img = base().resize((240, 240))
        kind, (what, cx), _ = L.count_layout(i, "128", True, 120)   # as drawCount centres it
        if i == 0:
            seven_seg(img, 128, (255, 255, 255), cx)
        elif i == 1:
            layer, mask = seven_seg_round(128, (255, 255, 255), cx=cx)
            img.paste(layer, (0, 0), mask)
        else:
            L.V.render(img, F[what], "128", cx, 120, (255, 255, 255))
        m = Image.new("L", (240, 240), 0)
        ImageDraw.Draw(m).ellipse([0, 0, 239, 239], fill=255)
        out = Image.new("RGBA", (240, 240), (0, 0, 0, 0))
        out.paste(img, (0, 0), m)
        out.save(os.path.join(OUT, f"digits_{i}.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
