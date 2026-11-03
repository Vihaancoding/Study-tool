import Foundation

public func newID(_ prefix: String) -> String {
    prefix + "_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
}

// MARK: - Curriculum

public enum SubjectKind: String, Codable, CaseIterable {
    case mathematics, science, language, humanities, arts, design, general
    public var label: String {
        switch self {
        case .mathematics: return "Mathematics"
        case .science: return "Science"
        case .language: return "Language"
        case .humanities: return "Humanities"
        case .arts: return "Arts"
        case .design: return "Design"
        case .general: return "General"
        }
    }
    public var icon: String {
        switch self {
        case .mathematics: return "function"
        case .science: return "atom"
        case .language: return "character.book.closed"
        case .humanities: return "globe.europe.africa"
        case .arts: return "paintpalette"
        case .design: return "pencil.and.ruler"
        case .general: return "book"
        }
    }
    /// Short guidance given to Claude so teaching adapts to the subject type.
    public var teachingFocus: String {
        switch self {
        case .mathematics: return "Work through equations one step at a time on the board; have the student complete the next step; check working, not just answers."
        case .science: return "Use diagrams and labelled models on the board; practise calculations with units and significant figures; train precise scientific terminology and command terms."
        case .language: return "Practise vocabulary, grammar and production; use short retrieval drills and corrections of the student's own sentences."
        case .humanities: return "Use timelines, evidence maps and cause-and-effect diagrams; practise source analysis and developing structured arguments (point, evidence, explanation, link)."
        case .arts, .design: return "Focus on analysis, process and reflection; use the board for annotated sketches and structured critique."
        case .general: return "Adapt to the material the student has imported."
        }
    }
}

public struct Criterion: Codable, Equatable, Identifiable {
    public var code: String
    public var name: String
    public var maxLevel: Int
    public var descriptor: String
    public var id: String { code }
    public init(code: String, name: String, maxLevel: Int = 8, descriptor: String = "") {
        self.code = code; self.name = name; self.maxLevel = maxLevel; self.descriptor = descriptor
    }
}

public struct CommandTerm: Codable, Equatable, Identifiable {
    public var term: String
    public var definition: String
    public var id: String { term }
    public init(term: String, definition: String) { self.term = term; self.definition = definition }
}

public struct Subject: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var kind: SubjectKind
    public var framework: String
    public var criteria: [Criterion]
    public var commandTerms: [CommandTerm]
    public var teachingNotes: String
    public var shareWithAI: Bool
    public var createdAt: Date

    public init(id: String = newID("sub"), name: String, kind: SubjectKind, framework: String = "MYP",
                criteria: [Criterion] = [], commandTerms: [CommandTerm] = [], teachingNotes: String = "",
                shareWithAI: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.framework = framework
        self.criteria = criteria; self.commandTerms = commandTerms; self.teachingNotes = teachingNotes
        self.shareWithAI = shareWithAI; self.createdAt = createdAt
    }
}

public struct CurriculumUnit: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var title: String
    public var order: Int
    public var notes: String
    public init(id: String = newID("unit"), subjectId: String, title: String, order: Int = 0, notes: String = "") {
        self.id = id; self.subjectId = subjectId; self.title = title; self.order = order; self.notes = notes
    }
}

public struct Objective: Codable, Identifiable, Equatable {
    public var id: String
    public var text: String
    public var criterion: String?
    public var sourceRef: String?
    public init(id: String = newID("obj"), text: String, criterion: String? = nil, sourceRef: String? = nil) {
        self.id = id; self.text = text; self.criterion = criterion; self.sourceRef = sourceRef
    }
}

public struct Topic: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var unitId: String?
    public var title: String
    public var summary: String
    public var objectives: [Objective]
    public var sourceRefs: [String]
    public var origin: String   // "student", "import", "claude"
    public var createdAt: Date
    public init(id: String = newID("top"), subjectId: String, unitId: String? = nil, title: String,
                summary: String = "", objectives: [Objective] = [], sourceRefs: [String] = [],
                origin: String = "student", createdAt: Date = Date()) {
        self.id = id; self.subjectId = subjectId; self.unitId = unitId; self.title = title
        self.summary = summary; self.objectives = objectives; self.sourceRefs = sourceRefs
        self.origin = origin; self.createdAt = createdAt
    }
}

