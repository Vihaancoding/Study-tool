import SwiftUI
import StudyCore

struct LearnView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let id = app.currentLessonId, app.store.lesson(id) != nil {
            ClassroomView(lessonId: id)
        } else {
            LessonLauncher()
        }
    }
}

struct LessonLauncher: View {
    @EnvironmentObject var app: AppState
    @State private var subjectId: String = ""
    @State private var topicId: String = ""
    @State private var focus = ""

    private var store: StudyStore { app.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Start a lesson").font(.system(size: 26, weight: .semibold))
                if store.data.subjects.isEmpty {
                    EmptyHint(icon: "books.vertical", title: "Add a subject first", message: "Lessons are tied to a subject so Claude can use your syllabus, notes and history.")
                    Button("Go to Subjects") { app.route = .subjects }.buttonStyle(.borderedProminent)
                } else {
                    if !app.hasAPIKey {
                        HStack { Image(systemName: "key"); Text("Add your Anthropic API key in Settings to teach with Claude."); Spacer(); Button("Open Settings") { app.route = .settings } }.quietPanel()
                    }
                    Form {
                        Picker("Subject", selection: $subjectId) {
                            Text("Choose…").tag("")
                            ForEach(store.data.subjects) { Text($0.name).tag($0.id) }
                        }
                        Picker("Topic", selection: $topicId) {
                            Text("Let Claude suggest").tag("")
                            ForEach(store.topics(in: subjectId)) { Text($0.title).tag($0.id) }
                        }.disabled(subjectId.isEmpty)
                        TextField("What do you want to work on? (optional)", text: $focus, axis: .vertical).lineLimit(1...3)
                        Picker("Style", selection: Binding(get: { store.data.settings.teachingStyle }, set: { s in store.mutate { $0.settings.teachingStyle = s } })) {
                            ForEach(TeacherPrompt.styles, id: \.id) { Text($0.label).tag($0.id) }
                        }
                    }
                    .formStyle(.grouped).frame(maxWidth: 560)
                    Button { app.startLesson(subjectId: subjectId, topicId: topicId.isEmpty ? nil : topicId, focus: focus) } label: {
                        Label("Start lesson", systemImage: "graduationcap")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(subjectId.isEmpty || !app.hasAPIKey)

                    let rec = store.recommendations().first
                    if let r = rec {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionTitle("Suggested")
                            Text(r.title).fontWeight(.medium)
                            ForEach(r.reasons, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                            Button("Use this") { subjectId = r.subjectId; topicId = r.topicId ?? "" }.buttonStyle(.borderless)
                        }
                    }
                }
                let past = store.data.lessons.sorted { $0.startedAt > $1.startedAt }.prefix(8)
                if !past.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Previous lessons")
                        ForEach(Array(past)) { l in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.title).fontWeight(.medium)
                                    Text("\(store.subject(l.subjectId)?.name ?? "") · \(l.startedAt.formatted(date: .abbreviated, time: .shortened))\(l.isActive ? " · in progress" : "")").font(.caption).foregroundStyle(.secondary)
                                    if !l.summary.isEmpty { Text(l.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                                }
                                Spacer()
                                Button(l.isActive ? "Resume" : "View") { app.resumeLesson(l.id) }
                            }
                            Divider()
                        }
                    }.frame(maxWidth: 700)
                }
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if subjectId.isEmpty { subjectId = app.selectedSubjectId ?? store.data.subjects.first?.id ?? "" } }
        .onChange(of: subjectId) { _, _ in topicId = "" }
    }
}

struct ClassroomView: View {
    @EnvironmentObject var app: AppState
    let lessonId: String
    @State private var showEndConfirm = false

    private var store: StudyStore { app.store }

    var body: some View {
        if let lesson = store.lesson(lessonId) {
            HSplitView {
                ConversationView(lessonId: lessonId, session: app.session(for: lessonId))
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 560)
                rightPane(lesson)
                    .frame(minWidth: 480)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lesson.title).font(.headline)
                        Text(store.subject(lesson.subjectId)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup {
                    if lesson.isActive {
                        Button { showEndConfirm = true } label: { Label("End lesson", systemImage: "checkmark.circle") }
                    } else {
                        Button { app.currentLessonId = nil } label: { Label("Close", systemImage: "xmark") }
                    }
                }
            }
            .confirmationDialog("End this lesson?", isPresented: $showEndConfirm) {
                Button("Ask Claude to wrap up and save") { app.session(for: lessonId).endLesson() }
                Button("Save and close now") {
                    store.endLesson(lessonId, summary: nil); app.currentLessonId = nil
                }
                Button("Keep going", role: .cancel) {}
            } message: { Text("Claude will schedule reviews and write a short summary so you can pick up next time.") }
        }
    }

    @ViewBuilder private func rightPane(_ lesson: LessonSession) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.learnPane) {
                Text("Whiteboard").tag(LearnPane.board)
                Text("Quiz").tag(LearnPane.quiz)
                Text("Sources").tag(LearnPane.sources)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10).frame(maxWidth: 360)
            Divider()
            switch app.learnPane {
            case .board:
                BoardEditor(boardId: lesson.boardId, compact: false)
                if lesson.isActive {
                    Divider()
                    HStack {
                        Text("Done on the board?").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Send my board to Claude") { app.session(for: lessonId).send("I've worked on the whiteboard. Please look at it and respond.") }
                            .disabled(!app.hasAPIKey)
                    }.padding(10)
                }
            case .quiz:
                if let qid = app.openQuizId ?? lesson.quizIds.last, store.quiz(qid) != nil {
                    QuizRunnerView(quizId: qid, onClose: { app.openQuizId = nil; app.learnPane = .board })
                        .id(qid)
                } else {
                    EmptyHint(icon: "checklist", title: "No quiz yet", message: "Ask Claude to quiz you — it will appear here ready to take.")
                }
            case .sources:
                LessonSources(lesson: lesson)
            }
        }
    }
}

