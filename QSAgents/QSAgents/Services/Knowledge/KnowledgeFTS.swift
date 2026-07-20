import Foundation

/// D1: lightweight full-text inverted index (FTS-like) over knowledge chunks.
/// Pure Swift — no SQLite dependency; rebuilds when KnowledgeStore finishes indexing.
struct KnowledgeFTSHit: Equatable {
    let chunkId: UUID
    let score: Double
}

@MainActor
final class KnowledgeFTSIndex {
    /// term → posting list of chunk ids
    private var postings: [String: [UUID]] = [:]
    private var docLen: [UUID: Int] = [:]
    private var avgDocLen: Double = 1
    private var docCount: Int = 0

    var isEmpty: Bool { docCount == 0 }

    func clear() {
        postings = [:]
        docLen = [:]
        avgDocLen = 1
        docCount = 0
    }

    func rebuild(chunks: [KnowledgeChunk]) {
        clear()
        guard !chunks.isEmpty else { return }
        var totalLen = 0
        for c in chunks {
            let tokens = Self.tokenize(
                c.relativePath + " " + c.symbols.joined(separator: " ") + " " + c.text
            )
            docLen[c.id] = tokens.count
            totalLen += tokens.count
            var seen = Set<String>()
            for t in tokens {
                if seen.insert(t).inserted {
                    postings[t, default: []].append(c.id)
                }
            }
        }
        docCount = chunks.count
        avgDocLen = max(1, Double(totalLen) / Double(docCount))
    }

    /// BM25-ish ranking over query terms.
    func search(query: String, limit: Int = 40) -> [KnowledgeFTSHit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty, docCount > 0 else { return [] }

        var scores: [UUID: Double] = [:]
        let k1 = 1.2
        let b = 0.75
        let N = Double(docCount)

        for term in terms {
            guard let docs = postings[term], !docs.isEmpty else { continue }
            let df = Double(docs.count)
            let idf = log((N - df + 0.5) / (df + 0.5) + 1)
            // term frequency ≈ 1 per doc in postings (presence); boost repeats via count in list
            var tfMap: [UUID: Int] = [:]
            for id in docs { tfMap[id, default: 0] += 1 }
            for (id, tf) in tfMap {
                let dl = Double(docLen[id] ?? 1)
                let tfD = Double(tf)
                let denom = tfD + k1 * (1.0 - b + b * (dl / avgDocLen))
                let norm = (tfD * (k1 + 1.0)) / max(denom, 0.0001)
                let prev = scores[id] ?? 0
                scores[id] = prev + idf * norm
            }
        }

        var hits: [KnowledgeFTSHit] = []
        hits.reserveCapacity(scores.count)
        for (id, score) in scores {
            hits.append(KnowledgeFTSHit(chunkId: id, score: score))
        }
        hits.sort { $0.score > $1.score }
        if hits.count > limit {
            return Array(hits.prefix(limit))
        }
        return hits
    }

    static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        var out: [String] = []
        var cur = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber || ch == "_" {
                cur.append(ch)
            } else if !cur.isEmpty {
                if cur.count >= 2 { out.append(cur) }
                cur = ""
            }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }
}
