import Foundation

/// Tools available inside an AgentRuntime loop (sandboxed to workspace when possible).
enum AgentToolName: String, CaseIterable {
    case list_dir
    case read_file
    case run_command
    case git_status
    case git_log
    case write_file
    /// C5: propose full-file replacement → show unified diff, do not write until apply_patch
    case propose_patch
    case apply_patch
    case discard_patch
    case create_task
    case ask_user
    case complete_task
    case search_knowledge
    /// Structured repo capsule: hybrid FTS + import graph, pivot full + neighbor skeletons.
    case repo_capsule
    /// Force/rebuild ProjectCodeBrain index for current workspace.
    case index_repo
    case finish

    /// Exact match, aliases, or near-typo (e.g. repo_capsool → repo_capsule).
    static func resolve(_ raw: String) -> AgentToolName? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if let exact = AgentToolName(rawValue: s) { return exact }
        // Common aliases / typos
        let aliases: [String: AgentToolName] = [
            "capsule": .repo_capsule,
            "repo_capsool": .repo_capsule,
            "repo_capsul": .repo_capsule,
            "repocapsule": .repo_capsule,
            "code_capsule": .repo_capsule,
            "context_capsule": .repo_capsule,
            "search": .search_knowledge,
            "knowledge": .search_knowledge,
            "grep": .search_knowledge,
            "ls": .list_dir,
            "listdir": .list_dir,
            "dir": .list_dir,
            "cat": .read_file,
            "read": .read_file,
            "open": .read_file,
            "write": .write_file,
            "patch": .propose_patch,
            "propose": .propose_patch,
            "apply": .apply_patch,
            "done": .finish,
            "complete": .complete_task,
            "create": .create_task,
            "createtask": .create_task,
            "add_task": .create_task,
            "crea_task": .create_task,
            "nuova_task": .create_task,
            "index": .index_repo,
            "reindex": .index_repo,
            "bash": .run_command,
            "shell": .run_command,
            "cmd": .run_command,
            "git": .git_status,
        ]
        if let a = aliases[s] { return a }
        // Edit-distance ≤ 2 against known names (handles repo_capsool, readfile, etc.)
        var best: AgentToolName?
        var bestDist = 3
        for cand in AgentToolName.allCases {
            let d = Self.levenshtein(s, cand.rawValue)
            if d < bestDist {
                bestDist = d
                best = cand
            }
        }
        return bestDist <= 2 ? best : nil
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[b.count]
    }
}

struct AgentToolCall: Equatable {
    var name: AgentToolName
    var args: [String: String]
    var raw: String
}

struct AgentToolResult: Equatable {
    var ok: Bool
    var output: String
}

/// C5 pending file change waiting for apply_patch.
struct PendingPatch: Equatable {
    var path: String
    var fullPath: String
    var original: String
    var proposed: String
    var diff: String
    var at: Date
}

@MainActor
final class AgentToolRunner {
    weak var terminals: TerminalManager?
    weak var workspaces: WorkspaceStore?
    weak var tasks: TaskStore?
    weak var git: GitService?
    weak var safety: SafetyGuardrails?
    /// Optional sink for swarm mission (create_task / ask_user).
    weak var missionStore: AgentSessionStore?
    weak var knowledge: KnowledgeStore?

    var workspaceRoot: String?
    var agentRole: AgentRole = .builder
    var taskId: UUID?
    /// When set, tool I/O is echoed into this real TerminalSession pane.
    var linkedTerminalID: UUID?

    /// C5: path → pending patch (diff-first workflow).
    private(set) var pendingPatches: [String: PendingPatch] = [:]
    /// Relative paths successfully written this agent loop (apply_patch / write_file).
    private(set) var appliedPathsThisSession: [String] = []

    private var maxReadBytes: Int { TokenBudget.toolReadChars }
    private var maxPatchBytes: Int { TokenBudget.toolPatchChars }
    private var maxList: Int { TokenBudget.toolListEntries }

    /// Clear write/apply tracking at the start of each LLM loop.
    func resetSessionWriteState() {
        appliedPathsThisSession = []
        pendingPatches.removeAll()
    }

    /// Tools that never mutate disk / board — safe to run in parallel (C4).
    static let readOnlyTools: Set<AgentToolName> = [
        .list_dir, .read_file, .git_status, .git_log, .search_knowledge, .repo_capsule,
    ]

    static func isReadOnly(_ name: AgentToolName) -> Bool {
        readOnlyTools.contains(name)
    }

    /// Compact tool catalog — role-scoped to cut system prompt tokens.
    func describeToolsForPrompt() -> String {
        let ro = """
        Read-only: repo_capsule|read_file|list_dir|git_status|git_log|search_knowledge
        PRIMARY: {"tool":"repo_capsule","query":"homepage motion prefers-reduced-motion"}
        {"tool":"read_file","path":"premium-ui.css","around":"233","max_lines":"80"}
        {"tool":"read_file","path":"src/foundation/…","start_line":"1","max_lines":"90"}
        {"tool":"search_knowledge","query":"…"}  (locate paths/symbols — NO full capsule)
        {"tool":"list_dir","path":"."} {"tool":"list_dir","path":"src"} {"tool":"git_status"}
        {"tool":"index_repo","force":"false"}  (if capsule says index missing)
        SORGENTE REALE = root + src/ (come Cursor/Claude). www/ è spesso BUILD Capacitor (gitignore) — non editarlo.
        VIETATO: cat dump; path ios/ android/ public/; scrivere in www/ se esiste il file in root.
        Batch RO: {"tools":[{…},{…}]}
        """
        let write = """
        Edit (diff-first): propose_patch → apply_patch | discard_patch
        Preferisci replace: {"tool":"propose_patch","path":"premium-ui.css","old_string":".p-big-play{…}","new_string":".p-big-play{…}"}
        Oppure append: {"tool":"propose_patch","path":"premium-ui.css","mode":"append","content":"/* block */\\n.p-big-play{…}"}
        VIETATO content:"APPEND" da solo (tronca il file). Full rewrite solo file piccoli.
        {"tool":"apply_patch","path":"premium-ui.css"}
        {"tool":"run_command","command":"safe cmd"}  (no cat di CSS/JS grandi)
        """
        let board = """
        Board: create_task|ask_user|complete_task|finish
        {"tool":"create_task","title":"…","subtitle":"…","priority":"alto|medio|critico"}
        {"tool":"ask_user","question":"…"}
        {"tool":"finish","message":"short summary"}
        """
        switch agentRole {
        case .scout, .reviewer:
            return """
            Tools (ruolo \(agentRole.rawValue) — preferisci repo_capsule, poi finish):
            \(ro)
            {"tool":"finish","message":"…"}
            Regole: 1° = repo_capsule. Poi read_file con around=LINE. finish con path da editare.
            """
        case .coordinator:
            return """
            Tools (coordinator — piano + task, no edit file):
            \(ro)
            \(board)
            Regole: 1 repo_capsule; spezza lavoro in 3–8 create_task STRETTE; finish. No propose_patch.
            """
        case .builder, .general, .deployer:
            return """
            Tools (builder):
            \(ro)
            \(write)
            {"tool":"complete_task"} {"tool":"finish","message":"…"}
            Flusso (come Cursor): 1× repo_capsule → (UI: markup/JS id/class + CSS già linkato) → propose_patch → apply_patch → git_status → complete_task.
            No dump file intero. complete_task richiede apply riuscito.
            """
        }
    }

