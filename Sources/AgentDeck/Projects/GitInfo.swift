import Foundation

/// Lightweight Git inspection by reading `.git` metadata directly — no `git`
/// process per refresh. Handles linked worktrees (`.git` file with `gitdir:`).
enum GitInfo {
    struct Repo: Hashable, Sendable {
        var root: String          // working tree root containing the path
        var mainRoot: String      // primary checkout (same as root unless a linked worktree)
        var gitDir: String
        var isWorktree: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Repo?] = [:]

    static func repo(containing path: String) -> Repo? {
        lock.lock()
        if let hit = cache[path] { lock.unlock(); return hit }
        lock.unlock()
        let result = resolve(path)
        lock.lock(); cache[path] = result; lock.unlock()
        return result
    }

    private static func resolve(_ path: String) -> Repo? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<40 {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return Repo(root: url.path, mainRoot: url.path, gitDir: dotGit.path, isWorktree: false)
                }
                // Linked worktree: ".git" file -> "gitdir: /main/.git/worktrees/<name>"
                if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if !gitDir.hasPrefix("/") { gitDir = url.appendingPathComponent(gitDir).standardizedFileURL.path }
                    var main = url.path
                    if let r = gitDir.range(of: "/.git/worktrees/") { main = String(gitDir[..<r.lowerBound]) }
                    else if let r = gitDir.range(of: "/.git/modules/") { main = String(gitDir[..<r.lowerBound]) }
                    return Repo(root: url.path, mainRoot: main, gitDir: gitDir, isWorktree: main != url.path)
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    /// Current branch name, or short SHA when detached. Always read fresh.
    static func branch(at path: String) -> String? {
        guard let repo = repo(containing: path) else { return nil }
        guard let head = try? String(contentsOfFile: repo.gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        if trimmed.count >= 7 { return String(trimmed.prefix(7)) + " (detached)" }
        return nil
    }

    // MARK: Web links

    enum Host: Sendable { case github, gitlab, bitbucket, other }

    /// The `origin` remote as a web URL (https://host/owner/repo), read from the repo's config file.
    static func webRemote(at path: String) -> (url: URL, host: Host)? {
        guard let repo = repo(containing: path) else { return nil }
        // Linked worktrees share the main checkout's config.
        let common = repo.isWorktree ? repo.mainRoot + "/.git" : repo.gitDir
        guard let config = try? String(contentsOfFile: common + "/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        var raw: String?
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            if inOrigin, line.hasPrefix("url") , let eq = line.firstIndex(of: "=") {
                raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces); break
            }
        }
        guard var r = raw else { return nil }
        if r.hasSuffix(".git") { r.removeLast(4) }
        // git@host:owner/repo  |  ssh://git@host[:port]/owner/repo  |  https://[user@]host/owner/repo
        var hostPart: String, pathPart: String
        if r.hasPrefix("git@"), let colon = r.firstIndex(of: ":") {
            hostPart = String(r[r.index(r.startIndex, offsetBy: 4)..<colon]); pathPart = String(r[r.index(after: colon)...])
        } else if let u = URL(string: r), let h = u.host {
            hostPart = h; pathPart = String(u.path.drop(while: { $0 == "/" }))
        } else { return nil }
        guard !hostPart.isEmpty, !pathPart.isEmpty, let url = URL(string: "https://\(hostPart)/\(pathPart)") else { return nil }
        let h = hostPart.lowercased()
        let kind: Host = h.contains("github") ? .github : h.contains("gitlab") ? .gitlab : h.contains("bitbucket") ? .bitbucket : .other
        return (url, kind)
    }

    private static func encode(_ branch: String) -> String {
        branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? branch
    }

    /// Branch page on the hosting service, when the host is recognised.
    static func branchURL(at path: String, branch: String) -> URL? {
        guard let (base, host) = webRemote(at: path), !branch.contains("(detached)") else { return nil }
        switch host {
        case .github: return URL(string: base.absoluteString + "/tree/" + encode(branch))
        case .gitlab: return URL(string: base.absoluteString + "/-/tree/" + encode(branch))
        case .bitbucket: return URL(string: base.absoluteString + "/branch/" + encode(branch))
        case .other: return nil
        }
    }

    /// The hosting service's page for opening (or finding) a pull / merge request from this branch.
    static func reviewURL(at path: String, branch: String) -> (url: URL, label: String)? {
        guard let (base, host) = webRemote(at: path), !branch.contains("(detached)") else { return nil }
        let q = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? branch
        switch host {
        case .github: return URL(string: base.absoluteString + "/pulls?q=is%3Apr+head%3A" + q).map { ($0, "Open pull request") }
        case .gitlab: return URL(string: base.absoluteString + "/-/merge_requests?scope=all&state=all&source_branch=" + q).map { ($0, "Open merge request") }
        case .bitbucket: return URL(string: base.absoluteString + "/pull-requests?query=" + q).map { ($0, "Open pull request") }
        case .other: return nil
        }
    }

    static func isRepository(_ path: String) -> Bool { repo(containing: path)?.root == URL(fileURLWithPath: path).standardizedFileURL.path }
}
