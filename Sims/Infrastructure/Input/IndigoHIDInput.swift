import Foundation
import ObjectiveC

/// Production `Input` — dispatches gestures into SimulatorKit's HID
/// pipeline. Taps / touch sequences ride the iOS 26 digitizer recipe
/// in `IOHIDDigitizerDispatch`; scroll rides
/// `IndigoHIDMessageForScrollEvent`; keys ride
/// `IndigoHIDMessageForHIDArbitrary`.
///
/// One instance per simulator. The first dispatch warms a
/// `SimDeviceLegacyHIDClient` (init + pointer + mouse service
/// primers); subsequent dispatches reuse it for the instance's
/// lifetime.
///
/// See `.claude/knowledge/indigo-hid.md`.
final class IndigoHIDInput: Input, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost

    private var client: AnyObject?
    private var warmed = false
    private let lock = NSLock()

    // MARK: cached SimulatorKit symbols

    private typealias HIDArbitraryFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonFn       = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ScrollFn       = @convention(c) (UInt32, Double, Double, Double, UInt32) -> UnsafeMutableRawPointer?
    private typealias ServiceFn      = @convention(c) () -> UnsafeMutableRawPointer?

    private var hidArbFn:        HIDArbitraryFn?
    private var buttonFn:        ButtonFn?
    private var scrollFn:        ScrollFn?
    private var createPointerSvc: ServiceFn?
    private var createMouseSvc:   ServiceFn?
    private var removePointerSvc: ServiceFn?

    /// Target ids used to talk to backboardd's HID services. These
    /// values predate the iOS 26 RE work — we kept them because the
    /// alternative (registering the proper services via hand-crafted
    /// IndigoHID create-service messages) routes touches to the wrong
    /// pipeline. Occasional backboardd assertion failures are the
    /// trade-off until we have a working
    /// `createDigitizerForTargetID:withDisplayUID:` recipe.
    private static let mainScreenTouch:   UInt32 = 0x32
    private static let homeButtonTarget:  UInt32 = 0x33
    private static let physicalButton:    UInt32 = 0x32

    // MARK: touch identifier + edge — sticky within a touch1 sequence

    private var touchIdentifierCounter: UInt32 = 0
    private var stickyTouchIdentifier:  UInt32?
    /// Edge bit applied to every event in the current touch1 sequence.
    /// Resolved on `.down` from the start point; cleared on the next
    /// `.down`. Without this, swipe-up-from-bottom is delivered as an
    /// interior pan and iOS's home-indicator recogniser never fires.
    private var stickyTouchEdge: IOHIDDigitizerDispatch.Edge = .none

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    deinit {
        // Tear down the pointer service we created on warmup so the
        // simulator-side bookkeeping stays clean. Best-effort — if
        // anything is missing we just bail.
        if warmed, let client, let remove = removePointerSvc, let msg = remove() {
            Self.send(message: msg, to: client)
        }
    }

    // MARK: - Input

    func tap(at point: Point, size: Size, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let normalised = CGPoint(
            x: clamp01(point.x / size.width),
            y: clamp01(point.y / size.height)
        )
        return IOHIDDigitizerDispatch.tap(
            point: normalised,
            holdSeconds: duration > 0 ? duration : 0.05,
            edge: .none,
            identifier: nextTouchIdentifier(),
            on: c
        )
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool {
        guard let c = ensureWarm() else { return false }
        let normalised = CGPoint(
            x: clamp01(point.x / size.width),
            y: clamp01(point.y / size.height)
        )
        let dispatchPhase: IOHIDDigitizerDispatch.Phase
        switch phase {
        case .down: dispatchPhase = .down
        case .move: dispatchPhase = .move
        case .up:   dispatchPhase = .up
        }
        // Sticky id + edge: fresh on `.down`, reused through `.up`.
        // iOS threads the touch sequence by id, and the home-indicator
        // / status-bar gesture recognisers only fire when *every* event
        // in the sequence carries the matching edge bit.
        if phase == .down {
            stickyTouchIdentifier = nextTouchIdentifier()
            stickyTouchEdge = Self.edgeForTouchStart(at: normalised)
        }
        let id = stickyTouchIdentifier ?? nextTouchIdentifier()
        return IOHIDDigitizerDispatch.send(
            point: normalised, identifier: id,
            phase: dispatchPhase, edge: stickyTouchEdge,
            on: c
        )
    }

    /// Classify the start point of a touch sequence as one of the iOS
    /// system gesture zones. `bottom` is the home indicator (swipe-up
    /// → Home; slow swipe with dwell → App Switcher); `top` is the
    /// status-bar zone (pull from top-left → Lock screen, top-right →
    /// Notification Center; Control Center on older devices). iOS's
    /// gesture recognisers do their own velocity/dwell discrimination —
    /// we just have to flag the sequence as edge-originated.
    ///
    /// Thresholds are deliberately tight (3% at bottom, 0.5% at top)
    /// so interior touches near the screen edge don't get mis-routed.
    /// Real home-indicator-zone touches normalise to y > 0.99 because
    /// the indicator sits in the bottom ~25 points of a ~900pt screen.
    private static func edgeForTouchStart(at p: CGPoint) -> IOHIDDigitizerDispatch.Edge {
        if p.y >= 0.97  { return .bottom }
        if p.y <= 0.005 { return .top }
        return .none
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        guard let c = ensureWarm(), let sfn = scrollFn else { return false }
        // IndigoHIDMessageForScrollEvent(uint32, dx, dy, dz, IndigoHIDTarget)
        // — the trailing target slot must be set or the message routes
        // to a random service and backboardd aborts.
        guard let msg = sfn(0x13, deltaX, deltaY, 0, Self.mainScreenTouch) else { return false }
        Self.send(message: msg, to: c)
        return true
    }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        guard let c = ensureWarm() else { return false }
        let holdUs = holdMicroseconds(for: duration)
        switch button {
        case .home:
            // IndigoHIDMessageForButton(keycode, op, target). Apple's
            // Simulator.app passes target=0x0b for the Home button —
            // that's the IndigoHIDTarget that backboardd registers a
            // service for. SpringBoard listens to this event source on
            // every device, Face ID included, and delivers the instant
            // Home transition rather than the visible swipe animation.
            return pressLegacyButton(arg0: 0x0, target: Self.homeButtonTarget, holdUs: holdUs, on: c)
        case .lock:
            // Physical-button target (lock/side button live here too).
            return pressLegacyButton(arg0: 0x1, target: Self.physicalButton, holdUs: holdUs, on: c)
        case .volumeUp, .volumeDown:
            guard let usage = button.standardHIDUsage else { return false }
            return pressArbitraryHID(usage: usage, holdUs: holdUs, on: c)
        }
    }

    private func pressLegacyButton(arg0: UInt32, target: UInt32, holdUs: UInt32, on client: AnyObject) -> Bool {
        guard let bfn = buttonFn else {
            logErr("[hid] button — IndigoHIDMessageForButton unresolved")
            return false
        }
        guard let down = bfn(arg0, 1, target) else { return false }
        Self.send(message: down, to: client)
        usleep(holdUs)
        // direction=2 for release; passing 0 crashes backboardd on iOS 26.4.
        guard let up = bfn(arg0, 2, target) else { return false }
        Self.send(message: up, to: client)
        return true
    }

    private func pressArbitraryHID(usage: HIDUsage, holdUs: UInt32, on client: AnyObject) -> Bool {
        guard let kfn = hidArbFn else {
            logErr("[hid] button — IndigoHIDMessageForHIDArbitrary unresolved")
            return false
        }
        let target = Self.physicalButton
        guard let down = kfn(target, usage.page, usage.usage, 1) else { return false }
        Self.send(message: down, to: client)
        usleep(holdUs)
        guard let up = kfn(target, usage.page, usage.usage, 2) else { return false }
        Self.send(message: up, to: client)
        return true
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let c = ensureWarm(), let kfn = hidArbFn else {
            logErr("[hid] key — IndigoHIDMessageForHIDArbitrary unresolved")
            return false
        }
        let holdUs = holdMicroseconds(for: duration)
        let target = Self.physicalButton
        // Sorted modifiers so the down/up order is deterministic. iOS
        // doesn't care; logs do.
        let mods = modifiers.sorted()

        for m in mods {
            guard let down = kfn(target, m.hidUsage.page, m.hidUsage.usage, 1) else { return false }
            Self.send(message: down, to: c)
        }
        guard let keyDown = kfn(target, key.hidUsage.page, key.hidUsage.usage, 1) else { return false }
        Self.send(message: keyDown, to: c)
        usleep(holdUs)
        guard let keyUp = kfn(target, key.hidUsage.page, key.hidUsage.usage, 2) else { return false }
        Self.send(message: keyUp, to: c)
        for m in mods.reversed() {
            guard let up = kfn(target, m.hidUsage.page, m.hidUsage.usage, 2) else { return false }
            Self.send(message: up, to: c)
        }
        return true
    }

    // MARK: - private

    private func nextTouchIdentifier() -> UInt32 {
        touchIdentifierCounter &+= 1
        if touchIdentifierCounter == 0 { touchIdentifierCounter = 1 }
        return touchIdentifierCounter
    }

    private func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }

    /// Default key/tap hold is 100ms. Clamp the floor at 20ms so a
    /// zero-duration request doesn't underrun the HID dispatcher.
    private func holdMicroseconds(for duration: Double) -> UInt32 {
        guard duration > 0 else { return 100_000 }
        let us = duration * 1_000_000
        return UInt32(min(max(us, 20_000), Double(UInt32.max)))
    }

    /// Lazy resolve + warm. Synchronised because gestures can come
    /// from multiple threads in a streaming session.
    private func ensureWarm() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }

        resolveFunctions()

        guard let device = host.resolveDevice(udid: udid) else { return nil }
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            logErr("SimDeviceLegacyHIDClient class not found")
            return nil
        }

        // [SimDeviceLegacyHIDClient alloc] init: alloc on metaclass, then
        // initWithDevice:error: on the instance.
        guard let metaCls = object_getClass(cls) else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocImp = class_getMethodImplementation(metaCls, allocSel) else { return nil }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, allocSel) else { return nil }

        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let initImp = class_getMethodImplementation(cls, initSel) else { return nil }
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        var err: NSError?
        guard let c = unsafeBitCast(initImp, to: InitFn.self)(allocated, initSel, device, &err) else {
            if let err { logErr("SimDeviceLegacyHIDClient init failed: \(err)") }
            return nil
        }
        client = c
        warmServices(on: c)
        warmed = true
        return c
    }

    private func resolveFunctions() {
        guard hidArbFn == nil else { return }
        let dev = CoreSimulators.developerDir()
        let path = (dev as NSString).appendingPathComponent(
            "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        )
        guard let handle = dlopen(path, RTLD_NOW) else {
            logErr("SimulatorKit dlopen failed (input): \(dlerrorString())")
            return
        }
        hidArbFn         = dlsym(handle, "IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: HIDArbitraryFn.self) }
        buttonFn         = dlsym(handle, "IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFn.self) }
        scrollFn         = dlsym(handle, "IndigoHIDMessageForScrollEvent").map { unsafeBitCast($0, to: ScrollFn.self) }
        createPointerSvc = dlsym(handle, "IndigoHIDMessageToCreatePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
        createMouseSvc   = dlsym(handle, "IndigoHIDMessageToCreateMouseService").map { unsafeBitCast($0, to: ServiceFn.self) }
        removePointerSvc = dlsym(handle, "IndigoHIDMessageToRemovePointerService").map { unsafeBitCast($0, to: ServiceFn.self) }
    }

    /// Prime the pointer and mouse services on the freshly-allocated
    /// HID client. The simulator side hangs the first touch on a
    /// brand-new client without these.
    private func warmServices(on client: AnyObject) {
        if let create = createPointerSvc, let msg = create() {
            Self.send(message: msg, to: client)
            usleep(20_000)
        }
        if let create = createMouseSvc, let msg = create() {
            Self.send(message: msg, to: client)
            usleep(20_000)
        }
    }

    /// `[SimDeviceLegacyHIDClient sendWithMessage:freeWhenDone:completionQueue:completion:]`.
    /// Fire-and-forget: `freeWhenDone = YES`, no completion queue or
    /// callback. Static so `IOHIDDigitizerDispatch` and warmup paths
    /// share the same call site.
    static func send(message: UnsafeMutableRawPointer, to client: AnyObject) {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, sel) else { return }
        typealias Fn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
    }
}
