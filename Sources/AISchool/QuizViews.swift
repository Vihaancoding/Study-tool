import SwiftUI
import StudyCore

struct QuizRunnerView: View {
    @EnvironmentObject var app: AppState
    let quizId: String
    var onClose: () -> Void

    @State private var attemptId: String?
    @State private var answers: [String: Answer] = [:]
    @State private var index = 0
    @State private var hintShown: Set<String> = []
    @State private var confirmSubmit = false
    @State private var submitted = false

    private var store: StudyStore { app.store }

    var body: some View {
        Group {
            if let quiz = store.quiz(quizId) {
                if let aid = attemptId, let att = store.attempt(aid), att.submittedAt != nil {
                    QuizResultsView(quiz: quiz, attemptId: aid, onClose: onClose)
                } else if attemptId != nil {
                    runner(quiz)
                } else {
                    ProgressView().onAppear { begin(quiz) }
                }
            } else {
                EmptyHint(icon: "questionmark.circle", title: "Quiz not found", message: "It may have been deleted.")
            }
        }
    }

    private func begin(_ quiz: Quiz) {
        guard let att = store.startAttempt(quizId: quiz.id) else { return }
        attemptId = att.id
        for a in att.answers { answers[a.questionId] = a }
    }

    private func answer(_ q: Question) -> Binding<Answer> {
        Binding(get: { answers[q.id] ?? Answer(questionId: q.id) },
                set: { answers[q.id] = $0; if let aid = attemptId { store.saveDraftAnswers(attemptId: aid, answers: Array(answers.values)) } })
    }

    private func isAnswered(_ q: Question) -> Bool {
        guard let a = answers[q.id] else { return false }
        return !a.text.trimmingCharacters(in: .whitespaces).isEmpty || !a.selected.isEmpty || a.blanks.contains { !$0.isEmpty } || a.labels.values.contains { !$0.isEmpty }
    }

    private func runner(_ quiz: Quiz) -> some View {
        let q = quiz.questions[min(index, quiz.questions.count - 1)]
        let answered = quiz.questions.filter(isAnswered).count
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quiz.title).font(.headline)
                    Text("\(quiz.mode.label) · \(quiz.totalMarks) marks").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let limit = quiz.timeLimitSeconds, let att = attemptId.flatMap({ store.attempt($0) }) {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        let remaining = max(0, Int(att.startedAt.addingTimeInterval(Double(limit)).timeIntervalSince(tl.date)))
                        Label(String(format: "%d:%02d", remaining / 60, remaining % 60), systemImage: "timer")
                            .font(.title3.monospacedDigit()).foregroundStyle(remaining < 60 ? Theme.bad : .primary)
                            .onChange(of: remaining) { _, r in if r == 0 && !submitted { submit(quiz, expired: true) } }
                    }
                }
            }.padding(16)
            ProgressView(value: Double(answered), total: Double(quiz.questions.count)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { i, qq in
                        Button { index = i } label: {
                            Text("\(i + 1)").font(.callout.monospacedDigit()).frame(width: 30, height: 30)
                                .background(i == index ? Theme.accent : (isAnswered(qq) ? Theme.accent.opacity(0.2) : Color.secondary.opacity(0.12)), in: Circle())
                                .foregroundStyle(i == index ? Color.white : Color.primary)
                        }.buttonStyle(.plain).accessibilityLabel("Question \(i + 1)\(isAnswered(qq) ? ", answered" : "")")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text("Question \(index + 1) of \(quiz.questions.count)").font(.caption).foregroundStyle(.secondary)
                        Text("[\(q.marks) mark\(q.marks == 1 ? "" : "s")]").font(.caption).foregroundStyle(.secondary)
                        if let c = q.commandTerm { Text(c).font(.caption.weight(.semibold)).padding(.horizontal, 6).background(Theme.accent.opacity(0.15), in: Capsule()) }
                        if let c = q.criterion { Text("Criterion \(c)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(q.prompt).font(.title3).textSelection(.enabled)
                    QuestionInput(question: q, answer: answer(q), boardSource: store.board(q.boardId))
                    if let h = q.hint {
                        if hintShown.contains(q.id) {
                            Label(h, systemImage: "lightbulb").padding(10).background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { hintShown.insert(q.id); var a = answers[q.id] ?? Answer(questionId: q.id); a.hintUsed = true; answer(q).wrappedValue = a } label: { Label("Show hint", systemImage: "lightbulb") }
                                .buttonStyle(.borderless)
                        }
                    }
                }.padding(20).frame(maxWidth: 760, alignment: .leading)
            }
            Divider()
            HStack {
                Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }.disabled(index == 0)
                Spacer()
                Text("\(answered) of \(quiz.questions.count) answered").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if index < quiz.questions.count - 1 {
                    Button { index += 1 } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }.keyboardShortcut(.rightArrow, modifiers: .command)
                }
                Button("Submit") { if answered < quiz.questions.count { confirmSubmit = true } else { submit(quiz, expired: false) } }
                    .buttonStyle(PrimaryButtonStyle())
            }.padding(14)
        }
        .confirmationDialog("Submit with unanswered questions?", isPresented: $confirmSubmit) {
            Button("Submit anyway") { submit(quiz, expired: false) }
            Button("Keep working", role: .cancel) {}
        } message: { Text("Unanswered questions score zero.") }
    }

    private func submit(_ quiz: Quiz, expired: Bool) {
        guard let aid = attemptId, !submitted else { return }
        submitted = true
        _ = store.submitAttempt(attemptId: aid, answers: Array(answers.values), timeExpired: expired)
        app.notifyQuizSubmitted(quizId: quiz.id, attemptId: aid)
    }
}

