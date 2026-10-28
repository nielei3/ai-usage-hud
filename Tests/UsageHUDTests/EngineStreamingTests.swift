import Foundation
import Testing
import UsageCore

private final class StreamingSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UsageSnapshot?
    func append(_ snapshot: UsageSnapshot) { lock.lock(); defer { lock.unlock() }; value = snapshot }
    var last: UsageSnapshot { lock.lock(); defer { lock.unlock() }; return value! }
}

@Suite struct EngineStreamingTests {
    private let stamp = "2026-10-27T12:00:00Z"
    private var now: Date { ISO8601DateFormatter().date(from: stamp)! }

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build").appendingPathComponent("engine-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true)
        return root
    }

    private func engine(_ root: URL, snapshots: StreamingSnapshots) async -> UsageEngine {
        let engine = UsageEngine(feed: .init(
            claudeRoot: root.appendingPathComponent("claude"), codexRoot: root.appendingPathComponent("codex"),
            claudeUsageCache: root.appendingPathComponent("cache.json"),
            snapshotCacheURL: root.appendingPathComponent("snapshot.json")
        ), clock: ManualClock(start: now))
        await engine.setSink { snapshots.append($0) }
        return engine
    }

    private func claude(_ input: Int, session: String = "中文🙂") -> String {
        #"{"timestamp":"\#(stamp)","sessionId":"\#(session)","message":{"model":"m","usage":{"input_tokens":\#(input),"output_tokens":2}}}"#
    }

    private func codex(_ input: Int, last: Int? = nil, padding: String = "") -> String {
        let last = last.map { #", "last_token_usage":{"input_tokens":\#($0),"output_tokens":2}"# } ?? ""
        return #"{"timestamp":"\#(stamp)","type":"event_msg","padding":"\#(padding)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"output_tokens":10}\#(last)},"rate_limits":{"primary":{"window_minutes":300,"used_percent":25,"resets_at":1793102400},"secondary":{"window_minutes":10080,"used_percent":10,"resets_at":1793188800},"plan_type":"pro"}}}"#
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func coldPartialRecordCompletesExactlyOnceAcrossProviders() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("claude/c.jsonl")
        let x = root.appendingPathComponent("codex/x.jsonl")
        let cLine = claude(7)
        let xLine = codex(11)
        try Data(cLine.dropLast(3).utf8).write(to: c)
        try Data(xLine.dropLast(3).utf8).write(to: x)
        let snapshots = StreamingSnapshots()
        let engine = await engine(root, snapshots: snapshots)
        await engine.rescanAll()
        #expect(snapshots.last.claude.todayUsage.inputTokens == 0)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 0)
        try append(String(cLine.suffix(3)) + "\n", to: c)
        try append(String(xLine.suffix(3)) + "\n", to: x)
        await engine.tailPulse(changed: [c, x])
        #expect(snapshots.last.claude.todayUsage.inputTokens == 7)
        #expect(snapshots.last.claude.todayUsage.outputTokens == 2)
        #expect(snapshots.last.claude.activeSessions == 1)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 11)
        await engine.tailPulse(changed: [c, x])
        #expect(snapshots.last.claude.todayUsage.inputTokens == 7)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 11)
        await engine.rescanAll()
        #expect(snapshots.last.claude.todayUsage.inputTokens == 7)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 11)
    }

    @Test func truncationReplacesAggregatesAndCodexBaseline() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("claude/c.jsonl")
        let x = root.appendingPathComponent("codex/x.jsonl")
        try Data((claude(100, session: "old-session") + "\n" + claude(200) + "\n").utf8).write(to: c)
        try Data((codex(1000, padding: String(repeating: "x", count: 50)) + "\n").utf8).write(to: x)
        let snapshots = StreamingSnapshots()
        let engine = await engine(root, snapshots: snapshots)
        await engine.rescanAll()
        #expect(snapshots.last.claude.todayUsage.inputTokens == 300)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 1000)
        try Data((claude(3) + "\n").utf8).write(to: c)
        try Data((codex(5) + "\n").utf8).write(to: x)
        await engine.tailPulse(changed: [c, x])
        #expect(snapshots.last.claude.todayUsage.inputTokens == 3)
        #expect(snapshots.last.claude.blockUsage.inputTokens == 3)
        #expect(snapshots.last.claude.weeklyUsage.inputTokens == 3)
        #expect(snapshots.last.claude.activeSessions == 1)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 5)
        await engine.rescanAll()
        #expect(snapshots.last.claude.todayUsage.inputTokens == 3)
        #expect(snapshots.last.codex.todayUsage.inputTokens == 5)
    }

    @Test func burstPreservesTotalsSessionsAndRateWindowsAcrossRescan() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("claude/c.jsonl")
        let x = root.appendingPathComponent("codex/x.jsonl")
        try Data((claude(3) + "\n").utf8).write(to: c)
        try Data((codex(5, last: 5) + "\n").utf8).write(to: x)
        let snapshots = StreamingSnapshots()
        let engine = await engine(root, snapshots: snapshots)
        await engine.rescanAll()
        try append(String(repeating: claude(7) + "\n", count: 7000), to: c)
        try append(String(repeating: codex(12, last: 7) + "\n", count: 3500), to: x)
        await engine.tailPulse(changed: [c, x])
        let appended = snapshots.last
        #expect(appended.claude.todayUsage.inputTokens == 49_003)
        #expect(appended.claude.todayUsage.outputTokens == 14_002)
        #expect(appended.claude.blockUsage.inputTokens == 49_003)
        #expect(appended.claude.weeklyUsage.inputTokens == 49_003)
        #expect(appended.claude.activeSessions == 1)
        #expect(appended.codex.todayUsage.inputTokens == 24_505)
        #expect(appended.codex.todayUsage.outputTokens == 7_002)
        #expect(appended.codex.activeSessions == 1)
        #expect(appended.codex.planType == "pro")
        #expect(appended.codex.rateLimits.map(\.windowMinutes) == [300, 10080])
        #expect(appended.codex.rateLimits.map(\.usedPercent) == [25, 10])
        #expect(appended.codex.rateLimits.map(\.resetsAt) == [Date(timeIntervalSince1970: 1793102400), Date(timeIntervalSince1970: 1793188800)])
        await engine.rescanAll()
        #expect(snapshots.last == appended)
    }
}
