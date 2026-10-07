#!/bin/zsh
# Collects every text the app shows, as the Swift compiler sees it, and brings Transcripts/Localizable.xcstrings up to
# date: new texts are added (to be translated), texts no longer in the code are marked stale, translations stay.
#   Tools/localization/extract.sh
# Then translate what's new (Tools/localization/catalog.py todo lists it) and merge it with catalog.py merge.
set -e
cd "$(dirname "$0")/../.."
work=build/localization
rm -rf "$work/strings"
mkdir -p "$work/strings"
# A build of its own, so every file is compiled (and nothing of the normal build is touched).
swift build --package-path Packages/TranscriptsKit --build-path "$work/build" --target TranscriptsKit \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$work/strings" 2>&1 | tail -1
python3 Tools/localization/catalog.py sync "$work/strings"
