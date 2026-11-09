import SwiftUI
import Observation

/// Central registry and orchestration engine. Owns adapters, merges their
/// snapshots into one list, derives lifecycle events from state transitions,
/// persists everything, and drives notifications. All UI reads from here.
@MainActor
@Observable
final class AgentManager {
    // MARK: Published state
    private(set) var agents: [String: Agent] = [:]
    private(set) var projects: [Project] = []
    private(set) var events: [AgentEvent] = []
    private(set) var pins: [String] = []
    private(set) var hidden: Set<String> = []
    private(set) var health: [ProviderKind: ProviderHealth] = [:]
    private(set) var adapterErrors: [ProviderKind: String] = [:]
    /// Undocumented provider formats that stopped matching (shown in Settings and the status bar).
    private(set) var formatWarnings: [ProviderKind: [String]] = [:]
    private(set) var lastRefresh: [ProviderKind: Date] = [:]
    private(set) var isMonitoring = false
    var alert: AlertItem?
    var toast: String?
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persistence.save(settings)
            prefs.terminalBundleID = settings.terminalBundleID
            if settings.refreshInterval != oldValue.refreshInterval { restartPolling() }
            if settings.globalHotkeyEnabled != oldValue.globalHotkeyEnabled { QuickSwitcher.shared.setGlobalHotKey(settings.globalHotkeyEnabled) }
            if settings.historyDays != oldValue.historyDays || settings.discoverClaude != oldValue.discoverClaude
                || settings.discoverCursor != oldValue.discoverCursor { refreshAll() }
        }
    }

    struct AlertItem: Identifiable { let id = UUID(); var title: String; var message: String }

    // MARK: Internals
    let persistence: Persistence
    let prefs = AdapterPreferences()
    let claude: ClaudeAdapter
    let cursor: CursorAdapter
    var adapters: [AgentAdapter] { [claude, cursor] }
    private var watchers: [FileWatcher] = []
    private var pollTask: Task<Void, Never>?
    private var refreshTasks: [ProviderKind: Task<Void, Never>] = [:]
    private var refreshPending: Set<ProviderKind> = []
    private var managedIDs: Set<String> = []
    private var managedHandles: Set<String> = []
    private var knownIDs: Set<String> = []
    private var initialSnapshotDone: Set<ProviderKind> = []
    /// Agent id → the waitingSince value we already sent a reminder for.
    private var reminded: [String: Date] = [:]
    let notifier = Notifier()

    init() {
        let p: Persistence
        do { p = try Persistence() } catch { fatalError("AgentDeck could not open its database: \(error)") }
        persistence = p
        settings = p.loadSettings()
        claude = ClaudeAdapter(prefs: prefs)
        cursor = CursorAdapter(prefs: prefs)
        prefs.terminalBundleID = settings.terminalBundleID
        projects = p.loadProjects()
        pins = p.loadPins()
        hidden = p.loadHidden()
        events = p.loadEvents()
        if let data = p.value("managedIDs")?.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) { managedIDs = Set(ids) }
        if let data = p.value("managedHandles")?.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) { managedHandles = Set(ids) }
        // Last-known agents: the dashboard is populated immediately, then reconciled with live data.
        for var a in p.loadAgents() {
            a.capabilities = a.status.isLive ? [] : [.resume, .focus]
            if a.status.isLive { a.status = .unknown; a.statusDetail = "Checking…" }
            a.projectID = projectID(for: a.workingDirectory, create: false)
            a.isPinned = pins.contains(a.id)
            agents[a.id] = a
            knownIDs.insert(a.id)
        }
    }

    // MARK: Lifecycle

    func startMonitoring() {
        debugLog("startMonitoring")
        guard !isMonitoring else { return }
        isMonitoring = true
        notifier.requestAuthorization()
        Task {
            for adapter in adapters {
                await adapter.start { [weak self] signal in
                    Task { @MainActor in self?.handle(signal) }
                }
            }
            for adapter in adapters {
                let paths = adapter.watchedPaths()
                let kind = adapter.kind
                watchers.append(FileWatcher(paths: paths) { [weak self] changed in
                    // Ignore SQLite sidecar churn (our own read-only reads touch -shm) to avoid refresh loops.
                    let relevant = changed.contains { p in !(p.hasSuffix("-shm") || p.hasSuffix("-wal") || p.hasSuffix("-journal") || p.hasSuffix(".db")) }
                    guard relevant else { return }
                    Task { @MainActor in self?.scheduleRefresh(kind, delay: 0.25) }
                })
            }
            refreshAll()
            restartPolling()
            await refreshHealth()
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        pollTask?.cancel()
        watchers.removeAll()
    }

    private func restartPolling() {
        pollTask?.cancel()
        let interval = max(2, settings.refreshInterval)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.refreshAll()
            }
        }
    }

    func refreshAll() {
        for a in adapters { scheduleRefresh(a.kind, delay: 0) }
    }

    func refreshHealth() async {
        await withTaskGroup(of: (ProviderKind, ProviderHealth).self) { group in
            for a in adapters { group.addTask { (a.kind, await a.checkHealth()) } }
            for await (k, h) in group { health[k] = h }
        }
    }

    private func isEnabled(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .claudeCode: return settings.discoverClaude
        case .cursor: return settings.discoverCursor
        }
    }

    /// Coalesces refresh requests per provider so FSEvents bursts cause one snapshot.
    func scheduleRefresh(_ kind: ProviderKind, delay: TimeInterval) {
        if refreshTasks[kind] != nil { refreshPending.insert(kind); return }
        refreshTasks[kind] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await self?.refresh(kind)
            guard let self else { return }
            self.refreshTasks[kind] = nil
            if self.refreshPending.remove(kind) != nil { self.scheduleRefresh(kind, delay: 0.5) }
        }
    }

    private func refresh(_ kind: ProviderKind) async {
        guard let adapter = adapters.first(where: { $0.kind == kind }) else { return }
        let options = DiscoveryOptions(historyWindow: settings.historyDays * 86_400)
        let enabled = isEnabled(kind)
        do {
            // Each adapter is isolated: an error here only affects this provider.
            debugLog("refresh \(kind) begin")
            var snapshot = try await adapter.snapshot(options: options)
            debugLog("refresh \(kind) got \(snapshot.count)")
            if !enabled { snapshot = snapshot.filter { $0.ownership == .managed } }
            adapterErrors[kind] = nil
            let w = adapter.formatWarnings()
            if formatWarnings[kind] ?? [] != w { formatWarnings[kind] = w }
            merge(kind, snapshot)
        } catch {
            adapterErrors[kind] = error.localizedDescription
            debugLog("refresh \(kind) error \(error)")
            // Keep last-known agents but stop claiming they are live.
            for (id, var a) in agents where a.provider == kind && a.status.isLive {
                a.status = .unknown
                a.statusDetail = "Provider unavailable: \(error.localizedDescription)"
                agents[id] = a
            }
        }
        lastRefresh[kind] = Date()
    }

    // MARK: Merge & events

    private func merge(_ kind: ProviderKind, _ snapshot: [Agent]) {
        let firstSnapshot = !initialSnapshotDone.contains(kind)
        initialSnapshotDone.insert(kind)
        var seen = Set<String>()
        var changed: [Agent] = []
        for var a in snapshot {
            if let h = a.handle, managedHandles.contains(h) { managedIDs.insert(a.id) }
            if managedIDs.contains(a.id) && a.ownership == .discovered {
                a.ownership = .managed
            }
            a.projectID = projectID(for: a.workingDirectory, create: true)
            a.isPinned = pins.contains(a.id)
            seen.insert(a.id)
            let prev = agents[a.id]
            if a.status.isWaiting {
                a.waitingSince = (prev?.status == a.status ? prev?.waitingSince : nil) ?? Date()
            }
            if prev == nil && !knownIDs.contains(a.id) {
                knownIDs.insert(a.id)
                if !firstSnapshot || a.status.isLive {
                    record(a, a.status.isLive ? .discovered : .info,
                           a.status.isLive ? "Detected \(a.kindLabel?.lowercased() ?? "") session" : "Found recent session", notify: false)
                }
            } else if let prev, prev.status != a.status, prev.status != .unknown || !firstSnapshot {
                transition(from: prev, to: a, silent: prev.status == .unknown)
                // An archived agent that starts working or needs you again comes back to the dashboard.
                if hidden.contains(a.id), !prev.status.isActive, a.status.isActive {
                    hidden.remove(a.id)
                    persistence.setHidden(a.id, false)
                    record(a, .info, "Active again, moved out of Archive", notify: false)
                }
            }
            if prev.map({ $0.status != a.status || $0.title != a.title || $0.model != a.model || $0.lastActivity != a.lastActivity }) ?? true {
                changed.append(a)
            }
            agents[a.id] = a
        }
        // Agents of this provider that disappeared from the snapshot.
        let cutoff = Date().addingTimeInterval(-settings.historyDays * 86_400)
        for (id, var a) in agents where a.provider == kind && !seen.contains(id) {
            if a.status.isLive || a.status == .unknown {
                let wasLive = a.status.isLive
                a.status = .stopped
                a.statusDetail = "Session ended or is no longer reported by \(kind.displayName)."
                a.capabilities = [.resume, .focus]
                a.pid = nil
                a.pendingPermission = nil
                agents[id] = a
                changed.append(a)
                if wasLive { record(a, .stopped, "Session ended", notify: false) }
            }
            if !pins.contains(id), (a.lastActivity ?? .distantPast) < cutoff {
                agents.removeValue(forKey: id)
            }
        }
        if !changed.isEmpty { persistence.save(agents: changed) }
        saveManaged()
        updateDockBadge()
        sendReminders()
        autoArchive()
    }

    private func autoArchive() {
        let hours = settings.autoArchiveHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let stale = agents.values.filter {
            !hidden.contains($0.id) && !$0.isPinned && $0.status.isArchivable && ($0.lastActivity ?? .distantPast) < cutoff
        }
        guard !stale.isEmpty else { return }
        for a in stale { hidden.insert(a.id); persistence.setHidden(a.id, true) }
        debugLog("auto-archived \(stale.count)")
    }

    /// One reminder per waiting episode, after `remindWaitingMinutes`.
    private func sendReminders() {
        let minutes = settings.remindWaitingMinutes
        guard minutes > 0, settings.notifyOnWaiting else { return }
        let now = Date()
        for a in agents.values where a.status.isWaiting && !hidden.contains(a.id) {
            guard let since = a.waitingSince, now.timeIntervalSince(since) >= minutes * 60, reminded[a.id] != since else { continue }
            reminded[a.id] = since
            let mins = Int(now.timeIntervalSince(since) / 60)
            notifier.post(title: a.title, body: "\(a.provider.displayName) · Still \(a.status.label.lowercased()) (\(mins) min)",
                          agentID: a.id, canDecide: a.pendingPermission.map(Self.isAcceptReject) ?? false)
        }
        reminded = reminded.filter { agents[$0.key]?.status.isWaiting == true }
    }

    nonisolated static func isAcceptReject(_ p: PermissionRequest) -> Bool {
        Set(p.options.map(\.id)) == ["accept", "reject"]
    }

    private func transition(from prev: Agent, to a: Agent, silent: Bool) {
        let kind: AgentEventKind
        var message: String
        switch a.status {
        case .working: kind = prev.status.isWaiting ? .resumed : .statusChanged; message = prev.status.isWaiting ? "Continued working" : "Started working"
        case .idle: kind = .idle; message = "Became idle"
        case .waitingApproval: kind = .permissionRequested; message = a.statusDetail ?? "Waiting for approval"
        case .waitingInput: kind = .statusChanged; message = "Waiting for input"
        case .completed: kind = .completed; message = "Completed"
        case .failed: kind = .failed; message = a.statusDetail.map { "Failed: \($0)" } ?? "Failed"
        case .stopped: kind = .stopped; message = "Stopped"
        case .unknown: return
        }
        // Avoid duplicates when the adapter already emitted the same event.
        if let last = events.first(where: { $0.agentID == a.id }), last.kind == kind, Date().timeIntervalSince(last.date) < 10 { return }
        record(a, kind, message, notify: !silent)
    }

    func record(_ a: Agent, _ kind: AgentEventKind, _ message: String, notify: Bool) {
        var e = AgentEvent(agentID: a.id, provider: a.provider, projectID: a.projectID, kind: kind, message: message, date: Date())
        e.id = persistence.insert(e)
        events.insert(e, at: 0)
        if events.count > 2500 { events.removeLast(events.count - 2000); persistence.pruneEvents() }
        guard notify else { return }
        let wants: Bool
        switch kind {
        case .permissionRequested: wants = settings.notifyOnWaiting
        case .completed: wants = settings.notifyOnCompleted
        case .failed: wants = settings.notifyOnFailed
        default: wants = a.status == .waitingInput && settings.notifyOnWaiting
        }
        if wants {
            notifier.post(title: a.title, body: "\(a.provider.displayName) · \(message)", agentID: a.id,
                          canDecide: kind == .permissionRequested && (a.pendingPermission.map(Self.isAcceptReject) ?? false))
        }
    }

    private func handle(_ signal: AdapterSignal) {
        switch signal {
        case .needsRefresh(let k), .agentUpdated(let k):
            scheduleRefresh(k, delay: 0.1)
        case let .event(sid, provider, kind, message):
            let id = "\(provider.rawValue):\(sid)"
            let agent = agents[id] ?? Agent(provider: provider, sessionID: sid, title: "Session", status: .unknown, ownership: .discovered, capabilities: [])
            if kind == .permissionRequested,
               let last = events.first(where: { $0.agentID == id }), last.kind == .permissionRequested, Date().timeIntervalSince(last.date) < 10 { break }
            record(agent, kind, message, notify: kind == .permissionRequested || kind == .failed || kind == .completed)
            scheduleRefresh(provider, delay: 0.1)
        }
    }

    private func saveManaged() {
        if let d = try? JSONEncoder().encode(Array(managedIDs)) { persistence.setValue("managedIDs", String(decoding: d, as: UTF8.self)) }
        if let d = try? JSONEncoder().encode(Array(managedHandles)) { persistence.setValue("managedHandles", String(decoding: d, as: UTF8.self)) }
    }

    private func updateDockBadge() {
        let n = agents.values.filter { $0.status.isWaiting && !hidden.contains($0.id) }.count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: Projects

    private static let palette = ["8B5CF6", "22C55E", "3B82F6", "F59E0B", "EC4899", "14B8A6", "EF4444", "A855F7", "06B6D4", "84CC16"]

    func projectRoot(for path: String) -> String {
        GitInfo.repo(containing: path)?.mainRoot ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func projectID(for cwd: String?, create: Bool) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let std = URL(fileURLWithPath: cwd).standardizedFileURL.path
        // Most specific user project containing this path wins.
        if let p = projects.filter({ std == $0.path || std.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }),
           p.path != NSHomeDirectory() || std == NSHomeDirectory() {
            return p.id
        }
        let root = projectRoot(for: std)
        if let p = projects.first(where: { $0.path == root }) { return p.id }
        guard create else { return nil }
        let isHome = root == NSHomeDirectory()
        let name = isHome ? "Home" : URL(fileURLWithPath: root).lastPathComponent
        let color = Self.palette[abs(root.hashValue) % Self.palette.count]
        let p = Project(id: root, name: name, path: root, colorHex: color, symbol: isHome ? "house" : "folder",
                        isUserAdded: false, isHidden: false, isGitRepository: GitInfo.repo(containing: root) != nil, createdAt: Date())
        projects.append(p)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistence.save(p)
        return p.id
    }

    func addProject(path: String) {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if let idx = projects.firstIndex(where: { $0.path == std }) {
            projects[idx].isUserAdded = true; projects[idx].isHidden = false
            persistence.save(projects[idx])
        } else {
            let color = Self.palette[projects.count % Self.palette.count]
            let p = Project(id: std, name: URL(fileURLWithPath: std).lastPathComponent, path: std, colorHex: color, symbol: "folder",
                            isUserAdded: true, isHidden: false, isGitRepository: GitInfo.repo(containing: std) != nil, createdAt: Date())
            projects.append(p)
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            persistence.save(p)
        }
        reassignProjects()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        persistence.save(project)
    }

    func removeProject(_ project: Project) {
        // Auto-detected projects are hidden (they would be re-created); user-added ones are deleted.
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].isHidden = true
            projects[idx].isUserAdded = false
            persistence.save(projects[idx])
        }
    }

    private func reassignProjects() {
        for (id, var a) in agents {
            a.projectID = projectID(for: a.workingDirectory, create: false) ?? a.projectID
            agents[id] = a
        }
    }

    // MARK: Pins & visibility

    func togglePin(_ agent: Agent) {
        if let i = pins.firstIndex(of: agent.id) { pins.remove(at: i) } else { pins.append(agent.id) }
        agents[agent.id]?.isPinned = pins.contains(agent.id)
        persistence.savePins(pins)
    }

    func movePin(_ id: String, before target: String?) {
        guard let from = pins.firstIndex(of: id) else { return }
        pins.remove(at: from)
        if let target, let to = pins.firstIndex(of: target) { pins.insert(id, at: to) } else { pins.append(id) }
        persistence.savePins(pins)
    }

    // MARK: Archive (stored in the `hidden_agents` table)

    var archivedAgents: [Agent] { agents.values.filter { hidden.contains($0.id) } }
    func isArchived(_ agent: Agent) -> Bool { hidden.contains(agent.id) }

    /// Archives agents that are finished or idle. Working, waiting and failed agents are never archived, so
    /// nothing disappears while it is busy or needs you.
    @discardableResult
    func archive(_ list: [Agent]) -> Int {
        let targets = list.filter { $0.status.isArchivable && !hidden.contains($0.id) }
        for a in targets {
            hidden.insert(a.id)
            persistence.setHidden(a.id, true)
            if pins.contains(a.id) { togglePin(a) }
        }
        if targets.count == 1, let a = targets.first { toast = "Archived “\(a.title)”" }
        else if targets.count > 1 { toast = "Archived \(targets.count) agents. They're under Archived in the sidebar." }
        updateDockBadge()
        return targets.count
    }

    func archive(_ agent: Agent) { archive([agent]) }

    func unarchive(_ agent: Agent) {
        hidden.remove(agent.id)
        persistence.setHidden(agent.id, false)
        toast = "Moved “\(agent.title)” back to the dashboard"
    }

    func unarchiveAll() {
        for id in hidden { persistence.setHidden(id, false) }
        hidden.removeAll()
    }

    /// Kept for older call sites.
    func hide(_ agent: Agent) { archive(agent) }
    func unhideAll() { unarchiveAll() }

    // MARK: Actions

    func adapter(for kind: ProviderKind) -> AgentAdapter { kind == .claudeCode ? claude : cursor }

    func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        let result = try await adapter(for: request.provider).launch(request)
        if let h = result.handle { managedHandles.insert(h) }
        if let sid = result.sessionID {
            let id = "\(request.provider.rawValue):\(sid)"
            if request.mode == .managed { managedIDs.insert(id) }
            knownIDs.insert(id)
            let placeholder = Agent(provider: request.provider, sessionID: sid, title: request.title?.isEmpty == false ? request.title! : String(request.prompt.prefix(60)),
                                    model: request.model, workingDirectory: request.workingDirectory,
                                    status: request.mode == .managed ? .working : .unknown, ownership: request.mode == .managed ? .managed : .discovered,
                                    capabilities: [], startedAt: Date(), lastActivity: Date(),
                                    kindLabel: request.mode == .managed ? (request.provider == .cursor ? "ACP" : "Background") : "Terminal",
                                    projectID: projectID(for: request.workingDirectory, create: true))
            if agents[id] == nil { agents[id] = placeholder }
            record(placeholder, .started, "Launched from AgentDeck: \(result.commandDescription)", notify: false)
        } else {
            let stub = Agent(provider: request.provider, sessionID: "launch-\(UUID().uuidString.prefix(8))", title: request.title ?? request.prompt,
                             status: .unknown, ownership: .managed, capabilities: [],
                             projectID: projectID(for: request.workingDirectory, create: true))
            record(stub, .started, "Launched from AgentDeck: \(result.commandDescription)", notify: false)
        }
        saveManaged()
        scheduleRefresh(request.provider, delay: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.scheduleRefresh(request.provider, delay: 0) }
        return result
    }

    func perform(_ action: AgentAction, on agent: Agent) {
        Task {
            do {
                let adapter = adapter(for: agent.provider)
                switch action {
                case .focus: try await adapter.focus(agent)
                case .resume:
                    try await adapter.resume(agent)
                    record(agent, .resumed, "Resumed in terminal", notify: false)
                case .stop:
                    try await adapter.stop(agent)
                    record(agent, .stopped, "Stopped from AgentDeck", notify: false)
                case .interrupt:
                    try await adapter.interrupt(agent)
                    record(agent, .stopped, "Interrupted from AgentDeck", notify: false)
                case .openWorkspace:
                    if agent.provider == .cursor { try await cursor.openWorkspace(agent) }
                    else if let cwd = agent.workingDirectory { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
                case .revealInFinder:
                    if let cwd = agent.workingDirectory { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
                }
                scheduleRefresh(agent.provider, delay: 0.3)
            } catch {
                alert = AlertItem(title: "\(action.label) failed", message: error.localizedDescription)
            }
        }
    }

    func send(_ message: String, to agent: Agent) {
        Task {
            do { try await adapter(for: agent.provider).send(agent, message: message) }
            catch { alert = AlertItem(title: "Could not send", message: error.localizedDescription) }
        }
    }

    /// Called from a notification's Accept / Reject buttons.
    func decideFromNotification(agentID: String, accept: Bool) {
        guard let a = agents[agentID], a.capabilities.contains(.approve), a.pendingPermission != nil else {
            alert = AlertItem(title: "Nothing to answer", message: "That agent is no longer waiting for approval.")
            return
        }
        respond(a, optionID: accept ? "accept" : "reject")
    }

    func respond(_ agent: Agent, optionID: String?) {
        Task {
            do {
                try await adapter(for: agent.provider).respondToPermission(agent, optionID: optionID)
                let name = agent.pendingPermission?.options.first { $0.id == optionID }?.name ?? "Rejected"
                record(agent, .info, "Permission answered: \(name)", notify: false)
            } catch { alert = AlertItem(title: "Could not answer", message: error.localizedDescription) }
        }
    }

    // MARK: Claude hooks

    var claudeHooksInstalled: Bool { claude.hooks.isInstalled }

    func setClaudeHooks(_ enabled: Bool) {
        do {
            if enabled { try claude.hooks.install() } else { try claude.hooks.uninstall() }
            toast = enabled ? "Claude Code hooks installed (backup saved next to settings.json)" : "Claude Code hooks removed"
        } catch {
            alert = AlertItem(title: "Could not update Claude Code settings", message: error.localizedDescription)
        }
    }

    // MARK: Queries

    var visibleAgents: [Agent] {
        agents.values.filter { !hidden.contains($0.id) && (settings.showInactive || $0.status.isLive || $0.isPinned || $0.status.needsAttention) }
    }

    func sorted(_ list: [Agent]) -> [Agent] {
        list.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isPinned, $1.isPinned { return (pins.firstIndex(of: $0.id) ?? 0) < (pins.firstIndex(of: $1.id) ?? 0) }
            if $0.status.sortRank != $1.status.sortRank { return $0.status.sortRank < $1.status.sortRank }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    func project(_ id: String?) -> Project? { id.flatMap { pid in projects.first { $0.id == pid } } }

    func activeCount(in project: Project) -> Int {
        visibleAgents.filter { $0.projectID == project.id && $0.status.isLive }.count
    }

    var sidebarProjects: [Project] {
        projects.filter { p in !p.isHidden && (p.isUserAdded || visibleAgents.contains { $0.projectID == p.id }) }
    }

    func events(for agent: Agent) -> [AgentEvent] { events.filter { $0.agentID == agent.id } }

    func reloadEvents() { events = persistence.loadEvents() }

    var monitoredCount: Int { visibleAgents.filter { $0.status.isLive }.count }

    func shutdown() {
        cursor.shutdown()
    }
}

enum AgentAction: String {
    case focus, resume, stop, interrupt, openWorkspace, revealInFinder
    var label: String {
        switch self {
        case .focus: return "Focus"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .interrupt: return "Interrupt"
        case .openWorkspace: return "Open workspace"
        case .revealInFinder: return "Reveal in Finder"
        }
    }
}

extension Agent {
    init(provider: ProviderKind, sessionID: String, title: String, model: String? = nil, workingDirectory: String? = nil,
         status: AgentStatus, ownership: AgentOwnership, capabilities: AgentCapabilities, startedAt: Date? = nil,
         lastActivity: Date? = nil, kindLabel: String? = nil, projectID: String? = nil) {
        self.init(provider: provider, sessionID: sessionID, handle: nil, title: title, model: model, workingDirectory: workingDirectory,
                  gitBranch: nil, status: status, statusDetail: nil, ownership: ownership, capabilities: capabilities,
                  createdAt: startedAt, startedAt: startedAt, lastActivity: lastActivity, pid: nil, kindLabel: kindLabel,
                  lastMessage: nil, pendingPermission: nil)
        self.projectID = projectID
    }

    /// Short human-readable focus action label, honest about what happens.
    var focusLabel: String {
        if hostApp == "Claude" { return "Open in Claude" }
        if hostApp == "Cursor" { return "Open in Cursor" }
        switch provider {
        case .claudeCode:
            if kindLabel == "Background" { return "Attach in Terminal" }
            return status.isLive ? "Focus in Claude Code" : "Resume in Terminal"
        case .cursor:
            if ownership == .managed && status.isLive { return "Open in Cursor" }
            return status.isLive ? "Focus terminal" : "Resume in Terminal"
        }
    }
}

/// Diagnostics to stderr when AGENTDECK_DEBUG=1.
func debugLog(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["AGENTDECK_DEBUG"] == "1" { FileHandle.standardError.write(Data(("[AgentDeck] " + s() + "\n").utf8)) }
}
