#!/usr/bin/env bash
# Builds a universal, ad-hoc-signed Blackout.app and zips it for a GitHub release.
#   Scripts/release.sh   ->  build/release/Blackout-<version>.zip (+ prints its SHA-256)
set -euo pipefail
cd "$(dirname "$0")/.."

# A release has to match a commit, so refuse to build from uncommitted changes.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit or stash your changes before building a release" >&2
  exit 1
fi

version=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
xcodegen generate >/dev/null
# Build from scratch: Xcode leaves files removed from the project in the built app.
rm -rf build/release-derived
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release \
  -derivedDataPath build/release-derived ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- build -quiet

out=build/release
rm -rf "$out"; mkdir -p "$out"
zip="$out/Blackout-$version.zip"
ditto -c -k --keepParent build/release-derived/Build/Products/Release/Blackout.app "$zip"
lipo -archs build/release-derived/Build/Products/Release/Blackout.app/Contents/MacOS/Blackout
echo "$zip"
shasum -a 256 "$zip"