struct QuestionInput: View {
    let question: Question
    @Binding var answer: Answer
    var boardSource: Board?

    var body: some View {
        switch question.type {
        case .single, .trueFalse:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                    Button { answer.selected = [i] } label: {
                        HStack { Image(systemName: answer.selected == [i] ? "largecircle.fill.circle" : "circle"); Text(opt).multilineTextAlignment(.leading); Spacer() }
                            .padding(10).background(answer.selected == [i] ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        case .multi:
            VStack(alignment: .leading, spacing: 8) {
                Text("Select all that apply").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                    Button {
                        if answer.selected.contains(i) { answer.selected.removeAll { $0 == i } } else { answer.selected.append(i) }
                    } label: {
                        HStack { Image(systemName: answer.selected.contains(i) ? "checkmark.square.fill" : "square"); Text(opt).multilineTextAlignment(.leading); Spacer() }
                            .padding(10).background(answer.selected.contains(i) ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        case .short:
            TextField("Your answer", text: $answer.text, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
        case .extended:
            VStack(alignment: .trailing) {
                TextEditor(text: $answer.text).font(.body).frame(minHeight: 220).padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Text("\(answer.text.split { $0.isWhitespace }.count) words").font(.caption).foregroundStyle(.secondary)
            }
        case .calculation:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Answer (number)", text: $answer.text).textFieldStyle(.roundedBorder).frame(width: 200)
                    TextField("Unit", text: $answer.unit).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                if let sf = question.calc?.sigFigs { Text("Give your answer to \(sf) significant figures.").font(.caption).foregroundStyle(.secondary) }
                Text("Working").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $answer.working).font(.body.monospaced()).frame(minHeight: 120).padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        case .equationCompletion:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<question.blanks.count, id: \.self) { i in
                    HStack {
                        Text("Blank \(i + 1)").frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                        TextField("…", text: Binding(get: { i < answer.blanks.count ? answer.blanks[i] : "" }, set: { v in
                            while answer.blanks.count < question.blanks.count { answer.blanks.append("") }
                            answer.blanks[i] = v
                        })).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                }
            }
        case .diagramLabel:
            VStack(alignment: .leading, spacing: 10) {
                if let b = boardSource { LabelDiagram(board: b, targets: question.labels) }
                ForEach(Array(question.labels.enumerated()), id: \.element.id) { i, t in
                    HStack {
                        Text("\(i + 1)").frame(width: 22, height: 22).background(Theme.accent, in: Circle()).foregroundStyle(.white)
                        if question.labelBank.isEmpty {
                            TextField("Label", text: Binding(get: { answer.labels[t.id] ?? "" }, set: { answer.labels[t.id] = $0 })).textFieldStyle(.roundedBorder).frame(width: 260)
                        } else {
                            Picker("", selection: Binding(get: { answer.labels[t.id] ?? "" }, set: { answer.labels[t.id] = $0 })) {
                                Text("Choose…").tag("")
                                ForEach(question.labelBank, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 260)
                        }
                    }
                }
            }
        }
    }
}

/// Read-only snapshot of a board with numbered markers where the student must supply labels.
struct LabelDiagram: View {
    let board: Board
    let targets: [LabelTarget]
    var body: some View {
        let visible = board.objects.filter { $0.step <= board.currentStep }
        var box = visible.first?.bounds ?? CGRect(x: 0, y: 0, width: 600, height: 400)
        for o in visible.dropFirst() { box = box.union(o.bounds) }
        for t in targets { box = box.union(CGRect(x: t.x - 20, y: t.y - 20, width: 40, height: 40)) }
        box = box.insetBy(dx: -30, dy: -30)
        let scale = min(1, 620 / max(box.width, 1))
        return ZStack(alignment: .topLeading) {
            BoardSurface(board: board, animated: false)
            ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                Text("\(i + 1)").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
                    .offset(x: t.x - 15, y: t.y - 15)
            }
        }
        .offset(x: -box.minX, y: -box.minY)
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .background(Theme.canvas)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: box.width * scale, height: box.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

struct QuizResultsView: View {
    @EnvironmentObject var app: AppState
    let quiz: Quiz
    let attemptId: String
    var onClose: () -> Void

    var body: some View {
        let store = app.store
        if let att = store.attempt(attemptId) {
            let pending = att.marks.filter { $0.pending }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text("Results").font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
                            Text(quiz.title).font(.title2.weight(.semibold))
                        }
                        Spacer()
                        Button("Close", action: onClose)
                    }
                    if att.maxMarked > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(trim(att.awardedTotal)).font(.system(size: 44, weight: .semibold)).monospacedDigit()
                            Text("/ \(att.maxMarked)").font(.title2).foregroundStyle(.secondary)
                            Text("\(Int((att.awardedTotal / Double(att.maxMarked) * 100).rounded()))%").font(.title3).foregroundStyle(.secondary).padding(.leading, 8)
                        }
                    }
                    if att.timeExpired { Label("Time ran out; your answers were submitted automatically.", systemImage: "timer").foregroundStyle(Theme.warn) }
                    if pending > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(pending) answer\(pending == 1 ? " is" : "s are") waiting to be marked by Claude", systemImage: "hourglass")
                            Text("Marks shown so far are provisional. Written answers and working are marked against the rubric by Claude.").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Ask Claude to mark") { app.askClaudeToMark(attemptId: attemptId) }.disabled(!app.hasAPIKey).buttonStyle(PrimaryButtonStyle())
                                Button("Finish without Claude’s marking") { store.finalizeWithoutPending(attemptId: attemptId) }
                            }
                        }.quietPanel()
                    } else if att.finalized {
                        Label("Saved to your learning record. Mistakes were added to your log and revision dates updated.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(Theme.good)
                    }
                    ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { i, q in
                        QuestionResultCard(index: i + 1, question: q, answer: att.answers.first { $0.questionId == q.id }, mark: att.marks.first { $0.questionId == q.id })
                    }
                }.padding(24).frame(maxWidth: 800, alignment: .leading)
            }
        }
    }

    private func trim(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}

