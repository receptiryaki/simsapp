# Sims

> [!IMPORTANT]
> **This project is no longer maintained.** Apple shipped
> [**Device Hub**](https://developer.apple.com/documentation/xcode/device-hub)
> with Xcode 27 (announced at WWDC 2026), which does natively — and supported —
> what Sims set out to do: a unified workspace for managing simulators and
> physical devices with live display, touch input, hardware controls, zoom,
> resize, and keyboard capture. Per Apple, "Device Hub replaces Simulator and
> does a whole lot more too."
>
> Since Device Hub is a first-party, officially supported tool that doesn't
> depend on reverse-engineered private frameworks, there's no reason to keep
> maintaining Sims. The repository is **archived** (read-only). The code and the
> reverse-engineering notes under [`.claude/`](./.claude/) remain available for
> reference. Thanks to everyone who tried it. — see
> [Managing your simulated and physical devices in Device Hub](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub).

A native macOS app for managing and streaming iOS simulators, with each
simulator living in its own AppKit tab inside a single window.

Lists every simulator the host has, boots them headlessly, streams their
framebuffers via SimulatorKit, and forwards mouse / keyboard / button
input through CoreSimulator's IndigoHID pipeline.

## Features

- Lists every simulator CoreSimulator knows about (name, runtime, UDID,
  state).
- Boot / shutdown without launching Apple's Simulator.app.
- Live framebuffer streaming, zero-copy via `IOSurface` →
  `CALayer.contents`.
- Mouse → touch / drag / swipe, full keyboard, scroll wheel, Home /
  Volume Up / Volume Down, Screenshot to `~/Desktop`.
- Native AppKit window tabs — `⌘T` to open a new picker tab, `⌘⇧]` /
  `⌘⇧[` to switch.
- Universal binary (Apple Silicon + Intel), notarized.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 26+ installed — Sims reaches into Xcode's simulator runtimes at
  runtime, so the full Xcode app is required (Command Line Tools alone
  are not enough)
- Apple Silicon or Intel Mac

## Install

### From a release

Download the latest notarized `Sims.zip` from the
[Releases](../../releases) tab, unzip, and drag `Sims.app` into
`/Applications`. Gatekeeper recognises the notarisation and opens it
without warnings.

### From source

```sh
git clone https://github.com/receptiryaki/simsapp.git
cd simsapp
open Sims.xcodeproj         # build and run from Xcode
```

That's enough for a Debug build (ad-hoc signed, fine for local
tinkering). For a signed Release / notarised distribution build, see
[Building a release](#building-a-release).

## How it works

Sims is built on top of three private Apple frameworks that ship with
Xcode but are not part of the public macOS SDK:

- **CoreSimulator** — list / boot / shutdown simulators (`SimDevice`).
- **SimulatorKit** — subscribe to framebuffer `IOSurface`s; build HID
  messages.
- **IndigoHID** — the wire format that carries touches / button presses
  to the simulator's `backboardd`.

Sims doesn't link any of these at build time. They're discovered at
runtime by resolving `xcode-select -p`, `dlopen`-ing the framework
binaries, and reaching in via `NSClassFromString` + `dlsym`. That means
the same binary runs against whatever Xcode is currently installed,
including side-by-side / beta Xcodes.

Framebuffer rendering is zero-copy — the simulator hands us an
`IOSurface` per frame, which we set directly as `CALayer.contents`. No
JPEG, no H.264, no VideoToolbox round-trip.

Input dispatch on iOS 26 needed a rewrite from the long-standing
`IndigoHIDMessageForMouseNSEvent` recipe: single-finger taps on iOS 26
either get misinterpreted as Home gestures or silently drop. Sims uses
a digitizer-dispatch path that builds a real `IOHIDEvent` parent +
finger child, wraps it via
`IndigoHIDMessageForTrackpadEventFromHIDEventRef`, and patches the
target / edge byte slots the wrapper leaves uninitialised.

The reverse-engineering trail — every selector, byte offset, and
framework symbol — lives under [`.claude/`](./.claude/). Start with
[`.claude/architecture.md`](./.claude/architecture.md) for the layer
split, and [`.claude/knowledge/indigo-hid.md`](./.claude/knowledge/indigo-hid.md)
for the HID pipeline.

## Building a release

A notarised Release build needs a one-time Apple Developer setup
(certificate + notarytool credentials). The full walk-through is in
[`scripts/DISTRIBUTION.md`](./scripts/DISTRIBUTION.md). Once configured:

```sh
cp Sims/Local.xcconfig.example Sims/Local.xcconfig
# edit Local.xcconfig with your Developer Team ID + bundle identifier

./scripts/release.sh
# → dist/Sims.app and dist/Sims.zip, notarised + stapled
```

`Local.xcconfig` is gitignored, so your team ID never enters the repo.

## A note on Apple private frameworks

Sims is fundamentally a wrapper around private Apple APIs. Each Xcode
release can change the surface and break things. The HID wire format
itself changed in iOS 26, and the framebuffer descriptor enumeration
has shifted at least twice in the last two years. This project tracks
the current Xcode (26.x as of writing) and will need ongoing work to
keep up.

Practical consequences:

- The app is **not** eligible for the Mac App Store.
- Binary compatibility across Xcode versions is not guaranteed.
- Sims is signed with a Developer ID and notarised, but never
  sandboxed (the App Sandbox refuses to `dlopen` Apple's private
  frameworks).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Bug reports and feature
requests use the GitHub issue templates; PRs are welcome.

## License

[MIT](./LICENSE) © 2026 Recep Tiryaki
