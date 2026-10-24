import Foundation
import Testing

@testable import UsageCore

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[URL]] = []
    func record(_ paths: [URL]) { lock.lock(); defer { lock.unlock() }; _calls.append(paths) }
    var calls: [[URL]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _calls.count }
}

@Suite struct FSEventsWatcherDebounceTests {
    @Test func burstOfBatchesWithinWindowCoalescesToOneCallback() async throws {
        let counter = CallbackCounter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debounce-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = FSEventsWatcher(roots: [root]) { paths in
            counter.record(paths)
        }
        watcher.start()

        let expected = Set((0..<10).map { URL(fileURLWithPath: "\(root.path)/file-\($0).jsonl") })
        for i in 0..<10 {
            let paths = [URL(fileURLWithPath: "\(root.path)/file-\(i).jsonl")]
            watcher.deliver(paths)
        }

        try await Task.sleep(for: .milliseconds(500))

        #expect(counter.callCount == 1)
        let delivered = Set(counter.calls[0])
        #expect(delivered.isSuperset(of: expected))

        watcher.stop()
    }

    @Test func separatedBatchesProduceSeparateCallbacks() async throws {
        let counter = CallbackCounter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debounce-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = FSEventsWatcher(roots: [root]) { paths in
            counter.record(paths)
        }
        watcher.start()

        let a = URL(fileURLWithPath: "\(root.path)/a.jsonl")
        let b = URL(fileURLWithPath: "\(root.path)/b.jsonl")
        watcher.deliver([a])
        try await Task.sleep(for: .milliseconds(400))
        watcher.deliver([b])
        try await Task.sleep(for: .milliseconds(400))

        #expect(counter.callCount == 2)
        #expect(Set(counter.calls[0]).contains(a))
        #expect(Set(counter.calls[1]).contains(b))

        watcher.stop()
    }
}
