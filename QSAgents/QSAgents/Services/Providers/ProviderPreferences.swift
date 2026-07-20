import Foundation
import Combine

/// Default provider + model per role + usage/cost (token meter).
/// Swarm / AgentRuntime / Orchestrator all resolve through here.
@MainActor
final class ProviderPreferences: ObservableObject {
    static let shared = ProviderPreferences()

    @Published var defaultProviderRaw: String = LLMProviderKind.spaceXAI.rawValue
    @Published var modelByRole: [String: String] = [:]
    /// Optional override: which provider each role uses (defaults to defaultProvider).
    @Published var providerByRole: [String: String] = [:]
    @Published var lastUsageTokens: Int = 0
    @Published var estimatedCostUSD: Double = 0
    @Published var sessionTokens: Int = 0
    @Published var sessionCostUSD: Double = 0
    @Published var tokensByProvider: [String: Int] = [:]
    /// Estimated tokens avoided by code-brain / knowledge vs full-file reads.
    @Published var knowledgeTokensSaved: Int = 0
    @Published var knowledgeSavedCostUSD: Double = 0

    private let defaultsKey = "qs.provider.prefs.v3"

    init() {
        load()
    }

    var defaultProvider: LLMProviderKind? {
        // migrate legacy names
        if let k = LLMProviderKind(rawValue: defaultProviderRaw) { return k }
        switch defaultProviderRaw {
        case "Grok", "xAI": return .spaceXAI
        case "Codex": return .openAI
        case "Claude": return .anthropic
        default: return nil
        }
    }

    var activeModelLabel: String {
        let (p, m) = resolve(for: .coordinator)
        return "\(p?.displayName ?? "local") · \(m)"
    }

    /// Provider for a role: role override → defaultProvider (if has key) → first key in Keychain.
    func provider(for role: AgentRole) -> LLMProviderKind? {
        if let raw = providerByRole[role.rawValue],
           let p = LLMProviderKind(rawValue: raw),
           LLMClient.shared.hasKey(p) {
            return p
        }
        if let d = defaultProvider, LLMClient.shared.hasKey(d) {
            return d
        }
        // Fall back: any configured key (stable order of enum)
        return LLMProviderKind.allCases.first { LLMClient.shared.hasKey($0) }
    }

    func model(for role: AgentRole) -> String {
        let p = provider(for: role)
        if let m = modelByRole[role.rawValue], !m.isEmpty {
            let cleaned = Self.stripProviderPrefix(m)
            // Keep model if still valid for provider; otherwise default
            if let p, p.models.contains(cleaned) || cleaned.contains("/") { return cleaned }
            if p == nil { return cleaned }
        }
        return p?.defaultModel ?? "local"
    }

