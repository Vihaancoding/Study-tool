import Foundation

public struct SourceHit {
    public var resourceId: String
    public var chunkIndex: Int
    public var title: String
    public var kind: ResourceKind
    public var origin: ResourceOrigin
    public var text: String
    public var score: Double
    public var citation: String { "\(resourceId)#\(chunkIndex)" }
}

public enum TextChunker {
    /// Splits text into ~900 character chunks along paragraph boundaries. Stable for a given text.
    public static func chunks(_ text: String, target: Int = 900) -> [String] {
        let paras = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for p in paras {
            if p.count > target * 2 {
                flush()
                var start = p.startIndex
                while start < p.endIndex {
                    let end = p.index(start, offsetBy: target, limitedBy: p.endIndex) ?? p.endIndex
                    out.append(String(p[start..<end]))
                    start = end
                }
            } else if cur.count + p.count > target {
                flush(); cur = p
            } else {
                cur += (cur.isEmpty ? "" : "\n\n") + p
            }
        }
        flush()
        return out
    }

    static let stop: Set<String> = ["the", "and", "for", "that", "this", "with", "are", "was", "what", "how", "why", "does", "from", "about", "you", "your", "can", "not", "have", "has", "into", "its", "they", "their"]

    public static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
    }
}

extension StudyStore {
    /// Keyword search across resources. `forAI` restricts to material the student allows to be sent to Claude.
    public func searchSources(query: String, subjectId: String? = nil, topicId: String? = nil,
                              limit: Int = 6, forAI: Bool = true) -> [SourceHit] {
        let q = TextChunker.tokens(query)
        guard !q.isEmpty else { return [] }
        var hits: [SourceHit] = []
        for r in data.resources {
            if let s = subjectId, r.subjectId != s { continue }
            if forAI {
                if !r.shareWithAI { continue }
                if let sub = subject(r.subjectId), !sub.shareWithAI { continue }
            }
            let titleTokens = Set(TextChunker.tokens(r.title))
            let topicBonus = (topicId != nil && r.topicId == topicId) ? 2.0 : 0
            for (i, c) in TextChunker.chunks(r.text).enumerated() {
                let lower = c.lowercased()
                var score = topicBonus
                for t in q {
                    let n = lower.components(separatedBy: t).count - 1
                    if n > 0 { score += 1 + log(Double(n) + 1) }
                    if titleTokens.contains(t) { score += 0.5 }
                }
                if score > 0 {
                    hits.append(SourceHit(resourceId: r.id, chunkIndex: i, title: r.title, kind: r.kind,
                                          origin: r.origin, text: c, score: score))
                }
            }
        }
        // Prefer original material over Claude-generated notes when scores are close.
        hits.sort { ($0.score + ($0.origin == .claude ? -0.4 : 0)) > ($1.score + ($1.origin == .claude ? -0.4 : 0)) }
        return Array(hits.prefix(limit))
    }

    public func chunk(resourceId: String, index: Int) -> String? {
        guard let r = resource(resourceId) else { return nil }
        let cs = TextChunker.chunks(r.text)
        return index >= 0 && index < cs.count ? cs[index] : nil
    }
}
