# Conventions

Project-specific Swift style and code-quality rules.

## Swift style

- **Swift 6, strict concurrency on.** Every file is compiled with
  `-strict-concurrency=complete`. Types that bridge ObjC runtime
  state are typically `final class … @unchecked Sendable` with an
  explicit `NSLock` for the mutating surface.
- **`final` by default** on classes. The only non-final classes are
  `NSWindowController` / `NSViewController` subclasses, which AppKit
  may itself subclass via NIBs (we don't use NIBs here but keep the
  convention).
- **Value types in Domain.** `struct`s for `Point`, `Size`,
  `Insets`, `Rect`, `HIDUsage`, gesture types. `enum`s for state
  (`SimulatorState`, `GesturePhase`, `DeviceEdge`).
- **No force-unwraps in production code.** Optional binding or
  graceful return. The one exception is `try!` against
  `JSONSerialization` when serialising a dict whose shape we built
  ourselves (it can't fail).
- **Underscore-prefixed locals are banned.** Use plain
  `eventMask`, not `_eventMask`. The codebase doesn't have any.

## Naming

The protocol-naming rules below are a deliberate choice, not mere
style:

- **Port protocols are named for their domain role**,
  not their architectural pattern. Look at what exists: `Simulator`,
  `Simulators`, `Input`, `Screen`, `DeviceHost`. **The words `Port`,
  `Service`, `Manager` never appear**, and you're not adding them.
- The **carve-out for `Repository`-shaped collections** is the plural
  of the aggregate noun: `Simulators` is the repository of
  `Simulator`. Not `SimulatorRepository`. The suffix is the
  pluralisation, not a label.
- Concrete impls take a descriptive prefix: `CoreSimulators` (the
  CoreSimulator-backed `Simulators`), `SimulatorKitScreen` (the
  SimulatorKit-backed `Screen`), `IndigoHIDInput` (the IndigoHID-backed
  `Input`).
- Hand-rolled test fakes are `FakeXxx` and live in `Tests/`. If we
  later pull in a mocking library, its generated types should
  follow the `MockXxx` convention.

## Error handling

- **`enum XxxError: Error, Equatable`** per bounded context.
  `SimulatorError`, `ScreenError`, `InputError`. Each case maps to
  exactly one human-readable line; no associated values unless they
  carry diagnostic data we'd actually show.
- **`throws` at the boundary** (`Simulator.boot()`,
  `Screen.start(onFrame:)`), **`-> Bool` for low-level dispatch**
  (`Input.tap(at:size:duration:)`). The boundary the user sees throws;
  the inner dispatcher signals success without giving the caller a
  policy decision they can't make.
- **`logErr(_:)`** for unexpected `NSError` from ObjC-runtime calls.
  Don't `print`; don't `os_log` unless we standardise on it later.
  Implementation: `fputs("[sims] \(message)\n", stderr)`.

## Comments

- **Comment the WHY when the WHAT is private API.** Every ObjC
  selector string, every `dlsym` symbol, every byte offset is a
  contract we don't control. If you discover one experimentally,
  *write the receipt down right next to the code* — what you tried,
  what you observed, why this is the value.
- **Don't comment the WHAT** when the WHAT is plain Swift.
  `// loop over devices` next to `for device in devices` is noise.
- **Don't write changelog-style comments** in code (`// fixed in
  v0.3`, `// added for issue #42`). That belongs in commit messages.

## Logging

- One namespaced prefix: `[sims]`.
- Tag the subsystem: `[sims:sim] …`, `[sims:hid] …`,
  `[sims:fb] …`.
- Log irreversible state transitions (boot started, boot succeeded,
  boot failed, framebuffer attached, framebuffer torn down) and
  unexpected failures. Don't log every gesture; the volume is too
  high.

## Testing

We **do not yet require TDD**. We're starting with a shape that's
harder to unit-test end-to-end (AppKit app talking to private
frameworks). The rule for v1 is:

- **Pure Domain types ship with tests.** Anything in `Domain/`
  (gesture parsers, value types, state mappings) gets a Swift
  Testing (`@Suite`, `@Test`, `#expect`) suite under
  `Tests/SimsTests/`.
- **Infrastructure adapters are integration-only** unless they have
  a non-trivial pure orchestration layer that can be lifted into
  Domain. If they do (a state machine, a byte-buffer flusher), lift
  it and unit-test the pure piece separately.
- **No XCTest.** Swift Testing only.
- **No mocks if we don't need them.** Fakes (small hand-rolled
  conforming types) are fine. A mocking library only lands if we
  have enough abstractions to justify the macro.

The TDD bar may rise once we have shape — once the architecture is
stable, requiring a failing test before code is reasonable. Until then
we're optimising for getting to a working spike.

## Git

- **Conventional commits**: `feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `chore:`. Scope optional and short: `feat(boot):`,
  `feat(hid):`, `fix(fb):`.
- **Per-phase commits**: a phase commits as one tidy unit (multiple
  commits inside the phase are fine, but everything in the phase ships
  before moving on).
- **Never `--amend`**, **never force-push**, **never add
  `Co-Authored-By` lines**. (See the global instructions in the user's
  `~/.claude/CLAUDE.md`.)
- **Never commit without explicit confirmation.** Even after a bug fix
  follow-up. Stop and ask.

## File length

No hard cap. `IndigoHIDInput.swift` and `IOHIDDigitizerDispatch.swift`
will sit in the multi-hundred-lines range because the IndigoHID recipe
genuinely doesn't decompose cleanly. Don't split files just to hit a
line count.

## What goes in `Domain/` vs `Infrastructure/`

A quick test: **can you compile and test this file with `import
Foundation` and nothing else?** If yes, it's Domain. If it needs
`import ObjectiveC` for `NSClassFromString`, or `import IOSurface`'s
private siblings, or `dlopen`, or AppKit, it's Infrastructure.

`IOSurface` itself is the one exception — it's public, and exposing it
at the Domain boundary (`Screen.start(onFrame:)`) saves us a copy at
the layer boundary.
