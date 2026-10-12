#!/bin/zsh
# Collects every text the app shows, as the Swift compiler sees it, and brings the string catalogs (the app's in
# Transcripts/, the widget extension's in TranscriptsWidgets/) up to date: new texts are added (to be translated), texts
# no longer in the code are dropped, translations stay. The code is compiled twice, for the Mac and for iPhone and iPad,
# since some texts exist on one of them only.
#   Tools/localization/extract.sh
# Then translate what's new (Tools/localization/catalog.py todo lists it) and merge it with catalog.py merge.
set -e
cd "$(dirname "$0")/../.."
work=build/localization
# The compiler writes a file per source it compiles; the files of sources it skips (unchanged) stay valid.
mkdir -p "$work/strings"
# A build of its own, so every file is compiled (and nothing of the normal build is touched).
swift build --package-path Packages/TranscriptsKit --build-path "$work/build" --target TranscriptsKit \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$work/strings" 2>&1 | tail -1
# The same for iPhone and iPad (xcodebuild: SwiftPM alone doesn't build for iOS), with the app target, Shared/ and
# the widget extension.
root=$PWD
mkdir -p "$work/strings-ios"
xcodebuild -project Transcripts.xcodeproj -scheme Transcripts -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/build-ios" build -quiet SWIFT_EMIT_LOC_STRINGS=NO \
  OTHER_SWIFT_FLAGS="\$(inherited) -emit-localized-strings -emit-localized-strings-path $root/$work/strings-ios" 2>&1 \
  | grep -E "error:" | grep -v "produced no further output" || true
python3 Tools/localization/catalog.py sync "$work/strings" "$work/strings-ios"
