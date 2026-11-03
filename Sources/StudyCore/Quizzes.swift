import Foundation

extension StudyStore {

    // MARK: Creation

    @discardableResult
    public func addQuiz(_ q: Quiz) -> Quiz {
        mutate { d in
            d.quizzes.append(q)
            if let lid = q.lessonId, let i = d.lessons.firstIndex(where: { $0.id == lid }) { d.lessons[i].quizIds.append(q.id) }
        }
        return q
    }

    /// Every question ever created, one entry per question id (the reusable question bank).
    public func questionBank(subjectId: String? = nil) -> [Question] {
        var seen = Set<String>()
        var out: [Question] = []
        for quiz in data.quizzes where subjectId == nil || quiz.subjectId == subjectId {
            for q in quiz.questions where !seen.contains(q.id) { seen.insert(q.id); out.append(q) }
        }
        return out
    }

    private func lastResult(for questionId: String) -> (score: Double, date: Date)? {
        var best: (Double, Date)?
        for a in data.attempts where a.finalized {
            if let m = a.marks.first(where: { $0.questionId == questionId && !$0.pending }), m.max > 0 {
                let when = a.submittedAt ?? a.startedAt
                if best == nil || when > best!.1 { best = (m.awarded / Double(m.max), when) }
            }
        }
        return best.map { (score: $0.0, date: $0.1) }
    }

