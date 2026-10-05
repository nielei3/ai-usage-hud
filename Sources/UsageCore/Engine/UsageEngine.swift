import Foundation

/// The ONLY filesystem-touching component. Owns CandidateSet, TailReader,
/// DeltaAccumulator and RegimeSwitch; rescans or tails per Regime on every
/// FSEvents batch, then republishes a fresh UsageSnapshot via the sink.
///
/// Aggregation: per-file aggregates are MERGED — today tokens sum across
/// files, session sets union, the 5h anchor is the earliest qualifying row
/// clamped to now−5h. The last file's values never overwrite the rest.
public actor UsageEngine {
    public struct Feed: Sendable {
        public var claudeRoot: URL
        public var codexRoot: URL

        public init(claudeRoot: URL, codexRoot: URL) {
            self.claudeRoot = claudeRoot
            self.codexRoot = codexRoot
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
    /// Read by AppShell to route FSEvents batches (tail vs full rescan).
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
        var sessions: Set<String>
        var lastActivity: Date?
        var lastModel: String?
    }

    struct CodexFileAggregate: Sendable, Equatable {
        var today: CodexTokenUsage
        var rateLimits: [RateLimitWindow]
        var planType: String?
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

    public func start() {
        rescanAll()
    }

    /// Cold start, 60s sweep, or sub-1s-regime event: rescan every candidate.
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
        let snapshot = fold(now: now)
        regime.recordFullScan(duration: clock.now().timeIntervalSince(started))
        sink?(snapshot)
    }

    /// >1s regime: tail each candidate from its stored offset, then recompute
    /// everything from the merged per-file aggregates.
    public func tailPulse(changed: [URL]) {
        let now = clock.now()
        var touched = Set(changed)
        let cutoff = WindowMath.candidateCutoff(now: now, clock: clock)
        for url in changed where CandidateSet.isCandidate(url, cutoff: cutoff) {
            candidates.insert(url)
        }
        // Hygiene: a re-scan drops candidates whose mtime fell below cutoff.
        candidates = Set(candidates.filter { CandidateSet.isCandidate($0, cutoff: cutoff) })
        touched.formIntersection(candidates)
        // Drop files that fell out of the candidate set (mtime below cutoff).
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

    // MARK: - Aggregation

    /// Per-file aggregate recompute — the ONLY place a file's content is
    /// read. Claude: one full streaming parse (bounded RSS; a 2GB session
    /// re-parses only when THAT file changes). Codex: per-file incremental
    /// tail; the aggregate accumulates ONLY this file's new deltas and
    /// fold() owns the cross-file merge.
    private func claudeAggregate(url: URL, now: Date) -> ClaudeFileAggregate {
        var today = TokenUsage()
        var block = TokenUsage()
        var blockStart: Date?
        var sessions = Set<String>()
        var lastActivity: Date?
        var lastModel: String?
        let lines = (try? StreamingLineReader(url: url).lines()) ?? []
        for line in lines {
            guard let row = ClaudeLineParser().parse(line) else { continue }
            if row.isSidechain, !includeSidechains { continue }
            if WindowMath.isToday(row.timestamp, now: now, clock: clock) {
                today = today + row.usage
            }
            if WindowMath.isWithinFiveHours(row.timestamp, now: now) {
                block = block + row.usage
                blockStart = blockStart.map { min($0, row.timestamp) }
                    ?? BlockEstimate.anchor(earliestEvent: row.timestamp, now: now)
            }
            sessions.insert(row.sessionId)
            if lastActivity == nil || row.timestamp > lastActivity! {
                lastActivity = row.timestamp
                lastModel = row.model ?? lastModel
            }
        }
        return ClaudeFileAggregate(
            today: today, block: block, blockStart: blockStart,
            sessions: sessions, lastActivity: lastActivity, lastModel: lastModel
        )
    }

    private func codexAggregate(url: URL, now: Date) -> CodexFileAggregate {
        var agg = codexFiles[url] ?? CodexFileAggregate(
            today: CodexTokenUsage(), rateLimits: [], planType: nil,
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
        var sessions = Set<String>()
        var lastActivity: Date?
        var lastModel: String?
        for agg in claudeFiles.values {
            today = today + agg.today
            block = block + agg.block
            if let s = agg.blockStart { blockStart = blockStart.map { min($0, s) } ?? s }
            sessions.formUnion(agg.sessions)
            if let a = agg.lastActivity, a > (lastActivity ?? .distantPast) {
                lastActivity = a
                lastModel = agg.lastModel
            }
        }
        let claude = UsageSnapshot.Claude(
            todayUsage: today, blockUsage: block, blockStart: blockStart,
            activeSessions: sessions.count, lastActivity: lastActivity, lastModel: lastModel
        )

        var todayC = CodexTokenUsage()
        var rateLimits: [RateLimitWindow] = []
        var planType: String?
        var sessionsC = Set<String>()
        var lastEvent: Date?
        for (url, agg) in codexFiles.sorted(by: { $0.key.path < $1.key.path }) {
            todayC = todayC + agg.today
            sessionsC.formUnion(agg.sessions)
            if let event = agg.lastEvent, event > (lastEvent ?? .distantPast) {
                lastEvent = event
                rateLimits = agg.rateLimits
                planType = agg.planType
            }
        }
        let codex = UsageSnapshot.Codex(
            todayUsage: todayC, rateLimits: rateLimits, planType: planType,
            activeSessions: sessionsC.count, lastActivity: lastEvent
        )
        return UsageSnapshot(claude: claude, codex: codex)
    }
}