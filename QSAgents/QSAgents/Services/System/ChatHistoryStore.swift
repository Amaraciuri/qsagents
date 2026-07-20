import Foundation
import Combine

/// Lightweight persisted chat line (full ChatMessage has non-Codable actions/engine).
struct PersistedChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var role: String // user | assistant | system
    var text: String
    var timestamp: Date
    var engineBadge: String?
    var isVoice: Bool

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        timestamp: Date = .now,
        engineBadge: String? = nil,
        isVoice: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.engineBadge = engineBadge
        self.isVoice = isVoice
    }

    init(from msg: ChatMessage) {
        id = msg.id
        role = msg.role.rawValue
        text = msg.text
        timestamp = msg.timestamp
        engineBadge = msg.engine?.badge
        isVoice = msg.isVoice
    }

    func asChatMessage() -> ChatMessage {
        let r: ChatMessage.Role
        switch role {
        case "assistant": r = .assistant
        case "system": r = .system
        default: r = .user
        }
        let eng: ReplyEngine? = {
            guard let badge = engineBadge, !badge.isEmpty else { return nil }
            if badge == "Regole locali" { return .localRules }
            if badge == "Voce" { return .voiceNote }
            // "Provider · model"
            let parts = badge.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                return .llm(provider: parts[0], model: parts[1])
            }
            return .llm(provider: badge, model: "")
        }()
        return ChatMessage(
            id: id,
            role: r,
            text: text,
            timestamp: timestamp,
            engine: eng,
            isVoice: isVoice
        )
    }
}

/// One chat transcript (active or archived) scoped to a workspace.
struct ChatTranscript: Identifiable, Codable, Equatable {
    let id: UUID
    var workspacePath: String
    var title: String
    var updatedAt: Date
    var messages: [PersistedChatMessage]
    var archived: Bool

    init(
        id: UUID = UUID(),
        workspacePath: String,
        title: String,
        updatedAt: Date = .now,
        messages: [PersistedChatMessage] = [],
        archived: Bool = false
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.title = title
        self.updatedAt = updatedAt
        self.messages = messages
        self.archived = archived
    }

    var preview: String {
        guard let t = messages.last?.text else { return "Vuota" }
        let one = t.replacingOccurrences(of: "\n", with: " ")
        return one.count > 80 ? String(one.prefix(80)) + "…" : one
    }
}

/// Durable chat history per workspace — survives relaunch and “Pulisci chat” (archives).
@MainActor
final class ChatHistoryStore: ObservableObject {
    static let shared = ChatHistoryStore()

    @Published private(set) var transcripts: [ChatTranscript] = []
    /// Active (non-archived) transcript id per workspace path.
    @Published private(set) var activeIDByWorkspace: [String: UUID] = [:]

    private let storeName = "chat_history_v1"
    private let maxTranscripts = 80
    private let maxMessagesPerTranscript = 400

