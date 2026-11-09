import SwiftUI
import AppKit

struct AgentCardView: View {
    var agent: Agent
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(\.deckAccent) private var accent
    @State private var hover = false

    var body: some View {
        let selected = ui.selection == agent.id
        let project = manager.project(agent.projectID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderIcon(provider: agent.provider, size: 22)
                Text(agent.provider.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if agent.ownership == .managed { OwnershipBadge(ownership: .managed) }
                Spacer()
                IconButton(symbol: agent.isPinned ? "pin.fill" : "pin", help: agent.isPinned ? "Unpin" : "Pin", active: agent.isPinned) {
                    withAnimation { manager.togglePin(agent) }
                }
                IconButton(symbol: "arrow.up.forward.square", help: agent.focusLabel) {
                    manager.perform(agent.capabilities.contains(.focus) ? .focus : .resume, on: agent)
                }
                .disabled(agent.capabilities.isDisjoint(with: [.focus, .resume]))
            }
            .padding(.bottom, 9)

            Text(agent.title)
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .help(agent.title)
                .padding(.bottom, 6)

            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11.5))
                Text(project?.name ?? Fmt.abbreviatePath(agent.workingDirectory)).lineLimit(1)
                if let b = agent.gitBranch {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(b).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.bottom, 12)

            HStack {
                StatusPill(status: agent.status)
                Spacer()
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 11.5))
                        Text(timeText(now: ctx.date)).font(.system(size: 12.5).monospacedDigit())
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }

            if let stats = agent.stats, let text = StatsText.line(stats) {
                Text(text)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 8)
                    .help(StatsText.help(stats))
            }

            if let line = attentionLine {
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(agent.status.needsAttention ? agent.status.color : Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 8)
            }

            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 11)

            HStack(spacing: 7) {
                Image(systemName: "cpu").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text(agent.model ?? "Model not reported")
                    .font(.system(size: 12.5))
                    .foregroundStyle(agent.model == nil ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let p = agent.progress {
                    ProgressBar(fraction: p.fraction).frame(width: 110).help(p.label)
                } else {
                    Text(agent.kindLabel ?? "").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(16)
        .deckCard(selected: selected, hovered: hover)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { hover = $0 }
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                manager.perform(agent.capabilities.contains(.focus) ? .focus : .resume, on: agent)
            } else {
                ui.select(agent.id)
            }
        }
        .contextMenu { AgentContextMenu(agent: agent) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.provider.displayName) agent \(agent.title), \(agent.status.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var attentionLine: String? {
        if agent.status.isWaiting { return agent.pendingPermission?.title ?? agent.statusDetail }
        if agent.status == .failed { return agent.statusDetail }
        if agent.status == .working, let a = agent.currentActivity { return a }
        return nil
    }

    private func timeText(now: Date) -> String {
        if agent.status.isLive, let s = agent.startedAt { return Fmt.duration(now.timeIntervalSince(s)) }
        return Fmt.relative(agent.lastActivity, now: now)
    }
}

/// Formats provider-reported usage. Only numbers the provider recorded are shown.
enum StatsText {
    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    static func line(_ s: AgentStats) -> String? {
        var parts: [String] = []
        if let a = s.linesAdded, let r = s.linesRemoved, a + r > 0 { parts.append("+\(a) −\(r)") }
        if let f = s.filesChanged, f > 0 { parts.append("\(f) file\(f == 1 ? "" : "s")") }
        if let p = s.contextPercent { parts.append("\(Int(p.rounded()))% context") }
        else if let t = s.contextTokens { parts.append("\(tokens(t)) context") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func help(_ s: AgentStats) -> String {
        var lines: [String] = []
        if let a = s.linesAdded, let r = s.linesRemoved { lines.append("Lines added / removed: \(a) / \(r)") }
        if let f = s.filesChanged { lines.append("Files changed: \(f)") }
        if let p = s.contextPercent { lines.append("Context window used: \(Int(p.rounded()))%") }
        if let t = s.contextTokens { lines.append("Context tokens (latest turn): \(t.formatted())") }
        return lines.joined(separator: "\n") + "\nAs recorded by the provider."
    }
}

struct ProgressBar: View {
    var fraction: Double
    @Environment(\.deckAccent) private var accent
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule().fill(accent).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(.easeOut, value: fraction)
    }
}

struct AgentContextMenu: View {
    var agent: Agent
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui

    var body: some View {
        if agent.capabilities.contains(.focus) { Button(agent.focusLabel) { manager.perform(.focus, on: agent) } }
        if agent.capabilities.contains(.resume) { Button("Resume in Terminal") { manager.perform(.resume, on: agent) } }
        if agent.capabilities.contains(.interrupt) { Button("Interrupt current turn") { manager.perform(.interrupt, on: agent) } }
        if agent.capabilities.contains(.stop) { Button("Stop agent") { manager.perform(.stop, on: agent) } }
        Divider()
        Button(agent.isPinned ? "Unpin" : "Pin") { manager.togglePin(agent) }
        Button("Show details") { ui.select(agent.id) }
        if agent.workingDirectory != nil {
            if agent.provider == .cursor { Button("Open workspace in Cursor") { manager.perform(.openWorkspace, on: agent) } }
            Button("Reveal folder in Finder") { manager.perform(.revealInFinder, on: agent) }
        }
        if let cwd = agent.workingDirectory, let b = agent.gitBranch {
            if let review = GitInfo.reviewURL(at: cwd, branch: b) { Button(review.label) { NSWorkspace.shared.open(review.url) } }
            if let url = GitInfo.branchURL(at: cwd, branch: b) { Button("Open branch on web") { NSWorkspace.shared.open(url) } }
        }
        Divider()
        Button("Copy session ID") { copy(agent.sessionID) }
        Button("Copy resume command") { copy(resumeCommand) }
        if manager.isArchived(agent) {
            Divider()
            Button("Move back to dashboard") { manager.unarchive(agent) }
        } else if agent.status.isArchivable {
            Divider()
            Button("Archive") { manager.archive(agent) }
        }
    }

    private var resumeCommand: String {
        switch agent.provider {
        case .claudeCode: return TerminalLauncher.describe("claude", ["--resume", agent.sessionID], cwd: agent.workingDirectory)
        case .cursor: return TerminalLauncher.describe("cursor-agent", ["--resume", agent.sessionID], cwd: agent.workingDirectory)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        manager.toast = "Copied to clipboard"
    }
}
