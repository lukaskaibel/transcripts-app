#!/bin/bash
# Renders the Icon Composer documents into the pictures the app offers in Settings and the README shows.
#   swift Tools/make-icon.swift && Tools/render-icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
resources=Packages/TranscriptsKit/Sources/TranscriptsKit/Resources
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$resources"

# render <document> <rendition> <output>: the icon at Dock proportions.
render() {
  "$ictool" "$1" --export-image --output-file "$work/full.png" --platform macOS --rendition "$2" \
    --width 1024 --height 1024 --scale 1 >/dev/null
  swift Tools/pad-icon.swift "$work/full.png" "$3"
}

render Transcripts/AppIcon.icon Default "$work/light.png"
render Transcripts/AppIcon.icon Dark "$work/dark.png"
render Design/AppIcon-Indigo.icon Default "$work/indigo.png"
swift Tools/pad-icon.swift --split "$work/light.png" "$work/dark.png" "$work/automatic.png"

for name in automatic light dark indigo; do
  sips -z 512 512 "$work/$name.png" --out "$resources/icon-$name.png" >/dev/null
done
sips -z 256 256 "$work/light.png" --out Design/icon.png >/dev/null
sips -z 256 256 "$work/dark.png" --out Design/icon-dark.png >/dev/null
sips -z 256 256 "$work/indigo.png" --out Design/icon-indigo.png >/dev/null
echo "Rendered the icons into $resources and Design/."
