import Foundation

enum SeedData {
    static let workspaces: [WorkspaceNav] = [
        .init(name: "qs-api", icon: "folder.fill", isActive: true),
        .init(name: "qs-ui", icon: "macwindow"),
        .init(name: "QSBoard", icon: "square.grid.2x2"),
        .init(name: "QSSwarm", icon: "point.3.connected.trianglepath.dotted"),
    ]

    static let agents: [AgentInstance] = [
        .init(
            name: "Claude-3.5-Sonnet",
            modelTag: "V3.5.12",
            status: .active,
            lines: [
                .init(text: "Found 2 vulnerability issues -- doctor for details", level: .warning),
                .init(text: "GET /v1/auth/session 200 OK", level: .success),
                .init(text: "Thinking: Analyzing dependency tree...", level: .thinking),
                .init(text: "Analyzing @qs/core-api...", level: .muted),
                .init(text: "Starting sub-process [agent:security-audit]", level: .info),
            ],
            promptPlaceholder: "Invia comando..."
        ),
        .init(
            name: "GPT-4o-Mini",
            modelTag: "LATEST",
            status: .thinking,
            lines: [
                .init(text: "Generando documentazione API...", level: .info),
                .init(text: "const apiResponse = \"Success\";", level: .code),
                .init(text: "Attendere prego...", level: .thinking),
            ],
            promptPlaceholder: "Scrivi un prompt..."
        ),
        .init(
            name: "DeepSeek-Coder",
            modelTag: "67B",
            status: .active,
            lines: [
                .init(text: "\"Repository indicizzato con successo\"", level: .success),
                .init(text: "Listening on port 8080...", level: .info),
            ],
            promptPlaceholder: "Analisi codice...",
            cpuUsage: 0.65
        ),
        .init(
            name: "",
            modelTag: "",
            status: .idle,
            lines: [],
            isPlaceholder: true
        ),
        .init(
            name: "System-Monitor",
            modelTag: "SYS",
            status: .active,
            lines: [
                .init(text: "Health check: OK", level: .success),
                .init(text: "Uptime: 14h 22m", level: .info),
                .init(text: "Nodes: 12 Online", level: .info),
            ],
            promptPlaceholder: "Query sistema..."
        ),
        .init(
            name: "Git-Helper",
            modelTag: "GIT",
            status: .active,
            lines: [
                .init(text: "commit", level: .code),
                .init(text: "feat: aggiunta gestione errori sidebar", level: .info),
                .init(text: "Syncing with 'origin/main'...", level: .muted),
            ],
            promptPlaceholder: "git / prompt..."
        ),
        .init(name: "Instance-7", modelTag: "—", status: .idle, lines: [], promptPlaceholder: "Attiva agente..."),
        .init(name: "Instance-8", modelTag: "—", status: .idle, lines: [], promptPlaceholder: "Attiva agente..."),
        .init(name: "Instance-9", modelTag: "—", status: .idle, lines: [], promptPlaceholder: "Attiva agente..."),
    ]

    static let skills: [AgentSkill] = [
        .init(
            name: "Security Audit Pro",
            category: .security,
            description: "Analisi delle vulnerabilità in tempo reale e monitoraggio delle dipendenze CVE.",
            isActive: true
        ),
        .init(
            name: "QSSEO",
            category: .growth,
            description: "Ottimizzazione automatica dei meta-tag e analisi della struttura semantica."
        ),
        .init(
            name: "QSGitHub",
            category: .workflow,
            description: "Gestione PR automatizzata, commit linting e deploy orchestrato."
        ),
        .init(
            name: "QSMemory",
            category: .memory,
            description: "Memoria contestuale condivisa"
        ),
        .init(
            name: "QSNotes",
            category: .memory,
            description: "Integrazione note e task"
        ),
    ]

    static let tasks: [AgentTask] = [
        .init(
            title: "Implementare validazione JWT nel modulo Auth",
            priority: .medio,
            column: .todo,
            assigneeModel: "Claude 3.5"
        ),
        .init(
            title: "Fix crash memoria nel loop di orchestrazione",
            priority: .critico,
            column: .todo,
            assigneeModel: "GPT-4o"
        ),
        .init(
            title: "Refactoring dei componenti SideNav in React",
            priority: .alto,
            column: .todo,
            assigneeModel: "Llama 3"
        ),
        .init(
            title: "Migrazione database PostgreSQL verso Supabase",
            priority: .alto,
            column: .inProgress,
            assigneeModel: "GPT-4o",
            progress: 0.62,
            isSelected: true
        ),
        .init(
            title: "Scrittura test unitari per controller utenti",
            priority: .medio,
            column: .inProgress,
            assigneeModel: "Claude 3.5",
            progress: 0.35
        ),
        .init(
            title: "Aggiornamento documentazione API v2",
            subtitle: "Review richiesta da Lead Architect",
            priority: .alto,
            column: .review,
            assigneeModel: "Llama 3"
        ),
    ]

    static let fileTree: [WorkspaceFile] = [
        .init(name: "src/", isDirectory: true, children: [
            .init(name: "components/", isDirectory: true, children: [
                .init(name: "Revisione_Codice.ts", language: "ts"),
                .init(name: "AgentLogic.js", language: "js"),
            ], isExpanded: true),
            .init(name: "public/", isDirectory: true, children: [], isExpanded: false),
        ], isExpanded: true),
        .init(name: "config.json", language: "json"),
    ]

