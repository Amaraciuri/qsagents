import Foundation
import Combine

/// Orchestrator layer over a single Claude Code PTY per workspace:
/// ready/menu detect → RAW goal → continuous tail listen → task board updates → follow-ups.
@MainActor
final class ClaudeSessionSupervisor: ObservableObject {
    static let shared = ClaudeSessionSupervisor()

    enum Phase: String, Equatable {
        case idle
        case starting
        case menu
        case running
        case awaitingInput
        case limit
        case done
        case error
    }

    struct Session: Equatable {
        var workspacePath: String
        var terminalID: UUID
        var taskID: UUID?
        var phase: Phase
        var goal: String
        var lastTail: String
        var goalSent: Bool
        var menuDismissed: Bool
        var binaryPath: String
        var startedAt: Date
        var lastPhaseChange: Date
    }

    struct StartResult: Equatable {
        let ok: Bool
        let message: String
        let terminalID: UUID?
        let taskID: UUID?
        let binaryPath: String?
        /// True when we injected into an already-running Claude PTY instead of launching anew.
        let followUpOnly: Bool
    }

    @Published private(set) var session: Session?

    weak var terminals: TerminalManager?
    weak var tasks: TaskStore?
    weak var git: GitService?

    /// (phaseLabel, detail) → OrchestratorEngine activity
    var onActivity: ((String, String) -> Void)?
    /// User-visible chat notices (limit, awaiting input, done)
    var onChatNotice: ((String) -> Void)?
    var onNavigate: ((String) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var lastEvidenceFingerprint = ""
    private var lastChatNoticeKey = ""
    private var lineCountAtGoalSend = 0
    private var goalSentAt: Date?
    private var quietSince: Date?
    private var doneHoldSince: Date?
    private var limitHoldSince: Date?
    /// Last time the PTY looked like Claude was still working (thinking/tools).
    private var lastRunningAt: Date?
    /// Last activity emit fingerprint (phase|detail) — kill “Attendo terminale” spam.
    private var lastEmitKey = ""
    private var lastEmitAt: Date = .distantPast
    private var lastGitNudgeAt: Date = .distantPast
    /// Don't re-mark review for the same task within a short window.
    private var lastReviewMarkedAt: Date = .distantPast
    private var lastReviewTaskID: UUID?

    /// After chat → PTY follow-up: capture Claude’s next reply and mirror it back to chat.
    private struct PendingRelay: Equatable {
        var question: String
        var lineCountAtSend: Int
        var sentAt: Date
        var sawRunning: Bool
    }
    private var pendingRelay: PendingRelay?
    private var lastRelayedFingerprint = ""

    private init() {}

    func bind(terminals: TerminalManager?, tasks: TaskStore?, git: GitService?) {
        if let terminals { self.terminals = terminals }
        if let tasks { self.tasks = tasks }
        if let git { self.git = git }
    }

    // MARK: - Public API

    /// Start or reuse Claude for this workspace and send the goal (after ready).
    func start(goal: String, workspace: String) -> StartResult {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else {
            return StartResult(ok: false, message: "Goal vuoto.", terminalID: nil, taskID: nil, binaryPath: nil, followUpOnly: false)
        }
        let root = (workspace as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: root) else {
            return StartResult(ok: false, message: "Workspace non trovato: `\(root)`", terminalID: nil, taskID: nil, binaryPath: nil, followUpOnly: false)
        }
        guard let terminals else {
            return StartResult(ok: false, message: "TerminalManager non disponibile.", terminalID: nil, taskID: nil, binaryPath: nil, followUpOnly: false)
        }
        guard let binary = CodingCLILauncher.resolveClaudeBinary() else {
            return StartResult(
                ok: false,
                message: CodingCLILauncher.missingClaudeMessage,
                terminalID: nil,
                taskID: nil,
                binaryPath: nil,
                followUpOnly: false
            )
        }

        // Reuse live Claude PTY for this workspace → follow-up only
        if let existing = session,
           existing.workspacePath == root,
           let term = terminals.sessions.first(where: { $0.id == existing.terminalID }),
           term.isAlive {
            session?.goal = g
            let ok = sendFollowUp(g)
            return StartResult(
                ok: ok,
                message: ok
                    ? "**Stesso PTY Claude** — follow-up inviato (nessun nuovo terminale).\n\n\(g.prefix(200))"
                    : "PTY Claude non pronto per follow-up.",
                terminalID: existing.terminalID,
                taskID: existing.taskID,
                binaryPath: existing.binaryPath,
                followUpOnly: true
            )
        }

        // Reuse orphan Claude Code pane at same cwd if supervisor state was lost
        if let orphan = terminals.sessions.first(where: {
            $0.isAlive
                && $0.title.hasPrefix(CodingCLILauncher.terminalTitlePrefix)
                && ($0.cwd as NSString).standardizingPath == root
        }) {
            terminals.select(orphan.id)
            attachHooks(to: orphan)
            let task = ensureBoardTask(goal: g, workspace: root, terminalID: orphan.id)
            session = Session(
                workspacePath: root,
                terminalID: orphan.id,
                taskID: task?.id,
                phase: .running,
                goal: g,
                lastTail: tail(of: orphan),
                goalSent: false,
                menuDismissed: false,
                binaryPath: binary,
                startedAt: .now,
                lastPhaseChange: .now
            )
            startPolling()
            emit("starting", "Riuso PTY Claude esistente — attendo ready…")
            // Don't re-launch binary; wait for ready then send goal
            scheduleReadyThenSendGoal()
            onNavigate?("terminals")
            return StartResult(
                ok: true,
                message: """
                **Claude Code** (riuso PTY) @ `\(root)`.

                · Supervisione attiva — ascolto output e aggiorno la task.
                · Chat / Avvia parlano **questo** terminale.
                """,
                terminalID: orphan.id,
                taskID: task?.id,
                binaryPath: binary,
                followUpOnly: false
            )
        }

        let title = "\(CodingCLILauncher.terminalTitlePrefix) · \(URL(fileURLWithPath: root).lastPathComponent)"
        guard let term = terminals.openTerminal(at: root, title: title, select: true, role: .builder) else {
            return StartResult(
                ok: false,
                message: terminals.lastError ?? "Impossibile aprire terminale.",
                terminalID: nil,
                taskID: nil,
                binaryPath: binary,
                followUpOnly: false
            )
        }
        attachHooks(to: term)
        let boardTask = ensureBoardTask(goal: g, workspace: root, terminalID: term.id)
        git?.setPath(root)
        session = Session(
            workspacePath: root,
            terminalID: term.id,
            taskID: boardTask?.id,
            phase: .starting,
            goal: g,
            lastTail: "",
            goalSent: false,
            menuDismissed: false,
            binaryPath: binary,
            startedAt: .now,
            lastPhaseChange: .now
        )
        startPolling()
        emit("starting", "Avvio Claude Code…")
        noticeOnce("start-\(term.id.uuidString.prefix(8))", """
        **Coding engine** avviato su `\(root)`.

        Fasi in chat: avvio → lavoro nel PTY → **revisione** quando Claude finisce (QS Tasks + Git).
        Continua a scrivere qui per guidarlo sullo stesso terminale.
        """)

        let termID = term.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let terminals = self.terminals else { return }
            guard terminals.sessions.contains(where: { $0.id == termID && $0.isAlive }) else { return }
            _ = terminals.sendCommandLine(
                binary,
                to: termID,
                source: "orchestrator-claude-supervisor",
                bypassSafety: true,
                roleOverride: .builder
            )
            self.emit("starting", "Binary avviato — attendo ready/menu…")
            self.scheduleReadyThenSendGoal()
        }

        onNavigate?("terminals")
        AppLogger.info("ClaudeSessionSupervisor start · \(binary) @ \(root)")
        return StartResult(
            ok: true,
            message: """
            **Claude Code** sotto supervisione Orchestratore @ `\(root)`.

            · Un solo PTY — ready/menu gestiti automaticamente
            · Ascolto continuo → aggiorno QS Tasks
            · Messaggi chat / Avvia → stesso terminale (non Swarm)
            · Di’ «stop goal» per chiudere
            """,
            terminalID: term.id,
            taskID: boardTask?.id,
            binaryPath: binary,
            followUpOnly: false
        )
    }

