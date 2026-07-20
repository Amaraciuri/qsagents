import Foundation

/// Short-term session memory for the orchestrator (Fase 2).
struct OrchestratorMemoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var role: String // user | assistant
    var summary: String
    var at: Date

    init(id: UUID = UUID(), role: String, summary: String, at: Date = .now) {
        self.id = id
        self.role = role
        self.summary = summary
        self.at = at
    }
}

@MainActor
final class OrchestratorMemory: ObservableObject {
    @Published private(set) var entries: [OrchestratorMemoryEntry] = []

    private let storeName = "orchestrator_memory"
    private let maxEntries = 24
    private let maxSummaryLen = 220

    init() {
        load()
    }

    func remember(role: String, text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let summary = s.count > maxSummaryLen ? String(s.prefix(maxSummaryLen)) + "…" : s
        entries.append(OrchestratorMemoryEntry(role: role, summary: summary))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    /// Compact block for system prompts (token-aware).
    func promptBlock(limit: Int = 12, maxLine: Int = 200) -> String {
        let recent = entries.suffix(limit)
        guard !recent.isEmpty else { return "_nessuna_" }
        return recent.map { e in
            let line = e.summary.replacingOccurrences(of: "\n", with: " ")
            let clipped = line.count > maxLine ? String(line.prefix(maxLine)) + "…" : line
            return "• [\(e.role)] \(clipped)"
        }.joined(separator: "\n")
    }

    /// B3: one-line digest for project memory (not the full transcript).
    func sessionDigest(limit: Int = 12) -> String {
        let recent = entries.suffix(limit)
        guard !recent.isEmpty else { return "" }
        let parts = recent.map { e -> String in
            let role = e.role == "user" ? "U" : "A"
            let s = e.summary.replacingOccurrences(of: "\n", with: " ")
            return "[\(role)] \(String(s.prefix(100)))"
        }
        return parts.joined(separator: " · ")
    }

    private func load() {
        if let loaded: [OrchestratorMemoryEntry] = JSONStore.load([OrchestratorMemoryEntry].self, name: storeName) {
            entries = loaded
        }
    }

    private func persist() {
        JSONStore.save(entries, name: storeName)
    }
}
