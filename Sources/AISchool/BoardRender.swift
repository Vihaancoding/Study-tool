import SwiftUI
import AppKit
import StudyCore

enum BoardPalette {
    static func color(_ s: String) -> Color {
        if s == "ink" { return Color.primary }
        guard s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) else { return Color.primary }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static let swatches: [(name: String, value: String)] = [
        ("Ink", "ink"), ("Blue", "#3E63DD"), ("Red", "#E5484D"), ("Green", "#30A46C"), ("Orange", "#F76B15"), ("Purple", "#8E4EC6"), ("Yellow", "#F5C518")
    ]
}

struct PolyShape: Shape {
    var kind: ShapeType
    func path(in r: CGRect) -> Path {
        switch kind {
        case .rect: return Path(roundedRect: r, cornerRadius: 8)
        case .ellipse: return Path(ellipseIn: r)
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
            return p
        case .triangle:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
            return p
        }
    }
}

/// Draws the objects of a board in board coordinates. Used for the live editor, read-only previews, and image export.
struct BoardSurface: View {
    let board: Board
    var selection: Set<String> = []
    var erasing: Set<String> = []
    var offsets: [String: CGSize] = [:]
    var animated = true

    var body: some View {
        let moving = board.objects.contains { $0.motion != nil && board.isVisible($0) }
        if animated && moving {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                objects(t: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            objects(t: 0)
        }
    }

    private func objects(t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(board.objects) { o in
                if board.isVisible(o) && !(o.hidden && o.kind != .text && o.kind != .equation) {
                    ObjectView(o: o, t: t, selected: selection.contains(o.id), faded: erasing.contains(o.id),
                               extra: offsets[o.id] ?? .zero, animate: board.animate)
                }
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }
}

struct ObjectView: View {
    let o: BoardObject
    let t: Double
    let selected: Bool
    let faded: Bool
    let extra: CGSize
    let animate: Bool

    private var pad: CGFloat { CGFloat(max(o.strokeWidth * 2, 8) + 6) }
    private var color: Color { BoardPalette.color(o.color) }

    private func rel(_ p: Point) -> CGPoint { CGPoint(x: p.x - o.x + Double(pad), y: p.y - o.y + Double(pad)) }

    private var motionOffset: CGSize {
        guard let m = o.motion else { return .zero }
        let seed = Double(abs(o.id.hashValue % 997)) / 31.0
        if m.type == "jiggle" {
            return CGSize(width: sin(t * m.speed * 1.3 + seed) * m.amplitude, height: cos(t * m.speed * 1.1 + seed * 1.7) * m.amplitude)
        }
        let s = sin(t * m.speed * 0.5 + seed)
        let wob = sin(t * m.speed * 0.37 + seed * 2.0) * 0.4
        return CGSize(width: (cos(m.angle) * s + sin(m.angle) * wob) * m.amplitude, height: (sin(m.angle) * s - cos(m.angle) * wob) * m.amplitude)
    }

    var body: some View {
        let m = motionOffset
        ZStack(alignment: .topLeading) {
            content
            if o.highlighted {
                RoundedRectangle(cornerRadius: 10).stroke(Theme.warn, lineWidth: 3)
                    .frame(width: CGFloat(o.w) + 16, height: CGFloat(o.h) + 16)
                    .shadow(color: Theme.warn.opacity(0.5), radius: 8)
                    .offset(x: pad - 8, y: pad - 8)
            }
            if selected {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: CGFloat(o.w) + 10, height: CGFloat(o.h) + 10)
                    .offset(x: pad - 5, y: pad - 5)
            }
        }
        .frame(width: CGFloat(o.w) + pad * 2, height: CGFloat(o.h) + pad * 2, alignment: .topLeading)
        .opacity(faded ? 0.25 : 1)
        .offset(x: CGFloat(o.x) - pad + extra.width + m.width, y: CGFloat(o.y) - pad + extra.height + m.height)
        .animation(animate ? .easeInOut(duration: 0.9) : nil, value: o.x)
        .animation(animate ? .easeInOut(duration: 0.9) : nil, value: o.y)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch o.kind {
        case .text, .equation: return o.hidden ? "Hidden label" : o.text
        case .blank: return "Answer box. \(o.guess)"
        case .shape: return o.text.isEmpty ? "Shape" : "Shape: \(o.text)"
        case .arrow: return o.text.isEmpty ? "Arrow" : "Arrow: \(o.text)"
        case .particle: return "Particle"
        case .stroke: return "Drawing"
        case .image: return "Image"
        }
    }

    @ViewBuilder private var content: some View {
        if o.hidden && (o.kind == .text || o.kind == .equation) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(Text(o.guess.isEmpty ? "?" : "").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary))
                .frame(width: max(CGFloat(o.w), 90), height: max(CGFloat(o.h), 40))
                .offset(x: pad, y: pad)
        } else {
            switch o.kind {
            case .stroke:
                Path { p in
                    guard let first = o.points.first else { return }
                    p.move(to: rel(first))
                    if o.points.count == 1 { p.addLine(to: CGPoint(x: rel(first).x + 0.1, y: rel(first).y)) }
                    for pt in o.points.dropFirst() { p.addLine(to: rel(pt)) }
                }
                .stroke(color.opacity(o.opacity), style: StrokeStyle(lineWidth: CGFloat(o.strokeWidth), lineCap: .round, lineJoin: .round))
            case .arrow:
                ArrowBody(o: o, pad: pad, color: color)
            case .text:
                Text(o.text)
                    .font(.system(size: CGFloat(o.fontSize), weight: o.bold ? .bold : .regular))
                    .foregroundStyle(color).fixedSize().offset(x: pad, y: pad)
            case .equation:
                Text(MathText.render(o.text))
                    .font(.system(size: CGFloat(o.fontSize), design: .serif))
                    .foregroundStyle(color).fixedSize().offset(x: pad, y: pad)
            case .shape:
                let kind = o.shape ?? .rect
                ZStack {
                    if let f = o.fill { PolyShape(kind: kind).fill(BoardPalette.color(f).opacity(o.opacity < 1 ? o.opacity : 0.18)) }
                    PolyShape(kind: kind).stroke(color, style: StrokeStyle(lineWidth: CGFloat(o.strokeWidth), dash: o.dashed ? [8, 5] : []))
                    if !o.text.isEmpty {
                        Text(o.text).font(.system(size: CGFloat(o.fontSize), weight: o.bold ? .bold : .regular))
                            .foregroundStyle(Color.primary).multilineTextAlignment(.center).padding(4)
                    }
                }
                .frame(width: CGFloat(o.w), height: CGFloat(o.h)).offset(x: pad, y: pad)
            case .particle:
                Circle().fill(color.opacity(0.9)).overlay(Circle().stroke(color, lineWidth: 1))
                    .frame(width: CGFloat(o.w), height: CGFloat(o.h)).offset(x: pad, y: pad)
            case .blank:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: CGFloat(o.w), height: CGFloat(o.h)).offset(x: pad, y: pad)
            case .image:
                if let d = o.imageData, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFit().frame(width: CGFloat(o.w), height: CGFloat(o.h)).offset(x: pad, y: pad)
                }
            }
        }
    }
}

