import Foundation

public struct ToolResult {
    public var content: String
    public var isError: Bool
    public var boardImageId: String?     // ask the app to attach a rendering of this board
    public var summary: String           // short line for the UI activity log
}

/// Executes Claude's tool calls against the shared store. Every input is validated before state changes.
public final class ToolExecutor {
    public let store: StudyStore
    public var lessonId: String?
    private let maxResultChars = 14000

    public init(store: StudyStore, lessonId: String?) {
        self.store = store
        self.lessonId = lessonId
    }

    private var lesson: LessonSession? { store.lesson(lessonId) }

    public func run(name: String, input: JSON) -> ToolResult {
        do {
            var imageId: String?
            let (out, summary) = try dispatch(name, Args(input, context: name), &imageId)
            var s = out.serialized()
            if s.count > maxResultChars { s = String(s.prefix(maxResultChars)) + "…[truncated; narrow your request]" }
            return ToolResult(content: s, isError: false, boardImageId: imageId, summary: summary)
        } catch let e as ToolError {
            return ToolResult(content: "Error: \(e.message)", isError: true, boardImageId: nil, summary: "\(name) failed: \(e.message)")
        } catch {
            return ToolResult(content: "Error: \(error.localizedDescription)", isError: true, boardImageId: nil, summary: "\(name) failed")
        }
    }

    // MARK: Dispatch

    private func dispatch(_ name: String, _ a: Args, _ imageId: inout String?) throws -> (JSON, String) {
        switch name {
        case "get_student_context": return (try studentContext(a), "Read your learning profile")
        case "list_curriculum": return (try listCurriculum(a), "Looked up the curriculum")
        case "search_sources": return try searchSources(a)
        case "read_source": return try readSource(a)
        case "get_mistakes": return (try getMistakes(a), "Checked your mistake log")
        case "open_lesson": return try openLesson(a)
        case "whiteboard_apply": return try whiteboardApply(a)
        case "whiteboard_read":
            let id = try boardId(a)
            guard let b = store.board(id) else { throw ToolError("unknown board_id") }
            imageId = id
            return (b.summary(), "Looked at the whiteboard")
        case "create_quiz": return try createQuiz(a)
        case "get_quiz_results": return try getQuizResults(a)
        case "mark_response": return try markResponse(a)
        case "log_mistake": return try logMistake(a)
        case "record_understanding": return try recordUnderstanding(a)
        case "schedule_review": return try scheduleReview(a)
        case "curriculum_add": return try curriculumAdd(a)
        case "save_note": return try saveNote(a)
        case "end_lesson": return try endLesson(a)
        default: throw ToolError("unknown tool '\(name)'")
        }
    }

    // MARK: Helpers

    private func requireSubject(_ a: Args, _ key: String = "subject_id") throws -> Subject {
        let id = try a.string(key, maxLength: 40)
        guard let s = store.subject(id) else { throw ToolError("unknown \(key) '\(id)'. Call get_student_context to see valid ids.") }
        return s
    }

    private func optTopic(_ a: Args, _ key: String = "topic_id", subject: String? = nil) throws -> Topic? {
        guard let id = try a.optString(key, maxLength: 40) else { return nil }
        guard let t = store.topic(id) else { throw ToolError("unknown \(key) '\(id)'") }
        if let s = subject, t.subjectId != s { throw ToolError("topic '\(id)' belongs to a different subject") }
        return t
    }

    private func boardId(_ a: Args) throws -> String {
        if let id = try a.optString("board_id", maxLength: 40) {
            guard store.board(id) != nil else { throw ToolError("unknown board_id '\(id)'") }
            return id
        }
        guard let l = lesson else { throw ToolError("no active lesson, so board_id is required") }
        return l.boardId
    }

    private func dateJSON(_ d: Date?) -> JSON { d.map { JSON.s(DateCodec.day($0)) } ?? .null }

    // MARK: Context

