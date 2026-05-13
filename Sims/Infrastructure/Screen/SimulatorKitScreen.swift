import Foundation
import IOSurface
import ObjectiveC

/// Production `Screen` — subscribes to SimulatorKit's framebuffer
/// callbacks via the ObjC runtime and forwards `IOSurface` frames as
/// they arrive. Pure pass-through; cadence policy belongs to the
/// consumer (a `CALayer` that just keeps re-assigning `contents`).
///
/// Multi-descriptor: simulators expose secondary planes / overlays.
/// We register on every `com.apple.framebuffer.display` descriptor and
/// hand the consumer whichever currently has the largest live surface.
///
/// See `.claude/knowledge/simulatorkit-framebuffer.md` for the recipe.
final class SimulatorKitScreen: Screen, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    private let queue = DispatchQueue(label: "sims.fb", qos: .userInteractive)

    private var ioClient: NSObject?
    private var descriptors: [NSObject] = []
    private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
    private var onFrame: (@Sendable (IOSurface) -> Void)?

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        self.onFrame = onFrame

        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        guard let io = device.perform(NSSelectorFromString("io"))?
            .takeUnretainedValue() as? NSObject
        else {
            throw ScreenError.ioUnavailable
        }
        self.ioClient = io
        try wireFramebuffer()
    }

    func stop() {
        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for desc in descriptors {
            if let uuid = callbackUUIDs[ObjectIdentifier(desc)],
               desc.responds(to: unregSel) {
                desc.perform(unregSel, with: uuid)
            }
        }
        descriptors.removeAll()
        callbackUUIDs.removeAll()
        ioClient = nil
        onFrame = nil
    }

    // MARK: - private

    private func wireFramebuffer() throws {
        guard let io = ioClient else { throw ScreenError.ioUnavailable }

        // Lazy population — `deviceIOPorts` is empty until this fires.
        io.perform(NSSelectorFromString("updateIOPorts"))

        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw ScreenError.noFramebuffer
        }

        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")

        var candidates: [NSObject] = []
        for port in ports where port.responds(to: pidSel) {
            guard let pid = port.perform(pidSel)?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfSel)
            else { continue }
            candidates.append(desc)
        }
        guard !candidates.isEmpty else { throw ScreenError.noFramebuffer }
        descriptors = candidates

        for desc in candidates {
            try registerCallbacks(on: desc)
        }
    }

    private func registerCallbacks(on desc: NSObject) throws {
        let regSel = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard desc.responds(to: regSel) else { throw ScreenError.callbackUnavailable }

        let uuid = NSUUID()
        callbackUUIDs[ObjectIdentifier(desc)] = uuid

        // Frame + surfaces-changed both signal "a new IOSurface is
        // available"; we just re-pull. The properties callback fires
        // on color-space / format changes which we don't react to.
        let frame: @convention(block) @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.captureLatest() }
        }
        let surfaces: @convention(block) @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.captureLatest() }
        }
        let props: @convention(block) @Sendable () -> Void = {}

        guard let imp = class_getMethodImplementation(type(of: desc), regSel) else {
            throw ScreenError.callbackUnavailable
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(
            desc, regSel,
            uuid, queue as AnyObject,
            frame as AnyObject, surfaces as AnyObject, props as AnyObject
        )
    }

    /// Walk every registered descriptor, pick the one whose live
    /// surface has the largest pixel area (overlays / secondary planes
    /// are typically smaller than the main display), and emit it.
    private func captureLatest() {
        let surfSel = NSSelectorFromString("framebufferSurface")
        var best: IOSurface?
        var bestArea = 0
        for desc in descriptors {
            guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
            // The framebufferSurface accessor returns an IOSurfaceRef that
            // bridges to Swift's IOSurface; `unsafeDowncast` is the
            // compiler-recommended form (debug-asserts the type, release
            // skips the check).
            let surf = unsafeDowncast(surfObj, to: IOSurface.self)
            let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
            if area > bestArea {
                best = surf
                bestArea = area
            }
        }
        if let best, let onFrame {
            onFrame(best)
        }
    }
}
