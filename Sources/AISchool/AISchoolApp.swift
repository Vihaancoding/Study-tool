import SwiftUI
import AppKit
import StudyCore

@main
struct AISchoolApp: App {
    @StateObject private var app = AppState()

    init() {
        // Lets the executable behave as a regular app even when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        Window("Personal AI School", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1040, minHeight: 700)
                .onOpenURL { app.open(url: $0) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Route.allCases) { r in
                    Button(r.title) { app.route = r }.keyboardShortcut(r.key, modifiers: .command)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Lesson…") { app.route = .learn; app.currentLessonId = nil }.keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra("AI School", systemImage: "graduationcap") {
            MenuBarView().environmentObject(app)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            List(Route.allCases, selection: Binding<Route?>(get: { app.route }, set: { if let r = $0 { app.route = r } })) { r in
                Label(r.title, systemImage: r.icon).tag(r)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                if app.currentLessonId != nil && app.route != .learn {
                    Button { app.route = .learn } label: { Label("Lesson in progress", systemImage: "circle.fill").font(.caption).foregroundStyle(Theme.good) }
                        .buttonStyle(.plain).padding(10)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let b = app.banner {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(b).font(.callout)
                        Spacer()
                        Button("Dismiss") { app.banner = nil }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.warn.opacity(0.12))
                }
                if let e = app.store.lastSaveError {
                    Text(e).font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.bad.opacity(0.12))
                }
                Group {
                    switch app.route {
                    case .home: HomeView()
                    case .learn: LearnView()
                    case .whiteboard: WhiteboardView()
                    case .practice: PracticeView()
                    case .subjects: SubjectsView()
                    case .mistakes: MistakesView()
                    case .schedule: ScheduleView()
                    case .settings: SettingsView()
                    }
                }
            }
        }
        .sheet(item: $app.sourceToShow) { ref in SourceViewer(ref: ref).environmentObject(app) }
        .sheet(isPresented: Binding(get: { app.openQuizId != nil && app.route != .learn }, set: { if !$0 { app.openQuizId = nil } })) {
            if let qid = app.openQuizId {
                QuizRunnerView(quizId: qid, onClose: { app.openQuizId = nil }).environmentObject(app).frame(minWidth: 760, minHeight: 600)
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let store = app.store
        let b = store.briefing()
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.headline)
            Text(b.headline).font(.callout)
            ForEach(b.lines, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if let r = b.recommendation, let t = store.topic(r.topicId) {
                Button { open(); app.startLesson(subjectId: t.subjectId, topicId: t.id, focus: "") } label: { Label("Start lesson: \(t.title)", systemImage: "graduationcap") }
            }
            if let l = store.activeLesson {
                Button { open(); app.resumeLesson(l.id) } label: { Label("Continue: \(l.title)", systemImage: "play.circle") }
            }
            Button { open(); app.startBankQuiz(mode: .quick, subjectId: nil) } label: { Label("Quick quiz", systemImage: "bolt") }
            Button { open(); app.route = .home } label: { Label("Open AI School", systemImage: "macwindow") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(14).frame(width: 300)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
