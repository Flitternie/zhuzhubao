#!/usr/bin/env python3
"""Draws the visiting friend's pixel hand and the friend-related UI icons.

The hand is built from simple shapes (capsule fingers, rounded palm, thumb, a thin sleeve) and
rasterised at the cat's own pixel density, so waving re-draws the hand turned instead of shearing
pixels. Outline: a soft warm dark, lighter than the UI ink; flat skin with one shade tone.

Hand frames (sprites/hand/): open, pat (fingers curled forward), wave-l / wave-r (turned).
Icons (sprites/ui/, 16 x 16): hand (visit a friend / pet), hi (a speech bubble).

    python3 tools/make_hand.py
"""
import math
from pathlib import Path
from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "Sources/ZhuzhuPet/Resources/sprites"
INK = (64, 60, 66, 255)
LINE = (112, 86, 82, 255)
SKIN = (255, 231, 212, 255)
SHADE = (243, 199, 176, 255)
SLEEVE = (160, 204, 240, 255)
SLEEVE_SHADE = (118, 170, 222, 255)
W, H = 24, 30


def capsule(a, b, r):
    (ax, ay), (bx, by) = a, b
    def inside(x, y):
        dx, dy = bx - ax, by - ay
        t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
        px, py = ax + t * dx, ay + t * dy
        return (x - px) ** 2 + (y - py) ** 2 <= r * r
    return inside


def rrect(x0, y0, x1, y1, r):
    def inside(x, y):
        cx = min(max(x, x0 + r), x1 - r)
        cy = min(max(y, y0 + r), y1 - r)
        return x0 <= x <= x1 and y0 <= y <= y1 and (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    return inside


def hand(curl=0.0, turn=0.0):
    """Parts in drawing order: (name, inside-test, fill, shade). y grows downwards; wrist at the bottom."""
    pivot = (12.0, 26.0)
    c, s = math.cos(math.radians(turn)), math.sin(math.radians(turn))
    def rot(p):
        x, y = p[0] - pivot[0], p[1] - pivot[1]
        return (pivot[0] + x * c - y * s, pivot[1] + x * s + y * c)
    def finger(base, tip, r=1.45):
        t = (base[0] + (tip[0] - base[0]) * (1 - curl), base[1] + (tip[1] - base[1]) * (1 - curl))
        return capsule(rot(base), rot(t), r)
    pr = rrect(6.0, 13.5, 18.6, 25.2, 3.2)
    def palm(x, y):          # test the point turned back into the palm's own frame
        x0, y0 = x - pivot[0], y - pivot[1]
        return pr(pivot[0] + x0 * c + y0 * s, pivot[1] - x0 * s + y0 * c)
    return [
        ("thumb", capsule(rot((7.6, 21.0)), rot((3.4, 14.6)), 1.6), SKIN, SHADE),
        ("index", finger((8.4, 15.0), (7.2, 5.0)), SKIN, SHADE),
        ("middle", finger((11.4, 14.0), (11.2, 2.6)), SKIN, SHADE),
        ("ring", finger((14.4, 15.0), (15.2, 4.4)), SKIN, SHADE),
        ("pinky", finger((17.0, 17.0), (18.6, 8.6), 1.3), SKIN, SHADE),
        ("palm", palm, SKIN, SHADE),
        ("sleeve", rrect(7.2, 24.6, 17.6, 29.6, 1.0), SLEEVE, SLEEVE_SHADE),
    ]


def render(parts):
    owner = {}
    for y in range(H):
        for x in range(W):
            for i, (_, inside, _, _) in enumerate(parts):
                if inside(x + 0.5, y + 0.5):
                    owner[(x, y)] = i      # later parts win: palm over finger roots, sleeve over palm
    names = [p[0] for p in parts]
    fingers = {names.index(n) for n in ("index", "middle", "ring", "pinky")}
    palm, sleeve = names.index("palm"), names.index("sleeve")
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for (x, y), i in owner.items():
        _, _, fill, shade = parts[i]
        edge = owner.get((x + 1, y)) != i or owner.get((x, y + 1)) != i
        img.putpixel((x, y), shade if edge else fill)
    for y in range(H):                     # outline: empty pixels touching the hand
        for x in range(W):
            if (x, y) not in owner and any(q in owner for q in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1))):
                img.putpixel((x, y), LINE)
    for (x, y), i in owner.items():
        j = owner.get((x + 1, y))
        if j is not None and j != i and i in fingers and j in fingers:
            img.putpixel((x, y), LINE)     # gaps between the fingers
        if i == sleeve and owner.get((x, y - 1)) == palm:
            img.putpixel((x, y), LINE)     # sleeve hem
    return img


