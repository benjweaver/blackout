# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each release's notes on GitHub come
from its section below.

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
