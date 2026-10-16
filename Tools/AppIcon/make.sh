#!/bin/bash
# Builds Transcripts' app icons (Transcripts/AppIcon.icon and the presets AppIcon-*.icon), the passes Settings › App-Icon
# colours at runtime (Packages/TranscriptsKit/Sources/TranscriptsKit/AppIconPasses) and the pictures of the icon for
# onboarding, the README and the website. Run it after changing Tools/AppIcon/dictaphone.py.
#   Tools/AppIcon/make.sh
# Needs Xcode (for Icon Composer's ictool), Python 3 with NumPy and Pillow, and rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/../.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
work=build/app-icon
kit=Packages/TranscriptsKit/Sources/TranscriptsKit
passes=$kit/AppIconPasses

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "Needs rsvg-convert: brew install librsvg" >&2; exit 1; }

rm -rf Transcripts/AppIcon.icon Transcripts/AppIcon-*.icon "$work" "$passes"
mkdir -p "$work" "$passes"
python3 Tools/AppIcon/dictaphone.py icons Transcripts
python3 Tools/AppIcon/dictaphone.py passes "$work"

# Each pass at 512 px, light and dark, in 8 bits: plenty for the Dock and the previews in Settings.
for part in base ground body grille button; do
  for look in Default Dark; do
    name=$([ $look = Default ] && echo light || echo dark)-$part
    "$ictool" "$work/pass-$part.icon" --export-image --output-file "$work/$name.png" \
      --platform macOS --rendition $look --width 512 --height 512 --scale 1 >/dev/null
    python3 - "$work/$name.png" "$passes/$name.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
im.convert("RGBA").save(sys.argv[2], optimize=True, icc_profile=im.info.get("icc_profile"))
EOF
  done
done

# The icon at Dock proportions (an 824 px body on a 1024 px canvas): for the iPhone's welcome screen, the README, the
# website and the social preview.
for look in Default Dark; do
  name=$([ $look = Default ] && echo light || echo dark)
  "$ictool" Transcripts/AppIcon.icon --export-image --output-file "$work/$name-full.png" --platform macOS \
    --rendition $look --width 1024 --height 1024 --scale 1 >/dev/null
  swift Tools/AppIcon/pad-icon.swift "$work/$name-full.png" "$work/$name.png"
  sips -z 512 512 "$work/$name.png" --out "$kit/Resources/icon-$name.png" >/dev/null
done
sips -z 256 256 "$work/light.png" --out Design/icon.png >/dev/null
sips -z 256 256 "$work/dark.png" --out Design/icon-dark.png >/dev/null
echo "Wrote Transcripts/AppIcon*.icon, $(ls "$passes" | wc -l | tr -d ' ') passes to $passes and the pictures"