    /// Parse one or many tool calls (C4).
    func parseToolCalls(from text: String) -> [AgentToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonStr = extractJSONObject(trimmed) else { return [] }
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        // Batch: {"tools":[...]}
        if let dict = obj as? [String: Any], let arr = dict["tools"] as? [[String: Any]] {
            return arr.compactMap { parseOneObject($0, rawFallback: jsonStr) }
        }
        // Single object
        if let dict = obj as? [String: Any] {
            if let one = parseOneObject(dict, rawFallback: jsonStr) {
                return [one]
            }
        }
        return []
    }

    /// Back-compat single call.
    func parseToolCall(from text: String) -> AgentToolCall? {
        parseToolCalls(from: text).first
    }

    private func parseOneObject(_ obj: [String: Any], rawFallback: String) -> AgentToolCall? {
        // Accept "tool" or occasional "name" key from sloppy models
        let nameStr = (obj["tool"] as? String) ?? (obj["name"] as? String) ?? ""
        guard let name = AgentToolName.resolve(nameStr) else {
            return nil
        }
        var args: [String: String] = [:]
        for (k, v) in obj where k != "tool" && k != "name" {
            if let s = v as? String {
                args[k] = s
            } else if let n = v as? NSNumber {
                args[k] = n.stringValue
            } else if let b = v as? Bool {
                args[k] = b ? "true" : "false"
            }
        }
        // Normalize raw so logs show the corrected tool name
        var normalized = obj
        normalized["tool"] = name.rawValue
        normalized.removeValue(forKey: "name")
        let raw: String
        if let d = try? JSONSerialization.data(withJSONObject: normalized),
           let s = String(data: d, encoding: .utf8) {
            raw = s
        } else {
            raw = rawFallback
        }
        return AgentToolCall(name: name, args: args, raw: raw)
    }

    /// True if model clearly tried to call a tool (JSON with tool/name) but parse failed.
    static func looksLikeFailedToolAttempt(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("\"tool\"") || t.contains("\"tools\"") { return true }
        if t.contains("repo_cap") || t.contains("propose_patch") || t.contains("read_file") { return true }
        return false
    }

    /// Echo tool activity into the linked PTY so Terminali panes show real work (not only the dock log).
    func mirrorToLinkedPTY(tool: String, output: String, ok: Bool) {
        guard let id = linkedTerminalID,
              let term = terminals?.sessions.first(where: { $0.id == id }) else { return }
        let mark = ok ? "✓" : "✗"
        let head = "\(mark) \(tool)"
        let body = output.count > 2_500
            ? String(output.prefix(2_500)) + "\n… [\(output.count) chars]"
            : output
        term.appendAgentEcho("→ \(head)\n\(body)")
    }

    func execute(_ call: AgentToolCall) -> AgentToolResult {
        switch call.name {
        case .list_dir:
            return listDir(call.args["path"] ?? ".")
        case .read_file:
            return readFile(
                call.args["path"] ?? "",
                startLine: Int(call.args["start_line"] ?? call.args["start"] ?? ""),
                maxLines: Int(call.args["max_lines"] ?? call.args["lines"] ?? ""),
                around: Int(call.args["around"] ?? call.args["line"] ?? "")
            )
        case .run_command:
            return runCommand(call.args["command"] ?? "")
        case .git_status:
            return gitStatus()
        case .git_log:
            let lim = Int(call.args["limit"] ?? "15") ?? 15
            return gitLog(limit: lim)
        case .write_file:
            // C5 soft nudge: if file exists and no force flag, prefer propose_path
            let force = (call.args["force"] ?? "").lowercased() == "true"
                || (call.args["apply"] ?? "").lowercased() == "true"
            if !force, let path = call.args["path"], let content = call.args["content"],
               let full = resolvePath(path),
               FileManager.default.fileExists(atPath: full) {
                let proposed = proposePatch(path: path, content: content)
                if proposed.ok {
                    return AgentToolResult(
                        ok: true,
                        output: proposed.output + "\n\n(write_file su file esistente → convertito in propose_patch. Usa apply_patch o write_file con force=true.)"
                    )
                }
            }
            return writeFile(path: call.args["path"] ?? "", content: call.args["content"] ?? "")
        case .propose_patch:
            return proposePatch(
                path: call.args["path"] ?? "",
                content: call.args["content"] ?? "",
                mode: call.args["mode"] ?? call.args["op"] ?? "",
                oldString: call.args["old_string"] ?? call.args["old"] ?? "",
                newString: call.args["new_string"] ?? call.args["new"] ?? ""
            )
        case .apply_patch:
            return applyPatch(path: call.args["path"] ?? "")
        case .discard_patch:
            return discardPatch(path: call.args["path"] ?? "")
        case .create_task:
            return createTask(
                title: call.args["title"] ?? "",
                subtitle: call.args["subtitle"],
                priorityRaw: call.args["priority"]
            )
        case .ask_user:
            return askUser(question: call.args["question"] ?? call.args["message"] ?? "")
        case .complete_task:
            return completeTask()
        case .search_knowledge:
            return searchKnowledge(call.args["query"] ?? call.args["q"] ?? "")
        case .repo_capsule:
            return repoCapsule(
                query: call.args["query"] ?? call.args["q"] ?? "",
                budget: Int(call.args["budget"] ?? call.args["tokens"] ?? "") ?? TokenBudget.repoCapsuleTokens
            )
        case .index_repo:
            return indexRepo(force: (call.args["force"] ?? "").lowercased() == "true")
        case .finish:
            return AgentToolResult(ok: true, output: call.args["message"] ?? "Done")
        }
    }