public struct AssessmentResult: Codable, Equatable {
    public var levels: [String: Int]     // criterion code -> level achieved (entered by the student)
    public var feedback: String
    public var recordedAt: Date
    public init(levels: [String: Int] = [:], feedback: String = "", recordedAt: Date = Date()) {
        self.levels = levels; self.feedback = feedback; self.recordedAt = recordedAt
    }
}

public struct Assessment: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var title: String
    public var date: Date?
    public var criteria: [String]
    public var topicIds: [String]
    public var notes: String
    public var result: AssessmentResult?
    public var sourceRef: String?
    public init(id: String = newID("asm"), subjectId: String, title: String, date: Date? = nil,
                criteria: [String] = [], topicIds: [String] = [], notes: String = "",
                result: AssessmentResult? = nil, sourceRef: String? = nil) {
        self.id = id; self.subjectId = subjectId; self.title = title; self.date = date
        self.criteria = criteria; self.topicIds = topicIds; self.notes = notes
        self.result = result; self.sourceRef = sourceRef
    }
}

// MARK: - Resources

public enum ResourceKind: String, Codable, CaseIterable {
    case syllabus, note, chat, textbook, worksheet, assessment, feedback, rubric, other
    public var label: String { rawValue.capitalized }
}

public enum ResourceOrigin: String, Codable {
    case imported   // came from the student's own files
    case student    // typed/edited by the student in the app
    case claude     // generated by Claude; never treated as original source material
}

public struct Resource: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var topicId: String?
    public var title: String
    public var kind: ResourceKind
    public var origin: ResourceOrigin
    public var text: String
    public var sourceName: String
    public var importedAt: Date
    public var shareWithAI: Bool
    public init(id: String = newID("res"), subjectId: String, topicId: String? = nil, title: String,
                kind: ResourceKind = .note, origin: ResourceOrigin = .imported, text: String,
                sourceName: String = "", importedAt: Date = Date(), shareWithAI: Bool = true) {
        self.id = id; self.subjectId = subjectId; self.topicId = topicId; self.title = title
        self.kind = kind; self.origin = origin; self.text = text; self.sourceName = sourceName
        self.importedAt = importedAt; self.shareWithAI = shareWithAI
    }
}

// MARK: - Progress

public struct ScoreEvent: Codable, Equatable {
    public var date: Date
    public var score: Double        // 0...1
    public var weight: Int          // number of questions (or 1 for lesson observations)
    public var source: String       // "quiz:<id>" or "lesson:<id>"
    public init(date: Date, score: Double, weight: Int, source: String) {
        self.date = date; self.score = score; self.weight = weight; self.source = source
    }
}

public struct TopicProgress: Codable, Equatable {
    public var topicId: String
    public var ease: Double
    public var intervalDays: Double
    public var reps: Int
    public var lapses: Int
    public var due: Date?
    public var lastStudied: Date?
    public var events: [ScoreEvent]
    public var understandingNote: String?
    public init(topicId: String) {
        self.topicId = topicId; ease = 2.3; intervalDays = 0; reps = 0; lapses = 0
        due = nil; lastStudied = nil; events = []; understandingNote = nil
    }
}

public enum MasteryLevel: String, Codable {
    case unseen, struggling, learning, provisional, secure
    public var label: String {
        switch self {
        case .unseen: return "Not started"
        case .struggling: return "Struggling"
        case .learning: return "Learning"
        case .provisional: return "Looks good — unconfirmed"
        case .secure: return "Secure"
        }
    }
}

