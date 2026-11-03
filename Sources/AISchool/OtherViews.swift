import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import StudyCore

// MARK: Whiteboard (standalone boards)

struct WhiteboardView: View {
    @EnvironmentObject var app: AppState
    static var pendingBoardId: String?
    @State private var selected: String?
    @State private var renaming: Board?
    @State private var newTitle = ""
    private var store: StudyStore { app.store }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(store.data.boards.sorted { $0.updatedAt > $1.updatedAt }, selection: $selected) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title)
                        Text("\(store.subject(b.subjectId)?.name ?? "No subject") · \(b.objects.count) objects").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(b.id)
                    .contextMenu {
                        Button("Rename…") { renaming = b; newTitle = b.title }
                        Button("Delete", role: .destructive) { store.deleteBoard(b.id); if selected == b.id { selected = nil } }
                    }
                }
                Divider()
                Button { let b = store.createBoard(title: "Untitled board", subjectId: app.selectedSubjectId, lessonId: nil); selected = b.id } label: { Label("New board", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10)
            }.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            Group {
                if let id = selected, store.board(id) != nil { BoardEditor(boardId: id).id(id) }
                else { EmptyHint(icon: "pencil.and.scribble", title: "Whiteboard", message: "Create a board to sketch, solve and annotate. Boards from lessons appear here too — Claude draws on the lesson's board while it teaches.") }
            }.frame(minWidth: 520)
        }
        .onAppear {
            if let p = WhiteboardView.pendingBoardId { selected = p; WhiteboardView.pendingBoardId = nil }
            else if selected == nil { selected = store.data.boards.sorted { $0.updatedAt > $1.updatedAt }.first?.id }
        }
        .alert("Rename board", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let b = renaming { store.mutateBoard(b.id, undoable: false) { $0.title = newTitle } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: Practice

struct PracticeView: View {
    @EnvironmentObject var app: AppState
    @State private var subjectId = ""
    private var store: StudyStore { app.store }

    var body: some View {
        let bank = store.questionBank(subjectId: subjectId.isEmpty ? nil : subjectId)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Practice").font(.system(size: 34, weight: .bold))
                Picker("Subject", selection: $subjectId) {
                    Text("All subjects").tag("")
                    ForEach(store.data.subjects) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 320)
                if bank.isEmpty {
                    EmptyHint(icon: "checklist", title: "No saved questions yet", message: "Quizzes Claude creates in a lesson are stored here. Once you have some, you can run quick, adaptive, mixed and exam practice without a lesson.")
                    Button { app.route = .learn } label: { Label("Start a lesson and ask for a quiz", systemImage: "graduationcap") }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Text("\(bank.count) saved question\(bank.count == 1 ? "" : "s") available").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], alignment: .leading, spacing: 16) {
                        mode("Quick quiz", "6 questions, prioritising what's due or shaky.", "bolt", .quick)
                        mode("Adaptive", "Weighted towards topics you struggle with.", "scope", .adaptive)
                        mode("Mixed retrieval", "Interleaves topics to test recall.", "shuffle", .retrieval)
                        mode("Exam simulation", "Timed, no hints encouraged, whole subject.", "timer", .exam)
                    }
                }
                HStack {
                    Button { app.route = .learn } label: { Label("Ask Claude for a new quiz in a lesson", systemImage: "sparkles") }.buttonStyle(.borderless)
                }
                let quizzes = store.data.quizzes.filter { subjectId.isEmpty || $0.subjectId == subjectId }.sorted { $0.createdAt > $1.createdAt }
                if !quizzes.isEmpty {
                    SectionTitle("History")
                    ForEach(quizzes.prefix(20)) { q in
                        let atts = store.data.attempts.filter { $0.quizId == q.id && $0.submittedAt != nil }
                        HStack {
                            VStack(alignment: .leading) {
                                Text(q.title)
                                Text("\(store.subject(q.subjectId)?.name ?? "") · \(q.mode.label) · \(q.createdAt.formatted(date: .abbreviated, time: .omitted))\(q.createdBy == "claude" ? " · by Claude" : "")").font(.caption).foregroundStyle(.secondary)
                                if let a = atts.last, a.maxMarked > 0 { Text("Last: \(Int((a.awardedTotal / Double(a.maxMarked) * 100).rounded()))%\(a.hasPending ? " (provisional)" : "")").font(.caption) }
                            }
                            Spacer()
                            if let a = atts.last { Button("Results") { app.openQuizId = q.id; _ = a } }
                            Button(atts.isEmpty ? "Take" : "Retake") { app.openQuizId = q.id }
                        }
                        Divider()
                    }
                }
            }.padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func mode(_ title: String, _ detail: String, _ icon: String, _ m: QuizMode) -> some View {
        Button { app.startBankQuiz(mode: m, subjectId: subjectId.isEmpty ? nil : subjectId) } label: {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: icon, color: Route.practice.tint, size: 34)
                Text(title).font(.system(size: 17, weight: .bold))
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading).card()
        }.buttonStyle(.plain).hoverLift()
    }
}

