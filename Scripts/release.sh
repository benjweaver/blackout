#!/usr/bin/env bash
# Releases the version in project.yml in one step: builds a universal, ad-hoc-signed
# Blackout.app, publishes it as a GitHub release with its CHANGELOG.md section as the
# notes, and points the Homebrew tap at it.
#   Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

repo=benjweaver/blackout
tap=benjweaver/homebrew-blackout

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

xcodegen generate >/dev/null
# Build from scratch: Xcode leaves files removed from the project in the built app.
rm -rf build/release-derived
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/release-derived \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- build -quiet

app=build/release-derived/Build/Products/Release/Blackout.app
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/Blackout" -verify_arch "$arch" ||
    { echo "error: the build is missing $arch" >&2; exit 1; }
done
codesign --verify --deep --strict "$app"
out=build/release
rm -rf "$out"; mkdir -p "$out"
zip="$out/Blackout-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

gh release create "$tag" "$zip" --repo "$repo" --target "$commit" --title "Blackout $version" \
  --notes "$notes

Universal (Apple silicon and Intel), macOS 14 or later. Not notarized: the Homebrew cask clears the download flag, and if you download the zip, allow it once in System Settings → Privacy & Security."

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
