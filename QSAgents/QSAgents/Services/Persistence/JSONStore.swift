import Foundation

/// Versioned JSON persistence under Application Support/QSAgents/data/.
/// Corrupt files are quarantined (never silently overwritten); last good save kept as `.bak`.
enum JSONStore {
    struct Envelope<T: Codable>: Codable {
        var schemaVersion: Int
        var updatedAt: Date
        var payload: T
    }

    /// Posted when a load fails and the file is quarantined (UI can show a banner).
    static let didQuarantineCorrupt = Notification.Name("qs.jsonStore.quarantineCorrupt")

    static func url(for name: String) -> URL {
        AppConfig.dataDirectory.appendingPathComponent("\(name).json")
    }

    static func backupURL(for name: String) -> URL {
        AppConfig.dataDirectory.appendingPathComponent("\(name).bak.json")
    }

    static func load<T: Codable>(_ type: T.Type, name: String) -> T? {
        let u = url(for: name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else {
            return loadBackup(type, name: name)
        }
        guard let data = try? Data(contentsOf: u) else {
            return loadBackup(type, name: name)
        }
        do {
            let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            if env.schemaVersion > AppConfig.schemaVersion {
                AppLogger.warn("JSONStore \(name): schema \(env.schemaVersion) > app \(AppConfig.schemaVersion)")
            }
            return env.payload
        } catch {
            AppLogger.error("JSONStore load \(name): \(error.localizedDescription)")
            quarantineCorrupt(name: name, url: u)
            if let recovered = loadBackup(type, name: name) {
                AppLogger.warn("JSONStore \(name): recovered from .bak")
                return recovered
            }
            return nil
        }
    }

    static func save<T: Codable>(_ value: T, name: String) {
        let env = Envelope(schemaVersion: AppConfig.schemaVersion, updatedAt: Date(), payload: value)
        do {
            let data = try JSONEncoder().encode(env)
            let u = url(for: name)
            let bak = backupURL(for: name)
            let fm = FileManager.default
            // Keep previous good file as .bak before overwrite (if any)
            if fm.fileExists(atPath: u.path) {
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: u, to: bak)
            }
            try data.write(to: u, options: .atomic)
            // Always keep .bak as last successful write (so first-save corruption can recover)
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: u, to: bak)
        } catch {
            AppLogger.error("JSONStore save \(name): \(error.localizedDescription)")
        }
    }

    private static func loadBackup<T: Codable>(_ type: T.Type, name: String) -> T? {
        let bak = backupURL(for: name)
        guard FileManager.default.fileExists(atPath: bak.path),
              let data = try? Data(contentsOf: bak),
              let env = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            return nil
        }
        return env.payload
    }

    private static func quarantineCorrupt(name: String, url: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        let dest = AppConfig.dataDirectory.appendingPathComponent("\(name).corrupt-\(ts).json")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: url, to: dest)
            AppLogger.warn("JSONStore quarantined corrupt \(name) → \(dest.lastPathComponent)")
            NotificationCenter.default.post(
                name: didQuarantineCorrupt,
                object: nil,
                userInfo: ["name": name, "path": dest.path]
            )
        } catch {
            AppLogger.error("JSONStore quarantine failed \(name): \(error.localizedDescription)")
        }
    }
}
