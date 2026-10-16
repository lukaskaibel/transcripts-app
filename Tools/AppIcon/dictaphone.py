#!/usr/bin/env python3
"""Draws Transcripts' app icon: a dictaphone with a speaker grille and a record button, standing on a ground.

  dictaphone.py icons <out dir>    <out dir>/AppIcon.icon, the black dictaphone in light and dark (the app's own icon),
                                   and the presets iPhone and iPad offer as alternate icons (AppIcon-Silver.icon, …)
  dictaphone.py passes <out dir>   the passes behind Settings › App-Icon (see AppIcon.swift)

Tools/AppIcon/make.sh runs both and renders the passes with Apple's ictool. Needs Python 3 with NumPy and Pillow,
and rsvg-convert (brew install librsvg).

Every part (the body, the grille, the button and the ground) is filled with its own colour and lit by black and white
overlays that don't depend on it, and the textures multiply. So the icon is a sum of the parts' colours, each times
what its pass shows, and the app can draw it in any colours (AppIconRenderer adds the passes up).
"""
import colorsys, json, math, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

S = 1024

# The dictaphone on the 1024 canvas: its body, the grille plate and the record button.
X, Y, W, H, R = 327, 96, 370, 832, 150
PX, PY, PW, PH, PR = 375, 160, 274, 310, 106
BX, BY, BR = 512, 722, 72
LED = (512, 546)

# The dictaphone the app ships with. Keep in step with AppIconLook.standard in AppIcon.swift.
STANDARD = {"body": "#2C2E33", "grille": "#E1E3E7", "button": "#E8382D", "ground": "#ECE8E1"}

# The presets iPhone and iPad offer as alternate icons. Keep in step with AppIconPreset in AppIcon.swift.
PRESETS = {
    "Silver": {"body": "#D6D8DC", "grille": "#4A4C52", "button": "#E8382D", "ground": "#E4E9F0"},
    "Titanium": {"body": "#B5AEA3", "grille": "#7E786F", "button": "#FF5F1F", "ground": "#ECE8E1"},
    "White": {"body": "#F2F2EF", "grille": "#E1E3E7", "button": "#E8382D", "ground": "#E3E7DE"},
    "Midnight": {"body": "#273145", "grille": "#E1E3E7", "button": "#E8382D", "ground": "#E4E9F0"},
}

PARTS = ("body", "grille", "button", "ground")

# The albedo a part gets in its pass: below white, so the highlights on it never clip.
PASS_GREY = "#B4B4B4"


# Colours. The app derives the same shades from the same colours (AppIcon.swift).

def rgb(hex_):
    return tuple(int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))

def hex_(c):
    return "#" + "".join(f"{round(min(max(v, 0), 1) * 255):02X}" for v in c)

def scaled(hex_colour, saturation, brightness, minimum=0.0):
    h, s, v = colorsys.rgb_to_hsv(*rgb(hex_colour))
    return hex_(colorsys.hsv_to_rgb(h, min(s * saturation, 1), min(max(v * brightness, minimum), 1)))

def ground_shades(c):
    """The ground's gradient, top to bottom, in light and in dark: a dark grey of the same tint, never black."""
    dark_top = scaled(c, 0.6, 0.30, 0.18)
    return {"light": (c, scaled(c, 1.1, 0.88)), "dark": (dark_top, scaled(dark_top, 1.0, 0.55))}


# SVG.

def rr(x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    return (f"M{x + r:.1f},{y:.1f} H{x + w - r:.1f} A{r:.1f},{r:.1f} 0 0 1 {x + w:.1f},{y + r:.1f} "
            f"V{y + h - r:.1f} A{r:.1f},{r:.1f} 0 0 1 {x + w - r:.1f},{y + h:.1f} H{x + r:.1f} "
            f"A{r:.1f},{r:.1f} 0 0 1 {x:.1f},{y + h - r:.1f} V{y + r:.1f} A{r:.1f},{r:.1f} 0 0 1 {x + r:.1f},{y:.1f} Z")

def path(d, fill, extra=""):
    return f'<path d="{d}" fill="{fill}" {extra}/>'

def circle(cx, cy, r, fill, extra=""):
    return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}" {extra}/>'

