import SwiftUI
import AppKit

extension Color {
    init(hex: String, opacity: Double = 1) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: opacity)
    }

    /// Appearance-aware color resolved by AppKit at draw time.
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Design tokens. Dark palette mirrors the reference: charcoal surfaces with a
/// faint violet cast, restrained borders, purple accent.
enum Theme {
    static let windowBackground = Color.dynamic(light: "F6F5FA", dark: "0F0E14")
    static let sidebarBackground = Color.dynamic(light: "EEEDF4", dark: "14131B")
    static let inspectorBackground = Color.dynamic(light: "F1F0F6", dark: "13121A")
    static let surface = Color.dynamic(light: "FFFFFF", dark: "1A1922")
    static let surfaceRaised = Color.dynamic(light: "FFFFFF", dark: "201F2A")
    static let surfaceHover = Color.dynamic(light: "F7F6FC", dark: "1F1E28")
    static let border = Color.dynamic(light: "E3E1EC", dark: "2A2834")
    static let borderStrong = Color.dynamic(light: "D4D1E0", dark: "353341")
    static let textPrimary = Color.dynamic(light: "16151C", dark: "F3F2F8")
    static let textSecondary = Color.dynamic(light: "5F5B6E", dark: "A6A2B5")
    static let textTertiary = Color.dynamic(light: "8F8BA0", dark: "6F6B80")
    static let divider = Color.dynamic(light: "E6E4EE", dark: "24222D")

    static let green = Color(hex: "22C55E")
    static let amber = Color(hex: "F5A524")
    static let blueGrey = Color(hex: "8A94B0")
    static let red = Color(hex: "EF4444")
    static let blue = Color(hex: "60A5FA")
    static let grey = Color(hex: "71717A")

    static let radius: CGFloat = 14
    static let smallRadius: CGFloat = 9
}

private struct AccentKey: EnvironmentKey { static let defaultValue = Color(hex: "8B5CF6") }
extension EnvironmentValues {
    var deckAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

extension AgentStatus {
    var color: Color {
        switch self {
        case .working: return Theme.green
        case .idle: return Theme.blueGrey
        case .waitingApproval, .waitingInput: return Theme.amber
        case .completed: return Theme.green
        case .failed: return Theme.red
        case .stopped: return Theme.grey
        case .unknown: return Theme.grey
        }
    }

    var symbol: String {
        switch self {
        case .working: return "circle.fill"
        case .idle: return "circle.fill"
        case .waitingApproval: return "pause.fill"
        case .waitingInput: return "ellipsis.bubble.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.fill"
        case .unknown: return "questionmark"
        }
    }

    var shortLabel: String {
        switch self {
        case .waitingApproval: return "Waiting for approval"
        case .waitingInput: return "Waiting for input"
        default: return label
        }
    }
}

struct CardStyle: ViewModifier {
    var selected = false
    var hovered = false
    @Environment(\.deckAccent) private var accent

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(selected ? accent.opacity(0.10) : (hovered ? Theme.surfaceHover : Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.9) : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: selected ? accent.opacity(0.35) : .black.opacity(0.12), radius: selected ? 14 : 6, y: selected ? 0 : 2)
    }
}

extension View {
    func deckCard(selected: Bool = false, hovered: Bool = false) -> some View { modifier(CardStyle(selected: selected, hovered: hovered)) }
}

/// Formatting helpers.
enum Fmt {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }

    static func preciseDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return duration(seconds)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let d = now.timeIntervalSince(date)
        if d < 10 { return "just now" }
        if d < 60 { return "\(Int(d))s ago" }
        if d < 3600 { return "\(Int(d / 60))m ago" }
        if d < 86_400 { return "\(Int(d / 3600))h ago" }
        return "\(Int(d / 86_400))d ago"
    }

    static func abbreviatePath(_ path: String?) -> String {
        guard let path else { return "—" }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