    @discardableResult
    func sendFollowUp(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let s = session, let term = terminal(for: s.terminalID), term.isAlive else {
            return false
        }
        // RAW: paste as TUI input (not shell)
        let compact = t.replacingOccurrences(of: "\n+", with: " · ", options: .regularExpression)
        let linesBefore = term.displayLines.count
        term.send(compact)
        term.send("\r")
        doneHoldSince = nil
        limitHoldSince = nil
        quietSince = nil
        setPhase(.running)
        emit("running", "Follow-up inviato al PTY Claude")
        // Expect a reply back into orchestrator chat (not only Terminali)
        pendingRelay = PendingRelay(
            question: t,
            lineCountAtSend: linesBefore,
            sentAt: .now,
            sawRunning: false
        )
        if let tid = s.taskID {
            tasks?.move(tid, to: .inProgress)
            tasks?.appendEvidence(tid, "follow-up:\(String(t.prefix(60)))")
            // Allow a fresh review when this round finishes
            if lastReviewTaskID == tid { lastReviewTaskID = nil }
        }
        lastRunningAt = .now
        doneHoldSince = nil
        git?.notifyWorkingTreeMaybeChanged()
        return true
    }

    /// Status for orchestrator when user asks «hai finito?» without waiting on PTY.
    func statusSummaryForChat() -> String {
        guard let s = session else {
            return "Nessuna sessione Claude attiva."
        }
        let dirty = gitWorkingTreeDirty()
        let files = git?.status.changes.prefix(8).map(\.path).joined(separator: ", ") ?? ""
        let taskCol: String = {
            guard let tid = s.taskID, let t = tasks?.task(id: tid) else { return "nessuna task linkata" }
            return "\(t.column.rawValue) · \(Int((t.progress ?? 0) * 100))%"
        }()
        return """
        **Stato coding engine**
        · Fase: `\(s.phase.rawValue)`
        · Workspace: `\(s.workspacePath)`
        · QS Task: \(taskCol)
        · Git dirty: \(dirty ? "sì — \(files)" : "no (working tree clean)")
        """
    }

