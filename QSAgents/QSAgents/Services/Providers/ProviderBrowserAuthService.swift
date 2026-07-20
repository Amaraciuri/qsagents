import Foundation
import AppKit
import Combine

/// Browser / first-party CLI auth for AI providers (Cursor-style account login).
///
/// Reality check (2026):
/// - **OpenAI / ChatGPT**: Codex CLI OAuth is the practical “login without API key” path.
///   We import tokens from `~/.codex/auth.json` or launch `codex login` in Terminal.
/// - **Anthropic / Claude**: subscription OAuth is **restricted to Claude Code / claude.ai**
///   (Anthropic Consumer ToS). Third-party apps must use **Console API keys**.
///   We open the console in browser + optional Keychain import with clear warnings.
@MainActor
final class ProviderBrowserAuthService: ObservableObject {
    static let shared = ProviderBrowserAuthService()

    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var openAIEmail: String?
    @Published var openAIAccountId: String?
    @Published var anthropicNote: String?

    // Keychain accounts
    static let openAIOAuthAccount = "OpenAI-OAuth"       // JSON blob: access/refresh/account
    static let openAIAPIKeyAccount = "OpenAI"            // classic sk- key (existing)
    static let anthropicAPIKeyAccount = "Anthropic"

    private let codexAuthPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")

    // MARK: - Status

    var openAIHasAPIKey: Bool {
        KeychainStore.hasValue(Self.openAIAPIKeyAccount)
    }

    var openAIHasOAuth: Bool {
        oauthBundle() != nil
    }

    var openAIConnected: Bool { openAIHasAPIKey || openAIHasOAuth }

    var anthropicHasKey: Bool {
        KeychainStore.hasValue(Self.anthropicAPIKeyAccount)
    }

    func refreshStatus() {
        if let b = oauthBundle() {
            openAIAccountId = b.accountId
            openAIEmail = b.emailHint
        } else {
            openAIAccountId = nil
            openAIEmail = nil
        }
        anthropicNote = anthropicHasKey
            ? "API key in Keychain"
            : "Serve API key Console (subscription login non usabile in app terze)"
    }

    // MARK: - OpenAI / ChatGPT

    /// Import session already logged into Codex CLI (`codex login` / ChatGPT).
    func importOpenAIFromCodexCLI() {
        isBusy = true
        lastError = nil
        statusMessage = "Leggo ~/.codex/auth.json…"
        defer {
            isBusy = false
            refreshStatus()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: codexAuthPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = "Nessun login Codex. Installa Codex CLI e fai `codex login`, oppure usa una API key Platform."
            statusMessage = nil
            return
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            lastError = "auth.json senza access_token. Riesegui: codex login"
            statusMessage = nil
            return
        }
        let refresh = tokens["refresh_token"] as? String
        let accountId = tokens["account_id"] as? String
        let idToken = tokens["id_token"] as? String
        let email = Self.emailFromJWT(idToken)
        let bundle = OpenAIOAuthBundle(
            accessToken: access,
            refreshToken: refresh,
            accountId: accountId,
            emailHint: email,
            savedAt: Date()
        )
        saveOAuthBundle(bundle)
        openAIEmail = email
        openAIAccountId = accountId
        statusMessage = email.map { "ChatGPT collegato come \($0)" }
            ?? "Token ChatGPT/Codex importato in Keychain"
        lastError = nil
        AppLogger.info("OpenAI OAuth imported from Codex CLI")
    }

    /// Open browser + Terminal for first-party ChatGPT login via Codex CLI.
    func loginOpenAIWithBrowser() {
        isBusy = true
        lastError = nil
        statusMessage = "Apro login ChatGPT (Codex)…"

        // Prefer Codex CLI if installed
        let which = shell("command -v codex 2>/dev/null")
        if which.ok, !which.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Open Terminal with codex login — user completes browser flow
            let script = """
            tell application "Terminal"
                activate
                do script "codex login; echo; echo 'Poi torna in QS Agents → Integrazioni → Importa da Codex CLI'; exit"
            end tell
            """
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qs-codex-login.scpt")
            try? script.write(to: tmp, atomically: true, encoding: .utf8)
            _ = shell("osascript \(tmp.path.shellQuoted)")
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
            statusMessage = "Completa il login in Terminal (`codex login`), poi premi «Importa da Codex CLI»."
            isBusy = false
            return
        }

