#!/usr/bin/env bash
# Releases the version in project.yml in one step: builds a universal Blackout.app,
# signs it with the Developer ID and has Apple notarize it, publishes it as a GitHub
# release with its CHANGELOG.md section as the notes, and points the Homebrew tap at it.
#   Scripts/release.sh
# Notarizing uses the credentials saved as the notarytool profile "notary" (see
# Release in the README).
set -euo pipefail
cd "$(dirname "$0")/.."

repo=benjweaver/blackout
tap=benjweaver/homebrew-blackout
team=AR25V66TVY
identity="Developer ID Application: Ben Weaver ($team)"
notary_profile=notary

# The release is tagged at the commit it's built from, so that commit has to be
# committed and pushed.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit or stash your changes before releasing" >&2
  exit 1
fi
git fetch -q origin main
commit=$(git rev-parse HEAD)
if [ "$commit" != "$(git rev-parse origin/main)" ]; then
  echo "error: HEAD isn't origin/main; push main (or check it out) before releasing" >&2
  exit 1
fi

version=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
tag="v$version"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "error: $tag is already released; bump the version in project.yml" >&2
  exit 1
fi
notes=$(awk -v version="$version" '
  index($0, "## [" version "]") == 1 { on = 1; next }
  /^## \[/ || /^\[/ { on = 0 }
  on
' CHANGELOG.md)
if ! grep -q '[^[:space:]]' <<<"$notes"; then
  echo "error: CHANGELOG.md has no section for $version" >&2
  exit 1
fi
# Signing and notarizing come after the build, so check both can work before it.
if ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  echo "error: \"$identity\" isn't in the keychain" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null; then
  echo "error: the notarytool profile \"$notary_profile\" doesn't work; see Release in the README" >&2
  exit 1
fi

xcodegen generate >/dev/null
# Build from scratch: Xcode leaves files removed from the project in the built app.
rm -rf build/release-derived
# Notarization requires the hardened runtime and a secure timestamp, and refuses the
# debugging entitlement that Xcode otherwise adds to a plain build.
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/release-derived \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp build -quiet

app=build/release-derived/Build/Products/Release/Blackout.app
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/Blackout" -verify_arch "$arch" ||
    { echo "error: the build is missing $arch" >&2; exit 1; }
done
codesign --verify --deep --strict "$app"
out=build/release
rm -rf "$out"; mkdir -p "$out"
zip="$out/Blackout-$version.zip"

# Notarize, then staple the ticket to the app, so Gatekeeper needn't look it up
# online, and zip the stapled app for the release.
ditto -c -k --keepParent "$app" "$zip"
result=$(xcrun notarytool submit "$zip" --keychain-profile "$notary_profile" --wait --output-format json)
if [ "$(plutil -extract status raw -o - - <<<"$result")" != Accepted ]; then
  echo "error: notarization failed: $result" >&2
  echo "details: xcrun notarytool log $(plutil -extract id raw -o - - <<<"$result") --keychain-profile $notary_profile" >&2
  exit 1
fi
xcrun stapler staple -q "$app"
spctl --assess --type execute "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"

gh release create "$tag" "$zip" --repo "$repo" --target "$commit" --title "Blackout $version" \
  --notes "$notes

Universal (Apple silicon and Intel), macOS 14 or later. Signed with a Developer ID and notarized by Apple."

# Point the tap at the new release. The push starts the tap's install test.
tapdir=$(mktemp -d)
trap 'rm -rf "$tapdir"' EXIT
gh repo clone "$tap" "$tapdir" -- -q
bash "$tapdir/scripts/update-cask.sh" "$tag"
if git -C "$tapdir" diff --quiet; then
  echo "The tap already points at $tag."
else
  git -C "$tapdir" commit -qam "blackout $version"
  git -C "$tapdir" push -q
  echo "Pointed $tap at $tag; its install test is running."
fi