def stops(pairs):
    return "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in pairs)

def linear(id_, x1, y1, x2, y2, pairs):
    return f'<linearGradient id="{id_}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops(pairs)}</linearGradient>'

def radial(id_, cx, cy, r, pairs, fx=None, fy=None):
    focus = f' fx="{fx}" fy="{fy}"' if fx is not None else ""
    return f'<radialGradient id="{id_}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}"{focus}>{stops(pairs)}</radialGradient>'

def light(colour, pairs):
    """Opacity stops of one colour (white lights, black shades)."""
    return [(o, colour, a) for o, a in pairs]

DEFS = (
    '<filter id="blur4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>'
    '<filter id="blur8" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="8"/></filter>'
    '<filter id="blur24" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="24"/></filter>'
    f'<clipPath id="body"><path d="{rr(X, Y, W, H, R)}"/></clipPath>'
    f'<clipPath id="plate"><path d="{rr(PX, PY, PW, PH, PR)}"/></clipPath>'
    # The body is lit from the upper left: a soft highlight a third of the way across, darker rims.
    + linear("body-shade", X, 0, X + W, 0, light("#000000", [(0, 0.7), (0.06, 0), (0.6, 0), (0.92, 0.28), (1, 0.78)]))
    + linear("body-light", X, 0, X + W, 0, light("#FFFFFF", [(0, 0), (0.06, 0.016), (0.28, 0.06), (0.6, 0), (1, 0)]))
    # The grille plate, brushed metal: brighter and with harder rims than the body.
    + linear("plate-shade", PX, 0, PX + PW, 0, light("#000000", [(0, 0.57), (0.07, 0.11), (0.3, 0), (0.62, 0), (0.93, 0.26), (1, 0.65)]))
    + linear("plate-light", PX, 0, PX + PW, 0, light("#FFFFFF", [(0, 0), (0.07, 0), (0.3, 0.2), (0.62, 0), (1, 0)]))
    # The body's and the plate's edges: lit on top, shaded below; the plate sits in a recess.
    + linear("bevel", 0, Y, 0, Y + H, [(0, "#FFFFFF", 0.3), (0.18, "#FFFFFF", 0), (0.82, "#000000", 0), (1, "#000000", 0.73)])
    + linear("chamfer", 0, Y, 0, Y + H, [(0, "#FFFFFF", 0.5), (0.5, "#FFFFFF", 0.15), (1, "#FFFFFF", 0.3)])
    + linear("recess", 0, PY, 0, PY + PH, [(0, "#000000", 0.67), (0.25, "#000000", 0), (0.8, "#FFFFFF", 0), (1, "#FFFFFF", 0.35)])
    # The record button: a polished ring, a dome lit from the upper left.
    + linear("ring", 0, BY - BR - 15, 0, BY + BR + 15, [(0, "#F2F3F5", 1), (0.45, "#9A9DA4", 1), (0.55, "#C2C5CA", 1), (1, "#E1E3E7", 1)])
    + radial("dome-light", BX, BY, BR, light("#FFFFFF", [(0, 0.16), (0.62, 0), (1, 0)]), fx=BX - BR * 0.25, fy=BY - BR * 0.4)
    + radial("dome-shade", BX, BY, BR, light("#000000", [(0, 0), (0.62, 0), (1, 0.42)]))
)


def hex_points(x0, y0, x1, y1, spacing, inside):
    pts, row, y = [], 0, y0
    while y <= y1:
        x = x0 + (spacing / 2 if row % 2 else 0)
        while x <= x1:
            if inside(x, y):
                pts.append((x, y))
            x += spacing
        y += spacing * math.sqrt(3) / 2
        row += 1
    return pts

