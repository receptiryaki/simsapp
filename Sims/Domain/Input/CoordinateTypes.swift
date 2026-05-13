import Foundation

/// A point in the simulator's screen-space, in whatever units the
/// caller is using (typically points). The infrastructure adapter
/// normalises by the accompanying `Size` before handing to IndigoHID.
/// Top-left origin.
struct Point: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// Screen size in the same units as the accompanying `Point`. Carried
/// with every gesture so the dispatch layer can normalise without
/// knowing which device is the target.
struct Size: Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Phase of a streaming touch gesture.
enum GesturePhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up
}

/// HID (page, usage) pair — the wire-level code SimulatorKit needs
/// to identify an arbitrary-HID input (keyboard key, side button).
struct HIDUsage: Equatable, Hashable, Sendable {
    let page: UInt32
    let usage: UInt32
}

/// Hardware buttons + virtual gestures routable into the simulator.
///
/// `home` and `lock` ride `IndigoHIDMessageForButton` (legacy iPhone
/// hardware-button path). `volumeUp` / `volumeDown` ride
/// `IndigoHIDMessageForHIDArbitrary` keyed by HID consumer-page codes
/// — same codes every shipping iPhone's chrome.json publishes. The
/// `home` case additionally falls back to the digitizer swipe-up
/// gesture on Face ID devices that lack a physical home button.
enum DeviceButton: String, Sendable, Equatable, Hashable {
    case home
    case lock
    case volumeUp   = "volume-up"
    case volumeDown = "volume-down"

    /// HID (page, usage) for buttons that ride
    /// `IndigoHIDMessageForHIDArbitrary`. `home`/`lock` return `nil` —
    /// they go through a different SimulatorKit symbol.
    var standardHIDUsage: HIDUsage? {
        switch self {
        case .home, .lock: return nil
        case .volumeUp:   return HIDUsage(page: 12, usage: 233)
        case .volumeDown: return HIDUsage(page: 12, usage: 234)
        }
    }
}
