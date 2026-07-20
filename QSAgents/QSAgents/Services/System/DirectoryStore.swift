import Foundation
import AppKit
import Combine

struct DirectoryEntry: Identifiable, Equatable, Hashable {
    let id: UUID
    var path: String
    var name: String
    var kind: Kind
    var isGit: Bool
    var subtitle: String?

    enum Kind: String {
        case home, desktop, documents, downloads, projects, bookmark, recent, discovered
    }

    init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        kind: Kind,
        isGit: Bool = false,
        subtitle: String? = nil
    ) {
        self.id = id
        self.path = (path as NSString).standardizingPath
        self.name = name ?? URL(fileURLWithPath: self.path).lastPathComponent
        self.kind = kind
        self.isGit = isGit
        self.subtitle = subtitle
    }
}

@MainActor
final class DirectoryStore: ObservableObject {
    @Published var quickAccess: [DirectoryEntry] = []
    @Published var bookmarks: [DirectoryEntry] = []
    @Published var recent: [DirectoryEntry] = []
    @Published var projects: [DirectoryEntry] = []
    @Published var searchQuery: String = ""

    private let bookmarksKey = "qs.directory.bookmarks"
    private let recentKey = "qs.directory.recent"

    init() {
        loadPersisted()
        rebuildQuickAccess()
        Task { await scanProjects() }
    }

    var filteredProjects: [DirectoryEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    // MARK: - Actions

    func rebuildQuickAccess() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var items: [DirectoryEntry] = [
            .init(path: home, name: "Home", kind: .home),
            .init(path: home + "/Desktop", name: "Desktop", kind: .desktop),
            .init(path: home + "/Documents", name: "Documents", kind: .documents),
            .init(path: home + "/Downloads", name: "Downloads", kind: .downloads),
        ]
        // Common project roots
        for name in ["Projects", "Developer", "dev", "code", "src", "work", "repos"] {
            let p = home + "/" + name
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                items.append(.init(path: p, name: name, kind: .projects))
            }
        }
        // Workspace of this app
        let qs = home + "/qsagents"
        if fm.fileExists(atPath: qs) {
            items.append(.init(path: qs, name: "qsagents", kind: .projects, isGit: fm.fileExists(atPath: qs + "/.git")))
        }
        quickAccess = items.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    func addBookmark() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        panel.message = "Aggiungi directory preferite per accesso rapido"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addBookmark(path: url.path)
        }
    }

    func addBookmark(path: String) {
        let resolved = (path as NSString).standardizingPath
        guard !bookmarks.contains(where: { $0.path == resolved }) else { return }
        let isGit = FileManager.default.fileExists(atPath: resolved + "/.git")
        bookmarks.insert(.init(path: resolved, kind: .bookmark, isGit: isGit), at: 0)
        persist()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func rememberRecent(path: String) {
        let resolved = (path as NSString).standardizingPath
        recent.removeAll { $0.path == resolved }
        let isGit = FileManager.default.fileExists(atPath: resolved + "/.git")
        recent.insert(.init(path: resolved, kind: .recent, isGit: isGit), at: 0)
        if recent.count > 12 { recent = Array(recent.prefix(12)) }
        persist()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Deep-ish scan of common roots for git projects / package dirs.
    func scanProjects() async {
        let home = NSHomeDirectory()
        let roots = [
            home + "/Projects",
            home + "/Developer",
            home + "/dev",
            home + "/code",
            home + "/repos",
            home + "/work",
            home + "/qsagents",
            home + "/Documents",
        ]
        let fm = FileManager.default
        var found: [DirectoryEntry] = []
        var seen = Set<String>()

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            // root itself if project-like
            if isProjectLike(root) {
                let p = (root as NSString).standardizingPath
                if seen.insert(p).inserted {
                    found.append(.init(path: p, kind: .discovered, isGit: fm.fileExists(atPath: p + "/.git")))
                }
            }
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in kids where !name.hasPrefix(".") {
                let full = root + "/" + name
                var kidDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &kidDir), kidDir.boolValue else { continue }
                if isProjectLike(full) {
                    let p = (full as NSString).standardizingPath
                    if seen.insert(p).inserted {
                        found.append(.init(
                            path: p,
                            kind: .discovered,
                            isGit: fm.fileExists(atPath: p + "/.git"),
                            subtitle: root.replacingOccurrences(of: home, with: "~")
                        ))
                    }
                }
                // one more level
                if let grand = try? fm.contentsOfDirectory(atPath: full) {
                    for g in grand where !g.hasPrefix(".") {
                        let gfull = full + "/" + g
                        var gDir: ObjCBool = false
                        guard fm.fileExists(atPath: gfull, isDirectory: &gDir), gDir.boolValue else { continue }
                        if isProjectLike(gfull) {
                            let p = (gfull as NSString).standardizingPath
                            if seen.insert(p).inserted {
                                found.append(.init(
                                    path: p,
                                    kind: .discovered,
                                    isGit: fm.fileExists(atPath: p + "/.git"),
                                    subtitle: full.replacingOccurrences(of: home, with: "~")
                                ))
                            }
                        }
                    }
                }
            }
        }

        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        projects = found
    }

    func resolveUserPath(_ raw: String) -> String? {
        var p = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") {
            // Match by project name
            if let hit = projects.first(where: { $0.name.lowercased() == p.lowercased() }) {
                return hit.path
            }
            if p.count >= 3, let hit = projects.first(where: { $0.name.lowercased().contains(p.lowercased()) }) {
                return hit.path
            }
            if let hit = bookmarks.first(where: { $0.name.lowercased() == p.lowercased() }) {
                return hit.path
            }
            // Do not map Italian filler («home», «gioco») to ~/token
            let stop: Set<String> = ["home", "gioco", "codice", "pagina", "progetto", "workspace", "cartella"]
            if stop.contains(p.lowercased()) { return nil }
            // relative to home only for path-like tokens
            p = NSHomeDirectory() + "/" + p
        }
        p = (p as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        if p == home { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            return p
        }
        return nil
    }

    // MARK: - Private

    private func isProjectLike(_ path: String) -> Bool {
        let fm = FileManager.default
        let markers = [
            ".git", "Package.swift", "package.json", "Cargo.toml", "go.mod",
            "pyproject.toml", "Podfile", "*.xcodeproj", "Gemfile", "composer.json",
            "CMakeLists.txt", "Makefile", "README.md"
        ]
        for m in markers {
            if m.contains("*") {
                // xcodeproj
                if let kids = try? fm.contentsOfDirectory(atPath: path),
                   kids.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                    return true
                }
            } else if fm.fileExists(atPath: path + "/" + m) {
                return true
            }
        }
        return false
    }

    private func loadPersisted() {
        let defaults = UserDefaults.standard
        if let paths = defaults.stringArray(forKey: bookmarksKey) {
            bookmarks = paths.map {
                .init(path: $0, kind: .bookmark, isGit: FileManager.default.fileExists(atPath: $0 + "/.git"))
            }
        }
        if let paths = defaults.stringArray(forKey: recentKey) {
            recent = paths.map {
                .init(path: $0, kind: .recent, isGit: FileManager.default.fileExists(atPath: $0 + "/.git"))
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(bookmarks.map(\.path), forKey: bookmarksKey)
        UserDefaults.standard.set(recent.map(\.path), forKey: recentKey)
    }
}
