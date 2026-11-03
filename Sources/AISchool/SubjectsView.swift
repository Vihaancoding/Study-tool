import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import StudyCore

struct SubjectsView: View {
    @EnvironmentObject var app: AppState
    @State private var showAdd = false
    private var store: StudyStore { app.store }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(store.data.subjects, selection: Binding<String?>(get: { app.selectedSubjectId }, set: { app.selectedSubjectId = $0 })) { s in
                    Label(s.name, systemImage: s.kind.icon).tag(s.id)
                }
                Divider()
                Button { showAdd = true } label: { Label("Add subject", systemImage: "plus") }.buttonStyle(.borderless).padding(10)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            Group {
                if let id = app.selectedSubjectId, store.subject(id) != nil {
                    SubjectWorkspace(subjectId: id).id(id)
                } else {
                    EmptyHint(icon: "books.vertical", title: "Subjects", message: "Add a subject to give it a workspace: syllabus, resources, lessons, boards, quizzes, results, mistakes and revision.")
                }
            }.frame(minWidth: 600)
        }
        .sheet(isPresented: $showAdd) { AddSubjectSheet().environmentObject(app) }
    }
}

struct AddSubjectSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: SubjectKind = .science

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("e.g. Sciences, Mathematics, Individuals & Societies"))
            Picker("Type", selection: $kind) { ForEach(SubjectKind.allCases, id: \.self) { Text($0.label).tag($0) } }
            Text("MYP criteria names (A–D) for this type are added automatically; level descriptors stay empty until you import your rubric. You can edit everything later.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Add") { let s = app.store.addSubject(name: name.trimmingCharacters(in: .whitespaces), kind: kind); app.selectedSubjectId = s.id; dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.formStyle(.grouped).frame(width: 460).padding()
    }
}

enum SubjectTab: String, CaseIterable, Identifiable {
    case syllabus, resources, assessments, lessons, boards, quizzes, mistakes, revision, setup
    var id: String { rawValue }
    var title: String { self == .setup ? "Settings" : rawValue.capitalized }
}

struct SubjectWorkspace: View {
    @EnvironmentObject var app: AppState
    let subjectId: String
    @State private var tab: SubjectTab = .syllabus

    var body: some View {
        if let s = app.store.subject(subjectId) {
            VStack(spacing: 0) {
                HStack {
                    Label(s.name, systemImage: s.kind.icon).font(.title2.weight(.semibold))
                    Text(s.framework).font(.caption).padding(.horizontal, 8).padding(.vertical, 2).background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Button { app.startLesson(subjectId: s.id, topicId: nil, focus: "") } label: { Label("Start lesson", systemImage: "graduationcap") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!app.hasAPIKey)
                }.padding(16)
                Picker("", selection: $tab) { ForEach(SubjectTab.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 10)
                Divider()
                switch tab {
                case .syllabus: SyllabusTab(subject: s)
                case .resources: ResourcesTab(subject: s)
                case .assessments: AssessmentsTab(subject: s)
                case .lessons: LessonsTab(subject: s)
                case .boards: BoardsTab(subject: s)
                case .quizzes: QuizzesTab(subject: s)
                case .mistakes: MistakesView(subjectFilter: s.id)
                case .revision: RevisionTab(subject: s)
                case .setup: SubjectSetupTab(subject: s)
                }
            }
        }
    }
}

// MARK: Syllabus

struct SyllabusTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    @State private var newUnit = ""
    @State private var editing: Topic?
    @State private var newTopic = ""
    private var store: StudyStore { app.store }

