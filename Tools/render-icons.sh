#!/bin/bash
# Renders the Icon Composer document into the PNGs the README shows.
#   swift Tools/make-icon.swift && Tools/render-icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

# render <rendition> <output>: the icon at Dock proportions, 256 px.
render() {
  "$ictool" Transcripts/AppIcon.icon --export-image --output-file "$work/full.png" --platform macOS --rendition "$1" \
    --width 1024 --height 1024 --scale 1 >/dev/null
  swift Tools/pad-icon.swift "$work/full.png" "$work/padded.png"
  sips -z 256 256 "$work/padded.png" --out "$2" >/dev/null
}

render Default Design/icon.png
render Dark Design/icon-dark.png
echo "Rendered Design/icon.png and Design/icon-dark.png."
