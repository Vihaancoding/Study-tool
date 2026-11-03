import Foundation

public struct Recommendation: Identifiable {
    public var id: String { (topicId ?? subjectId) + title }
    public var subjectId: String
    public var topicId: String?
    public var title: String
    public var reasons: [String]
    public var priority: Double
}

public struct ErrorPattern {
    public var category: ErrorCategory
    public var count: Int
    public var recentCount: Int          // last 14 days
    public var topicTitles: [String]
}

public enum SRS {
    /// Map a 0...1 performance score to an SM-2 style quality 0...5.
    public static func quality(_ score: Double) -> Int {
        switch score {
        case 0.9...: return 5
        case 0.75...: return 4
        case 0.6...: return 3
        case 0.4...: return 2
        case 0.2...: return 1
        default: return 0
        }
    }

    /// Updates a topic's schedule from one scored event. Failure brings the topic back sooner;
    /// success stretches the interval, scaled by ease.
    public static func update(_ p: inout TopicProgress, score: Double, weight: Int, source: String, now: Date) {
        p.events.append(ScoreEvent(date: now, score: score, weight: weight, source: source))
        if p.events.count > 60 { p.events.removeFirst(p.events.count - 60) }
        p.lastStudied = now
        let q = quality(score)
        if q < 3 {
            p.reps = 0
            p.lapses += 1
            p.intervalDays = q <= 1 ? 0.5 : 1
            p.ease = max(1.3, p.ease - 0.2)
        } else {
            p.reps += 1
            if p.reps == 1 { p.intervalDays = 1 }
            else if p.reps == 2 { p.intervalDays = 3 }
            else { p.intervalDays = max(p.intervalDays * p.ease, p.intervalDays + 1).rounded() }
            let d = Double(5 - q)
            p.ease = max(1.3, p.ease + 0.1 - d * (0.08 + d * 0.02))
        }
        p.due = now.addingTimeInterval(p.intervalDays * 86400)
    }

    /// Mastery requires repeated success on separate days with a lengthening interval; one lucky answer
    /// only reaches `.provisional`.
    public static func mastery(_ p: TopicProgress?, now: Date = Date()) -> MasteryLevel {
        guard let p = p, !p.events.isEmpty else { return .unseen }
        let recent = Array(p.events.suffix(4))
        let weighted = recent.reduce(0.0) { $0 + $1.score * Double($1.weight) }
        let w = recent.reduce(0) { $0 + $1.weight }
        let avg = w > 0 ? weighted / Double(w) : 0
        let cal = Calendar.current
        let days = Set(p.events.filter { $0.score >= 0.75 }.map { cal.startOfDay(for: $0.date) }).count
        if avg < 0.5 || (p.reps == 0 && p.lapses > 0 && avg < 0.65) { return .struggling }
        if days >= 3 && avg >= 0.8 && p.intervalDays >= 6 && p.reps >= 3 { return .secure }
        if days <= 1 && avg >= 0.75 { return .provisional }
        return .learning
    }
}

extension StudyStore {

    public func masteryLevel(topicId: String, now: Date = Date()) -> MasteryLevel {
        SRS.mastery(data.progress[topicId], now: now)
    }

    public func recentAccuracy(topicId: String, last n: Int = 4) -> (score: Double, count: Int)? {
        guard let p = data.progress[topicId], !p.events.isEmpty else { return nil }
        let ev = Array(p.events.suffix(n))
        let w = ev.reduce(0) { $0 + $1.weight }
        guard w > 0 else { return nil }
        return (ev.reduce(0.0) { $0 + $1.score * Double($1.weight) } / Double(w), w)
    }

    public func recordScore(topicId: String, score: Double, weight: Int, source: String, now: Date = Date()) {
        guard topic(topicId) != nil else { return }
        mutate { d in
            var p = d.progress[topicId] ?? TopicProgress(topicId: topicId)
            SRS.update(&p, score: max(0, min(1, score)), weight: max(1, weight), source: source, now: now)
            d.progress[topicId] = p
        }
    }

    public func dueTopics(now: Date = Date(), subjectId: String? = nil) -> [Topic] {
        data.topics.filter { t in
            if let s = subjectId, t.subjectId != s { return false }
            guard let due = data.progress[t.id]?.due else { return false }
            return due <= now
        }.sorted { (data.progress[$0.id]?.due ?? .distantFuture) < (data.progress[$1.id]?.due ?? .distantFuture) }
    }

    public func weakTopics(subjectId: String? = nil) -> [Topic] {
        data.topics.filter { t in
            if let s = subjectId, t.subjectId != s { return false }
            return masteryLevel(topicId: t.id) == .struggling
        }
    }

    public func unresolvedMistakes(topicId: String? = nil, subjectId: String? = nil) -> [Mistake] {
        data.mistakes.filter { m in
            !m.resolved && (topicId == nil || m.topicId == topicId) && (subjectId == nil || m.subjectId == subjectId)
        }
    }

