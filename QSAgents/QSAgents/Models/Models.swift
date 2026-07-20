import Foundation
import SwiftUI

// MARK: - Navigation

enum MainTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case dashboard = "Dashboard"
    case orchestrator = "Orchestrator"
    case monitor = "Monitor"

    var id: String { rawValue }

    /// Label in top bar
    var displayTitle: String {
        switch self {
        case .home: return "Home"
        case .dashboard: return "Terminali"
        case .orchestrator: return "Orchestrator"
        case .monitor: return "Knowledge"
        }
    }
}

enum OrchestratorMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case tasks = "QS Tasks"
    case swarm = "QS Swarm"
    case workspace = "Workspace"

    var id: String { rawValue }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case activeAgents = "Active Agents"
    case deployment = "Deployment"
    case logs = "Logs"
    case settings = "Settings"
    case integrations = "Integrazioni"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .workspaces: return "folder.fill"
        case .activeAgents: return "cpu"
        case .deployment: return "rocket"
        case .logs: return "terminal"
        case .settings: return "gearshape"
        case .integrations: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Agent

enum AgentStatus: String, Codable, CaseIterable {
    case idle, active, thinking, error

    var color: Color {
        switch self {
        case .idle: return QS.Color.agentIdle
        case .active: return QS.Color.agentActive
        case .thinking: return QS.Color.agentThinking
        case .error: return QS.Color.agentError
        }
    }

    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .active: return "ACTIVE"
        case .thinking: return "THINKING"
        case .error: return "ERROR"
        }
    }
}

enum LogLevel: String, Codable {
    case info, success, warning, error, code, thinking, muted

    var color: Color {
        switch self {
        case .info: return QS.Color.onSurfaceVariant
        case .success: return QS.Color.syntaxString
        case .warning: return QS.Color.agentThinking
        case .error: return QS.Color.agentError
        case .code: return QS.Color.primary
        case .thinking: return QS.Color.agentThinking
        case .muted: return QS.Color.outline
        }
    }
}

struct TerminalLine: Identifiable, Equatable {
    let id: UUID
    var text: String
    var level: LogLevel
    var timestamp: Date

    init(id: UUID = UUID(), text: String, level: LogLevel = .info, timestamp: Date = .now) {
        self.id = id
        self.text = text
        self.level = level
        self.timestamp = timestamp
    }
}

struct AgentInstance: Identifiable, Equatable {
    let id: UUID
    var name: String
    var modelTag: String
    var status: AgentStatus
    var lines: [TerminalLine]
    var promptPlaceholder: String
    var cpuUsage: Double?
    var tokenUsage: Double?
    var isPlaceholder: Bool
    var role: String?

    init(
        id: UUID = UUID(),
        name: String,
        modelTag: String,
        status: AgentStatus = .idle,
        lines: [TerminalLine] = [],
        promptPlaceholder: String = "Invia comando...",
        cpuUsage: Double? = nil,
        tokenUsage: Double? = nil,
        isPlaceholder: Bool = false,
        role: String? = nil
    ) {
        self.id = id
        self.name = name
        self.modelTag = modelTag
        self.status = status
        self.lines = lines
        self.promptPlaceholder = promptPlaceholder
        self.cpuUsage = cpuUsage
        self.tokenUsage = tokenUsage
        self.isPlaceholder = isPlaceholder
        self.role = role
    }
}

// MARK: - Skills

enum SkillCategory: String, Codable {
    case security = "SECURITY"
    case growth = "GROWTH"
    case workflow = "WORKFLOW"
    case memory = "MEMORY"

    var tint: Color {
        switch self {
        case .security: return QS.Color.agentActive
        case .growth: return QS.Color.primarySolid
        case .workflow: return QS.Color.secondary
        case .memory: return QS.Color.outline
        }
    }

    var icon: String {
        switch self {
        case .security: return "shield.lefthalf.filled"
        case .growth: return "chart.line.uptrend.xyaxis"
        case .workflow: return "arrow.triangle.branch"
        case .memory: return "brain.head.profile"
        }
    }
}

struct AgentSkill: Identifiable, Equatable {
    let id: UUID
    var name: String
    var category: SkillCategory
    var description: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, category: SkillCategory, description: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.isActive = isActive
    }
}

// MARK: - Tasks

enum TaskPriority: String, Codable, CaseIterable {
    case critico = "CRITICO"
    case alto = "ALTO"
    case medio = "MEDIO"

    var color: Color {
        switch self {
        case .critico: return QS.Color.chipCritical
        case .alto: return QS.Color.chipHigh
        case .medio: return QS.Color.chipMedium
        }
    }
}

enum TaskColumn: String, Codable, CaseIterable, Identifiable {
    case todo = "DA FARE"
    case inProgress = "IN CORSO"
    case review = "IN REVISIONE"
    case done = "COMPLETATE"

    var id: String { rawValue }

    var accent: Color {
        switch self {
        case .todo: return QS.Color.agentIdle
        case .inProgress: return QS.Color.agentThinking
        case .review: return QS.Color.secondary
        case .done: return QS.Color.agentActive
        }
    }
}

