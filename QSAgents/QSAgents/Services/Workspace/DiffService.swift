import Foundation

/// Unified-diff apply / preview (Fase 6 review flow).
enum DiffService {
    struct Hunk: Equatable {
        var header: String
        var lines: [String] // include leading +/ -/ space
    }

    struct FilePatch: Equatable, Identifiable {
        var id: String { path }
        var path: String
        var hunks: [Hunk]
    }

    static func parseUnified(_ text: String) -> [FilePatch] {
        var patches: [FilePatch] = []
        var currentPath: String?
        var hunks: [Hunk] = []
        var currentHunk: Hunk?

        func flushHunk() {
            if let h = currentHunk { hunks.append(h); currentHunk = nil }
        }
        func flushFile() {
            flushHunk()
            if let p = currentPath, !hunks.isEmpty {
                patches.append(FilePatch(path: p, hunks: hunks))
            }
            hunks = []
            currentPath = nil
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                // diff --git a/foo b/foo
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    var p = String(parts[3])
                    if p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
                    currentPath = p
                }
            } else if line.hasPrefix("+++ ") {
                var p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
                if p != "/dev/null" { currentPath = p }
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHunk = Hunk(header: line, lines: [])
            } else if currentHunk != nil {
                if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line == "\\ No newline at end of file" {
                    currentHunk?.lines.append(line)
                }
            }
        }
        flushFile()
        return patches
    }

    enum ApplyError: Error, CustomStringConvertible {
        case contextNotFound(String)
        var description: String {
            switch self {
            case .contextNotFound(let s): return s
            }
        }
    }

    /// Apply a single-file unified patch to `original`. Best-effort context match.
    static func apply(patch: FilePatch, to original: String) -> Result<String, ApplyError> {
        var lines = original.components(separatedBy: "\n")
        // Work bottom-up if multiple hunks with line numbers
        for hunk in patch.hunks {
            // Parse @@ -a,b +c,d @@
            let startOld: Int
            if let r = hunk.header.range(of: #"@@ -(\d+)"#, options: .regularExpression),
               let n = Int(hunk.header[r].dropFirst(4).split(separator: ",").first ?? "1") {
                startOld = max(1, n) - 1
            } else {
                startOld = 0
            }

            var oldSlice: [String] = []
            var newSlice: [String] = []
            for l in hunk.lines {
                if l.hasPrefix("\\") { continue }
                if l.hasPrefix("-") {
                    oldSlice.append(String(l.dropFirst()))
                } else if l.hasPrefix("+") {
                    newSlice.append(String(l.dropFirst()))
                } else if l.hasPrefix(" ") {
                    let body = String(l.dropFirst())
                    oldSlice.append(body)
                    newSlice.append(body)
                }
            }

            // Find oldSlice in lines near startOld
            let idx = find(slice: oldSlice, in: lines, near: startOld) ?? find(slice: oldSlice, in: lines, near: 0)
            guard let idx else {
                return .failure(.contextNotFound("Context non trovato per hunk \(hunk.header) in \(patch.path)"))
            }
            lines.replaceSubrange(idx..<(idx + oldSlice.count), with: newSlice)
        }
        return .success(lines.joined(separator: "\n"))
    }

    private static func find(slice: [String], in lines: [String], near: Int) -> Int? {
        guard !slice.isEmpty else { return near }
        let n = lines.count
        let s = slice.count
        guard s <= n else { return nil }
        // search from near outward
        for delta in 0..<n {
            for sign in [1, -1] {
                let i = near + sign * delta
                if i < 0 || i + s > n { continue }
                if Array(lines[i..<(i + s)]) == slice { return i }
            }
            if delta == 0 { continue }
        }
        return nil
    }

    static func previewHTML(old: String, new: String) -> String {
        let o = old.components(separatedBy: "\n")
        let n = new.components(separatedBy: "\n")
        var rows: [String] = []
        let maxL = max(o.count, n.count)
        for i in 0..<maxL {
            let a = i < o.count ? o[i] : ""
            let b = i < n.count ? n[i] : ""
            if a == b {
                rows.append("<div style='color:#9a9a9a'>\(escape(a))</div>")
            } else {
                if !a.isEmpty { rows.append("<div style='background:#3a1515;color:#ff8a80'>- \(escape(a))</div>") }
                if !b.isEmpty { rows.append("<div style='background:#153a15;color:#80ff8a'>+ \(escape(b))</div>") }
            }
        }
        return "<html><body style='background:#111;font:12px Menlo,monospace;padding:12px'>\(rows.joined())</body></html>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
