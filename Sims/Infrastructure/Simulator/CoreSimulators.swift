import Foundation
import ObjectiveC

/// Production `Simulators` — backed by CoreSimulator's private classes
/// reached through the ObjC runtime. No `import CoreSimulator`. Framework
/// loading is lazy and one-shot at first construction.
///
/// See `.claude/knowledge/coresimulator-api.md` for the selector and KVC
/// recipes this file uses.
final class CoreSimulators: Simulators, DeviceHost, @unchecked Sendable {
    init() {
        Self.loadFrameworks()
    }

    var all: [any Simulator] {
        guard let set = resolveSet() else { return [] }
        return availableDevices(in: set).map { device in
            simulator(from: device)
        }
    }

    func find(udid: String) -> (any Simulator)? {
        all.first { $0.udid == udid }
    }

    // MARK: DeviceHost

    /// Look up the underlying `SimDevice` `NSObject` for a UDID.
    /// Adapters in later phases (`SimulatorKitScreen`, `IndigoHIDInput`)
    /// depend on this rather than caching the device — CoreSimulator
    /// returns a fresh ref on each enumeration and the previous one
    /// becomes stale.
    func resolveDevice(udid: String) -> NSObject? {
        guard let set = resolveSet() else { return nil }
        for device in availableDevices(in: set) {
            if (device.value(forKey: "UDID") as? NSUUID)?.uuidString == udid {
                return device
            }
        }
        return nil
    }

    // MARK: device-set resolution

    private func resolveSet() -> NSObject? {
        guard let ctx = sharedServiceContext() else { return nil }
        return defaultDeviceSet(context: ctx)
    }

    private func sharedServiceContext() -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else { return nil }
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        var err: NSError?
        let ctx = invokeClassObjWithObjAndError(cls, sel, Self.developerDir() as NSString, &err)
        if ctx == nil, let err { logErr("sharedServiceContext: \(err)") }
        return ctx
    }

    private func defaultDeviceSet(context: NSObject) -> NSObject? {
        let sel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard context.responds(to: sel) else { return nil }
        var err: NSError?
        let set = invokeObjWithError(context, sel, &err)
        if set == nil, let err { logErr("defaultDeviceSet: \(err)") }
        return set
    }

    private func availableDevices(in set: NSObject) -> [NSObject] {
        (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    }

    // MARK: device → Simulator projection

    private func simulator(from device: NSObject) -> CoreSimulator {
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let name = (device.value(forKey: "name") as? String) ?? "Unknown"
        let raw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        // CoreSimulator's `runtime` is a SimRuntime object whose `name`
        // returns the user-facing version string ("iOS 26.4"). Fall back
        // to the runtime identifier and then to "" so we always hand the
        // UI at least a string.
        let runtimeName = (device.value(forKey: "runtime") as? NSObject).flatMap { rt -> String? in
            (rt.value(forKey: "name") as? String) ?? (rt.value(forKey: "versionString") as? String)
        } ?? ""
        // `deviceType.name` is the stable bundle filename — survives
        // `simctl clone` / rename where `device.name` doesn't.
        let deviceTypeName = (device.value(forKey: "deviceType") as? NSObject)
            .flatMap { $0.value(forKey: "name") as? String } ?? name
        return CoreSimulator(
            udid: udid,
            name: name,
            state: state(from: raw),
            runtime: runtimeName,
            deviceTypeName: deviceTypeName,
            host: self
        )
    }

    private func state(from raw: UInt) -> SimulatorState {
        switch raw {
        case 0: return .creating
        case 1: return .shutdown
        case 2: return .booting
        case 3: return .booted
        case 4: return .shuttingDown
        default: return .shutdown
        }
    }

    // MARK: framework loading

    nonisolated(unsafe) private static var loaded = false

    static func loadFrameworks() {
        guard !loaded else { return }
        loaded = true
        let dev = developerDir()
        let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        let simKit = (dev as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
        if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("CoreSimulator load failed: \(dlerrorString())")
        }
        // SimulatorKit isn't strictly needed for Phase 1 (no screen/input),
        // but loading it now surfaces any framework-discovery problems early
        // — and matches Phase 2+'s expectation that both are resident.
        if dlopen(simKit, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("SimulatorKit load failed: \(dlerrorString())")
        }
    }

    /// Resolve a developer directory that actually contains
    /// `SimulatorKit.framework`. `xcode-select -p` can point at
    /// `CommandLineTools` (no SimulatorKit) when CLT was installed
    /// before Xcode; fall back to scanning `/Applications` for any
    /// `Xcode*.app` whose `Contents/Developer` has the framework.
    static func developerDir() -> String {
        if let dev = xcodeSelectDir(), hasSimulatorKit(at: dev) { return dev }
        if let dev = scanApplications() { return dev }
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
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private static func hasSimulatorKit(at developerDir: String) -> Bool {
        let path = (developerDir as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
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
}

// MARK: - shared ObjC-runtime helpers

func dlerrorString() -> String {
    guard let err = dlerror() else { return "(null)" }
    return String(cString: err)
}

func logErr(_ message: String) {
    fputs("[sims] \(message)\n", stderr)
}

func invokeBoolWithError(
    _ target: NSObject, _ sel: Selector, _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err)
}

func invokeBoolWithObjAndError(
    _ target: NSObject, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, arg, &err)
}

func invokeObjWithError(
    _ target: NSObject, _ sel: Selector, _ err: inout NSError?
) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err) as? NSObject
}

func invokeClassObjWithObjAndError(
    _ cls: AnyClass, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> NSObject? {
    guard let metaCls = object_getClass(cls),
          let imp = class_getMethodImplementation(metaCls, sel)
    else { return nil }
    typealias Fn = @convention(c) (
        AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(cls, sel, arg, &err) as? NSObject
}
