#!/bin/bash
# Runs the UI tests of the iPhone and iPad app on the demo mode's made-up meetings, on one iPhone and one iPad
# simulator (created on first use, so the simulators of other projects are left alone). The screenshots each test
# takes end up in build/test-results/<device>/.
#   Tools/test-ios.sh                    both devices
#   Tools/test-ios.sh iphone             only the iPhone
#   Tools/test-ios.sh ipad PhoneTests/testOnboarding    one test (as for -only-testing)
set -euo pipefail
cd "$(dirname "$0")/.."

runtime=$(xcrun simctl list runtimes | awk '/^iOS 27/ { id = $NF } END { print id }')
if [ -z "$runtime" ]; then
  echo "No iOS 27 simulator runtime. Install it in Xcode › Settings › Components." >&2
  exit 1
fi

simulator() {
  local name=$1 type=$2
  local id
  id=$(xcrun simctl list devices | awk -v name="$name" -F '[()]' '$0 ~ "    " name " \\(" { print $2; exit }')
  if [ -z "$id" ]; then id=$(xcrun simctl create "$name" "$type" "$runtime"); fi
  echo "$id"
}

mkdir -p build/test-results

# A fresh simulator shows a tip over the keyboard the first time it appears, which would cover the keys.
prepare() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl spawn "$1" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
  xcrun simctl status_bar "$1" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
}

run() {
  local label=$1 id=$2 only=${3:-}
  echo "UI tests on $label…"
  prepare "$id"
  rm -rf "build/test-results/$label.xcresult" "build/test-results/$label"
  local filter=()
  if [ -n "$only" ]; then filter=(-only-testing:"TranscriptsUITests/$only"); fi
  local status=0
  xcodebuild test -project Transcripts.xcodeproj -scheme TranscriptsUITests \
    -destination "platform=iOS Simulator,id=$id" -derivedDataPath build/DerivedData-ios -collect-test-diagnostics never \
    -resultBundlePath "build/test-results/$label.xcresult" -quiet ${filter[@]+"${filter[@]}"} || status=$?
  # The screenshots, named after the step that took them.
  xcrun xcresulttool export attachments --path "build/test-results/$label.xcresult" --output-path "build/test-results/$label" >/dev/null 2>&1 || true
  python3 - "build/test-results/$label" <<'PY'
import json, os, sys
folder = sys.argv[1]
manifest = os.path.join(folder, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "").split("_")[0].replace("/", "-")
            source = os.path.join(folder, attachment["exportedFileName"])
            extension = os.path.splitext(attachment["exportedFileName"])[1]
            if name and os.path.exists(source) and not name.endswith(extension):
                os.replace(source, os.path.join(folder, name + extension))
PY
  return $status
}

device=${1:-all}
only=${2:-}
failed=0
case "$device" in
  iphone) run iPhone "$(simulator 'Transcripts iPhone' 'iPhone 17 Pro')" "$only" || failed=1 ;;
  ipad) run iPad "$(simulator 'Transcripts iPad' 'iPad Pro 13-inch (M5)')" "$only" || failed=1 ;;
  *)
    # Both devices, even when the first fails, so one run shows everything.
    run iPhone "$(simulator 'Transcripts iPhone' 'iPhone 17 Pro')" "$only" || failed=1
    run iPad "$(simulator 'Transcripts iPad' 'iPad Pro 13-inch (M5)')" "$only" || failed=1
    ;;
esac
if [ "$failed" != 0 ]; then
  echo "Some tests failed; the result bundles in build/test-results say which (open them in Xcode)." >&2
  exit 1
fi
echo "All tests passed. Screenshots: build/test-results"
