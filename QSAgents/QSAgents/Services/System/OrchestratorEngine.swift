import Foundation
import Combine

enum ReplyEngine: Equatable {
    case localRules
    case llm(provider: String, model: String)
    case voiceNote

    var badge: String {
        switch self {
        case .localRules: return "Regole locali"
        case .llm(let provider, let model): return "\(provider) · \(model)"
        case .voiceNote: return "Voce"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    var actions: [OrchestratorAction]
    var engine: ReplyEngine?
    var isVoice: Bool
    /// C3: true while tokens are still arriving.
    var isStreaming: Bool

    enum Role: String {
        case user, assistant, system
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = .now,
        actions: [OrchestratorAction] = [],
        engine: ReplyEngine? = nil,
        isVoice: Bool = false,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.actions = actions
        self.engine = engine
        self.isVoice = isVoice
        self.isStreaming = isStreaming
    }
}

enum OrchestratorAction: Equatable {
    case openTerminal(path: String, title: String?)
    case runCommand(command: String, path: String?)
    case focusTerminal(id: UUID)
    case revealPath(String)
    case openIntegrations
    case switchView(String)
    case spawnAgent(goal: String)
    /// Full Swarm / GOAL mission (coord + builders) — preferred for product/UI work.
    case startMission(goal: String)
    /// Create a board task (title; optional subtitle after first |).
    case createTask(title: String, subtitle: String?)
    /// Start builder on board task (title or id).
    case startBoardTask(titleOrId: String)
}

/// Live “what is the orchestrator doing?” — Claude/ChatGPT-style status trail.
enum OrchestratorPhase: String, Equatable {
    case idle
    case thinking
    case callingLLM
    case streaming
    case runningTool
    case waitingTerminal
    case waitingAgents
    case applying
    case goal
    case done

    /// Italian source key — pass through `L()` at display time.
    var label: String {
        switch self {
        case .idle: return "Inattivo"
        case .thinking: return "Pensando"
        case .callingLLM: return "Chiamo il modello"
        case .streaming: return "Sto scrivendo"
        case .runningTool: return "Eseguo tool"
        case .waitingTerminal: return "Attendo terminale"
        case .waitingAgents: return "Attendo agent"
        case .applying: return "Applico azioni"
        case .goal: return "GOAL MODE"
        case .done: return "Fatto"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .thinking: return "brain.head.profile"
        case .callingLLM: return "sparkles"
        case .streaming: return "text.cursor"
        case .runningTool: return "wrench.and.screwdriver"
        case .waitingTerminal: return "terminal"
        case .waitingAgents: return "person.3"
        case .applying: return "checkmark.diamond"
        case .goal: return "target"
        case .done: return "checkmark.circle"
        }
    }

    var isBusy: Bool {
        self != .idle && self != .done
    }
}

struct OrchestratorActivityEntry: Identifiable, Equatable {
    let id: UUID
    var phase: OrchestratorPhase
    var detail: String
    var at: Date
    var done: Bool

    init(
        id: UUID = UUID(),
        phase: OrchestratorPhase,
        detail: String,
        at: Date = .now,
        done: Bool = false
    ) {
        self.id = id
        self.phase = phase
        self.detail = detail
        self.at = at
        self.done = done
    }
}

@MainActor
final class OrchestratorEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    /// Local media / files attached to the next chat send (images, pdf, text).
    @Published var draftAttachments: [URL] = []
    @Published var isThinking: Bool = false
    @Published var lastActions: [OrchestratorAction] = []
    /// Ultimo motore usato per rispondere (per badge UI).
    @Published var lastReplyEngine: ReplyEngine = .localRules
    /// Live model switch (Home / chat header).
    @Published var selectedProviderRaw: String?
    @Published var selectedModel: String?
    /// Last LLM failure (surfaced in UI / fallback text).
    @Published var lastLLMError: String?
    /// GOAL MODE: user messages become autonomous missions (auto-split, elevated token budget).
    @Published var goalModeEnabled: Bool = false {
        didSet {
            agents?.goalModePreferred = goalModeEnabled
        }
    }
    /// Coding engine: Auto / Claude CLI / Grok CLI / QS API IDE / Swarm.
    @Published var codingEngine: CodingEngineKind = CodingEngine.preferred {
        didSet { CodingEngine.preferred = codingEngine }
    }
    /// Legacy bridge for older call sites / chips.
    var useClaudeCodeEnabled: Bool {
        get { codingEngine != .swarm }
        set { codingEngine = newValue ? .auto : .swarm }
    }
    /// Last coding PTY / board task (for stop + UI).
    private(set) var lastClaudeCodeTerminalID: UUID?
    private(set) var lastClaudeCodeTaskID: UUID?
    /// Trail of what the orchestrator is doing (visible in chat).
    @Published private(set) var activityLog: [OrchestratorActivityEntry] = []
    @Published private(set) var livePhase: OrchestratorPhase = .idle
    @Published private(set) var liveDetail: String = ""

    private var agentPulseTask: Task<Void, Never>?
    private var lastAgentPulseSignature: String = ""

    /// Wipe chat transcript + activity trail.
    /// Archives the current transcript to Chat History so nothing is lost.
    /// - Parameter stopAgents: if true, also cancel mission/agent loops (BUG-013).
    func clearChat(stopAgents: Bool = false) {
        // Always pause pulse during clear so mid-clear ticks don't mutate UI.
        agentPulseTask?.cancel()
        agentPulseTask = nil
        lastAgentPulseSignature = ""

        let ws = workspaces?.current?.path
        if !messages.isEmpty {
            _ = ChatHistoryStore.shared.archiveLive(workspacePath: ws, messages: messages)
            flushSessionToProjectMemory(force: true)
        }
        messages.removeAll(keepingCapacity: false)
        activityLog.removeAll(keepingCapacity: false)
        draft = ""
        draftAttachments = []
        lastActions = []
        lastLLMError = nil
        livePhase = .idle
        liveDetail = stopAgents ? L("Chat pulita · agent fermati") : ""
        isThinking = false

        if stopAgents {
            agents?.stopAll()
            agents?.clearMission()
            _ = CodingEngine.stop(terminals: terminals, agents: agents)
            goalModeEnabled = false
        }

        _ = ChatHistoryStore.shared.saveLive(workspacePath: ws, messages: [])
        messages = [Self.makeWelcomeMessage()]
    }

    /// Restore a saved / archived transcript into the live chat.
    func restoreChatHistory(_ transcriptID: UUID) {
        guard let t = ChatHistoryStore.shared.restoreAsLive(transcriptID) else { return }
        messages = t.messages.map { $0.asChatMessage() }
        activityLog.removeAll(keepingCapacity: false)
        livePhase = .idle
        liveDetail = L("History ripristinata") + " · \(t.title)"
    }

    /// Load live transcript for a workspace (call on bind / workspace switch).
    func loadChatForWorkspace(_ path: String?, savingPrevious previousPath: String? = nil) {
        if let prev = previousPath, prev != path, !messages.isEmpty {
            _ = ChatHistoryStore.shared.saveLive(workspacePath: prev, messages: messages)
        }
        guard let path, !path.isEmpty else {
            messages = [Self.makeWelcomeMessage()]
            return
        }
        if let t = ChatHistoryStore.shared.activeTranscript(for: path), !t.messages.isEmpty {
            messages = t.messages.map { $0.asChatMessage() }
        } else {
            messages = [Self.makeWelcomeMessage()]
            _ = ChatHistoryStore.shared.saveLive(workspacePath: path, messages: messages)
        }
        activityLog.removeAll(keepingCapacity: false)
        livePhase = .idle
        liveDetail = ""
    }

    private var chatPersistTask: Task<Void, Never>?
    func persistChatHistoryDebounced() {
        let ws = workspaces?.current?.path
        let snapshot = messages
        chatPersistTask?.cancel()
        chatPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            _ = ChatHistoryStore.shared.saveLive(workspacePath: ws, messages: snapshot)
        }
    }

    func persistChatHistoryNow() {
        chatPersistTask?.cancel()
        _ = ChatHistoryStore.shared.saveLive(
            workspacePath: workspaces?.current?.path,
            messages: messages
        )
    }

    /// True when a board task is waiting for human review (show “Applica feedback”).
    var hasTaskInReview: Bool {
        tasks?.tasks.contains { $0.column == .review } == true
    }

