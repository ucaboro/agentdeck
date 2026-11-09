import Foundation

/// Best-effort reader for Claude Code session transcripts (~/.claude/projects/<dir>/<session>.jsonl).
/// The format is not a stable public API, so every field is optional and
/// parsing failures simply yield less metadata — never a crash or wrong status.
struct ClaudeTranscriptSummary: Sendable {
    var sessionID: String
    var path: String
    var title: String?
    var firstPrompt: String?
    var model: String?
    var cwd: String?
    var gitBranch: String?
    var lastTimestamp: Date?
    var firstTimestamp: Date?
    var lastAssistantText: String?
    var lastErrorText: String?
    var modified: Date
    var userMessageCount: Int
    /// Context size of the latest main-thread turn: input + cache-read + cache-creation tokens, as recorded
    /// in that message's `usage`.
    var contextTokens: Int?
}

final class ClaudeTranscriptIndex: @unchecked Sendable {
    private struct CacheKey: Hashable { var path: String; var mtime: Date; var size: Int }
    private var cache: [String: (CacheKey, ClaudeTranscriptSummary)] = [:]
    private let lock = NSLock()

    let projectsDir: String

    init(projectsDir: String = NSHomeDirectory() + "/.claude/projects") {
        self.projectsDir = projectsDir
    }

    /// All top-level transcripts (subagent transcripts live in nested folders and are skipped).
    func transcriptFiles() -> [(sessionID: String, path: String, modified: Date, size: Int)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        var out: [(String, String, Date, Int)] = []
        for d in dirs {
            let dirPath = projectsDir + "/" + d
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let p = dirPath + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: p) else { continue }
                let m = attrs[.modificationDate] as? Date ?? .distantPast
                let s = (attrs[.size] as? NSNumber)?.intValue ?? 0
                out.append((String(f.dropLast(6)), p, m, s))
            }
        }
        return out
    }

    func summary(sessionID: String, path: String, modified: Date, size: Int) -> ClaudeTranscriptSummary? {
        let key = CacheKey(path: path, mtime: modified, size: size)
        lock.lock()
        if let (k, s) = cache[sessionID], k == key { lock.unlock(); return s }
        lock.unlock()
        guard let s = parse(sessionID: sessionID, path: path, modified: modified, size: size) else { return nil }
        lock.lock(); cache[sessionID] = (key, s); lock.unlock()
        return s
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parse(sessionID: String, path: String, modified: Date, size: Int) -> ClaudeTranscriptSummary? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var s = ClaudeTranscriptSummary(sessionID: sessionID, path: path, modified: modified, userMessageCount: 0)

        // Head: first prompt / start time. Tail: latest title, model, activity.
        let headData = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
        scan(headData, into: &s, isHead: true)
        let tailSize = 384 * 1024
        if size > headData.count {
            let offset = UInt64(max(0, size - tailSize))
            try? fh.seek(toOffset: offset)
            let tail = (try? fh.readToEnd()) ?? Data()
            scan(tail, into: &s, isHead: false, dropFirstLine: offset > 0)
        }
        return s
    }

    private func scan(_ data: Data, into s: inout ClaudeTranscriptSummary, isHead: Bool, dropFirstLine: Bool = false) {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if let ts = (obj["timestamp"] as? String).flatMap(Self.iso.date(from:)) {
                if s.firstTimestamp == nil { s.firstTimestamp = ts }
                if s.lastTimestamp.map({ ts > $0 }) ?? true { s.lastTimestamp = ts }
            }
            if let cwd = obj["cwd"] as? String { s.cwd = cwd }
            if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { s.gitBranch = b }
            if obj["isSidechain"] as? Bool == true { continue }
            switch type {
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { s.title = t }
            case "agent-name":
                if s.title == nil, let t = obj["agentName"] as? String, !t.isEmpty { s.title = t }
            case "summary":
                if s.title == nil, let t = obj["summary"] as? String, !t.isEmpty { s.title = t }
            case "user":
                if isHead { s.userMessageCount += 1 }
                if s.firstPrompt == nil, let text = Self.text(from: obj["message"]), !text.hasPrefix("<") {
                    s.firstPrompt = text
                }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let m = msg["model"] as? String, !m.hasPrefix("<") { s.model = m }
                if let u = msg["usage"] as? [String: Any] {
                    let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                        .compactMap { (u[$0] as? NSNumber)?.intValue }.reduce(0, +)
                    if n > 0 { s.contextTokens = n }
                }
                if obj["isApiErrorMessage"] as? Bool == true {
                    s.lastErrorText = Self.text(from: msg)
                } else if let t = Self.text(from: msg), !t.isEmpty {
                    s.lastAssistantText = t
                    s.lastErrorText = nil
                }
            default: break
            }
        }
    }

    static func text(from message: Any?) -> String? {
        guard let msg = message as? [String: Any] else { return nil }
        if let c = msg["content"] as? String { return clean(c) }
        if let parts = msg["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { return clean(texts.joined(separator: " ")) }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(240))
    }
}
