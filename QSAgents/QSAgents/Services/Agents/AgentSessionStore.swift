import Foundation
import Combine

/// Outcome of board "Avvia" — avoids spawning a new PTY/agent every click.
enum TaskLaunchResult: Equatable {
    case failed(String)
    case alreadyRunning(agentName: String)
    case resumed(agentName: String)
    case started(agentName: String)

    var ok: Bool {
        if case .failed = self { return false }
        return true
    }

    var agentName: String? {
        switch self {
        case .failed: return nil
        case .alreadyRunning(let n), .resumed(let n), .started(let n): return n
        }
    }
}

/// Multi-agent session (Fase 3) — local bootstrap + optional LLM tool loop.
struct AgentSession: Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: AgentRole
    /// Display label and preferred model id (e.g. gpt-4.1 or grok-4.5).
    /// Raw model id for the API (e.g. `anthropic/claude-opus-4.8`) — never a UI label.
    var model: String
    /// Optional provider override for this session (LLMProviderKind.rawValue).
    var providerRaw: String?

    /// UI label: `OpenRouter/anthropic/claude-opus-4.8` (safe — not sent to the API).
    var modelDisplayLabel: String {
        if let raw = providerRaw, let p = LLMProviderKind(rawValue: raw) {
            return "\(p.displayName)/\(model)"
        }
        return model
    }
    var status: AgentStatus
    var workspacePath: String?
    var taskId: UUID?
    /// Real PTY pane opened for this agent (tool I/O is mirrored there).
    var linkedTerminalID: UUID?
    var lines: [TerminalLine]
    var progress: Double
    var tokenUsage: Int
    var createdAt: Date
    var lastGoal: String?

    init(
        id: UUID = UUID(),
        name: String,
        role: AgentRole = .builder,
        model: String = "local",
        providerRaw: String? = nil,
        status: AgentStatus = .idle,
        workspacePath: String? = nil,
        taskId: UUID? = nil,
        linkedTerminalID: UUID? = nil,
        lines: [TerminalLine] = [],
        progress: Double = 0,
        tokenUsage: Int = 0,
        createdAt: Date = .now,
        lastGoal: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.model = model
        self.providerRaw = providerRaw
        self.status = status
        self.workspacePath = workspacePath
        self.taskId = taskId
        self.linkedTerminalID = linkedTerminalID
        self.lines = lines
        self.progress = progress
        self.tokenUsage = tokenUsage
        self.createdAt = createdAt
        self.lastGoal = lastGoal
    }
}

// MARK: - Swarm mission (Lovable/Bolt-style phases)

enum MissionPhase: String, Equatable {
    case planning      // scout + coordinator only
    case awaitingUser  // questions / plan ready — human gate
    case executing     // builders on board tasks
    case done
}

struct SwarmQuestion: Identifiable, Equatable {
    let id: UUID
    var text: String
    var answer: String?
    var at: Date

    init(id: UUID = UUID(), text: String, answer: String? = nil, at: Date = .now) {
        self.id = id
        self.text = text
        self.answer = answer
        self.at = at
    }
}

struct MissionActivityLine: Identifiable, Equatable {
    let id: UUID
    var agentName: String
    var role: String
    var text: String
    var level: LogLevel
    var at: Date

    init(
        id: UUID = UUID(),
        agentName: String,
        role: String,
        text: String,
        level: LogLevel = .info,
        at: Date = .now
    ) {
        self.id = id
        self.agentName = agentName
        self.role = role
        self.text = text
        self.level = level
        self.at = at
    }
}

struct SwarmMission: Identifiable, Equatable {
    let id: UUID
    var goal: String
    var phase: MissionPhase
    var workspacePath: String?
    var taskIds: [UUID]
    var questions: [SwarmQuestion]
    var activity: [MissionActivityLine]
    var coordinatorSummary: String?
    var startedAt: Date
    /// C1/E4: board tasks created by this mission share this plan id (DAG).
    var planId: UUID
    /// Agent session ids spawned for this mission.
    var agentIds: [UUID]
    /// When true, after plan (no open questions) auto-start builders and chain tasks.
    var autoRun: Bool
    /// Task IDs already fully dispatched at least once this mission.
    var dispatchedTaskIds: [UUID]
    /// GOAL MODE: no human gate; on builder stuck → auto-split into mini-tasks; elevated token budget.
    var goalMode: Bool
    /// How many auto-splits already performed this mission.
    var splitCount: Int
    /// Cap on auto-splits (see TokenBudget.goalModeMaxSplits).
    var maxSplits: Int

    var openQuestions: [SwarmQuestion] {
        questions.filter { $0.answer == nil }
    }

    var needsUserGate: Bool {
        // Goal mode never waits on the user.
        if goalMode { return false }
        return !autoRun && (phase == .awaitingUser || !openQuestions.isEmpty)
    }
}

/// E4: live edge agent ↔ task for Swarm DAG UI.
struct SwarmAgentTaskEdge: Identifiable, Equatable {
    let id: UUID
    let agentId: UUID
    let agentName: String
    let role: String
    let status: AgentStatus
    let taskId: UUID?
    let taskTitle: String?
    let taskColumn: TaskColumn?
    let progress: Double
}

