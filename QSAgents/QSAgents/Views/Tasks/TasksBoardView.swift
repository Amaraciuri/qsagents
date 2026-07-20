import SwiftUI

struct TasksBoardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @State private var newTaskTitle: String = ""
    @State private var showAdd: Bool = false
    @State private var toast: String?
    @State private var taskPendingDelete: UUID?
    @State private var showDeleteConfirm = false
    @State private var pendingBulkClear: BulkClear?
    @State private var showBulkClearConfirm = false
    /// Default ON: board shows only the open workspace (orchestrator can still work across projects).
    @State private var filterCurrentWorkspace = true
    @State private var defaultModel: String = ProviderPreferences.shared.model(for: .builder)
    @ObservedObject private var prefs = ProviderPreferences.shared

    private enum BulkClear: Identifiable, Equatable {
        case review
        case done
        case reviewAndDone
        case all

        var id: String {
            switch self {
            case .review: return "review"
            case .done: return "done"
            case .reviewAndDone: return "both"
            case .all: return "all"
            }
        }

        var columns: Set<TaskColumn>? {
            switch self {
            case .review: return [.review]
            case .done: return [.done]
            case .reviewAndDone: return [.review, .done]
            case .all: return nil
            }
        }

        var title: String {
            switch self {
            case .review: return "Svuotare IN REVISIONE?"
            case .done: return "Svuotare COMPLETATE?"
            case .reviewAndDone: return "Svuotare revisione + completate?"
            case .all: return "Eliminare TUTTE le task?"
            }
        }
    }

    private var visibleTasks: [AgentTask] {
        taskStore.filtered(
            workspacePath: workspaces.current?.path,
            onlyCurrentWorkspace: filterCurrentWorkspace
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                StandardSidebar()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .leading, help: "Mostra sidebar (⌘B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("QS Tasks")
                        .font(QS.Font.ui(14, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("· board full-width")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                    Spacer()
                    Toggle(workspaces.current.map { "Solo \($0.name)" } ?? "Solo workspace", isOn: $filterCurrentWorkspace)
                        .help("Mostra solo le task del workspace aperto. Off = tutte mescolate.")
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(QS.Font.ui(10))
                    let wsPath = workspaces.current?.path
                    let reviewN = taskStore.count(
                        in: .review, workspacePath: wsPath, onlyCurrentWorkspace: filterCurrentWorkspace
                    )
                    let doneN = taskStore.count(
                        in: .done, workspacePath: wsPath, onlyCurrentWorkspace: filterCurrentWorkspace
                    )
                    if reviewN > 0 {
                        Button {
                            pendingBulkClear = .review
                            showBulkClearConfirm = true
                        } label: {
                            Text("Pulisci revisione (\(reviewN))")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.outline)
                        }
                        .buttonStyle(.plain)
                        .help("Elimina le task IN REVISIONE del filtro attuale")
                    }
                    if doneN > 0 {
                        Button {
                            pendingBulkClear = .done
                            showBulkClearConfirm = true
                        } label: {
                            Text("Pulisci completate (\(doneN))")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.outline)
                        }
                        .buttonStyle(.plain)
                        .help("Elimina le task COMPLETATE del filtro attuale")
                    }
                    if reviewN + doneN > 0 {
                        Button {
                            pendingBulkClear = .reviewAndDone
                            showBulkClearConfirm = true
                        } label: {
                            Text("Pulisci archivio")
                                .font(QS.Font.ui(11, weight: .medium))
                                .foregroundStyle(QS.Color.error.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Elimina revisione + completate (filtro workspace)")
                    }
                    if !visibleTasks.isEmpty {
                        Button {
                            pendingBulkClear = .all
                            showBulkClearConfirm = true
                        } label: {
                            Text("Elimina tutte (\(visibleTasks.count))")
                                .font(QS.Font.ui(11, weight: .semibold))
                                .foregroundStyle(QS.Color.error)
                        }
                        .buttonStyle(.plain)
                        .help("Elimina tutte le task del filtro attuale (TODO + IN CORSO + REVIEW + DONE)")
                    }
                    if let ws = workspaces.current {
                        Text(ws.name)
                            .font(QS.Font.codeSM)
                            .foregroundStyle(QS.Color.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let toast {
                    Text(toast)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.agentActive)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                if visibleTasks.isEmpty {
                    VStack(spacing: 12) {
                        Text("Nessuna task")
                            .font(QS.Font.headline)
                            .foregroundStyle(QS.Color.onSurface)
                        Text("Crea una task, poi Avvia (agent + log in-app) o Invia all'orchestratore.")
                            .font(QS.Font.body)
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                        PrimaryButton(title: "Aggiungi task", icon: "plus") { showAdd = true }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // Board
                        GeometryReader { geo in
                            let cols = TaskColumn.allCases
                            let spacing: CGFloat = 12
                            let hPad: CGFloat = 12
                            let n = CGFloat(cols.count)
                            let colW = max(180, (geo.size.width - hPad * 2 - spacing * (n - 1)) / n)

                            HStack(alignment: .top, spacing: spacing) {
                                ForEach(cols) { column in
                                    let colTasks = visibleTasks.filter { $0.column == column }
                                    TaskColumnView(
                                        column: column,
                                        tasks: colTasks,
                                        count: colTasks.count,
                                        onSelect: { id in
                                            taskStore.select(id)
                                            focusAgentForTask(id)
                                        },
                                        onMove: { id, col in taskStore.move(id, to: col) },
                                        onStart: { id in
                                            // REVIEW: open detail/diff — do not cold-restart via Avvia.
                                            if taskStore.task(id: id)?.column == .review {
                                                openReview(id)
                                            } else {
                                                startTask(id)
                                            }
                                        },
                                        onSendOrchestrator: { sendToOrchestrator($0) },
                                        onComplete: { completeTask($0) },
                                        onDelete: { confirmDelete($0) },
                                        onSetModel: { id, model in taskStore.setModel(id, model) },
                                        onAdd: column == .todo ? { showAdd = true } : nil
                                    )
                                    .frame(width: colW, height: geo.size.height - 8, alignment: .top)
                                }
                            }
                            .padding(.horizontal, hPad)
                            .padding(.bottom, 8)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Agent log OR archive (files touched) for selected task — including DONE.
                        // IN REVISIONE always prefers the archive panel (diff / Applica feedback).
                        Group {
                            if let task = selectedTask, task.column == .review {
                                TaskArchivePanel(task: task)
                            } else if let session = agentForSelectedTask {
                                AgentWorkLogPanel(
                                    session: session,
                                    title: "Log agent della task",
                                    emptyHint: "Log vuoto.",
                                    onStop: { agents.stop(session.id) }
                                )
                            } else if let task = selectedTask {
                                TaskArchivePanel(task: task)
                            } else {
                                AgentWorkLogPanel(
                                    session: nil,
                                    title: "Log agent",
                                    emptyHint: "Seleziona una task (anche COMPLETATE) per vedere file cambiati e log."
                                )
                            }
                        }
                        .frame(minHeight: 200, idealHeight: 240, maxHeight: 320)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }

                BottomStatusBar(leftText: "QS Tasks · log agent sotto · \(taskStore.count(in: .inProgress)) in corso · \(agents.sessions.count) agent")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(QS.Color.backgroundDeep)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(QS.Color.primarySolid)
                        .padding(14)
                        .background(QS.Color.primary)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showLeftSidebar)
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Nuova Task")
                    .font(QS.Font.headline)
                TextField("Titolo task...", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                Text("Modello LLM")
                    .font(QS.Font.ui(11, weight: .medium))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                SearchableModelPicker(
                    provider: prefs.provider(for: .builder) ?? prefs.defaultProvider ?? .spaceXAI,
                    selection: $defaultModel,
                    width: 360
                )
                Text("Catalogo live (stesso di Home) · engine coding: \(CodingEngine.preferred.shortLabel)")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                HStack {
                    Button("Annulla") { showAdd = false }
                    Spacer()
                    Button("Solo crea") {
                        addTask(start: false)
                    }
                    Button("Crea e avvia") {
                        addTask(start: true)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
            .onAppear {
                defaultModel = prefs.model(for: .builder)
            }
        }
        .confirmationDialog(
            "Eliminare questa task?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                if let id = taskPendingDelete {
                    performDelete(id)
                }
                showDeleteConfirm = false
            }
            Button("Annulla", role: .cancel) {
                taskPendingDelete = nil
                showDeleteConfirm = false
            }
        } message: {
            if let id = taskPendingDelete, let t = taskStore.task(id: id) {
                Text("«\(t.title)» verrà rimossa. Non si può annullare.")
            } else {
                Text("L'azione non si può annullare.")
            }
        }
        .confirmationDialog(
            pendingBulkClear?.title ?? "Svuotare colonne?",
            isPresented: $showBulkClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                performBulkClear()
            }
            Button("Annulla", role: .cancel) {
                pendingBulkClear = nil
                showBulkClearConfirm = false
            }
        } message: {
            let scope = filterCurrentWorkspace
                ? (workspaces.current.map { "solo \($0.name)" } ?? "filtro workspace")
                : "tutti i workspace"
            Text("Rimuove le card selezionate (\(scope)). Non si può annullare.")
        }
    }

    private func addTask(start: Bool) {
        let t = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        taskStore.add(
            title: t,
            model: defaultModel,
            workspacePath: workspaces.current?.path
        )
        let id = taskStore.tasks.first?.id
        newTaskTitle = ""
        showAdd = false
        if start, let id {
            startTask(id)
        }
    }

    private var selectedTask: AgentTask? {
        taskStore.tasks.first(where: { $0.isSelected })
    }

    /// Agent bound to the selected task only — never steal focus from another live agent.
    private var agentForSelectedTask: AgentSession? {
        guard let tid = selectedTask?.id else { return nil }
        return agents.sessions.first(where: { $0.taskId == tid })
    }

    private func focusAgentForTask(_ taskId: UUID) {
        if let agent = agents.sessions.first(where: { $0.taskId == taskId }) {
            agents.selectedID = agent.id
        }
    }

    /// IN REVISIONE primary CTA: show file diff / evidence — not another Avvia/restart.
    private func openReview(_ id: UUID) {
        taskStore.select(id)
        focusAgentForTask(id)
        toast = L("Revisiona sotto: file + Applica feedback (niente riavvio).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { toast = nil }
    }

    private func startTask(_ id: UUID) {
        let gate = taskStore.canStart(id)
        if !gate.ok {
            toast = gate.reason ?? "Task bloccata da dipendenze"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { toast = nil }
            return
        }
        // BUG-018: refuse Avvia without project — clear CTA, no silent agent on $HOME.
        guard workspaces.current != nil,
              AgentToolRunner.sanitizedWorkspace(workspaces.current?.path) != nil else {
            toast = "Apri un workspace progetto (⌘⇧O) prima di Avvia — non uso $HOME."
            NotificationCenter.default.post(name: .qsOpenWorkspacePicker, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { toast = nil }
            return
        }
        taskStore.select(id)
        // Orchestratore lancia o riprende lo stesso sub-agent (no nuovo PTY a ogni click).
        let ok = orchestrator.launchBoardTask(id)
        if let agent = agents.agentForTask(id) {
            agents.selectedID = agent.id
        }
        let reused = agents.agentForTask(id).map { agents.runtime.isRunning($0.id) || $0.status == .thinking || $0.status == .active } ?? false
        toast = ok
            ? (reused
               ? L("Già in corso — vedi log sotto (nessun nuovo terminale).")
               : L("Orchestratore ha lanciato/ripreso il builder."))
            : L("Avvio non riuscito — vedi messaggio orchestratore.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { toast = nil }
    }

    private func sendToOrchestrator(_ id: UUID) {
        // Only open ⌘K modal with a prefilled brief — stay on Tasks board (no route jump).
        agents.prepareTaskBriefForOrchestrator(id)
        state.openOrchestratorModal()
        toast = "Brief pronto in ⌘K — premi Invia"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { toast = nil }
    }

    private func completeTask(_ id: UUID) {
        let next = taskStore.complete(id)
        if let next {
            toast = "Completata → prossima: \(next.title)"
        } else {
            toast = "Task completata"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { toast = nil }
    }

    private func confirmDelete(_ id: UUID) {
        taskPendingDelete = id
        showDeleteConfirm = true
    }

    private func performDelete(_ id: UUID) {
        taskStore.remove(id)
        taskPendingDelete = nil
        showDeleteConfirm = false
        toast = "Task eliminata"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
    }

    private func performBulkClear() {
        guard let kind = pendingBulkClear else { return }
        let ws = workspaces.current?.path
        let n: Int
        if let cols = kind.columns {
            n = taskStore.clearColumns(cols, workspacePath: ws, onlyCurrentWorkspace: filterCurrentWorkspace)
        } else {
            n = taskStore.clearAll(workspacePath: ws, onlyCurrentWorkspace: filterCurrentWorkspace)
        }
        pendingBulkClear = nil
        showBulkClearConfirm = false
        toast = n > 0 ? "Rimosse \(n) task" : L("Nessuna task da rimuovere")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
    }
}

/// Board primary CTA labels by column. REVIEW opens detail/diff; others start/resume.
@MainActor
enum TaskBoardStartLabel {
    static func title(for column: TaskColumn, blocked: Bool = false) -> String {
        if blocked { return L("Bloccata") }
        switch column {
        case .review: return L("Revisiona")
        case .inProgress: return L("Continua")
        case .todo, .done: return L("Avvia")
        }
    }

    static func systemImage(for column: TaskColumn, blocked: Bool = false) -> String {
        if blocked { return "lock.fill" }
        switch column {
        case .review: return "eye.fill"
        case .inProgress: return "forward.fill"
        case .todo, .done: return "play.fill"
        }
    }

    static func help(for column: TaskColumn) -> String {
        switch column {
        case .review:
            return L("Apri dettaglio e diff sotto — Applica feedback per ritocchi (niente riavvio)")
        case .inProgress:
            return L("Continua lo stesso agent — nessun nuovo terminale se già in corso")
        case .todo, .done:
            return L("Sposta in corso, crea agent builder e log in-app")
        }
    }
}

struct TaskColumnView: View {
    let column: TaskColumn
    let tasks: [AgentTask]
    let count: Int
    var onSelect: (UUID) -> Void
    var onMove: (UUID, TaskColumn) -> Void
    var onStart: (UUID) -> Void
    var onSendOrchestrator: (UUID) -> Void
    var onComplete: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var onSetModel: ((UUID, String) -> Void)?
    var onAdd: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(column.accent).frame(width: 7, height: 7)
                Text(column.rawValue)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                Text("\(count)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCardView(
                            task: task,
                            onSelect: { onSelect(task.id) },
                            onStart: { onStart(task.id) },
                            onSendOrchestrator: { onSendOrchestrator(task.id) },
                            onComplete: { onComplete(task.id) },
                            onDelete: { onDelete(task.id) }
                        )
                        .contextMenu {
                            if task.column != .done {
                                Button(L("✓ Segna completata")) { onComplete(task.id) }
                            }
                            Button("▶ \(TaskBoardStartLabel.title(for: task.column))") { onStart(task.id) }
                            Button(L("✦ Invia all'orchestratore")) { onSendOrchestrator(task.id) }
                            Divider()
                            ForEach(TaskColumn.allCases) { col in
                                if col != task.column {
                                    Button(L("Sposta in") + " \(col.rawValue)") {
                                        onMove(task.id, col)
                                    }
                                }
                            }
                            Menu(L("Modello")) {
                                let live: [String] = {
                                    var seen = Set<String>()
                                    var out: [String] = []
                                    for m in [
                                        ProviderPreferences.shared.model(for: .builder),
                                        ProviderPreferences.shared.model(for: .coordinator),
                                        "local",
                                        CodingEngine.preferred == .claudeCLI ? "claude-code-cli" : nil,
                                        CodingEngine.preferred == .grokCLI ? "grok-cli" : nil
                                    ].compactMap({ $0 }) where seen.insert(m).inserted {
                                        out.append(m)
                                    }
                                    return out
                                }()
                                ForEach(live, id: \.self) { m in
                                    Button(m) { onSetModel?(task.id, m) }
                                }
                            }
                            Divider()
                            Button("Elimina…", role: .destructive) { onDelete(task.id) }
                        }
                        .onDrag {
                            NSItemProvider(object: task.id.uuidString as NSString)
                        }
                    }

                    if let onAdd {
                        Button(action: onAdd) {
                            HStack {
                                Image(systemName: "plus")
                                Text("Aggiungi Task")
                                    .font(QS.Font.ui(12))
                            }
                            .foregroundStyle(QS.Color.outline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                onMove(id, column)
                return true
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(QS.Color.surfaceLow.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous)
                .stroke(
                    column == .done ? QS.Color.agentActive.opacity(0.35) : QS.Color.border,
                    lineWidth: 1
                )
        )
    }
}

struct TaskCardView: View {
    @EnvironmentObject private var taskStore: TaskStore
    let task: AgentTask
    var onSelect: () -> Void
    var onStart: () -> Void
    var onSendOrchestrator: () -> Void
    var onComplete: () -> Void
    var onDelete: () -> Void

    private var isDone: Bool { task.column == .done }
    private var blockedBy: [String] { taskStore.blockingTitles(for: task) }
    private var isBlocked: Bool { !blockedBy.isEmpty && !isDone }
    private var planStepLabel: String? {
        guard let planId = task.planId else { return nil }
        let plan = taskStore.tasks(inPlan: planId)
        guard let idx = plan.firstIndex(where: { $0.id == task.id }) else {
            return "plan \(planId.uuidString.prefix(4))"
        }
        return "piano \(idx + 1)/\(plan.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PriorityChip(priority: task.priority)
                if isBlocked {
                    StatusChip(text: "BLOCKED", color: QS.Color.error)
                }
                Spacer()
                if task.column == .inProgress {
                    StatusChip(text: "RUN", color: QS.Color.agentActive)
                } else if isDone {
                    StatusChip(text: "DONE", color: QS.Color.agentActive)
                }
            }

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(QS.Font.ui(13, weight: .medium))
                        .foregroundStyle(isDone ? QS.Color.onSurfaceVariant : QS.Color.onSurface)
                        .strikethrough(isDone, color: QS.Color.outline)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle = task.subtitle {
                        Text(subtitle)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .lineLimit(3)
                    }
                    if isDone {
                        let files = task.changedFiles
                        Text(files.isEmpty
                             ? "DONE · tap per dettaglio (file/evidence)"
                             : "DONE · \(files.count) file · tap per elenco")
                            .font(QS.Font.mono(9))
                            .foregroundStyle(QS.Color.agentActive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !task.evidence.isEmpty || task.source != .manual || task.planId != nil {
                HStack(spacing: 4) {
                    Text(task.source.shortLabel.uppercased())
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primarySolid)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let planStepLabel {
                        Text(planStepLabel)
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(QS.Color.surfaceHighest)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if let first = task.evidence.first {
                        Text(first)
                            .font(QS.Font.ui(10))
                            .foregroundStyle(QS.Color.outline)
                            .lineLimit(1)
                    }
                }
            }

            if isBlocked {
                Text("Attende: \(blockedBy.joined(separator: " · "))")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.error)
                    .lineLimit(2)
            }

            if let progress = task.progress, !isDone {
                // Task column progress (board) — distinct from agent LLM step bar
                VStack(alignment: .leading, spacing: 2) {
                    Text("task \(Int(progress * 100))%")
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.outline)
                    ActivityGauge(progress: progress, tint: QS.Color.primarySolid)
                }
            }
            // Live agent hint if any session is on this task
            // (resolved by parent via agents store is heavier; show generic cue)
            if task.column == .inProgress {
                Text(L("Continua → log sotto · click card per focus"))
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.agentThinking)
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(QS.Color.outline)
                Text(task.assigneeModel.uppercased())
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                Spacer()
                if task.tokensUsed > 0 {
                    Text("\(task.tokensUsed)t · $\(String(format: "%.3f", task.estimatedCostUSD))")
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.primary)
                        .help("Token e stima $ in base a priorità (\(task.priority.rawValue)) e modello")
                }
            }

            // Primary actions — separate Buttons so they are not swallowed by card gestures
            HStack(spacing: 6) {
                if !isDone {
                    Button(action: onComplete) {
                        Label("Completa", systemImage: "checkmark.circle.fill")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(QS.Color.agentActive)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Sposta in COMPLETATE")

                    Button(action: onStart) {
                        Label(
                            TaskBoardStartLabel.title(for: task.column, blocked: isBlocked),
                            systemImage: TaskBoardStartLabel.systemImage(for: task.column, blocked: isBlocked)
                        )
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(isBlocked ? QS.Color.outline : QS.Color.primarySolid)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBlocked)
                    .help(isBlocked
                          ? "Completa prima: \(blockedBy.joined(separator: ", "))"
                          : TaskBoardStartLabel.help(for: task.column))
                }

                Button(action: onSendOrchestrator) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(QS.Color.primary)
                        .padding(6)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Apri ⌘K con brief della task (resti su Tasks)")

                Spacer(minLength: 0)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.error)
                        .padding(6)
                        .background(QS.Color.error.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Elimina task")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous)
                .stroke(task.isSelected ? QS.Color.primarySolid.opacity(0.8) : QS.Color.border, lineWidth: 1)
        )
        .opacity(isDone ? 0.9 : 1)
    }
}

/// Bottom panel for completed / idle tasks: files changed + Accept/Reject + evidence.
struct TaskArchivePanel: View {
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    let task: AgentTask
    @State private var expandedDiff: String?

    private var reviewFiles: [String] {
        let fromTask = task.changedFiles
        if !fromTask.isEmpty { return fromTask }
        // Fallback: current dirty tree when task is in review
        if task.column == .review || task.column == .inProgress {
            return Array(git.status.changes.prefix(16).map(\.path))
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QS.Color.primarySolid)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dettaglio task")
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(task.title)
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                }
                Spacer()
                if task.column == .review {
                    Button {
                        orchestrator.applyReviewFeedback()
                    } label: {
                        Label("Applica feedback", systemImage: "arrow.uturn.forward")
                            .font(QS.Font.ui(10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Invia i ritocchi della chat allo stesso Claude/PTY")
                }
                StatusChip(text: task.column.rawValue, color: task.column.accent)
                if task.tokensUsed > 0 {
                    Text("\(task.tokensUsed) tok · $\(String(format: "%.4f", task.estimatedCostUSD))")
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.primary)
                }
                if let ws = task.workspacePath {
                    Text((ws as NSString).lastPathComponent)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().overlay(QS.Color.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let files = reviewFiles
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("FILE CAMBIATI (\(files.count))")
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                            Spacer()
                            if !files.isEmpty, task.column == .review || task.column == .inProgress {
                                Button("Accept all") {
                                    ensureGitPath()
                                    for f in files { git.stage(path: f) }
                                    taskStore.appendEvidence(task.id, "accept-all:\(files.count)")
                                }
                                .font(QS.Font.ui(10, weight: .semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(QS.Color.agentActive)
                                Button("Reject all") {
                                    ensureGitPath()
                                    for f in files { git.discard(path: f) }
                                    taskStore.appendEvidence(task.id, "reject-all:\(files.count)")
                                }
                                .font(QS.Font.ui(10, weight: .semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(QS.Color.error)
                            }
                        }
                        if files.isEmpty {
                            Text(task.wasAutoCompletedWithoutWork
                                 ? "Nessun file: questa card è stata segnata DONE in automatico (dipendenza / goal-auto-done), senza apply_patch su di lei."
                                 : "Nessun file in evidence. Task vecchie (prima del tracking) o solo verifica/lettura senza scrittura.")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.outline)
                        } else {
                            ForEach(files, id: \.self) { f in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc")
                                            .font(.system(size: 10))
                                            .foregroundStyle(QS.Color.agentActive)
                                        Text(f)
                                            .font(QS.Font.codeSM)
                                            .foregroundStyle(QS.Color.onSurface)
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Diff") {
                                            ensureGitPath()
                                            git.loadDiff(path: f, staged: false)
                                            expandedDiff = f
                                        }
                                        .font(QS.Font.ui(10))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(QS.Color.primary)
                                        Button("Accept") {
                                            ensureGitPath()
                                            git.stage(path: f)
                                            taskStore.appendEvidence(task.id, "accept:\(f)")
                                        }
                                        .font(QS.Font.ui(10, weight: .semibold))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(QS.Color.agentActive)
                                        .help("git add — tiene la modifica")
                                        Button("Reject") {
                                            ensureGitPath()
                                            git.discard(path: f)
                                            taskStore.appendEvidence(task.id, "reject:\(f)")
                                        }
                                        .font(QS.Font.ui(10, weight: .semibold))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(QS.Color.error)
                                        .help("Scarta modifica working tree")
                                    }
                                    if expandedDiff == f, git.selectedDiffPath == f {
                                        Text(git.selectedDiffText.isEmpty ? "…" : String(git.selectedDiffText.prefix(2_400)))
                                            .font(QS.Font.mono(9))
                                            .foregroundStyle(QS.Color.outline)
                                            .textSelection(.enabled)
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(QS.Color.backgroundDeep)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }

                    if !task.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EVIDENCE / LOG")
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                            ForEach(Array(task.evidence.suffix(12).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(QS.Font.mono(10))
                                    .foregroundStyle(QS.Color.outline)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(QS.Color.border, lineWidth: 1)
        )
        .onAppear { ensureGitPath() }
    }

    private func ensureGitPath() {
        if let ws = task.workspacePath {
            git.setPath(ws)
        }
    }
}