def inside_rr(x0, y0, w, h, r):
    def test(x, y):
        cx, cy = min(max(x, x0 + r), x0 + w - r), min(max(y, y0 + r), y0 + h - r)
        return x0 <= x <= x0 + w and y0 <= y <= y0 + h and (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    return test

HOLES = hex_points(PX + 24, PY + 26, PX + PW - 16, PY + PH - 16, 18.5, inside_rr(PX + 20, PY + 20, PW - 40, PH - 40, PR - 20))


def elements():
    """The dictaphone from back to front, as (svg, part): a part's elements are drawn in white and take its colour; the
    light, the shade, the holes and the chrome are drawn as they are."""
    body_d, plate_d = rr(X, Y, W, H, R), rr(PX, PY, PW, PH, PR)
    holes = lambda dy: "".join(f'<circle cx="{x:.1f}" cy="{y + dy:.1f}" r="5.4"/>' for x, y in HOLES)
    lx, ly = LED
    return [
        (path(body_d, "#FFFFFF"), "body"),
        (path(body_d, "url(#body-shade)"), None),
        (path(body_d, "url(#body-light)"), None),
        (f'<path d="{body_d}" fill="none" stroke="url(#bevel)" stroke-width="20" clip-path="url(#body)"/>', None),
        (f'<path d="{body_d}" fill="none" stroke="url(#chamfer)" stroke-width="5" clip-path="url(#body)"/>', None),
        # The grille.
        (path(plate_d, "#FFFFFF"), "grille"),
        (path(plate_d, "url(#plate-shade)"), None),
        (path(plate_d, "url(#plate-light)"), None),
        (f'<path d="{plate_d}" fill="none" stroke="url(#recess)" stroke-width="12" clip-path="url(#plate)"/>', None),
        (f'<g fill="#FFFFFF" fill-opacity="0.25">{holes(1.8)}</g>', None),
        (f'<g fill="#0D0E11">{holes(0)}</g>', None),
        # The light, in the button's colour.
        (circle(lx, ly, 21, "#FFFFFF", 'fill-opacity="0.35" filter="url(#blur8)"'), "button"),
        (circle(lx, ly, 8, "#FFFFFF"), "button"),
        (circle(lx - 2.4, ly - 2.8, 2.8, "#FFFFFF", 'fill-opacity="0.8"'), None),
        # The record button.
        (circle(BX, BY, BR + 15, "url(#ring)"), None),
        (circle(BX, BY, BR + 4.5, "#121316"), None),
        (circle(BX, BY, BR, "#FFFFFF"), "button"),
        (circle(BX, BY, BR, "url(#dome-light)"), None),
        (circle(BX, BY, BR, "url(#dome-shade)"), None),
        (f'<ellipse cx="{BX - BR * 0.1:.1f}" cy="{BY - BR * 0.5:.1f}" rx="{BR * 0.5:.1f}" ry="{BR * 0.24:.1f}" '
         f'fill="#FFFFFF" fill-opacity="0.22" filter="url(#blur4)"/>', None),
    ]

def contact_shadow():
    """Where the dictaphone stands on the ground."""
    return path(rr(X, Y, W, H, R), "#000000", 'fill-opacity="0.45" filter="url(#blur24)" transform="translate(0 22)"')


def write_png(path_, body):
    svg = path_[:-4] + ".svg"
    with open(svg, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">'
                f'<defs>{DEFS}</defs>{body}</svg>')
    subprocess.run(["rsvg-convert", "-w", str(S), "-h", str(S), "-o", path_, svg], check=True)
    os.remove(svg)


# The materials: the body bead-blasted, the grille brushed. Seeded, so every pass gets the same texture.

def textures():
    rng = np.random.default_rng(7)

    def smooth(h, w):
        small = Image.fromarray((rng.random((h, w)) * 255).astype(np.uint8))
        return np.asarray(small.resize((S, S), Image.BICUBIC)).astype(np.float32) / 255 - 0.5

    bead = 1 + rng.normal(0, 1, (S, S)).astype(np.float32) * 0.02 + smooth(50, 50) * 0.008
    brushed = 1 + smooth(S, 4) * 0.03 + smooth(S, 10) * 0.025 + rng.normal(0, 1, (S, S)).astype(np.float32) * 0.003

    def mask(body):
        with tempfile.TemporaryDirectory() as work:
            png = os.path.join(work, "mask.png")
            write_png(png, body)
            return np.asarray(Image.open(png).convert("RGBA"))[..., 3].astype(np.float32) / 255

    body = mask(path(rr(X, Y, W, H, R), "#FFFFFF"))
    plate = mask(path(rr(PX, PY, PW, PH, PR), "#FFFFFF"))
    button = mask(circle(BX, BY, BR + 15, "#FFFFFF"))
    on_body = body * (1 - plate) * (1 - button)
    return 1 + (bead - 1) * on_body + (brushed - 1) * plate

def decode(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

def encode(v):
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(v, 1 / 2.4) - 0.055)

RENDERED = None

def rendered():
    """Each element as linear colour (None for a part's) and coverage; drawn once, used for every colour."""
    global RENDERED
    if RENDERED is None:
        RENDERED = []
        with tempfile.TemporaryDirectory() as work:
            for i, (svg, part) in enumerate(elements()):
                png = os.path.join(work, f"{i}.png")
                write_png(png, svg)
                a = np.asarray(Image.open(png).convert("RGBA")).astype(np.float32) / 255
                RENDERED.append((None if part else decode(a[..., :3]), a[..., 3], part))
        RENDERED.append(textures() ** 2.2)
    return RENDERED

def recorder(colours, png):
    """The dictaphone in the colours (one per part), blended in linear light: so it is a sum of the parts' colours,
    each times what its pass shows."""
    *layers, texture = rendered()
    premultiplied = np.zeros((S, S, 3), np.float32)
    alpha = np.zeros((S, S), np.float32)
    for colour, coverage, part in layers:
        if part:
            colour = decode(np.array(rgb(colours[part]), np.float32))
        premultiplied = premultiplied * (1 - coverage[..., None]) + colour * coverage[..., None]
        alpha = alpha * (1 - coverage) + coverage
    premultiplied *= texture[..., None]
    straight = premultiplied / np.maximum(alpha, 1e-6)[..., None]
    out = np.dstack([encode(np.clip(straight, 0, 1)) * 255, alpha * 255])
    Image.fromarray(np.round(out).astype(np.uint8), "RGBA").save(png)


# Icon Composer documents.

def srgb(hex_colour):
    r, g, b = rgb(hex_colour)
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"

def fill(top, bottom):
    return {"linear-gradient": [srgb(top), srgb(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}

def document(path_, colours, grounds):
    """colours: a colour per part; grounds: {"light": (top, bottom), "dark": (top, bottom)}."""
    assets = os.path.join(path_, "Assets")
    os.makedirs(assets, exist_ok=True)
    recorder(colours, os.path.join(assets, "recorder.png"))
    write_png(os.path.join(assets, "shadow.png"), contact_shadow())
    doc = {
        "fill-specializations": [{"value": fill(*grounds["light"])}, {"appearance": "dark", "value": fill(*grounds["dark"])}],
        "groups": [
            {"name": "Dictaphone", "layers": [{"name": "recorder", "glass": False, "image-name": "recorder.png"}],
             "shadow": {"kind": "neutral", "opacity": 0.3}, "translucency": {"enabled": False, "value": 0.4}},
            {"name": "Contact shadow", "layers": [{"name": "shadow", "glass": False, "image-name": "shadow.png"}],
             "shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.4}},
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(path_, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)


def icons(out):
    document(os.path.join(out, "AppIcon.icon"), STANDARD, ground_shades(STANDARD["ground"]))
    for name, colours in PRESETS.items():
        document(os.path.join(out, f"AppIcon-{name}.icon"), colours, ground_shades(colours["ground"]))

def passes(out):
    """One document per part: that part in grey, the rest black ("base": all black). The app adds them up in linear
    light: base + Σ colour × (pass − base) / grey."""
    for part in ("base",) + PARTS:
        colours = {p: PASS_GREY if p == part else "#000000" for p in PARTS}
        ground = (colours["ground"], colours["ground"])
        document(os.path.join(out, f"pass-{part}.icon"), colours, {"light": ground, "dark": ground})


if __name__ == "__main__":
    what, out = sys.argv[1], sys.argv[2]
    {"icons": icons, "passes": passes}[what](out)
