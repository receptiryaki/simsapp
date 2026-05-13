import Foundation
import IOSurface

/// The simulator's screen — a stream of GPU framebuffer surfaces. Two
/// verbs: `start` to subscribe, `stop` to tear down. Per simulator.
///
/// `IOSurface` is a public Apple type (zero-copy framebuffer), not
/// private API, so it's safe to expose at the domain boundary.
protocol Screen: AnyObject, Sendable {
    /// Subscribe to frame delivery. Throws if the framebuffer pipe can't
    /// be wired (e.g. the simulator isn't booted). The closure runs on
    /// the screen adapter's own dispatch queue.
    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws

    /// Tear down callbacks and release the underlying screen object.
    func stop()
}

/// Failure modes the screen adapter surfaces.
enum ScreenError: Error, Equatable {
    case ioUnavailable
    case noFramebuffer
    case callbackUnavailable
}
