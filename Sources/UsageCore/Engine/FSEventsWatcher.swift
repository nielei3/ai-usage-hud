import CoreServices
import Foundation

/// One FSEvents stream per root directory (fileEvents, 0.5s latency, background
/// queue). Changed paths accumulate in a Set and are delivered as one batch
/// after a 300ms debounce; a 60s timer backstop re-derives the candidate set
/// in case coalescing swallows an event.
public final class FSEventsWatcher: @unchecked Sendable {
    private let roots: [URL]
    private let onChange: @Sendable ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let sweepTimer: DispatchSourceTimer
    private var sweepRunning = false
    private let debounceTimer: DispatchSourceTimer
    private var pendingPaths = Set<URL>()

    /// Char-pointer interpretation: the stream is created WITHOUT
    /// kFSEventStreamCreateFlagUseCFTypes, so `paths` is a
    /// `UnsafePointer<UnsafePointer<CChar>?>` — dereferencing it as CF types
    /// would hand back garbage pointers.
    public init(roots: [URL], onChange: @escaping @Sendable ([URL]) -> Void) {
        self.roots = roots
        self.onChange = onChange
        self.queue = DispatchQueue(label: "usage-hud.fsevents", qos: .utility)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        sweepTimer = timer
        let debounce = DispatchSource.makeTimerSource(queue: queue)
        debounceTimer = debounce

        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onChange(self.roots)
        }

        debounce.setEventHandler { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            self.onChange(paths)
        }
    }

    public func start() {
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let raw = UnsafeBufferPointer(start: paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self), count: count)
            let changed = raw.compactMap { $0.map { URL(fileURLWithPath: String(cString: $0)) } }
            guard !changed.isEmpty else { return }
            watcher.deliver(changed)
        }

        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let rootPaths = roots.map(\.path) as CFArray
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, rootPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else {
            // No stream → the 60s sweep is the only change signal; keep it alive.
            resumeSweep()
            debounceTimer.resume()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        resumeSweep()
        debounceTimer.resume()
    }

    public func deliver(_ paths: [URL]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingPaths.formUnion(paths)
            self.debounceTimer.schedule(deadline: .now() + .milliseconds(300), repeating: .never)
        }
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        self.stream = nil
        sweepTimer.cancel()
        sweepRunning = false
        debounceTimer.cancel()
    }

    private func resumeSweep() {
        guard !sweepRunning else { return }
        sweepRunning = true
        sweepTimer.resume()
    }

    deinit { stop() }
}
