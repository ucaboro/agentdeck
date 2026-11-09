import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @FocusState private var searchFocused: Bool

    @State private var confirmArchive = false

    private var scoped: [Agent] {
        var list = ui.section == .archived ? manager.archivedAgents : manager.visibleAgents
        switch ui.section {
        case .pinned: list = list.filter(\.isPinned)
        case .project(let id): list = list.filter { $0.projectID == id }
        default: break
        }
        if let p = ui.providerFilter { list = list.filter { $0.provider == p } }
        return list
    }

    private var filtered: [Agent] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        return manager.sorted(scoped.filter { a in
            ui.filter.matches(a.status) && (q.isEmpty || [a.title, a.model ?? "", a.workingDirectory ?? "", a.gitBranch ?? "",
                                                        manager.project(a.projectID)?.name ?? "", a.provider.displayName]
                .contains { $0.lowercased().contains(q) })
        })
    }

    private var title: String {
        if case .project(let id) = ui.section { return manager.project(id)?.name ?? "Project" }
        return ui.section.title
    }

    private var subtitle: String {
        switch ui.section {
        case .overview: return "Your local agents, in one place."
        case .pinned: return "Agents you are keeping an eye on. Drag to reorder."
        case .all: return "Every Claude Code and Cursor session AgentDeck can see."
        case .archived: return "Finished and idle agents you've put away. They come back by themselves if they start working again."
        case .project(let id): return Fmt.abbreviatePath(manager.project(id)?.path)
        default: return ""
        }
    }

    var body: some View {
        Group {
            if AppInfo.snapshotMode {
                // Layer snapshots cannot capture scroll-view content; lay out flat instead.
                content.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { content }.scrollIndicators(.automatic)
            }
        }
        .background(Theme.windowBackground)
        .onChange(of: ui.searchFocusRequest) { _, _ in searchFocused = true }
        .confirmationDialog("Archive \(finishedInView.count) finished or idle agent\(finishedInView.count == 1 ? "" : "s")?", isPresented: $confirmArchive) {
            Button("Archive") { manager.archive(finishedInView) }
        } message: {
            Text("Completed, not-running and idle agents in this view move to Archived. Pinned agents and anything working, waiting or failed stay. An archived agent comes back by itself when it starts working again. Nothing is deleted.")
        }
        .contentShape(Rectangle())
        .onTapGesture { ui.select(nil) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if ui.section == .overview { StatsRow(agents: scoped) }
            filterBar
            if filtered.isEmpty {
                emptyState.deckCard()
            } else {
                grid
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 28)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            SystemStatusBadge()
            NewAgentButton()
        }
        .padding(.top, 14)
    }

    private var filterBar: some View {
        @Bindable var ui = ui
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(StatusFilter.allCases) { f in
                    FilterChip(title: f.rawValue, count: scoped.filter { f.matches($0.status) }.count, selected: ui.filter == f) {
                        withAnimation(.easeOut(duration: 0.15)) { ui.filter = f }
                    }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search agents…", text: $ui.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { ui.search = ""; searchFocused = false }
                if !ui.search.isEmpty {
                    Button { ui.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(width: 260, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? Color(hex: manager.settings.accentHex).opacity(0.7) : Theme.border))
            Menu {
                Picker("Provider", selection: $ui.providerFilter) {
                    Text("All providers").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag(ProviderKind?.some($0)) }
                }
                Divider()
                Toggle("Show inactive sessions", isOn: Binding(get: { manager.settings.showInactive }, set: { manager.settings.showInactive = $0 }))
                Divider()
                if ui.section == .archived {
                    Button("Move all \(manager.archivedAgents.count) back to the dashboard") { manager.unarchiveAll() }
                        .disabled(manager.archivedAgents.isEmpty)
                } else {
                    Button("Archive \(finishedInView.count) finished or idle agent\(finishedInView.count == 1 ? "" : "s")…") { confirmArchive = true }
                        .disabled(finishedInView.isEmpty)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ui.providerFilter != nil ? Color(hex: manager.settings.accentHex) : Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 36)
            .help("Filter and view options")
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 16)], spacing: 16) {
            ForEach(AppInfo.snapshotMode ? Array(filtered.prefix(4)) : filtered) { agent in
                AgentCardView(agent: agent)
                    .id(agent.id)
                    .onDrag {
                        NSItemProvider(object: agent.id as NSString)
                    }
                    .onDrop(of: [UTType.plainText], delegate: PinDropDelegate(target: agent, manager: manager))
            }
        }
        .animation(.easeOut(duration: 0.2), value: filtered.map(\.id))
    }

    /// Finished or idle, unpinned agents currently shown: what the bulk archive acts on.
    private var finishedInView: [Agent] { filtered.filter { $0.status.isArchivable && !$0.isPinned } }

    @ViewBuilder private var emptyState: some View {
        if ui.section == .archived && ui.search.isEmpty {
            EmptyStateView(symbol: "archivebox", title: "Nothing archived",
                           message: "Archive finished or idle agents from their card menu (⌘⌫), or all at once from the filter menu.")
        } else if !ui.search.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No agents match “\(ui.search)”.")
        } else if ui.section == .pinned {
            EmptyStateView(symbol: "pin", title: "Nothing pinned yet", message: "Pin agents from their card or context menu to keep them here.")
        } else if manager.visibleAgents.isEmpty {
            VStack(spacing: 14) {
                EmptyStateView(symbol: "sparkles", title: "No agents yet",
                               message: "AgentDeck shows Claude Code and Cursor CLI sessions running on this Mac. Start one here or in your terminal.")
                Button("New agent") { ui.newAgent() }.buttonStyle(PrimaryButtonStyle()).padding(.bottom, 24)
            }
        } else {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "No \(ui.filter.rawValue.lowercased()) agents", message: "Try another filter.")
        }
    }
}

