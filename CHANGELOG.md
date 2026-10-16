# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each release's notes on GitHub come
from its section below.

## [Unreleased]

### Added

- The notch is hidden on the lock screen, in one of two ways, chosen in a new
  "Lock screen" setting:
  - **Black behind the icons** (the default): while the screen is locked, the
    strip beside the notch turns black, and Apple's Wi-Fi, battery, and input
    source icons still show in it, as they do in the menu bar. Blackout draws
    only black, keyed around the icons, from a private window layer that sits
    above the lock screen. It uses private macOS interfaces and turns itself off
    if they're missing.
  - **Shrink below the camera**: Blackout switches each display with a notch to
    its mode that ends below the camera, so the strip is unlit, then restores the
    original mode on unlock. The mode is set for Blackout only, so macOS restores
    it if Blackout quits.

  Neither applies to the login window at boot or the FileVault unlock screen,
  since Blackout isn't running then. "Leave as is" turns both off.

## [1.1.1] - 2026-10-02

### Changed

- Signed with a Developer ID and notarized by Apple, so macOS opens Blackout
  without a warning, from Homebrew or the zip, and the cask no longer has to
  clear the download's quarantine flag.

## [1.1.0] - 2026-10-02

### Added

- The notch stays hidden in Mission Control and App Exposé. Both draw a strip
  of their own over the menu bar, so on a display with a notch Blackout now
  keeps a second black bar above it, with a gap for Mission Control's + button.
  Displays without a notch keep Mission Control's strip as it is, since it shows
  the Space names there.

## [1.0.2] - 2026-10-01

### Fixed

- Blackout's bar no longer covers the top of full-screen apps on displays
  without a notch, such as external monitors. A full-screen virtual machine's
  menu bar, for example, was hidden behind it.

## [1.0.1] - 2026-09-29

### Added

- A Quit button in the settings window, and ⌘W and ⌘Q, which matter when the
  menu bar icon is hidden.
- With Reduce transparency on, macOS draws an opaque menu bar over Blackout's
  bar. The settings window now says so instead of leaving the notch visible
  without explanation.

### Fixed

- Rounded corners fit native macOS windows with no sliver of wallpaper, and
  they appear on displays without a menu bar too.
- Open at login shows its real status and keeps its error messages.
- The app icon is clean at small sizes.

## [1.0.0] - 2026-09-29

### Added

- Hides the MacBook notch by blacking out the menu bar, on the MacBook display
  only or on all displays.
- Rounded desktop corners at the top and bottom, on by default.
- Open at login, and an option to hide the menu bar icon.
