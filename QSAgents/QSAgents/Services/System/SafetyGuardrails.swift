import Foundation
import Combine

// MARK: - Environment

enum AgentEnvironment: String, CaseIterable, Identifiable, Codable {
    case development = "development"
    case staging = "staging"
    case production = "production"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .development: return "Development"
        case .staging: return "Staging"
        case .production: return "Production / Live"
        }
    }

    var shortLabel: String {
        switch self {
        case .development: return "DEV"
        case .staging: return "STG"
        case .production: return "LIVE"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .development: return 0x32D74B
        case .staging: return 0xFFD60A
        case .production: return 0xFF453A
        }
    }

    var rank: Int {
        switch self {
        case .development: return 0
        case .staging: return 1
        case .production: return 2
        }
    }
}

// MARK: - Agent roles (per-agent policy)

enum AgentRole: String, CaseIterable, Identifiable, Codable {
    case general = "general"
    case scout = "scout"
    case builder = "builder"
    case reviewer = "reviewer"
    case coordinator = "coordinator"
    case deployer = "deployer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .scout: return "Scout (read-only-ish)"
        case .builder: return "Builder"
        case .reviewer: return "Reviewer"
        case .coordinator: return "Coordinator"
        case .deployer: return "Deployer"
        }
    }

    var icon: String {
        switch self {
        case .general: return "person"
        case .scout: return "binoculars"
        case .builder: return "hammer"
        case .reviewer: return "eyeglasses"
        case .coordinator: return "person.3"
        case .deployer: return "airplane.departure"
        }
    }

    var blurb: String {
        switch self {
        case .general: return "Permessi standard, segue le regole globali"
        case .scout: return "Esplora e legge: niente DB wipe, niente destroy, niente force-push"
        case .builder: return "Può buildare/testare; DB distruttivi e deploy bloccati"
        case .reviewer: return "Review e git safe; niente infra destroy"
        case .coordinator: return "Orchestra; conferma su azioni sensibili"
        case .deployer: return "Deploy consentito (con guardrail env); wipe DB ancora bloccato"
        }
    }
}

struct AgentRolePolicy: Equatable, Codable, Identifiable {
    var role: AgentRole
    var canDatabaseDestructive: Bool
    var canFilesystemDestructive: Bool
    var canGitForce: Bool
    var canCloudDestroy: Bool
    var canDeploy: Bool
    var canExposeSecrets: Bool

    var id: String { role.rawValue }

    static let defaults: [AgentRolePolicy] = [
        .init(role: .scout, canDatabaseDestructive: false, canFilesystemDestructive: false, canGitForce: false, canCloudDestroy: false, canDeploy: false, canExposeSecrets: false),
        .init(role: .builder, canDatabaseDestructive: false, canFilesystemDestructive: true, canGitForce: false, canCloudDestroy: false, canDeploy: false, canExposeSecrets: false),
        .init(role: .reviewer, canDatabaseDestructive: false, canFilesystemDestructive: false, canGitForce: false, canCloudDestroy: false, canDeploy: false, canExposeSecrets: false),
        .init(role: .coordinator, canDatabaseDestructive: false, canFilesystemDestructive: true, canGitForce: false, canCloudDestroy: false, canDeploy: false, canExposeSecrets: false),
        .init(role: .deployer, canDatabaseDestructive: false, canFilesystemDestructive: true, canGitForce: false, canCloudDestroy: false, canDeploy: true, canExposeSecrets: false),
        .init(role: .general, canDatabaseDestructive: true, canFilesystemDestructive: true, canGitForce: true, canCloudDestroy: true, canDeploy: true, canExposeSecrets: true),
    ]
}

// MARK: - Allowlist

enum AllowlistMode: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case warn = "warn"
    case enforce = "enforce"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Spenta"
        case .warn: return "Avvisa"
        case .enforce: return "Blocca fuori lista"
        }
    }
}

struct ProjectAllowlistEntry: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var path: String
    var name: String

    init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        let resolved = (path as NSString).standardizingPath
        self.path = resolved
        self.name = name ?? URL(fileURLWithPath: resolved).lastPathComponent
    }
}

// MARK: - Rules

enum GuardrailSeverity: String, CaseIterable, Codable {
    case info
    case warn
    case confirm
    case dualConfirm  // two-person rule
    case block

    var displayName: String {
        switch self {
        case .info: return "Info"
        case .warn: return "Avviso"
        case .confirm: return "1 conferma"
        case .dualConfirm: return "2 persone"
        case .block: return "Blocco"
        }
    }

    var rank: Int {
        switch self {
        case .info: return 0
        case .warn: return 1
        case .confirm: return 2
        case .dualConfirm: return 3
        case .block: return 4
        }
    }
}

enum GuardrailCategory: String, CaseIterable, Codable, Identifiable {
    case database, filesystem, git, network, secrets, process, cloud, custom, allowlist, role

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .database: return "Database"
        case .filesystem: return "Filesystem"
        case .git: return "Git"
        case .network: return "Network / Deploy"
        case .secrets: return "Secrets"
        case .process: return "Processi"
        case .cloud: return "Cloud / Infra"
        case .custom: return "Custom"
        case .allowlist: return "Allowlist"
        case .role: return "Ruolo agente"
        }
    }

    var icon: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .filesystem: return "folder.badge.minus"
        case .git: return "arrow.triangle.branch"
        case .network: return "network"
        case .secrets: return "key.fill"
        case .process: return "cpu"
        case .cloud: return "cloud.fill"
        case .custom: return "slider.horizontal.3"
        case .allowlist: return "checkmark.shield"
        case .role: return "person.badge.key"
        }
    }
}

