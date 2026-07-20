import Foundation
import SQLite3

/// Local project code brain: parse → graph → SQLite FTS → token-bounded capsule.
/// No upload, no embeddings required. Agents call `repo_capsule` instead of grepping the world.
@MainActor
final class ProjectCodeBrain: ObservableObject {
    static let shared = ProjectCodeBrain()

    @Published private(set) var isIndexing = false
    @Published private(set) var lastRoot: String?
    @Published private(set) var lastStats: String = ""
    @Published private(set) var lastError: String?

    private var db: OpaquePointer?
    private let ignore: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", "build",
        "dist", ".next", "xcuserdata", ".DS_Store", "Carthage", "vendor",
        ".vexp", ".claude", ".cursor", "ios/Pods", "android/.gradle",
    ]
    private let codeExt: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt",
        "md", "json", "yml", "yaml", "html", "css", "scss", "vue", "svelte",
    ]

    private init() {}

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Index (or re-index) a workspace into Application Support SQLite.
    /// Non-force: mtime-based incremental (only changed/new files + drop deleted).
    /// Force: full wipe rebuild.
    func index(workspace path: String, force: Bool = false) {
        guard !isIndexing else { return }
        let root = (path as NSString).standardizingPath
        isIndexing = true
        lastError = nil
        lastRoot = root

        Task.detached(priority: .userInitiated) { [ignore, codeExt] in
            let stats = Self.runIndex(root: root, force: force, ignore: ignore, codeExt: codeExt)
            await MainActor.run {
                self.isIndexing = false
                if let err = stats.error {
                    self.lastError = err
                } else {
                    self.lastRoot = root
                    self.openDB(root: root)
                    self.lastStats = stats.summary
                    self.refreshStatsFromDB()
                    // Prefer the detailed summary from the index pass when available
                    if !stats.summary.isEmpty {
                        self.lastStats = stats.summary + " · salvato"
                    }
                    AppLogger.info("ProjectCodeBrain indexed \(root): \(stats.summary)")
                }
            }
        }
    }

    /// Hot-path: re-parse a few relative paths after agent write/apply_patch (no full scan).
    func reindexRelativePaths(workspace path: String, relativePaths: [String]) {
        let root = (path as NSString).standardizingPath
        let rels = relativePaths
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        guard !rels.isEmpty else { return }
        // Don't block if full index running
        guard !isIndexing else { return }

        Task.detached(priority: .utility) { [codeExt] in
            let dbURL = Self.dbURL(for: root)
            var local: OpaquePointer?
            guard sqlite3_open(dbURL.path, &local) == SQLITE_OK, let local else { return }
            defer { sqlite3_close(local) }
            Self.migrate(db: local)

            var fileIdByRel = Self.loadFileIdMap(db: local)
            var touched = 0
            for rel in rels {
                let ext = (rel as NSString).pathExtension.lowercased()
                guard codeExt.contains(ext) else { continue }
                let full = (root as NSString).appendingPathComponent(rel)
                if !FileManager.default.fileExists(atPath: full) {
                    if let fid = fileIdByRel[rel] {
                        Self.deleteFileCascade(db: local, fileId: fid)
                        fileIdByRel.removeValue(forKey: rel)
                    }
                    continue
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)), data.count < 500_000,
                      let text = String(data: data, encoding: .utf8), !Self.looksSecret(text) else { continue }
                let mtime = Self.fileMTime(full)
                if let old = fileIdByRel[rel] {
                    Self.deleteFileCascade(db: local, fileId: old)
                }
                let fid = Self.insertFile(
                    db: local, root: root, rel: rel, lang: ext,
                    size: data.count, content: text, mtime: mtime
                )
                fileIdByRel[rel] = fid
                for sym in CodeStructure.extract(from: text, lang: ext, path: rel) {
                    Self.insertSymbol(db: local, fileId: fid, sym: sym)
                }
                // Rebuild outgoing edges for this file
                Self.deleteEdgesFrom(db: local, fileId: fid)
                for imp in CodeStructure.extractImports(from: text, lang: ext, fromRel: rel) {
                    if let tid = Self.resolveImport(imp, in: fileIdByRel) {
                        Self.insertEdge(db: local, from: fid, to: tid, kind: "import")
                    }
                }
                touched += 1
            }
            Self.setMeta(db: local, key: "indexed_at", value: ISO8601DateFormatter().string(from: Date()))
            await MainActor.run {
                if self.lastRoot == root {
                    self.openDB(root: root)
                    let n = self.db.map { Self.count(db: $0, table: "files") } ?? 0
                    self.lastStats = "\(n) file · hot +\(touched)"
                }
                AppLogger.info("ProjectCodeBrain hot reindex \(touched) path(s) in \(root)")
            }
        }
    }

    private struct IndexResult {
        var summary: String
        var error: String?
    }

    nonisolated private static func runIndex(
        root: String,
        force: Bool,
        ignore: Set<String>,
        codeExt: Set<String>
    ) -> IndexResult {
        let dbURL = Self.dbURL(for: root)
        var local: OpaquePointer?
        guard sqlite3_open(dbURL.path, &local) == SQLITE_OK, let local else {
            return IndexResult(summary: "", error: "SQLite open failed")
        }
        defer { sqlite3_close(local) }
        Self.migrate(db: local)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            return IndexResult(summary: "", error: "Impossibile scansionare \(root)")
        }

        // Existing index for incremental
        var existing = force ? [String: (id: Int64, size: Int, mtime: Double)]() : Self.loadFileMeta(db: local)
        if force {
            _ = Self.exec(db: local, """
                DELETE FROM files; DELETE FROM symbols; DELETE FROM edges;
                DELETE FROM files_fts; DELETE FROM symbols_fts;
                """)
            existing = [:]
        }

        var fileIdByRel: [String: Int64] = [:]
        for (rel, meta) in existing { fileIdByRel[rel] = meta.id }

        var fileCount = 0
        var symbolCount = 0
        var edgeCount = 0
        var updated = 0
        var skipped = 0
        var seen = Set<String>()

        while let rel = enumerator.nextObject() as? String {
            let parts = rel.split(separator: "/")
            if parts.contains(where: { ignore.contains(String($0)) }) {
                enumerator.skipDescendants()
                continue
            }
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            guard codeExt.contains(ext) else { continue }
            seen.insert(rel)

            let mtime = Self.fileMTime(full)
            if let old = existing[rel], !force, abs(old.mtime - mtime) < 0.5 {
                // Unchanged — keep id, count as present
                fileIdByRel[rel] = old.id
                fileCount += 1
                skipped += 1
                continue
            }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)), data.count < 500_000 else { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            if Self.looksSecret(text) { continue }

            if let old = fileIdByRel[rel] {
                Self.deleteFileCascade(db: local, fileId: old)
            }
            let fid = Self.insertFile(
                db: local, root: root, rel: rel, lang: ext,
                size: data.count, content: text, mtime: mtime
            )
            fileIdByRel[rel] = fid
            fileCount += 1
            updated += 1
            for sym in CodeStructure.extract(from: text, lang: ext, path: rel) {
                Self.insertSymbol(db: local, fileId: fid, sym: sym)
                symbolCount += 1
            }
            if fileCount >= 2500 { break }
        }

        // Drop deleted files from index
        let deleted = Set(existing.keys).subtracting(seen)
        for rel in deleted {
            if let fid = existing[rel]?.id {
                Self.deleteFileCascade(db: local, fileId: fid)
                fileIdByRel.removeValue(forKey: rel)
            }
        }

        // Rebuild all import edges (cheap vs wrong graph after partial updates)
        _ = Self.exec(db: local, "DELETE FROM edges;")
        for (rel, fid) in fileIdByRel {
            let full = (root as NSString).appendingPathComponent(rel)
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let imports = CodeStructure.extractImports(
                from: text, lang: (rel as NSString).pathExtension, fromRel: rel
            )
            for imp in imports {
                if let tid = Self.resolveImport(imp, in: fileIdByRel) {
                    Self.insertEdge(db: local, from: fid, to: tid, kind: "import")
                    edgeCount += 1
                }
            }
        }

        // Count symbols if incremental skipped many
        if symbolCount == 0 {
            symbolCount = Self.count(db: local, table: "symbols")
        }

        Self.setMeta(db: local, key: "indexed_at", value: ISO8601DateFormatter().string(from: Date()))
        Self.setMeta(db: local, key: "root", value: root)

        let mode = force ? "full" : "incr"
        let summary = "\(fileCount) file · \(symbolCount) symbol · \(edgeCount) edge · \(mode) +\(updated)/skip\(skipped)/-\(deleted.count)"
        return IndexResult(summary: summary, error: nil)
    }

    /// Prefer real source over docs / mirrored native copies (Capacitor public/).
    nonisolated private static func pathQualityBoost(_ relLow: String) -> Double {
        var b = 0.0
        if relLow.hasPrefix("docs/") || relLow.contains("/readme") || relLow.hasSuffix(".md") {
            b -= 4.5
        }
        // Native asset mirrors are sync copies — almost never the edit target.
        if relLow.hasPrefix("ios/") || relLow.hasPrefix("android/") {
            b -= 6.0
        }
        if relLow.contains("/public/") && (relLow.hasPrefix("ios/") || relLow.hasPrefix("android/")) {
            b -= 2.0
        }
        if relLow.hasSuffix(".js") || relLow.hasSuffix(".ts") || relLow.hasSuffix(".tsx")
            || relLow.hasSuffix(".css") || relLow.hasSuffix(".swift") {
            b += 2.5
        }
        if relLow.contains("premium-ui") || relLow.contains("game-feel") || relLow.contains("boot") {
            b += 3.5
        }
        // Orphan / additive CSS often FTS-matches "play" but is NOT linked from index.html → UI unchanged
        if relLow.contains("mobile-buttons") || relLow.contains("home-mobile") {
            b -= 8.0
        }
        // www/ is usually Capacitor BUILD output (gitignore) — demote vs Cursor-style source
        if relLow.hasPrefix("www/") {
            b -= 4.0
        }
        // Repo-root tracked shell (zackgame: premium-ui.css, index.html, …)
        if !relLow.contains("/"), relLow.hasSuffix(".css") || relLow.hasSuffix(".js") || relLow == "index.html" {
            b += 3.5
        }
        // Prefer the real home shell over lookalike CSS filenames
        if relLow == "premium-ui.css" || relLow == "premium-ui.js" || relLow == "index.html" {
            b += 4.0
        }
        if relLow.hasPrefix("src/") {
            b += 2.5
        }
        return b
    }

    /// Collapse Capacitor / www mirrors to one logical key so capsule doesn't paste 3× same CSS.
    nonisolated static func logicalPathKey(_ rel: String) -> String {
        var low = rel.replacingOccurrences(of: "\\", with: "/").lowercased()
        let prefixes = [
            "ios/app/app/public/",
            "android/app/src/main/assets/public/",
            "ios/app/app/",
            "android/app/src/main/assets/",
            "www/",
        ]
        for p in prefixes where low.hasPrefix(p) {
            low = String(low.dropFirst(p.count))
            break
        }
        return low
    }

    nonisolated private static func resolveImport(_ imp: String, in fileIdByRel: [String: Int64]) -> Int64? {
        if let tid = fileIdByRel[imp] { return tid }
        let cands = [
            imp, imp + ".ts", imp + ".tsx", imp + ".js", imp + ".jsx",
            imp + ".swift", imp + ".py", imp + ".go", imp + ".rs",
            imp + "/index.ts", imp + "/index.tsx", imp + "/index.js",
        ]
        for c in cands {
            if let tid = fileIdByRel[c] { return tid }
        }
        return nil
    }

    nonisolated private static func fileMTime(_ path: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let d = attrs?[.modificationDate] as? Date {
            return d.timeIntervalSince1970
        }
        return 0
    }

    nonisolated private static func loadFileMeta(db: OpaquePointer) -> [String: (id: Int64, size: Int, mtime: Double)] {
        var out: [String: (id: Int64, size: Int, mtime: Double)] = [:]
        let sql = "SELECT id, rel, size, mtime FROM files;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let rel = String(cString: sqlite3_column_text(stmt, 1))
                let size = Int(sqlite3_column_int(stmt, 2))
                let mtime = sqlite3_column_double(stmt, 3)
                out[rel] = (id, size, mtime)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    nonisolated private static func loadFileIdMap(db: OpaquePointer) -> [String: Int64] {
        var out: [String: Int64] = [:]
        let sql = "SELECT id, rel FROM files;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(stmt, 1))] = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    nonisolated private static func deleteFileCascade(db: OpaquePointer, fileId: Int64) {
        // Remove symbols + FTS
        let sqlSym = "SELECT id FROM symbols WHERE file_id=?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sqlSym, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, fileId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = sqlite3_column_int64(stmt, 0)
                _ = exec(db: db, "DELETE FROM symbols_fts WHERE rowid=\(sid);")
            }
        }
        sqlite3_finalize(stmt)
        _ = exec(db: db, "DELETE FROM symbols WHERE file_id=\(fileId);")
        _ = exec(db: db, "DELETE FROM edges WHERE from_id=\(fileId) OR to_id=\(fileId);")
        _ = exec(db: db, "DELETE FROM files_fts WHERE rowid=\(fileId);")
        _ = exec(db: db, "DELETE FROM files WHERE id=\(fileId);")
    }

    nonisolated private static func deleteEdgesFrom(db: OpaquePointer, fileId: Int64) {
        _ = exec(db: db, "DELETE FROM edges WHERE from_id=\(fileId);")
    }

    /// Cheap locator: ranked path:line · symbol — no bodies (for search_knowledge / 2nd look).
    func locate(query: String, limit: Int = 12) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "locate: query vuota" }
        guard let db else {
            return "locate: indice assente. Usa index_repo o attendi index workspace."
        }
        let raw = searchPivots(db: db, query: q, limit: max(limit * 3, 18))
        let pivots = Self.dedupePivots(raw, limit: limit)
        if pivots.isEmpty {
            return "locate: nessun hit per «\(q)». Prova nome file/simbolo (es. premium-ui prefersReducedMotion)."
        }
        var lines: [String] = ["# LOCATE · \(q)", ""]
        for p in pivots {
            lines.append(
                "- `\(p.rel):\(p.line)` · \(p.kind) \(p.name)  (score \(String(format: "%.1f", p.score)))"
            )
        }
        lines.append("")
        lines.append("_Poi: read_file path+around=LINE oppure repo_capsule. Non rileggere capsule intera._")
        return lines.joined(separator: "\n")
    }

    /// Token-bounded capsule: pivot bodies + neighbor skeletons.
    func capsule(query: String, budgetTokens: Int = 1800) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "repo_capsule: query vuota" }
        guard let db else {
            return "repo_capsule: indice assente. Apri workspace e attendi index, o tool index_repo."
        }

        // ~4 chars/token heuristic
        let budgetChars = max(800, budgetTokens * 4)
        var used = 0
        var out: [String] = ["# CAPSULE · \(q)", ""]

        let rawPivots = searchPivots(db: db, query: q, limit: 14)
        let pivots = Self.dedupePivots(rawPivots, limit: 4)
        if pivots.isEmpty {
            return "repo_capsule: nessun pivot per «\(q)». Prova termini di codice (nome funzione/file)."
        }

        out.append("## Pivots (full · deduped mirrors)")
        var pivotFileIds = Set<Int64>()
        for p in pivots {
            pivotFileIds.insert(p.fileId)
            let bodyCap = 720
            let block: String
            if let body = p.body, !body.isEmpty {
                let clipped = body.count > bodyCap ? String(body.prefix(bodyCap)) + "\n…" : body
                block = """
                ### \(p.rel):\(p.line) · \(p.kind) \(p.name)
                ```\(p.lang)
                \(clipped)
                ```
                """
            } else {
                let excerpt = fileExcerpt(db: db, fileId: p.fileId, around: p.line, window: 18)
                block = """
                ### \(p.rel):\(p.line) · \(p.kind) \(p.name)
                ```\(p.lang)
                \(excerpt)
                ```
                """
            }
            if used + block.count > budgetChars * 72 / 100 { break }
            out.append(block)
            used += block.count
        }

        out.append("")
        out.append("## Neighbors (skeleton)")
        let neighbors = Self.dedupeNeighbors(
            neighborSkeletons(db: db, pivotFileIds: pivotFileIds, limit: 28),
            limit: 14
        )
        for n in neighbors {
            let line = "- `\(n.rel)` · \(n.signature)"
            if used + line.count > budgetChars { break }
            out.append(line)
            used += line.count
        }

        out.append("")
        out.append("## Paths (ranked · edit these)")
        var seen = Set<String>()
        for p in pivots {
            if seen.insert(p.rel).inserted {
                out.append("- \(p.rel)  (score \(String(format: "%.1f", p.score)))")
            }
        }

        out.append("")
        out.append(
            "_chars≈\(used)/\(budgetChars) · read_file around=LINE · propose_patch su root/src (NON www/ build) · no ios/android · no list_dir enorme._"
        )
        return out.joined(separator: "\n")
    }

    /// Keep best-scoring path per logical file (drops ios/android/www duplicates).
    private static func dedupePivots(_ pivots: [Pivot], limit: Int) -> [Pivot] {
        var best: [String: Pivot] = [:]
        for p in pivots.sorted(by: { $0.score > $1.score }) {
            let key = logicalPathKey(p.rel)
            if best[key] == nil {
                best[key] = p
            }
        }
        return Array(best.values).sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private static func dedupeNeighbors(_ neighbors: [Neighbor], limit: Int) -> [Neighbor] {
        var seen = Set<String>()
        var out: [Neighbor] = []
        for n in neighbors {
            let key = logicalPathKey(n.rel)
            // Skip native mirrors entirely in skeleton
            let low = n.rel.lowercased()
            if low.hasPrefix("ios/") || low.hasPrefix("android/") { continue }
            if seen.insert(key).inserted {
                out.append(n)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Open persisted SQLite if present and refresh UI stats — agents query this DB via repo_capsule/locate.
    func ensureIndexed(workspace path: String) {
        let root = (path as NSString).standardizingPath
        let switched = lastRoot != root || db == nil
        if switched {
            openDB(root: root)
            lastRoot = root
            refreshStatsFromDB()
        }
        let n = db.map { Self.count(db: $0, table: "files") } ?? 0
        if n == 0 {
            // Nothing on disk yet → full/incr build
            index(workspace: root, force: false)
        } else if switched {
            // Disk hit: show counts immediately, then soft mtime incremental in background
            refreshStatsFromDB()
            index(workspace: root, force: false)
        }
        // else: already warm for this root — agents can capsule now
    }

    /// Reload file/symbol/edge counts from the open DB (survives app relaunch without re-click).
    func refreshStatsFromDB() {
        guard let db else {
            if lastStats.isEmpty { lastStats = "" }
            return
        }
        let files = Self.count(db: db, table: "files")
        let symbols = Self.count(db: db, table: "symbols")
        let edges = Self.count(db: db, table: "edges")
        if files > 0 {
            lastStats = "\(files) file · \(symbols) symbol · \(edges) edge · salvato"
            lastError = nil
        } else {
            lastStats = ""
        }
    }

    /// True when agents can query capsule/locate. Disk data is usable even while a soft reindex runs.
    var isReadyForAgents: Bool {
        guard let db else { return false }
        return Self.count(db: db, table: "files") > 0
    }

    // MARK: - Search / graph

    private struct Pivot {
        var fileId: Int64
        var rel: String
        var lang: String
        var name: String
        var kind: String
        var line: Int
        var body: String?
        var score: Double
    }

    private struct Neighbor {
        var rel: String
        var signature: String
    }

    private func searchPivots(db: OpaquePointer, query: String, limit: Int) -> [Pivot] {
        let terms = KnowledgeFTSIndex.tokenize(query)
        var scored: [Int64: (Pivot, Double)] = [:]

        // FTS symbols
        let ftsQ = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        if !ftsQ.isEmpty {
            let sql = """
            SELECT s.id, s.file_id, s.name, s.kind, s.line, s.signature, s.body, f.rel, f.lang,
                   bm25(symbols_fts) AS rank
            FROM symbols_fts
            JOIN symbols s ON s.id = symbols_fts.rowid
            JOIN files f ON f.id = s.file_id
            WHERE symbols_fts MATCH ?
            ORDER BY rank
            LIMIT 40;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, ftsQ, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let fileId = sqlite3_column_int64(stmt, 1)
                    let name = String(cString: sqlite3_column_text(stmt, 2))
                    let kind = String(cString: sqlite3_column_text(stmt, 3))
                    let line = Int(sqlite3_column_int(stmt, 4))
                    let sig = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? name
                    let body = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                    let rel = String(cString: sqlite3_column_text(stmt, 7))
                    let lang = String(cString: sqlite3_column_text(stmt, 8))
                    let rank = abs(sqlite3_column_double(stmt, 9))
                    var score = 10.0 / (1.0 + rank)
                    // Path boost / demote noise
                    let relLow = rel.lowercased()
                    for t in terms where relLow.contains(t) { score += 3 }
                    if name.lowercased().contains(terms.first ?? "§") { score += 4 }
                    score += Self.pathQualityBoost(relLow)
                    let pivot = Pivot(fileId: fileId, rel: rel, lang: lang, name: name, kind: kind, line: line, body: body ?? sig, score: score)
                    if let existing = scored[fileId], existing.1 >= score { continue }
                    scored[fileId] = (pivot, score)
                }
            }
            sqlite3_finalize(stmt)
        }

        // FTS files content
        if !ftsQ.isEmpty {
            let sql = """
            SELECT f.id, f.rel, f.lang, bm25(files_fts) AS rank
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY rank
            LIMIT 20;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, ftsQ, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let fileId = sqlite3_column_int64(stmt, 0)
                    if scored[fileId] != nil { continue }
                    let rel = String(cString: sqlite3_column_text(stmt, 1))
                    let lang = String(cString: sqlite3_column_text(stmt, 2))
                    let rank = abs(sqlite3_column_double(stmt, 3))
                    let relLow = rel.lowercased()
                    var score = 4.0 / (1.0 + rank) + Self.pathQualityBoost(relLow)
                    let pivot = Pivot(fileId: fileId, rel: rel, lang: lang, name: (rel as NSString).lastPathComponent, kind: "file", line: 1, body: nil, score: score)
                    scored[fileId] = (pivot, score)
                }
            }
            sqlite3_finalize(stmt)
        }

        // Graph boost: degree centrality
        for (fid, pair) in scored {
            let deg = edgeDegree(db: db, fileId: fid)
            var p = pair.0
            p.score = pair.1 + Double(min(deg, 12)) * 0.35
            scored[fid] = (p, p.score)
        }

        return scored.values.map(\.0).sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func neighborSkeletons(db: OpaquePointer, pivotFileIds: Set<Int64>, limit: Int) -> [Neighbor] {
        guard !pivotFileIds.isEmpty else { return [] }
        var out: [Neighbor] = []
        var seen = Set<Int64>()
        for fid in pivotFileIds {
            // outgoing + incoming
            let sql = """
            SELECT DISTINCT f.rel, s.kind, s.name, s.signature, f.id
            FROM edges e
            JOIN files f ON f.id = CASE WHEN e.from_id = ? THEN e.to_id ELSE e.from_id END
            LEFT JOIN symbols s ON s.file_id = f.id
            WHERE e.from_id = ? OR e.to_id = ?
            LIMIT 40;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, fid)
                sqlite3_bind_int64(stmt, 2, fid)
                sqlite3_bind_int64(stmt, 3, fid)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let nf = sqlite3_column_int64(stmt, 4)
                    if pivotFileIds.contains(nf) { continue }
                    if !seen.insert(nf).inserted { continue }
                    let rel = String(cString: sqlite3_column_text(stmt, 0))
                    let kind = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "file"
                    let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let sig = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "\(kind) \(name)"
                    out.append(Neighbor(rel: rel, signature: sig.isEmpty ? rel : sig))
                    if out.count >= limit { break }
                }
            }
            sqlite3_finalize(stmt)
            if out.count >= limit { break }
        }
        // If few edges, add top symbols from pivot files as skeleton
        if out.count < 4 {
            for fid in pivotFileIds {
                let sql = "SELECT f.rel, s.kind, s.name, s.signature FROM symbols s JOIN files f ON f.id=s.file_id WHERE s.file_id=? LIMIT 8;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, fid)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let rel = String(cString: sqlite3_column_text(stmt, 0))
                        let kind = String(cString: sqlite3_column_text(stmt, 1))
                        let name = String(cString: sqlite3_column_text(stmt, 2))
                        let sig = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "\(kind) \(name)"
                        out.append(Neighbor(rel: rel, signature: sig))
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
        return Array(out.prefix(limit))
    }

    private func fileExcerpt(db: OpaquePointer, fileId: Int64, around line: Int, window: Int) -> String {
        let sql = "SELECT content FROM files WHERE id=?;"
        var stmt: OpaquePointer?
        var text = ""
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, fileId)
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                text = String(cString: c)
            }
        }
        sqlite3_finalize(stmt)
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "(empty)" }
        let i = max(0, min(lines.count - 1, line - 1))
        let from = max(0, i - window)
        let to = min(lines.count - 1, i + window)
        return lines[from...to].joined(separator: "\n")
    }

    private func edgeDegree(db: OpaquePointer, fileId: Int64) -> Int {
        let sql = "SELECT COUNT(*) FROM edges WHERE from_id=? OR to_id=?;"
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, fileId)
            sqlite3_bind_int64(stmt, 2, fileId)
            if sqlite3_step(stmt) == SQLITE_ROW {
                n = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return n
    }

    // MARK: - DB lifecycle

    private func openDB(root: String) {
        if let db { sqlite3_close(db); self.db = nil }
        let url = Self.dbURL(for: root)
        // Ensure directory exists before open
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var ptr: OpaquePointer?
        if sqlite3_open_v2(url.path, &ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = ptr
            if let ptr {
                Self.migrate(db: ptr)
            }
            AppLogger.info("ProjectCodeBrain open \(url.lastPathComponent)")
        } else {
            lastError = "open db failed"
            AppLogger.error("ProjectCodeBrain open failed: \(url.path)")
        }
    }

    nonisolated private static func dbURL(for root: String) -> URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = app.appendingPathComponent("QSAgents/code-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = root.replacingOccurrences(of: "/", with: "_")
        let name = String(key.suffix(80)) + ".sqlite"
        return dir.appendingPathComponent(name)
    }

    nonisolated private static func migrate(db: OpaquePointer) {
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS files (
          id INTEGER PRIMARY KEY,
          rel TEXT NOT NULL,
          lang TEXT,
          size INTEGER,
          content TEXT,
          mtime REAL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS symbols (
          id INTEGER PRIMARY KEY,
          file_id INTEGER NOT NULL,
          name TEXT,
          kind TEXT,
          line INTEGER,
          signature TEXT,
          body TEXT,
          FOREIGN KEY(file_id) REFERENCES files(id)
        );
        CREATE TABLE IF NOT EXISTS edges (
          from_id INTEGER,
          to_id INTEGER,
          kind TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(rel, content, content='files', content_rowid='id');
        CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(name, signature, body, content='symbols', content_rowid='id');
        CREATE INDEX IF NOT EXISTS idx_sym_file ON symbols(file_id);
        CREATE INDEX IF NOT EXISTS idx_edge_from ON edges(from_id);
        CREATE INDEX IF NOT EXISTS idx_edge_to ON edges(to_id);
        """
        _ = exec(db: db, schema)
        // Backward-compatible column for incremental mtime index
        _ = exec(db: db, "ALTER TABLE files ADD COLUMN mtime REAL DEFAULT 0;")
    }

    @discardableResult
    nonisolated private static func exec(db: OpaquePointer, _ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { sqlite3_free(err) }
            return false
        }
        return true
    }

    nonisolated private static func count(db: OpaquePointer, table: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(table);"
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                n = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return n
    }

    nonisolated private static func metaDate(db: OpaquePointer, key: String) -> Date? {
        let sql = "SELECT v FROM meta WHERE k=?;"
        var stmt: OpaquePointer?
        var s: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                s = String(cString: c)
            }
        }
        sqlite3_finalize(stmt)
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    nonisolated private static func setMeta(db: OpaquePointer, key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO meta(k,v) VALUES(?,?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    nonisolated private static func insertFile(
        db: OpaquePointer,
        root: String,
        rel: String,
        lang: String,
        size: Int,
        content: String,
        mtime: Double = 0
    ) -> Int64 {
        let sql = "INSERT INTO files(rel, lang, size, content, mtime) VALUES(?,?,?,?,?);"
        var stmt: OpaquePointer?
        var id: Int64 = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, rel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, lang, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 3, Int32(size))
            sqlite3_bind_text(stmt, 4, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 5, mtime)
            if sqlite3_step(stmt) == SQLITE_DONE {
                id = sqlite3_last_insert_rowid(db)
                let fts = "INSERT INTO files_fts(rowid, rel, content) VALUES(?,?,?);"
                var s2: OpaquePointer?
                if sqlite3_prepare_v2(db, fts, -1, &s2, nil) == SQLITE_OK {
                    sqlite3_bind_int64(s2, 1, id)
                    sqlite3_bind_text(s2, 2, rel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(s2, 3, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    _ = sqlite3_step(s2)
                }
                sqlite3_finalize(s2)
            }
        }
        sqlite3_finalize(stmt)
        return id
    }

    nonisolated private static func insertSymbol(db: OpaquePointer, fileId: Int64, sym: CodeStructure.Symbol) {
        let sql = "INSERT INTO symbols(file_id, name, kind, line, signature, body) VALUES(?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, fileId)
            sqlite3_bind_text(stmt, 2, sym.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, sym.kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 4, Int32(sym.line))
            sqlite3_bind_text(stmt, 5, sym.signature, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, sym.body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_DONE {
                let id = sqlite3_last_insert_rowid(db)
                let fts = "INSERT INTO symbols_fts(rowid, name, signature, body) VALUES(?,?,?,?);"
                var s2: OpaquePointer?
                if sqlite3_prepare_v2(db, fts, -1, &s2, nil) == SQLITE_OK {
                    sqlite3_bind_int64(s2, 1, id)
                    sqlite3_bind_text(s2, 2, sym.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(s2, 3, sym.signature, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(s2, 4, sym.body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    _ = sqlite3_step(s2)
                }
                sqlite3_finalize(s2)
            }
        }
        sqlite3_finalize(stmt)
    }

    nonisolated private static func insertEdge(db: OpaquePointer, from: Int64, to: Int64, kind: String) {
        let sql = "INSERT INTO edges(from_id, to_id, kind) VALUES(?,?,?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, from)
            sqlite3_bind_int64(stmt, 2, to)
            sqlite3_bind_text(stmt, 3, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    nonisolated private static func looksSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("begin private key") { return true }
        if lower.contains("aws_secret") { return true }
        return false
    }
}

// MARK: - Lightweight structure parse (no tree-sitter dependency)

enum CodeStructure {
    struct Symbol {
        var name: String
        var kind: String
        var line: Int
        var signature: String
        var body: String
    }

    static func extract(from text: String, lang: String, path: String) -> [Symbol] {
        let lines = text.components(separatedBy: "\n")
        var out: [Symbol] = []
        let patterns: [(String, String)] // kind, regex
        switch lang {
        case "swift":
            patterns = [
                ("func", #"^\s*(?:public |private |internal |open |fileprivate )*(?:static |class )?func\s+(\w+)\s*\("#),
                ("class", #"^\s*(?:public |private |open )*class\s+(\w+)"#),
                ("struct", #"^\s*(?:public |private )*struct\s+(\w+)"#),
                ("enum", #"^\s*(?:public |private )*enum\s+(\w+)"#),
                ("protocol", #"^\s*(?:public |private )*protocol\s+(\w+)"#),
            ]
        case "ts", "tsx", "js", "jsx":
            patterns = [
                ("function", #"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)"#),
                ("class", #"^\s*(?:export\s+)?class\s+(\w+)"#),
                ("const", #"^\s*(?:export\s+)?const\s+(\w+)\s*="#),
                ("method", #"^\s*(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{"#),
            ]
        case "py":
            patterns = [
                ("def", #"^\s*(?:async\s+)?def\s+(\w+)\s*\("#),
                ("class", #"^\s*class\s+(\w+)"#),
            ]
        case "go":
            patterns = [
                ("func", #"^\s*func\s+(?:\([^)]+\)\s+)?(\w+)\s*\("#),
                ("type", #"^\s*type\s+(\w+)\s+"#),
            ]
        case "rs":
            patterns = [
                ("fn", #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)"#),
                ("struct", #"^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)"#),
                ("enum", #"^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)"#),
                ("trait", #"^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)"#),
            ]
        case "html":
            patterns = [
                ("id", #"id=[\"']([\w-]+)[\"']"#),
                ("class", #"class=[\"']([\w\s-]+)[\"']"#),
            ]
        default:
            patterns = [("symbol", #"\b([A-Z][A-Za-z0-9_]{3,})\b"#)]
        }

        for (i, line) in lines.enumerated() {
            for (kind, pat) in patterns {
                guard let re = try? NSRegularExpression(pattern: pat) else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: line) else { continue }
                let name = String(line[r]).trimmingCharacters(in: .whitespaces)
                guard name.count >= 2, name != "if", name != "for", name != "while" else { continue }
                let from = i
                let to = min(lines.count - 1, i + 28)
                let body = lines[from...to].joined(separator: "\n")
                let sig = line.trimmingCharacters(in: .whitespaces)
                out.append(Symbol(name: name, kind: kind, line: i + 1, signature: String(sig.prefix(160)), body: String(body.prefix(900))))
                if out.count >= 80 { return out }
            }
        }
        return out
    }

    static func extractImports(from text: String, lang: String, fromRel: String) -> [String] {
        var hits: [String] = []
        let lines = text.components(separatedBy: "\n").prefix(80)
        let dir = (fromRel as NSString).deletingLastPathComponent
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            // JS/TS: import ... from './x' or require('./x')
            if let re = try? NSRegularExpression(pattern: #"(?:from|require\()\s*['\"]([^'\"]+)['\"]"#),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)),
               m.numberOfRanges > 1,
               let rr = Range(m.range(at: 1), in: t) {
                let mod = String(t[rr])
                if mod.hasPrefix(".") {
                    let resolved = resolveRelative(fromDir: dir, importPath: mod)
                    hits.append(resolved)
                }
            }
            // Swift: import Module (skip — usually not files)
            // Python: from .x import
            if let re = try? NSRegularExpression(pattern: #"from\s+(\.[\w.]*)\s+import"#),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)),
               m.numberOfRanges > 1,
               let rr = Range(m.range(at: 1), in: t) {
                let mod = String(t[rr]).replacingOccurrences(of: ".", with: "/")
                // rough
                hits.append((dir as NSString).appendingPathComponent(String(mod.dropFirst())) + ".py")
            }
        }
        return hits
    }

    private static func resolveRelative(fromDir: String, importPath: String) -> String {
        var base = fromDir
        var path = importPath
        while path.hasPrefix("../") {
            base = (base as NSString).deletingLastPathComponent
            path = String(path.dropFirst(3))
        }
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        let joined = base.isEmpty ? path : (base as NSString).appendingPathComponent(path)
        // Caller resolves extensions against indexed files
        return joined
    }
}
