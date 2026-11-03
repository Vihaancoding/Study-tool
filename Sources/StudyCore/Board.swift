import Foundation
import CoreGraphics

public enum BoardObjectKind: String, Codable {
    case stroke, text, shape, arrow, equation, image, particle, blank
}

public enum ShapeType: String, Codable, CaseIterable {
    case rect, ellipse, diamond, triangle
}

public struct Point: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Motion: Codable, Equatable {
    public var type: String      // "jiggle" | "drift"
    public var amplitude: Double
    public var speed: Double
    public var angle: Double     // radians; drift direction
    public init(type: String, amplitude: Double, speed: Double, angle: Double = 0) {
        self.type = type; self.amplitude = amplitude; self.speed = speed; self.angle = angle
    }
}

/// One editable object on a whiteboard. Invariant: x, y, w, h always describe the bounding box.
public struct BoardObject: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String?
    public var kind: BoardObjectKind
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var points: [Point] = []
    public var text: String = ""
    public var shape: ShapeType? = nil
    public var color: String = "ink"
    public var fill: String? = nil
    public var strokeWidth: Double = 3
    public var fontSize: Double = 28
    public var bold: Bool = false
    public var dashed: Bool = false
    public var opacity: Double = 1
    public var arrowHead: Bool = true
    public var step: Int = 0
    public var hidden: Bool = false          // recall mode: label hidden until revealed
    public var highlighted: Bool = false
    public var locked: Bool = false
    public var motion: Motion? = nil
    public var author: String = "claude"
    public var group: String? = nil
    public var expected: String? = nil       // blank/recall: the answer (used by Claude/marking)
    public var guess: String = ""            // student's attempt for blank/hidden label
    public var imageData: Data? = nil

    public init(id: String = newID("o"), name: String? = nil, kind: BoardObjectKind,
                x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var bounds: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var isPointBased: Bool { kind == .stroke || kind == .arrow }

    public mutating func refreshBounds() {
        guard !points.isEmpty else { return }
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        x = xs.min() ?? 0; y = ys.min() ?? 0
        w = (xs.max() ?? 0) - x; h = (ys.max() ?? 0) - y
    }

    public mutating func translate(dx: Double, dy: Double) {
        x += dx; y += dy
        if !points.isEmpty { points = points.map { Point(x: $0.x + dx, y: $0.y + dy) } }
    }

    public mutating func estimateTextSize() {
        let lines = text.components(separatedBy: "\n")
        let longest = lines.map { $0.count }.max() ?? 1
        w = max(24, Double(longest) * fontSize * 0.56)
        h = max(fontSize * 1.3, Double(lines.count) * fontSize * 1.3)
    }
}

public enum BoardColor {
    public static let named: [String: String] = [
        "ink": "ink", "black": "ink", "white": "ink",
        "red": "#E5484D", "blue": "#3E63DD", "green": "#30A46C", "orange": "#F76B15",
        "purple": "#8E4EC6", "yellow": "#F5C518", "teal": "#12A594", "pink": "#D6409F",
        "gray": "#8B8D98", "grey": "#8B8D98", "brown": "#A18072"
    ]
    public static func normalise(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = named[t] { return n }
        if t.count == 7, t.hasPrefix("#"), t.dropFirst().allSatisfy({ $0.isHexDigit }) { return t.uppercased() }
        throw ToolError("color '\(s)' is not valid. Use a name (\(named.keys.sorted().joined(separator: ", "))) or hex like #3E63DD")
    }
}

public struct Board: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var subjectId: String?
    public var lessonId: String?
    public var objects: [BoardObject]
    public var currentStep: Int
    public var background: String      // "grid" | "plain" | "lines"
    public var createdAt: Date
    public var updatedAt: Date
    /// Transient: set when Claude moves things so the UI animates the change. Not persisted.
    public var animate: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, subjectId, lessonId, objects, currentStep, background, createdAt, updatedAt
    }

    public init(id: String = newID("board"), title: String, subjectId: String? = nil, lessonId: String? = nil) {
        self.id = id; self.title = title; self.subjectId = subjectId; self.lessonId = lessonId
        self.objects = []; self.currentStep = 0; self.background = "grid"
        self.createdAt = Date(); self.updatedAt = Date()
    }

    public var maxStep: Int { objects.map { $0.step }.max() ?? 0 }

    public func isVisible(_ o: BoardObject) -> Bool { o.step <= currentStep }

    public func index(of ref: String) -> Int? {
        if let i = objects.firstIndex(where: { $0.id == ref }) { return i }
        return objects.firstIndex(where: { $0.name == ref })
    }

    func resolve(_ ref: String) throws -> Int {
        guard let i = index(of: ref) else {
            throw ToolError("no board object with id or name '\(ref)'. Use whiteboard_read to list objects.")
        }
        return i
    }
}

