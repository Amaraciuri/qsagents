import Foundation
import SwiftUI
import Combine
import Security

@MainActor
final class AppState: ObservableObject {
    // Navigation
    @Published var mainTab: MainTab = .home
    @Published var orchestratorMode: OrchestratorMode = .chat
    @Published var selectedSidebar: SidebarItem = .activeAgents
    /// Left rail (workspace / directory explorer) — like Cursor/VS Code primary sidebar.
    @Published var showLeftSidebar: Bool = UserDefaults.standard.object(forKey: "qs.ui.leftSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLeftSidebar, forKey: "qs.ui.leftSidebar") }
    }
    /// Right rail (context / git / inspector) — secondary sidebar.
    @Published var showRightSidebar: Bool = UserDefaults.standard.object(forKey: "qs.ui.rightSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRightSidebar, forKey: "qs.ui.rightSidebar") }
    }
    /// Legacy alias used by older views (maps to right sidebar).
    var showSkillsPanel: Bool {
        get { showRightSidebar }
        set { showRightSidebar = newValue }
    }
    @Published var showIntegrations: Bool = false
    @Published var showOrchestratorModal: Bool = false
    @Published var showSafety: Bool = false
    @Published var searchText: String = ""
    /// Deep-link into IntegrationsView section: "gdpr" | "docs" | "support" | "permissions" | nil
    @Published var openSettingsSection: String? = nil

    func toggleLeftSidebar() { showLeftSidebar.toggle() }
    func toggleRightSidebar() { showRightSidebar.toggle() }

    // Dashboard (legacy agent cards — empty unless demo)
    @Published var agents: [AgentInstance] = []
    @Published var workspaces: [WorkspaceNav] = []
    @Published var skills: [AgentSkill] = []
    @Published var selectedAgentID: UUID?
    @Published var commandDrafts: [UUID: String] = [:]

    // Tasks — prefer TaskStore; kept for backward UI during migration
    @Published var tasks: [AgentTask] = []

    // Workspace editor — superseded by WorkspaceStore for real files
    @Published var fileTree: [WorkspaceFile] = []
    @Published var openFileName: String = ""
    @Published var codeLines: [CodeLine] = []
    @Published var liveStream: [TerminalLine] = []
    @Published var workspaceAgents: [AgentInstance] = []
    @Published var rightPanelTab: Int = 0 // 0 browser, 1 terminal, 2 memory

    // Swarm
    @Published var swarmAgents: [SwarmAgent] = []
    @Published var swarmCommand: String = ""
    @Published var swarmRunning: Bool = false

    // Knowledge
    @Published var knowledgeNodes: [KnowledgeNode] = []
    @Published var knowledgeEdges: [KnowledgeEdge] = []
    @Published var selectedNodeID: UUID?
    @Published var graphScale: CGFloat = 1.0
    @Published var graphOffset: CGSize = .zero

    // Integrations
    @Published var integrations: [AIIntegration] = SeedData.integrations
    @Published var integrationSearch: String = ""
    @Published var configuringIntegrationID: UUID?
    @Published var apiKeyDraft: String = ""
    /// Feedback after Salva key in Integrations.
    @Published var integrationSaveMessage: String?

    // System metrics — only from SystemProbe / terminals (no fake animation)
    @Published var activeAgentCount: Int = 0
    @Published var cpuPercent: Int = 0
    @Published var memGB: Double = 0
    @Published var tokensPerSec: Int = 0
    @Published var systemOnline: Bool = true

    init() {
        loadDomainData()
        AppLogger.info("AppState init · useDemoData=\(AppConfig.useDemoData)")
    }

    private func loadDomainData() {
        if AppConfig.useDemoData {
            agents = SeedData.agents
            workspaces = SeedData.workspaces
            skills = SeedData.skills
            tasks = SeedData.tasks
            fileTree = SeedData.fileTree
            openFileName = "Revisione_Codice.ts"
            codeLines = SeedData.codeLines
            liveStream = SeedData.liveStream
            workspaceAgents = SeedData.workspaceAgents
            swarmAgents = SeedData.swarmAgents
            swarmRunning = true
            knowledgeNodes = SeedData.knowledgeNodes
            knowledgeEdges = SeedData.makeEdges(nodes: knowledgeNodes)
            selectedNodeID = knowledgeNodes.first(where: { $0.isSelected })?.id
            selectedAgentID = agents.first(where: { !$0.isPlaceholder })?.id
        } else {
            // Real path: empty collections; terminals/workspaces/tasks live in dedicated stores
            agents = []
            workspaces = []
            skills = []
            tasks = []
            fileTree = []
            openFileName = ""
            codeLines = []
            liveStream = []
            workspaceAgents = []
            swarmAgents = []
            knowledgeNodes = []
            knowledgeEdges = []
            integrations = SeedData.integrations // cards only; connection from Keychain
        }
    }

