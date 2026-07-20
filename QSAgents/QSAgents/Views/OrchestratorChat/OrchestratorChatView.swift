import SwiftUI
import UniformTypeIdentifiers

struct OrchestratorChatView: View {
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var probe: SystemProbe
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var voice: VoiceControlService
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var projectMemory: ProjectMemoryStore
    @State private var showAttachPicker = false
    @State private var showChatHistory = false
    @State private var showSaveShortcut = false
    @State private var stickyDraft: String = ""
    @ObservedObject private var recipes = WorkRecipeStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                DirectorySidebarView { path in
                    terminals.openTerminal(at: path)
                    directories.rememberRecent(path: path)
                    state.mainTab = .dashboard
                    state.showIntegrations = false
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .leading, help: "Mostra sidebar (⌘B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }

            chatColumn

            if state.showRightSidebar {
                awarenessColumn
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .trailing, help: "Mostra contesto (⌘⌥B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showRightSidebar = true }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showLeftSidebar)
        .animation(.easeInOut(duration: 0.15), value: state.showRightSidebar)
        .onAppear {
            voice.refreshAuthorization()
            stickyDraft = projectMemory.stickyBrief(for: workspaces.current?.path) ?? ""
        }
        .onChange(of: workspaces.current?.path) { _, path in
            stickyDraft = projectMemory.stickyBrief(for: path) ?? ""
        }
        .sheet(isPresented: $showChatHistory) {
            ChatHistorySheet(isPresented: $showChatHistory)
                .environmentObject(orchestrator)
                .environmentObject(workspaces)
        }
        .sheet(isPresented: $showSaveShortcut) {
            SaveShortcutSheet(isPresented: $showSaveShortcut)
                .environmentObject(orchestrator)
                .environmentObject(workspaces)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            // header + live model switch
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orchestratore")
                            .font(QS.Font.ui(15, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                        Text(orchestrator.configuredAISummary)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .lineLimit(2)
                    }
                    Spacer()
                    Menu {
                        ForEach(CodingEngineKind.allCases) { kind in
                            Button {
                                orchestrator.codingEngine = kind
                            } label: {
                                HStack {
                                    Text(kind.menuLabel)
                                    if orchestrator.codingEngine == kind {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(orchestrator.codingEngine.shortLabel)
                            .font(QS.Font.labelXS)
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (orchestrator.codingEngine == .swarm ? QS.Color.outline : QS.Color.agentActive)
                            .opacity(0.18)
                    )
                    .clipShape(Capsule())
                    .help(orchestrator.codingEngine.help)
                    .controlSize(.small)

                    Toggle(isOn: $orchestrator.goalModeEnabled) {
                        Text(orchestrator.goalModeEnabled ? "GOAL ON" : "GOAL")
                            .font(QS.Font.labelXS)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .tint(orchestrator.goalModeEnabled ? QS.Color.agentActive : QS.Color.outline)
                    .help("GOAL MODE: messaggi = goal autonomi → Coding engine (PTY / IDE)")
                    .controlSize(.small)

                    Button {
                        showChatHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(QS.Font.ui(11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Chat salvate per questo workspace — ripristina o elimina")

                    Menu {
                        Button("Pulisci chat (archivia)") {
                            orchestrator.clearChat(stopAgents: false)
                        }
                        Button("Pulisci e ferma agent", role: .destructive) {
                            orchestrator.clearChat(stopAgents: true)
                        }
                    } label: {
                        Label("Pulisci", systemImage: "trash")
                            .font(QS.Font.ui(11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(orchestrator.messages.isEmpty && orchestrator.activityLog.isEmpty)
                    .help("Archivia la chat. «Pulisci e ferma» cancella anche missione/pulse (BUG-013).")

                    Text(orchestrator.lastReplyEngine.badge)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(Capsule())

                    Text("\(ProviderPreferences.shared.sessionTokens) tok")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                        .help("Token usati in questa sessione")

                    if terminals.activeCount > 0 {
                        Button {
                            state.navigate(to: .dashboard)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(QS.Color.agentActive).frame(width: 6, height: 6)
                                Text("\(terminals.activeCount) terminali →")
                                    .font(QS.Font.ui(11, weight: .medium))
                            }
                            .foregroundStyle(QS.Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(QS.Color.primarySolid.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    Text("Modello")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Picker("Provider", selection: Binding(
                        get: {
                            orchestrator.selectedProviderKind?.rawValue
                                ?? ProviderPreferences.shared.defaultProviderRaw
                        },
                        set: { raw in
                            if let k = LLMProviderKind(rawValue: raw) {
                                orchestrator.setLiveProvider(k)
                                ProviderPreferences.shared.setDefaultProvider(k)
                            }
                        }
                    )) {
                        ForEach(LLMProviderKind.allCases) { p in
                            Text(p.displayName).tag(p.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    SearchableModelPicker(
                        provider: orchestrator.selectedProviderKind
                            ?? ProviderPreferences.shared.defaultProvider
                            ?? .spaceXAI,
                        selection: Binding(
                            get: {
                                orchestrator.selectedModel
                                    ?? ProviderPreferences.shared.model(for: .coordinator)
                            },
                            set: { m in
                                orchestrator.setLiveModel(m)
                                ProviderPreferences.shared.setModel(m, for: .coordinator)
                            }
                        ),
                        width: 220
                    )

                    Spacer()
                    Button("Home") {
                        state.goHome()
                    }
                    .buttonStyle(.plain)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
                }
            }
            .padding(16)
            .background(QS.Color.surfaceLow)
            .overlay(alignment: .bottom) {
                Rectangle().fill(QS.Color.border).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(orchestrator.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if orchestrator.isActivityVisible {
                            OrchestratorActivityPanel()
                                .id("activity")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: orchestrator.messages.count) { _, _ in
                    if let last = orchestrator.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: orchestrator.activityLog.count) { _, _ in
                    if orchestrator.isActivityVisible {
                        withAnimation { proxy.scrollTo("activity", anchor: .bottom) }
                    }
                }
            }
            .background(QS.Color.backgroundDeep)

            // suggestions
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if orchestrator.hasTaskInReview {
                        chip("Applica feedback") {
                            orchestrator.applyReviewFeedback()
                        }
                    }
                    chip("Salva scorciatoia") {
                        showSaveShortcut = true
                    }
                    Menu {
                        Text("Rilancia un goal salvato (stesso testo + engine)")
                        Divider()
                        let list = recipes.recipes(forWorkspace: workspaces.current?.path)
                        if list.isEmpty {
                            Text("Nessuna scorciatoia — salva un goal usato spesso")
                        } else {
                            ForEach(list.prefix(12)) { r in
                                Button {
                                    orchestrator.runRecipe(r)
                                } label: {
                                    Text("\(r.title) · \(r.engine.shortLabel)")
                                }
                            }
                            Divider()
                            Menu("Elimina scorciatoia") {
                                ForEach(list.prefix(12)) { r in
                                    Button(r.title, role: .destructive) {
                                        recipes.delete(r.id)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("Rilancia")
                            .font(QS.Font.ui(11, weight: .medium))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(QS.Color.border, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .help("Scorciatoie goal: salva «fix CSS home» e rilanciala dopo senza riscrivere")
                    chip("Apri coding engine qui") {
                        orchestrator.launchClaudeCodeQuickAction()
                    }
                    chip("Apri terminale in Home") {
                        orchestrator.draft = "apri terminale in ~"
                        orchestrator.send()
                    }
                    chip("Lista progetti") {
                        orchestrator.draft = "lista progetti"
                        orchestrator.send()
                    }
                    chip("Cosa sta girando?") {
                        orchestrator.draft = "cosa sta girando?"
                        orchestrator.send()
                    }
                    chip("Quale AI usi?") {
                        orchestrator.draft = "quale AI usi?"
                        orchestrator.send()
                    }
                    if let first = directories.projects.first {
                        chip("Terminale · \(first.name)") {
                            orchestrator.draft = "apri terminale in \(first.name)"
                            orchestrator.send()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(QS.Color.surfaceLow.opacity(0.5))

            // Voice routing bar
            voiceControlBar

            // composer
            HStack(alignment: .bottom, spacing: 10) {
                // Mic button
                Button {
                    handleMicTap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(voice.isListening ? QS.Color.agentError.opacity(0.25) : QS.Color.surfaceHigh)
                            .frame(width: 40, height: 40)
                        Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(voice.isListening ? QS.Color.agentError : QS.Color.primary)
                            .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                    }
                }
                .buttonStyle(.plain)
                .help(voice.isListening ? "Stop e invia" : "Parla (click per avviare/fermare)")

                Button {
                    showAttachPicker = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(QS.Color.surfaceHigh)
                            .frame(width: 40, height: 40)
                        Image(systemName: "paperclip")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(QS.Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .help("Allega immagine o file all'agente")
                .fileImporter(
                    isPresented: $showAttachPicker,
                    allowedContentTypes: [.image, .pdf, .plainText, .utf8PlainText, .json, .data],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result {
                        for u in urls.prefix(6) {
                            _ = u.startAccessingSecurityScopedResource()
                            orchestrator.addDraftAttachment(u)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if voice.isListening || !voice.partialTranscript.isEmpty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(QS.Color.agentError)
                                .frame(width: 6, height: 6)
                            Text(voice.isListening ? "Ascolto…" : "Ultima trascrizione")
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.agentError)
                            Text(voice.partialTranscript)
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }

                    if !orchestrator.draftAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(orchestrator.draftAttachments, id: \.self) { url in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                            .font(.system(size: 9))
                                        Text(url.lastPathComponent)
                                            .font(QS.Font.mono(9))
                                            .lineLimit(1)
                                        Button {
                                            orchestrator.removeDraftAttachment(url)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(QS.Color.surfaceHigh)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    TextField(
                        composerPlaceholder,
                        text: $orchestrator.draft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(QS.Font.body)
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(1...5)
                    .padding(12)
                    .background(QS.Color.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                voice.isListening ? QS.Color.agentError.opacity(0.6) : QS.Color.border,
                                lineWidth: 1
                            )
                    )
                    .onSubmit { orchestrator.send() }
                }

                Button {
                    orchestrator.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            canSendChat ? QS.Color.primarySolid : QS.Color.outline
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSendChat || orchestrator.isThinking)
            }
            .padding(14)
            .background(QS.Color.surfaceLow)

            if let err = voice.errorMessage {
                Text(err)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.error)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var voiceControlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "ear")
                    .font(.system(size: 11))
                    .foregroundStyle(QS.Color.secondary)

                Text("Voce →")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)

                // Target picker
                Picker("Destinazione", selection: $voice.target) {
                    Text("Orchestratore (chat)").tag(VoiceTarget.orchestrator)
                    ForEach(terminals.sessions) { session in
                        Text("🖥 \(session.title)")
                            .tag(VoiceTarget.terminal(session.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)

                if case .terminal = voice.target, terminals.sessions.isEmpty {
                    Text("Apri prima un terminale")
                        .font(QS.Font.ui(10))
                        .foregroundStyle(QS.Color.agentThinking)
                }

                Spacer()

                Toggle("Auto-invio", isOn: $voice.autoSend)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(QS.Font.ui(10))

                Toggle("TTS risposte", isOn: $voice.speakReplies)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(QS.Font.ui(10))
                    .help("L'orchestratore legge le risposte ad alta voce")

                Picker("", selection: $voice.preferredLocale) {
                    Text("IT").tag("it-IT")
                    Text("EN").tag("en-US")
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .controlSize(.mini)
            }

            Text(voice.statusMessage)
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(QS.Color.surfaceContainer.opacity(0.65))
        .overlay(alignment: .top) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private var canSendChat: Bool {
        !orchestrator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !orchestrator.draftAttachments.isEmpty
    }

    private var composerPlaceholder: String {
        switch voice.target {
        case .orchestrator:
            return "Scrivi o parla all'orchestratore… es. apri 2 terminali in qsagents"
        case .terminal:
            return "Comando vocale per il terminale selezionato… es. git status"
        }
    }

    private func handleMicTap() {
        if voice.isListening {
            let text = voice.stopListening(commit: true)
            guard !text.isEmpty else { return }
            routeVoice(text)
        } else {
            // Ensure terminal target still valid
            if case .terminal(let id) = voice.target,
               !terminals.sessions.contains(where: { $0.id == id }) {
                voice.target = .orchestrator
            }
            voice.startListening()
        }
    }

    private func routeVoice(_ text: String) {
        switch voice.target {
        case .orchestrator:
            if voice.autoSend {
                orchestrator.sendVoiceToOrchestrator(text)
            } else {
                orchestrator.draft = text
            }
        case .terminal(let id):
            if voice.autoSend {
                _ = orchestrator.sendVoiceToTerminal(text, sessionID: id)
            } else {
                orchestrator.draft = text
                // Keep target; user can send manually to terminal via button
                voice.finalTranscript = text
            }
        }
    }

    private var awarenessColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Awareness")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
                .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // AI engine card
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Motore AI")
                        Text(orchestrator.configuredAISummary)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Ultima risposta: \(orchestrator.lastReplyEngine.badge)")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.primary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QS.Color.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    awarenessMetric("CPU", String(format: "%.0f%%", probe.snapshot.cpuPercent), probe.snapshot.cpuPercent / 100)
                    awarenessMetric("RAM", String(format: "%.1f / %.0f GB", probe.snapshot.memoryUsedGB, probe.snapshot.memoryTotalGB), probe.snapshot.memoryUsedGB / max(1, probe.snapshot.memoryTotalGB))

                    SectionLabel(text: "Cosa so adesso")
                    Text(briefContext)
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(QS.Color.backgroundDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    SectionLabel(text: "Brief sticky (memoria progetto)")
                    Text("Regole / stack / path vietati — restano al cambio chat e riapertura.")
                        .font(QS.Font.ui(10))
                        .foregroundStyle(QS.Color.outline)
                    TextEditor(text: $stickyDraft)
                        .font(QS.Font.mono(11))
                        .frame(minHeight: 72, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(QS.Color.backgroundDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Salva brief") {
                            if let path = workspaces.current?.path {
                                _ = projectMemory.setStickyBrief(path: path, text: stickyDraft)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(workspaces.current == nil)
                        if projectMemory.stickyBrief(for: workspaces.current?.path) != nil {
                            Text("Salvato")
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.agentActive)
                        }
                    }

                    SectionLabel(text: "Voce → terminali")
                    if terminals.sessions.isEmpty {
                        Text("Nessun terminale. Aprine uno per inviare comandi vocali.")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    } else {
                        ForEach(terminals.sessions) { session in
                            Button {
                                voice.target = .terminal(session.id)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(session.isAlive ? QS.Color.agentActive : QS.Color.agentIdle)
                                        .frame(width: 6, height: 6)
                                    Text(session.title)
                                        .font(QS.Font.ui(11, weight: .medium))
                                        .foregroundStyle(QS.Color.onSurface)
                                    Spacer()
                                    if case .terminal(let id) = voice.target, id == session.id {
                                        Image(systemName: "mic.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(QS.Color.agentError)
                                    }
                                }
                                .padding(8)
                                .background(QS.Color.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SectionLabel(text: "Azioni rapide")
                    PrimaryButton(title: "Nuovo terminale", icon: "terminal", compact: true) {
                        terminals.openTerminal(at: NSHomeDirectory())
                        state.navigate(to: .dashboard)
                    }
                    GhostButton(title: "Scegli cartella + terminal", icon: "folder") {
                        terminals.pickDirectoryAndOpen()
                        state.navigate(to: .dashboard)
                    }
                    GhostButton(title: "Integrazioni AI", icon: "puzzlepiece.extension") {
                        state.openIntegrations()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 280)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var briefContext: String {
        let terms = terminals.sessions.prefix(4).map {
            "• \($0.title) @ \($0.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        }.joined(separator: "\n")
        let ports = probe.snapshot.listeningPorts.prefix(6).joined(separator: ", ")
        return """
        User: \(probe.snapshot.username)
        Terminali: \(terminals.activeCount)
        \(terms.isEmpty ? "• (nessuno aperto)" : terms)
        Porte: \(ports.isEmpty ? "—" : ports)
        Progetti noti: \(directories.projects.count)
        Voce: \(voice.isListening ? "LISTENING" : "idle")
        """
    }

    private func awarenessMetric(_ title: String, _ value: String, _ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
                Spacer()
                Text(value).font(QS.Font.codeSM).foregroundStyle(QS.Color.onSurface)
            }
            ActivityGauge(progress: min(1, max(0, progress)))
        }
        .padding(10)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(QS.Font.ui(11, weight: .medium))
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(QS.Color.surfaceContainer)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(QS.Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Claude/ChatGPT-style live trail of what the orchestrator is doing.
struct OrchestratorActivityPanel: View {
    @EnvironmentObject private var orchestrator: OrchestratorEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if orchestrator.livePhase.isBusy || orchestrator.isThinking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: orchestrator.livePhase.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QS.Color.primary)
                }
                Text(orchestrator.livePhase.isBusy || orchestrator.isThinking
                     ? orchestrator.livePhase.label
                     : "Attività")
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                if !orchestrator.liveDetail.isEmpty, orchestrator.livePhase.isBusy {
                    Text("· \(orchestrator.liveDetail)")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(orchestrator.activityLog.suffix(10)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.done ? "checkmark.circle.fill" : entry.phase.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(entry.done ? QS.Color.agentActive : QS.Color.primary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.phase.label)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(entry.done ? QS.Color.outline : QS.Color.primary)
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(entry.at, style: .time)
                            .font(QS.Font.ui(9))
                            .foregroundStyle(QS.Color.outline.opacity(0.7))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QS.Color.surfaceContainer.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    (orchestrator.livePhase.isBusy || orchestrator.isThinking)
                    ? QS.Color.primarySolid.opacity(0.45)
                    : QS.Color.border,
                    lineWidth: 1
                )
        )
        .padding(.trailing, 40)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if message.isVoice {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(QS.Color.agentError)
                    }
                    Text(message.role == .user ? "Tu" : message.role == .system ? "Sistema" : "Orchestratore")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    if let engine = message.engine, message.role == .assistant {
                        Text("· \(engine.badge)")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.primary.opacity(0.85))
                    }
                }

                HStack(alignment: .bottom, spacing: 2) {
                    Text(message.text.isEmpty && message.isStreaming
                         ? LocalizedStringKey("_…_")
                         : LocalizedStringKey(message.text.isEmpty ? " " : message.text))
                        .font(QS.Font.body)
                        .foregroundStyle(QS.Color.onSurface)
                        .textSelection(.enabled)
                    if message.isStreaming {
                        // C3: caret while tokens arrive
                        TimelineView(.animation(minimumInterval: 0.5, paused: false)) { ctx in
                            Text((Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0) ? "▍" : " ")
                                .font(QS.Font.mono(13))
                                .foregroundStyle(QS.Color.primarySolid)
                        }
                    }
                }
                .padding(12)
                .background(
                    message.role == .user
                    ? (message.isVoice ? QS.Color.agentError.opacity(0.15) : QS.Color.primarySolid.opacity(0.2))
                    : QS.Color.surfaceContainer
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            message.isStreaming
                            ? QS.Color.primarySolid.opacity(0.55)
                            : (message.role == .user
                               ? (message.isVoice ? QS.Color.agentError.opacity(0.4) : QS.Color.primarySolid.opacity(0.35))
                               : QS.Color.border),
                            lineWidth: message.isStreaming ? 1.5 : 1
                        )
                )

                if !message.actions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("\(message.actions.count) azion\(message.actions.count == 1 ? "e" : "i") eseguita")
                            .font(QS.Font.labelXS)
                    }
                    .foregroundStyle(QS.Color.agentActive)
                }
            }
            if message.role != .user { Spacer(minLength: 60) }
        }
    }
}
