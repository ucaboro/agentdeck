import SwiftUI
import AppKit

struct ProjectsView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @State private var editing: Project?

    var body: some View {
        let projects = manager.projects.filter { !$0.isHidden }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Projects").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Text("Workspaces are detected from agent directories (git worktrees are grouped with their repository).")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { addProject() } label: { Label("Add project", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 14)

                if projects.isEmpty {
                    EmptyStateView(symbol: "folder.badge.plus", title: "No projects", message: "Add a local folder, or start an agent and its project appears automatically.").deckCard()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(projects) { p in ProjectCard(project: p) { editing = p } }
                }
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
        }
        .sheet(item: $editing) { p in ProjectEditor(project: p) }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        if panel.runModal() == .OK { for url in panel.urls { manager.addProject(path: url.path) } }
    }
}

private struct ProjectCard: View {
    var project: Project
    var edit: () -> Void
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @State private var hover = false

    var body: some View {
        let agents = manager.visibleAgents.filter { $0.projectID == project.id }
        let live = agents.filter { $0.status.isLive }.count
        let waiting = agents.filter { $0.status.isWaiting }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: project.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: project.colorHex))
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: project.colorHex).opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(Fmt.abbreviatePath(project.path)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                IconButton(symbol: "pencil", help: "Edit project", action: edit)
            }
            HStack(spacing: 14) {
                metric("\(live)", "live", Theme.green)
                metric("\(waiting)", "waiting", Theme.amber)
                metric("\(agents.count)", "total", Theme.textSecondary)
                Spacer()
                if project.isGitRepository, let b = GitInfo.branch(at: project.path) {
                    Label(b, systemImage: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
        }
        .padding(16)
        .deckCard(hovered: hover)
        .onHover { hover = $0 }
        .onTapGesture { ui.section = .project(project.id) }
        .contextMenu {
            Button("View agents") { ui.section = .project(project.id) }
            Button("New agent here…") { ui.section = .project(project.id); ui.newAgent() }
            Button("Edit…", action: edit)
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            Divider()
            Button("Hide project") { manager.removeProject(project) }
        }
    }

    private func metric(_ v: String, _ l: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Text(v).font(.system(size: 13, weight: .bold)).foregroundStyle(c)
            Text(l).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct ProjectEditor: View {
    @State var project: Project
    @Environment(AgentManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    static let colors = ["8B5CF6", "22C55E", "3B82F6", "F59E0B", "EC4899", "14B8A6", "EF4444", "A855F7", "06B6D4", "84CC16", "F97316", "94A3B8"]
    static let symbols = ["folder", "house", "hammer", "shippingbox", "iphone", "globe", "server.rack", "brain", "paintbrush", "book", "flask", "gamecontroller"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit project").font(.system(size: 18, weight: .bold))
            TextField("Name", text: $project.name).textFieldStyle(.roundedBorder)
            Text(Fmt.abbreviatePath(project.path)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            Text("Colour").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(Self.colors, id: \.self) { c in
                    Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: project.colorHex == c ? 2 : 0))
                        .onTapGesture { project.colorHex = c }
                }
            }
            Text("Icon").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(Self.symbols, id: \.self) { s in
                    Image(systemName: s).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(project.symbol == s ? Color(hex: project.colorHex).opacity(0.3) : Theme.surfaceRaised))
                        .onTapGesture { project.symbol = s }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { manager.update(project); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
