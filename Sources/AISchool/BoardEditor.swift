import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudyCore

enum BoardTool: String, CaseIterable, Identifiable {
    case select, hand, pen, highlighter, eraser, text, equation, rect, ellipse, arrow, line
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .text: return "textformat"
        case .equation: return "x.squareroot"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.right"
        case .line: return "line.diagonal"
        }
    }
    var label: String { rawValue.capitalized }
}

/// Installs a local event monitor so trackpad scroll pans and pinch / ⌘-scroll zooms the board while the pointer is over it.
struct ScrollZoomMonitor: NSViewRepresentable {
    var onScroll: (CGSize, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.owner = self
        return v
    }
    func updateNSView(_ v: MonitorView, context: Context) { v.owner = self }

    final class MonitorView: NSView {
        var owner: ScrollZoomMonitor?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self = self, let win = self.window, event.window === win else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let loc = CGPoint(x: p.x, y: self.bounds.height - p.y)
                if event.type == .magnify {
                    self.owner?.onMagnify(event.magnification, loc)
                } else if event.modifierFlags.contains(.command) {
                    self.owner?.onMagnify(event.scrollingDeltaY * 0.01, loc)
                } else {
                    self.owner?.onScroll(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), loc)
                }
                return nil
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

struct BoardEditor: View {
    @EnvironmentObject var app: AppState
    let boardId: String
    var compact = false

    @State private var tool: BoardTool = .select
    @State private var color = "ink"
    @State private var width: Double = 3
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = CGSize(width: 24, height: 24)
    @State private var selection: Set<String> = []
    @State private var stroke: [Point] = []
    @State private var shapeStart: Point?
    @State private var shapeEnd: Point?
    @State private var dragOffset: CGSize = .zero
    @State private var movingIds: Set<String> = []
    @State private var erasing: Set<String> = []
    @State private var gestureActive = false
    @State private var panStart: CGSize?
    @State private var showInspector = true

    private var store: StudyStore { app.store }
    private var board: Board? { store.board(boardId) }

    var body: some View {
        if let board = board {
            VStack(spacing: 0) {
                toolbar(board)
                Divider()
                HStack(spacing: 0) {
                    canvas(board)
                    if showInspector, let sel = selectedObject(board), !compact {
                        Divider()
                        Inspector(board: board, object: sel, store: store).frame(width: 230)
                    }
                }
            }
        } else {
            EmptyHint(icon: "pencil.and.scribble", title: "No board selected", message: "Pick or create a board to start drawing.")
        }
    }

    // MARK: Coordinates

    private func toBoard(_ p: CGPoint) -> Point { Point(x: Double((p.x - pan.width) / zoom), y: Double((p.y - pan.height) / zoom)) }

    private func selectedObject(_ b: Board) -> BoardObject? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return b.objects.first { $0.id == id }
    }

    // MARK: Canvas

