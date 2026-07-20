import Foundation
import Combine

// MARK: - Models

struct GitCommitEntry: Identifiable, Equatable {
    let id: String // hash
    var hash: String
    var shortHash: String
    var subject: String
    var author: String
    var relativeDate: String
    var dateISO: String
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { path + status }
    var path: String
    /// M, A, D, ??, R, etc.
    var status: String
    var staged: Bool
}

struct GitStatusSnapshot: Equatable {
    var isRepo: Bool
    var root: String?
    var branch: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var changes: [GitFileChange]
    var stagedCount: Int
    var unstagedCount: Int
    var untrackedCount: Int
    var lastError: String?
    /// True when repo exists but has zero commits (unborn HEAD).
    var isEmptyRepo: Bool
    /// Ignored paths with on-disk activity (e.g. zackgame `www/` is gitignored).
    var ignoredCount: Int
    /// Sample ignored paths for UI (max ~8).
    var ignoredSamples: [String]

    static let empty = GitStatusSnapshot(
        isRepo: false, root: nil, branch: nil, upstream: nil,
        ahead: 0, behind: 0, changes: [],
        stagedCount: 0, unstagedCount: 0, untrackedCount: 0,
        lastError: nil, isEmptyRepo: false,
        ignoredCount: 0, ignoredSamples: []
    )

    var summaryLine: String {
        guard isRepo else { return "Non è un repo git" }
        if isEmptyRepo { return "\(branch ?? "main") · repo vuoto (0 commit)" }
        var parts: [String] = []
        if let b = branch { parts.append(b) }
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        if stagedCount > 0 { parts.append("\(stagedCount) staged") }
        if unstagedCount > 0 { parts.append("\(unstagedCount) modified") }
        if untrackedCount > 0 { parts.append("\(untrackedCount) untracked") }
        if stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0 {
            // Match Desktop/CLI: primary signal is working tree clean
            parts.append("clean")
            if ignoredCount > 0 { parts.append("\(ignoredCount) gitignored") }
        } else if ignoredCount > 0 {
            parts.append("\(ignoredCount) gitignored")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Process runner (never blocks main)

enum GitRunner {
    struct Result: Sendable {
        var ok: Bool
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// Run git off the calling thread. Safe from any context. Hard timeout.
    nonisolated static func run(
        _ args: [String],
        in directory: String,
        extraEnv: [String: String] = [:],
        timeoutSeconds: TimeInterval = 12
    ) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        proc.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        // Never block on credential prompts / pager
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        env["GCM_INTERACTIVE"] = "never"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return Result(ok: false, stdout: "", stderr: error.localizedDescription, exitCode: -1, timedOut: false)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            proc.waitUntilExit()
            group.leave()
        }

        let wait = group.wait(timeout: .now() + timeoutSeconds)
        if wait == .timedOut {
            proc.terminate()
            // escalate
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning { proc.interrupt() }
            }
            return Result(
                ok: false,
                stdout: "",
                stderr: "Timeout git \(args.prefix(3).joined(separator: " ")) (\(Int(timeoutSeconds))s)",
                exitCode: -9,
                timedOut: true
            )
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(
            ok: proc.terminationStatus == 0,
            stdout: stdout,
            stderr: stderr,
            exitCode: proc.terminationStatus,
            timedOut: false
        )
    }

    nonisolated static func basicAuth(token: String) -> String {
        let raw = "x-access-token:\(token)"
        return Data(raw.utf8).base64EncodedString()
    }

    nonisolated static func findGitRoot(from path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        let fm = FileManager.default
        var hops = 0
        while hops < 40 {
            // .git can be file (worktree) or directory
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
            hops += 1
        }
        return nil
    }

    nonisolated static func loadSnapshot(path: String) -> (GitStatusSnapshot, [GitCommitEntry]) {
        guard let root = findGitRoot(from: path) else {
            return (.empty, [])
        }

        // Unborn HEAD (0 commits): rev-parse HEAD fails
        let head = run(["rev-parse", "--verify", "HEAD"], in: root, timeoutSeconds: 5)
        let isEmptyRepo = !head.ok

        var branch: String?
        let br = run(["rev-parse", "--abbrev-ref", "HEAD"], in: root, timeoutSeconds: 5)
        if br.ok {
            let b = br.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // unborn may report "HEAD"
            branch = (b == "HEAD" && isEmptyRepo) ? "main?" : b
        } else if isEmptyRepo {
            // symbolic-ref for unborn
            let sym = run(["symbolic-ref", "--short", "HEAD"], in: root, timeoutSeconds: 3)
            branch = sym.ok
                ? sym.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : "main"
        }

        // --untracked-files=normal but cap: status can hang on huge trees; timeout protects UI
        let st = run(["status", "--porcelain=1", "-b", "--untracked-files=normal"], in: root, timeoutSeconds: 10)
        var changes: [GitFileChange] = []
        var ahead = 0
        var behind = 0
        var upstream: String?
        var staged = 0
        var unstaged = 0
        var untracked = 0

        if !st.timedOut {
            for line in st.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix("##") {
                    let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if let range = body.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) {
                        let bracket = String(body[range])
                        if let a = bracket.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                            ahead = bracket[a].split(separator: " ").last.flatMap { Int($0) } ?? 0
                        }
                        if let b = bracket.range(of: #"behind (\d+)"#, options: .regularExpression) {
                            behind = bracket[b].split(separator: " ").last.flatMap { Int($0) } ?? 0
                        }
                    }
                    if let dots = body.range(of: "...") {
                        let after = body[dots.upperBound...]
                        upstream = after.split(separator: " ").first.map(String.init)
                    }
                    continue
                }
                guard line.count >= 3 else { continue }
                let xy = String(line.prefix(2))
                let pathPart = String(line.dropFirst(3))
                let filePath = pathPart.contains(" -> ")
                    ? (pathPart.components(separatedBy: " -> ").last ?? pathPart)
                    : pathPart
                let x = xy[xy.startIndex]
                let y = xy[xy.index(after: xy.startIndex)]
                if xy == "??" {
                    changes.append(GitFileChange(path: filePath, status: "??", staged: false))
                    untracked += 1
                } else {
                    if x != " " && x != "?" {
                        changes.append(GitFileChange(path: filePath, status: String(x), staged: true))
                        staged += 1
                    }
                    if y != " " && y != "?" {
                        changes.append(GitFileChange(path: filePath, status: String(y), staged: false))
                        unstaged += 1
                    }
                }
            }
        }

