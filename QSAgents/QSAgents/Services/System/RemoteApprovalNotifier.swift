import Foundation
import Combine

/// Slack Incoming Webhook + PagerDuty Events API v2 for dual-approval workflows.
/// Outbound payloads are redacted (commands, paths, secrets); full remote codes are sent only on initial dual-pending notify.
@MainActor
final class RemoteApprovalNotifier: ObservableObject {
    @Published var slackEnabled: Bool = false
    @Published var pagerDutyEnabled: Bool = false
    @Published var slackChannelHint: String = "#qs-agents-approvals"
    @Published var lastStatus: String = "Idle"
    @Published var lastError: String?

    /// One-time remote codes waiting for second approval (code → pending meta).
    @Published private(set) var outstandingRemoteCodes: [String: RemoteApprovalTicket] = [:]

    private let slackAccount = "QSAgents.Slack.Webhook"
    private let pdAccount = "QSAgents.PagerDuty.RoutingKey"

    struct RemoteApprovalTicket: Equatable {
        let code: String
        let command: String
        let path: String?
        let ruleName: String
        let createdAt: Date
        var pdDedupKey: String?
    }

    init() {
        slackEnabled = UserDefaults.standard.bool(forKey: "qs.remote.slack.enabled")
        pagerDutyEnabled = UserDefaults.standard.bool(forKey: "qs.remote.pd.enabled")
        slackChannelHint = UserDefaults.standard.string(forKey: "qs.remote.slack.channel") ?? "#qs-agents-approvals"
    }

    // MARK: - Credentials

    var hasSlackWebhook: Bool {
        if let w = KeychainStore.get(slackAccount), !w.isEmpty { return true }
        return false
    }

    var hasPagerDutyKey: Bool {
        if let k = KeychainStore.get(pdAccount), !k.isEmpty { return true }
        return false
    }

