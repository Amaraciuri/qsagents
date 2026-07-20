import Foundation
import Combine

struct KnowledgeChunk: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var relativePath: String
    var language: String
    var startLine: Int
    var text: String
    var symbols: [String]

    init(
        id: UUID = UUID(),
        path: String,
        relativePath: String,
        language: String,
        startLine: Int,
        text: String,
        symbols: [String] = []
    ) {
        self.id = id
        self.path = path
        self.relativePath = relativePath
        self.language = language
        self.startLine = startLine
        self.text = text
        self.symbols = symbols
    }
}

struct KnowledgeGraphNode: Identifiable, Equatable {
    let id: UUID
    var title: String
    var kind: String // file | symbol | concept | folder | page
    var path: String?
    /// Relative path (folder or file) for hierarchy display
    var relativePath: String?
    var detail: String
    var x: Double
    var y: Double
    /// Language / extension for color (swift, ts, …)
    var language: String?
    /// Relative weight for node size (files with more symbols = larger)
    var weight: Int
    /// Depth in tree (0 = root)
    var depth: Int
    /// Child count (folders) or import count (files)
    var childCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        kind: String,
        path: String? = nil,
        relativePath: String? = nil,
        detail: String,
        x: Double,
        y: Double,
        language: String? = nil,
        weight: Int = 1,
        depth: Int = 0,
        childCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.path = path
        self.relativePath = relativePath
        self.detail = detail
        self.x = x
        self.y = y
        self.language = language
        self.weight = weight
        self.depth = depth
        self.childCount = childCount
    }
}

struct KnowledgeGraphEdge: Identifiable, Equatable {
    let id: UUID
    var from: UUID
    var to: UUID
    /// contains | defines | imports | related
    var kind: String

    init(id: UUID = UUID(), from: UUID, to: UUID, kind: String = "related") {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
    }
}

struct KnowledgeHit: Identifiable, Equatable {
    let id: UUID
    var path: String
    var relativePath: String
    var snippet: String
    var score: Int
    var startLine: Int
}

struct KnowledgeProjectSnapshot: Equatable {
    var path: String
    var name: String
    var chunks: [KnowledgeChunk]
    var nodes: [KnowledgeGraphNode]
    var edges: [KnowledgeGraphEdge]
    var fileCount: Int
    var indexedAt: Date
}

