import Foundation
import ObjectiveC

/// The iOS 26 digitizer-dispatch path. Builds a real `IOHIDEvent`
/// digitizer parent + finger child, runs it through
/// `IndigoHIDMessageForTrackpadEventFromHIDEventRef`, and patches two
/// byte slots the wrapper leaves uninitialised. The result is a
/// touch message iOS 26's HID stack delivers correctly — bypassing
/// the `IndigoHIDMessageForMouseNSEvent` regression where single-
/// finger taps get misinterpreted as Home gestures or silently drop.
///
/// See `.claude/knowledge/indigo-hid.md` for the recipe, offset
/// table, and the diagnostic trail.
enum IOHIDDigitizerDispatch {

    /// Screen-edge bitmask the patch writes at byte 0x3b/0xdb of the
    /// Indigo message. `.none` for interior touches; `.bottom` is the
    /// home-indicator path; `.top` / `.left` / `.right` are reserved
    /// for future edge gestures.
    enum Edge {
        case none, left, top, right, bottom

        var bit: UInt8 {
            switch self {
            case .none:   return 0x00
            case .left:   return 0x02
            case .top:    return 0x08
            case .right:  return 0x04
            case .bottom: return 0x01
            }
        }
    }

    /// Phase of a touch sequence. Determines `IOHIDDigitizerEventMask`
    /// bits and the range/touch flags iOS uses to thread the touch
    /// state through its gesture recognisers.
    enum Phase {
        case down, move, up

        var eventMask: UInt32 {
            switch self {
            case .down, .move: return 0x07     // Range | Touch | Position
            case .up:          return 0x06     // Touch | Position (lift)
            }
        }
        var range: Bool { self != .up }
        var touch: Bool { self != .up }
    }

    // MARK: one-shot helpers

    /// Single-finger tap at `point` (normalised 0..1). Down → hold for
    /// `holdSeconds` → up at the same point with the same identifier.
    @discardableResult
    static func tap(
        point: CGPoint, holdSeconds: Double,
        edge: Edge = .none, identifier: UInt32,
        on client: AnyObject
    ) -> Bool {
        guard send(point: point, identifier: identifier,
                   phase: .down, edge: edge, on: client) else { return false }
        let holdUs = UInt32(max(0.02, holdSeconds) * 1_000_000)
        usleep(holdUs)
        return send(point: point, identifier: identifier,
                    phase: .up, edge: edge, on: client)
    }

    /// Continuous swipe from `start` to `end` over `steps` interpolated
    /// moves. `dwellMs` resends the last move N times — used by the
    /// bottom-edge App Switcher path; iOS reads dwell as Home vs App
    /// Switcher.
    @discardableResult
    static func swipe(
        from start: CGPoint, to end: CGPoint,
        steps: Int = 10, stepMs: UInt32 = 16, dwellMs: UInt32 = 0,
        edge: Edge = .none, identifier: UInt32,
        on client: AnyObject
    ) -> Bool {
        guard send(point: start, identifier: identifier,
                   phase: .down, edge: edge, on: client) else { return false }
        var ok = 0
        for i in 1...steps {
            usleep(stepMs * 1000)
            let t = Double(i) / Double(steps)
            let p = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            if send(point: p, identifier: identifier,
                    phase: .move, edge: edge, on: client) { ok += 1 }
        }
        if dwellMs > 0 {
            let pulses = max(1, Int(dwellMs / 50))
            for _ in 0..<pulses {
                _ = send(point: end, identifier: identifier,
                         phase: .move, edge: edge, on: client)
                usleep(50_000)
            }
        }
        usleep(stepMs * 1000)
        return send(point: end, identifier: identifier,
                    phase: .up, edge: edge, on: client) && ok >= steps / 2
    }

    // MARK: primitive

    /// Build, patch, and dispatch one digitizer event.
    @discardableResult
    static func send(
        point: CGPoint, identifier: UInt32,
        phase: Phase, edge: Edge,
        on client: AnyObject
    ) -> Bool {
        guard ensureSymbols() else { return false }
        guard let parent = makeDigitizerEvent(
            point: point, identifier: identifier, phase: phase
        ) else { return false }
        // `withExtendedLifetime` keeps the CF parent alive long enough
        // for the wrapper to copy out the data.
        let raw: UnsafeMutableRawPointer? = withExtendedLifetime(parent) {
            wrapTrackpad(event: parent)
        }
        guard let raw else { return false }
        patch(message: raw, edge: edge)
        sendMessage(raw, to: client)
        return true
    }

    // MARK: private — IOHIDEvent construction

    /// Parent digitizer event + finger child appended to it. iOS expects
    /// touches as parent+child pairs; a bare finger event produces a
    /// 192-byte wrapper stub iOS ignores.
    private static func makeDigitizerEvent(
        point: CGPoint, identifier: UInt32, phase: Phase
    ) -> CFTypeRef? {
        guard let createParent = createDigitizerFn,
              let createFinger = createFingerFn,
              let appendFn      = appendEventFn else { return nil }

        let mask = phase.eventMask
        let range = phase.range
        let touch = phase.touch
        let pressure = 0.0     // non-zero crashed earlier; 0.0 is safe
        let now = mach_absolute_time()
        let transducerFinger: UInt32 = 2   // kIOHIDDigitizerTransducerTypeFinger

        guard let parentUM = createParent(
            nil, now, transducerFinger,
            0, identifier, mask, 0,
            point.x, point.y, 0.0,
            pressure, 0.0,
            range, touch, 0
        ) else { return nil }
        let parent = parentUM.takeRetainedValue()

        guard let fingerUM = createFinger(
            nil, now,
            0, identifier, mask,
            point.x, point.y, 0.0,
            pressure, 0.0,
            range, touch, 0
        ) else { return parent }
        let finger = fingerUM.takeRetainedValue()
        appendFn(parent, finger, 0)
        return parent
    }