// MARK: - Structured actions (validated, atomic)

public enum BoardLimits {
    public static let maxObjects = 2500
    public static let coord: ClosedRange<Double> = -6000...6000
    public static let size: ClosedRange<Double> = 1...4000
}

extension Board {
    /// Applies a batch atomically: either every action is valid and applied, or nothing changes.
    public mutating func applyBatch(_ actions: [JSON]) throws -> [[String]] {
        var copy = self
        var created: [[String]] = []
        for (i, action) in actions.enumerated() {
            do {
                created.append(try copy.applyOne(action))
            } catch let e as ToolError {
                throw ToolError("action[\(i)] rejected (nothing was applied): \(e.message)")
            }
        }
        if copy.objects.count > BoardLimits.maxObjects { throw ToolError("board would exceed \(BoardLimits.maxObjects) objects") }
        copy.updatedAt = Date()
        self = copy
        return created
    }

    private func checkName(_ name: String?) throws {
        guard let n = name else { return }
        if objects.contains(where: { $0.name == n || $0.id == n }) { throw ToolError("name '\(n)' is already used on this board") }
    }

    private mutating func add(_ o: BoardObject) -> String { objects.append(o); return o.id }

    private func coordArg(_ a: Args, _ k: String) throws -> Double { try a.number(k, range: BoardLimits.coord) }
    private func sizeArg(_ a: Args, _ k: String) throws -> Double { try a.number(k, range: BoardLimits.size) }

    private func colorArg(_ a: Args, _ k: String = "color", def: String = "ink") throws -> String {
        if let s = try a.optString(k, maxLength: 20) { return try BoardColor.normalise(s) }
        return def
    }

    private func applyCommon(_ a: Args, to o: inout BoardObject) throws {
        if let n = try a.optString("name", maxLength: 60) { try checkName(n); o.name = n }
        if let s = try a.optInt("step", range: 0...200) { o.step = s }
        if let g = try a.optString("group", maxLength: 60) { o.group = g }
        if let d = try a.optBool("dashed") { o.dashed = d }
        if let sw = try a.optNumber("stroke_width", range: 1...24) { o.strokeWidth = sw }
    }

