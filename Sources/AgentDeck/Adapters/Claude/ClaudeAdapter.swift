import AppKit

/// Thread-safe values adapters need from user preferences.
final class AdapterPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var _terminal = "com.apple.Terminal"
    var terminalBundleID: String {
        get { lock.lock(); defer { lock.unlock() }; return _terminal }
        set { lock.lock(); _terminal = newValue; lock.unlock() }
    }
}

/// Claude Code integration.
///
/// Supported mechanisms used:
///  • `claude agents --json --all`: live interactive + background sessions (pid, cwd, status, name, state)
///  • `claude --bg …`: launch a managed background session (subscription auth, same as the terminal)
///  • `claude stop <id>` / `claude attach <id>` / `claude --resume <session>`
///  • `claude auth status`: authentication method (warns if API-key billing would be used)
///  • Optional hooks relay for permission prompts (see ClaudeHooks)
/// Transcript files are read best-effort for model / branch / title only.
final class ClaudeAdapter: AgentAdapter, @unchecked Sendable {
    let kind: ProviderKind = .claudeCode
    let prefs: AdapterPreferences
    let hooks = ClaudeHooks()
    private let transcripts = ClaudeTranscriptIndex()
    private let desktopSessions = ClaudeDesktopSessions()
    private var transcriptWarning: String?

    func formatWarnings() -> [String] {
        [lock.withLock { transcriptWarning }, desktopSessions.formatWarning].compactMap { $0 }
    }
    private let lock = NSLock()
    private var signals: (@Sendable (AdapterSignal) -> Void)?
    private var executable: String?
    private var helpText: String?
    /// Latest hook-derived state per session: (status, detail, date).
    private var hookState: [String: (AgentStatus, String?, Date)] = [:]

    init(prefs: AdapterPreferences) { self.prefs = prefs }

    func start(signals: @escaping @Sendable (AdapterSignal) -> Void) async {
        self.signals = signals
        executable = ProcessRunner.which("claude")
        if FileManager.default.fileExists(atPath: hooks.scriptURL.path) { try? hooks.ensureScript() }
    }

    func watchedPaths() -> [String] {
        [transcripts.projectsDir, hooks.spoolDir.path, NSHomeDirectory() + "/.claude/jobs"]
    }

    // MARK: Health

