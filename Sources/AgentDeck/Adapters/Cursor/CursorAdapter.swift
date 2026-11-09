import AppKit
import SQLite3

/// Cursor integration.
///
/// • Managed agents: `cursor-agent acp` (Agent Client Protocol). Gives precise
///   status, model, plan progress, permission requests, cancel and follow-ups.
///   ACP sessions are child processes of AgentDeck; the chat itself is persisted
///   by Cursor and stays resumable after AgentDeck quits.
/// • Discovered agents: Cursor CLI chats in ~/.cursor/chats/<md5(cwd)>/<chatId>/
///   (meta.json + the plain `meta` table of store.db, opened read-only; encrypted
///   conversation blobs are never touched). Liveness is inferred from running
///   cursor-agent processes in the same directory.
/// • Cursor app agent chats: read-only from the app's local state database
///   (see CursorAppChats). Focus brings the right Cursor window forward; Cursor has
///   no external link that selects a specific chat.
final class CursorAdapter: AgentAdapter, @unchecked Sendable {
    let kind: ProviderKind = .cursor
    let prefs: AdapterPreferences
    private let lock = NSLock()
    private var signals: (@Sendable (AdapterSignal) -> Void)?
    private var executable: String?
    private var sessions: [String: ManagedSession] = [:]
    private var cachedModels: [ModelOption] = []
    private var cachedModes: [ModeOption] = []
    private let chatsDir = NSHomeDirectory() + "/.cursor/chats"
    private let appChats = CursorAppChats()

    init(prefs: AdapterPreferences) { self.prefs = prefs }

    final class ManagedSession: @unchecked Sendable {
        let client: ACPClient
        var sessionID = ""
        var title: String
        var cwd: String
        var model: String?
        var modelName: String?
        var mode: String?
        var status: AgentStatus = .working
        var detail: String?
        var startedAt = Date()
        var lastActivity = Date()
        var messageBuffer = ""
        var lastMessage: String?
        var currentTool: String?
        var progress: AgentProgress?
        var permission: PermissionRequest?
        var permissionRPCID: Any?
        var ended = false
        init(client: ACPClient, title: String, cwd: String) { self.client = client; self.title = title; self.cwd = cwd }
    }

    func start(signals: @escaping @Sendable (AdapterSignal) -> Void) async {
        self.signals = signals
        executable = ProcessRunner.which("cursor-agent") ?? ProcessRunner.which("agent")
    }

    func watchedPaths() -> [String] { [chatsDir] }

    func formatWarnings() -> [String] { [appChats.formatWarning].compactMap { $0 } }

    private func exe() throws -> String {
        guard let e = executable ?? ProcessRunner.which("cursor-agent") else {
            throw AgentDeckError.notInstalled("Cursor CLI (`cursor-agent`) not found. Install it from cursor.com/cli.")
        }
        return e
    }

    // MARK: Health

