import Foundation

public struct QuotaSnapshot: Sendable, Equatable {
    public var claude: ClaudeUsageFetcher.UsageData?
    public var codex: CodexUsageFetcher.CreditData?

    public init(claude: ClaudeUsageFetcher.UsageData? = nil, codex: CodexUsageFetcher.CreditData? = nil) {
        self.claude = claude
        self.codex = codex
    }
}

/// The ONLY filesystem-touching component. Owns CandidateSet, TailReader,
/// DeltaAccumulator and RegimeSwitch; rescans on cold start / 60s sweep,
/// tails on every FSEvents file event, then republishes a fresh
/// UsageSnapshot via the sink.
///
/// Aggregation: per-file aggregates are MERGED — today tokens sum across
/// files, session sets union, the 5h anchor is the earliest qualifying row
/// clamped to now−5h. The last file's values never overwrite the rest.
public actor UsageEngine {
    public struct Feed: Sendable {
        public var claudeRoot: URL
        public var codexRoot: URL
        public var claudeUsageCache: URL

        public init(claudeRoot: URL, codexRoot: URL, claudeUsageCache: URL) {
            self.claudeRoot = claudeRoot
            self.codexRoot = codexRoot
            self.claudeUsageCache = claudeUsageCache
        }
    }

    public enum Provenance: Sendable, Equatable {
        case claude
        case codex
    }

    private let feed: Feed
    private let clock: UsageClock
    private var includeSidechains = true
    private var positions: [URL: TailPosition] = [:]
    private var deltas = DeltaAccumulator()
    private var quota = QuotaSnapshot()
    public private(set) var regime = RegimeSwitch()
    private var candidates = Set<URL>()
    // Per-file aggregates: the ONLY aggregation ledger. A changed file
    // recomputes its OWN entry; the snapshot is a fold over ALL entries —
    // order-independent by construction (no += into a previous snapshot).
    private var claudeFiles: [URL: ClaudeFileAggregate] = [:]
    private var codexFiles: [URL: CodexFileAggregate] = [:]

    struct ClaudeFileAggregate: Sendable, Equatable {
        var today: TokenUsage
        var block: TokenUsage
        var blockStart: Date?
        var weekly: TokenUsage
        var sessions: Set<String>
        var lastActivity: Date?
        var lastModel: String?
    }

    struct CodexFileAggregate: Sendable, Equatable {
        var today: CodexTokenUsage
        var rateLimits: [RateLimitWindow]
        var planType: String?
        var creditBalance: Double?
        var sessions: Set<String>
        var lastEvent: Date?
    }

    public init(feed: Feed, clock: UsageClock) {
        self.feed = feed
        self.clock = clock
    }

    public func setIncludeSidechains(_ value: Bool) {
        includeSidechains = value
    }

    public func setQuota(_ value: QuotaSnapshot) {
        quota = value
    }

    public func start() {
        if let cached = loadSnapshotCache() {
            sink?(cached)
        }
        rescanAll()
    }

    /// Cold start, 60s sweep: rescan every candidate.
    public func rescanAll() {
        let started = clock.now()
        let now = started
        let found = CandidateSet(clock: clock)
            .files(claudeRoot: feed.claudeRoot, codexRoot: feed.codexRoot, now: now)
        candidates = Set(found)
        positions.removeAll()
        deltas = DeltaAccumulator()
        claudeFiles.removeAll()
        codexFiles.removeAll()
        for url in found {
            recompute(url: url, now: now)
        }
        regime.recordFullScan(duration: clock.now().timeIntervalSince(started))
        let snapshot = fold(now: now)
        saveSnapshotCache(snapshot)
        sink?(snapshot)
    }

    /// Every FSEvents file event: tail each changed candidate from its
    /// stored offset, then recompute from the merged per-file aggregates.
    public func tailPulse(changed: [URL]) {
        let now = clock.now()
        var touched = Set(changed)
        let cutoff = WindowMath.candidateCutoff(now: now, clock: clock)
        for url in changed where CandidateSet.isCandidate(url, cutoff: cutoff) {
            candidates.insert(url)
        }
        candidates = Set(candidates.filter { CandidateSet.isCandidate($0, cutoff: cutoff) })
        touched.formIntersection(candidates)
        claudeFiles = claudeFiles.filter { candidates.contains($0.key) }
        codexFiles = codexFiles.filter { candidates.contains($0.key) }
        guard !touched.isEmpty else {
            sink?(fold(now: now)); return
        }
        for url in touched {
            recompute(url: url, now: now)
        }
        sink?(fold(now: now))
    }

    /// Routing by WHICH ROOT the file came from — the scan's own truth,
    /// never a path substring (env overrides are e2e fixtures).
    private func provenance(of url: URL) -> Provenance {
        url.path.hasPrefix(feed.claudeRoot.path) ? .claude : .codex
    }

    /// One file, one aggregate — the ONLY place a file's content is read.
    private func recompute(url: URL, now: Date) {
        switch provenance(of: url) {
        case .claude:
            claudeFiles[url] = claudeAggregate(url: url, now: now)
        case .codex:
            codexFiles[url] = codexAggregate(url: url, now: now)
        }
    }

    public var onChange: (@Sendable (UsageSnapshot) -> Void)?
    private var sink: (@Sendable (UsageSnapshot) -> Void)?

    public func setSink(_ sink: (@Sendable (UsageSnapshot) -> Void)?) {
        self.sink = sink
    }

    private static var snapshotCacheURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/plugins/oh-my-claudecode/.usage-hud-snapshot.json")
    }

    private func loadSnapshotCache() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: Self.snapshotCacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SnapshotCodec.decode(obj)
    }

    private func saveSnapshotCache(_ snapshot: UsageSnapshot) {
        guard let obj = SnapshotCodec.encode(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        let dir = Self.snapshotCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.snapshotCacheURL)
    }

    // MARK: - Aggregation

    /// Per-file aggregate recompute — the ONLY place a file's content is
    /// read. Claude: incremental tail from stored position (cold start
    /// streams the full file via forEachLine, bounded RSS). Codex:
    /// per-file incremental tail; the aggregate accumulates ONLY this
    /// file's new deltas and fold() owns the cross-file merge.
    private func claudeAggregate(url: URL, now: Date) -> ClaudeFileAggregate {
        var agg = claudeFiles[url] ?? ClaudeFileAggregate(
            today: TokenUsage(), block: TokenUsage(), blockStart: nil,
            weekly: TokenUsage(), sessions: [], lastActivity: nil, lastModel: nil
        )
        if let position = positions[url] {
            guard let tail = try? TailReader.read(url: url, from: position) else { return agg }
            positions[url] = tail.position
            for line in tail.newLines {
                accumulateClaudeLine(line, now: now, agg: &agg)
            }
        } else {
            let reader = StreamingLineReader(url: url)
            try? reader.forEachLine { line in
                accumulateClaudeLine(line, now: now, agg: &agg)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs?[.size] as? Int {
                positions[url] = TailPosition(byteOffset: size, partialCarry: "")
            }
        }
        return agg
    }

    private func accumulateClaudeLine(_ line: String, now: Date, agg: inout ClaudeFileAggregate) {
        guard let row = ClaudeLineParser().parse(line) else { return }
        if row.isSidechain, !includeSidechains { return }
        if WindowMath.isToday(row.timestamp, now: now, clock: clock) {
            agg.today = agg.today + row.usage
        }
        if WindowMath.isWithinFiveHours(row.timestamp, now: now) {
            agg.block = agg.block + row.usage
            agg.blockStart = agg.blockStart.map { min($0, row.timestamp) }
                ?? BlockEstimate.anchor(earliestEvent: row.timestamp, now: now)
        }
        if WindowMath.isWithinWeek(row.timestamp, now: now) {
            agg.weekly = agg.weekly + row.usage
        }
        agg.sessions.insert(row.sessionId)
        if agg.lastActivity == nil || row.timestamp > agg.lastActivity! {
            agg.lastActivity = row.timestamp
            agg.lastModel = row.model ?? agg.lastModel
        }
    }

    private func codexAggregate(url: URL, now: Date) -> CodexFileAggregate {
        var agg = codexFiles[url] ?? CodexFileAggregate(
            today: CodexTokenUsage(), rateLimits: [], planType: nil,
            creditBalance: nil,
            sessions: [], lastEvent: nil
        )
        let key = url.path
        let position = positions[url] ?? TailPosition()
        guard let tail = try? TailReader.read(url: url, from: position) else {
            return agg
        }
        positions[url] = tail.position
        for line in tail.newLines {
            guard let row = CodexLineParser().parse(line) else { continue }
            let delta = deltas.absorb(row: row, today: { WindowMath.isToday($0, now: now, clock: clock) }, fileKey: key)
            agg.today = agg.today + delta
            if let limits = row.rateLimits {
                agg.rateLimits = [limits.primary, limits.secondary].compactMap { window in
                    window.map { RateLimitWindow(windowMinutes: $0.windowMinutes, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
                }
                agg.planType = limits.planType ?? agg.planType
                agg.creditBalance = limits.creditBalance ?? agg.creditBalance
            }
            let event = row.timestamp
            if event > (agg.lastEvent ?? .distantPast) {
                agg.lastEvent = event
            }
            agg.sessions.insert(key)
        }
        return agg
    }

    /// Deterministic fold — order-independent by construction: token sums
    /// commute; session sets union (parent+subagent same sessionId counts
    /// ONCE); blockStart = min; lastActivity = max. Codex rateLimits/plan
    /// come from the file with the NEWEST event, ties by path — never
    /// dictionary iteration order.
    private func fold(now: Date) -> UsageSnapshot {
        var today = TokenUsage()
        var block = TokenUsage()
        var blockStart: Date?
        var weekly = TokenUsage()
        var sessions = Set<String>()
        var lastActivity: Date?
        var lastModel: String?
        for agg in claudeFiles.values {
            today = today + agg.today
            block = block + agg.block
            weekly = weekly + agg.weekly
            if let s = agg.blockStart { blockStart = blockStart.map { min($0, s) } ?? s }
            sessions.formUnion(agg.sessions)
            if let a = agg.lastActivity, a > (lastActivity ?? .distantPast) {
                lastActivity = a
                lastModel = agg.lastModel
            }
        }
        let cache = quota.claude
        let claude = UsageSnapshot.Claude(
            todayUsage: today, blockUsage: block, blockStart: blockStart,
            weeklyUsage: weekly,
            fiveHourPercent: cache?.fiveHourPercent,
            fiveHourResetsAt: cache?.fiveHourResetsAt,
            weeklyPercent: cache?.weeklyPercent,
            weeklyResetsAt: cache?.weeklyResetsAt,
            creditUsedUsd: cache?.creditUsedUsd,
            creditLimitUsd: cache?.creditLimitUsd,
            activeSessions: sessions.count, lastActivity: lastActivity, lastModel: lastModel
        )

        var todayC = CodexTokenUsage()
        var rateLimits: [RateLimitWindow] = []
        var planType: String?
        var creditBalance: Double?
        var sessionsC = Set<String>()
        var lastEvent: Date?
        for (url, agg) in codexFiles.sorted(by: { $0.key.path < $1.key.path }) {
            todayC = todayC + agg.today
            sessionsC.formUnion(agg.sessions)
            if let event = agg.lastEvent, event > (lastEvent ?? .distantPast) {
                lastEvent = event
                rateLimits = agg.rateLimits
                planType = agg.planType
                creditBalance = agg.creditBalance
            }
        }
        let codexCache = quota.codex
        let codex = UsageSnapshot.Codex(
            todayUsage: todayC, rateLimits: rateLimits, planType: planType,
            creditBalance: codexCache?.used,
            creditLimit: codexCache?.limit,
            activeSessions: sessionsC.count, lastActivity: lastEvent
        )
        return UsageSnapshot(claude: claude, codex: codex)
    }
}