import Foundation

/// Typed tools the orchestrator can execute (Fase 2 + Git).
enum OrchestratorTool: Equatable {
    case openTerminal(path: String, role: AgentRole?)
    case runCommand(command: String, path: String?, role: AgentRole?)
    case listProjects
    case getSystemStatus
    case createTask(title: String, subtitle: String?, priority: TaskPriority, workspacePath: String?, model: String?)
    /// Start builder LLM loop on an existing board task (by id prefix or title).
    case startBoardTask(titleOrId: String)
    case completeTask(titleOrId: String)
    case deleteTask(titleOrId: String)
    case switchView(String)
    case openWorkspace(path: String)
    /// Ordered setup tasks on the QS Tasks board for a project.
    case createPlan(path: String?)
    /// One-shot project flow: open WS + terminal + plan tasks + optional agent.
    case bootstrapProject(
        path: String,
        openTerminal: Bool,
        createPlan: Bool,
        indexKnowledge: Bool,
        startAgent: Bool,
        agentGoal: String?
    )
    // Git
    case gitStatus(path: String?)
    case gitLog(path: String?, limit: Int)
    case gitDiff(path: String?)
    case gitCommit(message: String, path: String?, push: Bool)
    case gitPush(path: String?)
    case gitPull(path: String?)
    case spawnAgent(goal: String, role: AgentRole)
    case startMission(goal: String, builders: Int)
    case searchKnowledge(query: String)
    /// B4: recall durable project memory (git changelog + notes).
    case recallProject(path: String?, query: String?)
    /// B1: sync git log into project memory (optional note).
    case syncProjectMemory(path: String?, note: String?)
}

struct ToolResult: Equatable {
    var ok: Bool
    var message: String
    var tool: OrchestratorTool?
}

@MainActor
final class OrchestratorToolRunner {
    weak var terminals: TerminalManager?
    weak var directories: DirectoryStore?
    weak var probe: SystemProbe?
    weak var tasks: TaskStore?
    weak var workspaces: WorkspaceStore?
    weak var safety: SafetyGuardrails?
    weak var git: GitService?
    weak var agents: AgentSessionStore?
    weak var knowledge: KnowledgeStore?
    weak var projectMemory: ProjectMemoryStore?
    var onNavigate: ((String) -> Void)?
    /// When true, tools that mutate describe only (Fase 10 dry-run).
    var dryRun: Bool = false
    /// A6: when true, side-effect tools do not change the main route (⌘K modal / board).
    var stayInPlace: Bool = false
    /// Optional activity sink for orchestrator chat log (phase + detail).
    var onActivity: ((OrchestratorPhase, String) -> Void)?

    /// Navigate only if stayInPlace is off, unless `force` (explicit switchView).
    private func navigate(_ route: String, force: Bool = false) {
        if stayInPlace && !force { return }
        onNavigate?(route)
    }

    private func note(_ phase: OrchestratorPhase, _ detail: String) {
        onActivity?(phase, detail)
    }