    /// `OpenRouter/anthropic/…` → `anthropic/…` (UI labels must never hit the API).
    static func stripProviderPrefix(_ model: String) -> String {
        var m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in LLMProviderKind.allCases {
            for name in [p.displayName, p.rawValue] {
                if m.hasPrefix(name + "/") {
                    m = String(m.dropFirst(name.count + 1))
                } else if m.hasPrefix(name + " · ") {
                    m = String(m.dropFirst(name.count + 3))
                }
            }
        }
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve pair used by AgentRuntime / Swarm spawn.
    func resolve(for role: AgentRole) -> (provider: LLMProviderKind?, model: String) {
        let p = provider(for: role)
        let m = model(for: role)
        return (p, m)
    }

    /// First provider that actually has a Keychain/OAuth credential (orchestrator + swarm share this).
    func anyKeyedProvider() -> LLMProviderKind? {
        if let p = provider(for: .builder), LLMClient.shared.hasKey(p) { return p }
        if let p = provider(for: .coordinator), LLMClient.shared.hasKey(p) { return p }
        if let d = defaultProvider, LLMClient.shared.hasKey(d) { return d }
        return LLMProviderKind.allCases.first { LLMClient.shared.hasKey($0) }
    }

    /// Keep Swarm on the same live provider/model as the orchestrator chat (kills «no key» bootstrap).
    func syncSwarmFromLive(provider: LLMProviderKind, model: String) {
        guard LLMClient.shared.hasKey(provider) else { return }
        let m = Self.stripProviderPrefix(model)
        let useModel = m.isEmpty || m == "local" ? provider.defaultModel : m
        applyToAllSwarmRoles(provider: provider, model: useModel)
        AppLogger.info("Swarm routing sync ← \(provider.displayName)/\(useModel)")
    }

    /// Label shown on agent cards: `OpenAI/gpt-4.1`
    func label(for role: AgentRole) -> String {
        let (p, m) = resolve(for: role)
        guard let p else { return "local" }
        return "\(p.displayName)/\(m)"
    }

    func models(for provider: LLMProviderKind) -> [String] {
        ModelCatalog.shared.models(for: provider)
    }

    func setModel(_ model: String, for role: AgentRole) {
        modelByRole[role.rawValue] = model
        persist()
        objectWillChange.send()
    }

    func setProvider(_ p: LLMProviderKind, for role: AgentRole) {
        providerByRole[role.rawValue] = p.rawValue
        // Align model to that provider if current is invalid
        let current = modelByRole[role.rawValue]
        if current == nil || !p.models.contains(current ?? "") {
            modelByRole[role.rawValue] = p.defaultModel
        }
        persist()
        objectWillChange.send()
    }

    func setDefaultProvider(_ p: LLMProviderKind) {
        defaultProviderRaw = p.rawValue
        // Coordinator follows default unless role-override is set
        if providerByRole[AgentRole.coordinator.rawValue] == nil {
            let allowed = p.models
            let current = modelByRole[AgentRole.coordinator.rawValue]
            if current == nil || !(allowed.contains(current ?? "")) {
                modelByRole[AgentRole.coordinator.rawValue] = p.defaultModel
            }
        }
        // Also seed other swarm roles if empty so they inherit new default model
        for role in [AgentRole.scout, .builder, .reviewer] {
            if modelByRole[role.rawValue] == nil {
                modelByRole[role.rawValue] = p.defaultModel
            }
        }
        persist()
        objectWillChange.send()
    }

    /// Apply the same provider+model to all swarm roles (quick setup).
    func applyToAllSwarmRoles(provider: LLMProviderKind, model: String) {
        for role in [AgentRole.coordinator, .scout, .builder, .reviewer] {
            providerByRole[role.rawValue] = provider.rawValue
            modelByRole[role.rawValue] = model
        }
        defaultProviderRaw = provider.rawValue
        persist()
        objectWillChange.send()
    }

    func recordUsage(tokens: Int, provider: LLMProviderKind) {
        guard tokens > 0 else { return }
        lastUsageTokens += tokens
        sessionTokens += tokens
        tokensByProvider[provider.rawValue, default: 0] += tokens

        let per1k: Double
        switch provider {
        case .spaceXAI: per1k = 0.002
        case .openAI: per1k = 0.002
        case .anthropic: per1k = 0.003
        case .gemini: per1k = 0.001
        case .openRouter: per1k = 0.002
        }
        let delta = Double(tokens) / 1000.0 * per1k
        estimatedCostUSD += delta
        sessionCostUSD += delta

        UserDefaults.standard.set(lastUsageTokens, forKey: "qs.usage.tokens")
        UserDefaults.standard.set(estimatedCostUSD, forKey: "qs.usage.cost")
        if let data = try? JSONEncoder().encode(tokensByProvider) {
            UserDefaults.standard.set(data, forKey: "qs.usage.byProvider")
        }
        objectWillChange.send()
    }

    /// Home «Reset sessione» — clears session meters and the Totale / Stima shown beside them.
    func resetSessionUsage() {
        sessionTokens = 0
        sessionCostUSD = 0
        lastUsageTokens = 0
        estimatedCostUSD = 0
        tokensByProvider = [:]
        UserDefaults.standard.set(0, forKey: "qs.usage.tokens")
        UserDefaults.standard.set(0.0, forKey: "qs.usage.cost")
        UserDefaults.standard.removeObject(forKey: "qs.usage.byProvider")
        objectWillChange.send()
    }

    func resetAllUsage() {
        resetSessionUsage()
        knowledgeTokensSaved = 0
        knowledgeSavedCostUSD = 0
        UserDefaults.standard.set(0, forKey: "qs.usage.knowledgeSaved")
        UserDefaults.standard.set(0.0, forKey: "qs.usage.knowledgeSavedCost")
        objectWillChange.send()
    }

    /// Credit tokens avoided when agents use capsule/locate instead of dumping whole files.
    func recordKnowledgeSavings(savedTokens: Int, provider: LLMProviderKind? = nil) {
        guard savedTokens > 0 else { return }
        knowledgeTokensSaved += savedTokens
        let p = provider ?? defaultProvider ?? .openRouter
        let per1k: Double
        switch p {
        case .spaceXAI: per1k = 0.002
        case .openAI: per1k = 0.002
        case .anthropic: per1k = 0.003
        case .gemini: per1k = 0.001
        case .openRouter: per1k = 0.002
        }
        knowledgeSavedCostUSD += Double(savedTokens) / 1000.0 * per1k
        UserDefaults.standard.set(knowledgeTokensSaved, forKey: "qs.usage.knowledgeSaved")
        UserDefaults.standard.set(knowledgeSavedCostUSD, forKey: "qs.usage.knowledgeSavedCost")
        objectWillChange.send()
    }

    private struct Payload: Codable {
        var defaultProviderRaw: String
        var modelByRole: [String: String]
        var providerByRole: [String: String]?
    }

    private func load() {
        lastUsageTokens = UserDefaults.standard.integer(forKey: "qs.usage.tokens")
        estimatedCostUSD = UserDefaults.standard.double(forKey: "qs.usage.cost")
        knowledgeTokensSaved = UserDefaults.standard.integer(forKey: "qs.usage.knowledgeSaved")
        knowledgeSavedCostUSD = UserDefaults.standard.double(forKey: "qs.usage.knowledgeSavedCost")
        if let data = UserDefaults.standard.data(forKey: "qs.usage.byProvider"),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            tokensByProvider = map
        }
        // v3 → v2 → v1
        let data = UserDefaults.standard.data(forKey: defaultsKey)
            ?? UserDefaults.standard.data(forKey: "qs.provider.prefs.v2")
            ?? UserDefaults.standard.data(forKey: "qs.provider.prefs")
        guard let data,
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        defaultProviderRaw = p.defaultProviderRaw
        modelByRole = p.modelByRole
        providerByRole = p.providerByRole ?? [:]
    }

    private func persist() {
        let p = Payload(
            defaultProviderRaw: defaultProviderRaw,
            modelByRole: modelByRole,
            providerByRole: providerByRole
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