// MARK: Mistakes

struct MistakesView: View {
    @EnvironmentObject var app: AppState
    var subjectFilter: String? = nil
    @State private var search = ""
    @State private var category: ErrorCategory?
    @State private var showResolved = false
    private var store: StudyStore { app.store }

    var body: some View {
        let all = store.data.mistakes.filter { subjectFilter == nil || $0.subjectId == subjectFilter }
        let shown = all.filter { m in
            (showResolved || !m.resolved) && (category == nil || m.category == category) &&
            (search.isEmpty || [m.question, m.studentAnswer, m.correctReasoning, store.topic(m.topicId)?.title ?? ""].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.date > $1.date }
        VStack(spacing: 0) {
            let patterns = store.errorPatterns(subjectId: subjectFilter).prefix(4)
            if !patterns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("Patterns")
                    HStack(spacing: 8) {
                        ForEach(Array(patterns), id: \.category) { p in
                            Button { category = category == p.category ? nil : p.category } label: {
                                Text("\(p.category.label) · \(p.count)\(p.recentCount > 0 ? " (\(p.recentCount) recent)" : "")").font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(category == p.category ? Theme.accent.opacity(0.25) : Theme.bad.opacity(0.1), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                Divider()
            }
            HStack {
                TextField("Search mistakes", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Toggle("Show resolved", isOn: $showResolved)
                Spacer()
                Text("\(shown.count) shown").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            List(shown) { m in MistakeRow(mistake: m) }
                .overlay { if all.isEmpty { EmptyHint(icon: "exclamationmark.bubble", title: "No mistakes logged", message: "Mistakes from quizzes and lessons are saved here automatically with the correct reasoning, so you and Claude can target them.") } }
        }
    }
}

struct MistakeRow: View {
    @EnvironmentObject var app: AppState
    let mistake: Mistake
    @State private var open = false

    var body: some View {
        let store = app.store
        let m = mistake
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.category.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.bad)
                if let t = store.topic(m.topicId) { Text(t.title).font(.caption).foregroundStyle(.secondary) }
                if let c = m.criterion { Text("Criterion \(c)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if m.resolved { Label("Resolved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.good) }
                Text(m.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Text(m.question).lineLimit(open ? nil : 2)
            if open {
                Text("Your answer: ").font(.callout.weight(.medium)) + Text(m.studentAnswer).font(.callout)
                Text("Correct reasoning: ").font(.callout.weight(.medium)) + Text(m.correctReasoning).font(.callout)
                if !m.followUps.isEmpty { Text("Follow-ups: " + m.followUps.map { $0.correct ? "✓" : "✗" }.joined(separator: " ")).font(.caption) }
                HStack {
                    if let tid = m.topicId, let t = store.topic(tid) {
                        Button("Practise this topic") { app.startLesson(subjectId: t.subjectId, topicId: tid, focus: "Retest me on my mistake: \(m.question.prefix(120)) (mistake id \(m.id))") }.disabled(!app.hasAPIKey)
                    }
                    Button(m.resolved ? "Mark unresolved" : "Mark resolved") { store.mutate { d in if let i = d.mistakes.firstIndex(where: { $0.id == m.id }) { d.mistakes[i].resolved.toggle() } } }
                    Button("Delete", role: .destructive) { store.mutate { $0.mistakes.removeAll { $0.id == m.id } } }
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { open.toggle() }
        .padding(.vertical, 4)
    }
}

// MARK: Schedule

struct ScheduleView: View {
    @EnvironmentObject var app: AppState
    @State private var adding = false
    private var store: StudyStore { app.store }

    private struct Row: Identifiable { let id: String; let date: Date; let title: String; let detail: String; let icon: String; let action: (() -> Void)? }

    var body: some View {
        let rows = makeRows()
        let planned = store.plannedNotifications()
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("Schedule").font(.system(size: 34, weight: .bold)); Spacer()
                    Button { adding = true } label: { Label("Add reminder", systemImage: "plus") } }
                if rows.isEmpty { EmptyHint(icon: "calendar", title: "Nothing scheduled", message: "Reviews, assessments and reminders appear here. Claude schedules reviews at the end of lessons.") }
                ForEach(rows) { r in
                    HStack(alignment: .top) {
                        Image(systemName: r.icon).frame(width: 22).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) { Text(r.title); Text(r.detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(relativeDay(r.date)).foregroundStyle(r.date < Calendar.current.startOfDay(for: Date()) ? Theme.warn : .secondary)
                        if let a = r.action { Button("Start", action: a).disabled(!app.hasAPIKey) }
                    }
                    Divider()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Notifications queued by macOS")
                    if !app.notifications.isAvailable {
                        Text("Notifications need the packaged app. Build it with scripts/build_app.sh and open AISchool.app.").font(.callout).foregroundStyle(Theme.warn)
                    } else if app.notifications.status != .authorized {
                        Text("Notifications are off. Allow them in Settings → Notifications.").font(.callout).foregroundStyle(Theme.warn)
                    }
                    if planned.isEmpty { Text("No notifications are planned for the next 7 days (quiet hours, daily limit and your settings applied).").font(.callout).foregroundStyle(.secondary) }
                    ForEach(planned, id: \.id) { n in
                        HStack(alignment: .top) {
                            Text(n.fire.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit()).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                            VStack(alignment: .leading) { Text(n.title).font(.callout); Text(n.body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) { AddReminderSheet().environmentObject(app) }
    }

    private func makeRows() -> [Row] {
        var rows: [Row] = []
        for t in store.data.topics {
            if let due = store.data.progress[t.id]?.due {
                rows.append(Row(id: "rev-\(t.id)", date: due, title: "Review: \(t.title)", detail: (store.subject(t.subjectId)?.name ?? "") + " · " + store.masteryLevel(topicId: t.id).label,
                                icon: "arrow.triangle.2.circlepath", action: { app.startLesson(subjectId: t.subjectId, topicId: t.id, focus: "Review") }))
            }
        }
        for a in store.upcomingAssessments(days: 120) {
            let p = store.preparation(for: a)
            rows.append(Row(id: "asm-\(a.id)", date: a.date ?? Date(), title: a.title, detail: (store.subject(a.subjectId)?.name ?? "") + (p.total > 0 ? " · \(p.studied)/\(p.total) topics studied" : ""), icon: "doc.text", action: nil))
        }
        for s in store.data.schedule where !s.done && s.kind != .review {
            rows.append(Row(id: s.id, date: s.due, title: s.title, detail: s.body, icon: "bell", action: nil))
        }
        return rows.sorted { $0.date < $1.date }
    }
}

struct AddReminderSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var due = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    var body: some View {
        Form {
            TextField("Reminder", text: $title)
            TextField("Note", text: $note)
            DatePicker("When", selection: $due)
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Add") { app.store.addScheduleItem(ScheduleItem(kind: .custom, title: title, body: note, due: due)); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(title.isEmpty) }
        }.formStyle(.grouped).frame(width: 420).padding()
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var keyField = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var backupMessage: String?
    @State private var restoreCandidate: URL?
    private var store: StudyStore { app.store }

    var body: some View {
        Form {
            Section("Claude") {
                HStack {
                    SecureField(app.hasAPIKey ? "API key saved in Keychain — paste a new one to replace" : "Anthropic API key (sk-ant-…)", text: $keyField)
                    Button("Save") { if Keychain.save(keyField.trimmingCharacters(in: .whitespacesAndNewlines)) { app.hasAPIKey = true; keyField = ""; testResult = nil } }
                        .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasAPIKey { Button("Remove", role: .destructive) { Keychain.delete(); app.hasAPIKey = false } }
                }
                Picker("Model", selection: Binding(get: { store.data.settings.model }, set: { m in store.mutate { $0.settings.model = m } })) {
                    Text("Claude Sonnet 5.5 (balanced)").tag("claude-sonnet-5-5")
                    Text("Claude Opus 5.5 (strongest)").tag("claude-opus-5-5")
                    Text("Claude Haiku 5.5 (fastest)").tag("claude-haiku-5-5")
                    if !["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"].contains(store.data.settings.model) { Text(store.data.settings.model).tag(store.data.settings.model) }
                }
                TextField("Custom model id", text: Binding(get: { store.data.settings.model }, set: { m in store.mutate { $0.settings.model = m } }))
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(!app.hasAPIKey || testing)
                    if let r = testResult { Text(r).font(.callout).foregroundStyle(r.hasPrefix("Connected") ? Theme.good : Theme.bad) }
                }
                Text("Get a key at console.anthropic.com. API use is billed to your Anthropic account, separately from a Claude subscription.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About you") {
                TextField("Your name", text: Binding(get: { store.data.student.name }, set: { v in store.mutate { $0.student.name = v } }))
                TextField("Year / grade (e.g. MYP 4)", text: Binding(get: { store.data.student.yearGroup }, set: { v in store.mutate { $0.student.yearGroup = v } }))
                TextField("Anything Claude should know about how you learn", text: Binding(get: { store.data.student.notes }, set: { v in store.mutate { $0.student.notes = v } }), axis: .vertical).lineLimit(2...5)
                Picker("Default teaching style", selection: Binding(get: { store.data.settings.teachingStyle }, set: { v in store.mutate { $0.settings.teachingStyle = v } })) {
                    ForEach(TeacherPrompt.styles, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
            notificationSection
            Section("Privacy: what leaves this Mac") {
                Text("Everything is stored locally in ~/Library/Application Support/PersonalAISchool. The API key lives in the macOS Keychain.").font(.callout)
                Text("Only when you chat with Claude, the app sends to Anthropic: the lesson instructions, your messages, and whatever Claude asks for through tools — your learning profile summary, search results from your notes (short passages, only from resources with sharing on), your mistakes, whiteboard contents and a picture of the board, and your quiz answers. Imported files are never uploaded wholesale. Turn sharing off per resource or per subject. Briefings, reminders, quick quizzes and marking of objective questions run entirely on your Mac.").font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Recent transmissions (this session)") {
                    if app.outbound.isEmpty { Text("Nothing sent yet.").foregroundStyle(.secondary) }
                    ForEach(app.outbound.suffix(30).reversed()) { e in
                        Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.text)").font(.caption.monospaced())
                    }
                }
            }
            Section("Data") {
                HStack {
                    Button("Back up now") { do { let u = try store.makeBackup(); backupMessage = "Saved \(u.lastPathComponent)" } catch { backupMessage = error.localizedDescription } }
                    Button("Export JSON…") { export(json: true) }
                    Button("Export study report…") { export(json: false) }
                    Button("Show data folder") { NSWorkspace.shared.open(store.directory) }
                }
                if let m = backupMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Restore from a backup") {
                    ForEach(store.listBackups().prefix(10), id: \.self) { u in
                        HStack { Text(u.lastPathComponent).font(.caption.monospaced()); Spacer(); Button("Restore…") { restoreCandidate = u } }
                    }
                    Button("Choose a file…") { chooseRestoreFile() }
                }
            }
            Section("Launch") {
                Toggle("Open at login (keeps reminders fresh in the background)", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace all current data with this backup?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })) {
            Button("Restore (current data is backed up first)", role: .destructive) {
                if let u = restoreCandidate { do { try store.restore(from: u); backupMessage = "Restored." } catch { backupMessage = "Restore failed: \(error.localizedDescription)" } }
                restoreCandidate = nil
            }
        }
        .task { await app.notifications.refreshStatus() }
    }

    private var notificationSection: some View {
        Section("Notifications") {
            let n = app.notifications
            if !n.isAvailable {
                Text("Run the packaged app (scripts/build_app.sh) to use native notifications.").foregroundStyle(Theme.warn).font(.callout)
            } else {
                HStack {
                    Text("Permission: " + statusText(n.status))
                    Spacer()
                    if n.status == .notDetermined { Button("Allow notifications") { Task { await n.requestPermission(); app.scheduleNotificationRefresh() } } }
                    else if n.status == .denied { Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) } }
                    else { Button("Send test") { Task { await n.sendTest() } } }
                }
                Text("\(n.pendingCount) scheduled with macOS. They are delivered even when the window is closed; the app refreshes them whenever your data changes or it opens.").font(.caption).foregroundStyle(.secondary)
            }
            toggle("Morning briefing", \.morningBriefing)
            if store.data.settings.morningBriefing { minutesPicker("Briefing time", \.morningMinutes) }
            toggle("Assessment reminders (7, 3 and 1 day before, and on the day)", \.assessmentReminders)
            toggle("Spaced-repetition reminders", \.reviewReminders)
            toggle("Follow-up practice for topics I struggled with", \.followUpReminders)
            toggle("Short optional quiz prompts", \.quizPrompts)
            toggle("Evening summary", \.eveningSummary)
            if store.data.settings.eveningSummary { minutesPicker("Summary time", \.eveningMinutes) }
            minutesPicker("Quiet hours start", \.quietStartMinutes)
            minutesPicker("Quiet hours end", \.quietEndMinutes)
            Stepper("At most \(store.data.settings.maxPerDay) per day", value: Binding(get: { store.data.settings.maxPerDay }, set: { v in store.mutate { $0.settings.maxPerDay = v } }), in: 1...6)
        }
    }

    private func toggle(_ title: String, _ kp: WritableKeyPath<AppSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { store.data.settings[keyPath: kp] }, set: { v in store.mutate { $0.settings[keyPath: kp] = v } }))
    }

    private func minutesPicker(_ title: String, _ kp: WritableKeyPath<AppSettings, Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: store.data.settings[keyPath: kp] / 60, minute: store.data.settings[keyPath: kp] % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            store.mutate { $0.settings[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        }), displayedComponents: .hourAndMinute)
    }

    private func statusText(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized, .provisional, .ephemeral: return "allowed"
        case .denied: return "denied in System Settings"
        default: return "not requested yet"
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let key = Keychain.read() else { testResult = "No key saved."; return }
        let client = ClaudeClient(apiKey: key, model: store.data.settings.model)
        do {
            _ = try await client.send(system: "Reply with the single word OK.", messages: [["role": "user", "content": "ping"]], tools: [], maxTokens: 16)
            testResult = "Connected ✓ (\(store.data.settings.model))"
        } catch { testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func export(json: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = json ? "ai-school-export.json" : "study-report.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { if json { try store.exportJSON(to: url) } else { try store.exportMarkdown(to: url) }; backupMessage = "Exported to \(url.lastPathComponent)" }
        catch { backupMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { restoreCandidate = panel.url }
    }
}
