import Foundation
import OSLog

/// Unified logging → OSLog + optional file under Application Support/QSAgents/logs.
/// All messages pass through SecretRedactor before persistence or OSLog.
enum AppLogger {
    private static let subsystem = "com.qsagents.mac"
    private static let logger = Logger(subsystem: subsystem, category: "app")
    private static let fileURL = AppConfig.logsDirectory.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "com.qsagents.logger")

    static func info(_ message: String, file: String = #fileID, function: String = #function) {
        let safe = SecretRedactor.redact(message)
        logger.info("\(safe, privacy: .private)")
        append("INFO", safe, file: file, function: function)
    }

    static func debug(_ message: String, file: String = #fileID, function: String = #function) {
        let safe = SecretRedactor.redact(message)
        logger.debug("\(safe, privacy: .private)")
        append("DEBUG", safe, file: file, function: function)
    }

    static func error(_ message: String, file: String = #fileID, function: String = #function) {
        let safe = SecretRedactor.redact(message)
        logger.error("\(safe, privacy: .private)")
        append("ERROR", safe, file: file, function: function)
    }

    static func warn(_ message: String, file: String = #fileID, function: String = #function) {
        let safe = SecretRedactor.redact(message)
        logger.warning("\(safe, privacy: .private)")
        append("WARN", safe, file: file, function: function)
    }

    private static func append(_ level: String, _ message: String, file: String, function: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "\(ts) [\(level)] \(file).\(function): \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            // Cap ~2MB
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? UInt64, size > 2_000_000 {
                try? "".write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
