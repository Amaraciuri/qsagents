import SwiftUI
import AppKit

struct AppShellView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var probe: SystemProbe
    @EnvironmentObject private var safety: SafetyGuardrails

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()
            Divider().overlay(QS.Color.border)
            SafetyPendingBanner()
            LocalRecoveryBanners()

            Group {
                if state.showSafety {
                    SafetySettingsView()
                } else if state.showIntegrations || state.selectedSidebar == .integrations {
                    IntegrationsView()
                } else {
                    switch state.mainTab {
                    case .home:
                        HomeHubView()
                    case .dashboard:
                        RealTerminalsView()
                    case .orchestrator:
                        switch state.orchestratorMode {
                        case .chat: OrchestratorChatView()
                        case .tasks: TasksBoardView()
                        case .swarm: SwarmView()
                        case .workspace: WorkspaceEditorView()
                        }
                    case .monitor:
                        KnowledgeGraphView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // global status
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle().fill(QS.Color.agentActive).frame(width: 7, height: 7)
                    Text(L("SISTEMA ONLINE"))
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                Text("\(terminals.activeCount) \(L("Terminali").uppercased())")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                // Environment / safety badge
                Button {
                    state.openSafety()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: safety.enabled ? "shield.lefthalf.filled" : "shield.slash")
                            .font(.system(size: 9))
                        Text(safety.environment.shortLabel)
                            .font(QS.Font.labelXS)
                    }
                    .foregroundStyle(Color(hex: safety.environment.colorHex))
                }
                .buttonStyle(.plain)
                .help(L("Ambiente e guardrail QS Agents"))

                Text(probe.snapshot.username)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Spacer()
                HStack(spacing: 14) {
                    statusMetric("CPU", String(format: "%.0f%%", probe.snapshot.cpuPercent))
                    statusMetric("MEM", String(format: "%.1fGB", probe.snapshot.memoryUsedGB))
                    statusMetric("TOK", "\(ProviderPreferences.shared.sessionTokens)")
                    statusMetric("$", String(format: "%.3f", ProviderPreferences.shared.sessionCostUSD))
                    statusMetric("LOAD", String(format: "%.2f", probe.snapshot.loadAvg.0))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(QS.Color.surfaceLow)
            .overlay(alignment: .top) {
                Rectangle().fill(QS.Color.border).frame(height: 1)
            }
        }
        .background(QS.Color.backgroundDeep)
        .preferredColorScheme(.dark)
        .orchestratorQuickModal()
    }

    private func statusMetric(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            Text(v).font(QS.Font.labelXS).foregroundStyle(QS.Color.onSurfaceVariant)
        }
    }
}

