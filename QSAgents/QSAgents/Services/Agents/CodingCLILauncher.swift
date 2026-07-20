import Foundation

/// CLI discovery + thin launch helpers for external coding agents (Claude, Grok, …).
/// Claude supervision → ``ClaudeSessionSupervisor``. Grok → lightweight PTY session.
@MainActor
enum CodingCLILauncher {
    struct LaunchResult: Equatable {
        let ok: Bool
        let message: String
        let terminalID: UUID?
        let taskID: UUID?
        let binaryPath: String?

        init(ok: Bool, message: String, terminalID: UUID?, taskID: UUID?, binaryPath: String?) {
            self.ok = ok
            self.message = message
            self.terminalID = terminalID
            self.taskID = taskID
            self.binaryPath = binaryPath
        }

        init(_ r: ClaudeSessionSupervisor.StartResult) {
            self.ok = r.ok
            self.message = r.message
            self.terminalID = r.terminalID
            self.taskID = r.taskID
            self.binaryPath = r.binaryPath
        }
    }

    static let terminalTitlePrefix = "Claude Code"
    static let grokTitlePrefix = "Grok CLI"

    private static let legacyDefaultsKey = "qs.orchestrator.useClaudeCode"
    private static var cachedClaude: (path: String, at: Date)?
    private static var cachedGrok: (path: String, at: Date)?

    /// Active Grok PTY sessions keyed by standardized workspace path.
    private static var grokSessions: [String: UUID] = [:]

    /// Legacy bridge — prefer ``CodingEngine.preferred``.
    static var useClaudeCodePreferred: Bool {
        get { CodingEngine.preferred != .swarm }
        set {
            CodingEngine.preferred = newValue ? .auto : .swarm
            UserDefaults.standard.set(newValue, forKey: legacyDefaultsKey)
        }
    }

    static let missingClaudeMessage = """
    **Claude Code CLI non trovato** sul PATH.

    Installa e verifica:
    `npm i -g @anthropic-ai/claude-code` · poi `which claude`.

    Oppure scegli **QS API · IDE in terminale** (usa la key OpenRouter già in chat).
    """

    static let missingGrokMessage = """
    **Grok / xAI CLI non trovato** sul PATH.

    Installa il CLI ufficiale quando disponibile, poi `which grok` (o `grok-cli`).
    Oppure usa **QS API** con provider SpaceXAI / OpenRouter.
    """

    // MARK: - Resolve binaries

    static func resolveClaudeBinary() -> String? {
        resolveBinary(
            cache: &cachedClaude,
            names: ["claude"],
            candidates: [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
                (NSHomeDirectory() as NSString).appendingPathComponent(".claude/local/claude"),
            ]
        )
    }

