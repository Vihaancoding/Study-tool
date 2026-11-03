import Foundation

public struct ImportedDoc {
    public var title: String
    public var kind: ResourceKind
    public var text: String
    public var sourceName: String
    public init(title: String, kind: ResourceKind, text: String, sourceName: String) {
        self.title = title; self.kind = kind; self.text = text; self.sourceName = sourceName
    }
}

/// Parses plain text, Markdown, CSV, HTML and chat exports (Claude / ChatGPT `conversations.json`).
/// PDF and RTF are handled in the app target (they need Apple frameworks).
public enum Importer {
    public static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "html", "htm", "text"]

    public static func parse(data: Data, filename: String, kindHint: ResourceKind?) throws -> [ImportedDoc] {
        let ext = (filename as NSString).pathExtension.lowercased()
        let base = (filename as NSString).deletingPathExtension
        if ext == "json" {
            let docs = parseChatExport(data, filename: filename)
            if !docs.isEmpty { return docs }
        }
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ToolError("\(filename) is not readable text")
        }
        if ext == "html" || ext == "htm" { text = stripHTML(text) }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolError("\(filename) is empty") }
        return [ImportedDoc(title: base, kind: kindHint ?? .note, text: text, sourceName: filename)]
    }

    static func stripHTML(_ s: String) -> String {
        var t = s
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        t = t.replacingOccurrences(of: "</p>", with: "\n\n").replacingOccurrences(of: "<br>", with: "\n")
        if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// Handles a Claude export (array of conversations with `chat_messages`) and a ChatGPT export (`mapping`).
    static func parseChatExport(_ data: Data, filename: String) -> [ImportedDoc] {
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }
        let convs: [JSON]
        if let a = json.array { convs = a } else if json.object != nil { convs = [json] } else { return [] }
        var out: [ImportedDoc] = []
        for c in convs {
            var lines: [String] = []
            if let msgs = c["chat_messages"]?.array {
                for m in msgs {
                    let sender = m["sender"]?.string ?? m["role"]?.string ?? "unknown"
                    var text = m["text"]?.string ?? ""
                    if text.isEmpty, let parts = m["content"]?.array {
                        text = parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
                    }
                    if !text.isEmpty { lines.append("\(sender == "human" ? "Student" : "Claude"): \(text)") }
                }
            } else if let mapping = c["mapping"]?.object {
                var nodes: [(Double, String)] = []
                for (_, node) in mapping {
                    guard let msg = node["message"], let role = msg["author"]?["role"]?.string, role != "system" else { continue }
                    let parts = msg["content"]?["parts"]?.array?.compactMap { $0.string } ?? []
                    let text = parts.joined(separator: "\n")
                    if text.isEmpty { continue }
                    nodes.append((msg["create_time"]?.double ?? 0, "\(role == "user" ? "Student" : "Assistant"): \(text)"))
                }
                lines = nodes.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            if lines.isEmpty { continue }
            let title = c["name"]?.string ?? c["title"]?.string ?? "Conversation \(out.count + 1)"
            out.append(ImportedDoc(title: title.isEmpty ? "Conversation \(out.count + 1)" : title, kind: .chat,
                                   text: lines.joined(separator: "\n\n"), sourceName: filename))
        }
        return out
    }
}
