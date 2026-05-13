import Foundation
import ObjectiveC

/// Production `Simulator` — owns identity + state and exposes the
/// boot/shutdown verbs. Resolves a fresh `SimDevice` via
/// `host.resolveDevice(udid:)` on each operation, never caches the
/// `NSObject` — CoreSimulator returns new refs on each enumeration
/// and the old ones go stale across state transitions.
final class CoreSimulator: Simulator, @unchecked Sendable {
    let udid: String
    let name: String
    let state: SimulatorState
    let runtime: String
    let deviceTypeName: String

    private let host: any DeviceHost

    init(
        udid: String,
        name: String,
        state: SimulatorState,
        runtime: String,
        deviceTypeName: String,
        host: any DeviceHost
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.deviceTypeName = deviceTypeName
        self.host = host
    }

    func boot() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }

        // Prefer `bootWithOptions:error:` with `persist: true` — boots
        // headlessly and keeps the simulator alive past our process
        // exit, which is what users want from an app like this.
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootOpts) {
            var err: NSError?
            let opts: NSDictionary = ["persist": true]
            if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
            if let err { logErr("bootWithOptions failed: \(err)") }
        }

        // Fall back to the no-options variant if the options selector
        // is gone in some future CoreSimulator. The framework has kept
        // both shapes around for several Xcodes.
        let bootSel = NSSelectorFromString("bootWithError:")
        if device.responds(to: bootSel) {
            var err: NSError?
            if invokeBoolWithError(device, bootSel, &err) { return }
            if let err { logErr("bootWithError failed: \(err)") }
        }

        throw SimulatorError.bootFailed
    }

    func shutdown() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        let sel = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: sel) else { throw SimulatorError.shutdownFailed }
        var err: NSError?
        guard invokeBoolWithError(device, sel, &err) else {
            if let err { logErr("shutdownWithError failed: \(err)") }
            throw SimulatorError.shutdownFailed
        }
    }

    func screen() -> any Screen {
        SimulatorKitScreen(udid: udid, host: host)
    }

    func input() -> any Input {
        IndigoHIDInput(udid: udid, host: host)
    }
}
