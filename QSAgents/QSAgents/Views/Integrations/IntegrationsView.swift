import SwiftUI

struct IntegrationsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var voice: VoiceControlService
    @EnvironmentObject private var language: AppLanguageStore
    @StateObject private var githubAuth = GitHubAuthService.shared
    @StateObject private var browserAuth = ProviderBrowserAuthService.shared
    @State private var section: SettingsSection = .integrations

    enum SettingsSection: String, CaseIterable, Identifiable {
        case integrations
        case tutorials
        case permissions
        case gdpr
        case changelog
        case docs
        case support
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .integrations: return "Integrazioni"
            case .tutorials: return "Tutorial"
            case .permissions: return "Permessi"
            case .gdpr: return "GDPR"
            case .changelog: return "Novità"
            case .docs: return "Docs"
            case .support: return "Supporto"
            }
        }

        var icon: String {
            switch self {
            case .integrations: return "puzzlepiece.extension"
            case .tutorials: return "book.fill"
            case .permissions: return "mic.and.signal.meter"
            case .gdpr: return "hand.raised.fill"
            case .changelog: return "newspaper.fill"
            case .docs: return "doc.text"
            case .support: return "questionmark.circle"
            }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        HStack(spacing: 0) {
            integrationsSidebar
            switch section {
            case .integrations:
                integrationsMain
            case .tutorials:
                TutorialsView()
            case .permissions:
                PermissionsSettingsView()
            case .gdpr:
                GDPRPrivacyView()
            case .changelog:
                AppChangelogView()
            case .docs:
                DocsSettingsView()
            case .support:
                SupportSettingsView()
            }
        }
        .onAppear {
            // Deep-link: open GDPR / changelog / docs if requested
            if state.openSettingsSection == "gdpr" {
                section = .gdpr
                state.openSettingsSection = nil
            } else if state.openSettingsSection == "tutorials" || state.openSettingsSection == "tutorial" {
                section = .tutorials
                state.openSettingsSection = nil
            } else if state.openSettingsSection == "changelog" || state.openSettingsSection == "novita" {
                section = .changelog
                state.openSettingsSection = nil
            } else if state.openSettingsSection == "docs" {
                section = .docs
                state.openSettingsSection = nil
            } else if state.openSettingsSection == "support" {
                section = .support
                state.openSettingsSection = nil
            } else if state.openSettingsSection == "permissions" {
                section = .permissions
                state.openSettingsSection = nil
            }
            state.refreshIntegrationStatuses()
            voice.refreshAllPermissions()
            browserAuth.refreshStatus()
            Task { await githubAuth.refreshUserLogin() }
        }
        .onChange(of: githubAuth.isLoggedIn) { _, loggedIn in
            if loggedIn {
                state.refreshIntegrationStatuses()
            }
        }
        .onChange(of: githubAuth.isAuthenticating) { _, auth in
            if !auth { state.refreshIntegrationStatuses() }
        }
    }

    private var integrationsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QS AGENTS")
                    .font(QS.Font.ui(12, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                Text("Impostazioni")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(14)

            VStack(spacing: 2) {
                SidebarNavRow(
                    title: L("Integrazioni"),
                    icon: "puzzlepiece.extension",
                    selected: section == .integrations
                ) {
                    section = .integrations
                }
                SidebarNavRow(
                    title: L("Tutorial"),
                    icon: "book.fill",
                    selected: section == .tutorials
                ) {
                    section = .tutorials
                }
                SidebarNavRow(
                    title: L("Permessi"),
                    icon: "mic.and.signal.meter",
                    selected: section == .permissions
                ) {
                    section = .permissions
                    voice.refreshAllPermissions()
                }
                SidebarNavRow(
                    title: "GDPR & Privacy",
                    icon: "hand.raised.fill",
                    selected: section == .gdpr
                ) {
                    section = .gdpr
                }
                SidebarNavRow(
                    title: L("Novità"),
                    icon: "newspaper.fill",
                    selected: section == .changelog
                ) {
                    section = .changelog
                }
                SidebarNavRow(title: "Workspaces", icon: "square.grid.2x2", selected: false) {
                    state.showIntegrations = false
                    state.mainTab = .orchestrator
                    state.orchestratorMode = .workspace
                }
                SidebarNavRow(title: L("Terminali"), icon: "terminal", selected: false) {
                    state.showIntegrations = false
                    state.mainTab = .dashboard
                }
                SidebarNavRow(title: L("Sicurezza"), icon: "shield.lefthalf.filled", selected: false) {
                    state.openSafety()
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Divider().overlay(QS.Color.border)
            VStack(spacing: 2) {
                SidebarNavRow(
                    title: L("Docs"),
                    icon: "doc.text",
                    selected: section == .docs
                ) {
                    section = .docs
                }
                SidebarNavRow(
                    title: L("Supporto"),
                    icon: "questionmark.circle",
                    selected: section == .support
                ) {
                    section = .support
                }
            }
            .padding(8)
        }
        .frame(width: QS.Spacing.sidebarWidth)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var integrationsMain: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("INTEGRAZIONI")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Text("AI & GITHUB")
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("API key in Keychain · OpenAI: anche login ChatGPT (Codex) · Claude: API key Console (policy Anthropic).")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                Spacer()

                QSSearchField(placeholder: "Cerca provider...", text: $state.integrationSearch)

                PrimaryButton(title: "Aggiungi Personalizzato", icon: "plus", compact: true) {}
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AccountLoginPanel(auth: browserAuth) {
                        state.refreshIntegrationStatuses()
                    }

                    GitHubLoginPanel(auth: githubAuth) {
                        state.refreshIntegrationStatuses()
                    }

                    if let msg = state.integrationSaveMessage {
                        Text(msg)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(
                                msg.lowercased().contains("salvata") || msg.lowercased().contains("ok")
                                ? QS.Color.agentActive : QS.Color.error
                            )
                            .padding(.horizontal, 4)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.filteredIntegrations) { item in
                            IntegrationCard(
                                item: item,
                                isConfiguring: state.configuringIntegrationID == item.id,
                                apiKey: $state.apiKeyDraft,
                                onConfigure: {
                                    state.configuringIntegrationID = item.id
                                    state.apiKeyDraft = ""
                                    state.integrationSaveMessage = nil
                                },
                                onSave: { _ = state.saveAPIKey(for: item.id) },
                                onSaveKey: { key in
                                    state.saveAPIKey(for: item.id, keyOverride: key)
                                },
                                onDisconnect: {
                                    if item.name == "GitHub" {
                                        githubAuth.logout()
                                    }
                                    state.disconnectIntegration(item.id)
                                },
                                onCancel: {
                                    state.configuringIntegrationID = nil
                                    state.apiKeyDraft = ""
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }
}

// MARK: - Permissions (mic / speech re-enable)

struct PermissionsSettingsView: View {
    @EnvironmentObject private var voice: VoiceControlService
    @EnvironmentObject private var language: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IMPOSTAZIONI")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Text("Permessi")
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("Microfono e riconoscimento vocale per ⌘K e comandi parlati. Se hai premuto «Non consentire», macOS non ripropone il dialog: si riabilita da qui → Impostazioni Sistema.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Spacer()
                GhostButton(title: "Aggiorna stato", icon: "arrow.clockwise") {
                    voice.refreshAllPermissions()
                }
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LanguageSettingsCard()

                    // Combined readiness
                    HStack(spacing: 10) {
                        Image(systemName: voice.bothPermissionsReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(voice.bothPermissionsReady ? QS.Color.agentActive : QS.Color.agentThinking)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.bothPermissionsReady ? "Pronti per la voce" : "Permessi incompleti")
                                .font(QS.Font.ui(13, weight: .semibold))
                                .foregroundStyle(QS.Color.onSurface)
                            Text(voice.statusMessage)
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                        }
                        Spacer()
                        PrimaryButton(title: "Testa microfono", icon: "stethoscope", compact: true) {
                            voice.runMicProbe()
                        }
                    }
                    .padding(14)
                    .background(QS.Color.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    permissionCard(
                        title: "Microfono",
                        icon: "mic.fill",
                        status: voice.microphoneStatusLabel,
                        ok: voice.microphoneAuthorized,
                        detail: "Serve per catturare l’audio quando usi 🎤. Bundle: com.qsagents.mac",
                        primaryTitle: voice.microphoneAuthorized ? "Ricarica stato" : "Richiedi permesso",
                        primaryAction: {
                            voice.requestMicrophoneIfNeeded()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                voice.refreshAllPermissions()
                                if !voice.microphoneAuthorized {
                                    voice.openSystemMicrophoneSettings()
                                }
                            }
                        },
                        secondaryTitle: "Apri Privacy → Microfono",
                        secondaryAction: { voice.openSystemMicrophoneSettings() }
                    )

                    permissionCard(
                        title: "Riconoscimento vocale",
                        icon: "waveform",
                        status: voice.speechStatusLabel,
                        ok: voice.isAuthorized,
                        detail: "Trasforma la voce in testo per l’Orchestratore e i terminali.",
                        primaryTitle: voice.isAuthorized ? "Ricarica stato" : "Richiedi permesso",
                        primaryAction: {
                            voice.requestPermissionsIfNeeded()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                voice.refreshAllPermissions()
                                if !voice.isAuthorized {
                                    voice.openSystemSpeechSettings()
                                }
                            }
                        },
                        secondaryTitle: "Apri Privacy → Riconoscimento vocale",
                        secondaryAction: { voice.openSystemSpeechSettings() }
                    )

                    if let err = voice.errorMessage {
                        Text(err)
                            .font(QS.Font.ui(12))
                            .foregroundStyle(QS.Color.error)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(QS.Color.error.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if !voice.diagnosticsLine.isEmpty {
                        Text(voice.diagnosticsLine)
                            .font(QS.Font.mono(10))
                            .foregroundStyle(QS.Color.outline)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Se resta OFF")
                            .font(QS.Font.ui(13, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                        Text("""
                        1. Chiudi completamente QS Agents (⌘Q)
                        2. Impostazioni Sistema → Privacy e sicurezza → Microfono
                           → attiva **QS Agents** (bundle com.qsagents.mac)
                        3. Stessa cosa in Riconoscimento vocale
                        4. Riapri l’app, torna qui → «Aggiorna stato» → «Testa microfono»
                        5. Se non compare in lista: premi 🎤 in ⌘K una volta (fa scattare il dialog TCC)
                        6. Se hai più copie dell’app, abilita quella che stai eseguendo ora
                        """)
                            .font(QS.Font.ui(12))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                        HStack(spacing: 8) {
                            GhostButton(title: "Apri Privacy e sicurezza", icon: "gear") {
                                voice.openSystemPrivacySettings()
                            }
                            GhostButton(title: "Richiedi entrambi", icon: "hand.raised") {
                                voice.requestPermissionsIfNeeded()
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QS.Color.surfaceLow)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(QS.Color.border, lineWidth: 1))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .onAppear {
                voice.refreshAllPermissions()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
        .onAppear { voice.refreshAllPermissions() }
    }

    private func permissionCard(
        title: String,
        icon: String,
        status: String,
        ok: Bool,
        detail: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ok ? QS.Color.agentActive : QS.Color.agentThinking)
                    .frame(width: 36, height: 36)
                    .background((ok ? QS.Color.agentActive : QS.Color.agentThinking).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(QS.Font.ui(14, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(status)
                        .font(QS.Font.ui(12))
                        .foregroundStyle(ok ? QS.Color.agentActive : QS.Color.onSurfaceVariant)
                }
                Spacer()
                Text(ok ? "ON" : "OFF")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(ok ? QS.Color.agentActive : QS.Color.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((ok ? QS.Color.agentActive : QS.Color.error).opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(detail)
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            HStack(spacing: 10) {
                if !ok {
                    PrimaryButton(title: primaryTitle, icon: "lock.open", compact: true, action: primaryAction)
                }
                GhostButton(title: secondaryTitle, icon: "arrow.up.forward.app", action: secondaryAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(QS.Color.border, lineWidth: 1))
    }
}

// MARK: - AI account login (ChatGPT / Claude browser)

struct AccountLoginPanel: View {
    @ObservedObject var auth: ProviderBrowserAuthService
    var onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(QS.Color.primarySolid)
                Text("Account AI · login browser")
                    .font(QS.Font.ui(14, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
            }

            Text("Come in Cursor/Codex: collega l’account ChatGPT (senza sk-) o apri la Console Anthropic. Le key restano in Keychain locale.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            // OpenAI / ChatGPT
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(QS.Color.agentActive)
                    Text("OpenAI / ChatGPT")
                        .font(QS.Font.ui(12, weight: .semibold))
                    Spacer()
                    if auth.openAIHasOAuth {
                        StatusChip(
                            text: auth.openAIEmail.map { String($0.prefix(22)) } ?? "ChatGPT",
                            color: QS.Color.agentActive
                        )
                    } else if auth.openAIHasAPIKey {
                        StatusChip(text: "API key", color: QS.Color.primarySolid)
                    } else {
                        StatusChip(text: "non collegato", color: QS.Color.outline)
                    }
                }
                Text("Login ChatGPT = sessione Codex (abbonamento). API key = Platform a consumo.")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)

                HStack(spacing: 10) {
                    Button {
                        auth.loginOpenAIWithBrowser()
                        onChanged()
                    } label: {
                        Label("Login browser (Codex)", systemImage: "globe")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(QS.Color.primarySolid)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        auth.importOpenAIFromCodexCLI()
                        onChanged()
                    } label: {
                        Label("Importa da Codex CLI", systemImage: "square.and.arrow.down")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.primarySolid)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(QS.Color.primarySolid.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Se hai già fatto `codex login`, importa ~/.codex/auth.json")

                    Button {
                        auth.openOpenAIPlatformKeys()
                    } label: {
                        Text("API key Platform…")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    }
                    .buttonStyle(.plain)

                    if auth.openAIHasOAuth {
                        Button {
                            auth.disconnectOpenAIOAuth()
                            onChanged()
                        } label: {
                            Text("Disconnetti ChatGPT")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(QS.Color.surfaceHigh.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Anthropic / Claude
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(QS.Color.agentThinking)
                    Text("Anthropic / Claude")
                        .font(QS.Font.ui(12, weight: .semibold))
                    Spacer()
                    if auth.anthropicHasKey {
                        StatusChip(text: "API key", color: QS.Color.agentActive)
                    } else {
                        StatusChip(text: "non collegato", color: QS.Color.outline)
                    }
                }
                Text("Policy Anthropic (2026): il login Pro/Max di Claude Code **non** può essere riusato in app terze. Serve una API key da Console.")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        auth.loginAnthropicWithBrowser()
                    } label: {
                        Label("Apri Console + claude.ai", systemImage: "globe")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(QS.Color.agentThinking)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        auth.importAnthropicFromClaudeCodeKeychain()
                        onChanged()
                    } label: {
                        Label("Importa da Claude Code", systemImage: "key.horizontal")
                            .font(QS.Font.ui(11, weight: .medium))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Solo se in Portachiavi c’è una key Console; OAuth Pro/Max di solito è bloccato da Anthropic")
                }
            }
            .padding(12)
            .background(QS.Color.surfaceHigh.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let msg = auth.statusMessage {
                Text(msg)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.agentActive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = auth.lastError {
                Text(err)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(QS.Color.primarySolid.opacity(0.25), lineWidth: 1))
        .onAppear { auth.refreshStatus() }
    }
}

// MARK: - GitHub browser login panel

struct GitHubLoginPanel: View {
    @ObservedObject var auth: GitHubAuthService
    var onChanged: () -> Void
    @State private var clientIdDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(QS.Color.primary)
                Text("GitHub · login browser")
                    .font(QS.Font.ui(14, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
                if auth.isLoggedIn {
                    StatusChip(text: auth.login.map { "@\($0)" } ?? "CONNESSO", color: QS.Color.agentActive)
                }
            }

            Text("Come Cursor/Codex: apre il browser, autorizzi l'app, il token finisce in Keychain per push/pull.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            if !auth.hasClientId {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1) Crea un'OAuth App gratuita (solo Client ID, niente secret per Device Flow):")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                    HStack {
                        Button("Apri GitHub Developer settings") {
                            auth.openOAuthAppSettings()
                        }
                        .buttonStyle(.plain)
                        .font(QS.Font.ui(11, weight: .semibold))
                        .foregroundStyle(QS.Color.primary)
                        Text("→ New OAuth App · Callback: http://127.0.0.1")
                            .font(QS.Font.ui(10))
                            .foregroundStyle(QS.Color.outline)
                    }
                    Text("2) Incolla il Client ID qui:")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                    HStack {
                        TextField("OvXXXXXXXX…", text: $clientIdDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(QS.Font.codeSM)
                        Button("Salva Client ID") {
                            auth.clientId = clientIdDraft
                            clientIdDraft = auth.clientId
                        }
                        .buttonStyle(.plain)
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(QS.Color.primarySolid)
                    }
                }
            } else {
                Text("OAuth Client ID: \(String(auth.clientId.prefix(8)))…")
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.outline)
            }

            if auth.isAuthenticating, let code = auth.userCode {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codice da confermare su GitHub")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.outline)
                        Text(code)
                            .font(QS.Font.ui(22, weight: .bold))
                            .foregroundStyle(QS.Color.primary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copia") { auth.copyUserCode() }
                        .buttonStyle(.plain)
                        .foregroundStyle(QS.Color.onSurface)
                    Button("Riapri browser") { auth.openVerificationInBrowser() }
                        .buttonStyle(.plain)
                        .foregroundStyle(QS.Color.primary)
                    Button("Annulla") { auth.cancelLogin() }
                        .buttonStyle(.plain)
                        .foregroundStyle(QS.Color.error)
                }
                .padding(12)
                .background(QS.Color.primarySolid.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                PrimaryButton(
                    title: auth.isAuthenticating ? "In attesa browser…" : "Accedi con browser",
                    icon: "safari",
                    compact: true
                ) {
                    auth.loginWithBrowser()
                }
                .disabled(auth.isAuthenticating || !auth.hasClientId)

                GhostButton(title: "Importa da gh CLI", icon: "terminal") {
                    Task {
                        await auth.importFromGitHubCLI()
                        onChanged()
                    }
                }

                GhostButton(title: "Pagina PAT…", icon: "key") {
                    auth.openPATPageInBrowser()
                }

                if auth.isLoggedIn {
                    Button("Disconnetti") {
                        auth.logout()
                        onChanged()
                    }
                    .buttonStyle(.plain)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.error)
                }

                if auth.hasClientId {
                    Button("Cambia Client ID") {
                        clientIdDraft = auth.clientId
                        auth.clientId = ""
                    }
                    .buttonStyle(.plain)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                }
            }

            if let msg = auth.statusMessage {
                Text(msg)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.agentActive)
            }
            if let err = auth.lastError {
                Text(err)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.xl, style: .continuous)
                .stroke(auth.isLoggedIn ? QS.Color.primarySolid.opacity(0.45) : QS.Color.border, lineWidth: 1)
        )
        .onAppear {
            clientIdDraft = auth.clientId
        }
        .onChange(of: auth.statusMessage) { _, _ in
            if auth.isLoggedIn { onChanged() }
        }
    }
}

struct IntegrationCard: View {
    let item: AIIntegration
    let isConfiguring: Bool
    @Binding var apiKey: String
    var onConfigure: () -> Void
    var onSave: () -> Void
    /// Prefer saving with local field value (OpenRouter / SecureField reliability).
    var onSaveKey: ((String) -> Bool)? = nil
    var onDisconnect: () -> Void
    var onCancel: () -> Void
    @State private var testMessage: String?
    @State private var testing = false
    @State private var localKey: String = ""
    @State private var showPlainKey = false
    @State private var saveHint: String?

    private var keyPlaceholder: String {
        switch item.name {
        case "OpenRouter": return "sk-or-v1-…"
        case "GitHub": return "ghp_… / gho_… / github_pat_…"
        case "SpaceX AI", "Grok", "xAI": return "xai-…"
        case "Anthropic", "Claude": return "sk-ant-…"
        case "Gemini": return "AIza…"
        default: return "sk-…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(QS.Color.surfaceHigh)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(QS.Color.primary)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(QS.Font.ui(14, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(item.provider)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }

                Spacer()

                StatusChip(text: item.status.rawValue, color: item.status.color)
            }

            if isConfiguring {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name == "GitHub" ? "Token (PAT o da browser)" : "API Key")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    // Local state avoids SecureField drop on shared binding (esp. OpenRouter)
                    Group {
                        if showPlainKey {
                            TextField(keyPlaceholder, text: $localKey)
                        } else {
                            SecureField(keyPlaceholder, text: $localKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(QS.Font.codeSM)
                    .padding(8)
                    .background(QS.Color.backgroundDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(QS.Color.border, lineWidth: 1)
                    )
                    .onAppear {
                        localKey = apiKey
                    }
                    .onChange(of: localKey) { _, v in
                        apiKey = v
                    }

                    HStack {
                        Toggle("Mostra key", isOn: $showPlainKey)
                            .toggleStyle(.checkbox)
                            .font(QS.Font.ui(10))
                        Spacer()
                    }

                    if item.name == "OpenRouter" {
                        Text("Key da openrouter.ai/keys · formato tipico sk-or-v1-… · dopo Salva usa «Test».")
                            .font(QS.Font.ui(10))
                            .foregroundStyle(QS.Color.outline)
                    } else if item.name == "GitHub" {
                        Text("Preferisci il pannello sopra «Accedi con browser». PAT manuale resta disponibile.")
                            .font(QS.Font.ui(10))
                            .foregroundStyle(QS.Color.outline)
                    }

                    if let saveHint {
                        Text(saveHint)
                            .font(QS.Font.ui(10))
                            .foregroundStyle(saveHint.contains("salvata") || saveHint.hasPrefix("OK")
                                             ? QS.Color.agentActive : QS.Color.error)
                    }

                    HStack {
                        Button("Annulla") {
                            localKey = ""
                            onCancel()
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(QS.Color.outline)
                            .font(QS.Font.ui(12))
                        Spacer()
                        Button("Salva") {
                            let k = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let onSaveKey {
                                let ok = onSaveKey(k)
                                saveHint = ok
                                    ? "Key salvata (\(k.count) caratteri)"
                                    : "Salvataggio fallito — vedi messaggio sopra o Portachiavi"
                            } else {
                                apiKey = k
                                onSave()
                                saveHint = k.isEmpty ? "Key vuota" : "Salvataggio richiesto"
                            }
                        }
                            .buttonStyle(.plain)
                            .font(QS.Font.ui(12, weight: .semibold))
                            .foregroundStyle(QS.Color.primarySolid)
                    }
                }
            } else if item.status == .connected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let hint = item.modelHint {
                            Text(hint)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(QS.Color.surfaceHighest)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        if isTestableProvider(item.name) {
                            Button(testing ? "Test…" : "Test") {
                                testProvider(item.name)
                            }
                            .buttonStyle(.plain)
                            .font(QS.Font.ui(11, weight: .medium))
                            .foregroundStyle(QS.Color.primary)
                            .disabled(testing)
                        }
                        Button("Disconnetti", action: onDisconnect)
                            .buttonStyle(.plain)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.error)
                    }
                    if let testMessage {
                        Text(testMessage)
                            .font(QS.Font.ui(10))
                            .foregroundStyle(testMessage.hasPrefix("OK") ? QS.Color.agentActive : QS.Color.error)
                            .lineLimit(2)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Configura", action: onConfigure)
                        .buttonStyle(.plain)
                        .font(QS.Font.ui(12, weight: .medium))
                        .foregroundStyle(QS.Color.onSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(QS.Color.surfaceHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(QS.Color.border, lineWidth: 1)
                        )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.xl, style: .continuous)
                .stroke(
                    item.status == .connected ? QS.Color.primarySolid.opacity(0.45) : QS.Color.border,
                    lineWidth: 1
                )
        )
    }

    private func isTestableProvider(_ name: String) -> Bool {
        LLMProviderKind.allCases.contains { $0.keychainAccount == name }
            || ["Grok", "Codex", "Claude"].contains(name)
    }

    private func testProvider(_ name: String) {
        let kind: LLMProviderKind? = {
            if let k = LLMProviderKind.allCases.first(where: { $0.keychainAccount == name }) {
                return k
            }
            switch name {
            case "Grok", "xAI": return .spaceXAI
            case "Codex": return .openAI
            case "Claude": return .anthropic
            default: return nil
            }
        }()
        guard let kind else { return }
        testing = true
        testMessage = nil
        Task {
            let r = await LLMClient.shared.testConnection(kind)
            await MainActor.run {
                testing = false
                testMessage = r.message
            }
        }
    }
}
