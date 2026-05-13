# IndigoHID — input injection recipe

**This is the single most important knowledge file in the repo.** If
the input adapter ever stops working, start here.

The HID injection path has two distinct shapes:

1. **`IndigoHIDMessageForMouseNSEvent`** — the legacy SimulatorKit
   symbol. Two argument shapes (9-arg and 7-arg-with-edge). Works
   reliably on iOS 26 for 2-finger pinch/pan but is unreliable for
   single-finger taps (taps either get misinterpreted as Home gestures
   or silently drop).
2. **`IOHIDDigitizerDispatch`** — the iOS 26 / Xcode 26 workaround.
   Builds a real `IOHIDEvent` digitizer parent + finger
   child, runs it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef`,
   patches two byte slots the wrapper leaves uninitialised, then sends
   via `SimDeviceLegacyHIDClient`. **This is the path Sims uses
   for taps, swipes, single-finger touches, and all edge gestures.**

The mouse-event path remains as a fallback for two-finger gestures
(pinch / pan), but for v1 of Sims we **only need the digitizer
dispatch path** — pinch isn't in scope.

## The message sink: `SimDeviceLegacyHIDClient`

Every HID message — mouse, button, scroll, keyboard, the patched
digitizer message — is sent through `SimDeviceLegacyHIDClient`. This
is a Swift class inside SimulatorKit; its ObjC class name is the
Swift-mangled form:

```
_TtC12SimulatorKit24SimDeviceLegacyHIDClient
```

(Breakdown: `_TtC` = Swift class, `12SimulatorKit` = module name, `24` =
class-name length, `SimDeviceLegacyHIDClient` = class name.)

### Construction

```swift
guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient"),
      let device = host.resolveDevice(udid: udid) else { return nil }

let allocSel = NSSelectorFromString("alloc")
let metaCls  = object_getClass(cls)!
let allocImp = class_getMethodImplementation(metaCls, allocSel)!
typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, allocSel)!

let initSel = NSSelectorFromString("initWithDevice:error:")
let initImp = class_getMethodImplementation(cls, initSel)!
typealias InitFn = @convention(c) (
    AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
) -> AnyObject?
var err: NSError?
let client = unsafeBitCast(initImp, to: InitFn.self)(allocated, initSel, device, &err)
```

One client per simulator. Hold it for the simulator's lifetime; the
warmup cost is non-trivial.

### Sending a message

The selector is

```
sendWithMessage:freeWhenDone:completionQueue:completion:
```

The message pointer comes from `IndigoHIDMessageForXxx` (or the patched
trackpad-wrapper output for digitizer events). Pass `freeWhenDone: true`
— the framework owns the buffer after the call:

```swift
let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
typealias Fn = @convention(c) (
    AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
) -> Void
let imp = class_getMethodImplementation(object_getClass(client)!, sel)!
unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
```

`completionQueue` and `completion` are nil — fire-and-forget.

## Warmup (call once per client)

Before any HID dispatch, prime pointer + mouse services:

```swift
let createPointerSvc: ServiceFn? = dlsym(kit, "IndigoHIDMessageToCreatePointerService").map { … }
let createMouseSvc:   ServiceFn? = dlsym(kit, "IndigoHIDMessageToCreateMouseService").map { … }

if let msg = createPointerSvc?() { send(message: msg, to: client); usleep(20_000) }
if let msg = createMouseSvc?()   { send(message: msg, to: client); usleep(20_000) }
```

And on tear-down:

```swift
let removePointerSvc: ServiceFn? = dlsym(kit, "IndigoHIDMessageToRemovePointerService").map { … }
if let msg = removePointerSvc?() { send(message: msg, to: client) }
```

```swift
typealias ServiceFn = @convention(c) () -> UnsafeMutableRawPointer?
```

## The digitizer-dispatch recipe (primary path)

Five steps:

1. Build an `IOHIDEvent` **digitizer parent** event.
2. Build a finger child event.
3. Append the child to the parent.
4. Run the parent through `IndigoHIDMessageForTrackpadEventFromHIDEventRef`.
5. Patch two byte offsets in the returned message, then send via
   `SimDeviceLegacyHIDClient.send`.

### Symbols

| Symbol | Library | What |
|---|---|---|
| `IOHIDEventCreateDigitizerEvent` | dyld shared cache (use `RTLD_DEFAULT`, i.e. `bitPattern: -2`) | parent event |
| `IOHIDEventCreateDigitizerFingerEvent` | dyld shared cache | finger child |
| `IOHIDEventAppendEvent` | dyld shared cache | append child to parent |
| `IndigoHIDMessageForTrackpadEventFromHIDEventRef` | SimulatorKit (`dlopen`) | wraps the IOHIDEvent into an Indigo message buffer |

```swift
let dyld = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
let pCreateDig = dlsym(dyld, "IOHIDEventCreateDigitizerEvent")
let pCreateFin = dlsym(dyld, "IOHIDEventCreateDigitizerFingerEvent")
let pAppend    = dlsym(dyld, "IOHIDEventAppendEvent")
let kit        = dlopen("<devDir>/.../SimulatorKit", RTLD_NOW)!
let pWrap      = dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef")
```

### Signatures

```swift
// IOHIDEventCreateDigitizerEvent(allocator, ts, transducer,
//   index, identifier, eventMask, buttonMask,
//   x, y, z, tipPressure, barrelPressure,
//   range, touch, options)
typealias CreateDigitizerFn = @convention(c) (
    CFAllocator?, UInt64, UInt32,
    UInt32, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double,
    Bool, Bool, UInt32
) -> Unmanaged<CFTypeRef>?