        // Cap listed changes for UI
        if changes.count > 200 {
            changes = Array(changes.prefix(200))
        }

        var err: String?
        if st.timedOut {
            err = st.stderr
        } else if !st.ok && !isEmptyRepo {
            err = st.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err?.isEmpty == true { err = nil }
        }

        // Agent patches often land in gitignored dirs (e.g. Capacitor `www/`).
        var ignoredCount = 0
        var ignoredSamples: [String] = []
        let ign = run(
            ["status", "--porcelain=1", "--ignored=matching", "--untracked-files=normal"],
            in: root,
            timeoutSeconds: 8
        )
        if ign.ok || !ign.stdout.isEmpty {
            for line in ign.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                guard line.hasPrefix("!! ") else { continue }
                let p = String(line.dropFirst(3))
                // Skip noisy trees
                let skipPrefixes = [
                    "node_modules/", "Pods/", ".git/", "android/.gradle/", "android/build/",
                    "android/app/build/", ".vexp/",
                ]
                if skipPrefixes.contains(where: { p.hasPrefix($0) || p == String($0.dropLast()) }) { continue }
                if p == "node_modules/" || p == "Pods/" { continue }
                ignoredCount += 1
                if ignoredSamples.count < 8 { ignoredSamples.append(p) }
            }
        }

        let snap = GitStatusSnapshot(
            isRepo: true,
            root: root,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            changes: changes,
            stagedCount: staged,
            unstagedCount: unstaged,
            untrackedCount: untracked,
            lastError: err,
            isEmptyRepo: isEmptyRepo,
            ignoredCount: ignoredCount,
            ignoredSamples: ignoredSamples
        )

        var log: [GitCommitEntry] = []
        if !isEmptyRepo {
            let fmt = "%H|%h|%s|%an|%ar|%aI"
            let r = run(
                ["log", "-n", "40", "--pretty=format:\(fmt)"],
                in: root,
                timeoutSeconds: 8
            )
            if r.ok {
                log = r.stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
                    let parts = String(line).components(separatedBy: "|")
                    guard parts.count >= 6 else { return nil }
                    return GitCommitEntry(
                        id: parts[0],
                        hash: parts[0],
                        shortHash: parts[1],
                        subject: parts[2],
                        author: parts[3],
                        relativeDate: parts[4],
                        dateISO: parts[5]
                    )
                }
            }
        }

        return (snap, log)
    }
}

