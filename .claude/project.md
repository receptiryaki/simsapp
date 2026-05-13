# Sims — Project Charter

## Goal

A native macOS app that lists iOS simulators on the host, boots them
headlessly, streams their framebuffers, forwards mouse/keyboard input,
and presents each one as its own tab inside a single `NSWindow` via
**native AppKit window tabs** — no custom tab UI, no web view.

## Why native AppKit (not SwiftUI)

`NSWindow` tab management — `allowsAutomaticWindowTabbing`,
`addTabbedWindow(_:ordered:)`, `tabbingMode`, `selectedTab`,
`moveTabToNewWindow:` — is exposed in full to AppKit and is intentionally
under-exposed in SwiftUI. Native tabs are the entire point of the app, so
the right tool is `NSWindowController` + `NSWindow`.

See [`knowledge/appkit-tabs.md`](./knowledge/appkit-tabs.md) for the
specific API surface.

## Tech stack

| Concern | Choice |
|---|---|
| Language | Swift 6 (strict concurrency on) |
| UI | AppKit (`NSWindow`, `NSTableView`, `NSView` + `CALayer`) |
| Target | macOS 15+, Apple Silicon only, Xcode 26 |
| Triple | `arm64e-apple-macos26.0` |
| Frame rendering | `IOSurface` set directly as `CALayer.contents` (zero-copy) |
| Private frameworks | `CoreSimulator`, `SimulatorKit` — loaded at runtime via `dlopen` |
| Public frameworks linked | `IOSurface`, `CoreGraphics`, `VideoToolbox` (only if encoding) |
| Dependencies | None unless strictly necessary |
| App Sandbox | **Disabled** (private frameworks won't load sandboxed) |

The private frameworks are deliberately **not** linked at build time.
Linking would bake `LC_LOAD_DYLIB` entries that fail if the user's Xcode
sits anywhere other than `/Applications/Xcode.app`. Instead, resolve
the Xcode dev dir at runtime, `dlopen` SimulatorKit/CoreSimulator with
`RTLD_NOW | RTLD_GLOBAL`, then reach into them via `NSClassFromString` +
`dlsym`. See [`knowledge/private-frameworks.md`](./knowledge/private-frameworks.md).

## Module layout

```
Sims/
├── App/                       AppKit setup, window controllers, menu, lifecycle
├── Domain/                    Pure Swift — no private framework imports
│   ├── Simulator/             Simulator protocol, SimulatorState enum, SimulatorError
│   ├── Input/                 Gesture types (Tap, Swipe, Touch1, Key, …), Input port
│   └── Screen/                Screen port, IOSurface re-export
└── Infrastructure/
    ├── Simulator/             CoreSimulators / CoreSimulator (CoreSimulator wrapper)
    ├── Screen/                SimulatorKitScreen (framebuffer subscription)
    └── Input/                 IndigoHIDInput + IOHIDDigitizerDispatch (digitizer recipe)
```

Domain has no Apple-private imports. Infrastructure depends on Domain;
Domain never depends on Infrastructure. App composes both.

Full breakdown in [`architecture.md`](./architecture.md).

## Phases

Build in numbered phases. **Do not start a phase before the previous
one is signed off.** Before each phase write a short plan in chat and
wait for OK; after each phase produce a short "what changed" summary
and an acceptance checklist the user can run. See
[`workflow.md`](./workflow.md) for the exact gate rules.

### Phase 1 — List and boot

- AppKit app skeleton: `App/AppDelegate.swift`, main window with
  `NSTableView` (4 columns: name, runtime, UDID, state).
- `CoreSimulators` infra type wrapping `SimServiceContext` +
  `SimDeviceSet` + `SimDevice`. List/boot/shutdown only.
- Per-row Boot / Shutdown buttons; table refreshes on a timer or
  on a state-change notification (whichever exists in CoreSimulator).
- **Acceptance:** every simulator listed; boot works; shutdown works;
  Simulator.app never opens; UDID/name/runtime/state correct.

### Phase 2 — Framebuffer streaming (one simulator)

- Double-click a booted row → opens a plain `NSWindow` (not tabbed yet).
- `SimulatorKitScreen` subscribes to `SimDeviceIOClient`'s framebuffer
  descriptor callbacks. Picks the descriptor with the largest live
  surface area (handles multi-display sims).
- Render via `IOSurface` directly as `CALayer.contents` at native FPS.
- **Acceptance:** live, smooth content; window resize scales correctly;
  multiple sims can stream concurrently in separate windows.

### Phase 3 — Input injection

- Capture mouse down/drag/up and key events in the render `NSView`.
- Translate to taps/swipes/scroll/keys via the digitizer dispatch
  recipe documented in [`knowledge/indigo-hid.md`](./knowledge/indigo-hid.md).
- Coordinates: NSView local → simulator screen-space in **points**
  → normalized [0, 1] for the C function. Top-left origin.
- **Acceptance:** tap, swipe, scroll, and type into the simulator from
  the streaming window. Single-finger touch sequences interpret as
  expected (no spurious Home gestures).

### Phase 4 — Native tabs

- Convert the stream window into a tabbed child of the main window.
- Each new simulator stream opens as a new tab via
  `mainWindow.addTabbedWindow(streamWindow, ordered: .above)`.
- Tab title shows device name.
- `NSWindow.allowsAutomaticWindowTabbing = true`.
- **Acceptance:** multiple simulators visible as tabs in one window;
  instant switching; closing last tab keeps the main list window open.

### Phase 5 — Polish

- Main list reflects boot/shutdown state live.
- Closing a tab prompts: shut down the simulator, or just close the
  tab.
- Handle "already booted by Xcode" — attach to the running device
  instead of re-booting it.
- Acceptance: smooth state transitions; no dangling boot/shutdown
  edges.

## Out of scope (do not build these)

- iPad multi-display rendering / external display simulation
- Drag-and-drop files into the simulator
- Video recording (screenshot ships via `simctl io`)
- Multi-touch beyond a single finger (pinch via two-finger trackpad
  gestures may land later, but isn't in v1)
- A Preferences window
- App Store packaging
- Web UI, headless mode, scripting interface