    private func studentContext(_ a: Args) throws -> JSON {
        let now = Date()
        let st = store.data
        var out: [String: JSON] = [
            "today": .s(DateCodec.day(now)),
            "student": ["name": .s(st.student.name), "year_group": .s(st.student.yearGroup), "notes": .s(st.student.notes)],
            "teaching_style_preference": .s(st.settings.teachingStyle)
        ]
        var gaps: [String] = []
        if st.subjects.isEmpty { gaps.append("No subjects exist yet.") }
        if st.resources.isEmpty { gaps.append("No source material has been imported — teach from general knowledge and say so; do not claim it comes from their notes.") }
        if st.topics.isEmpty { gaps.append("No topics/syllabus saved — ask what they are studying or use curriculum_add once you know.") }
        if st.attempts.isEmpty && st.mistakes.isEmpty { gaps.append("No quiz or mistake history yet — check understanding with questions before assuming anything.") }

        let focusId = try a.optString("subject_id", maxLength: 40)
        let focusSubject: Subject? = focusId.flatMap { store.subject($0) }
        if let id = focusId, focusSubject == nil { throw ToolError("unknown subject_id '\(id)'") }

        let subjects = focusSubject.map { [$0] } ?? st.subjects
        var subj: [JSON] = []
        for s in subjects where s.shareWithAI {
            var topicsJSON: [JSON] = []
            for t in store.topics(in: s.id) {
                let p = st.progress[t.id]
                var d: [String: JSON] = ["id": .s(t.id), "title": .s(t.title), "mastery": .s(store.masteryLevel(topicId: t.id).rawValue)]
                if let u = t.unitId, let unit = st.units.first(where: { $0.id == u }) { d["unit"] = .s(unit.title) }
                if let due = p?.due { d["review_due"] = .s(DateCodec.day(due)); d["is_due"] = .b(due <= now) }
                if let acc = store.recentAccuracy(topicId: t.id) { d["recent_accuracy_pct"] = .i(Int((acc.score * 100).rounded())); d["recent_questions"] = .i(acc.count) }
                if let last = p?.lastStudied { d["last_studied"] = .s(DateCodec.day(last)) }
                if let n = p?.understandingNote { d["last_observation"] = .s(n) }
                let open = store.unresolvedMistakes(topicId: t.id).count
                if open > 0 { d["unresolved_mistakes"] = .i(open) }
                if !t.objectives.isEmpty { d["objectives"] = .strings(t.objectives.prefix(6).map { $0.text }) }
                topicsJSON.append(.object(d))
            }
            let resources = st.resources.filter { $0.subjectId == s.id && $0.shareWithAI }
            var sd: [String: JSON] = [:]
            sd["id"] = .s(s.id)
            sd["name"] = .s(s.name)
            sd["type"] = .s(s.kind.rawValue)
            sd["framework"] = .s(s.framework)
            sd["teaching_focus"] = .s(s.kind.teachingFocus)
            sd["teacher_notes"] = .s(s.teachingNotes)
            var crit: [JSON] = []
            for c in s.criteria { crit.append(.object(["code": .s(c.code), "name": .s(c.name), "descriptor": .s(c.descriptor)])) }
            sd["criteria"] = .array(crit)
            sd["topics"] = .array(topicsJSON)
            var resJSON: [JSON] = []
            for r in resources.prefix(40) { resJSON.append(.object(["id": .s(r.id), "title": .s(r.title), "kind": .s(r.kind.rawValue), "origin": .s(r.origin.rawValue)])) }
            sd["resources"] = .array(resJSON)
            subj.append(.object(sd))
        }
        out["subjects"] = .array(subj)

        let sid = focusSubject?.id
        let patterns = store.errorPatterns(subjectId: sid).prefix(6).map { p -> JSON in
            ["category": .s(p.category.rawValue), "total": .i(p.count), "last_14_days": .i(p.recentCount), "topics": .strings(p.topicTitles)]
        }
        out["recurring_error_patterns"] = .array(Array(patterns))
        out["upcoming_assessments"] = .array(store.upcomingAssessments(now: now).filter { sid == nil || $0.subjectId == sid }.prefix(6).map { x -> JSON in
            let prep = store.preparation(for: x)
            return ["id": .s(x.id), "title": .s(x.title), "date": dateJSON(x.date), "subject": .opt(store.subject(x.subjectId)?.name),
                    "criteria": .strings(x.criteria), "topics_total": .i(prep.total), "topics_studied": .i(prep.studied), "topics_secure": .i(prep.secure)]
        })
        out["due_for_review"] = .array(store.dueTopics(now: now, subjectId: sid).prefix(8).map { ["id": .s($0.id), "title": .s($0.title)] })
        out["recommended_next"] = .array(store.recommendations(now: now).filter { sid == nil || $0.subjectId == sid }.prefix(4).map {
            ["topic_id": .opt($0.topicId), "title": .s($0.title), "reasons": .strings($0.reasons)]
        })
        let lessons = st.lessons.filter { !$0.isActive && !$0.summary.isEmpty && (sid == nil || $0.subjectId == sid) }.sorted { $0.startedAt > $1.startedAt }.prefix(3)
        out["recent_lessons"] = .array(lessons.map { ["date": .s(DateCodec.day($0.startedAt)), "title": .s($0.title), "summary": .s($0.summary), "next_steps": .strings($0.nextSteps)] })
        if let l = lesson { out["current_lesson"] = ["id": .s(l.id), "title": .s(l.title), "board_id": .s(l.boardId), "subject_id": .s(l.subjectId)] }
        if !gaps.isEmpty { out["data_gaps"] = .strings(gaps) }
        return .object(out)
    }

