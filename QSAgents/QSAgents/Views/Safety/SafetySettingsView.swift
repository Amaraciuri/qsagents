import SwiftUI
import AppKit

struct SafetySettingsView: View {
    @EnvironmentObject private var safety: SafetyGuardrails
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var signing: ApprovalSigningService
    @EnvironmentObject private var remote: RemoteApprovalNotifier
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @State private var filter: GuardrailCategory? = nil
    @State private var section: SafetySection = .overview
    @State private var pinDraft = ""
    @State private var pinConfirm = ""
    @State private var slackURL = ""
    @State private var pdKey = ""
    @State private var verifyMsg = ""
    @State private var setupBanner = ""
    @State private var showAuditExportConfirm = false

    enum SafetySection: String, CaseIterable, Identifiable {
        case overview, allowlist, twoPerson, remote, roles, rules, audit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .allowlist: return "Allowlist"
            case .twoPerson: return "Two-person"
            case .remote: return "Slack / PD"
            case .roles: return "Ruoli agenti"
            case .rules: return "Regole"
            case .audit: return "Audit firmato"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "shield.lefthalf.filled"
            case .allowlist: return "checkmark.shield"
            case .twoPerson: return "person.2.fill"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .roles: return "person.badge.key"
            case .rules: return "list.bullet.rectangle"
            case .audit: return "doc.text.magnifyingglass"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            main
        }
        .alert("Export audit CSV", isPresented: $showAuditExportConfirm) {
            Button("Export", role: .destructive) {
                if let url = signing.exportCSV() {
                    verifyMsg = "OK export: \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    verifyMsg = signing.lastError ?? "Export fallito"
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(ProductionDiagnostics.exportPrivacyNotice)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QS AGENTS")
                    .font(QS.Font.ui(12, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                Text("SICUREZZA")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(14)

            VStack(spacing: 2) {
                ForEach(SafetySection.allCases) { s in
                    SidebarNavRow(title: s.title, icon: s.icon, selected: section == s) {
                        section = s
                    }
                }
                Divider().overlay(QS.Color.border).padding(.vertical, 8)
                SidebarNavRow(title: L("Integrazioni"), icon: "puzzlepiece.extension", selected: false) {
                    state.openIntegrations()
                }
                SidebarNavRow(title: "Terminali", icon: "terminal", selected: false) {
                    state.showSafety = false
                    state.navigate(to: .dashboard)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
            Text("Allowlist · 2 persone · ruoli\nscout/builder/deployer")
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
                .padding(14)
        }
        .frame(width: QS.Spacing.sidebarWidth)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                Group {
                    switch section {
                    case .overview: overviewContent
                    case .allowlist: allowlistContent
                    case .twoPerson: twoPersonContent
                    case .remote: remoteContent
                    case .roles: rolesContent
                    case .rules: rulesContent
                    case .audit: auditContent
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sicurezza QS Agents")
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("Guardrail · allowlist · two-person · ruoli · Slack/PD")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                Spacer()
                Toggle("Guardrail ON", isOn: Binding(
                    get: { safety.enabled },
                    set: { safety.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                PrimaryButton(title: "Setup consigliato", icon: "star.fill", compact: true) {
                    applyRecommended()
                }
                Menu {
                    Button("Setup consigliato (DEV, usabile)") {
                        applyRecommended()
                    }
                    Button("Setup LIVE strict") {
                        applyLiveStrict()
                    }
                    Divider()
                    Button("Reset solo regole pattern") {
                        safety.resetToDefaults()
                        setupBanner = "Regole pattern e ruoli ripristinati."
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
            }

            if !setupBanner.isEmpty {
                Text(setupBanner)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.agentActive)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QS.Color.agentActive.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if safety.needsRecommendedSetup {
                HStack {
                    Text("Primo avvio: applica il profilo consigliato per non partire a zero.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.agentThinking)
                    Spacer()
                    Button("Applica ora") { applyRecommended() }
                        .buttonStyle(.plain)
                        .font(QS.Font.ui(11, weight: .semibold))
                        .foregroundStyle(QS.Color.primarySolid)
                }
                .padding(10)
                .background(QS.Color.agentThinking.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .bottom) { Rectangle().fill(QS.Color.border).frame(height: 1) }
    }

    private func projectPaths() -> [String] {
        directories.projects.map(\.path)
            + directories.bookmarks.map(\.path)
            + directories.quickAccess.map(\.path)
    }

    private func applyRecommended() {
        setupBanner = safety.applyRecommendedProfile(projectPaths: projectPaths())
    }

    private func applyLiveStrict() {
        setupBanner = safety.applyProductionStrictProfile(projectPaths: projectPaths())
    }

    // MARK: - Overview

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Recommended card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(QS.Color.agentThinking)
                    Text("Profilo consigliato")
                        .font(QS.Font.ui(13, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Spacer()
                    if safety.recommendedSetupApplied {
                        Text("APPLICATO")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.agentActive)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(QS.Color.agentActive.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("DEV + guardrail + allowlist avviso + two-person da LIVE + ruolo Builder. Ideale per lavorare ogni giorno senza spararsi i piedi.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                HStack(spacing: 10) {
                    PrimaryButton(title: "Applica setup consigliato", icon: "checkmark.seal", compact: true) {
                        applyRecommended()
                    }
                    GhostButton(title: "LIVE strict", icon: "flame") {
                        applyLiveStrict()
                    }
                }
            }
            .padding(14)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(QS.Color.primarySolid.opacity(0.35), lineWidth: 1)
            )

            // Dry-run orchestratore
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dry-run orchestratore")
                        .font(QS.Font.ui(13, weight: .semibold))
                    Text("Descrive open/run/mission senza eseguire. Anche: `dry-run on/off` in chat.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                Spacer()
                Toggle("Dry-run", isOn: Binding(
                    get: { orchestrator.dryRun.enabled },
                    set: { orchestrator.dryRun.setEnabled($0); orchestrator.tools.dryRun = $0 }
                ))
                .toggleStyle(.switch)
            }
            .padding(14)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            SectionLabel(text: "Ambiente")
            HStack(spacing: 10) {
                ForEach(AgentEnvironment.allCases) { env in
                    Button { safety.setEnvironment(env) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(env.shortLabel)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(Color(hex: env.colorHex))
                            Text(env.displayName)
                                .font(QS.Font.ui(12, weight: .semibold))
                                .foregroundStyle(QS.Color.onSurface)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(QS.Color.surfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    safety.environment == env ? Color(hex: env.colorHex).opacity(0.85) : QS.Color.border,
                                    lineWidth: safety.environment == env ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statCard("Allowlist", safety.allowlistMode.displayName, "\(safety.projectAllowlist.count) progetti")
                statCard("Two-person", safety.twoPersonEnabled ? "ON da \(safety.twoPersonFrom.shortLabel)" : "OFF", safety.isSecondPINConfigured ? "PIN ok" : "PIN mancante")
                statCard("Ruolo default", safety.defaultAgentRole.displayName, "\(safety.rolePolicies.count) policy")
            }

            SectionLabel(text: "Cosa è coperto")
            Text("• Pattern rules (DB, git, rm, cloud)\n• Allowlist path progetti\n• Matrice permessi per ruolo (scout non tocca DB)\n• Conferma 1 persona o 2 persone su LIVE\n• Log firmato + Slack/PagerDuty")
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
    }

    private func statCard(_ t: String, _ v: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            Text(v).font(QS.Font.ui(13, weight: .semibold)).foregroundStyle(QS.Color.onSurface)
            Text(s).font(QS.Font.ui(11)).foregroundStyle(QS.Color.onSurfaceVariant)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(QS.Color.border, lineWidth: 1))
    }

    // MARK: - Allowlist

    private var allowlistContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Modalità allowlist")
            Picker("Modo", selection: Binding(
                get: { safety.allowlistMode },
                set: { safety.allowlistMode = $0; safety.persist() }
            )) {
                ForEach(AllowlistMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Text(allowlistHint)
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            HStack {
                PrimaryButton(title: "Aggiungi cartella…", icon: "folder.badge.plus", compact: true) {
                    pickFolder()
                }
                GhostButton(title: "Importa progetti scansionati", icon: "arrow.down.doc") {
                    safety.importAllowlist(from: directories.projects.map(\.path))
                    safety.importAllowlist(from: directories.bookmarks.map(\.path))
                }
            }

            SectionLabel(text: "Progetti autorizzati (\(safety.projectAllowlist.count))")
            if safety.projectAllowlist.isEmpty {
                Text("Lista vuota. Con modalità «Blocca» nessun terminale fuori lista potrà aprire/eseguire.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            }
            ForEach(safety.projectAllowlist) { entry in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(QS.Color.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(QS.Font.ui(12, weight: .semibold)).foregroundStyle(QS.Color.onSurface)
                        Text(entry.path).font(QS.Font.codeSM).foregroundStyle(QS.Color.outline).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        safety.removeAllowlist(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(QS.Color.agentError)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var allowlistHint: String {
        switch safety.allowlistMode {
        case .off: return "Allowlist disattiva: si può lavorare ovunque (restano le altre regole)."
        case .warn: return "Avvisa se cwd/path non è in lista, ma non blocca."
        case .enforce: return "Blocca apertura terminali e comandi fuori dai path autorizzati."
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi all'allowlist"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            safety.addAllowlistPath(url.path)
        }
    }

    // MARK: - Two person

    private var twoPersonContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Abilita two-person rule", isOn: Binding(
                get: { safety.twoPersonEnabled },
                set: { safety.twoPersonEnabled = $0; safety.persist() }
            ))
            .toggleStyle(.switch)

            Text("Da quale ambiente in su le conferme diventano a 2 persone (e le regole dualConfirm si attivano):")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            Picker("Da ambiente", selection: Binding(
                get: { safety.twoPersonFrom },
                set: { safety.twoPersonFrom = $0; safety.persist() }
            )) {
                ForEach(AgentEnvironment.allCases) { e in
                    Text(e.displayName).tag(e)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Secondo approvatore")
                TextField("Nome (es. Tech Lead)", text: Binding(
                    get: { safety.secondApproverName },
                    set: { safety.secondApproverName = $0; safety.persist() }
                ))
                .textFieldStyle(.roundedBorder)

                Text(safety.isSecondPINConfigured ? "PIN configurato ✓" : "PIN non configurato — obbligatorio per 2ª approvazione")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(safety.isSecondPINConfigured ? QS.Color.agentActive : QS.Color.agentThinking)

                SecureField("Nuovo PIN (min 4 cifre)", text: $pinDraft)
                    .textFieldStyle(.roundedBorder)
                SecureField("Conferma PIN", text: $pinConfirm)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    PrimaryButton(title: "Salva PIN", icon: "key", compact: true) {
                        guard pinDraft.count >= 4, pinDraft == pinConfirm else { return }
                        safety.setSecondApproverPIN(pinDraft)
                        pinDraft = ""
                        pinConfirm = ""
                    }
                    if safety.isSecondPINConfigured {
                        GhostButton(title: "Rimuovi PIN", icon: "trash") {
                            safety.clearSecondApproverPIN()
                        }
                    }
                }
            }
            .padding(14)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("Flusso: 1ª persona approva → 2ª persona diversa inserisce nome + PIN → comando eseguito. Stesso nome bloccato.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.outline)
        }
    }

    // MARK: - Roles

    private var rolesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Ruolo default per nuovi terminali")
            Picker("Default", selection: Binding(
                get: { safety.defaultAgentRole },
                set: { safety.defaultAgentRole = $0; safety.persist() }
            )) {
                ForEach(AgentRole.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .labelsHidden()

            SectionLabel(text: "Matrice permessi")
            ForEach(safety.rolePolicies) { policy in
                roleCard(policy)
            }
        }
    }

    private func roleCard(_ policy: AgentRolePolicy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: policy.role.icon)
                    .foregroundStyle(QS.Color.primary)
                Text(policy.role.displayName)
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
            }
            Text(policy.role.blurb)
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                roleToggle("DB distruttivo", policy.canDatabaseDestructive) { v in
                    var p = policy; p.canDatabaseDestructive = v; safety.updateRolePolicy(p)
                }
                roleToggle("rm -rf / FS", policy.canFilesystemDestructive) { v in
                    var p = policy; p.canFilesystemDestructive = v; safety.updateRolePolicy(p)
                }
                roleToggle("Force-push git", policy.canGitForce) { v in
                    var p = policy; p.canGitForce = v; safety.updateRolePolicy(p)
                }
                roleToggle("Cloud destroy", policy.canCloudDestroy) { v in
                    var p = policy; p.canCloudDestroy = v; safety.updateRolePolicy(p)
                }
                roleToggle("Deploy", policy.canDeploy) { v in
                    var p = policy; p.canDeploy = v; safety.updateRolePolicy(p)
                }
                roleToggle("Dump secrets", policy.canExposeSecrets) { v in
                    var p = policy; p.canExposeSecrets = v; safety.updateRolePolicy(p)
                }
            }
        }
        .padding(14)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QS.Color.border, lineWidth: 1))
    }

    private func roleToggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(QS.Font.ui(11))
            .foregroundStyle(QS.Color.onSurfaceVariant)
    }

    // MARK: - Rules

    private var filteredRules: [GuardrailRule] {
        guard let filter else { return safety.rules }
        return safety.rules.filter { $0.category == filter }
    }

    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Regole pattern (\(filteredRules.count))")
                Spacer()
                Picker("Cat", selection: $filter) {
                    Text("Tutte").tag(Optional<GuardrailCategory>.none)
                    ForEach(GuardrailCategory.allCases) { c in
                        Text(c.displayName).tag(Optional(c))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            ForEach(filteredRules) { rule in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { on in
                            var r = rule; r.enabled = on; safety.updateRule(r)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(rule.name)
                                .font(QS.Font.ui(12, weight: .semibold))
                                .foregroundStyle(QS.Color.onSurface)
                            Text(rule.severity.displayName.uppercased())
                                .font(QS.Font.labelXS)
                                .foregroundStyle(severityColor(rule.severity))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(severityColor(rule.severity).opacity(0.15))
                                .clipShape(Capsule())
                            Text("da \(rule.appliesFrom.shortLabel)")
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.outline)
                        }
                        Text(rule.description)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                    }
                    Spacer()
                }
                .padding(12)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(rule.enabled ? 1 : 0.45)
            }
        }
    }

    private func severityColor(_ s: GuardrailSeverity) -> Color {
        switch s {
        case .info: return QS.Color.outline
        case .warn: return QS.Color.agentThinking
        case .confirm: return QS.Color.primarySolid
        case .dualConfirm: return QS.Color.secondary
        case .block: return QS.Color.agentError
        }
    }

    // MARK: - Remote Slack / PD

    private var remoteContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notifiche remote per two-person: Slack Incoming Webhook e/o PagerDuty Events API v2.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)

            // Slack
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Slack")
                    Spacer()
                    Toggle("Attivo", isOn: Binding(
                        get: { remote.slackEnabled },
                        set: { remote.slackEnabled = $0; remote.persistFlags() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text(remote.hasSlackWebhook ? "Webhook salvato in Keychain ✓" : "Nessun webhook")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(remote.hasSlackWebhook ? QS.Color.agentActive : QS.Color.outline)
                SecureField("https://hooks.slack.com/services/…", text: $slackURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Canale hint (solo testo)", text: Binding(
                    get: { remote.slackChannelHint },
                    set: { remote.slackChannelHint = $0; remote.persistFlags() }
                ))
                .textFieldStyle(.roundedBorder)
                HStack {
                    PrimaryButton(title: "Salva webhook", icon: "link", compact: true) {
                        remote.setSlackWebhook(slackURL)
                        slackURL = ""
                    }
                    GhostButton(title: "Rimuovi", icon: "trash") {
                        remote.setSlackWebhook("")
                    }
                    GhostButton(title: "Test Slack", icon: "paperplane") {
                        Task {
                            _ = await remote.notifyDualPending(
                                command: "echo QS Agents test approval",
                                path: nil,
                                environment: "TEST",
                                ruleName: "Test",
                                firstApproverHint: NSFullUserName(),
                                host: ProcessInfo.processInfo.hostName
                            )
                        }
                    }
                }
            }
            .padding(14)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // PagerDuty
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "PagerDuty")
                    Spacer()
                    Toggle("Attivo", isOn: Binding(
                        get: { remote.pagerDutyEnabled },
                        set: { remote.pagerDutyEnabled = $0; remote.persistFlags() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text(remote.hasPagerDutyKey ? "Routing key in Keychain ✓" : "Nessuna routing key")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(remote.hasPagerDutyKey ? QS.Color.agentActive : QS.Color.outline)
                SecureField("Routing key Events API v2", text: $pdKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    PrimaryButton(title: "Salva key", icon: "key", compact: true) {
                        remote.setPagerDutyRoutingKey(pdKey)
                        pdKey = ""
                    }
                    GhostButton(title: "Rimuovi", icon: "trash") {
                        remote.setPagerDutyRoutingKey("")
                    }
                }
                Text("Su dual-approval apre un incident; resolve automatico su approve/deny.")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(14)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let err = remote.lastError {
                Text(err).font(QS.Font.ui(11)).foregroundStyle(QS.Color.agentError)
            }
            Text("Status: \(remote.lastStatus)")
                .font(QS.Font.codeSM)
                .foregroundStyle(QS.Color.outline)
        }
    }

    // MARK: - Audit (in-memory + signed chain)

    private var auditContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Log firmato (HMAC chain)")
                Text(signing.logFilePath)
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.outline)
                    .textSelection(.enabled)
                HStack {
                    PrimaryButton(title: "Verifica catena", icon: "checkmark.seal", compact: true) {
                        let r = signing.verifyChain()
                        verifyMsg = r.message
                    }
                    GhostButton(title: "Apri in Finder", icon: "folder") {
                        signing.revealInFinder()
                    }
                    GhostButton(title: "Export CSV", icon: "square.and.arrow.up") {
                        showAuditExportConfirm = true
                    }
                    if !safety.sessionApprovals.isEmpty {
                        GhostButton(title: "Reset approvazioni sessione", icon: "trash") {
                            safety.clearSessionApprovals()
                        }
                    }
                }
                if !verifyMsg.isEmpty {
                    Text(verifyMsg)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(verifyMsg.hasPrefix("OK") ? QS.Color.agentActive : QS.Color.agentError)
                }
                if let err = signing.lastError {
                    Text(err).font(QS.Font.ui(11)).foregroundStyle(QS.Color.agentError)
                }
            }
            .padding(12)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            SectionLabel(text: "Record firmati recenti")
            if signing.recentRecords.isEmpty {
                Text("Nessun record firmato ancora. Le approvazioni generano append su JSONL.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            } else {
                ForEach(signing.recentRecords.prefix(25)) { rec in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rec.payload.event)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.primary)
                            Spacer()
                            Text(rec.payload.timestamp)
                                .font(QS.Font.ui(10))
                                .foregroundStyle(QS.Color.outline)
                        }
                        Text(rec.payload.command)
                            .font(QS.Font.codeSM)
                            .foregroundStyle(QS.Color.onSurface)
                            .lineLimit(2)
                        Text("sig \(rec.signature.prefix(16))… · chain \(rec.chainHash.prefix(12))…")
                            .font(QS.Font.ui(9))
                            .foregroundStyle(QS.Color.outline)
                    }
                    .padding(8)
                    .background(QS.Color.surfaceContainer.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            SectionLabel(text: "Audit sessione (UI)")
            if safety.auditLog.isEmpty {
                Text("Nessun evento sessione.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            } else {
                ForEach(safety.auditLog.prefix(20)) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.decision)
                            .font(QS.Font.labelXS)
                            .foregroundStyle(entry.decision.contains("BLOCK") ? QS.Color.agentError : QS.Color.agentThinking)
                            .frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.command)
                                .font(QS.Font.codeSM)
                                .foregroundStyle(QS.Color.onSurface)
                                .lineLimit(2)
                            Text("\(entry.environment.shortLabel) · \(entry.source) · \(entry.role ?? "—")")
                                .font(QS.Font.ui(10))
                                .foregroundStyle(QS.Color.outline)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(QS.Color.surfaceContainer.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

// MARK: - Confirm / dual sheet

struct SafetyConfirmSheet: View {
    /// Snapshot at open; live state from safety.pendingConfirm for dual step transitions.
    let pending: SafetyGuardrails.PendingConfirm
    @EnvironmentObject private var safety: SafetyGuardrails
    @EnvironmentObject private var terminals: TerminalManager
    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String = NSFullUserName()
    @State private var secondName: String = ""
    @State private var secondPIN: String = ""
    @State private var remoteCodeField: String = ""
    @State private var error: String?

    private var live: SafetyGuardrails.PendingConfirm {
        safety.pendingConfirm ?? pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: live.requiresDual ? "person.2.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(live.requiresDual ? QS.Color.secondary : QS.Color.agentThinking)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.requiresDual ? "Two-person rule" : "Conferma umana")
                        .font(QS.Font.ui(16, weight: .semibold))
                    Text("QS Agents · \(live.rule.name) · \(live.role.displayName)")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                }
            }

            Text(LocalizedStringKey(live.message))
                .font(QS.Font.body)
                .foregroundStyle(QS.Color.onSurface)

            commandBox(live)

            if live.requiresDual && live.awaitingSecond {
                secondStep(live)
            } else if live.requiresDual {
                firstStepDual
            } else {
                singleStep(live)
            }

            if let error {
                Text(error)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.agentError)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(QS.Color.surfaceLow)
    }

    private func commandBox(_ p: SafetyGuardrails.PendingConfirm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comando")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            Text(p.command)
                .font(QS.Font.codeMD)
                .foregroundStyle(QS.Color.syntaxString)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.backgroundDeep)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let path = p.path {
                Text("Path: \(path)")
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.outline)
            }
        }
    }

    private func singleStep(_ p: SafetyGuardrails.PendingConfirm) -> some View {
        HStack {
            Button("Annulla") {
                safety.denyPending()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Approva e esegui") {
                if safety.approveFirst(by: firstName) {
                    terminals.runApproved(cmd: p.command, path: p.path, role: p.role, source: p.source)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(QS.Color.agentError)
        }
    }

    private var firstStepDual: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Passo 1/2 — Prima approvazione (operatore)")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            TextField("Il tuo nome", text: $firstName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Annulla") {
                    safety.denyPending()
                    dismiss()
                }
                Spacer()
                Button("1ª approvazione →") {
                    _ = safety.approveFirst(by: firstName)
                }
                .buttonStyle(.borderedProminent)
                .tint(QS.Color.primarySolid)
            }
        }
    }

    private func secondStep(_ p: SafetyGuardrails.PendingConfirm) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Passo 2/2 — \(safety.secondApproverName) (persona diversa)")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.secondary)
            if let first = p.firstApproverName {
                Text("1ª firma: \(first)")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            }
            if let code = p.remoteCode {
                Text("Codice inviato su Slack: \(code)")
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.primary)
            }
            TextField("Nome 2º approvatore", text: $secondName)
                .textFieldStyle(.roundedBorder)
            SecureField("PIN locale", text: $secondPIN)
                .textFieldStyle(.roundedBorder)
            TextField("Oppure codice remoto Slack (XXXX-XXXX)", text: $remoteCodeField)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Annulla") {
                    safety.denyPending()
                    dismiss()
                }
                Spacer()
                Button("2ª approvazione e esegui") {
                    let code = remoteCodeField.isEmpty ? nil : remoteCodeField
                    let result = safety.approveSecond(
                        name: secondName,
                        pin: secondPIN,
                        remoteCode: code
                    )
                    if result.ok {
                        terminals.runApproved(cmd: p.command, path: p.path, role: p.role, source: p.source)
                        dismiss()
                    } else {
                        error = result.error
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(QS.Color.secondaryContainer)
            }
            Text("Usa PIN locale **oppure** il codice one-time da Slack (30 min).")
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
        }
    }
}

