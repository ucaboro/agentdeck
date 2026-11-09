import SwiftUI
import AppKit
import UserNotifications

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var manager: AgentManager
    @State private var ui: UIState
    @Environment(\.openWindow) private var openWindow

    init() {
        let m = AgentManager()
        let u = UIState()
        _manager = State(initialValue: m)
        _ui = State(initialValue: u)
        AppDelegate.manager = m
        AppDelegate.ui = u
    }

    var body: some Scene {
        Window("AgentDeck", id: "main") {
            RootView()
                .environment(manager)
                .environment(ui)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    applyAppearance()
                    if manager.settings.startMonitoringOnLaunch { manager.startMonitoring() }
                }
                .onChange(of: manager.settings.appearance) { _, _ in applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1480, height: 940)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(manager: manager, ui: ui) }

        Settings {
            SettingsView()
                .environment(manager)
                .environment(ui)
                .environment(\.deckAccent, Color(hex: manager.settings.accentHex))
                .preferredColorScheme(colorScheme)
        }

        MenuBarExtra {
            MenuBarContent().environment(manager).environment(ui)
        } label: {
            let waiting = manager.visibleAgents.filter { $0.status.isWaiting }.count
            Image(systemName: waiting > 0 ? "square.stack.3d.up.badge.automatic.fill" : "square.stack.3d.up.fill")
        }
    }

    private var colorScheme: ColorScheme? {
        switch manager.settings.appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    private func applyAppearance() {
        switch manager.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}

struct AppCommands: Commands {
    var manager: AgentManager
    var ui: UIState
    @Environment(\.openWindow) private var openWindow

    private var selected: Agent? { ui.selection.flatMap { manager.agents[$0] } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent…") { showMain(); ui.newAgent() }.keyboardShortcut("n")
            Button("Add Project…") { showMain(); ui.section = .projects }.keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            Button("Search Agents") {
                showMain()
                if !ui.section.showsAgents { ui.section = .all }
                ui.searchFocusRequest += 1
            }.keyboardShortcut("f")
            Button("Jump to Agent…") { QuickSwitcher.shared.toggle() }.keyboardShortcut("k")
        }
        CommandMenu("Go") {
            Button("Overview") { showMain(); ui.section = .overview }.keyboardShortcut("1")
            Button("Pinned") { showMain(); ui.section = .pinned }.keyboardShortcut("2")
            Button("Projects") { showMain(); ui.section = .projects }.keyboardShortcut("3")
            Button("Activity") { showMain(); ui.section = .activity }.keyboardShortcut("4")
            Button("Archived") { showMain(); ui.section = .archived }.keyboardShortcut("5")
            Button("All Agents") { showMain(); ui.section = .all }.keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Needs Attention") { showMain(); ui.section = .all; ui.filter = .waiting }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Agent") {
            Button(selected?.focusLabel ?? "Focus") { if let a = selected { manager.perform(.focus, on: a) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selected?.capabilities.isDisjoint(with: [.focus, .resume]) ?? true)
            Button("Resume in Terminal") { if let a = selected { manager.perform(.resume, on: a) } }
                .disabled(!(selected?.capabilities.contains(.resume) ?? false))
            Button(selected?.isPinned == true ? "Unpin" : "Pin") { if let a = selected { manager.togglePin(a) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(selected == nil)
            Divider()
            Button("Interrupt") { if let a = selected { manager.perform(.interrupt, on: a) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(selected?.capabilities.contains(.interrupt) ?? false))
            Button("Stop Agent") { if let a = selected { manager.perform(.stop, on: a) } }
                .disabled(!(selected?.capabilities.contains(.stop) ?? false))
            Button(selected.map { manager.isArchived($0) } == true ? "Move Back to Dashboard" : "Archive") {
                guard let a = selected else { return }
                if manager.isArchived(a) { manager.unarchive(a) } else { manager.archive(a); ui.select(nil) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected == nil || (selected?.status.isArchivable == false && selected.map { !manager.isArchived($0) } == true))
            Divider()
            Button("Refresh") { manager.refreshAll(); Task { await manager.refreshHealth() } }.keyboardShortcut("r")
            Button(manager.isMonitoring ? "Pause Monitoring" : "Start Monitoring") {
                manager.isMonitoring ? manager.stopMonitoring() : manager.startMonitoring()
            }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") {
                if ui.selection == nil { return }
                ui.inspectorCollapsed.toggle()
            }.keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct MenuBarContent: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let attention = manager.sorted(manager.visibleAgents.filter { $0.status.needsAttention })
        let working = manager.sorted(manager.visibleAgents.filter { $0.status == .working })
        if attention.isEmpty && working.isEmpty { Text("No agents need attention") }
        if !attention.isEmpty {
            Section("Needs attention") { ForEach(attention.prefix(8)) { a in item(a) } }
        }
        if !working.isEmpty {
            Section("Working") { ForEach(working.prefix(8)) { a in item(a) } }
        }
        Divider()
        Button("Jump to Agent…  ⌥⌘K") { QuickSwitcher.shared.show() }
        Button("Open AgentDeck") { open(nil) }
        Button("New Agent…") { open(nil); ui.newAgent() }
        Divider()
        Button("Quit AgentDeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func item(_ a: Agent) -> some View {
        Button("\(a.provider == .claudeCode ? "✳︎" : "◆") \(a.title) — \(a.status.label)") { open(a.id) }
    }

    private func open(_ id: String?) {
        openWindow(id: "main")
        NSApp.activate()
        if let id { ui.section = .all; ui.filter = .all; ui.select(id) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var manager: AgentManager?
    @MainActor static var ui: UIState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppInfo.isBundled { UNUserNotificationCenter.current().delegate = self }
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            if let m = Self.manager, let u = Self.ui { QuickSwitcher.shared.configure(manager: m, ui: u) }
        }
        let args = CommandLine.arguments
        // Development aid: `--dev-launch <claude|cursor> <dir> <permissionMode> <prompt>` exercises the
        // same launch path as the New Agent sheet (managed mode).
        if let i = args.firstIndex(of: "--dev-launch"), i + 4 < args.count {
            let provider = ProviderKind(rawValue: args[i + 1]) ?? .claudeCode
            let req = LaunchRequest(provider: provider, workingDirectory: args[i + 2], prompt: args[i + 4], title: "AgentDeck self-test",
                                    model: provider == .claudeCode ? "haiku" : nil, mode: .managed, permissionMode: args[i + 3])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { @MainActor in
                    guard let m = Self.manager else { return }
                    do { let r = try await m.launch(req); debugLog("dev-launch ok: \(r.commandDescription) session=\(r.sessionID ?? "-") handle=\(r.handle ?? "-")") }
                    catch { debugLog("dev-launch failed: \(error.localizedDescription)") }
                }
            }
        }
        // Development aid: `--snapshot <png> [delaySeconds]` renders the main window to a PNG.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            let delay = i + 2 < args.count ? Double(args[i + 2]) ?? 6 : 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1.5) {
                MainActor.assumeIsolated {
                    if let m = Self.manager, let ui = Self.ui {
                        if let sec = ProcessInfo.processInfo.environment["AGENTDECK_SECTION"] {
                            ui.section = ["activity": .activity, "projects": .projects, "settings": .settings, "all": .all][sec] ?? .overview
                        }
                        ui.selection = m.sorted(m.visibleAgents).first?.id
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                      let view = window.contentView else { return }
                view.wantsLayer = true
                guard let layer = view.layer else { return }
                let scale = window.backingScaleFactor
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.scaleBy(x: scale, y: scale)
                if !view.isFlipped { } else { ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                guard let img = ctx.makeImage() else { return }
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.manager?.settings.closeBehaviour == .quit
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = Self.manager else { return .terminateNow }
        let live = m.cursor.liveManagedCount()
        if live > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit AgentDeck?"
            alert.informativeText = "\(live) Cursor agent\(live == 1 ? " is" : "s are") running inside AgentDeck via ACP and will stop. Their chats are kept and can be resumed from the terminal. Claude Code sessions are not affected."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        m.shutdown()
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["agentID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let m = Self.manager else { return }
            if let id, action == Notifier.actionAccept || action == Notifier.actionReject {
                // An explicit click on Accept / Reject in the notification.
                m.decideFromNotification(agentID: id, accept: action == Notifier.actionAccept)
                return
            }
            // Default click: open the agent where it lives (setting), or show it in AgentDeck.
            if action == UNNotificationDefaultActionIdentifier, m.settings.notificationOpensAgent,
               let id, let a = m.agents[id], !a.capabilities.isDisjoint(with: [.focus, .resume]) {
                m.perform(.focus, on: a)
                return
            }
            Self.showInDeck(id)
        }
    }

    @MainActor
    static func showInDeck(_ id: String?) {
        NSApp.activate()
        for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true { w.makeKeyAndOrderFront(nil) }
        if let id, let ui { ui.section = .all; ui.filter = .all; ui.select(id) }
    }
}
