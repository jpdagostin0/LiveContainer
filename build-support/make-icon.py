#!/usr/bin/env python3
"""Render the LiveContainer+SideStore app icon into Resources/Assets.xcassets.

    python3 build-support/make-icon.py

Draws a 1024 pt master with Pillow (4x supersampled) and writes every size the
AppIcon set lists. The design is an isometric "container" cube on an indigo-to-
cyan field, with app tiles rising out of its open top, shelf lines on the left face
and a sparkle on the right one.
"""
import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")
S = 4096  # supersampled canvas; downsampled to 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def gradient(size, c0, c1, angle_deg):
    """Linear gradient across the square at `angle_deg` (0 = left->right)."""
    w = h = size
    small = 256
    g = Image.new("RGB", (small, small))
    px = g.load()
    ang = math.radians(angle_deg)
    dx, dy = math.cos(ang), math.sin(ang)
    for y in range(small):
        for x in range(small):
            u = (x / (small - 1) - 0.5) * dx + (y / (small - 1) - 0.5) * dy
            t = min(1.0, max(0.0, u / (abs(dx) * 0.5 + abs(dy) * 0.5) * 0.5 + 0.5))
            px[x, y] = lerp(c0, c1, t)
    return g.resize((w, h), Image.Resampling.BICUBIC)


def radial_glow(size, center, radius, color, strength):
    layer = Image.new("RGBA", (size, size), color + (0,))
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    cx, cy = center
    steps = 60
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(strength * (1 - i / steps) ** 1.6)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=a)
    layer.putalpha(mask)
    return layer


def poly(draw, pts, fill):
    draw.polygon([(round(x), round(y)) for x, y in pts], fill=fill)


def shaded_face(size, pts, top_color, bottom_color, y0, y1):
    """Polygon filled with a vertical gradient between y0 and y1."""
    grad = gradient(size, top_color[:3], bottom_color[:3], 90).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon([(round(x), round(y)) for x, y in pts], fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def rounded_tile(size, box, radius, fill):
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(box, radius=radius, fill=fill)
    return layer


def face_map(origin, u, v):
    """Map unit-square face coordinates onto an isometric face."""
    ox, oy = origin
    return lambda a, b: (ox + u[0] * a + v[0] * b, oy + u[1] * a + v[1] * b)


def render():
    img = gradient(S, (60, 22, 140), (18, 150, 220), 60).convert("RGBA")
    img.alpha_composite(radial_glow(S, (S * 0.25, S * 0.15), S * 0.80, (255, 255, 255), 55))
    img.alpha_composite(radial_glow(S, (S * 0.85, S * 1.00), S * 0.70, (110, 30, 190), 80))

    # Isometric cube (open top). The figure (tiles + cube) is centered.
    e = S * 0.235                      # half width
    k = e * math.tan(math.radians(30))  # half height of the top diamond
    h = S * 0.235                      # vertical edge
    cx, cy = S * 0.5, S * 0.665         # cy = y of the left/right bottom corners
    top = [(cx, cy - k - h), (cx + e, cy - h), (cx, cy + k - h), (cx - e, cy - h)]
    left = [(cx - e, cy - h), (cx, cy + k - h), (cx, cy + k), (cx - e, cy)]
    right = [(cx, cy + k - h), (cx + e, cy - h), (cx + e, cy), (cx, cy + k)]

    # Contact shadow.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon(
        [(round(x), round(y + h + S * 0.02)) for x, y in top], fill=(12, 4, 50, 120))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.035)))

    # Inside of the box: dark well with a soft gradient (back walls).
    img.alpha_composite(shaded_face(S, top, (22, 12, 70), (52, 34, 128), cy - k - h, cy + k - h))

    # Back rim of the opening (behind the tiles).
    back = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bpts = [(round(x), round(y)) for x, y in top]
    ImageDraw.Draw(back).line([bpts[3], bpts[0], bpts[1]], fill=(255, 255, 255, 120), width=int(S * 0.008), joint="curve")
    img.alpha_composite(back)

    # App tiles rising out of the opening. They may only show inside the
    # opening or above its back rim; the front faces then cover their bases.
    tiles_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile = S * 0.150
    base = cy - h + k * 0.15
    for x, rise, col in [
        (cx - tile * 1.20, tile * 1.05, (255, 92, 132)),
        (cx + tile * 0.20, tile * 1.10, (82, 224, 158)),
        (cx - tile * 0.50, tile * 1.60, (255, 194, 58)),
    ]:
        y = base - rise
        box = (x, y, x + tile, y + tile * 1.35)
        glow = rounded_tile(S, (box[0] - tile * 0.06, box[1] - tile * 0.06, box[2] + tile * 0.06, box[3]), tile * 0.28, col + (120,))
        tiles_layer.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.014)))
        tiles_layer.alpha_composite(rounded_tile(S, box, tile * 0.24, col + (255,)))
        tiles_layer.alpha_composite(rounded_tile(S, (box[0], box[1], box[2], box[1] + tile * 0.55), tile * 0.24, (255, 255, 255, 70)))
    clip = Image.new("L", (S, S), 0)
    cd = ImageDraw.Draw(clip)
    cd.polygon([(round(x), round(y)) for x, y in top], fill=255)
    cd.polygon([(0, 0), (S, 0), (S, round(cy - h)), (round(cx + e), round(cy - h)),
                (round(cx), round(cy - k - h)), (round(cx - e), round(cy - h)), (0, round(cy - h))], fill=255)
    tiles_layer.putalpha(ImageChops.multiply(tiles_layer.getchannel("A"), clip))
    img.alpha_composite(tiles_layer)

    # Front faces with vertical shading.
    img.alpha_composite(shaded_face(S, left, (244, 246, 255), (190, 198, 242), cy - h, cy + k))
    img.alpha_composite(shaded_face(S, right, (196, 204, 250), (126, 136, 214), cy - h, cy + k))

    # Bright rim on the front edges of the opening.
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    w = int(S * 0.010)
    pts = [(round(x), round(y)) for x, y in top]
    rd.line([pts[3], pts[2], pts[1]], fill=(255, 255, 255, 255), width=w, joint="curve")
    rd.line([(round(cx), round(cy + k - h)), (round(cx), round(cy + k))], fill=(255, 255, 255, 150), width=int(w * 0.5))
    img.alpha_composite(rim)

    # Two "shelf" lines on the left face's plane (a container of apps).
    lf = face_map((cx - e, cy - h), (e, k), (0, h))
    shelves = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shelves)
    for v in (0.42, 0.62):
        sdraw.line([tuple(map(round, lf(0.22, v))), tuple(map(round, lf(0.78, v)))], fill=(120, 96, 220, 255), width=int(S * 0.016))
    img.alpha_composite(shelves)

    # Four-point sparkle on the right face's plane ("live").
    rf = face_map((cx, cy + k - h), (e, -k), (0, h))
    star = []
    for i in range(8):
        ang = math.pi / 4 * i
        rr = 0.20 if i % 2 == 0 else 0.06
        star.append(rf(0.5 + rr * math.cos(ang), 0.5 + rr * math.sin(ang) * (e / h)))
    sp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    poly(ImageDraw.Draw(sp), star, (255, 255, 255, 235))
    img.alpha_composite(sp)

    return img.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)


