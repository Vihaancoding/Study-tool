import SwiftUI
import Charts
import StudyCore

struct HomeView: View {
    @EnvironmentObject var app: AppState
    private var store: StudyStore { app.store }

    var body: some View {
        let now = Date()
        let briefing = store.briefing(now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(now)
                todaySection(briefing)
                if store.data.subjects.isEmpty || !app.hasAPIKey || store.data.resources.isEmpty { setup }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        dueSection(now).card().frame(maxWidth: .infinity, alignment: .topLeading)
                        weakSection.card().frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        assessmentsSection(now).card().frame(maxWidth: .infinity, alignment: .topLeading)
                        recentSection.card().frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                progressSection(now).card().frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }

    private func header(_ now: Date) -> some View {
        let hour = Calendar.current.component(.hour, from: now)
        let greet = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        let name = store.data.student.name
        return VStack(alignment: .leading, spacing: 4) {
            Text(name.isEmpty ? greet : "\(greet), \(name)").font(.system(size: 34, weight: .bold))
            Text(now.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Get set up")
            checklistRow("Add your Anthropic API key", done: app.hasAPIKey) { app.route = .settings }
            checklistRow("Add a subject", done: !store.data.subjects.isEmpty) { app.route = .subjects }
            checklistRow("Import notes, chats, rubrics or a syllabus", done: !store.data.resources.isEmpty) { app.route = .subjects }
            checklistRow("Start your first lesson", done: !store.data.lessons.isEmpty) { app.route = .learn }
        }.quietPanel()
    }

    private func checklistRow(_ text: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.good : .secondary)
                Text(text).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                Spacer()
                if !done { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }.buttonStyle(.plain)
    }

    private func todaySection(_ b: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TODAY").font(.system(size: 11.5, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.75))
            Text(b.headline).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(b.lines, id: \.self) { Text($0).foregroundStyle(.white.opacity(0.9)) }
                if let r = b.recommendation { ForEach(r.reasons.prefix(3), id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.white.opacity(0.8)) } }
            }
            HStack(spacing: 12) {
                if let r = b.recommendation, let t = store.topic(r.topicId) {
                    Button { app.startLesson(subjectId: t.subjectId, topicId: t.id, focus: "") } label: { Label("Start: \(t.title)", systemImage: "play.fill") }
                        .buttonStyle(HeroButtonStyle()).disabled(!app.hasAPIKey)
                } else if !store.data.subjects.isEmpty {
                    Button { app.route = .learn } label: { Label("Start a lesson", systemImage: "play.fill") }.buttonStyle(HeroButtonStyle())
                } else {
                    Button { app.route = .subjects } label: { Label("Add your first subject", systemImage: "plus") }.buttonStyle(HeroButtonStyle())
                }
                if let l = store.activeLesson {
                    Button { app.resumeLesson(l.id) } label: { Label("Continue “\(l.title)”", systemImage: "arrow.right.circle") }
                        .buttonStyle(.plain).foregroundStyle(.white).font(.system(size: 14, weight: .semibold))
                } else if let last = store.data.lessons.filter({ !$0.nextSteps.isEmpty }).sorted(by: { $0.startedAt > $1.startedAt }).first {
                    Text("Last time: " + last.nextSteps[0]).font(.callout).foregroundStyle(.white.opacity(0.85))
                }
            }.padding(.top, 4)
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color(red: 0.4, green: 0.3, blue: 0.9).opacity(0.3), radius: 20, y: 10)
    }

    private func dueSection(_ now: Date) -> some View {
        let due = store.dueTopics(now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack { SectionTitle("Revision due"); Spacer()
                if !store.questionBank().isEmpty { Button("Quick quiz") { app.startBankQuiz(mode: .quick, subjectId: nil) }.buttonStyle(.borderless) } }
            if due.isEmpty { Text("Nothing is due. Reviews appear here as spaced-repetition dates arrive.").foregroundStyle(.secondary).font(.callout) }
            ForEach(due.prefix(6)) { t in
                Button { app.startLesson(subjectId: t.subjectId, topicId: t.id, focus: "Review") } label: {
                    HStack { VStack(alignment: .leading) { Text(t.title); Text(store.subject(t.subjectId)?.name ?? "").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); MasteryPill(level: store.masteryLevel(topicId: t.id)) }
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var weakSection: some View {
        let weak = store.weakTopics()
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Needs attention")
            if weak.isEmpty { Text("No weak topics detected from your quiz results yet.").foregroundStyle(.secondary).font(.callout) }
            ForEach(weak.prefix(5)) { t in
                let acc = store.recentAccuracy(topicId: t.id)
                Button { app.startLesson(subjectId: t.subjectId, topicId: t.id, focus: "Fix what I keep getting wrong") } label: {
                    HStack { Text(t.title); Spacer()
                        if let a = acc { Text("\(Int((a.score * 100).rounded()))% of last \(a.count)").font(.caption).foregroundStyle(Theme.bad) } }
                }.buttonStyle(.plain)
            }
            let patterns = store.errorPatterns().prefix(3)
            if !patterns.isEmpty {
                Text("Recurring: " + patterns.map { "\($0.category.label) (\($0.count))" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func assessmentsSection(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Upcoming assessments")
            let list = store.upcomingAssessments(now: now)
            if list.isEmpty { Text("No upcoming assessments saved. Add them in a subject, or import an assessment brief.").foregroundStyle(.secondary).font(.callout) }
            ForEach(list.prefix(5)) { a in
                let prep = store.preparation(for: a)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(a.title).fontWeight(.medium); Spacer(); Text(a.date.map { relativeDay($0) } ?? "").foregroundStyle(.secondary) }
                    Text(store.subject(a.subjectId)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    if prep.total > 0 {
                        ProgressView(value: Double(prep.studied), total: Double(prep.total))
                        Text("\(prep.studied) of \(prep.total) topics studied · \(prep.secure) secure").font(.caption).foregroundStyle(.secondary)
                    } else { Text("No topics linked yet — preparation can't be measured.").font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
            }
        }
    }

    private var recentSection: some View {
        let recent = Dictionary(grouping: store.data.lessons, by: { $0.subjectId }).compactMap { (sid, ls) -> (Subject, Date)? in
            guard let s = store.subject(sid), let d = ls.map({ $0.startedAt }).max() else { return nil }
            return (s, d)
        }.sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Recently studied")
            if recent.isEmpty { Text("Your lessons will appear here.").foregroundStyle(.secondary).font(.callout) }
            ForEach(recent.prefix(4), id: \.0.id) { s, d in
                Button { app.selectedSubjectId = s.id; app.route = .subjects } label: {
                    HStack { Label(s.name, systemImage: s.kind.icon); Spacer(); Text(relativeDay(d)).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
        }
    }

    private func progressSection(_ now: Date) -> some View {
        let data = store.dailyAccuracy(days: 14, now: now)
        let topics = store.data.topics
        let seen = topics.filter { store.masteryLevel(topicId: $0.id) != .unseen }.count
        let secure = topics.filter { store.masteryLevel(topicId: $0.id) == .secure }.count
        let questions = store.data.attempts.filter { $0.finalized }.reduce(0) { $0 + $1.marks.filter { !$0.pending && $0.max > 0 }.count }
        let weekMinutes = (0..<7).reduce(0) { acc, d in acc + store.studyMinutes(on: Calendar.current.date(byAdding: .day, value: -d, to: now) ?? now) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Progress (from your saved results)")
            HStack(spacing: 40) {
                stat("\(seen)/\(topics.count)", "topics started")
                stat("\(secure)", "topics secure")
                stat("\(questions)", "questions answered")
                stat("\(weekMinutes) min", "lessons this week")
            }
            if data.count >= 2 {
                Chart(data, id: \.day) { d in
                    LineMark(x: .value("Day", d.day, unit: .day), y: .value("Accuracy", d.accuracy * 100))
                    PointMark(x: .value("Day", d.day, unit: .day), y: .value("Accuracy", d.accuracy * 100))
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Quiz accuracy %")
                .frame(height: 150)
            } else {
                Text("The accuracy chart appears after quizzes on two different days.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading) { Text(v).font(.system(size: 28, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
}