// IOHIDEventCreateDigitizerFingerEvent(allocator, ts,
//   index, identifier, eventMask,
//   x, y, z, tipPressure, twist,
//   range, touch, options)
typealias CreateFingerFn = @convention(c) (
    CFAllocator?, UInt64,
    UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double,
    Bool, Bool, UInt32
) -> Unmanaged<CFTypeRef>?

typealias AppendEventFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
typealias TrackpadWrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
```

### Build the parent + child

```swift
let now = mach_absolute_time()
let transducerFinger: UInt32 = 2     // kIOHIDDigitizerTransducerTypeFinger
let mask: UInt32 = phase.eventMask   // see Phase table below
let range = phase != .up
let touch = phase != .up
let pressure = 0.0                   // non-zero crashed earlier; 0.0 is safe

guard let parentUM = createDigitizerFn(
    nil, now, transducerFinger,
    0,            // index
    identifier,   // a monotonic per-touch UInt32; sticky across down→move→up
    mask, 0,
    point.x, point.y, 0.0,
    pressure, 0.0,
    range, touch, 0
) else { return nil }
let parent = parentUM.takeRetainedValue()

guard let fingerUM = createFingerFn(
    nil, now,
    0, identifier, mask,
    point.x, point.y, 0.0,
    pressure, 0.0,
    range, touch, 0
) else { return parent }
let finger = fingerUM.takeRetainedValue()
appendFn(parent, finger, 0)
```

Real iOS touches arrive as parent + child IOHIDEvent pairs; without
the parent the trackpad wrapper produces a 192-byte stub iOS ignores.

### Wrap through the trackpad bridge

```swift
let raw = Unmanaged.passUnretained(parent as AnyObject).toOpaque()
guard let msg = trackpadWrapFn(raw) else { return nil }
```

`withExtendedLifetime(parent) { … }` around the wrap call keeps the
CF object alive long enough for the wrapper to copy out the data.

### Patch the byte offsets

```swift
let target: UInt32 = 0x32                // IndigoHIDTouchTarget = digitizer
msg.storeBytes(of: target, toByteOffset: 0x6c, as: UInt32.self)

let size = malloc_size(msg)
if size >= 0x110 {
    msg.storeBytes(of: target, toByteOffset: 0x10c, as: UInt32.self)
}

let edgeBit: UInt8 = edge.bit             // table below
let edgePresent: UInt8 = edgeBit == 0 ? 0x00 : 0x04
msg.storeBytes(of: edgePresent, toByteOffset: 0x3a, as: UInt8.self)
msg.storeBytes(of: edgeBit,     toByteOffset: 0x3b, as: UInt8.self)
if size >= 0xdc {
    msg.storeBytes(of: edgePresent, toByteOffset: 0xda, as: UInt8.self)
    msg.storeBytes(of: edgeBit,     toByteOffset: 0xdb, as: UInt8.self)
}
```

The two slots:

- **`0x6c` + `0x10c`** — `IndigoHIDTouchTarget` (the routing tag).
  `0x32` tells iOS to deliver the touch through the digitizer
  subsystem instead of the pointer-service stub.
- **`0x3a/0x3b` + `0xda/0xdb`** — the edge bitmask. `0x04` at the
  "present" byte and one of the edge bits at the next byte. Without
  this, every touch the wrapper produces has edge = none, and iOS's
  home-indicator gesture recognizer will misinterpret bottom-edge
  swipes.

### Tables

#### `Edge` bits

| Edge | Bit |
|---|---|
| none | `0x00` |
| left | `0x02` |
| top | `0x08` |
| right | `0x04` |
| bottom | `0x01` |

#### Phase → `IOHIDDigitizerEventMask`

| Phase | Mask | Range | Touch |
|---|---|---|---|
| `.down` | `0x07` (Range \| Touch \| Position) | true | true |
| `.move` | `0x07` (sustained) | true | true |
| `.up` | `0x06` (Touch \| Position — lift) | false | false |

#### Touch identifier

A monotonic `UInt32` per touch sequence. Reset to 1 on overflow. For
streaming `touch1` (`down` → many `move`s → `up`), pick a fresh id on
`.down` and reuse it through `.up`. For one-shot `tap` and `swipe`,
pick one fresh id per call.

### Send

```swift
sendMessage(msg, to: client)   // selector recipe shown earlier
```

## High-level entry points

The dispatcher exposes two convenience helpers:

```swift
enum IOHIDDigitizerDispatch {
    static func tap(point: CGPoint, holdSeconds: Double,
                    edge: Edge = .none, identifier: UInt32,
                    on client: AnyObject) -> Bool { … }