struct GuardrailRule: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var category: GuardrailCategory
    var pattern: String
    var severity: GuardrailSeverity
    var appliesFrom: AgentEnvironment
    var enabled: Bool
    var description: String
    var message: String
    /// If set, rule only applies to these roles (empty = all roles).
    var roles: [AgentRole]

    init(
        id: UUID = UUID(),
        name: String,
        category: GuardrailCategory,
        pattern: String,
        severity: GuardrailSeverity,
        appliesFrom: AgentEnvironment = .development,
        enabled: Bool = true,
        description: String,
        message: String,
        roles: [AgentRole] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.pattern = pattern
        self.severity = severity
        self.appliesFrom = appliesFrom
        self.enabled = enabled
        self.description = description
        self.message = message
        self.roles = roles
    }

    func applies(to env: AgentEnvironment, role: AgentRole) -> Bool {
        guard appliesFrom.rank <= env.rank else { return false }
        if roles.isEmpty { return true }
        return roles.contains(role)
    }
}

// MARK: - Context & decision

struct SafetyContext: Equatable {
    var source: String
    var path: String?
    var role: AgentRole

    static func terminal(path: String? = nil, role: AgentRole = .general) -> SafetyContext {
        .init(source: "terminal", path: path, role: role)
    }
}

enum SafetyDecision: Equatable {
    case allow
    case allowWithWarning(String, rule: GuardrailRule)
    case requireConfirm(String, rule: GuardrailRule)
    case requireDualConfirm(String, rule: GuardrailRule)
    case block(String, rule: GuardrailRule)

    var isBlocked: Bool {
        if case .block = self { return true }
        return false
    }

    var needsConfirm: Bool {
        switch self {
        case .requireConfirm, .requireDualConfirm: return true
        default: return false
        }
    }

    var userMessage: String {
        switch self {
        case .allow: return ""
        case .allowWithWarning(let m, _), .requireConfirm(let m, _),
             .requireDualConfirm(let m, _), .block(let m, _):
            return m
        }
    }

    var rule: GuardrailRule? {
        switch self {
        case .allow: return nil
        case .allowWithWarning(_, let r), .requireConfirm(_, let r),
             .requireDualConfirm(_, let r), .block(_, let r):
            return r
        }
    }

    var rank: Int {
        switch self {
        case .allow: return 0
        case .allowWithWarning: return 1
        case .requireConfirm: return 2
        case .requireDualConfirm: return 3
        case .block: return 4
        }
    }
}

struct SafetyAuditEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let command: String
    let environment: AgentEnvironment
    let decision: String
    let ruleName: String?
    let source: String
    let role: String?
    let path: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        command: String,
        environment: AgentEnvironment,
        decision: String,
        ruleName: String?,
        source: String,
        role: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.environment = environment
        self.decision = decision
        self.ruleName = ruleName
        self.source = source
        self.role = role
        self.path = path
    }
}

// MARK: - Policy store

@MainActor
final class SafetyGuardrails: ObservableObject {
    @Published var environment: AgentEnvironment = .development
    @Published var rules: [GuardrailRule] = SafetyGuardrails.defaultRules
    @Published var enabled: Bool = true
    @Published var auditLog: [SafetyAuditEntry] = []
    @Published private(set) var sessionApprovals: Set<String> = []
    @Published var lastDecision: SafetyDecision = .allow
    @Published var pendingConfirm: PendingConfirm?

    /// Injected: signed JSONL audit + Slack/PagerDuty.
    weak var signing: ApprovalSigningService?
    weak var remote: RemoteApprovalNotifier?

    // Allowlist
    @Published var allowlistMode: AllowlistMode = .warn
    @Published var projectAllowlist: [ProjectAllowlistEntry] = []

    // Two-person
    @Published var twoPersonEnabled: Bool = true
    @Published var twoPersonFrom: AgentEnvironment = .production
    @Published var secondApproverName: String = "Second Approver"

    // Per-role
    @Published var rolePolicies: [AgentRolePolicy] = AgentRolePolicy.defaults
    @Published var defaultAgentRole: AgentRole = .builder

    /// True after first-launch recommended setup (or manual button).
    @Published var recommendedSetupApplied: Bool = false

    struct PendingConfirm: Identifiable, Equatable {
        let id: UUID
        let command: String
        let path: String?
        let rule: GuardrailRule
        let source: String
        let message: String
        let role: AgentRole
        var requiresDual: Bool
        var firstApproverName: String?
        var awaitingSecond: Bool
        /// One-time code sent to Slack for remote 2nd approval.
        var remoteCode: String?

        init(
            id: UUID = UUID(),
            command: String,
            path: String?,
            rule: GuardrailRule,
            source: String,
            message: String,
            role: AgentRole = .general,
            requiresDual: Bool = false,
            firstApproverName: String? = nil,
            awaitingSecond: Bool = false,
            remoteCode: String? = nil
        ) {
            self.id = id
            self.command = command
            self.path = path
            self.rule = rule
            self.source = source
            self.message = message
            self.role = role
            self.requiresDual = requiresDual
            self.firstApproverName = firstApproverName
            self.awaitingSecond = awaitingSecond
            self.remoteCode = remoteCode
        }
    }

