import Foundation

/// Strips sensitive environment variables before agent / orchestrator child processes run.
///
/// Interactive user terminals inherit the full shell environment by default.
/// Agent-launched PTYs and tool subprocesses use `.agentSafe` so API keys and
/// cloud credentials from the parent GUI process are not leaked to untrusted commands.
enum AgentProcessEnvironment {
    /// Exact env var names removed in agent-safe mode.
    private static let blockedExact: Set<String> = [
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "XAI_API_KEY",
        "GOOGLE_API_KEY",
        "GEMINI_API_KEY",
        "OPENROUTER_API_KEY",
        "HUGGINGFACE_TOKEN",
        "HF_TOKEN",
        "GITHUB_TOKEN",
        "GH_TOKEN",
        "DATABASE_URL",
        "POSTGRES_URL",
        "MYSQL_URL",
        "REDIS_URL",
        "MONGODB_URI",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "AWS_DEFAULT_REGION",
        "AZURE_CLIENT_SECRET",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "NPM_TOKEN",
        "NETRC",
    ]

    /// Prefixes stripped (e.g. `AWS_*`, `GITHUB_*`).
    private static let blockedPrefixes = [
        "AWS_",
        "AZURE_",
        "GCP_",
        "GOOGLE_CLOUD_",
        "DATABASE_",
        "PG",
        "MYSQL_",
        "REDIS_",
        "MONGO",
    ]

    enum Mode {
        /// User shell — inherit parent environment (minus nothing).
        case inherit
        /// Agent / tool subprocess — strip secrets listed above.
        case agentSafe
    }

    static func prepare(_ base: [String: String] = ProcessInfo.processInfo.environment, mode: Mode) -> [String: String] {
        switch mode {
        case .inherit:
            return base
        case .agentSafe:
            var env = base
            for key in env.keys {
                if shouldStrip(key) {
                    env.removeValue(forKey: key)
                }
            }
            return env
        }
    }

    private static func shouldStrip(_ key: String) -> Bool {
        let upper = key.uppercased()
        if blockedExact.contains(upper) { return true }
        for prefix in blockedPrefixes where upper.hasPrefix(prefix) { return true }
        if upper.contains("SECRET") || upper.contains("PASSWORD") || upper.hasSuffix("_TOKEN") {
            return true
        }
        return false
    }
}