    static let codeLines: [CodeLine] = [
        .init(number: 1, text: "import { Agent } from '@qs/core';"),
        .init(number: 2, text: "import { Workspace } from './types';"),
        .init(number: 3, text: ""),
        .init(number: 4, text: "export const initializeReview = (id: string) => {"),
        .init(number: 5, text: "  const context = Agent.getContext(id);", kind: .removed),
        .init(number: 6, text: "  const context = await", kind: .added),
        .init(number: 7, text: "    Agent.getEnhancedContext(id);", kind: .added),
        .init(number: 8, text: "  const traceId = uuid();", kind: .added),
        .init(number: 9, text: "  return {"),
        .init(number: 10, text: "    status: 'pending',"),
        .init(number: 11, text: "    timestamp: Date.now(),", kind: .removed),
        .init(number: 12, text: "    timestamp: new Date().toISOString(),", kind: .added),
        .init(number: 13, text: "    context"),
        .init(number: 14, text: "  };"),
        .init(number: 15, text: "};"),
    ]

    static let liveStream: [TerminalLine] = [
        .init(text: "[$] agent-opus: analizzando diff...", level: .info),
        .init(text: "[!] Warning: deprecated call in line 42", level: .warning),
        .init(text: "[$] agent-opus: suggerendo miglioramento context", level: .info),
        .init(text: "[OK] Miglioramento applicato con successo", level: .success),
        .init(text: "[$] agent-shell: riavvio server locale...", level: .info),
        .init(text: "[$] Listening on port 3000", level: .success),
    ]

    static let workspaceAgents: [AgentInstance] = [
        .init(
            name: "Claude-3-Opus",
            modelTag: "Architetto Senior",
            status: .active,
            tokenUsage: 0.75,
            role: "Architetto Senior"
        ),
        .init(
            name: "Dev-Shell-X",
            modelTag: "Compilazione",
            status: .idle,
            role: "Compilazione"
        ),
    ]

    static let swarmAgents: [SwarmAgent] = [
        .init(name: "REVISORE 1", detail: "Analisi qualità...", status: .active, x: 0.38, y: 0.22),
        .init(name: "REVISORE 2", detail: "In attesa di output.", status: .idle, x: 0.62, y: 0.22),
        .init(name: "BUILDER 1", detail: "Generazione moduli...", status: .thinking, x: 0.28, y: 0.48),
        .init(name: "BUILDER 2", detail: "Refactoring in corso.", status: .thinking, x: 0.50, y: 0.48),
        .init(name: "SCOUT 1", detail: "Crawling docs...", status: .active, x: 0.72, y: 0.48),
        .init(
            name: "COORDINATORE 1",
            detail: "Orchestrazione missione: Deployment_Alpha",
            status: .active,
            x: 0.50,
            y: 0.74,
            isCoordinator: true,
            progress: 0.58
        ),
    ]

    static var knowledgeNodes: [KnowledgeNode] {
        let core = KnowledgeNode(
            title: "PROGETTO CORE",
            isCore: true,
            x: 0.50,
            y: 0.42,
            confidence: 0.99,
            modelOrigin: "Sistema",
            entityType: "Root",
            description: "Nodo radice del grafo di conoscenza del progetto QS Agents.",
            related: ["Auth Flow", "Database Schema", "API Endpoints"]
        )
        let auth = KnowledgeNode(
            title: "Auth Flow",
            x: 0.32,
            y: 0.22,
            confidence: 0.96,
            description: "Flusso di autenticazione end-to-end con bearer token e session store.",
            related: ["API Endpoints", "PROGETTO CORE"]
        )
        let db = KnowledgeNode(
            title: "Database Schema",
            x: 0.68,
            y: 0.22,
            confidence: 0.91,
            description: "Schema relazionale e migrazioni verso Supabase.",
            related: ["PROGETTO CORE", "API Endpoints"]
        )
        let api = KnowledgeNode(
            title: "API Endpoints",
            isSelected: true,
            x: 0.50,
            y: 0.68,
            confidence: 0.984,
            modelOrigin: "GPT-4o",
            entityType: "Schema Tecnica",
            description: """
            Definizione degli endpoint RESTful per l'interfaccia utente:
            • GET /api/v1/health: Controllo stato sistema.
            • POST /api/v1/auth: Gestione autenticazione bearer token.
            • GET /api/v1/knowledge: Recupero grafo della memoria.
            """,
            tokenUsed: 2400,
            tokenLimit: 4000,
            related: ["Auth Flow end-to-end", "Database Schema v2"],
            updatedLabel: "Aggiornato 12 min fa",
            verified: true
        )
        return [core, auth, db, api]
    }

    static func makeEdges(nodes: [KnowledgeNode]) -> [KnowledgeEdge] {
        guard nodes.count >= 4 else { return [] }
        let core = nodes[0].id
        return [
            .init(from: core, to: nodes[1].id),
            .init(from: core, to: nodes[2].id),
            .init(from: core, to: nodes[3].id),
            .init(from: nodes[1].id, to: nodes[3].id),
            .init(from: nodes[2].id, to: nodes[3].id),
        ]
    }

    static let integrations: [AIIntegration] = [
        .init(name: "SpaceX AI", provider: "XAI / GROK", status: .notConfigured, icon: "bolt.fill", modelHint: "grok-4.5"),
        .init(name: "OpenAI", provider: "OPENAI", status: .notConfigured, icon: "brain", modelHint: "gpt-4.1"),
        .init(name: "Anthropic", provider: "ANTHROPIC", status: .notConfigured, icon: "brain.head.profile", modelHint: "opus-4.8 · sonnet-5"),
        .init(name: "Gemini", provider: "GOOGLE", status: .notConfigured, icon: "diamond.fill", modelHint: "2.5-pro"),
        .init(name: "OpenRouter", provider: "OPENROUTER", status: .notConfigured, icon: "arrow.triangle.branch", modelHint: "multi-model"),
        .init(name: "GitHub", provider: "GITHUB", status: .notConfigured, icon: "chevron.left.forwardslash.chevron.right", modelHint: "OAuth / PAT"),
    ]
}