    private let envKey = "qs.safety.environment"
    private let enabledKey = "qs.safety.enabled"
    private let rulesKey = "qs.safety.rules.v2"
    private let allowModeKey = "qs.safety.allowlist.mode"
    private let allowListKey = "qs.safety.allowlist.paths"
    private let twoPersonKey = "qs.safety.twoperson"
    private let twoPersonFromKey = "qs.safety.twoperson.from"
    private let secondNameKey = "qs.safety.second.name"
    private let rolesKey = "qs.safety.roles.v1"
    private let defaultRoleKey = "qs.safety.defaultRole"
    private let recommendedKey = "qs.safety.recommendedApplied.v1"

    init() {
        SecondApprovalPINStore.migrateLegacyIfNeeded()
        load()
    }

    var needsRecommendedSetup: Bool { !recommendedSetupApplied }

    // MARK: - Evaluate

    func evaluate(_ raw: String, source: String = "terminal") -> SafetyDecision {
        evaluate(raw, context: SafetyContext(source: source, path: nil, role: defaultAgentRole))
    }

    func evaluate(_ raw: String, context: SafetyContext) -> SafetyDecision {
        guard enabled else { return .allow }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .allow }

        if sessionApprovals.contains(approvalKey(command: command, path: context.path)) {
            return .allow
        }

        // Claude Code CLI (orchestrator delegate) — always allow the binary itself.
        if Self.isCodingCLIBinaryCommand(command) {
            return .allow
        }

        var worst: SafetyDecision = .allow
        let role = context.role

        // 1) Project allowlist (path)
        if let path = context.path, allowlistMode != .off {
            if !isPathAllowed(path) {
                let synthetic = GuardrailRule(
                    name: "Project allowlist",
                    category: .allowlist,
                    pattern: "allowlist",
                    severity: allowlistMode == .enforce ? .block : .warn,
                    description: "Path fuori allowlist",
                    message: "Path non in allowlist progetti: `\(path)`"
                )
                let msg = """
                🛡️ **Allowlist progetti**
                Path: `\(path)`
                Non è tra i progetti autorizzati.

                Aggiungilo in Sicurezza → Allowlist, oppure lavora dentro un progetto consentito.
                """
                if allowlistMode == .enforce {
                    worst = merge(worst, .block(msg, rule: synthetic))
                } else {
                    worst = merge(worst, .allowWithWarning(msg, rule: synthetic))
                }
            }
        }

        // 2) Role capability matrix
        if let roleHit = evaluateRole(command: command, role: role) {
            worst = merge(worst, roleHit)
        }

        // 3) Pattern rules
        for rule in rules where rule.enabled && rule.applies(to: environment, role: role) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(command.startIndex..., in: command)
            guard regex.firstMatch(in: command, options: [], range: range) != nil else { continue }

            var severity = rule.severity
            // Escalate confirm → dual on LIVE if two-person on
            if severity == .confirm, shouldUseTwoPerson {
                severity = .dualConfirm
            }
            if severity == .dualConfirm, !shouldUseTwoPerson {
                severity = .confirm
            }

