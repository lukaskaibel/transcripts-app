# Makes the website's pictures from the windows Tools/readme-images.sh had the app render, and from the app icon.
#   python3 Tools/readme-images/website.py <captures folder>
# Writes Website/images: the meeting window and the floating recorder with rounded corners on a transparent ground
# (the page draws the shadows), in light and dark, and the icons. Tools/readme-images.sh runs it after the README
# images.
import os
import subprocess
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from compose import THEMES, rounded, scaled

raw = sys.argv[1] if len(sys.argv) > 1 else "build/readme-images/raw"
icons = "Packages/TranscriptsKit/Sources/TranscriptsKit/Resources"
out = "Website/images"
os.makedirs(out, exist_ok=True)


def save(img, name, **options):
    img.save(f"{out}/{name}", **options)
    print(f"  {out}/{name}")


def capture(name):
    return Image.open(f"{raw}/{name}.png").convert("RGBA")


for theme in ["light", "dark"]:
    border = THEMES[theme]["border"]
    save(scaled(rounded(capture(f"meeting-{theme}"), 30, border), 0.72), f"mac-{theme}.webp", quality=86, method=6)
    save(rounded(capture(f"floating-{theme}"), 26, border), f"recorder-{theme}.webp", quality=90, method=6)

for theme in ["light", "dark"]:
    icon = Image.open(f"{icons}/icon-{theme}.png").convert("RGBA")
    save(icon.resize((288, 288), Image.LANCZOS), f"icon-{theme}.png", optimize=True)
    save(icon.resize((64, 64), Image.LANCZOS), f"favicon-{theme}.png", optimize=True)

# The home-screen icon is the iOS rendition of the icon.
ictool = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip() \
    + "/../Applications/Icon Composer.app/Contents/Executables/ictool"
with tempfile.TemporaryDirectory() as work:
    subprocess.run([ictool, "Transcripts/AppIcon.icon", "--export-image", "--output-file", f"{work}/touch.png",
                    "--platform", "iOS", "--rendition", "Default", "--width", "180", "--height", "180", "--scale", "1"],
                   check=True, stdout=subprocess.DEVNULL)
    save(Image.open(f"{work}/touch.png").convert("RGBA"), "apple-touch-icon.png", optimize=True)
