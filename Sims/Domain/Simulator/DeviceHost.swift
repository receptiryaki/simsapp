import Foundation

/// Lookup port for live `SimDevice` `NSObject`s by UDID. Adapters that
/// need to act on the underlying ObjC device (`Infrastructure/Screen/`,
/// `Infrastructure/Input/` in later phases) depend on this rather than
/// the concrete aggregate, so they can be tested with an `NSObject`
/// stand-in.
///
/// Returns `NSObject?` rather than a typed `SimDevice` because
/// `SimDevice` is a private ObjC class. Adapters interact via the
/// runtime (`value(forKey:)`, `responds(to:)`,
/// `class_getMethodImplementation`).
protocol DeviceHost: AnyObject, Sendable {
    /// Look up the underlying `SimDevice` for a UDID. Returns `nil`
    /// when the device set has no match (or CoreSimulator failed to
    /// load).
    func resolveDevice(udid: String) -> NSObject?
}
