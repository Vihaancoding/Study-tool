import Foundation

/// Deterministic marking for objective question types. Anything needing judgement is left `pending` for Claude.
public enum Marker {

    public static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("−", "-"), ("–", "-"), ("×", "*"), ("·", "*"), ("÷", "/"), ("²", "^2"), ("³", "^3")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-*/^=().%"))
        return String(t.unicodeScalars.filter { allowed.contains($0) })
    }

    public static func looseEqual(_ a: String, _ b: String) -> Bool {
        let x = normalise(a), y = normalise(b)
        if x.isEmpty || y.isEmpty { return false }
        if x == y { return true }
        if let nx = parseNumber(a)?.value, let ny = parseNumber(b)?.value, abs(nx - ny) <= 1e-9 * max(1, abs(ny)) { return true }
        return false
    }

    // MARK: Numbers

    /// Parses "3.2", "-4e3", "5.0 × 10^3", "5x10^-2", "1,200", ignoring a trailing unit.
    public static func parseNumber(_ raw: String) -> (value: Double, text: String, rest: String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: ",", with: "")
        let sciPattern = "^([-+]?[0-9]*\\.?[0-9]+)\\s*(?:x|\\*)\\s*10\\s*\\^?\\s*\\(?([-+]?[0-9]+)\\)?"
        if let re = try? NSRegularExpression(pattern: sciPattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
           let mant = Double(s[r1]), let ex = Double(s[r2]), let whole = Range(m.range, in: s) {
            return (mant * pow(10, ex), String(s[r1]) + "e" + String(s[r2]), String(s[whole.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        let pattern = "^[-+]?[0-9]*\\.?[0-9]+(?:[eE][-+]?[0-9]+)?"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s), let v = Double(s[r]) else { return nil }
        return (v, String(s[r]), String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Number of significant figures in the way the student wrote the number.
    public static func sigFigs(of text: String) -> Int? {
        guard let p = parseNumber(text) else { return nil }
        var mant = p.text.lowercased()
        if let e = mant.firstIndex(of: "e") { mant = String(mant[..<e]) }
        mant = mant.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "+", with: "")
        let hasPoint = mant.contains(".")
        var digits = mant.replacingOccurrences(of: ".", with: "")
        while digits.hasPrefix("0") { digits.removeFirst() }
        if digits.isEmpty { return 1 }
        if !hasPoint { while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() } }
        return digits.count
    }

    static func unitMatches(_ given: String, _ spec: CalcSpec) -> Bool {
        let g = normalise(given)
        guard !g.isEmpty else { return false }
        let accepted = ([spec.unit].compactMap { $0 }) + spec.unitAlternatives
        return accepted.contains { normalise($0) == g }
    }

    // MARK: Marking

    public static func mark(question q: Question, answer a: Answer?) -> QuestionMark {
        let ans = a ?? Answer(questionId: q.id)
        var m = QuestionMark(questionId: q.id, awarded: 0, max: q.marks, criterion: q.criterion)
        let hasInput = !ans.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ans.selected.isEmpty ||
            ans.blanks.contains { !$0.isEmpty } || ans.labels.values.contains { !$0.isEmpty }
        if !hasInput {
            m.feedback = "No answer given."
            m.betterAnswer = q.modelAnswer
            m.errorCategories = [.recall]
            return m
        }
        switch q.type {
        case .single, .trueFalse:
            let ok = Set(ans.selected) == Set(q.correct) && ans.selected.count == 1
            m.awarded = ok ? Double(q.marks) : 0
            m.feedback = ok ? "Correct." : "Not quite."
            if !ok { m.betterAnswer = correctOptionsText(q); m.errorCategories = [.conceptual] }

        case .multi:
            let right = Set(q.correct), chosen = Set(ans.selected)
            let good = Double(chosen.intersection(right).count), bad = Double(chosen.subtracting(right).count)
            let frac = right.isEmpty ? 0 : max(0, good - bad) / Double(right.count)
            m.awarded = roundHalf(Double(q.marks) * frac)
            if chosen == right { m.feedback = "Correct." }
            else {
                m.feedback = "You chose \(chosen.count) option(s); \(Int(good)) correct and \(Int(bad)) incorrect. Partial credit applied."
                m.betterAnswer = correctOptionsText(q); m.errorCategories = [.conceptual]
            }

        case .short:
            let t = ans.text
            if q.acceptable.contains(where: { looseEqual($0, t) || normalise(t).contains(normalise($0)) && !normalise($0).isEmpty }) {
                m.awarded = Double(q.marks); m.feedback = "Matches an accepted answer."
            } else if !q.keywords.isEmpty {
                let nt = normalise(t)
                let hit = q.keywords.filter { nt.contains(normalise($0)) }
                let frac = Double(hit.count) / Double(q.keywords.count)
                m.awarded = roundHalf(Double(q.marks) * frac)
                if hit.count == q.keywords.count { m.feedback = "Includes all expected key terms." }
                else {
                    let missing = q.keywords.filter { !hit.contains($0) }
                    m.feedback = "Missing key idea(s): \(missing.joined(separator: ", "))."
                    m.pending = true     // Claude should judge synonyms / correct wording before it is final
                    m.errorCategories = [.incompleteExplanation]
                }
                m.betterAnswer = q.modelAnswer
            } else {
                m.pending = true; m.betterAnswer = q.modelAnswer
                m.feedback = "Waiting for Claude to mark this answer."
            }

        case .extended:
            m.pending = true; m.betterAnswer = q.modelAnswer
            m.feedback = "Waiting for Claude to mark this against the rubric."

        case .calculation:
            m = markCalculation(q, ans, m)

        case .equationCompletion:
            let expected = q.blanks
            guard !expected.isEmpty else { m.pending = true; return m }
            var right = 0
            var wrong: [String] = []
            for (i, e) in expected.enumerated() {
                let g = i < ans.blanks.count ? ans.blanks[i] : ""
                if looseEqual(g, e) { right += 1 } else { wrong.append("blank \(i + 1)") }
            }
            m.awarded = roundHalf(Double(q.marks) * Double(right) / Double(expected.count))
            m.feedback = wrong.isEmpty ? "All blanks correct." : "Incorrect: \(wrong.joined(separator: ", "))."
            if !wrong.isEmpty { m.betterAnswer = expected.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "  "); m.errorCategories = [.calculation] }

        case .diagramLabel:
            guard !q.labels.isEmpty else { m.pending = true; return m }
            var right = 0
            var wrong: [String] = []
            for (i, t) in q.labels.enumerated() {
                let g = ans.labels[t.id] ?? ""
                if looseEqual(g, t.answer) || t.acceptable.contains(where: { looseEqual(g, $0) }) { right += 1 } else { wrong.append("label \(i + 1)") }
            }
            m.awarded = roundHalf(Double(q.marks) * Double(right) / Double(q.labels.count))
            m.feedback = wrong.isEmpty ? "All labels correct." : "Incorrect: \(wrong.joined(separator: ", "))."
            if !wrong.isEmpty { m.betterAnswer = q.labels.enumerated().map { "\($0.offset + 1): \($0.element.answer)" }.joined(separator: ", "); m.errorCategories = [.terminology] }
        }
        return m
    }

    static func markCalculation(_ q: Question, _ ans: Answer, _ base: QuestionMark) -> QuestionMark {
        var m = base
        guard let spec = q.calc else { m.pending = true; m.feedback = "Waiting for Claude to mark this calculation."; return m }
        let total = q.marks
        let unitMark = (spec.unit != nil && total >= 2) ? 1 : 0
        let sfMark = (spec.sigFigs != nil && total - unitMark >= 2) ? 1 : 0
        let valueMarks = total - unitMark - sfMark
        var awarded = 0.0
        var notes: [String] = []
        var cats: [ErrorCategory] = []

        // The unit may be typed in the unit box or after the number.
        let parsed = parseNumber(ans.text)
        let unitGiven = ans.unit.isEmpty ? (parsed?.rest ?? "") : ans.unit
        var valueOK = false
        if let p = parsed {
            let tol = abs(spec.answer) * spec.tolerancePercent / 100
            valueOK = abs(p.value - spec.answer) <= max(tol, spec.answer == 0 ? 1e-9 : 1e-12)
        }
        if valueOK { awarded += Double(valueMarks); notes.append("Value correct.") }
        else { notes.append(parsed == nil ? "I could not read a number in your answer." : "The numerical value is not within tolerance."); cats.append(.calculation) }

        if unitMark == 1 {
            if unitMatches(unitGiven, spec) { awarded += 1; notes.append("Unit correct.") }
            else {
                let expectedUnit = spec.unit ?? ""
                notes.append(unitGiven.isEmpty ? "Unit missing." : "Unit incorrect (expected \(expectedUnit)).")
                cats.append(.missingUnits)
            }
        }
        if sfMark == 1, let want = spec.sigFigs {
            if valueOK, let got = sigFigs(of: ans.text), got == want { awarded += 1; notes.append("Significant figures correct.") }
            else if valueOK { notes.append("Give the answer to \(want) significant figures."); cats.append(.sigFigs) }
        }
        m.awarded = awarded
        m.feedback = notes.joined(separator: " ")
        m.errorCategories = cats
        m.betterAnswer = q.modelAnswer.isEmpty ? "\(trimNumber(spec.answer)) \(spec.unit ?? "")".trimmingCharacters(in: .whitespaces) : q.modelAnswer
        let hasWorking = !ans.working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if awarded < Double(total) && hasWorking || spec.requireWorking {
            m.pending = true   // Claude reviews the working for method marks
            m.feedback += " Claude will review your working for method marks."
        }
        return m
    }

    static func correctOptionsText(_ q: Question) -> String {
        q.correct.compactMap { $0 >= 0 && $0 < q.options.count ? q.options[$0] : nil }.joined(separator: "; ")
    }

    static func trimNumber(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d)
    }

    static func roundHalf(_ d: Double) -> Double { (d * 2).rounded() / 2 }
}