    private mutating func applyOne(_ action: JSON) throws -> [String] {
        guard action.object != nil else { throw ToolError("each action must be an object with a 'type'") }
        let a = Args(action, context: "action")
        let type = try a.string("type", maxLength: 40)
        switch type {
        case "add_text", "add_label":
            var o = BoardObject(kind: .text, x: try coordArg(a, "x"), y: try coordArg(a, "y"))
            o.text = try a.string("text", maxLength: 2000)
            o.fontSize = try a.optNumber("size", range: 8...200) ?? 28
            o.bold = try a.optBool("bold") ?? false
            o.color = try colorArg(a)
            try applyCommon(a, to: &o)
            o.estimateTextSize()
            return [add(o)]

        case "add_equation":
            var o = BoardObject(kind: .equation, x: try coordArg(a, "x"), y: try coordArg(a, "y"))
            o.text = try a.string("text", maxLength: 500)
            o.fontSize = try a.optNumber("size", range: 12...200) ?? 40
            o.color = try colorArg(a)
            try applyCommon(a, to: &o)
            o.estimateTextSize()
            o.w = max(o.w * 0.9, 40)
            return [add(o)]

        case "add_shape":
            let shape = try a.oneOf("shape", ShapeType.allCases.map { $0.rawValue })
            var o = BoardObject(kind: .shape, x: try coordArg(a, "x"), y: try coordArg(a, "y"),
                                w: try sizeArg(a, "w"), h: try sizeArg(a, "h"))
            o.shape = ShapeType(rawValue: shape)
            o.color = try colorArg(a)
            if let f = try a.optString("fill", maxLength: 20) { o.fill = try BoardColor.normalise(f) }
            o.text = try a.optString("text", maxLength: 500) ?? ""
            o.fontSize = try a.optNumber("size", range: 8...120) ?? 22
            try applyCommon(a, to: &o)
            return [add(o)]

        case "add_arrow", "add_line":
            let x1 = try coordArg(a, "x1"), y1 = try coordArg(a, "y1"), x2 = try coordArg(a, "x2"), y2 = try coordArg(a, "y2")
            if x1 == x2 && y1 == y2 { throw ToolError("arrow start and end must differ") }
            var o = BoardObject(kind: .arrow)
            o.points = [Point(x: x1, y: y1), Point(x: x2, y: y2)]
            o.refreshBounds()
            o.arrowHead = type == "add_arrow" ? (try a.optBool("head") ?? true) : false
            o.color = try colorArg(a)
            o.text = try a.optString("label", maxLength: 200) ?? ""
            o.fontSize = try a.optNumber("size", range: 8...80) ?? 22
            try applyCommon(a, to: &o)
            return [add(o)]

        case "add_blank":
            var o = BoardObject(kind: .blank, x: try coordArg(a, "x"), y: try coordArg(a, "y"),
                                w: try a.optNumber("w", range: 40...1200) ?? 200,
                                h: try a.optNumber("h", range: 24...400) ?? 56)
            o.expected = try a.optString("expected", maxLength: 500)
            o.text = ""
            o.guess = ""
            o.color = try colorArg(a, def: "blue")
            o.fontSize = try a.optNumber("size", range: 10...80) ?? 24
            // 'prompt' is shown as the placeholder inside the empty box.
            o.text = try a.optString("prompt", maxLength: 200) ?? ""
            try applyCommon(a, to: &o)
            return [add(o)]

        case "add_table":
            let rows = try a.array("rows", max: 40)
            var grid: [[String]] = []
            for (ri, r) in rows.enumerated() {
                guard let cells = r.array else { throw ToolError("rows[\(ri)] must be an array of strings") }
                grid.append(cells.map { $0.string ?? ($0.double.map { String($0) } ?? "") })
            }
            guard !grid.isEmpty, let cols = grid.map({ $0.count }).max(), cols > 0, cols <= 12 else {
                throw ToolError("table needs 1-40 rows and 1-12 columns")
            }
            let x0 = try coordArg(a, "x"), y0 = try coordArg(a, "y")
            let cw = try a.optNumber("cell_w", range: 40...500) ?? 160
            let ch = try a.optNumber("cell_h", range: 24...200) ?? 52
            let header = try a.optBool("header") ?? true
            let step = try a.optInt("step", range: 0...200) ?? 0
            let group = try a.optString("group", maxLength: 60) ?? "table"
            var ids: [String] = []
            for (ri, row) in grid.enumerated() {
                for ci in 0..<cols {
                    var o = BoardObject(kind: .shape, x: x0 + Double(ci) * cw, y: y0 + Double(ri) * ch, w: cw, h: ch)
                    o.shape = .rect
                    o.text = ci < row.count ? row[ci] : ""
                    o.fontSize = 20
                    o.bold = header && ri == 0
                    if header && ri == 0 { o.fill = "#8B8D98" }
                    o.step = step; o.group = group
                    ids.append(add(o))
                }
            }
            return ids

        case "add_particles":
            return try addParticles(a)

        case "add_timeline":
            return try addTimeline(a)

        case "highlight":
            let color = try colorArg(a, def: "#F5C518")
            if let region = try a.optObject("region") {
                var o = BoardObject(kind: .shape, x: try coordArg(region, "x"), y: try coordArg(region, "y"),
                                    w: try sizeArg(region, "w"), h: try sizeArg(region, "h"))
                o.shape = .rect; o.color = color; o.fill = color; o.opacity = 0.28; o.group = "highlight"
                o.strokeWidth = 2
                if let s = try a.optInt("step", range: 0...200) { o.step = s }
                return [add(o)]
            }
            let refs = try targetRefs(a)
            for r in refs { let i = try resolve(r); objects[i].highlighted = true }
            return refs

        case "unhighlight":
            if try a.optBool("all") == true {
                objects.removeAll { $0.group == "highlight" }
                for i in objects.indices { objects[i].highlighted = false }
                return []
            }
            let refs = try targetRefs(a)
            for r in refs { let i = try resolve(r); objects[i].highlighted = false; if objects[i].group == "highlight" { objects[i].hidden = true } }
            return refs

        case "update":
            let i = try resolve(try a.string("ref", maxLength: 60))
            var o = objects[i]
            if let t = try a.optString("text", maxLength: 2000) { o.text = t }
            if let c = try a.optString("color", maxLength: 20) { o.color = try BoardColor.normalise(c) }
            if let f = try a.optString("fill", maxLength: 20) { o.fill = f == "none" ? nil : try BoardColor.normalise(f) }
            if let s = try a.optNumber("size", range: 8...200) { o.fontSize = s }
            if let s = try a.optInt("step", range: 0...200) { o.step = s }
            if let h = try a.optBool("hidden") { o.hidden = h }
            if let l = try a.optBool("locked") { o.locked = l }
            if let b = try a.optBool("bold") { o.bold = b }
            if let n = try a.optString("new_name", maxLength: 60) { try checkName(n); o.name = n }
            if o.isPointBased {
                if a.has("w") || a.has("h") { throw ToolError("arrows/strokes cannot be resized; delete and re-add") }
            } else {
                if let w = try a.optNumber("w", range: BoardLimits.size) { o.w = w }
                if let h = try a.optNumber("h", range: BoardLimits.size) { o.h = h }
            }
            if o.kind == .text || o.kind == .equation, a.has("text") || a.has("size") { o.estimateTextSize() }
            objects[i] = o
            if a.has("x") || a.has("y") {
                let nx = try a.optNumber("x", range: BoardLimits.coord) ?? objects[i].x
                let ny = try a.optNumber("y", range: BoardLimits.coord) ?? objects[i].y
                objects[i].translate(dx: nx - objects[i].x, dy: ny - objects[i].y)
                animate = true
            }
            return [o.id]

        case "move":
            let i = try resolve(try a.string("ref", maxLength: 60))
            let nx = try coordArg(a, "x"), ny = try coordArg(a, "y")
            objects[i].translate(dx: nx - objects[i].x, dy: ny - objects[i].y)
            animate = true
            return [objects[i].id]

        case "set_motion":
            let i = try resolve(try a.string("ref", maxLength: 60))
            let t = try a.oneOf("motion", ["none", "jiggle", "drift"])
            if t == "none" { objects[i].motion = nil }
            else {
                let amp = try a.optNumber("amplitude", range: 0...200) ?? (t == "jiggle" ? 2 : 12)
                let spd = try a.optNumber("speed", range: 0.1...20) ?? (t == "jiggle" ? 6 : 1.5)
                let ang = try a.optNumber("angle", range: -7...7) ?? 0
                objects[i].motion = Motion(type: t, amplitude: amp, speed: spd, angle: ang)
            }
            return [objects[i].id]

        case "delete":
            let refs = try targetRefs(a)
            var idx = Set<Int>()
            for r in refs { idx.insert(try resolve(r)) }
            objects = objects.enumerated().filter { !idx.contains($0.offset) }.map { $0.element }
            return refs

        case "clear":
            objects.removeAll(); currentStep = 0
            return []

        case "set_step":
            currentStep = try a.int("step", range: 0...200)
            return []

        case "reveal_next":
            let next = objects.map { $0.step }.filter { $0 > currentStep }.min()
            if let n = next { currentStep = n }
            return []

        case "reveal_all":
            currentStep = maxStep
            return []

        case "hide_labels":
            // Recall mode: hide text/equation labels so the student must reconstruct them.
            let targets = try recallTargets(a)
            for i in targets {
                if objects[i].expected == nil { objects[i].expected = objects[i].text }
                objects[i].hidden = true
            }
            return targets.map { objects[$0].id }

        case "show_labels":
            let targets = try recallTargets(a)
            for i in targets { objects[i].hidden = false }
            return targets.map { objects[$0].id }

        case "set_background":
            background = try a.oneOf("background", ["grid", "plain", "lines"])
            return []

        case "set_title":
            title = try a.string("title", maxLength: 120)
            return []

        default:
            throw ToolError("unknown action type '\(type)'. Valid: add_text, add_equation, add_shape, add_arrow, add_line, add_blank, add_table, add_particles, add_timeline, highlight, unhighlight, update, move, set_motion, delete, clear, set_step, reveal_next, reveal_all, hide_labels, show_labels, set_background, set_title")
        }
    }

