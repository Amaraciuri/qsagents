import SwiftUI
import AppKit

/// Complete GDPR / privacy hub for QS Agents (local-first macOS app).
struct GDPRPrivacyView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: GDPRSection = .overview
    @State private var statusMessage: String = ""
    @State private var showWipeConfirm = false

    private enum GDPRSection: String, CaseIterable, Identifiable {
        case overview
        case dataMap
        case legalBases
        case rights
        case thirdParties
        case retention
        case yourControls
        case policy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Panoramica"
            case .dataMap: return "Mappa dati"
            case .legalBases: return "Basi giuridiche"
            case .rights: return "I tuoi diritti"
            case .thirdParties: return "Terze parti"
            case .retention: return "Conservazione"
            case .yourControls: return "I tuoi controlli"
            case .policy: return "Informativa"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "shield.checkered"
            case .dataMap: return "cylinder.split.1x2"
            case .legalBases: return "scalemass"
            case .rights: return "person.crop.circle.badge.checkmark"
            case .thirdParties: return "network"
            case .retention: return "clock.arrow.circlepath"
            case .yourControls: return "slider.horizontal.3"
            case .policy: return "doc.plaintext"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            gdprSubnav
            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
        .alert("Cancellare tutti i dati locali?", isPresented: $showWipeConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Elimina tutto", role: .destructive) {
                wipeLocalData()
            }
        } message: {
            Text("Verranno rimossi task, memoria progetto, preferenze app, indici knowledge e log in Application Support. Le API key in Keychain richiedono conferma separata.")
        }
    }

    // MARK: - Sub-nav

    private var gdprSubnav: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GDPR")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(GDPRSection.allCases) { s in
                        SidebarNavRow(
                            title: s.title,
                            icon: s.icon,
                            selected: section == s
                        ) {
                            section = s
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.agentActive)
                    .padding(10)
            }
        }
        .frame(width: 200)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                Group {
                    switch section {
                    case .overview: overviewBlock
                    case .dataMap: dataMapBlock
                    case .legalBases: legalBasesBlock
                    case .rights: rightsBlock
                    case .thirdParties: thirdPartiesBlock
                    case .retention: retentionBlock
                    case .yourControls: controlsBlock
                    case .policy: policyBlock
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GDPR & Privacy")
                .font(QS.Font.ui(18, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text("Trasparenza sul trattamento dati in QS Agents · Regolamento (UE) 2016/679")
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    // MARK: - Sections

    private var overviewBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(
                title: "Principio: local-first",
                body: """
                QS Agents è un’app desktop macOS. La maggior parte dei dati resta sul tuo Mac (Application Support e Keychain). \
                Non gestiamo un account cloud QS Agents: non c’è un backend nostro che conserva le tue chat o i file del progetto.

                I dati escono dal dispositivo solo se:
                • usi un provider LLM (OpenAI, Anthropic, SpaceX AI/Grok, Gemini, OpenRouter) — invii testo/prompt;
                • usi GitHub (token / device flow) o notifiche Slack / PagerDuty che configuri tu;
                • abiliti il riconoscimento vocale online di Apple (se non on-device).
                """
            )

            card(
                title: "Titolare del trattamento",
                body: """
                **Titolare:** l’operatore / sviluppatore di QS Agents (installazione locale).
                Per l’uso professionale, il titolare è tipicamente la tua organizzazione (decidi finalità e mezzi del trattamento sui device aziendali).

                **Contatto privacy:** \(AppConfig.privacyEmail)
                **Supporto:** \(AppConfig.supportEmail)
                **DPO:** nominato solo se obbligatorio (art. 37 GDPR); altrimenti punto di contatto privacy sopra.
                """
            )

            HStack(spacing: 12) {
                infoPill("Base legale tipica", "Contratto / legittimo interesse / consenso (voce, marketing)")
                infoPill("Trasferimenti extra-UE", "Solo via provider LLM / GitHub se scelti da te")
            }

            card(
                title: "Cosa non facciamo",
                body: """
                • Non vendiamo dati personali
                • Non mostriamo pubblicità comportamentale
                • Non creiamo profili di marketing da codice o conversazioni
                • Non carichiamo automaticamente l’intero repository su server QS (non esistono)
                """
            )
        }
    }

    private var dataMapBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Dove stanno i dati sul Mac")

            dataRow(
                "Keychain",
                "API key LLM, token GitHub, eventuale PIN two-person",
                "Accesso protetto dal sistema · non in chiaro sul disco app"
            )
            dataRow(
                "Application Support/QSAgents/data/",
                "Task board, memoria progetto, preferenze provider, knowledge cache (sessione), notifiche",
                AppConfig.dataDirectory.path
            )
            dataRow(
                "Application Support/QSAgents/logs/",
                "Log diagnostici, audit firmato, e crashes.log solo se abiliti «Log crash locali» in Supporto",
                AppConfig.logsDirectory.path
            )
            dataRow(
                "UserDefaults",
                "Preferenze UI (sidebar, onboarding, provider default, contatori token)",
                "Dominio app com.qsagents.mac"
            )
            dataRow(
                "Workspace sul disco",
                "I tuoi file di progetto: QS Agents li legge/scrive solo dove apri un workspace e i tool lo consentono",
                "Path scelti da te"
            )
            dataRow(
                "Microfono / Speech",
                "Audio processato in locale o da framework Apple; trascrizione può andare ai servizi Apple se non on-device",
                "TCC Privacy → Microfono / Riconoscimento vocale"
            )

            card(
                title: "Categorie di dati",
                body: """
                • **Identificativi tecnici:** hostname, username OS (system probe), path workspace  
                • **Contenuti di lavoro:** testo chat orchestratore, goal swarm, task, snippet knowledge, output terminali  
                • **Credenziali:** API key e token (Keychain)  
                • **Metadati d’uso:** conteggio token / stima costo (locale)  
                • **Dati biometrici/voce:** solo se attivi il microfono (trattamento legato al riconoscimento vocale)
                """
            )
        }
    }

    private var legalBasesBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(
                title: "Art. 6 GDPR — basi giuridiche (uso tipico)",
                body: """
                | Trattamento | Base |
                |-------------|------|
                | Esecuzione tool, terminali, task sul tuo Mac | **Esecuzione di un contratto** / misure precontrattuali (uso del software) o **legittimo interesse** (produttività sviluppatore) bilanciato |
                | API key e preferenze salvate localmente | **Contratto** / legittimo interesse |
                | Invio prompt a LLM di terze parti | **Contratto** con te + **istruzioni** tue; se i prompt contengono dati di terzi, valuti tu le basi e i DPA col provider |
                | Microfono e speech | **Consenso** (permesso TCC) revocabile in Impostazioni Sistema |
                | Notifiche Slack / PagerDuty | **Contratto** / legittimo interesse operativo, solo se configurate |
                | Log di sicurezza / audit firmato | **Legittimo interesse** (sicurezza, accountability) o obbligo legale se applicabile |

                Non trattiamo categorie particolari (art. 9) di proposito. Evita di incollare dati sanitari, biometrici o giudiziari nei prompt.
                """
            )

            card(
                title: "Ruoli (art. 4, 28)",
                body: """
                • **Tu / la tua org:** titolare per i dati dei progetti e delle persone che inserisci nei prompt.  
                • **Provider LLM / GitHub / Slack:** responsabili o titolari autonomi a seconda del contratto (vedi le loro privacy policy e DPA).  
                • **QS Agents (software locale):** non opera un servizio cloud di hosting dei tuoi dati.
                """
            )
        }
    }

    private var rightsBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Diritti dell’interessato (art. 12–22)")

            rightCard("Accesso (15)", "Puoi vedere cosa è memorizzato localmente (cartelle sotto Application Support) e le integrazioni attive in app.")
            rightCard("Rettifica (16)", "Modifica task, preferenze e file del progetto come preferisci; le chat LLM non sono un archivio immutabile nostro.")
            rightCard("Cancellazione (17)", "Usa «Elimina dati locali» in Controlli, svuota Keychain dalle integrazioni, e disinstalla l’app. Chiedi cancellazione anche ai provider LLM se hai account lì.")
            rightCard("Limitazione (18)", "Disattiva integrazioni, dry-run orchestratore, e non inviare dati sensibili ai provider.")
            rightCard("Portabilità (20)", "Esporta i JSON locali (Export dati) e i file del workspace: sono già in formati aperti.")
            rightCard("Opposizione (21)", "Smetti di usare LLM cloud, microfono, Slack/PD; l’app continua in modalità locale dove possibile.")
            rightCard("Revoca consenso", "Impostazioni Sistema → Privacy → Microfono / Riconoscimento vocale → disattiva QS Agents.")
            rightCard("Reclamo", "Hai diritto di proporre reclamo all’autorità di controllo (in Italia: Garante per la protezione dei dati personali — www.garanteprivacy.it).")
        }
    }

    private var thirdPartiesBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(
                title: "Destinatari e sub-responsabili (solo se li attivi)",
                body: """
                **LLM**
                • SpaceX AI / xAI (Grok) — api.x.ai  
                • OpenAI — api.openai.com  
                • Anthropic — api.anthropic.com  
                • Google Gemini — generativelanguage.googleapis.com  
                • OpenRouter — openrouter.ai  

                **Sviluppo / git**
                • GitHub (device flow OAuth o PAT) — api.github.com  

                **Operazioni (opzionali)**
                • Slack incoming webhook  
                • PagerDuty  

                **Apple**
                • Speech framework / eventuale riconoscimento cloud se non on-device  
                • Keychain e TCC del sistema  

                Ogni provider ha propria informativa e sede (spesso USA). Per trasferimenti extra-UE si applicano le garanzie del provider (SCC, DPF, ecc.): consulta i loro DPA prima di dati personali di clienti.
                """
            )

            card(
                title: "Cosa invii quando usi un LLM",
                body: """
                Messaggi di chat, goal Swarm, snippet di codice/file che i tool o l’agent includono nel contesto, e metadati tecnici minimi della richiesta API. \
                Non inviamo l’intera Keychain né i file non letti dai tool.

                **Consiglio:** redigi i segreti; QS Agents tenta di redarre pattern tipo sk-… nei log, ma non sostituisce la tua diligenza.
                """
            )
        }
    }

    private var retentionBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(
                title: "Tempi di conservazione",
                body: """
                | Dato | Conservazione |
                |------|----------------|
                | Task, memoria progetto, preferenze | Fino a cancellazione da te o wipe dati |
                | Knowledge index in RAM/cache sessione | Sessione / finché non re-indicizzi o wipe |
                | Log e audit firmato | Fino a rotazione/cancellazione manuale o wipe |
                | API key in Keychain | Fino a disconnect integrazione o rimozione Keychain |
                | Contatori token / costo | Locali finché non resetti usage o wipe |
                | Dati presso LLM / GitHub | Secondo policy del provider (non sotto controllo QS Agents) |

                Non applichiamo retention cloud perché non ospitiamo i tuoi dati su server QS.
                """
            )
        }
    }

    private var controlsBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Azioni immediate")

            card(
                title: "Esporta dati locali (portabilità)",
                body: "Copia la cartella dati QS Agents sul Desktop come archivio leggibile (JSON e log)."
            )

            HStack(spacing: 10) {
                PrimaryButton(title: "Esporta dati…", icon: "square.and.arrow.up", compact: true) {
                    exportLocalData()
                }
                GhostButton(title: "Apri cartella dati", icon: "folder") {
                    NSWorkspace.shared.open(AppConfig.dataDirectory)
                }
                GhostButton(title: "Apri cartella log", icon: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.open(AppConfig.logsDirectory)
                }
            }

            card(
                title: "Cancellazione (diritto all’oblio — locale)",
                body: """
                1. Disconnect delle integrazioni (rimuove key da Keychain dove supportato)  
                2. Elimina dati Application Support  
                3. Opzionale: disinstalla l’app  
                4. Richiedi cancellazione anche agli account OpenAI/Anthropic/GitHub se necessario
                """
            )

            HStack(spacing: 10) {
                Button {
                    showWipeConfirm = true
                } label: {
                    Label("Elimina tutti i dati locali", systemImage: "trash")
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(QS.Color.error)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                GhostButton(title: "Apri Integrazioni (key)", icon: "key") {
                    state.openIntegrations()
                }
                GhostButton(title: "Privacy microfono", icon: "mic") {
                    // reuse voice if available via settings deep link strings
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            card(
                title: "Minimizzazione (consigli pratici)",
                body: """
                • Non incollare elenchi clienti o segreti nei goal Swarm  
                • Usa dry-run orchestratore in ambienti sensibili  
                • Preferisci provider con DPA e data retention breve  
                • Spegni speech se non serve  
                • Limita allowlist path in Sicurezza
                """
            )
        }
    }

    private var policyBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(
                title: "Informativa privacy — QS Agents (sintesi completa)",
                body: policyFullText
            )

            Text("Ultimo aggiornamento: 2026-07-19 · Versione informativa 1.1")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)

            HStack(spacing: 10) {
                GhostButton(title: "Email privacy", icon: "envelope") {
                    if let url = URL(string: "mailto:\(AppConfig.privacyEmail)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if let privacy = AppConfig.privacyPolicyURL {
                    GhostButton(title: "Apri policy web", icon: "safari") {
                        NSWorkspace.shared.open(privacy)
                    }
                }
                GhostButton(title: "Copia informativa", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(policyFullText, forType: .string)
                    statusMessage = "Informativa copiata"
                }
            }
        }
    }

    private var policyFullText: String {
        """
        INFORMATIVA PRIVACY — QS AGENTS (macOS)

        1. Titolare
        Il software QS Agents è eseguito localmente sul dispositivo dell’utente. In assenza di un backend QS Agents, il titolare del trattamento dei dati presenti sul device e nei progetti è l’utente o la sua organizzazione. Contatto privacy: \(AppConfig.privacyEmail). Supporto: \(AppConfig.supportEmail).

        2. Finalità
        Fornire un ambiente multi-agent per sviluppo software: terminali, orchestrazione, task, swarm, knowledge locale, integrazioni LLM/GitHub, guardrail di sicurezza.

        3. Categorie di dati
        Credenziali API (Keychain); path e contenuti di workspace letti/modificati su istruzione; messaggi all’orchestratore e agli agent; task e memoria progetto; log e audit; metriche di sistema non invasive (CPU/RAM); audio/trascrizioni se microfono attivo; token e stime di costo d’uso LLM.

        4. Basi giuridiche
        Esecuzione del contratto di utilizzo del software e legittimo interesse alla produttività e sicurezza; consenso per microfono/riconoscimento vocale; ove richiesto, adempimento di obblighi legali per log di sicurezza.

        5. Modalità e luogo
        Trattamento prevalentemente locale. Comunicazione a terzi solo se l’utente configura e usa integrazioni (LLM, GitHub, Slack, PagerDuty, servizi Apple Speech).

        6. Conservazione
        Fino a cancellazione da parte dell’utente, wipe dati o disinstallazione; presso i terzi secondo le loro policy.

        7. Diritti
        Accesso, rettifica, cancellazione, limitazione, portabilità, opposizione, revoca del consenso, reclamo al Garante. Esercizio: tramite controlli in-app (questa sezione) e Impostazioni Sistema / account dei provider.

        8. Sicurezza
        Keychain OS, guardrail comandi, allowlist path, optional two-person rule e audit firmato. Nessuna misura è assoluta: l’utente resta responsabile dell’uso su dati sensibili.

        9. Minori
        Il prodotto è destinato a professionisti; non è rivolto a minori di 16 anni.

        10. Modifiche
        L’informativa può essere aggiornata con il software. La data in calce indica la revisione corrente.
        """
    }

    // MARK: - Actions

    private func exportLocalData() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Esporta qui"
        panel.message = "Scegli la cartella di destinazione per la copia dei dati QS Agents"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = dest.appendingPathComponent("QSAgents-export-\(stamp)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let dataDir = AppConfig.dataDirectory
            let logsDir = AppConfig.logsDirectory
            if fm.fileExists(atPath: dataDir.path) {
                try fm.copyItem(at: dataDir, to: out.appendingPathComponent("data", isDirectory: true))
            }
            if fm.fileExists(atPath: logsDir.path) {
                try fm.copyItem(at: logsDir, to: out.appendingPathComponent("logs", isDirectory: true))
            }
            let readme = """
            QS Agents data export
            Date: \(Date())
            Bundle: com.qsagents.mac
            Note: API keys are NOT included (Keychain). Re-export after disconnect if needed for audit.
            """
            try readme.write(to: out.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            statusMessage = "Export completato: \(out.lastPathComponent)"
            NSWorkspace.shared.open(out)
        } catch {
            statusMessage = "Export fallito: \(error.localizedDescription)"
        }
    }

    private func wipeLocalData() {
        let fm = FileManager.default
        var errors: [String] = []
        for dir in [AppConfig.dataDirectory, AppConfig.logsDirectory] {
            if fm.fileExists(atPath: dir.path) {
                do {
                    let items = try fm.contentsOfDirectory(atPath: dir.path)
                    for item in items {
                        let p = dir.appendingPathComponent(item)
                        try fm.removeItem(at: p)
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
        }
        // Soft-clear common UserDefaults keys for this app
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("qs.") || $0.hasPrefix("QS")
        }
        for k in keys { defaults.removeObject(forKey: k) }

        if errors.isEmpty {
            statusMessage = "Dati locali eliminati. Riavvia l’app. Scollega le integrazioni per rimuovere le key."
        } else {
            statusMessage = "Wipe parziale: \(errors.joined(separator: "; "))"
        }
    }

    // MARK: - UI bits

    private func card(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(QS.Font.ui(14, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text(LocalizedStringKey(body))
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QS.Color.border, lineWidth: 1))
    }

    private func dataRow(_ where_: String, _ what: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(where_)
                .font(QS.Font.ui(12, weight: .semibold))
                .foregroundStyle(QS.Color.primarySolid)
            Text(what)
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurface)
            Text(detail)
                .font(QS.Font.mono(10))
                .foregroundStyle(QS.Color.outline)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rightCard(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(QS.Color.agentActive)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(body)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func infoPill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            Text(value)
                .font(QS.Font.ui(11, weight: .medium))
                .foregroundStyle(QS.Color.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.primarySolid.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Docs & Support (same sidebar pattern)

struct DocsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Documentazione")
                    .font(QS.Font.ui(18, weight: .semibold))
                Text("Guide rapide integrate. Per il piano prodotto vedi anche docs/ nel repository.")
                    .font(QS.Font.ui(12))
                    .foregroundStyle(QS.Color.onSurfaceVariant)

                docCard("Orchestratore", "⌘K · intent locali + LLM · tools tipizzati (git, task, terminali, piano smart).")
                docCard("QS Swarm", "Missione plan-first: scout+coord → task board → conferma → builder. Modelli per ruolo nella barra Swarm.")
                docCard("QS Tasks", "Board kanban con provenance (source + evidence) e smart plan da ProjectBrain.")
                docCard("Knowledge", "Indice locale + mappa gerarchica cartelle/file/import. Re-indicizza dopo i cambi di layout.")
                docCard("Sicurezza", "Allowlist path, ruoli agent, two-person, audit firmato, dry-run.")
                docCard("GDPR", "Sezione Privacy nella sidebar Impostazioni: mappa dati, diritti, export e wipe.")
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }

    private func docCard(_ t: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(QS.Font.ui(13, weight: .semibold))
            Text(b).font(QS.Font.ui(12)).foregroundStyle(QS.Color.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SupportSettingsView: View {
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var safety: SafetyGuardrails
    @EnvironmentObject private var sparkle: SparkleUpdater
    @EnvironmentObject private var language: AppLanguageStore
    @State private var checks: [ProductionDiagnostics.Check] = []
    @State private var exportNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Supporto & produzione"))
                    .font(QS.Font.ui(18, weight: .semibold))
                Text("\(L("Diagnostica locale (nessuna telemetria).")) \(AppConfig.versionLabel).")
                    .font(QS.Font.ui(12))
                    .foregroundStyle(QS.Color.onSurfaceVariant)

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "mailto:\(AppConfig.supportEmail)?subject=QS%20Agents%20support") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(AppConfig.supportEmail, systemImage: "envelope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        if let url = URL(string: "mailto:\(AppConfig.privacyEmail)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        sparkle.checkForUpdates()
                    } label: {
                        Label("Cerca aggiornamenti", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!sparkle.updater.canCheckForUpdates)
                }

                Toggle(isOn: Binding(
                    get: { AppConfig.crashLogEnabled },
                    set: { newVal in
                        AppConfig.crashLogEnabled = newVal
                        if newVal { CrashReporter.install() }
                        checks = ProductionDiagnostics.runChecks(
                            workspaces: workspaces,
                            tasks: taskStore,
                            safety: safety
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log crash locali (opt-in)")
                            .font(QS.Font.ui(12, weight: .semibold))
                        Text("Scrive breadcrumbs in Application Support/logs/crashes.log. Nessun invio in rete. Richiede riavvio se spegni dopo l’install.")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Live health
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Health check")
                            .font(QS.Font.ui(13, weight: .semibold))
                        Spacer()
                        Button("Esegui") {
                            checks = ProductionDiagnostics.runChecks(
                                workspaces: workspaces,
                                tasks: taskStore,
                                safety: safety
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if checks.isEmpty {
                        Text("Premi Esegui per verificare key, workspace, log e scrittura disco.")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    } else {
                        ForEach(checks) { c in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(c.ok ? QS.Color.agentActive : QS.Color.agentThinking)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(QS.Font.ui(12, weight: .semibold))
                                    Text(c.detail).font(QS.Font.ui(11)).foregroundStyle(QS.Color.onSurfaceVariant)
                                }
                            }
                        }
                    }
                    Button {
                        if let url = ProductionDiagnostics.exportReport(
                            workspaces: workspaces,
                            tasks: taskStore,
                            safety: safety
                        ) {
                            exportNote = "Esportato: \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            exportNote = "Export fallito — vedi app.log"
                        }
                    } label: {
                        Label("Esporta diagnostica (.txt)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    if let exportNote {
                        Text(exportNote).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                supportRow("Log app", AppConfig.logsDirectory.path, "folder") {
                    NSWorkspace.shared.open(AppConfig.logsDirectory)
                }
                supportRow("Dati app", AppConfig.dataDirectory.path, "externaldrive") {
                    NSWorkspace.shared.open(AppConfig.dataDirectory)
                }
                supportRow("Bundle ID", AppConfig.bundleId, "app.badge.checkmark") {}
                supportRow("Versione", AppConfig.versionLabel, "number") {}

                VStack(alignment: .leading, spacing: 8) {
                    Text("Checklist release / production")
                        .font(QS.Font.ui(13, weight: .semibold))
                    Text("""
                    Stabilità
                    • Build Release; smoke: onboarding → workspace → goal → Accept/Reject
                    • Crash log opt-in solo se serve debug; altrimenti off
                    • Notifiche = sheet (no NSPopover su macOS beta)

                    Onboarding & UX
                    • Workspace ≠ $HOME · Coding engine spiegato · Scorciatoie goal chiare
                    • Support email e privacy raggiungibili da About / Support

                    Sicurezza & privacy
                    • Key solo Keychain · Demo OFF in Release · Safety ON
                    • Informativa GDPR aggiornata · URL privacy se pubblicata
                    • Nessuna telemetria cloud

                    Distribuzione (fuori Mac personale)
                    • Developer ID + notarize prima di App Store
                    • MAS: sandbox/PTY spesso bloccanti — valuta Direct/TestFlight Mac
                    • Matrix QA: Claude CLI / QS API / Grok / Swarm; git dirty; review 90%
                    """)
                    .font(QS.Font.ui(12))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text("Non inviare API key nei ticket. Usa export diagnostica + log senza secret.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
        .onAppear {
            checks = ProductionDiagnostics.runChecks(
                workspaces: workspaces,
                tasks: taskStore,
                safety: safety
            )
        }
    }

    private func supportRow(_ title: String, _ detail: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(QS.Color.primarySolid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(QS.Font.ui(12, weight: .semibold)).foregroundStyle(QS.Color.onSurface)
                    Text(detail).font(QS.Font.mono(10)).foregroundStyle(QS.Color.outline).lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(QS.Color.outline)
            }
            .padding(12)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
