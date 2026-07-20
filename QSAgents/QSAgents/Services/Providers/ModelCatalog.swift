import Foundation

/// Catalog of selectable models **per provider**.
///
/// Default lists are curated and small (safe for SwiftUI pickers).
/// OpenRouter never auto-loads the full remote catalog (thousands of IDs → crash).
/// Optional remote fetch is manual, hard-capped, and only merges when the user asks.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    /// Soft remote extras for OpenRouter only (capped; never the full API dump).
    @Published private(set) var openRouterRemote: [String] = []
    @Published private(set) var isLoadingOpenRouter = false
    @Published private(set) var lastFetchError: String?
    /// When false, pickers show only curated OpenRouter models (default, safe).
    @Published private(set) var includeRemoteOpenRouter = false

    private let openRouterCacheKey = "qs.models.openrouter.v2"
    private let legacyCacheKey = "qs.models.openrouter.v1"
    private var lastFetchAt: Date?

    /// Hard cap: never put more remote IDs into the UI than this.
    private static let remoteCap = 80

    init() {
        // Drop legacy unbounded cache that used to crash the app.
        UserDefaults.standard.removeObject(forKey: legacyCacheKey)
        if let cached = UserDefaults.standard.stringArray(forKey: openRouterCacheKey) {
            openRouterRemote = Array(cached.prefix(Self.remoteCap))
        }
    }

    /// Models for a single provider only (never cross-provider dumps).
    func models(for provider: LLMProviderKind, including selected: String? = nil) -> [String] {
        var list = curated(for: provider)
        if provider == .openRouter, includeRemoteOpenRouter, !openRouterRemote.isEmpty {
            let set = Set(list)
            for id in openRouterRemote where !set.contains(id) {
                list.append(id)
                if list.count >= curated(for: .openRouter).count + Self.remoteCap { break }
            }
        }
        if let selected, !selected.isEmpty, !list.contains(selected) {
            list.insert(selected, at: 0)
        }
        return list
    }

    func filter(_ query: String, provider: LLMProviderKind, selected: String?) -> [String] {
        let all = models(for: provider, including: selected)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    /// Manual pull of a **capped** OpenRouter subset. Does not run automatically.
    func refreshOpenRouterIfNeeded(force: Bool = false) {
        if isLoadingOpenRouter { return }
        if !force, let last = lastFetchAt, Date().timeIntervalSince(last) < 300 { return }
        guard LLMClient.shared.hasKey(.openRouter) else {
            lastFetchError = L("Nessuna key OpenRouter")
            return
        }
        isLoadingOpenRouter = true
        lastFetchError = nil
        Task {
            do {
                let ids = try await Self.fetchOpenRouterModels(cap: Self.remoteCap)
                await MainActor.run {
                    self.openRouterRemote = ids
                    self.includeRemoteOpenRouter = true
                    self.lastFetchAt = Date()
                    self.isLoadingOpenRouter = false
                    UserDefaults.standard.set(ids, forKey: self.openRouterCacheKey)
                    AppLogger.info("OpenRouter models fetched (capped): \(ids.count)")
                }
            } catch {
                await MainActor.run {
                    self.isLoadingOpenRouter = false
                    self.lastFetchError = error.localizedDescription
                    AppLogger.error("OpenRouter models: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stay on curated list only (clears remote merge for UI).
    func useCuratedOpenRouterOnly() {
        includeRemoteOpenRouter = false
        lastFetchError = nil
    }

    private static func fetchOpenRouterModels(cap: Int) async throws -> [String] {
        guard let key = LLMClient.shared.resolveKey(.openRouter) else {
            throw LLMClientError.noAPIKey
        }
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, body.prefix(200).description)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw LLMClientError.decode
        }

        // Prefer “popular / frontier” families; never return thousands of rows.
        let preferredPrefixes = [
            "openai/", "anthropic/", "google/", "x-ai/", "meta-llama/",
            "deepseek/", "qwen/", "mistralai/", "perplexity/", "cohere/",
            "moonshotai/",
        ]
        let allIDs = arr.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        var picked: [String] = []
        var seen = Set<String>()
        for prefix in preferredPrefixes {
            for id in allIDs where id.hasPrefix(prefix) && !seen.contains(id) {
                seen.insert(id)
                picked.append(id)
                if picked.count >= cap { return picked.sorted() }
            }
        }
        for id in allIDs.sorted() where !seen.contains(id) {
            seen.insert(id)
            picked.append(id)
            if picked.count >= cap { break }
        }
        return picked.sorted()
    }

    // MARK: - Curated catalogs (one list per provider — not OpenRouter dump)

    private func curated(for provider: LLMProviderKind) -> [String] {
        switch provider {
        case .spaceXAI:
            return [
                "grok-4-5", "grok-4", "grok-3", "grok-3-mini", "grok-3-fast",
                "grok-2-latest", "grok-2-1212", "grok-2-vision-1212",
                "grok-beta", "grok-vision-beta",
            ]
        case .openAI:
            return [
                "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
                "gpt-4o", "gpt-4o-mini", "gpt-4o-2024-11-20",
                "o4-mini", "o3", "o3-mini", "o3-pro",
                "o1", "o1-mini", "o1-pro",
                "gpt-4-turbo", "gpt-4", "gpt-3.5-turbo",
                "chatgpt-4o-latest",
            ]
        case .anthropic:
            return [
                "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5",
                "claude-fable-5",
                "claude-haiku-4-5", "claude-haiku-4-5-20251001",
                "claude-3-5-sonnet-latest", "claude-3-5-haiku-latest",
                "claude-3-opus-latest",
            ]
        case .gemini:
            return [
                "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
                "gemini-2.0-flash", "gemini-2.0-flash-lite",
                "gemini-1.5-pro", "gemini-1.5-flash",
            ]
        case .openRouter:
            return [
                // OpenAI
                "openai/gpt-4.1", "openai/gpt-4.1-mini", "openai/gpt-4o", "openai/gpt-4o-mini",
                "openai/o4-mini", "openai/o3", "openai/o3-mini", "openai/o1",
                // Anthropic
                "anthropic/claude-opus-4.8", "anthropic/claude-opus-4.7",
                "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6",
                "anthropic/claude-haiku-4.5",
                "anthropic/claude-3.5-sonnet", "anthropic/claude-3-opus",
                // Google
                "google/gemini-2.5-pro", "google/gemini-2.5-flash",
                "google/gemini-2.0-flash-001", "google/gemini-pro-1.5",
                // xAI
                "x-ai/grok-4.5", "x-ai/grok-4", "x-ai/grok-3", "x-ai/grok-3-mini",
                "x-ai/grok-2-1212", "x-ai/grok-beta",
                // Meta / DeepSeek / Qwen / Mistral / others
                "meta-llama/llama-4-maverick", "meta-llama/llama-4-scout",
                "meta-llama/llama-3.3-70b-instruct", "meta-llama/llama-3.1-405b-instruct",
                "deepseek/deepseek-r1", "deepseek/deepseek-chat-v3-0324", "deepseek/deepseek-r1-distill-llama-70b",
                "qwen/qwen3-235b-a22b", "qwen/qwen-2.5-72b-instruct", "qwen/qwq-32b",
                "mistralai/mistral-large", "mistralai/mistral-small-3.1-24b-instruct",
                "mistralai/mixtral-8x22b-instruct",
                "google/gemma-3-27b-it",
                "cohere/command-r-plus",
                "perplexity/sonar-pro", "perplexity/sonar-reasoning",
                // Moonshot / Kimi (OpenRouter)
                "moonshotai/kimi-k3",
                "moonshotai/kimi-k2.5", "moonshotai/kimi-k2-thinking", "moonshotai/kimi-k2",
                "~moonshotai/kimi-latest",
                "nvidia/llama-3.1-nemotron-70b-instruct",
                "microsoft/phi-4",
                "openrouter/auto",
            ]
        }
    }
}
