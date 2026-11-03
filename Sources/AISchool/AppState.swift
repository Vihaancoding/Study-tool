import Foundation
import SwiftUI
import StudyCore
import UserNotifications
import ServiceManagement

enum Route: String, CaseIterable, Identifiable {
    case home, learn, whiteboard, practice, subjects, mistakes, schedule, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: return "house"
        case .learn: return "graduationcap"
        case .whiteboard: return "pencil.and.scribble"
        case .practice: return "checklist"
        case .subjects: return "books.vertical"
        case .mistakes: return "exclamationmark.bubble"
        case .schedule: return "calendar"
        case .settings: return "gearshape"
        }
    }
    var key: KeyEquivalent {
        let order = Route.allCases.firstIndex(of: self) ?? 0
        return KeyEquivalent(Character(String(order + 1)))
    }
}

struct OutboundEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class AppState: ObservableObject {
    let store: StudyStore
    let notifications = NotificationManager()

    @Published var route: Route = .home
    @Published var selectedSubjectId: String?
    @Published var openQuizId: String?
    @Published var learnPane: LearnPane = .board
    @Published var currentLessonId: String?
    @Published var hasAPIKey: Bool = Keychain.read() != nil
    @Published var banner: String?
    @Published var outbound: [OutboundEntry] = []
    @Published var sourceToShow: SourceRef?
    @Published var launchAtLogin: Bool = false

    private var sessions: [String: TeacherSession] = [:]
    private var rescheduleTask: Task<Void, Never>?

    init(store: StudyStore = StudyStore(directory: StudyStore.defaultDirectory)) {
        self.store = store
        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.scheduleNotificationRefresh() }
        }
        store.onUIEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        currentLessonId = store.activeLesson?.id
        if let s = store.data.subjects.first { selectedSubjectId = s.id }
        notifications.onOpenLink = { [weak self] url in self?.open(url: url) }
        do { _ = try store.makeBackup() } catch { /* first launch has nothing to back up */ }
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        Task { await notifications.refreshStatus(); scheduleNotificationRefresh() }
    }

    // MARK: UI events from the store (including those caused by Claude's tools)

    private func handle(_ event: UIEvent) {
        switch event {
        case .lessonOpened(let id):
            currentLessonId = id
            route = .learn
        case .showBoard:
            learnPane = .board
        case .launchQuiz(let id):
            openQuizId = id
            learnPane = .quiz
        case .showSource(let id):
            if let r = store.resource(id) { sourceToShow = SourceRef(resourceId: r.id, chunk: 0) }
        case .dataChanged:
            objectWillChange.send()
        }
    }

    func session(for lessonId: String) -> TeacherSession {
        if let s = sessions[lessonId] { return s }
        let s = TeacherSession(lessonId: lessonId, app: self)
        sessions[lessonId] = s
        return s
    }

    var currentSession: TeacherSession? { currentLessonId.map { session(for: $0) } }

    // MARK: Lessons

    func startLesson(subjectId: String, topicId: String?, focus: String) {
        let topic = store.topic(topicId)
        let title = topic?.title ?? (focus.isEmpty ? "Lesson" : String(focus.prefix(60)))
        let lesson = store.startLesson(subjectId: subjectId, topicId: topicId, title: title)
        currentLessonId = lesson.id
        route = .learn
        learnPane = .board
        var msg = "Let's start a lesson"
        if let t = topic { msg += " on \(t.title)" }
        if !focus.isEmpty { msg += ". Focus: \(focus)" }
        msg += "."
        session(for: lesson.id).send(msg)
    }

    func resumeLesson(_ id: String) {
        currentLessonId = id
        route = .learn
    }

    func notifyQuizSubmitted(quizId: String, attemptId: String) {
        guard let l = store.activeLesson, l.quizIds.contains(quizId), hasAPIKey, let q = store.quiz(quizId) else { return }
        session(for: l.id).send("I've submitted the quiz “\(q.title)”. Please read my answers, mark anything that needs marking, and go through the results with me.")
    }

    // MARK: Quick quizzes (work offline, from the saved question bank)

    func startBankQuiz(mode: QuizMode, subjectId: String?) {
        guard let quiz = store.buildQuizFromBank(mode: mode, subjectId: subjectId) else {
            banner = "No saved questions yet. Start a lesson and ask Claude for a quiz — questions are kept for later practice."
            route = .practice
            return
        }
        store.addQuiz(quiz)
        openQuizId = quiz.id
        learnPane = .quiz
        if route != .learn { route = .practice }
    }

    // MARK: Deep links (notifications, menu bar)

    func open(url: URL) {
        guard url.scheme == "aischool" else { return }
        let host = url.host ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { if let v = item.value, q[item.name] == nil { q[item.name] = v } }
        switch host {
        case "home": route = .home
        case "schedule": route = .schedule
        case "mistakes": route = .mistakes
        case "subjects": route = .subjects
        case "learn":
            if let tid = q["topic"], let t = store.topic(tid) { startLesson(subjectId: t.subjectId, topicId: tid, focus: "Review") } else { route = .learn }
        case "quiz":
            startBankQuiz(mode: url.path.contains("adaptive") ? .adaptive : .quick, subjectId: nil)
        case "source":
            if let id = q["id"] { sourceToShow = SourceRef(resourceId: id, chunk: Int(q["chunk"] ?? "0") ?? 0) }
        default: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Notifications

    func scheduleNotificationRefresh() {
        rescheduleTask?.cancel()
        rescheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let plan = self.store.plannedNotifications()
            await self.notifications.reschedule(plan)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            } catch { banner = "Couldn't change login item: \(error.localizedDescription)" }
        }
    }

    func logOutbound(_ text: String) {
        outbound.append(OutboundEntry(text: text))
        if outbound.count > 200 { outbound.removeFirst(outbound.count - 200) }
    }
}