/// Local keyword index — **multi-progetto** (cache per workspace path).
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var chunks: [KnowledgeChunk] = []
    @Published private(set) var nodes: [KnowledgeGraphNode] = []
    @Published private(set) var edges: [KnowledgeGraphEdge] = []
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var lastIndexedPath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var fileCount: Int = 0
    @Published var searchQuery: String = ""
    @Published private(set) var hits: [KnowledgeHit] = []
    /// All projects that have been indexed this session (and optionally restored).
    @Published private(set) var projects: [KnowledgeProjectSnapshot] = []
    @Published var activeProjectPath: String?

    private var cache: [String: KnowledgeProjectSnapshot] = [:]
    /// D1 FTS inverted index for active project.
    private let fts = KnowledgeFTSIndex()

    private let ignore: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", "build",
        "dist", ".next", "xcuserdata", ".DS_Store", "Carthage", "vendor"
    ]
    private let codeExt: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt",
        "md", "json", "yml", "yaml", "toml", "sh", "c", "h", "cpp", "m", "mm"
    ]

    var activeProjectName: String {
        if let p = activeProjectPath {
            return URL(fileURLWithPath: p).lastPathComponent
        }
        return "—"
    }

    func cacheHas(_ path: String) -> Bool {
        let root = (path as NSString).standardizingPath
        return cache[root] != nil
    }

    /// Switch active knowledge to another already-indexed project (instant).
    func selectProject(_ path: String) {
        let root = (path as NSString).standardizingPath
        if let snap = cache[root] {
            apply(snap)
            return
        }
        // Not cached — will need re-index
        lastError = "Progetto non in cache — premi «Indice» per scansionarlo"
        activeProjectPath = root
        chunks = []
        nodes = []
        edges = []
        fileCount = 0
        hits = []
    }

    /// Drop one project from memory cache.
    func removeProject(_ path: String) {
        let root = (path as NSString).standardizingPath
        cache.removeValue(forKey: root)
        projects.removeAll { $0.path == root }
        if activeProjectPath == root {
            if let first = projects.first {
                apply(first)
            } else {
                activeProjectPath = nil
                chunks = []
                nodes = []
                edges = []
                fileCount = 0
                lastIndexedPath = nil
                hits = []
            }
        }
    }

    private func apply(_ snap: KnowledgeProjectSnapshot) {
        chunks = snap.chunks
        nodes = snap.nodes
        edges = snap.edges
        fileCount = snap.fileCount
        lastIndexedPath = snap.path
        activeProjectPath = snap.path
        hits = []
        fts.rebuild(chunks: snap.chunks)
        if !searchQuery.isEmpty { search(searchQuery) }
    }

    private func rebuildProjectList() {
        projects = cache.values.sorted { $0.indexedAt > $1.indexedAt }
    }

    func index(workspace path: String) {
        guard !isIndexing else { return }
        isIndexing = true
        lastError = nil
        let root = (path as NSString).standardizingPath
        activeProjectPath = root
        Task.detached(priority: .userInitiated) { [ignore, codeExt] in
            var collected: [KnowledgeChunk] = []
            var files = 0
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(atPath: root) else {
                await MainActor.run {
                    self.isIndexing = false
                    self.lastError = "Impossibile scansionare \(root)"
                }
                return
            }
            while let rel = enumerator.nextObject() as? String {
                let parts = rel.split(separator: "/")
                if parts.contains(where: { ignore.contains(String($0)) }) {
                    if parts.count == 1 || ignore.contains(String(parts[0])) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let full = (root as NSString).appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                let ext = (rel as NSString).pathExtension.lowercased()
                guard codeExt.contains(ext) else { continue }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)), data.count < 400_000 else { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                files += 1
                let lang = ext
                let lines = text.components(separatedBy: "\n")
                let chunkSize = 80
                var i = 0
                while i < lines.count {
                    let slice = lines[i..<min(i + chunkSize, lines.count)]
                    let body = slice.joined(separator: "\n")
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        i += chunkSize
                        continue
                    }
                    let symbols = KnowledgeIndexer.extractSymbols(from: body, lang: lang)
                    collected.append(KnowledgeChunk(
                        path: full,
                        relativePath: rel,
                        language: lang,
                        startLine: i + 1,
                        text: body,
                        symbols: symbols
                    ))
                    i += chunkSize
                    if collected.count > 4000 { break }
                }
                if collected.count > 4000 { break }
            }
            let graph = KnowledgeIndexer.buildGraph(chunks: collected, root: root)
            let name = URL(fileURLWithPath: root).lastPathComponent
            let snap = KnowledgeProjectSnapshot(
                path: root,
                name: name,
                chunks: collected,
                nodes: graph.nodes,
                edges: graph.edges,
                fileCount: files,
                indexedAt: Date()
            )
            await MainActor.run {
                self.cache[root] = snap
                self.rebuildProjectList()
                self.apply(snap)
                self.isIndexing = false
                AppLogger.info("Knowledge indexed \(name): \(files) files · \(collected.count) chunks · \(self.cache.count) progetti in cache")
            }
        }
    }

    func search(_ query: String) {
        searchQuery = query
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            return
        }
        let terms = KnowledgeFTSIndex.tokenize(q)
        let byId = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })

        // D1: FTS inverted index (BM25-ish) + symbol/path boosts
        var scored: [KnowledgeHit] = []
        if !fts.isEmpty {
            let ftsHits = fts.search(query: q, limit: 60)
            for fh in ftsHits {
                guard let c = byId[fh.chunkId] else { continue }
                var score = Int(fh.score * 10)
                for t in terms {
                    if c.symbols.contains(where: { $0.lowercased().contains(t) }) { score += 8 }
                    if c.relativePath.lowercased().contains(t) { score += 6 }
                }
                score += Self.pathRankBoost(c.relativePath)
                let snip = snippet(from: c.text, terms: terms)
                scored.append(KnowledgeHit(
                    id: c.id,
                    path: c.path,
                    relativePath: c.relativePath,
                    snippet: snip,
                    score: score,
                    startLine: c.startLine
                ))
            }
        }

        // Fallback / merge: classic substring if FTS thin
        if scored.count < 8 {
            var seen = Set(scored.map(\.id))
            for c in chunks {
                if seen.contains(c.id) { continue }
                let hay = (c.relativePath + "\n" + c.symbols.joined(separator: " ") + "\n" + c.text).lowercased()
                var score = 0
                for t in terms {
                    if hay.contains(t) { score += 2 }
                    if c.symbols.contains(where: { $0.lowercased().contains(t) }) { score += 5 }
                    if c.relativePath.lowercased().contains(t) { score += 4 }
                }
                if score == 0 { continue }
                score += Self.pathRankBoost(c.relativePath)
                seen.insert(c.id)
                scored.append(KnowledgeHit(
                    id: c.id,
                    path: c.path,
                    relativePath: c.relativePath,
                    snippet: snippet(from: c.text, terms: terms),
                    score: score,
                    startLine: c.startLine
                ))
            }
        }

        // Collapse Capacitor / www mirrors — keep best score per logical file.
        var byLogical: [String: KnowledgeHit] = [:]
        for h in scored.sorted(by: { $0.score > $1.score }) {
            let key = ProjectCodeBrain.logicalPathKey(h.relativePath)
            if byLogical[key] == nil { byLogical[key] = h }
        }
        hits = Array(byLogical.values).sorted { $0.score > $1.score }.prefix(40).map { $0 }
    }

    /// Prefer tracked root/src (Cursor-style); demote www/ build + native mirrors.
    private static func pathRankBoost(_ rel: String) -> Int {
        let low = rel.lowercased()
        var b = 0
        if low.hasPrefix("www/") { b -= 6 }
        if low.hasPrefix("src/") { b += 5 }
        if !low.contains("/"), low.hasSuffix(".css") || low.hasSuffix(".js") || low == "index.html" { b += 6 }
        if low == "premium-ui.css" || low == "premium-ui.js" || low == "index.html" { b += 8 }
        if low.contains("mobile-buttons") || low.contains("home-mobile") { b -= 12 }
        if low.hasPrefix("ios/") || low.hasPrefix("android/") { b -= 10 }
        if low.hasPrefix("docs/") || low.hasSuffix(".md") { b -= 2 }
        return b
    }

    func answerPrompt(for question: String) -> String {
        search(question)
        if hits.isEmpty {
            return lastIndexedPath == nil
                ? "Knowledge non indicizzato. Apri un workspace e premi **Indice**."
                : "Nessun risultato per «\(question)» in **\(activeProjectName)** (\(fileCount) file). Prova un altro progetto dalla lista."
        }
        let top = hits.prefix(6).map { h in
            "• `\(h.relativePath):\(h.startLine)` (score \(h.score))\n  \(h.snippet.replacingOccurrences(of: "\n", with: " ").prefix(160))"
        }.joined(separator: "\n")
        return "**Knowledge FTS · \(activeProjectName)** (\(fileCount) file, \(chunks.count) chunk · \(projects.count) progetti)\n\n\(top)"
    }

    /// Agent/tool helper: compact FTS results string.
    func searchReport(_ query: String, limit: Int = 8) -> String {
        search(query)
        if hits.isEmpty {
            return "Nessun hit FTS per «\(query)» (index \(chunks.count) chunk)."
        }
        return hits.prefix(limit).map { h in
            "[\(h.score)] \(h.relativePath):\(h.startLine)\n\(h.snippet.prefix(200))"
        }.joined(separator: "\n---\n")
    }

    private func snippet(from text: String, terms: [String]) -> String {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let low = line.lowercased()
            if terms.contains(where: { low.contains($0) }) {
                let from = max(0, i - 1)
                let to = min(lines.count - 1, i + 2)
                return lines[from...to].joined(separator: "\n")
            }
        }
        return String(text.prefix(200))
    }

}

