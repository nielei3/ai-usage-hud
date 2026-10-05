import Foundation
import Testing

@testable import UsageCore

@Suite struct WindowMathTests {
    private var clock: ManualClock {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let midnight = cal.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        return ManualClock(start: midnight.addingTimeInterval(30 * 60), timeZone: cal.timeZone)
    }

    @Test func cutoffIsMinOfMidnightAndNowMinus5h() {
        // Fixture 'now' is 00:30 local; now-5h (19:30 prev day) precedes local midnight,
        // so the min() must land on now-5h, not midnight.
        let clock = clock
        let now = clock.now()
        let cutoff = WindowMath.candidateCutoff(now: now, clock: clock)
        #expect(cutoff == now.addingTimeInterval(-5 * 3600))
    }

    @Test func cutoffFallsBackToNowMinus5hInsideFirstFiveHours() {
        var clock = clock
        clock.advance(by: 2 * 3600)
        let now = clock.now()
        let cutoff = WindowMath.candidateCutoff(now: now, clock: clock)
        #expect(cutoff == now.addingTimeInterval(-5 * 3600))
    }

    @Test func isTodayRespectsInjectedTimeZone() {
        let clock = clock
        let cal = clock.calendar
        let yesterday = clock.now().addingTimeInterval(-24 * 3600)
        #expect(WindowMath.isToday(clock.now(), now: clock.now(), clock: clock))
        #expect(!WindowMath.isToday(yesterday, now: clock.now(), clock: clock))
        _ = cal
    }
}

@Suite struct BlockEstimateTests {
    @Test func anchorClampsEarliestEventToNowMinus5h() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let eightHoursAgo = now.addingTimeInterval(-8 * 3600)
        #expect(BlockEstimate.anchor(earliestEvent: eightHoursAgo, now: now) == now.addingTimeInterval(-5 * 3600))
    }

    @Test func anchorKeepsEarliestEventInsideWindow() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let oneHourAgo = now.addingTimeInterval(-1 * 3600)
        #expect(BlockEstimate.anchor(earliestEvent: oneHourAgo, now: now) == oneHourAgo)
    }

    @Test func anchorWithoutEventsIsNowMinus5h() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(BlockEstimate.anchor(earliestEvent: nil, now: now) == now.addingTimeInterval(-5 * 3600))
    }
}

@Suite struct StatusBarDecisionTests {
    @Test func bothSidesPresentPicksMaxPercentBranch() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: 40, codexPercent: 70, claudeTodayTokens: 1_000, codexTodayTokens: 2_000
        )
        #expect(outcome == .maxPercent(claude: 40, codex: 70))
    }

    @Test func onlyClaudePresentShowsClaudeSide() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: 55, codexPercent: nil, claudeTodayTokens: 0, codexTodayTokens: 0
        )
        #expect(outcome == .singleSide(side: .claude, percent: 55))
    }

    @Test func onlyCodexPresentShowsCodexSide() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: nil, codexPercent: 12.5, claudeTodayTokens: 0, codexTodayTokens: 0
        )
        #expect(outcome == .singleSide(side: .codex, percent: 12.5))
    }

    @Test func neitherPercentFallsBackToLargerTokenCount() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: nil, codexPercent: nil, claudeTodayTokens: 412_000, codexTodayTokens: 90_000
        )
        #expect(outcome == .tokenFallback(text: "412k"))
    }

    @Test func nothingAtAllIsIdle() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: nil, codexPercent: nil, claudeTodayTokens: 0, codexTodayTokens: 0
        )
        #expect(outcome == .idle)
    }
}

@Suite struct AbbreviationTests {
    @Test func abbreviatesThousandsAndMillions() {
        #expect(StatusBarDecision.abbreviate(999) == "999")
        #expect(StatusBarDecision.abbreviate(1_000) == "1k")
        #expect(StatusBarDecision.abbreviate(412_345) == "412k")
        #expect(StatusBarDecision.abbreviate(1_500_000) == "1.5M")
    }
}

@Suite struct RateLimitWindowNameTests {
    @Test func windowNamesCoverFiveHourWeeklyAndRaw() {
        #expect(RateLimitWindow(windowMinutes: 300, usedPercent: 10, resetsAt: Date()).windowName == "5h")
        #expect(RateLimitWindow(windowMinutes: 10_080, usedPercent: 10, resetsAt: Date()).windowName == "weekly")
        #expect(RateLimitWindow(windowMinutes: 60, usedPercent: 10, resetsAt: Date()).windowName == "60m")
    }
}
