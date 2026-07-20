import SwiftUI

/// Modal globale: parla con l'Orchestratore QS Agents da qualsiasi schermata (⌘K).
struct OrchestratorQuickModal: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var voice: VoiceControlService
    @FocusState private var inputFocused: Bool

    private let quickPrompts = [
        "Apri coding engine qui",
        "Apri terminale e fai git status",
        "Cosa sta girando?",
        "Lista progetti",
        "Avvia missione: esplora il workspace",
    ]

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                header
                Divider().overlay(QS.Color.border)

                messagesArea
                suggestions
                voiceRow
                composer
            }
            .frame(width: 640, height: 520)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(QS.Color.surfaceLow)
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                QS.Color.primarySolid.opacity(0.55),
                                QS.Color.secondary.opacity(0.25),
                                QS.Color.border
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .onAppear {
            bindTargetToSelectedTerminal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocused = true
            }
            voice.refreshAuthorization()
        }
        .onChange(of: terminals.selectedID) { _, _ in
            // Keep modal destination in sync if user switches terminal while open.
            if case .terminal = voice.target {
                bindTargetToSelectedTerminal()
            }
        }
        .onExitCommand { dismiss() }
    }

    /// When a terminal is selected, ⌘K defaults to speaking/writing into that pane.
    private func bindTargetToSelectedTerminal() {
        if let id = terminals.selectedID, terminals.sessions.contains(where: { $0.id == id }) {
            voice.target = .terminal(id)
        } else {
            voice.target = .orchestrator
        }
    }

    private var targetTerminal: TerminalSession? {
        if case .terminal(let id) = voice.target {
            return terminals.sessions.first { $0.id == id }
        }
        return nil
    }

    private var isTerminalTarget: Bool {
        if case .terminal = voice.target { return true }
        return false
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isTerminalTarget
                                ? [QS.Color.agentActive, QS.Color.primarySolid]
                                : [QS.Color.primarySolid, QS.Color.secondaryContainer],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: isTerminalTarget ? "terminal.fill" : "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isTerminalTarget ? "Terminale selezionato" : "Orchestratore QS Agents")
                    .font(QS.Font.ui(15, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                if let term = targetTerminal {
                    Text("→ \(term.title) · \(term.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.primary)
                        .lineLimit(1)
                } else {
                    Text("Dillo in naturale · \(orchestrator.lastReplyEngine.badge)")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .lineLimit(1)
                }
            }

            // Always show where you're working + switch
            WorkspaceSwitcher(style: .compact)
                .frame(maxWidth: 160)

            Spacer(minLength: 8)

            Menu {
                ForEach(CodingEngineKind.allCases) { kind in
                    Button {
                        orchestrator.codingEngine = kind
                    } label: {
                        HStack {
                            Text(kind.shortLabel)
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
            .controlSize(.small)
            .help(orchestrator.codingEngine.help)

            Toggle(isOn: $orchestrator.goalModeEnabled) {
                Text(orchestrator.goalModeEnabled ? "GOAL ON" : "GOAL")
                    .font(QS.Font.labelXS)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(orchestrator.goalModeEnabled ? QS.Color.agentActive : QS.Color.outline)
            .controlSize(.small)
            .help("GOAL MODE: messaggi = goal autonomi → Coding engine")

            Button {
                orchestrator.clearChat()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(orchestrator.messages.isEmpty && orchestrator.activityLog.isEmpty)
            .help("Pulisci chat")

            Text("⌘K")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(QS.Color.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QS.Color.outline)
                    .frame(width: 28, height: 28)
                    .background(QS.Color.surfaceHigh)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if orchestrator.messages.isEmpty {
                        emptyHint
                    } else {
                        ForEach(orchestrator.messages.suffix(12)) { msg in
                            miniBubble(msg)
                                .id(msg.id)
                        }
                    }
                    if orchestrator.isActivityVisible {
                        OrchestratorActivityPanel()
                            .id("activity")
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
            .background(QS.Color.backgroundDeep.opacity(0.65))
            .onChange(of: orchestrator.messages.count) { _, _ in
                if let last = orchestrator.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Esempi")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            Text("«Aprimi il progetto qsagents e apri due terminali»")
                .font(QS.Font.ui(13))
                .foregroundStyle(QS.Color.onSurfaceVariant)
            Text("«Esegui git status nel progetto corrente»")
                .font(QS.Font.ui(13))
                .foregroundStyle(QS.Color.onSurfaceVariant)
            Text("«Cosa sta girando sul Mac?»")
                .font(QS.Font.ui(13))
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private func miniBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 40) }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if msg.isVoice {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(QS.Color.agentError)
                    }
                    Text(msg.role == .user ? "Tu" : "QS Agents")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    Text(LocalizedStringKey(msg.text.isEmpty && msg.isStreaming ? "…" : (msg.text.isEmpty ? " " : msg.text)))
                        .font(QS.Font.ui(12))
                        .foregroundStyle(QS.Color.onSurface)
                        .textSelection(.enabled)
                    if msg.isStreaming {
                        Text("▍")
                            .font(QS.Font.mono(11))
                            .foregroundStyle(QS.Color.primarySolid)
                    }
                }
                .padding(10)
                .background(
                    msg.role == .user
                    ? QS.Color.primarySolid.opacity(0.22)
                    : QS.Color.surfaceContainer
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            msg.isStreaming
                            ? QS.Color.primarySolid.opacity(0.5)
                            : (msg.role == .user
                               ? QS.Color.primarySolid.opacity(0.35)
                               : QS.Color.border),
                            lineWidth: 1
                        )
                )
            }
            if msg.role != .user { Spacer(minLength: 40) }
        }
    }

    private var suggestions: some View {
        // Horizontal chip scroller — fixedSize content so macOS can pan past the modal width.
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(quickPrompts, id: \.self) { prompt in
                    Button {
                        if prompt.lowercased().contains("coding engine")
                            || prompt.lowercased().contains("claude code") {
                            orchestrator.launchClaudeCodeQuickAction()
                        } else {
                            orchestrator.draft = prompt
                            orchestrator.send()
                        }
                    } label: {
                        Text(prompt)
                            .font(QS.Font.ui(11, weight: .medium))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(QS.Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .background(QS.Color.surfaceLow)
    }

    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isTerminalTarget ? "terminal" : "ear")
                    .font(.system(size: 11))
                    .foregroundStyle(isTerminalTarget ? QS.Color.primary : QS.Color.secondary)
                Text(destinationLabel)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)

                if voice.isListening {
                    Text(voice.partialTranscript.isEmpty ? "Ascolto…" : voice.partialTranscript)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.agentError)
                        .lineLimit(1)
                }

                Spacer()

                if terminals.activeCount > 0 {
                    Text("\(terminals.activeCount) terminali")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.agentActive)
                }
            }

            // Destination picker: Orchestratore vs each open terminal
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    destChip(
                        title: "Orchestratore",
                        icon: "sparkles",
                        selected: !isTerminalTarget
                    ) {
                        voice.target = .orchestrator
                    }
                    ForEach(terminals.sessions) { session in
                        destChip(
                            title: session.title,
                            icon: "terminal",
                            selected: {
                                if case .terminal(let id) = voice.target { return id == session.id }
                                return false
                            }()
                        ) {
                            terminals.select(session.id)
                            voice.target = .terminal(session.id)
                        }
                    }
                }
                .padding(.trailing, 4)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            isTerminalTarget
                ? QS.Color.primarySolid.opacity(0.08)
                : QS.Color.surfaceContainer.opacity(0.5)
        )
    }

    private var destinationLabel: String {
        if let term = targetTerminal {
            return "Voce / testo → \(term.title)"
        }
        return "Voce → Orchestratore"
    }

    private func destChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(QS.Font.ui(11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? .white : QS.Color.onSurfaceVariant)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? QS.Color.primarySolid : QS.Color.surfaceHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                handleMic()
            } label: {
                ZStack {
                    Circle()
                        .fill(voice.isListening ? QS.Color.agentError.opacity(0.25) : QS.Color.surfaceHigh)
                        .frame(width: 40, height: 40)
                    Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(voice.isListening ? QS.Color.agentError : QS.Color.primary)
                }
            }
            .buttonStyle(.plain)
            .help(isTerminalTarget
                  ? "Parla → comando nel terminale selezionato"
                  : "Parla all'Orchestratore QS Agents")

            TextField(
                isTerminalTarget
                    ? "Comando per \(targetTerminal?.title ?? "terminale")… (Invio invia al PTY)"
                    : "Aprimi il progetto… apri terminali… dimmi cosa gira…",
                text: $orchestrator.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(QS.Font.body)
            .foregroundStyle(QS.Color.onSurface)
            .lineLimit(1...4)
            .padding(12)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        inputFocused
                            ? (isTerminalTarget ? QS.Color.agentActive.opacity(0.8) : QS.Color.primarySolid.opacity(0.7))
                            : QS.Color.border,
                        lineWidth: 1
                    )
            )
            .focused($inputFocused)
            .onSubmit { send() }

            Button(action: send) {
                Image(systemName: isTerminalTarget ? "terminal.fill" : "arrow.up.circle.fill")
                    .font(.system(size: isTerminalTarget ? 28 : 34))
                    .foregroundStyle(
                        canSend ? QS.Color.primarySolid : QS.Color.outline
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend || orchestrator.isThinking)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(isTerminalTarget ? "Invia comando al terminale" : "Invia all'orchestratore")
        }
        .padding(14)
        .background(QS.Color.surfaceLow)
    }

    private var canSend: Bool {
        !orchestrator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = orchestrator.draft
        if case .terminal(let id) = voice.target {
            orchestrator.draft = ""
            _ = orchestrator.sendVoiceToTerminal(text, sessionID: id)
            // Keep modal open so user can send more commands to the same terminal
            inputFocused = true
            return
        }
        orchestrator.send()
        inputFocused = true
    }

    private func handleMic() {
        // Do NOT force orchestrator — respect selected terminal target
        if voice.isListening {
            let text = voice.stopListening(commit: true)
            guard !text.isEmpty else { return }
            if voice.autoSend {
                dispatchVoiceText(text)
            } else {
                orchestrator.draft = text
            }
        } else {
            voice.startListening()
        }
    }

    private func dispatchVoiceText(_ text: String) {
        if case .terminal(let id) = voice.target {
            _ = orchestrator.sendVoiceToTerminal(text, sessionID: id)
        } else {
            orchestrator.sendVoiceToOrchestrator(text)
        }
    }

    private func dismiss() {
        if voice.isListening {
            _ = voice.stopListening(commit: false)
        }
        state.closeOrchestratorModal()
    }
}

// MARK: - Overlay host

struct OrchestratorModalHost: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content
            .overlay {
                if state.showOrchestratorModal {
                    OrchestratorQuickModal()
                        .zIndex(999)
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: state.showOrchestratorModal)
                }
            }
    }
}

extension View {
    func orchestratorQuickModal() -> some View {
        modifier(OrchestratorModalHost())
    }
}