// MARK: - Service (UI-facing, MainActor — work offloaded)

/// Local git + optional GitHub push. Git never blocks the main thread.
@MainActor
final class GitService: ObservableObject {
    static let githubKeychainAccount = "GitHub"

    @Published var status: GitStatusSnapshot = .empty
    @Published var log: [GitCommitEntry] = []
    @Published var isBusy: Bool = false
    @Published var lastMessage: String?
    @Published var lastError: String?
    @Published var workingPath: String?
    /// Selected file path for inline diff (relative to repo).
    @Published var selectedDiffPath: String?
    @Published var selectedDiffText: String = ""
    @Published var selectedDiffStaged: Bool = false

    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    var hasGitHubToken: Bool {
        guard let t = KeychainStore.get(Self.githubKeychainAccount) else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Refresh (async)

    func setPath(_ path: String?) {
        // Never bind Git to bare $HOME — agents/terminals sometimes cwd there by mistake.
        let normalized: String? = {
            guard let path else { return nil }
            let std = (path as NSString).standardizingPath
            let home = (NSHomeDirectory() as NSString).standardizingPath
            if std == home { return nil }
            return std
        }()
        let changed = workingPath != normalized
        workingPath = normalized
        // Drop stale status immediately so the panel never looks stuck on the previous project.
        if changed {
            status = .empty
            log = []
            lastMessage = nil
            lastError = nil
            refresh()
        }
        // Same path → no refresh (was causing Commit button flicker + 90%+ CPU)
    }

    /// Soft refresh after agent writes — debounced so patch storms don't spam `git status`.
    private var notifyDebounce: Task<Void, Never>?
    private var lastRefreshAt: Date = .distantPast
    /// Minimum gap between automatic refreshes (UI stays usable for Commit).
    private let minRefreshGap: TimeInterval = 2.5

    func notifyWorkingTreeMaybeChanged() {
        notifyDebounce?.cancel()
        notifyDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refresh(force: false)
        }
    }

    /// Non-blocking refresh. Safe to call from onAppear / button.
    func refresh(force: Bool = true) {
        guard let path = workingPath, !path.isEmpty else {
            status = .empty
            log = []
            isBusy = false
            return
        }

        // Throttle background refreshes — force=true for user Commit/Refresh clicks
        if !force, Date().timeIntervalSince(lastRefreshAt) < minRefreshGap {
            return
        }
        lastRefreshAt = .now

        refreshGeneration &+= 1
        let gen = refreshGeneration
        refreshTask?.cancel()
        isBusy = true
        lastError = nil

        refreshTask = Task { [weak self] in
            let pathCopy = path
            let pair = await Task.detached(priority: .userInitiated) {
                GitRunner.loadSnapshot(path: pathCopy)
            }.value

            guard let self, !Task.isCancelled, self.refreshGeneration == gen else { return }

            self.status = pair.0
            self.log = pair.1
            self.isBusy = false
            if let err = pair.0.lastError, !err.isEmpty {
                self.lastError = err
            }
            if pair.0.isEmptyRepo {
                self.lastMessage = "Repo senza commit — changelog vuoto è normale"
            }
        }
    }

    func refreshAsync() { refresh() }

    // MARK: - Actions (async wrappers)

    /// Stage working tree. `includeIgnored` uses `git add -A --force` (BUG-011 — www/ e file gitignored).
    func stageAll(includeIgnored: Bool = false) {
        runAction(timeout: includeIgnored ? 60 : 30) { root in
            var args = ["add", "-A"]
            if includeIgnored { args.append("--force") }
            let r = GitRunner.run(args, in: root, timeoutSeconds: includeIgnored ? 60 : 30)
            let msg = includeIgnored
                ? "Stage All (+ ignored/forzati)"
                : "Tutti i file tracked in stage"
            return (r.ok, r.ok ? msg : (r.stderr.isEmpty ? r.stdout : r.stderr))
        }
    }

    /// Stage a single path (VS Code + style).
    func stage(path: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        runAction(timeout: 20) { root in
            let r = GitRunner.run(["add", "--", p], in: root, timeoutSeconds: 20)
            return (r.ok, r.ok ? "Staged \(p)" : (r.stderr.isEmpty ? r.stdout : r.stderr))
        }
    }

