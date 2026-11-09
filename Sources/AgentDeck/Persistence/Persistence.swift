import Foundation

/// User preferences. Stored as a JSON value in SQLite (no credentials, ever).
struct AppSettings: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable { case system, dark, light; var id: String { rawValue } }
    enum CloseBehaviour: String, Codable, CaseIterable, Identifiable, Sendable {
        case keepRunning, quit
        var id: String { rawValue }
        var label: String { self == .keepRunning ? "Keep monitoring in the background" : "Quit AgentDeck" }
    }

    var appearance: Appearance = .dark
    var accentHex: String = "8B5CF6"
    var refreshInterval: Double = 5          // seconds; fallback poll for state that has no file events
    var historyDays: Double = 2              // show inactive sessions touched within N days
    var notifyOnWaiting = true
    var notifyOnCompleted = true
    var notifyOnFailed = true
    var discoverClaude = true
    var discoverCursor = true
    var startMonitoringOnLaunch = true
    var closeBehaviour: CloseBehaviour = .keepRunning
    var terminalBundleID = "com.apple.Terminal"
    var inspectorVisible = true
    var showInactive = true
    var defaultClaudePermissionMode: String = ""   // empty = Claude's configured default
    var defaultCursorMode: String = "agent"
    /// Re-notify when an agent has been waiting on you this long (minutes). 0 = off.
    var remindWaitingMinutes: Double = 10
    /// ⌥⌘K from any app opens the quick switcher.
    var globalHotkeyEnabled = true
    /// Clicking a notification opens the agent in its own app (Claude / Cursor / terminal)
    /// instead of showing it in AgentDeck.
    var notificationOpensAgent = true
    /// Archive finished (completed / not running) agents after this many hours without activity. 0 = never.
    var autoArchiveHours: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        // Tolerant decoding so new settings never wipe old ones.
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        accentHex = (try? c.decode(String.self, forKey: .accentHex)) ?? d.accentHex
        refreshInterval = (try? c.decode(Double.self, forKey: .refreshInterval)) ?? d.refreshInterval
        historyDays = (try? c.decode(Double.self, forKey: .historyDays)) ?? d.historyDays
        notifyOnWaiting = (try? c.decode(Bool.self, forKey: .notifyOnWaiting)) ?? d.notifyOnWaiting
        notifyOnCompleted = (try? c.decode(Bool.self, forKey: .notifyOnCompleted)) ?? d.notifyOnCompleted
        notifyOnFailed = (try? c.decode(Bool.self, forKey: .notifyOnFailed)) ?? d.notifyOnFailed
        discoverClaude = (try? c.decode(Bool.self, forKey: .discoverClaude)) ?? d.discoverClaude
        discoverCursor = (try? c.decode(Bool.self, forKey: .discoverCursor)) ?? d.discoverCursor
        startMonitoringOnLaunch = (try? c.decode(Bool.self, forKey: .startMonitoringOnLaunch)) ?? d.startMonitoringOnLaunch
        closeBehaviour = (try? c.decode(CloseBehaviour.self, forKey: .closeBehaviour)) ?? d.closeBehaviour
        terminalBundleID = (try? c.decode(String.self, forKey: .terminalBundleID)) ?? d.terminalBundleID
        inspectorVisible = (try? c.decode(Bool.self, forKey: .inspectorVisible)) ?? d.inspectorVisible
        showInactive = (try? c.decode(Bool.self, forKey: .showInactive)) ?? d.showInactive
        defaultClaudePermissionMode = (try? c.decode(String.self, forKey: .defaultClaudePermissionMode)) ?? d.defaultClaudePermissionMode
        defaultCursorMode = (try? c.decode(String.self, forKey: .defaultCursorMode)) ?? d.defaultCursorMode
        remindWaitingMinutes = (try? c.decode(Double.self, forKey: .remindWaitingMinutes)) ?? d.remindWaitingMinutes
        globalHotkeyEnabled = (try? c.decode(Bool.self, forKey: .globalHotkeyEnabled)) ?? d.globalHotkeyEnabled
        notificationOpensAgent = (try? c.decode(Bool.self, forKey: .notificationOpensAgent)) ?? d.notificationOpensAgent
        autoArchiveHours = (try? c.decode(Double.self, forKey: .autoArchiveHours)) ?? d.autoArchiveHours
    }
}

