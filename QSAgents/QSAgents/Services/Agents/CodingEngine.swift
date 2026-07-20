import Foundation

/// Pluggable coding backends — Claude/Grok CLI or QS API (IDE-in-terminal).
/// Orchestrator + Swarm plan; this owns real edits.
enum CodingEngineKind: String, CaseIterable, Identifiable, Codable {
    case auto
    case claudeCLI
    case grokCLI
    case qsAPI
    case swarm

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .claudeCLI: return "Claude CLI"
        case .grokCLI: return "Grok CLI"
        case .qsAPI: return "QS API"
        case .swarm: return "Swarm"
        }
    }

    var menuLabel: String {
        switch self {
        case .auto: return "Auto (miglior engine)"
        case .claudeCLI: return "Claude Code CLI"
        case .grokCLI: return "Grok Build CLI"
        case .qsAPI: return "QS API · IDE in terminale"
        case .swarm: return "Swarm multi-agent"
        }
    }

    var help: String {
        switch self {
        case .auto:
            return "Sceglie Claude CLI → Grok CLI → QS API (stessa key OpenRouter) → altrimenti messaggio chiaro."
        case .claudeCLI:
            return "Avvia `claude` nel PTY e supervisione (ready/menu/follow-up)."
        case .grokCLI:
            return "Avvia CLI Grok/xAI nel PTY se presente sul PATH."
        case .qsAPI:
            return "Loop IDE QS: API del modello + tools (read/patch/cmd) mirrorati nel terminale."
        case .swarm:
            return "Missione multi-agent (coord/scout/builder). Usa solo se vuoi parallelismo esplicito."
        }
    }
}

/// Result of launching / resolving a coding session.
struct CodingEngineLaunchResult: Equatable {
    let ok: Bool
    let message: String
    let engine: CodingEngineKind
    let terminalID: UUID?
    let taskID: UUID?

    init(ok: Bool, message: String, engine: CodingEngineKind, terminalID: UUID? = nil, taskID: UUID? = nil) {
        self.ok = ok
        self.message = message
        self.engine = engine
        self.terminalID = terminalID
        self.taskID = taskID
    }
}

/// Single entry for coding goals — CLI adapters or QS API IDE loop.
@MainActor
enum CodingEngine {
    private static let defaultsKey = "qs.orchestrator.codingEngine"
    private static let legacyClaudeKey = "qs.orchestrator.useClaudeCode"