/// Reorders pinned agents by dropping one card onto another.
private struct PinDropDelegate: DropDelegate {
    var target: Agent
    var manager: AgentManager

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [UTType.plainText]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = obj as? String else { return }
            Task { @MainActor in
                guard id != target.id else { return }
                if !manager.pins.contains(id), let a = manager.agents[id] { manager.togglePin(a) }
                if !manager.pins.contains(target.id) { manager.movePin(id, before: manager.pins.first { manager.agents[$0] != nil && $0 != id }) }
                else { withAnimation { manager.movePin(id, before: target.id) } }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct FilterChip: View {
    var title: String
    var count: Int
    var selected: Bool
    var action: () -> Void
    @Environment(\.deckAccent) private var accent
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text("\(count)").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.2) : Theme.surfaceRaised))
            }
            .foregroundStyle(selected ? .white : Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent : (hover ? Theme.surfaceHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SystemStatusBadge: View {
    @Environment(AgentManager.self) private var manager
    var body: some View {
        let healthy = manager.isMonitoring && manager.adapterErrors.isEmpty
        let color = healthy ? Theme.green : Theme.amber
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
            Text(healthy ? "LOCAL SYSTEM ONLINE" : (manager.isMonitoring ? "DEGRADED" : "PAUSED"))
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Capsule().fill(color.opacity(0.1)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25)))
        .help(manager.adapterErrors.values.joined(separator: "\n").isEmpty ? "All integrations healthy" : manager.adapterErrors.values.joined(separator: "\n"))
        .padding(.trailing, 6)
    }
}

struct NewAgentButton: View {
    @Environment(UIState.self) private var ui
    @Environment(\.deckAccent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            Button { ui.newAgent() } label: {
                Label("New agent", systemImage: "plus").labelStyle(.titleAndIcon)
                    .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18)
            Menu {
                ForEach(ProviderKind.allCases) { p in
                    Button("New \(p.displayName) agent") { ui.newAgent(p) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 10)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [accent, accent.opacity(0.8)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: accent.opacity(0.4), radius: 12, y: 2)
    }
}

struct StatsRow: View {
    var agents: [Agent]
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui

    var body: some View {
        let active = agents.filter { $0.status == .working || $0.status == .idle }.count
        let waiting = agents.filter { $0.status.isWaiting }.count
        let completed = agents.filter { $0.status == .completed }.count
        let projects = Set(agents.compactMap(\.projectID)).count
        HStack(spacing: 14) {
            StatCard(value: active, label: "Active", symbol: "play.fill", color: Theme.green, sparkline: activitySeries()) { ui.filter = .active }
            StatCard(value: waiting, label: "Waiting", symbol: "pause.fill", color: Theme.amber) { ui.filter = .waiting }
            StatCard(value: completed, label: "Completed", symbol: "checkmark", color: Theme.green) { ui.filter = .completed }
            StatCard(value: projects, label: "Projects", symbol: "square.stack.3d.up.fill", color: Color(hex: manager.settings.accentHex)) { ui.section = .projects }
        }
    }

    /// Events per 30-minute bucket over the last 6 hours (real activity only).
    private func activitySeries() -> [Double] {
        let now = Date()
        var buckets = [Double](repeating: 0, count: 12)
        for e in manager.events {
            let age = now.timeIntervalSince(e.date)
            if age > 6 * 3600 { break }
            let idx = 11 - min(11, Int(age / 1800))
            buckets[idx] += 1
        }
        return buckets
    }
}

struct StatCard: View {
    var value: Int
    var label: String
    var symbol: String
    var color: Color
    var sparkline: [Double]? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(value)").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if let sparkline, sparkline.contains(where: { $0 > 0 }) {
                    Sparkline(values: sparkline, color: color).frame(width: 52, height: 24)
                        .help("Activity over the last 6 hours")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .deckCard(hovered: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut, value: value)
    }
}
