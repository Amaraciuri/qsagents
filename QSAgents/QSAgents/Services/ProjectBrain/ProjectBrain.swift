import Foundation

// MARK: - Snapshot (A1)

enum DetectedStack: String, Codable, Equatable {
    case rust
    case next
    case node
    case python
    case go
    case swift
    case java
    case ruby
    case elixir
    case unknown

    var label: String {
        switch self {
        case .rust: return "Rust / Cargo"
        case .next: return "Next.js"
        case .node: return "Node.js"
        case .python: return "Python"
        case .go: return "Go"
        case .swift: return "Swift / SPM"
        case .java: return "Java"
        case .ruby: return "Ruby"
        case .elixir: return "Elixir"
        case .unknown: return "sconosciuto"
        }
    }
}

enum PackageManagerKind: String, Codable, Equatable {
    case npm, pnpm, yarn, bun, cargo, pip, poetry, go, spm, maven, gradle, bundler, mix
}

/// One-shot project intelligence: git + manifests + README (no LLM).
struct ProjectBrainSnapshot: Equatable {
    var path: String
    var name: String
    var isRepo: Bool
    var isEmptyRepo: Bool
    var branch: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var isDirty: Bool
    var stagedCount: Int
    var unstagedCount: Int
    var untrackedCount: Int
    var dirtyPaths: [String]
    var recentCommits: [GitCommitEntry]
    var packageManagers: [PackageManagerKind]
    var stack: DetectedStack
    var hasReadme: Bool
    var readmeHeadline: String?
    var hasEnvExample: Bool
    var hasEnvFile: Bool
    var hasInstallDir: Bool
    var rootEntries: [String]
    var refreshedAt: Date