    /// Board Avvia for Claude-supervised tasks.
    @discardableResult
    func handleBoardAvvia(taskId: UUID) -> Bool {
        guard let tasks, let task = tasks.task(id: taskId), isClaudeTask(task) else { return false }
        let ws = task.workspacePath
            ?? session?.workspacePath
            ?? ""
        let root = (ws as NSString).standardizingPath

        if let s = session, s.workspacePath == root || s.taskID == taskId,
           terminal(for: s.terminalID)?.isAlive == true {
            let msg = "Continua la task «\(task.title)». Completa il goal e fai git status."
            _ = sendFollowUp(msg)
            onChatNotice?("**Avvia** → stesso PTY Claude (nessun Swarm).")
            onNavigate?("terminals")
            return true
        }

        // Relink / restart Claude for this task
        let goal = task.subtitle?.isEmpty == false
            ? (task.subtitle ?? task.title)
            : task.title
        let wsPath = root.isEmpty ? (session?.workspacePath ?? "") : root
        guard !wsPath.isEmpty else { return false }
        let result = start(goal: goal, workspace: wsPath)
        if result.ok {
            if var s = session {
                s.taskID = taskId
                session = s
            }
            tasks.move(taskId, to: .inProgress)
            if let termID = result.terminalID {
                tasks.linkTerminal(taskId, terminalID: termID)
            }
            tasks.appendEvidence(taskId, "supervisor-relink")
            // Drop duplicate board card if start() created another
            if let created = result.taskID, created != taskId {
                tasks.forceMove(created, to: .done)
                tasks.appendEvidence(created, "superseded-by-avvia")
            }
        }
        onChatNotice?(result.message)
        return result.ok
    }

    func isClaudeTask(_ task: AgentTask) -> Bool {
        if task.assigneeModel == "claude-code-cli" { return true }
        if task.evidence.contains(where: { $0.hasPrefix("claude-code") || $0 == "claude-code-cli" }) {
            return true
        }
        if let s = session, s.taskID == task.id { return true }
        if let lid = task.linkedTerminalID,
           let term = terminals?.sessions.first(where: { $0.id == lid }),
           term.title.hasPrefix(CodingCLILauncher.terminalTitlePrefix) {
            return true
        }
        return false
    }

    func hasActiveSession(for workspace: String? = nil) -> Bool {
        guard let s = session, let term = terminal(for: s.terminalID), term.isAlive else { return false }
        if let workspace {
            return s.workspacePath == (workspace as NSString).standardizingPath
        }
        return true
    }

    /// Called from orchestrator pulse (~2s).
    func pulse() {
        guard session != nil else { return }
        ingestCurrentBuffer(forceEvidence: false)
    }

