import Foundation
import Testing
import UsageCore

private func worktree() -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // repo root
        .path
}

@Suite struct StatusBarRendererCodexSideTests {
    // The renderer maps .codex single-side to "Codex NN%" — asserted at the
    // decision boundary (blocker 12's "X" → "Codex" rename).
    @Test func codexSideRendersCodexLabel() {
        let outcome = StatusBarDecision.resolve(
            claudePercent: nil, codexPercent: 40,
            claudeTodayTokens: 0, codexTodayTokens: 10
        )
        guard case .singleSide(let side, let percent) = outcome else {
            Issue.record("expected singleSide"); return
        }
        #expect(side == .codex)
        #expect(percent == 40)
    }
}

@Suite struct StatusDecisionBlockPercentTests {
    @Test func blockPercentUsesBlockUsageOwnTotalNotToday() {
        let block = TokenUsage(inputTokens: 200, outputTokens: 100, cacheReadTokens: 150, cacheCreationTokens: 50)
        let pct = StatusBarDecision.blockPercent(blockUsage: block, limitTokens: 1_000)
        #expect(pct == 50.0)
    }

    @Test func blockPercentNilWithoutCapAndClamps() {
        #expect(StatusBarDecision.blockPercent(blockUsage: TokenUsage(inputTokens: 10), limitTokens: nil) == nil)
        #expect(StatusBarDecision.blockPercent(blockUsage: TokenUsage(inputTokens: 10), limitTokens: 0) == nil)
        #expect(StatusBarDecision.blockPercent(blockUsage: TokenUsage(inputTokens: 3_000), limitTokens: 1_000) == 100)
    }
}

@Suite struct TailReaderCarryResumeTests {
    private func tempFile(_ name: String, content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(name)-\(UUID().uuidString).jsonl")
        try! Data(content.utf8).write(to: url)
        return url
    }

    @Test func partialFragmentCarriedOnceAndResumed() throws {
        let url = tempFile("carry", content: "{\"a\":1}\n{\"b\":2}")
        let first = try TailReader.read(url: url, from: TailPosition())
        #expect(first.newLines == ["{\"a\":1}"])
        #expect(first.position.byteOffset == 15)
        #expect(first.position.partialCarry == "{\"b\":2}")

        // Append the rest of the fragment; the carry must NOT be prepended
        // twice and the offset must resume at the fragment start.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}\n".utf8))
        try handle.close()

        let second = try TailReader.read(url: url, from: first.position)
        // True content: carry '{"b":2}' + completing '}' = '{"b":2}}'.
        #expect(second.newLines == ["{\"b\":2}}"])
        #expect(second.position.byteOffset == 17)
        #expect(second.position.partialCarry.isEmpty)
    }

    @Test func multibyteFragmentCompletesAcrossReads() throws {
        let content = "{\"a\":\"中"
        let url = tempFile("multibyte", content: content)
        let first = try TailReader.read(url: url, from: TailPosition())
        #expect(first.newLines.isEmpty)
        #expect(first.position.byteOffset == content.utf8.count)
        #expect(first.position.partialCarry == "{\"a\":\"中")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("文\"}\n".utf8))
        try handle.close()
        let second = try TailReader.read(url: url, from: first.position)
        #expect(second.newLines == ["{\"a\":\"中文\"}"])
        #expect(second.position.byteOffset == content.utf8.count + "文\"}\n".utf8.count)
        #expect(second.position.partialCarry.isEmpty)
    }

    @Test func truncationResetsPositionToZero() throws {
        let url = tempFile("trunc", content: "one\ntwo\nthree\n")
        var position = try TailReader.read(url: url, from: TailPosition()).position
        #expect(position.byteOffset > 0)

        try Data("tiny\n".utf8).write(to: url)
        let result = try TailReader.read(url: url, from: position)
        #expect(result.newLines == ["tiny"])
        position = result.position
        #expect(position.byteOffset == 5)
    }

    @Test func hugeCandidateReadsThroughOneMegabyteChunks() throws {
        var content = "x\(Int.random(in: 0...9))\n"
        content = String(repeating: content, count: 400_000) // ~7.2MB
        let url = tempFile("big", content: content)
        let result = try TailReader.read(url: url, from: TailPosition())
        #expect(result.newLines.count == 400_000)
        #expect(result.position.byteOffset == content.utf8.count)
        let expectedLines = content.split(separator: "\n").map(String.init)
        #expect(result.newLines.map { String($0) } == expectedLines.map { String($0) })
    }
}

@Suite struct NumericParsingTests {
    @Test func hugeAndPathologicalDoublesClampToZeroNotCrash() {
        #expect(NumericParsing.int(1e19) == 0)
        #expect(NumericParsing.int(9.3e18) == 0)
        #expect(NumericParsing.int(-1e19) == 0)
        #expect(NumericParsing.int(.infinity) == 0)
        #expect(NumericParsing.int(.nan) == 0)
        #expect(NumericParsing.int(1.5e18) == 1_500_000_000_000_000_000)
        #expect(NumericParsing.int("999") == 999)
        #expect(NumericParsing.int(nil) == 0)
    }
}

@Suite struct WindowMathFiveHourTests {
    private func clock(at localTime: String) -> ManualClock {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let midnight = cal.startOfDay(for: base)
        let comps = localTime.split(separator: ":").map { Double($0)! }
        return ManualClock(start: midnight.addingTimeInterval(comps[0] * 3600 + comps[1] * 60), timeZone: cal.timeZone)
    }

    @Test func fiveHourFilterIsNowMinus5hEvenPastMidnight() {
        // 00:30 local: now−5h = 19:30 yesterday. A 23:00-yesterday row is inside
        // the 5h window even though it is NOT today.
        let clock = clock(at: "00:30")
        let yesterday23 = clock.now().addingTimeInterval(-1.5 * 3600)
        #expect(WindowMath.isWithinFiveHours(yesterday23, now: clock.now()))
        #expect(!WindowMath.isToday(yesterday23, now: clock.now(), clock: clock))
        #expect(!WindowMath.isWithinFiveHours(clock.now().addingTimeInterval(-6 * 3600), now: clock.now()))
    }
}

@Suite struct SettingsStoreLaunchAtLoginTests {
    private func suite(_ name: String) -> UserDefaults {
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        return s
    }

    @Test func launchAtLoginRoundTrips() {
        let d = suite("usage-hud-test-lal")
        let store = UserDefaultsSettingsStore(defaults: d)
        store.save(HudSettings(includeSidechains: true, fiveHourLimitTokens: 1_000, launchAtLogin: true))
        #expect(store.load().launchAtLogin)
        store.save(HudSettings(includeSidechains: true, fiveHourLimitTokens: 1_000, launchAtLogin: false))
        #expect(!store.load().launchAtLogin)
    }
}
