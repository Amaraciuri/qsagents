import Foundation
import AppKit
import Combine

@MainActor
final class TerminalManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var lastError: String?
    @Published var lastSafetyMessage: String?

    /// Injected from app bootstrap — enforces guardrails on orchestrated commands.
    weak var safety: SafetyGuardrails?
    /// Terminal process finished → UI notices + task board.
    var onSessionExit: ((TerminalSession, Int32) -> Void)?
    /// User closed a tab → Swarm should drop linked agents.
    var onSessionClosed: ((UUID) -> Void)?

    private let persistName = "terminal_sessions_meta"

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    var activeCount: Int {
        sessions.filter(\.isAlive).count
    }

    private struct SessionMeta: Codable {
        var title: String
        var cwd: String
        var roleRaw: String
    }

    /// Restore last tabs (cwd/title/role) — shells restart fresh (Fase 9).
    /// Cap low: restoring many interactive zsh at once can freeze the UI (felt like a crash).
    func restorePersistedSessions() {
        guard sessions.isEmpty,
              let metas: [SessionMeta] = JSONStore.load([SessionMeta].self, name: persistName),
              !metas.isEmpty else { return }
        let batch = Array(metas.prefix(3))
        for (i, m) in batch.enumerated() {
            let role = AgentRole(rawValue: m.roleRaw) ?? .general
            // Stagger opens so PTY + zsh init don't all hit MainActor at once
            let delay = 0.15 * Double(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.sessions.count < 3 else { return }
                _ = self.openTerminal(at: m.cwd, title: m.title, select: i == 0, role: role)
            }
        }
        AppLogger.info("Restoring \(batch.count) terminal session(s) (staggered)")
    }

    private func persistMeta() {
        let metas = sessions.map {
            SessionMeta(title: $0.title, cwd: $0.cwd, roleRaw: $0.agentRole.rawValue)
        }
        JSONStore.save(metas, name: persistName)
    }

    // MARK: - Open / close

    @discardableResult
    func openTerminal(
        at path: String? = nil,
        title: String? = nil,
        select: Bool = true,
        role: AgentRole? = nil,
        agentLaunched: Bool = false
    ) -> TerminalSession? {
        let cwd = resolvePath(path ?? NSHomeDirectory())
        let agentRole = role ?? safety?.defaultAgentRole ?? .general

        // Allowlist gate on open
        if let safety, safety.enabled, safety.allowlistMode == .enforce, !safety.isPathAllowed(cwd) {
            lastError = "Path fuori allowlist: \(cwd)"
            lastSafetyMessage = "Apertura terminale bloccata: progetto non in allowlist QS Agents."
            return nil
        }

        let resolvedTitle = uniqueTitle(title ?? URL(fileURLWithPath: cwd).lastPathComponent)
        let stripEnv = agentLaunched || (agentRole != .general)
        let session = TerminalSession(title: resolvedTitle, cwd: cwd, agentRole: agentRole)
        session.onProcessExit = { [weak self] id, code in
            guard let self, let s = self.sessions.first(where: { $0.id == id }) else { return }
            self.onSessionExit?(s, code)
        }
        do {
            try session.start(agentLaunched: stripEnv)
            sessions.append(session)
            if select { selectedID = session.id }
            lastError = nil
            persistMeta()
            if let safety, safety.allowlistMode == .warn, !safety.isPathAllowed(cwd) {
                lastSafetyMessage = "Avviso allowlist: \(cwd) non è un progetto autorizzato."
                session.appendSafetyNotice("⚠️ Path non in allowlist progetti QS Agents")
            }
            return session
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Unique display name per pane (e.g. qsagents, qsagents · 2).
    func uniqueTitle(_ base: String) -> String {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = root.isEmpty ? "Terminale" : root
        let taken = Set(sessions.map(\.title))
        if !taken.contains(seed) { return seed }
        var n = 2
        while taken.contains("\(seed) · \(n)") { n += 1 }
        return "\(seed) · \(n)"
    }

    func rename(_ id: UUID, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = t
        persistMeta()
        objectWillChange.send()
    }

    func openTerminals(at paths: [String]) {
        for (i, p) in paths.enumerated() {
            openTerminal(at: p, select: i == paths.count - 1)
        }
    }

    func close(_ id: UUID) {
        if let s = sessions.first(where: { $0.id == id }) {
            s.terminate()
        }
        sessions.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = sessions.last?.id
        }
        persistMeta()
        onSessionClosed?(id)
    }

    func closeAll() {
        let ids = sessions.map(\.id)
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        selectedID = nil
        persistMeta()
        for id in ids {
            onSessionClosed?(id)
        }
    }

    func select(_ id: UUID) {
        selectedID = id
    }

    func restart(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = sessions[idx]
        let cwd = old.cwd
        let title = old.title
        let role = old.agentRole
        old.terminate()
        let fresh = TerminalSession(id: id, title: title, cwd: cwd, agentRole: role)
        do {
            try fresh.start()
            sessions[idx] = fresh
            selectedID = id
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Orchestrator helpers

    func snapshotForOrchestrator() -> String {
        if sessions.isEmpty {
            return "Nessun terminale aperto."
        }
        return sessions.enumerated().map { i, s in
            let status = s.isAlive ? "LIVE" : "DEAD"
            return "[\(i + 1)] \(s.title) · \(status) · cwd=\(s.cwd)"
        }.joined(separator: "\n")
    }

    func findSession(matching query: String) -> TerminalSession? {
        let q = query.lowercased()
        return sessions.first {
            $0.title.lowercased().contains(q)
                || $0.cwd.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
        }
    }

    func runInNewTerminal(command: String, at path: String?, role: AgentRole? = nil) {
        let agentRole = role ?? safety?.defaultAgentRole ?? .general
        let ctx = SafetyContext(source: "orchestrator", path: path.map { resolvePath($0) }, role: agentRole)

        if let safety {
            switch safety.evaluate(command, context: ctx) {
            case .block(let msg, _):
                lastSafetyMessage = msg
                lastError = "Comando bloccato dai guardrail QS Agents"
                return
            case .requireConfirm(let msg, let rule):
                _ = safety.requestConfirm(command: command, path: ctx.path, source: "orchestrator", role: agentRole)
                lastSafetyMessage = msg
                lastError = "Conferma richiesta: \(rule.name)"
                return
            case .requireDualConfirm(let msg, let rule):
                _ = safety.requestConfirm(command: command, path: ctx.path, source: "orchestrator", role: agentRole)
                lastSafetyMessage = msg
                lastError = "Two-person rule: \(rule.name)"
                return
            case .allowWithWarning(let msg, _):
                lastSafetyMessage = msg
            case .allow:
                break
            }
        }

        guard let session = openTerminal(at: path, role: agentRole) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            session.sendLine(command)
        }
    }

    /// Send a full command line through safety checks (used by UI command bar, voice, orchestrator).
    @discardableResult
    func sendCommandLine(
        _ command: String,
        to sessionID: UUID? = nil,
        source: String = "terminal",
        bypassSafety: Bool = false,
        roleOverride: AgentRole? = nil
    ) -> SafetyDecision {
        let id = sessionID ?? selectedID
        let session = id.flatMap { sid in sessions.first { $0.id == sid } }
        let role = roleOverride ?? session?.agentRole ?? safety?.defaultAgentRole ?? .general
        let path = session?.cwd

        let decision: SafetyDecision
        if bypassSafety || safety == nil {
            decision = .allow
        } else {
            decision = safety!.evaluate(
                command,
                context: SafetyContext(source: source, path: path, role: role)
            )
        }

        switch decision {
        case .block(let msg, _):
            lastSafetyMessage = msg
            lastError = "Comando bloccato dai guardrail"
            session?.appendSafetyNotice("🚫 BLOCCATO [\(role.displayName)]: \(command)\n\(msg)")
            return decision
        case .requireConfirm(let msg, let rule):
            lastSafetyMessage = msg
            _ = safety?.requestConfirm(command: command, path: path, source: source, role: role)
            session?.appendSafetyNotice("⚠️ CONFERMA (\(rule.name)): \(command)")
            return decision
        case .requireDualConfirm(let msg, let rule):
            lastSafetyMessage = msg
            _ = safety?.requestConfirm(command: command, path: path, source: source, role: role)
            session?.appendSafetyNotice("👥 TWO-PERSON (\(rule.name)): \(command)")
            return decision
        case .allowWithWarning(let msg, _):
            lastSafetyMessage = msg
            fallthrough
        case .allow:
            guard let session else {
                lastError = "Nessun terminale selezionato"
                return decision
            }
            session.sendLine(command)
            return decision
        }
    }

    /// Called after full approval (1 or 2 person).
    func executeApprovedPending() {
        guard let safety else { return }
        // If still awaiting second person, do nothing
        if let p = safety.pendingConfirm, p.requiresDual, p.awaitingSecond {
            return
        }
        // Single-person path still has pending until approveFirst finalizes
        guard let pending = safety.pendingConfirm else {
            // Already finalized — try last approved via sessionApprovals by re-read is hard;
            // callers should call after approve returns true
            return
        }
        let cmd = pending.command
        let path = pending.path
        let role = pending.role
        let fullyApproved = safety.approveFirst()
        guard fullyApproved else { return } // dual: wait for second

        runApproved(cmd: cmd, path: path, role: role, source: pending.source)
    }

    func runApproved(cmd: String, path: String?, role: AgentRole, source: String) {
        if let path, sessions.first(where: { $0.cwd == path }) == nil {
            // Open then send — already in sessionApprovals
            if let session = openTerminal(at: path, role: role) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    session.sendLine(cmd)
                }
            }
            return
        }
        if let id = selectedID {
            _ = sendCommandLine(cmd, to: id, source: source, roleOverride: role)
        } else if let path {
            if let session = openTerminal(at: path, role: role) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    session.sendLine(cmd)
                }
            }
        }
    }

    // MARK: - Paths

    func resolvePath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty → keep caller context; never silently jump to $HOME (breaks git/orchestrator).
        if p.isEmpty {
            if let cwd = selected?.cwd, !cwd.isEmpty { return (cwd as NSString).standardizingPath }
            return (NSHomeDirectory() as NSString).standardizingPath
        }
        p = (p as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            return p
        }
        // If file, use parent
        if FileManager.default.fileExists(atPath: p) {
            return (p as NSString).deletingLastPathComponent
        }
        // Unknown path: return standardized input (do NOT fall back to $HOME).
        return p
    }

    func pickDirectoryAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Apri Terminale"
        panel.message = "Scegli la directory di lavoro per il nuovo terminale"
        if panel.runModal() == .OK, let url = panel.url {
            openTerminal(at: url.path)
        }
    }
}
