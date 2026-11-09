import AppKit

/// Opens commands in the user's terminal without requiring Automation (AppleScript)
/// permission: we write a small `.command` script and hand it to the terminal app.
/// The script is shown to the user verbatim via `commandDescription`.
enum TerminalLauncher {
    static let supportedTerminals: [(id: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.mitchellh.ghostty", "Ghostty"),
    ]

    static func installedTerminals() -> [(id: String, name: String)] {
        supportedTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// Quote an argument for POSIX shells.
    static func shellQuote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func describe(_ executable: String, _ args: [String], cwd: String?) -> String {
        let cmd = ([URL(fileURLWithPath: executable).lastPathComponent] + args).map(shellQuote).joined(separator: " ")
        if let cwd { return "cd \(shellQuote(cwd)) && \(cmd)" }
        return cmd
    }

    @MainActor
    static func open(executable: String, arguments: [String], cwd: String?, title: String, terminalBundleID: String) throws {
        let dir = Persistence.supportDirectory.appendingPathComponent("launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Clean up scripts older than a day.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if date < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: url) }
            }
        }
        let script = dir.appendingPathComponent("agentdeck-\(UUID().uuidString.prefix(8)).command")
        var body = "#!/bin/zsh -l\n"
        body += "printf '\\033]0;%s\\007' \(shellQuote(title))\n"
        body += "export PATH=\(shellQuote(ProcessRunner.searchPath))\n"
        if let cwd { body += "cd \(shellQuote(cwd)) || exit 1\n" }
        body += "echo \(shellQuote("AgentDeck ▸ " + describe(executable, arguments, cwd: nil)))\n"
        body += "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ") + "\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let ws = NSWorkspace.shared
        let appURL = ws.urlForApplication(withBundleIdentifier: terminalBundleID)
            ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let appURL else { throw AgentDeckError.notInstalled("No terminal application found.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        ws.open([script], withApplicationAt: appURL, configuration: config)
    }

    /// Bring a GUI app forward by PID.
    @MainActor
    @discardableResult
    static func activate(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    @MainActor
    static func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return app.activate()
    }
}