    func execute(_ tool: OrchestratorTool) -> ToolResult {
        switch tool {
        case .openTerminal(let path, let role):
            let resolved = terminals?.resolvePath(path) ?? path
            note(.runningTool, "openTerminal · \(resolved.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
            if dryRun {
                return ToolResult(ok: true, message: "🧪 DRY-RUN: aprirei terminale in `\(resolved)` ruolo \(role?.rawValue ?? "default")", tool: tool)
            }
            if let ws = workspaces?.open(path: resolved) {
                AppLogger.info("Tool openTerminal via workspace \(ws.path)")
            }
            if let session = terminals?.openTerminal(at: resolved, role: role) {
                navigate("terminals")
                return ToolResult(ok: true, message: "Terminale aperto in `\(session.cwd)` (ruolo \(session.agentRole.rawValue))", tool: tool)
            }
            return ToolResult(ok: false, message: terminals?.lastError ?? "Impossibile aprire terminale", tool: tool)

        case .runCommand(let command, let path, let role):
            let cwd = path.map { terminals?.resolvePath($0) ?? $0 }
            note(.waitingTerminal, "run `\(String(command.prefix(64)))`")
            if dryRun {
                return ToolResult(ok: true, message: "🧪 DRY-RUN: eseguirei `\(command)` in \(cwd ?? "home")", tool: tool)
            }
            if let cwd { _ = workspaces?.open(path: cwd) }
            // qs-safety.json
            if let root = cwd ?? workspaces?.current?.path,
               let policy = workspaces?.safetyPolicy ?? WorkspaceSafetyPolicy.load(from: root),
               let block = policy.blocks(command) {
                return ToolResult(ok: false, message: block, tool: tool)
            }

            // Prefer writing into an already-open PTY when path matches / omitted
            if let selected = terminals?.selected, selected.isAlive {
                let sameCwd: Bool = {
                    guard let cwd else { return true }
                    let a = (selected.cwd as NSString).standardizingPath
                    let b = (cwd as NSString).standardizingPath
                    return a == b || a.hasPrefix(b) || b.hasPrefix(a)
                }()
                if sameCwd || path == nil {
                    let decision = terminals?.sendCommandLine(
                        command,
                        to: selected.id,
                        source: "orchestrator",
                        roleOverride: role
                    ) ?? .allow
                    switch decision {
                    case .block(let msg, _), .requireConfirm(let msg, _), .requireDualConfirm(let msg, _):
                        return ToolResult(ok: false, message: terminals?.lastSafetyMessage ?? msg, tool: tool)
                    case .allowWithWarning(let msg, _):
                        navigate("terminals")
                        return ToolResult(
                            ok: true,
                            message: "⚠️ \(msg)\nComando inviato a **\(selected.title)**: `\(command)`",
                            tool: tool
                        )
                    case .allow:
                        navigate("terminals")
                        return ToolResult(
                            ok: true,
                            message: "Comando inviato al terminale **\(selected.title)** (`\(selected.cwd)`):\n`\(command)`",
                            tool: tool
                        )
                    }
                }
            }

            terminals?.runInNewTerminal(command: command, at: cwd ?? workspaces?.current?.path, role: role)
            if let err = terminals?.lastError, terminals?.lastSafetyMessage != nil || err.contains("bloccato") || err.contains("Conferma") {
                return ToolResult(ok: false, message: terminals?.lastSafetyMessage ?? err, tool: tool)
            }
            navigate("terminals")
            let where_ = cwd ?? workspaces?.current?.path ?? "home"
            return ToolResult(ok: true, message: "Comando avviato in nuovo PTY · `\(command)` · \(where_)", tool: tool)

        case .listProjects:
            let dirs = directories
            let list = (dirs?.projects.prefix(25).map { "• \($0.name) — \($0.path)" } ?? []).joined(separator: "\n")
            let recent = (workspaces?.recent.prefix(10).map { "★ \($0.name) — \($0.path)" } ?? []).joined(separator: "\n")
            return ToolResult(
                ok: true,
                message: "**Progetti**\n\(list.isEmpty ? "_nessuno_" : list)\n\n**Workspace recenti**\n\(recent.isEmpty ? "_nessuno_" : recent)",
                tool: tool
            )

        case .getSystemStatus:
            let snap = probe?.snapshot
            let terms = terminals?.snapshotForOrchestrator() ?? "—"
            let gitLine: String
            if let g = git, g.status.isRepo {
                gitLine = "Git: \(g.status.summaryLine)"
            } else {
                gitLine = "Git: —"
            }
            let msg = """
            Host: \(snap?.hostname ?? "—") · User: \(snap?.username ?? "—")
            CPU \(String(format: "%.0f", snap?.cpuPercent ?? 0))% · RAM \(String(format: "%.1f", snap?.memoryUsedGB ?? 0))GB
            Terminali:
            \(terms)
            Workspace: \(workspaces?.current?.path ?? "nessuno")
            \(gitLine)
            """
            return ToolResult(ok: true, message: msg, tool: tool)

        case .createTask(let title, let subtitle, let priority, let workspacePath, let model):
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else {
                return ToolResult(ok: false, message: "Titolo task vuoto", tool: tool)
            }
            let ws = AgentToolRunner.sanitizedWorkspace(workspacePath ?? workspaces?.current?.path)
            guard let ws else {
                return ToolResult(
                    ok: false,
                    message: "Nessun workspace progetto aperto (non uso $HOME). Apri il progetto prima di creare task.",
                    tool: tool
                )
            }
            let modelName = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "local"
            let created = tasks?.add(
                title: String(t.prefix(160)),
                subtitle: subtitle.map { String($0.prefix(2_000)) },
                priority: priority,
                model: modelName,
                workspacePath: ws,
                source: .orchestrator,
                evidence: ["orchestrator create_task", "ws:\(ws)"]
            )
            navigate("tasks")
            var msg = "Task creata su QS Tasks: **\(created?.title ?? t)**"
            if let sub = subtitle, !sub.isEmpty {
                msg += "\n\nDettaglio:\n\(String(sub.prefix(400)))"
            }
            msg += "\n\nWorkspace: `\(ws)`"
            msg += "\nPriorità: \(priority.rawValue) · modello \(modelName) · id \(created?.id.uuidString.prefix(8) ?? "—")"
            return ToolResult(ok: true, message: msg, tool: tool)

        case .startBoardTask(let titleOrId):
            guard let agents else {
                return ToolResult(ok: false, message: "AgentSessionStore non disponibile", tool: tool)
            }
            note(.waitingAgents, "startBoardTask · \(String(titleOrId.prefix(48)))")
            guard let task = resolveTask(titleOrId) else {
                // Fallback: latest TODO for current workspace
                let path = workspaces?.current?.path
                let fallback = tasks?.tasks
                    .filter { $0.column == .inProgress || $0.column == .todo || $0.column == .review }
                    .filter { path == nil || $0.workspacePath == nil || $0.workspacePath == path }
                    .sorted { a, b in
                        // Prefer IN CORSO orphans, then TODO, then REVIEW
                        func rank(_ c: TaskColumn) -> Int {
                            switch c {
                            case .inProgress: return 0
                            case .todo: return 1
                            case .review: return 2
                            case .done: return 9
                            }
                        }
                        return rank(a.column) < rank(b.column)
                    }
                    .first
                guard let fallback else {
                    return ToolResult(ok: false, message: "Task non trovata: \(titleOrId). Crea prima una task o indica il titolo.", tool: tool)
                }
                if dryRun {
                    return ToolResult(ok: true, message: "🧪 DRY-RUN: avvierei builder su «\(fallback.title)»", tool: tool)
                }
                let gate = tasks?.canStart(fallback.id)
                if let gate, !gate.ok {
                    return ToolResult(ok: false, message: "Non avviabile: \(gate.reason ?? "dipendenze")", tool: tool)
                }
                if let orch = agents.orchestrator {
                    let ok = orch.launchBoardTask(fallback.id)
                    return ToolResult(
                        ok: ok,
                        message: ok
                            ? "Orchestratore ha lanciato **\(fallback.title)** (sub-agent sotto controllo)."
                            : "Avvio fallito per **\(fallback.title)**.",
                        tool: tool
                    )
                }
                agents.startTask(fallback.id, underOrchestratorControl: true)
                navigate("swarm")
                return ToolResult(
                    ok: true,
                    message: "Builder avviato sulla task **\(fallback.title)** (match soft).\nVedi **Terminali** (PTY + log tool) o **QS Swarm**.",
                    tool: tool
                )
            }
            if dryRun {
                return ToolResult(ok: true, message: "🧪 DRY-RUN: avvierei builder su «\(task.title)»", tool: tool)
            }
            if let gate = tasks?.canStart(task.id), !gate.ok {
                return ToolResult(ok: false, message: "Non avviabile: \(gate.reason ?? "dipendenze")", tool: tool)
            }
            if let orch = agents.orchestrator {
                let ok = orch.launchBoardTask(task.id)
                return ToolResult(
                    ok: ok,
                    message: ok
                        ? "Orchestratore ha lanciato **\(task.title)** [\(task.id.uuidString.prefix(8))] — sub-agent sotto controllo."
                        : "Avvio fallito per **\(task.title)**.",
                    tool: tool
                )
            }
            agents.startTask(task.id, underOrchestratorControl: true)
            navigate("swarm")
            return ToolResult(
                ok: true,
                message: "Builder avviato sulla task **\(task.title)** [\(task.id.uuidString.prefix(8))].\nModello: \(task.assigneeModel)\nVedi **Terminali** / **QS Swarm** per log e PTY.",
                tool: tool
            )

        case .completeTask(let titleOrId):
            guard let task = resolveTask(titleOrId) else {
                return ToolResult(ok: false, message: "Task non trovata: \(titleOrId)", tool: tool)
            }
            let next = tasks?.complete(task.id)
            navigate("tasks")
            var msg = "Task **completata**: \(task.title)"
            if let next {
                msg += "\n\n**Auto-advance (C2)** → prossima in corso: **\(next.title)**"
            } else if let planId = task.planId, let tasks {
                let left = tasks.tasks(inPlan: planId).filter { $0.column != .done }.count
                if left == 0 {
                    msg += "\n\nPiano completo — nessuna task rimasta nel DAG."
                }
            }
            return ToolResult(ok: true, message: msg, tool: tool)

        case .deleteTask(let titleOrId):
            guard let task = resolveTask(titleOrId) else {
                return ToolResult(ok: false, message: "Task non trovata: \(titleOrId)", tool: tool)
            }
            let title = task.title
            tasks?.remove(task.id)
            navigate("tasks")
            return ToolResult(ok: true, message: "Task **eliminata**: \(title)", tool: tool)

        case .switchView(let name):
            navigate(name, force: true)
            return ToolResult(ok: true, message: "Vista: \(name)", tool: tool)

        case .openWorkspace(let path):
            if let ws = workspaces?.open(path: path) {
                git?.setPath(ws.path)
                let prev = projectMemory?.markVisit(path: ws.path)
                navigate("workspace")
                var msg = "Workspace aperto: `\(ws.path)`"
                if let prev, !prev.isEmpty {
                    msg += "\n\n_Ultima volta:_ \(prev)"
                }
                return ToolResult(ok: true, message: msg, tool: tool)
            }
            return ToolResult(ok: false, message: workspaces?.lastError ?? "Workspace non trovato", tool: tool)

        case .createPlan(let path):
            guard let tasks else {
                return ToolResult(ok: false, message: "TaskStore non disponibile", tool: tool)
            }
            let root = path.map { terminals?.resolvePath($0) ?? $0 }
                ?? workspaces?.current?.path
            guard let root else {
                return ToolResult(ok: false, message: "Nessun workspace — apri un progetto prima", tool: tool)
            }
            if dryRun {
                let snap = ProjectBrain.refresh(path: root)
                let preview = ProjectBrain.suggestTasks(from: snap)
                let lines = preview.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
                return ToolResult(
                    ok: true,
                    message: "🧪 DRY-RUN smart plan per `\(root)`\n\(snap.summaryLine)\n\(lines)",
                    tool: tool
                )
            }
            _ = workspaces?.open(path: root)
            git?.setPath(root)
            let name = URL(fileURLWithPath: root).lastPathComponent
            let snap = ProjectBrain.refresh(path: root)
            let created = tasks.addPlan(forWorkspace: root, projectName: name)
            // B1: fold git + plan into durable project memory
            _ = projectMemory?.syncChangelog(path: root)
            _ = projectMemory?.appendNote(
                path: root,
                text: "Piano smart: \(created.count) task (stack \(snap.stack.label))",
                kind: .plan,
                evidence: created.prefix(5).map(\.title)
            )
            navigate("tasks")
            let list = created.enumerated().map { idx, t in
                let src = t.source.shortLabel
                let dep = t.dependsOn.isEmpty ? "root" : "dopo #\(idx)"
                let ev = t.evidence.first.map { " — \($0)" } ?? ""
                return "\(idx + 1). \(t.title) _(\(src), \(dep))_\(ev)"
            }.joined(separator: "\n")
            let evidenceN = created.filter { !$0.evidence.isEmpty && $0.source != .template }.count
            let planIdShort = created.first?.planId?.uuidString.prefix(8) ?? "?"
            return ToolResult(
                ok: true,
                message: """
                **Piano smart** per **\(name)** — \(snap.summaryLine)

                \(created.count) task in TODO · DAG sequenziale (plan `\(planIdShort)`) · \(evidenceN) con evidence:

                \(list)

                **C1/C2:** ogni step dipende dal precedente; completa uno → il prossimo va **IN CORSO** auto.
                Solo la #1 è avviabile subito (le altre = BLOCKED finché le dipendenze non sono DONE).

                Memoria progetto + decision log aggiornati. \
                `cosa abbiamo fatto su \(name)` per il recall.

                Apri **QS Tasks** per avviare la prima (Avvia → agent). \
                Oppure: `avvia agent` sulla prima, o `avvia missione \(name)`.
                """,
                tool: tool
            )

        case .bootstrapProject(let path, let openTerminal, let createPlan, let indexKnowledge, let startAgent, let agentGoal):
            let resolved = terminals?.resolvePath(path) ?? path
            if dryRun {
                return ToolResult(
                    ok: true,
                    message: "🧪 DRY-RUN bootstrap `\(resolved)` term=\(openTerminal) plan=\(createPlan) agent=\(startAgent)",
                    tool: tool
                )
            }
            var lines: [String] = []

            // 1) Workspace
            guard let ws = workspaces?.open(path: resolved) else {
                return ToolResult(
                    ok: false,
                    message: workspaces?.lastError ?? "Impossibile aprire workspace `\(resolved)`",
                    tool: tool
                )
            }
            git?.setPath(ws.path)
            lines.append("✓ Workspace **\(ws.name)** → `\(ws.path)`")

            // 2) Terminal
            if openTerminal {
                if let session = terminals?.openTerminal(at: ws.path, title: ws.name) {
                    lines.append("✓ Terminale **\(session.title)**")
                } else {
                    lines.append("✗ Terminale: \(terminals?.lastError ?? "errore")")
                }
            }

            // 3) Knowledge index (async start)
            if indexKnowledge {
                knowledge?.index(workspace: ws.path)
                lines.append("✓ Knowledge: indicizzazione avviata")
            }

            // 4) Smart plan from repo (A1–A3)
            if createPlan, let tasks {
                let snap = ProjectBrain.refresh(path: ws.path)
                let created = tasks.addPlan(forWorkspace: ws.path, projectName: ws.name)
                lines.append("✓ **\(created.count) task** smart plan — \(snap.summaryLine)")
                for (i, t) in created.prefix(7).enumerated() {
                    lines.append("   \(i + 1). \(t.title) _(\(t.source.shortLabel))_")
                }
            }

            // 5) Optional LLM agent (Grok/OpenAI/…)
            if startAgent {
                let goal = (agentGoal?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Esplora il progetto \(ws.name), leggi README e struttura, poi proponi le priorità di lavoro e allinea le task del board."
                if let agents {
                    let session = agents.spawn(
                        name: "builder-\(ws.name.prefix(12))",
                        role: .builder,
                        workspacePath: ws.path,
                        openTerminal: !openTerminal, // reuse if we already opened one
                        goal: goal,
                        runLLM: false
                    )
                    agents.runtime.runGoal(sessionId: session.id, goal: goal, workspace: ws.path, maxSteps: 8)
                    lines.append("✓ Agent **\(session.name)** avviato (LLM se key in Integrazioni)")
                } else {
                    lines.append("✗ Agent store non disponibile")
                }
            }

            navigate(createPlan ? "tasks" : (openTerminal ? "terminals" : "workspace"))
            return ToolResult(
                ok: true,
                message: """
                **Progetto avviato**

                \(lines.joined(separator: "\n"))

                Flusso consigliato: rivedi le task in **QS Tasks** → **Avvia** sulla prima, \
                oppure continua in chat: `git status`, `cosa so di …`, `avvia missione …`.
                """,
                tool: tool
            )

        // MARK: Git tools

        case .gitStatus(let path):
            guard let resolved = Self.resolveProjectGitPath(
                path: path,
                terminals: terminals,
                workspaces: workspaces,
                git: git
            ) else {
                return ToolResult(
                    ok: false,
                    message: "Nessun workspace git. Apri zackgame (o il progetto) — non uso $HOME.",
                    tool: tool
                )
            }
            let (snap, _) = GitRunner.loadSnapshot(path: resolved)
            git?.setPath(resolved)
            if !snap.isRepo {
                return ToolResult(ok: false, message: "Nessun repo git in \(resolved)", tool: tool)
            }
            let changes = snap.changes.prefix(30).map {
                "\($0.staged ? "S" : " ") \($0.status) \($0.path)"
            }.joined(separator: "\n")
            let body = """
            **Git status** · `\(snap.root ?? "")`
            Branch: **\(snap.branch ?? "?")** · \(snap.summaryLine)

            ```
            \(changes.isEmpty ? (snap.isEmptyRepo ? "(repo vuoto, 0 commit)" : "(clean)") : changes)
            ```

            Token GitHub: \(git?.hasGitHubToken == true ? "✓ configurato" : "✗ manca (Integrazioni → GitHub)")
            """
            navigate("workspace")
            return ToolResult(ok: true, message: body, tool: tool)

        case .gitLog(let path, let limit):
            guard let resolved = Self.resolveProjectGitPath(
                path: path,
                terminals: terminals,
                workspaces: workspaces,
                git: git
            ) else {
                return ToolResult(
                    ok: false,
                    message: "Nessun workspace git. Apri il progetto — non uso $HOME.",
                    tool: tool
                )
            }
            let (snap, log) = GitRunner.loadSnapshot(path: resolved)
            git?.setPath(resolved)
            git?.log = log
            // B1: persist changelog into project memory
            _ = projectMemory?.syncChangelog(path: resolved, limit: max(limit, 25))
            if snap.isEmptyRepo {
                return ToolResult(ok: true, message: "_Nessun commit (repo vuoto)_", tool: tool)
            }
            let lines = log.prefix(limit).map {
                "• `\($0.shortHash)` **\($0.subject)** — \($0.author) · \($0.relativeDate)"
            }
            let name = URL(fileURLWithPath: resolved).lastPathComponent
            let footer = "\n\n_Memoria aggiornata_ · `cosa abbiamo fatto su \(name)`"
            return ToolResult(
                ok: true,
                message: (lines.isEmpty ? "_Nessun commit_" : "**Changelog**\n" + lines.joined(separator: "\n")) + footer,
                tool: tool
            )

        case .gitDiff(let path):
            ensureGitPath(path)
            guard let g = git else {
                return ToolResult(ok: false, message: "GitService non disponibile", tool: tool)
            }
            return ToolResult(ok: true, message: g.diffSummary(), tool: tool)

        case .gitCommit(let message, let path, let push):
            ensureGitPath(path)
            guard let g = git else {
                return ToolResult(ok: false, message: "GitService non disponibile", tool: tool)
            }
            let ok = push ? g.commitAndPushSync(message: message) : g.commitSync(message: message)
            if ok {
                if let p = g.workingPath ?? path.map({ terminals?.resolvePath($0) ?? $0 }) ?? workspaces?.current?.path {
                    _ = projectMemory?.syncChangelog(path: p, limit: 10)
                    _ = projectMemory?.appendNote(
                        path: p,
                        text: push ? "Commit+push: \(message)" : "Commit: \(message)",
                        kind: .note,
                        evidence: ["git commit"]
                    )
                }
                navigate("workspace")
                return ToolResult(
                    ok: true,
                    message: push
                        ? "✓ Commit + push: **\(message)**\n\(g.lastMessage ?? "")"
                        : "✓ Commit: **\(message)**",
                    tool: tool
                )
            }
            return ToolResult(ok: false, message: g.lastError ?? "Commit/push fallito", tool: tool)

        case .gitPush(let path):
            ensureGitPath(path)
            guard let g = git else {
                return ToolResult(ok: false, message: "GitService non disponibile", tool: tool)
            }
            if g.pushSync() {
                return ToolResult(ok: true, message: g.lastMessage ?? "Push OK", tool: tool)
            }
            return ToolResult(ok: false, message: g.lastError ?? "Push fallito", tool: tool)

        case .gitPull(let path):
            ensureGitPath(path)
            guard let g = git else {
                return ToolResult(ok: false, message: "GitService non disponibile", tool: tool)
            }
            if g.pullSync() {
                return ToolResult(ok: true, message: g.lastMessage ?? "Pull OK", tool: tool)
            }
            return ToolResult(ok: false, message: g.lastError ?? "Pull fallito", tool: tool)

        case .spawnAgent(let goal, let role):
            guard let agents else {
                return ToolResult(ok: false, message: "AgentSessionStore non disponibile", tool: tool)
            }
            note(.waitingAgents, "spawn \(role.rawValue): \(String(goal.prefix(48)))")
            let path = workspaces?.current?.path
            let session = agents.spawn(
                name: "\(role.rawValue)-\(agents.sessions.count + 1)",
                role: role,
                workspacePath: path,
                openTerminal: true,
                goal: goal,
                runLLM: false
            )
            agents.runtime.runGoal(sessionId: session.id, goal: goal, workspace: path, maxSteps: 8)
            navigate("terminals")
            return ToolResult(
                ok: true,
                message: "Agent **\(session.name)** avviato (\(role.displayName)).\nGoal: \(goal)\nVedi strip Agent nei Terminali.",
                tool: tool
            )

        case .startMission(let goal, let builders):
            guard let agents else {
                return ToolResult(ok: false, message: "AgentSessionStore non disponibile", tool: tool)
            }
            if dryRun {
                return ToolResult(ok: true, message: "🧪 DRY-RUN: avvierei missione «\(goal)» con coord+scout+\(builders) builder+reviewer", tool: tool)
            }
            if agents.goalModePreferred {
                note(.goal, "startGoalMode · \(String(goal.prefix(56)))")
                agents.startGoalMode(goal: goal, builders: builders)
                navigate("swarm")
                return ToolResult(
                    ok: true,
                    message: "🎯 **GOAL MODE**: \(goal)\n· auto-run + auto-split + budget elevato\nVedi **QS Swarm**.",
                    tool: tool
                )
            }
            note(.waitingAgents, "startMission · \(String(goal.prefix(56)))")
            agents.startMission(goal: goal, builders: builders)
            navigate("swarm")
            return ToolResult(
                ok: true,
                message: "Missione avviata: **\(goal)**\n· coordinator + scout + \(builders) builder + reviewer\nVedi **QS Swarm** e strip Agent.",
                tool: tool
            )

        case .searchKnowledge(let query):
            guard let knowledge else {
                return ToolResult(ok: false, message: "KnowledgeStore non disponibile", tool: tool)
            }
            if knowledge.chunks.isEmpty, let path = workspaces?.current?.path {
                knowledge.index(workspace: path)
            }
            let answer = knowledge.answerPrompt(for: query)
            navigate("knowledge")
            return ToolResult(ok: true, message: answer, tool: tool)

        case .recallProject(let path, let query):
            guard let projectMemory else {
                return ToolResult(ok: false, message: "ProjectMemoryStore non disponibile", tool: tool)
            }
            let resolved = path.map { terminals?.resolvePath($0) ?? $0 }
                ?? workspaces?.current?.path
            var body = projectMemory.recall(path: resolved, query: query)
            // B2: append decision log slice
            let decisions = DecisionLogStore.shared.formatRecall(workspace: resolved, limit: 10)
            body += "\n\n### Decision log (B2)\n\(decisions)"
            return ToolResult(ok: true, message: body, tool: tool)

        case .syncProjectMemory(let path, let note):
            guard let projectMemory else {
                return ToolResult(ok: false, message: "ProjectMemoryStore non disponibile", tool: tool)
            }
            let resolved = path.map { terminals?.resolvePath($0) ?? $0 }
                ?? workspaces?.current?.path
            guard let resolved else {
                return ToolResult(ok: false, message: "Nessun workspace per sincronizzare la memoria", tool: tool)
            }
            let rec = projectMemory.syncChangelog(path: resolved)
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = projectMemory.appendNote(path: resolved, text: note, kind: .note)
            }
            return ToolResult(
                ok: true,
                message: "Memoria **\(rec.projectName)** aggiornata · \(rec.events.count) eventi\n\(rec.lastVisitSummary ?? "")",
                tool: tool
            )
        }
    }

    private func ensureGitPath(_ path: String?) {
        if let resolved = Self.resolveProjectGitPath(
            path: path,
            terminals: terminals,
            workspaces: workspaces,
            git: git
        ) {
            git?.setPath(resolved)
        }
    }

    /// Prefer open project workspace. Never bind git to bare $HOME (GUI cwd / «nella home»).
    static func resolveProjectGitPath(
        path: String?,
        terminals: TerminalManager?,
        workspaces: WorkspaceStore?,
        git: GitService?
    ) -> String? {
        let home = (NSHomeDirectory() as NSString).standardizingPath
        func isHome(_ std: String) -> Bool {
            std == home || std == home + "/"
        }
        func usable(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if p == "." || p == "./" || p == "~" {
                // Relative / tilde alone → open workspace, not process cwd ($HOME)
                return usable(workspaces?.current?.path)
            }
            // Expand tilde / standardize WITHOUT TerminalManager.resolvePath fallback-to-HOME.
            if p.hasPrefix("~") {
                p = (p as NSString).expandingTildeInPath
            }
            p = (p as NSString).standardizingPath
            if isHome(p) { return nil }
            // Prefer real directories; if missing, still reject HOME but keep project-like paths
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
            // Allow unresolved project paths only if not HOME (caller may open later)
            return isHome(p) ? nil : p
        }

        // 1) Open workspace always wins (zackgame in switcher)
        if let p = usable(workspaces?.current?.path) { return p }
        // 2) Explicit path from chat (if not HOME)
        if let p = usable(path) { return p }
        // 3) Live coding / agent terminal under a project
        if let cwd = terminals?.selected?.cwd, let p = usable(cwd) { return p }
        if let p = usable(git?.workingPath) { return p }
        // 4) Any alive terminal whose cwd is a git repo (not HOME)
        if let terminals {
            for term in terminals.sessions where term.isAlive {
                if let p = usable(term.cwd),
                   FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) {
                    return p
                }
            }
        }
        return nil
    }

    private func resolveTask(_ titleOrId: String) -> AgentTask? {
        let q = titleOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let tasks else { return nil }
        if let id = UUID(uuidString: q) {
            return tasks.task(id: id)
        }
        // exact then contains
        if let exact = tasks.tasks.first(where: { $0.title.caseInsensitiveCompare(q) == .orderedSame }) {
            return exact
        }
        return tasks.tasks.first { $0.title.localizedCaseInsensitiveContains(q) }
    }
}
