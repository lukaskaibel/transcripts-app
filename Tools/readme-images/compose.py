# Drawing helpers for the README images: a backdrop in the app's indigo, window shadows and rounded corners. The same
# look as the Issues app's README (github.com/lukaskaibel/issues-for-github).
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

THEMES = {
    # Glows: colour, strength, centre (fractions of width and height), radius (fraction of width).
    "dark": dict(
        base=(11, 12, 16),
        glows=[((101, 108, 230), 0.80, (0.50, -0.05), 0.95), ((196, 95, 166), 0.34, (1.00, 1.05), 0.60),
               ((90, 176, 216), 0.22, (0.00, 1.05), 0.55)],
        shadow=0.70, border=(255, 255, 255, 22), rim=(255, 255, 255, 34)),
    "light": dict(
        base=(244, 244, 250),
        glows=[((143, 150, 242), 0.42, (0.50, 0.00), 0.75), ((217, 139, 196), 0.20, (0.95, 1.05), 0.55),
               ((90, 176, 216), 0.14, (0.02, 1.00), 0.50)],
        shadow=0.24, border=(0, 0, 0, 20), rim=(0, 0, 0, 30)),
}


def backdrop(size, theme):
    w, h = size
    t = THEMES[theme]
    # The glows are smooth, so they are computed small and scaled up.
    sw, sh = max(1, w // 8), max(1, h // 8)
    ys, xs = np.mgrid[0:sh, 0:sw]
    rgb = np.ones((sh, sw, 3)) * np.array(t["base"], dtype=float)
    for color, strength, (cx, cy), radius in t["glows"]:
        d = np.sqrt((xs / sw - cx) ** 2 + ((ys / sh - cy) * (h / w)) ** 2) / radius
        a = (strength * np.clip(1 - d, 0, 1) ** 2)[..., None]
        rgb = rgb + (np.array(color, dtype=float) - rgb) * a
    img = Image.fromarray(rgb.astype(np.uint8), "RGB").resize((w, h), Image.BICUBIC)
    # Fine noise keeps the gradient free of bands.
    noise = Image.effect_noise((w, h), 6).convert("L").point(lambda v: 128 + (v - 128) // 3)
    return ImageChops.add(img, Image.merge("RGB", [noise] * 3), scale=1, offset=-128)


def rounded(img, radius, border=None):
    img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    img.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    if border:
        ImageDraw.Draw(img).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, outline=border, width=2)
    return img


def shadow_onto(canvas, item, pos, theme, rim=False):
    """Draws item onto canvas (both RGBA) with a soft shadow; rim adds the hairline macOS draws around windows."""
    t = THEMES[theme]
    alpha = item.getchannel("A")
    for blur, opacity, dy in [(60, t["shadow"] * 0.9, 40), (14, t["shadow"] * 0.6, 8)]:
        sh = Image.new("L", canvas.size, 0)
        sh.paste(alpha, (pos[0], pos[1] + dy))
        sh = sh.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * opacity))
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 255))
        layer.putalpha(sh)
        canvas = Image.alpha_composite(canvas, layer)
    canvas.alpha_composite(item, pos)
    if rim:
        ring = ImageChops.subtract(alpha.filter(ImageFilter.MaxFilter(3)), alpha)
        line = Image.new("RGBA", item.size, t["rim"][:3] + (0,))
        line.putalpha(ring.point(lambda v: v * t["rim"][3] // 255))
        canvas.alpha_composite(line, pos)
    return canvas


def finish(canvas, out_width):
    out = canvas.convert("RGB")
    if out.width > out_width:
        out = out.resize((out_width, round(out.height * out_width / out.width)), Image.LANCZOS)
    return out


def place(fg, theme, pad, out_width, rim=True):
    """One window or crop, centred on the backdrop."""
    canvas = backdrop((fg.width + 2 * pad[0], fg.height + 2 * pad[1]), theme).convert("RGBA")
    return finish(shadow_onto(canvas, fg, pad, theme, rim), out_width)


def layout(items, size, theme, out_width):
    """Several images at given positions, drawn in order, each with its shadow."""
    canvas = backdrop(size, theme).convert("RGBA")
    for img, pos in items:
        canvas = shadow_onto(canvas, img, pos, theme)
    return finish(canvas, out_width)


def scaled(img, s):
    return img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)


def opaque(img, threshold=200):
    """Only what is drawn solidly: the floating recorder without the room its window leaves for the shadow."""
    box = img.getchannel("A").point(lambda v: 255 if v >= threshold else 0).getbbox()
    return img.crop(box) if box else img


def phone(img, theme):
    """An iPhone 17 Pro around a simulator screenshot (402 points wide): the screen's rounded corners, a black border,
    a thin titanium band and the Dynamic Island, which the screenshot leaves out."""
    s = img.width / 402
    radius, border, band = 55 * s, round(5.5 * s), round(3 * s)
    edge = border + band
    w, h = img.width + 2 * edge, img.height + 2 * edge
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(out)
    # The band: lit along its top, as a frame is under a ceiling light.
    top, bottom = ((214, 212, 207), (168, 166, 161)) if theme == "light" else ((92, 92, 96), (52, 52, 55))
    band_img = Image.new("RGBA", (w, h))
    for y in range(h):
        t = y / (h - 1)
        band_img.paste(tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,), (0, y, w, y + 1))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius + edge, fill=255)
    out.paste(band_img, (0, 0), mask)
    draw.rounded_rectangle((band, band, w - 1 - band, h - 1 - band), radius + border, fill=(8, 8, 9, 255))
    screen = img.convert("RGBA")
    screen_mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(screen_mask).rounded_rectangle((0, 0, screen.width - 1, screen.height - 1), radius, fill=255)
    out.paste(screen, (edge, edge), screen_mask)
    island_w, island_h, island_y = 125 * s, 37 * s, 11 * s
    x0 = edge + (screen.width - island_w) / 2
    draw.rounded_rectangle((x0, edge + island_y, x0 + island_w, edge + island_y + island_h), island_h / 2, fill=(0, 0, 0, 255))
    return out


def window(img, radius=30):
    """A window rendered by the app itself (square corners) with the rounded corners of a macOS window."""
    return rounded(img, radius)
