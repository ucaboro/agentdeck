import Foundation
import Darwin

/// Runs short-lived CLI commands asynchronously with a timeout.
/// GUI apps inherit a minimal PATH, so we resolve the user's login-shell PATH once.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var cachedPath: String?

    /// Search path combining the login shell PATH with common install locations.
    static var searchPath: String {
        pathLock.lock(); defer { pathLock.unlock() }
        if let cachedPath { return cachedPath }
        let home = NSHomeDirectory()
        var parts = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cursor/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let shellPath = loginShellPath() {
            for p in shellPath.split(separator: ":").map(String.init) where !parts.contains(p) { parts.append(p) }
        }
        let joined = parts.joined(separator: ":")
        cachedPath = joined
        return joined
    }

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["NO_COLOR"] = "1"
        // Never let a stray API key in the environment silently switch agents
        // from the user's subscription login to API-billed execution.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CURSOR_API_KEY"] { env.removeValue(forKey: key) }
        return env
    }

    /// Locate an executable by name on the search path.
    static func which(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 15) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = environment
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let done = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in done.signal() }   // must be set before run() to avoid a race
                do { try p.run() } catch {
                    cont.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                    return
                }
                var timedOut = false
                let deadline = DispatchTime.now() + timeout
                if done.wait(timeout: deadline) == .timedOut {
                    timedOut = true
                    p.terminate()
                    _ = done.wait(timeout: .now() + 2)
                }
                _ = group.wait(timeout: .now() + 2)
                cont.resume(returning: Output(status: p.terminationStatus,
                                              stdout: String(decoding: outData, as: UTF8.self),
                                              stderr: String(decoding: errData, as: UTF8.self),
                                              timedOut: timedOut))
            }
        }
    }
}

/// Read-only inspection of local processes via libproc (no shelling out).
enum ProcessInspector {
    struct Info: Sendable {
        var pid: Int32
        var ppid: Int32
        var name: String
        var path: String
        var startTime: Date?
    }

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
    }

    static func info(_ pid: Int32) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? String(cString: pathBuf) : ""
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        return Info(pid: pid, ppid: Int32(bsd.pbi_ppid), name: name, path: path, startTime: start)
    }

    static func cwd(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        return withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { raw -> String? in
            let s = String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            return s.isEmpty ? nil : s
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Processes whose executable path contains `fragment`.
    static func processes(matching fragment: String) -> [Info] {
        allPIDs().compactMap { info($0) }.filter { $0.path.contains(fragment) }
    }

    /// Walk up the parent chain until we hit a process that is a regular GUI app.
    static func hostingAppPID(for pid: Int32) -> Int32? {
        var current = pid
        for _ in 0..<32 {
            guard let i = info(current) else { return nil }
            if i.path.contains(".app/Contents/MacOS/") { return current }
            if i.ppid <= 1 { return nil }
            current = i.ppid
        }
        return nil
    }
}
