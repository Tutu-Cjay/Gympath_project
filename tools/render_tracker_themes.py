"""Pictures of the tracker's rep screen for the app's preview.

Renders every theme × number style as the firmware's live preview draws it
(drawRepPage: sample count 12, a lift in progress; same fonts, positions and
colours as Gympath_Track.ino), plus where the count sits on each theme (the
window the count slides in, firmware countWindow):

    python tools/render_tracker_themes.py
      -> mobile/assets/tracker/page_<theme>_<style>.png
      -> mobile/lib/screens/tracker_preview_data.dart
"""
import io
import contextlib
import math
import os
import sys

from PIL import Image, ImageDraw

sys.argv = sys.argv[:1]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
with contextlib.redirect_stdout(io.StringIO()):
    import check_tracker_layout as L   # fonts + renderer  # noqa: E402

OUT = os.path.join(ROOT, "mobile", "assets", "tracker")
DART = os.path.join(ROOT, "mobile", "lib", "screens", "tracker_preview_data.dart")
WHITE = (255, 255, 255)
GREEN, MUTED, TRACK = (0, 255, 136), (98, 145, 205), (8, 44, 65)
SPEED = (0, 255, 0)            # Classic ring at mid speed (0x07E0)
THEMES, STYLES = 4, 4
SAMPLE = "12"
SS = 4                         # supersampling for arcs and rounded segments
SEG = [(1, 1, 1, 1, 1, 1, 0), (0, 1, 1, 0, 0, 0, 0), (1, 1, 0, 1, 1, 0, 1), (1, 1, 1, 1, 0, 0, 1),
       (0, 1, 1, 0, 0, 1, 1), (1, 0, 1, 1, 0, 1, 1), (1, 0, 1, 1, 1, 1, 1), (1, 1, 1, 0, 0, 0, 0),
       (1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 0, 1, 1)]


def count_place(th):
    """(cy, large) of the count on theme th."""
    return {0: (120, True), 1: (112, False), 2: (118, False), 3: (120, True)}[th]


def seg_rects(x, y, s):
    w, h, vv = 6 * s, s, 7 * s
    return [(x + h, y, w, h), (x + w + h, y + h, h, vv), (x + w + h, y + vv + 2 * h, h, vv),
            (x + h, y + 2 * vv + 2 * h, w, h), (x, y + vv + 2 * h, h, vv), (x, y + h, h, vv),
            (x + h, y + vv + h, w, h)]


def seg_box(txt, s, cx, cy):
    """segBox: (x, y, w, h) of the digit cells."""
    w = len(txt) * 8 * s + (len(txt) - 1) * 2 * s
    h = 17 * s
    return cx - w // 2, cy - h // 2, w, h


