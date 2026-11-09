import SwiftUI
import AppKit

struct NewAgentSheet: View {
    var initialProvider: ProviderKind
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @Environment(\.deckAccent) private var accent

    @State private var provider: ProviderKind = .claudeCode
    @State private var projectPath = ""
    @State private var prompt = ""
    @State private var title = ""
    @State private var model = ""
    @State private var mode: LaunchRequest.Mode = .app
    @State private var permissionMode = ""
    @State private var worktree = false
    @State private var models: [ModelOption] = []
    @State private var modes: [ModeOption] = []
    @State private var loadingModels = false
    @State private var launching = false
    @State private var error: String?

    private var health: ProviderHealth? { manager.health[provider] }
    private var providerReady: Bool {
        if mode == .app { return appReady == nil }
        return health?.state == .ok || health == nil
    }

    /// Why the desktop-app target can't be used right now, if it can't.
    private var appReady: String? {
        switch provider {
        case .claudeCode:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") == nil
                ? "The Claude desktop app is not installed." : nil
        case .cursor:
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: CursorAppChats.bundleID) == nil { return "Cursor is not installed." }
            return CursorAppChats.bridgeInstalled ? nil : "Install the AgentDeck Bridge extension (Settings → Integrations → Cursor) to start chats in the Cursor app."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New agent").font(.system(size: 20, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textSecondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step(1, "Provider") {
                        HStack(spacing: 10) {
                            ForEach(ProviderKind.allCases) { p in providerTile(p) }
                        }
                        if let h = health, h.state != .ok {
                            warning(h.message ?? "\(provider.displayName) is not ready.")
                        }
                    }
                    step(2, "Project") {
                        HStack(spacing: 8) {
                            Picker("", selection: $projectPath) {
                                Text("Choose a folder…").tag("")
                                ForEach(manager.projects.filter { !$0.isHidden }) { p in
                                    Text("\(p.name)  —  \(Fmt.abbreviatePath(p.path))").tag(p.path)
                                }
                                if !projectPath.isEmpty && !manager.projects.contains(where: { $0.path == projectPath }) {
                                    Text(Fmt.abbreviatePath(projectPath)).tag(projectPath)
                                }
                            }
                            .labelsHidden()
                            Button("Browse…") { browse() }.buttonStyle(SecondaryButtonStyle())
                        }
                        if !projectPath.isEmpty, let b = GitInfo.branch(at: projectPath) {
                            Label("Git repository · \(b)", systemImage: "arrow.triangle.branch").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    step(3, "Task") {
                        TextEditor(text: $prompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 96, maxHeight: 160)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                            .overlay(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("Describe what the agent should do…").font(.system(size: 13)).foregroundStyle(Theme.textTertiary).padding(14).allowsHitTesting(false)
                                }
                            }
                        TextField("Display name (optional)", text: $title).textFieldStyle(.roundedBorder)
                    }
                    if mode != .app { step(4, "Model") {
                        HStack {
                            Picker("", selection: $model) {
                                Text("Provider default").tag("")
                                ForEach(models) { m in Text(m.name == m.id ? m.id : "\(m.name)  (\(m.id))").tag(m.id) }
                            }
                            .labelsHidden()
                            if loadingModels { ProgressView().controlSize(.small) }
                        }
                        Text(provider == .claudeCode ? "Aliases come from your installed `claude --help`; full names are models seen in your recent sessions."
                                                     : "Models offered to your Cursor account (`cursor-agent models`).")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    } }
                    step(mode == .app ? 4 : 5, "Launch options") {
                        Picker("Run", selection: $mode) {
                            Text(provider == .claudeCode ? "In the Claude app" : "In the Cursor app").tag(LaunchRequest.Mode.app)
                            Text(provider == .claudeCode ? "Background (managed)" : "In AgentDeck via ACP (managed)").tag(LaunchRequest.Mode.managed)
                            Text("In terminal (interactive)").tag(LaunchRequest.Mode.terminal)
                        }
                        .pickerStyle(.radioGroup)
                        Text(modeExplanation).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if mode == .app, let why = appReady {
                            Text(why).font(.system(size: 11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        if !modes.isEmpty, !(mode == .app && provider == .claudeCode) {
                            Picker(provider == .claudeCode ? "Permission mode" : "Agent mode", selection: $permissionMode) {
                                Text("Default").tag("")
                                ForEach(modes) { m in Text(m.detail.isEmpty ? m.name : "\(m.name) — \(m.detail)").tag(m.id) }
                            }
                        }
                        if mode != .app, GitInfo.repo(containing: projectPath) != nil {
                            Toggle("Run in an isolated git worktree", isOn: $worktree)
                        }
                    }
                }
                .padding(.trailing, 6)
            }

            if let error {
                warning(error).padding(.top, 10)
            }
            commandPreview.padding(.top, 12)

            HStack {
                Label("Uses your existing \(provider.displayName) sign-in. No API keys.", systemImage: "lock.shield")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button { start() } label: {
                    HStack(spacing: 6) {
                        if launching { ProgressView().controlSize(.small).tint(.white) }
                        Text(launching ? "Starting…" : "Start agent")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 620, height: 720)
        .background(Theme.windowBackground)
        .onAppear {
            provider = initialProvider
            if case .project(let id) = ui.section, let p = manager.project(id) { projectPath = p.path }
            else if let sel = ui.selection.flatMap({ manager.agents[$0] }), let pid = sel.projectID, let p = manager.project(pid) { projectPath = p.path }
            loadOptions()
        }
        .onChange(of: provider) { _, _ in model = ""; permissionMode = ""; loadOptions() }
    }

    private var canStart: Bool {
        !launching && providerReady && !projectPath.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modeExplanation: String {
        switch (provider, mode) {
        case (.claudeCode, .app): return "Opens a new session in the Claude app with this folder and task filled in. You press Enter there to start it, with the model and permissions you choose in the app. Clicking it in AgentDeck opens that exact session."
        case (.cursor, .app): return "Starts a chat in the Cursor app window for this folder and submits the task, using the model selected in Cursor. Goes through the AgentDeck Bridge extension. Approvals can be answered from AgentDeck."
        case (.claudeCode, .managed): return "Runs `claude --bg`. AgentDeck can stop it, and you can attach to it in a terminal at any time. It keeps running if AgentDeck quits."
        case (.claudeCode, .terminal): return "Opens an interactive Claude Code session in your terminal. AgentDeck monitors it; stop it from the terminal."
        case (.cursor, .managed): return "Runs `cursor-agent acp` under AgentDeck: live status, plan progress and approvals here. Quitting AgentDeck ends the session (the chat is kept and can be resumed)."
        case (.cursor, .terminal): return "Opens an interactive Cursor Agent in your terminal. AgentDeck picks it up from Cursor's local chat store."
        }
    }

    private var request: LaunchRequest {
        LaunchRequest(provider: provider, workingDirectory: projectPath, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                      title: title.isEmpty ? nil : title, model: model.isEmpty ? nil : model, mode: mode,
                      permissionMode: permissionMode.isEmpty ? nil : permissionMode, worktree: worktree)
    }

    private var commandPreview: some View {
        let r = request
        let text: String
        switch (r.provider, r.mode) {
        case (.claudeCode, .app):
            text = "open \"claude://code/new?folder=\(Fmt.abbreviatePath(r.workingDirectory))&q=…\""
        case (.cursor, .app):
            text = "open \"cursor://agentdeck.agentdeck-bridge/new?mode=\(r.permissionMode == "ask" ? "chat" : (r.permissionMode ?? "agent"))&prompt=…\"   (in \(Fmt.abbreviatePath(r.workingDirectory)))"
        case (.claudeCode, _):
            var args = r.mode == .managed ? ["--bg"] : []
            if let t = r.title { args += ["-n", t] }
            if let m = r.model { args += ["--model", m] }
            if let p = r.permissionMode { args += ["--permission-mode", p] }
            if r.worktree { args += ["--worktree"] }
            args.append(r.prompt.isEmpty ? "<task>" : String(r.prompt.prefix(60)) + (r.prompt.count > 60 ? "…" : ""))
            text = TerminalLauncher.describe("claude", args, cwd: r.workingDirectory.isEmpty ? nil : r.workingDirectory)
        case (.cursor, .managed):
            text = "cursor-agent acp   → session/new, session/prompt (cwd: \(Fmt.abbreviatePath(r.workingDirectory)))"
        case (.cursor, .terminal):
            var args: [String] = []
            if let m = r.model { args += ["--model", m] }
            if let p = r.permissionMode, p != "agent" { args += ["--mode", p] }
            if r.worktree { args += ["--worktree"] }
            args += ["--workspace", r.workingDirectory, r.prompt.isEmpty ? "<task>" : String(r.prompt.prefix(60))]
            text = TerminalLauncher.describe("cursor-agent", args, cwd: nil)
        }
        return VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "Command")
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(2).textSelection(.enabled)
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    private func providerTile(_ p: ProviderKind) -> some View {
        let selected = provider == p
        let h = manager.health[p]
        return Button { provider = p } label: {
            HStack(spacing: 10) {
                ProviderIcon(provider: p, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(h.map { $0.state == .ok ? ($0.version.map { "v\($0)" } ?? "Ready") : "Unavailable" } ?? "Checking…")
                        .font(.system(size: 11)).foregroundStyle(h?.state == .ok ? Theme.textTertiary : Theme.amber)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .deckCard(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                    .frame(width: 20, height: 20).background(Circle().fill(accent.opacity(0.15)))
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            content()
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.amber.opacity(0.08)))
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            manager.addProject(path: url.path)
            projectPath = url.standardizedFileURL.path
        }
    }

    private func loadOptions() {
        let p = provider
        loadingModels = true
        Task {
            let a = manager.adapter(for: p)
            let m = await a.availableModels()
            guard p == provider else { return }
            models = m
            modes = a.launchModes()
            if p == .cursor, permissionMode.isEmpty { permissionMode = "" }
            if p == .claudeCode, permissionMode.isEmpty { permissionMode = manager.settings.defaultClaudePermissionMode }
            loadingModels = false
        }
    }

    private func start() {
        error = nil
        launching = true
        let r = request
        Task {
            do {
                let result = try await manager.launch(r)
                launching = false
                manager.toast = result.message ?? "\(r.provider.displayName) agent started"
                if let sid = result.sessionID { ui.selection = "\(r.provider.rawValue):\(sid)" }
                dismiss()
            } catch {
                launching = false
                self.error = error.localizedDescription
            }
        }
    }
}
