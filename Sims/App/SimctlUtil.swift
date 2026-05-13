import Foundation

/// Thin wrappers around `xcrun simctl` for operations that have no clean
/// private-framework path. Used by the toolbar actions in
/// `SimulatorTabController`.
///
/// All methods block; callers dispatch from background queues so they
/// don't lag the main run loop. Errors come back as `SimctlError`.
enum SimctlUtil {

    enum SimctlError: Error, CustomStringConvertible {
        case nonZeroExit(args: [String], status: Int32, stderr: String)
        case spawnFailed(Error)

        var description: String {
            switch self {
            case .nonZeroExit(let args, let status, let stderr):
                let cmd = (["xcrun"] + args).joined(separator: " ")
                return "`\(cmd)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .spawnFailed(let err):
                return "spawn failed: \(err)"
            }
        }
    }

    /// `xcrun simctl io <udid> screenshot <path>` — saves a PNG.
    static func screenshot(udid: String, to url: URL) throws {
        try run(["simctl", "io", udid, "screenshot", url.path])
    }

    // MARK: - core runner

    /// Run `/usr/bin/xcrun <args...>` synchronously. Throws on non-zero
    /// exit or spawn failure. Captures stderr for the error message.
    private static func run(_ args: [String], stdin: Data? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = args

        let errPipe = Pipe()
        task.standardOutput = Pipe()           // discard
        task.standardError  = errPipe

        let inPipe: Pipe?
        if let stdin {
            let p = Pipe()
            task.standardInput = p
            inPipe = p
            _ = stdin
        } else {
            inPipe = nil
        }

        do {
            try task.run()
        } catch {
            throw SimctlError.spawnFailed(error)
        }

        // Write stdin (if any) and close, so simctl sees EOF.
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw SimctlError.nonZeroExit(
                args: args,
                status: task.terminationStatus,
                stderr: errStr
            )
        }
    }
}
