#!/bin/zsh
# Builds the app, starts it on the demo data and has it render its own windows to PNGs.
#   Tools/screenshots/run.sh [command-file]
# The commands (see DebugRemote.swift) come from the given file, or a standard tour.
# Works while the screen is locked: the app draws into images itself. BACKGROUND=1 starts it without taking the focus
# (for working on the Mac meanwhile).
set -e
cd "$(dirname "$0")/../.."
out=build/screens/out
app=build/DerivedData/Build/Products/Debug/Transcripts.app
mkdir -p "$out"
rm -f "$out"/*.png(N) "$out"/debug.log

if [ -z "$SKIP_BUILD" ]; then
  xcodebuild -project Transcripts.xcodeproj -scheme Transcripts -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData build -quiet 2>&1 | grep -E "error:" | grep -v "produced no further output" || true
fi

# Only an earlier demo run; a copy of the app someone is using stays open.
pkill -f "$app/Contents/MacOS/Transcripts -demo YES" 2>/dev/null || true
sleep 0.5
cmd=build/screens/cmd
: > "$cmd"
open ${BACKGROUND:+-g} -n "$app" --args -demo YES -debugCommandFile "$PWD/$cmd" -debugOutput "$PWD/$out" ${=DEMO_ARGS} \
  "-NSWindow Frame MainWindow" "100 80 1280 820 0 0 1512 949"
sleep 3

send() { echo "$1" >> "$cmd"; sleep ${2:-1.2}; }

if [ -n "$1" ]; then
  while IFS= read -r line; do
    [[ "$line" == wait* ]] && { sleep ${line#wait }; continue; }
    send "$line"
  done < "$1"
else
  send "snap 01-list"
  send "select m-sync"
  send "snap 02-detail"
  send "palette"
  send "snap 03-palette"
  send "closeoverlay"
  send "section people"
  send "snap 04-people"
  send "section meetings"
  send "appearance dark"
  send "select m-sync"
  send "snap 05-detail-dark"
  send "appearance light"
  send "settings ai" 2
  send "snapwindow settings 06-settings-ai"
  send "live" 2
  send "snapwindow live 07-live"
  send "floating" 1.5
  send "snapwindow floating 08-floating"
  send "menubar" 1.5
  send "snapwindow MenuBar 09-menubar"
  send "windows"
  send "quit" 0.5
fi
ls "$out"
