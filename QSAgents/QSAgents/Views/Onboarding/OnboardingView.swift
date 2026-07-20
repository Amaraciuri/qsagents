import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var safety: SafetyGuardrails
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    var onDone: () -> Void

    @State private var step: Int = 0
    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Benvenuto in QS Agents")
                    .font(QS.Font.ui(18, weight: .semibold))
                Spacer()
                Text("\(step + 1)/\(lastStep + 1)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(20)

            Group {
                switch step {
                case 0:
                    stepCard(
                        title: "Multi-agent nativo macOS",
                        body: "Terminali PTY reali, orchestratore ⌘K, task, git e guardrail — tutto locale. In ~60 secondi: workspace → engine → primo goal.",
                        icon: "cpu"
                    )
                case 1:
                    VStack(alignment: .leading, spacing: 14) {
                        stepCard(
                            title: "Apri un workspace",
                            body: "Scegli la cartella del progetto (es. zackgame). File tree, git e coding CLI usano questa root — non la home.",
                            icon: "folder"
                        )
                        PrimaryButton(title: "Apri cartella…", icon: "folder.badge.plus") {
                            workspaces.pickAndOpen()
                        }
                        if let ws = workspaces.current {
                            Text("✓ \(ws.path)")
                                .font(QS.Font.codeSM)
                                .foregroundStyle(QS.Color.agentActive)
                        }
                    }
                case 2:
                    VStack(alignment: .leading, spacing: 14) {
                        stepCard(
                            title: "Coding engine (chi scrive il codice)",
                            body: "È diverso dal modello Home. Auto prova Claude CLI → Grok → QS API. Swarm solo se lo scegli tu o dici «avvia missione».",
                            icon: "terminal"
                        )
                        Picker("Engine", selection: $orchestrator.codingEngine) {
                            ForEach(CodingEngineKind.allCases) { kind in
                                Text(kind.menuLabel).tag(kind)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Text(orchestrator.codingEngine.help)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Suggerimento: Claude CLI = account Claude sul Mac. QS API = key da Integrazioni (es. Haiku).")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                    }
                case 3:
                    VStack(alignment: .leading, spacing: 14) {
                        stepCard(
                            title: "Integrazioni AI (opzionale)",
                            body: "Key in Keychain per orchestratore / QS API. Claude CLI può funzionare senza key QS se hai già `claude` loggato.",
                            icon: "key"
                        )
                        PrimaryButton(title: "Apri Integrazioni", icon: "puzzlepiece.extension") {
                            state.openIntegrations()
                        }
                        Text(LLMClient.shared.configuredSummary())
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    }
                default:
                    VStack(alignment: .leading, spacing: 14) {
                        stepCard(
                            title: "Sicurezza + scorciatoie goal",
                            body: "Applica il profilo DEV. In chat, «Salva scorciatoia» memorizza un goal ripetibile (ex «ricetta») — non è un menu di cucina.",
                            icon: "shield.lefthalf.filled"
                        )
                        PrimaryButton(title: "Applica setup consigliato", icon: "checkmark.shield") {
                            let paths = directories.projects.map(\.path) + workspaces.recent.map(\.path)
                            _ = safety.applyRecommendedProfile(projectPaths: paths)
                        }
                        Text("Shortcuts: ⌘K orchestratore · ⌘⇧O workspace · ⌘⇧T task · ⌘, integrazioni")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("Indietro") { step -= 1 }
                        .buttonStyle(.plain)
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
                if step < lastStep {
                    PrimaryButton(title: "Continua", icon: "arrow.right", compact: true) {
                        step += 1
                    }
                } else {
                    PrimaryButton(title: "Inizia", icon: "sparkles", compact: true) {
                        UserDefaults.standard.set(true, forKey: "qs.onboarding.done")
                        onDone()
                    }
                }
                Button("Salta") {
                    UserDefaults.standard.set(true, forKey: "qs.onboarding.done")
                    onDone()
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.outline)
            }
            .padding(20)
        }
        .frame(width: 540, height: 480)
        .background(QS.Color.surfaceContainer)
    }

    private func stepCard(title: String, body: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(QS.Color.primary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(QS.Font.ui(15, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(body)
                    .font(QS.Font.ui(12))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }
}

struct AboutView: View {
    var onClose: () -> Void
    @EnvironmentObject private var state: AppState
    @State private var showChangelog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QS Agents")
                .font(QS.Font.ui(20, weight: .bold))
            Text("Command center multi-agent nativo macOS")
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.outline)
            Text("\(AppConfig.versionLabel) · local-first · PTY · safety · LLM tools")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.onSurfaceVariant)
            Text(AppConfig.isProduction ? "Build Release" : "Build Debug")
                .font(QS.Font.mono(10))
                .foregroundStyle(QS.Color.outline)

            Button {
                showChangelog = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "newspaper.fill")
                        .foregroundStyle(QS.Color.primarySolid)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Novità · v\(AppChangelog.latest.version)")
                            .font(QS.Font.ui(12, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                        Text(AppChangelog.latest.title)
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(QS.Color.outline)
                }
                .padding(10)
                .background(QS.Color.primarySolid.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Divider()
            Text("Supporto")
                .font(QS.Font.ui(13, weight: .semibold))
            Button {
                if let url = URL(string: "mailto:\(AppConfig.supportEmail)?subject=QS%20Agents%20\(AppConfig.marketingVersion)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(AppConfig.supportEmail, systemImage: "envelope")
                    .font(QS.Font.ui(12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(QS.Color.primarySolid)

            if let privacy = AppConfig.privacyPolicyURL {
                Button {
                    NSWorkspace.shared.open(privacy)
                } label: {
                    Label("Privacy policy", systemImage: "hand.raised")
                        .font(QS.Font.ui(12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(QS.Color.primarySolid)
            }

            Divider()
            Text("Scorciatoie")
                .font(QS.Font.ui(13, weight: .semibold))
            shortcut("⌘K", "Orchestratore modal")
            shortcut("⌘⇧O", "Apri workspace")
            shortcut("⌘⇧T", "Nuova task")
            shortcut("⌘N", "Nuovo terminale")
            shortcut("⌘,", "Integrazioni")
            shortcut("⌘⇧S", "Sicurezza")
            shortcut("⌘1–5", "Viste principali")

            HStack {
                Button("Apri Novità") {
                    onClose()
                    state.openSettingsSection = "changelog"
                    state.openIntegrations()
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(12, weight: .medium))
                .foregroundStyle(QS.Color.primarySolid)
                Spacer()
                Button("Chiudi", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .sheet(isPresented: $showChangelog) {
            VStack(spacing: 0) {
                HStack {
                    Text("Novità QS Agents")
                        .font(QS.Font.ui(14, weight: .semibold))
                    Spacer()
                    Button("Chiudi") { showChangelog = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(QS.Color.outline)
                }
                .padding(14)
                Divider()
                AppChangelogView()
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack {
            Text(key)
                .font(QS.Font.codeSM)
                .foregroundStyle(QS.Color.primary)
                .frame(width: 70, alignment: .leading)
            Text(label)
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurface)
        }
    }
}
