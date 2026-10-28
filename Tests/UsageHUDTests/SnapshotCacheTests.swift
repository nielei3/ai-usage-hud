import Foundation
import Testing
import UsageCore

private final class CacheSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UsageSnapshot] = []
    func append(_ snapshot: UsageSnapshot) { lock.lock(); defer { lock.unlock() }; values.append(snapshot) }
    var first: UsageSnapshot { lock.lock(); defer { lock.unlock() }; return values.first! }
    var last: UsageSnapshot { lock.lock(); defer { lock.unlock() }; return values.last! }
}

@Suite struct SnapshotCacheTests {
    @Test func injectedCacheLoadsAndPersistsSnapshotsWithinFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-cache-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache/snapshot.json")
        do {
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            let seed = #"{"claude":{"fiveHourPercent":17,"weeklyPercent":29,"creditUsedUsd":5,"creditLimitUsd":100},"codex":{"rateLimits":[],"creditBalance":3,"creditLimit":50}}"#
            try Data(seed.utf8).write(to: cache)
            let feed = UsageEngine.Feed(
                claudeRoot: root.appendingPathComponent("claude"),
                codexRoot: root.appendingPathComponent("codex"),
                claudeUsageCache: root.appendingPathComponent("usage.json"),
                snapshotCacheURL: cache
            )
            let engine = UsageEngine(feed: feed, clock: SystemClock())
            let loaded = CacheSnapshots()
            await engine.setSink { loaded.append($0) }
            await engine.start()
            #expect(loaded.first.claude.fiveHourPercent == 17)
            #expect(loaded.first.claude.weeklyPercent == 29)
            #expect(loaded.first.claude.creditUsedUsd == 5)
            #expect(loaded.first.codex.creditBalance == 3)
            await engine.setQuota(QuotaSnapshot(
                claude: ClaudeUsageFetcher.UsageData(
                    fiveHourPercent: 42, weeklyPercent: 61,
                    creditUsedUsd: 10, creditLimitUsd: 200
                ),
                codex: CodexUsageFetcher.CreditData(used: 7, limit: 80)
            ))
            await engine.rescanAll()
            #expect(loaded.last.claude.fiveHourPercent == 42)
            let reloaded = CacheSnapshots()
            let next = UsageEngine(feed: feed, clock: SystemClock())
            await next.setSink { reloaded.append($0) }
            await next.start()
            #expect(reloaded.first.claude.fiveHourPercent == 42)
            #expect(reloaded.first.claude.weeklyPercent == 61)
            #expect(reloaded.first.claude.creditUsedUsd == 10)
            #expect(reloaded.first.claude.creditLimitUsd == 200)
            #expect(reloaded.first.codex.creditBalance == 7)
            #expect(reloaded.first.codex.creditLimit == 80)
            #expect(FileManager.default.fileExists(atPath: cache.path))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
