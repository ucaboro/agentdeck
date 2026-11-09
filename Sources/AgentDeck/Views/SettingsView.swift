import SwiftUI
import AppKit

struct SettingsView: View {
    var embedded = false
    @Environment(AgentManager.self) private var manager
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if embedded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Integrations, appearance and monitoring.").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 14)
            }
            Picker("", selection: $tab) {
                Text("Integrations").tag(0)
                Text("Appearance").tag(1)
                Text("Monitoring").tag(2)
                Text("General").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, embedded ? 28 : 20)
            .padding(.top, embedded ? 0 : 20)
            ScrollView {
                Group {
                    switch tab {
                    case 0: IntegrationsSettings()
                    case 1: AppearanceSettings()
                    case 2: MonitoringSettings()
                    default: GeneralSettings()
                    }
                }
                .padding(.horizontal, embedded ? 28 : 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: embedded ? nil : 640, minHeight: embedded ? nil : 520)
        .background(Theme.windowBackground)
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deckCard()
            if let footer { Text(footer).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 14)
    }
}

private struct IntegrationsSettings: View {
    @Environment(AgentManager.self) private var manager
    @State private var refreshing = false
    @State private var hooksInstalled = false
    @State private var bridgeInstalled = CursorAppChats.bridgeInstalled
    @State private var bridgeBusy = false
    @State private var bridgeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ProviderKind.allCases) { p in
                SettingsGroup(title: p.displayName, footer: footer(p)) {
                    ProviderHealthView(provider: p, health: manager.health[p], error: manager.adapterErrors[p], lastRefresh: manager.lastRefresh[p])
                    ForEach(manager.formatWarnings[p] ?? [], id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    if p == .claudeCode {
                        Divider()
                        Toggle(isOn: Binding(get: { hooksInstalled }, set: { v in manager.setClaudeHooks(v); hooksInstalled = manager.claudeHooksInstalled })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Show when Claude is waiting for you (Claude Code hooks)").font(.system(size: 13, weight: .medium))
                                Text("Needed for \u{201C}waiting for approval\u{201D}, \u{201C}waiting for input\u{201D} and their notifications on Claude sessions. Adds a relay hook to ~/.claude/settings.json (a backup is saved first). The hook only writes a local file and always exits 0, so it can't approve or block anything. Turning this off removes exactly those entries.")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    if p == .cursor {
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("AgentDeck Bridge for Cursor").font(.system(size: 13, weight: .medium))
                                Text("A small Cursor extension that lets AgentDeck open the exact chat, answer approvals and start chats in the Cursor app. Approving and starting chats need a secret only AgentDeck has. No network access. Without it, Open in Cursor only brings the right window forward. The first time, Cursor asks whether to allow AgentDeck's links.")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                                if let bridgeError {
                                    Text(bridgeError).font(.system(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            if bridgeInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.green)
                            } else {
                                Button(bridgeBusy ? "Installing…" : "Install") {
                                    bridgeBusy = true; bridgeError = nil
                                    Task {
                                        do { try await CursorAppChats.installBridge() } catch { bridgeError = error.localizedDescription }
                                        bridgeInstalled = CursorAppChats.bridgeInstalled; bridgeBusy = false
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle()).disabled(bridgeBusy)
                            }
                        }
                    }
                }
            }
            HStack {
                Button {
                    refreshing = true
                    Task { await manager.refreshHealth(); manager.refreshAll(); refreshing = false }
                } label: { Label(refreshing ? "Checking…" : "Re-check integrations", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(refreshing)
                Spacer()
            }
            .padding(.bottom, 18)
            SettingsGroup(title: "Known limitations") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Cursor app chats are read from Cursor's internal local state, read-only; a Cursor update may change it. Cursor does not save “running”, so it is inferred from live message activity and can lag about 90 seconds after a run ends.")
                    bullet("Opening the exact Cursor chat needs the AgentDeck Bridge extension (above). Without it, Open in Cursor brings the right window forward.")
                    bullet("Cursor CLI chats started in a terminal expose no model or live state; AgentDeck infers “running” from cursor-agent processes in the same folder.")
                    bullet("Interactive Claude Code sessions belong to their terminal or the Claude app: AgentDeck can focus that app but cannot stop them. Background sessions (`claude --bg`) can be stopped.")
                    bullet("Claude model, title and branch are read best-effort from local transcripts, which are not a stable API.")
                    bullet("ACP agents run as child processes of AgentDeck and end when it quits; their chats stay resumable.")
                }
            }
        }
        .onAppear { hooksInstalled = manager.claudeHooksInstalled; bridgeInstalled = CursorAppChats.bridgeInstalled }
    }

    private func footer(_ p: ProviderKind) -> String {
        p == .claudeCode
            ? "Uses `claude agents --json`, `claude --bg`, `claude stop/attach/--resume` and your claude.ai sign-in."
            : "Uses `cursor-agent acp` (Agent Client Protocol), `cursor-agent --resume` and your Cursor sign-in."
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(Theme.textTertiary)
            Text(s).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderHealthView: View {
    var provider: ProviderKind
    var health: ProviderHealth?
    var error: String?
    var lastRefresh: Date?

    var body: some View {
        let state = health?.state ?? .unknown
        let color: Color = state == .ok && error == nil ? Theme.green : (state == .unknown ? Theme.grey : Theme.amber)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLabel(state)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    if let m = health?.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("CLI", health?.executablePath.map(Fmt.abbreviatePath) ?? "Not found")
                row("Version", health?.version ?? "—")
                row("Account", health?.account?.isEmpty == false ? health!.account! : "—")
                row("Desktop app", health?.appInstalled == true ? "Installed" : "Not found")
                row("Last sync", lastRefresh.map { Fmt.relative($0) } ?? "—")
                if let error { row("Error", error) }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Text(v).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).textSelection(.enabled).lineLimit(2)
        }
    }

    private func stateLabel(_ s: ProviderHealth.State) -> String {
        switch s {
        case .ok: return error == nil ? "Connected" : "Connected — discovery error"
        case .notInstalled: return "Not installed"
        case .notAuthenticated: return "Not signed in"
        case .error: return "Error"
        case .unknown: return "Checking…"
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AgentManager.self) private var manager
    static let accents = ["8B5CF6", "6366F1", "3B82F6", "14B8A6", "22C55E", "F59E0B", "EC4899", "EF4444"]

    var body: some View {
        @Bindable var manager = manager
        SettingsGroup(title: "Theme") {
            Picker("Appearance", selection: $manager.settings.appearance) {
                Text("System").tag(AppSettings.Appearance.system)
                Text("Dark").tag(AppSettings.Appearance.dark)
                Text("Light").tag(AppSettings.Appearance.light)
            }
            .pickerStyle(.segmented).frame(maxWidth: 320)
            HStack(spacing: 10) {
                Text("Accent").font(.system(size: 13))
                ForEach(Self.accents, id: \.self) { c in
                    Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: manager.settings.accentHex == c ? 2 : 0))
                        .onTapGesture { manager.settings.accentHex = c }
                        .accessibilityLabel("Accent \(c)")
                }
            }
        }
        SettingsGroup(title: "Layout") {
            Toggle("Show inspector when an agent is selected", isOn: $manager.settings.inspectorVisible)
            Toggle("Show inactive (resumable) sessions on the dashboard", isOn: $manager.settings.showInactive)
        }
    }
}

