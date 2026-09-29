# Blackout

A free, open-source, telemetry-free menu bar app that hides the MacBook notch by
drawing a black bar behind the menu bar. Native AppKit, no network code, no analytics.

- **Show black bar on:** MacBook display only, or all displays (so every menu bar looks the same).
- Works with dynamic wallpapers, multiple displays, and Spaces: it draws over the menu bar rather than editing your wallpaper, so nothing needs regenerating.
- Optional rounded corners for the desktop (top and bottom), like the display's own for the desktop, like the display's own.
- Open at login, and an option to hide the menu bar icon entirely for set-and-forget use. With the icon hidden, open Blackout from Applications again to bring the settings window back.

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Blackout.xcodeproj -scheme Blackout -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Blackout.app
```

Requires macOS 14+. Licensed GPL-3.0-or-later.

## Icon

`swift Scripts/make-icon.swift` regenerates the app icon from code.
