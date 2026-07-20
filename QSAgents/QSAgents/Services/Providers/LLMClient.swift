import Foundation

// MARK: - Models

/// AI providers available in QS Agents.
/// Keychain account names match Integration card names where possible.
enum LLMProviderKind: String, CaseIterable, Identifiable {
    case spaceXAI = "SpaceX AI"   // Grok via xAI (user-facing name)
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case openRouter = "OpenRouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spaceXAI: return "SpaceX AI (Grok)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Keychain account (also used for Integrations card `name` when possible).
    var keychainAccount: String {
        switch self {
        case .spaceXAI: return "SpaceX AI" // also accept legacy "Grok"
        case .openAI: return "OpenAI"      // also accept legacy "Codex"
        case .anthropic: return "Anthropic" // also accept "Claude"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Alternate Keychain names for migration.
    var legacyKeychainAccounts: [String] {
        switch self {
        case .spaceXAI: return ["Grok", "xAI"]
        case .openAI: return ["Codex", "OpenAI"]
        case .anthropic: return ["Claude", "Anthropic"]
        case .gemini: return ["Gemini", "Google"]
        case .openRouter: return ["OpenRouter"]
        }
    }

    var apiStyle: APIStyle {
        switch self {
        case .anthropic: return .anthropicMessages
        case .gemini: return .geminiGenerate
        case .spaceXAI, .openAI, .openRouter: return .openAIChat
        }
    }

    enum APIStyle {
        case openAIChat
        case anthropicMessages
        case geminiGenerate
    }

    var baseURL: URL {
        switch self {
        case .spaceXAI: return URL(string: "https://api.x.ai/v1")!
        case .openAI: return URL(string: "https://api.openai.com/v1")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")!
        }
    }

    var chatPath: String {
        switch self {
        case .anthropic: return "/messages"
        case .gemini: return "/models" // specialized
        default: return "/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .spaceXAI: return "grok-4-5"
        case .openAI: return "gpt-4.1"
        case .anthropic: return "claude-sonnet-5"
        case .gemini: return "gemini-2.5-pro"
        case .openRouter: return "openai/gpt-4.1"
        }
    }

    /// Models shown in live switcher (latest-first).
    var models: [String] {
        switch self {
        case .spaceXAI:
            return [
                "grok-4-5",
                "grok-4",
                "grok-3",
                "grok-3-mini",
                "grok-2-latest",
            ]
        case .openAI:
            return [
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "gpt-4o",
                "gpt-4o-mini",
                "o4-mini",
                "o3",
                "o3-mini",
            ]
        case .anthropic:
            // Latest Claude API IDs (2026)
            return [
                "claude-opus-4-8",
                "claude-sonnet-5",
                "claude-fable-5",
                "claude-haiku-4-5",
                "claude-opus-4-7",
                "claude-sonnet-4-6",
            ]
        case .gemini:
            return [
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.0-flash",
                "gemini-1.5-pro",
            ]
        case .openRouter:
            // Static curated list (SearchableModelPicker merges live OpenRouter catalog)
            return [
                "openai/gpt-4.1", "openai/gpt-4.1-mini", "openai/gpt-4o", "openai/gpt-4o-mini",
                "openai/o4-mini", "openai/o3", "openai/o3-mini",
                "anthropic/claude-opus-4.8", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6",
                "anthropic/claude-haiku-4.5",
                "google/gemini-2.5-pro", "google/gemini-2.5-flash",
                "x-ai/grok-4.5", "x-ai/grok-3", "x-ai/grok-3-mini",
                "meta-llama/llama-4-maverick", "meta-llama/llama-3.3-70b-instruct",
                "deepseek/deepseek-r1", "deepseek/deepseek-chat-v3-0324",
                "qwen/qwen3-235b-a22b", "mistralai/mistral-large",
                "perplexity/sonar-pro", "openrouter/auto",
            ]
        }
    }

    var integrationIcon: String {
        switch self {
        case .spaceXAI: return "bolt.fill"
        case .openAI: return "brain"
        case .anthropic: return "brain.head.profile"
        case .gemini: return "diamond.fill"
        case .openRouter: return "arrow.triangle.branch"
        }
    }
}

struct LLMMessage: Equatable {
    enum Role: String { case system, user, assistant, tool }
    var role: Role
    var content: String
    var name: String?
}

struct LLMUsage: Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    static let zero = LLMUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

    static func + (a: LLMUsage, b: LLMUsage) -> LLMUsage {
        LLMUsage(
            promptTokens: a.promptTokens + b.promptTokens,
            completionTokens: a.completionTokens + b.completionTokens,
            totalTokens: a.totalTokens + b.totalTokens
        )
    }
}

struct LLMCompletion: Equatable {
    var text: String
    var provider: LLMProviderKind
    var model: String
    var usage: LLMUsage
}

enum LLMClientError: LocalizedError {
    case noAPIKey
    case badURL
    case http(Int, String)
    case decode
    case empty

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Nessuna API key configurata (Integrazioni)"
        case .badURL: return "URL provider non valido"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(200))"
        case .decode: return "Risposta LLM non decodificabile"
        case .empty: return "Risposta LLM vuota"
        }
    }
}

