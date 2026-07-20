import Foundation
import Combine

@MainActor
final class TaskStore: ObservableObject {
    @Published var tasks: [AgentTask] = []
    /// Last auto-advanced task after a complete (C2) — UI toast.
    @Published private(set) var lastAutoAdvanced: AgentTask?

    private let storeName = "tasks"

    /// When true, skip JSON load/save (set automatically under XCTest; also usable in DEBUG).
    var suspendPersistence = false

    init() {
        // Prefer empty board in test host — never clobber the user's tasks.json.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            suspendPersistence = true
            tasks = []
            return
        }
        load()
        if tasks.isEmpty && AppConfig.useDemoData {
            tasks = SeedData.tasks
        }
    }

    /// Optional Slack notifier for completion (injected).
    var onTaskCompleted: ((AgentTask) -> Void)?
    /// Fired when C2 promotes the next ready task in a plan.
    var onAutoAdvanced: ((AgentTask) -> Void)?

    @discardableResult
    func add(
        title: String,
        subtitle: String? = nil,
        column: TaskColumn = .todo,
        priority: TaskPriority = .medio,
        model: String = "local",
        workspacePath: String? = nil,
        linkedTerminalID: UUID? = nil,
        source: TaskSource = .manual,
        evidence: [String] = [],
        planId: UUID? = nil,
        dependsOn: [UUID] = []
    ) -> AgentTask {
        let t = AgentTask(
            title: title,
            subtitle: subtitle,
            priority: priority,
            column: column,
            assigneeModel: model,
            workspacePath: workspacePath,
            linkedTerminalID: linkedTerminalID,
            source: source,
            evidence: evidence,
            planId: planId,
            dependsOn: dependsOn
        )
        tasks.insert(t, at: 0)
        persist()
        AppLogger.info("Task added: \(title)")
        return t
    }

    /// Smart plan from repo (A1–A3) + sequential DAG (C1).
    /// Each task depends on the previous one so the plan is executable top→bottom.
    @discardableResult
    func addPlan(forWorkspace path: String?, projectName: String, model: String = "local") -> [AgentTask] {
        let root = path.map { ($0 as NSString).standardizingPath }
        let name = projectName.isEmpty
            ? (root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "progetto")
            : projectName

        let suggested: [SuggestedTask]
        if let root, FileManager.default.fileExists(atPath: root) {
            let snap = ProjectBrain.refresh(path: root)
            suggested = ProjectBrain.suggestTasks(from: snap)
            AppLogger.info("Smart plan snapshot: \(snap.summaryLine)")
        } else {
            suggested = [
                SuggestedTask(
                    title: "[\(name)] Apri workspace e scansiona root",
                    subtitle: "Path non disponibile al momento del piano",
                    priority: .alto,
                    source: .template,
                    evidence: ["path mancante"]
                )
            ]
        }

        let planId = UUID()
        var created: [AgentTask] = []
        var previousId: UUID?

        for (idx, s) in suggested.enumerated() {
            let id = UUID()
            let deps: [UUID] = previousId.map { [$0] } ?? []
            var evidence = s.evidence
            evidence.append("plan:\(planId.uuidString.prefix(8))")
            if !deps.isEmpty {
                evidence.append("depends: step \(idx)")
            }
            let task = AgentTask(
                id: id,
                title: s.title,
                subtitle: s.subtitle,
                priority: s.priority,
                column: .todo,
                assigneeModel: model,
                workspacePath: root,
                source: s.source,
                evidence: evidence,
                planId: planId,
                dependsOn: deps
            )
            created.append(task)
            previousId = id
        }
        tasks.insert(contentsOf: created, at: 0)
        persist()
        let evidenceCount = created.filter { !$0.evidence.isEmpty && $0.source != .template }.count
        AppLogger.info("Plan added: \(name) · \(created.count) tasks · planId=\(planId.uuidString.prefix(8)) · \(evidenceCount) with evidence")

        DecisionLogStore.shared.append(
            workspace: root,
            kind: .plan,
            text: "Piano \(name): \(created.count) task (DAG sequenziale)",
            relatedTaskIds: created.map(\.id),
            meta: ["planId": planId.uuidString]
        )
        return created
    }

    // MARK: - C1 DAG

    /// All dependency tasks are **DONE** (BUG-009: REVIEW must not unlock dependents).
    /// Missing dependency id → still blocked (safe after clearCompleted without edge stripping).
    func isUnblocked(_ task: AgentTask) -> Bool {
        for depId in task.dependsOn {
            guard let dep = self.task(id: depId) else { return false }
            if dep.column != .done { return false }
        }
        return true
    }

    func isUnblocked(id: UUID) -> Bool {
        guard let t = task(id: id) else { return false }
        return isUnblocked(t)
    }

    /// Titles of open dependencies (for UI / errors).
    func blockingTitles(for task: AgentTask) -> [String] {
        task.dependsOn.compactMap { depId -> String? in
            guard let dep = self.task(id: depId) else { return "missing" }
            if dep.column == .done { return nil }
            return dep.title
        }
    }

    func canStart(_ id: UUID) -> (ok: Bool, reason: String?) {
        guard let t = task(id: id) else { return (false, "Task non trovata") }
        if t.column == .done { return (false, "Già completata") }
        if isUnblocked(t) { return (true, nil) }
        let names = blockingTitles(for: t)
        return (false, "Bloccata da: \(names.joined(separator: " · "))")
    }

    /// Tasks in a plan ordered by DAG (roots first, then dependents).
    func tasks(inPlan planId: UUID) -> [AgentTask] {
        let set = tasks.filter { $0.planId == planId }
        // Topological-ish: fewer deps first, then original insertion reverse (plan was inserted at 0)
        return set.sorted { a, b in
            if a.dependsOn.count != b.dependsOn.count {
                return a.dependsOn.count < b.dependsOn.count
            }
            return a.title < b.title
        }
    }

    /// Ready TODO tasks (unblocked) optionally scoped to workspace.
    func readyTodo(workspacePath: String? = nil) -> [AgentTask] {
        tasks.filter { t in
            t.column == .todo
                && isUnblocked(t)
                && (workspacePath == nil || t.workspacePath == nil || t.workspacePath == workspacePath)
        }
    }

    // MARK: - Lifecycle

    func linkTerminal(_ taskID: UUID, terminalID: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[i].linkedTerminalID = terminalID
        if tasks[i].column == .todo {
            tasks[i].column = .inProgress
            tasks[i].progress = 0.15
        }
        persist()
    }

    /// Terminal process ended → complete linked task (exit 0) or leave in review (non-zero).
    @discardableResult
    func handleTerminalExit(terminalID: UUID, exitCode: Int32) -> AgentTask? {
        guard let i = tasks.firstIndex(where: { $0.linkedTerminalID == terminalID }) else { return nil }
        if exitCode == 0 {
            let id = tasks[i].id
            tasks[i].column = .done
            tasks[i].progress = 1.0
            let t = tasks[i]
            persist()
            onTaskCompleted?(t)
            _ = autoAdvance(after: id)
            return t
        } else {
            tasks[i].column = .review
            tasks[i].progress = 0.85
            tasks[i].subtitle = (tasks[i].subtitle.map { $0 + " · " } ?? "") + "exit \(exitCode)"
            persist()
            return tasks[i]
        }
    }

    func appendEvidence(_ id: UUID, _ item: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let tag = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !tasks[i].evidence.contains(tag) else { return }
        tasks[i].evidence.append(tag)
        persist()
    }

    func move(_ id: UUID, to column: TaskColumn) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Soft gate: allow move to inProgress only if unblocked (unless already past todo)
        if column == .inProgress, tasks[i].column == .todo, !isUnblocked(tasks[i]) {
            AppLogger.warn("Move blocked for \(tasks[i].title): open dependencies")
            return
        }
        tasks[i].column = column
        applyProgressForColumn(&tasks[i], column)
        persist()
    }

    /// Force move ignoring DAG (context menu override).
    func forceMove(_ id: UUID, to column: TaskColumn) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].column = column
        applyProgressForColumn(&tasks[i], column)
        persist()
    }

    private func applyProgressForColumn(_ task: inout AgentTask, _ column: TaskColumn) {
        switch column {
        case .todo:
            break
        case .inProgress:
            if task.progress == nil || (task.progress ?? 0) < 0.1 {
                task.progress = 0.1
            }
        case .review:
            // Never leave review stuck at 10% after real work
            task.progress = max(task.progress ?? 0, 0.9)
        case .done:
            task.progress = 1.0
        }
    }

    func setModel(_ id: UUID, _ model: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].assigneeModel = model
        persist()
    }

    /// Attribute LLM usage to a board task (tokens + stima by priority/model).
    func addUsage(_ id: UUID, tokens: Int) {
        guard tokens > 0, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].tokensUsed += tokens
        let rate = tasks[i].costPer1kUSD
        tasks[i].estimatedCostUSD += Double(tokens) / 1000.0 * rate
        persist()
    }

    func setWorkspace(_ id: UUID, _ path: String?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].workspacePath = path
        persist()
    }

    func setPlanId(_ id: UUID, planId: UUID?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].planId = planId
        persist()
    }

    /// Mark task complete → COMPLETATE, then C2 auto-advance next in plan.
    @discardableResult
    func complete(_ id: UUID) -> AgentTask? {
        guard let t = task(id: id) else { return nil }
        forceMove(id, to: .done)
        onTaskCompleted?(t)
        AppLogger.info("Task completed: \(id.uuidString.prefix(8))")
        DecisionLogStore.shared.append(
            workspace: t.workspacePath,
            kind: .complete,
            text: "Completata: \(t.title)",
            relatedTaskIds: [id],
            meta: t.planId.map { ["planId": $0.uuidString] } ?? [:]
        )
        return autoAdvance(after: id)
    }

    /// C2: promote next unblocked TODO in the same plan (or same workspace chain).
    @discardableResult
    func autoAdvance(after completedId: UUID) -> AgentTask? {
        lastAutoAdvanced = nil
        guard let completed = task(id: completedId) else { return nil }

        // Prefer direct dependents in the same plan
        var candidates = tasks.filter { t in
            t.column == .todo
                && t.dependsOn.contains(completedId)
                && isUnblocked(t)
        }

        // Else any ready TODO in same plan
        if candidates.isEmpty, let planId = completed.planId {
            candidates = tasks.filter { t in
                t.planId == planId && t.column == .todo && isUnblocked(t)
            }
        }

        // Stable order: fewer remaining deps first
        candidates.sort { $0.dependsOn.count < $1.dependsOn.count }

        guard let next = candidates.first, let i = tasks.firstIndex(where: { $0.id == next.id }) else {
            AppLogger.info("Auto-advance: no next ready after \(completed.title)")
            return nil
        }

        tasks[i].column = .inProgress
        tasks[i].progress = 0.1
        select(next.id)
        persist()
        lastAutoAdvanced = tasks[i]
        onAutoAdvanced?(tasks[i])
        AppLogger.info("Auto-advance → \(tasks[i].title)")
        DecisionLogStore.shared.append(
            workspace: tasks[i].workspacePath,
            kind: .advance,
            text: "Auto-advance → \(tasks[i].title)",
            relatedTaskIds: [completedId, tasks[i].id],
            meta: tasks[i].planId.map { ["planId": $0.uuidString] } ?? [:]
        )
        return tasks[i]
    }

    func filtered(workspacePath: String?, onlyCurrentWorkspace: Bool) -> [AgentTask] {
        // BUG-018: filtro ON senza workspace → lista vuota (non tutte le task).
        guard onlyCurrentWorkspace else { return tasks }
        guard let workspacePath, !workspacePath.isEmpty else { return [] }
        let root = (workspacePath as NSString).standardizingPath
        return tasks.filter { task in
            guard let wp = task.workspacePath, !wp.isEmpty else { return false }
            return (wp as NSString).standardizingPath == root
        }
    }

    func select(_ id: UUID) {
        // Reassign array so @Published fires (in-place mutate often skips UI updates).
        var copy = tasks
        for i in copy.indices {
            copy[i].isSelected = copy[i].id == id
        }
        tasks = copy
    }

    func count(in column: TaskColumn) -> Int {
        tasks.filter { $0.column == column }.count
    }

    func count(in column: TaskColumn, workspacePath: String?, onlyCurrentWorkspace: Bool) -> Int {
        filtered(workspacePath: workspacePath, onlyCurrentWorkspace: onlyCurrentWorkspace)
            .filter { $0.column == column }
            .count
    }

    /// Soft progress only. Caps at 0.99 — DONE exclusively via `complete` / user `forceMove` (BUG-016).
    func updateProgress(_ id: UUID, _ progress: Double) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let capped = min(0.99, max(0, progress))
        tasks[i].progress = capped
        persist()
    }

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        // Drop dangling edges
        for i in tasks.indices {
            tasks[i].dependsOn.removeAll { $0 == id }
        }
        tasks.removeAll { $0.id == id }
        persist()
        AppLogger.info("Task deleted: \(id.uuidString.prefix(8))")
    }

    /// Remove all completed tasks (archive/clean).
    func clearCompleted() {
        clearColumns([.done], workspacePath: nil, onlyCurrentWorkspace: false)
    }

    /// Remove review and/or done tasks, optionally scoped to the open workspace filter.
    /// BUG-015: never strip `dependsOn` edges — missing deps keep dependents blocked.
    /// Also skip deleting a completed task while an *open* task still depends on it.
    @discardableResult
    func clearColumns(
        _ columns: Set<TaskColumn>,
        workspacePath: String?,
        onlyCurrentWorkspace: Bool
    ) -> Int {
        guard !columns.isEmpty else { return 0 }
        let scope = filtered(workspacePath: workspacePath, onlyCurrentWorkspace: onlyCurrentWorkspace)
        let candidates = Set(scope.filter { columns.contains($0.column) }.map(\.id))
        guard !candidates.isEmpty else { return 0 }
        let stillNeeded = candidates.filter { depId in
            tasks.contains { t in
                !candidates.contains(t.id)
                    && t.dependsOn.contains(depId)
                    && t.column != .done
            }
        }
        let removeIds = candidates.subtracting(stillNeeded)
        guard !removeIds.isEmpty else {
            AppLogger.warn("clearColumns: \(candidates.count) candidate(s) kept — still depended on")
            return 0
        }
        tasks.removeAll { removeIds.contains($0.id) }
        persist()
        AppLogger.info("Cleared \(removeIds.count) task(s) in \(columns.map(\.rawValue).joined(separator: "+"))")
        return removeIds.count
    }

    /// Delete every task in scope (all columns), optionally only current workspace filter.
    @discardableResult
    func clearAll(workspacePath: String?, onlyCurrentWorkspace: Bool) -> Int {
        let scope = filtered(workspacePath: workspacePath, onlyCurrentWorkspace: onlyCurrentWorkspace)
        let removeIds = Set(scope.map(\.id))
        guard !removeIds.isEmpty else { return 0 }
        // Keep dependsOn edges on survivors outside scope; missing ids stay blocking.
        tasks.removeAll { removeIds.contains($0.id) }
        persist()
        AppLogger.info("Cleared ALL \(removeIds.count) task(s)")
        return removeIds.count
    }

    private func load() {
        if suspendPersistence { return }
        if let loaded: [AgentTask] = JSONStore.load([AgentTask].self, name: storeName) {
            tasks = loaded
        }
    }

    func persist() {
        if suspendPersistence { return }
        JSONStore.save(tasks, name: storeName)
    }
}