    @discardableResult
    func stop(updatingTerminals: TerminalManager? = nil) -> Int {
        if let updatingTerminals { terminals = updatingTerminals }
        pollTask?.cancel()
        pollTask = nil
        var n = 0
        let taskId = session?.taskID
        if let tid = taskId {
            tasks?.move(tid, to: .review)
            tasks?.appendEvidence(tid, "supervisor-stop")
        }
        if let terminals {
            let ids = terminals.sessions
                .filter { $0.title.hasPrefix(CodingCLILauncher.terminalTitlePrefix) }
                .map(\.id)
            for id in ids {
                terminals.close(id)
                n += 1
            }
        }
        session = nil
        lastEvidenceFingerprint = ""
        goalSentAt = nil
        quietSince = nil
        doneHoldSince = nil
        limitHoldSince = nil
        emit("idle", "Sessione Claude chiusa")
        return n
    }

    // MARK: - Ready / menu / goal

    private func scheduleReadyThenSendGoal() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(18)
            var sentMenu = false
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard var s = self.session, let term = self.terminal(for: s.terminalID), term.isAlive else { return }
                let text = self.tail(of: term, lines: 40)
                s.lastTail = text
                self.session = s

                // Permission / confirm → do NOT auto-press 1; wait for human via chat.
                if self.looksLikeAwaitingInput(text.lowercased()), !s.goalSent {
                    self.setPhase(.awaitingInput)
                    self.noticeOnce(
                        "pre-goal-confirm",
                        "**Claude chiede conferma** nel terminale (permessi/login). Rispondi in chat oppure premi nel PTY; poi riparto."
                    )
                    continue
                }

                if self.looksLikeAuthMenu(text), !s.menuDismissed {
                    self.setPhase(.menu)
                    if !sentMenu {
                        sentMenu = true
                        term.sendLine("1")
                        s.menuDismissed = true
                        self.session = s
                        self.emit("menu", "Menu login/account → inviato «1»")
                    }
                    continue
                }