    var body: some View {
        let units = store.units(in: subject.id)
        let loose = store.topics(in: subject.id).filter { $0.unitId == nil }
        List {
            ForEach(units) { u in
                Section {
                    ForEach(store.topics(in: subject.id).filter { $0.unitId == u.id }) { t in topicRow(t) }
                } header: {
                    HStack { Text(u.title).font(.headline)
                        Spacer()
                        Button { store.deleteUnit(u.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete unit (topics are kept)") }
                }
            }
            Section(units.isEmpty ? "Topics" : "Not in a unit") { ForEach(loose) { t in topicRow(t) } }
            Section {
                HStack { TextField("New unit", text: $newUnit); Button("Add unit") { store.addUnit(subjectId: subject.id, title: newUnit); newUnit = "" }.disabled(newUnit.isEmpty) }
                HStack { TextField("New topic", text: $newTopic); Button("Add topic") { editing = store.addTopic(subjectId: subject.id, title: newTopic); newTopic = "" }.disabled(newTopic.isEmpty) }
            }
        }
        .overlay { if store.topics(in: subject.id).isEmpty && units.isEmpty {
            Text("No syllabus yet. Add topics manually, or import your syllabus in Resources and choose “Organise with Claude”.").foregroundStyle(.secondary).padding().frame(maxWidth: 380).multilineTextAlignment(.center).allowsHitTesting(false)
        } }
        .sheet(item: $editing) { t in TopicEditor(topic: t).environmentObject(app) }
    }

    private func topicRow(_ t: Topic) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                HStack(spacing: 8) {
                    if let p = store.data.progress[t.id], let due = p.due { Text("Review \(relativeDay(due).lowercased())").font(.caption).foregroundStyle(due <= Date() ? Theme.warn : .secondary) }
                    if t.origin == "claude" { Text("added by Claude from your sources").font(.caption).foregroundStyle(.tertiary) }
                    if !t.objectives.isEmpty { Text("\(t.objectives.count) objectives").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            MasteryPill(level: store.masteryLevel(topicId: t.id))
            Button { app.startLesson(subjectId: subject.id, topicId: t.id, focus: "") } label: { Image(systemName: "graduationcap") }.buttonStyle(.borderless).help("Learn this topic").disabled(!app.hasAPIKey)
            Button { editing = t } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
        }
    }
}

struct TopicEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var topic: Topic
    @State private var newObjective = ""

    var body: some View {
        let store = app.store
        Form {
            TextField("Title", text: $topic.title)
            Picker("Unit", selection: Binding(get: { topic.unitId ?? "" }, set: { topic.unitId = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                ForEach(store.units(in: topic.subjectId)) { Text($0.title).tag($0.id) }
            }
            TextField("Summary", text: $topic.summary, axis: .vertical).lineLimit(1...4)
            Section("Learning objectives") {
                ForEach($topic.objectives) { $o in
                    HStack { TextField("Objective", text: $o.text); TextField("Crit.", text: Binding(get: { o.criterion ?? "" }, set: { o.criterion = $0.isEmpty ? nil : $0 })).frame(width: 50) }
                }.onDelete { topic.objectives.remove(atOffsets: $0) }
                HStack { TextField("Add objective", text: $newObjective); Button("Add") { topic.objectives.append(Objective(text: newObjective)); newObjective = "" }.disabled(newObjective.isEmpty) }
            }
            HStack {
                Button("Delete topic", role: .destructive) { store.deleteTopic(topic.id); dismiss() }
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { store.updateTopic(topic); dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }.formStyle(.grouped).frame(width: 520, height: 520)
    }
}

// MARK: Resources & import

struct PendingDoc: Identifiable {
    let id = UUID()
    var doc: ImportedDoc
    var include = true
}

struct ResourcesTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    @State private var pending: [PendingDoc] = []
    @State private var importError: String?
    @State private var editing: Resource?
    private var store: StudyStore { app.store }

    var body: some View {
        let list = store.data.resources.filter { $0.subjectId == subject.id }.sorted { $0.importedAt > $1.importedAt }
        VStack(spacing: 0) {
            HStack {
                Button { importFiles() } label: { Label("Import files…", systemImage: "square.and.arrow.down") }
                Button { editing = Resource(subjectId: subject.id, title: "New note", kind: .note, origin: .student, text: "") } label: { Label("New note", systemImage: "square.and.pencil") }
                Spacer()
                Text("Supported: PDF, TXT, Markdown, RTF, HTML, CSV, and Claude / ChatGPT chat exports (.json)").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            if let e = importError { Text(e).foregroundStyle(Theme.bad).padding(.horizontal, 12) }
            List(list) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title)
                        Text("\(r.kind.label) · \(r.origin == .claude ? "written by Claude" : r.origin == .student ? "your note" : "imported") · \(r.text.count / 1000)k characters\(r.shareWithAI ? "" : " · not shared with Claude")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Organise with Claude") { app.askClaudeToOrganise(resourceId: r.id) }.buttonStyle(.borderless).disabled(!app.hasAPIKey || r.origin == .claude)
                    Button { app.sourceToShow = SourceRef(resourceId: r.id, chunk: 0) } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("View")
                    Button { editing = r } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                }
            }
            .overlay { if list.isEmpty { EmptyHint(icon: "tray.and.arrow.down", title: "No resources yet", message: "Import your notes, textbook extracts, worksheets, rubrics, teacher feedback, syllabus and past Claude chats. Claude will search and cite them while teaching.") } }
        }
        .sheet(item: $editing) { r in ResourceEditor(resource: r).environmentObject(app) }
        .sheet(isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } })) {
            ImportReview(subject: subject, pending: $pending).environmentObject(app)
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .pdf, .json, .rtf, .html, .commaSeparatedText, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        importError = nil
        var docs: [PendingDoc] = []
        for url in panel.urls {
            do {
                for d in try FileImport.read(url: url) { docs.append(PendingDoc(doc: d)) }
            } catch let e as ToolError { importError = (importError.map { $0 + "\n" } ?? "") + e.message }
            catch { importError = (importError.map { $0 + "\n" } ?? "") + "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
        pending = docs
    }
}

enum FileImport {
    static func read(url: URL) throws -> [ImportedDoc] {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let hint: ResourceKind? = ext == "json" ? .chat : nil
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw ToolError("\(name): could not open PDF") }
            var text = ""
            for i in 0..<pdf.pageCount { text += (pdf.page(at: i)?.string ?? "") + "\n\n" }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolError("\(name): this PDF has no selectable text (it looks scanned). OCR is not supported yet.") }
            return [ImportedDoc(title: (name as NSString).deletingPathExtension, kind: .textbook, text: text, sourceName: name)]
        }
        if ext == "rtf" {
            let data = try Data(contentsOf: url)
            let attr = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return [ImportedDoc(title: (name as NSString).deletingPathExtension, kind: .note, text: attr.string, sourceName: name)]
        }
        guard Importer.textExtensions.contains(ext) else { throw ToolError("\(name): .\(ext) files are not supported") }
        return try Importer.parse(data: try Data(contentsOf: url), filename: name, kindHint: hint)
    }
}

