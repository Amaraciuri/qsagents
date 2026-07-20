import SwiftUI

/// In-app how-to for using QS Agents well (Impostazioni → Tutorial).
struct TutorialsView: View {
    @State private var expanded: String? = "quickstart"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tutorial")
                        .font(QS.Font.ui(20, weight: .bold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("Come usare QS Agents senza bruciare token e senza confondere shell PTY e log agent.")
                        .font(QS.Font.ui(13))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }

                tutorialCard(
                    id: "quickstart",
                    title: "1 · Quick start (5 minuti)",
                    body: """
                    1. Impostazioni → Integrazioni: inserisci la API key (Anthropic / OpenAI / Grok…).
                    2. Apri un workspace (cartella progetto, es. zackgame) — resta su quella.
                    3. Orchestratore (⌘K o tab Chat): crea task piccole e chiare, o lancia una missione Swarm.
                    4. QS Tasks → Avvia sulla task, oppure Swarm → missione + auto-run.
                    5. Segui i log tool (console sotto Terminali / Swarm). I PTY mostrano anche l’eco dei tool.
                    """
                )

                tutorialCard(
                    id: "workspace",
                    title: "2 · Workspace: non perderlo",
                    body: """
                    • Il workspace attivo è quello in alto (cartella). Cambialo solo con «Apri / cambia cartella…».
                    • Non c’è più una lista «Recenti» nella tab Workspace (evitava switch accidentali).
                    • Nella tab Workspace c’è la chat orchestratore in basso: resta sul progetto mentre parli.
                    • Knowledge e Swarm usano il workspace corrente — aprilo prima di indicizzare o lanciare agent.
                    """
                )

                tutorialCard(
                    id: "tasks",
                    title: "3 · Task buone (basso costo token)",
                    body: """
                    Una task deve avere:
                    • Titolo corto e concreto (es. «QS smoke: commento in boot.css»).
                    • Dettaglio con path esatti (1–2 file), passi 1-2-3, e cosa è vietato (no ROADMAP, no list_dir root).
                    • Preferisci file piccoli; evita «animazioni homepage» su premium-ui.css intero (90k+).

                    Prompt tipo per l’orchestratore:
                    Crea UNA sola task… Titolo: … Dettaglio: UN solo file: path/… propose_patch → apply_patch → complete_task.

                    Non rilanciare task roadmap vecchie e vaghe: spezzale o riscrivile.
                    """
                )

                tutorialCard(
                    id: "terminals",
                    title: "4 · Terminali vs log agent (importante)",
                    body: """
                    Ci sono DUE flussi:

                    A) Shell PTY (i riquadri neri in Terminali)
                    • Sono terminali veri del Mac (zsh + PTY).
                    • Puoi digitarci comandi a mano, aprire 5 pannelli, griglia 2×2, ecc.
                    • Quando un agent è collegato, i tool LLM vengono anche specchiati qui (eco ciano).

                    B) Console log agent (barra sotto / Swarm dock)
                    • È il tool stream: repo_capsule, read_file, propose_patch, token, step…
                    • NON è lo scrollback della shell. Qui capisci cosa decide l’agent.

                    Perché prima «non vedevi niente» nel terminal?
                    • L’agent lavorava con tool interni (Process/file API), non digitando nello shell.
                    • Ora l’output tool è mirrored nel PTY collegato + resta nel log sotto.
                    • run_command dell’agent ancora gira in sandbox (non sempre come se lo avessi battuto tu): l’eco mostra comando e risultato.
                    """
                )

                tutorialCard(
                    id: "swarm",
                    title: "5 · Swarm e orchestratore",
                    body: """
                    • Missione nuova: goal chiaro + workspace. Coordinator crea 3–8 task piccole, poi builder.
                    • Auto-run: concatena le task; disattivalo se vuoi approvare a mano.
                    • create_task dall’orchestratore finisce sulla board QS Tasks (titolo + dettaglio).
                    • Smoke test consigliato: 1 file piccolo, 1 riga, complete_task — verifica patch e API.
                    """
                )

                tutorialCard(
                    id: "brain",
                    title: "6 · Code brain (repo_capsule)",
                    body: """
                    • repo_capsule = contesto strutturato dal code brain (locale, no upload).
                    • 1° tool dei builder: capsule con termini del titolo, non list_dir root.
                    • Knowledge FTS = docs/note; per codice preferisci capsule.
                    • Re-indicizza da Knowledge → Code brain se il repo è cambiato molto.
                    """
                )

                tutorialCard(
                    id: "tokens",
                    title: "7 · Disciplina token",
                    body: """
                    • Budget sessione agent ~14k: se esplora troppo, stop automatico.
                    • Max pochi round di sola lettura, poi patch obbligatoria.
                    • Non far leggere all’agent interi CSS/JS da 50–100k: indichi sezioni o append in fondo.
                    • propose_patch → apply_patch (diff-first); poi complete_task.
                    """
                )

                tutorialCard(
                    id: "checklist",
                    title: "8 · Checklist se «non funziona»",
                    body: """
                    □ API key e modello corretti (pallino verde in Integrazioni)
                    □ Workspace = progetto giusto (path in alto)
                    □ Task con path e passi, non solo titolo roadmap
                    □ Log agent aperti (non solo lo shell vuoto)
                    □ Per smoke: file piccolo + complete_task
                    □ Se finish «nessun task» o typo tool: app aggiornata rifiuta/retry
                    □ Impostazioni → Supporto → Health check / export diagnostica
                    □ Preferisci build Release per uso quotidiano (demo off)
                    """
                )

                tutorialCard(
                    id: "production",
                    title: "9 · Uso production",
                    body: """
                    • Build Release (scripts/ship_check.sh o xcodebuild -configuration Release).
                    • Demo data non si attiva in Release.
                    • Keys solo in Keychain; non committare secret.
                    • Supporto → Esporta diagnostica se qualcosa fallisce (no API key nel file).
                    • Notarize/Sparkle solo se distribuisci ad altri Mac (Apple Developer, fuori scope automatico).
                    """
                )

                Text("Suggerimento: tieni questa pagina aperta la prima settimana; poi Impostazioni → Novità per le release.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }

    private func tutorialCard(id: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded = expanded == id ? nil : id
                }
            } label: {
                HStack {
                    Text(title)
                        .font(QS.Font.ui(14, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: expanded == id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.outline)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if expanded == id {
                Text(body)
                    .font(QS.Font.ui(12))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .textSelection(.enabled)
            }
        }
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(expanded == id ? QS.Color.primarySolid.opacity(0.35) : QS.Color.border, lineWidth: 1)
        )
    }
}
