import Foundation

/// Lightweight post-coding checks before human review (no heavy CI).
struct QualityGateResult: Equatable {
    var ok: Bool
    var summary: String
    var lines: [String]

    var chatMarkdown: String {
        let icon = ok ? "✅" : "⚠️"
        let body = lines.map { "• \($0)" }.joined(separator: "\n")
        return """
        **Quality gate** \(icon) \(summary)

        \(body)
        """
    }
}

enum QualityGate {
    /// Sync, fast checks on workspace + current git status.
    @MainActor
    static func run(workspace: String, git: GitService?) -> QualityGateResult {
        let root = (workspace as NSString).standardizingPath
        var lines: [String] = []
        var issues = 0

        if let git {
            // Prefer existing snapshot — caller often just refreshed (avoid git storm / UI churn).
            if git.status.root != root {
                git.setPath(root)
            }
            let changes = git.status.changes
            let dirty = changes.count
            if dirty == 0 {
                lines.append("Working tree clean — nessun file da revisionare")
                issues += 1
            } else {
                lines.append("\(dirty) file dirty · \(git.status.stagedCount) staged")
                for c in changes.prefix(8) {
                    lines.append("`\(c.path)` (\(c.status))")
                }
                if dirty > 8 { lines.append("… +\(dirty - 8) altri") }
            }
            let conflictish = changes.filter {
                let s = $0.status.uppercased()
                return s.contains("U") || s == "AA" || s == "DD"
            }
            if !conflictish.isEmpty {
                lines.append("Possibili CONFLICTS (\(conflictish.count)) — risolvi prima di Completa")
                issues += 2
            }
        } else {
            lines.append("Git non collegato — skip status")
        }

        let fm = FileManager.default
        // Soft hints: test scripts exist but we don't run them (keep gate <1s)
        let pkg = (root as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkg),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pkg)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = obj["scripts"] as? [String: Any] {
            let keys = ["test", "lint", "typecheck", "check"].filter { scripts[$0] != nil }
            if keys.isEmpty {
                lines.append("package.json senza script test/lint")
            } else {
                lines.append("Suggerito: `npm run \(keys[0])` (non eseguito in automatico)")
            }
        }
        if fm.fileExists(atPath: (root as NSString).appendingPathComponent("Cargo.toml")) {
            lines.append("Suggerito: `cargo check` (non eseguito in automatico)")
        }
        if fm.fileExists(atPath: (root as NSString).appendingPathComponent("Package.swift")) {
            lines.append("Suggerito: `swift build` (non eseguito in automatico)")
        }

        let ok = issues == 0
        let summary = ok
            ? "pronto per review umana"
            : (issues >= 2 ? "attenzione richiesta" : "da verificare")
        return QualityGateResult(ok: ok, summary: summary, lines: lines)
    }
}