def draw_segments(img, txt, s, cx, cy, color, rounded):
    x, y, _, _ = seg_box(txt, s, cx, cy)
    mask = Image.new("L", (240 * SS, 240 * SS), 0)
    d = ImageDraw.Draw(mask)
    for ch in txt:
        for k, (rx, ry, rw, rh) in enumerate(seg_rects(x, y, s)):
            if not SEG[int(ch)][k]:
                continue
            if rounded:
                if k in (0, 3, 6): rx += 1; rw -= 2
                else: ry += 1; rh -= 2
                d.rounded_rectangle([rx * SS, ry * SS, (rx + rw) * SS - 1, (ry + rh) * SS - 1],
                                    radius=(s // 2) * SS, fill=255)
            else:
                d.rectangle([rx * SS, ry * SS, (rx + rw) * SS - 1, (ry + rh) * SS - 1], fill=255)
        x += 10 * s
    img.paste(Image.new("RGB", (240, 240), color), (0, 0),
              mask.resize((240, 240), Image.LANCZOS if rounded else Image.BOX))


def draw_count(img, th, style, color):
    cy, large = count_place(th)
    kind, what, _ = L.count_layout(style, SAMPLE, large, cy)
    if kind == "seg":
        s, cx = what
        draw_segments(img, SAMPLE, s, cx, cy, color, style == 1)
    else:
        name, cx = what
        L.V.render(img, L.F[name], SAMPLE, cx, cy, color)


def count_window(th):
    """countWindow: union of the count's boxes in every style, 1 px margin."""
    cy, large = count_place(th)
    x0 = y0 = 240
    x1 = y1 = 0
    for st in range(STYLES):
        kind, what, box = L.count_layout(st, SAMPLE, large, cy)
        if kind == "seg":
            x, y, w, h = seg_box(SAMPLE, what[0], what[1], cy)
            box = (x, y, x + w, y + h)
        x0, y0 = min(x0, box[0]), min(y0, box[1])
        x1, y1 = max(x1, box[2]), max(y1, box[3])
    wx, wy = max(0, x0 - 1), max(0, y0 - 1)
    return wx, wy, min(240, x1 + 1) - wx, min(240, y1 + 1) - wy


def arcs(th):
    """The theme's rings, supersampled (TFT_eSPI angles: 0 = bottom, clockwise)."""
    big = Image.new("RGB", (240 * SS, 240 * SS), (0, 0, 0))
    d = ImageDraw.Draw(big)

    def arc(r, ir, a0, a1, col):
        d.arc([(120 - r) * SS, (120 - r) * SS, (120 + r) * SS, (120 + r) * SS],
              a0 + 90, a1 + 90, fill=col, width=(r - ir) * SS)

    if th == 0:
        arc(119, 105, 0, 360, SPEED)
    elif th == 1:
        end = 40 + int(280 * 0.62)
        end -= (end - 40) % 2
        arc(118, 104, 40, 320, TRACK)
        arc(118, 104, 40, end, GREEN)
    elif th == 2:
        arc(118, 112, 0, 360, GREEN)          # lifting: the ring is green
    elif th == 3:
        for i in range(12):                   # a dot per rep, 12° apart
            a = math.radians(i * 12)
            x, y = 120 + round(108 * math.sin(a)), 120 - round(108 * math.cos(a))
            d.ellipse([(x - 4) * SS, (y - 4) * SS, (x + 4) * SS, (y + 4) * SS], fill=GREEN)
    return big.resize((240, 240), Image.LANCZOS)


def page(th, style):
    img = arcs(th)
    F = L.F
    if th == 1:
        L.V.render(img, F["FONT_SMALL"], "reps", 120, 150, MUTED)
    elif th == 2:
        L.V.render(img, F["FONT_MED"], "LIFT", 120, 62, GREEN)
        L.V.render(img, F["FONT_SMALL"], "up 1.2s  down 2.4s", 120, 166, WHITE)
        L.V.render(img, F["FONT_TINY"], "last rep", 120, 186, MUTED)
    draw_count(img, th, style, SPEED if th == 0 else WHITE)
    mask = Image.new("L", (240, 240), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, 239, 239], fill=255)
    out = Image.new("RGBA", (240, 240), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):                # earlier per-theme / per-style pictures
        if old.startswith(("theme_", "digits_")):
            os.remove(os.path.join(OUT, old))
    for th in range(THEMES):
        for st in range(STYLES):
            page(th, st).save(os.path.join(OUT, f"page_{th}_{st}.png"), optimize=True)
    wins = [count_window(th) for th in range(THEMES)]
    with open(DART, "w") as f:
        f.write("// Generated by tools/render_tracker_themes.py — do not edit.\n")
        f.write("//\n// Where the rep count sits on each theme of the tracker screen (240 x 240\n")
        f.write("// px): the window the count slides in when the number style changes\n")
        f.write("// (firmware countWindow). Index = theme.\n")
        f.write("const List<List<int>> trackerCountWindows = [\n")
        for th, (x, y, w, h) in enumerate(wins):
            f.write(f"  [{x}, {y}, {w}, {h}], // theme {th}\n")
        f.write("];\n")
    print("wrote", OUT, "and", DART, wins)


if __name__ == "__main__":
    main()
