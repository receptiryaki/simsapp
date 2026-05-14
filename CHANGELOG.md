# Changelog

All notable changes to Sims are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/receptiryaki/simsapp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/receptiryaki/simsapp/releases/tag/v0.1.0
