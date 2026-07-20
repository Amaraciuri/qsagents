import Foundation

/// Global app configuration. Demo data is OFF by default (production path).
enum AppConfig {
    // MARK: - Environment

    /// True in Xcode Debug builds only.
    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Production = not debug. Use for gates that must never ship loose.
    static var isProduction: Bool { !isDebug }

    /// When true, SeedData populates Tasks/Swarm/Knowledge/etc. for screenshots only.
    /// Forced **off** in Release builds.
    static var useDemoData: Bool {
        get {
            if isProduction { return false }
            return UserDefaults.standard.bool(forKey: keyDemo)
        }
        set {
            if isProduction { return }
            UserDefaults.standard.set(newValue, forKey: keyDemo)
        }
    }

    private static let keyDemo = "qs.config.useDemoData"

    // MARK: - Version (from bundle)

    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "11"
    }

    static var versionLabel: String {
        "v\(marketingVersion) (\(buildNumber))"
    }

    static var bundleId: String {
        Bundle.main.bundleIdentifier ?? "com.qsagents.mac"
    }

    static let schemaVersion = 2

    // MARK: - Support / privacy contacts

    /// Public support inbox (mailto from About / Support).
    static let supportEmail = "support@qsagents.app"
    /// Privacy / GDPR contact (shown in informativa).
    static let privacyEmail = "privacy@qsagents.app"
    /// Optional public privacy policy URL (empty until hosted).
    static let privacyPolicyURL: URL? = URL(string: "https://qsagents.app/privacy")

    private static let keyCrashLog = "qs.config.crashLogEnabled"

    /// Opt-in: write local crash breadcrumbs to Application Support/logs/crashes.log.
    /// Off by default — no network; only local disk. User enables in Support.
    static var crashLogEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: keyCrashLog) }
        set { UserDefaults.standard.set(newValue, forKey: keyCrashLog) }
    }

    // MARK: - Paths

    /// Application Support root for QS Agents.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QSAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var logsDirectory: URL {
        let d = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var dataDirectory: URL {
        let d = supportDirectory.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var codeBrainDirectory: URL {
        let d = supportDirectory.appendingPathComponent("code-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Production bootstrap

    /// Call once at launch: lock unsafe defaults, ensure dirs, log env.
    static func applyProductionDefaults() {
        if isProduction {
            UserDefaults.standard.set(false, forKey: keyDemo)
        }
        _ = supportDirectory
        _ = logsDirectory
        _ = dataDirectory
        AppLogger.info(
            "AppConfig \(versionLabel) · bundle=\(bundleId) · production=\(isProduction) · demo=\(useDemoData)"
        )
    }
}

extension Notification.Name {
    static let qsOpenWorkspacePicker = Notification.Name("qs.openWorkspacePicker")
}
