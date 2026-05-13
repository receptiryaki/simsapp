# Changelog

All notable changes to Sims are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial public release.
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
- Swift 6 strict-concurrency errors at the picker's activate /
  refresh hops in `SimulatorTabController`.