    /// Collect recent user feedback and send it to the same coding PTY / IDE session.
    @discardableResult
    func applyReviewFeedback(extra: String? = nil) -> Bool {
        let typed = (extra ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let recentUser = messages
            .filter { $0.role == .user }
            .suffix(4)
            .map(\.text)
            .filter { !$0.hasPrefix("🎤") }
        var chunks: [String] = []
        if !typed.isEmpty { chunks.append(typed) }
        for u in recentUser where !chunks.contains(u) {
            chunks.append(u)
        }
        let feedback = chunks.joined(separator: "\n---\n")
        guard !feedback.isEmpty else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "Scrivi prima i ritocchi in chat (o nel campo), poi **Applica feedback**.",
                engine: .localRules
            ))
            return false
        }

        let prompt = """
        L'utente ha revisionato il lavoro (QS Task IN REVISIONE). Applica questo feedback sullo stesso repo, senza rifare tutto da zero. Poi `git status` e conferma cosa hai cambiato.

        FEEDBACK:
        \(feedback)
        """

        draft = ""
        messages.append(ChatMessage(role: .user, text: "Applica feedback:\n\(feedback)", isVoice: false))
        memory.remember(role: "user", text: "Applica feedback: \(String(feedback.prefix(160)))")

        // Move review tasks for this workspace back to in progress
        let ws = workspaces?.current?.path
        if let tasks {
            for t in tasks.tasks where t.column == .review {
                if let ws, let tw = t.workspacePath, tw != ws { continue }
                tasks.move(t.id, to: .inProgress)
                tasks.appendEvidence(t.id, "feedback-applied")
            }
        }

        let result = CodingEngine.sendFollowUp(
            prompt, workspace: ws, agents: agents, terminals: terminals
        )
        if !result.ok, CodingEngine.usesDedicatedCodingPath, let path = ws {
            let launch = CodingEngine.launch(
                goal: prompt,
                workspace: path,
                agents: agents,
                terminals: terminals,
                tasks: tasks,
                git: git,
                navigate: { [weak self] route in self?.navigate(route) }
            )
            messages.append(ChatMessage(
                role: .assistant,
                text: launch.ok
                    ? "**Feedback inviato** — nuova sessione coding.\n\n\(launch.message)"
                    : "⚠️ \(launch.message)",
                engine: .localRules
            ))
            persistChatHistoryDebounced()
            return launch.ok
        }
        messages.append(ChatMessage(
            role: .assistant,
            text: result.ok
                ? "**Feedback inviato** allo stesso PTY/IDE. La risposta tornerà in chat."
                : "⚠️ \(result.detail)",
            engine: .localRules
        ))
        persistChatHistoryDebounced()
        return result.ok
    }

    /// Save current draft / last user goal as a one-click shortcut (“ricetta”).
    func saveRecipeFromChat() {
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (messages.last(where: { $0.role == .user })?.text ?? "")
            : draft
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "Niente da salvare: scrivi un goal o usa l’ultimo messaggio utente, oppure usa **Salva scorciatoia**.",
                engine: .localRules
            ))
            return
        }
        WorkRecipeStore.shared.add(
            title: String(g.prefix(48)),
            goal: g,
            workspacePath: workspaces?.current?.path,
            engine: codingEngine
        )
        messages.append(ChatMessage(
            role: .assistant,
            text: "**Scorciatoia salvata** — menu **Rilancia** sopra la chat (stesso goal + engine). Non è un menu di cucina: è un preferito one-click.",
            engine: .localRules
        ))
    }

    /// Replay a saved recipe (sets engine + launches coding / sends goal).
    func runRecipe(_ recipe: WorkRecipe) {
        WorkRecipeStore.shared.recordUse(recipe.id)
        codingEngine = recipe.engine
        if let path = recipe.workspacePath, workspaces?.current?.path != path {
            _ = workspaces?.open(path: path)
        }
        draft = recipe.goal
        goalModeEnabled = true
        send()
    }

    /// Build a text block the agent / Claude can use (paths + inline text; images as path note).
    static func formatAttachments(_ urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        var parts: [String] = ["[Allegati utente]"]
        for url in urls.prefix(8) {
            let path = url.path
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff"]
            let textExts: Set<String> = ["txt", "md", "swift", "js", "ts", "tsx", "jsx", "css", "html", "json", "yml", "yaml", "toml", "csv", "log"]
            if imageExts.contains(ext) {
                parts.append("• Immagine: `\(path)` (\(name)) — apri/leggi questo file sul disco se serve.")
            } else if textExts.contains(ext),
                      let data = try? Data(contentsOf: url),
                      data.count < 48_000,
                      let body = String(data: data, encoding: .utf8) {
                let clipped = body.count > 12_000 ? String(body.prefix(12_000)) + "\n… [troncato]" : body
                parts.append("• File testo `\(name)` (`\(path)`):\n```\n\(clipped)\n```")
            } else if ext == "pdf" {
                parts.append("• PDF: `\(path)` — usa tool/CLI per estrarre testo se necessario.")
            } else {
                parts.append("• File: `\(path)` (\(name))")
            }
        }
        return parts.joined(separator: "\n")
    }

    func addDraftAttachment(_ url: URL) {
        guard !draftAttachments.contains(url) else { return }
        draftAttachments.append(url)
    }

    func removeDraftAttachment(_ url: URL) {
        draftAttachments.removeAll { $0 == url }
    }

    weak var terminals: TerminalManager?
    weak var directories: DirectoryStore?
    weak var probe: SystemProbe?
    weak var safety: SafetyGuardrails?
    weak var tasks: TaskStore?
    weak var workspaces: WorkspaceStore?
    weak var git: GitService?
    weak var agents: AgentSessionStore?
    weak var knowledge: KnowledgeStore?
    weak var projectMemory: ProjectMemoryStore?
    let tools = OrchestratorToolRunner()
    let memory = OrchestratorMemory()
    let dryRun = DryRunController()
    var onNavigate: ((String) -> Void)?
    var onSpeak: ((String) -> Void)?
    /// A6: when true (e.g. ⌘K modal open), tool side-effects must not change main route.
    var stayInPlaceProvider: (() -> Bool)?

    private func navigate(_ route: String, force: Bool = false) {
        let stay = stayInPlaceProvider?() ?? tools.stayInPlace
        if stay && !force { return }
        onNavigate?(route)
    }

    /// Public: surface QS Tasks after auto-seed (mission/goal start).
    func navigateToTasksBoard() {
        navigate("tasks", force: true)
    }

    init() {
        messages = [Self.makeWelcomeMessage()]
    }

    /// Language-aware welcome bubble shown on first open / after clear.
    static func makeWelcomeMessage() -> ChatMessage {
        let ai = Self.describeConfiguredAI()
        let engineLabel = CodingEngine.preferred.menuLabel
        let avail = CodingEngine.availabilitySummary()
        let en = AppLanguageStore.shared.isEnglish
        let text: String
        if en {
            text = """
            Hi — I'm the **QS Orchestrator**.

            **Current AI:** \(ai)
            **Coding engine:** \(engineLabel) · \(avail)

            I'm a **layer** on top of the coding engine (one PTY, listening, tasks, chat → same session):
            • **Auto** — Claude CLI → Grok CLI → QS API IDE (tools + OpenRouter model)
            • **QS API** — IDE in the terminal without external CLIs
            • **Swarm** — only if you choose it explicitly or say «start mission …»

            Try:
            `In Home, improve the PLAY…` → keep writing here (same PTY/loop)
            `open coding engine here` · «stop goal»
            Or hold 🎤 and speak.
            """
        } else {
            text = """
            Ciao — sono l'**Orchestratore QS**.

            **AI attuale:** \(ai)
            **Coding engine:** \(engineLabel) · \(avail)

            Sono un **layer** sopra il coding engine (un PTY, ascolto, task, chat → stessa sessione):
            • **Auto** — Claude CLI → Grok CLI → QS API IDE (tools + modello OpenRouter)
            • **QS API** — IDE nel terminale senza CLI esterni
            • **Swarm** — solo se lo scegli esplicitamente o «avvia missione …»

            Prova:
            `Nella home migliora il PLAY…` → continua a scrivere qui (stesso PTY/loop)
            `apri coding engine qui` · «stop goal»
            Oppure tieni premuto 🎤 e parla.
            """
        }
        return ChatMessage(role: .assistant, text: text, engine: .localRules)
    }

    /// Marker used to detect the seeded welcome so language switches can refresh it.
    static var welcomeMarkerIT: String { "Ciao — sono l'" }
    static var welcomeMarkerEN: String { "Hi — I'm the" }

    /// Refresh welcome when language changes and chat is still only the initial bubble (or empty).
    func refreshWelcomeForLanguageIfNeeded() {
        if messages.isEmpty {
            messages = [Self.makeWelcomeMessage()]
            return
        }
        guard messages.count == 1, messages[0].role == .assistant else { return }
        let t = messages[0].text
        let isWelcome = t.contains(Self.welcomeMarkerIT) || t.contains(Self.welcomeMarkerEN)
            || t.contains("Orchestratore QS") || t.contains("QS Orchestrator")
        guard isWelcome else { return }
        messages = [Self.makeWelcomeMessage()]
    }

    /// Quale backend è configurato adesso (Keychain + override live).
    static func describeConfiguredAI() -> String {
        LLMClient.shared.configuredSummary()
    }

    var selectedProviderKind: LLMProviderKind? {
        if let raw = selectedProviderRaw, let k = LLMProviderKind(rawValue: raw) {
            return k
        }
        return ProviderPreferences.shared.defaultProvider ?? LLMClient.shared.preferredProvider()
    }

    var configuredAISummary: String {
        if let p = selectedProviderKind, LLMClient.shared.hasKey(p) {
            let m = selectedModel ?? ProviderPreferences.shared.model(for: .coordinator)
            return "\(p.displayName) · `\(m)` (live)"
        }
        return Self.describeConfiguredAI()
    }

    func setLiveProvider(_ p: LLMProviderKind) {
        selectedProviderRaw = p.rawValue
        let current = selectedModel.map { p.canonicalizeModelID($0) }
        if current == nil || !(ProviderPreferences.shared.models(for: p).contains(current ?? "")) {
            selectedModel = p.defaultModel
        } else {
            selectedModel = current
        }
    }

    func setLiveModel(_ model: String) {
        if let p = selectedProviderKind {
            selectedModel = p.canonicalizeModelID(model)
        } else {
            selectedModel = model
        }
    }

    func bind(
        terminals: TerminalManager,
        directories: DirectoryStore,
        probe: SystemProbe,
        safety: SafetyGuardrails? = nil,
        tasks: TaskStore? = nil,
        workspaces: WorkspaceStore? = nil,
        git: GitService? = nil,
        agents: AgentSessionStore? = nil,
        knowledge: KnowledgeStore? = nil,
        projectMemory: ProjectMemoryStore? = nil,
        onNavigate: @escaping (String) -> Void
    ) {
        self.terminals = terminals
        self.directories = directories
        self.probe = probe
        self.safety = safety
        self.tasks = tasks
        self.workspaces = workspaces
        self.git = git
        self.agents = agents
        self.knowledge = knowledge
        self.projectMemory = projectMemory
        self.onNavigate = onNavigate
        tools.terminals = terminals
        tools.directories = directories
        tools.probe = probe
        tools.tasks = tasks
        tools.workspaces = workspaces
        tools.safety = safety
        tools.git = git
        tools.agents = agents
        tools.knowledge = knowledge
        tools.projectMemory = projectMemory
        tools.dryRun = dryRun.enabled
        tools.onNavigate = onNavigate
        tools.onActivity = { [weak self] phase, detail in
            self?.pushActivity(phase, detail)
        }
        bindClaudeSupervisor()
        startAgentPulseIfNeeded()
        loadChatForWorkspace(workspaces?.current?.path)
    }

    private func bindClaudeSupervisor() {
        let s = ClaudeSessionSupervisor.shared
        s.bind(terminals: terminals, tasks: tasks, git: git)
        s.onNavigate = { [weak self] route in self?.navigate(route) }
        s.onActivity = { [weak self] label, detail in
            guard let self else { return }
            let phase: OrchestratorPhase = {
                switch label {
                case "done": return .done
                case "goal", "running": return .waitingTerminal
                case "menu", "starting": return .waitingTerminal
                case "waitingTerminal": return .waitingTerminal
                default: return .waitingTerminal
                }
            }()
            self.pushActivity(phase, detail)
            if phase == .waitingTerminal || phase == .done {
                self.livePhase = phase == .done ? .idle : .waitingTerminal
                self.liveDetail = detail
            }
        }
        s.onChatNotice = { [weak self] text in
            guard let self else { return }
            self.messages.append(ChatMessage(role: .assistant, text: text, engine: .localRules))
            self.memory.remember(role: "assistant", text: text)
            self.persistChatHistoryDebounced()
        }
    }

    // MARK: - Activity log (Claude-style “what I’m doing”)

    var isActivityVisible: Bool {
        if isThinking || livePhase.isBusy { return true }
        if let m = agents?.mission, m.phase != .done { return true }
        return false
    }

    func pushActivity(_ phase: OrchestratorPhase, _ detail: String = "") {
        let raw = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        // Translate static Italian process labels; interpolated strings pass through unchanged.
        let d = raw.isEmpty ? "" : L(raw)
        // Ignore Claude TUI footer spam
        if d.contains("auto mode on") || d.contains("shift+tab to cycle") { return }
        // Dedupe identical busy steps (was flooding «Attendo terminale» ×10)
        if let last = activityLog.last,
           !last.done,
           last.phase == phase,
           last.detail == d || (phase == .waitingTerminal && last.phase == .waitingTerminal) {
            livePhase = phase == .done ? .idle : phase
            liveDetail = d
            return
        }
        // Close previous open step
        if let last = activityLog.indices.last, !activityLog[last].done {
            activityLog[last].done = true
        }
        let entry = OrchestratorActivityEntry(phase: phase, detail: d, done: phase == .done)
        activityLog.append(entry)
        if activityLog.count > 48 {
            activityLog = Array(activityLog.suffix(48))
        }
        livePhase = phase == .done ? .idle : phase
        liveDetail = d
    }

    private func beginActivityTurn(_ detail: String) {
        activityLog.removeAll(keepingCapacity: true)
        lastAgentPulseSignature = ""
        pushActivity(.thinking, detail)
    }

    private func finishActivityTurn(successDetail: String = "Pronto") {
        pushActivity(.done, successDetail)
        livePhase = .idle
        liveDetail = ""
        isThinking = false
        persistChatHistoryDebounced()
        maybeFlushSessionMemory()
    }

    /// Periodic pulse while a swarm/GOAL mission is running — shows agent status in chat log.
    private func startAgentPulseIfNeeded() {
        agentPulseTask?.cancel()
        agentPulseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { self?.pulseAgentActivity() }
            }
        }
    }

    private func pulseAgentActivity() {
        // Claude PTY supervision layer (independent of Swarm mission)
        let claude = ClaudeSessionSupervisor.shared
        if claude.session != nil {
            claude.pulse()
            if let s = claude.session, s.phase == .running || s.phase == .awaitingInput || s.phase == .menu || s.phase == .starting {
                let sig = "claude|\(s.phase.rawValue)|\(s.lastTail.suffix(40))"
                if sig != lastAgentPulseSignature {
                    lastAgentPulseSignature = sig
                    livePhase = .waitingTerminal
                    liveDetail = "Claude · \(s.phase.rawValue) · \(String(s.lastTail.suffix(48)))"
                }
            }
        }

        guard let agents else { return }
        if let m = agents.mission, m.phase == .done, livePhase.isBusy, claude.session == nil {
            pushActivity(.done, m.goalMode ? "Goal completato" : "Missione completata")
            livePhase = .idle
            liveDetail = ""
            return
        }
        guard let m = agents.mission, m.phase != .done else { return }
        let busy = agents.sessions.filter { $0.status == .thinking || $0.status == .active }
        let idle = agents.sessions.filter { $0.status == .idle || $0.status == .error }

        // Kick even when signature is unchanged — otherwise one idle pulse stalls forever.
        if busy.isEmpty {
            agents.kickStalledMissionIfNeeded()
        }

        let parts = busy.prefix(4).map { s -> String in
            let st = s.status == .thinking ? "pensa" : "lavora"
            let goal = (s.lastGoal ?? "").prefix(36)
            return "\(s.name) \(st)\(goal.isEmpty ? "" : " · \(goal)")"
        }
        let sig = "\(m.phase.rawValue)|\(busy.count)|\(parts.joined())|\(m.splitCount)"
        guard sig != lastAgentPulseSignature else { return }
        lastAgentPulseSignature = sig

        if busy.isEmpty {
            if m.phase == .planning || m.phase == .awaitingUser {
                pushActivity(.waitingAgents, "Missione \(m.phase.rawValue) — kick antistallo…")
            } else if !idle.isEmpty {
                pushActivity(.waitingAgents, "Nessun agent attivo — riparto sulla prossima task")
            }
            return
        }
        let phase: OrchestratorPhase = m.goalMode ? .goal : .waitingAgents
        let head = m.goalMode ? "GOAL" : "Swarm"
        pushActivity(phase, "\(head) · \(busy.count) agent: \(parts.joined(separator: " · "))")
    }

    func send(isVoice: Bool = false) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachBlock = Self.formatAttachments(draftAttachments)
        let text: String
        if typed.isEmpty, attachBlock.isEmpty {
            return
        } else if typed.isEmpty {
            text = attachBlock
        } else if attachBlock.isEmpty {
            text = typed
        } else {
            text = typed + "\n\n" + attachBlock
        }
        draft = ""
        draftAttachments = []
        // A6: sync stayInPlace from UI (modal / board) before any tool runs
        let stay = stayInPlaceProvider?() ?? false
        tools.stayInPlace = stay
        messages.append(ChatMessage(role: .user, text: text, isVoice: isVoice))
        memory.remember(role: "user", text: text)
        persistChatHistoryDebounced()
        isThinking = true
        beginActivityTurn(String(text.prefix(80)))

        if isGoalStopCommand(text) {
            pushActivity(.runningTool, "Stop agent / coding engine / pausa GOAL")
            agents?.stopAll()
            let closed = CodingEngine.stop(terminals: terminals, agents: agents)
            lastClaudeCodeTerminalID = nil
            let reply = ChatMessage(
                role: .assistant,
                text: "Pausa — sessioni fermate" + (closed > 0 ? "; chiusi \(closed) PTY coding." : ".")
                    + " L’engine resta \(codingEngine.shortLabel); il prossimo messaggio riparte.",
                engine: .localRules
            )
            messages.append(reply)
            memory.remember(role: "assistant", text: reply.text)
            lastReplyEngine = .localRules
            finishActivityTurn(successDetail: "GOAL in pausa")
            isThinking = false
            return
        }

        // Active coding session: chat → SAME PTY / IDE loop (not a new Swarm).
        let wsPath = workspaces?.current?.path
        if CodingEngine.usesDedicatedCodingPath,
           CodingEngine.hasActiveSession(workspace: wsPath, agents: agents, terminals: terminals),
           !isOrchestratorMetaQuery(text) {
            pushActivity(.waitingTerminal, "Follow-up → coding engine")
            // Instant status for «hai finito?» while Claude also answers in PTY
            let finishQ = text.lowercased().contains("hai finito")
                || text.lowercased().contains("task finita")
                || text.lowercased().contains("è finita")
            if finishQ {
                let snap = ClaudeSessionSupervisor.shared.statusSummaryForChat()
                messages.append(ChatMessage(
                    role: .assistant,
                    text: snap + "\n\nChiedo conferma a Claude nel PTY — la **risposta completa** arriva qui tra poco.",
                    engine: .localRules
                ))
            }
            let result = CodingEngine.sendFollowUp(
                text, workspace: wsPath, agents: agents, terminals: terminals
            )
            let reply = ChatMessage(
                role: .assistant,
                text: result.ok
                    ? (finishQ
                       ? "**Inviato a Claude** — aspetto la risposta e la porto in questa chat (e aggiorno QS Tasks)."
                       : "**Inviato a Claude** (stesso PTY).\n\nLa sua risposta tornerà **qui in chat** quando avrà finito di scrivere nel terminale.")
                    : "⚠️ \(result.detail)",
                engine: .localRules
            )
            messages.append(reply)
            memory.remember(role: "assistant", text: reply.text)
            lastReplyEngine = .localRules
            livePhase = .waitingTerminal
            liveDetail = L("Attendo risposta Claude → chat")
            // Stay on chat so the relayed answer is visible (user can still open Terminali)
            finishActivityTurn(successDetail: result.ok ? "follow-up coding" : "follow-up failed")
            isThinking = false
            return
        }

        // Coding / product goals → CodingEngine (CLI or QS API IDE). Swarm only if engine == .swarm.
        let autoMission = looksLikeAutonomousWork(text) && workspaces?.current != nil
        if (goalModeEnabled && shouldPursueAsGoal(text)) || autoMission {
            if codingEngine != .swarm, let ws = workspaces?.current?.path {
                let effective = CodingEngine.resolveEffective(codingEngine)
                pushActivity(.goal, "Avvio \(effective.shortLabel)…")
                let result = launchCodingEngine(goal: text, workspace: ws)
                let reply = ChatMessage(
                    role: .assistant,
                    text: result.message + (result.ok ? "\n\n**Goal:** \(text)" : ""),
                    engine: .localRules
                )
                messages.append(reply)
                memory.remember(role: "assistant", text: reply.text)
                lastReplyEngine = .localRules
                if result.ok {
                    lastClaudeCodeTerminalID = result.terminalID
                    lastClaudeCodeTaskID = result.taskID
                    pushActivity(.waitingTerminal, "\(result.engine.shortLabel) attivo — tab Terminali")
                    livePhase = .waitingTerminal
                    liveDetail = "\(result.engine.shortLabel) · \(ws)"
                } else {
                    pushActivity(.thinking, "Coding engine non disponibile")
                    finishActivityTurn(successDetail: "coding engine failed")
                }
                isThinking = false
                return
            }

            // Explicit Swarm engine
            agents?.goalModePreferred = true
            if let p = selectedProviderKind ?? LLMClient.shared.preferredProvider()
                ?? ProviderPreferences.shared.anyKeyedProvider() {
                let m = selectedModel?.isEmpty == false ? selectedModel! : ProviderPreferences.shared.model(for: .coordinator)
                ProviderPreferences.shared.syncSwarmFromLive(provider: p, model: m)
            }
            pushActivity(.goal, autoMission && !goalModeEnabled ? "Missione Swarm…" : "Avvio missione Swarm…")
            // startGoalMode / direct-patch seed QS Task themselves — avoid duplicate cards.
            agents?.startGoalMode(goal: text, builders: 2)
            navigate("tasks", force: true)
            navigate("swarm")
            let reply = ChatMessage(
                role: .assistant,
                text: """
                **Swarm** — perseguo fino a DONE.

                Goal: \(text)

                · Workspace: \(workspaces?.current?.path ?? "?")
                · QS Task collegata sulla board
                · Per IDE singolo-PTY: scegli **Auto** o **QS API** nel menu Coding
                · Log in **QS Swarm** · Di’ «stop goal» per fermare
                """,
                engine: .localRules
            )
            messages.append(reply)
            memory.remember(role: "assistant", text: reply.text)
            lastReplyEngine = .localRules
            pushActivity(.waitingAgents, "Swarm builders avviati")
            isThinking = false
            livePhase = .waitingAgents
            liveDetail = L("Missione Swarm in corso…")
            return
        }

        // C3: placeholder bubble that fills token-by-token when LLM streams
        let streamId = UUID()
        messages.append(ChatMessage(
            id: streamId,
            role: .assistant,
            text: "",
            isStreaming: true
        ))

        Task {
            pushActivity(.thinking, "Analizzo la richiesta…")
            let reply = await handle(text, streamMessageId: streamId)
            if let i = messages.firstIndex(where: { $0.id == streamId }) {
                var final = reply
                // keep stable id so List doesn't jump
                final = ChatMessage(
                    id: streamId,
                    role: reply.role,
                    text: reply.text.isEmpty ? "…" : reply.text,
                    timestamp: reply.timestamp,
                    actions: reply.actions,
                    engine: reply.engine,
                    isVoice: reply.isVoice,
                    isStreaming: false
                )
                messages[i] = final
            } else {
                messages.append(reply)
            }
            memory.remember(role: "assistant", text: reply.text)
            lastActions = reply.actions
            lastReplyEngine = reply.engine ?? .localRules
            if !reply.actions.isEmpty {
                pushActivity(.applying, "\(reply.actions.count) azion\(reply.actions.count == 1 ? "e" : "i")…")
            }
            await apply(reply.actions)
            onSpeak?(reply.text)
            finishActivityTurn(successDetail: reply.actions.isEmpty ? "Risposta pronta" : "Azioni completate")
            // B3: periodically fold chat into project memory
            maybeFlushSessionMemory()
        }
    }

    /// Live status lines from AgentSessionStore during GOAL MODE.
    func notifyGoalMode(_ event: String) {
        let line = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        pushActivity(.goal, line)
        messages.append(ChatMessage(
            role: .system,
            text: "🎯 GOAL · \(line)",
            engine: .localRules
        ))
    }

    /// Board / Swarm "Avvia": always go through the orchestrator so it owns the sub-agent.
    /// Claude Code tasks → same supervised PTY (never Swarm builder).
    @discardableResult
    func launchBoardTask(_ taskId: UUID) -> Bool {
        guard let tasks, let task = tasks.task(id: taskId) else {
            pushActivity(.runningTool, "Task non trovata")
            return false
        }

        // Claude-supervised board cards must NOT spawn Swarm builders.
        if ClaudeSessionSupervisor.shared.isClaudeTask(task) || task.assigneeModel == "claude-code-cli" {
            beginActivityTurn("Avvia Claude · \(task.title)")
            isThinking = true
            bindClaudeSupervisor()
            let ok = ClaudeSessionSupervisor.shared.handleBoardAvvia(taskId: taskId)
            if ok {
                pushActivity(.waitingTerminal, "Avvia → stesso PTY Claude")
                livePhase = .waitingTerminal
                liveDetail = task.title
                navigate("terminals")
                messages.append(ChatMessage(
                    role: .assistant,
                    text: """
                    **Avvia** su task Claude → stesso terminale (layer Orchestratore).

                    · Nessun nuovo Swarm / builder
                    · Segui **Terminali** · continua a chattare qui per guidare Claude
                    """,
                    engine: .localRules
                ))
                finishActivityTurn(successDetail: "claude avvia")
            } else {
                pushActivity(.runningTool, "Avvio Claude fallito")
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "⚠️ Non riesco a riprendere Claude Code per **\(task.title)**. Usa «Apri Claude Code qui».",
                    engine: .localRules
                ))
                finishActivityTurn(successDetail: "claude avvia failed")
            }
            isThinking = false
            return ok
        }

        let gate = tasks.canStart(taskId)
        if !gate.ok {
            let reason = gate.reason ?? "dipendenze aperte"
            pushActivity(.runningTool, "Non avviabile: \(reason)")
            messages.append(ChatMessage(
                role: .assistant,
                text: "⚠️ Non posso avviare **\(task.title)**: \(reason)",
                engine: .localRules
            ))
            return false
        }

        agents?.goalModePreferred = goalModeEnabled
        beginActivityTurn("Avvio task · \(task.title)")
        isThinking = true

        let result = agents?.startTask(taskId, underOrchestratorControl: true)
            ?? .failed("Agent store non disponibile")

        switch result {
        case .failed(let reason):
            pushActivity(.runningTool, reason)
            messages.append(ChatMessage(
                role: .assistant,
                text: "⚠️ Avvio fallito per **\(task.title)**: \(reason)",
                engine: .localRules
            ))
            finishActivityTurn(successDetail: "Avvio fallito")
            return false

        case .alreadyRunning(let agentName):
            pushActivity(.waitingAgents, "Già in corso · \(agentName) — nessun nuovo terminale")
            messages.append(ChatMessage(
                role: .assistant,
                text: """
                **\(task.title)** è già in esecuzione.

                · Riuso sub-agent `\(agentName)` e lo stesso PTY
                · Non apro un altro terminale (evita di far rileggere tutto)
                · Segui il log in **QS Swarm** / activity sotto
                """,
                engine: .localRules
            ))

        case .resumed(let agentName):
            pushActivity(.waitingAgents, "Ripresa · \(agentName) (stesso PTY)")
            messages.append(ChatMessage(
                role: .assistant,
                text: """
                Riprendo **\(task.title)** sullo stesso sub-agent.

                · Agent: `\(agentName)` — stesso terminale
                · Istruzioni: continua senza riesplorare il repo
                · Split automatico se si blocca di nuovo\(goalModeEnabled ? " (GOAL MODE)" : "")
                """,
                engine: .localRules
            ))

        case .started(let agentName):
            pushActivity(.waitingAgents, "Nuovo sub-agent · \(agentName)")
            messages.append(ChatMessage(
                role: .assistant,
                text: """
                Avvio **\(task.title)** sotto il mio controllo.

                · Sub-agent: `\(agentName)`
                · Missione/control shell attiva (split se si blocca\(goalModeEnabled ? ", GOAL MODE" : ""))
                · Segui il log attività qui e in **QS Swarm**
                """,
                engine: .localRules
            ))
        }

        livePhase = .waitingAgents
        liveDetail = task.title
        isThinking = false
        navigate("swarm")
        return true
    }

    /// Swarm "Avvia builder": orchestrator approves the plan and dispatches builders.
    func approveMissionBuilders(builderCount: Int = 2) {
        guard agents?.mission != nil else {
            pushActivity(.runningTool, "Nessuna missione da approvare")
            messages.append(ChatMessage(
                role: .assistant,
                text: "Nessuna missione attiva. Avvia prima una missione o una task dalla board.",
                engine: .localRules
            ))
            return
        }
        beginActivityTurn("Approvo piano → builder")
        isThinking = true
        pushActivity(.waitingAgents, "Orchestratore lancia i builder della missione…")
        agents?.approveAndExecuteBuilders(builderCount: builderCount)
        messages.append(ChatMessage(
            role: .assistant,
            text: "Piano approvato — sto lanciando i **builder** come miei sub-agent. Resto in controllo (pipeline + auto-split se GOAL).",
            engine: .localRules
        ))
        pushActivity(.waitingAgents, "Builder in esecuzione sotto controllo orchestratore")
        livePhase = .waitingAgents
        liveDetail = L("Missione in esecuzione")
        isThinking = false
        navigate("swarm")
    }

    private func isGoalStopCommand(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["stop goal", "stop missione", "pausa goal", "ferma goal", "stop agents", "stop agent"]
            .contains { t == $0 || t.hasPrefix($0 + " ") }
    }

    private func shouldPursueAsGoal(_ text: String) -> Bool {
        if isGoalStopCommand(text) { return true }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tiny queries stay in normal chat even with toggle on.
        if t.count < 8 { return false }
        let lower = t.lowercased()
        let chatOnly = ["ciao", "help", "aiuto", "status", "chi sei", "token"]
        if chatOnly.contains(where: { lower == $0 }) { return false }
        return true
    }

    /// Launch preferred / resolved coding engine (CLI or QS API IDE).
    @discardableResult
    func launchCodingEngine(goal: String, workspace: String? = nil) -> CodingEngineLaunchResult {
        bindClaudeSupervisor()
        let ws = workspace ?? workspaces?.current?.path ?? ""
        // Lock git + tools to project before any status/follow-up (never $HOME).
        if !ws.isEmpty {
            let std = (ws as NSString).standardizingPath
            let home = (NSHomeDirectory() as NSString).standardizingPath
            if std != home {
                git?.setPath(std)
                if workspaces?.current?.path != std {
                    _ = workspaces?.open(path: std)
                }
            }
        }
        let result = CodingEngine.launch(
            goal: goal,
            workspace: ws,
            agents: agents,
            terminals: terminals,
            tasks: tasks,
            git: git,
            navigate: { [weak self] route in self?.navigate(route) }
        )
        if result.ok {
            lastClaudeCodeTerminalID = result.terminalID
            lastClaudeCodeTaskID = result.taskID
            if !ws.isEmpty { git?.setPath(ws) }
            // If engine returned without a board task (rare), open/create one like Claude.
            if result.taskID == nil {
                let linked = ensureLinkedQSTask(goal: goal, navigateToBoard: false)
                if let tid = linked?.id {
                    return CodingEngineLaunchResult(
                        ok: result.ok,
                        message: result.message + "\n\n" + L("QS Task collegata sulla board."),
                        engine: result.engine,
                        terminalID: result.terminalID,
                        taskID: tid
                    )
                }
            }
        }
        // Clarify: Claude CLI ignores Home model picker (Haiku/Opus API ids).
        if result.engine == .claudeCLI {
            let homeModel = ProviderPreferences.shared.model(for: .coordinator)
            let note = """
            \(result.message)

            _Nota: **Claude Code CLI** usa l’account Claude sul Mac (modello scelto da Claude Code), non «\(homeModel)» dalla Home. Per Haiku/Sonnet via API: Coding engine → **QS API**._
            """
            return CodingEngineLaunchResult(
                ok: result.ok,
                message: note,
                engine: result.engine,
                terminalID: result.terminalID,
                taskID: result.taskID
            )
        }
        return result
    }

    /// Legacy: force Claude CLI specifically.
    @discardableResult
    func launchClaudeCode(goal: String, workspace: String? = nil) -> CodingCLILauncher.LaunchResult {
        bindClaudeSupervisor()
        let ws = workspace ?? workspaces?.current?.path ?? ""
        let result = CodingCLILauncher.launchClaudeCode(
            goal: goal,
            workspace: ws,
            terminals: terminals,
            tasks: tasks,
            git: git,
            navigate: { [weak self] route in self?.navigate(route) }
        )
        if result.ok {
            lastClaudeCodeTerminalID = result.terminalID
            lastClaudeCodeTaskID = result.taskID
        }
        return result
    }

    /// Chat queries that must stay with the orchestrator (not forwarded into coding PTY).
    private func isOrchestratorMetaQuery(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.count < 4 { return true }
        let meta = [
            "chi sei", "help", "aiuto", "status", "cosa sta girando", "lista progetti",
            "changelog", "quale ai", "token", "stop goal", "stop agent",
        ]
        return meta.contains { lower == $0 || lower.hasPrefix($0 + " ") }
            || isIdentityQuery(lower)
            || isConversationalQuery(lower)
    }

    /// Quick-action / chip: coding engine with last user goal or a continue prompt.
    func launchClaudeCodeQuickAction() {
        let fromUser = messages.last(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let g: String = {
            if !fromUser.isEmpty { return fromUser }
            if !fromDraft.isEmpty { return fromDraft }
            return "Continua sul workspace aperto: analizza UI/home, piano design, poi edita i file tracked (root/src)."
        }()
        draft = ""
        if codingEngine == .swarm { codingEngine = .auto }
        isThinking = true
        beginActivityTurn("Coding engine")
        pushActivity(.goal, "Apri coding engine qui…")
        guard let ws = workspaces?.current?.path else {
            let reply = ChatMessage(
                role: .assistant,
                text: "Seleziona un workspace (es. zackgame) prima di aprire il coding engine.",
                engine: .localRules
            )
            messages.append(reply)
            finishActivityTurn(successDetail: "no workspace")
            isThinking = false
            return
        }
        let result = launchCodingEngine(goal: g, workspace: ws)
        messages.append(ChatMessage(role: .assistant, text: result.message, engine: .localRules))
        lastReplyEngine = .localRules
        isThinking = false
        if result.ok {
            livePhase = .waitingTerminal
            liveDetail = result.engine.shortLabel
            finishActivityTurn(successDetail: "coding engine")
        } else {
            finishActivityTurn(successDetail: "coding engine failed")
        }
    }

    /// Long “do this in the project” messages — run Swarm even if GOAL toggle is off.
    private func looksLikeAutonomousWork(_ text: String) -> Bool {
        if isGoalStopCommand(text) { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 36 { return false }
        let lower = t.lowercased()
        // Don't steal pure git/chat intents
        if isStandaloneGitIntent(text, needles: ["git status", "git log", "git diff", "git push", "git pull"]) {
            return false
        }
        let verbs = [
            "migliora", "modifica", "cambia", "implementa", "aggiungi", "fix", "sistema",
            "trova tu", "rendi ", "aggiorna il", "aggiorna la", "patch", "rifattor",
            "nel codice", "sorgente", "pulsante", "button", "layout",
        ]
        return verbs.contains { lower.contains($0) }
    }

    /// B3: push orchestrator session digest into ProjectMemoryStore for current workspace.
    func flushSessionToProjectMemory(force: Bool = false) {
        guard let path = workspaces?.current?.path else { return }
        let digest = memory.sessionDigest(limit: 16)
        guard !digest.isEmpty else { return }
        if !force, memory.entries.count < 4 { return }
        _ = projectMemory?.appendNote(
            path: path,
            text: "Sessione orchestratore: \(digest)",
            kind: .session,
            evidence: ["source: orchestrator", "entries: \(memory.entries.count)"]
        )
        DecisionLogStore.shared.append(
            workspace: path,
            kind: .session,
            text: "Session memory flush (\(memory.entries.count) turns)",
            meta: ["source": "orchestrator"]
        )
        AppLogger.info("B3 session → project memory @ \(path)")
    }

    private var lastMemoryFlushCount = 0
    private func maybeFlushSessionMemory() {
        // Every ~8 new memory entries
        let n = memory.entries.count
        if n - lastMemoryFlushCount >= 8 {
            lastMemoryFlushCount = n
            flushSessionToProjectMemory()
        }
    }

    /// Invia testo riconosciuto dalla voce all'orchestratore.
    func sendVoiceToOrchestrator(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = t
        send(isVoice: true)
    }

    /// Invia testo riconosciuto come comando in un terminale PTY specifico.
    @discardableResult
    func sendVoiceToTerminal(_ text: String, sessionID: UUID) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let session = terminals?.sessions.first(where: { $0.id == sessionID }) else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "Non trovo quel terminale. Aprine uno e riprova.",
                engine: .localRules
            ))
            return false
        }
        terminals?.select(sessionID)

        messages.append(ChatMessage(
            role: .user,
            text: "🎤 → \(session.title): `\(t)`",
            engine: .voiceNote,
            isVoice: true
        ))

        let decision = terminals?.sendCommandLine(t, to: sessionID, source: "voice") ?? .allow
        switch decision {
        case .block(let msg, let rule):
            messages.append(ChatMessage(
                role: .assistant,
                text: "🛡️ **Guardrail** ha bloccato il comando vocale.\n\n\(msg)\n\nRegola: \(rule.name)",
                engine: .localRules
            ))
            return false
        case .requireConfirm(let msg, let rule):
            messages.append(ChatMessage(
                role: .assistant,
                text: "🛡️ Conferma richiesta prima di eseguire su **\(session.title)**.\n\n\(msg)\n\nConferma dal dialog o banner in alto.\nRegola: \(rule.name)",
                engine: .localRules
            ))
            return false
        case .requireDualConfirm(let msg, let rule):
            messages.append(ChatMessage(
                role: .assistant,
                text: "👥 **Two-person rule** su **\(session.title)**.\n\n\(msg)\n\nServe 1ª approvazione + 2ª persona (\(safety?.secondApproverName ?? "second approver")) con PIN.\nRegola: \(rule.name)",
                engine: .localRules
            ))
            return false
        case .allowWithWarning(let msg, _):
            messages.append(ChatMessage(
                role: .assistant,
                text: "⚠️ Avviso sicurezza (eseguito comunque):\n\(msg)\n\nInviato a **\(session.title)**.",
                engine: .voiceNote,
                isVoice: true
            ))
        case .allow:
            messages.append(ChatMessage(
                role: .assistant,
                text: "Inviato al terminale **\(session.title)** (`\(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))`).",
                engine: .voiceNote,
                isVoice: true
            ))
        }
        navigate("terminals")
        return true
    }

    // MARK: - Intent handling

    private func handle(_ text: String, streamMessageId: UUID? = nil) async -> ChatMessage {
        let lower = text.lowercased()
        var actions: [OrchestratorAction] = []

        tools.dryRun = dryRun.enabled

        // Dry-run toggle
        if matches(lower, any: ["dry-run on", "dry run on", "attiva dry-run", "modalità dry-run"]) {
            dryRun.setEnabled(true)
            tools.dryRun = true
            return ChatMessage(role: .assistant, text: "🧪 Dry-run **ON** — descrivo le azioni senza eseguirle.", engine: .localRules)
        }
        if matches(lower, any: ["dry-run off", "dry run off", "disattiva dry-run"]) {
            dryRun.setEnabled(false)
            tools.dryRun = false
            return ChatMessage(role: .assistant, text: "Dry-run **OFF** — le azioni si eseguono di nuovo.", engine: .localRules)
        }

        // ── Project bootstrap (fundamental work flow) ─────────────────
        // "apri progetto X, terminale, lista task, avvia grok/agent"
        if isProjectBootstrapIntent(lower) {
            return handleProjectBootstrap(text: text, lower: lower)
        }

        // Standalone: crea piano / lista task del progetto
        if matches(lower, any: [
            "crea piano", "piano task", "lista task", "task del progetto",
            "crea task list", "setup task", "prepara piano", "backlog progetto",
            "crea le task", "genera task"
        ]) {
            let path = extractPath(from: text) ?? extractProjectPath(from: text) ?? workspaces?.current?.path
            let result = tools.execute(.createPlan(path: path))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Conversational / identity questions → LLM first (never the local command list).
        // Bug fix: bare "?" used to match help for ANY question ("chi sei?").
        if isConversationalQuery(lower) {
            if let llmResult = await tryLLM(userText: text, streamMessageId: streamMessageId) {
                let (clean, acts) = parseActionTags(llmResult.text)
                return ChatMessage(
                    role: .assistant,
                    text: clean.isEmpty ? llmResult.text : clean,
                    actions: acts,
                    engine: .llm(provider: llmResult.provider, model: llmResult.model)
                )
            }
            if isIdentityQuery(lower) {
                return identityLocalReply()
            }
        }

        // Knowledge search
        if matches(lower, any: ["cosa so di", "cerca knowledge", "knowledge ", "cerca nel codice", "search knowledge", "indice knowledge"]) {
            var q = text
            for p in ["cosa so di ", "cerca knowledge ", "knowledge ", "cerca nel codice ", "search knowledge ", "indice knowledge "] {
                if let r = q.range(of: p, options: .caseInsensitive) {
                    q = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if q.isEmpty { q = text }
            let result = tools.execute(.searchKnowledge(query: q))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Safety / guardrails questions
        if matches(lower, any: ["guardrail", "sicurezza", "safety", "policy", "regole sicurezza", "non cancellare", "ambiente live", "production"]) {
            let env = safety?.environment.displayName ?? "n/d"
            let on = safety?.enabled == true ? "ON" : "OFF"
            let count = safety?.rules.filter(\.enabled).count ?? 0
            return ChatMessage(
                role: .assistant,
                text: """
                **Sicurezza QS Agents**

                Ambiente: **\(env)** · Guardrail: **\(on)** · \(count) regole attive

                Su **Production/Live** blocco di default:
                • DROP / TRUNCATE database
                • `migrate:fresh` / `db:wipe`
                • `rm -rf` su path di sistema
                • force-push su main/master
                • terraform/helm destroy

                In **Development** le operazioni distruttive chiedono **conferma umana**.

                Apri **Sicurezza** (ingranaggio / sidebar) per cambiare ambiente, regole e audit log.
                Chiedi: `mostra regole sicurezza` oppure cambia con le impostazioni.
                """,
                engine: .localRules
            )
        }

        if matches(lower, any: ["mostra regole sicurezza", "lista guardrail", "regole attive"]) {
            let env = safety?.environment ?? .development
            let role = safety?.defaultAgentRole ?? .general
            let list = (safety?.rules.filter { $0.enabled && $0.applies(to: env, role: role) }.prefix(20).map {
                "• [\($0.severity.rawValue)] **\($0.name)** — \($0.description)"
            } ?? []).joined(separator: "\n")
            return ChatMessage(
                role: .assistant,
                text: "**Guardrail attivi** (ambiente \(env.shortLabel)):\n\n\(list.isEmpty ? "_Nessuna_" : list)",
                engine: .localRules
            )
        }

        // Which AI? Prefer LLM self-intro; offline fallback lists configured model.
        if isIdentityQuery(lower) || matches(lower, any: ["quale ai", "quale a.i", "which ai", "che modello", "che ai usi", "quale llm", "che motore", "ai usi"]) {
            if let llmResult = await tryLLM(userText: text, streamMessageId: streamMessageId) {
                let (clean, acts) = parseActionTags(llmResult.text)
                return ChatMessage(
                    role: .assistant,
                    text: clean.isEmpty ? llmResult.text : clean,
                    actions: acts,
                    engine: .llm(provider: llmResult.provider, model: llmResult.model)
                )
            }
            return identityLocalReply()
        }

        // System status (avoid bare tokens that false-positive on normal questions)
        if matches(lower, any: ["cosa sta girando", "stato sistema", "system status", "top processi", "uso cpu", "uso memoria", "porte in ascolto", "listening ports"]) {
            let result = tools.execute(.getSystemStatus)
            return ChatMessage(
                role: .assistant,
                text: "Ecco lo stato live del Mac:\n\n```\n\(result.message)\n```",
                engine: .localRules
            )
        }

        // List projects → real tool
        if matches(lower, any: ["progetti", "lista progetti", "dove sono", "directory", "cartelle", "mostra progetti"]) {
            let result = tools.execute(.listProjects)
            return ChatMessage(role: .assistant, text: result.message + "\n\nDimmi: `apri workspace <path>` o `apri terminale in <nome>`.", engine: .localRules)
        }

        // Create task (local — do not wait for LLM ACTION; long multi-line prompts supported)
        if isCreateTaskIntent(lower) {
            let spec = parseCreateTaskSpec(from: text)
            let result = tools.execute(.createTask(
                title: spec.title,
                subtitle: spec.subtitle,
                priority: spec.priority,
                workspacePath: workspaces?.current?.path,
                model: spec.model
            ))
            var msg = result.message
            // Optional: create + start in one shot
            if result.ok, wantsStartTask(lower) {
                let start = tools.execute(.startBoardTask(titleOrId: spec.title))
                msg += "\n\n" + start.message
            } else if result.ok {
                msg += "\n\n_Per avviare: scrivi «avvia task \(spec.title)» o premi Avvia sulla board._"
            }
            return ChatMessage(role: .assistant, text: msg, engine: .localRules)
        }

        // Start existing board task (builder LLM loop)
        if isStartTaskIntent(lower) {
            let ref = parseStartTaskRef(from: text) ?? ""
            let result = tools.execute(.startBoardTask(titleOrId: ref.isEmpty ? " " : ref))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Complete / delete task
        if matches(lower, any: ["completa task", "completa la task", "segna completata", "task completata", "complete task", "mark done"]) {
            var title = text
            for p in ["completa task ", "completa la task ", "segna completata ", "task completata ", "complete task ", "mark done "] {
                if let r = title.range(of: p, options: .caseInsensitive) {
                    title = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if title.isEmpty || title.lowercased() == lower {
                // complete selected or latest in progress
                if let t = tasks?.tasks.first(where: { $0.isSelected })
                    ?? tasks?.tasks.first(where: { $0.column == .inProgress })
                    ?? tasks?.tasks.first {
                    let result = tools.execute(.completeTask(titleOrId: t.id.uuidString))
                    return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
                }
            }
            let result = tools.execute(.completeTask(titleOrId: title))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        if matches(lower, any: ["elimina task", "cancella task", "delete task", "rimuovi task"]) {
            var title = text
            for p in ["elimina task ", "cancella task ", "delete task ", "rimuovi task "] {
                if let r = title.range(of: p, options: .caseInsensitive) {
                    title = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if title.isEmpty || title.lowercased() == lower {
                if let t = tasks?.tasks.first(where: { $0.isSelected }) {
                    let result = tools.execute(.deleteTask(titleOrId: t.id.uuidString))
                    return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
                }
                return ChatMessage(role: .assistant, text: "Specifica la task: `elimina task <titolo>` o selezionala prima.", engine: .localRules)
            }
            let result = tools.execute(.deleteTask(titleOrId: title))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // B4: project memory recall
        if matches(lower, any: [
            "cosa abbiamo fatto", "cosa abbiamo fatto su", "ricorda progetto",
            "memoria progetto", "project memory", "ultima volta", "ultima volta su",
            "history progetto", "storia progetto", "cosa è successo su",
        ]) {
            let path = extractPath(from: text)
            let query = extractProjectQuery(from: text)
            let result = tools.execute(.recallProject(path: path ?? workspaces?.current?.path, query: query))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Git: changelog / log / status / diff / commit / push
        // Git intents: only when the message *is* a git command — not when a GOAL mentions «verifica con git status».
        if isStandaloneGitIntent(text, needles: ["changelog", "git log", "commit history", "storia commit", "mostra log git", "git changelog"]) {
            let path = safeGitPath(from: text)
            let result = tools.execute(.gitLog(path: path, limit: 25))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        if isStandaloneGitIntent(text, needles: ["git status", "stato git", "working tree", "file modificati"])
            || (text.count < 64 && matches(lower, any: ["cosa è cambiato"])) {
            let path = safeGitPath(from: text)
            let result = tools.execute(.gitStatus(path: path))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        if isStandaloneGitIntent(text, needles: ["git diff", "mostra diff", "diff git"]) {
            let path = safeGitPath(from: text)
            let result = tools.execute(.gitDiff(path: path))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        if isStandaloneGitIntent(text, needles: ["git push", "push su github", "push github", "invia su github", "push origin"]) {
            let path = safeGitPath(from: text)
            let result = tools.execute(.gitPush(path: path))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        if isStandaloneGitIntent(text, needles: ["git pull", "pull origin", "aggiorna repo"]) {
            let path = safeGitPath(from: text)
            let result = tools.execute(.gitPull(path: path))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // commit "message" / commit e push "message"
        if matches(lower, any: ["git commit", "commit e push", "commit + push", "fai commit", "crea commit", "committa"]) {
            let push = matches(lower, any: ["push", "github"])
            var message = extractQuoted(from: text)
            if message == nil {
                for p in ["commit e push ", "commit + push ", "git commit ", "fai commit ", "crea commit ", "committa "] {
                    if let r = text.range(of: p, options: .caseInsensitive) {
                        let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rest.isEmpty { message = rest; break }
                    }
                }
            }
            guard let msg = message, !msg.isEmpty else {
                return ChatMessage(
                    role: .assistant,
                    text: "Specifica il messaggio: `commit \"fix: …\"` oppure `commit e push \"feat: …\"`.",
                    engine: .localRules
                )
            }
            let path = extractPath(from: text) ?? workspaces?.current?.path
            let result = tools.execute(.gitCommit(message: msg, path: path, push: push))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Open workspace (simple — multi-step goes to bootstrap above)
        if matches(lower, any: ["apri workspace", "apri progetto", "apri cartella", "open workspace", "aprimi", "passa a ", "switch a ", "vai al progetto"]) {
            let path = extractPath(from: text) ?? extractProjectPath(from: text)
                ?? workspaces?.recent.first?.path
                ?? directories?.resolveUserPath("qsagents")
            if let path {
                var msg = tools.execute(.openWorkspace(path: path)).message
                if matches(lower, any: ["aprimi", "terminale", "e apri", "e lancia term"]) {
                    let t = tools.execute(.openTerminal(path: path, role: nil))
                    msg += "\n" + t.message
                }
                return ChatMessage(role: .assistant, text: msg, engine: .localRules)
            }
            return ChatMessage(
                role: .assistant,
                text: "Specifica un path o nome progetto (es. `apri progetto qsagents`).\nO usa il menu **Workspace** in alto per cambiare.",
                engine: .localRules
            )
        }

        // Terminals status
        if matches(lower, any: ["terminali aperti", "quali terminali", "lista terminali", "sessioni"]) {
            let snap = terminals?.snapshotForOrchestrator() ?? "n/d"
            return ChatMessage(
                role: .assistant,
                text: "**Terminali attivi**\n```\n\(snap)\n```",
                engine: .localRules
            )
        }

        // Open multiple terminals
        if let count = extractTerminalCount(from: lower),
           let path = extractPath(from: text) ?? extractProjectPath(from: text) ?? workspaces?.current?.path {
            var msgs: [String] = []
            for _ in 1...count {
                let r = tools.execute(.openTerminal(path: path, role: nil))
                msgs.append(r.message)
            }
            return ChatMessage(
                role: .assistant,
                text: "Apro **\(count) terminali** in `\(path)`.\n" + msgs.joined(separator: "\n"),
                engine: .localRules
            )
        }

        // Multi-step: apri terminale … e lancia/esegui …
        if matches(lower, any: ["apri terminale", "open terminal", "nuovo terminale", "apri shell", "apri pty", "terminal in", "terminale in", "terminale su", "aprimi"])
            || (matches(lower, any: ["apri"]) && matches(lower, any: ["e lancia", "e esegui", "e run", "poi "])) {
            let path = extractPath(from: text)
                ?? extractProjectPath(from: text)
                ?? workspaces?.current?.path
                ?? NSHomeDirectory()
            let openRes = tools.execute(.openTerminal(path: path, role: nil))
            directories?.rememberRecent(path: path)

            // Optional chained command
            var chainMsg = openRes.message
            if let chained = extractChainedCommand(from: text) {
                let runRes = tools.execute(.runCommand(command: chained, path: path, role: nil))
                chainMsg += "\n\nPoi: \(runRes.message)"
            } else if matches(lower, any: ["e lancia", "e esegui", "e run", "poi esegui", "poi lancia"]) {
                // try extract after "e lancia " / "e esegui "
                if let cmd = extractAfterVerb(text, verbs: ["e lancia ", "e esegui ", "e run ", "poi esegui ", "poi lancia ", "and run "]) {
                    let runRes = tools.execute(.runCommand(command: cmd, path: path, role: nil))
                    chainMsg += "\n\nPoi: \(runRes.message)"
                }
            }

            return ChatMessage(
                role: .assistant,
                text: chainMsg + "\n\nShell: \(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")",
                engine: .localRules
            )
        }

        // Explicit coding engine in terminal (Claude / Grok / QS API)
        if matches(lower, any: [
            "apri claude code", "avvia claude code", "claude code qui",
            "lancia claude", "apri claude nel", "usa claude code",
            "apri coding engine", "avvia coding engine", "coding engine qui",
            "apri qs api", "avvia qs api", "ide in terminale",
            "apri grok", "avvia grok", "grok cli",
        ]) {
            var goal = text
            for p in [
                "apri claude code ", "avvia claude code ", "claude code qui ",
                "lancia claude ", "usa claude code ",
                "apri coding engine ", "avvia coding engine ", "coding engine qui ",
                "apri qs api ", "avvia qs api ", "ide in terminale ",
                "apri grok ", "avvia grok ", "grok cli ",
            ] {
                if let r = goal.range(of: p, options: .caseInsensitive) {
                    goal = String(goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if goal.isEmpty || goal.lowercased() == lower {
                goal = messages.last(where: { $0.role == .user })?.text
                    ?? "Continua sul workspace: piano design, poi edit tracked root/src."
            }
            guard let ws = workspaces?.current?.path ?? extractProjectPath(from: text) else {
                return ChatMessage(
                    role: .assistant,
                    text: "Apri un workspace (es. zackgame) prima di lanciare il coding engine.",
                    engine: .localRules
                )
            }
            if lower.contains("grok") { codingEngine = .grokCLI }
            else if lower.contains("qs api") || lower.contains("ide in terminale") { codingEngine = .qsAPI }
            else if lower.contains("claude") { codingEngine = .claudeCLI }
            else if codingEngine == .swarm { codingEngine = .auto }
            let result = launchCodingEngine(goal: goal, workspace: ws)
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Spawn agent LLM
        if matches(lower, any: ["avvia agent", "spawn agent", "lancia agent", "avvia un agent", "start agent"]) {
            var goal = text
            for p in ["avvia agent ", "spawn agent ", "lancia agent ", "avvia un agent ", "start agent "] {
                if let r = goal.range(of: p, options: .caseInsensitive) {
                    goal = String(goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if goal.isEmpty || goal.lowercased() == lower { goal = "Ispeziona il workspace e proponi i prossimi passi" }
            let result = tools.execute(.spawnAgent(goal: goal, role: .builder))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // GOAL MODE explicit (even if toggle off)
        if matches(lower, any: ["goal mode ", "avvia goal ", "persegui ", "raggiungi goal "]) {
            var goal = text
            for p in ["goal mode ", "avvia goal ", "persegui ", "raggiungi goal "] {
                if let r = goal.range(of: p, options: .caseInsensitive) {
                    goal = String(goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if !goal.isEmpty {
                goalModeEnabled = true
                if codingEngine != .swarm, let ws = workspaces?.current?.path {
                    let result = launchCodingEngine(goal: goal, workspace: ws)
                    return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
                }
                agents?.goalModePreferred = true
                let result = tools.execute(.startMission(goal: goal, builders: 2))
                return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
            }
        }

        // Swarm mission (explicit — always Swarm, never Claude Code)
        if matches(lower, any: ["avvia missione", "start mission", "swarm ", "lancia swarm", "missione "]) {
            var goal = text
            for p in ["avvia missione ", "start mission ", "lancia swarm ", "missione ", "swarm "] {
                if let r = goal.range(of: p, options: .caseInsensitive) {
                    goal = String(goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if goal.isEmpty { goal = "Ispeziona repo e proponi piano" }
            let result = tools.execute(.startMission(goal: goal, builders: 2))
            return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
        }

        // Run command via tool runner (safety inside TerminalManager)
        if let (cmd, path) = extractRunCommand(from: text) {
            let cwd = path ?? extractProjectPath(from: text) ?? workspaces?.current?.path
            let result = tools.execute(.runCommand(command: cmd, path: cwd, role: nil))
            return ChatMessage(
                role: .assistant,
                text: result.message,
                engine: .localRules
            )
        }

        // Memoria
        if matches(lower, any: ["memoria sessione", "cosa ricordi", "cronologia chat", "mostra memoria"]) {
            return ChatMessage(
                role: .assistant,
                text: "**Memoria sessione**\n\(memory.promptBlock())",
                engine: .localRules
            )
        }

        // cd / vai in
        if matches(lower, any: ["vai in", "cd ", "cambia cartella", "spostati"]) {
            if let path = extractPath(from: text) ?? extractProjectPath(from: text) {
                if let selected = terminals?.selected, selected.isAlive {
                    selected.changeDirectory(to: path)
                    directories?.rememberRecent(path: path)
                    return ChatMessage(
                        role: .assistant,
                        text: "Ok, `cd` sul terminale selezionato → `\(path)`.",
                        engine: .localRules
                    )
                } else {
                    actions.append(.openTerminal(path: path, title: nil))
                    return ChatMessage(
                        role: .assistant,
                        text: "Nessun terminale attivo: ne apro uno in `\(path)`.",
                        actions: actions,
                        engine: .localRules
                    )
                }
            }
        }

        // Integrations
        if matches(lower, any: ["integrazioni", "api key", "configura claude", "configura grok", "modelli"]) {
            actions.append(.openIntegrations)
            return ChatMessage(
                role: .assistant,
                text: "Apro le **Integrazioni** per i provider AI (chiavi in Keychain).",
                actions: actions,
                engine: .localRules
            )
        }

        // Help only on explicit help requests — never on bare "?" (that broke "chi sei?").
        if isExplicitHelpQuery(lower) {
            return ChatMessage(role: .assistant, text: helpText, engine: .localRules)
        }

        // Prefer LLM for anything not matched as a concrete tool action
        if let llmResult = await tryLLM(userText: text, streamMessageId: streamMessageId) {
            let (clean, acts) = parseActionTags(llmResult.text)
            // If model forgot ACTION tags but asked for a clear shell run, still execute
            var acts2 = acts
            if acts2.isEmpty, let (cmd, path) = extractRunCommand(from: text) {
                acts2.append(.runCommand(command: cmd, path: path ?? workspaces?.current?.path))
            }
            // Safety net: user clearly wanted a board task but model forgot ACTION:CREATE_TASK
            if acts2.isEmpty, isCreateTaskIntent(lower) {
                let spec = parseCreateTaskSpec(from: text)
                acts2.append(.createTask(title: spec.title, subtitle: spec.subtitle))
                if wantsStartTask(lower) {
                    acts2.append(.startBoardTask(titleOrId: spec.title))
                }
            } else if acts2.isEmpty, isStartTaskIntent(lower) {
                let ref = parseStartTaskRef(from: text) ?? tasks?.tasks.first(where: { $0.column == .todo })?.title ?? ""
                if !ref.isEmpty {
                    acts2.append(.startBoardTask(titleOrId: ref))
                }
            }
            // New goal/mission via LLM without create_task → auto-link QS Task (Kimi/Claude parity).
            let hasTaskAction = acts2.contains {
                if case .createTask = $0 { return true }
                if case .startMission = $0 { return true }
                if case .startBoardTask = $0 { return true }
                return false
            }
            if !hasTaskAction, looksLikeAutonomousWork(text) || matches(lower, any: ["missione", "goal mode", "avvia missione"]) {
                _ = ensureLinkedQSTask(goal: text, navigateToBoard: true)
            }
            let body = clean.isEmpty ? llmResult.text : clean
            let tail = acts2.isEmpty
                ? ""
                : "\n\n_Azioni: \(acts2.map(Self.describeAction).joined(separator: " · "))_"
            return ChatMessage(
                role: .assistant,
                text: body + tail,
                actions: acts2,
                engine: .llm(provider: llmResult.provider, model: llmResult.model)
            )
        }

        // LLM down — still honor create/start task intents
        if isCreateTaskIntent(lower) {
            let spec = parseCreateTaskSpec(from: text)
            let result = tools.execute(.createTask(
                title: spec.title,
                subtitle: spec.subtitle,
                priority: spec.priority,
                workspacePath: workspaces?.current?.path,
                model: spec.model
            ))
            var msg = result.message
            if result.ok, wantsStartTask(lower) {
                msg += "\n\n" + tools.execute(.startBoardTask(titleOrId: spec.title)).message
            }
            let errNote = lastLLMError.map { "\n\n_(LLM non disponibile: \($0))_" } ?? ""
            return ChatMessage(role: .assistant, text: msg + errNote, engine: .localRules)
        }
        if isStartTaskIntent(lower) {
            let ref = parseStartTaskRef(from: text) ?? ""
            let result = tools.execute(.startBoardTask(titleOrId: ref.isEmpty ? " " : ref))
            let errNote = lastLLMError.map { "\n\n_(LLM non disponibile: \($0))_" } ?? ""
            return ChatMessage(role: .assistant, text: result.message + errNote, engine: .localRules)
        }

        // LLM failed — still try shell-ish local execution before giving up
        if let (cmd, path) = extractRunCommand(from: text) {
            let cwd = path ?? extractProjectPath(from: text) ?? workspaces?.current?.path
            let result = tools.execute(.runCommand(command: cmd, path: cwd, role: nil))
            let errNote = lastLLMError.map { "\n\n_(LLM non disponibile: \($0))_" } ?? ""
            return ChatMessage(
                role: .assistant,
                text: result.message + errNote,
                engine: .localRules
            )
        }

        // Fallback smart suggestions
        if let path = extractProjectPath(from: text) ?? extractPath(from: text) {
            actions.append(.openTerminal(path: path, title: nil))
            return ChatMessage(
                role: .assistant,
                text: "Ho trovato il path `\(path)`. Apro un terminale lì. Per eseguire un comando: `esegui git status` o `lancia npm test in \(URL(fileURLWithPath: path).lastPathComponent)`.",
                actions: actions,
                engine: .localRules
            )
        }

        let llmHint: String
        if let err = lastLLMError {
            llmHint = """
            **LLM fallito:** \(err)

            Controlla **Integrazioni** (API key), il modello selezionato, o prova un altro provider dal selettore live (es. OpenAI / SpaceX AI).
            """
        } else if let p = selectedProviderKind, LLMClient.shared.hasKey(p) {
            llmHint = "Avevo **\(p.displayName)** configurato ma la chiamata non è andata a buon fine. Controlla key/modello o cambia provider."
        } else if LLMClient.shared.preferredProvider() != nil {
            llmHint = "C'è una API key ma non è stata usata. Riprova o scegli il modello dal selettore live."
        } else {
            llmHint = "Nessuna API key: solo **regole locali**. Aggiungi un provider in Integrazioni."
        }

        return ChatMessage(
            role: .assistant,
            text: """
            Non ho matchato un tool locale.

            \(llmHint)

            AI: \(configuredAISummary)
            Contesto: \(terminals?.activeCount ?? 0) terminali · \(directories?.projects.count ?? 0) progetti · CPU ≈ \(Int(probe?.snapshot.cpuPercent ?? 0))%

            **Per eseguire davvero un comando** (anche senza LLM):
            • `esegui git status`
            • `lancia npm test in qsagents`
            • `apri terminale in ~/qsagents e lancia git status`
            • oppure seleziona un PTY e: `manda al terminale ls -la`

            Altri: `git status` · `cosa sta girando?` · `help`
            """,
            engine: .localRules
        )
    }

    private static func describeAction(_ a: OrchestratorAction) -> String {
        switch a {
        case .openTerminal(let path, _): return "open \(path)"
        case .runCommand(let cmd, let path): return "run `\(cmd)`\(path.map { " @ \($0)" } ?? "")"
        case .focusTerminal: return "focus terminal"
        case .revealPath(let p): return "reveal \(p)"
        case .openIntegrations: return "integrations"
        case .switchView(let n): return "view \(n)"
        case .spawnAgent(let g): return "spawn \(g.prefix(40))"
        case .startMission(let g): return "mission \(g.prefix(40))"
        case .createTask(let t, _): return "create_task \(t.prefix(40))"
        case .startBoardTask(let t): return "start_task \(t.prefix(40))"
        }
    }

    /// True for chat-like questions that must never be hijacked by the local help list.
    private func isConversationalQuery(_ lower: String) -> Bool {
        if isIdentityQuery(lower) { return true }
        let phrases = [
            "come stai", "come va", "spiegami", "raccontami", "cosa pensi",
            "perché", "perche", "perchè", "dimmi di te", "presentati",
            "hello", "hi ", "hey ", "buongiorno", "buonasera", "grazie",
            "thanks", "what are you", "what model", "which model",
            "puoi aiutarmi", "mi aiuti a capire", "in poche parole"
        ]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        // Free-form questions: trailing ? but not explicit tool help
        if lower.contains("?") && !isExplicitHelpQuery(lower) && !isClearToolCommand(lower) {
            return true
        }
        return false
    }

    private func isIdentityQuery(_ lower: String) -> Bool {
        matches(lower, any: [
            "chi sei", "chi e'", "chi è", "chi e ",
            "who are you", "who r u", "what are you",
            "presentati", "come ti chiami", "che modello sei",
            "che modello usi", "che ai sei", "sei grok", "sei claude",
            "sei gpt", "sei un modello", "your name", "your model"
        ])
    }

    private func isExplicitHelpQuery(_ lower: String) -> Bool {
        // Exact-ish help only — never match bare "?"
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!.,"))
        if ["help", "aiuto", "comandi", "commands", "?"].contains(trimmed) { return true }
        return matches(lower, any: [
            "lista comandi", "mostra comandi", "quali comandi",
            "mostra help", "help comandi", "aiuto comandi",
            "cosa sai fare", "cosa puoi fare", "che comandi"
        ])
    }

    private func isClearToolCommand(_ lower: String) -> Bool {
        matches(lower, any: [
            "apri terminale", "open terminal", "git status", "git push", "git pull",
            "git commit", "changelog", "crea task", "elimina task", "avvia agent",
            "apri workspace", "esegui ", "lancia ", "run "
        ])
    }

    private func identityLocalReply() -> ChatMessage {
        let summary = configuredAISummary
        let text = """
        Sono l'**Orchestratore QS Agents** — il copilota locale dell'app.

        **Modello / provider attivo:** \(summary)

        Con una API key rispondo tramite quel modello (badge sulla risposta: provider · model).
        Senza key, oppure se la chiamata fallisce, uso regole locali per tool (terminali, git, task).

        Chiedimi pure in linguaggio naturale — es. «apri terminale in qsagents» o «spiegami questo errore».
        """
        return ChatMessage(role: .assistant, text: text, engine: .localRules)
    }

    private func apply(_ actions: [OrchestratorAction]) async {
        for action in actions {
            switch action {
            case .openTerminal(let path, let title):
                pushActivity(.runningTool, "Apro terminale · \(shortPath(path))")
                _ = terminals?.openTerminal(at: path, title: title)
                directories?.rememberRecent(path: path)
                navigate("terminals")
            case .runCommand(let command, let path):
                // Prefer typed tool runner (safety + open workspace + message path)
                let resolved = path.map { ($0 as NSString).expandingTildeInPath }
                pushActivity(.waitingTerminal, "Invio a PTY: `\(String(command.prefix(72)))`")
                let r = tools.execute(.runCommand(command: command, path: resolved, role: nil))
                if !r.ok {
                    AppLogger.warn("Orchestrator run failed: \(r.message)")
                    pushActivity(.runningTool, "Comando fallito: \(String(r.message.prefix(80)))")
                    messages.append(ChatMessage(
                        role: .assistant,
                        text: "⚠️ Esecuzione comando: \(r.message)",
                        engine: .localRules
                    ))
                } else {
                    pushActivity(.waitingTerminal, "Comando inviato — output nel pannello Terminali")
                }
            case .focusTerminal(let id):
                pushActivity(.runningTool, "Focus terminale")
                terminals?.select(id)
                navigate("terminals")
            case .revealPath(let path):
                pushActivity(.runningTool, "Reveal \(shortPath(path))")
                directories?.revealInFinder(path)
            case .openIntegrations:
                pushActivity(.runningTool, "Apro Integrazioni")
                navigate("integrations", force: true)
            case .switchView(let name):
                pushActivity(.runningTool, "Vista → \(name)")
                navigate(name, force: true)
            case .spawnAgent(let goal):
                pushActivity(.waitingAgents, "Avvio agent: \(String(goal.prefix(60)))")
                _ = tools.execute(.spawnAgent(goal: goal, role: .builder))
            case .startMission(let goal):
                pushActivity(.goal, "Missione Swarm: \(String(goal.prefix(60)))")
                if let p = selectedProviderKind ?? LLMClient.shared.preferredProvider()
                    ?? ProviderPreferences.shared.anyKeyedProvider() {
                    let m = selectedModel?.isEmpty == false ? selectedModel! : ProviderPreferences.shared.model(for: .coordinator)
                    ProviderPreferences.shared.syncSwarmFromLive(provider: p, model: m)
                }
                agents?.goalModePreferred = true
                // startMission seeds the board; only ensure if seed somehow skipped.
                let r = tools.execute(.startMission(goal: goal, builders: 2))
                if agents?.mission?.taskIds.isEmpty != false {
                    _ = ensureLinkedQSTask(goal: goal, navigateToBoard: true)
                } else {
                    navigate("tasks", force: true)
                }
                navigate("swarm")
                messages.append(ChatMessage(
                    role: .assistant,
                    text: r.ok ? r.message : "⚠️ \(r.message)",
                    engine: .localRules
                ))
            case .createTask(let title, let subtitle):
                pushActivity(.runningTool, "Creo task · \(String(title.prefix(48)))")
                let r = tools.execute(.createTask(
                    title: title,
                    subtitle: subtitle,
                    priority: .medio,
                    workspacePath: workspaces?.current?.path,
                    model: nil
                ))
                if r.ok {
                    messages.append(ChatMessage(role: .assistant, text: r.message, engine: .localRules))
                } else {
                    messages.append(ChatMessage(role: .assistant, text: "⚠️ \(r.message)", engine: .localRules))
                }
            case .startBoardTask(let titleOrId):
                pushActivity(.waitingAgents, "Avvio builder su task · \(String(titleOrId.prefix(48)))")
                let r = tools.execute(.startBoardTask(titleOrId: titleOrId))
                messages.append(ChatMessage(
                    role: .assistant,
                    text: r.ok ? r.message : "⚠️ \(r.message)",
                    engine: .localRules
                ))
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Parsing helpers

    private func matches(_ text: String, any phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    /// Broad intent: board task creation (works with multi-line prompts).
    private func isCreateTaskIntent(_ lower: String) -> Bool {
        matches(lower, any: [
            "crea task", "crea una task", "crea una sola task", "crea 1 task",
            "create task", "create_task", "nuova task", "aggiungi task",
            "sulla board", "qs tasks", "qs task", "task sulla board",
            "titolo task", "titolo:", "create una task",
        ])
    }

    /// User wants builder to run now (not only create the card).
    private func wantsStartTask(_ lower: String) -> Bool {
        if lower.contains("non lanciare") || lower.contains("non avviare")
            || lower.contains("senza avviare") || lower.contains("non avvia")
            || lower.contains("senza lanciare") || lower.contains("solo crea") {
            return false
        }
        return matches(lower, any: [
            "e avvia", "poi avvia", "avvia subito", "avvia la task", "avvia questa",
            "lancia la task", "lanciala", "avviala", "start task", "run task",
            "e lancia", "avvia builder", "avvia un builder", "eseguila", "esegui la task",
        ])
    }

    /// Standalone start (task already on board).
    private func isStartTaskIntent(_ lower: String) -> Bool {
        if isCreateTaskIntent(lower) { return false } // handled in create+start path
        return matches(lower, any: [
            "avvia task", "avvia la task", "start task", "lancia task",
            "run task", "avvia builder sulla", "avvia quella task",
            "avvia ultima task", "avvia l'ultima task", "riprendi task",
        ])
    }

    private func parseStartTaskRef(from text: String) -> String? {
        let lower = text.lowercased()
        for p in ["avvia task ", "avvia la task ", "start task ", "lancia task ", "run task ", "avvia "] {
            if let r = lower.range(of: p) {
                let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = rest.components(separatedBy: .newlines).first?
                    .trimmingCharacters(in: .whitespaces) ?? rest
                if !firstLine.isEmpty, firstLine.count < 200 { return firstLine }
            }
        }
        // "ultima task" / selected
        if lower.contains("ultima") || lower.contains("ultimo") || lower.contains("quella") {
            return tasks?.tasks.first(where: { $0.column == .todo })?.title
                ?? tasks?.tasks.first?.title
        }
        return tasks?.tasks.first(where: { $0.isSelected })?.title
    }

    /// Parse title / subtitle / priority / model from free text or structured lines.
    private func parseCreateTaskSpec(from text: String) -> (title: String, subtitle: String?, priority: TaskPriority, model: String?) {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var title: String?
        var subtitleParts: [String] = []
        var priority: TaskPriority = .medio
        var inSubtitle = false
        var expectTitleNext = false

        var model: String?

        func isLabelOnly(_ low: String) -> Bool {
            low.hasPrefix("subtitle") || low.hasPrefix("subtile") || low.hasPrefix("dettaglio")
                || low.hasPrefix("titolo") || low.hasPrefix("title")
                || low.hasPrefix("priorit") || low.hasPrefix("workspace")
                || low.hasPrefix("crea ") || low.hasPrefix("create ")
                || low.hasPrefix("non lanciare") || low.hasPrefix("poi finish")
                || low.hasPrefix("vietato") || low == "un solo file:"
                || low.hasPrefix("modello") || low.hasPrefix("model")
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            let low = line.lowercased()

            if low.hasPrefix("modello") || low.hasPrefix("model") || low.contains("modello builder") {
                let after = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let after, !after.isEmpty {
                    // "Anthropic / claude-sonnet-5" → last token looks like model id
                    let cleaned = after.replacingOccurrences(of: "Anthropic", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "OpenAI", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "/", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    model = cleaned.split(separator: " ").map(String.init).last ?? cleaned
                }
                continue
            }

            // Title on same line or next line after "Titolo task:"
            if low.hasPrefix("titolo task") || low.hasPrefix("titolo:") || low.hasPrefix("title:") {
                let after = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !after.isEmpty {
                    title = after
                    expectTitleNext = false
                } else {
                    expectTitleNext = true
                }
                inSubtitle = false
                continue
            }
            if expectTitleNext {
                if !isLabelOnly(low) {
                    title = String(line.prefix(160))
                    expectTitleNext = false
                    continue
                }
                expectTitleNext = false
            }

            // Subtitle headers (incl. common typo "Subtile")
            if low.hasPrefix("subtitle") || low.hasPrefix("subtile") || low.hasPrefix("dettaglio") {
                let after = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !after.isEmpty { subtitleParts.append(after) }
                inSubtitle = true
                continue
            }
            if low.hasPrefix("priorit") {
                if low.contains("critic") || low.contains("p0") { priority = .critico }
                else if low.contains("alto") || low.contains("high") || low.contains("p1") { priority = .alto }
                else { priority = .medio }
                inSubtitle = false
                continue
            }
            if low.hasPrefix("poi finish") || low.hasPrefix("workspace:") || low.hasPrefix("crea una sola")
                || low.hasPrefix("non lanciare") {
                inSubtitle = false
                continue
            }
            if inSubtitle {
                subtitleParts.append(line)
            }
        }

        // Prefer a real title from body (e.g. "QS smoke: …") if label parsing failed
        if title == nil || title?.isEmpty == true {
            for line in lines where !line.isEmpty {
                let low = line.lowercased()
                if isLabelOnly(low) { continue }
                if low.contains("crea") && low.contains("task") { continue }
                if low.hasPrefix("/*") || low.hasPrefix("1)") || low.hasPrefix("2)") { continue }
                // Strong signals for smoke / short task names
                if low.contains("smoke") || low.contains("boot.css") || low.hasPrefix("qs ") {
                    title = String(line.prefix(160))
                    break
                }
            }
        }
        if title == nil || title?.isEmpty == true {
            for line in lines where !line.isEmpty {
                let low = line.lowercased()
                if isLabelOnly(low) { continue }
                if low.contains("crea") && low.contains("task") { continue }
                title = String(line.prefix(160))
                break
            }
        }

        var sub = subtitleParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if sub.isEmpty, let t = title, text.count > t.count + 20 {
            sub = text.replacingOccurrences(of: t, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sub.count > 1_500 { sub = String(sub.prefix(1_500)) }
        }

        // Never leave a label as the title
        var finalTitle = (title?.isEmpty == false ? title! : "Nuova task")
        let ftLow = finalTitle.lowercased()
        if isLabelOnly(ftLow) || ftLow.hasPrefix("subtile") || ftLow.hasPrefix("dettaglio esatto") {
            finalTitle = lines.first(where: {
                let l = $0.lowercased()
                return !$0.isEmpty && !isLabelOnly(l) && (l.contains("smoke") || l.contains("boot") || l.hasPrefix("qs "))
            }).map { String($0.prefix(160)) } ?? "QS smoke task"
        }
        // Free-text model: "claude-sonnet" anywhere
        if model == nil {
            let lowAll = text.lowercased()
            if lowAll.contains("claude-sonnet") || lowAll.contains("claude sonnet") {
                model = "claude-sonnet-5"
            } else if lowAll.contains("gpt-4") {
                model = "gpt-4.1"
            } else if lowAll.contains("grok") {
                model = "grok-4.5"
            }
        }
        return (finalTitle, sub.isEmpty ? nil : sub, priority, model)
    }

    private func extractTerminalCount(from lower: String) -> Int? {
        // "apri 2 terminali" / "3 terminali"
        let pattern = #/(\d+)\s+terminal/#
        if let match = lower.firstMatch(of: pattern), let n = Int(match.1), n > 0, n <= 8 {
            return n
        }
        if lower.contains("due terminal") { return 2 }
        if lower.contains("tre terminal") { return 3 }
        return nil
    }

    /// True when the user is asking for a git tool *now*, not mentioning git inside a longer goal.
    private func isStandaloneGitIntent(_ text: String, needles: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard matches(lower, any: needles) else { return false }
        // Long multi-line goals that say «verifica con git status» must not hijack the chat.
        if t.count > 120 || t.contains("\n") { return false }
        // Prefer messages that start with / are mostly the git phrase
        let firstLine = lower.components(separatedBy: .newlines).first ?? lower
        return needles.contains { firstLine.hasPrefix($0) || firstLine == $0 || firstLine.hasPrefix("mostra \($0)") }
            || t.count < 48
    }

    /// Prefer open workspace; never return bare $HOME ( «nella home del gioco» used to resolve to ~ ).
    private func safeGitPath(from text: String) -> String? {
        // Workspace switcher (zackgame) always wins over parsed chat paths.
        return OrchestratorToolRunner.resolveProjectGitPath(
            path: extractPath(from: text),
            terminals: terminals,
            workspaces: workspaces,
            git: git
        )
    }

    private func extractPath(from text: String) -> String? {
        // ~/... or /... (real filesystem paths only)
        let pattern = #/(?:~\/|\/)[^\s`'",]+/#
        if let match = text.firstMatch(of: pattern) {
            let raw = String(match.0)
            return directories?.resolveUserPath(raw) ?? (raw as NSString).expandingTildeInPath
        }
        // "in zackgame" / "su qsagents" — only if token looks like a project name, not Italian filler
        let stop: Set<String> = [
            "home", "gioco", "codice", "pagina", "board", "corso", "revisione", "chat",
            "missione", "swarm", "task", "file", "repo", "progetto", "workspace", "cartella",
            "layout", "pulsante", "button", "play", "verde", "css", "js", "html",
        ]
        let inPattern = #/(?:in|su|at|nel|nella)\s+([~\w.\-\/]+)/#
        if let match = text.lowercased().firstMatch(of: inPattern) {
            let token = String(match.1)
            if stop.contains(token) { return nil }
            if token.contains("/") || token.hasPrefix("~") || token.contains(".") {
                return directories?.resolveUserPath(token)
            }
            // Bare name: only if it matches a known project / recent workspace
            if let dirs = directories, dirs.resolveUserPath(token) != nil {
                // resolveUserPath also does HOME/token — reject that for short tokens without project hit
                if let hit = dirs.projects.first(where: { $0.name.lowercased() == token })
                    ?? dirs.projects.first(where: { $0.name.lowercased().contains(token) && token.count >= 3 })
                    ?? dirs.bookmarks.first(where: { $0.name.lowercased() == token }) {
                    return hit.path
                }
            }
            if let ws = workspaces?.recent.first(where: { $0.name.lowercased() == token }) {
                return ws.path
            }
        }
        return nil
    }

    private func extractProjectPath(from text: String) -> String? {
        let lower = text.lowercased()
        if matches(lower, any: ["progetto corrente", "workspace corrente", "current project", "questo progetto", "qui "]) {
            return workspaces?.current?.path
        }
        // Recent workspaces first (user context)
        if let ws = workspaces {
            for r in ws.recent {
                if lower.contains(r.name.lowercased()) { return r.path }
            }
        }
        if let dirs = directories {
            for p in dirs.projects {
                if lower.contains(p.name.lowercased()) { return p.path }
            }
            for b in dirs.bookmarks {
                if lower.contains(b.name.lowercased()) { return b.path }
            }
        }
        return nil
    }

    // MARK: - Project bootstrap flow

    /// Multi-part “start working on a project” natural language.
    private func isProjectBootstrapIntent(_ lower: String) -> Bool {
        let openish = matches(lower, any: [
            "apri progetto", "apri workspace", "aprimi", "open project",
            "inizia su", "lavora su", "setup progetto", "prepara progetto",
            "avvia progetto", "start project", "bootstrap"
        ])
        let workish = matches(lower, any: [
            "terminale", "terminal", "task", "piano", "lista", "backlog",
            "agent", "grok", "llm", "knowledge", "indice", "missi",
            "e avvia", "e crea", "e fai", "e apri", "poi "
        ])
        // Explicit compound phrases
        if matches(lower, any: [
            "apri il progetto", "apri progetto e", "setup del progetto",
            "lista di task del progetto", "task del progetto",
            "apri e avvia", "prepara l'ambiente", "prepara ambiente"
        ]) { return true }
        return openish && workish
    }

    private func handleProjectBootstrap(text: String, lower: String) -> ChatMessage {
        let path = extractPath(from: text)
            ?? extractProjectPath(from: text)
            ?? workspaces?.current?.path
            ?? workspaces?.recent.first?.path

        guard let path else {
            return ChatMessage(
                role: .assistant,
                text: """
                Per avviare un progetto dimmi il nome o il path, ad esempio:

                `apri progetto qsagents, apri terminale e crea le task`

                Oppure scegli dal menu **Workspace** in alto a sinistra.
                """,
                engine: .localRules
            )
        }

        let wantTerminal = matches(lower, any: [
            "terminale", "terminal", "shell", "pty"
        ]) || !matches(lower, any: ["senza terminale", "no terminale"])
        // Default: open a terminal when bootstrapping unless user refuses

        let wantPlan = matches(lower, any: [
            "task", "piano", "lista", "backlog", "todo", "lavori", "checklist"
        ]) || matches(lower, any: ["setup", "prepara", "bootstrap", "avvia progetto"])

        let wantAgent = matches(lower, any: [
            "agent", "grok", "openai", "claude", "llm", "avvia ai", "avvia l'ai", "analizza"
        ])

        let wantKnowledge = matches(lower, any: [
            "knowledge", "indice", "index", "cerca nel codice"
        ]) || wantPlan // plan implies useful to index

        // Agent goal: strip boilerplate, keep rest if meaningful
        var goal: String? = nil
        if wantAgent {
            goal = text
            for p in ["avvia grok", "avvia agent", "e avvia", "con grok", "con agent"] {
                if let r = text.range(of: p, options: .caseInsensitive) {
                    let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if rest.count > 8 { goal = rest }
                    break
                }
            }
        }

        let result = tools.execute(.bootstrapProject(
            path: path,
            openTerminal: wantTerminal,
            createPlan: wantPlan,
            indexKnowledge: wantKnowledge,
            startAgent: wantAgent,
            agentGoal: goal
        ))
        return ChatMessage(role: .assistant, text: result.message, engine: .localRules)
    }

    private func extractRunCommand(from text: String) -> (String, String?)? {
        let lower = text.lowercased()
        let verbs = [
            "manda al terminale ", "scrivi nel terminale ", "invia al terminale ",
            "esegui nel terminale ", "run in terminal ", "terminal: ",
            "puoi eseguire ", "puoi lanciare ", "esegui questo: ", "esegui: ",
            "esegui ", "lancia ", "run ", "fai ", "esegui:", "run:",
        ]
        let hasVerb = verbs.contains { lower.contains($0.trimmingCharacters(in: .whitespaces)) }
            || matches(lower, any: ["esegui", "lancia", "run ", "fai "])
        let looksLikeShell = lower.contains("npm ") || lower.contains("git ")
            || lower.contains("cargo ") || lower.contains("swift ") || lower.contains("python ")
            || lower.contains("ls ") || lower.contains("cd ") || lower.hasPrefix("ls")
            || lower.hasPrefix("git ") || lower.hasPrefix("npm ")
        // Bare shell line (user pasted a command)
        if !hasVerb && looksLikeShell && text.split(whereSeparator: \.isNewline).count <= 2 {
            let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if bare.count >= 2, !bare.contains("?") {
                return (bare, workspaces?.current?.path)
            }
        }
        guard hasVerb || (looksLikeShell && hasVerb) else {
            return nil
        }

        var cmd = text
        for p in verbs + ["Esegui ", "Run ", "Lancia ", "Fai "] {
            if let r = cmd.range(of: p, options: [.caseInsensitive, .anchored]) {
                cmd = String(cmd[r.upperBound...])
                break
            } else if let r = cmd.range(of: p, options: .caseInsensitive) {
                cmd = String(cmd[r.upperBound...])
                break
            }
        }
        // strip " in path"
        var path: String?
        if let r = cmd.range(of: " in ", options: .caseInsensitive) {
            let after = String(cmd[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            path = directories?.resolveUserPath(after) ?? extractPath(from: after)
            cmd = String(cmd[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        cmd = cmd.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        guard !cmd.isEmpty, cmd.count < 2000 else { return nil }
        return (cmd, path)
    }

    private func buildContext() -> String {
        // Compact context for LLM — full probe dumps burn thousands of prompt tokens per turn
        let ws = workspaces?.current?.path ?? "nessuno"
        let term: String = {
            if let s = terminals?.selected, s.isAlive {
                return "\(s.title) @ \(s.cwd) LIVE"
            }
            let n = terminals?.sessions.count ?? 0
            return n == 0 ? "nessun PTY" : "\(n) PTY · sel=\(terminals?.selected?.title ?? "—")"
        }()
        let tasksN = tasks?.tasks.count ?? 0
        let openTodo = tasks?.count(in: .todo) ?? 0
        let proj = (directories?.projects.prefix(TokenBudget.orchestratorContextProjects).map(\.name) ?? []).joined(separator: ", ")
        let cpu = probe?.snapshot.cpuPercent
        let mem = probe?.snapshot.memoryUsedGB
        let metrics: String = {
            if let cpu, let mem {
                return "CPU \(String(format: "%.0f", cpu))% · RAM \(String(format: "%.1f", mem))G"
            }
            return "metrics n/d"
        }()
        return """
        WS: \(ws)
        Term: \(term)
        Tasks: \(tasksN) (todo \(openTodo))
        Progetti: \(proj.isEmpty ? "—" : proj)
        \(metrics)
        """
    }

    private func extractQuoted(from text: String) -> String? {
        // "message" or 'message'
        if let r = text.range(of: "\"([^\"]+)\"", options: .regularExpression) {
            var s = String(text[r])
            if s.count >= 2 {
                s.removeFirst()
                s.removeLast()
                return s
            }
        }
        if let r = text.range(of: "'([^']+)'", options: .regularExpression) {
            var s = String(text[r])
            if s.count >= 2 {
                s.removeFirst()
                s.removeLast()
                return s
            }
        }
        return nil
    }

    /// Extract project name after phrases like "su zackgame" / "progetto qsagents".
    private func extractProjectQuery(from text: String) -> String? {
        let lower = text.lowercased()
        let prefixes = [
            "cosa abbiamo fatto su ",
            "cosa è successo su ",
            "ultima volta su ",
            "memoria progetto ",
            "ricorda progetto ",
            "history progetto ",
            "storia progetto ",
            "su ",
        ]
        for p in prefixes {
            if let r = lower.range(of: p) {
                let rest = String(text[r.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty { continue }
                let first = rest.split(whereSeparator: { $0.isWhitespace || $0 == "?" || $0 == "," }).first
                guard let first else { continue }
                let token = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                if token.count >= 2 { return token }
            }
        }
        return extractQuoted(from: text)
    }

    private var helpText: String {
        """
        **Comandi Orchestratore**

        Flusso progetto (consigliato)
        • `apri progetto qsagents, apri terminale e crea le task`
        • `prepara progetto zackgame e avvia agent`
        • `crea piano` / `lista task del progetto` (sul workspace attuale)
        → apre workspace, PTY, piano in **QS Tasks**, opzionale agent LLM

        Workspace
        • `apri progetto <nome>` / `passa a <nome>`
        • Menu **Workspace** in alto per switch rapido

        Terminali
        • `apri terminale in ~/qsagents`
        • `apri 2 terminali in qsagents`
        • `terminali aperti`

        Git / GitHub
        • `changelog` / `git log` (salva anche in memoria progetto)
        • `git status` / `git diff`
        • `commit "fix: messaggio"`
        • `commit e push "feat: …"`
        • `git push` / `git pull`
        (Token PAT in Integrazioni → GitHub)

        Memoria progetto
        • `cosa abbiamo fatto su <progetto>`
        • `ultima volta` / `memoria progetto`
        • `crea piano` e `changelog` aggiornano la memoria automaticamente

        Task
        • `crea task <titolo>`
        • `completa task <titolo>`
        • `elimina task <titolo>`

        Comandi shell
        • `esegui npm run dev in <progetto>`

        Sistema
        • `cosa sta girando?`
        • `processi` / `porte`

        Progetti
        • `lista progetti`
        • `apri workspace ~/qsagents`

        UI
        • `integrazioni`
        """
    }

    private func extractChainedCommand(from text: String) -> String? {
        // Patterns: "… e lancia X" / "… e esegui X"
        for verb in [" e lancia ", " e esegui ", " e run ", " poi esegui ", " poi lancia ", " and run "] {
            if let r = text.range(of: verb, options: .caseInsensitive) {
                let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // strip trailing path phrases
                if let inR = rest.range(of: " in ", options: .caseInsensitive) {
                    return String(rest[..<inR.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    private func extractAfterVerb(_ text: String, verbs: [String]) -> String? {
        for v in verbs {
            if let r = text.range(of: v, options: .caseInsensitive) {
                let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return rest }
            }
        }
        return nil
    }

    // MARK: - Optional LLM via LLMClient

    private struct LLMResult {
        let text: String
        let provider: String
        let model: String
    }

    private func appendStreamDelta(_ messageId: UUID?, _ piece: String) {
        guard let messageId, !piece.isEmpty else { return }
        guard let i = messages.firstIndex(where: { $0.id == messageId }) else { return }
        // Reassign so @Published notifies (in-place struct mutate is silent)
        var m = messages[i]
        m.text += piece
        m.isStreaming = true
        messages[i] = m
    }

    private func tryLLM(userText: String, streamMessageId: UUID? = nil) async -> LLMResult? {
        lastLLMError = nil

        // Build candidate (provider, model) list: live → prefs → other keys as fallback
        var candidates: [(LLMProviderKind, String)] = []
        func push(_ p: LLMProviderKind?, model: String?) {
            guard let p, LLMClient.shared.hasKey(p) else { return }
            let m = model?.isEmpty == false ? model! : (
                ProviderPreferences.shared.model(for: .coordinator) != "local"
                    ? ProviderPreferences.shared.model(for: .coordinator)
                    : p.defaultModel
            )
            if !candidates.contains(where: { $0.0 == p && $0.1 == m }) {
                candidates.append((p, m))
            }
        }
        push(selectedProviderKind, model: selectedModel)
        push(ProviderPreferences.shared.defaultProvider, model: ProviderPreferences.shared.model(for: .coordinator))
        push(LLMClient.shared.preferredProvider(), model: nil)
        for p in LLMProviderKind.allCases where LLMClient.shared.hasKey(p) {
            push(p, model: p.defaultModel)
        }
        guard !candidates.isEmpty else {
            lastLLMError = "Nessuna API key in Keychain"
            pushActivity(.thinking, "Nessuna API key — uso regole locali")
            return nil
        }

        let env = safety?.environment.shortLabel ?? "dev"
        let termHint: String = {
            if let s = terminals?.selected, s.isAlive {
                return "PTY \(s.title) @ \(s.cwd)"
            }
            return "no PTY sel"
        }()
        let ws = workspaces?.current?.path ?? "nessuno"
        // Cap user text in prompt (paste dumps)
        let userCapped = userText.count > 4_000 ? String(userText.prefix(4_000)) + "…" : userText

        var errors: [String] = []
        // Prefer 1–2 candidates only (each retry re-sends full system+context)
        let tryList = Array(candidates.prefix(2))
        for (provider, model) in tryList {
            pushActivity(.callingLLM, "\(provider.displayName) · \(model)")
            let system = """
            Orchestratore QS Agents · \(provider.displayName)/\(model)
            Italiano, breve.             Side-effect SOLO con ACTION (una riga, no fence):
            ACTION:START_MISSION|goal  ← preferisci per «migliora/modifica/cambia UI» (avvia Swarm)
            ACTION:SPAWN_AGENT|goal
            ACTION:CREATE_TASK|titolo|subtitle_opzionale
            ACTION:START_TASK|titolo_o_id
            ACTION:OPEN_TERMINAL|path
            ACTION:RUN|cmd|path_opzionale  ← SOLO comandi shell brevi, MAI per goal di prodotto/UI
            Se l'utente chiede di cambiare codice/UI: ACTION:START_MISSION|… (non RUN, non solo terminale).
            WS=\(ws). \(termHint). Safety \(env): no DROP DB / rm -rf / / force-push main.
            Ctx:
            \(buildContext())
            Mem sessione:
            \(memory.promptBlock(limit: TokenBudget.orchestratorMemoryTurns, maxLine: TokenBudget.orchestratorMemoryLineChars))
            Mem progetto:
            \(projectMemory?.promptBlock(path: ws == "nessuno" ? nil : ws, limit: 6) ?? "_nessuna_")
            """

            do {
                // C3: stream into chat bubble when we have a placeholder id
                let c: LLMCompletion
                if streamMessageId != nil {
                    // Reset bubble if retrying next provider
                    if let id = streamMessageId, let i = messages.firstIndex(where: { $0.id == id }) {
                        var m = messages[i]
                        m.text = ""
                        m.isStreaming = true
                        m.engine = .llm(provider: provider.displayName, model: model)
                        messages[i] = m
                    }
                    pushActivity(.streaming, "Token in arrivo da \(provider.displayName)…")
                    c = try await LLMClient.shared.completeStreaming(
                        system: system,
                        user: userCapped,
                        provider: provider,
                        model: model,
                        maxTokens: TokenBudget.orchestratorMaxCompletion,
                        onDelta: { [weak self] piece in
                            self?.appendStreamDelta(streamMessageId, piece)
                        }
                    )
                } else {
                    c = try await LLMClient.shared.complete(
                        messages: [
                            LLMMessage(role: .system, content: system),
                            LLMMessage(role: .user, content: userCapped),
                        ],
                        provider: provider,
                        model: model,
                        temperature: 0.3,
                        maxTokens: TokenBudget.orchestratorMaxCompletion
                    )
                }
                ProviderPreferences.shared.recordUsage(tokens: c.usage.totalTokens, provider: c.provider)
                // Swarm must use the same live key — otherwise builders hit local bootstrap
                ProviderPreferences.shared.syncSwarmFromLive(provider: c.provider, model: c.model)
                AppLogger.info("Orchestrator LLM ok · \(c.provider.displayName) · \(c.model)\(streamMessageId != nil ? " · stream" : "")")
                lastLLMError = nil
                if selectedProviderRaw == nil {
                    selectedProviderRaw = c.provider.rawValue
                }
                if selectedModel == nil || selectedModel?.isEmpty == true {
                    selectedModel = c.model
                }
                pushActivity(.thinking, "Risposta modello ok · \(c.usage.totalTokens) tok")
                return LLMResult(text: c.text, provider: c.provider.displayName, model: c.model)
            } catch {
                let msg = "\(provider.displayName)/\(model): \(error.localizedDescription)"
                errors.append(msg)
                AppLogger.error("Orchestrator LLM: \(msg)")
                pushActivity(.callingLLM, "Retry — \(String(msg.prefix(70)))")
                // try next candidate
            }
        }
        lastLLMError = errors.prefix(3).joined(separator: " | ")
        return nil
    }

    private func parseActionTags(_ text: String) -> (String, [OrchestratorAction]) {
        var actions: [OrchestratorAction] = []
        var lines: [String] = []
        // Normalize: strip common markdown wrappers around ACTION lines
        let normalized = text
            .replacingOccurrences(of: "```", with: "\n")
            .replacingOccurrences(of: "`ACTION:", with: "ACTION:")
            .replacingOccurrences(of: "ACTION: ", with: "ACTION:")

        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ACTION:OPEN_TERMINAL|") {
                let path = String(line.dropFirst("ACTION:OPEN_TERMINAL|".count)).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    actions.append(.openTerminal(path: (path as NSString).expandingTildeInPath, title: nil))
                }
            } else if line.hasPrefix("ACTION:RUN|") {
                // Path is optional and must look like a filesystem path. Shell pipelines use `|`
                // inside cmd — never take the first `|` as the cmd/path split (that produced
                // allowlist Path: `head -40|/Users/.../zackgame`).
                let rest = String(line.dropFirst("ACTION:RUN|".count))
                let (cmd, runPath) = Self.parseRunActionRest(rest)
                if !cmd.isEmpty {
                    actions.append(.runCommand(command: cmd, path: runPath))
                }
            } else if line.hasPrefix("ACTION:START_MISSION|") || line.hasPrefix("ACTION:GOAL|") {
                let prefix = line.hasPrefix("ACTION:GOAL|") ? "ACTION:GOAL|" : "ACTION:START_MISSION|"
                let goal = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !goal.isEmpty {
                    actions.append(.startMission(goal: goal))
                }
            } else if line.hasPrefix("ACTION:SPAWN_AGENT|") {
                let goal = String(line.dropFirst("ACTION:SPAWN_AGENT|".count)).trimmingCharacters(in: .whitespaces)
                if !goal.isEmpty {
                    actions.append(.spawnAgent(goal: goal))
                }
            } else if line.hasPrefix("ACTION:CREATE_TASK|") {
                let rest = String(line.dropFirst("ACTION:CREATE_TASK|".count))
                let parts = rest.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if let title = parts.first, !title.isEmpty {
                    let sub = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                    actions.append(.createTask(title: title, subtitle: sub))
                }
            } else if line.hasPrefix("ACTION:START_TASK|") {
                let ref = String(line.dropFirst("ACTION:START_TASK|".count)).trimmingCharacters(in: .whitespaces)
                if !ref.isEmpty {
                    actions.append(.startBoardTask(titleOrId: ref))
                }
            } else {
                lines.append(rawLine)
            }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), actions)
    }

    /// Parse `ACTION:RUN|…` body. Last `|`-segment wins as cwd only if it looks like a path.
    static func parseRunActionRest(_ rest: String) -> (command: String, path: String?) {
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        let segments = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if segments.count >= 2, let last = segments.last, SafetyGuardrails.looksLikeFilesystemPath(last) {
            let cmd = segments.dropLast().joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (last as NSString).expandingTildeInPath
            return (cmd, path.isEmpty ? nil : path)
        }
        return (trimmed, nil)
    }

    /// Ensure a QS Task exists for a new goal/mission (Claude-style), reuse active card on follow-ups.
    @discardableResult
    func ensureLinkedQSTask(goal: String, navigateToBoard: Bool = true) -> AgentTask? {
        let ws = workspaces?.current?.path
        let model = selectedModel?.isEmpty == false
            ? selectedModel!
            : (selectedProviderKind ?? ProviderPreferences.shared.anyKeyedProvider())?.defaultModel ?? "orchestrator"
        let task = tasks?.ensureLinkedTask(
            goal: goal,
            workspacePath: ws,
            titlePrefix: "QS",
            model: model,
            evidence: ["orchestrator-auto", "ws:\(ws ?? "?")"]
        )
        if let task {
            lastClaudeCodeTaskID = task.id
            if navigateToBoard { navigate("tasks") }
        }
        return task
    }
}
