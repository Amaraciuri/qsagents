import Foundation

/// LLM + tools loop for a single AgentSession (Fase 3).
@MainActor
final class AgentRuntime {
    private let llm = LLMClient.shared
    private let tools = AgentToolRunner()

    weak var store: AgentSessionStore? {
        didSet { tools.missionStore = store }
    }
    weak var terminals: TerminalManager? {
        didSet { tools.terminals = terminals }
    }
    weak var workspaces: WorkspaceStore? {
        didSet { tools.workspaces = workspaces }
    }
    weak var tasks: TaskStore? {
        didSet { tools.tasks = tasks }
    }
    weak var git: GitService? {
        didSet { tools.git = git }
    }
    weak var safety: SafetyGuardrails? {
        didSet { tools.safety = safety }
    }
    weak var knowledge: KnowledgeStore? {
        didSet { tools.knowledge = knowledge }
    }

    private var running: Set<UUID> = []
    private var cancelled: Set<UUID> = []
    /// Live loop handles so Stop can interrupt mid-`await llm.complete`.
    private var loopTasks: [UUID: Task<Void, Never>] = [:]
    /// Orchestrator chat → next LLM turn (IDE follow-up without new session).
    private var pendingGuidance: [UUID: [String]] = [:]

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Inject user guidance into a running (or about-to-run) agent loop.
    func injectGuidance(sessionId: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pendingGuidance[sessionId, default: []].append(t)
    }

    private func drainGuidance(into history: inout [LLMMessage], sessionId: UUID) {
        guard let notes = pendingGuidance.removeValue(forKey: sessionId), !notes.isEmpty else { return }
        for n in notes {
            history.append(LLMMessage(
                role: .user,
                content: """
                GUIDA UTENTE (Orchestratore — priorità alta):
                \(n)
                Applica questa guida nei prossimi tool (propose_patch/apply_patch se serve codice).
                """
            ))
        }
    }

    /// Cooperative + hard cancel: flag + cancel Swift Task (drops in-flight LLM await).
    func cancel(_ id: UUID) {
        cancelled.insert(id)
        loopTasks[id]?.cancel()
        loopTasks[id] = nil
        running.remove(id)
        pendingGuidance.removeValue(forKey: id)
    }

    func cancelAll() {
        let ids = Array(running) + Array(loopTasks.keys)
        for id in Set(ids) {
            cancel(id)
        }
        // Also mark every known session id as cancelled if still looping
        cancelled.formUnion(running)
        pendingGuidance.removeAll()
    }

    private func shouldStop(_ sessionId: UUID) -> Bool {
        cancelled.contains(sessionId) || Task.isCancelled
    }