    /// Called from system probe to keep status bar real.
    func applySystemMetrics(cpu: Int, memGB: Double, activeTerminals: Int) {
        self.cpuPercent = cpu
        self.memGB = memGB
        self.activeAgentCount = activeTerminals
        self.tokensPerSec = 0
    }

    // MARK: - Dashboard actions

    func sendCommand(to agentID: UUID) {
        let text = (commandDrafts[agentID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let idx = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[idx].lines.append(TerminalLine(text: "$ \(text)", level: .code))
        agents[idx].status = .thinking
        commandDrafts[agentID] = ""

        let response = processLocalCommand(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let i = self.agents.firstIndex(where: { $0.id == agentID }) else { return }
            self.agents[i].lines.append(contentsOf: response)
            self.agents[i].status = .active
        }
    }

    private func processLocalCommand(_ text: String) -> [TerminalLine] {
        let lower = text.lowercased()
        if lower.hasPrefix("help") {
            return [
                TerminalLine(text: "Comandi: help · status · clear · run <task> · skill <name>", level: .info),
                TerminalLine(text: "Usa @agent per indirizzare un agente dello sciame.", level: .muted),
            ]
        }
        if lower.hasPrefix("status") {
            return [
                TerminalLine(text: "Sistema: ONLINE · Agenti attivi: \(activeAgentCount)", level: .success),
                TerminalLine(text: "CPU \(cpuPercent)% · MEM \(String(format: "%.1f", memGB))GB · TOKEN/S \(tokensPerSec)", level: .info),
            ]
        }
        if lower.hasPrefix("clear") {
            return [TerminalLine(text: "Buffer pulito.", level: .muted)]
        }
        if lower.hasPrefix("run") {
            return [
                TerminalLine(text: "Thinking: pianificando esecuzione...", level: .thinking),
                TerminalLine(text: "OK · task accodato nell'orchestratore", level: .success),
            ]
        }
        // Best-effort real shell for safe read-only commands
        if lower.hasPrefix("echo ") || lower == "pwd" || lower == "date" || lower.hasPrefix("whoami") {
            if let out = ShellRunner.run(text) {
                return out.split(separator: "\n", omittingEmptySubsequences: false).map {
                    TerminalLine(text: String($0), level: .info)
                }
            }
        }
        return [
            TerminalLine(text: "Agent ack: \"\(text)\"", level: .info),
            TerminalLine(text: "Thinking: elaborazione in corso...", level: .thinking),
            TerminalLine(text: "Risultato parziale disponibile nel contesto condiviso.", level: .success),
        ]
    }

    func addNewAgent() {
        let n = agents.filter { !$0.isPlaceholder }.count + 1
        let agent = AgentInstance(
            name: "Agent-\(n)",
            modelTag: "LOCAL",
            status: .idle,
            lines: [TerminalLine(text: "Istanza pronta. Digita help per i comandi.", level: .muted)],
            promptPlaceholder: "Invia comando..."
        )
        if let placeholderIdx = agents.firstIndex(where: { $0.isPlaceholder }) {
            agents.insert(agent, at: placeholderIdx)
        } else {
            agents.append(agent)
        }
        selectedAgentID = agent.id
    }

    func closeAgent(_ id: UUID) {
        agents.removeAll { $0.id == id }
        if selectedAgentID == id { selectedAgentID = agents.first?.id }
    }

    func applySkill(_ skill: AgentSkill, to agentID: UUID?) {
        guard let agentID, let idx = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[idx].lines.append(TerminalLine(text: "Skill attivata: \(skill.name)", level: .success))
        agents[idx].lines.append(TerminalLine(text: skill.description, level: .muted))
        agents[idx].status = .active
        if let sIdx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[sIdx].isActive = true
        }
    }

    // MARK: - Tasks (legacy; prefer TaskStore)

    func moveTask(_ id: UUID, to column: TaskColumn) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].column = column
        if column == .inProgress && tasks[idx].progress == nil {
            tasks[idx].progress = 0.15
        }
    }

    func addTask(title: String, column: TaskColumn = .todo) {
        let task = AgentTask(
            title: title,
            priority: .medio,
            column: column,
            assigneeModel: "local"
        )
        tasks.insert(task, at: 0)
    }

    func selectTask(_ id: UUID) {
        for i in tasks.indices {
            tasks[i].isSelected = tasks[i].id == id
        }
    }

    func count(in column: TaskColumn) -> Int {
        tasks.filter { $0.column == column }.count
    }

    // MARK: - Swarm

    func sendSwarmCommand() {
        let text = swarmCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        swarmRunning = true
        if let cIdx = swarmAgents.firstIndex(where: { $0.isCoordinator }) {
            swarmAgents[cIdx].detail = "Missione: \(text.prefix(40))"
            swarmAgents[cIdx].status = .active
            swarmAgents[cIdx].progress = 0.2
        }
        for i in swarmAgents.indices where !swarmAgents[i].isCoordinator {
            swarmAgents[i].status = [.active, .thinking, .idle].randomElement()!
        }
        swarmCommand = ""
    }

    // MARK: - Knowledge

    func selectNode(_ id: UUID) {
        selectedNodeID = id
        for i in knowledgeNodes.indices {
            knowledgeNodes[i].isSelected = knowledgeNodes[i].id == id
        }
    }

    var selectedNode: KnowledgeNode? {
        knowledgeNodes.first { $0.id == selectedNodeID }
    }

    // MARK: - Integrations

    var filteredIntegrations: [AIIntegration] {
        let q = integrationSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return integrations }
        return integrations.filter {
            $0.name.lowercased().contains(q) || $0.provider.lowercased().contains(q)
        }
    }

    /// Save key for integration. Pass `keyOverride` from the card local field (more reliable than SecureField binding alone).
    @discardableResult
    func saveAPIKey(for id: UUID, keyOverride: String? = nil) -> Bool {
        guard let idx = integrations.firstIndex(where: { $0.id == id }) else {
            integrationSaveMessage = "Integrazione non trovata"
            return false
        }
        let name = integrations[idx].name
        let key = (keyOverride ?? apiKeyDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty else {
            integrationSaveMessage = "Incolla o digita la API key prima di Salva"
            AppLogger.warn("saveAPIKey empty for \(name)")
            return false
        }

        // Canonical account name for LLM providers
        let account: String = {
            if let kind = LLMProviderKind.allCases.first(where: {
                $0.keychainAccount == name || $0.displayName == name || $0.legacyKeychainAccounts.contains(name)
            }) {
                return kind.keychainAccount
            }
            return name
        }()

        // Clear only "miss" stigma — do NOT wipe a good cache after a successful set.
        // Previous code invalidated after set then non-interactive get failed (esp. OpenRouter ACL).
        KeychainStore.invalidateCache(for: account)

        let result = KeychainStore.persist(key, for: account)
        switch result {
        case .persisted:
            integrations[idx].status = .connected
            integrationSaveMessage = "Key salvata in Portachiavi per \(account)"
            AppLogger.info("API key saved for \(account) (len=\(key.count))")
            configuringIntegrationID = nil
            apiKeyDraft = ""
            refreshIntegrationStatuses()
            return true
        case .sessionOnly:
            // Usable now, but honest: gone after quit
            integrations[idx].status = .connected
            integrationSaveMessage = "⚠️ Key solo in sessione per \(account) — Portachiavi ha rifiutato; al riavvio sparisce. Riprova Salva o sblocca il login keychain."
            AppLogger.warn("Keychain session-only for \(account)")
            configuringIntegrationID = nil
            apiKeyDraft = ""
            refreshIntegrationStatuses()
            return true
        case .failed:
            break
        }
        integrationSaveMessage = "Keychain ha rifiutato \(account). Riprova; se macOS chiede accesso Portachiavi, scegli Consenti."
        AppLogger.error("Failed to save API key for \(account)")
        return false
    }

    func disconnectIntegration(_ id: UUID) {
        guard let idx = integrations.firstIndex(where: { $0.id == id }) else { return }
        let name = integrations[idx].name
        KeychainStore.delete(name)
        if let kind = LLMProviderKind.allCases.first(where: { $0.keychainAccount == name }) {
            for a in kind.legacyKeychainAccounts { KeychainStore.delete(a) }
        }
        KeychainStore.invalidateCache(for: name)
        integrations[idx].status = .notConfigured
        integrationSaveMessage = "Disconnesso \(name)"
        refreshIntegrationStatuses()
    }

    // MARK: - Navigation helpers

    func openIntegrations() {
        showIntegrations = true
        showSafety = false
        mainTab = .dashboard
        selectedSidebar = .integrations
    }

    /// Open Impostazioni on a specific subsection (e.g. GDPR).
    func openSettings(section: String? = nil) {
        openSettingsSection = section
        openIntegrations()
    }

    func openOrchestratorModal() {
        showOrchestratorModal = true
    }

    func closeOrchestratorModal() {
        showOrchestratorModal = false
    }

    func toggleOrchestratorModal() {
        showOrchestratorModal.toggle()
    }

    func openSafety() {
        showSafety = true
        showIntegrations = false
        showOrchestratorModal = false
    }

    func navigate(to tab: MainTab) {
        showIntegrations = false
        showSafety = false
        mainTab = tab
        if tab == .home {
            selectedSidebar = .activeAgents
        } else if tab == .orchestrator {
            if orchestratorMode == .workspace {
                selectedSidebar = .workspaces
            } else if orchestratorMode == .chat {
                selectedSidebar = .activeAgents
            }
        } else if tab == .monitor {
            selectedSidebar = .activeAgents
        } else if tab == .dashboard {
            selectedSidebar = .logs
        }
    }

    func goHome() {
        showIntegrations = false
        showSafety = false
        mainTab = .home
    }

    /// Route string used by orchestrator actions.
    func handleOrchestratorRoute(_ route: String) {
        showIntegrations = false
        switch route {
        case "terminals", "dashboard":
            mainTab = .dashboard
        case "integrations":
            openIntegrations()
        case "chat":
            mainTab = .orchestrator
            orchestratorMode = .chat
        case "swarm":
            mainTab = .orchestrator
            orchestratorMode = .swarm
        case "knowledge":
            mainTab = .monitor
        case "tasks":
            mainTab = .orchestrator
            orchestratorMode = .tasks
        case "swarm":
            mainTab = .orchestrator
            orchestratorMode = .swarm
        case "workspace":
            mainTab = .orchestrator
            orchestratorMode = .workspace
        case "monitor", "knowledge":
            mainTab = .monitor
        case "safety", "sicurezza", "guardrail":
            openSafety()
        case "chat":
            mainTab = .orchestrator
            orchestratorMode = .chat
        default:
            break
        }
    }

    func refreshIntegrationStatuses() {
        // Keep provider cards in sync with LLMProviderKind + GitHub
        let wanted = LLMProviderKind.allCases.map {
            AIIntegration(
                name: $0.keychainAccount,
                provider: $0.displayName.uppercased(),
                status: .notConfigured,
                icon: $0.integrationIcon,
                modelHint: $0.defaultModel
            )
        } + [
            AIIntegration(
                name: "GitHub",
                provider: "GITHUB",
                status: .notConfigured,
                icon: "chevron.left.forwardslash.chevron.right",
                modelHint: "OAuth / PAT"
            ),
        ]
        // Merge: prefer Seed order names, add missing
        for w in wanted {
            if !integrations.contains(where: { $0.name == w.name }) {
                integrations.append(w)
            }
        }
        for i in integrations.indices {
            let name = integrations[i].name
            // Non-interactive keychain (no prompt storms). Cache hits after first allow.
            var connected = KeychainStore.hasValue(name)
            if !connected, let kind = LLMProviderKind.allCases.first(where: { $0.keychainAccount == name }) {
                connected = kind.legacyKeychainAccounts.contains { KeychainStore.hasValue($0) }
                // OpenAI ChatGPT OAuth / other LLMClient resolution paths
                if !connected {
                    connected = LLMClient.shared.hasKey(kind)
                }
            }
            if !connected {
                let aliases = ["Grok", "Codex", "Claude", "xAI"]
                if aliases.contains(name) {
                    connected = KeychainStore.hasValue(name)
                }
            }
            if name == "OpenAI", ProviderBrowserAuthService.shared.openAIHasOAuth {
                connected = true
                integrations[i].modelHint = "ChatGPT OAuth"
            }
            integrations[i].status = connected ? .connected : .notConfigured
        }
    }
}

// MARK: - Shell (safe subset)

enum ShellRunner {
    static func run(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return "Errore: \(error.localizedDescription)"
        }
    }
}

// KeychainStore lives in Services/Persistence/KeychainStore.swift