public enum ErrorCategory: String, Codable, CaseIterable {
    case conceptual, recall, calculation, missingUnits, sigFigs, terminology
    case incompleteExplanation, undevelopedArgument, commandTerm, misreadQuestion, careless, other
    public var label: String {
        switch self {
        case .conceptual: return "Misunderstood concept"
        case .recall: return "Forgot a fact"
        case .calculation: return "Calculation error"
        case .missingUnits: return "Missing / wrong units"
        case .sigFigs: return "Significant figures"
        case .terminology: return "Imprecise terminology"
        case .incompleteExplanation: return "Incomplete explanation"
        case .undevelopedArgument: return "Argument not developed"
        case .commandTerm: return "Command term not addressed"
        case .misreadQuestion: return "Misread the question"
        case .careless: return "Careless slip"
        case .other: return "Other"
        }
    }
}

public struct FollowUp: Codable, Equatable {
    public var date: Date
    public var correct: Bool
    public var quizId: String?
    public init(date: Date, correct: Bool, quizId: String? = nil) { self.date = date; self.correct = correct; self.quizId = quizId }
}

public struct Mistake: Codable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var subjectId: String
    public var topicId: String?
    public var question: String
    public var studentAnswer: String
    public var correctReasoning: String
    public var category: ErrorCategory
    public var criterion: String?
    public var quizId: String?
    public var questionId: String?
    public var lessonId: String?
    public var marksLost: Double
    public var resolved: Bool
    public var followUps: [FollowUp]
    public init(id: String = newID("mis"), date: Date = Date(), subjectId: String, topicId: String? = nil,
                question: String, studentAnswer: String, correctReasoning: String, category: ErrorCategory,
                criterion: String? = nil, quizId: String? = nil, questionId: String? = nil, lessonId: String? = nil,
                marksLost: Double = 0, resolved: Bool = false, followUps: [FollowUp] = []) {
        self.id = id; self.date = date; self.subjectId = subjectId; self.topicId = topicId
        self.question = question; self.studentAnswer = studentAnswer; self.correctReasoning = correctReasoning
        self.category = category; self.criterion = criterion; self.quizId = quizId; self.questionId = questionId
        self.lessonId = lessonId; self.marksLost = marksLost; self.resolved = resolved; self.followUps = followUps
    }
}

// MARK: - Quizzes

public enum QuestionType: String, Codable, CaseIterable {
    case single, multi, trueFalse, short, extended, calculation, equationCompletion, diagramLabel
    public var label: String {
        switch self {
        case .single: return "Single choice"
        case .multi: return "Multiple select"
        case .trueFalse: return "True / false"
        case .short: return "Short answer"
        case .extended: return "Extended response"
        case .calculation: return "Calculation"
        case .equationCompletion: return "Equation completion"
        case .diagramLabel: return "Diagram labelling"
        }
    }
}

public struct CalcSpec: Codable, Equatable {
    public var answer: Double
    public var tolerancePercent: Double
    public var unit: String?
    public var unitAlternatives: [String]
    public var sigFigs: Int?
    public var requireWorking: Bool
    public init(answer: Double, tolerancePercent: Double = 1, unit: String? = nil, unitAlternatives: [String] = [],
                sigFigs: Int? = nil, requireWorking: Bool = false) {
        self.answer = answer; self.tolerancePercent = tolerancePercent; self.unit = unit
        self.unitAlternatives = unitAlternatives; self.sigFigs = sigFigs; self.requireWorking = requireWorking
    }
}

public struct LabelTarget: Codable, Identifiable, Equatable {
    public var id: String
    public var x: Double
    public var y: Double
    public var answer: String
    public var acceptable: [String]
    public init(id: String, x: Double, y: Double, answer: String, acceptable: [String] = []) {
        self.id = id; self.x = x; self.y = y; self.answer = answer; self.acceptable = acceptable
    }
}

public struct Question: Codable, Identifiable, Equatable {
    public var id: String
    public var type: QuestionType
    public var prompt: String
    public var options: [String]
    public var correct: [Int]
    public var acceptable: [String]
    public var keywords: [String]
    public var modelAnswer: String
    public var rubric: String
    public var marks: Int
    public var hint: String?
    public var topicId: String?
    public var criterion: String?
    public var commandTerm: String?
    public var calc: CalcSpec?
    public var blanks: [String]
    public var labels: [LabelTarget]
    public var labelBank: [String]
    public var boardId: String?
    public var sourceRefs: [String]
    public var testsMistakeId: String?
    public var difficulty: Int