    private func startLoop(sessionId: UUID, goal: String, maxSteps: Int) {
        // Replace any previous loop for this session
        loopTasks[sessionId]?.cancel()
        cancelled.remove(sessionId)
        running.insert(sessionId)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.loop(sessionId: sessionId, goal: goal, maxSteps: maxSteps)
        }
        loopTasks[sessionId] = task
    }

    /// Run autonomous agent loop on a task (with optional swarm context).
    /// `resume`: same agent re-clicked Avvia — forbid full re-explore; continue from prior log.
    func runTask(
        sessionId: UUID,
        taskTitle: String,
        taskId: UUID?,
        workspace: String?,
        maxSteps: Int? = nil,
        missionGoal: String? = nil,
        taskSubtitle: String? = nil,
        coordinatorSummary: String? = nil,
        resume: Bool = false
    ) {
        // Don't stack a second loop on the same session (double-Avvia).
        if isRunning(sessionId) {
            store?.append(
                sessionId,
                "Loop già attivo — ignoro secondo avvio (nessun nuovo PTY).",
                level: .warning
            )
            return
        }
        tools.workspaceRoot = workspace
        tools.taskId = taskId
        let role = store?.sessions.first(where: { $0.id == sessionId })?.role ?? .builder
        tools.agentRole = role
        tools.linkedTerminalID = store?.sessions.first(where: { $0.id == sessionId })?.linkedTerminalID
        let goalMode = store?.mission?.goalMode == true
        let steps = maxSteps ?? (goalMode
            ? TokenBudget.goalAgentMaxSteps(for: role)
            : TokenBudget.agentMaxSteps(for: role))

        let resumeBlock = resume ? """
        RIPRESA SESSIONE (stesso agent/PTY — l'utente ha ricliccato Avvia):
        - VIETATO ripetere repo_capsule / search_knowledge / read_file del file intero se già nel log.
        - Usa path:line già noti; se UI manca id/class o foglio caricato, UN read_file around=LINE.
        - Poi propose_patch → apply_patch → git_status → complete_task (no patch cieca).
        """ : ""

        // Prefer store-enriched brief when available
        let session = store?.sessions.first(where: { $0.id == sessionId })
        let goal: String
        if let session, let store {
            let instr = resume
                ? "CONTINUA e completa questa task (no re-explore): \(taskTitle)"
                : "Esegui e completa questa task board: \(taskTitle)"
            let base = store.contextualWorkBrief(for: session, userInstruction: instr)
            goal = resumeBlock.isEmpty ? base : base + "\n" + resumeBlock
        } else {
            var lines = [
                "Task: \(taskTitle)",
                "WS: \(workspace ?? "n/d")",
            ]
            if let missionGoal, !missionGoal.isEmpty {
                lines.append("Missione: \(missionGoal)")
            }
            if let taskSubtitle, !taskSubtitle.isEmpty {
                lines.append("Dettaglio: \(taskSubtitle)")
            }
            if let coordinatorSummary, !coordinatorSummary.isEmpty {
                lines.append("Piano: \(String(coordinatorSummary.prefix(400)))")
            }
            if !resumeBlock.isEmpty { lines.append(resumeBlock) }
            lines.append("OBBLIGO: questa È la task. Ispeziona solo quanto serve → propose/apply o complete_task. MAI «in attesa di task».")
            goal = lines.joined(separator: "\n")
        }

        startLoop(sessionId: sessionId, goal: goal, maxSteps: steps)
    }

    /// Free-form agent run (swarm / orchestrator spawn).
    func runGoal(sessionId: UUID, goal: String, workspace: String?, maxSteps: Int? = nil) {
        tools.workspaceRoot = workspace
        let sess = store?.sessions.first(where: { $0.id == sessionId })
        tools.taskId = sess?.taskId
        tools.linkedTerminalID = sess?.linkedTerminalID
        let role = sess?.role ?? .builder
        tools.agentRole = role
        let goalMode = store?.mission?.goalMode == true
        let steps = maxSteps ?? (goalMode
            ? TokenBudget.goalAgentMaxSteps(for: role)
            : TokenBudget.agentMaxSteps(for: role))

        // Cap goal size — allow slightly more for contextual briefs
        let g = goal.count > 2200 ? String(goal.prefix(2200)) + "…" : goal
        startLoop(sessionId: sessionId, goal: g, maxSteps: steps)
    }

    private func loop(sessionId: UUID, goal: String, maxSteps: Int) async {
        defer {
            running.remove(sessionId)
            loopTasks[sessionId] = nil
        }

        if shouldStop(sessionId) {
            store?.setStatus(sessionId, .idle)
            return
        }

        // Resolve provider/model: same pool as orchestrator (never bootstrap if ANY key exists).
        let session = store?.sessions.first(where: { $0.id == sessionId })
        let role = session?.role ?? tools.agentRole
        var picked = Self.pickLiveLLM(session: session, role: role, llm: llm)
        if picked == nil, let p = ProviderPreferences.shared.anyKeyedProvider() {
            // Last-chance sync: orchestrator key exists but Swarm routing was still «local».
            let m = ProviderPreferences.shared.model(for: role)
            ProviderPreferences.shared.syncSwarmFromLive(
                provider: p,
                model: m == "local" ? p.defaultModel : m
            )
            picked = Self.pickLiveLLM(session: session, role: role, llm: llm)
            store?.append(
                sessionId,
                "Retry LLM · sync da Integrazioni → \(p.displayName)",
                level: .thinking
            )
        }
        guard let picked else {
            if shouldStop(sessionId) { return }
            await localBootstrap(sessionId: sessionId, goal: goal)
            return
        }
        let useProvider = picked.provider
        var useModel = Self.sanitizeModelID(picked.model, provider: useProvider)
        // Persist RAW model id only — never "OpenRouter/anthropic/…" (breaks resume → HTTP 400).
        store?.setProviderAndModel(sessionId, providerRaw: useProvider.rawValue, model: useModel)

        store?.setStatus(sessionId, .thinking)
        store?.append(
            sessionId,
            "LLM loop · \(useProvider.displayName) · \(useModel) · ruolo \(role.displayName)",
            level: .thinking
        )

        let isBuilder = (role == .builder || role == .general || role == .deployer)
        let system = """
        Agent QS · \(role.rawValue) · \(useProvider.displayName)/\(useModel)
        WS: \(tools.workspaceRoot ?? "n/d")
        \(tools.describeToolsForPrompt())
        Output: SOLO un JSON tool (o {"tools":[…]} max 3 RO). Italiano breve.
        \(isBuilder ? """
        BUILDER — QUALITÀ (come Cursor/Claude), poi token:
        - 1°: UNA sola repo_capsule (termini del titolo). NON list_dir root / ROADMAP / cat.
        - search_knowledge = locate (path:line). NON ripetere capsule.
        - read_file SEMPRE con around=LINE o start_line (mai file CSS/JS intero).
        - Task UI/visiva: 1) leggi markup/JS che crea il controllo (id/class) 2) leggi il CSS/JS GIÀ caricato da index.html/boot 3) patcha QUEL path tracked 4) git_status 5) complete_task.
        - VIETATO patchare un CSS “simile” non linkato, o selettori inventati senza aver letto il markup.
        - Edita SOLO sorgente tracked: root (premium-ui.css/js, index.html, …) o src/. VIETATO www/ build, ios/, android/ mirrors.
        - Se la capsule mostra www/X, patcha X in root (o src/X).
        - Dopo ~\(TokenBudget.builderMaxExploreSteps) round spreco (list_dir / capsule ripetute / read senza around): progresso utile — conferma target, oppure propose/apply, oppure finish con path provati.
        - VIETATO finish con «nessun task» / «in attesa» — il titolo board È la task.
        - complete_task solo dopo apply_patch riuscito (gate hard).
        """ : "Preferisci repo_capsule prima di list_dir; finish con path tracked da editare (non www/).")
        """

        tools.resetSessionWriteState()

        var history: [LLMMessage] = [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: goal),
        ]

        var totalUsage = LLMUsage.zero
        var finished = false
        var exploreOnlySteps = 0
        var consecutiveSearchKnowledge = 0
        var emptyRetries = 0
        var creditsRetried = false
        let goalMode = store?.mission?.goalMode == true
        let tokenBudget = goalMode ? TokenBudget.goalAgentSessionBudget : TokenBudget.agentSessionBudget
        let reserve = goalMode ? TokenBudget.goalAgentBudgetReserve : TokenBudget.agentBudgetReserve
        var maxCompletion = TokenBudget.agentMaxCompletion(provider: useProvider, goalMode: goalMode)
        if goalMode {
            store?.append(sessionId, "GOAL MODE · budget \(tokenBudget) tok · completion \(maxCompletion)", level: .muted)
        } else if useProvider == .openRouter {
            store?.append(
                sessionId,
                "OpenRouter · completion cap \(maxCompletion) (evita 402 su max_tokens alti)",
                level: .muted
            )
        }
        for step in 1...maxSteps {
            if shouldStop(sessionId) {
                finishCancelled(sessionId)
                return
            }

            store?.setStatus(sessionId, .thinking)
            store?.setProgress(sessionId, Double(step - 1) / Double(maxSteps))
            store?.append(sessionId, "Step \(step)/\(maxSteps)…", level: .muted)

            // Budget BEFORE paying for another LLM call (was overshooting to 20k+)
            if totalUsage.totalTokens + reserve >= tokenBudget {
                let msg = goalMode
                    ? "Budget token sessione (~\(totalUsage.totalTokens)/\(tokenBudget)). GOAL MODE: stop builder → orchestratore spezza in mini-task."
                    : "Budget token quasi esaurito (~\(totalUsage.totalTokens)/\(tokenBudget)). Stop per non sprecare. Rilancia con goal più stretto o continua manualmente."
                store?.append(sessionId, msg, level: .warning)
                store?.setStatus(sessionId, .idle)
                store?.setProgress(sessionId, 0.85)
                store?.agentDidFinish(sessionId: sessionId, summary: "token budget")
                finished = true
                break
            }

            // Orchestrator follow-up mid-loop (chat → same IDE session)
            drainGuidance(into: &history, sessionId: sessionId)

            // Soft nudge after wasteful exploration — never force a blind patch
            if isBuilder, exploreOnlySteps >= TokenBudget.builderMaxExploreSteps {
                history.append(LLMMessage(
                    role: .user,
                    content: """
                    PROGRESSO UTILE (\(exploreOnlySteps) round spreco). Non patchare alla cieca.
                    Scegli UNO: (A) conferma target — read_file markup/JS (id/class) + CSS/JS già caricato da index/boot; \
                    (B) propose_patch → apply_patch sul path TRACKED corretto (root/src, mai www/); \
                    (C) finish con motivo + path già provati.
                    Vietato: CSS non linkato, selettori inventati, list_dir enorme, ROADMAP, cat, altra repo_capsule.
                    """
                ))
                store?.append(sessionId, "Nudge: conferma target o patch tracked (non rush)", level: .thinking)
                if history.count > TokenBudget.agentHistoryMessages + 2 {
                    history = [history[0]] + Array(history.suffix(TokenBudget.agentHistoryMessages - 1))
                }
            }

            // Stall: search_knowledge looping without reading or patching
            if isBuilder, consecutiveSearchKnowledge >= 2 {
                history.append(LLMMessage(
                    role: .user,
                    content: """
                    STALLO: \(consecutiveSearchKnowledge) search_knowledge di fila senza read_file / propose_patch.
                    OBBLIGO prossimo tool: (1) read_file sul path:line migliore dal locate, POI (2) propose_patch sul file TRACKED.
                    Vietato un altro search_knowledge / repo_capsule finché non hai letto o patchato.
                    """
                ))
                store?.append(
                    sessionId,
                    "Nudge antistallo: stop search_knowledge → read_file poi propose_patch",
                    level: .warning
                )
                if history.count > TokenBudget.agentHistoryMessages + 2 {
                    history = [history[0]] + Array(history.suffix(TokenBudget.agentHistoryMessages - 1))
                }
            }

            do {
                let completion = try await llm.complete(
                    messages: history,
                    provider: useProvider,
                    model: useModel,
                    temperature: 0.2,
                    maxTokens: maxCompletion
                )

                // Critical: stop may have arrived during await — do not keep going
                if shouldStop(sessionId) {
                    finishCancelled(sessionId)
                    return
                }

                totalUsage = totalUsage + completion.usage
                store?.addTokens(sessionId, completion.usage.totalTokens)
                // Keep raw model id — UI formats provider/model for display.
                let rawOut = Self.sanitizeModelID(completion.model, provider: completion.provider)
                useModel = rawOut
                store?.setProviderAndModel(sessionId, providerRaw: completion.provider.rawValue, model: rawOut)

                let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty body after a working session: retry, never "local bootstrap"
                if text.isEmpty {
                    emptyRetries += 1
                    store?.append(sessionId, "Risposta LLM vuota — retry \(emptyRetries)/2…", level: .warning)
                    if emptyRetries <= 2 {
                        // Shrink history (capsule can choke the next turn) and force patch
                        if history.count > 4 {
                            history = [history[0]] + Array(history.suffix(2))
                        }
                        history.append(LLMMessage(role: .user, content: """
                            Risposta vuota. Ora OBBLIGO un solo JSON:
                            {"tool":"propose_patch","path":"premium-ui.css","content":"…css motion home…"}
                            oppure read_file path premium-ui.js se ti manca contesto. No list_dir.
                            """))
                        continue
                    }
                    store?.append(sessionId, "LLM vuoto ripetuto — stop (non bootstrap locale).", level: .error)
                    store?.setStatus(sessionId, .error)
                    store?.agentDidFinish(sessionId: sessionId, summary: "empty LLM")
                    finished = true
                    break
                }
                emptyRetries = 0
                store?.append(sessionId, String(text.prefix(400)), level: .code)

                let calls = tools.parseToolCalls(from: text)
                guard !calls.isEmpty else {
                    // Typo / partial JSON: do NOT kill the loop — re-prompt (was ending on repo_capsool)
                    if AgentToolRunner.looksLikeFailedToolAttempt(text) {
                        store?.append(
                            sessionId,
                            "Tool JSON non valido (typo o troncato). Riprovo…",
                            level: .warning
                        )
                        history.append(LLMMessage(role: .assistant, content: String(text.prefix(500))))
                        history.append(LLMMessage(role: .user, content: """
                            JSON tool non riconosciuto. Tool validi: repo_capsule, read_file, list_dir, propose_patch, apply_patch, complete_task, finish.
                            Esempio: {"tool":"repo_capsule","query":"premium-ui home motion"}
                            oppure {"tool":"propose_patch","path":"premium-ui.css","content":"…"}
                            Solo un JSON, niente testo.
                            """))
                        continue
                    }
                    store?.append(sessionId, "Nessun tool JSON — chiudo con testo libero.", level: .warning)
                    store?.append(sessionId, text, level: .success)
                    store?.setStatus(sessionId, .idle)
                    store?.setProgress(sessionId, 1)
                    finished = true
                    break
                }

                if shouldStop(sessionId) {
                    finishCancelled(sessionId)
                    return
                }

                // Terminal tools
                if calls.count == 1, calls[0].name == .finish {
                    let msg = calls[0].args["message"] ?? "Completato"
                    // Reject cop-out finish when a board task / goal was given
                    if Self.isCopOutFinish(msg), tools.taskId != nil || !goal.isEmpty {
                        store?.append(
                            sessionId,
                            "Finish rifiutato: «nessun task» non valido — la task è nel brief. Continua con propose_patch.",
                            level: .warning
                        )
                        history.append(LLMMessage(role: .assistant, content: calls[0].raw))
                        history.append(LLMMessage(role: .user, content: """
                            finish RIFIUTATO. Hai una task board nel system/user brief (titolo tipo Motion/homepage).
                            NON dire che manca il task. Ora: repo_capsule o read_file su premium-ui.js / premium-ui.css → propose_patch.
                            """))
                        continue
                    }
                    store?.append(sessionId, "✓ \(msg)", level: .success)
                    store?.setStatus(sessionId, .idle)
                    store?.setProgress(sessionId, 1)
                    if let tid = tools.taskId {
                        tasks?.move(tid, to: .review)
                        tasks?.updateProgress(tid, 0.9)
                    }
                    store?.agentDidFinish(sessionId: sessionId, summary: msg)
                    finished = true
                    break
                }

                if calls.count == 1, calls[0].name == .complete_task {
                    let result = tools.execute(calls[0])
                    store?.append(sessionId, result.output, level: result.ok ? .success : .error)
                    if !result.ok {
                        // BUG-004: failed complete_task must keep looping
                        history.append(LLMMessage(role: .assistant, content: calls[0].raw))
                        history.append(LLMMessage(
                            role: .user,
                            content: "complete_task rifiutato:\n\(result.output)\nContinua: apply_patch (se manca) → git_status → complete_task, oppure finish con motivo."
                        ))
                        if history.count > TokenBudget.agentHistoryMessages {
                            history = [history[0]] + Array(history.suffix(TokenBudget.agentHistoryMessages - 1))
                        }
                        continue
                    }
                    store?.setStatus(sessionId, .idle)
                    store?.setProgress(sessionId, 1)
                    store?.agentDidFinish(sessionId: sessionId, summary: result.output, taskCompleted: true)
                    finished = true
                    break
                }

                store?.setStatus(sessionId, .active)

                // Cap parallel batch size (token + thrash)
                let limitedCalls = Array(calls.prefix(3))

                // C4: parallel when all read-only and count > 1
                let results: [(AgentToolCall, AgentToolResult)]
                let allRO = limitedCalls.allSatisfy { AgentToolRunner.isReadOnly($0.name) }
                if limitedCalls.count > 1, allRO {
                    store?.append(
                        sessionId,
                        "→ parallel ×\(limitedCalls.count): \(limitedCalls.map(\.name.rawValue).joined(separator: ", "))",
                        level: .info
                    )
                    results = await tools.executeParallel(limitedCalls)
                } else {
                    var acc: [(AgentToolCall, AgentToolResult)] = []
                    for call in limitedCalls {
                        if shouldStop(sessionId) { break }
                        store?.append(sessionId, "→ \(call.name.rawValue)", level: .info)
                        acc.append((call, tools.execute(call)))
                    }
                    results = acc
                }

                // Count only wasteful RO (list_dir / repeated capsule / unscoped read) — not locate/git_status/scoped read
                if allRO {
                    let wasteful = limitedCalls.contains { Self.isWastefulExplore($0) }
                    if wasteful {
                        exploreOnlySteps += 1
                    }
                } else {
                    exploreOnlySteps = 0
                }

                // Consecutive search_knowledge without read/patch → stall counter
                let names = limitedCalls.map(\.name)
                if names.contains(where: { $0 == .read_file || $0 == .propose_patch || $0 == .apply_patch }) {
                    consecutiveSearchKnowledge = 0
                } else if names.allSatisfy({ $0 == .search_knowledge }) {
                    consecutiveSearchKnowledge += 1
                } else {
                    consecutiveSearchKnowledge = 0
                }

                if shouldStop(sessionId) {
                    finishCancelled(sessionId)
                    return
                }

                var combined = ""
                for (call, result) in results {
                    let perTool = TokenBudget.historyClipLimit(for: call.name)
                    // UI console (Swarm + Terminali): keep full-ish tool output for copy/read.
                    // LLM history still clipped via clipToolForHistory (token economy).
                    let uiCap = TokenBudget.uiLogLimit(for: call.name)
                    let uiText: String = {
                        if result.output.count <= uiCap { return result.output }
                        return String(result.output.prefix(uiCap)) + "\n… [UI log clipped \(result.output.count) chars]"
                    }()
                    store?.append(
                        sessionId,
                        "→ \(call.name.rawValue)\n\(uiText)",
                        level: result.ok ? .success : .error
                    )
                    // Real PTY pane (Terminali grid): same stream so panes aren't empty shells
                    tools.mirrorToLinkedPTY(tool: call.name.rawValue, output: uiText, ok: result.ok)
                    let clipped = Self.clipToolForHistory(name: call.name, output: result.output, limit: perTool)
                    combined += "### \(call.name.rawValue) ok=\(result.ok)\n\(clipped)\n\n"
                    if call.name == .ask_user {
                        store?.append(sessionId, "In attesa risposta utente…", level: .thinking)
                    }
                    if call.name == .propose_patch {
                        store?.append(sessionId, "Diff-first: patch in attesa di apply_patch", level: .thinking)
                    }
                }

                // Truncate tool JSON in history (propose_patch content is huge)
                let rawCap = TokenBudget.agentToolCallRawChars
                let rawJoined = calls.map { call -> String in
                    let r = call.raw
                    // For propose_patch: keep path only, not full content
                    if call.name == .propose_patch {
                        let path = call.args["path"] ?? "?"
                        return #"{"tool":"propose_patch","path":"\#(path)","content":"[omitted \#(call.args["content"]?.count ?? 0) chars]"}"#
                    }
                    return r.count > rawCap ? String(r.prefix(rawCap)) + "…" : r
                }.joined(separator: "\n")
                history.append(LLMMessage(role: .assistant, content: rawJoined))
                history.append(LLMMessage(
                    role: .user,
                    content: "Results (\(results.count)):\n\(combined.prefix(TokenBudget.agentToolResultsTotalChars))\nNext: one JSON tool or finish. No dumps."
                ))

                // Keep history small (system + recent turns only)
                let keep = TokenBudget.agentHistoryMessages
                if history.count > keep {
                    history = [history[0]] + Array(history.suffix(keep - 1))
                }
            } catch is CancellationError {
                finishCancelled(sessionId)
                return
            } catch {
                if shouldStop(sessionId) {
                    finishCancelled(sessionId)
                    return
                }
                // URLSession may surface cancel as generic error
                let msg = error.localizedDescription.lowercased()
                if msg.contains("cancel") || msg.contains("aborted") {
                    finishCancelled(sessionId)
                    return
                }
                let errMsg = error.localizedDescription
                store?.append(sessionId, "Errore LLM: \(errMsg)", level: .error)
                let lower = errMsg.lowercased()
                let llmErr = error as? LLMClientError

                // OpenRouter / credits: one cheaper retry, then stop with clear UX (not "bad model / rete").
                if let llmErr, llmErr.isCreditsFailure, !creditsRetried, !shouldStop(sessionId) {
                    creditsRetried = true
                    let afford = llmErr.suggestedMaxTokensCap
                    let reduced = min(
                        maxCompletion - 400,
                        afford ?? (maxCompletion * 2 / 3)
                    )
                    let next = max(TokenBudget.openRouterMinCompletion, reduced)
                    if next < maxCompletion {
                        maxCompletion = next
                        store?.append(
                            sessionId,
                            L("Crediti bassi (402) — ritento con max_tokens") + " \(maxCompletion). "
                                + L("Se fallisce: ricarica OpenRouter o scegli un modello più economico."),
                            level: .warning
                        )
                        continue
                    }
                }
                if let llmErr, llmErr.isCreditsFailure {
                    store?.setStatus(sessionId, .error)
                    store?.append(
                        sessionId,
                        L("Stop: crediti OpenRouter insufficienti (HTTP 402). Ricarica su openrouter.ai/settings/credits, abbassa il modello, o riprova — non è un bug di key/rete."),
                        level: .warning
                    )
                    if let tid = tools.taskId {
                        tasks?.move(tid, to: .review)
                        tasks?.appendEvidence(tid, "llm-402-credits")
                    }
                    store?.agentDidFinish(sessionId: sessionId, summary: "llm 402 credits: \(errMsg)")
                    return
                }

                // Bad model id (e.g. "OpenRouter/anthropic/…") — fix id and stay in LLM loop.
                let badModel = lower.contains("not a valid model") || lower.contains("invalid model")
                    || (lower.contains("model") && lower.contains("400"))
                if badModel, emptyRetries < 2, !shouldStop(sessionId) {
                    emptyRetries += 1
                    let fixed = Self.sanitizeModelID(useModel, provider: useProvider)
                    let fallback = fixed != useModel ? fixed : useProvider.defaultModel
                    useModel = fallback
                    store?.setProviderAndModel(sessionId, providerRaw: useProvider.rawValue, model: fallback)
                    ProviderPreferences.shared.setModel(fallback, for: role)
                    store?.append(
                        sessionId,
                        "Model id invalido → retry con `\(fallback)` (no bootstrap locale)",
                        level: .warning
                    )
                    if history.count > 5 {
                        history = [history[0]] + Array(history.suffix(3))
                    }
                    history.append(LLMMessage(role: .user, content: """
                        Errore modello corretto. Continua la task con un JSON tool (propose_patch con CSS/JS reale, non "APPEND").
                        """))
                    continue
                }
                // Transient empty / network / undecodable: retry without dropping into shell bootstrap
                let retryable = lower.contains("vuota") || lower.contains("empty")
                    || lower.contains("timeout") || lower.contains("temporar")
                    || lower.contains("rate") || lower.contains("529")
                    || lower.contains("overloaded") || lower.contains("503")
                    || lower.contains("non decodificabile") || lower.contains("undecodable")
                    || lower.contains("decodificabile")
                if retryable, emptyRetries < 2, !shouldStop(sessionId) {
                    emptyRetries += 1
                    store?.append(sessionId, "Errore transient — retry \(emptyRetries)/2 (resto in LLM)…", level: .warning)
                    if history.count > 5 {
                        history = [history[0]] + Array(history.suffix(3))
                    }
                    history.append(LLMMessage(role: .user, content: """
                        Errore API: \(errMsg). Continua la task con un JSON tool.
                        Preferisci: {"tool":"read_file","path":"package.json"} oppure propose_patch.
                        Mai read_file path="." (è una cartella — usa list_dir).
                        """))
                    continue
                }
                store?.setStatus(sessionId, .error)
                // Never pretend «no API key» after a real HTTP error (400/401/5xx).
                store?.append(
                    sessionId,
                    "Stop: errore LLM (key ok, richiesta fallita). Controlla model id / rete — no bootstrap locale.",
                    level: .warning
                )
                if let tid = tools.taskId {
                    tasks?.move(tid, to: .review)
                    tasks?.appendEvidence(tid, "llm-error-no-bootstrap")
                }
                store?.agentDidFinish(sessionId: sessionId, summary: "llm error: \(errMsg)")
                return
            }
        }

        if shouldStop(sessionId) {
            finishCancelled(sessionId)
            return
        }

        if !finished {
            store?.append(sessionId, "Max steps raggiunto — interrompo. Rivedi i log e rilancia se serve.", level: .warning)
            store?.setStatus(sessionId, .idle)
            store?.setProgress(sessionId, 0.85)
            if let tid = tools.taskId {
                tasks?.move(tid, to: .review)
            }
            store?.agentDidFinish(sessionId: sessionId, summary: "max steps")
        }

        store?.append(sessionId, "Token usati (sessione): \(totalUsage.totalTokens)", level: .muted)
        if totalUsage.totalTokens > 0 {
            ProviderPreferences.shared.recordUsage(tokens: totalUsage.totalTokens, provider: useProvider)
        }
        // Ensure mission pipeline advances when loop ends without explicit finish
        if finished {
            // agentDidFinish already called on finish/complete_task paths
        } else {
            // already called above for max steps
        }
        AppLogger.info("AgentRuntime done session=\(sessionId.uuidString.prefix(8)) tokens=\(totalUsage.totalTokens) model=\(useModel)")
    }

    private func finishCancelled(_ sessionId: UUID) {
        // Avoid double log spam if session already removed
        guard store?.sessions.contains(where: { $0.id == sessionId }) == true else { return }
        store?.append(sessionId, "⏹ Stop — loop interrotto", level: .warning)
        store?.setStatus(sessionId, .idle)
        store?.setProgress(sessionId, 0)
        AppLogger.info("AgentRuntime cancelled session=\(sessionId.uuidString.prefix(8))")
    }

    /// Agent tries to bail with “no task / waiting / need clearer request” despite board title.
    private static func isCopOutFinish(_ message: String) -> Bool {
        let m = message.lowercased()
        let needles = [
            "nessun task",
            "nessuna task",
            "in attesa di task",
            "non contiene una richiesta",
            "serve indicare",
            "task specifico",
            "task specifica",
            "waiting for a task",
            "no specific task",
            "no task provided",
            "non ho un task",
            "manca il task",
            "manca la task",
        ]
        return needles.contains { m.contains($0) }
    }

    /// Strip UI labels like `OpenRouter/anthropic/claude-opus-4.8` → `anthropic/claude-opus-4.8`.
    private static func sanitizeModelID(_ model: String?, provider: LLMProviderKind) -> String {
        var m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty || m == "local" { return provider.defaultModel }
        // "OpenRouter/anthropic/…" or "OpenRouter · anthropic/…"
        for p in LLMProviderKind.allCases {
            let names = [p.displayName, p.rawValue]
            for name in names {
                if m.hasPrefix(name + "/") {
                    m = String(m.dropFirst(name.count + 1))
                } else if m.hasPrefix(name + " · ") {
                    m = String(m.dropFirst(name.count + 3))
                } else if m.hasPrefix(name + " ·") {
                    m = String(m.dropFirst(name.count + 2)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        m = m.trimmingCharacters(in: .whitespacesAndNewlines)
        m = provider.canonicalizeModelID(m)
        return m.isEmpty ? provider.defaultModel : m
    }

    /// Pick any live LLM: session → role prefs → preferred → first keyed provider.
    private static func pickLiveLLM(
        session: AgentSession?,
        role: AgentRole,
        llm: LLMClient
    ) -> (provider: LLMProviderKind, model: String)? {
        let prefs = ProviderPreferences.shared
        var candidates: [(LLMProviderKind, String)] = []
        func push(_ p: LLMProviderKind?, model: String?) {
            guard let p, llm.hasKey(p) else { return }
            let m = sanitizeModelID(model, provider: p)
            if !candidates.contains(where: { $0.0 == p }) {
                candidates.append((p, m))
            }
        }
        if let raw = session?.providerRaw, let p = LLMProviderKind(rawValue: raw) {
            push(p, model: session?.model)
        }
        let resolved = prefs.resolve(for: role)
        push(resolved.provider, model: resolved.model)
        push(llm.preferredProvider(), model: prefs.model(for: role))
        push(prefs.anyKeyedProvider(), model: nil)
        for p in LLMProviderKind.allCases { push(p, model: p.defaultModel) }
        return candidates.first
    }

    /// Wasteful explore: list_dir, capsule, or unscoped read_file (no around/start_line).
    /// git_status / search_knowledge / scoped reads do not inflate the rush counter.
    private static func isWastefulExplore(_ call: AgentToolCall) -> Bool {
        switch call.name {
        case .list_dir, .repo_capsule:
            return true
        case .read_file:
            let around = call.args["around"] ?? ""
            let start = call.args["start_line"] ?? call.args["start"] ?? ""
            return around.isEmpty && start.isEmpty
        default:
            return false
        }
    }

    /// Aggressively shrink tool dumps that pollute history (list_dir / ROADMAP).
    /// repo_capsule keeps a larger budget — it is the structure-first context.
    private static func clipToolForHistory(name: AgentToolName, output: String, limit: Int) -> String {
        var s = output
        if name == .list_dir {
            let lines = s.components(separatedBy: "\n")
            if lines.count > 18 {
                s = lines.prefix(18).joined(separator: "\n") + "\n… (\(lines.count) lines total)"
            }
        }
        if name == .repo_capsule {
            if s.count > limit {
                s = String(s.prefix(limit)) + "\n… [capsule clipped]"
            }
            return s
        }
        if name == .search_knowledge || name == .read_file {
            if s.count > limit {
                s = String(s.prefix(limit)) + "…"
            }
            return s
        }
        if s.count > limit {
            s = String(s.prefix(limit)) + "…"
        }
        return s
    }

    /// No-API-key path: safe shell scout only.
    private func localBootstrap(sessionId: UUID, goal: String) async {
        if shouldStop(sessionId) {
            finishCancelled(sessionId)
            return
        }
        store?.append(sessionId, "Modalità locale (no LLM) — bootstrap workspace", level: .thinking)
        store?.setStatus(sessionId, .active)
        store?.setModel(sessionId, "local")

        let path = tools.workspaceRoot ?? workspaces?.current?.path
        if let path {
            let r1 = tools.execute(AgentToolCall(name: .list_dir, args: ["path": "."], raw: "{}"))
            if shouldStop(sessionId) { finishCancelled(sessionId); return }
            store?.append(sessionId, String(r1.output.prefix(400)), level: .code)
            store?.setProgress(sessionId, 0.4)

            if FileManager.default.fileExists(atPath: path + "/.git") {
                let r2 = tools.execute(AgentToolCall(name: .git_status, args: [:], raw: "{}"))
                store?.append(sessionId, String(r2.output.prefix(400)), level: .code)
            }

            // Do NOT open a new PTY here — bootstrap thrash used to spawn 100+ Terminali.
            store?.append(
                sessionId,
                "Nessuna API key per questo ruolo. Configura Anthropic/OpenRouter/Grok in Integrazioni + routing Swarm. Task → REVIEW (no auto-rilancio).",
                level: .warning
            )
            store?.setProgress(sessionId, 0.7)
            if let tid = tools.taskId {
                tasks?.appendEvidence(tid, "local-bootstrap-dead")
                tasks?.move(tid, to: .review)
            }
        } else {
            store?.append(sessionId, "Apri un workspace (⌘⇧O).", level: .warning)
        }
        if shouldStop(sessionId) {
            finishCancelled(sessionId)
            return
        }
        store?.setStatus(sessionId, .idle)
        store?.setProgress(sessionId, 1)
        store?.append(sessionId, "Bootstrap locale fine · goal: \(goal.prefix(80))", level: .success)
        // Critical: without this, GOAL stays in phase=planning forever («in coda o gate»).
        store?.agentDidFinish(sessionId: sessionId, summary: "local bootstrap (no LLM key)")
    }
}
