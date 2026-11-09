import AppKit
import SQLite3
import Security

/// Agent chats from the Cursor desktop app.
///
/// Cursor keeps a header row per chat in its local state database
/// (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `composerHeaders`)
/// and the chat record under `cursorDiskKV` key `composerData:<id>`. Both are internal formats, so
/// every field is optional and anything unexpected is skipped.
///
/// The database is opened read-only and only these fields are extracted, inside SQLite, with
/// `json_extract`: name, workspace folder, timestamps, `status`, `hasBlockingPendingActions`,
/// `hasPendingPlan`, subtitle, the model name and the number of messages being generated.
/// Conversation text, encryption keys and everything else stay in the file.
///
/// Cursor does not persist "running": while a turn is in progress the chat's `status` keeps its
/// previous value. A run is therefore inferred from the message records (`bubbleId:<chat>:…`), which
/// are written as it works: a tool call with `status: loading`, or a message in the last 90 seconds.
/// Only `createdAt` and `toolFormerData.status` of the latest 25 records are read.
final class CursorAppChats: @unchecked Sendable {
    static let bundleID = "com.todesktop.230313mzl4w4u92"
    private let dbPath: String
    private let warningLock = NSLock()
    private var _warning: String?
    /// Set when Cursor's database exists but no longer matches the expected format.
    var formatWarning: String? { warningLock.withLock { _warning } }

    init(dbPath: String = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb") {
        self.dbPath = dbPath
    }

    private func setWarning(_ w: String?) { warningLock.withLock { _warning = w } }

    struct Row {
        let id: String
        let name: String?
        let cwd: String?
        let created: Date?
        let updated: Date?
        let blocking: Bool
        let pendingPlan: Bool
        let subtitle: String?
        let mode: String?
        let status: String?
        let model: String?
        let generating: Int
        var checkpoint: Date? = nil
        /// From the chat's message records, which Cursor writes live during a run.
        var lastMessageAt: Date? = nil
        var toolsInFlight = 0
        var questionsInFlight = 0
        var contextPercent: Double? = nil
        var contextTokens: Int? = nil
        var linesAdded: Int? = nil
        var linesRemoved: Int? = nil
        var filesChanged: Int? = nil
    }

    var exists: Bool { FileManager.default.fileExists(atPath: dbPath) }

    func agents(window: TimeInterval, appRunning running: Bool? = nil) -> [Agent] {
        guard exists else { return [] }
        let appRunning = running ?? !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        return rows(since: Date().addingTimeInterval(-window)).map { agent(from: $0, appRunning: appRunning) }
    }