    /// C4: run multiple read-only tools concurrently (file I/O off main where possible).
    func executeParallel(_ calls: [AgentToolCall]) async -> [(AgentToolCall, AgentToolResult)] {
        guard !calls.isEmpty else { return [] }
        // If any mutating, fall back to serial
        if calls.contains(where: { !Self.isReadOnly($0.name) }) {
            return calls.map { ($0, execute($0)) }
        }
        return await withTaskGroup(of: (Int, AgentToolCall, AgentToolResult).self) { group in
            for (idx, call) in calls.enumerated() {
                group.addTask { @MainActor in
                    // Brief yield so UI can breathe between starts
                    let r = self.execute(call)
                    return (idx, call, r)
                }
            }
            var out: [(Int, AgentToolCall, AgentToolResult)] = []
            for await item in group {
                out.append(item)
            }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    private func completeTask() -> AgentToolResult {
        guard let tid = taskId else {
            return AgentToolResult(ok: false, output: "Nessuna task legata a questo agent")
        }
        // Mirror startTask hard lock (BUG-008): sanitized mismatch / bare $HOME / task WS unset.
        let currentWS = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        guard let currentWS else {
            return AgentToolResult(
                ok: false,
                output: "complete_task rifiutato: nessun workspace progetto valido (non uso $HOME). Apri il progetto e riprova."
            )
        }
        guard let t = tasks?.task(id: tid) else {
            return AgentToolResult(ok: false, output: "Task non trovata")
        }
        let taskWS = Self.sanitizedWorkspace(t.workspacePath)
        if t.workspacePath == nil || taskWS == nil {
            return AgentToolResult(
                ok: false,
                output: "complete_task rifiutato: task senza workspace progetto. Imposta il path (Avvia dopo aver aperto il progetto) e riprova."
            )
        }
        if let taskWS, taskWS != currentWS {
            return AgentToolResult(
                ok: false,
                output: "Workspace mismatch: task=\(taskWS) agent=\(currentWS). Riapri la task sul progetto giusto."
            )
        }

        let title = t.title.lowercased()
        let subtitle = (t.subtitle ?? "").lowercased()
        let blob = title + " " + subtitle
        let isLocateOnly = blob.contains("locate")
            && !blob.contains("patch")
            && !blob.contains("cambia")
            && !blob.contains("fix")
            && !blob.contains("implement")
        let isVerifyOnly = blob.contains("verify") || blob.contains("verifica")
        let isBuilderRole = agentRole == .builder || agentRole == .general || agentRole == .deployer

        if isBuilderRole, !isLocateOnly, appliedPathsThisSession.isEmpty {
            // Verify-only may complete after checking git — but still needs prior apply on parent chain,
            // or a tracked dirty tree. Soft check: reject blind complete without apply.
            if isVerifyOnly {
                git?.refresh()
                let dirty = (git?.status.changes.isEmpty == false)
                if !dirty {
                    return AgentToolResult(
                        ok: false,
                        output: """
                        complete_task rifiutato (Verify): nessuna diff tracked e nessun apply in questa sessione.
                        Se la Patch ha scritto su file sbagliato/non linkato, ripatcha root/src; poi git_status; poi complete_task.
                        Oppure finish con path provati.
                        """
                    )
                }
            } else {
                return AgentToolResult(
                    ok: false,
                    output: """
                    complete_task rifiutato: nessun apply_patch in questa sessione.
                    Prima propose_patch → apply_patch sul path TRACKED corretto (UI: markup + CSS già caricato), poi git_status, poi complete_task.
                    Se impossibile: finish con motivo + path provati.
                    """
                )
            }
        }

        // Soft gate for UI/patch tasks: applied path must appear in tracked git status
        let needsTrackedDiff = isBuilderRole
            && !isLocateOnly
            && !isVerifyOnly
            && (blob.contains("patch") || blob.contains("cambia") || blob.contains("button")
                || blob.contains("pulsante") || blob.contains("ui ") || blob.contains(" play")
                || blob.contains("verde") || blob.contains("css") || blob.contains("home"))
        if needsTrackedDiff, !appliedPathsThisSession.isEmpty {
            git?.refresh()
            let changePaths = git?.status.changes.map(\.path) ?? []
            let appliedVisible = appliedPathsThisSession.contains { applied in
                changePaths.contains { ch in
                    ch == applied || ch.hasSuffix("/" + applied) || applied.hasSuffix("/" + ch)
                        || ch.hasSuffix(applied) || applied.hasSuffix(ch)
                }
            }
            if !appliedVisible {
                return AgentToolResult(
                    ok: false,
                    output: """
                    complete_task rifiutato: apply su \(appliedPathsThisSession.joined(separator: ", ")) ma git status non lista quel path tracked.
                    Probabile file gitignored / path sbagliato / contenuto invariato. Patcha un file tracked in root/src che cambia l’UI (markup + CSS caricato).
                    """
                )
            }
        }

        let next = tasks?.complete(tid)
        var out = "Task \(tid.uuidString.prefix(8)) → COMPLETATE"
        if !appliedPathsThisSession.isEmpty {
            out += " · files: \(appliedPathsThisSession.joined(separator: ", "))"
        }
        if let next {
            out += " · auto-advance → \(next.title) [\(next.id.uuidString.prefix(8))]"
        }
        return AgentToolResult(ok: true, output: out)
    }

    private func createTask(title: String, subtitle: String?, priorityRaw: String?) -> AgentToolResult {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            return AgentToolResult(ok: false, output: "create_task richiede title")
        }
        guard let tasks else {
            return AgentToolResult(ok: false, output: "TaskStore non disponibile")
        }
        let prio: TaskPriority
        switch (priorityRaw ?? "medio").lowercased() {
        case "critico", "critical", "p0": prio = .critico
        case "alto", "high", "p1": prio = .alto
        default: prio = .medio
        }
        let path = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        guard let path else {
            return AgentToolResult(ok: false, output: "Nessun workspace progetto (non uso $HOME). Apri zackgame / progetto prima.")
        }
        let planId = missionStore?.missionPlanId()
        let dependsOn: [UUID] = {
            if let last = missionStore?.lastMissionTaskId() { return [last] }
            return []
        }()
        var evidence = ["swarm create_task", "role: \(agentRole.rawValue)", "ws:\(path)"]
        if let planId {
            evidence.append("plan:\(planId.uuidString.prefix(8))")
        }
        if !dependsOn.isEmpty {
            evidence.append("depends:\(dependsOn[0].uuidString.prefix(8))")
        }
        let builderModel = ProviderPreferences.shared.model(for: .builder)
        let modelLabel = builderModel == "local"
            ? (ProviderPreferences.shared.anyKeyedProvider()?.defaultModel ?? "openrouter")
            : builderModel
        let created = tasks.add(
            title: t,
            subtitle: subtitle,
            priority: prio,
            model: modelLabel,
            workspacePath: path,
            source: .orchestrator,
            evidence: evidence,
            planId: planId,
            dependsOn: dependsOn
        )
        missionStore?.recordMissionTask(created)
        return AgentToolResult(
            ok: true,
            output: "Task creata su QS Tasks: \(created.title) [\(created.id.uuidString.prefix(8))] priority=\(prio.rawValue) plan=\(planId?.uuidString.prefix(8) ?? "—")"
        )
    }

    private func askUser(question: String) -> AgentToolResult {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return AgentToolResult(ok: false, output: "ask_user richiede question")
        }
        // GOAL MODE: never block on the human — pick a safe default and continue.
        if missionStore?.mission?.goalMode == true {
            return AgentToolResult(
                ok: true,
                output: """
                GOAL MODE: ask_user ignorata. Procedi con il default più sicuro.
                Domanda (non bloccante): \(q)
                Ora: create_task strette + finish — niente altre ask_user.
                """
            )
        }
        missionStore?.addMissionQuestion(q)
        return AgentToolResult(
            ok: true,
            output: "Domanda inviata all'utente UI. Attendi risposta prima di assumere. Domanda: \(q)"
        )
    }

