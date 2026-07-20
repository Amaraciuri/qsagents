import Foundation

/// Policy-as-code loaded from `qs-safety.json` in workspace root (Fase 10).
struct WorkspaceSafetyPolicy: Codable, Equatable {
    var version: Int
    var environment: String?
    var allowCommands: [String]?
    var denyCommands: [String]?
    var requireConfirm: [String]?
    var maxParallelAgents: Int?
    var dryRunDefault: Bool?
    var notes: String?

    static let fileName = "qs-safety.json"

    static func load(from workspacePath: String) -> WorkspaceSafetyPolicy? {
        let path = (workspacePath as NSString).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let policy = try? JSONDecoder().decode(WorkspaceSafetyPolicy.self, from: data) else {
            return nil
        }
        return policy
    }

    static func templateJSON() -> String {
        """
        {
          "version": 1,
          "environment": "development",
          "denyCommands": ["rm -rf /", "mkfs", "dd if=", "shutdown"],
          "requireConfirm": ["git push --force", "npm publish", "terraform destroy"],
          "maxParallelAgents": 4,
          "dryRunDefault": false,
          "notes": "QS Agents workspace policy — versiona in git"
        }
        """
    }

    func blocks(_ command: String) -> String? {
        let lower = command.lowercased()
        for d in denyCommands ?? [] {
            if lower.contains(d.lowercased()) {
                return "Bloccato da qs-safety.json: \(d)"
            }
        }
        return nil
    }

    func needsConfirm(_ command: String) -> String? {
        let lower = command.lowercased()
        for d in requireConfirm ?? [] {
            if lower.contains(d.lowercased()) {
                return "Conferma richiesta da qs-safety.json: \(d)"
            }
        }
        return nil
    }
}

/// Orchestrator dry-run: describe actions without executing (Fase 10).
@MainActor
final class DryRunController: ObservableObject {
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "qs.dryrun")

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "qs.dryrun")
    }

    func wrap(_ description: String) -> String {
        "🧪 **DRY-RUN** (nessuna esecuzione)\n\nAvrei fatto:\n\(description)\n\nDisattiva dry-run in Sicurezza o di' `dry-run off`."
    }
}
