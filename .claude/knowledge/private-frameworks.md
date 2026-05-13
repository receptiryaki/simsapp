# Private frameworks — loading, paths, sandbox

How Sims reaches into Apple's private SimulatorKit / CoreSimulator
frameworks without linking them at build time, and the constraints
that come with that choice.

## The two frameworks

| Framework | Filesystem location |
|---|---|
| `CoreSimulator` | `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator` |
| `SimulatorKit` | `<developerDir>/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit` |

`CoreSimulator` is installed system-wide by Xcode at
`/Library/Developer/PrivateFrameworks/`. `SimulatorKit` is inside the
Xcode bundle at `<developerDir>/Library/PrivateFrameworks/`, where
`<developerDir>` is the active Xcode's `Contents/Developer/`.

Inside an Xcode bundle that path is:

```
/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit
```

Beta or side-by-side Xcodes work the same way — only `<developerDir>`
changes.

## Why we don't link at build time

Linking would emit `LC_LOAD_DYLIB` entries in the Mach-O binary that
`dyld` must resolve before `main()` runs. If the user's Xcode lives
anywhere other than the exact path the linker baked in, the binary
fails to launch with a "no suitable image found" error before any of
our code can intervene.

Sims policy: **SimulatorKit + CoreSimulator are never linked at build
time.** Nothing in `Sims/` does `import SimulatorKit` /
`import CoreSimulator`. The Swift code reaches into them via
`NSClassFromString` + `dlsym` (see `CoreSimulators.loadFrameworks()`
and `IndigoHIDInput.ensureWarm()`), after discovering the active
Xcode through `xcode-select -p`.

## What we *do* link

Public frameworks are linked normally (they're at stable system paths
that always exist):

```swift
.linkedFramework("IOSurface"),
.linkedFramework("CoreGraphics"),
.linkedFramework("QuartzCore"),
// VideoToolbox / ImageIO / CoreVideo only if encoding (we don't, v1)
```

In an Xcode project (which we'll use for AppKit), add the same in
the target's "Frameworks, Libraries, and Embedded Content" pane.

## Discovering the developer dir at runtime

```swift
static func developerDir() -> String {
    if let dev = xcodeSelectDir(), hasSimulatorKit(at: dev) { return dev }
    if let dev = scanApplications() { return dev }
    // No working Xcode found — return xcode-select's answer (or the
    // canonical default) so the subsequent dlopen surfaces a path
    // the user recognises in the error.
    return xcodeSelectDir() ?? "/Applications/Xcode.app/Contents/Developer"
}

private static func xcodeSelectDir() -> String? {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    task.arguments = ["-p"]
    task.standardOutput = pipe
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private static func hasSimulatorKit(at developerDir: String) -> Bool {
    let path = (developerDir as NSString).appendingPathComponent(
        "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    )
    return FileManager.default.fileExists(atPath: path)
}

private static func scanApplications() -> String? {
    let fm = FileManager.default
    let canonical = "/Applications/Xcode.app/Contents/Developer"
    if hasSimulatorKit(at: canonical) { return canonical }
    let entries = (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
    for app in entries.sorted()
    where app.hasPrefix("Xcode") && app.hasSuffix(".app") && app != "Xcode.app" {
        let dev = "/Applications/\(app)/Contents/Developer"
        if hasSimulatorKit(at: dev) { return dev }
    }
    return nil
}
```

The `xcode-select -p` answer can point at `CommandLineTools`
(`/Library/Developer/CommandLineTools`), which has no SimulatorKit.
The two-step "validate, fall back to scanning" pattern handles that.

## Loading the frameworks

```swift
static func loadFrameworks() {
    let dev = developerDir()
    let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    let simKit = (dev as NSString)
        .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
    if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil {
        logErr("CoreSimulator load failed: \(dlerrorString())")
    }
    if dlopen(simKit, RTLD_NOW | RTLD_GLOBAL) == nil {
        logErr("SimulatorKit load failed: \(dlerrorString())")
    }
}

func dlerrorString() -> String {
    guard let err = dlerror() else { return "(null)" }
    return String(cString: err)
}
```

Call this **once** per process — `loadFrameworks` guards with a static
`loaded` flag.

`RTLD_NOW` resolves all symbols immediately (we want to fail fast).
`RTLD_GLOBAL` makes the symbols visible to subsequently-loaded
dylibs, which matters because SimulatorKit transitively references
CoreSimulator symbols.

## Symbol resolution

For Indigo / IOHIDEvent symbols, use `dlsym`:

```swift
guard let handle = dlopen(simKitPath, RTLD_NOW) else { return }
let mouseSym = dlsym(handle, "IndigoHIDMessageForMouseNSEvent")
```

IOHIDEvent symbols live in the **dyld shared cache** (`IOKit`'s
public-but-not-publicly-headered C functions). Use the special
`RTLD_DEFAULT` handle:

```swift
let dyld = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
let sym = dlsym(dyld, "IOHIDEventCreateDigitizerEvent")
```

For class lookups use the ObjC runtime, not `dlsym`:

```swift
guard let cls = NSClassFromString("SimServiceContext") else { return }
```

## App Sandbox

**Disabled.** Private frameworks won't `dlopen` under the App
Sandbox; the sandbox's allow-list doesn't include them. Sims
ships with the sandbox off.

In the Xcode project, the `.entitlements` file either omits
`com.apple.security.app-sandbox` entirely or sets it to `false`.
Hardened runtime is fine (and useful for code-signing later) as
long as we **don't** add `com.apple.security.cs.disable-library-validation`-
adjacent restrictions; the default hardened-runtime allows
arbitrary `dlopen`.

## Code signing

Out of scope for v1 (see `project.md` non-goals). For local dev runs
the app is unsigned or ad-hoc-signed; macOS will Gatekeeper-warn on
first launch and the user can right-click → Open to bypass.

When (if) we sign in the future, the hardened-runtime entitlements
list will need:

- `com.apple.security.cs.allow-unsigned-executable-memory` — IOSurface
  → CALayer involves IOKit shared-memory regions; some hardened
  rules trip on these.
- `com.apple.security.get-task-allow` for debug builds (lets Xcode
  attach the debugger).

We'll revisit this when we hit it.

## Frameworks not to worry about

`IOSurface`, `CoreGraphics`, `QuartzCore`, `AppKit` are all public,
stable, headered, sandbox-safe. Link them normally; no `dlopen`.

`VideoToolbox`, `CoreVideo`, `ImageIO` are public too but we don't
use them in v1 (no encoding pipeline). Add the linker entries later
if encoding lands.