    /// Unstage path (keep working tree changes).
    func unstage(path: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        runAction(timeout: 20) { root in
            // Works on modern git; fallback for older
            var r = GitRunner.run(["restore", "--staged", "--", p], in: root, timeoutSeconds: 15)
            if !r.ok {
                r = GitRunner.run(["reset", "HEAD", "--", p], in: root, timeoutSeconds: 15)
            }
            return (r.ok, r.ok ? "Unstaged \(p)" : (r.stderr.isEmpty ? r.stdout : r.stderr))
        }
    }

    func unstageAll() {
        runAction(timeout: 20) { root in
            var r = GitRunner.run(["restore", "--staged", "."], in: root, timeoutSeconds: 15)
            if !r.ok {
                r = GitRunner.run(["reset", "HEAD"], in: root, timeoutSeconds: 15)
            }
            return (r.ok, r.ok ? "Tutto unstaged" : (r.stderr.isEmpty ? r.stdout : r.stderr))
        }
    }

    /// Discard unstaged changes to a file (dangerous — working tree only).
    func discard(path: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        runAction(timeout: 20) { root in
            // Untracked: remove; tracked: checkout
            let st = GitRunner.run(["status", "--porcelain=1", "--", p], in: root, timeoutSeconds: 8)
            let line = st.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("??") {
                let r = GitRunner.run(["clean", "-f", "--", p], in: root, timeoutSeconds: 15)
                return (r.ok, r.ok ? "Rimosso untracked \(p)" : r.stderr)
            }
            var r = GitRunner.run(["restore", "--worktree", "--", p], in: root, timeoutSeconds: 15)
            if !r.ok {
                r = GitRunner.run(["checkout", "--", p], in: root, timeoutSeconds: 15)
            }
            return (r.ok, r.ok ? "Discard \(p)" : (r.stderr.isEmpty ? r.stdout : r.stderr))
        }
    }

