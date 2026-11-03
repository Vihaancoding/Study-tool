import Foundation

/// A small dynamic JSON value used for tool inputs/outputs and API messages.
public enum JSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Constructors
    public static func s(_ v: String) -> JSON { .string(v) }
    public static func i(_ v: Int) -> JSON { .number(Double(v)) }
    public static func n(_ v: Double) -> JSON { .number(v) }
    public static func b(_ v: Bool) -> JSON { .bool(v) }
    public static func strings(_ v: [String]) -> JSON { .array(v.map { JSON.string($0) }) }
    public static func opt(_ v: String?) -> JSON { v.map { JSON.string($0) } ?? .null }

    // MARK: Accessors
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let d) = self { return d }; return nil }
    public var int: Int? {
        if case .number(let d) = self, d == d.rounded(), abs(d) < 1e12 { return Int(d) }
        return nil
    }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public subscript(key: String) -> JSON? { object?[key] }

    // MARK: Serialisation
    public func serialized(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    public static func parse(_ text: String) -> JSON? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: d)
    }

    public static func from<T: Encodable>(_ value: T) -> JSON {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(value), let j = try? JSONDecoder().decode(JSON.self, from: d) else { return .null }
        return j
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var d: [String: JSON] = [:]
        for (k, v) in elements { d[k] = v }
        self = .object(d)
    }
}

// MARK: - Validation helpers

public struct ToolError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Typed accessor with clear error messages for validating model-supplied input.
public struct Args {
    public let json: JSON
    public let context: String

    public init(_ json: JSON, context: String = "input") {
        self.json = json
        self.context = context
    }

    private func fail(_ msg: String) -> ToolError { ToolError("\(context): \(msg)") }
    private func raw(_ key: String) -> JSON? {
        guard let v = json[key], !v.isNull else { return nil }
        return v
    }

    public func has(_ key: String) -> Bool { raw(key) != nil }

    public func string(_ key: String, maxLength: Int = 20000) throws -> String {
        guard let v = raw(key) else { throw fail("missing required field '\(key)'") }
        guard let s = v.string else { throw fail("'\(key)' must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw fail("'\(key)' must not be empty") }
        if s.count > maxLength { throw fail("'\(key)' is too long (max \(maxLength) characters)") }
        return s
    }

    public func optString(_ key: String, maxLength: Int = 20000) throws -> String? {
        guard let v = raw(key) else { return nil }
        guard let s = v.string else { throw fail("'\(key)' must be a string") }
        if s.count > maxLength { throw fail("'\(key)' is too long (max \(maxLength) characters)") }
        return s
    }

    public func number(_ key: String, range: ClosedRange<Double>? = nil) throws -> Double {
        guard let v = raw(key) else { throw fail("missing required field '\(key)'") }
        guard let d = v.double, d.isFinite else { throw fail("'\(key)' must be a number") }
        if let r = range, !r.contains(d) { throw fail("'\(key)' must be between \(r.lowerBound) and \(r.upperBound)") }
        return d
    }

    public func optNumber(_ key: String, range: ClosedRange<Double>? = nil) throws -> Double? {
        guard raw(key) != nil else { return nil }
        return try number(key, range: range)
    }

    public func int(_ key: String, range: ClosedRange<Int>? = nil) throws -> Int {
        guard let v = raw(key) else { throw fail("missing required field '\(key)'") }
        guard let i = v.int else { throw fail("'\(key)' must be a whole number") }
        if let r = range, !r.contains(i) { throw fail("'\(key)' must be between \(r.lowerBound) and \(r.upperBound)") }
        return i
    }

    public func optInt(_ key: String, range: ClosedRange<Int>? = nil) throws -> Int? {
        guard raw(key) != nil else { return nil }
        return try int(key, range: range)
    }

    public func optBool(_ key: String) throws -> Bool? {
        guard let v = raw(key) else { return nil }
        guard let b = v.bool else { throw fail("'\(key)' must be true or false") }
        return b
    }

    public func array(_ key: String, max: Int = 500) throws -> [JSON] {
        guard let v = raw(key) else { throw fail("missing required field '\(key)'") }
        guard let a = v.array else { throw fail("'\(key)' must be an array") }
        if a.count > max { throw fail("'\(key)' has too many items (max \(max))") }
        return a
    }

    public func optArray(_ key: String, max: Int = 500) throws -> [JSON]? {
        guard raw(key) != nil else { return nil }
        return try array(key, max: max)
    }

    public func stringArray(_ key: String, max: Int = 200) throws -> [String]? {
        guard let a = try optArray(key, max: max) else { return nil }
        var out: [String] = []
        for (i, e) in a.enumerated() {
            guard let s = e.string else { throw fail("'\(key)[\(i)]' must be a string") }
            out.append(s)
        }
        return out
    }

    public func intArray(_ key: String) throws -> [Int]? {
        guard let a = try optArray(key, max: 50) else { return nil }
        var out: [Int] = []
        for (i, e) in a.enumerated() {
            guard let n = e.int else { throw fail("'\(key)[\(i)]' must be a whole number") }
            out.append(n)
        }
        return out
    }

    public func object(_ key: String) throws -> Args {
        guard let v = raw(key) else { throw fail("missing required field '\(key)'") }
        guard v.object != nil else { throw fail("'\(key)' must be an object") }
        return Args(v, context: "\(context).\(key)")
    }

    public func optObject(_ key: String) throws -> Args? {
        guard raw(key) != nil else { return nil }
        return try object(key)
    }

    /// Case-insensitive enum check; returns the matching allowed value exactly as spelled in `allowed`.
    public func oneOf(_ key: String, _ allowed: [String]) throws -> String {
        let s = try string(key, maxLength: 100).trimmingCharacters(in: .whitespaces)
        guard let match = allowed.first(where: { $0.lowercased() == s.lowercased() }) else {
            throw fail("'\(key)' must be one of: \(allowed.joined(separator: ", "))")
        }
        return match
    }

    public func optOneOf(_ key: String, _ allowed: [String]) throws -> String? {
        guard raw(key) != nil else { return nil }
        return try oneOf(key, allowed)
    }

    public func elements(_ key: String, max: Int = 500) throws -> [Args] {
        let a = try array(key, max: max)
        var out: [Args] = []
        for (i, e) in a.enumerated() {
            guard e.object != nil else { throw fail("'\(key)[\(i)]' must be an object") }
            out.append(Args(e, context: "\(context).\(key)[\(i)]"))
        }
        return out
    }
}

public enum DateCodec {
    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Accepts "2026-11-20" or a full ISO-8601 timestamp.
    public static func parse(_ s: String) -> Date? {
        if let d = isoFull.date(from: s) { return d }
        if let d = isoDay.date(from: s) {
            // Treat a bare date as 09:00 local so reminders land at a sensible time.
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
        }
        return nil
    }

    public static func day(_ d: Date) -> String { isoDay.string(from: d) }
    public static func full(_ d: Date) -> String { isoFull.string(from: d) }
}
