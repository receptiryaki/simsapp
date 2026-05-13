# SimulatorKit — framebuffer subscription

The SimulatorKit private framework owns the simulator's
GPU-resident framebuffer. We subscribe to per-frame callbacks and
receive `IOSurface` objects (zero-copy GPU memory) that we hand
directly to a `CALayer`.

Framework location:

```
<developerDir>/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit
```

`<developerDir>` is whatever `xcode-select -p` resolves to (with our
Xcode-discovery fallback — see
[`private-frameworks.md`](./private-frameworks.md)).

## The path from `SimDevice` to a frame callback

```
SimDevice                     (CoreSimulator — KVC `io`)
  ▼
SimDeviceIOClient             (returned by `-[SimDevice io]`)
  ▼  call `updateIOPorts`, then read `deviceIOPorts`
[SimDeviceIOPortConsumer]     (one per descriptor / display plane)
  ▼  filter by `portIdentifier == "com.apple.framebuffer.display"`
SimDisplayDescriptorState     (or similar — opaque NSObject — `descriptor`)
  ▼  register frame + surfaces-changed callbacks
IOSurface                     (`-[descriptor framebufferSurface]`)
```

## The selector recipes

### Step 1 — Get the `io` client

`SimDevice` has an `io` accessor that returns the `SimDeviceIOClient`.
Treat as a `NSObject` and reach via `perform`:

```swift
guard let device = host.resolveDevice(udid: udid) else { throw … }
guard let io = device.perform(NSSelectorFromString("io"))?
    .takeUnretainedValue() as? NSObject else {
    throw ScreenError.ioUnavailable
}
```

The `io` client is stable for the simulator's lifetime; cache it on
the `SimulatorKitScreen` instance.

### Step 2 — Refresh ports, enumerate

```swift
io.perform(NSSelectorFromString("updateIOPorts"))    // populate
guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
    throw ScreenError.noFramebuffer
}
```

`updateIOPorts` is the lazy-population trigger; without it
`deviceIOPorts` may be empty even on booted simulators. Call it before
every fresh subscription, but not on every frame.

### Step 3 — Filter to framebuffer descriptors

Each port has a `portIdentifier` (a `SimDeviceIOPortIdentifier` —
treat as a stringly-typed value via `String(describing:)`). The ones
we want produce `"com.apple.framebuffer.display"`.

```swift
let pidSel  = NSSelectorFromString("portIdentifier")
let descSel = NSSelectorFromString("descriptor")
let surfSel = NSSelectorFromString("framebufferSurface")

var descriptors: [NSObject] = []
for port in ports where port.responds(to: pidSel) {
    guard let pid = port.perform(pidSel)?.takeUnretainedValue(),
          "\(pid)" == "com.apple.framebuffer.display",
          port.responds(to: descSel),
          let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
          desc.responds(to: surfSel) else { continue }
    descriptors.append(desc)
}
```

A simulator may surface multiple framebuffer descriptors (the main
display plus secondary planes / overlays). We register on all of them
and, at frame time, pick the descriptor whose surface has the largest
area.

### Step 4 — Register screen callbacks

The selector is long. Three closures: frame, surfaces-changed,
properties-changed. The first two both signal "a new IOSurface is
available"; the third we ignore (color-space / format changes — we
don't care, we just re-pull the surface).

```swift
let regSel = NSSelectorFromString(
    "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
        "surfacesChangedCallback:propertiesChangedCallback:"
)

let uuid = NSUUID()
let queue = DispatchQueue(label: "sims.fb", qos: .userInteractive)

let frame: @convention(block) () -> Void = { [weak self] in
    self?.queue.async { self?.captureLatest() }
}
let surfaces: @convention(block) () -> Void = { [weak self] in
    self?.queue.async { self?.captureLatest() }
}
let props: @convention(block) () -> Void = { /* ignore */ }

typealias Fn = @convention(c) (
    AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
) -> Void

let imp = class_getMethodImplementation(type(of: desc), regSel)!
unsafeBitCast(imp, to: Fn.self)(
    desc, regSel,
    uuid, queue as AnyObject,
    frame as AnyObject, surfaces as AnyObject, props as AnyObject
)
```