    private func listCurriculum(_ a: Args) throws -> JSON {
        let s = try requireSubject(a)
        var topics: [JSON] = []
        for t in store.topics(in: s.id) {
            var objs: [JSON] = []
            for o in t.objectives { objs.append(.object(["text": .s(o.text), "criterion": .opt(o.criterion)])) }
            var d: [String: JSON] = [:]
            d["id"] = .s(t.id); d["title"] = .s(t.title); d["unit_id"] = .opt(t.unitId)
            d["summary"] = .s(t.summary); d["objectives"] = .array(objs)
            topics.append(.object(d))
        }
        var crit: [JSON] = []
        for c in s.criteria { crit.append(.object(["code": .s(c.code), "name": .s(c.name), "descriptor": .s(c.descriptor)])) }
        var terms: [JSON] = []
        for c in s.commandTerms { terms.append(.object(["term": .s(c.term), "definition": .s(c.definition)])) }
        var units: [JSON] = []
        for u in store.units(in: s.id) { units.append(.object(["id": .s(u.id), "title": .s(u.title)])) }
        var asms: [JSON] = []
        for x in store.data.assessments where x.subjectId == s.id {
            var d: [String: JSON] = [:]
            d["id"] = .s(x.id); d["title"] = .s(x.title); d["date"] = dateJSON(x.date)
            d["criteria"] = .strings(x.criteria); d["topic_ids"] = .strings(x.topicIds); d["has_result"] = .b(x.result != nil)
            asms.append(.object(d))
        }
        var out: [String: JSON] = [:]
        out["subject"] = .s(s.name); out["criteria"] = .array(crit); out["command_terms"] = .array(terms)
        out["units"] = .array(units); out["topics"] = .array(topics); out["assessments"] = .array(asms)
        return .object(out)
    }

    // MARK: Sources

    private func searchSources(_ a: Args) throws -> (JSON, String) {
        let q = try a.string("query", maxLength: 300)
        let sid = try a.optString("subject_id", maxLength: 40)
        if let s = sid, store.subject(s) == nil { throw ToolError("unknown subject_id '\(s)'") }
        let limit = try a.optInt("limit", range: 1...10) ?? 5
        let hits = store.searchSources(query: q, subjectId: sid, topicId: try a.optString("topic_id", maxLength: 40), limit: limit)
        let items = hits.map { h -> JSON in
            ["citation": .s(h.citation), "resource": .s(h.title), "kind": .s(h.kind.rawValue), "origin": .s(h.origin.rawValue),
             "text": .s(String(h.text.prefix(900)))]
        }
        return (["results": .array(items), "how_to_cite": "Write [[src:CITATION]] after claims drawn from a result.",
                 "note": .s(hits.isEmpty ? "No matching material found. Say so rather than inventing a source." : "")],
                "Searched your notes for “\(q)” (\(hits.count) found)")
    }

