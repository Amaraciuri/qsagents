import SwiftUI

@main
struct QSAgentsApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var terminals = TerminalManager()
    @StateObject private var directories = DirectoryStore()
    @StateObject private var probe = SystemProbe()
    @StateObject private var orchestrator = OrchestratorEngine()
    @StateObject private var voice = VoiceControlService()
    @StateObject private var safety = SafetyGuardrails()
    @StateObject private var signing = ApprovalSigningService()
    @StateObject private var remote = RemoteApprovalNotifier()
    @StateObject private var workspaces = WorkspaceStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var agentSessions = AgentSessionStore()
    @StateObject private var git = GitService()
    @StateObject private var knowledge = KnowledgeStore()
    @StateObject private var projectMemory = ProjectMemoryStore()
    @StateObject private var notices = AppNotificationCenter()
    @StateObject private var sparkle = SparkleUpdater()
    @ObservedObject private var language = AppLanguageStore.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "qs.onboarding.done")
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(appState)
                .environmentObject(terminals)
                .environmentObject(directories)
                .environmentObject(probe)
                .environmentObject(orchestrator)
                .environmentObject(voice)
                .environmentObject(safety)
                .environmentObject(signing)
                .environmentObject(remote)
                .environmentObject(workspaces)
                .environmentObject(taskStore)
                .environmentObject(agentSessions)
                .environmentObject(git)
                .environmentObject(knowledge)
                .environmentObject(projectMemory)
                .environmentObject(notices)
                .environmentObject(sparkle)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .id(language.code)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear {
                    bootstrap()
                }
                .onChange(of: language.code) { _, _ in
                    orchestrator.refreshWelcomeForLanguageIfNeeded()
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView {
                        showOnboarding = false
                    }
                    .environmentObject(appState)
                    .environmentObject(workspaces)
                    .environmentObject(safety)
                    .environmentObject(directories)
                    .environmentObject(orchestrator)
                    .environment(\.locale, language.locale)
                }
                .sheet(isPresented: $showAbout) {
                    AboutView { showAbout = false }
                        .environmentObject(appState)
                        .environment(\.locale, language.locale)
                }
                .onReceive(NotificationCenter.default.publisher(for: .qsOpenWorkspacePicker)) { _ in
                    workspaces.pickAndOpen()
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .workspace
                }
                .sheet(item: $safety.pendingConfirm) { pending in
                    SafetyConfirmSheet(pending: pending)
                        .environmentObject(safety)
                        .environmentObject(terminals)
                        .environment(\.locale, language.locale)
                }
                .onReceive(probe.$snapshot) { snap in
                    appState.applySystemMetrics(
                        cpu: Int(snap.cpuPercent),
                        memGB: snap.memoryUsedGB,
                        activeTerminals: terminals.activeCount
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(sparkle: sparkle)
                Button(L("Orchestratore QS Agents…")) {
                    appState.toggleOrchestratorModal()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button(L("About & Scorciatoie…")) {
                    showAbout = true
                }
                Button(L("Mostra onboarding…")) {
                    showOnboarding = true
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(L("Nuovo Terminale")) {
                    terminals.openTerminal(at: terminals.selected?.cwd ?? NSHomeDirectory())
                    appState.navigate(to: .dashboard)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button(L("Nuovo Terminale in Cartella…")) {
                    terminals.pickDirectoryAndOpen()
                    appState.navigate(to: .dashboard)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(L("Nuova Task")) {
                    appState.mainTab = .orchestrator
                    appState.orchestratorMode = .tasks
                    appState.showIntegrations = false
                    taskStore.add(title: L("Nuova task"))
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(L("Apri Workspace…")) {
                    workspaces.pickAndOpen()
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .workspace
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu(L("Viste")) {
                Button(L("Home")) {
                    appState.goHome()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button(L("Apri Orchestratore (modal)")) {
                    appState.openOrchestratorModal()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(L("Orchestratore (Chat full)")) {
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .chat
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button(L("Terminali")) {
                    appState.navigate(to: .dashboard)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(L("QS Tasks")) {
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .tasks
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(L("QS Swarm")) {
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .swarm
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button(L("Workspace")) {
                    appState.navigate(to: .orchestrator)
                    appState.orchestratorMode = .workspace
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button(L("Knowledge Graph")) {
                    appState.navigate(to: .monitor)
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button(L("Integrazioni")) {
                    appState.openIntegrations()
                }
                .keyboardShortcut(",", modifiers: [.command])

                Button(L("Sicurezza & Guardrail")) {
                    appState.openSafety()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu(L("Terminale")) {
                Button(L("Chiudi terminale corrente")) {
                    if let id = terminals.selectedID {
                        terminals.close(id)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button(L("Riavvia terminale corrente")) {
                    if let id = terminals.selectedID {
                        terminals.restart(id)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu(L("Vista")) {
                Button(appState.showLeftSidebar ? L("Nascondi sidebar sinistra") : L("Mostra sidebar sinistra")) {
                    appState.toggleLeftSidebar()
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button(appState.showRightSidebar ? L("Nascondi pannello destro") : L("Mostra pannello destro")) {
                    appState.toggleRightSidebar()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button(L("Nascondi entrambe le sidebar")) {
                    appState.showLeftSidebar = false
                    appState.showRightSidebar = false
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Settings {
            IntegrationsView()
                .environmentObject(appState)
                .environmentObject(voice)
                .environmentObject(workspaces)
                .environmentObject(taskStore)
                .environmentObject(safety)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .id(language.code)
                .frame(width: 900, height: 600)
        }
    }

    private func bootstrap() {
        AppConfig.applyProductionDefaults()
        CrashReporter.installIfEnabled()
        probe.start(interval: 3)
        // Integration status uses Keychain — never do the first fill on the main thread.
        // Prefetch off-main, then refresh UI once the process cache is warm.
        let keyAccounts = LLMProviderKind.allCases.flatMap { [$0.keychainAccount] + $0.legacyKeychainAccounts }
            + ["GitHub", "OpenAI", "OpenRouter", "Anthropic", "xAI"]
        KeychainStore.prefetch(keyAccounts)
        Task.detached(priority: .utility) {
            // Give background fills a brief head start (Keychain ops are timed out).
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                appState.refreshIntegrationStatuses()
            }
        }
        // Do NOT request mic/speech at launch — only when user taps 🎤
        voice.refreshAuthorization()
        terminals.safety = safety
        safety.signing = signing
        safety.remote = remote
        agentSessions.terminals = terminals
        agentSessions.workspaces = workspaces
        agentSessions.tasks = taskStore
        agentSessions.orchestrator = orchestrator
        agentSessions.git = git
        agentSessions.safety = safety
        agentSessions.projectMemory = projectMemory
        agentSessions.knowledge = knowledge
        agentSessions.bindRuntime()
        taskStore.onTaskCompleted = { [weak remote, notices, agentSessions] task in
            notices.post(
                "Task completata",
                body: "\(task.title)\nModello: \(task.assigneeModel)",
                kind: .task,
                taskID: task.id
            )
            remote?.notifyInfo(
                title: "Task completata",
                body: "\(task.title)\nModello: \(task.assigneeModel)\nWorkspace: \(task.workspacePath ?? "—")"
            )
            // Swarm auto-pipeline: next unblocked task → next builder
            agentSessions.advanceMissionPipeline()
        }

        // Terminal process exit → notice + linked task board update
        terminals.onSessionExit = { [weak taskStore, notices] session, code in
            let ok = code == 0
            notices.post(
                ok ? "Terminale terminato" : "Terminale fallito (exit \(code))",
                body: "\(session.title) · \(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                kind: ok ? .terminalDone : .terminalFailed,
                terminalID: session.id
            )
            if let linked = taskStore?.handleTerminalExit(terminalID: session.id, exitCode: code), !ok {
                notices.post(
                    "Task in review",
                    body: "\(linked.title) · exit \(code)",
                    kind: .task,
                    taskID: linked.id
                )
            }
        }
        // User closes PTY tab → remove Swarm agent + save trace onto the board task
        terminals.onSessionClosed = { [weak agentSessions] terminalId in
            agentSessions?.handleTerminalClosed(terminalId)
        }

        // Defer heavy work so first frame is responsive (felt like freezes/crashes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            terminals.restorePersistedSessions()
        }
        if let path = workspaces.current?.path {
            git.setPath(path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                knowledge.index(workspace: path)
                // Local code brain / capsule index for agents
                ProjectCodeBrain.shared.ensureIndexed(workspace: path)
                // B1/B5: soft sync + “ultima volta” on launch
                _ = projectMemory.markVisit(path: path)
            }
        }
        orchestrator.bind(
            terminals: terminals,
            directories: directories,
            probe: probe,
            safety: safety,
            tasks: taskStore,
            workspaces: workspaces,
            git: git,
            agents: agentSessions,
            knowledge: knowledge,
            projectMemory: projectMemory,
            onNavigate: { [weak appState] route in
                appState?.handleOrchestratorRoute(route)
            }
        )
        // A6: ⌘K modal → tools.stayInPlace so side-effects don't force route changes
        orchestrator.stayInPlaceProvider = { [weak appState] in
            appState?.showOrchestratorModal == true
        }
        orchestrator.onSpeak = { [weak voice] text in
            voice?.speak(text)
        }

        workspaces.onWorkspaceChanged = { [weak orchestrator, weak projectMemory] previous, current in
            orchestrator?.loadChatForWorkspace(current, savingPrevious: previous)
            _ = projectMemory?.markVisit(path: current)
        }

        // First-run / empty feed welcome so the bell isn't a dead control
        if notices.notices.isEmpty {
            notices.post(
                L("Centro notifiche attivo"),
                body: L("Qui vedrai terminali, task e eventi safety/orchestratore."),
                kind: .info
            )
            notices.markAllRead()
        }

        // First launch / never configured → apply recommended safety profile
        let paths = directories.projects.map(\.path)
            + directories.bookmarks.map(\.path)
            + directories.quickAccess.map(\.path)
            + workspaces.recent.map(\.path)
        safety.applyRecommendedIfNeeded(projectPaths: paths)

        AppLogger.info("Bootstrap complete · demo=\(AppConfig.useDemoData) · workspace=\(workspaces.current?.path ?? "nil") · tasks=\(taskStore.tasks.count)")

        // Sparkle: background check on launch (native alert if update found). Scheduled
        // checks continue via Info.plist SUEnableAutomaticChecks / SUScheduledCheckInterval.
        DispatchQueue.main.async { [sparkle] in
            sparkle.checkForUpdatesInBackgroundAfterLaunch()
        }

        // If projects scan finishes late, top up allowlist once
        Task {
            await directories.scanProjects()
            if safety.recommendedSetupApplied, safety.projectAllowlist.count < 3 {
                safety.importAllowlist(from: directories.projects.map(\.path))
            }
        }
    }
}
