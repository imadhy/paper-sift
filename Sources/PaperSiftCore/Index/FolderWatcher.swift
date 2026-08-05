import CoreServices
import Foundation

/// Watches folders with FSEvents and reports the paths that changed.
///
/// FSEvents coalesces bursts for us — `latency` is the window it batches over —
/// so a folder being unpacked produces a handful of callbacks, not thousands.
/// A dispatch queue rather than a run loop, so this works in the CLI too.
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let handler: Handler
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.imadhy.papersift.fsevents")
    private var stream: FSEventStreamRef?

    public init(latency: CFTimeInterval = 1.0, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    /// Replaces whatever was being watched with `paths`.
    public func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags)
        else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        handler(paths)
    }
}

/// FSEvents wants a C function pointer, which cannot capture anything — the
/// watcher travels through the context's `info` pointer instead.
private func folderWatcherCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    paths: UnsafeMutableRawPointer,
    flags: UnsafePointer<FSEventStreamEventFlags>,
    ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes means `paths` is a CFArray of CFStrings.
    let changed = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
    watcher.deliver(changed)
}