    private func readSource(_ a: Args) throws -> (JSON, String) {
        let id = try a.string("resource_id", maxLength: 40)
        guard let r = store.resource(id) else { throw ToolError("unknown resource_id '\(id)'") }
        guard r.shareWithAI, store.subject(r.subjectId)?.shareWithAI != false else { throw ToolError("the student has not allowed this resource to be shared with you") }
        let chunks = TextChunker.chunks(r.text)
        let from = try a.optInt("from_chunk", range: 0...100000) ?? 0
        let n = try a.optInt("max_chunks", range: 1...8) ?? 4
        guard from < chunks.count || chunks.isEmpty else { throw ToolError("from_chunk is past the end (resource has \(chunks.count) chunks)") }
        let slice = chunks.enumerated().filter { $0.offset >= from && $0.offset < from + n }
        return (["resource_id": .s(r.id), "title": .s(r.title), "kind": .s(r.kind.rawValue), "origin": .s(r.origin.rawValue), "total_chunks": .i(chunks.count),
                 "chunks": .array(slice.map { ["citation": .s("\(r.id)#\($0.offset)"), "text": .s($0.element)] })],
                "Read “\(r.title)”")
    }

    private func getMistakes(_ a: Args) throws -> JSON {
        let only = try a.optBool("only_unresolved") ?? true
        let limit = try a.optInt("limit", range: 1...30) ?? 10
        let sid = try a.optString("subject_id", maxLength: 40)
        let tid = try a.optString("topic_id", maxLength: 40)
        let cat = try a.optOneOf("category", ErrorCategory.allCases.map { $0.rawValue })
        let list = store.data.mistakes.filter { m in
            (sid == nil || m.subjectId == sid) && (tid == nil || m.topicId == tid) && (cat == nil || m.category.rawValue == cat) && (!only || !m.resolved)
        }.sorted { $0.date > $1.date }.prefix(limit)
        return ["mistakes": .array(list.map { m -> JSON in
            ["id": .s(m.id), "date": .s(DateCodec.day(m.date)), "topic": .opt(store.topic(m.topicId)?.title), "topic_id": .opt(m.topicId),
             "category": .s(m.category.rawValue), "question": .s(m.question), "student_answer": .s(m.studentAnswer),
             "correct_reasoning": .s(m.correctReasoning), "criterion": .opt(m.criterion), "resolved": .b(m.resolved),
             "follow_ups": .array(m.followUps.map { ["date": .s(DateCodec.day($0.date)), "correct": .b($0.correct)] })]
        })]
    }

    // MARK: Lesson & board

    private func openLesson(_ a: Args) throws -> (JSON, String) {
        guard let l = lesson else { throw ToolError("no active lesson") }
        let title = try a.string("title", maxLength: 120)
        let topic = try optTopic(a, subject: l.subjectId)
        let objectives = try a.stringArray("objectives", max: 8) ?? l.objectives
        store.updateLesson(l.id) { $0.title = title; $0.objectives = objectives; if let t = topic { $0.topicId = t.id } }
        store.mutateBoard(l.boardId, undoable: false) { $0.title = title }
        store.onUIEvent?(.lessonOpened(l.id))
        return (["ok": true, "lesson_id": .s(l.id), "board_id": .s(l.boardId)], "Opened lesson: \(title)")
    }

    private func whiteboardApply(_ a: Args) throws -> (JSON, String) {
        let id = try boardId(a)
        let actions = try a.array("actions", max: 120)
        let (created, summary) = try store.applyBoardActions(boardId: id, actions: actions)
        let count = created.reduce(0) { $0 + $1.count }
        return (["ok": true, "board_id": .s(id), "actions_applied": .i(actions.count),
                 "created_ids_per_action": .array(created.map { .strings($0.count > 12 ? Array($0.prefix(12)) + ["…"] : $0) }),
                 "board": summary],
                "Updated the whiteboard (\(actions.count) action\(actions.count == 1 ? "" : "s"), \(count) object\(count == 1 ? "" : "s"))")
    }

    // MARK: Quizzes

