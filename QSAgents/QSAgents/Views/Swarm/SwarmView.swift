import SwiftUI

/// Multi-agent mission canvas: plan-first (coord+scout) → human gate → builders.
struct SwarmView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @ObservedObject private var prefs = ProviderPreferences.shared
    @State private var missionDraft: String = ""
    @State private var showHowTo: Bool = true
    /// Collapsed by default — open only when needed (header «Modelli»).
    @State private var showModelRouting: Bool = false
    @State private var answerDrafts: [UUID: String] = [:]
    /// Agent tool console (bottom). Toggle like the shell sidebars.
    @State private var showAgentConsole: Bool = true
    @State private var consolePulse: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                swarmSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .leading, help: "Mostra sidebar Swarm (⌘B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }

            ZStack {
                QS.Color.backgroundDeep.ignoresSafeArea()
                DotGridBackground()

                VStack(alignment: .leading, spacing: 0) {
                    header
                    if showModelRouting {
                        modelRoutingBar
                    }
                    if showHowTo && agents.sessions.isEmpty {
                        howToBanner
                    }
                    if agents.mission != nil {
                        missionPhaseBanner
                    }
                    // Main: canvas + multi-agent terminal dock (logs = what each agent does)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            canvas
                            liveActivityPanel
                                .frame(width: 260)
                        }
                        .frame(maxHeight: .infinity)

                        if showAgentConsole {
                            AgentTerminalDock(
                                sessions: agents.sessions,
                                selectedID: $agents.selectedID,
                                pulse: consolePulse,
                                onStop: { id in agents.stop(id) },
                                onClose: { withAnimation { showAgentConsole = false } }
                            )
                            .frame(minHeight: 280, idealHeight: 360, maxHeight: 560)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .id("agent-console")
                        } else {
                            HStack {
                                Text("Terminal agent chiuso — i log tool non sono i PTY di «Terminali».")
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(QS.Color.outline)
                                Spacer()
                                Button {
                                    withAnimation { showAgentConsole = true }
                                    if agents.selectedID == nil {
                                        agents.selectedID = agents.sessions.first?.id
                                    }
                                } label: {
                                    Label("Apri terminal agent", systemImage: "terminal.fill")
                                        .font(QS.Font.ui(11, weight: .semibold))
                                        .foregroundStyle(QS.Color.primarySolid)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(QS.Color.surfaceContainer.opacity(0.8))
                        }
                    }
                    commandBar
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showLeftSidebar)
        .onChange(of: agents.sessions.map(\.status)) { _, _ in
            // Auto-focus a live agent so the console isn't empty
            if agents.selectedID == nil,
               let live = agents.sessions.first(where: { $0.status == .thinking || $0.status == .active }) {
                focusAgentLog(live.id)
            }
        }
    }

    /// Select agent + ensure console is visible (used by canvas / sidebar / log taps).
    private func focusAgentLog(_ id: UUID) {
        agents.selectedID = id
        withAnimation(.easeInOut(duration: 0.15)) {
            showAgentConsole = true
        }
        consolePulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            consolePulse = false
        }
    }

    // MARK: - Sidebar (Swarm-specific — no legacy "Logs → Terminali" trap)

    private var swarmSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QS SWARM")
                    .font(QS.Font.ui(12, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                Text("Missioni multi-agent")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Clear destinations (labels = where you go)
            VStack(spacing: 2) {
                navRow("Swarm (qui)", icon: "point.3.connected.trianglepath.dotted", selected: true) {}
                navRow("Terminali PTY", icon: "terminal", selected: false) {
                    state.navigate(to: .dashboard)
                }
                navRow("QS Tasks", icon: "checklist", selected: false) {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .tasks
                    state.showIntegrations = false
                }
                navRow("Chat orchestratore", icon: "bubble.left.and.bubble.right", selected: false) {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .chat
                    state.showIntegrations = false
                }
                navRow("Workspace file", icon: "folder", selected: false) {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .workspace
                    state.showIntegrations = false
                }
            }
            .padding(.horizontal, 8)

            Divider().overlay(QS.Color.border).padding(.vertical, 10)

            // Live agents = the real "Active Agents" list (stays on Swarm)
            HStack {
                Text("AGENT LIVE")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
                Text("\(agents.sessions.count)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.primary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            ScrollView {
                if agents.sessions.isEmpty {
                    Text("Nessun agent. Lancia una missione sotto.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(agents.sessions) { session in
                            agentSidebarRow(session)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 8)

            if !agents.sessions.isEmpty {
                VStack(spacing: 6) {
                    Button {
                        agents.stopAll()
                    } label: {
                        Label("Stop tutti", systemImage: "stop.fill")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.error)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(QS.Color.error.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        agents.removeAll()
                    } label: {
                        Label("Elimina tutti", systemImage: "trash")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Ferma i loop e rimuove tutti gli agent dal canvas")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Divider().overlay(QS.Color.border)
            Button {
                withAnimation { showHowTo.toggle() }
            } label: {
                Label(showHowTo ? "Nascondi guida" : "Come usare Swarm", systemImage: "questionmark.circle")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: QS.Spacing.sidebarWidth)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private func navRow(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SidebarNavRow(title: title, icon: icon, selected: selected, action: action)
    }

    private func agentSidebarRow(_ session: AgentSession) -> some View {
        HStack(spacing: 4) {
            Button {
                focusAgentLog(session.id)
            } label: {
                HStack(spacing: 8) {
                    StatusLED(status: session.status, size: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.name)
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                            .lineLimit(1)
                        Text(session.status.label + " · " + session.role.displayName)
                            .font(QS.Font.mono(9))
                            .foregroundStyle(QS.Color.outline)
                    }
                    Spacer(minLength: 0)
                    // Explicit log affordance
                    Text("\(session.lines.count) log")
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.primarySolid)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(Capsule())
                    if session.tokenUsage > 0 {
                        Text("\(session.tokenUsage)t")
                            .font(QS.Font.mono(9))
                            .foregroundStyle(QS.Color.outline)
                    }
                }
                .padding(8)
                .background(
                    agents.selectedID == session.id && showAgentConsole
                        ? QS.Color.primarySolid.opacity(0.14)
                        : QS.Color.surfaceContainer.opacity(0.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Apri console log di \(session.name)")

            // Always-visible controls (not buried only in context menu)
            if session.status == .active || session.status == .thinking {
                Button {
                    agents.stop(session.id)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QS.Color.error)
                        .frame(width: 28, height: 28)
                        .background(QS.Color.error.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Stop loop LLM")
            }

            Button {
                agents.remove(session.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .frame(width: 28, height: 28)
                    .background(QS.Color.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Elimina agent dal canvas")
        }
        .contextMenu {
            Button("Apri log") { focusAgentLog(session.id) }
            Button("Stop") { agents.stop(session.id) }
            Button("Elimina", role: .destructive) { agents.remove(session.id) }
            Button("Apri Terminali (PTY)") {
                state.navigate(to: .dashboard)
            }
        }
    }

    // MARK: - Header / how-to

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("QS Swarm")
                        .font(QS.Font.ui(22, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(workspaces.current.map { "Workspace: \($0.name)" } ?? "Apri un workspace (menu in alto) prima di lanciare una missione.")
                        .font(QS.Font.ui(12))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                Spacer()
                SidebarToggleIcon(
                    systemName: "terminal.fill",
                    isOpen: showAgentConsole,
                    help: "Mostra/nascondi terminal agent (log tool)"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAgentConsole.toggle()
                        if showAgentConsole, agents.selectedID == nil {
                            agents.selectedID = agents.sessions.first?.id
                        }
                    }
                }
                if !showModelRouting {
                    GhostButton(title: "Modelli", icon: "cpu") {
                        withAnimation { showModelRouting = true }
                    }
                }
                if !agents.sessions.isEmpty {
                    GhostButton(title: "Stop tutti", icon: "stop.fill") {
                        agents.stopAll()
                    }
                    GhostButton(title: "Elimina tutti", icon: "trash") {
                        agents.removeAll()
                    }
                }
                PrimaryButton(title: "Nuova missione", icon: "play.fill", compact: true) {
                    if missionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        missionDraft = "Ispeziona repo e proponi piano"
                    }
                    submitCommand()
                }
                .help("Parte sul testo nel campo sotto (o sul default «Ispeziona repo…»). Workspace = quello aperto. Fase PLAN (scout+coord), poi builder.")
            }
            Text("Flusso: PLAN → conferma → BUILDER. Goal = testo nel campo comando (vuoto → ispezione repo). Workspace corrente. Orchestratore: \(prefs.label(for: .coordinator))")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.outline)
        }
        .padding(20)
    }

    // MARK: - Model routing (coordinator + roles)

    private var modelRoutingBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(QS.Color.primarySolid)
                Text("Modelli missione")
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text("(salva e si applica agli agent che avvii)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
                Button {
                    withAnimation { showModelRouting = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }

            // Coordinator / default (from Home)
            HStack(spacing: 12) {
                Text("Default (Home)")
                    .font(QS.Font.ui(11, weight: .medium))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .frame(width: 100, alignment: .leading)
                providerPicker(selection: Binding(
                    get: { prefs.defaultProviderRaw },
                    set: { raw in
                        if let k = LLMProviderKind(rawValue: raw) {
                            prefs.setDefaultProvider(k)
                        }
                    }
                ))
                SearchableModelPicker(
                    provider: prefs.defaultProvider ?? .spaceXAI,
                    selection: Binding(
                        get: { prefs.model(for: .coordinator) },
                        set: { prefs.setModel($0, for: .coordinator) }
                    ),
                    width: 200
                )
                Button("Applica a tutti i ruoli") {
                    guard let p = prefs.defaultProvider else { return }
                    prefs.applyToAllSwarmRoles(provider: p, model: prefs.model(for: .coordinator))
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(11, weight: .semibold))
                .foregroundStyle(QS.Color.primarySolid)
                .help("Coord + scout + builder + reviewer usano lo stesso modello")
            }

            // Per-role rows
            ForEach([AgentRole.coordinator, .scout, .builder, .reviewer], id: \.rawValue) { role in
                roleModelRow(role)
            }

            Text("Gli agent già avviati restano sul modello con cui sono partiti; le nuove missioni usano questa routing.")
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
        }
        .padding(12)
        .background(QS.Color.surfaceContainer.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QS.Color.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func roleModelRow(_ role: AgentRole) -> some View {
        let hasKey: Bool = {
            if let p = prefs.provider(for: role) {
                return LLMClient.shared.hasKey(p)
            }
            return false
        }()
        return HStack(spacing: 12) {
            Text(role.rawValue)
                .font(QS.Font.mono(11))
                .foregroundStyle(QS.Color.onSurface)
                .frame(width: 100, alignment: .leading)
            providerPicker(selection: Binding(
                get: {
                    prefs.providerByRole[role.rawValue]
                        ?? prefs.defaultProviderRaw
                },
                set: { raw in
                    if let k = LLMProviderKind(rawValue: raw) {
                        prefs.setProvider(k, for: role)
                    }
                }
            ))
            SearchableModelPicker(
                provider: prefs.provider(for: role) ?? prefs.defaultProvider ?? .spaceXAI,
                selection: Binding(
                    get: { prefs.model(for: role) },
                    set: { prefs.setModel($0, for: role) }
                ),
                width: 200
            )
            Circle()
                .fill(hasKey ? QS.Color.agentActive : QS.Color.error)
                .frame(width: 7, height: 7)
                .help(hasKey ? "API key OK" : "Nessuna API key per questo provider — Integrazioni")
            Text(prefs.label(for: role))
                .font(QS.Font.mono(9))
                .foregroundStyle(QS.Color.outline)
                .lineLimit(1)
        }
    }

    private func providerPicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(LLMProviderKind.allCases) { p in
                Text(p.displayName + (LLMClient.shared.hasKey(p) ? "" : " (no key)"))
                    .tag(p.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 160)
    }



    // MARK: - Phase banner + human gate

    private var missionPhaseBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let m = agents.mission {
                HStack(spacing: 10) {
                    phaseChip(m.phase)
                    Text(m.goal)
                        .font(QS.Font.ui(12, weight: .medium))
                        .foregroundStyle(QS.Color.onSurface)
                        .lineLimit(2)
                    Spacer()
                    let taskN = m.taskIds.count
                    Button {
                        state.mainTab = .orchestrator
                        state.orchestratorMode = .tasks
                    } label: {
                        Label("\(taskN) task board", systemImage: "checklist")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.primarySolid)
                    }
                    .buttonStyle(.plain)
                }

                if let summary = m.coordinatorSummary, !summary.isEmpty {
                    Text(summary)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .lineLimit(4)
                }

                // Coordinator questions
                ForEach(m.openQuestions) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.bubble.fill")
                                .foregroundStyle(QS.Color.agentThinking)
                            Text(q.text)
                                .font(QS.Font.ui(12, weight: .medium))
                                .foregroundStyle(QS.Color.onSurface)
                        }
                        HStack(spacing: 8) {
                            TextField("La tua risposta…", text: Binding(
                                get: { answerDrafts[q.id] ?? "" },
                                set: { answerDrafts[q.id] = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(QS.Font.ui(12))
                            .padding(8)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button("Invia") {
                                let a = (answerDrafts[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !a.isEmpty else { return }
                                agents.answerQuestion(id: q.id, answer: a)
                                answerDrafts[q.id] = nil
                            }
                            .buttonStyle(.plain)
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(QS.Color.primarySolid)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(10)
                    .background(QS.Color.agentThinking.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if m.phase == .awaitingUser || m.phase == .planning {
                    HStack(spacing: 10) {
                        if m.phase == .awaitingUser || m.taskIds.count > 0 {
                            Button {
                                // Sempre via orchestratore — così resta in controllo dei sub-agent.
                                orchestrator.approveMissionBuilders(builderCount: 2)
                            } label: {
                                Label(
                                    m.taskIds.isEmpty
                                        ? "Orchestratore → avvia builder"
                                        : "Orchestratore → \(m.taskIds.count) builder",
                                    systemImage: "play.fill"
                                )
                                .font(QS.Font.ui(12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(QS.Color.agentActive)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("L'orchestratore approva il piano e lancia i builder come suoi sub-agent")
                        }
                        Button {
                            state.mainTab = .orchestrator
                            state.orchestratorMode = .tasks
                        } label: {
                            Label("Apri QS Tasks", systemImage: "arrow.right")
                                .font(QS.Font.ui(11, weight: .medium))
                                .foregroundStyle(QS.Color.onSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(QS.Color.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(phaseHint(m.phase))
                            .font(QS.Font.ui(10))
                            .foregroundStyle(QS.Color.outline)
                    }
                } else if m.phase == .executing {
                    HStack {
                        Text("Auto-pipeline: coord assegna le task ai builder · log sotto = terminal di ogni agent.")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.agentActive)
                        Spacer()
                        Toggle("Auto-run", isOn: Binding(
                            get: { agents.mission?.autoRun ?? true },
                            set: { agents.setMissionAutoRun($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(QS.Font.ui(10))
                    }
                } else if m.phase == .done {
                    Text("Missione completata — task board e memoria aggiornate.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.agentActive)
                }

                if m.phase == .awaitingUser || m.phase == .planning {
                    Toggle(
                        "Auto-run (dopo il piano avvia i builder e concatena le task da solo)",
                        isOn: Binding(
                            get: { agents.mission?.autoRun ?? true },
                            set: { agents.setMissionAutoRun($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                }
            }
        }
        .padding(14)
        .background(QS.Color.surfaceContainer.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QS.Color.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func phaseChip(_ phase: MissionPhase) -> some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .planning: return ("PLAN", QS.Color.agentThinking)
            case .awaitingUser: return ("TUA CONFERMA", QS.Color.primarySolid)
            case .executing: return ("BUILD", QS.Color.agentActive)
            case .done: return ("DONE", QS.Color.outline)
            }
        }()
        return Text(label)
            .font(QS.Font.labelXS)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(Capsule())
    }

    private func phaseHint(_ phase: MissionPhase) -> String {
        switch phase {
        case .planning: return "Coord sta creando il piano/task…"
        case .awaitingUser: return "Rispondi alle domande o avvia i builder"
        case .executing: return "Esecuzione in corso"
        case .done: return "Completata"
        }
    }

    // MARK: - Live activity + E4 agent↔task DAG

    private var liveActivityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LIVE FEED")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
                Text(LLMClient.shared.configuredSummary())
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(QS.Color.border)

            // E4: DAG agent ↔ task (not just bubbles)
            swarmDagPanel

            Divider().overlay(QS.Color.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let activity = agents.mission?.activity, !activity.isEmpty {
                        ForEach(activity.prefix(80)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(line.agentName)
                                        .font(QS.Font.ui(10, weight: .semibold))
                                        .foregroundStyle(QS.Color.primarySolid)
                                    Text(line.role)
                                        .font(QS.Font.mono(9))
                                        .foregroundStyle(QS.Color.outline)
                                }
                                Text(line.text)
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(line.level.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12)
                        }
                    } else {
                        Text("Qui vedi in tempo reale cosa fanno coord/scout/builder — non solo bolle sul canvas.")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                            .padding(12)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(QS.Color.surfaceSidebar.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var swarmDagPanel: some View {
        let edges = agents.liveEdges()
        let free = agents.unassignedMissionTasks()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DAG · agent ↔ task")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
                if let plan = agents.mission?.planId {
                    Text("plan \(plan.uuidString.prefix(6))")
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.primarySolid)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if edges.isEmpty && free.isEmpty {
                Text("Nessun link ancora — le create_task del coord compaiono qui.")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(edges) { e in
                            Button {
                                focusAgentLog(e.agentId)
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(statusColor(e.status))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(e.agentName) · \(e.role)")
                                            .font(QS.Font.ui(10, weight: .semibold))
                                            .foregroundStyle(QS.Color.onSurface)
                                        if let title = e.taskTitle {
                                            Text("→ \(title)")
                                                .font(QS.Font.mono(9))
                                                .foregroundStyle(QS.Color.primarySolid)
                                                .lineLimit(2)
                                            if let col = e.taskColumn {
                                                Text(col.rawValue)
                                                    .font(QS.Font.labelXS)
                                                    .foregroundStyle(QS.Color.outline)
                                            }
                                        } else {
                                            Text("→ (nessuna task legata)")
                                                .font(QS.Font.mono(9))
                                                .foregroundStyle(QS.Color.outline)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(free) { t in
                            Button {
                                state.mainTab = .orchestrator
                                state.orchestratorMode = .tasks
                                taskStore.select(t.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checklist")
                                        .font(.system(size: 9))
                                        .foregroundStyle(QS.Color.outline)
                                    Text("board: \(t.title)")
                                        .font(QS.Font.mono(9))
                                        .foregroundStyle(QS.Color.onSurfaceVariant)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .padding(.bottom, 6)
            }
        }
    }

    private func statusColor(_ s: AgentStatus) -> Color {
        switch s {
        case .thinking: return QS.Color.agentThinking
        case .active: return QS.Color.agentActive
        case .error: return QS.Color.agentError
        case .idle: return QS.Color.outline
        }
    }

    private var howToBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(QS.Color.agentThinking)
                Text("Swarm stile Lovable/Bolt (non chat, non solo bolle)")
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
                Button {
                    withAnimation { showHowTo = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                howStep("1", "Apri un **workspace** (gioco / repo).")
                howStep("2", "Goal es. «crea tutte le task per migliorare il menu iniziale» → ▶.")
                howStep("3", "**PLAN**: coord+scout. Il coordinatore crea le card su **QS Tasks** e può farti domande.")
                howStep("4", "**Orchestratore → avvia builder**: lancia i sub-agent e resta in controllo. Feed LIVE a destra.")
            }
            Text("Il lavoro degli agent si legge nella **console in basso** (tool stream), non in Terminali PTY. Barra % = step del loop LLM. Clic su un agent per il log completo.")
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
        }
        .padding(14)
        .background(QS.Color.primarySolid.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QS.Color.primarySolid.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func howStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(QS.Font.labelXS)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(QS.Color.primarySolid)
                .clipShape(Circle())
            Text(LocalizedStringKey(text))
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if agents.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(QS.Color.outline)
                        Text("Nessuna missione attiva")
                            .font(QS.Font.headline)
                            .foregroundStyle(QS.Color.onSurface)
                        Text("Scrivi un goal e premi play — prima piano/task, poi builder dopo la tua conferma.")
                            .font(QS.Font.body)
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(Array(agents.sessions.enumerated()), id: \.element.id) { index, session in
                        RealSwarmNodeCard(
                            session: session,
                            selected: agents.selectedID == session.id && showAgentConsole,
                            onOpenLog: { focusAgentLog(session.id) }
                        )
                            .position(position(for: index, total: agents.sessions.count, in: geo.size))
                            .onTapGesture { focusAgentLog(session.id) }
                            .contextMenu {
                                Button("Apri log") { focusAgentLog(session.id) }
                                Button("Stop") { agents.stop(session.id) }
                                Button("Elimina", role: .destructive) { agents.remove(session.id) }
                                Button("Vai ai Terminali") { state.navigate(to: .dashboard) }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func position(for index: Int, total: Int, in size: CGSize) -> CGPoint {
        let session = agents.sessions[index]
        if session.role == .coordinator {
            return CGPoint(x: size.width * 0.5, y: size.height * 0.22)
        }
        let workers = agents.sessions.enumerated().filter { $0.element.role != .coordinator }
        let wi = workers.firstIndex(where: { $0.offset == index }) ?? index
        let n = max(workers.count, 1)
        let t = Double(wi) / Double(max(n - 1, 1))
        let x = 0.2 + 0.6 * t
        let y = 0.55 + 0.08 * sin(t * .pi)
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    // MARK: - Command bar

    private var commandBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("@ all")
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    TextField(
                        agents.sessions.isEmpty
                            ? "Goal missione… es. «analizza auth e proponi fix»"
                            : "@all status · @builder-1 focus su login · missione nuovo goal…",
                        text: $missionDraft
                    )
                    .textFieldStyle(.plain)
                    .font(QS.Font.body)
                    .foregroundStyle(QS.Color.onSurface)
                    .onSubmit { submitCommand() }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(QS.Color.surfaceContainer)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(QS.Color.border, lineWidth: 1))

                Button {
                    submitCommand()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(QS.Color.primarySolid)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(agents.sessions.isEmpty ? "Avvia missione" : "Invia messaggio / nuova missione")
            }
            .padding(.horizontal, 40)

            Text("Agent attivi: \(agents.sessions.filter { $0.status == .active || $0.status == .thinking }.count) · totali \(agents.sessions.count) · coord \(prefs.label(for: .coordinator))")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .padding(.bottom, 14)
        }
    }

    private func submitCommand() {
        let g = missionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        if g.hasPrefix("@") {
            agents.messageAgents(g)
        } else if agents.sessions.isEmpty {
            agents.startMission(goal: g, builders: 2)
        } else if g.lowercased().hasPrefix("missione ") || g.lowercased().hasPrefix("mission ") {
            agents.startMission(goal: g, builders: 2)
        } else if agents.sessions.contains(where: { $0.status == .active || $0.status == .thinking }) {
            agents.messageAgents("@all \(g)")
        } else {
            agents.startMission(goal: g, builders: 2)
        }
        missionDraft = ""
        state.swarmRunning = true
    }
}

// MARK: - Node card

struct RealSwarmNodeCard: View {
    @EnvironmentObject private var taskStore: TaskStore
    let session: AgentSession
    var selected: Bool = false
    var onOpenLog: (() -> Void)? = nil

    private var linkedTask: AgentTask? {
        session.taskId.flatMap { taskStore.task(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if session.role == .coordinator {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                        .foregroundStyle(QS.Color.primary)
                }
                Text(session.name)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(session.role == .coordinator ? QS.Color.primary : QS.Color.onSurfaceVariant)
                Spacer(minLength: 8)
                StatusLED(status: session.status, size: 7)
            }
            Text(session.lastGoal ?? session.role.displayName)
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurface)
                .lineLimit(2)
                .frame(maxWidth: 180, alignment: .leading)

            // E4: show linked board task on the node
            if let t = linkedTask {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 8))
                    Text(t.title)
                        .lineLimit(1)
                }
                .font(QS.Font.mono(9))
                .foregroundStyle(QS.Color.primarySolid)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(QS.Color.primarySolid.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if session.progress > 0 || session.status == .thinking || session.status == .active {
                AgentLoopProgressBar(progress: session.progress, status: session.status)
                    .padding(.top, 2)
            }
            // Last log line preview
            if let last = session.lines.last {
                Text(last.text)
                    .font(QS.Font.mono(9))
                    .foregroundStyle(last.level.color.opacity(0.9))
                    .lineLimit(2)
            }
            HStack {
                Text(session.modelDisplayLabel)
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.primarySolid)
                    .lineLimit(1)
                Spacer()
                Button {
                    onOpenLog?()
                } label: {
                    Label("\(session.lines.count) log", systemImage: "text.alignleft")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primarySolid)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(QS.Color.primarySolid.opacity(0.14))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Apri console tool stream")
                if session.tokenUsage > 0 {
                    Text("\(session.tokenUsage) tok")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
            }
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(QS.Color.surfaceContainer.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    selected ? QS.Color.primarySolid : QS.Color.border,
                    lineWidth: selected ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.25), radius: selected ? 12 : 6, y: 4)
    }
}
