import XCTest
@testable import StudyCore

final class StudyCoreTests: XCTestCase {

    func makeStore() -> StudyStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aischool-test-\(UUID().uuidString)")
        return StudyStore(directory: dir)
    }

    func makeScienceStore() -> (StudyStore, Subject, Topic) {
        let store = makeStore()
        let s = store.addSubject(name: "Sciences", kind: .science)
        let t = store.addTopic(subjectId: s.id, title: "Particle theory")
        return (store, s, t)
    }

    // MARK: Board actions

    func testBoardBatchIsAtomic() throws {
        var b = Board(title: "t")
        let good: JSON = ["type": "add_text", "text": "Solid", "x": 10, "y": 10, "name": "solid"]
        let bad: JSON = ["type": "add_shape", "shape": "hexagon", "x": 0, "y": 0, "w": 10, "h": 10]
        XCTAssertThrowsError(try b.applyBatch([good, bad]))
        XCTAssertTrue(b.objects.isEmpty, "a rejected batch must change nothing")
        _ = try b.applyBatch([good])
        XCTAssertEqual(b.objects.count, 1)
    }

    func testBoardStepsAndRecall() throws {
        var b = Board(title: "t")
        _ = try b.applyBatch([
            ["type": "add_text", "text": "Nucleus", "x": 0, "y": 0, "name": "n1", "step": 1],
            ["type": "add_text", "text": "Electron", "x": 0, "y": 50, "name": "n2", "step": 2]
        ])
        XCTAssertEqual(b.maxStep, 2)
        XCTAssertFalse(b.isVisible(b.objects[0]))
        _ = try b.applyBatch([["type": "reveal_next"]])
        XCTAssertEqual(b.currentStep, 1)
        _ = try b.applyBatch([["type": "hide_labels", "all_text": true]])
        XCTAssertTrue(b.objects.allSatisfy { $0.hidden && $0.expected != nil })
    }

    func testParticlesAndTimeline() throws {
        var b = Board(title: "t")
        let created = try b.applyBatch([["type": "add_particles", "x": 100, "y": 100, "w": 400, "h": 300, "count": 20, "state": "gas", "name_prefix": "p"]])
        XCTAssertEqual(created[0].count, 21) // container + 20 particles
        XCTAssertTrue(b.objects.filter { $0.kind == .particle }.allSatisfy { $0.motion != nil })
        XCTAssertThrowsError(try b.applyBatch([["type": "add_particles", "x": 0, "y": 0, "w": 60, "h": 60, "count": 200, "state": "solid"]]))
        _ = try b.applyBatch([["type": "add_timeline", "x": 100, "y": 600, "events": [["label": "1914"], ["label": "1918"]], "reveal_sequentially": true]])
        XCTAssertGreaterThan(b.maxStep, 0)
    }

    func testDuplicateNameRejected() throws {
        var b = Board(title: "t")
        _ = try b.applyBatch([["type": "add_text", "text": "a", "x": 0, "y": 0, "name": "x"]])
        XCTAssertThrowsError(try b.applyBatch([["type": "add_text", "text": "b", "x": 0, "y": 0, "name": "x"]]))
    }

    // MARK: Marking

    func testSigFigsAndNumberParsing() {
        XCTAssertEqual(Marker.sigFigs(of: "0.00450"), 3)
        XCTAssertEqual(Marker.sigFigs(of: "1200"), 2)
        XCTAssertEqual(Marker.sigFigs(of: "1.20e3"), 3)
        XCTAssertEqual(Marker.parseNumber("5.0 × 10^3")?.value ?? 0, 5000, accuracy: 1e-9)
        XCTAssertEqual(Marker.parseNumber("12.5 m/s")?.rest, "m/s")
    }

    func testCalculationMarking() {
        let q = Question(type: .calculation, prompt: "v?", marks: 3, calc: CalcSpec(answer: 12.5, tolerancePercent: 1, unit: "m/s", sigFigs: 3))
        var a = Answer(questionId: q.id, text: "12.5", unit: "m/s")
        XCTAssertEqual(Marker.mark(question: q, answer: a).awarded, 3)
        a.unit = ""
        let noUnit = Marker.mark(question: q, answer: a)
        XCTAssertEqual(noUnit.awarded, 2)
        XCTAssertTrue(noUnit.errorCategories.contains(.missingUnits))
        a = Answer(questionId: q.id, text: "12.50000", unit: "m/s")
        let sf = Marker.mark(question: q, answer: a)
        XCTAssertTrue(sf.errorCategories.contains(.sigFigs))
        a = Answer(questionId: q.id, text: "99", unit: "m/s", working: "v = d/t")
        XCTAssertTrue(Marker.mark(question: q, answer: a).pending, "wrong answer with working goes to Claude for method marks")
    }

    func testObjectiveMarking() {
        let single = Question(type: .single, prompt: "?", options: ["a", "b", "c"], correct: [1], marks: 1)
        XCTAssertEqual(Marker.mark(question: single, answer: Answer(questionId: single.id, selected: [1])).awarded, 1)
        XCTAssertEqual(Marker.mark(question: single, answer: Answer(questionId: single.id, selected: [0])).awarded, 0)
        let multi = Question(type: .multi, prompt: "?", options: ["a", "b", "c", "d"], correct: [0, 1], marks: 2)
        XCTAssertEqual(Marker.mark(question: multi, answer: Answer(questionId: multi.id, selected: [0])).awarded, 1)
        XCTAssertEqual(Marker.mark(question: multi, answer: Answer(questionId: multi.id, selected: [0, 1, 3])).awarded, 0.5)
        let ext = Question(type: .extended, prompt: "Explain", rubric: "r", marks: 4)
        XCTAssertTrue(Marker.mark(question: ext, answer: Answer(questionId: ext.id, text: "x")).pending)
        let eq = Question(type: .equationCompletion, prompt: "2x + ___ = 10", marks: 1, blanks: ["4"])
        XCTAssertEqual(Marker.mark(question: eq, answer: Answer(questionId: eq.id, blanks: ["4.0"])).awarded, 1)
    }

    // MARK: Spaced repetition & mastery

    func testSRSShortensAfterFailureAndLengthensAfterSuccess() {
        var p = TopicProgress(topicId: "t")
        let day: TimeInterval = 86400
        let t0 = Date()
        SRS.update(&p, score: 1.0, weight: 3, source: "q", now: t0)
        SRS.update(&p, score: 1.0, weight: 3, source: "q", now: t0.addingTimeInterval(day))
        SRS.update(&p, score: 1.0, weight: 3, source: "q", now: t0.addingTimeInterval(4 * day))
        let grown = p.intervalDays
        XCTAssertGreaterThan(grown, 3)
        SRS.update(&p, score: 0.1, weight: 3, source: "q", now: t0.addingTimeInterval(10 * day))
        XCTAssertLessThan(p.intervalDays, grown)
        XCTAssertEqual(p.reps, 0)
    }

    func testSingleLuckySuccessIsNotMastery() {
        var p = TopicProgress(topicId: "t")
        SRS.update(&p, score: 1.0, weight: 1, source: "q", now: Date())
        XCTAssertEqual(SRS.mastery(p), .provisional)
        XCTAssertNotEqual(SRS.mastery(p), .secure)
        var s = TopicProgress(topicId: "s")
        let day: TimeInterval = 86400
        for i in 0..<4 { SRS.update(&s, score: 1.0, weight: 3, source: "q", now: Date().addingTimeInterval(Double(i) * 3 * day)) }
        XCTAssertEqual(SRS.mastery(s), .secure)
    }

    // MARK: Quiz → marking → mistakes → progress

    func testQuizEndToEnd() throws {
        let (store, s, t) = makeScienceStore()
        let exec = ToolExecutor(store: store, lessonId: nil)
        let input: JSON = [
            "subject_id": .s(s.id), "title": "Particles", "mode": "practice", "launch": false,
            "questions": [
                ["type": "single", "prompt": "Which state has fixed shape?", "options": ["Solid", "Gas"], "correct": [0], "topic_id": .s(t.id)],
                ["type": "extended", "prompt": "Explain why gases compress.", "rubric": "Particles far apart; empty space", "topic_id": .s(t.id), "marks": 4, "criterion": "A"]
            ]
        ]
        let r = exec.run(name: "create_quiz", input: input)
        XCTAssertFalse(r.isError, r.content)
        let quiz = store.data.quizzes[0]
        let att = store.startAttempt(quizId: quiz.id)!
        _ = store.submitAttempt(attemptId: att.id, answers: [
            Answer(questionId: quiz.questions[0].id, selected: [1]),
            Answer(questionId: quiz.questions[1].id, text: "Because they are light")
        ])
        XCTAssertFalse(store.attempt(att.id)!.finalized, "extended answer still awaits Claude")
        XCTAssertEqual(store.data.mistakes.count, 0)

        let mark = exec.run(name: "mark_response", input: [
            "attempt_id": .s(att.id),
            "marks": [["question_id": .s(quiz.questions[1].id), "awarded": 1, "feedback": "Mentions lightness, not spacing.",
                       "error_categories": ["incompleteExplanation"], "uncertainty": "Rubric judgement"]]
        ])
        XCTAssertFalse(mark.isError, mark.content)
        let done = store.attempt(att.id)!
        XCTAssertTrue(done.finalized)
        XCTAssertEqual(store.data.mistakes.count, 2)
        XCTAssertNotNil(store.data.progress[t.id]?.due)
        XCTAssertEqual(store.masteryLevel(topicId: t.id), .struggling)
    }

    func testToolValidationRejectsBadInput() {
        let (store, s, _) = makeScienceStore()
        let exec = ToolExecutor(store: store, lessonId: nil)
        let bad = exec.run(name: "create_quiz", input: ["subject_id": .s(s.id), "title": "x", "questions": [["type": "single", "prompt": "?", "options": ["a", "b"], "correct": [5]]]])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(store.data.quizzes.isEmpty)
        XCTAssertTrue(exec.run(name: "nope", input: [:]).isError)
        XCTAssertTrue(exec.run(name: "schedule_review", input: ["topic_id": "missing", "in_days": 2]).isError)
        XCTAssertTrue(exec.run(name: "whiteboard_apply", input: ["actions": []]).isError)
    }

    func testMistakeFollowUpResolves() throws {
        let (store, s, t) = makeScienceStore()
        let m = Mistake(subjectId: s.id, topicId: t.id, question: "q", studentAnswer: "a", correctReasoning: "r", category: .missingUnits)
        store.mutate { $0.mistakes.append(m) }
        for _ in 0..<2 {
            var q = Question(type: .single, prompt: "retest", options: ["a", "b"], correct: [0], topicId: t.id)
            q.testsMistakeId = m.id
            let quiz = store.addQuiz(Quiz(subjectId: s.id, title: "r", questions: [q]))
            let att = store.startAttempt(quizId: quiz.id)!
            _ = store.submitAttempt(attemptId: att.id, answers: [Answer(questionId: q.id, selected: [0])])
        }
        XCTAssertTrue(store.data.mistakes.first { $0.id == m.id }!.resolved)
    }

    // MARK: Recommendations, sources, planner

    func testRecommendationsUseEvidenceOnly() {
        let (store, s, t) = makeScienceStore()
        XCTAssertTrue(store.recommendations().isEmpty, "no assessments or history → nothing to recommend")
        let soon = Calendar.current.date(byAdding: .day, value: 3, to: Date())
        store.addAssessment(Assessment(subjectId: s.id, title: "Unit test", date: soon, topicIds: [t.id]))
        let r = store.recommendations()
        XCTAssertEqual(r.first?.topicId, t.id)
        XCTAssertTrue(r.first!.reasons.contains { $0.contains("Unit test") })
    }

    func testSourceSearchRespectsSharingAndOrigin() {
        let (store, s, _) = makeScienceStore()
        store.addResource(Resource(subjectId: s.id, title: "Notes", kind: .note, text: "Particles in a gas are far apart and move randomly.", shareWithAI: true))
        store.addResource(Resource(subjectId: s.id, title: "Private", kind: .note, text: "Gas gas gas secret diary", shareWithAI: false))
        let hits = store.searchSources(query: "gas particles")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "Notes")
        XCTAssertEqual(store.searchSources(query: "gas", forAI: false).count, 2)
    }

    func testPlannerHonoursQuietHoursAndDailyLimit() {
        let (store, s, t) = makeScienceStore()
        let soon = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        store.addAssessment(Assessment(subjectId: s.id, title: "Test", date: soon, topicIds: [t.id]))
        store.mutate { d in
            d.settings.maxPerDay = 2; d.settings.quizPrompts = true; d.settings.eveningSummary = true
            d.settings.morningMinutes = 23 * 60   // inside quiet hours by default
        }
        let plan = store.plannedNotifications(now: Date(), horizonDays: 7)
        let cal = Calendar.current
        let byDay = Dictionary(grouping: plan) { cal.startOfDay(for: $0.fire) }
        for (_, list) in byDay { XCTAssertLessThanOrEqual(list.count, 2) }
        for n in plan {
            let m = cal.component(.hour, from: n.fire) * 60 + cal.component(.minute, from: n.fire)
            XCTAssertFalse(m >= 21 * 60 + 30 || m < 7 * 60, "notification at \(n.fire) is inside quiet hours")
        }
    }

    // MARK: Import, persistence, repair

    func testChatExportImport() throws {
        let json = """
        [{"name":"Photosynthesis chat","chat_messages":[{"sender":"human","text":"What is photosynthesis?"},{"sender":"assistant","text":"It converts light to chemical energy."}]}]
        """
        let docs = try Importer.parse(data: Data(json.utf8), filename: "conversations.json", kindHint: nil)
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs[0].kind, .chat)
        XCTAssertTrue(docs[0].text.contains("Student: What is photosynthesis?"))
    }

    func testPersistenceRoundTripAndBackup() throws {
        let (store, s, _) = makeScienceStore()
        store.addResource(Resource(subjectId: s.id, title: "R", text: "hello"))
        store.flush()
        let reopened = StudyStore(directory: store.directory)
        XCTAssertEqual(reopened.data.subjects.count, 1)
        XCTAssertEqual(reopened.data.resources.first?.text, "hello")
        let backup = try store.makeBackup()
        store.mutate { $0.resources.removeAll() }
        try store.restore(from: backup)
        XCTAssertEqual(store.data.resources.count, 1)
    }

    func testHistoryRepairAnswersDanglingToolUse() {
        let h: [JSON] = [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": [["type": "tool_use", "id": "tu_1", "name": "whiteboard_read", "input": [:]]]]
        ]
        let fixed = HistoryRepair.repair(h)
        XCTAssertEqual(fixed.count, 3)
        XCTAssertEqual(fixed[2]["content"]?.array?.first?["tool_use_id"]?.string, "tu_1")
    }

    func testMathText() {
        XCTAssertEqual(MathText.render("x^2 + H_2O"), "x² + H₂O")
        XCTAssertEqual(MathText.render("\\Delta T \\times 2"), "Δ T × 2")
    }
}
