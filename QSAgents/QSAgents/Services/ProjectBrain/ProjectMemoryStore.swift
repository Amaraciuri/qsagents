import Foundation
import Combine

// MARK: - Models (B1)

enum ProjectMemoryKind: String, Codable, Equatable {
    case gitCommit = "git_commit"
    case note
    case plan
    case session
    case visit
}

struct ProjectMemoryEvent: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ProjectMemoryKind
    var text: String
    var at: Date
    var evidence: [String]
    /// Commit hash when kind == gitCommit (dedupe).
    var commitHash: String?

    init(
        id: UUID = UUID(),
        kind: ProjectMemoryKind,
        text: String,
        at: Date = .now,
        evidence: [String] = [],
        commitHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.at = at
        self.evidence = evidence
        self.commitHash = commitHash
    }
}

struct ProjectMemoryRecord: Codable, Equatable {
    var workspacePath: String
    var projectName: String
    var lastSyncAt: Date?
    var lastVisitAt: Date?
    var events: [ProjectMemoryEvent]
    /// Short line shown on reopen (“ultima volta…”).
    var lastVisitSummary: String?
    /// Sticky brief: rules / stack / path conventions always injected into orchestrator.
    var stickyBrief: String?

    static func empty(path: String, name: String) -> ProjectMemoryRecord {
        ProjectMemoryRecord(
            workspacePath: path,
            projectName: name,
            lastSyncAt: nil,
            lastVisitAt: nil,
            events: [],
            lastVisitSummary: nil,
            stickyBrief: nil
        )
    }

    // Decode older records without stickyBrief.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspacePath = try c.decode(String.self, forKey: .workspacePath)
        projectName = try c.decode(String.self, forKey: .projectName)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastVisitAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitAt)
        events = try c.decodeIfPresent([ProjectMemoryEvent].self, forKey: .events) ?? []
        lastVisitSummary = try c.decodeIfPresent(String.self, forKey: .lastVisitSummary)
        stickyBrief = try c.decodeIfPresent(String.self, forKey: .stickyBrief)
    }

    init(
        workspacePath: String,
        projectName: String,
        lastSyncAt: Date?,
        lastVisitAt: Date?,
        events: [ProjectMemoryEvent],
        lastVisitSummary: String?,
        stickyBrief: String?
    ) {
        self.workspacePath = workspacePath
        self.projectName = projectName
        self.lastSyncAt = lastSyncAt
        self.lastVisitAt = lastVisitAt
        self.events = events
        self.lastVisitSummary = lastVisitSummary
        self.stickyBrief = stickyBrief
    }
}

// MARK: - Store

/// Per-workspace durable memory: git changelog + user/orchestrator notes (B1/B4).
@MainActor
final class ProjectMemoryStore: ObservableObject {
    /// Path → record (normalized absolute paths).
    @Published private(set) var records: [String: ProjectMemoryRecord] = [:]

    private let storeName = "project_memories"
    private let maxEventsPerProject = 120

    init() {
        load()
    }

    // MARK: - Public API

    func record(for path: String) -> ProjectMemoryRecord? {
        records[normalize(path)]
    }

    /// Sync git log into memory (idempotent on commit hash). Returns updated record.
    @discardableResult
    func syncChangelog(path: String, limit: Int = 30) -> ProjectMemoryRecord {
        let root = normalize(path)
        let name = URL(fileURLWithPath: root).lastPathComponent
        var rec = records[root] ?? .empty(path: root, name: name)
        rec.projectName = name
        rec.workspacePath = root

        let (_, log) = GitRunner.loadSnapshot(path: root)
        let known = Set(rec.events.compactMap(\.commitHash))
        var added = 0
        // Oldest first so events stay chronological when appending
        for commit in log.prefix(limit).reversed() {
            guard !known.contains(commit.hash) else { continue }
            rec.events.append(ProjectMemoryEvent(
                kind: .gitCommit,
                text: "\(commit.shortHash) \(commit.subject)",
                at: parseISO(commit.dateISO) ?? .now,
                evidence: [
                    "author: \(commit.author)",
                    "when: \(commit.relativeDate)",
                    "hash: \(commit.shortHash)",
                ],
                commitHash: commit.hash
            ))
            added += 1
        }
        rec.lastSyncAt = .now
        if added > 0 {
            rec.lastVisitSummary = "+\(added) commit in memoria · ultimo: \(log.first.map { "\($0.shortHash) \($0.subject)" } ?? "—")"
        } else if rec.lastVisitSummary == nil, let top = log.first {
            rec.lastVisitSummary = "Baseline git: \(top.shortHash) \(top.subject)"
        }
        trim(&rec)
        records[root] = rec
        persist()
        AppLogger.info("ProjectMemory sync \(name): +\(added) commits · total \(rec.events.count)")
        return rec
    }