    private func canvas(_ board: Board) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.canvas
            gridBackground(board)
            BoardSurface(board: board, selection: selection, erasing: erasing,
                         offsets: Dictionary(uniqueKeysWithValues: movingIds.map { ($0, dragOffset) }))
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pan.width, y: pan.height)
                .allowsHitTesting(false)
            previewLayer
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pan.width, y: pan.height)
                .allowsHitTesting(false)
            Color.clear.contentShape(Rectangle()).gesture(drawGesture(board))
            entryLayer(board)
        }
        .clipped()
        .background(ScrollZoomMonitor(onScroll: { d, _ in pan = CGSize(width: pan.width + d.width, height: pan.height + d.height) },
                                      onMagnify: { m, loc in zoomBy(1 + m, around: loc) }))
        .focusable()
        .onDeleteCommand { deleteSelection() }
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .topLeading) {
            if board.maxStep > 0 { stepBadge(board).padding(12) }
        }
    }

    private func gridBackground(_ board: Board) -> some View {
        Canvas { ctx, size in
            guard board.background != "plain" else { return }
            let step = 40 * zoom
            guard step > 8 else { return }
            let ox = pan.width.truncatingRemainder(dividingBy: step), oy = pan.height.truncatingRemainder(dividingBy: step)
            let c = Color.secondary.opacity(0.22)
            if board.background == "lines" {
                var y = oy
                while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(c)); y += step }
            } else {
                var x = ox
                while x < size.width {
                    var y = oy
                    while y < size.height { ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(c)); y += step }
                    x += step
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var previewLayer: some View {
        ZStack(alignment: .topLeading) {
            if stroke.count > 0 {
                Path { p in
                    p.move(to: CGPoint(x: stroke[0].x, y: stroke[0].y))
                    for pt in stroke.dropFirst() { p.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
                }
                .stroke(BoardPalette.color(tool == .highlighter && color == "ink" ? "#F5C518" : color).opacity(tool == .highlighter ? 0.35 : 1),
                        style: StrokeStyle(lineWidth: tool == .highlighter ? 18 : CGFloat(width), lineCap: .round, lineJoin: .round))
            }
            if let s = shapeStart, let e = shapeEnd {
                switch tool {
                case .rect:
                    Rectangle().stroke(BoardPalette.color(color), lineWidth: CGFloat(width))
                        .frame(width: abs(CGFloat(e.x - s.x)), height: abs(CGFloat(e.y - s.y)))
                        .offset(x: CGFloat(min(s.x, e.x)), y: CGFloat(min(s.y, e.y)))
                case .ellipse:
                    Ellipse().stroke(BoardPalette.color(color), lineWidth: CGFloat(width))
                        .frame(width: abs(CGFloat(e.x - s.x)), height: abs(CGFloat(e.y - s.y)))
                        .offset(x: CGFloat(min(s.x, e.x)), y: CGFloat(min(s.y, e.y)))
                default:
                    Path { p in p.move(to: CGPoint(x: s.x, y: s.y)); p.addLine(to: CGPoint(x: e.x, y: e.y)) }
                        .stroke(BoardPalette.color(color), lineWidth: CGFloat(width))
                }
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }

    /// Text fields for blanks and hidden recall labels live above the gesture layer so they can take focus.
    private func entryLayer(_ board: Board) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(board.objects) { o in
                if board.isVisible(o) && (o.kind == .blank || (o.hidden && (o.kind == .text || o.kind == .equation))) {
                    let w = max(o.w, o.kind == .blank ? 60 : 90), h = max(o.h, 40)
                    TextField(o.kind == .blank ? (o.text.isEmpty ? "Your answer" : o.text) : "?", text: guessBinding(o))
                        .textFieldStyle(.plain)
                        .font(.system(size: CGFloat(o.kind == .blank ? o.fontSize : 22)))
                        .multilineTextAlignment(.center)
                        .frame(width: CGFloat(w) * zoom - 12, height: CGFloat(h) * zoom)
                        .offset(x: CGFloat(o.x) * zoom + pan.width + 6, y: CGFloat(o.y) * zoom + pan.height)
                }
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }

    private func guessBinding(_ o: BoardObject) -> Binding<String> {
        Binding(get: { board?.objects.first { $0.id == o.id }?.guess ?? "" },
                set: { new in
                    store.mutateBoard(boardId, undoable: false) { b in
                        if let i = b.objects.firstIndex(where: { $0.id == o.id }) { b.objects[i].guess = new }
                    }
                })
    }

    // MARK: Gestures

    private func drawGesture(_ board: Board) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = toBoard(v.location), s = toBoard(v.startLocation)
                switch tool {
                case .hand:
                    if panStart == nil { panStart = pan }
                    pan = CGSize(width: (panStart?.width ?? 0) + v.translation.width, height: (panStart?.height ?? 0) + v.translation.height)
                case .pen, .highlighter:
                    if stroke.isEmpty { stroke = [s] }
                    if let last = stroke.last, hypot(last.x - p.x, last.y - p.y) > 1.5 / Double(zoom) { stroke.append(p) }
                case .eraser:
                    for o in board.objects where board.isVisible(o) && !o.locked && hits(o, p, tolerance: 10 / Double(zoom)) { erasing.insert(o.id) }
                case .select:
                    if !gestureActive {
                        gestureActive = true
                        if let id = topHit(board, s) {
                            if !selection.contains(id) { selection = [id] }
                            movingIds = Set(selection.filter { sid in board.objects.first { $0.id == sid }?.locked == false })
                        } else { selection = []; movingIds = [] }
                    }
                    if !movingIds.isEmpty { dragOffset = CGSize(width: p.x - s.x, height: p.y - s.y) }
                case .rect, .ellipse, .arrow, .line:
                    shapeStart = s; shapeEnd = p
                case .text, .equation:
                    break
                }
            }
            .onEnded { v in
                let p = toBoard(v.location), s = toBoard(v.startLocation)
                commit(board, start: s, end: p)
                stroke = []; shapeStart = nil; shapeEnd = nil; dragOffset = .zero; movingIds = []; erasing = []
                gestureActive = false; panStart = nil
            }
    }

    private func commit(_ board: Board, start s: Point, end p: Point) {
        let dragDist = hypot(p.x - s.x, p.y - s.y)
        switch tool {
        case .pen, .highlighter:
            guard !stroke.isEmpty else { return }
            var o = BoardObject(kind: .stroke)
            o.points = stroke
            o.refreshBounds()
            o.author = "student"
            if tool == .highlighter {
                o.color = color == "ink" ? "#F5C518" : color; o.strokeWidth = 18; o.opacity = 0.35
            } else { o.color = color; o.strokeWidth = width }
            addObject(o)
        case .eraser:
            let ids = erasing
            if !ids.isEmpty { store.mutateBoard(boardId) { $0.objects.removeAll { ids.contains($0.id) } }; selection.subtract(ids) }
        case .select:
            if !movingIds.isEmpty && dragDist > 2 {
                let ids = movingIds, dx = p.x - s.x, dy = p.y - s.y
                store.mutateBoard(boardId) { b in
                    for i in b.objects.indices where ids.contains(b.objects[i].id) { b.objects[i].translate(dx: dx, dy: dy) }
                }
            }
        case .rect, .ellipse:
            var o = BoardObject(kind: .shape, x: min(s.x, p.x), y: min(s.y, p.y), w: abs(p.x - s.x), h: abs(p.y - s.y))
            if o.w < 8 || o.h < 8 { o.x = s.x; o.y = s.y; o.w = 160; o.h = 100 }
            o.shape = tool == .rect ? .rect : .ellipse
            o.color = color; o.strokeWidth = width; o.author = "student"
            addObject(o)
        case .arrow, .line:
            var q = p
            if dragDist < 8 { q = Point(x: s.x + 160, y: s.y) }
            var o = BoardObject(kind: .arrow)
            o.points = [s, q]; o.refreshBounds()
            o.arrowHead = tool == .arrow; o.color = color; o.strokeWidth = width; o.author = "student"
            addObject(o)
        case .text, .equation:
            var o = BoardObject(kind: tool == .text ? .text : .equation, x: s.x, y: s.y)
            o.text = tool == .text ? "Text" : "x^2 + y^2 = r^2"
            o.fontSize = tool == .text ? 28 : 40
            o.color = color; o.author = "student"
            o.estimateTextSize()
            addObject(o)
            tool = .select
        case .hand:
            break
        }
    }

    private func addObject(_ o: BoardObject) {
        store.mutateBoard(boardId) { b in b.objects.append(o) }
        if tool != .pen && tool != .highlighter { selection = [o.id] }
    }

    private func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        store.mutateBoard(boardId) { b in b.objects.removeAll { ids.contains($0.id) && !$0.locked } }
        selection = []
    }

    // MARK: Hit testing

    private func topHit(_ b: Board, _ p: Point) -> String? {
        for o in b.objects.reversed() where b.isVisible(o) && hits(o, p, tolerance: 8 / Double(zoom)) { return o.id }
        return nil
    }

    private func hits(_ o: BoardObject, _ p: Point, tolerance t: Double) -> Bool {
        if o.isPointBased && o.points.count >= 2 {
            for i in 0..<(o.points.count - 1) where distance(p, o.points[i], o.points[i + 1]) <= t + o.strokeWidth { return true }
            return false
        }
        if o.isPointBased, let only = o.points.first { return hypot(p.x - only.x, p.y - only.y) <= t + o.strokeWidth }
        return p.x >= o.x - t && p.x <= o.x + o.w + t && p.y >= o.y - t && p.y <= o.y + o.h + t
    }

    private func distance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Zoom

    private func zoomBy(_ factor: CGFloat, around loc: CGPoint? = nil) {
        let new = max(0.2, min(4, zoom * factor))
        let anchor = loc ?? CGPoint(x: 400, y: 300)
        let bx = (anchor.x - pan.width) / zoom, by = (anchor.y - pan.height) / zoom
        zoom = new
        pan = CGSize(width: anchor.x - bx * new, height: anchor.y - by * new)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoomBy(0.8) } label: { Image(systemName: "minus") }.help("Zoom out")
            Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { zoomBy(1.25) } label: { Image(systemName: "plus") }.help("Zoom in")
            Button { zoom = 1; pan = CGSize(width: 24, height: 24) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Reset view")
        }
        .buttonStyle(.borderless).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
    }

    private func stepBadge(_ b: Board) -> some View {
        HStack(spacing: 8) {
            Button { setStep(b.currentStep - 1) } label: { Image(systemName: "chevron.left") }.disabled(b.currentStep <= 0)
            Text("Step \(b.currentStep) of \(b.maxStep)").font(.caption.weight(.medium)).monospacedDigit()
            Button { setStep(b.currentStep + 1) } label: { Image(systemName: "chevron.right") }.disabled(b.currentStep >= b.maxStep)
            Button("Show all") { setStep(b.maxStep) }.disabled(b.currentStep >= b.maxStep)
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
    }

    private func setStep(_ s: Int) {
        store.mutateBoard(boardId, undoable: false) { $0.currentStep = max(0, s) }
    }

    // MARK: Toolbar

    private func toolbar(_ board: Board) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(BoardTool.allCases) { t in
                    Button { tool = t } label: {
                        Image(systemName: t.icon).frame(width: 28, height: 26)
                            .background(tool == t ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help(t.label).accessibilityLabel(t.label)
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 4) {
                ForEach(BoardPalette.swatches, id: \.value) { sw in
                    Button { color = sw.value; applyColorToSelection(sw.value) } label: {
                        Circle().fill(BoardPalette.color(sw.value)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(color == sw.value ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: color == sw.value ? 2.5 : 1))
                    }
                    .buttonStyle(.plain).help(sw.name).accessibilityLabel(sw.name)
                }
            }
            Picker("", selection: $width) {
                Text("Thin").tag(2.0); Text("Medium").tag(4.0); Text("Thick").tag(8.0)
            }.pickerStyle(.menu).frame(width: 80).labelsHidden()
            Divider().frame(height: 20)
            Button { store.undoBoard(boardId) } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo(boardId)).help("Undo (⌘Z)").keyboardShortcut("z", modifiers: .command)
            Button { store.redoBoard(boardId) } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.canRedo(boardId)).help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 20)
            Button { addImage() } label: { Image(systemName: "photo") }.help("Add image")
            Menu {
                Button("Hide all labels (recall test)") { setRecall(true) }
                Button("Reveal all labels") { setRecall(false) }
                Divider()
                Picker("Background", selection: Binding(get: { board.background }, set: { b in store.mutateBoard(boardId) { $0.background = b } })) {
                    Text("Dots").tag("grid"); Text("Lines").tag("lines"); Text("Plain").tag("plain")
                }
                Divider()
                Button("Export as PNG…") { exportPNG() }
                Button("Clear board", role: .destructive) { store.mutateBoard(boardId) { $0.objects.removeAll(); $0.currentStep = 0 }; selection = [] }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 34)
            Spacer()
            if !compact { Toggle(isOn: $showInspector) { Image(systemName: "sidebar.right") }.toggleStyle(.button).help("Inspector") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func applyColorToSelection(_ c: String) {
        let ids = selection
        guard !ids.isEmpty else { return }
        store.mutateBoard(boardId) { b in for i in b.objects.indices where ids.contains(b.objects[i].id) { b.objects[i].color = c } }
    }

    private func setRecall(_ hide: Bool) {
        store.mutateBoard(boardId) { b in
            for i in b.objects.indices where b.objects[i].kind == .text || b.objects[i].kind == .equation {
                if hide {
                    if b.objects[i].expected == nil { b.objects[i].expected = b.objects[i].text }
                    b.objects[i].hidden = true
                } else { b.objects[i].hidden = false }
            }
        }
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), data.count < 8_000_000, let img = NSImage(data: data) else { return }
        var o = BoardObject(kind: .image, x: 80, y: 80)
        let ratio = img.size.height / max(img.size.width, 1)
        o.w = min(480, Double(img.size.width)); o.h = o.w * Double(ratio)
        o.imageData = data; o.author = "student"
        addObject(o)
    }

    private func exportPNG() {
        guard let png = BoardRenderer.png(for: board, maxSide: 2400) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (board?.title ?? "board") + ".png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

struct Inspector: View {
    let board: Board
    let object: BoardObject
    let store: StudyStore

    private func update(_ undoable: Bool = true, _ f: @escaping (inout BoardObject) -> Void) {
        store.mutateBoard(board.id, undoable: undoable) { b in
            if let i = b.objects.firstIndex(where: { $0.id == object.id }) { f(&b.objects[i]) }
        }
    }

    var body: some View {
        Form {
            Section(object.kind.rawValue.capitalized + (object.name.map { " · \($0)" } ?? "")) {
                if object.kind == .text || object.kind == .equation || object.kind == .shape || object.kind == .blank {
                    TextField(object.kind == .blank ? "Prompt" : "Text", text: Binding(get: { object.text }, set: { t in
                        update(false) { $0.text = t; if $0.kind == .text || $0.kind == .equation { $0.estimateTextSize() } }
                    }), axis: .vertical).lineLimit(1...5)
                }
                if object.kind == .text || object.kind == .equation {
                    Stepper("Size \(Int(object.fontSize))", value: Binding(get: { object.fontSize }, set: { v in
                        update { $0.fontSize = v; $0.estimateTextSize() }
                    }), in: 10...120, step: 2)
                    Toggle("Bold", isOn: Binding(get: { object.bold }, set: { v in update { $0.bold = v } }))
                }
                Stepper("Appears at step \(object.step)", value: Binding(get: { object.step }, set: { v in update { $0.step = v } }), in: 0...50)
                Toggle("Hide for recall", isOn: Binding(get: { object.hidden }, set: { v in
                    update { if $0.expected == nil { $0.expected = $0.text }; $0.hidden = v }
                })).disabled(object.kind != .text && object.kind != .equation)
                Toggle("Highlight", isOn: Binding(get: { object.highlighted }, set: { v in update { $0.highlighted = v } }))
                Toggle("Lock position", isOn: Binding(get: { object.locked }, set: { v in update { $0.locked = v } }))
                Toggle("Animate (jiggle)", isOn: Binding(get: { object.motion != nil }, set: { v in
                    update { $0.motion = v ? Motion(type: "jiggle", amplitude: 3, speed: 6) : nil }
                })).disabled(object.kind != .particle && object.kind != .shape && object.kind != .text)
            }
            Section {
                Button("Bring to front") {
                    store.mutateBoard(board.id) { b in
                        if let i = b.objects.firstIndex(where: { $0.id == object.id }) { let o = b.objects.remove(at: i); b.objects.append(o) }
                    }
                }
                Button("Delete", role: .destructive) {
                    store.mutateBoard(board.id) { b in b.objects.removeAll { $0.id == object.id } }
                }
            }
        }
        .formStyle(.grouped)
    }
}