@MainActor
final class AgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedID: UUID?
    /// Active multi-agent mission (plan → gate → execute).
    @Published var mission: SwarmMission?
    /// UI preference: next orchestrator send / mission starts in GOAL MODE.
    @Published var goalModePreferred: Bool = false
    /// Throttle antistallo kicks from the orchestrator pulse.
    private var lastStallKickAt: Date?

    weak var terminals: TerminalManager?
    weak var workspaces: WorkspaceStore?
    weak var tasks: TaskStore?
    weak var orchestrator: OrchestratorEngine?
    weak var git: GitService?
    weak var safety: SafetyGuardrails?
    /// B3: durable project memory flush on mission end.
    weak var projectMemory: ProjectMemoryStore?
    /// D1: knowledge FTS for agent search_knowledge tool.
    weak var knowledge: KnowledgeStore?

    let runtime = AgentRuntime()

    var selected: AgentSession? {
        sessions.first { $0.id == selectedID }
    }

    func bindRuntime() {
        runtime.store = self
        runtime.terminals = terminals
        runtime.workspaces = workspaces
        runtime.tasks = tasks
        runtime.git = git
        runtime.safety = safety
        runtime.knowledge = knowledge
    }

    @discardableResult
    func spawn(
        name: String? = nil,
        role: AgentRole = .builder,
        model: String? = nil,
        providerRaw: String? = nil,
        workspacePath: String? = nil,
        taskId: UUID? = nil,
        openTerminal: Bool = true,
        goal: String? = nil,
        runLLM: Bool = false
    ) -> AgentSession {
        bindRuntime()
        let path = AgentToolRunner.sanitizedWorkspace(workspacePath ?? workspaces?.current?.path)
        let n = name ?? "\(role.rawValue)-\(sessions.count + 1)"
        // Resolve model/provider from prefs (Home / Swarm routing) unless explicit.
        // Fall back to any keyed provider so Swarm never starts as «local» when chat has a key.
        let resolved = ProviderPreferences.shared.resolve(for: role)
        let live = ProviderPreferences.shared.anyKeyedProvider()
        let resolvedModel: String = {
            if let model, !model.isEmpty, model != "local" { return model }
            if resolved.model != "local", !resolved.model.isEmpty { return resolved.model }
            return live?.defaultModel ?? resolved.model
        }()
        let resolvedProvider = providerRaw
            ?? resolved.provider?.rawValue
            ?? live?.rawValue
        let providerKind = resolvedProvider.flatMap { LLMProviderKind(rawValue: $0) } ?? resolved.provider ?? live
        let label = providerKind.map { "\($0.displayName)/\(resolvedModel)" } ?? resolvedModel
        var session = AgentSession(
            name: n,
            role: role,
            model: resolvedModel,
            providerRaw: resolvedProvider,
            status: .idle,
            workspacePath: path,
            taskId: taskId,
            lines: [
                TerminalLine(text: "Agent \(n) pronto · ruolo \(role.displayName)", level: .muted),
                TerminalLine(text: "Modello: \(label)", level: .info),
            ],
            lastGoal: goal
        )
        if openTerminal, let path {
            if let term = terminals?.openTerminal(at: path, title: n, role: role) {
                session.linkedTerminalID = term.id
                session.lines.append(TerminalLine(text: "PTY collegato · \(term.cwd) · tool mirrored qui", level: .success))
                session.status = .active
                term.appendAgentEcho(
                    "═══ QS Agent «\(n)» · \(role.displayName) ═══\n" +
                    "I tool LLM (read/patch/cmd) appaiono qui e nella console log sotto.\n" +
                    "Puoi anche digitare comandi a mano in questo shell.\n"
                )
            }
        }
        sessions.insert(session, at: 0)
        selectedID = session.id
        // E4: register agent on active mission
        if var m = mission {
            if !m.agentIds.contains(session.id) {
                m.agentIds.append(session.id)
            }
            mission = m
        }
        if let taskId {
            pushActivity(
                agentName: n,
                role: role.rawValue,
                text: "Link task \(taskId.uuidString.prefix(8)) · \(goal ?? "")",
                level: .info
            )
        }
        AppLogger.info("Agent spawned: \(n) role=\(role.rawValue)")

        if runLLM, let goal {
            runtime.runGoal(sessionId: session.id, goal: goal, workspace: path)
        }
        return session
    }

    // MARK: - E4 Swarm ↔ Tasks DAG

    /// Live edges for canvas / DAG panel.
    func liveEdges() -> [SwarmAgentTaskEdge] {
        sessions.map { s in
            let t = s.taskId.flatMap { tasks?.task(id: $0) }
            return SwarmAgentTaskEdge(
                id: s.id,
                agentId: s.id,
                agentName: s.name,
                role: s.role.rawValue,
                status: s.status,
                taskId: s.taskId,
                taskTitle: t?.title ?? (s.taskId != nil ? "(task)" : nil),
                taskColumn: t?.column,
                progress: s.progress
            )
        }
    }

    /// Mission board tasks not yet claimed by an agent.
    func unassignedMissionTasks() -> [AgentTask] {
        guard let m = mission, let tasks else { return [] }
        let claimed = Set(sessions.compactMap(\.taskId))
        return m.taskIds.compactMap { tid in
            guard !claimed.contains(tid), let t = tasks.task(id: tid) else { return nil }
            return t
        }
    }

    /// Shared plan id for create_task during mission (DAG chain).
    func ensureMissionPlanId() -> UUID? {
        guard var m = mission else { return nil }
        // planId is non-optional on SwarmMission
        mission = m
        return m.planId
    }

    func missionPlanId() -> UUID? { mission?.planId }

    func lastMissionTaskId() -> UUID? { mission?.taskIds.last }

    func append(_ id: UUID, _ text: String, level: LogLevel = .info) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Keep enough for Swarm/Terminali console copy (was 2k — tool dumps looked truncated vs full capsule)
        let line = text.count > 16_000 ? String(text.prefix(16_000)) + "\n… [log troncato a 16k]" : text
        sessions[i].lines.append(TerminalLine(text: line, level: level))
        if sessions[i].lines.count > 600 {
            sessions[i].lines.removeFirst(sessions[i].lines.count - 600)
        }
        // Global mission activity feed (Lovable/Bolt-style live log)
        pushActivity(
            agentName: sessions[i].name,
            role: sessions[i].role.rawValue,
            text: line,
            level: level
        )
    }

    func pushActivity(agentName: String, role: String, text: String, level: LogLevel) {
        guard var m = mission else { return }
        let entry = MissionActivityLine(agentName: agentName, role: role, text: text, level: level)
        m.activity.insert(entry, at: 0)
        if m.activity.count > 150 {
            m.activity = Array(m.activity.prefix(150))
        }
        mission = m
    }

    func recordMissionTask(_ task: AgentTask) {
        guard var m = mission else { return }
        if !m.taskIds.contains(task.id) {
            m.taskIds.append(task.id)
        }
        if m.phase == .planning {
            m.phase = .awaitingUser
        }
        mission = m
        pushActivity(
            agentName: "board",
            role: "tasks",
            text: "Task #\(m.taskIds.count) → board: \(task.title)",
            level: .success
        )
        // Ensure task is tagged with mission planId (if created without it)
        if task.planId == nil {
            tasks?.setPlanId(task.id, planId: m.planId)
        }
    }

    func addMissionQuestion(_ text: String) {
        guard var m = mission else { return }
        m.questions.append(SwarmQuestion(text: text))
        m.phase = .awaitingUser
        mission = m
        pushActivity(agentName: "coord", role: "coordinator", text: "Domanda: \(text)", level: .thinking)
    }

    func answerQuestion(id: UUID, answer: String) {
        guard var m = mission, let i = m.questions.firstIndex(where: { $0.id == id }) else { return }
        let questionText = m.questions[i].text
        m.questions[i].answer = answer
        mission = m
        pushActivity(
            agentName: "you",
            role: "user",
            text: "Risposta: \(answer)",
            level: .info
        )
        if let coord = sessions.first(where: { $0.role == .coordinator }) {
            append(coord.id, "Utente ha risposto: \(answer)", level: .success)
            runtime.runGoal(
                sessionId: coord.id,
                goal: """
                L'utente ha risposto alla tua domanda.
                Domanda: \(questionText)
                Risposta: \(answer)
                Aggiorna il piano: crea_task se serve, poi finish con il riepilogo.
                """,
                workspace: m.workspacePath ?? coord.workspacePath
            )
        }
    }

    /// Any agent loop finished — advance plan or mission pipeline.
    /// - Parameter taskCompleted: structured flag from Runtime when `complete_task` succeeded (BUG-014).
    func agentDidFinish(sessionId: UUID, summary: String, taskCompleted: Bool = false) {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return }
        guard var m = mission else { return }

        // Planning phase: coordinator done
        if m.phase == .planning || m.phase == .awaitingUser {
            if s.role == .coordinator {
                m.coordinatorSummary = Self.sanitizeCoordinatorSummary(summary)
                // Goal mode: ignore open questions — never block on the user.
                if m.goalMode {
                    m.questions = m.questions.map { q in
                        var qq = q
                        if qq.answer == nil { qq.answer = "(goal mode: skip)" }
                        return qq
                    }
                    m.phase = .awaitingUser
                    mission = m
                    let path = m.workspacePath ?? workspaces?.current?.path
                    mergeOpenBoardTasksIntoMission(workspacePath: path)
                    // Critical: if coord finished without create_task, board stays empty and
                    // builders loop on the failure text («non hai creato le task card»).
                    if (mission?.taskIds.isEmpty ?? true) {
                        let seeded = seedMissionTasksIfEmpty(reason: "coord-finish-senza-create_task")
                        pushActivity(
                            agentName: "system",
                            role: "goal",
                            text: seeded > 0
                                ? "Coord senza create_task → seed \(seeded) card su QS Tasks"
                                : "Coord senza create_task e seed fallito — ritento coord una volta",
                            level: .warning
                        )
                        if seeded == 0,
                           let coord = sessions.first(where: { $0.role == .coordinator }),
                           !(mission?.activity.contains(where: { $0.text.contains("FORCE create_task") }) ?? false) {
                            pushActivity(
                                agentName: "system",
                                role: "goal",
                                text: "FORCE create_task — ritento coordinatore",
                                level: .thinking
                            )
                            runtime.runGoal(
                                sessionId: coord.id,
                                goal: """
                                OBBLIGO ASSOLUTO: chiama create_task 3–5 volte ORA (JSON tool), poi finish.
                                Goal: \(m.goal)
                                \(boardSnapshotForPrompt(workspacePath: path))
                                Ogni task: titolo chiaro + subtitle con path TRACKED (root/src, mai www/).
                                Esempio: {"tool":"create_task","title":"Patch X","subtitle":"file.css around LINE","priority":"alto"}
                                VIETATO finish senza aver creato le card. VIETATO dire «non hai creato le task».
                                """,
                                workspace: path
                            )
                            return
                        }
                    }
                    let local = summary.lowercased().contains("local bootstrap")
                    pushActivity(
                        agentName: s.name,
                        role: s.role.rawValue,
                        text: local
                            ? "GOAL MODE · coord senza LLM — salto al board (builder)"
                            : "GOAL MODE · piano pronto — avvio builder senza gate",
                        level: .success
                    )
                    orchestrator?.notifyGoalMode(
                        local ? "Coord locale → builder su board" : "Piano pronto → builder automatici"
                    )
                    approveAndExecuteBuilders(builderCount: 2)
                    return
                }
                m.phase = .awaitingUser
                mission = m
                if m.openQuestions.isEmpty, m.autoRun {
                    pushActivity(
                        agentName: s.name,
                        role: s.role.rawValue,
                        text: "Piano pronto — auto-run builder (nessuna domanda aperta)",
                        level: .success
                    )
                    approveAndExecuteBuilders(builderCount: 2)
                } else {
                    pushActivity(
                        agentName: s.name,
                        role: s.role.rawValue,
                        text: m.openQuestions.isEmpty
                            ? "Piano pronto — premi «Avvia builder» (o attiva auto-run)"
                            : "Piano pronto — rispondi alle domande, poi builder",
                        level: .success
                    )
                }
            }
            return
        }

        // Executing: builder/reviewer finished → chain next task / close mission
        if m.phase == .executing {
            pushActivity(
                agentName: s.name,
                role: s.role.rawValue,
                text: "Loop finito: \(String(summary.prefix(120)))",
                level: .muted
            )
            // GOAL MODE: stuck builder → split into mini-tasks (don't wait for user).
            if m.goalMode, s.role == .builder, Self.isStuckSummary(summary) {
                if handleGoalModeStuck(session: s, summary: summary) {
                    return
                }
            }
            // Mark linked task — DONE only via structured complete_task flag (BUG-014), never Italian substrings.
            // Note: successful complete_task already called TaskStore.complete — skip double auto-advance.
            if s.role == .builder, let tid = s.taskId, let t = tasks?.task(id: tid),
               t.column == .inProgress || t.column == .todo {
                if taskCompleted {
                    _ = tasks?.complete(tid)
                    tasks?.appendEvidence(tid, "complete_task-ok")
                } else {
                    tasks?.move(tid, to: .review)
                }
            } else if taskCompleted, let tid = s.taskId {
                tasks?.appendEvidence(tid, "complete_task-ok")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.advanceMissionPipeline()
            }
        }
    }

    /// Kick stalled GOAL/auto-run missions (called from orchestrator pulse).
    func kickStalledMissionIfNeeded() {
        guard let m = mission, m.phase != .done else { return }
        let busy = sessions.contains { $0.status == .thinking || $0.status == .active }
        guard !busy else { return }
        // Non-GOAL: never bypass unanswered coordinator questions
        guard m.goalMode || (m.autoRun && m.openQuestions.isEmpty) else { return }
        if let last = lastStallKickAt, Date().timeIntervalSince(last) < 5 { return }
        lastStallKickAt = Date()

        if m.phase == .planning || m.phase == .awaitingUser {
            if !m.goalMode, !m.openQuestions.isEmpty { return }
            pushActivity(
                agentName: "system",
                role: "goal",
                text: "Antistallo · fase \(m.phase.rawValue) con agent idle → forzo builder",
                level: .warning
            )
            orchestrator?.notifyGoalMode("Antistallo planning → builder")
            approveAndExecuteBuilders(builderCount: 2)
            return
        }
        if m.phase == .executing {
            advanceMissionPipeline()
        }
    }

    private static func isStuckSummary(_ summary: String) -> Bool {
        let s = summary.lowercased()
        let markers = [
            "token budget", "max steps", "empty llm", "llm error",
            "tool json", "cancelled", "budget token",
        ]
        return markers.contains { s.contains($0) }
    }

    /// Don't feed builders a coord failure rant («non hai creato le task card»).
    private static func sanitizeCoordinatorSummary(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        if low.contains("local bootstrap") || low.contains("no llm key") {
            return "Coord senza LLM (bootstrap locale) — i builder usano la key in Integrazioni/routing Swarm. Non è un errore se vedi Anthropic/Grok nei log builder."
        }
        let bad = [
            "non hai creato", "non ho creato", "nessuna task", "no task card",
            "task card", "senza task", "mancano le task", "board vuot",
        ]
        if bad.contains(where: { low.contains($0) }) {
            return "Piano: spezza il goal in patch piccole su file tracked (root/src). Usa le card QS Tasks."
        }
        return String(s.prefix(400))
    }

    /// Live board view for the coordinator prompt (so it cannot "guess" empty/full).
    private func boardSnapshotForPrompt(workspacePath path: String?) -> String {
        let open = openBoardTasks(workspacePath: path)
        if open.isEmpty {
            return "BOARD QS Tasks (questo workspace): VUOTO → DEVI chiamare create_task 3–6 volte ORA."
        }
        let lines = open.prefix(10).map { t in
            "- [\(t.column.rawValue)] \(String(t.title.prefix(70)))"
        }
        return """
        BOARD QS Tasks aperte (\(open.count)) — NON duplicare; i builder riprendono queste:
        \(lines.joined(separator: "\n"))
        Solo se il goal chiede lavoro NUOVO fuori da queste card: create_task aggiuntive.
        """
    }

    /// When the LLM skips create_task, still put cards on QS Tasks so the pipeline can run.
    @discardableResult
    private func seedMissionTasksIfEmpty(reason: String, forceNew: Bool = false) -> Int {
        guard var m = mission, let tasks else { return 0 }
        let path = AgentToolRunner.sanitizedWorkspace(m.workspacePath ?? workspaces?.current?.path)
        if !forceNew {
            mergeOpenBoardTasksIntoMission(workspacePath: path)
            if let cur = mission, !cur.taskIds.isEmpty { return cur.taskIds.count }
        }
        guard let path else { return 0 }

        let g = m.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(g.prefix(42))
        let gl = g.lowercased()
        let uiPlay = gl.contains("play") || gl.contains("pulsante") || gl.contains("button")
            || gl.contains("home") || gl.contains("verde")
        // One card only — Locate→Patch→Verify cascade was the bottleneck (LOCAL + REVIEW spam).
        let uiHint = uiPlay
            ? "TARGET: premium-ui.js + premium-ui.css (.p-big-play). VIETATO premium-home-mobile-buttons.css (non linkato)."
            : "path TRACKED root/src"
        let builderModel = ProviderPreferences.shared.model(for: .builder)
        let title = "Patch · \(short)"
        let sub = "Come Cursor: \(uiHint) propose_patch → apply_patch → git_status → complete_task. Goal: \(String(g.prefix(160)))"
        let created = tasks.add(
            title: title,
            subtitle: sub,
            column: .todo,
            priority: .alto,
            model: builderModel == "local" ? (ProviderPreferences.shared.anyKeyedProvider()?.defaultModel ?? "openrouter") : builderModel,
            workspacePath: path,
            source: .orchestrator,
            evidence: ["system-seed", reason, "ws:\(path)", "single-patch"],
            planId: m.planId,
            dependsOn: []
        )
        if !m.taskIds.contains(created.id) {
            m.taskIds.append(created.id)
        }
        let count = 1
        mission = m
        AppLogger.info("seedMissionTasksIfEmpty · \(count) · \(reason)")
        return count
    }

    /// Split a stuck task into scout → patch → verify mini-tasks and start the first.
    @discardableResult
    private func handleGoalModeStuck(session: AgentSession, summary: String) -> Bool {
        guard var m = mission, m.goalMode else { return false }
        // Hard stop earlier: recursive Locate→Locate burns hundreds of k tokens without UI change.
        let effectiveMax = min(m.maxSplits, 2)
        if m.splitCount >= effectiveMax {
            pushActivity(
                agentName: "system",
                role: "goal",
                text: "GOAL MODE · stop split (\(m.splitCount)/\(effectiveMax)) — \(String(summary.prefix(60))). Niente altro auto-split: apri il log o una sola Patch manuale.",
                level: .warning
            )
            orchestrator?.notifyGoalMode("Stop split (evita loop token). Intervento umano.")
            return false
        }

        let path = m.workspacePath ?? workspaces?.current?.path
        let parent = session.taskId.flatMap { tasks?.task(id: $0) }
        let parentTitle = parent?.title ?? session.lastGoal ?? m.goal
        let parentDetail = parent?.subtitle ?? ""

        // Already a mini-task that hit token budget → one focused Patch, never another Locate cascade.
        let parentBlob = (parentTitle + " " + parentDetail).lowercased()
        let alreadyMini = parentBlob.contains("locate") || parentBlob.contains("· patch")
            || parentBlob.contains("verify") || parentBlob.contains("verifica")
            || (parent?.evidence.contains(where: { $0.hasPrefix("goal-split") }) ?? false)

        if let tid = parent?.id {
            tasks?.move(tid, to: .review)
            tasks?.appendEvidence(tid, "stuck-abandoned:\(String(summary.prefix(80)))")
            tasks?.appendEvidence(tid, "goal-split-parent")
        }

        let slices = Self.heuristicMiniTasks(
            title: parentTitle,
            detail: parentDetail,
            stuckReason: summary,
            missionGoal: m.goal,
            singleShot: alreadyMini || summary.lowercased().contains("token budget")
        )
        var newIds: [UUID] = []
        var prev: UUID?
        for (idx, slice) in slices.enumerated() {
            let deps: [UUID] = prev.map { [$0] } ?? []
            let created = tasks?.add(
                title: slice.title,
                subtitle: slice.subtitle,
                column: .todo,
                priority: parent?.priority ?? .medio,
                model: parent?.assigneeModel ?? "local",
                workspacePath: path ?? parent?.workspacePath,
                source: .orchestrator,
                evidence: [
                    "goal-split",
                    "split#\(m.splitCount + 1)",
                    "from:\(String(parentTitle.prefix(40)))",
                    "reason:\(String(summary.prefix(60)))",
                ],
                planId: m.planId,
                dependsOn: deps
            )
            if let created {
                newIds.append(created.id)
                prev = created.id
                _ = idx
            }
        }
        guard !newIds.isEmpty else { return false }

        m.taskIds.append(contentsOf: newIds)
        m.splitCount += 1
        mission = m

        let names = slices.map(\.title).joined(separator: " → ")
        pushActivity(
            agentName: "system",
            role: "goal",
            text: "GOAL MODE · split #\(m.splitCount): \(names)",
            level: .thinking
        )
        orchestrator?.notifyGoalMode("Builder bloccato (\(summary.prefix(40))) → \(newIds.count) mini-task")

        if let first = newIds.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.startTask(first)
            }
        }
        return true
    }

    private static func heuristicMiniTasks(
        title: String,
        detail: String,
        stuckReason: String,
        missionGoal: String,
        singleShot: Bool = false
    ) -> [(title: String, subtitle: String)] {
        let short = String(missionGoal.prefix(42))
        let scope = detail.isEmpty ? String(missionGoal.prefix(160)) : String(detail.prefix(200))
        let why = String(stuckReason.prefix(80))
        let g = missionGoal.lowercased()
        let uiPlay = g.contains("play") || g.contains("pulsante") || g.contains("button")
            || g.contains("home") || g.contains("verde")
        let uiTarget = uiPlay
            ? "TARGET OBBLIGATO: premium-ui.js (#pContinueButton / .p-big-play) + premium-ui.css. VIETATO premium-home-mobile-buttons.css (non linkato in index — effetto zero)."
            : "UN file tracked root/src (mai www/)."

        // After token-budget / nested split: one Patch only (Cursor-style), no Locate→Verify cascade.
        if singleShot {
            return [(
                "Patch · \(short)",
                "\(uiTarget) read_file around → propose_patch → apply_patch → git_status → complete_task. Reason: \(why). Scope: \(scope)"
            )]
        }

        return [
            (
                "Locate · \(short)",
                "SOLO repo_capsule + search_knowledge. Path TRACKED; se UI: \(uiTarget) Elenca id/class + line. No patch. Split: \(why)"
            ),
            (
                "Patch · \(short)",
                "Come Cursor: \(uiTarget) propose_patch → apply_patch. Scope: \(scope)"
            ),
            (
                "Verify · \(short)",
                "git_status deve listare i path applicati (es. premium-ui.css). Se clean o solo mobile-buttons non linkato → ripatcha, non complete."
            ),
        ]
    }

    /// After a builder frees up: assign next work (IN CORSO orphans first), never stall on blocked TODOs.
    func advanceMissionPipeline() {
        guard var m = mission, m.phase == .executing else { return }
        bindRuntime()
        guard let tasks else { return }

        let path = m.workspacePath ?? workspaces?.current?.path
        // Pull open board tasks into the mission so GOAL doesn't ignore IN CORSO / REVIEW.
        mergeOpenBoardTasksIntoMission(workspacePath: path)

        let busyTaskIds = Set(
            sessions
                .filter { $0.role == .builder && ($0.status == .thinking || $0.status == .active) }
                .compactMap(\.taskId)
        )

        guard let m2 = mission else { return }
        m = m2
        let boardTasks = m.taskIds.compactMap { tasks.task(id: $0) }
        let remaining = boardTasks.filter { $0.column != .done && !Self.isAbandonedTask($0) }
        let noneRunning = !sessions.contains { $0.status == .thinking || $0.status == .active }

        let next = pickNextMissionTask(
            remaining: remaining,
            busyTaskIds: busyTaskIds,
            tasks: tasks
        )

        if let next {
            if next.column == .done { return }
            let label: String = {
                switch next.column {
                case .inProgress: return "Riprendo IN CORSO"
                case .review: return "Rilancio REVIEW"
                default: return "Assegno"
                }
            }()
            pushActivity(
                agentName: "coord",
                role: "orchestrator",
                text: "\(label) → \(next.title)",
                level: .thinking
            )
            // Reuse idle builder if any
            if let idle = sessions.first(where: {
                $0.role == .builder && $0.status == .idle
            }) {
                let wasInFlight = next.column == .inProgress || next.column == .review
                if let i = sessions.firstIndex(where: { $0.id == idle.id }) {
                    sessions[i].taskId = next.id
                    sessions[i].lastGoal = next.title
                    sessions[i].status = .thinking
                }
                if !m.taskIds.contains(next.id) { m.taskIds.append(next.id) }
                if !m.dispatchedTaskIds.contains(next.id) {
                    m.dispatchedTaskIds.append(next.id)
                }
                mission = m
                _ = tasks.move(next.id, to: .inProgress)
                runtime.runTask(
                    sessionId: idle.id,
                    taskTitle: next.title,
                    taskId: next.id,
                    workspace: path ?? next.workspacePath,
                    missionGoal: m.goal,
                    taskSubtitle: next.subtitle,
                    coordinatorSummary: m.coordinatorSummary,
                    resume: wasInFlight
                )
            } else if sessions.filter({ $0.role == .builder }).count < 4 {
                // startTask handles deps for fresh TODO; blockers already preferred above
                if next.column == .todo, !tasks.canStart(next.id).ok {
                    // Shouldn't happen if pickNext is correct — try blocker once more
                    if let blocker = firstOpenBlocker(of: next, tasks: tasks, busy: busyTaskIds) {
                        _ = startTask(blocker.id)
                    }
                    return
                }
                _ = startTask(next.id)
                if var mm = mission, !mm.dispatchedTaskIds.contains(next.id) {
                    mm.dispatchedTaskIds.append(next.id)
                    mission = mm
                }
            }
            return
        }

        // No assignable work right now
        let allDone = !boardTasks.isEmpty && boardTasks.allSatisfy { $0.column == .done || Self.isAbandonedTask($0) }
        if allDone && noneRunning {
            m.phase = .done
            mission = m
            pushActivity(
                agentName: "system",
                role: "mission",
                text: "Missione completata — tutte le task DONE",
                level: .success
            )
            if m.goalMode {
                orchestrator?.notifyGoalMode("Goal raggiunto ✓ — tutte le mini-task DONE")
            }
            persistMissionToProjectMemory(reason: "missionComplete")
            return
        }

        // Still open work but nothing runnable + nobody running → don't close; chase blockers / nudge
        if !remaining.isEmpty && noneRunning {
            // Never auto-relaunch REVIEW (bootstrap / QA pile) — that caused PTY×100 + token loops.
            if let forced = remaining.first(where: {
                $0.column == .inProgress && !Self.isAbandonedTask($0)
            }) ?? remaining.first(where: {
                $0.column == .todo && tasks.isUnblocked($0) && !Self.isAbandonedTask($0)
            }) {
                pushActivity(
                    agentName: "system",
                    role: m.goalMode ? "goal" : "mission",
                    text: "Antistallo → forzo ripresa «\(forced.title)»",
                    level: .warning
                )
                if m.goalMode {
                    orchestrator?.notifyGoalMode("Antistallo · riprendo \(forced.title)")
                }
                _ = startTask(forced.id)
                return
            }
            let onlyReviewLeft = remaining.allSatisfy { $0.column == .review || Self.isAbandonedTask($0) }
            if onlyReviewLeft {
                pushActivity(
                    agentName: "system",
                    role: "goal",
                    text: "Solo task IN REVISIONE restanti — stop auto. Avvia a mano o Pulisci revisione.",
                    level: .warning
                )
                if m.goalMode {
                    orchestrator?.notifyGoalMode("Stop: solo REVIEW in coda (no auto-rilancio)")
                }
                return
            }
            // Truly blocked (deps missing/broken) — mark review and keep hunting TODOs
            if let stuck = remaining.first(where: { $0.column == .todo }) {
                tasks.move(stuck.id, to: .review)
                tasks.appendEvidence(stuck.id, "pipeline-unstick:deps")
                pushActivity(
                    agentName: "system",
                    role: "goal",
                    text: "Task bloccata da dipendenze → REVIEW «\(stuck.title)» — continuo sulle altre",
                    level: .warning
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.advanceMissionPipeline()
                }
            }
        }
    }

    private static func isAbandonedTask(_ t: AgentTask) -> Bool {
        t.evidence.contains(where: {
            $0.hasPrefix("stuck-abandoned")
                || $0.hasPrefix("goal-split-parent")
                || $0.hasPrefix("local-bootstrap-dead")
        })
    }

    /// Priority: orphan IN CORSO → unblocked TODO → open dependency of a blocked TODO.
    /// Never auto-dispatch REVIEW (human QA / failed bootstrap) — only explicit Avvia.
    private func pickNextMissionTask(
        remaining: [AgentTask],
        busyTaskIds: Set<UUID>,
        tasks: TaskStore
    ) -> AgentTask? {
        let free: (AgentTask) -> Bool = { !busyTaskIds.contains($0.id) }

        if let orphan = remaining.first(where: {
            $0.column == .inProgress && free($0) && !Self.isAbandonedTask($0)
        }) {
            return orphan
        }

        let todos = remaining.filter {
            $0.column == .todo && free($0) && tasks.canStart($0.id).ok && !Self.isAbandonedTask($0)
        }
        if let t = todos.first { return t }

        // Blocked TODOs: chase their open deps (IN CORSO / TODO only — never REVIEW relaunch)
        for blocked in remaining where blocked.column == .todo && !tasks.canStart(blocked.id).ok {
            if let blocker = firstOpenBlocker(of: blocked, tasks: tasks, busy: busyTaskIds),
               blocker.column != .review {
                return blocker
            }
        }
        return nil
    }

    private func firstOpenBlocker(
        of task: AgentTask,
        tasks: TaskStore,
        busy: Set<UUID>
    ) -> AgentTask? {
        for depId in task.dependsOn {
            guard let dep = tasks.task(id: depId), dep.column != .done else { continue }
            if busy.contains(dep.id) { continue }
            if Self.isAbandonedTask(dep) { continue }
            return dep
        }
        return nil
    }

    /// Ensure mission.taskIds includes open board cards for this workspace (IN CORSO / TODO / REVIEW).
    private func mergeOpenBoardTasksIntoMission(workspacePath path: String?) {
        guard var m = mission, let tasks else { return }
        let open = openBoardTasks(workspacePath: path)
        var changed = false
        for t in open where !m.taskIds.contains(t.id) {
            m.taskIds.append(t.id)
            changed = true
        }
        if changed {
            mission = m
            pushActivity(
                agentName: "system",
                role: m.goalMode ? "goal" : "mission",
                text: "Board sync · \(open.count) task aperte in missione (anche IN CORSO)",
                level: .muted
            )
        }
    }

    private func openBoardTasks(workspacePath path: String?) -> [AgentTask] {
        guard let tasks else { return [] }
        let root = path.map { ($0 as NSString).standardizingPath }
        let open = tasks.tasks.filter { t in
            guard t.column == .todo || t.column == .inProgress || t.column == .review else { return false }
            if Self.isAbandonedTask(t) { return false }
            guard let root else { return true }
            guard let wp = t.workspacePath, !wp.isEmpty else { return true }
            return (wp as NSString).standardizingPath == root
        }
        // IN CORSO first, then unblocked TODO, then REVIEW, then blocked TODO
        let ranked: [(AgentTask, Int)] = open.map { t in
            let r: Int
            switch t.column {
            case .inProgress: r = 0
            case .todo:
                // Inline DAG check (avoid MainActor hop inside sorted closure)
                let blocked = t.dependsOn.contains { depId in
                    guard let dep = tasks.task(id: depId) else { return true }
                    return dep.column != .done
                }
                r = blocked ? 3 : 1
            case .review: r = 2
            case .done: r = 9
            }
            return (t, r)
        }
        return ranked
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.title < b.0.title }
            .map(\.0)
    }

    /// Human gate or auto-run: start builders on mission tasks (or all TODO if none tagged).
    func approveAndExecuteBuilders(builderCount: Int = 2) {
        guard var m = mission else { return }
        if m.phase == .executing {
            // Already running — just top up pipeline
            advanceMissionPipeline()
            return
        }
        bindRuntime()
        let path = m.workspacePath ?? workspaces?.current?.path
        m.phase = .executing
        mission = m
        pushActivity(
            agentName: "system",
            role: "mission",
            text: m.autoRun ? "Auto-run: avvio builder e catena task" : "Esecuzione approvata — avvio builder",
            level: .thinking
        )

        mergeOpenBoardTasksIntoMission(workspacePath: path)
        var taskIds = mission?.taskIds ?? m.taskIds
        if taskIds.isEmpty {
            // Fallback: open board cards — IN CORSO first, not only DA FARE
            taskIds = openBoardTasks(workspacePath: path)
                .prefix(8)
                .map(\.id)
            mission?.taskIds = taskIds
        } else {
            // Re-order so builders hit IN CORSO / unblocked roots before blocked TODOs
            let ordered = openBoardTasks(workspacePath: path)
                .map(\.id)
                .filter { taskIds.contains($0) }
            let extras = taskIds.filter { !ordered.contains($0) }
            taskIds = ordered + extras
            mission?.taskIds = taskIds
        }

        if taskIds.isEmpty {
            // Never launch free builders without board cards — that caused the
            // «non hai creato le task card» loop (failure text became the goal).
            let seeded = seedMissionTasksIfEmpty(reason: "approve-empty-board")
            taskIds = mission?.taskIds ?? []
            if taskIds.isEmpty {
                pushActivity(
                    agentName: "system",
                    role: "mission",
                    text: "Impossibile avviare builder: QS Tasks vuoto (seed=\(seeded)). Rilancia GOAL o crea card a mano.",
                    level: .warning
                )
                orchestrator?.notifyGoalMode("Blocco: nessuna task su board")
                return
            }
        }
        if !taskIds.isEmpty {
            // One builder per task (cap) — all get full mission+task brief
            for (idx, tid) in taskIds.prefix(4).enumerated() {
                if let task = tasks?.tasks.first(where: { $0.id == tid }) {
                    if idx == 0 {
                        startTask(tid)
                    } else {
                        if tasks?.canStart(tid).ok != true {
                            pushActivity(
                                agentName: "system",
                                role: "tasks",
                                text: "Skip \(task.title) — dipendenze aperte",
                                level: .muted
                            )
                            continue
                        }
                        tasks?.move(tid, to: .inProgress)
                        let a = spawn(
                            name: "builder-\(idx + 1)",
                            role: .builder,
                            workspacePath: path,
                            taskId: tid,
                            openTerminal: false,
                            goal: task.title,
                            runLLM: false
                        )
                        runtime.runTask(
                            sessionId: a.id,
                            taskTitle: task.title,
                            taskId: tid,
                            workspace: path,
                            missionGoal: m.goal,
                            taskSubtitle: task.subtitle,
                            coordinatorSummary: m.coordinatorSummary
                        )
                    }
                }
            }
        }

        // Reviewer only after builders in non-goal missions — in GOAL it was a key/bootstrap bottleneck.
        if m.goalMode != true {
            let reviewer = spawn(
                name: "reviewer-1",
                role: .reviewer,
                workspacePath: path,
                openTerminal: false,
                goal: m.goal,
                runLLM: false
            )
            let rev = sessions.first(where: { $0.id == reviewer.id }) ?? reviewer
            runtime.runGoal(
                sessionId: reviewer.id,
                goal: contextualWorkBrief(
                    for: rev,
                    userInstruction: "Review rischi e checklist PR sulle task della missione. No patch. finish con note actionable."
                ),
                workspace: path
            )
        }

        // Seed dispatched set for tasks we just started
        if var mm = mission {
            for tid in taskIds.prefix(4) {
                if !mm.dispatchedTaskIds.contains(tid) {
                    mm.dispatchedTaskIds.append(tid)
                }
            }
            mission = mm
        }
    }

    func setMissionAutoRun(_ enabled: Bool) {
        guard var m = mission else { return }
        m.autoRun = enabled
        mission = m
        pushActivity(
            agentName: "you",
            role: "user",
            text: enabled ? "Auto-run ON — coord assegna le task da solo" : "Auto-run OFF — serve «Avvia builder»",
            level: .info
        )
        if enabled, m.phase == .awaitingUser, m.openQuestions.isEmpty {
            approveAndExecuteBuilders()
        }
    }

    func dismissMissionGateKeepPlanning() {
        // Stay in awaitingUser without launching builders
        pushActivity(agentName: "you", role: "user", text: "Solo piano/task — builder non avviati", level: .muted)
    }

    func setStatus(_ id: UUID, _ status: AgentStatus) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].status = status
    }

    func setProgress(_ id: UUID, _ p: Double) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].progress = min(1, max(0, p))
    }

    func setModel(_ id: UUID, _ model: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].model = model
    }

    func setProviderAndModel(_ id: UUID, providerRaw: String, model: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].providerRaw = providerRaw
        sessions[i].model = model
    }

    func addTokens(_ id: UUID, _ n: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let add = max(0, n)
        sessions[i].tokenUsage += add
        if add > 0, let tid = sessions[i].taskId {
            tasks?.addUsage(tid, tokens: add)
        }
    }

    func stop(_ id: UUID) {
        runtime.cancel(id)
        // Always force UI to idle even if loop was stuck mid-await
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].status = .idle
            sessions[i].progress = 0
            sessions[i].lines.append(TerminalLine(text: "⏹ Stop richiesto", level: .warning))
            if sessions[i].lines.count > 120 {
                sessions[i].lines.removeFirst(sessions[i].lines.count - 120)
            }
            pushActivity(
                agentName: sessions[i].name,
                role: sessions[i].role.rawValue,
                text: "Stop",
                level: .warning
            )
        }
        AppLogger.info("Agent stop: \(id.uuidString.prefix(8))")
    }

    /// Stop every session (running or not) — cancel in-flight LLM loops.
    func stopAll() {
        runtime.cancelAll()
        for i in sessions.indices {
            sessions[i].status = .idle
            sessions[i].progress = 0
            sessions[i].lines.append(TerminalLine(text: "⏹ Stop tutti", level: .warning))
        }
        pushActivity(agentName: "system", role: "mission", text: "Stop tutti gli agent", level: .warning)
        AppLogger.info("Agent stopAll · \(sessions.count) sessions")
    }

    /// Remove one agent from Swarm (stops loop first).
    func remove(_ id: UUID) {
        runtime.cancel(id)
        let name = sessions.first(where: { $0.id == id })?.name ?? id.uuidString.prefix(8).description
        sessions.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = sessions.first?.id
        }
        if var m = mission {
            m.agentIds.removeAll { $0 == id }
            mission = m
        }
        pushActivity(agentName: "system", role: "mission", text: "Rimosso agent \(name)", level: .muted)
        AppLogger.info("Agent removed: \(name)")
    }

    /// PTY tab closed → drop linked Swarm agents and fold their log into the board task (memory).
    func handleTerminalClosed(_ terminalId: UUID) {
        let linked = sessions.filter { $0.linkedTerminalID == terminalId }
        guard !linked.isEmpty else { return }
        for s in linked {
            persistAgentTraceToTask(s)
            remove(s.id)
        }
        pushActivity(
            agentName: "system",
            role: "control",
            text: "PTY chiuso → \(linked.count) agent rimossi da Swarm (trace salvata sulla task)",
            level: .muted
        )
    }

    /// Save a short agent log slice onto the board task so future Avvia can recall it.
    private func persistAgentTraceToTask(_ session: AgentSession) {
        guard let tid = session.taskId, let tasks else { return }
        let useful = session.lines
            .filter { $0.level == .success || $0.level == .info || $0.level == .thinking || $0.level == .warning }
            .suffix(8)
            .map { String($0.text.prefix(120)) }
        guard !useful.isEmpty else { return }
        tasks.appendEvidence(tid, "agent-trace:\(session.name)")
        for line in useful.prefix(5) {
            tasks.appendEvidence(tid, "log:\(line)")
        }
        DecisionLogStore.shared.append(
            workspace: session.workspacePath ?? workspaces?.current?.path,
            kind: .note,
            text: "Agent \(session.name) chiuso · task \(tid.uuidString.prefix(8)) · \(useful.count) log lines",
            relatedTaskIds: [tid],
            meta: ["agent": session.name]
        )
    }

    /// Remove all agents and clear mission state.
    func removeAll() {
        persistMissionToProjectMemory(reason: "removeAll")
        runtime.cancelAll()
        let n = sessions.count
        sessions = []
        selectedID = nil
        if var m = mission {
            m.phase = .done
            m.activity.insert(
                MissionActivityLine(
                    agentName: "system",
                    role: "mission",
                    text: "Missione chiusa · \(n) agent rimossi",
                    level: .warning
                ),
                at: 0
            )
            mission = m
        }
        AppLogger.info("Agent removeAll · cleared \(n)")
    }

    /// End mission UI state without necessarily wiping history activity.
    func clearMission() {
        persistMissionToProjectMemory(reason: "clearMission")
        runtime.cancelAll()
        for i in sessions.indices {
            sessions[i].status = .idle
        }
        mission = nil
        AppLogger.info("Mission cleared")
    }

    /// B3: fold mission activity + task titles into ProjectMemoryStore.
    func persistMissionToProjectMemory(reason: String) {
        guard let m = mission else { return }
        guard let path = m.workspacePath ?? workspaces?.current?.path else { return }
        let taskTitles: [String] = m.taskIds.compactMap { tid in
            tasks?.task(id: tid)?.title
        }
        let edges = liveEdges().map { e in
            let col = e.taskColumn?.rawValue ?? "—"
            let link = e.taskTitle.map { "→ \($0) [\(col)]" } ?? "(no task)"
            return "\(e.agentName)(\(e.role)) \(link)"
        }
        let activitySnap = m.activity.prefix(12).map { "[\($0.agentName)] \($0.text)" }
        let body = """
        Goal: \(m.goal)
        Phase: \(m.phase.rawValue) · reason: \(reason)
        Tasks (\(taskTitles.count)): \(taskTitles.prefix(8).joined(separator: "; "))
        Links: \(edges.prefix(8).joined(separator: " | "))
        Feed: \(activitySnap.prefix(6).joined(separator: " · "))
        """
        _ = projectMemory?.appendSessionSummary(
            path: path,
            title: "Missione Swarm: \(String(m.goal.prefix(80)))",
            body: body,
            evidence: [
                "mission:\(m.id.uuidString.prefix(8))",
                "plan:\(m.planId.uuidString.prefix(8))",
                "tasks:\(m.taskIds.count)",
                "agents:\(m.agentIds.count)",
            ]
        )
        DecisionLogStore.shared.append(
            workspace: path,
            kind: .session,
            text: "Swarm mission end (\(reason)): \(m.goal.prefix(100))",
            relatedTaskIds: m.taskIds,
            meta: ["missionId": m.id.uuidString, "planId": m.planId.uuidString]
        )
        // Also fold orchestrator short memory if available
        orchestrator?.flushSessionToProjectMemory(force: true)
        AppLogger.info("B3 mission → project memory (\(reason))")
    }

    /// Attach task to the active mission (or open a control shell) so the orchestrator owns the run.
    /// Without this, "Avvia" on the board bypasses mission/GOAL/split/activity.
    func ensureOrchestratorControl(for taskId: UUID, goalHint: String? = nil) {
        guard let tasks, let task = tasks.task(id: taskId) else { return }
        let path = task.workspacePath ?? workspaces?.current?.path
        let hint = (goalHint ?? task.title).trimmingCharacters(in: .whitespacesAndNewlines)

        if var m = mission, m.phase != .done {
            if !m.taskIds.contains(taskId) {
                m.taskIds.append(taskId)
            }
            // Board starts should execute under orchestrator, not stay stuck in planning gate.
            if m.phase == .planning || m.phase == .awaitingUser {
                m.phase = .executing
                m.autoRun = true
            }
            mission = m
            pushActivity(
                agentName: "orchestrator",
                role: "control",
                text: "Controllo: task «\(task.title)» sotto missione «\(String(m.goal.prefix(48)))»",
                level: .thinking
            )
            return
        }

        // Soft control mission — enables agentDidFinish pipeline, pulse, optional GOAL split.
        let useGoal = goalModePreferred || (orchestrator?.goalModeEnabled == true)
        mission = SwarmMission(
            id: UUID(),
            goal: hint.isEmpty ? "Esegui task board" : hint,
            phase: .executing,
            workspacePath: path,
            taskIds: [taskId],
            questions: [],
            activity: [],
            coordinatorSummary: "Avvio diretto da board — orchestratore in controllo (sub-agent builder).",
            startedAt: .now,
            planId: task.planId ?? UUID(),
            agentIds: [],
            autoRun: true,
            dispatchedTaskIds: [],
            goalMode: useGoal,
            splitCount: 0,
            maxSplits: TokenBudget.goalModeMaxSplits
        )
        pushActivity(
            agentName: "orchestrator",
            role: "control",
            text: useGoal
                ? "GOAL control shell · task «\(task.title)»"
                : "Control shell · task «\(task.title)» — sub-agent sotto orchestratore",
            level: .thinking
        )
        orchestrator?.notifyGoalMode("Controllo task: \(task.title)")
    }

    /// Existing builder bound to this board task (newest first).
    func agentForTask(_ taskId: UUID) -> AgentSession? {
        sessions.first(where: { $0.taskId == taskId && $0.role == .builder })
            ?? sessions.first(where: { $0.taskId == taskId })
    }

    /// Reuse linked PTY if alive; reopen only when missing/dead (never spawn a second pane for the same agent).
    @discardableResult
    private func ensureLinkedTerminalAlive(sessionId: UUID, path: String?, title: String, role: AgentRole) -> Bool {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return false }
        if let tid = sessions[i].linkedTerminalID,
           let term = terminals?.sessions.first(where: { $0.id == tid }),
           term.isAlive {
            terminals?.select(tid)
            return true
        }
        // Dead or missing — open one replacement and re-link
        guard let path, let term = terminals?.openTerminal(at: path, title: title, role: role) else {
            return false
        }
        sessions[i].linkedTerminalID = term.id
        append(sessionId, "PTY ricollegato · \(term.cwd) (riuso agent, no nuovo spawn)", level: .success)
        term.appendAgentEcho(
            "═══ QS Agent «\(title)» ripreso ═══\n" +
            "Stesso agent — continua da dove eri, senza rileggere tutto il repo.\n"
        )
        terminals?.select(term.id)
        return true
    }

    /// Start working a task: reuse agent/PTY when possible — never open a new terminal on every Avvia click.
    /// Prefer `OrchestratorEngine.launchBoardTask` from UI so control + activity stay with the orchestrator.
    @discardableResult
    func startTask(_ taskId: UUID, underOrchestratorControl: Bool = true) -> TaskLaunchResult {
        bindRuntime()
        guard let tasks, let task = tasks.tasks.first(where: { $0.id == taskId }) else {
            return .failed("Task non trovata")
        }
        // C1: refuse start while DAG dependencies are open
        let gate = tasks.canStart(taskId)
        if !gate.ok {
            AppLogger.warn("startTask blocked: \(gate.reason ?? "?")")
            return .failed(gate.reason ?? "Task bloccata")
        }
        if underOrchestratorControl {
            ensureOrchestratorControl(for: taskId, goalHint: task.title)
        }

        // Hard lock: never run a task against a different open project (or bare $HOME).
        let currentWS = AgentToolRunner.sanitizedWorkspace(workspaces?.current?.path)
        let taskWS = AgentToolRunner.sanitizedWorkspace(task.workspacePath)
        if let taskWS, let currentWS, taskWS != currentWS {
            AppLogger.warn("startTask refused: task ws \(taskWS) ≠ current \(currentWS)")
            return .failed(
                "Workspace sbagliato: task → \((taskWS as NSString).lastPathComponent), aperto → \((currentWS as NSString).lastPathComponent). Apri il progetto giusto e riprova."
            )
        }
        let path = taskWS ?? currentWS
        guard let path else {
            return .failed("Nessun workspace progetto. Apri una cartella (non $HOME) prima di Avvia.")
        }
        if task.workspacePath == nil || AgentToolRunner.sanitizedWorkspace(task.workspacePath) == nil {
            tasks.setWorkspace(taskId, path)
        }

        // ── Reuse path: same task already has a builder ──
        if let existing = agentForTask(taskId) {
            selectedID = existing.id
            if runtime.isRunning(existing.id)
                || existing.status == .thinking
                || existing.status == .active {
                _ = ensureLinkedTerminalAlive(
                    sessionId: existing.id,
                    path: path,
                    title: existing.name,
                    role: existing.role
                )
                append(
                    existing.id,
                    "Già in corso — Continua non riavvia. Vedi log sotto (nessun nuovo terminale/agent).",
                    level: .warning
                )
                pushActivity(
                    agentName: existing.name,
                    role: "control",
                    text: "Riuso sessione (già running) · \(task.title)",
                    level: .muted
                )
                return .alreadyRunning(agentName: existing.name)
            }

            // Idle / error / review — resume same agent + same PTY
            tasks.move(taskId, to: .inProgress)
            if task.progress == nil || (task.progress ?? 0) < 0.15 {
                tasks.updateProgress(taskId, 0.15)
            }
            _ = ensureLinkedTerminalAlive(
                sessionId: existing.id,
                path: path,
                title: existing.name,
                role: existing.role
            )
            if let i = sessions.firstIndex(where: { $0.id == existing.id }) {
                sessions[i].lastGoal = task.title
                sessions[i].status = .thinking
            }
            if var m = mission {
                if !m.agentIds.contains(existing.id) { m.agentIds.append(existing.id) }
                if !m.dispatchedTaskIds.contains(taskId) { m.dispatchedTaskIds.append(taskId) }
                mission = m
            }
            append(existing.id, "Ripresa task (stesso agent/PTY): \(task.title)", level: .thinking)
            append(
                existing.id,
                "CONTINUA — non ripetere repo_capsule/read_file interi. Usa path già visti nel log; patch e complete_task.",
                level: .info
            )
            runtime.runTask(
                sessionId: existing.id,
                taskTitle: task.title,
                taskId: taskId,
                workspace: path,
                missionGoal: mission?.goal,
                taskSubtitle: task.subtitle,
                coordinatorSummary: mission?.coordinatorSummary,
                resume: true
            )
            setStatus(existing.id, .thinking)
            pushActivity(
                agentName: existing.name,
                role: "control",
                text: "Ripresa stesso agent · \(task.title)",
                level: .thinking
            )
            return .resumed(agentName: existing.name)
        }

        // ── Fresh start: only when no agent exists for this task ──
        tasks.move(taskId, to: .inProgress)
        tasks.updateProgress(taskId, 0.15)

        let modelHint: String? = {
            if task.assigneeModel != "local", !task.assigneeModel.isEmpty {
                return task.assigneeModel
            }
            return nil
        }()
        let agent = spawn(
            name: "builder-\(String(task.title.prefix(16)))",
            role: .builder,
            model: modelHint,
            workspacePath: path,
            taskId: taskId,
            openTerminal: true,
            goal: task.title,
            runLLM: false
        )
        if var m = mission, !m.agentIds.contains(agent.id) {
            m.agentIds.append(agent.id)
            if !m.dispatchedTaskIds.contains(taskId) {
                m.dispatchedTaskIds.append(taskId)
            }
            mission = m
        }
        append(agent.id, "Avvio task (orchestratore): \(task.title)", level: .thinking)
        append(agent.id, "Workspace: \(path ?? "nessuno — apri un workspace")", level: .muted)
        append(agent.id, "Sub-agent sotto controllo orchestratore / missione", level: .muted)

        runtime.runTask(
            sessionId: agent.id,
            taskTitle: task.title,
            taskId: taskId,
            workspace: path,
            missionGoal: mission?.goal,
            taskSubtitle: task.subtitle,
            coordinatorSummary: mission?.coordinatorSummary,
            resume: false
        )
        setStatus(agent.id, .thinking)
        setProgress(agent.id, 0.1)
        return .started(agentName: agent.name)
    }

    /// GOAL MODE entry: same pipeline but no human gate, elevated budgets, auto-split on stuck.
    func startGoalMode(goal: String, builders: Int = 2) {
        goalModePreferred = true
        // Always align Swarm routing to whatever key the orchestrator already has.
        if let p = ProviderPreferences.shared.anyKeyedProvider() {
            let m = ProviderPreferences.shared.model(for: .builder)
            ProviderPreferences.shared.syncSwarmFromLive(
                provider: p,
                model: m == "local" ? p.defaultModel : m
            )
        }
        let path = workspaces?.current?.path
        let open = openBoardTasks(workspacePath: path)
        // «Completa le task» with an existing board → skip PLAN (avoids stuck planning / local bootstrap).
        if !open.isEmpty, Self.looksLikeBoardSweepGoal(goal) {
            startBoardSweepGoal(goal: goal, builders: builders, openTasks: open)
            return
        }
        // Fast path: one Patch card + one builder. No scout/coord/reviewer bootstrap bottleneck.
        if ProviderPreferences.shared.anyKeyedProvider() != nil {
            startDirectPatchGoal(goal: goal)
            return
        }
        startMission(goal: goal, builders: builders, goalMode: true)
    }

    /// Result of starting QS API IDE session (tools mirrored to a real PTY).
    struct IDESessionResult: Equatable {
        let ok: Bool
        let message: String
        let terminalID: UUID?
        let taskID: UUID?
    }

    /// Coding Engine · QS API: one builder + linked PTY (IDE-in-terminal).
    @discardableResult
    func startIDESession(goal: String, workspace: String? = nil) -> IDESessionResult {
        startDirectPatchGoal(goal: goal, workspace: workspace, openTerminal: true, ideMode: true)
    }

    func hasActiveIDESession(workspacePath: String?) -> Bool {
        let builders = sessions.filter {
            $0.role == .builder && ($0.status == .active || $0.status == .thinking || runtime.isRunning($0.id))
        }
        guard !builders.isEmpty else { return false }
        guard let workspacePath else { return true }
        let root = (workspacePath as NSString).standardizingPath
        return builders.contains { sess in
            guard let p = sess.workspacePath else { return false }
            return (p as NSString).standardizingPath == root
        }
    }

    @discardableResult
    func sendIDEFollowUp(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let candidates = sessions.filter { $0.role == .builder }
        guard let agent = candidates.first(where: { runtime.isRunning($0.id) })
                ?? candidates.first(where: { $0.status == .active || $0.status == .thinking })
                ?? candidates.first else {
            return false
        }
        append(agent.id, "🎙 Orchestratore: \(t)", level: .info)
        if let tid = agent.linkedTerminalID,
           let term = terminals?.sessions.first(where: { $0.id == tid }) {
            term.appendAgentEcho("🎙 Orchestratore → agent:\n\(t)")
        }
        if runtime.isRunning(agent.id) {
            runtime.injectGuidance(sessionId: agent.id, text: t)
            pushActivity(agentName: agent.name, role: "ide", text: "Follow-up iniettato nel loop", level: .thinking)
            return true
        }
        // Resume finished builder on same task with guidance
        runtime.runTask(
            sessionId: agent.id,
            taskTitle: agent.lastGoal ?? "Continua",
            taskId: agent.taskId,
            workspace: agent.workspacePath,
            missionGoal: t,
            taskSubtitle: t,
            coordinatorSummary: "Follow-up orchestratore: \(t)",
            resume: true
        )
        pushActivity(agentName: agent.name, role: "ide", text: "Resume con guida orchestratore", level: .thinking)
        return true
    }

    func stopIDESessions() {
        let ids = sessions.filter { $0.role == .builder }.map(\.id)
        for id in ids { stop(id) }
    }

    /// Skip PLAN cascade: seed one task, run one builder with the live LLM key.
    private func startDirectPatchGoal(goal: String) {
        _ = startDirectPatchGoal(goal: goal, workspace: nil, openTerminal: true, ideMode: false)
    }

    @discardableResult
    private func startDirectPatchGoal(
        goal: String,
        workspace: String?,
        openTerminal: Bool,
        ideMode: Bool
    ) -> IDESessionResult {
        bindRuntime()
        let path = AgentToolRunner.sanitizedWorkspace(workspace ?? workspaces?.current?.path)
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else {
            return IDESessionResult(ok: false, message: "Goal vuoto.", terminalID: nil, taskID: nil)
        }
        guard let path else {
            return IDESessionResult(
                ok: false,
                message: "Apri un workspace prima (es. zackgame).",
                terminalID: nil,
                taskID: nil
            )
        }

        runtime.cancelAll()
        sessions = []
        selectedID = nil

        let live = ProviderPreferences.shared.anyKeyedProvider()
        let liveModel = live.map { p -> String in
            let m = ProviderPreferences.shared.model(for: .builder)
            return (m == "local" || m.isEmpty) ? p.defaultModel : m
        }

        let summary = ideMode
            ? "QS API IDE — 1 builder, tools → PTY (stessa key orchestratore)."
            : "Direct patch — skip PLAN (stessa key dell’orchestratore)."

        mission = SwarmMission(
            id: UUID(),
            goal: g,
            phase: .executing,
            workspacePath: path,
            taskIds: [],
            questions: [],
            activity: [],
            coordinatorSummary: summary,
            startedAt: .now,
            planId: UUID(),
            agentIds: [],
            autoRun: true,
            dispatchedTaskIds: [],
            goalMode: true,
            splitCount: 0,
            maxSplits: TokenBudget.goalModeMaxSplits
        )

        // Ignore stale REVIEW/LOCAL cards — always seed one fresh Patch for this goal.
        let seeded = seedMissionTasksIfEmpty(reason: ideMode ? "qs-api-ide" : "direct-patch-skip-plan", forceNew: true)
        let taskIds = mission?.taskIds ?? []
        guard let tid = taskIds.first, let task = tasks?.task(id: tid) else {
            pushActivity(
                agentName: "system",
                role: "goal",
                text: "Direct patch fallito: seed=\(seeded) — apri workspace e riprova.",
                level: .warning
            )
            return IDESessionResult(
                ok: false,
                message: "Seed task fallito — apri workspace e riprova.",
                terminalID: nil,
                taskID: nil
            )
        }

        let modeLabel = ideMode ? "QS API IDE" : "Direct patch"
        pushActivity(
            agentName: "system",
            role: "goal",
            text: "\(modeLabel) · 1 builder · \(live?.displayName ?? "?")/\(liveModel ?? "?") · PTY=\(openTerminal)",
            level: .thinking
        )
        orchestrator?.notifyGoalMode("\(modeLabel) (1 agent) — niente bootstrap locale")

        tasks?.move(tid, to: .inProgress)
        if var mm = mission {
            mm.dispatchedTaskIds.append(tid)
            mission = mm
        }

        let a = spawn(
            name: ideMode ? "ide-1" : "builder-1",
            role: .builder,
            model: liveModel,
            providerRaw: live?.rawValue,
            workspacePath: path,
            taskId: tid,
            openTerminal: openTerminal,
            goal: task.title,
            runLLM: false
        )
        runtime.runTask(
            sessionId: a.id,
            taskTitle: task.title,
            taskId: tid,
            workspace: path,
            missionGoal: g,
            taskSubtitle: task.subtitle,
            coordinatorSummary: mission?.coordinatorSummary
        )

        let providerLine = "\(live?.displayName ?? "?") / \(liveModel ?? "?")"
        return IDESessionResult(
            ok: true,
            message: """
            **QS API · IDE in terminale** @ `\(path)`.

            · Motore: \(providerLine) (stessa key della chat)
            · 1 builder · tools (`read` / `propose_patch` / `apply_patch` / `run_command`) mirrorati nel PTY
            · Continua a scrivere qui → guida lo stesso loop
            · Swarm multi-agent solo se scegli engine **Swarm**
            """,
            terminalID: a.linkedTerminalID,
            taskID: tid
        )
    }

    /// True when the user wants to finish the existing QS Tasks board (not invent a new plan).
    private static func looksLikeBoardSweepGoal(_ goal: String) -> Bool {
        let g = goal.lowercased()
        let markers = [
            "completa tutt", "completa le task", "completa task", "finire le task",
            "finish all task", "complete all task", "completa la board", "svuota board",
            "chiudi le task", "completa qs task", "tutte le task",
        ]
        return markers.contains { g.contains($0) }
    }

    /// Jump straight to executing open board cards (IN CORSO first).
    private func startBoardSweepGoal(goal: String, builders: Int, openTasks: [AgentTask]) {
        bindRuntime()
        let path = workspaces?.current?.path
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime.cancelAll()
        sessions = []
        selectedID = nil

        mission = SwarmMission(
            id: UUID(),
            goal: g,
            phase: .executing,
            workspacePath: path,
            taskIds: openTasks.map(\.id),
            questions: [],
            activity: [],
            coordinatorSummary: "Board sweep GOAL — niente PLAN, riprendo task aperte.",
            startedAt: .now,
            planId: UUID(),
            agentIds: [],
            autoRun: true,
            dispatchedTaskIds: [],
            goalMode: true,
            splitCount: 0,
            maxSplits: TokenBudget.goalModeMaxSplits
        )
        pushActivity(
            agentName: "system",
            role: "goal",
            text: "GOAL board-sweep · \(openTasks.count) task aperte → builder subito (skip PLAN)",
            level: .thinking
        )
        orchestrator?.notifyGoalMode("Board sweep · \(openTasks.count) task (skip planning)")
        approveAndExecuteBuilders(builderCount: max(2, min(builders, 3)))
    }

    /// Start mission in **plan-first** mode (Lovable/Bolt style):
    /// scout + coordinator create board tasks / ask questions → human approves → builders.
    /// `builders` is used later in `approveAndExecuteBuilders`.
    func startMission(goal: String, builders: Int = 2, goalMode: Bool = false) {
        bindRuntime()
        let path = workspaces?.current?.path
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }

        // Hard reset — old IDLE builders must not linger while a new mission is "planning"
        runtime.cancelAll()
        sessions = []
        selectedID = nil

        let useGoal = goalMode || goalModePreferred
        mission = SwarmMission(
            id: UUID(),
            goal: g,
            phase: .planning,
            workspacePath: path,
            taskIds: [],
            questions: [],
            activity: [],
            coordinatorSummary: nil,
            startedAt: .now,
            planId: UUID(),
            agentIds: [],
            autoRun: true,
            dispatchedTaskIds: [],
            goalMode: useGoal,
            splitCount: 0,
            maxSplits: TokenBudget.goalModeMaxSplits
        )
        pushActivity(
            agentName: "system",
            role: useGoal ? "goal" : "mission",
            text: useGoal
                ? "GOAL MODE ON · perseguo fino a DONE (auto-split se blocco): \(g)"
                : "Nuova missione (fase PLAN): \(g)",
            level: .thinking
        )
        if useGoal {
            orchestrator?.notifyGoalMode("Avvio goal: \(g)")
        }
        if path == nil {
            pushActivity(
                agentName: "system",
                role: "mission",
                text: "Nessun workspace aperto — apri una cartella prima per risultati utili",
                level: .warning
            )
        }

        // Auto-create / attach QS Task immediately (do not wait for coord create_task).
        let seeded = seedMissionTasksIfEmpty(reason: useGoal ? "goal-start" : "mission-start")
        if seeded > 0 {
            pushActivity(
                agentName: "system",
                role: useGoal ? "goal" : "mission",
                text: "QS Tasks · \(seeded) card collegate (seed all’avvio)",
                level: .success
            )
            // Surface board so the user sees the linked task without asking.
            orchestrator?.navigateToTasksBoard()
        }

        // 1) Scout (read-only exploration) — no PTY spam
        let scout = spawn(
            name: "scout-1",
            role: .scout,
            workspacePath: path,
            openTerminal: false,
            goal: g,
            runLLM: false
        )
        runtime.runGoal(
            sessionId: scout.id,
            goal: """
            Sei SCOUT (read-only). Missione: \(g)
            Esplora struttura file, git status, README / UI entrypoints se rilevanti.
            Non scrivere file. Non creare task (lo fa il coordinatore).
            finish con mappa del repo, file rilevanti e rischi.
            """,
            workspace: path
        )

        // 2) Coordinator plans + creates QS Tasks + may ask_user
        let coord = spawn(
            name: "coord-1",
            role: .coordinator,
            workspacePath: path,
            openTerminal: true,
            goal: g,
            runLLM: false
        )
        append(coord.id, useGoal ? "GOAL MODE (PLAN): \(g)" : "Missione (PLAN): \(g)", level: .thinking)
        append(
            coord.id,
            useGoal
                ? "GOAL MODE: niente ask_user — i builder partono da soli; task PICCOLE."
                : "I builder partono solo dopo conferma utente in Swarm.",
            level: .muted
        )
        let coordPrompt: String
        if useGoal {
            let boardSnap = boardSnapshotForPrompt(workspacePath: path)
            coordPrompt = """
            Sei il COORDINATORE in GOAL MODE (autonomo fino a DONE).
            Goal utente: \(g)

            \(boardSnap)

            OBBLIGHI:
            1) repo_capsule o list_dir mirato — niente dump enormi.
            2) Se BOARD VUOTO: DEVI chiamare create_task UNA volta (JSON tool) PRIMA di finish — una sola Patch concreta.
               Titolo chiaro; subtitle con path TRACKED root/src (mai www/ build).
               Esempio: {"tool":"create_task","title":"Patch · PLAY verde","subtitle":"premium-ui.css .p-big-play","priority":"alto"}
            3) Se BOARD ha già card aperte: NON duplicare; finish con «riprendi board, priorità IN CORSO».
            4) VIETATO ask_user. VIETATO finish con «non ho creato le task» — o create_task o riprendi board.
            5) finish con piano breve + elenco id/titoli delle card.

            NON patchare file in questa fase. I builder partono in automatico su root/src come Cursor.
            """
        } else {
            let boardSnap = boardSnapshotForPrompt(workspacePath: path)
            coordPrompt = """
            Sei il COORDINATORE di QS Swarm (stile Lovable/Bolt: pianifica prima, esegui dopo).
            Missione utente: \(g)

            \(boardSnap)

            Procedura obbligatoria:
            1) list_dir / read_file / git_status per capire il progetto (menu iniziale, UI, ecc. se rilevante).
            2) Se BOARD VUOTO o la missione chiede backlog: DEVI create_task per OGNI item (3–8 card).
               Esempio: {"tool":"create_task","title":"[Menu] Migliora CTA play","subtitle":"…","priority":"alto"}
            3) Se ti manca un requisito (stile, piattaforma, scope): ask_user con UNA domanda chiara.
            4) finish con: piano breve + elenco task create + cosa chiederai ai builder.
               VIETATO finish senza create_task se il board era vuoto.

            NON modificare file di gioco in questa fase. NON inventare path inesistenti.
            I builder NON partono finché l'utente non preme «Avvia builder» in Swarm.
            """
        }
        runtime.runGoal(
            sessionId: coord.id,
            goal: coordPrompt,
            workspace: path
        )

        // Builders/reviewer: deferred until approveAndExecuteBuilders (auto in goal/autoRun)
        _ = builders // reserved for approve step default
        pushActivity(
            agentName: "system",
            role: useGoal ? "goal" : "mission",
            text: useGoal
                ? "Scout + Coordinator avviati · GOAL MODE (builder automatici, budget elevato, auto-split)."
                : "Scout + Coordinator avviati. Builder in attesa del tuo ok.",
            level: .muted
        )
    }

    /// Direct a message to @all or @agent-name (swarm command bar).
    /// Always re-injects mission + linked task so builders never “forget” the job.
    func messageAgents(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        bindRuntime()
        let path = workspaces?.current?.path

        if text.lowercased().hasPrefix("@all") {
            let body = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            for s in sessions where s.status == .active || s.status == .thinking || s.status == .idle {
                append(s.id, "MSG @all: \(body)", level: .thinking)
                // Update lastGoal so UI shows current instruction
                if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                    sessions[i].lastGoal = body
                }
                runtime.runGoal(
                    sessionId: s.id,
                    goal: contextualWorkBrief(for: s, userInstruction: body),
                    workspace: path ?? s.workspacePath
                )
            }
            return
        }

        // @name rest
        if text.hasPrefix("@") {
            let rest = String(text.dropFirst())
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let name = String(parts[0]).lowercased()
            let body = parts.count > 1 ? String(parts[1]) : "Continua sul tuo compito assegnato e completa un passo concreto."
            if let target = sessions.first(where: {
                $0.name.lowercased().contains(name)
                    || $0.name.lowercased() == name
                    || $0.role.rawValue == name
            }) {
                append(target.id, "MSG @\(target.name): \(body)", level: .thinking)
                if let i = sessions.firstIndex(where: { $0.id == target.id }) {
                    sessions[i].lastGoal = body
                }
                runtime.runGoal(
                    sessionId: target.id,
                    goal: contextualWorkBrief(for: target, userInstruction: body),
                    workspace: path ?? target.workspacePath
                )
            } else {
                AppLogger.info("No agent matching @\(name)")
                pushActivity(
                    agentName: "system",
                    role: "mission",
                    text: "Nessun agent «\(name)» — prova @all o @builder-1",
                    level: .warning
                )
            }
            return
        }

        // default: selected agent → coordinator → all builders → new mission
        if let sel = selected {
            messageAgents("@\(sel.name) \(text)")
        } else if let c = sessions.first(where: { $0.role == .coordinator }) {
            messageAgents("@\(c.name) \(text)")
        } else if let b = sessions.first(where: { $0.role == .builder }) {
            messageAgents("@\(b.name) \(text)")
        } else {
            startMission(goal: text, builders: 1)
        }
    }

    /// Full work brief so agents never reply “waiting for a task” when context exists.
    func contextualWorkBrief(for session: AgentSession, userInstruction: String?) -> String {
        let m = mission
        let task: AgentTask? = session.taskId.flatMap { tasks?.task(id: $0) }
        let userLine = (userInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let focusTitle = task?.title ?? session.lastGoal ?? m?.goal ?? ""

        var parts: [String] = []
        parts.append("Ruolo: \(session.role.displayName) · Agent: \(session.name)")
        if let m {
            parts.append("MISSIONE: \(String(m.goal.prefix(200)))")
            // Keep coordinator summary short — was burning tokens
            if let sum = m.coordinatorSummary, !sum.isEmpty {
                parts.append("Piano (breve): \(String(sum.prefix(280)))")
            }
        } else if let lg = session.lastGoal, !lg.isEmpty {
            parts.append("Goal: \(String(lg.prefix(200)))")
        }
        if let task {
            parts.append("=== TASK BOARD (QUESTA È LA TASK — non inventare che manca) ===")
            parts.append("TITOLO: \(task.title)")
            if let sub = task.subtitle, !sub.isEmpty {
                parts.append("Dettaglio: \(String(sub.prefix(240)))")
            } else {
                parts.append("Dettaglio: (vuoto — interpreta il titolo e implementa il pezzo più utile nei file sotto)")
            }
            let prior = task.evidence.filter {
                $0.hasPrefix("log:") || $0.hasPrefix("agent-trace:") || $0.hasPrefix("stuck-abandoned")
            }.suffix(6)
            if !prior.isEmpty {
                parts.append("Trace precedente (stesso task, PTY chiuso o ripresa):")
                for e in prior {
                    parts.append("  · \(String(e.prefix(140)))")
                }
            }
            parts.append("Quando fatto: propose_patch → apply_patch → git_status → complete_task. finish SOLO se impossibile (con path provati).")
        } else if !focusTitle.isEmpty {
            parts.append("=== GOAL (questa è la task) === \(String(focusTitle.prefix(200)))")
        }
        if !userLine.isEmpty {
            parts.append("ISTRUZIONE: \(String(userLine.prefix(300)))")
        }

        // Memory from sibling / past tasks in the same workspace (survives closed terminals).
        let wsPath = session.workspacePath ?? workspaces?.current?.path ?? task?.workspacePath
        if let tasks, let wsPath {
            let root = (wsPath as NSString).standardizingPath
            let siblings = tasks.tasks
                .filter { t in
                    guard let wp = t.workspacePath else { return false }
                    return (wp as NSString).standardizingPath == root
                }
                .filter { $0.id != task?.id }
                .filter { $0.column == .done || $0.column == .review || $0.column == .inProgress }
                .prefix(5)
            if !siblings.isEmpty {
                parts.append("=== MEMORIA TASK WORKSPACE (cosa è già stato fatto) ===")
                for t in siblings {
                    let bit = t.evidence.filter { $0.hasPrefix("log:") }.suffix(2).joined(separator: " | ")
                    let sub = t.subtitle.map { " — \(String($0.prefix(70)))" } ?? ""
                    let extra = bit.isEmpty ? "" : " · \(String(bit.prefix(100)))"
                    parts.append("• [\(t.column.rawValue)] \(String(t.title.prefix(60)))\(sub)\(extra)")
                }
            }
            let decisions = DecisionLogStore.shared.formatRecall(workspace: wsPath, limit: 4)
            if !decisions.isEmpty,
               !decisions.lowercased().contains("nessun"),
               !decisions.lowercased().contains("vuoto") {
                parts.append("=== DECISION LOG ===\n\(String(decisions.prefix(320)))")
            }
        }

        // Path hints from task keywords — stop reading entire ROADMAP / docs
        let hints = Self.pathHints(for: focusTitle + " " + (task?.subtitle ?? ""))
        if !hints.isEmpty {
            parts.append("FILE TARGET (repo_capsule o read_file QUI, non docs/): \(hints.joined(separator: ", "))")
        }

        if session.role == .builder || session.role == .general {
            parts.append("""
            PIANO (qualità Cursor): 1) repo_capsule 2) se UI: read markup/JS (id/class) + CSS/JS già linkato da index/boot 3) propose_patch su path TRACKED root/src 4) apply 5) git_status (tracked dirty) 6) complete_task.
            VIETATO: patch CSS non caricato / selettori inventati; finish «nessun task»; list_dir/docs dump; www/ build.
            Focus: \(String(focusTitle.prefix(80))).
            """)
        } else {
            parts.append("Esegui il ruolo; finish con esito concreto. No «in attesa di task».")
        }

        let brief = parts.joined(separator: "\n")
        return brief.count > 2200 ? String(brief.prefix(2200)) + "…" : brief
    }

    /// Heuristic file/path suggestions from task text (Zack + generic web/game).
    static func pathHints(for text: String) -> [String] {
        let t = text.lowercased()
        var hints: [String] = []
        // Homepage / menu motion first (Zack premium shell — not docs, not missing src/ui)
        let homeish = t.contains("homepage") || t.contains("home page") || t.contains("menu")
            || t.contains("main screen") || t.contains("landing") || t.contains("home")
        let motionish = t.contains("motion") || t.contains("anim") || t.contains("transiz")
            || t.contains("scroll") || t.contains("reveal") || t.contains("hover")
        if homeish || (motionish && (t.contains("m4") || homeish || t.contains("ui"))) {
            hints += ["premium-ui.js", "premium-ui.css", "index.html", "src/foundation/", "sw.js"]
        }
        if motionish && !homeish {
            hints += ["premium-ui.js", "premium-ui.css", "src/gameplay/game-feel.js", "src/foundation/performance.css"]
        }
        if t.contains("audio") || t.contains("sound") {
            hints += ["src/foundation/audio-mixer.js", "audio/"]
        }
        if t.contains("ios") || t.contains("android") || t.contains("capacitor") {
            hints += ["capacitor.config.json", "ios/", "android/"]
        }
        if t.contains("hud") || t.contains("button") || t.contains("controll")
            || t.contains("pulsante") || t.contains("play") || t.contains("btn") {
            hints += ["premium-ui.js", "premium-ui.css", "index.html", "src/gameplay/input-controls.js"]
        }
        if t.contains("boot") || t.contains("loading") || t.contains("splash") {
            hints += ["src/foundation/boot.css", "src/foundation/boot-controller.js", "index.html"]
        }
        // unique preserve order
        var seen = Set<String>()
        return hints.filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    /// Prefill orchestrator ⌘K draft for a task — does **not** auto-send or navigate.
    /// Keeps user on the Tasks board; they press Invia in the modal.
    func prepareTaskBriefForOrchestrator(_ taskId: UUID) {
        guard let tasks, let task = tasks.tasks.first(where: { $0.id == taskId }) else { return }
        let ws = task.workspacePath
            ?? workspaces?.current?.path
            ?? "nessun workspace aperto"
        let name = workspaces?.current?.name ?? URL(fileURLWithPath: ws).lastPathComponent
        let brief = """
        Task QS: \(task.title)
        \(task.subtitle.map { "Dettaglio: \($0)\n" } ?? "")Priorità: \(task.priority.rawValue) · Workspace: \(name) (`\(ws)`)
        Modello: \(task.assigneeModel)

        Aiutami a eseguirla passo-passo (consigli + comandi safe). Non cambiare vista se non chiedo.
        """
        orchestrator?.draft = brief
        AppLogger.info("Task brief ready for orchestrator: \(task.title)")
    }

    /// Legacy: prefill + send (used if something still calls it).
    func sendTaskToOrchestrator(_ taskId: UUID) {
        prepareTaskBriefForOrchestrator(taskId)
        orchestrator?.send()
    }
}
