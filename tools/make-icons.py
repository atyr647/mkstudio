#!/usr/bin/env python3
"""Draw the MK Studio icon (a stack of database discs on a dark rounded square) and write
packaging/icons/: icon-<n>.png, mkstudio.ico, mkstudio.icns.   python3 tools/make-icons.py   (needs Pillow)

The generated files are committed, so building a release does not need Pillow."""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packaging", "icons")
os.makedirs(OUT, exist_ok=True)
S = 2048                                   # draw big, scale down (anti-aliasing)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def draw():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # background: rounded square with a vertical gradient
    bg = Image.new("RGBA", (S, S))
    px = bg.load()
    top, bot = (38, 44, 58), (16, 18, 24)
    for y in range(S):
        c = lerp(top, bot, y / S)
        for x in range(S): px[x, y] = c + (255,)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([60, 60, S - 60, S - 60], radius=int(S * 0.22), fill=255)
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    accent, side, light = (91, 157, 255), (45, 100, 200), (150, 195, 255)
    cx, w = S // 2, int(S * 0.52)
    h = int(S * 0.16)                      # ellipse height
    # three stacked discs, bottom to top
    for i, y0 in enumerate([int(S * 0.62), int(S * 0.46), int(S * 0.30)]):
        x0, x1 = cx - w // 2, cx + w // 2
        body_top, body_bot = y0 + h // 2, y0 + h // 2 + int(S * 0.12)
        d.rectangle([x0, body_top, x1, body_bot], fill=side)
        d.ellipse([x0, body_bot - h // 2, x1, body_bot + h // 2], fill=side)
        d.ellipse([x0, y0, x1, y0 + h], fill=accent if i == 2 else side)
        if i == 2:
            d.ellipse([x0 + int(S * 0.025), y0 + int(S * 0.02), x1 - int(S * 0.025), y0 + h - int(S * 0.02)], fill=light)
        else:
            d.arc([x0, body_bot - h // 2, x1, body_bot + h // 2], 0, 180, fill=light, width=int(S * 0.008))
    return img

big = draw()
sizes = [16, 32, 48, 64, 128, 256, 512, 1024]
for n in sizes:
    big.resize((n, n), Image.LANCZOS).save(os.path.join(OUT, "icon-%d.png" % n))
big.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, "mkstudio.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
big.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "mkstudio.icns"))
print("icons written to", os.path.normpath(OUT))