    private func createQuiz(_ a: Args) throws -> (JSON, String) {
        let subject = try requireSubject(a)
        let title = try a.string("title", maxLength: 120)
        let mode = QuizMode(rawValue: try a.optOneOf("mode", QuizMode.allCases.map { $0.rawValue }) ?? "practice") ?? .practice
        var limit: Int? = nil
        if let m = try a.optInt("time_limit_minutes", range: 1...180) { limit = m * 60 }
        if (mode == .timed || mode == .exam) && limit == nil { throw ToolError("time_limit_minutes is required for \(mode.rawValue) quizzes") }
        let qs = try a.elements("questions", max: 40)
        if qs.isEmpty { throw ToolError("a quiz needs at least one question") }
        var questions: [Question] = []
        for q in qs { questions.append(try parseQuestion(q, subject: subject)) }
        let quiz = Quiz(subjectId: subject.id, title: title, mode: mode, timeLimitSeconds: limit, questions: questions, createdBy: "claude", lessonId: lessonId)
        store.addQuiz(quiz)
        if try a.optBool("launch") ?? true { store.onUIEvent?(.launchQuiz(quiz.id)) }
        return (["ok": true, "quiz_id": .s(quiz.id), "question_ids": .strings(questions.map { $0.id }), "total_marks": .i(quiz.totalMarks),
                 "launched": .b(try a.optBool("launch") ?? true),
                 "next": "Wait for the student to submit, then call get_quiz_results. Do not reveal answers before they submit."],
                "Created quiz “\(title)” (\(questions.count) questions)")
    }

    private func parseQuestion(_ q: Args, subject: Subject) throws -> Question {
        let raw = try q.oneOf("type", ToolCatalog.questionTypes)
        let typeMap: [String: QuestionType] = ["single": .single, "multi": .multi, "true_false": .trueFalse, "short": .short, "extended": .extended,
                                               "calculation": .calculation, "equation_completion": .equationCompletion, "diagram_label": .diagramLabel]
        let type = typeMap[raw] ?? .short
        var out = Question(type: type, prompt: try q.string("prompt", maxLength: 4000))
        out.marks = try q.optInt("marks", range: 1...20) ?? (type == .extended ? 4 : 1)
        out.hint = try q.optString("hint", maxLength: 1000)
        out.modelAnswer = try q.optString("model_answer", maxLength: 4000) ?? ""
        out.rubric = try q.optString("rubric", maxLength: 4000) ?? ""
        out.commandTerm = try q.optString("command_term", maxLength: 40)
        out.difficulty = try q.optInt("difficulty", range: 1...3) ?? 2
        out.sourceRefs = try q.stringArray("source_refs", max: 10) ?? []
        if let t = try optTopic(q, subject: subject.id) { out.topicId = t.id }
        if let c = try q.optString("criterion", maxLength: 10) {
            guard subject.criteria.isEmpty || subject.criteria.contains(where: { $0.code == c }) else {
                throw ToolError("\(q.context): criterion '\(c)' is not defined for \(subject.name) (valid: \(subject.criteria.map { $0.code }.joined(separator: ", ")))")
            }
            out.criterion = c
        }
        if let m = try q.optString("tests_mistake_id", maxLength: 40) {
            guard store.data.mistakes.contains(where: { $0.id == m }) else { throw ToolError("\(q.context): unknown tests_mistake_id '\(m)'") }
            out.testsMistakeId = m
        }
        switch type {
        case .single, .multi:
            out.options = try q.stringArray("options", max: 8) ?? []
            if out.options.count < 2 { throw ToolError("\(q.context): needs at least 2 options") }
            out.correct = try q.intArray("correct") ?? []
            if out.correct.isEmpty { throw ToolError("\(q.context): 'correct' (option indices) is required") }
            if out.correct.contains(where: { $0 < 0 || $0 >= out.options.count }) { throw ToolError("\(q.context): 'correct' index out of range (0-\(out.options.count - 1))") }
            if Set(out.correct).count != out.correct.count { throw ToolError("\(q.context): duplicate indices in 'correct'") }
            if type == .single && out.correct.count != 1 { throw ToolError("\(q.context): a single-choice question has exactly one correct option; use type 'multi' otherwise") }
        case .trueFalse:
            out.options = ["True", "False"]
            guard let v = try q.optBool("correct_answer") else { throw ToolError("\(q.context): 'correct_answer' (true/false) is required") }
            out.correct = [v ? 0 : 1]
        case .short:
            out.acceptable = try q.stringArray("acceptable_answers", max: 20) ?? []
            out.keywords = try q.stringArray("keywords", max: 20) ?? []
            if out.acceptable.isEmpty && out.keywords.isEmpty && out.modelAnswer.isEmpty {
                throw ToolError("\(q.context): short answers need acceptable_answers, keywords or a model_answer so they can be marked")
            }
        case .extended:
            if out.rubric.isEmpty && out.modelAnswer.isEmpty { throw ToolError("\(q.context): extended responses need a rubric and/or model_answer") }
        case .calculation:
            let ans = try q.number("answer")
            let unit = try q.optString("unit", maxLength: 40)
            out.calc = CalcSpec(answer: ans, tolerancePercent: try q.optNumber("tolerance_percent", range: 0...50) ?? 1, unit: unit,
                                unitAlternatives: try q.stringArray("unit_alternatives", max: 8) ?? [],
                                sigFigs: try q.optInt("sig_figs", range: 1...10), requireWorking: try q.optBool("require_working") ?? false)
            if out.calc?.sigFigs != nil && out.marks < 2 { out.marks = 2 }
        case .equationCompletion:
            out.blanks = try q.stringArray("blanks", max: 10) ?? []
            if out.blanks.isEmpty { throw ToolError("\(q.context): 'blanks' (the answers) is required") }
            let slots = out.prompt.components(separatedBy: "___").count - 1
            if slots != out.blanks.count { throw ToolError("\(q.context): prompt has \(slots) '___' slot(s) but 'blanks' has \(out.blanks.count) answers") }
        case .diagramLabel:
            let labels = try q.elements("labels", max: 20)
            if labels.isEmpty { throw ToolError("\(q.context): needs at least one label") }
            for (i, l) in labels.enumerated() {
                out.labels.append(LabelTarget(id: "L\(i + 1)", x: try l.number("x", range: BoardLimits.coord), y: try l.number("y", range: BoardLimits.coord),
                                              answer: try l.string("answer", maxLength: 200), acceptable: try l.stringArray("acceptable", max: 8) ?? []))
            }
            out.labelBank = try q.stringArray("label_bank", max: 30) ?? []
            if let b = try q.optString("board_id", maxLength: 40) {
                guard store.board(b) != nil else { throw ToolError("\(q.context): unknown board_id '\(b)'") }
                out.boardId = b
            } else if let l = lesson { out.boardId = l.boardId }
            if out.marks < out.labels.count { out.marks = out.labels.count }
        }
        return out
    }