    public init(id: String = newID("q"), type: QuestionType, prompt: String, options: [String] = [], correct: [Int] = [],
                acceptable: [String] = [], keywords: [String] = [], modelAnswer: String = "", rubric: String = "",
                marks: Int = 1, hint: String? = nil, topicId: String? = nil, criterion: String? = nil,
                commandTerm: String? = nil, calc: CalcSpec? = nil, blanks: [String] = [], labels: [LabelTarget] = [],
                labelBank: [String] = [], boardId: String? = nil, sourceRefs: [String] = [],
                testsMistakeId: String? = nil, difficulty: Int = 2) {
        self.id = id; self.type = type; self.prompt = prompt; self.options = options; self.correct = correct
        self.acceptable = acceptable; self.keywords = keywords; self.modelAnswer = modelAnswer; self.rubric = rubric
        self.marks = marks; self.hint = hint; self.topicId = topicId; self.criterion = criterion
        self.commandTerm = commandTerm; self.calc = calc; self.blanks = blanks; self.labels = labels
        self.labelBank = labelBank; self.boardId = boardId; self.sourceRefs = sourceRefs
        self.testsMistakeId = testsMistakeId; self.difficulty = difficulty
    }
}

public enum QuizMode: String, Codable, CaseIterable {
    case practice, timed, exam, retrieval, adaptive, quick
    public var label: String {
        switch self {
        case .practice: return "Practice"
        case .timed: return "Timed quiz"
        case .exam: return "Exam simulation"
        case .retrieval: return "Mixed retrieval"
        case .adaptive: return "Adaptive"
        case .quick: return "Quick quiz"
        }
    }
}

public struct Quiz: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var title: String
    public var mode: QuizMode
    public var timeLimitSeconds: Int?
    public var questions: [Question]
    public var createdAt: Date
    public var createdBy: String
    public var lessonId: String?
    public init(id: String = newID("quiz"), subjectId: String, title: String, mode: QuizMode = .practice,
                timeLimitSeconds: Int? = nil, questions: [Question], createdAt: Date = Date(),
                createdBy: String = "claude", lessonId: String? = nil) {
        self.id = id; self.subjectId = subjectId; self.title = title; self.mode = mode
        self.timeLimitSeconds = timeLimitSeconds; self.questions = questions; self.createdAt = createdAt
        self.createdBy = createdBy; self.lessonId = lessonId
    }
    public var totalMarks: Int { questions.reduce(0) { $0 + $1.marks } }
}

public struct Answer: Codable, Equatable {
    public var questionId: String
    public var text: String
    public var selected: [Int]
    public var unit: String
    public var working: String
    public var blanks: [String]
    public var labels: [String: String]
    public var hintUsed: Bool
    public init(questionId: String, text: String = "", selected: [Int] = [], unit: String = "", working: String = "",
                blanks: [String] = [], labels: [String: String] = [:], hintUsed: Bool = false) {
        self.questionId = questionId; self.text = text; self.selected = selected; self.unit = unit
        self.working = working; self.blanks = blanks; self.labels = labels; self.hintUsed = hintUsed
    }
}

public struct QuestionMark: Codable, Equatable {
    public var questionId: String
    public var awarded: Double
    public var max: Int
    public var feedback: String
    public var betterAnswer: String
    public var errorCategories: [ErrorCategory]
    public var criterion: String?
    public var uncertainty: String?
    public var markedBy: String      // "auto" or "claude"
    public var pending: Bool         // waiting for Claude (reasoning/rubric marking)
    public init(questionId: String, awarded: Double, max: Int, feedback: String = "", betterAnswer: String = "",
                errorCategories: [ErrorCategory] = [], criterion: String? = nil, uncertainty: String? = nil,
                markedBy: String = "auto", pending: Bool = false) {
        self.questionId = questionId; self.awarded = awarded; self.max = max; self.feedback = feedback
        self.betterAnswer = betterAnswer; self.errorCategories = errorCategories; self.criterion = criterion
        self.uncertainty = uncertainty; self.markedBy = markedBy; self.pending = pending
    }
}

