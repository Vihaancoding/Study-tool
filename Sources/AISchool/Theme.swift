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
        Text(text).font(.system(size: 11.5, weight: .semibold)).textCase(.uppercase).tracking(0.8).foregroundStyle(.secondary)
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

extension Theme {
    static let gradient = LinearGradient(colors: [Color(red: 0.33, green: 0.42, blue: 0.96), Color(red: 0.60, green: 0.36, blue: 0.93)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let heroGradient = LinearGradient(colors: [Color(red: 0.25, green: 0.33, blue: 0.88), Color(red: 0.52, green: 0.30, blue: 0.86), Color(red: 0.86, green: 0.40, blue: 0.62)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Route {
    var tint: Color {
        switch self {
        case .home: return Color(red: 0.33, green: 0.52, blue: 0.98)
        case .learn: return Color(red: 0.58, green: 0.38, blue: 0.93)
        case .whiteboard: return Color(red: 0.96, green: 0.55, blue: 0.20)
        case .practice: return Color(red: 0.20, green: 0.70, blue: 0.50)
        case .subjects: return Color(red: 0.90, green: 0.38, blue: 0.55)
        case .mistakes: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .schedule: return Color(red: 0.20, green: 0.68, blue: 0.80)
        case .settings: return Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }
}

struct IconTile: View {
    let symbol: String
    var color: Color = Theme.accent
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.70)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Theme.gradient, in: Capsule())
            .shadow(color: Color(red: 0.4, green: 0.3, blue: 0.9).opacity(enabled ? 0.35 : 0), radius: 8, y: 3)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(red: 0.28, green: 0.30, blue: 0.85))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color.white, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Rounded surface with a soft shadow. The standard container for grouped content.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
    func quietPanel() -> some View { card(padding: 16) }
    func hoverLift() -> some View { modifier(HoverLift()) }
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
