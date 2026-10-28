import Foundation
import Testing

@testable import UsageCore

private func tempDir(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-tail-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func claudeLine(sessionId: String, input: Int, output: Int, offset: TimeInterval = 0) -> String {
    let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    return #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"\#(sessionId)","message":{"model":"m","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
}

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [UsageSnapshot] = []
    func append(_ s: UsageSnapshot) { lock.lock(); defer { lock.unlock() }; _snapshots.append(s) }
    var snapshots: [UsageSnapshot] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    func clear() { lock.lock(); defer { lock.unlock() }; _snapshots.removeAll() }
}

@Suite struct ClaudeIncrementalTailTests {
    @Test func tailPulseReadsOnlyNewBytesOnSecondCall() async throws {
        let claudeRoot = tempDir("claude-root")
        defer { try? FileManager.default.removeItem(at: claudeRoot) }

        let fileURL = claudeRoot.appendingPathComponent("session.jsonl")
        let firstLine = claudeLine(sessionId: "s1", input: 100, output: 50) + "\n"
        try Data(firstLine.utf8).write(to: fileURL)

        let codexRoot = tempDir("codex-empty")
        defer { try? FileManager.default.removeItem(at: codexRoot) }

        let engine = UsageEngine(
            feed: .init(
                claudeRoot: claudeRoot,
                codexRoot: codexRoot,
                claudeUsageCache: claudeRoot.appendingPathComponent("cache.json"),
                snapshotCacheURL: claudeRoot.appendingPathComponent("snapshot.json")
            ),
            clock: SystemClock()
        )

        let collector = SnapshotCollector()
        await engine.setSink { collector.append($0) }

        // First tailPulse establishes the stored offset (cold-start path).
        await engine.tailPulse(changed: [fileURL])
        let afterFirst = collector.snapshots.last!
        #expect(afterFirst.claude.todayUsage.inputTokens == 100)
        #expect(afterFirst.claude.todayUsage.outputTokens == 50)
        #expect(afterFirst.claude.activeSessions == 1)
        collector.clear()

        let secondLine = claudeLine(sessionId: "s2", input: 200, output: 100, offset: 60) + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondLine.utf8))
        try handle.close()

        // Second tailPulse reads only the new bytes and merges into the
        // existing aggregate (old + new), not replacing it.
        await engine.tailPulse(changed: [fileURL])

        let snaps = collector.snapshots
        #expect(!snaps.isEmpty)
        let snap = snaps.last!
        #expect(snap.claude.todayUsage.inputTokens == 300)
        #expect(snap.claude.todayUsage.outputTokens == 150)
        #expect(snap.claude.activeSessions == 2)
    }

    @Test func tailReaderAdvancesByteOffsetByDelta() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("incr-\(UUID().uuidString).jsonl")
        let first = "line1\nline2\n"
        try Data(first.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let firstRead = try TailReader.read(url: url, from: TailPosition())
        #expect(firstRead.newLines == ["line1", "line2"])
        #expect(firstRead.position.byteOffset == first.utf8.count)

        let append = "line3\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(append.utf8))
        try handle.close()

        let secondRead = try TailReader.read(url: url, from: firstRead.position)
        #expect(secondRead.newLines == ["line3"])
        #expect(secondRead.position.byteOffset == first.utf8.count + append.utf8.count)
    }
}
