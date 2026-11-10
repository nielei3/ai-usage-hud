import Foundation
import Testing

@testable import UsageCore

private func tempClaudeFile(_ content: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString).jsonl")
    try! Data(content.utf8).write(to: url)
    return url
}

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [UsageSnapshot] = []
    func append(_ s: UsageSnapshot) { lock.lock(); defer { lock.unlock() }; _snapshots.append(s) }
    var snapshots: [UsageSnapshot] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    func clear() { lock.lock(); defer { lock.unlock() }; _snapshots.removeAll() }
}

@Suite struct QuotaSnapshotTests {
    @Test func setQuotaIsReflectedInSnapshot() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudeFile = tempClaudeFile(
            #"{"type":"assistant","timestamp":"2026-10-01T00:00:00Z","sessionId":"s1","message":{"model":"m","usage":{"input_tokens":100,"output_tokens":50}}}"# + "\n"
        )
        defer { try? FileManager.default.removeItem(at: claudeFile) }

        let engine = UsageEngine(
            feed: .init(
                claudeRoot: dir,
                codexRoot: dir,
                claudeUsageCache: dir.appendingPathComponent("cache.json"),
                snapshotCacheURL: dir.appendingPathComponent("snapshot.json")
            ),
            clock: SystemClock()
        )

        let collector = SnapshotCollector()
        await engine.setSink { collector.append($0) }
        await engine.start()

        let quota = QuotaSnapshot(
            claude: ClaudeUsageFetcher.UsageData(
                fiveHourPercent: 42.0,
                creditUsedUsd: 5.0,
                creditLimitUsd: 100.0
            ),
            codex: CodexUsageFetcher.CreditData(
                used: 3.0,
                limit: 50.0
            )
        )
        await engine.setQuota(quota)
        collector.clear()
        await engine.tailPulse(changed: [claudeFile])

        let snaps = collector.snapshots
        #expect(!snaps.isEmpty)
        let snap = snaps.last!
        #expect(snap.claude.fiveHourPercent == 42.0)
        #expect(snap.claude.creditUsedUsd == 5.0)
        #expect(snap.claude.creditLimitUsd == 100.0)
        #expect(snap.codex.creditBalance == 3.0)
        #expect(snap.codex.creditLimit == 50.0)
    }

    @Test func liveCodexRateLimitsOverrideSessionWindowsInSnapshot() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-live-codex-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let codexFile = dir.appendingPathComponent("codex.jsonl")
        let sessionWindow = #"{"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1}},"rate_limits":{"primary":{"window_minutes":300,"used_percent":25,"resets_at":1800000000}}}}"#
        try! Data((sessionWindow + "\n").utf8).write(to: codexFile)

        let engine = UsageEngine(
            feed: .init(
                claudeRoot: dir,
                codexRoot: dir,
                claudeUsageCache: dir.appendingPathComponent("cache.json"),
                snapshotCacheURL: dir.appendingPathComponent("snapshot.json")
            ),
            clock: SystemClock()
        )
        let collector = SnapshotCollector()
        await engine.setSink { collector.append($0) }
        await engine.setQuota(QuotaSnapshot(codex: CodexUsageFetcher.CreditData(
            rateLimits: [RateLimitWindow(
                windowMinutes: 10_080,
                usedPercent: 100,
                resetsAt: Date(timeIntervalSince1970: 1_800_863_999)
            )]
        )))
        await engine.rescanAll()

        let limits = collector.snapshots.last!.codex.rateLimits
        #expect(limits.map(\.windowMinutes) == [10_080])
        #expect(limits.map(\.usedPercent) == [100])
        #expect(limits.first?.resetsAt == Date(timeIntervalSince1970: 1_800_863_999))
    }

    @Test func emptyLiveCodexQuotaKeepsSessionWindowsInSnapshot() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-session-codex-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let codexFile = dir.appendingPathComponent("codex.jsonl")
        let sessionWindow = #"{"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1}},"rate_limits":{"primary":{"window_minutes":300,"used_percent":25,"resets_at":1800000000}}}}"#
        try! Data((sessionWindow + "\n").utf8).write(to: codexFile)

        let engine = UsageEngine(
            feed: .init(
                claudeRoot: dir,
                codexRoot: dir,
                claudeUsageCache: dir.appendingPathComponent("cache.json"),
                snapshotCacheURL: dir.appendingPathComponent("snapshot.json")
            ),
            clock: SystemClock()
        )
        let collector = SnapshotCollector()
        await engine.setSink { collector.append($0) }
        await engine.setQuota(QuotaSnapshot(codex: CodexUsageFetcher.CreditData()))
        await engine.rescanAll()

        let limits = collector.snapshots.last!.codex.rateLimits
        #expect(limits.map(\.windowMinutes) == [300])
        #expect(limits.map(\.usedPercent) == [25])
        #expect(limits.first?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func burstOfTailPulseWithEmptyQuotaNeverCrashes() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-burst-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = UsageEngine(
            feed: .init(
                claudeRoot: dir,
                codexRoot: dir,
                claudeUsageCache: dir.appendingPathComponent("cache.json"),
                snapshotCacheURL: dir.appendingPathComponent("snapshot.json")
            ),
            clock: SystemClock()
        )
        await engine.setSink { _ in }
        await engine.start()

        for _ in 0..<10 {
            await engine.tailPulse(changed: [])
        }
        #expect(Bool(true))
    }
}