public struct Attempt: Codable, Identifiable, Equatable {
    public var id: String
    public var quizId: String
    public var subjectId: String
    public var startedAt: Date
    public var submittedAt: Date?
    public var answers: [Answer]
    public var marks: [QuestionMark]
    public var finalized: Bool
    public var timeExpired: Bool
    public init(id: String = newID("att"), quizId: String, subjectId: String, startedAt: Date = Date(),
                submittedAt: Date? = nil, answers: [Answer] = [], marks: [QuestionMark] = [],
                finalized: Bool = false, timeExpired: Bool = false) {
        self.id = id; self.quizId = quizId; self.subjectId = subjectId; self.startedAt = startedAt
        self.submittedAt = submittedAt; self.answers = answers; self.marks = marks
        self.finalized = finalized; self.timeExpired = timeExpired
    }
    public var awardedTotal: Double { marks.filter { !$0.pending }.reduce(0) { $0 + $1.awarded } }
    public var maxMarked: Int { marks.filter { !$0.pending }.reduce(0) { $0 + $1.max } }
    public var hasPending: Bool { marks.contains { $0.pending } }
}

// MARK: - Lessons, schedule, settings

public struct ChatEntry: Codable, Identifiable, Equatable {
    public enum Role: String, Codable { case user, assistant, tool, system }
    public var id: String
    public var role: Role
    public var text: String
    public var date: Date
    public var isError: Bool
    public init(id: String = newID("msg"), role: Role, text: String, date: Date = Date(), isError: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.date = date; self.isError = isError
    }
}

public struct LessonSession: Codable, Identifiable, Equatable {
    public var id: String
    public var subjectId: String
    public var topicId: String?
    public var title: String
    public var objectives: [String]
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String
    public var topicsCovered: [String]
    public var nextSteps: [String]
    public var boardId: String
    public var quizIds: [String]
    public var style: String
    public var messages: [ChatEntry]
    public var apiHistory: [JSON]
    public var isActive: Bool { endedAt == nil }
    public init(id: String = newID("les"), subjectId: String, topicId: String? = nil, title: String,
                objectives: [String] = [], startedAt: Date = Date(), endedAt: Date? = nil, summary: String = "",
                topicsCovered: [String] = [], nextSteps: [String] = [], boardId: String, quizIds: [String] = [],
                style: String = "socratic", messages: [ChatEntry] = [], apiHistory: [JSON] = []) {
        self.id = id; self.subjectId = subjectId; self.topicId = topicId; self.title = title
        self.objectives = objectives; self.startedAt = startedAt; self.endedAt = endedAt; self.summary = summary
        self.topicsCovered = topicsCovered; self.nextSteps = nextSteps; self.boardId = boardId
        self.quizIds = quizIds; self.style = style; self.messages = messages; self.apiHistory = apiHistory
    }
}

public enum ScheduleKind: String, Codable { case review, followUp, quiz, assessmentPrep, custom }

public struct ScheduleItem: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: ScheduleKind
    public var subjectId: String?
    public var topicId: String?
    public var title: String
    public var body: String
    public var due: Date
    public var notify: Bool
    public var createdBy: String
    public var done: Bool
    public init(id: String = newID("sch"), kind: ScheduleKind, subjectId: String? = nil, topicId: String? = nil,
                title: String, body: String = "", due: Date, notify: Bool = true, createdBy: String = "student",
                done: Bool = false) {
        self.id = id; self.kind = kind; self.subjectId = subjectId; self.topicId = topicId; self.title = title
        self.body = body; self.due = due; self.notify = notify; self.createdBy = createdBy; self.done = done
    }
}

public struct StudentProfile: Codable, Equatable {
    public var name: String
    public var yearGroup: String
    public var notes: String
    public init(name: String = "", yearGroup: String = "", notes: String = "") {
        self.name = name; self.yearGroup = yearGroup; self.notes = notes
    }
}