    func checkHealth() async -> ProviderHealth {
        var h = ProviderHealth()
        h.appInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        h.checkedAt = Date()
        guard let exe = ProcessRunner.which("claude") else {
            h.state = .notInstalled
            h.message = "The `claude` CLI was not found on your PATH. Install Claude Code, then refresh."
            return h
        }
        executable = exe
        h.executablePath = exe
        let v = await ProcessRunner.run(exe, ["--version"], timeout: 10)
        h.version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first
        let auth = await ProcessRunner.run(exe, ["auth", "status"], timeout: 10)
        if let data = auth.stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let loggedIn = obj["loggedIn"] as? Bool ?? false
            let method = obj["authMethod"] as? String ?? "unknown"
            let plan = obj["subscriptionType"] as? String
            h.account = [obj["email"] as? String, plan.map { "\($0) plan" }].compactMap { $0 }.joined(separator: " · ")
            if !loggedIn {
                h.state = .notAuthenticated
                h.message = "Not signed in. Run `claude` in a terminal and sign in with your Claude account."
            } else if method.lowercased().contains("api") || (obj["apiProvider"] as? String).map({ $0 != "firstParty" }) == true {
                h.state = .ok
                h.message = "Claude Code is configured for \(method) authentication — sessions may be API-billed. AgentDeck never changes this."
            } else {
                h.state = .ok
                h.message = "Signed in via \(method)."
            }
        } else {
            h.state = auth.status == 0 ? .ok : .error
            h.message = auth.stderr.isEmpty ? nil : String(auth.stderr.prefix(200))
        }
        return h
    }

    // MARK: Discovery

    private struct LiveEntry {
        var pid: Int32?
        var shortID: String?
        var cwd: String?
        var kind: String?
        var startedAt: Date?
        var sessionID: String
        var name: String?
        var status: String?
        var state: String?
    }

    private func liveEntries() async throws -> [LiveEntry] {
        guard let exe = executable ?? ProcessRunner.which("claude") else { throw AgentDeckError.notInstalled("Claude Code CLI not found") }
        let out = await ProcessRunner.run(exe, ["agents", "--json", "--all"], timeout: 10)
        guard out.status == 0, let data = out.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AgentDeckError.commandFailed("`claude agents --json` failed: \(out.stderr.prefix(200))")
        }
        return arr.compactMap { o in
            guard let sid = o["sessionId"] as? String else { return nil }
            return LiveEntry(pid: (o["pid"] as? NSNumber)?.int32Value, shortID: o["id"] as? String, cwd: o["cwd"] as? String,
                             kind: o["kind"] as? String,
                             startedAt: (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                             sessionID: sid, name: o["name"] as? String, status: o["status"] as? String, state: o["state"] as? String)
        }
    }

    func snapshot(options: DiscoveryOptions) async throws -> [Agent] {
        ingestHooks()
        let live = try await liveEntries()
        let files = transcripts.transcriptFiles()
        let fileByID = Dictionary(files.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, b in a.modified > b.modified ? a : b })
        let cutoff = Date().addingTimeInterval(-options.historyWindow)
        var agents: [Agent] = []
        var seen = Set<String>()

        for e in live {
            seen.insert(e.sessionID)
            let t = fileByID[e.sessionID].flatMap { transcripts.summary(sessionID: $0.sessionID, path: $0.path, modified: $0.modified, size: $0.size) }
            var a = baseAgent(sessionID: e.sessionID, transcript: t)
            a.handle = e.shortID
            a.pid = e.pid
            a.workingDirectory = e.cwd ?? t?.cwd
            if let n = e.name, !n.isEmpty { a.title = n }
            a.startedAt = e.startedAt ?? t?.firstTimestamp
            a.createdAt = t?.firstTimestamp ?? e.startedAt
            let isBackground = e.kind == "background"
            a.kindLabel = isBackground ? "Background" : "Interactive"
            let alive = e.pid.map(ProcessInspector.isAlive) ?? true
            (a.status, a.statusDetail) = mapLive(status: e.status, state: e.state, alive: alive, sessionID: e.sessionID, transcript: t)
            if isBackground {
                a.capabilities = [.focus, .attachTerminal, .stop]
                if !a.status.isLive { a.capabilities.insert(.resume) }
            } else {
                a.capabilities = alive ? [.focus] : [.resume, .focus]
            }
            a.lastActivity = max(t?.lastTimestamp ?? .distantPast, t?.modified ?? .distantPast, e.startedAt ?? .distantPast)
            agents.append(a)
        }

        // Recently active sessions that are not running anymore (resumable).
        for f in files where !seen.contains(f.sessionID) && f.modified >= cutoff {
            guard let t = transcripts.summary(sessionID: f.sessionID, path: f.path, modified: f.modified, size: f.size),
                  t.userMessageCount > 0 || t.firstPrompt != nil else { continue }
            var a = baseAgent(sessionID: f.sessionID, transcript: t)
            a.workingDirectory = t.cwd
            a.startedAt = t.firstTimestamp
            a.createdAt = t.firstTimestamp
            a.lastActivity = t.lastTimestamp ?? f.modified
            a.kindLabel = "Session"
            if let err = t.lastErrorText {
                a.status = .failed
                a.statusDetail = err
            } else {
                a.status = .stopped
                a.statusDetail = "Session is not running. Resume opens it in your terminal."
            }
            a.capabilities = [.resume, .focus]
            agents.append(a)
        }

        // Format check: recent transcripts that yield no timestamps or folders mean the format moved.
        let recentFiles = files.filter { $0.modified > Date().addingTimeInterval(-3600) && $0.size > 2048 }.prefix(5)
        let unreadable = recentFiles.filter { f in
            let t = transcripts.summary(sessionID: f.sessionID, path: f.path, modified: f.modified, size: f.size)
            return t?.lastTimestamp == nil && t?.cwd == nil
        }
        lock.withLock {
            transcriptWarning = !recentFiles.isEmpty && unreadable.count == recentFiles.count
                ? "Claude Code transcripts changed format. Titles, models and context may be missing until AgentDeck is updated."
                : nil
        }

        // Sessions owned by the Claude desktop app open there, on the exact session.
        let desktop = desktopSessions.index()
        for i in agents.indices {
            guard let e = desktop[agents[i].sessionID], !e.archived else { continue }
            agents[i].hostApp = "Claude"
            agents[i].hostSessionID = e.localID
            agents[i].kindLabel = "Claude app"
            if let t = e.title, !t.isEmpty { agents[i].title = t }
            if !agents[i].status.isLive {
                agents[i].statusDetail = agents[i].status == .failed ? agents[i].statusDetail : "Not running. Focus opens it in the Claude app."
            }
        }
        return agents
    }

    private func baseAgent(sessionID: String, transcript t: ClaudeTranscriptSummary?) -> Agent {
        let cwd = t?.cwd
        var branch = t?.gitBranch
        if let cwd, let b = GitInfo.branch(at: cwd) { branch = b }
        return Agent(provider: .claudeCode, sessionID: sessionID, handle: nil,
                     title: t?.title ?? t?.firstPrompt.map { String($0.prefix(80)) } ?? "Claude Code session",
                     model: t?.model, workingDirectory: cwd, gitBranch: branch, status: .unknown, statusDetail: nil,
                     ownership: .discovered, capabilities: [], createdAt: nil, startedAt: nil, lastActivity: nil,
                     pid: nil, kindLabel: nil, lastMessage: t?.lastAssistantText, pendingPermission: nil,
                     stats: t?.contextTokens.map { AgentStats(contextTokens: $0) })
    }

    private func mapLive(status: String?, state: String?, alive: Bool, sessionID: String, transcript: ClaudeTranscriptSummary?) -> (AgentStatus, String?) {
        if !alive { return (.stopped, "Process exited.") }
        let st = (state ?? "").lowercased()
        let s = (status ?? "").lowercased()
        // Hook-derived waiting states are the most precise signal we have.
        lock.lock(); let hook = hookState[sessionID]; lock.unlock()
        if let hook, hook.0.isWaiting { return (hook.0, hook.1) }
        if st.contains("fail") || st.contains("error") { return (.failed, transcript?.lastErrorText ?? "Background session reported \(st).") }
        if st.contains("stop") || st.contains("kill") || st.contains("exit") { return (.stopped, "Background session \(st).") }
        if st.contains("done") || st.contains("complete") { return (.completed, "Finished its task. Attach to continue the conversation.") }
        if st.contains("input") || st.contains("wait") || st.contains("block") || st.contains("need") {
            return (st.contains("perm") || st.contains("approv") ? .waitingApproval : .waitingInput, "Background session: \(st).")
        }
        if s == "busy" || s.contains("run") || s.contains("work") { return (.working, nil) }
        if s == "idle" { return (.idle, "Ready for your next instruction.") }
        if let hook { return (hook.0, hook.1) }
        return (.unknown, status.map { "Status reported: \($0)" })
    }

    private func ingestHooks() {
        let events = hooks.drain()
        guard !events.isEmpty else { return }
        lock.lock()
        for e in events {
            switch e.event {
            case "PermissionRequest":
                hookState[e.sessionID] = (.waitingApproval, "Approval needed\(e.toolName.map { " for \($0)" } ?? "")", e.date)
                emit(e, .permissionRequested, "Requested permission\(e.toolName.map { " to use \($0)" } ?? "")")
            case "Notification":
                if e.notificationType == "permission_prompt" || (e.message ?? "").lowercased().contains("permission") {
                    hookState[e.sessionID] = (.waitingApproval, e.message, e.date)
                    emit(e, .permissionRequested, e.message ?? "Requested permission")
                } else if e.notificationType == "idle_prompt" {
                    hookState[e.sessionID] = (.waitingInput, e.message ?? "Waiting for your input", e.date)
                }
            case "UserPromptSubmit":
                hookState[e.sessionID] = (.working, nil, e.date)
                emit(e, .instruction, "Received new instructions")
            case "PreToolUse", "PostToolUse", "PostToolUseFailure":
                hookState[e.sessionID] = (.working, nil, e.date)
            case "Stop":
                hookState[e.sessionID] = (.idle, "Turn finished.", e.date)
            case "SessionEnd":
                hookState.removeValue(forKey: e.sessionID)
            default: break
            }
        }
        lock.unlock()
    }

    private func emit(_ e: ClaudeHooks.HookEvent, _ kind: AgentEventKind, _ msg: String) {
        signals?(.event(agentSessionID: e.sessionID, provider: .claudeCode, kind: kind, message: msg))
    }

    // MARK: Models & modes (parsed from the installed CLI — never hardcoded)

    private func help() async -> String {
        if let helpText { return helpText }
        guard let exe = executable ?? ProcessRunner.which("claude") else { return "" }
        let out = await ProcessRunner.run(exe, ["--help"], timeout: 10)
        helpText = out.stdout
        return out.stdout
    }

    func availableModels() async -> [ModelOption] {
        var options: [ModelOption] = []
        let text = await help()
        // "--model <model> … Provide an alias for the latest model (e.g. 'fable', 'opus', or 'sonnet')"
        if let r = text.range(of: "--model <model>") {
            let section = String(text[r.lowerBound...].prefix(400)).replacingOccurrences(of: "\n", with: " ")
            let aliasRegex = try! NSRegularExpression(pattern: "'([a-z0-9.-]+)'")
            for m in aliasRegex.matches(in: section, range: NSRange(section.startIndex..., in: section)) {
                if let rr = Range(m.range(at: 1), in: section) {
                    let alias = String(section[rr])
                    options.append(ModelOption(id: alias, name: "\(alias.capitalized) (latest)"))
                }
            }
        }
        // Full model names seen in your recent sessions.
        let recent = transcripts.transcriptFiles().sorted { $0.modified > $1.modified }.prefix(40)
        var seen = Set(options.map(\.id))
        for f in recent {
            if let m = transcripts.summary(sessionID: f.sessionID, path: f.path, modified: f.modified, size: f.size)?.model, !seen.contains(m) {
                seen.insert(m)
                options.append(ModelOption(id: m, name: m))
            }
        }
        return options
    }

    func launchModes() -> [ModeOption] {
        // Parsed from: --permission-mode <mode> (choices: "acceptEdits", "auto", …)
        guard let text = helpText, let r = text.range(of: "--permission-mode <mode>") else { return [] }
        let section = String(text[r.lowerBound...].prefix(300)).replacingOccurrences(of: "\n", with: " ")
        guard let c = section.range(of: "choices:") else { return [] }
        let after = section[c.upperBound...]
        let end = after.firstIndex(of: ")") ?? after.endIndex
        let choices = after[..<end].components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.filter { !$0.isEmpty }
        let notes: [String: String] = [
            "plan": "Read-only planning; no edits.",
            "acceptEdits": "Auto-accept file edits; still asks for commands.",
            "manual": "Ask before every action.",
            "auto": "Claude's auto mode classifier decides.",
            "dontAsk": "Deny anything not pre-approved.",
            "bypassPermissions": "Skips all permission checks — not recommended.",
        ]
        return choices.map { ModeOption(id: $0, name: $0, detail: notes[$0] ?? "") }
    }

    // MARK: Actions

    private func exe() throws -> String {
        guard let e = executable ?? ProcessRunner.which("claude") else { throw AgentDeckError.notInstalled("Claude Code CLI (`claude`) not found.") }
        return e
    }

    func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        if request.mode == .app {
            // The Claude app's own new-session link opens the Code tab with the folder and prompt filled in.
            // You start it there, so it runs with the model and permission settings you pick in the app.
            var c = URLComponents()
            c.scheme = "claude"; c.host = "code"; c.path = "/new"
            c.queryItems = [URLQueryItem(name: "q", value: request.prompt), URLQueryItem(name: "folder", value: request.workingDirectory)]
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = c.url else { throw AgentDeckError.unsupported("Could not build the Claude app link.") }
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            guard ok else { throw AgentDeckError.notInstalled("The Claude app did not accept the new-session link. Is it installed?") }
            return LaunchResult(sessionID: nil, handle: nil,
                                commandDescription: "Claude app → new session in \(URL(fileURLWithPath: request.workingDirectory).lastPathComponent)",
                                message: "Opened in the Claude app with your prompt filled in. Press Enter there to start it.")
        }
        let exe = try exe()
        _ = await help()
        var args: [String] = []
        if let t = request.title, !t.isEmpty { args += ["-n", t] }
        if let m = request.model, !m.isEmpty { args += ["--model", m] }
        if let p = request.permissionMode, !p.isEmpty { args += ["--permission-mode", p] }
        if request.worktree { args += ["--worktree"] }

        switch request.mode {
        case .app: fatalError("handled above")
        case .managed:
            args = ["--bg"] + args + [request.prompt]
            let desc = TerminalLauncher.describe(exe, args, cwd: request.workingDirectory)
            let out = await ProcessRunner.run(exe, args, cwd: request.workingDirectory, timeout: 45)
            let text = out.stdout + out.stderr
            if text.contains("not trusted") {
                throw AgentDeckError.commandFailed("Claude Code has not been trusted in this folder yet. Open it once in a terminal (`claude` in \(request.workingDirectory)) and accept the trust prompt, or launch with “Terminal” mode.")
            }
            // "backgrounded · 19f6d592 · name"
            let handle = text.components(separatedBy: "\n").first { $0.contains("backgrounded") }?
                .components(separatedBy: "·").dropFirst().first?.trimmingCharacters(in: .whitespaces)
            guard out.status == 0, let handle else {
                throw AgentDeckError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400).description)
            }
            signals?(.needsRefresh(.claudeCode))
            return LaunchResult(sessionID: nil, handle: handle, commandDescription: desc, message: nil)
        case .terminal:
            let sid = UUID().uuidString.lowercased()
            args = ["--session-id", sid] + args + [request.prompt]
            let desc = TerminalLauncher.describe(exe, args, cwd: request.workingDirectory)
            let terminal = prefs.terminalBundleID
            let finalArgs = args
            try await MainActor.run {
                try TerminalLauncher.open(executable: exe, arguments: finalArgs, cwd: request.workingDirectory, title: request.title ?? "Claude Code", terminalBundleID: terminal)
            }
            return LaunchResult(sessionID: sid, handle: nil, commandDescription: desc, message: "Opened in your terminal. It runs under your terminal, so AgentDeck monitors it but cannot stop it.")
        }
    }

    func stop(_ agent: Agent) async throws {
        guard let handle = agent.handle, agent.kindLabel == "Background" else {
            throw AgentDeckError.unsupported("Interactive Claude Code sessions are owned by their terminal. Stop them there (Esc / Ctrl-C).")
        }
        let out = await ProcessRunner.run(try exe(), ["stop", handle], timeout: 20)
        if out.status != 0 { throw AgentDeckError.commandFailed((out.stderr + out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)) }
        signals?(.needsRefresh(.claudeCode))
    }

    func focus(_ agent: Agent) async throws {
        if agent.hostApp == "Claude", let local = agent.hostSessionID, let url = ClaudeDesktopSessions.deepLink(local) {
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            if ok { return }
            throw AgentDeckError.unsupported("The Claude app did not accept the link to this session.")
        }
        if agent.kindLabel == "Background", let handle = agent.handle {
            let exe = try exe(); let terminal = prefs.terminalBundleID
            try await MainActor.run {
                try TerminalLauncher.open(executable: exe, arguments: ["attach", handle], cwd: agent.workingDirectory, title: agent.title, terminalBundleID: terminal)
            }
            return
        }
        if agent.status.isLive, let pid = agent.pid,
           let info = ProcessInspector.info(pid), let host = ProcessInspector.hostingAppPID(for: info.ppid) {
            let ok = await MainActor.run { TerminalLauncher.activate(pid: host) }
            if ok { return }
        }
        if agent.status.isLive {
            throw AgentDeckError.unsupported("This session is running, but AgentDeck could not find the window hosting it.")
        }
        try await resume(agent)
    }

    func resume(_ agent: Agent) async throws {
        let exe = try exe(); let terminal = prefs.terminalBundleID
        let cwd = agent.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        try await MainActor.run {
            try TerminalLauncher.open(executable: exe, arguments: ["--resume", agent.sessionID], cwd: cwd, title: agent.title, terminalBundleID: terminal)
        }
    }
}
