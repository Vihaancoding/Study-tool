import Foundation
import SwiftUI
import StudyCore

/// Runs the conversation with Claude for one lesson: sends messages, executes tool calls against the shared
/// store, and keeps the stored history valid even when a turn is interrupted or fails.
@MainActor
final class TeacherSession: ObservableObject {
    let lessonId: String
    private unowned let app: AppState
    @Published var isWorking = false
    @Published var status = ""
    @Published var errorText: String?
    private var task: Task<Void, Never>?
    private var lastUserText: String?

    init(lessonId: String, app: AppState) {
        self.lessonId = lessonId
        self.app = app
    }

    var lesson: LessonSession? { app.store.lesson(lessonId) }

    // MARK: Public

    /// Sends a student message. If Claude is mid-turn this interrupts it first.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lastUserText = t
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            await previous?.value
            await self?.runTurn(userText: t)
        }
    }

    func retry() {
        guard let t = lastUserText, !isWorking else { return }
        errorText = nil
        // The failed turn's user message is already stored; resume without duplicating it.
        task = Task { [weak self] in await self?.runTurn(userText: nil) }
    }

    func stop() {
        task?.cancel()
        status = "Stopped"
    }

    /// Asks Claude to wrap up; falls back to a local save so results are never lost.
    func endLesson() {
        guard let l = lesson, l.isActive else { return }
        if app.hasAPIKey && !l.messages.isEmpty {
            let previous = task
            previous?.cancel()
            task = Task { [weak self] in
                await previous?.value
                await self?.runTurn(userText: "Let's finish here. Please schedule reviews for what we covered, then call end_lesson with an honest summary and next steps.")
                self?.saveLocallyIfStillOpen()
            }
        } else {
            saveLocallyIfStillOpen()
        }
    }

    private func saveLocallyIfStillOpen() {
        guard let l = lesson, l.isActive else { return }
        let n = l.messages.filter { $0.role == .user }.count
        app.store.endLesson(l.id, summary: l.summary.isEmpty ? "Lesson ended (\(n) message\(n == 1 ? "" : "s") from you). No summary was written by Claude." : l.summary)
        if app.currentLessonId == l.id { app.currentLessonId = nil }
    }

    // MARK: Turn loop

    private func append(_ entry: ChatEntry) {
        app.store.updateLesson(lessonId) { $0.messages.append(entry) }
    }

    private func runTurn(userText: String?) async {
        guard let key = Keychain.read(), !key.isEmpty else {
            if let t = userText { append(ChatEntry(role: .user, text: t)) }
            errorText = ClaudeError.noKey.errorDescription
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false; if !Task.isCancelled { status = "" } }

        let store = app.store
        if let t = userText {
            append(ChatEntry(role: .user, text: t))
            store.updateLesson(lessonId) { l in
                l.apiHistory = HistoryRepair.repair(l.apiHistory)
                l.apiHistory.append(["role": "user", "content": .s(t)])
            }
        } else {
            store.updateLesson(lessonId) { $0.apiHistory = HistoryRepair.repair($0.apiHistory) }
        }

        let executor = ToolExecutor(store: store, lessonId: lessonId)
        let client = ClaudeClient(apiKey: key, model: store.data.settings.model)

        var iterations = 0
        while iterations < 14 {
            iterations += 1
            if Task.isCancelled { return }
            guard let lesson = store.lesson(lessonId) else { return }
            let (history, trimmed) = Self.prepareHistory(lesson.apiHistory)
            var system = TeacherPrompt.system(store: store, lesson: lesson) + TeacherPrompt.liveState(store: store, lesson: lesson)
            if trimmed { system += "\n- Earlier messages in this lesson were omitted to save space. Re-read context with get_student_context / whiteboard_read if you need it." }
            status = iterations == 1 ? "Claude is thinking…" : "Claude is continuing…"
            app.logOutbound("Request to Claude: \(history.count) messages, ~\((system.count + history.map { $0.serialized().count }.reduce(0, +)) / 1000) KB of text, \(ToolCatalog.all.count) tools. Model: \(client.model)")

            let response: ClaudeResponse
            do {
                response = try await client.send(system: system, messages: history, tools: ToolCatalog.apiJSON)
            } catch is CancellationError {
                return
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                append(ChatEntry(role: .system, text: errorText ?? "Request failed", isError: true))
                return
            }

            store.updateLesson(lessonId) { l in
                l.apiHistory.append(["role": "assistant", "content": .array(response.content)])
                if !response.text.isEmpty { l.messages.append(ChatEntry(role: .assistant, text: response.text)) }
            }
            let uses = response.toolUses
            if uses.isEmpty {
                if response.stopReason == "max_tokens" { append(ChatEntry(role: .system, text: "Claude's reply was cut off. Say “continue” to carry on.", isError: false)) }
                return
            }

            // Execute every tool call synchronously on the main actor so board/quiz/UI state stays consistent.
            var results: [JSON] = []
            for use in uses {
                let id = use["id"]?.string ?? ""
                let name = use["name"]?.string ?? ""
                let input = use["input"] ?? .object([:])
                status = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
                let r = executor.run(name: name, input: input)
                append(ChatEntry(role: .tool, text: r.summary, isError: r.isError))
                app.logOutbound("Sent to Claude from tool \(name): \(r.content.count) characters\(r.boardImageId != nil ? " + a picture of the board" : "")")
                var block: [String: JSON] = ["type": "tool_result", "tool_use_id": .s(id)]
                if r.isError { block["is_error"] = true }
                if let bid = r.boardImageId, let png = BoardRenderer.png(for: store.board(bid)) {
                    block["content"] = .array([
                        ["type": "text", "text": .s(r.content)],
                        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .s(png.base64EncodedString())]]
                    ])
                } else {
                    block["content"] = .s(r.content)
                }
                results.append(.object(block))
            }
            store.updateLesson(lessonId) { $0.apiHistory.append(["role": "user", "content": .array(results)]) }
            if store.lesson(lessonId)?.isActive == false && uses.contains(where: { $0["name"]?.string == "end_lesson" }) {
                if app.currentLessonId == lessonId { app.currentLessonId = nil }
                return
            }
        }
        append(ChatEntry(role: .system, text: "Stopped after many tool steps in a row. Tell Claude how to continue.", isError: false))
    }

    // MARK: History handling

    /// Bounds request size: drops old turns (at a clean user-message boundary) and removes old board images.
    static func prepareHistory(_ history: [JSON]) -> ([JSON], Bool) {
        var h = HistoryRepair.repair(history)
        var trimmed = false
        let maxMessages = 60
        if h.count > maxMessages {
            var start = h.count - 48
            while start < h.count && !isPlainUserMessage(h[start]) { start += 1 }
            if start < h.count { h = Array(h[start...]); trimmed = true }
        }
        // Keep only the most recent board image.
        var lastImageIndex: Int?
        for (i, m) in h.enumerated() where containsImage(m) { lastImageIndex = i }
        for (i, m) in h.enumerated() where containsImage(m) && i != lastImageIndex { h[i] = strippingImages(m) }
        return (h, trimmed)
    }

    private static func isPlainUserMessage(_ m: JSON) -> Bool {
        guard m["role"]?.string == "user" else { return false }
        if m["content"]?.string != nil { return true }
        guard let blocks = m["content"]?.array else { return false }
        return !blocks.contains { $0["type"]?.string == "tool_result" }
    }

    private static func containsImage(_ m: JSON) -> Bool {
        guard let blocks = m["content"]?.array else { return false }
        return blocks.contains { b in
            b["type"]?.string == "tool_result" && (b["content"]?.array ?? []).contains { $0["type"]?.string == "image" }
        }
    }

    private static func strippingImages(_ m: JSON) -> JSON {
        guard var o = m.object, let blocks = m["content"]?.array else { return m }
        o["content"] = .array(blocks.map { b -> JSON in
            guard var bo = b.object, let inner = b["content"]?.array else { return b }
            bo["content"] = .array(inner.filter { $0["type"]?.string != "image" })
            return .object(bo)
        })
        return .object(o)
    }
}