Save the `NSUUID` per descriptor — you need it to unregister.

### Step 5 — Pull the latest surface in the callback

The callback **doesn't** receive the `IOSurface` directly. It's a
signal that one is available; pull it via the `framebufferSurface`
selector on the descriptor:

```swift
private func captureLatest() {
    let surfSel = NSSelectorFromString("framebufferSurface")
    var best: IOSurface?
    var bestArea = 0
    for desc in descriptors {
        guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
        // IOSurfaceRef bridges to Swift's IOSurface overlay.
        // `unsafeDowncast` debug-asserts the type and is the
        // compiler-recommended form on Swift 6 (it warns on the
        // `unsafeBitCast`-from-AnyObject form).
        let surf = unsafeDowncast(surfObj, to: IOSurface.self)
        let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
        if area > bestArea { best = surf; bestArea = area }
    }
    if let best { onFrame?(best) }
}
```

### Step 6 — Unregister on stop

```swift
let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
for desc in descriptors {
    if let uuid = callbackUUIDs[ObjectIdentifier(desc)],
       desc.responds(to: unregSel) {
        desc.perform(unregSel, with: uuid)
    }
}
```

Then clear `descriptors`, `callbackUUIDs`, and the `ioClient`. Setting
`ioClient = nil` lets ARC release the `SimDeviceIOClient`.

## Rendering to a CALayer

```swift
import IOSurface
import QuartzCore

// In the Screen.start callback closure:
{ surface in
    DispatchQueue.main.async {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit fade
        self.layer.contents = surface           // IOSurface as CALayer.contents — zero copy
        CATransaction.commit()
    }
}
```

`CALayer.contents` accepts an `IOSurface` directly on Apple Silicon
macOS — CoreAnimation grabs the GPU pages without a CPU round-trip.
This is the entire rendering pipeline for Sims; no encoder, no
bitmap, no VideoToolbox.

The hosting `NSView`'s layer is what we set; that view is
`wantsLayer = true` and `layer.contentsGravity = .resizeAspect` (or
`.resize` if you don't mind the simulator stretching to fit the
window). The simulator's screen dimensions can be read from the
surface itself via `IOSurfaceGetWidth/Height` if you want to keep the
window's aspect ratio in sync.

## Surface dimensions

```swift
let w = IOSurfaceGetWidth(surface)
let h = IOSurfaceGetHeight(surface)
```

These are **pixels**, not points. The simulator renders at its native
@2x or @3x density. For coordinate translation (NSView coords → tap
input coords) we want **points** in the simulator's screen-space; the
simulator's `deviceType` / `runtime` plus the surface dimensions give
us the scale factor. Keep everything in points and divide by the
screen-size at the C boundary.

## Errors / failure modes to plan for

| Failure | Likely cause | What to do |
|---|---|---|
| `device.perform("io")` returns nil | Simulator isn't booted | Throw `ScreenError.ioUnavailable`. Caller's job to wait for boot. |
| `deviceIOPorts` is empty after `updateIOPorts` | Simulator just started; ports not enumerated yet | Retry after ~100 ms, then give up. |
| No port with `portIdentifier == "com.apple.framebuffer.display"` | New runtime, different port id | Log the actual identifiers and update the recipe + this file. |
| Registration selector unresolved | SimulatorKit changed in newer Xcode | Same — log the selector and fix here in lockstep. |
| Frame callback never fires | Either the simulator is wedged, or our queue is starved | 2 s watchdog timer, then `stop()` and surface the failure. |

## Source

Selectors verified against
`<Xcode>/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit`.
The full implementation lives in
`Sims/Infrastructure/Screen/SimulatorKitScreen.swift`.
