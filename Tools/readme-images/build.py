# Lays out the README pictures from the windows Tools/readme-images.sh had the app render.
#   python3 Tools/readme-images/build.py <captures folder>
# Writes Design/screenshots/*.webp and Design/social-preview.png. Every picture comes in light and dark; the README
# shows the one that matches the reader's theme.
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from compose import backdrop, finish, layout, place, rounded, scaled, shadow_onto, window

raw = sys.argv[1]
out = "Design/screenshots"
os.makedirs(out, exist_ok=True)


def webp(img, name):
    img.save(f"{out}/{name}.webp", quality=92, method=6)
    print(f"  {out}/{name}.webp")


def capture(name):
    return Image.open(f"{raw}/{name}.png").convert("RGBA")


for theme in ["light", "dark"]:
    webp(place(window(capture(f"meeting-{theme}")), theme, (160, 130), 2000), f"meeting-{theme}")
    webp(place(window(capture(f"people-{theme}")), theme, (130, 110), 1800), f"people-{theme}")
    webp(place(window(capture(f"naming-{theme}")), theme, (130, 110), 1800), f"naming-{theme}")
    webp(place(window(capture(f"github-{theme}")), theme, (130, 110), 1800), f"github-{theme}")

    # While recording: the live window, with the floating recorder and the menu bar item beside it.
    live = window(capture(f"live-{theme}"))
    floating = rounded(capture(f"floating-{theme}"), 26)
    menubar = rounded(capture(f"menubar-{theme}"), 22)
    live = scaled(live, 0.86)
    gap, px, py = 90, 150, 120
    width = px + live.width + gap + max(menubar.width, floating.width) + px
    height = py + max(live.height, menubar.height + gap + floating.height) + py
    side = px + live.width + gap
    items = [(live, (px, py)), (menubar, (side, py)), (floating, (side, py + menubar.height + gap))]
    webp(layout(items, (width, height), theme, 1800), f"recording-{theme}")

# One meeting in three languages, as three windows on top of each other.
windows = [scaled(window(capture(f"meeting-light-{language}")), 0.5) for language in ["de", "fr", "uk"]]
step, px, py = (300, 150), 120, 100
size = (px * 2 + windows[0].width + step[0] * 2, py * 2 + windows[0].height + step[1] * 2)
items = [(image, (px + step[0] * index, py + step[1] * index)) for index, image in enumerate(windows)]
webp(layout(items, size, "light", 1800), "languages")

print("Social preview")
S = 2  # drawn at 2x, saved at 1280 x 640
canvas = backdrop((1280 * S, 640 * S), "dark").convert("RGBA")
mac = scaled(window(capture("meeting-dark")), 0.62)
canvas = shadow_onto(canvas, mac, (640 * S, 150 * S), "dark", rim=True)
icon = Image.open("Packages/TranscriptsKit/Sources/TranscriptsKit/Resources/icon-dark.png").convert("RGBA")
canvas.alpha_composite(icon.resize((176 * S, 176 * S), Image.LANCZOS), (66 * S, 128 * S))


def font(weight, size):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size * S)
    f.set_variation_by_name(weight)
    return f


d = ImageDraw.Draw(canvas)
d.text((86 * S, 318 * S), "Transcripts", font=font("Bold", 76), fill=(240, 241, 245))
d.text((88 * S, 418 * S), "Your meetings, transcribed", font=font("Medium", 32), fill=(200, 203, 214))
d.text((88 * S, 458 * S), "on your Mac, with names.", font=font("Medium", 32), fill=(200, 203, 214))
d.text((88 * S, 526 * S), "It learns every voice. Audio and", font=font("Regular", 22), fill=(140, 145, 160))
d.text((88 * S, 556 * S), "voices never leave the Mac.", font=font("Regular", 22), fill=(140, 145, 160))
finish(canvas, 1280).save("Design/social-preview.png", optimize=True)
print("  Design/social-preview.png")