    var summaryLine: String {
        var parts: [String] = [name, stack.label]
        if isRepo {
            if let b = branch { parts.append(b) }
            parts.append(isDirty ? "dirty" : "clean")
            if ahead > 0 { parts.append("↑\(ahead)") }
            if behind > 0 { parts.append("↓\(behind)") }
        } else {
            parts.append("no-git")
        }
        if !packageManagers.isEmpty {
            parts.append(packageManagers.map(\.rawValue).joined(separator: "+"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Concrete plan item with provenance (A2 + A3).
struct SuggestedTask: Equatable {
    var title: String
    var subtitle: String?
    var priority: TaskPriority
    var source: TaskSource
    var evidence: [String]
}

// MARK: - ProjectBrain

enum ProjectBrain {
    /// Scan workspace: git snapshot + package managers + README + root layout.
    nonisolated static func refresh(path: String) -> ProjectBrainSnapshot {
        let root = (path as NSString).standardizingPath
        let name = URL(fileURLWithPath: root).lastPathComponent
        let fm = FileManager.default

        let (gitSnap, log) = GitRunner.loadSnapshot(path: root)
        let dirtyPaths = Array(gitSnap.changes.prefix(12).map(\.path))
        let isDirty = gitSnap.stagedCount + gitSnap.unstagedCount + gitSnap.untrackedCount > 0

        let rootEntries = listRootEntries(root: root, fm: fm)
        let (pms, stack) = detectStack(root: root, entries: rootEntries, fm: fm)
        let (hasReadme, headline) = readReadme(root: root, fm: fm)
        let hasEnvExample = fm.fileExists(atPath: root + "/.env.example")
            || fm.fileExists(atPath: root + "/.env.sample")
        let hasEnvFile = fm.fileExists(atPath: root + "/.env")
        let hasInstallDir = detectInstallDir(root: root, pms: pms, fm: fm)

        return ProjectBrainSnapshot(
            path: root,
            name: name,
            isRepo: gitSnap.isRepo,
            isEmptyRepo: gitSnap.isEmptyRepo,
            branch: gitSnap.branch,
            upstream: gitSnap.upstream,
            ahead: gitSnap.ahead,
            behind: gitSnap.behind,
            isDirty: isDirty,
            stagedCount: gitSnap.stagedCount,
            unstagedCount: gitSnap.unstagedCount,
            untrackedCount: gitSnap.untrackedCount,
            dirtyPaths: dirtyPaths,
            recentCommits: Array(log.prefix(12)),
            packageManagers: pms,
            stack: stack,
            hasReadme: hasReadme,
            readmeHeadline: headline,
            hasEnvExample: hasEnvExample,
            hasEnvFile: hasEnvFile,
            hasInstallDir: hasInstallDir,
            rootEntries: rootEntries,
            refreshedAt: Date()
        )
    }

    /// Build concrete tasks from snapshot (git log + status + manifest). No fixed 7-step template.
    nonisolated static func suggestTasks(from snap: ProjectBrainSnapshot) -> [SuggestedTask] {
        var out: [SuggestedTask] = []
        let name = snap.name

        // --- Git hygiene (status evidence) ---
        if snap.isRepo && snap.isEmptyRepo {
            out.append(SuggestedTask(
                title: "[\(name)] Primo commit baseline",
                subtitle: "Repo senza commit — crea .gitignore e commit iniziale",
                priority: .alto,
                source: .gitStatus,
                evidence: ["git: empty repo", "branch: \(snap.branch ?? "?")"]
            ))
        }

        if snap.isRepo && snap.behind > 0 {
            out.append(SuggestedTask(
                title: "[\(name)] Pull upstream (↓\(snap.behind))",
                subtitle: "Allinea branch con remote prima di lavorare",
                priority: .critico,
                source: .gitStatus,
                evidence: [
                    "branch: \(snap.branch ?? "?")",
                    "behind: \(snap.behind)",
                    snap.upstream.map { "upstream: \($0)" } ?? "upstream: —",
                ]
            ))
        }

        if snap.isDirty {
            let files = snap.dirtyPaths.prefix(5).joined(separator: ", ")
            let counts = "\(snap.stagedCount) staged · \(snap.unstagedCount) mod · \(snap.untrackedCount) untracked"
            out.append(SuggestedTask(
                title: "[\(name)] Rivedi e committa working tree",
                subtitle: counts + (files.isEmpty ? "" : " — \(files)"),
                priority: snap.stagedCount > 0 ? .alto : .medio,
                source: .gitStatus,
                evidence: (["status: dirty", counts] + snap.dirtyPaths.prefix(8).map { "file: \($0)" })
            ))
        }

        if snap.isRepo && snap.ahead > 0 && !snap.isDirty {
            out.append(SuggestedTask(
                title: "[\(name)] Push branch (↑\(snap.ahead))",
                subtitle: "Commit locali non ancora sul remote",
                priority: .medio,
                source: .gitStatus,
                evidence: ["ahead: \(snap.ahead)", "branch: \(snap.branch ?? "?")"]
            ))
        }

        // --- Recent commits → follow-ups ---
        for task in tasksFromCommits(snap: snap) {
            if out.count >= 10 { break }
            out.append(task)
        }

        // --- Manifest / stack-specific ---
        for task in tasksFromStack(snap: snap) {
            if out.count >= 10 { break }
            out.append(task)
        }

        // --- Env ---
        if snap.hasEnvExample && !snap.hasEnvFile {
            out.append(SuggestedTask(
                title: "[\(name)] Configura .env da .env.example",
                subtitle: "Secrets / env locali mancanti",
                priority: .alto,
                source: .manifest,
                evidence: [".env.example presente", ".env assente"]
            ))
        }

        // --- README orientation ---
        if snap.hasReadme, let head = snap.readmeHeadline, !head.isEmpty {
            // Only if we still have room and nothing more urgent dominates
            if out.count < 6 {
                out.append(SuggestedTask(
                    title: "[\(name)] Allinea backlog al README",
                    subtitle: String(head.prefix(120)),
                    priority: .medio,
                    source: .repoSnapshot,
                    evidence: ["README: \(String(head.prefix(80)))"]
                ))
            }
        } else if !snap.hasReadme && out.count < 5 {
            out.append(SuggestedTask(
                title: "[\(name)] Scrivi README minimo",
                subtitle: "Nessun README in root — documenta setup e comandi",
                priority: .medio,
                source: .repoSnapshot,
                evidence: ["README assente", "root: \(snap.rootEntries.prefix(8).joined(separator: ", "))"]
            ))
        }

        // --- Fallback: light bootstrap only if almost empty signal ---
        if out.isEmpty {
            out = fallbackTemplate(name: name, snap: snap)
        }

        // Cap & de-dupe by title
        var seen = Set<String>()
        var unique: [SuggestedTask] = []
        for t in out {
            let key = t.title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(t)
            if unique.count >= 8 { break }
        }
        return unique
    }

    // MARK: - Private helpers

    nonisolated private static func listRootEntries(root: String, fm: FileManager) -> [String] {
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") || $0 == ".env.example" || $0 == ".env" }
            .sorted()
            .prefix(40)
            .map { $0 }
    }

    nonisolated private static func detectStack(
        root: String,
        entries: [String],
        fm: FileManager
    ) -> ([PackageManagerKind], DetectedStack) {
        var pms: [PackageManagerKind] = []
        var stack: DetectedStack = .unknown
        let set = Set(entries.map { $0.lowercased() })

        if set.contains("cargo.toml") {
            pms.append(.cargo)
            stack = .rust
        }
        if set.contains("package.json") {
            if fm.fileExists(atPath: root + "/pnpm-lock.yaml") { pms.append(.pnpm) }
            else if fm.fileExists(atPath: root + "/yarn.lock") { pms.append(.yarn) }
            else if fm.fileExists(atPath: root + "/bun.lockb") || fm.fileExists(atPath: root + "/bun.lock") {
                pms.append(.bun)
            } else {
                pms.append(.npm)
            }
            if isNextProject(root: root, fm: fm) {
                stack = .next
            } else if stack == .unknown {
                stack = .node
            }
        }
        if set.contains("go.mod") {
            pms.append(.go)
            if stack == .unknown { stack = .go }
        }
        if set.contains("package.swift") {
            pms.append(.spm)
            if stack == .unknown { stack = .swift }
        }
        if set.contains("pyproject.toml") {
            pms.append(.poetry)
            if stack == .unknown { stack = .python }
        } else if set.contains("requirements.txt") {
            pms.append(.pip)
            if stack == .unknown { stack = .python }
        }
        if set.contains("pom.xml") {
            pms.append(.maven)
            if stack == .unknown { stack = .java }
        }
        if set.contains("build.gradle") || set.contains("build.gradle.kts") {
            pms.append(.gradle)
            if stack == .unknown { stack = .java }
        }
        if set.contains("gemfile") {
            pms.append(.bundler)
            if stack == .unknown { stack = .ruby }
        }
        if set.contains("mix.exs") {
            pms.append(.mix)
            if stack == .unknown { stack = .elixir }
        }

        return (pms, stack)
    }

    nonisolated private static func isNextProject(root: String, fm: FileManager) -> Bool {
        let pkgPath = root + "/package.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
              let text = String(data: data, encoding: .utf8)?.lowercased()
        else { return false }
        if text.contains("\"next\"") || text.contains("'next'") { return true }
        if fm.fileExists(atPath: root + "/next.config.js")
            || fm.fileExists(atPath: root + "/next.config.mjs")
            || fm.fileExists(atPath: root + "/next.config.ts") {
            return true
        }
        return false
    }

    nonisolated private static func detectInstallDir(
        root: String,
        pms: [PackageManagerKind],
        fm: FileManager
    ) -> Bool {
        for pm in pms {
            switch pm {
            case .npm, .pnpm, .yarn, .bun:
                if fm.fileExists(atPath: root + "/node_modules") { return true }
            case .cargo:
                if fm.fileExists(atPath: root + "/target") { return true }
            case .go:
                // modules cache is global; treat go.mod alone as "ok"
                return true
            case .pip, .poetry:
                if fm.fileExists(atPath: root + "/.venv")
                    || fm.fileExists(atPath: root + "/venv") {
                    return true
                }
            case .spm:
                if fm.fileExists(atPath: root + "/.build") { return true }
            case .maven:
                if fm.fileExists(atPath: root + "/target") { return true }
            case .gradle:
                if fm.fileExists(atPath: root + "/build") { return true }
            case .bundler:
                if fm.fileExists(atPath: root + "/vendor/bundle") { return true }
            case .mix:
                if fm.fileExists(atPath: root + "/_build") { return true }
            }
        }
        return pms.isEmpty
    }

    nonisolated private static func readReadme(root: String, fm: FileManager) -> (Bool, String?) {
        let candidates = ["README.md", "README.MD", "Readme.md", "README", "README.txt"]
        for name in candidates {
            let p = root + "/" + name
            guard fm.fileExists(atPath: p),
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: p))
            else { continue }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: 2048)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("![") && !$0.hasPrefix("[!") }
            let head = lines.prefix(2).joined(separator: " ")
            return (true, head.isEmpty ? String(text.prefix(100)) : head)
        }
        return (false, nil)
    }

    nonisolated private static func tasksFromCommits(snap: ProjectBrainSnapshot) -> [SuggestedTask] {
        guard !snap.recentCommits.isEmpty else { return [] }
        var tasks: [SuggestedTask] = []
        let subjects = snap.recentCommits.map(\.subject)
        let joined = subjects.joined(separator: "\n").lowercased()

        // Hot areas from commit messages
        let keywords: [(String, String, TaskPriority)] = [
            ("auth", "Verifica flusso auth / login", .alto),
            ("security", "Review security recente", .critico),
            ("fix", "Valida fix recenti con test", .alto),
            ("wip", "Chiudi WIP aperti nei commit", .alto),
            ("todo", "Smaltisci TODO lasciati nei commit", .medio),
            ("refactor", "Smoke test post-refactor", .medio),
            ("api", "Smoke test endpoint API toccati", .alto),
            ("ui", "Check UI / regressioni visuali", .medio),
            ("migrat", "Verifica migration DB", .alto),
            ("test", "Esegui suite test aggiornata", .medio),
        ]

        var hit = Set<String>()
        for (kw, title, prio) in keywords {
            guard joined.contains(kw), !hit.contains(kw) else { continue }
            hit.insert(kw)
            let matching = snap.recentCommits
                .filter { $0.subject.lowercased().contains(kw) }
                .prefix(3)
            let evidence = matching.map { "commit \($0.shortHash): \($0.subject)" }
            tasks.append(SuggestedTask(
                title: "[\(snap.name)] \(title)",
                subtitle: matching.first.map { "da \($0.shortHash): \($0.subject)" },
                priority: prio,
                source: .gitLog,
                evidence: evidence.isEmpty ? ["git log recente menziona «\(kw)»"] : Array(evidence)
            ))
            if tasks.count >= 3 { break }
        }

        // Always surface “what changed” if we have log and few other tasks
        if tasks.isEmpty, let top = snap.recentCommits.first {
            let list = snap.recentCommits.prefix(5).map { "\($0.shortHash) \($0.subject)" }
            tasks.append(SuggestedTask(
                title: "[\(snap.name)] Rivedi ultimi commit e priorità",
                subtitle: "\(top.shortHash): \(top.subject)",
                priority: .medio,
                source: .gitLog,
                evidence: list
            ))
        }
        return tasks
    }

    nonisolated private static func tasksFromStack(snap: ProjectBrainSnapshot) -> [SuggestedTask] {
        var tasks: [SuggestedTask] = []
        let name = snap.name
        let pmEvidence = snap.packageManagers.map { "pm: \($0.rawValue)" }

        switch snap.stack {
        case .rust:
            if !snap.hasInstallDir {
                tasks.append(SuggestedTask(
                    title: "[\(name)] cargo fetch / build iniziale",
                    subtitle: "Target assente — scarica deps e compila",
                    priority: .alto,
                    source: .manifest,
                    evidence: ["Cargo.toml", "target/ assente"] + pmEvidence
                ))
            }
            tasks.append(SuggestedTask(
                title: "[\(name)] cargo check + cargo test",
                subtitle: "Smoke test nativo Rust del workspace",
                priority: .alto,
                source: .manifest,
                evidence: ["stack: Rust/Cargo", "Cargo.toml"] + pmEvidence
            ))
            if snap.rootEntries.contains(where: { $0.lowercased() == "clippy.toml" })
                || snap.recentCommits.contains(where: { $0.subject.lowercased().contains("lint") }) {
                tasks.append(SuggestedTask(
                    title: "[\(name)] cargo clippy",
                    subtitle: "Lint statico del crate",
                    priority: .medio,
                    source: .manifest,
                    evidence: ["stack: Rust"]
                ))
            }

        case .next:
            if !snap.hasInstallDir {
                let install = snap.packageManagers.contains(.pnpm) ? "pnpm install"
                    : snap.packageManagers.contains(.yarn) ? "yarn"
                    : snap.packageManagers.contains(.bun) ? "bun install"
                    : "npm install"
                tasks.append(SuggestedTask(
                    title: "[\(name)] \(install)",
                    subtitle: "node_modules assente",
                    priority: .critico,
                    source: .manifest,
                    evidence: ["package.json", "node_modules assente", "stack: Next.js"] + pmEvidence
                ))
            }
            tasks.append(SuggestedTask(
                title: "[\(name)] next build / typecheck",
                subtitle: "Smoke build Next.js (tsc + next build)",
                priority: .alto,
                source: .manifest,
                evidence: ["stack: Next.js", "package.json"] + pmEvidence
            ))
            tasks.append(SuggestedTask(
                title: "[\(name)] Smoke route critiche in dev",
                subtitle: "next dev → home + auth/api se presenti",
                priority: .medio,
                source: .manifest,
                evidence: ["stack: Next.js"]
            ))

        case .node:
            if !snap.hasInstallDir {
                tasks.append(SuggestedTask(
                    title: "[\(name)] npm/pnpm install",
                    subtitle: "Dipendenze Node non installate",
                    priority: .alto,
                    source: .manifest,
                    evidence: ["package.json", "node_modules assente"] + pmEvidence
                ))
            }
            tasks.append(SuggestedTask(
                title: "[\(name)] npm test / lint",
                subtitle: "Script package.json per smoke",
                priority: .alto,
                source: .manifest,
                evidence: ["stack: Node.js"] + pmEvidence
            ))

        case .python:
            if !snap.hasInstallDir {
                tasks.append(SuggestedTask(
                    title: "[\(name)] Crea venv e install deps",
                    subtitle: "pip/poetry install in virtualenv",
                    priority: .alto,
                    source: .manifest,
                    evidence: pmEvidence + ["venv assente"]
                ))
            }
            tasks.append(SuggestedTask(
                title: "[\(name)] pytest / smoke Python",
                subtitle: "Esegui test o import del package principale",
                priority: .alto,
                source: .manifest,
                evidence: ["stack: Python"] + pmEvidence
            ))

        case .go:
            tasks.append(SuggestedTask(
                title: "[\(name)] go test ./...",
                subtitle: "Smoke test moduli Go",
                priority: .alto,
                source: .manifest,
                evidence: ["go.mod"] + pmEvidence
            ))

        case .swift:
            tasks.append(SuggestedTask(
                title: "[\(name)] swift build / test",
                subtitle: "SPM package smoke",
                priority: .alto,
                source: .manifest,
                evidence: ["Package.swift"] + pmEvidence
            ))

        case .java:
            let cmd = snap.packageManagers.contains(.gradle) ? "./gradlew test" : "mvn test"
            tasks.append(SuggestedTask(
                title: "[\(name)] \(cmd)",
                subtitle: "Smoke test Java",
                priority: .alto,
                source: .manifest,
                evidence: ["stack: Java"] + pmEvidence
            ))

        case .ruby:
            tasks.append(SuggestedTask(
                title: "[\(name)] bundle install + rake test",
                subtitle: "Smoke Ruby",
                priority: .alto,
                source: .manifest,
                evidence: ["Gemfile"] + pmEvidence
            ))

        case .elixir:
            tasks.append(SuggestedTask(
                title: "[\(name)] mix deps.get + mix test",
                subtitle: "Smoke Elixir",
                priority: .alto,
                source: .manifest,
                evidence: ["mix.exs"] + pmEvidence
            ))

        case .unknown:
            if !snap.packageManagers.isEmpty {
                tasks.append(SuggestedTask(
                    title: "[\(name)] Installa dipendenze rilevate",
                    subtitle: snap.packageManagers.map(\.rawValue).joined(separator: ", "),
                    priority: .alto,
                    source: .manifest,
                    evidence: pmEvidence
                ))
            }
        }

        return tasks
    }

    nonisolated private static func fallbackTemplate(name: String, snap: ProjectBrainSnapshot) -> [SuggestedTask] {
        [
            SuggestedTask(
                title: "[\(name)] Mappa struttura progetto",
                subtitle: "Root: \(snap.rootEntries.prefix(6).joined(separator: ", "))",
                priority: .alto,
                source: .template,
                evidence: ["fallback: segnali deboli", "path: \(snap.path)"]
            ),
            SuggestedTask(
                title: "[\(name)] Definisci primi 3 lavori utili",
                subtitle: "Backlog iniziale basato su obiettivi prodotto",
                priority: .medio,
                source: .template,
                evidence: ["fallback template"]
            ),
        ]
    }
}
