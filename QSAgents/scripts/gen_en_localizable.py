#!/usr/bin/env python3
"""Generate en.lproj/Localizable.strings from Italian UI string list + phrase map."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_EN = ROOT / "QSAgents" / "en.lproj" / "Localizable.strings"
OUT_IT = ROOT / "QSAgents" / "it.lproj" / "Localizable.strings"
SRC = Path("/tmp/qs_ita_strings.json")
SRC_SWIFT = ROOT / "QSAgents"

STRING_RE = re.compile(
    r'(?:Text|Label|Button|Section|PrimaryButton|GhostButton|SidebarNavRow|SectionLabel|'
    r'\.navigationTitle|\.help|\.alert|Toggle)\s*\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
)


def extract_strings_from_swift() -> list[str]:
    found: set[str] = set()
    for path in SRC_SWIFT.rglob("*.swift"):
        if "Tests" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for m in STRING_RE.finditer(text):
            s = m.group(1).encode("utf-8").decode("unicode_escape")
            if s.strip() and not s.startswith("$"):
                found.add(s)
    return sorted(found, key=lambda x: (x.lower(), x))


def load_strings() -> list[str]:
    if SRC.exists():
        return json.loads(SRC.read_text(encoding="utf-8"))
    return extract_strings_from_swift()

# High-value exact phrase translations (Italian key → English).
EXACT: dict[str, str] = {
    "Aggiungi": "Add",
    "Aggiungi Personalizzato": "Add Custom",
    "Aggiungi Task": "Add Task",
    "Aggiungi task": "Add task",
    "Aggiungi cartella…": "Add folder…",
    "Aggiungi all'allowlist": "Add to allowlist",
    "Apri": "Open",
    "Apri…": "Open…",
    "Apri Workspace": "Open Workspace",
    "Apri workspace": "Open workspace",
    "Apri workspace…": "Open workspace…",
    "Apri Workspace…": "Open Workspace…",
    "Apri un workspace": "Open a workspace",
    "Apri un workspace (⌘⇧O).": "Open a workspace (⌘⇧O).",
    "Apri un workspace prima (es. zackgame).": "Open a workspace first (e.g. your project).",
    "Apri una cartella per iniziare.": "Open a folder to get started.",
    "Apri cartella": "Open folder",
    "Apri cartella…": "Open folder…",
    "Apri cartella dati": "Open data folder",
    "Apri cartella progetto": "Open project folder",
    "Apri come workspace": "Open as workspace",
    "Apri file": "Open file",
    "Apri diff": "Open diff",
    "Apri in Finder": "Open in Finder",
    "Apri in Home": "Open in Home",
    "Apri log": "Open log",
    "Apri qui": "Open here",
    "Apri terminale": "Open terminal",
    "Apri Terminale": "Open Terminal",
    "Apri Terminali (PTY)": "Open Terminals (PTY)",
    "Apri QS Tasks": "Open QS Tasks",
    "Apri Integrazioni": "Open Integrations",
    "Apri Integrazioni (key)": "Open Integrations (key)",
    "Apri Novità": "Open What's New",
    "Apri Privacy e sicurezza": "Open Privacy & Security",
    "Apri Privacy → Microfono": "Open Privacy → Microphone",
    "Apri Privacy → Riconoscimento vocale": "Open Privacy → Speech Recognition",
    "Apri prima un terminale": "Open a terminal first",
    "Apri coding engine qui": "Open coding engine here",
    "Apri console tool stream": "Open tool stream console",
    "Apri terminal agent": "Open agent terminal",
    "Apri terminale e fai git status": "Open terminal and run git status",
    "Apri terminale in Home": "Open terminal in Home",
    "Apri workspace + terminale": "Open workspace + terminal",
    "Apri / cambia cartella…": "Open / change folder…",
    "Apri Console + claude.ai": "Open Console + claude.ai",
    "Apri GitHub Developer settings": "Open GitHub Developer settings",
    "Avvia": "Start",
    "Avvia missione": "Start mission",
    "Avvia missione: esplora il workspace": "Start mission: explore the workspace",
    "Avvia via orchestratore": "Start via orchestrator",
    "Avvio missione Swarm…": "Starting Swarm mission…",
    "Attività": "Activity",
    "Attendo terminale": "Waiting for terminal",
    "Salva": "Save",
    "Salva scorciatoia": "Save shortcut",
    "Chiudi": "Close",
    "Cerca": "Search",
    "Cerca aggiornamenti": "Check for Updates",
    "Cerca aggiornamenti…": "Check for Updates…",
    "Annulla": "Cancel",
    "Conferma": "Confirm",
    "Elimina": "Delete",
    "Rimuovi": "Remove",
    "Modifica": "Edit",
    "Copia": "Copy",
    "Incolla": "Paste",
    "Reset": "Reset",
    "Reset sessione": "Reset session",
    "Impostazioni": "Settings",
    "IMPOSTAZIONI": "SETTINGS",
    "Integrazioni": "Integrations",
    "Supporto": "Support",
    "Permessi": "Permissions",
    "Sicurezza": "Safety",
    "Privacy": "Privacy",
    "Tutorial": "Tutorials",
    "Novità": "What's New",
    "Docs": "Docs",
    "Home": "Home",
    "Terminali": "Terminals",
    "Chat": "Chat",
    "Tasks": "Tasks",
    "QS Tasks": "QS Tasks",
    "QS Swarm": "QS Swarm",
    "Workspace": "Workspace",
    "Knowledge": "Knowledge",
    "Orchestratore": "Orchestrator",
    "Orchestratore QS Agents…": "QS Agents Orchestrator…",
    "About & Scorciatoie…": "About & Shortcuts…",
    "Mostra onboarding…": "Show onboarding…",
    "Nuovo Terminale": "New Terminal",
    "Nuovo Terminale in Cartella…": "New Terminal in Folder…",
    "Nuova Task": "New Task",
    "Nuova task": "New task",
    "Apri Workspace…": "Open Workspace…",
    "Viste": "Views",
    "Sistema": "System",
    "Italiano": "Italiano",
    "English": "English",
    "Lingua": "Language",
    "Lingua app": "App language",
    "Microfono": "Microphone",
    "Riconoscimento vocale": "Speech recognition",
    "Pronti per la voce": "Voice ready",
    "Permessi incompleti": "Permissions incomplete",
    "Testa microfono": "Test microphone",
    "Aggiorna stato": "Refresh status",
    "Ricarica stato": "Reload status",
    "Richiedi permesso": "Request permission",
    "Nessun workspace": "No workspace",
    "Nessun file": "No files",
    "Nessun repo git": "Not a git repo",
    "Nessuna API key": "No API key",
    "Carica": "Load",
    "Esporta": "Export",
    "Importa": "Import",
    "Pulisci": "Clear",
    "Pulisci chat": "Clear chat",
    "Pulisci e ferma": "Clear and stop",
    "Ferma": "Stop",
    "Continua": "Continue",
    "Invia": "Send",
    "Stage All": "Stage All",
    "Stage all": "Stage all",
    "Stage All (tracked)": "Stage All (tracked)",
    "Stage all (tracked)": "Stage all (tracked)",
    "Stage All + ignored (force)": "Stage All + ignored (force)",
    "Stage all + ignored (force)": "Stage all + ignored (force)",
    "Commit": "Commit",
    "Push": "Push",
    "Pull": "Pull",
    "Diff": "Diff",
    "Log": "Log",
    "Errore": "Error",
    "Avviso": "Warning",
    "OK": "OK",
    "Sì": "Yes",
    "No": "No",
    "Tutti": "All",
    "Nessuno": "None",
    "In corso": "In progress",
    "Completato": "Completed",
    "Completata": "Completed",
    "Bozza": "Draft",
    "Revisione": "Review",
    "Fatto": "Done",
    "Agent": "Agent",
    "Agenti": "Agents",
    "Modello": "Model",
    "Provider": "Provider",
    "Sessione": "Session",
    "Totale": "Total",
    "Token": "Tokens",
    "Costi": "Costs",
    "Diagnostica": "Diagnostics",
    "Health check": "Health check",
    "Esegui": "Run",
    "Esporta diagnostica": "Export diagnostics",
    "Log crash locali (opt-in)": "Local crash logs (opt-in)",
    "Supporto & produzione": "Support & production",
    "AI & GITHUB": "AI & GITHUB",
    "INTEGRAZIONI": "INTEGRATIONS",
    "Permessi": "Permissions",
    "Cerca provider...": "Search providers...",
    "Cerca provider…": "Search providers…",
    "Aggiungi Personalizzato": "Add Custom",
    "Salva scorciatoia": "Save shortcut",
    "Rilancia": "Relaunch",
    "Scorciatoie": "Shortcuts",
    "Preferenze": "Preferences",
    "Account": "Account",
    "Esci": "Sign out",
    "Accedi": "Sign in",
    "Connesso": "Connected",
    "Non connesso": "Not connected",
    "Test": "Test",
    "Salva key": "Save key",
    "Key salvata": "Key saved",
    "Key salvata solo per questa sessione": "Key saved for this session only",
    "Cartella": "Folder",
    "File": "File",
    "Progetto": "Project",
    "Branch": "Branch",
    "Pulito": "Clean",
    "Modificati": "Modified",
    "Staged": "Staged",
    "Untracked": "Untracked",
    "Ignorati": "Ignored",
    "Messaggio": "Message",
    "Descrizione": "Description",
    "Titolo": "Title",
    "Dettaglio": "Detail",
    "Obiettivo": "Goal",
    "Piano": "Plan",
    "Missione": "Mission",
    "Builder": "Builder",
    "Scout": "Scout",
    "Coordinatore": "Coordinator",
    "Swarm": "Swarm",
    "Knowledge": "Knowledge",
    "Indice": "Index",
    "Reindex": "Reindex",
    "Chunk": "Chunks",
    "Nessun risultato": "No results",
    "Caricamento…": "Loading…",
    "Salvataggio…": "Saving…",
    "Pronto": "Ready",
    "Occupato": "Busy",
    "Idle": "Idle",
    "Attivo": "Active",
    "Fallito": "Failed",
    "Riuscito": "Succeeded",
    "Annullato": "Cancelled",
    "Timeout": "Timeout",
    "Rete": "Network",
    "Locale": "Local",
    "Produzione": "Production",
    "Debug": "Debug",
    "Versione": "Version",
    "Build": "Build",
    "Informazioni": "About",
    "Chiudi banner": "Dismiss banner",
    "L'app è crashata in precedenza": "The app crashed previously",
    "Inizia Orchestratore - chat e tools": "Start Orchestrator — chat & tools",
    "Inizia Orchestratore": "Start Orchestrator",
    "Nuovo terminale": "New terminal",
    "Vai a": "Go to",
    "CPU": "CPU",
    "RAM": "RAM",
    "PTY": "PTY",
    "Task": "Task",
    "in corso": "in progress",
    "file": "files",
    "chunk": "chunks",
    "agent": "agents",
    "Modello Orchestratore": "Orchestrator model",
    "Token & Costi": "Tokens & Costs",
    "Stima $": "Est. $",
    "live": "live",
    "Git": "Git",
    "OpenRouter": "OpenRouter",
    "Command center multi-agent - terminali reali - git - knowledge": "Multi-agent command center — real terminals — git — knowledge",
    "Command center multi-agent — terminali reali — git — knowledge": "Multi-agent command center — real terminals — git — knowledge",
}

# Prefix / fragment rewrites applied left-to-right when no exact match.
FRAGMENTS: list[tuple[str, str]] = [
    ("Impostazioni Sistema", "System Settings"),
    ("Impostazioni", "Settings"),
    ("Integrazioni", "Integrations"),
    ("Orchestratore", "Orchestrator"),
    ("terminale", "terminal"),
    ("Terminale", "Terminal"),
    ("Terminali", "Terminals"),
    ("workspace", "workspace"),
    ("Workspace", "Workspace"),
    ("scorciatoia", "shortcut"),
    ("Scorciatoia", "Shortcut"),
    ("scorciatoie", "shortcuts"),
    ("ricetta", "shortcut"),
    ("Ricetta", "Shortcut"),
    ("Nessun ", "No "),
    ("Nessuna ", "No "),
    ("Nessuno ", "No "),
    ("Aggiungi ", "Add "),
    ("Apri ", "Open "),
    ("Salva ", "Save "),
    ("Chiudi ", "Close "),
    ("Cerca ", "Search "),
    ("Elimina ", "Delete "),
    ("Rimuovi ", "Remove "),
    ("Avvia ", "Start "),
    ("Ferma ", "Stop "),
    ("Pulisci ", "Clear "),
    ("Carica ", "Load "),
    ("Esporta ", "Export "),
    ("Importa ", "Import "),
    ("Modifica ", "Edit "),
    ("Copia ", "Copy "),
    ("Incolla ", "Paste "),
    ("Aggiorna ", "Update "),
    ("Conferma ", "Confirm "),
    ("Annulla ", "Cancel "),
    ("Seleziona ", "Select "),
    ("Scegli ", "Choose "),
    ("Crea ", "Create "),
    ("Nuova ", "New "),
    ("Nuovo ", "New "),
    ("Tutti i ", "All "),
    ("Tutte le ", "All "),
    ("errore", "error"),
    ("Errore", "Error"),
    ("avviso", "warning"),
    ("progetto", "project"),
    ("Progetto", "Project"),
    ("cartella", "folder"),
    ("Cartella", "Folder"),
    ("file ", "file "),
    ("chiave", "key"),
    ("Chiave", "Key"),
    ("sessione", "session"),
    ("Sessione", "Session"),
    ("modello", "model"),
    ("Modello", "Model"),
    ("agente", "agent"),
    ("Agente", "Agent"),
    ("agenti", "agents"),
    ("missione", "mission"),
    ("Missione", "Mission"),
    ("sicurezza", "safety"),
    ("Sicurezza", "Safety"),
    ("privacy", "privacy"),
    ("conoscenza", "knowledge"),
    ("Conoscenza", "Knowledge"),
    ("diagnostica", "diagnostics"),
    ("Diagnostica", "Diagnostics"),
    ("preferenze", "preferences"),
    ("Preferenze", "Preferences"),
    ("permesso", "permission"),
    ("Permesso", "Permission"),
    ("permessi", "permissions"),
    ("microfono", "microphone"),
    ("Microfono", "Microphone"),
    ("riconoscimento vocale", "speech recognition"),
    ("Riconoscimento vocale", "Speech recognition"),
    ("non disponibile", "unavailable"),
    ("non trovato", "not found"),
    ("non valido", "invalid"),
    ("riprova", "try again"),
    ("Riprova", "Try again"),
    ("richiede", "requires"),
    ("locale", "local"),
    ("rete", "network"),
    ("Keychain", "Keychain"),
    ("Application Support", "Application Support"),
    (" senza ", " without "),
    (" con ", " with "),
    (" per ", " for "),
    (" del ", " of the "),
    (" della ", " of the "),
    (" dei ", " of the "),
    (" delle ", " of the "),
    (" nel ", " in the "),
    (" nella ", " in the "),
    (" sul ", " on the "),
    (" sulla ", " on the "),
    (" dal ", " from the "),
    (" dalla ", " from the "),
    (" al ", " to the "),
    (" alla ", " to the "),
    (" e ", " and "),
    (" o ", " or "),
    (" di ", " of "),
    (" da ", " from "),
    (" in ", " in "),
    (" un ", " a "),
    (" una ", " a "),
    (" il ", " the "),
    (" lo ", " the "),
    (" la ", " the "),
    (" i ", " the "),
    (" gli ", " the "),
    (" le ", " the "),
    (" non ", " not "),
    (" che ", " that "),
    (" questo ", " this "),
    (" questa ", " this "),
    (" qui", " here"),
    (" ora", " now"),
    (" prima", " first"),
    (" dopo", " after"),
    (" già", " already"),
    (" ancora", " still"),
    (" solo", " only"),
    (" anche", " also"),
    (" più", " more"),
    (" meno", " less"),
]


def escape_strings(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def heuristic_translate(s: str) -> str:
    if s in EXACT:
        return EXACT[s]
    out = s
    for a, b in FRAGMENTS:
        out = out.replace(a, b)
    # Light cleanup of doubled spaces / awkward articles left over
    out = re.sub(r"\s{2,}", " ", out).strip()
    return out


def main() -> None:
    strings: list[str] = load_strings()
    en_map: dict[str, str] = {}
    for s in strings:
        en_map[s] = heuristic_translate(s)

    OUT_EN.parent.mkdir(parents=True, exist_ok=True)
    OUT_IT.parent.mkdir(parents=True, exist_ok=True)

    def write_strings(path: Path, mapping: dict[str, str], identity: bool = False) -> None:
        lines = [
            "/* QS Agents Localizable — generated; Italian source keys */",
            "",
        ]
        for k in sorted(mapping.keys(), key=lambda x: (x.lower(), x)):
            v = k if identity else mapping[k]
            lines.append(f'"{escape_strings(k)}" = "{escape_strings(v)}";')
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    write_strings(OUT_EN, en_map, identity=False)
    write_strings(OUT_IT, en_map, identity=True)

    # Also emit JSON for runtime fallback / review
    json_path = ROOT / "QSAgents" / "Resources" / "L10nEn.json"
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(en_map, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    changed = sum(1 for k, v in en_map.items() if k != v)
    print(f"Wrote {OUT_EN} ({len(en_map)} keys, {changed} translated)")
    print(f"Wrote {OUT_IT}")
    print(f"Wrote {json_path}")


if __name__ == "__main__":
    main()
