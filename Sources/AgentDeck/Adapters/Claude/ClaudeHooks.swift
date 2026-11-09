import Foundation

/// Optional bridge to Claude Code's documented hooks system.
///
/// When the user opts in (Settings → Integrations), AgentDeck adds `command`
/// hooks to ~/.claude/settings.json that drop each hook payload into a private
/// spool folder. That gives precise lifecycle signals — notably permission
/// prompts — which `claude agents --json` does not expose.
/// The hook only writes files locally and always exits 0, so it can never
/// block, approve or deny anything in Claude Code.
final class ClaudeHooks: @unchecked Sendable {
    struct HookEvent: Sendable {
        var sessionID: String
        var event: String
        var notificationType: String?
        var message: String?
        var toolName: String?
        var cwd: String?
        var date: Date
    }

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                         "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    static let marker = "agentdeck-hook.sh"

    let hooksDir = Persistence.supportDirectory.appendingPathComponent("hooks", isDirectory: true)
    var spoolDir: URL { hooksDir.appendingPathComponent("spool", isDirectory: true) }
    var scriptURL: URL { hooksDir.appendingPathComponent(Self.marker) }
    let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")

    var hookCommand: String { "'" + scriptURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func ensureScript() throws {
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = """
        #!/bin/sh
        # AgentDeck hook relay: stores the hook payload for AgentDeck to read. Never blocks Claude Code.
        d="$HOME/Library/Application Support/AgentDeck/hooks/spool"
        [ -d "$d" ] || exit 0
        t=$(mktemp "$d/.evt.XXXXXX") || exit 0
        cat > "$t" && mv "$t" "$t.json"
        exit 0

        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentDeckError.commandFailed("~/.claude/settings.json is not a JSON object; not modifying it.")
        }
        return obj
    }

    var isInstalled: Bool {
        guard let s = try? loadSettings(), let hooks = s["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { ev in
            ((hooks[ev] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(Self.marker) == true }
            }
        }
    }

    /// Adds AgentDeck's relay to each lifecycle event, preserving every existing hook.
    /// A timestamped backup of settings.json is written first.
    func install() throws {
        try ensureScript()
        var settings = try loadSettings()
        try backup()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for ev in Self.events {
            var groups = (hooks[ev] as? [[String: Any]]) ?? []
            groups = strip(groups)
            groups.append(["matcher": "", "hooks": [["type": "command", "command": hookCommand, "timeout": 5]]])
            hooks[ev] = groups
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    func uninstall() throws {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        try backup()
        for (ev, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = strip(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = cleaned }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings)
    }

    private func strip(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var g = group
            let inner = ((group["hooks"] as? [[String: Any]]) ?? []).filter { ($0["command"] as? String)?.contains(Self.marker) != true }
            if inner.isEmpty { return nil }
            g["hooks"] = inner
            return g
        }
    }

    private func backup() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.agentdeck-backup-\(stamp)")
        try FileManager.default.copyItem(at: settingsURL, to: dest)
    }

    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Consume spooled hook payloads (oldest first) and delete them.
    func drain() -> [HookEvent] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        var out: [HookEvent] = []
        let sorted = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        for url in sorted {
            defer { try? fm.removeItem(at: url) }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["session_id"] as? String, let ev = obj["hook_event_name"] as? String else { continue }
            out.append(HookEvent(sessionID: sid, event: ev, notificationType: obj["notification_type"] as? String,
                                 message: obj["message"] as? String, toolName: obj["tool_name"] as? String,
                                 cwd: obj["cwd"] as? String, date: date))
        }
        return out
    }
}
