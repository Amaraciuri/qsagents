import Foundation
import Combine

/// One real terminal tab/pane with live PTY output.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var cwd: String
    /// Line buffer for virtualized UI (preferred over full string).
    @Published private(set) var displayLines: [String] = [""]
    /// Bumps on each UI publish so views can react without deep-equating arrays.
    @Published private(set) var displayRevision: UInt64 = 0
    /// Full plain text (join on demand — use for copy/search, not high-freq UI).
    var displayText: String { displayLines.joined(separator: "\n") }
    /// Raw-ish buffer kept for copy/search (emulator plain).
    var output: String { displayText }
    @Published var isAlive: Bool = false
    @Published var exitCode: Int32?
    @Published var lastActivity: Date = .now
    @Published var projectName: String
    /// Safety role for this terminal/agent session.
    @Published var agentRole: AgentRole
    /// Optional link to a board task (auto-update on process exit).
    var linkedTaskID: UUID?

    /// Fired on main actor when the shell process exits (code).
    var onProcessExit: ((UUID, Int32) -> Void)?
    /// Optional stream of plain (redacted) output chunks — Claude supervisor / orchestrator layer.
    var onOutputText: ((UUID, String) -> Void)?

    private let pty = PTYProcess()
    private var emulator = TerminalEmulator()
    /// Pending UTF-8 bytes (split multi-byte sequences across reads).
    private var pendingBytes = Data()
    /// Emulator has new content not yet published to @Published props.
    private var uiDirty = false
    private var publishScheduled = false
    /// Cap UI publish rate (~30 fps) even if PTY flushes faster.
    private let publishInterval: Duration = .milliseconds(33)

    init(id: UUID = UUID(), title: String? = nil, cwd: String, agentRole: AgentRole = .general) {
        let resolved = (cwd as NSString).standardizingPath
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        let project = name.isEmpty ? resolved : name
        self.id = id
        self.cwd = resolved
        self.projectName = project
        self.title = title ?? project
        self.agentRole = agentRole
    }

    func start(agentLaunched: Bool = false) throws {
        // Agent/orchestrator terminals strip parent secrets from the child shell environment.
        let envMode: AgentProcessEnvironment.Mode = agentLaunched ? .agentSafe : .inherit
        // PTY already coalesces on its queue; callback is on MainActor.
        pty.onOutput = { [weak self] data in
            Task { @MainActor in
                self?.appendOutput(data)
            }
        }
        pty.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.isAlive = false
                self.exitCode = code
                self.appendPlain("\r\n[processo terminato · exit \(code)]\r\n", forcePublish: true)
                if code != 0 {
                    AppLogger.info("Terminale «\(self.title)» exit \(code)")
                }
                self.onProcessExit?(self.id, code)
            }
        }
        try pty.start(cwd: cwd, environmentMode: envMode)
        isAlive = true
        lastActivity = .now
    }

    func send(_ text: String) {
        guard isAlive else { return }
        // Only write to PTY — never local-echo (shell echoes)
        pty.write(text)
        lastActivity = .now
        trackDirectoryChange(from: text)
    }

    func sendLine(_ line: String) {
        // Prefer \r for interactive PTY (Enter key); shells expect CR
        let payload = line.hasSuffix("\r") || line.hasSuffix("\n") ? line : line + "\r"
        send(payload)
    }

    /// Inject a notice into the terminal buffer without executing (safety / system).
    func appendSafetyNotice(_ text: String) {
        appendPlain("\r\n\u{1b}[31m\(text)\u{1b}[0m\r\n", forcePublish: true)
    }

    /// Mirror agent tool activity into this real PTY pane (cyan, not executed as shell).
    func appendAgentEcho(_ text: String) {
        let body = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(80)
            .joined(separator: "\r\n")
        appendPlain("\r\n\u{1b}[36m\(body)\u{1b}[0m\r\n", forcePublish: true)
    }

    func resize(cols: Int, rows: Int) {
        pty.resize(cols: UInt16(max(20, cols)), rows: UInt16(max(5, rows)))
    }

    func terminate() {
        pty.terminate()
        isAlive = false
    }

    func clear() {
        emulator.reset()
        displayLines = [""]
        displayRevision &+= 1
        pendingBytes = Data()
        uiDirty = false
    }

    func changeDirectory(to path: String) {
        let resolved = (path as NSString).standardizingPath
        sendLine("cd \(shellQuote(resolved))")
        cwd = resolved
        projectName = URL(fileURLWithPath: resolved).lastPathComponent
        // Keep custom titles (user rename / · N); only auto-update generic project titles.
        if title == projectName || title.hasPrefix(projectName + " ·") || !title.contains("·") {
            // Leave numbered/custom names alone if they already diverge from folder name.
            if title == projectName || title.isEmpty {
                title = projectName
            }
        }
    }

    func findInBuffer(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        // Search lines without building a multi-MB join when possible.
        for (idx, line) in displayLines.enumerated() {
            if let r = line.range(of: q, options: .caseInsensitive) {
                let before = displayLines[max(0, idx - 1)..<idx].joined(separator: "\n")
                let afterStart = min(idx + 1, displayLines.count)
                let afterEnd = min(idx + 2, displayLines.count)
                let after = afterStart < afterEnd
                    ? displayLines[afterStart..<afterEnd].joined(separator: "\n")
                    : ""
                let hit = String(line[r])
                let ctxLeft = line[..<r.lowerBound].suffix(40)
                let ctxRight = line[r.upperBound...].prefix(80)
                var parts: [String] = []
                if !before.isEmpty { parts.append(String(before.suffix(40))) }
                parts.append("\(ctxLeft)\(hit)\(ctxRight)")
                if !after.isEmpty { parts.append(String(after.prefix(80))) }
                return parts.joined(separator: "\n")
            }
        }
        return nil
    }

    // MARK: - Private

    private func appendOutput(_ data: Data) {
        pendingBytes.append(data)
        // Decode as much UTF-8 as possible; keep incomplete tail
        if let full = String(data: pendingBytes, encoding: .utf8) {
            pendingBytes = Data()
            appendPlain(full)
            return
        }
        // Try shortening tail for incomplete multi-byte
        for drop in 1...3 {
            guard pendingBytes.count > drop else { break }
            let head = pendingBytes.prefix(pendingBytes.count - drop)
            if let s = String(data: head, encoding: .utf8) {
                pendingBytes = Data(pendingBytes.suffix(drop))
                appendPlain(s)
                return
            }
        }
        // Fallback latin1 for binary noise
        if pendingBytes.count > 4096 {
            let s = String(data: pendingBytes, encoding: .isoLatin1) ?? ""
            pendingBytes = Data()
            appendPlain(s)
        }
    }

    private func appendPlain(_ chunk: String, forcePublish: Bool = false) {
        let redacted = SecretRedactor.redact(chunk)
        emulator.feed(redacted)
        uiDirty = true
        lastActivity = .now
        if !redacted.isEmpty {
            onOutputText?(id, redacted)
        }
        if forcePublish {
            publishUI()
        } else {
            schedulePublish()
        }
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: publishInterval)
            self.publishScheduled = false
            if self.uiDirty {
                self.publishUI()
            }
        }
    }

    private func publishUI() {
        uiDirty = false
        // Assign lines array once per publish (virtualized UI reads this).
        displayLines = emulator.lines
        displayRevision &+= 1
    }

    private func trackDirectoryChange(from text: String) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n").union(.whitespaces))
        guard trimmed.hasPrefix("cd ") || trimmed == "cd" else { return }
        let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty || rest == "~" {
            cwd = NSHomeDirectory()
        } else if rest == "-" {
            return
        } else {
            let expanded = (rest as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                cwd = (expanded as NSString).standardizingPath
            } else {
                cwd = (cwd as NSString).appendingPathComponent(expanded)
                cwd = (cwd as NSString).standardizingPath
            }
        }
        let oldProject = projectName
        projectName = URL(fileURLWithPath: cwd).lastPathComponent
        // Only auto-rename when title still matched the previous folder (not a custom name).
        if title == oldProject || title.hasPrefix(oldProject + " ·") {
            title = projectName
        }
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - ANSI strip (legacy helper for copy / search on raw-ish strings)

enum ANSIParser {
    static func strip(_ input: String) -> String {
        var emu = TerminalEmulator()
        emu.feed(input)
        return emu.plainText
    }
}