def icon(rows, palette):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch in palette:
                img.putpixel((x, y), palette[ch])
    return img


def main():
    (OUT / "hand").mkdir(parents=True, exist_ok=True)
    render(hand()).save(OUT / "hand/open.png")
    render(hand(curl=0.45)).save(OUT / "hand/pat.png")
    render(hand(turn=-12)).save(OUT / "hand/wave-l.png")
    render(hand(turn=12)).save(OUT / "hand/wave-r.png")
    # the 16 px menu icon: the open hand shrunk by hand-picked pixels
    P = {"o": INK, "w": (255, 255, 255, 255), "r": (232, 48, 52, 255),
         "b": SLEEVE, "B": SLEEVE_SHADE, "s": SKIN, "S": SHADE, "g": (200, 196, 204, 255)}
    hand_icon = [
        "................",
        "......o.........",
        "....oosoo.......",
        "...osososoo.....",
        "...osososoSo....",
        "...osososoSo.o..",
        "...osssssssoso..",
        ".o.osssssssSso..",
        "osooosssssssSo..",
        ".osssssssssSo...",
        "..osssssssSSo...",
        "...ossssssSo....",
        "....obbbbbBo....",
        ".....oooooo.....",
        "................",
        "................",
    ]
    hi = [
        "................",
        "..oooooooooooo..",
        ".owwwwwwwwwwwwo.",
        ".owwwwwwwwwwwgo.",
        ".owworwwrwwrwgo.",
        ".owworwwrwwwwgo.",
        ".owworrrrwwrwgo.",
        ".owworwwrwwrwgo.",
        ".owworwwrwwrwgo.",
        ".owwwwwwwwwwwgo.",
        ".oggggggggggggo.",
        "..oooooo.ooooo..",
        "........owo.....",
        ".......oo.......",
        "................",
        "................",
    ]
    # 小咪好友: two little cat heads, a friend's cream one peeking from behind a white one
    P.update({"p": (246, 150, 164, 255), "c": (252, 232, 200, 255), "C": (230, 200, 160, 255),
              "e": (52, 84, 160, 255), "W": (220, 216, 228, 255)})
    back = [
        "................",
        "................",
        "................",
        "................",
        ".oo..oo.........",
        "opco.ocpo.......",
        "occcoccco.......",
        "occccccco.......",
        "ocecceccco......",
        "ocecceccco......",
        "occcpcccco......",
        ".oCCCCCCo.......",
        "..oooooo........",
        "................",
        "................",
        "................",
    ]
    front = [
        "................",
        "................",
        "......oo....oo..",
        ".....oppooooppo.",
        ".....owwwwwwwwo.",
        ".....owwwwwwwwo.",
        ".....owewwwwewo.",
        ".....owewwwwewo.",
        ".....owwwppwwwo.",
        ".....oWwwwwwwWo.",
        "......oWWWWWWo..",
        ".......oooooo...",
        "................",
        "................",
        "................",
        "................",
    ]
    img = icon(back, P)
    img.alpha_composite(icon(front, P))
    img.save(OUT / "ui/friends.png")
    icon(hand_icon, P).save(OUT / "ui/hand.png")
    icon(hi, P).save(OUT / "ui/hi.png")


if __name__ == "__main__":
    main()