    static func resolveGrokBinary() -> String? {
        resolveBinary(
            cache: &cachedGrok,
            names: ["grok", "grok-cli", "xai"],
            candidates: [
                "/opt/homebrew/bin/grok",
                "/opt/homebrew/bin/grok-cli",
                "/usr/local/bin/grok",
                (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/grok"),
                (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/grok-cli"),
            ]
        )
    }

    private static func resolveBinary(
        cache: inout (path: String, at: Date)?,
        names: [String],
        candidates: [String]
    ) -> String? {
        if let cache, Date().timeIntervalSince(cache.at) < 60,
           FileManager.default.isExecutableFile(atPath: cache.path) {
            return cache.path
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cache = (path, .now)
            return path
        }
        for name in names {
            if let found = which(name) {
                cache = (found, .now)
                return found
            }
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus == 0,
               !out.isEmpty,
               FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch {
            AppLogger.error("which \(name): \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Claude

    static func launchClaudeCode(
        goal: String,
        workspace: String,
        terminals: TerminalManager?,
        tasks: TaskStore?,
        git: GitService?,
        navigate: ((String) -> Void)?
    ) -> LaunchResult {
        let supervisor = ClaudeSessionSupervisor.shared
        supervisor.bind(terminals: terminals, tasks: tasks, git: git)
        supervisor.onNavigate = navigate
        return LaunchResult(supervisor.start(goal: goal, workspace: workspace))
    }

    @discardableResult
    static func stopClaudeCodeTerminals(terminals: TerminalManager?) -> Int {
        ClaudeSessionSupervisor.shared.stop(updatingTerminals: terminals)
    }

    static func buildBrief(goal: String, workspace: String) -> String {
        let g = goal
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Goal (@\(workspace)): \(g)

        QS: piano breve poi edit SOLO root/src tracked (premium-ui.css/js, index). Vietato www/ ios/ android. UI = patcha CSS/JS già linkato. A fine: git status + riepilogo. Qualità design lead mobile premium.
        """
    }

    // MARK: - Grok CLI (lightweight)

    static func launchGrokCLI(
        goal: String,
        workspace: String,
        terminals: TerminalManager?,
        tasks: TaskStore?,
        git: GitService?,
        navigate: ((String) -> Void)?
    ) -> LaunchResult {
        let root = (workspace as NSString).standardizingPath
        guard let terminals else {
            return LaunchResult(ok: false, message: "TerminalManager non disponibile.", terminalID: nil, taskID: nil, binaryPath: nil)
        }
        guard let binary = resolveGrokBinary() else {
            return LaunchResult(ok: false, message: missingGrokMessage, terminalID: nil, taskID: nil, binaryPath: nil)
        }

        // Reuse existing Grok PTY for this workspace
        if let tid = grokSessions[root],
           let term = terminals.sessions.first(where: { $0.id == tid && $0.isAlive }) {
            let brief = buildBrief(goal: goal, workspace: root)
            term.send(brief)
            term.send("\r")
            git?.refresh()
            navigate?("terminals")
            return LaunchResult(
                ok: true,
                message: "**Grok CLI** — follow-up sullo stesso PTY @ `\(root)`.",
                terminalID: term.id,
                taskID: nil,
                binaryPath: binary
            )
        }

        let title = "\(grokTitlePrefix) · \(URL(fileURLWithPath: root).lastPathComponent)"
        guard let term = terminals.openTerminal(at: root, title: title, select: true, role: .builder) else {
            return LaunchResult(
                ok: false,
                message: terminals.lastError ?? "Impossibile aprire terminale.",
                terminalID: nil,
                taskID: nil,
                binaryPath: binary
            )
        }
        grokSessions[root] = term.id

        let boardTask = tasks?.add(
            title: "Grok · \(String(goal.prefix(72)))",
            subtitle: goal,
            model: "grok-cli",
            workspacePath: root,
            linkedTerminalID: term.id,
            source: .orchestrator,
            evidence: ["coding-engine:grok-cli"]
        )
        if let tid = boardTask?.id {
            tasks?.move(tid, to: .inProgress)
        }

        let termID = term.id
        let brief = buildBrief(goal: goal, workspace: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard terminals.sessions.contains(where: { $0.id == termID && $0.isAlive }) else { return }
            _ = terminals.sendCommandLine(
                binary,
                to: termID,
                source: "orchestrator-grok-cli",
                bypassSafety: true,
                roleOverride: .builder
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let t = terminals.sessions.first(where: { $0.id == termID && $0.isAlive }) else { return }
                t.send(brief)
                t.send("\r")
            }
        }

        navigate?("terminals")
        AppLogger.info("Grok CLI launch · \(binary) @ \(root)")
        return LaunchResult(
            ok: true,
            message: """
            **Grok CLI** avviato @ `\(root)`.

            · Stesso modello di Claude: un PTY, chat = follow-up
            · Binary: `\(binary)`
            · Se la TUI chiede conferma, rispondi dalla chat Orchestratore
            """,
            terminalID: term.id,
            taskID: boardTask?.id,
            binaryPath: binary
        )
    }

    static func hasActiveGrokSession(workspace: String, terminals: TerminalManager?) -> Bool {
        let root = (workspace as NSString).standardizingPath
        guard let tid = grokSessions[root], let terminals else { return false }
        if terminals.sessions.contains(where: { $0.id == tid && $0.isAlive }) { return true }
        grokSessions.removeValue(forKey: root)
        return false
    }

    @discardableResult
    static func sendGrokFollowUp(_ text: String, workspace: String, terminals: TerminalManager?) -> Bool {
        let root = (workspace as NSString).standardizingPath
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let terminals,
              let tid = grokSessions[root],
              let term = terminals.sessions.first(where: { $0.id == tid && $0.isAlive }) else {
            return false
        }
        let compact = t.replacingOccurrences(of: "\n+", with: " · ", options: .regularExpression)
        term.send(compact)
        term.send("\r")
        return true
    }

    @discardableResult
    static func stopGrokSessions(terminals: TerminalManager?) -> Int {
        var closed = 0
        let ids = Array(grokSessions.values)
        grokSessions.removeAll()
        for tid in ids {
            if let terminals, terminals.sessions.contains(where: { $0.id == tid }) {
                terminals.close(tid)
                closed += 1
            }
        }
        return closed
    }
}