    private func getQuizResults(_ a: Args) throws -> (JSON, String) {
        var att: Attempt?
        if let id = try a.optString("attempt_id", maxLength: 40) {
            att = store.attempt(id)
            if att == nil { throw ToolError("unknown attempt_id '\(id)'") }
        } else {
            var qid = try a.optString("quiz_id", maxLength: 40)
            if qid == nil, let l = lesson { qid = l.quizIds.last }
            guard let q = qid, store.quiz(q) != nil else { throw ToolError("no quiz found; pass quiz_id") }
            att = store.data.attempts.last { $0.quizId == q && $0.submittedAt != nil }
            if att == nil {
                let draft = store.data.attempts.last { $0.quizId == q }
                return (["status": "not_submitted", "quiz_id": .s(q),
                         "detail": .s(draft == nil ? "The student has not started this quiz." : "The student is still working; they have not submitted. Do not guess their answers.")],
                        "Checked quiz status (not submitted)")
            }
        }
        guard let a2 = att else { throw ToolError("attempt not found") }
        var json = store.attemptJSON(a2)
        if case .object(var o) = json {
            let pending = a2.marks.filter { $0.pending }.count
            o["questions_needing_your_marking"] = .i(pending)
            json = .object(o)
        }
        return (json, "Read your quiz answers")
    }

    private func markResponse(_ a: Args) throws -> (JSON, String) {
        let id = try a.string("attempt_id", maxLength: 40)
        let marks = try a.elements("marks", max: 60)
        if marks.isEmpty { throw ToolError("'marks' must not be empty") }
        let applied = try store.applyClaudeMarks(attemptId: id, marks: marks)
        guard let att = store.attempt(id) else { throw ToolError("attempt vanished") }
        let still = att.marks.filter { $0.pending }.map { $0.questionId }
        var next: String
        if att.finalized {
            let lost = att.marks.filter { $0.awarded < Double($0.max) }.count
            next = lost > 0 ? "Finalised and mistakes logged. Now explain the errors, then give a NEW question that tests the correction (use tests_mistake_id), and schedule_review." : "Finalised. Praise specifically, then schedule_review with a longer interval."
        } else { next = "Still waiting for marks on: \(still.joined(separator: ", "))." }
        return (["ok": true, "marks_applied": .i(applied), "finalized": .b(att.finalized), "score": .n(att.awardedTotal), "out_of": .i(att.maxMarked),
                 "still_pending_question_ids": .strings(still), "next": .s(next)],
                "Marked \(applied) answer\(applied == 1 ? "" : "s")")
    }