struct QuestionResultCard: View {
    @EnvironmentObject var app: AppState
    let index: Int
    let question: Question
    let answer: Answer?
    let mark: QuestionMark?

    var body: some View {
        let store = app.store
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Q\(index)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if let c = question.commandTerm { Text(c).font(.caption.weight(.semibold)) }
                Spacer()
                if let m = mark {
                    if m.pending { Text("awaiting marking").font(.caption).foregroundStyle(Theme.warn) }
                    else {
                        Text("\(m.awarded == m.awarded.rounded() ? String(Int(m.awarded)) : String(m.awarded)) / \(m.max)").font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(m.awarded >= Double(m.max) ? Theme.good : (m.awarded > 0 ? Theme.warn : Theme.bad))
                    }
                }
            }
            Text(question.prompt)
            Group {
                Text("Your answer: ").foregroundStyle(.secondary) + Text(store.describe(answer: answer, question: question))
            }.font(.callout)
            if let m = mark {
                if !m.feedback.isEmpty { Text(m.feedback).font(.callout) }
                if !m.betterAnswer.isEmpty && (m.pending || m.awarded < Double(m.max)) {
                    Text("A stronger answer: ").font(.callout.weight(.medium)) + Text(m.betterAnswer).font(.callout)
                }
                if !m.errorCategories.isEmpty {
                    Text(m.errorCategories.map { $0.label }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.bad)
                }
                if let u = m.uncertainty { Label(u, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                if m.markedBy == "claude" { Text("Marked by Claude — judgement-based marks are not exact.").font(.caption2).foregroundStyle(.tertiary) }
            }
            if !question.sourceRefs.isEmpty {
                HStack { ForEach(question.sourceRefs, id: \.self) { ref in
                    Button("source") {
                        let parts = ref.split(separator: "#")
                        app.sourceToShow = SourceRef(resourceId: String(parts.first ?? ""), chunk: Int(parts.count > 1 ? String(parts[1]) : "0") ?? 0)
                    }.buttonStyle(.link).font(.caption)
                } }
            }
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
