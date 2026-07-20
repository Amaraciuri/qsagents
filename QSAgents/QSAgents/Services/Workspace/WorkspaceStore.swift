import Foundation
import AppKit
import Combine

/// A project folder on disk — source of truth for editor + terminals.
struct ProjectWorkspace: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var path: String
    var name: String
    var lastOpened: Date
    var defaultRoleRaw: String
    var envRaw: String

    var defaultRole: AgentRole {
        get { AgentRole(rawValue: defaultRoleRaw) ?? .builder }
        set { defaultRoleRaw = newValue.rawValue }
    }

    var env: AgentEnvironment {
        get { AgentEnvironment(rawValue: envRaw) ?? .development }
        set { envRaw = newValue.rawValue }
    }

    var gitRoot: String? {
        var dir = path
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        lastOpened: Date = .now,
        defaultRole: AgentRole = .builder,
        env: AgentEnvironment = .development
    ) {
        self.id = id
        let resolved = (path as NSString).standardizingPath
        self.path = resolved
        self.name = name ?? URL(fileURLWithPath: resolved).lastPathComponent
        self.lastOpened = lastOpened
        self.defaultRoleRaw = defaultRole.rawValue
        self.envRaw = env.rawValue
    }
}

struct FileNode: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var isDirectory: Bool
    var children: [FileNode]
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        isDirectory: Bool,
        children: [FileNode] = [],
        isExpanded: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
        self.isExpanded = isExpanded
    }
}

