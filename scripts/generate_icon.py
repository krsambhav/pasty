#!/usr/bin/env python3
"""Renders Pasty's app icon at every macOS size. Run: python3 scripts/generate_icon.py"""
import json, os
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas; downsampled for crisp edges
OUT = os.path.join(os.path.dirname(__file__), "..", "Pasty", "Resources", "Assets.xcassets", "AppIcon.appiconset")

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

def render():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS icon grid: 824/1024 body, centered, continuous-ish corner radius.
    inset = int(S * 100 / 1024)
    body = (inset, inset, S - inset, S - inset)
    radius = int(S * 185 / 1024)

    # Soft drop shadow under the body.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + S * 0.012, body[2], body[3] + S * 0.012), radius=radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))

    # Background: restrained vertical gradient, deep ink to indigo.
    top, bottom = (58, 63, 160), (20, 22, 58)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))
    img.paste(grad, (0, 0), rounded_mask((S, S), body, radius))

    # Subtle top highlight for depth.
    hl = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    ImageDraw.Draw(hl).ellipse((-S * 0.2, -S * 0.75, S * 1.2, S * 0.42), fill=(255, 255, 255, 26))
    hl = hl.filter(ImageFilter.GaussianBlur(S * 0.06))
    hl_mask = rounded_mask((S, S), body, radius)
    img.paste(Image.alpha_composite(img, hl), (0, 0), hl_mask)

    u = S / 1024
    # Back sheet: translucent, offset up and right.
    back = (int(400 * u), int(250 * u), int(760 * u), int(690 * u))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(back, radius=int(56 * u), fill=(255, 255, 255, 80))
    img.alpha_composite(layer)

    # Front sheet with soft shadow.
    front = (int(270 * u), int(350 * u), int(640 * u), int(800 * u))
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((front[0], front[1] + int(18 * u), front[2], front[3] + int(18 * u)), radius=int(56 * u), fill=(5, 6, 30, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(28 * u)))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle(front, radius=int(56 * u), fill=(250, 250, 253, 255))

    # Text lines: an accent line and two quiet ones.
    lx = front[0] + int(58 * u)
    lh = int(34 * u)
    lines = [
        (lx, front[1] + int(80 * u), front[2] - int(58 * u), (255, 122, 89, 255)),
        (lx, front[1] + int(160 * u), front[2] - int(100 * u), (196, 199, 216, 255)),
        (lx, front[1] + int(240 * u), front[2] - int(72 * u), (196, 199, 216, 255)),
        (lx, front[1] + int(320 * u), front[2] - int(150 * u), (196, 199, 216, 255)),
    ]
    for x0, y0, x1, color in lines:
        d.rounded_rectangle((x0, y0, x1, y0 + lh), radius=lh // 2, fill=color)
    img.alpha_composite(layer)
    return img

def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    master.resize((1024, 1024), Image.LANCZOS).save(os.path.join(os.path.dirname(__file__), "..", "docs", "icon.png"))

if __name__ == "__main__":
    os.makedirs(os.path.join(os.path.dirname(__file__), "..", "docs"), exist_ok=True)
    main()