struct LessonSources: View {
    @EnvironmentObject var app: AppState
    let lesson: LessonSession
    var body: some View {
        let res = app.store.data.resources.filter { $0.subjectId == lesson.subjectId }
        List(res) { r in
            Button { app.sourceToShow = SourceRef(resourceId: r.id, chunk: 0) } label: {
                VStack(alignment: .leading) {
                    Text(r.title)
                    Text("\(r.kind.label) · \(r.origin == .claude ? "written by Claude" : "your material")").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .overlay { if res.isEmpty { EmptyHint(icon: "doc.text", title: "No sources for this subject", message: "Import notes, worksheets or rubrics in Subjects so Claude can teach from them and cite them.") } }
    }
}

struct ConversationView: View {
    @EnvironmentObject var app: AppState
    let lessonId: String
    @ObservedObject var session: TeacherSession
    @State private var input = ""

    private var lesson: LessonSession? { app.store.lesson(lessonId) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lesson?.messages ?? []) { m in MessageRow(entry: m).id(m.id) }
                        if session.isWorking {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(session.status).font(.callout).foregroundStyle(.secondary) }.id("working")
                        }
                        if let e = session.errorText {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(e).font(.callout).foregroundStyle(Theme.bad)
                                HStack { Button("Try again") { session.retry() }; if !app.hasAPIKey { Button("Open Settings") { app.route = .settings } } }
                            }.id("error")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: lesson?.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(session.isWorking ? "working" : lesson?.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: session.isWorking) { _, _ in proxy.scrollTo(lesson?.messages.last?.id, anchor: .bottom) }
            }
            Divider()
            quickActions
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply, ask a question, or interrupt…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(send)
                if session.isWorking {
                    Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }.buttonStyle(.plain).help("Stop Claude")
                }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || lesson?.isActive == false)
                    .help("Send (⌘↩)")
            }.padding(12)
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Simpler") { fire("Can you explain that more simply?") }
                chip("Give me a hint") { fire("Give me a hint, but don't tell me the answer.") }
                chip("Show me on the board") { fire("Show me this on the whiteboard.") }
                chip("Quiz me") { fire("Quiz me on this using a real quiz.") }
                chip("Different way") { fire("Explain it a different way.") }
                chip("Exam style") { fire("Switch to exam-coach mode: use command terms and marks.") }
            }.padding(.horizontal, 12).padding(.top, 8)
        }
    }

    private func chip(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.caption).padding(.horizontal, 10).padding(.vertical, 4).background(Theme.accent.opacity(0.12), in: Capsule()) }
            .buttonStyle(.plain).disabled(lesson?.isActive == false)
    }

    private func fire(_ t: String) { session.send(t) }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        session.send(t)
    }
}

struct MessageRow: View {
    @EnvironmentObject var app: AppState
    let entry: ChatEntry

    var body: some View {
        switch entry.role {
        case .user:
            Text(entry.text).padding(10).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
        case .assistant:
            Text(MessageRow.render(entry.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in app.open(url: url); return .handled })
        case .tool:
            Label(entry.text, systemImage: entry.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.caption).foregroundStyle(entry.isError ? Theme.warn : .secondary)
        case .system:
            Text(entry.text).font(.caption).foregroundStyle(entry.isError ? Theme.bad : .secondary)
        }
    }

    /// Markdown plus [[src:ID#n]] citation markers turned into tappable links to the source viewer.
    static func render(_ text: String) -> AttributedString {
        var t = text
        if let re = try? NSRegularExpression(pattern: "\\[\\[src:([A-Za-z0-9_]+)#?([0-9]*)\\]\\]") {
            let ns = t as NSString
            var out = ""
            var last = 0
            var n = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let id = ns.substring(with: m.range(at: 1))
                let chunk = m.range(at: 2).length > 0 ? ns.substring(with: m.range(at: 2)) : "0"
                n += 1
                out += "[source \(n)](aischool://source?id=\(id)&chunk=\(chunk))"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: t, options: opts)) ?? AttributedString(text)
    }
}

struct SourceViewer: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let ref: SourceRef

    var body: some View {
        let r = app.store.resource(ref.resourceId)
        let chunks = r.map { TextChunker.chunks($0.text) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(r?.title ?? "Source not found").font(.headline)
                    if let r = r { Text("\(r.kind.label) · \(r.origin == .claude ? "Written by Claude — not your original material" : "From your material")").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { i, c in
                            Text(c).textSelection(.enabled).padding(10)
                                .background(i == ref.chunk ? Theme.warn.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6)).id(i)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(ref.chunk, anchor: .top) }
            }
        }
        .padding(20).frame(minWidth: 620, minHeight: 460)
    }
}