struct TopBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var notices: AppNotificationCenter

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                Text("QS AGENTS")
                    .font(QS.Font.ui(13, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                    .tracking(0.4)

                // Primary context: switch workspace in one menu (not a dead badge)
                WorkspaceSwitcher(style: .compact)

                if terminals.activeCount > 0 {
                    StatusChip(text: "\(terminals.activeCount) PTY", color: QS.Color.agentActive)
                }
            }

            HStack(spacing: 4) {
                // Primary destinations always visible
                TopTab(
                    title: "Home",
                    selected: !state.showIntegrations && !state.showSafety && state.mainTab == .home
                ) {
                    state.navigate(to: .home)
                }
                TopTab(
                    title: "Terminali",
                    selected: !state.showIntegrations && !state.showSafety && state.mainTab == .dashboard
                ) {
                    state.navigate(to: .dashboard)
                }
                TopTab(
                    title: "Chat",
                    selected: !state.showIntegrations
                        && !state.showSafety
                        && state.mainTab == .orchestrator
                        && state.orchestratorMode == .chat
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .chat
                }
                // Always visible — user request
                TopTab(
                    title: "QS Tasks",
                    selected: !state.showIntegrations
                        && !state.showSafety
                        && state.mainTab == .orchestrator
                        && state.orchestratorMode == .tasks
                ) {
                    state.showIntegrations = false
                    state.showSafety = false
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .tasks
                }
                TopTab(
                    title: "QS Swarm",
                    selected: !state.showIntegrations
                        && !state.showSafety
                        && state.mainTab == .orchestrator
                        && state.orchestratorMode == .swarm
                ) {
                    state.showIntegrations = false
                    state.showSafety = false
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .swarm
                }
                TopTab(
                    title: "Workspace",
                    selected: !state.showIntegrations
                        && !state.showSafety
                        && state.mainTab == .orchestrator
                        && state.orchestratorMode == .workspace
                ) {
                    state.navigate(to: .orchestrator)
                    state.orchestratorMode = .workspace
                }
                TopTab(
                    title: "Knowledge",
                    selected: !state.showIntegrations && !state.showSafety && state.mainTab == .monitor
                ) {
                    state.navigate(to: .monitor)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                // Cursor/VS Code style: toggle side rails
                SidebarToggleIcon(
                    systemName: "sidebar.left",
                    isOpen: state.showLeftSidebar,
                    help: "Mostra/nascondi sidebar sinistra (⌘B)"
                ) {
                    state.toggleLeftSidebar()
                }
                SidebarToggleIcon(
                    systemName: "sidebar.right",
                    isOpen: state.showRightSidebar,
                    help: "Mostra/nascondi pannello destro (⌘⌥B)"
                ) {
                    state.toggleRightSidebar()
                }

                ToolbarIconButton(systemName: "folder.badge.plus") {
                    // Open via notification — WorkspaceStore is env object on root
                    NotificationCenter.default.post(name: .qsOpenWorkspacePicker, object: nil)
                }

                // Global orchestrator — always available
                Button {
                    state.toggleOrchestratorModal()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Orchestratore")
                            .font(QS.Font.ui(11, weight: .semibold))
                        Text("⌘K")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.primary.opacity(0.85))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(QS.Color.primarySolid.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .foregroundStyle(QS.Color.onSurface)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        LinearGradient(
                            colors: [
                                QS.Color.primarySolid.opacity(0.22),
                                QS.Color.secondaryContainer.opacity(0.18)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(QS.Color.primarySolid.opacity(0.45), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Parla con l'Orchestratore QS Agents ovunque (⌘K)")

                QSSearchField(
                    placeholder: searchPlaceholder,
                    text: $state.searchText
                )
                ToolbarIconButton(systemName: "plus.rectangle.on.folder") {
                    terminals.pickDirectoryAndOpen()
                    state.navigate(to: .dashboard)
                }
                ToolbarIconButton(systemName: "terminal") {
                    terminals.openTerminal(at: terminals.selected?.cwd ?? NSHomeDirectory())
                    state.navigate(to: .dashboard)
                }
                ToolbarIconButton(
                    systemName: notices.hasUnread ? "bell.badge.fill" : "bell",
                    badgeCount: notices.unreadCount
                ) {
                    notices.togglePanel()
                }
                // Sheet — NOT .popover: NSPopover+ViewBridge crashes on macOS 15/26 betas (SIGTRAP).
                .sheet(isPresented: $notices.showPanel) {
                    NotificationCenterPanel()
                        .environmentObject(notices)
                        .environmentObject(state)
                        .environmentObject(terminals)
                        .frame(width: 380, height: 480)
                }
                .help(notices.hasUnread
                      ? "\(notices.unreadCount) notifiche non lette"
                      : "Centro notifiche")

                ToolbarIconButton(systemName: "shield.lefthalf.filled") {
                    state.openSafety()
                }
                ToolbarIconButton(systemName: "gearshape") {
                    state.openIntegrations()
                }
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [QS.Color.primarySolid, QS.Color.secondaryContainer],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text("QS")
                            .font(QS.Font.ui(9, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .padding(.horizontal, QS.Spacing.windowPadding)
        .frame(height: 44)
        .background(QS.Color.surfaceSidebar)
    }

    private var searchPlaceholder: String {
        switch state.mainTab {
        case .home: return "Cerca sezioni…"
        case .dashboard: return "Cerca progetto / path…"
        case .orchestrator:
            switch state.orchestratorMode {
            case .chat: return "Filtra chat…"
            case .tasks: return "Cerca task..."
            case .workspace: return "Cerca workspace..."
            case .swarm: return "Cerca agente..."
            }
        case .monitor: return "Cerca nella base di conoscenza..."
        }
    }
}

private struct TopTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(QS.Font.ui(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? QS.Color.primary : QS.Color.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle()
                            .fill(QS.Color.primarySolid)
                            .frame(height: 2)
                            .offset(y: 8)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Standard left sidebar (orchestrator / monitor style)

struct StandardSidebar: View {
    @EnvironmentObject private var state: AppState
    var showNewWorkspace: Bool = true
    var extraTop: AnyView? = nil
    var footerStatus: String = "Status"

    /// Labels match destination (no more “Logs → Terminali” surprise).
    private var navItems: [(title: String, icon: String, selected: Bool, action: () -> Void)] {
        [
            (
                L("Workspace file"),
                "folder.fill",
                state.mainTab == .orchestrator && state.orchestratorMode == .workspace && !state.showIntegrations,
                {
                    state.selectedSidebar = .workspaces
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .workspace
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                L("Chat orchestratore"),
                "bubble.left.and.bubble.right",
                state.mainTab == .orchestrator && state.orchestratorMode == .chat && !state.showIntegrations,
                {
                    state.selectedSidebar = .activeAgents
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .chat
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                "QS Tasks",
                "checklist",
                state.mainTab == .orchestrator && state.orchestratorMode == .tasks && !state.showIntegrations,
                {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .tasks
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                "QS Swarm",
                "point.3.connected.trianglepath.dotted",
                state.mainTab == .orchestrator && state.orchestratorMode == .swarm && !state.showIntegrations,
                {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .swarm
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                L("Terminali PTY"),
                "terminal",
                state.mainTab == .dashboard && !state.showIntegrations,
                {
                    state.selectedSidebar = .logs
                    state.mainTab = .dashboard
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                "Knowledge",
                "circle.hexagongrid",
                state.mainTab == .monitor && !state.showIntegrations,
                {
                    state.mainTab = .monitor
                    state.showIntegrations = false
                    state.showSafety = false
                }
            ),
            (
                L("Integrazioni"),
                "gearshape",
                state.showIntegrations,
                {
                    state.selectedSidebar = .settings
                    state.openIntegrations()
                }
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QS AGENTS")
                        .font(QS.Font.ui(12, weight: .bold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(L("Navigazione"))
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if let extraTop {
                extraTop
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            VStack(spacing: 2) {
                ForEach(Array(navItems.enumerated()), id: \.offset) { _, item in
                    SidebarNavRow(
                        title: item.title,
                        icon: item.icon,
                        selected: item.selected,
                        action: item.action
                    )
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            if showNewWorkspace {
                PrimaryButton(title: "New Workspace", icon: "plus") {
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .workspace
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Divider().overlay(QS.Color.border)

            VStack(spacing: 2) {
                SidebarNavRow(title: "Help", icon: "questionmark.circle", selected: false) {}
                SidebarNavRow(title: footerStatus, icon: "sensor.tag.radiowaves.forward", selected: false) {}
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: QS.Spacing.sidebarWidth)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }
}

// MARK: - Bottom status bar

struct BottomStatusBar: View {
    @EnvironmentObject private var state: AppState
    var leftText: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.systemOnline ? QS.Color.agentActive : QS.Color.agentError)
                    .frame(width: 7, height: 7)
                Text(leftText ?? (state.systemOnline ? L("SISTEMA ONLINE") : L("OFFLINE")))
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.onSurfaceVariant)
            }

            Text("\(L("AGENTI ATTIVI")): \(state.activeAgentCount)")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)

            Spacer()

            HStack(spacing: 14) {
                metric("CPU", "\(state.cpuPercent)%")
                metric("MEM", String(format: "%.1fGB", state.memGB))
                metric("TOKEN/S", "\(state.tokensPerSec)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .top) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            Text(value)
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
    }
}

/// Post-crash / corrupt JSON recovery strip (Fase 3.4) — local only, no telemetry.
struct LocalRecoveryBanners: View {
    @State private var crashPreview: String?
    @State private var crashAckLength: Int = 0
    @State private var jsonNote: String?

    var body: some View {
        VStack(spacing: 0) {
            if let crashPreview {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    title: "L’app è crashata in precedenza",
                    detail: crashPreview,
                    primary: "Apri log",
                    onPrimary: { CrashReporter.openCrashLogInFinder() },
                    onDismiss: {
                        CrashReporter.acknowledgeCrashLog(upToByteLength: crashAckLength)
                        self.crashPreview = nil
                    }
                )
            }
            if let jsonNote {
                banner(
                    icon: "externaldrive.badge.exclamationmark",
                    title: "Dati locali ripristinati",
                    detail: jsonNote,
                    primary: "Apri cartella dati",
                    onPrimary: { NSWorkspace.shared.open(AppConfig.dataDirectory) },
                    onDismiss: { self.jsonNote = nil }
                )
            }
        }
        .onAppear {
            if let unread = CrashReporter.unreadCrashReport() {
                crashPreview = unread.preview
                crashAckLength = unread.byteLength
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: JSONStore.didQuarantineCorrupt)) { note in
            let name = note.userInfo?["name"] as? String ?? "store"
            jsonNote = "File «\(name)» era corrotto: messo in quarantena. Se c’era un .bak è stato ricaricato."
        }
    }

    private func banner(
        icon: String,
        title: String,
        detail: String,
        primary: String,
        onPrimary: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(QS.Color.agentThinking)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(detail)
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(3)
            }
            Spacer()
            Button(primary, action: onPrimary)
                .buttonStyle(.plain)
                .font(QS.Font.ui(11, weight: .semibold))
                .foregroundStyle(QS.Color.primarySolid)
            Button("Chiudi", action: onDismiss)
                .buttonStyle(.plain)
                .foregroundStyle(QS.Color.outline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(QS.Color.agentThinking.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.agentThinking.opacity(0.35)).frame(height: 1)
        }
    }
}
