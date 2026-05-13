import Foundation

/// One iOS simulator on the host. Identity (`udid`, `name`), current
/// `state`, runtime, and the verbs the user invokes on it. The
/// production impl lives in `Infrastructure/Simulator/CoreSimulator.swift`.
protocol Simulator: Sendable {
    var udid: String { get }
    var name: String { get }
    var state: SimulatorState { get }

    /// Display name of the simulator's iOS runtime — `"iOS 26.4"`.
    /// Empty string when the host didn't populate it.
    var runtime: String { get }

    /// CoreSimulator device-type name — e.g. `"iPhone 17 Pro Max"`,
    /// the stable filename of the `.simdevicetype` bundle. Survives
    /// `simctl clone` / rename where `name` does not.
    var deviceTypeName: String { get }

    func boot() throws
    func shutdown() throws

    /// Subscribe to this simulator's framebuffer stream. Each call
    /// returns a fresh `Screen`; multiple concurrent subscriptions
    /// are supported. Adapter-internal — the underlying framework
    /// (SimulatorKit) supports many subscribers per device.
    func screen() -> any Screen

    /// Open an input channel into this simulator. Each call returns a
    /// fresh `Input`; the underlying `SimDeviceLegacyHIDClient` is
    /// warmed lazily on first dispatch and torn down with the adapter.
    func input() -> any Input
}

/// Lifecycle states a `SimDevice` can be in. Raw values match
/// CoreSimulator's `SimDevice.state` ints (verified iOS 26.4).
enum SimulatorState: Sendable, Equatable {
    case creating
    case shutdown
    case booting
    case booted
    case shuttingDown

    var description: String {
        switch self {
        case .creating:     return "Creating"
        case .shutdown:     return "Shutdown"
        case .booting:      return "Booting"
        case .booted:       return "Booted"
        case .shuttingDown: return "Shutting Down"
        }
    }
}

extension Simulator {
    var canBoot:     Bool { state != .booted && state != .booting }
    var canShutdown: Bool { state == .booted || state == .booting }
}

/// Failure modes the host surfaces.
enum SimulatorError: Error, Equatable {
    case bootFailed
    case shutdownFailed
    case notFound(udid: String)
}