    // MARK: Records

    private func logMistake(_ a: Args) throws -> (JSON, String) {
        let s = try requireSubject(a)
        let t = try optTopic(a, subject: s.id)
        let cat = ErrorCategory(rawValue: try a.oneOf("category", ErrorCategory.allCases.map { $0.rawValue })) ?? .other
        let m = Mistake(subjectId: s.id, topicId: t?.id, question: try a.string("question", maxLength: 3000),
                        studentAnswer: try a.string("student_answer", maxLength: 3000),
                        correctReasoning: try a.string("correct_reasoning", maxLength: 3000), category: cat,
                        criterion: try a.optString("criterion", maxLength: 10), lessonId: lessonId, marksLost: 0)
        store.mutate { $0.mistakes.append(m) }
        return (["ok": true, "mistake_id": .s(m.id), "tip": "Use tests_mistake_id in create_quiz to retest this."], "Saved a mistake to your log")
    }

    private func recordUnderstanding(_ a: Args) throws -> (JSON, String) {
        guard let t = try optTopic(a) else { throw ToolError("topic_id is required") }
        let level = try a.oneOf("level", ["none", "partial", "secure"])
        let evidence = try a.string("evidence", maxLength: 1000)
        let score: Double = level == "secure" ? 0.85 : (level == "partial" ? 0.55 : 0.2)
        store.recordScore(topicId: t.id, score: score, weight: 1, source: "lesson:\(lessonId ?? "-")")
        store.mutate { d in
            var p = d.progress[t.id] ?? TopicProgress(topicId: t.id)
            p.understandingNote = "\(DateCodec.day(Date())): \(level) — \(evidence)"
            d.progress[t.id] = p
        }
        return (["ok": true, "mastery_now": .s(store.masteryLevel(topicId: t.id).rawValue),
                 "note": "Lesson observations carry low weight; a quiz is needed to confirm mastery."], "Noted your understanding of \(t.title)")
    }

    private func scheduleReview(_ a: Args) throws -> (JSON, String) {
        guard let t = try optTopic(a) else { throw ToolError("topic_id is required") }
        let days = try a.int("in_days", range: 0...120)
        let notify = try a.optBool("notify") ?? true
        let note = try a.optString("note", maxLength: 300) ?? ""
        let cal = Calendar.current
        var due = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        if days > 0 { due = cal.date(bySettingHour: 17, minute: 0, second: 0, of: due) ?? due }
        store.mutate { d in
            var p = d.progress[t.id] ?? TopicProgress(topicId: t.id)
            p.due = due
            d.progress[t.id] = p
            d.schedule.removeAll { $0.kind == .review && $0.topicId == t.id && !$0.done && $0.createdBy == "claude" }
            d.schedule.append(ScheduleItem(kind: .review, subjectId: t.subjectId, topicId: t.id, title: "Review: \(t.title)",
                                           body: note.isEmpty ? "A short review of \(t.title)." : note, due: due, notify: notify, createdBy: "claude"))
        }
        return (["ok": true, "topic": .s(t.title), "due": .s(DateCodec.day(due)), "notification": .b(notify)], "Scheduled a review of \(t.title) for \(DateCodec.day(due))")
    }

