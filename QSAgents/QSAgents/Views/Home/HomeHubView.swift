import SwiftUI

/// Landing dashboard: quick jumps + orchestrator CTA + token/cost meter.
struct HomeHubView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var probe: SystemProbe
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var knowledge: KnowledgeStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @ObservedObject private var prefs = ProviderPreferences.shared

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                statusStrip
                modelAndCostRow
                sectionGrid
                recentRow
            }
            .padding(24)
        }
        .background(QS.Color.backgroundDeep)
        .onAppear {
            if let path = workspaces.current?.path {
                git.setPath(path)
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("QS Agents")
                    .font(QS.Font.ui(28, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(L("Command center multi-agent · terminali reali · git · knowledge"))
                    .font(QS.Font.ui(13))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                Text(workspaces.current.map { "Workspace: \($0.name)" } ?? L("Nessun workspace — aprine uno per iniziare"))
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.outline)

                HStack(spacing: 12) {
                    Button {
                        startOrchestrator()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Inizia Orchestratore")
                                    .font(QS.Font.ui(15, weight: .semibold))
                                Text("⌘K · chat e tools")
                                    .font(QS.Font.labelXS)
                                    .opacity(0.85)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [QS.Color.primarySolid, QS.Color.secondaryContainer],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: QS.Color.primarySolid.opacity(0.35), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)

                    GhostButton(title: "Apri workspace", icon: "folder") {
                        NotificationCenter.default.post(name: .qsOpenWorkspacePicker, object: nil)
                    }

                    GhostButton(title: "Nuovo terminale", icon: "terminal") {
                        let path = workspaces.current?.path ?? NSHomeDirectory()
                        terminals.openTerminal(at: path)
                        state.navigate(to: .dashboard)
                    }
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 12)

            // Quick pulse card
            VStack(alignment: .leading, spacing: 10) {
                Text("LIVE")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                metricLine("CPU", String(format: "%.0f%%", probe.snapshot.cpuPercent))
                metricLine("RAM", String(format: "%.1f GB", probe.snapshot.memoryUsedGB))
                metricLine("PTY", "\(terminals.activeCount)")
                metricLine("Agent", "\(agents.sessions.filter { $0.status == .active || $0.status == .thinking }.count)")
                metricLine("Task", "\(taskStore.count(in: .inProgress)) in corso")
            }
            .padding(16)
            .frame(width: 180, alignment: .leading)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(QS.Color.border, lineWidth: 1)
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(QS.Color.surfaceLow)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(QS.Color.primarySolid.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func metricLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            Spacer()
            Text(v).font(QS.Font.ui(12, weight: .semibold)).foregroundStyle(QS.Color.onSurface)
        }
    }

    // MARK: - Status

    private var statusStrip: some View {
        HStack(spacing: 10) {
            statusPill(git.status.isRepo ? "Git · \(git.status.branch ?? "?")" : "Git · —",
                       color: git.status.isRepo ? QS.Color.agentActive : QS.Color.outline)
            statusPill(LLMClient.shared.preferredProvider() != nil ? prefs.activeModelLabel : "Solo regole locali",
                       color: QS.Color.primary)
            statusPill(knowledge.fileCount > 0 ? "Knowledge · \(knowledge.fileCount) file" : "Knowledge · non indicizzato",
                       color: QS.Color.secondary)
            Spacer()
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(QS.Font.labelXS)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Model + cost

    private var modelAndCostRow: some View {
        HStack(alignment: .top, spacing: 14) {
            // Live model switch
            VStack(alignment: .leading, spacing: 10) {
                Text("Modello orchestratore")
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(L("Cambia al volo — la prossima risposta usa questo provider/modello."))
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)

                let activeProv = orchestrator.selectedProviderKind
                    ?? prefs.defaultProvider
                    ?? LLMProviderKind.spaceXAI
                let modelList = prefs.models(for: activeProv)

                HStack(spacing: 10) {
                    Picker("Provider", selection: Binding(
                        get: { orchestrator.selectedProviderKind?.rawValue ?? prefs.defaultProviderRaw },
                        set: { raw in
                            if let k = LLMProviderKind(rawValue: raw) {
                                orchestrator.setLiveProvider(k)
                                prefs.setDefaultProvider(k)
                            }
                        }
                    )) {
                        ForEach(LLMProviderKind.allCases) { p in
                            Text(p.displayName + (LLMClient.shared.hasKey(p) ? "" : " · no key"))
                                .tag(p.rawValue)
                        }
                    }
                    .frame(maxWidth: 200)

                    SearchableModelPicker(
                        provider: activeProv,
                        selection: Binding(
                            get: { orchestrator.selectedModel ?? prefs.model(for: .coordinator) },
                            set: { m in
                                orchestrator.setLiveModel(m)
                                prefs.setModel(m, for: .coordinator)
                            }
                        ),
                        width: 240
                    )
                }

                Text(orchestrator.configuredAISummary)
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.onSurfaceVariant)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Cost dashboard
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Token & costi")
                        .font(QS.Font.ui(13, weight: .semibold))
                    Spacer()
                    Button("Reset sessione") {
                        prefs.resetSessionUsage()
                    }
                    .buttonStyle(.plain)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                    .help("Azzera sessione, totale e stima $")
                }

                HStack(spacing: 16) {
                    costStat("Sessione", "\(prefs.sessionTokens)", "tok")
                    costStat("Totale", "\(prefs.lastUsageTokens)", "tok")
                    costStat("Stima $", String(format: "%.4f", prefs.estimatedCostUSD), "USD")
                }

                if prefs.knowledgeTokensSaved > 0 {
                    HStack(spacing: 16) {
                        costStat("Knowledge risparmiati", "\(prefs.knowledgeTokensSaved)", "tok")
                        costStat("Risparmio $", String(format: "%.4f", prefs.knowledgeSavedCostUSD), "USD")
                    }
                }

                // Simple meter
                GeometryReader { geo in
                    let maxT = max(prefs.lastUsageTokens, 1)
                    let w = min(1.0, Double(prefs.sessionTokens) / Double(max(maxT, 10_000)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(QS.Color.surfaceHigh).frame(height: 8)
                        Capsule()
                            .fill(QS.Color.primarySolid)
                            .frame(width: max(8, geo.size.width * w), height: 8)
                    }
                }
                .frame(height: 8)

                Text(L("Stima indicativa · non fattura reale. Aggiornato a ogni chiamata LLM."))
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func costStat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(QS.Font.ui(16, weight: .bold)).foregroundStyle(QS.Color.onSurface)
                Text(unit).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            }
        }
    }

    // MARK: - Sections grid

    private var sectionGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vai a")
                .font(QS.Font.ui(14, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)

            LazyVGrid(columns: columns, spacing: 14) {
                sectionCard(
                    title: "Orchestratore",
                    subtitle: "Chat · tools · ⌘K",
                    icon: "sparkles",
                    tint: QS.Color.primarySolid
                ) { startOrchestrator() }

                sectionCard(
                    title: "Terminali",
                    subtitle: "\(terminals.activeCount) PTY live",
                    icon: "terminal",
                    tint: QS.Color.agentActive
                ) {
                    state.navigate(to: .dashboard)
                }

                sectionCard(
                    title: "Tasks",
                    subtitle: "\(taskStore.tasks.count) task",
                    icon: "checklist",
                    tint: QS.Color.agentThinking
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .tasks
                }

                sectionCard(
                    title: "Workspace",
                    subtitle: workspaces.current?.name ?? "Apri cartella",
                    icon: "folder.fill",
                    tint: QS.Color.secondary
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .workspace
                }

                sectionCard(
                    title: "Swarm",
                    subtitle: "\(agents.sessions.count) agent",
                    icon: "point.3.connected.trianglepath.dotted",
                    tint: Color(hex: 0x64D2FF)
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .swarm
                }

                sectionCard(
                    title: "Knowledge",
                    subtitle: knowledge.fileCount > 0 ? "\(knowledge.chunks.count) chunk" : "Indice codice",
                    icon: "point.3.filled.connected.trianglepath.dotted",
                    tint: Color(hex: 0xBF5AF2)
                ) {
                    state.navigate(to: .monitor)
                }

                sectionCard(
                    title: "Git",
                    subtitle: git.status.isRepo ? git.status.summaryLine : "Changelog / commit",
                    icon: "arrow.triangle.branch",
                    tint: Color(hex: 0x30D158)
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .workspace
                }

                sectionCard(
                    title: "Integrazioni",
                    subtitle: "AI · GitHub",
                    icon: "puzzlepiece.extension",
                    tint: QS.Color.primary
                ) {
                    state.openIntegrations()
                }

                sectionCard(
                    title: "Sicurezza",
                    subtitle: "Guardrail · audit",
                    icon: "shield.lefthalf.filled",
                    tint: QS.Color.agentError
                ) {
                    state.openSafety()
                }
            }
        }
    }

    private func sectionCard(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tint)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(QS.Font.ui(13, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(subtitle)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(QS.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Workspace recenti"))
                .font(QS.Font.ui(13, weight: .semibold))
            if workspaces.recent.isEmpty {
                Text(L("Nessuno — usa Apri workspace"))
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspaces.recent.prefix(8)) { ws in
                            Button {
                                workspaces.openRecent(ws.id)
                                if let path = workspaces.current?.path {
                                    git.setPath(path)
                                }
                                state.navigate(to: .orchestrator)
                                state.orchestratorMode = .workspace
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(ws.name)
                                        .lineLimit(1)
                                }
                                .font(QS.Font.ui(12))
                                .foregroundStyle(QS.Color.onSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(QS.Color.surfaceHigh)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func startOrchestrator() {
        state.showIntegrations = false
        state.showSafety = false
        state.mainTab = .orchestrator
        state.orchestratorMode = .chat
        state.openOrchestratorModal()
    }
}
