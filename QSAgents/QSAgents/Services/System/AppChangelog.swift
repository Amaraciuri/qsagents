import Foundation
import SwiftUI

/// In-app product changelog (not git log) — what shipped in QS Agents.
enum AppChangelog {
    struct Entry: Identifiable, Equatable {
        let id: String
        let version: String
        let date: String
        let title: String
        let tagline: String
        let kind: Kind
        let highlights: [Highlight]

        enum Kind: String {
            case major, feature, fix, polish

            var label: String {
                switch self {
                case .major: return "MAJOR"
                case .feature: return "FEATURE"
                case .fix: return "FIX"
                case .polish: return "POLISH"
                }
            }

            var color: Color {
                switch self {
                case .major: return QS.Color.primarySolid
                case .feature: return QS.Color.agentActive
                case .fix: return QS.Color.agentThinking
                case .polish: return QS.Color.secondary
                }
            }

            var icon: String {
                switch self {
                case .major: return "sparkles"
                case .feature: return "plus.circle.fill"
                case .fix: return "wrench.and.screwdriver.fill"
                case .polish: return "paintbrush.fill"
                }
            }
        }

        struct Highlight: Identifiable, Equatable {
            let id = UUID()
            let icon: String
            let title: String
            let detail: String
        }
    }

    /// Newest first.
    static let releases: [Entry] = [
        Entry(
            id: "1.0.4",
            version: "1.0.4",
            date: "20 Jul 2026",
            title: "Allowlist fix · Auto task · Kimi resilience",
            tagline: "Path allowlist parsing, auto QS Task from goals, stronger OpenRouter/Kimi decoding.",
            kind: .fix,
            highlights: [
                .init(icon: "checkmark.shield", title: "Allowlist path fix",
                      detail: "Parses cmd|path allowlist entries correctly; allowlist can be turned off when needed. (IT: parsing cmd|path e allowlist disattivabile.)"),
                .init(icon: "checklist", title: "Auto QS Task",
                      detail: "Orchestrator/mission goals can create and start a QS Task automatically. (IT: goal orchestratore/missione → task automatica.)"),
                .init(icon: "arrow.clockwise", title: "Kimi / OpenRouter decode",
                      detail: "More resilient LLM JSON decode + retry for OpenRouter/Kimi responses. (IT: decode JSON più robusto con retry.)"),
            ]
        ),
        Entry(
            id: "1.0.3",
            version: "1.0.3",
            date: "20 Jul 2026",
            title: "Auto-update on launch · Compact nav",
            tagline: "Sparkle checks for updates at launch; responsive top nav with Altro/More overflow.",
            kind: .feature,
            highlights: [
                .init(icon: "arrow.triangle.2.circlepath", title: "Update popup on launch",
                      detail: "Sparkle checks for updates when the app starts so you see new builds sooner."),
                .init(icon: "sidebar.left", title: "Compact top nav",
                      detail: "Narrow windows fold secondary tabs into Altro/More instead of crowding the bar."),
            ]
        ),
        Entry(
            id: "1.0.2",
            version: "1.0.2",
            date: "20 Jul 2026",
            title: "English Language tab · Kimi · SpaceX AI Grok",
            tagline: "In-app English tab + i18n, OpenRouter Kimi, SpaceX AI grok-4.5 model IDs.",
            kind: .feature,
            highlights: [
                .init(icon: "globe", title: "English Language tab",
                      detail: "Dedicated Language settings with fuller EN/IT coverage."),
                .init(icon: "sparkles", title: "OpenRouter Kimi",
                      detail: "moonshotai/kimi models available via OpenRouter."),
                .init(icon: "cpu", title: "SpaceX AI grok-4.5",
                      detail: "Canonical dotted model IDs; migrates legacy grok-4-5 prefs."),
            ]
        ),
        Entry(
            id: "1.0.0",
            version: "1.0.0",
            date: "20 Jul 2026",
            title: "v1 alpha — English + security hardening",
            tagline: "Bilingual UI (EN default), Keychain PIN, secret redaction, gitleaks CI, notarized release.",
            kind: .major,
            highlights: [
                .init(icon: "globe", title: "English + Italiano",
                      detail: "Settings → Language. Default English; switch anytime."),
                .init(icon: "lock.shield", title: "Hardening",
                      detail: "PBKDF2 PIN in Keychain; SecretRedactor on logs/Slack/audit; agent-safe env."),
                .init(icon: "checkmark.seal", title: "Notarized",
                      detail: "Developer ID + Sparkle appcast for v1.0.0-alpha."),
            ]
        ),
        Entry(
            id: "1.3.10",
            version: "1.3.10",
            date: "19 lug 2026",
            title: "Production complete · notarize + Sparkle",
            tagline: "Developer ID notarizzato; auto-update Sparkle; roadmap Fase 0–6 chiusa.",
            kind: .major,
            highlights: [
                .init(icon: "checkmark.seal", title: "Notarize",
                      detail: "Gatekeeper Notarized Developer ID; ship_check + staple."),
                .init(icon: "arrow.triangle.2.circlepath", title: "Sparkle",
                      detail: "Cerca aggiornamenti nel menu e in Supporto; appcast su GitHub."),
                .init(icon: "lock.shield", title: "Privacy docs",
                      detail: "README: sandbox off motivato, Keychain, TCC microfono opt-in."),
            ]
        ),
        Entry(
            id: "1.3.9",
            version: "1.3.9",
            date: "19 lug 2026",
            title: "Production Fase 2–4",
            tagline: "Sandbox testabile, DONE strutturato, JSON/Keychain/LLM resilienti, XCTest + CI.",
            kind: .major,
            highlights: [
                .init(icon: "lock.shield", title: "Sandbox + test",
                      detail: "Symlink resolve; target QSAgentsTests; CI GitHub Actions."),
                .init(icon: "checklist", title: "Task truth",
                      detail: "REVIEW non sblocca DAG; progress≠DONE; complete_task flag; clear+stop."),
                .init(icon: "externaldrive.badge.timemachine", title: "Dati onesti",
                      detail: "JSON corrupt→quarantine+.bak; Keychain session-only esplicito; retry 429/5xx."),
            ]
        ),
        Entry(
            id: "1.3.8",
            version: "1.3.8",
            date: "19 lug 2026",
            title: "Scorciatoie goal · onboarding engine · production",
            tagline: "«Ricetta» = preferito goal; onboarding 5 step; support/privacy; crash log opt-in.",
            kind: .feature,
            highlights: [
                .init(icon: "bookmark", title: "Salva scorciatoia",
                      detail: "Ex «ricetta»: salva goal+engine+workspace e rilancialo dal menu Rilancia."),
                .init(icon: "list.number", title: "Onboarding coding",
                      detail: "Step workspace → Coding engine → integrazioni → safety."),
                .init(icon: "envelope", title: "Support & privacy",
                      detail: "Email in About/Support/GDPR; crash log locale solo opt-in."),
                .init(icon: "checklist", title: "Checklist release",
                      detail: "Supporto aggiornato: stabilità, UX, privacy, notarize vs MAS."),
            ]
        ),
        Entry(
            id: "1.3.7",
            version: "1.3.7",
            date: "19 lug 2026",
            title: "Crash campanella + review prematura",
            tagline: "Notifiche = sheet (no NSPopover crash); task non va in REVISIONE mentre Claude lavora ancora.",
            kind: .fix,
            highlights: [
                .init(icon: "bell", title: "Crash ViewBridge",
                      detail: "Centro notifiche da .popover → .sheet (macOS beta SIGTRAP)."),
                .init(icon: "hourglass", title: "Review prematura",
                      detail: "Niente REVIEW su solo git dirty / riepilogo mid-task; serve quiet 12–18s dopo i tool."),
                .init(icon: "info.circle", title: "Haiku vs Claude CLI",
                      detail: "Nota in chat: Claude CLI ignora modello Home; per Haiku usa Coding engine QS API."),
            ]
        ),
        Entry(
            id: "1.3.6",
            version: "1.3.6",
            date: "19 lug 2026",
            title: "Feedback · Diff Accept · Ricette · Gate",
            tagline: "Applica feedback allo stesso PTY; Accept/Reject file; ricette one-click; quality gate in review.",
            kind: .feature,
            highlights: [
                .init(icon: "arrow.uturn.forward", title: "Applica feedback",
                      detail: "Ritocchi chat → stesso Claude/IDE; task torna IN CORSO."),
                .init(icon: "checkmark.circle", title: "Accept / Reject",
                      detail: "Per file in Dettaglio task (stage / discard) + Diff."),
                .init(icon: "bookmark", title: "Ricette",
                      detail: "Salva goal+engine; menu Ricette per replay."),
                .init(icon: "shield.checkerboard", title: "Quality gate",
                      detail: "A fine lavoro: dirty tree + hint test (no CI lenta)."),
            ]
        ),
        Entry(
            id: "1.3.5",
            version: "1.3.5",
            date: "19 lug 2026",
            title: "Chat History + brief sticky",
            tagline: "Chat persistente per workspace; Pulisci archivia; brief progetto sempre iniettato.",
            kind: .feature,
            highlights: [
                .init(icon: "clock.arrow.circlepath", title: "History",
                      detail: "Salvataggio automatico; ripristino da sheet History in chat."),
                .init(icon: "pin.fill", title: "Brief sticky",
                      detail: "Regole repo in Awareness — sopravvive a clear e riavvio."),
                .init(icon: "brain", title: "Mem progetto in LLM",
                      detail: "promptBlock (brief + eventi) nel system prompt orchestratore."),
            ]
        ),
        Entry(
            id: "1.3.4",
            version: "1.3.4",
            date: "19 lug 2026",
            title: "Altezza terminali regolabile",
            tagline: "Toolbar M/L/XL/MAX per pane PTY + drag tra shell e console agent.",
            kind: .polish,
            highlights: [
                .init(icon: "arrow.up.and.down", title: "Altezza PTY",
                      detail: "Chip M→MAX in barra Terminali (persiste)."),
                .init(icon: "rectangle.split.1x2", title: "Splitter",
                      detail: "Trascina la maniglia sopra la console agent per ridistribuire lo spazio."),
            ]
        ),
        Entry(
            id: "1.3.3",
            version: "1.3.3",
            date: "19 lug 2026",
            title: "Task files + costi + allegati chat",
            tagline: "Dettaglio task mostra file da Claude; modelli live in Nuova task; reset totale; token/task; knowledge risparmiati; paperclip in chat.",
            kind: .feature,
            highlights: [
                .init(icon: "doc.badge.ellipsis", title: "FILE CAMBIATI",
                      detail: "Parse `files:` + `file:` per path da supervisor/git."),
                .init(icon: "cpu", title: "Modello Nuova task",
                      detail: "SearchableModelPicker live (non lista hardcoded)."),
                .init(icon: "dollarsign.circle", title: "Token & costi",
                      detail: "Reset azzera anche Totale/Stima; risparmio Knowledge; tok/$ su card task."),
                .init(icon: "paperclip", title: "Allegati chat",
                      detail: "Immagini/PDF/testo → path + anteprima testo all’agente."),
            ]
        ),
        Entry(
            id: "1.3.2",
            version: "1.3.2",
            date: "19 lug 2026",
            title: "Stop git flicker + activity spam",
            tagline: "Niente più Commit che lampeggia / Attendo terminale ×10; fine lavoro → revisione in chat.",
            kind: .fix,
            highlights: [
                .init(icon: "flame", title: "CPU / Commit flicker",
                      detail: "setPath non refresha se path uguale; git refresh throttled 2.5s."),
                .init(icon: "text.badge.minus", title: "Activity dedupe",
                      detail: "Footer «auto mode on» e Attendo terminale ripetuti filtrati."),
                .init(icon: "checkmark.bubble", title: "Riepilogo → IN REVISIONE",
                      detail: "Prompt ❯ + file dirty o «Riepilogo» → task 90% + messaggio chat."),
            ]
        ),
        Entry(
            id: "1.3.1",
            version: "1.3.1",
            date: "19 lug 2026",
            title: "Git dots + Desktop parity + review chat",
            tagline: "Pallini rossi sui file modificati; write/mtime per GitHub Desktop; task in REVISIONE con messaggio in chat.",
            kind: .fix,
            highlights: [
                .init(icon: "circle.fill", title: "File tree · pallino rosso",
                      detail: "I path dirty da git status / agent appaiono con dot rosso nel workspace."),
                .init(icon: "arrow.triangle.2.circlepath", title: "GitHub Desktop vede le diff",
                      detail: "Dopo write: mtime bump + git status; commit mostra path assoluto del repo."),
                .init(icon: "checkmark.bubble", title: "Fine Claude → revisione",
                      detail: "Riconosce «Fatto.»; task ~90% IN REVISIONE + avviso chat (no auto-DONE)."),
            ]
        ),
        Entry(
            id: "1.3.0",
            version: "1.3.0",
            date: "19 lug 2026",
            title: "Coding Engine unificato",
            tagline: "Auto / Claude CLI / Grok CLI / QS API IDE — Swarm solo se scelto. Chat = stesso PTY/loop.",
            kind: .major,
            highlights: [
                .init(icon: "cpu", title: "Menu Coding (non più solo Claude)",
                      detail: "Auto sceglie Claude → Grok → QS API (OpenRouter). Swarm esplicito."),
                .init(icon: "terminal.fill", title: "QS API = IDE in terminale",
                      detail: "1 builder + tools mirrorati nel PTY; follow-up chat inietta guida nel loop."),
                .init(icon: "lock.shield", title: "Diff sandbox",
                      detail: "applyUnifiedDiff rifiuta path assoluti fuori workspace."),
            ]
        ),
        Entry(
            id: "1.2.1",
            version: "1.2.1",
            date: "19 lug 2026",
            title: "Supervisor: heuristic stretti + stop fix",
            tagline: "Niente DONE falso da git status; limit solo frasi crediti; stop non azzera TaskStore.",
            kind: .fix,
            highlights: [
                .init(icon: "checkmark.shield", title: "Done/limit conservativi",
                      detail: "Done richiede frasi forti + quiet 12s + 75s lavoro; limit solo rate/credit/429."),
                .init(icon: "hand.raised", title: "Menu solo auth",
                      detail: "Auto-1 solo login/account; permessi → chat, non tasto 1."),
                .init(icon: "wrench", title: "Stop + goal RAW",
                      detail: "stop preserva tasks; brief compatto una riga per il TUI."),
            ]
        ),
        Entry(
            id: "1.2.0",
            version: "1.2.0",
            date: "19 lug 2026",
            title: "Orchestratore = layer su Claude PTY",
            tagline: "Supervisione: ready/menu, ascolto output, task sync; Avvia/chat → stesso terminale (no Swarm).",
            kind: .major,
            highlights: [
                .init(icon: "rectangle.connected.to.line.below", title: "ClaudeSessionSupervisor",
                      detail: "Un PTY per workspace; attende ready, auto-menu «1», goal RAW, poll tail."),
                .init(icon: "ear", title: "Ascolto continuo",
                      detail: "Fasi running/limit/done/awaitingInput → QS Tasks + activity log."),
                .init(icon: "arrow.triangle.merge", title: "Chat e Avvia unificati",
                      detail: "Follow-up nello stesso Claude; Avvia su task claude-code non apre Swarm."),
            ]
        ),
        Entry(
            id: "1.1.9",
            version: "1.1.9",
            date: "19 lug 2026",
            title: "Orchestratore → Claude Code in terminale",
            tagline: "I goal di codice aprono Claude CLI (piano → edit reali); Swarm solo su richiesta esplicita.",
            kind: .feature,
            highlights: [
                .init(icon: "terminal", title: "Claude Code ON (default)",
                      detail: "«migliora il pulsante…» apre PTY + claude nel workspace; file visibili in GitHub Desktop."),
                .init(icon: "switch.2", title: "Toggle + chip",
                      detail: "Claude Code ON/OFF in chat; chip «Apri Claude Code qui». OFF = Swarm."),
                .init(icon: "hand.raised", title: "Senza CLI: niente Swarm silenzioso",
                      detail: "Se `claude` manca, messaggio install — zero task LOCAL incomplete."),
            ]
        ),
        Entry(
            id: "1.1.8",
            version: "1.1.8",
            date: "19 lug 2026",
            title: "Model id + propose_patch sicuri",
            tagline: "Resume non manda più OpenRouter/anthropic/… (HTTP 400); APPEND non tronca CSS.",
            kind: .fix,
            highlights: [
                .init(icon: "number", title: "Raw model id in sessione",
                      detail: "UI mostra OpenRouter/…; API riceve solo anthropic/claude-…. Retry 400 senza bootstrap."),
                .init(icon: "doc.badge.plus", title: "propose_patch append/replace",
                      detail: "mode=append + old_string/new_string; rifiuta content APPEND e wipe >50%."),
            ]
        ),
        Entry(
            id: "1.1.7",
            version: "1.1.7",
            date: "19 lug 2026",
            title: "Direct patch: stessa key, un builder",
            tagline: "Niente più «Nessuna API key» sul Swarm se la chat ha OpenRouter; skip PLAN/scout/reviewer.",
            kind: .fix,
            highlights: [
                .init(icon: "bolt.fill", title: "GOAL → 1 Patch + 1 builder",
                      detail: "Con key in Integrazioni salta scout/coord/cascade Locate; seed una sola card."),
                .init(icon: "key.fill", title: "Swarm = key orchestratore",
                      detail: "syncSwarmFromLive + retry pickLiveLLM; spawn stampa provider vivo."),
                .init(icon: "hand.tap", title: "Senza toggle GOAL",
                      detail: "Messaggi «migliora/modifica…» avviano missione autonoma automaticamente."),
            ]
        ),
        Entry(
            id: "1.1.6",
            version: "1.1.6",
            date: "19 lug 2026",
            title: "Pre-flight: no REVIEW thrash + Elimina tutte",
            tagline: "Stop auto-rilancio REVIEW/PTY spam; run_command senza $HOME; wipe board 1 click.",
            kind: .fix,
            highlights: [
                .init(icon: "hand.raised", title: "REVIEW non riparte da sola",
                      detail: "Pipeline/antistallo ignorano IN REVISIONE; bootstrap no-LLM marca local-bootstrap-dead."),
                .init(icon: "house", title: "run_command fail-closed",
                      detail: "Senza workspace progetto non cade su $HOME."),
                .init(icon: "trash.fill", title: "Elimina tutte",
                      detail: "Un click (con conferma) svuota TODO+IN CORSO+REVIEW+DONE del filtro."),
            ]
        ),
        Entry(
            id: "1.1.5",
            version: "1.1.5",
            date: "19 lug 2026",
            title: "Pulisci revisione + delete task",
            tagline: "Svuota IN REVISIONE / COMPLETATE (filtro workspace); dialog elimina affidabile.",
            kind: .fix,
            highlights: [
                .init(icon: "trash", title: "Pulisci revisione / archivio",
                      detail: "Bottoni in QS Tasks: revisione, completate, o entrambe — rispettano «Solo zackgame»."),
                .init(icon: "exclamationmark.triangle", title: "Elimina singola",
                      detail: "Confirm dialog con flag dedicato (non più binding fragile su UUID)."),
            ]
        ),
        Entry(
            id: "1.1.4",
            version: "1.1.4",
            date: "19 lug 2026",
            title: "Stop loop token + knowledge PLAY",
            tagline: "Niente cascade Locate×6; knowledge demote CSS non linkato; banner bootstrap chiarito.",
            kind: .fix,
            highlights: [
                .init(icon: "arrow.uturn.backward", title: "Max 2 GOAL split",
                      detail: "Su token budget: una sola Patch mirata, non Locate→Patch→Verify ricorsivo (331k loop)."),
                .init(icon: "magnifyingglass", title: "Knowledge → premium-ui",
                      detail: "Demote premium-home-mobile-buttons; boost premium-ui.css/js per play/home."),
                .init(icon: "key", title: "Bootstrap ≠ no Anthropic",
                      detail: "Coord senza key non nasconde i builder LLM: summary spiega routing Swarm."),
            ]
        ),
        Entry(
            id: "1.1.3",
            version: "1.1.3",
            date: "19 lug 2026",
            title: "Agent quality = Cursor parity",
            tagline: "Meno rush, più ragionamento: explore soft, gate su complete_task, Git come Desktop.",
            kind: .fix,
            highlights: [
                .init(icon: "brain", title: "Niente patch cieca",
                      detail: "Explore max 6; nudge chiede target markup/CSS linkato, non «obbliga propose_patch»."),
                .init(icon: "checkmark.shield", title: "complete_task con apply",
                      detail: "Gate hard: serve apply_patch (+ diff tracked su task UI). Fallimento non chiude il loop."),
                .init(icon: "text.alignleft", title: "Contesto più ricco",
                      detail: "History 14 msg; clip tool/locate alzati così id/class restano come in Cursor."),
                .init(icon: "arrow.triangle.branch", title: "Git = Desktop",
                      detail: "Working tree clean quando tracked è clean; www/ gitignored solo footnote."),
            ]
        ),
        Entry(
            id: "1.1.2",
            version: "1.1.2",
            date: "18 lug 2026",
            title: "GOAL MODE + activity log",
            tagline: "Toggle GOAL autonomo; in chat vedi se pensa, chiama il modello, attende PTY o agent.",
            kind: .feature,
            highlights: [
                .init(icon: "target", title: "GOAL MODE",
                      detail: "Chat/⌘K: attiva GOAL e scrivi l’obiettivo. Scout+coord+builder senza gate umano."),
                .init(icon: "list.bullet.rectangle", title: "Activity log",
                      detail: "Trail live stile Claude: pensando → LLM → tool → attendo terminale/agent."),
                .init(icon: "person.badge.key", title: "Avvia via orchestratore",
                      detail: "Play su Tasks/Swarm: l’orchestratore crea il sub-agent e tiene il controllo (no bypass)."),
                .init(icon: "externaldrive", title: "Code brain persistente",
                      detail: "Stats da SQLite al reopen; PTY chiuso → agent via da Swarm + trace sulla task; board filtrata per workspace."),
                .init(icon: "terminal.fill", title: "Swarm · terminal toggle",
                      detail: "Modelli chiusi di default; icona terminal come le sidebar. GOAL riprende IN CORSO e sblocca dipendenze."),
                .init(icon: "arrow.triangle.2.circlepath", title: "GOAL antistallo",
                      detail: "Bootstrap locale chiude il gate; «completa task» salta PLAN; pulse riparte se tutti idle; deps REVIEW ok."),
                .init(icon: "doc.badge.arrow.up", title: "Edit su sorgente reale",
                      detail: "Come Cursor: patch su root/src. www/ Capacitor è build — redirect automatico, così Git vede le diff."),
            ]
        ),
        Entry(
            id: "1.1.1",
            version: "1.1.1",
            date: "18 lug 2026",
            title: "Agent token + code brain",
            tagline: "Budget più alto, patch JSON non troncate, capsule senza mirror ios/android, read_file a finestra.",
            kind: .fix,
            highlights: [
                .init(icon: "gauge.with.needle", title: "TokenBudget 26k / completion 3.2k",
                      detail: "Session budget alzato; max completion per propose_patch CSS/JS. Explore RO max 2 step."),
                .init(icon: "square.on.square.dashed", title: "Capsule dedupe mirrors",
                      detail: "www/ preferito; ios/android public/ collassati. search_knowledge → locate (path:line), non ricapsula."),
                .init(icon: "text.page.badge.magnifyingglass", title: "read_file around/start_line",
                      detail: "Niente dump file intero; cat via run_command → read_file finestra. Patch solo su www/."),
            ]
        ),
        Entry(
            id: "1.1.0",
            version: "1.1.0",
            date: "18 lug 2026",
            title: "Production ready",
            tagline: "Build 1.1.0, demo off in Release, diagnostica locale, create+avvia task, tutorial, PTY mirror.",
            kind: .major,
            highlights: [
                .init(icon: "shippingbox.fill", title: "Release 1.1.0",
                      detail: "Versioning bundle, demo forzato OFF in Release, hardened runtime, export compliance."),
                .init(icon: "stethoscope", title: "Health check + export",
                      detail: "Impostazioni → Supporto: check key/workspace/log e report diagnostica senza secret."),
                .init(icon: "play.circle.fill", title: "Orchestratore avvia task",
                      detail: "create + avvia in un prompt; ACTION:START_TASK; modello sulla task."),
                .init(icon: "book.fill", title: "Tutorial + PTY mirror",
                      detail: "Guida in-app; tool agent eco nei riquadri Terminali reali."),
            ]
        ),
        Entry(
            id: "1.0.7",
            version: "1.0.7",
            date: "17 lug 2026",
            title: "Terminali = Swarm + brain incr",
            tagline: "Console agent in Terminali come Swarm; log tool completi; code brain con reindex mtime e hot-path.",
            kind: .polish,
            highlights: [
                .init(icon: "terminal.fill", title: "Terminali · AgentTerminalDock",
                      detail: "Stesso dock tab multi-agent di Swarm sotto i PTY; altezza M/L/XL; wrap multi-linea e copia full."),
                .init(icon: "doc.text.magnifyingglass", title: "Log tool non troncati",
                      detail: "UI fino a 12k per capsule / 8k patch; store 16k/riga · 600 eventi. History LLM resta clip."),
                .init(icon: "arrow.triangle.2.circlepath", title: "Code brain incrementale",
                      detail: "Index mtime: solo file cambiati. Hot reindex su write/apply_patch. Go/Rust symbols."),
            ]
        ),
        Entry(
            id: "1.0.6",
            version: "1.0.6",
            date: "17 lug 2026",
            title: "Code brain locale",
            tagline: "Grafo + FTS locale e capsule: gli agent trovano il codice senza greppare tutto il repo.",
            kind: .feature,
            highlights: [
                .init(icon: "brain.head.profile", title: "ProjectCodeBrain",
                      detail: "Parse simboli/import → SQLite FTS5 + edges. Tutto locale in Application Support, zero upload."),
                .init(icon: "cube.transparent", title: "Tool repo_capsule",
                      detail: "Pivot in full source, vicini solo skeleton. Budget token bound. index_repo per rebuild."),
                .init(icon: "arrow.triangle.pull", title: "Builder discipline",
                      detail: "Prompt: 1° tool = repo_capsule, non list_dir root / ROADMAP. Capsule resta in history."),
            ]
        ),
        Entry(
            id: "1.0.5",
            version: "1.0.5",
            date: "17 lug 2026",
            title: "Token budget & log console",
            tagline: "Meno token bruciati; log agent copiabili e visibili anche in Terminali.",
            kind: .polish,
            highlights: [
                .init(icon: "gauge.with.dots.needle.67percent", title: "TokenBudget",
                      detail: "Limiti centrali: history corta, tool out troncati, budget 18k/sessione, prompt role-scoped."),
                .init(icon: "doc.on.doc", title: "Copia console Swarm",
                      detail: "Copia tutto / riga; click su log apre la console."),
                .init(icon: "terminal", title: "Log agent in Terminali",
                      detail: "Tool stream sotto i PTY — non confondere con lo shell."),
            ]
        ),
        Entry(
            id: "1.0.4-legacy",
            version: "1.0.4",
            date: "17 lug 2026",
            title: "Parallel tools, diff-first & FTS",
            tagline: "Gli agent leggono in parallelo, patchano con diff e cercano nel repo con ranking.",
            kind: .feature,
            highlights: [
                .init(icon: "arrow.triangle.branch", title: "C4 · Tool paralleli",
                      detail: "Batch read-only: list_dir + git_status + read_file nello stesso step (TaskGroup)."),
                .init(icon: "doc.badge.plus", title: "C5 · Diff-first",
                      detail: "propose_patch mostra il diff → apply_patch scrive su disco (o discard)."),
                .init(icon: "magnifyingglass", title: "D1 · Knowledge FTS",
                      detail: "Indice invertito BM25-ish sui chunk; tool search_knowledge per gli agent."),
                .init(icon: "newspaper", title: "Changelog in-app",
                      detail: "Questa sezione: novità leggibili senza aprire git."),
            ]
        ),
        Entry(
            id: "1.0.3-legacy",
            version: "1.0.3",
            date: "17 lug 2026",
            title: "Swarm DAG, streaming & memoria",
            tagline: "Missioni collegate alle task, chat token-by-token, sessioni salvate sul progetto.",
            kind: .major,
            highlights: [
                .init(icon: "point.3.connected.trianglepath.dotted", title: "E4 · Swarm ↔ Tasks",
                      detail: "Pannello DAG agent→task, planId condiviso, nodi con link board."),
                .init(icon: "text.cursor", title: "C3 · Streaming UI",
                      detail: "SSE OpenAI/xAI/OpenRouter con caret in chat e ⌘K."),
                .init(icon: "archivebox", title: "B3 · Session memory",
                      detail: "Fine missione e chat periodica → ProjectMemoryStore + decision log."),
                .init(icon: "checklist", title: "C1/C2 · Task DAG",
                      detail: "dependsOn sequenziali, BLOCKED su board, auto-advance IN CORSO."),
            ]
        ),
        Entry(
            id: "1.0.2-legacy",
            version: "1.0.2",
            date: "17 lug 2026",
            title: "Smart plan, key & picker stabili",
            tagline: "Piani dal repo, OpenRouter che salva, modelli per provider senza crash.",
            kind: .fix,
            highlights: [
                .init(icon: "brain", title: "A1–A3 ProjectBrain",
                      detail: "git + manifest + README → task con evidence e provenance."),
                .init(icon: "key.fill", title: "Keychain OpenRouter",
                      detail: "Salvataggio robusto, cache sessione, dual-write legacy."),
                .init(icon: "rectangle.portrait.and.arrow.right", title: "Model picker sheet",
                      detail: "Niente NSPopover+TextField (crash ViewBridge); liste curate per provider."),
                .init(icon: "book.closed", title: "B1/B2/B4 Memoria",
                      detail: "Changelog progetto, decision log hash, recall «cosa abbiamo fatto»."),
            ]
        ),
        Entry(
            id: "1.0.1",
            version: "1.0.1",
            date: "17 lug 2026",
            title: "UX trust & navigazione onesta",
            tagline: "Sidebar che non mente, ⌘K che non ti butta fuori, task board affidabile.",
            kind: .polish,
            highlights: [
                .init(icon: "sidebar.left", title: "Label = destinazione",
                      detail: "Niente più «Logs» che apre i Terminali."),
                .init(icon: "rectangle.center.inset.filled", title: "stayInPlace",
                      detail: "Sparkles / modal restano sulla vista corrente."),
                .init(icon: "trash", title: "Delete task",
                      detail: "Cestino non mangiato dal tap sulla card."),
                .init(icon: "person.3", title: "Swarm plan-first",
                      detail: "Coord+scout → gate umano → builder sulle task."),
            ]
        ),
        Entry(
            id: "1.0.0",
            version: "1.0.0",
            date: "2026",
            title: "QS Agents 1.0",
            tagline: "Command center multi-agent nativo macOS: PTY, board, swarm, safety, LLM.",
            kind: .major,
            highlights: [
                .init(icon: "terminal", title: "Terminali PTY reali",
                      detail: "Shell macOS collegate a workspace e safety guardrails."),
                .init(icon: "bubble.left.and.bubble.right", title: "Orchestratore",
                      detail: "Intent + tools + LLM multi-provider (Grok, OpenAI, Anthropic, …)."),
                .init(icon: "shield.lefthalf.filled", title: "Sicurezza",
                      detail: "Conferme umane, ambient production, audit."),
                .init(icon: "lock.shield", title: "Local-first",
                      detail: "Key in Keychain, dati su disco, GDPR hub."),
            ]
        ),
    ]

    static var latest: Entry { releases[0] }
}