/// Provenance of a board task (A3).
enum TaskSource: String, Codable, Equatable {
    case manual
    case orchestrator
    case repoSnapshot = "repo_snapshot"
    case gitLog = "git_log"
    case gitStatus = "git_status"
    case manifest
    case template
    case bootstrap

    var shortLabel: String {
        switch self {
        case .manual: return "manuale"
        case .orchestrator: return "orchestrator"
        case .repoSnapshot: return "repo"
        case .gitLog: return "git log"
        case .gitStatus: return "git status"
        case .manifest: return "manifest"
        case .template: return "template"
        case .bootstrap: return "bootstrap"
        }
    }
}

struct AgentTask: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var subtitle: String?
    var priority: TaskPriority
    var column: TaskColumn
    var assigneeModel: String
    var progress: Double?
    var isSelected: Bool
    /// Absolute workspace path this task belongs to (optional filter).
    var workspacePath: String?
    /// When set, terminal exit can auto-complete / fail this task.
    var linkedTerminalID: UUID?
    /// Where this task came from (A3 provenance).
    var source: TaskSource
    /// Concrete signals that justify the task (commits, files, manifests).
    var evidence: [String]
    /// C1: tasks from the same smart plan / swarm batch share this id.
    var planId: UUID?
    /// C1: must be DONE before this task is unblocked (DAG edges).
    var dependsOn: [UUID]
    /// Cumulative LLM tokens attributed to this task (session + board).
    var tokensUsed: Int
    /// Estimated USD for `tokensUsed` (priority + model tier).
    var estimatedCostUSD: Double

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        priority: TaskPriority,
        column: TaskColumn,
        assigneeModel: String,
        progress: Double? = nil,
        isSelected: Bool = false,
        workspacePath: String? = nil,
        linkedTerminalID: UUID? = nil,
        source: TaskSource = .manual,
        evidence: [String] = [],
        planId: UUID? = nil,
        dependsOn: [UUID] = [],
        tokensUsed: Int = 0,
        estimatedCostUSD: Double = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.priority = priority
        self.column = column
        self.assigneeModel = assigneeModel
        self.progress = progress
        self.isSelected = isSelected
        self.workspacePath = workspacePath
        self.linkedTerminalID = linkedTerminalID
        self.source = source
        self.evidence = evidence
        self.planId = planId
        self.dependsOn = dependsOn
        self.tokensUsed = tokensUsed
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// True when every dependency is done (or none).
    var hasOpenDependencies: Bool { !dependsOn.isEmpty }

    /// Cost per 1k tokens — higher priority ≈ pricier model tier for stima.
    var costPer1kUSD: Double {
        let base: Double
        let m = assigneeModel.lowercased()
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet") {
            base = 0.003
        } else if m.contains("gpt-4") || m.contains("o1") || m.contains("o3") {
            base = 0.0025
        } else if m.contains("grok") || m.contains("gpt-4o-mini") || m.contains("flash") {
            base = 0.0015
        } else if m == "local" || m.contains("local") {
            base = 0.0002
        } else {
            base = 0.002
        }
        switch priority {
        case .critico: return base * 1.35
        case .alto: return base * 1.1
        case .medio: return base
        }
    }

    /// Files touched by agents — `file:` / `files:` tags plus paths mined from older log/evidence.
    var changedFiles: [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip wrapping backticks from chat-style lists
            if p.hasPrefix("`"), p.hasSuffix("`"), p.count > 2 {
                p = String(p.dropFirst().dropLast())
            }
            guard !p.isEmpty, !seen.contains(p) else { return }
            seen.insert(p)
            out.append(p)
        }
        let ext = #"(?:css|js|ts|tsx|jsx|html|json|md|swift|scss|mjs|cjs|vue|svelte|py|go|rs|toml|yml|yaml)"#
        for e in evidence {
            if e.hasPrefix("file:") {
                add(String(e.dropFirst(5)))
                continue
            }
            // Claude supervisor / git batch: "files:a.swift, b.js" or "files: a, b"
            if e.hasPrefix("files:") {
                let rest = String(e.dropFirst(6))
                for part in rest.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
                    add(String(part))
                }
                continue
            }
            // Legacy: "Scritto /abs/.../www/foo.css" or "PATCH PROPOSTA · /abs/.../bar.js"
            if let r = e.range(of: #"(?:Scritto|PATCH PROPOSTA[^\n]*·)\s+(\S+\."# + ext + #")"#, options: .regularExpression) {
                let m = String(e[r])
                if let path = m.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) {
                    if let idx = path.range(of: "/www/") {
                        add("www/" + path[idx.upperBound...])
                    } else if path.contains("/") {
                        add((path as NSString).lastPathComponent)
                    } else {
                        add(path)
                    }
                }
            }
            if e.contains("path\":\"") || e.contains("path=") {
                let pattern = #"path["\s:=]+([A-Za-z0-9_./\-]+\."# + ext + #")"#
                if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let ns = e as NSString
                    let matches = re.matches(in: e, range: NSRange(location: 0, length: ns.length))
                    for m in matches where m.numberOfRanges > 1 {
                        add(ns.substring(with: m.range(at: 1)))
                    }
                }
            }
        }
        return out
    }

    /// True when DONE was stamped without a real builder finish on this card.
    var wasAutoCompletedWithoutWork: Bool {
        evidence.contains { $0.hasPrefix("goal-auto-done:") }
            && !evidence.contains(where: { $0.hasPrefix("file:") || $0.contains("Scritto ") })
    }

    // Backward-compatible decode for tasks saved before A3/C1.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        priority = try c.decode(TaskPriority.self, forKey: .priority)
        column = try c.decode(TaskColumn.self, forKey: .column)
        assigneeModel = try c.decode(String.self, forKey: .assigneeModel)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        linkedTerminalID = try c.decodeIfPresent(UUID.self, forKey: .linkedTerminalID)
        source = try c.decodeIfPresent(TaskSource.self, forKey: .source) ?? .manual
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        planId = try c.decodeIfPresent(UUID.self, forKey: .planId)
        dependsOn = try c.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        tokensUsed = try c.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        estimatedCostUSD = try c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0
    }
}

