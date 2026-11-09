import Foundation
import CoreServices

/// Thin FSEvents wrapper: event-driven refresh of provider data instead of
/// tight polling. Callbacks are coalesced by FSEvents latency.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "agentdeck.fsevents")

    init(paths: [String], latency: TimeInterval = 0.6, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