struct ArrowBody: View {
    let o: BoardObject
    let pad: CGFloat
    let color: Color
    var body: some View {
        let p1 = CGPoint(x: (o.points.first?.x ?? 0) - o.x + Double(pad), y: (o.points.first?.y ?? 0) - o.y + Double(pad))
        let p2 = CGPoint(x: (o.points.last?.x ?? 0) - o.x + Double(pad), y: (o.points.last?.y ?? 0) - o.y + Double(pad))
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: p1); p.addLine(to: p2)
                if o.arrowHead {
                    let ang = atan2(p2.y - p1.y, p2.x - p1.x)
                    let len: CGFloat = 16 + CGFloat(o.strokeWidth)
                    for d in [0.45, -0.45] {
                        p.move(to: p2)
                        p.addLine(to: CGPoint(x: p2.x - len * cos(ang + d), y: p2.y - len * sin(ang + d)))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: CGFloat(o.strokeWidth), lineCap: .round, lineJoin: .round, dash: o.dashed ? [8, 5] : []))
            if !o.text.isEmpty {
                Text(o.text).font(.system(size: CGFloat(o.fontSize))).foregroundStyle(color)
                    .padding(.horizontal, 4).background(Theme.canvas.opacity(0.85))
                    .position(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 16)
            }
        }
    }
}

/// Renders a board to PNG so Claude can see freehand work, and for export.
@MainActor
enum BoardRenderer {
    static func png(for board: Board?, maxSide: CGFloat = 1400) -> Data? {
        guard let board = board else { return nil }
        let visible = board.objects.filter { board.isVisible($0) }
        var box = CGRect(x: 0, y: 0, width: 800, height: 500)
        if let first = visible.first {
            box = first.bounds
            for o in visible.dropFirst() { box = box.union(o.bounds) }
            box = box.insetBy(dx: -40, dy: -40)
        }
        box.size.width = max(box.width, 200); box.size.height = max(box.height, 150)
        let scale = min(1, maxSide / max(box.width, box.height))
        let content = BoardSurface(board: board, animated: false)
            .offset(x: -box.minX, y: -box.minY)
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