    private static func wrapTrackpad(event: CFTypeRef) -> UnsafeMutableRawPointer? {
        guard let wrapFn = trackpadWrapFn else { return nil }
        let raw = Unmanaged.passUnretained(event as AnyObject).toOpaque()
        // The IndigoHIDTarget arg is overwritten below by the patch at
        // msg[0x6c], so the value passed here doesn't matter. Use 0.
        return wrapFn(raw, 0)
    }

    /// Patch the two byte slots the trackpad wrapper leaves
    /// uninitialised. Both must be set for iOS to consume the touch.
    ///
    ///   0x6c + 0x10c → IndigoHIDTouchTarget (0x32 = digitizer)
    ///   0x3a/0x3b + 0xda/0xdb → edge bitmask (present byte + edge bit)
    private static func patch(message msg: UnsafeMutableRawPointer, edge: Edge) {
        let target: UInt32 = 0x32
        msg.storeBytes(of: target, toByteOffset: 0x6c, as: UInt32.self)
        let size = malloc_size(msg)
        if size >= 0x110 {
            msg.storeBytes(of: target, toByteOffset: 0x10c, as: UInt32.self)
        }
        let edgeBit = edge.bit
        let edgePresent: UInt8 = edgeBit == 0 ? 0x00 : 0x04
        msg.storeBytes(of: edgePresent, toByteOffset: 0x3a, as: UInt8.self)
        msg.storeBytes(of: edgeBit,     toByteOffset: 0x3b, as: UInt8.self)
        if size >= 0xdc {
            msg.storeBytes(of: edgePresent, toByteOffset: 0xda, as: UInt8.self)
            msg.storeBytes(of: edgeBit,     toByteOffset: 0xdb, as: UInt8.self)
        }
    }

    private static func sendMessage(_ message: UnsafeMutableRawPointer, to client: AnyObject) {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, sel) else { return }
        typealias Fn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
    }

    // MARK: private — symbol resolution

    /// `IOHIDEventCreateDigitizerEvent(allocator, ts, transducer,
    ///   index, identifier, eventMask, buttonMask,
    ///   x, y, z, tipPressure, barrelPressure,
    ///   range, touch, options)` — 9 ints + 5 doubles.
    typealias CreateDigitizerFn = @convention(c) (
        CFAllocator?, UInt64, UInt32,
        UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double,
        Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?

    /// `IOHIDEventCreateDigitizerFingerEvent(allocator, ts, index,
    ///   identifier, eventMask, x, y, z, tipPressure, twist,
    ///   range, touch, options)` — 8 ints + 5 doubles.
    typealias CreateFingerFn = @convention(c) (
        CFAllocator?, UInt64,
        UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double,
        Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?

    typealias AppendEventFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    typealias TrackpadWrapFn = @convention(c) (UnsafeRawPointer, UInt32) -> UnsafeMutableRawPointer?

    // Write-once function pointers cached on first dispatch.
    nonisolated(unsafe) private static var createDigitizerFn: CreateDigitizerFn?
    nonisolated(unsafe) private static var createFingerFn:    CreateFingerFn?
    nonisolated(unsafe) private static var appendEventFn:     AppendEventFn?
    nonisolated(unsafe) private static var trackpadWrapFn:    TrackpadWrapFn?
    nonisolated(unsafe) private static var symbolsResolved = false

    /// Lazy resolve of the four C symbols. IOKit symbols
    /// (event creation + append) live in the dyld shared cache —
    /// `RTLD_DEFAULT` is enough. The trackpad wrapper requires
    /// dlopen-ing SimulatorKit explicitly.
    private static func ensureSymbols() -> Bool {
        if symbolsResolved { return true }
        let dev = CoreSimulators.developerDir()
        let kitPath = (dev as NSString).appendingPathComponent(
            "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        )
        guard let kit = dlopen(kitPath, RTLD_NOW) else {
            logErr("SimulatorKit dlopen failed: \(dlerrorString())")
            return false
        }
        let dyld = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let pCreateDig = dlsym(dyld, "IOHIDEventCreateDigitizerEvent"),
              let pCreateFin = dlsym(dyld, "IOHIDEventCreateDigitizerFingerEvent"),
              let pAppend    = dlsym(dyld, "IOHIDEventAppendEvent"),
              let pWrap      = dlsym(kit,  "IndigoHIDMessageForTrackpadEventFromHIDEventRef")
        else {
            logErr("digitizer symbols unresolved")
            return false
        }
        createDigitizerFn = unsafeBitCast(pCreateDig, to: CreateDigitizerFn.self)
        createFingerFn    = unsafeBitCast(pCreateFin, to: CreateFingerFn.self)
        appendEventFn     = unsafeBitCast(pAppend,    to: AppendEventFn.self)
        trackpadWrapFn    = unsafeBitCast(pWrap,      to: TrackpadWrapFn.self)
        symbolsResolved = true
        return true
    }
}