enum LearnPane: String, CaseIterable, Identifiable {
    case board, quiz, sources
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct SourceRef: Identifiable, Equatable {
    var id: String { "\(resourceId)#\(chunk)" }
    var resourceId: String
    var chunk: Int
}

extension AppState {
    /// Opens (or reuses) a lesson and asks Claude to mark a submitted attempt.
    func askClaudeToMark(attemptId: String) {
        guard hasAPIKey, let att = store.attempt(attemptId), let quiz = store.quiz(att.quizId) else {
            banner = hasAPIKey ? "That attempt could not be found." : "Add your API key in Settings so Claude can mark this."
            return
        }
        var lessonId = store.activeLesson?.id
        if lessonId == nil {
            lessonId = store.startLesson(subjectId: quiz.subjectId, topicId: nil, title: "Marking: \(quiz.title)").id
        }
        guard let lid = lessonId else { return }
        store.updateLesson(lid) { if !$0.quizIds.contains(quiz.id) { $0.quizIds.append(quiz.id) } }
        currentLessonId = lid
        route = .learn
        learnPane = .quiz
        session(for: lid).send("Please mark my quiz “\(quiz.title)” (attempt \(attemptId)). Read my answers with get_quiz_results, mark everything that needs marking with mark_response, then go through the results with me.")
    }
}

extension AppState {
    /// Starts a lesson whose only job is to turn an imported resource into curriculum structure, using tools.
    func askClaudeToOrganise(resourceId: String) {
        guard hasAPIKey, let r = store.resource(resourceId), let s = store.subject(r.subjectId) else {
            banner = hasAPIKey ? "Resource not found." : "Add your API key in Settings first."
            return
        }
        let lesson = store.startLesson(subjectId: s.id, topicId: nil, title: "Organise: \(r.title)")
        currentLessonId = lesson.id
        route = .learn
        session(for: lesson.id).send("""
        Please organise my imported material “\(r.title)” (resource id \(r.id)) into my \(s.name) curriculum. \
        Read it with read_source (all chunks), check what already exists with list_curriculum, then use curriculum_add to add only the units, topics, learning objectives and assessments that the text actually supports (include source_refs). \
        Do not invent dates or content. Afterwards tell me what you added and what was unclear, and ask me about anything you were unsure of.
        """)
    }
}