struct ImportReview: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let subject: Subject
    @Binding var pending: [PendingDoc]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review import").font(.headline)
            Text("Imported text is stored on this Mac as your original source material. Nothing is sent to Claude until a lesson searches or reads it, and you can turn sharing off per resource.")
                .font(.callout).foregroundStyle(.secondary)
            List($pending) { $p in
                HStack {
                    Toggle("", isOn: $p.include).labelsHidden()
                    VStack(alignment: .leading) {
                        TextField("Title", text: $p.doc.title)
                        Text("\(p.doc.text.count / 1000)k characters from \(p.doc.sourceName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $p.doc.kind) { ForEach(ResourceKind.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 130)
                }
            }.frame(minHeight: 240)
            HStack {
                Button("Select all") { for i in pending.indices { pending[i].include = true } }
                Button("None") { for i in pending.indices { pending[i].include = false } }
                Spacer()
                Button("Cancel") { pending = []; dismiss() }
                Button("Import \(pending.filter { $0.include }.count)") {
                    for p in pending where p.include {
                        app.store.addResource(Resource(subjectId: subject.id, title: p.doc.title, kind: p.doc.kind, origin: .imported, text: p.doc.text, sourceName: p.doc.sourceName))
                    }
                    pending = []; dismiss()
                }.buttonStyle(PrimaryButtonStyle()).disabled(!pending.contains { $0.include })
            }
        }.padding(20).frame(width: 640, height: 460)
    }
}