    func checkHealth() async -> ProviderHealth {
        var h = ProviderHealth()
        h.appInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
        h.checkedAt = Date()
        guard let exe = ProcessRunner.which("cursor-agent") ?? ProcessRunner.which("agent") else {
            h.state = .notInstalled
            h.message = h.appInstalled ? "Cursor is installed, but the Cursor CLI (`cursor-agent`) is not. Install it to launch and monitor agents." : "Cursor CLI not found."
            return h
        }
        executable = exe
        h.executablePath = exe
        let v = await ProcessRunner.run(exe, ["--version"], timeout: 10)
        h.version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = await ProcessRunner.run(exe, ["status", "--format", "json"], timeout: 15)
        if let data = s.stdout.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = obj["isAuthenticated"] as? Bool ?? false
            h.account = (obj["userInfo"] as? [String: Any])?["email"] as? String
            h.state = ok ? .ok : .notAuthenticated
            h.message = ok ? "Signed in with your Cursor account." : "Not signed in. Run `cursor-agent login` in a terminal."
        } else {
            h.state = .error
            h.message = String((s.stderr.isEmpty ? s.stdout : s.stderr).prefix(200))
        }
        return h
    }

    // MARK: Discovery

    func snapshot(options: DiscoveryOptions) async throws -> [Agent] {
        var agents: [Agent] = []
        lock.lock()
        let managed = Array(sessions.values)
        lock.unlock()
        var managedIDs = Set<String>()
        for s in managed where !s.sessionID.isEmpty {
            managedIDs.insert(s.sessionID)
            agents.append(agent(from: s))
        }
        agents += discoverChats(window: options.historyWindow, excluding: managedIDs, ownPIDs: Set(managed.map { $0.client.pid }))
        agents += appChats.agents(window: options.historyWindow).filter { !managedIDs.contains($0.sessionID) }
        return agents
    }

    private func agent(from s: ManagedSession) -> Agent {
        lock.lock(); defer { lock.unlock() }
        var caps: AgentCapabilities = [.resume]
        if !s.ended {
            caps = [.sendMessage, .stop]
            if s.status == .working || s.status.isWaiting { caps.insert(.interrupt) }
            if s.permission != nil { caps.insert(.approve) }
        }
        caps.insert(.focus)
        return Agent(provider: .cursor, sessionID: s.sessionID, handle: nil, title: s.title,
                     model: s.modelName ?? s.model, workingDirectory: s.cwd, gitBranch: GitInfo.branch(at: s.cwd),
                     status: s.status, statusDetail: s.detail, ownership: .managed, capabilities: caps,
                     createdAt: s.startedAt, startedAt: s.startedAt, lastActivity: s.lastActivity,
                     pid: s.ended ? nil : s.client.pid, kindLabel: s.ended ? "ACP (ended)" : "ACP",
                     lastMessage: s.lastMessage, pendingPermission: s.permission, progress: s.progress,
                     currentActivity: s.currentTool)
    }

    private func discoverChats(window: TimeInterval, excluding: Set<String>, ownPIDs: Set<Int32>) -> [Agent] {
        let fm = FileManager.default
        guard let hashes = try? fm.contentsOfDirectory(atPath: chatsDir) else { return [] }
        let cutoff = Date().addingTimeInterval(-window)
        // Running Cursor CLI agents (bundled node runtime), excluding our own ACP children.
        var liveCwds: [String: Int32] = [:]
        for p in ProcessInspector.processes(matching: "/cursor-agent/versions/") where !ownPIDs.contains(p.pid) && !ownPIDs.contains(p.ppid) {
            if let cwd = ProcessInspector.cwd(p.pid) { liveCwds[cwd] = p.pid }
        }
        var byCwd: [String: [Agent]] = [:]
        for h in hashes {
            let dir = chatsDir + "/" + h
            guard let chats = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for chat in chats where !excluding.contains(chat) {
                let path = dir + "/" + chat
                guard let data = fm.contents(atPath: path + "/meta.json"),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      meta["hasConversation"] as? Bool ?? true else { continue }
                let updated = (meta["updatedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                    ?? ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
                let cwd = meta["cwd"] as? String
                let isLiveDir = cwd.map { liveCwds[$0] != nil } ?? false
                guard updated >= cutoff || isLiveDir else { continue }
                let created = (meta["createdAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                let info = readChatMeta(path + "/store.db")
                var a = Agent(provider: .cursor, sessionID: chat, handle: nil,
                              title: info.name.flatMap { $0 == "New Agent" ? nil : $0 } ?? "Cursor chat",
                              model: nil, workingDirectory: cwd, gitBranch: cwd.flatMap(GitInfo.branch(at:)),
                              status: .stopped, statusDetail: "Not running. Resume opens it in your terminal.",
                              ownership: .discovered, capabilities: [.resume, .focus], createdAt: created, startedAt: created,
                              lastActivity: updated, pid: nil, kindLabel: "CLI chat", lastMessage: nil, pendingPermission: nil)
                if let mode = info.mode { a.currentActivity = "Mode: \(mode)" }
                byCwd[cwd ?? "", default: []].append(a)
            }
        }
        // The most recently updated chat in a directory with a live process is the running one.
        var out: [Agent] = []
        for (cwd, var list) in byCwd {
            list.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            if let pid = liveCwds[cwd], !list.isEmpty {
                let recent = (list[0].lastActivity ?? .distantPast) > Date().addingTimeInterval(-20)
                list[0].status = recent ? .working : .idle
                list[0].statusDetail = "Inferred: cursor-agent is running in this folder" + (recent ? " and the chat was just updated." : ".")
                list[0].pid = pid
                list[0].capabilities = [.focus]
            }
            out += list
        }
        return out
    }

    private var metaCache: [String: (Date, String?, String?)] = [:]

    /// Cached by store.db modification date so unchanged chats are never re-opened.
    private func readChatMeta(_ dbPath: String) -> (name: String?, mode: String?) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date ?? .distantPast
        let walTime = (try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal"))?[.modificationDate] as? Date ?? .distantPast
        let stamp = max(mtime, walTime)
        let cached: (Date, String?, String?)? = lock.withLock { metaCache[dbPath] }
        if let cached, cached.0 == stamp { return (cached.1, cached.2) }
        let r = readChatMetaUncached(dbPath)
        lock.withLock { metaCache[dbPath] = (stamp, r.name, r.mode) }
        return r
    }

    /// Reads only the plain-JSON `meta` row (name, mode). Never touches encrypted blobs.
    private func readChatMetaUncached(_ dbPath: String) -> (name: String?, mode: String?) {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return (nil, nil)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return (nil, nil) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return (nil, nil) }
        let raw = String(cString: c)
        var data = Data(capacity: raw.count / 2)
        var idx = raw.startIndex
        while idx < raw.endIndex, let next = raw.index(idx, offsetBy: 2, limitedBy: raw.endIndex) {
            guard let b = UInt8(raw[idx..<next], radix: 16) else { break }
            data.append(b); idx = next
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return (json?["name"] as? String, json?["mode"] as? String)
    }

    // MARK: Models & modes

    func availableModels() async -> [ModelOption] {
        lock.lock(); let cached = cachedModels; lock.unlock()
        if !cached.isEmpty { return cached }
        guard let exe = try? exe() else { return [] }
        let out = await ProcessRunner.run(exe, ["models"], timeout: 20)
        // Lines look like: "gpt-5.2 - GPT-5.2" (current default marked in the name)
        let models = out.stdout.components(separatedBy: "\n").compactMap { line -> ModelOption? in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" ") else { return nil }
            return ModelOption(id: id, name: parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }
        lock.lock(); cachedModels = models; lock.unlock()
        return models
    }

    func launchModes() -> [ModeOption] {
        lock.lock(); defer { lock.unlock() }
        if !cachedModes.isEmpty { return cachedModes }
        // ACP reports these on session/new; until we have seen one, use the CLI's documented modes.
        return [ModeOption(id: "agent", name: "Agent", detail: "Full agent capabilities with tool access"),
                ModeOption(id: "plan", name: "Plan", detail: "Read-only planning; no edits"),
                ModeOption(id: "ask", name: "Ask", detail: "Q&A, no edits or commands")]
    }

    // MARK: Launch (ACP)

    func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        if request.mode == .app {
            // Cursor app modes: agent / plan / chat (the app's name for Ask).
            let m = request.permissionMode == "ask" ? "chat" : (request.permissionMode ?? "agent")
            let ws = request.workingDirectory, prompt = request.prompt
            let desc = try await CursorAppChats.newChat(workspace: ws, prompt: prompt, mode: ["agent", "plan", "chat"].contains(m) ? m : "agent")
            return LaunchResult(sessionID: nil, handle: nil, commandDescription: desc,
                                message: "Started in the Cursor app. It appears here within a few seconds.")
        }
        let exe = try exe()
        switch request.mode {
        case .app: fatalError("handled above")
        case .terminal:
            var args: [String] = []
            if let m = request.model, !m.isEmpty { args += ["--model", m] }
            if let mode = request.permissionMode, mode == "plan" || mode == "ask" { args += ["--mode", mode] }
            if request.worktree { args += ["--worktree"] }
            args += ["--workspace", request.workingDirectory, request.prompt]
            let desc = TerminalLauncher.describe(exe, args, cwd: request.workingDirectory)
            let terminal = prefs.terminalBundleID
            let finalArgs = args
            try await MainActor.run {
                try TerminalLauncher.open(executable: exe, arguments: finalArgs, cwd: request.workingDirectory, title: request.title ?? "Cursor Agent", terminalBundleID: terminal)
            }
            return LaunchResult(sessionID: nil, handle: nil, commandDescription: desc, message: "Opened in your terminal. AgentDeck will pick it up from Cursor's chat store.")
        case .managed:
            return try await launchACP(exe: exe, request: request)
        }
    }

    private func launchACP(exe: String, request: LaunchRequest) async throws -> LaunchResult {
        let client = ACPClient(executable: exe, cwd: request.workingDirectory)
        let title = request.title?.isEmpty == false ? request.title! : String(request.prompt.prefix(60))
        let session = ManagedSession(client: client, title: title, cwd: request.workingDirectory)
        wire(session)
        try client.start()
        do {
            _ = try await client.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "AgentDeck", "version": AppInfo.version],
            ], timeout: 30)
            let created = try await newSession(client: client, cwd: request.workingDirectory)
            guard let sid = created["sessionId"] as? String else { throw AgentDeckError.protocolError("Cursor did not return a session id.") }
            lock.lock()
            session.sessionID = sid
            if let models = created["models"] as? [String: Any] {
                session.model = models["currentModelId"] as? String
                let available = (models["availableModels"] as? [[String: Any]]) ?? []
                session.modelName = available.first { $0["modelId"] as? String == session.model }?["name"] as? String
            }
            if let modes = created["modes"] as? [String: Any], let list = modes["availableModes"] as? [[String: Any]] {
                cachedModes = list.compactMap { m in
                    guard let id = m["id"] as? String else { return nil }
                    return ModeOption(id: id, name: m["name"] as? String ?? id, detail: m["description"] as? String ?? "")
                }
                session.mode = modes["currentModeId"] as? String
            }
            sessions[sid] = session
            lock.unlock()

            var notes: [String] = []
            if let wanted = request.model, !wanted.isEmpty {
                let available = ((created["models"] as? [String: Any])?["availableModels"] as? [[String: Any]]) ?? []
                // ACP model ids may carry bracketed parameters; match on the base id.
                let match = available.first { ($0["modelId"] as? String) == wanted }
                    ?? available.first { ($0["modelId"] as? String)?.components(separatedBy: "[").first == wanted.components(separatedBy: "[").first }
                if let match, let mid = match["modelId"] as? String {
                    do {
                        _ = try await client.request("session/set_model", ["sessionId": sid, "modelId": mid], timeout: 20)
                        lock.lock(); session.model = mid; session.modelName = match["name"] as? String ?? mid; lock.unlock()
                    } catch { notes.append("Model could not be set via ACP (\(error.localizedDescription)); using \(session.modelName ?? "the default").") }
                } else {
                    notes.append("“\(wanted)” is not offered over ACP for this account; using \(session.modelName ?? "the default").")
                }
            }
            if let mode = request.permissionMode, !mode.isEmpty, mode != session.mode {
                do {
                    _ = try await client.request("session/set_mode", ["sessionId": sid, "modeId": mode], timeout: 20)
                    lock.lock(); session.mode = mode; lock.unlock()
                } catch { notes.append("Mode could not be set: \(error.localizedDescription)") }
            }
            for n in notes { signals?(.event(agentSessionID: sid, provider: .cursor, kind: .info, message: n)) }
            prompt(session, text: request.prompt)
            return LaunchResult(sessionID: sid, handle: nil, commandDescription: "cursor-agent acp  (cwd: \(request.workingDirectory))",
                                message: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        } catch {
            client.terminate()
            throw error
        }
    }

    private func newSession(client: ACPClient, cwd: String) async throws -> [String: Any] {
        do {
            return (try await client.request("session/new", ["cwd": cwd, "mcpServers": []], timeout: 60)) as? [String: Any] ?? [:]
        } catch {
            // Use the existing Cursor login (never an API key) if the agent asks us to authenticate.
            if error.localizedDescription.lowercased().contains("auth") {
                _ = try await client.request("authenticate", ["methodId": "cursor_login"], timeout: 60)
                return (try await client.request("session/new", ["cwd": cwd, "mcpServers": []], timeout: 60)) as? [String: Any] ?? [:]
            }
            throw error
        }
    }

    private func wire(_ s: ManagedSession) {
        s.client.onNotification = { [weak self, weak s] method, params in
            guard let self, let s, method == "session/update", let update = params["update"] as? [String: Any] else { return }
            self.apply(update: update, to: s)
        }
        s.client.onRequest = { [weak self, weak s] id, method, params in
            guard let self, let s else { return }
            if method == "session/request_permission" {
                self.handlePermission(id: id, params: params, session: s)
            } else {
                // We advertised no client capabilities; refuse anything else explicitly.
                s.client.respondError(id: id, code: -32601, message: "Method not supported by AgentDeck: \(method)")
            }
        }
        s.client.onExit = { [weak self, weak s] code, tail in
            guard let self, let s else { return }
            self.lock.lock()
            let wasEnded = s.ended
            s.ended = true
            s.permission = nil
            if s.status.isLive {
                s.status = code == 0 || code == 15 ? .stopped : .failed
                s.detail = code == 0 || code == 15 ? "Agent process ended." : "Agent process exited (\(code)). \(tail.suffix(200))"
            }
            let sid = s.sessionID
            self.lock.unlock()
            if !wasEnded && !sid.isEmpty {
                self.signals?(.event(agentSessionID: sid, provider: .cursor, kind: code == 0 || code == 15 ? .stopped : .failed,
                                     message: code == 0 || code == 15 ? "Agent process ended" : "Agent process exited with code \(code)"))
            }
            self.signals?(.agentUpdated(.cursor))
        }
    }

    private func apply(update: [String: Any], to s: ManagedSession) {
        let kind = update["sessionUpdate"] as? String ?? ""
        var event: (AgentEventKind, String)?
        lock.lock()
        s.lastActivity = Date()
        switch kind {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                s.messageBuffer += text
                let collapsed = s.messageBuffer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                s.lastMessage = String(collapsed.suffix(240)).trimmingCharacters(in: .whitespaces)
            }
        case "tool_call":
            let title = update["title"] as? String ?? "Tool call"
            s.currentTool = title
            event = (.toolCall, title)
        case "tool_call_update":
            if let st = update["status"] as? String, st == "completed" || st == "failed" { s.currentTool = nil }
            if update["status"] as? String == "failed" { event = (.toolCall, "Tool failed: \(update["title"] as? String ?? "")") }
        case "plan":
            if let entries = update["entries"] as? [[String: Any]], !entries.isEmpty {
                let done = entries.filter { $0["status"] as? String == "completed" }.count
                s.progress = AgentProgress(completed: done, total: entries.count, label: "\(done) of \(entries.count) plan steps")
                if let current = entries.first(where: { $0["status"] as? String == "in_progress" })?["content"] as? String {
                    s.currentTool = current
                }
            }
        case "current_mode_update":
            s.mode = update["currentModeId"] as? String ?? s.mode
        default: break
        }
        let sid = s.sessionID
        lock.unlock()
        if let event { signals?(.event(agentSessionID: sid, provider: .cursor, kind: event.0, message: event.1)) }
        signals?(.agentUpdated(.cursor))
    }

    private func handlePermission(id: Any, params: [String: Any], session s: ManagedSession) {
        let toolCall = params["toolCall"] as? [String: Any]
        let options = ((params["options"] as? [[String: Any]]) ?? []).compactMap { o -> PermissionRequest.Option? in
            guard let oid = o["optionId"] as? String else { return nil }
            return .init(id: oid, name: o["name"] as? String ?? oid, kind: o["kind"] as? String ?? "")
        }
        var detail: String?
        if let raw = toolCall?["rawInput"] as? [String: Any] {
            detail = (raw["command"] as? String) ?? (raw["path"] as? String) ?? (raw["file_path"] as? String)
        }
        let title = toolCall?["title"] as? String ?? "Permission requested"
        lock.lock()
        s.permission = PermissionRequest(requestID: "\(id)", title: title, detail: detail, options: options)
        s.permissionRPCID = id
        s.status = .waitingApproval
        s.detail = title
        let sid = s.sessionID
        lock.unlock()
        signals?(.event(agentSessionID: sid, provider: .cursor, kind: .permissionRequested, message: title))
        signals?(.agentUpdated(.cursor))
    }

    private func prompt(_ s: ManagedSession, text: String) {
        lock.lock()
        s.status = .working
        s.detail = nil
        s.messageBuffer = ""
        s.lastActivity = Date()
        let sid = s.sessionID
        lock.unlock()
        signals?(.agentUpdated(.cursor))
        Task.detached { [weak self, s] in
            guard let self else { return }
            do {
                let result = try await s.client.request("session/prompt", ["sessionId": sid, "prompt": [["type": "text", "text": text]]])
                let reason = (result as? [String: Any])?["stopReason"] as? String ?? "end_turn"
                self.lock.lock()
                s.permission = nil
                s.currentTool = nil
                var ev: (AgentEventKind, String)
                switch reason {
                case "end_turn":
                    s.status = .completed; s.detail = "Turn finished. Send a follow-up to continue."
                    ev = (.completed, "Finished turn")
                case "cancelled":
                    s.status = .idle; s.detail = "Cancelled. Ready for new instructions."
                    ev = (.stopped, "Turn cancelled")
                case "refusal":
                    s.status = .failed; s.detail = "The model refused to continue."
                    ev = (.failed, "Model refused")
                default:
                    s.status = .failed; s.detail = "Stopped: \(reason)"
                    ev = (.failed, "Stopped: \(reason)")
                }
                self.lock.unlock()
                self.signals?(.event(agentSessionID: sid, provider: .cursor, kind: ev.0, message: ev.1))
            } catch {
                self.lock.lock()
                let ended = s.ended
                if !ended { s.status = .failed; s.detail = error.localizedDescription }
                self.lock.unlock()
                if !ended { self.signals?(.event(agentSessionID: sid, provider: .cursor, kind: .failed, message: error.localizedDescription)) }
            }
            self.signals?(.agentUpdated(.cursor))
        }
    }

    private func managed(_ agent: Agent) -> ManagedSession? {
        lock.lock(); defer { lock.unlock() }
        guard let s = sessions[agent.sessionID], !s.ended else { return nil }
        return s
    }

    // MARK: Actions

    func send(_ agent: Agent, message: String) async throws {
        guard let s = managed(agent) else { throw AgentDeckError.unsupported("This Cursor agent is not running under AgentDeck. Resume it in the terminal to continue.") }
        signals?(.event(agentSessionID: agent.sessionID, provider: .cursor, kind: .instruction, message: String(message.prefix(140))))
        prompt(s, text: message)
    }

    func interrupt(_ agent: Agent) async throws {
        guard let s = managed(agent) else { throw AgentDeckError.unsupported("Only agents launched by AgentDeck can be interrupted.") }
        lock.lock()
        let pid = s.permissionRPCID
        s.permission = nil; s.permissionRPCID = nil
        lock.unlock()
        if let pid { s.client.respond(id: pid, result: ["outcome": ["outcome": "cancelled"]]) }
        s.client.notify("session/cancel", ["sessionId": s.sessionID])
    }

    func stop(_ agent: Agent) async throws {
        guard let s = managed(agent) else { throw AgentDeckError.unsupported("Only agents launched by AgentDeck can be stopped. Discovered Cursor CLI chats are owned by their terminal.") }
        try? await interrupt(agent)
        try? await Task.sleep(nanoseconds: 300_000_000)
        lock.lock(); s.status = .stopped; s.detail = "Stopped from AgentDeck. The chat is kept by Cursor and can be resumed."; lock.unlock()
        s.client.terminate()
    }

    func respondToPermission(_ agent: Agent, optionID: String?) async throws {
        if agent.hostApp == "Cursor", let chat = agent.hostSessionID {
            let ws = agent.workingDirectory
            try await CursorAppChats.decide(chatID: chat, accept: optionID == "accept", workspace: ws)
            signals?(.agentUpdated(.cursor))
            return
        }
        guard let s = managed(agent) else { throw AgentDeckError.unsupported("No pending request.") }
        lock.lock()
        guard let rpc = s.permissionRPCID else { lock.unlock(); return }
        s.permission = nil; s.permissionRPCID = nil
        s.status = .working; s.detail = nil
        lock.unlock()
        if let optionID {
            s.client.respond(id: rpc, result: ["outcome": ["outcome": "selected", "optionId": optionID]])
        } else {
            s.client.respond(id: rpc, result: ["outcome": ["outcome": "cancelled"]])
        }
        signals?(.agentUpdated(.cursor))
    }

    func focus(_ agent: Agent) async throws {
        if agent.hostApp == "Cursor" {
            let ws = agent.workingDirectory, chat = agent.hostSessionID
            try await CursorAppChats.open(workspace: ws, chatID: chat)
            return
        }
        if let pid = agent.pid, agent.ownership == .discovered, let info = ProcessInspector.info(pid),
           let host = ProcessInspector.hostingAppPID(for: info.ppid) {
            if await MainActor.run(body: { TerminalLauncher.activate(pid: host) }) { return }
        }
        if agent.ownership == .managed, managed(agent) != nil {
            // ACP agents run inside AgentDeck; "focus" means open the workspace in Cursor.
            try await openWorkspace(agent)
            return
        }
        try await resume(agent)
    }

    func resume(_ agent: Agent) async throws {
        let exe = try exe(); let terminal = prefs.terminalBundleID
        var args = ["--resume", agent.sessionID]
        if let cwd = agent.workingDirectory { args += ["--workspace", cwd] }
        let cwd = agent.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let finalArgs = args
        try await MainActor.run {
            try TerminalLauncher.open(executable: exe, arguments: finalArgs, cwd: cwd, title: agent.title, terminalBundleID: terminal)
        }
    }

    func openWorkspace(_ agent: Agent) async throws {
        guard let cwd = agent.workingDirectory else { throw AgentDeckError.unsupported("No workspace folder known for this agent.") }
        try await MainActor.run {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
                    ?? (FileManager.default.fileExists(atPath: "/Applications/Cursor.app") ? URL(fileURLWithPath: "/Applications/Cursor.app") : nil) else {
                throw AgentDeckError.notInstalled("Cursor.app is not installed.")
            }
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Called on quit: ACP sessions are our child processes and end with us.
    func liveManagedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.filter { !$0.ended && $0.status.isLive }.count
    }

    func shutdown() {
        lock.lock(); let all = Array(sessions.values); lock.unlock()
        for s in all where !s.ended { s.client.terminate() }
    }
}
