# CoreSimulator — API surface

The private framework that owns simulator lifecycle (list, boot,
shutdown, state). Loaded at runtime via `dlopen`; reached via the ObjC
runtime (no `import CoreSimulator`).

Framework location (after `xcode-select -p` resolves to the active
Xcode developer dir):

```
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator
```

`CoreSimulator.framework` lives **outside** the Xcode bundle at
`/Library/Developer/PrivateFrameworks/` — it's installed by Xcode
but accessible system-wide. (Compare to SimulatorKit, which lives
inside `<developerDir>/Library/PrivateFrameworks/`.)

`dlopen` with `RTLD_NOW | RTLD_GLOBAL` so the SimulatorKit framework
(loaded next) can resolve CoreSimulator symbols.

## Loading the framework

```swift
import Foundation

func loadCoreSimulator() {
    let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil {
        let err = dlerror().map { String(cString: $0) } ?? "(null)"
        fputs("[sims] CoreSimulator dlopen failed: \(err)\n", stderr)
    }
}
```

## Class lookup

```swift
guard let cls = NSClassFromString("SimServiceContext") else { return }
```

The three classes we touch:

| ObjC class | What it is | How we get one |
|---|---|---|
| `SimServiceContext` | The shared CoreSimulator "world" handle | `+sharedServiceContextForDeveloperDir:error:` (class method) |
| `SimDeviceSet` | A collection of simulators (default = Xcode's) | `-defaultDeviceSetWithError:` on a `SimServiceContext` |
| `SimDevice` | One simulator instance | iterate `set.availableDevices` (NSArray) |

`SimRuntime` and `SimDeviceType` also exist as referenced types but we
only KVC-read into them; we never construct or call methods on them.

## Selector recipes

All four selectors below take an out-error pointer and return either
`BOOL` or `id`. The `invoke*WithError` family in
`Infrastructure/Simulator/CoreSimulators.swift` wraps
`class_getMethodImplementation` + `unsafeBitCast` so we don't
re-derive the calling convention every time.

### `+[SimServiceContext sharedServiceContextForDeveloperDir:error:]`

Class method on `SimServiceContext`. Returns the shared context for a
given Xcode developer dir (`xcode-select -p`-style path).

```swift
typealias Fn = @convention(c) (
    AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
) -> AnyObject?

let cls = NSClassFromString("SimServiceContext")!
let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
let metaCls = object_getClass(cls)!
let imp = class_getMethodImplementation(metaCls, sel)!
let fn  = unsafeBitCast(imp, to: Fn.self)

var err: NSError?
let ctx = fn(cls, sel, developerDir as NSString, &err) as? NSObject
```

### `-[SimServiceContext defaultDeviceSetWithError:]`

Instance method on the context. Returns the user's default
`SimDeviceSet` (the one Xcode uses when you run a Simulator destination).

```swift
typealias Fn = @convention(c) (
    AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
) -> AnyObject?

let sel = NSSelectorFromString("defaultDeviceSetWithError:")
let imp = class_getMethodImplementation(type(of: ctx), sel)!
let fn  = unsafeBitCast(imp, to: Fn.self)

var err: NSError?
let set = fn(ctx, sel, &err) as? NSObject
```

### `-[SimDeviceSet availableDevices]` (KVC)

Returns `NSArray` of `SimDevice`. Read via KVC:

```swift
let devices = (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
```

### `-[SimDevice bootWithOptions:error:]` (preferred) / `-[SimDevice bootWithError:]` (fallback)

```swift
let bootOpts = NSSelectorFromString("bootWithOptions:error:")
let opts: NSDictionary = ["persist": true]   // persist past process exit
if device.responds(to: bootOpts) {
    var err: NSError?
    if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
}

// fallback
let bootSel = NSSelectorFromString("bootWithError:")
if device.responds(to: bootSel) {
    var err: NSError?
    if invokeBoolWithError(device, bootSel, &err) { return }
}
```

`persist: true` keeps the simulator booted past our process exit —
the right default. Without it, the simulator shuts down when the
controlling process detaches.

### `-[SimDevice shutdownWithError:]`

```swift
let sel = NSSelectorFromString("shutdownWithError:")
var err: NSError?
let ok = invokeBoolWithError(device, sel, &err)
```

## KVC properties on `SimDevice`

| Key | Type | Notes |
|---|---|---|
| `UDID` | `NSUUID` | `.uuidString` for the human-readable form |
| `name` | `String` | User-given name; drifts on `simctl clone` / rename |
| `state` | `NSNumber` (UInt) | See state mapping below |
| `runtime` | `SimRuntime` (NSObject) | KVC again to get `name` ("iOS 26.4") or `versionString` |
| `deviceType` | `SimDeviceType` (NSObject) | KVC `name` returns the `.simdevicetype` filename — stable across renames |

State mapping (integer values verified stable on iOS 26.4):

```swift
private func state(from raw: UInt) -> SimulatorState {
    switch raw {
    case 0: return .creating
    case 1: return .shutdown
    case 2: return .booting
    case 3: return .booted
    case 4: return .shuttingDown
    default: return .shutdown   // be permissive; new states have appeared in past Xcodes
    }
}
```

## "Resolve fresh on every operation" rule

CoreSimulator returns a *new* `SimDevice` reference on each
`availableDevices` enumeration. Caching the first ref produces
`EBADF`-like failures on later operations once state changes (the
framework reaps stale handles internally).

**Don't cache the `NSObject`.** Cache only the UDID, and resolve fresh
every time:

```swift
func resolveDevice(udid: String) -> NSObject? {
    guard let set = currentDeviceSet else { return nil }
    let devices = (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    return devices.first {
        ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid
    }
}
```

`CoreSimulators` (the aggregate) implements this lookup; everything
downstream (`SimulatorKitScreen`, `IndigoHIDInput`) depends on the
narrow `DeviceHost` protocol that exposes only this one method.

## The minimum we need

For Phase 1 the Sims feature set is:

- List: enumerate `availableDevices`, project each to a Swift value
  with name / udid / runtime / state / deviceTypeName.
- Boot: `bootWithOptions:error:` with `["persist": true]`, fall back
  to `bootWithError:`.
- Shutdown: `shutdownWithError:`.

That's it. We do not need anything from CoreSimulator's broader
surface (notifications, async ops, custom device sets, device creation/
deletion). If we add "attach to an Xcode-booted sim" in Phase 5, that's
just *not* booting — same listing, no boot call.

## Source

Selectors and KVC keys verified by reading the SimulatorKit /
CoreSimulator framework binaries in
`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/` and
`<Xcode>/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/`.