    static var preferred: CodingEngineKind {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let kind = CodingEngineKind(rawValue: raw) {
                return kind
            }
            // Migrate old Claude ON/OFF toggle
            if UserDefaults.standard.object(forKey: legacyClaudeKey) != nil {
                return UserDefaults.standard.bool(forKey: legacyClaudeKey) ? .auto : .swarm
            }
            return .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// True when coding should NOT fall through to bare Swarm unless engine == .swarm.
    static var usesDedicatedCodingPath: Bool {
        preferred != .swarm
    }

    // MARK: - Resolve

    /// Pick concrete engine for this machine / keys.
    static func resolveEffective(_ kind: CodingEngineKind? = nil) -> CodingEngineKind {
        let preferred = kind ?? Self.preferred
        switch preferred {
        case .claudeCLI, .grokCLI, .qsAPI, .swarm:
            return preferred
        case .auto:
            if CodingCLILauncher.resolveClaudeBinary() != nil { return .claudeCLI }
            if CodingCLILauncher.resolveGrokBinary() != nil { return .grokCLI }
            if ProviderPreferences.shared.anyKeyedProvider() != nil { return .qsAPI }
            return .qsAPI // still try; surface missing-key clearly
        }
    }

    static func availabilitySummary() -> String {
        let claude = CodingCLILauncher.resolveClaudeBinary() != nil
        let grok = CodingCLILauncher.resolveGrokBinary() != nil
        let api = ProviderPreferences.shared.anyKeyedProvider()?.displayName
        return "Claude CLI \(claude ? "✓" : "✗") · Grok CLI \(grok ? "✓" : "✗") · API \(api ?? "✗")"
    }

    // MARK: - Launch

    static func launch(
        goal: String,
        workspace: String,
        agents: AgentSessionStore?,
        terminals: TerminalManager?,
        tasks: TaskStore?,
        git: GitService?,
        navigate: ((String) -> Void)?,
        force: CodingEngineKind? = nil
    ) -> CodingEngineLaunchResult {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else {
            return CodingEngineLaunchResult(ok: false, message: "Goal vuoto.", engine: preferred)
        }
        let root = (workspace as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: root) else {
            return CodingEngineLaunchResult(
                ok: false,
                message: "Workspace non trovato: `\(root)`",
                engine: preferred
            )
        }

        let engine = resolveEffective(force ?? preferred)

        switch engine {
        case .auto:
            // unreachable — resolveEffective never returns .auto
            return launch(
                goal: g, workspace: root, agents: agents, terminals: terminals,
                tasks: tasks, git: git, navigate: navigate, force: .qsAPI
            )

        case .claudeCLI:
            let r = CodingCLILauncher.launchClaudeCode(
                goal: g, workspace: root,
                terminals: terminals, tasks: tasks, git: git, navigate: navigate
            )
            if r.ok {
                return CodingEngineLaunchResult(
                    ok: true,
                    message: r.message,
                    engine: .claudeCLI,
                    terminalID: r.terminalID,
                    taskID: r.taskID
                )
            }
            // Auto-fallback only when user chose Auto
            if (force ?? preferred) == .auto,
               ProviderPreferences.shared.anyKeyedProvider() != nil {
                return launchQSAPI(
                    goal: g, workspace: root, agents: agents, navigate: navigate,
                    note: "Claude CLI assente → **QS API IDE**.\n\n"
                )
            }
            return CodingEngineLaunchResult(
                ok: false,
                message: r.message,
                engine: .claudeCLI,
                terminalID: r.terminalID,
                taskID: r.taskID
            )

        case .grokCLI:
            let r = CodingCLILauncher.launchGrokCLI(
                goal: g, workspace: root,
                terminals: terminals, tasks: tasks, git: git, navigate: navigate
            )
            if r.ok {
                return CodingEngineLaunchResult(
                    ok: true,
                    message: r.message,
                    engine: .grokCLI,
                    terminalID: r.terminalID,
                    taskID: r.taskID
                )
            }
            if (force ?? preferred) == .auto,
               ProviderPreferences.shared.anyKeyedProvider() != nil {
                return launchQSAPI(
                    goal: g, workspace: root, agents: agents, navigate: navigate,
                    note: "Grok CLI assente → **QS API IDE**.\n\n"
                )
            }
            return CodingEngineLaunchResult(
                ok: false,
                message: r.message,
                engine: .grokCLI
            )

        case .qsAPI:
            return launchQSAPI(goal: g, workspace: root, agents: agents, navigate: navigate, note: "")

        case .swarm:
            return CodingEngineLaunchResult(
                ok: false,
                message: "Engine = Swarm — usa `startGoalMode` dal chiamante.",
                engine: .swarm
            )
        }
    }

    private static func launchQSAPI(
        goal: String,
        workspace: String,
        agents: AgentSessionStore?,
        navigate: ((String) -> Void)?,
        note: String
    ) -> CodingEngineLaunchResult {
        guard let agents else {
            return CodingEngineLaunchResult(
                ok: false,
                message: "Agent store non disponibile.",
                engine: .qsAPI
            )
        }
        guard ProviderPreferences.shared.anyKeyedProvider() != nil else {
            return CodingEngineLaunchResult(
                ok: false,
                message: """
                **Nessuna API key** per QS API IDE.

                Impostazioni → Integrazioni → OpenRouter / Grok / Anthropic.
                Oppure installa Claude Code (`which claude`) e scegli **Claude CLI**.
                Disponibilità: \(availabilitySummary())
                """,
                engine: .qsAPI
            )
        }
        let result = agents.startIDESession(goal: goal, workspace: workspace)
        if result.ok {
            navigate?("terminals")
        }
        return CodingEngineLaunchResult(
            ok: result.ok,
            message: note + result.message,
            engine: .qsAPI,
            terminalID: result.terminalID,
            taskID: result.taskID
        )
    }

    // MARK: - Session layer (follow-up / stop)

    static func hasActiveSession(
        workspace: String?,
        agents: AgentSessionStore?,
        terminals: TerminalManager?
    ) -> Bool {
        let ws = workspace.map { ($0 as NSString).standardizingPath }
        if let ws, ClaudeSessionSupervisor.shared.hasActiveSession(for: ws) { return true }
        if let ws, CodingCLILauncher.hasActiveGrokSession(workspace: ws, terminals: terminals) { return true }
        if let agents, agents.hasActiveIDESession(workspacePath: ws) { return true }
        return false
    }

    @discardableResult
    static func sendFollowUp(
        _ text: String,
        workspace: String?,
        agents: AgentSessionStore?,
        terminals: TerminalManager?
    ) -> (ok: Bool, detail: String) {
        let ws = workspace.map { ($0 as NSString).standardizingPath }
        if let ws, ClaudeSessionSupervisor.shared.hasActiveSession(for: ws) {
            let ok = ClaudeSessionSupervisor.shared.sendFollowUp(text)
            return (ok, ok ? "Inviato a Claude CLI (stesso PTY)." : "PTY Claude non raggiungibile.")
        }
        if let ws, CodingCLILauncher.hasActiveGrokSession(workspace: ws, terminals: terminals) {
            let ok = CodingCLILauncher.sendGrokFollowUp(text, workspace: ws, terminals: terminals)
            return (ok, ok ? "Inviato a Grok CLI (stesso PTY)." : "PTY Grok non raggiungibile.")
        }
        if let agents, agents.hasActiveIDESession(workspacePath: ws) {
            let ok = agents.sendIDEFollowUp(text)
            return (ok, ok
                ? "Guida inviata all’agent QS API (stesso PTY / loop)."
                : "Nessun agent IDE attivo — rilancia il goal.")
        }
        return (false, "Nessuna sessione coding attiva.")
    }

    @discardableResult
    static func stop(terminals: TerminalManager?, agents: AgentSessionStore?) -> Int {
        var n = ClaudeSessionSupervisor.shared.stop(updatingTerminals: terminals)
        n += CodingCLILauncher.stopGrokSessions(terminals: terminals)
        agents?.stopIDESessions()
        return n
    }
}
