import Foundation
import AppKit

/// Lightweight local crash / error breadcrumb log (Fase 11).
/// Install only when the user opts in (`AppConfig.crashLogEnabled`) — stays on-device, no telemetry.
enum CrashReporter {
    private static var path: URL {
        AppConfig.logsDirectory.appendingPathComponent("crashes.log")
    }

    private static var installed = false

    static func installIfEnabled() {
        guard AppConfig.crashLogEnabled else {
            AppLogger.info("CrashReporter skipped (opt-in off)")
            return
        }
        install()
    }

    static func install() {
        guard !installed else { return }
        installed = true
        NSSetUncaughtExceptionHandler(qsUncaughtException)
        // Best-effort for fatal signals (does not recover — only logs before exit).
        signal(SIGTRAP, qsSignalHandler)
        signal(SIGABRT, qsSignalHandler)
        signal(SIGSEGV, qsSignalHandler)
        signal(SIGBUS, qsSignalHandler)
        signal(SIGILL, qsSignalHandler)
        AppLogger.info("CrashReporter installed → \(path.path)")
    }

    static func log(_ message: String) {
        guard AppConfig.crashLogEnabled || installed else { return }
        append("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n")
    }

    private static let ackKey = "qs.crash.ackByteLength"

    /// Unread crash breadcrumbs since last dismiss (works even if opt-in is off — log may exist from past).
    static func unreadCrashReport() -> (preview: String, byteLength: Int)? {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        let ack = UserDefaults.standard.integer(forKey: ackKey)
        guard data.count > ack else { return nil }
        let slice = data.suffix(from: data.index(data.startIndex, offsetBy: min(ack, data.count)))
        guard let text = String(data: Data(slice), encoding: .utf8), !text.isEmpty else { return nil }
        let interesting = text.contains("FATAL") || text.contains("EXCEPTION")
        guard interesting else { return nil }
        let preview = text
            .split(separator: "\n")
            .suffix(6)
            .joined(separator: "\n")
        return (String(preview.prefix(400)), data.count)
    }

    static func acknowledgeCrashLog(upToByteLength length: Int? = nil) {
        if let length {
            UserDefaults.standard.set(length, forKey: ackKey)
            return
        }
        if let n = try? Data(contentsOf: path).count {
            UserDefaults.standard.set(n, forKey: ackKey)
        }
    }

    static func openCrashLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    fileprivate static func append(_ text: String) {
        let url = path
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }
}

private func qsUncaughtException(_ exception: NSException) {
    let msg = """
    [\(ISO8601DateFormatter().string(from: Date()))] EXCEPTION \(exception.name.rawValue)
    reason: \(exception.reason ?? "—")
    stack: \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))

    """
    CrashReporter.append(msg)
}

private func qsSignalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGTRAP: name = "SIGTRAP"
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS: name = "SIGBUS"
    case SIGILL: name = "SIGILL"
    default: name = "SIGNAL \(sig)"
    }
    let msg = "[\(ISO8601DateFormatter().string(from: Date()))] FATAL \(name)\n"
    CrashReporter.append(msg)
    // Re-raise default so system still produces a crash report
    signal(sig, SIG_DFL)
    raise(sig)
}
