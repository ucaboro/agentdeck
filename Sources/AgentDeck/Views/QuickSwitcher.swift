import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Spotlight-style panel to jump to any agent: type, then Return opens it where it lives (Claude app,
/// Cursor, terminal) and ⌘Return shows it in AgentDeck. Opened with ⌘K in AgentDeck, or ⌥⌘K from any
/// app when the global shortcut is enabled.
@MainActor
final class QuickSwitcher {
    static let shared = QuickSwitcher()

    private var panel: SwitcherPanel?
    private weak var manager: AgentManager?
    private weak var ui: UIState?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func configure(manager: AgentManager, ui: UIState) {
        self.manager = manager
        self.ui = ui
        setGlobalHotKey(manager.settings.globalHotkeyEnabled)
    }

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    func show() {
        guard let manager, let ui else { return }
        let p = panel ?? makePanel()
        panel = p
        let root = QuickSwitcherView(onClose: { [weak self] in self?.close() })
            .environment(manager)
            .environment(ui)
            .preferredColorScheme(manager.settings.appearance == .light ? .light : manager.settings.appearance == .dark ? .dark : nil)
        p.contentView = NSHostingView(rootView: root)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - 320, y: f.maxY - f.height * 0.22 - 420, width: 640, height: 420), display: true)
        }
        // Non-activating: typing goes to the panel without pulling AgentDeck's main window forward.
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> SwitcherPanel {
        let p = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onResignKey = { [weak self] in self?.close() }
        return p
    }

    // MARK: Global hot key (⌥⌘K). Carbon hot keys need no Accessibility permission.

    func setGlobalHotKey(_ enabled: Bool) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        guard enabled else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickSwitcher.shared.toggle() } }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4144_4B53), id: 1) // "ADKS"
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

final class SwitcherPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResignKey?() }
}

struct QuickSwitcherView: View {
    @Environment(AgentManager.self) private var manager
    @Environment(UIState.self) private var ui
    var onClose: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [Agent] {
        let all = manager.sorted(manager.visibleAgents)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(all.prefix(50)) }
        let terms = q.split(separator: " ").map(String.init)
        return all.compactMap { a -> (Agent, Int)? in
            let hay = [a.title, manager.project(a.projectID)?.name ?? "", a.gitBranch ?? "", a.provider.displayName,
                       a.status.label, a.model ?? "", a.kindLabel ?? ""].joined(separator: " ").lowercased()
            guard terms.allSatisfy({ hay.contains($0) }) else { return nil }
            // Title prefix matches first, then title contains, then anything.
            let t = a.title.lowercased()
            let score = t.hasPrefix(terms[0]) ? 0 : (t.contains(terms[0]) ? 1 : 2)
            return (a, score)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(50).map(\.0)
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Jump to an agent…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { open(list, inDeck: NSEvent.modifierFlags.contains(.command)) }
                Text("⌥⌘K").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 18).frame(height: 56)
            Divider()
            if list.isEmpty {
                Text(query.isEmpty ? "No agents yet" : "No agents match “\(query)”")
                    .foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                row(a, selected: i == index)
                                    .id(a.id)
                                    .onTapGesture { index = i; open(list, inDeck: false) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: index) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↩", "Open where it runs")
                hint("⌘↩", "Show in AgentDeck")
                hint("↑↓", "Move")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 30)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { focused = true; index = 0 }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ a: Agent, selected: Bool) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: a.provider, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let p = manager.project(a.projectID) { ProjectDot(hex: p.colorHex, size: 7); Text(p.name) }
                    if let b = a.gitBranch { Text("· \(b)").lineLimit(1) }
                    Text("· \(a.focusLabel)")
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            StatusPill(status: a.status, compact: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.surfaceHover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.borderStrong : .clear))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            Text(text)
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
    }

    private func open(_ list: [Agent], inDeck: Bool) {
        guard list.indices.contains(index) else { return }
        let a = list[index]
        onClose()
        if inDeck || a.capabilities.isDisjoint(with: [.focus, .resume]) {
            AppDelegate.showInDeck(a.id)
        } else {
            manager.perform(.focus, on: a)
        }
    }
}
