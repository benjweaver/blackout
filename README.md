# Blackout

A free, open-source, telemetry-free menu bar app that hides the MacBook notch by
drawing a black bar behind the menu bar. Native AppKit, no network code, no analytics.

- **Show black bar on:** MacBook display only, or all displays (so every menu bar looks the same).
- Works with dynamic wallpapers, multiple displays, and Spaces: it draws behind the menu bar rather than editing your wallpaper, so nothing needs regenerating.
- Rounded desktop corners at the top and bottom, like the display's own. On by default; you can turn them off.
- Open at login, and an option to hide the menu bar icon entirely for set-and-forget use. With the icon hidden, open Blackout from Applications again to bring the settings window back.

Blackout draws beneath the menu bar, so it needs the menu bar to be see-through. With
**Reduce transparency** on (System Settings → Accessibility → Display), macOS draws an opaque
menu bar over it and the notch stays visible. The settings window says so when that's the case.

## Install

```sh
brew install --cask benjweaver/blackout/blackout
```

Blackout isn't notarized yet, so the cask clears the download quarantine flag on
install. Or download `Blackout-<version>.zip` from Releases. macOS blocks the first
open, so go to System Settings → Privacy & Security and click Open Anyway.

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Blackout.app
```

Requires macOS 14+. Licensed GPL-3.0-or-later.

## Support

Blackout is free. If it's useful, you can [support its development](https://benjweaver.dev/support/blackout).

## Icon

`swift Scripts/make-icon.swift` regenerates the app icon from code.

## Release

Bump the version in `project.yml`, add its section to `CHANGELOG.md`, then commit and
push. `Scripts/release.sh` does the rest: it builds a universal, ad-hoc-signed zip,
publishes it as a GitHub release with that changelog section as the notes, and points the
[Homebrew tap](https://github.com/benjweaver/homebrew-blackout) at it.