/// Last-known agent metadata so the dashboard is populated instantly on launch
/// and agents that vanished while AgentDeck was closed are still listed.
struct StoredAgent: Sendable {
    var agent: Agent
}

/// Typed persistence over SQLite. Main-actor callers; DB itself is thread-safe.
final class Persistence: @unchecked Sendable {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AgentDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    let db: Database

    init() throws {
        db = try Database(url: Persistence.supportDirectory.appendingPathComponent("agentdeck.sqlite"))
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE, color TEXT NOT NULL,
            symbol TEXT NOT NULL, user_added INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0,
            is_git INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS agents (
            id TEXT PRIMARY KEY, provider TEXT NOT NULL, session_id TEXT NOT NULL, handle TEXT, title TEXT NOT NULL,
            model TEXT, cwd TEXT, branch TEXT, status TEXT NOT NULL, ownership TEXT NOT NULL, kind_label TEXT,
            created_at REAL, started_at REAL, last_activity REAL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS pins (agent_id TEXT PRIMARY KEY, position INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS hidden_agents (agent_id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, agent_id TEXT NOT NULL, provider TEXT NOT NULL, project_id TEXT,
            kind TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS events_agent ON events(agent_id, created_at);
        CREATE INDEX IF NOT EXISTS events_date ON events(created_at);
        """)
    }

    // MARK: Settings

    func loadSettings() -> AppSettings {
        guard let row = try? db.query("SELECT value FROM settings WHERE key='app'").first,
              let json = row["value"]?.string, let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? db.run("INSERT INTO settings(key,value) VALUES('app',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    [.text(String(decoding: data, as: UTF8.self))])
    }

    func value(_ key: String) -> String? {
        (try? db.query("SELECT value FROM settings WHERE key=?", [.text(key)]).first?["value"]?.string) ?? nil
    }

    func setValue(_ key: String, _ value: String) {
        try? db.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    // MARK: Projects

    func loadProjects() -> [Project] {
        let rows = (try? db.query("SELECT * FROM projects ORDER BY name COLLATE NOCASE")) ?? []
        return rows.compactMap { r in
            guard let id = r["id"]?.string, let name = r["name"]?.string, let path = r["path"]?.string else { return nil }
            return Project(id: id, name: name, path: path, colorHex: r["color"]?.string ?? "8B5CF6",
                           symbol: r["symbol"]?.string ?? "folder", isUserAdded: r["user_added"]?.int == 1,
                           isHidden: r["hidden"]?.int == 1, isGitRepository: r["is_git"]?.int == 1,
                           createdAt: r["created_at"]?.date ?? Date())
        }
    }

    func save(_ p: Project) {
        try? db.run("""
        INSERT INTO projects(id,name,path,color,symbol,user_added,hidden,is_git,created_at) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path, color=excluded.color, symbol=excluded.symbol,
          user_added=excluded.user_added, hidden=excluded.hidden, is_git=excluded.is_git
        """, [.text(p.id), .text(p.name), .text(p.path), .text(p.colorHex), .text(p.symbol), .from(p.isUserAdded), .from(p.isHidden), .from(p.isGitRepository), .from(p.createdAt)])
    }

    func deleteProject(_ id: String) { try? db.run("DELETE FROM projects WHERE id=?", [.text(id)]) }

    // MARK: Agents

    func loadAgents() -> [Agent] {
        let rows = (try? db.query("SELECT * FROM agents ORDER BY last_activity DESC LIMIT 500")) ?? []
        return rows.compactMap { r in
            guard let p = r["provider"]?.string.flatMap(ProviderKind.init(rawValue:)), let sid = r["session_id"]?.string else { return nil }
            return Agent(provider: p, sessionID: sid, handle: r["handle"]?.string, title: r["title"]?.string ?? "Session",
                         model: r["model"]?.string, workingDirectory: r["cwd"]?.string, gitBranch: r["branch"]?.string,
                         status: r["status"]?.string.flatMap(AgentStatus.init(rawValue:)) ?? .unknown, statusDetail: nil,
                         ownership: r["ownership"]?.string.flatMap(AgentOwnership.init(rawValue:)) ?? .discovered,
                         capabilities: [], createdAt: r["created_at"]?.date, startedAt: r["started_at"]?.date,
                         lastActivity: r["last_activity"]?.date, pid: nil, kindLabel: r["kind_label"]?.string)
        }
    }

    func save(agents: [Agent]) {
        try? db.transaction {
            for a in agents {
                try db.run("""
                INSERT INTO agents(id,provider,session_id,handle,title,model,cwd,branch,status,ownership,kind_label,created_at,started_at,last_activity,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET handle=excluded.handle, title=excluded.title, model=COALESCE(excluded.model, agents.model),
                  cwd=COALESCE(excluded.cwd, agents.cwd), branch=COALESCE(excluded.branch, agents.branch), status=excluded.status,
                  ownership=CASE WHEN agents.ownership='managed' THEN 'managed' ELSE excluded.ownership END,
                  kind_label=excluded.kind_label, started_at=COALESCE(excluded.started_at, agents.started_at),
                  last_activity=excluded.last_activity, updated_at=excluded.updated_at
                """, [.text(a.id), .text(a.provider.rawValue), .text(a.sessionID), .from(a.handle), .text(a.title), .from(a.model),
                      .from(a.workingDirectory), .from(a.gitBranch), .text(a.status.rawValue), .text(a.ownership.rawValue), .from(a.kindLabel),
                      .from(a.createdAt), .from(a.startedAt), .from(a.lastActivity), .from(Date())])
            }
        }
    }

    func markManaged(_ agentID: String) { try? db.run("UPDATE agents SET ownership='managed' WHERE id=?", [.text(agentID)]) }

    func deleteAgent(_ id: String) {
        try? db.run("DELETE FROM agents WHERE id=?", [.text(id)])
        try? db.run("DELETE FROM pins WHERE agent_id=?", [.text(id)])
    }

    func pruneAgents(olderThan date: Date, keeping ids: Set<String>) {
        let rows = (try? db.query("SELECT id FROM agents WHERE COALESCE(last_activity, updated_at) < ?", [.from(date)])) ?? []
        for r in rows { if let id = r["id"]?.string, !ids.contains(id) { try? db.run("DELETE FROM agents WHERE id=?", [.text(id)]) } }
    }

    // MARK: Pins / hidden

    func loadPins() -> [String] {
        ((try? db.query("SELECT agent_id FROM pins ORDER BY position")) ?? []).compactMap { $0["agent_id"]?.string }
    }

    func savePins(_ ids: [String]) {
        try? db.transaction {
            try db.run("DELETE FROM pins")
            for (i, id) in ids.enumerated() { try db.run("INSERT INTO pins(agent_id, position) VALUES(?,?)", [.text(id), .int(Int64(i))]) }
        }
    }

    func loadHidden() -> Set<String> {
        Set(((try? db.query("SELECT agent_id FROM hidden_agents")) ?? []).compactMap { $0["agent_id"]?.string })
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { try? db.run("INSERT OR IGNORE INTO hidden_agents(agent_id) VALUES(?)", [.text(id)]) }
        else { try? db.run("DELETE FROM hidden_agents WHERE agent_id=?", [.text(id)]) }
    }

    // MARK: Events

    func insert(_ e: AgentEvent) -> Int64 {
        (try? db.run("INSERT INTO events(agent_id,provider,project_id,kind,message,created_at) VALUES(?,?,?,?,?,?)",
                     [.text(e.agentID), .text(e.provider.rawValue), .from(e.projectID), .text(e.kind.rawValue), .text(e.message), .from(e.date)])) ?? 0
    }

    func loadEvents(limit: Int = 2000) -> [AgentEvent] {
        let rows = (try? db.query("SELECT * FROM events ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let aid = r["agent_id"]?.string, let p = r["provider"]?.string.flatMap(ProviderKind.init(rawValue:)),
                  let k = r["kind"]?.string.flatMap(AgentEventKind.init(rawValue:)) else { return nil }
            return AgentEvent(id: r["id"]?.int ?? 0, agentID: aid, provider: p, projectID: r["project_id"]?.string, kind: k,
                              message: r["message"]?.string ?? "", date: r["created_at"]?.date ?? Date())
        }
    }

    func pruneEvents(keep: Int = 5000) {
        try? db.run("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT ?)", [.int(Int64(keep))])
    }

    func clearEvents() { try? db.run("DELETE FROM events") }
}
