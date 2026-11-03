import Foundation

/// Converts a LaTeX-like string into readable Unicode (superscripts, subscripts, Greek, fractions).
/// This is a lightweight renderer, not a full TeX engine.
public enum MathText {
    static let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ"]
    static let sub: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "i": "ᵢ", "n": "ₙ"]
    static let symbols: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\Delta": "Δ", "\\theta": "θ", "\\lambda": "λ",
        "\\mu": "μ", "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ", "\\Sigma": "Σ", "\\omega": "ω", "\\Omega": "Ω", "\\phi": "φ",
        "\\times": "×", "\\cdot": "·", "\\div": "÷", "\\pm": "±", "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈",
        "\\rightarrow": "→", "\\to": "→", "\\leftarrow": "←", "\\rightleftharpoons": "⇌", "\\infty": "∞", "\\degree": "°",
        "\\sqrt": "√", "\\propto": "∝", "\\therefore": "∴", "->": "→", "<=>": "⇌"
    ]

    public static func render(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "$", with: "")
        // \frac{a}{b} -> (a)/(b)
        if let re = try? NSRegularExpression(pattern: "\\\\frac\\{([^{}]*)\\}\\{([^{}]*)\\}") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "($1)⁄($2)")
        }
        if let re = try? NSRegularExpression(pattern: "\\\\sqrt\\{([^{}]*)\\}") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "√($1)")
        }
        for (k, v) in symbols.sorted(by: { $0.key.count > $1.key.count }) { s = s.replacingOccurrences(of: k, with: v) }
        s = script(s, marker: "^", map: sup)
        s = script(s, marker: "_", map: sub)
        return s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    private static func script(_ s: String, marker: Character, map: [Character: Character]) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == marker, i + 1 < chars.count {
                var group = ""
                if chars[i + 1] == "{", let close = chars[(i + 1)...].firstIndex(of: "}") {
                    group = String(chars[(i + 2)..<close]); i = close + 1
                } else {
                    group = String(chars[i + 1]); i += 2
                }
                if group.allSatisfy({ map[$0] != nil }) { out += String(group.map { map[$0]! }) }
                else { out += String(marker == "^" ? "^" : "_") + "(" + group + ")" }
            } else { out.append(c); i += 1 }
        }
        return out
    }
}
