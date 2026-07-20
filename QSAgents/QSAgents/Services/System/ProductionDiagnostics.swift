import Foundation
import AppKit

/// Local production health check + diagnostics export (no network telemetry).
@MainActor
enum ProductionDiagnostics {
    struct Check: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    /// Shown before exporting diagnostics or audit CSV.
    static let exportPrivacyNotice = """
    L'export può contenere hostname, percorsi abbreviati (~) e log dell'app.
    Non include chiavi API (Keychain). Controlla il file prima di condividerlo.
    """

    static func runChecks(
        workspaces: WorkspaceStore?,
        tasks: TaskStore?,
        safety: SafetyGuardrails?
    ) -> [Check] {
        var out: [Check] = []

        out.append(Check(
            name: "Build",
            ok: true,
            detail: "\(AppConfig.versionLabel) · \(AppConfig.isProduction ? "Release" : "Debug") · \(AppConfig.bundleId)"
        ))

        out.append(Check(
            name: "Demo data",
            ok: !AppConfig.useDemoData,
            detail: AppConfig.useDemoData
                ? "ATTIVO (solo Debug) — disattiva per uso reale"
                : "Off (path produzione)"
        ))

        let keyOk = KeychainStore.hasAnyLLMKey()
        out.append(Check(
            name: "API key LLM",
            ok: keyOk,
            detail: keyOk ? "Almeno un provider in Keychain" : "Nessuna key — Integrazioni"
        ))

        let ws = workspaces?.current?.path
        out.append(Check(
            name: "Workspace",
            ok: ws != nil,
            detail: ws.map { shorten($0) } ?? "Nessuno aperto"
        ))

        let taskN = tasks?.tasks.count ?? 0
        out.append(Check(
            name: "QS Tasks",
            ok: true,
            detail: "\(taskN) task in board"
        ))

        let safetyOn = safety?.enabled ?? false
        out.append(Check(
            name: "Safety",
            ok: true,
            detail: safetyOn ? "Guardrail attivi" : "Guardrail off (consigliati on)"
        ))

        let logExists = FileManager.default.fileExists(atPath: AppConfig.logsDirectory.path)
        out.append(Check(
            name: "Log locali",
            ok: logExists,
            detail: shorten(AppConfig.logsDirectory.path)
        ))

        let supportWritable: Bool = {
            let probe = AppConfig.dataDirectory.appendingPathComponent(".write-probe")
            do {
                try "ok".write(to: probe, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: probe)
                return true
            } catch {
                return false
            }
        }()
        out.append(Check(
            name: "Application Support",
            ok: supportWritable,
            detail: supportWritable ? "Scrivibile" : "Non scrivibile — controlla permessi"
        ))

        out.append(Check(
            name: "Hardened Runtime",
            ok: true,
            detail: "Entitlements: network client, audio-input, no app-sandbox (PTY/agent tooling)"
        ))

        out.append(Check(
            name: "Privacy",
            ok: true,
            detail: "Keychain locale · no telemetria cloud · SecretRedactor su terminal/tool · \(AppConfig.privacyEmail)"
        ))

        out.append(Check(
            name: "Crash log",
            ok: true,
            detail: AppConfig.crashLogEnabled
                ? "Opt-in ON → \(shorten(AppConfig.logsDirectory.appendingPathComponent("crashes.log").path))"
                : "Opt-in OFF (consigliato default) — abilita in Supporto se serve debug"
        ))

        let claudePath = CodingCLILauncher.resolveClaudeBinary()
        out.append(Check(
            name: "Claude CLI",
            ok: claudePath != nil || CodingEngine.preferred == .qsAPI,
            detail: claudePath.map { "Trovato: \(shorten($0))" }
                ?? "Non trovato — usa QS API o installa Claude Code CLI"
        ))

        out.append(Check(
            name: "Support contact",
            ok: true,
            detail: AppConfig.supportEmail
        ))

        return out
    }

    /// Write a human-readable diagnostics report next to app logs. Returns path.
    @discardableResult
    static func exportReport(
        workspaces: WorkspaceStore?,
        tasks: TaskStore?,
        safety: SafetyGuardrails?
    ) -> URL? {
        let checks = runChecks(workspaces: workspaces, tasks: tasks, safety: safety)
        var lines: [String] = [
            "QS Agents — Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Version: \(AppConfig.versionLabel)",
            "Host: \(ProcessInfo.processInfo.hostName)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "=== Privacy notice ===",
            exportPrivacyNotice,
            "",
            "=== Checks ===",
        ]
        for c in checks {
            lines.append("[\(c.ok ? "OK" : "!!")] \(c.name): \(c.detail)")
        }
        lines.append("")
        lines.append("=== Paths (shortened) ===")
        lines.append("Support: \(shorten(AppConfig.supportDirectory.path))")
        lines.append("Logs: \(shorten(AppConfig.logsDirectory.path))")
        lines.append("Data: \(shorten(AppConfig.dataDirectory.path))")
        lines.append("")
        lines.append("=== Notes ===")
        lines.append("Do not paste API keys into tickets. Keys live in Keychain only.")
        lines.append("Attach app.log / crashes.log from Logs if needed.")

        let body = SecretRedactor.redact(lines.joined(separator: "\n"))
        let url = AppConfig.logsDirectory.appendingPathComponent(
            "diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        )
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            AppLogger.info("Diagnostics exported → \(shorten(url.path))")
            return url
        } catch {
            AppLogger.error("Diagnostics export failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func openLogsFolder() {
        NSWorkspace.shared.open(AppConfig.logsDirectory)
    }

    private static func shorten(_ path: String) -> String {
        SecretRedactor.shortenPaths(path)
    }
}

private extension KeychainStore {
    static func hasAnyLLMKey() -> Bool {
        for p in LLMProviderKind.allCases {
            if hasValue(p.keychainAccount) { return true }
            for leg in p.legacyKeychainAccounts where hasValue(leg) { return true }
        }
        return false
    }
}
