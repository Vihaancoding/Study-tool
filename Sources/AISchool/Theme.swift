import SwiftUI
import AppKit
import StudyCore

enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.45, green: 0.62, blue: 1.0, alpha: 1) : NSColor(red: 0.20, green: 0.34, blue: 0.80, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.985, alpha: 1)
    })
    static let hairline = Color(nsColor: .separatorColor)
    static let good = Color(red: 0.19, green: 0.64, blue: 0.42)
    static let warn = Color(red: 0.96, green: 0.42, blue: 0.08)
    static let bad = Color(red: 0.90, green: 0.28, blue: 0.30)

    static func mastery(_ m: MasteryLevel) -> Color {
        switch m {
        case .unseen: return .secondary
        case .struggling: return bad
        case .learning: return warn
        case .provisional: return accent
        case .secure: return good
        }
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.secondary)
    }
}

struct MasteryPill: View {
    let level: MasteryLevel
    var body: some View {
        Text(level.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.mastery(level).opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.mastery(level))
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(32)
    }
}

extension View {
    func quietPanel() -> some View {
        self.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline.opacity(0.6)))
    }
}

func relativeDay(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    case 2...6: return "In \(days) days"
    case -6 ... -2: return "\(-days) days ago"
    default: return d.formatted(date: .abbreviated, time: .omitted)
    }
}
