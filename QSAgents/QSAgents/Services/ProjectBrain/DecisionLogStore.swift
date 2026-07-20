import Foundation
import CryptoKit

/// B2: append-only decision log per workspace (JSONL + content hash).
/// Not a full crypto signature — integrity hash so we can detect corruption.
@MainActor
final class DecisionLogStore: ObservableObject {
    static let shared = DecisionLogStore()

    enum Kind: String, Codable {
        case plan
        case complete
        case advance
        case note
        case session
        case open
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let at: Date
        let workspace: String?
        let kind: Kind
        let text: String
        let relatedTaskIds: [UUID]
        let meta: [String: String]
        /// SHA256 hex of canonical payload (id+at+kind+text+workspace).
        let contentHash: String
    }

    @Published private(set) var recent: [Entry] = []

    private let maxRecent = 80

    private init() {
        recent = loadGlobalRecent()
    }

    @discardableResult
    func append(
        workspace: String?,
        kind: Kind,
        text: String,
        relatedTaskIds: [UUID] = [],
        meta: [String: String] = [:]
    ) -> Entry {
        let id = UUID()
        let at = Date()
        let hash = Self.hash(id: id, at: at, workspace: workspace, kind: kind, text: text)
        let entry = Entry(
            id: id,
            at: at,
            workspace: workspace.map { ($0 as NSString).standardizingPath },
            kind: kind,
            text: text,
            relatedTaskIds: relatedTaskIds,
            meta: meta,
            contentHash: hash
        )
        appendLine(entry)
        recent.insert(entry, at: 0)
        if recent.count > maxRecent {
            recent = Array(recent.prefix(maxRecent))
        }
        saveGlobalRecent()
        AppLogger.info("DecisionLog [\(kind.rawValue)] \(text.prefix(80))")
        return entry
    }

    /// Last N decisions for a workspace path (or all if nil).
    func recall(workspace: String?, limit: Int = 15) -> [Entry] {
        let root = workspace.map { ($0 as NSString).standardizingPath }
        let lines = loadAllLines(workspace: root)
        let filtered: [Entry]
        if let root {
            filtered = lines.filter { $0.workspace == root }
        } else {
            filtered = lines
        }
        return Array(filtered.suffix(limit).reversed())
    }

    func formatRecall(workspace: String?, limit: Int = 12) -> String {
        let entries = recall(workspace: workspace, limit: limit)
        guard !entries.isEmpty else {
            return "_Nessuna decisione registrata ancora per questo workspace._"
        }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return entries.map { e in
            let day = df.string(from: e.at)
            return "• [\(e.kind.rawValue)] \(day) — \(e.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence (JSONL under Application Support)

    private var baseDir: URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = app.appendingPathComponent("QSAgents/decision-log", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(for workspace: String?) -> URL {
        if let workspace {
            let key = workspace
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let clipped = String(key.suffix(120))
            return baseDir.appendingPathComponent("\(clipped).jsonl")
        }
        return baseDir.appendingPathComponent("global.jsonl")
    }

    private func appendLine(_ entry: Entry) {
        let url = fileURL(for: entry.workspace)
        guard let data = try? JSONEncoder().encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        // Mirror to global stream
        if entry.workspace != nil {
            let g = fileURL(for: nil)
            if FileManager.default.fileExists(atPath: g.path),
               let handle = try? FileHandle(forWritingTo: g) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else if !FileManager.default.fileExists(atPath: g.path) {
                try? line.write(to: g, atomically: true, encoding: .utf8)
            }
        }
    }

    private func loadAllLines(workspace: String?) -> [Entry] {
        let url = fileURL(for: workspace)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(Entry.self, from: d)
        }
    }

    private func loadGlobalRecent() -> [Entry] {
        Array(loadAllLines(workspace: nil).suffix(maxRecent).reversed())
    }

    private func saveGlobalRecent() {
        // recent is derived from append; no separate write needed beyond JSONL
    }

    private static func hash(id: UUID, at: Date, workspace: String?, kind: Kind, text: String) -> String {
        let payload = "\(id.uuidString)|\(at.timeIntervalSince1970)|\(workspace ?? "")|\(kind.rawValue)|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
