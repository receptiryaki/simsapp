# Contributing to Sims

Thanks for taking the time. This is the short "how to land a PR without
ping-pong" version; the deeper engineering context lives under
[`.claude/`](./.claude/).

## Setup

1. Install **Xcode 26+** — the full app, not just the Command Line
   Tools. Sims uses Xcode's simulator runtimes at runtime.

2. Clone and open the project:

   ```sh
   git clone https://github.com/receptiryaki/simsapp.git
   cd simsapp
   ```

3. Copy the local-config template:

   ```sh
   cp Sims/Local.xcconfig.example Sims/Local.xcconfig
   ```

   Fill in `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` (any
   unique values are fine for local development; Release / notarisation
   needs a real Apple Developer Team ID). `Local.xcconfig` is gitignored
   so your IDs stay on your machine. Without it the project still
   builds the Debug configuration, ad-hoc signed.

## Building

- **In Xcode**: open `Sims.xcodeproj`, hit `⌘R`.
- **From the command line**:

  ```sh
  xcodebuild -project Sims.xcodeproj -scheme Sims \
             -configuration Debug build
  ```

- **A notarised Release build** requires Developer ID + notarytool
  setup; see [`scripts/DISTRIBUTION.md`](./scripts/DISTRIBUTION.md).
  Once configured, `./scripts/release.sh` runs the whole pipeline.

## Code style

[`.claude/conventions.md`](./.claude/conventions.md) is the source of
truth. The highlights:

- Swift 6, strict concurrency on.
- `final class` by default; value types live in `Domain/`.
- Port protocols are named for their domain role — `Simulator`,
  `Input`, `Screen`, `DeviceHost`. The words `Port`, `Service`,
  `Manager` are banned as suffixes.
- Comment the *why*, especially for every private-framework selector,
  byte offset, and `dlsym` symbol. Comments documenting plain Swift
  are noise.
- One namespaced log prefix: `[sims]`, tagged by subsystem
  (`[sims:hid]`, `[sims:fb]`, …).

## Architecture

Three layers — `App` → `Domain` ← `Infrastructure`. Domain depends only
on Foundation + IOSurface and never imports private frameworks; App
composes both. Read
[`.claude/architecture.md`](./.claude/architecture.md) before adding a
new bounded context.

## Reverse-engineering notes

If your change touches CoreSimulator / SimulatorKit / IndigoHID, **add
the receipt to `.claude/knowledge/` in the same PR**. Every selector
name, every `dlsym` symbol, every byte offset is a contract we don't
control — write down what you tried, what you observed, and where you
verified it. Stale notes lie to the next session.

## Commits

Use the [Conventional Commits](https://www.conventionalcommits.org/)
style:

```
feat(hid): route Home through legacy button target
fix(stream): handle multi-display sims by picking largest IOSurface
docs(readme): explain the private-framework caveat
```

Scope is optional but useful (`feat(hid):`, `fix(fb):`,
`refactor(arch):`). Keep subjects under 72 characters in the imperative
mood. The body explains *why*, the diff explains *what*.

## Pull request checklist

- [ ] Builds clean (`xcodebuild build` succeeds).
- [ ] No team IDs, bundle identifiers, certificates, or other
      personal data in tracked files.
- [ ] Any newly-discovered private-framework selector / offset /
      symbol is documented under `.claude/knowledge/`.
- [ ] Commit messages follow Conventional Commits.
- [ ] If the change is user-visible, `CHANGELOG.md`'s `[Unreleased]`
      section has a line for it.

## Cutting a release

Releases are tag-driven and notarised by CI. The full pipeline
(Developer-ID signing, notarytool submission, stapling, GitHub
Release creation) runs in `.github/workflows/release.yml` — local
machines don't need any certificate setup just to ship a version.

The version is **a single value in `Sims/Sims.xcconfig`**:

```
MARKETING_VERSION = 0.1.0
```

`CURRENT_PROJECT_VERSION` tracks it via `$(MARKETING_VERSION)`, and
`Info.plist` reads both via `$(...)` expansion. One edit changes
everything.

### Steps

1. Pick the next version. We use [SemVer](https://semver.org/) —
   `MAJOR.MINOR.PATCH`. Pre-1.0 we treat each minor as a feature
   release and each patch as a fix-only release. A breaking change
   (e.g. dropping an Xcode version) bumps minor while we're still
   on 0.x, or major from 1.0 onwards.

2. Branch and bump:

   ```sh
   git checkout -b release/v0.2.0
   # edit Sims/Sims.xcconfig: MARKETING_VERSION = 0.2.0
   # in CHANGELOG.md: rename `## [Unreleased]` to `## [0.2.0] - YYYY-MM-DD`
   # and add a fresh empty `## [Unreleased]` above it
   # update the link references at the bottom of CHANGELOG.md
   git commit -am "release: v0.2.0"
   git push -u origin release/v0.2.0
   ```

3. Open and merge the PR (squash). Main now reflects the new version.

4. Tag from main and push:

   ```sh
   git checkout main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

5. GitHub Actions takes over. The `Release` workflow:
   - verifies the tag matches `MARKETING_VERSION` in the xcconfig,
   - signs with Developer ID, notarises via the App Store Connect
     API key,
   - staples the ticket onto `Sims.app`,
   - creates a GitHub Release titled `Sims v0.2.0` with the
     `## [0.2.0]` block from `CHANGELOG.md` as the body, and
     `Sims.zip` attached.

   Typical run time: 8–15 minutes (notarytool is the bottleneck).

### If something goes wrong

- **Tag-version mismatch**: the workflow fails fast at the
  "Verify tag matches Sims.xcconfig" step. Either bump the
  xcconfig and re-tag, or delete the tag and re-tag once you've
  picked a consistent version.
- **Notarisation rejection**: the run logs include the notarytool
  submission ID. Pull the developer log with `xcrun notarytool log
  <id> --key ... --key-id ... --issuer ...` (or use the Actions
  log link). Fix the underlying issue (usually a missing
  entitlement or unsigned nested binary), then re-run the
  workflow via the **Run workflow** button on the Actions tab.
- **Need to re-release the same tag**: use the workflow's
  `workflow_dispatch` trigger (manual run with the same tag as
  input). Delete the GitHub Release first if it was partly
  created.

### One-time CI setup

Before the first release, the repo needs six secrets configured —
walked through in [`scripts/DISTRIBUTION.md`](./scripts/DISTRIBUTION.md).

## Bug reports

Use the **Bug report** issue template. Include your macOS version,
Xcode version, the simulator runtime you were targeting, and any
relevant `.ips` crash reports from `~/Library/Logs/DiagnosticReports/`.