/// Off-main-actor helpers for indexing.
enum KnowledgeIndexer {
    static func extractSymbols(from text: String, lang: String) -> [String] {
        var out: [String] = []
        let patterns: [String]
        switch lang {
        case "swift":
            patterns = [#"\b(?:func|class|struct|enum|protocol|actor)\s+(\w+)"#]
        case "ts", "tsx", "js", "jsx":
            patterns = [#"\b(?:function|class|const|export\s+function)\s+(\w+)"#]
        case "py":
            patterns = [#"\b(?:def|class)\s+(\w+)"#]
        default:
            patterns = [#"\b([A-Z][A-Za-z0-9_]{2,})\b"#]
        }
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            re.enumerateMatches(in: text, range: range) { m, _, _ in
                guard let m, m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: text) else { return }
                out.append(String(text[r]))
            }
        }
        return Array(Set(out)).prefix(30).map { $0 }
    }

    /// Hierarchical project map: root → folders → files (+ import links + top symbols).
    static func buildGraph(chunks: [KnowledgeChunk], root: String) -> (nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge]) {
        var byFile: [String: [KnowledgeChunk]] = [:]
        for c in chunks {
            byFile[c.relativePath, default: []].append(c)
        }
        // Prefer richer files but keep breadth for depth map
        let ranked = byFile.keys.sorted { a, b in
            let da = a.split(separator: "/").count
            let db = b.split(separator: "/").count
            let sa = byFile[a]?.flatMap(\.symbols).count ?? 0
            let sb = byFile[b]?.flatMap(\.symbols).count ?? 0
            // Prefer mid-depth structure files; then by symbols
            if sa != sb { return sa > sb }
            if da != db { return da < db }
            return a < b
        }
        // Cap for readability; still enough to show depth
        let files = Array(ranked.prefix(72))
        let fileSet = Set(files)

        // --- Collect all folder prefixes ---
        var folderPaths = Set<String>()
        for f in files {
            let parts = f.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            var acc = ""
            for i in 0..<(parts.count - 1) {
                acc = acc.isEmpty ? parts[i] : acc + "/" + parts[i]
                folderPaths.insert(acc)
            }
        }
        // Cap deep trees: keep folders that contain selected files, max ~40 folders
        let folders = Array(folderPaths).sorted { a, b in
            let da = a.split(separator: "/").count
            let db = b.split(separator: "/").count
            if da != db { return da < db }
            return a < b
        }
        // If too many, prefer shallower
        let folderList: [String]
        if folders.count > 40 {
            folderList = folders.filter { $0.split(separator: "/").count <= 3 }.prefix(40).map { $0 }
        } else {
            folderList = folders
        }
        let folderSet = Set(folderList)

        var nodes: [KnowledgeGraphNode] = []
        var edges: [KnowledgeGraphEdge] = []
        var nodeID: [String: UUID] = [:] // key: "root" | "dir:path" | "file:path" | "sym:name"

        let rootName = URL(fileURLWithPath: root).lastPathComponent
        let rootID = UUID()
        nodeID["root"] = rootID
        nodes.append(KnowledgeGraphNode(
            id: rootID,
            title: rootName,
            kind: "concept",
            path: root,
            relativePath: "",
            detail: "\(files.count) file · \(folderList.count) cartelle · \(chunks.count) chunk",
            x: 0.5,
            y: 0.06,
            weight: 14,
            depth: 0,
            childCount: folderList.filter { !$0.contains("/") }.count
                + files.filter { !$0.contains("/") }.count
        ))

        // Parent of a path segment key
        func parentKey(for folder: String) -> String {
            if let r = folder.range(of: "/", options: .backwards) {
                let p = String(folder[..<r.lowerBound])
                return folderSet.contains(p) ? "dir:\(p)" : "root"
            }
            return "root"
        }

        // --- Layout: tree by depth (horizontal spread per depth band) ---
        // Group folders by depth
        var foldersByDepth: [Int: [String]] = [:]
        for f in folderList {
            let d = f.split(separator: "/").count
            foldersByDepth[d, default: []].append(f)
        }
        var filesByParent: [String: [String]] = [:] // parent key → file rel paths
        for f in files {
            let parts = f.split(separator: "/").map(String.init)
            if parts.count == 1 {
                filesByParent["root", default: []].append(f)
            } else {
                let parentFolder = parts.dropLast().joined(separator: "/")
                // walk up to a known folder
                var p = parentFolder
                var key = "dir:\(p)"
                while !folderSet.contains(p) {
                    if let r = p.range(of: "/", options: .backwards) {
                        p = String(p[..<r.lowerBound])
                        key = "dir:\(p)"
                    } else {
                        key = "root"
                        break
                    }
                }
                if folderSet.contains(p) {
                    filesByParent[key, default: []].append(f)
                } else {
                    filesByParent["root", default: []].append(f)
                }
            }
        }

        // Place folders
        for depth in foldersByDepth.keys.sorted() {
            let list = foldersByDepth[depth]!.sorted()
            let y = min(0.72, 0.06 + Double(depth) * 0.13)
            for (i, folder) in list.enumerated() {
                let n = max(list.count, 1)
                let x = n == 1 ? 0.5 : 0.08 + 0.84 * (Double(i) + 0.5) / Double(n)
                let id = UUID()
                let key = "dir:\(folder)"
                nodeID[key] = id
                let title = (folder as NSString).lastPathComponent
                let childFiles = filesByParent[key]?.count ?? 0
                let childFolders = folderList.filter {
                    $0.hasPrefix(folder + "/") && $0.split(separator: "/").count == depth + 1
                }.count
                nodes.append(KnowledgeGraphNode(
                    id: id,
                    title: title,
                    kind: "folder",
                    path: (root as NSString).appendingPathComponent(folder),
                    relativePath: folder,
                    detail: "\(folder)\n\(childFolders) sub · \(childFiles) file",
                    x: x,
                    y: y,
                    weight: 5 + min(6, childFiles + childFolders),
                    depth: depth,
                    childCount: childFiles + childFolders
                ))
                let pk = parentKey(for: folder)
                if let parent = nodeID[pk] {
                    edges.append(KnowledgeGraphEdge(from: parent, to: id, kind: "contains"))
                }
            }
        }

        // Place files under parents (slightly below parent band)
        var fileNodeID: [String: UUID] = [:]
        // Group placement: for each parent, lay files in a row under parent y
        for (parentKeyName, flist) in filesByParent {
            let parentNode = nodeID[parentKeyName]
            let parentY = nodes.first(where: { $0.id == parentNode })?.y ?? 0.06
            let parentDepth = nodes.first(where: { $0.id == parentNode })?.depth ?? 0
            let sorted = flist.sorted()
            // Cap per parent for clarity
            let shown = Array(sorted.prefix(12))
            for (i, f) in shown.enumerated() {
                let list = byFile[f] ?? []
                let symbols = Array(Set(list.flatMap(\.symbols))).sorted()
                let lang = list.first?.language
                let n = max(shown.count, 1)
                let baseX = nodes.first(where: { $0.id == parentNode })?.x ?? 0.5
                // Fan under parent
                let spread = min(0.28, 0.04 * Double(n))
                let x: Double
                if n == 1 {
                    x = baseX
                } else {
                    x = baseX - spread + 2 * spread * (Double(i) / Double(n - 1))
                }
                let y = min(0.94, parentY + 0.09 + Double(i % 3) * 0.015)
                let nid = UUID()
                fileNodeID[f] = nid
                nodeID["file:\(f)"] = nid
                let isPage = ["tsx", "jsx", "vue", "svelte", "html"].contains(lang ?? "")
                    || f.lowercased().contains("page.")
                    || f.lowercased().contains("view")
                    || f.lowercased().contains("screen")
                nodes.append(KnowledgeGraphNode(
                    id: nid,
                    title: (f as NSString).lastPathComponent,
                    kind: isPage ? "page" : "file",
                    path: list.first?.path,
                    relativePath: f,
                    detail: symbols.isEmpty
                        ? f
                        : "\(f)\n\(symbols.prefix(8).joined(separator: ", "))",
                    x: min(0.96, max(0.04, x)),
                    y: min(0.96, max(0.08, y)),
                    language: lang,
                    weight: max(2, min(10, symbols.count + 2)),
                    depth: parentDepth + 1,
                    childCount: symbols.count
                ))
                if let pid = parentNode {
                    edges.append(KnowledgeGraphEdge(from: pid, to: nid, kind: "contains"))
                } else {
                    edges.append(KnowledgeGraphEdge(from: rootID, to: nid, kind: "contains"))
                }
            }
        }

        // --- Import / reference edges between files ---
        var importEdges = 0
        for f in files {
            guard let fid = fileNodeID[f], let chunks = byFile[f] else { continue }
            let body = chunks.prefix(3).map(\.text).joined(separator: "\n")
            let lang = chunks.first?.language ?? ""
            let imports = extractImports(from: body, lang: lang, currentFile: f, knownFiles: fileSet)
            for target in imports.prefix(6) {
                guard let tid = fileNodeID[target], tid != fid else { continue }
                edges.append(KnowledgeGraphEdge(from: fid, to: tid, kind: "imports"))
                importEdges += 1
                if importEdges > 80 { break }
            }
            if importEdges > 80 { break }
        }

        // --- Top symbols (small inner ring near defining file or root) ---
        var symbolCounts: [String: Int] = [:]
        var symbolFiles: [String: String] = [:]
        for c in chunks where fileSet.contains(c.relativePath) {
            for s in c.symbols {
                symbolCounts[s, default: 0] += 1
                if symbolFiles[s] == nil { symbolFiles[s] = c.relativePath }
            }
        }
        let topSym = symbolCounts.sorted { $0.value > $1.value }.prefix(10)
        for (i, pair) in topSym.enumerated() {
            let sid = UUID()
            let fileRel = symbolFiles[pair.key]
            let fileN = fileRel.flatMap { fileNodeID[$0] }
            let fx = nodes.first(where: { $0.id == fileN })?.x ?? 0.5
            let fy = nodes.first(where: { $0.id == fileN })?.y ?? 0.5
            let angle = Double(i) / Double(max(topSym.count, 1)) * 2 * .pi
            let x = min(0.96, max(0.04, fx + 0.05 * cos(angle)))
            let y = min(0.96, max(0.08, fy + 0.04 * sin(angle)))
            nodes.append(KnowledgeGraphNode(
                id: sid,
                title: pair.key,
                kind: "symbol",
                path: fileRel.flatMap { byFile[$0]?.first?.path },
                relativePath: fileRel,
                detail: "simbolo · \(pair.value)× · \(fileRel ?? "?")",
                x: x,
                y: y,
                weight: min(8, pair.value + 1),
                depth: (nodes.first(where: { $0.id == fileN })?.depth ?? 0) + 1,
                childCount: pair.value
            ))
            if let fid = fileN {
                edges.append(KnowledgeGraphEdge(from: fid, to: sid, kind: "defines"))
            } else {
                edges.append(KnowledgeGraphEdge(from: rootID, to: sid, kind: "related"))
            }
        }

        return (nodes, edges)
    }

    /// Resolve import-like references to known relative file paths.
    static func extractImports(
        from text: String,
        lang: String,
        currentFile: String,
        knownFiles: Set<String>
    ) -> [String] {
        var found: [String] = []
        let lines = text.components(separatedBy: .newlines).prefix(80)
        let dir = (currentFile as NSString).deletingLastPathComponent

        func resolve(_ raw: String) -> String? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !s.isEmpty, !s.hasPrefix("http") else { return nil }
            // Only relative / project-ish
            let candidates: [String]
            if s.hasPrefix(".") {
                let joined = (dir as NSString).appendingPathComponent(s)
                let std = (joined as NSString).standardizingPath
                // strip leading ./
                let rel = std.hasPrefix("/") ? String(std.dropFirst()) : std
                candidates = [
                    rel,
                    rel + ".swift", rel + ".ts", rel + ".tsx", rel + ".js", rel + ".jsx",
                    rel + ".py", rel + ".go", rel + ".rs",
                    (rel as NSString).appendingPathComponent("index.ts"),
                    (rel as NSString).appendingPathComponent("index.tsx"),
                    (rel as NSString).appendingPathComponent("mod.rs"),
                ]
            } else if s.contains("/") {
                candidates = [
                    s, s + ".swift", s + ".ts", s + ".tsx", s + ".js",
                    "src/" + s, "src/" + s + ".ts", "src/" + s + ".tsx",
                ]
            } else {
                // bare module — match filename stem
                let stem = s.split(separator: ".").last.map(String.init) ?? s
                return knownFiles.first {
                    ($0 as NSString).lastPathComponent
                        .replacingOccurrences(of: ".\(($0 as NSString).pathExtension)", with: "")
                        .caseInsensitiveCompare(stem) == .orderedSame
                }
            }
            for c in candidates {
                let norm = c.replacingOccurrences(of: "//", with: "/")
                if knownFiles.contains(norm) { return norm }
            }
            // fuzzy: endswith
            for k in knownFiles {
                if k.hasSuffix(s) || k.hasSuffix(s + ".ts") || k.hasSuffix(s + ".tsx") || k.hasSuffix(s + ".swift") {
                    return k
                }
            }
            return nil
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("#") || t.hasPrefix("/*") { continue }

            // Swift: import Foo  (weak) or import struct Module.Type
            if lang == "swift", t.hasPrefix("import ") {
                let rest = t.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let mod = rest.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).first.map(String.init) ?? ""
                if let r = resolve(mod) { found.append(r) }
                continue
            }
            // TS/JS: from '…' / require('…')
            if ["ts", "tsx", "js", "jsx"].contains(lang) {
                if let r = matchQuoted(after: "from ", in: t).flatMap(resolve) { found.append(r); continue }
                if let r = matchQuoted(after: "require(", in: t).flatMap(resolve) { found.append(r); continue }
                if let r = matchQuoted(after: "import(", in: t).flatMap(resolve) { found.append(r); continue }
            }
            // Python
            if lang == "py" {
                if t.hasPrefix("from ") {
                    let parts = t.split(separator: " ")
                    if parts.count >= 2, let r = resolve(String(parts[1]).replacingOccurrences(of: ".", with: "/")) {
                        found.append(r)
                    }
                } else if t.hasPrefix("import ") {
                    let mod = t.dropFirst(7).split(separator: " ").first.map(String.init) ?? ""
                    if let r = resolve(mod.replacingOccurrences(of: ".", with: "/")) { found.append(r) }
                }
            }
            // Go
            if lang == "go", t.contains("\"") && (t.contains("import") || t.hasPrefix("\"")) {
                if let r = matchQuoted(after: "\"", in: t).flatMap(resolve) { found.append(r) }
            }
            // Rust mod / use crate::
            if lang == "rs" {
                if t.hasPrefix("mod ") {
                    let m = t.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ";{ "))
                    if let r = resolve("./" + m) { found.append(r) }
                }
                if t.hasPrefix("use ") {
                    let m = t.dropFirst(4).split(separator: ":").first.map(String.init) ?? ""
                    if let r = resolve(m) { found.append(r) }
                }
            }
        }
        return Array(Set(found))
    }

    private static func matchQuoted(after marker: String, in line: String) -> String? {
        guard let r = line.range(of: marker) else {
            // try any quote pair
            return nil
        }
        let rest = line[r.upperBound...]
        for q in ["\"", "'", "`"] {
            if let a = rest.range(of: q) {
                let after = rest[a.upperBound...]
                if let b = after.range(of: q) {
                    return String(after[..<b.lowerBound])
                }
            }
        }
        return nil
    }
}
