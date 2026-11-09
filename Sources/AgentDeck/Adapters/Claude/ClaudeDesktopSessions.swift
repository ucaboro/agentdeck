import Foundation

/// Maps Claude Code session ids to sessions owned by the Claude desktop app (Code tab), so
/// "Focus" can open that exact session in the app via its registered `claude://` URL scheme:
/// `claude://code/continue?session=local_<id>` (handled by Claude.app; it validates the id).
///
/// Reads `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`,
/// read-only, and keeps only ids, title and archive flag. Files are re-parsed only when their
/// modification date changes.
final class ClaudeDesktopSessions: @unchecked Sendable {
    struct Entry: Sendable { let localID: String; let title: String?; let archived: Bool }

    private let root: String
    private let lock = NSLock()
    private var _warning: String?
    /// Set when session files exist but none can be read any more.
    var formatWarning: String? { lock.withLock { _warning } }

    init(root: String = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions") {
        self.root = root
    }
    private var fileCache: [String: (Date, [String], Entry)] = [:]   // path → (mtime, cli ids, entry)

    /// cliSessionId → desktop session.
    func index() -> [String: Entry] {
        let fm = FileManager.default
        var out: [String: Entry] = [:]
        guard let accounts = try? fm.contentsOfDirectory(atPath: root) else { return out }
        var live = Set<String>()
        var parsed = 0
        for a in accounts {
            guard let orgs = try? fm.contentsOfDirectory(atPath: root + "/" + a) else { continue }
            for o in orgs {
                let dir = root + "/" + a + "/" + o
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    let path = dir + "/" + f
                    live.insert(path)
                    guard let (ids, entry) = read(path) else { continue }
                    parsed += 1
                    for id in ids { out[id] = entry }
                }
            }
        }
        let warning = !live.isEmpty && parsed == 0
            ? "The Claude app's session files changed format. Claude app sessions open in a terminal instead of the app until AgentDeck is updated."
            : nil
        lock.withLock { fileCache = fileCache.filter { live.contains($0.key) }; _warning = warning }
        return out
    }

    private func read(_ path: String) -> ([String], Entry)? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        if let c = lock.withLock({ fileCache[path] }), c.0 == mtime { return (c.1, c.2) }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let local = obj["sessionId"] as? String, local.hasPrefix("local_") else { return nil }
        let ids = [obj["cliSessionId"], obj["lastAssistantCliSessionId"]].compactMap { $0 as? String }
        let entry = Entry(localID: local, title: obj["title"] as? String, archived: obj["isArchived"] as? Bool ?? false)
        lock.withLock { fileCache[path] = (mtime, ids, entry) }
        return (ids, entry)
    }

    static func deepLink(_ localID: String) -> URL? {
        var c = URLComponents()
        c.scheme = "claude"; c.host = "code"; c.path = "/continue"
        c.queryItems = [URLQueryItem(name: "session", value: localID)]
        return c.url
    }
}
