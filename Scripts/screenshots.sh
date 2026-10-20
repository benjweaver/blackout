#!/usr/bin/env bash
# Retakes the README screenshots from the latest Blackout release, in the "macOS 27" UTM VM:
# the settings window in dark (docs/screenshots/blackout-settings.png) and light
# (docs/screenshots/blackout-settings-light.png).
#   Scripts/screenshots.sh
# It installs the cask from benjweaver/homebrew-blackout, as Homebrew would, so the shots
# match what people get. Set APP=/path/to/Blackout.app to shoot a local build instead, such
# as an unreleased fix.
#
# Needs the "macOS 27" VM with `ssh macos27` working, gh logged in (to read the tap), and
# the agent-guides mac.sh tool (MAC_SH overrides its path). Scripts/release.sh runs this
# after each release; SKIP_SCREENSHOTS=1 skips that. The VM's appearance and desktop icons
# are put back afterward, and the VM is shut down if this script started it. Blackout stays
# installed in the VM.
set -euo pipefail
cd "$(dirname "$0")/.."

MAC_SH=${MAC_SH:-$HOME/Dev/agent-guides/machines/bens-macbook-pro/tools/mac.sh}
host=${HOST:-macos27}
tap=benjweaver/homebrew-blackout
cask=blackout
app=Blackout
out=docs/screenshots
tmp=$(mktemp -d)

cleanup() {
  "$MAC_SH" restore || true
  "$MAC_SH" down || true
  rm -rf "$tmp"
}
trap cleanup EXIT

"$MAC_SH" up

if [ -n "${APP:-}" ]; then
  # A local build: zip it, copy it over, and check the copy's SHA-256 against ours.
  name=$(basename "$APP" .app)
  zip="$tmp/$name.zip"
  ditto -c -k --keepParent "$APP" "$zip"
  sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
  echo "Installing the local build $APP"
  scp -q "$zip" "$host:/tmp/blackout-shots.zip"
  remote=$(ssh "$host" 'shasum -a 256 /tmp/blackout-shots.zip' | cut -d' ' -f1)
  [ "$remote" = "$sha" ] || { echo "error: the copy to the VM doesn't match its SHA-256" >&2; exit 1; }
  ssh "$host" "set -e; pkill -TERM -x $name 2>/dev/null || true; sleep 1
    rm -rf /tmp/blackout-shots && mkdir /tmp/blackout-shots
    ditto -x -k /tmp/blackout-shots.zip /tmp/blackout-shots
    sudo rm -rf /Applications/$name.app; sudo ditto /tmp/blackout-shots/$name.app /Applications/$name.app
    rm -rf /tmp/blackout-shots /tmp/blackout-shots.zip"
else
  # The latest release, from the live tap; mac.sh install checks the download's SHA-256.
  read -r url sha version <<<"$("$MAC_SH" cask "$tap" "$cask")"
  echo "Installing $app $version from $tap"
  "$MAC_SH" install "$url" "$sha"
fi

"$MAC_SH" prep light
"$MAC_SH" open "$app"
sleep 5
# Opening Blackout from Applications shows its settings window; a banner may have come back.
"$MAC_SH" prep light
"$MAC_SH" front "$app"
sleep 1

# The settings window is the one titled "Blackout" on the normal layer (0).
id=$("$MAC_SH" windows "$app" | awk -F'\t' '$3 == "Blackout" && $4 == 0 { if (!id) id = $1 } END { print id }')
[ -n "$id" ] || { echo "error: no Blackout settings window is on screen" >&2; exit 1; }

"$MAC_SH" shot "$tmp/blackout-settings-light.png" "$id"
"$MAC_SH" appearance dark
"$MAC_SH" shot "$tmp/blackout-settings.png" "$id"

# Close the window, then quit Blackout.
"$MAC_SH" run "osascript -e 'tell application \"System Events\" to tell process \"Blackout\" to click button 1 of window \"Blackout\"'" || true
"$MAC_SH" quit "$app" || true

mkdir -p "$out"
for f in blackout-settings.png blackout-settings-light.png; do
  cp "$tmp/$f" "$out/$f"
  echo "Wrote $out/$f"
done