struct ResourceEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var resource: Resource

    var body: some View {
        let store = app.store
        let exists = store.resource(resource.id) != nil
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $resource.title).font(.headline)
            HStack {
                Picker("Kind", selection: $resource.kind) { ForEach(ResourceKind.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 220)
                Picker("Topic", selection: Binding(get: { resource.topicId ?? "" }, set: { resource.topicId = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag(""); ForEach(store.topics(in: resource.subjectId)) { Text($0.title).tag($0.id) }
                }
                Toggle("Share with Claude", isOn: $resource.shareWithAI)
            }
            if resource.origin == .claude { Text("Written by Claude. Edit freely, but it stays labelled as generated.").font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: $resource.text).font(.body).frame(minHeight: 280).padding(4).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if exists { Button("Delete", role: .destructive) { store.deleteResource(resource.id); dismiss() } }
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { if exists { store.updateResource(resource) } else { store.addResource(resource) }; dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(resource.title.isEmpty)
            }
        }.padding(20).frame(width: 640, height: 520)
    }
}

// MARK: Assessments

struct AssessmentsTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    @State private var editing: Assessment?
    private var store: StudyStore { app.store }

    var body: some View {
        let list = store.data.assessments.filter { $0.subjectId == subject.id }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        VStack(spacing: 0) {
            HStack { Button { editing = Assessment(subjectId: subject.id, title: "") } label: { Label("Add assessment", systemImage: "plus") }; Spacer() }.padding(12)
            List(list) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(a.title).fontWeight(.medium)
                        Spacer()
                        Text(a.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "No date").foregroundStyle(.secondary)
                        Button { editing = a } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    }
                    if !a.criteria.isEmpty { Text("Criteria " + a.criteria.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    if let r = a.result {
                        Text("Result (entered by you): " + r.levels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")).font(.callout)
                        if !r.feedback.isEmpty { Text(r.feedback).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        let p = store.preparation(for: a)
                        if p.total > 0 { Text("\(p.studied)/\(p.total) topics studied · \(p.secure) secure").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .overlay { if list.isEmpty { EmptyHint(icon: "calendar.badge.clock", title: "No assessments", message: "Add upcoming assessments (or let Claude add them from an assessment brief you imported). Grades are only ever what you enter.") } }
        }
        .sheet(item: $editing) { a in AssessmentEditor(assessment: a, subject: subject).environmentObject(app) }
    }
}

struct AssessmentEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var assessment: Assessment
    let subject: Subject
    @State private var hasDate = false
    @State private var date = Date()
    @State private var hasResult = false
    @State private var levels: [String: Int] = [:]
    @State private var feedback = ""

    var body: some View {
        let store = app.store
        Form {
            TextField("Title", text: $assessment.title)
            Toggle("Has a date", isOn: $hasDate)
            if hasDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
            Section("Criteria assessed") {
                ForEach(subject.criteria) { c in
                    Toggle("\(c.code) — \(c.name)", isOn: Binding(get: { assessment.criteria.contains(c.code) }, set: { on in
                        if on { assessment.criteria.append(c.code) } else { assessment.criteria.removeAll { $0 == c.code } }
                    }))
                }
            }
            Section("Topics covered") {
                ForEach(store.topics(in: subject.id)) { t in
                    Toggle(t.title, isOn: Binding(get: { assessment.topicIds.contains(t.id) }, set: { on in
                        if on { assessment.topicIds.append(t.id) } else { assessment.topicIds.removeAll { $0 == t.id } }
                    }))
                }
            }
            Section("Result you received") {
                Toggle("I have a result", isOn: $hasResult)
                if hasResult {
                    ForEach(assessment.criteria.sorted(), id: \.self) { code in
                        Stepper("Criterion \(code): \(levels[code] ?? 0)", value: Binding(get: { levels[code] ?? 0 }, set: { levels[code] = $0 }), in: 0...8)
                    }
                    TextField("Teacher feedback", text: $feedback, axis: .vertical).lineLimit(2...6)
                }
            }
            HStack {
                if store.data.assessments.contains(where: { $0.id == assessment.id }) { Button("Delete", role: .destructive) { store.deleteAssessment(assessment.id); dismiss() } }
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    assessment.date = hasDate ? date : nil
                    assessment.result = hasResult ? AssessmentResult(levels: levels, feedback: feedback) : nil
                    if store.data.assessments.contains(where: { $0.id == assessment.id }) { store.updateAssessment(assessment) } else { store.addAssessment(assessment) }
                    dismiss()
                }.buttonStyle(PrimaryButtonStyle()).disabled(assessment.title.isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 540, height: 640)
        .onAppear {
            if let d = assessment.date { hasDate = true; date = d }
            if let r = assessment.result { hasResult = true; levels = r.levels; feedback = r.feedback }
        }
    }
}

// MARK: Lessons / boards / quizzes / revision / setup

struct LessonsTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    var body: some View {
        let list = app.store.data.lessons.filter { $0.subjectId == subject.id }.sorted { $0.startedAt > $1.startedAt }
        List(list) { l in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.title).fontWeight(.medium)
                    Text(l.startedAt.formatted(date: .abbreviated, time: .shortened) + (l.isActive ? " · in progress" : "")).font(.caption).foregroundStyle(.secondary)
                    if !l.summary.isEmpty { Text(l.summary).font(.callout).foregroundStyle(.secondary) }
                    ForEach(l.nextSteps, id: \.self) { Text("→ \($0)").font(.caption) }
                }
                Spacer()
                Button(l.isActive ? "Resume" : "Open") { app.resumeLesson(l.id) }
            }
        }.overlay { if list.isEmpty { EmptyHint(icon: "graduationcap", title: "No lessons yet", message: "Lessons with Claude are saved here with their board, chat and summary.") } }
    }
}

