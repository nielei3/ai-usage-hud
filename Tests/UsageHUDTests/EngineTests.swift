import Foundation
import Testing

@testable import UsageCore

private func fixture(_ parts: String...) -> URL {
    parts.reduce(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    ) { $0.appendingPathComponent($1) }
}

private func laClock(at localTime: String) -> ManualClock {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    let day = cal.startOfDay(for: base)
    let comps = localTime.split(separator: ":").compactMap { Double($0) }
    return ManualClock(
        start: day.addingTimeInterval((comps[0] * 3600) + (comps.count > 1 ? comps[1] * 60 : 0)),
        timeZone: cal.timeZone
    )
}

@Suite struct CandidateSetTests {
    @Test func cutoffIsMinOfLocalMidnightAndNowMinus5h() {
        let clock = laClock(at: "00:30")
        let cutoff = WindowMath.candidateCutoff(now: clock.now(), clock: clock)
        #expect(cutoff == clock.now().addingTimeInterval(-5 * 3600))
    }

    @Test func cutoffFallsBackToNowMinus5hInsideFirstFiveHours() {
        let clock = laClock(at: "02:00")
        let cutoff = WindowMath.candidateCutoff(now: clock.now(), clock: clock)
        #expect(cutoff == clock.now().addingTimeInterval(-5 * 3600))
    }
}

@Suite struct DeltaAccumulatorTests {
    private func todayClock() -> ManualClock {
        laClock(at: "10:00")
    }

    @Test func todaySumsLastTokenUsagePerEvent() {
        var acc = DeltaAccumulator()
        let today = todayClock().now()
        let a = CodexUsageRow(timestamp: today, last: CodexTokenUsage(inputTokens: 100, outputTokens: 50), total: CodexTokenUsage(inputTokens: 100, outputTokens: 50))
        let b = CodexUsageRow(timestamp: today, last: CodexTokenUsage(inputTokens: 200, outputTokens: 70), total: CodexTokenUsage(inputTokens: 300, outputTokens: 120))
        let key = "f"
        _ = acc.absorb(row: a, today: { $0 == today }, fileKey: key)
        let second = acc.absorb(row: b, today: { $0 == today }, fileKey: key)
        #expect(second.inputTokens == 200)
        #expect(second.outputTokens == 70)
    }

    @Test func missingLastFallsBackToTotalDeltaAcrossMidnightBaseline() {
        var acc = DeltaAccumulator()
        let clock = laClock(at: "00:30")
        let midnight = clock.now()
        let yesterday = midnight.addingTimeInterval(-3600)
        // Yesterday's last row: total carries the cumulative 10_000.
        let prev = CodexUsageRow(timestamp: yesterday, last: nil, total: CodexTokenUsage(inputTokens: 10_000, outputTokens: 2_000))
        _ = acc.absorb(row: prev, today: { $0 >= midnight }, fileKey: "f")
        // Today's first row lacks `last`: delta = today total − yesterday's total.
        let row = CodexUsageRow(timestamp: midnight.addingTimeInterval(60), last: nil, total: CodexTokenUsage(inputTokens: 11_000, outputTokens: 2_500))
        let delta = acc.absorb(row: row, today: { $0 >= midnight }, fileKey: "f")
        #expect(delta.inputTokens == 1_000)
        #expect(delta.outputTokens == 500)
    }

    @Test func firstRowMissingLastUsesZeroBaseline() {
        var acc = DeltaAccumulator()
        let clock = laClock(at: "00:30")
        let row = CodexUsageRow(timestamp: clock.now(), last: nil, total: CodexTokenUsage(inputTokens: 4_000, outputTokens: 900))
        let delta = acc.absorb(row: row, today: { $0 == clock.now() }, fileKey: "f")
        #expect(delta.inputTokens == 4_000)
        #expect(delta.outputTokens == 900)
    }
}

@Suite struct BlockEstimateAnchorTests {
    @Test func anchorClampsEarliestEventToNowMinus5h() {
        let now = laClock(at: "03:00").now()
        let old = now.addingTimeInterval(-8 * 3600)
        #expect(BlockEstimate.anchor(earliestEvent: old, now: now) == now.addingTimeInterval(-5 * 3600))
    }

    @Test func anchorKeepsEarliestEventInsideWindow() {
        let now = laClock(at: "03:00").now()
        let near = now.addingTimeInterval(-1 * 3600)
        #expect(BlockEstimate.anchor(earliestEvent: near, now: now) == near)
    }
}

@Suite struct WindowMathMidnightTests {
    @Test func candidateSetAdmitsYesterdayFileInsideFirstFiveHours() {
        // 00:30 local: cutoff = now−5h = 19:30 prev day. A file whose events sit at
        // 23:00 yesterday (mtime yesterday 23:00) IS ≥ cutoff → admitted.
        let clock = laClock(at: "00:30")
        let cutoff = WindowMath.candidateCutoff(now: clock.now(), clock: clock)
        let yesterdayEvent = clock.now().addingTimeInterval(-1.5 * 3600)
        #expect(yesterdayEvent >= cutoff)
    }

    @Test func todayAggregateExcludesYesterdayRows() {
        let clock = laClock(at: "00:30")
        let yesterday = clock.now().addingTimeInterval(-1.5 * 3600)
        #expect(WindowMath.isToday(yesterday, now: clock.now(), clock: clock) == false)
        #expect(WindowMath.isToday(clock.now(), now: clock.now(), clock: clock))
    }
}