    func setSlackWebhook(_ url: String) {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            KeychainStore.delete(slackAccount)
        } else {
            KeychainStore.set(t, for: slackAccount)
        }
        persistFlags()
    }

    func setPagerDutyRoutingKey(_ key: String) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            KeychainStore.delete(pdAccount)
        } else {
            KeychainStore.set(t, for: pdAccount)
        }
        persistFlags()
    }

    func persistFlags() {
        UserDefaults.standard.set(slackEnabled, forKey: "qs.remote.slack.enabled")
        UserDefaults.standard.set(pagerDutyEnabled, forKey: "qs.remote.pd.enabled")
        UserDefaults.standard.set(slackChannelHint, forKey: "qs.remote.slack.channel")
    }

    // MARK: - Notify dual pending

    /// Generates a remote second-approval code and notifies Slack/PD.
    @discardableResult
    func notifyDualPending(
        command: String,
        path: String?,
        environment: String,
        ruleName: String,
        firstApproverHint: String?,
        host: String
    ) async -> String? {
        let code = Self.generateCode()
        var ticket = RemoteApprovalTicket(
            code: code,
            command: command,
            path: path,
            ruleName: ruleName,
            createdAt: .now
        )

        let safeCommand = redactCommand(command)
        let safePath = redactPath(path)
        let summary = """
        🛡️ *QS Agents — Two-person approval*
        *Env:* `\(environment)` · *Rule:* \(ruleName)
        *Host:* \(host) · *User:* \(NSUserName())
        *Command:*
        ```
        \(safeCommand.prefix(500))
        ```
        *Path:* \(safePath ?? "—")
        \(firstApproverHint.map { "*1ª firma attesa/di:* \($0)" } ?? "")

        *Remote 2ª firma code:* `\(code)`
        Incolla questo codice nell'app QS Agents (dialog two-person) *oppure* usa il PIN locale.
        Codice valido 30 minuti.
        """

        if slackEnabled, hasSlackWebhook {
            await postSlack(text: summary)
        }

        if pagerDutyEnabled, hasPagerDutyKey {
            let dedup = "qsagents-\(code)"
            ticket.pdDedupKey = dedup
            await triggerPagerDuty(
                summary: "QS Agents dual approval: \(ruleName)",
                severity: environment.uppercased().contains("LIVE") || environment.uppercased().contains("PROD") ? "error" : "warning",
                dedupKey: dedup,
                details: [
                    "command": String(safeCommand.prefix(300)),
                    "path": safePath ?? "",
                    "code_hash": SecretRedactor.hashPrefix(code),
                    "host": host,
                ]
            )
        }

        outstandingRemoteCodes[code] = ticket
        pruneExpired()
        lastStatus = "Notifica inviata · code \(SecretRedactor.hashPrefix(code))"
        return code
    }

    func notifyFirstApproved(command: String, first: String, ruleName: String, remoteCode: String?) async {
        let codeNote = remoteCode.map { "Codice 2ª firma ancora valido (ref `\($0.prefix(4))…`)." }
            ?? "In attesa 2ª firma (PIN o codice Slack)."
        let text = """
        ⏳ *QS Agents — 1ª firma ricevuta*
        *Da:* \(first) · *Rule:* \(ruleName)
        ```
        \(redactCommand(command).prefix(300))
        ```
        \(codeNote)
        """
        if slackEnabled, hasSlackWebhook {
            await postSlack(text: text)
        }
        lastStatus = "1ª firma notificata"
    }

    func notifyApproved(
        command: String,
        first: String?,
        second: String?,
        ruleName: String,
        remoteCode: String?
    ) async {
        let text = """
        ✅ *QS Agents — Approvato*
        *Rule:* \(ruleName)
        *1ª:* \(first ?? "—") · *2ª:* \(second ?? "—")
        ```
        \(redactCommand(command).prefix(400))
        ```
        """
        if slackEnabled, hasSlackWebhook {
            await postSlack(text: text)
        }
        if let code = remoteCode, let ticket = outstandingRemoteCodes[code], let dedup = ticket.pdDedupKey {
            await resolvePagerDuty(dedupKey: dedup, note: "Approved by \(second ?? "second")")
            outstandingRemoteCodes.removeValue(forKey: code)
        } else if let code = remoteCode {
            outstandingRemoteCodes.removeValue(forKey: code)
        }
        lastStatus = "Approvazione notificata"
    }

    func notifyDenied(command: String, ruleName: String, remoteCode: String?) async {
        let text = """
        ⛔ *QS Agents — Negato*
        *Rule:* \(ruleName)
        ```
        \(redactCommand(command).prefix(300))
        ```
        """
        if slackEnabled, hasSlackWebhook {
            await postSlack(text: text)
        }
        if let code = remoteCode, let ticket = outstandingRemoteCodes[code], let dedup = ticket.pdDedupKey {
            await resolvePagerDuty(dedupKey: dedup, note: "Denied")
            outstandingRemoteCodes.removeValue(forKey: code)
        }
        lastStatus = "Deny notificato"
    }

    /// Validate remote code for second approval (alternative to PIN).
    func consumeRemoteCode(_ code: String, forCommand command: String) -> (ok: Bool, error: String?) {
        pruneExpired()
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let ticket = outstandingRemoteCodes[c] else {
            return (false, "Codice remoto non valido o scaduto")
        }
        if ticket.command != command {
            return (false, "Il codice non corrisponde a questo comando")
        }
        outstandingRemoteCodes.removeValue(forKey: c)
        return (true, nil)
    }

    /// Informational Slack message (task completed, etc.) — no approval code.
    func notifyInfo(title: String, body: String) {
        guard slackEnabled, hasSlackWebhook else { return }
        Task {
            await postSlack(text: "*\(title)*\n\(SecretRedactor.redact(body))")
            lastStatus = "Info inviato: \(title)"
        }
    }

    // MARK: - HTTP

    private func postSlack(text: String) async {
        guard let urlString = KeychainStore.get(slackAccount),
              let url = URL(string: urlString) else {
            lastError = "Slack webhook mancante"
            return
        }
        let safeText = SecretRedactor.redact(text)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": safeText,
            "mrkdwn": true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "Slack HTTP \(http.statusCode)"
            } else {
                lastError = nil
            }
        } catch {
            lastError = "Slack: \(error.localizedDescription)"
        }
    }

    private func triggerPagerDuty(
        summary: String,
        severity: String,
        dedupKey: String,
        details: [String: String]
    ) async {
        guard let routing = KeychainStore.get(pdAccount), !routing.isEmpty else {
            lastError = "PagerDuty routing key mancante"
            return
        }
        guard let url = URL(string: "https://events.pagerduty.com/v2/enqueue") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let redactedDetails = details.mapValues { SecretRedactor.redact($0) }
        let body: [String: Any] = [
            "routing_key": routing,
            "event_action": "trigger",
            "dedup_key": dedupKey,
            "payload": [
                "summary": SecretRedactor.redact(summary),
                "severity": severity,
                "source": "qs-agents",
                "component": "safety-guardrails",
                "custom_details": redactedDetails,
            ] as [String: Any],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "PagerDuty HTTP \(http.statusCode)"
            }
        } catch {
            lastError = "PagerDuty: \(error.localizedDescription)"
        }
    }

    private func resolvePagerDuty(dedupKey: String, note: String) async {
        guard let routing = KeychainStore.get(pdAccount), !routing.isEmpty else { return }
        guard let url = URL(string: "https://events.pagerduty.com/v2/enqueue") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "routing_key": routing,
            "event_action": "resolve",
            "dedup_key": dedupKey,
            "payload": [
                "summary": "Resolved: \(SecretRedactor.redact(note))",
                "severity": "info",
                "source": "qs-agents",
            ] as [String: Any],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        outstandingRemoteCodes = outstandingRemoteCodes.filter { $0.value.createdAt > cutoff }
    }

    private func redactCommand(_ command: String) -> String {
        SecretRedactor.redact(command)
    }

    private func redactPath(_ path: String?) -> String? {
        path.map { SecretRedactor.shortenPaths(SecretRedactor.redact($0)) }
    }

    static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var s = ""
        for _ in 0..<8 {
            s.append(alphabet.randomElement()!)
        }
        let i = s.index(s.startIndex, offsetBy: 4)
        return String(s[..<i]) + "-" + String(s[i...])
    }
}