private struct MonitoringSettings: View {
    @Environment(AgentManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        SettingsGroup(title: "Discovery", footer: "File changes trigger refreshes immediately (FSEvents). The interval is only a fallback for state with no file activity, such as busy → idle.") {
            Toggle("Discover Claude Code sessions", isOn: $manager.settings.discoverClaude)
            Toggle("Discover Cursor chats (app and CLI)", isOn: $manager.settings.discoverCursor)
            HStack {
                Text("Fallback refresh every")
                Picker("", selection: $manager.settings.refreshInterval) {
                    ForEach([2.0, 3, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }.labelsHidden().frame(width: 90)
            }
            HStack {
                Text("Include inactive sessions from the last")
                Picker("", selection: $manager.settings.historyDays) {
                    Text("12 hours").tag(0.5)
                    Text("1 day").tag(1.0)
                    Text("2 days").tag(2.0)
                    Text("7 days").tag(7.0)
                    Text("30 days").tag(30.0)
                }.labelsHidden().frame(width: 110)
            }
            HStack {
                Text("Archive finished and idle agents automatically after")
                Picker("", selection: $manager.settings.autoArchiveHours) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(1.0)
                    Text("4 hours").tag(4.0)
                    Text("1 day").tag(24.0)
                }.labelsHidden().frame(width: 110)
            }
            Text("Completed, not-running and idle agents with no activity for that long move to Archived. Pinned, failed and waiting agents stay. Anything that starts working or needs you again comes back.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        SettingsGroup(title: "Notifications") {
            Toggle("Agent needs approval or input", isOn: $manager.settings.notifyOnWaiting)
            Toggle("Agent completed", isOn: $manager.settings.notifyOnCompleted)
            Toggle("Agent failed", isOn: $manager.settings.notifyOnFailed)
            Picker("Remind me if an agent is still waiting after", selection: $manager.settings.remindWaitingMinutes) {
                Text("Never").tag(0.0)
                Text("5 minutes").tag(5.0)
                Text("10 minutes").tag(10.0)
                Text("30 minutes").tag(30.0)
            }
            .disabled(!manager.settings.notifyOnWaiting)
            Picker("Clicking a notification", selection: $manager.settings.notificationOpensAgent) {
                Text("Opens the agent in its app").tag(true)
                Text("Shows it in AgentDeck").tag(false)
            }
            Text("Cursor approval notifications include Accept and Reject buttons when the AgentDeck Bridge is installed.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 14) {
                Button("Send a test notification") {
                    manager.notifier.post(title: "AgentDeck test", body: "Notifications are working.", agentID: "test")
                }
                Button("Open macOS notification settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }.buttonStyle(.link)
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AgentManager.self) private var manager
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var manager = manager
        SettingsGroup(title: "Startup") {
            Toggle("Launch AgentDeck at login", isOn: Binding(get: { launchAtLogin }, set: { v in
                do { try LaunchAtLogin.set(v); launchAtLogin = LaunchAtLogin.isEnabled }
                catch { manager.alert = .init(title: "Launch at login", message: error.localizedDescription) }
            }))
            Toggle("Start monitoring when AgentDeck opens", isOn: $manager.settings.startMonitoringOnLaunch)
            Toggle("⌥⌘K opens the agent switcher from any app", isOn: $manager.settings.globalHotkeyEnabled)
        }
        SettingsGroup(title: "When the window closes") {
            Picker("", selection: $manager.settings.closeBehaviour) {
                ForEach(AppSettings.CloseBehaviour.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.radioGroup).labelsHidden()
            Text("Closing AgentDeck never stops Claude Code sessions or Cursor terminal agents.").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        }
        SettingsGroup(title: "Terminal", footer: "Used for resuming sessions, attaching to background agents and interactive launches.") {
            Picker("Open sessions in", selection: $manager.settings.terminalBundleID) {
                ForEach(TerminalLauncher.installedTerminals(), id: \.id) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 300)
        }
        SettingsGroup(title: "Defaults for new agents") {
            Picker("Claude Code permission mode", selection: $manager.settings.defaultClaudePermissionMode) {
                Text("Claude's configured default").tag("")
                ForEach(manager.claude.launchModes()) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 420)
        }
        SettingsGroup(title: "Data", footer: "AgentDeck stores metadata only (no credentials, no conversation content) in ~/Library/Application Support/AgentDeck. No telemetry is sent anywhere.") {
            HStack {
                Button("Show data folder") { NSWorkspace.shared.open(Persistence.supportDirectory) }.buttonStyle(SecondaryButtonStyle())
                if !manager.hidden.isEmpty { Button("Unarchive \(manager.hidden.count) agents") { manager.unarchiveAll() }.buttonStyle(SecondaryButtonStyle()) }
            }
        }
    }
}