SIZES = [
    ("iphone", "20x20", [2, 3]), ("iphone", "29x29", [2, 3]),
    ("iphone", "40x40", [2, 3]), ("iphone", "60x60", [2, 3]),
    ("ipad", "20x20", [1, 2]), ("ipad", "29x29", [1, 2]),
    ("ipad", "40x40", [1, 2]), ("ipad", "76x76", [1, 2]),
    ("ipad", "83.5x83.5", [2]), ("ios-marketing", "1024x1024", [1]),
]


def main():
    master = render()
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".png"):
            os.remove(os.path.join(OUT, f))
    images = []
    for idiom, size, scales in SIZES:
        pt = float(size.split("x")[0])
        for sc in scales:
            px = int(round(pt * sc))
            name = f"icon-{px}.png"
            if not os.path.exists(os.path.join(OUT, name)):
                master.resize((px, px), Image.Resampling.LANCZOS).save(os.path.join(OUT, name), optimize=True)
            images.append({"filename": name, "idiom": idiom, "scale": f"{sc}x", "size": size})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(os.path.dirname(OUT), "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    # Grey variant LiveContainer uses for its second (multitasking) copy
    # (LCUtils sets CFBundleIconName/CFBundleIconFiles to AppIconGrey*).
    grey = ImageEnhance.Color(master).enhance(0.0)
    grey = ImageEnhance.Brightness(grey).enhance(0.92)
    for name, px in (("AppIconGrey60x60@2x.png", 120), ("AppIconGrey76x76@2x~ipad.png", 152)):
        grey.resize((px, px), Image.Resampling.LANCZOS).save(os.path.join(ROOT, "Resources", name), optimize=True)
    print(f"wrote {len(images)} icon entries to {OUT} and the AppIconGrey PNGs")


if __name__ == "__main__":
    main()
