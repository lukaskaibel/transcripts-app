#!/bin/bash
# Uploads the iPhone and iPad app to TestFlight: archives the Release build for iOS and has Xcode sign it for the App
# Store and upload it to App Store Connect. The build number is the number of commits, so an upload from a later commit
# gets a higher one (0.1.0 (40) was commit 79ad971). It needs the team in Config/Local.xcconfig (whose TR_ICLOUD goes
# into the build too) and an Apple account with App Store Connect access in Xcode › Settings › Accounts. The uploaded
# archive is copied to Xcode's Organizer, where the next run looks up the last build number.
#   Tools/testflight.sh                   archive and upload
#   Tools/testflight.sh --archive-only    only the archive, in build/Transcripts-iOS.xcarchive; nothing is uploaded
set -euo pipefail
cd "$(dirname "$0")/.."

upload=1
case "${1:-}" in
  "") ;;
  --archive-only) upload=0 ;;
  *) echo "Usage: Tools/testflight.sh [--archive-only]" >&2; exit 2 ;;
esac

if [ ! -f Config/Local.xcconfig ]; then
  echo "Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example and enter your Apple Developer team." >&2
  exit 1
fi
setting() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]*).*/\1/p" Config/Local.xcconfig | tail -1
}
team=$(setting DEVELOPMENT_TEAM)
if ! [[ $team =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Config/Local.xcconfig has no DEVELOPMENT_TEAM (your team's ten-character ID)." >&2
  exit 1
fi
if [ "$(setting TR_ICLOUD)" = YES ]; then icloud=on; else icloud=off; fi

# Every upload needs a higher build number than the one before: 40 was the first, the archives in the Organizer
# remember the later ones.
build=$(git rev-list --count HEAD)
last=40
for archive in "$HOME"/Library/Developer/Xcode/Archives/*/"Transcripts iOS "*.xcarchive; do
  [ -e "$archive" ] || continue
  number=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive/Info.plist" 2>/dev/null || true)
  if [[ $number =~ ^[0-9]+$ ]] && [ "$number" -gt "$last" ]; then last=$number; fi
done
commit=$(git rev-parse --short HEAD)
branch=$(git branch --show-current)
echo "Build $build from commit $commit${branch:+ on $branch}, iCloud $icloud. Last uploaded build: $last."
if [ "$upload" = 1 ]; then
  if [ "$build" -le "$last" ]; then
    echo "Build $build isn't higher than $last. Upload from a later commit." >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "There are uncommitted changes. Commit them first, so that build $build is commit $commit." >&2
    exit 1
  fi
fi

# The errors from a failed step. Without an Apple account in Xcode, signing and uploading fail with "No Accounts" or
# "App Store Connect access for … is required".
explain() {
  grep -E 'error:|\*\* [A-Z ]+ FAILED' "$1" | awk '!seen[$0]++' | head -20 >&2 || true
  if grep -q -E 'No Accounts|App Store Connect access' "$1"; then
    echo "Sign in under Xcode › Settings › Accounts, with an Apple account that has App Store Connect access to the team." >&2
  fi
  echo "The whole log: $1" >&2
}

mkdir -p build
archive=build/Transcripts-iOS.xcarchive
rm -rf "$archive" build/export-ios
echo "Archiving…"
if ! xcodebuild archive -project Transcripts.xcodeproj -scheme Transcripts -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/DerivedData-archive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" > build/testflight-archive.log 2>&1; then
  echo "The archive failed." >&2
  explain build/testflight-archive.log
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$archive/Info.plist")
if [ "$upload" = 0 ]; then
  echo "Archived $version ($build) in $archive. Nothing was uploaded."
  exit 0
fi

# How Xcode signs the archive for the App Store and uploads it; the build number stays the one above.
options=build/ExportOptions-TestFlight.plist
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$team</string>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

echo "Uploading $version ($build) to App Store Connect…"
if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath build/export-ios \
  -allowProvisioningUpdates > build/testflight-upload.log 2>&1; then
  echo "The upload failed." >&2
  explain build/testflight-upload.log
  exit 1
fi

# In the Organizer for crash reports, and for the next run's check.
organizer="$HOME/Library/Developer/Xcode/Archives/$(date +%F)/Transcripts iOS $version ($build).xcarchive"
mkdir -p "$(dirname "$organizer")"
rm -rf "$organizer"
ditto "$archive" "$organizer"
echo "Uploaded $version ($build). App Store Connect processes it for a few minutes, then it's in TestFlight."
