import Foundation

public struct Briefing {
    public var headline: String
    public var lines: [String]
    public var recommendation: Recommendation?
    public var isEmpty: Bool { lines.isEmpty }
}

public struct PlannedNotification: Equatable {
    public enum Category: Int { case assessment = 0, briefing, review, followUp, scheduled, quiz, evening }
    public var id: String
    public var fire: Date
    public var title: String
    public var body: String
    public var link: String          // aischool://... deep link
    public var category: Category
}

extension StudyStore {

    /// Plain-language briefing built only from stored data.
    public func briefing(now: Date = Date()) -> Briefing {
        var lines: [String] = []
        let cal = Calendar.current
        let due = dueTopics(now: now)
        if !due.isEmpty {
            lines.append("\(due.count) topic\(due.count == 1 ? "" : "s") due for review: " + due.prefix(3).map { $0.title }.joined(separator: ", ") + (due.count > 3 ? "…" : ""))
        }
        for a in upcomingAssessments(now: now, days: 14).prefix(2) {
            let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: now), to: a.date ?? now).day ?? 0)
            let prep = preparation(for: a)
            var s = "\(a.title) \(days == 0 ? "is today" : days == 1 ? "is tomorrow" : "is in \(days) days")"
            if prep.total > 0 { s += " — \(prep.studied) of \(prep.total) topics studied, \(prep.secure) secure" }
            lines.append(s)
        }
        let weak = weakTopics()
        if !weak.isEmpty { lines.append("Needs attention: " + weak.prefix(3).map { $0.title }.joined(separator: ", ")) }
        let rec = recommendations(now: now).first
        var headline = "Nothing is scheduled yet"
        if let r = rec { headline = "Start with \(r.title)" }
        else if !data.subjects.isEmpty { headline = "You're up to date" }
        else { headline = "Add a subject and import your material to begin" }
        return Briefing(headline: headline, lines: lines, recommendation: rec)
    }

    // MARK: Notification planning

    public func plannedNotifications(now: Date = Date(), horizonDays: Int = 7) -> [PlannedNotification] {
        let s = data.settings
        let cal = Calendar.current
        var plan: [PlannedNotification] = []

        func at(_ dayOffset: Int, minutes: Int) -> Date? {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { return nil }
            return cal.date(byAdding: .minute, value: minutes, to: day)
        }

        for d in 0..<horizonDays {
            guard let day = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now)) else { continue }
            let key = DateCodec.day(day)

            if s.morningBriefing, let t = at(d, minutes: s.morningMinutes) {
                let asOf = max(t, now)
                let b = briefing(now: asOf)
                if !b.isEmpty || b.recommendation != nil {
                    let body = ([b.headline] + b.lines.prefix(2)).joined(separator: "\n")
                    plan.append(PlannedNotification(id: "briefing-\(key)", fire: t, title: "Good morning — today's study", body: body,
                                                    link: "aischool://home", category: .briefing))
                }
            }

            if s.reviewReminders, let t = at(d, minutes: 17 * 60), d < 4 {
                let endOfDay = cal.date(byAdding: .day, value: 1, to: day) ?? day
                let due = dueTopics(now: endOfDay)
                if !due.isEmpty {
                    plan.append(PlannedNotification(id: "review-\(key)", fire: t, title: "Short review ready",
                                                    body: "\(due.count) topic\(due.count == 1 ? "" : "s") ready for spaced review, starting with \(due[0].title). About 5 minutes.",
                                                    link: "aischool://quiz/quick", category: .review))
                }
            }

            if s.followUpReminders, d % 2 == 1 || d == 0, let t = at(d, minutes: 16 * 60) {
                if let w = weakTopics().first {
                    plan.append(PlannedNotification(id: "followup-\(key)", fire: t, title: "Try again, gently",
                                                    body: "A few fresh questions on \(w.title) — you've had trouble here recently, so a short retry will help it stick.",
                                                    link: "aischool://quiz/adaptive", category: .followUp))
                }
            }

            if s.quizPrompts, let t = at(d, minutes: 15 * 60 + 30), d < 5, !questionBank().isEmpty {
                plan.append(PlannedNotification(id: "quiz-\(key)", fire: t, title: "2-minute quiz",
                                                body: "A handful of questions chosen from what's due or shaky. Skip it any time.",
                                                link: "aischool://quiz/quick", category: .quiz))
            }

            if s.eveningSummary, let t = at(d, minutes: s.eveningMinutes) {
                var body = "A quick look back at today and what's coming up tomorrow."
                if d == 0 {
                    let answered = data.attempts.filter { a in a.finalized && (a.submittedAt.map { cal.isDate($0, inSameDayAs: now) } ?? false) }
                        .reduce(0) { $0 + $1.marks.filter { !$0.pending }.count }
                    let mins = studyMinutes(on: now)
                    if answered > 0 || mins > 0 { body = "Today: \(mins) min of lessons, \(answered) question\(answered == 1 ? "" : "s") answered." }
                }
                plan.append(PlannedNotification(id: "evening-\(key)", fire: t, title: "Evening summary", body: body,
                                                link: "aischool://schedule", category: .evening))
            }
        }

        if s.assessmentReminders {
            for a in upcomingAssessments(now: now, days: horizonDays + 8) {
                guard let when = a.date else { continue }
                let prep = preparation(for: a)
                let prepText = prep.total > 0 ? " \(prep.studied) of \(prep.total) topics studied." : ""
                for before in [7, 3, 1, 0] {
                    guard let day = cal.date(byAdding: .day, value: -before, to: cal.startOfDay(for: when)),
                          let t = cal.date(byAdding: .minute, value: s.morningMinutes + 30, to: day) else { continue }
                    let label = before == 0 ? "today" : before == 1 ? "tomorrow" : "in \(before) days"
                    plan.append(PlannedNotification(id: "asm-\(a.id)-\(before)", fire: t, title: "\(a.title) \(label)",
                                                    body: "Preparation check:" + prepText + " Open a lesson to cover what's left.",
                                                    link: "aischool://schedule", category: .assessment))
                }
            }
        }

        for item in data.schedule where item.notify && !item.done {
            plan.append(PlannedNotification(id: "item-\(item.id)", fire: item.due, title: item.title, body: item.body,
                                            link: item.topicId.map { "aischool://learn?topic=\($0)" } ?? "aischool://schedule",
                                            category: .scheduled))
        }

        return Self.limit(plan, settings: s, now: now, horizonDays: horizonDays)
    }

    /// Applies quiet hours, drops the past, enforces a daily cap and minimum spacing so it never feels punitive.
    static func limit(_ plan: [PlannedNotification], settings s: AppSettings, now: Date, horizonDays: Int) -> [PlannedNotification] {
        let cal = Calendar.current
        func minuteOfDay(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
        func inQuiet(_ m: Int) -> Bool {
            let a = s.quietStartMinutes, b = s.quietEndMinutes
            if a == b { return false }
            return a < b ? (m >= a && m < b) : (m >= a || m < b)
        }
        var adjusted: [PlannedNotification] = []
        for var n in plan {
            if inQuiet(minuteOfDay(n.fire)) {
                // Move to the end of quiet hours on the same calendar day; otherwise drop rather than pile up.
                let endMinutes = s.quietEndMinutes
                let dayStart = cal.startOfDay(for: n.fire)
                guard let moved = cal.date(byAdding: .minute, value: endMinutes, to: dayStart), moved > n.fire || minuteOfDay(n.fire) < endMinutes else { continue }
                if minuteOfDay(n.fire) < endMinutes { n.fire = moved } else { continue }
            }
            if n.fire <= now.addingTimeInterval(60) { continue }
            adjusted.append(n)
        }
        var result: [PlannedNotification] = []
        let byDay = Dictionary(grouping: adjusted) { cal.startOfDay(for: $0.fire) }
        for (_, list) in byDay {
            var kept: [PlannedNotification] = []
            for n in list.sorted(by: { ($0.category.rawValue, $0.fire) < ($1.category.rawValue, $1.fire) }) {
                if kept.count >= max(1, s.maxPerDay) { break }
                if kept.contains(where: { abs($0.fire.timeIntervalSince(n.fire)) < 90 * 60 }) { continue }
                kept.append(n)
            }
            result.append(contentsOf: kept)
        }
        return result.sorted { $0.fire < $1.fire }
    }
}
