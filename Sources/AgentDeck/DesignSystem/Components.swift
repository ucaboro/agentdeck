import SwiftUI
import AppKit

/// Provider glyph: uses the locally installed app icon (Claude / Cursor) when
/// present, otherwise a neutral SF Symbol.
struct ProviderIcon: View {
    var provider: ProviderKind
    var size: CGFloat = 22

    private static var cache: [ProviderKind: NSImage] = [:]

    private var image: NSImage? {
        if let c = Self.cache[provider] { return c }
        let ids = provider == .claudeCode ? ["com.anthropic.claudefordesktop"] : ["com.todesktop.230313mzl4w4u92"]
        var url = ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        if url == nil {
            let path = provider == .claudeCode ? "/Applications/Claude.app" : "/Applications/Cursor.app"
            if FileManager.default.fileExists(atPath: path) { url = URL(fileURLWithPath: path) }
        }
        guard let url else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[provider] = img
        return img
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: provider == .claudeCode ? "asterisk" : "cube.fill")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(provider == .claudeCode ? Color(hex: "D97757") : Theme.textPrimary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25).fill(Theme.surfaceRaised))
        }
    }
}

struct StatusPill: View {
    var status: AgentStatus
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if status == .working {
                PulsingDot(color: status.color)
            } else if status == .idle || status == .unknown {
                Circle().fill(status.color).frame(width: 7, height: 7)
            } else {
                Image(systemName: status.symbol).font(.system(size: 9, weight: .heavy))
            }
            Text(status.shortLabel.uppercased())
                .font(.system(size: compact ? 10 : 10.5, weight: .bold))
                .tracking(0.4)
                .lineLimit(1)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(Capsule().fill(status.color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(status.color.opacity(0.18), lineWidth: 1))
        .accessibilityLabel("Status: \(status.label)")
    }
}

struct PulsingDot: View {
    var color: Color
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 7, height: 7).scaleEffect(pulse ? 2.0 : 1).opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

struct OwnershipBadge: View {
    var ownership: AgentOwnership
    @Environment(\.deckAccent) private var accent
    var body: some View {
        Text(ownership.label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(ownership == .managed ? accent : Theme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().strokeBorder(ownership == .managed ? accent.opacity(0.5) : Theme.border))
            .help(ownership == .managed ? "Launched by AgentDeck — can be controlled from here." : "Discovered locally — AgentDeck monitors it; control happens in the original app.")
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var active = false
    var action: () -> Void
    @State private var hover = false
    @Environment(\.deckAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? accent : (hover ? Theme.textPrimary : Theme.textTertiary))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.surfaceRaised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.deckAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(enabled ? 1 : 0.4), accent.opacity(enabled ? 0.82 : 0.35)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .shadow(color: accent.opacity(enabled ? 0.35 : 0), radius: 10, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint ?? Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(configuration.isPressed ? Theme.surfaceHover : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.borderStrong))
    }
}

struct ProjectDot: View {
    var hex: String
    var size: CGFloat = 10
    var body: some View { Circle().fill(Color(hex: hex)).frame(width: size, height: size) }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.textTertiary)
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

/// Sparkline of recent activity (events/hour), derived from real events only.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: geo.size.height - CGFloat(v / maxV) * geo.size.height)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
