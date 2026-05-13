# Architecture

Three-layer split with strictly inward-flowing imports.

```
App   ────▶  Domain
  │           ▲
  └───▶  Infrastructure ──┘
```

- **App** can see Domain and Infrastructure.
- **Infrastructure** can see Domain. It must never import App.
- **Domain** depends only on Foundation + `IOSurface` (a public Apple
  type, so safe to expose at the domain boundary). It must never import
  CoreSimulator, SimulatorKit, AppKit, or any private framework.

## Bounded contexts

`Domain/` and `Infrastructure/` are split into the same context
sub-folders, so a feature lives in one place across both layers:

```
Sims/
├── App/
│   ├── AppDelegate.swift
│   ├── MainWindowController.swift      # the list window
│   ├── StreamWindowController.swift    # one per booted simulator
│   ├── StreamView.swift                # NSView whose CALayer holds the IOSurface
│   ├── InputController.swift           # NSEvent → Gesture
│   └── TabRouter.swift                 # addTabbedWindow / moveTabToNewWindow
│
├── Domain/
│   ├── Simulator/
│   │   ├── Simulator.swift             # protocol, SimulatorState, SimulatorError
│   │   ├── Simulators.swift            # aggregate protocol (list/find)
│   │   └── DeviceHost.swift            # lookup port for live SimDevice NSObject
│   ├── Input/
│   │   ├── Input.swift                 # input port (tap, swipe, touch1, button, key, scroll)
│   │   ├── Gesture.swift               # protocol + Field helpers (if needed)
│   │   ├── Tap.swift / Swipe.swift / Touch1.swift / Key.swift / …
│   │   └── CoordinateTypes.swift       # Point, Size, GesturePhase, DeviceEdge, HIDUsage
│   └── Screen/
│       └── Screen.swift                # screen port (start(onFrame:) / stop)
│
└── Infrastructure/
    ├── Simulator/
    │   ├── CoreSimulators.swift        # Simulators impl + DeviceHost impl + ObjC helpers
    │   └── CoreSimulator.swift         # one Simulator instance; verbs delegate via DeviceHost
    ├── Screen/
    │   └── SimulatorKitScreen.swift    # io / deviceIOPorts / registerScreenCallbacks
    └── Input/
        ├── IndigoHIDInput.swift        # Input impl; warm SimDeviceLegacyHIDClient; route gestures
        └── IOHIDDigitizerDispatch.swift # the IOHIDEvent + trackpad-wrapper + byte-patch recipe
```

## Key design decisions

### Why the ObjC-runtime path instead of `import SimulatorKit`?

Linking the private frameworks at build time bakes `LC_LOAD_DYLIB`
entries into the binary that `dyld` must resolve before `main()` runs.
Those resolve fine if the user has the same Xcode in the same location,
but the moment Xcode lives at `/Applications/Xcode-beta.app` or
`/Applications/Xcode_26_2.app`, the binary fails to launch. Resolving
at runtime via `xcode-select -p` (with a `/Applications/Xcode*.app`
fallback) → `dlopen` → `NSClassFromString` works regardless of install
location. Details: [`knowledge/private-frameworks.md`](./knowledge/private-frameworks.md).

### Why a `DeviceHost` port and not just `CoreSimulators`?

Adapters that need to act on a `SimDevice` (`SimulatorKitScreen`,
`IndigoHIDInput`) shouldn't depend on the `CoreSimulators` aggregate —
they only need *"give me the live `NSObject` for this UDID"*. So they
depend on a narrow `DeviceHost` protocol that `CoreSimulators` happens
to implement. Tests can substitute a fake `DeviceHost` that returns a
KVC-stubbed `NSObject` without standing up CoreSimulator.

### Why resolve `SimDevice` on every operation, not cache it?

CoreSimulator returns a fresh `SimDevice` object on each
`availableDevices` enumeration. Caching the first reference produces
`EBADF`-flavoured failures on later operations once state changes
(the framework reaps stale handles). Always do
`host.resolveDevice(udid: udid)` immediately before the call.

### Why IOSurface directly as `CALayer.contents`?

IOSurface is GPU-resident memory; CoreAnimation knows how to set it as
a backing store with zero copies. No bitmap conversion, no
`CGBitmapContext`, no VideoToolbox round-trip. The render path is
`SimulatorKitScreen` → callback closure → `CATransaction.begin();
layer.contents = surface; CATransaction.commit();` on main.

### Why one `NSWindow` per simulator (then tabbed) instead of a tab view inside one window?

`addTabbedWindow(_:ordered:)` requires that each tab be its own
`NSWindow`. AppKit's native tab UI is a *window-grouping* mechanism, not
a `NSTabView`. The OS draws the tab bar; we don't. Spinning up one
`NSWindowController` per stream is the natural fit, and tab join/leave
becomes trivial. See [`knowledge/appkit-tabs.md`](./knowledge/appkit-tabs.md).

### Why no SwiftUI?

We need full control over `NSWindow.allowsAutomaticWindowTabbing`,
`addTabbedWindow:ordered:`, `tabbingMode`, `tab.title`, `moveTabToNewWindow:`,
and the per-window menu items. SwiftUI's `WindowGroup` and `Scene`
abstractions deliberately hide these so they can target iOS/iPadOS too.
AppKit gives us the lever we need.

### Why no external dependencies?

The interesting hard part of this project is the
SimulatorKit/CoreSimulator/IndigoHID surface, not anything a dependency
solves. Foundation + AppKit + `IOSurface` cover the rest. The only
thing we might pull in later is a mocking library (e.g. Kolos65/Mockable)
if we want auto-generated test fakes — but only if we end up writing
enough tests for it to pay off.

## Concurrency model

- The simulator list (`CoreSimulators.all`) and the boot/shutdown
  calls run on a background dispatch queue.
- The framebuffer callback fires on `SimulatorKitScreen`'s own
  serial queue (label like `sims.screen`).
- `IOSurface` rendering hops to main via `DispatchQueue.main.async`
  or a `CATransaction` in a `runOnMain` helper. `CALayer.contents`
  must be set on main.
- **HID input must run on `MainActor`** —
  `IndigoHIDMessageForMouseNSEvent` reads AppKit/NSEvent thread-local
  state, so calling it from a background event-loop thread builds
  malformed messages that the simulator silently drops. For us this
  is automatic since `NSEvent`s are already delivered on main, but
  if the digitizer path is ever called from a background queue we
  hop back to main first.

## Where private-framework code is allowed

Only inside `Infrastructure/`. If you find yourself reaching for
`NSClassFromString` or `dlsym` from `Domain/` or `App/`, stop and add
a Domain protocol the App layer talks to instead.

## Extensibility hot spots

| To add… | Touch these files |
|---|---|
| A new gesture | `Domain/Input/<Name>.swift` (+ register it in whatever dispatcher lives in App) |
| A new screen-pipeline frame source (e.g. external display) | `Domain/Screen/` port stays; new `Infrastructure/Screen/<Name>.swift` |
| Boot options (e.g. with-keyboard) | Extend `Simulator.boot(options:)` and the underlying `bootWithOptions:error:` dict |
| New simulator-state surfaced in the list | Add to `SimulatorState`, map in `CoreSimulators.state(from:)` |
