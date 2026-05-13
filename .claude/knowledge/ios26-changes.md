# Why iOS 26 broke older simulator-control tools

A short history of the HID wire-format change that made `idb`, `AXe`,
and most open-source simulator bridges stop working on iOS 26, and
why Sims needs a different recipe.

This is the **single most important piece of context for this
project** — everything in [`indigo-hid.md`](./indigo-hid.md) exists
to work around the changes documented here.

## What changed

`SimulatorHID`'s wire format gained a new routing target on iOS 26.
The host-side message builder `IndigoHIDMessageForMouseNSEvent` —
the C symbol every open-source simulator-control tool calls to
inject a touch — gained new argument shapes that route to a
different in-simulator subsystem.

### iOS ≤ 25.x — the world `idb` / `AXe` were built for

`IndigoHIDMessageForMouseNSEvent` had a 5-argument signature:

```c
void* IndigoHIDMessageForMouseNSEvent(
    CGPoint* point,
    uint32_t buttonState,
    uint32_t eventType,
    double   widthPoints,
    double   heightPoints
);
```

This produced a message that routed to the simulator's **pointer
service**, which the iOS 25 HID stack picked up and translated into a
`UITouch`. Tools like `idb` and `AXe` built on this — `FBSimulator-`
prefixed wrappers in `idb`, the `simctl`-adjacent shim in `AXe`.

### iOS 26 — what changed

The pointer service either:

- silently drops touches that arrive via the old format, or
- forwards them to `backboardd` in a malformed shape that triggers
  crashes (notably the `siri` button, which crashes through every
  known Indigo path).

The replacement is a **digitizer target** (routing tag `0x32`). The
new 9-argument `IndigoHIDMessageForMouseNSEvent` signature is:

```c
void* IndigoHIDMessageForMouseNSEvent(
    CGPoint* p1, CGPoint* p2,            // 1- or 2-finger
    uint32_t target,                      // 0x32 = touchDigitizer
    uint32_t eventType,                   // 1=down, 2=up, 6=dragged (NSEventType)
    uint32_t direction,                   // 1=down, 0=move, 2=up
    double   unused1, double unused2,     // pass 1.0, 1.0
    double   widthPoints, double heightPoints
);
```

Open-source tools that haven't moved to this signature inject
messages the iOS 26 HID stack drops on the floor.

### iOS 26 (continued) — the *second* breakage

Even the 9-arg signature isn't fully reliable on iOS 26.4:
single-finger taps either get misinterpreted as Home gestures
(triggering an unwanted "go to springboard") or silently drop. The
2-finger pinch/pan path works fine via 9-arg, but taps don't.

The wrapper produces messages that iOS reads as edge-flagged unless
you patch two byte slots in the output buffer:

- `0x6c` + `0x10c` → `0x32` (`IndigoHIDTouchTarget`) — the routing
  tag. Without it iOS treats the touch as a pointer event.
- `0x3a/0x3b` + `0xda/0xdb` → edge bitmask. Without it iOS reads
  the touch as if it started on an edge (likely zero-init garbage in
  the message), tripping the home-indicator gesture recognizer.

The workaround is to skip `IndigoHIDMessageForMouseNSEvent` entirely
for taps and use a different SimulatorKit path:

1. Build a real `IOHIDEvent` digitizer parent + finger child.
2. Run it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef`
   (the only `*FromHIDEventRef` wrapper in SimulatorKit that
   doesn't reject digitizer events outright).
3. **Patch the two byte slots** before sending — the wrapper leaves
   them uninitialised.

This is the digitizer-dispatch recipe in
[`indigo-hid.md`](./indigo-hid.md).

### The 7-arg variant (edge gestures)

There's a *third* signature variant of
`IndigoHIDMessageForMouseNSEvent` — the same C symbol, but a
7-argument calling convention used for explicit edge gestures
(swipe-to-home, app switcher):

```c
void* IndigoHIDMessageForMouseNSEvent(
    CGPoint* p1, CGPoint* p2,
    uint32_t target,
    uint32_t eventType,
    uint32_t edge,           // IndigoHIDEdge: 0=none, 1=left, 2=top, 3=right, 4=bottom
    double   widthPoints,
    double   heightPoints
);
```

The function dispatches on the type at runtime — the prologue does
`cmp x24, #0x4` to bounds-check argument 4 against `IndigoHIDEdge`'s
max value, picking the 7-arg branch if it looks like an edge value.

For Sims v1 we don't use this — edge gestures aren't in scope.

## What this means for Sims

We **skip the 5-arg signature entirely** (never built on iOS 25
support) and **skip the 9-arg signature for taps** (unreliable). We
use the digitizer-dispatch recipe for everything single-finger.

Two-finger gestures, if we ever add them, will use the 9-arg
signature (it's stable for 2-finger pinch/pan).

Edge gestures, if we ever add a "go home" menu item, will use the
7-arg signature.

## The threading constraint

`IndigoHIDMessageForMouseNSEvent` (all three signatures) reads
**AppKit / NSEvent thread-local state** internally. Calling it from
a NIO event-loop thread or any other background queue produces
malformed messages the simulator silently drops.

For Sims the hop is automatic — `NSEvent`s arrive on main, so the
dispatcher runs there naturally. Any background-queue code that
wants to send HID must hop to `MainActor` first.

The **digitizer-dispatch path doesn't share this constraint** —
`IOHIDEvent*` and `IndigoHIDMessageForTrackpadEventFromHIDEventRef`
are pure C with no AppKit dependency. But we still dispatch from
main for ordering reasons.

`IndigoHIDMessageForButton` and `IndigoHIDMessageForHIDArbitrary`
(buttons and keyboard) are also pure C and thread-safe.

## Diagnostic trick

If touches stop working after a change to the input adapter, **send
a button press via `IndigoHIDMessageForButton`** as a sanity check.
A working button press tells you:

- `SimDeviceLegacyHIDClient` is alive and reachable.
- The send selector is correct.
- The simulator's HID stack is receiving messages.

A failing button press tells you the problem is in the client setup,
not the message builder. A working button + failing tap tells you
the problem is in the digitizer-dispatch recipe (the byte offsets,
the IOHIDEvent fields, the edge bitmask).

Sims uses this trick — `pressLegacyButton` is the simplest working
path through the stack and the first thing to verify after a
regression.

## Why open-source tools are stuck

- `idb` (Facebook/Meta) ships with the 5-arg signature; its
  maintenance has slowed and the iOS 26 PR hadn't merged at the time
  of this writing.
- `AXe` calls into `idb` internals, so it inherits the breakage.
- `serve-sim`, `kittyfarm`, `opensafari`, and the other
  WebSocket-bridge projects all target the 5-arg or 9-arg path
  without the digitizer-dispatch recipe.
- Simulator.app itself uses the digitizer-dispatch path internally
  — that's how the recipe was uncovered, by tracing what Simulator.app
  was doing.

If a future Xcode unifies these signatures again, this file should
get a "post-mortem: this is no longer needed" note. Until then, every
single-finger gesture in Sims goes through the digitizer-dispatch
recipe.

## Source

`Sims/Infrastructure/Input/IndigoHIDInput.swift` and
`IOHIDDigitizerDispatch.swift` carry inline comments with the full
reverse-engineering trail — what was tried, what was observed, why
the final recipe is what it is. Re-read those when something stops
working.
