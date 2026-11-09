import SwiftUI
import AppKit

struct InspectorView: View {
    var agent: Agent
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(\.deckAccent) private var accent
    @State private var followUp = ""
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 30)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let req = agent.pendingPermission, agent.capabilities.contains(.approve) {
                        PermissionPanel(agent: agent, request: req)
                    } else if agent.status == .waitingApproval {
                        notice(symbol: "hand.raised.fill", color: Theme.amber,
                               text: "This agent is waiting for approval. Answer it in \(agent.provider.displayName) — AgentDeck never approves on your behalf.")
                    }
                    details
                    if let msg = agent.lastMessage, !msg.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Latest output")
                            Text(msg).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(6).textSelection(.enabled)
                        }
                    }
                    timeline
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            actions
        }
        .confirmationDialog("Stop “\(agent.title)”?", isPresented: $confirmStop) {
            Button("Stop agent", role: .destructive) { manager.perform(.stop, on: agent) }
        } message: {
            Text(agent.provider == .cursor ? "The ACP session ends. The chat stays in Cursor and can be resumed from the terminal." : "Runs `claude stop`. The conversation is kept and can be resumed.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderIcon(provider: agent.provider, size: 30)
                Text(agent.provider.displayName).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                OwnershipBadge(ownership: agent.ownership)
                Spacer()
                Menu {
                    AgentContextMenu(agent: agent)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary).frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                IconButton(symbol: "sidebar.right", help: "Hide inspector") { ui.inspectorCollapsed = true }
            }
            Text(agent.title).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(manager.project(agent.projectID)?.name ?? Fmt.abbreviatePath(agent.workingDirectory))
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                StatusPill(status: agent.status)
                if let p = agent.progress { Text(p.label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
            if let d = agent.statusDetail, !agent.status.isWaiting || agent.pendingPermission == nil {
                Text(d).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let p = agent.progress { ProgressBar(fraction: p.fraction) }
        }
        .padding(.top, 4)
    }

    private var details: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                Rectangle().fill(Theme.divider).frame(height: 1)
                DetailRow(symbol: "cpu", label: "Model", value: agent.model ?? "Not reported by provider")
                DetailRow(symbol: "folder", label: "Repository", value: Fmt.abbreviatePath(agent.workingDirectory), copy: agent.workingDirectory)
                if let b = agent.gitBranch { DetailRow(symbol: "arrow.triangle.branch", label: "Branch", value: b, copy: b) }
                if let cwd = agent.workingDirectory, let b = agent.gitBranch, let review = GitInfo.reviewURL(at: cwd, branch: b) {
                    HStack {
                        Spacer().frame(width: 26)
                        Button(review.label) { NSWorkspace.shared.open(review.url) }.buttonStyle(.link).font(.system(size: 12))
                        if let url = GitInfo.branchURL(at: cwd, branch: b) {
                            Button("Branch on web") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.system(size: 12))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                if let st = agent.stats {
                    if let a = st.linesAdded, let r = st.linesRemoved, a + r > 0 {
                        DetailRow(symbol: "plusminus", label: "Changes", value: "+\(a) −\(r)" + (st.filesChanged.map { " · \($0) file\($0 == 1 ? "" : "s")" } ?? ""))
                    }
                    if let p = st.contextPercent {
                        DetailRow(symbol: "gauge.with.dots.needle.33percent", label: "Context used", value: "\(Int(p.rounded()))%" + (st.contextTokens.map { " · \(StatsText.tokens($0)) tokens" } ?? ""))
                    } else if let t = st.contextTokens {
                        DetailRow(symbol: "gauge.with.dots.needle.33percent", label: "Context", value: "\(t.formatted()) tokens (latest turn)")
                    }
                }
                DetailRow(symbol: "number", label: "Session", value: agent.handle.map { "\($0) · \(agent.sessionID.prefix(8))…" } ?? String(agent.sessionID.prefix(13)) + "…", copy: agent.sessionID)
                DetailRow(symbol: "terminal", label: "Type", value: [agent.kindLabel, agent.ownership.label].compactMap { $0 }.joined(separator: " · "))
                DetailRow(symbol: "clock", label: "Started", value: agent.startedAt.map { Fmt.relative($0, now: ctx.date) } ?? "—",
                          tooltip: agent.startedAt.map { Fmt.dateTime.string(from: $0) })
                if agent.status.isLive, let s = agent.startedAt {
                    DetailRow(symbol: "timer", label: "Duration", value: Fmt.preciseDuration(ctx.date.timeIntervalSince(s)))
                }
                DetailRow(symbol: "bolt.horizontal", label: "Last activity", value: Fmt.relative(agent.lastActivity, now: ctx.date),
                          tooltip: agent.lastActivity.map { Fmt.dateTime.string(from: $0) })
                if let pid = agent.pid { DetailRow(symbol: "gearshape.2", label: "Process", value: "PID \(pid)") }
            }
        }
    }

    private var timeline: some View {
        let events = Array(manager.events(for: agent).prefix(30))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if events.isEmpty {
                Text("No events recorded yet. Events appear as AgentDeck observes status changes.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, e in
                    TimelineRow(event: e, isFirst: idx == 0, isLast: idx == events.count - 1, live: idx == 0 && agent.status == .working)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 9) {
            if agent.capabilities.contains(.sendMessage) {
                HStack(spacing: 8) {
                    TextField("Send follow-up instructions…", text: $followUp, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...4)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                        .onSubmit(sendFollowUp)
                    Button(action: sendFollowUp) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.status == .working)
                        .help(agent.status == .working ? "Wait for the current turn to finish, or interrupt it." : "Send")
                }
            }
            if !agent.capabilities.isDisjoint(with: [.focus, .resume]) {
                Button {
                    manager.perform(agent.capabilities.contains(.focus) ? .focus : .resume, on: agent)
                } label: {
                    Label(agent.focusLabel, systemImage: "arrow.up.forward.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 8) {
                if agent.capabilities.contains(.interrupt) {
                    Button { manager.perform(.interrupt, on: agent) } label: {
                        Label("Interrupt", systemImage: "pause.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryButtonStyle())
                }
                if agent.capabilities.contains(.stop) {
                    Button { confirmStop = true } label: {
                        Label("Stop agent", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                }
            }
            if agent.capabilities.isDisjoint(with: [.stop, .interrupt]) && agent.status.isLive {
                Text("Monitored only — stop this session in \(agent.provider == .claudeCode ? "its terminal or Claude app" : "its terminal").")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .background(Theme.inspectorBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, agent.status != .working else { return }
        manager.send(text, to: agent)
        followUp = ""
    }

    private func notice(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.25)))
    }
}

private struct PermissionPanel: View {
    var agent: Agent
    var request: PermissionRequest
    @Environment(AgentManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
                Text("Permission requested").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(request.title).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            if let d = request.detail {
                Text(d).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.windowBackground))
                    .textSelection(.enabled)
            }
            VStack(spacing: 6) {
                ForEach(request.options, id: \.id) { o in
                    Button { manager.respond(agent, optionID: o.id) } label: { Text(o.name).frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle(tint: o.isAllow ? Theme.green : Theme.red))
                }
            }
            Text("Relayed from Cursor's own permission system via ACP.").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.amber.opacity(0.3)))
    }
}

private struct DetailRow: View {
    var symbol: String
    var label: String
    var value: String
    var copy: String? = nil
    var tooltip: String? = nil
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary).frame(width: 18)
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
                Text(value).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    .help(tooltip ?? value)
                Spacer(minLength: 0)
                if let copy {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).opacity(hover ? 1 : 0.5).help("Copy")
                }
            }
            .padding(.vertical, 9)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .onHover { hover = $0 }
    }
}

struct TimelineRow: View {
    var event: AgentEvent
    var isFirst: Bool
    var isLast: Bool
    var live: Bool
    @Environment(\.deckAccent) private var accent

    private var color: Color {
        switch event.kind {
        case .completed, .started, .resumed: return Theme.green
        case .failed: return Theme.red
        case .permissionRequested: return Theme.amber
        case .stopped: return Theme.grey
        default: return accent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 22, height: 22)
                    if live { Circle().strokeBorder(accent, lineWidth: 2.5).frame(width: 14, height: 14) }
                    else { Image(systemName: event.kind.symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(color) }
                }
                if !isLast { Rectangle().fill(Theme.divider).frame(width: 1.5).frame(minHeight: 18) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).lineLimit(3)
                Text(Fmt.relative(event.date)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .help(Fmt.dateTime.string(from: event.date))
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer(minLength: 0)
        }
    }
}
