#!/bin/zsh
# Takes the iPhone's pictures for the website: PictureTests runs the demo in English on the "Transcripts iPhone"
# simulator, once light and once dark, and the screenshots land in build/readme-images/raw as
# iphone-<name>-<theme>.png, next to the Mac's. Tools/readme-images.sh runs it before it lays out the website's pictures.
#   Tools/iphone-images.sh
set -e
cd "$(dirname "$0")/.."
raw=build/readme-images/raw
mkdir -p "$raw"

for theme in light dark; do
  # TEST_RUNNER_ passes the variables on to the tests: English, the theme, and the pictures instead of a skip.
  TEST_RUNNER_TR_LANGUAGE=en TEST_RUNNER_TR_APPEARANCE=$theme TEST_RUNNER_TR_PICTURES=1 Tools/test-ios.sh iphone PictureTests/testPictures > /dev/null 2>&1 \
    || echo "The iPhone pictures ($theme) failed; see build/test-results/iPhone.xcresult" >&2
  for file in build/test-results/iPhone/iphone-*.png(N); do
    cp "$file" "$raw/${file:t:r}-$theme.png"
  done
done
ls "$raw"/iphone-*.png
