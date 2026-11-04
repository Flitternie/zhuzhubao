"""Build the app icon (AppIcon.icns) from the big pixel cat head.

Usage: python make_icon.py <head-on-green.png> <out-dir>
Needs Pillow. Writes <out-dir>/AppIcon.icns and <out-dir>/AppIcon-1024.png.
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

src, out_dir = sys.argv[1], sys.argv[2]

# 1. Key out the green background, and neutralise any green cast left on the edge.
head = Image.open(src).convert('RGBA')
p = head.load()
W, H = head.size
for y in range(H):
    for x in range(W):
        r, g, b, a = p[x, y]
        if g > 110 and g > r * 1.3 and g > b * 1.3:
            p[x, y] = (0, 0, 0, 0)
        elif g > r + 8 and g > b + 8:
            m = min(r, b)
            p[x, y] = (m, m, m, a)
head = head.crop(head.getbbox())

# 2. macOS icon shape: an 824 px rounded square inside a 1024 canvas, soft sky-blue gradient.
S = 1024
canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
body = (100, 100, 924, 924)
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(body, radius=186, fill=255)
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((100, 112, 924, 936), radius=186, fill=(30, 40, 70, 90))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
grad = Image.new('RGBA', (S, S))
gp = grad.load()
top, bottom = (214, 232, 250), (164, 198, 238)
for y in range(S):
    t = min(1, max(0, (y - 100) / 824))
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    for x in range(S):
        gp[x, y] = c
canvas.paste(grad, (0, 0), mask)

# 3. The head, big and centred, sitting a touch low like it is peeking up.
target_w = 600
k = target_w / head.width
head = head.resize((target_w, int(head.height * k)), Image.LANCZOS)
hx = (S - head.width) // 2
hy = (S - head.height) // 2 + 12
soft = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sh = Image.new('RGBA', head.size, (20, 30, 60, 70))
sh.putalpha(head.getchannel('A').point(lambda v: 70 if v > 0 else 0))
soft.paste(sh, (hx, hy + 14), sh)
canvas.alpha_composite(soft.filter(ImageFilter.GaussianBlur(10)))
canvas.alpha_composite(head, (hx, hy))
os.makedirs(out_dir, exist_ok=True)
canvas.save(os.path.join(out_dir, 'AppIcon-1024.png'))

# 4. All the sizes macOS wants, then iconutil.
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, 'AppIcon.iconset')
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            canvas.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'))
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(out_dir, 'AppIcon.icns')], check=True)
print('wrote', os.path.join(out_dir, 'AppIcon.icns'))