                if self.looksLikeReady(text), !s.goalSent {
                    // Extra beat so TUI finishes painting
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self.sendGoalRAW()
                    return
                }
            }
            // Timeout: try send anyway once
            if self.session?.goalSent != true {
                self.emit("starting", "Timeout ready — invio goal comunque")
                self.sendGoalRAW()
                if self.session?.goalSent != true {
                    self.setPhase(.error)
                    if let tid = self.session?.taskID {
                        self.tasks?.move(tid, to: .review)
                        self.tasks?.appendEvidence(tid, "supervisor-ready-timeout")
                    }
                    self.noticeOnce("ready-timeout", "⚠️ Claude non pronto in tempo. Controlla il tab Terminali o riprova.")
                }
            }
        }
    }

    private func sendGoalRAW() {
        guard var s = session, !s.goalSent, let term = terminal(for: s.terminalID), term.isAlive else { return }
        let brief = CodingCLILauncher.buildBrief(goal: s.goal, workspace: s.workspacePath)
        lineCountAtGoalSend = term.displayLines.count
        // Single submit: normalize to one paragraph so TUI doesn't treat lines as separate Enter.
        let compact = brief
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n+", with: " · ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        term.send(compact)
        term.send("\r")
        s.goalSent = true
        s.phase = .running
        s.lastPhaseChange = .now
        session = s
        goalSentAt = .now
        quietSince = nil
        doneHoldSince = nil
        limitHoldSince = nil
        emit("running", "Goal inviato (RAW) — supervisione attiva")
        if let tid = s.taskID {
            tasks?.move(tid, to: .inProgress)
            tasks?.appendEvidence(tid, "goal-sent-raw")
        }
        git?.refresh()
    }

    // MARK: - Listen / parse

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.ingestCurrentBuffer(forceEvidence: true)
            }
        }
    }

    private func attachHooks(to term: TerminalSession) {
        let id = term.id
        term.onOutputText = { [weak self] termID, _ in
            guard termID == id else { return }
            Task { @MainActor in
                self?.ingestCurrentBuffer(forceEvidence: false)
            }
        }
    }

    private func ingestCurrentBuffer(forceEvidence: Bool) {
        guard var s = session, let term = terminal(for: s.terminalID) else { return }
        if !term.isAlive {
            setPhase(.error)
            if let tid = s.taskID {
                tasks?.move(tid, to: .review)
                tasks?.appendEvidence(tid, "pty-exited")
            }
            noticeOnce("pty-exit", "PTY Claude terminato — task in REVISIONE.")
            pollTask?.cancel()
            session = nil
            return
        }

        let text = tail(of: term, lines: 60)
        s.lastTail = text
        session = s

        let low = text.lowercased()
        // Claude CLI wrote/edited → soft git nudge (throttled; never setPath spam)
        let editSignal = low.contains("writing ") || low.contains("edited ")
            || low.contains("wrote ") || (low.contains("apply") && low.contains("patch"))
            || low.contains("file modificato")
        if editSignal, Date().timeIntervalSince(lastGitNudgeAt) >= 3 {
            lastGitNudgeAt = .now
            if git?.workingPath != s.workspacePath {
                git?.setPath(s.workspacePath)
            }
            git?.notifyWorkingTreeMaybeChanged()
        }
        if looksLikeRunning(low) {
            quietSince = nil
            doneHoldSince = nil
        } else if s.goalSent {
            if quietSince == nil { quietSince = .now }
        }

        let phase = classify(text: text, session: s)
        if phase != s.phase {
            applyPhase(phase, tail: text)
        } else if forceEvidence, phase == .running {
            // Evidence only — do NOT emit activity every second (was flooding chat with footer lines)
            appendTailEvidence(text)
        }

        // Chat asked something → Claude answered in PTY → mirror into orchestrator chat + update task
        maybeRelayClaudeReplyToChat(term: term, phase: phase, tail: text)
    }

    /// When user wrote in chat, Claude replies in the TUI — bring that answer back to chat + board.
    private func maybeRelayClaudeReplyToChat(term: TerminalSession, phase: Phase, tail: String) {
        guard var relay = pendingRelay else { return }
        let low = tail.lowercased()
        if looksLikeRunning(low) { relay.sawRunning = true; pendingRelay = relay }

        let growth = term.displayLines.count - relay.lineCountAtSend
        let waited = Date().timeIntervalSince(relay.sentAt)
        // Need some new output, and Claude idle again (ready / done) after having worked — or timeout 90s
        let idleAgain = (phase == .done || looksLikeReady(tail) || phase == .awaitingInput)
            && (!looksLikeRunning(low) || phase == .done)
        let readyToCapture = (relay.sawRunning || growth >= 8) && idleAgain && waited >= 2
        let timedOut = waited >= 90 && growth >= 3
        guard readyToCapture || timedOut else { return }

        let delta = term.displayLines
            .suffix(max(0, term.displayLines.count - relay.lineCountAtSend))
            .joined(separator: "\n")
        let cleaned = Self.cleanTerminalReply(delta)
        pendingRelay = nil
        guard cleaned.count >= 24 else { return }

        let fp = String(cleaned.prefix(160))
        guard fp != lastRelayedFingerprint else { return }
        lastRelayedFingerprint = fp

        let q = relay.question
        let body = """
        **Risposta da Claude** (stesso PTY) — alla tua domanda:
        > \(q)

        \(cleaned)
        """
        onChatNotice?(body)
        emit("done", "Risposta Claude riportata in chat")

        // Review only on explicit “hai finito?” or a strong done phrase — never “dirty alone”
        // (Claude often dirties the tree mid-task while still working).
        let finishAsk = Self.looksLikeFinishQuestion(q)
        let strong = looksLikeStrongDone(cleaned.lowercased())
        let stillWorking = looksLikeRunning(cleaned.lowercased())
            || (lastRunningAt.map { Date().timeIntervalSince($0) < 12 } ?? false)
        if stillWorking { return }
        if finishAsk {
            markTaskReadyForReview(reason: "user-asked-finished")
        } else if strong {
            markTaskReadyForReview(reason: "claude-reply-done")
        }
    }

    private func markTaskReadyForReview(reason: String) {
        guard let tid = session?.taskID else {
            emit("done", "Claude ha finito (nessuna task linkata)")
            return
        }
        // Still actively tooling? Don't yank the card to REVIEW.
        if let last = lastRunningAt, Date().timeIntervalSince(last) < 12 {
            emit("running", "Ancora al lavoro — review rimandata")
            return
        }
        if lastReviewTaskID == tid, Date().timeIntervalSince(lastReviewMarkedAt) < 20 {
            return
        }
        lastReviewTaskID = tid
        lastReviewMarkedAt = .now
        if let ws = session?.workspacePath { git?.setPath(ws) }
        git?.refresh(force: true)
        tasks?.move(tid, to: .review)
        tasks?.updateProgress(tid, 0.9)
        let paths = git?.status.changes.prefix(12).map(\.path) ?? []
        if !paths.isEmpty {
            tasks?.appendEvidence(tid, "files:\(paths.joined(separator: ", "))")
            for p in paths {
                tasks?.appendEvidence(tid, "file:\(p)")
            }
        }
        tasks?.appendEvidence(tid, reason)
        let root = session?.workspacePath ?? "?"
        let list = git?.status.changes.prefix(10).map { "• `\($0.path)`" }.joined(separator: "\n") ?? ""
        let gate = QualityGate.run(workspace: root, git: git)
        tasks?.appendEvidence(tid, "quality:\(gate.summary)")
        for line in gate.lines.prefix(6) {
            tasks?.appendEvidence(tid, "qg:\(line)")
        }
        emit("done", "QS Task → IN REVISIONE")
        noticeOnce("review-\(tid.uuidString.prefix(8))", """
        **QS Task → IN REVISIONE (~90%)**

        Repo: `\(root)`
        \(list.isEmpty ? "Controlla Git / GitHub Desktop su questo path." : "File:\n\(list)\n")
        \(gate.chatMarkdown)

        Scrivi i ritocchi in chat e premi **Applica feedback**, oppure **Completa** sulla card in QS Tasks.
        Accetta/rifiuta i file nel dettaglio task (Accept / Reject).
        """)
        if session?.phase != .done {
            setPhase(.done)
        }
    }

    private static func looksLikeFinishQuestion(_ q: String) -> Bool {
        let low = q.lowercased()
        return low.contains("hai finito") || low.contains("task finita") || low.contains("task finito")
            || low.contains("completata") || low.contains("è finita") || low.contains("e' finita")
            || low.contains("finished") || low.contains("are you done") || low.contains("done with the task")
    }

    /// Strip TUI chrome / spinner junk from a Claude reply for chat.
    private static func cleanTerminalReply(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let l = line.lowercased()
                if l.contains("auto mode on") || l.contains("shift+tab") { return false }
                if l.hasPrefix("⏵") || l.hasPrefix("❯") || l == "·" { return false }
                if l.contains("esc to interrupt") || l.contains("for agents") { return false }
                if l.hasPrefix("thought for") || l.hasPrefix("scurrying") { return false }
                return true
            }
        // Keep last ~40 useful lines
        let slice = lines.suffix(40)
        var out = slice.joined(separator: "\n")
        if out.count > 3500 {
            out = "…" + String(out.suffix(3400))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func classify(text: String, session s: Session) -> Phase {
        let low = text.lowercased()
        guard s.goalSent else {
            if looksLikeAuthMenu(text) { return .menu }
            if looksLikeAwaitingInput(low) { return .awaitingInput }
            if looksLikeReady(text) { return .starting }
            return s.phase == .idle ? .starting : s.phase
        }

        // Limit: strict phrases + 3s hold (avoid flicker)
        if looksLikeLimit(low) {
            if limitHoldSince == nil { limitHoldSince = .now }
            if let t = limitHoldSince, Date().timeIntervalSince(t) >= 3 { return .limit }
        } else {
            limitHoldSince = nil
        }

        // Don't treat idle prompt footer as "awaiting confirmation"
        if looksLikeAwaitingInput(low), !looksLikeReady(text) { return .awaitingInput }

        if looksLikeRunning(low) {
            lastRunningAt = .now
            doneHoldSince = nil
            return .running
        }

        // Done: strong completion + quiet after last tool use (never dirty-alone)
        if looksLikeStrongDone(low), isDoneEligible(session: s), hasBeenQuietAfterWork(minQuiet: 12) {
            if doneHoldSince == nil { doneHoldSince = .now }
            let hold: TimeInterval = gitWorkingTreeDirty() ? 5 : 8
            if let t = doneHoldSince, Date().timeIntervalSince(t) >= hold { return .done }
        } else {
            doneHoldSince = nil
        }

        // Sitting at ❯ after real work: require strong done OR (dirty + long quiet), never dirty alone early
        if s.goalSent, looksLikeReady(text), !looksLikeRunning(low),
           let sent = goalSentAt, Date().timeIntervalSince(sent) >= 50,
           hasBeenQuietAfterWork(minQuiet: 18) {
            if looksLikeStrongDone(low) { return .done }
            // Dirty + idle prompt for a while — likely finished without a “Fatto.” line
            if gitWorkingTreeDirty(), Date().timeIntervalSince(sent) >= 90 {
                return .done
            }
        }

        // Idle prompt after goal without confirmation — keep running
        return .running
    }

    /// True when Claude has not shown a “running” signal for `minQuiet` seconds.
    private func hasBeenQuietAfterWork(minQuiet: TimeInterval) -> Bool {
        guard let last = lastRunningAt else {
            // Never saw running — only allow done after goal has been out for a while
            guard let sent = goalSentAt else { return false }
            return Date().timeIntervalSince(sent) >= 45
        }
        return Date().timeIntervalSince(last) >= minQuiet
    }

    private func isDoneEligible(session s: Session) -> Bool {
        guard let sent = goalSentAt else { return false }
        let elapsed = Date().timeIntervalSince(sent)
        // Fast path: Italian/English “Fatto” + git dirty after ≥25s work
        if elapsed >= 25, termLineGrowth() >= 12, gitWorkingTreeDirty() {
            return true
        }
        // Conservative path: longer work + quiet
        guard elapsed >= 60 else { return false }
        guard termLineGrowth() >= 20 else { return false }
        guard let q = quietSince, Date().timeIntervalSince(q) >= 8 else { return false }
        return true
    }

    private func gitWorkingTreeDirty() -> Bool {
        // Use last snapshot (refresh on applyPhase / write notify) — don't spam git in the poll loop
        let st = git?.status
        guard st?.isRepo == true else { return false }
        return (st?.stagedCount ?? 0) + (st?.unstagedCount ?? 0) + (st?.untrackedCount ?? 0) > 0
    }

    private func applyPhase(_ phase: Phase, tail: String) {
        guard session != nil else { return }
        // Don't bounce DONE/LIMIT → RUNNING on noise
        if session?.phase == .done || session?.phase == .limit, phase == .running {
            return
        }
        setPhase(phase)
        appendTailEvidence(tail)
        switch phase {
        case .running:
            if let tid = session?.taskID { tasks?.move(tid, to: .inProgress) }
            emit("running", shortDetail(tail))
        case .awaitingInput:
            emit("waitingTerminal", "Claude aspetta conferma — rispondi in chat")
            noticeOnce("await-\(session?.terminalID.uuidString.prefix(8) ?? "")",
                       "**Claude chiede conferma** nel terminale. Scrivi qui la risposta: la mando nello stesso PTY.")
        case .limit:
            if let tid = session?.taskID {
                tasks?.move(tid, to: .review)
                tasks?.appendEvidence(tid, "claude-limit")
            }
            emit("waitingTerminal", "Limite/crediti Claude")
            noticeOnce("limit",
                       "**Limite token/crediti** raggiunto. Ricarica OpenRouter/Anthropic, poi scrivi in chat per continuare **nello stesso PTY**.")
            git?.refresh(force: true)
        case .done:
            pendingRelay = nil
            // Shared path with chat follow-up «hai finito?»
            markTaskReadyForReview(reason: gitWorkingTreeDirty() ? "supervisor-done-dirty" : "supervisor-done-verify")
        case .error:
            if let tid = session?.taskID { tasks?.move(tid, to: .review) }
            emit("runningTool", "Errore sessione Claude")
        case .menu:
            emit("menu", "Menu login/account Claude")
        case .starting, .idle:
            break
        }
    }

    // MARK: - Heuristics

    /// Only auth/account choosers — NOT generic numbered lists / permission dialogs.
    private func looksLikeAuthMenu(_ text: String) -> Bool {
        let low = text.lowercased()
        let authCtx = low.contains("login") || low.contains("log in") || low.contains("sign in")
            || low.contains("which account") || low.contains("subscription")
            || low.contains("anthropic account") || low.contains("claude.ai")
            || (low.contains("choose") && (low.contains("account") || low.contains("login") || low.contains("auth")))
        guard authCtx else { return false }
        let lines = text.split(separator: "\n").suffix(16).map(String.init)
        let numbered = lines.filter { $0.range(of: #"^\s*[1-9][\.\)]\s"#, options: .regularExpression) != nil }
        return numbered.count >= 1
    }

    private func looksLikeReady(_ text: String) -> Bool {
        let low = text.lowercased()
        if looksLikeAuthMenu(text) { return false }
        if looksLikeAwaitingInput(low) { return false }
        if low.contains("auto mode") { return true }
        if low.contains("shift+tab") || low.contains("double-tap esc") { return true }
        if text.contains("❯") { return true }
        if low.contains("type a message") || low.contains("ask claude") { return true }
        return false
    }

    private func looksLikeRunning(_ low: String) -> Bool {
        low.contains("thinking") || low.contains("scurry") || low.contains("scurrying")
            || low.contains("running tool") || low.contains("tool use")
            || low.contains("reading ") || low.contains("editing ") || low.contains("writing ")
            || low.contains("searched") || low.contains("applying")
    }

    private func looksLikeLimit(_ low: String) -> Bool {
        let phrases = [
            "rate limit", "usage limit", "hit your limit", "you've hit",
            "out of credit", "out of credits", "insufficient credit", "insufficient credits",
            "credit balance", "monthly limit", "quota exceeded", "quota limit",
            "too many requests", "error 429", "http 429", "error 402", "http 402",
            "limit raggiunto", "crediti esauriti", "senza crediti",
        ]
        return phrases.contains { low.contains($0) }
    }

    private func looksLikeAwaitingInput(_ low: String) -> Bool {
        low.contains("do you want") || low.contains("would you like")
            || low.contains("shall i") || low.contains("proceed?")
            || low.contains("(y/n)") || low.contains("[y/n]")
            || low.contains("vuoi che") || low.contains("posso procedere")
            || (low.contains("allow") && (low.contains("permission") || low.contains("access")))
            || low.contains("press enter to") || low.contains("waiting for")
    }

    /// Strong completion only — never bare "git status" / mid-task "riepilogo".
    private func looksLikeStrongDone(_ low: String) -> Bool {
        let phrases = [
            "i've made the changes", "i have made the changes", "i've updated",
            "changes have been applied", "modifiche applicate", "modifiche completate",
            "here's a summary of the changes", "summary of the changes", "summary of changes",
            "all done", "fatto! ho", "ho finito", "work is complete",
            "committed the",
            // Italian Claude Code wrap-ups — avoid bare "riepilogo" (appears mid-plan)
            "fatto.", "fatto\n", "fatto. solo", "fatto. ho",
            "riepilogo delle modifiche", "riepilogo finale", "piano eseguito",
            "file modificato", "cosa è cambiato",
            "verifica: git status", "nessun altro file",
            "fix applicati", "modifiche, entrambe",
        ]
        return phrases.contains { low.contains($0) }
    }

    // MARK: - Helpers

    private func ensureBoardTask(goal: String, workspace: String, terminalID: UUID) -> AgentTask? {
        if let s = session, let tid = s.taskID, let t = tasks?.task(id: tid) {
            if t.linkedTerminalID == nil { tasks?.linkTerminal(tid, terminalID: terminalID) }
            return tasks?.task(id: tid) ?? t
        }
        guard let task = tasks?.ensureLinkedTask(
            goal: goal,
            workspacePath: workspace,
            titlePrefix: "Claude Code",
            model: "claude-code-cli",
            evidence: ["claude-code-cli", "supervisor", "ws:\(workspace)"]
        ) else { return nil }
        if task.linkedTerminalID != terminalID {
            tasks?.linkTerminal(task.id, terminalID: terminalID)
        }
        return tasks?.task(id: task.id) ?? task
    }

    private func terminal(for id: UUID) -> TerminalSession? {
        terminals?.sessions.first { $0.id == id }
    }

    private func tail(of term: TerminalSession, lines: Int = 30) -> String {
        term.displayLines.suffix(lines).joined(separator: "\n")
    }

    private func termLineGrowth() -> Int {
        guard let s = session, let term = terminal(for: s.terminalID) else { return 0 }
        return max(0, term.displayLines.count - lineCountAtGoalSend)
    }

    private func shortDetail(_ text: String) -> String {
        let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? "Claude attivo"
        return String(line.suffix(72))
    }

    private func appendTailEvidence(_ text: String) {
        guard let tid = session?.taskID else { return }
        let fp = String(text.suffix(120))
        guard fp != lastEvidenceFingerprint else { return }
        lastEvidenceFingerprint = fp
        let compact = fp
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 8 else { return }
        tasks?.appendEvidence(tid, "log:\(String(compact.prefix(80)))")
    }

    private func setPhase(_ phase: Phase) {
        guard var s = session, s.phase != phase else { return }
        s.phase = phase
        s.lastPhaseChange = .now
        session = s
    }

    private func emit(_ label: String, _ detail: String) {
        // Collapse spam: same label+detail within 4s, or footer noise
        let clean = detail
            .replacingOccurrences(of: #"▶▶.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(label)|\(clean.prefix(48))"
        if key == lastEmitKey, Date().timeIntervalSince(lastEmitAt) < 4 { return }
        if clean.contains("auto mode on") || clean.contains("shift+tab") { return }
        lastEmitKey = key
        lastEmitAt = .now
        onActivity?(label, clean.isEmpty ? detail : clean)
    }

    private func noticeOnce(_ key: String, _ message: String) {
        guard key != lastChatNoticeKey else { return }
        lastChatNoticeKey = key
        onChatNotice?(message)
    }
}
