"""Check the tracker screen layout for overlaps (firmware/Gympath_Track).

Uses the real anti-aliased fonts (tracker_fonts.h) and the positions used
in the firmware: every text box, the battery strip, the dots and the link
dot must stay clear of the rings, of each other and of the round panel's
edge. Worst-case strings are used. Keep the numbers in step with the
firmware's updateDashboard() / displayTask().

    python tools/check_tracker_layout.py      # exit code 1 on a problem
"""
import math
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
H = os.path.join(ROOT, "firmware", "Gympath_Track", "tracker_fonts.h")


class V:
    """Reads the generated subpixel fonts (tracker_fonts.h)."""
    ORDER = 1  # as SUBPIXEL_ORDER in the firmware: stripes B, G, R

    @staticmethod
    def load(header, name):
        s = open(header).read()
        m = re.search(r"static const SPGlyph %s_glyphs\[\d+\] = \{(.*?)\};" % name, s, re.S)
        glyphs = [tuple(map(int, t)) for t in re.findall(
            r"\{(-?\d+),(-?\d+),(-?\d+),(-?\d+),(-?\d+),(-?\d+),(-?\d+)\}", m.group(1))]
        d = re.search(r"static const uint8_t %s_data\[\d+\] = \{(.*?)\};" % name, s, re.S)
        data = bytes(int(x) for x in re.findall(r"\d+", d.group(1)))
        asc, desc = map(int, re.search(
            r"static const SPFont %s = \{.*?, (\d+), (\d+)\};" % name, s).groups())
        g = {chr(c): (w, h, dx, dy, adv, off) for c, w, h, dx, dy, adv, off in glyphs}
        return dict(g=g, data=data, asc=asc, desc=desc, H=asc + desc)

    @staticmethod
    def width(f, s):
        return sum(f["g"][ch][4] for ch in s if ch in f["g"])

    @staticmethod
    def render(img, f, s, cx, cy, col, pad=0, centre=True):
        """Like the firmware's drawText (black background)."""
        W = V.width(f, s); H = f["H"]; bw = max(W, pad)
        x0 = cx - bw // 2 if centre else cx
        pen = x0 + ((bw - W) // 2 if centre else 0)
        y0 = cy - H // 2
        for ch in s:
            w, h, dx, dy, adv, off = f["g"][ch]
            for j in range(h):
                for i in range(w):
                    a = f["data"][off + 3 * (j * w + i): off + 3 * (j * w + i) + 3]
                    if not any(a):
                        continue
                    if V.ORDER == 0: aR, aG, aB = a[0], a[1], a[2]
                    elif V.ORDER == 1: aR, aG, aB = a[2], a[1], a[0]
                    else: aR = aG = aB = sum(a) // 3
                    x, y = pen + dx + i, y0 + f["asc"] - dy + j
                    if 0 <= x < 240 and 0 <= y < 240:
                        o = img.getpixel((x, y))
                        img.putpixel((x, y), (max(o[0], col[0] * aR // 255),
                                              max(o[1], col[1] * aG // 255),
                                              max(o[2], col[2] * aB // 255)))
            pen += adv
        return (x0, y0, x0 + bw, y0 + H)


# ---- dashboard ----
F={n:V.load(H,n) for n in ['FONT_TINY','FONT_SMALL','FONT_MED','FONT_BIG']}
# rings (r, ir) and arc span: TFT angles 0 = bottom, clockwise; drawn 40..320
RINGS=[(118,108),(104,98)]
A0,SPAN=40,280
def ring_pixel(x,y):
    dx,dy=x+0.5-120,y+0.5-120; r=math.hypot(dx,dy)
    ang=(math.degrees(math.atan2(-dx,dy)))%360   # 0 at bottom, clockwise
    for ro,ri in RINGS:
        if ri-1<=r<=ro+1 and A0-1<=ang<=A0+SPAN+1: return True
    return False
L=dict(  # element: (font, y, worst-case text)
  link=('dot',30,None),
  battery=('FONT_TINY',44,'100%'),
  top=('FONT_SMALL',66,'last sync: Wed'),
  big=('FONT_BIG',106,'1888'),
  goal=('FONT_SMALL',138,'reps / 120'),
  l1=('FONT_SMALL',157,'88 sets  88.8 t'),
  l2=('FONT_SMALL',176,'muscles 13/13'),
  dots=('dots',196,None),
  l3=('FONT_TINY',215,'7/7 - 99 wk streak'),
)
def boxes():
    out={}
    for k,(f,y,s) in L.items():
        if f=='dot': out[k]=(117,y-4,124,y+4)
        elif f=='dots': out[k]=(120-3*15-8,y-8,120+3*15+8,y+8)
        elif k=='battery':
            w=25+2+5+V.width(F[f],s); x0=120-w//2; out[k]=(x0,y-F[f]['H']//2-1,x0+w+2,y+F[f]['H']//2+1)
        else:
            fo=F[f]; w=V.width(fo,s); out[k]=(120-w//2,y-fo['H']//2,120-w//2+w,y-fo['H']//2+fo['H'])
    return out
B=boxes(); bad=0
for k,(x0,y0,x1,y1) in B.items():
    hits=0; outside=0
    for y in range(y0,y1):
        for x in range(x0,x1):
            if ring_pixel(x,y): hits+=1
            if math.hypot(x+0.5-120,y+0.5-120)>119.5: outside+=1
    if hits or outside: print(f"{k}: ring overlap {hits}px, off-screen {outside}px  box={B[k]}"); bad+=1
ks=list(B)
for i in range(len(ks)):
    for j in range(i+1,len(ks)):
        a,b=B[ks[i]],B[ks[j]]
        if a[0]<b[2] and b[0]<a[2] and a[1]<b[3] and b[1]<a[3]: print("overlap",ks[i],ks[j],a,b); bad+=1

# ---- status screens (ring 105..120 around them) ----
screens={
 'idle(test)':[('FONT_SMALL',40,'USB TEST'),('FONT_MED',110,'READY'),('FONT_SMALL',142,'press Start')],
 'calib':[('FONT_MED',110,'HOLD'),('FONT_SMALL',142,'keep still...')],
 'fail':[('FONT_MED',96,'MOVED'),('FONT_SMALL',126,'retry Start'),('FONT_TINY',154,'a 99.99 sd 9.99'),('FONT_TINY',172,'g 99.9 sd 9.9 dps')],
 'ota':[('FONT_MED',100,'UPDATE'),('FONT_MED',138,'100%')],
 'otafail':[('FONT_MED',100,'UPDATE'),('FONT_MED',138,'FAILED')],
 'sensor':[('FONT_MED',100,'SENSOR'),('FONT_MED',138,'ERROR')],
}
for name,items in screens.items():
    bx=[]
    for f,y,s in items:
        fo=F[f]; w=V.width(fo,s); b=(120-w//2,y-fo['H']//2,120-w//2+w,y-fo['H']//2+fo['H'])
        worst=max(math.hypot(x-120,yy-120) for x in (b[0],b[2]) for yy in (b[1],b[3]))
        if worst>104: print(name,s,'reaches r=%.1f (ring at 105)'%worst); bad+=1
        for o in bx:
            if b[0]<o[2] and o[0]<b[2] and b[1]<o[3] and o[1]<b[3]: print(name,'overlap',s); bad+=1
        bx.append(b)
# 7-seg digits for the rep count: 3 digits s=6 -> 168x102
w,h=3*48+2*12,102; print('7seg 3 digits corner r=%.1f'%math.hypot(w/2,h/2))


def preview(path):
    """A picture of the dashboard with example numbers (needs Pillow)."""
    from PIL import Image, ImageDraw
    S = 1
    img = Image.new("RGB", (240, 240), (0, 0, 0))
    d = ImageDraw.Draw(img)
    def arc(r, ir, a0, a1, col):
        d.arc([120 - r, 120 - r, 120 + r, 120 + r], a0 + 90, a1 + 90, fill=col, width=r - ir)
    arc(118, 108, 40, 320, (40, 40, 44)); arc(118, 108, 40, 40 + int(280 * 0.8), (0, 255, 136))
    arc(104, 98, 40, 320, (40, 40, 44)); arc(104, 98, 40, 40 + int(280 * 8 / 13), (56, 176, 248))
    d.ellipse([117, 27, 123, 33], fill=(0, 255, 136))
    txt, f = "82%", F["FONT_TINY"]
    total = 25 + 2 + 5 + V.width(f, txt); x = 120 - total // 2
    d.rounded_rectangle([x, 38, x + 24, 50], radius=3, outline="white")
    d.rectangle([x + 25, 42, x + 26, 46], fill="white")
    for i in range(3):
        d.rectangle([x + 3 + i * 5, 41, x + 3 + i * 5 + 3, 47], fill=(0, 255, 136))
    V.render(img, f, txt, x + 32, 44, (0, 255, 136), centre=False)
    V.render(img, F["FONT_SMALL"], "Tue  10:30", 120, 66, (130, 130, 130))
    V.render(img, F["FONT_BIG"], "48", 120, 106, (255, 255, 255))
    V.render(img, F["FONT_SMALL"], "reps / 60", 120, 138, (0, 255, 136))
    V.render(img, F["FONT_SMALL"], "12 sets  1.8 t", 120, 157, (255, 255, 255))
    V.render(img, F["FONT_SMALL"], "muscles 8/13", 120, 176, (56, 176, 248))
    for i in range(7):
        x = 120 + (i - 3) * 15
        if i < 2: d.ellipse([x - 5, 191, x + 5, 201], fill=(255, 138, 61))
        else: d.ellipse([x - 4, 192, x + 4, 200], outline=(40, 40, 44))
        if i == 1: d.ellipse([x - 7, 189, x + 7, 203], outline="white")
    V.render(img, F["FONT_TINY"], "2/3 - 3 wk streak", 120, 215, (130, 130, 130))
    mask = Image.new("L", (240, 240), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, 239, 239], fill=255)
    out = Image.new("RGB", (240, 240), (60, 60, 60)); out.paste(img, (0, 0), mask)
    out.resize((480, 480), Image.NEAREST).save(path)


if len(sys.argv) > 2 and sys.argv[1] == "--preview":
    preview(sys.argv[2])
print("layout problems:", bad)
sys.exit(1 if bad else 0)
