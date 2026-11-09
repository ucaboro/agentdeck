import Foundation

/// Minimal Agent Client Protocol client: newline-delimited JSON-RPC 2.0 over the
/// stdio of `cursor-agent acp`. We advertise no fs / terminal capabilities, so
/// the agent uses its own tools and permission system; AgentDeck only relays
/// permission prompts to the user and never answers them on its own.
final class ACPClient: @unchecked Sendable {
    typealias JSON = [String: Any]

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var buffer = Data()
    private var stderrTail = ""
    private(set) var isRunning = false

    /// Notifications (method, params).
    var onNotification: (@Sendable (String, JSON) -> Void)?
    /// Agent → client requests (id, method, params). Must eventually be answered with `respond`.
    var onRequest: (@Sendable (Any, String, JSON) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    var pid: Int32 { process.processIdentifier }

    init(executable: String, cwd: String) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["acp"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessRunner.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.consume(d)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            self.isRunning = false
            let waiting = self.pending
            self.pending.removeAll()
            let tail = self.stderrTail
            self.lock.unlock()
            for (_, c) in waiting { c.resume(throwing: AgentDeckError.protocolError("Cursor agent process exited (\(p.terminationStatus)).")) }
            self.onExit?(p.terminationStatus, tail)
        }
        try process.run()
        isRunning = true
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: Messaging

    func request(_ method: String, _ params: JSON, timeout: TimeInterval? = nil) async throws -> Any {
        let id: Int = { lock.lock(); defer { lock.unlock() }; nextID += 1; return nextID }()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            guard isRunning else { lock.unlock(); cont.resume(throwing: AgentDeckError.protocolError("Cursor agent is not running.")); return }
            pending[id] = cont
            lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let c = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    c?.resume(throwing: AgentDeckError.protocolError("\(method) timed out."))
                }
            }
        }
    }

    func notify(_ method: String, _ params: JSON) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func respond(id: Any, result: JSON) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ obj: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? JSON else { return }
        let method = obj["method"] as? String
        if let method, let id = obj["id"] {
            onRequest?(id, method, obj["params"] as? JSON ?? [:])
        } else if let method {
            onNotification?(method, obj["params"] as? JSON ?? [:])
        } else if let id = (obj["id"] as? NSNumber)?.intValue {
            lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
            if let err = obj["error"] as? JSON {
                c?.resume(throwing: AgentDeckError.protocolError(err["message"] as? String ?? "ACP error"))
            } else {
                c?.resume(returning: obj["result"] ?? NSNull())
            }
        }
    }

    var lastStderr: String { lock.lock(); defer { lock.unlock() }; return stderrTail }
}
