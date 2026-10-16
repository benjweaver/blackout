#!/usr/bin/env bash
# Records the top of the screen in the macOS 27 VM while macOS moves, hides, and fades
# the menu bar (Mission Control, App Exposé, Show Desktop, full screen in and out, its
# menu bar revealed, Space switches, Notification Center) on a range of wallpapers, with
# "Show menu bar background" on, and prints when anything but black shows.
#   Scripts/vm-transitions/run.sh [wallpaper ...]
# Wallpapers are names of the generated solid colors (black darkgreen midgray lightgray
# red yellow cyan white) or paths to images in the guest; with none, it runs them all
# plus two of Apple's photos. Results, with a contact sheet of every transition, go to
# build/vm-transitions/<wallpaper>/.
#
# Needs the "macOS 27" VM running with `ssh macos27` working and the GUI helper at
# /usr/local/bin/gui in the guest (see the VM notes in agent-guides). The VM displays
# have no notch, so the notch row and Mission Control's notch bar still need a check on
# a notched Mac.
set -euo pipefail
cd "$(dirname "$0")/../.."
here=Scripts/vm-transitions
out=build/vm-transitions
tools=$out/tools
mkdir -p "$tools" "$out/walls"

if [ $# -eq 0 ]; then
  set -- black darkgreen midgray lightgray red yellow cyan white \
    "/System/Library/Desktop Pictures/Sonoma.heic" "/System/Library/Desktop Pictures/Mac Blue.heic"
fi

# The guest has no developer tools, so everything is built here.
xcodegen generate >/dev/null
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/vm-derived build -quiet
for tool in setup walls timeline stack; do
  swiftc -O -target arm64-apple-macos14.0 "$here/tools/$tool.swift" -o "$tools/$tool"
done
"$tools/walls" "$out/walls"

ssh macos27 'mkdir -p ~/vm-transitions/walls; osascript -e "tell application \"Blackout\" to quit" 2>/dev/null; rm -rf ~/vm-transitions/Blackout.app'
scp -q "$tools/setup" "$here"/guest/*.sh macos27:vm-transitions/
scp -q "$out"/walls/*.png macos27:vm-transitions/walls/
scp -rq build/vm-derived/Build/Products/Release/Blackout.app macos27:vm-transitions/
ssh macos27 'osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to true"
  open -a Terminal; open ~/vm-transitions/Blackout.app; sleep 4'

for wall in "$@"; do
  case "$wall" in
    /*) guest="$wall" ;;
    *) guest="/Users/dev/vm-transitions/walls/$wall.png" ;;
  esac
  name=$(basename "$wall" | sed 's/\.[a-z]*$//' | tr -d ' ')
  ssh macos27 "cd ~/vm-transitions && ./setup \"$guest\" && sleep 2 && ./transitions.sh" >/dev/null
  rm -rf "${out:?}/$name"; mkdir -p "$out/$name/frames"
  scp -q 'macos27:/tmp/rec/*' "$out/$name/frames/"
  mv "$out/$name/frames/marks" "$out/$name/marks"
  cp "$out/$name/marks" "$out/$name/frames/marks"
  echo "== $name"
  "$tools/timeline" "$out/$name/frames" | tee "$out/$name/timeline.txt"
  # A contact sheet per transition: the frames from its mark to 0.8 s later.
  while read -r time label; do
    frames=$(ls "$out/$name/frames" | grep png | awk -F. -v t="$time" '($1 + $2 / 1000) >= t && ($1 + $2 / 1000) <= t + 0.8' \
      | sed "s|^|$out/$name/frames/|")
    [ -n "$frames" ] && "$tools/stack" "$out/$name/$label.png" $frames
  done < "$out/$name/marks"
done
echo "Contact sheets: $out/<wallpaper>/<transition>.png"