        // No codex: open Platform key page + ChatGPT account page
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
        statusMessage = "Codex CLI non trovato. Apri ChatGPT per l’account; per QS Agents usa una API key Platform (o installa Codex e `codex login`)."
        lastError = "Installa Codex CLI per login ChatGPT senza API key: https://github.com/openai/codex"
        isBusy = false
    }

    func disconnectOpenAIOAuth() {
        KeychainStore.delete(Self.openAIOAuthAccount)
        openAIEmail = nil
        openAIAccountId = nil
        statusMessage = "Sessione ChatGPT/Codex rimossa"
        lastError = nil
    }

    func openOpenAIPlatformKeys() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
    }

    // MARK: - Anthropic / Claude

    /// Open Anthropic Console to create an API key (required for third-party apps).
    func loginAnthropicWithBrowser() {
        lastError = nil
        // Console API keys — the only supported path for third-party apps
        NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
        NSWorkspace.shared.open(URL(string: "https://claude.ai/")!)
        statusMessage = """
        Browser aperto: Console (API key) + claude.ai (account).
        Incolla la key sk-ant-… su Anthropic → Configura.
        Nota: il login Pro/Max di Claude Code non può essere riusato in app terze (policy Anthropic 2026).
        """
        anthropicNote = "API key Console richiesta per QS Agents"
        isBusy = false
    }

    /// Best-effort: import from macOS Keychain item written by Claude Code (may not work with API — ToS).
    func importAnthropicFromClaudeCodeKeychain() {
        isBusy = true
        lastError = nil
        statusMessage = "Cerco credenziali Claude Code in Portachiavi…"
        defer { isBusy = false; refreshStatus() }

        // Claude Code stores generic password "Claude Code-credentials"
        let r = shell("security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null")
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !raw.isEmpty else {
            lastError = "Nessuna credenziale Claude Code in Portachiavi. Usa Console API key."
            statusMessage = nil
            return
        }
        // Payload is often JSON — extract sk-ant or oauth token
        var candidate: String?
        if raw.hasPrefix("sk-ant") {
            candidate = raw
        } else if let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            candidate = (json["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
                ?? json["accessToken"] as? String
                ?? json["apiKey"] as? String
        }
        guard let token = candidate, !token.isEmpty else {
            lastError = "Formato credenziali Claude non riconosciuto. Incolla una API key Console."
            statusMessage = nil
            return
        }
        if token.hasPrefix("sk-ant") {
            KeychainStore.set(token, for: Self.anthropicAPIKeyAccount)
            statusMessage = "API key Claude importata"
            lastError = nil
        } else {
            // OAuth token — store separately with warning; API calls may fail
            KeychainStore.set(token, for: "Anthropic-OAuth")
            statusMessage = "Token OAuth Claude salvato — ma Anthropic blocca l’uso in app terze. Preferisci API key Console."
            lastError = "Policy Anthropic: OAuth Pro/Max solo per Claude Code. Per QS Agents usa console.anthropic.com → API keys."
            AppLogger.warn("Anthropic OAuth imported (third-party use may be blocked)")
        }
    }

    // MARK: - OAuth bundle storage

    struct OpenAIOAuthBundle: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var accountId: String?
        var emailHint: String?
        var savedAt: Date
    }

    func oauthBundle() -> OpenAIOAuthBundle? {
        guard let s = KeychainStore.get(Self.openAIOAuthAccount),
              let data = s.data(using: .utf8),
              let b = try? JSONDecoder().decode(OpenAIOAuthBundle.self, from: data),
              !b.accessToken.isEmpty else {
            return nil
        }
        return b
    }

    private func saveOAuthBundle(_ b: OpenAIOAuthBundle) {
        guard let data = try? JSONEncoder().encode(b),
              let s = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(s, for: Self.openAIOAuthAccount)
    }

    /// Access token for ChatGPT/Codex backend (not Platform sk- key).
    func openAIAccessToken() -> String? {
        oauthBundle()?.accessToken
    }

    func openAIChatGPTAccountId() -> String? {
        oauthBundle()?.accountId
    }

    // MARK: - Helpers

    private static func emailFromJWT(_ jwt: String?) -> String? {
        guard let jwt, jwt.split(separator: ".").count >= 2 else { return nil }
        var payload = String(jwt.split(separator: ".")[1])
        // base64url
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    @discardableResult
    private func shell(_ cmd: String) -> (ok: Bool, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, s)
    }
}

private extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