// MARK: - Client

@MainActor
final class LLMClient {
    static let shared = LLMClient()

    /// Prefer user selection from Home / ProviderPreferences, then first key in Keychain.
    func preferredProvider() -> LLMProviderKind? {
        if let d = ProviderPreferences.shared.defaultProvider, hasKey(d) {
            return d
        }
        // Role-coordinator override
        if let p = ProviderPreferences.shared.provider(for: .coordinator) {
            return p
        }
        for p in LLMProviderKind.allCases {
            if hasKey(p) { return p }
        }
        return nil
    }

    func hasKey(_ provider: LLMProviderKind) -> Bool {
        if resolveKey(provider) != nil { return true }
        // OpenAI: ChatGPT/Codex OAuth session counts as connected
        if provider == .openAI, ProviderBrowserAuthService.shared.openAIHasOAuth {
            return true
        }
        return false
    }

    /// Resolve key from primary or legacy Keychain accounts.
    /// OpenAI may also return a ChatGPT OAuth access_token (JWT) when no sk- key is set.
    func resolveKey(_ provider: LLMProviderKind) -> String? {
        var accounts = [provider.keychainAccount] + provider.legacyKeychainAccounts
        // unique preserve order
        var seen = Set<String>()
        accounts = accounts.filter { seen.insert($0).inserted }
        for a in accounts {
            if let k = KeychainStore.get(a)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
                // Skip OAuth JSON blob if someone stored it under OpenAI by mistake
                if k.hasPrefix("{") { continue }
                return k
            }
        }
        if provider == .openAI, let tok = ProviderBrowserAuthService.shared.openAIAccessToken() {
            return tok
        }
        return nil
    }

    /// True when OpenAI auth is ChatGPT OAuth (not Platform sk-).
    func isOpenAIOAuthCredential(_ key: String) -> Bool {
        key.hasPrefix("eyJ") || key.contains(".") && !key.hasPrefix("sk-")
    }

    func configuredSummary() -> String {
        guard let p = preferredProvider() else {
            return "Solo regole locali (nessuna API key). Configura SpaceX AI / OpenAI / Anthropic in Integrazioni."
        }
        let model = ProviderPreferences.shared.model(for: .coordinator)
        if p == .openAI, ProviderBrowserAuthService.shared.openAIHasOAuth, !openAIHasAPIKeyOnly() {
            let who = ProviderBrowserAuthService.shared.openAIEmail ?? "ChatGPT"
            return "\(p.displayName) · ChatGPT · \(who) · `\(model)`"
        }
        return "\(p.displayName) · `\(model)`"
    }

    private func openAIHasAPIKeyOnly() -> Bool {
        if let k = KeychainStore.get(LLMProviderKind.openAI.keychainAccount),
           k.hasPrefix("sk-") { return true }
        return false
    }

    private static let retryableHTTP = Set([429, 500, 502, 503, 504])

    /// Retry with exponential backoff + jitter on 429/5xx (max 3 attempts). Honors `Retry-After`.
    private func dataWithRetry(for request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LLMClientError.decode }
                if (200...299).contains(http.statusCode) {
                    return (data, http)
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                if Self.retryableHTTP.contains(http.statusCode), attempt < 2 {
                    let headerDelay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let delay = headerDelay ?? (pow(2.0, Double(attempt)) + Double.random(in: 0...0.35))
                    AppLogger.warn(
                        "LLM \(label) HTTP \(http.statusCode) — ritento \(attempt + 1)/3 tra \(String(format: "%.1f", delay))s"
                    )
                    try await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000))
                    continue
                }
                throw LLMClientError.http(http.statusCode, String(body.prefix(300)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as LLMClientError {
                throw e
            } catch {
                lastError = error
                if attempt < 2 {
                    let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...0.3)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? LLMClientError.empty
    }

    /// Complete using ProviderPreferences for a swarm/agent role.
    func complete(
        messages: [LLMMessage],
        role: AgentRole,
        temperature: Double = 0.3,
        maxTokens: Int = 2048
    ) async throws -> LLMCompletion {
        let (p, m) = ProviderPreferences.shared.resolve(for: role)
        return try await complete(
            messages: messages,
            provider: p,
            model: m,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    func complete(
        messages: [LLMMessage],
        provider: LLMProviderKind? = nil,
        model: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048
    ) async throws -> LLMCompletion {
        let p = provider ?? preferredProvider()
        guard let p else { throw LLMClientError.noAPIKey }
        guard let key = resolveKey(p) else { throw LLMClientError.noAPIKey }
        // Prefer explicit model → prefs coordinator model if same provider → provider default
        let m: String
        if let model, !model.isEmpty {
            m = model
        } else {
            let pref = ProviderPreferences.shared.model(for: .coordinator)
            m = (pref != "local" && !pref.isEmpty) ? pref : p.defaultModel
        }

        switch p.apiStyle {
        case .anthropicMessages:
            return try await completeAnthropic(messages: messages, key: key, model: m, temperature: temperature, maxTokens: maxTokens, provider: p)
        case .geminiGenerate:
            return try await completeGemini(messages: messages, key: key, model: m, temperature: temperature, maxTokens: maxTokens)
        case .openAIChat:
            if p == .openAI, isOpenAIOAuthCredential(key) {
                // ChatGPT/Codex subscription token → ChatGPT backend (not Platform API)
                return try await completeOpenAIChatGPT(
                    messages: messages,
                    accessToken: key,
                    model: m,
                    maxTokens: maxTokens
                )
            }
            return try await completeOpenAICompat(provider: p, messages: messages, key: key, model: m, temperature: temperature, maxTokens: maxTokens)
        }
    }

    func complete(
        system: String,
        user: String,
        provider: LLMProviderKind? = nil,
        model: String? = nil
    ) async throws -> LLMCompletion {
        try await complete(
            messages: [
                LLMMessage(role: .system, content: system),
                LLMMessage(role: .user, content: user),
            ],
            provider: provider,
            model: model
        )
    }

    // MARK: - C3 Streaming

    /// Token-by-token completion. OpenAI-compatible providers use SSE `stream:true`;
    /// Anthropic/Gemini fall back to one-shot then a single onDelta with full text.
    func completeStreaming(
        messages: [LLMMessage],
        provider: LLMProviderKind? = nil,
        model: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> LLMCompletion {
        let p = provider ?? preferredProvider()
        guard let p else { throw LLMClientError.noAPIKey }
        guard let key = resolveKey(p) else { throw LLMClientError.noAPIKey }
        let m: String
        if let model, !model.isEmpty {
            m = model
        } else {
            let pref = ProviderPreferences.shared.model(for: .coordinator)
            m = (pref != "local" && !pref.isEmpty) ? pref : p.defaultModel
        }

        switch p.apiStyle {
        case .openAIChat:
            return try await streamOpenAICompat(
                provider: p,
                messages: messages,
                key: key,
                model: m,
                temperature: temperature,
                maxTokens: maxTokens,
                onDelta: onDelta
            )
        case .anthropicMessages, .geminiGenerate:
            // Fallback: non-stream complete, then surface full text once
            let c = try await complete(
                messages: messages,
                provider: p,
                model: m,
                temperature: temperature,
                maxTokens: maxTokens
            )
            await MainActor.run { onDelta(c.text) }
            return c
        }
    }

    func completeStreaming(
        system: String,
        user: String,
        provider: LLMProviderKind? = nil,
        model: String? = nil,
        maxTokens: Int = 2048,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> LLMCompletion {
        try await completeStreaming(
            messages: [
                LLMMessage(role: .system, content: system),
                LLMMessage(role: .user, content: user),
            ],
            provider: provider,
            model: model,
            maxTokens: maxTokens,
            onDelta: onDelta
        )
    }

    // MARK: OpenAI ChatGPT / Codex OAuth (subscription)

    /// Best-effort chat via ChatGPT backend when user linked Codex/ChatGPT (no Platform sk- key).
    private func completeOpenAIChatGPT(
        messages: [LLMMessage],
        accessToken: String,
        model: String,
        maxTokens: Int
    ) async throws -> LLMCompletion {
        // Prefer Responses-style Codex backend used by ChatGPT-authenticated clients
        let url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        var input: [[String: Any]] = []
        for msg in messages where msg.role != .system {
            let role = msg.role == .assistant ? "assistant" : "user"
            input.append([
                "type": "message",
                "role": role,
                "content": [["type": "input_text", "text": msg.content]],
            ])
        }
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "store": false,
            "stream": false,
        ]
        if !system.isEmpty {
            body["instructions"] = system
        }
        // max_output_tokens if supported
        body["max_output_tokens"] = maxTokens

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMClientError.decode
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("QSAgents", forHTTPHeaderField: "User-Agent")
        if let account = ProviderBrowserAuthService.shared.openAIChatGPTAccountId() {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.httpBody = data
        req.timeoutInterval = 120

        let respData: Data
        do {
            (respData, _) = try await dataWithRetry(for: req, label: "ChatGPT-OAuth")
        } catch let LLMClientError.http(code, errBody) where code == 401 || code == 403 || code == 404 {
            do {
                return try await completeOpenAICompat(
                    provider: .openAI,
                    messages: messages,
                    key: accessToken,
                    model: model,
                    temperature: 0.3,
                    maxTokens: maxTokens
                )
            } catch {
                throw LLMClientError.http(code, "ChatGPT OAuth: \(errBody.prefix(280)). Prova API key Platform o ri-importa da Codex.")
            }
        }

        // Parse Responses API shape: output[].content[].text or similar
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
            if let text = extractResponsesText(json) {
                return LLMCompletion(
                    text: text,
                    provider: .openAI,
                    model: model,
                    usage: LLMUsage(promptTokens: 0, completionTokens: max(1, text.count / 4), totalTokens: max(1, text.count / 4))
                )
            }
        }
        // Raw string fallback
        if let s = String(data: respData, encoding: .utf8), !s.isEmpty {
            return LLMCompletion(text: s, provider: .openAI, model: model, usage: .zero)
        }
        throw LLMClientError.decode
    }

    private func extractResponsesText(_ json: [String: Any]) -> String? {
        // output: [{ content: [{ type, text }] }]
        if let output = json["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if let t = c["text"] as? String { parts.append(t) }
                        if let t = c["output_text"] as? String { parts.append(t) }
                    }
                }
                if let t = item["text"] as? String { parts.append(t) }
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        if let t = json["output_text"] as? String, !t.isEmpty { return t }
        if let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let t = msg["content"] as? String {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: OpenAI-compatible (OpenAI, xAI/SpaceX, OpenRouter)

    private func completeOpenAICompat(
        provider: LLMProviderKind,
        messages: [LLMMessage],
        key: String,
        model: String,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMCompletion {
        let base = provider.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = URL(string: base + provider.chatPath)!

        let apiMessages: [[String: String]] = messages.map { msg in
            var d = ["role": msg.role.rawValue, "content": msg.content]
            if let n = msg.name { d["name"] = n }
            return d
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMClientError.decode
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .openRouter {
            req.setValue("https://qsagents.local", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("QS Agents", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = data
        req.timeoutInterval = 90

        let (respData, _) = try await dataWithRetry(for: req, label: provider.rawValue)

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMClientError.decode
        }

        var usage = LLMUsage.zero
        if let u = json["usage"] as? [String: Any] {
            usage = LLMUsage(
                promptTokens: u["prompt_tokens"] as? Int ?? 0,
                completionTokens: u["completion_tokens"] as? Int ?? 0,
                totalTokens: u["total_tokens"] as? Int ?? 0
            )
        }

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMClientError.empty }
        return LLMCompletion(text: text, provider: provider, model: model, usage: usage)
    }

    /// SSE stream for OpenAI-compatible chat completions.
    private func streamOpenAICompat(
        provider: LLMProviderKind,
        messages: [LLMMessage],
        key: String,
        model: String,
        temperature: Double,
        maxTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> LLMCompletion {
        let base = provider.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = URL(string: base + provider.chatPath)!

        let apiMessages: [[String: String]] = messages.map { msg in
            var d = ["role": msg.role.rawValue, "content": msg.content]
            if let n = msg.name { d["name"] = n }
            return d
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMClientError.decode
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider == .openRouter {
            req.setValue("https://qsagents.local", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("QS Agents", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = data
        req.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.decode }
        guard (200...299).contains(http.statusCode) else {
            // Collect a bit of body for error context
            var errBuf = Data()
            for try await b in bytes {
                errBuf.append(b)
                if errBuf.count > 800 { break }
            }
            throw LLMClientError.http(http.statusCode, String(data: errBuf, encoding: .utf8) ?? "")
        }

        var assembled = ""
        var promptTokens = 0
        var completionTokens = 0

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunkData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                continue
            }
            if let u = json["usage"] as? [String: Any] {
                promptTokens = u["prompt_tokens"] as? Int ?? promptTokens
                completionTokens = u["completion_tokens"] as? Int ?? completionTokens
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            // delta.content (chat) or text
            var piece = ""
            if let delta = first["delta"] as? [String: Any],
               let c = delta["content"] as? String {
                piece = c
            } else if let t = first["text"] as? String {
                piece = t
            }
            if !piece.isEmpty {
                assembled += piece
                await MainActor.run { onDelta(piece) }
            }
        }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMClientError.empty }
        let usage = LLMUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens > 0 ? completionTokens : max(1, text.count / 4),
            totalTokens: promptTokens + (completionTokens > 0 ? completionTokens : max(1, text.count / 4))
        )
        return LLMCompletion(text: text, provider: provider, model: model, usage: usage)
    }

    // MARK: Anthropic

    private func completeAnthropic(
        messages: [LLMMessage],
        key: String,
        model: String,
        temperature: Double,
        maxTokens: Int,
        provider: LLMProviderKind
    ) async throws -> LLMCompletion {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var system = ""
        var apiMessages: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system:
                system += (system.isEmpty ? "" : "\n") + m.content
            case .user, .tool:
                apiMessages.append(["role": "user", "content": m.content])
            case .assistant:
                apiMessages.append(["role": "assistant", "content": m.content])
            }
        }
        if apiMessages.isEmpty {
            apiMessages.append(["role": "user", "content": "…"])
        }

        // Normalize legacy / alias model IDs
        let resolvedModel = Self.normalizeAnthropicModel(model)

        var body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": max(maxTokens, 256),
            "messages": apiMessages,
        ]
        // Newer Claude models may reject non-default temperature — omit for 4.x/5.x
        let skipTemp = resolvedModel.contains("sonnet-5")
            || resolvedModel.contains("fable-5")
            || resolvedModel.contains("opus-4")
            || resolvedModel.contains("haiku-4")
            || resolvedModel.contains("mythos")
        if temperature != 1.0 && !skipTemp {
            body["temperature"] = temperature
        }
        if !system.isEmpty { body["system"] = system }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMClientError.decode
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 120

        let (respData, _) = try await dataWithRetry(for: req, label: "Anthropic/\(resolvedModel)")

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]] else {
            throw LLMClientError.decode
        }
        let text = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMClientError.empty }

        var usage = LLMUsage.zero
        if let u = json["usage"] as? [String: Any] {
            let inn = u["input_tokens"] as? Int ?? 0
            let out = u["output_tokens"] as? Int ?? 0
            usage = LLMUsage(promptTokens: inn, completionTokens: out, totalTokens: inn + out)
        }
        return LLMCompletion(text: text, provider: provider, model: resolvedModel, usage: usage)
    }

    /// Map UI aliases / typos to current Anthropic API IDs.
    private static func normalizeAnthropicModel(_ model: String) -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch m {
        case "claude-3-5-sonnet", "claude-3-5-sonnet-latest", "claude-3.5-sonnet":
            return "claude-sonnet-4-6"
        case "claude-3-opus", "claude-opus-4", "claude-opus-4-latest":
            return "claude-opus-4-8"
        case "claude-3-haiku", "claude-haiku":
            return "claude-haiku-4-5"
        default:
            return m
        }
    }

    // MARK: Gemini

    private func completeGemini(
        messages: [LLMMessage],
        key: String,
        model: String,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMCompletion {
        // https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)"
        guard let endpoint = URL(string: urlStr) else { throw LLMClientError.badURL }

        var system = ""
        var contents: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system:
                system += (system.isEmpty ? "" : "\n") + m.content
            case .user, .tool:
                contents.append(["role": "user", "parts": [["text": m.content]]])
            case .assistant:
                contents.append(["role": "model", "parts": [["text": m.content]]])
            }
        }
        if contents.isEmpty {
            contents.append(["role": "user", "parts": [["text": "…"]]])
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens,
            ],
        ]
        if !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMClientError.decode
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 90

        let (respData, _) = try await dataWithRetry(for: req, label: "Gemini/\(model)")

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMClientError.decode
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMClientError.empty }

        var usage = LLMUsage.zero
        if let u = json["usageMetadata"] as? [String: Any] {
            let inn = u["promptTokenCount"] as? Int ?? 0
            let out = u["candidatesTokenCount"] as? Int ?? 0
            usage = LLMUsage(promptTokens: inn, completionTokens: out, totalTokens: inn + out)
        }
        return LLMCompletion(text: text, provider: .gemini, model: model, usage: usage)
    }

    func testConnection(_ provider: LLMProviderKind) async -> (ok: Bool, message: String) {
        guard hasKey(provider) else {
            return (false, "Key assente in Keychain")
        }
        do {
            let r = try await complete(
                system: "Reply with exactly: OK",
                user: "ping",
                provider: provider,
                model: provider.defaultModel
            )
            return (true, "OK · \(r.model) · \(r.usage.totalTokens) tok")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