    /// Builds a quiz from the existing bank without needing Claude.
    /// - quick/retrieval: due & weak topics first, mixed.  adaptive: weighted to weak topics.  exam: whole subject, timed.
    public func buildQuizFromBank(mode: QuizMode, subjectId: String?, count: Int = 6, now: Date = Date()) -> Quiz? {
        let bank = questionBank(subjectId: subjectId)
        guard !bank.isEmpty else { return nil }
        let dueIds = Set(dueTopics(now: now, subjectId: subjectId).map { $0.id })
        let weakIds = Set(weakTopics(subjectId: subjectId).map { $0.id })
        func priority(_ q: Question) -> Double {
            var p = Double.random(in: 0...0.5)
            if let t = q.topicId {
                if weakIds.contains(t) { p += 3 }
                if dueIds.contains(t) { p += 2 }
            }
            if let r = lastResult(for: q.id) {
                p += (1 - r.score) * 2                                    // missed before -> sooner
                let days = now.timeIntervalSince(r.date) / 86400
                p += min(days, 14) * 0.1                                  // not seen for a while
            } else { p += 1 }                                             // never attempted
            return p
        }
        // Score each question once (the score includes a random tie-breaker, so it must not be recomputed while sorting).
        let scores = Dictionary(bank.map { ($0.id, priority($0)) }, uniquingKeysWith: { a, _ in a })
        func ranked() -> [Question] { bank.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) } }
        var picked: [Question]
        switch mode {
        case .retrieval:
            // Mix topics: take best from each topic round-robin.
            let grouped = Dictionary(grouping: ranked(), by: { $0.topicId ?? "-" })
            var queues = grouped.values.map { Array($0) }
            picked = []
            while picked.count < count && queues.contains(where: { !$0.isEmpty }) {
                for i in queues.indices where !queues[i].isEmpty && picked.count < count { picked.append(queues[i].removeFirst()) }
            }
        case .exam:
            picked = Array(bank.shuffled().prefix(max(count, 10)))
        default:
            picked = Array(ranked().prefix(count))
        }
        guard !picked.isEmpty else { return nil }
        let sid = subjectId ?? picked.first.flatMap { q in data.quizzes.first { $0.questions.contains { $0.id == q.id } }?.subjectId } ?? ""
        let minutes = picked.reduce(0) { $0 + max(1, $1.marks) }
        let limit: Int? = (mode == .exam || mode == .timed) ? max(5, minutes) * 60 : nil
        let title = mode == .exam ? "Exam simulation" : (mode == .adaptive ? "Adaptive practice" : (mode == .retrieval ? "Mixed retrieval" : "Quick quiz"))
        return Quiz(subjectId: sid, title: title, mode: mode, timeLimitSeconds: limit, questions: picked, createdBy: "app")
    }

    // MARK: Attempts

    public func startAttempt(quizId: String) -> Attempt? {
        guard let q = quiz(quizId) else { return nil }
        // Resume an unsubmitted attempt rather than creating duplicates.
        if let existing = data.attempts.last(where: { $0.quizId == quizId && $0.submittedAt == nil }) { return existing }
        let a = Attempt(quizId: quizId, subjectId: q.subjectId)
        mutate { $0.attempts.append(a) }
        return a
    }

    public func saveDraftAnswers(attemptId: String, answers: [Answer]) {
        mutate { d in
            if let i = d.attempts.firstIndex(where: { $0.id == attemptId }), d.attempts[i].submittedAt == nil { d.attempts[i].answers = answers }
        }
    }

    /// Submits, auto-marks what can be marked objectively, leaves the rest `pending` for Claude.
    @discardableResult
    public func submitAttempt(attemptId: String, answers: [Answer], timeExpired: Bool = false) -> Attempt? {
        guard let ai = data.attempts.firstIndex(where: { $0.id == attemptId }),
              data.attempts[ai].submittedAt == nil,
              let quiz = quiz(data.attempts[ai].quizId) else { return attempt(attemptId) }
        var marks: [QuestionMark] = []
        for q in quiz.questions { marks.append(Marker.mark(question: q, answer: answers.first { $0.questionId == q.id })) }
        mutate { d in
            d.attempts[ai].answers = answers
            d.attempts[ai].marks = marks
            d.attempts[ai].submittedAt = Date()
            d.attempts[ai].timeExpired = timeExpired
        }
        finalizeIfComplete(attemptId: attemptId)
        return attempt(attemptId)
    }

    /// Applies Claude's marks (validated). Claude may also revise auto-marks, with a reason in the feedback.
    public func applyClaudeMarks(attemptId: String, marks: [Args]) throws -> Int {
        guard let ai = data.attempts.firstIndex(where: { $0.id == attemptId }) else { throw ToolError("unknown attempt_id '\(attemptId)'") }
        guard data.attempts[ai].submittedAt != nil else { throw ToolError("attempt has not been submitted by the student yet") }
        guard let quiz = quiz(data.attempts[ai].quizId) else { throw ToolError("quiz for this attempt no longer exists") }
        var updated = data.attempts[ai].marks
        var applied = 0
        for m in marks {
            let qid = try m.string("question_id", maxLength: 40)
            guard let q = quiz.questions.first(where: { $0.id == qid }) else { throw ToolError("question_id '\(qid)' is not in this quiz") }
            let awarded = try m.number("awarded", range: 0...Double(q.marks))
            let feedback = try m.string("feedback", maxLength: 4000)
            let better = try m.optString("better_answer", maxLength: 4000) ?? ""
            var cats: [ErrorCategory] = []
            for c in try m.stringArray("error_categories", max: 5) ?? [] {
                guard let e = ErrorCategory.allCases.first(where: { $0.rawValue.lowercased() == c.lowercased() }) else { throw ToolError("error_categories contains '\(c)'; valid: \(ErrorCategory.allCases.map { $0.rawValue }.joined(separator: ", "))") }
                cats.append(e)
            }
            if awarded < Double(q.marks) && cats.isEmpty { cats = [.other] }
            guard let mi = updated.firstIndex(where: { $0.questionId == qid }) else { throw ToolError("no mark slot for question '\(qid)'") }
            updated[mi].awarded = (awarded * 2).rounded() / 2
            updated[mi].feedback = feedback
            if !better.isEmpty { updated[mi].betterAnswer = better }
            updated[mi].errorCategories = awarded < Double(q.marks) ? cats : []
            updated[mi].criterion = try m.optString("criterion", maxLength: 10) ?? q.criterion
            updated[mi].uncertainty = try m.optString("uncertainty", maxLength: 1000)
            updated[mi].markedBy = "claude"
            updated[mi].pending = false
            applied += 1
        }
        let finalized = data.attempts[ai].finalized
        mutate { $0.attempts[ai].marks = updated }
        if finalized {
            // Re-marking after finalisation (e.g. a correction): rebuild derived records for this attempt.
            let remarkedIds = Set(updated.map { $0.questionId })
            let since = (data.attempts[ai].submittedAt ?? Date.distantPast).addingTimeInterval(-5)
            mutate { d in
                d.mistakes.removeAll { (mis: Mistake) -> Bool in
                    mis.quizId == quiz.id && mis.date >= since && mis.questionId.map { remarkedIds.contains($0) } == true
                }
                d.attempts[ai].finalized = false
            }
        }
        finalizeIfComplete(attemptId: attemptId)
        return applied
    }

    /// Student chooses to stop waiting for Claude: pending items are excluded from totals.
    public func finalizeWithoutPending(attemptId: String) {
        guard let ai = data.attempts.firstIndex(where: { $0.id == attemptId }) else { return }
        mutate { d in
            for i in d.attempts[ai].marks.indices where d.attempts[ai].marks[i].pending {
                d.attempts[ai].marks[i].pending = false
                d.attempts[ai].marks[i].max = 0
                d.attempts[ai].marks[i].awarded = 0
                d.attempts[ai].marks[i].feedback = "Not marked (skipped)."
            }
        }
        finalizeIfComplete(attemptId: attemptId)
    }

    /// When no question is waiting for marking: record mistakes, update topic progress and spaced repetition.
    public func finalizeIfComplete(attemptId: String, now: Date = Date()) {
        guard let a = attempt(attemptId), a.submittedAt != nil, !a.finalized, !a.hasPending, let quiz = quiz(a.quizId) else { return }
        var perTopic: [String: (got: Double, max: Int)] = [:]
        var newMistakes: [Mistake] = []
        var followUps: [(mistakeId: String, ok: Bool)] = []
        for m in a.marks where m.max > 0 {
            guard let q = quiz.questions.first(where: { $0.id == m.questionId }) else { continue }
            if let t = q.topicId {
                let old = perTopic[t] ?? (0, 0)
                perTopic[t] = (old.got + m.awarded, old.max + m.max)
            }
            if let mid = q.testsMistakeId { followUps.append((mid, m.awarded >= Double(m.max) * 0.8)) }
            if m.awarded < Double(m.max) {
                let ans = a.answers.first { $0.questionId == q.id }
                let cat = m.errorCategories.first ?? defaultCategory(q.type)
                newMistakes.append(Mistake(
                    date: now, subjectId: quiz.subjectId, topicId: q.topicId,
                    question: q.prompt, studentAnswer: describe(answer: ans, question: q),
                    correctReasoning: m.betterAnswer.isEmpty ? (q.modelAnswer.isEmpty ? Marker.correctOptionsText(q) : q.modelAnswer) : m.betterAnswer,
                    category: cat, criterion: m.criterion ?? q.criterion, quizId: quiz.id, questionId: q.id,
                    marksLost: Double(m.max) - m.awarded))
            }
        }
        mutate { d in
            if let i = d.attempts.firstIndex(where: { $0.id == attemptId }) { d.attempts[i].finalized = true }
            d.mistakes.append(contentsOf: newMistakes)
            for (mid, ok) in followUps {
                if let i = d.mistakes.firstIndex(where: { $0.id == mid }) {
                    d.mistakes[i].followUps.append(FollowUp(date: now, correct: ok, quizId: quiz.id))
                    let last2 = d.mistakes[i].followUps.suffix(2)
                    if last2.count == 2 && last2.allSatisfy({ $0.correct }) { d.mistakes[i].resolved = true }
                    if !ok { d.mistakes[i].resolved = false }
                }
            }
        }
        for (tid, v) in perTopic where v.max > 0 {
            recordScore(topicId: tid, score: v.got / Double(v.max), weight: v.max, source: "quiz:\(quiz.id)", now: now)
        }
        onUIEvent?(.dataChanged)
    }

    private func defaultCategory(_ t: QuestionType) -> ErrorCategory {
        switch t {
        case .calculation, .equationCompletion: return .calculation
        case .diagramLabel: return .terminology
        case .extended: return .incompleteExplanation
        case .short: return .recall
        default: return .conceptual
        }
    }

    public func describe(answer: Answer?, question q: Question) -> String {
        guard let a = answer else { return "(no answer)" }
        switch q.type {
        case .single, .multi, .trueFalse:
            let t = a.selected.sorted().compactMap { $0 < q.options.count ? q.options[$0] : nil }.joined(separator: "; ")
            return t.isEmpty ? "(no answer)" : t
        case .calculation:
            var s = a.text
            if !a.unit.isEmpty { s += " " + a.unit }
            if !a.working.isEmpty { s += "  [working: \(a.working)]" }
            return s.isEmpty ? "(no answer)" : s
        case .equationCompletion: return a.blanks.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " ")
        case .diagramLabel: return q.labels.enumerated().map { "\($0.offset + 1): \(a.labels[$0.element.id] ?? "")" }.joined(separator: ", ")
        default: return a.text.isEmpty ? "(no answer)" : a.text
        }
    }

    // MARK: Claude-facing results

    public func attemptJSON(_ a: Attempt) -> JSON {
        guard let quiz = quiz(a.quizId) else { return ["error": "quiz missing"] }
        var items: [JSON] = []
        for q in quiz.questions {
            let ans = a.answers.first { $0.questionId == q.id }
            let m = a.marks.first { $0.questionId == q.id }
            var d: [String: JSON] = [
                "question_id": .s(q.id), "type": .s(q.type.rawValue), "prompt": .s(q.prompt), "marks_available": .i(q.marks),
                "student_answer": .s(describe(answer: ans, question: q)),
                "hint_used": .b(ans?.hintUsed ?? false)
            ]
            if let c = q.commandTerm { d["command_term"] = .s(c) }
            if let c = q.criterion { d["criterion"] = .s(c) }
            if !q.rubric.isEmpty { d["rubric"] = .s(q.rubric) }
            if !q.modelAnswer.isEmpty { d["model_answer"] = .s(q.modelAnswer) }
            if let w = ans?.working, !w.isEmpty { d["student_working"] = .s(w) }
            if let m = m {
                d["status"] = .s(m.pending ? "needs_your_marking" : "marked")
                d["awarded"] = m.pending ? .null : .n(m.awarded)
                d["auto_feedback"] = .s(m.feedback)
                d["marked_by"] = .s(m.markedBy)
            }
            if let c = q.calc { d["calc_spec"] = ["answer": .n(c.answer), "unit": .opt(c.unit), "sig_figs": c.sigFigs.map { .i($0) } ?? .null, "tolerance_percent": .n(c.tolerancePercent)] }
            items.append(.object(d))
        }
        return ["attempt_id": .s(a.id), "quiz_id": .s(quiz.id), "title": .s(quiz.title), "submitted": .b(a.submittedAt != nil),
                "time_expired": .b(a.timeExpired), "finalized": .b(a.finalized),
                "score_so_far": .n(a.awardedTotal), "marks_marked": .i(a.maxMarked), "marks_total": .i(quiz.totalMarks),
                "questions": .array(items)]
    }
}