    static func swipe(from start: CGPoint, to end: CGPoint,
                      steps: Int = 10, stepMs: UInt32 = 16,
                      dwellMs: UInt32 = 0,
                      edge: Edge = .none, identifier: UInt32,
                      on client: AnyObject) -> Bool { … }

    /// The primitive: build, patch, send one event.
    static func send(point: CGPoint, identifier: UInt32, phase: Phase,
                     edge: Edge, on client: AnyObject) -> Bool { … }
}
```

A tap is `send(.down)` → `usleep(holdSeconds * 1_000_000)` →
`send(.up)` at the same point with the same id.

A swipe is `send(.down)` at start → 10 interpolated `send(.move)`s →
optional dwell (resend `.move` at end with `usleep(50_000)` repeats) →
`send(.up)` at end.

Coords are **normalized [0, 1]** — the trackpad wrapper interprets
the IOHIDEvent's x/y as unit fractions of the device screen. The
caller scales view coordinates → simulator screen-space (in points) →
divide by screen-size → normalize. `IndigoHIDInput.tap` does this
division at the entry point:

```swift
let normalised = CGPoint(x: clamp01(point.x / size.width),
                         y: clamp01(point.y / size.height))
```

## Keyboard / arbitrary HID

Distinct from the digitizer dispatch path — keyboard goes through
`IndigoHIDMessageForHIDArbitrary`:

```swift
// (target, page, usage, operation)
//   target = 0x32 (digitizer)
//   page/usage = HID page/usage codes for the key
//   operation = 1 (down) / 2 (up)
typealias HIDArbitraryFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

let target: UInt32 = 0x32
let down = hidArbFn(target, key.hidUsage.page, key.hidUsage.usage, 1)!
send(message: down, to: client)
usleep(holdUs)
let up = hidArbFn(target, key.hidUsage.page, key.hidUsage.usage, 2)!
send(message: up, to: client)
```

For modifier-bracketed keystrokes: modifiers-down → key-down → hold
→ key-up → modifiers-up (reversed order).

HID page/usage codes for the standard W3C `KeyboardEvent.code` set
live in `Sims/Domain/Input/Keyboard.swift`.

## Threading constraints

- **`IndigoHIDMessageForMouseNSEvent` must run on `MainActor`.** It
  reads `NSEvent` thread-local state internally. Calling it from a
  background queue produces malformed messages the simulator silently
  drops. (We don't use this for taps any more, but the rule still
  applies to two-finger paths if/when we add them.)
- The digitizer dispatch path (`IOHIDDigitizerDispatch`) doesn't
  share the thread-local dependency, but we still dispatch HID from
  main because `NSEvent`s come from there and we want stable ordering.
- Buttons (`IndigoHIDMessageForButton`) and arbitrary HID
  (`IndigoHIDMessageForHIDArbitrary`) are pure-C and thread-safe.
  These are useful as sanity checks if your tap path goes silent —
  a button press that *works* tells you the client is wired up
  correctly and the issue is in the digitizer dispatch.

## Symbol-loading order

```
1. dlopen CoreSimulator (RTLD_NOW | RTLD_GLOBAL)
2. dlopen SimulatorKit  (RTLD_NOW | RTLD_GLOBAL)
3. dlsym each Indigo* function (lives in SimulatorKit)
4. dlsym each IOHIDEvent* function (lives in dyld shared cache;
   pass `RTLD_DEFAULT` = `UnsafeMutableRawPointer(bitPattern: -2)`)
```

## What v1 Sims needs from this file

For Phase 3 (input injection), the minimum is:

- `SimDeviceLegacyHIDClient` warm + send
- `IOHIDDigitizerDispatch.tap` / `.swipe` / `.send` for `touch1`
- `IndigoHIDMessageForHIDArbitrary` for keys
- `IndigoHIDMessageForScrollEvent` for scrolling

We do **not** need (in v1):

- 2-finger mouse-event path (`IndigoHIDMessageForMouseNSEvent`,
  9-arg or 7-arg)
- `IndigoHIDMessageForButton` (no hardware-button UI in v1)
- The four virtual edge gestures (swipe-to-home, app switcher, etc.)
  — we can add later if we want a "go home" menu item

## Source

Recipe verified by disassembling
`<Xcode>/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit`
on iOS 26.4. Our `IndigoHIDInput.swift` and
`IOHIDDigitizerDispatch.swift` carry inline comments explaining the
offset derivations and regression diagnoses — re-read those when you
hit a wall.
