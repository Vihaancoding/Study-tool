import Foundation

public enum UIEvent {
    case lessonOpened(String)       // lesson id
    case showBoard(String)          // board id
    case launchQuiz(String)         // quiz id
    case showSource(String)         // resource id
    case dataChanged
}

/// Single source of truth shared by the UI and by Claude's tools. Main-thread only.
public final class StudyStore {
    public private(set) var data: StudyData
    public var onChange: (() -> Void)?
    public var onUIEvent: ((UIEvent) -> Void)?
    public private(set) var lastSaveError: String?

    public let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("study-data.json") }
    private var saveScheduled = false
    private var undoStacks: [String: [BoardSnapshot]] = [:]
    private var redoStacks: [String: [BoardSnapshot]] = [:]

    struct BoardSnapshot { var objects: [BoardObject]; var step: Int; var background: String }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded = StudyData()
        let url = directory.appendingPathComponent("study-data.json")
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let v = try? dec.decode(StudyData.self, from: d) {
                loaded = v
            } else {
                // Never silently discard a file we cannot read: keep it for recovery.
                let stamp = DateCodec.full(Date()).replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("unreadable-\(stamp).json"))
                lastSaveError = "Your saved data could not be read; a copy was kept as unreadable-*.json. Restore from Settings → Backups."
            }
        }
        self.data = loaded
        repairInterruptedState()
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalAISchool", isDirectory: true)
    }

    // MARK: Persistence

    /// Applies a mutation, schedules a coalesced atomic save and notifies observers.
    public func mutate(_ change: (inout StudyData) -> Void) {
        change(&data)
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.flush() }
    }

    public func flush() {
        saveScheduled = false
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        do {
            let d = try enc.encode(data)
            try d.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = "Saving failed: \(error.localizedDescription)"
        }
    }

    /// Lessons left "mid-turn" by a crash: ensure the stored API history is valid to resume.
    private func repairInterruptedState() {
        for i in data.lessons.indices {
            data.lessons[i].apiHistory = HistoryRepair.repair(data.lessons[i].apiHistory)
        }
    }

    // MARK: Backups & export

    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    @discardableResult
    public func makeBackup(keep: Int = 15) throws -> URL {
        flush()
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let stamp = DateCodec.full(Date()).replacingOccurrences(of: ":", with: "-")
        let dest = backupsDirectory.appendingPathComponent("backup-\(stamp)-\(String(UUID().uuidString.prefix(4))).json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: dest)
        } else {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(data).write(to: dest)
        }
        let all = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        let sorted = all.filter { $0.lastPathComponent.hasPrefix("backup-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
        return dest
    }

    public func listBackups() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("backup-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Replaces all data with a backup after validating it decodes. A safety backup of current data is taken first.
    public func restore(from url: URL) throws {
        let d = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let restored = try dec.decode(StudyData.self, from: d)
        _ = try makeBackup()
        mutate { $0 = restored }
        undoStacks.removeAll(); redoStacks.removeAll()
        onUIEvent?(.dataChanged)
    }

    public func exportJSON(to url: URL) throws {
        flush()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(data).write(to: url, options: .atomic)
    }

    /// Human-readable study report (Markdown): progress, mistakes, schedule.
    public func exportMarkdown(to url: URL) throws {
        try exportMarkdownText().write(to: url, atomically: true, encoding: .utf8)
    }

    public func exportMarkdownText(now: Date = Date()) -> String {
        var md = "# Study report — \(DateCodec.day(now))\n\n"
        for s in data.subjects {
            md += "## \(s.name)\n\n"
            for t in topics(in: s.id) {
                let lvl = masteryLevel(topicId: t.id)
                md += "- **\(t.title)** — \(lvl.label)"
                if let p = data.progress[t.id], let due = p.due { md += " (review due \(DateCodec.day(due)))" }
                md += "\n"
            }
            let ms = data.mistakes.filter { $0.subjectId == s.id }
            if !ms.isEmpty {
                md += "\n### Mistakes\n\n"
                for m in ms.sorted(by: { $0.date > $1.date }) {
                    md += "- \(DateCodec.day(m.date)) · \(m.category.label)\(m.resolved ? " · resolved" : "")\n  - Q: \(m.question)\n  - My answer: \(m.studentAnswer)\n  - Correct reasoning: \(m.correctReasoning)\n"
                }
            }
            md += "\n"
        }
        return md
    }

    // MARK: Lookup helpers

    public func subject(_ id: String?) -> Subject? { id.flatMap { i in data.subjects.first { $0.id == i } } }
    public func topic(_ id: String?) -> Topic? { id.flatMap { i in data.topics.first { $0.id == i } } }
    public func topics(in subjectId: String) -> [Topic] { data.topics.filter { $0.subjectId == subjectId } }
    public func units(in subjectId: String) -> [CurriculumUnit] { data.units.filter { $0.subjectId == subjectId }.sorted { $0.order < $1.order } }
    public func resource(_ id: String?) -> Resource? { id.flatMap { i in data.resources.first { $0.id == i } } }
    public func quiz(_ id: String?) -> Quiz? { id.flatMap { i in data.quizzes.first { $0.id == i } } }
    public func attempt(_ id: String?) -> Attempt? { id.flatMap { i in data.attempts.first { $0.id == i } } }
    public func board(_ id: String?) -> Board? { id.flatMap { i in data.boards.first { $0.id == i } } }
    public func lesson(_ id: String?) -> LessonSession? { id.flatMap { i in data.lessons.first { $0.id == i } } }
    public var activeLesson: LessonSession? { data.lessons.filter { $0.isActive }.sorted { $0.startedAt > $1.startedAt }.first }

    // MARK: Subjects & curriculum CRUD

    @discardableResult
    public func addSubject(name: String, kind: SubjectKind) -> Subject {
        let s = MYP.makeSubject(name: name, kind: kind)
        mutate { $0.subjects.append(s) }
        return s
    }

    public func updateSubject(_ s: Subject) {
        mutate { d in if let i = d.subjects.firstIndex(where: { $0.id == s.id }) { d.subjects[i] = s } }
    }

    public func deleteSubject(_ id: String) {
        mutate { d in
            let topicIds = Set(d.topics.filter { $0.subjectId == id }.map { $0.id })
            d.subjects.removeAll { $0.id == id }
            d.units.removeAll { $0.subjectId == id }
            d.topics.removeAll { $0.subjectId == id }
            d.assessments.removeAll { $0.subjectId == id }
            d.resources.removeAll { $0.subjectId == id }
            d.mistakes.removeAll { $0.subjectId == id }
            d.quizzes.removeAll { $0.subjectId == id }
            d.attempts.removeAll { $0.subjectId == id }
            d.lessons.removeAll { $0.subjectId == id }
            d.boards.removeAll { $0.subjectId == id }
            d.schedule.removeAll { $0.subjectId == id }
            for t in topicIds { d.progress[t] = nil }
        }
    }

    @discardableResult
    public func addUnit(subjectId: String, title: String) -> CurriculumUnit {
        let u = CurriculumUnit(subjectId: subjectId, title: title, order: units(in: subjectId).count)
        mutate { $0.units.append(u) }
        return u
    }

    @discardableResult
    public func addTopic(subjectId: String, unitId: String? = nil, title: String, summary: String = "",
                         objectives: [Objective] = [], sourceRefs: [String] = [], origin: String = "student") -> Topic {
        let t = Topic(subjectId: subjectId, unitId: unitId, title: title, summary: summary,
                      objectives: objectives, sourceRefs: sourceRefs, origin: origin)
        mutate { $0.topics.append(t) }
        return t
    }

    public func updateTopic(_ t: Topic) {
        mutate { d in if let i = d.topics.firstIndex(where: { $0.id == t.id }) { d.topics[i] = t } }
    }

    public func deleteTopic(_ id: String) {
        mutate { d in
            d.topics.removeAll { $0.id == id }
            d.progress[id] = nil
            for i in d.assessments.indices { d.assessments[i].topicIds.removeAll { $0 == id } }
        }
    }

    public func updateUnit(_ u: CurriculumUnit) {
        mutate { d in if let i = d.units.firstIndex(where: { $0.id == u.id }) { d.units[i] = u } }
    }

    public func deleteUnit(_ id: String) {
        mutate { d in
            d.units.removeAll { $0.id == id }
            for i in d.topics.indices where d.topics[i].unitId == id { d.topics[i].unitId = nil }
        }
    }

    @discardableResult
    public func addAssessment(_ a: Assessment) -> Assessment {
        mutate { $0.assessments.append(a) }
        return a
    }

    public func updateAssessment(_ a: Assessment) {
        mutate { d in if let i = d.assessments.firstIndex(where: { $0.id == a.id }) { d.assessments[i] = a } }
    }

    public func deleteAssessment(_ id: String) { mutate { $0.assessments.removeAll { $0.id == id } } }

    // MARK: Resources

    @discardableResult
    public func addResource(_ r: Resource) -> Resource {
        mutate { $0.resources.append(r) }
        return r
    }

    public func updateResource(_ r: Resource) {
        mutate { d in if let i = d.resources.firstIndex(where: { $0.id == r.id }) { d.resources[i] = r } }
    }

    public func deleteResource(_ id: String) { mutate { $0.resources.removeAll { $0.id == id } } }

    // MARK: Boards (shared by the canvas and by Claude)

    @discardableResult
    public func createBoard(title: String, subjectId: String?, lessonId: String?) -> Board {
        let b = Board(title: title, subjectId: subjectId, lessonId: lessonId)
        mutate { $0.boards.append(b) }
        return b
    }

    public func deleteBoard(_ id: String) {
        mutate { $0.boards.removeAll { $0.id == id } }
        undoStacks[id] = nil; redoStacks[id] = nil
    }

    private func snapshot(_ b: Board) -> BoardSnapshot { BoardSnapshot(objects: b.objects, step: b.currentStep, background: b.background) }

    /// Mutates a board, recording an undo step (so the student can undo Claude's changes too).
    public func mutateBoard(_ id: String, undoable: Bool = true, animate: Bool = false, _ change: (inout Board) -> Void) {
        guard let i = data.boards.firstIndex(where: { $0.id == id }) else { return }
        if undoable {
            undoStacks[id, default: []].append(snapshot(data.boards[i]))
            if undoStacks[id]!.count > 150 { undoStacks[id]!.removeFirst() }
            redoStacks[id] = []
        }
        mutate { d in
            change(&d.boards[i])
            d.boards[i].updatedAt = Date()
            d.boards[i].animate = animate
        }
    }

    public func canUndo(_ id: String) -> Bool { !(undoStacks[id] ?? []).isEmpty }
    public func canRedo(_ id: String) -> Bool { !(redoStacks[id] ?? []).isEmpty }

    public func undoBoard(_ id: String) {
        guard var stack = undoStacks[id], let snap = stack.popLast(), let i = data.boards.firstIndex(where: { $0.id == id }) else { return }
        redoStacks[id, default: []].append(snapshot(data.boards[i]))
        undoStacks[id] = stack
        mutate { d in d.boards[i].objects = snap.objects; d.boards[i].currentStep = snap.step; d.boards[i].background = snap.background; d.boards[i].animate = false }
    }

    public func redoBoard(_ id: String) {
        guard var stack = redoStacks[id], let snap = stack.popLast(), let i = data.boards.firstIndex(where: { $0.id == id }) else { return }
        undoStacks[id, default: []].append(snapshot(data.boards[i]))
        redoStacks[id] = stack
        mutate { d in d.boards[i].objects = snap.objects; d.boards[i].currentStep = snap.step; d.boards[i].background = snap.background; d.boards[i].animate = false }
    }

    /// Validated, atomic structured actions from Claude.
    public func applyBoardActions(boardId: String, actions: [JSON]) throws -> (created: [[String]], summary: JSON) {
        guard let current = board(boardId) else { throw ToolError("unknown board_id '\(boardId)'") }
        if actions.isEmpty { throw ToolError("'actions' must contain at least one action") }
        if actions.count > 120 { throw ToolError("too many actions in one call (max 120)") }
        var trial = current
        let created = try trial.applyBatch(actions)   // throws before touching stored state
        let usesMotion = actions.contains { ["move", "update", "set_motion"].contains($0["type"]?.string ?? "") }
        mutateBoard(boardId, animate: usesMotion) { $0 = trial; $0.animate = usesMotion }
        onUIEvent?(.showBoard(boardId))
        return (created, trial.summary(limit: 60))
    }

    // MARK: Lessons

    @discardableResult
    public func startLesson(subjectId: String, topicId: String?, title: String, objectives: [String] = []) -> LessonSession {
        // Close any other active lesson first so state stays consistent.
        if let active = activeLesson { endLesson(active.id, summary: active.summary.isEmpty ? "Ended when a new lesson started." : active.summary) }
        let board = createBoard(title: title, subjectId: subjectId, lessonId: nil)
        let style = data.settings.teachingStyle
        let l = LessonSession(subjectId: subjectId, topicId: topicId, title: title, objectives: objectives,
                              boardId: board.id, style: style)
        mutate { d in
            d.lessons.append(l)
            if let bi = d.boards.firstIndex(where: { $0.id == board.id }) { d.boards[bi].lessonId = l.id }
        }
        onUIEvent?(.lessonOpened(l.id))
        return l
    }

    public func updateLesson(_ id: String, _ change: (inout LessonSession) -> Void) {
        mutate { d in if let i = d.lessons.firstIndex(where: { $0.id == id }) { change(&d.lessons[i]) } }
    }

    public func endLesson(_ id: String, summary: String?, topicsCovered: [String] = [], nextSteps: [String] = []) {
        updateLesson(id) { l in
            if l.endedAt == nil { l.endedAt = Date() }
            if let s = summary, !s.isEmpty { l.summary = s }
            if !topicsCovered.isEmpty { l.topicsCovered = topicsCovered }
            if !nextSteps.isEmpty { l.nextSteps = nextSteps }
        }
        // A lesson touches its topic: mark as studied so "recently studied" and scheduling reflect reality.
        if let l = lesson(id) {
            for tid in Set(l.topicsCovered + (l.topicId.map { [$0] } ?? [])) where topic(tid) != nil {
                mutate { d in
                    var p = d.progress[tid] ?? TopicProgress(topicId: tid)
                    p.lastStudied = Date()
                    d.progress[tid] = p
                }
            }
        }
    }

    // MARK: Schedule

    @discardableResult
    public func addScheduleItem(_ item: ScheduleItem) -> ScheduleItem {
        mutate { $0.schedule.append(item) }
        return item
    }

    public func updateScheduleItem(_ item: ScheduleItem) {
        mutate { d in if let i = d.schedule.firstIndex(where: { $0.id == item.id }) { d.schedule[i] = item } }
    }

    public func deleteScheduleItem(_ id: String) { mutate { $0.schedule.removeAll { $0.id == id } } }
}

/// Makes a stored Claude message history valid again after an interrupted turn
/// (e.g. the app quit between a tool_use and its tool_result).
public enum HistoryRepair {
    public static func repair(_ history: [JSON]) -> [JSON] {
        var out = history
        // Drop trailing assistant message with unanswered tool_use by answering with an error result.
        if let last = out.last, last["role"]?.string == "assistant", let blocks = last["content"]?.array {
            let uses = blocks.filter { $0["type"]?.string == "tool_use" }
            if !uses.isEmpty {
                let results: [JSON] = uses.compactMap { (u: JSON) -> JSON? in
                    guard let id = u["id"]?.string else { return nil }
                    return ["type": "tool_result", "tool_use_id": .s(id), "is_error": true,
                            "content": "Interrupted before this tool ran. State may be unchanged; call whiteboard_read or get_student_context to re-sync."]
                }
                out.append(["role": "user", "content": .array(results)])
            }
        }
        // Every tool_use in an assistant message must be answered in the next user message.
        var fixed: [JSON] = []
        for (i, m) in out.enumerated() {
            fixed.append(m)
            guard m["role"]?.string == "assistant", let blocks = m["content"]?.array else { continue }
            let useIds = blocks.compactMap { $0["type"]?.string == "tool_use" ? $0["id"]?.string : nil }
            if useIds.isEmpty { continue }
            let next = i + 1 < out.count ? out[i + 1] : nil
            let answered = Set((next?["content"]?.array ?? []).compactMap { $0["type"]?.string == "tool_result" ? $0["tool_use_id"]?.string : nil })
            let missing = useIds.filter { !answered.contains($0) }
            if !missing.isEmpty && next != nil {
                // Insert a repair message before the next message.
                let res: [JSON] = missing.map { ["type": "tool_result", "tool_use_id": .s($0), "is_error": true, "content": "Interrupted."] }
                fixed.append(["role": "user", "content": .array(res)])
            }
        }
        return fixed
    }
}