struct SafetyPendingBanner: View {
    @EnvironmentObject private var safety: SafetyGuardrails
    @EnvironmentObject private var terminals: TerminalManager
    @State private var showSheet = false

    var body: some View {
        if let p = safety.pendingConfirm {
            HStack(spacing: 12) {
                Image(systemName: p.requiresDual ? "person.2.fill" : "shield.lefthalf.filled")
                    .foregroundStyle(p.requiresDual ? QS.Color.secondary : QS.Color.agentThinking)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.awaitingSecond ? "Serve 2ª firma: \(p.rule.name)" : "Conferma guardrail: \(p.rule.name)")
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(p.command)
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                }
                Spacer()
                Button("Nega") { safety.denyPending() }
                    .buttonStyle(.plain)
                    .foregroundStyle(QS.Color.outline)
                Button(p.awaitingSecond ? "2ª firma…" : "Approva…") {
                    showSheet = true
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(p.requiresDual ? QS.Color.secondaryContainer : QS.Color.agentError)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(QS.Color.agentThinking.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle().fill(QS.Color.agentThinking.opacity(0.4)).frame(height: 1)
            }
            .sheet(isPresented: $showSheet) {
                if let pending = safety.pendingConfirm {
                    SafetyConfirmSheet(pending: pending)
                        .environmentObject(safety)
                        .environmentObject(terminals)
                }
            }
        }
    }
}