    /// Load unified diff for a path (staged or unstaged).
    func loadDiff(path: String, staged: Bool, maxChars: Int = 12_000) {
        selectedDiffPath = path
        selectedDiffStaged = staged
        selectedDiffText = "Caricamento…"
        guard let root = resolveRoot() else {
            selectedDiffText = "Nessun repo"
            return
        }
        let p = path
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                let args: [String]
                if staged {
                    args = ["diff", "--cached", "--", p]
                } else {
                    // Untracked: show as /dev/null
                    let st = GitRunner.run(["status", "--porcelain=1", "--", p], in: root, timeoutSeconds: 5)
                    if st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("??") {
                        let cat = GitRunner.run(["show", ":\(p)"], in: root, timeoutSeconds: 3)
                        _ = cat
                        // For untracked, use diff against empty
                        let r = GitRunner.run(
                            ["diff", "--no-index", "/dev/null", p],
                            in: root,
                            timeoutSeconds: 10
                        )
                        // git diff --no-index returns 1 when different
                        let out = r.stdout.isEmpty ? r.stderr : r.stdout
                        return out.isEmpty ? "(file untracked — apri nel workspace)" : out
                    }
                    args = ["diff", "--", p]
                }
                let r = GitRunner.run(args, in: root, timeoutSeconds: 12)
                var out = r.stdout
                if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out = r.stderr
                }
                if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return staged ? "(nessun diff staged)" : "(nessun diff unstaged — file forse solo staged o binario)"
                }
                if out.count > maxChars {
                    return String(out.prefix(maxChars)) + "\n… [troncato]"
                }
                return out
            }.value
            await MainActor.run {
                guard let self, self.selectedDiffPath == p else { return }
                self.selectedDiffText = text
            }
        }
    }

    func clearDiff() {
        selectedDiffPath = nil
        selectedDiffText = ""
    }

    /// Staged vs unstaged lists for UI tree.
    var stagedChanges: [GitFileChange] {
        status.changes.filter(\.staged)
    }

    var unstagedChanges: [GitFileChange] {
        // porcelain can list same path twice (staged + unstaged); keep non-staged rows
        status.changes.filter { !$0.staged }
    }

    func commit(message: String) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            lastError = "Messaggio di commit vuoto"
            return
        }
        let needStage = status.stagedCount == 0
        runAction(timeout: 45) { root in
            if needStage {
                _ = GitRunner.run(["add", "-A"], in: root, timeoutSeconds: 30)
            }
            let r = GitRunner.run(["commit", "-m", msg], in: root, timeoutSeconds: 30)
            let err = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            // Include absolute repo path so user can match GitHub Desktop folder
            return (r.ok, r.ok ? "Commit creato · repo `\(root)` — apri questa cartella in GitHub Desktop" : (err.isEmpty ? "Commit fallito" : err))
        }
    }

    func commitAndPush(message: String) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            lastError = "Messaggio di commit vuoto"
            return
        }
        let needStage = status.stagedCount == 0
        let token = KeychainStore.get(Self.githubKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        runAction(timeout: 90) { root in
            if needStage {
                _ = GitRunner.run(["add", "-A"], in: root, timeoutSeconds: 30)
            }
            let c = GitRunner.run(["commit", "-m", msg], in: root, timeoutSeconds: 30)
            if !c.ok {
                let err = (c.stderr.isEmpty ? c.stdout : c.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, err.isEmpty ? "Commit fallito" : err)
            }
            var env: [String: String] = [:]
            if let token, !token.isEmpty {
                env["GIT_CONFIG_COUNT"] = "1"
                env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(GitRunner.basicAuth(token: token))"
            }
            var r = GitRunner.run(["push", "-u", "origin", "HEAD"], in: root, extraEnv: env, timeoutSeconds: 60)
            if !r.ok {
                r = GitRunner.run(["push"], in: root, extraEnv: env, timeoutSeconds: 60)
            }
            if r.ok { return (true, "Commit + push OK") }
            let err = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, err.isEmpty ? "Push fallito" : err)
        }
    }

    func push() {
        let token = KeychainStore.get(Self.githubKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        runAction(timeout: 90) { root in
            var env: [String: String] = [:]
            if let token, !token.isEmpty {
                env["GIT_CONFIG_COUNT"] = "1"
                env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(GitRunner.basicAuth(token: token))"
            }
            var r = GitRunner.run(["push", "-u", "origin", "HEAD"], in: root, extraEnv: env, timeoutSeconds: 60)
            if !r.ok {
                r = GitRunner.run(["push"], in: root, extraEnv: env, timeoutSeconds: 60)
            }
            if r.ok { return (true, "Push su origin completato") }
            let err = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, err.isEmpty ? "Push fallito" : err)
        }
    }

    func pull() {
        let token = KeychainStore.get(Self.githubKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        runAction(timeout: 90) { root in
            var env: [String: String] = [:]
            if let token, !token.isEmpty {
                env["GIT_CONFIG_COUNT"] = "1"
                env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(GitRunner.basicAuth(token: token))"
            }
            let r = GitRunner.run(["pull", "--rebase", "--autostash"], in: root, extraEnv: env, timeoutSeconds: 60)
            if r.ok { return (true, "Pull completato") }
            let err = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, err.isEmpty ? "Pull fallito" : err)
        }
    }

    /// Sync helpers for orchestrator/agent (work off main; waits with timeout).
    func commitSync(message: String) -> Bool {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { lastError = "Messaggio di commit vuoto"; return false }
        guard let root = resolveRoot() else { lastError = "Nessun repo git"; return false }
        let needStage = status.stagedCount == 0
        return runSyncOnBackground(root: root) {
            if needStage { _ = GitRunner.run(["add", "-A"], in: root, timeoutSeconds: 30) }
            return GitRunner.run(["commit", "-m", msg], in: root, timeoutSeconds: 30).ok
        }
    }

    func commitAndPushSync(message: String) -> Bool {
        guard commitSync(message: message) else { return false }
        return pushSync()
    }

    func pushSync() -> Bool {
        guard let root = resolveRoot() else { lastError = "Nessun repo git"; return false }
        let token = KeychainStore.get(Self.githubKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return runSyncOnBackground(root: root) {
            var env: [String: String] = [:]
            if let token, !token.isEmpty {
                env["GIT_CONFIG_COUNT"] = "1"
                env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(GitRunner.basicAuth(token: token))"
            }
            var r = GitRunner.run(["push", "-u", "origin", "HEAD"], in: root, extraEnv: env, timeoutSeconds: 60)
            if !r.ok { r = GitRunner.run(["push"], in: root, extraEnv: env, timeoutSeconds: 60) }
            return r.ok
        }
    }

    func pullSync() -> Bool {
        guard let root = resolveRoot() else { lastError = "Nessun repo git"; return false }
        let token = KeychainStore.get(Self.githubKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return runSyncOnBackground(root: root) {
            var env: [String: String] = [:]
            if let token, !token.isEmpty {
                env["GIT_CONFIG_COUNT"] = "1"
                env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(GitRunner.basicAuth(token: token))"
            }
            return GitRunner.run(["pull", "--rebase", "--autostash"], in: root, extraEnv: env, timeoutSeconds: 60).ok
        }
    }

    func diffSummary(maxChars: Int = 4000) -> String {
        guard let root = resolveRoot() else { return "Nessun repo" }
        let staged = GitRunner.run(["diff", "--cached", "--stat"], in: root, timeoutSeconds: 8).stdout
        let unstaged = GitRunner.run(["diff", "--stat"], in: root, timeoutSeconds: 8).stdout
        var parts: [String] = []
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("**Staged**\n```\n\(staged.trimmingCharacters(in: .whitespacesAndNewlines))\n```")
        }
        if !unstaged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("**Unstaged**\n```\n\(unstaged.trimmingCharacters(in: .whitespacesAndNewlines))\n```")
        }
        if parts.isEmpty {
            return status.isEmptyRepo ? "_Repo vuoto (nessun commit)_" : "_Working tree clean_"
        }
        var out = parts.joined(separator: "\n\n")
        if out.count > maxChars { out = String(out.prefix(maxChars)) + "\n…" }
        return out
    }

    func changelogMarkdown(limit: Int = 20) -> String {
        if status.isEmptyRepo {
            return "_Nessun commit ancora (repo appena inizializzato)_"
        }
        guard !log.isEmpty else {
            return status.isRepo ? "_Nessun commit_" : "_Non è un repository git_"
        }
        let lines = log.prefix(limit).map { c in
            "• `\(c.shortHash)` **\(c.subject)** — \(c.author) · \(c.relativeDate)"
        }
        let branch = status.branch.map { " (\($0))" } ?? ""
        return "**Changelog\(branch)**\n" + lines.joined(separator: "\n")
    }

    func findGitRoot(from path: String) -> String? {
        GitRunner.findGitRoot(from: path)
    }

    /// Compatibility for older call sites that used runGit on main.
    @discardableResult
    func runGit(
        _ args: [String],
        in directory: String,
        extraEnv: [String: String] = [:]
    ) -> GitRunner.Result {
        GitRunner.run(args, in: directory, extraEnv: extraEnv, timeoutSeconds: 15)
    }

    // MARK: - Private

    private func resolveRoot() -> String? {
        if let r = status.root { return r }
        if let p = workingPath { return GitRunner.findGitRoot(from: p) }
        return nil
    }

    private func runAction(timeout: TimeInterval, work: @escaping @Sendable (String) -> (Bool, String)) {
        guard let root = resolveRoot() else {
            lastError = "Nessun repo git"
            return
        }
        actionTask?.cancel()
        isBusy = true
        lastError = nil
        lastMessage = nil
        actionTask = Task { [weak self] in
            let rootCopy = root
            let result = await Task.detached(priority: .userInitiated) {
                work(rootCopy)
            }.value
            guard let self, !Task.isCancelled else { return }
            if result.0 {
                self.lastMessage = result.1
                self.lastError = nil
            } else {
                self.lastError = result.1
            }
            self.isBusy = false
            self.refresh()
        }
    }

    /// For orchestrator tools that still want a Bool return (may wait, but off main via semaphore carefully).
    private func runSyncOnBackground(root: String, work: @escaping @Sendable () -> Bool) -> Bool {
        // If already off main, just run
        if !Thread.isMainThread {
            let ok = work()
            if ok { lastMessage = "OK"; lastError = nil } else { lastError = lastError ?? "Operazione fallita" }
            refresh()
            return ok
        }
        isBusy = true
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ok = work()
            sem.signal()
        }
        // Wait with timeout so we never beachball forever
        let wait = sem.wait(timeout: .now() + 70)
        isBusy = false
        if wait == .timedOut {
            lastError = "Timeout operazione git"
            return false
        }
        if ok {
            lastMessage = "OK"
            lastError = nil
        }
        refresh()
        return ok
    }

}