    private func targetRefs(_ a: Args) throws -> [String] {
        if let refs = try a.stringArray("refs", max: 200), !refs.isEmpty { return refs }
        if let r = try a.optString("ref", maxLength: 60) { return [r] }
        throw ToolError("provide 'ref' (id or name) or 'refs'")
    }

    private func recallTargets(_ a: Args) throws -> [Int] {
        var out: [Int] = []
        if let refs = try a.stringArray("refs", max: 200), !refs.isEmpty {
            for r in refs { out.append(try resolve(r)) }
        } else if let g = try a.optString("group", maxLength: 60) {
            out = objects.indices.filter { objects[$0].group == g && ($0 >= 0) }
        } else if try a.optBool("all_text") == true {
            out = objects.indices.filter { objects[$0].kind == .text || objects[$0].kind == .equation }
        } else {
            throw ToolError("provide 'refs', 'group' or 'all_text': true")
        }
        for i in out where objects[i].kind != .text && objects[i].kind != .equation {
            throw ToolError("only text and equation objects can be hidden for recall (\(objects[i].id) is \(objects[i].kind.rawValue))")
        }
        return out
    }

    // MARK: Composite builders

    private struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
    }

    private mutating func addParticles(_ a: Args) throws -> [String] {
        let x = try coordArg(a, "x"), y = try coordArg(a, "y")
        let w = try a.number("w", range: 60...3000), h = try a.number("h", range: 60...3000)
        let count = try a.int("count", range: 1...250)
        let state = try a.oneOf("state", ["solid", "liquid", "gas"])
        let r = try a.optNumber("radius", range: 3...40) ?? 9
        let color = try colorArg(a, def: "#3E63DD")
        let step = try a.optInt("step", range: 0...200) ?? 0
        let prefix = try a.optString("name_prefix", maxLength: 40)
        let group = try a.optString("group", maxLength: 60) ?? "particles"
        let drawContainer = try a.optBool("draw_container") ?? true
        var ids: [String] = []

        if drawContainer {
            var c = BoardObject(kind: .shape, x: x, y: y, w: w, h: h)
            c.shape = .rect; c.strokeWidth = 4; c.step = step; c.group = group
            if let p = prefix { try checkName(p + "_container"); c.name = p + "_container" }
            ids.append(add(c))
        }

        var rng = LCG(s: UInt64(count * 7919) &+ UInt64(abs(Int(x + y))) &+ 17)
        var pts: [(Double, Double)] = []
        switch state {
        case "solid":
            let cols = max(1, Int(ceil(sqrt(Double(count) * w / h))))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let sp = min(2.4 * r, (w - 2 * r) / Double(cols), (h - 2 * r) / Double(rows))
            if sp < r * 1.2 { throw ToolError("container too small for \(count) particles of radius \(r)") }
            let gw = sp * Double(cols - 1), gh = sp * Double(rows - 1)
            let ox = x + (w - gw) / 2, oy = y + (h - gh) / 2
            for k in 0..<count { pts.append((ox + Double(k % cols) * sp, oy + Double(k / cols) * sp)) }
        case "liquid":
            let sp = 2.3 * r
            let cols = max(1, Int((w - 2 * r) / sp))
            let rows = Int(ceil(Double(count) / Double(cols)))
            if Double(rows) * sp + r > h { throw ToolError("container too small for \(count) liquid particles of radius \(r)") }
            for k in 0..<count {
                let col = k % cols, row = k / cols
                let px = x + r + (w - 2 * r - sp * Double(cols - 1)) / 2 + Double(col) * sp + (rng.next() - 0.5) * r * 0.6
                let py = y + h - r - Double(row) * sp + (rng.next() - 0.5) * r * 0.6
                pts.append((px, py))
            }
        default:
            for _ in 0..<count { pts.append((x + r + rng.next() * (w - 2 * r), y + r + rng.next() * (h - 2 * r))) }
        }
        for (k, p) in pts.enumerated() {
            var o = BoardObject(kind: .particle, x: p.0 - r, y: p.1 - r, w: 2 * r, h: 2 * r)
            o.color = color; o.fill = color; o.step = step; o.group = group; o.strokeWidth = 1
            switch state {
            case "solid": o.motion = Motion(type: "jiggle", amplitude: 1.6, speed: 7, angle: 0)
            case "liquid": o.motion = Motion(type: "drift", amplitude: 7, speed: 2, angle: rng.next() * 6.28)
            default: o.motion = Motion(type: "drift", amplitude: min(w, h) * 0.12, speed: 1.1 + rng.next(), angle: rng.next() * 6.28)
            }
            if let p = prefix { o.name = "\(p)_\(k + 1)"; try checkName(o.name) }
            ids.append(add(o))
        }
        return ids
    }

    private mutating func addTimeline(_ a: Args) throws -> [String] {
        let events = try a.elements("events", max: 20)
        if events.count < 2 { throw ToolError("a timeline needs at least 2 events") }
        let x = try coordArg(a, "x"), y = try coordArg(a, "y")
        let w = try a.optNumber("w", range: 300...3000) ?? 1100
        let prefix = try a.optString("name_prefix", maxLength: 40) ?? "event"
        let sequential = try a.optBool("reveal_sequentially") ?? false
        let color = try colorArg(a)
        var ids: [String] = []
        var line = BoardObject(kind: .arrow)
        line.points = [Point(x: x, y: y), Point(x: x + w, y: y)]
        line.refreshBounds(); line.color = color; line.group = "timeline"; line.strokeWidth = 4
        ids.append(add(line))
        let n = events.count
        for (k, ev) in events.enumerated() {
            let ex = x + 40 + (w - 80) * Double(k) / Double(n - 1)
            let step = sequential ? k + 1 : 0
            var tick = BoardObject(kind: .arrow)
            tick.points = [Point(x: ex, y: y - 14), Point(x: ex, y: y + 14)]
            tick.refreshBounds(); tick.arrowHead = false; tick.color = color; tick.step = step; tick.group = "timeline"
            ids.append(add(tick))
            var label = BoardObject(kind: .text, x: ex, y: k % 2 == 0 ? y - 80 : y + 30)
            let l = try ev.string("label", maxLength: 120)
            let d = try ev.optString("detail", maxLength: 200)
            label.text = d == nil ? l : l + "\n" + d!
            label.fontSize = 20; label.step = step; label.group = "timeline"
            label.name = "\(prefix)\(k + 1)"
            try checkName(label.name)
            label.estimateTextSize()
            label.x = ex - label.w / 2
            ids.append(add(label))
        }
        return ids
    }

    /// A compact description of the board for Claude (no image data).
    public func summary(limit: Int = 300) -> JSON {
        var items: [JSON] = []
        for o in objects.prefix(limit) {
            var d: [String: JSON] = [
                "id": .s(o.id), "kind": .s(o.kind.rawValue),
                "x": .n((o.x).rounded()), "y": .n((o.y).rounded()),
                "w": .n(o.w.rounded()), "h": .n(o.h.rounded()),
                "author": .s(o.author), "step": .i(o.step)
            ]
            if let n = o.name { d["name"] = .s(n) }
            if !o.text.isEmpty { d["text"] = .s(o.text) }
            if let g = o.group { d["group"] = .s(g) }
            if o.hidden { d["hidden"] = true }
            if o.highlighted { d["highlighted"] = true }
            if let e = o.expected { d["expected"] = .s(e) }
            if !o.guess.isEmpty { d["student_guess"] = .s(o.guess) }
            if o.kind == .blank { d["student_answer"] = .s(o.guess) }
            if o.kind == .stroke { d["note"] = "freehand ink (see board image)" }
            items.append(.object(d))
        }
        return [
            "board_id": .s(id), "title": .s(title), "current_step": .i(currentStep), "max_step": .i(maxStep),
            "object_count": .i(objects.count), "objects": .array(items),
            "canvas_note": "Coordinates are board units; origin top-left; x right, y down. A typical visible area is about 1400x850."
        ]
    }
}
