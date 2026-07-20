import Foundation
import CryptoKit

/// Redacts secrets and shortens home paths before logging, exports, or remote notifications.
enum SecretRedactor {
    private static let home = NSHomeDirectory()

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"sk-[A-Za-z0-9_\-]{10,}"#,
            #"ghp_[A-Za-z0-9]{20,}"#,
            #"github_pat_[A-Za-z0-9_]{20,}"#,
            #"xai-[A-Za-z0-9_\-]{20,}"#,
            #"AIza[0-9A-Za-z_\-]{20,}"#,
            #"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"(?i)(api[_-]?key|token|password|secret|authorization)\s*[:=]\s*\S+"#,
            #"(?i)(OPENAI|ANTHROPIC|AWS|GITHUB|DATABASE)_[A-Z0-9_]*\s*=\s*\S+"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    static func redact(_ text: String) -> String {
        var out = shortenPaths(text) as NSString
        for re in patterns {
            let range = NSRange(location: 0, length: out.length)
            out = re.stringByReplacingMatches(
                in: out as String,
                options: [],
                range: range,
                withTemplate: "•••REDACTED•••"
            ) as NSString
        }
        return out as String
    }

    /// Replace the user home directory prefix with `~` (also common `/Users/name` variants).
    static func shortenPaths(_ text: String) -> String {
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    /// Truncate a remote approval code for audit storage (never store full code in signed log).
    static func hashPrefix(_ value: String, length: Int = 8) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(length))
    }
}