    init() {
        load()
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    func activeTranscript(for workspacePath: String?) -> ChatTranscript? {
        guard let ws = workspacePath.map(normalize) else { return nil }
        if let id = activeIDByWorkspace[ws],
           let t = transcripts.first(where: { $0.id == id && !$0.archived }) {
            return t
        }
        return transcripts
            .filter { normalize($0.workspacePath) == ws && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func transcripts(for workspacePath: String?, includeArchived: Bool = true) -> [ChatTranscript] {
        let ws = workspacePath.map(normalize)
        return transcripts
            .filter { t in
                if let ws { guard normalize(t.workspacePath) == ws else { return false } }
                if !includeArchived { return !t.archived }
                return true
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Save / replace the live transcript for a workspace.
    @discardableResult
    func saveLive(workspacePath: String?, messages: [ChatMessage]) -> ChatTranscript? {
        guard let path = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let root = normalize(path)
        let persisted = messages.map(PersistedChatMessage.init(from:))
        var t: ChatTranscript
        if let existing = activeTranscript(for: root) {
            t = existing
            t.messages = persisted
            t.updatedAt = .now
            if t.title == "Chat corrente" || t.title.isEmpty {
                t.title = Self.makeTitle(from: persisted)
            }
        } else {
            t = ChatTranscript(
                workspacePath: root,
                title: Self.makeTitle(from: persisted),
                messages: persisted,
                archived: false
            )
        }
        if t.messages.count > maxMessagesPerTranscript {
            t.messages = Array(t.messages.suffix(maxMessagesPerTranscript))
        }
        upsert(t)
        activeIDByWorkspace[root] = t.id
        persist()
        return t
    }

    /// Archive current live chat and clear active pointer (used by Pulisci chat).
    @discardableResult
    func archiveLive(workspacePath: String?, messages: [ChatMessage]) -> ChatTranscript? {
        guard let path = workspacePath, !messages.isEmpty else { return nil }
        let root = normalize(path)
        var t = activeTranscript(for: root) ?? ChatTranscript(
            workspacePath: root,
            title: Self.makeTitle(from: messages.map(PersistedChatMessage.init(from:))),
            messages: []
        )
        t.messages = messages.map(PersistedChatMessage.init(from:))
        t.updatedAt = .now
        t.archived = true
        t.title = "Archivio · " + Self.makeTitle(from: t.messages)
        upsert(t)
        activeIDByWorkspace[root] = nil
        // Start a fresh empty active slot so next messages don't overwrite archive
        let fresh = ChatTranscript(workspacePath: root, title: "Chat corrente", messages: [], archived: false)
        upsert(fresh)
        activeIDByWorkspace[root] = fresh.id
        trimGlobal()
        persist()
        return t
    }

    func loadMessages(transcriptID: UUID) -> [ChatMessage] {
        guard let t = transcripts.first(where: { $0.id == transcriptID }) else { return [] }
        return t.messages.map { $0.asChatMessage() }
    }

    /// Restore an archived (or any) transcript as the live chat for its workspace.
    @discardableResult
    func restoreAsLive(_ id: UUID) -> ChatTranscript? {
        guard var t = transcripts.first(where: { $0.id == id }) else { return nil }
        let root = normalize(t.workspacePath)
        // Archive previous live if different
        if let live = activeTranscript(for: root), live.id != id, !live.messages.isEmpty {
            var old = live
            old.archived = true
            old.updatedAt = .now
            old.title = "Archivio · " + old.title
            upsert(old)
        }
        t.archived = false
        t.updatedAt = .now
        if t.title.hasPrefix("Archivio · ") {
            t.title = String(t.title.dropFirst("Archivio · ".count))
        }
        upsert(t)
        activeIDByWorkspace[root] = t.id
        persist()
        return t
    }

    func delete(_ id: UUID) {
        transcripts.removeAll { $0.id == id }
        for (k, v) in activeIDByWorkspace where v == id {
            activeIDByWorkspace[k] = nil
        }
        persist()
    }

    private func upsert(_ t: ChatTranscript) {
        if let i = transcripts.firstIndex(where: { $0.id == t.id }) {
            transcripts[i] = t
        } else {
            transcripts.insert(t, at: 0)
        }
    }

    private func trimGlobal() {
        if transcripts.count > maxTranscripts {
            // Drop oldest archived first
            let sorted = transcripts.sorted { $0.updatedAt < $1.updatedAt }
            var keep = Set(transcripts.map(\.id))
            for t in sorted where t.archived && transcripts.count > maxTranscripts {
                keep.remove(t.id)
                transcripts.removeAll { $0.id == t.id }
            }
            _ = keep
        }
    }

    private static func makeTitle(from messages: [PersistedChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == "user" }) {
            let s = firstUser.text.replacingOccurrences(of: "\n", with: " ")
            return s.count > 48 ? String(s.prefix(48)) + "…" : s
        }
        return "Chat corrente"
    }

    private struct Payload: Codable {
        var transcripts: [ChatTranscript]
        var activeIDByWorkspace: [String: UUID]
    }

    private func load() {
        if let p: Payload = JSONStore.load(Payload.self, name: storeName) {
            transcripts = p.transcripts
            activeIDByWorkspace = p.activeIDByWorkspace
        }
    }

    private func persist() {
        JSONStore.save(
            Payload(transcripts: transcripts, activeIDByWorkspace: activeIDByWorkspace),
            name: storeName
        )
    }
}
