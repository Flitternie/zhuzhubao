"""Pixel-art background for the DMG window (640 x 420 points, plus a @2x version).

Scenery is drawn on a 320 x 210 grid and scaled up 2x (chunky pixels); the cat sprite is pasted at
1 sprite pixel = 1 point so it looks like it does on the desktop. Writes
packaging/background.png and background@2x.png.
Run: python3 tools/make_dmg_bg.py
"""
import math, os, random
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
RES = os.path.join(APP, 'Sources/ZhuzhuPet/Resources')
OUT = os.path.join(APP, 'packaging')
FONT = os.path.join(RES, 'fonts/fusion-pixel-12px-proportional-zh_hans.otf')
W, H = 320, 210                      # low-res grid; the window is 640 x 420
APP_C, APPS_C = (80, 104), (240, 104)  # icon centres on the grid (Finder positions x2)
GROUND = 176                         # grid row where the floor starts

rnd = random.Random(7)
img = Image.new('RGB', (W, H))
px = img.load()

# Sky: soft bands from cream-pink to pale blue, with a 2-row checker dither between bands.
bands = [(255, 238, 236), (252, 236, 240), (246, 236, 246), (236, 238, 250), (228, 240, 252)]
band_h = GROUND / len(bands)
for y in range(GROUND):
    i = min(len(bands) - 1, int(y / band_h))
    j = min(len(bands) - 1, i + 1)
    edge = (y - i * band_h) > band_h - 3
    for x in range(W):
        c = bands[j] if edge and (x + y) % 2 == 0 else bands[i]
        px[x, y] = c

d = ImageDraw.Draw(img)

def cloud(cx, cy, s):
    out, fill, shade = (214, 214, 232), (255, 255, 255), (238, 240, 250)
    blobs = [(-2*s, 0, 2*s), (0, -s, int(2.6*s)), (2*s, 0, 2*s), (int(3.6*s), s // 2, int(1.4*s))]
    for dx, dy, r in blobs:
        d.ellipse([cx+dx-r-1, cy+dy-r-1, cx+dx+r+1, cy+dy+r+1], fill=out)
    for dx, dy, r in blobs:
        d.ellipse([cx+dx-r, cy+dy-r, cx+dx+r, cy+dy+r], fill=fill)
    d.rectangle([cx-4*s, cy+s, cx+5*s, cy+2*s], fill=out)
    d.rectangle([cx-4*s+1, cy+s, cx+5*s-1, cy+2*s-1], fill=shade)
cloud(34, 58, 4); cloud(286, 44, 5); cloud(120, 150, 3)

# Little sparkles in the sky.
for (x, y) in [(118, 22), (210, 60), (300, 120), (20, 140), (150, 70), (262, 160)]:
    c = (255, 214, 120)
    d.point([(x, y-1), (x-1, y), (x, y), (x+1, y), (x, y+1)], fill=c)

# Floor: wooden planks with a lighter top lip.
for y in range(GROUND, H):
    for x in range(W):
        base = (222, 186, 150) if y > GROUND + 1 else (240, 214, 184)
        if y == GROUND: base = (190, 150, 118)
        px[x, y] = base
for y0 in range(GROUND + 7, H, 8):
    d.line([(0, y0), (W, y0)], fill=(204, 166, 132))
for row, y0 in enumerate(range(GROUND + 2, H, 8)):
    off = 0 if row % 2 == 0 else 22
    for x0 in range(off, W, 44):
        d.line([(x0, y0), (x0, min(H - 1, y0 + 4))], fill=(204, 166, 132))

# Paw prints across the floor behind the cat (left to right).
def paw(x, y, c=(196, 156, 126)):
    d.rectangle([x, y + 2, x + 3, y + 4], fill=c)
    for dx, dy in [(-1, 0), (1, -1), (3, -1), (5, 0)]:
        d.point([(x + dx - 1 + 1, y + dy)], fill=c)
for i, x in enumerate(range(20, 140, 20)):
    paw(x, GROUND + 3 + (3 if i % 2 else 0))

# Arrow between the icons: a dotted pink line of little hearts ending in a chunky arrow head.
pink, pinkd = (255, 128, 172), (214, 84, 132)
y = APP_C[1] - 4
for x in range(APP_C[0] + 40, APPS_C[0] - 46, 9):
    d.rectangle([x, y - 1, x + 3, y + 1], fill=pink)
    d.point([(x, y + 1), (x + 3, y + 1)], fill=pinkd)
hx = APPS_C[0] - 46
for k in range(7):
    d.line([(hx + k, y - 6 + k), (hx + k, y + 6 - k)], fill=pink)
d.line([(hx, y - 6), (hx + 6, y)], fill=pinkd); d.line([(hx, y + 6), (hx + 6, y)], fill=pinkd)

# Text in the pixel font (drawn on the grid, so each font pixel becomes 2x2 points).
font = ImageFont.truetype(FONT, 12)
def text(s, cx, y, fill, shadow=None):
    w = d.textlength(s, font=font)
    x = int(cx - w / 2)
    if shadow: d.text((x + 1, y + 1), s, font=font, fill=shadow)
    d.text((x, y), s, font=font, fill=fill)
d.fontmode = '1'
text('把猪猪包拖进 Applications，它就住下啦～', W / 2, 14, (122, 76, 96), shadow=(255, 214, 226))
text('第一次打开：在「应用程序」里右键点它 →「打开」', W / 2, GROUND + 13, (255, 250, 244), shadow=(170, 128, 100))

def scaled(k):
    return img.resize((W * k, H * k), Image.NEAREST)

def sprite(path, mirror=False):
    s = Image.open(path).convert('RGBA')
    return s.transpose(Image.FLIP_LEFT_RIGHT) if mirror else s

def heart(big):
    rows = ([".ooo...ooo.", "ohlpo.opppo", "olpppoppppo", "opppppppppo", "opppppppppo",
             ".oppppppdo.", "..oppppdo..", "...oppdo...", "....odo....", ".....o....."] if big else
            [".oo.oo.", "ohpoppo", "opppppo", ".opppo.", "..odo..", "...o..."])
    pal = {'o': (178, 62, 112), 'p': (255, 128, 172), 'd': (228, 92, 142), 'l': (255, 192, 216), 'h': (255, 255, 255)}
    im = Image.new('RGBA', (len(rows[0]), len(rows)))
    for yy, r in enumerate(rows):
        for xx, ch in enumerate(r):
            if ch in pal: im.putpixel((xx, yy), pal[ch] + (255,))
    return im

os.makedirs(OUT, exist_ok=True)
for k, name in [(1, 'background.png'), (2, 'background@2x.png')]:
    bg = scaled(2 * k).convert('RGBA')
    # The cat walks along the floor toward Applications (walk frames face left, so mirror).
    cat = sprite(os.path.join(RES, 'sprites/walk/walk-3.png'), mirror=True)
    cat = cat.resize((cat.width * k, cat.height * k), Image.NEAREST)
    feet = 122                                  # sprite row of the feet
    cx = int(176 * 2 * k)
    bg.alpha_composite(cat, (cx - cat.width // 2, int((GROUND + 3) * 2 * k) - (feet + 1) * k))
    for (hx, hy, big) in [(182, 124, True), (195, 116, False), (174, 117, False)]:
        h = heart(big)
        h = h.resize((h.width * 2 * k, h.height * 2 * k), Image.NEAREST)
        bg.alpha_composite(h, (hx * 2 * k, hy * 2 * k))
    bg.convert('RGB').save(os.path.join(OUT, name))
print('wrote', OUT)
