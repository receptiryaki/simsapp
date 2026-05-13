import Foundation

/// The host's collection of simulators. Lists what's available and
/// looks up by UDID. Capabilities (boot, shutdown, future screen/input
/// accessors) live on `Simulator` itself.
protocol Simulators: AnyObject, Sendable {
    var all: [any Simulator] { get }
    func find(udid: String) -> (any Simulator)?
}