struct EditorTab: Identifiable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var content: String
    var isDirty: Bool

    init(id: UUID = UUID(), path: String, name: String, content: String, isDirty: Bool = false) {
        self.id = id
        self.path = path
        self.name = name
        self.content = content
        self.isDirty = isDirty
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var recent: [ProjectWorkspace] = []
    @Published var current: ProjectWorkspace?
    @Published var fileTree: [FileNode] = []
    @Published var openFilePath: String?
    @Published var openFileName: String = ""
    @Published var fileContent: String = ""
    @Published var isDirty: Bool = false
    @Published var lastError: String?
    /// Multi-tab editor (Fase 6)
    @Published var tabs: [EditorTab] = []
    @Published var selectedTabID: UUID?
    @Published var pendingDiffText: String = ""
    @Published var lastTestCommand: String?
    @Published var safetyPolicy: WorkspaceSafetyPolicy?
    @Published var previewURL: String = "http://127.0.0.1:3000"
    /// Absolute paths modified by agents / git dirty (red dots in file tree).
    @Published private(set) var dirtyFilePaths: Set<String> = []

    private let storeName = "workspaces"
    private let ignoreNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods",
        ".swiftpm", "build", "dist", ".next", "xcuserdata", ".DS_Store"
    ]

    init() {
        load()
    }

    /// Mark files touched by agent writes (absolute paths).
    func markExternallyModified(paths: [String]) {
        var next = dirtyFilePaths
        for p in paths {
            let std = (p as NSString).standardizingPath
            guard !std.isEmpty else { continue }
            next.insert(std)
        }
        if next != dirtyFilePaths { dirtyFilePaths = next }
    }

    /// Sync red dots from `git status` (relative paths → absolute under root).
    func syncGitDirty(root: String?, changes: [GitFileChange]) {
        guard let root, !root.isEmpty else {
            if !dirtyFilePaths.isEmpty { dirtyFilePaths = [] }
            return
        }
        let rootStd = (root as NSString).standardizingPath
        var next = Set<String>()
        for c in changes {
            let abs = (rootStd as NSString).appendingPathComponent(c.path)
            next.insert((abs as NSString).standardizingPath)
        }
        // Keep agent-touched paths that git still reports, drop cleaned ones
        if next != dirtyFilePaths { dirtyFilePaths = next }
    }

    func isPathDirty(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        if dirtyFilePaths.contains(std) { return true }
        // Folder contains a dirty child
        let prefix = std.hasSuffix("/") ? std : std + "/"
        return dirtyFilePaths.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - Open / close

    /// Fired when workspace path actually changes (not same-path refresh).
    var onWorkspaceChanged: ((String?, String) -> Void)?

    @discardableResult
    func open(path: String) -> ProjectWorkspace? {
        let resolved = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            lastError = "Directory non valida: \(resolved)"
            AppLogger.error(lastError!)
            return nil
        }
        // Same path already current — refresh tree only, keep tabs/editor (avoid "reset" feel)
        if let cur = current, (cur.path as NSString).standardizingPath == resolved {
            var ws = cur
            ws.lastOpened = .now
            current = ws
            remember(ws)
            reloadFileTree()
            lastError = nil
            safetyPolicy = WorkspaceSafetyPolicy.load(from: resolved)
            persist()
            return ws
        }
        let previous = current?.path
        var ws = recent.first { $0.path == resolved } ?? ProjectWorkspace(path: resolved)
        ws.lastOpened = .now
        current = ws
        remember(ws)
        dirtyFilePaths = []
        reloadFileTree()
        tabs = []
        selectedTabID = nil
        openFilePath = nil
        openFileName = ""
        fileContent = ""
        isDirty = false
        lastError = nil
        safetyPolicy = WorkspaceSafetyPolicy.load(from: resolved)
        if safetyPolicy != nil {
            AppLogger.info("Loaded qs-safety.json for \(resolved)")
        }
        AppLogger.info("Workspace opened: \(resolved)")
        // Warm local code brain so agents can repo_capsule without grepping
        ProjectCodeBrain.shared.ensureIndexed(workspace: resolved)
        persist()
        onWorkspaceChanged?(previous, resolved)
        return ws
    }

    func pickAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Apri Workspace"
        panel.message = "Scegli la cartella progetto per QS Agents"
        if panel.runModal() == .OK, let url = panel.url {
            _ = open(path: url.path)
        }
    }

    func openRecent(_ id: UUID) {
        guard let ws = recent.first(where: { $0.id == id }) else { return }
        _ = open(path: ws.path)
    }

    func removeRecent(_ id: UUID) {
        recent.removeAll { $0.id == id }
        if current?.id == id { current = nil; fileTree = [] }
        persist()
    }

    // MARK: - File tree

    /// Paths the user expanded — restored after `reloadFileTree` (BUG-017).
    private var expandedPaths: Set<String> = []

    private func expandedDefaultsKey(for root: String) -> String {
        "qs.workspace.expanded.\((root as NSString).standardizingPath)"
    }

    private func loadExpandedPaths(for root: String) {
        let arr = UserDefaults.standard.stringArray(forKey: expandedDefaultsKey(for: root)) ?? []
        expandedPaths = Set(arr)
    }

    private func persistExpandedPaths(for root: String) {
        UserDefaults.standard.set(Array(expandedPaths).sorted(), forKey: expandedDefaultsKey(for: root))
    }

    func reloadFileTree() {
        guard let root = current?.path else {
            fileTree = []
            return
        }
        loadExpandedPaths(for: root)
        // Root listing; re-apply saved expand state (BUG-017).
        fileTree = restoreExpanded(in: listDirectory(root, depth: 0, maxDepth: 0))
    }

    /// Collapse every directory in the explorer.
    func collapseAllFolders() {
        fileTree = collapseAll(in: fileTree)
        expandedPaths.removeAll()
        if let root = current?.path {
            persistExpandedPaths(for: root)
        }
    }

    private func collapseAll(in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            var n = node
            if n.isDirectory {
                n.isExpanded = false
                n.children = collapseAll(in: n.children)
            }
            return n
        }
    }

    func toggleExpand(_ nodeID: UUID) {
        fileTree = toggleExpand(in: fileTree, id: nodeID)
        if let root = current?.path {
            persistExpandedPaths(for: root)
        }
    }

    private func toggleExpand(in nodes: [FileNode], id: UUID) -> [FileNode] {
        nodes.map { node in
            var n = node
            if n.id == id, n.isDirectory {
                n.isExpanded.toggle()
                if n.isExpanded {
                    expandedPaths.insert(n.path)
                    if n.children.isEmpty {
                        n.children = listDirectory(n.path, depth: 0, maxDepth: 1)
                    }
                } else {
                    expandedPaths.remove(n.path)
                    // Also drop nested expands under this folder
                    expandedPaths = expandedPaths.filter { !$0.hasPrefix(n.path + "/") }
                }
            } else if n.isDirectory && !n.children.isEmpty {
                n.children = toggleExpand(in: n.children, id: id)
            }
            return n
        }
    }

    private func restoreExpanded(in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            var n = node
            guard n.isDirectory, expandedPaths.contains(n.path) else { return n }
            n.isExpanded = true
            if n.children.isEmpty {
                n.children = listDirectory(n.path, depth: 0, maxDepth: 1)
            }
            n.children = restoreExpanded(in: n.children)
            return n
        }
    }

    private func listDirectory(_ path: String, depth: Int, maxDepth: Int) -> [FileNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        let filtered = names.filter { !ignoreNames.contains($0) && !$0.hasPrefix(".") }
            .sorted { a, b in
                let ap = path + "/" + a
                let bp = path + "/" + b
                var aDir: ObjCBool = false
                var bDir: ObjCBool = false
                _ = fm.fileExists(atPath: ap, isDirectory: &aDir)
                _ = fm.fileExists(atPath: bp, isDirectory: &bDir)
                if aDir.boolValue != bDir.boolValue { return aDir.boolValue && !bDir.boolValue }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        return filtered.prefix(200).map { name in
            let full = path + "/" + name
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            var children: [FileNode] = []
            if isDir.boolValue && depth < maxDepth {
                children = listDirectory(full, depth: depth + 1, maxDepth: maxDepth)
            }
            return FileNode(
                name: name + (isDir.boolValue ? "/" : ""),
                path: full,
                isDirectory: isDir.boolValue,
                children: children,
                isExpanded: false
            )
        }
    }

    // MARK: - Editor (multi-tab)

    func openFile(path: String) {
        guard !path.isEmpty else { return }
        if let existing = tabs.first(where: { $0.path == path }) {
            selectTab(existing.id)
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.count > 2_000_000 {
                lastError = "File troppo grande (>2MB)"
                return
            }
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                lastError = "Encoding non supportato"
                return
            }
            let tab = EditorTab(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                content: text
            )
            tabs.append(tab)
            selectTab(tab.id)
            lastError = nil
            AppLogger.info("File opened: \(path)")
        } catch {
            lastError = error.localizedDescription
            AppLogger.error("openFile: \(error.localizedDescription)")
        }
    }

    func selectTab(_ id: UUID) {
        // flush current dirty content into tab first
        syncOpenToTab()
        selectedTabID = id
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        openFilePath = tab.path
        openFileName = tab.name
        fileContent = tab.content
        isDirty = tab.isDirty
    }

    /// - Returns: `false` if the tab is dirty and `force` is false (caller should confirm) — BUG-017.
    @discardableResult
    func closeTab(_ id: UUID, force: Bool = false) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return true }
        if tab.isDirty && !force { return false }
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            if let last = tabs.last {
                selectTab(last.id)
            } else {
                selectedTabID = nil
                openFilePath = nil
                openFileName = ""
                fileContent = ""
                isDirty = false
            }
        }
        return true
    }

    private func syncOpenToTab() {
        guard let sid = selectedTabID,
              let i = tabs.firstIndex(where: { $0.id == sid }) else { return }
        tabs[i].content = fileContent
        tabs[i].isDirty = isDirty
    }

    func updateContent(_ text: String) {
        fileContent = text
        isDirty = true
        if let sid = selectedTabID, let i = tabs.firstIndex(where: { $0.id == sid }) {
            tabs[i].content = text
            tabs[i].isDirty = true
        }
    }

    @discardableResult
    func saveOpenFile() -> Bool {
        guard let path = openFilePath else { return false }
        do {
            try fileContent.write(toFile: path, atomically: true, encoding: .utf8)
            isDirty = false
            if let sid = selectedTabID, let i = tabs.firstIndex(where: { $0.id == sid }) {
                tabs[i].content = fileContent
                tabs[i].isDirty = false
            }
            lastError = nil
            AppLogger.info("File saved: \(path)")
            return true
        } catch {
            lastError = error.localizedDescription
            AppLogger.error("saveFile: \(error.localizedDescription)")
            return false
        }
    }

    /// Detect test/build command for workspace.
    func detectTestCommand() -> String {
        guard let root = current?.path else { return "echo 'no workspace'" }
        let fm = FileManager.default
        if fm.fileExists(atPath: root + "/Package.swift") { return "swift test" }
        if fm.fileExists(atPath: root + "/package.json") {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = json["scripts"] as? [String: Any] {
                if scripts["test"] != nil { return "npm test" }
                if scripts["build"] != nil { return "npm run build" }
            }
            return "npm test"
        }
        if fm.fileExists(atPath: root + "/Makefile") { return "make test" }
        if fm.fileExists(atPath: root + "/Cargo.toml") { return "cargo test" }
        if fm.fileExists(atPath: root + "/pyproject.toml") || fm.fileExists(atPath: root + "/pytest.ini") {
            return "pytest -q"
        }
        return "echo 'Nessun runner rilevato — configura manualmente'"
    }

    @discardableResult
    func applyUnifiedDiff(_ diffText: String) -> String {
        let patches = DiffService.parseUnified(diffText)
        guard !patches.isEmpty else { return "Nessun patch valido nel diff" }
        var messages: [String] = []
        for patch in patches {
            let full: String
            if patch.path.hasPrefix("/") {
                // BUG-010 + symlink: refuse absolute paths outside open workspace (resolve symlinks)
                guard let root = current?.path else {
                    messages.append("Skip \(patch.path): no workspace")
                    continue
                }
                let rootReal = WorkspacePathSandbox.realStandardizedPath(root)
                guard WorkspacePathSandbox.contains(candidate: patch.path, workspaceRoot: rootReal) else {
                    messages.append("✗ \(patch.path): fuori workspace (bloccato)")
                    continue
                }
                full = WorkspacePathSandbox.realStandardizedPath(patch.path)
            } else if let root = current?.path {
                let rootReal = WorkspacePathSandbox.realStandardizedPath(root)
                let joined = (rootReal as NSString).appendingPathComponent(patch.path)
                guard WorkspacePathSandbox.contains(candidate: joined, workspaceRoot: rootReal) else {
                    messages.append("✗ \(patch.path): path escape / symlink fuori workspace (bloccato)")
                    continue
                }
                full = WorkspacePathSandbox.realStandardizedPath(joined)
            } else {
                messages.append("Skip \(patch.path): no workspace")
                continue
            }
            let original = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
            switch DiffService.apply(patch: patch, to: original) {
            case .success(let newText):
                do {
                    try newText.write(toFile: full, atomically: true, encoding: .utf8)
                    messages.append("✓ applicato \(patch.path)")
                    // refresh tab if open
                    if let i = tabs.firstIndex(where: { $0.path == full }) {
                        tabs[i].content = newText
                        tabs[i].isDirty = false
                        if selectedTabID == tabs[i].id {
                            fileContent = newText
                            isDirty = false
                        }
                    }
                } catch {
                    messages.append("✗ write \(patch.path): \(error.localizedDescription)")
                }
            case .failure(let err):
                messages.append("✗ \(patch.path): \(err.description)")
            }
        }
        return messages.joined(separator: "\n")
    }

    func writeSafetyTemplate() -> Bool {
        guard let root = current?.path else { return false }
        let path = (root as NSString).appendingPathComponent(WorkspaceSafetyPolicy.fileName)
        do {
            try WorkspaceSafetyPolicy.templateJSON().write(toFile: path, atomically: true, encoding: .utf8)
            safetyPolicy = WorkspaceSafetyPolicy.load(from: root)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// First text file under root for convenience (README, etc.)
    func openDefaultFileIfNeeded() {
        guard openFilePath == nil, let root = current?.path else { return }
        let candidates = ["README.md", "readme.md", "Package.swift", "package.json"]
        for c in candidates {
            let p = root + "/" + c
            if FileManager.default.fileExists(atPath: p) {
                openFile(path: p)
                return
            }
        }
    }

    // MARK: - Persist

    private struct Payload: Codable {
        var recent: [ProjectWorkspace]
        var currentPath: String?
    }

    private func remember(_ ws: ProjectWorkspace) {
        recent.removeAll { $0.path == ws.path }
        recent.insert(ws, at: 0)
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        persist()
    }

    private func load() {
        guard let p: Payload = JSONStore.load(Payload.self, name: storeName) else { return }
        recent = p.recent
        if let path = p.currentPath {
            _ = open(path: path)
        }
    }

    private func persist() {
        let payload = Payload(recent: recent, currentPath: current?.path)
        JSONStore.save(payload, name: storeName)
    }
}