    private func searchKnowledge(_ query: String) -> AgentToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return AgentToolResult(ok: false, output: "search_knowledge richiede query")
        }
        let low = q.lowercased()
        let wantsDocs = low.contains("roadmap") || low.contains("nota") || low.contains("doc ")
            || low.contains("docs/") || low.contains("readme") || low.contains("changelog")

        // Code-ish → cheap LOCATE (paths/symbols only). Never re-emit a full capsule here —
        // that was burning ~8k chars twice per task (see M4 motion incident).
        if !wantsDocs {
            let brain = ProjectCodeBrain.shared
            if let path = workspaceRoot ?? workspaces?.current?.path {
                brain.ensureIndexed(workspace: path)
            }
            if brain.isReadyForAgents {
                let loc = brain.locate(query: q, limit: TokenBudget.knowledgeHitLimit)
                if !loc.contains("indice assente"), !loc.contains("nessun hit") {
                    var parts = [loc]
                    if let knowledge, !knowledge.chunks.isEmpty {
                        let docs = knowledge.searchReport(q, limit: 2)
                        if !docs.hasPrefix("Nessun hit") {
                            parts.append("## Docs FTS (top)\n\(docs)")
                        }
                    }
                    let out = parts.joined(separator: "\n\n")
                    // Locate ≈ path:line hits; without knowledge we'd often dump ~2–3 full files.
                    let used = max(1, out.count / 4)
                    let baseline = TokenBudget.toolReadChars / 4 * 2
                    ProviderPreferences.shared.recordKnowledgeSavings(savedTokens: max(0, baseline - used))
                    return AgentToolResult(ok: true, output: out)
                }
            }
        }

        guard let knowledge else {
            return AgentToolResult(ok: false, output: "KnowledgeStore non collegato")
        }
        if knowledge.chunks.isEmpty, let path = workspaceRoot ?? workspaces?.current?.path {
            knowledge.index(workspace: path)
            return AgentToolResult(
                ok: true,
                output: "Indexing avviato su \(path). Richiama search_knowledge tra poco."
            )
        }
        let report = knowledge.searchReport(q, limit: TokenBudget.knowledgeHitLimit)
        return AgentToolResult(ok: true, output: report)
    }

    private func repoCapsule(query: String, budget: Int) -> AgentToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return AgentToolResult(ok: false, output: "repo_capsule richiede query (es. «homepage motion menu»)")
        }
        let brain = ProjectCodeBrain.shared
        if let path = workspaceRoot ?? workspaces?.current?.path {
            brain.ensureIndexed(workspace: path)
        }
        if brain.isIndexing && !brain.isReadyForAgents {
            return AgentToolResult(
                ok: true,
                output: "Code-brain in indexing… (\(brain.lastStats.isEmpty ? "avvio" : brain.lastStats)). Richiama repo_capsule tra pochi secondi."
            )
        }
        if !brain.isReadyForAgents {
            return AgentToolResult(
                ok: false,
                output: "Code-brain vuoto o non aperto. Usa {\"tool\":\"index_repo\",\"force\":\"false\"} poi ritenta repo_capsule. Stats: \(brain.lastStats.isEmpty ? "—" : brain.lastStats)"
            )
        }
        let text = brain.capsule(query: q, budgetTokens: max(600, min(budget, TokenBudget.repoCapsuleTokens)))
        // Capsule replaces list_dir root + several full reads (~8–12k tok baseline).
        let used = max(1, text.count / 4)
        let baseline = 10_000
        ProviderPreferences.shared.recordKnowledgeSavings(savedTokens: max(0, baseline - used))
        return AgentToolResult(ok: true, output: text)
    }

    private func indexRepo(force: Bool) -> AgentToolResult {
        guard let path = workspaceRoot ?? workspaces?.current?.path else {
            return AgentToolResult(ok: false, output: "Nessun workspace. Apri un progetto prima.")
        }
        let brain = ProjectCodeBrain.shared
        brain.index(workspace: path, force: force)
        // Also refresh docs FTS brain
        knowledge?.index(workspace: path)
        return AgentToolResult(
            ok: true,
            output: "index_repo avviato su \(path) force=\(force). Attendi lastStats poi usa repo_capsule."
        )
    }

    // MARK: - C5 Diff-first

    private func proposePatch(
        path: String,
        content: String,
        mode: String = "",
        oldString: String = "",
        newString: String = ""
    ) -> AgentToolResult {
        let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        let mapped = Self.canonicalSourceRelative(path, workspaceRoot: root)
        let editPath = mapped.path
        guard let full = resolvePath(editPath) else {
            return AgentToolResult(ok: false, output: "Path non consentito: \(path)")
        }
        let editLow = editPath.lowercased()
        // Knowledge often ranks this orphan CSS for "PLAY" — it is usually NOT linked from index.html.
        if editLow.contains("mobile-buttons") || editLow.contains("home-mobile-buttons") {
            return AgentToolResult(
                ok: false,
                output: """
                Rifiutato `\(editPath)`: foglio tipicamente NON caricato (effetto UI zero).
                Per PLAY/home usa: premium-ui.js (#pContinueButton / .p-big-play) + premium-ui.css.
                Poi propose_patch su premium-ui.css.
                """
            )
        }
        let low = path.lowercased()
        if low.hasPrefix("ios/") || low.hasPrefix("android/") {
            return AgentToolResult(
                ok: false,
                output: "Path mirror nativo. Edita la sorgente tracked: `\(editPath)` (root/src — non ios/android/www build)."
            )
        }
        if low.hasPrefix("www/"), Self.isWwwBuildOutput(workspaceRoot: root), mapped.redirectedFrom != nil {
            // Continue on canonical path — inform builder
        }
        let base = (full as NSString).lastPathComponent
        if base == ".git" || full.contains("/.git/") {
            return AgentToolResult(ok: false, output: "Non posso patchare .git")
        }
        let original: String
        if FileManager.default.fileExists(atPath: full),
           let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
           let text = String(data: data, encoding: .utf8) {
            original = text
        } else {
            original = ""
        }

        let modeL = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contentTrim = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentinel = ["append", "todo", "…", "...", "patch", "here"].contains(contentTrim.lowercased())

        // Surgical replace (preferred for large CSS/JS)
        if !oldString.isEmpty {
            guard original.contains(oldString) else {
                return AgentToolResult(
                    ok: false,
                    output: """
                    old_string non trovato in `\(editPath)`. Copia un pezzo ESATTO da read_file (max ~40 righe).
                    Oppure mode=append con content=blocco CSS completo.
                    """
                )
            }
            let proposed = original.replacingOccurrences(of: oldString, with: newString, options: [], range: nil)
            // Only replace first occurrence if unique intent — if multiple, still ok for identical rules
            let count = original.components(separatedBy: oldString).count - 1
            let finalProposed: String
            if count > 1 {
                if let r = original.range(of: oldString) {
                    finalProposed = original.replacingCharacters(in: r, with: newString)
                } else {
                    finalProposed = proposed
                }
            } else {
                finalProposed = proposed
            }
            return storePendingPatch(editPath: editPath, full: full, original: original, proposed: finalProposed, redirectFrom: mapped.redirectedFrom)
        }

        // Append block at end of file
        if modeL == "append" || modeL == "append_only" {
            guard !contentTrim.isEmpty, !sentinel else {
                return AgentToolResult(
                    ok: false,
                    output: """
                    mode=append richiede content= blocco reale da aggiungere (es. regole CSS), non la parola "APPEND".
                    Esempio: {"tool":"propose_patch","path":"premium-ui.css","mode":"append","content":"\\n.p-big-play{background:linear-gradient(#3ddc84,#1faa54);}\\n"}
                    """
                )
            }
            if content.utf8.count > maxPatchBytes {
                return AgentToolResult(ok: false, output: "Content troppo grande (\(content.utf8.count) > \(maxPatchBytes)).")
            }
            let sep = original.hasSuffix("\n") || original.isEmpty ? "" : "\n"
            let proposed = original + sep + contentTrim + (contentTrim.hasSuffix("\n") ? "" : "\n")
            return storePendingPatch(editPath: editPath, full: full, original: original, proposed: proposed, redirectFrom: mapped.redirectedFrom)
        }

        // Accidental sentinel that would wipe the file
        if sentinel || contentTrim.count < 8 {
            return AgentToolResult(
                ok: false,
                output: """
                propose_patch rifiutato: content «\(contentTrim.prefix(40))» non è un file valido (troncherebbe `\(editPath)`).
                Usa old_string/new_string, oppure mode=append con il blocco CSS/JS completo.
                """
            )
        }

        if content.utf8.count > maxPatchBytes {
            return AgentToolResult(
                ok: false,
                output: "Content troppo grande (\(content.utf8.count) > \(maxPatchBytes)). Spezza in patch più piccola o usa old_string/new_string."
            )
        }

        // Full rewrite: refuse silent wipe of large files
        if !original.isEmpty,
           original.utf8.count > 2_000,
           content.utf8.count < original.utf8.count / 2 {
            return AgentToolResult(
                ok: false,
                output: """
                Rifiutato: il content (\(content.utf8.count) B) cancellerebbe >50% di `\(editPath)` (\(original.utf8.count) B).
                Usa old_string/new_string o mode=append. Non riscrivere l'intero CSS minificato.
                """
            )
        }

        if original == content {
            return AgentToolResult(ok: true, output: "Nessuna differenza rispetto a \(full)")
        }
        return storePendingPatch(editPath: editPath, full: full, original: original, proposed: content, redirectFrom: mapped.redirectedFrom)
    }

    private func storePendingPatch(
        editPath: String,
        full: String,
        original: String,
        proposed: String,
        redirectFrom: String?
    ) -> AgentToolResult {
        let diff = Self.unifiedDiff(path: editPath, old: original, new: proposed)
        let key = (full as NSString).standardizingPath
        pendingPatches[key] = PendingPatch(
            path: editPath,
            fullPath: full,
            original: original,
            proposed: proposed,
            diff: diff,
            at: .now
        )
        let preview = diff.count > 6_000 ? String(diff.prefix(6_000)) + "\n… [diff troncato]" : diff
        let redirectNote = redirectFrom.map {
            "\n↻ Path build/mirror `\($0)` → sorgente tracked `\(editPath)` (come Cursor; git vedrà la diff)."
        } ?? ""
        return AgentToolResult(
            ok: true,
            output: """
            PATCH PROPOSTA (non applicata) · \(full)\(redirectNote)
            Per scrivere su disco: {"tool":"apply_patch","path":"\(editPath)"}
            Per scartare: {"tool":"discard_patch","path":"\(editPath)"}

            ```diff
            \(preview)
            ```
            """
        )
    }

    private func applyPatch(path: String) -> AgentToolResult {
        // Empty path → sole pending patch (don't resolve ".")
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if pendingPatches.count == 1, let p = pendingPatches.values.first {
                return writePending(p)
            }
            return AgentToolResult(ok: false, output: "Nessun patch pendente. Usa propose_patch prima.")
        }
        let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        let editPath = Self.canonicalSourceRelative(path, workspaceRoot: root).path
        guard let full = resolvePath(editPath) else {
            // Path fuori sandbox / non risolvibile: non applicare un'altra patch "unica" pendente
            // (evita write silenzioso su target diverso da quello chiesto).
            return AgentToolResult(
                ok: false,
                output: "Path non consentito o fuori workspace: \(path). Usa propose_patch sul path corretto, oppure apply_patch senza path se c’è un solo patch pendente."
            )
        }
        let key = (full as NSString).standardizingPath
        // Also try match by relative key
        let patch = pendingPatches[key]
            ?? pendingPatches.first(where: {
                $0.value.path == path || $0.value.path == editPath
                    || $0.value.fullPath.hasSuffix(path) || $0.value.fullPath.hasSuffix(editPath)
            })?.value
        guard let patch else {
            let keys = pendingPatches.values.map(\.path).joined(separator: ", ")
            return AgentToolResult(
                ok: false,
                output: "Nessun patch per \(path). Pendenti: \(keys.isEmpty ? "nessuno" : keys)"
            )
        }
        return writePending(patch)
    }

    private func discardPatch(path: String) -> AgentToolResult {
        if path.isEmpty {
            let n = pendingPatches.count
            pendingPatches.removeAll()
            return AgentToolResult(ok: true, output: "Scartati \(n) patch")
        }
        guard let full = resolvePath(path) else {
            return AgentToolResult(ok: false, output: "Path non valido")
        }
        let key = (full as NSString).standardizingPath
        if pendingPatches.removeValue(forKey: key) != nil {
            return AgentToolResult(ok: true, output: "Patch scartata per \(path)")
        }
        // fuzzy
        if let k = pendingPatches.first(where: { $0.value.path == path })?.key {
            pendingPatches.removeValue(forKey: k)
            return AgentToolResult(ok: true, output: "Patch scartata per \(path)")
        }
        return AgentToolResult(ok: false, output: "Nessun patch pendente per \(path)")
    }

    private func writePending(_ patch: PendingPatch) -> AgentToolResult {
        let result = writeFile(path: patch.path, content: patch.proposed)
        if result.ok {
            let key = (patch.fullPath as NSString).standardizingPath
            pendingPatches.removeValue(forKey: key)
            return AgentToolResult(
                ok: true,
                output: "APPLY OK · \(patch.fullPath)\n" + result.output + "\n\nSuggerimento: git_status (deve vedere la diff tracked), poi complete_task."
            )
        }
        return result
    }

    private func recordAppliedPath(_ path: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if !appliedPathsThisSession.contains(p) {
            appliedPathsThisSession.append(p)
        }
    }

    /// Simple unified-style diff (line-based, not full Myers — good enough for agent review).
    static func unifiedDiff(path: String, old: String, new: String) -> String {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var out: [String] = [
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -1,\(a.count) +1,\(b.count) @@",
        ]
        let aSet = Set(a)
        let bSet = Set(b)
        // Show removals then additions with a shared-context hint
        var shown = 0
        for line in a where !bSet.contains(line) {
            out.append("-\(line)")
            shown += 1
            if shown > 200 { out.append("… [removals capped]"); break }
        }
        var add = 0
        for line in b where !aSet.contains(line) {
            out.append("+\(line)")
            add += 1
            if add > 200 { out.append("… [additions capped]"); break }
        }
        if shown == 0 && add == 0 {
            // Same multiset but reordered — dump head of both
            out.append(" (reorder/whitespace — preview new head)")
            for line in b.prefix(40) { out.append("+\(line)") }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Impl

    private func resolvePath(_ raw: String) -> String? {
        let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "." }
        if p.hasPrefix("~") {
            p = (p as NSString).expandingTildeInPath
        }
        if p == "." || p == "./" {
            return root.map { WorkspacePathSandbox.realStandardizedPath($0) }
        }
        // Absolute → still remap under workspace if it's a www/ build path
        if p.hasPrefix("/") {
            if let root {
                let rootReal = WorkspacePathSandbox.realStandardizedPath(root)
                guard WorkspacePathSandbox.contains(candidate: p, workspaceRoot: rootReal) else { return nil }
                let pReal = WorkspacePathSandbox.realStandardizedPath(p)
                let prefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
                let rel = pReal == rootReal ? "." : String(pReal.dropFirst(prefix.count))
                let canon = Self.canonicalSourceRelative(rel, workspaceRoot: rootReal).path
                if canon == "." { return rootReal }
                let joined = (rootReal as NSString).appendingPathComponent(canon)
                let out = WorkspacePathSandbox.realStandardizedPath(joined)
                guard WorkspacePathSandbox.contains(candidate: out, workspaceRoot: rootReal) else { return nil }
                return out
            }
            return nil
        }
        guard let root else { return nil }
        let rootReal = WorkspacePathSandbox.realStandardizedPath(root)
        let canon = Self.canonicalSourceRelative(p, workspaceRoot: rootReal).path
        if canon == "." { return rootReal }
        let joined = (rootReal as NSString).appendingPathComponent(canon)
        let out = WorkspacePathSandbox.realStandardizedPath(joined)
        guard WorkspacePathSandbox.contains(candidate: out, workspaceRoot: rootReal) else { return nil }
        return out
    }

    private func listDir(_ path: String) -> AgentToolResult {
        guard let full = resolvePath(path) else {
            return AgentToolResult(ok: false, output: "Path fuori workspace / non valido: \(path)")
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: full) else {
            return AgentToolResult(ok: false, output: "Impossibile leggere \(full)")
        }
        let sorted = names.sorted().prefix(maxList)
        var lines: [String] = []
        for n in sorted {
            let fp = (full as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: fp, isDirectory: &isDir)
            lines.append((isDir.boolValue ? "d " : "f ") + n)
        }
        return AgentToolResult(ok: true, output: lines.joined(separator: "\n") + "\n(\(lines.count) entries in \(full))")
    }

    private func readFile(
        _ path: String,
        startLine: Int? = nil,
        maxLines: Int? = nil,
        around: Int? = nil
    ) -> AgentToolResult {
        guard let full = resolvePath(path) else {
            return AgentToolResult(ok: false, output: "Path non consentito: \(path)")
        }
        let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        let mapped = Self.canonicalSourceRelative(path, workspaceRoot: root)
        if let from = mapped.redirectedFrom, from != mapped.path {
            // Re-resolve on canonical — resolvePath already remaps, just annotate below
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
            return AgentToolResult(ok: false, output: "File non leggibile: \(full)")
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if text.isEmpty { return AgentToolResult(ok: true, output: "(vuoto)") }

        let lines = text.components(separatedBy: "\n")
        let window = max(20, min(maxLines ?? TokenBudget.toolReadWindowLines, 200))
        let scoped: Bool
        let slice: ArraySlice<String>
        let fromLine: Int

        if let around, around > 0 {
            let center = around - 1
            let half = window / 2
            let from = max(0, center - half)
            let to = min(lines.count, from + window)
            fromLine = from + 1
            slice = lines[from..<to]
            scoped = true
        } else if let start = startLine, start > 0 {
            let from = min(lines.count, max(0, start - 1))
            let to = min(lines.count, from + window)
            fromLine = from + 1
            slice = lines[from..<to]
            scoped = true
        } else if data.count > maxReadBytes || lines.count > TokenBudget.toolReadWindowLines {
            // Unscoped giant file: never dump the whole thing into the LLM.
            let to = min(lines.count, TokenBudget.toolReadWindowLines)
            fromLine = 1
            slice = lines[0..<to]
            scoped = false
        } else {
            if let from = mapped.redirectedFrom, from != mapped.path {
                return AgentToolResult(ok: true, output: "↻ Lettura da sorgente `\(mapped.path)` (richiesto: \(from))\n\n\(text)")
            }
            return AgentToolResult(ok: true, output: text)
        }

        var body = slice.enumerated().map { idx, line in
            let n = fromLine + idx
            return "\(n)|\(line)"
        }.joined(separator: "\n")

        if !scoped {
            body += """


            … [file grande \(lines.count) righe / \(data.count) bytes — NON rileggere intero]
            Usa {"tool":"read_file","path":"\(mapped.path)","around":"<LINE dalla capsule>","max_lines":"80"}
            oppure start_line. Poi propose_patch sul path tracked (root/src — non www/ build).
            """
        } else if fromLine + slice.count - 1 < lines.count {
            body += "\n\n… [righe \(fromLine)–\(fromLine + slice.count - 1) / \(lines.count)]"
        }
        if let from = mapped.redirectedFrom, from != mapped.path {
            body = "↻ Lettura da sorgente `\(mapped.path)` (richiesto: \(from))\n\n" + body
        }
        return AgentToolResult(ok: true, output: body)
    }

    /// `cat path` / `cat ./path` / `head -n N path` → relative path for read_file redirect.
    private static func simpleCatPath(_ cmd: String) -> String? {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:/bin/)?(?:cat|head)\s+(?:-n\s+\d+\s+)?(?:\./)?([A-Za-z0-9_./\-]+\.(?:css|js|ts|tsx|jsx|swift|html|json|md|scss))$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let m = re.firstMatch(in: trimmed, options: [], range: range),
              let r = Range(m.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[r])
    }

    /// Reject bare $HOME as a project root (caused patches under ~/www/…).
    /// Returns the real (symlink-resolved) path so containment stays consistent.
    static func sanitizedWorkspace(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let std = WorkspacePathSandbox.realStandardizedPath(path)
        let home = WorkspacePathSandbox.realStandardizedPath(NSHomeDirectory())
        if std == home { return nil }
        return std
    }

    /// True when `www/` is a Capacitor/native build output (not the Cursor-style source tree).
    static func isWwwBuildOutput(workspaceRoot: String?) -> Bool {
        guard let root = sanitizedWorkspace(workspaceRoot) else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: root + "/scripts/prepare-native.mjs") { return true }
        if let gi = try? String(contentsOfFile: root + "/.gitignore", encoding: .utf8) {
            for line in gi.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "www/" || t == "/www/" || t == "www" || t.hasPrefix("www/") && !t.contains("*") {
                    return true
                }
            }
        }
        return false
    }

    /// Map agent-relative path → real editable source (root/`src/`), like Cursor/Claude.
    /// `www/foo` → `foo` when root has it or www is build output; native public/ → same.
    static func canonicalSourceRelative(
        _ path: String,
        workspaceRoot: String?
    ) -> (path: String, redirectedFrom: String?) {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        if p.isEmpty || p == "." { return (".", nil) }

        var from: String?

        if let alt = wwwMirrorAlternate(p), alt != p {
            from = p
            p = alt
        }

        if p.hasPrefix("www/") {
            let rest = String(p.dropFirst(4))
            guard !rest.isEmpty else { return (p, from) }
            let buildOut = isWwwBuildOutput(workspaceRoot: workspaceRoot)
            if let root = sanitizedWorkspace(workspaceRoot) {
                let fm = FileManager.default
                let rootFile = (root as NSString).appendingPathComponent(rest)
                let srcFile = (root as NSString).appendingPathComponent("src/" + rest)
                if fm.fileExists(atPath: rootFile) {
                    return (rest, from ?? "www/\(rest)")
                }
                if fm.fileExists(atPath: srcFile) {
                    return ("src/" + rest, from ?? "www/\(rest)")
                }
                if buildOut {
                    // Edit will land on tracked tree; prepare-native will rebuild www later.
                    return (rest, from ?? "www/\(rest)")
                }
            }
        }
        return (p, from)
    }

    /// Map Capacitor native public mirrors → www/… then canonicalized to root.
    private static func wwwMirrorAlternate(_ path: String) -> String? {
        let norm = path.replacingOccurrences(of: "\\", with: "/")
        let low = norm.lowercased()
        let prefixes = [
            "ios/App/App/public/",
            "android/app/src/main/assets/public/",
            "ios/app/app/public/",
        ]
        for p in prefixes {
            if low.hasPrefix(p.lowercased()) {
                let rest = String(norm.dropFirst(p.count))
                return "www/\(rest)"
            }
        }
        return nil
    }

    private func writeFile(path: String, content: String) -> AgentToolResult {
        guard let full = resolvePath(path) else {
            return AgentToolResult(ok: false, output: "Path non consentito: \(path)")
        }
        if content.utf8.count > maxPatchBytes {
            return AgentToolResult(ok: false, output: "Content troppo grande")
        }
        let base = (full as NSString).lastPathComponent
        if base == ".git" || full.contains("/.git/") {
            return AgentToolResult(ok: false, output: "Non posso scrivere in .git")
        }
        do {
            let dir = (full as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: full)
            // Atomic write + mtime bump so GitHub Desktop / FSEvents see the change like CLI tools
            try content.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: full
            )
            // Nudge parent dir (helps some watchers)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: dir
            )
            if let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path) {
                git?.setPath(root)
                // Force git index to re-stat (Desktop parity)
                _ = GitRunner.run(["status", "--porcelain", "--", full], in: root, timeoutSeconds: 8)
            }
            // Keep code-brain capsule fresh (hot path, no full scan)
            if let root = workspaceRoot ?? workspaces?.current?.path {
                let rel: String
                if full.hasPrefix(root) {
                    rel = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else {
                    rel = path
                }
                ProjectCodeBrain.shared.reindexRelativePaths(workspace: root, relativePaths: [rel])
                if let tid = taskId, !rel.isEmpty {
                    tasks?.appendEvidence(tid, "file:\(rel)")
                }
                recordAppliedPath(rel.isEmpty ? path : rel)
            } else {
                recordAppliedPath(path)
            }
            git?.notifyWorkingTreeMaybeChanged()
            workspaces?.markExternallyModified(paths: [full])
            return AgentToolResult(ok: true, output: "Scritto \(full) (\(content.utf8.count) bytes)")
        } catch {
            return AgentToolResult(ok: false, output: error.localizedDescription)
        }
    }

    private func runCommand(_ command: String) -> AgentToolResult {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            return AgentToolResult(ok: false, output: "Comando vuoto")
        }
        let lower = cmd.lowercased()
        // Agents love `cat huge.css` — that burns tokens + hits 45s timeout. Redirect to ranged read_file.
        if let catPath = Self.simpleCatPath(cmd) {
            let r = readFile(catPath, startLine: 1, maxLines: TokenBudget.toolReadWindowLines, around: nil)
            return AgentToolResult(
                ok: r.ok,
                output: "_(run_command cat → read_file finestra; usa around=LINE)_\n\n" + r.output
            )
        }
        let blocked = ["rm -rf /", "mkfs", "dd if=", ":(){", "shutdown", "reboot", "diskutil erase"]
        if blocked.contains(where: { lower.contains($0) }) {
            return AgentToolResult(ok: false, output: "Comando bloccato da safety agent")
        }
        if let policy = workspaces?.safetyPolicy, let msg = policy.blocks(cmd) {
            return AgentToolResult(ok: false, output: msg)
        }

        guard let cwd = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path) else {
            return AgentToolResult(
                ok: false,
                output: "run_command rifiutato: nessun workspace progetto (non uso $HOME). Apri zackgame / progetto."
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = AgentProcessEnvironment.prepare(mode: .agentSafe).merging([
            "TERM": "dumb",
            "GIT_TERMINAL_PROMPT": "0",
        ]) { _, n in n }

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                proc.waitUntilExit()
                group.leave()
            }
            let wait = group.wait(timeout: .now() + 45)
            if wait == .timedOut {
                proc.terminate()
                return AgentToolResult(ok: false, output: "Timeout 45s: \(cmd)")
            }
        } catch {
            return AgentToolResult(ok: false, output: error.localizedDescription)
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var combined = stdout
        if !stderr.isEmpty {
            combined += (combined.isEmpty ? "" : "\n") + "[stderr]\n" + stderr
        }
        combined = SecretRedactor.redact(combined)
        let cap = TokenBudget.toolCommandOutChars
        if combined.count > cap {
            combined = String(combined.prefix(cap)) + "\n…"
        }
        let ok = proc.terminationStatus == 0
        let header = "exit \(proc.terminationStatus) · cwd \(cwd)\n"
        return AgentToolResult(ok: ok, output: header + (combined.isEmpty ? "(no output)" : combined))
    }

    private func gitStatus() -> AgentToolResult {
        let root = Self.sanitizedWorkspace(workspaceRoot ?? workspaces?.current?.path)
        if let root {
            let (snap, _) = GitRunner.loadSnapshot(path: root)
            git?.setPath(root)
            let diff = GitRunner.run(["diff", "--stat"], in: snap.root ?? root, timeoutSeconds: 8).stdout
            return AgentToolResult(
                ok: snap.isRepo,
                output: snap.summaryLine + "\n" + (diff.isEmpty ? "(no diff)" : diff)
            )
        }
        return AgentToolResult(
            ok: false,
            output: "Nessun workspace git. Apri zackgame (o il progetto) — non uso $HOME."
        )
    }

    private func gitLog(limit: Int) -> AgentToolResult {
        let root = workspaceRoot ?? workspaces?.current?.path
        if let root {
            let (snap, log) = GitRunner.loadSnapshot(path: root)
            if snap.isEmptyRepo {
                return AgentToolResult(ok: true, output: "_Nessun commit (repo vuoto)_")
            }
            let lines = log.prefix(min(limit, 40)).map {
                "• `\($0.shortHash)` \($0.subject) — \($0.author)"
            }
            return AgentToolResult(ok: true, output: lines.isEmpty ? "_Nessun commit_" : lines.joined(separator: "\n"))
        }
        return runCommand("git log -n \(min(limit, 40)) --oneline")
    }

    private func extractJSONObject(_ text: String) -> String? {
        if let r = text.range(of: "```json") {
            let after = text[r.upperBound...]
            if let end = after.range(of: "```") {
                return String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let r = text.range(of: "```") {
            let after = text[r.upperBound...]
            if let end = after.range(of: "```") {
                let inner = String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.hasPrefix("{") { return inner }
            }
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inStr = false
        var esc = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inStr {
                if esc { esc = false }
                else if c == "\\" { esc = true }
                else if c == "\"" { inStr = false }
            } else {
                if c == "\"" { inStr = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...i])
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