    private func curriculumAdd(_ a: Args) throws -> (JSON, String) {
        let items = try a.elements("items", max: 60)
        if items.isEmpty { throw ToolError("'items' must not be empty") }
        // Validate everything first so a bad item changes nothing.
        struct Planned { var kind: String; var subject: Subject; var args: Args }
        var plan: [Planned] = []
        for it in items {
            let kind = try it.oneOf("kind", ["unit", "topic", "assessment"])
            let subject = try requireSubject(it)
            _ = try it.string("title", maxLength: 200)
            if kind == "assessment", let d = try it.optString("date", maxLength: 40), DateCodec.parse(d) == nil { throw ToolError("\(it.context): date '\(d)' must be YYYY-MM-DD") }
            plan.append(Planned(kind: kind, subject: subject, args: it))
        }
        var created: [JSON] = []
        for p in plan {
            let title = try p.args.string("title", maxLength: 200)
            switch p.kind {
            case "unit":
                if let existing = store.units(in: p.subject.id).first(where: { $0.title.lowercased() == title.lowercased() }) {
                    created.append(["kind": "unit", "id": .s(existing.id), "existing": true])
                } else {
                    let u = store.addUnit(subjectId: p.subject.id, title: title)
                    created.append(["kind": "unit", "id": .s(u.id)])
                }
            case "topic":
                var unitId = try p.args.optString("unit_id", maxLength: 40)
                if let uid = unitId, !store.units(in: p.subject.id).contains(where: { $0.id == uid }) { throw ToolError("unknown unit_id '\(uid)'") }
                if unitId == nil, let ut = try p.args.optString("unit_title", maxLength: 200) {
                    unitId = store.units(in: p.subject.id).first(where: { $0.title.lowercased() == ut.lowercased() })?.id ?? store.addUnit(subjectId: p.subject.id, title: ut).id
                }
                if let existing = store.topics(in: p.subject.id).first(where: { $0.title.lowercased() == title.lowercased() }) {
                    created.append(["kind": "topic", "id": .s(existing.id), "existing": true]); continue
                }
                var objs: [Objective] = []
                for o in try p.args.optArray("objectives", max: 30) ?? [] {
                    let oa = Args(o, context: "objective")
                    objs.append(Objective(text: try oa.string("text", maxLength: 500), criterion: try oa.optString("criterion", maxLength: 10)))
                }
                let t = store.addTopic(subjectId: p.subject.id, unitId: unitId, title: title, summary: try p.args.optString("summary", maxLength: 1000) ?? "",
                                       objectives: objs, sourceRefs: try p.args.stringArray("source_refs", max: 10) ?? [], origin: "claude")
                created.append(["kind": "topic", "id": .s(t.id)])
            default:
                var topicIds: [String] = []
                for tt in try p.args.stringArray("topic_titles", max: 30) ?? [] {
                    if let t = store.topics(in: p.subject.id).first(where: { $0.title.lowercased() == tt.lowercased() }) { topicIds.append(t.id) }
                }
                let date = try p.args.optString("date", maxLength: 40).flatMap { DateCodec.parse($0) }
                let asm = store.addAssessment(Assessment(subjectId: p.subject.id, title: title, date: date, criteria: try p.args.stringArray("criteria", max: 8) ?? [],
                                                         topicIds: topicIds, sourceRef: try p.args.stringArray("source_refs", max: 10)?.first))
                created.append(["kind": "assessment", "id": .s(asm.id)])
            }
        }
        return (["ok": true, "created": .array(created)], "Added \(created.count) curriculum item\(created.count == 1 ? "" : "s")")
    }

    private func saveNote(_ a: Args) throws -> (JSON, String) {
        let s = try requireSubject(a)
        let t = try optTopic(a, subject: s.id)
        let r = Resource(subjectId: s.id, topicId: t?.id, title: try a.string("title", maxLength: 150), kind: .note, origin: .claude,
                         text: try a.string("text", maxLength: 12000), sourceName: "Written by Claude")
        store.addResource(r)
        return (["ok": true, "resource_id": .s(r.id), "origin": "claude"], "Saved a note: \(r.title)")
    }

    private func endLesson(_ a: Args) throws -> (JSON, String) {
        guard let l = lesson else { throw ToolError("no active lesson") }
        let summary = try a.string("summary", maxLength: 3000)
        var covered: [String] = []
        for id in try a.stringArray("topics_covered", max: 20) ?? [] {
            guard store.topic(id) != nil else { throw ToolError("unknown topic id '\(id)' in topics_covered") }
            covered.append(id)
        }
        store.endLesson(l.id, summary: summary, topicsCovered: covered, nextSteps: try a.stringArray("next_steps", max: 10) ?? [])
        store.onUIEvent?(.dataChanged)
        return (["ok": true, "saved": true], "Lesson saved")
    }
}

