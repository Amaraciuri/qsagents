import Foundation
import AppKit
import Combine

/// GitHub browser login via **OAuth Device Flow** (+ optional `gh` CLI).
///
/// Requires a free OAuth App (only `client_id`, public):
/// https://github.com/settings/developers → New OAuth App
/// - Homepage: `https://github.com` (any)
/// - Callback URL: `http://127.0.0.1` (unused by device flow, but required field)
///
/// Scopes: `repo` (push) · `read:user` (identity).
@MainActor
final class GitHubAuthService: ObservableObject {
    static let shared = GitHubAuthService()
    static let keychainAccount = "GitHub"
    static let clientIdKey = "qs.github.oauth.client_id"

    @Published var isAuthenticating = false
    @Published var userCode: String?
    @Published var verificationURL: String?
    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var login: String? // github username when known

    private var pollTask: Task<Void, Never>?

    var clientId: String {
        get {
            UserDefaults.standard.string(forKey: Self.clientIdKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIdKey)
        }
    }

    var hasClientId: Bool { !clientId.isEmpty }

    var isLoggedIn: Bool {
        guard let t = KeychainStore.get(Self.keychainAccount) else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Device Flow (browser)

    /// Start GitHub Device Flow: opens browser, user confirms, we poll for token → Keychain.
    func loginWithBrowser(scopes: String = "repo read:user") {
        lastError = nil
        statusMessage = nil
        guard hasClientId else {
            lastError = "Manca OAuth Client ID. Creane uno gratis su GitHub → Settings → Developer settings → OAuth Apps."
            return
        }
        pollTask?.cancel()
        isAuthenticating = true
        userCode = nil
        verificationURL = nil
        statusMessage = "Richiesta codice dispositivo…"

        Task {
            do {
                let device = try await requestDeviceCode(scopes: scopes)
                userCode = device.userCode
                verificationURL = device.verificationURIComplete ?? device.verificationURI
                statusMessage = "Apri il browser e inserisci il codice: \(device.userCode)"

                // Open browser
                let urlStr = device.verificationURIComplete ?? device.verificationURI
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }

                // Poll
                let token = try await pollForToken(
                    deviceCode: device.deviceCode,
                    interval: device.interval,
                    expiresIn: device.expiresIn
                )
                KeychainStore.set(token, for: Self.keychainAccount)
                await refreshUserLogin()
                statusMessage = login.map { "Connesso come \($0)" } ?? "Token GitHub salvato in Keychain"
                lastError = nil
                isAuthenticating = false
                userCode = nil
                AppLogger.info("GitHub OAuth device flow OK")
            } catch is CancellationError {
                isAuthenticating = false
                statusMessage = "Annullato"
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
                isAuthenticating = false
                AppLogger.error("GitHub OAuth: \(error.localizedDescription)")
            }
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        isAuthenticating = false
        userCode = nil
        statusMessage = "Login annullato"
    }

    func logout() {
        KeychainStore.delete(Self.keychainAccount)
        login = nil
        statusMessage = "Disconnesso da GitHub"
    }

    /// Copy user code to pasteboard (if mid-flow).
    func copyUserCode() {
        guard let code = userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        statusMessage = "Codice copiato: \(code)"
    }

    func openVerificationInBrowser() {
        guard let s = verificationURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - GitHub CLI bridge

    /// If `gh` is installed and already logged in, import its token.
    func importFromGitHubCLI() async {
        lastError = nil
        statusMessage = "Cerco `gh auth token`…"
        let r = await runShell("command -v gh >/dev/null && gh auth token 2>/dev/null")
        let token = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !token.isEmpty, token.hasPrefix("gho_") || token.hasPrefix("ghp_") || token.count > 20 else {
            lastError = "GitHub CLI non disponibile o non loggato. Prova: `gh auth login -w` nel terminale, poi riprova."
            statusMessage = nil
            return
        }
        KeychainStore.set(token, for: Self.keychainAccount)
        await refreshUserLogin()
        statusMessage = login.map { "Importato da gh · \($0)" } ?? "Token importato da GitHub CLI"
        lastError = nil
    }

    /// Open classic PAT creation page (manual fallback).
    func openPATPageInBrowser() {
        let url = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:user&description=QS-Agents")!
        NSWorkspace.shared.open(url)
        statusMessage = "Crea un fine-grained o classic token e incollalo in Configura."
    }

    /// Open OAuth Apps settings to create client_id.
    func openOAuthAppSettings() {
        NSWorkspace.shared.open(URL(string: "https://github.com/settings/developers")!)
    }

    func refreshUserLogin() async {
        guard let token = KeychainStore.get(Self.keychainAccount), !token.isEmpty else {
            login = nil
            return
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("QSAgents", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let login = json["login"] as? String else {
                self.login = nil
                return
            }
            self.login = login
        } catch {
            login = nil
        }
    }

    // MARK: - Device Flow HTTP

    private struct DeviceCodeResponse {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var verificationURIComplete: String?
        var expiresIn: Int
        var interval: Int
    }

    private func requestDeviceCode(scopes: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(urlEncode(clientId))&scope=\(urlEncode(scopes))"
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.network
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.decode
        }
        if let err = json["error"] as? String {
            throw AuthError.api(err, json["error_description"] as? String)
        }
        guard (200...299).contains(http.statusCode),
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else {
            throw AuthError.decode
        }
        return DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            verificationURIComplete: json["verification_uri_complete"] as? String,
            expiresIn: json["expires_in"] as? Int ?? 900,
            interval: max(5, json["interval"] as? Int ?? 5)
        )
    }

    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var wait = UInt64(interval) * 1_000_000_000

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: wait)

            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = [
                "client_id=\(urlEncode(clientId))",
                "device_code=\(urlEncode(deviceCode))",
                "grant_type=\(urlEncode("urn:ietf:params:oauth:grant-type:device_code"))",
            ].joined(separator: "&")
            req.httpBody = body.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let token = json["access_token"] as? String, !token.isEmpty {
                return token
            }

            let err = json["error"] as? String ?? ""
            if err == "authorization_pending" {
                statusMessage = "In attesa conferma nel browser… codice \(userCode ?? "")"
                continue
            }
            if err == "slow_down" {
                wait += 5_000_000_000
                continue
            }
            if err == "expired_token" {
                throw AuthError.expired
            }
            if err == "access_denied" {
                throw AuthError.denied
            }
            if !err.isEmpty {
                throw AuthError.api(err, json["error_description"] as? String)
            }
        }
        throw AuthError.expired
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func runShell(_ cmd: String) async -> (ok: Bool, stdout: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", cmd]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let s = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: (p.terminationStatus == 0, s))
                } catch {
                    cont.resume(returning: (false, ""))
                }
            }
        }
    }

    enum AuthError: LocalizedError {
        case network
        case decode
        case expired
        case denied
        case api(String, String?)

        var errorDescription: String? {
            switch self {
            case .network: return "Errore di rete"
            case .decode: return "Risposta GitHub non valida"
            case .expired: return "Codice scaduto — riprova Accedi con browser"
            case .denied: return "Accesso negato su GitHub"
            case .api(let e, let d): return d ?? e
            }
        }
    }
}