    public func errorPatterns(subjectId: String? = nil, now: Date = Date()) -> [ErrorPattern] {
        var buckets: [ErrorCategory: [Mistake]] = [:]
        for m in data.mistakes where subjectId == nil || m.subjectId == subjectId { buckets[m.category, default: []].append(m) }
        return buckets.map { cat, ms in
            let recent = ms.filter { now.timeIntervalSince($0.date) < 14 * 86400 }.count
            let titles = Array(Set(ms.compactMap { topic($0.topicId)?.title })).sorted()
            return ErrorPattern(category: cat, count: ms.count, recentCount: recent, topicTitles: Array(titles.prefix(5)))
        }.sorted { ($0.recentCount, $0.count) > ($1.recentCount, $1.count) }
    }

    public func upcomingAssessments(now: Date = Date(), days: Int = 60) -> [Assessment] {
        data.assessments.filter { a in
            guard let d = a.date, a.result == nil else { return false }
            return d >= Calendar.current.startOfDay(for: now) && d.timeIntervalSince(now) < Double(days) * 86400
        }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Fraction of an assessment's topics that have been studied, and how many are secure.
    public func preparation(for a: Assessment) -> (studied: Int, secure: Int, total: Int) {
        let ids = a.topicIds.filter { topic($0) != nil }
        let studied = ids.filter { masteryLevel(topicId: $0) != .unseen }.count
        let secure = ids.filter { masteryLevel(topicId: $0) == .secure }.count
        return (studied, secure, ids.count)
    }

    /// Evidence-based ranking of what to study next. Every reason is derived from stored data.
    public func recommendations(now: Date = Date()) -> [Recommendation] {
        var out: [Recommendation] = []
        let cal = Calendar.current
        let upcoming = upcomingAssessments(now: now, days: 30)
        for t in data.topics {
            var score = 0.0
            var reasons: [String] = []
            let level = masteryLevel(topicId: t.id, now: now)
            if let due = data.progress[t.id]?.due, due <= now {
                let overdue = max(0, cal.dateComponents([.day], from: due, to: now).day ?? 0)
                score += 3 + min(Double(overdue), 7) * 0.3
                reasons.append(overdue > 0 ? "Review was due \(overdue) day\(overdue == 1 ? "" : "s") ago" : "Review due today")
            }
            if level == .struggling, let acc = recentAccuracy(topicId: t.id) {
                score += 2.5
                reasons.append("Recent accuracy \(Int((acc.score * 100).rounded()))% over \(acc.count) question\(acc.count == 1 ? "" : "s")")
            }
            for a in upcoming where a.topicIds.contains(t.id) {
                let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: now), to: a.date ?? now).day ?? 0)
                let proximity = Double(max(0, 30 - days)) / 30
                if level == .unseen { score += 2 + proximity * 2; reasons.append("In “\(a.title)” (\(days == 0 ? "today" : "in \(days) day\(days == 1 ? "" : "s")")) and not studied yet") }
                else if level != .secure { score += 1 + proximity * 1.5; reasons.append("In “\(a.title)” in \(days) day\(days == 1 ? "" : "s"); not yet secure") }
            }
            let open = unresolvedMistakes(topicId: t.id).count
            if open > 0 { score += 0.4 * Double(min(open, 5)); reasons.append("\(open) unresolved mistake\(open == 1 ? "" : "s")") }
            if score > 0 {
                out.append(Recommendation(subjectId: t.subjectId, topicId: t.id, title: t.title, reasons: reasons, priority: score))
            }
        }
        return out.sorted { $0.priority > $1.priority }
    }

    public func studyMinutes(on day: Date) -> Int {
        let cal = Calendar.current
        return data.lessons.filter { cal.isDate($0.startedAt, inSameDayAs: day) }.reduce(0) { acc, l in
            let end = l.endedAt ?? l.messages.last?.date ?? l.startedAt
            return acc + max(0, Int(end.timeIntervalSince(l.startedAt) / 60))
        }
    }

    /// Daily accuracy for the last `days` days based on finalized attempts. Days with no questions are omitted.
    public func dailyAccuracy(days: Int = 14, now: Date = Date()) -> [(day: Date, accuracy: Double, questions: Int)] {
        let cal = Calendar.current
        var buckets: [Date: (Double, Int)] = [:]
        for a in data.attempts where a.finalized {
            guard let when = a.submittedAt, now.timeIntervalSince(when) < Double(days) * 86400 else { continue }
            let key = cal.startOfDay(for: when)
            let marked = a.marks.filter { !$0.pending }
            let got = marked.reduce(0.0) { $0 + $1.awarded }, mx = marked.reduce(0) { $0 + $1.max }
            guard mx > 0 else { continue }
            let old = buckets[key] ?? (0, 0)
            buckets[key] = (old.0 + got, old.1 + mx)
        }
        return buckets.map { ($0.key, $0.value.0 / Double($0.value.1), $0.value.1) }.sorted { $0.0 < $1.0 }
    }
}
