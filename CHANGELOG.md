# Changelog

All notable changes to Sims are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- File → New Simulator… (⌘N) dialog to create devices via
  `simctl create`. The form filters device types by the runtime's
  `supportedDeviceTypes`.
- Recent simulators section in the picker, persisted in
  `UserDefaults` and bumped on activation.
- Record toolbar button next to Screenshot — wraps
  `simctl io recordVideo`, finalises the MOV on stop via SIGINT,
  and reveals the file in Finder.
- Touch ring overlay in the stream view: a circle follows the
  pointer during click / drag so viewers and screen recordings
  can see where the user is pressing.
- Forward ⌘+key chords (Cmd+C/V/A/X/Z, etc.) into the running
  simulator. App-level shortcuts (⌘Q/W/T/N/H/M, ⌘⇧H, ⌘⇧]/[, ⌘`)
  stay on macOS.
- `acceptsFirstMouse` on the stream view so the first click on an
  inactive window dispatches as a touch instead of just focusing
  the window.

### Fixed

- Shifted symbols (`@`, `#`, `$`, etc.) now type into the
  simulator. `charactersIgnoringModifiers` still applies Shift,
  so Shift+2 was mapping to `@` and falling through; switched to
  `characters(byApplyingModifiers: [])` to recover the base key.

## [0.1.1] - 2026-05-14

### Fixed

- Release builds now use the macOS 26 SDK so the shipped `.app`
  renders with Liquid Glass on macOS 26 hosts. CI was pinned to
  the `macos-15` runner (macOS 15 SDK, Xcode 16), which gates the
  app out of the new design language. Both `release.yml` and
  `build.yml` now run on `macos-26` (Xcode 26.2).

## [0.1.0] - 2026-05-14

### Added

- Initial public release.
- Tag-driven release pipeline at `.github/workflows/release.yml`:
  pushing a `v*` tag signs with Developer ID, notarises via
  App Store Connect API, staples, and publishes a GitHub Release
  with notes lifted from this file.
- `MARKETING_VERSION` lives in `Sims/Sims.xcconfig` as the single
  source of truth; the CI release workflow refuses to ship a tag
  that disagrees with it.

### Fixed

- Swift 6 strict-concurrency errors at the picker's refresh / boot
  / shutdown hops in `SimulatorTabController` — restructured the
  detached-Task callbacks so `self` stays on `@MainActor`.

[Unreleased]: https://github.com/receptiryaki/simsapp/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/receptiryaki/simsapp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/receptiryaki/simsapp/releases/tag/v0.1.0
