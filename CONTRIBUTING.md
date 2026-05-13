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

## Bug reports

Use the **Bug report** issue template. Include your macOS version,
Xcode version, the simulator runtime you were targeting, and any
relevant `.ips` crash reports from `~/Library/Logs/DiagnosticReports/`.