    private func agent(from r: Row, appRunning: Bool) -> Agent {
        let (status, detail) = Self.status(r, appRunning: appRunning)
        var a = Agent(provider: .cursor, sessionID: r.id, handle: nil,
                      title: r.name.flatMap { $0.isEmpty || $0 == "New Agent" || $0 == "New Chat" ? nil : $0 } ?? "Cursor chat",
                      model: r.model.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 },
                      workingDirectory: r.cwd, gitBranch: r.cwd.flatMap(GitInfo.branch(at:)),
                      status: status, statusDetail: detail, ownership: .discovered, capabilities: [.focus],
                      createdAt: r.created, startedAt: r.created,
                      lastActivity: [r.updated, r.checkpoint, r.lastMessageAt].compactMap { $0 }.max(), pid: nil,
                      kindLabel: "Cursor app", lastMessage: nil, pendingPermission: nil)
        a.currentActivity = r.subtitle
        a.hostApp = "Cursor"
        a.hostSessionID = r.id
        let stats = AgentStats(contextPercent: r.contextPercent, contextTokens: r.contextTokens, outputTokens: nil,
                               linesAdded: r.linesAdded, linesRemoved: r.linesRemoved, filesChanged: r.filesChanged)
        a.stats = stats.isEmpty ? nil : stats
        if status == .waitingApproval, Self.bridgeInstalled {
            // Accept / Reject go through the bridge to Cursor's own approval commands.
            a.capabilities.insert(.approve)
            a.pendingPermission = PermissionRequest(requestID: "cursor-app:\(r.id)", title: "Cursor is waiting for your approval",
                detail: r.subtitle, options: [
                    .init(id: "accept", name: "Accept", kind: "allow_once"),
                    .init(id: "reject", name: "Reject", kind: "reject_once"),
                ])
        }
        return a
    }

    static func status(_ r: Row, appRunning: Bool) -> (AgentStatus, String?) {
        let s = (r.status ?? "").lowercased()
        let now = Date()
        let recentMessage = r.lastMessageAt.map { now.timeIntervalSince($0) < 90 } ?? false
        let toolRunning = r.toolsInFlight > 0 && (r.lastMessageAt.map { now.timeIntervalSince($0) < 30 * 60 } ?? false)
        let reported = r.generating > 0 || !(s.isEmpty || s == "none" || s == "completed" || s == "aborted")
        let running = reported || recentMessage || toolRunning
        if !appRunning {
            return running ? (.unknown, "Cursor is not running; this chat was mid-run when it closed.") : finished(s)
        }
        if r.blocking { return (.waitingApproval, "Waiting for you to approve an action in Cursor.") }
        if r.questionsInFlight > 0, running { return (.waitingInput, "Cursor is asking you a question.") }
        if running {
            if reported { return (.working, nil) }
            return (.working, toolRunning ? "A tool call is in progress." : "Cursor is writing to this chat.")
        }
        if r.pendingPlan { return (.waitingInput, "A plan is ready for your review in Cursor.") }
        return finished(s)
    }

    private static func finished(_ s: String) -> (AgentStatus, String?) {
        switch s {
        case "completed": return (.completed, "Finished. Focus opens its Cursor window.")
        case "aborted": return (.stopped, "Stopped in Cursor.")
        case "none", "": return (.idle, "No run yet.")
        default: return (.unknown, "Cursor reported status \"\(s)\".")
        }
    }

    private func rows(since: Date) -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        let sql = """
        SELECT h.composerId,
               json_extract(h.value, '$.name'),
               json_extract(h.value, '$.workspaceIdentifier.uri.fsPath'),
               h.createdAt, h.lastUpdatedAt,
               json_extract(h.value, '$.hasBlockingPendingActions'),
               json_extract(h.value, '$.hasPendingPlan'),
               json_extract(h.value, '$.subtitle'),
               json_extract(h.value, '$.unifiedMode'),
               json_extract(c.value, '$.status'),
               json_extract(c.value, '$.modelConfig.modelName'),
               json_array_length(json_extract(c.value, '$.generatingBubbleIds')),
               h.checkpointAt,
               json_extract(h.value, '$.contextUsagePercent'),
               json_extract(c.value, '$.contextTokensUsed'),
               json_extract(h.value, '$.totalLinesAdded'),
               json_extract(h.value, '$.totalLinesRemoved'),
               json_extract(h.value, '$.filesChangedCount')
        FROM composerHeaders h
        LEFT JOIN cursorDiskKV c ON c.key = 'composerData:' || h.composerId
        WHERE IFNULL(h.isSubagent, 0) = 0 AND IFNULL(h.isArchived, 0) = 0
          AND MAX(IFNULL(h.lastUpdatedAt, 0), IFNULL(h.checkpointAt, 0)) >= ?
        ORDER BY MAX(IFNULL(h.lastUpdatedAt, 0), IFNULL(h.checkpointAt, 0)) DESC
        LIMIT 150
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            debugLog("cursor app chats: unexpected schema: \(msg)")
            // "locked/busy" is transient; anything else means the tables changed shape.
            if !msg.lowercased().contains("lock"), !msg.lowercased().contains("busy") {
                setWarning("Cursor's chat database changed format (\(msg)). Cursor app chats can't be listed until AgentDeck is updated.")
            }
            return []
        }
        setWarning(nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, i)) / 1000)
        }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int(stmt, i) != 0 }
        func int(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(0) else { continue }
            out.append(Row(id: id, name: text(1), cwd: text(2), created: date(3), updated: date(4),
                           blocking: bool(5), pendingPlan: bool(6), subtitle: text(7), mode: text(8),
                           status: text(9), model: text(10), generating: Int(sqlite3_column_int(stmt, 11)),
                           checkpoint: date(12), contextPercent: double(13), contextTokens: int(14),
                           linesAdded: int(15), linesRemoved: int(16), filesChanged: int(17)))
        }
        // Live activity, only for chats touched in the last few hours.
        let recent = Date().addingTimeInterval(-6 * 3600)
        for i in out.indices {
            let touched = [out[i].updated, out[i].checkpoint].compactMap { $0 }.max() ?? .distantPast
            guard touched >= recent else { continue }
            let act = activity(db: db, chatID: out[i].id)
            out[i].lastMessageAt = act.last
            out[i].toolsInFlight = act.tools
            out[i].questionsInFlight = act.questions
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Newest message time, tool calls still loading, and questions to you still open, from the latest
    /// 25 message records. Uses a key range (not LIKE) so SQLite walks the key index.
    private func activity(db: OpaquePointer?, chatID: String) -> (last: Date?, tools: Int, questions: Int) {
        let sql = """
        SELECT MAX(json_extract(value, '$.createdAt')),
               SUM(CASE WHEN json_extract(value, '$.toolFormerData.status') = 'loading' THEN 1 ELSE 0 END),
               SUM(CASE WHEN json_extract(value, '$.toolFormerData.status') = 'loading'
                         AND json_extract(value, '$.toolFormerData.name') = 'ask_question' THEN 1 ELSE 0 END)
        FROM (SELECT value FROM cursorDiskKV WHERE key >= ? AND key < ? ORDER BY rowid DESC LIMIT 25)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "bubbleId:\(chatID):", -1, transient)
        sqlite3_bind_text(stmt, 2, "bubbleId:\(chatID);", -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, 0, 0) }
        let last = sqlite3_column_text(stmt, 0).flatMap { Self.iso.date(from: String(cString: $0)) }
        return (last, Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)))
    }

    // MARK: AgentDeck Bridge (optional Cursor extension, integrations/cursor-bridge)

    static let bridgeID = "agentdeck.agentdeck-bridge"

    /// True when the bridge extension is installed in Cursor.
    static var bridgeInstalled: Bool {
        let dir = NSHomeDirectory() + "/.cursor/extensions"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix(bridgeID + "-") }
    }

    /// The packaged extension shipped inside AgentDeck.app, if any.
    static var bundledBridgeVSIX: URL? {
        Bundle.main.urls(forResourcesWithExtension: "vsix", subdirectory: nil)?.first { $0.lastPathComponent.hasPrefix("agentdeck-bridge") }
    }

    /// Installs the bundled bridge with Cursor's own CLI (`cursor --install-extension`).
    static func installBridge() async throws {
        guard let vsix = bundledBridgeVSIX else { throw AgentDeckError.unsupported("This AgentDeck build does not include the Cursor bridge extension.") }
        let cli = "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw AgentDeckError.notInstalled("Cursor's command-line tool was not found in Cursor.app.") }
        let r = await ProcessRunner.run(cli, ["--install-extension", vsix.path, "--force"], timeout: 60)
        guard r.status == 0, bridgeInstalled else {
            throw AgentDeckError.commandFailed((r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func bridgeLink(chatID: String, folder: String?) -> URL? {
        var items = ["chat": chatID]
        if let folder { items["folder"] = folder }
        return bridgeURL("/open", items)
    }

    /// Opens a Cursor app chat. Brings the chat's workspace window forward first (Cursor routes links to the
    /// most recently active window), then, when the bridge extension is installed, asks it to show the chat.
    @MainActor
    static func open(workspace: String?, chatID: String?) async throws {
        try open(workspace: workspace)
        guard let chatID, bridgeInstalled, let link = bridgeLink(chatID: chatID, folder: workspace) else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        NSWorkspace.shared.open(link)
    }

    /// Random secret that the bridge requires for links that act on your behalf (`decide`, `new`), so a web
    /// page or another app that knows the link format cannot use them. Stored 0600 in AgentDeck's folder.
    static func bridgeToken() throws -> String {
        let url = Persistence.supportDirectory.appendingPathComponent("bridge-token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentDeckError.unsupported("Could not create the bridge token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    private static func bridgeURL(_ path: String, _ items: [String: String]) -> URL? {
        var c = URLComponents()
        c.scheme = "cursor"; c.host = bridgeID; c.path = path
        c.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" and "&"-safe characters; encode "+" so prompts survive form decoding.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// Accepts or rejects what a Cursor app chat is waiting on, via Cursor's own approval commands.
    @MainActor
    static func decide(chatID: String, accept: Bool, workspace: String?) async throws {
        guard bridgeInstalled else { throw AgentDeckError.unsupported("Install the AgentDeck Bridge extension (Settings → Integrations → Cursor) to answer Cursor approvals from AgentDeck.") }
        var items = ["chat": chatID, "decision": accept ? "accept" : "reject", "token": try bridgeToken()]
        if let workspace { items["folder"] = workspace }
        guard let url = bridgeURL("/decide", items) else { return }
        try open(workspace: workspace)
        try? await Task.sleep(nanoseconds: 700_000_000)
        NSWorkspace.shared.open(url)
    }

    /// Starts a chat in the Cursor app for `workspace` and submits `prompt`.
    @MainActor
    static func newChat(workspace: String, prompt: String, mode: String) async throws -> String {
        guard bridgeInstalled else { throw AgentDeckError.unsupported("Starting chats in the Cursor app needs the AgentDeck Bridge extension (Settings → Integrations → Cursor).") }
        guard let url = bridgeURL("/new", ["prompt": prompt, "mode": mode, "folder": workspace, "token": try bridgeToken()]) else {
            throw AgentDeckError.unsupported("Could not build the Cursor link.")
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        try open(workspace: workspace)
        // A cold start needs time for the window and extension host to come up before the link can be handled.
        try? await Task.sleep(nanoseconds: wasRunning ? 900_000_000 : 6_000_000_000)
        NSWorkspace.shared.open(url)
        return "Cursor app → new \(mode) chat in \(URL(fileURLWithPath: workspace).lastPathComponent) (via AgentDeck Bridge)"
    }

    /// Brings the Cursor window for this workspace forward.
    @MainActor
    static func open(workspace: String?) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? (FileManager.default.fileExists(atPath: "/Applications/Cursor.app") ? URL(fileURLWithPath: "/Applications/Cursor.app") : nil) else {
            throw AgentDeckError.notInstalled("Cursor.app is not installed.")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let ws = workspace, FileManager.default.fileExists(atPath: ws) {
            NSWorkspace.shared.open([URL(fileURLWithPath: ws)], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        }
    }
}
