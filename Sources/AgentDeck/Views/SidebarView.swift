import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let visible = manager.visibleAgents
        VStack(alignment: .leading, spacing: 0) {
            // Leave room for the traffic lights (full-size content window).
            Color.clear.frame(height: 38)
            HStack(spacing: 10) {
                AppGlyph(size: 30)
                Text("AgentDeck").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)

            VStack(spacing: 3) {
                NavRow(symbol: "house", title: "Overview", section: .overview)
                NavRow(symbol: "pin", title: "Pinned", section: .pinned, count: manager.pins.filter { manager.agents[$0] != nil && !manager.hidden.contains($0) }.count)
                NavRow(symbol: "square.grid.2x2", title: "All agents", section: .all, count: visible.count)
                NavRow(symbol: "folder", title: "Projects", section: .projects)
                NavRow(symbol: "waveform.path.ecg", title: "Activity", section: .activity)
                NavRow(symbol: "archivebox", title: "Archived", section: .archived, count: manager.archivedAgents.count)
                NavRow(symbol: "gearshape", title: "Settings", section: .settings)
            }
            .padding(.horizontal, 12)

            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 18).padding(.vertical, 16)

            SectionLabel(text: "Projects").padding(.horizontal, 20).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(manager.sidebarProjects) { p in
                        ProjectRow(project: p, active: manager.activeCount(in: p))
                    }
                    Button { addProject() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 14)
                            Text("Add project").font(.system(size: 13))
                            Spacer()
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
            }
            Spacer(minLength: 8)
            MachineCard().padding(12)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        panel.message = "Choose one or more project folders. Git repositories are detected automatically."
        if panel.runModal() == .OK {
            for url in panel.urls { manager.addProject(path: url.path) }
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat
    @Environment(\.deckAccent) private var accent
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.62, height: size * 0.62)
                    .rotationEffect(.degrees(45))
                    .scaleEffect(x: 1, y: 0.62)
                    .offset(y: CGFloat(i - 1) * size * 0.16)
                    .opacity(1 - Double(i) * 0.25)
                    .zIndex(Double(3 - i))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct NavRow: View {
    var symbol: String
    var title: String
    var section: SidebarSection
    var count: Int? = nil
    @Environment(UIState.self) private var ui
    @Environment(\.deckAccent) private var accent
    @State private var hover = false

    var body: some View {
        let selected = ui.section == section
        Button { ui.section = section } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Theme.surfaceRaised))
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? accent.opacity(0.28) : (hover ? Theme.surfaceHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ProjectRow: View {
    var project: Project
    var active: Int
    @Environment(UIState.self) private var ui
    @Environment(AgentManager.self) private var manager
    @Environment(\.deckAccent) private var accent
    @State private var hover = false

    var body: some View {
        let selected = ui.section == .project(project.id)
        Button { ui.section = .project(project.id) } label: {
            HStack(spacing: 10) {
                ProjectDot(hex: project.colorHex, size: 10).frame(width: 14)
                Text(project.name).font(.system(size: 13)).lineLimit(1)
                Spacer()
                if active > 0 {
                    Text("\(active)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.green)
                        .help("\(active) live agents")
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.opacity(0.2) : (hover ? Theme.surfaceHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            Button("New agent here…") { ui.section = .project(project.id); ui.newAgent() }
            Divider()
            Button("Hide from sidebar") { manager.removeProject(project) }
        }
    }
}

private struct MachineCard: View {
    @Environment(AgentManager.self) private var manager
    var body: some View {
        let ok = manager.isMonitoring && manager.adapterErrors.isEmpty
        HStack(spacing: 11) {
            Image(systemName: "laptopcomputer").font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Host.current().localizedName ?? "This Mac").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(ok ? Theme.green : Theme.amber).frame(width: 6, height: 6)
                    Text("\(manager.monitoredCount) agents running").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
    }
}