    @discardableResult
    func appendNote(
        path: String,
        text: String,
        kind: ProjectMemoryKind = .note,
        evidence: [String] = []
    ) -> ProjectMemoryRecord {
        let root = normalize(path)
        let name = URL(fileURLWithPath: root).lastPathComponent
        var rec = records[root] ?? .empty(path: root, name: name)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rec }
        // Session digests can be longer
        let cap = kind == .session ? 900 : 500
        rec.events.append(ProjectMemoryEvent(
            kind: kind,
            text: String(trimmed.prefix(cap)),
            evidence: evidence
        ))
        rec.lastVisitAt = .now
        rec.lastVisitSummary = String(trimmed.prefix(120))
        trim(&rec)
        records[root] = rec
        persist()
        return rec
    }

    /// B3: append a structured multi-agent / mission session summary.
    @discardableResult
    func appendSessionSummary(
        path: String,
        title: String,
        body: String,
        evidence: [String] = []
    ) -> ProjectMemoryRecord {
        let text = "\(title)\n\(body)"
        return appendNote(path: path, text: text, kind: .session, evidence: evidence)
    }

    /// Mark that the user reopened / focused this workspace (B5 light).
    @discardableResult
    func markVisit(path: String) -> String? {
        let root = normalize(path)
        let previous = records[root]?.lastVisitSummary
        let name = URL(fileURLWithPath: root).lastPathComponent
        var rec = records[root] ?? .empty(path: root, name: name)
        let when = rec.lastVisitAt.map { Self.relativeDate($0) } ?? "mai"
        rec.lastVisitAt = .now
        // Sync lightly so reopen has fresh commits
        records[root] = rec
        _ = syncChangelog(path: root, limit: 15)
        if var updated = records[root] {
            if previous != nil {
                updated.events.append(ProjectMemoryEvent(
                    kind: .visit,
                    text: "Riapertura workspace (ultima visita: \(when))",
                    evidence: previous.map { ["prev: \($0)"] } ?? []
                ))
                trim(&updated)
            }
            records[root] = updated
            persist()
        }
        return previous
    }

    /// B4: human-readable recall for a project (path or name match).
    func recall(path: String? = nil, query: String? = nil, limit: Int = 20) -> String {
        let resolved = resolvePath(path: path, query: query)
        guard let root = resolved else {
            if records.isEmpty {
                return "_Nessuna memoria di progetto ancora._\nApri un workspace e usa `changelog` o `crea piano` per iniziare."
            }
            let listing = records.values
                .sorted { ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast) }
                .prefix(8)
                .map { "• **\($0.projectName)** — \($0.events.count) eventi · \($0.lastVisitSummary ?? "—")" }
                .joined(separator: "\n")
            return """
            Specifica il progetto: `cosa abbiamo fatto su <nome>` oppure apri un workspace.

            **Progetti in memoria**
            \(listing)
            """
        }

        // Ensure git is folded in
        let rec = syncChangelog(path: root, limit: 25)
        let events = rec.events.sorted { $0.at > $1.at }.prefix(limit)
        guard !events.isEmpty else {
            return "Memoria vuota per **\(rec.projectName)**. Nessun commit/nota ancora."
        }

        let lines = events.map { e -> String in
            let tag: String
            switch e.kind {
            case .gitCommit: tag = "git"
            case .note: tag = "nota"
            case .plan: tag = "piano"
            case .session: tag = "sessione"
            case .visit: tag = "visita"
            }
            let day = Self.shortDate(e.at)
            let extra = e.evidence.first.map { " — \($0)" } ?? ""
            return "• _\(day)_ **[\(tag)]** \(e.text)\(extra)"
        }.joined(separator: "\n")

        let visit = rec.lastVisitAt.map { "Ultima visita QS: \(Self.relativeDate($0))" } ?? "Prima volta in memoria"
        let sync = rec.lastSyncAt.map { "Sync git: \(Self.relativeDate($0))" } ?? ""

        return """
        **Cosa abbiamo fatto su \(rec.projectName)**
        `\(rec.workspacePath)`
        \(visit)\(sync.isEmpty ? "" : " · \(sync)")

        \(lines)

        _Memoria persistente per workspace (git log + note QS)._
        """
    }

    /// Compact block for LLM / orchestrator context.
    func promptBlock(path: String?, limit: Int = 8) -> String {
        guard let path else { return "" }
        let root = normalize(path)
        guard let rec = records[root] else { return "" }
        var parts: [String] = []
        if let brief = rec.stickyBrief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            parts.append("**Brief sticky (\(rec.projectName))**\n\(String(brief.prefix(900)))")
        }
        if !rec.events.isEmpty {
            let recent = rec.events.sorted { $0.at > $1.at }.prefix(limit)
            let body = recent.map { "• [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")
            parts.append("**Project memory**\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    func stickyBrief(for path: String?) -> String? {
        guard let path else { return nil }
        let s = records[normalize(path)]?.stickyBrief?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    @discardableResult
    func setStickyBrief(path: String, text: String) -> ProjectMemoryRecord {
        let root = normalize(path)
        let name = URL(fileURLWithPath: root).lastPathComponent
        var rec = records[root] ?? .empty(path: root, name: name)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rec.stickyBrief = trimmed.isEmpty ? nil : String(trimmed.prefix(2_000))
        rec.lastVisitAt = .now
        records[root] = rec
        persist()
        return rec
    }

    // MARK: - Resolve

    private func resolvePath(path: String?, query: String?) -> String? {
        if let path, !path.isEmpty {
            let n = normalize(path)
            if records[n] != nil || FileManager.default.fileExists(atPath: n) {
                return n
            }
        }
        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !q.isEmpty else {
            return nil
        }
        // Match by project name fragment
        let byName = records.first { _, rec in
            rec.projectName.lowercased().contains(q) || rec.workspacePath.lowercased().contains(q)
        }?.key
        return byName
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func trim(_ rec: inout ProjectMemoryRecord) {
        if rec.events.count > maxEventsPerProject {
            // Keep newest by date
            rec.events.sort { $0.at < $1.at }
            rec.events = Array(rec.events.suffix(maxEventsPerProject))
        }
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        f.locale = Locale(identifier: "it_IT")
        return f.string(from: d)
    }

    private static func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Persistence

    private func load() {
        if let loaded: [String: ProjectMemoryRecord] = JSONStore.load([String: ProjectMemoryRecord].self, name: storeName) {
            records = loaded
        }
    }

    private func persist() {
        JSONStore.save(records, name: storeName)
    }
}