// MARK: - Workspace

struct WorkspaceFile: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isDirectory: Bool
    var children: [WorkspaceFile]
    var isExpanded: Bool
    var language: String?

    init(
        id: UUID = UUID(),
        name: String,
        isDirectory: Bool = false,
        children: [WorkspaceFile] = [],
        isExpanded: Bool = false,
        language: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isExpanded = isExpanded
        self.language = language
    }
}

struct CodeLine: Identifiable, Equatable {
    let id: UUID
    var number: Int
    var text: String
    var kind: CodeLineKind

    init(id: UUID = UUID(), number: Int, text: String, kind: CodeLineKind = .normal) {
        self.id = id
        self.number = number
        self.text = text
        self.kind = kind
    }
}

enum CodeLineKind {
    case normal, added, removed
}

// MARK: - Knowledge

struct KnowledgeNode: Identifiable, Equatable {
    let id: UUID
    var title: String
    var isCore: Bool
    var isSelected: Bool
    var x: CGFloat
    var y: CGFloat
    var confidence: Double
    var modelOrigin: String
    var entityType: String
    var description: String
    var tokenUsed: Int
    var tokenLimit: Int
    var related: [String]
    var updatedLabel: String
    var verified: Bool

    init(
        id: UUID = UUID(),
        title: String,
        isCore: Bool = false,
        isSelected: Bool = false,
        x: CGFloat,
        y: CGFloat,
        confidence: Double = 0.9,
        modelOrigin: String = "GPT-4o",
        entityType: String = "Schema Tecnica",
        description: String = "",
        tokenUsed: Int = 2400,
        tokenLimit: Int = 4000,
        related: [String] = [],
        updatedLabel: String = "Aggiornato 12 min fa",
        verified: Bool = true
    ) {
        self.id = id
        self.title = title
        self.isCore = isCore
        self.isSelected = isSelected
        self.x = x
        self.y = y
        self.confidence = confidence
        self.modelOrigin = modelOrigin
        self.entityType = entityType
        self.description = description
        self.tokenUsed = tokenUsed
        self.tokenLimit = tokenLimit
        self.related = related
        self.updatedLabel = updatedLabel
        self.verified = verified
    }
}

struct KnowledgeEdge: Identifiable, Equatable {
    let id: UUID
    var from: UUID
    var to: UUID

    init(id: UUID = UUID(), from: UUID, to: UUID) {
        self.id = id
        self.from = from
        self.to = to
    }
}

// MARK: - Swarm

struct SwarmAgent: Identifiable, Equatable {
    let id: UUID
    var name: String
    var detail: String
    var status: AgentStatus
    var x: CGFloat
    var y: CGFloat
    var isCoordinator: Bool
    var progress: Double?

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        status: AgentStatus,
        x: CGFloat,
        y: CGFloat,
        isCoordinator: Bool = false,
        progress: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.status = status
        self.x = x
        self.y = y
        self.isCoordinator = isCoordinator
        self.progress = progress
    }
}

// MARK: - Integrations

enum IntegrationStatus: String {
    case connected = "CONNESSO"
    case notConfigured = "NON CONFIGURATO"

    var color: Color {
        switch self {
        case .connected: return QS.Color.agentActive
        case .notConfigured: return QS.Color.agentIdle
        }
    }
}

struct AIIntegration: Identifiable, Equatable {
    let id: UUID
    var name: String
    var provider: String
    var status: IntegrationStatus
    var icon: String
    var modelHint: String?

    init(
        id: UUID = UUID(),
        name: String,
        provider: String,
        status: IntegrationStatus,
        icon: String,
        modelHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.status = status
        self.icon = icon
        self.modelHint = modelHint
    }
}

// MARK: - Workspace nav item

struct WorkspaceNav: Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, icon: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isActive = isActive
    }
}
