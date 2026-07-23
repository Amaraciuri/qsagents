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
        // Deferred so first frame is not competing with project discovery.
        Task(priority: .utility) { await scanProjects() }
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
    /// Heavy filesystem work runs off the main actor — scanning ~/Documents on MainActor
    /// froze launch (spinning cursor, no window) on large home directories.
    func scanProjects() async {
        let found = await Task.detached(priority: .utility) {
            Self.discoverProjects()
        }.value
        projects = found
    }

    nonisolated private static func discoverProjects() -> [DirectoryEntry] {
        let home = NSHomeDirectory()
        // Prefer explicit project roots. ~/Documents is last and only scanned 1 level deep —
        // hang reports showed main-thread freezes on iCloud dataless materialization there.
        let roots: [(path: String, depth: Int)] = [
            (home + "/Projects", 2),
            (home + "/Developer", 2),
            (home + "/dev", 2),
            (home + "/code", 2),
            (home + "/repos", 2),
            (home + "/work", 2),
            (home + "/qsagents", 2),
            (home + "/Documents", 1),
        ]
        var found: [DirectoryEntry] = []
        var seen = Set<String>()

        for (root, maxDepth) in roots {
            guard isLocalDirectory(root) else { continue }
            // root itself if project-like
            if isProjectLike(root) {
                let p = (root as NSString).standardizingPath
                if seen.insert(p).inserted {
                    found.append(.init(path: p, kind: .discovered, isGit: hasLocalGit(root)))
                }
            }
            scanChildren(
                of: root,
                home: home,
                remainingDepth: maxDepth,
                found: &found,
                seen: &seen
            )
        }

        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return found
    }

    /// Enumerate immediate children; recurse while `remainingDepth > 1`.
    nonisolated private static func scanChildren(
        of root: String,
        home: String,
        remainingDepth: Int,
        found: inout [DirectoryEntry],
        seen: inout Set<String>
    ) {
        guard remainingDepth >= 1 else { return }
        // Avoid contentsOfDirectory on pure cloud roots (can stall waiting for materialization).
        guard !isCloudOnlyDirectory(root) else { return }
        guard let kids = listDirectoryNames(root) else { return }

        for name in kids where !name.hasPrefix(".") {
            let full = root + "/" + name
            guard isLocalDirectory(full) else { continue }
            if isProjectLike(full) {
                let p = (full as NSString).standardizingPath
                if seen.insert(p).inserted {
                    found.append(.init(
                        path: p,
                        kind: .discovered,
                        isGit: hasLocalGit(full),
                        subtitle: root.replacingOccurrences(of: home, with: "~")
                    ))
                }
            }
            if remainingDepth > 1 {
                scanChildren(
                    of: full,
                    home: home,
                    remainingDepth: remainingDepth - 1,
                    found: &found,
                    seen: &seen
                )
            }
        }
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

    // MARK: - Filesystem helpers (must not force iCloud materialization)

    /// Project markers. Deliberately omit README.md — too common and often a cloud-only
    /// placeholder; `fileExists` on dataless files triggers `apfs_materialize_dataless_file_ext`
    /// and freezes the caller (see hang report 2026-07-23).
    private static let projectMarkers = [
        ".git", "Package.swift", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "Podfile", "Gemfile", "composer.json",
        "CMakeLists.txt", "Makefile",
    ]

    nonisolated private static func isProjectLike(_ path: String) -> Bool {
        // Cheap name-list first (no per-marker stat that could materialize cloud blobs).
        if let kids = listDirectoryNames(path) {
            if kids.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return true
            }
            let set = Set(kids)
            for m in projectMarkers where set.contains(m) {
                return true
            }
        }
        return false
    }

    nonisolated private static func hasLocalGit(_ path: String) -> Bool {
        guard let kids = listDirectoryNames(path) else { return false }
        return kids.contains(".git")
    }

    /// Name-only listing (no per-child stat that could materialize iCloud placeholders).
    nonisolated private static func listDirectoryNames(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// True only for real local directories. Skips files and non-downloaded iCloud items.
    nonisolated private static func isLocalDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let rv = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) else {
            // resourceValues failed — do not fall back to fileExists (can materialize).
            return false
        }
        if rv.isSymbolicLink == true { return false }
        guard rv.isDirectory == true else { return false }
        if rv.isUbiquitousItem == true {
            // Only walk fully current (downloaded) cloud folders.
            return rv.ubiquitousItemDownloadingStatus == .current
        }
        return true
    }

    nonisolated private static func isCloudOnlyDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let rv = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) else { return false }
        guard rv.isUbiquitousItem == true else { return false }
        return rv.ubiquitousItemDownloadingStatus != .current
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