public struct AppSettings: Codable, Equatable {
    public var model: String = "claude-sonnet-5-5"
    public var teachingStyle: String = "socratic"
    public var morningBriefing: Bool = true
    public var morningMinutes: Int = 7 * 60 + 30
    public var eveningSummary: Bool = false
    public var eveningMinutes: Int = 19 * 60 + 30
    public var assessmentReminders: Bool = true
    public var reviewReminders: Bool = true
    public var followUpReminders: Bool = true
    public var quizPrompts: Bool = false
    public var quietStartMinutes: Int = 21 * 60 + 30
    public var quietEndMinutes: Int = 7 * 60
    public var maxPerDay: Int = 3
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        teachingStyle = try c.decodeIfPresent(String.self, forKey: .teachingStyle) ?? d.teachingStyle
        morningBriefing = try c.decodeIfPresent(Bool.self, forKey: .morningBriefing) ?? d.morningBriefing
        morningMinutes = try c.decodeIfPresent(Int.self, forKey: .morningMinutes) ?? d.morningMinutes
        eveningSummary = try c.decodeIfPresent(Bool.self, forKey: .eveningSummary) ?? d.eveningSummary
        eveningMinutes = try c.decodeIfPresent(Int.self, forKey: .eveningMinutes) ?? d.eveningMinutes
        assessmentReminders = try c.decodeIfPresent(Bool.self, forKey: .assessmentReminders) ?? d.assessmentReminders
        reviewReminders = try c.decodeIfPresent(Bool.self, forKey: .reviewReminders) ?? d.reviewReminders
        followUpReminders = try c.decodeIfPresent(Bool.self, forKey: .followUpReminders) ?? d.followUpReminders
        quizPrompts = try c.decodeIfPresent(Bool.self, forKey: .quizPrompts) ?? d.quizPrompts
        quietStartMinutes = try c.decodeIfPresent(Int.self, forKey: .quietStartMinutes) ?? d.quietStartMinutes
        quietEndMinutes = try c.decodeIfPresent(Int.self, forKey: .quietEndMinutes) ?? d.quietEndMinutes
        maxPerDay = try c.decodeIfPresent(Int.self, forKey: .maxPerDay) ?? d.maxPerDay
    }
}

public struct StudyData: Codable, Equatable {
    public var version: Int = 1
    public var student = StudentProfile()
    public var subjects: [Subject] = []
    public var units: [CurriculumUnit] = []
    public var topics: [Topic] = []
    public var assessments: [Assessment] = []
    public var resources: [Resource] = []
    public var progress: [String: TopicProgress] = [:]
    public var mistakes: [Mistake] = []
    public var quizzes: [Quiz] = []
    public var attempts: [Attempt] = []
    public var boards: [Board] = []
    public var lessons: [LessonSession] = []
    public var schedule: [ScheduleItem] = []
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        student = try c.decodeIfPresent(StudentProfile.self, forKey: .student) ?? StudentProfile()
        subjects = try c.decodeIfPresent([Subject].self, forKey: .subjects) ?? []
        units = try c.decodeIfPresent([CurriculumUnit].self, forKey: .units) ?? []
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        assessments = try c.decodeIfPresent([Assessment].self, forKey: .assessments) ?? []
        resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        progress = try c.decodeIfPresent([String: TopicProgress].self, forKey: .progress) ?? [:]
        mistakes = try c.decodeIfPresent([Mistake].self, forKey: .mistakes) ?? []
        quizzes = try c.decodeIfPresent([Quiz].self, forKey: .quizzes) ?? []
        attempts = try c.decodeIfPresent([Attempt].self, forKey: .attempts) ?? []
        boards = try c.decodeIfPresent([Board].self, forKey: .boards) ?? []
        lessons = try c.decodeIfPresent([LessonSession].self, forKey: .lessons) ?? []
        schedule = try c.decodeIfPresent([ScheduleItem].self, forKey: .schedule) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}