struct BoardsTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    var body: some View {
        let list = app.store.data.boards.filter { $0.subjectId == subject.id }.sorted { $0.updatedAt > $1.updatedAt }
        List(list) { b in
            HStack {
                VStack(alignment: .leading) { Text(b.title); Text("\(b.objects.count) objects · \(b.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Open") { WhiteboardView.pendingBoardId = b.id; app.route = .whiteboard }
            }
        }.overlay { if list.isEmpty { EmptyHint(icon: "pencil.and.scribble", title: "No boards yet", message: "Every lesson has its own whiteboard; it's saved here.") } }
    }
}

struct QuizzesTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    var body: some View {
        let store = app.store
        let list = store.data.quizzes.filter { $0.subjectId == subject.id }.sorted { $0.createdAt > $1.createdAt }
        List(list) { q in
            let atts = store.data.attempts.filter { $0.quizId == q.id && $0.submittedAt != nil }
            HStack {
                VStack(alignment: .leading) {
                    Text(q.title)
                    Text("\(q.mode.label) · \(q.questions.count) questions · \(q.totalMarks) marks").font(.caption).foregroundStyle(.secondary)
                    ForEach(atts.suffix(3), id: \.id) { a in
                        Text("\((a.submittedAt ?? Date()).formatted(date: .abbreviated, time: .shortened)): \(a.maxMarked > 0 ? "\(Int((a.awardedTotal / Double(a.maxMarked) * 100).rounded()))%" : "unmarked")\(a.hasPending ? " (provisional)" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(atts.isEmpty ? "Take" : "Retake") { app.openQuizId = q.id }
            }
        }.overlay { if list.isEmpty { EmptyHint(icon: "checklist", title: "No quizzes yet", message: "Ask Claude for a quiz in a lesson; it is saved here and its questions feed later practice.") } }
    }
}

struct RevisionTab: View {
    @EnvironmentObject var app: AppState
    let subject: Subject
    var body: some View {
        let store = app.store
        let topics = store.topics(in: subject.id).sorted { (store.data.progress[$0.id]?.due ?? .distantFuture) < (store.data.progress[$1.id]?.due ?? .distantFuture) }
        List(topics) { t in
            let p = store.data.progress[t.id]
            HStack {
                VStack(alignment: .leading) {
                    Text(t.title)
                    Text(p?.due.map { "Next review: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Not scheduled").font(.caption).foregroundStyle(.secondary)
                    if let p = p, !p.events.isEmpty { Text("\(p.events.count) scored sessions · \(p.lapses) lapse\(p.lapses == 1 ? "" : "s") · interval \(Int(p.intervalDays)) day\(Int(p.intervalDays) == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                MasteryPill(level: store.masteryLevel(topicId: t.id))
                Button("Review") { app.startLesson(subjectId: subject.id, topicId: t.id, focus: "Review") }.disabled(!app.hasAPIKey)
            }
        }.overlay { if topics.isEmpty { EmptyHint(icon: "arrow.triangle.2.circlepath", title: "No topics", message: "Spaced repetition works per topic. Add topics in the Syllabus tab.") } }
    }
}

struct SubjectSetupTab: View {
    @EnvironmentObject var app: AppState
    @State var subject: Subject
    @State private var confirmDelete = false
    init(subject: Subject) { _subject = State(initialValue: subject) }

    var body: some View {
        Form {
            TextField("Name", text: $subject.name)
            Picker("Type", selection: $subject.kind) { ForEach(SubjectKind.allCases, id: \.self) { Text($0.label).tag($0) } }
            TextField("Framework", text: $subject.framework)
            Toggle("Allow Claude to read this subject's resources", isOn: $subject.shareWithAI)
            TextField("Notes for your teacher (what helps you learn, goals…)", text: $subject.teachingNotes, axis: .vertical).lineLimit(2...6)
            Section("Assessment criteria (levels 0–8)") {
                ForEach($subject.criteria) { $c in
                    VStack(alignment: .leading) {
                        HStack { TextField("Code", text: $c.code).frame(width: 40); TextField("Name", text: $c.name) }
                        TextField("Descriptor / rubric summary (paste from your rubric)", text: $c.descriptor, axis: .vertical).lineLimit(1...4).font(.caption)
                    }
                }.onDelete { subject.criteria.remove(atOffsets: $0) }
                Button("Add criterion") { subject.criteria.append(Criterion(code: "", name: "")) }
            }
            Section("Command terms") {
                ForEach($subject.commandTerms) { $c in
                    HStack { TextField("Term", text: $c.term).frame(width: 110); TextField("Definition", text: $c.definition) }
                }.onDelete { subject.commandTerms.remove(atOffsets: $0) }
                Button("Add term") { subject.commandTerms.append(CommandTerm(term: "", definition: "")) }
            }
            HStack {
                Button("Delete subject…", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Save changes") { app.store.updateSubject(subject) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(subject.name) and everything in it?", isPresented: $confirmDelete) {
            Button("Delete subject and all its data", role: .destructive) { _ = try? app.store.makeBackup(); app.store.deleteSubject(subject.id); app.selectedSubjectId = app.store.data.subjects.first?.id }
        } message: { Text("Resources, lessons, quizzes, mistakes and progress for this subject will be removed. A backup is kept in Settings → Backups.") }
    }
}
