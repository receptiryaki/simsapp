import Foundation

/// `xcrun simctl` wrappers. Callers dispatch from background queues —
/// every method blocks.
enum SimctlUtil {

    enum SimctlError: Error, CustomStringConvertible {
        case nonZeroExit(args: [String], status: Int32, stderr: String)
        case spawnFailed(Error)
        case parseFailed(String)

        var description: String {
            switch self {
            case .nonZeroExit(let args, let status, let stderr):
                let cmd = (["xcrun"] + args).joined(separator: " ")
                return "`\(cmd)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .spawnFailed(let err):
                return "spawn failed: \(err)"
            case .parseFailed(let msg):
                return "parse failed: \(msg)"
            }
        }
    }

    struct DeviceType: Sendable, Hashable {
        let identifier: String
        let name: String
    }

    struct Runtime: Sendable, Hashable {
        let identifier: String
        let name: String
        let version: String
        let isAvailable: Bool
        let supportedDeviceTypeIds: [String]
    }

    static func screenshot(udid: String, to url: URL) throws {
        _ = try run(["simctl", "io", udid, "screenshot", url.path])
    }

    /// Long-running `simctl io <udid> recordVideo`. Caller holds the
    /// returned handle and calls `stop()` to finalise the file — simctl
    /// flushes the MOV when it receives SIGINT.
    final class VideoRecording: @unchecked Sendable {
        let outputURL: URL
        private let task: Process
        init(task: Process, outputURL: URL) {
            self.task = task
            self.outputURL = outputURL
        }
        func stop() {
            guard task.isRunning else { return }
            task.interrupt()
            task.waitUntilExit()
        }
    }

    static func startRecordVideo(udid: String, to url: URL) throws -> VideoRecording {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            throw SimctlError.spawnFailed(error)
        }
        return VideoRecording(task: task, outputURL: url)
    }

    static func listDeviceTypes() throws -> [DeviceType] {
        let json = try parseJSON(["simctl", "list", "-j", "devicetypes"])
        guard let arr = json["devicetypes"] as? [[String: Any]] else {
            throw SimctlError.parseFailed("devicetypes shape")
        }
        return arr.compactMap { entry in
            guard let id = entry["identifier"] as? String,
                  let name = entry["name"] as? String
            else { return nil }
            return DeviceType(identifier: id, name: name)
        }
    }

    static func listRuntimes() throws -> [Runtime] {
        let json = try parseJSON(["simctl", "list", "-j", "runtimes"])
        guard let arr = json["runtimes"] as? [[String: Any]] else {
            throw SimctlError.parseFailed("runtimes shape")
        }
        return arr.compactMap { entry in
            guard let id = entry["identifier"] as? String,
                  let name = entry["name"] as? String
            else { return nil }
            let supported = (entry["supportedDeviceTypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["identifier"] as? String }
            return Runtime(
                identifier: id,
                name: name,
                version: entry["version"] as? String ?? "",
                isAvailable: entry["isAvailable"] as? Bool ?? false,
                supportedDeviceTypeIds: supported
            )
        }
    }

    /// Returns the new device's UDID (the only thing simctl prints).
    @discardableResult
    static func createDevice(name: String, deviceTypeId: String, runtimeId: String) throws -> String {
        let stdout = try run(["simctl", "create", name, deviceTypeId, runtimeId])
        let udid = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if udid.isEmpty { throw SimctlError.parseFailed("empty UDID from create") }
        return udid
    }

    // MARK: - runner

    private static func parseJSON(_ args: [String]) throws -> [String: Any] {
        let data = try run(args)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimctlError.parseFailed("expected JSON object from `xcrun \(args.joined(separator: " "))`")
        }
        return obj
    }

    /// Run `/usr/bin/xcrun <args>` synchronously. Stdout drained before
    /// `waitUntilExit` so JSON-heavy commands can't deadlock on a full pipe.
    @discardableResult
    private static func run(_ args: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe

        do {
            try task.run()
        } catch {
            throw SimctlError.spawnFailed(error)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errStr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw SimctlError.nonZeroExit(
                args: args,
                status: task.terminationStatus,
                stderr: errStr
            )
        }
        return outData
    }
}
