import SwiftUI

struct RootView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui

    private var selectedAgent: Agent? { ui.selection.flatMap { manager.agents[$0] } }
    private var showInspector: Bool {
        ui.section.showsAgents && selectedAgent != nil && manager.settings.inspectorVisible && !ui.inspectorCollapsed
    }

    var body: some View {
        @Bindable var ui = ui
        @Bindable var manager = manager
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 236)
                .background(Theme.sidebarBackground)
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView()
            }
            .background(Theme.windowBackground)
            if showInspector, let agent = selectedAgent {
                Rectangle().fill(Theme.divider).frame(width: 1)
                InspectorView(agent: agent)
                    .frame(width: 330)
                    .background(Theme.inspectorBackground)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showInspector)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 640)
        .environment(\.deckAccent, Color(hex: manager.settings.accentHex))
        .tint(Color(hex: manager.settings.accentHex))
        .sheet(isPresented: $ui.showNewAgent) {
            NewAgentSheet(initialProvider: ui.newAgentProvider)
        }
        .alert(item: $manager.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .overlay(alignment: .bottom) { ToastView() }
        .onChange(of: ui.selection) { _, new in
            if new != nil { ui.inspectorCollapsed = false }
        }
    }

    @ViewBuilder private var content: some View {
        switch ui.section {
        case .overview, .pinned, .all, .project, .archived:
            DashboardView()
        case .projects:
            ProjectsView()
        case .activity:
            ActivityView()
        case .settings:
            SettingsView(embedded: true)
        }
    }
}

struct ToastView: View {
    @Environment(AgentManager.self) private var manager
    var body: some View {
        if let toast = manager.toast {
            Text(toast)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.surfaceRaised))
                .overlay(Capsule().strokeBorder(Theme.borderStrong))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.bottom, 48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation { manager.toast = nil }
                }
        }
    }
}

struct StatusBarView: View {
    @Environment(AgentManager.self) private var manager

    var body: some View {
        let agents = manager.visibleAgents
        let ok = manager.isMonitoring && manager.adapterErrors.isEmpty
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(ok ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                Text(manager.isMonitoring ? (ok ? "Local monitoring active" : "Some integrations need attention") : "Monitoring paused")
            }
            Divider().frame(height: 12)
            Text("\(manager.monitoredCount) live sessions monitored")
            Spacer()
            ForEach(ProviderKind.allCases) { p in
                let mine = agents.filter { $0.provider == p }
                let live = mine.filter { $0.status.isLive }.count
                HStack(spacing: 5) {
                    ProviderIcon(provider: p, size: 14)
                    Text("\(p == .claudeCode ? "Claude" : "Cursor") \(mine.count)" + (live > 0 ? " · \(live) active" : ""))
                        .help("\(mine.count) \(p == .claudeCode ? "Claude Code" : "Cursor") agents shown, \(live) running or waiting")
                    if manager.adapterErrors[p] != nil || !(manager.formatWarnings[p] ?? []).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                            .help(([manager.adapterErrors[p]].compactMap { $0 } + (manager.formatWarnings[p] ?? [])).joined(separator: "\n"))
                    }
                }
            }
            Divider().frame(height: 12)
            Text("v\(AppInfo.version)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Theme.windowBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}
