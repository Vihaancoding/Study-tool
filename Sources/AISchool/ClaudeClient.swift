import Foundation
import StudyCore

enum ClaudeError: LocalizedError {
    case noKey
    case http(Int, String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key yet. Add one in Settings to start lessons with Claude."
        case .http(let code, let msg):
            switch code {
            case 401: return "Anthropic rejected the API key (401). Check it in Settings."
            case 429: return "Rate limit reached (429). Wait a moment and try again."
            case 529, 503: return "Claude is busy right now (\(code)). Try again shortly."
            default: return "Claude API error \(code): \(msg)"
            }
        case .network(let m): return "Network problem: \(m)"
        case .badResponse: return "Claude sent a response the app could not read."
        }
    }
    var isRetryable: Bool {
        switch self {
        case .http(let c, _): return c == 429 || c == 529 || c == 503 || c == 500
        case .network: return true
        default: return false
        }
    }
}

struct ClaudeResponse {
    var content: [JSON]
    var stopReason: String
    var inputTokens: Int
    var outputTokens: Int
    var text: String { content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n") }
    var toolUses: [JSON] { content.filter { $0["type"]?.string == "tool_use" } }
}

/// Minimal Messages API client with tool use. Retries transient failures with backoff.
struct ClaudeClient {
    var apiKey: String
    var model: String
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func send(system: String, messages: [JSON], tools: [JSON], maxTokens: Int = 4096) async throws -> ClaudeResponse {
        var body: [String: JSON] = [
            "model": .s(model), "max_tokens": .i(maxTokens), "system": .s(system),
            "messages": .array(messages)
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        let payload = try JSONEncoder().encode(JSON.object(body))

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        var lastError: ClaudeError = .badResponse
        for attempt in 0..<4 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw ClaudeError.badResponse }
                if http.statusCode == 200 {
                    guard let j = try? JSONDecoder().decode(JSON.self, from: data), let content = j["content"]?.array else { throw ClaudeError.badResponse }
                    return ClaudeResponse(content: content, stopReason: j["stop_reason"]?.string ?? "end_turn",
                                          inputTokens: j["usage"]?["input_tokens"]?.int ?? 0, outputTokens: j["usage"]?["output_tokens"]?.int ?? 0)
                }
                var msg = String(data: data, encoding: .utf8) ?? ""
                if let j = try? JSONDecoder().decode(JSON.self, from: data), let m = j["error"]?["message"]?.string { msg = m }
                lastError = .http(http.statusCode, msg)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as ClaudeError {
                lastError = e
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = .network(error.localizedDescription)
            }
            if !lastError.isRetryable { throw lastError }
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
        }
        throw lastError
    }
}