            let msg = """
            \(rule.message)

            Regola: **\(rule.name)** · Env: **\(environment.shortLabel)** · Ruolo: **\(role.displayName)**
            """
            let decision: SafetyDecision
            switch severity {
            case .info, .warn:
                decision = .allowWithWarning(msg, rule: rule)
            case .confirm:
                decision = .requireConfirm(msg, rule: rule)
            case .dualConfirm:
                decision = .requireDualConfirm(msg + "\n\n**Two-person rule**: serve seconda approvazione (\(secondApproverName)).", rule: rule)
            case .block:
                decision = .block(msg, rule: rule)
            }
            worst = merge(worst, decision)
        }

        // 4) LIVE heuristic
        if environment == .production {
            if command.range(of: #"\b(prod|production|live)\b"#, options: .regularExpression) != nil,
               command.range(of: #"\b(drop|delete|destroy|truncate|rm\s+-rf)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                let synthetic = GuardrailRule(
                    name: "LIVE keyword + destructive",
                    category: .custom,
                    pattern: "prod",
                    severity: .block,
                    appliesFrom: .production,
                    description: "Heuristic",
                    message: "Operazione distruttiva su ambiente LIVE bloccata."
                )
                worst = merge(worst, .block(synthetic.message, rule: synthetic))
            }
        }

        lastDecision = worst
        log(command: command, decision: worst, context: context)
        return worst
    }

    private var shouldUseTwoPerson: Bool {
        twoPersonEnabled && twoPersonFrom.rank <= environment.rank
    }

    // MARK: - Role matrix

    private func policy(for role: AgentRole) -> AgentRolePolicy {
        rolePolicies.first { $0.role == role } ?? AgentRolePolicy.defaults.first { $0.role == role }!
    }

    private func evaluateRole(command: String, role: AgentRole) -> SafetyDecision? {
        let p = policy(for: role)
        let lower = command.lowercased()

        func hit(_ name: String, _ cat: GuardrailCategory, _ message: String) -> SafetyDecision {
            let rule = GuardrailRule(
                name: name,
                category: .role,
                pattern: role.rawValue,
                severity: .block,
                description: "Policy ruolo \(role.displayName)",
                message: message,
                roles: [role]
            )
            return .block("""
            🛡️ **Policy ruolo \(role.displayName)**

            \(message)

            I \(role.displayName) non possono eseguire questa classe di azioni. Usa un ruolo con permessi adeguati o eleva in Sicurezza → Ruoli.
            """, rule: rule)
        }

        // Database destructive patterns
        if !p.canDatabaseDestructive {
            let dbPat = #"\b(drop\s+(database|schema|table)|truncate|migrate:fresh|migrate:reset|db:wipe|db:drop|prisma\s+migrate\s+reset)\b"#
            if lower.range(of: dbPat, options: .regularExpression) != nil {
                return hit("Role: no DB destructive", .database, "Ruolo \(role.displayName): operazioni DB distruttive vietate.")
            }
        }
        if !p.canFilesystemDestructive {
            if lower.range(of: #"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b"#, options: .regularExpression) != nil {
                return hit("Role: no rm -rf", .filesystem, "Ruolo \(role.displayName): rm -rf non consentito.")
            }
        }
        if !p.canGitForce {
            if lower.range(of: #"git\s+push\s+.*(--force|-f)"#, options: .regularExpression) != nil {
                return hit("Role: no force-push", .git, "Ruolo \(role.displayName): force-push vietato.")
            }
        }
        if !p.canCloudDestroy {
            if lower.range(of: #"\b(terraform\s+destroy|pulumi\s+destroy|helm\s+uninstall|kubectl\s+delete)\b"#, options: .regularExpression) != nil {
                return hit("Role: no cloud destroy", .cloud, "Ruolo \(role.displayName): destroy/delete infra vietato.")
            }
        }
        if !p.canDeploy {
            if lower.range(of: #"\b(kubectl\s+apply|helm\s+upgrade|vercel\s+deploy|fly\s+deploy|aws\s+deploy)\b"#, options: .regularExpression) != nil {
                return hit("Role: no deploy", .network, "Ruolo \(role.displayName): deploy non consentito.")
            }
        }
        if !p.canExposeSecrets {
            if lower.range(of: #"\b(cat|echo|printenv)\b.*\b(\.env|secret|api_key|password)\b"#, options: .regularExpression) != nil {
                return hit("Role: no secrets dump", .secrets, "Ruolo \(role.displayName): esposizione secrets non consentita.")
            }
        }
        return nil
    }

    // MARK: - Claude Code / allowlist helpers

    /// True for bare coding CLI (`claude`, `grok`, …) or absolute path (no args).
    static func isCodingCLIBinaryCommand(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(["claude", "grok", "grok-cli", "xai"])
        if allowed.contains(c) { return true }
        let base = (c as NSString).lastPathComponent
        guard allowed.contains(base) else { return false }
        if c.contains(";") || c.contains("|") || c.contains("&") || c.contains("`") || c.contains("$") {
            return false
        }
        let parts = c.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 1 else { return false }
        return c.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: c)
    }

    /// Legacy alias.
    static func isClaudeCodeBinaryCommand(_ command: String) -> Bool {
        isCodingCLIBinaryCommand(command)
    }

    func isPathAllowed(_ path: String) -> Bool {
        if projectAllowlist.isEmpty { return allowlistMode == .off }
        let resolved = (path as NSString).standardizingPath
        return projectAllowlist.contains { entry in
            resolved == entry.path || resolved.hasPrefix(entry.path + "/")
        }
    }

    func addAllowlistPath(_ path: String, name: String? = nil) {
        let entry = ProjectAllowlistEntry(path: path, name: name)
        guard !projectAllowlist.contains(where: { $0.path == entry.path }) else { return }
        projectAllowlist.append(entry)
        persist()
    }

    func removeAllowlist(id: UUID) {
        projectAllowlist.removeAll { $0.id == id }
        persist()
    }

    func importAllowlist(from paths: [String]) {
        for p in paths { addAllowlistPath(p) }
    }

    // MARK: - Pending / dual approval

    func requestConfirm(
        command: String,
        path: String?,
        source: String,
        role: AgentRole = .general
    ) -> PendingConfirm? {
        let ctx = SafetyContext(source: source, path: path, role: role)
        let decision = evaluate(command, context: ctx)
        switch decision {
        case .requireConfirm(let msg, let rule):
            let pending = PendingConfirm(
                command: command, path: path, rule: rule, source: source,
                message: msg, role: role, requiresDual: false
            )
            pendingConfirm = pending
            recordSigned(
                .pendingSingle, command: command, path: path, rule: rule.name,
                role: role.rawValue, source: source, first: nil, second: nil
            )
            return pending
        case .requireDualConfirm(let msg, let rule):
            let pending = PendingConfirm(
                command: command, path: path, rule: rule, source: source,
                message: msg, role: role, requiresDual: true, awaitingSecond: false
            )
            pendingConfirm = pending
            recordSigned(
                .pendingDual, command: command, path: path, rule: rule.name,
                role: role.rawValue, source: source, first: nil, second: nil
            )
            // Fire-and-forget remote notify
            Task { [weak self] in
                guard let self else { return }
                let code = await self.remote?.notifyDualPending(
                    command: command,
                    path: path,
                    environment: self.environment.displayName,
                    ruleName: rule.name,
                    firstApproverHint: nil,
                    host: ProcessInfo.processInfo.hostName
                )
                await MainActor.run {
                    if var live = self.pendingConfirm, live.command == command {
                        live.remoteCode = code
                        self.pendingConfirm = live
                    }
                    if let code {
                        self.recordSigned(
                            .remoteNotified, command: command, path: path, rule: rule.name,
                            role: role.rawValue, source: source, first: nil, second: nil,
                            remoteCode: code
                        )
                    }
                }
            }
            return pending
        default:
            return nil
        }
    }

    /// First person approval (operator).
    func approveFirst(by name: String = NSFullUserName()) -> Bool {
        guard var p = pendingConfirm else { return false }
        if p.requiresDual {
            p.firstApproverName = name.isEmpty ? NSUserName() : name
            p.awaitingSecond = true
            pendingConfirm = p
            auditLog.insert(SafetyAuditEntry(
                command: p.command,
                environment: environment,
                decision: "FIRST_APPROVED",
                ruleName: p.rule.name,
                source: p.source,
                role: p.role.rawValue,
                path: p.path
            ), at: 0)
            trimAudit()
            recordSigned(
                .firstApproved, command: p.command, path: p.path, rule: p.rule.name,
                role: p.role.rawValue, source: p.source, first: p.firstApproverName, second: nil,
                remoteCode: p.remoteCode
            )
            Task { [weak self] in
                await self?.remote?.notifyFirstApproved(
                    command: p.command,
                    first: p.firstApproverName ?? name,
                    ruleName: p.rule.name,
                    remoteCode: p.remoteCode
                )
            }
            return false // not fully approved yet
        } else {
            finalizeApproval(p)
            return true
        }
    }

    /// Second person: name + PIN **or** remote Slack code.
    func approveSecond(name: String, pin: String, remoteCode: String? = nil) -> (ok: Bool, error: String?) {
        guard let p = pendingConfirm, p.requiresDual, p.awaitingSecond else {
            return (false, "Nessuna doppia approvazione in attesa")
        }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty {
            return (false, "Inserisci il nome del secondo approvatore")
        }
        if let first = p.firstApproverName, first.lowercased() == n.lowercased() {
            return (false, "Il secondo approvatore deve essere una persona diversa dalla prima")
        }

        // Path A: remote code from Slack
        let code = (remoteCode ?? pin).trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeRemoteCode = code.contains("-") && code.count >= 8
        if looksLikeRemoteCode, let remote {
            let check = remote.consumeRemoteCode(code, forCommand: p.command)
            if check.ok {
                recordSigned(
                    .remoteCodeUsed, command: p.command, path: p.path, rule: p.rule.name,
                    role: p.role.rawValue, source: p.source, first: p.firstApproverName, second: n,
                    remoteCode: code
                )
                finalizeApproval(p, secondName: n, viaRemoteCode: code)
                return (true, nil)
            }
            // If remote code fails, try as PIN below only if not hyphenated format
            if remoteCode != nil || code.contains("-") {
                return (false, check.error)
            }
        }

        // Path B: local PIN
        if !isSecondPINConfigured {
            return (false, "PIN non configurato e codice remoto non valido (Sicurezza → Two-person / Remote)")
        }
        switch SecondApprovalPINStore.verify(pin) {
        case .ok:
            finalizeApproval(p, secondName: n)
            return (true, nil)
        case .lockedOut(_, let message):
            return (false, message)
        case .invalid:
            auditLog.insert(SafetyAuditEntry(
                command: p.command,
                environment: environment,
                decision: "SECOND_DENIED_PIN",
                ruleName: p.rule.name,
                source: p.source,
                role: p.role.rawValue,
                path: p.path
            ), at: 0)
            recordSigned(
                .pinDenied, command: p.command, path: p.path, rule: p.rule.name,
                role: p.role.rawValue, source: p.source, first: p.firstApproverName, second: n
            )
            return (false, "PIN non valido")
        case .notConfigured:
            return (false, "PIN non configurato")
        }
    }

    /// Legacy single approve (maps to first).
    func approvePending() {
        _ = approveFirst()
    }

    func denyPending() {
        if let p = pendingConfirm {
            auditLog.insert(SafetyAuditEntry(
                command: p.command,
                environment: environment,
                decision: "DENIED_BY_USER",
                ruleName: p.rule.name,
                source: p.source,
                role: p.role.rawValue,
                path: p.path
            ), at: 0)
            trimAudit()
            recordSigned(
                .denied, command: p.command, path: p.path, rule: p.rule.name,
                role: p.role.rawValue, source: p.source, first: p.firstApproverName, second: nil,
                remoteCode: p.remoteCode
            )
            Task { [weak self] in
                await self?.remote?.notifyDenied(
                    command: p.command,
                    ruleName: p.rule.name,
                    remoteCode: p.remoteCode
                )
            }
        }
        pendingConfirm = nil
    }

    private func finalizeApproval(_ p: PendingConfirm, secondName: String? = nil, viaRemoteCode: String? = nil) {
        sessionApprovals.insert(approvalKey(command: p.command, path: p.path))
        pendingConfirm = nil
        let label = secondName != nil ? "DUAL_APPROVED" : "APPROVED_BY_USER"
        auditLog.insert(SafetyAuditEntry(
            command: p.command,
            environment: environment,
            decision: label + (secondName.map { " (\($0))" } ?? ""),
            ruleName: p.rule.name,
            source: p.source,
            role: p.role.rawValue,
            path: p.path
        ), at: 0)
        trimAudit()
        let event: ApprovalEventKind = secondName != nil ? .dualApproved : .approved
        recordSigned(
            event, command: p.command, path: p.path, rule: p.rule.name,
            role: p.role.rawValue, source: p.source, first: p.firstApproverName, second: secondName,
            remoteCode: viaRemoteCode ?? p.remoteCode
        )
        if secondName != nil {
            Task { [weak self] in
                await self?.remote?.notifyApproved(
                    command: p.command,
                    first: p.firstApproverName,
                    second: secondName,
                    ruleName: p.rule.name,
                    remoteCode: viaRemoteCode ?? p.remoteCode
                )
            }
        }
    }

    private func recordSigned(
        _ event: ApprovalEventKind,
        command: String,
        path: String?,
        rule: String?,
        role: String?,
        source: String,
        first: String?,
        second: String?,
        remoteCode: String? = nil
    ) {
        _ = signing?.append(
            event: event,
            command: command,
            path: path,
            environment: environment.rawValue,
            ruleName: rule,
            role: role,
            source: source,
            firstApprover: first,
            secondApprover: second,
            remoteCode: remoteCode
        )
    }

    func clearSessionApprovals() {
        sessionApprovals.removeAll()
    }

    private func approvalKey(command: String, path: String?) -> String {
        "\(path ?? "")||\(command)"
    }

    // MARK: - PIN

    func setSecondApproverPIN(_ pin: String) {
        guard SecondApprovalPINStore.setPIN(pin) else { return }
        objectWillChange.send()
    }

    func clearSecondApproverPIN() {
        SecondApprovalPINStore.clearPIN()
        objectWillChange.send()
    }

    var isSecondPINConfigured: Bool { SecondApprovalPINStore.isConfigured }

    // MARK: - Role policy CRUD

    func updateRolePolicy(_ policy: AgentRolePolicy) {
        if let i = rolePolicies.firstIndex(where: { $0.role == policy.role }) {
            rolePolicies[i] = policy
        } else {
            rolePolicies.append(policy)
        }
        persist()
    }

    // MARK: - Policy text for LLM

    func policyPromptBlock() -> String {
        let active = rules.filter { $0.enabled && $0.applies(to: environment, role: defaultAgentRole) }
        let lines = active.prefix(30).map { r in
            "- [\(r.severity.rawValue)] \(r.name): /\(r.pattern)/"
        }.joined(separator: "\n")
        let roles = rolePolicies.map {
            "\($0.role.rawValue): db=\($0.canDatabaseDestructive) fs=\($0.canFilesystemDestructive) deploy=\($0.canDeploy)"
        }.joined(separator: "; ")
        let allow = projectAllowlist.prefix(15).map(\.path).joined(separator: ", ")
        return """
        === QS AGENTS SAFETY POLICY (obbligatoria) ===
        Ambiente: \(environment.displayName) (\(environment.shortLabel))
        Guardrail: \(enabled ? "ON" : "OFF")
        Allowlist: \(allowlistMode.rawValue) → [\(allow.isEmpty ? "vuota" : allow)]
        Two-person: \(twoPersonEnabled ? "ON from \(twoPersonFrom.shortLabel)" : "OFF")
        Ruoli: \(roles)

        NON suggerire/eseguire azioni che violano regole.
        Su LIVE: vietati DROP/TRUNCATE DB, force-push main, rm -rf system, destroy infra.

        Regole pattern:
        \(lines)
        """
    }

    // MARK: - Rule CRUD

    func addRule(_ rule: GuardrailRule) {
        rules.insert(rule, at: 0)
        persist()
    }

    func updateRule(_ rule: GuardrailRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
            persist()
        }
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func resetToDefaults() {
        rules = Self.defaultRules
        rolePolicies = AgentRolePolicy.defaults
        persist()
    }

    /// Profilo bilanciato QS Agents: sicuro ma usabile in dev locale.
    /// - Guardrail ON, ambiente DEV
    /// - Allowlist in avviso + progetti importati
    /// - Two-person da LIVE
    /// - Ruolo default Builder (no wipe DB)
    /// - Matrice ruoli di fabbrica
    @discardableResult
    func applyRecommendedProfile(projectPaths: [String] = []) -> String {
        enabled = true
        environment = .development
        allowlistMode = .warn
        twoPersonEnabled = true
        twoPersonFrom = .production
        if secondApproverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            secondApproverName = "Tech Lead"
        }
        defaultAgentRole = .builder
        rules = Self.defaultRules
        rolePolicies = AgentRolePolicy.defaults

        // Seed allowlist with home projects + explicit paths
        let home = NSHomeDirectory()
        var seeds = projectPaths
        seeds.append(contentsOf: [
            home + "/qsagents",
            home + "/Projects",
            home + "/Developer",
            home + "/dev",
            home + "/code",
        ])
        for p in seeds {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                addAllowlistPath(p)
            }
        }

        recommendedSetupApplied = true
        UserDefaults.standard.set(true, forKey: recommendedKey)
        persist()

        let pinNote = isSecondPINConfigured
            ? "PIN 2ª firma già configurato."
            : "Imposta ancora il PIN in Two-person (e Slack opzionale)."
        return """
        Setup consigliato applicato:
        · Guardrail ON · Ambiente DEV
        · Allowlist: avvisa (\(projectAllowlist.count) path)
        · Two-person: ON da LIVE
        · Ruolo default: Builder
        · \(pinNote)
        """
    }

    /// Profilo più severo per lavoro su production (usa con attenzione).
    @discardableResult
    func applyProductionStrictProfile(projectPaths: [String] = []) -> String {
        _ = applyRecommendedProfile(projectPaths: projectPaths)
        environment = .production
        allowlistMode = .enforce
        // If allowlist empty after import, fall back to warn so user isn't locked out
        if projectAllowlist.isEmpty {
            allowlistMode = .warn
        }
        persist()
        return """
        Setup LIVE strict applicato:
        · Ambiente PRODUCTION
        · Allowlist: \(allowlistMode == .enforce ? "BLOCCA" : "avvisa (lista vuota — aggiungi progetti)")
        · Two-person obbligatorio su azioni sensibili
        · Ruolo default Builder
        """
    }

    func setEnvironment(_ env: AgentEnvironment) {
        environment = env
        persist()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        persist()
    }

    // MARK: - Defaults

    static let defaultRules: [GuardrailRule] = [
        GuardrailRule(
            name: "DROP DATABASE / SCHEMA",
            category: .database,
            pattern: #"\b(drop\s+(database|schema|table)|DROP\s+(DATABASE|SCHEMA|TABLE))\b"#,
            severity: .block,
            appliesFrom: .staging,
            description: "Impedisce DROP su staging e live",
            message: "Bloccato: DROP database/schema/table non consentito su questo ambiente."
        ),
        GuardrailRule(
            name: "TRUNCATE / DELETE massivo",
            category: .database,
            pattern: #"\b(truncate\s+table|delete\s+from\s+\w+\s*;?\s*$|delete\s+from\s+\w+\s+where\s+1\s*=\s*1)\b"#,
            severity: .block,
            appliesFrom: .production,
            description: "Blocca TRUNCATE / DELETE massivo su LIVE",
            message: "Bloccato su LIVE: cancellazione massiva database."
        ),
        GuardrailRule(
            name: "Migrate reset / db:wipe",
            category: .database,
            pattern: #"\b(migrate:fresh|migrate:reset|db:wipe|db:drop|prisma\s+migrate\s+reset|rails\s+db:drop|rails\s+db:reset)\b"#,
            severity: .block,
            appliesFrom: .staging,
            description: "Reset migrazioni / wipe DB",
            message: "Bloccato: reset/wipe database non permesso su staging/live."
        ),
        GuardrailRule(
            name: "DB destructive (dev confirm)",
            category: .database,
            pattern: #"\b(drop\s+table|truncate|migrate:fresh|db:drop)\b"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "In dev chiede conferma per DB distruttivi",
            message: "Conferma: comando potenzialmente distruttivo sul database."
        ),
        GuardrailRule(
            name: "DB on LIVE → two person",
            category: .database,
            pattern: #"\b(psql|mysql|mongosh|supabase|prisma\s+db)\b"#,
            severity: .dualConfirm,
            appliesFrom: .production,
            description: "Accesso DB tool su LIVE richiede 2 persone",
            message: "LIVE: accesso tool database richiede two-person rule."
        ),
        GuardrailRule(
            name: "rm -rf root / system",
            category: .filesystem,
            pattern: #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+(/|~|/Users|/home|/var|/etc|/usr|/System)"#,
            severity: .block,
            appliesFrom: .development,
            description: "Blocca sempre rm -rf su path di sistema",
            message: "Bloccato: rimozione ricorsiva su path di sistema."
        ),
        GuardrailRule(
            name: "rm -rf generico",
            category: .filesystem,
            pattern: #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "Conferma per ogni rm -rf",
            message: "Conferma: `rm -rf` può cancellare intere directory."
        ),
        GuardrailRule(
            name: "mkfs / disk wipe",
            category: .filesystem,
            pattern: #"\b(mkfs|diskutil\s+erase|dd\s+if=.*of=/dev/)\b"#,
            severity: .block,
            appliesFrom: .development,
            description: "Formattazione dischi",
            message: "Bloccato: formattazione/wipe disco."
        ),
        GuardrailRule(
            name: "Force push main/master",
            category: .git,
            pattern: #"git\s+push\s+.*(--force|--force-with-lease|-f).*\b(main|master|production|prod)\b|\bgit\s+push\s+.*\b(main|master)\b.*(--force|-f)"#,
            severity: .block,
            appliesFrom: .staging,
            description: "Niente force-push su branch protetti",
            message: "Bloccato: force-push su main/master/production."
        ),
        GuardrailRule(
            name: "git reset --hard",
            category: .git,
            pattern: #"git\s+reset\s+--hard"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "reset --hard scarta lavoro locale",
            message: "Conferma: `git reset --hard` elimina modifiche non committate."
        ),
        GuardrailRule(
            name: "git clean -fd",
            category: .git,
            pattern: #"git\s+clean\s+-[a-zA-Z]*f"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "git clean rimuove untracked",
            message: "Conferma: `git clean` elimina file non tracciati."
        ),
        GuardrailRule(
            name: "Esposizione secrets",
            category: .secrets,
            pattern: #"\b(cat|echo|printenv|env)\b.*\b(AWS_|SECRET|API_KEY|PRIVATE_KEY|PASSWORD|TOKEN|\.pem|\.env)\b"#,
            severity: .warn,
            appliesFrom: .development,
            description: "Avvisa dump secret",
            message: "Attenzione: possibile esposizione secrets."
        ),
        GuardrailRule(
            name: "Commit secret files",
            category: .secrets,
            pattern: #"git\s+add\s+.*(\.env|credentials\.json|id_rsa|\.pem|secrets?)"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "Evitare commit sensibili",
            message: "Conferma: file potenzialmente sensibili in git add."
        ),
        GuardrailRule(
            name: "Shutdown / reboot",
            category: .process,
            pattern: #"\b(sudo\s+)?(shutdown|reboot|halt|poweroff)\b"#,
            severity: .block,
            appliesFrom: .development,
            description: "Niente spegnimento",
            message: "Bloccato: shutdown/reboot."
        ),
        GuardrailRule(
            name: "kill -9 massivo",
            category: .process,
            pattern: #"kill\s+-9\s+-1|killall\s+-9|pkill\s+-9\s+\."#,
            severity: .block,
            appliesFrom: .development,
            description: "Kill di tutti i processi",
            message: "Bloccato: terminazione massiva processi."
        ),
        GuardrailRule(
            name: "Deploy production destroy",
            category: .network,
            pattern: #"\b(kubectl\s+delete|helm\s+uninstall|terraform\s+destroy|pulumi\s+destroy|fly\s+apps?\s+destroy|vercel\s+remove|aws\s+.*delete-)\b"#,
            severity: .block,
            appliesFrom: .production,
            description: "Destroy infra su LIVE",
            message: "Bloccato su LIVE: destroy/delete infrastruttura."
        ),
        GuardrailRule(
            name: "Terraform destroy (confirm)",
            category: .cloud,
            pattern: #"\b(terraform\s+destroy|pulumi\s+destroy|cdk\s+destroy)\b"#,
            severity: .confirm,
            appliesFrom: .development,
            description: "Destroy infra richiede conferma",
            message: "Conferma: destroy infrastruttura cloud."
        ),
        GuardrailRule(
            name: "kubectl production context",
            category: .cloud,
            pattern: #"kubectl\s+.*\b(--context\s+\S*prod|namespace\s+production|namespace\s+prod)\b"#,
            severity: .dualConfirm,
            appliesFrom: .staging,
            description: "k8s prod → two person da staging+",
            message: "Operazione Kubernetes su context/namespace production."
        ),
    ]

    // MARK: - Private

    private func merge(_ a: SafetyDecision, _ b: SafetyDecision) -> SafetyDecision {
        b.rank >= a.rank ? b : a
    }

    private func log(command: String, decision: SafetyDecision, context: SafetyContext) {
        let label: String
        switch decision {
        case .allow: return
        case .allowWithWarning: label = "WARN"
        case .requireConfirm: label = "CONFIRM"
        case .requireDualConfirm: label = "DUAL"
        case .block: label = "BLOCK"
        }
        auditLog.insert(SafetyAuditEntry(
            command: command,
            environment: environment,
            decision: label,
            ruleName: decision.rule?.name,
            source: context.source,
            role: context.role.rawValue,
            path: context.path
        ), at: 0)
        trimAudit()
    }

    private func trimAudit() {
        if auditLog.count > 120 { auditLog = Array(auditLog.prefix(120)) }
    }

    private func load() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: envKey), let env = AgentEnvironment(rawValue: raw) {
            environment = env
        }
        if d.object(forKey: enabledKey) != nil { enabled = d.bool(forKey: enabledKey) }
        if let data = d.data(forKey: rulesKey),
           let decoded = try? JSONDecoder().decode([GuardrailRule].self, from: data),
           !decoded.isEmpty {
            rules = decoded
        }
        if let m = d.string(forKey: allowModeKey), let mode = AllowlistMode(rawValue: m) {
            allowlistMode = mode
        }
        if let data = d.data(forKey: allowListKey),
           let list = try? JSONDecoder().decode([ProjectAllowlistEntry].self, from: data) {
            projectAllowlist = list
        }
        if d.object(forKey: twoPersonKey) != nil { twoPersonEnabled = d.bool(forKey: twoPersonKey) }
        if let raw = d.string(forKey: twoPersonFromKey), let e = AgentEnvironment(rawValue: raw) {
            twoPersonFrom = e
        }
        secondApproverName = d.string(forKey: secondNameKey) ?? "Second Approver"
        if let data = d.data(forKey: rolesKey),
           let decoded = try? JSONDecoder().decode([AgentRolePolicy].self, from: data),
           !decoded.isEmpty {
            rolePolicies = decoded
        }
        if let r = d.string(forKey: defaultRoleKey), let role = AgentRole(rawValue: r) {
            defaultAgentRole = role
        }
        recommendedSetupApplied = d.bool(forKey: recommendedKey)

        // First install: property defaults already match recommended baseline.
        // Mark applied only after bootstrap imports projects (see applyRecommendedIfNeeded).
    }

    /// Called once from app bootstrap when user has never applied recommended setup.
    func applyRecommendedIfNeeded(projectPaths: [String]) {
        guard !recommendedSetupApplied else { return }
        _ = applyRecommendedProfile(projectPaths: projectPaths)
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(environment.rawValue, forKey: envKey)
        d.set(enabled, forKey: enabledKey)
        if let data = try? JSONEncoder().encode(rules) { d.set(data, forKey: rulesKey) }
        d.set(allowlistMode.rawValue, forKey: allowModeKey)
        if let data = try? JSONEncoder().encode(projectAllowlist) { d.set(data, forKey: allowListKey) }
        d.set(twoPersonEnabled, forKey: twoPersonKey)
        d.set(twoPersonFrom.rawValue, forKey: twoPersonFromKey)
        d.set(secondApproverName, forKey: secondNameKey)
        if let data = try? JSONEncoder().encode(rolePolicies) { d.set(data, forKey: rolesKey) }
        d.set(defaultAgentRole.rawValue, forKey: defaultRoleKey)
        d.set(recommendedSetupApplied, forKey: recommendedKey)
    }
}
