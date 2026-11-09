import XCTest
import SQLite3
@testable import AgentDeck

/// Fixture tests for the provider formats AgentDeck reads but nobody documents: Claude Code transcripts,
/// the Claude app's session files and Cursor's state database. Fixtures mirror real records seen on disk
/// (trimmed to the fields AgentDeck uses). When a provider update breaks a reader, refresh the fixture from a
/// real file and fix the reader until these pass.
final class FormatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to rel: String) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Claude Code transcripts

    func testClaudeTranscriptSummary() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-09T10:00:00.000Z","cwd":"/tmp/proj","gitBranch":"feature/x","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"custom-title","customTitle":"Login bug"}"#,
            #"{"type":"assistant","timestamp":"2026-11-09T10:00:05.000Z","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Looking at auth.ts"}],"usage":{"input_tokens":12,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":300}}}"#,
            #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-09T10:00:06.000Z","message":{"model":"claude-haiku-5-5","content":[{"type":"text","text":"subagent"}]}}"#,
        ]
        let url = try write(lines.joined(separator: "\n") + "\n", to: "projects/-tmp-proj/abc.jsonl")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let index = ClaudeTranscriptIndex(projectsDir: dir.appendingPathComponent("projects").path)
        let s = try XCTUnwrap(index.summary(sessionID: "abc", path: url.path,
                                            modified: attrs[.modificationDate] as! Date, size: (attrs[.size] as! NSNumber).intValue))
        XCTAssertEqual(s.title, "Login bug")
        XCTAssertEqual(s.firstPrompt, "Fix the login bug")
        XCTAssertEqual(s.model, "claude-opus-5-5", "sidechain (subagent) messages must not override the model")
        XCTAssertEqual(s.cwd, "/tmp/proj")
        XCTAssertEqual(s.gitBranch, "feature/x")
        XCTAssertEqual(s.contextTokens, 42_012)
        XCTAssertEqual(s.lastAssistantText, "Looking at auth.ts")
        XCTAssertNotNil(s.lastTimestamp)
        XCTAssertEqual(index.transcriptFiles().map(\.sessionID), ["abc"])
    }

    func testClaudeTranscriptApiError() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-09T10:00:00.000Z","message":{"content":"hi"}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-09T10:00:01.000Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"Rate limited"}]}}"#,
        ]
        let url = try write(lines.joined(separator: "\n"), to: "projects/p/err.jsonl")
        let s = try XCTUnwrap(ClaudeTranscriptIndex(projectsDir: dir.path).summary(sessionID: "err", path: url.path, modified: Date(), size: 10))
        XCTAssertEqual(s.lastErrorText, "Rate limited")
        XCTAssertNil(s.model, "synthetic models are ignored")
    }

    // MARK: Claude app sessions

    func testClaudeDesktopSessions() throws {
        let json = #"{"sessionId":"local_568cb93e-d432-4ee1-a94e-6dbc7ab989c1","cliSessionId":"5792fa3a-b682-45e8-b781-e52b37f20ee9","lastAssistantCliSessionId":"6792fa3a-b682-45e8-b781-e52b37f20ee9","title":"Release update","isArchived":false,"cwd":"/tmp/x"}"#
        _ = try write(json, to: "sessions/acct/org/local_568cb93e-d432-4ee1-a94e-6dbc7ab989c1.json")
        let d = ClaudeDesktopSessions(root: dir.appendingPathComponent("sessions").path)
        let idx = d.index()
        XCTAssertEqual(idx["5792fa3a-b682-45e8-b781-e52b37f20ee9"]?.localID, "local_568cb93e-d432-4ee1-a94e-6dbc7ab989c1")
        XCTAssertEqual(idx["6792fa3a-b682-45e8-b781-e52b37f20ee9"]?.title, "Release update")
        XCTAssertNil(d.formatWarning)
        XCTAssertEqual(ClaudeDesktopSessions.deepLink("local_568cb93e-d432-4ee1-a94e-6dbc7ab989c1")?.absoluteString,
                       "claude://code/continue?session=local_568cb93e-d432-4ee1-a94e-6dbc7ab989c1")
    }

    func testClaudeDesktopSessionsFormatChange() throws {
        _ = try write(#"{"id":"something-else"}"#, to: "sessions/acct/org/local_1.json")
        let d = ClaudeDesktopSessions(root: dir.appendingPathComponent("sessions").path)
        XCTAssertTrue(d.index().isEmpty)
        XCTAssertNotNil(d.formatWarning, "files that exist but can't be read must raise a warning")
    }

    // MARK: Cursor app chats

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK { XCTFail(String(cString: err!)) }
    }

    private func makeCursorDB(updatedMsAgo: Double, status: String, toolStatus: String?, toolName: String = "run_terminal_command_v2",
                              blocking: Bool = false) throws -> String {
        let path = dir.appendingPathComponent("state-\(UUID().uuidString).vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        exec(db, "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);")
        let id = "7dc24482-4c28-4cf1-ba19-34368e72473d"
        let now = Date().timeIntervalSince1970 * 1000
        let updated = Int64(now - updatedMsAgo)
        let header = """
        {"type":"head","composerId":"\(id)","name":"BFF contract review","unifiedMode":"agent","contextUsagePercent":68.9,"totalLinesAdded":196,"totalLinesRemoved":31,"filesChangedCount":10,"subtitle":"Edited index.tsx","hasBlockingPendingActions":\(blocking),"hasPendingPlan":false,"workspaceIdentifier":{"id":"w","uri":{"fsPath":"/tmp/proj"}}}
        """
        exec(db, "INSERT INTO composerHeaders VALUES ('\(id)','w',\(updated - 60000),\(updated),0,0,\(updated),\(updated),'\(header)',NULL);")
        let data = #"{"status":"\#(status)","modelConfig":{"modelName":"grok-4.7"},"generatingBubbleIds":[],"contextTokensUsed":176000}"#
        exec(db, "INSERT INTO cursorDiskKV VALUES ('composerData:\(id)','\(data)');")
        if let toolStatus {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let created = iso.string(from: Date(timeIntervalSince1970: Double(updated) / 1000))
            let bubble = #"{"type":2,"createdAt":"\#(created)","toolFormerData":{"status":"\#(toolStatus)","name":"\#(toolName)"}}"#
            exec(db, "INSERT INTO cursorDiskKV VALUES ('bubbleId:\(id):b1','\(bubble)');")
        }
        return path
    }

    func testCursorChatRunningWhileStoredStatusIsStale() throws {
        // Real behaviour: while a turn runs, `status` keeps the previous turn's value ("aborted").
        let path = try makeCursorDB(updatedMsAgo: 5_000, status: "aborted", toolStatus: "completed")
        let a = try XCTUnwrap(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: true).first)
        XCTAssertEqual(a.title, "BFF contract review")
        XCTAssertEqual(a.workingDirectory, "/tmp/proj")
        XCTAssertEqual(a.model, "grok-4.7")
        XCTAssertEqual(a.status, .working)
        XCTAssertEqual(a.hostApp, "Cursor")
        XCTAssertEqual(a.stats?.linesAdded, 196)
        XCTAssertEqual(a.stats?.linesRemoved, 31)
        XCTAssertEqual(a.stats?.filesChanged, 10)
        XCTAssertEqual(a.stats?.contextTokens, 176_000)
        XCTAssertEqual(a.stats?.contextPercent ?? 0, 68.9, accuracy: 0.01)
    }

    func testCursorChatLongToolCallStaysWorking() throws {
        let path = try makeCursorDB(updatedMsAgo: 10 * 60_000, status: "completed", toolStatus: "loading")
        XCTAssertEqual(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: true).first?.status, .working)
    }

    func testCursorChatQuestionIsWaitingForInput() throws {
        let path = try makeCursorDB(updatedMsAgo: 2_000, status: "completed", toolStatus: "loading", toolName: "ask_question")
        XCTAssertEqual(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: true).first?.status, .waitingInput)
    }

    func testCursorChatBlockingIsWaitingForApproval() throws {
        let path = try makeCursorDB(updatedMsAgo: 2_000, status: "completed", toolStatus: "loading", blocking: true)
        XCTAssertEqual(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: true).first?.status, .waitingApproval)
    }

    func testCursorChatFinished() throws {
        let path = try makeCursorDB(updatedMsAgo: 5 * 60_000, status: "completed", toolStatus: "completed")
        XCTAssertEqual(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: true).first?.status, .completed)
        let aborted = try makeCursorDB(updatedMsAgo: 5 * 60_000, status: "aborted", toolStatus: nil)
        XCTAssertEqual(CursorAppChats(dbPath: aborted).agents(window: 86_400, appRunning: true).first?.status, .stopped)
    }

    func testCursorChatMidRunWhenCursorQuit() throws {
        let path = try makeCursorDB(updatedMsAgo: 5_000, status: "aborted", toolStatus: "loading")
        XCTAssertEqual(CursorAppChats(dbPath: path).agents(window: 86_400, appRunning: false).first?.status, .unknown)
    }

    func testCursorFormatChangeRaisesWarning() throws {
        let path = dir.appendingPathComponent("other.vscdb").path
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        exec(db, "CREATE TABLE somethingElse (x TEXT);")
        sqlite3_close(db)
        let chats = CursorAppChats(dbPath: path)
        XCTAssertTrue(chats.agents(window: 86_400, appRunning: true).isEmpty)
        XCTAssertNotNil(chats.formatWarning)
    }

    // MARK: Git links

    func testGitLabRemoteLinks() throws {
        _ = try write("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@gitlab.example.co:team/app.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
                      to: "repo/.git/config")
        _ = try write("ref: refs/heads/feature/WL-1\n", to: "repo/.git/HEAD")
        let repo = dir.appendingPathComponent("repo").path
        XCTAssertEqual(GitInfo.branch(at: repo), "feature/WL-1")
        XCTAssertEqual(GitInfo.branchURL(at: repo, branch: "feature/WL-1")?.absoluteString, "https://gitlab.example.co/team/app/-/tree/feature/WL-1")
        XCTAssertEqual(GitInfo.reviewURL(at: repo, branch: "feature/WL-1")?.url.absoluteString,
                       "https://gitlab.example.co/team/app/-/merge_requests?scope=all&state=all&source_branch=feature/WL-1")
    }

    func testGitHubHTTPSRemote() throws {
        _ = try write("[remote \"origin\"]\n\turl = https://github.com/acme/web.git\n", to: "gh/.git/config")
        _ = try write("ref: refs/heads/main\n", to: "gh/.git/HEAD")
        let repo = dir.appendingPathComponent("gh").path
        XCTAssertEqual(GitInfo.branchURL(at: repo, branch: "main")?.absoluteString, "https://github.com/acme/web/tree/main")
        XCTAssertEqual(GitInfo.reviewURL(at: repo, branch: "main")?.label, "Open pull request")
    }

    // MARK: Archive rules

    func testArchiveRules() {
        let archivable = AgentStatus.allCases.filter(\.isArchivable)
        XCTAssertEqual(Set(archivable), [.completed, .stopped, .idle], "working, waiting, failed and unknown agents must never be archived")
        let active = AgentStatus.allCases.filter(\.isActive)
        XCTAssertEqual(Set(active), [.working, .waitingApproval, .waitingInput], "these bring an archived agent back")
    }

    // MARK: Presentation of real numbers

    func testStatsLine() {
        XCTAssertEqual(StatsText.line(AgentStats(contextPercent: 68.9, linesAdded: 196, linesRemoved: 31, filesChanged: 10)),
                       "+196 −31 · 10 files · 69% context")
        XCTAssertEqual(StatsText.line(AgentStats(contextTokens: 84_500)), "84k context")
        XCTAssertNil(StatsText.line(AgentStats()))
    }
}
