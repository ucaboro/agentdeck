import SwiftUI

struct ActivityView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @State private var provider: ProviderKind?
    @State private var projectID: String?
    @State private var kind: AgentEventKind?
    @State private var confirmClear = false

    private var filtered: [AgentEvent] {
        manager.events.filter { e in
            (provider == nil || e.provider == provider) &&
            (projectID == nil || e.projectID == projectID) &&
            (kind == nil || e.kind == kind)
        }
    }

    private var grouped: [(Date, [AgentEvent])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered.prefix(600)) { cal.startOfDay(for: $0.date) }
        return dict.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Lifecycle events observed across all agents.").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Clear history…") { confirmClear = true }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 14)

            HStack(spacing: 10) {
                Picker("Provider", selection: $provider) {
                    Text("All providers").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag(ProviderKind?.some($0)) }
                }.frame(width: 190)
                Picker("Project", selection: $projectID) {
                    Text("All projects").tag(String?.none)
                    ForEach(manager.projects.filter { !$0.isHidden }) { Text($0.name).tag(String?.some($0.id)) }
                }.frame(width: 220)
                Picker("Event", selection: $kind) {
                    Text("All events").tag(AgentEventKind?.none)
                    ForEach(AgentEventKind.allCases, id: \.self) { Text($0.label).tag(AgentEventKind?.some($0)) }
                }.frame(width: 190)
                Spacer()
                Text("\(filtered.count) events").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            .labelsHidden()

            if filtered.isEmpty {
                EmptyStateView(symbol: "waveform.path.ecg", title: "No activity yet",
                               message: "Events appear as agents start, change state, ask for permission, finish or stop.")
                    .deckCard()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.0) { day, events in
                            Section {
                                VStack(spacing: 0) {
                                    DaySummary(events: events)
                                    ForEach(events) { e in ActivityRow(event: e) }
                                }
                                .deckCard()
                            } header: {
                                Text(Fmt.dateTime.string(from: day).components(separatedBy: " at").first ?? "")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                                    .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.windowBackground)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .confirmationDialog("Clear all activity history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { manager.persistence.clearEvents(); manager.reloadEvents() }
        } message: { Text("This only removes AgentDeck's local event log. Sessions are not affected.") }
    }
}

/// One-line digest of a day: how many agents were active, what finished, what needed you, and where.
private struct DaySummary: View {
    var events: [AgentEvent]
    @Environment(AgentManager.self) private var manager

    var body: some View {
        let agents = Set(events.map(\.agentID))
        let started = Set(events.filter { $0.kind == .started || $0.kind == .discovered }.map(\.agentID)).count
        let completed = Set(events.filter { $0.kind == .completed }.map(\.agentID)).count
        let failed = Set(events.filter { $0.kind == .failed }.map(\.agentID)).count
        let asks = events.filter { $0.kind == .permissionRequested }.count
        let byProject = Dictionary(grouping: events.compactMap(\.projectID), by: { $0 })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(3)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                chip("\(agents.count) agent\(agents.count == 1 ? "" : "s") active", Theme.textSecondary)
                if started > 0 { chip("\(started) started", Theme.blue) }
                if completed > 0 { chip("\(completed) completed", Theme.green) }
                if failed > 0 { chip("\(failed) failed", Theme.red) }
                if asks > 0 { chip("\(asks) approval\(asks == 1 ? "" : "s") asked", Theme.amber) }
                Spacer()
            }
            if !byProject.isEmpty {
                HStack(spacing: 10) {
                    Text("Most active:").foregroundStyle(Theme.textTertiary)
                    ForEach(Array(byProject), id: \.0) { pid, n in
                        if let p = manager.project(pid) {
                            HStack(spacing: 5) { ProjectDot(hex: p.colorHex, size: 7); Text("\(p.name) (\(n))") }
                        }
                    }
                    Spacer()
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct ActivityRow: View {
    var event: AgentEvent
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @State private var hover = false

    var body: some View {
        let agent = manager.agents[event.agentID]
        let project = manager.project(event.projectID)
        Button {
            if agent != nil { ui.section = .all; ui.filter = .all; ui.select(event.agentID) }
        } label: {
            HStack(spacing: 12) {
                Text(Fmt.time.string(from: event.date)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .leading)
                Image(systemName: event.kind.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    .frame(width: 24, height: 24).background(Circle().fill(color.opacity(0.15)))
                ProviderIcon(provider: event.provider, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.title ?? "Session").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(event.message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer()
                if let project {
                    HStack(spacing: 5) { ProjectDot(hex: project.colorHex, size: 7); Text(project.name) }
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Text(event.kind.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(color.opacity(0.12)))
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(hover ? Theme.surfaceHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var color: Color {
        switch event.kind {
        case .completed, .started, .resumed: return Theme.green
        case .failed: return Theme.red
        case .permissionRequested: return Theme.amber
        case .stopped: return Theme.grey
        default: return Color(hex: manager.settings.accentHex)
        }
    }
}
