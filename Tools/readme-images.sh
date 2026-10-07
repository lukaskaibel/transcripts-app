#!/bin/zsh
# Takes the README's pictures: the app in demo mode renders its own windows (in English, light and dark, and the
# meeting in a few other languages), and Tools/readme-images/build.py lays them out as Design/screenshots/*.webp and
# Design/social-preview.png.
#   Tools/readme-images.sh
# Needs Python 3 with Pillow and NumPy. Works with a locked screen: the app draws into images itself, nothing is
# captured from the screen.
set -e
cd "$(dirname "$0")/.."
python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }

raw=build/readme-images/raw
mkdir -p "$raw"
rm -f "$raw"/*.png(N)
tour=build/readme-images/tour.txt

xcodebuild -project Transcripts.xcodeproj -scheme Transcripts -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData build -quiet 2>&1 | grep -E "error:" || true

# run <language> <region> <commands…>: the demo in that language and region; the snapshots end up in $raw.
run() {
  local language=$1 region=$2
  shift 2
  printf '%s\n' "wait 3" "$@" "wait 1" "quit" > "$tour"
  DEMO_ARGS="-AppleLanguages ($language) -AppleLocale ${language}_$region" SKIP_BUILD=1 zsh Tools/screenshots/run.sh "$tour" > /dev/null
  cp build/screens/out/*.png "$raw/"
}

scenes() {
  local theme=$1
  print -l "appearance $theme" "wait 1.5" \
    "select m-sync" "wait 2" "snapframe main meeting-$theme" \
    "section people" "wait 3" "snapframe main people-$theme" \
    "naming" "wait 2.5" "snapframe main naming-$theme" "closeoverlay" "wait 1" \
    "section meetings" "select m-sync" "wait 1.5" "clickid github.open" "wait 3" "snapframe main github-$theme" "wait 1.5" \
    "clickid github.close" "wait 1"
}

echo "English, light and dark…"
run en US "${(@f)$(scenes light)}" "${(@f)$(scenes dark)}" \
  "appearance light" "live" "wait 2.5" "snapframe live live-light" "floating" "wait 1.5" "snapwindow floating floating-light" \
  "menubar" "wait 1.5" "snapwindow MenuBar menubar-light" \
  "appearance dark" "wait 1.5" "snapframe live live-dark" "snapwindow floating floating-dark" "snapwindow MenuBar menubar-dark"

for place in de_DE fr_FR uk_UA; do
  language=${place%_*}
  echo "The meeting in $language…"
  run $language ${place#*_} "appearance light" "wait 1" "select m-sync" "wait 2" "snapframe main meeting-light-$language"
done

echo "Laying out…"
python3 Tools/readme-images/build.py "$raw"
